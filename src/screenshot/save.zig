//! Publish only complete PNGs: file browsers may inspect a path at IN_CREATE.
//! All I/O runs on the capture worker, never on the compositor event loop.
const std = @import("std");
const c = @cImport({
    // Match files/c.zig: Zig 0.16 cannot translate fortified libc wrappers.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
});

pub fn writePngFile(path: []const u8, bytes: []const u8) !void {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidPng;
    var path_buf: [4096]u8 = undefined;
    const destination = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    var temporary_buf: [4096]u8 = undefined;
    const temporary = try std.fmt.bufPrintZ(&temporary_buf, "{s}/.rediwm-screenshot-XXXXXX", .{std.fs.path.dirname(path) orelse "."});
    const fd = c.mkostemp(temporary.ptr, c.O_CLOEXEC);
    if (fd < 0) return error.CreateFailed;
    var closed = false;
    defer if (!closed) {
        _ = c.close(fd);
    };
    defer _ = c.unlink(temporary.ptr);

    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
    while (c.fsync(fd) != 0) {
        if (std.posix.errno(@as(c_int, -1)) != .INTR) return error.SyncFailed;
    }
    // close() must not be retried on Linux, even after EINTR.
    const close_result = c.close(fd);
    closed = true;
    if (close_result != 0) return error.CloseFailed;
    // NOREPLACE retains the IPC's no-overwrite guarantee, including symlinks
    // and another writer winning the race after queueRequest checked the path.
    if (c.renameat2(c.AT_FDCWD, temporary.ptr, c.AT_FDCWD, destination.ptr, c.RENAME_NOREPLACE) != 0) return error.PublishFailed;
}
