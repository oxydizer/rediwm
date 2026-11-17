//! Manager-owned, incrementally populated representation of a source tree.
//! EntryIds remain stable even when the backing entry array reallocates.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EntryId = u64;

pub const EntryKind = enum {
    directory,
    regular_file,
    symlink,
    other,
};

pub const DiscoveryState = enum {
    not_applicable,
    unscanned,
    queued,
    scanning,
    complete,
    failed,
    skipped,
};

pub const Metadata = struct {
    size: u64 = 0,
    mode: u32 = 0,
    mtime_sec: i64 = 0,
    mtime_nsec: i64 = 0,
};

pub const Entry = struct {
    id: EntryId,
    parent_id: ?EntryId,
    /// A single filename component. Linux filenames are not assumed UTF-8.
    name: []u8,
    kind: EntryKind,
    metadata: Metadata = .{},
    children: std.ArrayList(EntryId) = .empty,
    discovery: DiscoveryState = .not_applicable,
    /// Literal readlinkat() result. Never canonicalized or dereferenced.
    symlink_target: ?[]u8 = null,

    fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.symlink_target) |target| allocator.free(target);
        self.children.deinit(allocator);
    }
};

pub const TreeIndex = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    indices: std.AutoHashMapUnmanaged(EntryId, usize) = .empty,
    root_id: ?EntryId = null,
    next_id: EntryId = 1,

    pub fn init(allocator: Allocator) TreeIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TreeIndex) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    /// Adds the single root entry. Its name is the root's display name;
    /// its parent is null.
    pub fn addRoot(
        self: *TreeIndex,
        name: []const u8,
        kind: EntryKind,
        metadata: Metadata,
        symlink_target: ?[]const u8,
    ) !EntryId {
        if (self.root_id != null) return error.RootAlreadyExists;
        return self.addEntry(null, name, kind, metadata, symlink_target);
    }

    /// Adds a discovered child. Only directory entries may have children.
    /// Ownership of all stored bytes belongs to the TreeIndex.
    pub fn addEntry(
        self: *TreeIndex,
        parent_id: ?EntryId,
        name: []const u8,
        kind: EntryKind,
        metadata: Metadata,
        symlink_target: ?[]const u8,
    ) !EntryId {
        if (name.len == 0) return error.InvalidName;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidName;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
            return error.InvalidName;
        if ((kind == .symlink) != (symlink_target != null))
            return error.InvalidSymlinkTarget;
        if (self.next_id == std.math.maxInt(EntryId)) return error.IdExhausted;

        var parent_index: ?usize = null;
        if (parent_id) |id| {
            const index = self.indices.get(id) orelse return error.UnknownParent;
            if (self.entries.items[index].kind != .directory)
                return error.ParentNotDirectory;
            parent_index = index;
            try self.entries.items[index].children.ensureUnusedCapacity(self.allocator, 1);
        } else if (self.root_id != null or self.entries.items.len != 0) {
            return error.RootAlreadyExists;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_target = if (symlink_target) |target|
            try self.allocator.dupe(u8, target)
        else
            null;
        errdefer if (owned_target) |target| self.allocator.free(target);

        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.indices.ensureUnusedCapacity(self.allocator, 1);

        const id = self.next_id;
        const index = self.entries.items.len;
        self.entries.appendAssumeCapacity(.{
            .id = id,
            .parent_id = parent_id,
            .name = owned_name,
            .kind = kind,
            .metadata = metadata,
            .discovery = if (kind == .directory) .unscanned else .not_applicable,
            .symlink_target = owned_target,
        });
        self.indices.putAssumeCapacity(id, index);
        if (parent_index) |index_of_parent| {
            self.entries.items[index_of_parent].children.appendAssumeCapacity(id);
        } else {
            self.root_id = id;
        }
        self.next_id += 1;
        return id;
    }

    pub fn get(self: *TreeIndex, id: EntryId) ?*Entry {
        const index = self.indices.get(id) orelse return null;
        return &self.entries.items[index];
    }

    pub fn getConst(self: *const TreeIndex, id: EntryId) ?*const Entry {
        const index = self.indices.get(id) orelse return null;
        return &self.entries.items[index];
    }

    pub fn root(self: *const TreeIndex) ?EntryId {
        return self.root_id;
    }

    pub fn count(self: *const TreeIndex) usize {
        return self.entries.items.len;
    }
};

test "TreeIndex owns entries and preserves stable parent-child IDs" {
    const allocator = std.testing.allocator;
    var tree = TreeIndex.init(allocator);
    defer tree.deinit();

    const root_id = try tree.addRoot("source", .directory, .{ .mode = 0o755 }, null);
    const folder_id = try tree.addEntry(root_id, "folder", .directory, .{}, null);
    const file_id = try tree.addEntry(folder_id, "file.bin", .regular_file, .{ .size = 123 }, null);

    try std.testing.expectEqual(@as(?EntryId, root_id), tree.root());
    try std.testing.expectEqual(@as(usize, 3), tree.count());
    try std.testing.expectEqual(root_id, tree.getConst(folder_id).?.parent_id.?);
    try std.testing.expectEqual(folder_id, tree.getConst(file_id).?.parent_id.?);
    try std.testing.expectEqual(file_id, tree.getConst(folder_id).?.children.items[0]);
    try std.testing.expectEqual(DiscoveryState.unscanned, tree.getConst(folder_id).?.discovery);
    try std.testing.expectEqual(@as(u64, 123), tree.getConst(file_id).?.metadata.size);
}

test "TreeIndex stores literal symlink targets without interpretation" {
    const allocator = std.testing.allocator;
    var tree = TreeIndex.init(allocator);
    defer tree.deinit();

    const root_id = try tree.addRoot("source", .directory, .{}, null);
    const link_id = try tree.addEntry(root_id, "relative-link", .symlink, .{}, "../outside/target");
    try std.testing.expectEqualStrings("../outside/target", tree.getConst(link_id).?.symlink_target.?);
}

test "TreeIndex rejects invalid parents, names, and duplicate roots" {
    const allocator = std.testing.allocator;
    var tree = TreeIndex.init(allocator);
    defer tree.deinit();

    const root_id = try tree.addRoot("source", .directory, .{}, null);
    const file_id = try tree.addEntry(root_id, "file", .regular_file, .{}, null);
    try std.testing.expectError(error.ParentNotDirectory, tree.addEntry(file_id, "child", .regular_file, .{}, null));
    try std.testing.expectError(error.InvalidName, tree.addEntry(root_id, "../escape", .regular_file, .{}, null));
    try std.testing.expectError(error.InvalidName, tree.addEntry(root_id, "bad/name", .regular_file, .{}, null));
    try std.testing.expectError(error.InvalidSymlinkTarget, tree.addEntry(root_id, "link", .symlink, .{}, null));
    try std.testing.expectError(error.RootAlreadyExists, tree.addRoot("another", .directory, .{}, null));
    try std.testing.expectError(error.UnknownParent, tree.addEntry(999, "orphan", .regular_file, .{}, null));
}
