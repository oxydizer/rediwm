// Desktop canvas settings. All tree storage belongs to the open panel.
const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const gpa = @import("../../main.zig").gpa;

// Segmented callbacks carry no owner; the open panel's tree owns the widget.

const map_delays = [_]u32{ 1000, 1500, 2000, 3000, 5000 };
const map_delay_labels = [_][]const u8{ "1 second", "1.5 seconds", "2 seconds", "3 seconds", "5 seconds" };
const map_positions = [_]@import("../../mini_map_geometry.zig").Position{ .bottom_right, .bottom_center, .bottom_left };
const map_position_labels = [_][]const u8{ "Bottom right", "Bottom center", "Bottom left" };

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
    w.kind = .{ .rect = .{ .color = panel.palette().settings_card_bg, .radius = panel.palette().settings_card_radius, .border_width = 1, .border_color = panel.palette().border_soft } };
    w.padding = ui.layout.Edges.all(14);
    return w;
}

fn button(cc: *panel.ControlCenter, id: usize, label: []const u8, disabled: bool) W {
    return .{ .kind = .{ .button = .{ .label = label, .owner = cc, .id = id, .on_click = change, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 36 }, .width = .{ .fixed = if (id == 4) 180 else 42 } };
}

fn dimension(a: std.mem.Allocator, cc: *panel.ControlCenter, vertical: bool, value: u32) !W {
    const id: usize = if (vertical) 2 else 0;
    var number = text(try std.fmt.allocPrint(a, "{d}", .{value}), 22, false);
    number.width = .{ .flex = 1 };
    var row = try container(a, .row, &.{ button(cc, id, "←", value == 1), number, button(cc, id + 1, "→", value == 10) });
    row.@"align" = .center;
    return container(a, .column, &.{
        text(if (vertical) "Vertical Pan" else "Horizontal Pan", 13, false),
        row,
        text(if (vertical) "Screens tall (1–10)" else "Screens wide (1–10)", 12, true),
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
    const grid: W = .{ .kind = .container, .direction = .column, .justify = .center, .gap = gap, .width = .{ .percent = 1 }, .height = .{ .fixed = 220 }, .children = grid_rows };
    const preview = try card(a, &.{ text("Canvas Preview", 16, false), text("Your desktop panning area.", 12, true), grid, text("Highlighted: bottom-left screen", 12, true) });
    const controls = try card(a, &.{
        text("Canvas Size", 16, false),
        try dimension(a, cc, false, columns),
        try dimension(a, cc, true, rows),
        text(try std.fmt.allocPrint(a, "{d} × {d}  ·  {d} screens total", .{ columns, rows, columns * rows }), 18, false),
        button(cc, 4, "Reset to Default", columns == 3 and rows == 3),
    });
    var body = try container(a, if (cc.panel_box.width < 760) .column else .row, &.{ preview, controls });
    body.width = .{ .percent = 1 };
    const switching = try card(a, &.{
        text("Desktop Switching", 16, false),
        text("How long Super + arrow keys take to slide to the next desktop.", 12, true),
        .{ .name = "desktop_switch_ms", .kind = .{ .segmented = .{ .labels = &switch_labels, .selected = nearestSwitch(cfg.desktop_switch_ms), .owner = cc, .on_change = &switchChanged } }, .width = .{ .percent = 1 } },
    });
    const map_on = cfg.mini_map_enabled;
    var map_toggle = try container(a, .row, &.{
        text("Show mini map", 13, false),
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
        text("Mini Map", 16, false),
        text("See your position while navigating. Drag the highlighted view to pan.", 12, true),
        map_toggle,
        try mapSelect(cc, a, "Position", "mini_map_position", &map_position_labels, position_index, !map_on, &mapPositionChanged),
        try mapSelect(cc, a, "Hide after", "mini_map_hide_ms", &map_delay_labels, delay_index, !map_on, &mapDelayChanged),
    });
    var fixed_row = try container(a, .row, &.{
        text("Keep desktop icons in place", 13, false),
        .{ .name = "desktop_icons_fixed", .kind = .{ .toggle = .{ .on = cfg.desktop_icons_fixed, .owner = cc, .on_change = &fixedChanged } } },
    });
    fixed_row.justify = .space_between;
    fixed_row.@"align" = .center;
    var root = try container(a, .column, &.{
        body,
        switching,
        mini_map,
        try card(a, &.{ fixed_row, text("Keep icons fixed on screen while panning and zooming.", 12, true) }),
        text("Dragging stops on release. Edges settle with a short animation.", 12, true),
        text("Existing windows outside a smaller canvas stay reachable.", 12, true),
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
        cc.desktop.message = "Could not save. Check the configuration file and try again.";
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
        cc.desktop.message = "Could not save. Check the configuration file and try again.";
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
        cc.desktop.message = "Could not save. Check the configuration file and try again.";
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
        cc.desktop.message = "Could not save. Check the configuration file and try again.";
        cc.refresh();
        return;
    };
    cc.desktop.message = "";
    cc.server.config.compositor.canvas_columns = columns;
    cc.server.config.compositor.canvas_rows = rows;
    @import("../../Output.zig").recomputeWorldBounds(cc.server);
    cc.refresh();
}
