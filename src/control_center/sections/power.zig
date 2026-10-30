//! Power-source settings; callbacks queue changes until widget dispatch returns.
const std = @import("std");
const i18n = @import("i18n");
const ui = @import("ui");
const panel = @import("../panel.zig");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;
const config = @import("config");
const power = config.power;
const Field = enum { source, mode, brightness, blank, sleep, lid, docked, lock, warning, saver, critical, critical_action, dim, dim_brightness, keyboard, charge, automatic };
const times = [_]u32{ 0, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200 };

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    source: ?power.Source = null,
    pending: ?struct { field: Field, value: usize } = null,
    values: [@typeInfo(Field).@"enum".field_names.len][]const u32 = @splat(&.{}),
    message: []const u8 = "",
};

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    if (s.source == null) s.source = cc.server.power_policy.source orelse .plugged_in;
    if (!cc.server.power_policy.state.present) s.source = .plugged_in;
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}

fn group(a: std.mem.Allocator, children: []const W) !W {
    return .{ .kind = .container, .direction = .column, .gap = 14, .width = .{ .percent = 1 }, .children = try a.dupe(W, children) };
}

fn card(a: std.mem.Allocator, children: []const W) !W {
    const owned = try a.dupe(W, children);
    var w = panel.card(owned);
    w.gap = 14;
    return w;
}

fn row(cc: *panel.ControlCenter, a: std.mem.Allocator, title: []const u8, control: W) !W {
    var label = panel.label(title, panel.palette().settings_description_size, false);
    label.width = .{ .flex = 1 };
    return .{ .kind = .container, .direction = if (cc.panel_box.width < 760) .column else .row, .gap = 8, .@"align" = .center, .justify = .space_between, .width = .{ .percent = 1 }, .children = try a.dupe(W, &.{ label, control }) };
}

fn select(cc: *panel.ControlCenter, name: []const u8, field: Field, labels: []const []const u8, selected: usize) W {
    return .{ .name = name, .kind = .{ .select = .{ .labels = labels, .selected = selected, .owner = cc, .id = @backingInt(field), .on_change = changed } }, .width = .{ .fixed = 220 }, .height = .{ .fixed = 36 } };
}

fn number(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, field: Field, name: []const u8, title: []const u8, value: u32, seconds: bool) !W {
    var values: std.ArrayList(u32) = .empty;
    if (seconds) try values.appendSlice(a, &times) else for (0..101) |percent| {
        if (field == .dim_brightness and percent == 0) continue;
        if (field == .charge and percent > 0 and percent < 50) continue;
        try values.append(a, @intCast(percent));
    }
    var selected: ?usize = null;
    for (values.items, 0..) |v, i| if (v == value) {
        selected = i;
        break;
    };
    if (selected == null) {
        selected = values.items.len;
        try values.append(a, value);
    }
    const labels = try a.alloc([]const u8, values.items.len);
    for (values.items, labels) |v, *label| {
        label.* = if (v == 0)
            (if (field == .brightness or field == .charge) i18n.tr("Leave unchanged") else i18n.tr("Never"))
        else if (seconds and v % 60 == 0)
            try i18n.allocPrint(a, i18n.trn("{n} minute", "{n} minutes", v / 60), .{ .n = v / 60 })
        else if (seconds)
            try i18n.allocPrint(a, i18n.trn("{n} second", "{n} seconds", v), .{ .n = v })
        else
            try std.fmt.allocPrint(a, "{d}%", .{v});
    }
    s.values[@backingInt(field)] = values.items;
    return row(cc, a, title, select(cc, name, field, labels, selected.?));
}

fn profileCard(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const p = cc.server.config.power.profile(s.source.?);
    const idle = power.idle(p, cc.server.config.idle);
    const mode_labels = panel.translatedLabels(&.{ i18n.msg("Leave unchanged"), i18n.msg("Power Saver"), i18n.msg("Balanced"), i18n.msg("Performance") });
    var mode_select = select(cc, "power_mode", .mode, mode_labels, @backingInt(p.mode));
    var disabled: std.ArrayList(usize) = .empty;
    for (0..3) |index| {
        const supported = if (cc.server.power_profiles) |m| m.supports(@fromBackingInt(@intCast(index))) else false;
        if (!supported) try disabled.append(a, index + 1);
    }
    mode_select.kind.select.disabled_options = disabled.items;
    var rows: std.ArrayList(W) = .empty;
    try rows.append(a, panel.sectionTitle(if (!cc.server.power_policy.state.present) i18n.tr("Power settings") else if (s.source == .on_battery) i18n.tr("On battery") else i18n.tr("Plugged in")));
    try rows.append(a, try row(cc, a, i18n.tr("Power mode"), mode_select));
    try rows.append(a, try number(s, cc, a, .brightness, "power_brightness", i18n.tr("Set brightness"), p.brightness, false));
    const keyboard = cc.server.keyboard_brightness.level;
    if (keyboard != null or p.keyboard_brightness != null) {
        var values: std.ArrayList(u32) = .empty;
        try values.appendSlice(a, &.{ 101, 0, 33, 66, 100 });
        const current = p.keyboard_brightness orelse 101;
        var selected: ?usize = null;
        for (values.items, 0..) |value, index| if (value == current) {
            selected = index;
            break;
        };
        if (selected == null) {
            selected = values.items.len;
            try values.append(a, current);
        }
        const labels = try a.alloc([]const u8, values.items.len);
        for (values.items, labels) |value, *label| label.* = if (value == 101) i18n.tr("Leave unchanged") else if (value == 0) i18n.tr("Off") else try std.fmt.allocPrint(a, "{d}%", .{value});
        s.values[@backingInt(Field.keyboard)] = values.items;
        try rows.append(a, try row(cc, a, i18n.tr("Keyboard backlight"), select(cc, "power_keyboard", .keyboard, labels, selected.?)));
    }
    try rows.append(a, try panel.paragraph(a, i18n.tr("Brightness and power mode apply on login and when the power source changes. Manual changes last until the next source change."), @max(180, @as(f32, @floatFromInt(cc.panel_box.width)) - panel.sidebarWidth(cc) - 140), 12, true));
    try rows.append(a, try number(s, cc, a, .dim, "power_dim", i18n.tr("Dim screen after"), p.dim_after_seconds, true));
    if (p.dim_after_seconds > 0) try rows.append(a, try number(s, cc, a, .dim_brightness, "power_dim_brightness", i18n.tr("Dim brightness"), p.dim_brightness, false));
    try rows.append(a, try number(s, cc, a, .blank, "power_blank", i18n.tr("Turn off screen after"), idle.blank_after_seconds, true));
    try rows.append(a, try number(s, cc, a, .sleep, "power_sleep", i18n.tr("Sleep after"), idle.suspend_after_seconds, true));
    if (cc.server.input.lid.present()) try rows.append(a, try row(cc, a, i18n.tr("When the lid closes"), select(cc, "lid_close", .lid, panel.translatedLabels(&.{ i18n.msg("Turn off built-in screen"), i18n.msg("Lock"), i18n.msg("Sleep"), i18n.msg("Do nothing") }), @backingInt(p.lid_close orelse cc.server.config.compositor.lid_close))));
    return card(a, rows.items);
}

fn commonCard(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const cfg = cc.server.config.power;
    var rows: std.ArrayList(W) = .empty;
    try rows.append(a, panel.sectionTitle(if (cc.server.power_policy.state.present) i18n.tr("Sleep and battery") else i18n.tr("Sleep")));
    try rows.append(a, try row(cc, a, i18n.tr("Lock before sleep"), .{ .name = "lock_on_suspend", .kind = .{ .toggle = .{ .on = cfg.lock_on_suspend orelse cc.server.config.compositor.lock_on_suspend, .owner = cc, .id = @backingInt(Field.lock), .on_change = toggled } } }));
    if (cc.server.input.lid.present()) try rows.append(a, try row(cc, a, i18n.tr("Lid closed with external display"), select(cc, "power_docked", .docked, panel.translatedLabels(&.{ i18n.msg("Follow lid action"), i18n.msg("Keep working") }), @backingInt(cfg.docked))));
    if (cc.server.power_policy.state.present) {
        const charge = cc.server.power_policy.charge_limit;
        if (charge.supported) {
            var charge_row = try number(s, cc, a, .charge, "power_charge_limit", i18n.tr("Stop charging at"), cfg.charge_limit, false);
            charge_row.children[1].kind.select.disabled = !charge.writable;
            try rows.append(a, charge_row);
            if (!charge.writable) try rows.append(a, panel.label(i18n.tr("Charging limits require write permission from your system administrator."), 12, true));
            if (charge.percent) |percent| try rows.append(a, panel.label(try i18n.allocPrint(a, i18n.tr("Firmware charging limit: {percent}%"), .{ .percent = percent }), 12, true));
        }
        try rows.append(a, try number(s, cc, a, .warning, "power_warning", i18n.tr("Warn when battery reaches"), cfg.low_battery_percent, false));
        try rows.append(a, try number(s, cc, a, .saver, "power_saver", i18n.tr("Enable Power Saver below"), cfg.power_saver_percent, false));
        try rows.append(a, try number(s, cc, a, .critical, "power_critical", i18n.tr("Critical battery level"), cfg.critical_percent, false));
        if (cfg.critical_percent > 0) try rows.append(a, try row(cc, a, i18n.tr("At critical battery level"), select(cc, "power_critical_action", .critical_action, panel.translatedLabels(&.{ i18n.msg("Notify only"), i18n.msg("Sleep"), i18n.msg("Power off") }), @backingInt(cfg.critical_action))));
    }
    return card(a, rows.items);
}

fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const state = cc.server.power_policy.state;
    var rows: std.ArrayList(W) = .empty;
    if (state.present) {
        const percentage = if (state.percent) |p| try std.fmt.allocPrint(a, "{d}%", .{p}) else i18n.tr("Unavailable");
        try rows.append(a, panel.sectionTitle(try std.fmt.allocPrint(a, "{s} · {s}", .{ percentage, state.status() })));
        var estimate_buf: [192]u8 = undefined;
        if (state.estimate(&estimate_buf)) |estimate| try rows.append(a, panel.label(try a.dupe(u8, estimate), 13, true));
        if (state.health) |health| try rows.append(a, panel.label(try i18n.allocPrint(a, i18n.tr("Battery health: {percent}%"), .{ .percent = health }), 13, true));
        try rows.append(a, .{ .name = "power_source", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Plugged in"), i18n.msg("On battery") }), .selected = @backingInt(s.source.?), .owner = cc, .id = @backingInt(Field.source), .on_change = changed } }, .width = .{ .percent = 1 } });
    }
    if (cc.server.power_profiles) |manager| if (manager.active) |mode| {
        try rows.append(a, panel.label(try i18n.allocPrint(a, i18n.tr("Current power mode: {mode}"), .{ .mode = mode.label() }), 13, true));
    };
    try rows.append(a, try row(cc, a, i18n.tr("Automatic power management"), .{ .name = "power_enabled", .kind = .{ .toggle = .{ .on = cc.server.config.power.enabled orelse cc.server.backend.isDrm(), .owner = cc, .id = @backingInt(Field.automatic), .on_change = toggled } } }));
    if (!cc.server.power_policy.enabled()) try rows.append(a, panel.label(i18n.tr("Automatic power actions are inactive in this session."), 13, true));
    if (s.message.len > 0) try rows.append(a, panel.label(s.message, 13, true));
    if (cc.server.power_policy.message.len > 0) try rows.append(a, panel.label(cc.server.power_policy.message, 13, true));
    try rows.append(a, try profileCard(s, cc, a));
    try rows.append(a, try commonCard(s, cc, a));
    return group(a, rows.items);
}

fn changed(owner: ?*anyopaque, id: usize, selected: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    cc.power_settings.pending = .{ .field = @fromBackingInt(@intCast(id)), .value = selected };
}

fn toggled(owner: ?*anyopaque, id: usize, on: bool) void {
    changed(owner, id, @intFromBool(on));
}

pub fn apply(cc: *panel.ControlCenter) void {
    const s = &cc.power_settings;
    const pending = s.pending orelse return;
    s.pending = null;
    if (pending.field == .source) {
        s.source = @fromBackingInt(@intCast(pending.value));
    } else {
        save(cc, pending.field, pending.value) catch |err| {
            std.log.warn("saving power preferences: {}", .{err});
            s.message = i18n.tr("Could not save power settings.");
            cc.refresh();
            return;
        };
        s.message = "";
        @import("../../config_runtime/watcher.zig").reloadConfig(cc.server);
    }
    cc.refresh();
}

fn save(cc: *panel.ControlCenter, field: Field, selected: usize) !void {
    const s = &cc.power_settings;
    const values = s.values[@backingInt(field)];
    const value = if (values.len > 0) values[selected] else 0;
    switch (field) {
        .source => unreachable,
        .automatic => try persist(cc, null, "enabled", selected != 0),
        .charge => try persist(cc, null, "charge_limit", value),
        .keyboard => try persist(cc, s.source, "keyboard_brightness", if (value == 101) @as(i32, -1) else @as(i32, @intCast(value))),
        .mode => try persist(cc, s.source, "mode", @as(power.Mode, @fromBackingInt(@intCast(selected)))),
        .brightness => try persist(cc, s.source, "brightness", value),
        .dim => try persist(cc, s.source, "dim_after_seconds", value),
        .dim_brightness => try persist(cc, s.source, "dim_brightness", @max(1, value)),
        .blank => try persist(cc, s.source, "blank_after_seconds", value),
        .sleep => try persist(cc, s.source, "suspend_after_seconds", value),
        .lid => try persist(cc, s.source, "lid_close", @as(config.types.LidAction, @fromBackingInt(@intCast(selected)))),
        .docked => try persist(cc, null, "docked", @as(power.Docked, @fromBackingInt(@intCast(selected)))),
        .lock => try persist(cc, null, "lock_on_suspend", selected != 0),
        .warning => try persist(cc, null, "low_battery_percent", value),
        .saver => try persist(cc, null, "power_saver_percent", value),
        .critical => try persist(cc, null, "critical_percent", value),
        .critical_action => try persist(cc, null, "critical_action", @as(power.Critical, @fromBackingInt(@intCast(selected)))),
    }
}

fn persist(cc: *panel.ControlCenter, source: ?power.Source, comptime key: []const u8, value: anytype) !void {
    try config.setting_save.savePower(gpa, cc.server.io, cc.server.config.path, source, key, value);
}
