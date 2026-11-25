//! Deletion jobs on the coordinator (`io_deletion.zig`). Methods of
//! `Coordinator`, aliased there.
//!
//! A deletion job is a service job without a Manager job: its record, its
//! cancellation and its end are kept here. Its ids come from their own range,
//! apart from Manager job ids and failed-submit ids.
const std = @import("std");
const io_service = @import("io_service.zig");
const io_deletion = @import("io_deletion.zig");
const io_coordinator = @import("io_coordinator.zig");
const Coordinator = io_coordinator.Coordinator;
const JobId = io_service.JobId;

pub const id_base: JobId = 1 << 62;

/// How often a running deletion's progress is published.
const progress_interval_ms = 250;

pub const Deletion = struct {
    control: *io_deletion.Control,
    record: io_service.JobRecord,
    last_progress_ms: i64 = 0,
};

pub fn recordKind(kind: io_service.DeletionKind) io_service.JobKind {
    return switch (kind) {
        .delete, .delete_from_trash => .delete,
        .trash => .trash,
        .empty_trash => .empty_trash,
    };
}

/// Accepts a deletion submit: its record appears queued at once and the
/// payload moves to a deletion worker. Bounded; no I/O.
pub fn submitDeletion(self: *Coordinator, routed: *io_service.RoutedCommand, record_value: io_service.JobRecord) void {
    var record = record_value;
    const payload = routed.command.payload.?;
    const request = &payload.data.deletion;
    record.kind = recordKind(request.kind);
    record.source_count = @intCast(@min(request.paths.len, std.math.maxInt(u32)));
    record.total_items = io_deletion.itemCount(request);
    if (request.kind == .empty_trash)
        record.setLabel("Trash")
    else if (request.paths.len > 0)
        record.setLabel(std.fs.path.basename(request.paths[0]));

    const control = self.allocator.create(io_deletion.Control) catch |err|
        return self.failSubmit(&record, err);
    control.* = .{};
    self.deletions.ensureUnusedCapacity(self.allocator, 1) catch |err| {
        self.allocator.destroy(control);
        return self.failSubmit(&record, err);
    };
    record.id = self.next_deletion_id;
    record.state = .queued;
    self.service.createJobRecord(record, true) catch |err| {
        std.log.err("Files job record for deletion failed: {s}", .{@errorName(err)});
        self.allocator.destroy(control);
        return;
    };
    self.next_deletion_id += 1;
    if (!self.deletion_pool.trySubmit(.{ .job_id = record.id, .payload = payload, .control = control })) {
        // The pool holds as many jobs as the live table: only a stopping
        // pool refuses.
        record.state = .failed;
        record.error_code = @backingInt(io_coordinator.RejectionCode.other);
        record.finished_at_ms = record.started_at_ms;
        self.service.updateJobRecord(record) catch {};
        self.service.retireJobRecord(record.id) catch {};
        self.allocator.destroy(control);
        return;
    }
    // The worker owns the payload from here on.
    routed.command.payload = null;
    self.deletions.putAssumeCapacity(record.id, .{ .control = control, .record = record });
}

/// Whether `job_id` is a deletion; if so its cancel is requested.
pub fn cancelDeletion(self: *Coordinator, job_id: JobId) bool {
    const entry = self.deletions.getPtr(job_id) orelse return false;
    if (entry.record.cancel_requested) return true;
    entry.control.cancel.store(true, .release);
    entry.record.cancel_requested = true;
    self.service.updateJobRecord(entry.record) catch {};
    return true;
}

pub fn cancelAllDeletions(self: *Coordinator) void {
    var iterator = self.deletions.keyIterator();
    while (iterator.next()) |job_id| _ = cancelDeletion(self, job_id.*);
}

/// Ends the deletions whose workers returned: final record, then retirement.
pub fn pumpDeletions(self: *Coordinator) void {
    _ = self.deletion_pool.drainWake();
    while (self.deletion_pool.tryPopResult()) |result| {
        defer result.payload.deinit();
        const entry = self.deletions.fetchRemove(result.job_id) orelse continue;
        defer self.allocator.destroy(entry.value.control);
        var record = entry.value.record;
        record.state = result.outcome.state;
        record.completed_items = entry.value.control.done_items.load(.acquire);
        record.error_code = if (result.outcome.err) |err| @backingInt(io_coordinator.rejectionCode(err)) else 0;
        record.finished_at_ms = io_coordinator.wallClockMs();
        self.service.updateJobRecord(record) catch |err| {
            std.log.err("Files deletion record {d} update failed: {s}", .{ record.id, @errorName(err) });
        };
        self.service.retireJobRecord(record.id) catch |err| {
            std.log.err("Files deletion record {d} retirement failed: {s}", .{ record.id, @errorName(err) });
        };
    }
}

/// Publishes running deletions: the move to `running`, and item progress at
/// most every `progress_interval_ms`. Returns when to look again.
pub fn publishDeletions(self: *Coordinator, now: i64) ?i64 {
    var deadline: ?i64 = null;
    var iterator = self.deletions.valueIterator();
    while (iterator.next()) |entry| {
        var next = entry.record;
        if (entry.control.started.load(.acquire)) next.state = .running;
        next.completed_items = entry.control.done_items.load(.acquire);
        const structural = next.state != entry.record.state;
        const progressed = next.completed_items != entry.record.completed_items;
        if (structural or (progressed and now - entry.last_progress_ms >= progress_interval_ms)) {
            self.service.updateJobRecord(next) catch continue;
            entry.record = next;
            entry.last_progress_ms = now;
        }
        // Workers raise no wake for progress: look again while one runs.
        const at = entry.last_progress_ms + progress_interval_ms;
        deadline = if (deadline) |d| @min(d, at) else at;
    }
    return deadline;
}
