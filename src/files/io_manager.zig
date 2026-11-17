//! Application-wide model and deterministic scheduler for Files I/O Jobs.
//!
//! This layer is main-thread-owned. Worker threads and filesystem execution are
//! deliberately added in later phases.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JobId = u64;
pub const OperationId = u64;
pub const WindowId = u64;

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
    state: OperationState = .pending,
    generation: u64 = 0,
    dependencies: std.ArrayList(OperationId) = .empty,
    dependency_indices: std.ArrayList(usize) = .empty,
    dependents: std.ArrayList(usize) = .empty,
    unresolved_dependencies: usize = 0,

    fn deinit(self: *Operation, allocator: Allocator) void {
        self.dependencies.deinit(allocator);
        self.dependency_indices.deinit(allocator);
        self.dependents.deinit(allocator);
    }
};

const Job = struct {
    id: JobId,
    origin_window_id: ?WindowId,
    state: JobState = .planning,
    operations: std.ArrayList(Operation) = .empty,
    operation_indices: std.AutoHashMapUnmanaged(OperationId, usize) = .empty,
    ready_queue: std.ArrayList(usize) = .empty,
    ready_head: usize = 0,
    ready_count: usize = 0,
    dependency_work_queue: std.ArrayList(usize) = .empty,
    operation_state_counts: [7]usize = .{ 0, 0, 0, 0, 0, 0, 0 },

    fn deinit(self: *Job, allocator: Allocator) void {
        for (self.operations.items) |*operation| operation.deinit(allocator);
        self.operations.deinit(allocator);
        self.operation_indices.deinit(allocator);
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

    pub fn init(allocator: Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.jobs.items) |*job| job.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
    }

    pub fn createJob(self: *Manager, origin_window_id: ?WindowId) !JobId {
        if (self.next_job_id == std.math.maxInt(JobId)) return error.IdExhausted;
        const id = self.next_job_id;
        try self.jobs.append(self.allocator, .{
            .id = id,
            .origin_window_id = origin_window_id,
        });
        self.next_job_id += 1;
        return id;
    }

    pub fn addOperation(self: *Manager, job_id: JobId, kind: OperationKind) !OperationId {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        if (self.next_operation_id == std.math.maxInt(OperationId)) return error.IdExhausted;

        const id = self.next_operation_id;
        const index = job.operations.items.len;
        try job.operations.ensureUnusedCapacity(self.allocator, 1);
        try job.operation_indices.ensureUnusedCapacity(self.allocator, 1);
        job.operations.appendAssumeCapacity(.{ .id = id, .kind = kind });
        job.operation_indices.putAssumeCapacity(id, index);
        self.next_operation_id += 1;
        return id;
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
        job.state = if (job.operations.items.len == 0) .completed else .queued;
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

    /// One active Operation per Job preserves its FIFO execution order.
    /// The cursor rotates across Jobs after every successful dispatch.
    pub fn dispatchNext(self: *Manager) ?WorkToken {
        const count = self.jobs.items.len;
        if (count == 0) return null;

        for (0..count) |offset| {
            const index = (self.round_robin_cursor + offset) % count;
            const job = &self.jobs.items[index];
            if (job.state != .queued and job.state != .running) continue;

            if (job.operation_state_counts[@intFromEnum(OperationState.running)] != 0) continue;

            while (dequeueReady(job)) |operation_index| {
                const operation = &job.operations.items[operation_index];
                if (operation.state != .pending) continue;

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
            self.recomputeJobState(job);
        }
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

    pub fn operationState(self: *const Manager, job_id: JobId, operation_id: OperationId) ?OperationState {
        const job = self.findJobConst(job_id) orelse return null;
        const operation = findOperationConst(job, operation_id) orelse return null;
        return operation.state;
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
        if (job.state == .paused) return;
        const counts = job.operation_state_counts;
        if (counts[@intFromEnum(OperationState.running)] != 0) {
            job.state = .running;
        } else if (job.ready_count != 0) {
            job.state = .queued;
        } else if (
            counts[@intFromEnum(OperationState.waiting)] != 0 or
            counts[@intFromEnum(OperationState.pending)] != 0
        ) {
            job.state = .waiting;
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
        std.mem.copyBackwards(
            usize,
            job.ready_queue.items[1 .. remaining + 1],
            job.ready_queue.items[0..remaining],
        );
        job.ready_queue.items[0] = operation_index;
        job.ready_queue.items.len = remaining + 1;
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
