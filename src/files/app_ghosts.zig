//! Ghost rows of service jobs (stage S3b): what running copies and moves,
//! of any window, are bringing into the folder shown, with their progress,
//! from job views (architecture §14). The window watches the folder it shows
//! by path in view slot 0, whether or not it started a job: ghosts show the
//! future state of the filesystem. A ghost folder can be entered; its ghost
//! files come from the same watch on the deeper path. A snapshot whose shape
//! changed rebuilds the listing; one with only new bytes updates the rows in
//! place.
const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const ViewItem = @import("app_model.zig").ViewItem;
const io_service = @import("io_service.zig");
const views = @import("io_job_views.zig");
const fold = @import("ui").fold;

pub const slot = 0;

pub const State = struct {
    /// Owned: the folder watched, or null before the first watch.
    path: ?[]u8 = null,
    generation: u64 = 0,
    snapshot: ?*views.Snapshot = null,
    shape: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.snapshot) |s| s.destroy();
        self.snapshot = null;
        if (self.path) |path| allocator.free(path);
        self.path = null;
    }
};

/// Watches the folder shown: a new folder replaces the watch, and its
/// ghosts are dropped until the first snapshot arrives.
pub fn updateWatches(self: *App) void {
    const link = &self.service;
    const handle = link.handle orelse return;
    const ghosts = &link.ghosts;
    const wanted: ?[]const u8 = if (self.chooser == null and !self.transfer_view.active and
        self.history.archive_len == 0 and !self.isRecent()) self.history.current else null;
    if (ghosts.path) |path| {
        if (wanted) |want| if (std.mem.eql(u8, path, want)) return;
    } else if (wanted == null) return;

    var command: io_service.Command = if (wanted) |path|
        .{ .kind = .watch_view, .payload = io_service.OwnedPayload.createWatch(self.allocator, .{
            .slot = slot,
            .path = path,
            .generation = ghosts.generation + 1,
        }) catch return }
    else
        .{ .kind = .unwatch_view, .submit_tag = slot };
    defer command.deinitPayload();
    link.outbox.send(handle, &command) catch return;
    const owned = if (wanted) |path| self.allocator.dupe(u8, path) catch null else null;
    const had_rows = if (ghosts.snapshot) |snapshot| snapshot.rows.len > 0 else false;
    ghosts.deinit(self.allocator);
    ghosts.path = owned;
    ghosts.generation += 1;
    ghosts.shape = 0;
    if (had_rows) self.rebuildView();
}

/// Takes the newest snapshot of the watched folder.
pub fn takeViews(self: *App) void {
    const link = &self.service;
    const handle = link.handle orelse return;
    const ghosts = &link.ghosts;
    if (ghosts.path == null) return;
    const snapshot = (handle.takeView(slot) catch |err| switch (err) {
        error.ServiceBusy => {
            link.dirty = true;
            return;
        },
        else => return,
    }) orelse return;
    // A snapshot of a folder this window has left.
    if (snapshot.generation != ghosts.generation) return snapshot.destroy();
    const shape = shapeOf(snapshot);
    if (ghosts.snapshot) |old| old.destroy();
    ghosts.snapshot = snapshot;
    // A row that finished shows the real entry, which the folder's own
    // watch lists.
    if (shape != ghosts.shape) {
        ghosts.shape = shape;
        self.rebuildView();
    } else updateInPlace(self, snapshot);
}

/// Whether running jobs bring anything into the folder shown.
pub fn active(self: *const App) bool {
    const snapshot = self.service.ghosts.snapshot orelse return false;
    return snapshot.rows.len > 0;
}

fn shapeOf(snapshot: *const views.Snapshot) u64 {
    var hash = std.hash.Wyhash.init(snapshot.rows.len);
    for (snapshot.rows) |row| {
        hash.update(std.mem.asBytes(&row.entry_id));
        hash.update(std.mem.asBytes(&row.state));
    }
    return hash.final();
}

/// Bytes moved, nothing else: the matching rows take the new numbers and
/// only they are repainted.
fn updateInPlace(self: *App, snapshot: *const views.Snapshot) void {
    for (snapshot.rows) |row| {
        const name = snapshot.name(row);
        for (self.items.items, 0..) |*item, index| {
            if (!item.transfer_ghost or !std.mem.eql(u8, item.name, name)) continue;
            applyProgress(item, row);
            damageItem(self, index);
            break;
        }
    }
}

fn applyProgress(item: *ViewItem, row: views.Row) void {
    if (row.kind == .directory) {
        item.transfer_progress = if (row.total_bytes > 0)
            @min(1.0, @as(f64, @floatFromInt(row.completed_bytes)) / @as(f64, @floatFromInt(row.total_bytes)))
        else
            null;
    } else {
        item.transfer_bytes = row.completed_bytes;
        item.transfer_total_bytes = row.total_bytes;
    }
}

fn damageItem(self: *App, index: usize) void {
    const columns: usize = @intCast(@max(1, self.columns()));
    const row_y = self.viewTop() + self.itemInset() +
        @as(i32, @intCast(index / columns)) * self.rowHeight() - self.scroll_y;
    self.addDamageRegion(self.clipToViewport(.{
        .x = @floatFromInt(self.sidebarWidth()),
        .y = @floatFromInt(row_y),
        .w = @floatFromInt(self.w - self.sidebarWidth() - self.scrollbarGutter()),
        .h = @floatFromInt(self.cardHeight()),
    }));
}

fn transferState(state: views.RowState) ?@import("ops.zig").TransferEntryState {
    return switch (state) {
        .pending => .pending,
        .running => .copying,
        .done => .completed,
        // A row that failed or was skipped shows what is really there.
        .failed, .skipped, .cancelled => null,
    };
}

/// Adds the ghosts of the watched transfers to the listing being built:
/// what is not there yet appears faded with its progress; what is there and
/// still being written is marked as a ghost.
pub fn appendRows(self: *App, mem: std.mem.Allocator, old: *const std.StringHashMap(ViewItem)) void {
    if (self.chooser != null or self.transfer_view.active or
        self.history.archive_len > 0 or self.isRecent() or self.changedOnly()) return;
    const snapshot = self.service.ghosts.snapshot orelse return;
    for (snapshot.rows) |row| appendRow(self, mem, old, snapshot, row);
}

fn appendRow(self: *App, mem: std.mem.Allocator, old: *const std.StringHashMap(ViewItem), snapshot: *const views.Snapshot, row: views.Row) void {
    const state = transferState(row.state) orelse return;
    const ghost = state == .pending or state == .copying;
    const name = snapshot.name(row);
    const is_dir = row.kind == .directory;
    if (self.folders_only and !is_dir) return;
    if (!fold.contains(name, self.search.text.items, .{ .turkish = @import("i18n").isTurkish() })) return;
    for (self.items.items) |*item| {
        if (!std.mem.eql(u8, item.name, name)) continue;
        // A real file still pending is usually waiting on a conflict: it
        // becomes a ghost only once its copy has started.
        if (if (is_dir) ghost else state == .copying) {
            item.transfer_ghost = true;
            item.transfer_state = state;
            item.transfer_job_id = row.job_id;
            item.transfer_entry_id = row.entry_id;
            item.missing = !item.is_dir;
            applyProgress(item, row);
        }
        return;
    }
    if (!ghost) return;
    const path = std.fs.path.join(mem, &.{ self.history.current, name }) catch return;
    const previous = old.get(path);
    var item: ViewItem = .{
        .name = mem.dupe(u8, name) catch {
            mem.free(path);
            return;
        },
        .path = path,
        .is_dir = is_dir,
        .is_symlink = row.kind == .symlink,
        .is_broken = false,
        .transfer_ghost = true,
        .transfer_state = state,
        .transfer_job_id = row.job_id,
        .transfer_entry_id = row.entry_id,
        .missing = true,
        .bytes = @intCast(@min(row.total_bytes, @as(u64, std.math.maxInt(i64)))),
        .mtime = 0,
        .icon_name = switch (row.kind) {
            .directory => "folder",
            .symlink => "emblem-symbolic-link",
            else => "text-x-generic",
        },
        .selected = if (previous) |p| p.selected else false,
        .selection_fill = if (previous) |p| p.selection_fill else .{},
        .selection_border = if (previous) |p| p.selection_border else .{},
    };
    applyProgress(&item, row);
    self.items.append(self.allocator, item) catch {
        mem.free(item.name);
        mem.free(path);
    };
}

test "a watched transfer's rows appear as ghosts with their progress, and finished rows do not" {
    const allocator = std.testing.allocator;
    var app = try @import("app_tests.zig").testApp();
    defer app.deinit();
    try app.history.navigate("/destination");

    var rows = [_]views.Row{
        .{ .job_id = 7, .entry_id = 1, .name_start = 0, .name_len = 6, .kind = .directory, .state = .running, .completed_bytes = 25, .total_bytes = 100 },
        .{ .entry_id = 2, .name_start = 6, .name_len = 5, .kind = .regular_file, .state = .pending, .completed_bytes = 0, .total_bytes = 40 },
        .{ .entry_id = 3, .name_start = 11, .name_len = 4, .kind = .regular_file, .state = .done, .completed_bytes = 9, .total_bytes = 9 },
    };
    var names = "folderb.txtdone".*;
    var snapshot: views.Snapshot = .{ .allocator = allocator, .slot = 0, .offset = 0, .total_children = 3, .rows = &rows, .names = &names };
    app.service.ghosts.snapshot = &snapshot;
    defer app.service.ghosts.snapshot = null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var old = std.StringHashMap(ViewItem).init(allocator);
    defer old.deinit();
    const before = app.items.items.len;
    appendRows(&app, arena.allocator(), &old);
    defer app.items.shrinkRetainingCapacity(before);

    try std.testing.expectEqual(before + 2, app.items.items.len);
    const folder = app.items.items[before];
    try std.testing.expectEqualStrings("/destination/folder", folder.path);
    try std.testing.expect(folder.transfer_ghost and folder.is_dir);
    try std.testing.expectEqual(@as(?f64, 0.25), folder.transfer_progress);
    try std.testing.expectEqual(@as(u64, 7), folder.transfer_job_id);
    const file = app.items.items[before + 1];
    try std.testing.expectEqualStrings("b.txt", file.name);
    try std.testing.expectEqual(@as(?u64, 40), file.transfer_total_bytes);
    try std.testing.expectEqual(@import("ops.zig").TransferEntryState.pending, file.transfer_state.?);
}
