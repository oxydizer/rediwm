const std = @import("std");
const wl = @import("wayland").server.wl;

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const handlers = @import("handlers.zig");
const ipc_server_mod = @import("server.zig");
const anim = @import("ui").anim;

fn eventMatchesFilter(filter: ?protocol.EventFilter, event: protocol.Event) bool {
    const f = filter orelse return true;
    if (event == .state_snapshot) return true;

    const event_name: []const u8 = switch (event) {
        .keyboard_layouts_changed => "keyboard_layouts_changed",
        .keyboard_layout_switched => "keyboard_layout_switched",
        .config_loaded => "config_loaded",
        .polkit_prompt_opened => "polkit_prompt_opened",
        .polkit_prompt_closed => "polkit_prompt_closed",
        .window_urgency_changed => "window_urgency_changed",
        .window_opened => "window_opened",
        .window_closed => "window_closed",
        .window_changed => "window_changed",
        .window_focused => "window_focused",
        .window_moved => "window_moved",
        .output_added => "output_added",
        .output_changed => "output_changed",
        .output_removed => "output_removed",
        .camera_changed => "camera_changed",
        .notification_shown => "notification_shown",
        .notification_closed => "notification_closed",
        .notification_action => "notification_action",
        .launch_started => "launch_started",
        .launch_matched => "launch_matched",
        .launch_timeout => "launch_timeout",
        .widget_changed => "widget_changed",
        .state_snapshot => "state_snapshot",
    };

    if (f.events) |evs| {
        var found = false;
        for (evs) |ev| {
            if (std.mem.eql(u8, ev, event_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (f.window_id) |wid| {
        switch (event) {
            .window_opened => |w| if (w.window.id != wid) return false,
            .window_urgency_changed => |w| if (w.id != wid) return false,
            .window_closed => |w| if (w.id != wid) return false,
            .window_changed => |w| if (w.window.id != wid) return false,
            .window_focused => |w| if (w.id != null and w.id.? != wid) return false,
            .window_moved => |w| if (w.id != wid) return false,
            else => {},
        }
    }

    if (f.output) |out_name| {
        switch (event) {
            .output_added => |o| if (!std.mem.eql(u8, o.output.name, out_name)) return false,
            .output_changed => |o| if (!std.mem.eql(u8, o.output.name, out_name)) return false,
            .output_removed => |o| if (!std.mem.eql(u8, o.name, out_name)) return false,
            else => {},
        }
    }

    return true;
}

fn hasEventSubscribers(ipc: *const ipc_server_mod.Server) bool {
    for (ipc.clients.items) |client| if (client.is_event_subscriber) return true;
    return false;
}

pub fn broadcastEvent(ipc: *ipc_server_mod.Server, event: protocol.Event) void {
    // A metadata-free close notification lets existing subscribers discard
    // the old prompt when locking; all other events stay suppressed.
    if (ipc.compositor.locker != null and event != .polkit_prompt_closed) return;
    var bw = protocol.BufferWriter{ .list = undefined, .allocator = ipc.allocator };
    var i: usize = 0;
    while (i < ipc.clients.items.len) {
        const client = ipc.clients.items[i];
        if (client.is_event_subscriber) {
            if (!eventMatchesFilter(client.event_filter, event)) {
                i += 1;
                continue;
            }
            bw.list = &client.write_buf;
            protocol.stringifyEvent(event, bw) catch {
                client.destroy();
                continue;
            };
            if (client.write_buf.items.len - client.write_offset > 256 * 1024) {
                client.destroy();
                continue;
            }
            client.updateFdInterest() catch {
                client.destroy();
                continue;
            };
        }
        i += 1;
    }
}

pub fn sendSnapshot(ipc: *ipc_server_mod.Server, client: *ipc_server_mod.Client) !void {
    const compositor = ipc.compositor;

    var wins = std.ArrayList(protocol.WindowData).empty;
    defer wins.deinit(ipc.allocator);
    var win_it = compositor.world.toplevels.iterator(.forward);
    while (win_it.next()) |toplevel| {
        try wins.append(ipc.allocator, handlers.makeWindowData(compositor, toplevel));
    }

    var outs = std.ArrayList(protocol.OutputData).empty;
    defer outs.deinit(ipc.allocator);
    var out_it = compositor.outputs.iterator(.forward);
    while (out_it.next()) |output| {
        try outs.append(ipc.allocator, handlers.makeOutputData(compositor, output));
    }

    const focused_id: ?u64 = if (handlers.findFocusedToplevel(compositor)) |t| t.id else null;

    const snap: protocol.StateSnapshot = .{
        .seq = ipc.seq,
        .windows = wins.items,
        .outputs = outs.items,
        .workspaces = &.{.{ .id = 1, .name = "Canvas", .is_focused = true }},
        .focused_window_id = focused_id,
        .session_id = ipc.session_id,
        .time_ms = anim.nowMs(),
        .camera = handlers.makeCameraData(compositor),
        .shell = handlers.makeShellStateData(compositor),
    };

    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = ipc.allocator };
    try protocol.stringifyEvent(.{ .state_snapshot = snap }, bw);
    var arena = std.heap.ArenaAllocator.init(ipc.allocator);
    defer arena.deinit();
    const initial = [_]protocol.Event{
        .{ .keyboard_layouts_changed = .{ .seq = ipc.seq, .keyboard_layouts = try @import("../input/layouts.zig").inspect(compositor, arena.allocator()) } },
        .{ .config_loaded = configLoaded(compositor, ipc.seq) },
    };
    for (initial) |event| if (eventMatchesFilter(client.event_filter, event)) {
        try protocol.stringifyEvent(event, bw);
    };
    try client.updateFdInterest();
}

/// Hashes a window record field by field. Optionals hash their presence, so a
/// value moving between adjacent optional strings changes the digest.
fn hashWindowValue(hasher: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| {
            hasher.update(&.{1});
            hashWindowValue(hasher, v);
        } else hasher.update(&.{0}),
        .@"struct" => |info| inline for (info.fields) |field| hashWindowValue(hasher, @field(value, field.name)),
        .pointer => {
            std.hash.autoHash(hasher, value.len);
            hasher.update(value);
        },
        else => std.hash.autoHash(hasher, value),
    }
}

fn windowDigest(win: protocol.WindowData) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashWindowValue(&hasher, win);
    return hasher.final();
}

pub fn onWindowOpened(ipc: *ipc_server_mod.Server, toplevel: *Toplevel) void {
    ipc.seq += 1;
    const win = handlers.makeWindowData(ipc.compositor, toplevel);
    if (ipc.compositor.locker == null and hasEventSubscribers(ipc)) toplevel.ipc_window_digest = windowDigest(win);
    broadcastEvent(ipc, .{ .window_opened = .{ .seq = ipc.seq, .window = win } });
}

pub fn onWindowClosed(ipc: *ipc_server_mod.Server, id: u64) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .window_closed = .{ .seq = ipc.seq, .id = id } });
}

pub fn onWindowChanged(ipc: *ipc_server_mod.Server, toplevel: *Toplevel) void {
    ipc.seq += 1;
    // Runs on every client commit; skip building the record nobody reads.
    // While locked `broadcastEvent` drops it; remembering it would hide the
    // change from subscribers after unlock.
    if (!hasEventSubscribers(ipc) or ipc.compositor.locker != null) return;
    const win = handlers.makeWindowData(ipc.compositor, toplevel);
    // Subscribers joining later get a snapshot, so the last record sent is
    // the only one a repeat needs to match.
    const digest = windowDigest(win);
    if (toplevel.ipc_window_digest == digest) return;
    toplevel.ipc_window_digest = digest;
    broadcastEvent(ipc, .{ .window_changed = .{ .seq = ipc.seq, .window = win } });
}

pub fn onWindowUrgencyChanged(ipc: *ipc_server_mod.Server, id: u64, urgent: bool) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .window_urgency_changed = .{ .seq = ipc.seq, .id = id, .urgent = urgent } });
}

pub fn onWindowFocused(ipc: *ipc_server_mod.Server, id: ?u64) void {
    if (ipc.focused_window_id == id) return;
    ipc.focused_window_id = id;
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .window_focused = .{ .seq = ipc.seq, .id = id } });
}

pub fn onWindowMoved(ipc: *ipc_server_mod.Server, id: u64, x: i32, y: i32) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .window_moved = .{ .seq = ipc.seq, .id = id, .x = x, .y = y } });
}

pub fn onOutputAdded(ipc: *ipc_server_mod.Server, output: *Output) void {
    ipc.seq += 1;
    const out = handlers.makeOutputData(ipc.compositor, output);
    broadcastEvent(ipc, .{ .output_added = .{ .seq = ipc.seq, .output = out } });
}

pub fn onOutputChanged(ipc: *ipc_server_mod.Server, output: *Output) void {
    ipc.seq += 1;
    const out = handlers.makeOutputData(ipc.compositor, output);
    broadcastEvent(ipc, .{ .output_changed = .{ .seq = ipc.seq, .output = out } });
}

pub fn onOutputRemoved(ipc: *ipc_server_mod.Server, name: []const u8) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .output_removed = .{ .seq = ipc.seq, .name = name } });
}

pub fn onCameraChanged(ipc: *ipc_server_mod.Server, x: i32, y: i32, max_x: i32, max_y: i32, zoom_percent: u16) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .camera_changed = .{ .seq = ipc.seq, .x = x, .y = y, .max_x = max_x, .max_y = max_y, .zoom_percent = zoom_percent } });
}

pub fn onNotificationShown(ipc: *ipc_server_mod.Server, id: u32, app_name: []const u8, summary: []const u8, urgency: u8) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .notification_shown = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .id = id,
        .app_name = app_name,
        .summary = summary,
        .urgency = urgency,
    } });
}

pub fn onNotificationClosed(ipc: *ipc_server_mod.Server, id: u32, reason: u32) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .notification_closed = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .id = id,
        .reason = reason,
    } });
}

pub fn onNotificationAction(ipc: *ipc_server_mod.Server, id: u32, action_key: []const u8) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .notification_action = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .id = id,
        .action_key = action_key,
    } });
}

pub fn onLaunchStarted(ipc: *ipc_server_mod.Server, desktop_id: []const u8, pid: ?i32, placeholder_id: ?u64) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .launch_started = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .desktop_id = desktop_id,
        .pid = pid,
        .placeholder_id = placeholder_id,
    } });
    ipc.wait_mgr.onLaunchStarted(desktop_id);
    ipc.wait_mgr.checkAll();
}

pub fn onLaunchMatched(ipc: *ipc_server_mod.Server, desktop_id: []const u8, window_id: u64, pid: ?i32) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .launch_matched = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .desktop_id = desktop_id,
        .window_id = window_id,
        .pid = pid,
    } });
    ipc.wait_mgr.onLaunchMatched(desktop_id, window_id);
    ipc.wait_mgr.checkAll();
}

pub fn onLaunchTimeout(ipc: *ipc_server_mod.Server, desktop_id: []const u8, pid: ?i32) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .launch_timeout = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .desktop_id = desktop_id,
        .pid = pid,
    } });
    ipc.wait_mgr.onLaunchTimeout(desktop_id);
    ipc.wait_mgr.checkAll();
}

pub fn onPolkitPrompt(ipc: *ipc_server_mod.Server, opened: bool) void {
    ipc.seq += 1;
    const data = protocol.PolkitPromptEvent{ .seq = ipc.seq, .time_ms = anim.nowMs() };
    broadcastEvent(ipc, if (opened) .{ .polkit_prompt_opened = data } else .{ .polkit_prompt_closed = data });
    ipc.wait_mgr.checkAll();
}

fn configLoaded(server: *Server, seq: u64) protocol.ConfigLoadedEvent {
    return .{ .seq = seq, .generation = server.config_generation, .failed = server.config_reload_error != null, .error_name = server.config_reload_error };
}

pub fn onConfigLoaded(server: *Server) void {
    const ipc = server.ipc orelse return;
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .config_loaded = configLoaded(server, ipc.seq) });
}

pub fn onKeyboardLayoutsChanged(server: *Server) void {
    const ipc = server.ipc orelse return;
    var arena = std.heap.ArenaAllocator.init(ipc.allocator);
    defer arena.deinit();
    const data = @import("../input/layouts.zig").inspect(server, arena.allocator()) catch return;
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .keyboard_layouts_changed = .{ .seq = ipc.seq, .keyboard_layouts = data } });
}

pub fn onKeyboardLayoutSwitched(server: *Server, idx: u32) void {
    const ipc = server.ipc orelse return;
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .keyboard_layout_switched = .{ .seq = ipc.seq, .idx = idx } });
}

pub fn onWidgetChanged(ipc: *ipc_server_mod.Server, panel: []const u8, node: protocol.WidgetNodeData) void {
    ipc.seq += 1;
    broadcastEvent(ipc, .{ .widget_changed = .{
        .seq = ipc.seq,
        .time_ms = anim.nowMs(),
        .session_id = ipc.session_id,
        .panel = panel,
        .path = node.path,
        .name = node.name,
        .widget = node,
    } });
    ipc.wait_mgr.checkAll();
}

test "window digest ignores storage and separates adjacent optional strings" {
    const base: protocol.WindowData = .{ .id = 1, .is_focused = false, .is_minimized = false, .is_maximized = false, .x = 0, .y = 0, .width = 10, .height = 10 };
    var title_only = base;
    title_only.title = "x";
    var app_id_only = base;
    app_id_only.app_id = "x";
    try std.testing.expect(windowDigest(title_only) != windowDigest(app_id_only));

    var copy = "x".*;
    var same = base;
    same.title = &copy;
    try std.testing.expectEqual(windowDigest(title_only), windowDigest(same));

    same.width = 11;
    try std.testing.expect(windowDigest(title_only) != windowDigest(same));
}
