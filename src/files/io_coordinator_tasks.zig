//! Service tasks on the coordinator: handing blocking work to its lane's
//! pool and applying what comes back (threading §8). Methods of
//! `Coordinator`, aliased there.
const std = @import("std");
const io_transfer_plan = @import("io_transfer_plan.zig");
const io_service_tasks = @import("io_service_tasks.zig");
const io_resource_ledger = @import("io_resource_ledger.zig");
const io_service = @import("io_service.zig");
const Coordinator = @import("io_coordinator.zig").Coordinator;
const stalls = @import("io_coordinator_stalls.zig");
const JobId = io_service.JobId;

const Lane = struct { pool: *io_service_tasks.Pool, backlog: *std.ArrayList(io_service_tasks.Task) };

fn lane(self: *Coordinator, which: io_service_tasks.Lane) Lane {
    return switch (which) {
        .tasks => .{ .pool = self.tasks, .backlog = &self.task_backlog },
        .staging => .{ .pool = self.staging_tasks, .backlog = &self.staging_backlog },
    };
}

/// Every task enters its lane's backlog and goes to the pool from there
/// (`submitBacklogs`), in order, except that:
///
/// * requests go before prepares (worker-pools §4.6): a person waits on each
///   request, while a prepare only delays a job already shown as planning. At
///   most `worker_count` prepares are in the pool; the rest wait here, so a
///   request never queues behind a prepare that has not started;
/// * a task for a suspect mount waits while the ones behind it pass
///   (`io_coordinator_stalls.taskHeld`, §4.2).
pub fn submitTask(self: *Coordinator, task: io_service_tasks.Task) void {
    const backlog = if (task == .prepare_transfer)
        &self.prepare_backlog
    else
        lane(self, io_service_tasks.laneOf(task)).backlog;
    backlog.append(self.allocator, task) catch return dropTask(self, task);
    submitBacklogs(self);
}

fn submitBacklogs(self: *Coordinator) void {
    submitBacklog(self, lane(self, .tasks));
    submitBacklog(self, lane(self, .staging));
    // Queued requests went first; prepares take what room is left.
    var i: usize = 0;
    while (i < self.prepare_backlog.items.len and self.prepares_in_pool < io_service_tasks.worker_count) {
        const task = self.prepare_backlog.items[i];
        if (stalls.taskHeld(self, task)) {
            i += 1;
            continue;
        }
        if (!self.tasks.trySubmit(task)) break;
        _ = self.prepare_backlog.orderedRemove(i);
        self.prepares_in_pool += 1;
    }
}

fn submitBacklog(self: *Coordinator, into: Lane) void {
    var i: usize = 0;
    while (i < into.backlog.items.len) {
        const task = into.backlog.items[i];
        if (stalls.taskHeld(self, task)) {
            i += 1;
            continue;
        }
        if (!into.pool.trySubmit(task)) break;
        _ = into.backlog.orderedRemove(i);
    }
}

/// Out of memory with a full pool: give the work up visibly.
fn dropTask(self: *Coordinator, task: io_service_tasks.Task) void {
    std.log.err("Files service task dropped: out of memory", .{});
    switch (task) {
        .prepare_transfer => |prepare| {
            prepare.payload.deinit();
            _ = self.preparing.remove(prepare.job_id);
            self.endPlanningJob(prepare.job_id, .failed, error.OutOfMemory);
        },
        .delete_tree => |delete| {
            self.allocator.free(delete.path);
            self.finishCleanup(delete.handle);
        },
        .request => |request| {
            request.payload.deinit();
            self.service.cancelReplyReservation(request.window_id);
        },
        .scan_staging => |scan| {
            self.allocator.free(scan.path);
            var failed: anyerror!io_service_tasks.Scan = error.OutOfMemory;
            self.finishScan(scan.token, &failed);
        },
    }
}

pub fn pumpTasks(self: *Coordinator) void {
    collect(self, lane(self, .tasks));
    collect(self, lane(self, .staging));
    submitBacklogs(self);
}

fn collect(self: *Coordinator, from: Lane) void {
    _ = from.pool.drainWake();
    while (from.pool.tryPopResult()) |result_value| {
        var result = result_value;
        defer result.deinit(self.allocator);
        switch (result) {
            .prepared => |*prepared| {
                self.prepares_in_pool -= 1;
                applyPrepared(self, prepared.job_id, &prepared.plan);
            },
            .deleted => |deleted| {
                if (deleted.failed) |err| std.log.err(
                    "Files could not delete {s}: {s}",
                    .{ deleted.path, @errorName(err) },
                );
                self.finishCleanup(deleted.handle);
            },
            .replied => |replied| if (replied.reply) |reply|
                self.service.deliverReply(replied.window_id, reply)
            else
                self.service.cancelReplyReservation(replied.window_id),
            .scanned => |*scanned| self.finishScan(scanned.token, &scanned.scan),
        }
    }
}

/// Applies a prepared plan to its planning job, unless the job was
/// cancelled meanwhile or the plan failed.
fn applyPrepared(self: *Coordinator, job_id: JobId, plan_result: *anyerror!io_transfer_plan.TransferPlan) void {
    const entry = self.preparing.fetchRemove(job_id) orelse return;
    if (entry.value.cancelled) return self.endPlanningJob(job_id, .cancelled, null);
    const plan = if (plan_result.*) |*plan| plan else |err| return self.endPlanningJob(job_id, .failed, err);
    self.applyTransferPlan(job_id, entry.value.mode, plan) catch |err|
        return self.endPlanningJob(job_id, .failed, err);
}

/// A worker finished destroying a resource it held: release its entry.
/// A failed delete is released too; it is under a known staging root
/// that a later start sweeps (roadmap phase 5).
pub fn finishCleanup(self: *Coordinator, handle: io_resource_ledger.Handle) void {
    self.runtime.resource_ledger.release(handle, .operation_worker) catch |err| {
        std.log.err("Files cleanup release of resource {d} failed: {s}", .{ handle.id, @errorName(err) });
    };
}

pub fn discardDeleteResult(raw: ?*anyopaque, handle: io_resource_ledger.Handle) void {
    const self: *Coordinator = @ptrCast(@alignCast(raw.?));
    self.finishCleanup(handle);
}

pub fn discardTaskBacklog(self: *Coordinator) void {
    discardBacklog(self, &self.task_backlog);
    discardBacklog(self, &self.prepare_backlog);
    discardBacklog(self, &self.staging_backlog);
}

fn discardBacklog(self: *Coordinator, backlog: *std.ArrayList(io_service_tasks.Task)) void {
    for (backlog.items) |task| switch (task) {
        .prepare_transfer => |prepare| prepare.payload.deinit(),
        .delete_tree => |delete| {
            self.allocator.free(delete.path);
            self.finishCleanup(delete.handle);
        },
        .request => |request| request.payload.deinit(),
        .scan_staging => |scan| self.allocator.free(scan.path),
    };
    backlog.clearRetainingCapacity();
}
