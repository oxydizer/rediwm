//! Reading the properties of NetworkManager's IP configuration objects (IPv4
//! and IPv6) and formatting addresses as text.

const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const eq = std.mem.eql;
const types = @import("types.zig");
const Text = types.Text;
const Config = types.Config;

/// Adds `value` to a comma separated list, dropping what does not fit.
pub fn append(out: anytype, value: []const u8) void {
    const separator: []const u8 = if (out.len == 0) "" else ", ";
    if (out.len + separator.len + value.len > out.bytes.len) return;
    @memcpy(out.bytes[out.len..][0..separator.len], separator);
    out.len += separator.len;
    @memcpy(out.bytes[out.len..][0..value.len], value);
    out.len += value.len;
}

/// RFC 5952 text for an IPv6 address: lowercase, no leading zeros, and the
/// longest run of zero groups (two or more) written as "::".
pub fn formatIp6(buffer: *[48]u8, bytes: [16]u8) []const u8 {
    var groups: [8]u16 = undefined;
    for (&groups, 0..) |*g, i| g.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .big);
    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best_start = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best_start = 8;
    var len: usize = 0;
    i = 0;
    while (i < 8) {
        if (i == best_start) {
            buffer[len] = ':';
            buffer[len + 1] = ':';
            len += 2;
            i += best_len;
            continue;
        }
        if (len > 0 and buffer[len - 1] != ':') {
            buffer[len] = ':';
            len += 1;
        }
        len += (std.fmt.bufPrint(buffer[len..], "{x}", .{groups[i]}) catch return buffer[0..len]).len;
        i += 1;
    }
    return buffer[0..len];
}

/// An `aa{sv}` list of {address, prefix}, as "address/prefix" separated by commas.
pub fn addressList(b: *wire.Reader, with_prefix: bool) !Text(256) {
    var out: Text(256) = .{};
    var list = try b.array(4);
    while (list.offset < list.bytes.len) {
        var entries = try list.array(8);
        var address: []const u8 = "";
        var prefix: ?u32 = null;
        while (entries.offset < entries.bytes.len) {
            try entries.alignTo(8);
            const key = try entries.string();
            const sig = try entries.variant();
            if (eq(u8, key, "address") and eq(u8, sig, "s")) address = try entries.string() else if (eq(u8, key, "prefix") and eq(u8, sig, "u")) prefix = try entries.uint32() else try entries.skip(sig);
        }
        if (address.len == 0) continue;
        var text: [96]u8 = undefined;
        const value = if (with_prefix and prefix != null) std.fmt.bufPrint(&text, "{s}/{d}", .{ address, prefix.? }) catch address else address;
        append(&out, value);
    }
    return out;
}

/// An `as` list joined with commas.
pub fn stringList(b: *wire.Reader) !Text(256) {
    var out: Text(256) = .{};
    var list = try b.array(4);
    while (list.offset < list.bytes.len) append(&out, try list.string());
    return out;
}

/// IPv6 `Nameservers`: an `aay` of 16-byte addresses.
pub fn nameservers6(b: *wire.Reader) !Text(256) {
    var out: Text(256) = .{};
    var list = try b.array(4);
    while (list.offset < list.bytes.len) {
        var bytes = try list.array(1);
        const data = try bytes.take(bytes.bytes.len - bytes.offset);
        if (data.len != 16) continue;
        var text: [48]u8 = undefined;
        append(&out, formatIp6(&text, data[0..16].*));
    }
    return out;
}

/// One property of an IP4Config or IP6Config object. Returns false when the
/// key is not one we keep, and the caller must skip the value.
pub fn ipProperty(cfg: *Config, v6: bool, key: []const u8, sig: []const u8, props: *wire.Reader) !bool {
    if (eq(u8, key, "Gateway") and eq(u8, sig, "s")) {
        cfg.gateway.set(try props.string());
    } else if (eq(u8, key, "AddressData") and eq(u8, sig, "aa{sv}")) {
        cfg.address = try addressList(props, true);
    } else if (!v6 and eq(u8, key, "NameserverData") and eq(u8, sig, "aa{sv}")) {
        cfg.dns = try addressList(props, false);
    } else if (v6 and eq(u8, key, "Nameservers") and eq(u8, sig, "aay")) {
        cfg.dns = try nameservers6(props);
    } else if (eq(u8, key, "Searches") and eq(u8, sig, "as")) {
        cfg.domains = try stringList(props);
    } else return false;
    return true;
}

test "IPv6 text follows RFC 5952" {
    var buffer: [48]u8 = undefined;
    const cases = [_]struct { bytes: [16]u8, text: []const u8 }{
        .{ .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .text = "2001:db8::1" },
        .{ .bytes = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x1b, 0x63, 0xff, 0xfe, 0x94, 0x7a, 0xb2 }, .text = "fe80::21b:63ff:fe94:7ab2" },
        .{ .bytes = @splat(0), .text = "::" },
        .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .text = "::1" },
        .{ .bytes = .{ 0x20, 0x01, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 }, .text = "2001:0:1:0:1:0:1:1" },
        .{ .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, .text = "2001:db8:0:1::1" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.text, formatIp6(&buffer, case.bytes));
}
