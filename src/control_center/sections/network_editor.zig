//! The connection settings editor: auto-connect, IPv4 and IPv6 addressing, DNS,
//! MTU and metered for one saved connection. The values are read from the
//! profile when it opens and written back as a whole by Save (see
//! `network/manager_profile.zig`); nothing here talks to D-Bus directly.

const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const network = @import("../../network/manager.zig");
const profile_mod = @import("../../network/manager_profile.zig");
const ui = @import("ui");
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const widgets = @import("network_ui.zig");
const text = widgets.text;
const group = widgets.group;
const card = widgets.card;
const action = widgets.action;

pub const Field = enum { v4_address, v4_prefix, v4_gateway, v6_address, v6_prefix, v6_gateway, dns, mtu };
const fields = @import("network_fields.zig");

/// Select indices for a family's method; the last exists only for a method the
/// editor cannot express (shared), which then stays as it is.
fn methodLabels(other: bool) []const []const u8 {
    return if (other) panel.translatedLabels(&.{ i18n.msg("Automatic"), i18n.msg("Manual"), i18n.msg("Link-local only"), i18n.msg("Disabled"), i18n.msg("Other (unchanged)") }) else panel.translatedLabels(&.{ i18n.msg("Automatic"), i18n.msg("Manual"), i18n.msg("Link-local only"), i18n.msg("Disabled") });
}
fn dnsLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Automatic"), i18n.msg("Custom") });
}
fn meteredLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Automatic"), i18n.msg("Yes"), i18n.msg("No") });
}

pub const State = struct {
    open: bool = false,
    path: network.Path = .{},
    /// The fields hold the profile at `path` (filled once per opening).
    filled: bool = false,
    v4: usize = 0,
    v6: usize = 0,
    v4_other: bool = false,
    v6_other: bool = false,
    dns_custom: bool = false,
    metered: usize = 0,
    autoconnect: bool = true,
    forget_armed: bool = false,
    problem: []const u8 = "",
    fields: fields.Slots(Field) = .{},

    pub fn capture(s: *State) void {
        s.fields.capture();
    }
    pub fn close(s: *State) void {
        s.fields.release();
        s.* = .{};
    }
};

fn methodIndex(method: network.Method, other: *bool) usize {
    return switch (method) {
        .auto => 0,
        .manual => 1,
        .link_local => 2,
        .disabled => 3,
        .shared, .other => blk: {
            other.* = true;
            break :blk 4;
        },
    };
}

fn methodOf(index: usize) network.Method {
    return switch (index) {
        0 => .auto,
        1 => .manual,
        2 => .link_local,
        3 => .disabled,
        else => .other,
    };
}

fn prefixText(buffer: []u8, prefix: u8) []const u8 {
    return if (prefix == 0) "" else std.fmt.bufPrint(buffer, "{d}", .{prefix}) catch "";
}

fn fill(s: *State, cc: *panel.ControlCenter, p: *const profile_mod.Profile) void {
    s.fields.release();
    s.v4_other = false;
    s.v6_other = false;
    s.v4 = methodIndex(p.v4.method, &s.v4_other);
    s.v6 = methodIndex(p.v6.method, &s.v6_other);
    var number: [8]u8 = undefined;
    const first4: profile_mod.Address = if (p.v4.count > 0) p.v4.addresses[0] else .{};
    const first6: profile_mod.Address = if (p.v6.count > 0) p.v6.addresses[0] else .{};
    s.fields.set(cc, .v4_address, first4.text.slice(), i18n.tr("192.168.1.20"));
    s.fields.set(cc, .v4_prefix, prefixText(&number, first4.prefix), i18n.tr("24"));
    s.fields.set(cc, .v4_gateway, p.v4.gateway.slice(), i18n.tr("192.168.1.1"));
    s.fields.set(cc, .v6_address, first6.text.slice(), i18n.tr("2001:db8::20"));
    s.fields.set(cc, .v6_prefix, prefixText(&number, first6.prefix), i18n.tr("64"));
    s.fields.set(cc, .v6_gateway, p.v6.gateway.slice(), i18n.tr("fe80::1"));
    var dns: [400]u8 = undefined;
    const joined = if (p.v4.dns.len != 0 and p.v6.dns.len != 0) std.fmt.bufPrint(&dns, "{s}, {s}", .{ p.v4.dns.slice(), p.v6.dns.slice() }) catch p.v4.dns.slice() else if (p.v4.dns.len != 0) p.v4.dns.slice() else p.v6.dns.slice();
    s.dns_custom = joined.len != 0;
    s.fields.set(cc, .dns, joined, i18n.tr("1.1.1.1, 2606:4700:4700::1111"));
    s.fields.set(cc, .mtu, if (p.mtu == 0) "" else std.fmt.bufPrint(&number, "{d}", .{p.mtu}) catch "", i18n.tr("Automatic"));
    s.metered = if (p.metered == 1) 1 else if (p.metered == 2) 2 else 0;
    s.autoconnect = p.autoconnect;
    s.filled = true;
}

/// Opens the editor on `path` and asks for its settings.
pub fn open(cc: *panel.ControlCenter, path: []const u8) void {
    const s = &cc.network.edit;
    if (path.len == 0) return;
    s.close();
    s.open = true;
    s.path = network.Path.init(path);
    if (cc.server.network) |m| m.readProfile(path);
    cc.refresh();
}

pub fn close(cc: *panel.ControlCenter) void {
    cc.network.edit.close();
    if (cc.server.network) |m| {
        m.profile = null;
        m.edit_message = "";
    }
    cc.refresh();
}

fn locked(m: *const network.Manager) bool {
    return m.access == .locked or m.access == .denied or m.unlocking;
}

const labeled = fields.labeled;

fn select(cc: *panel.ControlCenter, name: []const u8, labels: []const []const u8, selected: usize, id: usize) W {
    return .{ .name = name, .kind = .{ .select = .{ .labels = labels, .selected = selected, .owner = cc, .id = id, .on_change = selectChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } };
}

fn familyRows(s: *State, cc: *panel.ControlCenter, a: Allocator, items: *std.ArrayList(W), v6: bool) !void {
    const method = if (v6) s.v6 else s.v4;
    const other = if (v6) s.v6_other else s.v4_other;
    try items.append(a, try labeled(a, if (v6) i18n.tr("IPv6") else i18n.tr("IPv4"), select(cc, if (v6) "edit_v6_method" else "edit_v4_method", methodLabels(other), method, if (v6) 6 else 4)));
    if (method != 1) return;
    var row = try group(a, .row, &.{
        try s.fields.input(a, if (v6) .v6_address else .v4_address, if (v6) "edit_v6_address" else "edit_v4_address", i18n.tr("Address")),
        try s.fields.input(a, if (v6) .v6_prefix else .v4_prefix, if (v6) "edit_v6_prefix" else "edit_v4_prefix", i18n.tr("Prefix length")),
        try s.fields.input(a, if (v6) .v6_gateway else .v4_gateway, if (v6) "edit_v6_gateway" else "edit_v4_gateway", i18n.tr("Gateway")),
    });
    row.@"align" = .start;
    row.children[0].width = .{ .flex = 3 };
    row.children[1].width = .{ .flex = 1 };
    row.children[2].width = .{ .flex = 3 };
    try items.append(a, row);
}

/// The editor card, or null while closed.
pub fn build(cc: *panel.ControlCenter, a: Allocator) !?W {
    const s = &cc.network.edit;
    if (!s.open) return null;
    const m = cc.server.network orelse return null;
    var items: std.ArrayList(W) = .empty;
    var title = text(i18n.tr("Connection settings"), 20, false);
    title.width = .{ .flex = 1 };
    const profile = if (m.profile) |p| if (std.mem.eql(u8, p.path.slice(), s.path.slice())) &m.profile.? else null else null;
    if (profile) |p| {
        if (!s.filled) fill(s, cc, p);
        var name = text(try a.dupe(u8, if (std.unicode.utf8ValidateSlice(p.id.slice())) p.id.slice() else i18n.tr("Connection")), 12, true);
        name.width = .auto;
        try items.append(a, try group(a, .row, &.{ title, name }));
    } else {
        try items.append(a, title);
        try items.append(a, text(if (m.edit_message.len != 0) m.edit_message else i18n.tr("Loading connection settings…"), 12, true));
        var close_button = action(cc, "edit_cancel", i18n.tr("Close"), 0, cancelClicked, false);
        close_button.width = .auto;
        try items.append(a, close_button);
        var empty = try card(a, items.items);
        empty.name = "edit_card";
        return empty;
    }
    const busy = m.edit_busy or locked(m);
    try items.append(a, .{ .name = "edit_autoconnect", .kind = .{ .checkbox = .{ .label = i18n.tr("Connect automatically"), .checked = s.autoconnect, .owner = cc, .on_change = autoconnectChanged } }, .width = .{ .percent = 1 } });
    try familyRows(s, cc, a, &items, false);
    try familyRows(s, cc, a, &items, true);
    try items.append(a, try labeled(a, i18n.tr("DNS servers"), select(cc, "edit_dns_mode", dnsLabels(), if (s.dns_custom) 1 else 0, 20)));
    if (s.dns_custom) try items.append(a, try s.fields.input(a, .dns, "edit_dns", i18n.tr("Servers, separated by commas")));
    var lower = try group(a, .row, &.{
        try s.fields.input(a, .mtu, "edit_mtu", i18n.tr("MTU")),
        try labeled(a, i18n.tr("Metered connection"), select(cc, "edit_metered", meteredLabels(), s.metered, 10)),
    });
    lower.@"align" = .start;
    lower.children[0].width = .{ .flex = 1 };
    lower.children[1].width = .{ .flex = 1 };
    try items.append(a, lower);
    const message = if (s.problem.len != 0) s.problem else m.edit_message;
    if (message.len != 0) try items.append(a, text(message, 12, true));
    var forget = action(cc, "edit_forget", if (s.forget_armed) i18n.tr("Confirm forget") else i18n.tr("Forget connection"), 1, forgetClicked, busy);
    forget.kind.button.variant = .ghost;
    forget.width = .auto;
    var save = action(cc, "edit_save", i18n.tr("Save"), 0, saveClicked, busy);
    save.kind.button.variant = .primary;
    const cancel = action(cc, "edit_cancel", i18n.tr("Cancel"), 0, cancelClicked, false);
    var spacer: W = .{ .kind = .container, .width = .{ .flex = 1 } };
    spacer.height = .{ .fixed = 1 };
    try items.append(a, try group(a, .row, &.{ forget, spacer, cancel, save }));
    var result = try card(a, items.items);
    result.name = "edit_card";
    return result;
}

fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}

fn selectChanged(raw: ?*anyopaque, id: usize, index: usize) void {
    const cc = owner(raw);
    const s = &cc.network.edit;
    s.fields.capture();
    switch (id) {
        4 => s.v4 = index,
        6 => s.v6 = index,
        10 => s.metered = index,
        20 => s.dns_custom = index == 1,
        else => {},
    }
    s.problem = "";
    cc.refresh();
}

fn autoconnectChanged(raw: ?*anyopaque, _: usize, value: bool) void {
    owner(raw).network.edit.autoconnect = value;
}

fn cancelClicked(raw: ?*anyopaque, _: usize) void {
    close(owner(raw));
}

fn forgetClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const s = &cc.network.edit;
    const m = cc.server.network orelse return;
    if (!s.forget_armed) {
        s.forget_armed = true;
        cc.refresh();
        return;
    }
    m.forget(s.path.slice());
    close(cc);
}

fn parsePrefix(value: []const u8, max: u8) ?u8 {
    const n = std.fmt.parseInt(u8, std.mem.trim(u8, value, " "), 10) catch return null;
    return if (n >= 1 and n <= max) n else null;
}

fn validIp(value: []const u8, v6: bool) bool {
    const t = std.mem.trim(u8, value, " ");
    if (v6) _ = std.Io.net.Ip6Address.parse(t, 0) catch return false else _ = std.Io.net.Ip4Address.parse(t, 0) catch return false;
    return true;
}

/// Reads one family's fields into `f`, or names the problem.
fn collectFamily(s: *const State, f: *profile_mod.Family, index: usize, v6: bool) ?[]const u8 {
    const method = methodOf(index);
    f.method = method;
    if (method == .other or method != .manual) return null;
    const address = std.mem.trim(u8, s.fields.value(if (v6) .v6_address else .v4_address), " ");
    const prefix = parsePrefix(s.fields.value(if (v6) .v6_prefix else .v4_prefix), if (v6) 128 else 32) orelse return if (v6) i18n.tr("Enter an IPv6 prefix length from 1 to 128.") else i18n.tr("Enter an IPv4 prefix length from 1 to 32.");
    if (!validIp(address, v6)) return if (v6) i18n.tr("Enter a valid IPv6 address.") else i18n.tr("Enter a valid IPv4 address.");
    const gateway = std.mem.trim(u8, s.fields.value(if (v6) .v6_gateway else .v4_gateway), " ");
    if (gateway.len != 0 and !validIp(gateway, v6)) return if (v6) i18n.tr("The IPv6 gateway is not a valid address.") else i18n.tr("The IPv4 gateway is not a valid address.");
    f.addresses[0] = .{ .text = network.Text(48).init(address), .prefix = prefix };
    if (f.count == 0) f.count = 1;
    f.gateway.set(gateway);
    return null;
}

fn collectDns(s: *const State, p: *profile_mod.Profile) ?[]const u8 {
    p.v4.dns = .{};
    p.v6.dns = .{};
    p.v4.ignore_auto_dns = false;
    p.v6.ignore_auto_dns = false;
    if (!s.dns_custom) return null;
    var any = false;
    var items = std.mem.tokenizeAny(u8, s.fields.value(.dns), ", ");
    while (items.next()) |item| {
        const v6 = std.mem.indexOfScalar(u8, item, ':') != null;
        if (!validIp(item, v6)) return i18n.tr("Check the DNS server addresses.");
        @import("../../network/manager_props.zig").append(if (v6) &p.v6.dns else &p.v4.dns, item);
        any = true;
    }
    if (!any) return i18n.tr("Enter at least one DNS server, or choose Automatic.");
    p.v4.ignore_auto_dns = true;
    p.v6.ignore_auto_dns = true;
    return null;
}

fn saveClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const s = &cc.network.edit;
    const m = cc.server.network orelse return;
    var p = (m.profile orelse return);
    s.problem = "";
    p.autoconnect = s.autoconnect;
    p.metered = if (s.metered == 1) 1 else if (s.metered == 2) 2 else 0;
    const mtu = std.mem.trim(u8, s.fields.value(.mtu), " ");
    if (mtu.len == 0) p.mtu = 0 else {
        const n = std.fmt.parseInt(u32, mtu, 10) catch 0;
        if (n < 576 or n > 9000) {
            s.problem = i18n.tr("The MTU must be between 576 and 9000, or empty.");
            return cc.refresh();
        }
        p.mtu = n;
    }
    if (collectFamily(s, &p.v4, s.v4, false) orelse collectFamily(s, &p.v6, s.v6, true) orelse collectDns(s, &p)) |problem| {
        s.problem = problem;
        return cc.refresh();
    }
    m.saveProfile(p);
    s.forget_armed = false;
    cc.refresh();
}
