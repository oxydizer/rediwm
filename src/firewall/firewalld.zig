//! firewalld through `firewall-cmd`, which the helper runs as root: the zone
//! listing (`--list-all`), the active zones and service definitions (their
//! XML), and the rich rules we write for what plain services and ports cannot
//! say (a source, a block, a rate limit). Our two trust levels map to two
//! zones: the default zone (Public) and `home`. A rule "everywhere" is in
//! both.
const std = @import("std");
const model = @import("model.zig");
const services = @import("services.zig");
const Allocator = std.mem.Allocator;

pub const home_zone = "home";
pub const service_dirs = [_][]const u8{ "/etc/firewalld/services", "/usr/lib/firewalld/services" };

pub const Zone = struct {
    name: []const u8 = "",
    target: []const u8 = "default",
    services: []const []const u8 = &.{},
    ports: []const []const u8 = &.{},
    interfaces: []const []const u8 = &.{},
    icmp_blocks: []const []const u8 = &.{},
    icmp_inversion: bool = false,
    rich: []const []const u8 = &.{},
};

fn words(a: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |word| try list.append(a, word);
    return list.toOwnedSlice(a);
}

/// `firewall-cmd --zone=Z --list-all`.
pub fn parseZone(a: Allocator, text: []const u8) !Zone {
    var zone: Zone = .{};
    var rich: std.ArrayList([]const u8) = .empty;
    var in_rich = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            zone.name = if (std.mem.indexOfScalar(u8, line, ' ')) |i| line[0..i] else line;
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t");
        if (in_rich and std.mem.startsWith(u8, trimmed, "rule ")) {
            try rich.append(a, trimmed);
            continue;
        }
        in_rich = false;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = trimmed[0..colon];
        const rest = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "target")) zone.target = rest;
        if (std.mem.eql(u8, key, "services")) zone.services = try words(a, rest);
        if (std.mem.eql(u8, key, "ports")) zone.ports = try words(a, rest);
        if (std.mem.eql(u8, key, "interfaces")) zone.interfaces = try words(a, rest);
        if (std.mem.eql(u8, key, "icmp-blocks")) zone.icmp_blocks = try words(a, rest);
        if (std.mem.eql(u8, key, "icmp-block-inversion")) zone.icmp_inversion = std.mem.eql(u8, rest, "yes");
        if (std.mem.eql(u8, key, "rich rules")) {
            in_rich = true;
            if (rest.len != 0) try rich.append(a, rest);
        }
    }
    zone.rich = try rich.toOwnedSlice(a);
    return zone;
}

pub const Active = struct { zone: []const u8, iface: []const u8 };

/// `firewall-cmd --get-active-zones`: zone lines, then indented
/// "interfaces: a b" (a zone line may carry " (default)").
pub fn parseActive(a: Allocator, text: []const u8) ![]Active {
    var list: std.ArrayList(Active) = .empty;
    var zone: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            zone = if (std.mem.indexOfScalar(u8, line, ' ')) |i| line[0..i] else line;
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "interfaces:")) continue;
        var it = std.mem.tokenizeAny(u8, trimmed["interfaces:".len..], " \t");
        while (it.next()) |iface| try list.append(a, .{ .zone = zone, .iface = iface });
    }
    return list.toOwnedSlice(a);
}

/// Ports of a service definition: each `<port protocol="tcp" port="22"/>`.
pub fn servicePorts(a: Allocator, xml: []const u8) ![]services.Port {
    var list: std.ArrayList(services.Port) = .empty;
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<port ")) |start| {
        const end = std.mem.indexOfScalarPos(u8, rest, start, '>') orelse break;
        const tag = rest[start..end];
        rest = rest[end..];
        const port = attribute(tag, "port") orelse continue;
        const proto = attribute(tag, "protocol") orelse continue;
        try list.append(a, .{ .proto = if (std.mem.eql(u8, proto, "udp")) .udp else .tcp, .port = port });
    }
    return list.toOwnedSlice(a);
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var buffer: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, " {s}=\"", .{name}) catch return null;
    const i = std.mem.indexOf(u8, tag, needle) orelse return null;
    const start = i + needle.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

fn portRule(entry: []const u8) ?model.Rule {
    const slash = std.mem.indexOfScalar(u8, entry, '/') orelse return null;
    const proto = entry[slash + 1 ..];
    return .{ .port = entry[0..slash], .proto = if (std.mem.eql(u8, proto, "tcp")) .tcp else if (std.mem.eql(u8, proto, "udp")) .udp else return null };
}

/// A rich rule we can show as a plain rule; anything else stays `raw`.
pub fn parseRich(a: Allocator, text: []const u8) model.Rule {
    var rule: model.Rule = .{ .raw = text };
    if (attribute(text, "family")) |family| rule.family = if (std.mem.eql(u8, family, "ipv6")) .v6 else .v4;
    if (std.mem.indexOf(u8, text, "source address=\"")) |_| {
        if (attribute(text, "address")) |address| rule.source = address;
    }
    if (std.mem.indexOf(u8, text, " service name=\"") != null) {
        if (attribute(text, "name")) |name| rule.service = name;
    } else if (std.mem.indexOf(u8, text, " port port=\"") != null) {
        if (attribute(text, "port")) |port| rule.port = port;
        if (attribute(text, "protocol")) |proto| rule.proto = if (std.mem.eql(u8, proto, "udp")) .udp else .tcp;
    }
    if (std.mem.endsWith(u8, text, " drop")) rule.action = .deny else if (std.mem.endsWith(u8, text, " reject")) rule.action = .reject else if (std.mem.indexOf(u8, text, " accept limit ") != null) rule.action = .limit;
    if (std.mem.indexOf(u8, text, " not ") != null or std.mem.indexOf(u8, text, " log") != null or std.mem.indexOf(u8, text, " destination ") != null) return rule;
    _ = a;
    return rule;
}

/// The page's rules for the two zones: a service, port or rich rule in both
/// is "everywhere", one only in `home` is home-only.
pub fn rules(a: Allocator, public: Zone, home: ?Zone) ![]model.Rule {
    var list: std.ArrayList(model.Rule) = .empty;
    const zones = [_]?Zone{ public, home };
    for (zones, 0..) |maybe, zi| {
        const zone = maybe orelse continue;
        const in_home = zi == 1;
        for (zone.services) |name| {
            if (in_home and contains(public.services, name)) continue;
            var rule: model.Rule = .{ .service = name, .scope = if (in_home) .home else .everywhere };
            if (services.find(name)) |s| if (s.ports.len == 1) {
                rule.port = s.ports[0].port;
                rule.proto = s.ports[0].proto;
            };
            try list.append(a, rule);
        }
        for (zone.ports) |entry| {
            if (in_home and contains(public.ports, entry)) continue;
            var rule = portRule(entry) orelse continue;
            rule.scope = if (in_home) .home else .everywhere;
            if (services.named(rule.proto, rule.port)) |s| rule.service = s.id;
            try list.append(a, rule);
        }
        for (zone.rich) |text| {
            if (in_home and contains(public.rich, text)) continue;
            var rule = parseRich(a, text);
            rule.scope = if (in_home) .home else .everywhere;
            try list.append(a, rule);
        }
    }
    for (list.items, 0..) |*rule, i| rule.id = @intCast(i);
    return list.toOwnedSlice(a);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

pub fn incoming(zone_target: []const u8) model.Policy {
    if (std.mem.eql(u8, zone_target, "ACCEPT")) return .accept;
    if (std.mem.eql(u8, zone_target, "DROP")) return .drop;
    return .reject;
}

pub fn target(p: model.Policy) []const u8 {
    return switch (p) {
        .accept => "ACCEPT",
        .drop => "DROP",
        .reject => "default",
    };
}

pub fn pingAllowed(zone: Zone) bool {
    const blocked = contains(zone.icmp_blocks, "echo-request");
    return if (zone.icmp_inversion) blocked else !blocked;
}

pub fn logging(word: []const u8) model.Logging {
    const w = std.mem.trim(u8, word, " \n");
    if (std.mem.eql(u8, w, "off") or w.len == 0) return .off;
    if (std.mem.eql(u8, w, "all")) return .high;
    if (std.mem.eql(u8, w, "unicast")) return .low;
    return .medium;
}

pub fn logWord(level: model.Logging) []const u8 {
    return switch (level) {
        .off => "off",
        .low => "unicast",
        .medium => "broadcast",
        .high => "all",
    };
}

const lan4 = [_][]const u8{ "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16" };
const lan6 = [_][]const u8{ "fc00::/7", "fe80::/10" };

/// The `firewall-cmd` arguments (without --zone/--permanent) that add `rule`
/// (or remove it, `delete`). Plain services and ports where possible, rich
/// rules for sources, blocks and limits.
pub fn arguments(a: Allocator, rule: model.Rule, delete: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const verb = if (delete) "remove" else "add";
    if (rule.raw.len != 0) {
        try out.append(a, try std.fmt.allocPrint(a, "--{s}-rich-rule={s}", .{ verb, rule.raw }));
        return out.toOwnedSlice(a);
    }
    const plain = rule.source.len == 0 and rule.action == .allow and rule.family == .both and rule.direction == .in and rule.iface.len == 0;
    const catalog = services.find(rule.service);
    const fw_name: []const u8 = if (catalog) |s| s.firewalld orelse s.id else rule.service;
    if (plain and rule.port.len == 0 and fw_name.len != 0) {
        try out.append(a, try std.fmt.allocPrint(a, "--{s}-service={s}", .{ verb, fw_name }));
        return out.toOwnedSlice(a);
    }
    var buffer: [8]services.Port = undefined;
    const ports = @import("own.zig").expand(rule, &buffer);
    if (plain) {
        for (ports) |p| {
            const protos: []const []const u8 = switch (p.proto) {
                .tcp => &.{"tcp"},
                .udp => &.{"udp"},
                .both => &.{ "tcp", "udp" },
            };
            for (protos) |proto| try out.append(a, try std.fmt.allocPrint(a, "--{s}-port={s}/{s}", .{ verb, p.port, proto }));
        }
        return out.toOwnedSlice(a);
    }
    const sources: []const []const u8 = if (std.mem.eql(u8, rule.source, "lan")) &(lan4 ++ lan6) else &.{rule.source};
    for (sources) |src| {
        const v6 = std.mem.indexOfScalar(u8, src, ':') != null;
        if (rule.family == .v4 and v6) continue;
        if (rule.family == .v6 and src.len != 0 and !v6) continue;
        for (ports) |p| {
            const protos: []const []const u8 = switch (p.proto) {
                .tcp => &.{"tcp"},
                .udp => &.{"udp"},
                .both => if (p.port.len != 0) &.{ "tcp", "udp" } else &.{""},
            };
            for (protos) |proto| {
                var text: std.Io.Writer.Allocating = .init(a);
                const w = &text.writer;
                try w.writeAll("rule");
                if (src.len != 0) {
                    try w.print(" family=\"{s}\" source address=\"{s}\"", .{ if (v6) "ipv6" else "ipv4", src });
                } else if (rule.family != .both) try w.print(" family=\"{s}\"", .{if (rule.family == .v6) "ipv6" else "ipv4"});
                if (p.port.len != 0) {
                    try w.print(" port port=\"{s}\" protocol=\"{s}\"", .{ p.port, proto });
                } else if (proto.len != 0) try w.print(" protocol value=\"{s}\"", .{proto});
                try w.writeAll(switch (rule.action) {
                    .allow => " accept",
                    .limit => " accept limit value=\"6/m\"",
                    .deny => " drop",
                    .reject => " reject",
                });
                try out.append(a, try std.fmt.allocPrint(a, "--{s}-rich-rule={s}", .{ verb, text.written() }));
            }
        }
    }
    return out.toOwnedSlice(a);
}

test "zone listing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\public (default, active)
        \\  target: default
        \\  icmp-block-inversion: no
        \\  interfaces: wlan0
        \\  sources:
        \\  services: dhcpv6-client mdns ssh
        \\  ports: 8080/tcp 1714-1764/udp
        \\  protocols:
        \\  forward: yes
        \\  masquerade: no
        \\  icmp-blocks: echo-request
        \\  rich rules:
        \\        rule family="ipv4" source address="203.0.113.9" drop
        \\        rule family="ipv4" source address="10.0.0.0/8" port port="22" protocol="tcp" accept
        \\
    ;
    const zone = try parseZone(a, text);
    try std.testing.expectEqualStrings("public", zone.name);
    try std.testing.expectEqual(@as(usize, 3), zone.services.len);
    try std.testing.expectEqual(@as(usize, 2), zone.rich.len);
    try std.testing.expect(!pingAllowed(zone));
    try std.testing.expectEqual(model.Policy.reject, incoming(zone.target));
    const home_text = "home\n  target: default\n  services: mdns ssh kdeconnect\n  ports: \n";
    const home = try parseZone(a, home_text);
    const list = try rules(a, zone, home);
    try std.testing.expectEqual(@as(usize, 8), list.len);
    try std.testing.expectEqualStrings("kdeconnect", list[7].service);
    try std.testing.expectEqual(model.Scope.home, list[7].scope);
    try std.testing.expectEqual(model.Action.deny, list[5].action);
    try std.testing.expectEqualStrings("203.0.113.9", list[5].source);
    try std.testing.expectEqualStrings("22", list[6].port);
}

test "active zones and services" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const active = try parseActive(a, "home\n  interfaces: eth0\npublic (default)\n  interfaces: wlan0 wwan0\n");
    try std.testing.expectEqual(@as(usize, 3), active.len);
    try std.testing.expectEqualStrings("public", active[2].zone);
    const ports = try servicePorts(a, "<service><short>SSH</short><port protocol=\"tcp\" port=\"22\"/></service>");
    try std.testing.expectEqualStrings("22", ports[0].port);
}

test "arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("--add-service=ssh", (try arguments(a, .{ .service = "ssh" }, false))[0]);
    try std.testing.expectEqualStrings("--remove-port=8080/tcp", (try arguments(a, .{ .port = "8080", .proto = .tcp }, true))[0]);
    const deny = try arguments(a, .{ .source = "203.0.113.9", .action = .deny }, false);
    try std.testing.expectEqualStrings("--add-rich-rule=rule family=\"ipv4\" source address=\"203.0.113.9\" drop", deny[0]);
    const lan = try arguments(a, .{ .port = "22", .proto = .tcp, .source = "lan" }, false);
    try std.testing.expectEqual(@as(usize, 6), lan.len);
}
