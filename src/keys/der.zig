//! Bounded DER envelopes for legacy RSA metadata. No private-key arithmetic.
const std = @import("std");
pub const Reader = struct {
    bytes: []const u8,
    pub fn value(self: *Reader, tag: u8) ![]const u8 {
        if (self.bytes.len < 2 or self.bytes[0] != tag) return error.InvalidDer;
        var len: usize = self.bytes[1];
        var start: usize = 2;
        if (len & 0x80 != 0) {
            const count = len & 0x7f;
            if (count == 0 or count > 4 or self.bytes.len < 2 + count) return error.InvalidDer;
            len = 0;
            for (self.bytes[2 .. 2 + count]) |byte| len = (len << 8) | byte;
            start += count;
        }
        if (len > self.bytes.len - start) return error.InvalidDer;
        const result = self.bytes[start .. start + len];
        self.bytes = self.bytes[start + len ..];
        return result;
    }
};
pub fn rsaPublic(a: std.mem.Allocator, raw: []const u8, pkcs8: bool) ![]const u8 {
    var outer: Reader = .{ .bytes = raw };
    var sequence: Reader = .{ .bytes = try outer.value(0x30) };
    if (outer.bytes.len != 0) return error.InvalidDer;
    if (pkcs8) {
        if (!std.mem.eql(u8, try sequence.value(2), "\x00")) return error.InvalidDer;
        var algorithm: Reader = .{ .bytes = try sequence.value(0x30) };
        if (!std.mem.eql(u8, try algorithm.value(6), "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01")) return error.UnsupportedKey;
        if (algorithm.bytes.len > 0 and (try algorithm.value(5)).len != 0) return error.InvalidDer;
        if (algorithm.bytes.len != 0) return error.InvalidDer;
        return rsaPublic(a, try sequence.value(4), false);
    }
    if (!std.mem.eql(u8, try sequence.value(2), "\x00")) return error.UnsupportedKey;
    const modulus = try sequence.value(2);
    const exponent = try sequence.value(2);
    for (0..6) |_| _ = try sequence.value(2);
    if (sequence.bytes.len != 0) return error.InvalidDer;
    const parts = [_][]const u8{ "ssh-rsa", exponent, modulus };
    var blob: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(part.len), .big);
        try blob.appendSlice(a, &len);
        try blob.appendSlice(a, part);
    }
    return blob.toOwnedSlice(a);
}
