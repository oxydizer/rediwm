const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const sn = @import("node.zig");

const StartMenu = @import("start_menu/panel.zig").StartMenu;
const PowerMenu = @import("power_menu.zig").PowerMenu;
const Server = @import("Server.zig");
const Taskbar = @import("Taskbar.zig");
const anim = @import("ui").anim;
const geometry = @import("geometry.zig");
const events = @import("ipc/events.zig");
const gpa = @import("main.zig").gpa;
const output_modes = @import("output/modes.zig");
const output_layout = @import("output/layout.zig");
const output_panels = @import("output/panels.zig");
const output_wallpaper = @import("output/wallpaper.zig");
const output_frame = @import("output/frame.zig");

pub const wlr_color_transform_init_lut_3x1d = wlr.color.transformInitLut3x1d;
pub const wlr_color_transform_unref = wlr.color.transformUnref;

pub const ColorKey = struct {
    temperature: u16,
    gamma_milli: u16,
    gamma_size: usize,
};

pub const ColorStatus = enum {
    neutral,
    pending,
    applied,
    unsupported,
    rejected,
    disabled,
};

pub const OutputColor = struct {
    transform: ?*wlr.ColorTransform = null,
    key: ?ColorKey = null,
    pending: bool = false,
    status: ColorStatus = .neutral,
    consecutive_failures: u8 = 0,
    logged_unsupported: bool = false,
    logged_rejected: bool = false,

    pub fn deinit(self: *OutputColor) void {
        if (self.transform) |tr| {
            wlr_color_transform_unref(tr);
            self.transform = null;
        }
    }
};

const Output = @This();

const log = std.log.scoped(.output);

lock_view: @import("session/lock.zig").View,
greeter_commit_seq: ?u32 = null,
greeter_presented: bool = false,
greeter_unveiled: bool = true,
server: *Server,
wlr_output: *wlr.Output,
wallpaper: ?*sn.Buffer = null,
taskbar: ?*Taskbar = null,
dock: @import("Dock.zig") = .{},
osd: @import("osd.zig") = .{},
start_menu: ?*StartMenu = null,
calendar: ?*@import("calendar.zig").Calendar = null,
battery_popup: ?*@import("battery_popup.zig").Popup = null,
wifi_popup: ?*@import("network/popup.zig").Popup = null,
power_menu: ?*PowerMenu = null,
color: OutputColor = .{},
frame_seq: u64 = 0,
// Match a scene buffer, excluding the backend's initial empty modeset.
startup_commit_seq: ?u32 = null,
startup_committing: bool = false,
startup_presented: bool = false,
animation_budget: anim.FrameBudget = .{},
idle_blanked: bool = false,
lid_blanked: bool = false,
/// Turned off by a wlr-output-power-management client (`output_power.zig`):
/// held `idle_blanked` until a client turns it back on.
power_off: bool = false,
user_disabled: bool = false,
cached_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
/// Paces frames whose output commit was skipped (see `commitIsRedundant`):
/// no page flip is pending then, so this timer stands in for the vblank.
vblank_timer: ?*wl.EventSource = null,
vblank_armed: bool = false,
vblank_target_ns: u64 = 0,
/// A frame event arrived while `vblank_timer` was armed; replay it then.
frame_wanted: bool = false,
/// Last known vblank: a page-flip frame event or a fired `vblank_timer`.
last_vblank_ns: u64 = 0,
flip_pending: bool = false,
/// Decides, once this dispatch's commits are handled, whether client frame
/// callbacks need a frame (`frameCallbacksWanted`).
callback_idle: ?*wl.EventSource = null,
callback_frame_seq: u64 = 0,
tearing_idle: ?*wl.EventSource = null,
tearing_rejected: bool = false,
/// An ext-session-lock client waits for this output to commit a locked frame.
lock_commit_pending: bool = false,
/// Hardware cursor state as of the last commit. Atomic DRM applies cursor
/// moves only with a commit, so a change here must not be skipped.
committed_cursor: CursorState = .{},
/// server.outputs
link: wl.list.Link = undefined,

frame: wl.Listener(*wlr.Output) = .init(handleFrame),
present: wl.Listener(*wlr.Output.event.Present) = .init(handlePresent),
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
workspace_id: u8 = 0,
destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),

pub fn isLogicallyEnabled(self: *const Output) bool {
    return !self.user_disabled;
}

pub fn isAvailable(self: *const Output) bool {
    return self.isLogicallyEnabled() and !self.idle_blanked and self.wlr_output.enabled;
}

/// A laptop's own panel, by DRM connector type.
pub fn isBuiltinPanel(name: []const u8) bool {
    for ([_][]const u8{ "eDP", "LVDS", "DSI" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// Whether a display other than the built-in panel is on.
pub fn otherDisplayOn(server: *Server) bool {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!isBuiltinPanel(std.mem.span(output.wlr_output.name)) and output.isLogicallyEnabled()) return true;
    }
    return false;
}

/// A closed lid turns the built-in panel off, but never the last display.
pub fn lidHides(output: *const Output) bool {
    const server = output.server;
    if (!server.input.lid.closed or (if (server.power_policy.enabled()) server.power_policy.lidAction() else server.config.compositor.lid_close) == .ignore) return false;
    return isBuiltinPanel(std.mem.span(output.wlr_output.name)) and otherDisplayOn(server);
}

/// Re-applies the lid policy after the lid, the outputs or the setting change.
pub fn applyLid(server: *Server) void {
    var changed = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!isBuiltinPanel(std.mem.span(output.wlr_output.name))) continue;
        const lid_blank = server.power_policy.enabled() and server.input.lid.closed and server.power_policy.lidAction() != .ignore and !otherDisplayOn(server);
        const blank_changed = output.lid_blanked != lid_blank;
        output.lid_blanked = lid_blank;
        const layout_changed = lidHides(output) != output.user_disabled;
        if (layout_changed) {
            output.applyConfig();
            changed = true;
        }
        if (blank_changed or layout_changed) {
            const idle_blank = if (server.idle) |idle| idle.isBlanked() else false;
            _ = output.setIdleBlanked(idle_blank or output.power_off);
        }
    }
    if (changed) syncLayout(server);
    server.power_policy.reconcileLid();
}

// output/modes.zig
pub const configured = output_modes.configured;
pub const configuredTransform = output_modes.configuredTransform;
pub const wlTransform = output_modes.wlTransform;
pub const configuredScale = output_modes.configuredScale;
pub const scaleForMode = output_modes.scaleForMode;
pub const scaleForDimensions = output_modes.scaleForDimensions;
pub const automaticScale = output_modes.automaticScale;
pub const configuredMode = output_modes.configuredMode;
pub const resolveDisplayMode = output_modes.resolveDisplayMode;

// output/layout.zig
pub const applyAndPersist = output_layout.applyAndPersist;
pub const arrange = output_layout.arrange;
pub const refreshConfiguration = output_layout.refreshConfiguration;
pub const setDisplayScale = output_layout.setDisplayScale;
pub const applyConfig = output_layout.applyConfig;
pub const syncLayout = output_layout.syncLayout;
pub const evacuateWindows = output_layout.evacuateWindows;
pub const restoreReconnectedWindows = output_layout.restoreReconnectedWindows;

pub const Placement = struct { output: *Output, x: i32, y: i32 };

// The wlr.Output should be destroyed by the caller on failure to trigger cleanup.
/// The kernel DRM driver of a DRM output when it is a hypervisor's virtual GPU.
fn virtualGpuDriver(wlr_output: *wlr.Output) ?[]const u8 {
    if (!wlr_output.isDrm()) return null;
    const fd = wlr_output.backend.getDrmFd();
    if (fd < 0) return null;
    // struct drm_version; only the name is asked for.
    const Version = extern struct {
        major: c_int = 0,
        minor: c_int = 0,
        patch: c_int = 0,
        name_len: usize,
        name: [*]u8,
        date_len: usize = 0,
        date: ?[*]u8 = null,
        desc_len: usize = 0,
        desc: ?[*]u8 = null,
    };
    const DRM_IOCTL_VERSION = std.os.linux.IOCTL.IOWR('d', 0x00, Version);
    var name: [32]u8 = undefined;
    var version: Version = .{ .name_len = name.len, .name = &name };
    if (std.os.linux.errno(std.os.linux.ioctl(fd, DRM_IOCTL_VERSION, @intFromPtr(&version))) != .SUCCESS) return null;
    const driver = name[0..@min(version.name_len, name.len)];
    for ([_][]const u8{ "vmwgfx", "vboxvideo", "virtio_gpu", "qxl", "bochs-drm", "cirrus", "cirrus-qemu", "hyperv_drm" }) |known| {
        if (std.mem.eql(u8, driver, known)) return known;
    }
    return null;
}

pub fn create(server: *Server, wlr_output: *wlr.Output) !void {
    const output = try gpa.create(Output);
    errdefer gpa.destroy(output); // listeners are attached last, so this cannot double-free with handleDestroy

    output.* = .{
        .server = server,
        .wlr_output = wlr_output,
        .lock_view = try @import("session/lock.zig").View.create(server.lock_tree),
    };

    errdefer output.lock_view.tree.node.destroy();
    if (virtualGpuDriver(wlr_output)) |driver| {
        // These drivers' cursor planes are often invisible in the guest
        // (VMware, VirtualBox): draw the cursor in the frame instead.
        wlr_output.lockSoftwareCursors(true);
        log.info("{s}: software cursor ({s} virtual GPU)", .{ wlr_output.name, driver });
    }
    output.vblank_timer = server.wl_server.getEventLoop().addTimer(*Output, handleVblank, output) catch null;
    errdefer if (output.vblank_timer) |timer| timer.remove();

    // Layout entry and scene output are addons on `wlr_output`. On error the
    // caller destroys that output, which is safer than a second explicit
    // destroy (that would double-free the addon).
    const layout_output = blk: {
        const name = std.mem.span(wlr_output.name);
        for (server.config.outputs) |placement| {
            if (std.mem.eql(u8, placement.name, name) and (placement.x != null or placement.y != null)) {
                break :blk try server.output_layout.add(wlr_output, placement.x orelse 0, placement.y orelse 0);
            }
        }
        break :blk try server.output_layout.addAuto(wlr_output);
    };
    _ = try server.scene_outputs.createOutput(wlr_output, layout_output);

    server.output_layout.getBox(wlr_output, &output.cached_box);

    if (server.wallpaper) |image| {
        output.wallpaper = server.background_tree.createSceneBuffer(&image.base) catch |err| blk: {
            log.err("Output.create: could not create wallpaper node: {}", .{err});
            break :blk null;
        };
        if (output.wallpaper) |node| node.setFilterMode(.bilinear);
    }
    output.taskbar = Taskbar.create(server, wlr_output) catch |err| blk: {
        log.warn("Output.create: could not create taskbar: {}", .{err});
        break :blk null;
    };

    // Listeners last so a failure above cannot fire handleDestroy on a
    // half-built Output, and the caller's wlr_output.destroy() will not
    // double-free us.
    wlr_output.data = output;
    wlr_output.events.frame.add(&output.frame);
    wlr_output.events.present.add(&output.present);
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.destroy.add(&output.destroy);
    server.outputs.append(output);
    server.input.refreshOutputScales();

    // Apply the saved enable policy before publishing the added event so
    // observers see the final logical state in one coherent notification.
    output.applyConfig();
    server.reveal.outputCreated(output);

    if (server.locker != null) output.lock_view.cover(output);
    syncLayout(server);
    restoreReconnectedWindows(output);
    syncLayout(server);
    // A display plugged into a closed laptop takes over from its panel.
    applyLid(server);
    output.server.night_light.retargetOutput(output);

    if (server.idle) |im| im.recheckInhibitors();

    if (server.ipc) |ipc| {
        events.onOutputAdded(ipc, output);
    }
}

pub fn fromWlr(wlr_output: *wlr.Output) ?*Output {
    const data = wlr_output.data orelse return null;
    const output: *Output = @ptrCast(@alignCast(data));
    if (output.wlr_output != wlr_output) return null;
    return output;
}

pub fn atLayout(server: *Server, lx: f64, ly: f64) ?*Output {
    if (server.output_layout.outputAt(lx, ly)) |wlr_output| {
        if (fromWlr(wlr_output)) |output| if (output.isLogicallyEnabled()) return output;
    }
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!output.isLogicallyEnabled()) continue;
        const box = output.cached_box;
        const x: i32 = @intFromFloat(lx);
        const y: i32 = @intFromFloat(ly);
        if (x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + box.height) {
            return output;
        }
    }
    return null;
}

/// The output without the taskbar's reserved strip (the bar and its gap; a
/// short bar leaves the strip beside it whole). The dock sits in this box and
/// the taskbar's popups open against it: neither is placed around the dock.
pub fn dockAreaBox(output: *Output) wlr.Box {
    var box: wlr.Box = if (output.idle_blanked) output.cached_box else blk: {
        var b: wlr.Box = undefined;
        output.server.output_layout.getBox(output.wlr_output, &b);
        break :blk b;
    };
    if (output.taskbar) |bar| {
        if (output.server.config.compositor.taskbar_position == .top) box.y += bar.reserved;
        box.height = @max(1, box.height - bar.reserved);
    }
    return box;
}

/// The output's usable area for compositor-driven placement (maximize, tiles,
/// new windows, popups): `dockAreaBox` less the strip a docked (not
/// auto-hiding) dock claims. Windows never open or maximize behind either.
pub fn usableBox(output: *Output) wlr.Box {
    var box = output.dockAreaBox();
    const strip = @import("Dock.zig").reservedStrip(output.server, box);
    if (strip == 0) return box;
    switch (output.server.config.compositor.dock_position) {
        .top => box.y += strip,
        .left => box.x += strip,
        .bottom, .right => {},
    }
    if (output.server.config.compositor.dock_position.vertical()) {
        box.width = @max(1, box.width - strip);
    } else box.height = @max(1, box.height - strip);
    return box;
}

/// Place a taskbar popup on the inward side of the selected edge.
pub fn taskbarPopupY(output: *Output, height: i32, gap: i32) i32 {
    const box = output.dockAreaBox();
    return if (output.server.config.compositor.taskbar_position == .top)
        box.y + gap
    else
        @max(box.y, box.y + box.height - height - gap);
}

pub fn setIdleBlanked(output: *Output, requested: bool) bool {
    const blanked = requested or output.lid_blanked;
    if (output.user_disabled) return false;
    if (output.idle_blanked == blanked) return true;
    output.idle_blanked = blanked;
    var state = wlr.Output.State.init();
    defer state.finish();
    if (blanked) {
        if (output.lock_commit_pending) {
            // A dark output shows nothing to hide from a lock client.
            output.lock_commit_pending = false;
            if (output.server.locker) |lock| lock.outputCovered();
        }
        if (output.server.switcher.output == output) output.server.switcher.cancel();
        output.osd.hide();
        state.setEnabled(false);
        const ok = output.wlr_output.commitState(&state);
        if (!ok) {
            output.idle_blanked = false;
            log.err("setIdleBlanked: disabling commit failed for {s}", .{output.wlr_output.name});
        } else if (output.server.capture_mgr) |cm| {
            // A disabled output stops getting frame commits, so any capture
            // session on it would otherwise hang waiting for a frame that
            // never completes (docs/screen-sharing.md's failure contract:
            // "Output idle blanking -> Initially close affected monitor
            // streams").
            cm.stopForOutput(output.wlr_output, @import("capture/manager.zig").failure_output_idle);
        }
        return ok;
    } else {
        state.setEnabled(true);
        state.setScale(output.wlr_output.scale);
        // Wake the mode that was in use, including backend-requested modes.
        if (output.wlr_output.current_mode) |mode| {
            state.setMode(mode);
        } else {
            state.setCustomMode(output.wlr_output.width, output.wlr_output.height, output.wlr_output.refresh);
        }
        const ok = output.wlr_output.commitState(&state);
        if (ok) {
            output.applyConfig();
            syncLayout(output.server);
            output.color.key = null;
            output.server.night_light.retargetOutput(output);
            output.wlr_output.scheduleFrame();
        } else {
            output.idle_blanked = true;
            log.err("setIdleBlanked: enabling commit failed for {s}", .{output.wlr_output.name});
        }
        return ok;
    }
}

// output/panels.zig
pub const toggleStartMenu = output_panels.toggleStartMenu;
pub const openStartMenu = output_panels.openStartMenu;
pub const toggleAppLauncher = output_panels.toggleAppLauncher;
pub const openMenu = output_panels.openMenu;
pub const closeStartMenu = output_panels.closeStartMenu;
pub const syncStartMenu = output_panels.syncStartMenu;
pub const toggleControlCenter = output_panels.toggleControlCenter;
pub const openNetworkSettings = output_panels.openNetworkSettings;
pub const closeControlCenter = output_panels.closeControlCenter;
pub const openPowerMenu = output_panels.openPowerMenu;
pub const closePowerMenu = output_panels.closePowerMenu;
pub const syncPowerMenu = output_panels.syncPowerMenu;
pub const closeCalendar = output_panels.closeCalendar;
pub const toggleCalendar = output_panels.toggleCalendar;
pub const closeBattery = output_panels.closeBattery;
pub const toggleBattery = output_panels.toggleBattery;
pub const closeWifi = output_panels.closeWifi;
pub const toggleWifi = output_panels.toggleWifi;

pub fn syncTaskbar(output: *Output) void {
    if (output.calendar) |calendar| calendar.refresh();
    const bar = output.taskbar orelse return;
    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return;
    bar.relayout(box);
}

// output/wallpaper.zig
pub const replaceWallpaper = output_wallpaper.replaceWallpaper;
pub const syncWallpaper = output_wallpaper.syncWallpaper;

// output/frame.zig
pub const commitFrameState = output_frame.commitFrameState;
pub const commitIsRedundant = output_frame.commitIsRedundant;
pub const refreshPeriodNs = output_frame.refreshPeriodNs;
pub const deferFrameDone = output_frame.deferFrameDone;
pub const handleVblank = output_frame.handleVblank;
pub const frameCallbacksWanted = output_frame.frameCallbacksWanted;
pub const sendFrameDone = output_frame.sendFrameDone;
pub const tearingAllowed = output_frame.tearingAllowed;
pub const queueTearing = output_frame.queueTearing;
pub const tearingIdle = output_frame.tearingIdle;
pub const handleFrame = output_frame.handleFrame;
pub const runFrame = output_frame.runFrame;
pub const setDisplayMode = output_frame.setDisplayMode;
pub const handleRequestState = output_frame.handleRequestState;
pub const handlePresent = output_frame.handlePresent;
pub const startupVisible = output_frame.startupVisible;

pub const CursorState = struct {
    cursor: ?*wlr.OutputCursor = null,
    buffer: ?*wlr.Buffer = null,
    x: f64 = 0,
    y: f64 = 0,
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
    enabled: bool = false,
    visible: bool = false,

    pub fn of(wlr_output: *wlr.Output) CursorState {
        const hw = wlr_output.hardware_cursor orelse return .{ .buffer = wlr_output.cursor_front_buffer };
        return .{
            .cursor = hw,
            .buffer = wlr_output.cursor_front_buffer,
            .x = hw.x,
            .y = hw.y,
            .hotspot_x = hw.hotspot_x,
            .hotspot_y = hw.hotspot_y,
            .enabled = hw.enabled,
            .visible = hw.visible,
        };
    }
};

pub fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("destroy", listener);
    if (output.tearing_idle) |source| source.remove();
    output.tearing_idle = null;
    if (output.server.screenshot_selector.output == output) output.server.screenshot_selector.cancel();
    if (output.server.screenshot_mgr) |mgr| mgr.cancelForOutput(output);
    const server = output.server;
    // Exclude the dying connector from fallback selection before removing its
    // layout entry. The saved logical box remains available in each snapshot.
    evacuateWindows(output);

    // Exclude the dying output before any scene mutation (including input
    // cleanup). Otherwise uncovering a surface can send it an output-enter
    // and attach a bind listener which misses the in-progress destroy signal,
    // causing wlr_output_finish() to assert. The scene output removes its
    // addons when explicitly destroyed, so wlroots won't destroy it twice.
    if (server.scene_outputs.get(output.wlr_output)) |scene_output| {
        scene_output.destroy();
    }
    // Remove the layout entry now so remaining automatic positions have
    // settled before we cache their boxes and rebuild output-local UI.
    server.output_layout.remove(output.wlr_output);

    // Pre-empt capture teardown explicitly rather than rely on wlroots' own
    // source (see docs/screen-sharing.md's failure contract: "Output
    // unplug/disable or window destruction/minimize -> End the selected
    // source's session"). This must run after the scene exclusion above: it
    // can disconnect a client that also owns mapped surfaces on this output,
    // and destroying those surfaces' scene nodes while `dying`'s scene
    // output link still existed is exactly the hazard that exclusion avoids
    // (confirmed by output_destroy_hook.c's assertion during test-writing).
    if (server.capture_mgr) |cm| cm.stopForOutput(output.wlr_output, @import("capture/manager.zig").failure_output_destroyed);

    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |toplevel| {
        if (toplevel.wlr_foreign) |handle| handle.forgetOutput(output.wlr_output);
    }
    output.lock_commit_pending = false;
    if (server.locker) |lock| {
        if (lock.client) |client| client.forgetOutput(output);
        lock.outputCovered();
    }

    const name_slice = std.mem.span(output.wlr_output.name);
    if (server.ipc) |ipc| {
        events.onOutputRemoved(ipc, name_slice);
    }

    server.input.detachOutput(output);
    if (output.server.switcher.output == output) output.server.switcher.cancel();
    server.world.mini_map.outputRemoved(output);
    output.osd.deinit();
    output.lock_view.tree.node.destroy();

    if (output.wallpaper) |node| node.node.destroy();
    output.dock.deinit();
    if (output.taskbar) |bar| bar.destroy();
    output.closeCalendar();
    output.closeBattery();
    output.closeWifi();
    if (output.server.polkit_dialog) |dialog| {
        if (dialog.output == output.wlr_output) dialog.cancel();
    }
    if (output.server.input.open_control_center) |cc| if (cc.wlr_output == output.wlr_output) {
        // The window stays; only its frame clock and default display move.
        var others = output.server.outputs.iterator(.forward);
        const next = while (others.next()) |other| {
            if (other != output and other.wlr_output.enabled) break other;
        } else null;
        if (next) |other| cc.adoptOutput(other.wlr_output) else cc.close();
    };
    if (output.start_menu) |sm| sm.destroy();
    if (output.power_menu) |pm| pm.destroy();
    output.color.deinit();
    if (output.vblank_timer) |timer| timer.remove();
    if (output.callback_idle) |idle| idle.remove();
    output.link.remove();
    output.frame.link.remove();
    output.present.link.remove();
    output.request_state.link.remove();
    output.destroy.link.remove();

    // The destroy signal runs before wlroots tears down the layout addon, so
    // outputAt() can still return this wlr_output. Clear userdata first so
    // fromWlr/atLayout cannot hand out a freed Output.
    output.wlr_output.data = null;
    if (server.desktop) |desktop| desktop.outputRemoved(output);
    server.world.workspaces.forgetOutput(output);
    gpa.destroy(output);
    server.input.refreshOutputScales();
    syncLayout(server);
    // Unplugging the last external display brings back a closed laptop's panel.
    applyLid(server);
    if (server.idle) |im| im.recheckInhibitors();
}

// Logical pixels to device pixels, never rounding down to nothing.
pub fn scaled(value: i32, scale: f32) i32 {
    return geometry.devicePixels(value, scale);
}

/// Recompute camera bounds from the union of all output layout boxes.
pub fn recomputeWorldBounds(server: *Server) void {
    var min_x: i32 = 0;
    var min_y: i32 = 0;
    var max_x: i32 = 0;
    var max_y: i32 = 0;
    var first = true;

    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!output.isLogicallyEnabled()) continue;
        const box = if (output.idle_blanked) output.cached_box else blk: {
            var b: wlr.Box = undefined;
            server.output_layout.getBox(output.wlr_output, &b);
            break :blk b;
        };
        if (box.width <= 0 or box.height <= 0) continue;
        if (first) {
            min_x = box.x;
            min_y = box.y;
            max_x = box.x + box.width;
            max_y = box.y + box.height;
            first = false;
        } else {
            if (box.x < min_x) min_x = box.x;
            if (box.y < min_y) min_y = box.y;
            if (box.x + box.width > max_x) max_x = box.x + box.width;
            if (box.y + box.height > max_y) max_y = box.y + box.height;
        }
    }

    const w = max_x - min_x;
    const h = max_y - min_y;
    server.world.initBounds(min_x, min_y, w, h);

    if (first) {
        // No remaining outputs: drop an in-progress pan rather than rebase it
        // against an empty layout.
        if (server.input.cursor_mode == .pan) {
            server.input.endPan();
            server.input.pan_session = null;
        }
        server.world.snapCamera();
    } else {
        // Resize/hotplug must not kill a live Super or middle-button pan — the
        // nested backend sends request_state whenever the host window resizes,
        // and cancelling here left middle-button held with no press to restart.
        server.input.rebasePan();
        if (server.world.panning) {
            server.world.rebindPan();
        } else {
            server.world.snapCamera();
            server.world.camera.clamp(server.world.bounds);
        }
    }
    server.world.applyCamera();
}

pub fn timestamp() posix.timespec {
    var timespec: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &timespec))) {
        .SUCCESS => return timespec,
        else => {
            // Safer than panicking: presentation timestamps of zero skip
            // a frame's feedback rather than taking down the compositor.
            log.err("timestamp: CLOCK_MONOTONIC not available", .{});
            return .{ .sec = 0, .nsec = 0 };
        },
    }
}
