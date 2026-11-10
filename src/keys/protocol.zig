const model = @import("model.zig");
pub const Action = enum { scan, generate, passphrase, comment, label, recreate_public, permissions, trash };
/// Only old_passphrase and new_passphrase are sensitive. Encode/decode this
/// structure in locked memory, never an arena, argv, environment or log.
pub const Request = struct {
    action: Action = .scan,
    path: []const u8 = "",
    fingerprint: []const u8 = "",
    text: []const u8 = "",
    old_passphrase: []const u8 = "",
    new_passphrase: []const u8 = "",
};
pub const Reply = struct {
    inventory: model.Inventory = .{},
    failure: ?[]const u8 = null,
};
