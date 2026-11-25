//! Output layout and configuration: applying, arranging, scale and reconnection.

const std = @import("std");
const Output = @import("../Output.zig");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const events = @import("../ipc/events.zig");
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.output);
const Placement = Output.Placement;
const lidHides = Output.lidHides;
const configured = Output.configured;
const configuredTransform = Output.configuredTransform;
const wlTransform = Output.wlTransform;
const configuredScale = Output.configuredScale;
const scaleForDimensions = Output.scaleForDimensions;
const automaticScale = Output.automaticScale;
const configuredMode = Output.configuredMode;
const resolveDisplayMode = Output.resolveDisplayMode;
const fromWlr = Output.fromWlr;
const atLayout = Output.atLayout;
const scaled = Output.scaled;
const recomputeWorldBounds = Output.recomputeWorldBounds;

/// The space left by the built-in taskbar and dock, before external panels.
pub fn shellUsableBox(output: *Output) wlr.Box {
    var box = output.dockAreaBox();
    const strip = @import("../Dock.zig").reservedStrip(output.server, box);
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

/// Window placement also respects the exclusive zones of mapped layer surfaces.
pub fn usableBox(output: *Output) wlr.Box {
    return output.layer_work_area orelse output.shellUsableBox();
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
    @import("../config_runtime/watcher.zig").applyLoadedConfig(server, config);
    output.refreshConfiguration();
}

/// Moves outputs to new layout positions (Settings' display arrangement).
/// Each is saved like any display change and pinned, so automatic placement
/// can't shuffle it later. Windows ride along with their output, as on other
/// desktops. A failure stops the remaining moves but still carries the
/// windows of the outputs that did move.
pub fn arrange(server: *Server, placements: []const Placement) !void {
    const Toplevel = @import("../Toplevel.zig");
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

pub fn refreshConfiguration(output: *Output) void {
    output.server.input.refreshOutputScales();
    if (output.taskbar) |bar| bar.notifyToplevelsChanged();
    syncLayout(output.server);
    @import("gamma.zig").refresh(output);
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
    output.commit_refresh = .{};
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
                    @import("gamma.zig").refresh(output);
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
            output.dock.deinit();
            if (output.server.switcher.output == output) output.server.switcher.cancel();
            output.osd.hide();
            continue;
        }
        server.output_layout.getBox(output.wlr_output, &output.cached_box);
        output.syncWallpaper();
        output.syncTaskbar();
        _ = @import("../LayerSurface.zig").arrangeOutput(output);
        output.syncStartMenu();
        output.syncPowerMenu();
        if (server.input.open_control_center) |cc| cc.refresh();
        if (server.ipc) |ipc| events.onOutputChanged(ipc, output);
    }
    recomputeWorldBounds(server);
    server.world.workspaces.setMode(server, server.config.compositor.desktop_mode == .workspaces);
    server.world.workspaces.syncOutputs(server);
    if (server.desktop) |desktop| desktop.syncLayout();
    if (server.output_management) |om| om.publish();
    server.input.touch.remap();
}

pub fn evacuateWindows(output: *Output) void {
    const server = output.server;
    const Displaced = struct {
        toplevel: *@import("../Toplevel.zig"),
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

pub fn restoreReconnectedWindows(output: *Output) void {
    if (!output.isAvailable()) return;
    var restored = false;
    var tops = output.server.world.toplevels.iterator(.forward);
    while (tops.next()) |toplevel| {
        if (toplevel.restoreOutputDisconnect(output)) restored = true;
    }
    if (restored) output.server.scheduleFrames();
}
