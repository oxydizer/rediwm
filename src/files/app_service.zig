//! This window's side of the Files I/O service: the commands it sends, the
//! job records it reads, and the deletion jobs it started (stage S3a,
//! docs/plans/files-io-service-architecture.md). Nothing here waits: a busy
//! service is retried on a later turn of the event loop (threading §3).
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const App = app_mod.App;
const io_service = @import("io_service.zig");
const io_window_link = @import("io_window_link.zig");
const io_coordinator = @import("io_coordinator.zig");
const app_requests = @import("app_requests.zig");
const app_transfers = @import("app_transfers.zig");
const jobs_card = @import("app_jobs_card.zig");
const app_ghosts = @import("app_ghosts.zig");

/// A window cannot have more submits in flight than it has outcome slots.
pub const max_deletions = io_service.outcome_slots_per_window;

pub const Deletion = struct {
    tag: u64,
    kind: io_service.DeletionKind,
};

pub const Link = struct {
    handle: ?io_service.Handle = null,
    outbox: io_window_link.Outbox = .{},
    reader: io_window_link.Reader = .{},
    last_fetch: ?io_service.FetchResult = null,
    /// The service's update wake fired since the last read.
    dirty: bool = false,
    deletions: [max_deletions]Deletion = undefined,
    deletion_count: usize = 0,
    /// Requests waiting for their reply: at most one per reply slot.
    requests: [io_service.reply_slots_per_window]app_requests.Entry = undefined,
    /// Every service job, for the Transfers card (`app_jobs.zig`).
    jobs: @import("app_jobs.zig").Model = .{},
    /// Ghost rows of transfers into the folder shown (`app_ghosts.zig`).
    ghosts: app_ghosts.State = .{},
    /// Copies and moves this window submitted (`app_transfers.zig`).
    transfers: app_transfers.List = .{},
    /// Archive jobs this window submitted (`app_archives.zig`).
    archives: @import("app_archives.zig").List = .{},
    request_count: usize = 0,
    /// Tags of submits and requests alike.
    next_tag: u64 = 1,

    /// Pending requests are freed by `app_requests.deinitPending` first.
    pub fn deinit(self: *Link) void {
        self.outbox.deinit();
    }

    pub fn takeRequest(self: *Link, tag: u64) ?app_requests.Pending {
        for (self.requests[0..self.request_count], 0..) |entry, i| {
            if (entry.tag != tag) continue;
            self.requests[i] = self.requests[self.request_count - 1];
            self.request_count -= 1;
            return entry.pending;
        }
        return null;
    }

    fn take(self: *Link, tag: u64) ?Deletion {
        for (self.deletions[0..self.deletion_count], 0..) |deletion, i| {
            if (deletion.tag != tag) continue;
            self.deletions[i] = self.deletions[self.deletion_count - 1];
            self.deletion_count -= 1;
            return deletion;
        }
        return null;
    }
};

/// Starts a deletion job. The dialog's paths are copied; the job runs in the
/// service and reports back through this window's job records.
pub fn submitDeletion(self: *App, kind: io_service.DeletionKind, paths: []const []const u8, trash_dir: ?[]const u8) void {
    const link = &self.service;
    const handle = link.handle orelse return failNotice(self, kind, null);
    if (link.deletion_count == max_deletions) return self.setStatusNotice(tr("Too many deletions running"), true);
    var command: io_service.Command = .{
        .kind = .submit_job,
        .submit_tag = link.next_tag,
        .payload = io_service.OwnedPayload.createDeletion(self.allocator, kind, paths, trash_dir) catch
            return failNotice(self, kind, null),
    };
    defer command.deinitPayload();
    link.outbox.send(handle, &command) catch |err| {
        std.log.warn("Files deletion not submitted: {s}", .{@errorName(err)});
        return failNotice(self, kind, null);
    };
    link.deletions[link.deletion_count] = .{ .tag = link.next_tag, .kind = kind };
    link.deletion_count += 1;
    link.next_tag += 1;
    self.setStatusNotice(switch (kind) {
        .delete, .delete_from_trash => tr("Deleting items…"),
        .trash => tr("Moving items to Trash…"),
        .empty_trash => tr("Emptying Trash…"),
    }, false);
}

/// Gives a window-owned resource back to the service, which deletes it on a
/// worker. A window without a handle has nothing of the service's to give.
pub fn disposeResource(raw: *anyopaque, resource_id: u64) void {
    const link: *Link = @ptrCast(@alignCast(raw));
    const handle = link.handle orelse return;
    var command: io_service.Command = .{ .kind = .dispose_resource, .resource_id = resource_id };
    link.outbox.send(handle, &command) catch |err| {
        // Not lost: the window's resources are disposed when it closes.
        std.log.warn("Files could not give back resource {d}: {s}", .{ resource_id, @errorName(err) });
    };
}

/// The service's update wake fired: read the table on the next step.
pub fn serviceUpdated(self: *App) void {
    self.service.dirty = true;
}

/// One bounded turn: retries refused commands and reads changed records.
pub fn stepService(self: *App) void {
    const link = &self.service;
    const handle = link.handle orelse return;
    link.outbox.flush(handle) catch |err| {
        std.log.warn("Files service command refused: {s}", .{@errorName(err)});
    };
    app_ghosts.updateWatches(self);
    app_transfers.checkConflicts(self);
    if (!link.dirty and !link.reader.pending) return;
    link.dirty = false;
    var records: [16]io_service.JobRecord = undefined;
    link.last_fetch = link.reader.fetch(handle, &records) catch |err| {
        std.log.warn("Files job records unreadable: {s}", .{@errorName(err)});
        link.reader.pending = false;
        return;
    };
    const fetched = link.last_fetch orelse return;
    const rows_before = jobs_card.count(self);
    const revision = link.jobs.revision;
    if (fetched.resync) link.jobs.clear();
    for (records[0..fetched.count]) |record| link.jobs.apply(record);
    if (link.jobs.revision != revision) {
        jobs_card.changed(self, rows_before);
        // The Transfers view lists every job with its progress.
        if (self.transfer_view.active) self.invalidate();
    }
    for (records[0..fetched.count]) |record| {
        if (record.origin_window_id != handle.window_id) continue;
        if (app_transfers.onRecord(self, record)) continue;
        if (@import("app_archives.zig").onRecord(self, record)) continue;
        if (!record.state.isTerminal()) continue;
        const deletion = link.take(record.submit_tag) orelse continue;
        finishDeletion(self, deletion.kind, record);
    }
    app_requests.takeReplies(self);
    app_ghosts.updateWatches(self);
    app_ghosts.takeViews(self);
    app_transfers.checkConflicts(self);
}

/// How soon the event loop must step this window for the service: null
/// when it can wait for the update wake.
pub fn serviceTimeout(self: *const App) ?i32 {
    const link = &self.service;
    if (link.outbox.pending() or link.dirty) return 1;
    return link.reader.pollTimeoutMs(link.last_fetch);
}

fn finishDeletion(self: *App, kind: io_service.DeletionKind, record: io_service.JobRecord) void {
    switch (record.state) {
        .completed => self.setStatusNotice(switch (kind) {
            .delete, .delete_from_trash => tr("Items permanently deleted"),
            .trash => tr("Items moved to Trash"),
            .empty_trash => tr("Trash emptied"),
        }, false),
        .cancelled => self.setStatusNotice(tr("Cancelled"), false),
        else => failNotice(self, kind, record.error_code),
    }
    self.refresh();
}

fn failNotice(self: *App, kind: io_service.DeletionKind, code: ?u8) void {
    if (code == @backingInt(io_coordinator.RejectionCode.trash_unavailable))
        return self.setStatusNotice(tr("Trash unavailable (gio not installed)"), true);
    self.setStatusNotice(switch (kind) {
        .delete, .delete_from_trash => tr("Could not delete all items"),
        .trash => tr("Could not move all items to Trash"),
        .empty_trash => tr("Could not empty Trash"),
    }, true);
}
