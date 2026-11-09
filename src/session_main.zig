//! rediwm-session: the login supervisor. Owns publication, readiness and child
//! session lifetime.
//!
//! Only a verified login can publish activation state: logind uses the shared
//! user manager, ConsoleKit2 a session bus. Unverified instances use direct child
//! environments. Helpers run in the foreground; apps are not restarted separately.
const std = @import("std");
const c = @import("c");
const sys = @import("session/login_sys.zig");
const login = @import("session/login_manager.zig");
const login_bus = @import("session/login_bus.zig");
const publication = @import("session/publication.zig");
const supervisor = @import("session/supervisor.zig");

const Publication = if (login.owns_session) @import("session/private_publication.zig").Publication(login_bus.Bus) else publication.Publication(login_bus.Bus);
const user_bus = @import("session/user_bus.zig");
const allocator = std.heap.c_allocator;

pub fn main(init: std.process.Init) !u8 {
    // The compositor refuses root too; fail here instead of crash-restarting it.
    if (std.posix.system.getuid() == 0 or std.posix.system.geteuid() == 0) {
        sys.diagnostic("refusing to run as root; log in as a regular user", .{});
        return 1;
    }
    _ = std.c.umask(0o077);
    const environ = init.minimal.environ;
    var env = try environ.createMap(allocator);
    defer env.deinit();
    for ([_][]const u8{ "REDIWM_LOGIN_SESSION", "REDIWM_SESSION_PRIMARY", "REDIWM_SESSION_FD" }) |key| _ = env.swapRemove(key);
    if (login.owns_session) {
        _ = env.swapRemove("XDG_SESSION_COOKIE");
        _ = env.swapRemove("XDG_SESSION_ID");
    }

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const runtime_env = environ.getPosix("XDG_RUNTIME_DIR");
    const user_address = environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse
        if (runtime_env) |dir| try std.fmt.allocPrint(arena, "unix:path={s}/bus", .{dir}) else "";
    var bus = try login_bus.Bus.init(
        allocator,
        environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/var/run/dbus/system_bus_socket",
        user_address,
    );
    defer bus.deinit();

    // Never infer a login from XDG_SESSION_TYPE or XDG_SESSION_ID alone.
    var daemon: ?user_bus.Daemon = null;
    defer if (daemon) |*owned| owned.stop(init.io);
    var lease: ?Publication = null;
    defer if (lease) |*p| p.deinit();
    loginSession(init.io, arena, &bus, runtime_env, &env, &lease, &daemon) catch |err| {
        sys.diagnostic("global activation disabled: {t}", .{err});
        if (lease) |*p| p.deinit();
        lease = null;
        if (login.owns_session and env.get("REDIWM_LOGIN_SESSION") == null) {
            login.release(&bus);
            for ([_][]const u8{ "XDG_SESSION_COOKIE", "XDG_SESSION_ID", "REDIWM_LOGIN_SESSION", "REDIWM_SESSION_PRIMARY" }) |key| _ = env.swapRemove(key);
        }
    };

    const exe_dir = try std.process.executableDirPathAlloc(init.io, arena);
    const compositor = try std.fs.path.joinZ(arena, &.{ exe_dir, "rediwm" });
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ exe_dir, env.get("PATH") orelse "/usr/bin:/bin" }));
    const prefix = std.fs.path.dirname(exe_dir) orelse "/";
    try env.put("XDG_DATA_DIRS", try dataDirs(arena, try std.fmt.allocPrint(arena, "{s}/share", .{prefix}), env.get("XDG_DATA_DIRS")));
    try env.put("XDG_CURRENT_DESKTOP", "rediwm");
    try env.put("XDG_SESSION_TYPE", "wayland");
    for ([_][]const u8{ "DISPLAY", "WAYLAND_DISPLAY", "WLR_BACKENDS", "WLR_WL_OUTPUTS", "WLR_HEADLESS_OUTPUTS", "REDIWM_NESTED", "REDIWM_SCALE" }) |key| _ = env.swapRemove(key);

    const state = if (env.get("XDG_STATE_HOME")) |dir|
        try std.fs.path.join(arena, &.{ dir, "rediwm" })
    else
        try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHome, ".local/state/rediwm" });
    try makePath(arena, state);
    const log_path = try std.fs.path.joinZ(arena, &.{ state, "session.log" });
    const previous_path = try std.fs.path.joinZ(arena, &.{ state, "session.previous.log" });
    sys.renameZ(log_path, previous_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const log_fd = try sys.openZ(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    defer {
        sys.diag_fd = 2;
        sys.close(log_fd);
    }
    // Supervisor diagnostics share the session log with compositor output.
    sys.diag_fd = log_fd;

    return supervisor.supervise(Publication, .{
        .allocator = allocator,
        .compositor = compositor,
        .env = &env,
        .log_fd = log_fd,
        .publication = if (lease) |*p| p else null,
    });
}

fn loginSession(io: std.Io, arena: std.mem.Allocator, bus: *login_bus.Bus, runtime_env: ?[]const u8, env: *std.process.Environ.Map, lease: *?Publication, daemon: *?user_bus.Daemon) !void {
    const context: login.Context = if (login.owns_session) .{ .display_device = try @import("platform").login_process.consoleDevice(arena) } else .{};
    const session = try bus.login(arena, context);
    const runtime = runtime_env orelse return error.NoRuntimeDir;
    const runtime_z = try arena.dupeSentinel(u8, runtime, 0);
    var info: c.struct_stat = undefined;
    _ = try sys.check(c.stat(runtime_z, &info));
    if (info.st_uid != std.posix.system.getuid() or info.st_mode & 0o077 != 0 or info.st_mode & c.S_IFMT != c.S_IFDIR) {
        sys.diagnostic("runtime directory is not private to this uid", .{});
        return error.RuntimeDirNotPrivate;
    }
    if (login.owns_session) {
        try env.put("XDG_SESSION_COOKIE", bus.login_cookie.?);
        daemon.* = try user_bus.ensure(io, arena, bus, env, runtime);
    }
    try env.put("REDIWM_LOGIN_SESSION", session);
    try env.put("XDG_SESSION_ID", if (login.owns_session) std.fs.path.basename(session) else session);
    if (env.get("DBUS_SESSION_BUS_ADDRESS") == null) {
        try env.put("DBUS_SESSION_BUS_ADDRESS", try std.fmt.allocPrint(arena, "unix:path={s}/bus", .{runtime}));
    }
    const import = env.get("REDIWM_IMPORT_ACTIVATION_ENV") orelse "1";
    if (std.mem.eql(u8, import, "0") or std.mem.eql(u8, import, "false")) return;
    lease.* = try Publication.init(allocator, bus, runtime, session);
    try lease.*.?.acquire();
    try env.put("REDIWM_SESSION_PRIMARY", "1");
}

/// XDG_DATA_DIRS with the install's own `share` first, once. The other
/// entries keep their order; unset or empty, the XDG default stands.
fn dataDirs(arena: std.mem.Allocator, own: []const u8, inherited: ?[]const u8) ![]const u8 {
    const base = if (inherited) |value| (if (value.len > 0) value else null) else null;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(arena, own);
    var it = std.mem.splitScalar(u8, base orelse "/usr/local/share:/usr/share", ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or std.mem.eql(u8, dir, own)) continue;
        try list.append(arena, ':');
        try list.appendSlice(arena, dir);
    }
    return list.items;
}

test "data dirs list the install's share first and once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unset or empty: the XDG default, so a /usr prefix keeps /usr/local/share.
    try std.testing.expectEqualStrings("/usr/share:/usr/local/share", try dataDirs(a, "/usr/share", null));
    try std.testing.expectEqualStrings("/usr/share:/usr/local/share", try dataDirs(a, "/usr/share", ""));
    try std.testing.expectEqualStrings("/usr/local/share:/usr/share", try dataDirs(a, "/usr/local/share", null));
    // Set: the install wins, the rest keep their order and lose duplicates.
    try std.testing.expectEqualStrings("/usr/local/share:/opt/a:/opt/b", try dataDirs(a, "/usr/local/share", "/opt/a:/usr/local/share::/opt/b"));
}

fn makePath(arena: std.mem.Allocator, path: []const u8) !void {
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end != path.len and path[end] != '/') continue;
        const partial = try arena.dupeSentinel(u8, path[0..end], 0);
        switch (std.posix.errno(c.mkdirat(c.AT_FDCWD, partial, @as(c.mode_t, 0o700)))) {
            .SUCCESS, .EXIST => {},
            else => |err| return sys.errnoError(err),
        }
    }
}

test {
    _ = @import("session/private_publication.zig");
    _ = publication;
    _ = supervisor;
    _ = login_bus;
}
