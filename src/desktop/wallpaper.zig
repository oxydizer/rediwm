//! GdkPixbuf is already in librsvg's link closure. Keep GLib headers out of translate-c.
const std = @import("std");
const c = @import("c.zig").api;
const Pixbuf = opaque {};
const GError = opaque {};
extern fn gdk_pixbuf_new_from_file([*:0]const u8, ?*?*GError) ?*Pixbuf;
extern fn gdk_pixbuf_get_width(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_height(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_rowstride(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_n_channels(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_pixels(*Pixbuf) [*]const u8;
extern fn g_object_unref(*anyopaque) void;
extern fn g_error_free(*GError) void;
pub const Mode = enum { fill, fit, stretch, center, tile };
pub const Image = struct { pixels: []u32, w: i32, h: i32, mode: Mode };
pub fn load(a: std.mem.Allocator, path: []const u8, mode: Mode) !Image {
    const z = try a.dupeZ(u8, path);
    defer a.free(z);
    var err: ?*GError = null;
    const pixbuf = gdk_pixbuf_new_from_file(z, &err) orelse {
        if (err) |e| g_error_free(e);
        return error.DecodeFailed;
    };
    defer g_object_unref(pixbuf);
    const w = gdk_pixbuf_get_width(pixbuf);
    const h = gdk_pixbuf_get_height(pixbuf);
    const stride = gdk_pixbuf_get_rowstride(pixbuf);
    const channels = gdk_pixbuf_get_n_channels(pixbuf);
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384 or (channels != 3 and channels != 4)) return error.InvalidImage;
    const pixels = try a.alloc(u32, @intCast(w * h));
    const data = gdk_pixbuf_get_pixels(pixbuf);
    for (pixels, 0..) |*p, i| {
        const offset = @divTrunc(i, @as(usize, @intCast(w))) * @as(usize, @intCast(stride)) + i % @as(usize, @intCast(w)) * @as(usize, @intCast(channels));
        const alpha: u32 = if (channels == 4) data[offset + 3] else 255;
        p.* = alpha << 24 | (@as(u32, data[offset]) * alpha / 255) << 16 | (@as(u32, data[offset + 1]) * alpha / 255) << 8 | (@as(u32, data[offset + 2]) * alpha / 255);
    }
    return .{ .pixels = pixels, .w = w, .h = h, .mode = mode };
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
