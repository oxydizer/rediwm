//! Plain filesystem helpers for Files: names, creation, deletion, trash and
//! moves. Transfers themselves run in the I/O service.

const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const platform = @import("platform");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

const copy_buffer_size = 64 * 1024;

/// What the window shows for its own (archive) job.
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
};

pub const TransferEntryKind = enum {
    file,
    directory,
    symlink,
};

pub const TransferEntryState = enum {
    pending,
    copying,
    completed,
    skipped,
    failed,
    cancelled,
};

pub const TransferEntry = struct {
    source_path: []u8,
    relative_path: []u8,
    destination_path: ?[]u8 = null,
    size: u64 = 0,
    kind: TransferEntryKind,
    state: TransferEntryState = .pending,
    root_index: usize,
};

/// Owns the paths and entries describing one logical transfer.
/// Used by the transfer tree projection; it holds no locks of its own.
pub const TransferManifest = struct {
    allocator: Allocator,
    entries: std.ArrayList(TransferEntry) = .empty,

    pub fn init(allocator: Allocator) TransferManifest {
        return .{ .allocator = allocator };
    }

    pub fn append(
        self: *TransferManifest,
        source_path: []const u8,
        relative_path: []const u8,
        destination_path: ?[]const u8,
        size: u64,
        kind: TransferEntryKind,
        root_index: usize,
    ) !void {
        const owned_source = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(owned_source);

        const owned_relative = try self.allocator.dupe(u8, relative_path);
        errdefer self.allocator.free(owned_relative);

        const owned_destination = if (destination_path) |path|
            try self.allocator.dupe(u8, path)
        else
            null;
        errdefer if (owned_destination) |path| self.allocator.free(path);

        try self.entries.append(self.allocator, .{
            .source_path = owned_source,
            .relative_path = owned_relative,
            .destination_path = owned_destination,
            .size = size,
            .kind = kind,
            .root_index = root_index,
        });
    }

    pub fn clearRetainingCapacity(self: *TransferManifest) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.source_path);
            self.allocator.free(entry.relative_path);
            if (entry.destination_path) |path| self.allocator.free(path);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *TransferManifest) void {
        self.clearRetainingCapacity();
        self.entries.deinit(self.allocator);
    }
};

pub fn validateFilename(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidCharacter;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidCharacter;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.ReservedName;
}

pub fn createFolder(allocator: Allocator, dir: []const u8, name: []const u8) !void {
    io_thread_guard.blocking("ops.createFolder");
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
    io_thread_guard.blocking("ops.createFile");
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
    io_thread_guard.blocking("ops.renameItem");
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
    io_thread_guard.blocking("ops.deleteItems");
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
    io_thread_guard.blocking("ops.emptyTrash");
    var child = std.process.spawn(io, .{ .argv = &.{ "gio", "trash", "--empty" } }) catch |err| {
        if (err == error.FileNotFound) return error.GioNotAvailable;
        return error.TrashFailed;
    };
    const result = try child.wait(io);
    if (result != .exited or result.exited != 0) return error.TrashFailed;
}

pub fn trashItems(io: std.Io, paths: []const []const u8) !void {
    io_thread_guard.blocking("ops.trashItems");
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
    io_thread_guard.blocking("ops.generateUniqueName");
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

fn cancelled(cancel: ?*std.atomic.Value(bool)) bool {
    return cancel != null and cancel.?.load(.acquire);
}

/// Copies one regular file into a new destination. A failed or cancelled
/// copy removes the partial destination it created.
pub fn copyFileContents(allocator: Allocator, src_path: []const u8, dst_path: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
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
    errdefer _ = c.unlink(dst_z);

    const buf = try allocator.alloc(u8, copy_buffer_size);
    defer allocator.free(buf);
    while (true) {
        if (cancelled(cancel)) return error.Cancelled;
        const n = c.read(src_fd, buf.ptr, buf.len);
        if (n == 0) break;
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return error.ReadFailed;
        const total: usize = @intCast(n);
        var written: usize = 0;
        while (written < total) {
            const wn = c.write(dst_fd, buf[written..].ptr, total - written);
            if (wn < 0 and std.posix.errno(wn) == .INTR) continue;
            if (wn <= 0) return error.WriteFailed;
            written += @intCast(wn);
        }
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

/// Copies a file, symlink or directory tree into a new destination. A failed
/// directory copy removes only the destination it created.
pub fn copyRecursive(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) anyerror!void {
    if (cancelled(cancel)) return error.Cancelled;
    const src_z = try allocator.dupeSentinel(u8, src, 0);
    defer allocator.free(src_z);

    var st: c.struct_stat = undefined;
    if (c.lstat(src_z, &st) != 0) return error.StatFailed;

    const fmt = st.st_mode & c.S_IFMT;
    if (fmt == c.S_IFLNK) return copySymlink(allocator, src, dst);
    if (fmt == c.S_IFREG) return copyFileContents(allocator, src, dst, cancel);
    if (fmt != c.S_IFDIR) return error.UnsupportedFileType;

    const dst_z = try allocator.dupeSentinel(u8, dst, 0);
    defer allocator.free(dst_z);
    if (c.mkdir(dst_z, @intCast(st.st_mode & 0o7777)) != 0) return error.CreateDirectoryFailed;
    errdefer deleteRecursive(allocator, dst) catch {};

    const dir_handle = c.opendir(src_z) orelse return error.OpenDirectoryFailed;
    defer _ = c.closedir(dir_handle);
    while (true) {
        std.c._errno().* = 0;
        const entry = c.readdir(dir_handle) orelse {
            if (std.c._errno().* != 0) return error.ReadDirectoryFailed;
            break;
        };
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src, name });
        defer allocator.free(child_src);
        const child_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, name });
        defer allocator.free(child_dst);
        try copyRecursive(allocator, child_src, child_dst, cancel);
    }
}

pub fn deleteRecursive(allocator: Allocator, path: []const u8) !void {
    io_thread_guard.blocking("ops.deleteRecursive");
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

/// Copies then removes the source. The source stays until the copy is whole.
pub fn crossDeviceMove(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    if (isDescendantOrSame(src, dst)) return error.CannotMoveIntoDescendant;
    // Copy cleans up only destinations it created; a raced existing target is preserved.
    try copyRecursive(allocator, src, dst, cancel);
    if (cancelled(cancel)) {
        deleteRecursive(allocator, dst) catch {};
        return error.Cancelled;
    }
    try deleteRecursive(allocator, src);
}

/// Renames without replacing, falling back to copy-and-delete across devices.
pub fn moveItem(allocator: Allocator, src: []const u8, dst: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
    io_thread_guard.blocking("ops.moveItem");
    if (isDescendantOrSame(src, dst)) return error.CannotMoveIntoDescendant;
    if (std.mem.eql(u8, src, dst)) return;

    const src_z = try allocator.dupeSentinel(u8, src, 0);
    defer allocator.free(src_z);
    const dst_z = try allocator.dupeSentinel(u8, dst, 0);
    defer allocator.free(dst_z);

    platform.fs.renameNoReplace(src_z, dst_z) catch |err| switch (err) {
        error.PathAlreadyExists => return error.PathAlreadyExists,
        error.CrossDevice => return crossDeviceMove(allocator, src, dst, cancel),
        else => return error.RenameFailed,
    };
}
