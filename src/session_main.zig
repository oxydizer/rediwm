//! rediwm-session: the login supervisor. Owns publication, readiness and child
//! session lifetime.
//!
//! Only a verified logind login can publish to the shared user manager. Nested
//! instances use direct child environments. Helpers must run in the foreground;
//! applications are never restarted independently.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("session/login_sys.zig");
const login_bus = @import("session/login_bus.zig");
const publication = @import("session/publication.zig");
const supervisor = @import("session/supervisor.zig");

const Publication = publication.Publication(login_bus.Bus);
const allocator = std.heap.c_allocator;

pub fn main(init: std.process.Init) !u8 {
    // The compositor refuses root too; fail here instead of crash-restarting it.
    if (std.os.linux.getuid() == 0 or std.os.linux.geteuid() == 0) {
        sys.diagnostic("refusing to run as root; log in as a regular user", .{});
        return 1;
    }
    _ = std.c.umask(0o077);
    const environ = init.minimal.environ;
    var env = try environ.createMap(allocator);
    defer env.deinit();
    for ([_][]const u8{ "REDIWM_LOGIN_SESSION", "REDIWM_SESSION_PRIMARY", "REDIWM_SESSION_FD" }) |key| _ = env.swapRemove(key);

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
    var lease: ?Publication = null;
    defer if (lease) |*p| p.deinit();
    loginSession(arena, &bus, runtime_env, &env, &lease) catch |err| {
        sys.diagnostic("global activation disabled: {t}", .{err});
        if (lease) |*p| p.deinit();
        lease = null;
    };

    const exe_dir = try std.process.executableDirPathAlloc(init.io, arena);
    const compositor = try std.fs.path.joinZ(arena, &.{ exe_dir, "rediwm" });
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ exe_dir, env.get("PATH") orelse "/usr/bin:/bin" }));
    const prefix = std.fs.path.dirname(exe_dir) orelse "/";
    try env.put("XDG_DATA_DIRS", try std.fmt.allocPrint(arena, "{s}/share:{s}", .{ prefix, env.get("XDG_DATA_DIRS") orelse "/usr/share" }));
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

fn loginSession(arena: std.mem.Allocator, bus: *login_bus.Bus, runtime_env: ?[]const u8, env: *std.process.Environ.Map, lease: *?Publication) !void {
    const session = try bus.login(arena);
    const runtime = runtime_env orelse return error.NoRuntimeDir;
    const runtime_z = try arena.dupeZ(u8, runtime);
    var info: linux.Statx = undefined;
    _ = try sys.check(linux.statx(linux.AT.FDCWD, runtime_z, 0, .{ .UID = true, .MODE = true }, &info));
    if (info.uid != linux.getuid() or info.mode & 0o077 != 0) {
        sys.diagnostic("runtime directory is not private to this uid", .{});
        return error.RuntimeDirNotPrivate;
    }
    try env.put("REDIWM_LOGIN_SESSION", session);
    try env.put("XDG_SESSION_ID", session);
    if (env.get("DBUS_SESSION_BUS_ADDRESS") == null) {
        try env.put("DBUS_SESSION_BUS_ADDRESS", try std.fmt.allocPrint(arena, "unix:path={s}/bus", .{runtime}));
    }
    const import = env.get("REDIWM_IMPORT_ACTIVATION_ENV") orelse "1";
    if (std.mem.eql(u8, import, "0") or std.mem.eql(u8, import, "false")) return;
    lease.* = try Publication.init(allocator, bus, runtime, session);
    try lease.*.?.acquire();
    try env.put("REDIWM_SESSION_PRIMARY", "1");
}

fn makePath(arena: std.mem.Allocator, path: []const u8) !void {
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end != path.len and path[end] != '/') continue;
        const partial = try arena.dupeZ(u8, path[0..end]);
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, partial, 0o700))) {
            .SUCCESS, .EXIST => {},
            else => |err| return sys.errnoError(err),
        }
    }
}

test {
    _ = publication;
    _ = supervisor;
    _ = login_bus;
}
