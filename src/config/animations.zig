// TOML overlay for `[animations]` / `[animations.<target>]`.
const std = @import("std");
const anim = @import("ui").anim;

pub const Settings = anim.Settings;
pub const Target = anim.Target;
pub const TargetFlags = struct {
    spring: bool = false,
    duration: bool = false,
    off: bool = false,
};

pub fn applyGlobalKey(cfg: *Settings, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "enabled")) {
        cfg.enabled = try parseBool(value);
    } else if (std.mem.eql(u8, key, "speed")) {
        cfg.speed = try parseFloatRange(value, 0, 8, false);
    } else if (std.mem.eql(u8, key, "reduced_motion")) {
        cfg.reduced_motion = try parseReducedMotion(value);
    } else {
        return error.InvalidField;
    }
}

pub fn applyTargetKey(
    cfg: *Settings,
    target: Target,
    flags: *TargetFlags,
    key: []const u8,
    value: []const u8,
) !void {
    const idx = @intFromEnum(target);
    var spec = cfg.targets[idx];
    if (std.mem.eql(u8, key, "off")) {
        if (flags.spring or flags.duration) return error.InvalidValue;
        if (!try parseBool(value)) return error.InvalidValue;
        flags.off = true;
        spec.curve = .off;
    } else if (std.mem.eql(u8, key, "spring")) {
        if (flags.off or flags.duration) return error.InvalidValue;
        flags.spring = true;
        const fallback = switch (spec.curve) {
            .spring => |s| s,
            else => switch (anim.defaultSpec(target).curve) {
                .spring => |s| s,
                else => if (target == .camera_pan) anim.springs.camera_pan else anim.Spring{},
            },
        };
        spec.curve = .{ .spring = try parseSpringTable(value, fallback, target) };
    } else if (std.mem.eql(u8, key, "duration_ms")) {
        if (flags.off or flags.spring) return error.InvalidValue;
        flags.duration = true;
        const ms: i64 = @intCast(try parseU32Range(value, 0, 10_000));
        const ease = switch (spec.curve) {
            .duration => |d| d.ease,
            else => anim.Ease.out_cubic,
        };
        spec.curve = .{ .duration = .{ .ms = ms, .ease = ease } };
    } else if (std.mem.eql(u8, key, "ease")) {
        if (flags.off or flags.spring) return error.InvalidValue;
        flags.duration = true;
        const ease = try parseEase(value);
        const ms: i64 = switch (spec.curve) {
            .duration => |d| d.ms,
            else => 90,
        };
        spec.curve = .{ .duration = .{ .ms = ms, .ease = ease } };
    } else if (std.mem.eql(u8, key, "decay_rate")) {
        spec.decay.rate = try parseFloatRange(value, 0.9, 0.9999, false);
        if (spec.decay.rate <= 0 or spec.decay.rate >= 1) return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "decay_threshold")) {
        spec.decay.threshold = try parseFloatRange(value, 0.001, 32, false);
    } else {
        return error.InvalidField;
    }
    cfg.targets[idx] = spec;
}

pub fn parseSpringTable(value: []const u8, fallback: anim.Spring, target: Target) !anim.Spring {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.InvalidValue;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return error.InvalidValue;
    var spring = fallback;
    var seen: u8 = 0;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidValue;
        const k = std.mem.trim(u8, part[0..eq], " \t");
        const v = std.mem.trim(u8, part[eq + 1 ..], " \t");
        if (std.mem.eql(u8, k, "damping_ratio")) {
            spring.damping_ratio = try parseFloatRange(v, 0.05, 20, false);
        } else if (std.mem.eql(u8, k, "stiffness")) {
            spring.stiffness = try parseFloatRange(v, 1, 20_000, false);
        } else if (std.mem.eql(u8, k, "epsilon")) {
            const bounds = anim.epsilonBounds(target);
            spring.epsilon = try parseFloatRange(v, bounds.min, bounds.max, false);
        } else return error.InvalidField;
        seen += 1;
    }
    if (seen == 0) return error.InvalidValue;
    if (!(spring.damping_ratio > 0) or !(spring.stiffness > 0) or !(spring.epsilon > 0)) return error.InvalidValue;
    if (!std.math.isFinite(spring.damping_ratio) or !std.math.isFinite(spring.stiffness) or !std.math.isFinite(spring.epsilon)) {
        return error.InvalidValue;
    }
    return spring;
}

fn parseReducedMotion(value: []const u8) !anim.ReducedMotion {
    const s = unquote(value);
    return std.meta.stringToEnum(anim.ReducedMotion, s) orelse error.InvalidValue;
}

fn parseEase(value: []const u8) !anim.Ease {
    const s = unquote(value);
    return std.meta.stringToEnum(anim.Ease, s) orelse error.InvalidValue;
}

fn unquote(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}

fn parseU32Range(value: []const u8, min: u32, max: u32) !u32 {
    const n = try std.fmt.parseInt(u32, value, 10);
    if (n < min or n > max) return error.InvalidValue;
    return n;
}

fn parseFloatRange(value: []const u8, min: f32, max: f32, exclusive_min: bool) !f32 {
    const v = try std.fmt.parseFloat(f32, value);
    if (!std.math.isFinite(v) or v < min or v > max or (exclusive_min and v == min)) return error.InvalidValue;
    return v;
}
