//! Focus: focusing windows and surfaces, raising transients, focus cycling, the peek target and hover.

const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const events = @import("../ipc/events.zig");
const anim = @import("ui").anim;
const World = @import("../World.zig");

pub fn focus(world: *World, toplevel: *Toplevel) void {
    world.focusSurface(toplevel, toplevel.surface());
}

/// True when `surface` is `toplevel_surface` itself, or an xdg_popup whose
/// chain of `xdg_popup.parent` links leads back to it. Deliberately narrower
/// than `Toplevel.fromSurface`: that helper also climbs a plain transient
/// dialog's X11/xdg parent to identify *its own* owning toplevel, which is
/// the right answer for "what toplevel is this," but the wrong one here — a
/// dialog being unmapped must not be mistaken for a popup of its owner.
pub fn isSurfaceOrOwnPopupOf(surface: *wlr.Surface, toplevel_surface: *wlr.Surface) bool {
    var current = surface;
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        if (current == toplevel_surface) return true;
        const xdg_surface = wlr.XdgSurface.tryFromWlrSurface(current) orelse return false;
        if (xdg_surface.role != .popup) return false;
        const popup = xdg_surface.role_data.popup orelse return false;
        current = popup.parent orelse return false;
    }
    return false;
}

/// Raise `toplevel` and give keyboard focus to `surface` (a popup or
/// subsurface, or the window's own surface when null).
pub fn focusSurface(world: *World, toplevel: *Toplevel, surface: ?*wlr.Surface) void {
    if (world.server.locker != null or world.server.polkit_dialog != null) return;
    world.overview.cancel(world);
    // Only windows in the stack can be raised; the reorder below needs the link.
    if (!toplevel.in_world) return;
    world.workspaces.reveal(toplevel);
    if (!@import("../workspaces.zig").visible(toplevel)) return;
    world.workspaces.rememberFocus(toplevel);
    world.server.window_tabs.focusMember(toplevel);
    var boosted = world.toplevels.iterator(.forward);
    while (boosted.next()) |previous| {
        if (previous != toplevel) previous.setZoomBoost(false);
    }
    toplevel.setUrgent(false);
    const seat = world.server.input.seat;
    const enter = surface orelse toplevel.surface();
    if (seat.keyboard_state.focused_surface) |previous_surface| {
        if (enter) |next| {
            if (previous_surface == next) {
                return;
            }
        }
        // Already the active window: a click or hover landing on one of ITS
        // OWN other surfaces (most commonly an xdg_popup menu) must not raise
        // it again, reactivate it, or move wl_keyboard focus onto that
        // surface. Toolkits (confirmed with both Brave and GTK/Firefox) treat
        // their own wl_keyboard.leave as "my window was deactivated" and
        // immediately cancel any open popup grab in response — even though
        // the very next event is wl_keyboard.enter for their own popup —
        // which silently swallows the click that triggered this call. The
        // client already routes key input to its own open popup internally,
        // so leaving keyboard focus exactly where it is costs nothing real.
        if (toplevel.surface()) |own_surface| {
            if (isSurfaceOrOwnPopupOf(previous_surface, own_surface)) {
                return;
            }
        }
        // Deactivate the previous window through its backend, including when
        // keyboard focus is leaving a popup belonging to a different app.
        if (Toplevel.fromSurface(world.server, previous_surface)) |prev| {
            if (prev != toplevel) prev.setActivated(false);
        }
    }
    // A compositor-drawn window holds focus without a wl_surface, so the
    // seat has nothing to leave: deactivate it through the stack instead.
    if (world.toplevels.first()) |previous| {
        if (previous != toplevel and previous.backend == .shell) previous.setActivated(false);
    }

    toplevel.raise();
    world.raiseTransientChildren(toplevel);
    toplevel.link.remove();
    world.toplevels.prepend(toplevel);

    // Record focus change for undo. The previous focus id is the window that
    // was at the top of the stack before we prepended `toplevel`. The
    // re-entrancy guard makes this a no-op when undo apply calls world.focus().
    {
        const prev_id: ?u64 = blk: {
            var it = world.toplevels.iterator(.forward);
            // toplevels.first() is now `toplevel` itself; second is the prev.
            _ = it.next(); // skip the just-prepended one
            break :blk if (it.next()) |prev| prev.id else null;
        };
        if (prev_id) |pid| {
            if (pid != toplevel.id) {
                const now_ms = Server.undoNowMs();
                world.server.undo.record(.{
                    .kind = .focus,
                    .press_seq = world.server.undo.press_seq,
                    .at_ms = now_ms,
                    .focus = pid,
                }, now_ms);
            }
        }
    }

    toplevel.setActivated(true);

    @import("../config_runtime/apply.zig").applyInactiveOpacity(world.server);
    world.server.refreshTaskbars();

    if (world.server.ipc) |ipc| {
        events.onWindowFocused(ipc, toplevel.id);
        ipc.wait_mgr.checkAll();
    }

    const next = enter orelse {
        if (world.server.desktop) |desktop| desktop.yieldKeyboard();
        seat.keyboardClearFocus();
        return;
    };
    @import("../Keyboard.zig").enter(world.server, next);
}

/// A transient dialog must stay above its owner even when the owner itself
/// is the one being raised/focused (clicking a taskbar chip, alt-tab, etc.),
/// not just when the dialog is mapped or clicked directly.
pub fn raiseTransientChildren(world: *World, owner: *Toplevel) void {
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |candidate| {
        if (candidate.in_world and @import("../workspaces.zig").visible(candidate) and !candidate.minimized and candidate.owner() == owner) {
            candidate.raise();
        }
    }
}

pub fn cycleFocus(world: *World) void {
    if (world.toplevels.length() < 2) return;
    var it = world.toplevels.iterator(.reverse);
    const toplevel = while (it.next()) |candidate| {
        if (!candidate.tab_hidden and @import("../workspaces.zig").visible(candidate)) break candidate;
    } else return;
    if (toplevel == world.toplevels.first()) return;
    if (toplevel.minimized) {
        toplevel.restore();
    } else {
        world.focus(toplevel);
    }
    if (world.server.getDefaultOutput()) |output| {
        world.navigateTo(toplevel, output);
    }
}

pub fn cycleFocusPrev(world: *World) void {
    if (world.toplevels.length() < 2) return;
    const current = world.toplevels.first() orelse return;
    var it = world.toplevels.iterator(.forward);
    const toplevel = while (it.next()) |candidate| {
        if (candidate != current and !candidate.tab_hidden and @import("../workspaces.zig").visible(candidate)) break candidate;
    } else return;
    current.link.remove();
    world.toplevels.append(current);
    if (toplevel.minimized) {
        toplevel.restore();
    } else {
        world.focus(toplevel);
    }
    if (world.server.getDefaultOutput()) |output| {
        world.navigateTo(toplevel, output);
    }
}

/// Latch the selected chip until Super is released, allowing pointer interaction
/// after leaving the taskbar. Also called from input events so a quick release
/// and re-press between frames cannot retain the previous preview.
pub fn peekTarget(world: *World) ?*Toplevel {
    if (world.workspaces.active or world.overview.active()) return null;
    const input = &world.server.input;
    var held = false;
    var keyboards = input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| {
        if (keyboard.device.toKeyboard().getModifiers().logo) held = true;
    }
    if (!held or input.window_menu.node != null or (world.server.locker != null or world.server.polkit_dialog != null)) {
        world.peek_window_id = null;
        return null;
    }
    if (input.hovered_taskbar) |bar| {
        if (bar.hover_target == .chip) {
            var it = world.toplevels.iterator(.forward);
            while (it.next()) |toplevel| {
                if (toplevel == bar.hover_target.chip) {
                    world.peek_window_id = if (toplevel.minimized) null else toplevel.id;
                    break;
                }
            }
        }
    }
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (world.peek_window_id == toplevel.id and !toplevel.minimized) return toplevel;
    }
    world.peek_window_id = null;
    return null;
}

pub fn tickHover(world: *World, now_ms: i64) bool {
    var animating = false;
    if (world.tickCamera(now_ms)) animating = true;
    const target = world.peekTarget();
    const focused = @import("../ipc/handlers.zig").findFocusedToplevel(world.server);
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (focused != toplevel) toplevel.setZoomBoost(false);
        if (toplevel.tickHover(now_ms)) animating = true;
        if (toplevel.tickGlow(now_ms)) animating = true;
        if (toplevel.tickZoom(now_ms)) animating = true;
        if (toplevel.tickZoomBoost(now_ms)) animating = true;
        if (toplevel.tickDragLift(now_ms)) animating = true;
        if (toplevel.tickMap(now_ms)) animating = true;
        if (toplevel.tickMove(now_ms)) animating = true;
        if (toplevel.tickDodge(now_ms)) animating = true;
        if (toplevel.tickSwitch(now_ms)) animating = true;
        if (toplevel.tickSize(now_ms)) animating = true;
        toplevel.applyVisualTransform(now_ms);
        if (target == null and toplevel.peek_mix.to != 0) {
            const level = toplevel.peek_level.value(now_ms);
            toplevel.peek_level = .{ .from = level, .to = level, .property = .opacity };
        }
        const mix: f32 = if (target != null) 1 else 0;
        if (toplevel.peek_mix.to != mix) toplevel.peek_mix.retargetTo(now_ms, mix, anim.curveFor(.window_peek));
        // Keep the previous level during release so the return starts at the
        // exact currently displayed opacity, including mid-transition release.
        if (target) |selected| {
            if (toplevel == selected) {
                // The interactive preview stays at 90% opacity, including
                // switching from a dimmed window or a configured opacity rule.
                toplevel.peek_mix = .{ .from = 1, .to = 1, .property = .opacity };
                toplevel.peek_level = .{ .from = 0.9, .to = 0.9, .property = .opacity };
            }
            const level: f32 = if (toplevel == selected) 0.9 else 0.2;
            if (toplevel.peek_level.to != level) toplevel.peek_level.retargetTo(now_ms, level, anim.curveFor(.window_peek));
        }
        toplevel.applyOpacity(now_ms);
        if (toplevel.dimAnimating(now_ms)) animating = true;
        _ = toplevel.peek_mix.sampleChanged(now_ms, anim.quantum_alpha);
        _ = toplevel.peek_level.sampleChanged(now_ms, anim.quantum_alpha);
        if (!toplevel.peek_mix.settled(now_ms) or !toplevel.peek_level.settled(now_ms)) animating = true;
    }

    if (world.overview.update(world, now_ms)) animating = true;

    var close_it = world.closing.iterator(.forward);
    while (close_it.next()) |toplevel| {
        const still = toplevel.tickMap(now_ms);
        toplevel.applyVisualTransform(now_ms);
        toplevel.applyOpacity(now_ms);
        if (toplevel.closingFinished(now_ms)) {
            toplevel.finishClose();
        } else if (still) {
            animating = true;
        }
    }
    return animating;
}
