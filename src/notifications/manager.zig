//! Notification daemon managing active toasts, history, D-Bus service, and IPC.
const std = @import("std");
const wl = @import("wayland").server.wl;

const anim = @import("ui").anim;
const dbus = @import("dbus");
const wire = @import("dbus").wire;
const activation = @import("../session/activation.zig");
const settings_portal = @import("../session/settings_portal.zig");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const toast_mod = @import("toast.zig");
const image_mod = @import("image.zig");
const window_rules = @import("config").window_rules;
const protocol = @import("../ipc/protocol.zig");
const ipc_events = @import("../ipc/events.zig");

const Toast = toast_mod.Toast;
const ActionPair = toast_mod.ActionPair;
const log = std.log.scoped(.notifications);

pub const bus_name = "org.freedesktop.Notifications";
pub const bus_path = "/org/freedesktop/Notifications";
pub const bus_interface = "org.freedesktop.Notifications";

pub const NotificationRecord = struct {
    id: u32,
    app_name: []const u8,
    summary: []const u8,
    body: []const u8,
    app_icon: []const u8,
    urgency: u8,
    time_ms: i64,
    closed: bool = false,
    close_reason: ?u32 = null,
};

pub const Rule = struct {
    app_name: ?[]const []const u8 = null,
    desktop_entry: ?[]const []const u8 = null,
    mute: ?bool = null,
    urgency: ?u8 = null,
    dnd_bypass: ?bool = null,
};

pub const Manager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    conn: ?*dbus.Connection = null,
    file_chooser: ?*@import("../session/file_chooser.zig").Manager = null,
    toasts: std.ArrayList(*Toast) = .empty,
    history: std.ArrayList(NotificationRecord) = .empty,
    next_id: u32 = 1,
    dnd: bool = false,
    default_timeout_ms: u32 = 5000,
    max_visible: usize = 5,
    was_locked: bool = false,
    timer: ?*wl.EventSource = null,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*Manager {
        const mgr = try allocator.create(Manager);
        errdefer allocator.destroy(mgr);

        mgr.* = .{
            .server = server,
            .allocator = allocator,
            .dnd = server.config.notifications.dnd,
            .default_timeout_ms = server.config.notifications.default_timeout_ms,
        };

        mgr.timer = try server.wl_server.getEventLoop().addTimer(*Manager, onTimer, mgr);

        const env_view = activation.viewFromEnviron(server.environ);
        const force_dbus = if (server.environ.getPosix("REDIWM_FORCE_DBUS")) |v| !std.mem.eql(u8, v, "0") else false;
        const should_connect = force_dbus or activation.shouldPublish(env_view);

        if (should_connect) {
            mgr.tryConnectDbus() catch |err| {
                log.info("notifications: D-Bus session bus not connected ({s}), running in IPC-only mode", .{@errorName(err)});
            };
        } else {
            log.info("notifications: nested/headless without REDIWM_FORCE_DBUS; running in IPC-only mode", .{});
        }

        return mgr;
    }

    fn tryConnectDbus(self: *Manager) !void {
        const loop = self.server.wl_server.getEventLoop();
        const conn = try dbus.Connection.openSession(self.allocator, loop, self.server.environ);
        self.conn = conn;

        try conn.register(.{ .path = bus_path, .interface = bus_interface, .member = "GetCapabilities", .owner = self, .callback = handleGetCapabilities });
        try conn.register(.{ .path = bus_path, .interface = bus_interface, .member = "GetServerInformation", .owner = self, .callback = handleGetServerInformation });
        try conn.register(.{ .path = bus_path, .interface = bus_interface, .member = "Notify", .owner = self, .callback = handleNotify });
        try conn.register(.{ .path = bus_path, .interface = bus_interface, .member = "CloseNotification", .owner = self, .callback = handleCloseNotification });
        try settings_portal.register(conn, self.server);
        try @import("../session/file_manager_service.zig").register(conn, self.server);
        self.file_chooser = try @import("../session/file_chooser.zig").Manager.create(self.server, conn);

        _ = try conn.hello(self, onHello);
    }

    pub fn deinit(self: *Manager) void {
        if (self.file_chooser) |chooser| chooser.destroy();
        if (self.timer) |timer| timer.remove();
        self.server.input.clearToastHover();
        for (self.toasts.items) |t| {
            if (t.icon_id) |id| self.server.iconRelease(id);
            t.deinit(self.allocator);
        }
        self.toasts.deinit(self.allocator);

        for (self.history.items) |rec| {
            self.allocator.free(rec.app_name);
            self.allocator.free(rec.summary);
            self.allocator.free(rec.body);
            self.allocator.free(rec.app_icon);
        }
        self.history.deinit(self.allocator);

        if (self.conn) |c| {
            c.destroy();
            self.conn = null;
        }
        self.allocator.destroy(self);
    }

    pub fn postNotification(
        self: *Manager,
        app_name: []const u8,
        replaces_id: u32,
        app_icon: []const u8,
        summary: []const u8,
        body: []const u8,
        actions: []const ActionPair,
        urgency_arg: u8,
        resident: bool,
        transient: bool,
        expire_timeout: i32,
        desktop_entry: []const u8,
        image: ?image_mod.DecodedImage,
    ) !u32 {
        const now_ms = anim.nowMs();
        var urgency = urgency_arg;
        var muted = false;
        var dnd_bypass = false;

        // Apply notification rules from config
        for (self.server.config.notification_rules) |rule| {
            var matched = false;
            if (rule.app_name) |pats| {
                for (pats) |pat| {
                    if (window_rules.matchGlob(pat, app_name)) {
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched and rule.desktop_entry != null and desktop_entry.len > 0) {
                for (rule.desktop_entry.?) |pat| {
                    if (window_rules.matchGlob(pat, desktop_entry)) {
                        matched = true;
                        break;
                    }
                }
            }
            if (matched) {
                if (rule.mute) |m| muted = m;
                if (rule.urgency) |u| urgency = u;
                if (rule.dnd_bypass) |b| dnd_bypass = b;
            }
        }

        // DND policy: if DND is enabled, suppress toast unless critical (urgency=2) or bypassed
        const suppressed_by_dnd = self.dnd and !dnd_bypass and urgency != 2;
        const should_show_toast = !muted and !suppressed_by_dnd;

        // In-place update for replaces_id
        if (replaces_id != 0) {
            if (self.findToast(replaces_id)) |existing| {
                try existing.updateContent(
                    app_name,
                    app_icon,
                    summary,
                    body,
                    actions,
                    urgency,
                    resident,
                    transient,
                    expire_timeout,
                    now_ms,
                    image,
                );
                if (existing.icon_id) |icon_id| self.server.iconRelease(icon_id);
                existing.icon_id = null;
                existing.icon_entry = null;
                self.resolveIcon(existing);
                try existing.buildTree();
                self.relayoutStack(now_ms);
                self.broadcastShown(existing.id, app_name, summary, urgency);
                self.server.scheduleFrames();
                return replaces_id;
            }
        }

        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        // Add to history
        try self.addHistory(id, app_name, summary, body, app_icon, urgency, now_ms);

        if (should_show_toast) {
            // If at max visible, begin closing oldest non-critical toast
            if (self.toasts.items.len >= self.max_visible) {
                for (self.toasts.items) |t| {
                    if (t.urgency != 2 and !t.closing) {
                        t.beginClose(now_ms, 1);
                        break;
                    }
                }
            }

            const toast = try Toast.create(
                self.allocator,
                self.server.overlay_tree,
                self,
                id,
                app_name,
                app_icon,
                summary,
                body,
                actions,
                urgency,
                resident,
                transient,
                expire_timeout,
                now_ms,
                image,
            );

            self.resolveIcon(toast);

            try self.toasts.append(self.allocator, toast);

            // Lock screen policy: suppress while locked
            if (self.server.locker != null) {
                toast.buffer_node.node.setEnabled(false);
            }

            self.relayoutStack(now_ms);
            self.broadcastShown(id, app_name, summary, urgency);
            self.server.scheduleFrames();
        }

        return id;
    }

    fn resolveIcon(self: *Manager, toast: *Toast) void {
        if (toast.image != null or toast.icon_entry != null or toast.app_icon.len == 0) return;
        const output = self.server.getDefaultOutput();
        const scale = if (output) |out| out.wlr_output.scale else 1;
        switch (self.server.iconLookup(toast.app_icon, @intFromFloat(@ceil(40 * scale)))) {
            .ready => |entry| {
                toast.icon_entry = entry;
                toast.icon_id = entry.id;
                self.server.iconAcquire(entry.id);
                toast.buildTree() catch {};
                toast.relayout(toast.width);
                toast.dirty = true;
            },
            .pending, .missing => {},
        }
    }

    pub fn iconsReady(self: *Manager) void {
        for (self.toasts.items) |toast| self.resolveIcon(toast);
    }

    pub fn closeNotification(self: *Manager, id: u32, reason: u32) void {
        const now_ms = anim.nowMs();
        if (self.findToast(id)) |toast| {
            toast.beginClose(now_ms, reason);
            self.updateHistoryClosed(id, reason);
            self.server.scheduleFrames();
        }
    }

    pub fn invokeAction(self: *Manager, id: u32, action_key: []const u8) void {
        // Emit D-Bus signal ActionInvoked(id, action_key)
        self.emitActionInvoked(id, action_key);

        // Broadcast IPC event
        self.broadcastAction(id, action_key);

        if (self.findToast(id)) |toast| {
            if (!toast.resident) {
                self.closeNotification(id, 2); // 2 = dismissed by user
            }
        }
    }

    pub fn findToast(self: *Manager, id: u32) ?*Toast {
        for (self.toasts.items) |t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn relayoutStack(self: *Manager, now_ms: i64) void {
        const output = self.server.getDefaultOutput() orelse return;
        const box = output.usableBox();
        const toast_width: f32 = @min(480, @max(120, @as(f32, @floatFromInt(box.width)) - 40));
        const margin: f32 = 20;
        const gap: f32 = 10;

        const target_x = @as(f32, @floatFromInt(box.x + box.width)) - toast_width - margin;
        var cur_y = @as(f32, @floatFromInt(box.y)) + margin;

        for (self.toasts.items) |toast| {
            toast.target_x = target_x;
            if (toast.width != toast_width) {
                toast.width = toast_width;
                toast.buildTree() catch {};
            }
            toast.relayout(toast_width);

            const old_render_y = toast.renderY(now_ms);
            toast.target_y = cur_y;
            const delta = old_render_y - toast.target_y;
            if (@abs(delta) >= 0.5) {
                toast.flip = .initCurve(delta, 0, now_ms, anim.curveFor(.toast_flip));
            }

            cur_y += toast.height + gap;
            toast.dirty = true;
        }
    }

    pub fn tick(self: *Manager, output: *Output, now_ms: i64) bool {
        _ = output;
        var animating = false;

        // Lock screen suppression
        const is_locked = self.server.locker != null;
        if (is_locked) {
            self.was_locked = true;
            for (self.toasts.items) |toast| {
                toast.buffer_node.node.setEnabled(false);
            }
            return false;
        }

        if (self.was_locked and !is_locked) {
            self.was_locked = false;
            // Unlock: restore visibility and reset timeouts
            for (self.toasts.items) |toast| {
                toast.buffer_node.node.setEnabled(true);
                if (toast.expire_timeout_ms > 0 and toast.urgency != 2) {
                    toast.expire_at_ms = now_ms + toast.expire_timeout_ms;
                }
            }
            self.relayoutStack(now_ms);
        }

        // Check auto-expiry
        for (self.toasts.items) |toast| {
            if (!toast.paused and !toast.closing and toast.expire_at_ms != null and now_ms >= toast.expire_at_ms.?) {
                toast.beginClose(now_ms, 1); // 1 = expired
            }
        }

        // Clean up finished toasts
        var i: usize = 0;
        var removed_any = false;
        while (i < self.toasts.items.len) {
            const toast = self.toasts.items[i];
            if (toast.finishedClosing(now_ms)) {
                _ = self.toasts.orderedRemove(i);
                removed_any = true;

                self.emitNotificationClosed(toast.id, toast.close_reason);
                self.broadcastClosed(toast.id, toast.close_reason);

                if (self.server.input.hovered_toast == toast) self.server.input.clearToastHover();
                if (toast.icon_id) |icon_id| self.server.iconRelease(icon_id);
                toast.deinit(self.allocator);
            } else {
                i += 1;
            }
        }

        if (removed_any) {
            self.relayoutStack(now_ms);
            if (self.server.ipc) |ipc| ipc.wait_mgr.checkAll();
        }

        // Render and position visible toasts
        const def_out = self.server.getDefaultOutput();
        const scale = if (def_out) |out| out.wlr_output.scale else 1.0;

        for (self.toasts.items) |toast| {
            toast.updateAge(now_ms);
            if (toast.dirty) {
                toast.paintContent(scale, self.allocator);
            }

            const rx = toast.renderX(now_ms);
            const ry = toast.renderY(now_ms);
            const op = toast.opacity(now_ms);

            toast.buffer_node.node.setPosition(@intFromFloat(@round(rx)), @intFromFloat(@round(ry)));
            toast.buffer_node.setOpacity(op);
            toast.buffer_node.node.setEnabled(op > 0 and !is_locked);

            _ = toast.slide.sampleChanged(now_ms, anim.quantum_alpha);
            _ = toast.flip.sampleChanged(now_ms, anim.quantum_px);
            if (!toast.slide.settled(now_ms) or !toast.flip.settled(now_ms)) {
                animating = true;
            }
        }

        // Wake idle outputs for expiration and relative timestamps without continuous frames.
        var next_wake: i64 = 60000;
        for (self.toasts.items) |toast| {
            if (!toast.closing) {
                next_wake = @min(next_wake, 60000 - @mod(@max(0, now_ms - toast.created_at_ms), 60000));
                if (!toast.paused) {
                    if (toast.expire_at_ms) |deadline| next_wake = @min(next_wake, @max(1, deadline - now_ms));
                }
            }
        }
        if (self.timer) |timer| timer.timerUpdate(if (self.toasts.items.len == 0) 0 else @intCast(next_wake)) catch {};
        return animating;
    }

    fn onTimer(self: *Manager) c_int {
        self.server.scheduleFrames();
        return 0;
    }

    pub fn setDnd(self: *Manager, enabled: bool) void {
        self.dnd = enabled;
        if (enabled) {
            // Dismiss all non-critical visible toasts
            const now_ms = anim.nowMs();
            for (self.toasts.items) |t| {
                if (t.urgency != 2) {
                    t.beginClose(now_ms, 2);
                }
            }
            self.server.scheduleFrames();
        }
    }

    pub fn clearNotifications(self: *Manager, which: []const u8) void {
        const now_ms = anim.nowMs();
        if (std.mem.eql(u8, which, "active") or std.mem.eql(u8, which, "all")) {
            for (self.toasts.items) |t| {
                t.beginClose(now_ms, 2);
            }
            self.server.scheduleFrames();
        }
        if (std.mem.eql(u8, which, "history") or std.mem.eql(u8, which, "all")) {
            for (self.history.items) |rec| {
                self.allocator.free(rec.app_name);
                self.allocator.free(rec.summary);
                self.allocator.free(rec.body);
                self.allocator.free(rec.app_icon);
            }
            self.history.clearRetainingCapacity();
        }
    }

    fn addHistory(self: *Manager, id: u32, app_name: []const u8, summary: []const u8, body: []const u8, app_icon: []const u8, urgency: u8, time_ms: i64) !void {
        if (self.history.items.len >= 50) {
            const old = self.history.orderedRemove(0);
            self.allocator.free(old.app_name);
            self.allocator.free(old.summary);
            self.allocator.free(old.body);
            self.allocator.free(old.app_icon);
        }
        try self.history.append(self.allocator, .{
            .id = id,
            .app_name = try self.allocator.dupe(u8, app_name),
            .summary = try self.allocator.dupe(u8, summary),
            .body = try self.allocator.dupe(u8, body),
            .app_icon = try self.allocator.dupe(u8, app_icon),
            .urgency = urgency,
            .time_ms = time_ms,
        });
    }

    fn updateHistoryClosed(self: *Manager, id: u32, reason: u32) void {
        for (self.history.items) |*rec| {
            if (rec.id == id) {
                rec.closed = true;
                rec.close_reason = reason;
                break;
            }
        }
    }

    fn emitNotificationClosed(self: *Manager, id: u32, reason: u32) void {
        const conn = self.conn orelse return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.uint32(id) catch return;
        body.uint32(reason) catch return;
        conn.signal(bus_path, bus_interface, "NotificationClosed", "uu", &body) catch {};
    }

    fn emitActionInvoked(self: *Manager, id: u32, action_key: []const u8) void {
        const conn = self.conn orelse return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.uint32(id) catch return;
        body.string(action_key) catch return;
        conn.signal(bus_path, bus_interface, "ActionInvoked", "us", &body) catch {};
    }

    fn broadcastShown(self: *Manager, id: u32, app_name: []const u8, summary: []const u8, urgency: u8) void {
        const ipc = self.server.ipc orelse return;
        ipc_events.onNotificationShown(ipc, id, app_name, summary, urgency);
    }

    fn broadcastClosed(self: *Manager, id: u32, reason: u32) void {
        const ipc = self.server.ipc orelse return;
        ipc_events.onNotificationClosed(ipc, id, reason);
    }

    fn broadcastAction(self: *Manager, id: u32, action: []const u8) void {
        const ipc = self.server.ipc orelse return;
        ipc_events.onNotificationAction(ipc, id, action);
    }

    pub fn getNotificationsResult(self: *Manager, allocator: std.mem.Allocator) !protocol.GetNotificationsResult {
        const toasts_list = try allocator.alloc(protocol.ToastData, self.toasts.items.len);
        for (self.toasts.items, 0..) |t, i| {
            toasts_list[i] = .{
                .id = t.id,
                .app_name = t.app_name,
                .summary = t.summary,
                .body = t.body,
                .app_icon = t.app_icon,
                .urgency = t.urgency,
                .resident = t.resident,
                .transient = t.transient,
                .expire_at_ms = t.expire_at_ms,
                .paused = t.paused,
                .closing = t.closing,
            };
        }

        const history_list = try allocator.alloc(protocol.NotificationRecordData, self.history.items.len);
        for (self.history.items, 0..) |rec, i| {
            history_list[i] = .{
                .id = rec.id,
                .app_name = rec.app_name,
                .summary = rec.summary,
                .body = rec.body,
                .app_icon = rec.app_icon,
                .urgency = rec.urgency,
                .time_ms = rec.time_ms,
                .closed = rec.closed,
                .close_reason = rec.close_reason,
            };
        }

        return .{
            .toasts = toasts_list,
            .history = history_list,
            .dnd = self.dnd,
        };
    }

    pub fn clearHistory(self: *Manager) void {
        for (self.history.items) |rec| {
            self.allocator.free(rec.app_name);
            self.allocator.free(rec.summary);
            self.allocator.free(rec.body);
            self.allocator.free(rec.app_icon);
        }
        self.history.clearRetainingCapacity();
    }
};

// --- D-Bus Service Method Handlers ---

fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    _ = result catch |err| {
        log.warn("notifications: D-Bus Hello failed: {}", .{err});
        return;
    };
    const mgr: *Manager = @ptrCast(@alignCast(owner orelse return));
    if (mgr.server.config.notifications.daemon.len == 0) {
        // DO_NOT_QUEUE only: never replace an existing notification service.
        _ = conn.requestName(bus_interface, 4, owner, onRequestName) catch |err| {
            log.warn("notifications: RequestName failed: {}", .{err});
        };
    } else {
        var body = wire.Writer{ .allocator = mgr.allocator };
        defer body.deinit();
        body.string(bus_interface) catch return;
        _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", &body, mgr, externalOwner, 5000) catch |err| {
            log.warn("notification daemon ownership lookup failed: {}", .{err});
        };
    }
    if (mgr.file_chooser) |chooser| chooser.start();
    settings_portal.requestName(conn);
    @import("../session/file_manager_service.zig").requestName(conn);
    settings_portal.startWatching(conn, mgr.server);
    _ = @import("../tray.zig").Tray.create(mgr.server, conn) catch |err| {
        log.warn("could not initialize application tray: {}", .{err});
    };
}

fn externalOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const mgr: *Manager = @ptrCast(@alignCast(owner orelse return));
    const message = result catch return;
    if (message.kind != .method_return) return;
    var body = message.body;
    if (body.boolean() catch true) return;
    @import("../config_runtime/actions.zig").spawnHelper(mgr.server, mgr.server.config.notifications.daemon);
}

fn onRequestName(_: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const msg = result catch |err| {
        log.warn("notifications: RequestName reply failed: {}", .{err});
        return;
    };
    if (msg.kind == .method_return) {
        var r = msg.body;
        const code = r.uint32() catch 0;
        if (code == 1 or code == 4) {
            log.info("notifications: acquired {s}", .{bus_interface});
        } else {
            log.warn("notifications: bus name {s} already owned (code {d})", .{ bus_interface, code });
        }
    }
}

fn handleGetCapabilities(owner: ?*anyopaque, conn: *dbus.Connection, request: wire.Message) anyerror!void {
    const mgr: *Manager = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    var body: wire.Writer = .{ .allocator = mgr.allocator };
    defer body.deinit();

    const arr = try body.beginArray(4);
    try body.string("body");
    try body.string("actions");
    try body.string("icon-static");
    try body.string("persistence");
    try body.endArray(arr);

    try conn.reply(request, "as", &body);
}

fn handleGetServerInformation(owner: ?*anyopaque, conn: *dbus.Connection, request: wire.Message) anyerror!void {
    const mgr: *Manager = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    var body: wire.Writer = .{ .allocator = mgr.allocator };
    defer body.deinit();

    try body.string("rediwm");
    try body.string("rediwm");
    try body.string("0.1.0");
    try body.string("1.2");

    try conn.reply(request, "ssss", &body);
}

fn handleNotify(owner: ?*anyopaque, conn: *dbus.Connection, request: wire.Message) anyerror!void {
    const mgr: *Manager = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    var r = request.body;

    const app_name = try r.string();
    const replaces_id = try r.uint32();
    const app_icon = try r.string();
    const summary = try r.string();
    const body_text = try r.string();

    // actions: as
    var actions_reader = try r.array(4);
    var actions_list: std.ArrayList(ActionPair) = .empty;
    defer actions_list.deinit(mgr.allocator);

    while (actions_reader.offset < actions_reader.bytes.len) {
        const key = try actions_reader.string();
        const label = if (actions_reader.offset < actions_reader.bytes.len)
            try actions_reader.string()
        else
            "";
        try actions_list.append(mgr.allocator, .{ .key = key, .label = label });
    }

    // hints: a{sv}
    var hints_reader = try r.array(8);
    var urgency: u8 = 1;
    var resident: bool = false;
    var transient: bool = false;
    var desktop_entry: []const u8 = "";
    var image_data: ?image_mod.DecodedImage = null;

    while (hints_reader.offset < hints_reader.bytes.len) {
        try hints_reader.alignTo(8);
        const key = try hints_reader.string();
        const val_sig = try hints_reader.variant();

        if (std.mem.eql(u8, key, "urgency")) {
            if (std.mem.eql(u8, val_sig, "y")) {
                urgency = try hints_reader.byte();
            } else if (std.mem.eql(u8, val_sig, "u") or std.mem.eql(u8, val_sig, "i")) {
                const u = try hints_reader.uint32();
                urgency = @intCast(@min(u, 2));
            } else {
                try hints_reader.skip(val_sig);
            }
        } else if (std.mem.eql(u8, key, "resident")) {
            if (std.mem.eql(u8, val_sig, "b")) {
                resident = try hints_reader.boolean();
            } else {
                try hints_reader.skip(val_sig);
            }
        } else if (std.mem.eql(u8, key, "transient")) {
            if (std.mem.eql(u8, val_sig, "b")) {
                transient = try hints_reader.boolean();
            } else {
                try hints_reader.skip(val_sig);
            }
        } else if (std.mem.eql(u8, key, "desktop-entry")) {
            if (std.mem.eql(u8, val_sig, "s")) {
                desktop_entry = try hints_reader.string();
            } else {
                try hints_reader.skip(val_sig);
            }
        } else if (std.mem.eql(u8, key, "image-data") or std.mem.eql(u8, key, "image_data")) {
            if (std.mem.eql(u8, val_sig, "(iiibiiay)")) {
                image_data = image_mod.decodeImageData(&hints_reader, mgr.allocator) catch null;
            } else {
                try hints_reader.skip(val_sig);
            }
        } else {
            try hints_reader.skip(val_sig);
        }
    }

    const expire_timeout = try r.int(i32);
    try r.done();

    const id = try mgr.postNotification(
        app_name,
        replaces_id,
        app_icon,
        summary,
        body_text,
        actions_list.items,
        urgency,
        resident,
        transient,
        expire_timeout,
        desktop_entry,
        image_data,
    );

    var reply_body: wire.Writer = .{ .allocator = mgr.allocator };
    defer reply_body.deinit();
    try reply_body.uint32(id);
    try conn.reply(request, "u", &reply_body);
}

fn handleCloseNotification(owner: ?*anyopaque, conn: *dbus.Connection, request: wire.Message) anyerror!void {
    const mgr: *Manager = @ptrCast(@alignCast(owner orelse return error.NoOwner));
    var r = request.body;
    const id = try r.uint32();
    try r.done();

    mgr.closeNotification(id, 3); // 3 = closed by call to CloseNotification

    var reply_body: wire.Writer = .{ .allocator = mgr.allocator };
    defer reply_body.deinit();
    try conn.reply(request, "", &reply_body);
}
