//! Supervisor diagnostics and portable login I/O.
const std = @import("std");
const io = @import("platform").login_io;

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

pub const check = io.check;
pub const retry = io.retry;
pub const close = io.close;
pub const writeAll = io.writeAll;
pub const readAll = io.readAll;
pub const monotonicMs = io.monotonicMs;
pub const errnoError = io.errnoError;
pub const openZ = io.openZ;
pub const unlinkZ = io.unlinkZ;
pub const renameZ = io.renameZ;
pub const random = io.random;
