//! Synthetic input actions: pointer, keys, text, gestures, drags and widget clicks.

const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const protocol = @import("protocol.zig");
const virtual_input_mod = @import("../input/virtual.zig");
const VirtualInput = virtual_input_mod.VirtualInput;
const Client = @import("server.zig").Client;
const events = @import("events.zig");
const handlers_widgets = @import("handlers_widgets.zig");
const handlers_data = @import("handlers_data.zig");
const computeTargetPoint = handlers_widgets.computeTargetPoint;
const findWidgetNode = handlers_widgets.findWidgetNode;
const resolveWidget = handlers_widgets.resolveWidget;
const cloneRequestId = handlers_data.cloneRequestId;
const freeRequestId = handlers_data.freeRequestId;
const findOutputByName = handlers_data.findOutputByName;
const handlers = @import("handlers.zig");
const handleAction = handlers.handleAction;

pub fn handleInputAction(
    server: *Server,
    request_id: ?protocol.RequestId,
    action: protocol.Action,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    switch (action) {
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
                server.input.processAxis(now, .vertical_scroll, p.dy, 0, .continuous, .identical);
            }
            if (p.dx != 0) {
                server.input.processAxis(now, .horizontal_scroll, p.dx, 0, .continuous, .identical);
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
        else => unreachable,
    }
}
