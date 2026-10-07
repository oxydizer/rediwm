// Authoritative window geometry and the shared desktop camera. Source nodes
// remain in world coordinates under a disabled tree. projection.c maintains
// the displayed tree between wallpaper and output-local shell UI.
const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const events = @import("ipc/events.zig");
pub const camera_mod = @import("camera.zig");

const World = @This();
const Projection = @import("projection.zig").Projection;
const glass = @import("glass.zig");
const anim = @import("ui").anim;

server: *Server,
tree: *wlr.SceneTree,
projection: *Projection,
/// Mapped windows, front of the list is the focused/top of the stack.
toplevels: wl.list.Head(Toplevel, .link) = undefined,
/// Unmapped windows whose close animation still owns a scene tree.
closing: wl.list.Head(Toplevel, .closing_link) = undefined,
camera: camera_mod.Camera = .{},
bounds: camera_mod.Bounds = .{},
mini_map: @import("mini_map.zig") = .{},
camera_event_pending: bool = false,
pan_x: anim.Anim = .{},
pan_y: anim.Anim = .{},
pan_target: anim.Target = .camera_pan,
zoom_anim: anim.Anim = .{ .from = 1, .to = 1 },
/// Layout-space zoom anchor, captured once at gesture start.
zoom_anchor: camera_mod.Vec = .{ .x = 0, .y = 0 },
/// World-space point that stays under `zoom_anchor` while zoom animates.
zoom_world: camera_mod.Vec = .{ .x = 0, .y = 0 },
zoom_keeps_anchor: bool = false,
/// True while a Super/middle-button pan is driving the offset 1:1.
panning: bool = false,
/// Unconstrained pan offset; rubber-banded into `camera.offset_*` while held.
pan_raw_x: f64 = 0,
pan_raw_y: f64 = 0,
/// True while a touchpad pinch is driving zoom 1:1.
pinching: bool = false,
pinch_start_zoom: f64 = 1,
pinch_start_index: usize = 0,
pinch_start_target: f64 = 1,
zoom_raw: f64 = 1,
vel_z: anim.VelocityTracker = .{},
/// Last chip selected during the current Super hold; IDs survive window teardown safely.
peek_window_id: ?u64 = null,

pub fn init(world: *World, server: *Server, tree: *wlr.SceneTree, view: *wlr.SceneTree) !void {
    world.* = .{
        .server = server,
        .tree = tree,
        .projection = Projection.create(tree, view, server.scene) orelse return error.SceneCreateFailed,
    };
    world.toplevels.init();
    world.closing.init();
}

pub fn focus(world: *World, toplevel: *Toplevel) void {
    world.focusSurface(toplevel, toplevel.surface());
}

/// True when `surface` is `toplevel_surface` itself, or an xdg_popup whose
/// chain of `xdg_popup.parent` links leads back to it. Deliberately narrower
/// than `Toplevel.fromSurface`: that helper also climbs a plain transient
/// dialog's X11/xdg parent to identify *its own* owning toplevel, which is
/// the right answer for "what toplevel is this," but the wrong one here — a
/// dialog being unmapped must not be mistaken for a popup of its owner.
fn isSurfaceOrOwnPopupOf(surface: *wlr.Surface, toplevel_surface: *wlr.Surface) bool {
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
    // Only windows in the stack can be raised; the reorder below needs the link.
    if (!toplevel.in_world) return;
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

    @import("config_runtime/apply.zig").applyInactiveOpacity(world.server);
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
    @import("Keyboard.zig").enter(world.server, next);
}

/// A transient dialog must stay above its owner even when the owner itself
/// is the one being raised/focused (clicking a taskbar chip, alt-tab, etc.),
/// not just when the dialog is mapped or clicked directly.
fn raiseTransientChildren(world: *World, owner: *Toplevel) void {
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |candidate| {
        if (candidate.in_world and !candidate.minimized and candidate.owner() == owner) {
            candidate.raise();
        }
    }
}

pub fn cycleFocus(world: *World) void {
    if (world.toplevels.length() < 2) return;
    var it = world.toplevels.iterator(.reverse);
    const toplevel = while (it.next()) |candidate| {
        if (!candidate.tab_hidden) break candidate;
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
        if (candidate != current and !candidate.tab_hidden) break candidate;
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
    const input = &world.server.input;
    var held = false;
    var keyboards = input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| {
        if (keyboard.device.toKeyboard().getModifiers().logo) held = true;
    }
    if (!held or input.window_menu.target != null or (world.server.locker != null or world.server.polkit_dialog != null)) {
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
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(world.server);
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (focused != toplevel) toplevel.setZoomBoost(false);
        if (toplevel.tickHover(now_ms)) animating = true;
        if (toplevel.tickZoom(now_ms)) animating = true;
        if (toplevel.tickZoomBoost(now_ms)) animating = true;
        if (toplevel.tickMap(now_ms)) animating = true;
        if (toplevel.tickMove(now_ms)) animating = true;
        if (toplevel.tickDodge(now_ms)) animating = true;
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
        _ = toplevel.peek_mix.sampleChanged(now_ms, anim.quantum_alpha);
        _ = toplevel.peek_level.sampleChanged(now_ms, anim.quantum_alpha);
        if (!toplevel.peek_mix.settled(now_ms) or !toplevel.peek_level.settled(now_ms)) animating = true;
    }

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

/// Windows whose backend is still alive are freed later by its destroy signal.
pub fn destroyClosing(world: *World) void {
    while (world.closing.first()) |toplevel| {
        toplevel.finishClose();
    }
}

/// Compute and store camera bounds from the combined output layout rectangle.
pub fn initBounds(world: *World, layout_x: i32, layout_y: i32, layout_w: i32, layout_h: i32) void {
    world.bounds = camera_mod.computeGridBounds(layout_x, layout_y, layout_w, layout_h, world.server.config.compositor.canvas_columns, world.server.config.compositor.canvas_rows);
}

/// Project the world without changing source nodes or client geometry.
pub fn applyCamera(world: *World) void {
    if (!world.allowsOverscroll()) {
        world.camera.clamp(world.bounds);
    }
    // Input updates the authoritative camera immediately. Presentation is
    // synchronized at the output frame (or before a hit test that needs it),
    // so high-rate pan events do not repeatedly walk and damage the scene.
    world.camera_event_pending = true;
    world.server.scheduleFrames();
    if (world.server.idle) |im| {
        im.recheckInhibitors();
    }
}

fn allowsOverscroll(world: *const World) bool {
    return world.panning or world.pan_x.active() or world.pan_y.active();
}

/// True while the camera is being dragged or its springs/fling are in flight.
/// Glass holds every backdrop for that interval and refreshes on the settle frame.
pub fn holdingGlass(world: *const World) bool {
    return world.panning or world.pinching or world.pan_x.active() or world.pan_y.active() or world.zoom_anim.active();
}

/// Analytic camera at `now_ms`, for IPC. Presentation still uses `world.camera`
/// as written by the last tick / gesture.
pub fn sampledCamera(world: *const World, now_ms: i64) camera_mod.Camera {
    var cam = world.camera;
    if (world.panning or world.pinching) return cam;
    if (world.zoom_anim.active()) {
        const z: f64 = @min(cam.zoom_limit, world.zoom_anim.value(now_ms));
        cam.zoom_value = z;
        if (world.zoom_keeps_anchor) {
            cam.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
        }
    }
    if (!world.zoom_keeps_anchor) {
        if (world.pan_x.active()) cam.offset_x = world.pan_x.value(now_ms);
        if (world.pan_y.active()) cam.offset_y = world.pan_y.value(now_ms);
    }
    return cam;
}

/// At most one camera event per output frame, even with high-rate input.
pub fn flushCameraEvent(world: *World) void {
    if (!world.camera_event_pending) return;
    world.camera_event_pending = false;
    // Panning moves windows between outputs without moving them in the world.
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| toplevel.syncForeign();
    const offset = camera_mod.appliedOffset(world.camera);
    if (world.server.ipc) |ipc| {
        const max_xi: i32 = @intFromFloat(world.bounds.max_x);
        const max_yi: i32 = @intFromFloat(world.bounds.max_y);
        events.onCameraChanged(ipc, offset.x, offset.y, max_xi, max_yi, world.camera.targetPercent());
    }
}

/// Use the same visibility threshold as window navigation. A focused window
/// showing only a sliver should be revealed by its taskbar button, not minimized.
pub fn isWindowVisible(world: *World, toplevel: *Toplevel, output: *@import("Output.zig")) bool {
    return toplevel.frame_tree.node.enabled and toplevel.chrome_width > 0 and toplevel.chrome_height > 0 and
        world.windowFocusOffset(toplevel, output, world.camera, toplevel.worldScale(), false) == null;
}

/// Reveal `toplevel` on `output` if it is currently offscreen.
pub fn revealIfOffscreen(world: *World, toplevel: *Toplevel, output: *@import("Output.zig")) void {
    if (world.windowFocusOffset(toplevel, output, world.camera, toplevel.worldScale(), false)) |offset| {
        world.springPan(offset.x, offset.y, .camera_reveal);
    }
}

fn windowFocusOffset(world: *World, toplevel: *Toplevel, output: *@import("Output.zig"), cam: camera_mod.Camera, scale: f64, force: bool) ?camera_mod.Vec {
    const usable = output.usableBox();
    return camera_mod.focusOffset(cam, world.bounds, .{ .x = @floatFromInt(toplevel.x), .y = @floatFromInt(toplevel.y) }, .{ .x = @as(f64, @floatFromInt(toplevel.chrome_width)) * scale, .y = @as(f64, @floatFromInt(toplevel.chrome_height)) * scale }, .{ .x = @floatFromInt(usable.x), .y = @floatFromInt(usable.y) }, .{ .x = @floatFromInt(usable.width), .y = @floatFromInt(usable.height) }, force);
}

/// Explicit navigation (Alt+Tab, directional focus and taskbar activation).
/// Plain pointer focus does not change the zoom beneath the pointer.
pub fn navigateTo(world: *World, toplevel: *Toplevel, output: *@import("Output.zig")) void {
    if (!toplevel.in_world or toplevel.minimized) return;
    const mode = world.server.config.compositor.focus_zoom;
    const floating = toplevel.layout() == .floating and !toplevel.isFullscreen();
    toplevel.setZoomBoost(mode == .boost and floating);
    const raw = @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index])) / 100;
    const changing_camera = mode == .camera and floating and @abs(world.camera.zoom() - 1 / raw) > 1e-6;
    if (mode == .camera and floating) {
        const usable = output.usableBox();
        world.setZoomTarget(1 / raw, 0, @as(f64, @floatFromInt(usable.x)) + @as(f64, @floatFromInt(usable.width)) / 2, @as(f64, @floatFromInt(usable.y)) + @as(f64, @floatFromInt(usable.height)) / 2);
    }
    var destination = world.camera;
    destination.zoom_value = destination.targetZoom();
    const scale = if (mode == .boost and floating) 1 / destination.zoom() else raw;
    if (world.windowFocusOffset(toplevel, output, destination, scale, changing_camera)) |offset| {
        world.springPan(offset.x, offset.y, .camera_reveal);
    }
}

pub fn refreshFocusZoom(world: *World) void {
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| toplevel.setZoomBoost(false);
    if (world.server.config.compositor.focus_zoom != .camera and world.camera.focus_zoom != null) {
        world.setZoom(0, world.server.input.cursor.x, world.server.input.cursor.y);
    }
    world.server.scheduleFrames();
}

/// Expand camera bounds if necessary so that the frame at (wx, wy) with size (w, h)
/// remains reachable through camera movement.
///
/// Uses the current layout rectangle in `world.bounds` rather than looking up a
/// live output. Output destroy runs while the dying output is still in the
/// layout, so a cursor-based lookup can return a wrapper that has already been
/// freed.
pub fn ensureInBounds(world: *World, wx: i32, wy: i32, w: i32, h: i32) void {
    const ux: i32 = @intFromFloat(@round(world.bounds.origin_x));
    const uy: i32 = @intFromFloat(@round(world.bounds.origin_y));
    const uw: i32 = @intFromFloat(@round(world.bounds.width));
    const uh: i32 = @intFromFloat(@round(world.bounds.height));
    camera_mod.expandToFrame(&world.bounds, wx, wy, w, h, ux, uy, uw, uh);
}

/// Scroll the camera to bring `toplevel`'s frame into the output's usable area.
/// `output` is used for the usable-area box.
pub fn reveal(
    world: *World,
    toplevel: *Toplevel,
    output: *@import("Output.zig"),
) void {
    if (world.windowFocusOffset(toplevel, output, world.camera, toplevel.worldScale(), true)) |offset| {
        world.springPan(offset.x, offset.y, .camera_reveal);
    }
}

pub fn deinit(world: *World) void {
    world.mini_map.deinit();
    Projection.destroy(world.projection);
}
pub fn syncPresentation(world: *World) void {
    const now = anim.nowMs();
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.zoom_boost_value != 0 or world.server.config.compositor.focus_zoom == .camera) {
            toplevel.applyVisualTransform(now);
            toplevel.applyOpacity(now);
        }
        toplevel.syncOutputScale();
    }
    Projection.syncFixed(world.projection, world.camera.zoom(), world.camera.offset_x, world.camera.offset_y, world.bounds.origin_x, world.bounds.origin_y, if (world.server.config.compositor.desktop_icons_fixed) world.server.world_desktop_tree else null);
    glass.Engine.project(world.server.glass_engine, world.projection, @floatCast(world.camera.zoom()));
    if (world.server.text_input) |relay| relay.updatePopups();
    if (world.server.desktop) |desktop| desktop.syncOverlayPosition();
}
pub fn toWorld(world: *const World, x: f64, y: f64) camera_mod.Vec {
    return world.camera.toWorld(world.bounds, x, y);
}
pub fn toLayout(world: *const World, x: f64, y: f64) camera_mod.Vec {
    return world.camera.toLayout(world.bounds, x, y);
}
pub fn setZoom(world: *World, index: usize, x: f64, y: f64) void {
    const next = @min(index, camera_mod.zoom_levels.len -| 1);
    world.setZoomTarget(camera_mod.zoomAtIndex(next), next, x, y);
}

/// In camera-focus mode, zooming in continues through the distinct window
/// depths. Otherwise the ordinary desktop steps remain capped at 100%.
pub fn stepZoom(world: *World, steps: i32, x: f64, y: f64) void {
    var target = world.camera.targetZoom();
    for (0..@abs(steps)) |_| {
        var next: ?f64 = null;
        for (0..camera_mod.zoom_levels.len) |index| {
            considerZoomStep(target, camera_mod.zoomAtIndex(index), steps < 0, &next);
        }
        if (world.server.config.compositor.focus_zoom == .camera) {
            var it = world.toplevels.iterator(.forward);
            while (it.next()) |toplevel| {
                if (toplevel.tab_hidden or toplevel.layout() != .floating or toplevel.isFullscreen()) continue;
                const scale = @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index])) / 100;
                considerZoomStep(target, 1 / scale, steps < 0, &next);
            }
        }
        target = next orelse break;
    }
    world.setZoomTarget(target, camera_mod.nearestIndex(target), x, y);
}

fn considerZoomStep(current: f64, candidate: f64, inward: bool, next: *?f64) void {
    if (if (inward) candidate <= current + 1e-6 else candidate >= current - 1e-6) return;
    if (next.*) |previous| {
        if (if (inward) candidate >= previous else candidate <= previous) return;
    }
    next.* = candidate;
}

fn nearestZoom(world: *World, value: f64) f64 {
    var nearest = camera_mod.zoomAtIndex(camera_mod.nearestIndex(value));
    if (world.server.config.compositor.focus_zoom == .camera) {
        var it = world.toplevels.iterator(.forward);
        while (it.next()) |toplevel| {
            if (toplevel.tab_hidden or toplevel.layout() != .floating or toplevel.isFullscreen()) continue;
            const candidate = 100 / @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index]));
            if (@abs(candidate - value) < @abs(nearest - value)) nearest = candidate;
        }
    }
    return nearest;
}

fn setZoomTarget(world: *World, target_z: f64, next: usize, x: f64, y: f64) void {
    world.mini_map.show(world.server, x, y);
    if (world.pinching) world.endPinch(false);
    if (next == world.camera.zoom_index and !world.zoom_anim.active() and
        @abs(world.camera.zoom_value - target_z) < 1e-9)
    {
        world.showZoom(x, y);
        return;
    }

    const now_ms = anim.nowMs();

    // Record camera zoom for undo. Coalescing keeps the first snapshot within
    // 600 ms, so wheel-zooming five notches produces one undoable entry.
    {
        const cam = world.camera;
        const undo_ms = Server.undoNowMs();
        world.server.undo.record(.{
            .kind = .camera_zoom,
            .press_seq = world.server.undo.press_seq,
            .at_ms = undo_ms,
            .camera = .{ .offset_x = cam.offset_x, .offset_y = cam.offset_y, .zoom_index = cam.zoom_index, .focus_zoom = cam.focus_zoom },
        }, undo_ms);
    }

    world.camera.focus_zoom = if (target_z != camera_mod.zoomAtIndex(next)) target_z else null;
    world.camera.zoom_limit = @max(world.camera.zoom_limit, target_z);
    world.camera.zoom_index = next;

    // A live pan keeps 1:1 with the pointer; snap zoom so offset math cannot
    // fight the drag. Reduced motion / disabled animations also snap.
    if (world.panning or !anim.enabled() or anim.speed() <= 0 or anim.reducedMotion()) {
        const point = world.camera.toWorld(world.bounds, x, y);
        world.camera.placeZoom(world.bounds, target_z, point, .{ .x = x, .y = y });
        world.camera.zoom_limit = @max(1, target_z);
        world.zoom_anim.cancel(@floatCast(world.camera.zoom_value));
        world.zoom_keeps_anchor = false;
        if (world.panning) {
            world.pan_raw_x = world.camera.offset_x;
            world.pan_raw_y = world.camera.offset_y;
        }
        world.applyCamera();
        world.server.input.processCursorMotion(0);
        world.showZoom(x, y);
        return;
    }

    if (!world.zoom_anim.active() or !world.zoom_keeps_anchor) {
        world.zoom_anim = .{ .from = @floatCast(world.camera.zoom_value), .to = @floatCast(world.camera.zoom_value) };
        world.zoom_anchor = .{ .x = x, .y = y };
        world.zoom_world = world.camera.toWorld(world.bounds, x, y);
        world.zoom_keeps_anchor = true;
        world.pan_x.cancel(@floatCast(world.camera.offset_x));
        world.pan_y.cancel(@floatCast(world.camera.offset_y));
    }

    world.camera.zoom_index = next;
    world.zoom_anim.retargetTo(now_ms, @floatCast(target_z), anim.curveFor(.camera_zoom));
    if (world.zoom_anim.settled(now_ms) or !world.zoom_anim.active()) {
        world.camera.placeZoom(world.bounds, target_z, world.zoom_world, world.zoom_anchor);
        world.camera.zoom_limit = @max(1, target_z);
        world.zoom_anim.cancel(@floatCast(world.camera.zoom_value));
        world.zoom_keeps_anchor = false;
        world.applyCamera();
    } else {
        _ = world.tickCamera(now_ms);
    }
    world.server.input.processCursorMotion(0);
    world.showZoom(x, y);
}

/// Reset the camera to the origin and 100%, springing independently on each axis.
pub fn resetCamera(world: *World) void {
    world.mini_map.show(world.server, world.server.input.cursor.x, world.server.input.cursor.y);
    // Record for undo before modifying camera state.
    {
        const cam = world.camera;
        if (cam.offset_x != 0 or cam.offset_y != 0 or cam.zoom_index != 0 or cam.focus_zoom != null) {
            const undo_ms = Server.undoNowMs();
            world.server.undo.record(.{
                .kind = .camera_zoom,
                .press_seq = world.server.undo.press_seq,
                .at_ms = undo_ms,
                .camera = .{ .offset_x = cam.offset_x, .offset_y = cam.offset_y, .zoom_index = cam.zoom_index, .focus_zoom = cam.focus_zoom },
            }, undo_ms);
        }
    }
    const now_ms = anim.nowMs();
    world.panning = false;
    world.pinching = false;
    world.zoom_keeps_anchor = false;
    world.camera.zoom_index = 0;
    world.camera.focus_zoom = null;
    world.syncPanAnims();
    if (!world.zoom_anim.active()) {
        world.zoom_anim = .{ .from = @floatCast(world.camera.zoom_value), .to = @floatCast(world.camera.zoom_value) };
    }
    world.zoom_anim.retargetTo(now_ms, 1, anim.curveFor(.camera_zoom));
    world.pan_target = .camera_reveal;
    world.pan_x.retargetTo(now_ms, 0, anim.curveFor(.camera_reveal));
    world.pan_y.retargetTo(now_ms, 0, anim.curveFor(.camera_reveal));
    if ((world.zoom_anim.settled(now_ms) or !world.zoom_anim.active()) and
        (world.pan_x.settled(now_ms) or !world.pan_x.active()) and
        (world.pan_y.settled(now_ms) or !world.pan_y.active()))
    {
        world.camera = .{};
        world.zoom_anim.cancel(1);
        world.pan_x.cancel(0);
        world.pan_y.cancel(0);
        world.applyCamera();
    } else {
        _ = world.tickCamera(now_ms);
    }
    world.server.input.processCursorMotion(0);
    world.showZoom(world.server.input.cursor.x, world.server.input.cursor.y);
}

pub fn springPan(world: *World, x: f64, y: f64, target: anim.Target) void {
    world.pan_target = target;
    world.mini_map.show(world.server, world.server.input.cursor.x, world.server.input.cursor.y);
    if (world.pinching) world.endPinch(false);
    const now_ms = anim.nowMs();
    const limits = camera_mod.offsetLimits(world.bounds, world.camera.targetZoom());
    const tx = if (limits.hi_x < limits.lo_x) (limits.lo_x + limits.hi_x) / 2 else std.math.clamp(x, limits.lo_x, limits.hi_x);
    const ty = if (limits.hi_y < limits.lo_y) (limits.lo_y + limits.hi_y) / 2 else std.math.clamp(y, limits.lo_y, limits.hi_y);
    world.zoom_keeps_anchor = false;
    world.syncPanAnims();
    const curve = anim.curveFor(target);
    world.pan_x.retargetTo(now_ms, @floatCast(tx), curve);
    world.pan_y.retargetTo(now_ms, @floatCast(ty), curve);
    if ((world.pan_x.settled(now_ms) or !world.pan_x.active()) and
        (world.pan_y.settled(now_ms) or !world.pan_y.active()))
    {
        world.camera.offset_x = tx;
        world.camera.offset_y = ty;
        world.pan_x.cancel(@floatCast(tx));
        world.pan_y.cancel(@floatCast(ty));
        world.applyCamera();
    } else {
        _ = world.tickCamera(now_ms);
    }
}

pub fn beginPan(world: *World) void {
    world.mini_map.show(world.server, world.server.input.cursor.x, world.server.input.cursor.y);
    if (world.pinching) world.endPinch(false);
    world.zoom_keeps_anchor = false;
    world.finishZoomAnimation();
    const x = world.camera.offset_x;
    const y = world.camera.offset_y;
    world.pan_x.cancel(@floatCast(x));
    world.pan_y.cancel(@floatCast(y));
    world.panning = true;
    world.pan_raw_x = x;
    world.pan_raw_y = y;
}

pub fn panBy(world: *World, dx: f64, dy: f64) void {
    if (!world.panning) world.beginPan();
    _ = camera_mod.applyMotionRubber(&world.camera, dx, dy, world.bounds, &world.pan_raw_x, &world.pan_raw_y);
    world.applyCamera();
}

pub fn endPanGesture(world: *World) void {
    if (!world.panning) return;
    world.panning = false;
    // Stop where the hand releases; only animate a short return from overscroll.
    world.pan_x.cancel(@floatCast(world.camera.offset_x));
    world.pan_y.cancel(@floatCast(world.camera.offset_y));
    world.springPan(world.camera.offset_x, world.camera.offset_y, .camera_pan);
}

pub fn cancelPan(world: *World) void {
    if (!world.panning) return;
    world.panning = false;
    const x: f32 = @floatCast(world.camera.offset_x);
    const y: f32 = @floatCast(world.camera.offset_y);
    world.pan_x.cancel(x);
    world.pan_y.cancel(y);
    world.camera.clamp(world.bounds);
    world.applyCamera();
}

pub fn beginPinch(world: *World, lx: f64, ly: f64) void {
    world.mini_map.show(world.server, lx, ly);
    if (world.panning) world.endPanGesture();
    const now_ms = anim.nowMs();
    const z = world.camera.zoom();
    world.pinching = true;
    world.pinch_start_zoom = z;
    world.pinch_start_index = world.camera.zoom_index;
    world.pinch_start_target = world.camera.targetZoom();
    world.camera.zoom_limit = @max(world.camera.zoom_limit, world.zoomLimits().hi);
    world.zoom_raw = z;
    world.zoom_anchor = .{ .x = lx, .y = ly };
    world.zoom_world = world.camera.toWorld(world.bounds, lx, ly);
    world.zoom_keeps_anchor = true;
    world.zoom_anim.cancel(@floatCast(z));
    world.vel_z.reset();
    world.vel_z.push(now_ms, @floatCast(z));
}

pub fn pinchTo(world: *World, scale: f64) void {
    if (!world.pinching) return;
    const now_ms = anim.nowMs();
    const raw = world.pinch_start_zoom * @max(scale, 1e-3);
    world.zoom_raw = raw;
    const range = world.zoomLimits();
    const dim = @max(range.hi - range.lo, 0.25);
    const z = @min(world.camera.zoom_limit, camera_mod.rubberBand(raw, range.lo, range.hi, dim));
    world.camera.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
    world.vel_z.push(now_ms, @floatCast(world.camera.zoom_value));
    world.applyCamera();
    world.showZoom(world.zoom_anchor.x, world.zoom_anchor.y);
}

pub fn endPinch(world: *World, cancelled: bool) void {
    if (!world.pinching) return;
    world.pinching = false;
    const now_ms = anim.nowMs();
    const visual = world.camera.zoom_value;
    const target = if (cancelled) world.pinch_start_target else world.nearestZoom(visual);
    const idx: usize = if (cancelled) world.pinch_start_index else camera_mod.nearestIndex(target);
    world.camera.zoom_index = idx;
    world.camera.focus_zoom = if (target != camera_mod.zoomAtIndex(idx)) target else null;
    const vz = if (cancelled) 0 else world.vel_z.velocity(now_ms);
    world.zoom_keeps_anchor = true;
    world.zoom_anim = .{ .from = @floatCast(visual), .to = @floatCast(visual) };
    if (!anim.enabled() or anim.speed() <= 0 or anim.reducedMotion()) {
        world.camera.placeZoom(world.bounds, target, world.zoom_world, world.zoom_anchor);
        world.zoom_anim.cancel(@floatCast(target));
        world.zoom_keeps_anchor = false;
        world.applyCamera();
    } else {
        world.zoom_anim.retargetWith(now_ms, @floatCast(target), anim.curveFor(.camera_zoom), vz);
        if (world.zoom_anim.settled(now_ms) or !world.zoom_anim.active()) {
            world.camera.placeZoom(world.bounds, target, world.zoom_world, world.zoom_anchor);
            world.zoom_anim.cancel(@floatCast(target));
            world.zoom_keeps_anchor = false;
            world.applyCamera();
        } else {
            _ = world.tickCamera(now_ms);
        }
    }
    world.server.input.processCursorMotion(0);
    world.showZoom(world.zoom_anchor.x, world.zoom_anchor.y);
}

fn zoomLimits(world: *World) struct { lo: f64, hi: f64 } {
    const a: f64 = world.server.config.compositor.camera_zoom_min;
    const b: f64 = world.server.config.compositor.camera_zoom_max;
    var hi = @min(1, @max(a, b));
    if (world.server.config.compositor.focus_zoom == .camera) {
        var it = world.toplevels.iterator(.forward);
        while (it.next()) |toplevel| {
            if (toplevel.tab_hidden or toplevel.layout() != .floating or toplevel.isFullscreen()) continue;
            hi = @max(hi, 100 / @as(f64, @floatFromInt(camera_mod.zoom_levels[toplevel.zoom_index])));
        }
    }
    return .{ .lo = @min(1, @min(a, b)), .hi = hi };
}

pub fn snapCamera(world: *World) void {
    const x: f32 = @floatCast(world.camera.offset_x);
    const y: f32 = @floatCast(world.camera.offset_y);
    const z: f32 = @floatCast(world.camera.targetZoom());
    world.panning = false;
    world.pinching = false;
    world.zoom_keeps_anchor = false;
    world.camera.zoom_value = z;
    world.camera.zoom_limit = @max(1, z);
    world.pan_x.cancel(x);
    world.pan_y.cancel(y);
    world.zoom_anim.cancel(z);
}

fn finishZoomAnimation(world: *World) void {
    if (!world.zoom_anim.active()) {
        world.zoom_keeps_anchor = false;
        return;
    }
    const z = world.camera.targetZoom();
    world.camera.zoom_value = z;
    world.camera.zoom_limit = @max(1, z);
    if (world.zoom_keeps_anchor) {
        world.camera.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
    }
    world.zoom_anim.cancel(@floatCast(z));
    world.zoom_keeps_anchor = false;
}

fn syncPanAnims(world: *World) void {
    if (!world.pan_x.active()) {
        const x: f32 = @floatCast(world.camera.offset_x);
        world.pan_x = .{ .from = x, .to = x };
    }
    if (!world.pan_y.active()) {
        const y: f32 = @floatCast(world.camera.offset_y);
        world.pan_y = .{ .from = y, .to = y };
    }
}

pub fn tickCamera(world: *World, now_ms: i64) bool {
    var animating = false;
    var moved = false;

    if (!world.pinching and world.zoom_anim.active()) {
        _ = world.zoom_anim.sampleChanged(now_ms, 0.001);
        const target_z = world.camera.targetZoom();
        const settled = world.zoom_anim.settled(now_ms);
        const z: f64 = if (settled) target_z else @min(world.camera.zoom_limit, world.zoom_anim.value(now_ms));
        if (world.camera.zoom_value != z) {
            world.camera.zoom_value = z;
            moved = true;
        }
        if (world.zoom_keeps_anchor) {
            world.camera.placeZoom(world.bounds, z, world.zoom_world, world.zoom_anchor);
            if (world.panning) {
                world.pan_raw_x = world.camera.offset_x;
                world.pan_raw_y = world.camera.offset_y;
            }
            moved = true;
        }
        if (settled) {
            world.zoom_anim.cancel(@floatCast(target_z));
            world.camera.zoom_value = target_z;
            world.camera.zoom_limit = @max(1, target_z);
            world.zoom_keeps_anchor = false;
        } else {
            animating = true;
        }
    }

    if (!world.panning and !world.zoom_keeps_anchor) {
        const pan_x_live = world.pan_x.active();
        const pan_y_live = world.pan_y.active();
        if (tickPanAxis(&world.pan_x, &world.camera.offset_x, now_ms, true, world.bounds, world.camera.zoom())) {
            animating = true;
        }
        if (tickPanAxis(&world.pan_y, &world.camera.offset_y, now_ms, false, world.bounds, world.camera.zoom())) {
            animating = true;
        }
        if (pan_x_live or pan_y_live) moved = true;
    }

    if (moved or animating) {
        world.applyCamera();
        if (!animating) world.server.input.processCursorMotion(0);
    }
    return animating;
}

fn tickPanAxis(
    a: *anim.Anim,
    dest: *f64,
    now_ms: i64,
    is_x: bool,
    bounds: camera_mod.Bounds,
    zoom: f64,
) bool {
    if (!a.active()) return false;
    _ = a.sampleChanged(now_ms, anim.quantum_px);
    const limits = camera_mod.offsetLimits(bounds, zoom);
    const lo = if (is_x) limits.lo_x else limits.lo_y;
    const hi = if (is_x) limits.hi_x else limits.hi_y;
    var value: f64 = a.value(now_ms);
    if (a.curve == .decay) {
        if (value < lo) {
            a.retargetWith(now_ms, @floatCast(lo), anim.curveFor(.camera_pan), a.velocity(now_ms));
            value = a.value(now_ms);
        } else if (value > hi) {
            a.retargetWith(now_ms, @floatCast(hi), anim.curveFor(.camera_pan), a.velocity(now_ms));
            value = a.value(now_ms);
        }
    }
    dest.* = value;
    if (a.settled(now_ms)) {
        const rest: f64 = a.to;
        dest.* = if (rest < lo) lo else if (rest > hi) hi else rest;
        a.cancel(@floatCast(dest.*));
        return false;
    }
    return true;
}

/// Re-apply rubber-band against current bounds after a layout change mid-drag.
pub fn rebindPan(world: *World) void {
    if (!world.panning) return;
    _ = camera_mod.applyMotionRubber(&world.camera, 0, 0, world.bounds, &world.pan_raw_x, &world.pan_raw_y);
}

fn showZoom(world: *World, x: f64, y: f64) void {
    const Output = @import("Output.zig");
    const output = Output.atLayout(world.server, x, y) orelse world.server.getDefaultOutput() orelse return;
    const level = if (world.pinching) world.camera.zoom() else world.camera.targetZoom();
    @import("osd.zig").showOn(world.server, output, .{ .kind = .zoom, .level = @floatCast(level) });
}
