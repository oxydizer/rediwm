const std = @import("std");
const wl = @import("wayland").server.wl;
const c = std.posix.system;
const wire = @import("wire.zig");
const connection = @import("connection.zig");
const io = @import("connection_io.zig");
const Connection = connection.Connection;

pub const TestResult = struct {
    count: usize = 0,
    failure: ?Connection.Failure = null,
    pub fn callback(owner: ?*anyopaque, _: *Connection, result: Connection.Failure!wire.Message) void {
        const self: *TestResult = @ptrCast(@alignCast(owner.?));
        self.count += 1;
        if (result) |_| {} else |err| {
            self.failure = err;
        }
    }
};

pub fn allocationLifecycle(allocator: std.mem.Allocator) !void {
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

pub fn deferredLifecycle(allocator: std.mem.Allocator) !void {
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
        var control: [std.mem.alignForward(usize, io.cmsg_data + @sizeOf(c_int), @sizeOf(usize))]u8 align(@alignOf(c.cmsghdr)) = @splat(0);
        const header: *c.cmsghdr = @ptrCast(&control);
        header.* = .{ .len = io.cmsg_data + @sizeOf(c_int), .level = std.posix.SOL.SOCKET, .type = c.SCM.RIGHTS };
        @as(*c_int, @ptrCast(@alignCast(&control[io.cmsg_data]))).* = sockets[1];
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
