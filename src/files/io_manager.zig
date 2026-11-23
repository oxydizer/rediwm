//! Application-wide model and deterministic scheduler for Files I/O Jobs.
//!
//! This layer is main-thread-owned. Worker threads and filesystem execution are
//! deliberately added in later phases.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_tree = @import("io_tree.zig");
const io_discovery = @import("io_discovery.zig");
const archive = @import("archive.zig");

pub const JobId = u64;
pub const OperationId = u64;
pub const WindowId = u64;
pub const ConflictId = u64;

pub const ConflictView = struct {
    id: ConflictId,
    job_id: JobId,
    operation_id: OperationId,
    entry_id: io_tree.EntryId,
    source_path: []const u8,
    destination_path: []const u8,
    source_kind: io_tree.EntryKind,
    destination_kind: io_tree.EntryKind,
};

const Conflict = struct {
    id: ConflictId,
    job_id: JobId,
    operation_id: OperationId,
    entry_id: io_tree.EntryId,
    source_path: []u8,
    destination_path: []u8,
    source_kind: io_tree.EntryKind,
    destination_kind: io_tree.EntryKind,

    fn view(self: *const Conflict) ConflictView {
        return .{
            .id = self.id,
            .job_id = self.job_id,
            .operation_id = self.operation_id,
            .entry_id = self.entry_id,
            .source_path = self.source_path,
            .destination_path = self.destination_path,
            .source_kind = self.source_kind,
            .destination_kind = self.destination_kind,
        };
    }

    fn deinit(self: *Conflict, allocator: Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.destination_path);
    }
};

pub const DiscoveryToken = struct {
    job_id: JobId,
    entry_id: io_tree.EntryId,
    generation: u64,
};

/// One selected directory root to schedule as part of an atomic Job commit.
pub const DiscoveryRoot = struct {
    root_id: io_tree.EntryId,
    path: []const u8,
};

pub const DiscoveryPriority = enum {
    foreground,
    promoted,
    background,
};

const DiscoverySchedule = struct {
    priority: DiscoveryPriority,
    version: u64,
};

const DiscoveryQueueItem = struct {
    job_id: JobId,
    entry_id: io_tree.EntryId,
    version: u64,
};

const DiscoveryQueue = struct {
    items: std.ArrayList(DiscoveryQueueItem) = .empty,
    head: usize = 0,

    fn deinit(self: *DiscoveryQueue, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    fn consumeHead(self: *DiscoveryQueue) void {
        self.head += 1;
        if (self.head >= self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 64 and self.head * 2 >= self.items.items.len) {
            const remaining = self.items.items.len - self.head;
            std.mem.copyForwards(
                DiscoveryQueueItem,
                self.items.items[0..remaining],
                self.items.items[self.head..],
            );
            self.items.items.len = remaining;
            self.head = 0;
        }
    }
};

const ReadyQueue = struct {
    head: ?usize = null,
    tail: ?usize = null,
    count: usize = 0,
};

pub const JobState = enum {
    planning,
    queued,
    running,
    finalizing,
    paused,
    waiting,
    completed,
    completed_with_errors,
    failed,
    cancelled,

    pub fn isTerminal(self: JobState) bool {
        return switch (self) {
            .completed, .completed_with_errors, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const OperationKind = enum {
    create_directory,
    copy_file,
    copy_symlink,
    move_entry,
    finalize_directories,
    publish,
    detach_source,
    purge_source,
    archive_extract,
    archive_member_extract,
};

/// Borrowed input for registering a job-level archive extraction operation.
/// The Manager copies every supplied path before returning.
pub const ArchiveOperationRequest = struct {
    source_path: []const u8,
    staging_parent: []const u8,
    member_path: ?[]const u8 = null,
    member_paths: []const []const u8 = &.{},
};

/// One top-level entry produced by archive extraction. The Manager copies
/// the source path and stores the entry in its owned TreeIndex.
pub const ArchivePublicationRootRequest = struct {
    name: []const u8,
    source_path: []const u8,
    kind: io_tree.EntryKind,
    metadata: io_tree.Metadata = .{},
    symlink_target: ?[]const u8 = null,
};

/// Immutable archive request details for a current dispatched operation.
/// The returned slices remain Manager-owned.
pub const ArchiveOperationDetails = struct {
    kind: OperationKind,
    source_path: []const u8,
    staging_parent: []const u8,
    member_path: ?[]const u8,
    member_paths: []const []const u8,
};

const OwnedArchiveOperationRequest = struct {
    source_path: []const u8,
    staging_parent: []const u8,
    member_path: ?[]const u8,
    member_paths: []const []const u8,

    fn deinit(self: *OwnedArchiveOperationRequest, allocator: Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.staging_parent);
        if (self.member_path) |path| allocator.free(path);
        for (self.member_paths) |path| allocator.free(path);
        allocator.free(self.member_paths);
    }
};

pub const OperationState = enum {
    pending,
    running,
    waiting,
    completed,
    skipped,
    failed,
    cancelled,

    pub fn isTerminal(self: OperationState) bool {
        return switch (self) {
            .completed, .skipped, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const WorkToken = struct {
    job_id: JobId,
    operation_id: OperationId,
    generation: u64,
};

pub const WorkResult = enum {
    yielded,
    completed,
    waiting,
    skipped,
    failed,
    cancelled,
};

pub const CopyPhase = enum {
    transferring,
    flushing,
};

/// Per-operation copy measurements accumulated from accepted worker units.
/// Counters are always collected; elapsed-time fields are opt-in.
pub const CopyMetrics = struct {
    reflink_attempts: u64 = 0,
    reflink_successes: u64 = 0,
    reflink_bytes: u64 = 0,
    reflink_fallbacks: u64 = 0,
    copy_file_range_calls: u64 = 0,
    copy_file_range_bytes: u64 = 0,
    copy_file_range_fallbacks: u64 = 0,
    buffered_read_calls: u64 = 0,
    buffered_read_bytes: u64 = 0,
    buffered_write_calls: u64 = 0,
    buffered_write_bytes: u64 = 0,
    fallback_exdev: u64 = 0,
    fallback_unsupported: u64 = 0,
    fallback_permission: u64 = 0,
    reflink_ns: u64 = 0,
    copy_file_range_ns: u64 = 0,
    buffered_ns: u64 = 0,
    elapsed_ns: u64 = 0,

    pub fn add(self: *CopyMetrics, delta: CopyMetrics) void {
        self.reflink_attempts +|= delta.reflink_attempts;
        self.reflink_successes +|= delta.reflink_successes;
        self.reflink_bytes +|= delta.reflink_bytes;
        self.reflink_fallbacks +|= delta.reflink_fallbacks;
        self.copy_file_range_calls +|= delta.copy_file_range_calls;
        self.copy_file_range_bytes +|= delta.copy_file_range_bytes;
        self.copy_file_range_fallbacks +|= delta.copy_file_range_fallbacks;
        self.buffered_read_calls +|= delta.buffered_read_calls;
        self.buffered_read_bytes +|= delta.buffered_read_bytes;
        self.buffered_write_calls +|= delta.buffered_write_calls;
        self.buffered_write_bytes +|= delta.buffered_write_bytes;
        self.fallback_exdev +|= delta.fallback_exdev;
        self.fallback_unsupported +|= delta.fallback_unsupported;
        self.fallback_permission +|= delta.fallback_permission;
        self.reflink_ns +|= delta.reflink_ns;
        self.copy_file_range_ns +|= delta.copy_file_range_ns;
        self.buffered_ns +|= delta.buffered_ns;
        self.elapsed_ns +|= delta.elapsed_ns;
    }
};

const Operation = struct {
    id: OperationId,
    kind: OperationKind,
    entry_id: ?io_tree.EntryId = null,
    discovery_gate: bool = false,
    population_accounted: bool = false,
    destination_override: ?[]u8 = null,
    archive_request: ?OwnedArchiveOperationRequest = null,
    finalization_queued: bool = false,
    merge_existing_directory: bool = false,
    replace_existing_file: bool = false,
    state: OperationState = .pending,
    generation: u64 = 0,
    progress_bytes: u64 = 0,
    progress_total_bytes: u64 = 0,
    progress_rate_generation: u64 = 0,
    progress_rate_sample_bytes: u64 = 0,
    progress_rate_sample_at_ms: i64 = 0,
    progress_rate_updated_at_ms: i64 = 0,
    progress_bytes_per_second: u64 = 0,
    copy_phase: CopyPhase = .transferring,
    copy_metrics: CopyMetrics = .{},
    dependencies: std.ArrayList(OperationId) = .empty,
    dependency_indices: std.ArrayList(usize) = .empty,
    dependents: std.ArrayList(usize) = .empty,
    unresolved_dependencies: usize = 0,
    ready_previous: ?usize = null,
    ready_next: ?usize = null,
    ready_queued: bool = false,

    fn deinit(self: *Operation, allocator: Allocator) void {
        if (self.destination_override) |path| allocator.free(path);
        if (self.archive_request) |*request| request.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.dependency_indices.deinit(allocator);
        self.dependents.deinit(allocator);
    }
};

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}

fn resetProgressRate(
    operation: *Operation,
    generation: u64,
    bytes: u64,
    sample_at: i64,
) void {
    operation.progress_rate_generation = generation;
    operation.progress_rate_sample_bytes = bytes;
    operation.progress_rate_sample_at_ms = sample_at;
    operation.progress_rate_updated_at_ms = 0;
    operation.progress_bytes_per_second = 0;
}

fn updateProgressRate(
    operation: *Operation,
    generation: u64,
    bytes: u64,
    phase: CopyPhase,
    sample_at: i64,
) void {
    // Execution generations advance for every yielded worker unit. They
    // identify stale work, not a new transfer, so preserve the sampling
    // window across ordinary redispatches.
    operation.progress_rate_generation = generation;

    if (phase != .transferring or
        operation.progress_rate_sample_at_ms == 0 or
        sample_at < operation.progress_rate_sample_at_ms or
        bytes < operation.progress_rate_sample_bytes)
    {
        resetProgressRate(operation, generation, bytes, sample_at);
    } else if (sample_at > operation.progress_rate_sample_at_ms and
        sample_at - operation.progress_rate_sample_at_ms >= 500)
    {
        const elapsed_ms = sample_at - operation.progress_rate_sample_at_ms;
        const transferred = bytes -| operation.progress_rate_sample_bytes;
        const rate = (@as(u128, transferred) * 1000) /
            @as(u128, @intCast(elapsed_ms));
        const max_rate: u128 = std.math.maxInt(u64);
        operation.progress_bytes_per_second = @intCast(@min(rate, max_rate));
        operation.progress_rate_sample_bytes = bytes;
        operation.progress_rate_sample_at_ms = sample_at;
        operation.progress_rate_updated_at_ms = sample_at;
    }
}

fn currentProgressRate(operation: *const Operation, now: i64) u64 {
    const updated_at = operation.progress_rate_updated_at_ms;
    if (updated_at <= 0 or now < updated_at or now - updated_at > 1500) return 0;
    if (operation.state != .pending and operation.state != .running) return 0;
    if (operation.copy_phase != .transferring) return 0;
    return operation.progress_bytes_per_second;
}

const Job = struct {
    id: JobId,
    origin_window_id: ?WindowId,
    state: JobState = .planning,
    tree: io_tree.TreeIndex,
    source_root_paths: std.AutoHashMapUnmanaged(io_tree.EntryId, []u8) = .empty,
    discovery_started: bool = false,
    auto_plan_discovered_entries: bool = false,
    auto_move_discovered_entries: bool = false,
    archive_publication_closed: bool = false,
    archive_publication_failed: bool = false,
    pause_requested: bool = false,
    cancel_requested: bool = false,
    destination_directory: ?[]u8 = null,
    destination_device_id: ?u64 = null,
    discovery_schedule: std.AutoHashMapUnmanaged(io_tree.EntryId, DiscoverySchedule) = .empty,
    skipped_subtrees: std.AutoHashMapUnmanaged(io_tree.EntryId, void) = .empty,
    discovery_pending_count: usize = 0,
    outstanding_population_count: usize = 0,
    directory_permission_records: std.ArrayList(DirectoryPermissionRecord) = .empty,
    discovery_generation: u64 = 0,
    discovery_in_flight: ?DiscoveryToken = null,
    operations: std.ArrayList(Operation) = .empty,
    operation_indices: std.AutoHashMapUnmanaged(OperationId, usize) = .empty,
    entry_operation_indices: std.AutoHashMapUnmanaged(io_tree.EntryId, usize) = .empty,
    source_detach_indices: std.AutoHashMapUnmanaged(io_tree.EntryId, usize) = .empty,
    ready_queues: [3]ReadyQueue = .{ .{}, .{}, .{} },
    ready_count: usize = 0,
    flushing_operation_count: usize = 0,
    directory_finalization_index: ?usize = null,
    dependency_work_queue: std.ArrayList(usize) = .empty,
    operation_state_counts: [7]usize = .{ 0, 0, 0, 0, 0, 0, 0 },

    fn deinit(self: *Job, allocator: Allocator) void {
        var source_path_iter = self.source_root_paths.valueIterator();
        while (source_path_iter.next()) |path| allocator.free(path.*);
        self.source_root_paths.deinit(allocator);
        if (self.destination_directory) |path| allocator.free(path);
        self.discovery_schedule.deinit(allocator);
        self.skipped_subtrees.deinit(allocator);
        self.directory_permission_records.deinit(allocator);
        self.tree.deinit();
        for (self.operations.items) |*operation| operation.deinit(allocator);
        self.operations.deinit(allocator);
        self.operation_indices.deinit(allocator);
        self.entry_operation_indices.deinit(allocator);
        self.source_detach_indices.deinit(allocator);
        self.dependency_work_queue.deinit(allocator);
    }
};

pub const OperationSnapshot = struct {
    id: OperationId,
    kind: OperationKind,
    state: OperationState,
    generation: u64,
    dependencies: []OperationId,
    copy_metrics: CopyMetrics,
};

pub const OperationDetails = struct {
    kind: OperationKind,
    entry_id: io_tree.EntryId,
    merge_existing_directory: bool,
    replace_existing_file: bool,
};

pub const DirectoryPermissionOrigin = enum {
    created,
    merged,
};

pub const DirectoryPermissionRecord = struct {
    entry_id: io_tree.EntryId,
    device_id: u64,
    inode_id: u64,
    mode: u32,
    origin: DirectoryPermissionOrigin,
};

pub const EntryOperationView = struct {
    state: OperationState,
    generation: u64,
    progress_bytes: u64,
    progress_total_bytes: u64,
    progress_bytes_per_second: u64,
    copy_phase: CopyPhase,
};

/// Caller-owned copy; it remains valid independently of the live manager.
pub const JobSnapshot = struct {
    allocator: Allocator,
    id: JobId,
    origin_window_id: ?WindowId,
    state: JobState,
    operations: []OperationSnapshot,

    pub fn deinit(self: *JobSnapshot) void {
        for (self.operations) |operation| self.allocator.free(operation.dependencies);
        self.allocator.free(self.operations);
    }
};

const PreferredOperation = struct {
    job_id: JobId,
    operation_id: OperationId,
};

pub const Manager = struct {
    allocator: Allocator,
    jobs: std.ArrayList(Job) = .empty,
    next_job_id: JobId = 1,
    next_operation_id: OperationId = 1,
    round_robin_cursor: usize = 0,
    preferred_operation: ?PreferredOperation = null,
    discovery_queues: [3]DiscoveryQueue = .{ .{}, .{}, .{} },
    discovery_schedule_slot: usize = 0,
    conflicts: std.ArrayList(Conflict) = .empty,
    conflict_head: usize = 0,
    conflict_operation_ids: std.AutoHashMapUnmanaged(OperationId, void) = .empty,
    next_conflict_id: ConflictId = 1,

    pub fn init(allocator: Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.jobs.items) |*job| job.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        for (&self.discovery_queues) |*queue| queue.deinit(self.allocator);
        for (self.conflicts.items[self.conflict_head..]) |*conflict|
            conflict.deinit(self.allocator);
        self.conflicts.deinit(self.allocator);
        self.conflict_operation_ids.deinit(self.allocator);
    }

    pub fn createJob(self: *Manager, origin_window_id: ?WindowId) !JobId {
        if (self.next_job_id == std.math.maxInt(JobId)) return error.IdExhausted;
        const id = self.next_job_id;
        try self.jobs.append(self.allocator, .{
            .id = id,
            .origin_window_id = origin_window_id,
            .tree = io_tree.TreeIndex.init(self.allocator),
        });
        self.next_job_id += 1;
        return id;
    }

    /// Discards a Job whose planning has not been committed to the scheduler.
    /// Any queued discovery records become harmless stale queue entries.
    pub fn discardPlanningJob(self: *Manager, job_id: JobId) bool {
        for (self.jobs.items, 0..) |*job, index| {
            if (job.id != job_id) continue;
            if (job.state != .planning or job.discovery_in_flight != null)
                return false;
            if (job.discovery_started) return false;

            var removed = self.jobs.orderedRemove(index);
            removed.deinit(self.allocator);

            if (self.jobs.items.len == 0) {
                self.round_robin_cursor = 0;
            } else {
                if (self.round_robin_cursor > index)
                    self.round_robin_cursor -= 1;
                if (self.round_robin_cursor >= self.jobs.items.len)
                    self.round_robin_cursor = 0;
            }
            return true;
        }
        return false;
    }

    /// Stores the selected destination directory. The Manager owns a copy;
    /// entry paths are constructed from this directory and TreeIndex names.
    pub fn setDestinationDirectory(
        self: *Manager,
        job_id: JobId,
        destination_directory: []const u8,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (job.tree.root() == null) {
            var has_archive_operation = false;
            for (job.operations.items) |operation| {
                if (operation.kind == .archive_extract or
                    operation.kind == .archive_member_extract)
                {
                    has_archive_operation = true;
                    break;
                }
            }
            if (!has_archive_operation) return error.MissingTreeRoot;
        }
        if (job.destination_directory != null)
            return error.DestinationDirectoryAlreadySet;
        if (destination_directory.len == 0 or
            !std.fs.path.isAbsolute(destination_directory) or
            std.mem.indexOfScalar(u8, destination_directory, 0) != null)
        {
            return error.InvalidDestinationDirectory;
        }

        job.destination_directory = try self.allocator.dupe(u8, destination_directory);
    }

    /// Stores the destination filesystem identity captured by the App.
    /// The Manager does not perform filesystem queries.
    pub fn setDestinationDeviceId(
        self: *Manager,
        job_id: JobId,
        device_id: u64,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (job.destination_directory == null)
            return error.DestinationDirectoryNotSet;
        if (job.destination_device_id != null)
            return error.DestinationDeviceAlreadySet;
        job.destination_device_id = device_id;
    }

    pub fn destinationDeviceId(self: *Manager, job_id: JobId) ?u64 {
        const job = self.findJob(job_id) orelse return null;
        return job.destination_device_id;
    }

    /// Adds the source root to a Job's Manager-owned TreeIndex.
    pub fn addTreeRoot(
        self: *Manager,
        job_id: JobId,
        name: []const u8,
        kind: io_tree.EntryKind,
        metadata: io_tree.Metadata,
        symlink_target: ?[]const u8,
    ) !io_tree.EntryId {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        return job.tree.addRoot(name, kind, metadata, symlink_target);
    }

    /// Adds one discovered child to the Job's Manager-owned TreeIndex.
    pub fn addTreeEntry(
        self: *Manager,
        job_id: JobId,
        parent_id: io_tree.EntryId,
        name: []const u8,
        kind: io_tree.EntryKind,
        metadata: io_tree.Metadata,
        symlink_target: ?[]const u8,
    ) !io_tree.EntryId {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        return job.tree.addEntry(parent_id, name, kind, metadata, symlink_target);
    }

    /// Compatibility wrapper for the first root in a single-root Job.
    pub fn startDiscovery(
        self: *Manager,
        job_id: JobId,
        root_path: []const u8,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const root_id = job.tree.root() orelse return error.MissingTreeRoot;
        try self.startRootDiscovery(job_id, root_id, root_path);
    }

    /// Enables automatic operation registration for entries adopted from
    /// subsequent discovery batches. The selected root operation is still
    /// registered explicitly by the caller before the Job is queued.
    pub fn enableDiscoveredEntryOperations(
        self: *Manager,
        job_id: JobId,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (job.tree.root() == null) return error.MissingTreeRoot;
        if (job.auto_move_discovered_entries)
            return error.DiscoveryOperationModeAlreadySet;
        job.auto_plan_discovered_entries = true;
    }

    /// Enables incremental move planning. Every selected directory root
    /// must already have both its destination-creation and source-detach
    /// operations registered. Discovered descendants receive the matching
    /// operation pair automatically.
    pub fn enableDiscoveredEntryMoves(
        self: *Manager,
        job_id: JobId,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (job.tree.root() == null) return error.MissingTreeRoot;
        if (job.auto_plan_discovered_entries)
            return error.DiscoveryOperationModeAlreadySet;

        for (job.tree.roots()) |root_id| {
            const root = job.tree.get(root_id) orelse return error.UnknownEntry;
            if (root.kind != .directory) return error.RootNotDirectory;
            const destination_index = job.entry_operation_indices.get(root_id) orelse
                return error.MissingRootDirectoryOperation;
            if (job.operations.items[destination_index].kind != .create_directory)
                return error.InvalidRootDirectoryOperation;
            if (!job.source_detach_indices.contains(root_id))
                return error.MissingRootSourceDetachOperation;
        }
        job.auto_move_discovered_entries = true;
    }

    /// Starts incremental discovery for one directory root. Each selected
    /// root has an independent source path and contributes to the Job's
    /// shared discovery-pending count.
    pub fn startRootDiscovery(
        self: *Manager,
        job_id: JobId,
        root_id: io_tree.EntryId,
        root_path: []const u8,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (root_path.len == 0 or
            !std.fs.path.isAbsolute(root_path) or
            std.mem.indexOfScalar(u8, root_path, 0) != null)
        {
            return error.InvalidRootPath;
        }

        if (!job.tree.isRoot(root_id)) return error.EntryNotRoot;
        const root = job.tree.get(root_id) orelse return error.UnknownEntry;
        if (root.kind != .directory) return error.RootNotDirectory;
        if (root.discovery != .unscanned) return error.DiscoveryAlreadyStarted;

        var owned_path: ?[]u8 = null;
        if (job.source_root_paths.get(root_id)) |existing| {
            if (!std.mem.eql(u8, existing, root_path))
                return error.SourceRootPathMismatch;
        } else {
            owned_path = try self.allocator.dupe(u8, root_path);
        }
        errdefer if (owned_path) |path| self.allocator.free(path);
        if (owned_path != null)
            try job.source_root_paths.ensureUnusedCapacity(self.allocator, 1);
        try job.discovery_schedule.ensureUnusedCapacity(self.allocator, 1);
        const queue = &self.discovery_queues[@backingInt(DiscoveryPriority.background)];
        try queue.items.ensureUnusedCapacity(self.allocator, 1);

        if (owned_path) |path|
            job.source_root_paths.putAssumeCapacity(root_id, path);
        job.discovery_started = true;
        root.discovery = .queued;
        job.discovery_schedule.putAssumeCapacity(root_id, .{
            .priority = .background,
            .version = 1,
        });
        queue.items.appendAssumeCapacity(.{
            .job_id = job_id,
            .entry_id = root_id,
            .version = 1,
        });
        job.discovery_pending_count += 1;
    }

    /// Returns the Manager-owned path for one selected root.
    pub fn discoveryRootPath(
        self: *const Manager,
        job_id: JobId,
        root_id: io_tree.EntryId,
    ) ?[]const u8 {
        const job = self.findJobConst(job_id) orelse return null;
        if (!job.discovery_started) return null;
        return job.source_root_paths.get(root_id);
    }

    /// Stores the original path for one selected root, including roots that
    /// do not need directory discovery, such as standalone files or links.
    pub fn setRootSourcePath(
        self: *Manager,
        job_id: JobId,
        root_id: io_tree.EntryId,
        source_root_path: []const u8,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (!job.tree.isRoot(root_id)) return error.EntryNotRoot;
        if (job.source_root_paths.contains(root_id))
            return error.SourceRootPathAlreadySet;
        if (source_root_path.len == 0 or
            !std.fs.path.isAbsolute(source_root_path) or
            std.mem.indexOfScalar(u8, source_root_path, 0) != null)
        {
            return error.InvalidSourceRootPath;
        }

        const owned_path = try self.allocator.dupe(u8, source_root_path);
        errdefer self.allocator.free(owned_path);
        try job.source_root_paths.ensureUnusedCapacity(self.allocator, 1);
        job.source_root_paths.putAssumeCapacity(root_id, owned_path);
    }

    /// Compatibility wrapper for the first root in a single-root Job.
    pub fn setSourceRootPath(
        self: *Manager,
        job_id: JobId,
        source_root_path: []const u8,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const root_id = job.tree.root() orelse return error.MissingTreeRoot;
        try self.setRootSourcePath(job_id, root_id, source_root_path);
    }

    /// Builds the absolute destination path for one TreeIndex entry.
    /// The root entry's display name is appended to the selected destination
    /// directory. The caller owns the returned path.
    pub fn destinationPath(
        self: *const Manager,
        allocator: Allocator,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) ![]u8 {
        const job = self.findJobConst(job_id) orelse return error.UnknownJob;
        const destination_directory = job.destination_directory orelse
            return error.MissingDestinationDirectory;

        // A renamed directory redirects its destination subtree without
        // changing TreeIndex names or source paths.
        var ancestor_id: ?io_tree.EntryId = entry_id;
        while (ancestor_id) |id| {
            if (job.entry_operation_indices.get(id)) |operation_index| {
                if (job.operations.items[operation_index].destination_override) |override| {
                    const target_relative = try job.tree.relativePath(allocator, entry_id);
                    defer allocator.free(target_relative);
                    const ancestor_relative = try job.tree.relativePath(allocator, id);
                    defer allocator.free(ancestor_relative);
                    const suffix = if (std.mem.eql(u8, target_relative, ancestor_relative))
                        ""
                    else if (std.mem.startsWith(u8, target_relative, ancestor_relative) and
                        target_relative.len > ancestor_relative.len and
                        target_relative[ancestor_relative.len] == '/')
                        target_relative[ancestor_relative.len + 1 ..]
                    else
                        return error.InvalidTreePath;
                    if (suffix.len == 0) return allocator.dupe(u8, override);
                    return std.fs.path.join(allocator, &.{ override, suffix });
                }
            }
            const entry = job.tree.getConst(id) orelse return error.UnknownEntry;
            ancestor_id = entry.parent_id;
        }

        const relative_path = try job.tree.relativePath(allocator, entry_id);
        defer allocator.free(relative_path);
        return std.fs.path.join(allocator, &.{
            destination_directory,
            relative_path,
        });
    }

    /// Dispatches one bounded directory batch using the global 2:1:1
    /// foreground/promoted/background schedule.
    pub fn dispatchDiscovery(self: *Manager) ?DiscoveryToken {
        const schedule = [_]DiscoveryPriority{
            .foreground,
            .foreground,
            .promoted,
            .background,
        };

        for (0..schedule.len) |offset| {
            const slot = (self.discovery_schedule_slot + offset) % schedule.len;
            if (self.dispatchDiscoveryFrom(schedule[slot])) |token| {
                self.discovery_schedule_slot = (slot + 1) % schedule.len;
                return token;
            }
        }
        return null;
    }

    fn dispatchDiscoveryFrom(
        self: *Manager,
        priority: DiscoveryPriority,
    ) ?DiscoveryToken {
        const queue = &self.discovery_queues[@backingInt(priority)];
        var index = queue.head;

        while (index < queue.items.items.len) {
            const candidate = queue.items.items[index];
            const job = self.findJob(candidate.job_id) orelse {
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            };
            const scheduled = job.discovery_schedule.get(candidate.entry_id) orelse {
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            };
            if (scheduled.version != candidate.version or scheduled.priority != priority) {
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            }
            const entry = job.tree.get(candidate.entry_id) orelse {
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            };
            if (entry.discovery != .queued) {
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            }
            if (!job.discovery_started or job.state == .paused or
                job.discovery_in_flight != null)
            {
                index += 1;
                continue;
            }
            if (job.state.isTerminal()) {
                entry.discovery = .skipped;
                job.discovery_pending_count -= 1;
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            }
            if (job.discovery_generation == std.math.maxInt(u64)) {
                entry.discovery = .failed;
                job.discovery_pending_count -= 1;
                if (index == queue.head) {
                    queue.consumeHead();
                    index = queue.head;
                } else {
                    index += 1;
                }
                continue;
            }

            if (index != queue.head) {
                std.mem.swap(
                    DiscoveryQueueItem,
                    &queue.items.items[queue.head],
                    &queue.items.items[index],
                );
            }
            queue.consumeHead();
            job.discovery_pending_count -= 1;
            job.discovery_generation += 1;
            const token: DiscoveryToken = .{
                .job_id = job.id,
                .entry_id = candidate.entry_id,
                .generation = job.discovery_generation,
            };
            entry.discovery = .scanning;
            job.discovery_in_flight = token;
            return token;
        }

        return null;
    }

    /// Adds a new queued directory to its priority queue.
    fn enqueueDiscovery(
        self: *Manager,
        job: *Job,
        entry_id: io_tree.EntryId,
        priority: DiscoveryPriority,
    ) !void {
        const queue = &self.discovery_queues[@backingInt(priority)];
        try queue.items.ensureUnusedCapacity(self.allocator, 1);
        try job.discovery_schedule.ensureUnusedCapacity(self.allocator, 1);

        const previous = job.discovery_schedule.get(entry_id);
        const version = if (previous) |value| blk: {
            if (value.version == std.math.maxInt(u64))
                return error.DiscoveryScheduleExhausted;
            break :blk value.version + 1;
        } else 1;

        job.discovery_schedule.putAssumeCapacity(entry_id, .{
            .priority = priority,
            .version = version,
        });
        queue.items.appendAssumeCapacity(.{
            .job_id = job.id,
            .entry_id = entry_id,
            .version = version,
        });
        job.discovery_pending_count += 1;
    }

    /// Makes this directory the foreground scan and promotes its currently
    /// discovered descendant directories into the promoted-subtree queue.
    pub fn prioritizeDiscovery(
        self: *Manager,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) !void {
        try self.setDiscoverySubtreePriority(job_id, entry_id, .foreground);
    }

    /// Promotes a directory and all currently discovered descendant
    /// directories without changing their scan positions.
    pub fn promoteDiscoverySubtree(
        self: *Manager,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) !void {
        try self.setDiscoverySubtreePriority(job_id, entry_id, .promoted);
    }

    fn setDiscoverySubtreePriority(
        self: *Manager,
        job_id: JobId,
        root_id: io_tree.EntryId,
        root_priority: DiscoveryPriority,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const root = job.tree.get(root_id) orelse return error.UnknownEntry;
        if (root.kind != .directory) return error.EntryNotDirectory;

        var stack: std.ArrayList(io_tree.EntryId) = .empty;
        defer stack.deinit(self.allocator);
        var directories: std.ArrayList(io_tree.EntryId) = .empty;
        defer directories.deinit(self.allocator);
        try stack.append(self.allocator, root_id);

        while (stack.items.len > 0) {
            const current_id = stack.pop().?;
            const current = job.tree.get(current_id) orelse continue;
            if (current.kind != .directory) continue;
            try directories.append(self.allocator, current_id);
            for (current.children.items) |child_id| {
                const child = job.tree.get(child_id) orelse continue;
                if (child.kind == .directory)
                    try stack.append(self.allocator, child_id);
            }
        }

        var queue_counts = [_]usize{ 0, 0, 0 };
        for (directories.items, 0..) |directory_id, index| {
            const priority = if (index == 0) root_priority else .promoted;
            const current = job.discovery_schedule.get(directory_id);
            if (current) |value| {
                if (value.priority == priority) continue;
                if (value.version == std.math.maxInt(u64))
                    return error.DiscoveryScheduleExhausted;
            }
            if (job.tree.get(directory_id).?.discovery == .queued)
                queue_counts[@backingInt(priority)] += 1;
        }

        try job.discovery_schedule.ensureUnusedCapacity(
            self.allocator,
            @intCast(directories.items.len),
        );
        for (&self.discovery_queues, 0..) |*queue, index| {
            try queue.items.ensureUnusedCapacity(self.allocator, queue_counts[index]);
        }

        for (directories.items, 0..) |directory_id, index| {
            const priority = if (index == 0) root_priority else .promoted;
            const current = job.discovery_schedule.get(directory_id);
            if (current) |value| {
                if (value.priority == priority) continue;
            }
            const version = if (current) |value| value.version + 1 else 1;
            job.discovery_schedule.putAssumeCapacity(directory_id, .{
                .priority = priority,
                .version = version,
            });
            if (job.tree.get(directory_id).?.discovery == .queued) {
                self.discovery_queues[@backingInt(priority)].items.appendAssumeCapacity(.{
                    .job_id = job_id,
                    .entry_id = directory_id,
                    .version = version,
                });
                if (current == null) job.discovery_pending_count += 1;
            }
        }
    }

    /// Returns a dispatched discovery entry to the queue when the worker
    /// pool cannot accept it. The next dispatch receives a fresh generation.
    pub fn yieldDiscovery(self: *Manager, token: DiscoveryToken) bool {
        const job = self.findJob(token.job_id) orelse return false;
        const active = job.discovery_in_flight orelse return false;
        if (active.entry_id != token.entry_id or
            active.generation != token.generation)
            return false;

        const entry = job.tree.get(token.entry_id) orelse return false;
        if (entry.discovery != .scanning) return false;

        if (isWithinSkippedSubtree(job, token.entry_id)) {
            entry.discovery = .skipped;
            job.discovery_in_flight = null;
            self.recomputeJobState(job);
            return false;
        }

        const priority = job.discovery_schedule.get(token.entry_id) orelse return false;
        self.enqueueDiscovery(job, token.entry_id, priority.priority) catch {
            entry.discovery = .failed;
            job.discovery_in_flight = null;
            return false;
        };
        entry.discovery = .queued;
        job.discovery_in_flight = null;
        return true;
    }

    /// Adopts a worker-produced batch when its token is still current.
    /// On success the batch is consumed and deinitialized.
    /// On a stale token the caller retains ownership of the batch.
    pub fn completeDiscovery(
        self: *Manager,
        token: DiscoveryToken,
        batch: *io_discovery.Batch,
    ) !bool {
        const job = self.findJob(token.job_id) orelse return false;
        const active = job.discovery_in_flight orelse return false;
        if (active.entry_id != token.entry_id or
            active.generation != token.generation)
            return false;

        const parent = job.tree.get(token.entry_id) orelse return false;
        if (parent.discovery != .scanning) return false;
        if (isWithinSkippedSubtree(job, token.entry_id)) {
            parent.discovery = .skipped;
            job.discovery_in_flight = null;
            batch.deinit();
            self.recomputeJobState(job);
            return true;
        }

        const parent_device_id = parent.metadata.device_id;

        var new_directories: usize = 0;
        for (batch.records.items) |record| {
            if (record.kind == .directory and
                !record.entry_error and
                (!job.auto_move_discovered_entries or
                    !directoryCrossesDeviceBoundary(parent_device_id, record.metadata.device_id)))
            {
                new_directories += 1;
            }
        }
        const parent_priority = job.discovery_schedule.get(token.entry_id) orelse
            return error.MissingDiscoverySchedule;
        const child_priority: DiscoveryPriority =
            if (parent_priority.priority == .background) .background else .promoted;
        try job.discovery_schedule.ensureUnusedCapacity(self.allocator, @intCast(new_directories));
        try self.discovery_queues[@backingInt(child_priority)].items.ensureUnusedCapacity(
            self.allocator,
            new_directories,
        );
        if (!batch.complete) {
            if (parent_priority.version == std.math.maxInt(u64))
                return error.DiscoveryScheduleExhausted;
            try self.discovery_queues[@backingInt(parent_priority.priority)].items.ensureUnusedCapacity(
                self.allocator,
                1,
            );
        }

        for (batch.records.items) |record| {
            // A symlink whose target could not be read cannot be represented
            // as a valid symlink TreeIndex entry. Retain it as an errored
            // non-directory entry instead.
            const invalid_symlink =
                record.kind == .symlink and record.symlink_target == null;
            const kind: io_tree.EntryKind =
                if (invalid_symlink) .other else record.kind;
            const crosses_directory_boundary =
                job.auto_move_discovered_entries and
                kind == .directory and
                !record.entry_error and
                directoryCrossesDeviceBoundary(parent_device_id, record.metadata.device_id);

            const child_id = try job.tree.addEntry(
                token.entry_id,
                record.name,
                kind,
                record.metadata,
                if (kind == .symlink) record.symlink_target else null,
            );

            if (job.auto_move_discovered_entries) {
                if (record.entry_error or invalid_symlink or kind == .other) {
                    self.failSourceDetach(job, token.entry_id);
                } else if (crosses_directory_boundary) {
                    // Never traverse or detach a directory mounted from a
                    // different filesystem. Preserve it and its contents.
                    self.failSourceDetach(job, token.entry_id);
                } else {
                    const completion_operation_id: ?OperationId = switch (kind) {
                        .directory => blk: {
                            _ = try self.addEntryOperation(
                                job.id,
                                child_id,
                                .create_directory,
                            );
                            break :blk try self.addEntryOperation(
                                job.id,
                                child_id,
                                .detach_source,
                            );
                        },
                        .regular_file => blk: {
                            const source_device_id = record.metadata.device_id orelse {
                                self.failSourceDetach(job, token.entry_id);
                                break :blk null;
                            };
                            const destination_device_id = job.destination_device_id orelse {
                                self.failSourceDetach(job, token.entry_id);
                                break :blk null;
                            };
                            if (source_device_id == destination_device_id) {
                                break :blk try self.addEntryOperation(
                                    job.id,
                                    child_id,
                                    .move_entry,
                                );
                            }
                            _ = try self.addEntryOperation(
                                job.id,
                                child_id,
                                .copy_file,
                            );
                            break :blk try self.addEntryOperation(
                                job.id,
                                child_id,
                                .detach_source,
                            );
                        },
                        .symlink => blk: {
                            const source_device_id = record.metadata.device_id orelse {
                                self.failSourceDetach(job, token.entry_id);
                                break :blk null;
                            };
                            const destination_device_id = job.destination_device_id orelse {
                                self.failSourceDetach(job, token.entry_id);
                                break :blk null;
                            };
                            if (source_device_id == destination_device_id) {
                                break :blk try self.addEntryOperation(
                                    job.id,
                                    child_id,
                                    .move_entry,
                                );
                            }
                            _ = try self.addEntryOperation(
                                job.id,
                                child_id,
                                .copy_symlink,
                            );
                            break :blk try self.addEntryOperation(
                                job.id,
                                child_id,
                                .detach_source,
                            );
                        },
                        .other => unreachable,
                    };
                    if (completion_operation_id) |operation_id| {
                        try self.addSourceDetachDependency(
                            job,
                            token.entry_id,
                            operation_id,
                        );
                    }
                }
            } else if (job.auto_plan_discovered_entries and
                !record.entry_error and
                !invalid_symlink)
            {
                const operation_kind: ?OperationKind = switch (kind) {
                    .directory => .create_directory,
                    .regular_file => .copy_file,
                    .symlink => .copy_symlink,
                    .other => null,
                };
                if (operation_kind) |operation|
                    _ = try self.addEntryOperation(job.id, child_id, operation);
            }

            if (record.kind == .directory and
                !record.entry_error and
                !crosses_directory_boundary)
            {
                const child = job.tree.get(child_id).?;
                child.discovery = .queued;
                job.discovery_schedule.putAssumeCapacity(child_id, .{
                    .priority = child_priority,
                    .version = 1,
                });
                self.discovery_queues[@backingInt(child_priority)].items.appendAssumeCapacity(.{
                    .job_id = job.id,
                    .entry_id = child_id,
                    .version = 1,
                });
                job.discovery_pending_count += 1;
            } else if (crosses_directory_boundary) {
                job.tree.get(child_id).?.discovery = .skipped;
            } else if (record.entry_error or invalid_symlink) {
                job.tree.get(child_id).?.discovery = .failed;
            }
        }

        // Reacquire this pointer after TreeIndex mutations, which may
        // reallocate its entry array.
        const updated_parent = job.tree.get(token.entry_id).?;
        job.discovery_in_flight = null;

        if (batch.complete) {
            updated_parent.discovery = .complete;
            self.releaseSourceDetachDiscoveryGate(job, token.entry_id);
        } else {
            const version = parent_priority.version + 1;
            job.discovery_schedule.putAssumeCapacity(token.entry_id, .{
                .priority = parent_priority.priority,
                .version = version,
            });
            self.discovery_queues[@backingInt(parent_priority.priority)].items.appendAssumeCapacity(.{
                .job_id = job.id,
                .entry_id = token.entry_id,
                .version = version,
            });
            job.discovery_pending_count += 1;
            updated_parent.discovery = .queued;
        }

        batch.deinit();
        self.recomputeJobState(job);
        return true;
    }

    /// Reconciles a worker-side cursor open/read failure.
    pub fn failDiscovery(self: *Manager, token: DiscoveryToken) bool {
        const job = self.findJob(token.job_id) orelse return false;
        const active = job.discovery_in_flight orelse return false;
        if (active.entry_id != token.entry_id or
            active.generation != token.generation)
            return false;

        if (isWithinSkippedSubtree(job, token.entry_id)) {
            if (job.tree.get(token.entry_id)) |entry|
                entry.discovery = .skipped;
            job.discovery_in_flight = null;
            self.recomputeJobState(job);
            return true;
        }

        if (job.tree.get(token.entry_id)) |entry|
            entry.discovery = .failed;
        self.failSourceDetach(job, token.entry_id);
        job.discovery_in_flight = null;
        self.recomputeJobState(job);
        return true;
    }

    pub fn discoveryComplete(
        self: *const Manager,
        job_id: JobId,
    ) ?bool {
        const job = self.findJobConst(job_id) orelse return null;
        if (!job.discovery_started) return null;
        for (job.tree.roots()) |root_id| {
            const root = job.tree.getConst(root_id) orelse continue;
            if (root.kind == .directory and root.discovery == .unscanned)
                return false;
        }
        return job.discovery_in_flight == null and job.discovery_pending_count == 0;
    }

    /// Read-only access; callers must retain EntryIds, not pointers into the
    /// backing array, across any subsequent TreeIndex mutation.
    pub fn treeIndex(self: *const Manager, job_id: JobId) ?*const io_tree.TreeIndex {
        const job = self.findJobConst(job_id) orelse return null;
        return &job.tree;
    }

    /// Returns the TreeIndex entry associated with a dispatched or waiting
    /// operation. Stale generations and terminal operations are rejected.
    pub fn operationDetails(self: *const Manager, token: WorkToken) ?OperationDetails {
        const job = self.findJobConst(token.job_id) orelse return null;
        const operation = findOperationConst(job, token.operation_id) orelse return null;
        if ((operation.state != .running and operation.state != .waiting) or
            operation.generation != token.generation)
            return null;
        return .{
            .kind = operation.kind,
            .entry_id = operation.entry_id orelse return null,
            .merge_existing_directory = operation.merge_existing_directory,
            .replace_existing_file = operation.replace_existing_file,
        };
    }

    /// Returns the kind of a currently running operation without requiring
    /// it to have a TreeIndex entry.
    pub fn operationKind(self: *const Manager, token: WorkToken) ?OperationKind {
        const job = self.findJobConst(token.job_id) orelse return null;
        const operation = findOperationConst(job, token.operation_id) orelse return null;
        if (operation.state != .running or operation.generation != token.generation)
            return null;
        return operation.kind;
    }

    pub fn registerDirectoryPermission(
        self: *Manager,
        token: WorkToken,
        record: DirectoryPermissionRecord,
    ) !void {
        const job = self.findJob(token.job_id) orelse return error.StaleWork;
        const operation = findOperation(job, token.operation_id) orelse
            return error.StaleWork;
        if (operation.state != .running or
            operation.generation != token.generation or
            operation.kind != .create_directory or
            operation.entry_id != record.entry_id)
            return error.StaleWork;

        if (record.mode > 0o777 or
            (record.origin == .merged) != operation.merge_existing_directory)
            return error.InvalidDirectoryPermissionRecord;

        for (job.directory_permission_records.items) |existing| {
            if (existing.entry_id == record.entry_id)
                return error.DuplicateDirectoryPermissionRecord;
        }

        const needs_finalizer = job.directory_finalization_index == null;
        if (needs_finalizer) {
            if (self.next_operation_id == std.math.maxInt(OperationId))
                return error.IdExhausted;
            const operation_index = job.operations.items.len;
            try job.operations.ensureUnusedCapacity(self.allocator, 1);
            try job.operation_indices.ensureUnusedCapacity(self.allocator, 1);
            try job.dependency_work_queue.ensureTotalCapacity(
                self.allocator,
                operation_index + 1,
            );
        }
        try job.directory_permission_records.ensureUnusedCapacity(self.allocator, 1);
        if (needs_finalizer) {
            _ = try self.addOperationInternal(job, .finalize_directories);
        }
        job.directory_permission_records.appendAssumeCapacity(record);
    }

    pub fn directoryPermissionRecords(
        self: *const Manager,
        job_id: JobId,
    ) ?[]const DirectoryPermissionRecord {
        const job = self.findJobConst(job_id) orelse return null;
        return job.directory_permission_records.items;
    }

    /// Returns the Manager-owned request for a current archive operation.
    /// Job-level archive work deliberately has no TreeIndex entry.
    pub fn archiveOperationDetails(
        self: *const Manager,
        token: WorkToken,
    ) ?ArchiveOperationDetails {
        const job = self.findJobConst(token.job_id) orelse return null;
        const operation = findOperationConst(job, token.operation_id) orelse return null;
        if ((operation.state != .running and operation.state != .waiting) or
            operation.generation != token.generation)
            return null;
        if (operation.kind != .archive_extract and
            operation.kind != .archive_member_extract)
            return null;
        const request = operation.archive_request orelse return null;
        return .{
            .kind = operation.kind,
            .source_path = request.source_path,
            .staging_parent = request.staging_parent,
            .member_path = request.member_path,
            .member_paths = request.member_paths,
        };
    }

    /// Closes registration of archive publication roots. Already-scheduled
    /// directory discovery may still register its descendants.
    pub fn closeArchivePublication(self: *Manager, token: WorkToken) !void {
        const job = self.findJob(token.job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, token.operation_id) orelse
            return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;
        if (operation.generation != token.generation) return error.StaleWorkToken;
        if (operation.kind != .archive_extract and
            operation.kind != .archive_member_extract)
            return error.InvalidOperationKind;
        if (job.archive_publication_closed)
            return error.ArchivePublicationAlreadyClosed;

        job.archive_publication_closed = true;
    }

    /// Closes archive root registration after a main-thread publication
    /// error. Already registered operations still drain before the barrier
    /// becomes terminal, so their staging sources remain valid.
    pub fn failArchivePublication(self: *Manager, token: WorkToken) !void {
        const job = self.findJob(token.job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, token.operation_id) orelse
            return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;
        if (operation.generation != token.generation) return error.StaleWorkToken;
        if (operation.kind != .archive_extract and
            operation.kind != .archive_member_extract)
            return error.InvalidOperationKind;
        if (job.archive_publication_closed)
            return error.ArchivePublicationAlreadyClosed;

        job.archive_publication_failed = true;
        job.archive_publication_closed = true;
    }

    /// Reports whether every publication operation and directory scan has
    /// reached a terminal state after root registration was closed.
    pub fn archivePublicationReady(
        self: *const Manager,
        token: WorkToken,
    ) ?bool {
        const job = self.findJobConst(token.job_id) orelse return null;
        const barrier = findOperationConst(job, token.operation_id) orelse return null;
        if (barrier.state != .waiting or barrier.generation != token.generation)
            return null;
        if (barrier.kind != .archive_extract and
            barrier.kind != .archive_member_extract)
            return null;
        if (!job.archive_publication_closed) return false;
        if (job.discovery_pending_count != 0 or job.discovery_in_flight != null)
            return false;
        if (job.outstanding_population_count != 0) return false;

        var remaining = nonterminalOperationCount(job);
        std.debug.assert(remaining != 0);
        remaining -= 1; // Archive publication barrier.
        if (job.directory_finalization_index) |finalizer_index| {
            if (!job.operations.items[finalizer_index].state.isTerminal()) {
                std.debug.assert(remaining != 0);
                remaining -= 1;
            }
        }
        return remaining == 0;
    }

    /// Reports whether all destination-population operations and directory
    /// discovery work have drained. Unknown jobs return null.
    pub fn populationComplete(
        self: *const Manager,
        job_id: JobId,
    ) ?bool {
        const job = self.findJobConst(job_id) orelse return null;
        return job.outstanding_population_count == 0 and
            job.discovery_pending_count == 0 and
            job.discovery_in_flight == null;
    }

    /// Completes the archive barrier only after publication registration,
    /// directory discovery, and every other operation have drained.
    pub fn completeArchivePublication(self: *Manager, token: WorkToken) bool {
        if (self.archivePublicationReady(token) != true) return false;
        const job = self.findJob(token.job_id) orelse return false;
        const operation = findOperation(job, token.operation_id) orelse return false;
        transitionOperation(
            job,
            operation,
            if (job.archive_publication_failed) .failed else .completed,
        );
        self.recomputeJobState(job);
        return true;
    }

    /// Builds the source path for one TreeIndex entry from the original
    /// selected root path. The root's display name is not appended twice.
    pub fn sourcePath(
        self: *const Manager,
        allocator: Allocator,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) ![]u8 {
        const job = self.findJobConst(job_id) orelse return error.UnknownJob;
        const root_id = job.tree.rootForEntry(entry_id) orelse
            return error.UnknownEntry;
        const root_path = job.source_root_paths.get(root_id) orelse
            return error.MissingSourceRootPath;
        const root = job.tree.getConst(root_id) orelse return error.MissingTreeRoot;
        const relative_path = try job.tree.relativePath(allocator, entry_id);
        defer allocator.free(relative_path);

        if (entry_id == root_id) return allocator.dupe(u8, root_path);
        if (relative_path.len <= root.name.len or
            !std.mem.eql(u8, relative_path[0..root.name.len], root.name) or
            relative_path[root.name.len] != '/')
        {
            return error.InvalidTreePath;
        }

        return std.fs.path.join(allocator, &.{
            root_path,
            relative_path[root.name.len + 1 ..],
        });
    }

    pub fn addOperation(self: *Manager, job_id: JobId, kind: OperationKind) !OperationId {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (kind == .archive_extract or kind == .archive_member_extract)
            return error.ArchiveRequestRequired;
        return self.addOperationInternal(job, kind);
    }

    /// Registers a job-level archive extraction operation. Archive paths are
    /// owned by the Manager; workers receive them through archiveOperationDetails().
    pub fn addArchiveOperation(
        self: *Manager,
        job_id: JobId,
        kind: OperationKind,
        request: ArchiveOperationRequest,
    ) !OperationId {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (kind != .archive_extract and kind != .archive_member_extract)
            return error.InvalidOperationKind;
        if (job.auto_move_discovered_entries)
            return error.DiscoveryOperationModeAlreadySet;
        for (job.operations.items) |existing| {
            if (existing.kind == .archive_extract or
                existing.kind == .archive_member_extract)
                return error.ArchiveOperationAlreadyRegistered;
        }

        if (!std.fs.path.isAbsolute(request.source_path) or
            request.source_path.len == 0 or
            std.mem.indexOfScalar(u8, request.source_path, 0) != null)
            return error.InvalidArchiveSourcePath;
        if (!std.fs.path.isAbsolute(request.staging_parent) or
            request.staging_parent.len == 0 or
            std.mem.indexOfScalar(u8, request.staging_parent, 0) != null)
            return error.InvalidArchiveStagingParent;

        if (kind == .archive_member_extract) {
            if (request.member_path == null or request.member_paths.len != 0)
                return error.InvalidArchiveMemberPath;
        } else if (request.member_path != null) {
            return error.InvalidArchiveMemberPath;
        }

        var owned_member: ?[]const u8 = null;
        errdefer if (owned_member) |path| self.allocator.free(path);
        if (request.member_path) |member_path| {
            const normalized = try archive.normalize(self.allocator, member_path);
            owned_member = normalized;
            if (normalized.len == 0) return error.InvalidArchiveMemberPath;
        }

        var normalized_members: std.ArrayList([]const u8) = .empty;
        defer normalized_members.deinit(self.allocator);
        var selected_members: std.StringHashMapUnmanaged(void) = .empty;
        defer selected_members.deinit(self.allocator);
        errdefer {
            for (normalized_members.items) |path| self.allocator.free(path);
        }
        for (request.member_paths) |member_path| {
            const normalized = try archive.normalize(self.allocator, member_path);
            errdefer self.allocator.free(normalized);
            if (normalized.len == 0) return error.InvalidArchiveMemberPath;
            const slot = try selected_members.getOrPut(self.allocator, normalized);
            if (slot.found_existing) return error.InvalidArchiveMemberPath;
            slot.value_ptr.* = {};
            try normalized_members.append(self.allocator, normalized);
        }

        const owned_members = try normalized_members.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_members) |path| self.allocator.free(path);
            self.allocator.free(owned_members);
        }

        const source_copy = try self.allocator.dupe(u8, request.source_path);
        errdefer self.allocator.free(source_copy);
        const staging_copy = try self.allocator.dupe(u8, request.staging_parent);
        errdefer self.allocator.free(staging_copy);

        const operation_id = try self.addOperationInternal(job, kind);
        const operation = &job.operations.items[job.operations.items.len - 1];
        operation.archive_request = .{
            .source_path = source_copy,
            .staging_parent = staging_copy,
            .member_path = owned_member,
            .member_paths = owned_members,
        };
        owned_member = null;
        job.auto_plan_discovered_entries = true;
        return operation_id;
    }

    /// Registers one extracted archive root while its archive barrier is
    /// waiting. Directory descendants are discovered and planned normally.
    pub fn addArchivePublicationRoot(
        self: *Manager,
        token: WorkToken,
        request: ArchivePublicationRootRequest,
    ) !io_tree.EntryId {
        const job = self.findJob(token.job_id) orelse return error.UnknownJob;
        const barrier = findOperation(job, token.operation_id) orelse
            return error.UnknownOperation;
        if (barrier.state != .waiting) return error.InvalidOperationState;
        if (barrier.generation != token.generation) return error.StaleWorkToken;
        if (barrier.kind != .archive_extract and
            barrier.kind != .archive_member_extract)
            return error.InvalidOperationKind;
        if (job.archive_publication_closed)
            return error.ArchivePublicationAlreadyClosed;
        if (job.state.isTerminal()) return error.InvalidJobState;
        if (job.destination_directory == null)
            return error.DestinationDirectoryNotSet;
        if (request.source_path.len == 0 or
            !std.fs.path.isAbsolute(request.source_path) or
            std.mem.indexOfScalar(u8, request.source_path, 0) != null)
        {
            return error.InvalidSourceRootPath;
        }
        if (request.kind == .other) return error.UnsupportedEntryKind;
        if (self.next_operation_id == std.math.maxInt(OperationId))
            return error.IdExhausted;

        const operation_kind: OperationKind = switch (request.kind) {
            .directory => .create_directory,
            .regular_file => .copy_file,
            .symlink => .copy_symlink,
            .other => unreachable,
        };
        if (job.outstanding_population_count == std.math.maxInt(usize))
            return error.PopulationCountExhausted;

        const operation_index = job.operations.items.len;
        try job.source_root_paths.ensureUnusedCapacity(self.allocator, 1);
        try job.operations.ensureUnusedCapacity(self.allocator, 1);
        try job.operation_indices.ensureUnusedCapacity(self.allocator, 1);
        try job.entry_operation_indices.ensureUnusedCapacity(self.allocator, 1);
        try job.dependency_work_queue.ensureTotalCapacity(
            self.allocator,
            operation_index + 1,
        );
        if (request.kind == .directory) {
            try job.discovery_schedule.ensureUnusedCapacity(self.allocator, 1);
            try self.discovery_queues[@backingInt(DiscoveryPriority.background)]
                .items.ensureUnusedCapacity(self.allocator, 1);
        }

        var owned_source_path: ?[]u8 =
            try self.allocator.dupe(u8, request.source_path);
        errdefer if (owned_source_path) |path| self.allocator.free(path);

        const root_id = try job.tree.addRoot(
            request.name,
            request.kind,
            request.metadata,
            request.symlink_target,
        );
        job.source_root_paths.putAssumeCapacity(root_id, owned_source_path.?);
        owned_source_path = null;

        const operation_id = try self.addOperationInternal(job, operation_kind);
        const registered_operation = &job.operations.items[operation_index];
        registered_operation.entry_id = root_id;
        registered_operation.population_accounted = true;
        job.outstanding_population_count += 1;
        job.entry_operation_indices.putAssumeCapacity(root_id, operation_index);

        if (request.kind == .directory) {
            const root = job.tree.get(root_id).?;
            root.discovery = .queued;
            job.discovery_started = true;
            job.discovery_schedule.putAssumeCapacity(root_id, .{
                .priority = .background,
                .version = 1,
            });
            self.discovery_queues[@backingInt(DiscoveryPriority.background)]
                .items.appendAssumeCapacity(.{
                    .job_id = job.id,
                    .entry_id = root_id,
                    .version = 1,
                });
            job.discovery_pending_count += 1;
        }

        std.debug.assert(registered_operation.id == operation_id);
        return root_id;
    }

    fn addOperationInternal(self: *Manager, job: *Job, kind: OperationKind) !OperationId {
        if (job.state.isTerminal()) return error.InvalidJobState;
        if (self.next_operation_id == std.math.maxInt(OperationId)) return error.IdExhausted;

        const id = self.next_operation_id;
        const index = job.operations.items.len;
        try job.operations.ensureUnusedCapacity(self.allocator, 1);
        try job.operation_indices.ensureUnusedCapacity(self.allocator, 1);
        if (job.state != .planning) {
            // Dynamic discovery can add operations after queueJob(). Keep
            // enough room for every operation to become ready, including
            // dependents released together by a completed parent.
            try job.dependency_work_queue.ensureTotalCapacity(
                self.allocator,
                index + 1,
            );
        }
        job.operations.appendAssumeCapacity(.{ .id = id, .kind = kind });
        job.operation_indices.putAssumeCapacity(id, index);
        if (kind == .finalize_directories) {
            std.debug.assert(job.directory_finalization_index == null);
            job.directory_finalization_index = index;
        }
        self.next_operation_id += 1;
        if (job.state != .planning) {
            job.operation_state_counts[@backingInt(OperationState.pending)] += 1;
            if (kind != .finalize_directories) enqueueReady(job, index);
            self.recomputeJobState(job);
        }
        return id;
    }

    /// Adds the operation for one discovered TreeIndex entry. A child entry
    /// automatically waits for its destination parent directory operation.
    pub fn addEntryOperation(
        self: *Manager,
        job_id: JobId,
        entry_id: io_tree.EntryId,
        kind: OperationKind,
    ) !OperationId {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state.isTerminal()) return error.InvalidJobState;
        const entry = job.tree.get(entry_id) orelse return error.UnknownEntry;
        const is_source_detach = kind == .detach_source;
        if (is_source_detach) {
            if (job.source_detach_indices.contains(entry_id))
                return error.EntryOperationAlreadyExists;
        } else if (job.entry_operation_indices.contains(entry_id)) {
            return error.EntryOperationAlreadyExists;
        }

        const expected_kind: OperationKind = switch (entry.kind) {
            .directory => .create_directory,
            .regular_file => .copy_file,
            .symlink => .copy_symlink,
            .other => return error.UnsupportedEntryKind,
        };
        const valid_kind = switch (entry.kind) {
            .directory => kind == .create_directory or kind == .detach_source,
            .regular_file, .symlink => kind == expected_kind or
                kind == .move_entry or kind == .detach_source,
            .other => false,
        };
        if (!valid_kind) {
            return error.InvalidEntryOperationKind;
        }
        const accounts_population = isPopulationOperation(kind);
        if (accounts_population and
            job.outstanding_population_count == std.math.maxInt(usize))
        {
            return error.PopulationCountExhausted;
        }

        var dependency_operation_index: ?usize = null;
        if (is_source_detach) {
            dependency_operation_index = job.entry_operation_indices.get(entry_id) orelse
                return error.MissingSourceOperation;
            if (job.operations.items[dependency_operation_index.?].kind != expected_kind)
                return error.InvalidSourceOperation;
        } else if (entry.parent_id) |parent_id| {
            const parent = job.tree.get(parent_id) orelse return error.UnknownEntry;
            if (parent.kind == .directory) {
                dependency_operation_index = job.entry_operation_indices.get(parent_id) orelse
                    return error.MissingParentDirectoryOperation;
                if (job.operations.items[dependency_operation_index.?].kind != .create_directory)
                    return error.InvalidParentDirectoryOperation;
            }
        }

        var dependencies: std.ArrayList(OperationId) = .empty;
        errdefer dependencies.deinit(self.allocator);
        var dependency_indices: std.ArrayList(usize) = .empty;
        errdefer dependency_indices.deinit(self.allocator);

        if (dependency_operation_index != null) {
            try dependencies.ensureUnusedCapacity(self.allocator, 1);
            try dependency_indices.ensureUnusedCapacity(self.allocator, 1);
        }

        if (is_source_detach) {
            try job.source_detach_indices.ensureUnusedCapacity(self.allocator, 1);
        } else {
            try job.entry_operation_indices.ensureUnusedCapacity(self.allocator, 1);
        }
        if (dependency_operation_index) |dependency_index| {
            const dependency_operation = &job.operations.items[dependency_index];
            try dependency_operation.dependents.ensureUnusedCapacity(self.allocator, 1);
            // Reserve the parent link before inserting this operation, so
            // dependency registration cannot allocate after insertion.
        }

        const operation_id = try self.addOperationInternal(job, kind);
        const operation_index = job.operations.items.len - 1;
        const operation = &job.operations.items[operation_index];
        operation.dependencies = dependencies;
        dependencies = .empty;
        operation.dependency_indices = dependency_indices;
        dependency_indices = .empty;
        operation.entry_id = entry_id;
        operation.discovery_gate = is_source_detach and entry.kind == .directory;
        if (accounts_population) {
            operation.population_accounted = true;
            job.outstanding_population_count += 1;
        }
        if (is_source_detach) {
            job.source_detach_indices.putAssumeCapacity(entry_id, operation_index);
            if (operation.discovery_gate and job.state != .planning) {
                operation.unresolved_dependencies += 1;
                _ = dequeueReadyIndex(job, operation_index);
            }
        } else {
            job.entry_operation_indices.putAssumeCapacity(entry_id, operation_index);
        }

        if (dependency_operation_index) |dependency_index| {
            const dependency_operation = &job.operations.items[dependency_index];
            operation.dependencies.appendAssumeCapacity(dependency_operation.id);
            operation.dependency_indices.appendAssumeCapacity(dependency_index);
            dependency_operation.dependents.appendAssumeCapacity(operation_index);

            if (job.state != .planning) {
                switch (dependency_operation.state) {
                    .completed => {},
                    .failed, .skipped, .cancelled => {
                        _ = dequeueReadyIndex(job, operation_index);
                        transitionOperation(job, operation, .skipped);
                        self.propagateUnmetDependencies(job, operation_index);
                        self.recomputeJobState(job);
                    },
                    else => {
                        operation.unresolved_dependencies += 1;
                        _ = dequeueReadyIndex(job, operation_index);
                    },
                }
            }
        }
        return operation_id;
    }

    fn addSourceDetachDependency(
        self: *Manager,
        job: *Job,
        parent_entry_id: io_tree.EntryId,
        child_operation_id: OperationId,
    ) !void {
        const parent_index = job.source_detach_indices.get(parent_entry_id) orelse
            return error.MissingParentSourceDetachOperation;
        if (job.operations.items[parent_index].state != .pending) return;
        const child_index = findOperationIndex(job, child_operation_id) orelse
            return error.UnknownOperation;
        try self.addDynamicDependency(job, parent_index, child_index);
    }

    /// Adds a dependency discovered after queueJob(). The dependent directory
    /// detach is held behind its discovery gate until its complete child set
    /// has been registered.
    fn addDynamicDependency(
        self: *Manager,
        job: *Job,
        operation_index: usize,
        dependency_index: usize,
    ) !void {
        const operation = &job.operations.items[operation_index];
        const dependency = &job.operations.items[dependency_index];
        for (operation.dependencies.items) |existing| {
            if (existing == dependency.id) return error.DuplicateDependency;
        }

        try operation.dependencies.ensureUnusedCapacity(self.allocator, 1);
        try operation.dependency_indices.ensureUnusedCapacity(self.allocator, 1);
        try dependency.dependents.ensureUnusedCapacity(self.allocator, 1);
        operation.dependencies.appendAssumeCapacity(dependency.id);
        operation.dependency_indices.appendAssumeCapacity(dependency_index);
        dependency.dependents.appendAssumeCapacity(operation_index);

        if (job.state == .planning or operation.state != .pending) return;
        switch (dependency.state) {
            .completed => {},
            .failed, .skipped, .cancelled => {
                _ = dequeueReadyIndex(job, operation_index);
                transitionOperation(job, operation, .skipped);
                self.propagateUnmetDependencies(job, operation_index);
                self.recomputeJobState(job);
            },
            else => {
                operation.unresolved_dependencies += 1;
                _ = dequeueReadyIndex(job, operation_index);
            },
        }
    }

    fn releaseSourceDetachDiscoveryGate(
        self: *Manager,
        job: *Job,
        entry_id: io_tree.EntryId,
    ) void {
        _ = self;
        const operation_index = job.source_detach_indices.get(entry_id) orelse return;
        const operation = &job.operations.items[operation_index];
        if (!operation.discovery_gate) return;
        operation.discovery_gate = false;
        if (job.state == .planning or operation.state != .pending) return;
        std.debug.assert(operation.unresolved_dependencies != 0);
        operation.unresolved_dependencies -= 1;
        if (operation.unresolved_dependencies == 0)
            enqueueReady(job, operation_index);
    }

    fn failSourceDetach(
        self: *Manager,
        job: *Job,
        entry_id: io_tree.EntryId,
    ) void {
        const operation_index = job.source_detach_indices.get(entry_id) orelse return;
        const operation = &job.operations.items[operation_index];
        if (operation.state != .pending) return;
        _ = dequeueReadyIndex(job, operation_index);
        transitionOperation(job, operation, .failed);
        self.propagateUnmetDependencies(job, operation_index);
    }

    /// Missing device identity is treated as a boundary: directory moves
    /// must not descend when the parent/child filesystem relationship is
    /// unknown.
    fn directoryCrossesDeviceBoundary(
        parent_device_id: ?u64,
        child_device_id: ?u64,
    ) bool {
        const parent_device = parent_device_id orelse return true;
        const child_device = child_device_id orelse return true;
        return parent_device != child_device;
    }

    /// Dependencies must refer to Operations in the same Job.
    pub fn addDependency(
        self: *Manager,
        job_id: JobId,
        operation_id: OperationId,
        dependency_id: OperationId,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (operation_id == dependency_id) return error.DependencyCycle;

        const operation = findOperation(job, operation_id) orelse return error.UnknownOperation;
        const dependency_index = findOperationIndex(job, dependency_id) orelse return error.UnknownDependency;
        for (operation.dependencies.items) |existing| {
            if (existing == dependency_id) return error.DuplicateDependency;
        }
        try operation.dependencies.ensureUnusedCapacity(self.allocator, 1);
        try operation.dependency_indices.ensureUnusedCapacity(self.allocator, 1);
        operation.dependencies.appendAssumeCapacity(dependency_id);
        operation.dependency_indices.appendAssumeCapacity(dependency_index);
    }

    pub fn queueJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        try self.prepareJobQueue(job);
        self.commitJobQueue(job);
    }

    /// Atomically schedules all selected directory roots and commits their
    /// Job to the operation queue. No discovery state is changed until every
    /// path, root, allocation, and dependency graph has been validated.
    pub fn queueJobWithDiscoveryRoots(
        self: *Manager,
        job_id: JobId,
        roots: []const DiscoveryRoot,
    ) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (job.discovery_started) return error.DiscoveryAlreadyStarted;
        if (roots.len == 0) return error.MissingDiscoveryRoots;
        if (roots.len > std.math.maxInt(u32))
            return error.DiscoveryCountExhausted;
        if (roots.len > std.math.maxInt(usize) - job.discovery_pending_count)
            return error.DiscoveryCountExhausted;

        // Validate the complete batch before allocating or mutating Manager
        // state. A duplicate root would otherwise schedule the same cursor
        // more than once.
        for (roots, 0..) |root_spec, index| {
            if (root_spec.path.len == 0 or
                !std.fs.path.isAbsolute(root_spec.path) or
                std.mem.indexOfScalar(u8, root_spec.path, 0) != null)
            {
                return error.InvalidRootPath;
            }
            if (!job.tree.isRoot(root_spec.root_id)) return error.EntryNotRoot;
            const root = job.tree.get(root_spec.root_id) orelse
                return error.UnknownEntry;
            if (root.kind != .directory) return error.RootNotDirectory;
            if (root.discovery != .unscanned)
                return error.DiscoveryAlreadyStarted;
            if (job.source_root_paths.contains(root_spec.root_id))
                return error.SourceRootPathAlreadySet;

            for (roots[0..index]) |previous| {
                if (previous.root_id == root_spec.root_id)
                    return error.DuplicateDiscoveryRoot;
            }
        }

        // Stage owned source paths. On any allocation failure, only these
        // temporary allocations are released; the Job remains uncommitted.
        const staged_paths = try self.allocator.alloc([]u8, roots.len);
        var staged_count: usize = 0;
        errdefer {
            for (staged_paths[0..staged_count]) |path|
                self.allocator.free(path);
            self.allocator.free(staged_paths);
        }
        for (roots) |root_spec| {
            staged_paths[staged_count] = try self.allocator.dupe(u8, root_spec.path);
            staged_count += 1;
        }

        // Reserve every container used by the discovery commit.
        const root_capacity: u32 = @intCast(roots.len);
        try job.source_root_paths.ensureUnusedCapacity(self.allocator, root_capacity);
        try job.discovery_schedule.ensureUnusedCapacity(self.allocator, root_capacity);
        const background_queue =
            &self.discovery_queues[@backingInt(DiscoveryPriority.background)];
        try background_queue.items.ensureUnusedCapacity(self.allocator, roots.len);

        // Queue preparation can fail, but it does not change Job state.
        // Its graph allocations are owned by the still-planning Job and are
        // released by discardPlanningJob() if the caller abandons the plan.
        try self.prepareJobQueue(job);

        // Commit: all following operations are allocation-free.
        for (roots, 0..) |root_spec, index| {
            job.source_root_paths.putAssumeCapacity(
                root_spec.root_id,
                staged_paths[index],
            );
            job.discovery_schedule.putAssumeCapacity(root_spec.root_id, .{
                .priority = .background,
                .version = 1,
            });
            background_queue.items.appendAssumeCapacity(.{
                .job_id = job_id,
                .entry_id = root_spec.root_id,
                .version = 1,
            });
            job.tree.get(root_spec.root_id).?.discovery = .queued;
        }
        job.discovery_pending_count += roots.len;
        job.discovery_started = true;
        self.commitJobQueue(job);

        // Ownership of every staged path moved into source_root_paths.
        self.allocator.free(staged_paths);
    }

    fn prepareJobQueue(self: *Manager, job: *Job) !void {
        try buildDependencyGraph(self.allocator, job);
        try validateAcyclic(self.allocator, job);

        var dependency_count: usize = 0;
        for (job.operations.items) |operation| {
            dependency_count += operation.dependency_indices.items.len;
        }
        try job.dependency_work_queue.ensureTotalCapacity(
            self.allocator,
            dependency_count,
        );
    }

    fn commitJobQueue(_: *Manager, job: *Job) void {
        job.dependency_work_queue.clearRetainingCapacity();
        job.ready_queues = .{ .{}, .{}, .{} };
        job.ready_count = 0;
        job.operation_state_counts = .{ 0, 0, 0, 0, 0, 0, 0 };

        for (job.operations.items, 0..) |*operation, index| {
            operation.ready_previous = null;
            operation.ready_next = null;
            operation.ready_queued = false;
            job.operation_state_counts[@backingInt(operation.state)] += 1;
            if (operation.unresolved_dependencies == 0) {
                enqueueReady(job, index);
            }
        }
        job.state = if (job.operations.items.len == 0 and !hasDiscoveryWork(job))
            .completed
        else
            .queued;
    }

    pub fn pauseJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .queued and job.state != .waiting and
            job.state != .running)
        {
            return error.InvalidJobState;
        }
        if (job.operation_state_counts[@backingInt(OperationState.running)] != 0) {
            job.pause_requested = true;
            return;
        }
        job.state = .paused;
    }

    pub fn resumeJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .paused) return error.InvalidJobState;
        job.pause_requested = false;
        job.state = .queued;
        self.recomputeJobState(job);
    }

    pub fn resolveWaiting(self: *Manager, job_id: JobId, operation_id: OperationId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, operation_id) orelse return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;
        const index = findOperationIndex(job, operation_id) orelse return error.UnknownOperation;
        resetProgressRate(
            operation,
            operation.generation,
            operation.progress_bytes,
            monotonicMs(),
        );
        transitionOperation(job, operation, .pending);
        enqueueReady(job, index);
        self.recomputeJobState(job);
    }

    /// Converts a waiting regular-file or symlink move into copy-and-detach
    /// after the worker reports that rename failed with EXDEV.
    ///
    /// The original operation ID is retained. Source detachment is registered
    /// as a dependent, so it cannot run until the replacement copy completes.
    pub fn fallbackMoveToCopy(self: *Manager, token: WorkToken) !OperationId {
        const job = self.findJob(token.job_id) orelse return error.UnknownJob;
        const operation_index = findOperationIndex(job, token.operation_id) orelse
            return error.UnknownOperation;
        const operation = &job.operations.items[operation_index];
        if (operation.state != .waiting) return error.InvalidOperationState;
        if (operation.generation != token.generation) return error.StaleWorkToken;
        if (operation.kind != .move_entry) return error.InvalidOperationKind;

        const entry_id = operation.entry_id orelse return error.OperationEntryMismatch;
        const entry = job.tree.get(entry_id) orelse return error.UnknownEntry;
        const copy_kind: OperationKind = switch (entry.kind) {
            .regular_file => .copy_file,
            .symlink => .copy_symlink,
            else => return error.UnsupportedEntryKind,
        };

        // addEntryOperation() validates and reserves all required storage
        // before mutating the graph. Restore the original kind if it fails.
        job.operations.items[operation_index].kind = copy_kind;
        const detach_operation_id = self.addEntryOperation(
            token.job_id,
            entry_id,
            .detach_source,
        ) catch |err| {
            job.operations.items[operation_index].kind = .move_entry;
            return err;
        };

        // addEntryOperation() may reallocate job.operations; reacquire by
        // index rather than retaining the earlier pointer.
        const copy_operation = &job.operations.items[operation_index];
        transitionOperation(job, copy_operation, .pending);
        enqueueReady(job, operation_index);
        self.recomputeJobState(job);
        return detach_operation_id;
    }

    /// Fails a waiting operation when its external resolution record could
    /// not be created. Dependents must not remain blocked indefinitely.
    pub fn failWaiting(self: *Manager, job_id: JobId, operation_id: OperationId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const operation_index = findOperationIndex(job, operation_id) orelse
            return error.UnknownOperation;
        const operation = &job.operations.items[operation_index];
        if (operation.state != .waiting) return error.InvalidOperationState;

        transitionOperation(job, operation, .failed);
        self.propagateUnmetDependencies(job, operation_index);
        self.pruneInvalidConflicts();
        self.recomputeJobState(job);
    }

    /// Registers a destination conflict for the exact current Operation.
    /// Executor completions have already transitioned it to waiting; direct
    /// callers may still register a running token and let this method wait it.
    pub fn registerConflict(
        self: *Manager,
        token: WorkToken,
        entry_id: io_tree.EntryId,
        source_path: []const u8,
        destination_path: []const u8,
        source_kind: io_tree.EntryKind,
        destination_kind: io_tree.EntryKind,
    ) !ConflictId {
        const job = self.findJob(token.job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, token.operation_id) orelse
            return error.UnknownOperation;
        if ((operation.state != .running and operation.state != .waiting) or
            operation.generation != token.generation)
            return error.StaleWorkToken;
        if (operation.entry_id == null or operation.entry_id.? != entry_id)
            return error.OperationEntryMismatch;
        if (self.next_conflict_id == std.math.maxInt(ConflictId))
            return error.IdExhausted;
        if (source_path.len == 0 or !std.fs.path.isAbsolute(source_path) or
            std.mem.indexOfScalar(u8, source_path, 0) != null)
            return error.InvalidConflictSourcePath;
        if (destination_path.len == 0 or !std.fs.path.isAbsolute(destination_path) or
            std.mem.indexOfScalar(u8, destination_path, 0) != null)
            return error.InvalidConflictDestinationPath;

        if (self.conflict_operation_ids.contains(token.operation_id))
            return error.ConflictAlreadyRegistered;

        const source_copy = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(source_copy);
        const destination_copy = try self.allocator.dupe(u8, destination_path);
        errdefer self.allocator.free(destination_copy);
        try self.conflicts.ensureUnusedCapacity(self.allocator, 1);
        try self.conflict_operation_ids.ensureUnusedCapacity(self.allocator, 1);

        const id = self.next_conflict_id;
        self.conflicts.appendAssumeCapacity(.{
            .id = id,
            .job_id = token.job_id,
            .operation_id = token.operation_id,
            .entry_id = entry_id,
            .source_path = source_copy,
            .destination_path = destination_copy,
            .source_kind = source_kind,
            .destination_kind = destination_kind,
        });
        self.conflict_operation_ids.putAssumeCapacity(token.operation_id, {});
        self.next_conflict_id += 1;

        if (operation.state == .running) {
            // The token was validated above and Manager state is main-thread
            // owned, so this transition cannot become stale between checks.
            std.debug.assert(self.completeWork(token, .waiting));
        }
        return id;
    }

    /// Returns the global FIFO head. The view remains valid until the next
    /// conflict-queue mutation or Manager teardown.
    pub fn nextConflict(self: *const Manager) ?ConflictView {
        if (self.conflict_head >= self.conflicts.items.len) return null;
        return self.conflicts.items[self.conflict_head].view();
    }

    /// Resolves the FIFO head for retry after the caller has applied the
    /// selected filesystem action (Replace, Rename, or Merge).
    pub fn resolveConflict(self: *Manager, conflict_id: ConflictId) !void {
        const conflict = self.conflictHead(conflict_id) orelse
            return error.ConflictNotAtQueueHead;
        const job_id = conflict.job_id;
        const operation_id = conflict.operation_id;
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, operation_id) orelse
            return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;

        self.consumeConflictHead();
        try self.resolveWaiting(job_id, operation_id);
    }

    /// Explicitly accepts an existing destination directory for a
    /// directory-to-directory conflict. The authorization is retained on the
    /// Operation and passed to its next prepared work unit.
    pub fn mergeConflict(self: *Manager, conflict_id: ConflictId) !void {
        const conflict = self.conflictHead(conflict_id) orelse
            return error.ConflictNotAtQueueHead;
        if (conflict.source_kind != .directory or
            conflict.destination_kind != .directory)
            return error.MergeRequiresDirectoryConflict;

        const job = self.findJob(conflict.job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, conflict.operation_id) orelse
            return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;
        if (operation.kind != .create_directory or
            operation.entry_id == null or
            operation.entry_id.? != conflict.entry_id)
            return error.MergeRequiresDirectoryOperation;
        const entry = job.tree.getConst(conflict.entry_id) orelse
            return error.UnknownEntry;
        if (entry.kind != .directory)
            return error.MergeRequiresDirectoryOperation;

        operation.merge_existing_directory = true;
        const job_id = conflict.job_id;
        const operation_id = conflict.operation_id;
        self.consumeConflictHead();
        try self.resolveWaiting(job_id, operation_id);
    }

    /// Explicitly authorizes replacement for a regular-file copy conflict.
    /// An existing regular file or empty directory may be replaced. The
    /// executor verifies directory emptiness before exchanging names.
    pub fn replaceConflict(self: *Manager, conflict_id: ConflictId) !void {
        const conflict = self.conflictHead(conflict_id) orelse
            return error.ConflictNotAtQueueHead;
        if (conflict.source_kind != .regular_file or
            (conflict.destination_kind != .regular_file and
                conflict.destination_kind != .directory))
            return error.ReplaceRequiresRegularFileConflict;

        const job = self.findJob(conflict.job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, conflict.operation_id) orelse
            return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;
        if (operation.kind != .copy_file or
            operation.entry_id == null or
            operation.entry_id.? != conflict.entry_id)
            return error.ReplaceRequiresFileCopyOperation;
        const entry = job.tree.getConst(conflict.entry_id) orelse
            return error.UnknownEntry;
        if (entry.kind != .regular_file)
            return error.ReplaceRequiresFileCopyOperation;

        operation.replace_existing_file = true;
        const job_id = conflict.job_id;
        const operation_id = conflict.operation_id;
        self.consumeConflictHead();
        try self.resolveWaiting(job_id, operation_id);
    }

    /// Assigns a conflict's new destination and retries its operation. The
    /// override also redirects descendants when the conflicted entry is a
    /// directory.
    pub fn renameConflict(
        self: *Manager,
        conflict_id: ConflictId,
        destination_path: []const u8,
    ) !void {
        const conflict = self.conflictHead(conflict_id) orelse
            return error.ConflictNotAtQueueHead;
        if (destination_path.len == 0 or !std.fs.path.isAbsolute(destination_path) or
            std.mem.indexOfScalar(u8, destination_path, 0) != null)
            return error.InvalidConflictDestinationPath;

        const job = self.findJob(conflict.job_id) orelse return error.UnknownJob;
        const operation_index = findOperationIndex(job, conflict.operation_id) orelse
            return error.UnknownOperation;
        const operation = &job.operations.items[operation_index];
        if (operation.state != .waiting) return error.InvalidOperationState;

        const owned_path = try self.allocator.dupe(u8, destination_path);
        if (operation.destination_override) |previous| self.allocator.free(previous);
        operation.destination_override = owned_path;

        const job_id = conflict.job_id;
        const operation_id = conflict.operation_id;
        self.consumeConflictHead();
        try self.resolveWaiting(job_id, operation_id);
    }

    /// Cancels every outstanding operation and discovery cursor in a Job.
    /// A running operation is allowed to finish its current bounded unit;
    /// its continuation is discarded when the result returns.
    pub fn cancelJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state == .planning or job.state.isTerminal())
            return error.InvalidJobState;
        const has_running =
            job.operation_state_counts[@backingInt(OperationState.running)] != 0;
        job.cancel_requested = has_running;
        job.pause_requested = false;
        self.cancelOutstanding(job, has_running);
        job.state = if (has_running) .running else .cancelled;
    }

    fn cancelOutstanding(
        self: *Manager,
        job: *Job,
        keep_running: bool,
    ) void {
        for (job.operations.items) |*operation| {
            if (!(keep_running and operation.state == .running) and
                !operation.state.isTerminal())
            {
                transitionOperation(job, operation, .cancelled);
            }
            operation.ready_previous = null;
            operation.ready_next = null;
            operation.ready_queued = false;
        }
        job.ready_queues = .{ .{}, .{}, .{} };
        job.ready_count = 0;
        job.dependency_work_queue.clearRetainingCapacity();

        for (job.tree.entries.items) |*entry| {
            if (entry.discovery == .queued or entry.discovery == .scanning)
                entry.discovery = .skipped;
        }
        job.discovery_pending_count = 0;
        job.discovery_in_flight = null;
        if (job.discovery_generation != std.math.maxInt(u64))
            job.discovery_generation += 1;

        self.pruneInvalidConflicts();
    }

    /// Cancels the entire Job represented by the current FIFO conflict.
    pub fn cancelConflict(self: *Manager, conflict_id: ConflictId) !void {
        const conflict = self.conflictHead(conflict_id) orelse
            return error.ConflictNotAtQueueHead;
        try self.cancelJob(conflict.job_id);
    }

    /// Skips the FIFO head and its dependent subtree. Any descendant
    /// conflicts made obsolete by dependency propagation are also removed.
    pub fn skipConflict(self: *Manager, conflict_id: ConflictId) !void {
        const conflict = self.conflictHead(conflict_id) orelse
            return error.ConflictNotAtQueueHead;
        const job = self.findJob(conflict.job_id) orelse return error.UnknownJob;
        const operation_index = findOperationIndex(job, conflict.operation_id) orelse
            return error.UnknownOperation;
        const operation = &job.operations.items[operation_index];
        if (operation.state != .waiting) return error.InvalidOperationState;

        var skipped_directory: ?io_tree.EntryId = null;
        if (operation.kind == .create_directory) {
            if (operation.entry_id) |entry_id| {
                if (job.tree.get(entry_id)) |entry| {
                    if (entry.kind == .directory) skipped_directory = entry_id;
                }
            }
        }

        if (skipped_directory) |entry_id| {
            var pending_entries: std.ArrayList(io_tree.EntryId) = .empty;
            defer pending_entries.deinit(self.allocator);
            var subtree_directories: std.ArrayList(io_tree.EntryId) = .empty;
            defer subtree_directories.deinit(self.allocator);
            try pending_entries.append(self.allocator, entry_id);
            while (pending_entries.pop()) |current_id| {
                const entry = job.tree.getConst(current_id) orelse continue;
                if (entry.kind != .directory) continue;
                try subtree_directories.append(self.allocator, current_id);
                try pending_entries.appendSlice(self.allocator, entry.children.items);
            }

            try job.skipped_subtrees.ensureUnusedCapacity(self.allocator, 1);
            job.skipped_subtrees.putAssumeCapacity(entry_id, {});

            // An active scan keeps its token until its bounded result arrives;
            // yieldDiscovery/completeDiscovery then discard it safely.
            for (subtree_directories.items) |directory_id| {
                const entry = job.tree.get(directory_id) orelse continue;
                switch (entry.discovery) {
                    .queued => {
                        std.debug.assert(job.discovery_pending_count != 0);
                        job.discovery_pending_count -= 1;
                        entry.discovery = .skipped;
                    },
                    .unscanned => entry.discovery = .skipped,
                    else => {},
                }
            }
        }

        transitionOperation(job, operation, .skipped);
        self.propagateUnmetDependencies(job, operation_index);

        // A selected root's source-detach operation is gated by discovery,
        // not by its own destination-creation operation. Skip it explicitly
        // so a skipped directory can never be detached from the source.
        if (skipped_directory) |entry_id| {
            if (job.source_detach_indices.get(entry_id)) |detach_index| {
                const detach = &job.operations.items[detach_index];
                if (detach.state == .pending) {
                    _ = dequeueReadyIndex(job, detach_index);
                    transitionOperation(job, detach, .skipped);
                    self.propagateUnmetDependencies(job, detach_index);
                }
            }
        }

        self.consumeConflictHead();
        self.pruneInvalidConflicts();
        self.recomputeJobState(job);
    }

    fn isWithinSkippedSubtree(job: *const Job, entry_id: io_tree.EntryId) bool {
        var current_id: ?io_tree.EntryId = entry_id;
        while (current_id) |id| {
            if (job.skipped_subtrees.contains(id)) return true;
            const entry = job.tree.getConst(id) orelse return false;
            current_id = entry.parent_id;
        }
        return false;
    }

    fn conflictHead(self: *Manager, conflict_id: ConflictId) ?*Conflict {
        if (self.conflict_head >= self.conflicts.items.len) return null;
        const conflict = &self.conflicts.items[self.conflict_head];
        if (conflict.id != conflict_id) return null;
        return conflict;
    }

    fn consumeConflictHead(self: *Manager) void {
        const operation_id = self.conflicts.items[self.conflict_head].operation_id;
        std.debug.assert(self.conflict_operation_ids.remove(operation_id));
        self.conflicts.items[self.conflict_head].deinit(self.allocator);
        self.conflict_head += 1;
        if (self.conflict_head >= self.conflicts.items.len) {
            self.conflicts.clearRetainingCapacity();
            self.conflict_head = 0;
        } else if (self.conflict_head >= 64 and
            self.conflict_head * 2 >= self.conflicts.items.len)
        {
            const remaining = self.conflicts.items.len - self.conflict_head;
            std.mem.copyForwards(
                Conflict,
                self.conflicts.items[0..remaining],
                self.conflicts.items[self.conflict_head..],
            );
            self.conflicts.items.len = remaining;
            self.conflict_head = 0;
        }
    }

    fn pruneInvalidConflicts(self: *Manager) void {
        var read_index = self.conflict_head;
        var write_index = self.conflict_head;
        while (read_index < self.conflicts.items.len) : (read_index += 1) {
            const conflict = &self.conflicts.items[read_index];
            var is_waiting = false;
            if (self.findJobConst(conflict.job_id)) |job| {
                if (job.operation_indices.get(conflict.operation_id)) |operation_index| {
                    is_waiting = job.operations.items[operation_index].state == .waiting;
                }
            }
            if (is_waiting) {
                if (write_index != read_index)
                    self.conflicts.items[write_index] = conflict.*;
                write_index += 1;
                continue;
            }

            std.debug.assert(self.conflict_operation_ids.remove(conflict.operation_id));
            conflict.deinit(self.allocator);
        }
        self.conflicts.items.len = write_index;
        if (self.conflict_head >= self.conflicts.items.len) {
            self.conflicts.clearRetainingCapacity();
            self.conflict_head = 0;
        }
    }

    /// Requests a one-shot preference for a visible queued regular-file copy.
    /// The preference survives pointer leave and waits until the operation
    /// is eligible for dispatch.
    pub fn prioritizeEntryOperation(
        self: *Manager,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) bool {
        const job = self.findJob(job_id) orelse return false;
        const entry = job.tree.getConst(entry_id) orelse return false;
        if (entry.kind != .regular_file) return false;

        const operation_index = job.entry_operation_indices.get(entry_id) orelse
            return false;
        const operation = &job.operations.items[operation_index];
        if (operation.kind != .copy_file or
            operation.entry_id != entry_id or
            (operation.state != .pending and operation.state != .running))
        {
            return false;
        }

        self.preferred_operation = .{
            .job_id = job_id,
            .operation_id = operation.id,
        };
        return true;
    }

    /// Dispatches the preferred operation ahead of normal Job and kind
    /// priority, without bypassing dependencies or per-Job serialization.
    fn dispatchPreferred(self: *Manager) ?WorkToken {
        const preferred = self.preferred_operation orelse return null;

        for (self.jobs.items, 0..) |*job, job_index| {
            if (job.id != preferred.job_id) continue;

            if (job.state.isTerminal()) {
                self.preferred_operation = null;
                return null;
            }

            const operation_index = job.operation_indices.get(
                preferred.operation_id,
            ) orelse {
                self.preferred_operation = null;
                return null;
            };
            const operation = &job.operations.items[operation_index];

            if (operation.state == .running) return null;
            if (operation.state != .pending) {
                self.preferred_operation = null;
                return null;
            }
            if ((job.state != .queued and job.state != .running) or
                job.operation_state_counts[@backingInt(OperationState.running)] != 0 or
                operation.unresolved_dependencies != 0 or
                !dependenciesCompleted(job, operation))
            {
                return null;
            }
            if (!dequeueReadyIndex(job, operation_index)) return null;

            // Consume the preference only when dispatch actually succeeds.
            self.preferred_operation = null;

            if (operation.generation == std.math.maxInt(u64)) {
                transitionOperation(job, operation, .failed);
                self.propagateUnmetDependencies(job, operation_index);
                self.recomputeJobState(job);
                return null;
            }

            if (operation.kind == .copy_file) {
                if (operation.entry_id) |entry_id| {
                    if (job.tree.getConst(entry_id)) |entry| {
                        operation.progress_total_bytes = entry.metadata.size;
                    }
                }
            }
            operation.generation += 1;
            transitionOperation(job, operation, .running);
            job.state = .running;
            self.round_robin_cursor = (job_index + 1) % self.jobs.items.len;
            return .{
                .job_id = job.id,
                .operation_id = operation.id,
                .generation = operation.generation,
            };
        }

        self.preferred_operation = null;
        return null;
    }

    /// One active Operation per Job preserves its FIFO execution order.
    /// The cursor rotates across Jobs after every successful dispatch.
    pub fn dispatchNext(self: *Manager) ?WorkToken {
        const count = self.jobs.items.len;
        if (count == 0) return null;

        if (self.dispatchPreferred()) |token| return token;

        // Directory creation outranks symlink creation, which outranks
        // regular-file and all remaining operation kinds.
        for (0..3) |priority| {
            for (0..count) |offset| {
                const index = (self.round_robin_cursor + offset) % count;
                const job = &self.jobs.items[index];
                if (job.state != .queued and job.state != .running and
                    job.state != .finalizing)
                    continue;
                if (job.operation_state_counts[@backingInt(OperationState.running)] != 0)
                    continue;

                while (dequeueReadyPriority(job, priority)) |operation_index| {
                    const operation = &job.operations.items[operation_index];
                    if (operation.state != .pending or operation.unresolved_dependencies != 0)
                        continue;

                    if (operation.generation == std.math.maxInt(u64)) {
                        transitionOperation(job, operation, .failed);
                        self.propagateUnmetDependencies(job, operation_index);
                        self.recomputeJobState(job);
                        continue;
                    }

                    if (operation.kind == .copy_file) {
                        if (operation.entry_id) |entry_id| {
                            if (job.tree.getConst(entry_id)) |entry| {
                                operation.progress_total_bytes = entry.metadata.size;
                            }
                        }
                    }
                    operation.generation += 1;
                    transitionOperation(job, operation, .running);
                    job.state = if (operation.kind == .finalize_directories)
                        .finalizing
                    else
                        .running;
                    self.round_robin_cursor = (index + 1) % count;
                    return .{
                        .job_id = job.id,
                        .operation_id = operation.id,
                        .generation = operation.generation,
                    };
                }
            }
        }
        for (self.jobs.items) |*job| self.recomputeJobState(job);
        return null;
    }

    /// Rejects stale and duplicate results. A yielded Operation returns to FIFO.
    pub fn completeWork(self: *Manager, token: WorkToken, result: WorkResult) bool {
        const job = self.findJob(token.job_id) orelse return false;
        const operation = findOperation(job, token.operation_id) orelse return false;
        if (operation.state != .running or operation.generation != token.generation) return false;

        const operation_index = findOperationIndex(job, token.operation_id) orelse return false;
        if (job.cancel_requested) {
            transitionOperation(
                job,
                operation,
                if (result == .completed) .completed else .cancelled,
            );
            job.cancel_requested = false;
            self.cancelOutstanding(job, false);
            job.state = .cancelled;
            return true;
        }

        const pause_after = job.pause_requested;
        const next_state: OperationState = switch (result) {
            .yielded => .pending,
            .completed => .completed,
            .waiting => .waiting,
            .skipped => .skipped,
            .failed => .failed,
            .cancelled => .cancelled,
        };
        transitionOperation(job, operation, next_state);
        if (result == .completed and operation.kind == .copy_file) {
            operation.progress_bytes = operation.progress_total_bytes;
        }
        if (result == .yielded) {
            enqueueReadyFront(job, operation_index);
        } else if (result == .completed) {
            for (operation.dependents.items) |dependent_index| {
                const dependent = &job.operations.items[dependent_index];
                dependent.unresolved_dependencies -= 1;
                if (dependent.unresolved_dependencies == 0 and dependent.state == .pending) {
                    enqueueReady(job, dependent_index);
                }
            }
        } else if (result == .failed or result == .skipped or result == .cancelled) {
            self.propagateUnmetDependencies(job, operation_index);
        }
        if (pause_after) {
            job.pause_requested = false;
            job.state = .paused;
        } else {
            self.recomputeJobState(job);
        }
        return true;
    }

    /// Records a copy's exact byte offset on the main thread.
    pub fn recordOperationProgress(
        self: *Manager,
        token: WorkToken,
        bytes: u64,
        total_bytes: u64,
        phase: CopyPhase,
    ) bool {
        const job = self.findJob(token.job_id) orelse return false;
        const operation = findOperation(job, token.operation_id) orelse return false;
        if ((operation.state != .pending and operation.state != .completed) or
            operation.generation != token.generation or
            bytes > total_bytes)
        {
            return false;
        }
        operation.progress_bytes = bytes;
        operation.progress_total_bytes = total_bytes;
        const was_flushing = isFlushingOperation(operation);
        operation.copy_phase = phase;
        updateFlushingOperationCount(job, operation, was_flushing);
        updateProgressRate(operation, token.generation, bytes, phase, monotonicMs());
        return true;
    }

    /// Adds measurements from one worker unit after its token was accepted.
    pub fn recordOperationCopyMetrics(
        self: *Manager,
        token: WorkToken,
        delta: CopyMetrics,
    ) bool {
        const job = self.findJob(token.job_id) orelse return false;
        const operation = findOperation(job, token.operation_id) orelse return false;
        if (operation.generation != token.generation) return false;
        operation.copy_metrics.add(delta);
        return true;
    }

    pub fn operationCopyMetrics(
        self: *const Manager,
        job_id: JobId,
        operation_id: OperationId,
    ) ?CopyMetrics {
        const job = self.findJobConst(job_id) orelse return null;
        const operation = findOperationConst(job, operation_id) orelse return null;
        return operation.copy_metrics;
    }

    pub fn jobState(self: *const Manager, job_id: JobId) ?JobState {
        const job = self.findJobConst(job_id) orelse return null;
        return job.state;
    }

    pub fn jobHasSkippedOperations(self: *const Manager, job_id: JobId) bool {
        const job = self.findJobConst(job_id) orelse return false;
        for (job.operations.items) |operation| {
            if (operation.state == .skipped) return true;
        }
        return false;
    }

    pub fn jobHasFlushingOperation(self: *const Manager, job_id: JobId) bool {
        const job = self.findJobConst(job_id) orelse return false;
        return job.flushing_operation_count != 0;
    }

    pub fn operationState(self: *const Manager, job_id: JobId, operation_id: OperationId) ?OperationState {
        const job = self.findJobConst(job_id) orelse return null;
        const operation = findOperationConst(job, operation_id) orelse return null;
        return operation.state;
    }

    /// Reports whether a worker token still identifies the running
    /// generation of its operation.
    pub fn acceptsWorkToken(self: *const Manager, token: WorkToken) bool {
        const job = self.findJobConst(token.job_id) orelse return false;
        const operation = findOperationConst(job, token.operation_id) orelse return false;
        return operation.state == .running and
            operation.generation == token.generation;
    }

    /// Read-only execution state for the operation associated with one entry.
    /// A nonzero generation means the operation has been dispatched at least
    /// once, even when a yielded operation is briefly pending again.
    pub fn entryOperationView(
        self: *const Manager,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) ?EntryOperationView {
        const job = self.findJobConst(job_id) orelse return null;
        const index = job.entry_operation_indices.get(entry_id) orelse return null;
        const operation = &job.operations.items[index];
        return .{
            .state = operation.state,
            .generation = operation.generation,
            .progress_bytes = operation.progress_bytes,
            .progress_total_bytes = operation.progress_total_bytes,
            .progress_bytes_per_second = currentProgressRate(operation, monotonicMs()),
            .copy_phase = operation.copy_phase,
        };
    }

    /// Returns the source-detach state for an entry, if registered.
    pub fn sourceDetachOperationState(
        self: *const Manager,
        job_id: JobId,
        entry_id: io_tree.EntryId,
    ) ?OperationState {
        const job = self.findJobConst(job_id) orelse return null;
        const index = job.source_detach_indices.get(entry_id) orelse return null;
        return job.operations.items[index].state;
    }

    pub fn snapshotJob(self: *const Manager, allocator: Allocator, job_id: JobId) !JobSnapshot {
        const job = self.findJobConst(job_id) orelse return error.UnknownJob;
        const operations = try allocator.alloc(OperationSnapshot, job.operations.items.len);
        var initialized: usize = 0;
        errdefer {
            for (operations[0..initialized]) |operation| allocator.free(operation.dependencies);
            allocator.free(operations);
        }

        for (job.operations.items, 0..) |operation, index| {
            const dependencies = try allocator.dupe(OperationId, operation.dependencies.items);
            operations[index] = .{
                .id = operation.id,
                .kind = operation.kind,
                .state = operation.state,
                .generation = operation.generation,
                .dependencies = dependencies,
                .copy_metrics = operation.copy_metrics,
            };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .id = job.id,
            .origin_window_id = job.origin_window_id,
            .state = job.state,
            .operations = operations,
        };
    }

    fn findJob(self: *Manager, id: JobId) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    fn findJobConst(self: *const Manager, id: JobId) ?*const Job {
        for (self.jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    fn recomputeJobState(self: *Manager, job: *Job) void {
        _ = self;
        if (job.state == .paused or job.state == .planning) return;
        var counts = job.operation_state_counts;

        if (job.directory_finalization_index) |finalizer_index| {
            const finalizer = &job.operations.items[finalizer_index];
            if (finalizer.state == .running) {
                job.state = .finalizing;
                return;
            }
            if (finalizer.state == .pending) {
                if (directoryFinalizationReady(job)) {
                    if (!finalizer.finalization_queued) {
                        enqueueReady(job, finalizer_index);
                        finalizer.finalization_queued = true;
                    }
                    job.state = .finalizing;
                    return;
                }
                if (finalizer.finalization_queued) {
                    _ = dequeueReadyIndex(job, finalizer_index);
                    finalizer.finalization_queued = false;
                }
                counts[@backingInt(OperationState.pending)] -= 1;
            }
        }
        if (counts[@backingInt(OperationState.running)] != 0) {
            job.state = .running;
        } else if (job.ready_count != 0) {
            job.state = .queued;
        } else if (counts[@backingInt(OperationState.waiting)] != 0 or
            counts[@backingInt(OperationState.pending)] != 0)
        {
            job.state = if (hasDiscoveryWork(job)) .queued else .waiting;
        } else if (hasDiscoveryWork(job)) {
            job.state = .queued;
        } else if (counts[@backingInt(OperationState.failed)] != 0) {
            job.state = if (counts[@backingInt(OperationState.completed)] != 0)
                .completed_with_errors
            else
                .failed;
        } else if (counts[@backingInt(OperationState.cancelled)] != 0) {
            job.state = .cancelled;
        } else {
            job.state = .completed;
        }
    }

    fn nonterminalOperationCount(job: *const Job) usize {
        return job.operation_state_counts[@backingInt(OperationState.pending)] +
            job.operation_state_counts[@backingInt(OperationState.running)] +
            job.operation_state_counts[@backingInt(OperationState.waiting)];
    }

    fn directoryFinalizationReady(job: *const Job) bool {
        if (job.discovery_pending_count != 0 or job.discovery_in_flight != null or
            job.outstanding_population_count != 0)
            return false;
        return nonterminalOperationCount(job) == 1;
    }


    fn hasDiscoveryWork(job: *const Job) bool {
        return job.discovery_started and
            (job.discovery_pending_count != 0 or job.discovery_in_flight != null);
    }

    fn propagateUnmetDependencies(self: *Manager, job: *Job, failed_index: usize) void {
        _ = self;
        job.dependency_work_queue.clearRetainingCapacity();
        for (job.operations.items[failed_index].dependents.items) |dependent_index| {
            job.dependency_work_queue.appendAssumeCapacity(dependent_index);
        }

        var head: usize = 0;
        while (head < job.dependency_work_queue.items.len) : (head += 1) {
            const index = job.dependency_work_queue.items[head];
            const operation = &job.operations.items[index];
            if (operation.state != .pending) continue;

            transitionOperation(job, operation, .skipped);
            for (operation.dependents.items) |dependent_index| {
                job.dependency_work_queue.appendAssumeCapacity(dependent_index);
            }
        }
    }
};

fn transitionOperation(job: *Job, operation: *Operation, next_state: OperationState) void {
    if (operation.state == next_state) return;
    const was_flushing = isFlushingOperation(operation);
    if (operation.population_accounted and
        !operation.state.isTerminal() and next_state.isTerminal())
    {
        std.debug.assert(job.outstanding_population_count != 0);
        job.outstanding_population_count -= 1;
        operation.population_accounted = false;
    }
    job.operation_state_counts[@backingInt(operation.state)] -= 1;
    job.operation_state_counts[@backingInt(next_state)] += 1;
    operation.state = next_state;
    updateFlushingOperationCount(job, operation, was_flushing);
}

fn isFlushingOperation(operation: *const Operation) bool {
    return operation.copy_phase == .flushing and
        (operation.state == .pending or operation.state == .running);
}

fn updateFlushingOperationCount(
    job: *Job,
    operation: *const Operation,
    was_flushing: bool,
) void {
    const is_flushing = isFlushingOperation(operation);
    if (was_flushing == is_flushing) return;
    if (is_flushing) {
        job.flushing_operation_count += 1;
    } else {
        std.debug.assert(job.flushing_operation_count != 0);
        job.flushing_operation_count -= 1;
    }
}

fn isPopulationOperation(kind: OperationKind) bool {
    return switch (kind) {
        .create_directory, .copy_file, .copy_symlink, .move_entry => true,
        .finalize_directories, .publish, .detach_source, .purge_source, .archive_extract,
        .archive_member_extract => false,
    };
}

fn findOperation(job: *Job, id: OperationId) ?*Operation {
    const index = job.operation_indices.get(id) orelse return null;
    return &job.operations.items[index];
}

fn findOperationConst(job: *const Job, id: OperationId) ?*const Operation {
    const index = job.operation_indices.get(id) orelse return null;
    return &job.operations.items[index];
}

fn findOperationIndex(job: *const Job, id: OperationId) ?usize {
    return job.operation_indices.get(id);
}

fn enqueueReady(job: *Job, operation_index: usize) void {
    const operation = &job.operations.items[operation_index];
    std.debug.assert(!operation.ready_queued);
    const queue = &job.ready_queues[operationPriority(operation.kind)];

    operation.ready_previous = queue.tail;
    operation.ready_next = null;
    if (queue.tail) |tail| {
        job.operations.items[tail].ready_next = operation_index;
    } else {
        queue.head = operation_index;
    }
    queue.tail = operation_index;
    queue.count += 1;
    operation.ready_queued = true;
    job.ready_count += 1;
}

fn enqueueReadyFront(job: *Job, operation_index: usize) void {
    const operation = &job.operations.items[operation_index];
    std.debug.assert(!operation.ready_queued);
    const queue = &job.ready_queues[operationPriority(operation.kind)];

    operation.ready_previous = null;
    operation.ready_next = queue.head;
    if (queue.head) |head| {
        job.operations.items[head].ready_previous = operation_index;
    } else {
        queue.tail = operation_index;
    }
    queue.head = operation_index;
    queue.count += 1;
    operation.ready_queued = true;
    job.ready_count += 1;
}

fn operationPriority(kind: OperationKind) usize {
    return switch (kind) {
        .create_directory => 0,
        .copy_symlink => 1,
        else => 2,
    };
}

fn unlinkReady(job: *Job, operation_index: usize) bool {
    const operation = &job.operations.items[operation_index];
    if (!operation.ready_queued) return false;

    const queue = &job.ready_queues[operationPriority(operation.kind)];
    if (operation.ready_previous) |previous| {
        job.operations.items[previous].ready_next = operation.ready_next;
    } else {
        queue.head = operation.ready_next;
    }
    if (operation.ready_next) |next| {
        job.operations.items[next].ready_previous = operation.ready_previous;
    } else {
        queue.tail = operation.ready_previous;
    }

    operation.ready_previous = null;
    operation.ready_next = null;
    operation.ready_queued = false;
    std.debug.assert(queue.count != 0 and job.ready_count != 0);
    queue.count -= 1;
    job.ready_count -= 1;
    std.debug.assert((queue.count == 0) == (queue.head == null));
    std.debug.assert((queue.count == 0) == (queue.tail == null));
    return true;
}

fn dequeueReadyPriority(job: *Job, priority: usize) ?usize {
    const operation_index = job.ready_queues[priority].head orelse return null;
    std.debug.assert(unlinkReady(job, operation_index));
    return operation_index;
}

fn dequeueReadyIndex(job: *Job, target: usize) bool {
    return unlinkReady(job, target);
}

fn dependenciesCompleted(job: *const Job, operation: *const Operation) bool {
    for (operation.dependencies.items) |dependency_id| {
        const dependency = findOperationConst(job, dependency_id) orelse return false;
        if (dependency.state != .completed) return false;
    }
    return true;
}

fn validateAcyclic(allocator: Allocator, job: *const Job) !void {
    const operations = job.operations.items;
    const indegree = try allocator.alloc(usize, operations.len);
    defer allocator.free(indegree);
    const queue = try allocator.alloc(usize, operations.len);
    defer allocator.free(queue);

    for (operations, 0..) |operation, index| {
        indegree[index] = operation.dependencies.items.len;
    }

    var head: usize = 0;
    var tail: usize = 0;
    for (indegree, 0..) |degree, index| {
        if (degree == 0) {
            queue[tail] = index;
            tail += 1;
        }
    }

    var completed: usize = 0;
    while (head < tail) {
        const index = queue[head];
        head += 1;
        completed += 1;

        for (operations[index].dependents.items) |dependent_index| {
            indegree[dependent_index] -= 1;
            if (indegree[dependent_index] == 0) {
                queue[tail] = dependent_index;
                tail += 1;
            }
        }
    }

    if (completed != operations.len) return error.DependencyCycle;
}

fn buildDependencyGraph(allocator: Allocator, job: *Job) !void {
    const operations = job.operations.items;

    for (operations) |*operation| {
        operation.dependents.clearRetainingCapacity();
        operation.unresolved_dependencies = operation.dependencies.items.len +
            @as(usize, @intFromBool(operation.discovery_gate));
    }

    for (operations, 0..) |operation, dependent_index| {
        for (operation.dependency_indices.items) |dependency_index| {
            if (dependency_index >= operations.len) return error.UnknownDependency;
            try job.operations.items[dependency_index].dependents.append(allocator, dependent_index);
        }
    }
}

test "generation exhaustion does not starve unrelated Operations" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_id = try manager.createJob(null);
    const exhausted = try manager.addOperation(job_id, .copy_file);
    const dependent = try manager.addOperation(job_id, .publish);
    const independent = try manager.addOperation(job_id, .copy_file);
    try manager.addDependency(job_id, dependent, exhausted);
    try manager.queueJob(job_id);

    const job = manager.findJob(job_id).?;
    job.operations.items[0].generation = std.math.maxInt(u64);

    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(independent, token.operation_id);
    try std.testing.expectEqual(OperationState.failed, manager.operationState(job_id, exhausted).?);
    try std.testing.expectEqual(OperationState.skipped, manager.operationState(job_id, dependent).?);
    try std.testing.expectEqual(OperationState.running, manager.operationState(job_id, independent).?);

    try std.testing.expect(manager.completeWork(token, .completed));
    try std.testing.expectEqual(JobState.completed_with_errors, manager.jobState(job_id).?);
}

test "accepted copy metrics accumulate and appear in operation snapshots" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_id = try manager.createJob(null);
    const operation_id = try manager.addOperation(job_id, .copy_file);
    try manager.queueJob(job_id);
    const token = manager.dispatchNext().?;
    try std.testing.expectEqual(operation_id, token.operation_id);
    try std.testing.expect(manager.completeWork(token, .yielded));

    const delta: CopyMetrics = .{
        .copy_file_range_calls = 2,
        .copy_file_range_bytes = 128 * 1024,
        .fallback_exdev = 1,
        .elapsed_ns = 900,
    };
    try std.testing.expect(manager.recordOperationCopyMetrics(token, delta));

    const metrics = manager.operationCopyMetrics(job_id, operation_id).?;
    try std.testing.expectEqual(@as(u64, 2), metrics.copy_file_range_calls);
    try std.testing.expectEqual(@as(u64, 128 * 1024), metrics.copy_file_range_bytes);
    try std.testing.expectEqual(@as(u64, 1), metrics.fallback_exdev);
    try std.testing.expectEqual(@as(u64, 900), metrics.elapsed_ns);

    var snapshot = try manager.snapshotJob(std.testing.allocator, job_id);
    defer snapshot.deinit();
    try std.testing.expectEqual(
        metrics.copy_file_range_bytes,
        snapshot.operations[0].copy_metrics.copy_file_range_bytes,
    );
}

test "multi-root discovery queue commit leaves no partial scheduling on validation failure" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_id = try manager.createJob(null);
    const first_root = try manager.addTreeRoot(
        job_id,
        "first",
        .directory,
        .{},
        null,
    );
    const second_root = try manager.addTreeRoot(
        job_id,
        "second",
        .directory,
        .{},
        null,
    );
    try manager.setDestinationDirectory(job_id, "/tmp/destination");
    try manager.enableDiscoveredEntryOperations(job_id);
    _ = try manager.addEntryOperation(job_id, first_root, .create_directory);
    _ = try manager.addEntryOperation(job_id, second_root, .create_directory);

    const roots = [_]DiscoveryRoot{
        .{ .root_id = first_root, .path = "/tmp/first" },
        .{ .root_id = second_root, .path = "relative/second" },
    };
    try std.testing.expectError(
        error.InvalidRootPath,
        manager.queueJobWithDiscoveryRoots(job_id, &roots),
    );

    try std.testing.expectEqual(JobState.planning, manager.jobState(job_id).?);
    try std.testing.expectEqual(
        io_tree.DiscoveryState.unscanned,
        manager.treeIndex(job_id).?.getConst(first_root).?.discovery,
    );
    try std.testing.expectEqual(
        io_tree.DiscoveryState.unscanned,
        manager.treeIndex(job_id).?.getConst(second_root).?.discovery,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), manager.discoveryRootPath(job_id, first_root));
    try std.testing.expectEqual(@as(?bool, null), manager.discoveryComplete(job_id));
    try std.testing.expect(manager.discardPlanningJob(job_id));
}

test "copy progress rate samples every 500ms and expires stale readings" {
    var operation: Operation = .{
        .id = 1,
        .kind = .copy_file,
        .state = .running,
    };

    updateProgressRate(&operation, 1, 0, .transferring, 1000);
    updateProgressRate(&operation, 1, 100, .transferring, 1499);
    try std.testing.expectEqual(@as(u64, 0), currentProgressRate(&operation, 1499));

    updateProgressRate(&operation, 1, 200, .transferring, 1500);
    try std.testing.expectEqual(@as(u64, 400), currentProgressRate(&operation, 2000));
    try std.testing.expectEqual(@as(u64, 0), currentProgressRate(&operation, 3001));
}

test "copy progress rate survives yielded generations and resets on regression and flushing" {
    var operation: Operation = .{
        .id = 1,
        .kind = .copy_file,
        .state = .running,
    };

    updateProgressRate(&operation, 1, 100, .transferring, 1000);
    updateProgressRate(&operation, 2, 600, .transferring, 1500);
    try std.testing.expectEqual(@as(u64, 1000), currentProgressRate(&operation, 1500));

    updateProgressRate(&operation, 3, 0, .transferring, 2000);
    try std.testing.expectEqual(@as(u64, 0), currentProgressRate(&operation, 2000));
    updateProgressRate(&operation, 3, 500, .transferring, 2500);
    try std.testing.expectEqual(@as(u64, 1000), currentProgressRate(&operation, 2500));

    updateProgressRate(&operation, 3, 500, .flushing, 2600);
    try std.testing.expectEqual(@as(u64, 0), currentProgressRate(&operation, 2600));
    updateProgressRate(&operation, 4, 1000, .transferring, 3100);
    try std.testing.expectEqual(@as(u64, 1000), currentProgressRate(&operation, 3100));
}
