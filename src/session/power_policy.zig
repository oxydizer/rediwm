//! One power-source policy per session, independent of outputs and panels.
const std = @import("std");
const i18n = @import("i18n");
const wl = @import("wayland").server.wl;
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const battery = @import("../taskbar/battery.zig");
const cfg = @import("config").power;
const Profile = @import("../power_profiles.zig").Profile;
const Self = @This();

server: ?*Server = null,
timer: ?*wl.EventSource = null,
state: battery.State = .{},
source: ?cfg.Source = null,
effective: cfg.Profile = .{},
initialized: bool = false,
deferred_source: bool = false,
pending_mode: ?Profile = null,
saver_active: bool = false,
saver_restore: ?Profile = null,
critical_notified: bool = false,
lid_action: ?@import("config").types.LidAction = null,
lid_handling: bool = false,
dim_previous: ?f32 = null,
message: []const u8 = "",
charge_limit: @import("platform").charge_limit.State = .{},
charge_requested: ?u32 = null,

pub fn init(self: *Self, server: *Server) void {
    if (server.greeter_mode) return;
    self.server = server;
    self.timer = server.wl_server.getEventLoop().addTimer(*Self, minuteTick, self) catch null;
    self.refresh();
    self.armMinute();
}

pub fn deinit(self: *Self) void {
    if (self.timer) |timer| timer.remove();
    self.* = .{};
}

fn armMinute(self: *Self) void {
    const c = @import("../taskbar/c_time.zig").c;
    var now: c.struct_timespec = undefined;
    const delay: i32 = if (c.clock_gettime(c.CLOCK_REALTIME, &now) == 0)
        @intCast((60 - @mod(now.tv_sec, 60)) * 1000 - @divTrunc(now.tv_nsec, 1_000_000) + 1)
    else
        60_000;
    if (self.timer) |timer| timer.timerUpdate(delay) catch {};
}

fn minuteTick(self: *Self) c_int {
    self.refresh();
    self.armMinute();
    return 0;
}

pub fn enabled(self: *const Self) bool {
    const server = self.server orelse return false;
    if (server.greeter_mode) return false;
    if (server.session) |session| if (!session.active) return false;
    return server.config.power.enabled orelse server.backend.isDrm();
}

pub fn refresh(self: *Self) void {
    const server = self.server orelse return;
    const charge = @import("platform").charge_limit.read(server.io);
    if (charge.writable and !self.charge_limit.writable) self.charge_requested = null;
    const changed = !std.meta.eql(self.charge_limit, charge);
    self.charge_limit = charge;
    self.update(battery.read(server.io, @import("../main.zig").gpa));
    if (changed) self.refreshSettings();
}

pub fn update(self: *Self, state: battery.State) void {
    const server = self.server orelse return;
    if (!state.valid) return;
    const previous = self.state;
    self.state = state;
    const next: ?cfg.Source = if (!state.present) .plugged_in else if (state.external_power) |external| (if (external) .plugged_in else .on_battery) else self.source;
    const changed = next != self.source;
    self.source = next;
    self.apply(changed);
    self.batteryActions();
    self.serviceReady();
    server.battery_warning.threshold = server.config.power.low_battery_percent;
    server.updateBatteryWarning(state);
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| if (output.taskbar) |bar| bar.applyBattery(state);
    if (!std.meta.eql(previous, state)) self.refreshSettings();
}

pub fn reload(self: *Self) void {
    if (self.server == null) return;
    self.message = "";
    self.apply(false);
    if (!self.enabled()) {
        Output.applyLid(self.server.?);
        if (self.server.?.power) |manager| manager.syncInhibitors();
    }
    self.batteryActions();
    self.serviceReady();
    const server = self.server.?;
    server.battery_warning.threshold = server.config.power.low_battery_percent;
    server.updateBatteryWarning(self.state);
    self.refreshSettings();
}

fn apply(self: *Self, changed: bool) void {
    const server = self.server orelse return;
    const next = server.config.power.profile(self.source orelse .plugged_in);
    if (!self.enabled()) {
        self.deferred_source = self.deferred_source or changed;
        if (!(server.config.power.enabled orelse server.backend.isDrm())) {
            if (server.config.power.enabled == false) if (server.idle) |idle| {
                var disabled = idle.config;
                disabled.enabled = false;
                if (!std.meta.eql(disabled, idle.config)) idle.applyConfig(disabled);
            };
            self.initialized = false;
            self.undim();
        }
        return;
    }
    const activate = !self.initialized or self.deferred_source;
    self.initialized = true;
    self.deferred_source = false;
    const charge = server.config.power.charge_limit;
    if (self.charge_requested != charge) {
        self.charge_requested = charge;
        if (charge > 0) self.charge_limit = @import("platform").charge_limit.set(server.io, charge) catch blk: {
            self.failed(i18n.tr("Charging limit could not be changed. Check hardware support, permissions and the start threshold."));
            break :blk self.charge_limit;
        };
    }
    const old = self.effective;
    self.effective = next;
    if (server.idle) |idle| {
        var idle_cfg = cfg.idle(next, server.config.idle);
        if (server.config.power.enabled) |active| idle_cfg.enabled = active;
        if (!std.meta.eql(idle.config, idle_cfg)) idle.applyConfig(idle_cfg);
    }
    if (changed or activate or old.dim_after_seconds != next.dim_after_seconds or old.dim_brightness != next.dim_brightness) self.undim();
    if (self.source != null and (changed or activate or next.brightness != old.brightness)) {
        if (next.brightness > 0) server.brightness.setAuto(server, @as(f32, @floatFromInt(next.brightness)) / 100);
    }
    if (self.source != null and (changed or activate or next.keyboard_brightness != old.keyboard_brightness)) {
        if (next.keyboard_brightness) |level| server.keyboard_brightness.setAuto(server, @as(f32, @floatFromInt(level)) / 100);
    }
    if (next.dim_after_seconds > 0 and (activate or changed or old.dim_after_seconds != next.dim_after_seconds) and server.brightness.level == null) server.brightness.query(server);
    if (server.idle) |idle| idle.armNextTimeout();
    if (self.source != null and (changed or activate or next.mode != old.mode)) {
        const restore = if (server.power_profiles) |manager| (if (manager.active == .power_saver) self.saver_restore else null) else null;
        self.saver_active = false;
        self.saver_restore = null;
        self.pending_mode = mode(next.mode) orelse restore;
    }
    if (server.power) |power| power.syncInhibitors();
    Output.applyLid(server);
}

fn mode(value: cfg.Mode) ?Profile {
    return switch (value) {
        .unchanged => null,
        .power_saver => .power_saver,
        .balanced => .balanced,
        .performance => .performance,
    };
}

pub fn serviceReady(self: *Self) void {
    if (!self.enabled()) return;
    const wanted = self.pending_mode orelse return;
    const manager = self.server.?.power_profiles orelse return;
    if (!manager.isAvailable()) return;
    self.pending_mode = null;
    if (!manager.supports(wanted)) {
        self.failed(i18n.tr("The configured power mode is unavailable."));
        return;
    }
    manager.selectAuto(wanted);
}

pub fn manualMode(self: *Self) void {
    self.pending_mode = null;
    self.saver_restore = null;
}

pub fn confirmedMode(self: *Self, profile: Profile) void {
    if (profile != .power_saver) self.saver_restore = null;
    self.refreshSettings();
}

pub fn failed(self: *Self, message: []const u8) void {
    self.message = message;
    self.refreshSettings();
}

pub fn refreshSettings(self: *Self) void {
    const server = self.server orelse return;
    if (server.input.open_control_center) |cc| if (cc.showingPage(.power)) cc.refresh();
}

fn batteryActions(self: *Self) void {
    if (!self.enabled()) return;
    const server = self.server.?;
    const config = server.config.power;
    const percent = self.state.percent orelse return;
    const draining = self.state.discharging and !self.state.charging;
    const low = draining and config.power_saver_percent > 0 and percent <= config.power_saver_percent;
    const recovered = !draining or config.power_saver_percent == 0 or percent > @min(100, config.power_saver_percent + 5);
    if (low and !self.saver_active) {
        self.saver_active = true;
        self.saver_restore = mode(self.effective.mode) orelse (if (server.power_profiles) |manager| manager.active else null);
        self.pending_mode = .power_saver;
    } else if (recovered and self.saver_active) {
        self.saver_active = false;
        if (self.pending_mode == .power_saver) {
            // Recovery can precede service startup: cancel the stale request.
            self.pending_mode = self.saver_restore;
        } else if (self.saver_restore) |restore| {
            if (server.power_profiles) |manager| if (manager.active == .power_saver or manager.pending_sets > 0) {
                self.pending_mode = mode(self.effective.mode) orelse restore;
            };
        }
        self.saver_restore = null;
    }
    const critical = draining and config.critical_percent > 0 and percent <= config.critical_percent;
    if (!critical) {
        if (!draining or config.critical_percent == 0 or percent > @min(100, config.critical_percent + 3)) self.critical_notified = false;
    } else if (!self.critical_notified) {
        self.critical_notified = true;
        if (server.notifications) |notifications| {
            _ = notifications.postNotification(i18n.tr("Power"), 0, "battery-caution", i18n.tr("Critical battery"), i18n.tr("Battery is critically low. Plug in your charger."), &.{}, 2, false, false, 0, "", null) catch {};
        }
        if (server.power) |power| switch (config.critical_action) {
            .notify => {},
            .sleep => power.requestSuspendAuto(),
            .power_off => power.requestPowerOffAuto(),
        };
    }
}

pub fn lidAction(self: *const Self) @import("config").types.LidAction {
    const server = self.server orelse return .display_off;
    if (self.enabled() and server.config.power.docked == .keep_awake and Output.otherDisplayOn(server)) return .display_off;
    return if (self.enabled()) self.effective.lid_close orelse server.config.compositor.lid_close else server.config.compositor.lid_close;
}

/// Reconsider after a lid edge, display hotplug, source change or inhibitor acquisition.
pub fn reconcileLid(self: *Self) void {
    const server = self.server orelse return;
    if (!server.input.lid.closed) {
        self.lid_action = null;
        return;
    }
    if (!self.enabled() or self.lid_handling) return;
    const action = self.lidAction();
    if (self.lid_action == action) return;
    self.lid_handling = true;
    defer self.lid_handling = false;
    self.lid_action = action;
    switch (action) {
        .ignore, .display_off => {},
        .lock => @import("lock.zig").Lock.start(server),
        .@"suspend" => {
            // Without the inhibitor logind may also suspend; never send both.
            const manager = server.power orelse {
                self.lid_action = null;
                return;
            };
            if (manager.lid_fd == null) {
                self.lid_action = null;
                return;
            }
            manager.requestSuspendAuto();
        },
    }
}

pub fn lockOnSuspend(_: *const Self, server: *Server) bool {
    return server.config.power.lock_on_suspend orelse server.config.compositor.lock_on_suspend;
}

pub fn dim(self: *Self) void {
    if (!self.enabled() or self.dim_previous != null) return;
    const server = self.server.?;
    const level = server.brightness.level orelse {
        server.brightness.query(server);
        return;
    };
    const target = @as(f32, @floatFromInt(self.effective.dim_brightness)) / 100;
    if (target >= level) return;
    self.dim_previous = level;
    server.brightness.setAuto(server, target);
}

pub fn undim(self: *Self) void {
    if (self.dim_previous) |level| if (self.server) |server| server.brightness.setAuto(server, level);
    self.dim_previous = null;
}

pub fn manualBrightness(self: *Self) void {
    self.dim_previous = null;
}
