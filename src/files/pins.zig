//! Folders and files dropped into the sidebar's PLACES, in the order shown.
//!
//! One absolute path per line in `$XDG_STATE_HOME/rediwm/files-places`. The
//! file is the truth: Files re-reads it before every change, so two windows
//! never overwrite each other's pins.
const std = @import("std");
const c = @import("c.zig").api;

pub const max = 64;
const file_limit = max * (std.fs.max_path_bytes + 1);

pub const Kind = enum { dir, file, missing };

pub const Pin = struct {
    path: []u8,
    kind: Kind,

    /// What the sidebar calls the pin.
    pub fn name(self: Pin) []const u8 {
        const base = std.fs.path.basename(self.path);
        return if (base.len > 0) base else self.path;
    }
};

pub const InsertError = error{ Invalid, Duplicate, Missing, Full, OutOfMemory };

pub fn kindOf(path: []const u8) Kind {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return .missing;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var stat: c.struct_stat = undefined;
    if (c.stat(@ptrCast(&buf), &stat) != 0) return .missing;
    return if (stat.st_mode & c.S_IFMT == c.S_IFDIR) .dir else .file;
}

/// `path` without trailing slashes, or null when it cannot be a pin: not
/// absolute, or holding a byte the line format cannot carry.
pub fn normalize(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.indexOfAny(u8, path, "\n\x00") != null) return null;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

pub fn statePath(a: std.mem.Allocator, env: std.process.Environ) ![]u8 {
    if (env.getPosix("XDG_STATE_HOME")) |base| {
        if (std.fs.path.isAbsolute(base)) return std.fs.path.join(a, &.{ base, "rediwm", "files-places" });
    }
    const home = env.getPosix("HOME") orelse return error.NoHome;
    return std.fs.path.join(a, &.{ home, ".local/state/rediwm/files-places" });
}

pub const List = struct {
    items: std.ArrayList(Pin) = .empty,

    pub fn deinit(self: *List, a: std.mem.Allocator) void {
        for (self.items.items) |pin| a.free(pin.path);
        self.items.deinit(a);
    }

    pub fn find(self: List, path: []const u8) ?usize {
        for (self.items.items, 0..) |pin, i| {
            if (std.mem.eql(u8, pin.path, path)) return i;
        }
        return null;
    }

    /// Pins `path` so it ends up at `slot` (clamped to the end).
    pub fn insert(self: *List, a: std.mem.Allocator, slot: usize, path: []const u8) InsertError!void {
        const clean = normalize(path) orelse return error.Invalid;
        if (self.find(clean) != null) return error.Duplicate;
        if (self.items.items.len >= max) return error.Full;
        const kind = kindOf(clean);
        if (kind == .missing) return error.Missing;
        const owned = try a.dupe(u8, clean);
        errdefer a.free(owned);
        try self.items.insert(a, @min(slot, self.items.items.len), .{ .path = owned, .kind = kind });
    }

    pub fn remove(self: *List, a: std.mem.Allocator, index: usize) void {
        if (index >= self.items.items.len) return;
        a.free(self.items.orderedRemove(index).path);
    }

    /// Looks at the targets again: they come and go with removable drives.
    pub fn refresh(self: *List) void {
        for (self.items.items) |*pin| pin.kind = kindOf(pin.path);
    }

    /// What the file holds; nothing for a missing or unreadable one, and
    /// lines that are not usable paths are dropped.
    pub fn load(a: std.mem.Allocator, io: std.Io, file: []const u8) List {
        var list: List = .{};
        const data = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(file_limit)) catch return list;
        defer a.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (list.items.items.len >= max) break;
            const clean = normalize(line) orelse continue;
            if (list.find(clean) != null) continue;
            const owned = a.dupe(u8, clean) catch break;
            list.items.append(a, .{ .path = owned, .kind = kindOf(owned) }) catch {
                a.free(owned);
                break;
            };
        }
        return list;
    }

    pub fn save(self: List, a: std.mem.Allocator, io: std.Io, file: []const u8) !void {
        if (std.fs.path.dirname(file)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(a);
        for (self.items.items) |pin| {
            try data.appendSlice(a, pin.path);
            try data.append(a, '\n');
        }
        const temporary = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ file, c.getpid() });
        defer a.free(temporary);
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = data.items });
        try std.Io.Dir.rename(.cwd(), temporary, .cwd(), file, io);
    }
};

test "pins keep their order, refuse duplicates and unusable paths, and survive a restart" {
    const a = std.testing.allocator;
    var list: List = .{};
    defer list.deinit(a);
    try list.insert(a, 0, "/tmp/");
    try list.insert(a, 5, "/dev/null");
    try list.insert(a, 0, "/");
    try std.testing.expectError(error.Duplicate, list.insert(a, 0, "/tmp"));
    try std.testing.expectError(error.Invalid, list.insert(a, 0, "tmp"));
    try std.testing.expectError(error.Invalid, list.insert(a, 0, "/tmp/a\nb"));
    try std.testing.expectError(error.Missing, list.insert(a, 0, "/nonexistent-rediwm-pin"));
    try std.testing.expectEqualStrings("/", list.items.items[0].path);
    try std.testing.expectEqualStrings("/tmp", list.items.items[1].path);
    try std.testing.expectEqual(Kind.dir, list.items.items[1].kind);
    try std.testing.expectEqual(Kind.file, list.items.items[2].kind);
    try std.testing.expectEqualStrings("null", list.items.items[2].name());

    var dir: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&dir, "/tmp/rediwm-pins-{d}", .{c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmp) catch {};
    const file = try std.fmt.allocPrint(a, "{s}/state/files-places", .{tmp});
    defer a.free(file);
    try list.save(a, std.testing.io, file);
    list.remove(a, 1);
    var loaded = List.load(a, std.testing.io, file);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), loaded.items.items.len);
    try std.testing.expectEqualStrings("/dev/null", loaded.items.items[2].path);
    try std.testing.expectEqual(@as(usize, 2), list.items.items.len);
}
