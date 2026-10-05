//! Nonblocking polkit helper transport. Callbacks borrow text until return and
//! may respond/cancel, but must not destroy this object or dispatch the loop.
const std = @import("std");
const wl = @import("wayland").server.wl;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});
const Child = @import("../session/child.zig");
extern fn rediwm_polkit_spawn([*:0]const u8, *std.posix.pid_t) c_int;
extern fn rediwm_polkit_secret_new() ?*anyopaque;
extern fn rediwm_polkit_secret_free(*anyopaque) void;
extern fn rediwm_polkit_clear(*anyopaque, usize) void;
pub const default_socket = "/run/polkit/agent-helper.socket";
// fgets(512) needs room for both the newline and the terminating NUL.
pub const max_response = 510;
const max_line = 8192;
pub const Event = union(enum) {
    prompt_hidden: []const u8,
    prompt_visible: []const u8,
    info: []const u8,
    error_message: []const u8,
    success,
    failure,
    cancelled, // Agent-side cancellation, also delivered to prompt consumers.
    transport_error: anyerror,
};
pub const Options = struct {
    socket_path: []const u8 = default_socket,
    allow_spawn: bool = true,
};

pub const Helper = struct {
    allocator: std.mem.Allocator,
    fd: c_int = -1,
    child: ?*Child = null,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    secret: *[512]u8,
    owner: ?*anyopaque,
    callback: *const fn (?*anyopaque, *Helper, Event) void,
    initial: [4352]u8 = @splat(0),
    initial_len: usize = 0,
    initial_offset: usize = 0,
    response_len: usize = 0,
    response_offset: usize = 0,
    line: [max_line]u8 = undefined,
    line_len: usize = 0,
    connecting: bool = false,
    awaiting_response: bool = false,
    finished: bool = false,

    pub fn create(allocator: std.mem.Allocator, loop: *wl.EventLoop, options: Options, username: []const u8, cookie: []const u8, owner: ?*anyopaque, callback: @FieldType(Helper, "callback")) !*Helper {
        if (username.len == 0 or username.len > 255 or cookie.len == 0 or cookie.len > 4095) return error.InvalidHandshake;
        try validateLine(username);
        try validateLine(cookie);
        const secret: *[512]u8 = @ptrCast(rediwm_polkit_secret_new() orelse return error.SecretMemoryUnavailable);
        errdefer rediwm_polkit_secret_free(secret);
        const self = try allocator.create(Helper);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .secret = secret, .owner = owner, .callback = callback };
        errdefer self.cancel();
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        if (options.socket_path.len == 0 or options.socket_path.len >= addr.sun_path.len or std.mem.indexOfScalar(u8, options.socket_path, 0) != null) return error.InvalidSocketPath;
        addr.sun_family = c.AF_UNIX;
        @memcpy(@as([*]u8, @ptrCast(&addr.sun_path))[0..options.socket_path.len], options.socket_path);
        self.fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (self.fd < 0) return error.SocketFailed;
        var spawned = false;
        if (c.connect(self.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) {
            switch (std.posix.errno(@as(c_int, -1))) {
                .INPROGRESS => self.connecting = true,
                .NOENT, .CONNREFUSED => {
                    if (!options.allow_spawn) return error.HelperUnavailable;
                    _ = c.close(self.fd);
                    self.fd = -1;
                    var user: [256:0]u8 = @splat(0);
                    @memcpy(user[0..username.len], username);
                    var pid: std.posix.pid_t = 0;
                    self.fd = rediwm_polkit_spawn(&user, &pid);
                    if (self.fd < 0) return error.HelperUnavailable;
                    self.child = Child.watch(allocator, loop, pid, self, childExited) catch |err| {
                        _ = std.os.linux.kill(pid, .KILL);
                        var status: u32 = 0;
                        while (std.os.linux.errno(std.os.linux.wait4(pid, &status, 0, null)) == .INTR) {}
                        return err;
                    };
                    spawned = true;
                },
                else => return error.ConnectFailed,
            }
        }
        const initial = if (spawned) try std.fmt.bufPrint(&self.initial, "{s}\n", .{cookie}) else try std.fmt.bufPrint(&self.initial, "{s}\n{s}\n", .{ username, cookie });
        self.initial_len = initial.len;
        self.source = try loop.addFd(*Helper, self.fd, .{ .readable = true, .writable = true }, onFd, self);
        self.timer = try loop.addTimer(*Helper, onTimeout, self);
        try self.timer.?.timerUpdate(5000);
        return self;
    }
    fn childExited(owner: ?*anyopaque, _: *Child, _: ?u32) void {
        const self: *Helper = @ptrCast(@alignCast(owner.?));
        self.child = null;
    }

    pub fn destroy(self: *Helper) void {
        self.cancel();
        rediwm_polkit_secret_free(self.secret);
        self.allocator.destroy(self);
    }
    /// Cancels silently; the owner decides what to tell its D-Bus caller.
    pub fn cancel(self: *Helper) void {
        self.finished = true;
        self.awaiting_response = false;
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.timer) |timer| timer.remove();
        self.timer = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.child) |child| {
            child.signal(.KILL);
            child.detach();
        }
        self.child = null;
        self.clearResponse();
        rediwm_polkit_clear(&self.initial, self.initial.len);
        rediwm_polkit_clear(&self.line, self.line.len);
        self.initial_len = 0;
        self.initial_offset = 0;
        self.line_len = 0;
    }
    fn clearResponse(self: *Helper) void {
        rediwm_polkit_clear(self.secret, self.secret.len);
        self.response_len = 0;
        self.response_offset = 0;
    }
    pub fn respond(self: *Helper, response: []const u8) !void {
        if (self.finished or !self.awaiting_response or self.response_len != 0) return error.NoPrompt;
        if (response.len > max_response) return error.ResponseTooLong;
        try validateLine(response);
        @memcpy(self.secret[0..response.len], response);
        self.secret[response.len] = '\n';
        self.response_len = response.len + 1;
        errdefer self.clearResponse();
        try self.timer.?.timerUpdate(5000);
        try self.source.?.fdUpdate(.{ .readable = true, .writable = true });
        self.awaiting_response = false;
    }
    fn finish(self: *Helper, event: Event) void {
        if (self.finished) return;
        self.cancel();
        self.callback(self.owner, self, event);
    }
    fn onTimeout(self: *Helper) c_int {
        self.finish(.{ .transport_error = error.WriteTimeout });
        return 0;
    }
    fn write(self: *Helper) !void {
        const initial = self.initial_offset < self.initial_len;
        const data = if (initial) self.initial[self.initial_offset..self.initial_len] else self.secret[self.response_offset..self.response_len];
        if (data.len > 0) {
            const n = c.send(self.fd, data.ptr, data.len, c.MSG_NOSIGNAL);
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err == .AGAIN or err == .INTR) return;
                return error.WriteFailed;
            }
            if (n == 0) return error.HelperClosed;
            if (initial) {
                self.initial_offset += @intCast(n);
                if (self.initial_offset == self.initial_len) {
                    rediwm_polkit_clear(&self.initial, self.initial.len);
                    self.initial_len = 0;
                    self.initial_offset = 0;
                }
            } else {
                // Erase even partially transmitted responses immediately.
                rediwm_polkit_clear(self.secret[self.response_offset..].ptr, @intCast(n));
                self.response_offset += @intCast(n);
                if (self.response_offset == self.response_len) self.clearResponse();
            }
        }
        if (self.initial_len == 0 and self.response_len == 0) {
            try self.source.?.fdUpdate(.{ .readable = true });
            try self.timer.?.timerUpdate(0); // Human/PAM wait has no artificial timeout.
        }
    }
    fn onFd(_: c_int, mask: wl.EventMask, self: *Helper) c_int {
        self.handleFd(mask) catch |err| self.finish(.{ .transport_error = err });
        return 0;
    }
    fn handleFd(self: *Helper, mask: wl.EventMask) !void {
        if (self.connecting) {
            var socket_error: c_int = 0;
            var size: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(self.fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &size) < 0 or socket_error != 0) return error.ConnectFailed;
            self.connecting = false;
        }
        if (mask.writable) try self.write();
        if (mask.readable or mask.hangup) {
            // One read per dispatch bounds work. Drain HUP data before treating
            // EOF as failure (SUCCESS and HUP commonly arrive together).
            var bytes: [4096]u8 = undefined;
            defer rediwm_polkit_clear(&bytes, bytes.len);
            const n = c.read(self.fd, &bytes, bytes.len);
            if (n == 0) return error.HelperClosed;
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err != .AGAIN and err != .INTR) return error.ReadFailed;
            } else try self.feed(bytes[0..@intCast(n)]);
        }
        if (!self.finished and mask.@"error") return error.ReadFailed;
    }
    fn feed(self: *Helper, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (self.finished) return;
            if (byte == '\n') {
                const len = self.line_len;
                self.line_len = 0;
                try self.lineReceived(self.line[0..len]);
            } else {
                if (self.line_len == self.line.len) return error.LineTooLong;
                self.line[self.line_len] = byte;
                self.line_len += 1;
            }
        }
    }
    fn lineReceived(self: *Helper, line: []const u8) !void {
        if (std.mem.eql(u8, line, "SUCCESS")) return self.finish(.success);
        if (std.mem.eql(u8, line, "FAILURE")) return self.finish(.failure);
        inline for (.{
            .{ "PAM_PROMPT_ECHO_OFF ", "prompt_hidden" },
            .{ "PAM_PROMPT_ECHO_ON ", "prompt_visible" },
            .{ "PAM_TEXT_INFO ", "info" },
            .{ "PAM_ERROR_MSG ", "error_message" },
        }) |pair| {
            if (std.mem.startsWith(u8, line, pair[0])) {
                var decoded: [max_line]u8 = undefined;
                defer rediwm_polkit_clear(&decoded, decoded.len);
                const text = try unescape(line[pair[0].len..], &decoded);
                if (comptime std.mem.startsWith(u8, pair[1], "prompt")) {
                    if (self.awaiting_response or self.response_len != 0 or self.initial_len != 0) return error.UnexpectedPrompt;
                    self.awaiting_response = true;
                }
                self.callback(self.owner, self, @unionInit(Event, pair[1], text));
                return;
            }
        }
        return error.InvalidHelperLine;
    }
};

fn validateLine(bytes: []const u8) !void {
    if (std.mem.indexOfAny(u8, bytes, "\r\n\x00") != null) return error.InvalidLine;
}
pub fn unescape(input: []const u8, output: []u8) ![]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len) {
        var byte = input[i];
        i += 1;
        if (byte == '\\') {
            if (i == input.len) return error.InvalidEscape;
            byte = input[i];
            i += 1;
            byte = switch (byte) {
                'b' => 8,
                'f' => 12,
                'n' => 10,
                'r' => 13,
                't' => 9,
                'v' => 11,
                '\\', '"' => byte,
                '0'...'7' => blk: {
                    var value: u16 = byte - '0';
                    var digits: usize = 1;
                    while (digits < 3 and i < input.len and input[i] >= '0' and input[i] <= '7') : (digits += 1) {
                        value = value * 8 + input[i] - '0';
                        i += 1;
                    }
                    if (value > 255) return error.InvalidEscape;
                    break :blk @intCast(value);
                },
                else => return error.InvalidEscape,
            };
        }
        if (byte == 0) return error.InvalidEscape;
        if (n == output.len) return error.LineTooLong;
        output[n] = byte;
        n += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output[0..n])) return error.InvalidText;
    return output[0..n];
}

test "helper unescapes GLib controls, octal UTF-8 and rejects malformed escapes" {
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings("\x08\x0c\n\r\t\x0b\\\" café", try unescape("\\b\\f\\n\\r\\t\\v\\\\\\\" caf\\303\\251", &buf));
    for ([_][]const u8{ "trailing\\", "\\q", "\\777", "\\000" }) |bad| try std.testing.expectError(error.InvalidEscape, unescape(bad, &buf));
    try std.testing.expectError(error.InvalidText, unescape("\\377", &buf));
}

const TestEvents = struct {
    prompts: usize = 0,
    infos: usize = 0,
    errors: usize = 0,
    successes: usize = 0,
    failures: usize = 0,
    automatic: bool = true,
    bad: bool = false,
    fn event(owner: ?*anyopaque, helper: *Helper, ev: Event) void {
        const self: *TestEvents = @ptrCast(@alignCast(owner.?));
        switch (ev) {
            .prompt_hidden, .prompt_visible => |text| {
                self.prompts += 1;
                if (!std.mem.eql(u8, text, "Password: é")) self.bad = true;
                if (self.automatic) helper.respond("test-response") catch {
                    self.bad = true;
                };
            },
            .info => |text| {
                self.infos += 1;
                if (!std.mem.eql(u8, text, "one\ntwo")) self.bad = true;
            },
            .error_message => self.errors += 1,
            .success => self.successes += 1,
            .failure, .transport_error, .cancelled => self.failures += 1,
        }
    }
};

test "socketpair helper frames split/coalesced reads and wipes sent responses" {
    const display = try wl.Server.create();
    defer display.destroy();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0, &fds));
    defer _ = c.close(fds[1]);
    const secret: *[512]u8 = @ptrCast(rediwm_polkit_secret_new() orelse return error.SecretMemoryUnavailable);
    defer rediwm_polkit_secret_free(secret);
    var events: TestEvents = .{};
    var helper: Helper = .{ .allocator = std.testing.allocator, .fd = fds[0], .secret = secret, .owner = &events, .callback = TestEvents.event };
    defer helper.cancel();
    const loop = display.getEventLoop();
    helper.source = try loop.addFd(*Helper, helper.fd, .{ .readable = true }, Helper.onFd, &helper);
    helper.timer = try loop.addTimer(*Helper, Helper.onTimeout, &helper);
    const first = "PAM_PROMPT_ECHO_OFF Pass\\";
    try std.testing.expectEqual(@as(isize, first.len), c.send(fds[1], first.ptr, first.len, c.MSG_NOSIGNAL));
    try loop.dispatch(100);
    try std.testing.expectEqual(0, events.prompts);
    const second = "167ord: \\303\\251\n";
    try std.testing.expectEqual(@as(isize, second.len), c.send(fds[1], second.ptr, second.len, c.MSG_NOSIGNAL));
    try loop.dispatch(100);
    try std.testing.expectEqual(1, events.prompts);
    try loop.dispatch(100); // Newly writable response, queued by the prompt.
    var response: [512]u8 = undefined;
    const n = c.read(fds[1], &response, response.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("test-response\n", response[0..@intCast(n)]);
    try std.testing.expect(std.mem.allEqual(u8, secret, 0));
    // Maximum accepted response includes its newline in a single fgets buffer.
    events.automatic = false;
    helper.awaiting_response = true;
    const maximum = [_]u8{'x'} ** max_response;
    try helper.respond(&maximum);
    try loop.dispatch(100);
    const maximum_n = c.read(fds[1], &response, response.len);
    try std.testing.expectEqual(@as(isize, max_response + 1), maximum_n);
    try std.testing.expectEqualStrings(&maximum, response[0..max_response]);
    try std.testing.expectEqual('\n', response[max_response]);
    try std.testing.expect(std.mem.allEqual(u8, secret, 0));
    const rest = "PAM_TEXT_INFO one\\ntwo\nPAM_ERROR_MSG wrong\nSUCCESS\n";
    try std.testing.expectEqual(@as(isize, rest.len), c.send(fds[1], rest.ptr, rest.len, c.MSG_NOSIGNAL));
    _ = c.shutdown(fds[1], c.SHUT_WR);
    try loop.dispatch(100);
    try std.testing.expectEqual(1, events.infos);
    try std.testing.expectEqual(1, events.errors);
    try std.testing.expectEqual(1, events.successes);
    try std.testing.expectEqual(0, events.failures);
    try std.testing.expect(!events.bad and helper.finished);
    try std.testing.expect(std.mem.allEqual(u8, secret, 0));
    try std.testing.expectError(error.NoPrompt, helper.respond("late"));
}

test "helper bounds responses before copying and wipes every terminal path" {
    const display = try wl.Server.create();
    defer display.destroy();
    const secret: *[512]u8 = @ptrCast(rediwm_polkit_secret_new() orelse return error.SecretMemoryUnavailable);
    defer rediwm_polkit_secret_free(secret);
    var events: TestEvents = .{ .automatic = false };
    var helper: Helper = .{ .allocator = std.testing.allocator, .secret = secret, .owner = &events, .callback = TestEvents.event };
    defer helper.cancel();
    // Rejected input never needs an event source and never reaches the buffer.
    helper.awaiting_response = true;
    const oversized = [_]u8{'x'} ** 511;
    try std.testing.expectError(error.ResponseTooLong, helper.respond(&oversized));
    for ([_][]const u8{ "a\nb", "a\rb", "a\x00b" }) |bad| try std.testing.expectError(error.InvalidLine, helper.respond(bad));
    try std.testing.expect(std.mem.allEqual(u8, secret, 0));
    // EOF, protocol error, explicit failure, timeout and cancellation all share
    // the same erasure path, even when bytes are queued and not yet written.
    const endings = [_]Event{ .success, .failure, .{ .transport_error = error.HelperClosed }, .{ .transport_error = error.InvalidHelperLine }, .{ .transport_error = error.WriteTimeout } };
    for (endings) |event| {
        helper.finished = false;
        @memset(secret, 'x');
        helper.response_len = 511;
        helper.finish(event);
        try std.testing.expect(std.mem.allEqual(u8, secret, 0));
        try std.testing.expectEqual(0, helper.response_len);
    }
    helper.finished = false;
    @memset(secret, 'x');
    helper.cancel();
    try std.testing.expect(std.mem.allEqual(u8, secret, 0));
    helper.finished = false;
    try std.testing.expectError(error.InvalidHelperLine, helper.feed("SUCCESSx\n"));
    const huge = [_]u8{'x'} ** (max_line + 1);
    try std.testing.expectError(error.LineTooLong, helper.feed(&huge));
}

test "helper preserves a backpressured response until cancellation erases it" {
    const display = try wl.Server.create();
    defer display.destroy();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0, &fds));
    defer _ = c.close(fds[1]);
    const secret: *[512]u8 = @ptrCast(rediwm_polkit_secret_new() orelse return error.SecretMemoryUnavailable);
    defer rediwm_polkit_secret_free(secret);
    var events: TestEvents = .{};
    var helper: Helper = .{ .allocator = std.testing.allocator, .fd = fds[0], .secret = secret, .owner = &events, .callback = TestEvents.event, .awaiting_response = true };
    defer helper.cancel();
    const loop = display.getEventLoop();
    helper.source = try loop.addFd(*Helper, helper.fd, .{ .readable = true }, Helper.onFd, &helper);
    helper.timer = try loop.addTimer(*Helper, Helper.onTimeout, &helper);
    const size: c_int = 4096;
    try std.testing.expectEqual(0, c.setsockopt(helper.fd, c.SOL_SOCKET, c.SO_SNDBUF, &size, @sizeOf(c_int)));
    const padding = [_]u8{0} ** 4096;
    var full = false;
    for (0..16) |_| {
        const n = c.send(helper.fd, &padding, padding.len, c.MSG_NOSIGNAL);
        if (n < 0) {
            try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(n));
            full = true;
            break;
        }
    }
    try std.testing.expect(full);
    try helper.respond("pending-secret");
    try helper.write();
    try std.testing.expectEqualStrings("pending-secret\n", secret[0..helper.response_len]);
    helper.cancel();
    try std.testing.expect(std.mem.allEqual(u8, secret, 0));
}
