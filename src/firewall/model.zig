//! The firewall as Settings shows it, whatever program manages it. The helper
//! fills it from ufw, firewalld, our own nftables table or our pf anchor and
//! sends it as JSON; the page draws only from it. No compositor imports.
const std = @import("std");

pub const max_reply = 4 << 20;
pub const max_request = 16 << 10;
pub const max_rules = 512;

/// Who manages the firewall. `own` is our nftables table (Linux) or pf anchor
/// (FreeBSD); `redi` is RediOS's generated ruleset, read-only for now.
pub const Backend = enum { none, own, ufw, firewalld, redi, foreign };
pub const Policy = enum { accept, drop, reject };
pub const Action = enum { allow, deny, reject, limit };
pub const Direction = enum { in, out };
pub const Proto = enum { tcp, udp, both };
pub const Family = enum { both, v4, v6 };
/// Where a rule applies: on every network, or only on trusted (home) ones.
pub const Scope = enum { everywhere, home };
pub const Trust = enum { public, home };
pub const Logging = enum { off, low, medium, high };
pub const System = enum { linux, freebsd };

/// One rule. `port` is "22", "8000-8100" or "" (any); `service` is a catalog
/// id or the manager's own service/application name, whose ports the helper
/// resolves into `port` where it can. `source` is "" (anywhere), "lan" or an
/// address/CIDR.
pub const Rule = struct {
    id: u32 = 0,
    action: Action = .allow,
    direction: Direction = .in,
    proto: Proto = .both,
    port: []const u8 = "",
    service: []const u8 = "",
    source: []const u8 = "",
    scope: Scope = .everywhere,
    family: Family = .both,
    iface: []const u8 = "",
    comment: []const u8 = "",
    /// The manager can express this rule but we could not map all of it
    /// (a firewalld rich rule, a ufw route rule): shown, deletable, not editable.
    raw: []const u8 = "",
};

/// Rules some other program owns: a Docker or libvirt table, a pf.conf.
pub const Foreign = struct {
    owner: []const u8,
    name: []const u8,
    rules: u32 = 0,
};

pub const Verdict = enum { local, blocked, home, everywhere };

/// A listening socket and whether the firewall lets anyone reach it.
pub const Listener = struct {
    proto: Proto = .tcp,
    address: []const u8 = "",
    port: u16 = 0,
    process: []const u8 = "",
    pid: i32 = 0,
    uid: u32 = 0,
    verdict: Verdict = .blocked,
};

/// A network's trust: an active NetworkManager connection (`uuid`), or an
/// interface where there is no NetworkManager.
pub const Network = struct {
    name: []const u8 = "",
    iface: []const u8 = "",
    uuid: []const u8 = "",
    trust: Trust = .public,
    active: bool = false,
};

pub const Block = struct {
    time: []const u8 = "",
    direction: Direction = .in,
    proto: []const u8 = "",
    source: []const u8 = "",
    port: u16 = 0,
    iface: []const u8 = "",
};

/// What the manager can express; the page hides what it cannot.
pub const Capabilities = struct {
    edit: bool = false,
    trust: bool = false,
    sources: bool = false,
    limit: bool = false,
    reject: bool = false,
    outgoing_rules: bool = false,
    outgoing_policy: bool = false,
    forward_policy: bool = false,
    ping: bool = false,
    logging: bool = false,
    ssh_limit: bool = false,
    boot: bool = false,
    lockdown: bool = false,
};

pub const Status = struct {
    system: System = .linux,
    backend: Backend = .none,
    /// The manager is installed and set up but not filtering now.
    running: bool = false,
    boot: bool = false,
    /// Other managers that are active too; while any is, nothing is editable.
    conflicts: []const Backend = &.{},
    /// Managers that are installed but inactive (what Turn on may use).
    installed: []const Backend = &.{},
    incoming: Policy = .drop,
    outgoing: Policy = .accept,
    forward: Policy = .drop,
    ping: bool = true,
    logging: Logging = .off,
    ssh_limit: bool = false,
    lockdown: bool = false,
    /// firewalld's zone for the default route; empty elsewhere.
    zone: []const u8 = "",
    rules: []const Rule = &.{},
    foreign: []const Foreign = &.{},
    listeners: []const Listener = &.{},
    networks: []const Network = &.{},
    blocks: []const Block = &.{},
    capabilities: Capabilities = .{},
    /// Seconds until a pending change reverts unless confirmed; 0 for none.
    revert_in: u32 = 0,
    /// The setup a Turn on would do needs a change to pf.conf first (FreeBSD).
    needs_anchor: bool = false,
};

pub fn isAnywhere(source: []const u8) bool {
    return source.len == 0 or std.mem.eql(u8, source, "0.0.0.0/0") or std.mem.eql(u8, source, "::/0") or std.mem.eql(u8, source, "any");
}

/// Whether `port` (as a rule writes it) covers `number`.
pub fn portCovers(port: []const u8, number: u16) bool {
    if (port.len == 0) return true;
    var parts = std.mem.splitScalar(u8, port, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        const sep = std.mem.indexOfAny(u8, trimmed, "-:");
        if (sep) |i| {
            const lo = std.fmt.parseInt(u16, trimmed[0..i], 10) catch continue;
            const hi = std.fmt.parseInt(u16, trimmed[i + 1 ..], 10) catch continue;
            if (number >= lo and number <= hi) return true;
        } else {
            const one = std.fmt.parseInt(u16, trimmed, 10) catch continue;
            if (one == number) return true;
        }
    }
    return false;
}

/// Whether a rule is about this socket's port: a service whose ports the
/// helper could not resolve matches nothing rather than everything.
pub fn about(rule: Rule, listener: Listener) bool {
    if (rule.direction != .in) return false;
    if (rule.port.len == 0 and rule.service.len != 0) {
        const s = @import("services.zig").find(rule.service) orelse return false;
        for (s.ports) |p| if (protoMatches(p.proto, listener.proto) and portCovers(p.port, listener.port)) return true;
        return false;
    }
    return protoMatches(rule.proto, listener.proto) and portCovers(rule.port, listener.port);
}

fn protoMatches(rule: Proto, sock: Proto) bool {
    return rule == .both or rule == sock;
}

fn isLoopback(address: []const u8) bool {
    return std.mem.startsWith(u8, address, "127.") or std.mem.eql(u8, address, "::1") or std.mem.eql(u8, address, "localhost");
}

/// How far a listener reaches through `status`'s rules. Approximate on
/// purpose: it answers "can another machine connect", not every corner of
/// the manager's semantics. Rules are matched first-wins as ufw, our table
/// and our anchor (all `quick`) evaluate them.
pub fn verdict(status: Status, listener: Listener) Verdict {
    if (isLoopback(listener.address)) return .local;
    if (status.lockdown) return .blocked;
    if (!status.running or status.backend == .none) return .everywhere;
    var best: Verdict = if (status.incoming == .accept) .everywhere else .blocked;
    if (status.incoming == .accept) {
        for (status.rules) |rule| {
            if (!about(rule, listener)) continue;
            if (rule.action == .deny or rule.action == .reject) {
                if (isAnywhere(rule.source) and rule.scope == .everywhere) return .blocked;
            }
        }
        return best;
    }
    for (status.rules) |rule| {
        if (!about(rule, listener)) continue;
        switch (rule.action) {
            .deny, .reject => {
                if (isAnywhere(rule.source) and rule.scope == .everywhere and best == .blocked) return .blocked;
            },
            .allow, .limit => {
                const reach: Verdict = if (isAnywhere(rule.source) and rule.scope == .everywhere) .everywhere else .home;
                if (@backingInt(reach) > @backingInt(best)) best = reach;
                if (best == .everywhere) return best;
            },
        }
    }
    return best;
}

test "port ranges and lists" {
    try std.testing.expect(portCovers("22", 22));
    try std.testing.expect(!portCovers("22", 23));
    try std.testing.expect(portCovers("1000-2000", 1500));
    try std.testing.expect(portCovers("1714:1764", 1764));
    try std.testing.expect(portCovers("80,443", 443));
    try std.testing.expect(portCovers("", 9));
}

test "verdicts follow the rules" {
    const rules = [_]Rule{
        .{ .port = "22", .proto = .tcp },
        .{ .port = "5353", .proto = .udp, .scope = .home },
        .{ .port = "445", .proto = .tcp, .source = "192.168.0.0/16" },
    };
    const status: Status = .{ .backend = .own, .running = true, .rules = &rules };
    try std.testing.expectEqual(Verdict.everywhere, verdict(status, .{ .proto = .tcp, .address = "0.0.0.0", .port = 22 }));
    try std.testing.expectEqual(Verdict.blocked, verdict(status, .{ .proto = .udp, .address = "0.0.0.0", .port = 22 }));
    try std.testing.expectEqual(Verdict.home, verdict(status, .{ .proto = .udp, .address = "::", .port = 5353 }));
    try std.testing.expectEqual(Verdict.home, verdict(status, .{ .proto = .tcp, .address = "0.0.0.0", .port = 445 }));
    try std.testing.expectEqual(Verdict.local, verdict(status, .{ .proto = .tcp, .address = "127.0.0.1", .port = 631 }));
    try std.testing.expectEqual(Verdict.blocked, verdict(status, .{ .proto = .tcp, .address = "0.0.0.0", .port = 8080 }));
    const by_service = [_]Rule{.{ .service = "ssh", .source = "lan" }};
    try std.testing.expectEqual(Verdict.home, verdict(.{ .backend = .own, .running = true, .rules = &by_service }, .{ .proto = .tcp, .address = "::", .port = 22 }));
    var off = status;
    off.running = false;
    try std.testing.expectEqual(Verdict.everywhere, verdict(off, .{ .proto = .tcp, .address = "0.0.0.0", .port = 8080 }));
}
