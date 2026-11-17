//! Listening sockets on Linux: the kernel's `/proc/net/{tcp,tcp6,udp,udp6}`
//! tables (text; `firewall/sockets.zig` parses them) and which process holds
//! each socket inode, from `/proc/<pid>/fd`. Only root sees every process's
//! descriptors; the firewall helper calls this as root.
const std = @import("std");
const common = @import("proc_common.zig");
const c = common.c;

pub const NetTable = enum { tcp, tcp6, udp, udp6 };

/// One table's text, or null when it cannot be read (no IPv6, say).
pub fn netTable(a: std.mem.Allocator, which: NetTable) ?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/net/{s}", .{@tagName(which)}, 0) catch return null;
    var size: usize = 64 << 10;
    while (size <= 16 << 20) : (size *= 4) {
        const buf = a.alloc(u8, size) catch return null;
        if (common.readAt(c.AT_FDCWD, path, buf)) |text| return text else |err| {
            a.free(buf);
            if (err != error.DataTooLarge) return null;
        }
    }
    return null;
}

pub const Owner = struct { inode: u64, pid: i32, name: []const u8 };

/// Socket inodes and the process holding each (the first one found).
pub fn socketOwners(a: std.mem.Allocator) ![]Owner {
    var list: std.ArrayList(Owner) = .empty;
    const proc = c.opendir("/proc") orelse return list.toOwnedSlice(a);
    defer _ = c.closedir(proc);
    while (c.readdir(proc)) |entry| {
        const pid_name = std.mem.sliceTo(entry.*.d_name[0..], 0);
        const pid = std.fmt.parseInt(i32, pid_name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        const fd_path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/fd", .{pid}, 0) catch continue;
        const fds = c.opendir(fd_path) orelse continue;
        defer _ = c.closedir(fds);
        var name: []const u8 = "";
        while (c.readdir(fds)) |fd_entry| {
            const fd_name = std.mem.sliceTo(fd_entry.*.d_name[0..], 0);
            if (fd_name.len == 0 or fd_name[0] == '.') continue;
            var link_buf: [64]u8 = undefined;
            var target_buf: [64]u8 = undefined;
            const link = std.fmt.bufPrintSentinel(&link_buf, "/proc/{d}/fd/{s}", .{ pid, fd_name }, 0) catch continue;
            const n = c.readlink(link, &target_buf, target_buf.len);
            if (n <= 0) continue;
            const target = target_buf[0..@intCast(n)];
            if (!std.mem.startsWith(u8, target, "socket:[") or target[target.len - 1] != ']') continue;
            const inode = std.fmt.parseInt(u64, target[8 .. target.len - 1], 10) catch continue;
            if (name.len == 0) name = comm(a, pid) catch "";
            try list.append(a, .{ .inode = inode, .pid = pid, .name = name });
        }
    }
    return list.toOwnedSlice(a);
}

fn comm(a: std.mem.Allocator, pid: i32) ![]const u8 {
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/comm", .{pid}, 0);
    var buf: [64]u8 = undefined;
    const text = common.readAt(c.AT_FDCWD, path, &buf) catch return "";
    return a.dupe(u8, std.mem.trimEnd(u8, text, "\n"));
}
