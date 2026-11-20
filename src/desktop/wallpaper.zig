//! The desktop's own wallpaper, decoded by the shared native codec (never
//! GdkPixbuf, which starts a sandboxed loader process per image) and drawn
//! with Cairo.
const std = @import("std");
const c = @import("c.zig").api;
const codec = @import("../wallpaper_codec.zig");
pub const Mode = enum { fill, fit, stretch, center, tile };
pub const Image = struct { pixels: []u32, w: i32, h: i32, mode: Mode };
/// Larger files are not wallpapers; this also bounds the read.
const max_file_bytes = 256 << 20;
pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8, mode: Mode) !Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes));
    defer a.free(bytes);
    const image = try codec.decode(a, bytes);
    return .{ .pixels = image.pixels, .w = image.width, .h = image.height, .mode = mode };
}
pub fn render(image: Image, cr: *c.cairo_t, w: i32, h: i32) void {
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(image.pixels.ptr), c.CAIRO_FORMAT_ARGB32, image.w, image.h, image.w * 4);
    defer c.cairo_surface_destroy(surface);
    const sx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(image.w));
    const sy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(image.h));
    const xscale: f64 = switch (image.mode) {
        .fill => @max(sx, sy),
        .fit => @min(sx, sy),
        .stretch => sx,
        else => 1,
    };
    const yscale = if (image.mode == .stretch) sy else xscale;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    if (image.mode != .tile) c.cairo_translate(cr, (@as(f64, @floatFromInt(w)) - @as(f64, @floatFromInt(image.w)) * xscale) / 2, (@as(f64, @floatFromInt(h)) - @as(f64, @floatFromInt(image.h)) * yscale) / 2);
    c.cairo_scale(cr, xscale, yscale);
    c.cairo_set_source_surface(cr, surface, 0, 0);
    // Filtering past an upscaled image's edge would fade it into whatever is
    // underneath; fill and stretch cover the output, so repeat the border.
    // Fit and center keep transparent bars.
    switch (image.mode) {
        .tile => c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_REPEAT),
        .fill, .stretch => c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD),
        .fit, .center => {},
    }
    c.cairo_paint(cr);
}
