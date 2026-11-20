//! Files clipboard and file operations: copy, cut, paste, size and delete.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const recent = @import("recent.zig");
const ops_mod = @import("ops.zig");
const io_tree = @import("io_tree.zig");
const io_manager = @import("io_manager.zig");
const clipboard_mod = @import("clipboard.zig");
const deletion = @import("../delete_dialog.zig");
const trash = @import("trash.zig");
const c = @import("c.zig").api;

pub fn copySelected(self: *App) void {
    if (self.history.archive_len > 0) return;
    if (!self.hasSelection()) return;
    self.clipboard_is_text = false;
    self.clearClipboard();
    for (self.items.items) |it| {
        if (it.selected and !it.missing) {
            self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
        }
    }
    if (self.clipboard_paths.items.len > 0) {
        self.clipboard_cut = false;
        self.clipboard_revision += 1;
        var buf: [128]u8 = undefined;
        const count = self.clipboard_paths.items.len;
        const msg = i18n.fmt(&buf, i18n.trn("Copied {count} item", "Copied {count} items", count), .{ .count = count }) catch tr("Copied");
        self.setStatusNotice(msg, false);
        self.invalidate();
    }
}

pub fn cutSelected(self: *App) void {
    if (self.history.archive_len > 0 or self.trashReadOnly()) return;
    if (!self.hasSelection()) return;
    self.clipboard_is_text = false;
    self.clearClipboard();
    for (self.items.items) |it| {
        if (it.selected and !it.missing) {
            self.clipboard_paths.append(self.allocator, self.allocator.dupe(u8, it.path) catch continue) catch continue;
        }
    }
    if (self.clipboard_paths.items.len > 0) {
        self.clipboard_cut = true;
        self.clipboard_revision += 1;
        var buf: [128]u8 = undefined;
        const count = self.clipboard_paths.items.len;
        const msg = i18n.fmt(&buf, i18n.trn("Cut {count} item", "Cut {count} items", count), .{ .count = count }) catch tr("Cut");
        self.setStatusNotice(msg, false);
        self.invalidate();
    }
}

pub fn calculateSizeSelected(self: *App) void {
    if (self.history.archive_len > 0) return;
    var any = false;
    for (self.items.items, 0..) |it, idx| {
        if (it.selected and it.is_dir and !it.is_symlink) {
            self.startFolderSize(idx);
            any = true;
        }
    }
    if (!any) {
        if (self.focused_index) |idx| {
            if (idx < self.items.items.len) {
                const it = self.items.items[idx];
                if (it.is_dir and !it.is_symlink) {
                    self.startFolderSize(idx);
                }
            }
        }
    }
}

pub fn executePaste(self: *App, kind: ops_mod.OpKind, paths: []const []const u8) bool {
    if (self.isRecent()) return false;
    return self.executeTransfer(kind, paths, self.history.current, true);
}

/// Starts a multi-root regular-file/symlink copy through the Manager-owned
/// pipeline. Directory roots use the incremental discovery path below.
fn startManagerFileCopy(
    self: *App,
    paths: []const []const u8,
    directory: []const u8,
) !bool {
    if (paths.len == 0 or self.active_io_copy_job != null) return false;

    const RootPlan = struct {
        source: []const u8,
        name: []const u8,
        kind: io_tree.EntryKind,
        metadata: io_tree.Metadata,
        symlink_target: ?[]u8 = null,
    };
    var roots: std.ArrayList(RootPlan) = .empty;
    defer {
        for (roots.items) |root| {
            if (root.symlink_target) |target| self.allocator.free(target);
        }
        roots.deinit(self.allocator);
    }

    for (paths) |source| {
        if (!std.fs.path.isAbsolute(source)) return false;
        const name = std.fs.path.basename(source);
        if (name.len == 0) return false;

        const source_z = try self.allocator.dupeSentinel(u8, source, 0);
        defer self.allocator.free(source_z);
        var source_stat: c.struct_stat = undefined;
        if (c.lstat(source_z, &source_stat) != 0) return false;

        const kind: io_tree.EntryKind = switch (source_stat.st_mode & c.S_IFMT) {
            c.S_IFREG => .regular_file,
            c.S_IFLNK => .symlink,
            else => return false,
        };

        var symlink_target: ?[]u8 = null;
        defer if (symlink_target) |target| self.allocator.free(target);
        if (kind == .symlink) {
            var target_buffer: [4096]u8 = undefined;
            const target_len = c.readlink(source_z, &target_buffer, target_buffer.len);
            if (target_len < 0 or target_len == target_buffer.len) return false;
            symlink_target = try self.allocator.dupe(
                u8,
                target_buffer[0..@intCast(target_len)],
            );
        }

        try roots.append(self.allocator, .{
            .source = source,
            .name = name,
            .kind = kind,
            .metadata = .{
                .size = @intCast(@max(source_stat.st_size, 0)),
                .mode = @intCast(source_stat.st_mode),
                .device_id = @intCast(source_stat.st_dev),
            },
            .symlink_target = symlink_target,
        });
        symlink_target = null;
    }

    try self.startOperations();
    const manager = if (self.io_manager) |*value| value else return error.OperationManagerUnavailable;
    const owned_destination = try self.allocator.dupe(u8, directory);
    errdefer self.allocator.free(owned_destination);

    const job_id = try manager.createJob(null);
    errdefer _ = manager.discardPlanningJob(job_id);

    for (roots.items) |root| {
        const root_id = try manager.addTreeRoot(
            job_id,
            root.name,
            root.kind,
            root.metadata,
            root.symlink_target,
        );
        try manager.setRootSourcePath(job_id, root_id, root.source);
        const operation_kind: io_manager.OperationKind = switch (root.kind) {
            .regular_file => .copy_file,
            .symlink => .copy_symlink,
            else => unreachable,
        };
        _ = try manager.addEntryOperation(job_id, root_id, operation_kind);
    }
    try manager.setDestinationDirectory(job_id, directory);
    try manager.queueJob(job_id);

    self.active_io_copy_destination = owned_destination;
    self.active_io_copy_job = job_id;
    self.active_io_copy_is_directory = false;
    self.active_io_copy_item_count = paths.len;
    self.setStatusNotice(if (paths.len == 1) "Copying file" else "Copying items", false);
    self.invalidate();
    return true;
}

/// Starts regular-file/symlink moves through the Manager. Same-filesystem
/// entries retain native rename semantics; cross-filesystem entries use
/// copy followed by a dependent source detach.
fn startManagerFileMove(
    self: *App,
    paths: []const []const u8,
    directory: []const u8,
    clipboard: bool,
) !bool {
    if (paths.len == 0 or self.active_io_copy_job != null) return false;

    const destination_z = try self.allocator.dupeSentinel(u8, directory, 0);
    defer self.allocator.free(destination_z);
    var destination_stat: c.struct_stat = undefined;
    if (c.stat(destination_z, &destination_stat) != 0 or
        (destination_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
    {
        return false;
    }

    const RootPlan = struct {
        source: []const u8,
        name: []const u8,
        kind: io_tree.EntryKind,
        metadata: io_tree.Metadata,
        same_filesystem: bool,
        symlink_target: ?[]u8 = null,
    };
    var roots: std.ArrayList(RootPlan) = .empty;
    defer {
        for (roots.items) |root| {
            if (root.symlink_target) |target| self.allocator.free(target);
        }
        roots.deinit(self.allocator);
    }

    for (paths) |source| {
        if (!std.fs.path.isAbsolute(source)) return false;
        const name = std.fs.path.basename(source);
        if (name.len == 0) return false;

        const source_z = try self.allocator.dupeSentinel(u8, source, 0);
        defer self.allocator.free(source_z);
        var source_stat: c.struct_stat = undefined;
        if (c.lstat(source_z, &source_stat) != 0) return false;

        const mode = source_stat.st_mode & c.S_IFMT;
        if (mode != c.S_IFREG and mode != c.S_IFLNK) return false;

        var symlink_target: ?[]u8 = null;
        defer if (symlink_target) |target| self.allocator.free(target);
        if (mode == c.S_IFLNK) {
            var target_buffer: [4096]u8 = undefined;
            const target_len = c.readlink(source_z, &target_buffer, target_buffer.len);
            if (target_len < 0 or target_len == target_buffer.len) return false;
            symlink_target = try self.allocator.dupe(
                u8,
                target_buffer[0..@intCast(target_len)],
            );
        }

        const target_path = try std.fs.path.join(
            self.allocator,
            &.{ directory, name },
        );
        defer self.allocator.free(target_path);
        if (std.mem.eql(u8, source, target_path)) return false;

        try roots.append(self.allocator, .{
            .source = source,
            .name = name,
            .kind = if (mode == c.S_IFLNK) .symlink else .regular_file,
            .metadata = .{
                .size = @intCast(@max(source_stat.st_size, 0)),
                .mode = @intCast(source_stat.st_mode),
                .device_id = @intCast(source_stat.st_dev),
            },
            .same_filesystem = source_stat.st_dev == destination_stat.st_dev,
            .symlink_target = symlink_target,
        });
        symlink_target = null;
    }

    try self.startOperations();
    const manager = if (self.io_manager) |*value| value else return error.OperationManagerUnavailable;
    const owned_destination = try self.allocator.dupe(u8, directory);
    errdefer self.allocator.free(owned_destination);

    const job_id = try manager.createJob(null);
    errdefer _ = manager.discardPlanningJob(job_id);

    for (roots.items) |root| {
        const root_id = try manager.addTreeRoot(
            job_id,
            root.name,
            root.kind,
            root.metadata,
            root.symlink_target,
        );
        try manager.setRootSourcePath(job_id, root_id, root.source);
        if (root.same_filesystem) {
            _ = try manager.addEntryOperation(job_id, root_id, .move_entry);
        } else {
            const copy_kind: io_manager.OperationKind = switch (root.kind) {
                .regular_file => .copy_file,
                .symlink => .copy_symlink,
                else => unreachable,
            };
            _ = try manager.addEntryOperation(job_id, root_id, copy_kind);
            _ = try manager.addEntryOperation(job_id, root_id, .detach_source);
        }
    }
    try manager.setDestinationDirectory(job_id, directory);
    try manager.setDestinationDeviceId(job_id, @intCast(destination_stat.st_dev));
    try manager.queueJob(job_id);

    self.active_io_copy_destination = owned_destination;
    self.active_io_copy_job = job_id;
    self.active_io_copy_is_directory = false;
    self.active_io_copy_is_move = true;
    self.active_io_copy_item_count = paths.len;
    self.job_cut_revision = if (clipboard and self.clipboard_cut)
        self.clipboard_revision
    else
        null;
    self.setStatusNotice(
        if (paths.len == 1) "Moving file" else "Moving items",
        false,
    );
    self.invalidate();
    return true;
}

/// Starts selected directory roots through one incremental Manager Job.
/// Mixed selections and cross-filesystem moves remain on JobRunner.
fn startManagerDirectoryTransfer(
    self: *App,
    paths: []const []const u8,
    directory: []const u8,
    is_move: bool,
    clipboard: bool,
) !bool {
    if (paths.len == 0 or self.active_io_copy_job != null) return false;

    const destination_z = try self.allocator.dupeSentinel(u8, directory, 0);
    defer self.allocator.free(destination_z);
    var destination_stat: c.struct_stat = undefined;
    if (c.stat(destination_z, &destination_stat) != 0 or
        (destination_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
    {
        return false;
    }

    const RootPlan = struct {
        source: []const u8,
        name: []const u8,
        metadata: io_tree.Metadata,
    };
    var plans: std.ArrayList(RootPlan) = .empty;
    defer plans.deinit(self.allocator);

    for (paths) |source| {
        if (!std.fs.path.isAbsolute(source)) return false;
        const name = std.fs.path.basename(source);
        if (name.len == 0) return false;

        const source_z = try self.allocator.dupeSentinel(u8, source, 0);
        defer self.allocator.free(source_z);
        var source_stat: c.struct_stat = undefined;
        if (c.lstat(source_z, &source_stat) != 0) return false;
        if ((source_stat.st_mode & c.S_IFMT) != c.S_IFDIR) return false;

        if (is_move and source_stat.st_dev != destination_stat.st_dev)
            return false;

        // Moving overlapping roots as independent discovery roots could
        // detach a parent before the separately selected child is moved.
        if (is_move) {
            for (plans.items) |previous| {
                if (ops_mod.isDescendantOrSame(source, previous.source) or
                    ops_mod.isDescendantOrSame(previous.source, source))
                {
                    return false;
                }
            }
        }

        // Copying or moving a directory into itself or one of its descendants
        // would make discovery chase the destination being created.
        if (ops_mod.isDescendantOrSame(source, directory)) return false;

        try plans.append(self.allocator, .{
            .source = source,
            .name = name,
            .metadata = .{
                .mode = @intCast(source_stat.st_mode),
                .device_id = @intCast(source_stat.st_dev),
            },
        });
    }

    try self.startOperations();
    const manager = if (self.io_manager) |*value| value else return error.OperationManagerUnavailable;
    const owned_destination = try self.allocator.dupe(u8, directory);
    errdefer self.allocator.free(owned_destination);

    const job_id = try manager.createJob(null);
    errdefer _ = manager.discardPlanningJob(job_id);

    var discovery_roots: std.ArrayList(io_manager.DiscoveryRoot) = .empty;
    defer discovery_roots.deinit(self.allocator);

    for (plans.items) |plan| {
        const root_id = try manager.addTreeRoot(
            job_id,
            plan.name,
            .directory,
            plan.metadata,
            null,
        );
        try discovery_roots.append(self.allocator, .{
            .root_id = root_id,
            .path = plan.source,
        });
    }
    try manager.setDestinationDirectory(job_id, directory);

    if (is_move) {
        try manager.setDestinationDeviceId(job_id, @intCast(destination_stat.st_dev));
        for (discovery_roots.items) |root| {
            _ = try manager.addEntryOperation(job_id, root.root_id, .create_directory);
            _ = try manager.addEntryOperation(job_id, root.root_id, .detach_source);
        }
        try manager.enableDiscoveredEntryMoves(job_id);
    } else {
        try manager.enableDiscoveredEntryOperations(job_id);
        for (discovery_roots.items) |root| {
            _ = try manager.addEntryOperation(job_id, root.root_id, .create_directory);
        }
    }
    try self.startDiscoveryRoots(job_id, discovery_roots.items);

    self.active_io_copy_destination = owned_destination;
    self.active_io_copy_job = job_id;
    self.active_io_copy_is_directory = true;
    self.active_io_copy_is_move = is_move;
    self.active_io_copy_item_count = paths.len;
    self.job_cut_revision = if (is_move and clipboard and self.clipboard_cut)
        self.clipboard_revision
    else
        null;
    self.setStatusNotice(
        if (is_move)
            (if (paths.len == 1) "Moving folder" else "Moving folders")
        else
            (if (paths.len == 1) "Copying folder" else "Copying folders"),
        false,
    );
    self.invalidate();
    return true;
}

pub fn executeTransfer(self: *App, kind: ops_mod.OpKind, paths: []const []const u8, directory: []const u8, clipboard: bool) bool {
    if (self.history.archive_len > 0 or recent.isLocation(directory)) return false;
    if (paths.len == 0) return false;
    // Nothing is pasted or dropped into the Trash: Move to Trash is how items get there.
    if (self.trash_dir) |dir| if (trash.relation(dir, directory) != .none) {
        self.setStatusNotice(tr("Use Move to Trash to put items in Trash"), true);
        return false;
    };
    if (kind == .copy) {
        const started = startManagerFileCopy(self, paths, directory) catch false;
        if (started) return true;
        const directory_started =
            startManagerDirectoryTransfer(self, paths, directory, false, false) catch false;
        if (directory_started) return true;
    } else if (kind == .move) {
        const started =
            startManagerFileMove(self, paths, directory, clipboard) catch false;
        if (started) return true;
        const directory_started =
            startManagerDirectoryTransfer(self, paths, directory, true, clipboard) catch false;
        if (directory_started) return true;
    }
    const runner = self.job_runner orelse return false;
    runner.start(kind, paths, directory, .ask) catch {
        self.setStatusNotice(tr("Failed to start transfer job"), true);
        return false;
    };
    self.job_cut_revision = if (clipboard and kind == .move and self.clipboard_cut) self.clipboard_revision else null;
    self.job_was_running = true;
    self.invalidate();
    return true;
}

pub fn executePasteLocal(self: *App) void {
    if (self.clipboard_paths.items.len == 0) return;
    const kind: ops_mod.OpKind = if (self.clipboard_cut) .move else .copy;
    _ = self.executePaste(kind, self.clipboard_paths.items);
}

pub fn executePasteExternal(self: *App, mode: clipboard_mod.ClipboardMode, paths: []const []const u8) void {
    const kind: ops_mod.OpKind = if (mode == .cut) .move else .copy;
    if (!self.executePaste(kind, paths)) return;
    // Retain external cut entries too; completion republishes only remaining items.
    if (mode == .cut) {
        self.clearClipboard();
        for (paths) |path| {
            const owned = self.allocator.dupe(u8, path) catch continue;
            self.clipboard_paths.append(self.allocator, owned) catch self.allocator.free(owned);
        }
        self.clipboard_cut = true;
        self.clipboard_is_text = false;
        self.clipboard_revision += 1;
        self.job_cut_revision = self.clipboard_revision;
    }
}

pub fn deleteAction(self: *App, action: deletion.Action) void {
    switch (action) {
        .cancel => self.closeDialog(),
        .confirm => self.confirmDialog(),
        .toggle => {
            if (self.dialog.?.deletion.fixedChoice()) return;
            self.dialog.?.deletion.permanent = !self.dialog.?.deletion.permanent;
            self.dialog.?.deletion.focus = .toggle;
        },
        .none => {},
    }
    self.invalidate();
}

pub fn executeDeletion(self: *App) void {
    const state = &self.dialog.?.deletion;
    if (state.in_trash) return self.deleteFromTrash(state.paths.items);
    const result = if (state.empty_trash) ops_mod.emptyTrash(self.io) else if (state.permanent) ops_mod.deleteItems(self.io, state.paths.items) else ops_mod.trashItems(self.io, state.paths.items);
    result catch |err| {
        self.setStatusNotice(if (state.empty_trash) tr("Could not empty Trash") else if (state.permanent) tr("Could not delete all items") else if (err == error.GioNotAvailable) tr("Trash unavailable (gio not installed)") else tr("Could not move all items to Trash"), true);
        self.refresh();
        return;
    };
    // gio empties Trash; sweep what it leaves, so no metadata outlives its item.
    if (state.empty_trash) if (self.trash_dir) |dir| trash.sweepOrphans(self.allocator, dir);
    self.setStatusNotice(if (state.empty_trash) tr("Trash emptied") else if (state.permanent) tr("Items permanently deleted") else tr("Items moved to Trash"), false);
    self.refresh();
}

/// Permanently deletes entries of the Trash view with their metadata.
pub fn deleteFromTrash(self: *App, paths: []const []const u8) void {
    const dir = self.trash_dir orelse return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var stray: usize = 0;
    for (paths) |path| {
        // Only top-level entries of the trash have metadata and may go this way.
        const parent = std.fs.path.dirname(path) orelse "";
        if (!std.mem.eql(u8, parent, dir)) {
            stray += 1;
            continue;
        }
        names.append(self.allocator, std.fs.path.basename(path)) catch {
            stray += 1;
        };
    }
    const removed = trash.deleteMany(self.allocator, dir, names.items);
    if (removed.failed + stray > 0) {
        self.setStatusNotice(tr("Could not delete all items"), true);
    } else {
        self.setStatusNotice(tr("Items permanently deleted"), false);
    }
    self.refresh();
}
