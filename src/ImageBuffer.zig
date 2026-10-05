// A decoded image handed to the scene graph as a plain data-pointer buffer,
// on the same footing as the chrome that chrome.ChromeBuffer rasterizes.
const wlr = @import("wlroots");

const png = @import("png.zig");
const gpa = @import("main.zig").gpa;

const ImageBuffer = @This();

base: wlr.Buffer,
width: i32,
height: i32,
format: u32,
pixels: []u32,

const drm_format_argb8888: u32 = 0x34325241; // DRM_FORMAT_ARGB8888
const drm_format_xrgb8888: u32 = 0x34325258; // DRM_FORMAT_XRGB8888

const impl = wlr.Buffer.Impl{
    .destroy = destroy,
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = beginDataPtrAccess,
    .end_data_ptr_access = endDataPtrAccess,
};

pub fn createFromPng(bytes: []const u8) !*ImageBuffer {
    const decoded = try png.decode(gpa, bytes);
    errdefer decoded.deinit(gpa);
    return createFromDecoded(decoded);
}

/// Takes ownership of `decoded.pixels`.
pub fn createFromDecoded(decoded: png.Image) !*ImageBuffer {
    const image = try gpa.create(ImageBuffer);
    errdefer gpa.destroy(image);
    image.* = .{
        .base = undefined,
        .width = decoded.width,
        .height = decoded.height,
        .format = if (decoded.has_alpha) drm_format_argb8888 else drm_format_xrgb8888,
        .pixels = decoded.pixels,
    };
    image.base.init(&impl, decoded.width, decoded.height);
    return image;
}

/// Allocate an owned compositor raster, in premultiplied ARGB8888.
pub fn createSolid(width: i32, height: i32, color: u32) !*ImageBuffer {
    const image = try gpa.create(ImageBuffer);
    errdefer gpa.destroy(image);
    const pixels = try gpa.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    @memset(pixels, color);
    image.* = .{ .base = undefined, .width = width, .height = height, .format = drm_format_argb8888, .pixels = pixels };
    image.base.init(&impl, width, height);
    return image;
}

/// Bilinear-resized copy of a premultiplied ARGB8888 raster.
pub fn createScaled(src: []const u32, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) !*ImageBuffer {
    const pixels = try resample(src, src_w, src_h, dst_w, dst_h);
    errdefer gpa.free(pixels);
    const image = try gpa.create(ImageBuffer);
    errdefer gpa.destroy(image);
    image.* = .{ .base = undefined, .width = dst_w, .height = dst_h, .format = drm_format_argb8888, .pixels = pixels };
    image.base.init(&impl, dst_w, dst_h);
    return image;
}

fn clampInt(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

fn unpack(argb: u32) [4]f32 {
    return .{
        @floatFromInt((argb >> 24) & 0xff),
        @floatFromInt((argb >> 16) & 0xff),
        @floatFromInt((argb >> 8) & 0xff),
        @floatFromInt(argb & 0xff),
    };
}

fn lerpArgb(a: u32, b: u32, t: f32) u32 {
    const pa = unpack(a);
    const pb = unpack(b);
    var out: [4]u32 = undefined;
    for (0..4) |i| {
        out[i] = @intFromFloat(@round(pa[i] + (pb[i] - pa[i]) * t));
    }
    return (out[0] << 24) | (out[1] << 16) | (out[2] << 8) | out[3];
}

fn resample(src: []const u32, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) ![]u32 {
    const dst = try gpa.alloc(u32, @intCast(dst_w * dst_h));
    const dw: usize = @intCast(dst_w);
    const dh: usize = @intCast(dst_h);
    const sw: f32 = @floatFromInt(src_w);
    const sh: f32 = @floatFromInt(src_h);
    const dwf: f32 = @floatFromInt(dst_w);
    const dhf: f32 = @floatFromInt(dst_h);

    var dy: usize = 0;
    while (dy < dh) : (dy += 1) {
        const sy = (@as(f32, @floatFromInt(dy)) + 0.5) * sh / dhf - 0.5;
        const y0f = @floor(sy);
        const fy = sy - y0f;
        const y0 = clampInt(@intFromFloat(y0f), 0, src_h - 1);
        const y1 = clampInt(y0 + 1, 0, src_h - 1);

        var dx: usize = 0;
        while (dx < dw) : (dx += 1) {
            const sx = (@as(f32, @floatFromInt(dx)) + 0.5) * sw / dwf - 0.5;
            const x0f = @floor(sx);
            const fx = sx - x0f;
            const x0 = clampInt(@intFromFloat(x0f), 0, src_w - 1);
            const x1 = clampInt(x0 + 1, 0, src_w - 1);

            const p00 = src[@intCast(y0 * src_w + x0)];
            const p10 = src[@intCast(y0 * src_w + x1)];
            const p01 = src[@intCast(y1 * src_w + x0)];
            const p11 = src[@intCast(y1 * src_w + x1)];

            dst[dy * dw + dx] = lerpArgb(lerpArgb(p00, p10, fx), lerpArgb(p01, p11, fx), fy);
        }
    }
    return dst;
}

fn destroy(base: *wlr.Buffer) callconv(.c) void {
    const image: *ImageBuffer = @fieldParentPtr("base", base);
    gpa.free(image.pixels);
    gpa.destroy(image);
}

fn beginDataPtrAccess(
    base: *wlr.Buffer,
    _: u32,
    data: **anyopaque,
    format: *u32,
    stride: *usize,
) callconv(.c) bool {
    const image: *ImageBuffer = @fieldParentPtr("base", base);
    data.* = @ptrCast(image.pixels.ptr);
    format.* = image.format;
    stride.* = @as(usize, @intCast(image.width)) * @sizeOf(u32);
    return true;
}

fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}
