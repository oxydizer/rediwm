//! Window and workspace actions: focus, close, move, spawn, tiling, sizing and zoom.

const std = @import("std");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const Client = @import("server.zig").Client;
const handlers_data = @import("handlers_data.zig");
const findToplevelById = handlers_data.findToplevelById;
const findFocusedToplevel = handlers_data.findFocusedToplevel;
const findOutputByName = handlers_data.findOutputByName;
const handlers = @import("handlers.zig");
const handleAction = handlers.handleAction;

pub fn handleWindowAction(
    server: *Server,
    request_id: ?protocol.RequestId,
    action: protocol.Action,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    _ = request_id;
    _ = client;
    switch (action) {
        .focus_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{p.id});
                return .{ .err = msg };
            };
            if (toplevel.minimized) {
                toplevel.restore();
            } else {
                server.world.focus(toplevel);
            }
            if (server.getDefaultOutput()) |output| {
                server.world.revealIfOffscreen(toplevel, output);
            }
            return .{ .ok = .handled };
        },
        .close_window => |p| {
            const target: *Toplevel = if (p.id) |id|
                findToplevelById(server, id) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{id});
                    return .{ .err = msg };
                }
            else
                findFocusedToplevel(server) orelse return .{ .err = "NoFocusedWindow" };

            target.sendClose();
            return .{ .ok = .handled };
        },
        .move_window_to => |p| {
            const toplevel = findToplevelById(server, p.id) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{p.id});
                return .{ .err = msg };
            };
            if (toplevel.isResizing() or ((server.input.cursor_mode == .move or server.input.tiling_grab != null) and server.input.grabbed_toplevel == toplevel)) return .{ .err = "Busy" };

            if (p.output) |name| {
                const target_output = findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                };
                if (!target_output.isAvailable()) return .{ .err = "OutputUnavailable" };
                var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
                    @import("../layout_undo.zig").Transaction.begin(server, &.{ toplevel.workspace_id, target_output.workspace_id })
                else
                    null;
                defer if (transaction) |*change| change.finish();
                const old_x = toplevel.x;
                const old_y = toplevel.y;
                if (!toplevel.moveToOutput(target_output)) return .{ .err = "WindowUnavailable" };
                const dx = toplevel.x - old_x;
                const dy = toplevel.y - old_y;
                // Keep transient dialogs attached to their owner when the
                // owner is moved between monitors. Their own maximize or
                // fullscreen state remains authoritative if they have one.
                var it = server.world.toplevels.iterator(.forward);
                while (it.next()) |child| {
                    if (child == toplevel or child.owner() != toplevel or !child.in_world or child.isMaximized() or child.isFullscreen()) continue;
                    child.setPosition(child.x + dx, child.y + dy);
                }
            } else {
                var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
                    @import("../layout_undo.zig").Transaction.begin(server, &.{toplevel.workspace_id})
                else
                    null;
                defer if (transaction) |*change| change.finish();
                const floating = toplevel.auto_restore;
                @import("../auto_tiling.zig").setFloating(toplevel, true);
                toplevel.setPosition(p.x, p.y);
                if (floating) |saved| {
                    // This explicit placement is final; a delayed restore must
                    // not move it back after a subsequent interactive drag.
                    toplevel.pending_restore = null;
                    toplevel.finishSizeAnimation();
                    _ = toplevel.requestSize(saved.width, saved.height);
                }
            }
            toplevel.syncChrome(false, Toplevel.nowMs()) catch {};
            return .{ .ok = .handled };
        },
        .spawn => |p| {
            if (p.argv.len == 0) return .{ .err = "InvalidRequest: empty argv" };

            var env_map = try server.environ.createMap(allocator);
            defer env_map.deinit();
            try server.applyChildEnv(&env_map);

            const child = std.process.spawn(server.io, .{
                .argv = p.argv,
                .environ_map = &env_map,
            }) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "SpawnFailed: {s}", .{@errorName(err)});
                return .{ .err = msg };
            };
            if (child.id) |pid| {
                @import("../session/app_scope.zig").place(server, pid, std.fs.path.basename(p.argv[0]));
                if (server.services) |s| s.trackChild(pid) catch {};
            }

            return .{ .ok = .handled };
        },
        // Phase 4 targeted actions
        .set_desktop_mode => |p| {
            @import("../config_runtime/workspace_controls.zig").mode(server, p.mode, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_window_gap => |p| {
            @import("../config_runtime/workspace_controls.zig").gap(server, p.gap, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_floating_apps => |p| {
            @import("../config_runtime/workspace_controls.zig").floatingApps(server, p.apps, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_workspace_layout => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            @import("../config_runtime/workspace_controls.zig").layout(server, p.workspace, p.layout);
            return .{ .ok = .handled };
        },
        .switch_workspace => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            server.world.workspaces.switchTo(server, p.workspace);
            return .{ .ok = .handled };
        },
        .move_to_workspace => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            const top = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            server.world.workspaces.moveTo(top, p.workspace);
            return .{ .ok = .handled };
        },
        .tiling_action => |p| {
            if (!server.world.workspaces.active) return .{ .err = "WorkspaceModeRequired" };
            const top = if (p.id) |id| findToplevelById(server, id) orelse return .{ .err = "UnknownWindow" } else findFocusedToplevel(server);
            if (top) |target| if (!target.in_world or !@import("../workspaces.zig").visible(target)) return .{ .err = "WindowNotVisible" };
            @import("../auto_tiling.zig").execute(server, top, p.action);
            return .{ .ok = .handled };
        },
        .maximize_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            toplevel.setMaximized(true);
            return .{ .ok = .handled };
        },
        .minimize_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            toplevel.minimize();
            return .{ .ok = .handled };
        },
        .restore_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            if (toplevel.minimized) {
                toplevel.restore();
            } else if (toplevel.maximized) {
                toplevel.setMaximized(false);
            } else if (toplevel.fullscreen) {
                toplevel.setFullscreen(false);
            }
            return .{ .ok = .handled };
        },
        .fullscreen_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            _ = p.output;
            toplevel.toggleFullscreen();
            return .{ .ok = .handled };
        },
        .stop_xwayland => {
            const xwayland = server.xwayland orelse return .{ .err = "XwaylandNotRunning" };
            xwayland.stop();
            return .{ .ok = .handled };
        },
        .set_window_size => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            if (p.width <= 0 or p.height <= 0) return .{ .err = "InvalidCoordinates" };
            if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
            var transaction: ?@import("../layout_undo.zig").Transaction = if (server.world.workspaces.active)
                @import("../layout_undo.zig").Transaction.begin(server, &.{toplevel.workspace_id})
            else
                null;
            defer if (transaction) |*change| change.finish();
            if (transaction) |*change| change.resized = .{ .id = toplevel.id, .width = p.width, .height = p.height };
            if (toplevel.auto_target != null) toplevel.leaveLayout();
            _ = toplevel.requestSizeAnimated(p.width, p.height);
            return .{ .ok = .handled };
        },
        .set_window_zoom => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            for (@import("../camera.zig").zoom_levels, 0..) |pct, idx| {
                if (pct == p.percent) {
                    toplevel.setZoom(idx, server.input.cursor.x, server.input.cursor.y);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "InvalidRequest: unsupported zoom percent" };
        },
        else => unreachable,
    }
}
