//! The Firewall sub-view's rules: the list (with a two-click Remove) and the
//! Add rule form. A rule is a catalog service, a port, or an address; the
//! form offers only what the active manager can express.
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

/// The catalog's service names as literals the extractor finds, in
/// `fw.services.all` order (the firewall module, shared with the root helper,
/// stays free of i18n). The check below keeps the two lists in step.
const service_names = [_]i18n.Message{
    i18n.msg("SSH (remote login)"),
    i18n.msg("Web server (HTTP)"),
    i18n.msg("Web server (HTTPS)"),
    i18n.msg("Local network discovery (mDNS)"),
    i18n.msg("KDE Connect / GSConnect"),
    i18n.msg("Syncthing"),
    i18n.msg("Steam Remote Play"),
    i18n.msg("Windows file sharing (Samba)"),
    i18n.msg("Printer sharing (IPP)"),
    i18n.msg("Media sharing (DLNA)"),
    i18n.msg("Spotify local discovery"),
    i18n.msg("Files transfers (BitTorrent)"),
    i18n.msg("Screen sharing (VNC)"),
    i18n.msg("Remote desktop (RDP)"),
    i18n.msg("WireGuard server"),
    i18n.msg("NFS file sharing"),
    i18n.msg("Minecraft server"),
};

comptime {
    if (service_names.len != fw.services.all.len) @compileError("firewall service names out of step with services.all");
    for (service_names, fw.services.all) |name, svc| {
        if (!std.mem.eql(u8, name.source, svc.name)) @compileError("firewall service name out of step: " ++ svc.name);
    }
}

/// A catalog service's name in the user's language.
pub fn serviceName(index: usize) []const u8 {
    return if (index < service_names.len) service_names[index].get() else "";
}

fn catalogIndex(id: []const u8) ?usize {
    for (fw.services.all, 0..) |svc, i| if (std.mem.eql(u8, svc.id, id)) return i;
    return null;
}

fn actionLabel(act: model.Action) []const u8 {
    return switch (act) {
        .allow => i18n.tr("Allow"),
        .deny => i18n.tr("Block"),
        .reject => i18n.tr("Reject"),
        .limit => i18n.tr("Allow, rate-limited"),
    };
}

fn protoLabel(p: model.Proto) []const u8 {
    return switch (p) {
        .tcp => "TCP",
        .udp => "UDP",
        .both => "TCP/UDP",
    };
}

/// The rule's first line: its service's name, a port, or an address.
pub fn title(a: Allocator, rule: model.Rule) ![]const u8 {
    if (rule.raw.len != 0 and rule.port.len == 0 and rule.service.len == 0 and rule.source.len == 0) return a.dupe(u8, rule.raw);
    if (catalogIndex(rule.service)) |i| return a.dupe(u8, serviceName(i));
    if (rule.service.len != 0) return a.dupe(u8, rule.service);
    if (rule.port.len != 0) return std.fmt.allocPrint(a, "{s} {s} {s}", .{ i18n.tr("Port"), rule.port, protoLabel(rule.proto) });
    if (rule.source.len != 0) return std.fmt.allocPrint(a, "{s} {s}", .{ i18n.tr("Address"), rule.source });
    return a.dupe(u8, i18n.tr("All traffic"));
}

/// The rule's second line: what it does and where.
pub fn detail(a: Allocator, rule: model.Rule) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s} · {s}", .{ actionLabel(rule.action), if (rule.direction == .in) i18n.tr("incoming") else i18n.tr("outgoing") });
    if (rule.service.len != 0 and rule.port.len != 0) try w.print(" · {s} {s}", .{ rule.port, protoLabel(rule.proto) });
    if (std.mem.eql(u8, rule.source, "lan")) {
        try w.print(" · {s}", .{i18n.tr("local network only")});
    } else if (rule.source.len != 0 and (rule.port.len != 0 or rule.service.len != 0)) try w.print(" · {s} {s}", .{ if (rule.direction == .in) i18n.tr("from") else i18n.tr("to"), rule.source });
    if (rule.scope == .home) try w.print(" · {s}", .{i18n.tr("home networks only")});
    if (rule.iface.len != 0) try w.print(" · {s} {s}", .{ i18n.tr("on"), rule.iface });
    if (rule.family != .both) try w.print(" · {s}", .{if (rule.family == .v4) "IPv4" else "IPv6"});
    if (rule.comment.len != 0) try w.print(" · {s}", .{rule.comment});
    if (rule.raw.len != 0) try w.print(" · {s}", .{i18n.tr("can only be removed here")});
    return out.written();
}

pub fn rulesCard(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !W {
    const s = &cc.firewall;
    var items: std.ArrayList(W) = .empty;
    var heading = text(i18n.tr("Rules"), 16, false);
    heading.width = .{ .flex = 1 };
    var header: std.ArrayList(W) = .empty;
    try header.append(a, heading);
    if (status.capabilities.edit) {
        var add = action(cc, "firewall_add", i18n.tr("Add rule…"), @backingInt(firewall.Id.add_open), firewall.clicked, !firewall.editable(cc) or s.adding);
        add.kind.button.leading_icon = .plus;
        add.width = .auto;
        try header.append(a, add);
    }
    try items.append(a, try group(a, .row, header.items));
    if (status.rules.len == 0) {
        var buffer: [160]u8 = undefined;
        try items.append(a, text(try a.dupe(u8, i18n.fmt(&buffer, i18n.tr("No rules. Incoming connections follow the default: {policy}."), .{ .policy = firewall.policyLabel(status.incoming) }) catch ""), 13, true));
    }
    for (status.rules, 0..) |rule, i| {
        var labels = try group(a, .column, &.{ text(try title(a, rule), 14, false), text(try detail(a, rule), 12, true) });
        labels.gap = 3;
        labels.width = .{ .flex = 1 };
        var row: std.ArrayList(W) = .empty;
        try row.append(a, widgets.icon(if (rule.action == .allow or rule.action == .limit) .checkmark else .close, 18, rule.action == .allow or rule.action == .limit));
        try row.append(a, labels);
        if (status.capabilities.edit) {
            const armed = s.remove_armed == i;
            var remove = action(cc, "firewall_rule_remove", if (armed) i18n.tr("Remove?") else i18n.tr("Remove"), firewall.remove_base + i, firewall.clicked, !firewall.editable(cc));
            remove.kind.button.variant = if (armed) .primary else .ghost;
            remove.width = .auto;
            try row.append(a, remove);
        }
        var line = try group(a, .row, row.items);
        line.name = "firewall_rule";
        try items.append(a, line);
    }
    var result = try card(a, items.items);
    result.name = "firewall_rules";
    return result;
}

fn kindLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Service"), i18n.msg("Port"), i18n.msg("Address") });
}
fn actionLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Allow"), i18n.msg("Block"), i18n.msg("Reject"), i18n.msg("Allow, rate-limited") });
}
fn protoLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("TCP"), i18n.msg("UDP"), i18n.msg("TCP and UDP") });
}
fn directionLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Incoming"), i18n.msg("Outgoing") });
}
fn sourceLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("Anywhere"), i18n.msg("Local network"), i18n.msg("An address") });
}
fn scopeLabels() []const []const u8 {
    return panel.translatedLabels(&.{ i18n.msg("All networks"), i18n.msg("Home networks only") });
}

fn serviceLabels(a: Allocator) ![]const []const u8 {
    const labels = try a.alloc([]const u8, fw.services.all.len);
    for (labels, 0..) |*label, i| label.* = serviceName(i);
    return labels;
}

fn select(cc: *panel.ControlCenter, name: []const u8, id: usize, labels: []const []const u8, selected: usize, disabled_options: []const usize) W {
    return .{ .name = name, .kind = .{ .select = .{ .labels = labels, .selected = selected, .owner = cc, .id = id, .on_change = selectChanged, .disabled_options = disabled_options } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 34 } };
}

fn selectChanged(raw: ?*anyopaque, id: usize, index: usize) void {
    const cc = firewall.owner(raw);
    const f = &cc.firewall.form;
    f.fields.capture();
    switch (id) {
        0 => f.kind = index,
        1 => {
            f.service = index;
            if (index < fw.services.all.len) f.scope = if (fw.services.all[index].scope == .home) 1 else 0;
        },
        2 => f.rule_action = index,
        3 => f.proto = index,
        4 => f.direction = index,
        5 => f.source = index,
        6 => f.scope = index,
        else => {},
    }
    cc.refresh();
}

pub fn formCard(cc: *panel.ControlCenter, a: Allocator, status: *const model.Status) !W {
    const f = &cc.firewall.form;
    const caps = status.capabilities;
    var items: std.ArrayList(W) = .empty;
    try items.append(a, text(i18n.tr("Add rule"), 16, false));
    var first: std.ArrayList(W) = .empty;
    try first.append(a, try fields.labeled(a, i18n.tr("Kind"), select(cc, "firewall_form_kind", 0, kindLabels(), f.kind, &.{})));
    switch (f.kind) {
        0 => try first.append(a, try fields.labeled(a, i18n.tr("Service"), select(cc, "firewall_form_service", 1, try serviceLabels(a), f.service, &.{}))),
        1 => {
            try first.append(a, try f.fields.input(a, .port, "firewall_form_port", i18n.tr("Port or range")));
            try first.append(a, try fields.labeled(a, i18n.tr("Protocol"), select(cc, "firewall_form_proto", 3, protoLabels(), f.proto, &.{})));
        },
        else => try first.append(a, try f.fields.input(a, .address, "firewall_form_address", i18n.tr("Address or network"))),
    }
    for (first.items) |*w| w.width = .{ .flex = 1 };
    var row1 = try group(a, .row, first.items);
    row1.@"align" = .start;
    try items.append(a, row1);

    var disabled_actions: std.ArrayList(usize) = .empty;
    if (!caps.reject) try disabled_actions.append(a, 2);
    if (!caps.limit or f.kind == 2) try disabled_actions.append(a, 3);
    var second: std.ArrayList(W) = .empty;
    try second.append(a, try fields.labeled(a, i18n.tr("Action"), select(cc, "firewall_form_action", 2, actionLabels(), f.rule_action, disabled_actions.items)));
    if (caps.outgoing_rules) try second.append(a, try fields.labeled(a, i18n.tr("Direction"), select(cc, "firewall_form_direction", 4, directionLabels(), f.direction, &.{})));
    if (caps.sources and f.kind != 2) try second.append(a, try fields.labeled(a, if (f.direction == 0) i18n.tr("From") else i18n.tr("To"), select(cc, "firewall_form_source", 5, sourceLabels(), f.source, &.{})));
    if (caps.trust) try second.append(a, try fields.labeled(a, i18n.tr("Where"), select(cc, "firewall_form_scope", 6, scopeLabels(), f.scope, &.{})));
    for (second.items) |*w| w.width = .{ .flex = 1 };
    var row2 = try group(a, .row, second.items);
    row2.@"align" = .start;
    try items.append(a, row2);
    if (caps.sources and f.kind != 2 and f.source == 2) try items.append(a, try f.fields.input(a, .source, "firewall_form_source_address", i18n.tr("Address or network")));
    try items.append(a, try f.fields.input(a, .comment, "firewall_form_comment", i18n.tr("Note")));
    if (cc.firewall.message.len != 0) try items.append(a, text(try a.dupe(u8, cc.firewall.message), 12, true));
    var add = action(cc, "firewall_form_add", i18n.tr("Add"), @backingInt(firewall.Id.add_submit), firewall.clicked, !firewall.editable(cc));
    add.width = .auto;
    var cancel = action(cc, "firewall_form_cancel", i18n.tr("Cancel"), @backingInt(firewall.Id.add_cancel), firewall.clicked, false);
    cancel.kind.button.variant = .secondary;
    cancel.width = .auto;
    try items.append(a, try group(a, .row, &.{ add, cancel }));
    var result = try card(a, items.items);
    result.name = "firewall_form";
    return result;
}

/// The form as a rule, or null with the reason in the section's message.
pub fn formRule(cc: *panel.ControlCenter, status: *const model.Status) ?model.Rule {
    const s = &cc.firewall;
    const f = &s.form;
    var rule: model.Rule = .{
        .action = switch (f.rule_action) {
            1 => .deny,
            2 => .reject,
            3 => .limit,
            else => .allow,
        },
        .direction = if (f.direction == 1 and status.capabilities.outgoing_rules) .out else .in,
        .scope = if (f.scope == 1 and status.capabilities.trust) .home else .everywhere,
        .comment = std.mem.trim(u8, f.fields.value(.comment), " "),
    };
    switch (f.kind) {
        0 => rule.service = fw.services.all[@min(f.service, fw.services.all.len - 1)].id,
        1 => {
            rule.port = std.mem.trim(u8, f.fields.value(.port), " ");
            rule.proto = switch (f.proto) {
                0 => .tcp,
                1 => .udp,
                else => .both,
            };
            if (!fw.validate.port(rule.port) or rule.port.len == 0) {
                s.message = i18n.tr("Enter a port from 1 to 65535, or a range like 6000-6010.");
                return null;
            }
        },
        else => {
            rule.source = std.mem.trim(u8, f.fields.value(.address), " ");
            if (!fw.validate.cidr(rule.source)) {
                s.message = i18n.tr("Enter an IP address, or a network like 10.0.0.0/8.");
                return null;
            }
        },
    }
    if (f.kind != 2 and status.capabilities.sources) {
        if (f.source == 1) rule.source = "lan";
        if (f.source == 2) {
            rule.source = std.mem.trim(u8, f.fields.value(.source), " ");
            if (!fw.validate.cidr(rule.source)) {
                s.message = i18n.tr("Enter an IP address, or a network like 10.0.0.0/8.");
                return null;
            }
        }
    }
    if (rule.action == .limit and rule.proto == .both and rule.port.len != 0) rule.proto = .tcp;
    if (!fw.validate.comment(rule.comment)) {
        s.message = i18n.tr("The note may use up to 64 plain characters, without quotes.");
        return null;
    }
    if (!fw.validate.rule(rule)) {
        s.message = i18n.tr("This rule cannot be added.");
        return null;
    }
    return rule;
}

pub fn submit(cc: *panel.ControlCenter) void {
    const status = (cc.firewall.client orelse return).status() orelse return;
    cc.firewall.message = "";
    const rule = formRule(cc, status) orelse return;
    // Copy the typed strings: the fields own them and the request is
    // serialized now, but keep them stable until then.
    firewall.change(cc, .{ .op = .add_rule, .rule = rule });
}
