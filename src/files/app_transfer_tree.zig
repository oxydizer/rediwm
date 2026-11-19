//! Cached UI state for the transfer destination tree.

const std = @import("std");
const ui_profile = @import("ui_profile.zig");
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const projection = @import("transfer_tree.zig");
const io_manager = @import("io_manager.zig");

pub const State = struct {
    allocator: Allocator,
    tree: ?projection.Tree = null,
    expanded_paths: std.StringHashMap(void),
    aggregate_cache: std.ArrayList(AggregateProgress) = .empty,
    child_counts: std.ArrayList(usize) = .empty,
    aggregate_queue: std.ArrayList(usize) = .empty,
    dirty: bool = true,

    pub fn init(allocator: Allocator) State {
        return .{
            .allocator = allocator,
            .expanded_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.tree) |*tree| tree.deinit();

        self.aggregate_cache.deinit(self.allocator);
        self.child_counts.deinit(self.allocator);
        self.aggregate_queue.deinit(self.allocator);

        var paths = self.expanded_paths.keyIterator();
        while (paths.next()) |path| self.allocator.free(path.*);
        self.expanded_paths.deinit();
    }

    pub fn markDirty(self: *State) void {
        self.dirty = true;
    }

    /// Replaces the cached projection from one consistent manifest snapshot.
    pub fn rebuild(self: *State, runner: *ops.JobRunner) !void {
        var profiled_nodes = self.treeSize();
        const profile_started = ui_profile.start();
        defer ui_profile.finish(profile_started, "sidebar_tree_rebuild", profiled_nodes);

        const snapshot_started = ui_profile.start();
        var snapshot = try runner.snapshotTransferManifest(self.allocator);
        ui_profile.finish(snapshot_started, "sidebar_manifest_snapshot", snapshot.entries.items.len);
        defer snapshot.deinit();

        const build_started = ui_profile.start();
        var next = try projection.build(self.allocator, snapshot.entries.items);
        profiled_nodes = next.nodes.items.len;
        ui_profile.finish(build_started, "sidebar_tree_projection", next.nodes.items.len);
        errdefer next.deinit();

        try self.aggregate_cache.ensureTotalCapacity(self.allocator, next.nodes.items.len);
        try self.child_counts.ensureTotalCapacity(self.allocator, next.nodes.items.len);
        try self.aggregate_queue.ensureTotalCapacity(self.allocator, next.nodes.items.len);

        if (self.tree) |*old| old.deinit();
        self.tree = next;
        self.dirty = false;
    }

    /// Projects the Manager-owned incremental tree into the existing
    /// destination hierarchy used by the Files listing and transfer UI.
    pub fn rebuildManager(
        self: *State,
        manager: *const io_manager.Manager,
        job_id: io_manager.JobId,
    ) !void {
        const source_tree = manager.treeIndex(job_id) orelse return error.UnknownJob;
        var manifest = ops.TransferManifest.init(self.allocator);
        defer manifest.deinit();

        for (source_tree.entries.items) |entry| {
            const kind: ops.TransferEntryKind = switch (entry.kind) {
                .directory => .directory,
                .regular_file => .file,
                .symlink => .symlink,
                .other => continue,
            };

            const root_id = source_tree.rootForEntry(entry.id) orelse
                return error.UnknownEntry;
            var root_index: usize = 0;
            var found_root = false;
            for (source_tree.roots(), 0..) |candidate, index| {
                if (candidate != root_id) continue;
                root_index = index;
                found_root = true;
                break;
            }
            if (!found_root) return error.UnknownRoot;

            const source_path = try manager.sourcePath(
                self.allocator,
                job_id,
                entry.id,
            );
            defer self.allocator.free(source_path);
            const destination_path = try manager.destinationPath(
                self.allocator,
                job_id,
                entry.id,
            );
            defer self.allocator.free(destination_path);

            const full_relative_path = try source_tree.relativePath(
                self.allocator,
                entry.id,
            );
            defer self.allocator.free(full_relative_path);

            const relative_path: []const u8 = if (entry.parent_id == null)
                ""
            else blk: {
                const root = source_tree.getConst(root_id) orelse
                    return error.UnknownRoot;
                if (full_relative_path.len <= root.name.len or
                    !std.mem.startsWith(u8, full_relative_path, root.name) or
                    full_relative_path[root.name.len] != '/')
                {
                    return error.InvalidTreePath;
                }
                break :blk full_relative_path[root.name.len + 1 ..];
            };

            const state: ops.TransferEntryState =
                if (manager.entryOperationView(job_id, entry.id)) |operation| switch (operation.state) {
                    .pending => if (operation.generation > 0) .copying else .pending,
                    .running => .copying,
                    .waiting => .pending,
                    .completed => .completed,
                    .skipped => .skipped,
                    .failed => .failed,
                    .cancelled => .cancelled,
                } else if (entry.discovery == .failed) .failed else .pending;

            try manifest.append(
                source_path,
                relative_path,
                destination_path,
                entry.metadata.size,
                kind,
                root_index,
            );
            manifest.entries.items[manifest.entries.items.len - 1].state = state;
        }

        var next = try projection.build(self.allocator, manifest.entries.items);
        errdefer next.deinit();

        try self.aggregate_cache.ensureTotalCapacity(
            self.allocator,
            next.nodes.items.len,
        );
        try self.child_counts.ensureTotalCapacity(
            self.allocator,
            next.nodes.items.len,
        );
        try self.aggregate_queue.ensureTotalCapacity(
            self.allocator,
            next.nodes.items.len,
        );

        if (self.tree) |*old| old.deinit();
        self.tree = next;
        self.dirty = false;
    }

    pub fn isExpanded(self: *const State, path: []const u8) bool {
        return self.expanded_paths.contains(path);
    }

    pub const AggregateProgress = struct {
        total_bytes: u64 = 0,
        completed_bytes: u64 = 0,
        active: bool = false,
        failed: bool = false,

        pub fn fraction(self: AggregateProgress) f64 {
            if (self.total_bytes == 0) return 0;
            return @min(1.0, @as(f64, @floatFromInt(self.completed_bytes)) /
                @as(f64, @floatFromInt(self.total_bytes)));
        }
    };

    fn hiddenState(state: ops.TransferEntryState) bool {
        return state == .skipped or state == .cancelled;
    }

    /// The Transfers sidebar displays selected roots only.
    pub fn nodeVisible(self: *const State, tree: *const projection.Tree, index: usize) bool {
        _ = self;
        const node = tree.nodes.items[index];
        return node.parent_index == null and !hiddenState(node.state);
    }

    pub fn visibleCount(self: *const State, tree: *const projection.Tree) usize {
        const profile_started = ui_profile.start();
        defer ui_profile.finish(profile_started, "tree_visible_count", tree.roots.items.len);

        var count: usize = 0;
        for (tree.roots.items) |index| {
            if (self.nodeVisible(tree, index)) count += 1;
        }
        return count;
    }

    /// Computes every node's subtree progress in one bottom-up pass.
    /// The active path is the manifest source path. The queue processes
    /// leaves before parents, independent of manifest/node ordering.
    pub fn recomputeAggregates(
        self: *State,
        tree: *const projection.Tree,
        active_source_path: []const u8,
        active_bytes: u64,
        active_size: u64,
    ) !void {
        const profile_started = ui_profile.start();
        defer ui_profile.finish(profile_started, "tree_aggregate", tree.nodes.items.len);

        const count = tree.nodes.items.len;
        try self.aggregate_cache.ensureTotalCapacity(self.allocator, count);
        try self.child_counts.ensureTotalCapacity(self.allocator, count);
        try self.aggregate_queue.ensureTotalCapacity(self.allocator, count);

        self.aggregate_cache.clearRetainingCapacity();
        self.child_counts.clearRetainingCapacity();
        self.aggregate_queue.clearRetainingCapacity();

        for (tree.nodes.items, 0..) |node, index| {
            self.aggregate_cache.appendAssumeCapacity(.{});
            self.child_counts.appendAssumeCapacity(0);

            if (node.kind != .directory and !hiddenState(node.state)) {
                var aggregate = &self.aggregate_cache.items[index];
                aggregate.total_bytes = node.size;
                if (node.state == .failed) {
                    aggregate.failed = true;
                } else if (node.state == .completed) {
                    aggregate.completed_bytes = node.size;
                } else if (active_source_path.len > 0 and
                    std.mem.eql(u8, node.source_path, active_source_path))
                {
                    aggregate.active = true;
                    aggregate.completed_bytes = @min(
                        active_bytes,
                        if (node.size > 0) node.size else active_size,
                    );
                }
            }

            if (node.parent_index) |parent| {
                self.child_counts.items[parent] += 1;
            }
        }

        for (self.child_counts.items, 0..) |children, index| {
            if (children == 0) self.aggregate_queue.appendAssumeCapacity(index);
        }

        var head: usize = 0;
        while (head < self.aggregate_queue.items.len) : (head += 1) {
            const child_index = self.aggregate_queue.items[head];
            const parent_index = tree.nodes.items[child_index].parent_index orelse continue;
            const child = self.aggregate_cache.items[child_index];
            const parent = &self.aggregate_cache.items[parent_index];

            parent.total_bytes +|= child.total_bytes;
            parent.completed_bytes +|= child.completed_bytes;
            parent.active = parent.active or child.active;
            parent.failed = parent.failed or child.failed;

            self.child_counts.items[parent_index] -= 1;
            if (self.child_counts.items[parent_index] == 0) {
                self.aggregate_queue.appendAssumeCapacity(parent_index);
            }
        }

        for (self.aggregate_cache.items) |*aggregate| {
            aggregate.completed_bytes = @min(
                aggregate.completed_bytes,
                aggregate.total_bytes,
            );
        }
    }

    pub fn aggregateProgress(self: *const State, index: usize) AggregateProgress {
        return self.aggregate_cache.items[index];
    }

    fn treeSize(self: *const State) usize {
        return if (self.tree) |*tree| tree.nodes.items.len else 0;
    }

    pub fn toggleExpanded(self: *State, path: []const u8) !void {
        if (self.expanded_paths.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
        } else {
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            try self.expanded_paths.put(owned_path, {});
        }
    }
};

test "transfer tree expansion is keyed by destination path" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(!state.isExpanded("/destination/renamed"));

    try state.toggleExpanded("/destination/renamed");
    try std.testing.expect(state.isExpanded("/destination/renamed"));
    try std.testing.expect(!state.isExpanded("/destination/other"));

    try state.toggleExpanded("/destination/renamed");
    try std.testing.expect(!state.isExpanded("/destination/renamed"));
}

test "transfer tree state owns expansion paths" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const path = try std.testing.allocator.dupe(u8, "/destination/folder");
    try state.expanded_paths.put(path, {});

    try std.testing.expect(state.isExpanded("/destination/folder"));
}

test "transfer tree aggregates descendant file progress" {
    const allocator = std.testing.allocator;
    var manifest = ops.TransferManifest.init(allocator);
    defer manifest.deinit();

    try manifest.append("/source", "", "/destination/source", 0, .directory, 0);
    try manifest.append("/source/active.bin", "active.bin", "/destination/source/active.bin", 10, .file, 0);
    try manifest.append("/source/done.bin", "done.bin", "/destination/source/done.bin", 20, .file, 0);
    try manifest.append("/source/skipped.bin", "skipped.bin", "/destination/source/skipped.bin", 30, .file, 0);

    manifest.entries.items[1].state = .copying;
    manifest.entries.items[2].state = .completed;
    manifest.entries.items[3].state = .skipped;

    var tree = try projection.build(allocator, manifest.entries.items);
    defer tree.deinit();

    var state = State.init(allocator);
    defer state.deinit();
    try state.recomputeAggregates(&tree, "/source/active.bin", 4, 10);
    const aggregate = state.aggregateProgress(0);
    try std.testing.expectEqual(@as(u64, 30), aggregate.total_bytes);
    try std.testing.expectEqual(@as(u64, 24), aggregate.completed_bytes);
    try std.testing.expect(aggregate.active);
    try std.testing.expect(!aggregate.failed);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), aggregate.fraction(), 0.0001);
}

test "transfer tree aggregates deeply nested progress without mixing roots or outcomes" {
    const allocator = std.testing.allocator;
    var manifest = ops.TransferManifest.init(allocator);
    defer manifest.deinit();

    try manifest.append("/source-a", "", "/destination/a", 0, .directory, 0);
    try manifest.append("/source-a/one", "one", "/destination/a/one", 0, .directory, 0);
    try manifest.append("/source-a/one/two", "one/two", "/destination/a/one/two", 0, .directory, 0);
    try manifest.append("/source-a/one/two/active.bin", "one/two/active.bin", "/destination/a/one/two/active.bin", 10, .file, 0);
    try manifest.append("/source-a/one/done.bin", "one/done.bin", "/destination/a/one/done.bin", 20, .file, 0);
    try manifest.append("/source-a/pending.bin", "pending.bin", "/destination/a/pending.bin", 30, .file, 0);
    try manifest.append("/source-a/failed.bin", "failed.bin", "/destination/a/failed.bin", 40, .file, 0);
    try manifest.append("/source-a/skipped.bin", "skipped.bin", "/destination/a/skipped.bin", 50, .file, 0);
    try manifest.append("/source-a/cancelled.bin", "cancelled.bin", "/destination/a/cancelled.bin", 60, .file, 0);
    try manifest.append("/source-b", "", "/destination/b", 0, .directory, 1);
    try manifest.append("/source-b/other.bin", "other.bin", "/destination/b/other.bin", 70, .file, 1);

    manifest.entries.items[3].state = .copying;
    manifest.entries.items[4].state = .completed;
    manifest.entries.items[6].state = .failed;
    manifest.entries.items[7].state = .skipped;
    manifest.entries.items[8].state = .cancelled;
    manifest.entries.items[10].state = .completed;

    var tree = try projection.build(allocator, manifest.entries.items);
    defer tree.deinit();

    var state = State.init(allocator);
    defer state.deinit();

    // Root includes every visible descendant, but excludes skipped/cancelled
    // payloads. Failed payload remains in the denominator.
    try state.recomputeAggregates(&tree, "/source-a/one/two/active.bin", 4, 10);
    const root = state.aggregateProgress(0);
    try std.testing.expectEqual(@as(u64, 100), root.total_bytes);
    try std.testing.expectEqual(@as(u64, 24), root.completed_bytes);
    try std.testing.expect(root.active);
    try std.testing.expect(root.failed);
    try std.testing.expectApproxEqAbs(@as(f64, 0.24), root.fraction(), 0.0001);

    // The middle directory aggregates only its own subtree.
    const middle = state.aggregateProgress(1);
    try std.testing.expectEqual(@as(u64, 30), middle.total_bytes);
    try std.testing.expectEqual(@as(u64, 24), middle.completed_bytes);
    try std.testing.expect(middle.active);
    try std.testing.expect(!middle.failed);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), middle.fraction(), 0.0001);

    // The deepest directory sees only the active file.
    const deepest = state.aggregateProgress(2);
    try std.testing.expectEqual(@as(u64, 10), deepest.total_bytes);
    try std.testing.expectEqual(@as(u64, 4), deepest.completed_bytes);
    try std.testing.expect(deepest.active);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), deepest.fraction(), 0.0001);

    // A second selected root never inherits the first root's active progress.
    const other_root = state.aggregateProgress(9);
    try std.testing.expectEqual(@as(u64, 70), other_root.total_bytes);
    try std.testing.expectEqual(@as(u64, 70), other_root.completed_bytes);
    try std.testing.expect(!other_root.active);
    try std.testing.expect(!other_root.failed);
    try std.testing.expectEqual(@as(f64, 1.0), other_root.fraction());
}

test "transfer tree hides skipped and cancelled entries" {
    const allocator = std.testing.allocator;
    var manifest = ops.TransferManifest.init(allocator);
    defer manifest.deinit();

    try manifest.append("/source", "", "/destination/source", 0, .directory, 0);
    try manifest.append("/source/visible", "visible", "/destination/source/visible", 10, .file, 0);
    try manifest.append("/source/skipped", "skipped", "/destination/source/skipped", 10, .file, 0);
    try manifest.append("/source/cancelled", "cancelled", "/destination/source/cancelled", 10, .file, 0);

    manifest.entries.items[2].state = .skipped;
    manifest.entries.items[3].state = .cancelled;

    var tree = try projection.build(allocator, manifest.entries.items);
    defer tree.deinit();

    var state = State.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.nodeVisible(&tree, 0));
    try std.testing.expect(!state.nodeVisible(&tree, 1));
    try std.testing.expect(!state.nodeVisible(&tree, 2));
    try std.testing.expect(!state.nodeVisible(&tree, 3));
    try std.testing.expectEqual(@as(usize, 1), state.visibleCount(&tree));
    try std.testing.expectEqual(@as(usize, 1), tree.roots.items.len);
}
