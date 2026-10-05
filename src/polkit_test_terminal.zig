//! Manual Stage 3 driver only, never linked into the compositor. Input is read
//! directly into locked memory; no password in argv, environment or log output.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Agent = @import("polkit/agent.zig").Agent;
const helper = @import("polkit/helper.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
});
extern fn rediwm_polkit_secret_new() ?*anyopaque;
extern fn rediwm_polkit_secret_free(*anyopaque) void;
extern fn rediwm_polkit_clear(*anyopaque, usize) void;

pub const Terminal = struct {
    fd: c_int,
    saved: c.struct_termios,
    secret: *[512]u8,
    len: usize = 0,
    waiting: bool = false,
    source: ?*wl.EventSource = null,
    agent: *Agent,
    stop: *bool,

    pub fn create(loop: *wl.EventLoop, agent: *Agent, stop: *bool) !*Terminal {
        const fd = c.open("/dev/tty", c.O_RDWR | c.O_NONBLOCK | c.O_CLOEXEC);
        if (fd < 0) return error.NoTerminal;
        errdefer _ = c.close(fd);
        var saved: c.struct_termios = undefined;
        if (c.tcgetattr(fd, &saved) != 0) return error.NoTerminal;
        const secret: *[512]u8 = @ptrCast(rediwm_polkit_secret_new() orelse return error.SecretMemoryUnavailable);
        errdefer rediwm_polkit_secret_free(secret);
        const self = try std.heap.c_allocator.create(Terminal);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = .{ .fd = fd, .saved = saved, .secret = secret, .agent = agent, .stop = stop };
        self.source = try loop.addFd(*Terminal, fd, .{ .readable = true }, input, self);
        agent.conversation = .{ .owner = self, .event = event };
        self.print("Waiting for an authentication request. Ctrl-C cancels.\n");
        return self;
    }
    fn print(self: *Terminal, text: []const u8) void {
        _ = c.write(self.fd, text.ptr, text.len);
    }
    fn restore(self: *Terminal) void {
        _ = c.tcsetattr(self.fd, c.TCSANOW, &self.saved);
        self.waiting = false;
        rediwm_polkit_clear(self.secret, self.secret.len);
        self.len = 0;
    }
    pub fn destroy(self: *Terminal) void {
        self.agent.conversation = null;
        self.restore();
        self.source.?.remove();
        _ = c.close(self.fd);
        rediwm_polkit_secret_free(self.secret);
        std.heap.c_allocator.destroy(self);
    }
    fn event(owner: ?*anyopaque, agent: *Agent, ev: helper.Event) void {
        const self: *Terminal = @ptrCast(@alignCast(owner.?));
        switch (ev) {
            .prompt_hidden, .prompt_visible => |text| {
                self.restore();
                _ = c.tcflush(self.fd, c.TCIFLUSH);
                var mode = self.saved;
                // Even echo-on responses are hidden by this manual driver.
                mode.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ECHONL);
                mode.c_lflag |= c.ICANON;
                if (c.tcsetattr(self.fd, c.TCSANOW, &mode) != 0) return agent.cancel();
                self.waiting = true;
                self.print(text);
            },
            .info, .error_message => |text| {
                self.print(text);
                self.print("\n");
            },
            else => {
                self.restore();
                self.print(if (ev == .success) "\nAuthentication succeeded.\n" else "\nAuthentication ended without success.\n");
                self.stop.* = true;
            },
        }
    }
    fn input(_: c_int, _: wl.EventMask, self: *Terminal) c_int {
        if (!self.waiting) {
            _ = c.tcflush(self.fd, c.TCIFLUSH);
            return 0;
        }
        const n = c.read(self.fd, self.secret[self.len..].ptr, self.secret.len - self.len);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err != .AGAIN and err != .INTR) self.agent.cancel();
            return 0;
        }
        if (n == 0) {
            self.agent.cancel();
            return 0;
        }
        self.len += @intCast(n);
        if (std.mem.indexOfScalar(u8, self.secret[0..self.len], '\n')) |end| {
            self.agent.respond(self.secret[0..end]) catch self.agent.cancel();
            self.restore();
            self.print("\n");
        } else if (self.len == self.secret.len) {
            _ = c.tcflush(self.fd, c.TCIFLUSH);
            self.agent.cancel();
        }
        return 0;
    }
};
