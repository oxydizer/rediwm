// Adapted from zig-wlroots; see LICENSE.zig-wlroots.
const c = @import("c.zig").c;
const abi = @import("abi.zig");

const wlr = @import("wlr.zig");

pub const NamedPrimaries = enum(c_int) {
    srgb = c.WLR_COLOR_NAMED_PRIMARIES_SRGB,
    bt2020 = c.WLR_COLOR_NAMED_PRIMARIES_BT2020,
};

pub const TransferFunction = enum(c_int) {
    srgb = c.WLR_COLOR_TRANSFER_FUNCTION_SRGB,
    st2084_pq = c.WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
    ext_linear = c.WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR,
    gamma22 = c.WLR_COLOR_TRANSFER_FUNCTION_GAMMA22,
    bt1886 = c.WLR_COLOR_TRANSFER_FUNCTION_BT1886,
};

pub const SurfaceDescription = struct {
    transfer: TransferFunction,
    primaries: NamedPrimaries,
};

/// The client's committed image description. Untagged surfaces use the
/// compositor's SDR default, even on a PQ output.
pub fn surfaceDescription(surface: *wlr.Surface) ?SurfaceDescription {
    const description = c.wlr_surface_get_image_description_v1_data(@ptrCast(surface)) orelse return null;
    return .{
        .transfer = @fromBackingInt(@intCast(c.wlr_color_manager_v1_transfer_function_to_wlr(description.*.tf_named))),
        .primaries = @fromBackingInt(@intCast(c.wlr_color_manager_v1_primaries_to_wlr(description.*.primaries_named))),
    };
}

pub const Encoding = enum(c_int) {
    none = c.WLR_COLOR_ENCODING_NONE,
    identity = c.WLR_COLOR_ENCODING_IDENTITY,
    bt709 = c.WLR_COLOR_ENCODING_BT709,
    fcc = c.WLR_COLOR_ENCODING_FCC,
    bt601 = c.WLR_COLOR_ENCODING_BT601,
    smpte240 = c.WLR_COLOR_ENCODING_SMPTE240,
    bt2020 = c.WLR_COLOR_ENCODING_BT2020,
    bt2020_cl = c.WLR_COLOR_ENCODING_BT2020_CL,
    ictcp = c.WLR_COLOR_ENCODING_ICTCP,
};

pub const Range = enum(c_int) {
    none = c.WLR_COLOR_RANGE_NONE,
    limited = c.WLR_COLOR_RANGE_LIMITED,
    full = c.WLR_COLOR_RANGE_FULL,
};

pub const Cie1931Xy = extern struct {
    x: f32,
    y: f32,
};

pub const Primaries = extern struct {
    red: Cie1931Xy,
    green: Cie1931Xy,
    blue: Cie1931Xy,
    white: Cie1931Xy,
};

pub const Luminances = extern struct {
    min: f32,
    max: f32,
    reference: f32,
};

comptime {
    abi.assertLayout(Cie1931Xy, c.wlr_color_cie1931_xy);
    abi.assertLayout(Primaries, c.wlr_color_primaries);
    abi.assertLayout(Luminances, c.wlr_color_luminances);
}

pub fn primariesFromNamed(out: *Primaries, named: NamedPrimaries) void {
    c.wlr_color_primaries_from_named(@ptrCast(out), @intCast(@backingInt(named)));
}

pub fn transformInitLut3x1d(dim: usize, r: [*]const u16, g: [*]const u16, b: [*]const u16) ?*@import("wlr.zig").ColorTransform {
    return c.wlr_color_transform_init_lut_3x1d(dim, r, g, b);
}

pub fn transformUnref(transform: *@import("wlr.zig").ColorTransform) void {
    c.wlr_color_transform_unref(transform);
}
