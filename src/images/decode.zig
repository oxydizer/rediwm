//! GdkPixbuf-backed image decoding shared by the viewer and Files' thumbnails.
//! Pure functions over a path: no globals beyond the allocator, so any thread
//! may call them (each call owns its own pixbuf loader).
const std = @import("std");
const c = @import("../files/c.zig").api;
const png = @import("../png.zig");
const a = std.heap.c_allocator;
const Pixbuf = opaque {};
const GError = opaque {};
const PixbufLoader = opaque {};
extern fn gdk_pixbuf_loader_new() *PixbufLoader;
extern fn gdk_pixbuf_loader_write(*PixbufLoader, [*]const u8, usize, ?*?*GError) c_int;
extern fn gdk_pixbuf_loader_close(*PixbufLoader, ?*?*GError) c_int;
extern fn gdk_pixbuf_loader_get_pixbuf(*PixbufLoader) ?*Pixbuf;
extern fn gdk_pixbuf_loader_set_size(*PixbufLoader, c_int, c_int) void;
extern fn g_signal_connect_data(*PixbufLoader, [*:0]const u8, *const fn (*PixbufLoader, c_int, c_int, *SizeState) callconv(.c) void, *SizeState, ?*anyopaque, c_uint) c_ulong;
/// Bounds a decode. `box` makes the loader scale while it decodes (JPEG, WebP
/// and SVG decode straight to a fraction of their size; the rest are scaled
/// once decoded), so a thumbnail never holds the full raster for long.
pub const Options = struct {
    /// Fit inside this many pixels; null decodes at full size.
    box: ?Box = null,
    /// Pixel budget for formats that cannot scale while decoding.
    max_pixels: i64 = 32 * 1024 * 1024,
    /// Budget for JPEG, whose scaled decode needs memory only for the result.
    max_pixels_jpeg: i64 = 32 * 1024 * 1024,
    /// Receives facts about the file; see `Meta`.
    meta: ?*Meta = null,
};
pub const Box = struct { w: i32, h: i32 };
/// What decoding learned besides pixels.
pub const Meta = struct {
    /// Size of the file's own image, before any scaling.
    src_w: i32 = 0,
    src_h: i32 = 0,
    /// The `Thumb::MTime` and `Thumb::Size` text of a freedesktop thumbnail.
    thumb_mtime: ?i64 = null,
    thumb_size: ?i64 = null,
};
const SizeState = struct { box: ?Box, limit: i64, too_large: bool = false, src_w: i32 = 0, src_h: i32 = 0 };
fn sizePrepared(loader: *PixbufLoader, w: c_int, h: c_int, state: *SizeState) callconv(.c) void {
    state.src_w = w;
    state.src_h = h;
    if (w <= 0 or h <= 0 or w > 32768 or h > 32768 or @as(i64, w) * h > state.limit) {
        state.too_large = true;
        // The signal precedes pixel allocation. Limit this chunk's allocation,
        // then stop feeding the decoder immediately after write returns.
        gdk_pixbuf_loader_set_size(loader, 1, 1);
    } else if (state.box) |box| {
        const scale = @min(1, @min(@as(f64, @floatFromInt(box.w)) / @as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(box.h)) / @as(f64, @floatFromInt(h))));
        gdk_pixbuf_loader_set_size(loader, @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale)))), @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale)))));
    }
}
extern fn gdk_pixbuf_get_option(*Pixbuf, [*:0]const u8) ?[*:0]const u8;
extern fn gdk_pixbuf_apply_embedded_orientation(*Pixbuf) ?*Pixbuf;
extern fn gdk_pixbuf_get_width(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_height(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_rowstride(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_n_channels(*Pixbuf) c_int;
extern fn gdk_pixbuf_get_pixels(*Pixbuf) [*]const u8;
extern fn g_object_unref(*anyopaque) void;
extern fn g_error_free(*GError) void;

pub const Image = struct {
    pixels: []u32,
    w: i32,
    h: i32,
    pub fn deinit(self: Image) void {
        a.free(self.pixels);
    }
};
// The native decoder intentionally handles only plain RGB/RGBA PNG pixels.
// Let GdkPixbuf honor colour-key transparency and EXIF orientation as it does
// for the filmstrip, so preview and saved pixels agree.
fn plainPng(bytes: []const u8) bool {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
    var offset: usize = 8;
    while (bytes.len - offset >= 12) {
        const length: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return false;
        const kind = bytes[offset + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "tRNS") or std.mem.eql(u8, kind, "eXIf")) return false;
        if (std.mem.eql(u8, kind, "IEND")) return true;
        offset += length + 12;
    }
    return false;
}
/// The viewer's filmstrip tile fits this box.
pub const tile_box: Box = .{ .w = 240, .h = 160 };

pub fn load(path: [:0]const u8, thumbnail: bool) !Image {
    return loadWith(path, .{ .box = if (thumbnail) tile_box else null });
}

pub fn loadWith(path: [:0]const u8, options: Options) !Image {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.UnsupportedImage;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return error.UnsupportedImage;
    if (st.st_size <= 0) return error.UnsupportedImage;
    const file_size: usize = @intCast(st.st_size);
    const map = c.mmap(null, file_size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (map == c.MAP_FAILED) return error.UnsupportedImage;
    defer _ = c.munmap(map, file_size);
    const data: [*]const u8 = @ptrCast(map);
    const bytes = data[0..file_size];

    // Try fast native Zig decoder for PNG truecolor images
    if (options.box == null and plainPng(bytes)) {
        if (png.decode(a, bytes)) |pimg| {
            return .{
                .pixels = pimg.pixels,
                .w = pimg.width,
                .h = pimg.height,
            };
        } else |err| {
            if (err == error.ImageTooLarge) return error.ImageTooLarge;
            // Fall back to GdkPixbuf for palette or interlaced PNG
        }
    }

    const loader = gdk_pixbuf_loader_new();
    defer g_object_unref(loader);
    var closed = false;
    defer if (!closed) {
        _ = gdk_pixbuf_loader_close(loader, null);
    };
    const jpeg = bytes.len > 2 and bytes[0] == 0xff and bytes[1] == 0xd8;
    var state = SizeState{ .box = options.box, .limit = if (jpeg) options.max_pixels_jpeg else options.max_pixels };
    _ = g_signal_connect_data(loader, "size-prepared", sizePrepared, &state, null, 0);
    var err: ?*GError = null;
    defer if (err) |e| g_error_free(e);

    const head_len = @min(bytes.len, 4096);
    var ok = gdk_pixbuf_loader_write(loader, bytes.ptr, head_len, &err);
    if (state.too_large) return error.ImageTooLarge;
    if (ok == 0) return error.UnsupportedImage;

    if (bytes.len > head_len) {
        ok = gdk_pixbuf_loader_write(loader, bytes.ptr + head_len, bytes.len - head_len, &err);
        if (state.too_large) return error.ImageTooLarge;
        if (ok == 0) return error.UnsupportedImage;
    }

    closed = true;
    const close_ok = gdk_pixbuf_loader_close(loader, &err);
    if (state.too_large) return error.ImageTooLarge;
    if (close_ok == 0) return error.UnsupportedImage;
    const raw = gdk_pixbuf_loader_get_pixbuf(loader) orelse return error.UnsupportedImage;
    if (options.meta) |meta| {
        meta.* = .{ .src_w = state.src_w, .src_h = state.src_h };
        meta.thumb_mtime = textInt(raw, "tEXt::Thumb::MTime");
        meta.thumb_size = textInt(raw, "tEXt::Thumb::Size");
    }
    const pixbuf = gdk_pixbuf_apply_embedded_orientation(raw) orelse return error.DecodeFailed;
    defer g_object_unref(pixbuf);
    const w = gdk_pixbuf_get_width(pixbuf);
    const h = gdk_pixbuf_get_height(pixbuf);
    const stride = gdk_pixbuf_get_rowstride(pixbuf);
    const channels = gdk_pixbuf_get_n_channels(pixbuf);
    if (w <= 0 or h <= 0 or w > 32768 or h > 32768 or @as(i64, w) * h > 32 * 1024 * 1024 or (channels != 3 and channels != 4) or stride < w * channels) return error.InvalidImage;
    const pixels = try a.alloc(u32, @intCast(@as(i64, w) * h));
    const raw_pixels = gdk_pixbuf_get_pixels(pixbuf);
    const w_usize: usize = @intCast(w);
    const h_usize: usize = @intCast(h);
    const stride_usize: usize = @intCast(stride);

    if (channels == 3) {
        for (0..h_usize) |y| {
            const row = raw_pixels + y * stride_usize;
            const dest = pixels[y * w_usize ..][0..w_usize];
            var off: usize = 0;
            for (dest) |*pixel| {
                const r: u32 = row[off];
                const g: u32 = row[off + 1];
                const b: u32 = row[off + 2];
                pixel.* = 0xff00_0000 | (r << 16) | (g << 8) | b;
                off += 3;
            }
        }
    } else {
        for (0..h_usize) |y| {
            const row = raw_pixels + y * stride_usize;
            const dest = pixels[y * w_usize ..][0..w_usize];
            var off: usize = 0;
            for (dest) |*pixel| {
                const alpha: u32 = row[off + 3];
                if (alpha == 255) {
                    const r: u32 = row[off];
                    const g: u32 = row[off + 1];
                    const b: u32 = row[off + 2];
                    pixel.* = 0xff00_0000 | (r << 16) | (g << 8) | b;
                } else if (alpha == 0) {
                    pixel.* = 0;
                } else {
                    const r: u32 = (@as(u32, row[off]) * alpha + 127) / 255;
                    const g: u32 = (@as(u32, row[off + 1]) * alpha + 127) / 255;
                    const b: u32 = (@as(u32, row[off + 2]) * alpha + 127) / 255;
                    pixel.* = (alpha << 24) | (r << 16) | (g << 8) | b;
                }
                off += 4;
            }
        }
    }
    return .{ .pixels = pixels, .w = w, .h = h };
}
fn textInt(pixbuf: *Pixbuf, key: [*:0]const u8) ?i64 {
    const text = gdk_pixbuf_get_option(pixbuf, key) orelse return null;
    return std.fmt.parseInt(i64, std.mem.sliceTo(text, 0), 10) catch null;
}
/// Reuse the main decode for its filmstrip tile; no second file read or decode.
pub fn makeThumbnail(image: Image) !Image {
    const scale = @min(1, @min(240.0 / @as(f64, @floatFromInt(image.w)), 160.0 / @as(f64, @floatFromInt(image.h))));
    const w: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(image.w)) * scale))));
    const h: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(image.h)) * scale))));
    const pixels = try a.alloc(u32, @intCast(w * h));
    errdefer a.free(pixels);
    if (w == image.w and h == image.h) {
        @memcpy(pixels, image.pixels);
        return .{ .pixels = pixels, .w = w, .h = h };
    }
    const src_w: usize = @intCast(image.w);
    const src_h: usize = @intCast(image.h);
    const dst_w: usize = @intCast(w);
    const dst_h: usize = @intCast(h);
    const x_ratio = (@as(u64, @intCast(image.w)) << 16) / @as(u64, dst_w);
    const y_ratio = (@as(u64, @intCast(image.h)) << 16) / @as(u64, dst_h);

    for (0..dst_h) |dy| {
        const sy_fp = @as(u64, @intCast(dy)) * y_ratio;
        const sy0 = @min(src_h - 1, @as(usize, @intCast(sy_fp >> 16)));
        const sy1 = @min(src_h - 1, sy0 + 1);
        const y_weight: u32 = @intCast((sy_fp >> 8) & 0xff);
        const row0 = image.pixels[sy0 * src_w ..][0..src_w];
        const row1 = image.pixels[sy1 * src_w ..][0..src_w];
        const dst_row = pixels[dy * dst_w ..][0..dst_w];

        for (0..dst_w) |dx| {
            const sx_fp = @as(u64, @intCast(dx)) * x_ratio;
            const sx0 = @min(src_w - 1, @as(usize, @intCast(sx_fp >> 16)));
            const sx1 = @min(src_w - 1, sx0 + 1);
            const x_weight: u32 = @intCast((sx_fp >> 8) & 0xff);

            const p00 = row0[sx0];
            const p10 = row0[sx1];
            const p01 = row1[sx0];
            const p11 = row1[sx1];

            const top = lerpPixel(p00, p10, x_weight);
            const bot = lerpPixel(p01, p11, x_weight);
            dst_row[dx] = lerpPixel(top, bot, y_weight);
        }
    }
    return .{ .pixels = pixels, .w = w, .h = h };
}
fn lerpPixel(p0: u32, p1: u32, w: u32) u32 {
    const inv_w = 256 - w;
    const a_val = (((p0 >> 24) & 0xff) * inv_w + ((p1 >> 24) & 0xff) * w + 128) >> 8;
    const r = (((p0 >> 16) & 0xff) * inv_w + ((p1 >> 16) & 0xff) * w + 128) >> 8;
    const g = (((p0 >> 8) & 0xff) * inv_w + ((p1 >> 8) & 0xff) * w + 128) >> 8;
    const b = ((p0 & 0xff) * inv_w + (p1 & 0xff) * w + 128) >> 8;
    return (@as(u32, @intCast(a_val)) << 24) | (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
}

