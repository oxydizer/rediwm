//! Bluetooth device list and details, using the shared settings widgets.
const std = @import("std");
const ui = @import("ui");
const panel = @import("../panel.zig");
const bt = @import("../../bluetooth.zig");
const gpa = @import("../../main.zig").gpa;
const W = ui.layout.Widget;
const A = std.mem.Allocator;
const eq = std.mem.eql;

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    adapter_path: bt.Path = .{},
    selected: bt.Path = .{},
    rows: [256]bt.Path = @splat(.{}),
    adapter_paths: [16]bt.Path = @splat(.{}),
    search: ?*W = null,
    search_data: ?ui.layout.TextInputData = null,
    pin: ?*W = null,
    pin_data: ?ui.layout.TextInputData = null,
    list: ?*W = null,
    focus_name: bt.Path = .{},
    nearby: bool = false,
    forgetting: bool = false,
    pub fn capture(s: *Section) void {
        s.focus_name = .{};
        if (ui.input.current.focused) |w| if (w.name) |name| s.focus_name.set(name);
    }
    fn saveFields(s: *Section) void {
        if (s.search) |w| s.search_data = w.kind.text_input;
        if (s.pin) |w| s.pin_data = w.kind.text_input;
        s.search = null;
        s.pin = null;
    }
    pub fn clearPin(s: *Section) void {
        if (s.pin) |w| s.pin_data = w.kind.text_input;
        if (s.pin_data) |d| {
            @memset(d.value, 0);
            gpa.free(d.value);
        }
        if (s.pin) |w| w.kind.text_input.value = @constCast(&[_]u8{});
        s.pin_data = null;
        s.pin = null;
    }
    pub fn deinit(s: *Section) void {
        s.saveFields();
        s.clearPin();
        if (s.search_data) |d| gpa.free(d.value);
        s.arena.deinit();
    }
};
fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}
fn icon(id: ui.layout.IconId, size: f32) W {
    return .{ .kind = .{ .icon = .{ .id = id, .color = panel.palette().fg } }, .width = .{ .fixed = size }, .height = .{ .fixed = size } };
}
fn group(a: A, dir: ui.layout.Direction, items: []const W) !W {
    return .{ .kind = .container, .direction = dir, .gap = 10, .@"align" = if (dir == .row) .center else .stretch, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}
fn card(a: A, items: []const W) !W {
    var w = try group(a, .column, items);
    const t = panel.palette();
    w.kind = .{ .rect = .{ .color = t.app_item, .radius = 9, .border_width = 1, .border_color = t.app_item_border } };
    w.padding = ui.layout.Edges.all(14);
    w.gap = 14;
    return w;
}
fn button(cc: *panel.ControlCenter, name: []const u8, label: []const u8, id: usize, disabled: bool) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = clicked, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 } };
}
fn toggle(cc: *panel.ControlCenter, name: []const u8, id: usize, on: bool, disabled: bool) W {
    return .{ .name = name, .kind = .{ .toggle = .{ .style = .settings, .on = on, .disabled = disabled, .owner = cc, .id = id, .on_change = switched } } };
}
fn glyph(d: *const bt.Device) ui.layout.IconId {
    const value = d.icon.slice();
    if (std.mem.indexOf(u8, value, "keyboard") != null) return .keyboard;
    if (std.mem.indexOf(u8, value, "mouse") != null) return .mouse;
    if (std.mem.indexOf(u8, value, "audio") != null or d.audio) return .headphones;
    if (eq(u8, value, "computer")) return .display;
    return .bluetooth;
}
fn status(a: A, value: []const u8, connected: bool) !W {
    return group(a, .row, &.{
        .{ .kind = .{ .rect = .{ .color = if (connected) .{ 0.2, 0.86, 0.45, 1 } else panel.palette().dim, .radius = 4 } }, .width = .{ .fixed = 7 }, .height = .{ .fixed = 7 } }, text(value, 13, true),
    });
}
fn currentAdapter(s: *Section, m: *bt.Manager) ?*const bt.Adapter {
    if (m.adapter(s.adapter_path)) |ad| return ad;
    if (m.adapter_count == 0) return null;
    s.adapter_path = m.adapters[0].path;
    return &m.adapters[0];
}
pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    const saved = if (s.list) |list| list.kind.scroll_container else ui.layout.ScrollState{};
    s.saveFields();
    s.list = null;
    if (cc.server.bluetooth) |m| {
        if (m.prompt != .pin and m.prompt != .passkey) s.clearPin();
        if (m.find(s.selected) == null) {
            s.selected = .{};
            s.forgetting = false;
        }
    }
    _ = s.arena.reset(.retain_capacity);
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
    if (s.list) |list| list.kind.scroll_container = saved;
}
fn tree(s: *Section, cc: *panel.ControlCenter, a: A) !W {
    const m = cc.server.bluetooth;
    const ad = if (m) |manager| currentAdapter(s, manager) else null;
    const enabled = if (ad) |adapter| adapter.powered else false;
    const busy = if (m) |manager| manager.busy else false;
    const scanning = if (m) |manager| manager.scan_path.len > 0 else false;
    var radio_label = try group(a, .column, &.{ text("Bluetooth", 24, false), text("Connect and manage your Bluetooth devices.", 13, true) });
    radio_label.width = .{ .flex = 1 };
    radio_label.gap = 6;
    var pair = button(cc, "bluetooth_scan", if (scanning) "Stop Searching" else "Pair New Device", 0, !enabled or busy);
    pair.kind.button.variant = .primary;
    pair.kind.button.leading_icon = if (scanning) .close else .plus;
    var controls = try group(a, .row, &.{ radio_label, toggle(cc, "bluetooth_enabled", 0, enabled, ad == null or busy), pair });
    if (cc.panel_box.width < 900) {
        controls.direction = .column;
        controls.@"align" = .stretch;
    }
    var children: std.ArrayList(W) = .empty;
    try children.append(a, controls);
    if (m) |manager| if (manager.adapter_count > 1) {
        const labels = try a.alloc([]const u8, manager.adapter_count);
        var selected: usize = 0;
        for (manager.adapters[0..manager.adapter_count], 0..) |adapter, i| {
            s.adapter_paths[i] = adapter.path;
            labels[i] = try a.dupe(u8, if (adapter.name.len > 0) adapter.name.slice() else adapter.path.slice());
            if (eq(u8, adapter.path.slice(), s.adapter_path.slice())) selected = i;
        }
        try children.append(a, .{ .name = "bluetooth_adapter", .kind = .{ .select = .{ .labels = labels, .selected = selected, .owner = cc, .on_change = adapterChanged } }, .height = .{ .fixed = 34 }, .width = .{ .percent = 1 } });
    };
    const stacked = cc.panel_box.width < 1000;
    var devices = try deviceList(s, cc, a, enabled);
    devices.width = if (stacked) .{ .percent = 1 } else .{ .flex = 1 };
    var details = try deviceDetails(s, cc, a);
    details.width = if (stacked) .{ .percent = 1 } else .{ .flex = 1.25 };
    var columns = try group(a, if (stacked) .column else .row, &.{ devices, details });
    columns.@"align" = .start;
    columns.gap = 16;
    try children.append(a, columns);
    if (m) |manager| if (manager.message.len > 0) try children.append(a, text(manager.message, 13, true));
    return group(a, .column, children.items);
}
fn deviceList(s: *Section, cc: *panel.ControlCenter, a: A, enabled: bool) !W {
    const m = cc.server.bluetooth;
    if (s.search_data == null) s.search_data = .{ .placeholder = "Search devices…", .value = try gpa.dupe(u8, ""), .field = .{ .leading_icon = .search }, .owner = cc, .on_change = searchChanged };
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(if (s.nearby) "Available Devices" else "Paired Devices", 18, false));
    try items.append(a, .{ .name = "bluetooth_search", .kind = .{ .text_input = s.search_data.? }, .height = .{ .fixed = 36 }, .width = .{ .percent = 1 } });
    if (s.nearby) try items.append(a, button(cc, "bluetooth_paired", "Show Paired Devices", 1, false));
    var rows: std.ArrayList(W) = .empty;
    var count: usize = 0;
    if (m) |manager| for (manager.devices[0..manager.count]) |*d| {
        if (!eq(u8, d.adapter.slice(), s.adapter_path.slice()) or (!s.nearby and !d.paired)) continue;
        if (s.search_data.?.value.len > 0 and std.ascii.indexOfIgnoreCase(d.title(), s.search_data.?.value) == null and std.ascii.indexOfIgnoreCase(d.address.slice(), s.search_data.?.value) == null) continue;
        const selected = eq(u8, d.path.slice(), s.selected.slice());
        s.rows[count] = d.path;
        const state = if (d.connected) "Connected" else if (d.blocked) "Blocked" else if (d.paired) "Not connected" else "Ready to pair";
        const subtitle = if (d.battery) |pct| try std.fmt.allocPrint(a, "{s} · {d}%", .{ state, pct }) else state;
        var labels = try group(a, .column, &.{ text(try a.dupe(u8, d.title()), 14, false), try status(a, subtitle, d.connected) });
        labels.width = .{ .flex = 1 };
        labels.gap = 5;
        try rows.append(a, .{ .name = try std.fmt.allocPrint(a, "bluetooth_device_{d}", .{count}), .kind = .{ .row = .{ .selected = selected, .owner = cc, .id = count, .on_click = selectedDevice } }, .height = .{ .fixed = 66 }, .width = .{ .percent = 1 }, .padding = ui.layout.Edges.xy(10, 0), .@"align" = .center, .gap = 12, .children = try a.dupe(W, &.{ icon(glyph(d), 26), labels, icon(.chevron_right, 12) }) });
        count += 1;
    };
    if (count == 0) {
        const message: []const u8 = if (m == null or !m.?.available) "Bluetooth service is unavailable" else if (m.?.adapter_count == 0) "No Bluetooth adapter found" else if (!enabled) "Bluetooth is turned off" else if (s.search_data.?.value.len > 0) "No matching devices" else if (s.nearby) "Put your device in pairing mode. Nearby devices appear here." else "No paired devices. Choose Pair New Device to get started.";
        try rows.append(a, text(message, 13, true));
    }
    var list = try group(a, .column, rows.items);
    list.name = "bluetooth_devices";
    list.kind = .{ .scroll_container = .{} };
    list.height = .{ .fixed = if (cc.panel_box.width < 1000) 220 else @max(240, @as(f32, @floatFromInt(cc.panel_box.height)) - 270) };
    list.padding.right = ui.widgets.scrollbar.gutter(ui.theme.global.scrollbar_width);
    list.gap = 4;
    try items.append(a, list);
    var result = try card(a, items.items);
    result.name = "bluetooth_list";
    s.search = &result.children[1];
    s.list = &result.children[result.children.len - 1];
    return result;
}
fn setting(cc: *panel.ControlCenter, a: A, title: []const u8, description: []const u8, name: []const u8, id: usize, on: bool, disabled: bool) !W {
    var labels = try group(a, .column, &.{ text(title, 14, false), text(description, 12, true) });
    labels.width = .{ .flex = 1 };
    labels.gap = 4;
    return group(a, .row, &.{ labels, toggle(cc, name, id, on, disabled) });
}
fn deviceDetails(s: *Section, cc: *panel.ControlCenter, a: A) !W {
    const m = cc.server.bluetooth;
    const d = if (m) |manager| manager.find(s.selected) else null;
    if (d == null) return card(a, &.{ icon(.bluetooth, 48), text("Select a device", 18, false), text("View its connection, battery and device settings.", 13, true) });
    const dev = d.?;
    const manager = m.?;
    const ad = manager.adapter(dev.adapter);
    const disabled = manager.busy or ad == null or !ad.?.powered;
    var name = try group(a, .column, &.{ text(try a.dupe(u8, dev.title()), 20, false), text(try a.dupe(u8, dev.address.slice()), 12, true), try status(a, if (dev.connected) "Connected" else "Not connected", dev.connected) });
    name.width = .{ .flex = 1 };
    name.gap = 7;
    var badge: W = .{ .kind = .container, .width = .{ .fixed = 0 } };
    if (dev.battery) |percent| badge = .{ .name = "bluetooth_battery", .kind = .{ .battery = .{ .percent = percent } } };
    const header = try group(a, .row, &.{ icon(glyph(dev), 52), name });
    var items: std.ArrayList(W) = .empty;
    try items.append(a, header);
    if (dev.battery != null) try items.append(a, badge);
    if (dev.rssi) |rssi| try items.append(a, try card(a, &.{ text("Connection", 15, false), text(try std.fmt.allocPrint(a, "Last reported signal: {d} dBm", .{rssi}), 13, true) }));
    if (manager.pairing != null and eq(u8, manager.pairing.?.slice(), dev.path.slice())) {
        try items.append(a, try pairing(s, cc, a));
    } else {
        var connect = button(cc, "bluetooth_connect", if (!dev.paired) "Pair Device" else if (dev.connected) "Disconnect" else "Connect", 2, disabled or dev.blocked or (!dev.paired and !manager.agent_ready));
        connect.kind.button.variant = .primary;
        try items.append(a, connect);
    }
    var profiles: std.ArrayList(W) = .empty;
    try profiles.append(a, text("Profiles", 15, false));
    if (dev.audio) try profiles.append(a, try group(a, .row, &.{ icon(.music, 20), text("Audio (A2DP) · High quality audio", 13, true) }));
    if (dev.microphone) try profiles.append(a, try group(a, .row, &.{ icon(.mic_outline, 20), text("Headset · Audio and microphone", 13, true) }));
    if (dev.input) try profiles.append(a, try group(a, .row, &.{ icon(.keyboard, 20), text("Input · Keyboard, mouse or controller", 13, true) }));
    if (profiles.items.len == 1) try profiles.append(a, text(if (dev.paired) "No supported profiles reported" else "Profiles appear after pairing", 12, true));
    if (dev.audio or dev.microphone) try profiles.append(a, button(cc, "bluetooth_audio", "Audio Settings", 3, false));
    try items.append(a, try card(a, profiles.items));
    try items.append(a, try card(a, &.{ text("Device Settings", 15, false), try setting(cc, a, "Trusted Device", "Allow connections from this device without asking.", "bluetooth_trusted", 1, dev.trusted, manager.busy or !dev.paired), try setting(cc, a, "Blocked", "Prevent this device from connecting.", "bluetooth_blocked", 2, dev.blocked, manager.busy) }));
    if (s.forgetting) {
        try items.append(a, text("Forget this device? Pair it again to reconnect.", 13, true));
        try items.append(a, try group(a, .row, &.{ button(cc, "bluetooth_forget_confirm", "Forget Device", 5, manager.busy), button(cc, "bluetooth_forget_cancel", "Cancel", 6, false) }));
    } else try items.append(a, button(cc, "bluetooth_forget", "Forget Device", 4, manager.busy));
    var result = try card(a, items.items);
    result.name = "bluetooth_details";
    return result;
}
fn pairing(s: *Section, cc: *panel.ControlCenter, a: A) !W {
    const m = cc.server.bluetooth.?;
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text("Pairing", 15, false));
    switch (m.prompt) {
        .none => try items.append(a, text("Waiting for the device…", 13, true)),
        .confirm => {
            try items.append(a, text("Does this code match the code on your device?", 13, true));
            try items.append(a, text(try a.dupe(u8, m.code.slice()), 24, false));
        },
        .authorize => try items.append(a, text("Allow pairing with this device?", 13, true)),
        .display => {
            try items.append(a, text("Enter this code on your device, then press Enter.", 13, true));
            try items.append(a, text(try a.dupe(u8, m.code.slice()), 24, false));
        },
        .pin, .passkey => {
            if (s.pin_data == null) {
                s.pin_data = .{ .placeholder = "Pairing code", .value = try gpa.dupe(u8, ""), .owner = cc, .on_change = pinChanged };
                s.focus_name.set("bluetooth_pin");
            }
            try items.append(a, text(if (m.prompt == .pin) "Enter the device's PIN" else "Enter the device's six-digit passkey", 13, true));
            try items.append(a, .{ .name = "bluetooth_pin", .kind = .{ .text_input = s.pin_data.? }, .width = .{ .percent = 1 }, .height = .{ .fixed = 36 } });
        },
    }
    if (m.reply != null) try items.append(a, button(cc, "bluetooth_pair_accept", "Confirm Pairing", 7, false));
    try items.append(a, button(cc, "bluetooth_pair_cancel", "Cancel Pairing", 8, false));
    var result = try card(a, items.items);
    result.name = "bluetooth_pairing";
    for (result.children) |*w| if (w.kind == .text_input) {
        s.pin = w;
    };
    return result;
}
fn clicked(owner: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner.?));
    const s = &cc.bluetooth;
    const m = cc.server.bluetooth orelse return;
    switch (id) {
        0 => {
            s.nearby = true;
            if (m.scan_path.len > 0) m.stopScan() else m.scan(s.adapter_path);
        },
        1 => {
            s.nearby = false;
            m.stopScan();
        },
        2 => {
            const d = m.find(s.selected) orelse return;
            m.deviceAction(d.path, if (!d.paired) "Pair" else if (d.connected) "Disconnect" else "Connect");
        },
        3 => cc.pending_page = .audio,
        4 => s.forgetting = true,
        5 => {
            m.remove(s.selected);
            s.forgetting = false;
        },
        6 => s.forgetting = false,
        7 => {
            const value = if (s.pin) |field| field.kind.text_input.value else "";
            m.respond(true, value);
        },
        8 => {
            m.cancelPair();
            s.clearPin();
        },
        else => {},
    }
    cc.refresh();
}
fn switched(owner: ?*anyopaque, id: usize, on: bool) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner.?));
    const m = cc.server.bluetooth orelse return;
    if (id == 0) {
        if (!on) m.closed();
        m.set(cc.bluetooth.adapter_path, "org.bluez.Adapter1", "Powered", on);
    } else m.set(cc.bluetooth.selected, "org.bluez.Device1", if (id == 1) "Trusted" else "Blocked", on);
    cc.refresh();
}
fn selectedDevice(owner: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner.?));
    const m = cc.server.bluetooth orelse return;
    if (m.pairing != null) m.cancelPair();
    cc.bluetooth.clearPin();
    cc.bluetooth.selected = cc.bluetooth.rows[id];
    cc.bluetooth.forgetting = false;
    cc.refresh();
}
fn adapterChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner.?));
    if (cc.server.bluetooth) |m| m.closed();
    cc.bluetooth.adapter_path = cc.bluetooth.adapter_paths[index];
    cc.bluetooth.selected = .{};
    cc.bluetooth.forgetting = false;
    cc.refresh();
}
fn searchChanged(owner: ?*anyopaque, _: usize, _: []const u8) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner.?));
    cc.refresh();
}
fn pinChanged(_: ?*anyopaque, _: usize, _: []const u8) void {}
fn findNamed(root: *W, name: []const u8) ?*W {
    if (root.name) |n| if (eq(u8, n, name)) return root;
    for (root.children) |*child| if (findNamed(child, name)) |w| return w;
    return null;
}
pub fn restoreFocus(s: *Section, cc: *panel.ControlCenter) void {
    if (s.focus_name.len > 0) if (findNamed(&cc.root, s.focus_name.slice())) |w| {
        ui.input.current.focus(&cc.root, w);
        return;
    };
    if (s.pin) |w| ui.input.current.focus(&cc.root, w);
}
pub fn key(cc: *panel.ControlCenter, k: ui.input.Key) bool {
    if (k == .escape) {
        if (cc.server.bluetooth) |m| if (m.pairing != null) {
            clicked(cc, 8);
            return true;
        };
        if (cc.bluetooth.forgetting) {
            clicked(cc, 6);
            return true;
        }
    }
    if (k == .enter) if (ui.input.current.focused == cc.bluetooth.pin and cc.bluetooth.pin != null) {
        clicked(cc, 7);
        return true;
    };
    return false;
}
