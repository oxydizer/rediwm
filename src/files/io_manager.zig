//! Application-wide model and deterministic scheduler for Files I/O Jobs.
//!
//! This layer is main-thread-owned. Worker threads and filesystem execution are
//! deliberately added in later phases.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_tree = @import("io_tree.zig");
const io_discovery = @import("io_discovery.zig");

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

pub const JobState = enum {
    planning,
    queued,
    running,
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
    publish,
    detach_source,
    purge_source,
    archive_extract,
    archive_member_extract,
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

const Operation = struct {
    id: OperationId,
    kind: OperationKind,
    entry_id: ?io_tree.EntryId = null,
    destination_override: ?[]u8 = null,
    state: OperationState = .pending,
    generation: u64 = 0,
    dependencies: std.ArrayList(OperationId) = .empty,
    dependency_indices: std.ArrayList(usize) = .empty,
    dependents: std.ArrayList(usize) = .empty,
    unresolved_dependencies: usize = 0,

    fn deinit(self: *Operation, allocator: Allocator) void {
        if (self.destination_override) |path| allocator.free(path);
        self.dependencies.deinit(allocator);
        self.dependency_indices.deinit(allocator);
        self.dependents.deinit(allocator);
    }
};

const Job = struct {
    id: JobId,
    origin_window_id: ?WindowId,
    state: JobState = .planning,
    tree: io_tree.TreeIndex,
    source_root_paths: std.AutoHashMapUnmanaged(io_tree.EntryId, []u8) = .empty,
    discovery_started: bool = false,
    auto_plan_discovered_entries: bool = false,
    destination_directory: ?[]u8 = null,
    discovery_schedule: std.AutoHashMapUnmanaged(io_tree.EntryId, DiscoverySchedule) = .empty,
    discovery_pending_count: usize = 0,
    discovery_generation: u64 = 0,
    discovery_in_flight: ?DiscoveryToken = null,
    operations: std.ArrayList(Operation) = .empty,
    operation_indices: std.AutoHashMapUnmanaged(OperationId, usize) = .empty,
    entry_operation_indices: std.AutoHashMapUnmanaged(io_tree.EntryId, usize) = .empty,
    ready_queue: std.ArrayList(usize) = .empty,
    ready_head: usize = 0,
    ready_count: usize = 0,
    dependency_work_queue: std.ArrayList(usize) = .empty,
    operation_state_counts: [7]usize = .{ 0, 0, 0, 0, 0, 0, 0 },

    fn deinit(self: *Job, allocator: Allocator) void {
        var source_path_iter = self.source_root_paths.valueIterator();
        while (source_path_iter.next()) |path| allocator.free(path.*);
        self.source_root_paths.deinit(allocator);
        if (self.destination_directory) |path| allocator.free(path);
        self.discovery_schedule.deinit(allocator);
        self.tree.deinit();
        for (self.operations.items) |*operation| operation.deinit(allocator);
        self.operations.deinit(allocator);
        self.operation_indices.deinit(allocator);
        self.entry_operation_indices.deinit(allocator);
        self.ready_queue.deinit(allocator);
        self.dependency_work_queue.deinit(allocator);
    }
};

pub const OperationSnapshot = struct {
    id: OperationId,
    kind: OperationKind,
    state: OperationState,
    generation: u64,
    dependencies: []OperationId,
};

pub const OperationDetails = struct {
    kind: OperationKind,
    entry_id: io_tree.EntryId,
};

pub const EntryOperationView = struct {
    state: OperationState,
    generation: u64,
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

pub const Manager = struct {
    allocator: Allocator,
    jobs: std.ArrayList(Job) = .empty,
    next_job_id: JobId = 1,
    next_operation_id: OperationId = 1,
    round_robin_cursor: usize = 0,
    discovery_queues: [3]DiscoveryQueue = .{ .{}, .{}, .{} },
    discovery_schedule_slot: usize = 0,
    conflicts: std.ArrayList(Conflict) = .empty,
    conflict_head: usize = 0,
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
        if (job.tree.root() == null) return error.MissingTreeRoot;
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
        job.auto_plan_discovered_entries = true;
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
        const queue = &self.discovery_queues[@intFromEnum(DiscoveryPriority.background)];
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
        const queue = &self.discovery_queues[@intFromEnum(priority)];
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
        const queue = &self.discovery_queues[@intFromEnum(priority)];
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
                queue_counts[@intFromEnum(priority)] += 1;
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
                self.discovery_queues[@intFromEnum(priority)].items.appendAssumeCapacity(.{
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

        var new_directories: usize = 0;
        for (batch.records.items) |record| {
            if (record.kind == .directory and !record.entry_error)
                new_directories += 1;
        }
        const parent_priority = job.discovery_schedule.get(token.entry_id) orelse
            return error.MissingDiscoverySchedule;
        const child_priority: DiscoveryPriority =
            if (parent_priority.priority == .background) .background else .promoted;
        try job.discovery_schedule.ensureUnusedCapacity(self.allocator, @intCast(new_directories));
        try self.discovery_queues[@intFromEnum(child_priority)].items.ensureUnusedCapacity(
            self.allocator,
            new_directories,
        );
        if (!batch.complete) {
            if (parent_priority.version == std.math.maxInt(u64))
                return error.DiscoveryScheduleExhausted;
            try self.discovery_queues[@intFromEnum(parent_priority.priority)].items.ensureUnusedCapacity(
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

            const child_id = try job.tree.addEntry(
                token.entry_id,
                record.name,
                kind,
                record.metadata,
                if (kind == .symlink) record.symlink_target else null,
            );

            if (job.auto_plan_discovered_entries and
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

            if (record.kind == .directory and !record.entry_error) {
                const child = job.tree.get(child_id).?;
                child.discovery = .queued;
                job.discovery_schedule.putAssumeCapacity(child_id, .{
                    .priority = child_priority,
                    .version = 1,
                });
                self.discovery_queues[@intFromEnum(child_priority)].items.appendAssumeCapacity(.{
                    .job_id = job.id,
                    .entry_id = child_id,
                    .version = 1,
                });
                job.discovery_pending_count += 1;
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
        } else {
            const version = parent_priority.version + 1;
            job.discovery_schedule.putAssumeCapacity(token.entry_id, .{
                .priority = parent_priority.priority,
                .version = version,
            });
            self.discovery_queues[@intFromEnum(parent_priority.priority)].items.appendAssumeCapacity(.{
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

        if (job.tree.get(token.entry_id)) |entry|
            entry.discovery = .failed;
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
        };
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
        return self.addOperationInternal(job, kind);
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
            try job.ready_queue.ensureTotalCapacity(
                self.allocator,
                index + 1,
            );
            try job.dependency_work_queue.ensureTotalCapacity(
                self.allocator,
                index + 1,
            );
        }
        job.operations.appendAssumeCapacity(.{ .id = id, .kind = kind });
        job.operation_indices.putAssumeCapacity(id, index);
        self.next_operation_id += 1;
        if (job.state != .planning) {
            job.operation_state_counts[@intFromEnum(OperationState.pending)] += 1;
            enqueueReady(job, index);
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
        if (job.entry_operation_indices.contains(entry_id))
            return error.EntryOperationAlreadyExists;

        const expected_kind: OperationKind = switch (entry.kind) {
            .directory => .create_directory,
            .regular_file => .copy_file,
            .symlink => .copy_symlink,
            .other => return error.UnsupportedEntryKind,
        };
        if (kind != expected_kind) return error.InvalidEntryOperationKind;

        var parent_operation_index: ?usize = null;
        if (entry.parent_id) |parent_id| {
            const parent = job.tree.get(parent_id) orelse return error.UnknownEntry;
            if (parent.kind == .directory) {
                parent_operation_index = job.entry_operation_indices.get(parent_id) orelse
                    return error.MissingParentDirectoryOperation;
                if (job.operations.items[parent_operation_index.?].kind != .create_directory)
                    return error.InvalidParentDirectoryOperation;
            }
        }

        var dependencies: std.ArrayList(OperationId) = .empty;
        errdefer dependencies.deinit(self.allocator);
        var dependency_indices: std.ArrayList(usize) = .empty;
        errdefer dependency_indices.deinit(self.allocator);

        if (parent_operation_index != null) {
            try dependencies.ensureUnusedCapacity(self.allocator, 1);
            try dependency_indices.ensureUnusedCapacity(self.allocator, 1);
        }

        try job.entry_operation_indices.ensureUnusedCapacity(self.allocator, 1);
        if (parent_operation_index) |parent_index| {
            const parent_operation = &job.operations.items[parent_index];
            try parent_operation.dependents.ensureUnusedCapacity(self.allocator, 1);
            // When the parent completes, every pending dependent may become
            // ready in one pass. Reserve for the full dependent set now,
            // rather than relying on appendAssumeCapacity during completion.
            try job.ready_queue.ensureUnusedCapacity(
                self.allocator,
                parent_operation.dependents.items.len + 1,
            );
        }

        const operation_id = try self.addOperationInternal(job, kind);
        const operation_index = job.operations.items.len - 1;
        const operation = &job.operations.items[operation_index];
        operation.dependencies = dependencies;
        dependencies = .empty;
        operation.dependency_indices = dependency_indices;
        dependency_indices = .empty;
        operation.entry_id = entry_id;
        job.entry_operation_indices.putAssumeCapacity(entry_id, operation_index);

        if (parent_operation_index) |parent_index| {
            const parent_operation = &job.operations.items[parent_index];
            operation.dependencies.appendAssumeCapacity(parent_operation.id);
            operation.dependency_indices.appendAssumeCapacity(parent_index);
            parent_operation.dependents.appendAssumeCapacity(operation_index);

            if (job.state != .planning) {
                switch (parent_operation.state) {
                    .completed => {},
                    .failed, .skipped, .cancelled => {
                        _ = dequeueReadyIndex(job, operation_index);
                        transitionOperation(job, operation, .skipped);
                        self.recomputeJobState(job);
                    },
                    else => {
                        operation.unresolved_dependencies = 1;
                        _ = dequeueReadyIndex(job, operation_index);
                    },
                }
            }
        }
        return operation_id;
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
        try buildDependencyGraph(self.allocator, job);
        try validateAcyclic(self.allocator, job);

        const operation_count = job.operations.items.len;
        var dependency_count: usize = 0;
        for (job.operations.items) |operation| {
            dependency_count += operation.dependency_indices.items.len;
        }
        try job.ready_queue.ensureTotalCapacity(self.allocator, operation_count);
        try job.dependency_work_queue.ensureTotalCapacity(self.allocator, dependency_count);
        job.ready_queue.clearRetainingCapacity();
        job.dependency_work_queue.clearRetainingCapacity();
        job.ready_head = 0;
        job.ready_count = 0;
    job.operation_state_counts = .{ 0, 0, 0, 0, 0, 0, 0 };

        for (job.operations.items, 0..) |operation, index| {
            job.operation_state_counts[@intFromEnum(operation.state)] += 1;
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
        if (job.state != .queued and job.state != .waiting) return error.InvalidJobState;
        for (job.operations.items) |operation| {
            if (operation.state == .running) return error.Busy;
        }
        job.state = .paused;
    }

    pub fn resumeJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .paused) return error.InvalidJobState;
        job.state = .queued;
        self.recomputeJobState(job);
    }

    pub fn resolveWaiting(self: *Manager, job_id: JobId, operation_id: OperationId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        const operation = findOperation(job, operation_id) orelse return error.UnknownOperation;
        if (operation.state != .waiting) return error.InvalidOperationState;
        const index = findOperationIndex(job, operation_id) orelse return error.UnknownOperation;
        transitionOperation(job, operation, .pending);
        enqueueReady(job, index);
        self.recomputeJobState(job);
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

        for (self.conflicts.items[self.conflict_head..]) |conflict| {
            if (conflict.job_id == token.job_id and
                conflict.operation_id == token.operation_id)
                return error.ConflictAlreadyRegistered;
        }

        const source_copy = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(source_copy);
        const destination_copy = try self.allocator.dupe(u8, destination_path);
        errdefer self.allocator.free(destination_copy);
        try self.conflicts.ensureUnusedCapacity(self.allocator, 1);

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
    /// A running operation must first return its token so worker-owned
    /// resources can be reconciled safely.
    pub fn cancelJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state == .planning or job.state.isTerminal())
            return error.InvalidJobState;
        for (job.operations.items) |operation| {
            if (operation.state == .running) return error.Busy;
        }

        for (job.operations.items) |*operation| {
            if (!operation.state.isTerminal())
                transitionOperation(job, operation, .cancelled);
        }
        job.ready_queue.clearRetainingCapacity();
        job.ready_head = 0;
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
        self.recomputeJobState(job);
        job.state = .cancelled;
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

        transitionOperation(job, operation, .skipped);
        self.propagateUnmetDependencies(job, operation_index);
        self.consumeConflictHead();
        self.pruneInvalidConflicts();
        self.recomputeJobState(job);
    }

    fn conflictHead(self: *Manager, conflict_id: ConflictId) ?*Conflict {
        if (self.conflict_head >= self.conflicts.items.len) return null;
        const conflict = &self.conflicts.items[self.conflict_head];
        if (conflict.id != conflict_id) return null;
        return conflict;
    }

    fn consumeConflictHead(self: *Manager) void {
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
        var index = self.conflict_head;
        while (index < self.conflicts.items.len) {
            const conflict = &self.conflicts.items[index];
            var is_waiting = false;
            if (self.findJobConst(conflict.job_id)) |job| {
                if (job.operation_indices.get(conflict.operation_id)) |operation_index| {
                    is_waiting = job.operations.items[operation_index].state == .waiting;
                }
            }
            if (is_waiting) {
                index += 1;
                continue;
            }

            conflict.deinit(self.allocator);
            _ = self.conflicts.orderedRemove(index);
        }
        if (self.conflict_head >= self.conflicts.items.len) {
            self.conflicts.clearRetainingCapacity();
            self.conflict_head = 0;
        }
    }

    /// One active Operation per Job preserves its FIFO execution order.
    /// The cursor rotates across Jobs after every successful dispatch.
    pub fn dispatchNext(self: *Manager) ?WorkToken {
        const count = self.jobs.items.len;
        if (count == 0) return null;

        // Directory creation outranks symlink creation, which outranks
        // regular-file and all remaining operation kinds.
        for (0..3) |priority| {
            for (0..count) |offset| {
                const index = (self.round_robin_cursor + offset) % count;
                const job = &self.jobs.items[index];
                if (job.state != .queued and job.state != .running) continue;
                if (job.operation_state_counts[@intFromEnum(OperationState.running)] != 0)
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

                    operation.generation += 1;
                    transitionOperation(job, operation, .running);
                    job.state = .running;
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
        const next_state: OperationState = switch (result) {
            .yielded => .pending,
            .completed => .completed,
            .waiting => .waiting,
            .skipped => .skipped,
            .failed => .failed,
            .cancelled => .cancelled,
        };
        transitionOperation(job, operation, next_state);
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
        self.recomputeJobState(job);
        return true;
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

    pub fn operationState(self: *const Manager, job_id: JobId, operation_id: OperationId) ?OperationState {
        const job = self.findJobConst(job_id) orelse return null;
        const operation = findOperationConst(job, operation_id) orelse return null;
        return operation.state;
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
        const operation = job.operations.items[index];
        return .{
            .state = operation.state,
            .generation = operation.generation,
        };
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
        const counts = job.operation_state_counts;
        if (counts[@intFromEnum(OperationState.running)] != 0) {
            job.state = .running;
        } else if (job.ready_count != 0) {
            job.state = .queued;
        } else if (
            counts[@intFromEnum(OperationState.waiting)] != 0 or
            counts[@intFromEnum(OperationState.pending)] != 0
        ) {
            job.state = if (hasDiscoveryWork(job)) .queued else .waiting;
        } else if (hasDiscoveryWork(job)) {
            job.state = .queued;
        } else if (counts[@intFromEnum(OperationState.failed)] != 0) {
            job.state = if (counts[@intFromEnum(OperationState.completed)] != 0)
                .completed_with_errors
            else
                .failed;
        } else if (counts[@intFromEnum(OperationState.cancelled)] != 0) {
            job.state = .cancelled;
        } else {
            job.state = .completed;
        }
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
    job.operation_state_counts[@intFromEnum(operation.state)] -= 1;
    job.operation_state_counts[@intFromEnum(next_state)] += 1;
    operation.state = next_state;
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
    if (job.ready_queue.items.len == job.ready_queue.capacity) {
        const remaining = job.ready_queue.items.len - job.ready_head;
        std.mem.copyForwards(
            usize,
            job.ready_queue.items[0..remaining],
            job.ready_queue.items[job.ready_head..],
        );
        job.ready_queue.items.len = remaining;
        job.ready_head = 0;
    }
    job.ready_queue.appendAssumeCapacity(operation_index);
    job.ready_count += 1;
}

fn enqueueReadyFront(job: *Job, operation_index: usize) void {
    if (job.ready_count == 0) {
        job.ready_queue.appendAssumeCapacity(operation_index);
        job.ready_head = 0;
    } else if (job.ready_head > 0) {
        job.ready_head -= 1;
        job.ready_queue.items[job.ready_head] = operation_index;
    } else {
        const remaining = job.ready_queue.items.len;
        job.ready_queue.appendAssumeCapacity(operation_index);
        std.mem.copyBackwards(
            usize,
            job.ready_queue.items[1 .. remaining + 1],
            job.ready_queue.items[0..remaining],
        );
        job.ready_queue.items[0] = operation_index;
    }
    job.ready_count += 1;
}

fn dequeueReady(job: *Job) ?usize {
    if (job.ready_count == 0) return null;

    const operation_index = job.ready_queue.items[job.ready_head];
    job.ready_head += 1;
    job.ready_count -= 1;

    if (job.ready_count == 0) {
        job.ready_queue.clearRetainingCapacity();
        job.ready_head = 0;
    } else if (job.ready_head >= 64 and job.ready_head * 2 >= job.ready_queue.items.len) {
        const remaining = job.ready_queue.items.len - job.ready_head;
        std.mem.copyForwards(
            usize,
            job.ready_queue.items[0..remaining],
            job.ready_queue.items[job.ready_head..],
        );
        job.ready_queue.items.len = remaining;
        job.ready_head = 0;
    }
    return operation_index;
}

fn operationPriority(kind: OperationKind) usize {
    return switch (kind) {
        .create_directory => 0,
        .copy_symlink => 1,
        else => 2,
    };
}

fn dequeueReadyPriority(job: *Job, priority: usize) ?usize {
    if (job.ready_count == 0) return null;
    var position = job.ready_head;
    while (position < job.ready_queue.items.len) : (position += 1) {
        const operation_index = job.ready_queue.items[position];
        if (operationPriority(job.operations.items[operation_index].kind) != priority)
            continue;

        const remaining = job.ready_queue.items.len - position - 1;
        std.mem.copyForwards(
            usize,
            job.ready_queue.items[position .. position + remaining],
            job.ready_queue.items[position + 1 .. position + 1 + remaining],
        );
        job.ready_queue.items.len -= 1;
        job.ready_count -= 1;
        if (job.ready_count == 0) {
            job.ready_queue.clearRetainingCapacity();
            job.ready_head = 0;
        }
        return operation_index;
    }
    return null;
}

fn dequeueReadyIndex(job: *Job, target: usize) bool {
    if (job.ready_count == 0) return false;
    var position = job.ready_head;
    while (position < job.ready_queue.items.len) : (position += 1) {
        if (job.ready_queue.items[position] != target) continue;

        const remaining = job.ready_queue.items.len - position - 1;
        std.mem.copyForwards(
            usize,
            job.ready_queue.items[position .. position + remaining],
            job.ready_queue.items[position + 1 .. position + 1 + remaining],
        );
        job.ready_queue.items.len -= 1;
        job.ready_count -= 1;
        if (job.ready_count == 0) {
            job.ready_queue.clearRetainingCapacity();
            job.ready_head = 0;
        }
        return true;
    }
    return false;
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
        operation.unresolved_dependencies = operation.dependencies.items.len;
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
