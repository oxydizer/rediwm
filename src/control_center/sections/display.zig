const i18n = @import("i18n");
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
const vrr = @import("../../output/vrr.zig");
const hdr = @import("../../output/hdr.zig");
const scroll_tiling = @import("../../scroll_tiling.zig");
const ScrollDirection = @import("config").output_config.ScrollDirection;
const display_arrangement = @import("display_arrangement.zig");
const buildArrangement = display_arrangement.buildArrangement;
pub const pendingArrangement = display_arrangement.pendingArrangement;
pub const pendingArrangementSelection = display_arrangement.pendingArrangementSelection;
pub const pendingMakeMain = display_arrangement.pendingMakeMain;

/// Row slots; every access goes through these so inserting a row cannot leave
/// a stale index reading a `.select` widget as `.text` (a live-session panic).
const row_monitor = 0;
const row_resolution = 1;
const row_refresh = 2;
const row_scale = 3;
const row_xwayland = 4;
const row_transform = 5;
const row_adaptive_sync = 6;
const row_scroll_direction = 7;
const row_name = 8;
const row_count = 9;
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
const lid_labels = [_]i18n.Message{ i18n.msg("Turn off screen"), i18n.msg("Lock"), i18n.msg("Sleep"), i18n.msg("Power off"), i18n.msg("Do nothing") };
const transform_labels = [_]i18n.Message{ i18n.msg("Normal"), i18n.msg("90°"), i18n.msg("180°"), i18n.msg("270°"), i18n.msg("Flipped"), i18n.msg("Flipped 90°"), i18n.msg("Flipped 180°"), i18n.msg("Flipped 270°") };
/// In `AdaptiveSync` order: off, auto, always.
const adaptive_sync_labels = [_]i18n.Message{ i18n.msg("Off"), i18n.msg("Automatic"), i18n.msg("Always") };
/// In `ScrollDirection` order: auto, horizontal, vertical.
const scroll_direction_labels = [_]i18n.Message{ i18n.msg("Automatic"), i18n.msg("Horizontal"), i18n.msg("Vertical") };
/// In `hdr.Mode` order: off, on.
const hdr_labels = [_]i18n.Message{ i18n.msg("Off"), i18n.msg("On") };
/// SDR white level choices in nits (cd/m²); 203 is the BT.2408 reference white.
const sdr_white_steps = [_]f32{ 80, 100, 120, 150, 203, 250, 300, 400, 500 };
const sdr_white_labels = blk: {
    var labels: [sdr_white_steps.len][]const u8 = undefined;
    for (sdr_white_steps, 0..) |nits, i| labels[i] = std.fmt.comptimePrint("{d} cd/m²", .{nits});
    const final = labels;
    break :blk final;
};
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
    initial_adaptive_sync: ?usize = null,
    initial_scroll_direction: ?usize = null,
    /// The rows on show, `shown_rows[0..shown_row_count]`: the scrolling
    /// direction only while a workspace scrolls. Its `row_storage` slot is
    /// left unbuilt otherwise, so the page reads rows only from here.
    shown_rows: [row_count]Widget = undefined,
    shown_row_count: usize = 0,
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
    tearing_label_children: [2]Widget = undefined,
    /// The HDR card: the switch, then the white level while HDR is on and a
    /// note, on displays that can take HDR.
    hdr_row_children: [2]Widget = undefined,
    sdr_white_row_children: [2]Widget = undefined,
    hdr_rows: [3]Widget = undefined,
    hdr_row_count: usize = 0,
    initial_hdr: ?usize = null,
    initial_sdr_white: ?usize = null,
    tearing_group_children: [2]Widget = undefined,
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

pub fn transformFromWl(transform: anytype) output_transform.Transform {
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

pub fn labelWidget(text: []const u8) Widget {
    const t = panel.palette();
    return .{
        .kind = .{ .text = .{ .content = text, .font_size = 13, .weight = 600, .color = t.fg } },
        .width = .{ .flex = 1 },
    };
}

pub fn valueWidget(text: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = text, .font_size = 13, .color = t.dim } } };
}

fn setRow(out: *Section, index: usize, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    const value = std.fmt.bufPrint(&out.value_bufs[index], fmt, args) catch "?";
    out.row_children[index] = .{ labelWidget(label), valueWidget(value) };
    out.row_storage[index] = rowWidget(&out.row_children[index]);
}

fn rowWidget(children: *[2]Widget) Widget {
    return .{
        .kind = .container,
        .direction = .row,
        .justify = .space_between,
        .@"align" = .center,
        .height = .{ .fixed = row_height },
        .children = children,
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
    out.initial_adaptive_sync = null;
    out.initial_scroll_direction = null;
    out.monitor_labels = &.{};
    out.monitor_names = &.{};
    out.initial_monitor = null;
    const name = std.mem.span(wlr_output.name);
    // Plain-text fallback; buildMonitors replaces it unless it bails early.
    setRow(out, row_monitor, i18n.tr("Monitor"), "{s}", .{name});
    buildMonitors(out, name);
    if (wlr_output.current_mode) |mode| {
        setRow(out, row_resolution, i18n.tr("Resolution"), "{d} × {d}", .{ mode.width, mode.height });
        setRow(out, row_refresh, i18n.tr("Refresh rate"), "{d:.3} Hz", .{@as(f64, @floatFromInt(mode.refresh)) / 1000});
    } else {
        setRow(out, row_resolution, i18n.tr("Resolution"), "{d} × {d}", .{ wlr_output.width, wlr_output.height });
        setRow(out, row_refresh, i18n.tr("Refresh rate"), "{d:.3} Hz", .{@as(f64, @floatFromInt(wlr_output.refresh)) / 1000});
    }
    if (wlr_output.scale == @round(wlr_output.scale)) {
        setRow(out, row_scale, i18n.tr("Display scale"), "{d}×", .{@as(i32, @intFromFloat(wlr_output.scale))});
    } else {
        setRow(out, row_scale, i18n.tr("Display scale"), "{d:.2}×", .{wlr_output.scale});
    }
    setRow(out, row_xwayland, i18n.tr("Xwayland scale (global)"), "", .{});
    const current_transform = transformFromWl(wlr_output.transform);
    setRow(out, row_transform, i18n.tr("Transform"), "{s}", .{output_transform.name(current_transform)});
    setRow(out, row_adaptive_sync, i18n.tr("Variable refresh rate"), "{s}", .{i18n.tr("Not supported by this display")});
    setRow(out, row_name, i18n.tr("Output name"), "{s}", .{name});
    buildScales(out, wlr_output);

    buildChoices(out, wlr_output) catch {
        out.resolutions = &.{};
        out.rates = &.{};
    };
    buildTransforms(out, current_transform);
    const vrr_output = Output.fromWlr(wlr_output);
    if (vrr_output) |output| buildAdaptiveSync(out, output);
    var shown: usize = 0;
    for (out.row_storage, 0..) |row, index| {
        if (index == row_scroll_direction) {
            const output = vrr_output orelse continue;
            if (!scrollingInUse(out.cc)) continue;
            buildScrollDirection(out, output);
            out.shown_rows[shown] = out.row_storage[index];
        } else out.shown_rows[shown] = row;
        shown += 1;
    }
    out.shown_row_count = shown;
    buildHdr(out, vrr_output);
    const vrr_note = if (vrr_output) |output| output.vrr.needs_modeset and vrr.mode(output) == .auto else false;
    const pal = panel.palette();
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("DISPLAY"), .font_size = 12, .weight = 700, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = out.shown_rows[0..shown] },
        .{ .kind = .{ .text = .{ .content = if (out.failed) i18n.tr("Could not apply that display setting.") else if (out.save_failed) i18n.tr("Could not save the display setting.") else if (vrr_note) i18n.tr("This display changes variable refresh only with a mode switch: choose Always or Off.") else if (wlr_output.modes.empty()) i18n.tr("This output does not advertise editable display modes.") else i18n.tr("Changes are saved automatically. Scroll the lists for more modes."), .font_size = 12, .color = pal.dim } } },
    };
    out.root = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
    buildNightLight(out);
    buildTearing(out);
    buildLid(out);
    buildArrangement(out, name);
}

fn buildLid(out: *Section) void {
    const server = out.cc.server;
    out.has_lid = server.input.lid.present();
    if (!out.has_lid) return;
    const action = server.config.compositor.lid_close;
    out.initial_lid = @intFromEnum(action);
    out.lid_row_children = .{
        labelWidget(i18n.tr("When the lid is closed")),
        .{ .name = "lid_close", .kind = .{ .select = .{ .labels = panel.translatedLabels(&lid_labels), .selected = out.initial_lid } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } },
    };
    var hint = valueWidget(switch (action) {
        .display_off => i18n.tr("The built-in screen turns off while another display is connected."),
        .lock => i18n.tr("Locks, and turns off the built-in screen while another display is connected."),
        .@"suspend" => i18n.tr("Locks and sleeps, even with another display connected."),
        .power_off => i18n.tr("Powers off, even with another display connected."),
        .ignore => i18n.tr("The built-in screen stays on."),
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
        labelWidget(i18n.tr("Monitor")),
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
        i18n.fmt(&out.xwayland_hint_buf, i18n.tr("Xwayland: {active}× active. Restart the compositor to apply {pending}×."), .{ .active = server.xwaylandScale(), .pending = pending }) catch ""
    else
        i18n.fmt(&out.xwayland_hint_buf, i18n.tr("Xwayland: {active}× active. Changes require a compositor restart."), .{ .active = server.xwaylandScale() }) catch "";
    out.xwayland_hint = labelWidget(hint);
    out.xwayland_hint.kind.text.font_size = 12;
    if (server.scale_override != null) {
        out.xwayland_hint.kind.text.content = i18n.tr("REDIWM_SCALE sets scaling; restart to apply Xwayland changes.");
    }
}

fn scaleFactor(index: usize) f32 {
    return 1 + @as(f32, @floatFromInt(index - 1)) / 20;
}

fn buildTransforms(out: *Section, current_transform: output_transform.Transform) void {
    out.initial_transform = transformIndex(current_transform);
    out.row_children[row_transform][1] = .{ .name = "transform", .kind = .{ .select = .{
        .labels = panel.translatedLabels(&transform_labels),
        .selected = out.initial_transform,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
}

pub fn pendingTransform(out: *Section) ?output_transform.Transform {
    if (out.row_children[row_transform][1].kind != .select) return null;
    const selected = out.row_children[row_transform][1].kind.select.selected orelse return null;
    if (selected == out.initial_transform or selected >= transform_labels.len) return null;
    return @enumFromInt(selected);
}

fn buildAdaptiveSync(out: *Section, output: *Output) void {
    // An unsupported display keeps the text row, unless it is on anyway.
    if (!vrr.supported(output) and !vrr.active(output)) return;
    out.initial_adaptive_sync = @intFromEnum(vrr.mode(output));
    out.row_children[row_adaptive_sync][1] = .{ .name = "adaptive_sync", .kind = .{ .select = .{
        .labels = panel.translatedLabels(&adaptive_sync_labels),
        .selected = out.initial_adaptive_sync,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
}

pub fn pendingAdaptiveSync(out: *Section) ?vrr.Mode {
    if (out.row_children[row_adaptive_sync][1].kind != .select) return null;
    const selected = out.row_children[row_adaptive_sync][1].kind.select.selected orelse return null;
    if (selected == out.initial_adaptive_sync or selected >= adaptive_sync_labels.len) return null;
    return @enumFromInt(selected);
}

/// Whether any workspace lays out as a scrolling strip, or would in its mode.
fn scrollingInUse(cc: *panel.ControlCenter) bool {
    const server = cc.server;
    if (server.config.compositor.desktop_mode == .scrolling) return true;
    const spaces = &server.world.workspaces;
    if (!spaces.active) return false;
    for (spaces.slots, 1..) |slot, id| {
        if (slot.exists and spaces.layoutOf(@intCast(id)) == .scrolling) return true;
    }
    return false;
}

fn buildScrollDirection(out: *Section, output: *Output) void {
    out.initial_scroll_direction = @intFromEnum(scroll_tiling.setting(output));
    out.row_children[row_scroll_direction] = .{ labelWidget(i18n.tr("Scrolling direction")), .{ .name = "scroll_direction", .kind = .{ .select = .{
        .labels = panel.translatedLabels(&scroll_direction_labels),
        .selected = out.initial_scroll_direction,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } } };
    out.row_storage[row_scroll_direction] = rowWidget(&out.row_children[row_scroll_direction]);
}

pub fn pendingScrollDirection(out: *Section) ?ScrollDirection {
    if (out.initial_scroll_direction == null or out.row_children[row_scroll_direction][1].kind != .select) return null;
    const selected = out.row_children[row_scroll_direction][1].kind.select.selected orelse return null;
    if (selected == out.initial_scroll_direction or selected >= scroll_direction_labels.len) return null;
    return @enumFromInt(selected);
}

fn buildHdr(out: *Section, maybe_output: ?*Output) void {
    out.initial_hdr = null;
    out.initial_sdr_white = null;
    out.hdr_row_children = .{ labelWidget(i18n.tr("HDR")), valueWidget(i18n.tr("Not supported by this display")) };
    out.hdr_rows[0] = rowWidget(&out.hdr_row_children);
    out.hdr_row_count = 1;
    const output = maybe_output orelse return;
    // An unsupported display keeps the text row, unless HDR is on anyway.
    if (!hdr.supported(output) and !hdr.active(output)) return;
    const mode = hdr.mode(output);
    out.initial_hdr = @intFromEnum(mode);
    out.hdr_row_children[1] = .{ .name = "hdr", .kind = .{ .select = .{
        .labels = panel.translatedLabels(&hdr_labels),
        .selected = out.initial_hdr,
    } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } };
    if (mode == .on) {
        out.initial_sdr_white = nearestSdrWhite(hdr.sdrWhite(output));
        out.sdr_white_row_children = .{ labelWidget(i18n.tr("SDR brightness")), .{ .name = "sdr_white", .kind = .{ .select = .{
            .labels = &sdr_white_labels,
            .selected = out.initial_sdr_white,
        } }, .width = .{ .fixed = 190 }, .height = .{ .fixed = row_height } } };
        out.hdr_rows[out.hdr_row_count] = rowWidget(&out.sdr_white_row_children);
        out.hdr_row_count += 1;
    }
    // Report driver refusal, or explain the remaining experimental status.
    out.hdr_rows[out.hdr_row_count] = .{ .kind = .{ .text = .{
        .content = if (mode == .on and hdr.refused(output))
            i18n.tr("This display or its driver did not accept HDR in this mode, so it stays SDR.")
        else
            i18n.tr("HDR is experimental."),
        .font_size = 12,
        .color = panel.palette().dim,
    } } };
    out.hdr_row_count += 1;
}

fn nearestSdrWhite(nits: f32) usize {
    var best: usize = 0;
    for (sdr_white_steps, 0..) |step, i| {
        if (@abs(step - nits) < @abs(sdr_white_steps[best] - nits)) best = i;
    }
    return best;
}

pub fn pendingHdr(out: *Section) ?hdr.Mode {
    if (out.hdr_row_children[1].kind != .select) return null;
    const selected = out.hdr_row_children[1].kind.select.selected orelse return null;
    if (selected == out.initial_hdr or selected >= hdr_labels.len) return null;
    return @enumFromInt(selected);
}

/// Nits.
pub fn pendingSdrWhite(out: *Section) ?f32 {
    if (out.initial_sdr_white == null or out.sdr_white_row_children[1].kind != .select) return null;
    const selected = out.sdr_white_row_children[1].kind.select.selected orelse return null;
    if (selected == out.initial_sdr_white or selected >= sdr_white_steps.len) return null;
    return sdr_white_steps[selected];
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
        .{ .kind = .{ .text = .{ .content = i18n.tr("Night light"), .font_size = 13, .weight = 600, .color = t.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Reduce blue light with a warm tint"), .font_size = 12, .color = t.dim } } },
    };
    out.nl_toggle_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.nl_label_children },
        .{ .name = "night_light", .kind = .{ .toggle = .{ .style = .settings, .on = nl_cfg.enabled, .owner = out, .on_change = &onNightLightToggled } } },
    };
    const temp_str = std.fmt.bufPrint(&out.nl_temp_value_buf, "{d} K", .{nl_cfg.temperature}) catch "5000 K";
    out.nl_temp_header_children = .{ labelWidget(i18n.tr("Color temperature")), ui_slider.valuePill(temp_str, 13, panel.palette().dim) };
    const temp_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.nl_temp_header_children };
    out.nl_temp_slider = .{ .name = "night_light_temperature", .kind = .{ .slider = .{ .style = .settings, .value = @floatFromInt(nl_cfg.temperature), .min = nl_temp_min, .max = nl_temp_max, .step = 100, .owner = out, .on_change = &onNightLightTemperatureChanged } } };
    out.nl_group_children = .{
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.nl_toggle_row_children },
        temp_header,
        out.nl_temp_slider,
    };
}

fn buildTearing(out: *Section) void {
    const t = panel.palette();
    out.tearing_label_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("Allow tearing in games"), .font_size = 13, .weight = 600, .color = t.fg } } },
        .{ .kind = .{ .text = .{ .content = i18n.tr("Fullscreen games with VSync off show new frames at once; the picture may tear"), .font_size = 12, .color = t.dim } } },
    };
    out.tearing_group_children = .{
        .{ .kind = .container, .direction = .column, .gap = 2, .width = .{ .flex = 1 }, .children = &out.tearing_label_children },
        .{ .name = "allow_tearing", .kind = .{ .toggle = .{ .style = .settings, .on = out.cc.server.config.compositor.allow_tearing, .owner = out, .on_change = &onTearingToggled } } },
    };
}

fn onTearingToggled(owner: ?*anyopaque, _: usize, on: bool) void {
    const out = section(owner);
    const server = out.cc.server;
    if (server.config.compositor.allow_tearing == on) return;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "allow_tearing", on) catch |err| {
        std.log.warn("could not save allow_tearing: {}", .{err});
        out.tearing_group_children[1].kind.toggle.on = server.config.compositor.allow_tearing;
        out.tearing_group_children[1].markDirty();
        return;
    };
    server.config.compositor.allow_tearing = on;
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
