//! Each launched application gets its own transient systemd scope,
//! `app-rediwm-<id>-<pid>.scope` in the user manager's app.slice, as GNOME
//! and KDE do (systemd.io/DESKTOP_ENVIRONMENTS). Otherwise apps share the
//! compositor's session scope, and systemd-oomd, which kills whole cgroups,
//! would take the session with a runaway browser.
//!
//! The process is moved after it is spawned, so anything it forks before the
//! user manager answers (about a millisecond) stays behind, as with GNOME.
//! Best effort: without a session bus or a systemd user manager launches stay
//! where they are. Nested sessions skip it so tests never create units on the
//! host; REDIWM_APP_SCOPES=1 forces it on, 0 off. The connection opens on the
//! first launch and makes no calls while idle.
const std = @import("std");

const dbus = @import("dbus");
const wire = dbus.wire;
const wl = @import("wayland").server.wl;
const Server = @import("../Server.zig");
const activation = @import("activation.zig");

const log = std.log.scoped(.app_scope);

const systemd = "org.freedesktop.systemd1";
const call_timeout_ms: u32 = 5000;
/// Launches waiting for Hello; more than this in one burst stay unscoped.
const max_queued = 32;
const prefix = "app-rediwm-";
const suffix = ".scope";
const max_unit = 255;

pub fn enabled(environ: std.process.Environ) bool {
    const flag = environ.getPosix("REDIWM_APP_SCOPES");
    if (activation.isTruthy(flag)) return true;
    if (activation.isFalsy(flag)) return false;
    return !activation.isNested(activation.viewFromEnviron(environ));
}

/// Moves `pid` into a scope named after `app_id` (a desktop id without
/// `.desktop`, or a command name).
pub fn place(server: *Server, pid: i32, app_id: []const u8) void {
    if (server.app_scopes) |scopes| scopes.place(pid, app_id);
}

/// The scope name for a shell command line: its first word's basename.
pub fn commandId(cmd: []const u8) []const u8 {
    var words = std.mem.tokenizeAny(u8, cmd, " \t\n");
    return std.fs.path.basename(words.next() orelse "");
}

const Unit = struct {
    pid: i32,
    buf: [max_unit]u8 = undefined,
    len: usize = 0,

    fn name(self: *const Unit) []const u8 {
        return self.buf[0..self.len];
    }
};

/// `app-rediwm-<escaped id>-<pid>.scope`. Like systemd-escape, bytes outside
/// `[A-Za-z0-9:_.]` become `\xNN` (`-` separates the name's fields); the id
/// is cut short rather than exceed the unit name limit.
fn unitName(pid: i32, app_id: []const u8) Unit {
    var unit: Unit = .{ .pid = pid };
    var tail_buf: [32]u8 = undefined;
    const tail = std.fmt.bufPrint(&tail_buf, "-{d}" ++ suffix, .{pid}) catch unreachable;
    var w: std.Io.Writer = .fixed(&unit.buf);
    w.writeAll(prefix) catch unreachable;
    const id = if (app_id.len > 0) app_id else "app";
    for (id) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or ch == ':' or ch == '_' or ch == '.';
        const width: usize = if (plain) 1 else 4;
        if (w.end + width + tail.len > max_unit) break;
        if (plain) w.writeByte(ch) catch unreachable else w.print("\\x{x:0>2}", .{ch}) catch unreachable;
    }
    w.writeAll(tail) catch unreachable;
    unit.len = w.end;
    return unit;
}

/// `StartTransientUnit(ssa(sv)a(sa(sv)))`: mode "fail", the pid, app.slice,
/// and collected once every process has exited, even after a failure.
fn writeStart(body: *wire.Writer, unit: []const u8, pid: i32) !void {
    try body.string(unit);
    try body.string("fail");
    const props = try body.beginArray(8);
    try body.alignTo(8);
    try body.string("Description");
    try body.variant("s");
    try body.string("Application launched by RediWM");
    try body.alignTo(8);
    try body.string("PIDs");
    try body.variant("au");
    const pids = try body.beginArray(4);
    try body.uint32(@intCast(pid));
    try body.endArray(pids);
    try body.alignTo(8);
    try body.string("Slice");
    try body.variant("s");
    try body.string("app.slice");
    try body.alignTo(8);
    try body.string("CollectMode");
    try body.variant("s");
    try body.string("inactive-or-failed");
    try body.endArray(props);
    const aux = try body.beginArray(8);
    try body.endArray(aux);
}

pub const Scopes = struct {
    allocator: std.mem.Allocator,
    loop: *wl.EventLoop,
    environ: std.process.Environ,
    conn: ?*dbus.Connection = null,
    /// Hello answered; calls go out directly.
    ready: bool = false,
    /// The bus has no systemd user manager (or it refuses): stop asking.
    unavailable: bool = false,
    closing: bool = false,
    queued: std.ArrayList(Unit) = .empty,

    pub fn create(allocator: std.mem.Allocator, loop: *wl.EventLoop, environ: std.process.Environ) !*Scopes {
        const self = try allocator.create(Scopes);
        self.* = .{ .allocator = allocator, .loop = loop, .environ = environ };
        return self;
    }

    /// Before the event loop is destroyed.
    pub fn destroy(self: *Scopes) void {
        self.closing = true;
        if (self.conn) |conn| conn.destroy();
        self.queued.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn place(self: *Scopes, pid: i32, app_id: []const u8) void {
        if (self.unavailable or pid <= 0) return;
        const unit = unitName(pid, app_id);
        if (self.ready) return self.start(unit);
        if (self.conn == null or self.conn.?.closed) self.connect() catch |err| {
            log.debug("no session bus for app scopes: {}", .{err});
            return;
        };
        if (self.queued.items.len >= max_queued) return;
        self.queued.append(self.allocator, unit) catch {};
    }

    fn connect(self: *Scopes) !void {
        if (self.conn) |old| old.destroy();
        self.conn = null;
        self.queued.clearRetainingCapacity();
        const conn = try dbus.Connection.openSession(self.allocator, self.loop, self.environ);
        errdefer conn.destroy();
        _ = try conn.hello(self, onHello);
        conn.on_disconnect = .{ .owner = self, .callback = onDisconnect };
        self.conn = conn;
    }

    fn onDisconnect(owner: ?*anyopaque) void {
        const self: *Scopes = @ptrCast(@alignCast(owner orelse return));
        self.ready = false;
    }

    fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Scopes = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const ok = if (result) |msg| msg.kind == .method_return else |_| false;
        if (!ok) {
            log.debug("session bus Hello failed; launches keep the session's cgroup", .{});
            self.queued.clearRetainingCapacity();
            return conn.close();
        }
        self.ready = true;
        for (self.queued.items) |*unit| self.start(unit.*);
        self.queued.clearRetainingCapacity();
    }

    fn start(self: *Scopes, unit: Unit) void {
        const conn = self.conn orelse return;
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        writeStart(&body, unit.name(), unit.pid) catch return;
        // No auto-start: a bus without a user manager must not try to activate one.
        _ = conn.callWithFlags(systemd, "/org/freedesktop/systemd1", systemd ++ ".Manager", "StartTransientUnit", "ssa(sv)a(sa(sv))", &body, self, onStarted, call_timeout_ms, wire.flag_no_auto_start) catch |err| {
            log.debug("could not request {s}: {}", .{ unit.name(), err });
        };
    }

    fn onStarted(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Scopes = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const msg = result catch |err| return log.debug("app scope request failed: {}", .{err});
        if (msg.kind != .error_reply) return;
        const name = msg.headers.error_name orelse "unknown error";
        if (managerMissing(name)) {
            if (!self.unavailable) log.info("no systemd user manager ({s}); launched apps share the session's cgroup", .{name});
            self.unavailable = true;
        } else log.debug("app scope refused: {s}", .{name}); // usually a process that already exited
    }
};

fn managerMissing(error_name: []const u8) bool {
    inline for (.{ "ServiceUnknown", "NameHasNoOwner", "UnknownMethod", "UnknownObject", "AccessDenied" }) |suffix_name| {
        if (std.mem.eql(u8, error_name, "org.freedesktop.DBus.Error." ++ suffix_name)) return true;
    }
    return false;
}

test "unit names escape like systemd and stay under the limit" {
    try std.testing.expectEqualStrings("app-rediwm-org.gnome.Nautilus-42.scope", unitName(42, "org.gnome.Nautilus").name());
    try std.testing.expectEqualStrings("app-rediwm-brave\\x2dbrowser-7.scope", unitName(7, "brave-browser").name());
    try std.testing.expectEqualStrings("app-rediwm-app-1.scope", unitName(1, "").name());
    const long = unitName(2147483647, "x" ** 300);
    try std.testing.expect(long.len <= max_unit);
    try std.testing.expect(std.mem.endsWith(u8, long.name(), "-2147483647.scope"));
    const escaped = unitName(5, "-" ** 100);
    try std.testing.expect(escaped.len <= max_unit);
    try std.testing.expect(std.mem.endsWith(u8, escaped.name(), "\\x2d-5.scope"));
}

test "command ids are the first word's basename" {
    try std.testing.expectEqualStrings("foot", commandId("foot --server"));
    try std.testing.expectEqualStrings("brave", commandId("  /usr/bin/brave %U"));
    try std.testing.expectEqualStrings("", commandId(""));
}
