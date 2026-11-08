//! A saved connection as the editor shows it, read from NetworkManager's
//! `a{sa{sv}}` settings and written back. Only the keys the editor owns are
//! replaced; every other entry (secrets' flags, routes, 802.1x, ...) is copied
//! unchanged, and secrets themselves are never in `GetSettings` at all.

const std = @import("std");
const wire = @import("dbus").wire;
const types = @import("types.zig");
const props_mod = @import("manager_props.zig");
const Text = types.Text;
const Path = types.Path;
const Method = types.Method;
const eq = std.mem.eql;

pub const max_addresses = 4;
pub const Address = struct { text: Text(48) = .{}, prefix: u8 = 0 };
pub const Family = struct {
    method: Method = .auto,
    addresses: [max_addresses]Address = @splat(.{}),
    count: usize = 0,
    gateway: Text(48) = .{},
    /// This family's own servers, comma separated.
    dns: Text(192) = .{},
    ignore_auto_dns: bool = false,
};
pub const Profile = struct {
    path: Path = .{},
    id: Text(64) = .{},
    kind: Text(32) = .{},
    autoconnect: bool = true,
    /// NMMetered: 0 decided by NetworkManager, 1 yes, 2 no.
    metered: i32 = 0,
    /// 0 leaves the size to the driver.
    mtu: u32 = 0,
    v4: Family = .{},
    v6: Family = .{},

    fn mtuSection(self: *const Profile) []const u8 {
        return if (eq(u8, self.kind.slice(), "802-11-wireless")) "802-11-wireless" else "802-3-ethernet";
    }
};

pub fn methodText(method: Method, v6: bool) []const u8 {
    return switch (method) {
        .auto => "auto",
        .manual => "manual",
        .link_local => "link-local",
        .shared => "shared",
        .disabled => if (v6) "disabled" else "disabled",
        .other => "auto",
    };
}

pub fn parseMethod(value: []const u8) Method {
    if (eq(u8, value, "auto") or eq(u8, value, "dhcp")) return .auto;
    if (eq(u8, value, "manual")) return .manual;
    if (eq(u8, value, "link-local")) return .link_local;
    if (eq(u8, value, "shared")) return .shared;
    if (eq(u8, value, "disabled") or eq(u8, value, "ignore")) return .disabled;
    return .other;
}

// ---- reading -------------------------------------------------------------

pub fn parse(settings: *wire.Reader, path: []const u8) !Profile {
    var out: Profile = .{ .path = Path.init(path) };
    var sections = try settings.array(8);
    while (sections.offset < sections.bytes.len) {
        try sections.alignTo(8);
        const section = try sections.string();
        var props = try sections.array(8);
        while (props.offset < props.bytes.len) {
            try props.alignTo(8);
            const key = try props.string();
            const sig = try props.variant();
            try readProperty(&out, section, key, sig, &props);
        }
    }
    return out;
}

fn readProperty(out: *Profile, section: []const u8, key: []const u8, sig: []const u8, props: *wire.Reader) !void {
    if (eq(u8, section, "connection")) {
        if (eq(u8, key, "id") and eq(u8, sig, "s")) return out.id.set(try props.string());
        if (eq(u8, key, "type") and eq(u8, sig, "s")) return out.kind.set(try props.string());
        if (eq(u8, key, "autoconnect") and eq(u8, sig, "b")) {
            out.autoconnect = try props.boolean();
            return;
        }
        if (eq(u8, key, "metered") and eq(u8, sig, "i")) {
            out.metered = try props.int(i32);
            return;
        }
    } else if (eq(u8, section, "ipv4") or eq(u8, section, "ipv6")) {
        const v6 = eq(u8, section, "ipv6");
        const family = if (v6) &out.v6 else &out.v4;
        if (eq(u8, key, "method") and eq(u8, sig, "s")) {
            family.method = parseMethod(try props.string());
            return;
        }
        if (eq(u8, key, "address-data") and eq(u8, sig, "aa{sv}")) return readAddresses(family, props);
        if (eq(u8, key, "gateway") and eq(u8, sig, "s")) return family.gateway.set(try props.string());
        if (eq(u8, key, "ignore-auto-dns") and eq(u8, sig, "b")) {
            family.ignore_auto_dns = try props.boolean();
            return;
        }
        if (!v6 and eq(u8, key, "dns") and eq(u8, sig, "au")) {
            var list = try props.array(4);
            while (list.offset < list.bytes.len) {
                const value = try list.uint32();
                const bytes: [4]u8 = @bitCast(value);
                var text: [16]u8 = undefined;
                props_mod.append(&family.dns, std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch continue);
            }
            return;
        }
        if (v6 and eq(u8, key, "dns") and eq(u8, sig, "aay")) {
            var list = try props.array(4);
            while (list.offset < list.bytes.len) {
                var bytes = try list.array(1);
                const data = try bytes.take(bytes.bytes.len - bytes.offset);
                if (data.len != 16) continue;
                var text: [48]u8 = undefined;
                props_mod.append(&family.dns, props_mod.formatIp6(&text, data[0..16].*));
            }
            return;
        }
    } else if (eq(u8, section, "802-3-ethernet") or eq(u8, section, "802-11-wireless")) {
        if (eq(u8, key, "mtu") and eq(u8, sig, "u")) {
            out.mtu = try props.uint32();
            return;
        }
    }
    try props.skip(sig);
}

fn readAddresses(family: *Family, props: *wire.Reader) !void {
    var list = try props.array(4);
    while (list.offset < list.bytes.len) {
        var entries = try list.array(8);
        var address: Address = .{};
        while (entries.offset < entries.bytes.len) {
            try entries.alignTo(8);
            const key = try entries.string();
            const sig = try entries.variant();
            if (eq(u8, key, "address") and eq(u8, sig, "s")) address.text.set(try entries.string()) else if (eq(u8, key, "prefix") and eq(u8, sig, "u")) address.prefix = @intCast(@min(try entries.uint32(), 255)) else try entries.skip(sig);
        }
        if (address.text.len != 0 and family.count < max_addresses) {
            family.addresses[family.count] = address;
            family.count += 1;
        }
    }
}

// ---- writing -------------------------------------------------------------

const Kind = enum { connection, v4, v6, mtu, other };

fn beginSection(b: *wire.Writer, name: []const u8) !wire.Writer.Array {
    try b.alignTo(8);
    try b.string(name);
    return b.beginArray(8);
}

fn prop(b: *wire.Writer, name: []const u8, sig: []const u8) !void {
    try b.alignTo(8);
    try b.string(name);
    try b.variant(sig);
}

fn classify(name: []const u8, p: *const Profile) Kind {
    if (eq(u8, name, "connection")) return .connection;
    if (eq(u8, name, "ipv4") and p.v4.method != .other) return .v4;
    if (eq(u8, name, "ipv6") and p.v6.method != .other) return .v6;
    if (eq(u8, name, p.mtuSection())) return .mtu;
    return .other;
}

fn owned(kind: Kind, key: []const u8) bool {
    const keys: []const []const u8 = switch (kind) {
        .connection => &.{ "autoconnect", "metered" },
        .v4, .v6 => &.{ "method", "address-data", "addresses", "gateway", "dns", "dns-data", "ignore-auto-dns" },
        .mtu => &.{"mtu"},
        .other => return false,
    };
    for (keys) |name| if (eq(u8, name, key)) return true;
    return false;
}

fn writeOwned(b: *wire.Writer, kind: Kind, p: *const Profile) !void {
    switch (kind) {
        .connection => {
            try prop(b, "autoconnect", "b");
            try b.boolean(p.autoconnect);
            if (p.metered != 0) {
                try prop(b, "metered", "i");
                try b.int(i32, p.metered);
            }
        },
        .v4, .v6 => try writeFamily(b, if (kind == .v6) &p.v6 else &p.v4, kind == .v6),
        .mtu => if (p.mtu != 0) {
            try prop(b, "mtu", "u");
            try b.uint32(p.mtu);
        },
        .other => {},
    }
}

fn writeFamily(b: *wire.Writer, f: *const Family, v6: bool) !void {
    try prop(b, "method", "s");
    try b.string(methodText(f.method, v6));
    if (f.method == .manual and f.count != 0) {
        try prop(b, "address-data", "aa{sv}");
        const list = try b.beginArray(4);
        for (f.addresses[0..f.count]) |address| {
            const dict = try b.beginArray(8);
            try prop(b, "address", "s");
            try b.string(address.text.slice());
            try prop(b, "prefix", "u");
            try b.uint32(address.prefix);
            try b.endArray(dict);
        }
        try b.endArray(list);
        if (f.gateway.len != 0) {
            try prop(b, "gateway", "s");
            try b.string(f.gateway.slice());
        }
    }
    if (f.dns.len != 0) {
        try prop(b, "dns", if (v6) "aay" else "au");
        const list = try b.beginArray(4);
        var items = std.mem.tokenizeAny(u8, f.dns.slice(), ", ");
        while (items.next()) |item| {
            if (v6) {
                const address = std.Io.net.Ip6Address.parse(item, 0) catch return error.InvalidDns;
                const bytes = try b.beginArray(1);
                try b.raw(&address.bytes);
                try b.endArray(bytes);
            } else {
                const address = std.Io.net.Ip4Address.parse(item, 0) catch return error.InvalidDns;
                try b.uint32(@bitCast(address.bytes));
            }
        }
        try b.endArray(list);
    }
    if (f.ignore_auto_dns) {
        try prop(b, "ignore-auto-dns", "b");
        try b.boolean(true);
    }
}

/// Copies `settings` into `b`, replacing what the editor owns with `p`.
pub fn write(settings: *wire.Reader, b: *wire.Writer, p: *const Profile) !void {
    b.endian = settings.endian;
    const all = try b.beginArray(8);
    var seen: [5]bool = @splat(false);
    var sections = try settings.array(8);
    while (sections.offset < sections.bytes.len) {
        try sections.alignTo(8);
        const name = try sections.string();
        const kind = classify(name, p);
        seen[@intFromEnum(kind)] = true;
        const out = try beginSection(b, name);
        var entries = try sections.array(8);
        while (entries.offset < entries.bytes.len) {
            try entries.alignTo(8);
            const start = entries.offset;
            const key = try entries.string();
            const sig = try entries.variant();
            try entries.skip(sig);
            if (owned(kind, key)) continue;
            try b.alignTo(8);
            try b.raw(entries.bytes[start..entries.offset]);
        }
        try writeOwned(b, kind, p);
        try b.endArray(out);
    }
    // A profile may lack a section the editor sets (no ipv6 yet, no mtu).
    const missing = [_]struct { kind: Kind, name: []const u8 }{
        .{ .kind = .connection, .name = "connection" },
        .{ .kind = .v4, .name = "ipv4" },
        .{ .kind = .v6, .name = "ipv6" },
        .{ .kind = .mtu, .name = p.mtuSection() },
    };
    for (missing) |m| {
        if (seen[@intFromEnum(m.kind)]) continue;
        if (m.kind == .v4 and p.v4.method == .other) continue;
        if (m.kind == .v6 and p.v6.method == .other) continue;
        if (m.kind == .mtu and p.mtu == 0) continue;
        const out = try beginSection(b, m.name);
        try writeOwned(b, m.kind, p);
        try b.endArray(out);
    }
    try b.endArray(all);
}

// ---- tests ---------------------------------------------------------------

fn sample(b: *wire.Writer) !void {
    const all = try b.beginArray(8);
    const connection = try beginSection(b, "connection");
    try prop(b, "id", "s");
    try b.string("Studio_5G");
    try prop(b, "type", "s");
    try b.string("802-11-wireless");
    try prop(b, "autoconnect", "b");
    try b.boolean(true);
    try b.endArray(connection);
    const wifi = try beginSection(b, "802-11-wireless");
    try prop(b, "ssid", "ay");
    const ssid = try b.beginArray(1);
    try b.raw("Studio_5G");
    try b.endArray(ssid);
    try b.endArray(wifi);
    const security = try beginSection(b, "802-11-wireless-security");
    try prop(b, "key-mgmt", "s");
    try b.string("wpa-psk");
    try prop(b, "psk-flags", "u");
    try b.uint32(0);
    try b.endArray(security);
    const ip4 = try beginSection(b, "ipv4");
    try prop(b, "method", "s");
    try b.string("auto");
    try b.endArray(ip4);
    try b.endArray(all);
}

test "editing a profile keeps what the editor does not own" {
    var original: wire.Writer = .{ .allocator = std.testing.allocator };
    defer original.deinit();
    try sample(&original);
    var reader: wire.Reader = .{ .bytes = original.bytes.items };
    var profile = try parse(&reader, "/p/1");
    try std.testing.expectEqualStrings("Studio_5G", profile.id.slice());
    try std.testing.expect(profile.autoconnect and profile.v4.method == .auto and profile.v6.method == .auto);

    profile.autoconnect = false;
    profile.metered = 1;
    profile.mtu = 1400;
    profile.v4.method = .manual;
    profile.v4.addresses[0] = .{ .text = Text(48).init("10.0.0.5"), .prefix = 24 };
    profile.v4.count = 1;
    profile.v4.gateway.set("10.0.0.1");
    profile.v4.dns.set("1.1.1.1, 9.9.9.9");
    profile.v4.ignore_auto_dns = true;
    profile.v6.method = .manual;
    profile.v6.addresses[0] = .{ .text = Text(48).init("2001:db8::5"), .prefix = 64 };
    profile.v6.count = 1;
    profile.v6.dns.set("2001:db8::53");

    var edited: wire.Writer = .{ .allocator = std.testing.allocator };
    defer edited.deinit();
    reader = .{ .bytes = original.bytes.items };
    try write(&reader, &edited, &profile);
    // Untouched entries survive byte for byte, and no secret was invented.
    try std.testing.expect(std.mem.indexOf(u8, edited.bytes.items, "key-mgmt") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited.bytes.items, "psk-flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited.bytes.items, "Studio_5G") != null);

    var again: wire.Reader = .{ .bytes = edited.bytes.items };
    const back = try parse(&again, "/p/1");
    try std.testing.expect(!back.autoconnect);
    try std.testing.expectEqual(@as(i32, 1), back.metered);
    try std.testing.expectEqual(@as(u32, 1400), back.mtu);
    try std.testing.expect(back.v4.method == .manual and back.v4.count == 1);
    try std.testing.expectEqualStrings("10.0.0.5", back.v4.addresses[0].text.slice());
    try std.testing.expectEqual(@as(u8, 24), back.v4.addresses[0].prefix);
    try std.testing.expectEqualStrings("10.0.0.1", back.v4.gateway.slice());
    try std.testing.expectEqualStrings("1.1.1.1, 9.9.9.9", back.v4.dns.slice());
    try std.testing.expect(back.v4.ignore_auto_dns);
    try std.testing.expect(back.v6.method == .manual);
    try std.testing.expectEqualStrings("2001:db8::5", back.v6.addresses[0].text.slice());
    try std.testing.expectEqualStrings("2001:db8::53", back.v6.dns.slice());

    // Going back to automatic drops the addresses and the gateway.
    var auto = back;
    auto.v4.method = .auto;
    auto.v4.dns = .{};
    auto.v4.ignore_auto_dns = false;
    var third: wire.Writer = .{ .allocator = std.testing.allocator };
    defer third.deinit();
    var second: wire.Reader = .{ .bytes = edited.bytes.items };
    try write(&second, &third, &auto);
    var last: wire.Reader = .{ .bytes = third.bytes.items };
    const final = try parse(&last, "/p/1");
    try std.testing.expect(final.v4.method == .auto and final.v4.count == 0 and final.v4.gateway.len == 0 and final.v4.dns.len == 0);
    try std.testing.expect(final.v6.method == .manual);
}

test "an unrecognised method leaves that family untouched" {
    var original: wire.Writer = .{ .allocator = std.testing.allocator };
    defer original.deinit();
    const all = try original.beginArray(8);
    const ip4 = try beginSection(&original, "ipv4");
    try prop(&original, "method", "s");
    try original.string("shared");
    try original.endArray(ip4);
    try original.endArray(all);
    var reader: wire.Reader = .{ .bytes = original.bytes.items };
    var profile = try parse(&reader, "/p/2");
    try std.testing.expect(profile.v4.method == .shared);
    profile.v4.method = .other;
    var out: wire.Writer = .{ .allocator = std.testing.allocator };
    defer out.deinit();
    reader = .{ .bytes = original.bytes.items };
    try write(&reader, &out, &profile);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes.items, "shared") != null);
}
