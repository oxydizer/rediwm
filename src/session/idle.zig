//! Idle notification, surface-based inhibition, and display blanking policy.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const LayerSurface = @import("../LayerSurface.zig");
const loader = @import("config").loader;
const IdleConfig = loader.IdleConfig;

const log = std.log.scoped(.idle);

pub const State = enum {
    active,
    blanked,
    suspend_pending,
};

pub const ActivitySource = enum {
    keyboard,
    pointer,
    touch,
    tablet,
    virtual,
    lid,
};

pub const Clock = struct {
    now_ms_fn: ?*const fn () i64 = null,
    mock_now_ms: ?i64 = null,

    pub fn nowMs(self: Clock) i64 {
        if (self.mock_now_ms) |m| return m;
        if (self.now_ms_fn) |f| return f();
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
    }
};

pub const TrackedInhibitor = struct {
    inhibitor: *wlr.IdleInhibitorV1,
    manager: *IdleManager,
    destroy_listener: wl.Listener(*wlr.Surface) = .init(handleInhibitorDestroy),
    link: wl.list.Link = undefined,
    is_effective: bool = false,
    reason: []const u8 = "",

    fn handleInhibitorDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const tracked: *TrackedInhibitor = @fieldParentPtr("destroy_listener", listener);
        const manager = tracked.manager;
        tracked.destroy_listener.link.remove();
        tracked.link.remove();
        @import("../main.zig").gpa.destroy(tracked);
        manager.recheckInhibitors();
    }
};

pub const SurfaceVisibility = struct {
    visible: bool,
    window_id: ?u64 = null,
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    reason: []const u8 = "",
};

pub const IdleManager = struct {
    server: ?*Server = null,
    config: IdleConfig,
    state: State = .active,
    clock: Clock = .{},

    last_activity_ms: i64 = 0,
    timer_source: ?*wl.EventSource = null,

    idle_notifier: ?*wlr.IdleNotifierV1 = null,
    idle_inhibit_manager: ?*wlr.IdleInhibitManagerV1 = null,

    new_inhibitor_listener: wl.Listener(*wlr.IdleInhibitorV1) = .init(handleNewInhibitor),
    inhibitors: wl.list.Head(TrackedInhibitor, .link) = undefined,

    is_inhibited: bool = false,
    effective_inhibitor_count: usize = 0,

    wake_consume_pending_key: ?u32 = null,
    wake_consume_pending_button: ?u32 = null,

    suspend_request_count: usize = 0,

    pub fn create(server: *Server, config: IdleConfig) !*IdleManager {
        const gpa = @import("../main.zig").gpa;
        const self = try gpa.create(IdleManager);
        errdefer gpa.destroy(self);

        self.* = .{
            .server = server,
            .config = config,
        };
        self.inhibitors.init();
        self.last_activity_ms = self.clock.nowMs();

        // Create Wayland globals for idle notification and idle inhibition
        self.idle_notifier = wlr.IdleNotifierV1.create(server.wl_server) catch |err| blk: {
            log.warn("create: failed to create ext-idle-notify global: {}", .{err});
            break :blk null;
        };

        self.idle_inhibit_manager = wlr.IdleInhibitManagerV1.create(server.wl_server) catch |err| blk: {
            log.warn("create: failed to create idle-inhibit global: {}", .{err});
            break :blk null;
        };

        if (self.idle_inhibit_manager) |mgr| {
            mgr.events.new_inhibitor.add(&self.new_inhibitor_listener);
        }

        const loop = server.wl_server.getEventLoop();
        self.timer_source = loop.addTimer(*IdleManager, handleTimerCallback, self) catch |err| blk: {
            log.warn("create: failed to register timer: {}", .{err});
            break :blk null;
        };

        self.armNextTimeout();
        return self;
    }

    pub fn destroy(self: *IdleManager) void {
        const gpa = @import("../main.zig").gpa;

        if (self.timer_source) |source| {
            source.remove();
            self.timer_source = null;
        }

        if (self.idle_inhibit_manager != null) {
            self.new_inhibitor_listener.link.remove();
        }

        while (self.inhibitors.first()) |tracked| {
            tracked.destroy_listener.link.remove();
            tracked.link.remove();
            gpa.destroy(tracked);
        }

        gpa.destroy(self);
    }

    fn handleNewInhibitor(listener: *wl.Listener(*wlr.IdleInhibitorV1), inhibitor: *wlr.IdleInhibitorV1) void {
        const self: *IdleManager = @fieldParentPtr("new_inhibitor_listener", listener);
        const gpa = @import("../main.zig").gpa;
        const tracked = gpa.create(TrackedInhibitor) catch |err| {
            log.err("handleNewInhibitor: out of memory: {}", .{err});
            return;
        };
        tracked.* = .{
            .inhibitor = inhibitor,
            .manager = self,
        };
        inhibitor.events.destroy.add(&tracked.destroy_listener);
        self.inhibitors.append(tracked);
        self.recheckInhibitors();
    }

    fn handleTimerCallback(self: *IdleManager) c_int {
        self.tickTimer();
        return 0;
    }

    pub fn isPolicyEnabled(self: *const IdleManager) bool {
        if (self.config.enabled) |e| return e;
        if (self.server) |server| return server.backend.isDrm();
        return false;
    }

    pub fn tickTimer(self: *IdleManager) void {
        if (!self.isPolicyEnabled() or self.is_inhibited) return;
        const now = self.clock.nowMs();
        const elapsed = now - self.last_activity_ms;

        switch (self.state) {
            .active => {
                const blank_ms = @as(i64, self.config.blank_after_seconds) * 1000;
                if (self.config.blank_after_seconds > 0 and elapsed >= blank_ms) {
                    self.blankOutputs();
                } else {
                    self.armNextTimeout();
                }
            },
            .blanked => {
                const suspend_ms = @as(i64, self.config.suspend_after_seconds) * 1000;
                if (self.config.suspend_after_seconds > 0 and elapsed >= suspend_ms) {
                    self.state = .suspend_pending;
                    self.suspend_request_count += 1;
                    log.info("idle suspend deadline reached", .{});
                } else {
                    self.armNextTimeout();
                }
            },
            .suspend_pending => {},
        }
    }

    pub fn armNextTimeout(self: *IdleManager) void {
        if (!self.isPolicyEnabled() or self.is_inhibited) {
            self.disarmTimer();
            return;
        }

        const now = self.clock.nowMs();
        switch (self.state) {
            .active => {
                if (self.config.blank_after_seconds == 0) {
                    self.disarmTimer();
                    return;
                }
                const blank_ms = @as(i64, self.config.blank_after_seconds) * 1000;
                const elapsed = now - self.last_activity_ms;
                const remaining_ms = @max(1, blank_ms - elapsed);
                self.setTimerMs(@intCast(remaining_ms));
            },
            .blanked => {
                if (self.config.suspend_after_seconds == 0) {
                    self.disarmTimer();
                    return;
                }
                const suspend_ms = @as(i64, self.config.suspend_after_seconds) * 1000;
                const elapsed = now - self.last_activity_ms;
                const remaining_ms = @max(1, suspend_ms - elapsed);
                self.setTimerMs(@intCast(remaining_ms));
            },
            .suspend_pending => {
                self.disarmTimer();
            },
        }
    }

    fn setTimerMs(self: *IdleManager, ms: u32) void {
        if (self.timer_source) |source| {
            source.timerUpdate(@intCast(ms)) catch |err| {
                log.warn("setTimerMs: timerUpdate failed: {}", .{err});
            };
        }
    }

    fn disarmTimer(self: *IdleManager) void {
        if (self.timer_source) |source| {
            source.timerUpdate(0) catch {};
        }
    }

    pub fn blankOutputs(self: *IdleManager) void {
        if (self.state == .blanked) return;
        self.state = .blanked;
        if (self.server) |server| {
            var it = server.outputs.iterator(.forward);
            while (it.next()) |output| {
                _ = output.setIdleBlanked(true);
            }
        }
        log.info("displays blanked by idle policy", .{});
        self.armNextTimeout();
    }

    pub fn wakeOutputs(self: *IdleManager) void {
        const was_blanked = (self.state != .active);
        self.state = .active;
        if (was_blanked) {
            if (self.server) |server| {
                var it = server.outputs.iterator(.forward);
                while (it.next()) |output| {
                    if (!output.power_off) _ = output.setIdleBlanked(false);
                }
            }
            log.info("displays restored from idle", .{});
        }
        self.armNextTimeout();
    }

    pub fn notifyActivity(self: *IdleManager, source: ActivitySource) void {
        _ = source;
        const now = self.clock.nowMs();
        self.last_activity_ms = now;

        if (self.server) |server| {
            if (self.idle_notifier) |notifier| {
                notifier.notifyActivity(server.input.seat);
            }
        }

        if (self.state != .active) {
            self.wakeOutputs();
        } else if (!self.is_inhibited and self.isPolicyEnabled()) {
            self.armNextTimeout();
        }
        if (self.server) |server| @import("../output_power.zig").wakeIfAllDark(server);
    }

    /// Consumes the first key press when blanked and absorbs its matching release.
    /// Returns true if the key event should be dropped.
    pub fn interceptWakeKey(self: *IdleManager, keycode: u32, key_state: wl.Keyboard.KeyState) bool {
        if (self.state != .active) {
            if (key_state == .pressed) {
                self.wake_consume_pending_key = keycode;
                self.notifyActivity(.keyboard);
                return true;
            }
        } else if (self.wake_consume_pending_key) |pending| {
            if (key_state == .released and keycode == pending) {
                self.wake_consume_pending_key = null;
                return true;
            }
        }
        return false;
    }

    /// Consumes the first button press when blanked and absorbs its matching release.
    /// Returns true if the button event should be dropped.
    pub fn interceptWakeButton(self: *IdleManager, button: u32, btn_state: wl.Pointer.ButtonState) bool {
        if (self.state != .active) {
            if (btn_state == .pressed) {
                self.wake_consume_pending_button = button;
                self.notifyActivity(.pointer);
                return true;
            }
        } else if (self.wake_consume_pending_button) |pending| {
            if (btn_state == .released and button == pending) {
                self.wake_consume_pending_button = null;
                return true;
            }
        }
        return false;
    }

    pub fn checkSurfaceVisibility(self: *IdleManager, surface: *wlr.Surface) SurfaceVisibility {
        const server = self.server orelse return .{ .visible = false, .reason = "no server" };
        if (Toplevel.fromSurface(server, surface)) |toplevel| {
            const win_id = toplevel.id;
            const title = toplevel.title();
            const app_id = toplevel.appId();

            if (!toplevel.isMapped()) {
                return .{ .visible = false, .window_id = win_id, .app_id = app_id, .title = title, .reason = "unmapped toplevel" };
            }
            if (toplevel.minimized) {
                return .{ .visible = false, .window_id = win_id, .app_id = app_id, .title = title, .reason = "minimized" };
            }

            const bounds = server.world.bounds;
            const camera = server.world.camera;
            const x: f64 = @floatFromInt(toplevel.x);
            const y: f64 = @floatFromInt(toplevel.y);
            const w: f64 = @floatFromInt(toplevel.chrome_width);
            const h: f64 = @floatFromInt(toplevel.chrome_height);

            const tl = camera.toLayout(bounds, x, y);
            const br = camera.toLayout(bounds, x + w, y + h);
            const min_x = @min(tl.x, br.x);
            const max_x = @max(tl.x, br.x);
            const min_y = @min(tl.y, br.y);
            const max_y = @max(tl.y, br.y);

            var it = server.outputs.iterator(.forward);
            var intersects_any = false;
            while (it.next()) |output| {
                if (!output.isLogicallyEnabled()) continue;
                const obox = output.cached_box;
                const ox1: f64 = @floatFromInt(obox.x);
                const oy1: f64 = @floatFromInt(obox.y);
                const ox2: f64 = @floatFromInt(obox.x + obox.width);
                const oy2: f64 = @floatFromInt(obox.y + obox.height);

                if (max_x > ox1 and min_x < ox2 and max_y > oy1 and min_y < oy2) {
                    intersects_any = true;
                    break;
                }
            }

            if (!intersects_any) {
                return .{ .visible = false, .window_id = win_id, .app_id = app_id, .title = title, .reason = "off-canvas" };
            }
            return .{ .visible = true, .window_id = win_id, .app_id = app_id, .title = title, .reason = "visible toplevel" };
        }

        var lit = server.layer_surfaces.iterator(.forward);
        while (lit.next()) |layer| {
            if (layer.layer.surface == surface or layer.layer.surface == surface.getRootSurface()) {
                if (!layer.layer.surface.mapped) {
                    return .{ .visible = false, .reason = "unmapped layer surface" };
                }
                if (layer.layer.output) |out| {
                    if (Output.fromWlr(out)) |output| {
                        if (output.isLogicallyEnabled()) {
                            return .{ .visible = true, .reason = "visible layer surface" };
                        }
                    }
                }
                return .{ .visible = false, .reason = "layer surface on disabled output" };
            }
        }

        if (wlr.XwaylandSurface.tryFromWlrSurface(surface)) |xs| {
            if (xs.override_redirect) {
                if (xs.data) |d| {
                    const unmanaged: *@import("../xwayland_unmanaged.zig") = @ptrCast(@alignCast(d));
                    if (!unmanaged.tree.node.enabled) {
                        return .{ .visible = false, .reason = "unmapped xwayland unmanaged" };
                    }
                    const bounds = server.world.bounds;
                    const camera = server.world.camera;
                    const x = @as(f64, @floatFromInt(unmanaged.tree.node.x));
                    const y = @as(f64, @floatFromInt(unmanaged.tree.node.y));
                    const w = @as(f64, @floatFromInt(xs.width));
                    const h = @as(f64, @floatFromInt(xs.height));
                    const tl = camera.toLayout(bounds, x, y);
                    const br = camera.toLayout(bounds, x + w, y + h);
                    var oit = server.outputs.iterator(.forward);
                    while (oit.next()) |output| {
                        if (!output.isLogicallyEnabled()) continue;
                        const obox = output.cached_box;
                        if (@max(tl.x, br.x) > @as(f64, @floatFromInt(obox.x)) and
                            @min(tl.x, br.x) < @as(f64, @floatFromInt(obox.x + obox.width)) and
                            @max(tl.y, br.y) > @as(f64, @floatFromInt(obox.y)) and
                            @min(tl.y, br.y) < @as(f64, @floatFromInt(obox.y + obox.height)))
                        {
                            return .{ .visible = true, .reason = "visible xwayland unmanaged" };
                        }
                    }
                    return .{ .visible = false, .reason = "off-canvas xwayland unmanaged" };
                }
            }
        }

        return .{ .visible = false, .reason = "unknown or unattached surface" };
    }

    pub fn recheckInhibitors(self: *IdleManager) void {
        var effective_count: usize = 0;
        var it = self.inhibitors.iterator(.forward);
        while (it.next()) |tracked| {
            const vis = self.checkSurfaceVisibility(tracked.inhibitor.surface);
            tracked.is_effective = vis.visible;
            tracked.reason = vis.reason;
            if (vis.visible) effective_count += 1;
        }

        self.effective_inhibitor_count = effective_count;
        const now_inhibited = (effective_count > 0);
        const was_inhibited = self.is_inhibited;

        if (now_inhibited != was_inhibited) {
            self.is_inhibited = now_inhibited;
            if (self.idle_notifier) |notifier| {
                notifier.setInhibited(now_inhibited);
            }

            if (now_inhibited) {
                if (self.state != .active) {
                    self.wakeOutputs();
                }
                self.disarmTimer();
            } else {
                self.last_activity_ms = self.clock.nowMs();
                self.armNextTimeout();
            }
        }
    }

    pub fn inhibitorCount(self: *IdleManager) usize {
        var count: usize = 0;
        var it = self.inhibitors.iterator(.forward);
        while (it.next()) |_| count += 1;
        return count;
    }

    pub fn applyConfig(self: *IdleManager, new_cfg: IdleConfig) void {
        self.config = new_cfg;

        if (!self.isPolicyEnabled()) {
            if (self.state != .active) {
                self.wakeOutputs();
            }
            self.disarmTimer();
            return;
        }

        if (self.state == .blanked and self.config.blank_after_seconds == 0) {
            self.wakeOutputs();
            return;
        }

        self.recheckInhibitors();
        if (!self.is_inhibited) {
            self.armNextTimeout();
        }
    }
};

test "idle state transitions with simulated clock" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
            .suspend_after_seconds = 30,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
    };
    im.inhibitors.init();

    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(true, im.isPolicyEnabled());

    // 5 seconds elapsed: still active
    im.clock.mock_now_ms = 6000;
    im.tickTimer();
    try std.testing.expectEqual(State.active, im.state);

    // 10 seconds elapsed: transitions to blanked
    im.clock.mock_now_ms = 11000;
    im.tickTimer();
    try std.testing.expectEqual(State.blanked, im.state);

    // 25 seconds elapsed: still blanked (suspend is at 30s)
    im.clock.mock_now_ms = 26000;
    im.tickTimer();
    try std.testing.expectEqual(State.blanked, im.state);

    // 30 seconds elapsed: transitions to suspend_pending
    im.clock.mock_now_ms = 31000;
    im.tickTimer();
    try std.testing.expectEqual(State.suspend_pending, im.state);
    try std.testing.expectEqual(@as(usize, 1), im.suspend_request_count);

    // User activity restores display
    im.clock.mock_now_ms = 35000;
    im.notifyActivity(.keyboard);
    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(@as(i64, 35000), im.last_activity_ms);
}

test "wake key absorption and matching release" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .state = .blanked,
    };
    im.inhibitors.init();

    // First key press when blanked is absorbed and wakes displays
    try std.testing.expect(im.interceptWakeKey(30, .pressed));
    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(@as(?u32, 30), im.wake_consume_pending_key);

    // Another key press while waking/active is NOT absorbed
    try std.testing.expect(!im.interceptWakeKey(31, .pressed));

    // Release of an unrelated key is NOT absorbed
    try std.testing.expect(!im.interceptWakeKey(31, .released));
    try std.testing.expectEqual(@as(?u32, 30), im.wake_consume_pending_key);

    // Matching key release is absorbed and clears pending
    try std.testing.expect(im.interceptWakeKey(30, .released));
    try std.testing.expectEqual(@as(?u32, null), im.wake_consume_pending_key);

    // Subsequent press/release are normal (not absorbed)
    try std.testing.expect(!im.interceptWakeKey(30, .pressed));
    try std.testing.expect(!im.interceptWakeKey(30, .released));
}

test "wake button absorption and matching release" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .state = .blanked,
    };
    im.inhibitors.init();

    // First mouse button click when blanked is absorbed and wakes displays
    try std.testing.expect(im.interceptWakeButton(0x110, .pressed));
    try std.testing.expectEqual(State.active, im.state);
    try std.testing.expectEqual(@as(?u32, 0x110), im.wake_consume_pending_button);

    // Another button press while active is not absorbed
    try std.testing.expect(!im.interceptWakeButton(0x111, .pressed));

    // Matching release is absorbed and clears pending
    try std.testing.expect(im.interceptWakeButton(0x110, .released));
    try std.testing.expectEqual(@as(?u32, null), im.wake_consume_pending_button);
}

test "config reload wakes blanked displays when policy disabled" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .state = .blanked,
    };
    im.inhibitors.init();

    // Reloading config with idle disabled should restore blanked outputs
    im.applyConfig(.{ .enabled = false, .blank_after_seconds = 10 });
    try std.testing.expectEqual(State.active, im.state);
}

test "idle inhibitor release starts fresh timeout" {
    var im: IdleManager = .{
        .config = .{
            .enabled = true,
            .blank_after_seconds = 10,
        },
        .clock = .{ .mock_now_ms = 1000 },
        .last_activity_ms = 1000,
        .is_inhibited = true,
    };
    im.inhibitors.init();

    // Time elapses past blank deadline, but inhibition prevents blanking
    im.clock.mock_now_ms = 25000;
    im.tickTimer();
    try std.testing.expectEqual(State.active, im.state);

    // Release inhibitor: simulated activity timestamp reset to now
    im.is_inhibited = false;
    im.last_activity_ms = im.clock.nowMs();
    try std.testing.expectEqual(@as(i64, 25000), im.last_activity_ms);

    // 5 seconds after release: still active
    im.clock.mock_now_ms = 30000;
    im.tickTimer();
    try std.testing.expectEqual(State.active, im.state);

    // 10 seconds after release: blanks
    im.clock.mock_now_ms = 35000;
    im.tickTimer();
    try std.testing.expectEqual(State.blanked, im.state);
}
