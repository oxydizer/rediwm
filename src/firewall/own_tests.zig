const std = @import("std");
const own = @import("own.zig");
const model = @import("model.zig");

fn render(a: std.mem.Allocator, state: own.State, pf: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    if (pf) try own.renderPf(&out.writer, state, false) else try own.renderNft(&out.writer, state, &.{});
    return out.written();
}

const sample_rules = [_]model.Rule{
    .{ .service = "ssh", .source = "lan", .comment = "ssh" },
    .{ .port = "8000-8100", .proto = .both },
    .{ .source = "203.0.113.9", .action = .deny },
    .{ .service = "mdns", .scope = .home },
    .{ .port = "25", .proto = .tcp, .direction = .out, .action = .reject },
    .{ .port = "22", .proto = .tcp, .action = .limit, .family = .v6 },
};

test "nft table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, .{ .enabled = true, .rules = &sample_rules, .logging = .low, .ping = false, .home_ifaces = &.{"wlan0"} }, false);
    const expect = [_][]const u8{
        "table inet rediwm\ndelete table inet rediwm\ntable inet rediwm {",
        "elements = { \"wlan0\" }",
        "policy drop;",
        "\t\t ip saddr @lan4 tcp dport 22 accept comment \"ssh\"\n",
        "\t\t ip6 saddr @lan6 tcp dport 22 accept comment \"ssh\"\n",
        "\t\t meta l4proto { tcp, udp } th dport 8000-8100 accept\n",
        "\t\t ip saddr 203.0.113.9 drop\n",
        "\t\t iifname @home_ifaces udp dport 5353 accept\n",
        "\t\t tcp dport 25 reject\n",
        "\t\t meta nfproto ipv6 tcp dport 22 ct state new limit rate over 6/minute burst 6 packets drop\n",
        "icmp type echo-request drop",
        "limit rate 5/minute log prefix \"rediwm-drop \" level info",
    };
    for (expect) |piece| {
        if (std.mem.indexOf(u8, text, piece) == null) {
            std.debug.print("missing {s}\nin\n{s}\n", .{ piece, text });
            return error.TestUnexpectedResult;
        }
    }
    // Blocks come before allows in the input chain.
    try std.testing.expect(std.mem.indexOf(u8, text, "203.0.113.9 drop").? < std.mem.indexOf(u8, text, "@lan4 tcp dport 22").?);
}

test "pf anchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, .{ .enabled = true, .rules = &sample_rules, .home_ifaces = &.{ "em0", "wlan0" } }, true);
    const expect = [_][]const u8{
        "pass quick on lo0 all\n",
        "pass in quick proto tcp from <rediwm_lan> to any port 22 keep state label \"ssh\"\n",
        "pass in quick proto { tcp udp } from any to any port 8000:8100 keep state\n",
        "block drop in quick inet from 203.0.113.9 to any\n",
        "pass in quick on { em0 wlan0 } proto udp from any to any port 5353 keep state\n",
        "block return out quick proto tcp from any to any port 25\n",
        "pass in quick inet6 proto tcp from any to any port 22 keep state (max-src-conn-rate 6/30, overload <rediwm_abuse> flush global)\n",
        "block drop in quick all\n",
        "pass out quick all keep state\n",
    };
    for (expect) |piece| {
        if (std.mem.indexOf(u8, text, piece) == null) {
            std.debug.print("missing {s}\nin\n{s}\n", .{ piece, text });
            return error.TestUnexpectedResult;
        }
    }
    var locked: std.Io.Writer.Allocating = .init(a);
    try own.renderPf(&locked.writer, .{}, true);
    try std.testing.expect(std.mem.endsWith(u8, locked.written(), "pass quick on lo0 all\nblock drop quick all\n"));
}

test "pf.conf anchor insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conf = "ext_if=\"em0\"\nset skip on lo0\nscrub in all\nblock in all\npass out all keep state\n";
    try std.testing.expect(!own.pfConfHasAnchor(conf).anchor);
    const updated = try own.pfConfWithAnchor(a, conf, "/usr/local/etc/rediwm/pf.rediwm.conf");
    try std.testing.expect(std.mem.indexOf(u8, updated, "scrub in all\nanchor \"rediwm\"\nload anchor \"rediwm\" from \"/usr/local/etc/rediwm/pf.rediwm.conf\"\nblock in all") != null);
    const has = own.pfConfHasAnchor(updated);
    try std.testing.expect(has.anchor and has.load);
}

test "lockdown table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try own.renderLockdownNft(&out.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "type filter hook input priority -200; policy drop;\n\t\tiif \"lo\" accept") != null);
    var off: std.Io.Writer.Allocating = .init(arena.allocator());
    try own.renderLockdownNft(&off.writer, false);
    try std.testing.expectEqualStrings("table inet rediwm_lockdown\ndelete table inet rediwm_lockdown\n", off.written());
}

test "state round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try std.json.Stringify.valueAlloc(a, own.State{ .enabled = true, .rules = &sample_rules }, .{});
    const back = try std.json.parseFromSliceLeaky(own.State, a, json, .{ .ignore_unknown_fields = true });
    try std.testing.expect(back.enabled);
    try std.testing.expectEqual(sample_rules.len, back.rules.len);
    try std.testing.expect(own.sameRule(sample_rules[0], back.rules[0]));
}
