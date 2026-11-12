//! Taskbar pointer: hit testing, hover, press and wheel.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const Toplevel = @import("../Toplevel.zig");
const anim = @import("ui").anim;
const battery = @import("../taskbar/battery.zig");
const start_button = @import("../taskbar/start_button.zig");
const Output = @import("../Output.zig");
const nowMs = Taskbar.nowMs;
const paint_start = Taskbar.paint_start;
const paint_chips = Taskbar.paint_chips;
const paint_tray = Taskbar.paint_tray;
const paint_hover = Taskbar.paint_hover;
const paint_press = Taskbar.paint_press;
const paint_capture = Taskbar.paint_capture;
const press_scale = Taskbar.press_scale;
const volume_scroll_step = Taskbar.volume_scroll_step;
const TrayKind = Taskbar.TrayKind;
const Target = Taskbar.Target;
const battery_width = Taskbar.battery_width;
const trayHit = Taskbar.trayHit;
const buttonSize = Taskbar.buttonSize;
const targetEql = Taskbar.targetEql;
const markPaintCauseFromTarget = Taskbar.markPaintCauseFromTarget;
const trayItem = Taskbar.trayItem;

const source_scroll_step: f32 = 60;

/// A visible chip's horizontal bounds, used to calculate a drag insertion slot.
pub const ChipSlot = struct {
    id: u64,
    x: f64,
    width: f64,
};

pub const InsertionTarget = struct {
    neighbor_id: u64,
    before: bool,
};

/// Find the visible chip immediately after the dragged chip's insertion
/// point. The dragged chip itself is excluded from the slot calculation.
pub fn insertionTarget(chips: []const ChipSlot, dragged_id: u64, x: f64) ?InsertionTarget {
    var last_id: ?u64 = null;
    for (chips) |chip| {
        if (chip.id == dragged_id) continue;
        last_id = chip.id;
        if (x < chip.x + chip.width / 2) {
            return .{ .neighbor_id = chip.id, .before = true };
        }
    }
    const id = last_id orelse return null;
    return .{ .neighbor_id = id, .before = false };
}

/// Move a dragged chip to the slot currently indicated by the pointer.
/// Persistent entries for hidden windows remain in the order.
pub fn dragMove(bar: *Taskbar, dragged_id: u64, x: f64) bool {
    const from = Taskbar.chipOrderIndex(bar.chip_order.items, dragged_id) orelse return false;
    if (bar.chip_order.items.len < 2) return false;

    const now_ms = nowMs();
    var slots: std.ArrayList(ChipSlot) = .empty;
    defer slots.deinit(@import("../main.zig").gpa);
    for (bar.chips.items) |chip| {
        slots.append(@import("../main.zig").gpa, .{
            .id = chip.toplevel.id,
            .x = chip.renderX(now_ms),
            .width = chip.width,
        }) catch return false;
    }

    const target = insertionTarget(slots.items, dragged_id, x) orelse return false;
    const neighbor_index = Taskbar.chipOrderIndex(bar.chip_order.items, target.neighbor_id) orelse return false;
    const insertion_index = neighbor_index + @intFromBool(!target.before);
    const to = if (from < insertion_index) insertion_index - 1 else insertion_index;
    if (to >= bar.chip_order.items.len or from == to) return false;

    if (!Taskbar.moveChipOrder(bar.chip_order.items, from, to)) return false;
    _ = bar.reconcile(now_ms);
    bar.server.scheduleFrames();
    bar.wlr_output.scheduleFrame();
    return true;
}

pub fn hitTest(bar: *Taskbar, sx: f64, sy: f64) Target {
    const bh = bar.box.height;
    if (sy < 0 or sy >= @as(f64, @floatFromInt(bh))) return .none;
    if (bar.itemShown(.clock) and sx >= bar.clockX() and sx < bar.clockX() + bar.clockColumnWidth()) return .clock;
    if (bar.itemShown(.battery) and sx >= bar.batteryX() and sx < bar.batteryX() + battery_width) return .battery;
    if (bar.itemShown(.start) and start_button.hitTest(sx, sy, bh, bar.startX(), buttonSize())) return .start_button;
    const now_ms = nowMs();
    for (bar.chips.items) |chip| {
        const x = chip.renderX(now_ms);
        if (sx >= x and sx < x + @as(f64, chip.width)) return .{ .chip = chip.toplevel };
    }
    const positions = bar.trayPositions();
    const ty: f64 = @floatFromInt(@divTrunc(bh - trayHit(), 2));
    if (sy >= ty and sy < ty + @as(f64, @floatFromInt(trayHit()))) {
        if (bar.capturing()) {
            const cx = bar.captureX();
            const cw: f64 = @floatFromInt(bar.captureWidth());
            if (sx >= cx and sx < cx + cw) return .capture_indicator;
        }
        for (positions, 0..) |tx, i| {
            if (!bar.itemShown(trayItem(i))) continue;
            if (sx >= tx and sx < tx + @as(f64, @floatFromInt(trayHit()))) return .{ .tray = i };
        }
    }
    return .none;
}

pub fn pointerMotion(bar: *Taskbar, sx: f64, sy: f64) void {
    const target = bar.hitTest(sx, sy);
    if (targetEql(target, bar.hover_target)) return;
    const now_ms = nowMs();
    const old = markPaintCauseFromTarget(bar.hover_target);
    bar.setHover(bar.hover_target, 0, now_ms);
    bar.setHover(target, 1, now_ms);
    const next = markPaintCauseFromTarget(target);
    bar.hover_target = target;
    _ = bar.server.world.peekTarget();
    bar.server.scheduleFrames();
    bar.markDirty(old | next | paint_hover);
    bar.wlr_output.scheduleFrame();
}

pub fn pointerLeave(bar: *Taskbar) void {
    bar.pointerMotion(-1, -1);
}

pub fn setHover(bar: *Taskbar, target: Target, to: f32, now_ms: i64) void {
    switch (target) {
        .none, .clock, .battery => {},
        .start_button => {
            bar.start.hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
            bar.start_dirty = true;
        },
        .chip => |toplevel| {
            for (bar.chips.items) |*chip| {
                if (chip.toplevel == toplevel) {
                    chip.hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
                    chip.dirty = true;
                    break;
                }
            }
        },
        .tray => |i| {
            bar.tray[i].hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
            bar.tray_dirty[i] = true;
        },
        .capture_indicator => {
            bar.capture_hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
            bar.capture_dirty = true;
        },
    }
}

fn pressChip(bar: *Taskbar, toplevel: *Toplevel) void {
    const now_ms = nowMs();
    bar.markDirty(paint_chips | paint_press);
    for (bar.chips.items) |*chip| {
        if (chip.toplevel == toplevel) {
            chip.dirty = true;
            chip.press.pulseTo(now_ms, press_scale, 1, anim.curveFor(.taskbar_press));
            break;
        }
    }
    if (Output.fromWlr(bar.wlr_output)) |output| {
        const world = &bar.server.world;
        const focused = @import("../ipc/handlers.zig").findFocusedToplevel(bar.server) == toplevel;
        if (!toplevel.minimized and focused and world.isWindowVisible(toplevel, output)) {
            toplevel.minimize();
        } else {
            if (toplevel.minimized) toplevel.restore() else world.focus(toplevel);
            world.navigateTo(toplevel, output);
        }
    }
}

/// Complete a deferred chip click by stable window ID.
pub fn pointerPressChip(bar: *Taskbar, window_id: u64) void {
    for (bar.chips.items) |chip| {
        if (chip.toplevel.id == window_id) {
            pressChip(bar, chip.toplevel);
            bar.wlr_output.scheduleFrame();
            return;
        }
    }
}

// Non-chip taskbar actions still act immediately on press.
pub fn pointerPress(bar: *Taskbar, sx: f64, sy: f64) void {
    const now_ms = nowMs();
    var did_mutate = false;
    switch (bar.hitTest(sx, sy)) {
        .none => {},
        .clock => if (Output.fromWlr(bar.wlr_output)) |output| output.toggleCalendar(),
        .battery => if (Output.fromWlr(bar.wlr_output)) |output| output.toggleBattery(),
        .start_button => {
            bar.markDirty(paint_start | paint_press);
            bar.start_dirty = true;
            did_mutate = true;
            if (Output.fromWlr(bar.wlr_output)) |output| output.toggleStartMenu();
        },
        .chip => |toplevel| {
            did_mutate = true;
            pressChip(bar, toplevel);
        },
        .tray => |i| {
            bar.markDirty(paint_tray | paint_press);
            bar.tray_dirty[i] = true;
            did_mutate = true;
            bar.tray[i].press.pulseTo(now_ms, press_scale, 1, anim.curveFor(.taskbar_press));
            if (@as(TrayKind, @enumFromInt(i)) == .wifi) {
                if (Output.fromWlr(bar.wlr_output)) |out| out.toggleWifi();
            }
            if (@as(TrayKind, @enumFromInt(i)) == .wired) {
                if (Output.fromWlr(bar.wlr_output)) |out| out.openNetworkSettings();
            }
            if (@as(TrayKind, @enumFromInt(i)) == .input_source) {
                const x = bar.box.x + @as(i32, @intFromFloat(@round(bar.trayPositions()[i])));
                bar.server.input.window_menu.openSources(bar, x);
            }
            if (@as(TrayKind, @enumFromInt(i)) == .power) {
                if (Output.fromWlr(bar.wlr_output)) |out| out.openPowerMenu();
            }
            if (@as(TrayKind, @enumFromInt(i)) == .volume) {
                if (bar.server.audio) |mgr| {
                    mgr.toggleMasterMute();
                    bar.audio_muted = mgr.isMasterMuted();
                }
            }
        },
        .capture_indicator => {
            bar.markDirty(paint_capture | paint_press);
            bar.capture_dirty = true;
            did_mutate = true;
            bar.capture_press.pulseTo(now_ms, press_scale, 1, anim.curveFor(.taskbar_press));
            if (bar.server.capture_mgr) |cm| cm.stopAll();
        },
    }
    if (did_mutate) bar.wlr_output.scheduleFrame();
}

/// Handle scrolling over volume and input-source tray items. Returns true
/// when the tray item consumes the scroll; false lets the caller handle it.
/// Volume changes by ±`volume_scroll_step` per tick; input sources cycle per
/// notch (a touchpad steps every `source_scroll_step` px).
pub fn scrollVolume(bar: *Taskbar, sx: f64, sy: f64, delta_px: f32, notch: bool) bool {
    const idx = switch (bar.hitTest(sx, sy)) {
        .tray => |i| i,
        else => return false,
    };
    if (@as(TrayKind, @enumFromInt(idx)) == .input_source) {
        const sources = bar.server.input_sources orelse return true;
        if (notch) {
            if (delta_px != 0) sources.cycle(delta_px > 0);
            return true;
        }
        bar.source_scroll += delta_px;
        while (@abs(bar.source_scroll) >= source_scroll_step) {
            sources.cycle(bar.source_scroll > 0);
            bar.source_scroll -= std.math.copysign(source_scroll_step, bar.source_scroll);
        }
        return true;
    }
    if (@as(TrayKind, @enumFromInt(idx)) != .volume) return false;
    const mgr = bar.server.audio orelse return true;
    // Natural convention: scrolling up (negative delta) raises volume.
    const direction: f32 = if (delta_px < 0) 1 else -1;
    mgr.setMasterVolume(std.math.clamp(mgr.getMasterVolume() + direction * volume_scroll_step, 0, 1));
    bar.tray_dirty[@intFromEnum(TrayKind.volume)] = true;
    bar.markDirty(paint_tray);
    bar.wlr_output.scheduleFrame();
    return true;
}
