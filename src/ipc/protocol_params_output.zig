//! `set_output_config` parameters, kept apart from `protocol_params.zig`'s
//! action switch.

const std = @import("std");
const output_transform = @import("config").output_transform;
const OutputConfigPatch = @import("protocol_results.zig").OutputConfigPatch;
const ParseError = @import("protocol_parse.zig").ParseError;
const parseI32 = @import("protocol_parse.zig").parseI32;
const parseF64 = @import("protocol_parse.zig").parseF64;

pub fn parseOutputConfigParams(allocator: std.mem.Allocator, params: ?std.json.ObjectMap) ParseError!OutputConfigPatch {
    const p = params orelse return error.InvalidRequest;
    const name = p.get("output") orelse return error.InvalidRequest;
    if (name != .string or name.string.len == 0) return error.InvalidRequest;
    var patch = OutputConfigPatch{ .output = try allocator.dupe(u8, name.string) };
    inline for (.{ "width", "height", "refresh_mhz", "x", "y" }) |field| {
        if (p.get(field)) |value| @field(patch, field) = try parseI32(value);
    }
    if (p.get("scale")) |value| {
        if (value == .string and std.mem.eql(u8, value.string, "auto")) {
            patch.auto_scale = true;
        } else {
            const scale = try parseF64(value);
            if (scale < 1 or scale > 3) return error.InvalidRequest;
            patch.scale = @floatCast(scale);
        }
    }
    if (p.get("position")) |value| {
        if (value != .string or !std.mem.eql(u8, value.string, "auto")) return error.InvalidRequest;
        patch.auto_position = true;
    }
    if (p.get("enabled")) |value| {
        if (value != .bool) return error.InvalidRequest;
        patch.enabled = value.bool;
    }
    if (p.get("primary")) |value| {
        if (value != .bool) return error.InvalidRequest;
        patch.primary = value.bool;
    }
    if (p.get("transform")) |value| {
        if (value != .string) return error.InvalidRequest;
        patch.transform = output_transform.parseName(value.string) catch return error.InvalidRequest;
    }
    if (p.get("adaptive_sync")) |value| {
        if (value != .string) return error.InvalidRequest;
        patch.adaptive_sync = std.meta.stringToEnum(@import("config").output_config.AdaptiveSync, value.string) orelse return error.InvalidRequest;
    }
    if (p.get("hdr")) |value| {
        if (value != .string) return error.InvalidRequest;
        patch.hdr = std.meta.stringToEnum(@import("config").output_config.Hdr, value.string) orelse return error.InvalidRequest;
    }
    if (p.get("sdr_white")) |value| patch.sdr_white = @floatCast(try parseF64(value));
    patch.validate() catch return error.InvalidRequest;
    return patch;
}
