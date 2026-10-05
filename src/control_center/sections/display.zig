// Editable output modes, including backend-tested lower resolutions. Apply
// selections after input dispatch: a modeset rebuilds output-local trees.
const std = @import("std");
const wlr = @import("wlroots");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const theme = @import("ui").theme;
const Widget = layout.Widget;
const modes = @import("../../output_modes.zig");
const main = @import("../../main.zig");
const panel = @import("../panel.zig");
const setting_save = @import("config").setting_save;
const output_transform = @import("config").output_transform;
const Output = @import("../../Output.zig");

/// Row slots; every access goes through these so inserting a row cannot leave
/// a stale index reading a `.select` widget as `.text` (a live-session panic).
const row_monitor = 0;
const row_resolution = 1;
const row_refresh = 2;
const row_scale = 3;
const row_xwayland = 4;
const row_transform = 5;
const row_name = 6;
const row_count = 7;
const scale_labels = blk: {
    @setEvalBranchQuota(20000);
    var labels: [42][]const u8 = undefined;
    labels[0] = "Automatic";
    for (1..labels.len) |i| labels[i] = std.fmt.comptimePrint("{d}%", .{100 + (i - 1) * 5});
    break :blk labels;
};
const xwayland_labels = blk: {
    @setEvalBranchQuota(20000);
    var labels: [32][]const u8 = undefined;
    labels[0] = "Automatic";
    for (1..labels.len) |i| {
        const tenth = 10 + i - 1;
        labels[i] = std.fmt.comptimePrint("{d}.{d}×", .{ tenth / 10, tenth % 10 });
    }
    break :blk labels;
};
const LidAction = @import("config").loader.LidAction;
/// In `LidAction` order.
const lid_labels = [_][]const u8{ "Turn off screen", "Lock", "Sleep", "Do nothing" };
const transform_labels = [_][]const u8{ "Normal", "90°", "180°", "270°", "Flipped", "Flipped 90°", "Flipped 180°", "Flipped 270°" };
const row_height: f32 = 40;
const nl_temp_min: f32 = 1700;
const nl_temp_max: f32 = 10000;

pub const Section = struct {
    cc: *panel.ControlCenter = undefined,
    root: Widget = undefined,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    resolutions: []modes.Choice = &.{},
    rates: []modes.Choice = &.{},
    initial_resolution: ?usize = null,
    initial_rate: ?usize = null,
    initial_scale: ?usize = null,
    initial_xwayland_scale: ?usize = null,
    initial_transform: ?usize = null,
    monitor_labels: [][]const u8 = &.{},
    monitor_names: [][]const u8 = &.{},
    initial_monitor: ?usize = null,
    xwayland_hint: Widget = undefined,
    xwayland_hint_buf: [192]u8 = undefined,
    failed: bool = false,
    save_failed: bool = false,
    top_children: [3]Widget = undefined,
    row_storage: [row_count]Widget = undefined,
    row_children: [row_count][2]Widget = undefined,
    value_bufs: [row_count][32]u8 = undefined,
    nl_label_children: [2]Widget = undefined,
    nl_toggle_row_children: [2]Widget = undefined,
    nl_temp_header_children: [2]Widget = undefined,
    nl_temp_value_buf: [16]u8 = undefined,
    nl_temp_slider: Widget = undefined,
    nl_group_children: [3]Widget = undefined,
    /// Shown only on machines with a lid switch.
    has_lid: bool = false,
    initial_lid: ?usize = null,
    lid_row_children: [2]Widget = undefined,
    lid_group_children: [2]Widget = undefined,
    /// Display arrangement: shown while two or more displays are on.
    has_arrangement: bool = false,
    /// Output names and built positions, by arrangement item.
    arrangement_names: [][]const u8 = &.{},
    arrangement_origins: []layout.ArrangementItem = &.{},
    arrangement_items: []layout.ArrangementItem = &.{},
    arrangement_selected: ?usize = null,
    arrangement_children: [4]Widget = undefined,
    main_text_children: [2]Widget = undefined,
    main_row_children: [2]Widget = undefined,
    main_row_count: usize = 0,
    /// "Make main display" was clicked; applied after dispatch.
    make_main: bool = false,
};

fn transformFromWl(transform: anytype) output_transform.Transform {
    return switch (transform) {
        .normal => .normal,
        .@"90" => .@"90",
        .@"180" => .@"180",
        .@"270" => .@"270",
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
        else => .normal,
    };
}

fn transformIndex(transform: output_transform.Transform) usize {
    return @intFromEnum(transform);
}

fn labelWidget(text: []const u8) Widget {
    const t = panel.palette();
    return .{
        .kind = .{ .text = .{ .content = text, .font_size = 13, .weight = 600, .color = t.fg } },
        .width = .{ .flex = 1 },
    };
}

fn valueWidget(text: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = text, .font_size = 13, .color = t.dim } } };
}

fn setRow(out: *Section, index: usize, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    const value = std.fmt.bufPrint(&out.value_bufs[index], fmt, args) catch "?";
    out.row_children[index] = .{ labelWidget(label), valueWidget(value) };
    out.row_storage[index] = .{
        .kind = .container,
        .direction = .row,
        .justify = .space_between,
        .@"align" = .center,
        .height = .{ .fixed = row_height },
        .children = &out.row_children[index],
    };
}

pub fn build(out: *Section, cc: *panel.ControlCenter, wlr_output: *wlr.Output) void {
    out.cc = cc;
    _ = out.arena.reset(.free_all);
    out.resolutions = &.{};
    out.rates = &.{};
    out.initial_resolution = null;
    out.initial_rate = null;
    out.initial_transform = null;
    out.monitor_labels = &.{};
    out.monitor_names = &.{};
    out.initial_monitor = null;
    const name = std.mem.span(wlr_output.name);
    // Plain-text fallback; buildMonitors replaces it unless it bails early.
    setRow(out, row_monitor, "Monitor", "{s}", .{name});
    buildMonitors(out, name);
    if (wlr_output.current_mode) |mode| {
        setRow(out, row_resolution, "Resolution", "{d} × {d}", .{ mode.width, mode.height });
        setRow(out, row_refresh, "Refresh rate", "{d:.3} Hz", .{@as(f64, @floatFromInt(mode.refresh)) / 1000});
    } else {
        setRow(out, row_resolution, "Resolution", "{d} × {d}", .{ wlr_output.width, wlr_output.height });
        setRow(out, row_refresh, "Refresh rate", "{d:.3} Hz", .{@as(f64, @floatFromInt(wlr_output.refresh)) / 1000});
    }
    if (wlr_output.scale == @round(wlr_output.scale)) {
        setRow(out, row_scale, "Display scale", "{d}×", .{@as(i32, @intFromFloat(wlr_output.scale))});
    } else {
        setRow(out, row_scale, "Display scale", "{d:.2}×", .{wlr_output.scale});
    }
    setRow(out, row_xwayland, "Xwayland scale (global)", "", .{});
    const current_transform = transformFromWl(wlr_output.transform);
    setRow(out, row_transform, "Transform", "{s}", .{output_transform.name(current_transform)});
    setRow(out, row_name, "Output name", "{s}", .{name});
    buildScales(out, wlr_output);

    buildChoices(out, wlr_output) catch {
        out.resolutions = &.{};
        out.rates = &.{};
    };
    buildTransforms(out, current_transform);
    const pal = panel.palette();
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = "DISPLAY", .font_size = 12, .weight = 700, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.row_storage },
        .{ .kind = .{ .text = .{ .content = if (out.failed) "Could not apply that display setting." else if (out.save_failed) "Could not save the display setting." else if (wlr_output.modes.empty()) "This output does not advertise editable display modes." else "Changes are saved automatically. Scroll the lists for more modes.", .font_size = 12, .color = pal.dim } } },
    };
    out.root = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
    buildNightLight(out);
    buildLid(out);
    buildArrangement(out, name);
}

fn buildArrangement(out: *Section, selected_name: []const u8) void {
    out.has_arrangement = false;
    out.make_main = false;
    out.arrangement_selected = null;
    const server = out.cc.server;
    const allocator = out.arena.allocator();
    var count: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (arrangeable(output) != null) count += 1;
    }
    if (count < 2) return;
    out.arrangement_names = allocator.alloc([]const u8, count) catch return;
    out.arrangement_items = allocator.alloc(layout.ArrangementItem, count) catch return;
    out.arrangement_origins = allocator.alloc(layout.ArrangementItem, count) catch return;
    const primary = server.effectivePrimaryOutput();
    var selected_is_main = false;
    var index: usize = 0;
    it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const box = arrangeable(output) orelse continue;
        const name = allocator.dupe(u8, std.mem.span(output.wlr_output.name)) catch return;
        out.arrangement_names[index] = name;
        // The mode as the screen stands: a portrait screen reads tall.
        const rotated = switch (transformFromWl(output.wlr_output.transform)) {
            .@"90", .@"270", .flipped_90, .flipped_270 => true,
            else => false,
        };
        const mode_w = if (rotated) output.wlr_output.height else output.wlr_output.width;
        const mode_h = if (rotated) output.wlr_output.width else output.wlr_output.height;
        out.arrangement_items[index] = .{
            .x = box.x,
            .y = box.y,
            .width = box.width,
            .height = box.height,
            .label = name,
            .detail = std.fmt.allocPrint(allocator, "{d} × {d}", .{ mode_w, mode_h }) catch "",
            .primary = output == primary,
        };
        if (std.mem.eql(u8, name, selected_name)) {
            out.arrangement_selected = index;
            selected_is_main = output == primary;
        }
        index += 1;
    }
    @memcpy(out.arrangement_origins, out.arrangement_items);
    // A tall arrangement (stacked, or portrait screens) gets a taller canvas.
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (out.arrangement_items) |item| {
        min_x = @min(min_x, item.x);
        min_y = @min(min_y, item.y);
        max_x = @max(max_x, item.x + item.width);
        max_y = @max(max_y, item.y + item.height);
    }
    const canvas_height: f32 = if (3 * (max_y - min_y) > 2 * (max_x - min_x)) 280 else 220;

    const pal = panel.palette();
    var hint = valueWidget("Drag displays to match your desk. Click one to edit it.");
    hint.kind.text.font_size = 12;
    hint.width = .{ .flex = 1 };
    out.main_text_children = .{
        labelWidget("Main display"),
        valueWidget(if (selected_is_main) "Desktop icons appear on this display." else "Where desktop icons appear."),
    };
    out.main_text_children[1].kind.text.font_size = 12;
    out.main_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 4, .width = .{ .flex = 1 }, .children = &out.main_text_children },
        .{ .name = "make_main", .kind = .{ .button = .{ .label = "Make main display", .owner = out, .on_click = &onMakeMain } }, .height = .{ .fixed = 32 } },
    };
    // The selected display is already main: nothing to offer.
    out.main_row_count = if (selected_is_main or out.arrangement_selected == null) 1 else 2;
    out.arrangement_children = .{
        .{ .kind = .{ .text = .{ .content = "Arrangement", .font_size = 16, .weight = 600, .color = pal.fg } } },
        hint,
        .{ .name = "arrangement", .kind = .{ .arrangement = .{ .items = out.arrangement_items, .selected = out.arrangement_selected } }, .width = .{ .percent = 1 }, .height = .{ .fixed = canvas_height } },
        .{ .kind = .container, .direction = .row, .@"align" = .center, .gap = 12, .children = out.main_row_children[0..out.main_row_count] },
    };
    out.has_arrangement = true;
}

/// An output's layout box while it is on and placed.
fn arrangeable(output: *Output) ?wlr.Box {
    if (!output.isAvailable()) return null;
    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return null;
    return box;
}

fn onMakeMain(owner: ?*anyopaque, _: usize) void {
    const out: *Section = @ptrCast(@alignCast(owner orelse return));
    out.make_main = true;
}

fn arrangementData(out: *Section) ?*layout.ArrangementData {
    if (!out.has_arrangement or out.arrangement_children[2].kind != .arrangement) return null;
    return &out.arrangement_children[2].kind.arrangement;
}

/// After a drop: every display's new position, shifted so the arrangement
/// starts at 0,0 (X11 has no negative screen coordinates). Section-arena memory.
pub fn pendingArrangement(out: *Section) ?[]Output.Placement {
    const data = arrangementData(out) orelse return null;
    if (data.drag != null) return null;
    var moved = false;
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    for (data.items, out.arrangement_origins) |item, origin| {
        if (item.x != origin.x or item.y != origin.y) moved = true;
        min_x = @min(min_x, item.x);
        min_y = @min(min_y, item.y);
    }
    if (!moved) return null;
    // Once: the rebuild that follows applying it starts from the new layout.
    @memcpy(out.arrangement_origins, data.items);
    const server = out.cc.server;
    const placements = out.arena.allocator().alloc(Output.Placement, data.items.len) catch return null;
    for (data.items, out.arrangement_names, placements) |item, name, *placement| {
        placement.* = .{ .output = server.findOutputByName(name) orelse return null, .x = item.x - min_x, .y = item.y - min_y };
    }
    return placements;
}

/// The output name of a display picked in the arrangement.
pub fn pendingArrangementSelection(out: *Section) ?[]const u8 {
    const data = arrangementData(out) orelse return null;
    const selected = data.selected orelse return null;
    if (data.drag != null or selected == out.arrangement_selected or selected >= out.arrangement_names.len) return null;
    out.arrangement_selected = selected;
    return out.arrangement_names[selected];
}

pub fn pendingMakeMain(out: *Section) bool {
    defer out.make_main = false;
    return out.has_arrangement and out.make_main;
}

fn buildLid(out: *Section) void {
    const server = out.cc.server;
    out.has_lid = server.input.lid.present();
    if (!out.has_lid) return;
    const action = server.config.compositor.lid_close;
    out.initial_lid = @intFromEnum(action);
    out.lid_row_children = .{
        labelWidget("When the lid is closed"),
        .{ .name = "lid_close", .kind = .{ .select = .{ .labels = &lid_labels, .selected = out.initial_lid } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } },
    };
    var hint = valueWidget(switch (action) {
        .display_off => "The built-in screen turns off while another display is connected.",
        .lock => "Locks, and turns off the built-in screen while another display is connected.",
        .@"suspend" => "Locks and sleeps, even with another display connected.",
        .ignore => "The built-in screen stays on.",
    });
    hint.kind.text.font_size = 12;
    hint.width = .{ .flex = 1 };
    out.lid_group_children = .{
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .height = .{ .fixed = row_height }, .children = &out.lid_row_children },
        hint,
    };
}

/// Applied after dispatch: turning the built-in screen on or off rebuilds this tree.
pub fn pendingLidAction(out: *Section) ?LidAction {
    if (!out.has_lid or out.lid_row_children[1].kind != .select) return null;
    const selected = out.lid_row_children[1].kind.select.selected orelse return null;
    if (selected == out.initial_lid or selected >= lid_labels.len) return null;
    return @enumFromInt(selected);
}

fn buildMonitors(out: *Section, selected_name: []const u8) void {
    const server = out.cc.server;
    var count: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |_| count += 1;
    if (count == 0) return;
    const allocator = out.arena.allocator();
    out.monitor_labels = allocator.alloc([]const u8, count) catch return;
    out.monitor_names = allocator.alloc([]const u8, count) catch return;
    it = server.outputs.iterator(.forward);
    var index: usize = 0;
    while (it.next()) |output| {
        const output_name = std.mem.span(output.wlr_output.name);
        const copy = allocator.dupe(u8, output_name) catch return;
        out.monitor_names[index] = copy;
        out.monitor_labels[index] = copy;
        if (std.mem.eql(u8, selected_name, output_name)) out.initial_monitor = index;
        index += 1;
    }
    if (out.initial_monitor == null) out.initial_monitor = 0;
    out.row_children[row_monitor] = .{
        labelWidget("Monitor"),
        .{ .name = "monitor", .kind = .{ .select = .{ .labels = out.monitor_labels, .selected = out.initial_monitor, .owner = out, .on_change = &onMonitorChanged } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } },
    };
    out.row_storage[row_monitor] = .{
        .kind = .container,
        .direction = .row,
        .justify = .space_between,
        .@"align" = .center,
        .height = .{ .fixed = row_height },
        .children = &out.row_children[row_monitor],
    };
}

fn onMonitorChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const selected_section: *Section = @ptrCast(@alignCast(owner orelse return));
    if (index >= selected_section.monitor_names.len) return;
    const cc = selected_section.cc;
    cc.selectDisplayOutput(selected_section.monitor_names[index]);
}

fn buildScales(out: *Section, output: *wlr.Output) void {
    const server = out.cc.server;
    var configured: ?f32 = null;
    for (server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(output.name))) {
            configured = config.scale;
            break;
        }
    }
    out.initial_scale = if (configured == null) 0 else null;
    if (configured) |factor| {
        for (1..scale_labels.len) |index| {
            if (@abs(factor - scaleFactor(index)) < 0.001) out.initial_scale = index;
        }
    }
    const placeholder = out.row_children[row_scale][1].kind.text.content;
    out.row_children[row_scale][1] = .{ .name = "scale", .kind = .{ .select = .{
        .labels = &scale_labels,
        .selected = out.initial_scale,
        .placeholder = placeholder,
        .disabled = server.scale_override != null,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
    const configured_xwayland = server.config.compositor.xwayland_scale;
    out.initial_xwayland_scale = if (configured_xwayland == 0) 0 else null;
    for (1..xwayland_labels.len) |index| {
        if (@abs(configured_xwayland - xwaylandFactor(index)) < 0.0001) out.initial_xwayland_scale = index;
    }
    const xwayland_placeholder = std.fmt.bufPrint(&out.value_bufs[row_xwayland], "{d:.2}×", .{configured_xwayland}) catch "";
    out.row_children[row_xwayland][1] = .{ .name = "xwayland_scale", .kind = .{ .select = .{
        .labels = &xwayland_labels,
        .selected = out.initial_xwayland_scale,
        .placeholder = xwayland_placeholder,
        .disabled = !server.config.compositor.xwayland,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
    const hint = if (server.xwaylandScalePending()) |pending|
        std.fmt.bufPrint(&out.xwayland_hint_buf, "Xwayland: {d}× active. Restart the compositor to apply {d}×.", .{ server.xwaylandScale(), pending }) catch ""
    else
        std.fmt.bufPrint(&out.xwayland_hint_buf, "Xwayland: {d}× active. Changes require a compositor restart.", .{server.xwaylandScale()}) catch "";
    out.xwayland_hint = labelWidget(hint);
    out.xwayland_hint.kind.text.font_size = 12;
    if (server.scale_override != null) {
        out.xwayland_hint.kind.text.content = "Display scale is overridden by REDIWM_SCALE. Xwayland changes require a restart.";
    }
}

fn scaleFactor(index: usize) f32 {
    return 1 + @as(f32, @floatFromInt(index - 1)) / 20;
}

fn buildTransforms(out: *Section, current_transform: output_transform.Transform) void {
    out.initial_transform = transformIndex(current_transform);
    out.row_children[row_transform][1] = .{ .name = "transform", .kind = .{ .select = .{
        .labels = &transform_labels,
        .selected = out.initial_transform,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
}

pub fn pendingTransform(out: *Section) ?output_transform.Transform {
    if (out.row_children[row_transform][1].kind != .select) return null;
    const selected = out.row_children[row_transform][1].kind.select.selected orelse return null;
    if (selected == out.initial_transform or selected >= transform_labels.len) return null;
    return @enumFromInt(selected);
}

pub const ScaleChange = union(enum) { auto, factor: f32 };

pub fn pendingScale(out: *Section) ?ScaleChange {
    if (out.row_children[row_scale][1].kind != .select) return null;
    const selected = out.row_children[row_scale][1].kind.select.selected;
    if (selected == out.initial_scale) return null;
    const index = selected orelse return null;
    return if (index == 0) .auto else .{ .factor = scaleFactor(index) };
}

fn xwaylandFactor(index: usize) f64 {
    return @as(f64, @floatFromInt(10 + index - 1)) / 10;
}

pub fn pendingXwaylandScale(out: *Section) ?f64 {
    if (out.row_children[row_xwayland][1].kind != .select) return null;
    const selected = out.row_children[row_xwayland][1].kind.select.selected orelse return null;
    return if (selected != out.initial_xwayland_scale) (if (selected == 0) 0 else xwaylandFactor(selected)) else null;
}

fn buildNightLight(out: *Section) void {
    const t = panel.palette();
    const nl_cfg: @import("config").loader.NightLightConfig = out.cc.server.config.night_light;
    out.nl_label_children = .{
        .{ .kind = .{ .text = .{ .content = "Night light", .font_size = 13, .weight = 600, .color = t.fg } } },
        .{ .kind = .{ .text = .{ .content = "Reduce blue light with a warm tint", .font_size = 12, .color = t.dim } } },
    };
    out.nl_toggle_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.nl_label_children },
        .{ .name = "night_light", .kind = .{ .toggle = .{ .style = .settings, .on = nl_cfg.enabled, .owner = out, .on_change = &onNightLightToggled } } },
    };
    const temp_str = std.fmt.bufPrint(&out.nl_temp_value_buf, "{d} K", .{nl_cfg.temperature}) catch "5000 K";
    out.nl_temp_header_children = .{ labelWidget("Color temperature"), ui_slider.valuePill(temp_str, 13, panel.palette().dim) };
    const temp_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.nl_temp_header_children };
    out.nl_temp_slider = .{ .name = "night_light_temperature", .kind = .{ .slider = .{ .style = .settings, .value = @floatFromInt(nl_cfg.temperature), .min = nl_temp_min, .max = nl_temp_max, .step = 100, .owner = out, .on_change = &onNightLightTemperatureChanged } } };
    out.nl_group_children = .{
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.nl_toggle_row_children },
        temp_header,
        out.nl_temp_slider,
    };
}

fn onNightLightToggled(owner: ?*anyopaque, _: usize, on: bool) void {
    const server = section(owner).cc.server;
    if (server.config.night_light.enabled == on) return;
    server.config.night_light.enabled = on;
    server.night_light.reconfigure(server.config.night_light);
    setting_save.saveNightLight(main.gpa, server.io, server.config.path, "enabled", on) catch |err| {
        std.log.warn("could not save night_light enabled: {}", .{err});
    };
}

fn onNightLightTemperatureChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const server = section(owner).cc.server;
    const temp: u16 = @intFromFloat(@round(std.math.clamp(value, nl_temp_min, nl_temp_max)));
    if (server.config.night_light.temperature != temp) {
        server.config.night_light.temperature = temp;
        server.night_light.reconfigure(server.config.night_light);
        setting_save.saveNightLight(main.gpa, server.io, server.config.path, "temperature", temp) catch |err| {
            std.log.warn("could not save night_light temperature: {}", .{err});
        };
    }
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    s.nl_temp_header_children[1].kind.text.content = std.fmt.bufPrint(&s.nl_temp_value_buf, "{d} K", .{temp}) catch "";
    s.nl_temp_header_children[1].markDirty();
    if (server.input.open_control_center) |cc| cc.requestRepaint();
}

// Keep every advertised mode and any accepted lower-resolution candidates.
fn buildChoices(out: *Section, output: *wlr.Output) !void {
    const allocator = out.arena.allocator();
    var choices: std.ArrayList(modes.Choice) = .empty;
    var it = output.modes.iterator(.forward);
    while (it.next()) |mode| try choices.append(allocator, modes.Choice.fromMode(mode));
    try modes.appendCustom(allocator, &choices, output);
    const sorted = choices.items;
    const count = sorted.len;
    const resolutions = try allocator.alloc(modes.Choice, count);
    const rates = try allocator.alloc(modes.Choice, count);
    const resolution_labels = try allocator.alloc([]const u8, count);
    const rate_labels = try allocator.alloc([]const u8, count);
    var nr: usize = 0;
    var nf: usize = 0;
    std.mem.sort(modes.Choice, sorted, {}, struct {
        fn less(_: void, a: modes.Choice, b: modes.Choice) bool {
            if (a.width != b.width) return a.width > b.width;
            if (a.height != b.height) return a.height > b.height;
            return a.refresh > b.refresh;
        }
    }.less);
    for (sorted) |mode| {
        var found = false;
        for (resolutions[0..nr]) |existing| {
            if (existing.width == mode.width and existing.height == mode.height) {
                found = true;
                break;
            }
        }
        if (!found) {
            resolutions[nr] = mode;
            resolution_labels[nr] = try std.fmt.allocPrint(allocator, "{d} × {d}", .{ mode.width, mode.height });
            if (mode.width == output.width and mode.height == output.height) out.initial_resolution = nr;
            nr += 1;
        }
        if (mode.width != output.width or mode.height != output.height) continue;
        found = false;
        for (rates[0..nf]) |existing| {
            if (existing.refresh == mode.refresh) {
                found = true;
                break;
            }
        }
        if (!found) {
            rates[nf] = mode;
            rate_labels[nf] = try std.fmt.allocPrint(allocator, "{d:.3} Hz", .{@as(f64, @floatFromInt(mode.refresh)) / 1000});
            if (mode.refresh == output.refresh) out.initial_rate = nf;
            nf += 1;
        }
    }
    out.resolutions = resolutions[0..nr];
    out.rates = rates[0..nf];
    const current_resolution = out.row_children[row_resolution][1].kind.text.content;
    const current_rate = out.row_children[row_refresh][1].kind.text.content;
    out.row_children[row_resolution][1] = .{ .name = "resolution", .kind = .{ .select = .{ .labels = resolution_labels[0..nr], .selected = out.initial_resolution, .placeholder = current_resolution, .disabled = nr == 0 } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
    out.row_children[row_refresh][1] = .{ .name = "refresh_rate", .kind = .{ .select = .{ .labels = rate_labels[0..nf], .selected = out.initial_rate, .placeholder = current_rate, .disabled = nf == 0 } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
}

/// Called after dispatch, so committing a mode can safely rebuild this tree.
pub fn pendingMode(out: *Section, output: *wlr.Output) ?modes.Choice {
    if (out.row_children[row_resolution][1].kind != .select) return null;
    const resolution = out.row_children[row_resolution][1].kind.select.selected;
    if (resolution != out.initial_resolution) {
        const chosen = out.resolutions[resolution orelse return null];
        // Preserve the current refresh if possible; otherwise use the closest
        // supported rate, preferring the higher rate on a tie.
        var best = chosen;
        var it = output.modes.iterator(.forward);
        while (it.next()) |mode| {
            if (mode.width != chosen.width or mode.height != chosen.height) continue;
            const distance = @abs(@as(i64, mode.refresh) - output.refresh);
            const best_distance = @abs(@as(i64, best.refresh) - output.refresh);
            if (distance < best_distance or (distance == best_distance and mode.refresh > best.refresh)) best = modes.Choice.fromMode(mode);
        }
        return best;
    }
    const rate = out.row_children[row_refresh][1].kind.select.selected;
    if (rate != out.initial_rate) return out.rates[rate orelse return null];
    return null;
}

fn section(owner: ?*anyopaque) *Section {
    return @ptrCast(@alignCast(owner.?));
}
