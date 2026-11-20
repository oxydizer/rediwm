//! The wire format between the compositor and `rediwm-cups`, the helper that
//! holds libcups (and, through it, gnutls and the crypto libraries). Frames
//! travel on a stream socketpair: kind (u8), payload length (u32, little
//! endian), payload. Each side caps lengths before it reads a payload, and a
//! frame it cannot place is a protocol error: the connection is dropped.
//!
//! compositor -> helper: `submit` (reset byte, then NUL-terminated method and
//! arguments), `credentials` (user NUL password bytes), `cancel`, `finish`.
//! helper -> compositor: `state` (u8 state, i32 result: 1 wants a password, 2
//! finished), `device` (five NUL-terminated strings of a discovery result,
//! sent before the `state` frame that ends a successful discovery).
const std = @import("std");
const c = @import("c");

pub const header_len = 5;
/// Largest payload the helper accepts: 68 arguments of at most a few KiB.
pub const max_command = 128 * 1024;
/// Largest payload the compositor accepts: five strings of at most 8192 bytes.
pub const max_report = 48 * 1024;
/// Arguments after the method name (direct.c's own limit).
pub const max_args = 68;
/// Longest user name and password, as `credentials` carries them (`user NUL
/// password`). The helper's receive page for them is this big.
pub const max_user = 255;
pub const max_password = 4095;
pub const max_credentials = max_user + 1 + max_password;
/// Discovery results the compositor keeps (direct.c's own limit).
pub const max_devices = 128;

pub const Command = enum(u8) { submit = 1, credentials, cancel, finish, _ };
pub const Report = enum(u8) { state = 0x81, device, _ };

pub fn header(kind: u8, len: usize) [header_len]u8 {
    var bytes: [header_len]u8 = undefined;
    bytes[0] = kind;
    std.mem.writeInt(u32, bytes[1..5], @intCast(len), .little);
    return bytes;
}

/// Sends one frame whose payload is `parts` joined, in a single nonblocking
/// `sendmsg`: the parts are not copied, so a password goes from the caller's
/// locked storage to the kernel. A stream cannot carry half a frame, so false
/// (full, or the peer is gone) means the connection must be dropped.
pub fn send(fd: c_int, kind: u8, parts: []const []const u8) bool {
    var vec: [8]c.struct_iovec = undefined;
    if (parts.len + 1 > vec.len) return false;
    var total: usize = 0;
    for (parts) |part| total += part.len;
    var head = header(kind, total);
    vec[0] = .{ .iov_base = &head, .iov_len = header_len };
    for (parts, 1..) |part, i| vec[i] = .{ .iov_base = @constCast(part.ptr), .iov_len = part.len };
    var message = std.mem.zeroes(c.struct_msghdr);
    message.msg_iov = &vec;
    message.msg_iovlen = @intCast(parts.len + 1);
    while (true) {
        const sent = c.sendmsg(fd, &message, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
        if (sent < 0 and std.posix.errno(sent) == .INTR) continue;
        return sent >= 0 and @as(usize, @intCast(sent)) == total + header_len;
    }
}

/// Splits `payload` into its NUL-terminated strings, which stay in place.
/// Null when it does not end with a NUL or holds more than `out` can take.
pub fn strings(payload: []const u8, out: [][:0]const u8) ?usize {
    if (payload.len == 0) return 0;
    if (payload[payload.len - 1] != 0) return null;
    var count: usize = 0;
    var start: usize = 0;
    for (payload, 0..) |byte, i| {
        if (byte != 0) continue;
        if (count == out.len) return null;
        out[count] = payload[start..i :0];
        count += 1;
        start = i + 1;
    }
    return count;
}

/// Reassembles frames from a nonblocking stream. It reads exactly the bytes
/// the current frame still lacks, never beyond it, so a payload lands only
/// in the buffer `chooser` picked for its kind. That is how the helper keeps a
/// password in its locked page and nowhere else.
pub const Receiver = struct {
    head: [header_len]u8 = undefined,
    have: usize = 0,
    parsed: bool = false,
    complete: bool = false,
    kind: u8 = 0,
    len: usize = 0,
    got: usize = 0,
    body: []u8 = &.{},

    pub const Result = enum { frame, again, closed, invalid };

    /// `chooser.destination(kind, len)` returns the buffer for a payload of
    /// `len` bytes (at least that long), or null to refuse the frame.
    pub fn read(self: *Receiver, fd: c_int, chooser: anytype) Result {
        if (self.complete) self.* = .{};
        while (self.have < header_len) switch (chunk(fd, self.head[self.have..])) {
            .data => |n| self.have += n,
            .again => return .again,
            .closed => return .closed,
        };
        if (!self.parsed) {
            self.kind = self.head[0];
            self.len = std.mem.readInt(u32, self.head[1..5], .little);
            self.body = chooser.destination(self.kind, self.len) orelse return .invalid;
            if (self.body.len < self.len) return .invalid;
            self.parsed = true;
        }
        while (self.got < self.len) switch (chunk(fd, self.body[self.got..self.len])) {
            .data => |n| self.got += n,
            .again => return .again,
            .closed => return .closed,
        };
        self.complete = true;
        return .frame;
    }

    /// The payload of the frame `read` just completed.
    pub fn payload(self: *const Receiver) []u8 {
        return self.body[0..self.len];
    }
};

const Chunk = union(enum) { data: usize, again, closed };

fn chunk(fd: c_int, buffer: []u8) Chunk {
    while (true) {
        const n = c.recv(fd, buffer.ptr, buffer.len, c.MSG_DONTWAIT);
        if (n > 0) return .{ .data = @intCast(n) };
        if (n == 0) return .closed;
        switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return .again,
            else => return .closed,
        }
    }
}

test "frames are reassembled from partial writes and routed by kind" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &pair));
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    var plain: [64]u8 = undefined;
    var secret: [16]u8 = undefined;
    const Chooser = struct {
        plain: []u8,
        secret: []u8,
        pub fn destination(self: @This(), kind: u8, len: usize) ?[]u8 {
            if (kind == @intFromEnum(Command.credentials)) return if (len <= self.secret.len) self.secret else null;
            return if (len <= self.plain.len) self.plain else null;
        }
    };
    const chooser: Chooser = .{ .plain = &plain, .secret = &secret };
    var receiver: Receiver = .{};
    try std.testing.expectEqual(Receiver.Result.again, receiver.read(pair[1], chooser));

    // A frame in two writes, split inside the header and again in the payload.
    const head = header(@intFromEnum(Command.submit), 6);
    try std.testing.expect(send(pair[0], @intFromEnum(Command.cancel), &.{}));
    try std.testing.expectEqual(Receiver.Result.frame, receiver.read(pair[1], chooser));
    try std.testing.expectEqual(@intFromEnum(Command.cancel), receiver.kind);
    try std.testing.expectEqual(@as(usize, 0), receiver.payload().len);
    try std.testing.expectEqual(@as(isize, 2), c.send(pair[0], &head, 2, 0));
    try std.testing.expectEqual(Receiver.Result.again, receiver.read(pair[1], chooser));
    try std.testing.expectEqual(@as(isize, 3), c.send(pair[0], head[2..].ptr, 3, 0));
    try std.testing.expectEqual(@as(isize, 3), c.send(pair[0], "abc", 3, 0));
    try std.testing.expectEqual(Receiver.Result.again, receiver.read(pair[1], chooser));
    try std.testing.expectEqual(@as(isize, 3), c.send(pair[0], "de\x00", 3, 0));
    try std.testing.expectEqual(Receiver.Result.frame, receiver.read(pair[1], chooser));
    try std.testing.expectEqualStrings("abcde\x00", receiver.payload());

    // Credentials never touch the plain buffer, and the next frame is read cleanly.
    try std.testing.expect(send(pair[0], @intFromEnum(Command.credentials), &.{ "root", "\x00", "hunter2" }));
    try std.testing.expect(send(pair[0], @intFromEnum(Command.finish), &.{}));
    @memset(&plain, 0);
    try std.testing.expectEqual(Receiver.Result.frame, receiver.read(pair[1], chooser));
    try std.testing.expectEqualStrings("root\x00hunter2", receiver.payload());
    try std.testing.expect(receiver.payload().ptr == &secret);
    try std.testing.expect(std.mem.allEqual(u8, &plain, 0));
    try std.testing.expectEqual(Receiver.Result.frame, receiver.read(pair[1], chooser));
    try std.testing.expectEqual(@intFromEnum(Command.finish), receiver.kind);

    // A length the chooser refuses is a protocol error, not a short read.
    try std.testing.expect(send(pair[0], @intFromEnum(Command.credentials), &.{"xxxxxxxxxxxxxxxxx"}));
    try std.testing.expectEqual(Receiver.Result.invalid, receiver.read(pair[1], chooser));

    // A peer that went away, even in the middle of a frame, is `closed`.
    var gone: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &gone));
    defer _ = c.close(gone[1]);
    receiver = .{};
    try std.testing.expectEqual(@as(isize, 3), c.send(gone[0], &head, 3, 0));
    _ = c.close(gone[0]);
    try std.testing.expectEqual(Receiver.Result.closed, receiver.read(gone[1], chooser));
}

test "strings splits NUL-terminated payloads and refuses anything else" {
    var out: [3][:0]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), strings("", &out));
    try std.testing.expectEqual(@as(?usize, 3), strings("a\x00\x00bc\x00", &out));
    try std.testing.expectEqualStrings("a", out[0]);
    try std.testing.expectEqualStrings("", out[1]);
    try std.testing.expectEqualStrings("bc", out[2]);
    try std.testing.expectEqual(@as(?usize, null), strings("a\x00b", &out));
    try std.testing.expectEqual(@as(?usize, null), strings("a\x00b\x00c\x00d\x00", &out));
}
