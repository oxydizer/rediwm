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
const login_manager = @import("login_manager.zig");
const systemd1 = "org.freedesktop.systemd1";
const properties = "org.freedesktop.DBus.Properties";

pub const Bus = Client(login_manager);

pub fn Client(comptime Login: type) type {
    return struct {
        const Self = @This();
        login_cookie: ?[]u8 = null,
        login_owner: ?[]u8 = null,
        owns_user_bus: bool = false,
        allocator: std.mem.Allocator,
        loop: *wl.EventLoop,
        system_address: []const u8,
        user_address: []const u8,
        system: ?*Connection = null,
        user: ?*Connection = null,

        pub fn init(allocator: std.mem.Allocator, system_address: []const u8, user_address: []const u8) !Self {
            return .{
                .allocator = allocator,
                .loop = try wl.EventLoop.create(),
                .system_address = system_address,
                .user_address = user_address,
            };
        }

        pub fn deinit(self: *Self) void {
            Login.release(self);
            if (self.login_owner) |owner| self.allocator.free(owner);
            if (self.system) |conn| conn.destroy();
            if (self.user) |conn| conn.destroy();
            self.loop.destroy();
        }

        const Scope = enum { system, user };

        fn connection(self: *Self, scope: Scope) !*Connection {
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

        fn wait(self: *Self, reply: *Reply) !void {
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
        fn call(self: *Self, scope: Scope, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer) !Reply {
            const conn = try self.connection(scope);
            var reply: Reply = .{ .what = member };
            errdefer reply.deinit(self.allocator);
            reply.allocator = self.allocator;
            _ = try conn.call(destination, path, interface, member, signature, body, &reply, Reply.callback, timeout_ms);
            try self.wait(&reply);
            return reply;
        }

        fn getProperty(self: *Self, scope: Scope, destination: []const u8, path: []const u8, interface: []const u8, name: []const u8) !Reply {
            var body: wire.Writer = .{ .allocator = self.allocator };
            defer body.deinit();
            try body.string(interface);
            try body.string(name);
            var reply = try self.call(scope, destination, path, properties, "Get", "ss", &body);
            errdefer reply.deinit(self.allocator);
            try reply.expect("v");
            return reply;
        }

        pub fn userReady(self: *Self) bool {
            _ = self.connection(.user) catch return false;
            return true;
        }

        /// Only a verified local Wayland user login of this desktop may publish.
        pub fn login(self: *Self, arena: std.mem.Allocator, context: login_manager.Context) ![]const u8 {
            return Login.login(self, arena, context) catch |err| {
                if (err == error.NotLocalWaylandLogin) sys.diagnostic("not a local Wayland user login", .{});
                return err;
            };
        }

        pub fn conflict(self: *Self, arena: std.mem.Allocator, session: []const u8) !?[]const u8 {
            return Login.conflict(self, arena, session);
        }

        /// Blocking transport for the shared login-manager backend.
        pub fn loginCall(self: *Self, request: login_manager.Request) !Reply {
            const conn = try self.connection(.system);
            var reply: Reply = .{ .what = @tagName(request), .allocator = self.allocator };
            errdefer reply.deinit(self.allocator);
            _ = try Login.call(conn, request, if (request == .owner) null else self.login_owner, &reply, Reply.callback, timeout_ms);
            try self.wait(&reply);
            return reply;
        }

        /// The systemd user manager's environment.
        pub fn environment(self: *Self, arena: std.mem.Allocator) !Env {
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

        pub fn systemd(self: *Self, values: []const Pair, absent: []const []const u8) !void {
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

        pub fn activation(self: *Self, values: []const Pair) !void {
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
}

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
    endian: std.lang.Endian = .little,

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

    pub fn expect(self: *const Reply, signature: []const u8) !void {
        if (!std.mem.eql(u8, self.signature, signature)) return error.InvalidReply;
    }

    pub fn reader(self: *const Reply) wire.Reader {
        return .{ .bytes = self.body, .endian = self.endian };
    }

    pub fn deinit(self: *Reply, allocator: std.mem.Allocator) void {
        if (self.error_name) |v| allocator.free(v);
        if (self.error_text) |v| allocator.free(v);
        allocator.free(self.signature);
        allocator.free(self.body);
        self.* = .{ .what = self.what };
    }
};
