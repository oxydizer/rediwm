//! What the Transfers panel lists: the total speed graph under the header,
//! a row per running job (the selected one expanded with its own speed and
//! destination) and the finished jobs.
const i18n = @import("i18n");
const std = @import("std");
const paint = @import("ui").paint;
const theme = @import("ui").theme;
const button = @import("ui").widgets.button;
const Rect = @import("ui").widgets.field.Rect;
const IconId = @import("ui").layout.IconId;
const model_mod = @import("model.zig");
const glyphs = @import("glyphs.zig");
const popup_mod = @import("popup.zig");
const Popup = popup_mod.Popup;
const Job = model_mod.Job;
const width = popup_mod.width;

const row_height: f32 = 78;
const drawer_height: f32 = 104;
const done_heading: f32 = 34;
const done_height: f32 = 54;
const empty_height: f32 = 132;
const text_x: f32 = 58;
const right: f32 = width - 24;
const mono_size: f32 = 11.5;

pub fn contentHeight(popup: *const Popup, model: *const model_mod.Model) f32 {
    const live = model.liveJobs();
    const done = model.doneJobs();
    if (live.len == 0 and done.len == 0) return empty_height;
    var h: f32 = 6;
    for (live) |*job| h += row_height + (if (popup.selected == job.id) drawer_height else 0);
    if (done.len > 0) h += done_heading + @as(f32, @floatFromInt(done.len)) * done_height;
    return h + 6;
}

/// The last minute's total speed, between the header and the list.
pub fn paintTotal(r: *paint.Renderer, model: *const model_mod.Model) void {
    const t = r.palette.?;
    const top = popup_mod.header;
    const s = model.summary();
    var rate_buf: [32]u8 = undefined;
    const rate = speed(&rate_buf, s.rate);
    r.drawText(24, top + 10, 180, 26, .{ .content = rate, .font_size = 16, .weight = 700, .color = t.accent, .family = .mono });
    rightText(r, right, top + 13, i18n.tr("Last minute"), 11, t.window_dim, .sans);
    const area: Rect = .{ .x = 24, .y = top + 44, .w = width - 48, .h = 52 };
    r.fillRect(area.x - 6, area.y - 6, area.w + 12, area.h + 12, .{ .color = inset(t), .radius = 7 });
    var grid = t.window_dim;
    grid[3] *= 0.18;
    glyphs.dashes(r, area.x, area.y, area.w, grid);
    glyphs.dashes(r, area.x, area.y + area.h / 2, area.w, grid);
    const peak = model.total.peak();
    if (peak > 0) {
        var peak_buf: [48]u8 = undefined;
        var value_buf: [32]u8 = undefined;
        const label = i18n.fmt(&peak_buf, i18n.tr("Peak {speed}"), .{ .speed = speed(&value_buf, peak) }) catch "";
        rightText(r, area.x + area.w - 2, area.y - 2, label, 10, t.window_dim, .mono);
    }
    glyphs.graph(r, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h, .slots = model_mod.history_len, .top = niceTop(peak), .line = t.accent }, model.total.values());
    r.fillRect(20, top + graph_bottom - 1, width - 40, 1, .{ .color = t.border });
}

const graph_bottom = popup_mod.graph_height;

pub fn paintList(popup: *Popup, r: *paint.Renderer, model: *const model_mod.Model) void {
    const t = r.palette.?;
    const live = model.liveJobs();
    const done = model.doneJobs();
    var y = popup.list_top - popup.scroll;
    if (live.len == 0 and done.len == 0) {
        r.fillRect(width / 2 - 22, y + 20, 44, 44, .{ .color = t.surface_hover, .radius = 22 });
        glyphs.strokes(r, width / 2 - 12, y + 30, 24, &glyphs.arrow_down, 2, t.window_dim);
        r.drawTextCentered(24, y + 72, width - 48, 22, .{ .content = i18n.tr("No transfers"), .font_size = 14, .weight = 600, .color = t.window_fg });
        r.drawTextCentered(24, y + 96, width - 48, 20, .{ .content = i18n.tr("Copies, moves and extractions in Files appear here."), .font_size = 11.5, .color = t.window_dim });
        return;
    }
    y += 6;
    for (live) |*job| {
        const expanded = popup.selected == job.id;
        const h = row_height + (if (expanded) drawer_height else 0);
        paintRow(popup, r, job, y, h, expanded);
        y += h;
    }
    if (done.len == 0) return;
    r.drawText(28, y + 8, 200, 22, .{ .content = i18n.tr("Finished"), .font_size = 12, .weight = 700, .color = t.window_dim });
    y += done_heading;
    for (done) |*job| {
        paintDone(popup, r, job, y);
        y += done_height;
    }
}

fn paintRow(popup: *Popup, r: *paint.Renderer, job: *const Job, y: f32, h: f32, expanded: bool) void {
    const t = r.palette.?;
    const row_box: Rect = .{ .x = 12, .y = y, .w = width - 24, .h = h };
    const row_state = popup.addHit(.{ .x = row_box.x, .y = y, .w = row_box.w, .h = row_height }, .row, job.id);
    if (expanded or row_state.pointer == .hover or row_state.focused) {
        r.fillRect(row_box.x, y + 2, row_box.w, h - 4, .{ .color = t.surface_hover, .radius = 8, .border_width = if (row_state.focused) 1 else 0, .border_color = t.border_focus });
    }
    if (expanded) r.fillRect(row_box.x + 4, y + 14, 3, row_height - 28, .{ .color = t.accent, .radius = 1.5 });
    r.drawIcon(28, y + 12, 18, 18, .{ .id = kindIcon(job.kind), .color = t.window_dim });
    // Buttons first, so the label knows how much room is left.
    var buttons_left = right;
    const cancel_armed = popup.armed_cancel == job.id;
    if (!job.state.isTerminal() and !job.cancel_requested) {
        const cancel_w: f32 = if (cancel_armed) 74 else 30;
        buttons_left -= cancel_w;
        const cancel_box: Rect = .{ .x = buttons_left, .y = y + 6, .w = cancel_w, .h = 30 };
        const state = popup.addHit(cancel_box, .cancel, job.id);
        if (cancel_armed) {
            button.paint(r, cancel_box, .{ .size = .sm, .label = i18n.tr("Cancel"), .destructive = true }, state);
        } else button.paint(r, cancel_box, .{ .variant = .ghost, .size = .sm, .icon = .close, .label = i18n.tr("Cancel"), .icon_scale = 0.5 }, state);
        buttons_left -= 4;
        if (job.conflict) {
            buttons_left -= 84;
            const resolve_box: Rect = .{ .x = buttons_left, .y = y + 6, .w = 84, .h = 30 };
            button.paint(r, resolve_box, .{ .variant = .primary, .size = .sm, .label = i18n.tr("Resolve…") }, popup.addHit(resolve_box, .resolve, job.id));
        } else if (job.state != .planning and job.state != .finalizing) {
            buttons_left -= 30;
            const pause_box: Rect = .{ .x = buttons_left, .y = y + 6, .w = 30, .h = 30 };
            const paused = job.state == .paused;
            button.paint(r, pause_box, .{ .variant = .ghost, .size = .sm, .icon = if (paused) .play else .pause, .label = if (paused) i18n.tr("Resume") else i18n.tr("Pause"), .icon_scale = 0.5 }, popup.addHit(pause_box, .pause, job.id));
        }
    }
    var label_buf: [192]u8 = undefined;
    r.drawText(text_x, y + 9, buttons_left - text_x - 8, 24, .{ .content = jobLabel(&label_buf, job), .font_size = 13.5, .weight = 600, .color = t.window_fg });
    // The stats line: never cut, so the speed sits apart on the right.
    var stats_buf: [160]u8 = undefined;
    const stats = statusLine(&stats_buf, job);
    const attention = job.conflict or job.waiting_for.len > 0;
    var speed_buf: [32]u8 = undefined;
    const speed_text: []const u8 = if (job.state == .running and !model_mod.countsItems(job.kind) and job.rate > 0) speed(&speed_buf, job.rate) else "";
    const speed_w = if (speed_text.len > 0) textWidth(r, speed_text, mono_size, .mono) + 12 else 0;
    r.drawText(text_x, y + 34, right - text_x - speed_w, 20, .{ .content = stats, .font_size = mono_size, .color = if (attention) t.accent else t.window_dim, .family = .mono });
    if (speed_text.len > 0) rightText(r, right, y + 34, speed_text, mono_size, t.window_fg, .mono);
    // Progress: a thin bar and its percentage.
    const bar_w = right - text_x - 44;
    r.fillRect(text_x, y + 60, bar_w, 4, .{ .color = inset(t), .radius = 2 });
    if (job.fraction()) |f| {
        const fill = switch (job.state) {
            .paused => t.faint,
            .failed => t.danger,
            .completed, .completed_with_errors => success(),
            else => t.accent,
        };
        if (f > 0) r.fillRect(text_x, y + 60, @max(4, bar_w * f), 4, .{ .color = fill, .radius = 2 });
        var pct_buf: [8]u8 = undefined;
        rightText(r, right, y + 53, std.fmt.bufPrint(&pct_buf, "{d}%", .{@as(u32, @intFromFloat(@floor(f * 100)))}) catch "", 11, t.window_dim, .mono);
    }
    if (expanded) paintDrawer(popup, r, job, y + row_height);
}

/// The expanded row's speed over the last minute and where it writes.
fn paintDrawer(popup: *Popup, r: *paint.Renderer, job: *const Job, y: f32) void {
    const t = r.palette.?;
    const card: Rect = .{ .x = text_x - 6, .y = y, .w = right - text_x + 6, .h = 66 };
    r.fillRect(card.x, card.y, card.w, card.h, .{ .color = inset(t), .radius = 6, .border_width = 1, .border_color = t.border_soft });
    r.drawText(card.x + 10, card.y + 6, 120, 16, .{ .content = i18n.tr("Speed"), .font_size = 10.5, .color = t.window_dim, .family = .mono });
    const history = &job.history;
    if (history.count > 0) {
        var avg_buf: [32]u8 = undefined;
        var peak_buf: [32]u8 = undefined;
        var line_buf: [96]u8 = undefined;
        const line = i18n.fmt(&line_buf, i18n.tr("Avg {average} · Peak {peak}"), .{ .average = speed(&avg_buf, history.average()), .peak = speed(&peak_buf, history.peak()) }) catch "";
        rightText(r, card.x + card.w - 10, card.y + 6, line, 10.5, t.window_dim, .mono);
    }
    const area: Rect = .{ .x = card.x + 10, .y = card.y + 26, .w = card.w - 20, .h = 32 };
    var grid = t.window_dim;
    grid[3] *= 0.15;
    glyphs.dashes(r, area.x, area.y + area.h / 2, area.w, grid);
    const color = if (job.state == .paused) t.faint else t.accent;
    glyphs.graph(r, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h, .slots = model_mod.history_len, .top = niceTop(history.peak()), .line = color, .line_width = 1.3 }, history.values());
    if (job.destination.len == 0) return;
    var path_buf: [300]u8 = undefined;
    const path = model_mod.shortPath(&path_buf, job.destination.slice(), popup_mod.home());
    const box: Rect = .{ .x = card.x, .y = y + 72, .w = card.w, .h = 28 };
    const state = popup.addHit(box, .destination, job.id);
    button.paint(r, box, .{ .variant = .ghost, .size = .sm, .leading_icon = .folder, .label = path, .alignment = .left }, state);
}

fn paintDone(popup: *Popup, r: *paint.Renderer, job: *const Job, y: f32) void {
    const t = r.palette.?;
    const has_place = job.destination.len > 0;
    const row_box: Rect = .{ .x = 12, .y = y, .w = width - 24, .h = done_height };
    const state = if (has_place) popup.addHit(row_box, .done_row, job.id) else button.State{};
    if (state.pointer == .hover or state.focused) r.fillRect(row_box.x, y + 2, row_box.w, done_height - 4, .{ .color = t.surface_hover, .radius = 8, .border_width = if (state.focused) 1 else 0, .border_color = t.border_focus });
    const failed = job.state == .failed;
    const partial = job.state == .completed_with_errors;
    r.drawIcon(28, y + 10, 18, 18, .{ .id = if (failed) .close else .checkmark, .color = if (failed) t.danger else if (partial) t.accent else success() });
    var label_buf: [192]u8 = undefined;
    r.drawText(text_x, y + 7, right - text_x - 4, 22, .{ .content = jobLabel(&label_buf, job), .font_size = 13, .color = t.window_fg });
    var line_buf: [400]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    var path_buf: [300]u8 = undefined;
    const outcome = if (failed) i18n.tr("Failed") else if (partial) i18n.tr("Finished with errors") else i18n.tr("Done");
    const amount: []const u8 = if (model_mod.countsItems(job.kind) or job.total_bytes == 0) "" else model_mod.formatBytes(&size_buf, job.total_bytes);
    const place: []const u8 = if (has_place) model_mod.shortPath(&path_buf, job.destination.slice(), popup_mod.home()) else "";
    const line = if (amount.len > 0 and place.len > 0)
        std.fmt.bufPrint(&line_buf, "{s} · {s} · {s}", .{ outcome, amount, place }) catch outcome
    else if (amount.len > 0 or place.len > 0)
        std.fmt.bufPrint(&line_buf, "{s} · {s}", .{ outcome, if (amount.len > 0) amount else place }) catch outcome
    else
        outcome;
    r.drawText(text_x, y + 29, right - text_x - 4, 18, .{ .content = line, .font_size = 11, .color = if (failed) t.danger else t.window_dim, .family = .mono });
}

/// "photo.jpg", or "photo.jpg and 3 more".
fn jobLabel(buf: []u8, job: *const Job) []const u8 {
    const name = job.label.slice();
    if (job.source_count <= 1) return name;
    return i18n.fmt(buf, i18n.tr("{name} and {count} more"), .{ .name = name, .count = job.source_count - 1 }) catch name;
}

/// What a running row says under its name.
fn statusLine(buf: []u8, job: *const Job) []const u8 {
    if (job.conflict) return i18n.tr("A file already exists");
    if (job.cancel_requested) return i18n.tr("Cancelling…");
    if (job.waiting_for.len > 0) return i18n.fmt(buf, i18n.tr("Waiting for {place}…"), .{ .place = job.waiting_for.slice() }) catch "";
    switch (job.state) {
        .planning => return i18n.tr("Counting…"),
        .queued => return i18n.tr("Queued"),
        .finalizing => return i18n.tr("Finishing…"),
        .completed => return i18n.tr("Done"),
        .completed_with_errors => return i18n.tr("Finished with errors"),
        .failed => return i18n.tr("Failed"),
        .cancelled => return i18n.tr("Cancelled"),
        else => {},
    }
    var amount_buf: [80]u8 = undefined;
    const amount = if (model_mod.countsItems(job.kind) or job.total_bytes == 0)
        i18n.fmt(&amount_buf, i18n.tr("{done} of {total} items"), .{ .done = job.completed_items, .total = job.total_items }) catch ""
    else blk: {
        var done_buf: [24]u8 = undefined;
        var total_buf: [24]u8 = undefined;
        break :blk std.fmt.bufPrint(&amount_buf, "{s} / {s}", .{ model_mod.formatBytes(&done_buf, job.completed_bytes), model_mod.formatBytes(&total_buf, job.total_bytes) }) catch "";
    };
    if (job.state == .paused) return std.fmt.bufPrint(buf, "{s} · {s}", .{ amount, i18n.tr("Paused") }) catch amount;
    if (job.etaSeconds()) |seconds| {
        var eta_buf: [24]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s} · {s}", .{ amount, model_mod.formatDuration(&eta_buf, seconds) }) catch amount;
    }
    @memcpy(buf[0..amount.len], amount);
    return buf[0..amount.len];
}

fn kindIcon(kind: model_mod.Kind) IconId {
    return switch (kind) {
        .copy => .copy,
        .move => .cut,
        .extract => .open,
        .delete => .trash,
        .trash, .empty_trash => .trash_can,
        .other => .generic,
    };
}

fn speed(buf: []u8, rate: u64) []const u8 {
    var bytes_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/s", .{model_mod.formatBytes(&bytes_buf, rate)}) catch "";
}

/// A graph's ceiling a little above its peak, so the line never touches it.
fn niceTop(peak: u64) u64 {
    return if (peak == 0) 1 else peak + peak / 5;
}

fn success() [4]f32 {
    return theme.global.success orelse .{ 52.0 / 255.0, 168.0 / 255.0, 83.0 / 255.0, 1 };
}

/// Tracks and graph wells: a shade under the panel, lighter on light themes.
fn inset(t: theme.Theme) [4]f32 {
    const fg = t.window_fg;
    const light_text = fg[0] * 0.2126 + fg[1] * 0.7152 + fg[2] * 0.0722 > 0.5;
    return .{ 0, 0, 0, if (light_text) 0.22 else 0.06 };
}

fn textWidth(r: *const paint.Renderer, value: []const u8, size: f32, family: @import("ui").layout.TextFamily) f32 {
    return r.textWidth(.{ .content = value, .font_size = size, .color = .{ 0, 0, 0, 1 }, .family = family });
}

fn rightText(r: *paint.Renderer, x_right: f32, y: f32, value: []const u8, size: f32, color: [4]f32, family: @import("ui").layout.TextFamily) void {
    const w = textWidth(r, value, size, family);
    r.drawText(x_right - w - 1, y, w + 2, size + 8, .{ .content = value, .font_size = size, .color = color, .family = family });
}
