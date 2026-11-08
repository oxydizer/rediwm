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

fn inlineWidth(self: *App) f64 {
    const right = header.rect(self.w, self.inRepository(), if (self.inRepository()) .git_view else .grid);
    return right.x - 292;
}

pub fn rect(self: *App) ?header.Rect {
    if (!visible(self)) return null;
    if (extraHeight(self) == 0) return .{ .x = 284, .y = 64, .w = inlineWidth(self), .h = 36 };
    return .{ .x = 16, .y = @floatFromInt(header.height(self.w, self.inRepository())), .w = @floatFromInt(self.w - 32), .h = 36 };
}

fn control(self: *App, id: usize) ?ui.layout.Widget {
    const r = rect(self) orelse return null;
    const x = if (id == 0) r.x + 6 else if (id == 1) r.x + 42 else if (id == 3) r.x + r.w - 38 else r.x + 84;
    return .{
        .kind = .{ .slider = .{ .owner = self, .value = fraction(self), .min = 0, .max = 1, .style = .settings, .feel = self.audio_bar.appearance, .on_change = previewChanged } },
        .computed_x = @floatCast(x),
        .computed_y = @floatCast(r.y + if (id == 2) @as(f64, 20) else 2),
        .computed_width = @floatCast(if (id == 2) r.w - 242 else 32),
        .computed_height = if (id == 2) 14 else 32,
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
    var widget = control(self, 2) orelse {
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
    const enabled = visible(self) and self.audio_state.length_us > 0;
    const hovered = hit(self, self.mouse_x, self.mouse_y) == 2;
    if (self.audio_bar.appearance.step(now, false, hovered, self.audio_bar.drag.active, enabled)) {
        if (rect(self)) |r| self.addDamage(r);
    }
}

pub fn deadline(self: *App) ?i64 {
    if (!visible(self)) return null;
    return if (self.audio_bar.appearance.active) draw.nowMs() + 16 else self.audio_bar.appearance.deadline;
}

pub fn hit(self: *App, x: f64, y: f64) ?usize {
    if (self.dialog != null or self.menu != null or self.drag_origin != null or self.selection_band != null) return null;
    for (0..4) |id| {
        if (id == 2 and self.audio_state.length_us <= 0) continue;
        const widget = control(self, id) orelse return null;
        if (widget.contains(@floatCast(x), @floatCast(y))) return id;
    }
    return null;
}

pub fn click(self: *App, x: f64, y: f64) bool {
    const id = hit(self, x, y) orelse return false;
    const link = self.audio_link orelse return false;
    switch (id) {
        0 => link.playPause(),
        1 => link.stopPlayback(),
        3 => playlist.toggle(self),
        else => {
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
    draw.roundedRect(cr, r.x, r.y, r.w, r.h, 8);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
    draw.setSource(cr, t.window_fg);
    draw.drawEllipsis(cr, std.fs.path.basename(self.audio_state.file()), r.x + 84, r.y + 15, r.w - 134, ui.cairo.textSize(), true);
    var time_buf: [64]u8 = undefined;
    const duration: u64 = @intCast(@max(0, @divTrunc(self.audio_state.length_us, 1_000_000)));
    const elapsed: u64 = @intFromFloat(@as(f64, fraction(self)) * @as(f64, @floatFromInt(duration)));
    const time = std.fmt.bufPrint(&time_buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{ @divTrunc(elapsed, 60), @mod(elapsed, 60), @divTrunc(duration, 60), @mod(duration, 60) }) catch "";
    draw.drawEllipsis(cr, time, r.x + r.w - 150, r.y + 29, 106, ui.cairo.statusSize(), false);
    for (0..4) |id| {
        var widget = control(self, id).?;
        var layer = ui.cairo.Layer.begin(cr, .{ .x = widget.computed_x, .y = widget.computed_y, .w = widget.computed_width, .h = widget.computed_height }) orelse continue;
        defer layer.finish();
        if (id == 2) {
            widget.computed_x = 0;
            widget.computed_y = 0;
            ui.widgets.slider.paintShaded(&widget, widget.kind.slider, &layer.renderer);
            continue;
        }
        const playing = self.audio_state.status == .playing;
        ui.widgets.button.paint(&layer.renderer, layer.local(), .{
            .variant = if (id == 0) .primary else .ghost,
            .icon = if (id == 3) .view_list else if (id == 1) .close else if (playing) .pause else .play,
            .label = if (id == 3) tr("Playlist") else if (id == 1) tr("Stop") else if (playing) tr("Pause") else tr("Play"),
        }, .{ .selected = id == 3 and self.audio_bar.playlist_open, .pointer = if (hit(self, self.mouse_x, self.mouse_y) == id) .hover else .idle });
    }
}
