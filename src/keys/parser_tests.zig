const std = @import("std");
const ssh = @import("openssh.zig");
const ops = @import("ops.zig");

test "public fingerprints are over the wire blob and malformed lengths fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blob = "\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const key = try ssh.publicBlob(a, blob, "test");
    try std.testing.expectEqualStrings("ssh-ed25519", key.algorithm);
    const round = try ssh.publicLine(a, key.public_key);
    try std.testing.expectEqualStrings(key.fingerprint, round.fingerprint);
    try std.testing.expectError(error.Truncated, ssh.publicBlob(a, blob[0 .. blob.len - 1], ""));
    try std.testing.expectError(error.InvalidKey, ssh.publicBlob(a, blob ++ "\x00", ""));
    try std.testing.expectError(error.InvalidKey, ssh.publicLine(a, try std.fmt.allocPrint(a, "{s}{s}", .{ key.public_key, key.public_key })));
}
test "operation plans never carry passphrases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const actions = @import("protocol.zig").Action;
    for ([_]actions{ .generate, .passphrase, .comment }) |action| {
        const argv = try ops.argv(arena.allocator(), "/bin/ssh-keygen", .{ .action = action, .text = "example", .old_passphrase = "super-secret-old", .new_passphrase = "super-secret-new" }, "/tmp/stage/key");
        for (argv) |arg| {
            try std.testing.expect(std.mem.indexOf(u8, arg, "super-secret") == null);
            try std.testing.expect(!std.mem.eql(u8, arg, "-N") and !std.mem.eql(u8, arg, "-P"));
        }
    }
}
test "truncated hostile corpus never succeeds as a private key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rng = std.Random.DefaultPrng.init(42);
    var bytes: [256]u8 = undefined;
    for (0..1024) |i| {
        rng.random().bytes(&bytes);
        const raw = bytes[0 .. i % bytes.len];
        if (ssh.parse(arena.allocator(), raw)) |_| return error.UnexpectedKey else |_| {}
        var encoded: [344]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&encoded, raw);
        for ([_][]const u8{ "OPENSSH PRIVATE KEY", "RSA PRIVATE KEY", "PRIVATE KEY" }) |label| {
            const armored = try std.fmt.allocPrint(arena.allocator(), "-----BEGIN {s}-----\n{s}\n-----END {s}-----\n", .{ label, b64, label });
            if (ssh.parse(arena.allocator(), armored)) |_| return error.UnexpectedKey else |_| {}
        }
    }
}
test "DER rejects indefinite, overflowing and truncated lengths" {
    const Reader = @import("der.zig").Reader;
    for ([_][]const u8{ "\x30\x80", "\x30\x85\xff\xff\xff\xff\xff", "\x30\x84\xff\xff\xff\xff", "\x30\x03\x00" }) |bytes| {
        var reader: Reader = .{ .bytes = bytes };
        try std.testing.expectError(error.InvalidDer, reader.value(0x30));
    }
}
