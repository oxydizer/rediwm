//! D-Bus v1 codec. Readers borrow their backing message and optional descriptors.
//! Wire limits and alignment: https://dbus.freedesktop.org/doc/dbus-specification.html
const std = @import("std");
pub const max_array = 1 << 26;
pub const max_message = 1 << 27;
pub const Error = error{ InvalidMessage, Truncated, TooLarge, InvalidSignature, UnsupportedFd };
pub const Kind = enum(u8) { method_call = 1, method_return = 2, error_reply = 3, signal = 4, _ };
pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    endian: std.builtin.Endian = .little,
    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }
    pub fn raw(self: *Writer, data: []const u8) !void {
        if (data.len > max_message - self.bytes.items.len) return error.TooLarge;
        try self.bytes.appendSlice(self.allocator, data);
    }
    pub fn alignTo(self: *Writer, n: usize) !void {
        const zeros = [_]u8{0} ** 8;
        try self.raw(zeros[0..padding(self.bytes.items.len, n)]);
    }
    pub fn byte(self: *Writer, value: u8) !void {
        try self.raw(&.{value});
    }
    pub fn int(self: *Writer, comptime T: type, value: T) !void {
        try self.alignTo(@sizeOf(T));
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, self.endian);
        try self.raw(&buf);
    }
    pub fn uint32(self: *Writer, value: u32) !void {
        try self.int(u32, value);
    }
    pub fn uint64(self: *Writer, value: u64) !void {
        try self.int(u64, value);
    }
    pub fn boolean(self: *Writer, value: bool) !void {
        try self.uint32(@intFromBool(value));
    }
    pub fn double(self: *Writer, value: f64) !void {
        try self.int(u64, @bitCast(value));
    }
    pub fn string(self: *Writer, value: []const u8) !void {
        if (!validString(value)) return error.InvalidMessage;
        if (value.len > max_message) return error.TooLarge;
        try self.uint32(@intCast(value.len));
        try self.raw(value);
        try self.byte(0);
    }
    pub fn objectPath(self: *Writer, value: []const u8) !void {
        if (!validPath(value)) return error.InvalidMessage;
        try self.string(value);
    }
    pub fn signature(self: *Writer, value: []const u8) !void {
        try validateSignature(value);
        try self.byte(@intCast(value.len));
        try self.raw(value);
        try self.byte(0);
    }
    /// Start a variant, then write exactly one value of this signature.
    pub fn variant(self: *Writer, sig: []const u8) !void {
        try singleSignature(sig);
        try self.signature(sig);
    }
    pub const Array = struct { length: usize, start: usize };
    pub fn beginArray(self: *Writer, elem_alignment: usize) !Array {
        try self.alignTo(4);
        const length = self.bytes.items.len;
        try self.uint32(0);
        try self.alignTo(elem_alignment);
        return .{ .length = length, .start = self.bytes.items.len };
    }
    pub fn endArray(self: *Writer, array: Array) !void {
        const len = self.bytes.items.len - array.start;
        if (len > max_array) return error.TooLarge;
        self.patch(array.length, @intCast(len));
    }
    fn patch(self: *Writer, offset: usize, value: u32) void {
        std.mem.writeInt(u32, self.bytes.items[offset..][0..4], value, self.endian);
    }
};
pub const Reader = struct {
    fds: []const std.posix.fd_t = &.{},
    bytes: []const u8,
    offset: usize = 0,
    endian: std.builtin.Endian = .little,
    pub fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.offset > self.bytes.len or n > self.bytes.len - self.offset) return error.Truncated;
        const value = self.bytes[self.offset..][0..n];
        self.offset += n;
        return value;
    }
    pub fn alignTo(self: *Reader, n: usize) Error!void {
        for (try self.take(padding(self.offset, n))) |ch| if (ch != 0) return error.InvalidMessage;
    }
    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }
    pub fn int(self: *Reader, comptime T: type) Error!T {
        try self.alignTo(@sizeOf(T));
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], self.endian);
    }
    pub fn uint32(self: *Reader) Error!u32 {
        return self.int(u32);
    }
    pub fn unixFd(self: *Reader) Error!std.posix.fd_t {
        if (self.fds.len == 0) return error.UnsupportedFd;
        const index = try self.uint32();
        if (index >= self.fds.len) return error.InvalidMessage;
        return self.fds[index];
    }
    pub fn uint64(self: *Reader) Error!u64 {
        return self.int(u64);
    }
    pub fn boolean(self: *Reader) Error!bool {
        return switch (try self.uint32()) {
            0 => false,
            1 => true,
            else => error.InvalidMessage,
        };
    }
    pub fn double(self: *Reader) Error!f64 {
        return @bitCast(try self.int(u64));
    }
    fn text(self: *Reader, len: usize) Error![]const u8 {
        const value = try self.take(len);
        if (try self.byte() != 0 or !validString(value)) return error.InvalidMessage;
        return value;
    }
    pub fn string(self: *Reader) Error![]const u8 {
        return self.text(try self.uint32());
    }
    pub fn objectPath(self: *Reader) Error![]const u8 {
        const value = try self.string();
        if (!validPath(value)) return error.InvalidMessage;
        return value;
    }
    pub fn signature(self: *Reader) Error![]const u8 {
        const value = try self.text(try self.byte());
        try validateSignature(value);
        return value;
    }
    pub fn variant(self: *Reader) Error![]const u8 {
        const sig = try self.signature();
        try singleSignature(sig);
        return sig;
    }
    /// Subreader retains absolute offsets; its bytes end at the array boundary.
    pub fn array(self: *Reader, elem_alignment: usize) Error!Reader {
        const len = try self.uint32();
        if (len > max_array) return error.TooLarge;
        try self.alignTo(elem_alignment);
        const start = self.offset;
        _ = try self.take(len);
        return .{ .bytes = self.bytes[0..self.offset], .offset = start, .endian = self.endian, .fds = self.fds };
    }
    pub fn done(self: Reader) Error!void {
        if (self.offset != self.bytes.len) return error.InvalidMessage;
    }
    pub fn skip(self: *Reader, sig: []const u8) Error!void {
        try singleSignature(sig);
        try self.skipDepth(sig, 0);
    }
    fn skipDepth(self: *Reader, sig: []const u8, depth: usize) Error!void {
        if (depth > 64) return error.InvalidSignature;
        switch (sig[0]) {
            'y' => {
                _ = try self.byte();
            },
            'b' => {
                _ = try self.boolean();
            },
            'n', 'q' => {
                _ = try self.int(u16);
            },
            'i', 'u' => {
                _ = try self.uint32();
            },
            'x', 't', 'd' => {
                _ = try self.int(u64);
            },
            's' => {
                _ = try self.string();
            },
            'o' => {
                _ = try self.objectPath();
            },
            'g' => {
                _ = try self.signature();
            },
            'h' => {
                _ = try self.unixFd();
            },
            'v' => try self.skipDepth(try self.variant(), depth + 1),
            'a' => {
                var sub = try self.array(alignment(sig[1]));
                while (sub.offset < sub.bytes.len) try sub.skipDepth(sig[1..], depth + 1);
                try sub.done();
            },
            '(', '{' => {
                try self.alignTo(8);
                var pos: usize = 1;
                while (pos < sig.len - 1) {
                    const start = pos;
                    try typeEnd(sig, &pos, 0, 0, true);
                    try self.skipDepth(sig[start..pos], depth + 1);
                }
            },
            else => return error.InvalidSignature,
        }
    }
};
fn padding(offset: usize, n: usize) usize {
    std.debug.assert(n == 1 or n == 2 or n == 4 or n == 8);
    return (n - offset % n) % n;
}
fn validString(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}
pub fn validPath(s: []const u8) bool {
    if (s.len == 0 or s[0] != '/') return false;
    if (s.len == 1) return true;
    var parts = std.mem.splitScalar(u8, s[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}
fn alignment(ch: u8) usize {
    return switch (ch) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}
fn basic(ch: u8) bool {
    return std.mem.indexOfScalar(u8, "ybnqiuxtdsogh", ch) != null;
}
fn typeEnd(sig: []const u8, pos: *usize, arrays: usize, structs: usize, dict: bool) Error!void {
    if (pos.* >= sig.len or arrays > 32 or structs > 32) return error.InvalidSignature;
    const ch = sig[pos.*];
    pos.* += 1;
    if (basic(ch) or ch == 'v') return;
    switch (ch) {
        'a' => try typeEnd(sig, pos, arrays + 1, structs, true),
        '(', '{' => {
            if (ch == '{' and !dict) return error.InvalidSignature;
            const close: u8 = if (ch == '(') ')' else '}';
            var count: usize = 0;
            while (pos.* < sig.len and sig[pos.*] != close) {
                if (ch == '{' and count == 0 and !basic(sig[pos.*])) return error.InvalidSignature;
                try typeEnd(sig, pos, arrays, structs + 1, false);
                count += 1;
            }
            if (pos.* == sig.len or count == 0 or (ch == '{' and count != 2)) return error.InvalidSignature;
            pos.* += 1;
        },
        else => return error.InvalidSignature,
    }
}
pub fn validateSignature(sig: []const u8) Error!void {
    if (sig.len > 255) return error.InvalidSignature;
    var pos: usize = 0;
    while (pos < sig.len) try typeEnd(sig, &pos, 0, 0, false);
}
fn singleSignature(sig: []const u8) Error!void {
    try validateSignature(sig);
    var pos: usize = 0;
    try typeEnd(sig, &pos, 0, 0, false);
    if (pos != sig.len) return error.InvalidSignature;
}
pub const Headers = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
};
pub const flag_no_reply_expected: u8 = 0x01;
pub const flag_no_auto_start: u8 = 0x02;
pub const flag_allow_interactive_authorization: u8 = 0x04;

pub const Message = struct {
    kind: Kind,
    flags: u8 = 0,
    serial: u32,
    headers: Headers,
    body: Reader,
};
/// Null means the fixed header is incomplete. Validates lengths before allocation.
pub fn frameLength(bytes: []const u8) Error!?usize {
    if (bytes.len < 16) return null;
    if ((bytes[0] != 'l' and bytes[0] != 'B') or bytes[1] == 0 or bytes[3] != 1) return error.InvalidMessage;
    var r: Reader = .{ .bytes = bytes, .offset = 4, .endian = if (bytes[0] == 'l') .little else .big };
    const body = try r.uint32();
    if (try r.uint32() == 0) return error.InvalidMessage;
    const fields = try r.uint32();
    if (fields > max_array) return error.TooLarge;
    const header = 16 + @as(usize, fields) + padding(fields, 8);
    if (body > max_message - header) return error.TooLarge;
    return header + body;
}
pub fn decode(bytes: []const u8) Error!Message {
    return decodeWithFds(bytes, &.{});
}
/// Descriptors are borrowed, just like the message bytes. The caller owns them.
pub fn decodeWithFds(bytes: []const u8, fds: []const std.posix.fd_t) Error!Message {
    const len = (try frameLength(bytes)) orelse return error.Truncated;
    if (len != bytes.len) return if (len > bytes.len) error.Truncated else error.InvalidMessage;
    var r: Reader = .{ .bytes = bytes, .offset = 8, .endian = if (bytes[0] == 'l') .little else .big };
    const serial = try r.uint32();
    var fields = try r.array(8);
    var h: Headers = .{};
    var fd_count: u32 = 0;
    var seen = [_]bool{false} ** 256;
    while (fields.offset < fields.bytes.len) {
        try fields.alignTo(8);
        const code = try fields.byte();
        if (code == 0 or seen[code]) return error.InvalidMessage;
        seen[code] = true;
        const sig = try fields.variant();
        const expected: []const u8 = switch (code) {
            1 => "o",
            2, 3, 4, 6, 7 => "s",
            5, 9 => "u",
            8 => "g",
            else => sig,
        };
        if (!std.mem.eql(u8, sig, expected)) return error.InvalidMessage;
        switch (code) {
            1 => h.path = try fields.objectPath(),
            2 => h.interface = try fields.string(),
            3 => h.member = try fields.string(),
            4 => h.error_name = try fields.string(),
            5 => {
                const v = try fields.uint32();
                if (v == 0) return error.InvalidMessage;
                h.reply_serial = v;
            },
            6 => h.destination = try fields.string(),
            7 => h.sender = try fields.string(),
            8 => h.signature = try fields.signature(),
            9 => {
                fd_count = try fields.uint32();
                if (fd_count != 0 and fds.len == 0) return error.UnsupportedFd;
            },
            else => try fields.skip(sig),
        }
    }
    if (fd_count != fds.len) return error.InvalidMessage;
    r.fds = fds;
    try r.alignTo(8);
    const kind: Kind = @enumFromInt(bytes[1]);
    try required(kind, h);
    var body = r;
    var pos: usize = 0;
    while (pos < h.signature.len) {
        const start = pos;
        try typeEnd(h.signature, &pos, 0, 0, false);
        try body.skip(h.signature[start..pos]);
    }
    try body.done();
    return .{ .kind = kind, .flags = bytes[2], .serial = serial, .headers = h, .body = r };
}
fn required(kind: Kind, h: Headers) Error!void {
    if (h.interface) |v| if (!validName(v, .interface)) return error.InvalidMessage;
    if (h.error_name) |v| if (!validName(v, .interface)) return error.InvalidMessage;
    if (h.member) |v| if (!validName(v, .member)) return error.InvalidMessage;
    if (h.destination) |v| if (!validName(v, .bus)) return error.InvalidMessage;
    if (h.sender) |v| if (!validName(v, .bus)) return error.InvalidMessage;
    const ok = switch (kind) {
        .method_call => h.path != null and h.member != null,
        .method_return => h.reply_serial != null,
        .error_reply => h.reply_serial != null and h.error_name != null,
        .signal => h.path != null and h.interface != null and h.member != null,
        else => true,
    };
    if (!ok) return error.InvalidMessage;
}
pub fn encode(allocator: std.mem.Allocator, kind: Kind, flags: u8, serial: u32, h: Headers, body: *const Writer) !Writer {
    if (serial == 0 or @intFromEnum(kind) == 0) return error.InvalidMessage;
    try required(kind, h);
    var w: Writer = .{ .allocator = allocator, .endian = body.endian };
    errdefer w.deinit();
    try w.raw(&.{ if (w.endian == .little) 'l' else 'B', @intFromEnum(kind), flags, 1 });
    try w.uint32(@intCast(body.bytes.items.len));
    try w.uint32(serial);
    const array = try w.beginArray(8);
    inline for (.{ "path", "member", "interface", "error_name", "reply_serial", "destination", "sender", "signature" }, .{ 1, 3, 2, 4, 5, 6, 7, 8 }) |name, code| {
        const value = @field(h, name);
        if (comptime code == 8) {
            if (value.len != 0) {
                try w.alignTo(8);
                try w.byte(code);
                try w.variant("g");
                try w.signature(value);
            }
        } else if (value) |v| {
            try w.alignTo(8);
            try w.byte(code);
            if (comptime code == 5) {
                try w.variant("u");
                try w.uint32(v);
            } else {
                try w.variant(if (code == 1) "o" else "s");
                if (comptime code == 1) try w.objectPath(v) else try w.string(v);
            }
        }
    }
    try w.endArray(array);
    try w.alignTo(8);
    try w.raw(body.bytes.items);
    _ = try decode(w.bytes.items);
    return w;
}

test "primitive round trips in both byte orders and string alignment" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var w: Writer = .{ .allocator = std.testing.allocator, .endian = endian };
        defer w.deinit();
        try w.byte(7);
        try w.string("hello");
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, w.bytes.items[1..4]);
        try w.int(i16, -32);
        try w.int(u16, 65535);
        try w.int(i32, -1234);
        try w.uint32(0xffffffff);
        try w.int(i64, -9876543210);
        try w.int(u64, 0xffffffffffffffff);
        try w.double(1.25);
        try w.boolean(true);
        try w.objectPath("/a/b_1");
        try w.signature("a{sv}(yu)");
        var r: Reader = .{ .bytes = w.bytes.items, .endian = endian };
        try std.testing.expectEqual(7, try r.byte());
        try std.testing.expectEqualStrings("hello", try r.string());
        try std.testing.expectEqual(-32, try r.int(i16));
        try std.testing.expectEqual(65535, try r.int(u16));
        try std.testing.expectEqual(-1234, try r.int(i32));
        try std.testing.expectEqual(0xffffffff, try r.uint32());
        try std.testing.expectEqual(-9876543210, try r.int(i64));
        try std.testing.expectEqual(0xffffffffffffffff, try r.int(u64));
        try std.testing.expectEqual(1.25, try r.double());
        try std.testing.expect(try r.boolean());
        try std.testing.expectEqualStrings("/a/b_1", try r.objectPath());
        try std.testing.expectEqualStrings("a{sv}(yu)", try r.signature());
        try r.done();
    }
}
test "array length excludes leading alignment and variants use absolute offsets" {
    var w: Writer = .{ .allocator = std.testing.allocator };
    defer w.deinit();
    try w.byte(1);
    const a = try w.beginArray(8);
    try w.alignTo(8);
    try w.byte(2);
    try w.variant("t");
    try w.int(u64, 99);
    try w.endArray(a);
    try std.testing.expectEqual(8, a.start);
    try std.testing.expectEqual(24, w.bytes.items.len);
    var r: Reader = .{ .bytes = w.bytes.items };
    _ = try r.byte();
    var sub = try r.array(8);
    try sub.alignTo(8);
    try std.testing.expectEqual(2, try sub.byte());
    try std.testing.expectEqualStrings("t", try sub.variant());
    try std.testing.expectEqual(99, try sub.int(u64));
    try sub.done();
    try r.done();
    // Length prefix at offset zero ends at 4; the next 4 padding bytes do not count.
    var leading: Writer = .{ .allocator = std.testing.allocator };
    defer leading.deinit();
    const b = try leading.beginArray(8);
    try leading.int(u64, 42);
    try leading.endArray(b);
    try std.testing.expectEqual(8, std.mem.readInt(u32, leading.bytes.items[0..4], .little));
}
test "message framing, nested dictionary variants, header padding and truncation" {
    var body: Writer = .{ .allocator = std.testing.allocator };
    defer body.deinit();
    try body.byte(9);
    try body.alignTo(8);
    try body.uint32(123);
    const a = try body.beginArray(8);
    try body.alignTo(8);
    try body.string("title");
    try body.variant("as");
    const strings = try body.beginArray(4);
    try body.string("one");
    try body.string("two");
    try body.endArray(strings);
    try body.endArray(a);
    var w = try encode(std.testing.allocator, .method_call, 0, 1, .{ .path = "/test", .member = "Go", .signature = "y(u)a{sv}" }, &body);
    defer w.deinit();
    const msg = try decode(w.bytes.items);
    try std.testing.expectEqual(0, msg.body.offset % 8);
    try std.testing.expectEqualStrings("y(u)a{sv}", msg.headers.signature);
    for (0..w.bytes.items.len) |len| try std.testing.expectError(error.Truncated, decode(w.bytes.items[0..len]));
    // Every single-byte mutation must fail cleanly or produce a valid bounded message.
    for (0..w.bytes.items.len) |i| {
        const old = w.bytes.items[i];
        w.bytes.items[i] = 255;
        _ = decode(w.bytes.items) catch {};
        w.bytes.items[i] = old;
    }
}
test "malformed signatures, lengths, booleans, paths and padding" {
    for ([_][]const u8{ "a", "()", "{sv}", "a{vv}", "a{sss}", "(u", "u)", "z", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaau" }) |sig| try std.testing.expectError(error.InvalidSignature, validateSignature(sig));
    var r: Reader = .{ .bytes = &.{ 2, 0, 0, 0 } };
    try std.testing.expectError(error.InvalidMessage, r.boolean());
    r = .{ .bytes = &.{ 1, 0, 0, 4 } };
    try std.testing.expectError(error.TooLarge, r.array(1));
    r = .{ .bytes = &.{ 0, 1, 0, 0 }, .offset = 1 };
    try std.testing.expectError(error.InvalidMessage, r.alignTo(4));
    r = .{ .bytes = &.{ 3, 0, 0, 0, 'a' } };
    try std.testing.expectError(error.Truncated, r.string());
    r = .{ .bytes = &.{ 1, 0, 0, 0, 255, 0 } };
    try std.testing.expectError(error.InvalidMessage, r.string());
    try std.testing.expect(!validPath("/bad//path"));
    const oversized = [_]u8{ 'l', 1, 0, 1, 255, 255, 255, 255, 1, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.TooLarge, frameLength(&oversized));
}

fn validName(value: []const u8, kind: enum { interface, member, bus }) bool {
    if (value.len == 0 or value.len > 255) return false;
    const unique = kind == .bus and value[0] == ':';
    const text = if (unique) value[1..] else value;
    if (kind == .member and std.mem.indexOfScalar(u8, text, '.') != null) return false;
    if (kind != .member and std.mem.indexOfScalar(u8, text, '.') == null) return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or (!unique and std.ascii.isDigit(part[0]))) return false;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and !(kind == .bus and ch == '-')) return false;
    }
    return true;
}

test "real busctl Hello golden message including final header padding" {
    const golden = @embedFile("hello.bin");
    const message = try decode(golden);
    try std.testing.expectEqual(Kind.method_call, message.kind);
    try std.testing.expectEqualStrings("Hello", message.headers.member.?);
    try std.testing.expectEqualStrings(":1.1", message.headers.sender.?);
    try std.testing.expectEqual(144, message.body.offset);
    const body: Writer = .{ .allocator = std.testing.allocator };
    var written = try encode(std.testing.allocator, message.kind, message.flags, message.serial, message.headers, &body);
    defer written.deinit();
    try std.testing.expectEqualSlices(u8, golden, written.bytes.items);
}

test "duplicate or mistyped headers, absent body signature and forbidden FDs" {
    var golden = @embedFile("hello.bin").*;
    golden[48] = 1; // duplicate PATH in place of MEMBER
    try std.testing.expectError(error.InvalidMessage, decode(&golden));
    golden = @embedFile("hello.bin").*;
    golden[18] = 's'; // PATH must be an OBJECT_PATH variant
    try std.testing.expectError(error.InvalidMessage, decode(&golden));
    var body: Writer = .{ .allocator = std.testing.allocator };
    defer body.deinit();
    try body.uint32(0);
    try std.testing.expectError(error.InvalidMessage, encode(std.testing.allocator, .method_return, 0, 1, .{ .reply_serial = 1 }, &body));
    try std.testing.expectError(error.UnsupportedFd, encode(std.testing.allocator, .method_return, 0, 1, .{ .reply_serial = 1, .signature = "h" }, &body));
    try std.testing.expectError(error.InvalidMessage, encode(std.testing.allocator, .signal, 0, 1, .{ .path = "/", .interface = "bad", .member = "1bad", .signature = "u" }, &body));
}
