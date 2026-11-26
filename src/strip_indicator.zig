//! A thin bar along the edge of a scrolling display, shown while its strip
//! moves: the stretch on screen against the whole strip, like the canvas
//! mini-map. It stays `mini_map_hide_ms` after the strip settles, then fades.
//! A timer starts the fade, so a resting bar costs no frames, and a hidden
//! one nothing at all.
const std = @import("std");
const wl = @import("wayland").server.wl;
const sn = @import("node.zig");
const col = @import("color.zig");
const anim = @import("ui").anim;
const theme = @import("ui").theme;
const Output = @import("Output.zig");
const scroll_tiling = @import("scroll_tiling.zig");
const Self = @This();

tree: ?*sn.Tree = null,
track: ?*sn.Rect = null,
thumb: ?*sn.Rect = null,
timer: ?*wl.EventSource = null,
output: ?*Output = null,
visible: bool = false,
moving: bool = false,
fade_start: ?i64 = null,

const thickness = 4;
/// From the display's edge and from the ends of the strip.
const margin = 4;
const inset = 24;
const fade_ms = 220;

pub fn deinit(self: *Self) void {
    if (self.timer) |timer| timer.remove();
    if (self.tree) |tree| tree.node.destroy();
    self.* = .{};
}

/// Once per output frame. True while it fades.
pub fn tick(self: *Self, output: *Output, now_ms: i64) bool {
    const server = output.server;
    const id = output.workspace_id;
    const shown = id != 0 and server.config.compositor.mini_map_enabled and server.locker == null and
        scroll_tiling.scrolling(server, id) and !server.world.overview.active();
    const strip = if (shown) &server.world.workspaces.tiler.strips[id - 1] else null;
    const moving = if (strip) |s| s.extent > s.content and scroll_tiling.moving(server, id) else false;
    if (moving) {
        self.ensure(output) catch return false;
        self.visible = true;
        self.fade_start = null;
        if (self.timer) |timer| timer.timerUpdate(0) catch {};
    } else if (self.moving and self.visible) {
        // Settled: rest, then fade.
        if (self.timer) |timer| timer.timerUpdate(@intCast(@max(1, server.config.compositor.mini_map_hide_ms))) catch {};
    }
    self.moving = moving;
    if (!self.visible) return false;
    const s = strip orelse return self.hide();
    var alpha: f32 = 1;
    if (self.fade_start) |start| {
        alpha = 1 - @as(f32, @floatFromInt(now_ms - start)) / fade_ms;
        if (alpha <= 0 or !anim.enabled() or anim.reducedMotion()) return self.hide();
    }
    self.place(s, alpha);
    return self.fade_start != null;
}

fn hide(self: *Self) bool {
    self.visible = false;
    self.fade_start = null;
    if (self.tree) |tree| tree.node.setEnabled(false);
    return false;
}

fn ensure(self: *Self, output: *Output) !void {
    self.output = output;
    if (self.tree != null) return;
    const server = output.server;
    const tree = try server.overlay_tree.createSceneTree();
    errdefer tree.node.destroy();
    // Drawn only: clicks reach the windows beneath.
    _ = @import("projection.zig").setTreeInert(&tree.node, true);
    const clear: col.Premul = .{ .rgba = .{ 0, 0, 0, 0 } };
    const track = try col.createRect(tree, 0, 0, clear);
    const thumb = try col.createRect(tree, 0, 0, clear);
    if (self.timer == null) self.timer = try server.wl_server.getEventLoop().addTimer(*Self, timeout, self);
    self.tree = tree;
    self.track = track;
    self.thumb = thumb;
}

fn timeout(self: *Self) c_int {
    if (!self.visible or self.moving) return 0;
    self.fade_start = anim.nowMs();
    if (self.output) |output| output.wlr_output.scheduleFrame();
    return 0;
}

/// The track along the strip's far edge across it, and the thumb over the
/// stretch on screen.
fn place(self: *Self, strip: *const @import("scroll_layout.zig").Strip, alpha: f32) void {
    const tree = self.tree orelse return;
    const box = strip.viewport;
    const horizontal = strip.direction == .horizontal;
    const length = @max(1, (if (horizontal) box.width else box.height) - 2 * inset);
    const extent: f64 = @floatFromInt(@max(1, strip.extent));
    const view = std.math.clamp(strip.view, 0, strip.maxView());
    const thumb_len: i32 = @max(thickness * 2, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(length)) * @min(1, @as(f64, @floatFromInt(strip.content)) / extent)))));
    const thumb_at: i32 = @min(length - thumb_len, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(length)) * view / extent))));
    if (horizontal) {
        tree.node.setPosition(box.x + inset, box.y + box.height - margin - thickness);
        self.track.?.setSize(length, thickness);
        self.thumb.?.node.setPosition(thumb_at, 0);
        self.thumb.?.setSize(thumb_len, thickness);
    } else {
        tree.node.setPosition(box.x + box.width - margin - thickness, box.y + inset);
        self.track.?.setSize(thickness, length);
        self.thumb.?.node.setPosition(0, thumb_at);
        self.thumb.?.setSize(thickness, thumb_len);
    }
    const palette = theme.shellPalette();
    var track = col.Straight.fromRgba(palette.fg);
    track.a *= 0.18 * alpha;
    var thumb = col.Straight.fromRgba(palette.accent);
    thumb.a *= 0.85 * alpha;
    col.setRect(self.track.?, track.premultiply());
    col.setRect(self.thumb.?, thumb.premultiply());
    tree.node.raiseToTop();
    tree.node.setEnabled(true);
}
