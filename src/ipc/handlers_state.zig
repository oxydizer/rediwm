//! State queries: the full state snapshot, window debug, shell state, text input and input state.

const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const chrome = @import("../chrome.zig");
const Client = @import("server.zig").Client;
const handlers_panels = @import("handlers_panels.zig");
const handlers_data = @import("handlers_data.zig");
const controlCenterState = handlers_panels.controlCenterState;
const makeWindowData = handlers_data.makeWindowData;
const makeOutputData = handlers_data.makeOutputData;
const makeCameraData = handlers_data.makeCameraData;
const makeShellStateData = handlers_data.makeShellStateData;
const findToplevelById = handlers_data.findToplevelById;
const findFocusedToplevel = handlers_data.findFocusedToplevel;
const findOutputByName = handlers_data.findOutputByName;
const handlers = @import("handlers.zig");
const handleRequest = handlers.handleRequest;

pub fn handleStateRequest(
    server: *Server,
    request_id: ?protocol.RequestId,
    request: protocol.Request,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    _ = request_id;
    switch (request) {
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
                .workspaces = try server.world.workspaces.data(server, allocator),
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
            const footer = chrome.frameBorder();

            const client_box: protocol.RectData = .{
                .x = toplevel.x + if (decorated) chrome.frameBorder() else 0,
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
                        .frame_border = if (decorated) chrome.frameBorder() else 0,
                        .frame_radius = if (decorated) radius else 0,
                        .decoration_mode = if (decorated) "server" else "client",
                        .minimized = toplevel.minimized,
                        .maximized = toplevel.isMaximized(),
                        .fullscreen = toplevel.isFullscreen(),
                        .is_resizing = toplevel.isResizing(),
                        .zoom_percent = if (server.world.workspaces.active) 100 else @import("../camera.zig").zoom_levels[toplevel.zoom_index],
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
                        // Kept for the wire format: frames have had no skirt to
                        // sample since the window shapes (stage 4e).
                        .skirt_fill = null,
                        .edge_sample = "none",
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
                                .x = tb.box.x + @as(i32, @intFromFloat(@round(chip.renderX(now)))),
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
                        // Keep the existing status-item IPC contract.
                        if (item == .start or item == .windows or item == .tray) continue;
                        const box = tb.itemBox(item);
                        try right_items.append(allocator, .{
                            .name = @tagName(item),
                            .visible = items.resolved(item, tb.network_presence),
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
        else => unreachable,
    }
}
