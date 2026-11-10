const std = @import("std");
pub const max_file = 1 << 20;
pub const max_reply = 4 << 20;
pub const max_items = 1024;

pub const Location = struct {
    path: []const u8,
    private: bool,
    encrypted: bool = false,
    permissions: bool = false,
    missing_public: bool = false,
    mismatched_public: bool = false,
};
pub const Item = struct {
    fingerprint: []const u8,
    algorithm: []const u8,
    bits: u32,
    public_key: []const u8,
    comment: []const u8 = "",
    label: []const u8 = "",
    locations: []const Location = &.{},

    pub fn weak(self: Item) bool {
        return std.mem.eql(u8, self.algorithm, "ssh-dss") or
            (std.mem.eql(u8, self.algorithm, "ssh-rsa") and self.bits < 2048);
    }
};
pub const Inventory = struct {
    items: []const Item = &.{},
    skipped: usize = 0,
    directory_permissions: bool = false,
    keygen: bool = false,
    trash: bool = false,
};
