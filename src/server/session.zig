//! Server session: terminate, deactivate and reactivate, security contexts and services.

const std = @import("std");
const Server = @import("../Server.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const audio_mod = @import("../audio/pipewire.zig");
const Output = @import("../Output.zig");
const power_profiles_mod = @import("../power_profiles.zig");
const notifications_mod = @import("../notifications/mod.zig");
const log = std.log.scoped(.compositor);
const createAudioWakeFd = Server.createAudioWakeFd;
const handleAudioWake = Server.handleAudioWake;

pub fn terminate(server: *Server) void {
    if (server.shutting_down) return;
    server.shutting_down = true;
    log.info("terminating compositor session", .{});
    if (server.layout_autosave) |as| as.saveNow();
    // Unwind the event callback before tearing down clients. deinit destroys
    // the owned Xwayland server first; disconnecting its Wayland client here
    // would trigger wlroots' crash recovery and start it again during logout.
    server.wl_server.terminate();
}

pub fn deactivateSession(server: *Server) void {
    if (server.power) |power| power.syncInhibitors();
    if (server.polkit) |agent| {
        if (server.locker != null) agent.pauseForLock() else agent.cancelAll();
    }
    log.info("deactivating session: cancelling grabs, focus and menus", .{});
    server.input.clearGrab();
    server.screenshot_selector.cancel();
    server.switcher.cancel();

    if (server.input.gesture != .none) {
        if (server.input.gesture == .compositor_pinch or server.input.gesture == .client_pinch) {
            server.input.handlePinchEnd(0, true);
        } else if (server.input.gesture == .compositor_swipe or server.input.gesture == .client_swipe) {
            server.input.handleSwipeEnd(0, true);
        }
    }
    if (server.input.finger_pan) {
        server.input.finger_pan = false;
        server.world.cancelPan();
    }

    server.input.seat.keyboardEndGrab();
    server.input.seat.pointerEndGrab();
    server.input.window_menu.close();
    server.input.seat.keyboardClearFocus();
    server.input.seat.pointerClearFocus();
    server.input.setDefaultCursor();
    @import("ui").input.reset();

    var it = server.outputs.iterator(.forward);
    while (it.next()) |out| {
        out.closeStartMenu();
        out.closePowerMenu();
        out.closeBattery();
        out.closeWifi();
    }
    if (server.input.open_control_center) |cc| cc.pointer_down = false;

    if (server.layout_autosave) |as| as.saveNow();
}

pub fn reactivateSession(server: *Server) void {
    server.power_policy.refresh();
    if (server.idle) |idle| idle.notifyActivity(.lid);
    log.info("reactivating session: restoring output layout, damage and presentation", .{});
    Output.syncLayout(server);
    server.input.refreshOutputScales();

    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (server.scene_outputs.get(output.wlr_output)) |so| {
            so.damageWhole();
        }
        output.wlr_output.scheduleFrame();
    }
}

pub fn handleSessionActive(listener: *wl.Listener(void)) void {
    const server: *Server = @fieldParentPtr("session_active", listener);
    const session = server.session orelse return;
    if (session.active) {
        log.info("session became active (VT switch back)", .{});
        server.reactivateSession();
        @import("../session/greeter_ready.zig").check(server);
        server.startup_tasks.onSessionActive();
    } else {
        log.info("session became inactive (VT switch away)", .{});
        server.deactivateSession();
    }
}

pub fn handleSecurityContextDestroy(listener: *wl.Listener(void)) void {
    const server: *Server = @fieldParentPtr("security_context_destroy", listener);
    server.security_context = null;
    server.security_context_destroy.link.remove();
    server.security_context_commit.link.remove();
}

pub fn handleSecurityContextCommit(listener: *wl.Listener(*wlr.SecurityContextManagerV1.event.Commit), event: *wlr.SecurityContextManagerV1.event.Commit) void {
    _ = listener;
    const engine = if (event.state.sandbox_engine) |s| std.mem.span(s) else "<unspecified>";
    const app_id = if (event.state.app_id) |s| std.mem.span(s) else "<unspecified>";
    const instance_id = if (event.state.instance_id) |s| std.mem.span(s) else "<unspecified>";
    log.info("security-context: commit engine='{s}' app_id='{s}' instance_id='{s}'", .{ engine, app_id, instance_id });
}

pub fn getSystemd(server: *Server) !*@import("../systemd.zig").Client {
    if (server.greeter_mode) return error.ServicesUnavailable;
    if (server.systemd_client) |client| return client;
    const client = try @import("../systemd.zig").Client.create(server);
    server.systemd_client = client;
    return client;
}

/// One optional service per event-loop turn after the first desktop frame.
/// Power/lock inhibitors and child ownership are initialized synchronously.
pub fn startDesktopService(server: *Server, step: usize) bool {
    if (server.greeter_mode) return false;
    switch (step) {
        0 => {
            server.notifications = notifications_mod.Manager.create(server, @import("../main.zig").gpa) catch |err| blk: {
                log.warn("init: could not create notifications manager: {}", .{err});
                break :blk null;
            };
            // Outputs already took their initial battery snapshots before the
            // notification service started. Warn immediately when logging in low.
            var outputs = server.outputs.iterator(.forward);
            while (outputs.next()) |output| {
                if (output.taskbar) |bar| server.updateBatteryWarning(bar.battery_state);
            }
        },
        1 => {
            server.configurePolkit(server.config.polkit);
        },
        2 => {
            server.network = @import("../network/manager.zig").Manager.create(server) catch null;
        },
        3 => {
            server.power_profiles = power_profiles_mod.Manager.create(server, @import("../main.zig").gpa) catch |err| blk: {
                log.warn("init: could not create power profiles manager: {}", .{err});
                break :blk null;
            };
        },
        4 => {
            server.audio = audio_mod.AudioManager.createAsync(@import("../main.zig").gpa) catch |err| blk: {
                log.warn("init: PipeWire/PulseAudio not available, audio control disabled: {}", .{err});
                break :blk null;
            };
            if (server.audio) |mgr| {
                if (createAudioWakeFd()) |fd| {
                    mgr.setWakeFd(fd);
                    server.audio_wake_source = server.wl_server.getEventLoop().addFd(*Server, fd, .{ .readable = true }, handleAudioWake, server) catch |err| blk: {
                        log.warn("init: could not register audio wake fd: {}", .{err});
                        break :blk null;
                    };
                } else {
                    log.warn("init: could not create audio wake eventfd; taskbar/UI may lag behind external volume changes", .{});
                }
            }
        },
        else => return false,
    }
    return true;
}
