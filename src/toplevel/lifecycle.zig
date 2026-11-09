//! Toplevel lifecycle: commit, map, unmap and destruction.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const wlr = @import("wlroots");
const events = @import("../ipc/events.zig");
const xdg = @import("../xdg.zig");
const gpa = @import("../main.zig").gpa;
const window_rules = @import("config").window_rules;
const anim = @import("ui").anim;
const window_sizes = @import("../window_sizes.zig");
const log = std.log.scoped(.toplevel);
const nowMs = Toplevel.nowMs;
const pickInitialPlacement = Toplevel.pickInitialPlacement;

pub fn handleSurfaceCommit(toplevel: *Toplevel) void {
    if (toplevel.server.config.compositor.allow_tearing) {
        if (toplevel.currentOutput()) |output| output.queueTearing();
    }
    toplevel.server.switcher.committed(toplevel);
    if (toplevel.kde_decoration) |decoration| decoration.commit();
    if (toplevel.decoration) |decoration| decoration.applyMode();

    if (toplevel.size_wait == .x11_commit or toplevel.configureCompleted(toplevel.size_wait)) toplevel.size_wait = .none;
    if (toplevel.server.input.resize_session) |*session| {
        if (session.toplevel == toplevel) {
            if (session.outstanding_configure == .x11_commit) {
                session.outstanding_configure = .none;
            } else if (session.outstanding_configure != .none) {
                if (toplevel.configureCompleted(session.outstanding_configure)) {
                    session.outstanding_configure = .none;
                }
            }

            toplevel.positionDuringResize();

            // An acknowledgement can carry no pixel damage. Pending resize
            // work of the flame (following the pointer, or left over once it
            // has faded away) still needs a frame; plain resizes already
            // scheduled theirs, so with the effect off nothing changes.
            if (@import("../effects/window_move.zig").resizeEnabled(toplevel.server) and session.dirty and session.outstanding_configure == .none) {
                if (session.pacing_output) |output| output.wlr_output.scheduleFrame() else toplevel.server.scheduleFrames();
            }

            // A queued pre-release commit must not discard the fixed-edge
            // snapshot before the client acknowledges the final resize size.
            if (session.settling and !session.dirty and session.outstanding_configure == .none) {
                const gen = session.generation;
                toplevel.server.input.finishSettlement(gen);
            }
        }
    }

    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.err("handleCommit: could not update window decoration: {}", .{err});
    };
    if (toplevel.in_world) if (toplevel.server.layout_autosave) |autosave| {
        autosave.mapped(toplevel);
        autosave.finishMapped(toplevel);
    };
    @import("../auto_tiling.zig").observe(toplevel);
    toplevel.server.window_tabs.reconcile(toplevel);
    if (toplevel.tab_hidden) {
        if (@import("../window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.syncChrome(false, nowMs()) catch {};
    }
    if (toplevel.isMapped()) {
        toplevel.syncForeign();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowChanged(ipc, toplevel);
            ipc.wait_mgr.checkAll();
        }
    }
}

pub fn handleMapped(toplevel: *Toplevel) void {
    toplevel.server.holdTaskbars();
    defer toplevel.server.releaseTaskbars();
    if (toplevel.closing) toplevel.cancelClose();
    toplevel.minimized = false;
    toplevel.needs_attention = false;
    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.err("handleMap: could not update window decoration: {}", .{err});
    };

    toplevel.resolveInitialRules();
    if (toplevel.open_rules.focus orelse true) toplevel.server.window_tabs.focusMember(toplevel);
    const launch_origin = if (toplevel.backend != .placeholder and toplevel.backend != .shell) toplevel.server.launch_feedback.windowMapped(toplevel) else null;

    if (toplevel.open_rules.depth) |d| {
        toplevel.setZoomOrigin(d);
    }

    const maybe_ph = toplevel.placeholder_source orelse toplevel.findMatchingPlaceholder();
    var inherited_placeholder: ?*Toplevel = null;
    var ph_token: ?[]const u8 = null;
    var ph_pid: ?i32 = null;
    var ph_desktop_id: []const u8 = "";
    var ph_had_focus = false;

    if (maybe_ph) |ph_top| {
        if (ph_top.in_world and ph_top.backend == .placeholder and !ph_top.backend.placeholder.cancelled) {
            inherited_placeholder = ph_top;
            toplevel.workspace_id = ph_top.workspace_id;
            toplevel.workspace_order = ph_top.workspace_order;
            toplevel.workspace_generation = ph_top.workspace_generation;
            toplevel.canvas_state = ph_top.canvas_state;
            toplevel.auto_float = ph_top.auto_float;
            toplevel.auto_restore = ph_top.auto_restore;
            toplevel.auto_reinsert = ph_top.auto_reinsert;
            toplevel.auto_anchor = ph_top.auto_anchor;
            const ph = &ph_top.backend.placeholder;
            ph.matched = true;
            ph_token = ph.token;
            ph_pid = ph.pid;
            ph_desktop_id = ph.desktop_id;
            ph_had_focus = (toplevel.server.world.toplevels.first() == ph_top);

            const is_dialog = toplevel.parentWindow() != null;
            const client_geom = toplevel.clientGeometry();
            const is_far_smaller = (client_geom.width > 0 and client_geom.width < @divTrunc(ph.client_width, 2) and
                client_geom.height > 0 and client_geom.height < @divTrunc(ph.client_height, 2));

            if (!is_dialog and !is_far_smaller) {
                if (!toplevel.placed) {
                    toplevel.setPosition(ph_top.x, ph_top.y);
                    toplevel.placed = true;
                }
                if (ph_top.isMaximized()) {
                    toplevel.maximized = true;
                }
            }
        }
    }

    const target_out = toplevel.resolveTargetOutput();

    // Initial client requests already configure the protocol state, but must
    // also apply the corresponding geometry when the window maps. In
    // particular, don't cascade a maximized window like a floating one.
    if (toplevel.open_rules.fullscreen orelse toplevel.isFullscreen()) {
        if (target_out) |out| toplevel.setFullscreenOn(out);
        toplevel.placed = true;
    } else if (toplevel.open_rules.maximized orelse toplevel.isMaximized()) {
        if (target_out) |out| toplevel.setMaximizedOn(out);
        toplevel.placed = true;
    } else if (!toplevel.placed) {
        if (target_out) |output| {
            const frame_w = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom())));
            const frame_h = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom())));
            const geom = pickInitialPlacement(toplevel.server, output, toplevel.open_rules, toplevel.parentWindow(), frame_w, frame_h);
            toplevel.setPosition(geom.x, geom.y);
            toplevel.placed = true;
        }
    }

    toplevel.server.world.workspaces.mapped(toplevel);
    const want_focus = (if (inherited_placeholder != null) ph_had_focus else (toplevel.open_rules.focus orelse true)) and @import("../workspaces.zig").visible(toplevel);
    if (want_focus) {
        toplevel.needs_attention = false;
        toplevel.server.world.toplevels.prepend(toplevel);
        toplevel.in_world = true;
        toplevel.server.world.workspaces.mapped(toplevel);
        const undo_applying = toplevel.server.undo.applying;
        if (inherited_placeholder != null and toplevel.server.world.workspaces.active) toplevel.server.undo.applying = true;
        defer toplevel.server.undo.applying = undo_applying;
        toplevel.server.world.focus(toplevel);
    } else {
        toplevel.needs_attention = true;
        if (toplevel.server.world.toplevels.first()) |current_focused| {
            current_focused.link.insert(&toplevel.link);
            toplevel.frame_tree.node.placeBelow(&current_focused.frame_tree.node);
            toplevel.syncXwaylandStack();
        } else {
            toplevel.server.world.toplevels.prepend(toplevel);
        }
        toplevel.in_world = true;
        toplevel.server.world.workspaces.mapped(toplevel);
        toplevel.setActivated(false);
        @import("../config_runtime/apply.zig").applyWindowOpacity(toplevel.server);
        toplevel.server.refreshTaskbars();
    }
    if (toplevel.backend == .xdg) {
        if (toplevel.server.capture_mgr) |cm| {
            toplevel.foreign_handle = wlr.ExtForeignToplevelHandleV1.create(cm.toplevel_list, &.{
                .title = toplevel.backend.xdg.xdg_toplevel.title,
                .app_id = toplevel.backend.xdg.xdg_toplevel.app_id,
            }) catch |err| blk: {
                log.warn("handleMapped: could not publish foreign-toplevel handle: {}", .{err});
                break :blk null;
            };
        }
    }

    if (toplevel.backend != .placeholder and toplevel.wlr_foreign == null) {
        if (toplevel.server.foreign_toplevels) |manager| {
            toplevel.wlr_foreign = @import("../foreign_toplevel.zig").Handle.create(manager, toplevel) catch |err| blk: {
                log.warn("handleMapped: could not publish wlr foreign-toplevel handle: {}", .{err});
                break :blk null;
            };
        }
    }

    if (inherited_placeholder) |ph_top| {
        @import("../layout_undo.zig").replaced(toplevel.server, ph_top.id, toplevel.id);
        if (toplevel.server.ipc) |ipc| {
            events.onLaunchMatched(ipc, ph_desktop_id, toplevel.id, ph_pid);
        }
        ph_top.destroyNow();
    }

    if (toplevel.server.ipc) |ipc| {
        events.onWindowOpened(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }

    if (inherited_placeholder != null) {
        const now_ms = nowMs();
        toplevel.map_motion.cancel(1);
        toplevel.map_opacity.cancel(0);
        toplevel.map_opacity.retargetTo(now_ms, 1, anim.Curve{
            .duration = .{ .ms = 80, .ease = .out_cubic },
        });
        toplevel.applyVisualTransform(now_ms);
        toplevel.applyOpacity(now_ms);
        toplevel.server.scheduleFrames();
    } else {
        toplevel.beginOpenAnimation(launch_origin);
    }
    toplevel.server.window_tabs.mapped(toplevel);
    toplevel.server.window_tabs.mappedToken(toplevel);
    if (toplevel.server.layout_autosave) |autosave| autosave.finishMapped(toplevel);
    toplevel.syncChrome(false, nowMs()) catch {};
    toplevel.frame_tree.node.setEnabled(@import("../window_tabs.zig").visible(toplevel));
    // A newly focused app must not open behind the camera's current depth.
    if (want_focus and toplevel.server.config.compositor.focus_zoom == .camera) {
        if (target_out) |output| toplevel.server.world.navigateTo(toplevel, output);
    }
}

pub fn handleUnmapped(toplevel: *Toplevel) void {
    if (toplevel.closing) return;
    toplevel.finishZoomAnimation();
    toplevel.finishMoveAnimation();
    toplevel.server.switcher.cancel();
    if (!toplevel.in_world) return;
    const undo_applying = toplevel.server.undo.applying;
    toplevel.server.undo.applying = true;
    defer toplevel.server.undo.applying = undo_applying;
    const was_focused = toplevel.server.world.toplevels.first() == toplevel;
    const was_activated = toplevel.activated;
    const was_tab = toplevel.tab_group != 0;
    @import("../auto_tiling.zig").unmapped(toplevel);
    @import("../window_tabs.zig").rememberUnmap(toplevel);
    toplevel.server.window_tabs.remove(toplevel, false);
    toplevel.auto_target = null;
    toplevel.in_world = false;
    toplevel.needs_attention = false;
    toplevel.detachInput();
    toplevel.finishSwitch();
    const keep_scene = if (was_tab or !@import("../workspaces.zig").visible(toplevel)) false else toplevel.beginCloseAnimation();
    if (!keep_scene) {
        toplevel.clearChromeCache();
        toplevel.frame_tree.node.setEnabled(false);
    }
    if (toplevel.backend == .xdg) {
        toplevel.rules_resolved = false;
        toplevel.placed = false;
    }
    if (toplevel.backend != .placeholder) {
        const id = toplevel.appId();
        if (id.len > 0) {
            const geom = toplevel.clientGeometry();
            if (geom.width > 0 and geom.height > 0) {
                window_sizes.save(toplevel.server.io, toplevel.server.environ, id, @intCast(geom.width), @intCast(geom.height));
            }
        }
    }
    // Retire the foreign-toplevel handle so an unmapped (but not yet
    // destroyed) window stops being offered as a new capture target. This
    // deliberately does *not* also call `Manager.stopForWindow` here: full
    // close always calls this before `content_tree.node.destroy()`
    // (`Toplevel.destroy`), and `WindowCaptureSource`'s own listener on
    // that destroy event already ends any live session on it gracefully
    // (a real `stopped` event, not a hard disconnect — see
    // window_source.zig and `run_window_destroy_case`). Calling
    // `stopForWindow` here too would win that race every time and replace
    // the graceful stop with a hard one (minimize already gets its own
    // explicit `stopForWindow` call in `minimize()`, since that hides the
    // frame without destroying anything). The gap this leaves — a window
    // that unmaps without ever being destroyed and without going through
    // `minimize()` either — is a known, narrow limitation, not a
    // content-isolation bug like the one that motivated
    // `WindowCaptureSource` in the first place.
    if (toplevel.foreign_handle) |handle| {
        handle.destroy();
        toplevel.foreign_handle = null;
    }
    if (toplevel.wlr_foreign) |handle| {
        handle.destroy();
        toplevel.wlr_foreign = null;
    }
    toplevel.link.remove();
    toplevel.server.world.workspaces.tiler.schedule(toplevel.server);
    toplevel.server.refreshTaskbars();
    // A dismissed transient dialog returns focus to the window it was
    // opened from, rather than leaving the seat with no keyboard focus at
    // all (or focus on whatever the scene tree now happens to expose).
    if (was_focused) {
        if (toplevel.owner()) |owner_toplevel| {
            if (owner_toplevel.in_world) toplevel.server.world.focus(owner_toplevel);
        }
    }
    // Closing the active window hands the keyboard to the most recently
    // focused survivor, on the canvas as on a workspace. `activated` is false
    // while the desktop holds keyboard focus, which must not be taken away.
    if (was_focused and was_activated) {
        const workspaces = &toplevel.server.world.workspaces;
        @import("../workspaces.zig").focusFallback(toplevel.server, if (workspaces.active) toplevel.workspace_id else null);
    }
    if (toplevel.server.ipc) |ipc| {
        events.onWindowClosed(ipc, toplevel.id);
        ipc.wait_mgr.checkAll();
    }
    if (toplevel.server.idle) |im| {
        im.recheckInhibitors();
    }
}

pub fn destroy(toplevel: *Toplevel) void {
    if (toplevel.in_world) toplevel.handleUnmapped();
    if (!toplevel.backend_gone) {
        if (toplevel.forced_geometry_timer) |timer| {
            timer.remove();
            toplevel.forced_geometry_timer = null;
        }
        switch (toplevel.backend) {
            .xwayland => |*adapter| adapter.xsurface.data = null,
            .xdg, .placeholder, .shell => {},
        }
        toplevel.detachInput();
        if (toplevel.decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.decoration = null;
        }
        if (toplevel.kde_decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.kde_decoration = null;
        }
        toplevel.backend_gone = true;
    }
    if (toplevel.tryDeferDestroy()) return;
    toplevel.destroyNow();
}

pub fn tryDeferDestroy(toplevel: *Toplevel) bool {
    if (toplevel.server.shutting_down) return false;
    if (!toplevel.closing) return false;
    if (toplevel.close_snapshot == null) return false;
    const now_ms = nowMs();
    if (toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms)) return false;
    return true;
}

pub fn destroyNow(toplevel: *Toplevel) void {
    // A client window is freed only after its backend is destroyed: until then
    // its listeners are still attached and would run on freed memory.
    std.debug.assert(toplevel.backend_gone or toplevel.backend == .placeholder or toplevel.backend == .shell);
    if (toplevel.in_world) {
        toplevel.in_world = false;
        toplevel.link.remove();
        toplevel.server.world.workspaces.tiler.schedule(toplevel.server);
        toplevel.server.refreshTaskbars();
        if (toplevel.server.ipc) |ipc| {
            events.onWindowClosed(ipc, toplevel.id);
            ipc.wait_mgr.checkAll();
        }
    }
    if (toplevel.in_closing_list) {
        toplevel.closing_link.remove();
        toplevel.in_closing_list = false;
    }
    toplevel.closing = false;
    toplevel.close_snapshot = null;
    if (!toplevel.backend_gone) {
        if (toplevel.forced_geometry_timer) |timer| {
            timer.remove();
            toplevel.forced_geometry_timer = null;
        }
        switch (toplevel.backend) {
            .xwayland => |*adapter| adapter.xsurface.data = null,
            .xdg => {},
            .placeholder => |*ph| {
                var it = toplevel.server.world.toplevels.iterator(.forward);
                while (it.next()) |top| {
                    if (top.placeholder_source == toplevel) top.placeholder_source = null;
                }
                ph.deinit();
            },
            .shell => |*sw| std.debug.assert(sw.control_center == null),
        }
        toplevel.detachInput();
        if (toplevel.decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.decoration = null;
        }
        if (toplevel.kde_decoration) |decoration| {
            decoration.toplevel = null;
            toplevel.kde_decoration = null;
        }
        toplevel.backend_gone = true;
    }
    toplevel.clearChromeCache();
    toplevel.frame_tree.node.destroy();
    toplevel.releaseIcon();
    gpa.destroy(toplevel);
}

pub fn handleIdentityChanged(toplevel: *Toplevel) void {
    const prev_rules = toplevel.live_rules;
    const new_id = toplevel.currentIdentity();

    if (toplevel.rules_resolved) {
        if (toplevel.resolved_before_app_id and new_id.app_id.len > 0) {
            const hyp = window_rules.resolve(toplevel.server.config.window_rules, new_id);
            const hyp_open = window_rules.OpenRules.fromResolved(hyp);
            if (!hyp_open.eql(toplevel.open_rules)) {
                log.debug("window '{s}' ({s}) identity changed after open-time rules resolved; open-time rules would have differed", .{ toplevel.appId(), toplevel.title() });
            }
        }
        const resolved = window_rules.resolve(toplevel.server.config.window_rules, new_id);
        toplevel.live_rules = window_rules.LiveRules.fromResolved(resolved);
        toplevel.matched_rules = resolved.matched_rules;
    }

    if (toplevel.live_rules.opacity != prev_rules.opacity) {
        @import("../config_runtime/apply.zig").applyWindowOpacity(toplevel.server);
    }
    if (toplevel.live_rules.decorations != prev_rules.decorations) {
        if (toplevel.decoration) |d| d.applyMode();
        if (toplevel.kde_decoration) |d| d.applyMode(false);
        toplevel.syncChrome(true, nowMs()) catch {};
    }

    if (toplevel.in_world) if (toplevel.server.layout_autosave) |autosave| {
        autosave.mapped(toplevel);
        autosave.finishMapped(toplevel);
    };
    @import("../auto_tiling.zig").observe(toplevel);
    toplevel.server.window_tabs.reconcile(toplevel);
    if (toplevel.tab_hidden) {
        if (@import("../window_tabs.zig").active(toplevel.server, toplevel.tab_group)) |active_tab| active_tab.syncChrome(false, nowMs()) catch {};
    }
    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.err("handleIdentityChanged: could not update window title: {}", .{err});
    };
    if (toplevel.foreign_handle) |handle| {
        if (toplevel.backend == .xdg) {
            handle.updateState(&.{
                .title = toplevel.backend.xdg.xdg_toplevel.title,
                .app_id = toplevel.backend.xdg.xdg_toplevel.app_id,
            });
        }
    }
    toplevel.server.refreshTaskbars();
    toplevel.syncForeign();
    if (toplevel.server.ipc) |ipc| {
        events.onWindowChanged(ipc, toplevel);
        ipc.wait_mgr.checkAll();
    }
}
