//! Cached UI state for the transfer destination tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const projection = @import("transfer_tree.zig");

pub const State = struct {
    allocator: Allocator,
    tree: ?projection.Tree = null,
    expanded_paths: std.StringHashMap(void),
    dirty: bool = true,

    pub fn init(allocator: Allocator) State {
        return .{
            .allocator = allocator,
            .expanded_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.tree) |*tree| tree.deinit();

        var paths = self.expanded_paths.keyIterator();
        while (paths.next()) |path| self.allocator.free(path.*);
        self.expanded_paths.deinit();
    }

    pub fn markDirty(self: *State) void {
        self.dirty = true;
    }

    /// Replaces the cached projection from one consistent manifest snapshot.
    pub fn rebuild(self: *State, runner: *ops.JobRunner) !void {
        var snapshot = try runner.snapshotTransferManifest(self.allocator);
        defer snapshot.deinit();

        var next = try projection.build(self.allocator, snapshot.entries.items);
        errdefer next.deinit();

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

    /// A node is visible only when every directory ancestor is expanded.
    pub fn nodeVisible(self: *const State, tree: *const projection.Tree, index: usize) bool {
        if (hiddenState(tree.nodes.items[index].state)) return false;
        var parent = tree.nodes.items[index].parent_index;
        while (parent) |parent_index| {
            const ancestor = tree.nodes.items[parent_index];
            if (hiddenState(ancestor.state) or ancestor.kind != .directory or
                !self.isExpanded(ancestor.path)) return false;
            parent = ancestor.parent_index;
        }
        return true;
    }

    pub fn visibleCount(self: *const State, tree: *const projection.Tree) usize {
        var count: usize = 0;
        for (tree.nodes.items, 0..) |_, index| {
            if (self.nodeVisible(tree, index)) count += 1;
        }
        return count;
    }

    fn isWithinNode(tree: *const projection.Tree, candidate: usize, ancestor: usize) bool {
        var parent = tree.nodes.items[candidate].parent_index;
        while (parent) |parent_index| {
            if (parent_index == ancestor) return true;
            parent = tree.nodes.items[parent_index].parent_index;
        }
        return candidate == ancestor;
    }

    /// Computes file-byte progress for a node and all descendant files.
    /// The active path is the manifest source path.
    pub fn aggregateProgress(
        _: *const State,
        tree: *const projection.Tree,
        index: usize,
        active_source_path: []const u8,
        active_bytes: u64,
        active_size: u64,
    ) AggregateProgress {
        var result: AggregateProgress = .{};
        for (tree.nodes.items, 0..) |node, candidate| {
            if (!isWithinNode(tree, candidate, index) or
                node.kind == .directory or hiddenState(node.state)) continue;

            result.total_bytes +|= node.size;
            if (node.state == .failed) result.failed = true;
            if (node.state == .completed) {
                result.completed_bytes +|= node.size;
            } else if (active_source_path.len > 0 and
                std.mem.eql(u8, node.source_path, active_source_path))
            {
                result.active = true;
                result.completed_bytes +|= @min(
                    active_bytes,
                    if (node.size > 0) node.size else active_size,
                );
            }
        }
        result.completed_bytes = @min(result.completed_bytes, result.total_bytes);
        return result;
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

    const aggregate = State.aggregateProgress(&tree, 0, "/source/active.bin", 4, 10);
    try std.testing.expectEqual(@as(u64, 30), aggregate.total_bytes);
    try std.testing.expectEqual(@as(u64, 24), aggregate.completed_bytes);
    try std.testing.expect(aggregate.active);
    try std.testing.expect(!aggregate.failed);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), aggregate.fraction(), 0.0001);
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
    try state.toggleExpanded("/destination/source");

    try std.testing.expect(state.nodeVisible(&tree, 0));
    try std.testing.expect(state.nodeVisible(&tree, 1));
    try std.testing.expect(!state.nodeVisible(&tree, 2));
    try std.testing.expect(!state.nodeVisible(&tree, 3));
    try std.testing.expectEqual(@as(usize, 2), state.visibleCount(&tree));
}
