//! Moving a scrolling strip's view by hand: a three-finger swipe, two
//! fingers over empty strip, or a dragged tile held near the end of its
//! display. Input moves the view 1:1, rubber-banded past either end, and
//! `tick` places the windows once per output frame, since pointer events
//! arrive faster than frames. A release snaps the view to the nearest column
//! edge, keeping its speed, and focus moves to a column it shows. Windows
//! are only moved, never resized, so clients hear nothing (plan fix 1).
const std = @import("std");
const anim = @import("ui").anim;
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const scroll = @import("scroll_layout.zig");
const scroll_tiling = @import("scroll_tiling.zig");
const workspaces = @import("workspaces.zig");
const rubberBand = @import("camera.zig").rubberBand;

pub const Source = enum { none, swipe, finger };

pub const Motion = struct {
    /// Fingers are down and the view follows them.
    source: Source = .none,
    /// The view the fingers ask for, before the rubber band.
    raw: f64 = 0,
    /// The view moved since the windows were placed.
    pending: bool = false,
    /// After a release: towards `target`.
    snap: anim.Anim = .{},
    target: f64 = 0,
    velocity: anim.VelocityTracker = .{},
    /// Edge scrolling while a tile is dragged, in px/s along the strip, and
    /// when it last advanced.
    edge: f64 = 0,
    edge_ms: i64 = 0,
    /// Focus is moving to the column a release settled on: no reveal.
    focusing: bool = false,
    /// The last input that moved it by hand.
    last_ms: i64 = 0,

    pub fn active(motion: *const Motion) bool {
        return motion.source != .none or motion.snap.active() or motion.edge != 0;
    }
};

/// How far a release carries the view, in seconds of its speed: about what
/// a deceleration of 0.997 per millisecond covers.
const projection_s = 0.3;
/// Drag-edge scrolling at the very edge of the display.
const edge_speed = 1600;
/// Two fingers that sent nothing for this long have lifted: their stop
/// event can go elsewhere (Super pressed meanwhile takes the wheel).
const finger_idle_ms = 400;

fn motionOf(server: *Server, id: u8) *Motion {
    return &server.world.workspaces.tiler.motions[id - 1];
}

/// Workspace `id`'s motion, with a finger gesture that went quiet ended.
fn current(server: *Server, id: u8) *Motion {
    const motion = motionOf(server, id);
    if (motion.source == .finger and anim.nowMs() - motion.last_ms > finger_idle_ms) {
        if (server.input.finger_strip == id) server.input.finger_strip = 0;
        end(server, id, false);
    }
    return motion;
}

fn stripOf(server: *Server, id: u8) *scroll.Strip {
    return &server.world.workspaces.tiler.strips[id - 1];
}

/// Whether workspace `id`'s view is moved by hand or settling.
pub fn active(server: *Server, id: u8) bool {
    if (id == 0 or id > workspaces.count) return false;
    return current(server, id).active();
}

/// Whether a gesture holds the view, or focus follows a release: a reveal
/// would fight it.
pub fn holdsView(server: *Server, id: u8) bool {
    if (id == 0 or id > workspaces.count) return false;
    const motion = current(server, id);
    return motion.source != .none or motion.focusing;
}

/// A reveal takes over from a settling view where it is.
pub fn stopSnap(server: *Server, id: u8) void {
    const motion = motionOf(server, id);
    if (!motion.snap.active()) return;
    motion.snap.cancel(motion.snap.value(anim.nowMs()));
}

/// The scrolling workspace shown at layout point (x, y).
pub fn workspaceAt(server: *Server, x: f64, y: f64) ?u8 {
    const output = Output.atLayout(server, x, y) orelse return null;
    const id = output.workspace_id;
    if (id == 0 or !scroll_tiling.scrolling(server, id)) return null;
    return id;
}

/// The part of a pointer motion (dx, dy) that runs along workspace `id`'s
/// strip, as a view change: content follows the fingers.
pub fn along(server: *Server, id: u8, dx: f64, dy: f64) f64 {
    return -(if (stripOf(server, id).direction == .horizontal) dx else dy);
}

pub fn begin(server: *Server, id: u8, source: Source) void {
    const motion = motionOf(server, id);
    const strip = stripOf(server, id);
    const now = anim.nowMs();
    // Catch a settling view where it is.
    if (motion.snap.active()) {
        strip.view = motion.snap.value(now);
        motion.snap.cancel(@floatCast(strip.view));
        motion.pending = true;
    }
    motion.source = source;
    motion.last_ms = now;
    motion.raw = strip.view;
    motion.velocity.reset();
    motion.velocity.push(now, @floatCast(strip.view));
}

/// Moves the view by `delta` (positive: towards the strip's end).
pub fn scrollBy(server: *Server, id: u8, delta: f64) void {
    const motion = motionOf(server, id);
    if (motion.source == .none or delta == 0) return;
    const strip = stripOf(server, id);
    const now = anim.nowMs();
    motion.last_ms = now;
    motion.raw += delta;
    strip.view = rubberBand(motion.raw, 0, strip.maxView(), @floatFromInt(@max(1, strip.content)));
    motion.velocity.push(now, @floatCast(strip.view));
    motion.pending = true;
    server.scheduleFrames();
}

/// Fingers lifted: settle on a column edge with the release speed (none
/// when cancelled), and focus a column the view settles on.
pub fn end(server: *Server, id: u8, cancelled: bool) void {
    const motion = motionOf(server, id);
    if (motion.source == .none) return;
    motion.source = .none;
    const strip = stripOf(server, id);
    const velocity: f64 = if (cancelled) 0 else motion.velocity.velocity(anim.nowMs());
    const snap = strip.snapView(strip.view + velocity * projection_s, scroll_tiling.center(server)) orelse {
        settle(server, id, std.math.clamp(strip.view, 0, strip.maxView()), 0);
        return;
    };
    focusShown(server, id, snap);
    settle(server, id, snap.view, velocity);
}

fn settle(server: *Server, id: u8, target: f64, velocity: f64) void {
    const motion = motionOf(server, id);
    const strip = stripOf(server, id);
    motion.target = target;
    motion.pending = true;
    server.scheduleFrames();
    // Reduced motion: reveals jump; gestures stay 1:1, and so does this.
    if (!anim.enabled() or anim.speed() <= 0 or anim.reducedMotion() or strip.view == target) {
        strip.view = target;
        motion.snap.cancel(@floatCast(target));
        return;
    }
    const from: f32 = @floatCast(strip.view);
    motion.snap = .{ .from = from, .to = from };
    motion.snap.retargetWith(anim.nowMs(), @floatCast(target), anim.curveFor(.camera_pan), @floatCast(velocity));
}

/// Keeps focus when its column shows at the settled view; otherwise focuses
/// the member of the settled column nearest it.
fn focusShown(server: *Server, id: u8, snap: scroll.Snap) void {
    const strip = stripOf(server, id);
    const focused = scroll_tiling.focusKey(server, id);
    if (focused) |key| if (strip.locate(key)) |at| {
        if (strip.columnFits(at.column, snap.view)) return;
    };
    const key = strip.memberNear(snap.column, if (focused) |k| strip.rectangle(k) else null) orelse return;
    const top = scroll_tiling.windowFor(server, id, key) orelse return;
    const motion = motionOf(server, id);
    motion.focusing = true;
    defer motion.focusing = false;
    server.world.focus(top);
}

/// Edge scrolling while a tile is dragged: the strip under (x, y) scrolls
/// when the pointer nears either end of its display along the strip, faster
/// the nearer it is; every other strip stops.
pub fn dragEdge(server: *Server, x: f64, y: f64) void {
    const target = workspaceAt(server, x, y);
    for (&server.world.workspaces.tiler.motions, 1..) |*motion, index| {
        const id: u8 = @intCast(index);
        if (target != id) {
            motion.edge = 0;
            continue;
        }
        const strip = stripOf(server, id);
        const horizontal = strip.direction == .horizontal;
        const box = strip.viewport;
        const length: f64 = @floatFromInt(if (horizontal) box.width else box.height);
        const at = if (horizontal) x - @as(f64, @floatFromInt(box.x)) else y - @as(f64, @floatFromInt(box.y));
        const zone = std.math.clamp(length / 12, 32, 120);
        const depth: f64 = if (at < zone) -(zone - at) / zone else if (at > length - zone) (at - (length - zone)) / zone else 0;
        const speed = edge_speed * std.math.clamp(depth, -1, 1) * @abs(std.math.clamp(depth, -1, 1));
        if (speed != 0 and motion.edge == 0) motion.edge_ms = anim.nowMs();
        motion.edge = speed;
        if (speed != 0) server.scheduleFrames();
    }
}

pub fn stopEdges(server: *Server) void {
    for (&server.world.workspaces.tiler.motions) |*motion| motion.edge = 0;
}

/// Whether the input that moves workspace `id`'s view by hand is still down.
fn live(server: *Server, id: u8, source: Source) bool {
    if (server.locker != null or server.polkit_dialog != null) return false;
    const input = &server.input;
    return switch (source) {
        .none => false,
        .swipe => input.gesture == .strip_swipe and input.swipe_strip == id,
        .finger => input.finger_strip == id,
    };
}

/// Once per output frame: advance settling and edge-scrolling views, and
/// move the windows of every strip whose view changed. True while a view
/// keeps moving on its own.
pub fn tick(server: *Server, now_ms: i64) bool {
    if (!server.world.workspaces.active) return false;
    var animating = false;
    for (&server.world.workspaces.tiler.motions, 1..) |*motion, index| {
        const id: u8 = @intCast(index);
        if (!motion.active() and !motion.pending) continue;
        if (!scroll_tiling.scrolling(server, id)) {
            motion.* = .{};
            continue;
        }
        _ = current(server, id);
        // A gesture whose input went away (a lock, a lost device) ends here.
        if (motion.source != .none and !live(server, id, motion.source)) end(server, id, true);
        const strip = stripOf(server, id);
        if (motion.edge != 0) {
            const dt = std.math.clamp(@as(f64, @floatFromInt(now_ms - motion.edge_ms)) / 1000, 0, 0.05);
            motion.edge_ms = now_ms;
            const next = std.math.clamp(strip.view + motion.edge * dt, 0, strip.maxView());
            if (next != strip.view) {
                strip.view = next;
                motion.pending = true;
                animating = true;
            }
        }
        if (motion.snap.active()) {
            if (motion.snap.settled(now_ms)) {
                strip.view = motion.target;
                motion.snap.cancel(@floatCast(motion.target));
            } else {
                strip.view = motion.snap.value(now_ms);
                animating = true;
            }
            motion.pending = true;
        }
        if (!motion.pending) continue;
        motion.pending = false;
        strip.place();
        scroll_tiling.place(server, id, false);
        if (motion.edge != 0) @import("tiling_grab.zig").refreshPreview(&server.input);
    }
    return animating;
}
