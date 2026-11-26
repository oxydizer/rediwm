//! Evaluating wait conditions, including widget state, and cloning conditions and request ids for storage.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const handlers = @import("handlers.zig");
const WaitManager = @import("wait.zig").WaitManager;

pub fn checkWidgetState(node: protocol.WidgetNodeData, field: []const u8, equals: protocol.WidgetStateValue) bool {
    if (std.mem.eql(u8, field, "visible")) {
        return equals == .boolean and node.visible == equals.boolean;
    } else if (std.mem.eql(u8, field, "clipped")) {
        return equals == .boolean and node.clipped == equals.boolean;
    } else if (std.mem.eql(u8, field, "focused") or std.mem.eql(u8, field, "is_focused")) {
        return equals == .boolean and node.is_focused == equals.boolean;
    } else if (std.mem.eql(u8, field, "disabled") or std.mem.eql(u8, field, "is_disabled")) {
        return equals == .boolean and node.is_disabled == equals.boolean;
    } else if (std.mem.eql(u8, field, "checked")) {
        return switch (equals) {
            .boolean => |b| node.checked != null and node.checked.? == b,
            .null_value => node.checked == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "on")) {
        return switch (equals) {
            .boolean => |b| node.on != null and node.on.? == b,
            .null_value => node.on == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "open")) {
        return switch (equals) {
            .boolean => |b| node.open != null and node.open.? == b,
            .null_value => node.open == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "selected")) {
        return switch (equals) {
            .boolean => |b| node.selected != null and node.selected.? == b,
            .null_value => node.selected == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "value")) {
        return switch (equals) {
            .number => |n| node.value != null and @abs(node.value.? - n) < 0.001,
            .null_value => node.value == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "min")) {
        return switch (equals) {
            .number => |n| node.min != null and @abs(node.min.? - n) < 0.001,
            .null_value => node.min == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "max")) {
        return switch (equals) {
            .number => |n| node.max != null and @abs(node.max.? - n) < 0.001,
            .null_value => node.max == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "step")) {
        return switch (equals) {
            .number => |n| node.step != null and @abs(node.step.? - n) < 0.001,
            .null_value => node.step == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "selected_index")) {
        return switch (equals) {
            .number => |n| node.selected_index != null and node.selected_index.? == @as(usize, @intFromFloat(n)),
            .null_value => node.selected_index == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "text_length")) {
        return switch (equals) {
            .number => |n| node.text_length != null and node.text_length.? == @as(usize, @intFromFloat(n)),
            .null_value => node.text_length == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "scroll_offset")) {
        return switch (equals) {
            .number => |n| node.scroll_offset != null and @abs(node.scroll_offset.? - n) < 0.001,
            .null_value => node.scroll_offset == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "content_size")) {
        return switch (equals) {
            .number => |n| node.content_size != null and @abs(node.content_size.? - n) < 0.001,
            .null_value => node.content_size == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "label")) {
        return switch (equals) {
            .string => |s| node.label != null and std.mem.eql(u8, node.label.?, s),
            .null_value => node.label == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "name")) {
        return switch (equals) {
            .string => |s| node.name != null and std.mem.eql(u8, node.name.?, s),
            .null_value => node.name == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "role")) {
        return switch (equals) {
            .string => |s| std.mem.eql(u8, node.role, s),
            else => false,
        };
    } else if (std.mem.eql(u8, field, "path")) {
        return switch (equals) {
            .string => |s| node.path != null and std.mem.eql(u8, node.path.?, s),
            .null_value => node.path == null,
            else => false,
        };
    } else if (std.mem.eql(u8, field, "semantic_id")) {
        return switch (equals) {
            .string => |s| node.semantic_id != null and std.mem.eql(u8, node.semantic_id.?, s),
            .null_value => node.semantic_id == null,
            else => false,
        };
    }
    return false;
}

pub fn isConditionMet(mgr: *WaitManager, cond: protocol.WaitCondition, now: i64) bool {
    switch (cond) {
        .menu_opened => {
            const out = mgr.server.getDefaultOutput() orelse return false;
            const sm = out.start_menu orelse return false;
            return (sm.state == .open or (sm.state == .opening and sm.slide.settled(now)));
        },
        .menu_closed => {
            const out = mgr.server.getDefaultOutput() orelse return true;
            return out.start_menu == null;
        },
        .control_center_opened => {
            const cc = mgr.server.input.open_control_center orelse return false;
            return cc.settled();
        },
        .control_center_closed => {
            return mgr.server.input.open_control_center == null;
        },
        .power_menu_opened => {
            const out = mgr.server.getDefaultOutput() orelse return false;
            const pm = out.power_menu orelse return false;
            return (pm.state == .open or (pm.state == .opening and pm.slide.settled(now)));
        },
        .power_menu_closed => {
            const out = mgr.server.getDefaultOutput() orelse return true;
            return out.power_menu == null;
        },
        .window_mapped => |p| {
            if (p.id) |id| {
                if (mgr.server.findToplevelById(id)) |top| {
                    return top.isMapped();
                }
                return false;
            }
            var it = mgr.server.world.toplevels.iterator(.forward);
            while (it.next()) |top| {
                if (!top.isMapped()) continue;
                if (p.app_id) |app| {
                    if (!std.mem.eql(u8, top.appId(), app)) continue;
                }
                if (p.title) |title| {
                    if (!std.mem.eql(u8, top.title(), title)) continue;
                }
                return true;
            }
            return false;
        },
        .window_closed => |p| {
            return mgr.server.findToplevelById(p.id) == null;
        },
        .window_focused => |p| {
            const focused_surface = mgr.server.input.seat.keyboard_state.focused_surface;
            if (p.id) |id| {
                const top = mgr.server.findToplevelById(id) orelse return false;
                return if (focused_surface) |s| Toplevel.fromSurface(mgr.server, s) == top else false;
            } else {
                return focused_surface == null;
            }
        },
        .window_geometry_settled => |p| {
            const top = mgr.server.findToplevelById(p.id) orelse return false;
            return top.isGeometrySettled(now) and !@import("../scroll_tiling.zig").moving(mgr.server, top.workspace_id);
        },
        .output_frame => return false, // handled directly on frame
        .catalog_published => return @import("../startup.zig").marks.catalog_state == .published,
        .wallpaper_presented => return @import("../startup.zig").marks.wallpaper_state == .presented,
        .notification_count => |p| {
            const notif_mgr = mgr.server.notifications orelse return false;
            var count: usize = 0;
            for (notif_mgr.toasts.items) |t| {
                if (p.app_name) |app| {
                    if (!std.mem.eql(u8, t.app_name, app)) continue;
                }
                if (p.summary) |sum| {
                    if (!std.mem.eql(u8, t.summary, sum)) continue;
                }
                count += 1;
            }
            if (p.count) |expected| {
                return count == expected;
            } else {
                return count > 0;
            }
        },
        .notification_closed => |p| {
            const notif_mgr = mgr.server.notifications orelse return false;
            if (notif_mgr.findToast(p.id) != null) return false;
            for (notif_mgr.history.items) |rec| {
                if (rec.id == p.id and rec.closed) return true;
            }
            return false;
        },
        .notification_action => return false,
        .launch_started => |p| {
            var it = mgr.server.world.toplevels.iterator(.forward);
            while (it.next()) |top| {
                if (top.backend == .placeholder) {
                    const ph = &top.backend.placeholder;
                    if (p.desktop_id) |target| {
                        if (std.mem.eql(u8, target, ph.desktop_id)) return true;
                    } else {
                        return true;
                    }
                } else if (top.isMapped()) {
                    if (p.desktop_id) |target| {
                        const stem = if (std.mem.endsWith(u8, target, ".desktop"))
                            target[0 .. target.len - ".desktop".len]
                        else
                            target;
                        if (std.ascii.eqlIgnoreCase(top.appId(), target) or
                            std.ascii.eqlIgnoreCase(top.appId(), stem))
                        {
                            return true;
                        }
                    }
                }
            }
            return false;
        },
        .launch_matched => |p| {
            var it = mgr.server.world.toplevels.iterator(.forward);
            while (it.next()) |top| {
                if (top.backend != .placeholder and top.isMapped()) {
                    if (p.window_id) |wid| {
                        if (top.id != wid) continue;
                    }
                    if (p.desktop_id) |target| {
                        const stem = if (std.mem.endsWith(u8, target, ".desktop"))
                            target[0 .. target.len - ".desktop".len]
                        else
                            target;
                        if (std.ascii.eqlIgnoreCase(top.appId(), target) or
                            std.ascii.eqlIgnoreCase(top.appId(), stem))
                        {
                            return true;
                        }
                    } else {
                        return true;
                    }
                }
            }
            return false;
        },
        .launch_timeout => return false,
        .widget_present => |p| {
            var arena = std.heap.ArenaAllocator.init(mgr.allocator);
            defer arena.deinit();
            const node = handlers.findWidgetNode(mgr.server, p.path, arena.allocator()) catch return false;
            return node != null;
        },
        .widget_absent => |p| {
            var arena = std.heap.ArenaAllocator.init(mgr.allocator);
            defer arena.deinit();
            const node = handlers.findWidgetNode(mgr.server, p.path, arena.allocator()) catch return false;
            return node == null;
        },
        .widget_state => |p| {
            var arena = std.heap.ArenaAllocator.init(mgr.allocator);
            defer arena.deinit();
            const node_opt = handlers.findWidgetNode(mgr.server, p.path, arena.allocator()) catch return false;
            const node = node_opt orelse return false;
            return checkWidgetState(node, p.field, p.equals);
        },
        .panel_settled => |p| {
            const out = mgr.server.getDefaultOutput() orelse return false;
            if (std.mem.eql(u8, p.panel, "control_center")) {
                const cc = mgr.server.input.open_control_center orelse return false;
                // The window's own open animation must be done, too.
                return cc.settled() and cc.toplevel.map_motion.settled(now) and cc.toplevel.map_opacity.settled(now);
            } else if (std.mem.eql(u8, p.panel, "start_menu") or std.mem.eql(u8, p.panel, "menu")) {
                const sm = out.start_menu orelse return false;
                return sm.state == .open and sm.slide.settled(now) and !sm.dirty;
            } else if (std.mem.eql(u8, p.panel, "power_menu")) {
                const pm = out.power_menu orelse return false;
                return pm.state == .open and pm.slide.settled(now) and !pm.dirty and (pm.state != .selecting or pm.selection_presented);
            } else if (std.mem.eql(u8, p.panel, "taskbar")) {
                const tb = out.taskbar orelse return false;
                return !tb.dirty;
            }
            return false;
        },
    }
}

pub fn cloneCondition(mgr: *WaitManager, cond: protocol.WaitCondition) !protocol.WaitCondition {
    switch (cond) {
        .window_mapped => |p| {
            const app_id = if (p.app_id) |a| try mgr.allocator.dupe(u8, a) else null;
            errdefer if (app_id) |a| mgr.allocator.free(a);
            const title = if (p.title) |t| try mgr.allocator.dupe(u8, t) else null;
            return .{ .window_mapped = .{ .id = p.id, .app_id = app_id, .title = title } };
        },
        .output_frame => |p| {
            const output = if (p.output) |o| try mgr.allocator.dupe(u8, o) else null;
            return .{ .output_frame = .{ .output = output } };
        },
        .notification_count => |p| {
            const app_name = if (p.app_name) |a| try mgr.allocator.dupe(u8, a) else null;
            errdefer if (app_name) |a| mgr.allocator.free(a);
            const summary = if (p.summary) |s| try mgr.allocator.dupe(u8, s) else null;
            return .{ .notification_count = .{ .count = p.count, .app_name = app_name, .summary = summary } };
        },
        .notification_action => |p| {
            const action_key = if (p.action_key) |k| try mgr.allocator.dupe(u8, k) else null;
            return .{ .notification_action = .{ .id = p.id, .action_key = action_key } };
        },
        .launch_started => |p| {
            const desktop_id = if (p.desktop_id) |d| try mgr.allocator.dupe(u8, d) else null;
            return .{ .launch_started = .{ .desktop_id = desktop_id } };
        },
        .launch_matched => |p| {
            const desktop_id = if (p.desktop_id) |d| try mgr.allocator.dupe(u8, d) else null;
            return .{ .launch_matched = .{ .desktop_id = desktop_id, .window_id = p.window_id } };
        },
        .launch_timeout => |p| {
            const desktop_id = if (p.desktop_id) |d| try mgr.allocator.dupe(u8, d) else null;
            return .{ .launch_timeout = .{ .desktop_id = desktop_id } };
        },
        .widget_present => |p| {
            const path = try mgr.allocator.dupe(u8, p.path);
            return .{ .widget_present = .{ .path = path } };
        },
        .widget_absent => |p| {
            const path = try mgr.allocator.dupe(u8, p.path);
            return .{ .widget_absent = .{ .path = path } };
        },
        .widget_state => |p| {
            const path = try mgr.allocator.dupe(u8, p.path);
            errdefer mgr.allocator.free(path);
            const field = try mgr.allocator.dupe(u8, p.field);
            errdefer mgr.allocator.free(field);
            const equals: protocol.WidgetStateValue = switch (p.equals) {
                .string => |s| .{ .string = try mgr.allocator.dupe(u8, s) },
                .boolean => |b| .{ .boolean = b },
                .number => |n| .{ .number = n },
                .null_value => .null_value,
            };
            return .{ .widget_state = .{ .path = path, .field = field, .equals = equals } };
        },
        .panel_settled => |p| {
            const panel = try mgr.allocator.dupe(u8, p.panel);
            return .{ .panel_settled = .{ .panel = panel } };
        },
        else => return cond,
    }
}

pub fn cloneRequestId(mgr: *WaitManager, rid: protocol.RequestId) !protocol.RequestId {
    return switch (rid) {
        .integer => |i| .{ .integer = i },
        .string => |s| .{ .string = try mgr.allocator.dupe(u8, s) },
    };
}
