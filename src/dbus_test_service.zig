//! Test-only service, built by test-dbus; never installed with the compositor.
const std = @import("std");
const wl = @import("wayland").server.wl;
const dbus = @import("dbus");
const activation = @import("session/activation.zig");
const C = dbus.Connection;
const wire = dbus.wire;
const path = "/org/rediwm/Test";
const interface = "org.rediwm.Test";
var failed = false;
var stop = false;
var ready = false;
var callbacks: usize = 0;
var signal_count: usize = 0;
const Delayed = struct {
    conn: *C,
    reply: ?C.Deferred = null,
    timer: ?*wl.EventSource = null,
    fail: bool = false,

    fn fire(self: *Delayed) c_int {
        if (self.reply) |*reply| {
            defer self.conn.releaseDeferred(reply);
            if (self.fail) {
                self.conn.replyErrorDeferred(reply, "org.rediwm.Test.Failed", "delayed failure") catch {
                    failed = true;
                };
            } else {
                const body: wire.Writer = .{ .allocator = std.heap.c_allocator };
                self.conn.replyDeferred(reply, "", &body) catch {
                    failed = true;
                };
            }
        }
        self.reply = null;
        return 0;
    }
    fn method(owner: ?*anyopaque, conn: *C, request: wire.Message) !void {
        const self: *Delayed = @ptrCast(@alignCast(owner.?));
        if (self.reply != null) return error.Busy;
        self.reply = try conn.deferReply(request);
        errdefer {
            conn.releaseDeferred(&self.reply.?);
            self.reply = null;
        }
        self.fail = std.mem.eql(u8, request.headers.member.?, "DelayedFail");
        try self.timer.?.timerUpdate(1000);
    }
};
pub fn main(init: std.process.Init) !void {
    const display = try wl.Server.create();
    defer display.destroy();
    const args = init.minimal.args.vector;
    if (args.len > 1 and std.mem.eql(u8, std.mem.span(args[1]), "--activation-env")) {
        // The compositor's login-only publish, pointed at the private bus.
        return activation.publishActivationEnv(display.getEventLoop(), std.heap.c_allocator, init.minimal.environ, &.{
            .{ .name = "REDIWM_TEST_ACTIVATION", .value = "one" },
            .{ .name = "WAYLAND_DISPLAY", .value = "wayland-test" },
        });
    }
    const system = args.len > 1 and std.mem.eql(u8, std.mem.span(args[1]), "--system");
    const conn = if (system) try C.openSystem(std.heap.c_allocator, display.getEventLoop(), init.minimal.environ) else try C.openSession(std.heap.c_allocator, display.getEventLoop(), init.minimal.environ);
    defer conn.destroy();
    var delayed: Delayed = .{ .conn = conn };
    delayed.timer = try display.getEventLoop().addTimer(*Delayed, Delayed.fire, &delayed);
    defer {
        delayed.timer.?.remove();
        if (delayed.reply) |*reply| conn.releaseDeferred(reply);
    }
    inline for (.{ "Delayed", "DelayedFail" }) |member| try conn.register(.{ .path = path, .interface = interface, .member = member, .owner = &delayed, .callback = Delayed.method });
    inline for (.{ "Echo", "Fail", "Emit", "Hang", "Quit", "Stats", "Signals", "Unsub" }) |member| try conn.register(.{ .path = path, .interface = interface, .member = member, .callback = method });
    _ = try conn.hello(null, hello);
    var ticks: usize = 0;
    while (!stop and !failed and !conn.closed and ticks < 600) : (ticks += 1) try display.getEventLoop().dispatch(100);
    if (failed or !ready or ticks == 600) return error.TestFailed;
}
fn hello(_: ?*anyopaque, conn: *C, result: C.Failure!wire.Message) void {
    _ = result catch {
        failed = true;
        return;
    };
    _ = conn.requestName(interface, 4, null, named) catch {
        failed = true;
    };
}
fn named(_: ?*anyopaque, conn: *C, result: C.Failure!wire.Message) void {
    var msg = result catch {
        failed = true;
        return;
    };
    if (msg.kind != .method_return or (msg.body.uint32() catch 0) != 1) {
        failed = true;
        return;
    }
    ready = true;
    const body: wire.Writer = .{ .allocator = std.heap.c_allocator };
    _ = conn.subscribe(.{
        .interface = interface,
        .member = "Changed",
        .callback = onSignal,
    }, null, null) catch {
        failed = true;
    };
    // Real external service call and a timed-out call to our own service.
    _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", "", &body, null, listed, 5000) catch {
        failed = true;
    };
    _ = conn.call(interface, path, interface, "Hang", "", &body, null, timedOut, 100) catch {
        failed = true;
    };
}
fn onSignal(_: ?*anyopaque, _: *C, msg: wire.Message) !void {
    if (!std.mem.eql(u8, msg.headers.signature, "s")) return error.BadSignature;
    var r = msg.body;
    const val = try r.string();
    if (std.mem.eql(u8, val, "changed")) {
        signal_count += 1;
    }
}
fn listed(_: ?*anyopaque, _: *C, result: C.Failure!wire.Message) void {
    const msg = result catch {
        failed = true;
        return;
    };
    if (msg.kind != .method_return or !std.mem.eql(u8, msg.headers.signature, "as")) failed = true;
    callbacks += 1;
}
fn timedOut(_: ?*anyopaque, _: *C, result: C.Failure!wire.Message) void {
    if (result) |_| {
        failed = true;
    } else |err| {
        if (err != error.Timeout) failed = true;
    }
    callbacks += 1;
}
fn method(_: ?*anyopaque, conn: *C, request: wire.Message) !void {
    const member = request.headers.member.?;
    var body: wire.Writer = .{ .allocator = std.heap.c_allocator };
    defer body.deinit();
    if (std.mem.eql(u8, member, "Echo")) {
        if (!std.mem.eql(u8, request.headers.signature, "s")) return error.BadSignature;
        var r = request.body;
        try body.string(try r.string());
        try conn.reply(request, "s", &body);
    } else if (std.mem.eql(u8, member, "Fail")) {
        try conn.replyError(request, "org.rediwm.Test.Failed", "expected failure");
    } else if (std.mem.eql(u8, member, "Emit")) {
        try body.string("changed");
        try conn.signal(path, interface, "Changed", "s", &body);
        body.bytes.clearRetainingCapacity();
        try conn.reply(request, "", &body);
    } else if (std.mem.eql(u8, member, "Stats")) {
        try body.uint32(@intCast(callbacks));
        try conn.reply(request, "u", &body);
    } else if (std.mem.eql(u8, member, "Signals")) {
        try body.uint32(@intCast(signal_count));
        try conn.reply(request, "u", &body);
    } else if (std.mem.eql(u8, member, "Unsub")) {
        _ = try conn.unsubscribe(.{
            .interface = interface,
            .member = "Changed",
            .callback = onSignal,
        }, null, null);
        try conn.reply(request, "", &body);
    } else if (std.mem.eql(u8, member, "Quit")) {
        stop = true;
    }
}
