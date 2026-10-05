//! Session policy and private readiness handshake. The login supervisor owns
//! activation publication and cleanup, including after compositor crashes.
const std = @import("std");

const child_env = @import("../child_env.zig");
const dbus = @import("dbus");
const wl = @import("wayland").server.wl;
const wire = dbus.wire;

const log = std.log.scoped(.activation);

pub const EnvView = struct {
    nested_flag: ?[]const u8 = null,
    backends: ?[]const u8 = null,
    import_flag: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    login_session: ?[]const u8 = null,
    primary: ?[]const u8 = null,
    host_display: ?[]const u8 = null,
};

pub fn viewFromEnviron(environ: std.process.Environ) EnvView {
    return .{
        .nested_flag = environ.getPosix("REDIWM_NESTED"),
        .backends = environ.getPosix("WLR_BACKENDS"),
        .import_flag = environ.getPosix("REDIWM_IMPORT_ACTIVATION_ENV"),
        .config_home = environ.getPosix("XDG_CONFIG_HOME"),
        .home = environ.getPosix("HOME"),
        .login_session = environ.getPosix("REDIWM_LOGIN_SESSION"),
        .primary = environ.getPosix("REDIWM_SESSION_PRIMARY"),
        .host_display = environ.getPosix("WAYLAND_DISPLAY"),
    };
}

pub fn isTruthy(text: ?[]const u8) bool {
    const value = text orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

pub fn isFalsy(text: ?[]const u8) bool {
    const value = text orelse return false;
    return std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false");
}

/// Nested Wayland, headless test backends, or an explicit REDIWM_NESTED flag.
/// A DRM login typically leaves WLR_BACKENDS unset (or "drm") — not nested.
pub fn isNested(view: EnvView) bool {
    if (isTruthy(view.nested_flag)) return true;
    const backends = view.backends orelse return view.host_display != null;
    return std.mem.indexOf(u8, backends, "wayland") != null or
        std.mem.indexOf(u8, backends, "headless") != null;
}

/// Publish only on a real login. REDIWM_IMPORT_ACTIVATION_ENV=0 skips even
/// then; there is no force-import override for nested sessions (that would
/// write the nested display onto the host bus).
pub fn shouldPublish(view: EnvView) bool {
    if (isFalsy(view.import_flag)) return false;
    return !isNested(view) and isTruthy(view.login_session) and isTruthy(view.primary);
}

pub fn formatXdpwConfig(allocator: std.mem.Allocator, picker_path: []const u8) ![]u8 {
    const cmd = try formatChooserCmd(allocator, picker_path);
    defer allocator.free(cmd);
    return std.fmt.allocPrint(allocator,
        \\[screencast]
        \\max_fps=30
        \\chooser_type=dmenu
        \\chooser_cmd={s}
        \\
    , .{cmd});
}

pub fn formatChooserCmd(allocator: std.mem.Allocator, picker_path: []const u8) ![]u8 {
    if (needsShellQuote(picker_path)) {
        return std.fmt.allocPrint(allocator, "'{s}' --xdpw-dmenu", .{picker_path});
    }
    return std.fmt.allocPrint(allocator, "{s} --xdpw-dmenu", .{picker_path});
}

fn needsShellQuote(path: []const u8) bool {
    for (path) |byte| {
        switch (byte) {
            ' ', '\t', '\'', '"', '$', '`', '\\', '*', '?', '[', ']', '{', '}', '~', '#', '&', '|', ';', '<', '>', '(', ')' => return true,
            else => {},
        }
    }
    return false;
}

pub fn configHome(allocator: std.mem.Allocator, view: EnvView) ![]u8 {
    if (view.config_home) |home| {
        if (home.len > 0) return allocator.dupe(u8, home);
    }
    const home = view.home orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".config" });
}

pub fn sessionFd(environ: std.process.Environ) ?std.posix.fd_t {
    const value = environ.getPosix("REDIWM_SESSION_FD") orelse return null;
    const fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch return null;
    return if (fd >= 3) fd else null;
}

/// Close on ordinary child exec; retain only for a compositor exec restart.
pub fn setSessionFdInheritance(environ: std.process.Environ, inherit: bool) void {
    const fd = sessionFd(environ) orelse return;
    _ = std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(c_int, if (inherit) 0 else std.posix.FD_CLOEXEC));
}

/// rediwm-session queues "lock" ahead of everything else when the previous
/// compositor crashed while locked. Taken before the readiness exchange; any
/// other packet is left for it.
pub fn takeLockRequest(environ: std.process.Environ) bool {
    const fd = sessionFd(environ) orelse return false;
    const request = "lock";
    var packet: [8]u8 = undefined;
    const n = std.posix.system.recv(fd, &packet, packet.len, std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT);
    if (n != request.len or !std.mem.eql(u8, packet[0..request.len], request)) return false;
    _ = std.posix.system.recv(fd, &packet, packet.len, std.posix.MSG.DONTWAIT);
    return true;
}

/// Tells rediwm-session whether a crash from now on must restart behind the
/// lock. Without a supervisor (nested, greeter, tests) there is no one to tell.
pub fn reportLocked(environ: std.process.Environ, locked: bool) void {
    const fd = sessionFd(environ) orelse return;
    const report: []const u8 = if (locked) "locked" else "unlocked";
    const sent = std.posix.system.send(fd, report.ptr, report.len, std.posix.MSG.NOSIGNAL | std.posix.MSG.DONTWAIT);
    if (sent != report.len) log.warn("could not report the lock state to rediwm-session", .{});
}

/// The supervisor must acknowledge environment publication before autostart,
/// but frames, input and IPC keep running while its bus calls are outstanding.
/// Stored at a stable address until completion or deinit; the fd is borrowed
/// so it survives an exec restart through setSessionFdInheritance.
pub const Readiness = struct {
    pub const Failure = error{ ReadinessFailed, ReadinessTimeout };
    pub const Completion = *const fn (*anyopaque, Failure!void) void;

    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    owner: *anyopaque = undefined,
    completion: Completion = undefined,

    pub fn start(
        self: *Readiness,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        map: *const child_env.Map,
        loop: *wl.EventLoop,
        owner: *anyopaque,
        completion: Completion,
    ) !void {
        self.owner = owner;
        self.completion = completion;
        const view = viewFromEnviron(environ);
        if (shouldPublish(view)) writeXdpwConfig(allocator, view, io) catch |err| {
            log.warn("could not write xdpw config: {}", .{err});
        };
        const fd = sessionFd(environ) orelse {
            log.info("no login supervisor; using direct child environments only", .{});
            completion(owner, {});
            return;
        };
        const message = try std.json.Stringify.valueAlloc(allocator, .{
            .WAYLAND_DISPLAY = map.get("WAYLAND_DISPLAY") orelse "",
            .DISPLAY = map.get("DISPLAY") orelse "",
            .REDIWM_SOCKET = map.get("REDIWM_SOCKET") orelse "",
            .XDG_CURRENT_DESKTOP = child_env.desktop_name,
            .XDG_SESSION_TYPE = child_env.session_type,
            .PATH = map.get("PATH") orelse "",
        }, .{});
        defer allocator.free(message);

        errdefer self.deinit();
        self.source = try loop.addFd(*Readiness, fd, .{ .readable = true }, onFd, self);
        self.timer = try loop.addTimer(*Readiness, onTimeout, self);
        try self.timer.?.timerUpdate(30000);
        const sent = std.posix.system.send(fd, message.ptr, message.len, std.posix.MSG.NOSIGNAL | std.posix.MSG.DONTWAIT);
        if (sent != message.len) return error.ReadinessFailed;
    }

    pub fn deinit(self: *Readiness) void {
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.timer) |timer| timer.remove();
        self.timer = null;
    }

    fn finish(self: *Readiness, result: Failure!void) void {
        self.deinit();
        self.completion(self.owner, result);
    }

    fn onFd(fd: c_int, _: wl.EventMask, self: *Readiness) c_int {
        var reply: [32]u8 = undefined;
        const n = std.posix.system.recv(fd, &reply, reply.len, std.posix.MSG.DONTWAIT);
        if (n < 0 and std.posix.errno(n) == .AGAIN) return 0;
        if (n != 5 or !std.mem.eql(u8, reply[0..5], "ready")) {
            self.finish(error.ReadinessFailed);
        } else {
            self.finish({});
        }
        return 0;
    }

    fn onTimeout(self: *Readiness) c_int {
        self.finish(error.ReadinessTimeout);
        return 0;
    }
};

fn writeXdpwConfig(allocator: std.mem.Allocator, view: EnvView, io: std.Io) !void {
    if (isNested(view)) return;

    const home = try configHome(allocator, view);
    defer allocator.free(home);
    const dir = try std.fs.path.join(allocator, &.{ home, "xdg-desktop-portal-wlr" });
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "rediwm" });
    defer allocator.free(path);

    if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
        log.info("activation: keeping existing {s}", .{path});
        return;
    } else |_| {}

    const picker = pickerPath(allocator, io) catch |err| {
        log.warn("activation: could not locate rediwm-share-picker: {}", .{err});
        return err;
    };
    defer allocator.free(picker);
    const contents = try formatXdpwConfig(allocator, picker);
    defer allocator.free(contents);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        log.warn("activation: mkdir {s}: {}", .{ dir, err });
        return err;
    };
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    log.info("activation: wrote {s}", .{path});
}

fn pickerPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "rediwm-share-picker" });
}

pub const EnvVar = struct { name: []const u8, value: []const u8 };

const publish_timeout_ms = 5000;

const Reply = struct {
    what: []const u8,
    done: bool = false,
    ok: bool = false,
};

/// What `dbus-update-activation-environment --systemd` does: the bus's own
/// activation environment (services it execs itself) and the systemd user
/// manager's (units such as xdg-desktop-portal-gtk.service). Without these,
/// portal backends start with no display, exit, and xdg-desktop-portal drops
/// the Settings interface — which Brave reads as "prefer dark".
///
/// Blocks on the replies, not just the sends: queued messages are only
/// written from the event loop, so destroying the connection right after
/// `call` drops them. Succeeds if either manager accepted the environment;
/// each refusal is logged on its own.
pub fn publishActivationEnv(loop: *wl.EventLoop, allocator: std.mem.Allocator, environ: std.process.Environ, vars: []const EnvVar) !void {
    const conn = try dbus.Connection.openSession(allocator, loop, environ);
    defer conn.destroy();

    var hello = Reply{ .what = "Hello" };
    _ = try conn.hello(&hello, onReply);
    try waitForReplies(loop, &.{&hello});
    if (!hello.ok) return error.HelloFailed;

    var bus_body: wire.Writer = .{ .allocator = allocator };
    defer bus_body.deinit();
    try writeBusEnvironment(&bus_body, vars);
    var bus = Reply{ .what = "org.freedesktop.DBus.UpdateActivationEnvironment" };
    _ = try conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "UpdateActivationEnvironment", "a{ss}", &bus_body, &bus, onReply, publish_timeout_ms);

    var systemd_body: wire.Writer = .{ .allocator = allocator };
    defer systemd_body.deinit();
    try writeSystemdEnvironment(allocator, &systemd_body, vars);
    var systemd = Reply{ .what = "org.freedesktop.systemd1.Manager.SetEnvironment" };
    _ = try conn.call("org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "SetEnvironment", "as", &systemd_body, &systemd, onReply, publish_timeout_ms);

    try waitForReplies(loop, &.{ &bus, &systemd });
    if (!bus.ok and !systemd.ok) return error.NotPublished;
}

/// `a{ss}` for org.freedesktop.DBus.UpdateActivationEnvironment.
fn writeBusEnvironment(body: *wire.Writer, vars: []const EnvVar) !void {
    const dict = try body.beginArray(8);
    for (vars) |v| {
        try body.alignTo(8);
        try body.string(v.name);
        try body.string(v.value);
    }
    try body.endArray(dict);
}

/// `as` of NAME=value for org.freedesktop.systemd1.Manager.SetEnvironment.
fn writeSystemdEnvironment(allocator: std.mem.Allocator, body: *wire.Writer, vars: []const EnvVar) !void {
    const list = try body.beginArray(4);
    for (vars) |v| {
        const assignment = try std.fmt.allocPrint(allocator, "{s}={s}", .{ v.name, v.value });
        defer allocator.free(assignment);
        try body.string(assignment);
    }
    try body.endArray(list);
}

fn onReply(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const state: *Reply = @ptrCast(@alignCast(owner orelse return));
    state.done = true;
    const msg = result catch |err| {
        log.warn("activation: {s}: {}", .{ state.what, err });
        return;
    };
    if (msg.kind == .method_return) {
        state.ok = true;
    } else {
        log.warn("activation: {s} refused: {s}", .{ state.what, msg.headers.error_name orelse "unknown error" });
    }
}

/// The connection times each call out itself; this deadline only guards
/// against a stalled loop.
fn waitForReplies(loop: *wl.EventLoop, replies: []const *const Reply) !void {
    const deadline = try monotonicMillis() + publish_timeout_ms + 1000;
    while (true) {
        const pending = for (replies) |r| {
            if (!r.done) break true;
        } else false;
        if (!pending) return;

        const now = try monotonicMillis();
        if (now >= deadline) return error.Timeout;

        const remaining = deadline - now;
        const wait_ms: c_int = if (remaining > 1000)
            100
        else
            @as(c_int, @intCast(remaining));

        try loop.dispatch(wait_ms);
    }
}

fn monotonicMillis() !i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => return error.ClockReadFailed,
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

test "nested detection treats wayland and headless backends as nested" {
    try std.testing.expect(isNested(.{ .backends = "wayland" }));
    try std.testing.expect(isNested(.{ .backends = "wayland,headless" }));
    try std.testing.expect(isNested(.{ .backends = "headless" }));
    try std.testing.expect(isNested(.{ .nested_flag = "1" }));
    try std.testing.expect(!isNested(.{ .backends = "drm" }));
    try std.testing.expect(!isNested(.{}));
}

test "shouldPublish is false for nested and for an explicit skip" {
    try std.testing.expect(!shouldPublish(.{ .backends = "headless" }));
    try std.testing.expect(!shouldPublish(.{ .backends = "wayland" }));
    try std.testing.expect(!shouldPublish(.{ .import_flag = "0" }));
    try std.testing.expect(shouldPublish(.{ .backends = "drm", .login_session = "c1", .primary = "1" }));
    try std.testing.expect(!shouldPublish(.{}));
    try std.testing.expect(!shouldPublish(.{ .host_display = "wayland-0", .login_session = "c1", .primary = "1" }));
}

test "xdpw config points at the packaged picker and does not enable persist" {
    const text = try formatXdpwConfig(std.testing.allocator, "/usr/bin/rediwm-share-picker");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "chooser_type=dmenu") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/usr/bin/rediwm-share-picker --xdpw-dmenu") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "max_fps=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "XDPW_PERSIST") == null);
}

test "chooser command quotes picker paths that would break sh -c" {
    const quoted = try formatChooserCmd(std.testing.allocator, "/opt/tiny wl/rediwm-share-picker");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'/opt/tiny wl/rediwm-share-picker' --xdpw-dmenu", quoted);
}

test "activation environment bodies satisfy their D-Bus signatures" {
    const allocator = std.testing.allocator;
    const vars = [_]EnvVar{
        .{ .name = "WAYLAND_DISPLAY", .value = "wayland-1" },
        .{ .name = "XDG_CURRENT_DESKTOP", .value = "rediwm" },
        .{ .name = "XDG_SESSION_TYPE", .value = "" },
    };

    // wire.encode decodes its output, so a body that does not match the
    // signature fails here (bare strings under "as" were error.Truncated).
    var bus_body: wire.Writer = .{ .allocator = allocator };
    defer bus_body.deinit();
    try writeBusEnvironment(&bus_body, &vars);
    var bus_msg = try wire.encode(allocator, .method_call, 0, 1, .{ .path = "/org/freedesktop/DBus", .member = "UpdateActivationEnvironment", .signature = "a{ss}" }, &bus_body);
    defer bus_msg.deinit();
    var bus_reader = (try wire.decode(bus_msg.bytes.items)).body;
    var dict = try bus_reader.array(8);
    for (vars) |v| {
        try dict.alignTo(8);
        try std.testing.expectEqualStrings(v.name, try dict.string());
        try std.testing.expectEqualStrings(v.value, try dict.string());
    }
    try dict.done();
    try bus_reader.done();

    var systemd_body: wire.Writer = .{ .allocator = allocator };
    defer systemd_body.deinit();
    try writeSystemdEnvironment(allocator, &systemd_body, &vars);
    var systemd_msg = try wire.encode(allocator, .method_call, 0, 1, .{ .path = "/org/freedesktop/systemd1", .member = "SetEnvironment", .signature = "as" }, &systemd_body);
    defer systemd_msg.deinit();
    var systemd_reader = (try wire.decode(systemd_msg.bytes.items)).body;
    var list = try systemd_reader.array(4);
    try std.testing.expectEqualStrings("WAYLAND_DISPLAY=wayland-1", try list.string());
    try std.testing.expectEqualStrings("XDG_CURRENT_DESKTOP=rediwm", try list.string());
    try std.testing.expectEqualStrings("XDG_SESSION_TYPE=", try list.string());
    try list.done();
    try systemd_reader.done();
}
