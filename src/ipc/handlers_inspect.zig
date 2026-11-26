//! Inspection queries: hit tests, the scene, layer and widget trees, panels, config status and runtime info.

const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const scene_data = @import("../scene_data.zig");
const Client = @import("server.zig").Client;
const handlers_queries = @import("handlers_queries.zig");
const handlers_panels = @import("handlers_panels.zig");
const handlers_widgets = @import("handlers_widgets.zig");
const handlers_data = @import("handlers_data.zig");
const walkSceneTree = handlers_queries.walkSceneTree;
const panel_registry = handlers_panels.panel_registry;
const walkWidgetTree = handlers_widgets.walkWidgetTree;
const buildTaskbarWidgetTree = handlers_widgets.buildTaskbarWidgetTree;
const buildWindowWidgetTree = handlers_widgets.buildWindowWidgetTree;
const getBackendName = handlers_data.getBackendName;
const getRendererName = handlers_data.getRendererName;
const findToplevelById = handlers_data.findToplevelById;
const findFocusedToplevel = handlers_data.findFocusedToplevel;
const findOutputByName = handlers_data.findOutputByName;
const handlers = @import("handlers.zig");
const handleRequest = handlers.handleRequest;

pub fn handleInspectRequest(
    server: *Server,
    request_id: ?protocol.RequestId,
    request: protocol.Request,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    _ = request_id;
    _ = client;
    switch (request) {
        .hit_test => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            var obox: wlr.Box = undefined;
            server.output_layout.getBox(target_out.wlr_output, &obox);
            const lx: f64 = @floatFromInt(obox.x + p.x);
            const ly: f64 = @floatFromInt(obox.y + p.y);

            const hit = scene_data.hitTest(server, lx, ly);
            var result = protocol.HitTestResult{
                .target_type = "none",
                .local_x = 0,
                .local_y = 0,
                .layout_x = lx,
                .layout_y = ly,
                .output = std.mem.span(target_out.wlr_output.name),
            };

            switch (hit) {
                .mini_map => |map| {
                    result.target_type = "mini_map";
                    result.local_x = lx - @as(f64, @floatFromInt(map.box.x));
                    result.local_y = ly - @as(f64, @floatFromInt(map.box.y));
                },
                .none => {},
                .input_popup => |popup_hit| {
                    result.target_type = "input_popup";
                    result.local_x = popup_hit.sx;
                    result.local_y = popup_hit.sy;
                },
                .layer => |l| {
                    result.target_type = "layer";
                    result.local_x = l.sx;
                    result.local_y = l.sy;
                },
                .desktop => |d| {
                    result.target_type = "desktop";
                    result.local_x = d.x;
                    result.local_y = d.y;
                },
                .chrome => |c| {
                    result.target_type = "chrome";
                    result.window_id = c.toplevel.id;
                    result.local_x = c.sx;
                    result.local_y = c.sy;
                    result.widget = if (c.toplevel.hovered_control) |ctrl| @tagName(ctrl) else "titlebar";
                },
                .surface => |s| {
                    result.target_type = "window";
                    result.window_id = s.toplevel.id;
                    result.local_x = s.sx;
                    result.local_y = s.sy;
                },
                .dock => |d| {
                    result.target_type = "dock";
                    result.local_x = d.sx;
                    result.local_y = d.sy;
                },
                .taskbar => |tb| {
                    result.target_type = "taskbar";
                    result.local_x = tb.sx;
                    result.local_y = tb.sy;
                    const target = tb.bar.hitTest(tb.sx, tb.sy);
                    result.widget = if (tb.bar.appTrayAt(tb.sx, tb.sy) != null) "app_tray" else @tagName(target);
                },
                .wifi_popup => |popup| {
                    result.target_type = "wifi_popup";
                    result.widget = popup.popup.widgetAt(popup.sx, popup.sy);
                    result.local_x = popup.sx;
                    result.local_y = popup.sy;
                },
                .transfers_popup => |popup| {
                    result.target_type = "transfers_popup";
                    result.widget = popup.popup.widgetAt(popup.sx, popup.sy);
                    result.local_x = popup.sx;
                    result.local_y = popup.sy;
                },
                .battery_popup => |popup| {
                    result.target_type = "battery_popup";
                    result.local_x = popup.sx;
                    result.local_y = popup.sy;
                },
                .calendar => |cal| {
                    result.target_type = "calendar";
                    result.local_x = cal.sx;
                    result.local_y = cal.sy;
                },
                .control_center => |cc| {
                    result.target_type = "control_center";
                    result.local_x = cc.sx;
                    result.local_y = cc.sy;
                },
                .start_menu => |sm| {
                    result.target_type = "start_menu";
                    result.local_x = sm.sx;
                    result.local_y = sm.sy;
                },
                .power_menu => |pm| {
                    result.target_type = "power_menu";
                    result.local_x = pm.sx;
                    result.local_y = pm.sy;
                },
                .xwayland_unmanaged => |u| {
                    result.target_type = "xwayland_unmanaged";
                    result.local_x = u.sx;
                    result.local_y = u.sy;
                },
                .toast => |t| {
                    result.target_type = "toast";
                    result.local_x = t.sx;
                    result.local_y = t.sy;
                },
            }

            return .{ .ok = .{ .hit_test = result } };
        },
        .get_scene_tree => |p| {
            var nodes = std.ArrayList(protocol.SceneNodeData).empty;
            var total: usize = 0;
            const max_depth = p.max_depth orelse 16;
            try walkSceneTree(&server.nodes.tree.node, &nodes, allocator, 0, max_depth, &total);
            return .{ .ok = .{ .scene_tree = .{
                .nodes = try nodes.toOwnedSlice(allocator),
                .total_nodes = total,
            } } };
        },
        .get_layer_surfaces => {
            var list = std.ArrayList(protocol.LayerSurfaceData).empty;
            var it = server.layer_surfaces.iterator(.forward);
            while (it.next()) |ls| {
                const out_name = if (ls.layer.output) |o| std.mem.span(o.name) else "none";
                try list.append(allocator, .{
                    .namespace = std.mem.span(ls.layer.namespace),
                    .output = out_name,
                    .layer = @tagName(ls.layer.current.layer),
                    .exclusive_zone = ls.layer.current.exclusive_zone,
                    .keyboard_interactive = ls.layer.current.keyboard_interactive != .none,
                    .mapped = ls.layer.surface.mapped,
                    .box = .{
                        .x = ls.tree.node.x,
                        .y = ls.tree.node.y,
                        .width = ls.layer.surface.current.width,
                        .height = ls.layer.surface.current.height,
                    },
                });
            }
            return .{ .ok = .{ .layer_surfaces = .{
                .surfaces = try list.toOwnedSlice(allocator),
            } } };
        },
        .get_widget_tree => |p| {
            const def_out = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            for (panel_registry) |entry| {
                if (std.mem.eql(u8, entry.name, p.panel)) {
                    const resolved = entry.resolve(def_out) orelse return .{ .err = "PanelNotOpen" };
                    var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                    try walkWidgetTree(resolved.root, &widgets, allocator, p.panel, null, resolved.box.x, resolved.box.y, null);
                    return .{ .ok = .{ .widget_tree = .{
                        .panel = p.panel,
                        .widgets = try widgets.toOwnedSlice(allocator),
                    } } };
                }
            }
            if (std.mem.eql(u8, p.panel, "taskbar")) {
                const tb = def_out.taskbar orelse return .{ .err = "PanelNotOpen" };
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                try buildTaskbarWidgetTree(server, tb, &widgets, allocator);
                return .{ .ok = .{ .widget_tree = .{
                    .panel = p.panel,
                    .widgets = try widgets.toOwnedSlice(allocator),
                } } };
            }
            if (std.mem.eql(u8, p.panel, "window") or std.mem.startsWith(u8, p.panel, "window/")) {
                var target_tl: ?*Toplevel = null;
                if (std.mem.startsWith(u8, p.panel, "window/")) {
                    const rest = p.panel["window/".len..];
                    const slash_pos = std.mem.indexOfScalar(u8, rest, '/');
                    const num_str = if (slash_pos) |idx| rest[0..idx] else rest;
                    if (std.fmt.parseInt(u64, num_str, 10)) |id| {
                        target_tl = findToplevelById(server, id);
                    } else |_| return .{ .err = "InvalidRequest: bad window id" };
                } else {
                    target_tl = findFocusedToplevel(server) orelse server.world.toplevels.first();
                }
                const toplevel = target_tl orelse return .{ .err = "NotFound" };
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                try buildWindowWidgetTree(server, toplevel, &widgets, allocator);
                return .{ .ok = .{ .widget_tree = .{
                    .panel = p.panel,
                    .widgets = try widgets.toOwnedSlice(allocator),
                } } };
            }
            return .{ .err = "InvalidPanel: expected start_menu, control_center, power_menu, dock, taskbar, or window" };
        },
        .list_panels => {
            const def_out = server.getDefaultOutput();
            var panels = std.ArrayList(protocol.PanelData).empty;
            for (panel_registry) |entry| {
                var is_open = false;
                var box: ?protocol.RectData = null;
                if (def_out) |out| {
                    if (entry.resolve(out)) |res| {
                        is_open = true;
                        box = .{
                            .x = res.box.x,
                            .y = res.box.y,
                            .width = res.box.width,
                            .height = res.box.height,
                        };
                    }
                }
                try panels.append(allocator, .{
                    .name = entry.name,
                    .open = is_open,
                    .box = box,
                });
            }
            if (def_out) |out| {
                if (out.taskbar) |tb| {
                    try panels.append(allocator, .{
                        .name = "taskbar",
                        .open = true,
                        .box = .{
                            .x = tb.box.x,
                            .y = tb.box.y,
                            .width = tb.box.width,
                            .height = tb.box.height,
                        },
                    });
                }
            }
            return .{ .ok = .{ .list_panels = .{
                .panels = try panels.toOwnedSlice(allocator),
            } } };
        },
        .get_config_status => {
            return .{ .ok = .{ .config_status = .{
                .config_path = if (server.config.path.len > 0) server.config.path else null,
                .generation = server.config_generation,
                .theme_path = server.theme_path,
                .keybinds_count = server.config.keybinds.len,
                .last_reload_result = if (server.config_reload_error != null) "failed" else "ok",
                .last_reload_error = server.config_reload_error,
            } } };
        },
        .get_runtime_info => {
            return .{ .ok = .{ .runtime_info = .{
                .compositor = "rediwm",
                .version = "0.1.0",
                .wlroots_version = "0.20",
                .backend = getBackendName(server.backend),
                .renderer = getRendererName(server.renderer),
                .outputs_count = server.outputs.length(),
                .audio_available = server.audio != null,
                .session_id = if (server.ipc) |ipc| ipc.session_id else "",
                .xwayland_enabled = server.xwayland != null,
                .xwayland_display = if (server.xwayland) |xw| xw.displayName() else null,
                .xwayland_native_scaling = if (server.xwayland) |xw| xw.native_scaling else false,
                .xwayland_scale = server.xwaylandScale(),
                .xwayland_scale_pending = server.xwaylandScalePending(),
                .current_desktop = @import("../child_env.zig").desktop_name,
                .nested = @import("../session/activation.zig").isNested(
                    @import("../session/activation.zig").viewFromEnviron(server.environ),
                ),
            } } };
        },
        else => unreachable,
    }
}
