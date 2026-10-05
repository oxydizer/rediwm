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
    switch (action) {
        .noop => {},
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
    return @import("../ipc/handlers.zig").findFocusedToplevel(server) orelse server.world.toplevels.first();
}

fn tileFocused(server: *Server, dir: snap.Direction) void {
    const toplevel = focusedToplevel(server) orelse return;
    if (!toplevel.in_world or toplevel.minimized) return;
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
    spawnTracked(server, cmd, false);
}

pub fn spawnHelper(server: *Server, cmd: []const u8) void {
    if (server.services) |manager| {
        if (manager.helperRunning(cmd)) return;
    }
    spawnTracked(server, cmd, true);
}

fn spawnTracked(server: *Server, cmd: []const u8, helper: bool) void {
    var env_map = server.environ.createMap(gpa) catch |err| {
        log.warn("autostart/spawn env: {}", .{err});
        return;
    };
    defer env_map.deinit();
    server.applyChildEnv(&env_map) catch |err| {
        log.warn("autostart/spawn env: {}", .{err});
        return;
    };
    const child = std.process.spawn(server.io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .environ_map = &env_map,
        .pgid = if (helper) 0 else null,
    }) catch |err| {
        log.warn("spawn failed for '{s}': {}", .{ cmd, err });
        return;
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
    if (output) |out| out.toggleStartMenu();
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
        if (t == focused or t.minimized or t.tab_hidden) continue;
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
    const bytes = try IoDir.cwd().readFileAlloc(server.io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);

    var app_id: []const u8 = "";
    var x: i32 = 0;
    var y: i32 = 0;
    var zoom_index: usize = 0;
    var have = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "[[window]]")) {
            if (have) applySavedWindow(server, app_id, x, y, zoom_index);
            have = false;
            app_id = "";
            x = 0;
            y = 0;
            zoom_index = 0;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "app_id")) {
            if (value.len >= 2 and value[0] == '"') app_id = value[1 .. value.len - 1];
            have = true;
        } else if (std.mem.eql(u8, key, "x")) {
            x = std.fmt.parseInt(i32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "y")) {
            y = std.fmt.parseInt(i32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "zoom_index")) {
            zoom_index = std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }
    if (have) applySavedWindow(server, app_id, x, y, zoom_index);
}

fn applySavedWindow(server: *Server, app_id: []const u8, x: i32, y: i32, zoom_index: usize) void {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |t| {
        const id = t.appId();
        if (t.tab_hidden or !std.mem.eql(u8, id, app_id)) continue;
        // restore_layout is not a user gesture; suppress undo recording.
        server.undo.applying = true;
        defer server.undo.applying = false;
        t.setPosition(x, y);
        const max_index = camera_mod.zoom_levels.len - 1;
        t.setZoom(@min(zoom_index, max_index), server.input.cursor.x, server.input.cursor.y);
        return;
    }
}

fn executeUndo(server: *Server) void {
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
            .focus => .none,
        };
        server.undo.commit(now_ms, live);
    }

    const change = server.undo.slot orelse return;
    server.undo.slot = null;

    // Guard: setters in setPosition / setZoom / focusSurface must not record
    // while we are applying an undo.
    server.undo.applying = true;
    defer server.undo.applying = false;

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
                    .maximized, .tiled => toplevel.applyLayout(win.layout),
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
    spawnProcess(server, if (file_manager) "rediwm-files" else server.environ.getPosix("TERMINAL") orelse "foot");
}
