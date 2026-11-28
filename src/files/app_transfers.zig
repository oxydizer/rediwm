//! Copy and move as I/O service jobs (stage S3b): the window submits, keeps
//! what it needs to report the end, and answers the jobs' conflicts. Several
//! transfers may run at once; none of them belongs to the window.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const App = app_mod.App;
const io_service = @import("io_service.zig");
const io_requests = @import("io_requests.zig");
const io_coordinator = @import("io_coordinator.zig");
const app_requests = @import("app_requests.zig");
const ops_mod = @import("ops.zig");

/// A window cannot have more submits in flight than it has outcome slots.
pub const max_transfers = io_service.outcome_slots_per_window;

pub const Transfer = struct {
    tag: u64,
    job_id: io_service.JobId = 0,
    move: bool,
    /// Owned.
    destination: []u8,
    /// Owned: the source paths, for the cut clipboard and the refresh.
    sources: [][]u8,
    /// The cut clipboard this move came from, if any.
    cut_revision: ?usize,
    folder_navigation: ?u32 = null,
    /// The conflict at the head of the queue for this job, from its record.
    pending_conflict: u64 = 0,

    fn deinit(self: *Transfer, allocator: std.mem.Allocator) void {
        allocator.free(self.destination);
        for (self.sources) |path| allocator.free(path);
        allocator.free(self.sources);
    }
};

/// "Apply to all": a job's answer for its later conflicts, one for a folder
/// onto a folder (where Merge is offered) and one for everything else.
pub const Standing = struct {
    job_id: u64 = 0,
    folders: ?io_service.ConflictAction = null,
    others: ?io_service.ConflictAction = null,

    fn answer(self: Standing, can_merge: bool) ?io_service.ConflictAction {
        return if (can_merge) self.folders else self.others;
    }
};

pub const List = struct {
    items: [max_transfers]Transfer = undefined,
    len: usize = 0,
    /// The last conflict this window asked about, so it asks once.
    conflict_asked: u64 = 0,
    standing: [max_transfers]Standing = @splat(.{}),

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items[0..self.len]) |*item| item.deinit(allocator);
        self.len = 0;
    }

    fn find(self: *List, tag: u64) ?*Transfer {
        for (self.items[0..self.len]) |*item| if (item.tag == tag) return item;
        return null;
    }

    fn remove(self: *List, transfer: *Transfer) void {
        const index = (@intFromPtr(transfer) - @intFromPtr(&self.items[0])) / @sizeOf(Transfer);
        self.items[index] = self.items[self.len - 1];
        self.len -= 1;
    }
};

/// Submits a copy or move of `paths` into `directory`. The service checks
/// the sources and the destination; the job's record reports the end.
pub fn submitTransfer(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, clipboard: bool) bool {
    return submit(self, kind, paths, directory, .{
        .cut_revision = if (clipboard and kind == .move and self.clipboard_cut) self.clipboard_revision else null,
    });
}

pub fn submitFolderMove(self: *App, paths: []const []const u8, directory: []const u8, navigation: u32) bool {
    return submit(self, .move, paths, directory, .{ .folder_navigation = navigation });
}

pub fn submitPasteIntoFolder(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, cut_revision: ?usize) bool {
    return submit(self, kind, paths, directory, .{ .resolve_destination = true, .cut_revision = cut_revision });
}

const SubmitOptions = struct {
    folder_navigation: ?u32 = null,
    cut_revision: ?usize = null,
    resolve_destination: bool = false,
};

fn submit(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, options: SubmitOptions) bool {
    const link = &self.service;
    const list = &link.transfers;
    const handle = link.handle orelse return false;
    if (list.len == max_transfers) {
        self.setStatusNotice(tr("Too many transfers running"), true);
        return false;
    }
    const move = kind == .move;
    const destination = self.allocator.dupe(u8, directory) catch return false;
    errdefer self.allocator.free(destination);
    const sources = app_requests.dupeAll(self.allocator, paths) catch {
        self.allocator.free(destination);
        return false;
    };
    var command: io_service.Command = .{
        .kind = .submit_job,
        .submit_tag = link.next_tag,
        .payload = io_service.OwnedPayload.createTransfer(self.allocator, if (move) .move else .copy, directory, paths) catch {
            freeAll(self.allocator, sources);
            self.allocator.free(destination);
            return false;
        },
    };
    defer command.deinitPayload();
    command.payload.?.data.transfer.create_destination = options.folder_navigation != null;
    command.payload.?.data.transfer.resolve_destination = options.resolve_destination;
    link.outbox.send(handle, &command) catch |err| {
        std.log.warn("Files transfer not submitted: {s}", .{@errorName(err)});
        freeAll(self.allocator, sources);
        self.allocator.free(destination);
        self.setStatusNotice(tr("Failed to start transfer job"), true);
        return false;
    };
    list.items[list.len] = .{
        .tag = link.next_tag,
        .folder_navigation = options.folder_navigation,
        .move = move,
        .destination = destination,
        .sources = sources,
        .cut_revision = options.cut_revision,
    };
    list.len += 1;
    link.next_tag += 1;
    var buf: [256]u8 = undefined;
    self.setStatusNotice(if (paths.len == 1)
        (i18n.fmt(&buf, if (move) tr("Moving {name}") else tr("Copying {name}"), .{ .name = std.fs.path.basename(paths[0]) }) catch tr("Copying items"))
    else if (move) tr("Moving items") else tr("Copying items"), false);
    return true;
}

fn freeAll(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Where a transfer of this window goes, by job id.
pub fn destinationOf(self: *App, job_id: io_service.JobId) ?[]const u8 {
    const list = &self.service.transfers;
    for (list.items[0..list.len]) |transfer| if (transfer.job_id == job_id) return transfer.destination;
    return null;
}

/// A record of one of this window's jobs changed. Whether it was a transfer.
pub fn onRecord(self: *App, record: io_service.JobRecord) bool {
    const list = &self.service.transfers;
    const transfer = list.find(record.submit_tag) orelse return false;
    transfer.job_id = record.id;
    if (record.state.isTerminal()) {
        finish(self, transfer, record);
        transfer.deinit(self.allocator);
        list.remove(transfer);
        return true;
    }
    transfer.pending_conflict = record.pending_conflict;
    return true;
}

/// Asks about the conflict at the head of the queue once no dialog is
/// open: a job of this window's, or one whose window has closed. Called
/// every step, so a dialog that closes lets the question through.
pub fn checkConflicts(self: *App) void {
    const list = &self.service.transfers;
    const model = &self.service.jobs;
    closeStaleConflict(self);
    if (self.dialog != null) return;
    const handle = self.service.handle orelse return;
    for (model.records[0..model.len]) |record| {
        const conflict = record.pending_conflict;
        if (conflict == 0 or conflict == list.conflict_asked) continue;
        if (record.origin_window_id != handle.window_id and !record.conflict_orphaned) continue;
        askConflict(self, conflict);
        return;
    }
}

/// Asks the service what the dialog for `conflict` shows (a card row
/// waiting for an answer, clicked, asks too).
pub fn askConflict(self: *App, conflict: u64) void {
    if (app_requests.send(self, .{ .conflict_details = .{ .conflict_id = conflict } }, .conflict)) {
        std.log.info("Files window asks about conflict {d}", .{conflict});
        self.service.transfers.conflict_asked = conflict;
    } else std.log.info("Files window could not ask about conflict {d}", .{conflict});
}

/// A conflict dialog whose conflict another window answered, or that the
/// job's end took away, closes.
fn closeStaleConflict(self: *App) void {
    const dialog = self.dialog orelse return;
    if (!dialog.service_conflict) return;
    const id = dialog.manager_conflict_id orelse return;
    const model = &self.service.jobs;
    for (model.records[0..model.len]) |record| {
        if (record.pending_conflict == id) return;
    }
    // Not yet published: the record may still be on its way.
    if (self.service.transfers.conflict_asked == id and !self.service.dirty) {
        std.log.info("Files closes conflict {d}: no job waits on it any more", .{id});
        self.closeDialog();
        self.service.transfers.conflict_asked = 0;
    }
}

fn finish(self: *App, transfer: *Transfer, record: io_service.JobRecord) void {
    const many = transfer.sources.len > 1;
    const move = transfer.move;
    switch (record.state) {
        .completed => self.setStatusNotice(if (many)
            (if (move) tr("Items moved") else tr("Items copied"))
        else if (move) tr("Item moved") else tr("Item copied"), false),
        .cancelled => self.setStatusNotice(if (move) tr("Move cancelled") else tr("Copy cancelled"), true),
        else => self.setStatusNotice(rejection(record.error_code) orelse if (many)
            (if (move) tr("Could not move all items") else tr("Could not copy all items"))
        else if (move) tr("Move failed") else tr("Copy failed"), true),
    }
    // A cut clipboard whose move finished has nothing left to paste. After
    // a partial move it stays: what did move is no longer there to paste.
    if (move and record.state == .completed and transfer.cut_revision != null and
        transfer.cut_revision.? == self.clipboard_revision and self.clipboard_cut and !self.clipboard_is_text)
    {
        dropClipboardPaths(self, transfer.sources);
    }
    if (transfer.folder_navigation) |navigation| {
        if (record.state == .completed and self.navigation_count == navigation and self.dialog == null) {
            self.refreshAndSelectFolder(transfer.destination);
            return;
        }
    }
    if (showsAffected(self, transfer)) self.refresh();
}

/// What a submit refused says.
fn rejection(code: u8) ?[]const u8 {
    if (code == 0) return null;
    const Code = io_coordinator.RejectionCode;
    return switch (std.enums.fromInt(Code, code) orelse return null) {
        .destination_inside_source => tr("Cannot drop a folder into itself"),
        .atomic_rename_unavailable => tr("Moving items without replacing existing names is unavailable"),
        .folder_exists => tr("Folder already exists"),
        .folder_create_failed => tr("Failed to create folder"),
        .invalid_destination => tr("The destination folder is unavailable"),
        .invalid_source, .unsupported_source => tr("Some items cannot be transferred"),
        .nothing_to_transfer => tr("The items are already here"),
        .mounted_directory_move => tr("Cannot move a mounted directory"),
        .overlapping_move_roots => tr("A folder and its contents cannot be moved together"),
        else => null,
    };
}

fn dropClipboardPaths(self: *App, moved: []const []const u8) void {
    var changed = false;
    var index: usize = 0;
    while (index < self.clipboard_paths.items.len) {
        const path = self.clipboard_paths.items[index];
        const gone = for (moved) |source| {
            if (std.mem.eql(u8, source, path)) break true;
        } else false;
        if (gone) {
            self.allocator.free(self.clipboard_paths.orderedRemove(index));
            changed = true;
        } else index += 1;
    }
    if (self.clipboard_paths.items.len == 0) self.clipboard_cut = false;
    if (changed) self.clipboard_revision += 1;
}

/// The folder shown received the items or, for a move, lost them.
fn showsAffected(self: *App, transfer: *const Transfer) bool {
    const current = self.history.current;
    if (std.mem.eql(u8, current, transfer.destination)) return true;
    if (!transfer.move) return false;
    for (transfer.sources) |source| {
        if (std.mem.eql(u8, current, std.fs.path.dirname(source) orelse "")) return true;
    }
    return false;
}

/// The conflict's details arrived: show it, unless something else is open
/// or it was resolved meanwhile.
pub fn showConflict(self: *App, details: ?io_requests.ConflictDetails) void {
    const conflict = details orelse {
        // No longer at the head of the queue: ask again when it is.
        std.log.info("Files conflict answered before it was shown", .{});
        self.service.transfers.conflict_asked = 0;
        return;
    };
    if (standingFor(self, conflict.job_id)) |entry| if (entry.answer(conflict.can_merge)) |action| {
        std.log.info("Files answers conflict {d} as before: {s}", .{ conflict.conflict_id, @tagName(action) });
        resolveConflict(self, conflict.conflict_id, conflict.destination_path, action);
        return;
    };
    std.log.info("Files shows conflict {d} of job {d}", .{ conflict.conflict_id, conflict.job_id });
    if (self.dialog) |open| std.log.info("Files cannot show it yet: a {s} dialog is open", .{@tagName(open.kind)});
    if (self.dialog != null) {
        // Asked again once the dialog closes.
        self.service.transfers.conflict_asked = 0;
        return;
    }
    self.openServiceConflictDialog(conflict.conflict_id, conflict.job_id, conflict.destination_path, conflict.can_merge);
}

fn standingFor(self: *App, job_id: u64) ?*Standing {
    for (&self.service.transfers.standing) |*entry| if (entry.job_id == job_id) return entry;
    return null;
}

/// Remembers `action` for the rest of `job_id`'s conflicts. Skip and Rename
/// suit both kinds, so they also settle the other kind unless it has its own
/// answer; Merge only suits folders.
pub fn standFor(self: *App, job_id: u64, can_merge: bool, action: io_service.ConflictAction) void {
    const entry = standingFor(self, job_id) orelse for (&self.service.transfers.standing) |*slot| {
        // A free slot, or one whose job is over.
        const over = if (self.service.jobs.find(slot.job_id)) |record| record.state.isTerminal() else true;
        if (slot.job_id == 0 or over) {
            slot.* = .{ .job_id = job_id };
            break slot;
        }
    } else return;
    if (can_merge) entry.folders = action else entry.others = action;
    if (action != .merge) {
        if (can_merge and entry.others == null) entry.others = action;
        if (!can_merge and entry.folders == null) entry.folders = action;
    }
}

/// Answers the conflict in the dialog through the service. Rename first
/// asks the service for a free name.
pub fn resolveConflict(self: *App, conflict_id: u64, destination: []const u8, action: io_service.ConflictAction) void {
    std.log.info("Files answers conflict {d}: {s}", .{ conflict_id, @tagName(action) });
    if (action == .rename) {
        const dir = std.fs.path.dirname(destination) orelse return;
        const owned = self.allocator.dupe(u8, dir) catch return;
        _ = app_requests.send(self, .{ .unique_name = .{ .dir = dir, .name = std.fs.path.basename(destination) } }, .{ .conflict_rename = .{ .conflict_id = conflict_id, .dir = owned } });
        return;
    }
    sendResolution(self, conflict_id, action, null);
}

pub fn sendResolution(self: *App, conflict_id: u64, action: io_service.ConflictAction, path: ?[]const u8) void {
    const link = &self.service;
    const handle = link.handle orelse return;
    var command: io_service.Command = .{
        .kind = .resolve_conflict,
        .payload = io_service.OwnedPayload.createConflictResolution(self.allocator, conflict_id, action, path) catch return,
    };
    defer command.deinitPayload();
    link.outbox.send(handle, &command) catch {
        self.setStatusNotice(tr("Could not resolve file conflict"), true);
    };
}
