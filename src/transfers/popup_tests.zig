//! The Transfers panel and icon painted off screen: every row state gets
//! its controls, and `REDIWM_TRANSFERS_PREVIEW=<dir>` writes the pictures.
const std = @import("std");
const theme = @import("ui").theme;
const paint = @import("ui").paint;
const popup_mod = @import("popup.zig");
const rows = @import("popup_rows.zig");
const icon = @import("icon.zig");
const model_mod = @import("model.zig");
const popup_style = @import("../popup_style.zig");
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;

const snapshot =
    \\{"version":1,"event":"snapshot","sequence":1,"jobs":[
    \\{"id":1,"kind":"copy","state":"running","label":"archlinux-2026.11.01-x86_64.iso","source_count":1,"completed_bytes":903872512,"total_bytes":1288699904,"rate_bytes_per_second":18874368,"destination":"/home/u/Downloads/ISOs","rate_history":[31457280,35651584,44040192,39845888,33554432,29360128,31457280,37748736,46137344,41943040,35651584,31457280,33554432,39845888,48234496,44040192,37748736,33554432,35651584,41943040,18874368,16777216,18874368,20971520,18874368,17825792,18874368,19922944,18874368,18874368]},
    \\{"id":2,"kind":"move","state":"paused","label":"Holiday photos","source_count":214,"completed_bytes":1610612736,"total_bytes":3865051136,"destination":"/home/u/Pictures","rate_history":[9437184,9437184,8388608,10485760,9437184,0,0,0,0,0]},
    \\{"id":3,"kind":"copy","state":"queued","label":"report-final.pdf","source_count":1,"total_bytes":4194304,"conflict":true,"destination":"/home/u/Documents"},
    \\{"id":4,"kind":"extract","state":"running","label":"backup.tar.zst","source_count":1,"completed_bytes":41943040,"total_bytes":943718400,"waiting_for":"USB Drive","destination":"/run/media/u/USB Drive"},
    \\{"id":5,"kind":"delete","state":"running","label":"old-builds","source_count":1,"completed_items":180,"total_items":600}]}
;
const finished =
    \\{"version":1,"event":"jobs","sequence":2,"jobs":[
    \\{"id":9,"kind":"copy","state":"completed","label":"thesis.odt","source_count":1,"total_bytes":2306867,"destination":"/home/u/Documents","removed":true},
    \\{"id":8,"kind":"trash","state":"failed","label":"cache","source_count":3,"removed":true}]}
;

fn preview(name: []const u8, buf: *PanelBuffer) !void {
    const dir = std.c.getenv("REDIWM_TRANSFERS_PREVIEW") orelse return;
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
    const bytes = try @import("../screenshot/encode.zig").encodePng(std.testing.allocator, @intCast(buf.width), @intCast(buf.height), buf.pixels, @intCast(buf.width));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
}

fn paintPanel(popup: *popup_mod.Popup, model: *const model_mod.Model, scale: f32) !*PanelBuffer {
    popup.list_top = popup_mod.header + (if (model.liveJobs().len > 0) popup_mod.graph_height else 0);
    popup.content_height = rows.contentHeight(popup, model);
    popup.height = popup.list_top + popup.content_height + popup_mod.footer;
    const buf = try PanelBuffer.create(@intFromFloat(popup_mod.width), @intFromFloat(@ceil(popup.height)), scale);
    var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
    r.palette = theme.shellPalette();
    popup_style.background(&r, buf, popup_mod.width, popup.height, 12, 200, false);
    popup.hit_count = 0;
    popup.paintHeader(&r, model.summary());
    if (model.liveJobs().len > 0) rows.paintTotal(&r, model);
    r.clip = .{ .x = 8, .y = popup.list_top, .w = popup_mod.width - 16, .h = popup.height - popup.list_top - popup_mod.footer };
    rows.paintList(popup, &r, model);
    r.clip = null;
    popup.paintFooter(&r, model);
    return buf;
}

fn has(popup: *const popup_mod.Popup, focus: popup_mod.Focus, id: u64) bool {
    for (popup.hits[0..popup.hit_count]) |h| if (h.focus == focus and h.id == id) return true;
    return false;
}

test "transfers panel paints every row state with its controls" {
    var model: model_mod.Model = .{};
    _ = try model.applyLine(std.testing.allocator, snapshot);
    for ([_]f32{ 1, 1.5 }) |scale| {
        var popup: popup_mod.Popup = .{ .output = undefined, .buffer_node = undefined, .selected = 1, .armed_cancel = 4 };
        const buf = try paintPanel(&popup, &model, scale);
        defer buf.base.drop();
        // A running copy pauses, cancels and shows where it goes.
        try std.testing.expect(has(&popup, .pause, 1) and has(&popup, .cancel, 1) and has(&popup, .destination, 1));
        // A conflict is resolved in Files, not paused.
        try std.testing.expect(has(&popup, .resolve, 3) and !has(&popup, .pause, 3));
        try std.testing.expect(has(&popup, .pause, 2) and has(&popup, .pause_all, 0) and has(&popup, .open_files, 0));
        try std.testing.expect(!has(&popup, .clear_done, 0));
        if (scale == 1.5) try preview("panel", buf);
    }
    _ = try model.applyLine(std.testing.allocator, finished);
    var popup: popup_mod.Popup = .{ .output = undefined, .buffer_node = undefined };
    const buf = try paintPanel(&popup, &model, 1.5);
    defer buf.base.drop();
    try std.testing.expect(has(&popup, .done_row, 9) and !has(&popup, .done_row, 8) and has(&popup, .clear_done, 0));
    try preview("finished", buf);
    model.disconnected();
    model.clearDone();
    var empty: popup_mod.Popup = .{ .output = undefined, .buffer_node = undefined };
    const empty_buf = try paintPanel(&empty, &model, 1.5);
    defer empty_buf.base.drop();
    try preview("empty", empty_buf);
}

test "transfers panel icon states" {
    const states = [_]model_mod.Summary{
        .{},
        .{ .active = 2, .fraction = 0.62 },
        .{ .active = 2, .paused = 2, .all_paused = true, .fraction = 0.35 },
        .{ .active = 1, .fraction = 0.2, .attention = true },
        .{ .done = 1, .failed = 1 },
    };
    const scale: f32 = 4;
    const buf = try PanelBuffer.create(36 * states.len, 36, scale);
    defer buf.base.drop();
    var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
    r.fillRect(0, 0, 36 * states.len, 36, .{ .color = theme.global.taskbar_bg });
    for (states, 0..) |s, i| icon.paintSummary(&r, s, @as(f32, @floatFromInt(i)) * 36 + 6, 6, 24, theme.global.fg);
    // The running ring's arc is the accent at the top of the ring.
    const px: usize = @intFromFloat((36 + 6 + 12) * scale);
    const py: usize = @intFromFloat((6 + 3) * scale);
    const pixel = buf.pixels[py * @as(usize, @intCast(buf.width)) + px];
    const accent = theme.global.accent;
    try std.testing.expectApproxEqAbs(accent[1] * 255, @as(f32, @floatFromInt((pixel >> 8) & 255)), 24);
    try preview("icons", buf);
}
