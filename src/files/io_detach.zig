//! Removes a successfully transferred source entry for the Files I/O executor.
//!
//! The input payload contains an entry-kind tag followed by one
//! NUL-terminated absolute source path. Directories are removed non-recursively;
//! regular files and symlinks use unlinkat without following the final entry.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const executor = @import("io_executor.zig");
const io_tree = @import("io_tree.zig");

fn allocZ(allocator: Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

/// Build immutable operation input from an absolute source path.
pub fn makeInput(
    allocator: Allocator,
    source_path: []const u8,
    kind: io_tree.EntryKind,
) !executor.OwnedPayload {
    if (source_path.len == 0 or source_path[0] != '/')
        return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, source_path, 0) != null)
        return error.InvalidPath;

    const kind_tag: u8 = switch (kind) {
        .directory => 1,
        .regular_file => 2,
        .symlink => 3,
        .other => return error.UnsupportedEntryKind,
    };
    const bytes = try allocator.alloc(u8, source_path.len + 2);
    bytes[0] = kind_tag;
    @memcpy(bytes[1 .. source_path.len + 1], source_path);
    bytes[bytes.len - 1] = 0;
    return .{ .allocator = allocator, .bytes = bytes };
}

const ParsedInput = struct {
    path: []const u8,
    kind: io_tree.EntryKind,
};

fn parseInput(input: *const executor.OwnedPayload) !ParsedInput {
    const bytes = input.slice();
    if (bytes.len < 3 or bytes[bytes.len - 1] != 0)
        return error.InvalidInput;
    const kind: io_tree.EntryKind = switch (bytes[0]) {
        1 => .directory,
        2 => .regular_file,
        3 => .symlink,
        else => return error.InvalidInput,
    };
    const path = bytes[1 .. bytes.len - 1];
    if (path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidInput;
    return .{ .path = path, .kind = kind };
}

/// Remove one source entry without following its final path component.
pub fn execute(
    allocator: Allocator,
    item_arg: executor.WorkItem,
) executor.WorkCompletion {
    var item = item_arg;
    const parsed = parseInput(&item.input) catch {
        return completion(item, .failed);
    };
    const source_path = parsed.path;

    const separator = std.mem.lastIndexOfScalar(u8, source_path, '/') orelse
        return completion(item, .failed);
    const name = source_path[separator + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return completion(item, .failed);
    }

    const parent = if (separator == 0) "/" else source_path[0..separator];
    const parent_z = allocZ(allocator, parent) catch {
        return completion(item, .failed);
    };
    defer allocator.free(parent_z);

    const parent_fd = c.open(
        parent_z,
        c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW,
    );
    if (parent_fd < 0) return completion(item, .failed);
    defer _ = c.close(parent_fd);

    // The basename remains NUL-terminated in the owned input payload.
    const name_z: [*:0]const u8 = @ptrCast(name.ptr);
    var source_stat: c.struct_stat = undefined;
    if (c.fstatat(parent_fd, name_z, &source_stat, c.AT_SYMLINK_NOFOLLOW) != 0)
        return completion(item, .failed);

    const actual_kind: io_tree.EntryKind = switch (source_stat.st_mode & c.S_IFMT) {
        c.S_IFDIR => .directory,
        c.S_IFREG => .regular_file,
        c.S_IFLNK => .symlink,
        else => .other,
    };
    if (actual_kind != parsed.kind) return completion(item, .failed);

    const flags: c_int = if (parsed.kind == .directory) c.AT_REMOVEDIR else 0;
    if (c.unlinkat(parent_fd, name_z, flags) != 0)
        return completion(item, .failed);

    return completion(item, .completed);
}

fn completion(
    item_arg: executor.WorkItem,
    outcome: executor.WorkResult,
) executor.WorkCompletion {
    var item = item_arg;
    if (item.continuation) |*saved| {
        saved.deinit();
        item.continuation = null;
    }
    return .{
        .token = item.token,
        .outcome = outcome,
        .operation_kind = item.operation_kind,
        .input = item.input,
    };
}

pub fn discard(
    _: ?*anyopaque,
    _: executor.OperationKind,
    input: executor.OwnedPayload,
    continuation: ?executor.OwnedPayload,
    result: ?executor.OwnedPayload,
) void {
    var owned_input = input;
    owned_input.deinit();
    var owned_continuation = continuation;
    if (owned_continuation) |*payload| payload.deinit();
    if (result) |payload| {
        var owned_result = payload;
        owned_result.deinit();
    }
}

pub fn complete(
    _: ?*anyopaque,
    _: executor.WorkToken,
    _: executor.WorkResult,
    result: ?executor.OwnedPayload,
) void {
    if (result) |payload| {
        var owned_result = payload;
        owned_result.deinit();
    }
}
