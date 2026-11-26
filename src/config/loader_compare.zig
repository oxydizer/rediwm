//! Config comparison: which parts of two configs differ, for hot reload.

const std = @import("std");
const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
const ui_wheel = @import("ui").wheel;
const types = @import("types.zig");
const schedule_mod = @import("schedule.zig");
const NightLightConfig = schedule_mod.NightLightConfig;
const AccelProfile = types.AccelProfile;
const PanModifier = types.PanModifier;
const InputConfig = @import("loader.zig").InputConfig;
const OutputConfig = @import("loader.zig").OutputConfig;

pub fn outputsLayoutEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.x != right.x or left.y != right.y or left.scale != right.scale or left.width != right.width or left.height != right.height or left.refresh_mhz != right.refresh_mhz or left.enabled != right.enabled or left.primary != right.primary or left.transform != right.transform) return false;
    }
    return true;
}

pub fn outputsAdaptiveSyncEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.adaptive_sync != right.adaptive_sync) return false;
    }
    return true;
}

pub fn outputsHdrEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.hdr != right.hdr or left.sdr_white != right.sdr_white) return false;
    }
    return true;
}

pub fn outputsColorEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or left.night_light != right.night_light or left.gamma != right.gamma) return false;
    }
    return true;
}

pub fn outputsEql(a: []const OutputConfig, b: []const OutputConfig) bool {
    return outputsLayoutEql(a, b);
}

pub fn nightLightEql(a: NightLightConfig, b: NightLightConfig) bool {
    return a.enabled == b.enabled and
        a.schedule == b.schedule and
        a.temperature == b.temperature and
        a.day_temperature == b.day_temperature and
        a.start == b.start and
        a.end == b.end and
        a.transition_minutes == b.transition_minutes and
        a.latitude == b.latitude and
        a.longitude == b.longitude;
}

pub fn wheelAccel(cfg: InputConfig) ui_wheel.Accel {
    return .{ .gain = cfg.wheel_acceleration, .max = cfg.wheel_acceleration_max };
}

pub fn inputEql(a: InputConfig, b: InputConfig) bool {
    inline for (@typeInfo(InputConfig).@"struct".field_names) |field_name| {
        const left = @field(a, field_name);
        const right = @field(b, field_name);
        switch (@FieldType(InputConfig, field_name)) {
            []const u8 => if (!std.mem.eql(u8, left, right)) return false,
            []const []const u8 => {
                if (left.len != right.len) return false;
                for (left, right) |l, r| if (!std.mem.eql(u8, l, r)) return false;
            },
            bool, u32, f32 => if (left != right) return false,
            AccelProfile, PanModifier => if (left != right) return false,
            [2]f32 => if (left[0] != right[0] or left[1] != right[1]) return false,
            else => @compileError("no input equality for " ++ field_name),
        }
    }
    return true;
}

pub fn themeEql(a: Theme, b: Theme) bool {
    inline for (@typeInfo(Theme).@"struct".field_names) |field_name| {
        const left = @field(a, field_name);
        const right = @field(b, field_name);
        if (@FieldType(Theme, field_name) == []const u8) {
            if (!std.mem.eql(u8, left, right)) return false;
        } else if (!std.meta.eql(left, right)) return false;
    }
    return true;
}
