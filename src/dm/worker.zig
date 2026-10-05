//! The rediwm-dm worker process (`rediwm-dm --worker <fd>`).
//! Runs as root and owns one PAM handle for its whole life: it authenticates,
//! then opens the logind session, forks the greeter or user session child,
//! and closes the PAM session when that child is gone. SIGTERM (from the
//! daemon, or its death through PR_SET_PDEATHSIG) ends the child's process
//! group, escalating to SIGKILL, so no greeter or session outlives its worker.
const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto.zig");

const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/prctl.h");
});

pub const pam_handle_t = opaque {};

extern "c" fn rediwm_pam_start(service: [*:0]const u8, user: [*:0]const u8, confdir: ?[*:0]const u8, ctrl_fd: c_int) ?*pam_handle_t;
extern "c" fn rediwm_pam_authenticate(pamh: *pam_handle_t) c_int;
extern "c" fn rediwm_pam_acct_mgmt(pamh: *pam_handle_t) c_int;
extern "c" fn rediwm_pam_setcred(pamh: *pam_handle_t, flags: c_int) c_int;
extern "c" fn rediwm_pam_putenv(pamh: *pam_handle_t, nameval: [*:0]const u8) c_int;
extern "c" fn rediwm_pam_open_session(pamh: *pam_handle_t) c_int;
extern "c" fn rediwm_pam_close_session(pamh: *pam_handle_t) c_int;
extern "c" fn rediwm_pam_end(pamh: *pam_handle_t, status: c_int) c_int;
extern "c" fn rediwm_pam_getenvlist(pamh: *pam_handle_t) ?[*:null]?[*:0]u8;
extern "c" fn rediwm_pam_strerror(pamh: *pam_handle_t, err: c_int) [*:0]const u8;

const PAM_SUCCESS: c_int = 0;
const PAM_ESTABLISH_CRED: c_int = 0x0002;
const PAM_DELETE_CRED: c_int = 0x0004;

/// How long a session gets to exit after SIGTERM before SIGKILL.
const stop_grace_ms = 5000;
const default_path = "/usr/local/sbin:/usr/local/bin:/usr/bin:/bin";

fn report(fd: c_int, tag: proto.Report, text: []const u8) void {
    proto.writeFrameParts(fd, &.{ &.{@intFromEnum(tag)}, text }) catch {};
}

pub fn runWorker(ctrl_fd: c_int, greeter_fd: c_int, confdir: ?[]const u8, is_test: bool) !u8 {
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, @intFromEnum(linux.SIG.TERM)), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var frame_buf: [proto.max_frame]u8 = undefined;
    const init = try std.json.parseFromSliceLeaky(proto.Init, a, try proto.readFrame(ctrl_fd, &frame_buf), .{ .allocate = .alloc_always });
    const is_greeter = std.mem.eql(u8, init.class, "greeter");
    const user_z = try a.dupeZ(u8, init.user);
    const confdir_z: ?[*:0]const u8 = if (confdir) |cd| (try a.dupeZ(u8, cd)).ptr else null;

    const pamh = rediwm_pam_start((try a.dupeZ(u8, init.service)).ptr, user_z.ptr, confdir_z, ctrl_fd) orelse {
        report(ctrl_fd, .failed, "pam_start failed");
        return 1;
    };
    var pam_status: c_int = PAM_SUCCESS;
    defer _ = rediwm_pam_end(pamh, pam_status);

    pam_status = rediwm_pam_authenticate(pamh);
    if (pam_status != PAM_SUCCESS) {
        report(ctrl_fd, .denied, std.mem.span(rediwm_pam_strerror(pamh, pam_status)));
        return 1;
    }
    pam_status = rediwm_pam_acct_mgmt(pamh);
    if (pam_status != PAM_SUCCESS) {
        report(ctrl_fd, .failed, std.mem.span(rediwm_pam_strerror(pamh, pam_status)));
        return 1;
    }
    report(ctrl_fd, .auth_ok, "");

    // The daemon cancels by closing the socket.
    const start_bytes = proto.readFrame(ctrl_fd, &frame_buf) catch return 0;
    const start = try std.json.parseFromSliceLeaky(proto.Start, a, start_bytes, .{ .allocate = .alloc_always });

    // pam_systemd reads these when registering the logind session.
    _ = rediwm_pam_putenv(pamh, "XDG_SESSION_TYPE=wayland");
    _ = rediwm_pam_putenv(pamh, if (is_greeter) "XDG_SESSION_CLASS=greeter" else "XDG_SESSION_CLASS=user");
    _ = rediwm_pam_putenv(pamh, "XDG_SEAT=seat0");
    _ = rediwm_pam_putenv(pamh, (try std.fmt.allocPrintSentinel(a, "XDG_VTNR={d}", .{init.vt}, 0)).ptr);
    if (start.desktop.len > 0) _ = rediwm_pam_putenv(pamh, (try std.fmt.allocPrintSentinel(a, "XDG_SESSION_DESKTOP={s}", .{start.desktop}, 0)).ptr);

    pam_status = rediwm_pam_setcred(pamh, PAM_ESTABLISH_CRED);
    if (pam_status != PAM_SUCCESS) {
        report(ctrl_fd, .session_failed, std.mem.span(rediwm_pam_strerror(pamh, pam_status)));
        return 1;
    }
    defer _ = rediwm_pam_setcred(pamh, PAM_DELETE_CRED);
    pam_status = rediwm_pam_open_session(pamh);
    if (pam_status != PAM_SUCCESS) {
        report(ctrl_fd, .session_failed, std.mem.span(rediwm_pam_strerror(pamh, pam_status)));
        return 1;
    }
    defer _ = rediwm_pam_close_session(pamh);

    // From here on, termination signals mean "end the session", read through
    // a signalfd. The child restores an empty mask before exec.
    var mask = linux.sigemptyset();
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| linux.sigaddset(&mask, sig);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const signal_fd = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC);
    if (linux.errno(signal_fd) != .SUCCESS) {
        report(ctrl_fd, .session_failed, "signalfd failed");
        return 1;
    }

    const env = try sessionEnv(a, pamh, init.user, start.desktops, greeter_fd >= 0);
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        report(ctrl_fd, .session_failed, "fork failed");
        return 1;
    }
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid == 0) execSession(a, init, start.exec, user_z, env, greeter_fd, is_test, is_greeter);

    report(ctrl_fd, .session_started, "");
    const status = supervise(pid, @intCast(signal_fd));
    var buf: [32]u8 = undefined;
    report(ctrl_fd, .session_ended, std.fmt.bufPrint(&buf, "{d}", .{status}) catch "");
    return 0;
}

/// Waits for the session child. A termination signal ends its process group
/// (SIGTERM, then SIGKILL after `stop_grace_ms`); returns the wait status.
fn supervise(pid: linux.pid_t, signal_fd: i32) u32 {
    const pidfd_rc = linux.pidfd_open(pid, 0);
    if (linux.errno(pidfd_rc) == .SUCCESS) {
        const pidfd: i32 = @intCast(pidfd_rc);
        defer _ = linux.close(pidfd);
        var deadline: ?i64 = null;
        var killed = false;
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = signal_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const timeout: i32 = if (deadline) |d| @intCast(@max(0, d - monotonicMs())) else -1;
            const rc = linux.poll(&fds, fds.len, timeout);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) break;
            if (fds[0].revents != 0) break;
            if (fds[1].revents != 0) {
                var info: linux.signalfd_siginfo = undefined;
                _ = linux.read(signal_fd, std.mem.asBytes(&info).ptr, @sizeOf(linux.signalfd_siginfo));
                if (deadline == null) {
                    signalGroup(pid, .TERM);
                    deadline = monotonicMs() + stop_grace_ms;
                }
            } else if (rc == 0 and !killed) {
                signalGroup(pid, .KILL);
                killed = true;
                deadline = null;
            }
        }
    }
    var status: u32 = 0;
    while (linux.errno(linux.waitpid(pid, &status, 0)) == .INTR) {}
    return status;
}

/// The child called setsid, so its pid is also its process group.
fn signalGroup(pid: linux.pid_t, sig: linux.SIG) void {
    _ = linux.kill(-pid, sig);
    _ = linux.kill(pid, sig);
}

fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

const Account = struct { home: [:0]const u8, shell: [:0]const u8, uid: u32, gid: u32, found: bool };

fn account(a: std.mem.Allocator, user_z: [:0]const u8) Account {
    var buf: [16384]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var res: ?*c.struct_passwd = null;
    if (c.getpwnam_r(user_z.ptr, &pw, &buf, buf.len, &res) != 0 or res == null)
        return .{ .home = "/", .shell = "/bin/sh", .uid = 0, .gid = 0, .found = false };
    const home = if (pw.pw_dir) |d| std.mem.span(d) else "/";
    const shell = if (pw.pw_shell) |s| std.mem.span(s) else "";
    return .{
        .home = a.dupeZ(u8, home) catch "/",
        .shell = a.dupeZ(u8, if (shell.len > 0) shell else "/bin/sh") catch "/bin/sh",
        .uid = pw.pw_uid,
        .gid = pw.pw_gid,
        .found = true,
    };
}

/// The child's environment: PAM's (XDG_RUNTIME_DIR, XDG_SESSION_ID...) plus
/// the account's identity. Keys we set ourselves are never taken from PAM.
fn sessionEnv(a: std.mem.Allocator, pamh: *pam_handle_t, user: []const u8, desktops: []const u8, greeter: bool) ![:null]?[*:0]const u8 {
    const user_z = try a.dupeZ(u8, user);
    const acct = account(a, user_z);
    const owned = [_][]const u8{ "HOME", "USER", "LOGNAME", "SHELL", "XDG_CURRENT_DESKTOP", "REDIWM_GREETER_FD" };
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var has_path = false;
    if (rediwm_pam_getenvlist(pamh)) |pam_env| {
        var i: usize = 0;
        while (pam_env[i]) |entry| : (i += 1) {
            const text = std.mem.span(entry);
            const key = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
            var skip = false;
            for (owned) |k| skip = skip or std.mem.eql(u8, key, k);
            if (skip) continue;
            has_path = has_path or std.mem.eql(u8, key, "PATH");
            try list.append(a, entry);
        }
    }
    try list.append(a, try std.fmt.allocPrintSentinel(a, "HOME={s}", .{acct.home}, 0));
    try list.append(a, try std.fmt.allocPrintSentinel(a, "USER={s}", .{user}, 0));
    try list.append(a, try std.fmt.allocPrintSentinel(a, "LOGNAME={s}", .{user}, 0));
    try list.append(a, try std.fmt.allocPrintSentinel(a, "SHELL={s}", .{acct.shell}, 0));
    if (!has_path) try list.append(a, "PATH=" ++ default_path);
    if (desktops.len > 0) try list.append(a, try std.fmt.allocPrintSentinel(a, "XDG_CURRENT_DESKTOP={s}", .{desktops}, 0));
    if (greeter) try list.append(a, "REDIWM_GREETER_FD=3");
    return list.toOwnedSliceSentinel(a, null);
}

/// The forked child: becomes the session and never returns. Everything it
/// needs was allocated before fork.
fn execSession(
    a: std.mem.Allocator,
    init: proto.Init,
    exec: []const u8,
    user_z: [:0]const u8,
    env: [:null]?[*:0]const u8,
    greeter_fd: c_int,
    is_test: bool,
    is_greeter: bool,
) noreturn {
    // Default dispositions and an empty mask, whatever systemd (SIGPIPE
    // ignored) or the worker (termination signals blocked) had.
    const default: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    var sig: u32 = 1;
    while (sig < 65) : (sig += 1) switch (@as(linux.SIG, @enumFromInt(sig))) {
        .KILL, .STOP => {},
        else => |s| _ = linux.sigaction(s, &default, null),
    };
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    _ = linux.setsid();

    const acct = account(a, user_z);
    if (!is_test) {
        const tty = std.fmt.allocPrintSentinel(a, "/dev/tty{d}", .{init.vt}, 0) catch linux.exit_group(1);
        const tty_rc = linux.open(tty.ptr, .{ .ACCMODE = .RDWR }, 0);
        const tty_fd: c_int = if (linux.errno(tty_rc) == .SUCCESS) @intCast(tty_rc) else -1;
        if (tty_fd >= 0) {
            _ = c.ioctl(tty_fd, c.TIOCSCTTY, @as(c_int, 0));
            // The greeter keeps the worker's stdout/stderr (rediwm-dm's
            // journal); nothing on a graphical VT would ever be seen.
            for (0..@as(usize, if (is_greeter) 1 else 3)) |fd| _ = c.dup2(tty_fd, @intCast(fd));
            if (tty_fd > 2) _ = c.close(tty_fd);
        }
        if (!acct.found) linux.exit_group(1);
        if (c.initgroups(user_z.ptr, acct.gid) != 0) linux.exit_group(1);
        if (c.setgid(acct.gid) != 0 or c.setuid(acct.uid) != 0) linux.exit_group(1);
        if (c.getuid() != acct.uid or c.geteuid() != acct.uid or c.getgid() != acct.gid or c.getegid() != acct.gid) linux.exit_group(1);
    }
    _ = c.chdir(acct.home.ptr);

    // The greeter's daemon socket is the only fd beyond stdio it inherits.
    if (greeter_fd >= 0) {
        if (greeter_fd != 3) _ = c.dup2(greeter_fd, 3);
        _ = linux.fcntl(3, linux.F.SETFD, 0);
    }
    _ = linux.close_range(if (greeter_fd >= 0) 4 else 3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });

    if (is_greeter) {
        // Nothing the greeter runs needs to gain privileges (power actions
        // ask logind over D-Bus), so no setuid/file-capability exec may.
        // User sessions keep them for sudo and pkexec.
        if (c.prctl(c.PR_SET_NO_NEW_PRIVS, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) linux.exit_group(1);
        const cmd = a.dupeZ(u8, exec) catch linux.exit_group(1);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr };
        _ = linux.execve("/bin/sh", &argv, env.ptr);
    } else {
        // A login shell reads the profile, and interprets Exec's quoting.
        const cmd = std.fmt.allocPrintSentinel(a, "exec {s}", .{exec}, 0) catch linux.exit_group(1);
        const argv = [_:null]?[*:0]const u8{ acct.shell.ptr, "-l", "-c", cmd.ptr };
        _ = linux.execve(acct.shell.ptr, &argv, env.ptr);
    }
    linux.exit_group(127);
}
