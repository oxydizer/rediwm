//! What else is loaded: the tables in `nft -j list ruleset` (Linux) and the
//! pf and ipfw state (FreeBSD), named after the program that probably owns
//! them, so the page can list rules it will not touch and detect which
//! manager is active.
const std = @import("std");
const model = @import("model.zig");
const own = @import("own.zig");
const Allocator = std.mem.Allocator;

pub const Table = struct {
    family: []const u8,
    name: []const u8,
    rules: u32 = 0,
    /// Chain names, for guessing the owner (iptables-nft keeps tables named
    /// "filter" whose chains say who made them: ufw-*, DOCKER, ts-*).
    chains: []const []const u8 = &.{},
};

/// Tables with their chains and rule counts, from `nft -j list ruleset`.
pub fn parseNft(a: Allocator, json: []const u8) ![]Table {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const items = switch (parsed) {
        .object => |o| (o.get("nftables") orelse return &.{}).array.items,
        else => return &.{},
    };
    var tables: std.ArrayList(Table) = .empty;
    var chains: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        if (obj.get("table")) |t| {
            const family = stringField(t, "family") orelse continue;
            const name = stringField(t, "name") orelse continue;
            try tables.append(a, .{ .family = family, .name = name });
            try chains.append(a, .empty);
        } else if (obj.get("chain")) |c| {
            const i = find(tables.items, stringField(c, "family"), stringField(c, "table")) orelse continue;
            if (stringField(c, "name")) |name| try chains.items[i].append(a, name);
        } else if (obj.get("rule")) |r| {
            const i = find(tables.items, stringField(r, "family"), stringField(r, "table")) orelse continue;
            tables.items[i].rules += 1;
        }
    }
    for (tables.items, chains.items) |*t, *c| t.chains = try c.toOwnedSlice(a);
    return tables.toOwnedSlice(a);
}

fn stringField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn find(tables: []const Table, family: ?[]const u8, name: ?[]const u8) ?usize {
    const f = family orelse return null;
    const n = name orelse return null;
    for (tables, 0..) |t, i| if (std.mem.eql(u8, t.family, f) and std.mem.eql(u8, t.name, n)) return i;
    return null;
}

fn anyChain(t: Table, prefix: []const u8) bool {
    for (t.chains) |c| if (std.mem.startsWith(u8, c, prefix)) return true;
    return false;
}

/// Who probably owns a table, in words for the page ("Docker", "ufw").
pub fn owner(t: Table) []const u8 {
    if (std.mem.eql(u8, t.name, own.table) or std.mem.eql(u8, t.name, own.lockdown_table)) return "RediWM";
    if (std.mem.eql(u8, t.name, "firewalld")) return "firewalld";
    if (std.mem.eql(u8, t.name, "redi")) return "RediOS";
    if (std.mem.startsWith(u8, t.name, "libvirt")) return "libvirt";
    if (std.mem.startsWith(u8, t.name, "nm-shared") or std.mem.startsWith(u8, t.name, "nm-")) return "NetworkManager";
    if (std.mem.eql(u8, t.name, "netavark") or std.mem.startsWith(u8, t.name, "podman")) return "Podman";
    if (std.mem.startsWith(u8, t.name, "wg-quick")) return "WireGuard";
    if (std.mem.eql(u8, t.name, "incus") or std.mem.eql(u8, t.name, "lxd")) return "Incus";
    if (std.mem.eql(u8, t.name, "tailscale") or anyChain(t, "ts-")) return "Tailscale";
    if (anyChain(t, "ufw")) return "ufw";
    if (anyChain(t, "DOCKER")) return "Docker";
    if (anyChain(t, "LIBVIRT")) return "libvirt";
    if (anyChain(t, "f2b-")) return "fail2ban";
    return "";
}

pub fn hasTable(tables: []const Table, name: []const u8) bool {
    for (tables) |t| if (std.mem.eql(u8, t.name, name)) return true;
    return false;
}

pub fn hasOwner(tables: []const Table, who: []const u8) bool {
    for (tables) |t| if (std.mem.eql(u8, owner(t), who) and t.rules > 0) return true;
    return false;
}

/// Tables the page lists as other programs' rules: everything except ours and
/// the manager's own. Empty iptables-nft shells ("filter" with no rules) are
/// left out.
pub fn foreign(a: Allocator, tables: []const Table, manager: []const u8) ![]model.Foreign {
    var list: std.ArrayList(model.Foreign) = .empty;
    for (tables) |t| {
        const who = owner(t);
        if (std.mem.eql(u8, who, "RediWM")) continue;
        if (manager.len != 0 and std.mem.eql(u8, who, manager)) continue;
        if (t.rules == 0) continue;
        try list.append(a, .{ .owner = if (who.len != 0) who else "", .name = try std.fmt.allocPrint(a, "{s} {s}", .{ t.family, t.name }), .rules = t.rules });
    }
    return list.toOwnedSlice(a);
}

/// `pfctl -s info`: "Status: Enabled for …" or "Status: Disabled".
pub fn pfEnabled(info: []const u8) bool {
    return std.mem.indexOf(u8, info, "Status: Enabled") != null;
}

/// Rule lines in `pfctl -sr` output, not counting our anchor's own line.
pub fn pfRuleCount(rules: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, rules, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "anchor \"rediwm\"")) continue;
        if (std.mem.startsWith(u8, line, "@")) continue;
        count += 1;
    }
    return count;
}

test "nft tables and owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"nftables": [{"metainfo": {"version": "1.1.7"}},
        \\ {"table": {"family": "ip", "name": "filter", "handle": 1}},
        \\ {"chain": {"family": "ip", "table": "filter", "name": "ufw-user-input", "handle": 2}},
        \\ {"rule": {"family": "ip", "table": "filter", "chain": "ufw-user-input", "handle": 3, "expr": []}},
        \\ {"table": {"family": "ip", "name": "nat", "handle": 4}},
        \\ {"chain": {"family": "ip", "table": "nat", "name": "DOCKER", "handle": 5}},
        \\ {"rule": {"family": "ip", "table": "nat", "chain": "DOCKER", "handle": 6, "expr": []}},
        \\ {"rule": {"family": "ip", "table": "nat", "chain": "DOCKER", "handle": 7, "expr": []}},
        \\ {"table": {"family": "inet", "name": "rediwm", "handle": 8}}
        \\]}
    ;
    const tables = try parseNft(a, json);
    try std.testing.expectEqual(@as(usize, 3), tables.len);
    try std.testing.expectEqualStrings("ufw", owner(tables[0]));
    try std.testing.expectEqualStrings("Docker", owner(tables[1]));
    try std.testing.expectEqual(@as(u32, 2), tables[1].rules);
    try std.testing.expect(hasTable(tables, "rediwm"));
    const others = try foreign(a, tables, "ufw");
    try std.testing.expectEqual(@as(usize, 1), others.len);
    try std.testing.expectEqualStrings("Docker", others[0].owner);
}

test "pf" {
    try std.testing.expect(pfEnabled("Status: Enabled for 0 days 00:10:02           Debug: Urgent\n"));
    try std.testing.expect(!pfEnabled("Status: Disabled for 0 days"));
    try std.testing.expectEqual(@as(u32, 2), pfRuleCount("scrub in all fragment reassemble\nanchor \"rediwm\" all\nblock drop in all\n"));
}
