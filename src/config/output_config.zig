const std = @import("std");
const output_transform = @import("output_transform.zig");

/// Variable refresh rate (FreeSync, G-Sync Compatible, Adaptive-Sync) per
/// output: on only while a game fills it, never, or always.
pub const AdaptiveSync = enum { off, auto, always };

/// HDR10 output (docs/plans/hdr.md), opt-in per output. An enum so `auto`
/// can follow once tone mapping has been seen on several monitors (D4).
pub const Hdr = enum { off, on };

/// SDR content brightness on an HDR output, in nits (cd/m²). The default is
/// the BT.2408 reference white.
pub const sdr_white_default: f32 = 203;
pub const sdr_white_min: f32 = 80;
pub const sdr_white_max: f32 = 1000;

/// Omitted fields retain their saved value. Automatic settings explicitly clear overrides.
pub const Patch = struct {
    output: []const u8 = "",
    width: ?i32 = null,
    height: ?i32 = null,
    refresh_mhz: ?i32 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    scale: ?f32 = null,
    auto_scale: bool = false,
    auto_position: bool = false,
    enabled: ?bool = null,
    primary: ?bool = null,
    transform: ?output_transform.Transform = null,
    adaptive_sync: ?AdaptiveSync = null,
    hdr: ?Hdr = null,
    sdr_white: ?f32 = null,

    pub fn validate(p: Patch) !void {
        inline for (.{ "width", "height", "refresh_mhz" }) |field| {
            if (@field(p, field)) |value| if (value <= 0) return error.InvalidOutputConfig;
        }
        if (p.scale) |scale| {
            if (!std.math.isFinite(scale) or scale < 1 or scale > 3 or p.auto_scale) return error.InvalidOutputConfig;
        }
        if (p.sdr_white) |nits| {
            if (!std.math.isFinite(nits) or nits < sdr_white_min or nits > sdr_white_max) return error.InvalidOutputConfig;
        }
        if (p.auto_position and (p.x != null or p.y != null)) return error.InvalidOutputConfig;
        // Leave ample room for output extents and integer layout arithmetic.
        inline for (.{ "x", "y" }) |field| {
            if (@field(p, field)) |value| if (value < -1_000_000 or value > 1_000_000) return error.InvalidOutputConfig;
        }
        if (p.width == null and p.height == null and p.refresh_mhz == null and
            p.x == null and p.y == null and p.scale == null and !p.auto_scale and !p.auto_position and
            p.enabled == null and p.primary == null and p.transform == null and p.adaptive_sync == null and
            p.hdr == null and p.sdr_white == null)
            return error.EmptyOutputConfig;
    }
};
