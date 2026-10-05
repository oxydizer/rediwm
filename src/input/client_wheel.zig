// Shapes the mouse-wheel notches Input forwards to clients.
//
// Acceleration scales a notch (its value120 and pixel delta together) by the
// shared `ui/wheel.zig` rate, so a fast run scrolls further in any app while
// the app keeps its own smoothing. With `[input] smooth_scroll`, a notch is
// instead glided out as a run of small value120 steps, one per refresh,
// following the same `wheel_scroll` spring as the shell panels. Seat v8+
// clients take those as a high-resolution wheel; older ones get whole
// `axis_discrete` notches from wlroots' accumulator, so they still step.
//
// Browsers are excluded from smoothing by default: they smooth wheel
// scrolling themselves, and doing it twice feels mushy. Ctrl/Super+wheel
// (zoom and similar bindings in apps) is always forwarded untouched.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const anim = @import("ui").anim;
const wheel = @import("ui").wheel;
const Input = @import("../Input.zig");
const Toplevel = @import("../Toplevel.zig");

const ClientWheel = @This();

/// Armed only while a glide has steps left to send.
timer: ?*wl.EventSource = null,
axes: [2]Axis = .{ .{}, .{} },

const Axis = struct {
    rate: wheel.Rate = .{},
    /// Position in value120 units since the glide began; `sent` is how much
    /// of it has been delivered. Idle unless `glide.active()`.
    glide: anim.Anim = .{},
    sent: i32 = 0,
    /// Logical pixels per value120 unit, from the notches being glided.
    px_per_v120: f64 = 15.0 / 120.0,
    /// Compared, never dereferenced: a glide ends when pointer focus leaves.
    surface: ?*wlr.Surface = null,

    fn reset(axis: *Axis) void {
        axis.glide.cancel(0);
        axis.sent = 0;
        axis.surface = null;
    }
};

pub fn deinit(self: *ClientWheel) void {
    if (self.timer) |timer| timer.remove();
    self.timer = null;
}

/// Forwards one detented wheel event (`delta_discrete` != 0) to the focused
/// client, accelerated and/or glided as configured.
pub fn forward(self: *ClientWheel, time_msec: u32, orientation: wl.Pointer.Axis, delta: f64, delta_discrete: i32) void {
    const input = self.owner();
    const seat = input.seat;
    const focused = seat.pointer_state.focused_surface orelse
        return seat.pointerNotifyAxis(time_msec, orientation, delta, delta_discrete, .wheel, .identical);
    const cfg = input.server.config.input;
    const axis = &self.axes[@intCast(@intFromEnum(orientation))];
    const now_ms = anim.nowMs();
    // Deliver whatever is due first, so a glide that has finished but not
    // yet ticked is not lost when this notch starts a new one.
    _ = self.step(axis, orientation, now_ms);

    if (bindingModifierHeld(input)) {
        return seat.pointerNotifyAxis(time_msec, orientation, delta, delta_discrete, .wheel, .identical);
    }
    const app = if (Toplevel.fromSurface(input.server, focused)) |toplevel| toplevel.appIdOrNull() else null;
    const notches = @as(f32, @floatFromInt(delta_discrete)) / 120;
    const scale: f64 = if (listed(cfg.wheel_acceleration_exclude, app)) 1 else axis.rate.multiplier(notches, now_ms);
    const v120: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(delta_discrete)) * scale));
    if (v120 == 0) return;
    const px_per_v120 = delta / @as(f64, @floatFromInt(delta_discrete));

    // Files uses this same spring locally, like the shell scroll containers.
    // Keep acceleration here, but do not smooth its input a second time.
    const files = if (app) |id| std.mem.eql(u8, id, "rediwm-files") else false;
    if (!cfg.smooth_scroll or files or listed(cfg.smooth_scroll_exclude, app)) {
        return seat.pointerNotifyAxis(time_msec, orientation, @as(f64, @floatFromInt(v120)) * px_per_v120, v120, .wheel, .identical);
    }

    const in_flight = axis.glide.active() and axis.surface == focused;
    if (!in_flight) {
        axis.reset();
        axis.surface = focused;
    }
    axis.px_per_v120 = px_per_v120;
    const extra: f32 = @floatFromInt(v120);
    // Reversing mid-glide turns around from where the content is, without
    // the old momentum, as the shell panels do.
    const at = axis.glide.value(now_ms);
    if ((axis.glide.to - at) * extra < 0) axis.glide.cancel(at);
    axis.glide.retargetTo(now_ms, axis.glide.to + extra, anim.curveFor(.wheel_scroll));
    // Curve off or reduced motion: `step` sends it all at once.
    if (self.step(axis, orientation, now_ms)) self.arm();
}

/// Sends the part of `axis`'s glide that is due by `now_ms`. Returns whether
/// more remains.
fn step(self: *ClientWheel, axis: *Axis, orientation: wl.Pointer.Axis, now_ms: i64) bool {
    if (!axis.glide.active()) return false;
    const seat = self.owner().seat;
    if (seat.pointer_state.focused_surface == null or seat.pointer_state.focused_surface != axis.surface) {
        axis.reset();
        return false;
    }
    const done = axis.glide.settled(now_ms);
    const due: i32 = @intFromFloat(@round(if (done) axis.glide.to else axis.glide.value(now_ms)));
    const d = due - axis.sent;
    if (d != 0) {
        axis.sent = due;
        const time_msec: u32 = @truncate(@as(u64, @bitCast(now_ms)));
        seat.pointerNotifyAxis(time_msec, orientation, @as(f64, @floatFromInt(d)) * axis.px_per_v120, d, .wheel, .identical);
        seat.pointerNotifyFrame();
    }
    if (done) axis.reset();
    return !done;
}

fn tick(self: *ClientWheel) c_int {
    const now_ms = anim.nowMs();
    var pending = false;
    for (&self.axes, [_]wl.Pointer.Axis{ .vertical_scroll, .horizontal_scroll }) |*axis, orientation| {
        if (self.step(axis, orientation, now_ms)) pending = true;
    }
    if (pending) self.arm();
    return 0;
}

/// One step per refresh of the output under the cursor.
fn arm(self: *ClientWheel) void {
    const input = self.owner();
    if (self.timer == null) {
        self.timer = input.server.wl_server.getEventLoop().addTimer(*ClientWheel, tick, self) catch {
            // No timer: deliver the rest at once rather than lose it.
            for (&self.axes, [_]wl.Pointer.Axis{ .vertical_scroll, .horizontal_scroll }) |*axis, orientation| {
                _ = self.step(axis, orientation, std.math.maxInt(i64));
            }
            return;
        };
    }
    var period_ms: i32 = 16;
    if (input.server.output_layout.outputAt(input.cursor.x, input.cursor.y)) |output| {
        if (output.refresh > 0) period_ms = std.math.clamp(@divTrunc(1_000_000, output.refresh), 4, 33);
    }
    self.timer.?.timerUpdate(period_ms) catch {};
}

fn owner(self: *ClientWheel) *Input {
    return @fieldParentPtr("client_wheel", self);
}

/// Ctrl/Super+wheel is usually an app binding (zoom, tab switching); scaling
/// or splitting it would change what the binding does.
fn bindingModifierHeld(in: *Input) bool {
    var it = in.keyboards.iterator(.forward);
    while (it.next()) |kbd| {
        const mods = kbd.device.toKeyboard().getModifiers();
        if (mods.ctrl or mods.logo) return true;
    }
    return false;
}

/// App ids match by case-insensitive prefix, so `brave` also covers Brave's
/// installed web apps and Xwayland's `Brave-browser` class.
fn listed(list: []const []const u8, app_id: ?[]const u8) bool {
    const id = app_id orelse return false;
    for (list) |prefix| {
        if (prefix.len > 0 and std.ascii.startsWithIgnoreCase(id, prefix)) return true;
    }
    return false;
}
