const i18n = @import("i18n");
// Desktop canvas settings. All tree storage belongs to the open panel.
const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;

// Segmented callbacks carry no owner; the open panel's tree owns the widget.

const map_delays = [_]u32{ 1000, 1500, 2000, 3000, 5000 };
const map_delay_labels = [_]i18n.Message{ i18n.msg("1 second"), i18n.msg("1.5 seconds"), i18n.msg("2 seconds"), i18n.msg("3 seconds"), i18n.msg("5 seconds") };
const map_positions = [_]@import("../../mini_map_geometry.zig").Position{ .bottom_right, .bottom_center, .bottom_left };
const map_position_labels = [_]i18n.Message{ i18n.msg("Bottom right"), i18n.msg("Bottom center"), i18n.msg("Bottom left") };

const switch_ms = [_]u32{ 200, 400, 700, 1000, 1500, 2500 };
const switch_labels = [_][]const u8{ "0.2 s", "0.4 s", "0.7 s", "1 s", "1.5 s", "2.5 s" };

fn nearestSwitch(ms: u32) usize {
    var best: usize = 0;
    for (switch_ms, 0..) |candidate, i| {
        if (@abs(@as(i64, candidate) - ms) < @abs(@as(i64, switch_ms[best]) - ms)) best = i;
    }
    return best;
}

pub const Section = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    root: W = undefined,
    message: []const u8 = "",
    selected_workspace: u8 = 0,
    floating_choices: []const []const u8 = &.{},
};

fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}

fn container(a: std.mem.Allocator, direction: ui.layout.Direction, items: []const W) !W {
    return .{ .kind = .container, .direction = direction, .gap = 12, .@"align" = .stretch, .width = .{ .flex = 1 }, .children = try a.dupe(W, items) };
}

fn card(a: std.mem.Allocator, items: []const W) !W {
    var w = try container(a, .column, items);
    w.kind = .{ .rect = .{ .color = panel.palette().settings_card_bg, .radius = panel.palette().settings_card_radius, .border_width = 1, .border_color = panel.palette().border_soft, .relief = panel.palette().settings_card_relief } };
    w.padding = ui.layout.Edges.all(14);
    return w;
}

fn button(cc: *panel.ControlCenter, id: usize, label: []const u8, disabled: bool) W {
    var w: W = .{ .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = change, .state = if (disabled) .disabled else .idle } } };
    if (id == 4) {
        w.width = .{ .fixed = 180 };
        w.height = .{ .fixed = 36 };
    } else {
        w.kind.button.size = .lg;
        w.width = .{ .fixed = 56 };
        w.height = .{ .fixed = 52 };
    }
    return w;
}

fn dimension(a: std.mem.Allocator, cc: *panel.ControlCenter, vertical: bool, value: u32) !W {
    const id: usize = if (vertical) 2 else 0;
    var number = text(try std.fmt.allocPrint(a, "{d}", .{value}), 22, false);
    number.width = .{ .fixed = 28 };
    var row = try container(a, .row, &.{ button(cc, id, "←", value == 1), number, button(cc, id + 1, "→", value == 10) });
    row.@"align" = .center;
    row.justify = .center;
    return container(a, .column, &.{
        text(if (vertical) i18n.tr("Vertical Pan") else i18n.tr("Horizontal Pan"), 13, false),
        row,
        text(if (vertical) i18n.tr("Screens tall (1–10)") else i18n.tr("Screens wide (1–10)"), 12, true),
    });
}

pub fn build(s: *Section, cc: *panel.ControlCenter) void {
    _ = s.arena.reset(.retain_capacity);
    s.root = tree(s, cc, s.arena.allocator()) catch panel.outOfMemory();
}

fn tree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator) !W {
    const cfg = cc.server.config.compositor;
    const columns = cfg.canvas_columns;
    const rows = cfg.canvas_rows;
    const t = ui.theme.global;
    const accent = t.start_menu_selected_marker;
    // Keep every screen square, including even row/column counts. Centre a
    // compact grid instead of stretching its cells to fill the preview card.
    const gap: f32 = 3;
    const longest: f32 = @floatFromInt(@max(columns, rows));
    const cell_size = @floor((180 - gap * (longest - 1)) / longest);
    const grid_rows = try a.alloc(W, rows);
    for (grid_rows, 0..) |*row, y| {
        const cells = try a.alloc(W, columns);
        for (cells, 0..) |*cell, x| {
            const highlighted = x == 0 and y == rows - 1;
            cell.* = .{ .name = "desktop_preview_cell", .kind = .{ .rect = .{
                .color = if (highlighted) .{ accent[0], accent[1], accent[2], 0.16 } else .{ 1, 1, 1, 0.025 },
                .border_width = if (highlighted) 2 else 1,
                .border_color = if (highlighted) accent else t.window_border,
                .radius = 3,
            } }, .width = .{ .fixed = cell_size }, .height = .{ .fixed = cell_size } };
        }
        row.* = .{ .kind = .container, .direction = .row, .justify = .center, .gap = gap, .width = .{ .percent = 1 }, .height = .{ .fixed = cell_size }, .children = cells };
    }
    // The grid is exactly as tall as its rows: a single row stays one strip
    // instead of floating in a padded box.
    const grid_height = cell_size * @as(f32, @floatFromInt(rows)) + gap * @as(f32, @floatFromInt(rows -| 1));
    const grid: W = .{ .kind = .container, .direction = .column, .justify = .center, .gap = gap, .width = .{ .percent = 1 }, .height = .{ .fixed = grid_height }, .children = grid_rows };
    const preview = try card(a, &.{ panel.sectionTitle(i18n.tr("Canvas Preview")), text(i18n.tr("Your desktop panning area."), 12, true), grid, text(i18n.tr("Highlighted: bottom-left screen"), 12, true) });
    const controls = try card(a, &.{
        panel.sectionTitle(i18n.tr("Canvas Size")),
        try dimension(a, cc, false, columns),
        try dimension(a, cc, true, rows),
        text(try i18n.allocPrint(a, i18n.trn("{columns} × {rows}  ·  {n} screen total", "{columns} × {rows}  ·  {n} screens total", columns * rows), .{ .columns = columns, .rows = rows, .n = columns * rows }), 18, false),
        button(cc, 4, i18n.tr("Reset to Default"), columns == 3 and rows == 3),
    });
    var body = try container(a, if (cc.panel_box.width < 760) .column else .row, &.{ preview, controls });
    body.width = .{ .percent = 1 };
    const switching = try card(a, &.{
        panel.sectionTitle(i18n.tr("Desktop Switching")),
        text(i18n.tr("How long Super + arrow keys take to slide to the next desktop."), 12, true),
        .{ .name = "desktop_switch_ms", .kind = .{ .segmented = .{ .labels = &switch_labels, .selected = nearestSwitch(cfg.desktop_switch_ms), .owner = cc, .on_change = &switchChanged } }, .width = .{ .percent = 1 } },
    });
    const map_on = cfg.mini_map_enabled;
    var map_toggle = try container(a, .row, &.{
        text(i18n.tr("Show mini map"), 13, false),
        .{ .name = "mini_map_enabled", .kind = .{ .toggle = .{ .on = map_on, .owner = cc, .on_change = &mapEnabledChanged } } },
    });
    map_toggle.justify = .space_between;
    map_toggle.@"align" = .center;
    var position_index: usize = 0;
    for (map_positions, 0..) |position, i| if (position == cfg.mini_map_position) {
        position_index = i;
    };
    var delay_index: usize = 0;
    for (map_delays, 0..) |delay, i| {
        if (@abs(@as(i64, delay) - cfg.mini_map_hide_ms) < @abs(@as(i64, map_delays[delay_index]) - cfg.mini_map_hide_ms)) delay_index = i;
    }
    const mini_map = try card(a, &.{
        panel.sectionTitle(i18n.tr("Mini Map")),
        text(i18n.tr("See your position while navigating. Drag the highlighted view to pan."), 12, true),
        map_toggle,
        try mapSelect(cc, a, i18n.tr("Position"), "mini_map_position", panel.translatedLabels(&map_position_labels), position_index, !map_on, &mapPositionChanged),
        try mapSelect(cc, a, i18n.tr("Hide after"), "mini_map_hide_ms", panel.translatedLabels(&map_delay_labels), delay_index, !map_on, &mapDelayChanged),
    });
    var fixed_row = try container(a, .row, &.{
        text(i18n.tr("Keep desktop icons in place"), 13, false),
        .{ .name = "desktop_icons_fixed", .kind = .{ .toggle = .{ .on = cfg.desktop_icons_fixed, .owner = cc, .on_change = &fixedChanged } } },
    });
    fixed_row.justify = .space_between;
    fixed_row.@"align" = .center;
    const mode_card = try card(a, &.{
        panel.sectionTitle(i18n.tr("Desktop mode")),
        .{ .name = "desktop_mode", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Canvas"), i18n.msg("Workspaces") }), .selected = @intFromEnum(cfg.desktop_mode), .owner = cc, .on_change = modeChanged } }, .width = .{ .percent = 1 } },
        text(if (cfg.desktop_mode == .workspaces) i18n.tr("Automatic tiles with a fixed view and Hyprland-style shortcuts. Drag tiles to rearrange; Super+V toggles floating.") else i18n.tr("Pan and zoom the canvas. Switching back restores your canvas positions and zoom."), 12, true),
    });
    if (cfg.desktop_mode == .workspaces) return workspaceTree(s, cc, a, mode_card);
    var root = try container(a, .column, &.{
        mode_card,
        body,
        switching,
        mini_map,
        try card(a, &.{ fixed_row, text(i18n.tr("Keep icons fixed on screen while panning and zooming."), 12, true) }),
        text(i18n.tr("Dragging stops on release. Edges settle with a short animation."), 12, true),
        text(i18n.tr("Existing windows outside a smaller canvas stay reachable."), 12, true),
        text(s.message, 12, true),
    });
    if (s.message.len == 0) root.children = root.children[0 .. root.children.len - 1];
    root.width = .{ .percent = 1 };
    return root;
}

fn mapSelect(cc: *panel.ControlCenter, a: std.mem.Allocator, label: []const u8, name: []const u8, labels: []const []const u8, selected: usize, disabled: bool, callback: *const fn (?*anyopaque, usize, usize) void) !W {
    var row = try container(a, .row, &.{
        text(label, 13, false),
        .{ .name = name, .kind = .{ .select = .{ .labels = labels, .selected = selected, .disabled = disabled, .owner = cc, .on_change = callback } }, .width = .{ .fixed = 180 } },
    });
    row.justify = .space_between;
    row.@"align" = .center;
    return row;
}

fn saveMap(owner: ?*anyopaque, comptime key: []const u8, value: @FieldType(@import("config").loader.CompositorConfig, key)) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    @import("config").setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, key, value) catch {
        cc.desktop.message = i18n.tr("Could not save. Check the configuration file and try again.");
        cc.refresh();
        return;
    };
    @field(cc.server.config.compositor, key) = value;
    cc.server.world.mini_map.reconfigure();
    cc.server.scheduleFrames();
    cc.desktop.message = "";
    cc.refresh();
}
fn mapEnabledChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    saveMap(owner, "mini_map_enabled", on);
}
fn mapPositionChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index < map_positions.len) saveMap(owner, "mini_map_position", map_positions[index]);
}
fn mapDelayChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    if (index < map_delays.len) saveMap(owner, "mini_map_hide_ms", map_delays[index]);
}

fn fixedChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    @import("config").setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, "desktop_icons_fixed", on) catch {
        cc.desktop.message = i18n.tr("Could not save. Check the configuration file and try again.");
        cc.refresh();
        return;
    };
    cc.server.config.compositor.desktop_icons_fixed = on;
    cc.server.scheduleFrames();
    cc.desktop.message = "";
}

fn switchChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    const ms = switch_ms[index];
    // The config watcher's reload rebuilds the camera_desktop curve.
    @import("config").setting_save.saveCompositor(gpa, cc.server.io, cc.server.config.path, "desktop_switch_ms", ms) catch {
        cc.desktop.message = i18n.tr("Could not save. Check the configuration file and try again.");
        cc.refresh();
        return;
    };
    cc.server.config.compositor.desktop_switch_ms = ms;
    if (cc.desktop.message.len != 0) {
        cc.desktop.message = "";
        cc.refresh();
    }
}

fn change(owner: ?*anyopaque, id: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    var columns = cc.server.config.compositor.canvas_columns;
    var rows = cc.server.config.compositor.canvas_rows;
    switch (id) {
        0 => columns -|= 1,
        1 => columns += 1,
        2 => rows -|= 1,
        3 => rows += 1,
        4 => {
            columns = 3;
            rows = 3;
        },
        else => return,
    }
    columns = std.math.clamp(columns, 1, 10);
    rows = std.math.clamp(rows, 1, 10);
    @import("config").setting_save.saveCanvas(gpa, cc.server.io, cc.server.config.path, columns, rows) catch {
        cc.desktop.message = i18n.tr("Could not save. Check the configuration file and try again.");
        cc.refresh();
        return;
    };
    cc.desktop.message = "";
    cc.server.config.compositor.canvas_columns = columns;
    cc.server.config.compositor.canvas_rows = rows;
    @import("../../Output.zig").recomputeWorldBounds(cc.server);
    cc.refresh();
}

fn modeChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index > 1) return;
    const mode: @import("config").loader.DesktopMode = @enumFromInt(index);
    @import("../../config_runtime/workspace_controls.zig").mode(cc.server, mode, true) catch {
        cc.desktop.message = i18n.tr("Could not save desktop mode.");
        cc.refresh();
    };
}

const gaps = [_]u32{ 0, 4, 8, 12, 16, 24, 32 };
const gap_labels = [_][]const u8{ "0 px", "4 px", "8 px", "12 px", "16 px", "24 px", "32 px" };
fn workspaceTree(s: *Section, cc: *panel.ControlCenter, a: std.mem.Allocator, mode_card: W) !W {
    const manager = &cc.server.world.workspaces;
    const id = if (s.selected_workspace > 0) s.selected_workspace else if (cc.server.getDefaultOutput()) |out| @max(1, out.workspace_id) else 1;
    s.selected_workspace = id;
    const labels = try a.alloc([]const u8, 32);
    for (labels, 0..) |*label, i| label.* = try i18n.allocPrint(a, i18n.tr("Workspace {n}"), .{ .n = i + 1 });
    const slot = manager.slots[id - 1];
    const workspace_card = try card(a, &.{
        panel.sectionTitle(i18n.tr("Workspace layout")),
        try mapSelect(cc, a, i18n.tr("Workspace"), "workspace_select", labels, id - 1, false, workspaceSelected),
        try mapSelect(cc, a, i18n.tr("Placement"), "workspace_layout", panel.translatedLabels(&.{ i18n.msg("Automatic tiling"), i18n.msg("Floating") }), if (slot.automatic) 0 else 1, false, layoutChanged),
        text(if (slot.output) |out| try i18n.allocPrint(a, i18n.tr("Output: {name}"), .{ .name = std.mem.span(out.wlr_output.name) }) else i18n.tr("Assigned to the current output when first used."), 12, true),
        text(i18n.tr("Layouts and split sizes are saved for your next session."), 12, true),
    });
    var gap_index: usize = 0;
    const value = cc.server.config.compositor.windowGap();
    for (gaps, 0..) |candidate, i| if (@abs(@as(i64, candidate) - value) < @abs(@as(i64, gaps[gap_index]) - value)) {
        gap_index = i;
    };
    const spacing = try card(a, &.{
        panel.sectionTitle(i18n.tr("Window spacing")),
        try mapSelect(cc, a, try i18n.allocPrint(a, i18n.tr("Gap ({n} px)"), .{ .n = value }), "workspace_gap", &gap_labels, gap_index, false, gapChanged),
        text(i18n.tr("Applies to output edges and the space between automatic tiles."), 12, true),
    });
    var choices: std.ArrayList([]const u8) = .empty;
    for (cc.server.config.compositor.floating_apps) |app| try choices.append(a, try a.dupe(u8, app));
    cc.server.window_tabs.loadKnown(cc.server);
    var it = cc.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| _ = cc.server.window_tabs.remember(top.appId());
    for (cc.server.window_tabs.known.items) |app| {
        var found = false;
        for (choices.items) |existing| if (std.mem.eql(u8, app, existing)) {
            found = true;
            break;
        };
        if (!found) try choices.append(a, try a.dupe(u8, app));
    }
    s.floating_choices = choices.items;
    const list = ui.widgets.checkbox_list;
    const items = try a.alloc(list.Item, choices.items.len);
    for (choices.items, items, 0..) |app, *item, i| {
        var checked = false;
        for (cc.server.config.compositor.floating_apps) |enabled| if (std.mem.eql(u8, enabled, app)) {
            checked = true;
            break;
        };
        item.* = .{ .id = i, .name = try std.fmt.allocPrint(a, "floating_app:{s}", .{app}), .label = app, .checked = checked };
    }
    const rules = try card(a, &.{
        panel.sectionTitle(i18n.tr("Floating apps")),
        text(i18n.tr("Checked apps open floating. Super+V can override placement for a window. Dialogs and fixed-size windows float automatically."), 12, true),
        try list.build(a, items, cc, floatingChanged, .{}),
        text(i18n.tr("Open an app to add it here. Advanced title, backend and glob matches use [[window_rules]] floating in your config."), 12, true),
    });
    return container(a, .column, &.{ mode_card, workspace_card, spacing, rules, text(s.message, 12, true) });
}
fn workspaceSelected(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index >= 32) return;
    cc.desktop.selected_workspace = @intCast(index + 1);
    cc.refresh();
}
fn layoutChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index > 1) return;
    @import("../../config_runtime/workspace_controls.zig").automatic(cc.server, cc.desktop.selected_workspace, index == 0);
}
fn gapChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index >= gaps.len) return;
    @import("../../config_runtime/workspace_controls.zig").gap(cc.server, gaps[index], true) catch {
        cc.desktop.message = i18n.tr("Could not save window spacing.");
        cc.refresh();
    };
}
fn floatingChanged(owner: ?*anyopaque, index: usize, checked: bool) void {
    const cc: *panel.ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (index >= cc.desktop.floating_choices.len) return;
    const selected = cc.desktop.floating_choices[index];
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var apps: std.ArrayList([]const u8) = .empty;
    for (cc.server.config.compositor.floating_apps) |app| if (!std.mem.eql(u8, selected, app)) {
        apps.append(a, app) catch return;
    };
    if (checked) apps.append(a, selected) catch return;
    @import("../../config_runtime/workspace_controls.zig").floatingApps(cc.server, apps.items, true) catch {
        cc.desktop.message = i18n.tr("Could not save floating apps.");
        cc.refresh();
    };
}
