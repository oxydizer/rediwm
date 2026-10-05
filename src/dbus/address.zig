//! Unix transport addresses. Iterator preserves the bus address's fallback order.
const std = @import("std");
pub const Address = struct {
    socket: std.posix.sockaddr.un,
    len: std.posix.socklen_t,
    guid: ?[32]u8 = null,
};
pub const Iterator = struct {
    remaining: []const u8,
    pub fn next(self: *Iterator) !?Address {
        while (self.remaining.len != 0) {
            const end = std.mem.indexOfScalar(u8, self.remaining, ';') orelse self.remaining.len;
            const item = self.remaining[0..end];
            self.remaining = if (end < self.remaining.len) self.remaining[end + 1 ..] else "";
            const colon = std.mem.indexOfScalar(u8, item, ':') orelse return error.InvalidAddress;
            if (!std.mem.eql(u8, item[0..colon], "unix")) continue;
            var fields = std.mem.splitScalar(u8, item[colon + 1 ..], ',');
            var result: ?Address = null;
            var guid: ?[32]u8 = null;
            while (fields.next()) |field| {
                const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidAddress;
                const key = field[0..eq];
                var decoded: [256]u8 = undefined;
                const value = try decode(field[eq + 1 ..], &decoded);
                if (std.mem.eql(u8, key, "guid")) {
                    if (guid != null or value.len != 32) return error.InvalidAddress;
                    for (value) |ch| if (!std.ascii.isHex(ch)) return error.InvalidAddress;
                    guid = value[0..32].*;
                    continue;
                }
                const abstract = std.mem.eql(u8, key, "abstract");
                if (!abstract and !std.mem.eql(u8, key, "path")) continue;
                if (result != null or value.len == 0) return error.InvalidAddress;
                var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = @splat(0) };
                if (value.len >= addr.path.len) return error.AddressTooLong;
                if (!abstract and value[0] != '/') return error.InvalidAddress;
                const start: usize = if (abstract) 1 else 0;
                @memcpy(addr.path[start..][0..value.len], value);
                result = .{ .socket = addr, .len = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + value.len + 1) };
            }
            if (result) |*addr| {
                addr.guid = guid;
                return addr.*;
            }
        }
        return null;
    }
};
fn decode(input: []const u8, out: []u8) ![]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len) : (i += 1) {
        if (n == out.len) return error.AddressTooLong;
        var ch = input[i];
        if (ch == '%') {
            if (input.len - i < 3) return error.InvalidAddress;
            if (!std.ascii.isHex(input[i + 1]) or !std.ascii.isHex(input[i + 2])) return error.InvalidAddress;
            ch = std.fmt.parseInt(u8, input[i + 1 ..][0..2], 16) catch return error.InvalidAddress;
            i += 2;
        } else if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_/.*", ch) == null) return error.InvalidAddress;
        if (ch == 0) return error.InvalidAddress;
        out[n] = ch;
        n += 1;
    }
    return out[0..n];
}
test "address alternatives, escapes and abstract namespace" {
    var it: Iterator = .{ .remaining = "tcp:host=localhost;unix:path=/tmp/a%20b,guid=0123456789abcdef0123456789abcdef;unix:abstract=abc" };
    const path = (try it.next()).?;
    try std.testing.expectEqualStrings("/tmp/a b", std.mem.sliceTo(&path.socket.path, 0));
    const abstract = (try it.next()).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 'a', 'b', 'c' }, abstract.socket.path[0..4]);
    try std.testing.expectEqual(@as(std.posix.socklen_t, 6), abstract.len);
    try std.testing.expectEqual(null, try it.next());
}
test "invalid addresses" {
    for ([_][]const u8{ "unix:path=/a%", "unix:path=/a%+1", "unix:path=/a,guid=abcd", "unix:path=/a%00", "unix:path=/a,path=/b", "unix:path=a", "unix:path=/a b", "unix:path=/a,abstract=b" }) |input| {
        var it: Iterator = .{ .remaining = input };
        try std.testing.expectError(error.InvalidAddress, it.next());
    }
}
