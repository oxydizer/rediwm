//! ufw: its rules come from the tuples ufw keeps in `/etc/ufw/user.rules` and
//! `user6.rules` (the format `ufw/backend_iptables.py` reads back), its
//! defaults from `/etc/default/ufw`, its logging and boot state from
//! `/etc/ufw/ufw.conf`; only "is it filtering now" needs `ufw status`.
//! Changes are `ufw` commands built here from validated rules.
const std = @import("std");
const model = @import("model.zig");
const services = @import("services.zig");
const own = @import("own.zig");
const Allocator = std.mem.Allocator;

pub const rules_v4 = "/etc/ufw/user.rules";
pub const rules_v6 = "/etc/ufw/user6.rules";
pub const defaults = "/etc/default/ufw";
pub const conf = "/etc/ufw/ufw.conf";
pub const applications = "/etc/ufw/applications.d";

fn unhex(a: Allocator, hex: []const u8) []const u8 {
    if (hex.len % 2 != 0) return "";
    const out = a.alloc(u8, hex.len / 2) catch return "";
    _ = std.fmt.hexToBytes(out, hex) catch return "";
    for (out) |*ch| if (ch.* < 0x20 or ch.* > 0x7e) {
        ch.* = '?';
    };
    return out;
}

fn parseAction(word: []const u8) ?model.Action {
    const base = if (std.mem.indexOfScalar(u8, word, '_')) |i| word[0..i] else word;
    if (std.mem.eql(u8, base, "allow")) return .allow;
    if (std.mem.eql(u8, base, "deny")) return .deny;
    if (std.mem.eql(u8, base, "reject")) return .reject;
    if (std.mem.eql(u8, base, "limit")) return .limit;
    return null;
}

/// One tuple line ("### tuple ### allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 in").
pub fn parseTuple(a: Allocator, line: []const u8, v6: bool) ?model.Rule {
    const prefix = "### tuple ###";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var body = std.mem.trim(u8, line[prefix.len..], " \t\r");
    var comment: []const u8 = "";
    if (std.mem.indexOf(u8, body, " comment=")) |i| {
        comment = unhex(a, std.mem.trim(u8, body[i + 9 ..], " "));
        body = body[0..i];
    }
    var fields: [9][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, " \t");
    while (it.next()) |field| {
        if (n == fields.len) return null;
        fields[n] = field;
        n += 1;
    }
    if (n < 6) return null;
    var rule: model.Rule = .{ .family = if (v6) .v6 else .v4, .comment = comment };
    const action_word = fields[0];
    if (std.mem.indexOfScalar(u8, action_word, ':') != null) rule.raw = a.dupe(u8, body) catch "";
    rule.action = parseAction(if (std.mem.indexOfScalar(u8, action_word, ':')) |i| action_word[i + 1 ..] else action_word) orelse return null;
    rule.proto = if (std.mem.eql(u8, fields[1], "tcp")) .tcp else if (std.mem.eql(u8, fields[1], "udp")) .udp else .both;
    rule.port = if (std.mem.eql(u8, fields[2], "any")) "" else a.dupe(u8, fields[2]) catch "";
    const dst = fields[3];
    const sport = fields[4];
    const src = fields[5];
    if (!model.isAnywhere(dst) or !std.mem.eql(u8, sport, "any")) {
        if (rule.raw.len == 0) rule.raw = a.dupe(u8, body) catch "";
    }
    rule.source = if (model.isAnywhere(src)) "" else a.dupe(u8, src) catch "";
    if (n == 7 or n == 9) {
        const dir = fields[n - 1];
        rule.direction = if (std.mem.startsWith(u8, dir, "out")) .out else .in;
        if (std.mem.indexOfScalar(u8, dir, '_')) |i| {
            if (std.mem.indexOfScalar(u8, dir, '!') != null) {
                if (rule.raw.len == 0) rule.raw = a.dupe(u8, body) catch "";
            } else rule.iface = a.dupe(u8, dir[i + 1 ..]) catch "";
        }
    }
    if (n >= 8) {
        if (!std.mem.eql(u8, fields[6], "-")) rule.service = std.mem.replaceOwned(u8, a, fields[6], "%20", " ") catch "";
        if (!std.mem.eql(u8, fields[7], "-") and rule.raw.len == 0) rule.raw = a.dupe(u8, body) catch "";
    }
    if (rule.service.len == 0) {
        if (services.named(rule.proto, rule.port)) |s| rule.service = s.id;
    }
    return rule;
}

fn sameButFamily(x: model.Rule, y: model.Rule) bool {
    return x.action == y.action and x.direction == y.direction and x.proto == y.proto and
        std.mem.eql(u8, x.port, y.port) and x.source.len == 0 and y.source.len == 0 and
        std.mem.eql(u8, x.iface, y.iface) and std.mem.eql(u8, x.service, y.service) and std.mem.eql(u8, x.raw, y.raw);
}

/// Rules from both files; a rule ufw wrote to both (no address) becomes one
/// rule for both families, as `ufw status` shows it.
pub fn parseRules(a: Allocator, v4_text: []const u8, v6_text: []const u8) ![]model.Rule {
    var list: std.ArrayList(model.Rule) = .empty;
    var lines = std.mem.splitScalar(u8, v4_text, '\n');
    while (lines.next()) |line| if (parseTuple(a, std.mem.trim(u8, line, " \r"), false)) |rule| try list.append(a, rule);
    const v4_count = list.items.len;
    lines = std.mem.splitScalar(u8, v6_text, '\n');
    outer: while (lines.next()) |line| {
        const rule = parseTuple(a, std.mem.trim(u8, line, " \r"), true) orelse continue;
        for (list.items[0..v4_count]) |*existing| {
            if (existing.family == .v4 and sameButFamily(existing.*, rule)) {
                existing.family = .both;
                continue :outer;
            }
        }
        try list.append(a, rule);
    }
    for (list.items, 0..) |*rule, i| rule.id = @intCast(i);
    return list.toOwnedSlice(a);
}

fn value(text: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != '=') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], "\" ");
    }
    return "";
}

fn policy(word: []const u8) model.Policy {
    if (std.ascii.eqlIgnoreCase(word, "ACCEPT")) return .accept;
    if (std.ascii.eqlIgnoreCase(word, "REJECT")) return .reject;
    return .drop;
}

pub const Settings = struct {
    incoming: model.Policy,
    outgoing: model.Policy,
    forward: model.Policy,
    boot: bool,
    logging: model.Logging,
};

pub fn parseSettings(defaults_text: []const u8, conf_text: []const u8) Settings {
    const level = value(conf_text, "LOGLEVEL");
    return .{
        .incoming = policy(value(defaults_text, "DEFAULT_INPUT_POLICY")),
        .outgoing = policy(value(defaults_text, "DEFAULT_OUTPUT_POLICY")),
        .forward = policy(value(defaults_text, "DEFAULT_FORWARD_POLICY")),
        .boot = std.ascii.eqlIgnoreCase(value(conf_text, "ENABLED"), "yes"),
        .logging = if (std.mem.eql(u8, level, "off") or level.len == 0) .off else if (std.mem.eql(u8, level, "medium")) .medium else if (std.mem.eql(u8, level, "high") or std.mem.eql(u8, level, "full")) .high else .low,
    };
}

/// `ufw status` output: whether it is filtering now.
pub fn active(status_text: []const u8) bool {
    return std.mem.indexOf(u8, status_text, "Status: active") != null;
}

fn actionWord(action: model.Action) []const u8 {
    return switch (action) {
        .allow => "allow",
        .deny => "deny",
        .reject => "reject",
        .limit => "limit",
    };
}

pub fn policyWord(p: model.Policy) []const u8 {
    return switch (p) {
        .accept => "allow",
        .drop => "deny",
        .reject => "reject",
    };
}

pub fn loggingWord(level: model.Logging) []const u8 {
    return @tagName(level);
}

const lan_sources = [_][]const u8{ "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "fe80::/10" };

/// The `ufw` argv lists (after the program and `--force`) that add `rule`, or
/// with `delete` remove it. A service expands into one rule per port and a
/// "lan" source into one per private range, since ufw has neither.
pub fn commands(a: Allocator, rule: model.Rule, delete: bool) ![]const []const []const u8 {
    var out: std.ArrayList([]const []const u8) = .empty;
    var buffer: [8]services.Port = undefined;
    const ports = own.expand(rule, &buffer);
    const sources: []const []const u8 = if (std.mem.eql(u8, rule.source, "lan")) &lan_sources else &.{rule.source};
    for (ports) |p| {
        const protos: []const model.Proto = if (p.proto == .both and std.mem.indexOfAny(u8, p.port, "-:") != null) &.{ .tcp, .udp } else &.{p.proto};
        for (protos) |proto| for (sources) |src| {
            if (rule.family == .v4 and std.mem.indexOfScalar(u8, src, ':') != null) continue;
            if (rule.family == .v6 and src.len != 0 and std.mem.indexOfScalar(u8, src, ':') == null) continue;
            var argv: std.ArrayList([]const u8) = .empty;
            if (delete) try argv.append(a, "delete");
            try argv.append(a, actionWord(rule.action));
            try argv.append(a, if (rule.direction == .in) "in" else "out");
            if (rule.iface.len != 0) try argv.appendSlice(a, &.{ "on", rule.iface });
            if (proto != .both) try argv.appendSlice(a, &.{ "proto", if (proto == .tcp) "tcp" else "udp" });
            const any: []const u8 = switch (rule.family) {
                .both => "any",
                .v4 => "0.0.0.0/0",
                .v6 => "::/0",
            };
            const remote = if (src.len == 0) any else src;
            if (rule.direction == .in) try argv.appendSlice(a, &.{ "from", remote, "to", "any" }) else try argv.appendSlice(a, &.{ "from", "any", "to", remote });
            if (p.port.len != 0) {
                const port = try std.mem.replaceOwned(u8, a, p.port, "-", ":");
                try argv.appendSlice(a, &.{ "port", port });
            }
            if (!delete and rule.comment.len != 0) try argv.appendSlice(a, &.{ "comment", rule.comment });
            try out.append(a, try argv.toOwnedSlice(a));
        };
    }
    return out.toOwnedSlice(a);
}

/// Ports of an application profile file (`ports=22/tcp|80,443/tcp`).
pub fn profilePorts(text: []const u8, name: []const u8) []const u8 {
    var section = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 1 and line[0] == '[') {
            section = std.mem.eql(u8, line[1 .. line.len - 1], name);
            continue;
        }
        if (section and std.mem.startsWith(u8, line, "ports=")) return line[6..];
    }
    return "";
}

test "tuples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v4 =
        \\### RULES ###
        \\
        \\### tuple ### allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 in
        \\-A ufw-user-input -p tcp --dport 22 -j ACCEPT
        \\### tuple ### deny any any 0.0.0.0/0 any 203.0.113.9 in comment=6e6f697379
        \\### tuple ### allow any 1714:1764 0.0.0.0/0 any 192.168.0.0/16 in_wlan0
        \\### tuple ### allow any 80,443 0.0.0.0/0 any 0.0.0.0/0 Nginx%20Full - in
        \\### tuple ### route:allow any any 0.0.0.0/0 any 10.0.0.0/8 in_eth0!out_eth1
        \\### tuple ### limit tcp 22 0.0.0.0/0 any 0.0.0.0/0 out
        \\### END RULES ###
    ;
    const v6 =
        \\### tuple ### allow tcp 22 ::/0 any ::/0 in
        \\### tuple ### allow udp 5353 ::/0 any fe80::/10 in
    ;
    const rules = try parseRules(a, v4, v6);
    try std.testing.expectEqual(@as(usize, 7), rules.len);
    try std.testing.expectEqual(model.Family.both, rules[0].family);
    try std.testing.expectEqualStrings("22", rules[0].port);
    try std.testing.expectEqualStrings("ssh", rules[0].service);
    try std.testing.expectEqual(model.Action.deny, rules[1].action);
    try std.testing.expectEqualStrings("203.0.113.9", rules[1].source);
    try std.testing.expectEqualStrings("noisy", rules[1].comment);
    try std.testing.expectEqualStrings("wlan0", rules[2].iface);
    try std.testing.expectEqualStrings("Nginx Full", rules[3].service);
    try std.testing.expect(rules[4].raw.len != 0);
    try std.testing.expectEqual(model.Direction.out, rules[5].direction);
    try std.testing.expectEqual(model.Action.limit, rules[5].action);
    try std.testing.expectEqual(model.Family.v6, rules[6].family);
}

test "settings" {
    const s = parseSettings("DEFAULT_INPUT_POLICY=\"DROP\"\nDEFAULT_OUTPUT_POLICY=\"ACCEPT\"\nDEFAULT_FORWARD_POLICY=\"REJECT\"\n", "ENABLED=yes\nLOGLEVEL=medium\n");
    try std.testing.expectEqual(model.Policy.drop, s.incoming);
    try std.testing.expectEqual(model.Policy.accept, s.outgoing);
    try std.testing.expectEqual(model.Policy.reject, s.forward);
    try std.testing.expect(s.boot);
    try std.testing.expectEqual(model.Logging.medium, s.logging);
    try std.testing.expect(active("Status: active\n\nTo   Action  From"));
    try std.testing.expect(!active("Status: inactive"));
}

test "commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ssh = try commands(a, .{ .service = "ssh", .source = "lan", .comment = "ssh" }, false);
    try std.testing.expectEqual(@as(usize, 5), ssh.len);
    const first = try std.mem.join(a, " ", ssh[0]);
    try std.testing.expectEqualStrings("allow in proto tcp from 10.0.0.0/8 to any port 22 comment ssh", first);
    const kde = try commands(a, .{ .service = "kdeconnect" }, true);
    try std.testing.expectEqual(@as(usize, 2), kde.len);
    try std.testing.expectEqualStrings("delete allow in proto tcp from any to any port 1714:1764", try std.mem.join(a, " ", kde[0]));
    const v6only = try commands(a, .{ .port = "80", .proto = .tcp, .family = .v6 }, false);
    try std.testing.expectEqualStrings("allow in proto tcp from ::/0 to any port 80", try std.mem.join(a, " ", v6only[0]));
}
