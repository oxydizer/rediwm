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
    /// Borrowed from the request unless the planner resolved its parent.
    path: []const u8,
    path_owned: bool = false,
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
    destination_path_owned: bool = false,
    destination_device_id: u64,
    create_destination: bool = false,
    sources: std.ArrayList(SourcePlan) = .empty,

    pub fn deinit(self: *TransferPlan) void {
        for (self.sources.items) |source| {
            if (source.path_owned) self.allocator.free(source.path);
            if (source.symlink_target) |target| self.allocator.free(target);
            if (source.destination_name_owned) |name| self.allocator.free(name);
        }
        self.sources.deinit(self.allocator);
        if (self.destination_path_owned) self.allocator.free(self.destination_path);
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

    const parent = std.fs.path.dirname(request.destination_path) orelse "/";
    const folder_name = std.fs.path.basename(request.destination_path);
    if (request.create_destination) {
        try ops_mod.validateFilename(folder_name);
        if (request.mode != .move) return error.InvalidTransferDestination;
        if (!@import("platform").fs.hasAtomicRenameNoReplace()) return error.AtomicRenameUnavailable;
    }
    const destination_z = try allocator.dupeSentinel(u8, if (request.create_destination) parent else request.destination_path, 0);
    defer allocator.free(destination_z);
    // A selected directory can be a symlink whose target is inside a source.
    var resolved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_z = if (request.resolve_destination)
        std.mem.span(c.realpath(destination_z, &resolved_buffer) orelse return error.InvalidTransferDestination)
    else
        destination_z;
    const resolved_destination = if (request.resolve_destination) resolved_z else request.destination_path;
    var destination_stat: c.struct_stat = undefined;
    if (c.stat(resolved_z, &destination_stat) != 0 or
        (destination_stat.st_mode & c.S_IFMT) != c.S_IFDIR)
    {
        return error.InvalidTransferDestination;
    }

    // Execute through the resolved directory as well. Transfer operations
    // protect their destination paths from symlink traversal.
    var plan: TransferPlan = .{
        .allocator = allocator,
        .destination_path = if (request.resolve_destination) try allocator.dupe(u8, resolved_destination) else request.destination_path,
        .destination_path_owned = request.resolve_destination,
        .create_destination = request.create_destination,
        .destination_device_id = @intCast(destination_stat.st_dev),
    };
    errdefer plan.deinit();

    for (request.sources, 0..) |source, index| {
        if (!validAbsolutePath(source.path)) return error.InvalidTransferSource;
        if (request.create_destination) {
            const source_parent = std.fs.path.dirname(source.path) orelse return error.InvalidTransferSource;
            if (!std.mem.eql(u8, std.mem.trimEnd(u8, source_parent, "/"), std.mem.trimEnd(u8, parent, "/")))
                return error.InvalidTransferSource;
        }
        // A trailing slash makes lstat follow a directory symlink.
        const source_spelling = if (request.resolve_destination) std.mem.trimEnd(u8, source.path, "/") else source.path;
        const name = std.fs.path.basename(source_spelling);
        if (name.len == 0) return error.InvalidTransferSource;

        const source_z = try allocator.dupeSentinel(u8, source_spelling, 0);
        defer allocator.free(source_z);
        var source_stat: c.struct_stat = undefined;
        if (c.lstat(source_z, &source_stat) != 0) return error.InvalidTransferSource;

        const kind: io_tree.EntryKind = switch (source_stat.st_mode & c.S_IFMT) {
            c.S_IFREG => .regular_file,
            c.S_IFLNK => .symlink,
            c.S_IFDIR => .directory,
            else => return error.UnsupportedTransferSource,
        };

        var resolved_source = if (request.resolve_destination)
            try resolveSource(allocator, source_spelling, name)
        else
            null;
        defer if (resolved_source) |path| allocator.free(path);
        const source_path = resolved_source orelse source.path;
        if (kind == .directory and ops_mod.isDescendantOrSame(source_path, resolved_destination))
            return error.TransferDestinationInsideSource;

        // Compare parent directories by identity for folder paste. Comparing
        // the source inode would also treat distinct hard links as one entry.
        const source_parent = if (request.resolve_destination or (request.mode == .move and kind == .directory))
            parentStat(allocator, source_path) catch |err| switch (err) {
                error.InvalidTransferSource => if (request.resolve_destination)
                    return err
                else
                    return error.MountedDirectoryMoveUnsupported,
                else => return err,
            }
        else
            null;
        const lands_on_itself = if (request.resolve_destination)
            sameDirectory(source_parent.?, destination_stat)
        else
            try landsOnSource(allocator, request.destination_path, name, source.path);

        if (request.mode == .move and (!request.resolve_destination or !lands_on_itself)) {
            try validateMoveRoots(request.sources[0..index], if (request.resolve_destination) plan.sources.items else null, source_path, kind);
            if (kind == .directory and source_stat.st_dev != source_parent.?.st_dev)
                return error.MountedDirectoryMoveUnsupported;
        }

        // Moving an item to where it already is changes nothing.
        if (lands_on_itself and request.mode == .move) continue;

        var source_plan: SourcePlan = .{
            .path = source_path,
            .path_owned = resolved_source != null,
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
            const unique = try ops_mod.generateUniqueName(allocator, plan.destination_path, name);
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
        resolved_source = null;
    }

    if (plan.sources.items.len == 0) return error.TransferSourceEqualsDestination;
    return plan;
}

/// Resolve ancestors without following the selected entry itself. The leaf
/// already passed lstat, so a directory leaf yields a canonical directory
/// path and a symlink leaf is still the symlink.
fn resolveSource(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ![]u8 {
    ops_mod.validateFilename(name) catch return error.InvalidTransferSource;
    const parent = std.fs.path.dirname(path) orelse "/";
    const parent_z = try allocator.dupeSentinel(u8, parent, 0);
    defer allocator.free(parent_z);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = c.realpath(parent_z, &buffer) orelse return error.InvalidTransferSource;
    return std.fs.path.join(allocator, &.{ std.mem.span(resolved), name });
}

fn validateMoveRoots(sources: []const io_service.TransferSource, resolved: ?[]const SourcePlan, path: []const u8, kind: io_tree.EntryKind) !void {
    if (resolved) |previous_roots| {
        for (previous_roots) |previous| {
            if (overlapsResolvedRoot(path, kind, previous)) return error.OverlappingMoveRoots;
        }
    } else {
        for (sources) |previous| {
            if (ops_mod.isDescendantOrSame(path, previous.path) or
                ops_mod.isDescendantOrSame(previous.path, path))
                return error.OverlappingMoveRoots;
        }
    }
}

/// Check the parent of a non-directory entry so that overlap validation
/// never follows a selected symlink's target.
fn overlapsResolvedRoot(path: []const u8, kind: io_tree.EntryKind, previous: SourcePlan) bool {
    if (std.mem.eql(u8, path, previous.path)) return true;
    const parent_or_dir = if (kind == .directory) path else std.fs.path.dirname(path) orelse "/";
    const previous_parent_or_dir = if (previous.kind == .directory) previous.path else std.fs.path.dirname(previous.path) orelse "/";
    return (kind == .directory and ops_mod.isDescendantOrSame(path, previous_parent_or_dir)) or
        (previous.kind == .directory and ops_mod.isDescendantOrSame(previous.path, parent_or_dir));
}

fn parentStat(allocator: std.mem.Allocator, path: []const u8) !c.struct_stat {
    const parent = std.fs.path.dirname(path) orelse "/";
    const parent_z = try allocator.dupeSentinel(u8, parent, 0);
    defer allocator.free(parent_z);
    var stat: c.struct_stat = undefined;
    if (c.stat(parent_z, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFDIR)
        return error.InvalidTransferSource;
    return stat;
}

fn sameDirectory(a: c.struct_stat, b: c.struct_stat) bool {
    return a.st_dev == b.st_dev and a.st_ino == b.st_ino;
}

fn landsOnSource(allocator: std.mem.Allocator, destination: []const u8, name: []const u8, source: []const u8) !bool {
    const target = try std.fs.path.join(allocator, &.{ destination, name });
    defer allocator.free(target);
    return std.mem.eql(u8, source, target);
}

fn validAbsolutePath(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path) and
        std.mem.indexOfScalar(u8, path, 0) == null;
}
