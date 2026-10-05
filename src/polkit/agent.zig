//! Registration and helper conversation. A consumer supplies prompt handling;
//! without one requests are cancelled.
const std = @import("std");
const wl = @import("wayland").server.wl;
const dbus = @import("dbus");
const activation = @import("../session/activation.zig");
const helper_mod = @import("helper.zig");
const identity = @import("identity.zig");
const C = dbus.Connection;
const wire = dbus.wire;
const log = std.log.scoped(.polkit);

pub const authority_name = "org.freedesktop.PolicyKit1";
const authority_path = "/org/freedesktop/PolicyKit1/Authority";
const authority_interface = "org.freedesktop.PolicyKit1.Authority";
pub const agent_path = "/org/freedesktop/PolicyKit1/AuthenticationAgent";
const agent_interface = "org.freedesktop.PolicyKit1.AuthenticationAgent";
const bus_name = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
const cancelled = "org.freedesktop.PolicyKit1.Error.Cancelled";

pub fn shouldConnect(view: activation.EnvView, force: ?[]const u8) bool {
    return activation.isTruthy(force) or (!activation.isNested(view) and activation.isTruthy(view.login_session));
}

pub const Agent = struct {
    allocator: std.mem.Allocator,
    conn: *C,
    loop: *wl.EventLoop,
    helper_socket: []const u8 = helper_mod.default_socket,
    enabled: bool = true,
    owned_helper_socket: ?[]u8 = null,
    helper: ?*helper_mod.Helper = null,
    active: ?Request = null,
    queue: std.ArrayList(Request) = .empty,
    pump_timer: ?*wl.EventSource = null,
    suspended: bool = false,
    restart: bool = false,
    draining: bool = false,
    conversation: ?Conversation = null,
    session_id: ?[]u8 = null,
    locale: []const u8,
    authority: ?[]u8 = null,
    owner_revision: usize = 0,
    query_revision: usize = 0,
    registration_pending: bool = false,
    registration_revision: usize = 0,
    registered: bool = false,
    closing: bool = false,
    observer: ?Observer = null,
    observer_owner: ?*anyopaque = null,

    pub const max_queued = 16;
    pub const max_attempts = 3;
    pub const State = enum { registered, unavailable };
    pub const Observer = *const fn (?*anyopaque, State) void;
    pub const Conversation = struct {
        owner: ?*anyopaque = null,
        opened: ?*const fn (?*anyopaque, *Agent, []const u8, []const u8) void = null,
        /// Text is borrowed; may respond/cancel, never destroy or dispatch.
        event: *const fn (?*anyopaque, *Agent, helper_mod.Event) void,
    };
    pub const Request = struct {
        reply: C.Deferred,
        cookie: []u8,
        account: identity.Account,
        helper_socket: []u8,
        action: []u8,
        message: []u8,
        attempt: u8 = 1,
    };

    pub fn create(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ, observer_owner: ?*anyopaque, observer: ?Observer) !?*Agent {
        if (!shouldConnect(activation.viewFromEnviron(environ), environ.getPosix("REDIWM_FORCE_POLKIT"))) return null;
        const conn = try C.openSystem(allocator, loop, environ);
        errdefer conn.destroy();
        const self = try allocator.create(Agent);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .loop = loop,
            .locale = nonempty(environ.getPosix("LC_ALL")) orelse nonempty(environ.getPosix("LC_MESSAGES")) orelse nonempty(environ.getPosix("LANG")) orelse "C",
            .observer_owner = observer_owner,
            .observer = observer,
        };
        self.pump_timer = try loop.addTimer(*Agent, pump, self);
        errdefer self.pump_timer.?.remove();
        if (nonempty(environ.getPosix(if (activation.isTruthy(environ.getPosix("REDIWM_FORCE_POLKIT"))) "XDG_SESSION_ID" else "REDIWM_LOGIN_SESSION"))) |id| self.session_id = try allocator.dupe(u8, id);
        errdefer if (self.session_id) |id| allocator.free(id);
        inline for (.{ "BeginAuthentication", "CancelAuthentication" }) |member| try conn.register(.{
            .path = agent_path,
            .interface = agent_interface,
            .member = member,
            .owner = self,
            .callback = method,
        });
        _ = try conn.hello(self, hello);
        conn.on_disconnect = .{ .owner = self, .callback = disconnected };
        return self;
    }

    /// Called outside dispatch, while the loop still exists. Unregister is
    /// best effort; bus disconnect always removes this connection's agent.
    pub fn destroy(self: *Agent) void {
        self.closing = true;
        self.cancelAll();
        if (self.pump_timer) |timer| timer.remove();
        if (self.helper) |helper| helper.destroy();
        self.helper = null;
        if (self.registered and !self.conn.closed) {
            self.unregister() catch |err| log.warn("unregister failed: {s}", .{@errorName(err)});
        }
        self.conn.destroy();
        self.queue.deinit(self.allocator);
        if (self.owned_helper_socket) |path| self.allocator.free(path);
        if (self.session_id) |id| self.allocator.free(id);
        if (self.authority) |owner| self.allocator.free(owner);
        self.allocator.destroy(self);
    }

    /// New policy affects admission only. Accepted requests own a path snapshot,
    /// including queued requests and retries, independent of config arena lifetime.
    pub fn configure(self: *Agent, enabled: bool, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.owned_helper_socket) |old| self.allocator.free(old);
        self.owned_helper_socket = owned;
        self.helper_socket = owned;
        self.enabled = enabled;
        self.settlePolicy();
        if (enabled) try self.maybeRegister();
        self.schedule();
    }
    fn settlePolicy(self: *Agent) void {
        if (self.enabled or !self.registered or self.active != null or self.queue.items.len != 0 or self.conn.closed) return;
        self.unregister() catch |err| {
            self.unavailable(err);
            return;
        };
        self.registered = false;
    }

    fn unregister(self: *Agent) !void {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try subject(&body, self.session_id.?);
        try body.string(agent_path); // Polkit specifies STRING, not OBJECT_PATH.
        _ = try self.conn.call(self.authority.?, authority_path, authority_interface, "UnregisterAuthenticationAgent", "(sa{sv})s", &body, null, null, 5000);
        try self.conn.flush();
    }

    fn from(owner: ?*anyopaque) *Agent {
        return @ptrCast(@alignCast(owner.?));
    }
    fn unavailable(self: *Agent, err: anyerror) void {
        if (self.closing) return;
        self.registered = false;
        log.warn("authentication agent unavailable: {s}", .{@errorName(err)});
        if (self.observer) |cb| cb(self.observer_owner, .unavailable);
    }
    fn returned(result: C.Failure!wire.Message, signature: []const u8) !wire.Message {
        const msg = try result;
        if (msg.kind != .method_return) return error.Refused;
        if (!std.mem.eql(u8, msg.headers.signature, signature)) return error.InvalidReply;
        return msg;
    }
    fn hello(owner: ?*anyopaque, conn: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing) return;
        _ = returned(result, "s") catch |err| return self.unavailable(err);
        _ = conn.subscribe(.{
            .sender = bus_name,
            .path = bus_path,
            .interface = bus_name,
            .member = "NameOwnerChanged",
            .owner = self,
            .callback = ownerChanged,
        }, self, subscribed) catch |err| self.unavailable(err);
    }
    fn subscribed(owner: ?*anyopaque, conn: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing) return;
        _ = returned(result, "") catch |err| return self.unavailable(err);
        if (self.session_id != null) return self.queryOwner();
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.uint32(@intCast(std.posix.system.getpid())) catch |err| return self.unavailable(err);
        _ = conn.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID", "u", &body, self, sessionPath, 5000) catch |err| self.unavailable(err);
    }
    fn sessionPath(owner: ?*anyopaque, conn: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing) return;
        var msg = returned(result, "o") catch |err| return self.unavailable(err);
        const path = msg.body.objectPath() catch |err| return self.unavailable(err);
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string("org.freedesktop.login1.Session") catch |err| return self.unavailable(err);
        body.string("Id") catch |err| return self.unavailable(err);
        _ = conn.call("org.freedesktop.login1", path, "org.freedesktop.DBus.Properties", "Get", "ss", &body, self, sessionId, 5000) catch |err| self.unavailable(err);
    }
    fn sessionId(owner: ?*anyopaque, _: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing) return;
        var msg = returned(result, "v") catch |err| return self.unavailable(err);
        const sig = msg.body.variant() catch |err| return self.unavailable(err);
        if (!std.mem.eql(u8, sig, "s")) return self.unavailable(error.InvalidReply);
        const id = msg.body.string() catch |err| return self.unavailable(err);
        if (id.len == 0) return self.unavailable(error.NoSession);
        self.session_id = self.allocator.dupe(u8, id) catch |err| return self.unavailable(err);
        self.queryOwner();
    }
    fn queryOwner(self: *Agent) void {
        self.query_revision = self.owner_revision;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        body.string(authority_name) catch |err| return self.unavailable(err);
        _ = self.conn.call(bus_name, bus_path, bus_name, "GetNameOwner", "s", &body, self, queriedOwner, 5000) catch |err| self.unavailable(err);
    }
    fn queriedOwner(owner: ?*anyopaque, conn: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing or self.query_revision != self.owner_revision) return;
        var msg = result catch |err| return self.unavailable(err);
        if (msg.kind == .error_reply and std.mem.eql(u8, msg.headers.error_name.?, "org.freedesktop.DBus.Error.NameHasNoOwner")) {
            var body: wire.Writer = .{ .allocator = self.allocator };
            defer body.deinit();
            body.string(authority_name) catch |err| return self.unavailable(err);
            body.uint32(0) catch |err| return self.unavailable(err);
            _ = conn.call(bus_name, bus_path, bus_name, "StartServiceByName", "su", &body, self, activated, 5000) catch |err| self.unavailable(err);
            return;
        }
        msg = returned(msg, "s") catch |err| return self.unavailable(err);
        const name = msg.body.string() catch |err| return self.unavailable(err);
        self.setOwner(name) catch |err| self.unavailable(err);
    }
    fn activated(owner: ?*anyopaque, _: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing or self.authority != null) return;
        _ = returned(result, "u") catch |err| return self.unavailable(err);
        self.queryOwner();
    }
    fn ownerChanged(owner: ?*anyopaque, _: *C, request: wire.Message) !void {
        const self = from(owner);
        if (self.closing or !std.mem.eql(u8, request.headers.signature, "sss")) return;
        var r = request.body;
        if (!std.mem.eql(u8, try r.string(), authority_name)) return;
        _ = try r.string();
        self.owner_revision +%= 1;
        self.setOwner(try r.string()) catch |err| self.unavailable(err);
    }
    fn setOwner(self: *Agent, name: []const u8) !void {
        if (self.authority) |old| {
            if (std.mem.eql(u8, old, name)) return self.maybeRegister();
        }
        const had_active = self.active != null;
        self.cancelAll();
        if (!had_active and self.authority != null) self.emit(.cancelled);
        if (self.authority) |old| self.allocator.free(old);
        self.authority = null;
        self.registered = false;
        if (name.len > 0) self.authority = try self.allocator.dupe(u8, name);
        try self.maybeRegister();
    }
    fn maybeRegister(self: *Agent) !void {
        if (!self.enabled or self.closing or self.authority == null or self.session_id == null or self.registration_pending or self.registered) return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try subject(&body, self.session_id.?);
        try body.string(self.locale);
        try body.string(agent_path);
        _ = try self.conn.call(self.authority.?, authority_path, authority_interface, "RegisterAuthenticationAgent", "(sa{sv})ss", &body, self, registrationReply, 5000);
        self.registration_pending = true;
        self.registration_revision = self.owner_revision;
    }
    fn registrationReply(owner: ?*anyopaque, _: *C, result: C.Failure!wire.Message) void {
        const self = from(owner);
        if (self.closing) return;
        self.registration_pending = false;
        if (self.registration_revision != self.owner_revision) {
            self.maybeRegister() catch |err| self.unavailable(err);
            return;
        }
        const msg = result catch |err| return self.unavailable(err);
        // A bus-generated refusal must not cause an unbounded retry loop.
        _ = returned(msg, "") catch |err| return self.unavailable(err);
        // A reply from an unrelated sender cannot validate this owner.
        if (self.authority == null or !std.mem.eql(u8, msg.headers.sender orelse "", self.authority.?)) {
            return self.unavailable(error.InvalidReply);
        }
        self.registered = true;
        self.settlePolicy();
        if (self.registered) {
            log.info("authentication agent registered", .{});
            if (self.observer) |cb| cb(self.observer_owner, .registered);
        }
    }
    fn method(owner: ?*anyopaque, conn: *C, request: wire.Message) !void {
        const self = from(owner);
        if (self.authority == null or !std.mem.eql(u8, request.headers.sender orelse "", self.authority.?)) {
            return conn.replyError(request, "org.freedesktop.DBus.Error.AccessDenied", "Only the polkit authority may call this agent");
        }
        if (std.mem.eql(u8, request.headers.member.?, "BeginAuthentication")) {
            if (!std.mem.eql(u8, request.headers.signature, "sssa{ss}sa(sa{sv})")) return error.BadSignature;
            if (!self.enabled) return conn.replyError(request, cancelled, "Authentication agent is disabled");
            if (self.conversation == null) return conn.replyError(request, cancelled, "Authentication dialog is not available");

            self.begin(request) catch |err| {
                log.warn("could not start authentication: {s}", .{@errorName(err)});
                try conn.replyError(request, cancelled, "Could not start authentication helper");
            };
        } else {
            if (!std.mem.eql(u8, request.headers.signature, "s")) return error.BadSignature;
            var r = request.body;
            const cookie = try r.string();
            self.cancelCookie(cookie);
            const body: wire.Writer = .{ .allocator = self.allocator };
            try conn.reply(request, "", &body);
        }
    }

    fn begin(self: *Agent, request: wire.Message) !void {
        var r = request.body;
        const action = try r.string();
        const message = try r.string();
        _ = try r.string();
        try r.skip("a{ss}");
        const cookie = try r.string();
        const candidates = try identity.parse(&r);
        try r.done();
        const account = try identity.pick(candidates.entries[0..candidates.len], identity.System{ .uid = std.posix.system.getuid() });
        if (cookie.len == 0 or cookie.len > 4096 or action.len > 4096 or message.len > 8192 or
            !std.unicode.utf8ValidateSlice(action) or !std.unicode.utf8ValidateSlice(message)) return error.InvalidRequest;
        if (self.queue.items.len >= max_queued) return error.QueueFull;
        if (self.active) |active| if (std.mem.eql(u8, cookie, active.cookie)) return error.DuplicateCookie;
        for (self.queue.items) |queued| if (std.mem.eql(u8, cookie, queued.cookie)) return error.DuplicateCookie;
        const owned_cookie = try self.allocator.dupe(u8, cookie);
        errdefer self.allocator.free(owned_cookie);
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        const owned_socket = try self.allocator.dupe(u8, self.helper_socket);
        errdefer self.allocator.free(owned_socket);
        var reply = try self.conn.deferReply(request);
        errdefer self.conn.releaseDeferred(&reply);
        try self.queue.append(self.allocator, .{ .reply = reply, .cookie = owned_cookie, .helper_socket = owned_socket, .action = owned_action, .message = owned_message, .account = account });
        self.schedule();
    }
    fn schedule(self: *Agent) void {
        if (self.closing or self.conn.closed or self.suspended or self.draining) return;
        if (self.pump_timer) |timer| timer.timerUpdate(1) catch self.cancelAll();
    }
    // A fresh event-loop turn is mandatory: a terminal helper callback must
    // never destroy its own Helper while advancing the queue or retrying.
    fn pump(self: *Agent) c_int {
        self.settlePolicy();
        if (self.closing or self.conn.closed or self.suspended or self.draining) return 0;
        if (self.active != null and !self.restart) return 0;
        if (self.active == null) {
            if (self.queue.items.len == 0) return 0;
            self.active = self.queue.orderedRemove(0);
        }
        self.restart = false;
        if (self.helper) |helper| helper.destroy();
        self.helper = null;
        if (self.conversation) |consumer| if (consumer.opened) |cb| cb(consumer.owner, self, self.active.?.action, self.active.?.message);
        if (self.active == null or self.suspended) return 0;
        const active = &self.active.?;
        self.helper = helper_mod.Helper.create(self.allocator, self.loop, .{
            .socket_path = active.helper_socket,
            .allow_spawn = std.mem.eql(u8, active.helper_socket, helper_mod.default_socket),
        }, active.account.username(), active.cookie, self, helperEvent) catch |err| {
            self.complete(false);
            self.emit(.{ .transport_error = err });
            self.schedule();
            return 0;
        };
        return 0;
    }
    fn emit(self: *Agent, event: helper_mod.Event) void {
        if (self.conversation) |consumer| consumer.event(consumer.owner, self, event);
    }
    /// Drop the helper and any partially entered response, keeping the request
    /// at the head of the queue. Resume starts a fresh conversation at the same
    /// attempt number; locking is not a failed password attempt.
    pub fn pauseForLock(self: *Agent) void {
        if (self.suspended) return;
        self.suspended = true;
        if (self.helper) |helper| helper.cancel();
        self.restart = self.active != null;
        self.emit(.cancelled);
    }
    pub fn resumeAfterLock(self: *Agent) void {
        if (!self.suspended) return;
        self.suspended = false;
        self.schedule();
    }
    fn cancelCookie(self: *Agent, cookie: []const u8) void {
        if (self.active) |active| if (std.mem.eql(u8, cookie, active.cookie)) {
            self.cancel();
            return;
        };
        for (self.queue.items, 0..) |queued, i| {
            if (!std.mem.eql(u8, cookie, queued.cookie)) continue;
            var removed = self.queue.orderedRemove(i);
            self.finishRequest(&removed, false);
            self.settlePolicy();
            return;
        }
    }
    pub fn cancelAll(self: *Agent) void {
        const was_draining = self.draining;
        self.draining = true;
        defer self.draining = was_draining;
        // Empty the queue before replying: a send failure may reenter through
        // on_disconnect. Every deferred handle still has exactly one owner.
        while (self.queue.items.len != 0) {
            var removed = self.queue.orderedRemove(0);
            self.finishRequest(&removed, false);
        }
        self.cancel();
        self.settlePolicy();
    }
    pub fn respond(self: *Agent, response: []const u8) !void {
        if (self.active == null or self.suspended or self.helper == null or self.restart) return error.NoPrompt;
        try self.helper.?.respond(response);
    }
    pub fn cancel(self: *Agent) void {
        const had_request = self.active != null;
        if (self.helper) |helper| helper.cancel();
        self.complete(false);
        if (had_request) self.emit(.cancelled);
        self.settlePolicy();
        self.schedule();
    }
    fn complete(self: *Agent, success: bool) void {
        if (self.active) |value| {
            var active = value;
            self.active = null;
            self.restart = false;
            self.finishRequest(&active, success);
        }
    }
    fn finishRequest(self: *Agent, active: *Request, success: bool) void {
        if (!self.conn.closed) {
            if (success) {
                const body: wire.Writer = .{ .allocator = self.allocator };
                self.conn.replyDeferred(&active.reply, "", &body) catch self.conn.close();
            } else self.conn.replyErrorDeferred(&active.reply, cancelled, "Authentication cancelled or failed") catch self.conn.close();
        }
        self.conn.releaseDeferred(&active.reply);
        self.allocator.free(active.cookie);
        self.allocator.free(active.helper_socket);
        self.allocator.free(active.action);
        self.allocator.free(active.message);
    }
    fn helperEvent(owner: ?*anyopaque, _: *helper_mod.Helper, event: helper_mod.Event) void {
        const self = from(owner);
        if (self.active == null or self.suspended) return;
        switch (event) {
            .failure => {
                if (self.active.?.attempt < max_attempts) {
                    self.active.?.attempt += 1;
                    self.restart = true;
                    self.emit(.{ .error_message = "Authentication failed. Please try again." });
                    self.schedule();
                    return;
                }
                self.complete(false);
            },
            .success => self.complete(true),
            .transport_error => self.complete(false),
            else => {},
        }
        self.emit(event);
        if (self.active == null) self.schedule();
    }
    fn disconnected(owner: ?*anyopaque) void {
        const self = from(owner);
        if (self.closing) return;
        const had_active = self.active != null;
        self.cancelAll();
        if (!had_active) self.emit(.cancelled);
        self.registered = false;
    }
};

fn nonempty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len > 0) text else null;
}

fn subject(body: *wire.Writer, session_id: []const u8) !void {
    try body.alignTo(8);
    try body.string("unix-session");
    const dict = try body.beginArray(8);
    try body.alignTo(8);
    try body.string("session-id");
    try body.variant("s");
    try body.string(session_id);
    try body.endArray(dict);
}

test "polkit startup policy isolates nested and headless sessions" {
    try std.testing.expect(!shouldConnect(.{}, null));
    try std.testing.expect(shouldConnect(.{ .login_session = "c1" }, null));
    try std.testing.expect(!shouldConnect(.{ .nested_flag = "1" }, null));
    try std.testing.expect(!shouldConnect(.{ .backends = "headless" }, "0"));
    try std.testing.expect(!shouldConnect(.{ .backends = "wayland" }, "false"));
    try std.testing.expect(!shouldConnect(.{ .import_flag = "0" }, null));
    try std.testing.expect(shouldConnect(.{ .backends = "headless" }, "1"));
}
