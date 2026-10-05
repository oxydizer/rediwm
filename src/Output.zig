const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");

const ControlCenter = @import("control_center/panel.zig").ControlCenter;
const StartMenu = @import("start_menu/panel.zig").StartMenu;
const PowerMenu = @import("power_menu.zig").PowerMenu;
const Server = @import("Server.zig");
const ImageBuffer = @import("ImageBuffer.zig");
const Taskbar = @import("Taskbar.zig");
const anim = @import("ui").anim;
const geometry = @import("geometry.zig");
const glass = @import("glass.zig");
const events = @import("ipc/events.zig");
const stats = @import("ipc/stats.zig");
const gpa = @import("main.zig").gpa;
const output_transform = @import("config").output_transform;

pub extern fn wlr_color_transform_init_lut_3x1d(
    dim: usize,
    r: [*]const u16,
    g: [*]const u16,
    b: [*]const u16,
) ?*wlr.ColorTransform;

pub extern fn wlr_color_transform_unref(tr: *wlr.ColorTransform) void;

pub extern fn wlr_output_state_set_color_transform(
    state: *wlr.Output.State,
    tr: ?*wlr.ColorTransform,
) void;

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
server: *Server,
wlr_output: *wlr.Output,
wallpaper: ?*wlr.SceneBuffer = null,
taskbar: ?*Taskbar = null,
osd: @import("osd.zig") = .{},
start_menu: ?*StartMenu = null,
calendar: ?*@import("calendar.zig").Calendar = null,
battery_popup: ?*@import("battery_popup.zig").Popup = null,
wifi_popup: ?*@import("network/popup.zig").Popup = null,
power_menu: ?*PowerMenu = null,
color: OutputColor = .{},
frame_seq: u64 = 0,
animation_budget: anim.FrameBudget = .{},
idle_blanked: bool = false,
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
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
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
fn lidHides(output: *const Output) bool {
    const server = output.server;
    if (!server.input.lid.closed or server.config.compositor.lid_close == .ignore) return false;
    return isBuiltinPanel(std.mem.span(output.wlr_output.name)) and otherDisplayOn(server);
}

/// Re-applies the lid policy after the lid, the outputs or the setting change.
pub fn applyLid(server: *Server) void {
    var changed = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (!isBuiltinPanel(std.mem.span(output.wlr_output.name))) continue;
        if (lidHides(output) == output.user_disabled) continue;
        output.applyConfig();
        changed = true;
    }
    if (changed) syncLayout(server);
}

pub fn configured(server: *Server, out: *wlr.Output) ?@import("config").loader.OutputConfig {
    for (server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(out.name))) return config;
    }
    return null;
}

pub fn configuredTransform(server: *Server, out: *wlr.Output) output_transform.Transform {
    return (configured(server, out) orelse return .normal).transform;
}

fn wlTransform(transform: output_transform.Transform) wl.Output.Transform {
    return switch (transform) {
        .normal => .normal,
        .@"90" => .@"90",
        .@"180" => .@"180",
        .@"270" => .@"270",
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
    };
}

pub fn configuredScale(server: *Server, out: *wlr.Output) f32 {
    return scaleForDimensions(server, out, out.width, out.height);
}

pub fn scaleForMode(server: *Server, out: *wlr.Output, mode: ?*wlr.Output.Mode) f32 {
    return scaleForDimensions(server, out, if (mode) |m| m.width else out.width, if (mode) |m| m.height else out.height);
}

pub fn scaleForDimensions(server: *Server, out: *wlr.Output, width: i32, height: i32) f32 {
    if (server.scale_override) |scale| return scale;
    for (server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(out.name))) {
            if (config.scale) |scale| return scale;
            break;
        }
    }
    return automaticScale(server, out, width, height);
}

pub fn automaticScale(server: *Server, out: *wlr.Output, width: i32, height: i32) f32 {
    if (server.scale_override) |scale| return scale;
    // Nested outputs describe a host window, not necessarily a physical panel.
    if (!out.isDrm()) return 1;
    return @import("output_scale.zig").calculate(
        width,
        height,
        out.phys_width,
        out.phys_height,
    );
}

/// Resolve advertised modes first, then standard lower-resolution candidates.
pub fn configuredMode(server: *Server, out: *wlr.Output) ?@import("output_modes.zig").Choice {
    for (server.config.outputs) |config| {
        if (!std.mem.eql(u8, config.name, std.mem.span(out.name))) continue;
        const width = config.width orelse continue;
        const height = config.height orelse continue;
        return resolveDisplayMode(out, width, height, config.refresh_mhz);
    }
    return null;
}

fn resolveDisplayMode(out: *wlr.Output, width: i32, height: i32, refresh: ?i32) ?@import("output_modes.zig").Choice {
    var best: ?*wlr.Output.Mode = null;
    var it = out.modes.iterator(.forward);
    while (it.next()) |mode| {
        if (mode.width != width or mode.height != height) continue;
        if (refresh) |rate| {
            if (mode.refresh == rate) return @import("output_modes.zig").Choice.fromMode(mode);
        } else if (best == null or mode.refresh > best.?.refresh) best = mode;
    }
    if (best) |mode| return @import("output_modes.zig").Choice.fromMode(mode);
    return @import("output_modes.zig").customChoice(out, width, height, refresh);
}

/// Apply and persist one output patch, shared by IPC and Settings. Mode and scale
/// are tested/committed together; a failed publication restores the previous state.
pub fn applyAndPersist(output: *Output, requested: @import("config").output_config.Patch) !void {
    try requested.validate();
    if (output.idle_blanked and (requested.enabled == null or requested.enabled == false)) return error.OutputUnavailable;
    const out = output.wlr_output;
    const server = output.server;
    var patch = requested;
    if (patch.scale) |scale| patch.scale = @round(scale * 120) / 120;
    if ((patch.scale != null or patch.auto_scale) and server.scale_override != null) return error.ScaleOverridden;

    if (patch.enabled == false and output.isLogicallyEnabled()) {
        var enabled_count: usize = 0;
        var outputs = server.outputs.iterator(.forward);
        while (outputs.next()) |candidate| {
            if (candidate.isLogicallyEnabled()) enabled_count += 1;
        }
        if (enabled_count <= 1) return error.LastOutput;
    }

    var saved: @import("config").loader.OutputConfig = .{};
    for (server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(out.name))) {
            saved = config;
            break;
        }
    }
    var state = wlr.Output.State.init();
    defer state.finish();
    const mode_changed = patch.width != null or patch.height != null or patch.refresh_mhz != null;
    var width = out.width;
    var height = out.height;
    if (mode_changed) {
        width = patch.width orelse saved.width orelse out.width;
        height = patch.height orelse saved.height orelse out.height;
        if (width > 32768 or height > 32768) return error.InvalidOutputConfig;
        const refresh = patch.refresh_mhz orelse saved.refresh_mhz;
        const mode = resolveDisplayMode(out, width, height, refresh) orelse return error.RejectedMode;
        mode.setState(&state);
        patch.width = mode.width;
        patch.height = mode.height;
        patch.refresh_mhz = mode.refresh;
    }
    const scale_changed = patch.scale != null or patch.auto_scale or mode_changed;
    if (scale_changed) {
        const scale = if (patch.auto_scale)
            automaticScale(server, out, width, height)
        else
            patch.scale orelse scaleForDimensions(server, out, width, height);
        state.setScale(scale);
        if (!mode_changed and !out.isDrm() and out.modes.empty() and scale != out.scale) {
            const logical_width: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(out.width)) / out.scale));
            const logical_height: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(out.height)) / out.scale));
            state.setCustomMode(scaled(logical_width, scale), scaled(logical_height, scale), out.refresh);
        }
    }
    // Pin the other axis to its current position when leaving automatic placement.
    if (patch.x != null or patch.y != null) {
        var box: wlr.Box = undefined;
        server.output_layout.getBox(out, &box);
        patch.x = patch.x orelse saved.x orelse box.x;
        patch.y = patch.y orelse saved.y orelse box.y;
    }
    const transform_changed = patch.transform != null and wlTransform(patch.transform.?) != out.transform;
    if (transform_changed) state.setTransform(wlTransform(patch.transform.?));
    const changes_state = mode_changed or scale_changed or transform_changed;
    if (changes_state and !out.testState(&state)) return error.RejectedMode;
    var prepared = @import("config").output_save.prepare(gpa, server.io, server.config.path, std.mem.span(out.name), patch, server.environ) catch |err| {
        log.warn("could not stage output settings: {}", .{err});
        return error.OutputSaveFailed;
    };
    defer prepared.deinit();

    var previous = wlr.Output.State.init();
    defer previous.finish();
    previous.setScale(out.scale);
    previous.setTransform(out.transform);
    if (out.current_mode) |mode| previous.setMode(mode) else previous.setCustomMode(out.width, out.height, out.refresh);
    if (changes_state and !out.commitState(&state)) return error.RejectedMode;
    prepared.publish() catch |err| {
        log.warn("could not publish output settings: {}", .{err});
        if (changes_state) {
            const restored = out.commitState(&previous);
            output.refreshConfiguration();
            if (!restored) return error.OutputRollbackFailed;
        }
        return error.OutputSaveFailed;
    };
    const config = prepared.config.?;
    prepared.config = null; // Ownership moves into the server.
    @import("config_runtime/watcher.zig").applyLoadedConfig(server, config);
    output.refreshConfiguration();
}

pub const Placement = struct { output: *Output, x: i32, y: i32 };

/// Moves outputs to new layout positions (Settings' display arrangement).
/// Each is saved like any display change and pinned, so automatic placement
/// can't shuffle it later. Windows ride along with their output, as on other
/// desktops. A failure stops the remaining moves but still carries the
/// windows of the outputs that did move.
pub fn arrange(server: *Server, placements: []const Placement) !void {
    const Toplevel = @import("Toplevel.zig");
    const Carried = struct {
        toplevel: *Toplevel,
        output: *Output,
        from: wlr.Box,
        /// Layout position before the move: the camera may change with the bounds.
        layout_x: i32,
        layout_y: i32,
    };
    var carried: std.ArrayList(Carried) = .empty;
    defer carried.deinit(gpa);
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |toplevel| {
        if (!toplevel.in_world) continue;
        const center = toplevel.frameWorld(@floatFromInt(@divTrunc(toplevel.chrome_width, 2)), @floatFromInt(@divTrunc(toplevel.chrome_height, 2)));
        const layout_center = server.world.toLayout(center.x, center.y);
        // Only windows actually shown on an output; canvas beyond them stays put.
        const output = atLayout(server, layout_center.x, layout_center.y) orelse continue;
        var from: wlr.Box = undefined;
        server.output_layout.getBox(output.wlr_output, &from);
        const position = server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
        try carried.append(gpa, .{
            .toplevel = toplevel,
            .output = output,
            .from = from,
            .layout_x = @intFromFloat(@round(position.x)),
            .layout_y = @intFromFloat(@round(position.y)),
        });
    }

    var failure: ?anyerror = null;
    for (placements) |placement| {
        const out = placement.output.wlr_output;
        var box: wlr.Box = undefined;
        server.output_layout.getBox(out, &box);
        const pinned = if (configured(server, out)) |config| config.x != null and config.y != null else false;
        if (pinned and box.x == placement.x and box.y == placement.y) continue;
        placement.output.applyAndPersist(.{ .x = placement.x, .y = placement.y }) catch |err| {
            log.warn("output {s}: could not move to {d},{d}: {}", .{ out.name, placement.x, placement.y, err });
            failure = err;
            break;
        };
    }

    for (carried.items) |entry| {
        const toplevel = entry.toplevel;
        if (!toplevel.in_world or !entry.output.isAvailable()) continue;
        var to: wlr.Box = undefined;
        server.output_layout.getBox(entry.output.wlr_output, &to);
        if (to.x == entry.from.x and to.y == entry.from.y) continue;
        if (toplevel.isMaximized() or toplevel.isFullscreen() or toplevel.tile != null) {
            _ = toplevel.moveToOutput(entry.output);
            continue;
        }
        toplevel.finishMoveAnimation();
        const world = server.world.toWorld(@floatFromInt(entry.layout_x + to.x - entry.from.x), @floatFromInt(entry.layout_y + to.y - entry.from.y));
        toplevel.setPosition(@intFromFloat(@round(world.x)), @intFromFloat(@round(world.y)));
    }
    if (carried.items.len > 0) server.scheduleFrames();
    if (failure) |err| return err;
}

fn refreshConfiguration(output: *Output) void {
    output.server.input.refreshOutputScales();
    if (output.taskbar) |bar| bar.notifyToplevelsChanged();
    syncLayout(output.server);
    output.color.key = null;
    output.server.night_light.retargetOutput(output);
    if (output.server.idle) |im| im.recheckInhibitors();
    output.wlr_output.scheduleFrame();
}

/// Apply a density change without changing a nested/headless output's logical size.
pub fn setDisplayScale(output: *Output, scale: f32) bool {
    const out = output.wlr_output;
    if (!std.math.isFinite(scale) or scale <= 0 or scale > 16) return false;
    if (scale == out.scale) return true;
    var state = wlr.Output.State.init();
    defer state.finish();
    state.setScale(scale);
    if (!out.isDrm() and out.modes.empty()) {
        const width: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(out.width)) / out.scale));
        const height: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(out.height)) / out.scale));
        state.setCustomMode(scaled(width, scale), scaled(height, scale), out.refresh);
    }
    if (!out.testState(&state) or !out.commitState(&state)) return false;
    output.server.input.refreshOutputScales();
    if (output.taskbar) |bar| bar.notifyToplevelsChanged();
    out.scheduleFrame();
    return true;
}

/// Apply saved mode, scale and placement. Defer modesets until an output wakes.
pub fn applyConfig(output: *Output) void {
    const out = output.wlr_output;
    const saved = configured(output.server, out);
    const want_enabled = (if (saved) |config| config.enabled else true) and !lidHides(output);
    if (!want_enabled) {
        if (!output.user_disabled) evacuateWindows(output);
        if (out.enabled) {
            var disable = wlr.Output.State.init();
            defer disable.finish();
            disable.setEnabled(false);
            if (!out.commitState(&disable)) {
                output.user_disabled = false;
                log.warn("output {s}: saved disabled state rejected", .{out.name});
            }
        }
        syncLayout(output.server);
        return;
    }

    if (output.idle_blanked) {
        output.user_disabled = false;
        return;
    }

    const was_disabled = output.user_disabled or !out.enabled;
    output.user_disabled = false;
    if (was_disabled and !out.enabled) {
        var enable = wlr.Output.State.init();
        defer enable.finish();
        enable.setEnabled(true);
        if (out.current_mode) |mode| enable.setMode(mode) else enable.setCustomMode(out.width, out.height, out.refresh);
        enable.setScale(configuredScale(output.server, out));
        enable.setTransform(wlTransform(configuredTransform(output.server, out)));
        if (!out.testState(&enable) or !out.commitState(&enable)) {
            output.user_disabled = true;
            log.warn("output {s}: saved enabled state rejected", .{out.name});
            syncLayout(output.server);
            return;
        }
    }
    if (!output.idle_blanked and !output.user_disabled) {
        if (configuredMode(output.server, out)) |mode| {
            const transform_changed = out.transform != wlTransform(configuredTransform(output.server, out));
            if (out.width != mode.width or out.height != mode.height or out.refresh != mode.refresh or transform_changed) {
                var mode_state = wlr.Output.State.init();
                defer mode_state.finish();
                mode.setState(&mode_state);
                if (transform_changed) mode_state.setTransform(wlTransform(configuredTransform(output.server, out)));
                if (!out.testState(&mode_state) or !out.commitState(&mode_state)) {
                    log.warn("output {s}: saved display mode rejected", .{out.name});
                } else {
                    output.color.key = null;
                    output.server.night_light.retargetOutput(output);
                    out.scheduleFrame();
                }
            }
        } else if (out.transform != wlTransform(configuredTransform(output.server, out))) {
            var transform_state = wlr.Output.State.init();
            defer transform_state.finish();
            transform_state.setTransform(wlTransform(configuredTransform(output.server, out)));
            if (!out.testState(&transform_state) or !out.commitState(&transform_state)) {
                log.warn("output {s}: saved transform rejected", .{out.name});
            }
        }
    }
    const scale = configuredScale(output.server, out);
    if (!output.setDisplayScale(scale)) {
        log.err("output {s}: cannot apply scale {d}", .{ out.name, scale });
        return;
    }
    if (output.idle_blanked or output.user_disabled) return;
    var placed = false;
    for (output.server.config.outputs) |config| {
        if (std.mem.eql(u8, config.name, std.mem.span(out.name)) and (config.x != null or config.y != null)) {
            _ = output.server.output_layout.add(out, config.x orelse 0, config.y orelse 0) catch {};
            placed = true;
            break;
        }
    }
    if (!placed) _ = output.server.output_layout.addAuto(out) catch {};
    restoreReconnectedWindows(output);
}

/// Automatic layout can move existing outputs when a neighbour changes size.
pub fn syncLayout(server: *Server) void {
    server.world.mini_map.reconfigure();
    server.screenshot_selector.cancel();
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.idle_blanked or output.user_disabled) {
            if (output.server.switcher.output == output) output.server.switcher.cancel();
            output.osd.hide();
            continue;
        }
        server.output_layout.getBox(output.wlr_output, &output.cached_box);
        output.syncWallpaper();
        output.syncTaskbar();
        output.syncStartMenu();
        output.syncPowerMenu();
        if (server.input.open_control_center) |cc| cc.refresh();
        if (server.ipc) |ipc| events.onOutputChanged(ipc, output);
    }
    var layers = server.layer_surfaces.iterator(.forward);
    while (layers.next()) |layer| {
        if (!layer.layer.initialized) continue;
        const out = fromWlr(layer.layer.output orelse continue) orelse continue;
        if (!out.idle_blanked and !out.user_disabled) layer.arrange();
    }
    recomputeWorldBounds(server);
    if (server.desktop) |desktop| desktop.syncLayout();
    if (server.output_management) |om| om.publish();
    server.input.touch.remap();
}

fn evacuateWindows(output: *Output) void {
    const server = output.server;
    const Displaced = struct {
        toplevel: *@import("Toplevel.zig"),
        source_box: wlr.Box,
    };
    var displaced: std.ArrayList(Displaced) = .empty;
    defer displaced.deinit(gpa);
    const source_box = output.usableBox();
    const source_name = std.mem.span(output.wlr_output.name);
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |toplevel| {
        if (!toplevel.in_world or toplevel.currentOutput() != output) continue;
        toplevel.rememberOutputDisconnect(source_name, source_box);
        displaced.append(gpa, .{ .toplevel = toplevel, .source_box = source_box }) catch {
            log.warn("output {s}: could not snapshot all windows for recovery", .{output.wlr_output.name});
            break;
        };
    }
    output.user_disabled = true;
    if (server.effectivePrimaryOutput()) |target| {
        for (displaced.items) |entry| {
            if (entry.toplevel.isMaximized()) {
                entry.toplevel.setMaximizedOn(target);
            } else if (entry.toplevel.isFullscreen()) {
                entry.toplevel.setFullscreenOn(target);
            } else if (entry.toplevel.tile) |tile| {
                entry.toplevel.setTiledOn(target, tile);
            } else {
                _ = entry.toplevel.moveFromUsableToOutput(entry.source_box, target);
            }
            entry.toplevel.markOutputDisconnectPosition();
        }
    }
}

fn restoreReconnectedWindows(output: *Output) void {
    if (!output.isAvailable()) return;
    var restored = false;
    var tops = output.server.world.toplevels.iterator(.forward);
    while (tops.next()) |toplevel| {
        if (toplevel.restoreOutputDisconnect(output)) restored = true;
    }
    if (restored) output.server.scheduleFrames();
}

// The wlr.Output should be destroyed by the caller on failure to trigger cleanup.
pub fn create(server: *Server, wlr_output: *wlr.Output) !void {
    const output = try gpa.create(Output);
    errdefer gpa.destroy(output); // listeners are attached last, so this cannot double-free with handleDestroy

    output.* = .{
        .server = server,
        .wlr_output = wlr_output,
        .lock_view = try @import("session/lock.zig").View.create(server.lock_tree),
    };

    errdefer output.lock_view.tree.node.destroy();
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
    const scene_output = try server.scene.createSceneOutput(wlr_output);
    server.scene_output_layout.addOutput(layout_output, scene_output);

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
    wlr_output.events.request_state.add(&output.request_state);
    wlr_output.events.destroy.add(&output.destroy);
    server.outputs.append(output);
    server.input.refreshOutputScales();

    // Apply the saved enable policy before publishing the added event so
    // observers see the final logical state in one coherent notification.
    output.applyConfig();

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

// The output's usable area for compositor-driven placement (currently just
// maximize), excluding the taskbar's reserved strip.
pub fn usableBox(output: *Output) wlr.Box {
    var box: wlr.Box = if (output.idle_blanked) output.cached_box else blk: {
        var b: wlr.Box = undefined;
        output.server.output_layout.getBox(output.wlr_output, &b);
        break :blk b;
    };
    if (output.taskbar) |bar| {
        if (output.server.config.compositor.taskbar_position == .top) box.y += bar.box.height;
        box.height = @max(1, box.height - bar.box.height);
    }
    return box;
}

/// Place a taskbar popup on the inward side of the selected edge.
pub fn taskbarPopupY(output: *Output, height: i32, gap: i32) i32 {
    const box = output.usableBox();
    return if (output.server.config.compositor.taskbar_position == .top)
        box.y + gap
    else
        @max(box.y, box.y + box.height - height - gap);
}

pub fn setIdleBlanked(output: *Output, blanked: bool) bool {
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

/// Opens (creating one if needed), closes, or cancels-and-reopens the
/// start menu, and keeps the taskbar's start button state in sync either
/// way. The single entry point for the start button's click handler.
pub fn toggleStartMenu(output: *Output) void {
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.start_menu) |sm| {
        if (sm.state != .closing) {
            output.closeStartMenu();
            return;
        }
    }
    output.openStartMenu();
}

/// Opens the start menu, reversing an in-flight close rather than waiting for
/// it to finish — the panel is still alive, so there is nothing to rebuild.
///
/// Every "open" path has to come through here. `closeStartMenu` drops
/// `input.open_start_menu` immediately, so that keystrokes during the close
/// slide reach the window underneath rather than a panel that is going away;
/// restoring it is therefore part of opening, and a caller that only called
/// `StartMenu.reopen` got a visible menu that no key could reach.
pub fn openStartMenu(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.start_menu) |sm| {
        if (sm.state != .closing) return;
        sm.reopen();
    } else {
        if (output.power_menu != null) output.closePowerMenu();
        output.start_menu = StartMenu.create(output.server, output.wlr_output) catch |err| blk: {
            log.err("openStartMenu: could not create panel: {}", .{err});
            break :blk null;
        };
    }
    output.server.input.open_start_menu = output.start_menu;
    if (output.start_menu) |sm| sm.buffer_node.node.raiseToTop();
    if (output.taskbar) |bar| {
        bar.start.open = true;
        bar.start.open_amt.retargetTo(Taskbar.nowMs(), 1, anim.curveFor(.start_button));
        bar.markDirty(Taskbar.paint_start);
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

pub fn closeStartMenu(output: *Output) void {
    const sm = output.start_menu orelse return;
    sm.beginClose();
    if (output.server.input.open_start_menu == sm) {
        output.server.input.open_start_menu = null;
    }
    if (output.taskbar) |bar| {
        bar.start.open = false;
        bar.start.open_amt.retargetTo(Taskbar.nowMs(), 0, anim.curveFor(.start_button));
        bar.markDirty(Taskbar.paint_start);
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

fn syncStartMenu(output: *Output) void {
    if (output.start_menu) |sm| sm.relayout();
}

/// Opens or raises settings, reversing an in-flight close if needed.
/// Opens the settings window on this output, or raises (and restores) the
/// existing one wherever it is. It keeps its page, position and size.
pub fn toggleControlCenter(output: *Output) void {
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.start_menu != null) output.closeStartMenu();
    if (output.power_menu != null) output.closePowerMenu();
    if (output.server.input.open_control_center) |cc| {
        cc.present();
    } else {
        _ = ControlCenter.create(output.server, output.wlr_output) catch |err| {
            log.err("openControlCenter: could not create settings window: {}", .{err});
        };
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

/// Closes the settings window, like its titlebar close button.
pub fn closeControlCenter(output: *Output) void {
    const cc = output.server.input.open_control_center orelse return;
    cc.close();
    output.wlr_output.scheduleFrame();
}

/// Opens (creating one if needed) or closes the power menu modal, and closes
/// the start menu first — the single entry point for the
/// start menu's power button click handler.
pub fn openPowerMenu(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.server.input.open_calendar) |calendar| calendar.output.closeCalendar();
    if (output.power_menu != null) return;
    if (output.start_menu != null) output.closeStartMenu();
    output.power_menu = PowerMenu.create(output.server, output.wlr_output) catch |err| blk: {
        log.err("openPowerMenu: could not create panel: {}", .{err});
        break :blk null;
    };
    output.server.input.open_power_menu = output.power_menu;
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

pub fn closePowerMenu(output: *Output) void {
    const pm = output.power_menu orelse return;
    pm.beginClose();
    if (output.server.input.open_power_menu == pm) {
        output.server.input.open_power_menu = null;
    }
    output.wlr_output.scheduleFrame();
    if (output.server.ipc) |ipc| ipc.wait_mgr.checkAll();
}

fn syncPowerMenu(output: *Output) void {
    if (output.server.polkit_dialog) |dialog| dialog.relayout();
    if (output.power_menu) |pm| pm.relayout();
}

pub fn closeCalendar(output: *Output) void {
    const calendar = output.calendar orelse return;
    output.calendar = null;
    calendar.destroy();
    output.wlr_output.scheduleFrame();
}

pub fn toggleCalendar(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.server.input.open_battery) |popup| popup.output.closeBattery();
    if (output.calendar != null) {
        output.closeCalendar();
        return;
    }
    if (output.server.input.open_calendar) |other| other.output.closeCalendar();
    output.closeStartMenu();
    output.closePowerMenu();
    output.calendar = @import("calendar.zig").Calendar.create(output) catch return;
    output.server.input.open_calendar = output.calendar;
}

pub fn closeBattery(output: *Output) void {
    const popup = output.battery_popup orelse return;
    output.battery_popup = null;
    popup.destroy();
    output.wlr_output.scheduleFrame();
}

pub fn toggleBattery(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.server.input.open_wifi) |popup| popup.output.closeWifi();
    if (output.battery_popup != null) {
        output.closeBattery();
        return;
    }
    if (output.server.input.open_battery) |other| other.output.closeBattery();
    if (output.server.input.open_calendar) |other| other.output.closeCalendar();
    output.closeStartMenu();
    output.closePowerMenu();
    output.battery_popup = @import("battery_popup.zig").Popup.create(output) catch return;
    output.server.input.open_battery = output.battery_popup;
}

pub fn closeWifi(output: *Output) void {
    const popup = output.wifi_popup orelse return;
    output.wifi_popup = null;
    popup.destroy();
    output.wlr_output.scheduleFrame();
}

pub fn toggleWifi(output: *Output) void {
    output.server.input.window_menu.close();
    if (output.wifi_popup != null) {
        output.closeWifi();
        return;
    }
    if (output.server.input.open_wifi) |other| other.output.closeWifi();
    if (output.server.input.open_battery) |other| other.output.closeBattery();
    if (output.server.input.open_calendar) |other| other.output.closeCalendar();
    if (output.server.input.open_start_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closeStartMenu();
    if (output.server.input.open_power_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closePowerMenu();
    if (output.server.tray) |tray| tray.closeMenu();
    output.wifi_popup = @import("network/popup.zig").Popup.create(output) catch return;
    output.server.input.open_wifi = output.wifi_popup;
    if (output.server.network) |manager| manager.opened();
}

fn syncTaskbar(output: *Output) void {
    if (output.calendar) |calendar| calendar.refresh();
    const bar = output.taskbar orelse return;
    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return;
    bar.relayout(box);
}

// Scales the wallpaper to cover the output, cropping the overhanging axis
// so the image keeps its aspect ratio on any screen shape.
pub fn replaceWallpaper(output: *Output, image: *ImageBuffer) void {
    if (output.wallpaper) |node| node.node.destroy();
    output.wallpaper = output.server.background_tree.createSceneBuffer(&image.base) catch |err| blk: {
        log.err("replaceWallpaper: could not create wallpaper node: {}", .{err});
        break :blk null;
    };
    if (output.wallpaper) |node| node.setFilterMode(.bilinear);
    output.syncWallpaper();
    output.wlr_output.scheduleFrame();
}

pub fn syncWallpaper(output: *Output) void {
    const node = output.wallpaper orelse return;
    const image = output.server.wallpaper orelse return;

    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return;

    node.node.setPosition(box.x, box.y);
    node.setDestSize(box.width, box.height);

    const image_width: f64 = @floatFromInt(image.width);
    const image_height: f64 = @floatFromInt(image.height);
    const dest_width: f64 = @floatFromInt(box.width);
    const dest_height: f64 = @floatFromInt(box.height);
    const scale = @max(dest_width / image_width, dest_height / image_height);
    const source_width = @min(dest_width / scale, image_width);
    const source_height = @min(dest_height / scale, image_height);
    node.setSourceBox(&.{
        .x = (image_width - source_width) / 2,
        .y = (image_height - source_height) / 2,
        .width = source_width,
        .height = source_height,
    });
}

pub fn commitFrameState(output: *Output, state: *wlr.Output.State) bool {
    if (output.color.pending) {
        var copy = state.*;
        wlr_output_state_set_color_transform(&copy, output.color.transform);
        if (output.wlr_output.testState(&copy)) {
            wlr_output_state_set_color_transform(state, output.color.transform);
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
    return success;
}

const CursorState = struct {
    cursor: ?*wlr.OutputCursor = null,
    buffer: ?*wlr.Buffer = null,
    x: f64 = 0,
    y: f64 = 0,
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
    enabled: bool = false,
    visible: bool = false,

    fn of(wlr_output: *wlr.Output) CursorState {
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

/// Whether this frame would present exactly what is already on screen.
///
/// A client that asks for a frame callback makes wlroots latch
/// `wlr_output.needs_frame`, which otherwise forces a scene build and a page
/// flip every refresh even with no damage. That is the whole cost of an idle
/// desktop with one such client. Anything else that raises `needs_frame`
/// without scene damage is checked here: hardware cursor moves, output
/// capture (which holds an attach-render lock) and gamma changes.
fn commitIsRedundant(output: *Output, scene_output: *wlr.SceneOutput) bool {
    if (output.vblank_timer == null or output.color.pending) return false;
    const wlr_output = output.wlr_output;
    if (!wlr_output.enabled or wlr_output.attach_render_locks > 0) return false;
    if (scene_output.private.gamma_lut_changed) return false;
    if (scene_output.private.pending_commit_damage.notEmpty()) return false;
    return std.meta.eql(CursorState.of(wlr_output), output.committed_cursor);
}

fn refreshPeriodNs(output: *Output) u64 {
    const mhz: u64 = if (output.wlr_output.refresh > 0) @intCast(output.wlr_output.refresh) else 60_000;
    return 1_000_000_000_000 / mhz;
}

/// Delivers frame callbacks at the next estimated vblank instead of now.
/// Sending them immediately would let a client's next empty commit schedule
/// another frame at once: with no page flip pending nothing would pace it.
fn deferFrameDone(output: *Output) void {
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

fn handleVblank(output: *Output) c_int {
    output.vblank_armed = false;
    output.last_vblank_ns = output.vblank_target_ns;
    sendFrameDone(output);
    if (output.frame_wanted) {
        output.frame_wanted = false;
        output.wlr_output.scheduleFrame();
    }
    return 0;
}

fn sendFrameDone(output: *Output) void {
    if (output.server.scene.getSceneOutput(output.wlr_output)) |scene_output| {
        var now = timestamp();
        scene_output.sendFrameDone(&now);
    }
    var preview_time = timestamp();
    output.server.switcher.frameDone(output, &preview_time);
}

// A client commit can render before the next vblank when the previous flip is
// complete. Coalesce commits at idle, after wlroots has updated scene damage.
fn tearingAllowed(output: *Output) bool {
    const server = output.server;
    if (!server.config.compositor.allow_tearing or output.tearing_rejected or
        server.locker != null or server.polkit_dialog != null or server.greeter_mode or
        output.power_off or !output.wlr_output.enabled) return false;
    const focused = server.input.seat.keyboard_state.focused_surface orelse return false;
    const top = @import("Toplevel.zig").fromSurface(server, focused) orelse return false;
    if (!top.in_world or top.minimized or top.tab_hidden or !top.isFullscreen() or top.currentOutput() != output) return false;
    return @import("extra_protocols.zig").rediwm_protocols_tearing(server.extra_protocols, top.surface());
}

pub fn queueTearing(output: *Output) void {
    if (output.tearing_idle != null or !output.tearingAllowed()) return;
    output.tearing_idle = output.server.wl_server.getEventLoop().addIdle(*Output, tearingIdle, output) catch null;
}

fn tearingIdle(output: *Output) void {
    output.tearing_idle = null;
    if (!output.tearingAllowed() or output.wlr_output.frame_pending or output.vblank_armed) return;
    runFrame(output);
}

fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const output: *Output = @fieldParentPtr("frame", listener);
    // Only the vblank timer paces frames after a skipped commit.
    if (output.vblank_armed) {
        output.frame_wanted = true;
        return;
    }
    if (output.flip_pending) {
        output.flip_pending = false;
        output.last_vblank_ns = stats.nowNs();
    }
    runFrame(output);
}

fn runFrame(output: *Output) void {
    const frame_started = stats.nowNs();
    anim.beginFrame(output.animation_budget.coarse, stats.nowNs);
    defer {
        stats.global_stats.anim_cpu.record(anim.endFrame());
        const elapsed = stats.nowNs() -% frame_started;
        stats.global_stats.cpu_frame.record(elapsed);
        output.animation_budget.record(elapsed, output.wlr_output.refresh);
    }
    output.server.expireGpuTimer();
    if (output.server.gpu_timer) |timer| timer.collect();

    output.server.screenshot_selector.flush(output);
    const now_ms = Taskbar.nowMs();
    // Shell windows apply sizes synchronously. Flush before painting their
    // content so the body and chrome reach this frame at the same size.
    output.server.input.flushResizeConfigure(output);
    anim.observeBegin();
    const switcher_animating = output.server.switcher.tick(output, now_ms);
    const osd_animating = output.osd.tick(output, now_ms);
    const taskbar_started = stats.nowNs();
    var bar_animating = false;
    if (output.taskbar) |bar| bar_animating = bar.tick(now_ms);
    stats.global_stats.taskbar_cpu.record(stats.nowNs() -% taskbar_started);
    const chrome_started = stats.nowNs();
    const chrome_animating = output.server.world.tickHover(now_ms);
    stats.global_stats.chrome_cpu.record(stats.nowNs() -% chrome_started);
    const panels_started = stats.nowNs();

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

    stats.global_stats.panels_cpu.record(stats.nowNs() -% panels_started);
    if (anim.observeLongestMs() > 0) {
        const longest: u64 = @intCast(anim.observeLongestMs());
        if (longest > stats.global_stats.anim_longest_ms) stats.global_stats.anim_longest_ms = longest;
    }
    const scene_output = output.server.scene.getSceneOutput(output.wlr_output) orelse {
        // Safer than `.?`: a missing scene output is a setup failure, not a
        // reason to abort the compositor on every refresh.
        log.err("handleFrame: no scene output for {s}", .{output.wlr_output.name});
        return;
    };
    const projection_started = stats.nowNs();
    output.server.world.syncPresentation();
    stats.global_stats.projection_cpu.record(stats.nowNs() -% projection_started);
    output.server.world.flushCameraEvent();
    const mini_map_animating = output.server.world.mini_map.tick(output, now_ms);
    // GPU timestamps enclose glass capture/blur plus the scene submission.
    // Polling happens later; no glFinish or synchronous query-result reads.
    const gpu_active = if (output.server.gpu_timer) |timer| timer.begin() else false;
    const glass_started = stats.nowNs();
    const lock_animating = output.lock_view.sync(output);
    const polkit_animating = if (output.server.polkit_dialog) |dialog|
        dialog.output == output.wlr_output and dialog.frame(now_ms)
    else
        false;
    glass.Engine.hold(output.server.glass_engine, output.server.input.heldGlass());
    glass.Engine.holdAll(output.server.glass_engine, output.server.world.holdingGlass());
    glass.Engine.update(output.server.glass_engine, scene_output, output.wlr_output.scale);
    stats.global_stats.glass_cpu.record(stats.nowNs() -% glass_started);
    var captured = false;
    if (output.server.screenshot_mgr) |sm| {
        captured = sm.handleOutputFrame(output);
    }
    var deferred = false;
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
            if (scene_output.buildState(&state, null)) {
                committed = output.commitFrameState(&state);
            } else {
                committed = false;
            }
            if (committed) {
                output.committed_cursor = CursorState.of(output.wlr_output);
                output.flip_pending = true;
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
            @import("startup.zig").notePresented(@intCast(output.server.outputs.length()), output.server.maxOutputScale());
            output.server.session_startup.onPresented();
            output.server.startup_warmup.schedule(output.server);
        }
        if (!deferred) {
            var now = timestamp();
            scene_output.sendFrameDone(&now);
        }
    }
    if (deferred) {
        deferFrameDone(output);
    } else {
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
    const keep_going = mini_map_animating or switcher_animating or osd_animating or bar_animating or chrome_animating or cc_animating or sm_animating or pm_animating or taskbar_popup_animating or notif_animating or desktop_animating or lock_animating or polkit_animating;
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
pub fn setDisplayMode(output: *Output, mode: @import("output_modes.zig").Choice) bool {
    var state = wlr.Output.State.init();
    defer state.finish();
    mode.setState(&state);
    if (!output.wlr_output.testState(&state) or !output.wlr_output.commitState(&state)) return false;
    syncLayout(output.server);
    output.color.key = null;
    output.server.night_light.retargetOutput(output);
    if (output.server.idle) |im| im.recheckInhibitors();
    output.wlr_output.scheduleFrame();
    return true;
}

fn handleRequestState(
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
    output.applyConfig();
    syncLayout(output.server);
    output.color.key = null;
    output.server.night_light.retargetOutput(output);
    if (output.server.idle) |im| im.recheckInhibitors();
}

fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
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
    if (server.scene.getSceneOutput(output.wlr_output)) |scene_output| {
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
    output.link.remove();
    output.frame.link.remove();
    output.request_state.link.remove();
    output.destroy.link.remove();

    // The destroy signal runs before wlroots tears down the layout addon, so
    // outputAt() can still return this wlr_output. Clear userdata first so
    // fromWlr/atLayout cannot hand out a freed Output.
    output.wlr_output.data = null;
    if (server.desktop) |desktop| desktop.outputRemoved(output);
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

    // Expand bounds if necessary to retain existing window frames
    var it_top = server.world.toplevels.iterator(.forward);
    while (it_top.next()) |top| {
        if (top.tab_hidden) continue;
        server.world.ensureInBounds(top.x, top.y, top.chrome_width, top.chrome_height);
    }

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
