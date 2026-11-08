//! Live NetworkManager settings. Widget storage belongs to the window;
//! passwords stay in locked, wiped storage, never in the tree's arena.
const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const network = @import("../../network/manager.zig");
const secure = @import("../../network/secure_allocator.zig").allocator;
const gpa = @import("../../main.zig").gpa;
const ui = @import("ui");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const widgets = @import("network_ui.zig");
const text = widgets.text;
const icon = widgets.icon;
const group = widgets.group;
const card = widgets.card;
const divider = widgets.divider;
const status = widgets.status;
const summary = widgets.summary;
const action = widgets.action;
const details = @import("network_details.zig");
const editor = @import("network_editor.zig");
const proxy_card = @import("network_proxy.zig");
const vpn_card = @import("network_vpn.zig");
const rfkill = @import("platform").rfkill;

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
    edit: editor.State = .{},
    proxy: proxy_card.State = .{},
    /// A Wi-Fi network's Forget waits for a second click.
    forget_armed: bool = false,
    /// The VPN row whose Remove waits for a second click.
    vpn_forget: ?usize = null,
    /// What the last airplane-mode change did, when it failed.
    airplane_note: []const u8 = "",

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
        s.forget_armed = false;
    }
    pub fn deinit(s: *Section) void {
        s.clearForm();
        s.edit.close();
        s.proxy.deinit();
        if (s.password.storage.len != 0) secure.free(s.password.storage);
        s.arena.deinit();
    }
    pub fn captureFocus(s: *Section) void {
        if (s.focus_requested) return;
        s.focus_name = .{};
        if (ui.input.current.focused) |widget| if (widget.name) |name| s.focus_name.set(name);
    }
};

fn switchWidget(cc: *panel.ControlCenter, name: []const u8, id: usize, on: bool, disabled: bool) W {
    return .{ .name = name, .kind = .{ .toggle = .{ .style = .settings, .on = on, .disabled = disabled, .owner = cc, .id = id, .on_change = switched } } };
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    const saved_scroll = if (s.list) |list| list.kind.scroll_container else ui.layout.ScrollState{};
    if (s.name_field) |field| s.name_data = field.kind.text_input;
    s.name_field = null;
    s.edit.capture();
    s.proxy.capture();
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
    const eth = if (m) |n| details.chosenEthernet(s, n) else null;
    const connected_wifi: ?*const network.Network = if (m) |n| for (n.networks[0..n.count]) |*net| {
        if (net.connected) break net;
    } else null else null;
    const online = available and m.?.connectivity == 4;
    const internet_state: []const u8 = if (!available) i18n.tr("Unavailable") else switch (m.?.connectivity) {
        2 => i18n.tr("Sign-in required"),
        3 => i18n.tr("Limited access"),
        4 => i18n.tr("Connected"),
        else => if (m.?.state >= 50) i18n.tr("Connected") else i18n.tr("Offline"),
    };
    const internet_detail: []const u8 = if (!available) i18n.tr("NetworkManager unavailable") else switch (m.?.connectivity) {
        2 => i18n.tr("Open a browser to sign in"),
        3 => i18n.tr("No internet access"),
        4 => i18n.tr("You're online."),
        else => if (m.?.state >= 50) i18n.tr("Internet access not verified") else i18n.tr("No internet connection"),
    };
    const wifi_state: []const u8 = if (!available) i18n.tr("Unavailable") else if (!m.?.hardware) i18n.tr("Hardware blocked") else if (!m.?.enabled) i18n.tr("Turned off") else if (m.?.device.len == 0) i18n.tr("No adapter") else if (connected_wifi != null) i18n.tr("Connected") else i18n.tr("Not connected");
    const eth_detail = if (eth) |e| if (e.connected() and e.link.v4.address.len != 0) try std.fmt.allocPrint(a, "{s} · {s}", .{ try details.speed(a, e.*), details.bareAddress(e.link.v4.address.slice()) }) else try a.dupe(u8, e.name.slice()) else i18n.tr("No wired adapter");
    const wifi_detail = if (connected_wifi) |net| try std.fmt.allocPrint(a, "{s} · {s}", .{ network.networkName(net), if (net.strength >= 80) @as([]const u8, i18n.tr("Excellent")) else if (net.strength >= 55) i18n.tr("Good") else i18n.tr("Weak") }) else i18n.tr("Wireless connections");
    const overview_width = @as(f32, @floatFromInt(cc.panel_box.width)) - panel.sidebarWidth(cc) - 100;
    var description_width: f32 = 0;
    for ([_][]const u8{ internet_detail, eth_detail, wifi_detail }) |value| description_width = @max(description_width, ui.measure.textNatural(value, .sans, 400, 12).w);
    const stacked = overview_width < 3 * (@min(description_width, 260) + 74);
    var overview = try card(a, &.{
        try summary(a, .globe, i18n.tr("Internet"), internet_state, internet_detail, online),
        divider(!stacked),
        try summary(a, .ethernet, i18n.tr("Ethernet"), if (eth) |e| e.status() else i18n.tr("Unavailable"), eth_detail, if (eth) |e| e.connected() else false),
        divider(!stacked),
        try summary(a, .wifi, i18n.tr("Wi-Fi"), wifi_state, wifi_detail, connected_wifi != null),
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
    var page: std.ArrayList(W) = .empty;
    try page.append(a, overview);
    if (try airplaneRow(cc, a)) |row| try page.append(a, row);
    if (m) |n| if (try accessRow(cc, a, n)) |row| try page.append(a, row);
    try page.append(a, columns);
    if (try editor.build(cc, a)) |edit_card| try page.append(a, edit_card);
    try page.append(a, try vpn_card.build(cc, a));
    try page.append(a, try proxy_card.build(cc, a));
    return group(a, .column, page.items);
}

/// Airplane mode: every radio blocked by software (`/dev/rfkill`), which
/// NetworkManager and BlueZ both follow. Hidden where there is no rfkill.
fn airplaneRow(cc: *panel.ControlCenter, a: Allocator) !?W {
    const state = rfkill.read();
    if (state.count == 0) return null;
    var labels = try group(a, .column, &.{ text(i18n.tr("Airplane mode"), 14, false), text(if (cc.network.airplane_note.len != 0) cc.network.airplane_note else if (state.hardBlocked()) i18n.tr("A hardware switch is blocking a radio.") else i18n.tr("Turns off Wi-Fi, Bluetooth and other radios."), 12, true) });
    labels.width = .{ .flex = 1 };
    labels.gap = 4;
    var toggle = switchWidget(cc, "network_airplane", 2, state.allBlocked(), state.hardBlocked());
    toggle.kind.toggle.disabled = state.hardBlocked();
    var row = try card(a, &.{try group(a, .row, &.{ icon(.power, 26, state.allBlocked()), labels, toggle })});
    row.name = "network_airplane_row";
    return row;
}

/// The Unlock prompt, or a line saying what the last change did.
fn accessRow(cc: *panel.ControlCenter, a: Allocator, m: *const network.Manager) !?W {
    const locked = m.access == .locked or m.unlocking;
    const message: []const u8 = if (m.unlocking) i18n.tr("Waiting for authentication…") else if (m.access == .locked) i18n.tr("Unlock to change connection settings.") else if (m.access == .denied) i18n.tr("Your account is not allowed to change network connections.") else if (cc.network.edit.open) "" else m.edit_message;
    if (message.len == 0) return null;
    var label = text(message, 13, true);
    label.width = .{ .flex = 1 };
    if (!locked) return try group(a, .row, &.{label});
    var unlock = action(cc, "network_unlock", i18n.tr("Unlock"), 0, unlockClicked, m.unlocking);
    unlock.kind.button.leading_icon = .lock;
    unlock.width = .auto;
    var row = try group(a, .row, &.{ label, unlock });
    row.name = "network_access";
    return row;
}
fn ethernetCard(s: *Section, cc: *panel.ControlCenter, a: Allocator, eth: ?*const network.Ethernet) !W {
    const m = cc.server.network;
    const subtitle = if (eth) |e| if (e.driver.len != 0) try std.fmt.allocPrint(a, "{s} ({s})", .{ e.name.slice(), e.driver.slice() }) else try a.dupe(u8, e.name.slice()) else i18n.tr("No wired adapter found");
    var labels = try group(a, .column, &.{ text(i18n.tr("Ethernet"), 20, false), text(subtitle, 12, true) });
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
    var rows = try card(a, try details.ethernetRows(cc, a, eth));
    rows.gap = 6;
    try items.append(a, rows);
    if (eth) |e| {
        var edit = action(cc, "ethernet_edit", i18n.tr("Edit settings…"), 1, editClicked, ethernetProfile(m, e).len == 0 or cc.network.edit.open);
        edit.kind.button.variant = .secondary;
        edit.width = .auto;
        try items.append(a, edit);
    }
    if (m) |n| {
        if (n.wired_message.len > 0) try items.append(a, text(n.wired_message, 12, true));
    }
    var result = try card(a, items.items);
    result.name = "ethernet_card";
    return result;
}
fn ethernetProfile(m: ?*network.Manager, e: *const network.Ethernet) []const u8 {
    const manager = m orelse return "";
    if (details.profileOf(manager, e.active_connection.slice())) |saved| return saved.path.slice();
    return e.profile.slice();
}

fn wifiCard(s: *Section, cc: *panel.ControlCenter, a: Allocator) !W {
    const m = cc.server.network;
    const available = if (m) |n| n.available and n.hardware and n.enabled and n.device.len != 0 else false;
    const busy = if (m) |n| n.busy else false;
    var title = text(i18n.tr("Wi-Fi"), 20, false);
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
        const message: []const u8 = if (m) |n| if (!n.available) i18n.tr("NetworkManager is unavailable") else if (!n.hardware) i18n.tr("Wi-Fi is disabled by the hardware switch") else if (!n.enabled) i18n.tr("Wi-Fi is turned off") else if (n.device.len == 0) i18n.tr("No Wi-Fi adapter found") else if (n.searching()) i18n.tr("Searching for networks…") else i18n.tr("No networks found. Scan to try again.") else i18n.tr("NetworkManager is unavailable");
        var empty = try group(a, .column, &.{ icon(.wifi, 32, false), text(message, 13, true) });
        empty.padding = ui.layout.Edges.all(16);
        empty.gap = 16;
        try rows.append(a, empty);
    }
    if (available) {
        try rows.append(a, divider(false));
        var hidden = action(cc, "wifi_hidden", i18n.tr("Join Hidden Network"), 0, hiddenClicked, busy);
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
        if (net.connected) {
            var shown: std.ArrayList(W) = .empty;
            try shown.append(a, try wifiActions(s, cc, a, net));
            try shown.appendSlice(a, try details.wifiRows(cc, a, net));
            var result = try group(a, .column, shown.items);
            result.gap = 2;
            return result;
        }
        if (net.security == .unsupported and net.saved.len == 0) return group(a, .column, &.{text(i18n.tr("Configure this network with a network tool"), 12, true)});
    }
    var items: std.ArrayList(W) = .empty;
    if (s.hidden) {
        if (s.name_data == null) s.name_data = .{ .placeholder = i18n.tr("Network name (SSID)"), .value = try gpa.dupe(u8, ""), .owner = cc, .on_change = nameChanged };
        const field = try a.create(W);
        field.* = .{ .name = "wifi_ssid", .kind = .{ .text_input = s.name_data.? }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } };
        try items.append(a, text(i18n.tr("Network name"), 12, true));
        try items.append(a, field.*);
        try items.append(a, text(i18n.tr("Security"), 12, true));
        try items.append(a, .{ .name = "wifi_security", .kind = .{ .select = .{ .labels = panel.translatedLabels(&.{ i18n.msg("WPA2 / WPA3 Personal"), i18n.msg("WPA3 Personal"), i18n.msg("Open") }), .selected = if (s.security == .personal) 0 else if (s.security == .sae) 1 else 2, .owner = cc, .on_change = securityChanged } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } });
    }
    const net = s.selected orelse network.Network{ .security = s.security };
    if (!s.hidden and net.saved.len != 0) try items.append(a, try wifiActions(s, cc, a, net));
    if (net.security == .personal or net.security == .sae) {
        if (s.password.storage.len == 0) {
            s.password.storage = try secure.alloc(u8, 128);
            @memset(s.password.storage, 0);
        }
        try items.append(a, text(if (net.saved.len != 0) i18n.tr("Password (leave empty to use saved)") else i18n.tr("Password"), 12, true));
        var reveal = action(cc, "wifi_reveal", "", 0, revealClicked, false);
        reveal.kind.button.icon = if (s.revealed) .eye else .eye_off;
        reveal.kind.button.variant = .ghost;
        reveal.width = .{ .fixed = 34 };
        try items.append(a, try group(a, .row, &.{
            .{ .name = "wifi_password", .kind = .{ .secret_input = .{ .placeholder = i18n.tr("Password"), .input = &s.password, .revealed = s.revealed } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 36 } }, reveal,
        }));
    }
    if (net.saved.len == 0) try items.append(a, .{ .name = "wifi_autojoin", .kind = .{ .checkbox = .{ .label = i18n.tr("Connect automatically"), .checked = s.autojoin, .owner = cc, .on_change = autojoinChanged } }, .width = .{ .percent = 1 } });
    var join = action(cc, "wifi_join", i18n.tr("Connect"), 0, joinClicked, cc.server.network.?.busy);
    join.kind.button.variant = .primary;
    var buttons = try group(a, .row, &.{ action(cc, "wifi_cancel", i18n.tr("Cancel"), 0, cancelClicked, false), join });
    buttons.justify = .end;
    try items.append(a, buttons);
    var result = try group(a, .column, items.items);
    result.padding = ui.layout.Edges.all(10);
    if (s.hidden) s.name_field = &result.children[1];
    return result;
}
/// Edit, Forget and (for the connected network) Disconnect and auto-connect.
fn wifiActions(s: *Section, cc: *panel.ControlCenter, a: Allocator, net: network.Network) !W {
    const m = cc.server.network.?;
    const profile = if (net.connected) m.wifi.profile.slice() else net.saved.slice();
    const saved = network.savedAt(m, profile);
    const locked = m.access == .locked or m.access == .denied or m.unlocking or m.edit_busy;
    var items: std.ArrayList(W) = .empty;
    if (saved) |sv| {
        var toggle: W = .{ .name = "wifi_autoconnect", .kind = .{ .checkbox = .{ .label = i18n.tr("Connect automatically"), .checked = sv.autoconnect, .disabled = locked, .owner = cc, .on_change = autoconnectToggled } }, .width = .{ .percent = 1 } };
        toggle.padding = ui.layout.Edges.xy(0, 6);
        try items.append(a, toggle);
    }
    var buttons: std.ArrayList(W) = .empty;
    if (net.connected) {
        var disconnect = action(cc, "wifi_disconnect", i18n.tr("Disconnect"), 0, disconnectClicked, m.busy);
        disconnect.kind.button.variant = .secondary;
        try buttons.append(a, disconnect);
    }
    if (profile.len != 0) {
        var edit = action(cc, "wifi_edit", i18n.tr("Edit settings…"), 0, editClicked, s.edit.open);
        edit.kind.button.variant = .secondary;
        try buttons.append(a, edit);
        var forget = action(cc, "wifi_forget", if (s.forget_armed) i18n.tr("Confirm forget") else i18n.tr("Forget"), 0, wifiForgetClicked, locked);
        forget.kind.button.variant = .ghost;
        try buttons.append(a, forget);
    }
    if (buttons.items.len != 0) {
        var row = try group(a, .row, buttons.items);
        row.padding = ui.layout.Edges.xy(0, 6);
        try items.append(a, row);
    }
    return group(a, .column, items.items);
}
fn unlockClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.server.network) |m| m.unlock();
    cc.refresh();
}
fn disconnectClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    if (cc.server.network) |m| m.disconnectWifi();
}
/// Edit for the Wi-Fi network in the list (id 0) or the Ethernet adapter (id 1).
fn editClicked(raw: ?*anyopaque, id: usize) void {
    const cc = owner(raw);
    const m = cc.server.network orelse return;
    if (id == 1) {
        const eth = details.chosenEthernet(&cc.network, m) orelse return;
        return editor.open(cc, ethernetProfile(m, eth));
    }
    const net = cc.network.selected orelse return;
    editor.open(cc, if (net.connected) m.wifi.profile.slice() else net.saved.slice());
}
fn wifiForgetClicked(raw: ?*anyopaque, _: usize) void {
    const cc = owner(raw);
    const s = &cc.network;
    const m = cc.server.network orelse return;
    const net = s.selected orelse return;
    if (!s.forget_armed) {
        s.forget_armed = true;
        return cc.refresh();
    }
    const profile = if (net.connected) m.wifi.profile.slice() else net.saved.slice();
    m.forget(profile);
    s.clearForm();
    cc.refresh();
}
fn autoconnectToggled(raw: ?*anyopaque, _: usize, on: bool) void {
    const cc = owner(raw);
    const m = cc.server.network orelse return;
    const net = cc.network.selected orelse return;
    m.setAutoconnect(if (net.connected) m.wifi.profile.slice() else net.saved.slice(), on);
}
fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}
/// Turning airplane mode on remembers which radios were already blocked, so
/// turning it off puts them back as they were rather than waking them all.
fn airplaneChanged(cc: *panel.ControlCenter, on: bool) void {
    cc.network.airplane_note = "";
    const failed = i18n.tr("Could not change the radios. Check access to /dev/rfkill.");
    if (on) {
        cc.server.rfkill_before = rfkill.read();
        rfkill.blockAll(true) catch {
            cc.server.rfkill_before = null;
            cc.network.airplane_note = failed;
        };
    } else {
        const before = cc.server.rfkill_before;
        cc.server.rfkill_before = null;
        if (before) |snapshot| {
            if (snapshot.allBlocked()) rfkill.blockAll(false) catch {
                cc.network.airplane_note = failed;
            } else rfkill.restore(&snapshot) catch {
                cc.network.airplane_note = failed;
            };
        } else rfkill.blockAll(false) catch {
            cc.network.airplane_note = failed;
        };
    }
}
fn switched(raw: ?*anyopaque, id: usize, on: bool) void {
    const cc = owner(raw);
    if (id == 2) {
        airplaneChanged(cc, on);
        return cc.refresh();
    }
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
            s.message = i18n.tr("Network names must be at most 32 bytes.");
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
