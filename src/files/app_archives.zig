//! Archive jobs from this window, through the I/O service (stage S4):
//! extracting into a folder, opening one member, and exporting members for
//! the clipboard, a drag or Open With. The service extracts and publishes;
//! for a member or an export it then hands this window the staging folder,
//! which the window gives back (`StagingLease`) when it is done with it.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const App = app_mod.App;
const io_service = @import("io_service.zig");
const io_requests = @import("io_requests.zig");
const app_requests = @import("app_requests.zig");
const app_service = @import("app_service.zig");
const clipboard_mod = @import("clipboard.zig");

pub const ExportUse = enum { clipboard, drag, open_with };

pub const Use = union(enum) {
    extract: struct { destination: []u8 },
    member: struct { preview: bool, navigation: u32 },
    @"export": ExportUse,
};

pub const max_archives = 4;

pub const Archive = struct {
    tag: u64,
    job_id: io_service.JobId = 0,
    use: Use,
    /// Owned: the members asked for, relative to the archive root.
    members: [][]u8,
    /// A drag that was let go of before its members were ready.
    abandoned: bool = false,

    fn deinit(self: *Archive, allocator: std.mem.Allocator) void {
        for (self.members) |member| allocator.free(member);
        allocator.free(self.members);
        if (self.use == .extract) allocator.free(self.use.extract.destination);
    }
};

pub const List = struct {
    items: [max_archives]Archive = undefined,
    len: usize = 0,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items[0..self.len]) |*item| item.deinit(allocator);
        self.len = 0;
    }

    pub fn find(self: *List, tag: u64) ?*Archive {
        for (self.items[0..self.len]) |*item| if (item.tag == tag) return item;
        return null;
    }

    fn remove(self: *List, archive: *Archive, allocator: std.mem.Allocator) void {
        archive.deinit(allocator);
        const index = (@intFromPtr(archive) - @intFromPtr(&self.items[0])) / @sizeOf(Archive);
        self.items[index] = self.items[self.len - 1];
        self.len -= 1;
    }
};

/// Submits an archive job. Returns its tag, or null with a notice.
fn submit(self: *App, use: Use, source: []const u8, destination: []const u8, members: []const []const u8) ?u64 {
    const link = &self.service;
    const handle = link.handle orelse return null;
    const list = &link.archives;
    if (list.len == max_archives) {
        self.setStatusNotice(tr("Too many archive jobs running"), true);
        return null;
    }
    const owned = app_requests.dupeAll(self.allocator, members) catch return null;
    const purpose: io_service.ArchivePurpose = switch (use) {
        .extract => .extract,
        .member => .member,
        .@"export" => .@"export",
    };
    var command: io_service.Command = .{
        .kind = .submit_job,
        .submit_tag = link.next_tag,
        .payload = io_service.OwnedPayload.createArchive(self.allocator, purpose, source, destination, members) catch {
            freeAll(self.allocator, owned);
            return null;
        },
    };
    defer command.deinitPayload();
    link.outbox.send(handle, &command) catch |err| {
        std.log.warn("Files archive job not submitted: {s}", .{@errorName(err)});
        freeAll(self.allocator, owned);
        return null;
    };
    const tag = link.next_tag;
    link.next_tag += 1;
    list.items[list.len] = .{ .tag = tag, .use = use, .members = owned };
    list.len += 1;
    return tag;
}

fn freeAll(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Extracts `members` (all when empty) of the archive at `path` into
/// `destination`.
pub fn startExtraction(self: *App, path: []const u8, destination: []const u8, members: []const []const u8) bool {
    const owned = self.allocator.dupe(u8, destination) catch return false;
    if (submit(self, .{ .extract = .{ .destination = owned } }, path, destination, members) == null) {
        self.allocator.free(owned);
        self.setStatusNotice(tr("Could not start extraction"), true);
        return false;
    }
    self.setStatusNotice(tr("Extracting archive"), false);
    self.invalidate();
    return true;
}

/// Opens archive member `path` (under the archive shown) once extracted.
pub fn openMember(self: *App, path: []const u8, preview: bool) void {
    const len = self.history.archive_len;
    if (len == 0 or path.len <= len or path[len] != '/') return;
    const use: Use = .{ .member = .{ .preview = preview, .navigation = self.navigation_count } };
    if (submit(self, use, self.history.current[0..len], "/tmp", &.{path[len + 1 ..]}) == null)
        return self.setStatusNotice(tr("Could not open archive member"), true);
    self.setStatusNotice(tr("Opening archive member"), false);
    self.invalidate();
}

/// Extracts the selected members for `use`. The tag lets a drag wait for it.
pub fn startExport(self: *App, use: ExportUse) !u64 {
    if (!self.hasSelectedArchiveMembers()) return error.NoSelectedArchiveMembers;
    const len = self.history.archive_len;
    var members: std.ArrayList([]const u8) = .empty;
    defer members.deinit(self.allocator);
    for (self.items.items) |item| {
        if (!item.selected or item.transfer_ghost) continue;
        if (use == .open_with and item.is_dir) return error.NoSelectedArchiveMembers;
        try members.append(self.allocator, item.path[len + 1 ..]);
    }
    const tag = submit(self, .{ .@"export" = use }, self.history.current[0..len], "/tmp", members.items) orelse
        return error.ArchiveExportUnavailable;
    self.setStatusNotice(switch (use) {
        .clipboard => tr("Preparing archive members for clipboard"),
        .drag => tr("Preparing files for drag…"),
        .open_with => tr("Preparing archive members for Open With…"),
    }, false);
    self.invalidate();
    return tag;
}

/// Whether an archive job with this tag is still on its way.
pub fn pending(self: *App, tag: u64) bool {
    return self.service.archives.find(tag) != null;
}

/// The drag that waited for `tag` was let go of: cancel the export, and
/// give back whatever it still hands over.
pub fn abandon(self: *App, tag: u64) void {
    const archive = self.service.archives.find(tag) orelse return;
    archive.abandoned = true;
    if (archive.job_id == 0) return;
    const link = &self.service;
    const handle = link.handle orelse return;
    var command: io_service.Command = .{ .kind = .cancel_job, .job_id = archive.job_id };
    link.outbox.send(handle, &command) catch {};
}

/// A record of one of this window's jobs changed. Whether it was an archive
/// job.
pub fn onRecord(self: *App, record: io_service.JobRecord) bool {
    const list = &self.service.archives;
    const archive = list.find(record.submit_tag) orelse return false;
    archive.job_id = record.id;
    if (!record.state.isTerminal()) return true;
    switch (archive.use) {
        .extract => |extract| {
            finishNotice(self, archive.use, record.state);
            if (std.mem.eql(u8, self.history.current, extract.destination)) self.refresh();
            list.remove(archive, self.allocator);
        },
        .member, .@"export" => {
            if (record.state != .completed) {
                finishNotice(self, archive.use, record.state);
                list.remove(archive, self.allocator);
                return true;
            }
            // The staging is the window's now: take it.
            if (!app_requests.send(self, .{ .archive_handoff = .{ .job_id = record.id } }, .{ .archive_handoff = .{ .tag = archive.tag } })) {
                self.setStatusNotice(tr("Could not take extracted archive members"), true);
                list.remove(archive, self.allocator);
            }
        },
    }
    return true;
}

fn finishNotice(self: *App, use: Use, state: io_service.JobState) void {
    const failed = state != .completed;
    const cancelled = state == .cancelled;
    self.setStatusNotice(switch (use) {
        .extract => if (cancelled) tr("Archive extraction cancelled") else if (failed) tr("Could not extract archive") else tr("Archive extracted"),
        .member => if (cancelled) tr("Archive member opening cancelled") else tr("Could not open archive member"),
        .@"export" => |purpose| switch (purpose) {
            .clipboard => if (cancelled) tr("Archive clipboard copy cancelled") else tr("Could not copy archive members"),
            .drag => if (cancelled) tr("Archive drag cancelled") else tr("Could not prepare archive drag"),
            .open_with => if (cancelled) tr("Preparing archive members for Open With cancelled") else tr("Could not prepare archive members for Open With"),
        },
    }, failed);
}

fn lease(self: *App, handoff: io_requests.Handoff) clipboard_mod.StagingLease {
    return .{
        .allocator = self.allocator,
        .path = handoff.staging,
        .resource_id = handoff.resource_id,
        .dispose = app_service.disposeResource,
        .context = &self.service,
    };
}

/// The `archive_handoff` reply: `handoff` is this window's to keep or give
/// back; its staging string becomes the lease's.
pub fn finishHandoff(self: *App, tag: u64, handoff_value: ?io_requests.Handoff) void {
    const list = &self.service.archives;
    const archive = list.find(tag) orelse {
        if (handoff_value) |h| {
            var orphan = lease(self, h);
            orphan.deinit();
        }
        return;
    };
    defer list.remove(archive, self.allocator);
    const handoff = handoff_value orelse return finishNotice(self, archive.use, .failed);
    var staged = lease(self, handoff);
    if (archive.abandoned) return staged.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| self.allocator.free(path);
        paths.deinit(self.allocator);
    }
    for (archive.members) |member| {
        const path = std.fs.path.join(self.allocator, &.{ staged.path, member }) catch {
            staged.deinit();
            return finishNotice(self, archive.use, .failed);
        };
        paths.append(self.allocator, path) catch {
            self.allocator.free(path);
            staged.deinit();
            return finishNotice(self, archive.use, .failed);
        };
    }

    switch (archive.use) {
        .extract => unreachable, // extractions publish; nothing is handed over
        .member => |member| {
            // Navigated away meanwhile: the member is no longer wanted.
            const shown = self.navigation_count == member.navigation;
            const opened = shown and self.openExtracted(paths.items[0], member.preview);
            if (opened) {
                self.archive_open_with_leases.append(self.allocator, staged) catch staged.deinit();
                self.setStatusNotice(tr("Archive member opened"), false);
            } else {
                staged.deinit();
                if (!shown) self.setStatusNotice(tr("Archive member is no longer in this view"), false);
            }
        },
        .@"export" => |use| switch (use) {
            .clipboard => {
                self.clipboard_paths.ensureUnusedCapacity(self.allocator, paths.items.len) catch {
                    staged.deinit();
                    return finishNotice(self, archive.use, .failed);
                };
                self.clearClipboard();
                for (paths.items) |path| self.clipboard_paths.appendAssumeCapacity(path);
                paths.clearRetainingCapacity();
                self.clipboard_staging_lease = staged;
                self.clipboard_is_text = false;
                self.clipboard_cut = false;
                self.clipboard_revision += 1;
                self.setStatusNotice(tr("Archive members copied to clipboard"), false);
            },
            .drag => {
                if (self.archive_drag_export) |*old| old.deinit();
                self.archive_drag_export = .{ .allocator = self.allocator, .paths = paths, .staging_lease = staged };
                paths = .empty;
                self.setStatusNotice(tr("Archive members ready for drag"), false);
            },
            .open_with => if (self.openWithPaths(paths.items, true)) {
                self.archive_open_with_leases.append(self.allocator, staged) catch staged.deinit();
            } else staged.deinit(),
        },
    }
    self.invalidate();
}
