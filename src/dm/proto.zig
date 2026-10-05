//! Framing between rediwm-dm and its workers: a native-endian u32 length,
//! then the payload. Worker reports and PAM answers are a tag byte plus raw
//! bytes, so neither the C conversation shim nor a password ever goes through
//! JSON. `init` and `start` from the daemon are JSON built with
//! std.json.Stringify. Every fd here is a socket; writes use MSG_NOSIGNAL so
//! a vanished peer is an error, not SIGPIPE.
const std = @import("std");
const linux = std.os.linux;

pub const max_frame = 64 * 1024;

/// First byte of every worker -> daemon frame.
pub const Report = enum(u8) {
    /// Then a `QuestionKind` byte and the PAM message text.
    question = 'Q',
    auth_ok = 'O',
    /// Wrong credentials; then the PAM error text.
    denied = 'D',
    /// Any other authentication or account failure; then its text.
    failed = 'F',
    session_started = 'S',
    /// setcred/open_session/fork failed; then its text. The worker exits next.
    session_failed = 'X',
    session_ended = 'E',
    _,
};

pub const QuestionKind = enum(u8) {
    secret = 's',
    visible = 'v',
    info = 'i',
    @"error" = 'e',
    _,
};

/// First byte of a daemon -> worker answer frame (the C shim reads these).
pub const answer_tag = 'A';
pub const no_answer_tag = 'N';

pub fn writeFrame(fd: c_int, payload: []const u8) !void {
    return writeFrameParts(fd, &.{payload});
}

/// Writes one frame made of several parts, without copying them together.
pub fn writeFrameParts(fd: c_int, parts: []const []const u8) !void {
    var len: usize = 0;
    for (parts) |part| len += part.len;
    if (len > max_frame) return error.FrameTooLarge;
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(len), @import("builtin").cpu.arch.endian());
    try sendAll(fd, &prefix);
    for (parts) |part| try sendAll(fd, part);
}

fn sendAll(fd: c_int, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = linux.sendto(fd, bytes[sent..].ptr, bytes.len - sent, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => sent += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

/// Blocking read of one whole frame into `buf`. Only for trusted peers
/// (workers); the greeter is read without blocking through dm_ipc.Client.
pub fn readFrame(fd: c_int, buf: []u8) ![]u8 {
    var prefix: [4]u8 = undefined;
    try readAll(fd, &prefix);
    const len = std.mem.readInt(u32, &prefix, @import("builtin").cpu.arch.endian());
    if (len > buf.len) return error.FrameTooLarge;
    try readAll(fd, buf[0..len]);
    return buf[0..len];
}

fn readAll(fd: c_int, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const rc = linux.read(fd, buf[got..].ptr, buf.len - got);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.Eof;
                got += rc;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

/// Serializes `value` as JSON into `buf` and sends it as one frame.
pub fn writeJson(fd: c_int, buf: []u8, value: anytype) !void {
    var w: std.Io.Writer = .fixed(buf);
    try std.json.Stringify.value(value, .{}, &w);
    try writeFrame(fd, w.buffered());
}

/// The worker's first message: which PAM service and account to open.
pub const Init = struct {
    service: []const u8,
    user: []const u8,
    vt: u32,
    class: []const u8,
};

/// Sent once authentication succeeded: what to run in the new session.
pub const Start = struct {
    exec: []const u8,
    desktop: []const u8,
    desktops: []const u8,
};

/// At most `max` bytes of `text`, cut on a UTF-8 boundary, with invalid
/// UTF-8 replaced by '?' so the greeter's JSON parser accepts it.
pub fn sanitizeText(out: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const valid = i + len <= text.len and (len == 1 and text[i] < 0x80 or
            len > 1 and std.unicode.utf8ValidateSlice(text[i .. i + len]));
        const piece: []const u8 = if (valid) text[i .. i + len] else "?";
        if (n + piece.len > out.len) break;
        @memcpy(out[n..][0..piece.len], piece);
        n += piece.len;
        i += if (valid) len else 1;
    }
    return out[0..n];
}

test "dm frames round-trip and refuse oversized payloads" {
    const c = @cImport(@cInclude("sys/socket.h"));
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &fds));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    try writeFrameParts(fds[0], &.{ &.{answer_tag}, "p\"w\\\x08" });
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Ap\"w\\\x08", try readFrame(fds[1], &buf));
    var json_buf: [256]u8 = undefined;
    try writeJson(fds[0], &json_buf, Start{ .exec = "sh -c \"x\"", .desktop = "a", .desktops = "b" });
    const frame = try readFrame(fds[1], &buf);
    const parsed = try std.json.parseFromSlice(Start, std.testing.allocator, frame, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sh -c \"x\"", parsed.value.exec);
    try writeFrame(fds[0], "0123456789");
    try std.testing.expectError(error.FrameTooLarge, readFrame(fds[1], buf[0..4]));
}

test "dm question text is valid, bounded UTF-8" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a?b", sanitizeText(&out, "a\xffb"));
    try std.testing.expectEqualStrings("é", sanitizeText(out[0..3], "éé"));
    try std.testing.expectEqualStrings("??", sanitizeText(&out, "\xc3\xc3"));
}
