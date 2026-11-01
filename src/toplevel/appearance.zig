//! Toplevel appearance: opacity, dimming, hover, glow and the title chip.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const glass = @import("../glass.zig");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const chrome = @import("../chrome.zig");
const projection = @import("../projection.zig");
const theme = @import("ui").theme;
const actions = @import("../config_runtime/actions.zig");
const anim = @import("ui").anim;
const border_glow = @import("ui").border_glow;
const window_shape = @import("ui").window_shape;
const log = std.log.scoped(.toplevel);
const chip_slot_px = Toplevel.chip_slot_px;

pub fn detachInput(toplevel: *Toplevel) void {
    toplevel.server.input.detachToplevel(toplevel);
    toplevel.clearDragLift();
    toplevel.clearDodge();
    toplevel.clearZoomBoost();
    toplevel.peek_mix = .{};
    toplevel.peek_level = .{ .from = 1, .to = 1 };
    toplevel.hovered = false;
    toplevel.hovered_control = null;
    toplevel.hover_anim.cancel(0);
    toplevel.resetChip();
    toplevel.last_painted_hover = 0;
}

/// Blend the temporary taskbar preview over the configured window opacity.
pub fn effectiveOpacity(toplevel: *Toplevel, now_ms: i64) f32 {
    const focused = @import("../config_runtime/actions.zig").focusedToplevel(toplevel.server);
    const inactive = std.math.clamp(toplevel.server.config.compositor.inactive_opacity, 0, 1);
    const normal = (toplevel.live_rules.opacity orelse 1) * (if (toplevel == focused) @as(f32, 1) else inactive);
    const mix = toplevel.peek_mix.value(now_ms);
    return (normal * (1 - mix) + toplevel.peek_level.value(now_ms) * mix) * toplevel.cameraFocusOpacity();
}

/// 1 for a window that should show dimmed: not the focus, unless the dim is off,
/// the window is fullscreen (a video on another output stays as it is) or leaving.
pub fn dimTarget(toplevel: *Toplevel) f32 {
    const config = &toplevel.server.config.compositor;
    if (!config.inactive_dim or config.inactive_dim_amount <= 0 or toplevel.closing or toplevel.isFullscreen()) return 0;
    return if (toplevel == @import("../config_runtime/actions.zig").focusedToplevel(toplevel.server)) 0 else 1;
}

/// Takes some brightness and colour from a window that is not the focus
/// (`inactive_dim`): the output pass draws its whole frame, titlebar and ring
/// included, graded by what is set on the tree. The level eases in and out with
/// focus; a taskbar preview shows every window as it is. Popups are no part of it.
pub fn applyDim(toplevel: *Toplevel, now_ms: i64) void {
    const target = toplevel.dimTarget();
    if (toplevel.dim_anim.to != target) toplevel.dim_anim.retargetTo(now_ms, target, anim.curveFor(.window_dim));
    const level = toplevel.dim_anim.value(now_ms) * (1 - toplevel.peek_mix.value(now_ms));
    // Whole levels of an 8-bit channel: a finer step shows nothing and would only repaint.
    const amount = std.math.clamp(@round(level * toplevel.server.config.compositor.inactive_dim_amount * 255) / 255, 0, 1);
    if (amount == toplevel.dim_shown) return;
    if (!projection.setTreeDim(&toplevel.frame_tree.node, amount, amount)) {
        log.warn("could not dim window {d} by {d}", .{ toplevel.id, amount });
        return;
    }
    toplevel.dim_shown = amount;
}

/// Whether the dim is still easing, so frames keep coming until it settles.
pub fn dimAnimating(toplevel: *const Toplevel, now_ms: i64) bool {
    return !toplevel.dim_anim.settled(now_ms);
}

pub fn applyOpacity(toplevel: *Toplevel, now_ms: i64) void {
    var opacity = std.math.clamp(toplevel.effectiveOpacity(now_ms) * toplevel.map_opacity.value(now_ms) * toplevel.switch_fade.value(now_ms), 0, 1);
    toplevel.frame_tree.node.forEachBuffer(*f32, struct {
        fn iter(buffer: *sn.Buffer, _: c_int, _: c_int, value: *f32) void {
            buffer.setOpacity(value.*);
        }
    }.iter, &opacity);
    const color = toplevel.borderColor().scale(opacity);
    for (toplevel.border_rects) |rect| col.setRect(rect, color);
    for (toplevel.frame_fills) |rect| col.setRect(rect, chrome.fillColor().scale(opacity));
    toplevel.shape_opacity = opacity;
    toplevel.applyDim(now_ms);
    toplevel.applyShape();
    glass.Effect.configure(toplevel.glass_effect, toplevel.cornerRadius(), opacity);
    glass.Effect.configure(toplevel.sidebar_glass_effect, 0, opacity);
    switch (toplevel.backend) {
        .placeholder => |*ph| col.setRect(ph.body_rect, col.Straight.fromRgba(theme.global.window_bg).premultiply().scale(opacity)),
        else => {},
    }
}

pub fn applyHover(toplevel: *Toplevel, hovered: bool, control: ?chrome.ControlKind) void {
    if (!hovered and toplevel.tab_hover != 0) {
        toplevel.tab_hover = 0;
        toplevel.syncChrome(false, nowMs()) catch {};
    }
    const hover_changed = toplevel.hovered != hovered;
    const control_changed = toplevel.hovered_control != control;
    if (!hover_changed and !control_changed) return;

    toplevel.hovered = hovered;
    toplevel.hovered_control = control;
    if (hover_changed) {
        toplevel.hover_anim.retargetTo(nowMs(), if (hovered) 1 else 0, anim.curveFor(.titlebar_hover));
        toplevel.server.scheduleFrames();
    }
    if (control_changed) {
        toplevel.retargetChip(control);
        toplevel.server.scheduleFrames();
    }
    if (control_changed or !hover_changed) {
        toplevel.syncChrome(false, nowMs()) catch |err| {
            log.err("applyHover: could not update window decoration: {}", .{err});
        };
    }
}

/// The chip fades in where the pointer lands, then glides to whichever button
/// the pointer visits next; leaving every button only fades it, in place.
pub fn retargetChip(toplevel: *Toplevel, control: ?chrome.ControlKind) void {
    const now_ms = nowMs();
    const kind = control orelse {
        toplevel.chip_alpha.retargetTo(now_ms, 0, anim.curveFor(.titlebar_chip_fade));
        return;
    };
    const slot = chrome.controlSlot(kind);
    if (toplevel.chip_alpha.value(now_ms) <= 0.01) {
        toplevel.chip_pos.cancel(slot);
    } else {
        toplevel.chip_pos.retargetTo(now_ms, slot, anim.curveFor(.titlebar_chip));
    }
    toplevel.chip_alpha.retargetTo(now_ms, 1, anim.curveFor(.titlebar_chip_fade));
}

pub fn resetChip(toplevel: *Toplevel) void {
    toplevel.chip_pos.cancel(0);
    toplevel.chip_alpha.cancel(0);
}

/// The pointer's place relative to this window's frame, or null away from it
/// (`border_glow.probe`; `lx`, `ly` in layout space).
pub fn glowProbe(toplevel: *const Toplevel, lx: f64, ly: f64) ?border_glow.Probe {
    if (!chrome.shapes or !theme.global.border_glow_enabled or theme.global.border_glow[3] <= 0) return null;
    if (!toplevel.hasServerDecorations() or toplevel.isMaximized() or toplevel.isFullscreen()) return null;
    const density = toplevel.chromeDensity();
    const local = toplevel.frameLocal(lx, ly);
    const found = border_glow.probe(
        @floatFromInt(toplevel.chrome_width),
        @floatFromInt(toplevel.chrome_height),
        toplevel.cornerRadius(),
        @floatCast(local.x),
        @floatCast(local.y),
        theme.global.border_glow_reach * density,
    ) orelse return null;
    // A polygon outline: the highlight sits on the frame's bounding box, so it shows
    // only where the outline runs along it (within a few px: a shallow step still
    // lights). Where the nearest point of the box is cut away (a deep notch, a
    // slanted corner) there is no edge there to light.
    if (toplevel.shapePolygon(toplevel.chrome_width, toplevel.chrome_height)) |polygon| {
        if (@abs(window_shape.sdPolygon(polygon, found.x, found.y)) > 4 * density) return null;
    }
    return found;
}

/// Shows the highlight of the frame's edge at `probe` (null: fades it out). Only
/// a change of strength or of the whole-pixel place repaints, so a still pointer
/// costs nothing and the focused window alone ever calls this with a probe.
pub fn setGlow(toplevel: *Toplevel, probe: ?border_glow.Probe) void {
    const near: f32 = if (probe) |p| @round(p.near * 64) / 64 else 0;
    const now = nowMs();
    var changed = false;
    if (near != toplevel.glow_near) {
        toplevel.glow_near = near;
        toplevel.glow_anim.retargetTo(now, near, anim.curveFor(.titlebar_hover));
        changed = true;
    }
    if (probe) |p| {
        const x = @round(p.x);
        const y = @round(p.y);
        if (near > 0 and (x != toplevel.glow_x or y != toplevel.glow_y)) {
            toplevel.glow_x = x;
            toplevel.glow_y = y;
            changed = true;
        }
    }
    if (!changed) return;
    toplevel.applyShape();
    toplevel.server.scheduleFrames();
}

pub fn tickGlow(toplevel: *Toplevel, now_ms: i64) bool {
    if (toplevel.glow_anim.sampleChanged(now_ms, anim.rasterAlphaQuantum())) toplevel.applyShape();
    return !toplevel.glow_anim.settled(now_ms);
}

pub fn tickHover(toplevel: *Toplevel, now_ms: i64) bool {
    // Every sampler must run each frame (they track their own last value).
    const border = toplevel.hover_anim.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    const glide = toplevel.chip_pos.sampleChanged(now_ms, anim.rasterPixelQuantum(toplevel.render_scale) / chip_slot_px);
    const fade = toplevel.chip_alpha.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    if (border or glide or fade) {
        toplevel.syncChrome(false, now_ms) catch |err| {
            log.err("tickHover: could not update window decoration: {}", .{err});
        };
    }
    return !toplevel.hover_anim.settled(now_ms) or !toplevel.chip_pos.settled(now_ms) or !toplevel.chip_alpha.settled(now_ms);
}

pub fn nowMs() i64 {
    return @import("ui").anim.nowMs();
}
