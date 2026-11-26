//! Submit-time planning for Files transfers: the blocking half of
//! `submit_job`. It inspects the destination and every source (lstat, stat,
//! readlink) and returns an owned plan; it reads no Manager state. Today the
//! coordinator calls it under the C1 exemption; stage S2 runs it as a prepare
//! task on a discovery worker (docs/plans/files-io-threading-and-ownership.md §8).
const std = @import("std");
const c = @import("c.zig").api;
const io_service = @import("io_service.zig");
const io_tree = @import("io_tree.zig");
const ops_mod = @import("ops.zig");
const io_thread_guard = @import("io_thread_guard.zig");

/// One selected source, inspected and ready to become a Manager root.
pub const SourcePlan = struct {
    /// Borrowed from the request, which outlives the plan.
    path: []const u8,
    /// The name in the destination: the basename, or a unique name when the
    /// copy would land on the source itself.
    destination_name: []const u8,
    destination_name_owned: ?[]u8 = null,
    kind: io_tree.EntryKind,
    metadata: io_tree.Metadata,
    symlink_target: ?[]u8 = null,
    same_device: bool,
};

pub const TransferPlan = struct {
    allocator: std.mem.Allocator,
    destination_path: []const u8,
    destination_device_id: u64,
    sources: std.ArrayList(SourcePlan) = .empty,

    pub fn deinit(self: *TransferPlan) void {
        for (self.sources.items) |source| {
            if (source.symlink_target) |target| self.allocator.free(target);
            if (source.destination_name_owned) |name| self.allocator.free(name);
        }
        self.sources.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Inspects the request's destination and sources. This is the blocking
/// half of a submit (lstat, stat, readlink); it reads no Manager state.
///
/// Rules, matching what the retired JobRunner fallback covered:
/// * Files, symlinks and directories may be mixed in one job.
/// * A copy whose target is the source itself gets a unique destination name.
/// * A move whose target is the source itself is a no-op for that source; a
///   request with nothing left to do is rejected.
/// * Moved roots must not overlap; a moved directory must not be a mount
///   point; nothing may be transferred into itself or a descendant.
/// * Other file types (FIFOs, sockets, devices) are refused.
pub fn prepare(
    allocator: std.mem.Allocator,
    request: *const io_service.TransferRequest,
) !TransferPlan {
    io_thread_guard.blocking("submit validation");
    if (request.sources.len == 0) return error.EmptyTransfer;
    if (!validAbsolutePath(request.destination_path))
        return error.InvalidTransferDestination;

    const destination_z = try allocator.dupeSentinel(u8, request.destination_path, 0);
    defer allocator.free(destination_z);
    var destination_stat: c.struct_stat = undefined;
    if (c.stat(destination_z, &destination_stat) != 0 or
        (destination_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
    {
        return error.InvalidTransferDestination;
    }

    var plan: TransferPlan = .{
        .allocator = allocator,
        .destination_path = request.destination_path,
        .destination_device_id = @intCast(destination_stat.st_dev),
    };
    errdefer plan.deinit();

    for (request.sources, 0..) |source, index| {
        if (!validAbsolutePath(source.path)) return error.InvalidTransferSource;
        const name = std.fs.path.basename(source.path);
        if (name.len == 0) return error.InvalidTransferSource;

        const source_z = try allocator.dupeSentinel(u8, source.path, 0);
        defer allocator.free(source_z);
        var source_stat: c.struct_stat = undefined;
        if (c.lstat(source_z, &source_stat) != 0) return error.InvalidTransferSource;

        const kind: io_tree.EntryKind = switch (source_stat.st_mode & c.S_IFMT) {
            c.S_IFREG => .regular_file,
            c.S_IFLNK => .symlink,
            c.S_IFDIR => .directory,
            else => return error.UnsupportedTransferSource,
        };

        // Nothing may be copied or moved into itself or a descendant.
        if (kind == .directory and
            ops_mod.isDescendantOrSame(source.path, request.destination_path))
        {
            return error.TransferDestinationInsideSource;
        }

        if (request.mode == .move) {
            // Moving overlapping roots independently could detach a parent
            // before the separately selected child is moved.
            for (request.sources[0..index]) |previous| {
                if (ops_mod.isDescendantOrSame(source.path, previous.path) or
                    ops_mod.isDescendantOrSame(previous.path, source.path))
                {
                    return error.OverlappingMoveRoots;
                }
            }
            if (kind == .directory) {
                // Do not move a directory that is itself a mount point.
                const parent_path = std.fs.path.dirname(source.path) orelse "/";
                const parent_z = try allocator.dupeSentinel(u8, parent_path, 0);
                defer allocator.free(parent_z);
                var parent_stat: c.struct_stat = undefined;
                if (c.stat(parent_z, &parent_stat) != 0 or
                    source_stat.st_dev != parent_stat.st_dev)
                {
                    return error.MountedDirectoryMoveUnsupported;
                }
            }
        }

        const lands_on_itself = lands: {
            const target_path = try std.fs.path.join(allocator, &.{ request.destination_path, name });
            defer allocator.free(target_path);
            break :lands std.mem.eql(u8, source.path, target_path);
        };
        // Moving an item to where it already is changes nothing.
        if (lands_on_itself and request.mode == .move) continue;

        var source_plan: SourcePlan = .{
            .path = source.path,
            .destination_name = name,
            .kind = kind,
            .metadata = .{
                .size = if (kind == .directory) 0 else @intCast(@max(source_stat.st_size, 0)),
                .mode = @intCast(source_stat.st_mode),
                .device_id = @intCast(source_stat.st_dev),
                .inode_id = @intCast(source_stat.st_ino),
                .mtime_sec = @intCast(source_stat.st_mtim.tv_sec),
                .mtime_nsec = @intCast(source_stat.st_mtim.tv_nsec),
                .ctime_sec = @intCast(source_stat.st_ctim.tv_sec),
                .ctime_nsec = @intCast(source_stat.st_ctim.tv_nsec),
            },
            .same_device = source_stat.st_dev == destination_stat.st_dev,
        };
        errdefer {
            if (source_plan.symlink_target) |target| allocator.free(target);
            if (source_plan.destination_name_owned) |owned| allocator.free(owned);
        }

        // A copy onto itself would make Replace or Merge destroy the source,
        // so it gets a unique name instead: pasting into the same folder
        // makes a copy.
        if (lands_on_itself) {
            const unique = try ops_mod.generateUniqueName(allocator, request.destination_path, name);
            source_plan.destination_name_owned = unique;
            source_plan.destination_name = unique;
        }

        if (kind == .symlink) {
            var target_buffer: [4096]u8 = undefined;
            const target_len = c.readlink(source_z, &target_buffer, target_buffer.len);
            if (target_len < 0 or target_len == target_buffer.len)
                return error.InvalidTransferSource;
            source_plan.symlink_target = try allocator.dupe(u8, target_buffer[0..@intCast(target_len)]);
        }

        try plan.sources.append(allocator, source_plan);
    }

    if (plan.sources.items.len == 0) return error.TransferSourceEqualsDestination;
    return plan;
}

fn validAbsolutePath(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path) and
        std.mem.indexOfScalar(u8, path, 0) == null;
}
