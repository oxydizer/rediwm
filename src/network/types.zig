//! Small plain types shared by the NetworkManager client and its parsers.

const std = @import("std");

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, capacity);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn init(value: []const u8) @This() {
            var t: @This() = .{};
            t.set(value);
            return t;
        }
    };
}
pub const Path = Text(256);
pub const Security = enum { open, personal, sae, unsupported };
/// How a profile gets its addresses for one family.
pub const Method = enum { auto, manual, link_local, shared, disabled, other };
/// What NetworkManager assigned one interface for one address family (an
/// IP4Config or IP6Config object); addresses read "address/prefix".
pub const Config = struct {
    path: Path = .{},
    address: Text(256) = .{},
    gateway: Text(64) = .{},
    dns: Text(256) = .{},
    domains: Text(256) = .{},
};
pub const Link = struct { v4: Config = .{}, v6: Config = .{} };
