//! The home trash (Freedesktop Trash specification 1.0): restoring and
//! permanently deleting trashed entries, with their `.trashinfo` metadata.
//!
//! `files_dir` is `$XDG_DATA_HOME/Trash/files`; `info/` and `directorysizes`
//! sit beside it. Only top-level entries of `files/` have metadata. Moving
//! items *into* the trash stays with `gio trash` (`ops.trashItems`), which
//! knows the per-volume rules; nothing here talks to GIO, so tests use plain
//! fixture directories. Per-volume trashes (`$topdir/.Trash-$uid`) are not
//! handled: their `Path=` is relative to the volume and comes from removable
//! media, which needs its own containment checks.

const std = @import("std");
const c = @import("c.zig").api;
const ops = @import("ops.zig");
const Allocator = std.mem.Allocator;

/// Where a path lies relative to the trash's `files/` directory.
pub const Relation = enum {
    /// Not in the trash.
    none,
    /// The `files/` directory itself: its entries are the trashed items.
    root,
    /// Inside a trashed folder: no metadata of its own.
    inside,
};

/// By string, like the title and breadcrumb: `path` is a listing location.
pub fn relation(files_dir: []const u8, path: []const u8) Relation {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const p = path[0..end];
    if (std.mem.eql(u8, p, files_dir)) return .root;
    if (p.len > files_dir.len and std.mem.startsWith(u8, p, files_dir) and p[files_dir.len] == '/') return .inside;
    return .none;
}

pub const Info = struct {
    /// Where the item was before it was trashed: absolute, normalised.
    path: []u8,
    /// `DeletionDate=` as written (local time, no zone), if present.
    date: ?[]u8 = null,

    pub fn deinit(self: Info, a: Allocator) void {
        a.free(self.path);
        if (self.date) |d| a.free(d);
    }
};

pub const Restored = struct {
    /// The final location, which differs from the original when it was taken.
    path: []u8,
    renamed: bool,

    pub fn deinit(self: Restored, a: Allocator) void {
        a.free(self.path);
    }
};

pub const Summary = struct {
    restored: usize = 0,
    /// Included in `restored`: put back under a different name.
    renamed: usize = 0,
    /// No usable `.trashinfo`, so there is nowhere to put the entry.
    no_metadata: usize = 0,
    failed: usize = 0,
};

pub const Removed = struct { deleted: usize = 0, failed: usize = 0 };

/// A trashed entry's name is a single path component of `files/`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn root(files_dir: []const u8) []const u8 {
    return std.fs.path.dirname(files_dir) orelse "/";
}

fn within(dir: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, dir, path) or
        (path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/');
}

fn infoPath(buf: []u8, files_dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/info/{s}.trashinfo", .{ root(files_dir), name }, 0) catch error.PathTooLong;
}

fn entryPath(buf: []u8, files_dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ files_dir, name }, 0) catch error.PathTooLong;
}

fn errno() c_int {
    return std.c._errno().*;
}

fn readSmall(a: Allocator, path_z: [*:0]const u8, limit: usize) ![]u8 {
    const fd = c.open(path_z, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > limit) return error.TooLarge;
        try list.appendSlice(a, buf[0..len]);
    }
    return list.toOwnedSlice(a);
}

fn percentDecode(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var ch = text[i];
        if (ch == '%') {
            if (i + 3 > text.len) return error.InvalidEscape;
            ch = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.InvalidEscape;
            i += 2;
        }
        try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}

/// Parses the `[Trash Info]` group of a `.trashinfo` file. `Path=` must be an
/// absolute path without `.` or `..` components; anything else is invalid.
pub fn parseInfo(a: Allocator, text: []const u8) !Info {
    var in_group = false;
    var found_group = false;
    var raw_path: ?[]const u8 = null;
    var raw_date: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            in_group = std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t"), "[Trash Info]");
            found_group = found_group or in_group;
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, key, "Path")) {
            if (raw_path == null) raw_path = line[eq + 1 ..];
        } else if (std.mem.eql(u8, key, "DeletionDate")) {
            if (raw_date == null) raw_date = line[eq + 1 ..];
        }
    }
    if (!found_group) return error.InvalidMetadata;
    const encoded = raw_path orelse return error.InvalidMetadata;
    const decoded = percentDecode(a, encoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMetadata,
    };
    defer a.free(decoded);
    var end = decoded.len;
    while (end > 1 and decoded[end - 1] == '/') end -= 1;
    const path = decoded[0..end];
    if (path.len < 2 or path[0] != '/' or path.len >= std.fs.max_path_bytes - 300) return error.InvalidMetadata;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidMetadata;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidMetadata;
    }
    const owned_path = try a.dupe(u8, path);
    errdefer a.free(owned_path);
    const owned_date: ?[]u8 = if (raw_date) |d| try a.dupe(u8, std.mem.trim(u8, d, " \t")) else null;
    return .{ .path = owned_path, .date = owned_date };
}

/// The metadata of one top-level entry. `error.NoMetadata` when there is no
/// `.trashinfo`, `error.InvalidMetadata` when it is unusable.
pub fn readInfo(a: Allocator, files_dir: []const u8, name: []const u8) !Info {
    if (!validName(name)) return error.InvalidName;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try infoPath(&buf, files_dir, name);
    const text = readSmall(a, path, 16 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OpenFailed => return error.NoMetadata,
        else => return error.InvalidMetadata,
    };
    defer a.free(text);
    return parseInfo(a, text);
}

/// Whether `name` can be restored: it exists and its metadata names a place
/// outside the trash.
pub fn restorable(a: Allocator, files_dir: []const u8, name: []const u8) bool {
    const info = readInfo(a, files_dir, name) catch return false;
    defer info.deinit(a);
    if (within(root(files_dir), info.path)) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = entryPath(&buf, files_dir, name) catch return false;
    var st: c.struct_stat = undefined;
    return c.lstat(entry, &st) == 0;
}

fn isDir(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    var st: c.struct_stat = undefined;
    return c.stat(z, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

/// `mkdir -p`, remembering what it created so a failed restore can undo it.
fn makeParents(a: Allocator, dir: []const u8, created: *std.ArrayList([]u8)) !void {
    if (isDir(dir)) return;
    if (std.fs.path.dirname(dir)) |parent| {
        if (!std.mem.eql(u8, parent, dir)) try makeParents(a, parent, created);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return error.PathTooLong;
    if (c.mkdir(z, 0o777) != 0) {
        const err = errno();
        if (err == c.EEXIST and isDir(dir)) return;
        return switch (err) {
            c.EACCES, c.EPERM, c.EROFS => error.AccessDenied,
            else => error.NoParent,
        };
    }
    const owned = try a.dupe(u8, dir);
    errdefer a.free(owned);
    try created.append(a, owned);
}

fn canEnterAndWrite(dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return false;
    return c.access(z, c.W_OK | c.X_OK) == 0;
}

/// Puts `name` back where `.trashinfo` says it came from, never over an
/// existing item: a taken name gets the first free "name (N).ext". Missing
/// parent folders are recreated and removed again if the move fails.
pub fn restoreEntry(a: Allocator, files_dir: []const u8, name: []const u8) !Restored {
    if (!validName(name)) return error.InvalidName;
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = try entryPath(&src_buf, files_dir, name);
    var st: c.struct_stat = undefined;
    if (c.lstat(src, &st) != 0) return error.NotFound;

    const info = try readInfo(a, files_dir, name);
    defer info.deinit(a);
    if (within(root(files_dir), info.path)) return error.InvalidMetadata;

    const parent = std.fs.path.dirname(info.path) orelse return error.InvalidMetadata;
    const base = std.fs.path.basename(info.path);
    if (!validName(base)) return error.InvalidMetadata;

    var created: std.ArrayList([]u8) = .empty;
    defer {
        for (created.items) |dir| a.free(dir);
        created.deinit(a);
    }
    var moved = false;
    defer if (!moved) {
        var i = created.items.len;
        while (i > 0) : (i -= 1) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{created.items[i - 1]}, 0) catch continue;
            _ = c.rmdir(z);
        }
    };
    try makeParents(a, parent, &created);
    if (!canEnterAndWrite(parent)) return error.AccessDenied;

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const unique = try ops.generateUniqueName(a, parent, base);
        defer a.free(unique);
        const dest = try std.fs.path.join(a, &.{ parent, unique });
        if (ops.moveItem(a, src, dest, null)) |_| {
            moved = true;
            removeMetadata(a, files_dir, name);
            return .{ .path = dest, .renamed = !std.mem.eql(u8, unique, base) };
        } else |err| {
            a.free(dest);
            // Lost a race for the name: pick again, never overwrite.
            if (err == error.PathAlreadyExists and attempt < 8) continue;
            return error.RestoreFailed;
        }
    }
}

/// Deletes the `.trashinfo` and the `directorysizes` line of `name`. The item
/// itself is already gone, so a failure here only leaves harmless clutter.
fn removeMetadata(a: Allocator, files_dir: []const u8, name: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (infoPath(&buf, files_dir, name)) |path| _ = c.unlink(path) else |_| {}
    removeDirectorySize(a, files_dir, name) catch {};
}

fn sizeLineIsFor(a: Allocator, line: []const u8, name: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    const second = std.mem.indexOfScalarPos(u8, line, first + 1, ' ') orelse return false;
    const decoded = percentDecode(a, line[second + 1 ..]) catch return false;
    defer a.free(decoded);
    return std.mem.eql(u8, decoded, name);
}

/// Drops `name` from `directorysizes`, rewriting it through a temporary file
/// and rename, as the specification asks of everyone who edits it.
fn removeDirectorySize(a: Allocator, files_dir: []const u8, name: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/directorysizes", .{root(files_dir)}, 0) catch return error.PathTooLong;
    const data = readSmall(a, path, 16 * 1024 * 1024) catch return;
    defer a.free(data);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var changed = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (sizeLineIsFor(a, line, name)) {
            changed = true;
            continue;
        }
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    if (!changed) return;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}/directorysizes.{d}", .{ root(files_dir), c.getpid() }, 0) catch return error.PathTooLong;
    const fd = c.open(tmp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.WriteFailed;
    var ok = true;
    var written: usize = 0;
    while (written < out.items.len) {
        const n = c.write(fd, out.items[written..].ptr, out.items.len - written);
        if (n <= 0) {
            if (n < 0 and errno() == c.EINTR) continue;
            ok = false;
            break;
        }
        written += @intCast(n);
    }
    if (c.close(fd) != 0) ok = false;
    if (!ok or c.rename(tmp, path) != 0) {
        _ = c.unlink(tmp);
        return error.WriteFailed;
    }
}

/// Permanently removes one trashed entry and its metadata. The item goes
/// first: a crash then leaves an orphaned `.trashinfo` (swept by
/// `sweepOrphans`) instead of an item that can no longer be restored.
pub fn deleteEntry(a: Allocator, files_dir: []const u8, name: []const u8) !void {
    if (!validName(name)) return error.InvalidName;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try entryPath(&buf, files_dir, name);
    // deleteRecursive does not follow symlinks and treats a missing path as done.
    ops.deleteRecursive(a, entry) catch return error.DeleteFailed;
    removeMetadata(a, files_dir, name);
}

pub fn restoreMany(a: Allocator, files_dir: []const u8, names: []const []const u8) Summary {
    var summary: Summary = .{};
    for (names) |name| {
        const restored = restoreEntry(a, files_dir, name) catch |err| {
            switch (err) {
                error.NoMetadata, error.InvalidMetadata => summary.no_metadata += 1,
                else => summary.failed += 1,
            }
            continue;
        };
        defer restored.deinit(a);
        summary.restored += 1;
        if (restored.renamed) summary.renamed += 1;
    }
    return summary;
}

pub fn deleteMany(a: Allocator, files_dir: []const u8, names: []const []const u8) Removed {
    var removed: Removed = .{};
    for (names) |name| {
        if (deleteEntry(a, files_dir, name)) |_| removed.deleted += 1 else |_| removed.failed += 1;
    }
    return removed;
}

/// Every top-level entry of `files/`, in directory order. Free with `freeNames`.
pub fn listEntries(a: Allocator, files_dir: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer names.deinit(a);
    errdefer freeNames(a, names.items);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{files_dir}, 0) catch return error.PathTooLong;
    const dir = c.opendir(z) orelse return names.toOwnedSlice(a);
    defer _ = c.closedir(dir);
    while (true) {
        std.c._errno().* = 0;
        const entry = c.readdir(dir) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const owned = try a.dupe(u8, name);
        errdefer a.free(owned);
        try names.append(a, owned);
    }
    return names.toOwnedSlice(a);
}

pub fn freeNames(a: Allocator, names: []const []u8) void {
    for (names) |name| a.free(name);
}

/// Removes `.trashinfo` files whose item no longer exists (a crash between the
/// two deletions, or an item moved out by other means).
pub fn sweepOrphans(a: Allocator, files_dir: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const info_dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/info", .{root(files_dir)}, 0) catch return;
    const dir = c.opendir(info_dir) orelse return;
    var orphans: std.ArrayList([]u8) = .empty;
    defer {
        for (orphans.items) |name| a.free(name);
        orphans.deinit(a);
    }
    while (true) {
        const entry = c.readdir(dir) orelse break;
        const file = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.endsWith(u8, file, ".trashinfo")) continue;
        const stem = file[0 .. file.len - ".trashinfo".len];
        if (!validName(stem)) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const item = entryPath(&buf, files_dir, stem) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(item, &st) == 0 or errno() != c.ENOENT) continue;
        const owned = a.dupe(u8, stem) catch continue;
        orphans.append(a, owned) catch a.free(owned);
    }
    _ = c.closedir(dir);
    // Unlink after the scan so the directory is not changed while it is read.
    for (orphans.items) |stem| removeMetadata(a, files_dir, stem);
}
