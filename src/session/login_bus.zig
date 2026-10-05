//! Blocking logind/systemd/bus calls for the login supervisor. Connections are
//! opened on first use and reopened after a disconnect; the private event loop
//! is only dispatched while a call is outstanding.
const std = @import("std");
const wl = @import("wayland").server.wl;
const dbus = @import("dbus");
const sys = @import("login_sys.zig");
const publication = @import("publication.zig");

const wire = dbus.wire;
const Connection = dbus.Connection;
const Env = publication.Env;
const Pair = publication.Pair;

const timeout_ms = 3000;
const login1 = "org.freedesktop.login1";
const systemd1 = "org.freedesktop.systemd1";
const properties = "org.freedesktop.DBus.Properties";

pub const Bus = struct {
    allocator: std.mem.Allocator,
    loop: *wl.EventLoop,
    system_address: []const u8,
    user_address: []const u8,
    system: ?*Connection = null,
    user: ?*Connection = null,

    pub fn init(allocator: std.mem.Allocator, system_address: []const u8, user_address: []const u8) !Bus {
        return .{
            .allocator = allocator,
            .loop = try wl.EventLoop.create(),
            .system_address = system_address,
            .user_address = user_address,
        };
    }

    pub fn deinit(self: *Bus) void {
        if (self.system) |conn| conn.destroy();
        if (self.user) |conn| conn.destroy();
        self.loop.destroy();
    }

    const Scope = enum { system, user };

    fn connection(self: *Bus, scope: Scope) !*Connection {
        const slot = switch (scope) {
            .system => &self.system,
            .user => &self.user,
        };
        if (slot.*) |conn| {
            if (!conn.closed) return conn;
            conn.destroy();
            slot.* = null;
        }
        const conn = try Connection.open(self.allocator, self.loop, switch (scope) {
            .system => self.system_address,
            .user => self.user_address,
        });
        errdefer conn.destroy();
        var reply: Reply = .{ .what = "Hello" };
        _ = try conn.hello(&reply, Reply.callback);
        try self.wait(&reply);
        reply.deinit(self.allocator);
        slot.* = conn;
        return conn;
    }

    fn wait(self: *Bus, reply: *Reply) !void {
        // The connection's own timer completes every call, so this never blocks forever.
        while (!reply.done) try self.loop.dispatch(-1);
        if (reply.failure) |err| {
            sys.diagnostic("D-Bus {s}: {t}", .{ reply.what, err });
            return err;
        }
        if (reply.error_name) |name| {
            sys.diagnostic("D-Bus {s}: {s}: {s}", .{ reply.what, name, reply.error_text orelse "" });
            return error.DBusError;
        }
    }

    /// Caller frees with `reply.deinit`.
    fn call(self: *Bus, scope: Scope, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer) !Reply {
        const conn = try self.connection(scope);
        var reply: Reply = .{ .what = member };
        errdefer reply.deinit(self.allocator);
        reply.allocator = self.allocator;
        _ = try conn.call(destination, path, interface, member, signature, body, &reply, Reply.callback, timeout_ms);
        try self.wait(&reply);
        return reply;
    }

    fn getProperty(self: *Bus, scope: Scope, destination: []const u8, path: []const u8, interface: []const u8, name: []const u8) !Reply {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(interface);
        try body.string(name);
        var reply = try self.call(scope, destination, path, properties, "Get", "ss", &body);
        errdefer reply.deinit(self.allocator);
        try reply.expect("v");
        return reply;
    }

    fn sessionString(self: *Bus, arena: std.mem.Allocator, path: []const u8, name: []const u8) ![]const u8 {
        var reply = try self.getProperty(.system, login1, path, login1 ++ ".Session", name);
        defer reply.deinit(self.allocator);
        var r = reply.reader();
        if (!std.mem.eql(u8, try r.variant(), "s")) return error.InvalidReply;
        return arena.dupe(u8, try r.string());
    }

    /// Only a verified local Wayland user login of this desktop may publish.
    /// Returns the logind session id.
    pub fn login(self: *Bus, arena: std.mem.Allocator) ![]const u8 {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.uint32(@intCast(std.os.linux.getpid()));
        var reply = try self.call(.system, login1, "/org/freedesktop/login1", login1 ++ ".Manager", "GetSessionByPID", "u", &body);
        defer reply.deinit(self.allocator);
        try reply.expect("o");
        var r = reply.reader();
        const path = try arena.dupe(u8, try r.objectPath());

        const uid = blk: {
            var user = try self.getProperty(.system, login1, path, login1 ++ ".Session", "User");
            defer user.deinit(self.allocator);
            var ur = user.reader();
            if (!std.mem.eql(u8, try ur.variant(), "(uo)")) return error.InvalidReply;
            try ur.alignTo(8);
            break :blk try ur.uint32();
        };
        const remote = blk: {
            var value = try self.getProperty(.system, login1, path, login1 ++ ".Session", "Remote");
            defer value.deinit(self.allocator);
            var vr = value.reader();
            if (!std.mem.eql(u8, try vr.variant(), "b")) return error.InvalidReply;
            break :blk try vr.boolean();
        };
        const desktop = try self.sessionString(arena, path, "Desktop");
        const desktop_ok = std.ascii.eqlIgnoreCase(desktop, "rediwm") or std.ascii.eqlIgnoreCase(desktop, "rediwm-release-safe");
        if (uid != std.os.linux.getuid() or
            !std.mem.eql(u8, try self.sessionString(arena, path, "Type"), "wayland") or
            !std.mem.eql(u8, try self.sessionString(arena, path, "Class"), "user") or
            !desktop_ok or remote)
        {
            sys.diagnostic("not a local Wayland user login", .{});
            return error.NotLocalWaylandLogin;
        }
        return self.sessionString(arena, path, "Id");
    }

    /// Another live graphical login of this uid shares the user bus.
    pub fn conflict(self: *Bus, arena: std.mem.Allocator, session: []const u8) !?[]const u8 {
        const body: wire.Writer = .{ .allocator = self.allocator };
        var reply = try self.call(.system, login1, "/org/freedesktop/login1", login1 ++ ".Manager", "ListSessions", "", &body);
        defer reply.deinit(self.allocator);
        try reply.expect("a(susso)");
        var r = reply.reader();
        var rows = try r.array(8);
        const Row = struct { sid: []const u8, path: []const u8 };
        var candidates: std.ArrayList(Row) = .empty;
        while (rows.offset < rows.bytes.len) {
            try rows.alignTo(8);
            const sid = try rows.string();
            const uid = try rows.uint32();
            _ = try rows.string();
            _ = try rows.string();
            const path = try rows.objectPath();
            if (uid == std.os.linux.getuid() and !std.mem.eql(u8, sid, session)) {
                try candidates.append(arena, .{ .sid = try arena.dupe(u8, sid), .path = try arena.dupe(u8, path) });
            }
        }
        for (candidates.items) |row| {
            const kind = try self.sessionString(arena, row.path, "Type");
            if (!std.mem.eql(u8, kind, "wayland") and !std.mem.eql(u8, kind, "x11")) continue;
            if (std.mem.eql(u8, try self.sessionString(arena, row.path, "State"), "closing")) continue;
            return row.sid;
        }
        return null;
    }

    /// The systemd user manager's environment.
    pub fn environment(self: *Bus, arena: std.mem.Allocator) !Env {
        var reply = try self.getProperty(.user, systemd1, "/org/freedesktop/systemd1", systemd1 ++ ".Manager", "Environment");
        defer reply.deinit(self.allocator);
        var r = reply.reader();
        if (!std.mem.eql(u8, try r.variant(), "as")) return error.InvalidReply;
        var list = try r.array(4);
        var env: Env = .empty;
        while (list.offset < list.bytes.len) {
            const assignment = try list.string();
            const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse continue;
            try env.put(arena, try arena.dupe(u8, assignment[0..eq]), try arena.dupe(u8, assignment[eq + 1 ..]));
        }
        return env;
    }

    pub fn systemd(self: *Bus, values: []const Pair, absent: []const []const u8) !void {
        if (values.len > 0) {
            var body: wire.Writer = .{ .allocator = self.allocator };
            defer body.deinit();
            const list = try body.beginArray(4);
            for (values) |pair| {
                const assignment = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ pair.key, pair.value });
                defer self.allocator.free(assignment);
                try body.string(assignment);
            }
            try body.endArray(list);
            var reply = try self.call(.user, systemd1, "/org/freedesktop/systemd1", systemd1 ++ ".Manager", "SetEnvironment", "as", &body);
            reply.deinit(self.allocator);
        }
        if (absent.len > 0) {
            var body: wire.Writer = .{ .allocator = self.allocator };
            defer body.deinit();
            const list = try body.beginArray(4);
            for (absent) |key| try body.string(key);
            try body.endArray(list);
            var reply = try self.call(.user, systemd1, "/org/freedesktop/systemd1", systemd1 ++ ".Manager", "UnsetEnvironment", "as", &body);
            reply.deinit(self.allocator);
        }
    }

    pub fn activation(self: *Bus, values: []const Pair) !void {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        const dict = try body.beginArray(8);
        for (values) |pair| {
            try body.alignTo(8);
            try body.string(pair.key);
            try body.string(pair.value);
        }
        try body.endArray(dict);
        var reply = try self.call(.user, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "UpdateActivationEnvironment", "a{ss}", &body);
        reply.deinit(self.allocator);
    }
};

/// A completed call, copied out of the borrowed message.
const Reply = struct {
    what: []const u8,
    allocator: ?std.mem.Allocator = null,
    done: bool = false,
    failure: ?Connection.Failure = null,
    error_name: ?[]u8 = null,
    error_text: ?[]u8 = null,
    signature: []u8 = &.{},
    body: []u8 = &.{},
    endian: std.builtin.Endian = .little,

    fn callback(owner: ?*anyopaque, _: *Connection, result: Connection.Failure!wire.Message) void {
        const self: *Reply = @ptrCast(@alignCast(owner.?));
        self.done = true;
        const msg = result catch |err| {
            self.failure = err;
            return;
        };
        const allocator = self.allocator orelse return;
        self.copy(allocator, msg) catch {
            self.failure = error.OutOfMemory;
        };
    }

    fn copy(self: *Reply, allocator: std.mem.Allocator, msg: wire.Message) !void {
        if (msg.kind == .error_reply) {
            self.error_name = try allocator.dupe(u8, msg.headers.error_name orelse "unknown error");
            if (std.mem.startsWith(u8, msg.headers.signature, "s")) {
                var r = msg.body;
                self.error_text = try allocator.dupe(u8, r.string() catch "");
            }
            return;
        }
        // The body origin is 8-aligned, so a copy from it keeps every alignment.
        self.signature = try allocator.dupe(u8, msg.headers.signature);
        self.body = try allocator.dupe(u8, msg.body.bytes[msg.body.offset..]);
        self.endian = msg.body.endian;
    }

    fn expect(self: *const Reply, signature: []const u8) !void {
        if (!std.mem.eql(u8, self.signature, signature)) return error.InvalidReply;
    }

    fn reader(self: *const Reply) wire.Reader {
        return .{ .bytes = self.body, .endian = self.endian };
    }

    fn deinit(self: *Reply, allocator: std.mem.Allocator) void {
        if (self.error_name) |v| allocator.free(v);
        if (self.error_text) |v| allocator.free(v);
        allocator.free(self.signature);
        allocator.free(self.body);
        self.* = .{ .what = self.what };
    }
};
