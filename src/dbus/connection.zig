//! Single-threaded Wayland-loop D-Bus connection. Opening authenticates with a
//! bounded startup wait; Hello and all subsequent messages are asynchronous.
//! No implicit connection to a host bus and no name is acquired automatically.
const std = @import("std");
const wl = @import("wayland").server.wl;
const c = std.posix.system;
const wire = @import("wire.zig");
const address = @import("address.zig");
const log = std.log.scoped(.dbus);
const bus_name = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
const queue_limit = 8 * 1024 * 1024;
const pending_limit = 256;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    receive_fds: bool = false,
    read_fds: [16]c_int = undefined,
    read_fd_count: usize = 0,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    read_buf: std.ArrayList(u8) = .empty,
    write_buf: std.ArrayList(u8) = .empty,
    write_offset: usize = 0,
    /// Set for connections carrying secrets, alongside a locked allocator.
    wipe_buffers: bool = false,
    pending: std.ArrayList(Pending) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    signals: std.ArrayList(SignalHandler) = .empty,
    next_serial: u32 = 1,
    unique_name: ?[]const u8 = null,
    closed: bool = false,
    hello_sent: bool = false,
    callback_depth: usize = 0,
    /// Invoked once on close, before destroy; may clean up consumer work but
    /// must not destroy this connection or recursively dispatch the loop.
    on_disconnect: ?struct { owner: ?*anyopaque, callback: *const fn (?*anyopaque) void } = null,

    pub const Failure = error{ Disconnected, Timeout, InvalidReply, OutOfMemory };
    /// Message, slices and received FDs are borrowed only during the callback.
    /// Duplicate an FD with CLOEXEC to retain it after dispatch.
    /// Callbacks may enqueue calls/replies or close, but must not destroy or
    /// recursively dispatch the event loop. Destroy after dispatch returns.
    pub const Callback = *const fn (?*anyopaque, *Connection, Failure!wire.Message) void;
    pub const Method = *const fn (?*anyopaque, *Connection, wire.Message) anyerror!void;
    /// Owned reply address, not a copy of the request body. Do not copy this
    /// value; release it before destroying its connection, even after close.
    pub const Deferred = struct {
        serial: u32,
        sender: []u8,
        connection: ?*Connection,
        no_reply: bool,
    };
    pub const Handler = struct { path: []const u8, interface: []const u8, member: []const u8, owner: ?*anyopaque = null, callback: Method };
    pub const Signal = *const fn (?*anyopaque, *Connection, wire.Message) anyerror!void;
    pub const SignalCallback = Signal;
    pub const SignalHandler = struct {
        sender: ?[]const u8 = null,
        path: ?[]const u8 = null,
        interface: ?[]const u8 = null,
        member: ?[]const u8 = null,
        owner: ?*anyopaque = null,
        callback: Signal,
    };
    const Pending = struct { serial: u32, deadline: i64, owner: ?*anyopaque, callback: Callback, hello: bool = false };

    pub fn openSession(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Connection {
        return open(allocator, loop, environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus);
    }
    /// `DBUS_SYSTEM_BUS_ADDRESS` overrides the well-known socket per the D-Bus
    /// spec; tests use this to point a consumer at a private bus instead of
    /// the host's real system bus.
    pub fn openSystem(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Connection {
        return open(allocator, loop, environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/var/run/dbus/system_bus_socket");
    }
    /// Opt in to receiving UNIX_FDs; sending descriptors remains unsupported.
    pub fn openSystemWithFds(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Connection {
        return openWithFds(allocator, loop, environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/var/run/dbus/system_bus_socket", true);
    }
    pub fn open(allocator: std.mem.Allocator, loop: *wl.EventLoop, addresses: []const u8) !*Connection {
        return openWithFds(allocator, loop, addresses, false);
    }
    fn openWithFds(allocator: std.mem.Allocator, loop: *wl.EventLoop, addresses: []const u8, receive_fds: bool) !*Connection {
        var it: address.Iterator = .{ .remaining = addresses };
        var last_error: anyerror = error.NoSupportedAddress;
        while (try it.next()) |addr| {
            const fd = connectAuth(addr, receive_fds) catch |err| {
                last_error = err;
                continue;
            };
            errdefer _ = c.close(fd);
            const self = try allocator.create(Connection);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .fd = fd, .receive_fds = receive_fds };
            self.source = try loop.addFd(*Connection, fd, .{ .readable = true }, onFd, self);
            errdefer self.source.?.remove();
            // Armed only while a call awaits its reply; see armTimer.
            self.timer = try loop.addTimer(*Connection, onTimer, self);
            return self;
        }
        return last_error;
    }
    pub fn destroy(self: *Connection) void {
        std.debug.assert(self.callback_depth == 0);
        self.close();
        self.read_buf.deinit(self.allocator);
        self.write_buf.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.handlers.deinit(self.allocator);
        self.signals.deinit(self.allocator);
        if (self.unique_name) |name| self.allocator.free(name);
        self.allocator.destroy(self);
    }
    /// Completes every pending call exactly once. Idempotent; retains storage
    /// until destroy so closing from inside a callback is safe.
    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        if (self.source) |s| s.remove();
        self.source = null;
        if (self.timer) |s| s.remove();
        self.timer = null;
        _ = c.close(self.fd);
        self.closeReadFds();
        if (self.wipe_buffers) {
            std.crypto.secureZero(u8, self.write_buf.allocatedSlice());
            std.crypto.secureZero(u8, self.read_buf.allocatedSlice());
        }
        while (self.pending.items.len > 0) self.complete(self.pending.orderedRemove(0), error.Disconnected);
        if (self.on_disconnect) |handler| {
            self.callback_depth += 1;
            defer self.callback_depth -= 1;
            handler.callback(handler.owner);
        }
    }
    fn complete(self: *Connection, p: Pending, result: Failure!wire.Message) void {
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        p.callback(p.owner, self, result);
    }
    /// Handler strings must outlive the connection (normally string literals).
    pub fn register(self: *Connection, handler: Handler) !void {
        if (self.closed) return error.Disconnected;
        for (self.handlers.items) |h| if (eq(h.path, handler.path) and eq(h.interface, handler.interface) and eq(h.member, handler.member)) return error.DuplicateHandler;
        try self.handlers.append(self.allocator, handler);
    }
    /// Remove short-lived request objects before freeing their path and owner.
    pub fn unregisterMethodsByOwner(self: *Connection, owner: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.handlers.items.len) {
            if (self.handlers.items[i].owner == owner) _ = self.handlers.orderedRemove(i) else i += 1;
        }
    }
    /// Handler strings must outlive the registration (normally string literals).
    pub fn registerSignal(self: *Connection, handler: SignalHandler) !void {
        if (self.closed) return error.Disconnected;
        if (self.hasSignal(handler)) return error.DuplicateHandler;
        try self.signals.append(self.allocator, handler);
    }
    pub fn unregisterSignal(self: *Connection, handler: SignalHandler) bool {
        for (self.signals.items, 0..) |h, i| {
            if (eqOpt(h.sender, handler.sender) and
                eqOpt(h.path, handler.path) and
                eqOpt(h.interface, handler.interface) and
                eqOpt(h.member, handler.member) and
                h.owner == handler.owner and
                h.callback == handler.callback)
            {
                _ = self.signals.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
    pub fn unregisterSignalsByOwner(self: *Connection, owner: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.signals.items.len) {
            if (self.signals.items[i].owner == owner) {
                _ = self.signals.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    fn hasSignal(self: *Connection, handler: SignalHandler) bool {
        for (self.signals.items) |h| {
            if (eqOpt(h.sender, handler.sender) and
                eqOpt(h.path, handler.path) and
                eqOpt(h.interface, handler.interface) and
                eqOpt(h.member, handler.member) and
                h.owner == handler.owner and
                h.callback == handler.callback)
            {
                return true;
            }
        }
        return false;
    }
    pub fn formatMatchRule(buf: []u8, handler: SignalHandler) ![]const u8 {
        var offset: usize = 0;
        const prefix = "type='signal'";
        if (buf.len < prefix.len) return error.NoSpaceLeft;
        @memcpy(buf[0..prefix.len], prefix);
        offset += prefix.len;
        if (handler.sender) |s| {
            const part = try std.fmt.bufPrint(buf[offset..], ",sender='{s}'", .{s});
            offset += part.len;
        }
        if (handler.interface) |i| {
            const part = try std.fmt.bufPrint(buf[offset..], ",interface='{s}'", .{i});
            offset += part.len;
        }
        if (handler.member) |m| {
            const part = try std.fmt.bufPrint(buf[offset..], ",member='{s}'", .{m});
            offset += part.len;
        }
        if (handler.path) |p| {
            const part = try std.fmt.bufPrint(buf[offset..], ",path='{s}'", .{p});
            offset += part.len;
        }
        return buf[0..offset];
    }
    pub fn addMatch(self: *Connection, rule: []const u8, owner: ?*anyopaque, callback: ?Callback) !u32 {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(rule);
        return self.call(bus_name, bus_path, bus_name, "AddMatch", "s", &body, owner, callback, 5000);
    }
    pub fn removeMatch(self: *Connection, rule: []const u8, owner: ?*anyopaque, callback: ?Callback) !u32 {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(rule);
        return self.call(bus_name, bus_path, bus_name, "RemoveMatch", "s", &body, owner, callback, 5000);
    }
    pub fn subscribe(self: *Connection, handler: SignalHandler, owner: ?*anyopaque, callback: ?Callback) !u32 {
        try self.registerSignal(handler);
        errdefer _ = self.unregisterSignal(handler);
        var rule_buf: [512]u8 = undefined;
        const rule = try formatMatchRule(&rule_buf, handler);
        return self.addMatch(rule, owner, callback);
    }
    pub fn unsubscribe(self: *Connection, handler: SignalHandler, owner: ?*anyopaque, callback: ?Callback) !u32 {
        _ = self.unregisterSignal(handler);
        var rule_buf: [512]u8 = undefined;
        const rule = try formatMatchRule(&rule_buf, handler);
        return self.removeMatch(rule, owner, callback);
    }
    pub fn hello(self: *Connection, owner: ?*anyopaque, callback: Callback) !u32 {
        if (self.hello_sent) return error.AlreadyRegistered;
        const body: wire.Writer = .{ .allocator = self.allocator };
        const serial = try self.callInternal(bus_name, bus_path, bus_name, "Hello", "", &body, owner, callback, 5000, true, 0);
        self.hello_sent = true;
        return serial;
    }
    pub fn requestName(self: *Connection, name: []const u8, flags: u32, owner: ?*anyopaque, callback: Callback) !u32 {
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(name);
        try body.uint32(flags);
        return self.call(bus_name, bus_path, bus_name, "RequestName", "su", &body, owner, callback, 5000);
    }
    pub fn call(self: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, owner: ?*anyopaque, callback: ?Callback, timeout_ms: u32) !u32 {
        return self.callWithFlags(destination, path, interface, member, signature, body, owner, callback, timeout_ms, 0);
    }
    pub fn callWithFlags(self: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, owner: ?*anyopaque, callback: ?Callback, timeout_ms: u32, flags: u8) !u32 {
        if (self.unique_name == null) return error.NotRegistered;
        return self.callInternal(destination, path, interface, member, signature, body, owner, callback, timeout_ms, false, flags);
    }
    fn callInternal(self: *Connection, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer, owner: ?*anyopaque, callback: ?Callback, timeout_ms: u32, is_hello: bool, flags: u8) !u32 {
        if (self.closed) return error.Disconnected;
        const serial = self.allocateSerial();
        if (callback) |cb| {
            if (self.pending.items.len == pending_limit) return error.TooManyPendingCalls;
            try self.pending.append(self.allocator, .{ .serial = serial, .deadline = nowMs() + @as(i64, @max(1, timeout_ms)), .owner = owner, .callback = cb, .hello = is_hello });
            errdefer _ = self.pending.pop();
            try self.armTimer();
            try self.send(.method_call, flags, serial, .{ .destination = destination, .path = path, .interface = interface, .member = member, .signature = signature }, body);
        } else {
            try self.send(.method_call, flags | wire.flag_no_reply_expected, serial, .{ .destination = destination, .path = path, .interface = interface, .member = member, .signature = signature }, body);
        }
        return serial;
    }
    pub fn reply(self: *Connection, request: wire.Message, signature: []const u8, body: *const wire.Writer) !void {
        if (request.kind != .method_call) return error.InvalidRequest;
        if (request.flags & 1 != 0) return;
        try self.send(.method_return, 0, self.allocateSerial(), .{ .destination = request.headers.sender orelse return error.MissingSender, .reply_serial = request.serial, .signature = signature }, body);
    }
    /// Return successfully from the handler after deferring: dispatch sends
    /// nothing automatically. Any other request data needed later must be copied.
    pub fn deferReply(self: *Connection, request: wire.Message) !Deferred {
        if (self.closed) return error.Disconnected;
        if (request.kind != .method_call) return error.InvalidRequest;
        return .{
            .serial = request.serial,
            .sender = try self.allocator.dupe(u8, request.headers.sender orelse return error.MissingSender),
            .connection = self,
            .no_reply = request.flags & wire.flag_no_reply_expected != 0,
        };
    }
    /// Success consumes the handle. On failure it remains owned by the caller
    /// for retry or release; close makes every outstanding handle unusable.
    pub fn replyDeferred(self: *Connection, deferred: *Deferred, signature: []const u8, body: *const wire.Writer) !void {
        try self.checkDeferred(deferred);
        if (!deferred.no_reply) try self.send(.method_return, 0, self.allocateSerial(), .{ .destination = deferred.sender, .reply_serial = deferred.serial, .signature = signature }, body);
        self.releaseDeferred(deferred);
    }
    pub fn replyErrorDeferred(self: *Connection, deferred: *Deferred, name: []const u8, description: []const u8) !void {
        try self.checkDeferred(deferred);
        if (!deferred.no_reply) {
            var body: wire.Writer = .{ .allocator = self.allocator };
            defer body.deinit();
            try body.string(description);
            try self.send(.error_reply, 0, self.allocateSerial(), .{ .destination = deferred.sender, .reply_serial = deferred.serial, .error_name = name, .signature = "s" }, &body);
        }
        self.releaseDeferred(deferred);
    }
    fn checkDeferred(self: *Connection, deferred: *const Deferred) !void {
        if (deferred.connection != self) return error.InvalidRequest;
        if (self.closed) return error.Disconnected;
    }
    /// Abandon without replying. Idempotent, including after close; must run
    /// before destroy. A handle belongs only to the connection that created it.
    pub fn releaseDeferred(self: *Connection, deferred: *Deferred) void {
        if (deferred.connection == null) return;
        std.debug.assert(deferred.connection == self);
        self.allocator.free(deferred.sender);
        deferred.sender = &.{};
        deferred.connection = null;
    }
    pub fn replyError(self: *Connection, request: wire.Message, name: []const u8, description: []const u8) !void {
        if (request.kind != .method_call) return error.InvalidRequest;
        if (request.flags & 1 != 0) return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(description);
        try self.send(.error_reply, 0, self.allocateSerial(), .{ .destination = request.headers.sender orelse return error.MissingSender, .reply_serial = request.serial, .error_name = name, .signature = "s" }, &body);
    }
    pub fn signal(self: *Connection, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: *const wire.Writer) !void {
        if (self.unique_name == null) return error.NotRegistered;
        try self.send(.signal, 0, self.allocateSerial(), .{ .path = path, .interface = interface, .member = member, .signature = signature }, body);
    }
    fn allocateSerial(self: *Connection) u32 {
        while (true) {
            const value = self.next_serial;
            self.next_serial +%= 1;
            if (self.next_serial == 0) self.next_serial = 1;
            var used = false;
            for (self.pending.items) |p| if (p.serial == value) {
                used = true;
                break;
            };
            if (!used) return value;
        }
    }
    fn send(self: *Connection, kind: wire.Kind, flags: u8, value: u32, h: wire.Headers, body: *const wire.Writer) !void {
        if (self.closed) return error.Disconnected;
        var message = try wire.encode(self.allocator, kind, flags, value, h, body);
        defer message.deinit();
        if (message.bytes.items.len > queue_limit - (self.write_buf.items.len - self.write_offset)) return error.QueueFull;
        self.compactWrites();
        const old_len = self.write_buf.items.len;
        try self.write_buf.appendSlice(self.allocator, message.bytes.items);
        errdefer self.write_buf.items.len = old_len;
        try self.interest();
    }
    fn compactWrites(self: *Connection) void {
        const remaining = self.write_buf.items[self.write_offset..];
        std.mem.copyForwards(u8, self.write_buf.items[0..remaining.len], remaining);
        if (self.wipe_buffers) std.crypto.secureZero(u8, self.write_buf.items[remaining.len..]);
        self.write_buf.items.len = remaining.len;
        self.write_offset = 0;
    }
    fn interest(self: *Connection) !void {
        if (self.source) |s| try s.fdUpdate(.{ .readable = true, .writable = self.write_buf.items.len > self.write_offset });
    }
    fn dispatch(self: *Connection, message: wire.Message) !void {
        if (message.kind == .method_return or message.kind == .error_reply) {
            for (self.pending.items, 0..) |p, i| {
                if (p.serial != message.headers.reply_serial.?) continue;
                _ = self.pending.orderedRemove(i);
                if (p.hello) {
                    if (message.kind != .method_return or !eq(message.headers.signature, "s")) {
                        self.complete(p, error.InvalidReply);
                        self.close();
                        return;
                    }
                    var body = message.body;
                    const name = try body.string();
                    if (name.len < 3 or name[0] != ':') {
                        self.complete(p, error.InvalidReply);
                        self.close();
                        return;
                    }
                    self.unique_name = self.allocator.dupe(u8, name) catch {
                        self.complete(p, error.OutOfMemory);
                        self.close();
                        return;
                    };
                }
                self.complete(p, message);
                return;
            }
        } else if (message.kind == .method_call) {
            for (self.handlers.items) |h| {
                if (eq(h.path, message.headers.path.?) and eq(h.member, message.headers.member.?) and
                    (message.headers.interface == null or eq(h.interface, message.headers.interface.?)))
                {
                    self.callback_depth += 1;
                    defer self.callback_depth -= 1;
                    h.callback(h.owner, self, message) catch |err| {
                        if (!self.closed) try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", @errorName(err));
                    };
                    return;
                }
            }
            try self.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "No matching method");
        } else if (message.kind == .signal) {
            if (self.signals.items.len == 0) return;
            var inline_buf: [16]SignalHandler = undefined;
            const snapshot = if (self.signals.items.len <= inline_buf.len) blk: {
                @memcpy(inline_buf[0..self.signals.items.len], self.signals.items);
                break :blk inline_buf[0..self.signals.items.len];
            } else self.allocator.dupe(SignalHandler, self.signals.items) catch return;
            defer if (snapshot.ptr != &inline_buf) self.allocator.free(snapshot);

            for (snapshot) |h| {
                if (self.closed) break;
                if (!self.hasSignal(h)) continue;
                if (h.sender) |s| if (message.headers.sender == null or !eq(s, message.headers.sender.?)) continue;
                if (h.path) |p| if (message.headers.path == null or !eq(p, message.headers.path.?)) continue;
                if (h.interface) |iface| if (message.headers.interface == null or !eq(iface, message.headers.interface.?)) continue;
                if (h.member) |m| if (message.headers.member == null or !eq(m, message.headers.member.?)) continue;
                {
                    self.callback_depth += 1;
                    defer self.callback_depth -= 1;
                    h.callback(h.owner, self, message) catch |err| {
                        log.warn("signal callback error: {}", .{err});
                    };
                }
            }
        }
    }
    fn closeReadFds(self: *Connection) void {
        for (self.read_fds[0..self.read_fd_count]) |fd| _ = c.close(fd);
        self.read_fd_count = 0;
    }
    fn readWithFds(self: *Connection) !void {
        // Never cross a message boundary: ancillary FDs belong to this frame.
        // Bound each event's work, and close even unclaimed or malformed replies.
        const target = (try wire.frameLength(self.read_buf.items)) orelse 16;
        var buf: [16384]u8 = undefined;
        var iov: std.posix.iovec = .{ .base = &buf, .len = @min(buf.len, target - self.read_buf.items.len) };
        var control: [@sizeOf(c.cmsghdr) + 16 * @sizeOf(c_int)]u8 align(@alignOf(c.cmsghdr)) = undefined;
        var msg: c.msghdr = std.mem.zeroes(c.msghdr);
        msg.iov = @ptrCast(&iov);
        msg.iovlen = 1;
        msg.control = &control;
        msg.controllen = control.len;
        const n = c.recvmsg(self.fd, &msg, std.posix.MSG.CMSG_CLOEXEC);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) return;
            return error.ReadFailed;
        }
        var overflow = false;
        var offset: usize = 0;
        while (offset + @sizeOf(c.cmsghdr) <= msg.controllen) {
            const header: *const c.cmsghdr = @ptrCast(@alignCast(&control[offset]));
            if (header.len < @sizeOf(c.cmsghdr) or header.len > msg.controllen - offset) return error.InvalidReply;
            if (header.level == std.posix.SOL.SOCKET and header.type == c.SCM.RIGHTS) {
                const data = control[offset + @sizeOf(c.cmsghdr) .. offset + header.len];
                const fds: []const c_int = std.mem.bytesAsSlice(c_int, @as([]align(@alignOf(c_int)) const u8, @alignCast(data)));
                for (fds) |fd| {
                    if (self.read_fd_count == self.read_fds.len) {
                        _ = c.close(fd);
                        overflow = true;
                    } else {
                        self.read_fds[self.read_fd_count] = fd;
                        self.read_fd_count += 1;
                    }
                }
            }
            offset += std.mem.alignForward(usize, header.len, @sizeOf(usize));
        }
        if (overflow or msg.flags & std.posix.MSG.CTRUNC != 0) return error.TooManyFds;
        if (n == 0) return error.Disconnected;
        try self.read_buf.appendSlice(self.allocator, buf[0..@intCast(n)]);
        const len = (try wire.frameLength(self.read_buf.items)) orelse return;
        if (self.read_buf.items.len < len) return;
        defer self.closeReadFds();
        try self.dispatch(try wire.decodeWithFds(self.read_buf.items, self.read_fds[0..self.read_fd_count]));
        self.read_buf.clearRetainingCapacity();
    }
    fn read(self: *Connection) !void {
        if (self.receive_fds) return self.readWithFds();
        // One chunk per event prevents a busy peer starving compositor frames.
        var buf: [16384]u8 = undefined;
        const n = c.read(self.fd, &buf, buf.len);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) return;
            return error.ReadFailed;
        }
        if (n == 0) return error.Disconnected;
        if (@as(usize, @intCast(n)) > wire.max_message - self.read_buf.items.len) return error.TooLarge;
        try self.read_buf.appendSlice(self.allocator, buf[0..@intCast(n)]);
        var consumed: usize = 0;
        while (!self.closed) {
            const bytes = self.read_buf.items[consumed..];
            const len = (try wire.frameLength(bytes)) orelse break;
            if (bytes.len < len) break;
            try self.dispatch(try wire.decode(bytes[0..len]));
            consumed += len;
        }
        const rest = self.read_buf.items[consumed..];
        std.mem.copyForwards(u8, self.read_buf.items[0..rest.len], rest);
        self.read_buf.items.len = rest.len;
    }
    /// Try to drain queued output without waiting or dispatching callbacks.
    /// Shutdown users may flush best-effort messages before closing; EAGAIN
    /// leaves bytes queued, so delivery is not guaranteed by this operation.
    pub fn flush(self: *Connection) !void {
        if (self.closed) return error.Disconnected;
        try self.write();
        try self.interest();
    }
    fn write(self: *Connection) !void {
        const data = self.write_buf.items[self.write_offset..];
        if (data.len == 0) return;
        const n = c.send(self.fd, data.ptr, data.len, std.posix.MSG.NOSIGNAL);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) return;
            return error.WriteFailed;
        }
        if (n == 0) return error.Disconnected;
        self.write_offset += @intCast(n);
        self.compactWrites();
    }
    fn onFd(_: c_int, mask: wl.EventMask, self: *Connection) c_int {
        if (mask.readable) self.read() catch |err| {
            log.warn("connection closed: {}", .{err});
            self.close();
        };
        if (!self.closed and mask.writable) self.write() catch {
            self.close();
        };
        if (mask.hangup or mask.@"error") self.close();
        if (!self.closed) self.interest() catch {
            self.close();
        };
        return 0;
    }
    fn onTimer(self: *Connection) c_int {
        const now = nowMs();
        var i: usize = 0;
        while (!self.closed and i < self.pending.items.len) {
            if (self.pending.items[i].deadline <= now) {
                const p = self.pending.orderedRemove(i);
                self.complete(p, error.Timeout);
                if (p.hello) self.close();
            } else i += 1;
        }
        if (!self.closed) self.armTimer() catch self.close();
        return 0;
    }
    /// Wake for the earliest reply deadline, or not at all. An idle
    /// connection must not poll: a fixed 100 ms sweep woke the compositor
    /// 10 times a second per connection with nothing outstanding. A call
    /// answered before its deadline leaves at most one early wakeup, which
    /// re-arms for the next deadline or disarms.
    fn armTimer(self: *Connection) !void {
        const timer = self.timer orelse return;
        if (self.pending.items.len == 0) return timer.timerUpdate(0);
        var earliest = self.pending.items[0].deadline;
        for (self.pending.items[1..]) |p| earliest = @min(earliest, p.deadline);
        const delay = std.math.clamp(earliest - nowMs(), 1, std.math.maxInt(c_int));
        try timer.timerUpdate(@intCast(delay));
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn eqOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return eq(a.?, b.?);
}
fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
fn waitFd(fd: c_int, events: i16, deadline: i64) !void {
    while (true) {
        const left = deadline - nowMs();
        if (left <= 0) return error.AuthTimeout;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = c.poll(&fds, 1, @intCast(left));
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ConnectFailed;
        }
        if (n == 0) return error.AuthTimeout;
        if (fds[0].revents & events != 0) return;
        return error.Disconnected;
    }
}
fn authWrite(fd: c_int, bytes: []const u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitFd(fd, std.posix.POLL.OUT, deadline);
        const n = c.send(fd, bytes[offset..].ptr, bytes.len - offset, std.posix.MSG.NOSIGNAL);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) continue;
            return error.AuthFailed;
        }
        if (n == 0) return error.Disconnected;
        offset += @intCast(n);
    }
}
fn connectAuth(addr: address.Address, receive_fds: bool) !c_int {
    const fd = c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    const deadline = nowMs() + 2000;
    const rc = c.connect(fd, @ptrCast(&addr.socket), addr.len);
    if (rc < 0) {
        const err = std.posix.errno(rc);
        if (err != .INPROGRESS and err != .AGAIN and err != .INTR) return error.ConnectFailed;
        try waitFd(fd, std.posix.POLL.OUT, deadline);
        var socket_error: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&socket_error), &len) != 0 or socket_error != 0) return error.ConnectFailed;
    }
    var uid_buf: [20]u8 = undefined;
    const uid = try std.fmt.bufPrint(&uid_buf, "{d}", .{c.getuid()});
    var auth: [80]u8 = undefined;
    const prefix = "\x00AUTH EXTERNAL ";
    @memcpy(auth[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (uid, 0..) |ch, i| {
        auth[prefix.len + i * 2] = hex[ch >> 4];
        auth[prefix.len + i * 2 + 1] = hex[ch & 15];
    }
    const end = prefix.len + uid.len * 2;
    @memcpy(auth[end..][0..2], "\r\n");
    try authWrite(fd, auth[0 .. end + 2], deadline);
    var line: [1024]u8 = undefined;
    var count: usize = 0;
    while (count < line.len) {
        try waitFd(fd, std.posix.POLL.IN, deadline);
        const n = c.read(fd, line[count..].ptr, 1);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN or err == .INTR) continue;
            return error.AuthFailed;
        }
        if (n == 0) return error.Disconnected;
        count += 1;
        if (count >= 2 and eq(line[count - 2 .. count], "\r\n")) break;
    }
    if (count != 37 or !eq(line[0..3], "OK ") or !eq(line[count - 2 .. count], "\r\n")) return error.AuthFailed;
    for (line[3..35]) |ch| if (!std.ascii.isHex(ch)) return error.AuthFailed;
    if (addr.guid) |guid| if (!std.ascii.eqlIgnoreCase(&guid, line[3..35])) return error.GuidMismatch;
    if (receive_fds) {
        try authWrite(fd, "NEGOTIATE_UNIX_FD\r\n", deadline);
        const expected = "AGREE_UNIX_FD\r\n";
        for (expected) |ch| {
            var byte: [1]u8 = undefined;
            while (true) {
                try waitFd(fd, std.posix.POLL.IN, deadline);
                const n = c.read(fd, &byte, 1);
                if (n < 0 and (std.posix.errno(n) == .AGAIN or std.posix.errno(n) == .INTR)) continue;
                if (n != 1 or byte[0] != ch) return error.AuthFailed;
                break;
            }
        }
    }
    try authWrite(fd, "BEGIN\r\n", deadline);
    return fd;
}

const TestResult = struct {
    count: usize = 0,
    failure: ?Connection.Failure = null,
    fn callback(owner: ?*anyopaque, _: *Connection, result: Connection.Failure!wire.Message) void {
        const self: *TestResult = @ptrCast(@alignCast(owner.?));
        self.count += 1;
        if (result) |_| {} else |err| {
            self.failure = err;
        }
    }
};
fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    const display = try wl.Server.create();
    defer display.destroy();
    var fds: [2]c_int = undefined;
    if (c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0, &fds) != 0) return error.SocketFailed;
    defer _ = c.close(fds[1]);
    var self: Connection = .{ .allocator = allocator, .fd = fds[0] };
    var result: TestResult = .{};
    defer {
        self.close();
        self.read_buf.deinit(allocator);
        self.write_buf.deinit(allocator);
        self.pending.deinit(allocator);
        self.handlers.deinit(allocator);
        self.signals.deinit(allocator);
    }
    self.source = try display.getEventLoop().addFd(*Connection, self.fd, .{ .readable = true }, Connection.onFd, &self);
    self.timer = try display.getEventLoop().addTimer(*Connection, Connection.onTimer, &self);
    _ = self.hello(&result, TestResult.callback) catch |err| {
        try std.testing.expectEqual(0, self.pending.items.len);
        try std.testing.expectEqual(0, self.write_buf.items.len);
        try std.testing.expectEqual(0, result.count);
        self.close();
        try display.getEventLoop().dispatch(0);
        return err;
    };
    try std.testing.expectEqual(1, self.pending.items.len);
    self.close();
    self.close();
    try std.testing.expectEqual(1, result.count);
    try std.testing.expectEqual(error.Disconnected, result.failure.?);
    try display.getEventLoop().dispatch(0);
}
test "dbus lifecycle allocation failures leave no pending call or event sources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}
test "disconnect hook runs once and can close reentrantly" {
    const Owner = struct {
        conn: *Connection,
        count: usize = 0,
        fn disconnected(owner: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(owner.?));
            self.count += 1;
            self.conn.close();
        }
    };
    var conn: Connection = .{ .allocator = std.testing.allocator, .fd = -1 };
    var owner: Owner = .{ .conn = &conn };
    conn.on_disconnect = .{ .owner = &owner, .callback = Owner.disconnected };
    conn.close();
    conn.close();
    try std.testing.expectEqual(1, owner.count);
    try std.testing.expectEqual(0, conn.callback_depth);
}
test "dbus serial wrap skips zero and live calls" {
    var self: Connection = .{ .allocator = std.testing.allocator, .fd = -1, .next_serial = 0xffffffff };
    defer self.pending.deinit(self.allocator);
    try self.pending.append(self.allocator, .{ .serial = 1, .deadline = 0, .owner = null, .callback = TestResult.callback });
    try std.testing.expectEqual(0xffffffff, self.allocateSerial());
    try std.testing.expectEqual(2, self.allocateSerial());
}

fn deferredLifecycle(allocator: std.mem.Allocator) !void {
    var self: Connection = .{ .allocator = allocator, .fd = -1 };
    defer {
        self.close();
        self.handlers.deinit(allocator);
        self.write_buf.deinit(allocator);
    }
    const Capture = struct {
        reply: ?Connection.Deferred = null,
        fn method(owner: ?*anyopaque, conn: *Connection, request: wire.Message) !void {
            const capture: *@This() = @ptrCast(@alignCast(owner.?));
            capture.reply = try conn.deferReply(request);
        }
    };
    var capture: Capture = .{};
    defer if (capture.reply) |*reply| self.releaseDeferred(reply);
    try self.register(.{ .path = "/test", .interface = "org.test.Agent", .member = "Begin", .owner = &capture, .callback = Capture.method });
    const body: wire.Writer = .{ .allocator = allocator };
    {
        var encoded = try wire.encode(allocator, .method_call, 0, 42, .{ .sender = ":1.123", .path = "/test", .interface = "org.test.Agent", .member = "Begin" }, &body);
        defer encoded.deinit();
        try self.dispatch(try wire.decode(encoded.bytes.items));
    } // The request's storage is gone before the reply is sent.
    // dispatch turns handler allocation failures into InvalidArgs.
    if (capture.reply == null) return error.OutOfMemory;
    try std.testing.expectEqual(0, self.write_buf.items.len);
    try std.testing.expectEqualStrings(":1.123", capture.reply.?.sender);
    try self.replyDeferred(&capture.reply.?, "", &body);
    const response = try wire.decode(self.write_buf.items);
    try std.testing.expectEqual(wire.Kind.method_return, response.kind);
    try std.testing.expectEqual(42, response.headers.reply_serial.?);
    try std.testing.expectEqualStrings(":1.123", response.headers.destination.?);
    try std.testing.expectError(error.InvalidRequest, self.replyDeferred(&capture.reply.?, "", &body));
}

test "deferred replies outlive handler storage and clean up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, deferredLifecycle, .{});
}

test "deferred errors, suppression, abandonment and connection ownership" {
    const allocator = std.testing.allocator;
    var self: Connection = .{ .allocator = allocator, .fd = -1 };
    defer self.write_buf.deinit(allocator);
    defer self.close();
    const body: wire.Writer = .{ .allocator = allocator };
    var encoded = try wire.encode(allocator, .method_call, 0, 7, .{ .sender = ":1.42", .path = "/test", .member = "Begin" }, &body);
    defer encoded.deinit();
    var request = try wire.decode(encoded.bytes.items);
    var reply = try self.deferReply(request);
    defer self.releaseDeferred(&reply);
    var other: Connection = .{ .allocator = allocator, .fd = -1 };
    try std.testing.expectError(error.InvalidRequest, other.replyDeferred(&reply, "", &body));
    try self.replyErrorDeferred(&reply, "org.test.Cancelled", "cancelled");
    var response = try wire.decode(self.write_buf.items);
    try std.testing.expectEqual(wire.Kind.error_reply, response.kind);
    try std.testing.expectEqual(7, response.headers.reply_serial.?);
    try std.testing.expectEqualStrings(":1.42", response.headers.destination.?);
    try std.testing.expectEqualStrings("org.test.Cancelled", response.headers.error_name.?);
    try std.testing.expectEqualStrings("cancelled", try response.body.string());
    self.write_buf.clearRetainingCapacity();
    request.flags = wire.flag_no_reply_expected;
    reply = try self.deferReply(request);
    try self.replyDeferred(&reply, "", &body);
    reply = try self.deferReply(request);
    try self.replyErrorDeferred(&reply, "org.test.Cancelled", "cancelled");
    try std.testing.expectEqual(0, self.write_buf.items.len);
    request.flags = 0;
    reply = try self.deferReply(request);
    self.close();
    try std.testing.expectError(error.Disconnected, self.replyDeferred(&reply, "", &body));
    try std.testing.expectError(error.Disconnected, self.replyErrorDeferred(&reply, "org.test.Cancelled", "cancelled"));
    try std.testing.expectError(error.Disconnected, self.deferReply(request));
    self.releaseDeferred(&reply);
    self.releaseDeferred(&reply);
    try std.testing.expectEqual(0, self.write_buf.items.len);
}

test "signal match rule formatting" {
    var buf: [256]u8 = undefined;
    const dummy_fn = struct {
        fn cb(_: ?*anyopaque, _: *Connection, _: wire.Message) !void {}
    }.cb;

    // All empty/null
    const rule1 = try Connection.formatMatchRule(&buf, .{ .callback = dummy_fn });
    try std.testing.expectEqualStrings("type='signal'", rule1);

    // Member and interface
    const rule2 = try Connection.formatMatchRule(&buf, .{
        .interface = "org.rediwm.Test",
        .member = "Changed",
        .callback = dummy_fn,
    });
    try std.testing.expectEqualStrings("type='signal',interface='org.rediwm.Test',member='Changed'", rule2);

    // Sender, path, interface, member
    const rule3 = try Connection.formatMatchRule(&buf, .{
        .sender = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "NameOwnerChanged",
        .callback = dummy_fn,
    });
    try std.testing.expectEqualStrings("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',path='/org/freedesktop/DBus'", rule3);
}

test "addMatch and removeMatch encode correct method calls" {
    var self: Connection = .{ .allocator = std.testing.allocator, .fd = -1 };
    defer {
        self.pending.deinit(self.allocator);
        self.write_buf.deinit(self.allocator);
        self.signals.deinit(self.allocator);
    }
    // Calling before hello must fail
    try std.testing.expectError(error.NotRegistered, self.addMatch("type='signal'", null, null));

    self.unique_name = ":1.42";
    defer self.unique_name = null;

    // Fire-and-forget addMatch (callback = null)
    const serial1 = try self.addMatch("type='signal',member='Changed'", null, null);
    try std.testing.expectEqual(1, serial1);
    try std.testing.expectEqual(0, self.pending.items.len);

    var msg1 = try wire.decode(self.write_buf.items);
    try std.testing.expectEqual(wire.Kind.method_call, msg1.kind);
    try std.testing.expectEqual(1, msg1.flags & 1); // NO_REPLY_EXPECTED
    try std.testing.expectEqualStrings("org.freedesktop.DBus", msg1.headers.destination.?);
    try std.testing.expectEqualStrings("/org/freedesktop/DBus", msg1.headers.path.?);
    try std.testing.expectEqualStrings("org.freedesktop.DBus", msg1.headers.interface.?);
    try std.testing.expectEqualStrings("AddMatch", msg1.headers.member.?);
    try std.testing.expectEqualStrings("s", msg1.headers.signature);
    try std.testing.expectEqualStrings("type='signal',member='Changed'", try msg1.body.string());

    // removeMatch with callback
    self.write_buf.clearRetainingCapacity();
    const dummy_cb = struct {
        fn cb(_: ?*anyopaque, _: *Connection, _: Connection.Failure!wire.Message) void {}
    }.cb;
    const serial2 = try self.removeMatch("type='signal',member='Changed'", null, dummy_cb);
    try std.testing.expectEqual(2, serial2);
    try std.testing.expectEqual(1, self.pending.items.len);

    var msg2 = try wire.decode(self.write_buf.items);
    try std.testing.expectEqual(wire.Kind.method_call, msg2.kind);
    try std.testing.expectEqual(0, msg2.flags & 1); // reply expected
    try std.testing.expectEqualStrings("RemoveMatch", msg2.headers.member.?);
    try std.testing.expectEqualStrings("s", msg2.headers.signature);
    try std.testing.expectEqualStrings("type='signal',member='Changed'", try msg2.body.string());
}

test "signal handler registration, duplicate prevention, and unregistration" {
    var self: Connection = .{ .allocator = std.testing.allocator, .fd = -1 };
    defer self.signals.deinit(self.allocator);

    const dummy_fn = struct {
        fn cb(_: ?*anyopaque, _: *Connection, _: wire.Message) !void {}
    }.cb;
    const dummy_fn2 = struct {
        fn cb(_: ?*anyopaque, _: *Connection, _: wire.Message) !void {}
    }.cb;

    var owner1: u32 = 1;
    var owner2: u32 = 2;

    const h1: Connection.SignalHandler = .{
        .interface = "org.example.Test",
        .member = "Changed",
        .owner = &owner1,
        .callback = dummy_fn,
    };
    try self.registerSignal(h1);
    // Duplicate handler fails
    try std.testing.expectError(error.DuplicateHandler, self.registerSignal(h1));

    // Same interface/member with different owner succeeds
    const h2: Connection.SignalHandler = .{
        .interface = "org.example.Test",
        .member = "Changed",
        .owner = &owner2,
        .callback = dummy_fn,
    };
    try self.registerSignal(h2);

    // Same interface/member with different callback succeeds
    const h3: Connection.SignalHandler = .{
        .interface = "org.example.Test",
        .member = "Changed",
        .owner = &owner1,
        .callback = dummy_fn2,
    };
    try self.registerSignal(h3);

    try std.testing.expectEqual(3, self.signals.items.len);

    // Unregister single handler
    try std.testing.expect(self.unregisterSignal(h1));
    try std.testing.expect(!self.unregisterSignal(h1));
    try std.testing.expectEqual(2, self.signals.items.len);

    // Unregister by owner removes h3 (owner1) leaving h2 (owner2)
    self.unregisterSignalsByOwner(&owner1);
    try std.testing.expectEqual(1, self.signals.items.len);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&owner2)), self.signals.items[0].owner);

    self.unregisterSignalsByOwner(&owner2);
    try std.testing.expectEqual(0, self.signals.items.len);
}

test "incoming signal dispatch with filter matching and body delivery" {
    var self: Connection = .{ .allocator = std.testing.allocator, .fd = -1 };
    defer self.signals.deinit(self.allocator);

    const SignalState = struct {
        c_wildcard: usize = 0,
        c_path: usize = 0,
        c_member: usize = 0,
        c_sender: usize = 0,
        received_string: ?[]const u8 = null,

        fn onWildcard(owner: ?*anyopaque, _: *Connection, _: wire.Message) !void {
            const st: *@This() = @ptrCast(@alignCast(owner.?));
            st.c_wildcard += 1;
        }
        fn onPath(owner: ?*anyopaque, _: *Connection, _: wire.Message) !void {
            const st: *@This() = @ptrCast(@alignCast(owner.?));
            st.c_path += 1;
        }
        fn onMember(owner: ?*anyopaque, _: *Connection, msg: wire.Message) !void {
            const st: *@This() = @ptrCast(@alignCast(owner.?));
            st.c_member += 1;
            var b = msg.body;
            st.received_string = try b.string();
        }
        fn onSender(owner: ?*anyopaque, _: *Connection, _: wire.Message) !void {
            const st: *@This() = @ptrCast(@alignCast(owner.?));
            st.c_sender += 1;
        }
    };
    var state: SignalState = .{};

    try self.registerSignal(.{ .owner = &state, .callback = SignalState.onWildcard });
    try self.registerSignal(.{ .path = "/org/example/Special", .owner = &state, .callback = SignalState.onPath });
    try self.registerSignal(.{ .interface = "org.example.Iface", .member = "Alert", .owner = &state, .callback = SignalState.onMember });
    try self.registerSignal(.{ .sender = ":1.100", .owner = &state, .callback = SignalState.onSender });

    var body: wire.Writer = .{ .allocator = std.testing.allocator };
    defer body.deinit();
    try body.string("alert payload");

    // Signal 1: path=/org/example/General, iface=org.example.Iface, member=Alert, sender=:1.50
    var enc1 = try wire.encode(std.testing.allocator, .signal, 0, 1, .{
        .path = "/org/example/General",
        .interface = "org.example.Iface",
        .member = "Alert",
        .sender = ":1.50",
        .signature = "s",
    }, &body);
    defer enc1.deinit();

    try self.dispatch(try wire.decode(enc1.bytes.items));
    try std.testing.expectEqual(1, state.c_wildcard);
    try std.testing.expectEqual(0, state.c_path);
    try std.testing.expectEqual(1, state.c_member);
    try std.testing.expectEqualStrings("alert payload", state.received_string.?);
    try std.testing.expectEqual(0, state.c_sender);

    // Signal 2: path=/org/example/Special, iface=org.other.Iface, member=Ping, sender=:1.100
    var body2: wire.Writer = .{ .allocator = std.testing.allocator };
    defer body2.deinit();
    var enc2 = try wire.encode(std.testing.allocator, .signal, 0, 2, .{
        .path = "/org/example/Special",
        .interface = "org.other.Iface",
        .member = "Ping",
        .sender = ":1.100",
    }, &body2);
    defer enc2.deinit();

    try self.dispatch(try wire.decode(enc2.bytes.items));
    try std.testing.expectEqual(2, state.c_wildcard);
    try std.testing.expectEqual(1, state.c_path);
    try std.testing.expectEqual(1, state.c_member);
    try std.testing.expectEqual(1, state.c_sender);
}

test "signal handler self-unregistration during dispatch" {
    var self: Connection = .{ .allocator = std.testing.allocator, .fd = -1 };
    defer self.signals.deinit(self.allocator);

    const SelfUnsub = struct {
        calls1: usize = 0,
        calls2: usize = 0,
        self_conn: *Connection,

        fn onFirst(owner: ?*anyopaque, conn: *Connection, _: wire.Message) !void {
            const st: *@This() = @ptrCast(@alignCast(owner.?));
            st.calls1 += 1;
            // Unregister self during callback
            _ = conn.unregisterSignal(.{
                .member = "Test",
                .owner = owner,
                .callback = onFirst,
            });
        }
        fn onSecond(owner: ?*anyopaque, _: *Connection, _: wire.Message) !void {
            const st: *@This() = @ptrCast(@alignCast(owner.?));
            st.calls2 += 1;
        }
    };
    var test_ctx: SelfUnsub = .{ .self_conn = &self };

    try self.registerSignal(.{ .member = "Test", .owner = &test_ctx, .callback = SelfUnsub.onFirst });
    try self.registerSignal(.{ .member = "Test", .owner = &test_ctx, .callback = SelfUnsub.onSecond });

    var body: wire.Writer = .{ .allocator = std.testing.allocator };
    defer body.deinit();
    var enc = try wire.encode(std.testing.allocator, .signal, 0, 1, .{
        .path = "/test",
        .interface = "org.test",
        .member = "Test",
    }, &body);
    defer enc.deinit();

    // First dispatch: both handlers should run, even though the first unsubscribed itself
    try self.dispatch(try wire.decode(enc.bytes.items));
    try std.testing.expectEqual(1, test_ctx.calls1);
    try std.testing.expectEqual(1, test_ctx.calls2);

    // Second dispatch: only second handler should run
    try self.dispatch(try wire.decode(enc.bytes.items));
    try std.testing.expectEqual(1, test_ctx.calls1);
    try std.testing.expectEqual(2, test_ctx.calls2);
}

test "received FDs are frame scoped, cloexec, validated and closed after dispatch" {
    const a = std.testing.allocator;
    const reply = [_]u8{
        'l', 2, 0,   1, 4, 0,   0, 0, 1, 0, 0,   0, 23, 0, 0, 0,
        5,   1, 'u', 0, 1, 0,   0, 0, 9, 1, 'u', 0, 1,  0, 0, 0,
        8,   1, 'g', 0, 1, 'h', 0, 0, 0, 0, 0,   0,
    };
    const Owner = struct {
        received: ?c_int = null,
        fn callback(owner: ?*anyopaque, _: *Connection, result: Connection.Failure!wire.Message) void {
            const self: *@This() = @ptrCast(@alignCast(owner.?));
            var msg = result catch unreachable;
            self.received = msg.body.unixFd() catch unreachable;
            std.debug.assert(c.fcntl(self.received.?, std.posix.F.GETFD) & std.posix.FD_CLOEXEC != 0);
        }
    };
    // Also verify early disconnect and invalid descriptor indexes clean up.
    for (0..3) |scenario| {
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(0, c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0, &sockets));
        defer _ = c.close(sockets[1]);
        const conn = try a.create(Connection);
        conn.* = .{ .allocator = a, .fd = sockets[0], .receive_fds = true };
        defer conn.destroy();
        var owner: Owner = .{};
        try conn.pending.append(a, .{ .serial = 1, .deadline = 0, .owner = &owner, .callback = Owner.callback });
        var bytes = reply;
        if (scenario == 2) bytes[40] = 1;
        var iov: std.posix.iovec_const = .{ .base = &bytes, .len = bytes.len };
        var control: [std.mem.alignForward(usize, @sizeOf(c.cmsghdr) + @sizeOf(c_int), @sizeOf(usize))]u8 align(@alignOf(c.cmsghdr)) = @splat(0);
        const header: *c.cmsghdr = @ptrCast(&control);
        header.* = .{ .len = @sizeOf(c.cmsghdr) + @sizeOf(c_int), .level = std.posix.SOL.SOCKET, .type = c.SCM.RIGHTS };
        @as(*c_int, @ptrCast(@alignCast(&control[@sizeOf(c.cmsghdr)]))).* = sockets[1];
        var message: c.msghdr_const = std.mem.zeroes(c.msghdr_const);
        message.iov = @ptrCast(&iov);
        message.iovlen = 1;
        message.control = &control;
        message.controllen = control.len;
        try std.testing.expectEqual(@as(isize, bytes.len), c.sendmsg(sockets[1], &message, std.posix.MSG.NOSIGNAL));
        try conn.read(); // fixed header only, with ancillary data
        try std.testing.expectEqual(1, conn.read_fd_count);
        const borrowed = conn.read_fds[0];
        if (scenario == 0) {
            try conn.read();
            try std.testing.expectEqual(borrowed, owner.received.?);
        } else {
            if (scenario == 2) try std.testing.expectError(error.InvalidMessage, conn.read());
            // Pending callbacks cannot consume descriptors from invalid frames.
            conn.pending.clearRetainingCapacity();
            conn.close();
        }
        try std.testing.expectEqual(0, conn.read_fd_count);
        try std.testing.expectEqual(-1, c.fcntl(borrowed, std.posix.F.GETFD));
        try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(@as(c_int, -1)));
    }
}
