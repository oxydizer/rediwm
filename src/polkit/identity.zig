//! Parse polkit identities and select through a replaceable NSS resolver.
const std = @import("std");
const wire = @import("dbus").wire;
pub const Account = extern struct {
    uid: u32,
    gid: u32,
    user: [256]u8 = @splat(0),
    name: [256]u8 = @splat(0),
    pub fn username(self: *const Account) []const u8 {
        return std.mem.sliceTo(&self.user, 0);
    }
};
extern fn rediwm_polkit_user(u32, *Account) c_int;
extern fn rediwm_polkit_member(u32, u32) c_int;
extern fn rediwm_polkit_group_user(u32, *Account) c_int;
pub const Entry = union(enum) { user: u32, group: u32 };
pub const Candidates = struct { entries: [128]Entry = undefined, len: usize = 0 };

pub fn parse(reader: *wire.Reader) !Candidates {
    var result: Candidates = .{};
    var list = try reader.array(8);
    while (list.offset < list.bytes.len) {
        try list.alignTo(8);
        const kind = try list.string();
        const user = std.mem.eql(u8, kind, "unix-user");
        const group = std.mem.eql(u8, kind, "unix-group");
        var fields = try list.array(8);
        var id: ?u32 = null;
        while (fields.offset < fields.bytes.len) {
            try fields.alignTo(8);
            const key = try fields.string();
            const sig = try fields.variant();
            if ((user and std.mem.eql(u8, key, "uid")) or (group and std.mem.eql(u8, key, "gid"))) {
                if (id != null or !std.mem.eql(u8, sig, "u")) return error.InvalidIdentity;
                id = try fields.uint32();
            } else try fields.skip(sig);
        }
        if (id) |value| {
            if (result.len == result.entries.len) return error.TooManyIdentities;
            result.entries[result.len] = if (user) .{ .user = value } else .{ .group = value };
            result.len += 1;
        }
    }
    return result;
}
pub fn pick(entries: []const Entry, resolver: anytype) !Account {
    for (entries) |entry| {
        const own = switch (entry) {
            .user => |uid| uid == resolver.uid,
            .group => |gid| resolver.member(resolver.uid, gid),
        };
        if (own) if (resolver.user(resolver.uid)) |account| return account;
    }
    for (entries) |entry| switch (entry) {
        .user => |uid| {
            if (resolver.user(uid)) |account| return account;
        },
        else => {},
    };
    for (entries) |entry| switch (entry) {
        .group => |gid| {
            if (resolver.group(gid)) |account| return account;
        },
        else => {},
    };
    return error.NoIdentity;
}
pub const System = struct {
    uid: u32,
    pub fn user(_: System, uid: u32) ?Account {
        var account: Account = undefined;
        return if (rediwm_polkit_user(uid, &account) == 0) account else null;
    }
    pub fn member(_: System, uid: u32, gid: u32) bool {
        return rediwm_polkit_member(uid, gid) != 0;
    }
    pub fn group(_: System, gid: u32) ?Account {
        var account: Account = undefined;
        return if (rediwm_polkit_group_user(gid, &account) == 0) account else null;
    }
};

test "identity selection prefers self, then users, then resolvable group members" {
    const Fake = struct {
        uid: u32 = 1000,
        pub fn user(_: @This(), uid: u32) ?Account {
            return if (uid == 9999) null else .{ .uid = uid, .gid = 100 };
        }
        pub fn member(_: @This(), uid: u32, gid: u32) bool {
            return uid == 1000 and gid == 10;
        }
        pub fn group(_: @This(), gid: u32) ?Account {
            return if (gid == 20) .{ .uid = 2000, .gid = gid } else null;
        }
    };
    const cases = .{
        .{ &[_]Entry{ .{ .user = 0 }, .{ .user = 1000 } }, @as(u32, 1000) },
        .{ &[_]Entry{ .{ .user = 0 }, .{ .group = 10 } }, @as(u32, 1000) },
        .{ &[_]Entry{ .{ .group = 20 }, .{ .user = 9999 }, .{ .user = 42 } }, @as(u32, 42) },
        .{ &[_]Entry{ .{ .group = 99 }, .{ .group = 20 } }, @as(u32, 2000) },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[1], (try pick(case[0], Fake{})).uid);
    try std.testing.expectError(error.NoIdentity, pick(&.{}, Fake{}));
    try std.testing.expectError(error.NoIdentity, pick(&.{ .{ .user = 9999 }, .{ .group = 99 } }, Fake{}));
}

test "identity parser skips unknown variants and rejects ambiguous uid fields" {
    const a = std.testing.allocator;
    var w: wire.Writer = .{ .allocator = a };
    defer w.deinit();
    const list = try w.beginArray(8);
    try w.alignTo(8);
    try w.string("unix-user");
    const dict = try w.beginArray(8);
    try w.alignTo(8);
    try w.string("extra");
    try w.variant("s");
    try w.string("ignored");
    try w.alignTo(8);
    try w.string("uid");
    try w.variant("u");
    try w.uint32(1000);
    try w.endArray(dict);
    try w.endArray(list);
    var r: wire.Reader = .{ .bytes = w.bytes.items };
    const result = try parse(&r);
    try r.done();
    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqual(1000, result.entries[0].user);

    w.bytes.clearRetainingCapacity();
    const bad_list = try w.beginArray(8);
    try w.alignTo(8);
    try w.string("unix-user");
    const bad_dict = try w.beginArray(8);
    for (0..2) |_| {
        try w.alignTo(8);
        try w.string("uid");
        try w.variant("u");
        try w.uint32(1000);
    }
    try w.endArray(bad_dict);
    try w.endArray(bad_list);
    r = .{ .bytes = w.bytes.items };
    try std.testing.expectError(error.InvalidIdentity, parse(&r));
}
