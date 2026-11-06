//! Show the desktop before enumerating native input and starting optional
//! services. Backends remain owned by wlroots' multi-backend throughout.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Server = @import("Server.zig");
const startup = @import("startup.zig");

const Tasks = @This();
server: ?*Server = null,
timer: ?*wl.EventSource = null,
input_pending: bool = false,
step: usize = 0,
complete: bool = false,
failure: ?anyerror = null,

pub fn start(self: *Tasks, server: *Server) !void {
    self.server = server;
    startup.markBackendStart();
    // Greeter and lock recovery need their input immediately. Nested and
    // headless backends already own their output and input together.
    if (server.session != null and !server.greeter_mode and server.locker == null and server.backend.isMulti()) {
        server.backend.multiForEachBackend(*Tasks, startDisplayBackend, self);
        if (self.failure) |err| return err;
    } else {
        try server.backend.start();
    }
    startup.markBackendReady();
    if (self.input_pending) server.input.holdCursor() else startup.markInputReady();
    if (server.greeter_mode) {
        self.complete = true;
        @import("session/greeter_ready.zig").check(server);
        return;
    }
    self.timer = try server.wl_server.getEventLoop().addTimer(*Tasks, tick, self);
    // A disabled/unplugged display or failed flip must not leave input or
    // services waiting indefinitely. This is a one-shot bound.
    try self.timer.?.timerUpdate(if (server.outputs.length() == 0) 1 else 250);
}

fn startDisplayBackend(backend: *wlr.Backend, self: *Tasks) void {
    self.startSelectedBackend(backend, backend.isLibinput(), false);
}

fn startInputBackend(backend: *wlr.Backend, self: *Tasks) void {
    self.startSelectedBackend(backend, backend.isLibinput(), true);
}

fn startSelectedBackend(self: *Tasks, backend: *wlr.Backend, is_input: bool, input_stage: bool) void {
    if (self.failure != null) return;
    if (is_input != input_stage) {
        if (is_input) self.input_pending = true;
        return;
    }
    backend.start() catch |err| {
        self.failure = err;
    };
}

pub fn onVisible(self: *Tasks) void {
    // Do not re-arm between every frame or restart a completed queue.
    if (self.step != 0 or self.complete) return;
    if (self.timer) |timer| timer.timerUpdate(1) catch self.fail(error.TimerUpdateFailed);
}

pub fn onSessionActive(self: *Tasks) void {
    if (self.input_pending) self.onVisible();
}

fn tick(self: *Tasks) c_int {
    const server = self.server orelse return 0;
    if (server.shutting_down or server.restart_requested) {
        self.deinit();
        return 0;
    }
    if (self.input_pending) {
        // Device acquisition requires the active seat. A VT switch during
        // the first frame wait is resumed by handleSessionActive, not polling.
        if (server.session) |session| if (!session.active) return 0;
        self.input_pending = false;
        server.backend.multiForEachBackend(*Tasks, startInputBackend, self);
        if (self.failure) |err| {
            self.fail(err);
            return 0;
        }
        startup.markInputReady();
        server.input.releaseCursor();
    } else if (server.startDesktopService(self.step)) {
        self.step += 1;
    } else {
        self.complete = true;
        startup.markServicesStarted();
        self.deinit();
        server.session_startup.schedule();
        server.startup_warmup.schedule(server);
        return 0;
    }
    if (self.timer) |timer| timer.timerUpdate(1) catch self.fail(error.TimerUpdateFailed);
    return 0;
}

fn fail(self: *Tasks, err: anyerror) void {
    self.failure = err;
    self.deinit();
    if (self.server) |server| server.wl_server.terminate();
}

pub fn deinit(self: *Tasks) void {
    if (self.timer) |timer| timer.remove();
    self.timer = null;
}

test "staged backends retain multi ownership and only start in their own stage" {
    // Real headless backends exercise wlroots' start/ownership contracts;
    // classifying one as input avoids touching the host seat in this test.
    const loop = try wl.EventLoop.create();
    defer loop.destroy();
    const multi = try wlr.Backend.createMulti(loop);
    defer multi.destroy();
    const display = try wlr.Backend.createHeadless(loop);
    try std.testing.expect(multi.multiAdd(display));
    const input = try wlr.Backend.createHeadless(loop);
    try std.testing.expect(multi.multiAdd(input));
    _ = try display.headlessAddOutput(32, 32);
    _ = try input.headlessAddOutput(32, 32);
    const Observer = struct {
        listener: wl.Listener(*wlr.Output) = .init(newOutput),
        count: usize = 0,
        backends: usize = 0,
        fn newOutput(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
            const self: *@This() = @fieldParentPtr("listener", listener);
            self.count += 1;
        }
        fn countBackend(backend: *wlr.Backend, self: *@This()) void {
            if (backend.isHeadless()) self.backends += 1;
        }
    };
    var observer: Observer = .{};
    multi.multiForEachBackend(*Observer, Observer.countBackend, &observer);
    try std.testing.expectEqual(@as(usize, 2), observer.backends);
    try std.testing.expect(!multi.hasDrm());
    multi.events.new_output.add(&observer.listener);
    defer observer.listener.link.remove();
    var tasks: Tasks = .{};
    tasks.startSelectedBackend(input, true, false);
    try std.testing.expect(tasks.input_pending);
    try std.testing.expectEqual(@as(usize, 0), observer.count);
    tasks.startSelectedBackend(display, false, false);
    try std.testing.expectEqual(@as(usize, 1), observer.count);
    tasks.startSelectedBackend(display, false, true);
    try std.testing.expectEqual(@as(usize, 1), observer.count);
    tasks.startSelectedBackend(input, true, true);
    try std.testing.expectEqual(@as(usize, 2), observer.count);
    try std.testing.expect(tasks.failure == null);
}
