//! Process table presentation. Geometry is shared with the sortable widgets,
//! row picking and scrollbar; sampling and process identity stay in the model.
const std = @import("std");
const tr = @import("i18n").tr;
const ui = @import("ui");
const cairo = ui.cairo;
const theme = ui.theme;
const c = @import("../files/c.zig").api;
const app = @import("app.zig");
const App = app.App;
const Rect = cairo.Rect;
const row_h: f32 = @floatCast(app.row_h);
const scrollbar = ui.widgets.scrollbar;
const pad = 13;

pub fn paint(self: *App, cr: *c.cairo_t) void {
    const list = self.listBox();
    const top = self.sections[2].computed_y;
    const frame: Rect = .{ .x = list.x, .y = top, .w = list.w, .h = list.y + list.h - top };
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    roundPath(cr, frame, theme.global.radius_md);
    c.cairo_clip(cr);
    fill(cr, .{ .x = frame.x, .y = top, .w = frame.w, .h = list.y - top }, theme.global.app_bar);
    paintRows(self, cr);
    cairo.setSource(cr, theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, frame.x, list.y - 0.5);
    c.cairo_line_to(cr, frame.x + frame.w, list.y - 0.5);
    c.cairo_stroke(cr);
    roundPath(cr, .{ .x = frame.x + 0.5, .y = frame.y + 0.5, .w = frame.w - 1, .h = frame.h - 1 }, theme.global.radius_md);
    c.cairo_stroke(cr);
}

fn paintRows(self: *App, cr: *c.cairo_t) void {
    const list = self.listBox();
    const content_w = list.w - scrollbar.gutter(theme.global.scrollbar_width);
    const count = self.model.rows.items.len;
    const first: usize = @intFromFloat(@floor(self.model.scroll / row_h));
    const last = @min(count, first + @as(usize, @intFromFloat(@ceil(list.h / row_h))) + 1);
    c.cairo_save(cr);
    c.cairo_rectangle(cr, list.x, list.y, list.w, list.h);
    c.cairo_clip(cr);
    for (first..last) |i| {
        const y: f32 = @floatCast(list.y + @as(f64, @floatFromInt(i)) * row_h - self.model.scroll);
        if (i % 2 == 1) fill(cr, .{ .x = list.x, .y = y, .w = content_w, .h = row_h }, theme.global.app_item);
        var rule = theme.global.app_divider;
        rule[3] *= 0.4;
        fill(cr, .{ .x = list.x, .y = y + row_h - 1, .w = content_w, .h = 1 }, rule);
    }
    c.cairo_restore(cr);
    // Column rules continue through the header and body, beneath row feedback.
    var rule = theme.global.app_divider;
    rule[3] *= 0.65;
    for (self.headers[1..]) |header| fill(cr, .{
        .x = header.computed_x - 0.5,
        .y = self.sections[2].computed_y,
        .w = 1,
        .h = list.y + list.h - self.sections[2].computed_y,
    }, rule);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, list.x, list.y, list.w, list.h);
    c.cairo_clip(cr);
    const snap = self.model.snapshot orelse {
        app.textBox(cr, tr("Collecting processes…"), .{ .x = list.x + pad, .y = list.y + 12, .w = content_w - 2 * pad, .h = row_h }, cairo.textSize(), false, theme.global.window_fg);
        return;
    };
    // One scale for every resident-memory bar, independent of filtering or
    // scrolling. CPU fills at one core; numeric values can exceed 100%.
    var memory_max: u64 = 1;
    for (snap.processes) |row| memory_max = @max(memory_max, row.resident_bytes orelse 0);
    const hover = self.row_hover.frame;
    if (hover.alpha > 0) cairo.drawItemHighlight(cr, self.rowBox(hover.row), false, hover.alpha, hover.alpha);
    for (first..last) |i| {
        const row = snap.processes[self.model.rows.items[i]];
        const y: f32 = @floatCast(list.y + @as(f64, @floatFromInt(i)) * row_h - self.model.scroll);
        for (self.selections.items) |selection| if (selection.identity.eql(row.identity)) {
            cairo.drawItemHighlight(cr, self.rowBox(@floatFromInt(i)), true, selection.fade.alpha, selection.fade.alpha);
            break;
        };
        var pid_buf: [32]u8 = undefined;
        var cpu_buf: [32]u8 = undefined;
        var mem_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{row.identity.pid}) catch "—";
        const cpu = if (row.cpu_percent) |v| std.fmt.bufPrint(&cpu_buf, "{d:.1}%", .{v}) catch "—" else "—";
        const memory = if (row.resident_bytes) |v| app.bytesLabel(&mem_buf, v) else "—";
        var name_box = cell(self, 0, y);
        const icon_box: Rect = .{ .x = name_box.x, .y = y + 6, .w = 20, .h = 20 };
        if (cairo.Layer.begin(cr, icon_box)) |value| {
            var layer = value;
            layer.renderer.drawIcon(0, 0, 20, 20, .{ .id = processIcon(row.name), .color = theme.global.app_icon });
            layer.finish();
        }
        name_box.x += 30;
        name_box.w = @max(0, name_box.w - 30);
        label(cr, row.name, name_box);
        label(cr, pid, cell(self, 1, y));
        label(cr, row.user, cell(self, 2, y));
        usage(cr, cpu, cell(self, 3, y), if (row.cpu_percent) |v| v / 100 else null, "999.9%");
        usage(cr, memory, cell(self, 4, y), if (row.resident_bytes) |v| @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(memory_max)) else null, "999.9 MiB");
        var state_box = cell(self, 5, y);
        cairo.setSource(cr, stateColor(row.state));
        c.cairo_arc(cr, state_box.x + 4, y + row_h / 2, 3.5, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
        state_box.x += 16;
        state_box.w = @max(0, state_box.w - 16);
        label(cr, stateName(row.state), state_box);
    }
    if (count == 0) label(cr, if (snap.failed) tr("Process data unavailable") else tr("No matching processes"), .{ .x = list.x + pad, .y = list.y + 12, .w = content_w - 2 * pad, .h = row_h });
    if (self.barGeometry()) |g| cairo.drawScrollbar(cr, scrollbar.look(g, self.bar, theme.global.scrollbar_width, theme.global));
}

fn cell(self: *const App, column: usize, y: f32) Rect {
    const header = self.headers[column];
    return .{ .x = header.computed_x + pad, .y = y, .w = @max(0, header.computed_width - 2 * pad), .h = row_h };
}

fn label(cr: *c.cairo_t, value: []const u8, box: Rect) void {
    app.textBox(cr, value, box, cairo.textSize(), false, theme.global.window_fg);
}

fn usage(cr: *c.cairo_t, value: []const u8, box: Rect, fraction: ?f64, sample: []const u8) void {
    const text_w: f32 = @floatCast(@max(cairo.measureText(cr, sample, cairo.textSize(), false), cairo.measureText(cr, value, cairo.textSize(), false)));
    const bar_w = box.w - text_w - 12;
    if (bar_w < 28) return label(cr, value, box);
    label(cr, value, .{ .x = box.x, .y = box.y, .w = text_w, .h = box.h });
    if (fraction == null) return;
    const track: Rect = .{ .x = box.x + text_w + 12, .y = box.y + (box.h - 6) / 2, .w = bar_w, .h = 6 };
    roundPath(cr, track, 3);
    cairo.setSource(cr, theme.global.app_divider);
    c.cairo_fill(cr);
    const amount: f32 = @floatCast(std.math.clamp(fraction.?, 0, 1));
    if (amount <= 0) return;
    var bar = track;
    bar.w = @min(track.w, @max(3, track.w * amount));
    roundPath(cr, bar, @min(3, bar.w / 2));
    cairo.setSource(cr, theme.shellPalette().accent);
    c.cairo_fill(cr);
}

fn processIcon(name: []const u8) ui.layout.IconId {
    const known = .{
        .{ "rediwm-monitor", .power_performance }, .{ "rediwm-session", .display },
        .{ "rediwm-files", .folder },              .{ "rediwm-editor", .edit },
        .{ "rediwm", .settings },                  .{ "systemd", .settings },
        .{ "kitty", .terminal },                   .{ "foot", .terminal },
        .{ "bash", .terminal },                    .{ "zsh", .terminal },
        .{ "zig", .terminal },                     .{ "codex", .terminal },
        .{ "firefox", .browser },                  .{ "chromium", .browser },
        .{ "(sd-pam)", .lock },                    .{ "dbus-broker", .drive },
    };
    inline for (known) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return .generic;
}

fn stateColor(state: u8) [4]f32 {
    return switch (state) {
        'R' => theme.global.app_git_added,
        'S', 'I' => theme.global.terminal_blue orelse .{ 0.38, 0.72, 0.96, 1 },
        'D', 'T', 't' => theme.global.terminal_yellow orelse .{ 0.96, 0.75, 0.35, 1 },
        'Z', 'X', 'x' => theme.global.danger,
        else => theme.global.app_icon,
    };
}

fn fill(cr: *c.cairo_t, box: Rect, color: [4]f32) void {
    cairo.setSource(cr, color);
    c.cairo_rectangle(cr, box.x, box.y, box.w, box.h);
    c.cairo_fill(cr);
}

fn roundPath(cr: *c.cairo_t, box: Rect, radius: f32) void {
    const r = @min(radius, @min(box.w, box.h) / 2);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, box.x + box.w - r, box.y + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, box.x + box.w - r, box.y + box.h - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, box.x + r, box.y + box.h - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, box.x + r, box.y + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

fn stateName(state: u8) []const u8 {
    return switch (state) {
        'R' => tr("Running"),
        'S' => tr("Sleeping"),
        'D' => tr("Disk wait"),
        'T', 't' => tr("Stopped"),
        'Z' => tr("Zombie"),
        'I' => tr("Idle"),
        'X', 'x' => tr("Exited"),
        else => tr("Unknown"),
    };
}
