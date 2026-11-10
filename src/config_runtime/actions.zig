// Dispatch for config keybind actions.
const std = @import("std");
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const keybinds = @import("config").keybinds;
const app_scope = @import("../session/app_scope.zig");
pub const Action = keybinds.Action;

const log = std.log.scoped(.config);
const gpa = @import("../main.zig").gpa;

pub fn executeAction(server: *Server, action: Action) void {
    if (server.locker != null and !keybinds.isHardwareAction(action)) return;
    if (server.world.workspaces.active) switch (action) {
        .set_depth, .zoom_in, .zoom_out, .zoom_reset, .camera_zoom_in, .camera_zoom_out, .camera_zoom_reset, .pan_left, .pan_right, .pan_up, .pan_down => return,
        else => {},
    };
    switch (action) {
        .toggle_floating, .toggle_split, .toggle_workspace_tiling, .swap_left, .swap_right, .swap_up, .swap_down, .resize_split_left, .resize_split_right, .resize_split_up, .resize_split_down => @import("../auto_tiling.zig").execute(server, focusedToplevel(server), std.meta.stringToEnum(keybinds.TilingAction, @tagName(action)).?),
        .noop => {},
        .workspace => |id| server.world.workspaces.switchTo(server, id),
        .move_to_workspace => |id| if (focusedToplevel(server)) |top| server.world.workspaces.moveTo(top, id),
        .workspace_next => server.world.workspaces.cycle(server, true),
        .workspace_prev => server.world.workspaces.cycle(server, false),
        .toggle_power_menu => if (server.getDefaultOutput()) |output| {
            if (output.power_menu != null) output.closePowerMenu() else output.openPowerMenu();
        },
        .volume_up, .volume_down, .volume_mute, .mic_mute, .brightness_up, .brightness_down => @import("../hardware_keys.zig").execute(server, action),
        .power_profile_cycle => if (server.power_profiles) |pp| pp.cycle(),
        .spawn => |cmd| launchPreferred(server, cmd),
        .close_window => if (focusedToplevel(server)) |t| t.sendClose(),
        .toggle_fullscreen => if (focusedToplevel(server)) |t| t.toggleFullscreen(),
        .toggle_maximize => if (focusedToplevel(server)) |t| t.toggleMaximize(),
        .tile_left => tileFocused(server, .left),
        .tile_right => tileFocused(server, .right),
        .tile_up => tileFocused(server, .up),
        .tile_down => tileFocused(server, .down),
        .toggle_start_menu => toggleStartMenu(server),
        .open_system_monitor => openSystemMonitor(server),
        .set_depth => |band| setFocusedDepth(server, band),
        .zoom_in => zoomFocused(server, -1),
        .zoom_out => zoomFocused(server, 1),
        .zoom_reset => setFocusedZoom(server, 0),
        .camera_zoom_in => cameraZoom(server, -1),
        .camera_zoom_out => cameraZoom(server, 1),
        .camera_zoom_reset => cameraZoomReset(server),
        .pan_left => panScreen(server, -1, 0),
        .pan_right => panScreen(server, 1, 0),
        .pan_up => panScreen(server, 0, -1),
        .pan_down => panScreen(server, 0, 1),
        .focus_next => server.world.cycleFocus(),
        .focus_prev => server.world.cycleFocusPrev(),
        .focus_left => focusDirection(server, .left),
        .focus_right => focusDirection(server, .right),
        .focus_up => focusDirection(server, .up),
        .focus_down => focusDirection(server, .down),
        .lock_screen => @import("../session/lock.zig").Lock.start(server),
        .quit => server.terminate(),
        .poweroff => if (server.power) |pm| pm.requestPowerOff(),
        .reboot => if (server.power) |pm| pm.requestReboot(),
        .@"suspend" => if (server.power) |pm| pm.requestSuspend(),
        .poweroff_auto => if (server.power) |pm| pm.requestPowerOffAuto(),
        .reboot_auto => if (server.power) |pm| pm.requestRebootAuto(),
        .suspend_auto => if (server.power) |pm| pm.requestSuspendAuto(),
        .restart_shell => restartShell(server),
        .screenshot_region => screenshot(server, true),
        .screenshot_output => screenshot(server, false),
        .save_layout => |name| saveLayout(server, name),
        .restore_layout => |name| restoreLayout(server, name),
        .undo => executeUndo(server),
        .restore_shortcuts => _ = server.input.shortcuts_inhibit.revoke(),
    }
}

pub fn focusedToplevel(server: *Server) ?*Toplevel {
    if (server.world.workspaces.active) return @import("../ipc/handlers.zig").findFocusedToplevel(server);
    return @import("../ipc/handlers.zig").findFocusedToplevel(server) orelse server.world.toplevels.first();
}

fn openSystemMonitor(server: *Server) void {
    if (server.greeter_mode or server.locker != null or server.polkit_dialog != null) return;
    // Remove transient input owners before focusing either the existing app
    // or the one about to map. Releasing Alt must not accept an old switcher.
    var keyboards = server.input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| {
        keyboard.stopRepeat();
        keyboard.stopShellRepeat();
        keyboard.stopSwitcherRepeat();
    }
    _ = server.input.shortcuts_inhibit.revoke();
    _ = server.input.cancelDrag();
    server.input.clearGrab();
    server.input.pan_session = null;
    server.screenshot_selector.cancel();
    server.switcher.cancel();
    server.input.window_menu.close();
    if (server.tray) |tray| tray.closeMenu();
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        output.closeStartMenu();
        output.closePowerMenu();
        output.closeWifi();
        output.closeBattery();
        output.closeCalendar();
    }
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (!top.in_world or !std.mem.eql(u8, top.appId(), "rediwm-monitor")) continue;
        top.restore();
        server.world.focus(top);
        if (server.getDefaultOutput()) |output| server.world.navigateTo(top, output);
        return;
    }
    if (server.launch_feedback.pendingDesktop("rediwm-monitor.desktop")) return;
    // Sibling executable also works from a build tree whose bin isn't on PATH.
    const dir = std.process.executableDirPathAlloc(server.io, gpa) catch return;
    defer gpa.free(dir);
    const executable = std.fs.path.join(gpa, &.{ dir, "rediwm-monitor" }) catch return;
    defer gpa.free(executable);
    if (spawnTracked(server, "rediwm-monitor", false, &.{executable})) |pid| {
        server.launch_feedback.begin(.{ .pid = pid, .desktop_id = "rediwm-monitor.desktop" });
    }
}

fn tileFocused(server: *Server, dir: snap.Direction) void {
    const toplevel = focusedToplevel(server) orelse return;
    if (!toplevel.in_world or toplevel.minimized) return;
    var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
        @import("../layout_undo.zig").Transaction.begin(server, &.{toplevel.workspace_id})
    else
        null;
    defer if (transaction) |*change| change.finish();
    const before = toplevel.layout();
    const geom = toplevel.clientGeometry();
    const window: @import("../undo.zig").WindowState = .{
        .id = toplevel.id,
        .x = toplevel.x,
        .y = toplevel.y,
        .width = geom.width,
        .height = geom.height,
        .zoom_index = toplevel.zoom_index,
        .layout = before,
    };
    toplevel.applyLayout(snap.step(before, dir));
    if (!toplevel.layout().eql(before)) {
        const undo_ms = Server.undoNowMs();
        server.undo.record(.{ .kind = .resize, .press_seq = server.undo.press_seq, .at_ms = undo_ms, .window = window }, undo_ms);
    }
}

pub fn spawnProcess(server: *Server, cmd: []const u8) void {
    _ = spawnTracked(server, cmd, false, &.{ "/bin/sh", "-c", cmd });
}

/// Runs `argv` directly, no shell, as `spawnProcess` would a command line.
pub fn spawnArgv(server: *Server, argv: []const []const u8) void {
    _ = spawnTracked(server, argv[0], false, argv);
}

pub fn spawnHelper(server: *Server, cmd: []const u8) void {
    if (server.services) |manager| {
        if (manager.helperRunning(cmd)) return;
    }
    _ = spawnTracked(server, cmd, true, &.{ "/bin/sh", "-c", cmd });
}

fn spawnTracked(server: *Server, cmd: []const u8, helper: bool, argv: []const []const u8) ?i32 {
    var env_map = server.environ.createMap(gpa) catch |err| {
        log.warn("autostart/spawn env: {}", .{err});
        return null;
    };
    defer env_map.deinit();
    server.applyChildEnv(&env_map) catch |err| {
        log.warn("autostart/spawn env: {}", .{err});
        return null;
    };
    const child = std.process.spawn(server.io, .{
        .argv = argv,
        .environ_map = &env_map,
        .pgid = if (helper) 0 else null,
    }) catch |err| {
        log.warn("spawn failed for '{s}': {}", .{ cmd, err });
        return null;
    };
    if (child.id) |pid| {
        app_scope.place(server, pid, app_scope.commandId(cmd));
        if (server.services) |s| {
            if (helper) s.trackHelper(pid, cmd) catch |err| {
                log.err("could not supervise helper '{s}': {}", .{ cmd, err });
                std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
            } else s.trackChild(pid) catch {};
        }
    }
    return child.id;
}

pub fn spawnAutostartCommand(server: *Server, cmd: []const u8) void {
    if (std.mem.eql(u8, cmd, server.config.notifications.daemon)) return;
    if (std.mem.eql(u8, cmd, "dunst") and server.config.notifications.daemon.len == 0) {
        log.warn("ignoring legacy dunst autostart; use [notifications] daemon to select an external daemon", .{});
        return;
    }
    if (@import("config").loader.isDesktopClient(cmd)) {
        log.warn("ignoring rediwm-desktop autostart: the compositor draws the desktop; use [desktop] enabled", .{});
        return;
    }
    spawnHelper(server, cmd);
}

pub fn spawnAutostart(server: *Server) void {
    for (server.config.autostart) |cmd| spawnAutostartCommand(server, cmd);
}

fn toggleStartMenu(server: *Server) void {
    const output = Output.atLayout(server, server.input.cursor.x, server.input.cursor.y) orelse blk: {
        var top_it = server.world.toplevels.iterator(.forward);
        if (top_it.next()) |toplevel| {
            const cx = @as(f64, @floatFromInt(toplevel.x)) + @as(f64, @floatFromInt(toplevel.chrome_width)) / 2.0;
            const cy = @as(f64, @floatFromInt(toplevel.y)) + @as(f64, @floatFromInt(toplevel.chrome_height)) / 2.0;
            if (Output.atLayout(server, cx, cy)) |out| break :blk out;
        }
        var out_it = server.outputs.iterator(.forward);
        break :blk out_it.next();
    };
    if (output) |out| out.toggleAppLauncher();
}

fn setFocusedDepth(server: *Server, band: u8) void {
    const toplevel = focusedToplevel(server) orelse return;
    if (!server.input.canZoom()) return;
    const max_index = camera_mod.zoom_levels.len - 1;
    const index: usize = @min(@as(usize, band), max_index);
    toplevel.setZoomAnimated(index, server.input.cursor.x, server.input.cursor.y);
}

fn zoomFocused(server: *Server, delta: i32) void {
    const toplevel = focusedToplevel(server) orelse return;
    if (!server.input.canZoom()) return;
    const max_index: i32 = @intCast(camera_mod.zoom_levels.len - 1);
    const current: i32 = @intCast(toplevel.zoom_index);
    const next: usize = @intCast(std.math.clamp(current + delta, 0, max_index));
    if (next != toplevel.zoom_index) {
        toplevel.setZoomAnimated(next, server.input.cursor.x, server.input.cursor.y);
    }
}

fn setFocusedZoom(server: *Server, index: usize) void {
    const toplevel = focusedToplevel(server) orelse return;
    if (!server.input.canZoom()) return;
    toplevel.setZoomAnimated(index, server.input.cursor.x, server.input.cursor.y);
}

/// Scroll to the neighbouring desktop of the canvas grid.
fn panScreen(server: *Server, dx: i32, dy: i32) void {
    if (!server.input.canZoom()) return;
    if (server.input.cursor_mode == .pan) {
        server.input.endPan();
        server.input.pan_session = null;
    }
    const world = &server.world;
    const compositor = server.config.compositor;
    const zoom = world.camera.zoom();
    // Queue consecutive presses from the previous destination, not a mid-frame sample.
    const x: f64 = if (world.pan_x.active()) world.pan_x.to else world.camera.offset_x;
    const y: f64 = if (world.pan_y.active()) world.pan_y.to else world.camera.offset_y;
    world.springPan(
        camera_mod.desktopOffset(x, world.bounds.width, compositor.canvas_columns, zoom, dx),
        camera_mod.desktopOffset(y, world.bounds.height, compositor.canvas_rows, zoom, dy),
        .camera_desktop,
    );
}

fn cameraZoom(server: *Server, delta: i32) void {
    if (!server.input.canZoom()) return;
    server.world.stepZoom(delta, server.input.cursor.x, server.input.cursor.y);
}

fn cameraZoomReset(server: *Server) void {
    if (!server.input.canZoom()) return;
    server.world.setZoom(0, server.input.cursor.x, server.input.cursor.y);
}

const Dir = enum { left, right, up, down };

fn focusDirection(server: *Server, dir: Dir) void {
    const focused = focusedToplevel(server) orelse return;
    const fx = focused.x + @divTrunc(focused.chrome_width, 2);
    const fy = focused.y + @divTrunc(focused.chrome_height, 2);
    var best: ?*Toplevel = null;
    var best_score: i64 = std.math.maxInt(i64);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |t| {
        if (!@import("../workspaces.zig").visible(t) or t == focused or t.minimized or t.tab_hidden) continue;
        const tx = t.x + @divTrunc(t.chrome_width, 2);
        const ty = t.y + @divTrunc(t.chrome_height, 2);
        const dx = tx - fx;
        const dy = ty - fy;
        const on_axis = switch (dir) {
            .left => dx < 0,
            .right => dx > 0,
            .up => dy < 0,
            .down => dy > 0,
        };
        if (!on_axis) continue;
        const primary: i64 = switch (dir) {
            .left, .right => @intCast(@abs(dx)),
            .up, .down => @intCast(@abs(dy)),
        };
        const secondary: i64 = switch (dir) {
            .left, .right => @intCast(@abs(dy)),
            .up, .down => @intCast(@abs(dx)),
        };
        const score = primary + secondary * 2;
        if (score < best_score) {
            best_score = score;
            best = t;
        }
    }
    if (best) |t| {
        server.world.focus(t);
        if (server.getDefaultOutput()) |output| {
            server.world.navigateTo(t, output);
        }
    }
}

// Let main clean up clients, sockets and the backend before replacing the process.
fn restartShell(server: *Server) void {
    server.restart_requested = true;
    // Consume the outstanding supervisor reply before reusing the inherited
    // readiness fd; otherwise the new process could accept the old ack.
    if (server.session_startup.server != null and !server.session_startup.acknowledged) return;
    server.wl_server.terminate();
}

fn screenshot(server: *Server, region: bool) void {
    const selector = @import("../screenshot/selector.zig");
    if (region) {
        server.screenshot_selector.open(server) catch |err| selector.report(server, "Screenshot failed", @errorName(err));
    } else if (server.getDefaultOutput()) |output| {
        server.screenshot_selector.cancel();
        selector.save(server, output, null);
    }
}

fn layoutPath(server: *Server, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(server.config.path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/layouts/{s}.toml", .{ dir, name });
}

fn saveLayout(server: *Server, name: []const u8) void {
    const path = layoutPath(server, gpa, name) catch |err| {
        log.warn("save_layout: {}", .{err});
        return;
    };
    defer gpa.free(path);
    saveLayoutToPath(server, path) catch |err| log.warn("save_layout '{s}': {}", .{ name, err });
}

/// Shared by `save_layout <name>` and the periodic crash-recovery autosave
/// (session/layout_autosave.zig) — the latter just picks a different path.
pub fn saveLayoutToPath(server: *Server, path: []const u8) !void {
    return writeLayout(server, path, null);
}

/// The periodic autosave's variant: skips the write when the layout matches
/// what this process last wrote, so an unchanged desktop does not rewrite
/// the file (and wake the disk) every tick. `last_hash` is updated only
/// after a successful write.
pub fn saveLayoutToPathIfChanged(server: *Server, path: []const u8, last_hash: *?u64) !void {
    return writeLayout(server, path, last_hash);
}

fn writeLayout(server: *Server, path: []const u8, last_hash: ?*?u64) !void {
    if (server.world.workspaces.active) return @import("../workspace_persistence.zig").save(server, path, last_hash);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |t| {
        if (t.tab_hidden) continue;
        const app_id = t.appId();
        try buf.print(gpa, "[[window]]\napp_id = \"{s}\"\nx = {d}\ny = {d}\nwidth = {d}\nheight = {d}\nzoom_index = {d}\n\n", .{
            app_id, t.x, t.y, t.chrome_width, t.chrome_height, t.zoom_index,
        });
    }
    // Zero toplevels right now doesn't mean there's nothing worth
    // remembering — it also happens on every ordinary shutdown, since
    // Server.terminate() calls this before destroyClients() but a client can
    // just as easily have already exited on its own (closed by the user, or
    // killed moments earlier as part of the same teardown) by the time this
    // runs. Overwriting a real, still-useful save with an empty one in that
    // case would throw away positions that were perfectly good seconds ago;
    // leaving the file as the last periodic tick wrote it is strictly safer,
    // and restoring against "whatever toplevels happen to exist" already
    // treats a stale or unmatched entry as harmless (see this file's header).
    if (buf.items.len == 0) return;
    const hash = std.hash.Wyhash.hash(0, buf.items);
    if (last_hash) |last| if (last.*) |prev| if (prev == hash) return;
    if (std.fs.path.dirname(path)) |dir| try IoDir.cwd().createDirPath(server.io, dir);
    try IoDir.cwd().writeFile(server.io, .{ .sub_path = path, .data = buf.items });
    if (last_hash) |last| last.* = hash;
}

fn restoreLayout(server: *Server, name: []const u8) void {
    const path = layoutPath(server, gpa, name) catch |err| {
        log.warn("restore_layout: {}", .{err});
        return;
    };
    defer gpa.free(path);
    restoreLayoutFromPath(server, path) catch |err| {
        if (err != error.FileNotFound) log.warn("restore_layout '{s}': {}", .{ name, err });
        return;
    };
    log.info("restored layout '{s}'", .{name});
}

/// Shared by `restore_layout <name>` and the startup crash-recovery restore
/// (session/layout_autosave.zig) — the latter just picks a different path
/// and tolerates a missing file (nothing to recover) silently.
pub fn restoreLayoutFromPath(server: *Server, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try IoDir.cwd().readFileAlloc(server.io, path, a, .limited(1 << 20));
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n");
    const applying = server.undo.applying;
    server.undo.applying = true;
    defer server.undo.applying = applying;
    if (std.mem.startsWith(u8, trimmed, "{")) {
        if (server.world.workspaces.active) {
            var restore = try @import("../workspace_persistence.zig").Restore.fromBytes(bytes);
            defer restore.deinit();
            var it = server.world.toplevels.iterator(.reverse);
            while (it.next()) |top| restore.apply(server, top);
            it = server.world.toplevels.iterator(.reverse);
            while (it.next()) |top| restore.finish(server, top);
            if (server.layout_autosave) |autosave| for (restore.parsed.value.workspaces) |workspace| autosave.touch(&.{workspace.id});
        } else {
            const saved = try @import("config").workspace_layout.parse(a, bytes);
            var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
            for (saved.value.windows) |window| {
                const top = matchSavedWindow(server, window.app_id, &used, a) orelse continue;
                const c = window.canvas orelse continue;
                top.restoreGeometryNow(.{ .x = c.geometry.x, .y = c.geometry.y, .width = c.geometry.width, .height = c.geometry.height });
                top.setZoomOrigin(@min(c.zoom_index, camera_mod.zoom_levels.len - 1));
            }
        }
        return;
    }
    const rows = try @import("config").workspace_layout.parseLegacy(a, bytes);
    var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (rows) |row| {
        const top = matchSavedWindow(server, row.app_id, &used, a) orelse continue;
        const zoom_index = @min(row.zoom_index, camera_mod.zoom_levels.len - 1);
        if (server.world.workspaces.active) {
            // Older canvas saves update the return-to-canvas state, never the
            // fixed workspace camera or the current automatic rectangles.
            var canvas = top.canvas_state orelse @import("../workspaces.zig").CanvasWindow{
                .geometry = top.rememberGeometry(),
                .zoom_index = 0,
                .layout = .floating,
                .fullscreen = false,
                .maximize_restore = null,
                .tile_restore = null,
                .fullscreen_restore = null,
            };
            canvas.geometry.x = row.x;
            canvas.geometry.y = row.y;
            canvas.zoom_index = zoom_index;
            top.canvas_state = canvas;
        } else {
            top.setPosition(row.x, row.y);
            top.setZoom(zoom_index, server.input.cursor.x, server.input.cursor.y);
        }
    }
}
/// The startup restore of a flat (non-workspace) desktop, kept across the
/// several delayed attempts (session/layout_autosave.zig).
///
/// It works from one snapshot of the saved layout, not from the file: the
/// periodic autosave rewrites the file with the *current* layout every 10 s,
/// so re-reading it at each attempt put windows back wherever they had been up
/// to 10 s earlier (and moved a full-screen window to its old origin). Each
/// saved row is claimed by at most one window and each window is placed at most
/// once, so a window the user has moved since is never touched again.
pub const FlatRestore = struct {
    arena: std.heap.ArenaAllocator,
    layout: @import("config").workspace_layout.Flat,
    placed: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn load(server: *Server, path: []const u8) !FlatRestore {
        const bytes = try IoDir.cwd().readFileAlloc(server.io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const layout = try @import("config").workspace_layout.Flat.fromBytes(arena.allocator(), bytes);
        return .{ .arena = arena, .layout = layout };
    }

    pub fn deinit(self: *FlatRestore) void {
        self.arena.deinit();
    }

    /// Whether some saved row has not found its window yet.
    pub fn pending(self: *const FlatRestore) bool {
        return self.layout.pending();
    }

    pub fn apply(self: *FlatRestore, server: *Server) void {
        const applying = server.undo.applying;
        server.undo.applying = true;
        defer server.undo.applying = applying;
        var it = server.world.toplevels.iterator(.reverse);
        while (it.next()) |top| {
            if (top.tab_hidden or self.placed.contains(top.id)) continue;
            const row = self.layout.claim(top.appId()) orelse continue;
            self.placed.put(self.arena.allocator(), top.id, {}) catch continue;
            // Claimed even when skipped, so a later attempt cannot move it. A
            // window that is already full-screen or maximized keeps its own geometry.
            if (top.isFullscreen() or top.isMaximized()) continue;
            if (row.geometry) |g| {
                top.restoreGeometryNow(.{ .x = g.x, .y = g.y, .width = g.width, .height = g.height });
                top.setZoomOrigin(@min(row.zoom_index, camera_mod.zoom_levels.len - 1));
            } else {
                top.setPosition(row.x, row.y);
                top.setZoom(@min(row.zoom_index, camera_mod.zoom_levels.len - 1), server.input.cursor.x, server.input.cursor.y);
            }
        }
    }
};

fn matchSavedWindow(server: *Server, app_id: []const u8, used: *std.AutoHashMapUnmanaged(u64, void), a: std.mem.Allocator) ?*Toplevel {
    var it = server.world.toplevels.iterator(.reverse);
    while (it.next()) |top| {
        if (top.tab_hidden or used.contains(top.id) or !std.mem.eql(u8, top.appId(), app_id)) continue;
        used.put(a, top.id, {}) catch return null;
        return top;
    }
    return null;
}

fn executeUndo(server: *Server) void {
    if (server.input.tiling_grab != null) server.input.finishTilingGrab(true);
    const resizing = if (server.input.resize_session) |session| @as(?@import("../layout_undo.zig").Resize, .{
        .id = session.toplevel.id,
        .width = session.latest_desired_size.width,
        .height = session.latest_desired_size.height,
    }) else null;
    _ = @import("../layout_undo.zig").commitGesture(server, resizing);
    const now_ms = Server.undoNowMs();
    // Commit any in-flight gesture so a late event cannot clobber the restored state.
    if (server.undo.pending) |pending| {
        const live: @import("../undo.zig").Live = switch (pending.kind) {
            .move, .resize, .window_zoom => if (pending.window) |w| blk: {
                if (server.findToplevelById(w.id)) |t| {
                    const geom = t.clientGeometry();
                    break :blk .{ .window = .{
                        .id = t.id,
                        .x = t.x,
                        .y = t.y,
                        .width = geom.width,
                        .height = geom.height,
                        .zoom_index = t.zoom_index,
                    } };
                }
                break :blk .none;
            } else .none,
            .pan, .camera_zoom => .{ .camera = .{
                .offset_x = server.world.camera.offset_x,
                .offset_y = server.world.camera.offset_y,
                .zoom_index = server.world.camera.zoom_index,
                .focus_zoom = server.world.camera.focus_zoom,
            } },
            .focus, .workspace_layout => .none,
        };
        server.undo.commit(now_ms, live);
    }

    if (server.world.workspaces.active) {
        const applying = server.undo.applying;
        server.undo.applying = true;
        @import("../workspaces.zig").cancelGestures(server);
        server.undo.applying = applying;
    }

    const change = server.undo.slot orelse return;
    server.undo.slot = null;
    defer change.deinit();

    // Guard: setters in setPosition / setZoom / focusSurface must not record
    // while we are applying an undo.
    server.undo.applying = true;
    defer server.undo.applying = false;

    if (change.snapshot) |snapshot| {
        @import("../layout_undo.zig").apply(server, snapshot);
        return;
    }

    // 1. Camera
    if (change.camera) |cam| {
        server.world.panning = false;
        server.world.pinching = false;
        server.world.pan_x.cancel(@floatCast(cam.offset_x));
        server.world.pan_y.cancel(@floatCast(cam.offset_y));
        if (change.kind == .camera_zoom) {
            const anchor: camera_mod.Vec = .{
                .x = server.input.cursor.x,
                .y = server.input.cursor.y,
            };
            server.world.camera.setZoom(server.world.bounds, cam.zoom_index, anchor);
            server.world.camera.focus_zoom = cam.focus_zoom;
            server.world.camera.zoom_limit = @max(1, server.world.camera.targetZoom());
            server.world.snapCamera();
        }
        server.world.camera.offset_x = cam.offset_x;
        server.world.camera.offset_y = cam.offset_y;
        server.world.applyCamera();
    }

    // 2. Window
    if (change.window) |win| {
        if (server.findToplevelById(win.id)) |toplevel| {
            toplevel.finishZoomAnimation();
            toplevel.finishMoveAnimation();
            if (change.kind == .window_zoom) {
                toplevel.setZoom(win.zoom_index, server.input.cursor.x, server.input.cursor.y);
                toplevel.setPosition(win.x, win.y);
            } else if (!toplevel.layout().eql(win.layout)) {
                switch (win.layout) {
                    .floating => {
                        toplevel.leaveLayout();
                        toplevel.restoreGeometry(.{ .x = win.x, .y = win.y, .width = win.width, .height = win.height });
                    },
                    .maximized, .tiled, .automatic => toplevel.applyLayout(win.layout),
                }
            } else if (change.kind == .resize) {
                toplevel.restoreGeometry(.{ .x = win.x, .y = win.y, .width = win.width, .height = win.height });
            } else {
                // .move
                toplevel.setPosition(win.x, win.y);
            }
        }
    }

    // 3. Focus
    if (change.focus) |focus_id| {
        if (server.findToplevelById(focus_id)) |toplevel| {
            server.world.focus(toplevel);
        }
    }
}

const camera_mod = @import("../camera.zig");
const snap = @import("../snap.zig");
const IoDir = std.Io.Dir;

// Preserve existing generated shortcuts while allowing explicit default actions.
fn launchPreferred(server: *Server, cmd: []const u8) void {
    const file_manager = std.mem.eql(u8, cmd, "rediwm-files") or std.mem.eql(u8, cmd, "default-file-manager");
    const id = if (file_manager)
        server.config.compositor.default_file_manager
    else if (std.mem.eql(u8, cmd, "foot") or std.mem.eql(u8, cmd, "default-terminal"))
        server.config.compositor.default_terminal
    else
        return spawnProcess(server, cmd);
    if (id.len > 0) {
        const snapshot = server.start_menu_catalog.retainSnapshot();
        defer snapshot.release();
        if (@import("default_apps.zig").find(snapshot.entries, id)) |entry| {
            @import("../start_menu/launch.zig").launch(gpa, server, entry) catch |err| {
                log.warn("could not launch preferred application '{s}': {}", .{ id, err });
            };
            return;
        }
        log.warn("preferred application '{s}' is no longer installed; using fallback", .{id});
    }
    if (file_manager) return spawnProcess(server, "rediwm-files");
    const command = server.environ.getPosix("TERMINAL") orelse "foot";
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = @import("../start_menu/launch.zig").parseExec(arena.allocator(), command, null) catch return;
    if (args.len == 0) return;
    const themed = @import("config").terminal_theme.wrap(arena.allocator(), server.io, args, server.config.theme, server.config.compositor.terminal_opacity) catch return;
    if (themed.ptr == args.ptr) return spawnProcess(server, command);
    _ = spawnTracked(server, command, false, themed);
}
