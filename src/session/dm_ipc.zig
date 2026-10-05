//! rediwm-dm IPC protocol codec and client. Each message is a native-endian
//! u32 length followed by JSON; the daemon answers every request with exactly
//! one response. Requests that carry a secret are encoded into a caller-owned
//! buffer that is wiped after sending, so no heap copy of a password ever exists.
const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

/// Protocol frames are small; anything larger is a protocol violation.
pub const max_frame = 64 * 1024;
/// A 511-byte password escapes to at most ~3 KiB of JSON.
pub const request_capacity = 8 * 1024;

pub const Request = union(enum) {
    login: []const u8,
    /// null answers info/error messages, which carry no response.
    answer: ?[]const u8,
    start: []const u8,
    cancel,
};

pub const MessageKind = enum { visible, secret, info, @"error" };

pub const Response = union(enum) {
    ok,
    question: struct { kind: MessageKind, text: []const u8 },
    /// Wrong credentials; the conversation is over.
    denied: []const u8,
    failed: []const u8,
};

const ResponseWire = struct {
    type: []const u8,
    kind: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub const ParsedResponse = struct {
    arena: std.json.Parsed(ResponseWire),
    response: Response,

    pub fn deinit(self: *ParsedResponse) void {
        self.arena.deinit();
    }
};

pub const Parsed = ParsedResponse;

pub fn parseResponse(allocator: std.mem.Allocator, payload: []const u8) !ParsedResponse {
    var wire = try std.json.parseFromSlice(ResponseWire, allocator, payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer wire.deinit();
    const v = wire.value;
    const response: Response = if (std.mem.eql(u8, v.type, "ok"))
        .ok
    else if (std.mem.eql(u8, v.type, "question"))
        .{ .question = .{
            .kind = std.meta.stringToEnum(MessageKind, v.kind orelse "") orelse return error.InvalidResponse,
            .text = v.text orelse "",
        } }
    else if (std.mem.eql(u8, v.type, "denied"))
        .{ .denied = v.text orelse "" }
    else if (std.mem.eql(u8, v.type, "failed"))
        .{ .failed = v.text orelse "" }
    else
        return error.InvalidResponse;
    return .{ .arena = wire, .response = response };
}

pub const parse = parseResponse;

/// Encodes one framed request into `out`. The result aliases `out`.
pub fn encodeRequest(out: []u8, request: Request) ![]u8 {
    if (out.len < 4) return error.NoSpaceLeft;
    var w: std.Io.Writer = .fixed(out[4..]);
    switch (request) {
        .login => |user| try std.json.Stringify.value(.{ .type = "login", .user = user }, .{}, &w),
        .answer => |ans| try std.json.Stringify.value(.{ .type = "answer", .response = ans }, .{}, &w),
        .start => |session| try std.json.Stringify.value(.{ .type = "start", .session = session }, .{}, &w),
        .cancel => try std.json.Stringify.value(.{ .type = "cancel" }, .{}, &w),
    }
    const n = w.end;
    std.mem.writeInt(u32, out[0..4], @intCast(n), @import("builtin").cpu.arch.endian());
    return out[0 .. n + 4];
}

pub const encode = encodeRequest;

const RequestWire = struct {
    type: []const u8,
    user: ?[]const u8 = null,
    response: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

pub const ParsedRequest = struct {
    arena: std.json.Parsed(RequestWire),
    request: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, payload: []const u8) !ParsedRequest {
    var wire = try std.json.parseFromSlice(RequestWire, allocator, payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer wire.deinit();
    const v = wire.value;
    const request: Request = if (std.mem.eql(u8, v.type, "login"))
        .{ .login = v.user orelse return error.InvalidRequest }
    else if (std.mem.eql(u8, v.type, "answer"))
        .{ .answer = v.response }
    else if (std.mem.eql(u8, v.type, "start"))
        .{ .start = v.session orelse return error.InvalidRequest }
    else if (std.mem.eql(u8, v.type, "cancel"))
        .cancel
    else
        return error.InvalidRequest;
    return .{ .arena = wire, .request = request };
}

/// Encodes one framed response into `out`. The result aliases `out`.
pub fn encodeResponse(out: []u8, response: Response) ![]u8 {
    if (out.len < 4) return error.NoSpaceLeft;
    var w: std.Io.Writer = .fixed(out[4..]);
    switch (response) {
        .ok => try std.json.Stringify.value(.{ .type = "ok" }, .{}, &w),
        .question => |q| try std.json.Stringify.value(.{ .type = "question", .kind = @tagName(q.kind), .text = q.text }, .{}, &w),
        .denied => |text| try std.json.Stringify.value(.{ .type = "denied", .text = text }, .{}, &w),
        .failed => |text| try std.json.Stringify.value(.{ .type = "failed", .text = text }, .{}, &w),
    }
    const n = w.end;
    std.mem.writeInt(u32, out[0..4], @intCast(n), @import("builtin").cpu.arch.endian());
    return out[0 .. n + 4];
}

pub const Client = struct {
    fd: c_int,
    buf: [max_frame + 4]u8 = undefined,
    len: usize = 0,

    pub fn fromFd(fd: c_int) Client {
        return .{ .fd = fd };
    }

    pub fn close(self: *Client) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        self.len = 0;
    }

    /// Sends a request. The encoded bytes, which may hold a secret, are
    /// wiped before returning.
    pub fn send(self: *Client, request: Request) !void {
        var out: [request_capacity]u8 = undefined;
        defer std.crypto.secureZero(u8, &out);
        const bytes = try encodeRequest(&out, request);
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, c.MSG_NOSIGNAL);
            if (n < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.WriteFailed;
            }
            sent += @intCast(n);
        }
    }

    /// Reads whatever is available without blocking. Returns
    /// error.Disconnected at end of stream.
    pub fn fill(self: *Client) !void {
        while (self.len < self.buf.len) {
            const n = c.recv(self.fd, self.buf[self.len..].ptr, self.buf.len - self.len, c.MSG_DONTWAIT);
            if (n == 0) return error.Disconnected;
            if (n < 0) {
                const err = std.c._errno().*;
                if (err == c.EINTR) continue;
                if (err == c.EAGAIN or err == c.EWOULDBLOCK) return;
                if (err == c.ECONNRESET) return error.Disconnected;
                return error.ReadFailed;
            }
            self.len += @intCast(n);
        }
    }

    /// The next complete frame's payload, valid until `consume`.
    pub fn frame(self: *Client) !?[]const u8 {
        if (self.len < 4) return null;
        const n = std.mem.readInt(u32, self.buf[0..4], @import("builtin").cpu.arch.endian());
        if (n > max_frame) return error.FrameTooLarge;
        if (self.len < 4 + n) return null;
        return self.buf[4..][0..n];
    }

    /// Drops the frame `frame` returned. The vacated bytes are wiped: in the
    /// daemon they held a password.
    pub fn consume(self: *Client, payload: []const u8) void {
        const used = 4 + payload.len;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - used], self.buf[used..self.len]);
        std.crypto.secureZero(u8, self.buf[self.len - used .. self.len]);
        self.len -= used;
    }
};

test "dm requests are framed JSON in native byte order" {
    var out: [request_capacity]u8 = undefined;
    const f = try encodeRequest(&out, .{ .login = "alex" });
    const n = std.mem.readInt(u32, f[0..4], @import("builtin").cpu.arch.endian());
    try std.testing.expectEqual(f.len - 4, n);
    try std.testing.expectEqualStrings("{\"type\":\"login\",\"user\":\"alex\"}", f[4..]);
    try std.testing.expectEqualStrings(
        "{\"type\":\"answer\",\"response\":null}",
        (try encodeRequest(&out, .{ .answer = null }))[4..],
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"answer\",\"response\":\"p\\\"w\"}",
        (try encodeRequest(&out, .{ .answer = "p\"w" }))[4..],
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"start\",\"session\":\"rediwm\"}",
        (try encodeRequest(&out, .{ .start = "rediwm" }))[4..],
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"cancel\"}",
        (try encodeRequest(&out, .cancel))[4..],
    );
    // The largest password the UI accepts still fits after worst-case escaping.
    const control = [_]u8{1} ** 511;
    _ = try encodeRequest(&out, .{ .answer = &control });
}

test "dm responses map onto conversation steps" {
    const a = std.testing.allocator;
    var ok = try parseResponse(a, "{\"type\":\"ok\"}");
    defer ok.deinit();
    try std.testing.expect(ok.response == .ok);

    var bad = try parseResponse(a, "{\"type\":\"denied\",\"text\":\"pam_authenticate: AUTH_ERR\"}");
    defer bad.deinit();
    try std.testing.expectEqualStrings("pam_authenticate: AUTH_ERR", bad.response.denied);

    var fail = try parseResponse(a, "{\"type\":\"failed\",\"text\":\"no session\"}");
    defer fail.deinit();
    try std.testing.expectEqualStrings("no session", fail.response.failed);

    var ask = try parseResponse(a, "{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"Password:\",\"extra\":1}");
    defer ask.deinit();
    try std.testing.expectEqual(MessageKind.secret, ask.response.question.kind);
    try std.testing.expectEqualStrings("Password:", ask.response.question.text);

    try std.testing.expectError(error.InvalidResponse, parseResponse(a, "{\"type\":\"surprise\"}"));
}

test "dm request parsing and response encoding roundtrip" {
    const a = std.testing.allocator;
    var req1 = try parseRequest(a, "{\"type\":\"login\",\"user\":\"sam\"}");
    defer req1.deinit();
    try std.testing.expectEqualStrings("sam", req1.request.login);

    var req2 = try parseRequest(a, "{\"type\":\"answer\",\"response\":\"secret123\"}");
    defer req2.deinit();
    try std.testing.expectEqualStrings("secret123", req2.request.answer.?);

    var req3 = try parseRequest(a, "{\"type\":\"answer\",\"response\":null}");
    defer req3.deinit();
    try std.testing.expect(req3.request.answer == null);

    var req4 = try parseRequest(a, "{\"type\":\"start\",\"session\":\"sway\"}");
    defer req4.deinit();
    try std.testing.expectEqualStrings("sway", req4.request.start);

    var req5 = try parseRequest(a, "{\"type\":\"cancel\"}");
    defer req5.deinit();
    try std.testing.expect(req5.request == .cancel);

    var out: [request_capacity]u8 = undefined;
    const ok_bytes = try encodeResponse(&out, .ok);
    try std.testing.expectEqualStrings("{\"type\":\"ok\"}", ok_bytes[4..]);

    const q_bytes = try encodeResponse(&out, .{ .question = .{ .kind = .secret, .text = "Pass:" } });
    try std.testing.expectEqualStrings("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"Pass:\"}", q_bytes[4..]);

    const d_bytes = try encodeResponse(&out, .{ .denied = "No access" });
    try std.testing.expectEqualStrings("{\"type\":\"denied\",\"text\":\"No access\"}", d_bytes[4..]);

    const f_bytes = try encodeResponse(&out, .{ .failed = "Error occurred" });
    try std.testing.expectEqualStrings("{\"type\":\"failed\",\"text\":\"Error occurred\"}", f_bytes[4..]);
}

test "dm client reassembles split frames" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &fds));
    var client = Client.fromFd(fds[0]);
    defer client.close();
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(out[4..]);
    try w.writeAll("{\"type\":\"ok\"}");
    std.mem.writeInt(u32, out[0..4], @intCast(w.end), @import("builtin").cpu.arch.endian());
    const whole = out[0 .. w.end + 4];
    _ = c.write(fds[1], whole.ptr, 3);
    try client.fill();
    try std.testing.expect(try client.frame() == null);
    _ = c.write(fds[1], whole[3..].ptr, whole.len - 3);
    _ = c.write(fds[1], whole.ptr, whole.len);
    try client.fill();
    for (0..2) |_| {
        const payload = (try client.frame()).?;
        try std.testing.expectEqualStrings("{\"type\":\"ok\"}", payload);
        client.consume(payload);
    }
    try std.testing.expect(try client.frame() == null);
    _ = c.close(fds[1]);
    try std.testing.expectError(error.Disconnected, client.fill());
}
