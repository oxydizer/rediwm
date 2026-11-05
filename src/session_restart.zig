//! rediwm-restart: restart this user's installed RediWM after an update, never
//! a development or nested instance.
//!
//! Run by install-session.sh as the login user. It finds the IPC socket, checks
//! through SO_PEERCRED that the listener is this user's process running the
//! installed executable, asks it to restart, then waits until the same PID
//! answers again from the new executable. Usage:
//! `rediwm-restart [installed [socket]]` (default: configured installation). The
//! socket is an argument, never `REDIWM_SOCKET`: a shell started from the live
//! session inherits that variable, and a stray run would restart the desktop.
const std = @import("std");
const linux = std.os.linux;
const c = std.posix.system;
const platform = @import("platform");

const default_installed = @import("install_paths").bin ++ "/rediwm";
const io_timeout_s = 3;
const ready_timeout_ms = 20_000;
const poll_interval_ms = 200;

const Session = struct {
    path: []const u8,
    fd: c_int,
    pid: i32,
};

const RequestError = error{ Disconnected, TimedOut, BadReply, OutOfMemory };

pub fn main(init: std.process.Init) u8 {
    const allocator = std.heap.c_allocator;
    const args = init.minimal.args.vector;
    const installed: []const u8 = if (args.len > 1) std.mem.span(args[1]) else default_installed;
    const socket: ?[]const u8 = if (args.len > 2) std.mem.span(args[2]) else null;
    run(allocator, init.minimal.environ, installed, socket) catch |err| {
        std.debug.print("Installed, but restart failed: {s}\n", .{errorText(err)});
        return 1;
    };
    return 0;
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.MultipleSessions => "Multiple installed sessions found; pass the socket path as the second argument to choose one.",
        error.NotReady => "Restart did not become ready within 20 seconds; check the RediWM session log.",
        error.Rejected => "Restart rejected by the compositor",
        else => @errorName(err),
    };
}

fn run(allocator: std.mem.Allocator, environ: std.process.Environ, installed: []const u8, socket: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try socketPaths(arena, environ, socket);
    var found: std.ArrayList(Session) = .empty;
    for (paths) |path| {
        const session = connect(arena, path, installed) orelse continue;
        try found.append(arena, session);
    }
    if (found.items.len == 0) {
        say("Installed ReleaseSafe. No installed RediWM session found; select RediWM at login.\n");
        return;
    }
    if (found.items.len != 1) {
        for (found.items) |s| closeFd(s.fd);
        return error.MultipleSessions;
    }
    const session = found.items[0];

    {
        defer closeFd(session.fd);
        // Probe before sending: old versions cannot acquire new restart support
        // merely by replacing their executable on disk.
        const capabilities = try request(arena, session.fd, "{\"version\":1,\"command\":\"capabilities\"}\n");
        if (!hasCapability(capabilities, "restart_shell")) {
            say("Installed ReleaseSafe. This running version lacks clean restart support. " ++
                "Log out and back in once; subsequent installs restart automatically.\n");
            return;
        }
        say("Restarting RediWM; connected applications will close.\n");
        const ignore: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.HUP, &ignore, null);
        if (request(arena, session.fd, "{\"version\":1,\"command\":\"restart_shell\"}\n")) |reply| {
            if (reply.get("Err") != null) return error.Rejected;
        } else |err| switch (err) {
            // Shutdown can close IPC before its buffered reply is flushed.
            error.Disconnected, error.TimedOut => {},
            else => |e| return e,
        }
    }
    try waitReady(arena, session, installed);
}

/// The sockets to try: an explicit one, this display's, or every session's.
fn socketPaths(arena: std.mem.Allocator, environ: std.process.Environ, socket: ?[]const u8) ![]const []const u8 {
    if (socket) |explicit| return try arena.dupe([]const u8, &.{explicit});
    const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse
        try std.fmt.allocPrint(arena, "/run/user/{d}", .{c.getuid()});
    if (environ.getPosix("WAYLAND_DISPLAY")) |display| {
        return try arena.dupe([]const u8, &.{try std.fmt.allocPrint(arena, "{s}/rediwm-{s}.sock", .{ runtime, display })});
    }
    var list: std.ArrayList([]const u8) = .empty;
    const dir_path = try std.fmt.allocPrintSentinel(arena, "{s}", .{runtime}, 0);
    const dir = std.c.opendir(dir_path) orelse return list.items;
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (!std.mem.startsWith(u8, name, "rediwm-") or !std.mem.endsWith(u8, name, ".sock")) continue;
        try list.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ runtime, name }));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return list.items;
}

/// Connects and accepts only this user's process running `installed`.
fn connect(arena: std.mem.Allocator, path: []const u8, installed: []const u8) ?Session {
    if (path.len >= 107) return null;
    const fd = c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    if (fd < 0) return null;
    errdefer closeFd(fd);
    const tv: std.posix.timeval = .{ .sec = io_timeout_s, .usec = 0 };
    _ = c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));
    _ = c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));

    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const addr_len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
    if (c.connect(fd, @ptrCast(&addr), addr_len) < 0) {
        closeFd(fd);
        return null;
    }

    const peer = platform.peer.of(fd) orelse {
        closeFd(fd);
        return null;
    };
    if (peer.uid != c.getuid() or !runsInstalled(arena, peer.pid, installed)) {
        closeFd(fd);
        return null;
    }
    return .{ .path = path, .fd = fd, .pid = peer.pid };
}

fn runsInstalled(arena: std.mem.Allocator, pid: i32, installed: []const u8) bool {
    const link = std.fmt.allocPrintSentinel(arena, "/proc/{d}/exe", .{pid}, 0) catch return false;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const n = c.readlink(link, &buf, buf.len);
    if (n <= 0) return false;
    const deleted = " (deleted)";
    var exe: []const u8 = buf[0..@intCast(n)];
    if (std.mem.endsWith(u8, exe, deleted)) exe = exe[0 .. exe.len - deleted.len];
    return std.mem.eql(u8, exe, installed);
}

/// Sends one request line and returns the reply's top-level object.
fn request(arena: std.mem.Allocator, fd: c_int, line: []const u8) RequestError!std.json.ObjectMap {
    var sent: usize = 0;
    while (sent < line.len) {
        const n = c.write(fd, line.ptr + sent, line.len - sent);
        if (n < 0) return failure(std.posix.errno(n));
        sent += @intCast(n);
    }
    var data: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (std.mem.indexOfScalar(u8, data.items, '\n') == null) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) return failure(std.posix.errno(n));
        if (n == 0) return error.Disconnected;
        try data.appendSlice(arena, chunk[0..@intCast(n)]);
    }
    const first = data.items[0..std.mem.indexOfScalar(u8, data.items, '\n').?];
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, first, .{}) catch return error.BadReply;
    return switch (value) {
        .object => |o| o,
        else => error.BadReply,
    };
}

fn failure(err: std.posix.E) RequestError {
    return switch (err) {
        .AGAIN => error.TimedOut,
        else => error.Disconnected,
    };
}

fn hasCapability(reply: std.json.ObjectMap, name: []const u8) bool {
    const ok = switch (reply.get("Ok") orelse return false) {
        .object => |o| o,
        else => return false,
    };
    const list = switch (ok.get("Capabilities") orelse return false) {
        .array => |a| a,
        else => return false,
    };
    for (list.items) |item| switch (item) {
        .string => |s| if (std.mem.eql(u8, s, name)) return true,
        else => {},
    };
    return false;
}

/// Waits until the same PID runs the new executable and answers `Version`.
fn waitReady(arena: std.mem.Allocator, session: Session, installed: []const u8) !void {
    const installed_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{installed}, 0);
    const exe_z = try std.fmt.allocPrintSentinel(arena, "/proc/{d}/exe", .{session.pid}, 0);
    const expected = fileId(installed_z) orelse return error.NotReady;
    const deadline = nowMs() + ready_timeout_ms;
    while (nowMs() < deadline) : (sleepMs(poll_interval_ms)) {
        const current = fileId(exe_z) orelse continue;
        if (!std.meta.eql(current, expected)) continue;
        const ready = connect(arena, session.path, installed) orelse continue;
        defer closeFd(ready.fd);
        if (ready.pid != session.pid) continue;
        const reply = request(arena, ready.fd, "{\"version\":1,\"command\":\"version\"}\n") catch continue;
        if (reply.get("Ok") == null) continue;
        say("ReleaseSafe restarted successfully.\n");
        return;
    }
    return error.NotReady;
}

const FileId = struct { dev_major: u32, dev_minor: u32, ino: u64 };

fn fileId(path: [*:0]const u8) ?FileId {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .dev_major = stx.dev_major, .dev_minor = stx.dev_minor, .ino = stx.ino };
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u32) void {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * 1_000_000 };
    _ = c.nanosleep(&ts, null);
}

/// Progress goes to stdout; only the final failure line uses stderr.
fn say(comptime text: []const u8) void {
    _ = c.write(std.posix.STDOUT_FILENO, text.ptr, text.len);
}

fn closeFd(fd: c_int) void {
    _ = c.close(fd);
}
