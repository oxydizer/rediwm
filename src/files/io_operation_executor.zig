//! Connects Manager-owned operations to their filesystem handlers through
//! the generic bounded Executor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_executor = @import("io_executor.zig");
const io_copy = @import("io_copy.zig");
const io_directory = @import("io_directory.zig");
const io_symlink = @import("io_symlink.zig");
const io_move = @import("io_move.zig");
const io_detach = @import("io_detach.zig");
const archive = @import("archive.zig");
const ops = @import("ops.zig");
const clipboard = @import("clipboard.zig");

const Context = struct {
    allocator: Allocator,
    manager: *io_manager.Manager,
    archive_staging: std.AutoHashMapUnmanaged(
        io_executor.OperationKey,
        ArchiveStagingLease,
    ) = .empty,
    archive_cancellations: std.AutoHashMapUnmanaged(
        io_manager.JobId,
        *archive.Cancel,
    ) = .empty,
};

const ArchiveStagingLease = struct {
    allocator: Allocator,
    token: io_manager.WorkToken,
    path: []u8,

    fn deinit(self: *ArchiveStagingLease) void {
        ops.deleteRecursive(self.allocator, self.path) catch {};
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

fn requestArchiveCancellation(context: *Context) void {
    var cancellations = context.archive_cancellations.valueIterator();
    while (cancellations.next()) |cancel| {
        cancel.*.store(true, .release);
    }
}

pub const Runtime = struct {
    allocator: Allocator,
    context: *Context,
    executor: io_executor.Executor,

    pub fn init(
        allocator: Allocator,
        manager: *io_manager.Manager,
        worker_count: usize,
        capacity: usize,
    ) !Runtime {
        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        context.* = .{
            .allocator = allocator,
            .manager = manager,
        };

        const executor = try io_executor.Executor.init(
            allocator,
            .{
                .worker_count = worker_count,
                .capacity = capacity,
            },
            @ptrCast(context),
            .{
                .prepare = prepare,
                .execute = execute,
                .complete = complete,
                .discard = discard,
            },
        );

        return .{
            .allocator = allocator,
            .context = context,
            .executor = executor,
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Archive extraction is a long-running worker unit. Request
        // cancellation before joining so shutdown does not wait for it.
        requestArchiveCancellation(self.context);
        self.executor.deinit();

        var staging = self.context.archive_staging.valueIterator();
        while (staging.next()) |lease| lease.deinit();
        self.context.archive_staging.deinit(self.allocator);

        var cancellations = self.context.archive_cancellations.valueIterator();
        while (cancellations.next()) |cancel| self.allocator.destroy(cancel.*);
        self.context.archive_cancellations.deinit(self.allocator);

        self.allocator.destroy(self.context);
        self.* = undefined;
    }

    pub fn wakeFd(self: *Runtime) std.posix.fd_t {
        return self.executor.wakeFd();
    }

    pub fn drainWake(self: *Runtime) u64 {
        return self.executor.drainWake();
    }

    pub fn dispatchReady(self: *Runtime) !usize {
        return self.executor.dispatchReady(self.context.manager);
    }

    pub fn drainCompletions(self: *Runtime) !usize {
        return (try self.drainCompletionsWithStats()).drained;
    }

    pub fn drainCompletionsWithStats(self: *Runtime) !io_executor.DrainStats {
        return self.executor.drainCompletionsWithStats(self.context.manager);
    }

    /// Enables per-unit timing collection. Strategy and byte counters are
    /// collected regardless of this setting.
    pub fn setProfilingEnabled(self: *Runtime, enabled: bool) void {
        self.executor.profile_enabled = enabled;
    }

    pub fn pauseJob(self: *Runtime, job_id: io_manager.JobId) !void {
        try self.context.manager.pauseJob(job_id);
    }

    pub fn resumeJob(self: *Runtime, job_id: io_manager.JobId) !void {
        try self.context.manager.resumeJob(job_id);
    }

    pub fn cancelJob(self: *Runtime, job_id: io_manager.JobId) !void {
        if (self.context.archive_cancellations.get(job_id)) |cancel| {
            cancel.store(true, .release);
        }
        try self.context.manager.cancelJob(job_id);
        self.executor.cancelJob(job_id);
    }

    /// Borrows the private extraction directory while its archive operation
    /// waits at the publication barrier.
    pub fn archiveStagingPath(
        self: *const Runtime,
        token: io_manager.WorkToken,
    ) ?[]const u8 {
        if (self.context.manager.archiveOperationDetails(token) == null) return null;
        const lease = self.context.archive_staging.get(
            io_executor.OperationKey.fromToken(token),
        ) orelse return null;
        return lease.path;
    }

    /// Returns the exact waiting token associated with an owned staging
    /// lease. The generation is captured from the accepted worker completion.
    pub fn archiveStagingToken(
        self: *const Runtime,
        job_id: io_manager.JobId,
        operation_id: io_manager.OperationId,
    ) ?io_manager.WorkToken {
        const key: io_executor.OperationKey = .{
            .job_id = job_id,
            .operation_id = operation_id,
        };
        const lease = self.context.archive_staging.get(key) orelse return null;
        if (self.context.manager.archiveOperationDetails(lease.token) == null)
            return null;
        return lease.token;
    }

    /// Releases staging only after publication registration, discovery and
    /// every publication operation have drained.
    pub fn releaseArchiveStaging(
        self: *Runtime,
        token: io_manager.WorkToken,
    ) !bool {
        if (self.context.manager.archivePublicationReady(token) != true) return false;
        const key = io_executor.OperationKey.fromToken(token);
        const lease = self.context.archive_staging.getPtr(key) orelse return false;
        try ops.deleteRecursive(self.allocator, lease.path);
        self.allocator.free(lease.path);
        _ = self.context.archive_staging.remove(key);
        return true;
    }

    /// Transfers a completed extraction directory to an external owner.
    /// The publication barrier must be closed and all publication work drained.
    pub fn takeArchiveStaging(
        self: *Runtime,
        token: io_manager.WorkToken,
    ) ?clipboard.StagingLease {
        if (self.context.manager.archivePublicationReady(token) != true)
            return null;
        const key = io_executor.OperationKey.fromToken(token);
        const lease = self.context.archive_staging.get(key) orelse return null;
        if (!std.meta.eql(lease.token, token)) return null;

        const removed = self.context.archive_staging.fetchRemove(key) orelse
            return null;
        return .{
            .allocator = removed.value.allocator,
            .path = removed.value.path,
        };
    }

    /// Removes a retained staging lease after its Manager job has become
    /// terminal. This is used for cancelled archive operations.
    pub fn discardArchiveStaging(
        self: *Runtime,
        job_id: io_manager.JobId,
        operation_id: io_manager.OperationId,
    ) !bool {
        const state = self.context.manager.jobState(job_id) orelse return false;
        if (!state.isTerminal()) return false;
        const key: io_executor.OperationKey = .{
            .job_id = job_id,
            .operation_id = operation_id,
        };
        const lease = self.context.archive_staging.getPtr(key) orelse return false;
        try ops.deleteRecursive(self.allocator, lease.path);
        self.allocator.free(lease.path);
        _ = self.context.archive_staging.remove(key);
        return true;
    }
};

fn prepare(
    raw_context: ?*anyopaque,
    token: io_manager.WorkToken,
) anyerror!io_executor.PreparedWork {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    if (context.manager.archiveOperationDetails(token)) |archive_details| {
        return prepareArchive(context, token, archive_details);
    }
    const details = context.manager.operationDetails(token) orelse
        return error.StaleOperation;
    const tree = context.manager.treeIndex(token.job_id) orelse
        return error.UnknownJob;
    const entry = tree.getConst(details.entry_id) orelse return error.UnknownEntry;
    const input = switch (details.kind) {
        .detach_source => blk: {
            const source = try context.manager.sourcePath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(source);
            break :blk try io_detach.makeInput(
                context.allocator,
                source,
                entry.kind,
                entry.metadata,
            );
        },
        .create_directory, .copy_file => blk: {
            const destination = try context.manager.destinationPath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(destination);
            const source = try context.manager.sourcePath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(source);
            break :blk if (details.kind == .create_directory)
                try io_directory.makeInput(
                    context.allocator,
                    source,
                    destination,
                    details.merge_existing_directory,
                )
            else
                if (details.replace_existing_file)
                    try io_copy.makeReplacementInput(
                        context.allocator,
                        source,
                        destination,
                        token,
                    )
                else
                    try io_copy.makeInput(context.allocator, source, destination);
        },
        .copy_symlink => blk: {
            const destination = try context.manager.destinationPath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(destination);
            break :blk try io_symlink.makeInput(
                context.allocator,
                entry.symlink_target orelse return error.MissingSymlinkTarget,
                destination,
            );
        },
        .move_entry => blk: {
            const destination = try context.manager.destinationPath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(destination);
            const source = try context.manager.sourcePath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(source);
            break :blk try io_move.makeInput(
                context.allocator,
                source,
                destination,
            );
        },
        else => return error.UnsupportedOperation,
    };

    return .{
        .operation_kind = details.kind,
        .input = input,
    };
}

const ArchiveInput = struct {
    job_id: io_manager.JobId,
    cancel: *archive.Cancel,
    source_path: []const u8,
    staging_parent: []const u8,
    member_path: ?[]const u8,
    member_count: usize,
    member_paths_bytes: []const u8,
};

fn writeArchiveUnsigned(comptime T: type, output: []u8, value: T) void {
    for (0..@sizeOf(T)) |index| {
        const shift: std.math.Log2Int(T) = @intCast(index * 8);
        output[index] = @truncate(value >> shift);
    }
}

fn readArchiveUnsigned(comptime T: type, input: []const u8) T {
    var value: T = 0;
    for (0..@sizeOf(T)) |index| {
        const shift: std.math.Log2Int(T) = @intCast(index * 8);
        value |= @as(T, input[index]) << shift;
    }
    return value;
}

fn makeArchiveInput(
    allocator: Allocator,
    job_id: io_manager.JobId,
    cancel: *archive.Cancel,
    source_path: []const u8,
    staging_parent: []const u8,
    member_path: ?[]const u8,
    member_paths: []const []const u8,
) !io_executor.OwnedPayload {
    if (source_path.len == 0 or staging_parent.len == 0 or
        std.mem.indexOfScalar(u8, source_path, 0) != null or
        std.mem.indexOfScalar(u8, staging_parent, 0) != null)
    {
        return error.InvalidArchiveInput;
    }
    if (member_path) |member| {
        if (member.len == 0 or std.mem.indexOfScalar(u8, member, 0) != null)
            return error.InvalidArchiveInput;
    }
    if (member_path != null and member_paths.len != 0)
        return error.InvalidArchiveInput;
    for (member_paths) |member| {
        if (member.len == 0 or std.mem.indexOfScalar(u8, member, 0) != null)
            return error.InvalidArchiveInput;
    }

    const header_size = @sizeOf(io_manager.JobId) + @sizeOf(usize);
    const source_end = try std.math.add(usize, header_size, source_path.len);
    const parent_start = try std.math.add(usize, source_end, 1);
    const parent_end = try std.math.add(usize, parent_start, staging_parent.len);
    const member_start = try std.math.add(usize, parent_end, 1);
    const member = member_path orelse "";
    const member_end = try std.math.add(usize, member_start, member.len);
    const count_start = try std.math.add(usize, member_end, 1);
    const members_start = try std.math.add(usize, count_start, @sizeOf(usize));
    var total_size = members_start;
    for (member_paths) |path| {
        total_size = try std.math.add(usize, total_size, path.len);
        total_size = try std.math.add(usize, total_size, 1);
    }
    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);

    writeArchiveUnsigned(io_manager.JobId, bytes[0..@sizeOf(io_manager.JobId)], job_id);
    writeArchiveUnsigned(
        usize,
        bytes[@sizeOf(io_manager.JobId)..header_size],
        @intFromPtr(cancel),
    );
    @memcpy(bytes[header_size..source_end], source_path);
    bytes[source_end] = 0;
    @memcpy(bytes[parent_start..parent_end], staging_parent);
    bytes[parent_end] = 0;
    @memcpy(bytes[member_start..member_end], member);
    bytes[member_end] = 0;
    writeArchiveUnsigned(usize, bytes[count_start..members_start], member_paths.len);
    var cursor = members_start;
    for (member_paths) |path| {
        const path_end = cursor + path.len;
        @memcpy(bytes[cursor..path_end], path);
        bytes[path_end] = 0;
        cursor = path_end + 1;
    }

    return .{ .allocator = allocator, .bytes = bytes };
}

fn parseArchiveInput(input: *const io_executor.OwnedPayload) !ArchiveInput {
    const bytes = input.slice();
    const header_size = @sizeOf(io_manager.JobId) + @sizeOf(usize);
    if (bytes.len < header_size + 3) return error.InvalidArchiveInput;

    const job_id = readArchiveUnsigned(
        io_manager.JobId,
        bytes[0..@sizeOf(io_manager.JobId)],
    );
    const cancel_address = readArchiveUnsigned(
        usize,
        bytes[@sizeOf(io_manager.JobId)..header_size],
    );
    if (cancel_address == 0) return error.InvalidArchiveInput;

    const source_bytes = bytes[header_size..];
    const source_end = std.mem.indexOfScalar(u8, source_bytes, 0) orelse
        return error.InvalidArchiveInput;
    const parent_bytes = source_bytes[source_end + 1 ..];
    const parent_end = std.mem.indexOfScalar(u8, parent_bytes, 0) orelse
        return error.InvalidArchiveInput;
    const member_bytes = parent_bytes[parent_end + 1 ..];
    const member_end = std.mem.indexOfScalar(u8, member_bytes, 0) orelse
        return error.InvalidArchiveInput;
    if (source_end == 0 or parent_end == 0)
        return error.InvalidArchiveInput;
    const count_start = member_end + 1;
    const count_end = try std.math.add(usize, count_start, @sizeOf(usize));
    if (count_end > member_bytes.len) return error.InvalidArchiveInput;
    const member_count = readArchiveUnsigned(usize, member_bytes[count_start..count_end]);
    const member_paths_bytes = member_bytes[count_end..];
    var remaining = member_paths_bytes;
    for (0..member_count) |_| {
        const path_end = std.mem.indexOfScalar(u8, remaining, 0) orelse
            return error.InvalidArchiveInput;
        if (path_end == 0) return error.InvalidArchiveInput;
        remaining = remaining[path_end + 1 ..];
    }
    if (remaining.len != 0) return error.InvalidArchiveInput;

    return .{
        .job_id = job_id,
        .cancel = @ptrFromInt(cancel_address),
        .source_path = source_bytes[0..source_end],
        .staging_parent = parent_bytes[0..parent_end],
        .member_path = if (member_end == 0) null else member_bytes[0..member_end],
        .member_count = member_count,
        .member_paths_bytes = member_paths_bytes,
    };
}

fn prepareArchive(
    context: *Context,
    token: io_manager.WorkToken,
    details: io_manager.ArchiveOperationDetails,
) !io_executor.PreparedWork {
    if (context.archive_cancellations.contains(token.job_id))
        return error.ArchiveCancellationAlreadyActive;

    const cancel = try context.allocator.create(archive.Cancel);
    errdefer context.allocator.destroy(cancel);
    cancel.* = .init(false);

    const input = try makeArchiveInput(
        context.allocator,
        token.job_id,
        cancel,
        details.source_path,
        details.staging_parent,
        details.member_path,
        details.member_paths,
    );
    errdefer {
        var owned_input = input;
        owned_input.deinit();
    }

    try context.archive_cancellations.put(
        context.allocator,
        token.job_id,
        cancel,
    );

    return .{
        .operation_kind = details.kind,
        .input = input,
    };
}

fn execute(
    raw_context: ?*anyopaque,
    item: io_executor.WorkItem,
) io_executor.WorkCompletion {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    return switch (item.operation_kind) {
        .create_directory => io_directory.execute(context.allocator, item),
        .copy_file => io_copy.execute(context.allocator, item),
        .copy_symlink => io_symlink.execute(context.allocator, item),
        .move_entry => io_move.execute(context.allocator, item),
        .detach_source => io_detach.execute(context.allocator, item),
        .archive_extract, .archive_member_extract => executeArchive(context.allocator, item),
        else => failWork(item),
    };
}

fn executeArchive(
    allocator: Allocator,
    item_arg: io_executor.WorkItem,
) io_executor.WorkCompletion {
    var item = item_arg;
    const input = parseArchiveInput(&item.input) catch return failWork(item);
    const stage = archive.temporary(allocator, input.staging_parent) catch
        return failWork(item);

    var selected_members: std.ArrayList([]const u8) = .empty;
    defer selected_members.deinit(allocator);
    var remaining = input.member_paths_bytes;
    for (0..input.member_count) |_| {
        const path_end = std.mem.indexOfScalar(u8, remaining, 0) orelse
            return archiveCompletion(
                item,
                .failed,
                .{ .allocator = allocator, .bytes = stage },
            );
        selected_members.append(allocator, remaining[0..path_end]) catch
            return archiveCompletion(
                item,
                .failed,
                .{ .allocator = allocator, .bytes = stage },
            );
        remaining = remaining[path_end + 1 ..];
    }

    const extraction = if (input.member_count != 0)
        archive.extractMembers(
            allocator,
            input.source_path,
            stage,
            selected_members.items,
            input.cancel,
        )
    else
        archive.extract(
            allocator,
            input.source_path,
            stage,
            input.member_path,
            input.cancel,
        );
    extraction catch |err| {
        const outcome: io_manager.WorkResult =
            if (err == error.Cancelled) .cancelled else .failed;
        return archiveCompletion(
            item,
            outcome,
            .{ .allocator = allocator, .bytes = stage },
        );
    };

    return archiveCompletion(
        item,
        .waiting,
        .{ .allocator = allocator, .bytes = stage },
    );
}

fn archiveCompletion(
    item_arg: io_executor.WorkItem,
    outcome: io_manager.WorkResult,
    result: io_executor.OwnedPayload,
) io_executor.WorkCompletion {
    var item = item_arg;
    if (item.continuation) |*continuation| {
        continuation.deinit();
        item.continuation = null;
    }
    return .{
        .token = item.token,
        .outcome = outcome,
        .operation_kind = item.operation_kind,
        .input = item.input,
        .result = result,
    };
}

fn failWork(item_arg: io_executor.WorkItem) io_executor.WorkCompletion {
    var item = item_arg;
    if (item.continuation) |*continuation| {
        continuation.deinit();
        item.continuation = null;
    }
    return .{
        .token = item.token,
        .outcome = .failed,
        .operation_kind = item.operation_kind,
        .input = item.input,
    };
}

fn complete(
    raw_context: ?*anyopaque,
    token: io_manager.WorkToken,
    operation_kind: ?io_manager.OperationKind,
    outcome: io_manager.WorkResult,
    result: ?io_executor.OwnedPayload,
) void {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    if (operation_kind) |kind| {
        if (kind == .archive_extract or kind == .archive_member_extract) {
            if (outcome == .waiting) {
                const payload = result orelse {
                    context.manager.failWaiting(token.job_id, token.operation_id) catch {};
                    return;
                };
                var owned = payload;
                const path = owned.bytes orelse {
                    owned.deinit();
                    context.manager.failWaiting(token.job_id, token.operation_id) catch {};
                    return;
                };
                owned.bytes = null;
                const key = io_executor.OperationKey.fromToken(token);
                const lease = ArchiveStagingLease{
                    .allocator = context.allocator,
                    .token = token,
                    .path = path,
                };
                context.archive_staging.put(context.allocator, key, lease) catch {
                    var failed_lease = lease;
                    failed_lease.deinit();
                    context.manager.failWaiting(token.job_id, token.operation_id) catch {};
                };
            } else {
                discardArchiveResult(context.allocator, result);
            }
            return;
        }
    }
    if (outcome == .waiting) {
        if (operation_kind == .move_entry and isMoveFallbackResult(result)) {
            _ = context.manager.fallbackMoveToCopy(token) catch {
                context.manager.failWaiting(token.job_id, token.operation_id) catch {};
            };
        } else if (isCollisionResult(result)) {
            registerCollision(context, token) catch {
                context.manager.failWaiting(token.job_id, token.operation_id) catch {};
            };
        }
    }
    if (operation_kind) |kind| {
        switch (kind) {
            .create_directory => io_directory.complete(null, token, outcome, result),
            .copy_file => io_copy.complete(null, token, outcome, result),
            .copy_symlink => io_symlink.complete(null, token, outcome, result),
            .move_entry => io_move.complete(null, token, outcome, result),
            .detach_source => io_detach.complete(null, token, outcome, result),
            else => deinitOptional(result),
        }
    } else {
        deinitOptional(result);
    }
}

fn isMoveFallbackResult(result: ?io_executor.OwnedPayload) bool {
    const payload = result orelse return false;
    const bytes = payload.slice();
    return bytes.len == 1 and bytes[0] == 3;
}

fn isCollisionResult(result: ?io_executor.OwnedPayload) bool {
    const payload = result orelse return false;
    const bytes = payload.slice();
    // Directory and symlink handlers use tag 1; regular-file copy uses
    // tag 2 because tag 1 is also its successful-copy cleanup marker.
    // This function is called only for .waiting outcomes.
    return bytes.len == 1 and (bytes[0] == 1 or bytes[0] == 2);
}

fn registerCollision(context: *Context, token: io_manager.WorkToken) !void {
    const manager = context.manager;
    const details = manager.operationDetails(token) orelse
        return error.StaleOperation;
    const tree = manager.treeIndex(token.job_id) orelse return error.UnknownJob;
    const entry = tree.getConst(details.entry_id) orelse return error.UnknownEntry;

    const source_path = try manager.sourcePath(
        context.allocator,
        token.job_id,
        details.entry_id,
    );
    defer context.allocator.free(source_path);
    const destination_path = try manager.destinationPath(
        context.allocator,
        token.job_id,
        details.entry_id,
    );
    defer context.allocator.free(destination_path);

    const destination_z = try context.allocator.dupeSentinel(u8, destination_path, 0);
    defer context.allocator.free(destination_z);
    var destination_stat: c.struct_stat = undefined;
    if (c.lstat(destination_z, &destination_stat) != 0) {
        if (std.c._errno().* == c.ENOENT) {
            // The colliding entry disappeared before the main-thread
            // completion was handled. Retry the original destination.
            try manager.resolveWaiting(token.job_id, token.operation_id);
            return;
        }
        return error.DestinationStatFailed;
    }

    const destination_kind: @import("io_tree.zig").EntryKind =
        switch (destination_stat.st_mode & c.S_IFMT) {
            c.S_IFDIR => .directory,
            c.S_IFREG => .regular_file,
            c.S_IFLNK => .symlink,
            else => .other,
        };

    _ = try manager.registerConflict(
        token,
        details.entry_id,
        source_path,
        destination_path,
        entry.kind,
        destination_kind,
    );
}

fn discard(
    raw_context: ?*anyopaque,
    operation_kind: io_manager.OperationKind,
    input: io_executor.OwnedPayload,
    continuation: ?io_executor.OwnedPayload,
    result: ?io_executor.OwnedPayload,
) void {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    switch (operation_kind) {
        .create_directory => io_directory.discard(null, operation_kind, input, continuation, result),
        .copy_file => io_copy.discard(null, operation_kind, input, continuation, result),
        .copy_symlink => io_symlink.discard(null, operation_kind, input, continuation, result),
        .move_entry => io_move.discard(null, operation_kind, input, continuation, result),
        .detach_source => io_detach.discard(null, operation_kind, input, continuation, result),
        .archive_extract, .archive_member_extract => {
            if (input.bytes) |bytes| {
                const header_size = @sizeOf(io_manager.JobId) + @sizeOf(usize);
                if (bytes.len >= header_size) {
                    const job_id = readArchiveUnsigned(
                        io_manager.JobId,
                        bytes[0..@sizeOf(io_manager.JobId)],
                    );
                    const cancel_address = readArchiveUnsigned(
                        usize,
                        bytes[@sizeOf(io_manager.JobId)..header_size],
                    );
                    if (context.archive_cancellations.fetchRemove(job_id)) |entry| {
                        if (@intFromPtr(entry.value) == cancel_address)
                            context.allocator.destroy(entry.value)
                        else
                            context.archive_cancellations.put(
                                context.allocator,
                                job_id,
                                entry.value,
                            ) catch context.allocator.destroy(entry.value);
                    }
                }
            }
            var owned_input = input;
            owned_input.deinit();
            deinitOptional(continuation);
            discardArchiveResult(context.allocator, result);
        },
        else => {
            var owned_input = input;
            owned_input.deinit();
            deinitOptional(continuation);
            deinitOptional(result);
        },
    }
}

fn discardArchiveResult(allocator: Allocator, result: ?io_executor.OwnedPayload) void {
    if (result) |payload| {
        var owned = payload;
        if (owned.bytes) |path| ops.deleteRecursive(allocator, path) catch {};
        owned.deinit();
    }
}

fn deinitOptional(payload: ?io_executor.OwnedPayload) void {
    if (payload) |value| {
        var owned = value;
        owned.deinit();
    }
}

test "archive shutdown requests cancellation for every active extraction" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    var context: Context = .{
        .allocator = allocator,
        .manager = &manager,
    };
    defer context.archive_cancellations.deinit(allocator);

    var first: archive.Cancel = .init(false);
    var second: archive.Cancel = .init(false);
    try context.archive_cancellations.put(allocator, 1, &first);
    try context.archive_cancellations.put(allocator, 2, &second);

    requestArchiveCancellation(&context);

    try std.testing.expect(first.load(.acquire));
    try std.testing.expect(second.load(.acquire));
}
