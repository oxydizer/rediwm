const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const i18n = @import("i18n");
const tr = i18n.tr;
const archive = @import("archive.zig");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

const max_progress_path_bytes = 4096;
pub const copy_buffer_size = 64 * 1024;
const max_copy_buffer_size = 1024 * 1024;

pub const CopyStrategy = enum {
    buffered,
    copy_file_range,
    reflink,

    pub fn name(self: CopyStrategy) []const u8 {
        return switch (self) {
            .buffered => "buffered",
            .copy_file_range => "copy_file_range",
            .reflink => "reflink",
        };
    }
};

pub const CopyMetrics = struct {
    reflink_calls: u64 = 0,
    reflink_bytes: u64 = 0,
    reflink_fallback_files: u64 = 0,
    copy_file_range_calls: u64 = 0,
    copy_file_range_bytes: u64 = 0,
    buffered_fallback_files: u64 = 0,
};

/// Worker-side profiling counters for one JobRunner job.
/// Timings and counters are collected only when profile_enabled is true.
pub const CopyProfile = struct {
    manifest_scan_ns: u64 = 0,
    destination_resolution_ns: u64 = 0,
    recursive_copy_ns: u64 = 0,
    data_transfer_ns: u64 = 0,
    lstat_calls: u64 = 0,
    fstat_calls: u64 = 0,
    opendir_calls: u64 = 0,
    directory_entries: u64 = 0,
    file_open_calls: u64 = 0,
    directory_create_calls: u64 = 0,
    path_allocations: u64 = 0,
    path_allocation_bytes: u64 = 0,
    manifest_lookup_comparisons: u64 = 0,
    mutex_lock_calls: u64 = 0,
};

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

pub const ConflictAction = enum {
    ask,
    skip,
    rename,
    cancel,
};

test "transfer manifest subtree and root outcome states remain isolated" {
    const a = std.testing.allocator;
    const runner = try JobRunner.init(a);
    defer runner.deinit();

    try runner.manifest.append("/tree", "", null, 0, .directory, 0);
    try runner.manifest.append("/tree/child", "child", null, 1, .file, 0);
    try runner.manifest.append("/treehouse/child", "child", null, 1, .file, 0);
    try runner.manifest.append("/tree/child", "child", null, 1, .file, 1);

    runner.setManifestSubtreeState(0, "/tree", .failed);
    try std.testing.expectEqual(TransferEntryState.failed, runner.manifest.entries.items[0].state);
    try std.testing.expectEqual(TransferEntryState.failed, runner.manifest.entries.items[1].state);
    try std.testing.expectEqual(TransferEntryState.pending, runner.manifest.entries.items[2].state);
    try std.testing.expectEqual(TransferEntryState.pending, runner.manifest.entries.items[3].state);

    runner.manifest.entries.items[0].state = .completed;
    runner.manifest.entries.items[1].state = .copying;
    runner.finishManifestRoot(0, .cancelled);
    try std.testing.expectEqual(TransferEntryState.completed, runner.manifest.entries.items[0].state);
    try std.testing.expectEqual(TransferEntryState.cancelled, runner.manifest.entries.items[1].state);
    try std.testing.expectEqual(TransferEntryState.cancelled, runner.manifest.entries.items[2].state);
    try std.testing.expectEqual(TransferEntryState.pending, runner.manifest.entries.items[3].state);

    runner.finishManifestRoot(1, .skipped);
    try std.testing.expectEqual(TransferEntryState.skipped, runner.manifest.entries.items[3].state);

    runner.finishManifestRoot(0, .success);
    try std.testing.expectEqual(TransferEntryState.completed, runner.manifest.entries.items[0].state);
    try std.testing.expectEqual(TransferEntryState.completed, runner.manifest.entries.items[1].state);
    try std.testing.expectEqual(TransferEntryState.completed, runner.manifest.entries.items[2].state);
}

test "JobRunner tracks current file bytes independently and resets on file changes" {
    const a = std.testing.allocator;
    const runner = try JobRunner.init(a);
    defer runner.deinit();

    runner.state = .running;
    runner.kind = .copy;
    runner.beginFileProgress("/destination/first.bin", 1024);

    var progress = runner.pollProgress();
    try std.testing.expectEqualStrings(
        "/destination/first.bin",
        progress.current_file_path[0..progress.current_file_path_len],
    );
    try std.testing.expectEqual(@as(u64, 0), progress.current_file_bytes);
    try std.testing.expectEqual(@as(u64, 1024), progress.current_file_size);

    runner.addFileTransferredBytes(256);
    progress = runner.pollProgress();
    try std.testing.expectEqual(@as(u64, 256), progress.current_file_bytes);
    try std.testing.expectEqual(@as(u64, 256), progress.transferred_bytes);

    runner.addFileTransferredBytes(128);
    progress = runner.pollProgress();
    try std.testing.expectEqual(@as(u64, 384), progress.current_file_bytes);
    try std.testing.expectEqual(@as(u64, 384), progress.transferred_bytes);

    // Starting the next file resets only its per-file counter.
    runner.beginFileProgress("/destination/second.bin", 64);
    progress = runner.pollProgress();
    try std.testing.expectEqualStrings(
        "/destination/second.bin",
        progress.current_file_path[0..progress.current_file_path_len],
    );
    try std.testing.expectEqual(@as(u64, 0), progress.current_file_bytes);
    try std.testing.expectEqual(@as(u64, 64), progress.current_file_size);
    try std.testing.expectEqual(@as(u64, 384), progress.transferred_bytes);

    runner.addFileTransferredBytes(64);
    progress = runner.pollProgress();
    try std.testing.expectEqual(@as(u64, 64), progress.current_file_bytes);
    try std.testing.expectEqual(@as(u64, 448), progress.transferred_bytes);
}

test "JobRunner saturates current file byte counters instead of overflowing" {
    const a = std.testing.allocator;
    const runner = try JobRunner.init(a);
    defer runner.deinit();

    runner.state = .running;
    runner.beginFileProgress("/destination/large.bin", std.math.maxInt(u64));

    runner.addFileTransferredBytes(std.math.maxInt(u64) - 10);
    runner.addFileTransferredBytes(20);

    const progress = runner.pollProgress();
    try std.testing.expectEqual(std.math.maxInt(u64), progress.current_file_bytes);
    try std.testing.expectEqual(std.math.maxInt(u64), progress.transferred_bytes);
}

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

const ManifestLookupEntry = struct {
    root_index: usize,
    source_path: []const u8,
    entry_index: usize,

    fn lessThan(_: void, lhs: ManifestLookupEntry, rhs: ManifestLookupEntry) bool {
        if (lhs.root_index != rhs.root_index) return lhs.root_index < rhs.root_index;
        const order = std.mem.order(u8, lhs.source_path, rhs.source_path);
        if (order != .eq) return order == .lt;
        return lhs.entry_index < rhs.entry_index;
    }
};

/// Owns the paths and entries describing one logical transfer.
/// Synchronization is provided by the owning JobRunner.
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

test "manifest lookup isolates roots and preserves first duplicate entry" {
    const a = std.testing.allocator;
    const runner = try JobRunner.init(a);
    defer runner.deinit();

    try runner.manifest.append("/same", "", null, 0, .file, 0);
    try runner.manifest.append("/same", "", null, 0, .file, 0);
    try runner.manifest.append("/same", "", null, 0, .file, 1);
    try runner.manifest.append("/same/child", "child", null, 0, .file, 0);

    _ = c.pthread_mutex_lock(&runner.mutex);
    const built = runner.rebuildManifestLookup();
    _ = c.pthread_mutex_unlock(&runner.mutex);
    try std.testing.expect(built);

    runner.setManifestEntryState(0, "/same", .copying);
    try std.testing.expectEqual(TransferEntryState.copying, runner.manifest.entries.items[0].state);
    try std.testing.expectEqual(TransferEntryState.pending, runner.manifest.entries.items[1].state);
    try std.testing.expectEqual(TransferEntryState.pending, runner.manifest.entries.items[2].state);

    runner.setManifestEntryState(1, "/same", .completed);
    try std.testing.expectEqual(TransferEntryState.completed, runner.manifest.entries.items[2].state);

    runner.setManifestEntryState(0, "/same/child", .failed);
    try std.testing.expectEqual(TransferEntryState.failed, runner.manifest.entries.items[3].state);

    runner.setManifestEntryState(0, "/missing", .failed);
    try std.testing.expectEqual(TransferEntryState.pending, runner.manifest.entries.items[1].state);
}

/// An independently owned, consistent view of a JobRunner's transfer manifest.
/// Its paths remain valid even after the live manifest is cleared or reused.
pub const TransferManifestSnapshot = struct {
    allocator: Allocator,
    entries: std.ArrayList(TransferEntry) = .empty,

    pub fn deinit(self: *TransferManifestSnapshot) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.source_path);
            self.allocator.free(entry.relative_path);
            if (entry.destination_path) |path| self.allocator.free(path);
        }
        self.entries.deinit(self.allocator);
    }
};

fn cloneTransferEntry(allocator: Allocator, entry: TransferEntry) !TransferEntry {
    const source_path = try allocator.dupe(u8, entry.source_path);
    errdefer allocator.free(source_path);

    const relative_path = try allocator.dupe(u8, entry.relative_path);
    errdefer allocator.free(relative_path);

    const destination_path = if (entry.destination_path) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (destination_path) |path| allocator.free(path);

    return .{
        .source_path = source_path,
        .relative_path = relative_path,
        .destination_path = destination_path,
        .size = entry.size,
        .kind = entry.kind,
        .state = entry.state,
        .root_index = entry.root_index,
    };
}

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
    root_index: usize,
    relative_path: []const u8,
) !u64 {
    if (runner) |job| if (!job.waitIfResumed(cancel)) return error.Cancelled;
    if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;

    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    if (runner) |job| job.profilePathAllocation(path.len);

    var st: c.struct_stat = undefined;
    if (runner) |job| job.profileCount(&job.profile_metrics.lstat_calls, 1);
    if (c.lstat(path_z, &st) != 0) return error.StatFailed;

    const fmt = st.st_mode & c.S_IFMT;
    const kind: TransferEntryKind = if (fmt == c.S_IFLNK)
        .symlink
    else if (fmt == c.S_IFREG)
        .file
    else if (fmt == c.S_IFDIR)
        .directory
    else
        return error.UnsupportedFileType;

    const size: u64 = if (kind == .file) blk: {
        if (st.st_size < 0) return error.InvalidFileSize;
        break :blk @intCast(st.st_size);
    } else 0;

    if (runner) |job| {
        job.profileCount(&job.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&job.mutex);
        defer _ = c.pthread_mutex_unlock(&job.mutex);
        job.profilePathAllocation(path.len);
        job.profilePathAllocation(relative_path.len);
        try job.manifest.append(path, relative_path, null, size, kind, root_index);
    }

    if (kind == .symlink or kind == .file) return size;

    if (runner) |job| job.profileCount(&job.profile_metrics.opendir_calls, 1);
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
        if (runner) |job| job.profileCount(&job.profile_metrics.directory_entries, 1);

        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(child);
        if (runner) |job| job.profilePathAllocation(child.len);
        const child_relative = if (relative_path.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_path, name });
        defer allocator.free(child_relative);
        if (runner) |job| job.profilePathAllocation(child_relative.len);
        const child_bytes = try measureBytes(allocator, child, cancel, runner, root_index, child_relative);
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
    if (runner) |job| {
        job.profilePathAllocation(src_path.len);
        job.profilePathAllocation(dst_path.len);
        job.profileCount(&job.profile_metrics.file_open_calls, 1);
    }

    const src_fd = c.open(src_z, c.O_RDONLY | c.O_CLOEXEC);
    if (src_fd < 0) return error.OpenSourceFailed;
    defer _ = c.close(src_fd);

    var stat: c.struct_stat = undefined;
    if (runner) |job| job.profileCount(&job.profile_metrics.fstat_calls, 1);
    if (c.fstat(src_fd, &stat) != 0) return error.StatFailed;
    if (stat.st_size < 0) return error.InvalidFileSize;

    const mode = @as(c_uint, @intCast(stat.st_mode & 0o7777));
    if (runner) |job| job.profileCount(&job.profile_metrics.file_open_calls, 1);
    const dst_fd = c.open(dst_z, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, mode);
    if (dst_fd < 0) return error.OpenDestFailed;
    defer _ = c.close(dst_fd);

    if (runner) |job| job.beginFileProgress(dst_path, @intCast(stat.st_size));

    var buf: [max_copy_buffer_size]u8 = undefined;
    const buffer_len = if (runner) |job| job.copy_buffer_bytes else copy_buffer_size;
    std.debug.assert(buffer_len > 0 and buffer_len <= buf.len);

    const transfer_started = if (runner) |job| job.profileStart() else 0;
    defer if (runner) |job| job.profileAddDuration(
        transfer_started,
        &job.profile_metrics.data_transfer_ns,
    );

    var use_buffered_copy = true;
    if (comptime builtin.os.tag == .linux) {
        if (runner) |job| {
            if (job.copy_strategy == .reflink) {
                if (!job.waitIfResumed(cancel) or
                    (cancel != null and cancel.?.load(.acquire)))
                {
                    _ = c.unlink(dst_z);
                    return error.Cancelled;
                }

                job.recordReflinkCall();
                // Linux FICLONE: _IOW(0x94, 9, int).
                const clone_result = c.ioctl(
                    dst_fd,
                    @as(c_ulong, 0x40049409),
                    src_fd,
                );
                if (clone_result == 0) {
                    const file_size: u64 = @intCast(stat.st_size);
                    job.recordReflinkBytes(file_size);
                    job.addFileTransferredBytes(file_size);
                    return;
                }

                const clone_errno = std.c._errno().*;
                // Unsupported filesystems and cross-filesystem clones can
                // still use the normal kernel or buffered copy paths.
                if (clone_errno == c.EXDEV or
                    clone_errno == c.EINVAL or
                    clone_errno == c.ENOSYS or
                    clone_errno == c.ENOTTY or
                    clone_errno == c.EOPNOTSUPP)
                {
                    job.recordReflinkFallback();
                } else {
                    _ = c.unlink(dst_z);
                    return error.CopyFailed;
                }
            }

            if (job.copy_strategy == .copy_file_range or
                job.copy_strategy == .reflink)
            {
                use_buffered_copy = false;
                while (true) {
                    if (!job.waitIfResumed(cancel)) {
                        _ = c.unlink(dst_z);
                        return error.Cancelled;
                    }
                    if (cancel != null and cancel.?.load(.acquire)) {
                        _ = c.unlink(dst_z);
                        return error.Cancelled;
                    }

                    const copied = c.copy_file_range(
                        src_fd,
                        null,
                        dst_fd,
                        null,
                        buffer_len,
                        0,
                    );
                    job.recordCopyFileRangeCall();
                    if (copied == 0) break;
                    if (copied > 0) {
                        job.recordCopyFileRangeBytes(@intCast(copied));
                        job.addFileTransferredBytes(@intCast(copied));
                        continue;
                    }

                    const copy_errno = std.c._errno().*;
                    if (copy_errno == c.EINTR) continue;

                    // Unsupported filesystems, cross-device copies, and
                    // unsupported kernel paths fall back at the current
                    // file offsets. Any bytes already copied remain valid.
                    if (copy_errno == c.EXDEV or
                        copy_errno == c.EINVAL or
                        copy_errno == c.ENOSYS or
                        copy_errno == c.EOPNOTSUPP or
                        copy_errno == c.EPERM)
                    {
                        job.recordBufferedFallback();
                        use_buffered_copy = true;
                        break;
                    }

                    _ = c.unlink(dst_z);
                    return error.CopyFailed;
                }
            }
        }
    }

    if (!use_buffered_copy) return;

    while (true) {
        if (runner) |job| if (!job.waitIfResumed(cancel)) {
            _ = c.unlink(dst_z);
            return error.Cancelled;
        };
        if (cancel != null and cancel.?.load(.acquire)) {
            _ = c.unlink(dst_z);
            return error.Cancelled;
        }
        const n = c.read(src_fd, buf[0..buffer_len].ptr, buffer_len);
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
    if (runner) |job| job.setManifestEntryState(job.current_item_index, src, .copying);
    copyRecursiveTrackedImpl(allocator, src, dst, cancel, runner) catch |err| {
        // Recursive directory cleanup runs before this catch. If the destination
        // is gone, the whole copied subtree was rolled back; if it remains,
        // cleanup failed and completed descendants may still exist.
        if (runner) |job| {
            if (!pathExists(allocator, dst)) {
                job.setManifestSubtreeState(
                    job.current_item_index,
                    src,
                    if (err == error.Cancelled) .cancelled else .failed,
                );
            }
        }
        return err;
    };
    if (runner) |job| job.setManifestEntryState(job.current_item_index, src, .completed);
}

fn pathExists(allocator: Allocator, path: []const u8) bool {
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return true;
    defer allocator.free(path_z);
    var st: c.struct_stat = undefined;
    if (c.lstat(path_z, &st) == 0) return true;
    return std.c._errno().* != c.ENOENT;
}

fn copyRecursiveTrackedImpl(
    allocator: Allocator,
    src: []const u8,
    dst: []const u8,
    cancel: ?*std.atomic.Value(bool),
    runner: ?*JobRunner,
) anyerror!void {
    if (runner) |job| if (!job.waitIfResumed(cancel)) return error.Cancelled;
    if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;

    const src_z = try allocator.dupeSentinel(u8, src, 0);
    defer allocator.free(src_z);
    if (runner) |job| {
        job.profilePathAllocation(src.len);
        job.profileCount(&job.profile_metrics.lstat_calls, 1);
    }

    var st: c.struct_stat = undefined;
    if (c.lstat(src_z, &st) != 0) return error.StatFailed;

    const fmt = st.st_mode & c.S_IFMT;
    if (fmt == c.S_IFLNK) {
        return copySymlink(allocator, src, dst);
    } else if (fmt == c.S_IFDIR) {
        const dst_z = try allocator.dupeSentinel(u8, dst, 0);
        defer allocator.free(dst_z);
        if (runner) |job| {
            job.profilePathAllocation(dst.len);
            job.profileCount(&job.profile_metrics.directory_create_calls, 1);
        }

        if (c.mkdir(dst_z, @intCast(st.st_mode & 0o7777)) != 0) return error.CreateDirectoryFailed;
        // Only remove a destination created by this operation on failure.
        errdefer deleteRecursive(allocator, dst) catch {};

        if (runner) |job| job.profileCount(&job.profile_metrics.opendir_calls, 1);
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
            if (runner) |job| job.profileCount(&job.profile_metrics.directory_entries, 1);

            const child_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src, name });
            defer allocator.free(child_src);
            if (runner) |job| job.profilePathAllocation(child_src.len);
            const child_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, name });
            defer allocator.free(child_dst);
            if (runner) |job| job.profilePathAllocation(child_dst.len);

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
        deleteRecursive(allocator, dst) catch return error.Cancelled;
        job.setManifestRootState(job.current_item_index, .cancelled);
        return error.Cancelled;
    };
    if (cancel != null and cancel.?.load(.acquire)) {
        deleteRecursive(allocator, dst) catch return error.Cancelled;
        if (runner) |job| job.setManifestRootState(job.current_item_index, .cancelled);
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
    if (runner) |job| job.setManifestRootState(job.current_item_index, .completed);
}

pub const JobRunner = struct {
    allocator: Allocator,
    /// Profiling is disabled by default. Configure before starting a job.
    profile_enabled: bool = false,
    /// Worker-owned while a job is running; read through profilingSnapshot().
    profile_metrics: CopyProfile = .{},
    /// Per-job copy buffer size. Production defaults to 64 KiB.
    copy_buffer_bytes: usize = copy_buffer_size,
    /// The production default remains buffered until benchmarks justify a change.
    copy_strategy: CopyStrategy = .buffered,
    copy_metrics: CopyMetrics = .{},
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
    manifest: TransferManifest,
      manifest_lookup: std.ArrayList(ManifestLookupEntry) = .empty,
      manifest_lookup_valid: bool = false,
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
            .manifest = TransferManifest.init(allocator),
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

    fn profileStart(self: *JobRunner) u64 {
        if (!self.profile_enabled) return 0;
        return monotonicNowNs();
    }

    fn profileAddDuration(self: *JobRunner, started: u64, field: *u64) void {
        if (!self.profile_enabled) return;
        field.* +|= monotonicNowNs() - started;
    }

    fn profileCount(self: *JobRunner, field: *u64, amount: u64) void {
        if (!self.profile_enabled) return;
        field.* +|= amount;
    }

    /// Rebuilds the sorted lookup index. Caller must hold mutex.
    /// The index borrows source paths owned by the manifest.
    fn rebuildManifestLookup(self: *JobRunner) bool {
        self.manifest_lookup_valid = false;
        self.manifest_lookup.clearRetainingCapacity();

        const entries = self.manifest.entries.items;
        self.manifest_lookup.ensureTotalCapacity(self.allocator, entries.len) catch return false;

        for (entries, 0..) |entry, index| {
            self.manifest_lookup.appendAssumeCapacity(.{
                .root_index = entry.root_index,
                .source_path = entry.source_path,
                .entry_index = index,
            });
        }

        std.mem.sort(
            ManifestLookupEntry,
            self.manifest_lookup.items,
            {},
            ManifestLookupEntry.lessThan,
        );
        self.manifest_lookup_valid = true;
        return true;
    }

    /// Invalidates borrowed path references before the manifest is cleared.
    fn clearManifestLookup(self: *JobRunner) void {
        self.manifest_lookup_valid = false;
        self.manifest_lookup.clearRetainingCapacity();
    }

    fn profilePathAllocation(self: *JobRunner, bytes: usize) void {
        if (!self.profile_enabled) return;
        self.profile_metrics.path_allocations +|= 1;
        self.profile_metrics.path_allocation_bytes +|= @intCast(bytes);
    }

    /// Returns a stable snapshot only after the worker has completed.
    pub fn profilingSnapshot(self: *JobRunner) ?CopyProfile {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (!self.profile_enabled or self.state != .finished) return null;
        return self.profile_metrics;
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
        self.clearManifestLookup();
        self.manifest.deinit();
        self.manifest_lookup.deinit(self.allocator);
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
        self.clearManifestLookup();
        self.manifest.clearRetainingCapacity();
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
        self.copy_metrics = .{};
        self.profile_metrics = .{};
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
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
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

    /// Returns a consistent, independently owned copy of the transfer manifest.
    /// The caller owns the snapshot and must call deinit().
    pub fn snapshotTransferManifest(
        self: *JobRunner,
        allocator: Allocator,
    ) !TransferManifestSnapshot {
        var snapshot: TransferManifestSnapshot = .{ .allocator = allocator };
        errdefer snapshot.deinit();

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        try snapshot.entries.ensureTotalCapacity(allocator, self.manifest.entries.items.len);
        for (self.manifest.entries.items) |entry| {
            snapshot.entries.appendAssumeCapacity(try cloneTransferEntry(allocator, entry));
        }
        return snapshot;
    }

    fn addTransferredBytes(self: *JobRunner, bytes: u64) void {
        self.addTransferredBytesImpl(bytes, false);
    }

    fn addFileTransferredBytes(self: *JobRunner, bytes: u64) void {
        self.addTransferredBytesImpl(bytes, true);
    }

    fn addTransferredBytesImpl(self: *JobRunner, bytes: u64, file_progress: bool) void {
        if (bytes == 0) return;
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
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

    /// Returns copy_file_range activity accumulated by the current job.
    pub fn copyMetrics(self: *JobRunner) CopyMetrics {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return self.copy_metrics;
    }

    fn recordCopyFileRangeCall(self: *JobRunner) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        self.copy_metrics.copy_file_range_calls +|= 1;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn recordReflinkCall(self: *JobRunner) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        self.copy_metrics.reflink_calls +|= 1;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn recordReflinkBytes(self: *JobRunner, bytes: u64) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        self.copy_metrics.reflink_bytes +|= bytes;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn recordReflinkFallback(self: *JobRunner) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        self.copy_metrics.reflink_fallback_files +|= 1;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn recordCopyFileRangeBytes(self: *JobRunner, bytes: u64) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        self.copy_metrics.copy_file_range_bytes +|= bytes;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn recordBufferedFallback(self: *JobRunner) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        self.copy_metrics.buffered_fallback_files +|= 1;
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn beginFileProgress(self: *JobRunner, path: []const u8, size: u64) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
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
        return self.manifestSubtreeProgressLocked(path, null);
    }

    fn manifestSubtreeProgressLocked(
        self: *JobRunner,
        path: []const u8,
        matched: ?*bool,
    ) ?f64 {
        var total_bytes: u64 = 0;
        var completed_bytes: u64 = 0;

        for (self.manifest.entries.items) |entry| {
            if (entry.kind != .file) continue;
            const destination = entry.destination_path orelse continue;
            if (!isStrictPathDescendant(path, destination)) continue;

            if (matched) |was_matched| was_matched.* = true;
            total_bytes +|= entry.size;

            switch (entry.state) {
                .completed => completed_bytes +|= entry.size,
                .copying => {
                    if (self.current_file_path_len > 0 and
                        std.mem.eql(
                            u8,
                            self.current_file_path[0..self.current_file_path_len],
                            destination,
                        ))
                    {
                        completed_bytes +|= @min(self.current_file_bytes, entry.size);
                    }
                },
                .pending, .skipped, .failed, .cancelled => {},
            }
        }

        if (total_bytes == 0) return null;
        return @min(
            1.0,
            @as(f64, @floatFromInt(completed_bytes)) /
                @as(f64, @floatFromInt(total_bytes)),
        );
    }

    fn isStrictPathDescendant(parent: []const u8, candidate: []const u8) bool {
        if (parent.len == 0 or candidate.len <= parent.len) return false;

        var prefix_len = parent.len;
        while (prefix_len > 1 and parent[prefix_len - 1] == '/') {
            prefix_len -= 1;
        }

        if (prefix_len == 1 and parent[0] == '/') {
            return candidate.len > 1 and candidate[0] == '/';
        }

        return candidate.len > prefix_len and
            std.mem.startsWith(u8, candidate, parent[0..prefix_len]) and
            candidate[prefix_len] == '/';
    }

    /// Resolves a batch of visible paths under one lock and one source-list
    /// traversal. `matched` distinguishes paths with a cancelled outcome
    /// from paths that do not belong to this job.
    pub fn progressForPaths(
        self: *JobRunner,
        paths: []const []const u8,
        results: []?f64,
        matched: []bool,
    ) !void {
        std.debug.assert(paths.len == results.len and paths.len == matched.len);
        @memset(results, null);
        @memset(matched, false);

        // Index requested directories so each manifest file can update all
        // requested ancestors by walking its destination path only once.
        var path_indices = std.StringHashMap(usize).init(self.allocator);
        defer path_indices.deinit();
        try path_indices.ensureTotalCapacity(@intCast(paths.len));
        for (paths, 0..) |path, index| {
            if (path.len > 0) try path_indices.put(path, index);
        }

        const totals = try self.allocator.alloc(u64, paths.len);
        defer self.allocator.free(totals);
        const completed = try self.allocator.alloc(u64, paths.len);
        defer self.allocator.free(completed);
        @memset(totals, 0);
        @memset(completed, 0);

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

        const direct_matched = try self.allocator.dupe(bool, matched);
        defer self.allocator.free(direct_matched);

        // One manifest traversal serves every requested directory. Walking
        // destination ancestors makes this O(manifest entries × path depth),
        // rather than rescanning the manifest once per visible directory.
        for (self.manifest.entries.items) |entry| {
            if (entry.kind != .file) continue;
            const destination = entry.destination_path orelse continue;
            var ancestor = std.fs.path.dirname(destination) orelse continue;

            while (true) {
                if (path_indices.get(ancestor)) |path_idx| {
                    if (!direct_matched[path_idx]) {
                        matched[path_idx] = true;
                        totals[path_idx] +|= entry.size;

                        switch (entry.state) {
                            .completed => completed[path_idx] +|= entry.size,
                            .copying => {
                                if (self.current_file_path_len > 0 and
                                    std.mem.eql(
                                        u8,
                                        self.current_file_path[0..self.current_file_path_len],
                                        destination,
                                    ))
                                {
                                    completed[path_idx] +|= @min(
                                        self.current_file_bytes,
                                        entry.size,
                                    );
                                }
                            },
                            .pending, .skipped, .failed, .cancelled => {},
                        }
                    }
                }

                const parent = std.fs.path.dirname(ancestor) orelse break;
                if (parent.len == ancestor.len) break;
                ancestor = parent;
            }
        }

        for (paths, 0..) |_, path_idx| {
            if (results[path_idx] != null or totals[path_idx] == 0) continue;
            results[path_idx] = @min(
                1.0,
                @as(f64, @floatFromInt(completed[path_idx])) /
                    @as(f64, @floatFromInt(totals[path_idx])),
            );
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

    /// Resolves every manifest entry beneath one selected source root.
    /// The update is committed only after all destination paths are allocated.
    fn resolveManifestDestinations(self: *JobRunner, root_index: usize, root_destination: []const u8) !void {
        const started = self.profileStart();
        defer self.profileAddDuration(started, &self.profile_metrics.destination_resolution_ns);
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        const entries = self.manifest.entries.items;
        const resolved = try self.allocator.alloc(?[]u8, entries.len);
        defer self.allocator.free(resolved);
        @memset(resolved, null);
        errdefer {
            for (resolved) |path| {
                if (path) |owned| self.allocator.free(owned);
            }
        }

        for (entries, 0..) |entry, idx| {
            if (entry.root_index != root_index) continue;
            resolved[idx] = if (entry.relative_path.len == 0)
                try self.allocator.dupe(u8, root_destination)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                    root_destination,
                    entry.relative_path,
                });
            self.profilePathAllocation(if (entry.relative_path.len == 0)
                root_destination.len
            else
                root_destination.len + 1 + entry.relative_path.len);
        }

        for (self.manifest.entries.items, 0..) |*entry, idx| {
            if (resolved[idx]) |path| {
                if (entry.destination_path) |old| self.allocator.free(old);
                entry.destination_path = path;
                resolved[idx] = null;
            }
        }
    }

    fn setManifestEntryState(
        self: *JobRunner,
        root_index: usize,
        source_path: []const u8,
        state: TransferEntryState,
    ) void {
        self.profileCount(&self.profile_metrics.mutex_lock_calls, 1);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        if (self.manifest_lookup_valid) {
            const lookup = self.manifest_lookup.items;
            var low: usize = 0;
            var high: usize = lookup.len;

            // Lower-bound search by (root_index, source_path).
            while (low < high) {
                const mid = low + (high - low) / 2;
                const candidate = lookup[mid];
                self.profileCount(&self.profile_metrics.manifest_lookup_comparisons, 1);

                if (candidate.root_index < root_index) {
                    low = mid + 1;
                } else if (candidate.root_index > root_index) {
                    high = mid;
                } else if (std.mem.order(u8, candidate.source_path, source_path) == .lt) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            if (low < lookup.len) {
                const candidate = lookup[low];
                self.profileCount(&self.profile_metrics.manifest_lookup_comparisons, 1);
                if (candidate.root_index == root_index and
                    std.mem.eql(u8, candidate.source_path, source_path))
                {
                    self.manifest.entries.items[candidate.entry_index].state = state;
                }
            }
            return;
        }

        // Allocation failure while building the index must not affect correctness.
        for (self.manifest.entries.items) |*entry| {
            self.profileCount(&self.profile_metrics.manifest_lookup_comparisons, 1);
            if (entry.root_index == root_index and
                std.mem.eql(u8, entry.source_path, source_path))
            {
                entry.state = state;
                return;
            }
        }
    }

    fn setManifestRootState(
        self: *JobRunner,
        root_index: usize,
        state: TransferEntryState,
    ) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        for (self.manifest.entries.items) |*entry| {
            if (entry.root_index == root_index) entry.state = state;
        }
    }

    fn setManifestSubtreeState(
        self: *JobRunner,
        root_index: usize,
        source_root: []const u8,
        state: TransferEntryState,
    ) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        for (self.manifest.entries.items) |*entry| {
            if (entry.root_index != root_index) continue;
            if (std.mem.eql(u8, entry.source_path, source_root) or
                (std.mem.startsWith(u8, entry.source_path, source_root) and
                entry.source_path.len > source_root.len and
                entry.source_path[source_root.len] == '/'))
            {
                entry.state = state;
            }
        }
    }

    fn finishManifestRoot(self: *JobRunner, root_index: usize, outcome: ItemOutcome) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        const final_state: TransferEntryState = switch (outcome) {
            .success => .completed,
            .skipped => .skipped,
            .failed => .failed,
            .cancelled => .cancelled,
        };

        for (self.manifest.entries.items) |*entry| {
            if (entry.root_index != root_index) continue;
            if (outcome == .failed or outcome == .cancelled) {
                if (entry.state == .completed) continue;
            }
            entry.state = final_state;
        }
    }

    fn finishCancelledManifestEntries(self: *JobRunner) void {
        if (!self.cancel_flag.load(.acquire)) return;

        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        for (self.manifest.entries.items) |*entry| {
            if (entry.state == .pending) entry.state = .cancelled;
        }
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
        self.profilePathAllocation(target.len);
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
                },
            }
        }
        if (self.cancel_flag.load(.acquire)) return .cancelled;
        if (isDescendantOrSame(src, target)) return error.CannotCopyIntoDescendant;
        try self.resolveManifestDestinations(self.current_item_index, target);
        try self.recordDestinationPath(target);
        if (self.kind == .copy) {
            const recursive_started = self.profileStart();
            defer self.profileAddDuration(recursive_started, &self.profile_metrics.recursive_copy_ns);
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
            const manifest_started = self.profileStart();
            defer self.profileAddDuration(manifest_started, &self.profile_metrics.manifest_scan_ns);
            var total: u64 = 0;
            var known = true;
            for (self.sources.items, 0..) |src, idx| {
                if (self.cancel_flag.load(.acquire)) {
                    known = false;
                    break;
                }
                const bytes = measureBytes(self.allocator, src, &self.cancel_flag, self, idx, "") catch {
                    _ = c.pthread_mutex_lock(&self.mutex);
                    self.clearManifestLookup();
                    self.manifest.clearRetainingCapacity();
                    _ = c.pthread_mutex_unlock(&self.mutex);
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
            if (self.cancel_flag.load(.acquire)) {
                _ = c.pthread_mutex_lock(&self.mutex);
                self.clearManifestLookup();
                self.manifest.clearRetainingCapacity();
                _ = c.pthread_mutex_unlock(&self.mutex);
            }
            _ = c.pthread_mutex_lock(&self.mutex);
            if (!self.cancel_flag.load(.acquire)) {
                _ = self.rebuildManifestLookup();
            }
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
            if (self.kind == .copy or self.kind == .move) {
                self.finishManifestRoot(idx, outcome);
            }
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
        self.finishCancelledManifestEntries();
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
