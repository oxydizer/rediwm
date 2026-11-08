//! The rows that describe a connection (addresses, gateway, DNS, hardware and
//! link details), for the wired adapter and the Wi-Fi network in use. Each
//! address row has a copy button.

const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const network = @import("../../network/manager.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const widgets = @import("network_ui.zig");
const text = widgets.text;
const group = widgets.group;
const status = widgets.status;
const action = widgets.action;

/// What a copy button copies. The value is also the button's id; Wi-Fi
/// buttons add `wifi_offset`.
pub const Field = enum(usize) { address4 = 0, gateway4 = 1, dns4 = 2, mac = 3, address6 = 4, gateway6 = 5, dns6 = 6, domains = 7, bssid = 8 };
pub const wifi_offset: usize = 100;

pub fn speed(a: Allocator, eth: network.Ethernet) ![]const u8 {
    if (!eth.carrier or eth.speed == 0) return "—";
    return if (eth.speed >= 1000) std.fmt.allocPrint(a, "{d:.1} Gbps", .{@as(f32, @floatFromInt(eth.speed)) / 1000}) else std.fmt.allocPrint(a, "{d} Mbps", .{eth.speed});
}

pub fn chosenEthernet(s: anytype, m: *network.Manager) ?*const network.Ethernet {
    for (m.ethernet[0..m.ethernet_count]) |*eth| if (std.mem.eql(u8, s.ethernet_path.slice(), eth.path.slice())) return eth;
    if (m.ethernet_count == 0) return null;
    var selected: *const network.Ethernet = &m.ethernet[0];
    for (m.ethernet[0..m.ethernet_count]) |*eth| if (eth.connected()) {
        selected = eth;
        break;
    };
    s.ethernet_path = selected.path;
    return selected;
}

pub fn methodLabel(method: network.Method) []const u8 {
    return switch (method) {
        .auto => i18n.tr("Automatic"),
        .manual => i18n.tr("Manual"),
        .link_local => i18n.tr("Link-local only"),
        .shared => i18n.tr("Shared"),
        .disabled => i18n.tr("Disabled"),
        .other => i18n.tr("Other"),
    };
}

pub fn securityLabel(security: network.Security) []const u8 {
    return switch (security) {
        .open => i18n.tr("Open"),
        .personal => i18n.tr("WPA2/WPA3 Personal"),
        .sae => i18n.tr("WPA3 Personal"),
        .unsupported => i18n.tr("Other"),
    };
}

/// "5 GHz · channel 36" from a frequency in MHz.
pub fn band(a: Allocator, mhz: u32) ![]const u8 {
    if (mhz == 0) return "";
    const ghz: []const u8, const channel: u32 = if (mhz < 3000) .{ "2.4 GHz", if (mhz == 2484) 14 else (mhz -| 2407) / 5 } else if (mhz < 5925) .{ "5 GHz", (mhz -| 5000) / 5 } else .{ "6 GHz", (mhz -| 5950) / 5 };
    const buffer = try a.alloc(u8, 64);
    return i18n.fmt(buffer, i18n.tr("{band} · channel {channel}"), .{ .band = ghz, .channel = channel }) catch ghz;
}

/// The profile an active connection was made from.
pub fn profileOf(m: *const network.Manager, active: []const u8) ?*const network.Saved {
    for (m.actives[0..m.active_count]) |act| if (std.mem.eql(u8, act.path.slice(), active)) return network.savedAt(m, act.profile.slice());
    return null;
}

fn configuration(a: Allocator, saved: ?*const network.Saved) ![]const u8 {
    const profile = saved orelse return "";
    const buffer = try a.alloc(u8, 96);
    return i18n.fmt(buffer, i18n.tr("IPv4 {v4} · IPv6 {v6}"), .{ .v4 = methodLabel(profile.method4), .v6 = methodLabel(profile.method6) }) catch "";
}

/// One "title  value" row; `copy` adds a copy button when the value is not empty.
pub fn detail(cc: *panel.ControlCenter, a: Allocator, prefix: []const u8, title: []const u8, value: []const u8, copy: ?Field, active: bool, status_chip: bool) !W {
    var key_label = text(title, 12, true);
    key_label.width = .auto;
    key_label.min_width = 96;
    var val = if (status_chip) try status(a, value, active) else text(if (value.len == 0) "—" else try a.dupe(u8, value), 12, true);
    val.width = .{ .flex = 1 };
    var row = try group(a, .row, &.{ key_label, val });
    row.height = .{ .fixed = 30 };
    if (copy) |field| {
        const id = @intFromEnum(field) + if (std.mem.eql(u8, prefix, "wifi")) wifi_offset else 0;
        var button = action(cc, try std.fmt.allocPrint(a, "{s}_copy_{d}", .{ prefix, @intFromEnum(field) }), "", id, copyDetail, value.len == 0);
        button.kind.button.icon = if (cc.network.copied == id) .checkmark else .copy;
        button.kind.button.variant = .ghost;
        button.width = .{ .fixed = 26 };
        button.height = .{ .fixed = 26 };
        row.children = try a.dupe(W, &.{ key_label, val, button });
    }
    return row;
}

fn linkRows(cc: *panel.ControlCenter, a: Allocator, prefix: []const u8, link: *const network.Link, mac: []const u8, rows: *std.ArrayList(W)) !void {
    try rows.append(a, try detail(cc, a, prefix, i18n.tr("IPv4 address"), link.v4.address.slice(), .address4, false, false));
    try rows.append(a, try detail(cc, a, prefix, i18n.tr("Gateway"), link.v4.gateway.slice(), .gateway4, false, false));
    try rows.append(a, try detail(cc, a, prefix, i18n.tr("DNS servers"), link.v4.dns.slice(), .dns4, false, false));
    // IPv6 is often absent; only the address is always listed.
    try rows.append(a, try detail(cc, a, prefix, i18n.tr("IPv6 address"), link.v6.address.slice(), .address6, false, false));
    if (link.v6.gateway.len != 0) try rows.append(a, try detail(cc, a, prefix, i18n.tr("IPv6 gateway"), link.v6.gateway.slice(), .gateway6, false, false));
    if (link.v6.dns.len != 0) try rows.append(a, try detail(cc, a, prefix, i18n.tr("IPv6 DNS servers"), link.v6.dns.slice(), .dns6, false, false));
    var domains: network.Text(256) = link.v4.domains;
    if (link.v6.domains.len != 0 and domains.len == 0) domains = link.v6.domains;
    if (domains.len != 0) try rows.append(a, try detail(cc, a, prefix, i18n.tr("Search domains"), domains.slice(), .domains, false, false));
    try rows.append(a, try detail(cc, a, prefix, i18n.tr("MAC address"), mac, .mac, false, false));
}

/// The Ethernet card's rows.
pub fn ethernetRows(cc: *panel.ControlCenter, a: Allocator, eth: ?*const network.Ethernet) ![]W {
    var rows: std.ArrayList(W) = .empty;
    const e = eth orelse &network.Ethernet{};
    try rows.append(a, try detail(cc, a, "ethernet", i18n.tr("Status"), if (eth != null) e.status() else i18n.tr("Unavailable"), null, e.connected(), true));
    try rows.append(a, try detail(cc, a, "ethernet", i18n.tr("Link speed"), if (eth != null) try speed(a, e.*) else "—", null, false, false));
    if (e.connected()) {
        const config = try configuration(a, if (cc.server.network) |m| profileOf(m, e.active_connection.slice()) else null);
        if (config.len != 0) try rows.append(a, try detail(cc, a, "ethernet", i18n.tr("Configuration"), config, null, false, false));
    }
    try linkRows(cc, a, "ethernet", &e.link, e.mac.slice(), &rows);
    return rows.items;
}

/// The expanded Wi-Fi row of the connected network.
pub fn wifiRows(cc: *panel.ControlCenter, a: Allocator, net: network.Network) ![]W {
    const m = cc.server.network orelse return &.{};
    var rows: std.ArrayList(W) = .empty;
    try rows.append(a, try detail(cc, a, "wifi", i18n.tr("Security"), securityLabel(net.security), null, false, false));
    try rows.append(a, try detail(cc, a, "wifi", i18n.tr("Signal"), try std.fmt.allocPrint(a, "{d}%", .{net.strength}), null, false, false));
    const channel = try band(a, net.frequency);
    if (channel.len != 0) try rows.append(a, try detail(cc, a, "wifi", i18n.tr("Band"), channel, null, false, false));
    if (m.wifi.bitrate != 0) try rows.append(a, try detail(cc, a, "wifi", i18n.tr("Link speed"), try std.fmt.allocPrint(a, "{d} Mbps", .{m.wifi.bitrate / 1000}), null, false, false));
    if (net.bssid.len != 0) try rows.append(a, try detail(cc, a, "wifi", i18n.tr("Access point"), net.bssid.slice(), .bssid, false, false));
    const config = try configuration(a, network.savedAt(m, m.wifi.profile.slice()));
    if (config.len != 0) try rows.append(a, try detail(cc, a, "wifi", i18n.tr("Configuration"), config, null, false, false));
    try linkRows(cc, a, "wifi", &m.wifi.link, m.wifi.mac.slice(), &rows);
    return rows.items;
}

/// The first address of a list, without its "/prefix".
pub fn bareAddress(value: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, value, "/,") orelse value.len;
    return value[0..end];
}

/// Text for a copy button, without the "/prefix" parts that address rows show.
fn bare(buffer: []u8, value: []const u8) []const u8 {
    var len: usize = 0;
    var skipping = false;
    for (value) |ch| {
        if (ch == '/') skipping = true else if (ch == ',') skipping = false;
        if (skipping or len == buffer.len) continue;
        buffer[len] = ch;
        len += 1;
    }
    return buffer[0..len];
}

fn copyDetail(raw: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(raw.?));
    const m = cc.server.network orelse return;
    const wifi = id >= wifi_offset;
    const field: Field = std.enums.fromInt(Field, if (wifi) id - wifi_offset else id) orelse return;
    const link: *const network.Link, const mac: []const u8 = if (wifi) .{ &m.wifi.link, m.wifi.mac.slice() } else blk: {
        const eth = chosenEthernet(&cc.network, m) orelse return;
        break :blk .{ &eth.link, eth.mac.slice() };
    };
    var bssid: []const u8 = "";
    if (wifi) for (m.networks[0..m.count]) |net| if (net.connected) {
        bssid = net.bssid.slice();
    };
    const value = switch (field) {
        .address4 => link.v4.address.slice(),
        .gateway4 => link.v4.gateway.slice(),
        .dns4 => link.v4.dns.slice(),
        .mac => mac,
        .address6 => link.v6.address.slice(),
        .gateway6 => link.v6.gateway.slice(),
        .dns6 => link.v6.dns.slice(),
        .domains => if (link.v4.domains.len != 0) link.v4.domains.slice() else link.v6.domains.slice(),
        .bssid => bssid,
    };
    if (value.len == 0) return;
    var buffer: [256]u8 = undefined;
    @import("../../clipboard.zig").copyText(cc.server, bare(&buffer, value));
    cc.network.copied = id;
    cc.refresh();
}

test "copied addresses lose their prefix lengths" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.100", bare(&buffer, "192.168.1.100/24"));
    try std.testing.expectEqualStrings("10.0.0.2, fe80::1", bare(&buffer, "10.0.0.2/24, fe80::1/64"));
    try std.testing.expectEqualStrings("1.1.1.1, 1.0.0.1", bare(&buffer, "1.1.1.1, 1.0.0.1"));
}
