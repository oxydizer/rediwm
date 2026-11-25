//! Archive jobs on the coordinator (stage S4): extraction into a folder,
//! one member opened, and members exported for the clipboard, a drag or
//! Open With. Methods of `Coordinator`, aliased there.
//!
//! Extraction runs on an operation worker into private staging and waits
//! at the Manager's publication barrier. What happens then depends on the
//! purpose:
//! * extract: a task lists the staging folder's top level, the entries are
//!   registered as publication roots (from there on an ordinary transfer,
//!   with its conflicts and ghosts), and the staging is deleted on a worker
//!   once publication has drained;
//! * member and export: nothing is published; the staging is handed to the
//!   window that asked, which takes it with an `archive_handoff` request and
//!   disposes of it through the service when done.
//!
//! The coordinator itself never touches the staging folder.
const std = @import("std");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_requests = @import("io_requests.zig");
const io_service_tasks = @import("io_service_tasks.zig");
const io_coordinator = @import("io_coordinator.zig");
const Coordinator = io_coordinator.Coordinator;
const JobId = io_service.JobId;

pub const Archive = struct {
    window_id: io_service.WindowId,
    operation_id: io_manager.OperationId,
    purpose: io_service.ArchivePurpose,
    /// The worker's token, once the extraction waits at the barrier.
    token: ?io_manager.WorkToken = null,
    /// A scan task is out (extract only).
    scanning: bool = false,
    /// No more publication roots will be registered.
    registration_closed: bool = false,
};

/// Staging handed to a window, until it asks for it.
pub const Handoff = struct {
    window_id: io_service.WindowId,
    resource_id: u64,
    /// Owned.
    staging: []u8,
};

pub fn deinitArchives(self: *Coordinator) void {
    self.archives.deinit(self.allocator);
    var handoffs = self.handoffs.valueIterator();
    while (handoffs.next()) |entry| self.allocator.free(entry.staging);
    self.handoffs.deinit(self.allocator);
}

/// Creates the Manager job for an archive submit and queues it. Accept is
/// bounded and does no I/O: the Manager only checks the paths' shape.
pub fn submitArchive(self: *Coordinator, routed: *io_service.RoutedCommand, record_value: io_service.JobRecord) void {
    var record = record_value;
    const request = &routed.command.payload.?.data.archive;
    record.kind = .extract;
    record.source_count = 1;
    record.setLabel(std.fs.path.basename(request.source));

    const manager = &self.runtime.manager;
    const job_id = manager.createJob(routed.window_id) catch |err| return self.failSubmit(&record, err);
    record.id = job_id;
    const operation_id = blk: {
        const member_path: ?[]const u8 = if (request.purpose == .member) request.members[0] else null;
        const members: []const []const u8 = if (request.purpose == .member) &.{} else @ptrCast(request.members);
        const operation_id = manager.addArchiveOperation(
            job_id,
            if (request.purpose == .member) .archive_member_extract else .archive_extract,
            .{
                .source_path = request.source,
                .staging_parent = request.destination,
                .member_path = member_path,
                .member_paths = members,
            },
        ) catch |err| {
            std.debug.assert(manager.discardPlanningJob(job_id));
            return self.failSubmit(&record, err);
        };
        manager.setDestinationDirectory(job_id, request.destination) catch |err| {
            std.debug.assert(manager.discardPlanningJob(job_id));
            return self.failSubmit(&record, err);
        };
        break :blk operation_id;
    };
    self.archives.ensureUnusedCapacity(self.allocator, 1) catch |err| {
        std.debug.assert(manager.discardPlanningJob(job_id));
        return self.failSubmit(&record, err);
    };
    self.published.ensureUnusedCapacity(self.allocator, 1) catch |err| {
        std.debug.assert(manager.discardPlanningJob(job_id));
        return self.failSubmit(&record, err);
    };
    manager.queueJob(job_id) catch |err| {
        std.debug.assert(manager.discardPlanningJob(job_id));
        return self.failSubmit(&record, err);
    };
    record.state = .queued;
    self.service.createJobRecord(record, true) catch |err| {
        std.log.err("Files job record for archive job {d} failed: {s}", .{ job_id, @errorName(err) });
        self.runtime.cancelJob(job_id) catch {};
    };
    self.published.putAssumeCapacity(job_id, .{ .record = record });
    self.archives.putAssumeCapacity(job_id, .{
        .window_id = routed.window_id,
        .operation_id = operation_id,
        .purpose = request.purpose,
    });
}

/// Steps every archive job. True when it gave the executors new work, so
/// the caller dispatches it in this pass.
pub fn pumpArchives(self: *Coordinator) bool {
    const manager = &self.runtime.manager;
    const executor = if (self.runtime.operation_executor) |*value| value else return false;
    var changed = false;
    var iterator = self.archives.iterator();
    var ended: [16]JobId = undefined;
    var ended_count: usize = 0;
    while (iterator.next()) |entry| {
        const job_id = entry.key_ptr.*;
        const archive = entry.value_ptr;
        const state = manager.jobState(job_id);
        if (state == null or state.?.isTerminal()) {
            // Cancelled or failed: whatever staging is left goes.
            if (executor.detachArchiveStaging(job_id, archive.operation_id)) |staging| deleteStaging(self, staging);
            if (archive.scanning) continue; // the scan result is still due
            if (ended_count < ended.len) {
                ended[ended_count] = job_id;
                ended_count += 1;
            }
            continue;
        }
        if (archive.token == null) {
            archive.token = executor.archiveStagingToken(job_id, archive.operation_id);
            if (archive.token == null) continue;
        }
        const token = archive.token.?;
        if (!archive.registration_closed) switch (archive.purpose) {
            .extract => if (!archive.scanning) {
                const path = executor.archiveStagingPath(token) orelse {
                    failPublication(self, archive);
                    changed = true;
                    continue;
                };
                const owned = self.allocator.dupeSentinel(u8, path, 0) catch {
                    failPublication(self, archive);
                    changed = true;
                    continue;
                };
                archive.scanning = true;
                self.submitTask(.{ .scan_staging = .{ .token = token, .path = owned } });
            },
            // Nothing is published: the barrier can close at once.
            .member, .@"export" => {
                manager.closeArchivePublication(token) catch {
                    failPublication(self, archive);
                    changed = true;
                    continue;
                };
                archive.registration_closed = true;
                changed = true;
            },
        };
        if (!archive.registration_closed or manager.archivePublicationReady(token) != true) continue;

        const staging = executor.detachArchiveStaging(job_id, archive.operation_id) orelse continue;
        switch (archive.purpose) {
            .extract => deleteStaging(self, staging),
            .member, .@"export" => handToWindow(self, job_id, archive.window_id, staging),
        }
        if (!manager.completeArchivePublication(token)) {
            std.log.err("Files could not complete archive publication of job {d}", .{job_id});
        }
        changed = true;
        if (ended_count < ended.len) {
            ended[ended_count] = job_id;
            ended_count += 1;
        }
    }
    for (ended[0..ended_count]) |job_id| _ = self.archives.remove(job_id);
    return changed or ended_count > 0;
}

/// A scan task returned: register the entries as publication roots, then
/// close registration. Directory roots schedule their own discovery.
pub fn finishScan(self: *Coordinator, token: io_manager.WorkToken, result: *anyerror!io_service_tasks.Scan) void {
    const archive = self.archives.getPtr(token.job_id) orelse return;
    archive.scanning = false;
    const manager = &self.runtime.manager;
    const state = manager.jobState(token.job_id) orelse return;
    if (state.isTerminal()) return;
    const scan = if (result.*) |*scan| scan else |err| {
        std.log.err("Files could not list archive staging of job {d}: {s}", .{ token.job_id, @errorName(err) });
        return failPublication(self, archive);
    };
    const executor = if (self.runtime.operation_executor) |*value| value else return failPublication(self, archive);
    const staging_path = executor.archiveStagingPath(token) orelse return failPublication(self, archive);
    for (scan.records.items) |record| {
        if (record.entry_error or record.kind == .other) return failPublication(self, archive);
        const source_path = std.fs.path.join(self.allocator, &.{ staging_path, record.name }) catch
            return failPublication(self, archive);
        defer self.allocator.free(source_path);
        _ = manager.addArchivePublicationRoot(token, .{
            .name = record.name,
            .source_path = source_path,
            .kind = record.kind,
            .metadata = record.metadata,
            .symlink_target = record.symlink_target,
        }) catch return failPublication(self, archive);
    }
    manager.closeArchivePublication(token) catch return failPublication(self, archive);
    archive.registration_closed = true;
}

fn failPublication(self: *Coordinator, archive: *Archive) void {
    if (archive.registration_closed) return;
    archive.registration_closed = true;
    const token = archive.token orelse return;
    self.runtime.manager.failArchivePublication(token) catch |err| {
        std.log.err("Files could not fail archive publication of job {d}: {s}", .{ token.job_id, @errorName(err) });
    };
}

/// Moves staging to a worker, which deletes it and releases its entry.
fn deleteStaging(self: *Coordinator, staging: anytype) void {
    self.runtime.resource_ledger.transfer(staging.handle, .operation_executor, .operation_worker) catch |err| {
        std.log.err("Files could not hand archive staging to a worker: {s}", .{@errorName(err)});
        self.allocator.free(staging.path);
        return;
    };
    self.submitTask(.{ .delete_tree = .{ .handle = staging.handle, .path = staging.path } });
}

fn handToWindow(self: *Coordinator, job_id: JobId, window_id: io_service.WindowId, staging: anytype) void {
    const kept = self.allocator.dupe(u8, staging.path) catch return deleteStaging(self, staging);
    self.handoffs.ensureUnusedCapacity(self.allocator, 1) catch {
        self.allocator.free(kept);
        return deleteStaging(self, staging);
    };
    self.handResourceToWindow(staging.handle, .operation_executor, window_id, staging.path) catch {
        self.allocator.free(kept);
        return deleteStaging(self, staging);
    };
    self.handoffs.putAssumeCapacity(job_id, .{ .window_id = window_id, .resource_id = staging.handle.id, .staging = kept });
}

/// The `archive_handoff` reply: the staging, once, to the window it was
/// handed to.
pub fn takeHandoff(self: *Coordinator, window_id: io_service.WindowId, job_id: JobId) ?io_requests.Handoff {
    const entry = self.handoffs.get(job_id) orelse return null;
    if (entry.window_id != window_id) return null;
    _ = self.handoffs.remove(job_id);
    return .{ .resource_id = entry.resource_id, .staging = entry.staging };
}

/// A window closed: what it never took goes with its other resources.
pub fn dropWindowHandoffs(self: *Coordinator, window_id: io_service.WindowId) void {
    while (true) {
        var iterator = self.handoffs.iterator();
        const job_id = while (iterator.next()) |entry| {
            if (entry.value_ptr.window_id == window_id) break entry.key_ptr.*;
        } else return;
        const removed = self.handoffs.fetchRemove(job_id).?;
        self.allocator.free(removed.value.staging);
    }
}
