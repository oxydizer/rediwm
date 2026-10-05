const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const ControlCenter = @import("../control_center/panel.zig").ControlCenter;
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const stats = @import("stats.zig");
const scene_data = @import("../scene_data.zig");
const Taskbar = @import("../Taskbar.zig");
const chrome = @import("../chrome.zig");
const ui = @import("ui");
const virtual_input_mod = @import("../input/virtual.zig");
const VirtualInput = virtual_input_mod.VirtualInput;
const Client = @import("server.zig").Client;
const window_rules = @import("config").window_rules;
const actions = @import("../config_runtime/actions.zig");
const events = @import("events.zig");
const taskbar_items = @import("config").taskbar_items;

fn automationEnabled(server: *const Server) bool {
    const ipc = server.ipc orelse return false;
    return ipc.automation;
}

pub fn handleRequest(
    server: *Server,
    request_id: ?protocol.RequestId,
    request: protocol.Request,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    if (server.locker != null) return .{ .err = "SessionLocked" };
    if (client) |c_ptr| {
        if (c_ptr.sandbox) |sb| {
            const groups = server.config.sandboxAllowGroups(sb.app_id, sb.engine);
            if (!groups.contains(.ipc)) {
                return .{ .err = "PermissionDenied: sandboxed caller lacks ipc allowance" };
            }
            if (protocol.commands.requiresAutomation(request) and !groups.contains(.automation)) {
                return .{ .err = "PermissionDenied: sandboxed caller lacks automation allowance" };
            }
        }
    }
    if (protocol.commands.requiresAutomation(request) and !automationEnabled(server))
        return .{ .err = "AutomationDisabled: set [ipc] automation = true and restart rediwm" };
    if (server.polkit_dialog != null) switch (request) {
        .get_shell_state, .get_state, .get_input_state, .get_widget_tree, .outputs, .windows, .version, .capabilities, .event_stream, .event_stream_filtered => {},
        .action => |act| switch (act) {
            .wait_for_frame => {},
            else => return .{ .err = "AuthenticationActive" },
        },
        else => return .{ .err = "AuthenticationActive" },
    };
    switch (request) {
        .get_services => return @import("settings.zig").services(server, allocator),
        .get_sounds => return .{ .ok = .{ .sounds = try @import("../audio/sounds.zig").inspect(server, allocator) } },
        .get_wallpaper => return @import("settings.zig").wallpaper(server, allocator),
        .get_theme => return @import("settings.zig").getTheme(server, allocator),
        .get_processes => return @import("processes.zig").start(server, request_id, client),
        .get_keyboard_layouts => return .{ .ok = .{ .keyboard_layouts = try @import("../input/layouts.zig").inspect(server, allocator) } },
        .version => {
            return .{ .ok = .{ .version = "0.1.0" } };
        },
        .capabilities => {
            const caps = &protocol.commands.capabilities;
            return .{ .ok = .{ .capabilities = caps } };
        },
        .describe_ipc => {
            const commands = &protocol.commands.descriptions;

            var unavailable = std.ArrayList([]const u8).empty;
            if (server.audio == null) try unavailable.append(allocator, "audio unavailable");
            if (server.virtual_input == null) try unavailable.append(allocator, "virtual input unavailable");
            if (server.screenshot_mgr == null) try unavailable.append(allocator, "screenshot manager unavailable");
            if (server.idle == null) try unavailable.append(allocator, "idle manager unavailable");
            if (!automationEnabled(server)) try unavailable.append(allocator, "automation disabled: synthetic input, screenshots, pixel reads and buffer dumps need [ipc] automation = true");

            return .{ .ok = .{ .describe_ipc = .{
                .protocol_version = "1",
                .build_version = "0.1.0",
                .backend = getBackendName(server.backend),
                .renderer = getRendererName(server.renderer),
                .commands = commands,
                .unavailable_reasons = try unavailable.toOwnedSlice(allocator),
            } } };
        },
        .windows => {
            var list = std.ArrayList(protocol.WindowData).empty;
            var it = server.world.toplevels.iterator(.forward);
            while (it.next()) |toplevel| {
                const win = makeWindowData(server, toplevel);
                try list.append(allocator, win);
            }
            const wins = try list.toOwnedSlice(allocator);
            return .{ .ok = .{ .windows = wins } };
        },
        .outputs => {
            var list = std.ArrayList(protocol.OutputData).empty;
            var it = server.outputs.iterator(.forward);
            while (it.next()) |output| {
                const out = makeOutputData(server, output);
                try list.append(allocator, out);
            }
            const outs = try list.toOwnedSlice(allocator);
            return .{ .ok = .{ .outputs = outs } };
        },
        .focused_window => {
            if (findFocusedToplevel(server)) |toplevel| {
                return .{ .ok = .{ .focused_window = makeWindowData(server, toplevel) } };
            } else {
                return .{ .ok = .{ .focused_window = null } };
            }
        },
        .workspaces => {
            return .{ .ok = .{ .workspaces = &.{.{ .id = 1, .name = "Canvas", .is_focused = true }} } };
        },
        .event_stream => {
            return .{ .ok = .handled };
        },
        .event_stream_filtered => {
            return .{ .ok = .handled };
        },
        .get_state => {
            var wins = std.ArrayList(protocol.WindowData).empty;
            var win_it = server.world.toplevels.iterator(.forward);
            while (win_it.next()) |toplevel| {
                try wins.append(allocator, makeWindowData(server, toplevel));
            }

            var outs = std.ArrayList(protocol.OutputData).empty;
            var out_it = server.outputs.iterator(.forward);
            while (out_it.next()) |output| {
                try outs.append(allocator, makeOutputData(server, output));
            }

            const focused_id: ?u64 = if (findFocusedToplevel(server)) |t| t.id else null;

            return .{ .ok = .{ .state = .{
                .seq = if (server.ipc) |ipc| ipc.seq else 0,
                .session_id = if (server.ipc) |ipc| ipc.session_id else "",
                .windows = try wins.toOwnedSlice(allocator),
                .outputs = try outs.toOwnedSlice(allocator),
                .camera = makeCameraData(server),
                .focused_window_id = focused_id,
                .shell = makeShellStateData(server),
                .workspaces = &.{.{ .id = 1, .name = "Canvas", .is_focused = true }},
            } } };
        },
        .get_window_debug => |p| {
            const toplevel = findToplevelById(server, p.id) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{p.id});
                return .{ .err = msg };
            };
            const surface = toplevel.surface() orelse return .{ .err = "WindowNotVisible" };
            var src_box: wlr.FBox = undefined;
            surface.getBufferSourceBox(&src_box);

            const geometry_box = toplevel.clientGeometry();
            const decorated = toplevel.hasServerDecorations();
            const radius: f32 = toplevel.cornerRadius();
            const footer = chrome.footerHeight(radius);

            const client_box: protocol.RectData = .{
                .x = toplevel.x + if (decorated) chrome.frame_border else 0,
                .y = toplevel.y + toplevel.titlebarHeight(),
                .width = geometry_box.width,
                .height = geometry_box.height,
            };
            const chrome_box: protocol.RectData = .{
                .x = toplevel.x,
                .y = toplevel.y,
                .width = toplevel.chrome_width,
                .height = toplevel.chrome_height,
            };

            var out_names = std.ArrayList([]const u8).empty;
            var out_it = server.outputs.iterator(.forward);
            while (out_it.next()) |out| {
                var obox: wlr.Box = undefined;
                server.output_layout.getBox(out.wlr_output, &obox);
                if (obox.x < toplevel.x + toplevel.chrome_width and
                    obox.x + obox.width > toplevel.x and
                    obox.y < toplevel.y + toplevel.chrome_height and
                    obox.y + obox.height > toplevel.y)
                {
                    try out_names.append(allocator, std.mem.span(out.wlr_output.name));
                }
            }

            return .{
                .ok = .{
                    .window_debug = .{
                        .id = toplevel.id,
                        .title = toplevel.titleOrNull(),
                        .app_id = toplevel.appIdOrNull(),
                        .pid = toplevel.clientPid(),
                        .client_box = client_box,
                        .chrome_box = chrome_box,
                        .titlebar_height = toplevel.titlebarHeight(),
                        .footer_height = if (decorated) footer else 0,
                        .frame_border = if (decorated) chrome.frame_border else 0,
                        .frame_radius = if (decorated) radius else 0,
                        .decoration_mode = if (decorated) "server" else "client",
                        .minimized = toplevel.minimized,
                        .maximized = toplevel.isMaximized(),
                        .fullscreen = toplevel.isFullscreen(),
                        .is_resizing = toplevel.isResizing(),
                        .zoom_percent = @import("../camera.zig").zoom_levels[toplevel.zoom_index],
                        .effective_zoom = toplevel.zoom(),
                        .zoom_boosted = toplevel.zoom_boost.to != 0,
                        .source_box = .{ .x = src_box.x, .y = src_box.y, .width = src_box.width, .height = src_box.height },
                        // Surface width/height are logical (after scale/viewport).
                        // Report actual submitted pixels for density diagnostics.
                        .buffer_width = surface.current.buffer_width,
                        .buffer_height = surface.current.buffer_height,
                        .buffer_scale = @floatFromInt(surface.current.scale),
                        .buffer_transform = @tagName(surface.current.transform),
                        .configure_serial = toplevel.scheduledSerial(),
                        .ack_serial = toplevel.ackSerial(),
                        .outputs = try out_names.toOwnedSlice(allocator),
                        .skirt_fill = toplevel.skirt_fill,
                        .edge_sample = @tagName(toplevel.edge_kind),
                    },
                },
            };
        },
        .get_shell_state => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            const now = @import("ui").anim.nowMs();
            var start_menu_data: ?protocol.PanelStateData = null;
            if (target_out.start_menu) |sm| {
                start_menu_data = .{
                    .state = @tagName(sm.state),
                    .progress = sm.slide.value(now),
                    .is_settled = (sm.state == .open and sm.slide.settled(now)),
                    .box = .{ .x = sm.panel_box.x, .y = sm.panel_box.y, .width = sm.panel_box.width, .height = sm.panel_box.height },
                    .search_text = if (sm.model.query.items.len > 0) sm.model.query.items else null,
                    .category = @tagName(sm.model.category),
                    .selected_index = @intCast(sm.model.selected_index),
                    .result_count = sm.model.results.len,
                };
            }
            var cc_data: ?protocol.PanelStateData = null;
            if (server.input.open_control_center) |cc| {
                cc_data = controlCenterState(cc, now);
            }
            var pm_data: ?protocol.PanelStateData = null;
            if (target_out.power_menu) |pm| {
                pm_data = .{
                    .state = @tagName(pm.state),
                    .progress = pm.slide.value(now),
                    .is_settled = (pm.state == .open and pm.slide.settled(now)),
                    .box = .{ .x = pm.panel_box.x, .y = pm.panel_box.y, .width = pm.panel_box.width, .height = pm.panel_box.height },
                };
            }

            var taskbars = std.ArrayList(protocol.TaskbarData).empty;
            var it_out = server.outputs.iterator(.forward);
            while (it_out.next()) |out| {
                if (out.taskbar) |tb| {
                    var chips = std.ArrayList(protocol.TaskbarChipData).empty;
                    const focused_tl = findFocusedToplevel(server);
                    for (tb.chips.items) |chip| {
                        try chips.append(allocator, .{
                            .window_id = chip.toplevel.id,
                            .title = chip.toplevel.title(),
                            .box = .{
                                .x = tb.box.x + @as(i32, @intFromFloat(chip.target_x)),
                                .y = tb.box.y + @divTrunc(tb.box.height - 42, 2),
                                .width = @as(i32, @intFromFloat(chip.width)),
                                .height = 42,
                            },
                            .is_active = (focused_tl == chip.toplevel),
                            .is_urgent = chip.toplevel.needs_attention,
                        });
                    }
                    var right_items = std.ArrayList(protocol.TaskbarItemData).empty;
                    const items = server.config.compositor.taskbar_items;
                    for (items.order) |item| {
                        const box = tb.itemBox(item);
                        try right_items.append(allocator, .{
                            .name = @tagName(item),
                            .visible = items.shown(item),
                            .box = if (box) |b| .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } else null,
                        });
                    }
                    var app_tray = std.ArrayList(protocol.TaskbarItemData).empty;
                    if (server.tray) |tray| {
                        for (0..tb.appTrayCount()) |i| {
                            const item = tray.visibleItem(i) orelse continue;
                            const b = tb.appTrayBox(i);
                            try app_tray.append(allocator, .{ .name = item.service, .visible = true, .box = .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } });
                        }
                    }
                    const menu_box = if (server.tray) |tray| (if (tray.menu_node != null) tray.menu_box else null) else null;
                    try taskbars.append(allocator, .{
                        .output = std.mem.span(out.wlr_output.name),
                        .box = .{ .x = tb.box.x, .y = tb.box.y, .width = tb.box.width, .height = tb.box.height },
                        .start_button_box = .{
                            .x = tb.startButtonBox().x,
                            .y = tb.startButtonBox().y,
                            .width = tb.startButtonBox().width,
                            .height = tb.startButtonBox().height,
                        },
                        .right_items = try right_items.toOwnedSlice(allocator),
                        .app_tray = try app_tray.toOwnedSlice(allocator),
                        .tray_menu = if (menu_box) |b| .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height } else null,
                        .chips = try chips.toOwnedSlice(allocator),
                    });
                }
            }

            return .{ .ok = .{ .shell_state = .{
                .start_menu = start_menu_data,
                .control_center = cc_data,
                .power_menu = pm_data,
                .polkit_dialog = makeShellStateData(server).polkit_dialog,
                .taskbars = try taskbars.toOwnedSlice(allocator),
            } } };
        },
        .get_text_input => return .{ .ok = .{ .text_input = if (server.text_input) |relay| try relay.inspect(allocator) else .{} } },
        .get_input_state => {
            var mods = protocol.ModifiersData{};
            var kbd_it = server.input.keyboards.iterator(.forward);
            while (kbd_it.next()) |kbd| {
                const m = kbd.device.toKeyboard().getModifiers();
                if (m.ctrl) mods.ctrl = true;
                if (m.alt) mods.alt = true;
                if (m.shift) mods.shift = true;
                if (m.logo) mods.super = true;
                if (m.caps) mods.caps_lock = true;
            }

            var held_b = std.ArrayList(u32).empty;
            var held_k = std.ArrayList(u32).empty;
            if (client) |c| {
                var b_it = c.held_buttons.keyIterator();
                while (b_it.next()) |b| try held_b.append(allocator, b.*);
                var k_it = c.held_keys.keyIterator();
                while (k_it.next()) |k| try held_k.append(allocator, k.*);
            }

            var pointer_focused_id: ?u64 = null;
            if (server.input.seat.pointer_state.focused_surface) |psurf| {
                if (Toplevel.fromSurface(server, psurf)) |tl| pointer_focused_id = tl.id;
            }

            const keyboard_focused_id = if (findFocusedToplevel(server)) |tl| tl.id else null;

            return .{ .ok = .{ .input_state = .{
                .pointer_x = server.input.cursor.x,
                .pointer_y = server.input.cursor.y,
                .pointer_focused_window_id = pointer_focused_id,
                .keyboard_focused_window_id = keyboard_focused_id,
                .modifiers = mods,
                .held_buttons = try held_b.toOwnedSlice(allocator),
                .held_keys = try held_k.toOwnedSlice(allocator),
                .cursor_mode = @tagName(server.input.cursor_mode),
                .cursor_source = @tagName(server.input.cursor_source),
                .cursor_name = if (server.input.cursor_name) |name| std.mem.span(name) else null,
                .grabbed_window_id = if (server.input.grabbed_toplevel) |tl| tl.id else null,
                .resize_edges = if (server.input.cursor_mode == .resize and server.input.resize_session != null)
                    std.mem.span(server.input.resize_session.?.edges.cursorName())
                else
                    null,
                .has_active_sequence = server.virtual_input != null and server.virtual_input.?.active_sequence != null,
            } } };
        },
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
            try walkSceneTree(&server.scene.tree.node, &nodes, allocator, 0, max_depth, &total);
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
                        .x = ls.scene.tree.node.x,
                        .y = ls.scene.tree.node.y,
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
            return .{ .err = "InvalidPanel: expected start_menu, control_center, power_menu, taskbar, or window" };
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
        .get_idle_state => {
            return getIdleState(server, allocator);
        },
        .get_capture_state => {
            return getCaptureState(server, allocator);
        },
        .get_window_rules => |p| {
            return getWindowRules(server, p.id, allocator);
        },
        .match_window_rules => |p| {
            return matchWindowRules(server, p, allocator);
        },
        .get_night_light => {
            return getNightLight(server, allocator);
        },
        .get_notifications => {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            return .{ .ok = .{ .notifications = try notif_mgr.getNotificationsResult(allocator) } };
        },
        .action => |act| {
            return handleAction(server, request_id, act, allocator, client);
        },
    }
}

fn handleAction(
    server: *Server,
    request_id: ?protocol.RequestId,
    action: protocol.Action,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    switch (action) {
        .set_service_mode => |p| {
            const systemd = server.getSystemd() catch return .{ .err = "ServicesUnavailable" };
            systemd.setMode(p.service, p.mode) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .{ .service_mode = .{ .service = p.service, .mode = p.mode } } };
        },
        .play_sound => |p| return @import("../audio/sounds.zig").play(server, allocator, p.event) catch |err| .{ .err = @errorName(err) },
        .set_wallpaper => |p| {
            @import("settings.zig").setWallpaper(server, p.path, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_accent_color => |p| {
            @import("settings.zig").setAccent(server, p.color, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_night_light => |p| {
            @import("settings.zig").setNightLight(server, p.enabled, p.temperature, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .open_appearance => {
            server.openAppearance();
            return .{ .ok = .handled };
        },
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
            if (toplevel.isResizing() or (server.input.cursor_mode == .move and server.input.grabbed_toplevel == toplevel)) return .{ .err = "Busy" };

            if (p.output) |name| {
                const target_output = findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                };
                if (!target_output.isAvailable()) return .{ .err = "OutputUnavailable" };
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
                toplevel.setPosition(p.x, p.y);
            }
            toplevel.syncChrome(false, false, Toplevel.nowMs()) catch {};
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
        .move_cursor => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            var box: wlr.Box = undefined;
            server.output_layout.getBox(target_out.wlr_output, &box);

            if (p.x < 0 or p.y < 0 or p.x >= box.width or p.y >= box.height) {
                return .{ .err = "InvalidCoordinates: out of bounds" };
            }

            const lx: f64 = @floatFromInt(box.x + p.x);
            const ly: f64 = @floatFromInt(box.y + p.y);
            server.input.warpCursor(lx, ly, VirtualInput.nowMs());
            return .{ .ok = .handled };
        },
        .move_cursor_relative => |p| {
            const new_x = server.input.cursor.x + @as(f64, @floatFromInt(p.dx));
            const new_y = server.input.cursor.y + @as(f64, @floatFromInt(p.dy));
            server.input.warpCursor(new_x, new_y, VirtualInput.nowMs());
            return .{ .ok = .handled };
        },
        .pointer_button => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            if (client) |c| {
                if (p.pressed) {
                    try c.held_buttons.put(p.button, {});
                } else {
                    _ = c.held_buttons.remove(p.button);
                }
            }
            vi.pointer.sendButton(VirtualInput.nowMs(), p.button, if (p.pressed) .pressed else .released);
            return .{ .ok = .handled };
        },
        .click => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .pressed } });
            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .released } });

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .scroll => |p| {
            const now = VirtualInput.nowMs();
            if (p.dy != 0) {
                server.input.processAxis(now, .vertical_scroll, p.dy, 0, .continuous);
            }
            if (p.dx != 0) {
                server.input.processAxis(now, .horizontal_scroll, p.dx, 0, .continuous);
            }
            server.input.seat.pointerNotifyFrame();
            return .{ .ok = .handled };
        },
        .pinch => |p| {
            const now = VirtualInput.nowMs();
            switch (p.phase) {
                .begin => server.input.handlePinchBegin(now, p.fingers),
                .update => server.input.handlePinchUpdate(now, p.dx, p.dy, p.scale, p.rotation),
                .end => server.input.handlePinchEnd(now, p.cancelled),
            }
            return .{ .ok = .handled };
        },
        .swipe => |p| {
            const now = VirtualInput.nowMs();
            switch (p.phase) {
                .begin => server.input.handleSwipeBegin(now, p.fingers),
                .update => server.input.handleSwipeUpdate(now, p.dx, p.dy),
                .end => server.input.handleSwipeEnd(now, p.cancelled),
            }
            return .{ .ok = .handled };
        },
        .key => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            if (client) |c| {
                if (p.pressed) {
                    try c.held_keys.put(p.keycode, {});
                } else {
                    _ = c.held_keys.remove(p.keycode);
                }
            }
            vi.keyboard.sendKey(VirtualInput.nowMs(), p.keycode, if (p.pressed) .pressed else .released);
            return .{ .ok = .handled };
        },
        .key_press => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            const info = vi.keyboard.lookupKeyName(p.key) orelse {
                const msg = try std.fmt.allocPrint(allocator, "UnknownKey: {s}", .{p.key});
                return .{ .err = msg };
            };

            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            if (info.shift) {
                try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = true } });
            }
            try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .pressed } });
            try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .released } });
            if (info.shift) {
                try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = false } });
            }

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .type_text => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            if (!std.unicode.utf8ValidateSlice(p.text)) return .{ .err = "InvalidRequest: invalid UTF-8" };

            for (p.text) |byte| {
                if (vi.keyboard.lookupChar(byte) == null) {
                    const msg = try std.fmt.allocPrint(allocator, "UnsupportedCharacter: '{c}'", .{byte});
                    return .{ .err = msg };
                }
            }

            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            for (p.text) |byte| {
                const info = vi.keyboard.lookupChar(byte).?;
                if (info.shift) {
                    try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = true } });
                }
                try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .pressed } });
                try steps.append(vi.allocator, .{ .key = .{ .keycode = info.evdev_keycode, .state = .released } });
                if (info.shift) {
                    try steps.append(vi.allocator, .{ .shift_modifier = .{ .active = false } });
                }
            }

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .drag => |p| {
            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "UnknownOutput: {s}", .{name});
                    return .{ .err = msg };
                }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            var box: wlr.Box = undefined;
            server.output_layout.getBox(target_out.wlr_output, &box);

            if (p.from_x < 0 or p.from_y < 0 or p.from_x >= box.width or p.from_y >= box.height or
                p.to_x < 0 or p.to_y < 0 or p.to_x >= box.width or p.to_y >= box.height)
            {
                return .{ .err = "InvalidCoordinates: out of bounds" };
            }

            const start_x: f64 = @floatFromInt(box.x + p.from_x);
            const start_y: f64 = @floatFromInt(box.y + p.from_y);
            const end_x: f64 = @floatFromInt(box.x + p.to_x);
            const end_y: f64 = @floatFromInt(box.y + p.to_y);

            var steps = std.ArrayList(virtual_input_mod.Step).empty;
            try steps.append(vi.allocator, .{ .move_cursor = .{ .x = start_x, .y = start_y } });
            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .pressed } });

            const num_steps: usize = 10;
            var i: usize = 1;
            while (i <= num_steps) : (i += 1) {
                const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_steps));
                const cur_x = start_x + (end_x - start_x) * t;
                const cur_y = start_y + (end_y - start_y) * t;
                try steps.append(vi.allocator, .{ .move_cursor = .{ .x = cur_x, .y = cur_y } });
            }

            try steps.append(vi.allocator, .{ .pointer_button = .{ .button = p.button, .state = .released } });

            const seq = try vi.allocator.create(virtual_input_mod.Sequence);
            const duped_rid = if (request_id) |rid| try cloneRequestId(rid, vi.allocator) else null;
            seq.* = .{
                .client_id = if (client) |c| c.id else null,
                .request_id = duped_rid,
                .steps = steps,
                .on_complete = @import("server.zig").onSequenceComplete,
            };

            vi.startSequence(seq) catch |err| {
                seq.steps.deinit(vi.allocator);
                if (seq.request_id) |rid| freeRequestId(rid, vi.allocator);
                vi.allocator.destroy(seq);
                if (err == error.Busy) return .{ .err = "Busy" };
                return err;
            };

            return .{ .ok = .async_pending };
        },
        .screenshot => |p| {
            const sm = server.screenshot_mgr orelse return .{ .err = "Unsupported" };
            return sm.queueRequest(p, if (client) |c| c.id else null, request_id);
        },
        .stop_all_capture => {
            const cm = server.capture_mgr orelse return .{ .err = "Unsupported" };
            cm.stopAll();
            return .{ .ok = .handled };
        },
        .get_camera => {
            const cam = makeCameraData(server);
            return .{ .ok = .{ .camera = .{ .x = cam.x, .y = cam.y, .max_x = cam.max_x, .max_y = cam.max_y, .zoom_percent = cam.zoom_percent } } };
        },
        .set_camera => |p| {
            if (!server.input.canZoom() or server.input.cursor_mode == .pan) return .{ .err = "Busy" };
            server.world.springPan(@floatFromInt(p.x), @floatFromInt(p.y), .camera_pan);
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .set_zoom => |p| {
            if (!server.input.canZoom()) return .{ .err = "Busy" };
            for (@import("../camera.zig").zoom_levels, 0..) |percent, index| {
                if (@min(percent, 100) == p.percent) {
                    server.world.setZoom(index, server.input.cursor.x, server.input.cursor.y);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "InvalidRequest" };
        },
        .reset_camera => {
            if (!server.input.canZoom() or server.input.cursor_mode == .pan) return .{ .err = "Busy" };
            server.world.resetCamera();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .set_master_volume => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setMasterVolume(p.volume);
            return .{ .ok = .handled };
        },
        .toggle_mute => {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.toggleMasterMute();
            return .{ .ok = .handled };
        },
        .set_app_volume => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setSinkInputVolume(p.index, p.volume);
            return .{ .ok = .handled };
        },
        .set_app_mute => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setSinkInputMute(p.index, p.muted);
            return .{ .ok = .handled };
        },
        .get_audio_state => {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            return .{ .ok = .{ .audio_state = try makeAudioStateData(mgr, allocator) } };
        },
        .get_panel_stats => {
            const panel_s = @import("../panel_present.zig").snapshot();
            return .{ .ok = .{ .panel_stats = .{
                .paints = panel_s.paints,
                .allocated_bytes = panel_s.allocated_bytes,
                .reused_bytes = panel_s.reused_bytes,
                .paint_ns = panel_s.paint_ns,
            } } };
        },
        .get_animations => {
            return .{ .ok = .{ .animations = try @import("animations.zig").snapshot(server, allocator) } };
        },
        .reset_panel_stats => {
            @import("../panel_present.zig").reset();
            return .{ .ok = .handled };
        },
        .set_anim_time => |p| {
            @import("ui").anim.setNowMs(p.ms);
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_start_menu => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            // Handles the already-open and mid-close cases itself, including
            // the keyboard routing and taskbar state a bare `reopen` misses.
            output.openStartMenu();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_control_center => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            output.toggleControlCenter();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_power_menu => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            output.openPowerMenu();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },

        // Phase 1 waits
        .wait_for => |p| {
            const c = client orelse return .{ .err = "ClientRequired" };
            const ipc = server.ipc orelse return .{ .err = "IpcNotRunning" };
            return ipc.wait_mgr.registerCondition(c.id, request_id, p.condition, p.timeout_ms);
        },
        .wait_for_frame => |p| {
            const c = client orelse return .{ .err = "ClientRequired" };
            const ipc = server.ipc orelse return .{ .err = "IpcNotRunning" };
            return ipc.wait_mgr.registerFrame(c.id, request_id, p.output, p.timeout_ms);
        },

        // Phase 3 captures/stats
        .dump_buffer => |p| {
            var target_buf: ?*wlr.Buffer = null;
            var scale: f32 = 1;

            const target = std.meta.stringToEnum(DumpTarget, p.target) orelse return .{ .err = "UnknownTarget" };
            switch (target) {
                .titlebar, .skirt => {
                    const win_id = p.window_id orelse return .{ .err = "InvalidRequest: titlebar/skirt requires window_id" };
                    const toplevel = findToplevelById(server, win_id) orelse return .{ .err = "UnknownWindow" };
                    if (!toplevel.hasServerDecorations()) return .{ .err = "WindowHasNoServerDecorations" };
                    scale = toplevel.render_scale;
                    target_buf = if (target == .titlebar) toplevel.titlebar_buffer.buffer else toplevel.footer_buffer.buffer;
                },
                // Each tag names the Output field holding that panel.
                .control_center => {
                    const cc = server.input.open_control_center orelse return .{ .err = comptime DumpTarget.control_center.missingError() };
                    scale = cc.painted_scale;
                    target_buf = cc.buffer_node.buffer;
                },
                inline .taskbar, .start_menu, .power_menu => |tag| {
                    const out = if (p.output) |name| findOutputByName(server, name) else server.getDefaultOutput();
                    const target_out = out orelse return .{ .err = "NoOutput" };
                    scale = target_out.wlr_output.scale;
                    const panel = @field(target_out, @tagName(tag)) orelse return .{ .err = comptime tag.missingError() };
                    target_buf = panel.buffer_node.buffer;
                },
            }

            const buf = target_buf orelse return .{ .err = "BufferNotAttached" };
            var data_ptr: *anyopaque = undefined;
            var format: u32 = 0;
            var stride: usize = 0;
            if (!buf.beginDataPtrAccess(0, &data_ptr, &format, &stride)) {
                return .{ .err = "BufferAccessDenied" };
            }
            buf.endDataPtrAccess();

            return .{ .ok = .{ .dump_buffer = .{
                .target = p.target,
                .width = @intCast(buf.width),
                .height = @intCast(buf.height),
                .stride = @intCast(stride),
                .format = "argb8888",
                .scale = scale,
                .premultiplied = true,
                .data = null,
            } } };
        },
        .sample_pixels => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse return .{ .err = "UnknownOutput" }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            const scene_output = server.scene.getSceneOutput(target_out.wlr_output) orelse return .{ .err = "NoSceneOutput" };
            var state = wlr.Output.State.init();
            defer state.finish();
            if (!scene_output.buildState(&state, null)) return .{ .err = "CaptureFailed: scene render failed" };
            const buffer = state.buffer orelse return .{ .err = "CaptureFailed: missing frame buffer" };
            const texture = wlr.Texture.fromBuffer(server.renderer, buffer) orelse return .{ .err = "CaptureFailed: texture creation failed" };
            defer texture.destroy();

            const format = texture.preferredReadFormat();
            const count = p.width * p.height;
            const pixels = try allocator.alloc(u32, count);
            const ok = texture.readPixels(&.{
                .data = @ptrCast(pixels.ptr),
                .format = format,
                .stride = @intCast(p.width * @sizeOf(u32)),
                .dst_x = 0,
                .dst_y = 0,
                .src_box = .{ .x = p.x, .y = p.y, .width = @intCast(p.width), .height = @intCast(p.height) },
            });
            if (!ok) return .{ .err = "ReadPixelsFailed" };

            return .{ .ok = .{ .sample_pixels = .{
                .output = std.mem.span(target_out.wlr_output.name),
                .x = p.x,
                .y = p.y,
                .width = p.width,
                .height = p.height,
                .pixels = pixels,
                .gpu_readback = true,
            } } };
        },
        .get_performance_stats => {
            server.ensureGpuTimer();
            if (server.gpu_timer) |timer| timer.collect();
            const panel_s = @import("../panel_present.zig").snapshot();
            const timing = stats.global_stats.timing();
            return .{ .ok = .{ .performance_stats = .{
                .frame_work = stats.global_stats.frameWork(server.gpu_timer != null),
                .screenshot_selection = stats.global_stats.screenshot_selection,
                .output_commits = stats.global_stats.output_commits,
                .output_failed_commits = stats.global_stats.output_failed_commits,
                .fps = timing.fps,
                .frame_time_ms = timing.frame_time_ms,
                .missed_frames = timing.missed_frames,
                .refresh_hz = timing.refresh_hz,
                .titlebar_paints = stats.global_stats.titlebar_paints,
                .footer_paints = stats.global_stats.footer_paints,
                .edge_samples_attempted = stats.global_stats.edge_samples_attempted,
                .edge_samples_succeeded = stats.global_stats.edge_samples_succeeded,
                .edge_samples_skipped = stats.global_stats.edge_samples_skipped,
                .edge_sample_ns = stats.global_stats.edge_sample_ns,
                .panel_paints = panel_s.paints,
                .panel_allocated_bytes = panel_s.allocated_bytes,
                .panel_reused_bytes = panel_s.reused_bytes,
                .icon_cache_hits = stats.global_stats.icon_cache_hits,
                .icon_cache_misses = stats.global_stats.icon_cache_misses,
                .icon_decode_ns = stats.global_stats.icon_decode_ns,
                .icon_decode_count = stats.global_stats.icon_decode_count,
                .icon_decoded_bytes = stats.global_stats.icon_decoded_bytes,
                .icon_queue_depth_max = stats.global_stats.icon_queue_depth_max,
                .taskbar_paints = stats.global_stats.taskbar_paints,
                .taskbar_paint_ns = stats.global_stats.taskbar_paint_ns,
                .taskbar_raster_pixels = stats.global_stats.taskbar_raster_pixels,
                .taskbar_clock_frame_requests = stats.global_stats.taskbar_clock_frame_requests,
                .taskbar_clock_paints = stats.global_stats.taskbar_clock_paints,
                .taskbar_start_paints = stats.global_stats.taskbar_start_paints,
                .taskbar_chip_paints = stats.global_stats.taskbar_chip_paints,
                .taskbar_tray_paints = stats.global_stats.taskbar_tray_paints,
                .taskbar_hover_paints = stats.global_stats.taskbar_hover_paints,
                .taskbar_press_paints = stats.global_stats.taskbar_press_paints,
                .taskbar_audio_paints = stats.global_stats.taskbar_audio_paints,
                .recent_errors_count = stats.global_stats.errors_count,
                .anim_frames_scheduled = stats.global_stats.anim_frames_scheduled,
                .anim_wasted_wakeups = stats.global_stats.anim_wasted_wakeups,
                .anim_longest_ms = stats.global_stats.anim_longest_ms,
                .anim_speed = @import("ui").anim.speed(),
                .anim_enabled = @import("ui").anim.enabled(),
                .anim_reduced_motion = @import("ui").anim.reducedMotion(),
                .startup = startupStats(),
                .desktop = stats.global_stats.desktop,
                .output_skipped_commits = stats.global_stats.output_skipped_commits,
            } } };
        },
        .reset_performance_stats => {
            server.ensureGpuTimer();
            stats.global_stats.reset();
            @import("../panel_present.zig").reset();
            return .{ .ok = .handled };
        },

        // Phase 4 targeted actions
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
            } else if (toplevel.isMaximized()) {
                toplevel.setMaximized(false);
            } else if (toplevel.isFullscreen()) {
                toplevel.setFullscreen(false);
            }
            return .{ .ok = .handled };
        },
        .fullscreen_window => |p| {
            const toplevel = findToplevelById(server, p.id) orelse return .{ .err = "UnknownWindow" };
            _ = p.output;
            toplevel.setFullscreen(!toplevel.isFullscreen());
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
        .close_panel => |p| {
            const out = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            const panel = std.meta.stringToEnum(enum { start_menu, control_center, power_menu }, p.panel) orelse
                return .{ .err = "UnknownPanel" };
            switch (panel) {
                .start_menu => out.closeStartMenu(),
                .control_center => out.closeControlCenter(),
                .power_menu => out.closePowerMenu(),
            }
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .restart_shell => {
            @import("../config_runtime/actions.zig").executeAction(server, .restart_shell);
            return .{ .ok = .handled };
        },
        .switch_layout => |target| {
            @import("../input/layouts.zig").switchLayout(server, target) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .reload_config => {
            @import("../config_runtime/watcher.zig").reloadConfig(server);
            return .{ .ok = .handled };
        },
        .launch_app => |p| {
            const launch_mod = @import("../start_menu/launch.zig");
            const snap = server.start_menu_catalog.retainSnapshot();
            defer snap.release();
            for (snap.entries) |*entry| {
                if (std.mem.eql(u8, entry.id, p.desktop_id)) {
                    try launch_mod.launchUris(allocator, server, entry, p.uris);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "UnknownDesktopId" };
        },
        .get_idle_state => {
            return getIdleState(server, allocator);
        },
        .set_output_config => |p| {
            const output = findOutputByName(server, p.output) orelse return .{ .err = "UnknownOutput" };
            output.applyAndPersist(p) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_idle_config => |p| {
            if (server.idle) |im| {
                if (p.enabled) |e| im.config.enabled = e;
                if (p.blank_after_seconds) |b| im.config.blank_after_seconds = b;
                if (p.suspend_after_seconds) |s| im.config.suspend_after_seconds = s;
                im.recheckInhibitors();
                im.armNextTimeout();
                return .{ .ok = .handled };
            }
            return .{ .err = "IdleManagerNotAvailable" };
        },
        .advance_idle_time => |p| {
            if (server.idle) |im| {
                const current = im.clock.nowMs();
                const target = current + (@as(i64, p.seconds) * 1000);
                im.clock.mock_now_ms = target;
                im.tickTimer();
                return .{ .ok = .handled };
            }
            return .{ .err = "IdleManagerNotAvailable" };
        },
        .get_night_light => {
            return getNightLight(server, allocator);
        },
        .set_night_light_clock => |p| {
            server.night_light.setClockOverride(p.unix_seconds);
            return .{ .ok = .handled };
        },
        .dismiss_notification => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            const reason = p.reason orelse 2;
            notif_mgr.closeNotification(p.id, reason);
            return .{ .ok = .handled };
        },
        .invoke_notification_action => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.invokeAction(p.id, p.action_key);
            return .{ .ok = .handled };
        },
        .set_dnd => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.dnd = p.enabled;
            return .{ .ok = .handled };
        },
        .clear_notifications => {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.clearNotifications("all");
            return .{ .ok = .handled };
        },
        .undo => {
            @import("../config_runtime/actions.zig").executeAction(server, .undo);
            return .{ .ok = .handled };
        },
        .click_widget => |p| {
            const outcome = try resolveWidget(server, p.path, allocator);
            const target = switch (outcome) {
                .ok => |node| node,
                .panel_not_open => return .{ .err = "PanelNotOpen" },
                .not_found => return .{ .err = "NotFound" },
                .not_visible => return .{ .err = "NotVisible" },
                .disabled => return .{ .err = "Disabled" },
            };

            const gbox = target.global_box orelse return .{ .err = "NotFound" };
            const pt = computeTargetPoint(gbox, p.at);

            server.input.warpCursor(@floatFromInt(pt.x), @floatFromInt(pt.y), VirtualInput.nowMs());

            const vi = server.virtual_input orelse return .{ .err = "Unsupported" };
            const btn = p.button orelse 0x110;
            const now = VirtualInput.nowMs();
            vi.pointer.sendButton(now, btn, .pressed);
            vi.pointer.sendButton(now, btn, .released);

            if (server.ipc) |ipc| {
                var node_arena = std.heap.ArenaAllocator.init(allocator);
                defer node_arena.deinit();
                if (findWidgetNode(server, p.path, node_arena.allocator()) catch null) |updated_node| {
                    const slash_idx = std.mem.indexOfScalar(u8, p.path, '/');
                    const panel_name = if (slash_idx) |idx| p.path[0..idx] else "panel";
                    events.onWidgetChanged(ipc, panel_name, updated_node);
                }
            }

            return .{ .ok = .{ .click_widget = .{
                .point = pt,
                .x = pt.x,
                .y = pt.y,
            } } };
        },
        .hover_widget => |p| {
            const outcome = try resolveWidget(server, p.path, allocator);
            const target = switch (outcome) {
                .ok => |node| node,
                .panel_not_open => return .{ .err = "PanelNotOpen" },
                .not_found => return .{ .err = "NotFound" },
                .not_visible => return .{ .err = "NotVisible" },
                .disabled => return .{ .err = "Disabled" },
            };

            const gbox = target.global_box orelse return .{ .err = "NotFound" };
            const pt = computeTargetPoint(gbox, p.at);

            server.input.warpCursor(@floatFromInt(pt.x), @floatFromInt(pt.y), VirtualInput.nowMs());

            return .{ .ok = .{ .hover_widget = .{
                .point = pt,
                .x = pt.x,
                .y = pt.y,
            } } };
        },
    }
}

fn getNightLight(server: *Server, allocator: std.mem.Allocator) !protocol.Response {
    var outs = std.ArrayList(protocol.NightLightOutputData).empty;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const name = std.mem.span(output.wlr_output.name);
        var nl_enabled = true;
        var gamma: f32 = 1.0;
        for (server.config.outputs) |out_cfg| {
            if (std.mem.eql(u8, out_cfg.name, name)) {
                nl_enabled = out_cfg.night_light;
                gamma = out_cfg.gamma;
                break;
            }
        }
        const gamma_size = output.wlr_output.getGammaSize();
        const status: protocol.NightLightOutputStatus = switch (output.color.status) {
            .neutral => .neutral,
            .pending => .pending,
            .applied => .applied,
            .unsupported => .unsupported,
            .rejected => .rejected,
            .disabled => .disabled,
        };
        try outs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .gamma_size = gamma_size,
            .night_light = nl_enabled,
            .gamma = gamma,
            .temperature = server.night_light.outputTemperature(output),
            .status = status,
        });
    }
    const info = server.night_light.queryInfo();
    return .{ .ok = .{
        .night_light = .{
            .enabled = info.enabled,
            .schedule = try allocator.dupe(u8, info.schedule),
            .phase = info.phase,
            .temperature = info.temperature,
            .next_change_unix = info.next_change_unix,
            .clock_overridden = info.clock_overridden,
            .outputs = try outs.toOwnedSlice(allocator),
        },
    } };
}

fn getIdleState(server: *Server, allocator: std.mem.Allocator) !protocol.Response {
    const im = server.idle orelse {
        return .{ .ok = .{ .idle_state = .{
            .enabled = false,
            .state = "active",
            .blank_after_seconds = 0,
            .suspend_after_seconds = 0,
            .idle_ms = 0,
            .is_inhibited = false,
            .inhibitor_count = 0,
            .inhibitors = &[_]protocol.InhibitorData{},
            .suspend_request_count = 0,
        } } };
    };

    im.recheckInhibitors();

    var list = std.ArrayList(protocol.InhibitorData).empty;
    var it = im.inhibitors.iterator(.forward);
    while (it.next()) |tracked| {
        const surf = tracked.inhibitor.surface;
        const vis = im.checkSurfaceVisibility(surf);
        try list.append(allocator, .{
            .surface_ptr = @intFromPtr(surf),
            .window_id = vis.window_id,
            .app_id = if (vis.app_id) |a| try allocator.dupe(u8, a) else null,
            .title = if (vis.title) |t| try allocator.dupe(u8, t) else null,
            .is_active = tracked.is_effective,
            .reason = if (tracked.reason.len > 0) try allocator.dupe(u8, tracked.reason) else null,
        });
    }

    const now = im.clock.nowMs();
    const elapsed = now - im.last_activity_ms;

    return .{ .ok = .{ .idle_state = .{
        .enabled = im.isPolicyEnabled(),
        .state = @tagName(im.state),
        .blank_after_seconds = im.config.blank_after_seconds,
        .suspend_after_seconds = im.config.suspend_after_seconds,
        .idle_ms = elapsed,
        .is_inhibited = im.is_inhibited,
        .inhibitor_count = im.inhibitorCount(),
        .inhibitors = try list.toOwnedSlice(allocator),
        .suspend_request_count = @intCast(im.suspend_request_count),
    } } };
}

fn getCaptureState(server: *Server, allocator: std.mem.Allocator) !protocol.Response {
    const cm = server.capture_mgr orelse {
        return .{ .ok = .{ .capture_state = .{
            .supported = false,
            .active_sessions = 0,
            .sessions = &[_]protocol.CaptureSessionData{},
        } } };
    };

    const sessions = try cm.listSessions(allocator);
    var indicator: ?protocol.CaptureIndicatorData = null;
    if (sessions.len > 0) {
        var it = server.outputs.iterator(.forward);
        while (it.next()) |out| {
            if (out.taskbar) |tb| {
                if (tb.captureIndicatorBox()) |box| {
                    indicator = .{
                        .output = std.mem.span(out.wlr_output.name),
                        .box = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
                    };
                    break;
                }
            }
        }
    }
    return .{ .ok = .{ .capture_state = .{
        .supported = true,
        .active_sessions = sessions.len,
        .sessions = sessions,
        .last_failure = cm.last_failure,
        .indicator = indicator,
    } } };
}

fn getWindowRules(server: *Server, id: u64, allocator: std.mem.Allocator) !protocol.Response {
    const toplevel = findToplevelById(server, id) orelse {
        const msg = try std.fmt.allocPrint(allocator, "UnknownWindow: {d}", .{id});
        return .{ .err = msg };
    };
    var matched = std.ArrayList(u32).empty;
    var iter = toplevel.matched_rules.iterator(.{});
    while (iter.next()) |idx| {
        try matched.append(allocator, @intCast(idx + 1));
    }
    const effective_opacity = toplevel.effectiveOpacity(@import("ui").anim.nowMs());

    const dec_str: ?[]const u8 = if (toplevel.live_rules.decorations) |dec| dec.asString() else null;

    return .{ .ok = .{ .window_rules = .{
        .window_id = toplevel.id,
        .matched_rules = try matched.toOwnedSlice(allocator),
        .open = .{
            .output = toplevel.open_rules.getOutput(),
            .x = toplevel.open_rules.x,
            .y = toplevel.open_rules.y,
            .center = toplevel.open_rules.center,
            .width = toplevel.open_rules.width,
            .height = toplevel.open_rules.height,
            .maximized = toplevel.open_rules.maximized,
            .fullscreen = toplevel.open_rules.fullscreen,
            .focus = toplevel.open_rules.focus,
            .depth = toplevel.open_rules.depth,
        },
        .live = .{
            .opacity = toplevel.live_rules.opacity,
            .effective_opacity = effective_opacity,
            .decorations = dec_str,
            .skip_taskbar = toplevel.live_rules.skip_taskbar,
        },
        .resolved_before_app_id = toplevel.resolved_before_app_id,
    } } };
}

fn matchWindowRules(server: *Server, params: protocol.MatchWindowRulesParams, allocator: std.mem.Allocator) !protocol.Response {
    const backend: window_rules.Backend = if (params.backend) |b|
        window_rules.Backend.parse(b) catch return .{ .err = "InvalidBackend" }
    else
        .xdg;

    const id: window_rules.WindowIdentity = .{
        .app_id = params.app_id orelse "",
        .title = params.title orelse "",
        .x11_class = params.x11_class orelse "",
        .x11_instance = params.x11_instance orelse "",
        .backend = backend,
        .dialog = params.dialog orelse false,
    };
    const resolved = window_rules.resolve(server.config.window_rules, id);
    var matched = std.ArrayList(u32).empty;
    var iter = resolved.matched_rules.iterator(.{});
    while (iter.next()) |idx| {
        try matched.append(allocator, @intCast(idx + 1));
    }
    const open_r = window_rules.OpenRules.fromResolved(resolved);
    const live_r = window_rules.LiveRules.fromResolved(resolved);

    const dec_str: ?[]const u8 = if (live_r.decorations) |dec| dec.asString() else null;

    return .{ .ok = .{ .match_window_rules = .{
        .matched_rules = try matched.toOwnedSlice(allocator),
        .open = .{
            .output = open_r.getOutput(),
            .x = open_r.x,
            .y = open_r.y,
            .center = open_r.center,
            .width = open_r.width,
            .height = open_r.height,
            .maximized = open_r.maximized,
            .fullscreen = open_r.fullscreen,
            .focus = open_r.focus,
            .depth = open_r.depth,
        },
        .live = .{
            .opacity = live_r.opacity,
            .effective_opacity = null,
            .decorations = dec_str,
            .skip_taskbar = live_r.skip_taskbar,
        },
    } } };
}

fn walkSceneTree(
    node: *wlr.SceneNode,
    list: *std.ArrayList(protocol.SceneNodeData),
    allocator: std.mem.Allocator,
    current_depth: u32,
    max_depth: u32,
    total_nodes: *usize,
) !void {
    total_nodes.* += 1;
    if (current_depth > max_depth) return;

    var children_count: usize = 0;
    if (node.type == .tree) {
        const tree = wlr.SceneTree.fromNode(node);
        var it = tree.children.iterator(.forward);
        while (it.next()) |_| {
            children_count += 1;
        }
    }

    var role_str: []const u8 = "unknown";
    if (scene_data.SceneData.fromNode(node)) |data| {
        role_str = @tagName(data.role);
    }

    var box: ?protocol.RectData = null;
    if (node.type == .rect) {
        const r = wlr.SceneRect.fromNode(node);
        box = .{ .x = node.x, .y = node.y, .width = r.width, .height = r.height };
    } else if (node.type == .buffer) {
        const b = wlr.SceneBuffer.fromNode(node);
        if (b.buffer) |buf| {
            box = .{ .x = node.x, .y = node.y, .width = buf.width, .height = buf.height };
        } else {
            box = .{ .x = node.x, .y = node.y, .width = b.dst_width, .height = b.dst_height };
        }
    }

    try list.append(allocator, .{
        .id = @intFromPtr(node),
        .role = role_str,
        .node_type = @tagName(node.type),
        .enabled = node.enabled,
        .x = node.x,
        .y = node.y,
        .box = box,
        .children_count = children_count,
    });

    if (node.type == .tree) {
        const tree = wlr.SceneTree.fromNode(node);
        var it = tree.children.iterator(.forward);
        while (it.next()) |child| {
            try walkSceneTree(child, list, allocator, current_depth + 1, max_depth, total_nodes);
        }
    }
}

const ClipRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn intersect(a: ClipRect, b: ClipRect) ClipRect {
        const x1 = @max(a.x, b.x);
        const y1 = @max(a.y, b.y);
        const x2 = @min(a.x + a.width, b.x + b.width);
        const y2 = @min(a.y + a.height, b.y + b.height);
        return .{
            .x = x1,
            .y = y1,
            .width = @max(0, x2 - x1),
            .height = @max(0, y2 - y1),
        };
    }
};

pub const PanelRoot = struct {
    root: *ui.layout.Widget,
    box: wlr.Box,
};

pub const PanelRegistryEntry = struct {
    name: []const u8,
    resolve: *const fn (*Output) ?PanelRoot,
};

/// `dump_buffer` targets; the panel tags double as `Output` field names.
const DumpTarget = enum {
    titlebar,
    skirt,
    taskbar,
    start_menu,
    control_center,
    power_menu,

    fn missingError(comptime target: DumpTarget) []const u8 {
        return switch (target) {
            .taskbar => "NoTaskbar",
            .start_menu => "StartMenuNotOpen",
            .control_center => "ControlCenterNotOpen",
            .power_menu => "PowerMenuNotOpen",
            .titlebar, .skirt => @compileError("window targets have no panel"),
        };
    }
};

fn resolveStartMenu(out: *Output) ?PanelRoot {
    const sm = out.start_menu orelse return null;
    return .{ .root = &sm.root, .box = sm.panel_box };
}

fn resolveControlCenter(out: *Output) ?PanelRoot {
    const cc = out.server.input.open_control_center orelse return null;
    return .{ .root = &cc.root, .box = cc.screenBox() };
}

fn controlCenterState(cc: *const ControlCenter, now: i64) protocol.PanelStateData {
    const box = cc.screenBox();
    const toplevel = cc.toplevel;
    const opened = toplevel.map_motion.settled(now) and toplevel.map_opacity.settled(now);
    return .{
        .state = if (toplevel.minimized) "minimized" else "open",
        .progress = toplevel.map_opacity.value(now),
        .is_settled = opened and cc.settled(),
        .box = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height },
        .category = @tagName(cc.page),
    };
}

fn resolvePowerMenu(out: *Output) ?PanelRoot {
    const pm = out.power_menu orelse return null;
    return .{ .root = &pm.root, .box = pm.panel_box };
}

pub const panel_registry = [_]PanelRegistryEntry{
    .{ .name = "start_menu", .resolve = resolveStartMenu },
    .{ .name = "control_center", .resolve = resolveControlCenter },
    .{ .name = "power_menu", .resolve = resolvePowerMenu },
};

fn walkWidgetTree(
    w: *ui.layout.Widget,
    list: *std.ArrayList(protocol.WidgetNodeData),
    allocator: std.mem.Allocator,
    ancestor_path: []const u8,
    parent_index: ?usize,
    panel_x: i32,
    panel_y: i32,
    scroll_clip: ?ClipRect,
) !void {
    var label: ?[]const u8 = null;
    var semantic_id: ?[]const u8 = null;
    var is_focused = false;
    var is_disabled = false;
    var checked: ?bool = null;
    var on: ?bool = null;
    var value: ?f64 = null;
    var min: ?f64 = null;
    var max: ?f64 = null;
    var step: ?f64 = null;
    var selected_index: ?usize = null;
    var open: ?bool = null;
    var selected: ?bool = null;
    var text_length: ?usize = null;
    var scroll_offset: ?f64 = null;
    var content_size: ?f64 = null;

    switch (w.kind) {
        .button => |b| {
            label = b.label;
            semantic_id = try std.fmt.allocPrint(allocator, "btn_{s}", .{b.label});
            is_disabled = b.state == .disabled;
        },
        .text => |t| {
            label = t.content;
        },
        .row => |r| {
            semantic_id = try std.fmt.allocPrint(allocator, "row_{d}", .{r.id});
            is_focused = r.selected;
            is_disabled = r.state == .disabled;
            selected = r.selected;
        },
        .checkbox => |cb| {
            is_focused = ui.input.isFocused(w);
            is_disabled = cb.disabled;
            label = cb.label;
            semantic_id = try std.fmt.allocPrint(allocator, "cb_{s}", .{cb.label});
            checked = cb.checked;
            on = cb.checked;
        },
        .toggle => |tg| {
            is_disabled = tg.disabled;
            checked = tg.on;
            on = tg.on;
        },
        .slider => |s| {
            value = s.value;
            min = s.min;
            max = s.max;
            step = s.step;
        },
        .stepper => |st| {
            value = st.value;
            min = st.min;
            max = st.max;
            step = st.step;
        },
        .select => |s| {
            is_disabled = s.disabled;
            selected_index = s.selected;
            open = s.open;
        },
        .segmented => |seg| {
            selected_index = seg.selected;
        },
        .swatch => |sw| {
            selected = sw.selected;
        },
        .text_input => |ti| {
            is_focused = ui.input.isFocused(w);
            label = ti.placeholder;
            semantic_id = "text_input";
            text_length = ti.value.len;
        },
        // Expose focus for automation, never a secret's value or length.
        .secret_input => is_focused = ui.input.isFocused(w),
        .scroll_container => |sc| {
            scroll_offset = sc.scroll_offset;
            content_size = sc.content_size;
        },
        .arrangement => |a| {
            selected_index = a.selected;
        },
        else => {},
    }

    var path: ?[]const u8 = null;
    var child_ancestor_path = ancestor_path;
    if (w.name) |n| {
        if (ancestor_path.len > 0) {
            path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ancestor_path, n });
        } else {
            path = try allocator.dupe(u8, n);
        }
        child_ancestor_path = path.?;
    }

    const current_index = list.items.len;

    var visible = true;
    var clipped = false;
    if (scroll_clip) |clip| {
        const left = @max(w.computed_x, clip.x);
        const right = @min(w.computed_x + w.computed_width, clip.x + clip.width);
        const top = @max(w.computed_y, clip.y);
        const bottom = @min(w.computed_y + w.computed_height, clip.y + clip.height);
        const intersects = (right > left and bottom > top);
        if (!intersects) {
            visible = false;
            clipped = true;
        } else {
            visible = true;
            const fully_inside = (w.computed_x >= clip.x and
                w.computed_x + w.computed_width <= clip.x + clip.width and
                w.computed_y >= clip.y and
                w.computed_y + w.computed_height <= clip.y + clip.height);
            clipped = !fully_inside;
        }
    } else {
        visible = (w.computed_width > 0 and w.computed_height > 0);
        clipped = false;
    }

    try list.append(allocator, .{
        .id = @intFromPtr(w),
        .role = @tagName(w.kind),
        .name = w.name,
        .path = path,
        .parent_index = parent_index,
        .semantic_id = semantic_id,
        .label = label,
        .box = .{
            .x = @intFromFloat(w.computed_x),
            .y = @intFromFloat(w.computed_y),
            .width = @intFromFloat(w.computed_width),
            .height = @intFromFloat(w.computed_height),
        },
        .global_box = .{
            .x = panel_x + @as(i32, @intFromFloat(w.computed_x)),
            .y = panel_y + @as(i32, @intFromFloat(w.computed_y)),
            .width = @intFromFloat(w.computed_width),
            .height = @intFromFloat(w.computed_height),
        },
        .is_focused = is_focused,
        .is_disabled = is_disabled,
        .visible = visible,
        .clipped = clipped,
        .checked = checked,
        .on = on,
        .value = value,
        .min = min,
        .max = max,
        .step = step,
        .selected_index = selected_index,
        .open = open,
        .selected = selected,
        .text_length = text_length,
        .scroll_offset = scroll_offset,
        .content_size = content_size,
    });

    // Screens in an arrangement are painted, not child widgets: report each
    // as its own node so tests can find and drag them.
    if (w.kind == .arrangement) {
        for (w.kind.arrangement.items, 0..) |*item, i| {
            const tile = ui.widgets.arrangement.tileRect(w, i);
            const tile_box: protocol.RectData = .{
                .x = @intFromFloat(@round(tile.x)),
                .y = @intFromFloat(@round(tile.y)),
                .width = @intFromFloat(@round(tile.w)),
                .height = @intFromFloat(@round(tile.h)),
            };
            try list.append(allocator, .{
                .id = @intFromPtr(item),
                .role = "arrangement_item",
                .name = item.label,
                .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ child_ancestor_path, item.label }),
                .parent_index = current_index,
                .label = item.label,
                .box = tile_box,
                .global_box = .{ .x = panel_x + tile_box.x, .y = panel_y + tile_box.y, .width = tile_box.width, .height = tile_box.height },
                .visible = visible,
                .clipped = clipped,
                .selected = w.kind.arrangement.selected == i,
            });
        }
    }

    const child_clip: ?ClipRect = if (w.kind == .scroll_container) blk: {
        const my_clip = ClipRect{
            .x = w.computed_x,
            .y = w.computed_y,
            .width = w.computed_width,
            .height = w.computed_height,
        };
        break :blk if (scroll_clip) |sc| sc.intersect(my_clip) else my_clip;
    } else scroll_clip;

    for (w.children) |*child| {
        try walkWidgetTree(child, list, allocator, child_ancestor_path, current_index, panel_x, panel_y, child_clip);
    }
}

pub fn computeTargetPoint(gbox: protocol.RectData, at: protocol.FractionCoord) protocol.PointData {
    const at_x = std.math.clamp(at.x, 0.0, 1.0);
    const at_y = std.math.clamp(at.y, 0.0, 1.0);

    const gx: f64 = @floatFromInt(gbox.x);
    const gy: f64 = @floatFromInt(gbox.y);
    const gw: f64 = @floatFromInt(gbox.width);
    const gh: f64 = @floatFromInt(gbox.height);

    const target_x = @as(i32, @intFromFloat(@round(gx + gw * at_x)));
    const target_y = @as(i32, @intFromFloat(@round(gy + gh * at_y)));

    return .{ .x = target_x, .y = target_y };
}

pub fn findWidgetInNodes(
    nodes: []const protocol.WidgetNodeData,
    target_path: []const u8,
    subpath: []const u8,
) ?protocol.WidgetNodeData {
    // 1. Try matching full path first
    for (nodes) |node| {
        if (node.path) |p| {
            if (std.mem.eql(u8, p, target_path)) return node;
        }
    }
    // 2. Try matching widget name (either target_path or subpath)
    for (nodes) |node| {
        if (node.name) |n| {
            if (std.mem.eql(u8, n, target_path) or std.mem.eql(u8, n, subpath)) return node;
        }
    }
    // 3. Try matching semantic_id (either target_path or subpath)
    for (nodes) |node| {
        if (node.semantic_id) |s| {
            if (std.mem.eql(u8, s, target_path) or std.mem.eql(u8, s, subpath)) return node;
        }
    }
    // 4. Try matching label (either target_path or subpath)
    for (nodes) |node| {
        if (node.label) |l| {
            if (std.mem.eql(u8, l, target_path) or std.mem.eql(u8, l, subpath)) return node;
        }
    }
    return null;
}

pub const ResolveWidgetOutcome = union(enum) {
    ok: protocol.WidgetNodeData,
    panel_not_open,
    not_found,
    not_visible,
    disabled,
};

pub fn buildTaskbarWidgetTree(
    server: *Server,
    bar: *Taskbar,
    widgets: *std.ArrayList(protocol.WidgetNodeData),
    allocator: std.mem.Allocator,
) !void {
    // 0: Root taskbar
    try widgets.append(allocator, .{
        .id = 1,
        .parent_index = null,
        .role = "taskbar",
        .name = "taskbar",
        .path = "taskbar",
        .box = .{ .x = 0, .y = 0, .width = bar.box.width, .height = bar.box.height },
        .global_box = .{ .x = bar.box.x, .y = bar.box.y, .width = bar.box.width, .height = bar.box.height },
        .visible = true,
        .is_disabled = false,
    });

    // 1: Start button
    const sbox = bar.startButtonBox();
    try widgets.append(allocator, .{
        .id = 2,
        .parent_index = 0,
        .role = "button",
        .name = "start",
        .path = "taskbar/start",
        .semantic_id = "btn_Start",
        .label = "Start",
        .box = .{ .x = sbox.x - bar.box.x, .y = sbox.y - bar.box.y, .width = sbox.width, .height = sbox.height },
        .global_box = .{ .x = sbox.x, .y = sbox.y, .width = sbox.width, .height = sbox.height },
        .visible = true,
        .is_disabled = false,
    });

    // 2: Clock (if shown)
    if (bar.itemBox(.clock)) |cbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "text",
            .name = "clock",
            .path = "taskbar/clock",
            .semantic_id = "clock",
            .label = "Clock",
            .box = .{ .x = cbox.x - bar.box.x, .y = cbox.y - bar.box.y, .width = cbox.width, .height = cbox.height },
            .global_box = .{ .x = cbox.x, .y = cbox.y, .width = cbox.width, .height = cbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    // 3: Chips (taskbar/window/<id>)
    const focused_tl = findFocusedToplevel(server);
    // Same geometry as Taskbar.hitTest: animated x, themed chip height.
    const now_ms = Taskbar.nowMs();
    const ch = Taskbar.chipSize();
    for (bar.chips.items) |chip| {
        const cx = @as(i32, @intFromFloat(@round(chip.renderX(now_ms))));
        const cy = @divTrunc(bar.box.height - ch, 2);
        const cw = @as(i32, @intFromFloat(chip.width));

        const path_str = try std.fmt.allocPrint(allocator, "taskbar/window/{d}", .{chip.toplevel.id});
        const name_str = try std.fmt.allocPrint(allocator, "window/{d}", .{chip.toplevel.id});
        const sem_str = try std.fmt.allocPrint(allocator, "chip_{d}", .{chip.toplevel.id});
        const title_str = try allocator.dupe(u8, chip.toplevel.title());

        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "chip",
            .name = name_str,
            .path = path_str,
            .semantic_id = sem_str,
            .label = title_str,
            .box = .{ .x = cx, .y = cy, .width = cw, .height = ch },
            .global_box = .{ .x = bar.box.x + cx, .y = bar.box.y + cy, .width = cw, .height = ch },
            .visible = true,
            .is_disabled = false,
            .is_focused = (focused_tl == chip.toplevel),
        });
    }

    // 4: Tray items (taskbar/tray/<n>)
    if (bar.itemBox(.volume)) |vbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "tray/0",
            .path = "taskbar/tray/0",
            .semantic_id = "tray_volume",
            .label = "Volume",
            .box = .{ .x = vbox.x - bar.box.x, .y = vbox.y - bar.box.y, .width = vbox.width, .height = vbox.height },
            .global_box = .{ .x = vbox.x, .y = vbox.y, .width = vbox.width, .height = vbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }
    if (bar.itemBox(.network)) |nbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "tray/1",
            .path = "taskbar/tray/1",
            .semantic_id = "tray_network",
            .label = "Network",
            .box = .{ .x = nbox.x - bar.box.x, .y = nbox.y - bar.box.y, .width = nbox.width, .height = nbox.height },
            .global_box = .{ .x = nbox.x, .y = nbox.y, .width = nbox.width, .height = nbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    // App tray items
    if (server.tray) |_| {
        for (0..bar.appTrayCount()) |i| {
            const abox = bar.appTrayBox(i);
            const path_str = try std.fmt.allocPrint(allocator, "taskbar/tray/{d}", .{2 + i});
            const name_str = try std.fmt.allocPrint(allocator, "tray/{d}", .{2 + i});
            try widgets.append(allocator, .{
                .id = widgets.items.len + 1,
                .parent_index = 0,
                .role = "button",
                .name = name_str,
                .path = path_str,
                .box = .{ .x = abox.x - bar.box.x, .y = abox.y - bar.box.y, .width = abox.width, .height = abox.height },
                .global_box = .{ .x = abox.x, .y = abox.y, .width = abox.width, .height = abox.height },
                .visible = true,
                .is_disabled = false,
            });
        }
    }
}

pub fn buildWindowWidgetTree(
    server: *Server,
    toplevel: *Toplevel,
    widgets: *std.ArrayList(protocol.WidgetNodeData),
    allocator: std.mem.Allocator,
) !void {
    const pt = toplevel.frameWorld(0, 0);
    const ww = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.worldScale())));
    const wh = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.worldScale())));
    const is_visible = @import("../window_tabs.zig").visible(toplevel) and toplevel.in_world;
    const is_focused = (findFocusedToplevel(server) == toplevel);

    // 0: Window root
    const win_path = try std.fmt.allocPrint(allocator, "window/{d}", .{toplevel.id});
    const title_str = try allocator.dupe(u8, toplevel.title());
    try widgets.append(allocator, .{
        .id = 1,
        .parent_index = null,
        .role = "window",
        .name = "window",
        .path = win_path,
        .label = title_str,
        .box = .{ .x = 0, .y = 0, .width = toplevel.chrome_width, .height = toplevel.chrome_height },
        .global_box = .{ .x = @as(i32, @intFromFloat(@round(pt.x))), .y = @as(i32, @intFromFloat(@round(pt.y))), .width = ww, .height = wh },
        .visible = is_visible,
        .is_focused = is_focused,
        .is_disabled = false,
    });

    if (!toplevel.hasServerDecorations()) return;

    // 1: Titlebar
    const tbh = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.titlebarHeight())) * toplevel.worldScale())));
    const tb_path = try std.fmt.allocPrint(allocator, "window/{d}/titlebar", .{toplevel.id});
    try widgets.append(allocator, .{
        .id = 2,
        .parent_index = 0,
        .role = "titlebar",
        .name = "titlebar",
        .path = tb_path,
        .label = try allocator.dupe(u8, toplevel.title()),
        .box = .{ .x = 0, .y = 0, .width = toplevel.chrome_width, .height = toplevel.titlebarHeight() },
        .global_box = .{ .x = @as(i32, @intFromFloat(@round(pt.x))), .y = @as(i32, @intFromFloat(@round(pt.y))), .width = ww, .height = tbh },
        .visible = is_visible,
        .is_focused = is_focused,
        .is_disabled = false,
    });

    // 2, 3, 4: Controls (close, maximize, minimize)
    const controls = [_]struct { name: []const u8, kind: chrome.ControlKind }{
        .{ .name = "close", .kind = .close },
        .{ .name = "maximize", .kind = .maximize },
        .{ .name = "minimize", .kind = .minimize },
    };

    for (controls) |c| {
        const crect = chrome.controlRectScaled(toplevel.chrome_width, c.kind, toplevel.chromeDensity());
        const cpt = toplevel.frameWorld(@floatFromInt(crect.x), @floatFromInt(crect.y));
        const cw = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(crect.w)) * toplevel.worldScale())));
        const ch = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(crect.h)) * toplevel.worldScale())));

        const c_path = try std.fmt.allocPrint(allocator, "window/{d}/{s}", .{ toplevel.id, c.name });
        const c_sem = try std.fmt.allocPrint(allocator, "btn_{s}", .{c.name});

        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = c.name,
            .path = c_path,
            .semantic_id = c_sem,
            .label = c.name,
            .box = .{ .x = crect.x, .y = crect.y, .width = crect.w, .height = crect.h },
            .global_box = .{ .x = @as(i32, @intFromFloat(@round(cpt.x))), .y = @as(i32, @intFromFloat(@round(cpt.y))), .width = cw, .height = ch },
            .visible = is_visible,
            .is_disabled = false,
            .is_focused = is_focused,
        });
    }
    var tab_storage: [@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab = undefined;
    const strip = toplevel.tabStrip(&tab_storage);
    if (strip.tabs.len > 0) {
        const geom = @import("../chrome_tabs.zig").geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
        for (strip.tabs[geom.first..][0..geom.count], 0..) |tab, i| {
            try appendTabWidget(toplevel, widgets, allocator, try std.fmt.allocPrint(allocator, "tab/{d}", .{tab.id}), tab.title, geom.tab(i), is_visible, tab.active, false);
            try appendTabWidget(toplevel, widgets, allocator, try std.fmt.allocPrint(allocator, "tab/{d}/close", .{tab.id}), "Close tab", geom.close(i), is_visible, false, false);
        }
        try appendTabWidget(toplevel, widgets, allocator, "tab_new", "New tab", geom.plus, is_visible, false, strip.notice == .opening);
        if (geom.previous) |rect| try appendTabWidget(toplevel, widgets, allocator, "tab_previous", "Previous tab", rect, is_visible, false, false);
        if (geom.next) |rect| try appendTabWidget(toplevel, widgets, allocator, "tab_next", "Next tab", rect, is_visible, false, false);
    }
}

fn appendTabWidget(top: *Toplevel, widgets: *std.ArrayList(protocol.WidgetNodeData), a: std.mem.Allocator, name: []const u8, label: []const u8, rect: @import("ui").widgets.button.Rect, visible: bool, selected: bool, disabled: bool) !void {
    const point = top.frameWorld(rect.x, rect.y);
    try widgets.append(a, .{
        .id = widgets.items.len + 1,
        .parent_index = 1,
        .role = "button",
        .name = name,
        .path = try std.fmt.allocPrint(a, "window/{d}/{s}", .{ top.id, name }),
        .label = try a.dupe(u8, label),
        .box = .{ .x = @intFromFloat(@round(rect.x)), .y = @intFromFloat(@round(rect.y)), .width = @intFromFloat(@round(rect.w)), .height = @intFromFloat(@round(rect.h)) },
        .global_box = .{ .x = @intFromFloat(@round(point.x)), .y = @intFromFloat(@round(point.y)), .width = @intFromFloat(@round(rect.w * top.worldScale())), .height = @intFromFloat(@round(rect.h * top.worldScale())) },
        .visible = visible,
        .is_focused = selected,
        .is_disabled = disabled,
    });
}

pub fn findVirtualWidgetNode(
    server: *Server,
    path: []const u8,
    allocator: std.mem.Allocator,
) !?protocol.WidgetNodeData {
    const is_tb = std.mem.eql(u8, path, "taskbar") or std.mem.startsWith(u8, path, "taskbar/") or
        std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start");
    if (is_tb) {
        var tb: ?*Taskbar = if (server.getDefaultOutput()) |out| out.taskbar else null;
        if (tb == null) {
            var it = server.outputs.iterator(.forward);
            while (it.next()) |out| {
                if (out.taskbar) |t| {
                    tb = t;
                    break;
                }
            }
        }
        const bar = tb orelse return null;
        var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
        defer widgets.deinit(allocator);
        try buildTaskbarWidgetTree(server, bar, &widgets, allocator);

        if (std.mem.eql(u8, path, "taskbar")) return widgets.items[0];
        const subpath = if (std.mem.startsWith(u8, path, "taskbar/"))
            path["taskbar/".len..]
        else
            path;
        for (widgets.items) |w| {
            if (w.path) |wp| {
                if (std.mem.eql(u8, wp, path)) return w;
            }
            if (w.name) |wn| {
                if (std.mem.eql(u8, wn, subpath)) return w;
            }
        }
        // Aliases
        if (std.mem.eql(u8, subpath, "start_button") or std.mem.eql(u8, subpath, "start")) {
            for (widgets.items) |w| {
                if (w.name != null and std.mem.eql(u8, w.name.?, "start")) return w;
            }
        }
        if (std.mem.eql(u8, subpath, "tray/volume") or std.mem.eql(u8, subpath, "tray/0")) {
            for (widgets.items) |w| {
                if (w.name != null and std.mem.eql(u8, w.name.?, "tray/0")) return w;
            }
        }
        if (std.mem.eql(u8, subpath, "tray/network") or std.mem.eql(u8, subpath, "tray/wifi") or std.mem.eql(u8, subpath, "tray/1")) {
            for (widgets.items) |w| {
                if (w.name != null and std.mem.eql(u8, w.name.?, "tray/1")) return w;
            }
        }
        return null;
    }

    if (std.mem.startsWith(u8, path, "window/") or std.mem.eql(u8, path, "window")) {
        var target_tl: ?*Toplevel = null;
        var control_str: ?[]const u8 = null;
        if (std.mem.startsWith(u8, path, "window/")) {
            const rest = path["window/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
                const id_str = rest[0..slash_idx];
                control_str = rest[slash_idx + 1 ..];
                if (std.fmt.parseInt(u64, id_str, 10)) |id| {
                    target_tl = findToplevelById(server, id);
                } else |_| return null;
            } else {
                if (std.fmt.parseInt(u64, rest, 10)) |id| {
                    target_tl = findToplevelById(server, id);
                } else |_| {
                    target_tl = findFocusedToplevel(server) orelse server.world.toplevels.first();
                    control_str = rest;
                }
            }
        } else {
            target_tl = findFocusedToplevel(server) orelse server.world.toplevels.first();
        }

        const toplevel = target_tl orelse return null;
        var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
        defer widgets.deinit(allocator);
        try buildWindowWidgetTree(server, toplevel, &widgets, allocator);

        if (control_str) |cname| {
            for (widgets.items) |w| {
                if (w.name) |wn| {
                    if (std.mem.eql(u8, wn, cname)) return w;
                }
            }
            return null;
        } else {
            return widgets.items[0];
        }
    }

    return null;
}

pub fn findWidgetNode(
    server: *Server,
    path: []const u8,
    allocator: std.mem.Allocator,
) !?protocol.WidgetNodeData {
    if (std.mem.eql(u8, path, "taskbar") or std.mem.startsWith(u8, path, "taskbar/") or
        std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start") or
        std.mem.eql(u8, path, "window") or std.mem.startsWith(u8, path, "window/"))
    {
        return findVirtualWidgetNode(server, path, allocator);
    }

    const def_out = server.getDefaultOutput() orelse return null;

    if (std.mem.indexOfScalar(u8, path, '/')) |slash_idx| {
        const prefix = path[0..slash_idx];
        const subpath = path[slash_idx + 1 ..];

        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, prefix)) {
                const resolved = entry.resolve(def_out) orelse return null;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                return findWidgetInNodes(widgets.items, path, subpath);
            }
        }
        return null;
    } else {
        // Path has no slash. Check if path is a known panel name.
        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, path)) {
                const resolved = entry.resolve(def_out) orelse return null;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    return matched;
                }
                if (widgets.items.len > 0) {
                    var root_node = widgets.items[0];
                    root_node.path = path;
                    root_node.name = path;
                    return root_node;
                }
                return null;
            }
        }

        // Otherwise search all currently open panels
        for (panel_registry) |entry| {
            if (entry.resolve(def_out)) |resolved| {
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    return matched;
                }
            }
        }

        // Also search taskbar virtual widgets
        if (def_out.taskbar) |bar| {
            var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
            defer widgets.deinit(allocator);
            if (buildTaskbarWidgetTree(server, bar, &widgets, allocator)) |_| {
                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    return matched;
                }
            } else |_| {}
        }

        return null;
    }
}

pub fn resolveWidget(
    server: *Server,
    path: []const u8,
    allocator: std.mem.Allocator,
) !ResolveWidgetOutcome {
    if (std.mem.eql(u8, path, "taskbar") or std.mem.startsWith(u8, path, "taskbar/") or
        std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start") or
        std.mem.eql(u8, path, "window") or std.mem.startsWith(u8, path, "window/"))
    {
        const def_out = server.getDefaultOutput();
        if (std.mem.startsWith(u8, path, "taskbar") or std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start")) {
            if (def_out == null or def_out.?.taskbar == null) return .panel_not_open;
        }
        const node_opt = try findVirtualWidgetNode(server, path, allocator);
        const node = node_opt orelse return .not_found;
        if (!node.visible) return .not_visible;
        if (node.is_disabled) return .disabled;
        return .{ .ok = node };
    }

    const def_out = server.getDefaultOutput() orelse return .panel_not_open;

    if (std.mem.indexOfScalar(u8, path, '/')) |slash_idx| {
        const prefix = path[0..slash_idx];
        const subpath = path[slash_idx + 1 ..];

        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, prefix)) {
                const resolved = entry.resolve(def_out) orelse return .panel_not_open;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                const matched = findWidgetInNodes(widgets.items, path, subpath) orelse return .not_found;
                if (!matched.visible) return .not_visible;
                if (matched.is_disabled) return .disabled;
                return .{ .ok = matched };
            }
        }
        return .not_found;
    } else {
        // Path has no slash. Check if path is a known panel name.
        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, path)) {
                const resolved = entry.resolve(def_out) orelse return .panel_not_open;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    if (!matched.visible) return .not_visible;
                    if (matched.is_disabled) return .disabled;
                    return .{ .ok = matched };
                }
                if (widgets.items.len > 0) {
                    var root_node = widgets.items[0];
                    root_node.path = path;
                    root_node.name = path;
                    if (!root_node.visible) return .not_visible;
                    if (root_node.is_disabled) return .disabled;
                    return .{ .ok = root_node };
                }
                return .not_found;
            }
        }

        // Otherwise search all currently open panels
        for (panel_registry) |entry| {
            if (entry.resolve(def_out)) |resolved| {
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    if (!matched.visible) return .not_visible;
                    if (matched.is_disabled) return .disabled;
                    return .{ .ok = matched };
                }
            }
        }

        // Also search taskbar virtual widgets
        if (def_out.taskbar) |bar| {
            var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
            defer widgets.deinit(allocator);
            if (buildTaskbarWidgetTree(server, bar, &widgets, allocator)) |_| {
                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    if (!matched.visible) return .not_visible;
                    if (matched.is_disabled) return .disabled;
                    return .{ .ok = matched };
                }
            } else |_| {}
        }

        return .not_found;
    }
}

fn cloneRequestId(rid: protocol.RequestId, allocator: std.mem.Allocator) !protocol.RequestId {
    return switch (rid) {
        .integer => |i| .{ .integer = i },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

fn freeRequestId(rid: protocol.RequestId, allocator: std.mem.Allocator) void {
    switch (rid) {
        .string => |s| allocator.free(s),
        .integer => {},
    }
}

fn getBackendName(backend: *wlr.Backend) []const u8 {
    if (backend.isWl()) return "wayland";
    if (backend.isDrm()) return "drm";
    if (backend.isHeadless()) return "headless";
    if (backend.isX11()) return "x11";
    if (backend.isMulti()) return "multi";
    return "unknown";
}

fn getRendererName(renderer: *wlr.Renderer) []const u8 {
    if (renderer.isGles2()) return "gles2";
    if (renderer.isPixman()) return "pixman";
    return "unknown";
}

fn startupStats() protocol.StartupStats {
    const startup = @import("../startup.zig");
    const m = startup.marks;
    return .{
        .build_mode = m.build_mode,
        .renderer = m.renderer,
        .scale = m.scale,
        .output_count = m.output_count,
        .catalog_entries = m.catalog_entries,
        .autostart_count = m.autostart_count,
        .catalog_state = @tagName(m.catalog_state),
        .wallpaper_state = @tagName(m.wallpaper_state),
        .catalog_provisional = m.catalog_provisional,
        .catalog_loading = m.catalog_loading,
        .catalog_generation = m.catalog_generation,
        .renderer_ready_ns = startup.offset(m.renderer_ready_ns),
        .config_ready_ns = startup.offset(m.config_ready_ns),
        .catalog_cache_read_ns = startup.offset(m.catalog_cache_read_ns),
        .catalog_scan_ns = startup.offset(m.catalog_scan_ns),
        .wallpaper_decode_ns = startup.offset(m.wallpaper_decode_ns),
        .socket_ready_ns = startup.offset(m.socket_ready_ns),
        .ipc_ready_ns = startup.offset(m.ipc_ready_ns),
        .session_ready_ns = startup.offset(m.session_ready_ns),
        .session_clients_started_ns = startup.offset(m.session_clients_started_ns),
        .xwayland_ready_ns = startup.offset(m.xwayland_ready_ns),
        .first_presented_ns = startup.offset(m.first_presented_ns),
        .first_ipc_ns = startup.offset(m.first_ipc_ns),
        .first_input_ns = startup.offset(m.first_input_ns),
        .catalog_published_ns = startup.offset(m.catalog_published_ns),
        .wallpaper_presented_ns = startup.offset(m.wallpaper_presented_ns),
        .catalog_cache_read_duration_ns = m.catalog_cache_read_duration_ns,
        .catalog_scan_duration_ns = m.catalog_scan_duration_ns,
        .wallpaper_decode_duration_ns = m.wallpaper_decode_duration_ns,
    };
}

fn makeAudioStateData(mgr: anytype, allocator: std.mem.Allocator) !protocol.AudioStateData {
    mgr.lock();
    defer mgr.unlock();

    var master_volume: f32 = 0;
    var master_muted = false;
    var default_sink: []const u8 = "";
    for (mgr.sinks.items) |s| {
        if (!s.is_default) continue;
        master_volume = s.volume;
        master_muted = s.muted;
        default_sink = try allocator.dupe(u8, s.description);
    }

    var streams = std.ArrayList(protocol.SinkInputData).empty;
    for (mgr.sink_inputs.items) |si| {
        try streams.append(allocator, .{
            .index = si.index,
            .name = try allocator.dupe(u8, si.name),
            .app_id = try allocator.dupe(u8, si.app_id),
            .pid = si.pid,
            .volume = si.volume,
            .muted = si.muted,
        });
    }

    return .{
        .master_volume = master_volume,
        .master_muted = master_muted,
        .default_sink = default_sink,
        .streams = try streams.toOwnedSlice(allocator),
    };
}

pub fn makeWindowData(server: *Server, toplevel: *Toplevel) protocol.WindowData {
    const is_focused = findFocusedToplevel(server) == toplevel;

    return .{
        .id = toplevel.id,
        .title = toplevel.titleOrNull(),
        .app_id = toplevel.appIdOrNull(),
        .sandbox = toplevel.sandboxInfo(),
        .pid = toplevel.clientPid(),
        .is_focused = is_focused,
        .is_urgent = toplevel.needs_attention,
        .is_minimized = toplevel.minimized,
        .tab_group = if (toplevel.tab_group != 0) toplevel.tab_group else null,
        .tab_active = !toplevel.tab_hidden,
        .is_maximized = toplevel.isMaximized(),
        .workspace_id = 1,
        .tag = @import("../extra_protocols.zig").tag(toplevel.surface(), false),
        .description = @import("../extra_protocols.zig").tag(toplevel.surface(), true),
        .content_type = @import("../extra_protocols.zig").content(server, toplevel.surface()),
        .x = toplevel.x,
        .y = toplevel.y,
        .width = toplevel.logicalWidth(),
        .height = toplevel.logicalHeight(),
        .zoom_percent = @import("../camera.zig").zoom_levels[toplevel.zoom_index],
        .backend = toplevel.backendName(),
        .x11_class = toplevel.x11Class(),
        .x11_instance = toplevel.x11Instance(),
        .placeholder = if (toplevel.backend == .placeholder) true else null,
    };
}

pub fn makeOutputData(server: *Server, output: *Output) protocol.OutputData {
    const name = std.mem.span(output.wlr_output.name);
    const make = if (output.wlr_output.make) |m| std.mem.span(m) else null;
    const model = if (output.wlr_output.model) |m| std.mem.span(m) else null;

    const default_out = server.getDefaultOutput();
    const is_focused = if (default_out) |d| d == output else false;

    var box: wlr.Box = undefined;
    server.output_layout.getBox(output.wlr_output, &box);

    const refresh_hz: f32 = if (output.wlr_output.refresh > 0)
        @as(f32, @floatFromInt(output.wlr_output.refresh)) / 1000.0
    else
        60.0;

    const transform_str = switch (output.wlr_output.transform) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped_90",
        .flipped_180 => "flipped_180",
        .flipped_270 => "flipped_270",
        else => "normal",
    };

    return .{
        .name = name,
        .make = make,
        .model = model,
        .enabled = output.wlr_output.enabled,
        .x = box.x,
        .y = box.y,
        .logical_width = box.width,
        .logical_height = box.height,
        .bottom_exclusion = if (server.config.compositor.taskbar_position == .bottom) (if (output.taskbar) |tb| tb.box.height else 0) else 0,
        .buffer_width = output.wlr_output.width,
        .buffer_height = output.wlr_output.height,
        .transform = transform_str,
        .scale = output.wlr_output.scale,
        .refresh_hz = refresh_hz,
        .is_focused = is_focused,
    };
}

pub fn makeCameraData(server: *Server) protocol.CameraData {
    const now = @import("ui").anim.nowMs();
    const cam = server.world.sampledCamera(now);
    const offset = @import("../camera.zig").appliedOffset(cam);
    const max_xi: i32 = @intFromFloat(server.world.bounds.max_x);
    const max_yi: i32 = @intFromFloat(server.world.bounds.max_y);
    return .{
        .x = offset.x,
        .y = offset.y,
        .max_x = max_xi,
        .max_y = max_yi,
        .zoom_percent = server.world.camera.targetPercent(),
    };
}

pub fn makeShellStateData(server: *Server) protocol.ShellStateData {
    var shell = protocol.ShellStateData{};
    const now = @import("ui").anim.nowMs();
    if (server.getDefaultOutput()) |out| {
        if (out.start_menu) |sm| {
            shell.start_menu = .{
                .state = @tagName(sm.state),
                .progress = sm.slide.value(now),
                .is_settled = (sm.state == .open and sm.slide.settled(now)),
                .box = .{ .x = sm.panel_box.x, .y = sm.panel_box.y, .width = sm.panel_box.width, .height = sm.panel_box.height },
                .search_text = if (sm.model.query.items.len > 0) sm.model.query.items else null,
                .category = @tagName(sm.model.category),
                .selected_index = @intCast(sm.model.selected_index),
                .result_count = sm.model.results.len,
            };
        }
        if (server.input.open_control_center) |cc| {
            shell.control_center = controlCenterState(cc, now);
        }
        if (out.power_menu) |pm| {
            shell.power_menu = .{
                .state = @tagName(pm.state),
                .progress = pm.slide.value(now),
                .is_settled = (pm.state == .open and pm.slide.settled(now)),
                .box = .{ .x = pm.panel_box.x, .y = pm.panel_box.y, .width = pm.panel_box.width, .height = pm.panel_box.height },
            };
        }
    }
    var tb_count: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o.taskbar != null) tb_count += 1;
    }
    if (server.polkit_dialog) |dialog| shell.polkit_dialog = .{
        .state = if (dialog.ended) "failed" else if (dialog.waiting) "waiting" else "prompt",
        .box = .{ .x = dialog.panel_box.x, .y = dialog.panel_box.y, .width = dialog.panel_box.width, .height = dialog.panel_box.height },
    };
    shell.taskbar_count = tb_count;
    return shell;
}

pub fn findToplevelById(server: *Server, id: u64) ?*Toplevel {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.id == id) return toplevel;
    }
    return null;
}

pub fn findFocusedToplevel(server: *Server) ?*Toplevel {
    if (server.input.seat.keyboard_state.focused_surface) |surface| return Toplevel.fromSurface(server, surface);
    // The settings window is focused without a wl_surface.
    if (server.input.open_control_center) |cc| if (cc.hasKeyboardFocus()) return cc.toplevel;
    return null;
}

pub fn findOutputByName(server: *Server, name: []const u8) ?*Output {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const out_name = std.mem.span(output.wlr_output.name);
        if (std.mem.eql(u8, out_name, name)) return output;
    }
    return null;
}

test "walkWidgetTree builds hierarchical paths from named ancestors and preserves parent_index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var slider = ui.layout.Widget{
        .name = "output_volume",
        .kind = .{ .slider = .{ .value = 0.5, .min = 0, .max = 1, .step = 0.05, .on_change = struct {
            fn noop(_: ?*anyopaque, _: usize, _: f32) void {}
        }.noop } },
    };
    var intermediate_container = ui.layout.Widget{
        .kind = .container,
        .children = @as([*]ui.layout.Widget, @ptrCast(&slider))[0..1],
    };
    const sound_section = ui.layout.Widget{
        .name = "sound",
        .kind = .container,
        .children = @as([*]ui.layout.Widget, @ptrCast(&intermediate_container))[0..1],
    };
    const button = ui.layout.Widget{
        .name = "close",
        .kind = .{ .button = .{ .label = "Close settings" } },
    };
    var root_children = [_]ui.layout.Widget{ sound_section, button };
    var root = ui.layout.Widget{
        .kind = .container,
        .children = &root_children,
    };

    var list = std.ArrayList(protocol.WidgetNodeData).empty;
    try walkWidgetTree(&root, &list, a, "control_center", null, 100, 200, null);

    // root: index 0, parent_index null, path null (unnamed)
    try std.testing.expectEqual(@as(usize, 5), list.items.len);
    try std.testing.expect(list.items[0].parent_index == null);
    try std.testing.expect(list.items[0].path == null);

    // sound_section: index 1, parent_index 0, path control_center/sound
    try std.testing.expectEqual(@as(?usize, 0), list.items[1].parent_index);
    try std.testing.expectEqualStrings("control_center/sound", list.items[1].path.?);
    try std.testing.expectEqualStrings("sound", list.items[1].name.?);

    // intermediate_container: index 2, parent_index 1, path null (unnamed)
    try std.testing.expectEqual(@as(?usize, 1), list.items[2].parent_index);
    try std.testing.expect(list.items[2].path == null);

    // slider: index 3, parent_index 2, path control_center/sound/output_volume
    try std.testing.expectEqual(@as(?usize, 2), list.items[3].parent_index);
    try std.testing.expectEqualStrings("control_center/sound/output_volume", list.items[3].path.?);
    try std.testing.expectEqualStrings("output_volume", list.items[3].name.?);
    try std.testing.expectEqual(@as(?f64, 0.5), list.items[3].value);
    try std.testing.expectEqual(@as(?f64, 0), list.items[3].min);
    try std.testing.expectEqual(@as(?f64, 1), list.items[3].max);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), list.items[3].step.?, 0.0001);
    try std.testing.expectEqual(list.items[3].box.x + 100, list.items[3].global_box.?.x);
    try std.testing.expectEqual(list.items[3].box.y + 200, list.items[3].global_box.?.y);

    // button: index 4, parent_index 0, path control_center/close
    try std.testing.expectEqual(@as(?usize, 0), list.items[4].parent_index);
    try std.testing.expectEqualStrings("control_center/close", list.items[4].path.?);
    try std.testing.expectEqualStrings("close", list.items[4].name.?);
    try std.testing.expectEqualStrings("btn_Close settings", list.items[4].semantic_id.?);
}

test "walkWidgetTree captures per-kind state and scroll container clipping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const toggle = ui.layout.Widget{
        .name = "dark_mode",
        .kind = .{ .toggle = .{ .on = true, .on_change = struct {
            fn noop(_: ?*anyopaque, _: usize, _: bool) void {}
        }.noop } },
    };
    const text_in = ui.layout.Widget{
        .name = "search_box",
        .kind = .{ .text_input = .{
            .placeholder = "Search...",
            .value = try a.dupe(u8, "super secret input query"),
            .on_change = struct {
                fn noop(_: ?*anyopaque, _: usize, _: []const u8) void {}
            }.noop,
        } },
    };
    // Child 1 inside scroll container: partially visible
    const item1 = ui.layout.Widget{
        .computed_x = 10,
        .computed_y = 50,
        .computed_width = 80,
        .computed_height = 80,
        .kind = .container,
    };
    // Child 2 inside scroll container: completely scrolled out of view (y > 100)
    const item2 = ui.layout.Widget{
        .computed_x = 10,
        .computed_y = 150,
        .computed_width = 80,
        .computed_height = 80,
        .kind = .container,
    };
    var scroll_kids = [_]ui.layout.Widget{ item1, item2 };
    const scroll = ui.layout.Widget{
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 100,
        .computed_height = 100,
        .kind = .{ .scroll_container = .{ .scroll_offset = 20, .content_size = 300 } },
        .children = &scroll_kids,
    };
    var root_kids = [_]ui.layout.Widget{ toggle, text_in, scroll };
    var root = ui.layout.Widget{
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 200,
        .computed_height = 400,
        .kind = .container,
        .children = &root_kids,
    };

    var list = std.ArrayList(protocol.WidgetNodeData).empty;
    try walkWidgetTree(&root, &list, a, "panel", null, 50, 60, null);

    // Toggle widget checks
    const tg_node = list.items[1];
    try std.testing.expectEqualStrings("toggle", tg_node.role);
    try std.testing.expectEqual(@as(?bool, true), tg_node.on);
    try std.testing.expectEqual(@as(?bool, true), tg_node.checked);

    // TextInput widget checks: returns text_length and placeholder label, NEVER contents
    const ti_node = list.items[2];
    try std.testing.expectEqualStrings("text_input", ti_node.role);
    try std.testing.expectEqualStrings("Search...", ti_node.label.?);
    try std.testing.expectEqual(@as(?usize, 24), ti_node.text_length);

    // ScrollContainer checks
    const sc_node = list.items[3];
    try std.testing.expectEqualStrings("scroll_container", sc_node.role);
    try std.testing.expectEqual(@as(?f64, 20), sc_node.scroll_offset);
    try std.testing.expectEqual(@as(?f64, 300), sc_node.content_size);

    // item1: [50, 130] in y, scroll container viewport is [0, 100]. Overlaps -> visible = true, clipped = true
    const item1_node = list.items[4];
    try std.testing.expectEqual(true, item1_node.visible);
    try std.testing.expectEqual(true, item1_node.clipped);

    // item2: [150, 230] in y, outside [0, 100] -> visible = false, clipped = true
    const item2_node = list.items[5];
    try std.testing.expectEqual(false, item2_node.visible);
    try std.testing.expectEqual(true, item2_node.clipped);
}

test "computeTargetPoint calculates coordinates with fractional offsets and clamping" {
    const box = protocol.RectData{
        .x = 100,
        .y = 200,
        .width = 50,
        .height = 40,
    };

    // Default center (0.5, 0.5)
    const center = computeTargetPoint(box, .{ .x = 0.5, .y = 0.5 });
    try std.testing.expectEqual(@as(i32, 125), center.x);
    try std.testing.expectEqual(@as(i32, 220), center.y);

    // Top-left (0.0, 0.0)
    const top_left = computeTargetPoint(box, .{ .x = 0.0, .y = 0.0 });
    try std.testing.expectEqual(@as(i32, 100), top_left.x);
    try std.testing.expectEqual(@as(i32, 200), top_left.y);

    // Bottom-right (1.0, 1.0)
    const bottom_right = computeTargetPoint(box, .{ .x = 1.0, .y = 1.0 });
    try std.testing.expectEqual(@as(i32, 150), bottom_right.x);
    try std.testing.expectEqual(@as(i32, 240), bottom_right.y);

    // Slider fraction (0.2, 0.5)
    const slider_pt = computeTargetPoint(box, .{ .x = 0.2, .y = 0.5 });
    try std.testing.expectEqual(@as(i32, 110), slider_pt.x);
    try std.testing.expectEqual(@as(i32, 220), slider_pt.y);

    // Out-of-bounds clamped to [0, 1]
    const clamped_pt = computeTargetPoint(box, .{ .x = -0.5, .y = 1.5 });
    try std.testing.expectEqual(@as(i32, 100), clamped_pt.x);
    try std.testing.expectEqual(@as(i32, 240), clamped_pt.y);
}

test "findWidgetInNodes resolves by path, name, or semantic_id" {
    const nodes = [_]protocol.WidgetNodeData{
        .{
            .id = 1,
            .role = "button",
            .name = "tab_sound",
            .path = "control_center/tab_sound",
            .semantic_id = "btn_Sound",
            .label = "Sound",
            .box = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
            .global_box = .{ .x = 10, .y = 20, .width = 100, .height = 40 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 2,
            .role = "button",
            .name = "disabled_btn",
            .path = "control_center/disabled_btn",
            .semantic_id = "btn_Disabled",
            .box = .{ .x = 0, .y = 40, .width = 100, .height = 40 },
            .global_box = .{ .x = 10, .y = 60, .width = 100, .height = 40 },
            .visible = true,
            .is_disabled = true,
        },
        .{
            .id = 3,
            .role = "row",
            .name = "hidden_row",
            .path = "control_center/hidden_row",
            .semantic_id = "row_3",
            .box = .{ .x = 0, .y = 80, .width = 100, .height = 40 },
            .global_box = .{ .x = 10, .y = 100, .width = 100, .height = 40 },
            .visible = false,
            .is_disabled = false,
        },
    };

    // Match by full path
    const m1 = findWidgetInNodes(&nodes, "control_center/tab_sound", "tab_sound");
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(u64, 1), m1.?.id);

    // Match by subpath / name
    const m2 = findWidgetInNodes(&nodes, "tab_sound", "tab_sound");
    try std.testing.expect(m2 != null);
    try std.testing.expectEqual(@as(u64, 1), m2.?.id);

    // Match by semantic_id
    const m3 = findWidgetInNodes(&nodes, "btn_Sound", "btn_Sound");
    try std.testing.expect(m3 != null);
    try std.testing.expectEqual(@as(u64, 1), m3.?.id);

    // Match disabled widget
    const m4 = findWidgetInNodes(&nodes, "control_center/disabled_btn", "disabled_btn");
    try std.testing.expect(m4 != null);
    try std.testing.expect(m4.?.is_disabled);

    // Match invisible widget
    const m5 = findWidgetInNodes(&nodes, "control_center/hidden_row", "hidden_row");
    try std.testing.expect(m5 != null);
    try std.testing.expect(!m5.?.visible);

    // Not found
    const m6 = findWidgetInNodes(&nodes, "control_center/nonexistent", "nonexistent");
    try std.testing.expect(m6 == null);
}

test "findWidgetInNodes resolves Phase 5 taskbar and window hotspot nodes" {
    const taskbar_nodes = [_]protocol.WidgetNodeData{
        .{
            .id = 1,
            .role = "panel",
            .name = "taskbar",
            .path = "taskbar",
            .box = .{ .x = 0, .y = 0, .width = 1920, .height = 64 },
            .global_box = .{ .x = 0, .y = 1016, .width = 1920, .height = 64 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 2,
            .role = "button",
            .name = "start",
            .path = "taskbar/start",
            .semantic_id = "btn_Start",
            .label = "Start",
            .box = .{ .x = 16, .y = 11, .width = 42, .height = 42 },
            .global_box = .{ .x = 16, .y = 1027, .width = 42, .height = 42 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 3,
            .role = "label",
            .name = "clock",
            .path = "taskbar/clock",
            .semantic_id = "taskbar_clock",
            .label = "Clock",
            .box = .{ .x = 1800, .y = 11, .width = 100, .height = 42 },
            .global_box = .{ .x = 1800, .y = 1027, .width = 100, .height = 42 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 4,
            .role = "button",
            .name = "chip_42",
            .path = "taskbar/window/42",
            .semantic_id = "chip_42",
            .label = "Terminal",
            .box = .{ .x = 74, .y = 11, .width = 120, .height = 42 },
            .global_box = .{ .x = 74, .y = 1027, .width = 120, .height = 42 },
            .visible = true,
            .is_disabled = false,
            .is_focused = true,
        },
        .{
            .id = 5,
            .role = "button",
            .name = "tray/0",
            .path = "taskbar/tray/0",
            .semantic_id = "tray_volume",
            .label = "Volume",
            .box = .{ .x = 1720, .y = 11, .width = 32, .height = 32 },
            .global_box = .{ .x = 1720, .y = 1027, .width = 32, .height = 32 },
            .visible = true,
            .is_disabled = false,
        },
        .{
            .id = 6,
            .role = "button",
            .name = "tray/1",
            .path = "taskbar/tray/1",
            .semantic_id = "tray_network",
            .label = "Network",
            .box = .{ .x = 1760, .y = 11, .width = 32, .height = 32 },
            .global_box = .{ .x = 1760, .y = 1027, .width = 32, .height = 32 },
            .visible = true,
            .is_disabled = false,
        },
    };

    // Taskbar hotspot queries
    const start_node = findWidgetInNodes(&taskbar_nodes, "taskbar/start", "start");
    try std.testing.expect(start_node != null);
    try std.testing.expectEqualStrings("btn_Start", start_node.?.semantic_id.?);

    const clock_node = findWidgetInNodes(&taskbar_nodes, "taskbar/clock", "clock");
    try std.testing.expect(clock_node != null);
    try std.testing.expectEqualStrings("taskbar_clock", clock_node.?.semantic_id.?);

    const chip_node = findWidgetInNodes(&taskbar_nodes, "taskbar/window/42", "window/42");
    try std.testing.expect(chip_node != null);
    try std.testing.expectEqualStrings("chip_42", chip_node.?.semantic_id.?);
    try std.testing.expect(chip_node.?.is_focused);

    const tray_vol = findWidgetInNodes(&taskbar_nodes, "taskbar/tray/0", "tray/0");
    try std.testing.expect(tray_vol != null);
    try std.testing.expectEqualStrings("tray_volume", tray_vol.?.semantic_id.?);

    // Window controls
    const window_nodes = [_]protocol.WidgetNodeData{
        .{
            .id = 1,
            .role = "window",
            .name = "window",
            .path = "window/42",
            .label = "Terminal",
            .box = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
            .global_box = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 2,
            .role = "titlebar",
            .name = "titlebar",
            .path = "window/42/titlebar",
            .label = "Terminal",
            .box = .{ .x = 0, .y = 0, .width = 800, .height = 38 },
            .global_box = .{ .x = 100, .y = 100, .width = 800, .height = 38 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 3,
            .role = "button",
            .name = "close",
            .path = "window/42/close",
            .semantic_id = "btn_close",
            .label = "close",
            .box = .{ .x = 760, .y = 4, .width = 32, .height = 30 },
            .global_box = .{ .x = 860, .y = 104, .width = 32, .height = 30 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 4,
            .role = "button",
            .name = "maximize",
            .path = "window/42/maximize",
            .semantic_id = "btn_maximize",
            .label = "maximize",
            .box = .{ .x = 724, .y = 4, .width = 32, .height = 30 },
            .global_box = .{ .x = 824, .y = 104, .width = 32, .height = 30 },
            .visible = true,
            .is_focused = true,
        },
        .{
            .id = 5,
            .role = "button",
            .name = "minimize",
            .path = "window/42/minimize",
            .semantic_id = "btn_minimize",
            .label = "minimize",
            .box = .{ .x = 688, .y = 4, .width = 32, .height = 30 },
            .global_box = .{ .x = 788, .y = 104, .width = 32, .height = 30 },
            .visible = true,
            .is_focused = true,
        },
    };

    const win_root = findWidgetInNodes(&window_nodes, "window/42", "window/42");
    try std.testing.expect(win_root != null);
    try std.testing.expectEqualStrings("window", win_root.?.role);

    const win_close = findWidgetInNodes(&window_nodes, "window/42/close", "close");
    try std.testing.expect(win_close != null);
    try std.testing.expectEqualStrings("btn_close", win_close.?.semantic_id.?);

    const win_max = findWidgetInNodes(&window_nodes, "window/42/maximize", "maximize");
    try std.testing.expect(win_max != null);
    try std.testing.expectEqualStrings("btn_maximize", win_max.?.semantic_id.?);

    const win_min = findWidgetInNodes(&window_nodes, "window/42/minimize", "minimize");
    try std.testing.expect(win_min != null);
    try std.testing.expectEqualStrings("btn_minimize", win_min.?.semantic_id.?);
}
