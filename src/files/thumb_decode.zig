//! Makes one thumbnail: reads the shared freedesktop cache, otherwise decodes
//! the original and writes the result back. Pure functions over a path and a
//! context, so the worker threads in `thumbs.zig` and the tests share them;
//! nothing here touches Cairo or Wayland.
const std = @import("std");
const c = @import("c.zig").api;
const decode = @import("../images/decode.zig");
const tc = @cImport({
    @cInclude("thumb_codec.h");
});

const a = std.heap.c_allocator;

/// Longest edge of a thumbnail: the freedesktop "normal" size.
pub const box: i32 = 128;
/// Formats that cannot scale while decoding hold the whole raster briefly.
const max_pixels: i64 = 16 << 20;
/// JPEG decodes at a fraction of its size, so a large photo costs little.
const max_pixels_jpeg: i64 = 128 << 20;
const max_file_bytes: i64 = 1 << 30;
/// Thumbnails from other applications are at most 256 px, a few KiB.
const max_cache_file_bytes: i64 = 4 << 20;
const max_cache_pixels: i64 = 1 << 20;

pub const Decoded = struct {
    /// Premultiplied ARGB32, allocated by `std.heap.c_allocator`.
    pixels: []u32,
    w: i32,
    h: i32,
    /// The original is larger than a thumbnail, so the shared cache wants one.
    cacheable: bool = false,
    /// What the original looked like (symlinks resolved), for the cache entry.
    file_mtime: i64 = 0,
    file_size: i64 = 0,
    /// Read from the shared cache rather than decoded from the original.
    from_shared: bool = false,

    pub fn deinit(self: Decoded) void {
        a.free(self.pixels);
    }
};

pub const Outcome = union(enum) {
    ok: Decoded,
    /// Unreadable, unsupported or too large.
    failed,
    /// The file no longer matches what the caller listed; a rescan follows.
    stale,
};

pub const Context = struct {
    /// `$XDG_CACHE_HOME` or `~/.cache`; null disables the shared cache.
    cache_dir: ?[]const u8 = null,
};

/// The shared cache's root for this environment.
pub fn cacheDir(allocator: std.mem.Allocator, environ: std.process.Environ) ?[]u8 {
    if (environ.getPosix("XDG_CACHE_HOME")) |base| {
        if (std.fs.path.isAbsolute(base)) return allocator.dupe(u8, base) catch null;
    }
    const home = environ.getPosix("HOME") orelse return null;
    if (!std.fs.path.isAbsolute(home)) return null;
    return std.fs.path.join(allocator, &.{ home, ".cache" }) catch null;
}

/// Whether the environment turns thumbnails off.
pub fn disabled(environ: std.process.Environ) bool {
    const value = environ.getPosix("REDIWM_FILES_THUMBNAILS") orelse return false;
    return std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "false");
}

/// Makes the thumbnail for `path`, which the caller saw with `mtime` and
/// `bytes` (a symlink's own, so only regular files are compared).
pub fn generate(ctx: Context, path: [:0]const u8, mtime: i64, bytes: i64, is_symlink: bool) Outcome {
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return .failed;
    if ((st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_size <= 0 or st.st_size > max_file_bytes) return .failed;
    if (!is_symlink and (@as(i64, st.st_mtim.tv_sec) != mtime or @as(i64, st.st_size) != bytes)) return .stale;
    const file_mtime: i64 = st.st_mtim.tv_sec;
    const file_size: i64 = st.st_size;

    if (readShared(ctx, path, file_mtime, file_size)) |hit| return .{ .ok = hit };
    var outcome = fromOriginal(path) orelse return .failed;
    switch (outcome) {
        .ok => |*decoded| {
            decoded.file_mtime = file_mtime;
            decoded.file_size = file_size;
        },
        else => {},
    }
    return outcome;
}

fn fromOriginal(path: [:0]const u8) ?Outcome {
    if (decodeNative(path)) |result| return result;
    var meta: decode.Meta = .{};
    const image = decode.loadWith(path, .{
        .box = .{ .w = box, .h = box },
        .max_pixels = max_pixels,
        .max_pixels_jpeg = max_pixels_jpeg,
        .meta = &meta,
    }) catch return null;
    return .{ .ok = .{
        .pixels = image.pixels,
        .w = image.w,
        .h = image.h,
        .cacheable = meta.src_w > box or meta.src_h > box,
    } };
}

const Mapped = struct {
    data: []const u8,

    fn open(path: [:0]const u8, max_bytes: i64) ?Mapped {
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return null;
        defer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return null;
        if (st.st_size <= 0 or st.st_size > max_bytes) return null;
        const len: usize = @intCast(st.st_size);
        const map = c.mmap(null, len, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (map == c.MAP_FAILED) return null;
        const data: [*]const u8 = @ptrCast(map);
        return .{ .data = data[0..len] };
    }

    fn close(self: Mapped) void {
        _ = c.munmap(@ptrCast(@constCast(self.data.ptr)), self.data.len);
    }
};

/// JPEG and PNG through libjpeg/libpng; null when another decoder should try.
fn decodeNative(path: [:0]const u8) ?Outcome {
    const file = Mapped.open(path, max_file_bytes) orelse return null;
    defer file.close();
    var image: tc.tc_image = undefined;
    const jpeg = file.data.len > 2 and file.data[0] == 0xff and file.data[1] == 0xd8;
    const status = if (jpeg)
        tc.tc_jpeg(file.data.ptr, file.data.len, box, max_pixels_jpeg, &image)
    else
        tc.tc_png(file.data.ptr, file.data.len, box, max_pixels, &image);
    switch (status) {
        tc.TC_OK => {},
        tc.TC_TOO_LARGE, tc.TC_NOMEM => return .failed,
        else => return null,
    }
    defer tc.tc_free(&image);
    const count: usize = @intCast(@as(i64, image.w) * image.h);
    const copy = a.alloc(u32, count) catch return .failed;
    @memcpy(copy, image.pixels[0..count]);
    var decoded: Decoded = .{
        .pixels = copy,
        .w = image.w,
        .h = image.h,
        .cacheable = image.src_w > box or image.src_h > box,
    };
    if (image.orientation != 1) {
        if (orient(copy, decoded.w, decoded.h, @intCast(image.orientation))) |rotated| {
            a.free(copy);
            decoded.pixels = rotated.pixels;
            decoded.w = rotated.w;
            decoded.h = rotated.h;
        } else |_| {
            a.free(copy);
            return .failed;
        }
    }
    return .{ .ok = decoded };
}

pub const Oriented = struct { pixels: []u32, w: i32, h: i32 };

/// Applies an EXIF orientation (1..8) to a small raster, into a new buffer.
pub fn orient(pixels: []const u32, w: i32, h: i32, orientation: u8) !Oriented {
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const swap = orientation >= 5;
    const dw = if (swap) sh else sw;
    const dh = if (swap) sw else sh;
    const out = try a.alloc(u32, sw * sh);
    for (0..dh) |dy| {
        for (0..dw) |dx| {
            const sx: usize, const sy: usize = switch (orientation) {
                2 => .{ sw - 1 - dx, dy },
                3 => .{ sw - 1 - dx, sh - 1 - dy },
                4 => .{ dx, sh - 1 - dy },
                5 => .{ dy, dx },
                6 => .{ dy, sh - 1 - dx },
                7 => .{ sw - 1 - dy, sh - 1 - dx },
                8 => .{ sw - 1 - dy, dx },
                else => .{ dx, dy },
            };
            out[dy * dw + dx] = pixels[sy * sw + sx];
        }
    }
    return .{ .pixels = out, .w = @intCast(dw), .h = @intCast(dh) };
}

// ---- freedesktop shared cache -------------------------------------------

/// `file://` plus the path, escaped like GLib's `g_filename_to_uri`, so the
/// MD5 of it names the same file other applications wrote.
pub fn fileUri(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    try out.appendSlice(allocator, "file://");
    for (path) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/", ch) != null;
        if (plain) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, std.fmt.digitToChar(ch >> 4, .upper));
            try out.append(allocator, std.fmt.digitToChar(ch & 15, .upper));
        }
    }
}

pub fn uriHash(uri: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(uri, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// A cached thumbnail's path: `<cache>/thumbnails/<size>/<md5>.png`.
fn sharedPath(buf: []u8, ctx: Context, size_dir: []const u8, hash: *const [32]u8) ?[:0]u8 {
    const root = ctx.cache_dir orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/thumbnails/{s}/{s}.png", .{ root, size_dir, hash }) catch null;
}

fn readShared(ctx: Context, path: []const u8, mtime: i64, size: i64) ?Decoded {
    if (ctx.cache_dir == null or !std.fs.path.isAbsolute(path)) return null;
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(a);
    fileUri(&uri, a, path) catch return null;
    const hash = uriHash(uri.items);
    for ([_][]const u8{ "normal", "large" }) |size_dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache_path = sharedPath(&buf, ctx, size_dir, &hash) orelse return null;
        const file = Mapped.open(cache_path, max_cache_file_bytes) orelse continue;
        defer file.close();
        var image: tc.tc_image = undefined;
        if (tc.tc_png(file.data.ptr, file.data.len, box, max_cache_pixels, &image) != tc.TC_OK) continue;
        defer tc.tc_free(&image);
        // A changed original makes the entry stale; the spec makes MTime
        // mandatory and Size optional.
        if (image.thumb_mtime != mtime or (image.thumb_size >= 0 and image.thumb_size != size)) continue;
        const count: usize = @intCast(@as(i64, image.w) * image.h);
        const copy = a.alloc(u32, count) catch return null;
        @memcpy(copy, image.pixels[0..count]);
        return .{ .pixels = copy, .w = image.w, .h = image.h, .from_shared = true };
    }
    return null;
}

/// Saves `decoded` where other applications will find it. Failure only means
/// the next visit decodes again.
pub fn writeShared(ctx: Context, path: []const u8, decoded: Decoded) void {
    const root = ctx.cache_dir orelse return;
    if (!decoded.cacheable or !std.fs.path.isAbsolute(path)) return;
    // Thumbnails of thumbnails are pointless.
    if (std.mem.startsWith(u8, path, root) and std.mem.startsWith(u8, path[root.len..], "/thumbnails/")) return;
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(a);
    fileUri(&uri, a, path) catch return;
    const uri_z = a.dupeZ(u8, uri.items) catch return;
    defer a.free(uri_z);
    const hash = uriHash(uri.items);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/thumbnails/normal", .{root}) catch return;
    makeDirs(dir);
    var final_buf: [std.fs.max_path_bytes]u8 = undefined;
    const final = sharedPath(&final_buf, ctx, "normal", &hash) orelse return;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/thumbnails/normal/{s}.{d}.tmp", .{ root, &hash, c.getpid() }) catch return;
    _ = c.unlink(tmp.ptr);
    if (tc.tc_png_write(tmp.ptr, decoded.pixels.ptr, decoded.w, decoded.h, uri_z.ptr, decoded.file_mtime, decoded.file_size) != 0) return;
    if (c.rename(tmp.ptr, final.ptr) != 0) _ = c.unlink(tmp.ptr);
}

/// `mkdir -p` with mode 0700 (the spec's mode for thumbnail directories).
fn makeDirs(dir: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i != dir.len and buf[i] != '/') continue;
        const saved = buf[i];
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o700);
        buf[i] = saved;
    }
}

// ---- tests --------------------------------------------------------------

test "file URIs hash to the names other applications gave their thumbnails" {
    // Hashes are the MD5 of the escaped URI, as GNOME/KDE name thumbnails.
    const cases = [_]struct { path: []const u8, uri: []const u8, hash: []const u8 }{
        .{
            .path = "/home/user/Pictures/linux_arch-advertising_HD_Wallpapers Wallpaper_1920x1200[10wallpaper.com].jpg",
            .uri = "file:///home/user/Pictures/linux_arch-advertising_HD_Wallpapers%20Wallpaper_1920x1200%5B10wallpaper.com%5D.jpg",
            .hash = "502d9c3a0c3a9274ed6204e578c340b9",
        },
        .{
            .path = "/home/user/Downloads/unnamed (3).webp",
            .uri = "file:///home/user/Downloads/unnamed%20(3).webp",
            .hash = "5bb18d81e07ed6b5d82f69768e70e6c8",
        },
    };
    for (cases) |case| {
        var uri: std.ArrayList(u8) = .empty;
        defer uri.deinit(std.testing.allocator);
        try fileUri(&uri, std.testing.allocator, case.path);
        try std.testing.expectEqualStrings(case.uri, uri.items);
        try std.testing.expectEqualStrings(case.hash, &uriHash(uri.items));
    }
}

test "file URIs escape non-ASCII bytes and keep GLib's path characters" {
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(std.testing.allocator);
    try fileUri(&uri, std.testing.allocator, "/a/é #1+(x)@y,z.png");
    try std.testing.expectEqualStrings("file:///a/%C3%A9%20%231+(x)@y,z.png", uri.items);
}

test "orientation covers all eight EXIF cases" {
    // 2x3 source:   1 2
    //               3 4
    //               5 6
    const src = [_]u32{ 1, 2, 3, 4, 5, 6 };
    const expected = [_]struct { w: i32, h: i32, px: [6]u32 }{
        .{ .w = 2, .h = 3, .px = .{ 1, 2, 3, 4, 5, 6 } },
        .{ .w = 2, .h = 3, .px = .{ 2, 1, 4, 3, 6, 5 } },
        .{ .w = 2, .h = 3, .px = .{ 6, 5, 4, 3, 2, 1 } },
        .{ .w = 2, .h = 3, .px = .{ 5, 6, 3, 4, 1, 2 } },
        .{ .w = 3, .h = 2, .px = .{ 1, 3, 5, 2, 4, 6 } },
        .{ .w = 3, .h = 2, .px = .{ 5, 3, 1, 6, 4, 2 } },
        .{ .w = 3, .h = 2, .px = .{ 6, 4, 2, 5, 3, 1 } },
        .{ .w = 3, .h = 2, .px = .{ 2, 4, 6, 1, 3, 5 } },
    };
    for (expected, 1..) |want, orientation| {
        const got = try orient(&src, 2, 3, @intCast(orientation));
        defer a.free(got.pixels);
        try std.testing.expectEqual(want.w, got.w);
        try std.testing.expectEqual(want.h, got.h);
        try std.testing.expectEqualSlices(u32, &want.px, got.pixels);
    }
}
