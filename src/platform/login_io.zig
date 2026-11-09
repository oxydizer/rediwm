//! Small libc-based I/O helpers for the login supervisor, on Linux and FreeBSD.
const std = @import("std");
const c = std.c;

pub const Error = error{ FileNotFound, PathAlreadyExists, AccessDenied, ProcessNotFound, WouldBlock, BrokenPipe, ConnectionReset, SymLinkLoop, Unexpected };

pub fn errnoError(err: std.posix.E) Error {
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

pub fn check(rc: anytype) Error!usize {
    if (rc < 0) return errnoError(std.posix.errno(rc));
    return @intCast(rc);
}

pub fn retry(comptime f: anytype, args: anytype) Error!usize {
    while (true) {
        const rc = @call(.auto, f, args);
        if (rc >= 0) return @intCast(rc);
        const err = std.posix.errno(rc);
        if (err != .INTR) return errnoError(err);
    }
}

pub fn close(fd: i32) void {
    _ = c.close(fd);
}

pub fn writeAll(fd: i32, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = try retry(c.write, .{ fd, rest.ptr, rest.len });
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
        const n = try retry(c.read, .{ fd, spare.ptr, spare.len });
        if (n == 0) return out.toOwnedSlice(allocator);
        out.items.len += n;
    }
}

pub fn monotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn openZ(path: [*:0]const u8, flags: std.posix.O, mode: std.posix.mode_t) !i32 {
    return @intCast(try retry(c.openat, .{ std.posix.AT.FDCWD, path, flags, @as(c_uint, mode) }));
}

pub fn unlinkZ(path: [*:0]const u8) !void {
    _ = try check(c.unlinkat(std.posix.AT.FDCWD, path, 0));
}

pub fn renameZ(from: [*:0]const u8, to: [*:0]const u8) !void {
    _ = try check(c.renameat(std.posix.AT.FDCWD, from, std.posix.AT.FDCWD, to));
}

pub fn random(bytes: []u8) !void {
    const libc = struct {
        extern "c" fn getentropy(?*anyopaque, usize) c_int;
    };
    std.debug.assert(bytes.len <= 256);
    _ = try check(libc.getentropy(bytes.ptr, bytes.len));
}
