const std = @import("std");

const c = @cImport({
    @cInclude("png.h");
});

const PngWriteCtx = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    failed: bool = false,
};

fn pngWriteCallback(png_ptr: c.png_structp, data: c.png_bytep, length: c.png_size_t) callconv(.c) void {
    const io_ptr = c.png_get_io_ptr(png_ptr) orelse return;
    const ctx: *PngWriteCtx = @ptrCast(@alignCast(io_ptr));
    const slice = data[0..length];
    if (!ctx.failed) ctx.list.appendSlice(ctx.allocator, slice) catch {
        ctx.failed = true;
    };
}

fn pngFlushCallback(png_ptr: c.png_structp) callconv(.c) void {
    _ = png_ptr;
}

pub fn encodePng(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []const u32,
    stride_px: usize,
) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidDimensions;

    const png_ptr = c.png_create_write_struct(c.PNG_LIBPNG_VER_STRING, null, null, null) orelse return error.PngEncodeFailed;
    var info_ptr: c.png_infop = null;
    defer {
        var mutable_png_ptr: c.png_structp = png_ptr;
        c.png_destroy_write_struct(&mutable_png_ptr, &info_ptr);
    }

    info_ptr = c.png_create_info_struct(png_ptr) orelse return error.PngEncodeFailed;

    var out_list = std.ArrayList(u8).empty;
    errdefer out_list.deinit(allocator);

    var ctx = PngWriteCtx{
        .list = &out_list,
        .allocator = allocator,
    };

    c.png_set_write_fn(png_ptr, &ctx, pngWriteCallback, pngFlushCallback);

    c.png_set_IHDR(
        png_ptr,
        info_ptr,
        width,
        height,
        8,
        c.PNG_COLOR_TYPE_RGBA,
        c.PNG_INTERLACE_NONE,
        c.PNG_COMPRESSION_TYPE_DEFAULT,
        c.PNG_FILTER_TYPE_DEFAULT,
    );
    c.png_write_info(png_ptr, info_ptr);

    const row_bytes = width * 4;
    const row_buf = try allocator.alloc(u8, row_bytes);
    defer allocator.free(row_buf);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_pixels = pixels[y * stride_px .. y * stride_px + width];
        for (row_pixels, 0..) |pixel, x| {
            const a: u8 = @intCast((pixel >> 24) & 0xFF);
            const r_pm: u8 = @intCast((pixel >> 16) & 0xFF);
            const g_pm: u8 = @intCast((pixel >> 8) & 0xFF);
            const b_pm: u8 = @intCast(pixel & 0xFF);

            var r: u8 = r_pm;
            var g: u8 = g_pm;
            var b: u8 = b_pm;

            if (a == 0) {
                r = 0;
                g = 0;
                b = 0;
            } else if (a < 255) {
                r = @intCast(@min(255, (@as(u32, r_pm) * 255 + a / 2) / a));
                g = @intCast(@min(255, (@as(u32, g_pm) * 255 + a / 2) / a));
                b = @intCast(@min(255, (@as(u32, b_pm) * 255 + a / 2) / a));
            }

            row_buf[x * 4 + 0] = r;
            row_buf[x * 4 + 1] = g;
            row_buf[x * 4 + 2] = b;
            row_buf[x * 4 + 3] = a;
        }
        c.png_write_row(png_ptr, row_buf.ptr);
    }

    c.png_write_end(png_ptr, null);
    if (ctx.failed) return error.OutOfMemory;
    return out_list.toOwnedSlice(allocator);
}

pub fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buf, bytes);
    return buf;
}
