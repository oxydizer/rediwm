//! Power-source preferences. Missing values inherit the existing idle/lid settings.
const std = @import("std");
const fields = @import("loader_fields.zig");
const loader = @import("loader.zig");
pub const Mode = enum { unchanged, power_saver, balanced, performance };
pub const Docked = enum { follow, keep_awake };
pub const Critical = enum { notify, sleep, power_off };
pub const Source = enum { plugged_in, on_battery };

pub const Profile = struct {
    mode: Mode = .unchanged,
    /// Zero means leave unchanged; backlights never go below one percent.
    brightness: u32 = 0,
    keyboard_brightness: ?u32 = null,
    blank_after_seconds: ?u32 = null,
    suspend_after_seconds: ?u32 = null,
    lid_close: ?loader.LidAction = null,
    dim_after_seconds: u32 = 0,
    dim_brightness: u32 = 30,
};

pub const Config = struct {
    enabled: ?bool = null,
    plugged_in: Profile = .{},
    on_battery: Profile = .{},
    docked: Docked = .follow,
    lock_on_suspend: ?bool = null,
    low_battery_percent: u32 = 10,
    power_saver_percent: u32 = 0,
    critical_percent: u32 = 0,
    charge_limit: u32 = 0,
    critical_action: Critical = .notify,

    pub fn profile(self: Config, source: Source) Profile {
        return switch (source) {
            .plugged_in => self.plugged_in,
            .on_battery => self.on_battery,
        };
    }
};

pub fn applyProfile(p: *Profile, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "mode")) {
        p.mode = try fields.parseEnum(Mode, value);
        return;
    }
    if (std.mem.eql(u8, key, "lid_close")) {
        p.lid_close = try fields.parseEnum(loader.LidAction, value);
        return;
    }
    if (std.mem.eql(u8, key, "keyboard_brightness")) {
        p.keyboard_brightness = if (std.mem.eql(u8, value, "-1")) null else try fields.parseU32Range(value, 0, 100);
        return;
    }
    inline for (.{ "brightness", "dim_brightness" }) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(p, name) = try fields.parseU32Range(value, if (std.mem.eql(u8, name, "brightness")) 0 else 1, 100);
            return;
        }
    }
    inline for (.{ "dim_after_seconds", "blank_after_seconds", "suspend_after_seconds" }) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(p, name) = try fields.parseU32Range(value, 0, 86400);
            return;
        }
    }
    return error.InvalidField;
}

pub fn apply(config: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "enabled")) {
        config.enabled = try fields.parseBool(value);
        return;
    }
    if (std.mem.eql(u8, key, "docked")) {
        config.docked = try fields.parseEnum(Docked, value);
        return;
    }
    if (std.mem.eql(u8, key, "lock_on_suspend")) {
        config.lock_on_suspend = try fields.parseBool(value);
        return;
    }
    if (std.mem.eql(u8, key, "critical_action")) {
        config.critical_action = try fields.parseEnum(Critical, value);
        return;
    }
    if (std.mem.eql(u8, key, "charge_limit")) {
        config.charge_limit = if (std.mem.eql(u8, value, "0")) 0 else try fields.parseU32Range(value, 50, 100);
        return;
    }
    inline for (.{ "low_battery_percent", "power_saver_percent", "critical_percent" }) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(config, name) = try fields.parseU32Range(value, 0, 100);
            return;
        }
    }
    return error.InvalidField;
}

pub fn idle(profile_value: Profile, legacy: loader.IdleConfig) loader.IdleConfig {
    var result = legacy;
    result.blank_after_seconds = profile_value.blank_after_seconds orelse legacy.blank_after_seconds;
    result.suspend_after_seconds = profile_value.suspend_after_seconds orelse legacy.suspend_after_seconds;
    return result;
}

test {
    _ = @import("power_tests.zig");
}
