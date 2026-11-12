//! Space reservation and auto-hide: the reserved strip, footprint, reveal/hide timing and pointer proximity.

const std = @import("std");
const wlr = @import("wlroots");
const ui = @import("ui");
const Output = @import("../Output.zig");
const Server = @import("../Server.zig");
const glass = @import("../glass.zig");
const config = @import("config").loader;
const anim = ui.anim;
const Self = @import("../Dock.zig");
const max_pins = Self.max_pins;
const Shortcut = Self.Shortcut;
/// Pointer tolerance around a shown auto-hiding dock, independent of layout.
const pointer_margin = 5;
const edge_band = Self.edge_band;
const reveal_delay_ms = Self.reveal_delay_ms;
const hide_delay_ms = Self.hide_delay_ms;
const slide_distance = Self.slide_distance;
const Metrics = Self.Metrics;
const shownIn = Self.shownIn;

/// What a dock reserves along `area`'s edge for windows: exactly its thickness.
/// Nothing when it floats over them (auto-hide), is off, or
/// does not fit and so shows nothing.
pub fn reservedStrip(server: *const Server, area: wlr.Box) i32 {
    if (!reserves(&server.config.compositor)) return 0;
    return footprint(server, area);
}

/// How far a resting dock reaches in from its edge of `area`: its thickness,
/// whether it reserves that strip or auto-hides. Read from
/// the configuration alone, like `reservedStrip`, so what keeps clear of it (the
/// OSD) stays put while an auto-hiding dock comes and goes.
pub fn footprint(server: *const Server, area: wlr.Box) i32 {
    const c = &server.config.compositor;
    if (server.greeter_mode or !c.dock_enabled or !fits(c, area)) return 0;
    return @intCast(c.dock_height);
}

/// Whether the dock, as configured, keeps windows out of its strip. A change
/// to this (or to the dock's edge or size while it holds) moves the work area:
/// refit windows with `Server.applyTaskbarPosition`.
pub fn reserves(c: *const config.CompositorConfig) bool {
    return c.dock_enabled and !c.dock_auto_hide;
}

/// Whether the dock shows at all in `area` (the output less the taskbar). Read
/// from the configuration alone, so it agrees with what `reservedStrip` holds
/// back wherever it is asked.
pub fn fits(c: *const config.CompositorConfig, area: wlr.Box) bool {
    const m: Metrics = .{ .height = @intCast(c.dock_height) };
    const length = if (c.dock_position.vertical()) area.height else area.width;
    const thickness = if (c.dock_position.vertical()) area.width else area.height;
    const min_length = @max(260, @as(i32, @intCast(configuredFixedCount(c))) * m.itemStep() + m.padding() * 2 + 12);
    return length >= min_length and thickness >= @max(140, m.height + 72);
}

/// `fixedCount` from the configuration alone: an uninstalled pin counts.
pub fn configuredFixedCount(c: *const config.CompositorConfig) usize {
    var count: usize = @min(c.dock_pinned_apps.len, max_pins);
    for (std.enums.values(Shortcut)) |shortcut| {
        if (shownIn(c, shortcut)) count += 1;
    }
    return count;
}

/// Auto-hide: lets `reveal` follow the pointer's wish, and parks the dock once
/// it has gone. True while the reveal still moves.
pub fn syncReveal(self: *Self, now_ms: i64) bool {
    const server = self.output.?.server;
    var target: f32 = 1;
    if (server.config.compositor.dock_auto_hide) {
        self.retime();
        if (!self.shown) target = 0;
    } else {
        self.disarm();
        self.pointer_near = false;
        self.shown = false;
    }
    if (self.reveal.to != target) self.reveal.retargetTo(now_ms, target, anim.curveFor(.taskbar_hover));
    const moving = !self.reveal.settled(now_ms);
    self.parked = target == 0 and !moving;
    return moving;
}

/// The dock fades and slides toward its edge as `reveal` falls. The raster does
/// not change: only the node's position and opacity. Glass follows the position
/// as part of the tree, but its opacity is its own and is given here, or the
/// blurred backdrop would stay solid until the dock parks.
pub fn applyReveal(self: *Self, now_ms: i64) void {
    const t = std.math.clamp(self.reveal.value(now_ms), 0, 1);
    var x = self.box.x;
    var y = self.box.y;
    if (t < 1 and !anim.reducedMotion()) {
        const away: i32 = @intFromFloat(@round((1 - t) * slide_distance));
        switch (self.position) {
            .top => y -= away,
            .bottom => y += away,
            .left => x -= away,
            .right => x += away,
        }
    }
    self.tree.?.node.setPosition(x, y);
    self.node.?.setOpacity(t);
    glass.Effect.configure(self.glass_effect, self.glass_radius, t);
}

pub fn menuOpen(self: *const Self) bool {
    return self.output.?.server.input.window_menu.dock == self;
}

/// Whether the pointer at layout position `x`, `y` wants the dock: it is at the
/// output edge the dock is on, or on or just beside the dock once shown.
pub fn nearPointer(self: *const Self, output: *Output, x: f64, y: f64) bool {
    const c = &output.server.config.compositor;
    if (!c.dock_auto_hide or !self.visible) return false;
    const full = output.cached_box;
    const px: i32 = @intFromFloat(@floor(x));
    const py: i32 = @intFromFloat(@floor(y));
    if (px < full.x or py < full.y or px >= full.x + full.width or py >= full.y + full.height) return false;
    const at_edge = switch (c.dock_position) {
        .top => py < full.y + edge_band,
        .bottom => py >= full.y + full.height - edge_band,
        .left => px < full.x + edge_band,
        .right => px >= full.x + full.width - edge_band,
    };
    if (at_edge) return true;
    // Only a dock that is out can be pointed at: where it would be is windows.
    if (!self.shown) return false;
    return (px >= self.box.x - pointer_margin and px < self.box.x + self.box.width + pointer_margin and
        py >= self.box.y - pointer_margin and py < self.box.y + self.box.height + pointer_margin) or
        self.buttonAt(@floatCast(x - @as(f64, @floatFromInt(self.box.x))), @floatCast(y - @as(f64, @floatFromInt(self.box.y)))) != null;
}

/// Every pointer motion. `engaged` is false while a window is moved or resized
/// or a button is held for a client, none of which should raise the dock.
pub fn pointerAt(self: *Self, x: f64, y: f64, engaged: bool) void {
    const output = self.output orelse return;
    const near = engaged and self.nearPointer(output, x, y);
    if (near == self.pointer_near) return;
    self.pointer_near = near;
    self.retime();
}

/// Starts (or drops) the delay before `shown` follows what the pointer wants.
pub fn retime(self: *Self) void {
    const wanted = self.pointer_near or self.menuOpen();
    if (wanted == self.shown) return self.disarm();
    if (self.timer_target == wanted) return;
    self.timer_target = wanted;
    const delay: i32 = if (wanted) reveal_delay_ms else hide_delay_ms;
    const output = self.output.?;
    if (self.timer == null) self.timer = output.server.wl_server.getEventLoop().addTimer(*Self, onTimer, self) catch null;
    if (self.timer) |timer| {
        if (timer.timerUpdate(delay)) return else |_| {}
    }
    // No timer: follow at once.
    _ = onTimer(self);
}

pub fn disarm(self: *Self) void {
    if (self.timer_target == null) return;
    self.timer_target = null;
    if (self.timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn onTimer(self: *Self) c_int {
    if (self.timer_target) |wanted| self.shown = wanted;
    self.timer_target = null;
    if (self.output) |output| output.wlr_output.scheduleFrame();
    return 0;
}
