//! Selected-page-only, event-driven helper lifetime. A single request is in
//! flight: no refresh can overtake an action, and idle has no timer or worker.
const std = @import("std");
const wl = @import("wayland").server.wl;
const c = @import("c");
const platform = @import("platform");
const Child = @import("../session/child.zig");
const keys = @import("keys");
const secure = @import("../network/secure_allocator.zig").allocator;
const a = std.heap.c_allocator;

pub const Client = struct {
    io: std.Io,
    loop: *wl.EventLoop,
    owner: *anyopaque,
    changed: *const fn (*anyopaque) void,
    child: ?*Child = null,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    fd: c_int = -1,
    bytes: std.ArrayList(u8) = .empty,
    current: ?std.json.Parsed(keys.protocol.Reply) = null,
    busy: bool = false,
    failure: bool = false,
    timed_out: bool = false,

    pub fn create(io: std.Io, loop: *wl.EventLoop, owner: *anyopaque, changed: *const fn (*anyopaque) void) !*Client {
        const self = try a.create(Client);
        self.* = .{ .io = io, .loop = loop, .owner = owner, .changed = changed };
        errdefer self.destroy();
        try self.act(.{});
        return self;
    }
    pub fn destroy(self: *Client) void {
        self.cancel();
        if (self.current) |*value| value.deinit();
        self.bytes.deinit(a);
        a.destroy(self);
    }
    pub fn cancel(self: *Client) void {
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.timer) |timer| timer.remove();
        self.timer = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.child) |child| {
            // The watch kills the process group before reaping its leader.
            child.signal(.KILL);
            child.detach();
        }
        self.child = null;
        self.busy = false;
    }
    pub fn act(self: *Client, req: keys.protocol.Request) !void {
        if (self.busy) return error.Busy;
        const bytes = try std.json.Stringify.valueAlloc(secure, req, .{});
        defer secure.free(bytes);
        if (bytes.len > 16383) return error.RequestTooLarge;
        var sockets: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets) != 0) return error.PipeFailed;
        defer {
            _ = c.close(sockets[0]);
            _ = c.close(sockets[1]);
        }
        var path_buf: [4096]u8 = undefined;
        const executable = platform.exe.sibling(&path_buf, "rediwm-keys") orelse return error.NoExecutable;
        var process = try std.process.spawn(self.io, .{
            .argv = &.{ executable, if (req.action == .scan) "scan" else "op" },
            .stdin = .{ .file = .{ .handle = sockets[0], .flags = .{ .nonblocking = false } } },
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        errdefer process.kill(self.io);
        errdefer self.cancel();
        self.fd = process.stdout.?.handle;
        process.stdout = null;
        const flags = c.fcntl(self.fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(self.fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.PipeFailed;
        self.source = try self.loop.addFd(*Client, self.fd, .{ .readable = true }, readable, self);
        self.timer = try self.loop.addTimer(*Client, timeout, self);
        try self.timer.?.timerUpdate(45000);
        self.child = try Child.watch(a, self.loop, process.id.?, self, exited);
        self.child.?.kill_group = true;
        process.id = null;
        const sent = c.send(sockets[1], bytes.ptr, bytes.len, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
        if (sent != bytes.len or c.shutdown(sockets[1], c.SHUT_WR) != 0) return error.RequestWriteFailed;
        self.bytes.clearRetainingCapacity();
        self.failure = false;
        self.timed_out = false;
        self.busy = true;
    }
    fn drain(self: *Client) void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &buffer, buffer.len);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0 and std.posix.errno(n) == .AGAIN) return;
            if (n < 0) self.failure = true;
            if (n <= 0) {
                if (self.source) |source| source.remove();
                self.source = null;
                return;
            }
            const count: usize = @intCast(n);
            if (self.bytes.items.len + count > keys.model.max_reply) {
                self.failure = true;
                self.child.?.signal(.KILL);
                return;
            }
            self.bytes.appendSlice(a, buffer[0..count]) catch {
                self.failure = true;
                self.child.?.signal(.KILL);
                return;
            };
        }
    }
    fn readable(_: c_int, _: wl.EventMask, self: *Client) c_int {
        self.drain();
        return 0;
    }
    fn timeout(self: *Client) c_int {
        self.timed_out = true;
        self.failure = true;
        if (self.child) |child| child.signal(.KILL);
        return 0;
    }
    fn exited(raw: ?*anyopaque, _: *Child, status: ?u32) void {
        const self: *Client = @ptrCast(@alignCast(raw.?));
        self.drain();
        self.child = null;
        self.cancel();
        if (status == null or status.? != 0) self.failure = true;
        if (!self.failure) {
            const next = std.json.parseFromSlice(keys.protocol.Reply, a, self.bytes.items, .{ .allocate = .alloc_always, .max_value_len = 65536 }) catch null;
            if (next) |value| {
                if (self.current) |*previous| previous.deinit();
                self.current = value;
            } else self.failure = true;
        }
        self.changed(self.owner);
    }
};
