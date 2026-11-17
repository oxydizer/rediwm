//! Checks every value a request carries before the helper renders it into a
//! ruleset or a tool's argv. A value that passes contains no quotes, spaces,
//! braces, semicolons or newlines, so no renderer has to escape anything.
const std = @import("std");
const model = @import("model.zig");

/// "22", "8000-8100" (or "8000:8100"), or "" for any port. Lists are not
/// accepted from requests; the helper splits catalog services itself.
pub fn port(text: []const u8) bool {
    if (text.len == 0) return true;
    if (text.len > 11) return false;
    const sep = std.mem.indexOfAny(u8, text, "-:");
    if (sep) |i| {
        const lo = number(text[0..i]) orelse return false;
        const hi = number(text[i + 1 ..]) orelse return false;
        return lo < hi;
    }
    return number(text) != null;
}

fn number(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return null;
    const value = std.fmt.parseInt(u16, text, 10) catch return null;
    return if (value == 0) null else value;
}

/// An IPv4 or IPv6 address with an optional prefix length.
pub fn cidr(text: []const u8) bool {
    if (text.len == 0 or text.len > 43) return false;
    const slash = std.mem.indexOfScalar(u8, text, '/');
    const address = if (slash) |i| text[0..i] else text;
    const v6 = std.mem.indexOfScalar(u8, address, ':') != null;
    if (slash) |i| {
        const bits = std.fmt.parseInt(u8, text[i + 1 ..], 10) catch return false;
        if (text[i + 1 ..].len == 0 or text[i + 1 ..].len > 3) return false;
        if (bits > @as(u8, if (v6) 128 else 32)) return false;
    }
    if (v6) {
        _ = std.Io.net.Ip6Address.parse(address, 0) catch return false;
        return true;
    }
    _ = std.Io.net.Ip4Address.parse(address, 0) catch return false;
    return true;
}

pub fn isV6(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, ':') != null;
}

/// "" (anywhere), "lan", or an address.
pub fn source(text: []const u8) bool {
    return text.len == 0 or std.mem.eql(u8, text, "lan") or cidr(text);
}

/// A kernel interface name: 1–15 of [A-Za-z0-9._-], not starting with '-'.
pub fn iface(text: []const u8) bool {
    if (text.len == 0 or text.len > 15 or text[0] == '-' or text[0] == '.') return false;
    for (text) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return false;
    return true;
}

/// A service or application profile name: [A-Za-z0-9._+-], up to 48.
pub fn service(text: []const u8) bool {
    if (text.len == 0 or text.len > 48 or text[0] == '-') return false;
    for (text) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-' or ch == '+')) return false;
    return true;
}

/// Comments are free text but plain: up to 64 printable ASCII characters
/// without quotes, backslashes or anything a ruleset treats specially.
pub fn comment(text: []const u8) bool {
    if (text.len > 64) return false;
    for (text) |ch| {
        if (ch < 0x20 or ch > 0x7e) return false;
        if (std.mem.indexOfScalar(u8, "\"'\\`$;{}#", ch) != null) return false;
    }
    return true;
}

/// A NetworkManager connection uuid.
pub fn uuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// A whole rule from a request. A rule needs a port or a service, except an
/// address rule (`source` set, any port) which allows or blocks a host.
pub fn rule(r: model.Rule) bool {
    if (!port(r.port) or !source(r.source) or !comment(r.comment)) return false;
    if (r.service.len != 0 and !service(r.service)) return false;
    if (r.iface.len != 0 and !iface(r.iface)) return false;
    if (r.raw.len != 0) return false;
    if (r.port.len == 0 and r.service.len == 0 and r.source.len == 0) return false;
    if (r.port.len != 0 and r.proto == .both and r.action == .limit) return false;
    if (r.source.len != 0 and !std.mem.eql(u8, r.source, "lan")) {
        if (r.family == .v4 and isV6(r.source)) return false;
        if (r.family == .v6 and !isV6(r.source)) return false;
    }
    return true;
}

/// A rule sent back for deletion, as the helper listed it: its port may be a
/// list ("80,443", from a manager's service), and a rule we could not map
/// carries the manager's own text in `raw` (matched against the manager's
/// listing before use).
pub fn removal(r: model.Rule) bool {
    if (r.raw.len != 0) {
        if (r.raw.len > 512) return false;
        for (r.raw) |ch| if (ch < 0x20 or ch > 0x7e or std.mem.indexOfScalar(u8, "\\`$;", ch) != null) return false;
        return true;
    }
    if (r.port.len > 128) return false;
    var parts = std.mem.splitScalar(u8, r.port, ',');
    while (parts.next()) |part| if (!port(part) or (part.len == 0 and r.port.len != 0)) return false;
    var copy = r;
    copy.port = "";
    if (copy.service.len == 0 and copy.source.len == 0) copy.service = "x";
    return rule(copy);
}

test "ports" {
    try std.testing.expect(port("22"));
    try std.testing.expect(port("8000-8100"));
    try std.testing.expect(port("1714:1764"));
    try std.testing.expect(port(""));
    try std.testing.expect(!port("0"));
    try std.testing.expect(!port("65536"));
    try std.testing.expect(!port("100-50"));
    try std.testing.expect(!port("22 ; drop"));
    try std.testing.expect(!port("80,443"));
    try std.testing.expect(!port("-1"));
}

test "addresses" {
    try std.testing.expect(cidr("192.168.1.0/24"));
    try std.testing.expect(cidr("10.0.0.1"));
    try std.testing.expect(cidr("2001:db8::/32"));
    try std.testing.expect(cidr("fe80::1"));
    try std.testing.expect(!cidr("192.168.1.0/33"));
    try std.testing.expect(!cidr("2001:db8::/129"));
    try std.testing.expect(!cidr("300.1.1.1"));
    try std.testing.expect(!cidr("1.2.3.4/"));
    try std.testing.expect(!cidr("1.2.3.4 } accept"));
    try std.testing.expect(source("lan"));
    try std.testing.expect(source(""));
}

test "names and comments" {
    try std.testing.expect(iface("wlan0"));
    try std.testing.expect(iface("enp3s0f1.100"));
    try std.testing.expect(!iface("eth0\"; flush"));
    try std.testing.expect(!iface("-rf"));
    try std.testing.expect(!iface("abcdefghijklmnop"));
    try std.testing.expect(comment("Web server for the lab"));
    try std.testing.expect(!comment("a\" accept"));
    try std.testing.expect(!comment("x\ny"));
    try std.testing.expect(!comment("rm $(x)"));
    try std.testing.expect(service("OpenSSH"));
    try std.testing.expect(service("kdeconnect"));
    try std.testing.expect(!service("a b"));
    try std.testing.expect(uuid("0b6f2c55-1a4e-4c68-9d1d-2a5c4cbe1f00"));
    try std.testing.expect(!uuid("0b6f2c55-1a4e-4c68-9d1d-2a5c4cbe1f0z"));
}

test "removals" {
    try std.testing.expect(removal(.{ .port = "80,443", .service = "Nginx Full" }) == false);
    try std.testing.expect(removal(.{ .port = "80,443", .service = "nginx" }));
    try std.testing.expect(removal(.{ .raw = "rule family=\"ipv4\" source address=\"10.0.0.0/8\" accept" }));
    try std.testing.expect(!removal(.{ .raw = "x; rm" }));
    try std.testing.expect(!removal(.{ .port = "80,,443" }));
}

test "rules" {
    try std.testing.expect(rule(.{ .port = "22", .proto = .tcp }));
    try std.testing.expect(rule(.{ .service = "ssh" }));
    try std.testing.expect(rule(.{ .source = "203.0.113.9", .action = .deny }));
    try std.testing.expect(!rule(.{}));
    try std.testing.expect(!rule(.{ .port = "22", .raw = "x" }));
    try std.testing.expect(!rule(.{ .port = "22", .family = .v4, .source = "::1" }));
}
