//! Fixed argv plans contain public metadata only. No shell and no -N/-P.
const std = @import("std");
const protocol = @import("protocol.zig");
const openssh = @import("openssh.zig");
pub fn validate(req: protocol.Request) !void {
    if (req.text.len > 512 or !openssh.cleanText(req.text)) return error.InvalidText;
    for ([_][]const u8{ req.old_passphrase, req.new_passphrase }) |secret| {
        if (secret.len > 512 or !openssh.cleanText(secret)) return error.InvalidPassphrase;
    }
}
pub fn argv(a: std.mem.Allocator, executable: []const u8, req: protocol.Request, staged: []const u8) ![]const []const u8 {
    try validate(req);
    return switch (req.action) {
        .generate => try a.dupe([]const u8, &.{ executable, "-q", "-t", "ed25519", "-C", req.text, "-f", staged }),
        .passphrase => try a.dupe([]const u8, &.{ executable, "-q", "-p", "-f", staged }),
        .comment => try a.dupe([]const u8, &.{ executable, "-q", "-c", "-C", req.text, "-f", staged }),
        else => error.InvalidAction,
    };
}
