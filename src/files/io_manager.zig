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

    fn deinit(self: *Operation, allocator: Allocator) void {
        self.dependencies.deinit(allocator);
    }
};

const Job = struct {
    id: JobId,
    origin_window_id: ?WindowId,
    state: JobState = .planning,
    operations: std.ArrayList(Operation) = .empty,

    fn deinit(self: *Job, allocator: Allocator) void {
        for (self.operations.items) |*operation| operation.deinit(allocator);
        self.operations.deinit(allocator);
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
        try job.operations.append(self.allocator, .{ .id = id, .kind = kind });
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
        _ = findOperation(job, dependency_id) orelse return error.UnknownDependency;
        for (operation.dependencies.items) |existing| {
            if (existing == dependency_id) return error.DuplicateDependency;
        }
        try operation.dependencies.append(self.allocator, dependency_id);
    }

    pub fn queueJob(self: *Manager, job_id: JobId) !void {
        const job = self.findJob(job_id) orelse return error.UnknownJob;
        if (job.state != .planning) return error.InvalidJobState;
        try validateAcyclic(self.allocator, job);
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
        operation.state = .pending;
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

            var has_running = false;
            for (job.operations.items) |operation| {
                if (operation.state == .running) {
                    has_running = true;
                    break;
                }
            }
            if (has_running) continue;

            for (job.operations.items) |*operation| {
                if (operation.state != .pending) continue;
                if (!dependenciesCompleted(job, operation)) continue;
                if (operation.generation == std.math.maxInt(u64)) return null;

                operation.generation += 1;
                operation.state = .running;
                job.state = .running;
                self.round_robin_cursor = (index + 1) % count;
                return .{
                    .job_id = job.id,
                    .operation_id = operation.id,
                    .generation = operation.generation,
                };
            }
        }
        return null;
    }

    /// Rejects stale and duplicate results. A yielded Operation returns to FIFO.
    pub fn completeWork(self: *Manager, token: WorkToken, result: WorkResult) bool {
        const job = self.findJob(token.job_id) orelse return false;
        const operation = findOperation(job, token.operation_id) orelse return false;
        if (operation.state != .running or operation.generation != token.generation) return false;

        operation.state = switch (result) {
            .yielded => .pending,
            .completed => .completed,
            .waiting => .waiting,
            .skipped => .skipped,
            .failed => .failed,
            .cancelled => .cancelled,
        };
        self.skipOperationsWithUnmetDependencies(job);
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

        var has_running = false;
        var has_waiting = false;
        var has_pending = false;
        var has_failed = false;
        var has_cancelled = false;
        var has_completed = false;
        var has_skipped = false;
        var has_ready = false;

        for (job.operations.items) |*operation| {
            switch (operation.state) {
                .running => has_running = true,
                .waiting => has_waiting = true,
                .pending => {
                    has_pending = true;
                    if (dependenciesCompleted(job, operation)) has_ready = true;
                },
                .failed => has_failed = true,
                .cancelled => has_cancelled = true,
                .completed => has_completed = true,
                .skipped => has_skipped = true,
            }
        }

        if (has_running) {
            job.state = .running;
        } else if (has_ready) {
            job.state = .queued;
        } else if (has_waiting or has_pending) {
            job.state = .waiting;
        } else if (has_failed) {
            job.state = if (has_completed) .completed_with_errors else .failed;
        } else if (has_cancelled) {
            job.state = .cancelled;
        } else {
            job.state = .completed;
        }
    }

    fn skipOperationsWithUnmetDependencies(self: *Manager, job: *Job) void {
        _ = self;
        var changed = true;
        while (changed) {
            changed = false;
            for (job.operations.items) |*operation| {
                if (operation.state != .pending) continue;
                for (operation.dependencies.items) |dependency_id| {
                    const dependency = findOperation(job, dependency_id) orelse continue;
                    if (dependency.state.isTerminal() and dependency.state != .completed) {
                        operation.state = .skipped;
                        changed = true;
                        break;
                    }
                }
            }
        }
    }
};

fn findOperation(job: *Job, id: OperationId) ?*Operation {
    for (job.operations.items) |*operation| {
        if (operation.id == id) return operation;
    }
    return null;
}

fn findOperationConst(job: *const Job, id: OperationId) ?*const Operation {
    for (job.operations.items) |*operation| {
        if (operation.id == id) return operation;
    }
    return null;
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
    const processed = try allocator.alloc(bool, operations.len);
    defer allocator.free(processed);
    @memset(processed, false);

    for (operations, 0..) |operation, index| indegree[index] = operation.dependencies.items.len;

    var completed: usize = 0;
    while (completed < operations.len) {
        var candidate: ?usize = null;
        for (operations, 0..) |_, index| {
            if (!processed[index] and indegree[index] == 0) {
                candidate = index;
                break;
            }
        }
        const index = candidate orelse return error.DependencyCycle;
        processed[index] = true;
        completed += 1;

        const completed_id = operations[index].id;
        for (operations, 0..) |operation, dependent_index| {
            if (processed[dependent_index]) continue;
            for (operation.dependencies.items) |dependency_id| {
                if (dependency_id == completed_id) {
                    indegree[dependent_index] -= 1;
                    break;
                }
            }
        }
    }
}
