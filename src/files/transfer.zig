//! Nonblocking, bounded clipboard pipes. Progress comes from the Wayland poll loop.
const std = @import("std");
const c = @import("c.zig").api;
const a = std.heap.c_allocator;
pub const limit = 1024 * 1024;
pub const timeout_ms = 10000;

pub const Receive = struct {
    fd: c_int,
    text: bool,
    revision: usize,
    directory: []u8,
    started: i64,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Receive) void {
        _ = c.close(self.fd);
        a.free(self.directory);
        self.bytes.deinit(a);
    }
    pub fn read(self: *Receive) !bool {
        var buf: [65536]u8 = undefined;
        // One chunk per event-loop iteration keeps large offers fair to input.
        while (true) {
            const n = c.read(self.fd, &buf, buf.len);
            if (n == 0) return true;
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return false,
                else => return error.ReadFailed,
            };
            if (self.bytes.items.len + @as(usize, @intCast(n)) > limit) return error.TooLarge;
            try self.bytes.appendSlice(a, buf[0..@intCast(n)]);
            return false;
        }
    }
};

pub const Send = struct {
    fd: c_int,
    bytes: []u8,
    offset: usize = 0,
    started: i64,
    pub fn init(fd: c_int, bytes: []const u8, now: i64) !Send {
        errdefer _ = c.close(fd);
        if (bytes.len > limit) return error.TooLarge;
        const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.NonblockingFailed;
        return .{ .fd = fd, .bytes = try a.dupe(u8, bytes), .started = now };
    }
    pub fn deinit(self: *Send) void {
        _ = c.close(self.fd);
        a.free(self.bytes);
    }
    pub fn write(self: *Send) !bool {
        if (self.offset == self.bytes.len) return true;
        while (true) {
            const n = c.write(self.fd, self.bytes.ptr + self.offset, @min(65536, self.bytes.len - self.offset));
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return false,
                else => return error.WriteFailed,
            };
            if (n == 0) return error.WriteFailed;
            self.offset += @intCast(n);
            return self.offset == self.bytes.len;
        }
    }
};
