//! Raw Linux helpers shared by the login supervisor. These are raw syscalls:
//! errors come from `linux.errno(rc)`, never libc errno.
const std = @import("std");
const linux = std.os.linux;

/// Where supervisor diagnostics go: the journal (stderr) until session.log opens.
pub var diag_fd: i32 = 2;

pub fn diagnostic(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) return;
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "rediwm-session: " ++ fmt ++ "\n", args) catch blk: {
        buf[buf.len - 4 ..].* = "...\n".*;
        break :blk buf[0..];
    };
    writeAll(diag_fd, text) catch {};
}

pub fn check(rc: usize) SysError!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => |err| errnoError(err),
    };
}

/// Retries EINTR; every other failure is mapped through `errnoError`.
pub fn retry(comptime f: anytype, args: anytype) SysError!usize {
    while (true) {
        const rc = @call(.auto, f, args);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |err| return errnoError(err),
        }
    }
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

pub fn writeAll(fd: i32, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = try retry(linux.write, .{ fd, rest.ptr, rest.len });
        if (n == 0) return error.WriteFailed;
        rest = rest[n..];
    }
}

pub fn readAll(allocator: std.mem.Allocator, fd: i32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (true) {
        try out.ensureUnusedCapacity(allocator, 4096);
        const spare = out.unusedCapacitySlice();
        const n = try retry(linux.read, .{ fd, spare.ptr, spare.len });
        if (n == 0) return out.toOwnedSlice(allocator);
        out.items.len += n;
    }
}

pub fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub const SysError = error{ FileNotFound, PathAlreadyExists, AccessDenied, ProcessNotFound, WouldBlock, BrokenPipe, ConnectionReset, SymLinkLoop, Unexpected };

pub fn errnoError(err: linux.E) SysError {
    return switch (err) {
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        .SRCH => error.ProcessNotFound,
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .LOOP => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

pub fn openZ(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) !i32 {
    const rc = try retry(linux.openat, .{ linux.AT.FDCWD, path, flags, mode });
    return @intCast(rc);
}

pub fn unlinkZ(path: [*:0]const u8) !void {
    _ = try check(linux.unlinkat(linux.AT.FDCWD, path, 0));
}

pub fn renameZ(from: [*:0]const u8, to: [*:0]const u8) !void {
    _ = try check(linux.renameat(linux.AT.FDCWD, from, linux.AT.FDCWD, to));
}
