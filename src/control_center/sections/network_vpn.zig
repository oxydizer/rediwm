//! The VPN card: NetworkManager's VPN and WireGuard connections, with connect,
//! disconnect and remove. Importing a configuration is left to the VPN's own
//! NetworkManager plugin or `nmcli`. A connection that needs a password at
//! connect time has no secret agent here to ask for it: it must keep its
//! credentials in the profile.

const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const network = @import("../../network/manager.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const widgets = @import("network_ui.zig");
const text = widgets.text;
const icon = widgets.icon;
const group = widgets.group;
const card = widgets.card;
const action = widgets.action;

const max_rows = 32;
const Entry = struct { profile: network.Path = .{}, name: network.Text(64) = .{}, active: network.Path = .{}, state: u32 = 0 };

pub fn isVpn(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "vpn") or std.mem.eql(u8, kind, "wireguard");
}

fn collect(m: *const network.Manager, out: *[max_rows]Entry) usize {
    var count: usize = 0;
    for (m.saved[0..m.saved_count]) |saved| {
        if (!saved.loaded or !isVpn(saved.kind.slice()) or count == max_rows) continue;
        out[count] = .{ .profile = saved.path, .name = saved.id };
        for (m.actives[0..m.active_count]) |act| if (std.mem.eql(u8, act.profile.slice(), saved.path.slice())) {
            out[count].active = act.path;
            out[count].state = act.state;
        };
        count += 1;
    }
    return count;
}

fn stateLabel(state: u32, active: bool) []const u8 {
    if (!active) return i18n.tr("Not connected");
    return switch (state) {
        1 => i18n.tr("Connecting…"),
        2 => i18n.tr("Connected"),
        3 => i18n.tr("Disconnecting…"),
        else => i18n.tr("Not connected"),
    };
}

pub fn build(cc: *panel.ControlCenter, a: Allocator) !W {
    const m = cc.server.network;
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(i18n.tr("VPN"), 20, false));
    var entries: [max_rows]Entry = undefined;
    const count = if (m) |n| collect(n, &entries) else 0;
    const locked = if (m) |n| n.access == .locked or n.access == .denied or n.unlocking or n.edit_busy else true;
    for (entries[0..count], 0..) |entry, i| {
        const connected = entry.active.len != 0 and entry.state == 2;
        var labels = try group(a, .column, &.{ text(try a.dupe(u8, entry.name.slice()), 15, false), text(stateLabel(entry.state, entry.active.len != 0), 12, true) });
        labels.width = .{ .flex = 1 };
        labels.gap = 5;
        const busy = entry.active.len != 0 and entry.state != 2;
        var toggle = action(cc, try std.fmt.allocPrint(a, "vpn_toggle_{d}", .{i}), if (entry.active.len != 0) i18n.tr("Disconnect") else i18n.tr("Connect"), i, toggleClicked, busy);
        toggle.kind.button.variant = if (entry.active.len != 0) .secondary else .primary;
        toggle.width = .auto;
        var remove = action(cc, try std.fmt.allocPrint(a, "vpn_remove_{d}", .{i}), if (cc.network.vpn_forget == i) i18n.tr("Confirm remove") else i18n.tr("Remove"), i, removeClicked, locked or entry.active.len != 0);
        remove.kind.button.variant = .ghost;
        remove.width = .auto;
        var row = try group(a, .row, &.{ icon(.lock, 24, connected), labels, toggle, remove });
        row.name = try std.fmt.allocPrint(a, "vpn_row_{d}", .{i});
        row.padding = ui.layout.Edges.xy(10, 8);
        try items.append(a, row);
    }
    if (count == 0) try items.append(a, text(i18n.tr("No VPN connections. Add one with your VPN's NetworkManager plugin or nmcli; it then appears here."), 12, true));
    var result = try card(a, items.items);
    result.name = "vpn_card";
    return result;
}

fn owner(raw: ?*anyopaque) *panel.ControlCenter {
    return @ptrCast(@alignCast(raw.?));
}

fn entryAt(cc: *panel.ControlCenter, index: usize, out: *[max_rows]Entry) ?Entry {
    const m = cc.server.network orelse return null;
    const count = collect(m, out);
    return if (index < count) out[index] else null;
}

fn toggleClicked(raw: ?*anyopaque, index: usize) void {
    const cc = owner(raw);
    var entries: [max_rows]Entry = undefined;
    const entry = entryAt(cc, index, &entries) orelse return;
    const m = cc.server.network.?;
    if (entry.active.len != 0) m.deactivate(entry.active.slice()) else m.activate(entry.profile.slice());
    cc.refresh();
}

fn removeClicked(raw: ?*anyopaque, index: usize) void {
    const cc = owner(raw);
    var entries: [max_rows]Entry = undefined;
    const entry = entryAt(cc, index, &entries) orelse return;
    if (cc.network.vpn_forget != index) {
        cc.network.vpn_forget = index;
        return cc.refresh();
    }
    cc.network.vpn_forget = null;
    cc.server.network.?.forget(entry.profile.slice());
    cc.refresh();
}
