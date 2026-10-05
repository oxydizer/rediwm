const std = @import("std");
const archive = @import("archive.zig");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

pub const ConflictAction = enum {
    ask,
    skip,
    rename,
    cancel,
};

pub const JobState = enum {
    idle,
    running,
    waiting_conflict,
    finished,
};

pub const OpKind = enum {
    copy,
    move,
    extract,
    open_archive_member,
};

pub const ItemOutcome = enum {
    success,
    skipped,
    failed,
    cancelled,
};

pub const ItemResult = struct {
    src: []const u8,
    dst: ?[]const u8 = null,
    outcome: ItemOutcome,
    error_msg: ?[]const u8 = null,
};

pub const ProgressInfo = struct {
    state: JobState,
    total_items: usize = 0,
    processed_items: usize = 0,
    success_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,
    current_name: []const u8 = "",
    conflict_item_name: []const u8 = "",
    status_message: []const u8 = "",
    is_error: bool = false,
    cancelled: bool = false,
};

pub fn validateFilename(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidCharacter;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidCharacter;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.ReservedName;
}

pub fn createFolder(allocator: Allocator, dir: []const u8, name: []const u8) !void {
    try validateFilename(name);
    const full_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(full_path);

    if (c.mkdir(full_path, 0o755) != 0) {
        return switch (std.c._errno().*) {
            c.EEXIST => error.PathAlreadyExists,
            c.EACCES => error.AccessDenied,
            else => error.CreateFailed,
        };
    }
}

pub fn createFile(allocator: Allocator, dir: []const u8, name: []const u8) !void {
    try validateFilename(name);
    const full_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(full_path);

    const fd = c.open(full_path, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) {
        return switch (std.c._errno().*) {
            c.EEXIST => error.PathAlreadyExists,
            c.EACCES => error.AccessDenied,
            else => error.CreateFailed,
        };
    }
    _ = c.close(fd);
}

pub fn renameItem(allocator: Allocator, old_path: []const u8, new_name: []const u8) !void {
    try validateFilename(new_name);
    const parent = std.fs.path.dirname(old_path) orelse return error.InvalidPath;
    if (std.mem.eql(u8, std.fs.path.basename(old_path), new_name)) return;

    const new_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ parent, new_name }, 0);
    defer allocator.free(new_path);

    const old_z = try allocator.dupeZ(u8, old_path);
    defer allocator.free(old_z);

    if (c.renameat2(c.AT_FDCWD, old_z, c.AT_FDCWD, new_path, 1) != 0) {
        return switch (std.c._errno().*) {
            c.EEXIST => error.PathAlreadyExists,
            c.EACCES => error.AccessDenied,
            else => error.RenameFailed,
        };
    }
}

/// rm removes directory trees without following symlinks; -- protects option-like names.
pub fn deleteItems(io: std.Io, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(std.heap.c_allocator);
    try args.appendSlice(std.heap.c_allocator, &.{ "rm", "-r", "--interactive=never", "--" });
    try args.appendSlice(std.heap.c_allocator, paths);
    var child = try std.process.spawn(io, .{ .argv = args.items });
    const result = try child.wait(io);
    if (result != .exited or result.exited != 0) return error.DeleteFailed;
}

pub fn trashItems(io: std.Io, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(std.heap.c_allocator);

    try args.append(std.heap.c_allocator, "gio");
    try args.append(std.heap.c_allocator, "trash");
    try args.append(std.heap.c_allocator, "--");
    for (paths) |p| {
        try args.append(std.heap.c_allocator, p);
    }

    var child = std.process.spawn(io, .{ .argv = args.items }) catch |err| {
        if (err == error.FileNotFound) return error.GioNotAvailable;
        return error.TrashFailed;
    };
    const res = try child.wait(io);
    if (res != .exited or res.exited != 0) return error.TrashFailed;
}

pub fn isDescendantOrSame(src: []const u8, dst: []const u8) bool {
    if (std.mem.eql(u8, src, dst)) return true;
    if (std.mem.startsWith(u8, dst, src) and dst.len > src.len and dst[src.len] == '/') return true;

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = std.fmt.bufPrintZ(&src_buf, "{s}", .{src}) catch return false;
    const dst_z = std.fmt.bufPrintZ(&dst_buf, "{s}", .{dst}) catch return false;

    var src_st: c.struct_stat = undefined;
    var dst_st: c.struct_stat = undefined;
    if (c.stat(src_z, &src_st) != 0 or c.stat(dst_z, &dst_st) != 0) return false;

    if ((src_st.st_mode & c.S_IFMT) != c.S_IFDIR) return false;
    if (src_st.st_dev == dst_st.st_dev and src_st.st_ino == dst_st.st_ino) return true;

    var cur: []const u8 = dst;
    while (std.fs.path.dirname(cur)) |p| {
        if (std.mem.eql(u8, p, cur)) break;
        var p_buf: [4096]u8 = undefined;
        const p_z = std.fmt.bufPrintZ(&p_buf, "{s}", .{p}) catch break;
        var p_st: c.struct_stat = undefined;
        if (c.stat(p_z, &p_st) == 0) {
            if (p_st.st_dev == src_st.st_dev and p_st.st_ino == src_st.st_ino) return true;
        }
        cur = p;
    }
    return false;
}

pub fn generateUniqueName(allocator: Allocator, dest_dir: []const u8, original_name: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const initial_z = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dest_dir, original_name });
    var st: c.struct_stat = undefined;
    if (c.lstat(initial_z, &st) != 0) {
        return try allocator.dupe(u8, original_name);
    }

    var stem: []const u8 = original_name;
    var ext: []const u8 = "";
    if (std.mem.startsWith(u8, original_name, ".") and std.mem.indexOfScalar(u8, original_name[1..], '.') == null) {
        stem = original_name;
        ext = "";
    } else {
        const e = std.fs.path.extension(original_name);
        ext = e;
        stem = original_name[0 .. original_name.len - e.len];
    }

    var count: usize = 1;
    while (count < 10000) : (count += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, count, ext });
        const cand_z = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dest_dir, candidate }) catch {
            allocator.free(candidate);
            return error.PathTooLong;
        };
        if (c.lstat(cand_z, &st) != 0) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return error.TooManyDuplicates;
}

pub fn copyFileContents(allocator: Allocator, src_path: []const u8, dst_path: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    const src_z = try allocator.dupeZ(u8, src_path);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeZ(u8, dst_path);
    defer allocator.free(dst_z);

    const src_fd = c.open(src_z, c.O_RDONLY | c.O_CLOEXEC);
    if (src_fd < 0) return error.OpenSourceFailed;
    defer _ = c.close(src_fd);

    var stat: c.struct_stat = undefined;
    if (c.fstat(src_fd, &stat) != 0) return error.StatFailed;

    const mode = @as(c_uint, @intCast(stat.st_mode & 0o7777));
    const dst_fd = c.open(dst_z, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, mode);
    if (dst_fd < 0) return error.OpenDestFailed;
    defer _ = c.close(dst_fd);

    var buf: [65536]u8 = undefined;
    while (true) {
        if (cancel != null and cancel.?.load(.acquire)) {
            _ = c.unlink(dst_z);
            return error.Cancelled;
        }
        const n = c.read(src_fd, &buf, buf.len);
        if (n == 0) break;
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) {
            _ = c.unlink(dst_z);
            return error.ReadFailed;
        }
        var written: usize = 0;
        const total = @as(usize, @intCast(n));
        while (written < total) {
            const wn = c.write(dst_fd, buf[written..].ptr, total - written);
            if (wn < 0 and std.posix.errno(wn) == .INTR) continue;
            if (wn <= 0) {
                _ = c.unlink(dst_z);
                return error.WriteFailed;
            }
            written += @intCast(wn);
        }
    }
}

pub fn copySymlink(allocator: Allocator, src_path: []const u8, dst_path: []const u8) !void {
    const src_z = try allocator.dupeZ(u8, src_path);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeZ(u8, dst_path);
    defer allocator.free(dst_z);

    var target_buf: [4096]u8 = undefined;
    const len = c.readlink(src_z, &target_buf, target_buf.len - 1);
    if (len < 0) return error.ReadlinkFailed;
    target_buf[@intCast(len)] = 0;

    if (c.symlink(&target_buf, dst_z) != 0) return error.SymlinkFailed;
}

pub fn copyRecursive(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var st: c.struct_stat = undefined;
    if (c.lstat(src_z, &st) != 0) return error.StatFailed;

    const fmt = st.st_mode & c.S_IFMT;
    if (fmt == c.S_IFLNK) {
        return copySymlink(allocator, src, dst);
    } else if (fmt == c.S_IFDIR) {
        const dst_z = try allocator.dupeZ(u8, dst);
        defer allocator.free(dst_z);

        if (c.mkdir(dst_z, @as(c_uint, @intCast(st.st_mode & 0o7777))) != 0) return error.CreateDirectoryFailed;
        // Only remove a destination created by this operation on failure.
        errdefer deleteRecursive(allocator, dst) catch {};

        const dir_handle = c.opendir(src_z) orelse return error.OpenDirectoryFailed;
        defer _ = c.closedir(dir_handle);

        while (true) {
            std.c._errno().* = 0;
            const entry = c.readdir(dir_handle) orelse {
                if (std.c._errno().* != 0) return error.ReadDirectoryFailed;
                break;
            };
            if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const child_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src, name });
            defer allocator.free(child_src);
            const child_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, name });
            defer allocator.free(child_dst);

            try copyRecursive(allocator, child_src, child_dst, cancel);
        }
    } else if (fmt == c.S_IFREG) {
        return copyFileContents(allocator, src, dst, cancel);
    } else return error.UnsupportedFileType;
}

pub fn deleteRecursive(allocator: Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var st: c.struct_stat = undefined;
    if (c.lstat(path_z, &st) != 0) {
        if (std.c._errno().* == c.ENOENT) return;
        return error.StatFailed;
    }

    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        const dir_handle = c.opendir(path_z) orelse return error.OpenDirectoryFailed;
        defer _ = c.closedir(dir_handle);

        while (true) {
            std.c._errno().* = 0;
            const entry = c.readdir(dir_handle) orelse {
                if (std.c._errno().* != 0) return error.ReadDirectoryFailed;
                break;
            };
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
            defer allocator.free(child);
            try deleteRecursive(allocator, child);
        }
        if (c.rmdir(path_z) != 0) return error.DeleteFailed;
    } else {
        if (c.unlink(path_z) != 0) return error.DeleteFailed;
    }
}

pub fn crossDeviceMove(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    if (isDescendantOrSame(src, dst)) return error.CannotMoveIntoDescendant;

    // Copy cleans up only destinations it created; a raced existing target is preserved.
    try copyRecursive(allocator, src, dst, cancel);
    if (cancel != null and cancel.?.load(.acquire)) {
        deleteRecursive(allocator, dst) catch {};
        return error.Cancelled;
    }

    // Step 2: Copy succeeded 100%, now remove src.
    try deleteRecursive(allocator, src);
}

pub fn moveItem(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    if (isDescendantOrSame(src, dst)) return error.CannotMoveIntoDescendant;
    if (std.mem.eql(u8, src, dst)) return;

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeZ(u8, dst);
    defer allocator.free(dst_z);

    if (c.renameat2(c.AT_FDCWD, src_z, c.AT_FDCWD, dst_z, 1) == 0) {
        return;
    }

    const err = std.c._errno().*;
    if (err == c.EEXIST) {
        return error.PathAlreadyExists;
    } else if (err == c.EXDEV) {
        return crossDeviceMove(allocator, src, dst, cancel);
    } else {
        return error.RenameFailed;
    }
}

pub const JobRunner = struct {
    allocator: Allocator,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    wake_fd: c_int = -1,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    // Protected by mutex
    state: JobState = .idle,
    kind: OpKind = .copy,
    sources: std.ArrayList([]const u8) = .empty,
    outcomes: std.ArrayList(ItemOutcome) = .empty,
    dest_dir: []u8 = &[_]u8{},
    member: ?[]u8 = null,
    result_path: ?[]u8 = null,
    temporary_dirs: std.ArrayList([]u8) = .empty,
    default_conflict: ConflictAction = .ask,

    total_items: usize = 0,
    processed_items: usize = 0,
    success_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,

    current_item_name: []const u8 = &[_]u8{},
    conflict_item_name: []const u8 = &[_]u8{},
    conflict_action: ?ConflictAction = null,

    status_message: []u8 = &[_]u8{},
    is_error: bool = false,

    pub fn init(allocator: Allocator) !*JobRunner {
        const self = try allocator.create(JobRunner);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .sources = .empty,
        };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        if (c.pthread_cond_init(&self.cond, null) != 0) {
            _ = c.pthread_mutex_destroy(&self.mutex);
            return error.CondInitFailed;
        }
        self.wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_fd < 0) {
            _ = c.pthread_cond_destroy(&self.cond);
            _ = c.pthread_mutex_destroy(&self.mutex);
            return error.EventFdFailed;
        }
        return self;
    }

    fn notify(self: *JobRunner) void {
        const one: u64 = 1;
        _ = c.write(self.wake_fd, &one, @sizeOf(u64));
    }

    pub fn drain(self: *JobRunner) void {
        var count: u64 = 0;
        _ = c.read(self.wake_fd, &count, @sizeOf(u64));
    }

    pub fn deinit(self: *JobRunner) void {
        self.cancel();
        if (self.thread) |t| t.join();
        _ = c.close(self.wake_fd);

        self.clearStrings();
        for (self.temporary_dirs.items) |path| {
            deleteRecursive(self.allocator, path) catch {};
            self.allocator.free(path);
        }
        self.temporary_dirs.deinit(self.allocator);
        for (self.sources.items) |s| self.allocator.free(s);
        self.sources.deinit(self.allocator);
        self.outcomes.deinit(self.allocator);

        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }

    fn clearStrings(self: *JobRunner) void {
        if (self.member) |member| self.allocator.free(member);
        if (self.result_path) |path| self.allocator.free(path);
        self.member = null;
        self.result_path = null;
        if (self.dest_dir.len > 0) self.allocator.free(self.dest_dir);
        if (self.status_message.len > 0) self.allocator.free(self.status_message);
        self.dest_dir = &[_]u8{};
        self.current_item_name = &[_]u8{};
        self.conflict_item_name = &[_]u8{};
        self.status_message = &[_]u8{};
    }

    pub fn start(
        self: *JobRunner,
        kind: OpKind,
        sources: []const []const u8,
        dest_dir: []const u8,
        default_conflict: ConflictAction,
    ) !void {
        return self.startImpl(kind, sources, dest_dir, default_conflict, null);
    }

    pub fn startArchive(self: *JobRunner, source: []const u8, dest_dir: []const u8, member: ?[]const u8) !void {
        return self.startImpl(if (member != null) .open_archive_member else .extract, &.{source}, dest_dir, .ask, member);
    }

    fn startImpl(self: *JobRunner, kind: OpKind, sources: []const []const u8, dest_dir: []const u8, default_conflict: ConflictAction, member: ?[]const u8) !void {
        const progress = self.pollProgress();
        if (progress.state == .running or progress.state == .waiting_conflict) return error.Busy;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        _ = c.pthread_mutex_lock(&self.mutex);
        errdefer _ = c.pthread_mutex_unlock(&self.mutex);
        self.clearStrings();
        self.state = .idle;
        for (self.sources.items) |s| self.allocator.free(s);
        self.sources.clearRetainingCapacity();

        for (sources) |src| {
            const owned = try self.allocator.dupe(u8, src);
            errdefer self.allocator.free(owned);
            try self.sources.append(self.allocator, owned);
        }
        self.outcomes.clearRetainingCapacity();
        try self.outcomes.appendNTimes(self.allocator, .cancelled, sources.len);
        self.dest_dir = try self.allocator.dupe(u8, dest_dir);
        if (member) |name| self.member = try self.allocator.dupe(u8, name);
        self.kind = kind;
        self.default_conflict = default_conflict;
        self.state = .running;
        self.cancel_flag.store(false, .release);

        self.total_items = self.sources.items.len;
        self.processed_items = 0;
        self.success_count = 0;
        self.skipped_count = 0;
        self.failed_count = 0;
        self.conflict_action = null;
        self.is_error = false;

        _ = c.pthread_mutex_unlock(&self.mutex);

        self.thread = std.Thread.spawn(.{}, workerThread, .{self}) catch |err| {
            _ = c.pthread_mutex_lock(&self.mutex);
            self.state = .idle;
            return err;
        };
    }

    pub fn cancel(self: *JobRunner) void {
        self.cancel_flag.store(true, .release);
        _ = c.pthread_mutex_lock(&self.mutex);
        if (self.state == .waiting_conflict) {
            self.conflict_action = .cancel;
            _ = c.pthread_cond_signal(&self.cond);
        }
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn resolveConflict(self: *JobRunner, action: ConflictAction) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.state == .waiting_conflict) {
            self.conflict_action = action;
            _ = c.pthread_cond_signal(&self.cond);
        }
    }

    pub fn pollProgress(self: *JobRunner) ProgressInfo {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        return .{
            .state = self.state,
            .total_items = self.total_items,
            .processed_items = self.processed_items,
            .success_count = self.success_count,
            .skipped_count = self.skipped_count,
            .failed_count = self.failed_count,
            .current_name = self.current_item_name,
            .conflict_item_name = self.conflict_item_name,
            .status_message = self.status_message,
            .is_error = self.is_error,
            .cancelled = self.cancel_flag.load(.acquire),
        };
    }

    /// Only finished jobs expose results, so their source strings remain stable.
    pub fn movedSuccessfully(self: *JobRunner, path: []const u8) bool {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.state != .finished or self.kind != .move) return false;
        for (self.sources.items, self.outcomes.items) |src, outcome| {
            if (outcome == .success and std.mem.eql(u8, src, path)) return true;
        }
        return false;
    }

    fn transfer(self: *JobRunner, src: []const u8) !ItemOutcome {
        const name = std.fs.path.basename(src);
        var target = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dest_dir, name });
        defer self.allocator.free(target);
        var buf: [4096]u8 = undefined;
        const target_z = try std.fmt.bufPrintZ(&buf, "{s}", .{target});
        var st: c.struct_stat = undefined;
        if (c.lstat(target_z, &st) == 0) {
            var action = self.default_conflict;
            if (action == .ask) {
                _ = c.pthread_mutex_lock(&self.mutex);
                self.state = .waiting_conflict;
                self.conflict_item_name = name;
                self.conflict_action = null;
                self.notify();
                while (self.conflict_action == null and !self.cancel_flag.load(.acquire)) {
                    _ = c.pthread_cond_wait(&self.cond, &self.mutex);
                }
                action = self.conflict_action orelse .cancel;
                self.state = .running;
                self.notify();
                _ = c.pthread_mutex_unlock(&self.mutex);
            }
            switch (action) {
                .ask, .cancel => {
                    self.cancel_flag.store(true, .release);
                    return .cancelled;
                },
                .skip => return .skipped,
                .rename => {
                    const unique = try generateUniqueName(self.allocator, self.dest_dir, name);
                    defer self.allocator.free(unique);
                    const replacement = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dest_dir, unique });
                    self.allocator.free(target);
                    target = replacement;
                },
            }
        }
        if (self.cancel_flag.load(.acquire)) return .cancelled;
        if (isDescendantOrSame(src, target)) return error.CannotCopyIntoDescendant;
        if (self.kind == .copy) {
            try copyRecursive(self.allocator, src, target, &self.cancel_flag);
        } else {
            try moveItem(self.allocator, src, target, &self.cancel_flag);
        }
        return .success;
    }

    fn extractArchive(self: *JobRunner, source: []const u8) !ItemOutcome {
        const stage = try archive.temporary(self.allocator, self.dest_dir);
        var retained = false;
        defer if (!retained) {
            deleteRecursive(self.allocator, stage) catch {};
            self.allocator.free(stage);
        };
        try archive.extract(self.allocator, source, stage, self.member, &self.cancel_flag);
        if (self.member) |member| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ stage, member });
            errdefer self.allocator.free(path);
            try self.temporary_dirs.append(self.allocator, stage);
            retained = true;
            self.result_path = path;
            return .success;
        }
        const zstage = try self.allocator.dupeZ(u8, stage);
        defer self.allocator.free(zstage);
        const dir = c.opendir(zstage) orelse return error.OpenDirectoryFailed;
        defer _ = c.closedir(dir);
        var skipped = false;
        while (true) {
            std.c._errno().* = 0;
            const entry = c.readdir(dir) orelse {
                if (std.c._errno().* != 0) return error.ReadDirectoryFailed;
                break;
            };
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ stage, name });
            defer self.allocator.free(path);
            switch (try self.transfer(path)) {
                .cancelled => return .cancelled,
                .skipped => skipped = true,
                .failed => return .failed,
                .success => {},
            }
        }
        return if (skipped) .skipped else .success;
    }

    fn workerThread(self: *JobRunner) void {
        for (self.sources.items, 0..) |src, idx| {
            if (self.cancel_flag.load(.acquire)) break;
            _ = c.pthread_mutex_lock(&self.mutex);
            self.current_item_name = std.fs.path.basename(src);
            self.notify();
            _ = c.pthread_mutex_unlock(&self.mutex);
            const outcome = (if (self.kind == .extract or self.kind == .open_archive_member) self.extractArchive(src) else self.transfer(src)) catch |err| blk: {
                if (self.kind == .extract or self.kind == .open_archive_member) {
                    _ = c.pthread_mutex_lock(&self.mutex);
                    self.status_message = self.allocator.dupe(u8, archive.message(err)) catch "";
                    _ = c.pthread_mutex_unlock(&self.mutex);
                }
                break :blk if (err == error.Cancelled) ItemOutcome.cancelled else ItemOutcome.failed;
            };
            _ = c.pthread_mutex_lock(&self.mutex);
            self.outcomes.items[idx] = outcome;
            switch (outcome) {
                .success => self.success_count += 1,
                .skipped => self.skipped_count += 1,
                .failed => self.failed_count += 1,
                .cancelled => self.cancel_flag.store(true, .release),
            }
            if (outcome != .cancelled) self.processed_items += 1;
            self.notify();
            _ = c.pthread_mutex_unlock(&self.mutex);
            if (outcome == .cancelled) break;
        }
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const cancelled = self.cancel_flag.load(.acquire);
        if (self.status_message.len == 0) self.status_message = std.fmt.allocPrint(self.allocator, "{s}{d} {s}, {d} skipped, {d} failed, {d} remaining", .{
            if (cancelled) @as([]const u8, "Cancelled: ") else "",
            self.success_count,
            if (self.kind == .extract or self.kind == .open_archive_member) @as([]const u8, "extracted") else "transferred",
            self.skipped_count,
            self.failed_count,
            self.total_items - self.processed_items,
        }) catch "";
        self.is_error = cancelled or self.failed_count > 0;
        self.state = .finished;
        self.notify();
    }
};
