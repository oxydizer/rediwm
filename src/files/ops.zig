const std = @import("std");
const platform = @import("platform");
const i18n = @import("i18n");
const tr = i18n.tr;
const archive = @import("archive.zig");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

const max_progress_path_bytes = 4096;

pub const ConflictAction = enum {
    ask,
    skip,
    rename,
    cancel,
};

pub const JobState = enum {
    idle,
    running,
    paused,
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
    kind: OpKind = .copy,
    total_items: usize = 0,
    processed_items: usize = 0,
    total_bytes: u64 = 0,
    transferred_bytes: u64 = 0,
    total_bytes_known: bool = false,
    measuring: bool = false,
    success_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,
    current_name: []const u8 = "",
    current_file_path: [max_progress_path_bytes]u8 = undefined,
    current_file_path_len: usize = 0,
    current_file_bytes: u64 = 0,
    current_file_size: u64 = 0,
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

    const old_z = try allocator.dupeSentinel(u8, old_path, 0);
    defer allocator.free(old_z);

    platform.fs.renameNoReplace(old_z, new_path) catch |err| return switch (err) {
        error.PathAlreadyExists => error.PathAlreadyExists,
        error.AccessDenied => error.AccessDenied,
        else => error.RenameFailed,
    };
}

/// rm removes directory trees without following symlinks; -- protects option-like names.
pub fn deleteItems(io: std.Io, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(std.heap.c_allocator);
    // GNU rm takes `--interactive=never`; FreeBSD's rm only has `-f`.
    const never_prompt = if (@import("builtin").os.tag == .linux) "--interactive=never" else "-f";
    try args.appendSlice(std.heap.c_allocator, &.{ "rm", "-r", never_prompt, "--" });
    try args.appendSlice(std.heap.c_allocator, paths);
    var child = try std.process.spawn(io, .{ .argv = args.items });
    const result = try child.wait(io);
    if (result != .exited or result.exited != 0) return error.DeleteFailed;
}

/// Let GIO remove both trashed contents and their restore metadata.
pub fn emptyTrash(io: std.Io) !void {
    var child = std.process.spawn(io, .{ .argv = &.{ "gio", "trash", "--empty" } }) catch |err| {
        if (err == error.FileNotFound) return error.GioNotAvailable;
        return error.TrashFailed;
    };
    const result = try child.wait(io);
    if (result != .exited or result.exited != 0) return error.TrashFailed;
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
    const src_z = std.fmt.bufPrintSentinel(&src_buf, "{s}", .{src}, 0) catch return false;
    const dst_z = std.fmt.bufPrintSentinel(&dst_buf, "{s}", .{dst}, 0) catch return false;

    var src_st: c.struct_stat = undefined;
    var dst_st: c.struct_stat = undefined;
    if (c.stat(src_z, &src_st) != 0 or c.stat(dst_z, &dst_st) != 0) return false;

    if ((src_st.st_mode & c.S_IFMT) != c.S_IFDIR) return false;
    if (src_st.st_dev == dst_st.st_dev and src_st.st_ino == dst_st.st_ino) return true;

    var cur: []const u8 = dst;
    while (std.fs.path.dirname(cur)) |p| {
        if (std.mem.eql(u8, p, cur)) break;
        var p_buf: [4096]u8 = undefined;
        const p_z = std.fmt.bufPrintSentinel(&p_buf, "{s}", .{p}, 0) catch break;
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
    const initial_z = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dest_dir, original_name }, 0);
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
        const cand_z = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dest_dir, candidate }, 0) catch {
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

/// Measures regular-file payload bytes without following symlinks.
/// Runs on the job worker, never on the UI thread.
fn measureBytes(
    allocator: Allocator,
    path: []const u8,
    cancel: ?*std.atomic.Value(bool),
    runner: ?*JobRunner,
) !u64 {
    if (runner) |job| if (!job.waitIfResumed(cancel)) return error.Cancelled;
    if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;

    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    var st: c.struct_stat = undefined;
    if (c.lstat(path_z, &st) != 0) return error.StatFailed;

    const fmt = st.st_mode & c.S_IFMT;
    if (fmt == c.S_IFLNK) return 0;
    if (fmt == c.S_IFREG) {
        if (st.st_size < 0) return error.InvalidFileSize;
        return @intCast(st.st_size);
    }
    if (fmt != c.S_IFDIR) return error.UnsupportedFileType;

    const dir = c.opendir(path_z) orelse return error.OpenDirectoryFailed;
    defer _ = c.closedir(dir);

    var total: u64 = 0;
    while (true) {
        if (runner) |job| if (!job.waitIfResumed(cancel)) return error.Cancelled;
        if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;

        std.c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (std.c._errno().* != 0) return error.ReadDirectoryFailed;
            break;
        };
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(child);
        const child_bytes = try measureBytes(allocator, child, cancel, runner);
        if (child_bytes > std.math.maxInt(u64) - total) return error.SizeOverflow;
        total += child_bytes;
    }
    return total;
}

pub fn copyFileContents(allocator: Allocator, src_path: []const u8, dst_path: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    return copyFileContentsTracked(allocator, src_path, dst_path, cancel, null);
}

fn copyFileContentsTracked(
    allocator: Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    cancel: ?*std.atomic.Value(bool),
    runner: ?*JobRunner,
) !void {
    const src_z = try allocator.dupeSentinel(u8, src_path, 0);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeSentinel(u8, dst_path, 0);
    defer allocator.free(dst_z);

    const src_fd = c.open(src_z, c.O_RDONLY | c.O_CLOEXEC);
    if (src_fd < 0) return error.OpenSourceFailed;
    defer _ = c.close(src_fd);

    var stat: c.struct_stat = undefined;
    if (c.fstat(src_fd, &stat) != 0) return error.StatFailed;
    if (stat.st_size < 0) return error.InvalidFileSize;

    const mode = @as(c_uint, @intCast(stat.st_mode & 0o7777));
    const dst_fd = c.open(dst_z, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, mode);
    if (dst_fd < 0) return error.OpenDestFailed;
    defer _ = c.close(dst_fd);

    if (runner) |job| job.beginFileProgress(dst_path, @intCast(stat.st_size));

    var buf: [65536]u8 = undefined;
    while (true) {
        if (runner) |job| if (!job.waitIfResumed(cancel)) {
            _ = c.unlink(dst_z);
            return error.Cancelled;
        };
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
        var chunk_written: u64 = 0;
        const total = @as(usize, @intCast(n));
        while (written < total) {
            const wn = c.write(dst_fd, buf[written..].ptr, total - written);
            if (wn < 0 and std.posix.errno(wn) == .INTR) continue;
            if (wn <= 0) {
                if (runner) |job| job.addFileTransferredBytes(chunk_written);
                _ = c.unlink(dst_z);
                return error.WriteFailed;
            }
            const count: usize = @intCast(wn);
            written += count;
            chunk_written += count;
        }
        if (runner) |job| job.addFileTransferredBytes(chunk_written);
    }
}

pub fn copySymlink(allocator: Allocator, src_path: []const u8, dst_path: []const u8) !void {
    const src_z = try allocator.dupeSentinel(u8, src_path, 0);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeSentinel(u8, dst_path, 0);
    defer allocator.free(dst_z);

    var target_buf: [4096]u8 = undefined;
    const len = c.readlink(src_z, &target_buf, target_buf.len - 1);
    if (len < 0) return error.ReadlinkFailed;
    target_buf[@intCast(len)] = 0;

    if (c.symlink(&target_buf, dst_z) != 0) return error.SymlinkFailed;
}

pub fn copyRecursive(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    return copyRecursiveTracked(allocator, src, dst, cancel, null);
}

fn copyRecursiveTracked(
    allocator: Allocator,
    src: []const u8,
    dst: []const u8,
    cancel: ?*std.atomic.Value(bool),
    runner: ?*JobRunner,
) !void {
    if (runner) |job| if (!job.waitIfResumed(cancel)) return error.Cancelled;
    if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;

    const src_z = try allocator.dupeSentinel(u8, src, 0);
    defer allocator.free(src_z);

    var st: c.struct_stat = undefined;
    if (c.lstat(src_z, &st) != 0) return error.StatFailed;

    const fmt = st.st_mode & c.S_IFMT;
    if (fmt == c.S_IFLNK) {
        return copySymlink(allocator, src, dst);
    } else if (fmt == c.S_IFDIR) {
        const dst_z = try allocator.dupeSentinel(u8, dst, 0);
        defer allocator.free(dst_z);

        if (c.mkdir(dst_z, @intCast(st.st_mode & 0o7777)) != 0) return error.CreateDirectoryFailed;
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

            try copyRecursiveTracked(allocator, child_src, child_dst, cancel, runner);
        }
    } else if (fmt == c.S_IFREG) {
        return copyFileContentsTracked(allocator, src, dst, cancel, runner);
    } else return error.UnsupportedFileType;
}

pub fn deleteRecursive(allocator: Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
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
    return crossDeviceMoveTracked(allocator, src, dst, cancel, null);
}

fn crossDeviceMoveTracked(
    allocator: Allocator,
    src: []const u8,
    dst: []const u8,
    cancel: ?*std.atomic.Value(bool),
    runner: ?*JobRunner,
) !void {
    if (isDescendantOrSame(src, dst)) return error.CannotMoveIntoDescendant;

    // Copy cleans up only destinations it created; a raced existing target is preserved.
    try copyRecursiveTracked(allocator, src, dst, cancel, runner);
    if (runner) |job| if (!job.waitIfResumed(cancel)) {
        deleteRecursive(allocator, dst) catch {};
        return error.Cancelled;
    };
    if (cancel != null and cancel.?.load(.acquire)) {
        deleteRecursive(allocator, dst) catch {};
        return error.Cancelled;
    }

    // Step 2: Copy succeeded 100%, now remove src.
    try deleteRecursive(allocator, src);
}

pub fn moveItem(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    return moveItemTracked(allocator, src, dst, cancel, null, 0);
}

fn moveItemTracked(
    allocator: Allocator,
    src: []const u8,
    dst: []const u8,
    cancel: ?*std.atomic.Value(bool),
    runner: ?*JobRunner,
    source_bytes: u64,
) !void {
    if (runner) |job| if (!job.waitIfResumed(cancel)) return error.Cancelled;
    if (isDescendantOrSame(src, dst)) return error.CannotMoveIntoDescendant;
    if (std.mem.eql(u8, src, dst)) return;

    const src_z = try allocator.dupeSentinel(u8, src, 0);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeSentinel(u8, dst, 0);
    defer allocator.free(dst_z);

    platform.fs.renameNoReplace(src_z, dst_z) catch |err| switch (err) {
        error.PathAlreadyExists => return error.PathAlreadyExists,
        error.CrossDevice => return crossDeviceMoveTracked(allocator, src, dst, cancel, runner),
        else => return error.RenameFailed,
    };
    if (runner) |job| job.addTransferredBytes(source_bytes);
}

pub const JobRunner = struct {
    allocator: Allocator,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    wake_fd: c_int = -1,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    pause_requested: bool = false,

    // Protected by mutex
    state: JobState = .idle,
    kind: OpKind = .copy,
    sources: std.ArrayList([]const u8) = .empty,
    outcomes: std.ArrayList(ItemOutcome) = .empty,
    destination_paths: std.ArrayList([]u8) = .empty,
    dest_dir: []u8 = &[_]u8{},
    member: ?[]u8 = null,
    result_path: ?[]u8 = null,
    temporary_dirs: std.ArrayList([]u8) = .empty,
    default_conflict: ConflictAction = .ask,

    total_items: usize = 0,
    processed_items: usize = 0,
    item_bytes: std.ArrayList(u64) = .empty,
    item_transferred_bytes: std.ArrayList(u64) = .empty,
    current_item_index: usize = std.math.maxInt(usize),
    total_bytes: u64 = 0,
    transferred_bytes: u64 = 0,
    total_bytes_known: bool = false,
    measuring: bool = false,
    success_count: usize = 0,
    skipped_count: usize = 0,
    failed_count: usize = 0,

    current_item_name: []const u8 = &[_]u8{},
    current_file_path: [max_progress_path_bytes]u8 = undefined,
    current_file_path_len: usize = 0,
    current_file_bytes: u64 = 0,
    current_file_size: u64 = 0,
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
        for (self.destination_paths.items) |path| {
            if (path.len > 0) self.allocator.free(path);
        }
        self.destination_paths.deinit(self.allocator);
        self.outcomes.deinit(self.allocator);
        self.item_bytes.deinit(self.allocator);
        self.item_transferred_bytes.deinit(self.allocator);

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
        if (progress.state == .running or progress.state == .paused or progress.state == .waiting_conflict) return error.Busy;
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
        for (self.destination_paths.items) |path| {
            if (path.len > 0) self.allocator.free(path);
        }
        self.destination_paths.clearRetainingCapacity();

        for (sources) |src| {
            const owned = try self.allocator.dupe(u8, src);
            errdefer self.allocator.free(owned);
            try self.sources.append(self.allocator, owned);
        }
        self.outcomes.clearRetainingCapacity();
        try self.outcomes.appendNTimes(self.allocator, .cancelled, sources.len);
        try self.destination_paths.appendNTimes(self.allocator, &.{}, sources.len);
        self.item_bytes.clearRetainingCapacity();
        try self.item_bytes.appendNTimes(self.allocator, 0, sources.len);
        self.item_transferred_bytes.clearRetainingCapacity();
        try self.item_transferred_bytes.appendNTimes(self.allocator, 0, sources.len);
        self.current_item_index = std.math.maxInt(usize);
        self.dest_dir = try self.allocator.dupe(u8, dest_dir);
        if (member) |name| self.member = try self.allocator.dupe(u8, name);
        self.kind = kind;
        self.default_conflict = default_conflict;
        self.state = .running;
        self.cancel_flag.store(false, .release);
        self.pause_requested = false;

        self.total_items = self.sources.items.len;
        self.processed_items = 0;
        self.total_bytes = 0;
        self.transferred_bytes = 0;
        self.total_bytes_known = false;
        self.measuring = kind == .copy or kind == .move;
        self.success_count = 0;
        self.skipped_count = 0;
        self.failed_count = 0;
        self.current_file_path_len = 0;
        self.current_file_bytes = 0;
        self.current_file_size = 0;
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
        self.pause_requested = false;
        if (self.state == .waiting_conflict) {
            self.conflict_action = .cancel;
        }
        _ = c.pthread_cond_broadcast(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// Request a cooperative pause. The worker acknowledges it at its next
    /// safe point, after the current file chunk or directory entry.
    pub fn pause(self: *JobRunner) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        if (self.state == .running and (self.kind == .copy or self.kind == .move)) {
            self.pause_requested = true;
            self.notify();
        }
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn resumeJob(self: *JobRunner) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        if (self.state == .paused) {
            self.pause_requested = false;
            self.state = .running;
            _ = c.pthread_cond_broadcast(&self.cond);
            self.notify();
        }
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// Called only by the worker. A paused state means the worker has reached
    /// a safe point and is no longer doing filesystem work.
    fn waitIfResumed(self: *JobRunner, cancel_flag: ?*std.atomic.Value(bool)) bool {
        _ = c.pthread_mutex_lock(&self.mutex);
        while (self.pause_requested and (cancel_flag == null or !cancel_flag.?.load(.acquire))) {
            if (self.state != .paused) {
                self.state = .paused;
                self.notify();
            }
            _ = c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        const should_continue = cancel_flag == null or !cancel_flag.?.load(.acquire);
        _ = c.pthread_mutex_unlock(&self.mutex);
        return should_continue;
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

        var progress: ProgressInfo = .{
            .state = self.state,
            .kind = self.kind,
            .total_items = self.total_items,
            .processed_items = self.processed_items,
            .total_bytes = self.total_bytes,
            .transferred_bytes = self.transferred_bytes,
            .total_bytes_known = self.total_bytes_known,
            .measuring = self.measuring,
            .success_count = self.success_count,
            .skipped_count = self.skipped_count,
            .failed_count = self.failed_count,
            .current_name = self.current_item_name,
            .current_file_bytes = self.current_file_bytes,
            .current_file_size = self.current_file_size,
            .conflict_item_name = self.conflict_item_name,
            .status_message = self.status_message,
            .is_error = self.is_error,
            .cancelled = self.cancel_flag.load(.acquire),
        };
        if (self.current_file_path_len > 0) {
            progress.current_file_path_len = self.current_file_path_len;
            @memcpy(
                progress.current_file_path[0..self.current_file_path_len],
                self.current_file_path[0..self.current_file_path_len],
            );
        }
        return progress;
    }

    fn addTransferredBytes(self: *JobRunner, bytes: u64) void {
        self.addTransferredBytesImpl(bytes, false);
    }

    fn addFileTransferredBytes(self: *JobRunner, bytes: u64) void {
        self.addTransferredBytesImpl(bytes, true);
    }

    fn addTransferredBytesImpl(self: *JobRunner, bytes: u64, file_progress: bool) void {
        if (bytes == 0) return;
        _ = c.pthread_mutex_lock(&self.mutex);
        if (bytes > std.math.maxInt(u64) - self.transferred_bytes) {
            self.transferred_bytes = std.math.maxInt(u64);
        } else {
            self.transferred_bytes += bytes;
        }
        if (self.current_item_index < self.item_transferred_bytes.items.len) {
            const item_bytes = &self.item_transferred_bytes.items[self.current_item_index];
            if (bytes > std.math.maxInt(u64) - item_bytes.*) {
                item_bytes.* = std.math.maxInt(u64);
            } else {
                item_bytes.* += bytes;
            }
        }
        if (file_progress and self.current_file_path_len > 0) {
            if (bytes > std.math.maxInt(u64) - self.current_file_bytes) {
                self.current_file_bytes = std.math.maxInt(u64);
            } else {
                self.current_file_bytes += bytes;
            }
        }
        self.notify();
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn beginFileProgress(self: *JobRunner, path: []const u8, size: u64) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.current_file_path_len = 0;
        self.current_file_bytes = 0;
        self.current_file_size = size;
        if (path.len <= self.current_file_path.len) {
            @memcpy(self.current_file_path[0..path.len], path);
            self.current_file_path_len = path.len;
        }
        self.notify();
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    /// Returns the visible progress for a top-level copy/move item.
    /// Completed, skipped and failed outcomes remain visible until the job ends.
    pub fn progressForPath(self: *JobRunner, path: []const u8) ?f64 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.state == .idle or self.state == .finished or
            (self.kind != .copy and self.kind != .move)) return null;

        for (self.sources.items, 0..) |source, idx| {
            const source_match = std.mem.eql(u8, source, path);
            const destination_match = idx < self.destination_paths.items.len and
                self.destination_paths.items[idx].len > 0 and
                std.mem.eql(u8, self.destination_paths.items[idx], path);
            if (!source_match and !destination_match) continue;

            if (idx == self.current_item_index) {
                const total = self.item_bytes.items[idx];
                if (total == 0) return 0;
                return @min(1, @as(f64, @floatFromInt(self.item_transferred_bytes.items[idx])) /
                    @as(f64, @floatFromInt(total)));
            }

            return switch (self.outcomes.items[idx]) {
                .success => 1,
                .skipped, .failed => 0,
                .cancelled => null,
            };
        }
        return null;
    }

    /// Resolves a batch of visible paths under one lock and one source-list
    /// traversal. `matched` distinguishes paths with a cancelled outcome
    /// from paths that do not belong to this job.
    pub fn progressForPaths(
        self: *JobRunner,
        paths: []const []const u8,
        results: []?f64,
        matched: []bool,
    ) void {
        std.debug.assert(paths.len == results.len and paths.len == matched.len);
        @memset(results, null);
        @memset(matched, false);

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.state == .idle or self.state == .finished or
            (self.kind != .copy and self.kind != .move)) return;

        for (self.sources.items, 0..) |source, source_idx| {
            const destination = if (source_idx < self.destination_paths.items.len)
                self.destination_paths.items[source_idx]
            else
                &[_]u8{};

            for (paths, 0..) |path, path_idx| {
                if (matched[path_idx]) continue;
                if (!std.mem.eql(u8, source, path) and
                    (destination.len == 0 or !std.mem.eql(u8, destination, path))) continue;

                matched[path_idx] = true;
                if (source_idx == self.current_item_index) {
                    const total = self.item_bytes.items[source_idx];
                    results[path_idx] = if (total == 0)
                        0
                    else
                        @min(1, @as(f64, @floatFromInt(self.item_transferred_bytes.items[source_idx])) /
                            @as(f64, @floatFromInt(total)));
                } else {
                    results[path_idx] = switch (self.outcomes.items[source_idx]) {
                        .success => 1,
                        .skipped, .failed => 0,
                        .cancelled => null,
                    };
                }
            }
        }
    }

    fn recordDestinationPath(self: *JobRunner, path: []const u8) !void {
        const owned = try self.allocator.alloc(u8, path.len);
        errdefer self.allocator.free(owned);
        @memcpy(owned, path);

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.current_item_index >= self.destination_paths.items.len) return;
        const slot = &self.destination_paths.items[self.current_item_index];
        if (slot.len > 0) self.allocator.free(slot.*);
        slot.* = owned;
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

    fn transfer(self: *JobRunner, src: []const u8, source_bytes: u64) !ItemOutcome {
        const name = std.fs.path.basename(src);
        var target = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dest_dir, name });
        defer self.allocator.free(target);
        try self.recordDestinationPath(target);
        var buf: [4096]u8 = undefined;
        const target_z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{target}, 0);
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
                    try self.recordDestinationPath(target);
                },
            }
        }
        if (self.cancel_flag.load(.acquire)) return .cancelled;
        if (isDescendantOrSame(src, target)) return error.CannotCopyIntoDescendant;
        if (self.kind == .copy) {
            try copyRecursiveTracked(self.allocator, src, target, &self.cancel_flag, self);
        } else {
            try moveItemTracked(self.allocator, src, target, &self.cancel_flag, self, source_bytes);
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
        const zstage = try self.allocator.dupeSentinel(u8, stage, 0);
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
            switch (try self.transfer(path, 0)) {
                .cancelled => return .cancelled,
                .skipped => skipped = true,
                .failed => return .failed,
                .success => {},
            }
        }
        return if (skipped) .skipped else .success;
    }

    fn workerThread(self: *JobRunner) void {
        if (self.kind == .copy or self.kind == .move) {
            var total: u64 = 0;
            var known = true;
            for (self.sources.items, 0..) |src, idx| {
                if (self.cancel_flag.load(.acquire)) {
                    known = false;
                    break;
                }
                const bytes = measureBytes(self.allocator, src, &self.cancel_flag, self) catch {
                    known = false;
                    break;
                };
                self.item_bytes.items[idx] = bytes;
                if (bytes > std.math.maxInt(u64) - total) {
                    known = false;
                    break;
                }
                total += bytes;
            }
            _ = c.pthread_mutex_lock(&self.mutex);
            self.total_bytes = total;
            self.total_bytes_known = known;
            self.measuring = false;
            self.notify();
            _ = c.pthread_mutex_unlock(&self.mutex);
        }

        for (self.sources.items, 0..) |src, idx| {
            if (self.cancel_flag.load(.acquire)) break;
            _ = c.pthread_mutex_lock(&self.mutex);
            self.current_item_name = std.fs.path.basename(src);
            self.current_item_index = idx;
            self.notify();
            _ = c.pthread_mutex_unlock(&self.mutex);
            const outcome = (if (self.kind == .extract or self.kind == .open_archive_member) self.extractArchive(src) else self.transfer(src, self.item_bytes.items[idx])) catch |err| blk: {
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
        if (self.status_message.len == 0) {
            const extracting = self.kind == .extract or self.kind == .open_archive_member;
            const pattern = if (cancelled)
                (if (extracting) tr("Cancelled. Extracted: {completed}. Skipped: {skipped}. Failed: {failed}. Remaining: {remaining}.") else tr("Cancelled. Transferred: {completed}. Skipped: {skipped}. Failed: {failed}. Remaining: {remaining}."))
            else
                (if (extracting) tr("Extracted: {completed}. Skipped: {skipped}. Failed: {failed}. Remaining: {remaining}.") else tr("Transferred: {completed}. Skipped: {skipped}. Failed: {failed}. Remaining: {remaining}."));
            self.status_message = i18n.allocPrint(self.allocator, pattern, .{
                .completed = self.success_count,
                .skipped = self.skipped_count,
                .failed = self.failed_count,
                .remaining = self.total_items - self.processed_items,
            }) catch "";
        }
        self.is_error = cancelled or self.failed_count > 0;
        self.current_file_path_len = 0;
        self.current_file_bytes = 0;
        self.current_file_size = 0;
        self.state = .finished;
        self.notify();
    }
};
