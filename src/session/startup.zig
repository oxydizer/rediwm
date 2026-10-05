//! Gate session clients on publication and the first desktop frame. All
//! waiting uses the Wayland loop so startup never stalls input or rendering.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("../Server.zig");
const activation = @import("activation.zig");
const startup = @import("../startup.zig");
const gpa = @import("../main.zig").gpa;

const Startup = @This();
server: ?*Server = null,
readiness: activation.Readiness = .{},
timer: ?*wl.EventSource = null,
acknowledged: bool = false,
presented: bool = false,
launched: bool = false,
failure: ?anyerror = null,

pub fn start(self: *Startup, server: *Server) !void {
    self.server = server;
    var env = try server.environ.createMap(gpa);
    defer env.deinit();
    try server.applyChildEnv(&env);
    try self.readiness.start(gpa, server.io, server.environ, &env, server.wl_server.getEventLoop(), self, onReady);
}

pub fn deinit(self: *Startup) void {
    self.readiness.deinit();
    if (self.timer) |timer| timer.remove();
    self.timer = null;
}

pub fn onPresented(self: *Startup) void {
    self.presented = true;
    self.schedule();
}

fn onReady(owner: *anyopaque, result: activation.Readiness.Failure!void) void {
    const self: *Startup = @ptrCast(@alignCast(owner));
    result catch |err| {
        self.fail(err);
        return;
    };
    self.acknowledged = true;
    startup.markSessionReady();
    if (self.server) |server| if (server.restart_requested) {
        server.wl_server.terminate();
        return;
    };
    self.schedule();
}

fn schedule(self: *Startup) void {
    const server = self.server orelse return;
    if (!self.acknowledged or self.launched or self.timer != null or server.greeter_mode or server.shutting_down) return;
    // A session with no outputs must still be able to launch its clients.
    if (!self.presented and server.outputs.length() != 0) return;
    self.timer = server.wl_server.getEventLoop().addTimer(*Startup, launch, self) catch |err| {
        self.fail(err);
        return;
    };
    self.timer.?.timerUpdate(1) catch |err| self.fail(err);
}

fn launch(self: *Startup) c_int {
    if (self.timer) |timer| timer.remove();
    self.timer = null;
    const server = self.server orelse return 0;
    if (server.shutting_down or server.restart_requested) return 0;
    self.launched = true;
    self.launchCommand(server) catch |err| {
        self.fail(err);
        return 0;
    };
    server.spawnAutostart();
    startup.markSessionClientsStarted();
    return 0;
}

fn launchCommand(_: *Startup, server: *Server) !void {
    if (server.argv.len < 2) return;
    var env = try server.environ.createMap(gpa);
    defer env.deinit();
    try server.applyChildEnv(&env);
    const child = try std.process.spawn(server.io, .{
        .argv = &.{ "/bin/sh", "-c", std.mem.span(server.argv[1]) },
        .environ_map = &env,
    });
    if (child.id) |pid| {
        const app_scope = @import("app_scope.zig");
        app_scope.place(server, pid, app_scope.commandId(std.mem.span(server.argv[1])));
        if (server.services) |services| services.trackChild(pid) catch {};
    }
}

fn fail(self: *Startup, err: anyerror) void {
    self.failure = err;
    self.deinit();
    if (self.server) |server| server.terminate();
}
