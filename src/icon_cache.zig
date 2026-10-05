// Rasterizes and memoizes real app icons found via icon_theme.zig, for
// Taskbar.zig to blit in place of its hand-drawn SDF tile. Process-wide
// cache, global state, no `@This()` instance — same shape as text.zig's
// font slots.
//
// SVG goes through librsvg straight into a cairo ARGB32 surface, which is
// premultiplied, native-endian 0xAARRGGBB — byte-identical to this
// codebase's own buffer convention (see chrome.zig/Taskbar.BarBuffer), so
// the rasterized pixels are copied out verbatim, no conversion. PNG reuses
// the existing (deliberately minimal) png.zig decoder, then gets
// bilinearly resampled to the requested size, since hicolor's fixed sizes
// essentially never match our device-pixel target exactly.
const std = @import("std");
const Io = std.Io;

// cairo.h has no glib dependency and translates cleanly. librsvg/rsvg.h
// (and everything it pulls in transitively — glib, gobject, gio,
// gdk-pixbuf, pango) does not: glib's headers define
// G_GNUC_BEGIN_IGNORE_DEPRECATIONS as back-to-back `_Pragma(...)` tokens at
// file scope, which zig's translate-c cannot parse, and it cascades into
// thousands of unrelated errors. Since only a handful of stable, ABI-frozen
// rsvg/glib/gobject symbols are needed, they're hand-declared below instead
// of pulled in through @cInclude.
const c = @cImport({
    @cInclude("cairo.h");
});

const GError = opaque {};
const RsvgHandle = opaque {};

const RsvgRectangle = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

extern fn rsvg_handle_new_from_data(data: [*]const u8, len: usize, err: ?*?*GError) ?*RsvgHandle;
extern fn rsvg_handle_new_from_file(filename: [*:0]const u8, err: ?*?*GError) ?*RsvgHandle;
extern fn rsvg_handle_render_document(handle: *RsvgHandle, cr: *c.cairo_t, viewport: *const RsvgRectangle, err: ?*?*GError) c_int;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_error_free(err: *GError) void;

// `pub`: icon_service.zig frees rasters it evicts with this same allocator,
// since that's what actually produced the pixel buffers below.
pub const gpa = std.heap.c_allocator;
const png = @import("png.zig");
const icon_theme = @import("icon_theme.zig");

const log = std.log.scoped(.icon);

pub const Entry = struct {
    pixels: []const u32, // premultiplied ARGB8888, size*size, row-major
    size: i32,
};

var cache: std.StringHashMapUnmanaged(?Entry) = .empty;

// Keyed by "<size_px>:<icon_name>", not name alone: the taskbar and the
// window titlebar each ask for their own fixed size for the life of the
// process (Server.scale never changes after startup), but they're different
// sizes from each other, and a name-only key would let whichever asked first
// silently hand its wrong-size raster to the other. A cached `null` records
// "looked up, not found" so a repeatedly-unmatched app_id doesn't re-walk
// the filesystem on every caller.
pub fn get(cfg: icon_theme.Config, io: Io, icon_name: []const u8, size_px: i32) ?Entry {
    if (icon_name.len == 0) return null;

    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ size_px, icon_name }) catch
        return lookup(cfg, io, icon_name, size_px) catch null;
    if (cache.get(key)) |entry| return entry;

    const entry = lookup(cfg, io, icon_name, size_px) catch |err| blk: {
        log.warn("get: icon lookup failed for '{s}': {}", .{ icon_name, err });
        break :blk null;
    };

    const owned_key = gpa.dupe(u8, key) catch return entry;
    cache.put(gpa, owned_key, entry) catch gpa.free(owned_key);
    return entry;
}

// `pub`: icon_service.zig's worker thread calls this directly instead of
// `get()`, bypassing this module's own memoizing `cache` below. Once
// icon_service owns publishing/eviction (see its module comment), letting
// `cache` also hold the same pixel buffers would leave it handing out a
// dangling pointer the moment icon_service frees an evicted raster.
pub fn lookup(cfg: icon_theme.Config, io: Io, icon_name: []const u8, size_px: i32) !?Entry {
    if (std.mem.eql(u8, icon_name, "builtin:redi-logo")) {
        const bytes = @embedFile("assets/redi-logo.svg");
        var err: ?*GError = null;
        const handle = rsvg_handle_new_from_data(bytes.ptr, bytes.len, &err) orelse {
            if (err) |e| g_error_free(e);
            return null;
        };
        defer g_object_unref(handle);
        return Entry{ .pixels = renderSvg(handle, size_px) orelse return null, .size = size_px };
    }
    if (std.mem.startsWith(u8, icon_name, "/")) {
        const is_svg = std.mem.endsWith(u8, icon_name, ".svg");
        const is_png = std.mem.endsWith(u8, icon_name, ".png");
        if (is_svg) {
            const zpath = gpa.dupeZ(u8, icon_name) catch return null;
            defer gpa.free(zpath);
            const pixels = rasterizeSvg(zpath, size_px) orelse return null;
            return Entry{ .pixels = pixels, .size = size_px };
        } else if (is_png) {
            const zpath = gpa.dupeZ(u8, icon_name) catch return null;
            defer gpa.free(zpath);
            if (try loadPng(zpath, io, size_px)) |pixels| {
                return Entry{ .pixels = pixels, .size = size_px };
            }
            return null;
        } else {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}.svg", .{icon_name})) |svg_path| {
                const zpath = gpa.dupeZ(u8, svg_path) catch return null;
                defer gpa.free(zpath);
                if (rasterizeSvg(zpath, size_px)) |pixels| {
                    return Entry{ .pixels = pixels, .size = size_px };
                }
            } else |_| {}
            if (std.fmt.bufPrintZ(&buf, "{s}.png", .{icon_name})) |png_path| {
                if (try loadPng(png_path, io, size_px)) |pixels| {
                    return Entry{ .pixels = pixels, .size = size_px };
                }
            } else |_| {}
            return null;
        }
    }

    const found = (try icon_theme.find(gpa, io, cfg, icon_name, size_px)) orelse return null;
    defer gpa.free(found.path);

    if (found.svg) {
        const pixels = rasterizeSvg(found.path, size_px) orelse return null;
        return Entry{ .pixels = pixels, .size = size_px };
    }

    if (try loadPng(found.path, io, size_px)) |pixels| {
        return Entry{ .pixels = pixels, .size = size_px };
    }
    return null;
}

// A missing icon file is a permanent, expected outcome (most app_ids simply
// have no themed icon) so it collapses to `null` same as a decode failure.
// Anything else reading the file failed for (permission, a transient device
// error, an allocator failure downstream) is propagated instead: the caller
// decides whether that's worth caching as a permanent miss. See
// icon_service.zig's `resolveOne`, which is the only caller that cares.
fn loadPng(path: [:0]const u8, io: Io, size_px: i32) !?[]u32 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);

    if (png.decode(gpa, bytes)) |decoded| {
        defer decoded.deinit(gpa);
        return resample(decoded.pixels, decoded.width, decoded.height, size_px) catch null;
    } else |err| {
        // Fall back to cairo's libpng loader for formats png.zig doesn't handle (e.g. palette/indexed PNGs)
        if (decodePngViaCairo(path.ptr)) |cairo_img| {
            defer gpa.free(cairo_img.pixels);
            return resample(cairo_img.pixels, cairo_img.width, cairo_img.height, size_px) catch null;
        }
        if (err != error.UnsupportedPng) {
            log.warn("lookup: failed to decode icon PNG {s}: {}", .{ path, err });
        }
        return null;
    }
}

fn decodePngViaCairo(path: [*:0]const u8) ?struct { pixels: []u32, width: i32, height: i32 } {
    const surface = c.cairo_image_surface_create_from_png(path);
    if (surface == null) return null;
    defer c.cairo_surface_destroy(surface);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return null;

    c.cairo_surface_flush(surface);
    const data = c.cairo_image_surface_get_data(surface) orelse return null;
    const width = c.cairo_image_surface_get_width(surface);
    const height = c.cairo_image_surface_get_height(surface);
    if (width <= 0 or height <= 0) return null;

    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const format = c.cairo_image_surface_get_format(surface);

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels = gpa.alloc(u32, w * h) catch return null;
    errdefer gpa.free(pixels);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row_ptr = data + y * stride;
        if (format == c.CAIRO_FORMAT_ARGB32) {
            const row: [*]align(4) const u32 = @ptrCast(@alignCast(row_ptr));
            @memcpy(pixels[y * w ..][0..w], row[0..w]);
        } else if (format == c.CAIRO_FORMAT_RGB24) {
            const row: [*]align(4) const u32 = @ptrCast(@alignCast(row_ptr));
            for (0..w) |x| {
                pixels[y * w + x] = 0xff000000 | (row[x] & 0x00ffffff);
            }
        } else {
            gpa.free(pixels);
            return null;
        }
    }
    return .{ .pixels = pixels, .width = width, .height = height };
}

fn rasterizeSvg(path: [:0]const u8, size_px: i32) ?[]u32 {
    var err: ?*GError = null;

    const handle = rsvg_handle_new_from_file(path.ptr, &err) orelse {
        if (err) |e| g_error_free(e);
        return null;
    };
    defer g_object_unref(handle);
    return renderSvg(handle, size_px);
}

fn renderSvg(handle: *RsvgHandle, size_px: i32) ?[]u32 {
    var err: ?*GError = null;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, size_px, size_px);
    defer c.cairo_surface_destroy(surface);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return null;

    const cr = c.cairo_create(surface) orelse return null; // safer than `.?` later: a failed cairo_create must not crash icon lookup
    defer c.cairo_destroy(cr);
    if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return null;

    const viewport = RsvgRectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(size_px),
        .height = @floatFromInt(size_px),
    };
    if (rsvg_handle_render_document(handle, cr, &viewport, &err) == 0) {
        if (err) |e| g_error_free(e);
        return null;
    }
    c.cairo_surface_flush(surface);

    const data = c.cairo_image_surface_get_data(surface);
    if (data == null) return null;
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const w: usize = @intCast(size_px);

    const pixels = gpa.alloc(u32, w * w) catch return null;
    var y: usize = 0;
    while (y < w) : (y += 1) {
        const row: [*]align(4) const u32 = @ptrCast(@alignCast(data + y * stride));
        @memcpy(pixels[y * w ..][0..w], row[0..w]);
    }
    return pixels;
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

// Bilinear resample of a premultiplied-ARGB buffer into a square icon slot,
// centering rectangular artwork without stretching it. Valid on premultiplied
// data (unlike some other filters) since resize is a linear operation.
fn resample(src: []const u32, src_w: i32, src_h: i32, dst_size: i32) ![]u32 {
    const dst = try gpa.alloc(u32, @intCast(dst_size * dst_size));
    const dw: usize = @intCast(dst_size);
    const sw: f32 = @floatFromInt(src_w);
    const sh: f32 = @floatFromInt(src_h);
    const dwf: f32 = @floatFromInt(dst_size);
    const longest = @max(sw, sh);
    const image_w = dwf * sw / longest;
    const image_h = dwf * sh / longest;
    const left = (dwf - image_w) / 2;
    const top = (dwf - image_h) / 2;

    var dy: usize = 0;
    while (dy < dw) : (dy += 1) {
        const py = @as(f32, @floatFromInt(dy)) + 0.5;
        if (py < top or py >= top + image_h) {
            @memset(dst[dy * dw ..][0..dw], 0);
            continue;
        }
        const sy = (py - top) * sh / image_h - 0.5;
        const y0f = @floor(sy);
        const fy = sy - y0f;
        const y0 = clampInt(@intFromFloat(y0f), 0, src_h - 1);
        const y1 = clampInt(y0 + 1, 0, src_h - 1);

        var dx: usize = 0;
        while (dx < dw) : (dx += 1) {
            const px = @as(f32, @floatFromInt(dx)) + 0.5;
            if (px < left or px >= left + image_w) {
                dst[dy * dw + dx] = 0;
                continue;
            }
            const sx = (px - left) * sw / image_w - 0.5;
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

test "rectangular PNG icons keep their proportions" {
    const src = [_]u32{ 0xffff0000, 0xff0000ff };
    const pixels = try resample(&src, 2, 1, 4);
    defer gpa.free(pixels);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, pixels[12..16]);
    for (pixels[4..12]) |pixel| try std.testing.expectEqual(@as(u32, 0xff), pixel >> 24);
}

test "decode palette PNG via cairo fallback" {
    const paths = [_][*:0]const u8{
        "/usr/share/icons/hicolor/32x32/apps/cups.png",
        "/usr/share/icons/hicolor/32x32/apps/onlyoffice-desktopeditors.png",
    };
    for (paths) |path| {
        if (std.posix.system.access(path, std.posix.system.R_OK) == 0) {
            const decoded = decodePngViaCairo(path);
            try std.testing.expect(decoded != null);
            if (decoded) |img| {
                defer gpa.free(img.pixels);
                try std.testing.expect(img.width > 0);
                try std.testing.expect(img.height > 0);
                try std.testing.expectEqual(@as(usize, @intCast(img.width * img.height)), img.pixels.len);
            }
        }
    }
}
