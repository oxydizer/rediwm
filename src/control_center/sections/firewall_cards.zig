//! The Firewall sub-view's other cards: listening programs, networks and their
//! trust, advanced settings, other programs' rules and recent blocks, plus the
//! row buttons' actions.
const std = @import("std");
const i18n = @import("i18n");
const ui = @import("ui");
const fw = @import("firewall");
const panel = @import("../panel.zig");
const firewall = @import("firewall.zig");
const widgets = @import("network_ui.zig");
const fields = @import("network_fields.zig");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;
const model = fw.model;
const text = widgets.text;
const group = widgets.group;
const card = widgets.card;
const action = widgets.action;

fn heading(a: Allocator, title: []const u8, note: []const u8) !W {
    var column = try group(a, .column, &.{ text(title, 16, false), text(note, 12, true) });
    column.gap = 4;
    return column;
}

fn verdictLabel(v: model.Verdict) []const u8 {
    return switch (v) {
        .local => i18n.tr("This computer only"),
        .blocked => i18n.tr("Blocked"),
        .home => i18n.tr("Home or local networks"),
        .everywhere => i18n.tr("Any network"),
    };
}

pub fn listeners(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, try heading(a, i18n.tr("Listening programs"), i18n.tr("Programs waiting for connections, and who can reach them through the firewall.")));
    if (status.listeners.len == 0) try items.append(a, text(i18n.tr("No program is listening."), 13, true));
    const edit = status.capabilities.edit;
    for (status.listeners, 0..) |l, i| {
        if (i >= 64) break;
        const name = if (l.process.len != 0) try a.dupe(u8, l.process) else i18n.tr("Unknown program");
        const where = try std.fmt.allocPrint(a, "{s} {d} · {s}", .{ if (l.proto == .tcp) "TCP" else "UDP", l.port, l.address });
        var labels = try group(a, .column, &.{ text(name, 14, false), text(where, 12, true) });
        labels.gap = 3;
        labels.width = .{ .flex = 1 };
        var verdict = text(verdictLabel(l.verdict), 12, l.verdict != .everywhere);
        if (l.verdict == .everywhere) verdict.kind.text.color = panel.palette().danger;
        // Measured text can come out a little narrower than drawn at
        // fractional scales; a fixed column keeps the label whole.
        verdict.width = .{ .fixed = @max(150, ui.measure.textNatural(verdictLabel(l.verdict), .sans, 400, 12).w + 12) };
        var row: std.ArrayList(W) = .empty;
        try row.appendSlice(a, &.{ labels, verdict });
        if (edit and (l.verdict == .everywhere or l.verdict == .home)) {
            var block = action(cc, "firewall_listener_block", i18n.tr("Block"), firewall.block_base + i, firewall.clicked, !firewall.editable(cc));
            block.kind.button.variant = .ghost;
            block.width = .auto;
            try row.append(a, block);
        }
        if (edit and l.verdict == .blocked) {
            var allow = action(cc, "firewall_listener_allow", i18n.tr("Allow on home networks"), firewall.allow_base + i, firewall.clicked, !firewall.editable(cc));
            allow.kind.button.variant = .ghost;
            allow.width = .auto;
            try row.append(a, allow);
        }
        var line = try group(a, .row, row.items);
        line.name = "firewall_listener";
        try items.append(a, line);
    }
    var result = try card(a, items.items);
    result.name = "firewall_listeners";
    return result;
}

fn trustLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Public"), i18n.msg("Home") });
}

pub fn networks(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, try heading(a, i18n.tr("Networks"), if (status.capabilities.trust) i18n.tr("Home networks also get the rules marked \"home networks only\", such as sharing and device discovery. New networks are Public.") else i18n.tr("This firewall applies the same rules on every network.")));
    for (status.networks, 0..) |n, i| {
        if (i >= 32) break;
        const subtitle = if (n.iface.len != 0 and !std.mem.eql(u8, n.iface, n.name)) try a.dupe(u8, n.iface) else "";
        var labels = try group(a, .column, &.{ text(try a.dupe(u8, n.name), 14, false), text(subtitle, 12, true) });
        labels.gap = 3;
        labels.width = .{ .flex = 1 };
        var row: std.ArrayList(W) = .empty;
        try row.append(a, labels);
        if (status.capabilities.trust) {
            const trust: W = .{ .name = "firewall_trust", .kind = .{ .select = .{ .labels = trustLabels(), .selected = @backingInt(n.trust), .owner = cc, .id = firewall.trust_base + i, .on_change = selected, .disabled = !firewall.editable(cc) } }, .width = .{ .fixed = 140 }, .height = .{ .fixed = 34 } };
            try row.append(a, trust);
        }
        try items.append(a, try group(a, .row, row.items));
    }
    var result = try card(a, items.items);
    result.name = "firewall_networks";
    return result;
}

fn incomingLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Block"), i18n.msg("Reject"), i18n.msg("Allow") });
}
fn outgoingLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Allow"), i18n.msg("Block"), i18n.msg("Reject") });
}
fn forwardLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Block"), i18n.msg("Allow") });
}
fn loggingLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Off"), i18n.msg("Low"), i18n.msg("Medium"), i18n.msg("High") });
}

const select_incoming = 1;
const select_outgoing = 2;
const select_forward = 3;
const select_logging = 4;
const toggle_ping = 1;
const toggle_ssh = 2;
const toggle_boot = 3;

fn settingRow(a: Allocator, title: []const u8, note: []const u8, control: W) !W {
    var labels = try group(a, .column, &.{ text(title, 14, false), text(note, 12, true) });
    labels.gap = 3;
    labels.width = .{ .flex = 1 };
    return group(a, .row, &.{ labels, control });
}

fn selectWidget(cc: *panel.ControlCenter, name: []const u8, id: usize, labels: []const []const u8, index: usize) W {
    return .{ .name = name, .kind = .{ .select = .{ .labels = labels, .selected = index, .owner = cc, .id = id, .on_change = selected, .disabled = !firewall.editable(cc) } }, .width = .{ .fixed = 160 }, .height = .{ .fixed = 34 } };
}

fn toggleWidget(cc: *panel.ControlCenter, name: []const u8, id: usize, on: bool) W {
    return .{ .name = name, .kind = .{ .toggle = .{ .style = .settings, .on = on, .disabled = !firewall.editable(cc), .owner = cc, .id = id, .on_change = toggled } } };
}

pub fn advanced(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !W {
    const caps = status.capabilities;
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(i18n.tr("Advanced"), 16, false));
    const incoming: usize = switch (status.incoming) {
        .drop => 0,
        .reject => 1,
        .accept => 2,
    };
    try items.append(a, try settingRow(a, i18n.tr("Incoming connections"), i18n.tr("What happens to connections no rule allows. Block is the safe choice."), selectWidget(cc, "firewall_incoming", select_incoming, incomingLabels(), incoming)));
    if (caps.outgoing_policy) {
        const outgoing: usize = switch (status.outgoing) {
            .accept => 0,
            .drop => 1,
            .reject => 2,
        };
        try items.append(a, try settingRow(a, i18n.tr("Outgoing connections"), i18n.tr("Blocking stops every program from connecting out unless a rule allows it. It is undone after 20 s unless you keep it."), selectWidget(cc, "firewall_outgoing", select_outgoing, outgoingLabels(), outgoing)));
    }
    if (caps.forward_policy) try items.append(a, try settingRow(a, i18n.tr("Forwarding"), i18n.tr("Traffic passing through this computer, for virtual machines or sharing a connection."), selectWidget(cc, "firewall_forward", select_forward, forwardLabels(), if (status.forward == .accept) 1 else 0)));
    if (caps.ping) try items.append(a, try settingRow(a, i18n.tr("Answer ping"), i18n.tr("Let other computers check that this one is there."), toggleWidget(cc, "firewall_ping", toggle_ping, status.ping)));
    if (caps.ssh_limit) try items.append(a, try settingRow(a, i18n.tr("Slow down SSH login attempts"), i18n.tr("Drops a source that opens more than 6 SSH connections a minute."), toggleWidget(cc, "firewall_ssh_limit", toggle_ssh, status.ssh_limit)));
    if (caps.logging) try items.append(a, try settingRow(a, i18n.tr("Log blocked connections"), i18n.tr("Records blocked connections in the system log, at a limited rate."), selectWidget(cc, "firewall_logging", select_logging, loggingLabels(), @backingInt(status.logging))));
    if (caps.boot) try items.append(a, try settingRow(a, i18n.tr("Start at boot"), i18n.tr("Load the firewall before the network comes up."), toggleWidget(cc, "firewall_boot", toggle_boot, status.boot)));
    if (caps.lockdown and !status.lockdown) {
        var button = action(cc, "firewall_lockdown", i18n.tr("Block all connections"), @backingInt(firewall.Id.lockdown_on), firewall.clicked, !(cc.firewall.unlocked and !firewall.busy(cc)));
        button.kind.button.variant = .secondary;
        button.width = .auto;
        try items.append(a, try settingRow(a, i18n.tr("Lockdown"), i18n.tr("Cut this computer off from every network until you stop it or restart. Undone after 20 s unless you keep it."), button));
    }
    var result = try card(a, items.items);
    result.name = "firewall_advanced";
    return result;
}

pub fn foreign(a: Allocator, status: *const model.Status) !W {
    var items: std.ArrayList(W) = .empty;
    try items.append(a, try heading(a, i18n.tr("Other programs' rules"), i18n.tr("Loaded by other programs. RediWM never changes them, and they apply in addition to the rules above.")));
    for (status.foreign) |f| {
        const who = if (f.owner.len != 0) try a.dupe(u8, f.owner) else i18n.tr("Unknown");
        var buffer: [64]u8 = undefined;
        const count = try a.dupe(u8, i18n.fmt(&buffer, i18n.tr("{count} rules"), .{ .count = f.rules }) catch "");
        var labels = try group(a, .column, &.{ text(who, 14, false), text(try a.dupe(u8, f.name), 12, true) });
        labels.gap = 3;
        labels.width = .{ .flex = 1 };
        try items.append(a, try group(a, .row, &.{ labels, text(count, 12, true) }));
    }
    var result = try card(a, items.items);
    result.name = "firewall_foreign";
    return result;
}

pub fn blocks(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !W {
    var items: std.ArrayList(W) = .empty;
    var title = try heading(a, i18n.tr("Recent blocks"), if (status.logging == .off and status.capabilities.logging) i18n.tr("Logging is off, so only blocks from before it was turned off can show.") else i18n.tr("Connections the firewall refused in the last day."));
    title.width = .{ .flex = 1 };
    var show = action(cc, "firewall_blocks", if (cc.firewall.show_blocks) i18n.tr("Refresh") else i18n.tr("Show"), @backingInt(firewall.Id.blocks), firewall.clicked, firewall.busy(cc) or (cc.firewall.read_denied and !cc.firewall.unlocked));
    show.kind.button.variant = .secondary;
    show.width = .auto;
    try items.append(a, try group(a, .row, &.{ title, show }));
    if (cc.firewall.show_blocks) {
        if (status.blocks.len == 0) try items.append(a, text(if (firewall.busy(cc)) i18n.tr("Reading…") else i18n.tr("Nothing was blocked recently."), 13, true));
        for (status.blocks, 0..) |b, i| {
            if (i >= 40) break;
            const line = try std.fmt.allocPrint(a, "{s} · {s} {s} {d} · {s} {s}{s}{s}", .{
                b.time,
                if (b.direction == .in) i18n.tr("in") else i18n.tr("out"),
                b.proto,
                b.port,
                if (b.direction == .in) i18n.tr("from") else i18n.tr("to"),
                b.source,
                if (b.iface.len != 0) " · " else "",
                b.iface,
            });
            try items.append(a, text(line, 12, true));
        }
    }
    var result = try card(a, items.items);
    result.name = "firewall_blocks_card";
    return result;
}

fn selected(raw: ?*anyopaque, id: usize, index: usize) void {
    const cc = firewall.owner(raw);
    const status = (cc.firewall.client orelse return).status() orelse return;
    if (id >= firewall.trust_base) {
        const i = id - firewall.trust_base;
        if (i >= status.networks.len) return;
        const n = status.networks[i];
        firewall.change(cc, .{ .op = .set_trust, .uuid = n.uuid, .iface = n.iface, .trust = if (index == 1) .home else .public });
        return;
    }
    switch (id) {
        select_incoming => firewall.change(cc, .{ .op = .set_defaults, .incoming = switch (index) {
            1 => .reject,
            2 => .accept,
            else => .drop,
        } }),
        select_outgoing => {
            const p: model.Policy = switch (index) {
                1 => .drop,
                2 => .reject,
                else => .accept,
            };
            firewall.change(cc, .{ .op = .set_defaults, .outgoing = p, .revert_after = if (p == .accept) 0 else 20 });
        },
        select_forward => firewall.change(cc, .{ .op = .set_defaults, .forward = if (index == 1) .accept else .drop }),
        select_logging => firewall.change(cc, .{ .op = .set_option, .option = .logging, .logging = @fromBackingInt(@intCast(@min(index, 3))) }),
        else => {},
    }
}

fn toggled(raw: ?*anyopaque, id: usize, on: bool) void {
    const cc = firewall.owner(raw);
    const option: fw.protocol.Option = switch (id) {
        toggle_ping => .ping,
        toggle_ssh => .ssh_limit,
        toggle_boot => .boot,
        else => return,
    };
    firewall.change(cc, .{ .op = .set_option, .option = option, .on = on });
}

fn plainComment(buffer: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (n == buffer.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == ' ' or ch == '-' or ch == '_' or ch == '.') {
            buffer[n] = ch;
            n += 1;
        }
    }
    return buffer[0..n];
}

/// Allows SSH in? Removing such a rule waits for confirmation (D8).
fn allowsSsh(rule: model.Rule) bool {
    if (rule.direction != .in or rule.action == .deny or rule.action == .reject) return false;
    return std.mem.eql(u8, rule.service, "ssh") or (rule.proto != .udp and model.portCovers(rule.port, 22) and rule.port.len != 0);
}

/// Buttons in rows: Remove a rule, Block or Allow a listening program.
pub fn rowClicked(cc: *panel.ControlCenter, id: usize) void {
    const s = &cc.firewall;
    const status = (s.client orelse return).status() orelse return;
    if (id >= firewall.remove_base and id < firewall.block_base) {
        const i = id - firewall.remove_base;
        if (i >= status.rules.len) return;
        if (s.remove_armed != i) {
            s.remove_armed = i;
            return;
        }
        const rule = status.rules[i];
        firewall.change(cc, .{ .op = .remove_rule, .rule = rule, .revert_after = if (allowsSsh(rule)) 20 else 0 });
        return;
    }
    if (id >= firewall.block_base and id < firewall.allow_base) {
        const i = id - firewall.block_base;
        if (i >= status.listeners.len) return;
        const l = status.listeners[i];
        if (status.incoming == .accept) {
            var buffer: [32]u8 = undefined;
            const port = std.fmt.bufPrint(&buffer, "{d}", .{l.port}) catch return;
            firewall.change(cc, .{ .op = .add_rule, .rule = .{ .action = .deny, .port = port, .proto = l.proto } });
            return;
        }
        // Blocked by default: take away the rule that lets it through.
        for (status.rules) |rule| {
            if (rule.action != .allow and rule.action != .limit) continue;
            if (rule.port.len == 0 and rule.service.len == 0) continue;
            if (!model.about(rule, l)) continue;
            firewall.change(cc, .{ .op = .remove_rule, .rule = rule, .revert_after = if (allowsSsh(rule)) 20 else 0 });
            return;
        }
        s.message = i18n.tr("No single rule opens this port; check the rules list.");
        return;
    }
    if (id >= firewall.allow_base and id < firewall.trust_base) {
        const i = id - firewall.allow_base;
        if (i >= status.listeners.len) return;
        const l = status.listeners[i];
        var port_buffer: [32]u8 = undefined;
        var comment_buffer: [32]u8 = undefined;
        const port = std.fmt.bufPrint(&port_buffer, "{d}", .{l.port}) catch return;
        var rule: model.Rule = .{ .port = port, .proto = l.proto, .comment = plainComment(&comment_buffer, l.process) };
        if (status.capabilities.trust) rule.scope = .home else if (status.capabilities.sources) rule.source = "lan";
        firewall.change(cc, .{ .op = .add_rule, .rule = rule });
    }
}
