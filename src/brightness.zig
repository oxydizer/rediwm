// A single nonblocking helper at a time. Repeats accumulate while it runs;
// output is bounded, and only a successful machine-readable result is shown.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Child = @import("session/child.zig");
const Server = @import("Server.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("fcntl.h");
});
const Brightness = @This();
child: ?std.process.Child = null,
timer: ?*wl.EventSource = null,
source: ?*wl.EventSource = null,
watch: ?*Child = null,
pending: i32 = 0,
bytes: [1024]u8 = undefined,
len: usize = 0,
failed: bool = false,
level: ?f32 = null,
pending_level: ?f32 = null,
query_pending: bool = false,
querying: bool = false,
show_osd: bool = false,

pub fn query(self: *Brightness, server: *Server) void {
    self.query_pending = true;
    if (self.child == null) self.start(server) catch self.unavailable(server);
}

pub fn set(self: *Brightness, server: *Server, level: f32) void {
    self.pending_level = std.math.clamp(level, 0.01, 1);
    self.pending = 0;
    if (self.child == null) self.start(server) catch self.unavailable(server);
}

fn unavailable(self: *Brightness, server: *Server) void {
    self.pending = 0;
    self.pending_level = null;
    self.query_pending = false;
    self.level = null;
    self.failed = true;
    if (server.input.open_control_center) |cc| cc.refresh();
    if (server.locker) |lock| lock.controlsChanged();
}

pub fn adjust(self: *Brightness, server: *Server, steps: i32) void {
    if (self.pending_level) |level| {
        self.pending_level = std.math.clamp(level + @as(f32, @floatFromInt(steps)) * 0.05, 0.01, 1);
    } else self.pending = std.math.clamp(self.pending + steps, -20, 20);
    if (self.child == null) self.start(server) catch |err| {
        self.pending = 0;
        std.log.warn("brightnessctl: {}", .{err});
    };
}

fn start(self: *Brightness, server: *Server) !void {
    if (self.pending == 0 and self.pending_level == null and !self.query_pending) return;
    if (self.timer == null) self.timer = try server.wl_server.getEventLoop().addTimer(*Server, timeout, server);
    var value_buf: [16]u8 = undefined;
    self.querying = self.pending == 0 and self.pending_level == null;
    self.show_osd = !self.querying and self.pending_level == null;
    const value = if (self.pending_level) |level|
        try std.fmt.bufPrint(&value_buf, "{d}%", .{@as(u32, @intFromFloat(@round(level * 100)))})
    else
        try std.fmt.bufPrint(&value_buf, "{d}%{s}", .{ @abs(self.pending) * 5, if (self.pending > 0) "+" else "-" });
    self.pending = 0;
    self.pending_level = null;
    self.query_pending = false;
    const args: []const []const u8 = if (self.querying)
        &.{ "brightnessctl", "--class=backlight", "--machine-readable", "info" }
    else
        &.{ "brightnessctl", "--class=backlight", "--machine-readable", "--min-value=1", "set", value };
    var child = try std.process.spawn(server.io, .{ .argv = args, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    errdefer child.kill(server.io);
    if (c.fcntl(child.stdout.?.handle, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
    self.source = try server.wl_server.getEventLoop().addFd(*Server, child.stdout.?.handle, .{ .readable = true }, readable, server);
    errdefer {
        self.source.?.remove();
        self.source = null;
    }
    try self.timer.?.timerUpdate(2000);
    errdefer self.timer.?.timerUpdate(0) catch {};
    self.watch = try Child.watch(@import("main.zig").gpa, server.wl_server.getEventLoop(), child.id.?, server, exited);
    self.child = child;
    self.len = 0;
    self.failed = false;
}

fn drain(server: *Server) void {
    const self = &server.brightness;
    const child = if (self.child) |*child| child else return;
    while (true) {
        var scratch: [1024]u8 = undefined;
        const n = std.c.read(child.stdout.?.handle, &scratch, scratch.len);
        if (n <= 0) break;
        const count: usize = @intCast(n);
        if (count <= self.bytes.len - self.len) {
            @memcpy(self.bytes[self.len..][0..count], scratch[0..count]);
            self.len += count;
        } else self.failed = true;
        // Bound event-loop work even if a broken helper writes forever.
        if (self.failed) break;
    }
    if (self.failed) self.watch.?.signal(.KILL);
}

fn readable(_: c_int, mask: wl.EventMask, server: *Server) c_int {
    drain(server);
    if (mask.hangup or mask.@"error" or server.brightness.failed) {
        if (server.brightness.source) |source| source.remove();
        server.brightness.source = null;
    }
    return 0;
}

fn timeout(server: *Server) c_int {
    if (server.brightness.watch) |watch| {
        server.brightness.failed = true;
        watch.signal(.KILL);
    }
    return 0;
}

fn exited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
    const server: *Server = @ptrCast(@alignCast(owner.?));
    const self = &server.brightness;
    // Nonblocking even when a descendant retained stdout.
    drain(server);
    self.watch = null;
    self.timer.?.timerUpdate(0) catch {};
    if (self.source) |source| source.remove();
    self.source = null;
    const child = &self.child.?;
    child.stdout.?.close(server.io);
    self.child = null;
    if (status != null and status.? == 0 and !self.failed) {
        if (parseLevel(self.bytes[0..self.len])) |level| {
            self.level = level;
            if (self.show_osd) @import("osd.zig").show(server, .{ .kind = .brightness, .level = level });
        } else self.failed = true;
    } else self.failed = true;
    if (server.input.open_control_center) |cc| cc.refresh();
    if (self.failed) {
        self.unavailable(server);
        std.log.warn("brightnessctl failed or returned no backlight state", .{});
    }
    if (server.locker) |lock| lock.controlsChanged();
    self.start(server) catch |err| {
        self.unavailable(server);
        std.log.warn("brightnessctl: {}", .{err});
    };
}

pub fn deinit(self: *Brightness, server: *Server) void {
    if (self.timer) |timer| timer.remove();
    if (self.source) |source| source.remove();
    if (self.watch) |watch| {
        watch.signal(.KILL);
        watch.detach();
    }
    if (self.child) |child| child.stdout.?.close(server.io);
    self.* = .{};
}

pub fn parseLevel(bytes: []const u8) ?f32 {
    var fields = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, " \r\n"), ',');
    _ = fields.next() orelse return null;
    if (!std.mem.eql(u8, fields.next() orelse return null, "backlight")) return null;
    const current = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    _ = fields.next() orelse return null;
    const max = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    if (max == 0 or current > max or fields.next() != null) return null;
    return @as(f32, @floatFromInt(current)) / @as(f32, @floatFromInt(max));
}

test "brightness result uses actual values and rejects invalid or ambiguous devices" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), parseLevel("intel,backlight,700,70%,1000\n").?, 0.0001);
    for ([_][]const u8{ "", "dev,leds,1,1%,100", "dev,backlight,1,0%,0", "dev,backlight,101,100%,100", "a,backlight,1,1%,100\nb,backlight,1,1%,100" }) |bad| try std.testing.expectEqual(null, parseLevel(bad));
}
