//! Output frames: committing, frame scheduling, tearing and presentation.

const std = @import("std");
const Output = @import("../Output.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const SceneOutput = @import("../scene_outputs.zig").SceneOutput;
const Taskbar = @import("../Taskbar.zig");
const anim = @import("ui").anim;
const glass = @import("../glass.zig");
const stats = @import("../ipc/stats.zig");
const trace = @import("frame_trace.zig");
const late = @import("late.zig");
const wlr_color_transform_unref = Output.wlr_color_transform_unref;
const log = std.log.scoped(.output);
const CursorState = Output.CursorState;
const syncLayout = Output.syncLayout;
const scaled = Output.scaled;
const timestamp = Output.timestamp;

pub fn commitFrameState(output: *Output, state: *wlr.Output.State) bool {
    if (output.color.pending) {
        var copy = state.*;
        copy.setColorTransform(output.color.transform);
        if (output.wlr_output.testState(&copy)) {
            state.setColorTransform(output.color.transform);
        } else {
            output.color.status = .rejected;
            output.color.pending = false;
            output.color.consecutive_failures = 0;
            if (!output.color.logged_rejected) {
                output.color.logged_rejected = true;
                log.warn("output '{s}' rejected color transform", .{output.wlr_output.name});
            }
        }
        if (copy.color_transform) |tr| {
            wlr_color_transform_unref(tr);
        }
    }

    const had_transform = state.committed.color_transform;
    state.tearing_page_flip = state.committed.buffer and output.tearingAllowed();
    if (state.tearing_page_flip and !output.wlr_output.testState(state)) {
        state.tearing_page_flip = false;
        output.tearing_rejected = true;
    }
    var success = output.wlr_output.commitState(state);
    if (!success and state.tearing_page_flip) {
        state.tearing_page_flip = false;
        output.tearing_rejected = true;
        success = output.wlr_output.commitState(state);
    }
    if (had_transform) {
        if (success) {
            output.color.status = if (output.color.transform != null) .applied else .neutral;
            output.color.pending = false;
            output.color.consecutive_failures = 0;
        } else {
            if (output.color.transform != null) {
                output.color.consecutive_failures +%= 1;
                if (output.color.consecutive_failures >= 3) {
                    output.color.status = .rejected;
                    output.color.pending = false;
                    if (!output.color.logged_rejected) {
                        output.color.logged_rejected = true;
                        log.warn("output '{s}' rejected color transform after 3 failures", .{output.wlr_output.name});
                    }
                }
            }
        }
    }
    if (!success and state.committed.buffer) {
        if (output.server.scene_outputs.get(output.wlr_output)) |scene_output| scene_output.damageWhole();
    }
    return success;
}

/// Whether this frame would present exactly what is already on screen.
///
/// A client that asks for a frame callback makes wlroots latch
/// `wlr_output.needs_frame`, which otherwise forces a scene build and a page
/// flip every refresh even with no damage. That is the whole cost of an idle
/// desktop with one such client. Anything else that raises `needs_frame`
/// without scene damage is checked here: hardware cursor moves, output
/// capture (which holds an attach-render lock) and gamma changes.
pub fn commitIsRedundant(output: *Output, scene_output: *SceneOutput) bool {
    if (output.vblank_timer == null or output.color.pending) return false;
    const wlr_output = output.wlr_output;
    if (!wlr_output.enabled or wlr_output.attach_render_locks > 0) return false;
    if (scene_output.hasPendingDamage()) return false;
    return std.meta.eql(CursorState.of(wlr_output), output.committed_cursor);
}

pub fn refreshPeriodNs(output: *Output) u64 {
    const mhz: u64 = if (output.wlr_output.refresh > 0) @intCast(output.wlr_output.refresh) else 60_000;
    return 1_000_000_000_000 / mhz;
}

/// Delivers frame callbacks at the next estimated vblank instead of now.
/// Sending them immediately would let a client's next empty commit schedule
/// another frame at once: with no page flip pending nothing would pace it.
pub fn deferFrameDone(output: *Output) void {
    const timer = output.vblank_timer.?;
    const period = refreshPeriodNs(output);
    const now = stats.nowNs();
    const last = output.last_vblank_ns;
    const target = if (last == 0 or last > now) now + period else last + ((now - last) / period + 1) * period;
    const delay_ms: c_int = @intCast(@max(1, std.math.divCeil(u64, target - now, std.time.ns_per_ms) catch 1));
    timer.timerUpdate(delay_ms) catch {
        sendFrameDone(output);
        return;
    };
    output.vblank_armed = true;
    output.vblank_target_ns = target;
}

/// A client surface committed with frame callbacks waiting (node_surface.c).
/// A commit that changed nothing must not build a frame just to find it
/// redundant: once every commit handler of this dispatch has run, deliver the
/// callbacks at the next vblank unless a frame is coming anyway.
pub fn frameCallbacksWanted(wlr_output: *wlr.Output) callconv(.c) void {
    const output: *Output = @ptrCast(@alignCast(wlr_output.data orelse {
        wlr_output.scheduleFrame();
        return;
    }));
    if (output.vblank_armed or output.callback_idle != null) return;
    output.callback_frame_seq = output.frame_seq;
    output.callback_idle = output.server.wl_server.getEventLoop().addIdle(*Output, callbacksIdle, output) catch {
        wlr_output.scheduleFrame();
        return;
    };
}

fn callbacksIdle(output: *Output) void {
    output.callback_idle = null;
    const wlr_output = output.wlr_output;
    // A frame since the request sent them; a scheduled one or the timer will.
    if (output.frame_seq != output.callback_frame_seq or output.vblank_armed or wlr_output.needs_frame) return;
    const scene_output = output.server.scene_outputs.get(wlr_output) orelse return wlr_output.scheduleFrame();
    // A frame waiter (IPC) counts on client frames reaching the output.
    const waiting = if (output.server.ipc) |ipc| ipc.wait_mgr.waitsForFrame() else false;
    if (wlr_output.frame_pending or waiting or !commitIsRedundant(output, scene_output)) return wlr_output.scheduleFrame();
    stats.global_stats.output_skipped_commits +%= 1;
    deferFrameDone(output);
}

pub fn handleVblank(output: *Output) c_int {
    output.vblank_armed = false;
    output.last_vblank_ns = output.vblank_target_ns;
    sendFrameDone(output);
    if (output.frame_wanted) {
        output.frame_wanted = false;
        output.wlr_output.scheduleFrame();
    }
    return 0;
}

pub fn sendFrameDone(output: *Output) void {
    if (output.server.scene_outputs.get(output.wlr_output)) |scene_output| {
        var now = timestamp();
        output.server.sendFrameDone(scene_output, &now);
    }
    var preview_time = timestamp();
    output.server.switcher.frameDone(output, &preview_time);
}

// A client commit can render before the next vblank when the previous flip is
// complete. Coalesce commits at idle, after wlroots has updated scene damage.
pub fn tearingAllowed(output: *Output) bool {
    const server = output.server;
    if (!server.config.compositor.allow_tearing or output.tearing_rejected or
        server.locker != null or server.polkit_dialog != null or server.greeter_mode or
        output.power_off or !output.wlr_output.enabled) return false;
    const focused = server.input.seat.keyboard_state.focused_surface orelse return false;
    const top = @import("../Toplevel.zig").fromSurface(server, focused) orelse return false;
    if (!top.in_world or top.minimized or top.tab_hidden or !top.isFullscreen() or top.currentOutput() != output) return false;
    return @import("../extra_protocols.zig").rediwm_protocols_tearing(server.extra_protocols, top.surface());
}

pub fn queueTearing(output: *Output) void {
    if (output.tearing_idle != null or !output.tearingAllowed()) return;
    output.tearing_idle = output.server.wl_server.getEventLoop().addIdle(*Output, tearingIdle, output) catch null;
}

pub fn tearingIdle(output: *Output) void {
    output.tearing_idle = null;
    if (!output.tearingAllowed() or output.wlr_output.frame_pending or output.vblank_armed) return;
    runFrame(output);
}

pub fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);
    // A deferred frame is on its way; this event is damage asking for it.
    // (Not traced: the frame's event is the one that deferred it.)
    if (output.late_armed) return;
    trace.frameEvent(output.wlr_output);
    // Only the vblank timer paces frames after a skipped commit.
    if (output.vblank_armed) {
        output.frame_wanted = true;
        return;
    }
    if (output.flip_pending) {
        output.flip_pending = false;
        output.last_vblank_ns = stats.nowNs();
    }
    if (late.tryDefer(output)) return;
    runFrame(output);
}

pub fn runFrame(output: *Output) void {
    const frame_started = stats.nowNs();
    const late_plan = late.takePlan(output);
    // Stage timing costs a clock read per boundary (and two per animation
    // sample); only pay it while someone is reading the stats.
    const observing = output.server.observingStats(frame_started);
    anim.beginFrame(output.animation_budget.coarse, if (observing) stats.nowNs else null, @intCast(frame_started / std.time.ns_per_ms));
    defer {
        const sampling_ns = anim.endFrame();
        if (observing) stats.global_stats.anim_cpu.record(sampling_ns);
        const elapsed = stats.nowNs() -% frame_started;
        stats.global_stats.cpu_frame.record(elapsed);
        output.animation_budget.record(elapsed, output.wlr_output.refresh);
    }
    output.server.expireGpuTimer();
    if (output.server.gpu_timer) |timer| timer.collect(&output.server.gpu_recent);

    output.server.screenshot_selector.flush(output);
    const now_ms = Taskbar.nowMs();
    // Shell windows apply sizes synchronously. Flush before painting their
    // content so the body and chrome reach this frame at the same size.
    output.server.input.flushResizeConfigure(output);
    anim.observeBegin();
    const switcher_animating = output.server.switcher.tick(output, now_ms);
    const osd_animating = output.osd.tick(output, now_ms);
    const dock_animating = output.dock.tick(output, now_ms);
    const taskbar_started = if (observing) stats.nowNs() else 0;
    var bar_animating = false;
    if (output.taskbar) |bar| bar_animating = bar.tick(now_ms);
    if (observing) stats.global_stats.taskbar_cpu.record(stats.nowNs() -% taskbar_started);
    const chrome_started = if (observing) stats.nowNs() else 0;
    const chrome_animating = output.server.world.tickHover(now_ms);
    if (observing) stats.global_stats.chrome_cpu.record(stats.nowNs() -% chrome_started);
    const panels_started = if (observing) stats.nowNs() else 0;

    var cc_animating = false;
    if (output.server.input.open_control_center) |cc| {
        // A resize may be paced by another output after the window is moved.
        if (cc.wlr_output == output.wlr_output or !cc.wlr_output.enabled or cc.layout_pending) cc_animating = cc.tick(now_ms);
    }

    var sm_animating = false;
    if (output.start_menu) |sm| {
        sm_animating = sm.tick(now_ms);
        if (sm.finishedClosing(now_ms)) {
            sm.destroy();
            output.start_menu = null;
            if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
        }
    }

    var pm_animating = false;
    if (output.power_menu) |pm| {
        pm_animating = pm.tick(now_ms);
        if (pm.finishedClosing(now_ms)) {
            pm.destroy();
            output.power_menu = null;
            if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
        }
    }

    var taskbar_popup_animating = false;
    if (output.wifi_popup) |popup| taskbar_popup_animating = popup.tick(now_ms);
    if (output.battery_popup) |popup| taskbar_popup_animating = popup.tick(now_ms) or taskbar_popup_animating;
    if (output.calendar) |calendar| taskbar_popup_animating = calendar.tick(now_ms) or taskbar_popup_animating;

    var notif_animating = false;
    if (output.server.notifications) |mgr| {
        notif_animating = mgr.tick(output, now_ms);
    }

    const desktop_animating = if (output.server.desktop) |desktop| desktop.frame(output) else false;

    if (observing) stats.global_stats.panels_cpu.record(stats.nowNs() -% panels_started);
    if (anim.observeLongestMs() > 0) {
        const longest: u64 = @intCast(anim.observeLongestMs());
        if (longest > stats.global_stats.anim_longest_ms) stats.global_stats.anim_longest_ms = longest;
    }
    const scene_output = output.server.scene_outputs.get(output.wlr_output) orelse {
        // Safer than `.?`: a missing scene output is a setup failure, not a
        // reason to abort the compositor on every refresh.
        log.err("handleFrame: no scene output for {s}", .{output.wlr_output.name});
        return;
    };
    const reveal_animating = output.server.reveal.tick(output, now_ms);
    const projection_started = if (observing) stats.nowNs() else 0;
    output.server.world.refreshBounds();
    output.server.world.syncPresentation();
    if (observing) stats.global_stats.projection_cpu.record(stats.nowNs() -% projection_started);
    output.server.world.flushCameraEvent();
    const mini_map_animating = output.server.world.mini_map.tick(output, now_ms);
    // GPU timestamps enclose the scene submission, glass included (the output
    // pass blurs it). Polling happens later; no glFinish or synchronous reads.
    const gpu_active = if (output.server.gpu_timer) |timer| timer.begin() else false;
    const lock_animating = output.lock_view.sync(output);
    const polkit_animating = if (output.server.polkit_dialog) |dialog|
        dialog.output == output.wlr_output and dialog.frame(now_ms)
    else
        false;
    glass.Engine.hold(output.server.glass_engine, output.server.input.heldGlass());
    glass.Engine.holdAll(output.server.glass_engine, output.server.world.holdingGlass());
    var captured = false;
    if (output.server.screenshot_mgr) |sm| {
        captured = sm.handleOutputFrame(output);
    }
    var deferred = false;
    var timing = trace.Frame{ .start = frame_started, .active = trace.enabled or late.enabled(output), .plan = late_plan };
    defer timing.finish(output.wlr_output);
    if (!captured) {
        const started = stats.nowNs();
        var state = wlr.Output.State.init();
        defer state.finish();
        var should_commit = scene_output.needsFrame() or output.color.pending;
        if (should_commit and commitIsRedundant(output, scene_output)) {
            // `needs_frame` is a latch only a commit clears; while set,
            // later cursor moves or capture requests could not schedule.
            output.wlr_output.needs_frame = false;
            should_commit = false;
            deferred = true;
            stats.global_stats.output_skipped_commits +%= 1;
        }
        var committed = true;
        if (should_commit) {
            if (output.server.capture_mgr) |cm| cm.guardScreencopy(output.wlr_output);
            const built_ok = output.server.buildOutputState(scene_output, &state);
            timing.markBuilt();
            if (built_ok) {
                if (@import("../startup.zig").marks.first_visible_ns == 0) {
                    output.startup_commit_seq = output.wlr_output.commit_seq +% 1;
                    output.startup_presented = false;
                }
                if (output.server.greeter_mode and output.lock_view.content_ready and output.greeter_unveiled)
                    output.greeter_commit_seq = output.wlr_output.commit_seq +% 1;
                output.startup_committing = true;
                committed = output.commitFrameState(&state);
                output.startup_committing = false;
                timing.markCommitted(if (committed) output.wlr_output.commit_seq else null);
                if (!committed) {
                    output.startup_commit_seq = null;
                    output.greeter_commit_seq = null;
                }
            } else {
                committed = false;
            }
            if (committed) {
                output.committed_cursor = CursorState.of(output.wlr_output);
                output.flip_pending = true;
                if (timing.commit_seq) |seq| late.noteCommitted(output, seq, frame_started, timing.built, timing.done, late_plan);
                if (output.lock_commit_pending) {
                    output.lock_commit_pending = false;
                    if (output.server.locker) |lock| lock.outputCovered();
                }
            }
        }
        const commit_duration = stats.nowNs() -% started;
        stats.global_stats.scene_commit_cpu.record(commit_duration);
        if (!committed) {
            log.err("handleFrame: scene commit failed for {s}", .{output.wlr_output.name});
            stats.recordFailedCommit();
        } else if (should_commit) {
            stats.recordPresentedFrame(commit_duration, output.wlr_output.refresh);
            @import("../startup.zig").notePresented(@intCast(output.server.outputs.length()), output.server.maxOutputScale());
            output.server.session_startup.onPresented();
            // Headless backends can acknowledge synchronously inside commit.
            if (output.startup_presented) output.startupVisible();
        }
        // A deferred frame's callbacks went out when it was deferred.
        if (!deferred and late_plan == null) {
            var now = timestamp();
            output.server.sendFrameDone(scene_output, &now);
        }
    }
    if (deferred) {
        deferFrameDone(output);
    } else if (late_plan == null) {
        var preview_time = timestamp();
        output.server.switcher.frameDone(output, &preview_time);
    }
    if (gpu_active) output.server.gpu_timer.?.end();
    output.frame_seq +%= 1;
    if (output.server.ipc) |ipc| {
        ipc.wait_mgr.onOutputFrame(output);
        ipc.wait_mgr.checkAll();
    }

    // Keep repainting every refresh interval until the last hover/press/FLIP
    // animation settles; otherwise chrome and the bar only redraw when a
    // client does.
    const keep_going = mini_map_animating or switcher_animating or osd_animating or dock_animating or bar_animating or chrome_animating or cc_animating or sm_animating or pm_animating or taskbar_popup_animating or notif_animating or desktop_animating or lock_animating or polkit_animating or reveal_animating;
    output.late_animating = keep_going;
    // A pinned clock is advanced explicitly by IPC, which schedules its own
    // frame. Global window/taskbar springs must not spin between those steps.
    if (keep_going and !anim.clockOverridden()) {
        output.wlr_output.scheduleFrame();
        // Count the re-arm itself rather than `observeActive()`. Gating on the
        // latter meant a keep-awake that never reached `sampleChanged` — a
        // `settled()`-only check, or a caret blink — pumped this output at full
        // refresh while the counter read a reassuring zero.
        stats.global_stats.anim_frames_scheduled +%= 1;
        if (!anim.observeChanged()) stats.global_stats.anim_wasted_wakeups +%= 1;
    }
}

/// Apply a validated display mode, then update every output's placement and
/// shell geometry. This is a modeset, not a scene-built frame commit.
pub fn setDisplayMode(output: *Output, mode: @import("../output_modes.zig").Choice) bool {
    var state = wlr.Output.State.init();
    defer state.finish();
    mode.setState(&state);
    if (!output.wlr_output.testState(&state) or !output.wlr_output.commitState(&state)) return false;
    late.reset(output);
    syncLayout(output.server);
    output.color.key = null;
    output.server.night_light.retargetOutput(output);
    if (output.server.idle) |im| im.recheckInhibitors();
    output.wlr_output.scheduleFrame();
    return true;
}

pub fn handleRequestState(
    listener: *wl.Listener(*wlr.Output.event.RequestState),
    event: *wlr.Output.event.RequestState,
) void {
    const output: *Output = @fieldParentPtr("request_state", listener);

    var state = wlr.Output.State.init();
    defer state.finish();
    if (!state.copy(event.state)) {
        log.err("handleRequestState: could not copy state for {s}", .{output.wlr_output.name});
        return;
    }
    // Only the nested Wayland backend asks for a host-window logical size.
    // DRM modes are always device pixels and must never be multiplied.
    if (output.wlr_output.isWl() and state.committed.mode and state.mode_type == .custom) {
        state.setCustomMode(
            scaled(state.custom_mode.width, output.wlr_output.scale),
            scaled(state.custom_mode.height, output.wlr_output.scale),
            state.custom_mode.refresh,
        );
    }
    if (!output.wlr_output.commitState(&state)) {
        log.err("handleRequestState: commitState failed for {s}", .{output.wlr_output.name});
        return;
    }
    late.reset(output);
    output.applyConfig();
    syncLayout(output.server);
    output.color.key = null;
    output.server.night_light.retargetOutput(output);
    if (output.server.idle) |im| im.recheckInhibitors();
}

pub fn handlePresent(listener: *wl.Listener(*wlr.Output.event.Present), event: *wlr.Output.event.Present) void {
    const output: *Output = @fieldParentPtr("present", listener);
    trace.presented(event);
    late.notePresent(output, event);
    if (event.presented and output.greeter_commit_seq == event.commit_seq) {
        output.greeter_presented = true;
        @import("../session/greeter_ready.zig").check(output.server);
    }
    if (@import("../startup.zig").marks.first_visible_ns != 0 or !event.presented) return;
    if (output.startup_commit_seq == null or event.commit_seq != output.startup_commit_seq.?) return;
    output.startup_presented = true;
    if (!output.startup_committing) output.startupVisible();
}

pub fn startupVisible(output: *Output) void {
    if (@import("../startup.zig").marks.first_visible_ns != 0) return;
    @import("../startup.zig").noteVisible();
    output.server.startup_tasks.onVisible();
    output.server.reveal.onVisible();
}
