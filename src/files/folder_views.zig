//! The view each folder was last given: grid or list, the sort order and
//! whether folders come first. A folder is remembered only once one of those
//! is changed while it is open, and only for the parts that differ from the
//! defaults; everything else follows the defaults (`files_folders_first` in
//! the compositor config, the rest in `preferences.zig`). A folder's entry
//! does not apply to its subfolders.
//!
//! The process owns one store (`main.run`) that every window shares, so two
//! windows on the same folder agree. Windows run on the UI thread, which only
//! touches the map; a writer thread of the store's own puts it on disk, so a
//! change never waits on the filesystem. The file is read once, at startup.
//!
//! File: a `rediwm-folder-views 1` line, then one line per folder:
//! `<list> <sort> <folders_first>\t<path>`, each field a digit or `-` when it
//! follows the default. Paths with a newline are not remembered.
const std = @import("std");
const c = @import("c.zig").api;

const a = std.heap.c_allocator;
const header = "rediwm-folder-views 1\n";

/// Folders remembered at most; the one changed longest ago goes first.
pub const capacity = 4000;

/// What a folder overrides; null parts follow the defaults.
pub const View = struct {
    list: ?bool = null,
    sort: ?u8 = null,
    folders_first: ?bool = null,

    pub fn isEmpty(self: View) bool {
        return self.list == null and self.sort == null and self.folders_first == null;
    }
};

const Entry = struct { view: View, stamp: u64 };

pub const Store = struct {
    io: std.Io,
    path: ?[]u8 = null,
    // UI thread only.
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    stamp: u64 = 0,
    /// Bumped on every change, so windows notice another window's change.
    generation: u64 = 0,

    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    // Under `mutex`: the latest serialized map the writer has yet to save.
    pending: ?[]u8 = null,
    stopping: bool = false,
    written: u64 = 0,
    thread: ?std.Thread = null,

    /// Reads `path` (when given) and starts the writer. Without a path the
    /// store only lives in memory.
    pub fn start(self: *Store, io: std.Io, path: ?[]const u8) !void {
        self.* = .{ .io = io };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        if (path) |p| {
            self.path = try a.dupe(u8, p);
            self.load(p);
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }
    }

    /// Saves what is pending, then stops the writer.
    pub fn deinit(self: *Store) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stopping = true;
        _ = c.pthread_cond_signal(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.thread) |thread| thread.join();
        if (self.pending) |bytes| a.free(bytes);
        var it = self.map.keyIterator();
        while (it.next()) |key| a.free(key.*);
        self.map.deinit(a);
        if (self.path) |p| a.free(p);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.* = undefined;
    }

    pub fn get(self: *const Store, folder: []const u8) View {
        return if (self.map.get(folder)) |entry| entry.view else .{};
    }

    /// Remembers `view` for `folder`; an empty view forgets the folder.
    pub fn set(self: *Store, folder: []const u8, view: View) void {
        if (std.mem.indexOfScalar(u8, folder, '\n') != null) return;
        if (std.meta.eql(self.get(folder), view)) return;
        if (view.isEmpty()) {
            if (self.map.fetchRemove(folder)) |removed| a.free(removed.key);
        } else {
            self.put(folder, view) catch return;
        }
        self.generation +%= 1;
        self.schedule();
    }

    fn put(self: *Store, folder: []const u8, view: View) !void {
        self.stamp += 1;
        if (self.map.getPtr(folder)) |entry| {
            entry.* = .{ .view = view, .stamp = self.stamp };
            return;
        }
        if (self.map.count() >= capacity) self.evictOldest();
        const key = try a.dupe(u8, folder);
        errdefer a.free(key);
        try self.map.put(a, key, .{ .view = view, .stamp = self.stamp });
    }

    fn evictOldest(self: *Store) void {
        var oldest: ?[]const u8 = null;
        var oldest_stamp: u64 = std.math.maxInt(u64);
        var it = self.map.iterator();
        while (it.next()) |kv| if (kv.value_ptr.stamp < oldest_stamp) {
            oldest_stamp = kv.value_ptr.stamp;
            oldest = kv.key_ptr.*;
        };
        if (oldest) |key| if (self.map.fetchRemove(key)) |removed| a.free(removed.key);
    }

    /// Hands the writer a fresh copy of the map. Out of memory, the change
    /// stays in memory and goes to disk with the next one.
    fn schedule(self: *Store) void {
        if (self.thread == null) return;
        const bytes = self.serialize() catch return;
        _ = c.pthread_mutex_lock(&self.mutex);
        if (self.pending) |old| a.free(old);
        self.pending = bytes;
        _ = c.pthread_cond_signal(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// Oldest first, so a reload hands out stamps in the same order.
    pub fn serialize(self: *const Store) ![]u8 {
        const Kv = struct { key: []const u8, entry: Entry };
        var entries: std.ArrayList(Kv) = .empty;
        defer entries.deinit(a);
        var it = self.map.iterator();
        while (it.next()) |kv| try entries.append(a, .{ .key = kv.key_ptr.*, .entry = kv.value_ptr.* });
        std.mem.sort(Kv, entries.items, {}, struct {
            fn less(_: void, x: Kv, y: Kv) bool {
                return x.entry.stamp < y.entry.stamp;
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, header);
        for (entries.items) |kv| {
            const v = kv.entry.view;
            try out.append(a, if (v.list) |on| '0' + @as(u8, @intFromBool(on)) else '-');
            try out.append(a, ' ');
            try out.append(a, if (v.sort) |s| '0' + s else '-');
            try out.append(a, ' ');
            try out.append(a, if (v.folders_first) |on| '0' + @as(u8, @intFromBool(on)) else '-');
            try out.append(a, '\t');
            try out.appendSlice(a, kv.key);
            try out.append(a, '\n');
        }
        return out.toOwnedSlice(a);
    }

    /// Takes the lines of `bytes` it understands and skips the rest.
    pub fn parse(self: *Store, bytes: []const u8) void {
        if (!std.mem.startsWith(u8, bytes, header)) return;
        var lines = std.mem.splitScalar(u8, bytes[header.len..], '\n');
        while (lines.next()) |line| {
            if (line.len < 7 or line[1] != ' ' or line[3] != ' ' or line[5] != '\t') continue;
            const folder = line[6..];
            if (folder.len == 0) continue;
            const view: View = .{
                .list = flag(line[0]) catch continue,
                .sort = switch (line[2]) {
                    '-' => null,
                    '0'...'7' => line[2] - '0',
                    else => continue,
                },
                .folders_first = flag(line[4]) catch continue,
            };
            if (view.isEmpty()) continue;
            self.put(folder, view) catch return;
        }
    }

    fn flag(byte: u8) !?bool {
        return switch (byte) {
            '-' => null,
            '0' => false,
            '1' => true,
            else => error.Invalid,
        };
    }

    fn load(self: *Store, path: []const u8) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(8 << 20)) catch return;
        defer a.free(bytes);
        self.parse(bytes);
    }

    /// How many snapshots the writer has put on disk; for tests.
    pub fn writtenCount(self: *Store) u64 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return self.written;
    }

    fn run(self: *Store) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        while (true) {
            if (self.pending) |bytes| {
                self.pending = null;
                _ = c.pthread_mutex_unlock(&self.mutex);
                self.write(bytes) catch |err| std.log.warn("could not save folder views: {}", .{err});
                a.free(bytes);
                _ = c.pthread_mutex_lock(&self.mutex);
                self.written += 1;
                continue;
            }
            if (self.stopping) break;
            _ = c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn write(self: *Store, bytes: []const u8) !void {
        const file = self.path.?;
        const dir = std.Io.Dir.cwd();
        if (std.fs.path.dirname(file)) |parent| try dir.createDirPath(self.io, parent);
        const temporary = try std.fmt.allocPrint(a, "{s}.{d}.tmp", .{ file, c.getpid() });
        defer a.free(temporary);
        defer dir.deleteFile(self.io, temporary) catch {};
        try dir.writeFile(self.io, .{ .sub_path = temporary, .data = bytes });
        try std.Io.Dir.rename(.cwd(), temporary, .cwd(), file, self.io);
    }
};

/// `$XDG_STATE_HOME/rediwm/files-folder-views`, next to `files-view`.
pub fn statePath(alloc: std.mem.Allocator, env: std.process.Environ) ![]u8 {
    if (env.getPosix("XDG_STATE_HOME")) |base| {
        if (std.fs.path.isAbsolute(base)) return std.fs.path.join(alloc, &.{ base, "rediwm", "files-folder-views" });
    }
    const home = env.getPosix("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".local/state/rediwm/files-folder-views" });
}

test {
    _ = @import("folder_views_tests.zig");
}
