//! Public wire-format parsing, including the unencrypted header in encrypted
//! openssh-key-v1 files. Private components never leave this module.
const std = @import("std");
const pem = @import("pem.zig");
const model = @import("model.zig");
const A = std.mem.Allocator;
pub const Parsed = struct { item: model.Item, private: bool = false, encrypted: bool = false };
pub const Reader = struct {
    bytes: []const u8,
    pub fn int(self: *Reader) !u32 {
        if (self.bytes.len < 4) return error.Truncated;
        const value = std.mem.readInt(u32, self.bytes[0..4], .big);
        self.bytes = self.bytes[4..];
        return value;
    }
    pub fn string(self: *Reader) ![]const u8 {
        const len = try self.int();
        if (len > self.bytes.len) return error.Truncated;
        const value = self.bytes[0..len];
        self.bytes = self.bytes[len..];
        return value;
    }
};

fn mpBits(bytes: []const u8) !u32 {
    if (bytes.len == 0 or bytes[0] & 0x80 != 0) return error.InvalidInteger;
    const n = std.mem.trimStart(u8, bytes, "\x00");
    if (n.len == 0 or n.len > 2048) return error.InvalidInteger;
    return @intCast(n.len * 8 - @clz(n[0]));
}
pub fn publicBlob(a: A, blob: []const u8, comment: []const u8) !model.Item {
    if (blob.len > 32768) return error.KeyTooLarge;
    var r: Reader = .{ .bytes = blob };
    const algorithm = try r.string();
    const bits: u32 = if (std.mem.eql(u8, algorithm, "ssh-ed25519")) blk: {
        if ((try r.string()).len != 32) return error.InvalidKey;
        break :blk 256;
    } else if (std.mem.eql(u8, algorithm, "ssh-rsa")) blk: {
        _ = try mpBits(try r.string());
        break :blk try mpBits(try r.string());
    } else if (std.mem.eql(u8, algorithm, "ssh-dss")) blk: {
        const n = try mpBits(try r.string());
        for (0..3) |_| _ = try mpBits(try r.string());
        break :blk n;
    } else if (std.mem.startsWith(u8, algorithm, "ecdsa-sha2-")) blk: {
        const curve = try r.string();
        const n: u32 = if (std.mem.eql(u8, curve, "nistp256")) 256 else if (std.mem.eql(u8, curve, "nistp384")) 384 else if (std.mem.eql(u8, curve, "nistp521")) 521 else return error.UnsupportedKey;
        if (!std.mem.eql(u8, algorithm[11..], curve)) return error.InvalidKey;
        const point = try r.string();
        if (point.len != 1 + 2 * ((n + 7) / 8) or point[0] != 4) return error.InvalidKey;
        break :blk n;
    } else return error.UnsupportedKey;
    if (r.bytes.len != 0) return error.InvalidKey;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
    var fp: [43]u8 = undefined;
    _ = std.base64.standard_no_pad.Encoder.encode(&fp, &digest);
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(blob.len));
    defer a.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, blob);
    // Only displayable metadata crosses the helper boundary.
    const safe_comment = if (comment.len <= 1024 and cleanText(comment)) comment else "";
    return .{
        .algorithm = try a.dupe(u8, algorithm),
        .bits = bits,
        .fingerprint = try std.fmt.allocPrint(a, "SHA256:{s}", .{fp}),
        .public_key = try std.fmt.allocPrint(a, "{s} {s}{s}{s}\n", .{ algorithm, b64, if (safe_comment.len > 0) " " else "", safe_comment }),
        .comment = try a.dupe(u8, safe_comment),
    };
}
pub fn cleanText(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}
pub fn publicLine(a: A, bytes: []const u8) !model.Item {
    const line = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.indexOfAny(u8, line, "\r\n") != null) return error.InvalidKey;
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const algorithm = words.next() orelse return error.InvalidKey;
    const b64 = words.next() orelse return error.InvalidKey;
    const decoder = std.base64.standard.Decoder;
    const blob = try a.alloc(u8, try decoder.calcSizeForSlice(b64));
    defer a.free(blob);
    try decoder.decode(blob, b64);
    const item = try publicBlob(a, blob, std.mem.trim(u8, words.rest(), " \t"));
    if (!std.mem.eql(u8, algorithm, item.algorithm)) return error.InvalidKey;
    return item;
}
pub fn parse(a: A, bytes: []const u8) !Parsed {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const pkcs1 = std.mem.startsWith(u8, trimmed, "-----BEGIN RSA PRIVATE KEY-----");
    const pkcs8 = std.mem.startsWith(u8, trimmed, "-----BEGIN PRIVATE KEY-----");
    if (pkcs1 or pkcs8) {
        const raw = try pem.decode(a, trimmed, if (pkcs1) "RSA PRIVATE KEY" else "PRIVATE KEY");
        defer {
            std.crypto.secureZero(u8, raw);
            a.free(raw);
        }
        const blob = try @import("der.zig").rsaPublic(a, raw, pkcs8);
        defer a.free(blob);
        return .{ .item = try publicBlob(a, blob, ""), .private = true };
    }
    if (!std.mem.startsWith(u8, trimmed, "-----BEGIN OPENSSH PRIVATE KEY-----")) return .{ .item = try publicLine(a, trimmed) };
    const raw = try pem.decode(a, trimmed, "OPENSSH PRIVATE KEY");
    defer {
        std.crypto.secureZero(u8, raw);
        a.free(raw);
    }
    const magic = "openssh-key-v1\x00";
    if (!std.mem.startsWith(u8, raw, magic)) return error.InvalidKey;
    var r: Reader = .{ .bytes = raw[magic.len..] };
    const cipher = try r.string();
    const kdf = try r.string();
    const options = try r.string();
    const encrypted = !std.mem.eql(u8, cipher, "none");
    if (!encrypted and (!std.mem.eql(u8, kdf, "none") or options.len != 0)) return error.InvalidKey;
    if (encrypted and (std.mem.eql(u8, kdf, "none") or cipher.len == 0)) return error.InvalidKey;
    if (try r.int() != 1) return error.UnsupportedKey;
    var item = try publicBlob(a, try r.string(), "");
    var private: Reader = .{ .bytes = try r.string() };
    // AEAD formats carry a tag after the private string. Never interpret it.
    if (!encrypted) {
        const check = try private.int();
        if (check != try private.int()) return error.InvalidKey;
        if (!std.mem.eql(u8, try private.string(), item.algorithm)) return error.InvalidKey;
        const count: usize = if (std.mem.eql(u8, item.algorithm, "ssh-ed25519")) 2 else if (std.mem.eql(u8, item.algorithm, "ssh-rsa")) 6 else if (std.mem.eql(u8, item.algorithm, "ssh-dss")) 5 else 3;
        for (0..count) |_| _ = try private.string();
        const comment = try private.string();
        if (comment.len <= 1024 and cleanText(comment)) item.comment = try a.dupe(u8, comment);
        for (private.bytes, 0..) |byte, i| if (byte != (i + 1) % 256) return error.InvalidKey;
    }
    return .{ .item = item, .private = true, .encrypted = encrypted };
}
