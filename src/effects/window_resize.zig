//! The pointer pulls an elastic outline while the real client size follows
//! smoothly. One membrane fills the gap from the window to the curved boundary.
const std = @import("std");
const Top = @import("../Toplevel.zig");
const Host = @import("window_move.zig");
const anim = @import("ui").anim;
const ribbon = @import("ribbon.zig");
const resize = @import("../resize.zig");
const Follow = @import("resize_follow.zig");
const geometry = @import("resize_mesh.zig");
const border = @import("border.zig");
const Self = @This();

snapshot: resize.ResizeSnapshot,
follow: Follow,
last_motion: ?i64 = null,
released: ?i64 = null,
last_geometry: ?[5]f64 = null,
dirty: bool = true,

pub fn init(top: *Top) Self {
    const session = top.server.input.resize_session.?;
    return .{ .snapshot = session.snapshot, .follow = Follow.init(session.latest_desired_size, anim.nowMs()) };
}

pub fn motion(self: *Self, top: *Top) void {
    const session = top.server.input.resize_session orelse return;
    if (std.meta.eql(self.follow.target, session.latest_desired_size)) return;
    const now = anim.nowMs();
    self.follow.retarget(session.latest_desired_size, now, anim.speed());
    self.last_motion = now;
    self.dirty = true;
    top.server.scheduleFrames();
}

pub fn pending(self: *const Self, now: i64) bool {
    return self.follow.pending(now, anim.speed());
}

fn frame(top: *Top) [5]f64 {
    return .{ @floatFromInt(top.frame_tree.node.x), @floatFromInt(top.frame_tree.node.y), @floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height), top.worldScale() * top.drag_lift_value };
}

pub fn needsUpdate(self: *const Self, top: *Top) bool {
    return self.dirty or self.last_geometry == null or !std.meta.eql(self.last_geometry.?, frame(top));
}

pub fn update(self: *Self, host: *Host, top: *Top, now: i64) void {
    self.last_geometry = frame(top);
    self.dirty = false;
    const origin: ribbon.Point = .{ .x = @floatFromInt(top.frame_tree.node.x), .y = @floatFromInt(top.frame_tree.node.y) };
    const scale: f32 = @floatCast(top.worldScale() * top.drag_lift_value);
    const age = if (self.last_motion) |last|
        std.math.clamp(@as(f32, @floatFromInt(@max(0, now - last))) / @as(f32, @floatFromInt(host.preset.lifetime_ms)), 0, 1)
    else
        1;
    const following = self.pending(now);
    const release_age = if (self.released) |at|
        (if (following) 0 else std.math.clamp(@as(f32, @floatFromInt(@max(0, now - at))) / @as(f32, @floatFromInt(@min(450, host.preset.lifetime_ms))), 0, 1))
    else
        0;
    const strength = @max(if (following) @as(f32, 0.65) else 0, (1 - age) * (1 - age)) * (1 - release_age) * (1 - release_age);
    const desired = self.follow.target;
    const pos = resize.computeFramePosition(self.snapshot, desired.width, desired.height);
    const x = self.snapshot.initial_frame_x + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(pos.x - self.snapshot.initial_frame_x)) * top.worldScale())));
    const y = self.snapshot.initial_frame_y + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(pos.y - self.snapshot.initial_frame_y)) * top.worldScale())));
    const target: geometry.Box = .{
        .x = (@as(f32, @floatFromInt(x)) - origin.x) / scale,
        .y = (@as(f32, @floatFromInt(y)) - origin.y) / scale,
        .width = @floatFromInt(desired.width + 2 * self.snapshot.frame_border),
        .height = @floatFromInt(desired.height + self.snapshot.titlebar_height + self.snapshot.footer_height),
    };
    const decorated = top.hasServerDecorations() and @import("../chrome.zig").shapes;
    const radius = if (decorated) top.cornerRadius() else 0;
    const polygon = if (decorated) top.shapePolygon(top.chrome_width, top.chrome_height) else null;
    const target_polygon = if (decorated) top.shapePolygon(@intFromFloat(target.width), @intFromFloat(target.height)) else null;
    const phase = @as(f32, @floatFromInt(@mod(now, 100000))) * 0.003 * host.preset.turbulence;
    const reach = std.math.clamp(host.preset.width_px * 0.4, 6, 24) / scale;
    const pull: geometry.Pull = .{ .edges = self.snapshot.edges, .anchor = .{
        .x = @floatCast((self.snapshot.initial_cursor_x - @as(f64, @floatFromInt(self.snapshot.initial_frame_x)) / top.worldScale()) /
            @as(f64, @floatFromInt(self.snapshot.initial_client_width + 2 * self.snapshot.frame_border))),
        .y = @floatCast((self.snapshot.initial_cursor_y - @as(f64, @floatFromInt(self.snapshot.initial_frame_y)) / top.worldScale()) /
            @as(f64, @floatFromInt(self.snapshot.initial_client_height + self.snapshot.titlebar_height + self.snapshot.footer_height))),
    } };
    const meshes = geometry.build(@floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height), target, radius, polygon, target_polygon, pull, reach, strength, phase, host.preset);
    host.visible = false;
    host.present(0, meshes.fill, origin, scale);
    host.present(1, meshes.edge, origin, scale);
    host.present(2, border.mesh(@floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height), radius, polygon, reach, strength, host.preset), origin, scale);
}
