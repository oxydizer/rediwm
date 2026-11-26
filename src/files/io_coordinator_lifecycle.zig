//! Coordinator lifecycle: the draining shutdown, abort, and conflicts no
//! window can answer (docs/plans/files-io-threading-and-ownership.md §10).
//! Methods of `Coordinator`, aliased there.
const std = @import("std");
const io_manager = @import("io_manager.zig");
const io_coordinator = @import("io_coordinator.zig");
const Coordinator = io_coordinator.Coordinator;
const JobId = io_manager.JobId;

/// A second quit request, or an explicit abort: cancels every job,
/// ordinary ones included. Callable from any thread.
pub fn requestAbort(self: *Coordinator) void {
    self.abort_requested.store(true, .release);
    self.service.beginShutdown();
}

pub fn beginDraining(self: *Coordinator) void {
    self.draining = true;
    const manager = &self.runtime.manager;
    for (0..manager.jobCount()) |index| {
        const summary = manager.jobSummaryAt(index);
        if (summary.state.isTerminal()) continue;
        // Archive extraction is cancelled cooperatively and its staging
        // cleaned. A paused job cannot finish with no one to resume it.
        if (manager.jobHasArchiveOperation(summary.id) or summary.state == .paused) {
            cancelForShutdown(self, summary.id);
        }
    }
    var preparing = self.preparing.valueIterator();
    while (preparing.next()) |entry| entry.cancelled = true;
}

pub fn abortAll(self: *Coordinator) void {
    self.aborting = true;
    self.cancelAllDeletions();
    const manager = &self.runtime.manager;
    for (0..manager.jobCount()) |index| {
        const summary = manager.jobSummaryAt(index);
        if (!summary.state.isTerminal()) {
            std.log.warn("Files is aborting job {d}", .{summary.id});
            cancelForShutdown(self, summary.id);
        }
    }
    var preparing = self.preparing.valueIterator();
    while (preparing.next()) |entry| entry.cancelled = true;
}

pub fn cancelForShutdown(self: *Coordinator, job_id: JobId) void {
    self.runtime.cancelJob(job_id) catch |err| {
        std.log.err("Files could not cancel job {d} at shutdown: {s}", .{ job_id, @errorName(err) });
    };
}

/// With no window to answer, a conflict cancels its job. It can never
/// overwrite data unasked, nor leave the process waiting forever.
pub fn cancelUnanswerableConflicts(self: *Coordinator) void {
    const manager = &self.runtime.manager;
    var last: ?io_manager.ConflictId = null;
    while (manager.nextConflict()) |conflict| {
        if (last == conflict.id) break; // could not be cancelled; retry next pass
        last = conflict.id;
        manager.cancelConflict(conflict.id) catch |err| {
            std.log.err("Files could not cancel unanswered conflict {d}: {s}", .{ conflict.id, @errorName(err) });
            break;
        };
    }
}

/// Draining is done when no job is left (finished jobs retire on their
/// own once their executors and resources are released; deletions are
/// ordinary work and finish), nothing is being prepared or cleaned up, and
/// no accepted command is queued.
pub fn isIdle(self: *Coordinator) bool {
    return self.runtime.manager.jobCount() == 0 and
        self.preparing.count() == 0 and
        self.deletions.count() == 0 and
        self.archives.count() == 0 and
        self.task_backlog.items.len == 0 and
        self.prepare_backlog.items.len == 0 and
        self.tasks.isIdle() and
        self.staging_backlog.items.len == 0 and
        self.staging_tasks.isIdle() and
        !self.service.hasQueuedCommands();
}
