//! A torrent's files as folders: what one folder of it holds, and the
//! checkbox each row shows. Pure, so the browse (`app_torrent_browse.zig`)
//! and its tests share it.
//!
//! Paths are the torrent's own, `/`-separated and already checked by the
//! helper (no `..`, no absolute paths). A multi-file torrent keeps its files
//! under one folder named like it; browsing it starts inside that folder,
//! so `base` is that prefix and member paths are relative to it.
const std = @import("std");
const Entry = @import("torrents.zig").Entry;

pub const max_files = 512;
pub const Wanted = std.StaticBitSet(max_files);

/// A checkbox: a folder is `some` while only part of it is ticked.
pub const Check = enum { none, some, all };

pub const Child = struct {
    /// Borrowed from the entry's path.
    name: []const u8,
    is_dir: bool,
    /// The file's index (files only).
    index: usize = 0,
    size: i64 = 0,
    /// Bytes done across the whole row, ticked or not.
    done: i64 = 0,
    /// Size and bytes done of what is ticked.
    wanted_size: i64 = 0,
    wanted_done: i64 = 0,
    check: Check = .none,
    /// Every byte is here: a file that exists, a folder of such files.
    finished: bool = false,
};

/// The folder every file sits in, or "" (one file, or several roots).
pub fn base(files: []const Entry) []const u8 {
    if (files.len == 0) return "";
    const first = files[0].path;
    const slash = std.mem.indexOfScalar(u8, first, '/') orelse return "";
    const root = first[0..slash];
    for (files) |f| {
        if (f.path.len <= root.len or f.path[root.len] != '/' or !std.mem.eql(u8, f.path[0..root.len], root)) return "";
    }
    return root;
}

/// `path` relative to `root` (the browse's `base`), or null outside it.
fn relative(root: []const u8, path: []const u8) ?[]const u8 {
    if (root.len == 0) return path;
    if (path.len <= root.len or path[root.len] != '/' or !std.mem.eql(u8, path[0..root.len], root)) return null;
    return path[root.len + 1 ..];
}

/// `rel` inside folder `dir` (relative to the base, "" its top): the rest.
fn inside(dir: []const u8, rel: []const u8) ?[]const u8 {
    if (dir.len == 0) return rel;
    if (rel.len <= dir.len or rel[dir.len] != '/' or !std.mem.eql(u8, rel[0..dir.len], dir)) return null;
    return rel[dir.len + 1 ..];
}

fn complete(f: Entry) bool {
    return f.done >= f.size;
}

/// The rows of folder `dir`, in the order first met. A folder sums what is
/// under it; its check is `all` only when every file under it is ticked.
pub fn children(allocator: std.mem.Allocator, files: []const Entry, root: []const u8, dir: []const u8, wanted: *const Wanted) ![]Child {
    var rows: std.ArrayList(Child) = .empty;
    errdefer rows.deinit(allocator);
    var ticked: std.ArrayList(usize) = .empty;
    defer ticked.deinit(allocator);
    var counts: std.ArrayList(usize) = .empty;
    defer counts.deinit(allocator);
    for (files) |f| {
        const rel = relative(root, f.path) orelse continue;
        const rest = inside(dir, rel) orelse continue;
        if (rest.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const name = rest[0 .. slash orelse rest.len];
        const want = f.index < max_files and wanted.isSet(f.index);
        var at: ?usize = null;
        for (rows.items, 0..) |row, i| if (row.is_dir == (slash != null) and std.mem.eql(u8, row.name, name)) {
            at = i;
            break;
        };
        const i = at orelse blk: {
            try rows.append(allocator, .{ .name = name, .is_dir = slash != null, .index = f.index, .finished = true });
            try ticked.append(allocator, 0);
            try counts.append(allocator, 0);
            break :blk rows.items.len - 1;
        };
        const row = &rows.items[i];
        row.size +|= f.size;
        row.done +|= @min(f.done, f.size);
        row.finished = row.finished and complete(f);
        counts.items[i] += 1;
        if (want) {
            ticked.items[i] += 1;
            row.wanted_size +|= f.size;
            row.wanted_done +|= @min(f.done, f.size);
        }
    }
    for (rows.items, ticked.items, counts.items) |*row, n, total| {
        row.check = if (n == 0) .none else if (n == total) .all else .some;
    }
    return rows.toOwnedSlice(allocator);
}

/// Ticks (or unticks) every file at or under `member` (relative to the
/// base). A folder that was all ticked unticks; anything else ticks.
/// Returns whether any file changed.
pub fn toggle(files: []const Entry, root: []const u8, member: []const u8, wanted: *Wanted) bool {
    return set(files, root, member, check(files, root, member, wanted) != .all, wanted);
}

/// The check of `member` (relative to the base): a file or a folder.
pub fn check(files: []const Entry, root: []const u8, member: []const u8, wanted: *const Wanted) Check {
    var n: usize = 0;
    var ticked: usize = 0;
    for (files) |f| {
        if (!under(root, member, f.path) or f.index >= max_files) continue;
        n += 1;
        if (wanted.isSet(f.index)) ticked += 1;
    }
    return if (ticked == 0) .none else if (ticked == n) .all else .some;
}

/// Ticks or unticks every file at or under `member`. Returns whether any
/// file is there.
pub fn set(files: []const Entry, root: []const u8, member: []const u8, value: bool, wanted: *Wanted) bool {
    var any = false;
    for (files) |f| {
        if (!under(root, member, f.path) or f.index >= max_files) continue;
        any = true;
        wanted.setValue(f.index, value);
    }
    return any;
}

/// Whether `path` is `member` or inside it.
pub fn under(root: []const u8, member: []const u8, path: []const u8) bool {
    const rel = relative(root, path) orelse return false;
    if (member.len == 0) return true;
    if (std.mem.eql(u8, rel, member)) return true;
    return inside(member, rel) != null;
}

/// Whether `dir` (relative to the base) is a folder of the torrent.
pub fn hasFolder(files: []const Entry, root: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    for (files) |f| {
        const rel = relative(root, f.path) orelse continue;
        if (inside(dir, rel)) |rest| if (rest.len > 0) return true;
    }
    return false;
}

pub const Totals = struct {
    files: usize = 0,
    ticked: usize = 0,
    size: i64 = 0,
    wanted_size: i64 = 0,
    wanted_done: i64 = 0,
};

pub fn totals(files: []const Entry, wanted: *const Wanted) Totals {
    var t: Totals = .{};
    for (files) |f| {
        t.files += 1;
        t.size +|= f.size;
        if (f.index < max_files and wanted.isSet(f.index)) {
            t.ticked += 1;
            t.wanted_size +|= f.size;
            t.wanted_done +|= @min(f.done, f.size);
        }
    }
    return t;
}

test {
    _ = @import("torrent_tree_tests.zig");
}
