//! Taskbar layout: placement on the output, bleed and relayout.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const glass = @import("../glass.zig");
const wlr = @import("wlroots");
const battery = @import("../taskbar/battery.zig");
const taskbar_items = @import("config").taskbar_items;
const shape = @import("../taskbar/shape.zig");
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const projection = @import("../projection.zig");
const log = std.log.scoped(.taskbar);
const Output = @import("../Output.zig");
const nowMs = Taskbar.nowMs;
const tray_gap = Taskbar.tray_gap;
const clock_gap = Taskbar.clock_gap;
const paint_start = Taskbar.paint_start;
const paint_chips = Taskbar.paint_chips;
const paint_tray = Taskbar.paint_tray;
const paint_clock = Taskbar.paint_clock;
const capture_label = Taskbar.capture_label;
const TrayKind = Taskbar.TrayKind;
const Bleed = Taskbar.Bleed;
const battery_width = Taskbar.battery_width;
const barHeight = Taskbar.barHeight;
const edgeGap = Taskbar.edgeGap;
const barRadius = Taskbar.barRadius;
const hasPolygon = Taskbar.hasPolygon;
const chipGap = Taskbar.chipGap;
const chipSize = Taskbar.chipSize;
const trayHit = Taskbar.trayHit;
const buttonSize = Taskbar.buttonSize;
const startButtonLeft = Taskbar.startButtonLeft;
const rightPad = Taskbar.rightPad;

/// Where the bar belongs on `output_box` under the current theme and edge.
pub fn placement(bar: *Taskbar, output_box: wlr.Box) shape.Placement {
    return shape.place(output_box, .{
        .height = barHeight(),
        .edge_gap = edgeGap(),
        .length = ui_theme.global.taskbar_length,
        .alignment = bar.server.config.compositor.taskbar_alignment,
        .radius = barRadius(),
        .top = bar.server.config.compositor.taskbar_position == .top,
    });
}

/// Fractional scale floors an output's logical size (2560 / 1.5 is 1706), so a
/// flush bar that ends there stops a device pixel short of the panel and
/// shows whatever is under it. It reaches one logical pixel further, where no
/// other output starts just past that edge: the raster would draw on it.
pub fn bleedFor(bar: *Taskbar, output_box: wlr.Box, placed: wlr.Box) Bleed {
    if (!shape.flush(output_box, placed, barRadius(), hasPolygon())) return .{};
    const out = bar.wlr_output;
    const turned = @intFromEnum(out.transform) & 1 != 0;
    const scale: f64 = out.scale;
    const device_width: f64 = @floatFromInt(if (turned) out.height else out.width);
    const device_height: f64 = @floatFromInt(if (turned) out.width else out.height);
    var bleed: Bleed = .{};
    if (device_width > @round(scale * @as(f64, @floatFromInt(output_box.width)))) bleed.x = 1;
    if (placed.y + placed.height == output_box.y + output_box.height and
        device_height > @round(scale * @as(f64, @floatFromInt(output_box.height)))) bleed.y = 1;
    if (bleed.x == 0 and bleed.y == 0) return bleed;
    const right: wlr.Box = .{ .x = output_box.x + output_box.width, .y = output_box.y, .width = 1, .height = output_box.height };
    const below: wlr.Box = .{ .x = output_box.x, .y = output_box.y + output_box.height, .width = output_box.width, .height = 1 };
    var outputs = bar.server.outputs.iterator(.forward);
    while (outputs.next()) |other| {
        if (other.wlr_output == out) continue;
        var box: wlr.Box = undefined;
        bar.server.output_layout.getBox(other.wlr_output, &box);
        if (boxesOverlap(box, right)) bleed.x = 0;
        if (boxesOverlap(box, below)) bleed.y = 0;
    }
    return bleed;
}

pub fn boxesOverlap(a: wlr.Box, b: wlr.Box) bool {
    return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height;
}

/// The polygon outline of the bar as the clip of its tree: every item, and the
/// glass behind them, is cut to it on the GPU (the projection declines a pointer
/// pick outside it too, so a notch is the window below). No clip, and no cost,
/// for the rounded or the flush bar.
pub fn applyClip(bar: *Taskbar) void {
    const text_value = ui_theme.global.taskbar_shape;
    const poly = if (hasPolygon()) shape.polygon(text_value, @floatFromInt(bar.box.width), @floatFromInt(bar.box.height)) else null;
    const found = poly orelse {
        _ = projection.setTreeClip(&bar.tree.node, null);
        return;
    };
    var spec: projection.ClipSpec = .{
        .width = bar.box.width,
        .height = bar.box.height,
        .poly_count = @intCast(found.count),
        .radii = @splat(0),
        .border = 0,
        .border_color = @splat(0),
    };
    spec.poly = found.points;
    if (!projection.setTreeClip(&bar.tree.node, spec)) log.warn("could not set the taskbar shape ({d}x{d})", .{ bar.box.width, bar.box.height });
}

/// Whether the bar already sits where `placement` puts it.
pub fn isPlaced(bar: *Taskbar, output_box: wlr.Box) bool {
    const wanted = bar.placement(output_box);
    return std.meta.eql(bar.box, wanted.box) and bar.reserved == wanted.reserved and
        std.meta.eql(bar.bleed, bar.bleedFor(output_box, wanted.box));
}

// Repositions the strip along the configured output edge.
pub fn relayout(bar: *Taskbar, output_box: wlr.Box) void {
    if (bar.server.input.window_menu.bar == bar) bar.server.input.window_menu.close();
    if (bar.server.tray) |tray_mgr| tray_mgr.closeMenu();
    bar.refreshStartLogo();
    const placed = bar.placement(output_box);
    bar.box = placed.box;
    bar.reserved = placed.reserved;
    bar.flush = shape.flush(output_box, bar.box, barRadius(), hasPolygon());
    bar.bleed = bar.bleedFor(output_box, bar.box);
    glass.Effect.configure(bar.glass_effect, barRadius(), 1);
    bar.applyClip();
    bar.tree.node.setPosition(bar.box.x, bar.box.y);
    const now_ms = nowMs();
    bar.pointerLeave();
    _ = bar.reconcile(now_ms);
    bar.app_tray_generation = 0;
    bar.background_dirty = true;
    bar.start_dirty = true;
    bar.clock_dirty = true;
    bar.tray_dirty = @splat(true);
    bar.capture_dirty = true;
    bar.battery_dirty = true;
    for (bar.chips.items) |*chip| chip.dirty = true;
    bar.render(now_ms, paint_start | paint_chips | paint_tray | paint_clock);
    bar.scheduleClockTick();
    bar.dirty = false;
    bar.paint_causes = 0;
    if (Output.fromWlr(bar.wlr_output)) |output| if (output.wifi_popup) |popup| {
        if (bar.itemBox(.wifi) == null) output.closeWifi() else popup.refresh();
    };
    if (Output.fromWlr(bar.wlr_output)) |output| if (output.battery_popup) |popup| {
        if (bar.itemBox(.battery) == null) output.closeBattery() else popup.refresh();
    };
    // The calendar follows the clock as the bar lays its items out again.
    if (Output.fromWlr(bar.wlr_output)) |output| if (output.calendar) |calendar| calendar.refresh();
}

// Called whenever world.toplevels changes shape or order (map, unmap,
// focus) or a window's identity changes. Rebuilds the chip list, starting
// FLIP animations for chips whose on-screen position actually moved, and
// repaints only chips whose pixels would differ.
pub fn notifyToplevelsChanged(bar: *Taskbar) void {
    bar.refreshStartLogo();
    if (bar.server.tray) |tray_mgr| {
        if (bar.app_tray_generation != tray_mgr.generation) bar.markDirty(paint_tray);
    }
    const chips_changed = bar.reconcile(nowMs());
    if (chips_changed) bar.markDirty(paint_chips);
    if (bar.dirty) bar.wlr_output.scheduleFrame();
}

pub fn rightLayout(bar: *Taskbar) taskbar_items.Layout {
    return bar.item_layout;
}

pub fn startX(bar: *Taskbar) i32 {
    return @intFromFloat(@round(bar.item_layout.x[@intFromEnum(taskbar_items.Item.start)] orelse @as(f32, @floatFromInt(startButtonLeft()))));
}

pub fn calculateLayout(bar: *Taskbar, window_count: usize) taskbar_items.Layout {
    const items = bar.server.config.compositor.taskbar_items.effective(bar.network_presence);
    const app_count = bar.appTrayCount();
    const app_width: f32 = @floatFromInt(app_count * @as(usize, @intCast(trayHit() + tray_gap)));
    const capture_width: f32 = if (bar.capturing()) @floatFromInt(bar.captureWidth()) else 0;
    const windows_width = if (window_count == 0) 0 else @as(f32, @floatFromInt(window_count)) * @max(@as(f32, @floatFromInt(chipSize())), ui_theme.global.chip_width) +
        @as(f32, @floatFromInt(window_count - 1)) * @as(f32, @floatFromInt(chipGap()));
    return taskbar_items.arrange(items, @floatFromInt(startButtonLeft()), @floatFromInt(bar.box.width - rightPad()), @as(f32, @floatFromInt(bar.box.width)) / 2, .{ if (bar.battery_state.percent != null) battery_width else 0, @floatFromInt(trayHit()), @floatFromInt(trayHit()), bar.clockColumnWidth(), @floatFromInt(buttonSize()), windows_width, app_width, @floatFromInt(trayHit()), capture_width, @floatFromInt(trayHit()), @floatFromInt(trayHit()) }, tray_gap, clock_gap);
}

pub fn itemBox(bar: *Taskbar, item: taskbar_items.Item) ?wlr.Box {
    const x = bar.rightLayout().x[@intFromEnum(item)] orelse return null;
    const width: i32 = @intFromFloat(@ceil(bar.item_layout.widths[@intFromEnum(item)]));
    return .{ .x = bar.box.x + @as(i32, @intFromFloat(@round(x))), .y = bar.box.y, .width = width, .height = bar.box.height };
}

pub fn batteryX(bar: *Taskbar) f32 {
    return bar.rightLayout().x[@intFromEnum(taskbar_items.Item.battery)] orelse 0;
}

pub fn clockX(bar: *Taskbar) f32 {
    return bar.rightLayout().x[@intFromEnum(taskbar_items.Item.clock)] orelse 0;
}

pub fn trayItem(index: usize) taskbar_items.Item {
    return switch (@as(TrayKind, @enumFromInt(index))) {
        .volume => .volume,
        .wifi => .wifi,
        .power => .power,
        .wired => .wired,
        .input_source => .input_source,
    };
}

pub fn itemShown(bar: *Taskbar, item: taskbar_items.Item) bool {
    return bar.server.config.compositor.taskbar_items.resolved(item, bar.network_presence) and (item != .battery or bar.battery_state.percent != null);
}

pub fn capturing(bar: *Taskbar) bool {
    if (!bar.itemShown(.capture)) return false;
    const cm = bar.server.capture_mgr orelse return false;
    return cm.activeCount() > 0;
}

pub fn captureWidth(bar: *Taskbar) i32 {
    return @max(trayHit(), bar.captureLabelWidth() + 24);
}

pub fn captureLabelWidth(bar: *Taskbar) i32 {
    const scale = bar.wlr_output.scale;
    if (bar.capture_width.get(scale)) |width| return @intFromFloat(width);
    const width = text.measureWidth(capture_label, .manrope, 12, scale) catch return 80;
    return @intFromFloat(bar.capture_width.put(scale, @floatFromInt(width)));
}

pub fn captureX(bar: *Taskbar) f32 {
    return bar.item_layout.x[@intFromEnum(taskbar_items.Item.capture)] orelse 0;
}

pub fn captureIndicatorBox(bar: *Taskbar) ?wlr.Box {
    if (!bar.capturing()) return null;
    const x = bar.captureX();
    return .{
        .x = bar.box.x + @as(i32, @intFromFloat(@round(x))),
        .y = bar.box.y + @divTrunc(bar.box.height - trayHit(), 2),
        .width = bar.captureWidth(),
        .height = trayHit(),
    };
}

pub fn sharedChipWidth(bar: *Taskbar, count: usize) f32 {
    const min_w: f32 = @floatFromInt(chipSize());
    const max_w = @max(min_w, ui_theme.global.chip_width);
    if (count == 0) return max_w;
    const available = bar.item_layout.widths[@intFromEnum(taskbar_items.Item.windows)];
    const extra_gaps: usize = if (count > 1) count - 1 else 0;
    const gap_total = @as(f32, @floatFromInt(chipGap())) * @as(f32, @floatFromInt(extra_gaps));
    const each = (available - gap_total) / @as(f32, @floatFromInt(count));
    return @max(1, @min(max_w, each));
}
