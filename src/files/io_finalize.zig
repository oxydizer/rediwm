//! Identity-checked restoration of destination directory permissions.
//!
//! Inputs are owned snapshots of destination paths and expected identities.
//! Directories are opened component-by-component without following symlinks,
//! then chmod is applied through the pinned descriptor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").api;
const io_executor = @import("io_executor.zig");

const input_header_size: usize = 4;
const record_header_size: usize = 24;
const directory_open_flags =
    c.O_PATH | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW;

pub const Record = struct {
    path: []const u8,
    device_id: u64,
    inode_id: u64,
    mode: u32,
};

pub const Stats = struct {
    restored: usize = 0,
    failed: usize = 0,
};

const ParsedRecord = struct {
    path: []const u8,
    device_id: u64,
    inode_id: u64,
    mode: u32,
    depth: usize,
};

fn writeUnsigned(comptime T: type, output: []u8, value: T) void {
    for (0..@sizeOf(T)) |index| {
        const shift: std.math.Log2Int(T) = @intCast(index * 8);
        output[index] = @truncate(value >> shift);
    }
}

fn readUnsigned(comptime T: type, input: []const u8) T {
    var value: T = 0;
    for (0..@sizeOf(T)) |index| {
        const shift: std.math.Log2Int(T) = @intCast(index * 8);
        value |= @as(T, input[index]) << shift;
    }
    return value;
}

fn pathDepth(path: []const u8) !usize {
    if (path.len < 2 or path[0] != '/' or
        std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidPath;

    var depth: usize = 0;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return error.InvalidPath;
        depth += 1;
    }
    if (depth == 0) return error.InvalidPath;
    return depth;
}

/// Encode a caller-owned snapshot into an immutable worker payload.
pub fn makeInput(
    allocator: Allocator,
    records: []const Record,
) !io_executor.OwnedPayload {
    if (records.len > std.math.maxInt(u32)) return error.TooManyRecords;

    var total_size = input_header_size;
    for (records) |record| {
        if (record.mode > 0o777) return error.InvalidMode;
        _ = try pathDepth(record.path);
        if (record.path.len > std.math.maxInt(u32)) return error.PathTooLong;
        total_size = try std.math.add(usize, total_size, record_header_size);
        total_size = try std.math.add(usize, total_size, record.path.len);
    }

    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    writeUnsigned(u32, bytes[0..4], @intCast(records.len));

    var cursor = input_header_size;
    for (records) |record| {
        writeUnsigned(u64, bytes[cursor..][0..8], record.device_id);
        writeUnsigned(u64, bytes[cursor + 8 ..][0..8], record.inode_id);
        writeUnsigned(u32, bytes[cursor + 16 ..][0..4], record.mode);
        writeUnsigned(u32, bytes[cursor + 20 ..][0..4], @intCast(record.path.len));
        cursor += record_header_size;
        @memcpy(bytes[cursor..][0..record.path.len], record.path);
        cursor += record.path.len;
    }

    return .{ .allocator = allocator, .bytes = bytes };
}

fn parseInput(
    allocator: Allocator,
    input: *const io_executor.OwnedPayload,
) ![]ParsedRecord {
    const bytes = input.slice();
    if (bytes.len < input_header_size) return error.InvalidInput;

    const count = readUnsigned(u32, bytes[0..4]);
    const records = try allocator.alloc(ParsedRecord, count);
    errdefer allocator.free(records);

    var cursor = input_header_size;
    for (records) |*record| {
        if (cursor > bytes.len or bytes.len - cursor < record_header_size)
            return error.InvalidInput;

        const device_id = readUnsigned(u64, bytes[cursor..][0..8]);
        const inode_id = readUnsigned(u64, bytes[cursor + 8 ..][0..8]);
        const mode = readUnsigned(u32, bytes[cursor + 16 ..][0..4]);
        const path_len = readUnsigned(u32, bytes[cursor + 20 ..][0..4]);
        cursor += record_header_size;

        if (mode > 0o777 or path_len == 0 or
            cursor > bytes.len or path_len > bytes.len - cursor)
            return error.InvalidInput;

        const path = bytes[cursor..][0..path_len];
        const depth = pathDepth(path) catch return error.InvalidInput;
        record.* = .{
            .path = path,
            .device_id = device_id,
            .inode_id = inode_id,
            .mode = mode,
            .depth = depth,
        };
        cursor += path_len;
    }

    if (cursor != bytes.len) return error.InvalidInput;
    return records;
}

fn deeperFirst(_: void, lhs: ParsedRecord, rhs: ParsedRecord) bool {
    return lhs.depth > rhs.depth;
}

/// Open an absolute directory path without following any component.
///
/// O_PATH permits opening directories without read permission. Every
/// component is opened relative to the already pinned parent descriptor.
fn openDirectoryNoFollow(path: []const u8) c_int {
    if (path.len < 2 or path[0] != '/') return -1;

    var current_fd = c.open("/", directory_open_flags);
    if (current_fd < 0) return -1;

    var cursor: usize = 1;
    while (cursor < path.len) {
        while (cursor < path.len and path[cursor] == '/') : (cursor += 1) {}
        if (cursor == path.len) break;

        const start = cursor;
        while (cursor < path.len and path[cursor] != '/') : (cursor += 1) {}
        const component = path[start..cursor];
        if (component.len == 0 or component.len >= 4096 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            _ = c.close(current_fd);
            return -1;
        }

        var name: [4096]u8 = undefined;
        @memcpy(name[0..component.len], component);
        name[component.len] = 0;
        const next_fd = c.openat(current_fd, @ptrCast(&name), directory_open_flags);
        _ = c.close(current_fd);
        if (next_fd < 0) return -1;
        current_fd = next_fd;
    }

    return current_fd;
}

/// Apply chmod to the object pinned by fd, not to a re-resolved destination
/// pathname. The procfs descriptor link refers to the already-open inode.
fn chmodPinned(fd: c_int, mode: u32) bool {
    var path: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&path, "/proc/self/fd/{d}", .{fd}) catch
        return false;
    if (formatted.len >= path.len) return false;
    path[formatted.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path);
    return c.chmod(path_z, @intCast(mode)) == 0;
}

fn restoreOne(record: ParsedRecord) bool {
    const fd = openDirectoryNoFollow(record.path);
    if (fd < 0) return false;
    defer _ = c.close(fd);

    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or
        (stat.st_mode & c.S_IFMT) != c.S_IFDIR or
        @as(u64, @intCast(stat.st_dev)) != record.device_id or
        @as(u64, @intCast(stat.st_ino)) != record.inode_id)
        return false;

    return chmodPinned(fd, record.mode);
}

/// Restore every record deepest-first. Individual failures do not prevent
/// unrelated directories from being restored; the caller receives totals.
pub fn execute(
    allocator: Allocator,
    input: *const io_executor.OwnedPayload,
) !Stats {
    const records = try parseInput(allocator, input);
    defer allocator.free(records);

    std.mem.sort(ParsedRecord, records, {}, deeperFirst);

    var stats: Stats = .{};
    for (records) |record| {
        if (restoreOne(record)) {
            stats.restored += 1;
        } else {
            stats.failed += 1;
        }
    }
    return stats;
}
