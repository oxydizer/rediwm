//! A UI-independent destination hierarchy projected from a transfer manifest.

const std = @import("std");
const ops = @import("ops.zig");
const Allocator = std.mem.Allocator;

pub const Node = struct {
    path: []u8,
    source_path: []u8,
    name: []u8,
    parent_index: ?usize,
    entry_index: usize,
    root_index: usize,
    kind: ops.TransferEntryKind,
    size: u64,
    state: ops.TransferEntryState,
    progress_bytes: u64 = 0,
    manager_entry_id: ?@import("io_tree.zig").EntryId = null,
    waiting_conflict: bool = false,
};

pub const Tree = struct {
    allocator: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    roots: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *Tree) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node.path);
            self.allocator.free(node.source_path);
            self.allocator.free(node.name);
        }
        self.nodes.deinit(self.allocator);
        self.roots.deinit(self.allocator);
    }
};

fn isWithinRoot(root: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, root, path)) return true;
    if (root.len == 1 and root[0] == '/') {
        return std.mem.startsWith(u8, path, "/");
    }
    return path.len > root.len and
        std.mem.startsWith(u8, path, root) and
        path[root.len] == '/';
}

/// Projects resolved manifest entries into a flat, parent-linked hierarchy.
/// Directory parents must exist in the manifest; no filesystem objects are
/// created or inspected.
pub fn build(allocator: Allocator, entries: []const ops.TransferEntry) !Tree {
    var tree: Tree = .{ .allocator = allocator };
    errdefer tree.deinit();

    var roots = std.AutoHashMap(usize, []const u8).init(allocator);
    defer roots.deinit();

    // First identify the resolved destination of every selected root.
    for (entries) |entry| {
        if (entry.relative_path.len != 0) continue;
        const destination = entry.destination_path orelse continue;
        if (!std.fs.path.isAbsolute(destination)) return error.InvalidDestinationPath;
        if (roots.contains(entry.root_index)) return error.DuplicateRoot;
        try roots.put(entry.root_index, destination);
    }

    // Build every node before linking parents, so manifest ordering does not
    // become an accidental requirement of the projection.
    var by_path = std.StringHashMap(usize).init(allocator);
    defer by_path.deinit();

    for (entries, 0..) |entry, entry_index| {
        const destination = entry.destination_path orelse continue;
        const root_path = roots.get(entry.root_index) orelse continue;

        if (!std.fs.path.isAbsolute(destination) or
            !isWithinRoot(root_path, destination))
        {
            return error.DestinationOutsideRoot;
        }

        if (by_path.contains(destination)) return error.DuplicateDestination;

        const name = std.fs.path.basename(destination);
        const owned_path = try allocator.dupe(u8, destination);
        errdefer allocator.free(owned_path);
        const owned_source_path = try allocator.dupe(u8, entry.source_path);
        errdefer allocator.free(owned_source_path);
        const owned_name = try allocator.dupe(u8, if (name.len == 0) destination else name);
        errdefer allocator.free(owned_name);

        const node_index = tree.nodes.items.len;
        try tree.nodes.append(allocator, .{
            .path = owned_path,
            .source_path = owned_source_path,
            .name = owned_name,
            .parent_index = null,
            .entry_index = entry_index,
            .root_index = entry.root_index,
            .kind = entry.kind,
            .size = entry.size,
            .state = entry.state,
            .progress_bytes = 0,
        });
        try by_path.put(tree.nodes.items[node_index].path, node_index);
    }

    // Link descendants to their explicit directory entries.
    for (tree.nodes.items, 0..) |*node, node_index| {
        const root_path = roots.get(node.root_index) orelse continue;
        if (std.mem.eql(u8, node.path, root_path)) continue;

        const parent_path = std.fs.path.dirname(node.path) orelse
            return error.MissingParent;
        const parent_index = by_path.get(parent_path) orelse
            return error.MissingParent;
        const parent = tree.nodes.items[parent_index];

        if (parent.root_index != node.root_index or parent.kind != .directory) {
            return error.InvalidParent;
        }
        if (parent_index == node_index) return error.InvalidParent;

        node.parent_index = parent_index;
    }

    // Keep a compact index of selected top-level entries for sidebar UI.
    // Descendants remain in nodes for complete subtree aggregation.
    for (tree.nodes.items, 0..) |node, index| {
        if (node.parent_index == null) {
            try tree.roots.append(allocator, index);
        }
    }

    return tree;
}

test "transfer tree projects renamed roots, nested entries and independent roots" {
    const a = std.testing.allocator;
    var manifest = ops.TransferManifest.init(a);
    defer manifest.deinit();

    try manifest.append("/source-a", "", "/destination/renamed-a", 0, .directory, 0);
    try manifest.append("/source-a/nested/file.txt", "nested/file.txt", "/destination/renamed-a/nested/file.txt", 42, .file, 0);
    try manifest.append("/source-a/empty", "empty", "/destination/renamed-a/empty", 0, .directory, 0);
    try manifest.append("/source-a/nested", "nested", "/destination/renamed-a/nested", 0, .directory, 0);
    try manifest.append("/source-b", "", "/destination/second", 0, .directory, 1);
    try manifest.append("/source-b/link", "link", "/destination/second/link", 0, .symlink, 1);
    try manifest.append("/source-b/unresolved", "unresolved", null, 10, .file, 1);

    manifest.entries.items[1].state = .copying;
    manifest.entries.items[5].state = .completed;

    var tree = try build(a, manifest.entries.items);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 6), tree.nodes.items.len);

    const root_a = tree.nodes.items[0];
    try std.testing.expectEqualStrings("/destination/renamed-a", root_a.path);
    try std.testing.expect(root_a.parent_index == null);
    try std.testing.expectEqual(@as(usize, 0), root_a.root_index);

    const file = tree.nodes.items[1];
    try std.testing.expectEqualStrings("file.txt", file.name);
    try std.testing.expectEqualStrings("/source-a/nested/file.txt", file.source_path);
    try std.testing.expectEqual(ops.TransferEntryKind.file, file.kind);
    try std.testing.expectEqual(@as(u64, 42), file.size);
    try std.testing.expectEqual(ops.TransferEntryState.copying, file.state);
    try std.testing.expectEqual(@as(usize, 0), file.root_index);

    const empty = tree.nodes.items[2];
    try std.testing.expectEqualStrings("empty", empty.name);
    try std.testing.expectEqual(ops.TransferEntryKind.directory, empty.kind);
    try std.testing.expectEqual(@as(?usize, 0), empty.parent_index);

    const nested = tree.nodes.items[3];
    try std.testing.expectEqualStrings("nested", nested.name);
    try std.testing.expectEqual(@as(?usize, 0), nested.parent_index);
    try std.testing.expectEqual(@as(?usize, 3), file.parent_index);

    const root_b = tree.nodes.items[4];
    try std.testing.expectEqualStrings("/destination/second", root_b.path);
    try std.testing.expect(root_b.parent_index == null);
    try std.testing.expectEqual(@as(usize, 1), root_b.root_index);

    const link = tree.nodes.items[5];
    try std.testing.expectEqual(ops.TransferEntryKind.symlink, link.kind);
    try std.testing.expectEqual(ops.TransferEntryState.completed, link.state);
    try std.testing.expectEqual(@as(?usize, 4), link.parent_index);
}

test "transfer tree owns its projection independently of manifest updates" {
    const a = std.testing.allocator;
    var manifest = ops.TransferManifest.init(a);
    defer manifest.deinit();

    try manifest.append("/source", "", "/destination/source", 0, .directory, 0);
    try manifest.append("/source/file", "file", "/destination/source/file", 12, .file, 0);

    var tree = try build(a, manifest.entries.items);
    defer tree.deinit();

    manifest.entries.items[1].state = .failed;
    manifest.clearRetainingCapacity();

    try std.testing.expectEqual(@as(usize, 2), tree.nodes.items.len);
    try std.testing.expectEqualStrings("/destination/source/file", tree.nodes.items[1].path);
    try std.testing.expectEqual(ops.TransferEntryState.pending, tree.nodes.items[1].state);
    try std.testing.expectEqual(@as(u64, 12), tree.nodes.items[1].size);
}

test "transfer tree rejects descendants outside their resolved root" {
    const a = std.testing.allocator;
    var manifest = ops.TransferManifest.init(a);
    defer manifest.deinit();

    try manifest.append("/source", "", "/destination/source", 0, .directory, 0);
    try manifest.append("/source/file", "file", "/destination/elsewhere/file", 1, .file, 0);

    try std.testing.expectError(error.DestinationOutsideRoot, build(a, manifest.entries.items));
}
