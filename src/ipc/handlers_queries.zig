//! IPC query helpers: night light, idle, capture, window rules and the scene tree walk.

const std = @import("std");
const sn = @import("../node.zig");
const Server = @import("../Server.zig");
const protocol = @import("protocol.zig");
const scene_data = @import("../scene_data.zig");
const ui = @import("ui");
const window_rules = @import("config").window_rules;
const findToplevelById = @import("handlers_data.zig").findToplevelById;

pub fn getNightLight(server: *Server, allocator: std.mem.Allocator) !protocol.Response {
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

pub fn getIdleState(server: *Server, allocator: std.mem.Allocator) !protocol.Response {
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
    for (im.bus_inhibitors.items) |inhibitor| {
        try list.append(allocator, .{
            .surface_ptr = 0,
            .app_id = try allocator.dupe(u8, inhibitor.app),
            .title = try allocator.dupe(u8, inhibitor.reason),
            .is_active = true,
            .reason = try std.fmt.allocPrint(allocator, "D-Bus ScreenSaver {s}", .{inhibitor.owner}),
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

pub fn getCaptureState(server: *Server, allocator: std.mem.Allocator) !protocol.Response {
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

pub fn getWindowRules(server: *Server, id: u64, allocator: std.mem.Allocator) !protocol.Response {
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
            .floating = toplevel.live_rules.floating,
        },
        .resolved_before_app_id = toplevel.resolved_before_app_id,
    } } };
}

pub fn matchWindowRules(server: *Server, params: protocol.MatchWindowRulesParams, allocator: std.mem.Allocator) !protocol.Response {
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
            .floating = live_r.floating,
        },
    } } };
}

pub fn walkSceneTree(
    node: *sn.Node,
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
        const tree = sn.Tree.fromNode(node);
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
        const r = sn.Rect.fromNode(node);
        box = .{ .x = node.x, .y = node.y, .width = r.width, .height = r.height };
    } else if (node.type == .buffer) {
        const b = sn.Buffer.fromNode(node);
        if (b.getBuffer()) |buf| {
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
        const tree = sn.Tree.fromNode(node);
        var it = tree.children.iterator(.forward);
        while (it.next()) |child| {
            try walkSceneTree(child, list, allocator, current_depth + 1, max_depth, total_nodes);
        }
    }
}
