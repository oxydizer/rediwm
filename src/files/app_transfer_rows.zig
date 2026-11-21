//! Merge active file-operation manifest entries into the current folder view.

const std = @import("std");
const ui_profile = @import("ui_profile.zig");
const App = @import("app.zig").App;
const ViewItem = @import("app_model.zig").ViewItem;
const transfer_tree = @import("transfer_tree.zig");
const fold = @import("ui").fold;

pub fn appendTransferRows(
    self: *App,
    mem: std.mem.Allocator,
    old: *const std.StringHashMap(ViewItem),
) void {
    if (self.chooser != null or self.transfer_view.active or
        self.history.archive_len > 0 or self.isRecent() or self.changedOnly()) return;

    if (self.active_io_copy_job) |job_id| {
        const manager = if (self.io_manager) |value| value else return;
        const state = manager.jobState(job_id) orelse return;
        if (state.isTerminal()) return;

        if (self.transfer_tree_state.dirty) {
            self.transfer_tree_state.rebuildManager(manager, job_id) catch return;
        }
        const tree = if (self.transfer_tree_state.tree) |*value| value else return;
        appendTreeRows(self, mem, tree, old);
        return;
    }

    if (self.job_state != .running and self.job_state != .paused and
        self.job_state != .waiting_conflict) return;

    const runner = self.job_runner orelse return;
    const profile_started = ui_profile.start();
    defer ui_profile.finish(profile_started, "append_transfer_rows", self.items.items.len);

    // The sidebar and file listing share one projection of the transfer
    // manifest. Rebuild it only when transfer state has invalidated the cache.
    if (self.transfer_tree_state.dirty) {
        self.transfer_tree_state.rebuild(runner) catch return;
    }
    const tree = if (self.transfer_tree_state.tree) |*value| value else return;
    appendTreeRows(self, mem, tree, old);
}

/// Appends only direct children of the displayed folder. Existing filesystem
/// entries take precedence. Active files remain protected ghosts, and
/// existing directories remain ghost-treated while their subtree is pending.
pub fn appendTreeRows(
    self: *App,
    mem: std.mem.Allocator,
    tree: *const transfer_tree.Tree,
    old: *const std.StringHashMap(ViewItem),
) void {
    const profile_started = ui_profile.start();
    defer ui_profile.finish(profile_started, "append_tree_rows", tree.nodes.items.len);

    for (tree.nodes.items, 0..) |node, node_index| {
        if (!std.mem.eql(u8, std.fs.path.dirname(node.path) orelse "", self.history.current)) continue;

        const node_state = if (node.kind == .directory and node.state == .completed)
            descendantTransferState(tree, node_index) orelse node.state
        else
            node.state;
        const ghost = if (node.waiting_conflict) false else switch (node_state) {
            .pending, .copying => true,
            .completed => false,
            .skipped, .failed, .cancelled => continue,
        };
        if (self.folders_only and node.kind != .directory) continue;
        if (!fold.contains(node.name, self.search.text.items, .{ .turkish = @import("i18n").isTurkish() })) continue;

        var represented = false;
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.path, node.path)) {
                // A real file in .pending is usually waiting on a conflict.
                // It becomes a ghost only after a copy unit has started.
                const represented_ghost =
                    if (node.kind == .directory) ghost else node_state == .copying;
                if (represented_ghost) {
                    item.transfer_ghost = true;
                    item.transfer_state = node_state;
                    item.missing = !item.is_dir;
                    if (node.kind == .file) {
                        item.transfer_bytes = node.progress_bytes;
                        item.transfer_total_bytes = node.size;
                    } else if (node.kind == .directory and
                        node_index < self.transfer_tree_state.aggregate_cache.items.len)
                    {
                        const aggregate = self.transfer_tree_state.aggregateProgress(node_index);
                        item.transfer_progress = if (aggregate.total_bytes > 0)
                            aggregate.fraction()
                        else
                            null;
                    }
                }
                represented = true;
                break;
            }
        }
        if (represented) continue;

        const previous = old.get(node.path);
        const bytes: i64 = @intCast(@min(node.size, @as(u64, std.math.maxInt(i64))));
        const name = mem.dupe(u8, node.name) catch continue;
        const path = mem.dupe(u8, node.path) catch {
            mem.free(name);
            continue;
        };
        self.items.append(self.allocator, .{
            .name = name,
            .path = path,
            .is_dir = node.kind == .directory,
            .is_symlink = node.kind == .symlink,
            .is_broken = false,
            .transfer_ghost = ghost,
            .transfer_state = node_state,
            .transfer_bytes = if (node.kind == .file) node.progress_bytes else null,
            .transfer_total_bytes = if (node.kind == .file) node.size else null,
            .transfer_progress = if (node.kind == .directory and
                node_index < self.transfer_tree_state.aggregate_cache.items.len and
                self.transfer_tree_state.aggregateProgress(node_index).total_bytes > 0)
                self.transfer_tree_state.aggregateProgress(node_index).fraction()
            else
                null,
            .missing = ghost,
            .bytes = bytes,
            .mtime = 0,
            .icon_name = switch (node.kind) {
                .directory => "folder",
                .file => "text-x-generic",
                .symlink => "emblem-symbolic-link",
            },
            .selected = if (previous) |item| item.selected else false,
            .selection_fill = if (previous) |item| item.selection_fill else .{},
            .selection_border = if (previous) |item| item.selection_border else .{},
        }) catch {
            mem.free(name);
            mem.free(path);
        };
    }
}

fn descendantTransferState(
    tree: *const transfer_tree.Tree,
    directory_index: usize,
) ?@import("ops.zig").TransferEntryState {
    var pending = false;
    var copying = false;
    for (tree.nodes.items, 0..) |candidate, candidate_index| {
        if (candidate_index == directory_index) continue;
        var parent = candidate.parent_index;
        var descendant = false;
        while (parent) |parent_index| {
            if (parent_index == directory_index) {
                descendant = true;
                break;
            }
            parent = tree.nodes.items[parent_index].parent_index;
        }
        if (!descendant) continue;
        if (candidate.waiting_conflict) continue;
        switch (candidate.state) {
            .copying => copying = true,
            .pending => pending = true,
            .completed, .skipped, .failed, .cancelled => {},
        }
    }
    if (copying) return .copying;
    if (pending) return .pending;
    return null;
}

test "transfer rows merge direct children, prefer real entries and retain selection" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const mem = arena.allocator();

    var app: App = .{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = allocator, .current = "/destination/root" },
        .home_dir = "/",
        .items_arena = undefined,
        .transfer_tree_state = @import("app_transfer_tree.zig").State.init(allocator),
    };
    defer app.transfer_tree_state.deinit();
    defer app.items.deinit(allocator);

    try app.items.append(allocator, .{
        .name = "already-real.txt",
        .path = "/destination/root/already-real.txt",
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 9,
        .mtime = 1,
        .icon_name = "text-x-generic",
    });
    try app.items.append(allocator, .{
        .name = "copying-real.txt",
        .path = "/destination/root/copying-real.txt",
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 3,
        .mtime = 2,
        .icon_name = "text-x-generic",
    });

    var manifest = @import("ops.zig").TransferManifest.init(allocator);
    defer manifest.deinit();
    try manifest.append("/source", "", "/destination/root", 0, .directory, 0);
    try manifest.append("/source/already-real.txt", "already-real.txt", "/destination/root/already-real.txt", 9, .file, 0);
    try manifest.append("/source/pending.txt", "pending.txt", "/destination/root/pending.txt", 12, .file, 0);
    try manifest.append("/source/sub", "sub", "/destination/root/sub", 0, .directory, 0);
    try manifest.append("/source/sub/nested.txt", "sub/nested.txt", "/destination/root/sub/nested.txt", 4, .file, 0);
    try manifest.append("/source/done.txt", "done.txt", "/destination/root/done.txt", 20, .file, 0);
    try manifest.append("/source/skipped.txt", "skipped.txt", "/destination/root/skipped.txt", 2, .file, 0);
    try manifest.append("/source/copying-real.txt", "copying-real.txt", "/destination/root/copying-real.txt", 8, .file, 0);
    manifest.entries.items[1].state = .pending;
    manifest.entries.items[2].state = .pending;
    manifest.entries.items[3].state = .copying;
    manifest.entries.items[4].state = .pending;
    manifest.entries.items[5].state = .completed;
    manifest.entries.items[6].state = .skipped;
    manifest.entries.items[7].state = .copying;

    var tree = try transfer_tree.build(allocator, manifest.entries.items);
    defer tree.deinit();

    var old = std.StringHashMap(ViewItem).init(allocator);
    defer old.deinit();
    try old.put("/destination/root/pending.txt", .{
        .name = "pending.txt",
        .path = "/destination/root/pending.txt",
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 12,
        .mtime = 0,
        .icon_name = "text-x-generic",
        .selected = true,
    });

    appendTreeRows(&app, mem, &tree, &old);

    // Pending conflicts stay real; actively copied files remain protected ghosts.
    try std.testing.expectEqual(@as(usize, 5), app.items.items.len);
    try std.testing.expectEqualStrings("already-real.txt", app.items.items[0].name);
    try std.testing.expect(app.items.items[0].transfer_state == null);
    try std.testing.expect(!app.items.items[0].transfer_ghost);

    const copying = app.items.items[1];
    try std.testing.expectEqualStrings("copying-real.txt", copying.name);
    try std.testing.expect(copying.transfer_ghost and copying.missing);
    try std.testing.expectEqual(@import("ops.zig").TransferEntryState.copying, copying.transfer_state.?);
    try std.testing.expectEqual(@as(i64, 3), copying.bytes);
    try std.testing.expectEqual(@as(i64, 2), copying.mtime);

    const pending = app.items.items[2];
    try std.testing.expectEqualStrings("pending.txt", pending.name);
    try std.testing.expect(pending.transfer_ghost and pending.missing);
    try std.testing.expect(pending.selected);
    try std.testing.expectEqual(@as(i64, 12), pending.bytes);

    const sub = app.items.items[3];
    try std.testing.expectEqualStrings("sub", sub.name);
    try std.testing.expect(sub.is_dir and sub.transfer_ghost and sub.missing);

    const done = app.items.items[4];
    try std.testing.expectEqualStrings("done.txt", done.name);
    try std.testing.expect(!done.transfer_ghost and !done.missing);
    try std.testing.expectEqual(@import("ops.zig").TransferEntryState.completed, done.transfer_state.?);

    // Browsing a ghost directory projects only its immediate manifest children.
    app.items.clearRetainingCapacity();
    app.history.current = "/destination/root/sub";
    appendTreeRows(&app, mem, &tree, &old);
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expectEqualStrings("nested.txt", app.items.items[0].name);
    try std.testing.expect(app.items.items[0].transfer_ghost);
    try std.testing.expect(app.items.items[0].missing);
}

test "existing destination directories remain ghosts while descendants are pending" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const mem = arena.allocator();

    var app: App = .{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = allocator, .current = "/destination/root" },
        .home_dir = "/",
        .items_arena = undefined,
        .transfer_tree_state = @import("app_transfer_tree.zig").State.init(allocator),
    };
    defer app.transfer_tree_state.deinit();
    defer app.items.deinit(allocator);

    try app.items.append(allocator, .{
        .name = "sub",
        .path = "/destination/root/sub",
        .is_dir = true,
        .is_symlink = false,
        .is_broken = false,
        .bytes = -1,
        .mtime = 1,
        .icon_name = "folder",
    });

    var manifest = @import("ops.zig").TransferManifest.init(allocator);
    defer manifest.deinit();
    try manifest.append("/source", "", "/destination/root", 0, .directory, 0);
    try manifest.append("/source/sub", "sub", "/destination/root/sub", 0, .directory, 0);
    try manifest.append("/source/sub/pending.bin", "sub/pending.bin", "/destination/root/sub/pending.bin", 100, .file, 0);
    manifest.entries.items[0].state = .completed;
    manifest.entries.items[1].state = .completed;
    manifest.entries.items[2].state = .pending;

    var tree = try transfer_tree.build(allocator, manifest.entries.items);
    defer tree.deinit();
    try app.transfer_tree_state.recomputeAggregates(&tree, "", 0, 0);

    var old = std.StringHashMap(ViewItem).init(allocator);
    defer old.deinit();
    appendTreeRows(&app, mem, &tree, &old);

    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expect(app.items.items[0].transfer_ghost);
    try std.testing.expect(!app.items.items[0].missing);
    try std.testing.expectEqual(
        @import("ops.zig").TransferEntryState.pending,
        app.items.items[0].transfer_state.?,
    );
    try std.testing.expect(app.items.items[0].transfer_progress != null);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        app.items.items[0].transfer_progress.?,
        0.0001,
    );
}
