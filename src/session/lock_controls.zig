//! Transient volume and brightness sliders on the built-in lock screen.
//!
//! The hardware keys already work behind the lock; these are the pointer and
//! touch way to the same two controls. They are not part of the lock's
//! whole-output raster: dragging re-rasters only this small block (its own
//! scene buffer in `lock.View`), never the clock, avatar and field.
//!
//! Values come from the real backends (`AudioManager`, `Brightness`) and a
//! row exists only while its backend reports one: no default sink, no
//! backlight, no row. A drag shows its own value until release, then the
//! backend's report takes over again.
//! The block is hidden at rest and appears on pointer use or a hardware value
//! change, then hides again after a short idle timeout.
//!
//! Everything here is in the block's design units (the lock's 600x900
//! canvas) except the drag's track, which is kept in layout pixels so a drag
//! survives its output going away.
const std = @import("std");
const ui = @import("ui");
const Server = @import("../Server.zig");

pub const Kind = enum { volume, brightness };

pub const width: f32 = 260;
const row_h: f32 = 32;
const row_gap: f32 = 8;
const icon_size: f32 = 20;
pub const track_x: f32 = 32;
pub const track_w: f32 = 176;
const readout_x: f32 = 216;
const readout_w: f32 = 44;
/// Brightness never goes fully dark: the screen would be unrecoverable.
const brightness_min: f32 = 0.01;

pub const Part = enum { track, icon };
pub const Hit = struct { kind: Kind, part: Part };

const Drag = struct {
    kind: Kind,
    /// The track's left edge and width in layout pixels.
    left: f32,
    width: f32,
};

pub const Controls = struct {
    volume: f32 = 0,
    muted: bool = false,
    has_volume: bool = false,
    brightness: f32 = 1,
    has_brightness: bool = false,
    hover: ?Kind = null,
    drag: ?Drag = null,
    /// Bumped by anything the block draws differently; `lock.View` compares.
    revision: u64 = 1,

    pub fn rows(self: *const Controls) usize {
        return @as(usize, @intFromBool(self.has_volume)) + @intFromBool(self.has_brightness);
    }

    /// The block's height in design units; 0 with no rows.
    pub fn height(self: *const Controls) f32 {
        const n: f32 = @floatFromInt(self.rows());
        return if (n == 0) 0 else n * row_h + (n - 1) * row_gap;
    }

    fn slot(self: *const Controls, kind: Kind) ?usize {
        return switch (kind) {
            .volume => if (self.has_volume) 0 else null,
            .brightness => if (!self.has_brightness) null else if (self.has_volume) 1 else 0,
        };
    }

    fn rowY(slot_index: usize) f32 {
        return @as(f32, @floatFromInt(slot_index)) * (row_h + row_gap);
    }

    /// Re-reads both backends. Returns whether the block changed. Called
    /// when the lock engages and whenever either backend reports.
    pub fn refresh(self: *Controls, server: *Server) bool {
        var next = self.*;
        if (@import("../hardware_keys.zig").audioState(server, false)) |state| {
            next.has_volume = true;
            next.muted = server.audio.?.isMasterMuted();
            // The user's own drag is the truth until they let go.
            if (!self.draggingKind(.volume)) next.volume = std.math.clamp(state.level, 0, 1);
        } else next.has_volume = false;
        if (server.brightness.level) |level| {
            next.has_brightness = true;
            if (!self.draggingKind(.brightness)) next.brightness = std.math.clamp(level, brightness_min, 1);
        } else next.has_brightness = false;
        const changed = next.volume != self.volume or next.muted != self.muted or next.has_volume != self.has_volume or
            next.brightness != self.brightness or next.has_brightness != self.has_brightness;
        if (!changed) return false;
        self.* = next;
        self.revision +%= 1;
        return true;
    }

    fn draggingKind(self: *const Controls, kind: Kind) bool {
        const drag = self.drag orelse return false;
        return drag.kind == kind;
    }

    /// What lies under a point given relative to the block, in design units.
    pub fn pick(self: *const Controls, x: f32, y: f32) ?Hit {
        for ([_]Kind{ .volume, .brightness }) |kind| {
            const i = self.slot(kind) orelse continue;
            const top = rowY(i);
            if (y < top or y >= top + row_h) continue;
            if (x >= 0 and x < track_x - 4) return .{ .kind = kind, .part = .icon };
            // The thumb overhangs the track by half its width.
            if (x >= track_x - 6 and x <= track_x + track_w + 6) return .{ .kind = kind, .part = .track };
            return null;
        }
        return null;
    }

    pub fn setHover(self: *Controls, hit: ?Hit) bool {
        const next: ?Kind = if (hit) |h| if (h.part == .track) h.kind else null else null;
        if (next == self.hover) return false;
        self.hover = next;
        self.revision +%= 1;
        return true;
    }

    /// Starts dragging `kind`'s track, whose left edge and width are given
    /// in layout pixels, with the pointer at `x` (layout pixels).
    pub fn beginDrag(self: *Controls, server: *Server, kind: Kind, left: f32, span: f32, x: f32) void {
        self.drag = .{ .kind = kind, .left = left, .width = span };
        self.revision +%= 1;
        self.dragTo(server, x);
    }

    pub fn dragTo(self: *Controls, server: *Server, x: f32) void {
        const drag = self.drag orelse return;
        if (drag.width <= 0) return;
        const t = std.math.clamp((x - drag.left) / drag.width, 0, 1);
        switch (drag.kind) {
            .volume => {
                const value = @round(t * 100) / 100;
                if (value == self.volume) return;
                self.volume = value;
                if (server.audio) |mgr| mgr.setMasterVolume(value);
            },
            .brightness => {
                const value = std.math.clamp(@round(t * 100) / 100, brightness_min, 1);
                if (value == self.brightness) return;
                self.brightness = value;
                server.brightness.set(server, value);
            },
        }
        self.revision +%= 1;
    }

    pub fn endDrag(self: *Controls) bool {
        if (self.drag == null) return false;
        self.drag = null;
        self.revision +%= 1;
        return true;
    }

    /// Draws the block with its top-left at the renderer's origin, which
    /// the caller has zoomed to design units with the shell palette set.
    pub fn paint(self: *const Controls, r: *ui.paint.Renderer) void {
        const t = r.palette orelse ui.theme.global;
        for ([_]Kind{ .volume, .brightness }) |kind| {
            const i = self.slot(kind) orelse continue;
            const top = rowY(i);
            const value = if (kind == .volume) self.volume else self.brightness;
            const muted = kind == .volume and (self.muted or self.volume <= 0);
            const icon: ui.layout.IconId = switch (kind) {
                .volume => if (muted) .volume_muted else if (value < 0.4) .volume_low else .volume,
                .brightness => .brightness,
            };
            r.drawIcon(0, top + (row_h - icon_size) / 2, icon_size, icon_size, .{ .id = icon, .color = if (muted) t.accent else t.window_fg });
            const engaged = self.hover == kind or self.draggingKind(kind);
            var data = ui.layout.SliderData{
                .value = value,
                .min = if (kind == .brightness) brightness_min else 0,
                .max = 1,
                .on_change = &unused,
            };
            if (engaged) {
                data.feel.accent = 1;
                data.feel.wide = 1;
            }
            const widget = ui.layout.Widget{
                .kind = .{ .slider = data },
                .computed_x = track_x,
                .computed_y = top,
                .computed_width = track_w,
                .computed_height = row_h,
            };
            ui.paint.paintSlider(&widget, data, r);
            var buf: [8]u8 = undefined;
            const readout = std.fmt.bufPrint(&buf, "{d}%", .{@as(i32, @intFromFloat(@round(value * 100)))}) catch "";
            const size: f32 = 14;
            const x = ui.paint.centeredTextX(readout_x, readout_w, readout, size);
            r.drawText(x, top, readout_x + readout_w - x, row_h, .{
                .content = readout,
                .font_size = size,
                .color = if (engaged) t.window_fg else .{ t.window_fg[0], t.window_fg[1], t.window_fg[2], 0.66 * t.window_fg[3] },
            });
        }
    }

    fn unused(_: ?*anyopaque, _: usize, _: f32) void {}
};

/// The speaker icon was pressed. The backend's report (the audio wake)
/// redraws it.
pub fn toggleMute(server: *Server) void {
    const mgr = server.audio orelse return;
    mgr.toggleMasterMute();
}

test "lock controls rows are compacted to the backends that exist" {
    var c = Controls{};
    try std.testing.expectEqual(@as(f32, 0), c.height());
    try std.testing.expectEqual(@as(?Hit, null), c.pick(60, 10));
    c.has_brightness = true;
    try std.testing.expectEqual(@as(f32, 32), c.height());
    try std.testing.expectEqual(Kind.brightness, c.pick(60, 10).?.kind);
    c.has_volume = true;
    try std.testing.expectEqual(@as(f32, 72), c.height());
    try std.testing.expectEqual(Kind.volume, c.pick(60, 10).?.kind);
    try std.testing.expectEqual(Kind.brightness, c.pick(60, 50).?.kind);
}

test "lock controls: the icon, the track and the gaps are told apart" {
    const c = Controls{ .has_volume = true, .has_brightness = true };
    try std.testing.expectEqual(Part.icon, c.pick(10, 5).?.part);
    try std.testing.expectEqual(Part.track, c.pick(40, 5).?.part);
    try std.testing.expectEqual(Part.track, c.pick(track_x + track_w + 4, 5).?.part);
    // Between rows, beside the readout and below the block hit nothing.
    try std.testing.expectEqual(@as(?Hit, null), c.pick(60, 36));
    try std.testing.expectEqual(@as(?Hit, null), c.pick(readout_x + 10, 5));
    try std.testing.expectEqual(@as(?Hit, null), c.pick(60, 80));
}

test "lock controls hover only counts over a track and bumps the revision once" {
    var c = Controls{ .has_volume = true };
    const before = c.revision;
    try std.testing.expect(c.setHover(.{ .kind = .volume, .part = .track }));
    try std.testing.expect(!c.setHover(.{ .kind = .volume, .part = .track }));
    try std.testing.expect(c.setHover(.{ .kind = .volume, .part = .icon }));
    try std.testing.expectEqual(@as(?Kind, null), c.hover);
    try std.testing.expectEqual(before + 2, c.revision);
}
