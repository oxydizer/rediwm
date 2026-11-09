//! Linux supervisor teardown walks each descendant's tasks, including helpers
//! forked by threads other than the process leader.
const std = @import("std");
const c = @import("proc_common.zig").c;
const io = @import("platform").login_io;
const Tree = @import("proc_common.zig").Tree;

pub fn descendants(allocator: std.mem.Allocator, root: i32) !Tree {
    var result: Tree = .empty;
    errdefer result.deinit(allocator);
    var pending: std.ArrayList(i32) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, root);
    while (pending.pop()) |pid| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/task", .{pid}, 0);
        const dir = c.opendir(path) orelse continue;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |entry| {
            const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
            if (name[0] == '.') continue;
            var children_path: [96]u8 = undefined;
            const file = std.fmt.bufPrintSentinel(&children_path, "/proc/{d}/task/{s}/children", .{ pid, name }, 0) catch continue;
            const fd = io.openZ(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch continue;
            defer io.close(fd);
            const text = io.readAll(allocator, fd) catch continue;
            defer allocator.free(text);
            var it = std.mem.tokenizeScalar(u8, text, ' ');
            while (it.next()) |token| {
                const child = std.fmt.parseInt(i32, std.mem.trim(u8, token, "\n"), 10) catch continue;
                const gop = try result.getOrPut(allocator, child);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 0; // pidfds pin Linux identities after open.
                    try pending.append(allocator, child);
                }
            }
        }
    }
    return result;
}
