//! Connects Manager-owned operations to their filesystem handlers through
//! the generic bounded Executor.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_executor = @import("io_executor.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const io_copy = @import("io_copy.zig");
const io_directory = @import("io_directory.zig");
const io_symlink = @import("io_symlink.zig");
const io_move = @import("io_move.zig");
const io_detach = @import("io_detach.zig");
const io_finalize = @import("io_finalize.zig");
const archive = @import("archive.zig");
const ops = @import("ops.zig");

const Context = struct {
    allocator: Allocator,
    manager: *io_manager.Manager,
    archive_staging: std.AutoHashMapUnmanaged(
        io_executor.OperationKey,
        ArchiveStagingLease,
    ) = .empty,
    archive_cancellations: std.AutoHashMapUnmanaged(
        io_manager.JobId,
        ArchiveCancellationLease,
    ) = .empty,
    ledger: *io_resource_ledger.Ledger,
    owned_ledger: ?*io_resource_ledger.Ledger = null,
};

const ArchiveStagingLease = struct {
    allocator: Allocator,
    token: io_manager.WorkToken,
    path: []u8,
    ledger_handle: io_resource_ledger.Handle,

    fn deinit(
        self: *ArchiveStagingLease,
        ledger: *io_resource_ledger.Ledger,
    ) void {
        ops.deleteRecursive(self.allocator, self.path) catch {};
        self.allocator.free(self.path);
        ledger.release(
            self.ledger_handle,
            .operation_executor,
        ) catch unreachable;
        self.* = undefined;
    }
};

const ArchiveCancellationLease = struct {
    cancel: *archive.Cancel,
    ledger_handle: io_resource_ledger.Handle,
};

fn requestArchiveCancellation(context: *Context) void {
    var cancellations = context.archive_cancellations.valueIterator();
    while (cancellations.next()) |lease| {
        lease.cancel.store(true, .release);
    }
}

/// The archive worker has returned before its completion callback runs, so
/// its cancellation handle is no longer needed and can be reclaimed.
fn releaseArchiveCancellation(context: *Context, job_id: io_manager.JobId) void {
    const entry = context.archive_cancellations.fetchRemove(job_id) orelse return;
    context.allocator.destroy(entry.value.cancel);
    context.ledger.release(
        entry.value.ledger_handle,
        .operation_executor,
    ) catch unreachable;
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
        return initInternal(allocator, manager, null, worker_count, worker_count, capacity);
    }

    /// Uses the process Runtime's shared resource ledger. Standalone executor
    /// users retain the self-owned ledger provided by init().
    pub fn initWithLedger(
        allocator: Allocator,
        manager: *io_manager.Manager,
        ledger: *io_resource_ledger.Ledger,
        worker_count: usize,
        capacity: usize,
    ) !Runtime {
        return initInternal(allocator, manager, ledger, worker_count, worker_count, capacity);
    }

    /// As `initWithLedger`, with up to `worker_cap` workers while some are
    /// stuck (worker-pools §4.3).
    pub fn initWithLedgerElastic(
        allocator: Allocator,
        manager: *io_manager.Manager,
        ledger: *io_resource_ledger.Ledger,
        worker_count: usize,
        worker_cap: usize,
        capacity: usize,
    ) !Runtime {
        return initInternal(allocator, manager, ledger, worker_count, worker_cap, capacity);
    }

    fn initInternal(
        allocator: Allocator,
        manager: *io_manager.Manager,
        shared_ledger: ?*io_resource_ledger.Ledger,
        worker_count: usize,
        worker_cap: usize,
        capacity: usize,
    ) !Runtime {
        const owned_ledger = if (shared_ledger == null) blk: {
            const ledger = try allocator.create(io_resource_ledger.Ledger);
            ledger.* = io_resource_ledger.Ledger.init(allocator);
            break :blk ledger;
        } else null;
        errdefer if (owned_ledger) |ledger| {
            ledger.deinit();
            allocator.destroy(ledger);
        };

        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        context.* = .{
            .allocator = allocator,
            .manager = manager,
            .ledger = shared_ledger orelse owned_ledger.?,
            .owned_ledger = owned_ledger,
        };

        const executor = try io_executor.Executor.initWithLedger(
            allocator,
            .{
                .worker_count = worker_count,
                .capacity = capacity,
                .worker_cap = worker_cap,
            },
            @ptrCast(context),
            .{
                .prepare = prepare,
                .execute = execute,
                .accept = accept,
                .complete = complete,
                .discard = discard,
            },
            context.ledger,
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
        while (staging.next()) |lease| lease.deinit(self.context.ledger);
        self.context.archive_staging.deinit(self.allocator);

        var cancellations = self.context.archive_cancellations.valueIterator();
        while (cancellations.next()) |lease| {
            self.allocator.destroy(lease.cancel);
            self.context.ledger.release(
                lease.ledger_handle,
                .operation_executor,
            ) catch unreachable;
        }
        self.context.archive_cancellations.deinit(self.allocator);

        if (self.context.owned_ledger) |ledger| {
            std.debug.assert(ledger.isEmpty());
            ledger.deinit();
            self.allocator.destroy(ledger);
        }
        self.allocator.destroy(self.context);
        self.* = undefined;
    }

    pub fn runningTasks(self: *Runtime, out: []@import("io_workers.zig").Running) usize {
        return self.executor.runningTasks(out);
    }

    pub fn queuedCount(self: *Runtime) usize {
        return self.executor.queuedCount();
    }

    pub fn grow(self: *Runtime, stuck_after_ms: i64) usize {
        return self.executor.grow(stuck_after_ms);
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

    /// Includes executor work plus Runtime-owned archive resources. A staging
    /// lease blocks Job retirement until it is discarded or transferred.
    pub fn isJobQuiescent(self: *const Runtime, job_id: io_manager.JobId) bool {
        if (!self.executor.isJobQuiescent(job_id)) return false;
        if (self.context.archive_cancellations.contains(job_id)) return false;

        var staging_iter = self.context.archive_staging.keyIterator();
        while (staging_iter.next()) |key| {
            if (key.job_id == job_id) return false;
        }
        return true;
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
        if (self.context.archive_cancellations.get(job_id)) |lease| {
            lease.cancel.store(true, .release);
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

    pub const DetachedStaging = struct {
        handle: io_resource_ledger.Handle,
        /// Owned by the caller now.
        path: []u8,
    };

    /// Takes a staging folder out of the executor without touching the
    /// filesystem: its ledger entry stays executor-owned, and the caller
    /// hands it on, to a worker that deletes it or to a window (stage S4).
    /// Only once publication has drained, or once the job has ended.
    pub fn detachArchiveStaging(
        self: *Runtime,
        job_id: io_manager.JobId,
        operation_id: io_manager.OperationId,
    ) ?DetachedStaging {
        const key: io_executor.OperationKey = .{ .job_id = job_id, .operation_id = operation_id };
        const lease = self.context.archive_staging.get(key) orelse return null;
        const ended = if (self.context.manager.jobState(job_id)) |state| state.isTerminal() else true;
        if (!ended and self.context.manager.archivePublicationReady(lease.token) != true) return null;
        const removed = self.context.archive_staging.fetchRemove(key) orelse return null;
        return .{ .handle = removed.value.ledger_handle, .path = removed.value.path };
    }

    /// Releases a retained staging resource by its ledger handle. The
    /// staging directory is physically deleted before its ledger entry.
    pub fn releaseResource(
        self: *Runtime,
        handle: io_resource_ledger.Handle,
    ) !void {
        const owner = self.context.ledger.ownerOf(handle) orelse
            return error.UnknownResource;
        if (owner != .operation_executor)
            return error.ResourceOwnerMismatch;
        const job_id = self.context.ledger.jobIdOf(handle) orelse
            return error.UnknownResource;
        if (self.context.ledger.kindOf(handle) != .archive_staging)
            return error.ResourceNotReleasable;

        var iter = self.context.archive_staging.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.ledger_handle.id != handle.id) continue;

            const key = entry.key_ptr.*;
            if (key.job_id != job_id) return error.ResourceLedgerMismatch;
            const state = self.context.manager.jobState(key.job_id) orelse
                return error.UnknownJob;
            if (!state.isTerminal()) return error.ResourceBusy;

            const lease = entry.value_ptr.*;
            try ops.deleteRecursive(self.allocator, lease.path);
            self.allocator.free(lease.path);
            _ = self.context.archive_staging.remove(key);
            self.context.ledger.release(
                lease.ledger_handle,
                .operation_executor,
            ) catch unreachable;
            return;
        }

        return error.ResourceNotOwnedByOperationExecutor;
    }

    /// The first half of a staging release that must not block the calling
    /// thread: checks the same conditions as `releaseResource`, removes the
    /// lease and moves its ledger entry to `operation_worker`, so the job
    /// cannot retire while the directory still exists. The caller deletes the
    /// returned path on a worker and then calls `finishStagingCleanup`.
    /// The path is owned by the caller.
    pub fn takeStagingForCleanup(
        self: *Runtime,
        handle: io_resource_ledger.Handle,
    ) ![]u8 {
        const owner = self.context.ledger.ownerOf(handle) orelse
            return error.UnknownResource;
        if (owner != .operation_executor)
            return error.ResourceOwnerMismatch;
        const job_id = self.context.ledger.jobIdOf(handle) orelse
            return error.UnknownResource;
        if (self.context.ledger.kindOf(handle) != .archive_staging)
            return error.ResourceNotReleasable;

        var iter = self.context.archive_staging.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.ledger_handle.id != handle.id) continue;
            const key = entry.key_ptr.*;
            if (key.job_id != job_id) return error.ResourceLedgerMismatch;
            const state = self.context.manager.jobState(key.job_id) orelse
                return error.UnknownJob;
            if (!state.isTerminal()) return error.ResourceBusy;

            const path = entry.value_ptr.path;
            _ = self.context.archive_staging.remove(key);
            self.context.ledger.transfer(handle, .operation_executor, .operation_worker) catch unreachable;
            return path;
        }
        return error.ResourceNotOwnedByOperationExecutor;
    }

    /// Records that a worker finished deleting staging taken with
    /// `takeStagingForCleanup`. A failed delete is still released: the
    /// directory is under the known staging root, which a later start sweeps
    /// (roadmap phase 5), and the job must not stay unretirable.
    pub fn finishStagingCleanup(self: *Runtime, handle: io_resource_ledger.Handle) void {
        self.context.ledger.release(handle, .operation_worker) catch unreachable;
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
    const operation_kind = context.manager.operationKind(token) orelse
        return error.StaleOperation;
    if (operation_kind == .create_transfer_destination) {
        const destination = context.manager.destinationDirectory(token.job_id) orelse return error.MissingDestinationDirectory;
        const state = context.manager.groupDestination(token.job_id) orelse return error.MissingGroupDestination;
        const bytes = try context.allocator.alloc(u8, @sizeOf(usize) + destination.len + 1);
        std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], @intFromPtr(state), .little);
        @memcpy(bytes[@sizeOf(usize)..][0..destination.len], destination);
        bytes[bytes.len - 1] = 0;
        return .{ .operation_kind = operation_kind, .input = .{ .allocator = context.allocator, .bytes = bytes } };
    }
    if (operation_kind == .finalize_directories) {
        return .{
            .operation_kind = operation_kind,
            .input = try makeDirectoryFinalizationInput(context, token),
        };
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
            const defers_sync = context.manager.jobDefersSync(token.job_id);
            break :blk if (details.kind == .create_directory)
                try (if (defers_sync) &io_directory.makeDeferredInput else &io_directory.makeInput)(
                    context.allocator,
                    source,
                    destination,
                    details.merge_existing_directory,
                )
            else if (details.replace_existing_file)
                try io_copy.makeReplacementInput(
                    context.allocator,
                    source,
                    destination,
                    token,
                )
            else if (defers_sync)
                try io_copy.makeDeferredInput(context.allocator, source, destination, token)
            else
                try io_copy.makeInput(context.allocator, source, destination, token);
        },
        .copy_symlink => blk: {
            const destination = try context.manager.destinationPath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(destination);
            const make = if (context.manager.jobDefersSync(token.job_id))
                &io_symlink.makeDeferredInput
            else
                &io_symlink.makeInput;
            break :blk try make(
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
            break :blk try io_move.makeInputWithPolicy(
                context.allocator,
                source,
                destination,
                context.manager.jobRenamesOnly(token.job_id),
            );
        },
        else => return error.UnsupportedOperation,
    };

    return .{
        .operation_kind = details.kind,
        .input = input,
    };
}

fn makeDirectoryFinalizationInput(
    context: *Context,
    token: io_manager.WorkToken,
) !io_executor.OwnedPayload {
    const records = context.manager.directoryPermissionRecords(token.job_id) orelse
        return error.UnknownJob;
    const owned_records = try context.allocator.alloc(io_finalize.Record, records.len);
    defer context.allocator.free(owned_records);
    var initialized: usize = 0;
    defer {
        for (owned_records[0..initialized]) |record|
            context.allocator.free(record.path);
    }

    for (records) |record| {
        const path = try context.manager.destinationPath(
            context.allocator,
            token.job_id,
            record.entry_id,
        );
        owned_records[initialized] = .{
            .path = path,
            .device_id = record.device_id,
            .inode_id = record.inode_id,
            .mode = record.mode,
        };
        initialized += 1;
    }
    // A copy or extraction syncs its destination once here instead of every
    // new file, folder and link.
    const sync_directory = if (context.manager.jobDefersSync(token.job_id))
        context.manager.destinationDirectory(token.job_id)
    else
        null;
    return io_finalize.makeInputWithSync(context.allocator, owned_records, sync_directory);
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

    try context.archive_cancellations.ensureUnusedCapacity(context.allocator, 1);
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

    const ledger_handle = try context.ledger.register(
        token.job_id,
        .archive_cancellation,
        .operation_executor,
    );
    errdefer context.ledger.release(
        ledger_handle,
        .operation_executor,
    ) catch unreachable;
    context.archive_cancellations.putAssumeCapacity(token.job_id, .{
        .cancel = cancel,
        .ledger_handle = ledger_handle,
    });

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
    if (builtin.is_test and (item.operation_kind == .copy_file or item.operation_kind == .create_transfer_destination)) test_gate.maybePark();
    return switch (item.operation_kind) {
        .create_directory => io_directory.execute(context.allocator, item),
        .create_transfer_destination => createTransferDestination(item),
        .copy_file => io_copy.execute(context.allocator, item),
        .copy_symlink => io_symlink.execute(context.allocator, item),
        .move_entry => io_move.execute(context.allocator, item),
        .finalize_directories => executeDirectoryFinalization(context.allocator, item),
        .detach_source => io_detach.execute(context.allocator, item),
        .archive_extract, .archive_member_extract => executeArchive(context.allocator, item),
        else => failWork(item),
    };
}

fn createTransferDestination(item: io_executor.WorkItem) io_executor.WorkCompletion {
    const bytes = item.input.slice();
    const state: *io_manager.GroupDestination = @ptrFromInt(std.mem.readInt(usize, bytes[0..@sizeOf(usize)], .little));
    const path = bytes[@sizeOf(usize) .. bytes.len - 1 :0];
    var completion = failWork(item);
    if (state.cancelled.load(.acquire)) {
        completion.outcome = .cancelled;
        return completion;
    }
    ops.createFolderPath(path) catch |err| {
        state.error_code.store(@backingInt(@import("io_coordinator_codes.zig").rejectionCode(err)), .release);
        return completion;
    };
    completion.outcome = .completed;
    return completion;
}

/// Parks the next copy or transfer-destination creation on its worker
/// until the test releases it. Compiled out of non-test builds.
pub const test_gate = if (builtin.is_test) struct {
    pub var armed: std.atomic.Value(bool) = .init(false);
    pub var parked: std.atomic.Value(bool) = .init(false);
    pub var released: std.atomic.Value(bool) = .init(false);

    pub fn arm() void {
        parked.store(false, .release);
        released.store(false, .release);
        armed.store(true, .release);
    }

    pub fn release() void {
        armed.store(false, .release);
        released.store(true, .release);
    }

    fn maybePark() void {
        if (armed.cmpxchgStrong(true, false, .acq_rel, .monotonic) != null) return;
        parked.store(true, .release);
        while (!released.load(.acquire)) _ = std.posix.system.poll(&.{}, 0, 1);
    }
} else struct {};

fn executeDirectoryFinalization(
    allocator: Allocator,
    item_arg: io_executor.WorkItem,
) io_executor.WorkCompletion {
    const item = item_arg;
    const stats = io_finalize.execute(allocator, &item.input) catch
        return failWork(item);
    return .{
        .token = item.token,
        .outcome = if (stats.failed == 0) .completed else .failed,
        .operation_kind = item.operation_kind,
        .input = item.input,
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

fn accept(
    raw_context: ?*anyopaque,
    token: io_manager.WorkToken,
    operation_kind: ?io_manager.OperationKind,
    outcome: io_manager.WorkResult,
    result: ?*const io_executor.OwnedPayload,
) anyerror!void {
    if (outcome != .completed or operation_kind != .create_directory)
        return;

    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    const payload = result orelse return error.MissingDirectoryPermissionResult;
    const permission = io_directory.permissionResult(payload) orelse
        return error.InvalidDirectoryPermissionResult;
    const details = context.manager.operationDetails(token) orelse
        return error.StaleOperation;

    try context.manager.registerDirectoryPermission(token, .{
        .entry_id = details.entry_id,
        .device_id = permission.device_id,
        .inode_id = permission.inode_id,
        .mode = permission.mode,
        .origin = if (permission.origin == .created) .created else .merged,
    });
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
            releaseArchiveCancellation(context, token.job_id);
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
                context.archive_staging.ensureUnusedCapacity(
                    context.allocator,
                    1,
                ) catch {
                    ops.deleteRecursive(context.allocator, path) catch {};
                    context.allocator.free(path);
                    context.manager.failWaiting(token.job_id, token.operation_id) catch {};
                    return;
                };
                const ledger_handle = context.ledger.register(
                    token.job_id,
                    .archive_staging,
                    .operation_executor,
                ) catch {
                    ops.deleteRecursive(context.allocator, path) catch {};
                    context.allocator.free(path);
                    context.manager.failWaiting(token.job_id, token.operation_id) catch {};
                    return;
                };
                const lease = ArchiveStagingLease{
                    .allocator = context.allocator,
                    .token = token,
                    .path = path,
                    .ledger_handle = ledger_handle,
                };
                context.archive_staging.putAssumeCapacity(key, lease);
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
                    if (context.archive_cancellations.get(job_id)) |lease| {
                        if (@intFromPtr(lease.cancel) == cancel_address) {
                            _ = context.archive_cancellations.fetchRemove(job_id).?;
                            context.allocator.destroy(lease.cancel);
                            context.ledger.release(
                                lease.ledger_handle,
                                .operation_executor,
                            ) catch unreachable;
                        }
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

    var ledger = io_resource_ledger.Ledger.init(allocator);
    defer ledger.deinit();
    var context: Context = .{
        .allocator = allocator,
        .manager = &manager,
        .ledger = &ledger,
    };
    defer context.archive_cancellations.deinit(allocator);

    const first = try allocator.create(archive.Cancel);
    first.* = .init(false);
    const first_handle = try ledger.register(1, .archive_cancellation, .operation_executor);
    const second = try allocator.create(archive.Cancel);
    second.* = .init(false);
    const second_handle = try ledger.register(2, .archive_cancellation, .operation_executor);
    try context.archive_cancellations.put(allocator, 1, .{
        .cancel = first,
        .ledger_handle = first_handle,
    });
    try context.archive_cancellations.put(allocator, 2, .{
        .cancel = second,
        .ledger_handle = second_handle,
    });

    requestArchiveCancellation(&context);

    try std.testing.expect(first.load(.acquire));
    try std.testing.expect(second.load(.acquire));
    releaseArchiveCancellation(&context, 1);
    releaseArchiveCancellation(&context, 2);
}

test "archive completion releases its cancellation handle" {
    const allocator = std.testing.allocator;
    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();

    var ledger = io_resource_ledger.Ledger.init(allocator);
    defer ledger.deinit();
    var context: Context = .{
        .allocator = allocator,
        .manager = &manager,
        .ledger = &ledger,
    };
    defer context.archive_cancellations.deinit(allocator);

    const cancel = try allocator.create(archive.Cancel);
    cancel.* = .init(false);
    const handle = try ledger.register(42, .archive_cancellation, .operation_executor);
    try context.archive_cancellations.put(allocator, 42, .{
        .cancel = cancel,
        .ledger_handle = handle,
    });

    releaseArchiveCancellation(&context, 42);

    try std.testing.expect(!context.archive_cancellations.contains(42));
    try std.testing.expect(ledger.isJobEmpty(42));
}

test "operation executor physically deletes released archive staging" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    _ = try std.fmt.bufPrint(
        &temp_buffer,
        "/tmp/rediwm_archive_release_XXXXXX\x00",
        .{},
    );
    const temp_ptr = c.mkdtemp(@ptrCast(&temp_buffer)) orelse
        return error.MkdtempFailed;
    const temp_path = std.mem.span(@as([*:0]const u8, @ptrCast(temp_ptr)));
    const temp_z = try allocator.dupeSentinel(u8, temp_path, 0);
    defer allocator.free(temp_z);
    defer _ = c.rmdir(temp_z);

    var manager = io_manager.Manager.init(allocator);
    defer manager.deinit();
    const job_id = try manager.createJob(null);
    try manager.queueJob(job_id);
    const state = manager.jobState(job_id) orelse return error.UnknownJob;
    if (!state.isTerminal()) return error.EmptyJobDidNotComplete;

    var ledger = io_resource_ledger.Ledger.init(allocator);
    defer ledger.deinit();
    var runtime = try Runtime.initWithLedger(
        allocator,
        &manager,
        &ledger,
        1,
        1,
    );
    defer runtime.deinit();

    const handle = try ledger.register(
        job_id,
        .archive_staging,
        .operation_executor,
    );
    const path = try allocator.dupe(u8, temp_path);
    try runtime.context.archive_staging.put(allocator, .{
        .job_id = job_id,
        .operation_id = 1,
    }, .{
        .allocator = allocator,
        .token = undefined,
        .path = path,
        .ledger_handle = handle,
    });

    try runtime.releaseResource(handle);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, -1), c.lstat(temp_z, &stat));
    try std.testing.expect(ledger.ownerOf(handle) == null);
    try std.testing.expect(ledger.isJobEmpty(job_id));
    try std.testing.expectError(
        error.UnknownResource,
        runtime.releaseResource(handle),
    );
}
