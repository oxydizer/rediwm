//! Live NetworkManager settings. Widget storage belongs to the window;
//! passwords stay in locked, wiped storage, never in the tree's arena.
const std = @import("std");
const panel = @import("../panel.zig");
const network = @import("../../network/manager.zig");
const secure = @import("../../network/secure_allocator.zig").allocator;
const gpa = @import("../../main.zig").gpa;
const ui = @import("ui");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    ethernet_path: network.Path = .{},
    ethernet_paths: [16]network.Path = @splat(.{}),
    ethernet_count: usize = 0,
    rows: [256]network.Network = @splat(.{}),
    row_count: usize = 0,
    selected: ?network.Network = null,
    hidden: bool = false,
    security: network.Security = .personal,
    autojoin: bool = true,
    revealed: bool = false,
    password: ui.widgets.secret_input.Input = .{ .storage = @constCast(&[_]u8{}) },
    name_data: ?ui.layout.TextInputData = null,
    name_field: ?*W = null,
    list: ?*W = null,
    focus_name: network.Text(256) = .{},
    focus_requested: bool = false,
    message: []const u8 = "",
    copied: ?usize = null,

    pub fn clearForm(s: *Section) void {
        s.password.clear();
        s.revealed = false;
        s.selected = null;
        s.hidden = false;
        s.message = "";
        if (s.name_field) |field| s.name_data = field.kind.text_input;
        if (s.name_data) |data| gpa.free(data.value);
        if (s.name_field) |field| field.kind.text_input.value = @constCast(&[_]u8{});
        s.name_field = null;
        s.name_data = null;
        s.focus_name = .{};
        s.focus_requested = false;
    }
    pub fn deinit(s: *Section) void {
        s.clearForm();
        if (s.password.storage.len != 0) secure.free(s.password.storage);
        s.arena.deinit();
    }
    pub fn captureFocus(s: *Section) void {
        if (s.focus_requested) return;
        s.focus_name = .{};
        if (ui.input.current.focused) |widget| if (widget.name) |name| s.focus_name.set(name);
    }
};

fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}
fn icon(id: ui.layout.IconId, size: f32, accent: bool) W {
    return .{ .kind = .{ .icon = .{ .id = id, .color = if (accent) panel.palette().accent else panel.palette().fg } }, .width = .{ .fixed = size }, .height = .{ .fixed = size } };
}
fn group(a: Allocator, direction: ui.layout.Direction, items: []const W) !W {
    return .{ .kind = .container, .direction = direction, .gap = 10, .@"align" = if (direction == .row) .center else .stretch, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}
fn card(a: Allocator, items: []const W) !W {
    var w = try group(a, .column, items);
    const t = panel.palette();
    w.kind = .{ .rect = .{ .color = t.app_item, .radius = 9, .border_width = 1, .border_color = t.app_item_border } };
    w.padding = ui.layout.Edges.all(16);
    w.gap = 14;
    return w;
}
fn divider(vertical: bool) W {
    return .{ .kind = .{ .rect = .{ .color = panel.palette().border_soft } }, .width = if (vertical) .{ .fixed = 1 } else .{ .percent = 1 }, .height = if (vertical) .{ .fixed = 58 } else .{ .fixed = 1 } };
}
fn status(a: Allocator, value: []const u8, active: bool) !W {
    var label = text(value, 13, true);
    label.width = .{ .flex = 1 };
    if (active) label.kind.text.color = panel.palette().accent;
    return group(a, .row, &.{
        .{ .kind = .{ .rect = .{ .color = if (active) panel.palette().accent else panel.palette().dim, .radius = 4 } }, .width = .{ .fixed = 7 }, .height = .{ .fixed = 7 } },
        label,
    });
}
fn summary(a: Allocator, glyph: ui.layout.IconId, title: []const u8, state: []const u8, description: []const u8, active: bool) !W {
    var labels = try group(a, .column, &.{ text(title, 14, false), try status(a, state, active), text(description, 12, true) });
    labels.width = .{ .flex = 1 };
    labels.gap = 5;
    var w = try group(a, .row, &.{ icon(glyph, 30, active), labels });
    w.width = .{ .flex = 1 };
    return w;
}
fn action(cc: *panel.ControlCenter, name: []const u8, value: []const u8, id: usize, callback: *const fn (?*anyopaque, usize) void, disabled: bool) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = value, .owner = cc, .id = id, .on_click = callback, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 } };
}
fn switchWidget(cc: *panel.ControlCenter, name: []const u8, id: usize, on: bool, disabled: bool) W {
    return .{ .name = name, .kind = .{ .toggle = .{ .style = .settings, .on = on, .disabled = disabled, .owner = cc, .id = id, .on_change = switched } } };
}
fn speed(a: Allocator, eth: network.Ethernet) ![]const u8 {
    if (!eth.carrier or eth.speed == 0) return "—";
    return if (eth.speed >= 1000) std.fmt.allocPrint(a, "{d:.1} Gbps", .{@as(f32, @floatFromInt(eth.speed)) / 1000}) else std.fmt.allocPrint(a, "{d} Mbps", .{eth.speed});
}
fn chosenEthernet(s: *Section, m: *network.Manager) ?*const network.Ethernet {
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

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    const saved_scroll = if (s.list) |list| list.kind.scroll_container else ui.layout.ScrollState{};
    if (s.name_field) |field| s.name_data = field.kind.text_input;
    s.name_field = null;
    s.list = null;
    _ = s.arena.reset(.retain_capacity);
    // A service/radio change closes the form and wipes any entered secret.
    if (cc.server.network) |m| {
        if (!m.available or !m.enabled or !m.hardware or m.device.len == 0) s.clearForm();
        if (s.selected) |selected| {
            const found = for (m.networks[0..m.count]) |net| {
                if (network.sameNetwork(selected, net)) break net;
            } else null;
            if (found) |net| {
                s.selected = net;
                if (net.connected) {
                    s.password.clear();
                    s.revealed = false;
                }
            } else s.clearForm();
        }
    } else s.clearForm();
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
    if (s.list) |list| list.kind.scroll_container = saved_scroll;
}
fn tree(s: *Section, cc: *panel.ControlCenter, a: Allocator) !W {
    const m = cc.server.network;
    const available = if (m) |n| n.available else false;
    const eth = if (m) |n| chosenEthernet(s, n) else null;
    const connected_wifi: ?*const network.Network = if (m) |n| for (n.networks[0..n.count]) |*net| {
        if (net.connected) break net;
    } else null else null;
    const online = available and m.?.connectivity == 4;
    const internet_state: []const u8 = if (!available) "Unavailable" else switch (m.?.connectivity) {
        2 => "Sign-in required",
        3 => "Limited access",
        4 => "Connected",
        else => if (m.?.state >= 50) "Connected" else "Offline",
    };
    const internet_detail: []const u8 = if (!available) "NetworkManager unavailable" else switch (m.?.connectivity) {
        2 => "Open a browser to sign in",
        3 => "No internet access",
        4 => "You're online.",
        else => if (m.?.state >= 50) "Internet access not verified" else "No internet connection",
    };
    const wifi_state: []const u8 = if (!available) "Unavailable" else if (!m.?.hardware) "Hardware blocked" else if (!m.?.enabled) "Turned off" else if (m.?.device.len == 0) "No adapter" else if (connected_wifi != null) "Connected" else "Not connected";
    const eth_detail = if (eth) |e| if (e.connected() and e.address.len != 0) try std.fmt.allocPrint(a, "{s} · {s}", .{ try speed(a, e.*), e.address.slice() }) else try a.dupe(u8, e.name.slice()) else "No wired adapter";
    const wifi_detail = if (connected_wifi) |net| try std.fmt.allocPrint(a, "{s} · {s}", .{ network.networkName(net), if (net.strength >= 80) @as([]const u8, "Excellent") else if (net.strength >= 55) "Good" else "Weak" }) else "Wireless connections";
    const stacked = cc.panel_box.width < 1000;
    var overview = try card(a, &.{
        try summary(a, .globe, "Internet", internet_state, internet_detail, online),
        divider(!stacked),
        try summary(a, .ethernet, "Ethernet", if (eth) |e| e.status() else "Unavailable", eth_detail, if (eth) |e| e.connected() else false),
        divider(!stacked),
        try summary(a, .wifi, "Wi-Fi", wifi_state, wifi_detail, connected_wifi != null),
    });
    overview.name = "network_overview";
    overview.direction = if (stacked) .column else .row;
    overview.@"align" = .stretch;
    for (overview.children) |*child| {
        if (child.kind == .container and stacked) child.width = .{ .percent = 1 };
    }
    var ethernet = try ethernetCard(s, cc, a, eth);
    var wifi = try wifiCard(s, cc, a);
    ethernet.width = if (stacked) .{ .percent = 1 } else .{ .flex = 1 };
    wifi.width = ethernet.width;
    var columns = try group(a, if (stacked) .column else .row, &.{ ethernet, wifi });
    columns.@"align" = .start;
    columns.gap = 16;
    return group(a, .column, &.{ overview, columns });
}
fn ethernetCard(s: *Section, cc: *panel.ControlCenter, a: Allocator, eth: ?*const network.Ethernet) !W {
    const m = cc.server.network;
    const subtitle = if (eth) |e| if (e.driver.len != 0) try std.fmt.allocPrint(a, "{s} ({s})", .{ e.name.slice(), e.driver.slice() }) else try a.dupe(u8, e.name.slice()) else "No wired adapter found";
    var labels = try group(a, .column, &.{ text("Ethernet", 20, false), text(subtitle, 12, true) });
    labels.width = .{ .flex = 1 };
    labels.gap = 4;
    const disabled = if (eth) |e| !e.managed or (!e.carrier and !e.active()) or m.?.wired_pending != null else true;
    const header = try group(a, .row, &.{ icon(.ethernet, 28, false), labels, switchWidget(cc, "ethernet_enabled", 0, if (eth) |e| e.active() else false, disabled) });
    var items: std.ArrayList(W) = .empty;
    try items.append(a, header);
    s.ethernet_count = if (m) |n| n.ethernet_count else 0;
    if (s.ethernet_count > 1) {
        const names = try a.alloc([]const u8, s.ethernet_count);
        var selected: usize = 0;
        for (m.?.ethernet[0..s.ethernet_count], 0..) |e, i| {
            s.ethernet_paths[i] = e.path;
            names[i] = try a.dupe(u8, e.name.slice());
            if (std.mem.eql(u8, e.path.slice(), s.ethernet_path.slice())) selected = i;
        }
        try items.append(a, .{ .name = "ethernet_adapter", .kind = .{ .select = .{ .labels = names, .selected = selected, .owner = cc, .on_change = adapterChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } });
    }
    var details = try card(a, &.{
        try detail(cc, a, "Status", if (eth) |e| e.status() else "Unavailable", null, if (eth) |e| e.connected() else false),
        try detail(cc, a, "Link speed", if (eth) |e| try speed(a, e.*) else "—", null, false),
        try detail(cc, a, "IPv4 address", if (eth) |e| e.address.slice() else "", 0, false),
        try detail(cc, a, "Gateway", if (eth) |e| e.gateway.slice() else "", 1, false),
        try detail(cc, a, "DNS servers", if (eth) |e| e.dns.slice() else "", 2, false),
        try detail(cc, a, "MAC address", if (eth) |e| e.mac.slice() else "", 3, false),
    });
    details.gap = 6;
    try items.append(a, details);
    if (m) |n| {
        if (n.wired_message.len > 0) try items.append(a, text(n.wired_message, 12, true));
    }
    var result = try card(a, items.items);
    result.name = "ethernet_card";
    return result;
}
fn detail(cc: *panel.ControlCenter, a: Allocator, title: []const u8, value: []const u8, copy_id: ?usize, active: bool) !W {
    var key_label = text(title, 12, true);
    key_label.width = .{ .fixed = 96 };
    var val = if (std.mem.eql(u8, title, "Status")) try status(a, value, active) else text(if (value.len == 0) "—" else try a.dupe(u8, value), 12, true);
    val.width = .{ .flex = 1 };
    var row = try group(a, .row, &.{ key_label, val });
    row.height = .{ .fixed = 30 };
    if (copy_id) |id| {
        var copy = action(cc, try std.fmt.allocPrint(a, "ethernet_copy_{d}", .{id}), "", id, copyDetail, value.len == 0);
        copy.kind.button.icon = if (cc.network.copied == id) .checkmark else .copy;
        copy.kind.button.variant = .ghost;
        copy.width = .{ .fixed = 26 };
        copy.height = .{ .fixed = 26 };
        row.children = try a.dupe(W, &.{ key_label, val, copy });
    }
    return row;
}
fn wifiCard(s: *Section, cc: *panel.ControlCenter, a: Allocator) !W {
    const m = cc.server.network;
    const available = if (m) |n| n.available and n.hardware and n.enabled and n.device.len != 0 else false;
    const busy = if (m) |n| n.busy else false;
    var title = text("Wi-Fi", 20, false);
    title.width = .{ .flex = 1 };
    var scan = action(cc, "wifi_scan", "", 0, scanClicked, !available or m.?.searching());
    scan.kind.button.icon = .refresh;
    scan.kind.button.variant = .ghost;
    scan.width = .{ .fixed = 30 };
    const header = try group(a, .row, &.{ title, scan, switchWidget(cc, "wifi_enabled", 1, if (m) |n| n.enabled else false, if (m) |n| !n.available or !n.hardware or n.device.len == 0 or n.busy else true) });
    var items: std.ArrayList(W) = .empty;
    try items.append(a, header);
    try items.append(a, divider(false));
    var rows: std.ArrayList(W) = .empty;
    s.row_count = if (available) m.?.count else 0;
    for (0..s.row_count) |i| {
        s.rows[i] = m.?.networks[i];
        const net = &s.rows[i];
        const selected = if (s.selected) |chosen| network.sameNetwork(chosen, net.*) else false;
        var labels = try group(a, .column, &.{ text(try a.dupe(u8, network.networkName(net)), 15, false), text(network.networkSubtitle(net.*), 12, true) });
        labels.width = .{ .flex = 1 };
        labels.gap = 5;
        var glyph = icon(.wifi, 26, false);
        glyph.kind.icon.color[3] *= 0.45 + @as(f32, @floatFromInt(net.strength)) / 100 * 0.55;
        const children = try a.dupe(W, &.{ glyph, labels, if (net.security != .open) icon(.lock, 14, false) else .{ .kind = .container, .width = .{ .fixed = 14 } }, if (selected or net.connected) icon(if (selected) .chevron_up else .chevron_right, 12, false) else .{ .kind = .container, .width = .{ .fixed = 12 } } });
        try rows.append(a, .{ .name = try std.fmt.allocPrint(a, "wifi_network_{d}", .{i}), .kind = .{ .row = .{ .owner = cc, .id = i, .on_click = networkClicked, .selected = selected or net.connected, .state = if (busy) .disabled else .idle } }, .height = .{ .fixed = 64 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(10, 0), .@"align" = .center, .gap = 10, .children = children });
        if (selected) try rows.append(a, try form(s, cc, a));
    }
    if (s.row_count == 0) {
        const message: []const u8 = if (m) |n| if (!n.available) "NetworkManager is unavailable" else if (!n.hardware) "Wi-Fi is disabled by the hardware switch" else if (!n.enabled) "Wi-Fi is turned off" else if (n.device.len == 0) "No Wi-Fi adapter found" else if (n.searching()) "Searching for networks…" else "No networks found. Scan to try again." else "NetworkManager is unavailable";
        var empty = try group(a, .column, &.{ icon(.wifi, 32, false), text(message, 13, true) });
        empty.padding = ui.layout.Edges.all(16);
        empty.gap = 16;
        try rows.append(a, empty);
    }
    if (available) {
        try rows.append(a, divider(false));
        var hidden = action(cc, "wifi_hidden", "Join Hidden Network", 0, hiddenClicked, busy);
        hidden.kind.button.variant = .ghost;
        hidden.kind.button.leading_icon = .plus;
        hidden.kind.button.trailing_icon = if (s.hidden) .chevron_up else .chevron_down;
        hidden.width = .{ .percent = 1 };
        hidden.height = .{ .fixed = 44 };
        try rows.append(a, hidden);
        if (s.hidden) try rows.append(a, try form(s, cc, a));
    }
    const list = try a.create(W);
    list.* = try group(a, .column, rows.items);
    list.name = "wifi_networks";
    list.kind = .{ .scroll_container = .{} };
    list.height = .{ .fixed = @max(220, @as(f32, @floatFromInt(cc.panel_box.height)) - 345) };
    list.padding.right = ui.widgets.scrollbar.gutter(ui.theme.global.scrollbar_width);
    list.gap = 4;
    try items.append(a, list.*);
    const message = if (s.message.len > 0) s.message else if (m) |n| n.message else "";
    if (message.len > 0 and available) try items.append(a, text(message, 12, true));
    var result = try card(a, items.items);
    result.name = "wifi_card";
    s.list = &result.children[2];
    return result;
}
fn form(s: *Section, cc: *panel.ControlCenter, a: Allocator) !W {
    if (s.selected) |net| {
        if (net.connected) return group(a, .column, &.{text("You're connected to this network", 12, true)});
        if (net.security == .unsupported and net.saved.len == 0) return group(a, .column, &.{text("Configure this network with a network tool", 12, true)});
    }
    var items: std.ArrayList(W) = .empty;
    if (s.hidden) {
        if (s.name_data == null) s.name_data = .{ .placeholder = "Network name (SSID)", .value = try gpa.dupe(u8, ""), .owner = cc, .on_change = nameChanged };
        const field = try a.create(W);
        field.* = .{ .name = "wifi_ssid", .kind = .{ .text_input = s.name_data.? }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
        try items.append(a, text("Network name", 12, true));
        try items.append(a, field.*);
        try items.append(a, text("Security", 12, true));
        try items.append(a, .{ .name = "wifi_security", .kind = .{ .select = .{ .labels = &.{ "WPA2 / WPA3 Personal", "WPA3 Personal", "Open" }, .selected = if (s.security == .personal) 0 else if (s.security == .sae) 1 else 2, .owner = cc, .on_change = securityChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } });
    }
    const net = s.selected orelse network.Network{ .security = s.security };
    if (net.security == .personal or net.security == .sae) {
        if (s.password.storage.len == 0) {
            s.password.storage = try secure.alloc(u8, 128);
            @memset(s.password.storage, 0);
        }
        try items.append(a, text(if (net.saved.len != 0) "Password (leave empty to use saved)" else "Password", 12, true));
        var reveal = action(cc, "wifi_reveal", "", 0, revealClicked, false);
        reveal.kind.button.icon = if (s.revealed) .eye else .eye_off;
        reveal.kind.button.variant = .ghost;
        reveal.width = .{ .fixed = 34 };
        try items.append(a, try group(a, .row, &.{
            .{ .name = "wifi_password", .kind = .{ .secret_input = .{ .placeholder = "Password", .input = &s.password, .revealed = s.revealed } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 36 } }, reveal,
        }));
    }
    if (net.saved.len == 0) try items.append(a, .{ .name = "wifi_autojoin", .kind = .{ .checkbox = .{ .label = "Connect automatically", .checked = s.autojoin, .owner = cc, .on_change = autojoinChanged } }, .width = .{ .percent = 1 } });
    var join = action(cc, "wifi_join", "Connect", 0, joinClicked, cc.server.network.?.busy);
    join.kind.button.variant = .primary;
    var buttons = try group(a, .row, &.{ action(cc, "wifi_cancel", "Cancel", 0, cancelClicked, false), join });
    buttons.justify = .end;
    try items.append(a, buttons);
    var result = try group(a, .column, items.items);
    result.padding = ui.layout.Edges.all(10);
    if (s.hidden) s.name_field = &result.children[1];
    return result;
}
fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}
fn switched(raw: ?*anyopaque, id: usize, on: bool) void {
    const cc = owner(raw);
    const m = cc.server.network orelse return;
    if (id == 0) {
        cc.network.copied = null;
        m.setEthernet(cc.network.ethernet_path, on);
    } else {
        cc.network.clearForm();
        if (m.enabled != on) m.toggle();
    }
    cc.refresh();
}
fn adapterChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    if (index >= cc.network.ethernet_count) return;
    cc.network.ethernet_path = cc.network.ethernet_paths[index];
    cc.network.copied = null;
    cc.refresh();
}
fn copyDetail(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    const m = cc.server.network orelse return;
    const eth = chosenEthernet(&cc.network, m) orelse return;
    const value = switch (id) {
        0 => eth.address.slice(),
        1 => eth.gateway.slice(),
        2 => eth.dns.slice(),
        3 => eth.mac.slice(),
        else => return,
    };
    if (value.len == 0) return;
    @import("../../clipboard.zig").copyText(cc.server, value);
    cc.network.copied = id;
    cc.refresh();
}
fn scanClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.server.network) |m| m.opened();
}
fn requestFocus(s: *Section, name: []const u8) void {
    s.focus_name.set(name);
    s.focus_requested = true;
}
fn networkClicked(raw: ?*anyopaque, index: usize) void {
    const cc = owner(raw);
    const s = &cc.network;
    if (index >= s.row_count) return;
    const net = s.rows[index];
    const was_selected = if (s.selected) |selected| network.sameNetwork(selected, net) else false;
    s.clearForm();
    if (!was_selected) {
        s.selected = net;
        requestFocus(s, if ((net.security == .personal or net.security == .sae) and !net.connected) "wifi_password" else "wifi_join");
    }
    cc.refresh();
}
fn hiddenClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const hidden = !cc.network.hidden;
    cc.network.clearForm();
    cc.network.hidden = hidden;
    if (hidden) requestFocus(&cc.network, "wifi_ssid");
    cc.refresh();
}
fn cancelClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.network.clearForm();
    cc.refresh();
}
fn nameChanged(_: ?*anyopaque, _: usize, _: []const u8) void {}
fn securityChanged(raw: ?*anyopaque, _: usize, index: usize) void {
    const cc = owner(raw);
    cc.network.security = switch (index) {
        0 => .personal,
        1 => .sae,
        else => .open,
    };
    cc.network.password.clear();
    cc.network.revealed = false;
    cc.refresh();
}
fn autojoinChanged(raw: ?*anyopaque, _: usize, value: bool) void {
    owner(raw).network.autojoin = value;
}
fn revealClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    cc.network.revealed = !cc.network.revealed;
    requestFocus(&cc.network, "wifi_password");
    cc.refresh();
}
fn joinClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const s = &cc.network;
    const m = cc.server.network orelse return;
    if (m.busy) return;
    var net = s.selected orelse network.Network{ .security = s.security };
    if (s.hidden) {
        const value = if (s.name_field) |field| field.kind.text_input.value else "";
        if (value.len > 32) {
            s.message = "Network names must be at most 32 bytes.";
            cc.refresh();
            return;
        }
        net.ssid.set(value);
    }
    if (net.connected) return;
    if (network.joinError(net, s.password.value())) |message| {
        s.message = message;
        cc.refresh();
        return;
    }
    s.message = "";
    m.join(net, s.password.value(), s.autojoin, s.hidden);
    s.password.clear();
    s.revealed = false;
    cc.refresh();
}
fn findNamed(root: *W, name: []const u8) ?*W {
    if (root.name) |n| if (std.mem.eql(u8, n, name)) return root;
    for (root.children) |*child| if (findNamed(child, name)) |found| return found;
    return null;
}
pub fn restoreFocus(s: *Section, cc: *panel.ControlCenter) void {
    if (s.focus_name.len == 0) return;
    const widget = findNamed(&cc.root, s.focus_name.slice()) orelse return;
    ui.input.current.focus(&cc.root, widget);
    if (s.focus_requested) {
        if (s.list) |list| {
            var parent = widget.parent;
            while (parent) |p| : (parent = p.parent) {
                if (p == list) {
                    ui.widgets.scroll_container.ensureVisibleChild(list, widget);
                    break;
                }
            }
        }
    }
    s.focus_requested = false;
}
pub fn key(cc: *panel.ControlCenter, k: ui.input.Key) bool {
    if (k == .escape and (cc.network.hidden or cc.network.selected != null)) {
        cancelClicked(cc, 0);
        return true;
    }
    if (k == .enter) if (ui.input.current.focused) |widget| {
        if (widget.kind == .secret_input or widget.kind == .text_input) {
            joinClicked(cc, 0);
            return true;
        }
    };
    return false;
}
