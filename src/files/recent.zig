//! The shared freedesktop recent-file history. All disk work runs on Files' worker.
const std = @import("std");
const clipboard = @import("clipboard.zig");
const mime_db = @import("../mime_db.zig");
const Allocator = std.mem.Allocator;

pub const location = "recent:///";
pub fn isLocation(value: []const u8) bool {
    return std.mem.eql(u8, value, location);
}

// Keep GLib's headers out of translate-c, like associations.zig.
extern fn g_bookmark_file_new() *anyopaque;
extern fn g_bookmark_file_free(bookmark: *anyopaque) void;
extern fn g_bookmark_file_load_from_data(bookmark: *anyopaque, data: [*]const u8, length: usize, err: ?*?*anyopaque) c_int;
extern fn g_bookmark_file_get_uris(bookmark: *anyopaque, length: *usize) [*:null]?[*:0]u8;
extern fn g_bookmark_file_get_visited_date_time(bookmark: *anyopaque, uri: [*:0]const u8, err: ?*?*anyopaque) ?*anyopaque;
extern fn g_bookmark_file_get_modified_date_time(bookmark: *anyopaque, uri: [*:0]const u8, err: ?*?*anyopaque) ?*anyopaque;
extern fn g_date_time_to_unix(date: *anyopaque) i64;
extern fn g_bookmark_file_set_visited_date_time(bookmark: *anyopaque, uri: [*:0]const u8, date: *anyopaque) void;
extern fn g_bookmark_file_set_modified_date_time(bookmark: *anyopaque, uri: [*:0]const u8, date: *anyopaque) void;
extern fn g_date_time_new_now_utc() *anyopaque;
extern fn g_date_time_unref(date: *anyopaque) void;
extern fn g_bookmark_file_set_mime_type(bookmark: *anyopaque, uri: [*:0]const u8, mime: [*:0]const u8) void;
extern fn g_bookmark_file_add_application(bookmark: *anyopaque, uri: [*:0]const u8, name: [*:0]const u8, exec: [*:0]const u8) void;
extern fn g_bookmark_file_to_data(bookmark: *anyopaque, length: *usize, err: ?*?*anyopaque) ?[*:0]u8;
extern fn g_file_set_contents_full(filename: [*:0]const u8, data: [*]const u8, length: isize, flags: c_int, mode: c_int, err: ?*?*anyopaque) c_int;
extern fn g_bookmark_file_remove_item(bookmark: *anyopaque, uri: [*:0]const u8, err: ?*?*anyopaque) c_int;
extern fn g_strfreev(strings: [*:null]?[*:0]u8) void;
extern fn g_free(memory: ?*anyopaque) void;

pub const Entry = struct { path: [:0]const u8, opened: i64 };

pub fn path(a: Allocator, env: std.process.Environ) ![:0]u8 {
    const base = env.getPosix("XDG_DATA_HOME");
    if (base) |dir| {
        if (std.fs.path.isAbsolute(dir)) return std.fmt.allocPrintSentinel(a, "{s}/recently-used.xbel", .{dir}, 0);
    }
    const home = env.getPosix("HOME") orelse return error.NoHome;
    return std.fmt.allocPrintSentinel(a, "{s}/.local/share/recently-used.xbel", .{home}, 0);
}

fn load(a: Allocator, io: std.Io, filename: []const u8) !*anyopaque {
    const bookmark = g_bookmark_file_new();
    errdefer g_bookmark_file_free(bookmark);
    const data = std.Io.Dir.cwd().readFileAlloc(io, filename, a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return bookmark,
        else => return err,
    };
    defer a.free(data);
    if (g_bookmark_file_load_from_data(bookmark, data.ptr, data.len, null) == 0) return error.InvalidHistory;
    return bookmark;
}

/// Local files only; URI decoding rejects remote hosts, malformed escapes and NULs.
pub fn read(a: Allocator, io: std.Io, env: std.process.Environ) ![]Entry {
    const filename = try path(a, env);
    defer a.free(filename);
    const bookmark = try load(a, io, filename);
    defer g_bookmark_file_free(bookmark);
    var count: usize = 0;
    const uris = g_bookmark_file_get_uris(bookmark, &count);
    defer g_strfreev(uris);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| a.free(entry.path);
        entries.deinit(a);
    }
    for (uris[0..count]) |maybe_uri| {
        const uri = maybe_uri orelse continue;
        const decoded = clipboard.decodeLocalPath(a, std.mem.span(uri)) catch continue;
        defer a.free(decoded);
        const date = g_bookmark_file_get_visited_date_time(bookmark, uri, null) orelse
            g_bookmark_file_get_modified_date_time(bookmark, uri, null);
        const owned = try a.dupeSentinel(u8, decoded, 0);
        errdefer a.free(owned);
        // Bookmark date getters return borrowed values.
        try entries.append(a, .{ .path = owned, .opened = if (date) |d| g_date_time_to_unix(d) else 0 });
    }
    return entries.toOwnedSlice(a);
}

/// Re-read before writing so another window's latest entries are preserved.
pub fn record(a: Allocator, io: std.Io, env: std.process.Environ, opened: []const u8) !void {
    return recordBy(a, io, env, opened, "RediWM Files", "rediwm-files %f");
}

/// `record` on behalf of another application (the name and command GLib stores).
pub fn recordBy(a: Allocator, io: std.Io, env: std.process.Environ, opened: []const u8, app_name: [:0]const u8, exec: [:0]const u8) !void {
    if (!std.fs.path.isAbsolute(opened)) return;
    const filename = try path(a, env);
    defer a.free(filename);
    const bookmark = try load(a, io, filename);
    defer g_bookmark_file_free(bookmark);
    const raw_uri = try clipboard.encodeLocalUri(a, opened);
    defer a.free(raw_uri);
    const uri = try a.dupeSentinel(u8, raw_uri, 0);
    defer a.free(uri);
    const mime = try a.dupeSentinel(u8, mime_db.guess(opened), 0);
    defer a.free(mime);
    g_bookmark_file_set_mime_type(bookmark, uri, mime);
    g_bookmark_file_add_application(bookmark, uri, app_name, exec);
    const now = g_date_time_new_now_utc();
    defer g_date_time_unref(now);
    g_bookmark_file_set_visited_date_time(bookmark, uri, now);
    g_bookmark_file_set_modified_date_time(bookmark, uri, now);
    try write(io, filename, bookmark);
}

fn write(io: std.Io, filename: [:0]const u8, bookmark: *anyopaque) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(filename).?);
    var length: usize = 0;
    const data = g_bookmark_file_to_data(bookmark, &length, null) orelse return error.WriteHistoryFailed;
    defer g_free(data);
    // G_FILE_SET_CONTENTS_CONSISTENT: atomic replacement, private on first creation.
    if (g_file_set_contents_full(filename, data, @intCast(length), 1, 0o600, null) == 0) return error.WriteHistoryFailed;
}

/// Drops every local entry `drop` accepts, re-reading first like `record`.
pub fn forgetWhere(a: Allocator, io: std.Io, env: std.process.Environ, drop: *const fn ([]const u8) bool) !void {
    const filename = try path(a, env);
    defer a.free(filename);
    const bookmark = try load(a, io, filename);
    defer g_bookmark_file_free(bookmark);
    var count: usize = 0;
    const uris = g_bookmark_file_get_uris(bookmark, &count);
    defer g_strfreev(uris);
    var removed = false;
    for (uris[0..count]) |maybe_uri| {
        const uri = maybe_uri orelse continue;
        const decoded = clipboard.decodeLocalPath(a, std.mem.span(uri)) catch continue;
        defer a.free(decoded);
        if (drop(decoded) and g_bookmark_file_remove_item(bookmark, uri, null) != 0) removed = true;
    }
    if (removed) try write(io, filename, bookmark);
}
