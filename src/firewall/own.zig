//! Our own firewall, for systems where nothing else manages one: the state we
//! keep in `${sysconfdir}/rediwm/firewall.json` and its rendering into an
//! nftables table (`inet rediwm`, Linux) or a pf anchor (`rediwm`, FreeBSD).
//! We never write outside that table or anchor. Every string reaching a
//! renderer passed `validate.zig`, so nothing needs escaping here.
const std = @import("std");
const model = @import("model.zig");
const services = @import("services.zig");
const Writer = std.Io.Writer;

pub const State = struct {
    version: u32 = 1,
    enabled: bool = false,
    incoming: model.Policy = .drop,
    outgoing: model.Policy = .accept,
    forward: model.Policy = .drop,
    ping: bool = true,
    logging: model.Logging = .off,
    ssh_limit: bool = false,
    rules: []const model.Rule = &.{},
    /// Interfaces trusted as home where trust is per interface (no
    /// NetworkManager, or FreeBSD). With NetworkManager the dispatcher fills
    /// the live set from each connection's zone instead.
    home_ifaces: []const []const u8 = &.{},
};

pub const table = "rediwm";
pub const lockdown_table = "rediwm_lockdown";
pub const log_prefix = "rediwm-drop";

const lan4 = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16";
const lan6 = "fc00::/7, fe80::/10";

fn logRate(level: model.Logging) []const u8 {
    return switch (level) {
        .off => "",
        .low => "5/minute",
        .medium => "30/minute",
        .high => "120/minute",
    };
}

fn policyWord(p: model.Policy) []const u8 {
    return if (p == .accept) "accept" else "drop";
}

/// A rule's ports as concrete (proto, port) pairs: its own, or its service's.
pub fn expand(rule: model.Rule, out: []services.Port) []const services.Port {
    if (rule.port.len != 0 or rule.service.len == 0) {
        out[0] = .{ .proto = rule.proto, .port = rule.port };
        return out[0..1];
    }
    const s = services.find(rule.service) orelse {
        out[0] = .{ .proto = rule.proto, .port = "" };
        return out[0..1];
    };
    const n = @min(s.ports.len, out.len);
    @memcpy(out[0..n], s.ports[0..n]);
    return out[0..n];
}

fn nftPort(w: *Writer, port: []const u8) !void {
    for (port) |ch| try w.writeByte(if (ch == ':') '-' else ch);
}

const LanFamily = enum { v4, v6 };

fn nftMatch(w: *Writer, rule: model.Rule, p: services.Port, lan_family: ?LanFamily) !void {
    const in = rule.direction == .in;
    if (rule.family == .v4 and lan_family == null and rule.source.len == 0) try w.writeAll(" meta nfproto ipv4");
    if (rule.family == .v6 and lan_family == null and rule.source.len == 0) try w.writeAll(" meta nfproto ipv6");
    if (rule.iface.len != 0) try w.print(" {s} \"{s}\"", .{ if (in) "iifname" else "oifname", rule.iface });
    if (rule.scope == .home) try w.print(" {s} @home_ifaces", .{if (in) "iifname" else "oifname"});
    const field = if (in) "saddr" else "daddr";
    if (lan_family) |fam| {
        try w.print(" {s} {s} @lan{s}", .{ if (fam == .v4) "ip" else "ip6", field, if (fam == .v4) "4" else "6" });
    } else if (rule.source.len != 0) {
        const v6 = std.mem.indexOfScalar(u8, rule.source, ':') != null;
        try w.print(" {s} {s} {s}", .{ if (v6) "ip6" else "ip", field, rule.source });
    }
    switch (p.proto) {
        .tcp, .udp => {
            const name = if (p.proto == .tcp) "tcp" else "udp";
            if (p.port.len != 0) {
                try w.print(" {s} dport ", .{name});
                try nftPort(w, p.port);
            } else try w.print(" meta l4proto {s}", .{name});
        },
        .both => if (p.port.len != 0) {
            try w.writeAll(" meta l4proto { tcp, udp } th dport ");
            try nftPort(w, p.port);
        },
    }
}

fn nftRule(w: *Writer, rule: model.Rule) !void {
    var buffer: [8]services.Port = undefined;
    const ports = expand(rule, &buffer);
    const lan = std.mem.eql(u8, rule.source, "lan");
    for (ports) |p| {
        const passes: []const ?LanFamily = if (!lan) &.{null} else switch (rule.family) {
            .both => &.{ .v4, .v6 },
            .v4 => &.{.v4},
            .v6 => &.{.v6},
        };
        for (passes) |fam| {
            if (rule.action == .limit) {
                try w.writeAll("\t\t");
                try nftMatch(w, rule, p, fam);
                try w.writeAll(" ct state new limit rate over 6/minute burst 6 packets drop\n");
            }
            try w.writeAll("\t\t");
            try nftMatch(w, rule, p, fam);
            try w.writeAll(switch (rule.action) {
                .allow, .limit => " accept",
                .deny => " drop",
                .reject => " reject",
            });
            if (rule.comment.len != 0) try w.print(" comment \"{s}\"", .{rule.comment});
            try w.writeByte('\n');
        }
    }
}

fn denyFirst(rules: []const model.Rule, direction: model.Direction, deny: bool, w: *Writer) !void {
    for (rules) |rule| {
        if (rule.direction != direction) continue;
        const is_deny = rule.action == .deny or rule.action == .reject;
        if (is_deny == deny) try nftRule(w, rule);
    }
}

/// The whole table, replacing any previous one in a single transaction
/// (`table` + `delete table` first, so the load works whether or not it
/// exists, and a failed load changes nothing).
pub fn renderNft(w: *Writer, state: State, live_home: []const []const u8) !void {
    try w.writeAll("#!/usr/sbin/nft -f\n# Written by rediwm-firewall-helper from firewall.json; edit in Settings.\n");
    try w.print("table inet {s}\ndelete table inet {s}\n", .{ table, table });
    try w.print("table inet {s} {{\n", .{table});
    const home = if (live_home.len != 0) live_home else state.home_ifaces;
    try w.writeAll("\tset home_ifaces {\n\t\ttype ifname\n");
    if (home.len != 0) {
        try w.writeAll("\t\telements = { ");
        for (home, 0..) |name, i| try w.print("{s}\"{s}\"", .{ if (i == 0) "" else ", ", name });
        try w.writeAll(" }\n");
    }
    try w.writeAll("\t}\n");
    try w.print("\tset lan4 {{\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\telements = {{ {s} }}\n\t}}\n", .{lan4});
    try w.print("\tset lan6 {{\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\telements = {{ {s} }}\n\t}}\n", .{lan6});

    try w.print("\tchain input {{\n\t\ttype filter hook input priority filter; policy {s};\n", .{policyWord(state.incoming)});
    try w.writeAll("\t\tiif \"lo\" accept\n\t\tct state established,related accept\n\t\tct state invalid drop\n");
    try denyFirst(state.rules, .in, true, w);
    if (!state.ping) try w.writeAll("\t\ticmp type echo-request drop\n\t\ticmpv6 type echo-request drop\n");
    try w.writeAll("\t\tmeta l4proto { icmp, ipv6-icmp } accept\n");
    try w.writeAll("\t\tudp sport 67 udp dport 68 accept\n\t\tudp sport 547 udp dport 546 accept\n");
    if (state.ssh_limit) try w.writeAll("\t\ttcp dport 22 ct state new limit rate over 6/minute burst 6 packets drop\n");
    try denyFirst(state.rules, .in, false, w);
    if (state.logging != .off and state.incoming != .accept) try w.print("\t\tlimit rate {s} log prefix \"{s} \" level info\n", .{ logRate(state.logging), log_prefix });
    if (state.incoming == .reject) try w.writeAll("\t\treject with icmpx type admin-prohibited\n");
    try w.writeAll("\t}\n");

    try w.print("\tchain forward {{\n\t\ttype filter hook forward priority filter; policy {s};\n\t}}\n", .{policyWord(state.forward)});

    try w.print("\tchain output {{\n\t\ttype filter hook output priority filter; policy {s};\n", .{policyWord(state.outgoing)});
    try w.writeAll("\t\toif \"lo\" accept\n\t\tct state established,related accept\n");
    try denyFirst(state.rules, .out, true, w);
    if (state.outgoing != .accept) {
        // Without these, blocking outgoing would also cut DHCP and DNS.
        try w.writeAll("\t\tudp dport { 53, 67, 547 } accept\n\t\ttcp dport 53 accept\n\t\tmeta l4proto { icmp, ipv6-icmp } accept\n");
    }
    try denyFirst(state.rules, .out, false, w);
    if (state.outgoing == .reject) try w.writeAll("\t\treject with icmpx type admin-prohibited\n");
    try w.writeAll("\t}\n}\n");
}

/// Blocks everything but loopback, beside whatever else is loaded: a drop in
/// any base chain drops the packet, so this works under every manager.
pub fn renderLockdownNft(w: *Writer, on: bool) !void {
    try w.print("table inet {s}\ndelete table inet {s}\n", .{ lockdown_table, lockdown_table });
    if (!on) return;
    try w.print("table inet {s} {{\n", .{lockdown_table});
    inline for (.{ "input", "output", "forward" }) |hook| {
        const lo = if (comptime std.mem.eql(u8, hook, "input")) "\t\tiif \"lo\" accept\n" else if (comptime std.mem.eql(u8, hook, "output")) "\t\toif \"lo\" accept\n" else "";
        try w.print("\tchain {s} {{\n\t\ttype filter hook {s} priority -200; policy drop;\n{s}\t}}\n", .{ hook, hook, lo });
    }
    try w.writeAll("}\n");
}

fn pfPort(w: *Writer, port: []const u8) !void {
    for (port) |ch| try w.writeByte(if (ch == '-') ':' else ch);
}

fn pfRule(w: *Writer, rule: model.Rule, home: []const []const u8) !void {
    if (rule.scope == .home and home.len == 0 and rule.iface.len == 0) return;
    var buffer: [8]services.Port = undefined;
    for (expand(rule, &buffer)) |p| {
        const verb = switch (rule.action) {
            .allow, .limit => "pass",
            .deny => "block drop",
            .reject => "block return",
        };
        try w.print("{s} {s} quick", .{ verb, if (rule.direction == .in) "in" else "out" });
        if (rule.iface.len != 0) {
            try w.print(" on {s}", .{rule.iface});
        } else if (rule.scope == .home) {
            try w.writeAll(" on {");
            for (home) |name| try w.print(" {s}", .{name});
            try w.writeAll(" }");
        }
        const v6_source = rule.source.len != 0 and std.mem.indexOfScalar(u8, rule.source, ':') != null;
        if (rule.family == .v4 or (rule.source.len != 0 and !v6_source and !std.mem.eql(u8, rule.source, "lan"))) try w.writeAll(" inet");
        if (rule.family == .v6 or v6_source) try w.writeAll(" inet6");
        switch (p.proto) {
            .tcp => try w.writeAll(" proto tcp"),
            .udp => try w.writeAll(" proto udp"),
            .both => if (p.port.len != 0) try w.writeAll(" proto { tcp udp }"),
        }
        const remote = if (std.mem.eql(u8, rule.source, "lan")) "<rediwm_lan>" else if (rule.source.len != 0) rule.source else "any";
        if (rule.direction == .in) try w.print(" from {s} to any", .{remote}) else try w.print(" from any to {s}", .{remote});
        if (p.port.len != 0) {
            try w.writeAll(" port ");
            try pfPort(w, p.port);
        }
        if (rule.action == .allow or rule.action == .limit) {
            try w.writeAll(" keep state");
            if (rule.action == .limit) try w.writeAll(" (max-src-conn-rate 6/30, overload <rediwm_abuse> flush global)");
        }
        if (rule.comment.len != 0) try w.print(" label \"{s}\"", .{rule.comment});
        try w.writeByte('\n');
    }
}

/// The anchor's rules. Every rule is `quick`, so the anchor decides on its
/// own and in order: loopback, blocks, then allows, then the default.
pub fn renderPf(w: *Writer, state: State, lockdown: bool) !void {
    try w.writeAll("# Written by rediwm-firewall-helper from firewall.json; edit in Settings.\n");
    try w.print("table <rediwm_lan> const {{ {s}, {s} }}\ntable <rediwm_abuse> persist\n", .{ lan4, lan6 });
    try w.writeAll("pass quick on lo0 all\n");
    if (lockdown) {
        try w.writeAll("block drop quick all\n");
        return;
    }
    try w.writeAll("block drop in quick from <rediwm_abuse>\n");
    for (state.rules) |rule| if (rule.action == .deny or rule.action == .reject) try pfRule(w, rule, state.home_ifaces);
    if (state.ping) {
        try w.writeAll("pass in quick inet proto icmp all icmp-type { echoreq, unreach } keep state\n");
    } else try w.writeAll("pass in quick inet proto icmp all icmp-type unreach keep state\n");
    // Neighbour discovery: IPv6 does not work without it.
    try w.writeAll("pass in quick inet6 proto icmp6 all keep state\n");
    try w.writeAll("pass in quick inet proto udp from any port 67 to any port 68\npass in quick inet6 proto udp from any port 547 to any port 546\n");
    if (state.ssh_limit) try w.writeAll("pass in quick proto tcp from any to any port 22 keep state (max-src-conn-rate 6/30, overload <rediwm_abuse> flush global)\n");
    for (state.rules) |rule| if ((rule.action == .allow or rule.action == .limit) and rule.direction == .in) try pfRule(w, rule, state.home_ifaces);
    for (state.rules) |rule| if ((rule.action == .allow or rule.action == .limit) and rule.direction == .out) try pfRule(w, rule, state.home_ifaces);
    const log = if (state.logging != .off) " log" else "";
    try w.writeAll(switch (state.incoming) {
        .accept => "pass in quick all keep state\n",
        .drop => "",
        .reject => "",
    });
    if (state.incoming == .drop) try w.print("block drop in{s} quick all\n", .{log});
    if (state.incoming == .reject) try w.print("block return in{s} quick all\n", .{log});
    if (state.outgoing == .accept) {
        try w.writeAll("pass out quick all keep state\n");
    } else {
        try w.writeAll("pass out quick proto { tcp udp } from any to any port 53 keep state\npass out quick proto udp from any to any port { 67 547 } keep state\npass out quick inet proto icmp all keep state\npass out quick inet6 proto icmp6 all keep state\n");
        try w.writeAll(if (state.outgoing == .reject) "block return out quick all\n" else "block drop out quick all\n");
    }
}

/// The minimal pf.conf a Turn on writes when there is none.
pub const pf_conf =
    \\# Written by RediWM Settings. The rules live in the "rediwm" anchor;
    \\# add your own below the anchor line.
    \\set skip on lo0
    \\scrub in all
    \\anchor "rediwm"
    \\load anchor "rediwm" from "@ANCHOR@"
    \\block in all
    \\pass out all keep state
    \\
;

/// Whether a pf.conf evaluates our anchor (and loads it at boot).
pub fn pfConfHasAnchor(conf: []const u8) struct { anchor: bool, load: bool } {
    var anchor = false;
    var load = false;
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "anchor \"rediwm\"")) anchor = true;
        if (std.mem.startsWith(u8, line, "load anchor \"rediwm\"")) load = true;
    }
    return .{ .anchor = anchor, .load = load };
}

/// The lines Turn on adds to an existing pf.conf. The anchor goes first so
/// our blocks and allows come before the file's own rules.
pub fn pfConfWithAnchor(a: std.mem.Allocator, conf: []const u8, anchor_path: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(a);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, conf, '\n');
    var inserted = false;
    const w = &out.writer;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Options, tables, scrub and NAT must precede filter rules in pf.conf.
        const filter = std.mem.startsWith(u8, line, "pass") or std.mem.startsWith(u8, line, "block") or std.mem.startsWith(u8, line, "anchor") or std.mem.startsWith(u8, line, "antispoof");
        if (!inserted and filter) {
            try w.print("anchor \"rediwm\"\nload anchor \"rediwm\" from \"{s}\"\n", .{anchor_path});
            inserted = true;
        }
        try w.writeAll(raw);
        if (lines.peek() != null) try w.writeByte('\n');
    }
    if (!inserted) try w.print("\nanchor \"rediwm\"\nload anchor \"rediwm\" from \"{s}\"\n", .{anchor_path});
    return out.toOwnedSlice();
}

/// The status a saved state shows (rules carry their index as `id`).
pub fn status(a: std.mem.Allocator, state: State) !model.Status {
    const rules = try a.alloc(model.Rule, state.rules.len);
    for (state.rules, rules, 0..) |rule, *out, i| {
        out.* = rule;
        out.id = @intCast(i);
    }
    return .{
        .backend = .own,
        .incoming = state.incoming,
        .outgoing = state.outgoing,
        .forward = state.forward,
        .ping = state.ping,
        .logging = state.logging,
        .ssh_limit = state.ssh_limit,
        .rules = rules,
    };
}

pub fn sameRule(x: model.Rule, y: model.Rule) bool {
    return x.action == y.action and x.direction == y.direction and x.proto == y.proto and x.scope == y.scope and x.family == y.family and
        std.mem.eql(u8, x.port, y.port) and std.mem.eql(u8, x.service, y.service) and std.mem.eql(u8, x.source, y.source) and std.mem.eql(u8, x.iface, y.iface);
}
