//! What the Trash holds, counted off the UI thread. Files and the desktop's
//! Trash icon show the same totals in the same Properties window
//! (`trash_properties.zig`), so there is one walker.
//!
//! Items are the top-level entries of `Trash/files` (what the Trash view lists
//! and Empty Trash removes); the size is every payload byte below them. Links
//! are counted, never followed, and directory or `.trashinfo` metadata is not
//! included.
const std = @import("std");
const c = @import("c.zig").api;

const a = std.heap.c_allocator;

pub const Summary = struct {
    items: u64 = 0,
    bytes: i64 = 0,
    /// Something could not be read or the walk was cancelled: `bytes` is a
    /// lower bound.
    partial: bool = false,
};

pub fn collect(path: []const u8, stop: *const std.atomic.Value(bool)) Summary {
    var result: Summary = .{};
    const z = a.dupeSentinel(u8, path, 0) catch {
        result.partial = true;
        return result;
    };
    defer a.free(z);
    const fd = c.open(z, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        result.partial = true;
        return result;
    }
    walk(fd, 0, stop, &result);
    return result;
}

// Owns fd. Never follows links, counts top-level deleted entries, and sums
// payload sizes recursively (excluding directory and .trashinfo metadata).
fn walk(fd: c_int, depth: usize, stop: *const std.atomic.Value(bool), result: *Summary) void {
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        result.partial = true;
        return;
    };
    defer _ = c.closedir(dir);
    while (!stop.load(.acquire)) {
        std.c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (std.c._errno().* != 0) result.partial = true;
            return;
        };
        const name: [*:0]const u8 = @ptrCast(&entry.*.d_name);
        if (std.mem.eql(u8, std.mem.span(name), ".") or std.mem.eql(u8, std.mem.span(name), "..")) continue;
        if (depth == 0) result.items += 1;
        var st: c.struct_stat = undefined;
        if (c.fstatat(fd, name, &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
            result.partial = true;
            continue;
        }
        if (st.st_mode & c.S_IFMT == c.S_IFDIR) {
            if (depth >= 128) {
                result.partial = true;
                continue;
            }
            const child = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (child < 0) result.partial = true else walk(child, depth + 1, stop, result);
        } else result.bytes +|= @max(0, st.st_size);
    }
    result.partial = true;
}

/// One count on its own thread, for as long as a Properties window is open.
/// The host polls from its loop; the thread writes to `wake_fd` (the host's
/// existing eventfd) when it finishes, so nothing ticks while idle.
pub const Task = struct {
    path: [:0]u8,
    wake_fd: c_int,
    stop: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    result: Summary = .{},
    thread: std.Thread = undefined,

    pub fn start(path: []const u8, wake_fd: c_int) !*Task {
        const self = try a.create(Task);
        errdefer a.destroy(self);
        self.* = .{ .path = try a.dupeSentinel(u8, path, 0), .wake_fd = wake_fd };
        errdefer a.free(self.path);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Task) void {
        self.result = collect(self.path, &self.stop);
        self.finished.store(true, .release);
        if (self.wake_fd >= 0) {
            const one: u64 = 1;
            _ = c.write(self.wake_fd, &one, @sizeOf(u64));
        }
    }

    /// The totals once the walk is over.
    pub fn poll(self: *const Task) ?Summary {
        if (!self.finished.load(.acquire)) return null;
        return self.result;
    }

    /// Cancels a walk in progress and waits for the thread, so the wake fd
    /// may be closed afterwards.
    pub fn destroy(self: *Task) void {
        self.stop.store(true, .release);
        self.thread.join();
        a.free(self.path);
        a.destroy(self);
    }
};

test {
    _ = @import("trash_totals_tests.zig");
}
