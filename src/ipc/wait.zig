const std = @import("std");
const wl = @import("wayland").server.wl;

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const anim = @import("ui").anim;
const protocol = @import("protocol.zig");
const handlers = @import("handlers.zig");
const log = std.log.scoped(.ipc_wait);

pub const WaitKind = union(enum) {
    condition: protocol.WaitCondition,
    frame: ?[]const u8, // output name or null
};

pub const WaitEntry = struct {
    wait_id: u64,
    client_id: u64,
    request_id: ?protocol.RequestId,
    kind: WaitKind,
    start_time_ms: i64,
    timeout_ms: u64,
    deadline_ms: i64,
    timer_source: ?*wl.EventSource = null,
    manager: *WaitManager,
};

pub const WaitManager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*WaitEntry),
    next_wait_id: u64 = 1,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*WaitManager {
        const mgr = try allocator.create(WaitManager);
        mgr.* = .{
            .server = server,
            .allocator = allocator,
            .entries = std.ArrayList(*WaitEntry).empty,
        };
        return mgr;
    }

    pub fn deinit(mgr: *WaitManager) void {
        for (mgr.entries.items) |entry| {
            if (entry.timer_source) |ts| ts.remove();
            mgr.freeEntry(entry);
        }
        mgr.entries.deinit(mgr.allocator);
        mgr.allocator.destroy(mgr);
    }

    fn freeEntry(mgr: *WaitManager, entry: *WaitEntry) void {
        switch (entry.kind) {
            .condition => |cond| switch (cond) {
                .window_mapped => |p| {
                    if (p.app_id) |a| mgr.allocator.free(a);
                    if (p.title) |t| mgr.allocator.free(t);
                },
                .output_frame => |p| {
                    if (p.output) |o| mgr.allocator.free(o);
                },
                .notification_count => |p| {
                    if (p.app_name) |a| mgr.allocator.free(a);
                    if (p.summary) |s| mgr.allocator.free(s);
                },
                .notification_action => |p| {
                    if (p.action_key) |k| mgr.allocator.free(k);
                },
                .launch_started => |p| {
                    if (p.desktop_id) |d| mgr.allocator.free(d);
                },
                .launch_matched => |p| {
                    if (p.desktop_id) |d| mgr.allocator.free(d);
                },
                .launch_timeout => |p| {
                    if (p.desktop_id) |d| mgr.allocator.free(d);
                },
                .widget_present => |p| {
                    mgr.allocator.free(p.path);
                },
                .widget_absent => |p| {
                    mgr.allocator.free(p.path);
                },
                .widget_state => |p| {
                    mgr.allocator.free(p.path);
                    mgr.allocator.free(p.field);
                    protocol.freeWidgetStateValue(mgr.allocator, p.equals);
                },
                .panel_settled => |p| {
                    mgr.allocator.free(p.panel);
                },
                else => {},
            },
            .frame => |opt_out| {
                if (opt_out) |o| mgr.allocator.free(o);
            },
        }
        if (entry.request_id) |rid| {
            switch (rid) {
                .string => |s| mgr.allocator.free(s),
                .integer => {},
            }
        }
        mgr.allocator.destroy(entry);
    }

    pub fn clientCount(mgr: *WaitManager, client_id: u64) usize {
        var count: usize = 0;
        for (mgr.entries.items) |e| {
            if (e.client_id == client_id) count += 1;
        }
        return count;
    }

    pub fn cancelForClient(mgr: *WaitManager, client_id: u64) void {
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            if (entry.client_id == client_id) {
                if (entry.timer_source) |ts| ts.remove();
                _ = mgr.entries.orderedRemove(i);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    /// Ends every pending wait with `reason`. Locking uses this so a wait
    /// registered beforehand cannot report state changes behind the lock.
    pub fn failAll(mgr: *WaitManager, reason: []const u8) void {
        while (mgr.entries.pop()) |entry| {
            if (entry.timer_source) |ts| ts.remove();
            if (mgr.server.ipc) |ipc| if (ipc.findClientById(entry.client_id)) |client| {
                const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                protocol.stringifyResponseWithId(entry.request_id, .{ .err = reason }, bw) catch {};
                client.updateFdInterest() catch {};
            };
            mgr.freeEntry(entry);
        }
    }

    pub fn registerCondition(
        mgr: *WaitManager,
        client_id: u64,
        request_id: ?protocol.RequestId,
        condition: protocol.WaitCondition,
        timeout_ms: u64,
    ) !protocol.Response {
        const now = anim.nowMs();

        // 1. Evaluate condition immediately
        if (mgr.isConditionMet(condition, now)) {
            const cond_str = conditionName(condition);
            return .{ .ok = .{ .wait_for = .{
                .condition = cond_str,
                .elapsed_ms = 0,
                .state = null,
            } } };
        }

        mgr.server.scheduleFrames();

        if (mgr.clientCount(client_id) >= 16) {
            return .{ .err = "Busy: wait limit per client reached" };
        }

        const entry = try mgr.allocator.create(WaitEntry);
        entry.* = .{
            .wait_id = mgr.next_wait_id,
            .client_id = client_id,
            .request_id = null,
            .kind = .{ .frame = null },
            .start_time_ms = now,
            .timeout_ms = timeout_ms,
            .deadline_ms = now + @as(i64, @intCast(timeout_ms)),
            .timer_source = null,
            .manager = mgr,
        };
        errdefer mgr.freeEntry(entry);
        const owned_condition = try mgr.cloneCondition(condition);
        entry.kind = .{ .condition = owned_condition };
        const owned_request_id = if (request_id) |rid| try mgr.cloneRequestId(rid) else null;
        entry.request_id = owned_request_id;
        mgr.next_wait_id += 1;

        const loop = mgr.server.wl_server.getEventLoop();
        const timer = loop.addTimer(*WaitEntry, handleWaitTimer, entry) catch return error.EventLoopFailed;
        // A later allocation failure must not leave a timer pointing at entry.
        errdefer timer.remove();
        entry.timer_source = timer;
        timer.timerUpdate(@intCast(timeout_ms)) catch return error.EventLoopFailed;

        try mgr.entries.append(mgr.allocator, entry);
        return .{ .ok = .async_pending };
    }

    pub fn registerFrame(
        mgr: *WaitManager,
        client_id: u64,
        request_id: ?protocol.RequestId,
        output_name: ?[]const u8,
        timeout_ms: u64,
    ) !protocol.Response {
        const now = anim.nowMs();

        // Ensure frame is scheduled
        if (output_name) |name| {
            if (mgr.server.findOutputByName(name)) |out| {
                out.wlr_output.scheduleFrame();
            } else {
                return .{ .err = "UnknownOutput" };
            }
        } else {
            mgr.server.scheduleFrames();
        }

        if (mgr.clientCount(client_id) >= 16) {
            return .{ .err = "Busy: wait limit per client reached" };
        }

        const entry = try mgr.allocator.create(WaitEntry);
        entry.* = .{
            .wait_id = mgr.next_wait_id,
            .client_id = client_id,
            .request_id = null,
            .kind = .{ .frame = null },
            .start_time_ms = now,
            .timeout_ms = timeout_ms,
            .deadline_ms = now + @as(i64, @intCast(timeout_ms)),
            .timer_source = null,
            .manager = mgr,
        };
        errdefer mgr.freeEntry(entry);
        const owned_output = if (output_name) |o| try mgr.allocator.dupe(u8, o) else null;
        entry.kind = .{ .frame = owned_output };
        const owned_request_id = if (request_id) |rid| try mgr.cloneRequestId(rid) else null;
        entry.request_id = owned_request_id;
        mgr.next_wait_id += 1;

        const loop = mgr.server.wl_server.getEventLoop();
        const timer = loop.addTimer(*WaitEntry, handleWaitTimer, entry) catch return error.EventLoopFailed;
        // A later allocation failure must not leave a timer pointing at entry.
        errdefer timer.remove();
        entry.timer_source = timer;
        timer.timerUpdate(@intCast(timeout_ms)) catch return error.EventLoopFailed;

        try mgr.entries.append(mgr.allocator, entry);
        return .{ .ok = .async_pending };
    }

    pub fn onOutputFrame(mgr: *WaitManager, output: *Output) void {
        const out_name = std.mem.span(output.wlr_output.name);
        const now = anim.nowMs();

        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;

            switch (entry.kind) {
                .frame => |opt_out| {
                    if (opt_out) |req_name| {
                        if (std.mem.eql(u8, req_name, out_name)) satisfied = true;
                    } else {
                        satisfied = true;
                    }
                },
                .condition => |cond| {
                    if (cond == .output_frame) {
                        if (cond.output_frame.output) |req_name| {
                            if (std.mem.eql(u8, req_name, out_name)) satisfied = true;
                        } else {
                            satisfied = true;
                        }
                    }
                },
            }

            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();

                mgr.notifySuccess(entry, now, out_name);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn onLaunchStarted(mgr: *WaitManager, desktop_id: []const u8) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            if (entry.kind == .condition and entry.kind.condition == .launch_started) {
                if (entry.kind.condition.launch_started.desktop_id) |target| {
                    if (std.mem.eql(u8, target, desktop_id)) satisfied = true;
                } else {
                    satisfied = true;
                }
            }
            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();
                mgr.notifySuccess(entry, now, desktop_id);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn onLaunchMatched(mgr: *WaitManager, desktop_id: []const u8, window_id: u64) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            if (entry.kind == .condition and entry.kind.condition == .launch_matched) {
                const p = entry.kind.condition.launch_matched;
                var match = true;
                if (p.desktop_id) |target| {
                    if (!std.mem.eql(u8, target, desktop_id)) match = false;
                }
                if (p.window_id) |wid| {
                    if (wid != window_id) match = false;
                }
                if (match) satisfied = true;
            }
            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();
                mgr.notifySuccess(entry, now, desktop_id);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn onLaunchTimeout(mgr: *WaitManager, desktop_id: []const u8) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            if (entry.kind == .condition and entry.kind.condition == .launch_timeout) {
                if (entry.kind.condition.launch_timeout.desktop_id) |target| {
                    if (std.mem.eql(u8, target, desktop_id)) satisfied = true;
                } else {
                    satisfied = true;
                }
            }
            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();
                mgr.notifySuccess(entry, now, desktop_id);
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    pub fn checkAll(mgr: *WaitManager) void {
        const now = anim.nowMs();
        var i: usize = 0;
        while (i < mgr.entries.items.len) {
            const entry = mgr.entries.items[i];
            var satisfied = false;
            switch (entry.kind) {
                .condition => |cond| {
                    if (cond != .output_frame and mgr.isConditionMet(cond, now)) {
                        satisfied = true;
                    }
                },
                .frame => {},
            }

            if (satisfied) {
                _ = mgr.entries.orderedRemove(i);
                if (entry.timer_source) |ts| ts.remove();

                mgr.notifySuccess(entry, now, "");
                mgr.freeEntry(entry);
            } else {
                i += 1;
            }
        }
    }

    fn notifySuccess(mgr: *WaitManager, entry: *WaitEntry, now: i64, extra_name: []const u8) void {
        const ipc = mgr.server.ipc orelse return;
        const client = ipc.findClientById(entry.client_id) orelse return;

        const elapsed: u64 = if (now >= entry.start_time_ms)
            @intCast(now - entry.start_time_ms)
        else
            0;

        const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };

        switch (entry.kind) {
            .condition => |cond| {
                const res = protocol.WaitForResult{
                    .condition = conditionName(cond),
                    .elapsed_ms = elapsed,
                    .state = null,
                };
                protocol.stringifyResponseWithId(entry.request_id, .{ .ok = .{ .wait_for = res } }, bw) catch {};
            },
            .frame => {
                const out_res = protocol.WaitForFrameResult{
                    .output = extra_name,
                    .frame_seq = ipc.seq,
                    .elapsed_ms = elapsed,
                };
                protocol.stringifyResponseWithId(entry.request_id, .{ .ok = .{ .wait_for_frame = out_res } }, bw) catch {};
            },
        }
        client.updateFdInterest() catch {};
    }

    fn notifyTimeout(mgr: *WaitManager, entry: *WaitEntry) void {
        const ipc = mgr.server.ipc orelse return;
        const client = ipc.findClientById(entry.client_id) orelse return;

        var buf: [256]u8 = undefined;
        const diag = mgr.buildTimeoutDiagnostic(entry, &buf);

        const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
        protocol.stringifyResponseWithId(entry.request_id, .{ .err = diag }, bw) catch {};
        client.updateFdInterest() catch {};
    }

    fn buildTimeoutDiagnostic(mgr: *WaitManager, entry: *WaitEntry, buf: []u8) []const u8 {
        const now = anim.nowMs();
        switch (entry.kind) {
            .condition => |cond| switch (cond) {
                .menu_opened => {
                    const out = mgr.server.getDefaultOutput();
                    if (out != null and out.?.start_menu != null) {
                        const sm = out.?.start_menu.?;
                        return std.fmt.bufPrint(buf, "Timeout: start menu in state '{s}' (settled={}) after {d}ms", .{
                            @tagName(sm.state), sm.slide.settled(now), entry.timeout_ms,
                        }) catch "Timeout: menu_opened";
                    }
                    return std.fmt.bufPrint(buf, "Timeout: start menu is not open after {d}ms", .{entry.timeout_ms}) catch "Timeout";
                },
                .menu_closed => {
                    const out = mgr.server.getDefaultOutput();
                    if (out != null and out.?.start_menu != null) {
                        const sm = out.?.start_menu.?;
                        return std.fmt.bufPrint(buf, "Timeout: start menu still open with state '{s}' after {d}ms", .{
                            @tagName(sm.state), entry.timeout_ms,
                        }) catch "Timeout: menu_closed";
                    }
                    return std.fmt.bufPrint(buf, "Timeout: start menu not closed after {d}ms", .{entry.timeout_ms}) catch "Timeout";
                },
                .control_center_opened => return "Timeout: control center not open",
                .control_center_closed => return "Timeout: control center not closed",
                .power_menu_opened => return "Timeout: power menu not open",
                .power_menu_closed => return "Timeout: power menu not closed",
                .window_mapped => |p| {
                    if (p.id) |id| {
                        return std.fmt.bufPrint(buf, "Timeout: window {d} not mapped after {d}ms", .{ id, entry.timeout_ms }) catch "Timeout";
                    }
                    return "Timeout: window not mapped";
                },
                .window_closed => |p| {
                    return std.fmt.bufPrint(buf, "Timeout: window {d} still open after {d}ms", .{ p.id, entry.timeout_ms }) catch "Timeout";
                },
                .window_focused => |p| {
                    if (p.id) |id| {
                        return std.fmt.bufPrint(buf, "Timeout: window {d} not focused after {d}ms", .{ id, entry.timeout_ms }) catch "Timeout";
                    }
                    return "Timeout: focus not cleared";
                },
                .window_geometry_settled => |p| {
                    return std.fmt.bufPrint(buf, "Timeout: window {d} geometry not settled after {d}ms", .{ p.id, entry.timeout_ms }) catch "Timeout";
                },
                .output_frame => return "Timeout: output frame not received",
                .catalog_published => return "Timeout: catalogue not published",
                .wallpaper_presented => return "Timeout: wallpaper not presented",
                .notification_count => return "Timeout: notification count condition not met",
                .notification_closed => return "Timeout: notification not closed",
                .notification_action => return "Timeout: notification action not received",
                .launch_started => return "Timeout: launch not started",
                .launch_matched => return "Timeout: launch not matched",
                .launch_timeout => return "Timeout: launch did not timeout",
                .widget_present => |p| {
                    return std.fmt.bufPrint(buf, "Timeout: widget '{s}' not present after {d}ms", .{ p.path, entry.timeout_ms }) catch "Timeout: widget not present";
                },
                .widget_absent => |p| {
                    return std.fmt.bufPrint(buf, "Timeout: widget '{s}' still present after {d}ms", .{ p.path, entry.timeout_ms }) catch "Timeout: widget not absent";
                },
                .widget_state => |p| {
                    return std.fmt.bufPrint(buf, "Timeout: widget '{s}' field '{s}' condition not met after {d}ms", .{ p.path, p.field, entry.timeout_ms }) catch "Timeout: widget state";
                },
                .panel_settled => |p| {
                    return std.fmt.bufPrint(buf, "Timeout: panel '{s}' not settled after {d}ms", .{ p.panel, entry.timeout_ms }) catch "Timeout: panel not settled";
                },
            },
            .frame => return "Timeout: frame presentation not received",
        }
    }

    fn checkWidgetState(node: protocol.WidgetNodeData, field: []const u8, equals: protocol.WidgetStateValue) bool {
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

    fn isConditionMet(mgr: *WaitManager, cond: protocol.WaitCondition, now: i64) bool {
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
                const now_ms = @import("ui").anim.nowMs();
                return top.isGeometrySettled(now_ms);
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

    fn cloneCondition(mgr: *WaitManager, cond: protocol.WaitCondition) !protocol.WaitCondition {
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

    fn cloneRequestId(mgr: *WaitManager, rid: protocol.RequestId) !protocol.RequestId {
        return switch (rid) {
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = try mgr.allocator.dupe(u8, s) },
        };
    }
};

fn handleWaitTimer(entry: *WaitEntry) c_int {
    const mgr = entry.manager;
    var found_idx: ?usize = null;
    for (mgr.entries.items, 0..) |item, idx| {
        if (item == entry) {
            found_idx = idx;
            break;
        }
    }

    if (found_idx) |idx| {
        _ = mgr.entries.orderedRemove(idx);
        if (entry.timer_source) |ts| ts.remove();
        entry.timer_source = null;

        const now = anim.nowMs();
        var satisfied = false;
        switch (entry.kind) {
            .condition => |cond| {
                if (cond != .output_frame and mgr.isConditionMet(cond, now)) {
                    satisfied = true;
                }
            },
            .frame => {},
        }

        if (satisfied) {
            mgr.notifySuccess(entry, now, "");
        } else {
            mgr.notifyTimeout(entry);
        }
        mgr.freeEntry(entry);
    }
    return 0;
}

fn conditionName(cond: protocol.WaitCondition) []const u8 {
    return switch (cond) {
        .menu_opened => "menu_opened",
        .menu_closed => "menu_closed",
        .control_center_opened => "control_center_opened",
        .control_center_closed => "control_center_closed",
        .power_menu_opened => "power_menu_opened",
        .power_menu_closed => "power_menu_closed",
        .window_mapped => "window_mapped",
        .window_closed => "window_closed",
        .window_focused => "window_focused",
        .window_geometry_settled => "window_geometry_settled",
        .output_frame => "output_frame",
        .catalog_published => "catalog_published",
        .wallpaper_presented => "wallpaper_presented",
        .notification_count => "notification_count",
        .notification_closed => "notification_closed",
        .notification_action => "notification_action",
        .launch_started => "launch_started",
        .launch_matched => "launch_matched",
        .launch_timeout => "launch_timeout",
        .widget_present => "widget_present",
        .widget_absent => "widget_absent",
        .widget_state => "widget_state",
        .panel_settled => "panel_settled",
    };
}
