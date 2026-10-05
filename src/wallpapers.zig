//! Where wallpaper images come from, and what `[compositor] wallpaper` means.
//!
//! The build installs RediWM's own images into `share/rediwm/wallpapers` next
//! to `bin/` (zig-out/ or /usr/local); the user adds theirs to
//! `$XDG_DATA_HOME/rediwm/wallpapers`. The setting is empty for the bundled
//! default, a bare file name found in either directory (the user's first), or
//! a path (`~/` expands to the home directory).
const std = @import("std");

pub const default_name = "default.png";

/// Decoded by png.zig when it can, otherwise GdkPixbuf (wallpaper_load.zig).
const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp" };

pub const Entry = struct {
    /// The `wallpaper` value that selects it: the file name.
    name: []const u8,
    label: []const u8,
    path: []const u8,
    bundled: bool,
};

pub fn bundledDir(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);
    return std.fs.path.resolve(allocator, &.{ exe_dir, "..", "share", "rediwm", "wallpapers" });
}

pub fn userDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |data| {
        const dir = std.mem.span(data);
        // The spec ignores relative values.
        if (dir.len > 0 and dir[0] == '/') return std.fmt.allocPrint(allocator, "{s}/rediwm/wallpapers", .{dir});
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
    if (home.len == 0) return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/rediwm/wallpapers", .{home});
}

pub fn isImageName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    for (extensions) |ext| {
        if (name.len > ext.len and std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

/// The file to load for a `wallpaper` value. Names missing from the user's
/// directory resolve to the bundled one whether or not it exists; the loader
/// reports what it cannot open.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io, value: []const u8) ![]u8 {
    const name = if (value.len == 0) default_name else value;
    if (std.mem.startsWith(u8, name, "~/")) {
        const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, name[1..] });
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) return allocator.dupe(u8, name);
    if (userDir(allocator)) |dir| {
        defer allocator.free(dir);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| return path else |_| allocator.free(path);
    } else |_| {}
    const dir = try bundledDir(allocator, io);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

/// Images in both directories: bundled first, then the user's, each sorted by
/// label. A user file named like a bundled one replaces it, as `resolve` does.
/// Allocated in `arena`.
pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    const user = userDir(arena) catch null;
    const bundled = bundledDir(arena, io) catch null;
    for ([_]?[]const u8{ user, bundled }, [_]bool{ false, true }) |maybe_dir, is_bundled| {
        const dir_path = maybe_dir orelse continue;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!isImageName(entry.name)) continue;
            // Saved as a plain TOML string (setting_save.zig).
            if (std.mem.indexOfAny(u8, entry.name, "\"\\\n\r") != null) continue;
            if (indexOf(entries.items, entry.name) != null) continue;
            const name = try arena.dupe(u8, entry.name);
            try entries.append(arena, .{
                .name = name,
                .label = try label(arena, name),
                .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, name }),
                .bundled = is_bundled,
            });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.bundled != b.bundled) return a.bundled;
            const a_default = std.mem.eql(u8, a.name, default_name);
            const b_default = std.mem.eql(u8, b.name, default_name);
            if (a_default != b_default) return a_default;
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.lessThan);
    return entries.items;
}

/// More than a strip can usefully show, and a bound on the worker's decoding.
pub const max_folder_images = 200;

/// Images directly inside `dir_path`, sorted by label. Each entry is named by
/// its full path, which is what `wallpaper` holds for a file outside the
/// wallpaper directories. Allocated in `arena`; unreadable folders are empty.
pub fn listDir(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    if (std.mem.indexOfAny(u8, dir_path, "\"\\\n\r") != null) return entries.items;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return entries.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isImageName(entry.name)) continue;
        // Saved as a plain TOML string (setting_save.zig).
        if (std.mem.indexOfAny(u8, entry.name, "\"\\\n\r") != null) continue;
        const name = try arena.dupe(u8, entry.name);
        try entries.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, dir_path, "/"), name }),
            .label = try label(arena, name),
            .path = "",
            .bundled = false,
        });
    }
    for (entries.items) |*entry| entry.path = entry.name;
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.lessThan);
    return entries.items[0..@min(entries.items.len, max_folder_images)];
}

/// Whether `value` (a `wallpaper` setting) holds a path rather than a name.
pub fn isPath(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "~/") or std.mem.indexOfScalar(u8, value, '/') != null;
}

/// The entry a `wallpaper` value selects, if it names one by file name or by
/// the same path.
pub fn indexOf(entries: []const Entry, value: []const u8) ?usize {
    const name = if (value.len == 0) default_name else value;
    for (entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name) or std.mem.eql(u8, entry.path, name)) return i;
    }
    return null;
}

/// "sunset_over-hills.jpg" -> "Sunset over hills"; the default is "RediWM".
pub fn label(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, default_name)) return allocator.dupe(u8, "RediWM");
    const stem = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
    const out = try allocator.dupe(u8, if (stem.len > 0) stem else name);
    for (out) |*ch| {
        if (ch.* == '_' or ch.* == '-') ch.* = ' ';
    }
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// Box-filtered `dst_w`x`dst_h` copy of a premultiplied ARGB raster, cropped
/// to cover like the output's wallpaper node (Output.syncWallpaper).
pub fn thumbnail(allocator: std.mem.Allocator, src: []const u32, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) ![]u32 {
    const dst = try allocator.alloc(u32, @intCast(dst_w * dst_h));
    const sw: f64 = @floatFromInt(src_w);
    const sh: f64 = @floatFromInt(src_h);
    const dw: f64 = @floatFromInt(dst_w);
    const dh: f64 = @floatFromInt(dst_h);
    const scale = @max(dw / sw, dh / sh);
    const crop_x = (sw - dw / scale) / 2;
    const crop_y = (sh - dh / scale) / 2;
    const width: usize = @intCast(src_w);
    for (0..@intCast(dst_h)) |dy| {
        const y0 = boxStart(crop_y + @as(f64, @floatFromInt(dy)) / scale, src_h);
        const y1 = boxEnd(crop_y + @as(f64, @floatFromInt(dy + 1)) / scale, y0, src_h);
        for (0..@intCast(dst_w)) |dx| {
            const x0 = boxStart(crop_x + @as(f64, @floatFromInt(dx)) / scale, src_w);
            const x1 = boxEnd(crop_x + @as(f64, @floatFromInt(dx + 1)) / scale, x0, src_w);
            var sum: [4]u64 = .{ 0, 0, 0, 0 };
            for (y0..y1) |y| {
                for (src[y * width + x0 .. y * width + x1]) |p| {
                    inline for (0..4) |ch| sum[ch] += (p >> (24 - 8 * ch)) & 0xff;
                }
            }
            const n: u64 = (y1 - y0) * (x1 - x0);
            var out: u32 = 0;
            inline for (0..4) |ch| out |= @as(u32, @intCast((sum[ch] + n / 2) / n)) << (24 - 8 * ch);
            dst[dy * @as(usize, @intCast(dst_w)) + dx] = out;
        }
    }
    return dst;
}

/// First source pixel of a box starting at crop coordinate `v`.
fn boxStart(v: f64, len: i32) usize {
    return @intCast(std.math.clamp(@as(i64, @intFromFloat(@floor(v))), 0, len - 1));
}

/// Exclusive end of a box ending at `v`; every box keeps at least one pixel.
fn boxEnd(v: f64, start: usize, len: i32) usize {
    return @intCast(std.math.clamp(@as(i64, @intFromFloat(@floor(v))), @as(i64, @intCast(start)) + 1, len));
}

test "wallpaper names" {
    try std.testing.expect(isImageName("beach.JPG"));
    try std.testing.expect(isImageName("default.png"));
    try std.testing.expect(!isImageName(".png"));
    try std.testing.expect(!isImageName(".hidden.png"));
    try std.testing.expect(!isImageName("notes.txt"));
    const a = std.testing.allocator;
    const pretty = try label(a, "sunset_over-hills.jpg");
    defer a.free(pretty);
    try std.testing.expectEqualStrings("Sunset over hills", pretty);
    const default = try label(a, default_name);
    defer a.free(default);
    try std.testing.expectEqualStrings("RediWM", default);
}

test "values select entries by name or path, empty selects the default" {
    const entries = [_]Entry{
        .{ .name = "default.png", .label = "RediWM", .path = "/b/default.png", .bundled = true },
        .{ .name = "mine.jpg", .label = "Mine", .path = "/u/mine.jpg", .bundled = false },
    };
    try std.testing.expectEqual(@as(?usize, 0), indexOf(&entries, ""));
    try std.testing.expectEqual(@as(?usize, 1), indexOf(&entries, "mine.jpg"));
    try std.testing.expectEqual(@as(?usize, 1), indexOf(&entries, "/u/mine.jpg"));
    try std.testing.expectEqual(@as(?usize, null), indexOf(&entries, "/elsewhere/mine.jpg"));
}

test "folder listings name entries by path, sorted, images only" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "b_two.png", "a-one.JPG", ".hidden.png", "notes.txt" }) |name| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "x" });
    }
    const dir_path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    const entries = try listDir(arena.allocator(), std.testing.io, dir_path);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("A one", entries[0].label);
    try std.testing.expect(std.mem.endsWith(u8, entries[0].name, "/a-one.JPG"));
    try std.testing.expect(!std.mem.endsWith(u8, entries[0].name, "//a-one.JPG"));
    try std.testing.expectEqualStrings(entries[1].name, entries[1].path);
    try std.testing.expectEqual(@as(usize, 0), (try listDir(arena.allocator(), std.testing.io, "/nonexistent-rediwm-dir")).len);
    try std.testing.expect(isPath("~/x.png") and isPath("/a/b.png") and !isPath("x.png"));
}

test "paths resolve as given" {
    const a = std.testing.allocator;
    const path = try resolve(a, std.testing.io, "/srv/art/wall.png");
    defer a.free(path);
    try std.testing.expectEqualStrings("/srv/art/wall.png", path);
}

test "thumbnails average and crop to cover" {
    const a = std.testing.allocator;
    // 4x2 source: left half black, right half white, with a red column
    // cropped away on each side when fitting a square.
    const k: u32 = 0xff000000;
    const w: u32 = 0xffffffff;
    const r: u32 = 0xffff0000;
    const src = [_]u32{ r, k, w, r, r, k, w, r };
    const thumb = try thumbnail(a, &src, 4, 2, 2, 2);
    defer a.free(thumb);
    try std.testing.expectEqualSlices(u32, &.{ k, w, k, w }, thumb);

    const one = try thumbnail(a, &src, 4, 2, 1, 1);
    defer a.free(one);
    // A 1x1 cover crop averages the centre 2x2 box.
    try std.testing.expectEqual(@as(u32, 0xff808080), one[0]);
}
