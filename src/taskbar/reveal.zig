//! Taskbar auto-hide: reveal/hide timing, pointer proximity and the slide/fade.
//! Mirrors the dock's mechanism (dock/reveal.zig): the reveal animates the
//! tree's position and the buffers' opacity, and the parked bar disables its
//! tree so it neither paints nor takes hits.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const Output = @import("../Output.zig");
const glass = @import("../glass.zig");
const wl = @import("wayland").server.wl;
const anim = @import("ui").anim;

const Self = Taskbar;
/// The outermost pixels of the edge that reveal the bar, and the tolerance
/// around a shown one; timing and travel mirror the dock's.
const pointer_margin = 5;
const edge_band = 2;
const reveal_delay_ms = 120;
const hide_delay_ms = 400;
const slide_distance = 20;

/// Whether a panel the bar anchors keeps it shown: the window picker on this
/// bar, the start menu, or a popup (calendar, battery, network) on the output.
pub fn menuOpen(bar: *const Self) bool {
    const input = bar.server.input;
    if (input.window_menu.bar == bar) return true;
    if (input.open_start_menu) |sm| {
        if (sm.wlr_output == bar.wlr_output) return true;
    }
    if (Output.fromWlr(bar.wlr_output)) |output| {
        if (output.calendar != null or output.battery_popup != null or output.wifi_popup != null or output.transfers_popup != null) return true;
    }
    return false;
}

/// Auto-hide: lets `reveal` follow the pointer's wish. True while it still moves.
pub fn syncReveal(bar: *Self, now_ms: i64) bool {
    var target: f32 = 1;
    if (bar.server.config.compositor.taskbar_auto_hide) {
        retime(bar);
        if (!bar.shown) target = 0;
    } else {
        disarm(bar);
        bar.pointer_near = false;
        bar.shown = false;
    }
    if (bar.reveal.to != target) bar.reveal.retargetTo(now_ms, target, anim.curveFor(.taskbar_hover));
    const moving = !bar.reveal.settled(now_ms);
    bar.parked = target == 0 and !moving;
    return moving;
}

/// The bar fades and slides toward its edge as `reveal` falls. The rasters do
/// not change: only the tree's position and every buffer's opacity. Glass
/// follows the position as part of the tree, but its opacity is its own and is
/// given here, or the blurred backdrop would stay solid until the bar parks.
pub fn applyReveal(bar: *Self, now_ms: i64) void {
    const t = std.math.clamp(bar.reveal.value(now_ms), 0, 1);
    const x = bar.box.x;
    var y = bar.box.y;
    if (t < 1 and !anim.reducedMotion()) {
        const away: i32 = @intFromFloat(@round((1 - t) * slide_distance));
        if (bar.server.config.compositor.taskbar_position == .top) y -= away else y += away;
    }
    bar.tree.node.setPosition(x, y);
    bar.buffer_node.setOpacity(t);
    bar.start_node.setOpacity(t);
    bar.clock_node.setOpacity(t);
    for (bar.tray_nodes) |node| node.setOpacity(t);
    bar.app_tray_node.setOpacity(t);
    bar.capture_node.setOpacity(t);
    bar.battery_node.setOpacity(t);
    glass.Effect.configure(bar.glass_effect, Taskbar.barRadius(), t);
}

/// Whether the pointer at layout position `x`, `y` wants the bar: it is at the
/// output edge the bar sits on, or on the bar once shown.
pub fn nearPointer(bar: *const Self, output: *Output, x: f64, y: f64) bool {
    const c = &bar.server.config.compositor;
    if (!c.taskbar_auto_hide) return false;
    const full = output.cached_box;
    const px: i32 = @intFromFloat(@floor(x));
    const py: i32 = @intFromFloat(@floor(y));
    if (px < full.x or py < full.y or px >= full.x + full.width or py >= full.y + full.height) return false;
    const at_edge = if (c.taskbar_position == .top)
        py < full.y + edge_band
    else
        py >= full.y + full.height - edge_band;
    if (at_edge) return true;
    // Only a bar that is out can be pointed at: where it would be is windows.
    if (!bar.shown) return false;
    return px >= bar.box.x - pointer_margin and px < bar.box.x + bar.box.width + pointer_margin and
        py >= bar.box.y - pointer_margin and py < bar.box.y + bar.box.height + pointer_margin;
}

/// Every pointer motion. `engaged` is false while a window is moved or resized
/// or a button is held, none of which should raise the bar.
pub fn pointerAt(bar: *Self, x: f64, y: f64, engaged: bool) void {
    const output = Output.fromWlr(bar.wlr_output) orelse return;
    const near = engaged and nearPointer(bar, output, x, y);
    if (near == bar.pointer_near) return;
    bar.pointer_near = near;
    retime(bar);
}

/// Starts (or drops) the delay before `shown` follows what the pointer wants.
pub fn retime(bar: *Self) void {
    const wanted = bar.pointer_near or menuOpen(bar);
    if (wanted == bar.shown) return disarm(bar);
    if (bar.timer_target == wanted) return;
    bar.timer_target = wanted;
    const delay: i32 = if (wanted) reveal_delay_ms else hide_delay_ms;
    if (bar.reveal_timer == null) {
        bar.reveal_timer = bar.server.wl_server.getEventLoop().addTimer(*Self, onTimer, bar) catch null;
    }
    if (bar.reveal_timer) |timer| {
        if (timer.timerUpdate(delay)) return else |_| {}
    }
    // No timer: follow at once.
    _ = onTimer(bar);
}

pub fn disarm(bar: *Self) void {
    if (bar.timer_target == null) return;
    bar.timer_target = null;
    if (bar.reveal_timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn onTimer(bar: *Self) c_int {
    if (bar.timer_target) |wanted| bar.shown = wanted;
    bar.timer_target = null;
    bar.wlr_output.scheduleFrame();
    return 0;
}
