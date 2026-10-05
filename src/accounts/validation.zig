//! Validation rules for account-management requests.
const std = @import("std");

pub fn validUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!(name[0] == '_' or (name[0] >= 'a' and name[0] <= 'z'))) return false;
    for (name[1..]) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-')) return false;
    }
    return true;
}

pub fn validGroupName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    return true;
}

pub fn validFullName(name: []const u8) bool {
    if (name.len > 256) return false;
    for (name) |ch| if (ch == ':' or ch == ',' or ch == 0 or ch < 0x20 or ch == 0x7f) return false;
    return true;
}

pub fn validPassword(password: []const u8) bool {
    if (password.len == 0 or password.len > 1024) return false;
    return std.mem.indexOfAny(u8, password, "\x00\r\n") == null;
}

pub fn validLoginUid(uid: u32, min: u32, max: u32) bool {
    return uid >= min and uid <= max;
}

/// Refuse operations that would leave no administrator or remove the caller's
/// own administrator access.
pub fn mayRemoveAdmin(target: []const u8, caller: []const u8, admin_count: usize) bool {
    if (admin_count <= 1) return false;
    return !std.mem.eql(u8, target, caller);
}

pub fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// Produces only the add/remove operations needed to reach the requested set.
/// The caller must separately verify every name exists and is permitted.
pub const GroupChange = struct { name: []const u8, add: bool };

pub fn diffGroups(a: std.mem.Allocator, current: []const []const u8, desired: []const []const u8) ![]GroupChange {
    var changes: std.ArrayList(GroupChange) = .empty;
    for (desired) |name| if (!containsName(current, name)) try changes.append(a, .{ .name = name, .add = true });
    for (current) |name| if (!containsName(desired, name)) try changes.append(a, .{ .name = name, .add = false });
    return changes.toOwnedSlice(a);
}
