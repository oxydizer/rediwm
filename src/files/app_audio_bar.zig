//! Compact now-playing controls, independent of the folder being browsed.
const std = @import("std");
const App = @import("app.zig").App;
const header = @import("header.zig");
const draw = @import("app_draw.zig");
const ui = @import("ui");
const c = @import("c.zig").api;
const scrollbar = ui.widgets.scrollbar;
const playlist = @import("app_audio_playlist.zig");

pub const State = struct {
    drag: scrollbar.Drag = .{},
    appearance: scrollbar.Appearance = .{},
    preview: f32 = 0,
    playlist: ?@import("player_link.zig").Playlist = null,
    playlist_open: bool = false,
    playlist_selected: usize = 0,
    playlist_first: usize = 0,
    playlist_drag: scrollbar.Drag = .{},
    playlist_wheel: f64 = 0,
};

const tr = @import("i18n").tr;

pub fn visible(self: *App) bool {
    return self.chooser == null and !self.transfer_view.active and self.audio_link != null and self.audio_state.status != .none;
}

pub fn extraHeight(self: *App) i32 {
    if (!visible(self)) return 0;
    return if (inlineWidth(self) >= 340) 0 else 44;
}

/// Below this width the title and time stack above the slider instead of
/// sharing its row.
const single_row_min = 520;

fn inlineWidth(self: *App) f64 {
    const right = header.rect(self.w, self.inRepository(), if (self.inRepository()) .git_view else .grid);
    return right.x - 292;
}

/// A stacked bar is 4 px taller, about the toolbar's midline, so the Settings
/// thumb clears the title.
pub fn rect(self: *App) ?header.Rect {
    if (!visible(self)) return null;
    if (extraHeight(self) == 0) {
        const w = inlineWidth(self);
        return if (w < single_row_min) .{ .x = 284, .y = 62, .w = w, .h = 40 } else .{ .x = 284, .y = 64, .w = w, .h = 36 };
    }
    const w: f64 = @floatFromInt(self.w - 32);
    return .{ .x = 16, .y = @floatFromInt(header.height(self.w, self.inRepository())), .w = w, .h = if (w < single_row_min) 40 else 36 };
}

/// Controls, in hit-test order; the value is the hover-key offset from 920.
const Id = enum(usize) { play = 0, stop = 1, slider = 2, playlist = 3, previous = 4, next = 5 };
const count = std.enums.values(Id).len;

/// Left to right: Previous, Play, Next, the title, the slider, the time
/// readout, Stop and Playlist. A narrow bar stacks the title and time
/// above the slider.
const Layout = struct {
    stacked: bool,
    title_x: f64,
    title_w: f64,
    slider_x: f64,
    slider_w: f64,
    time_x: f64,
    time_w: f64,
};

const time_size = 13;
const time_sample = "00:00 / 00:00";

fn arrange(r: header.Rect) Layout {
    const title_x = r.x + 112;
    const end = r.x + r.w - 82;
    if (r.w < single_row_min) {
        const time_w: f64 = ui.paint.labelWidth(time_sample, @floatCast(ui.cairo.statusSize()));
        const content_w = @max(0, end - title_x);
        return .{ .stacked = true, .title_x = title_x, .title_w = @max(0, content_w - time_w - 8), .slider_x = title_x + 6, .slider_w = @max(0, content_w - 12), .time_x = end - time_w, .time_w = time_w };
    }
    const pill_w: f64 = @as(f64, ui.paint.labelWidth(time_sample, time_size)) + 22;
    const pill_x = end - pill_w;
    const room = @max(0, pill_x - 14 - title_x);
    const title_w = std.math.clamp(room * 0.36, @min(room, 72), 240);
    const slider_x = title_x + title_w + 14;
    return .{ .stacked = false, .title_x = title_x, .title_w = title_w, .slider_x = slider_x, .slider_w = @max(0, pill_x - 14 - slider_x), .time_x = pill_x, .time_w = pill_w };
}

fn box(r: header.Rect, id: Id) header.Rect {
    const l = arrange(r);
    const small = r.y + (r.h - 28) / 2;
    const large = r.y + (r.h - 32) / 2;
    return switch (id) {
        .previous => .{ .x = r.x + 6, .y = small, .w = 28, .h = 28 },
        .play => .{ .x = r.x + 38, .y = large, .w = 32, .h = 32 },
        .next => .{ .x = r.x + 74, .y = small, .w = 28, .h = 28 },
        .slider => if (l.stacked) .{ .x = l.slider_x, .y = r.y + r.h - 21, .w = l.slider_w, .h = 20 } else .{ .x = l.slider_x, .y = large, .w = l.slider_w, .h = 32 },
        .stop => .{ .x = r.x + r.w - 72, .y = large, .w = 32, .h = 32 },
        .playlist => .{ .x = r.x + r.w - 38, .y = large, .w = 32, .h = 32 },
    };
}

fn control(self: *App, id: Id) ?ui.layout.Widget {
    const b = box(rect(self) orelse return null, id);
    return .{
        .kind = .{ .slider = .{ .owner = self, .value = fraction(self), .min = 0, .max = 1, .style = .settings, .feel = self.audio_bar.appearance, .on_change = previewChanged } },
        .computed_x = @floatCast(b.x),
        .computed_y = @floatCast(b.y),
        .computed_width = @floatCast(b.w),
        .computed_height = @floatCast(b.h),
    };
}

/// Previous restarts a track that has played a while, as players do.
const restart_after_s = 3;

fn elapsedSeconds(self: *App) f64 {
    return @as(f64, fraction(self)) * @as(f64, @floatFromInt(self.audio_state.length_us)) / 1_000_000;
}

fn enabled(self: *App, id: Id) bool {
    return switch (id) {
        .slider => self.audio_state.length_us > 0,
        .next => playlist.neighbour(self, 1) != null,
        .previous => playlist.neighbour(self, -1) != null or elapsedSeconds(self) >= 0.5,
        else => true,
    };
}

fn fraction(self: *App) f32 {
    return if (self.audio_bar.drag.active) self.audio_bar.preview else @floatCast(self.audio_state.fraction(draw.nowMs()));
}

fn previewChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const self: *App = @ptrCast(@alignCast(owner orelse return));
    self.audio_bar.preview = value;
}

fn seek(self: *App, value: f32) void {
    const link = self.audio_link orelse return;
    const delta = (@as(f64, value) - self.audio_state.fraction(draw.nowMs())) * @as(f64, @floatFromInt(self.audio_state.length_us));
    link.seek(@intFromFloat(delta));
}

pub fn motion(self: *App, x: f64, y: f64) bool {
    if (!self.audio_bar.drag.active) return false;
    var widget = control(self, .slider) orelse {
        self.audio_bar.drag.end();
        return false;
    };
    self.mouse_x = x;
    self.mouse_y = y;
    ui.widgets.slider.setFromPointer(&widget, @floatCast(x));
    if (rect(self)) |r| self.addDamage(r);
    return true;
}

pub fn release(self: *App) bool {
    if (!self.audio_bar.drag.active) return false;
    const value = self.audio_bar.preview;
    self.audio_bar.drag.end();
    seek(self, value);
    if (rect(self)) |r| self.addDamage(r);
    return true;
}

pub fn step(self: *App, now: i64) void {
    const seekable = visible(self) and self.audio_state.length_us > 0;
    const hovered = hit(self, self.mouse_x, self.mouse_y) == @intFromEnum(Id.slider);
    if (self.audio_bar.appearance.step(now, false, hovered, self.audio_bar.drag.active, seekable)) {
        if (rect(self)) |r| self.addDamage(r);
    }
}

pub fn deadline(self: *App) ?i64 {
    if (!visible(self)) return null;
    return if (self.audio_bar.appearance.active) draw.nowMs() + 16 else self.audio_bar.appearance.deadline;
}

pub fn hit(self: *App, x: f64, y: f64) ?usize {
    if (self.dialog != null or self.menu != null or self.drag_origin != null or self.selection_band != null) return null;
    for (0..count) |index| {
        const id: Id = @enumFromInt(index);
        if (!enabled(self, id)) continue;
        const widget = control(self, id) orelse return null;
        if (widget.contains(@floatCast(x), @floatCast(y))) return index;
    }
    return null;
}

pub fn click(self: *App, x: f64, y: f64) bool {
    const index = hit(self, x, y) orelse return false;
    const link = self.audio_link orelse return false;
    switch (@as(Id, @enumFromInt(index))) {
        .play => link.playPause(),
        .stop => link.stopPlayback(),
        .playlist => playlist.toggle(self),
        .next => playlist.skip(self, 1),
        .previous => {
            const elapsed = elapsedSeconds(self);
            if (elapsed >= restart_after_s or playlist.neighbour(self, -1) == null) {
                link.seek(-@as(i64, @intFromFloat(elapsed * 1_000_000)));
            } else playlist.skip(self, -1);
        },
        .slider => {
            self.audio_bar.preview = fraction(self);
            self.audio_bar.drag.active = true;
            _ = motion(self, x, y);
            if (rect(self)) |r| self.addDamage(r);
        },
    }
    return true;
}

pub fn paint(self: *App, cr: *c.cairo_t) void {
    const r = rect(self) orelse return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
    c.cairo_clip(cr);
    const t = ui.theme.global;
    draw.setSource(cr, t.app_divider);
    draw.roundedRect(cr, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1, (r.h - 1) / 2);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
    const l = arrange(r);
    const size = if (l.stacked) ui.cairo.statusSize() else ui.cairo.textSize();
    const metrics = draw.fontMetrics(cr, size);
    const baseline = if (l.stacked) r.y + 4 + metrics.ascent else r.y + (r.h + metrics.ascent - metrics.descent) / 2;
    draw.setSource(cr, t.window_fg);
    draw.drawEllipsis(cr, std.fs.path.basename(self.audio_state.file()), l.title_x, baseline, l.title_w, size, true);
    var time_buf: [64]u8 = undefined;
    const duration: u64 = @intCast(@max(0, @divTrunc(self.audio_state.length_us, 1_000_000)));
    const elapsed: u64 = @intFromFloat(@as(f64, fraction(self)) * @as(f64, @floatFromInt(duration)));
    const time = std.fmt.bufPrint(&time_buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{ @divTrunc(elapsed, 60), @mod(elapsed, 60), @divTrunc(duration, 60), @mod(duration, 60) }) catch "";
    if (l.stacked) {
        const width = draw.measureText(cr, time, size, false);
        draw.drawEllipsis(cr, time, l.time_x + @max(0, l.time_w - width), baseline, l.time_w, size, false);
    }

    const hovered = hit(self, self.mouse_x, self.mouse_y);
    const playing = self.audio_state.status == .playing;
    for (0..count) |index| {
        const id: Id = @enumFromInt(index);
        var widget = control(self, id).?;
        if (id == .slider) {
            if (!enabled(self, id) or widget.computed_width < 24) continue;
            // The thumb overhangs the track's ends by half its width.
            const overhang: f32 = 8;
            var layer = ui.cairo.Layer.begin(cr, .{ .x = widget.computed_x - overhang, .y = widget.computed_y, .w = widget.computed_width + 2 * overhang, .h = widget.computed_height }) orelse continue;
            defer layer.finish();
            widget.computed_x = overhang;
            widget.computed_y = 0;
            ui.paint.paintSlider(&widget, widget.kind.slider, &layer.renderer);
            continue;
        }
        const b = box(r, id);
        var layer = ui.cairo.Layer.begin(cr, .{ .x = @floatCast(b.x), .y = @floatCast(b.y), .w = @floatCast(b.w), .h = @floatCast(b.h) }) orelse continue;
        defer layer.finish();
        ui.widgets.button.paint(&layer.renderer, layer.local(), .{
            .variant = if (id == .play) .primary else .ghost,
            .radius = @floatCast(b.h / 2),
            .icon = switch (id) {
                .previous => .skip_previous,
                .next => .skip_next,
                .stop => .stop,
                .playlist => .view_list,
                else => if (playing) .pause else .play,
            },
            .icon_scale = if (id == .play) 0.42 else 0.5,
            .label = switch (id) {
                .previous => tr("Previous"),
                .next => tr("Next"),
                .stop => tr("Stop"),
                .playlist => tr("Playlist"),
                else => if (playing) tr("Pause") else tr("Play"),
            },
        }, .{
            .selected = id == .playlist and self.audio_bar.playlist_open,
            .pointer = if (!enabled(self, id)) .disabled else if (hovered == index) .hover else .idle,
        });
    }

    // On one row the time sits in the Settings value pill.
    if (l.stacked) return;
    var pill = ui.widgets.slider.valuePill(time, time_size, t.window_fg);
    pill.kind.text.glow = if (self.audio_bar.drag.active) self.audio_bar.appearance.accent else 0;
    const pill_h: f64 = 26;
    var layer = ui.cairo.Layer.begin(cr, .{ .x = @floatCast(l.time_x), .y = @floatCast(r.y + (r.h - pill_h) / 2), .w = @floatCast(l.time_w), .h = pill_h }) orelse return;
    defer layer.finish();
    pill.computed_width = @floatCast(l.time_w);
    pill.computed_height = @floatCast(pill_h);
    ui.paint.paintPill(&pill, pill.kind.text, &layer.renderer);
}
