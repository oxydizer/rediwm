//! The rediwm-dm daemon: one poll loop over a signalfd, a timerfd, the
//! greeter connection and the workers' control sockets. It never blocks on
//! the greeter (an untrusted peer) and never sleeps; waits are timers.
//!
//! Invariant: while the daemon runs there is always a greeter, a login in
//! hand-off, a running session, or a pending greeter restart. Whatever ends
//! (greeter, login worker, session) leads back to a greeter.
const std = @import("std");
const linux = std.os.linux;
const config_mod = @import("config.zig");
const vt_mod = @import("vt.zig");
const state_mod = @import("state.zig");
const proto = @import("proto.zig");
const dm_ipc = @import("dm_ipc");
const ws = @import("wayland_sessions");

const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("sys/mman.h");
});

const log = std.log.scoped(.rediwm_dm);

/// How long the greeter gets to exit after its session was accepted.
const handoff_timeout_ms = 5000;
/// After SIGTERM, how long before the greeter's worker is killed outright.
/// Longer than the worker's own escalation, so the worker can clean up.
const greeter_kill_ms = 10_000;
/// A greeter that lived this long resets the restart backoff.
const greeter_healthy_ms = 10_000;
const max_backoff_ms = 30_000;
/// An autologin session that ends sooner than this counts as crashed.
const autologin_crash_ms = 10_000;
/// Parsed greeter requests live here and are wiped after each one.
const scratch_len = 3 * proto.max_frame;

fn defaultUserValidator(user: []const u8, range: ws.UidRange) bool {
    var buf: [16384]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var res: ?*c.struct_passwd = null;
    var name_buf: [256:0]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{user}) catch return false;
    if (c.getpwnam_r(name_z.ptr, &pw, &buf, buf.len, &res) != 0 or res == null) return false;
    const shell = if (pw.pw_shell) |s| std.mem.span(s) else "";
    return ws.loginAccount(range, pw.pw_uid, shell);
}

/// `--test` accounts need not exist; PAM (a test stack) decides.
fn testUserValidator(user: []const u8, _: ws.UidRange) bool {
    return user.len > 0 and user.len < 256 and std.mem.indexOfAny(u8, user, ":/\x00 \t\r\n") == null;
}

const Worker = struct { pid: linux.pid_t, ctrl: c_int };
const WorkerKind = enum { greeter, login, autologin };
const Timer = enum { none, handoff_deadline, greeter_kill, greeter_restart };

pub const Daemon = struct {
    config: config_mod.Config,
    io: std.Io,
    gpa: std.mem.Allocator = std.heap.c_allocator,
    is_test: bool = false,
    confdir: ?[]const u8 = null,
    marker_path: []const u8 = "/run/rediwm-dm/autologin-done",
    search_dirs: []const []const u8 = ws.standard_data_dirs,
    range: ws.UidRange = .{},
    relay: state_mod.Relay,

    children: @import("child_set") = .{},
    signal_fd: i32 = -1,
    timer_fd: i32 = -1,
    timer: Timer = .none,
    scratch: []u8 = &.{},

    greeter: ?Worker = null,
    greeter_conn: ?*dm_ipc.Client = null,
    greeter_started_at: i64 = 0,
    greeter_backoff_ms: u32 = 0,

    user: ?Worker = null,
    user_autologin: bool = false,
    session_running: bool = false,
    session_started_at: i64 = 0,
    autologin_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    autologin_session: ?ws.Session = null,

    /// `start` accepted: waiting for the greeter to exit before the session.
    handoff: bool = false,
    stopping: bool = false,

    pub fn init(config: config_mod.Config, io: std.Io, is_test: bool, confdir: ?[]const u8) Daemon {
        return .{
            .config = config,
            .io = io,
            .is_test = is_test,
            .confdir = confdir,
            .relay = .init(std.heap.c_allocator),
        };
    }

    fn validUser(self: *const Daemon, user: []const u8) bool {
        return if (self.is_test) testUserValidator(user, self.range) else defaultUserValidator(user, self.range);
    }

    pub fn run(self: *Daemon) !void {
        if (!self.is_test) {
            vt_mod.activate(self.config.vt) catch |err| log.warn("cannot activate VT {d}: {}", .{ self.config.vt, err });
            self.blankVt();
            self.range = ws.readLoginDefs(self.io);
        }

        defer self.children.deinit(self.gpa);
        var mask = linux.sigemptyset();
        for ([_]linux.SIG{ .TERM, .INT }) |sig| linux.sigaddset(&mask, sig);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
        self.signal_fd = @intCast(try check(linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)));
        defer _ = linux.close(self.signal_fd);
        self.timer_fd = @intCast(try check(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true })));
        defer _ = linux.close(self.timer_fd);

        self.scratch = try self.gpa.alloc(u8, scratch_len);
        _ = c.mlock(self.scratch.ptr, self.scratch.len);
        defer {
            std.crypto.secureZero(u8, self.scratch);
            self.gpa.free(self.scratch);
        }
        defer self.relay.deinit();
        defer self.autologin_arena.deinit();

        if (!self.tryAutologin()) self.startGreeter();

        while (true) {
            var fds: [6]linux.pollfd = undefined;
            var n: usize = 0;
            for ([_]c_int{
                self.signal_fd,
                self.timer_fd,
                if (self.greeter_conn) |conn| conn.fd else -1,
                if (self.greeter) |g| g.ctrl else -1,
                if (self.user) |u| u.ctrl else -1,
                self.children.fd,
            }) |fd| {
                fds[n] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            }
            const rc = linux.poll(&fds, n, -1);
            if (linux.errno(rc) == .INTR) continue;
            _ = try check(rc);

            if (fds[0].revents != 0 and self.handleSignals()) {
                self.stopAll();
                return;
            }
            if (fds[1].revents != 0) self.handleTimer();
            if (fds[5].revents != 0) self.handleExits();
            // Earlier handlers may have closed or replaced these; only act
            // on the fd that was polled.
            if (fds[2].revents != 0) if (self.greeter_conn) |conn| if (conn.fd == fds[2].fd) self.pumpGreeter();
            if (fds[3].revents != 0) if (self.greeter) |g| if (g.ctrl == fds[3].fd) self.pumpGreeterWorker();
            if (fds[4].revents != 0) if (self.user) |u| if (u.ctrl == fds[4].fd) self.pumpUserWorker();
        }
    }

    // ---- autologin -------------------------------------------------------

    /// Starts the configured autologin once per boot. False: show the greeter.
    fn tryAutologin(self: *Daemon) bool {
        const user = self.config.autologin_user orelse return false;
        const session = self.config.autologin_session orelse return false;
        const validator: *const fn ([]const u8, ws.UidRange) bool = if (self.is_test) &testUserValidator else &defaultUserValidator;
        const decision = state_mod.checkAutologin(self.io, self.marker_path, user, session, self.search_dirs, self.range, validator);
        if (decision != .proceed) {
            log.info("skipping autologin: {t}", .{decision});
            return false;
        }
        self.autologin_session = (ws.lookupSession(self.autologin_arena.allocator(), self.io, session, self.search_dirs) catch null) orelse return false;
        // Before the attempt, so a crash can never loop back into it.
        self.createMarker();
        self.startWorker(.autologin, user) catch |err| {
            log.err("cannot start autologin: {}", .{err});
            return false;
        };
        log.info("autologin for '{s}' into '{s}'", .{ user, session });
        return true;
    }

    fn createMarker(self: *Daemon) void {
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.marker_path)) |dir| cwd.createDirPath(self.io, dir) catch {};
        cwd.writeFile(self.io, .{ .sub_path = self.marker_path, .data = "autologin done\n" }) catch |err|
            log.warn("cannot create autologin marker: {}", .{err});
    }

    // ---- workers ---------------------------------------------------------

    fn startGreeter(self: *Daemon) void {
        std.debug.assert(self.greeter == null);
        self.startWorker(.greeter, self.config.greeter_user) catch |err| {
            log.err("cannot start the greeter: {}", .{err});
            self.scheduleGreeterRestart();
        };
    }

    fn startWorker(self: *Daemon, kind: WorkerKind, user: []const u8) !void {
        // [0] stays here, [1] goes to the worker.
        var fds = [4]i32{ -1, -1, -1, -1 };
        errdefer for (fds) |fd| if (fd >= 0) {
            _ = linux.close(fd);
        };
        _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, fds[0..2]));
        if (kind == .greeter) _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, fds[2..4]));
        const client: ?*dm_ipc.Client = if (kind == .greeter) try self.gpa.create(dm_ipc.Client) else null;
        errdefer if (client) |cl| self.gpa.destroy(cl);

        const pid: linux.pid_t = @intCast(try check(linux.fork()));
        if (pid == 0) self.execWorker(fds[1], fds[3]);
        var reaped = false;
        errdefer if (!reaped) {
            _ = linux.kill(pid, .KILL);
        };
        for ([_]usize{ 1, 3 }) |i| if (fds[i] >= 0) {
            _ = linux.close(fds[i]);
            fds[i] = -1;
        };

        self.children.add(self.gpa, pid) catch |err| {
            _ = linux.kill(pid, .KILL);
            var status: u32 = 0;
            while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
            reaped = true;
            return err;
        };
        const worker: Worker = .{ .pid = pid, .ctrl = fds[0] };
        var buf: [1024]u8 = undefined;
        try proto.writeJson(worker.ctrl, &buf, proto.Init{
            .service = switch (kind) {
                .greeter => "rediwm-greeter",
                .login => "rediwm-dm",
                .autologin => "rediwm-dm-autologin",
            },
            .user = user,
            .vt = self.config.vt,
            .class = if (kind == .greeter) "greeter" else "user",
        });
        const conn = fds[2];
        fds = .{ -1, -1, -1, -1 };

        switch (kind) {
            .greeter => {
                const cl = client.?;
                cl.* = .fromFd(conn);
                _ = c.mlock(&cl.buf, cl.buf.len);
                self.greeter = worker;
                self.greeter_conn = cl;
                self.relay.greeter_fd = conn;
                self.greeter_started_at = monotonicMs();
            },
            .login, .autologin => {
                self.user = worker;
                self.user_autologin = kind == .autologin;
                self.relay.worker_fd = worker.ctrl;
            },
        }
    }

    /// The forked child: becomes `rediwm-dm --worker`. Only the fds passed on
    /// the command line survive the exec.
    fn execWorker(self: *Daemon, ctrl_fd: i32, greeter_fd: i32) noreturn {
        const empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
        _ = linux.fcntl(ctrl_fd, linux.F.SETFD, 0);
        if (greeter_fd >= 0) _ = linux.fcntl(greeter_fd, linux.F.SETFD, 0);

        var ctrl_buf: [16]u8 = undefined;
        var greeter_buf: [16]u8 = undefined;
        var confdir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var args: [8:null]?[*:0]const u8 = @splat(null);
        var n: usize = 0;
        for ([_]?[*:0]const u8{
            "rediwm-dm",
            "--worker",
            (std.fmt.bufPrintZ(&ctrl_buf, "{d}", .{ctrl_fd}) catch linux.exit_group(1)).ptr,
        }) |arg| {
            args[n] = arg;
            n += 1;
        }
        if (greeter_fd >= 0) {
            args[n] = "--greeter-fd";
            args[n + 1] = (std.fmt.bufPrintZ(&greeter_buf, "{d}", .{greeter_fd}) catch linux.exit_group(1)).ptr;
            n += 2;
        }
        if (self.confdir) |dir| {
            args[n] = "--confdir";
            args[n + 1] = (std.fmt.bufPrintZ(&confdir_buf, "{s}", .{dir}) catch linux.exit_group(1)).ptr;
            n += 2;
        }
        if (self.is_test) args[n] = "--test";
        _ = linux.execve("/proc/self/exe", &args, @ptrCast(std.c.environ));
        linux.exit_group(127);
    }

    // ---- greeter connection ------------------------------------------------

    fn pumpGreeter(self: *Daemon) void {
        const conn = self.greeter_conn orelse return;
        conn.fill() catch |err| {
            if (err != error.Disconnected) log.warn("greeter read failed: {}", .{err});
            return self.dropGreeter(null);
        };
        while (self.greeter_conn == conn) {
            const payload = (conn.frame() catch return self.dropGreeter("oversized frame")) orelse return;
            self.handleGreeterFrame(payload);
            if (self.greeter_conn != conn) return;
            conn.consume(payload);
        }
    }

    fn handleGreeterFrame(self: *Daemon, payload: []const u8) void {
        // The request may hold a password: parse it into locked scratch
        // memory and wipe that before returning.
        var fba: std.heap.FixedBufferAllocator = .init(self.scratch);
        defer std.crypto.secureZero(u8, self.scratch);
        const parsed = dm_ipc.parseRequest(fba.allocator(), payload) catch return self.dropGreeter("unreadable request");
        const action = self.relay.handleGreeterRequest(parsed.request, self.io, self.search_dirs) catch |err| {
            log.warn("cannot answer the greeter: {}", .{err});
            return self.dropGreeter(null);
        };
        switch (action) {
            .none => {},
            .spawn_login => self.beginLogin(parsed.request.login),
            .kill_worker => self.killLogin(),
            .handoff => self.beginHandoff(),
            .drop_greeter => self.dropGreeter("request out of order"),
        }
    }

    fn beginLogin(self: *Daemon, user: []const u8) void {
        std.debug.assert(self.user == null);
        if (!self.validUser(user)) {
            self.relay.phase = .idle;
            self.relay.reply(.{ .denied = "Unknown account" }) catch self.dropGreeter(null);
            return;
        }
        self.startWorker(.login, user) catch |err| {
            log.err("cannot start a login worker: {}", .{err});
            self.relay.phase = .idle;
            self.relay.reply(.{ .failed = "Could not start the login process." }) catch self.dropGreeter(null);
        };
    }

    /// Abandons a login that has not started its session. Its worker is
    /// killed and forgotten; its exit is reaped like any other child.
    fn killLogin(self: *Daemon) void {
        const worker = self.user orelse return;
        if (self.session_running) return;
        _ = linux.close(worker.ctrl);
        _ = linux.kill(worker.pid, .TERM);
        self.user = null;
        self.user_autologin = false;
        self.relay.worker_fd = -1;
    }

    fn closeGreeterConn(self: *Daemon) void {
        const conn = self.greeter_conn orelse return;
        conn.close();
        std.crypto.secureZero(u8, &conn.buf);
        _ = c.munlock(&conn.buf, conn.buf.len);
        self.gpa.destroy(conn);
        self.greeter_conn = null;
        self.relay.greeter_fd = -1;
    }

    /// The greeter hung up, broke the protocol, or cannot be answered: its
    /// connection cannot be re-established, so replace the greeter.
    fn dropGreeter(self: *Daemon, reason: ?[]const u8) void {
        if (reason) |r| log.warn("dropping the greeter: {s}", .{r});
        self.closeGreeterConn();
        if (self.handoff) return;
        self.killLogin();
        self.relay.reset();
        self.stopGreeter();
    }

    fn blankVt(self: *Daemon) void {
        if (self.is_test) return;
        vt_mod.blank(self.config.vt) catch |err| log.debug("cannot blank VT {d}: {}", .{ self.config.vt, err });
    }

    fn stopGreeter(self: *Daemon) void {
        const greeter = self.greeter orelse return;
        _ = linux.kill(greeter.pid, .TERM);
        self.arm(.greeter_kill, greeter_kill_ms);
    }

    // ---- hand-off: greeter out, session in -------------------------------

    fn beginHandoff(self: *Daemon) void {
        // Blank while the greeter still covers the VT, so logind's switch
        // back to text mode shows nothing.
        self.blankVt();
        self.closeGreeterConn();
        self.handoff = true;
        if (self.greeter == null) return self.finishHandoff();
        self.arm(.handoff_deadline, handoff_timeout_ms);
    }

    fn finishHandoff(self: *Daemon) void {
        self.handoff = false;
        if (self.timer == .handoff_deadline or self.timer == .greeter_kill) self.arm(.none, 0);
        defer self.relay.reset();
        const worker = self.user orelse {
            log.warn("the login ended before its session could start", .{});
            return self.startGreeter();
        };
        const session = self.relay.session orelse unreachable;
        // Again, for anything the console printed during the hand-off.
        self.blankVt();
        self.sendStart(worker, session.exec, session.id, session.desktops) catch |err| {
            log.err("cannot start the session: {}", .{err});
            self.killLogin();
            self.startGreeter();
        };
    }

    fn sendStart(_: *Daemon, worker: Worker, exec: []const u8, desktop: []const u8, desktops: []const u8) !void {
        var buf: [proto.max_frame]u8 = undefined;
        try proto.writeJson(worker.ctrl, &buf, proto.Start{ .exec = exec, .desktop = desktop, .desktops = desktops });
    }

    // ---- worker reports ------------------------------------------------------

    fn pumpGreeterWorker(self: *Daemon) void {
        const worker = self.greeter orelse return;
        var buf: [proto.max_frame]u8 = undefined;
        const payload = proto.readFrame(worker.ctrl, &buf) catch {
            // The exit itself makes the pidfd readable.
            _ = linux.close(worker.ctrl);
            self.greeter.?.ctrl = -1;
            return;
        };
        if (payload.len == 0) return;
        const text = payload[1..];
        switch (@as(proto.Report, @enumFromInt(payload[0]))) {
            .auth_ok => self.sendStart(worker, self.config.greeter_command, "", "") catch |err|
                log.err("cannot start the greeter: {}", .{err}),
            .denied, .failed => log.err("cannot open the greeter account '{s}': {s}", .{ self.config.greeter_user, text }),
            .session_failed => log.err("cannot open the greeter session: {s}", .{text}),
            .session_ended => log.info("greeter exited (wait status {s})", .{text}),
            else => {},
        }
    }

    fn pumpUserWorker(self: *Daemon) void {
        const worker = self.user orelse return;
        var buf: [proto.max_frame]u8 = undefined;
        const payload = proto.readFrame(worker.ctrl, &buf) catch {
            _ = linux.close(worker.ctrl);
            self.user.?.ctrl = -1;
            self.relay.worker_fd = -1;
            return;
        };
        if (payload.len == 0) return;
        const text = payload[1..];
        switch (@as(proto.Report, @enumFromInt(payload[0]))) {
            .session_started => {
                self.session_running = true;
                self.session_started_at = monotonicMs();
            },
            .session_failed => log.err("cannot open the session: {s}", .{text}),
            .session_ended => log.info("session ended (wait status {s})", .{text}),
            else => if (self.user_autologin) {
                if (payload[0] == @intFromEnum(proto.Report.auth_ok)) {
                    const session = self.autologin_session.?;
                    self.sendStart(worker, session.exec, session.id, session.desktops) catch |err|
                        log.err("cannot start the autologin session: {}", .{err});
                } else log.err("autologin refused: {s}", .{text});
            } else self.relay.handleWorkerMessage(payload) catch |err| {
                log.warn("unexpected login worker report: {}", .{err});
                self.killLogin();
                self.dropGreeter(null);
            },
        }
    }

    // ---- exits, signals and timers ---------------------------------------

    /// True when the daemon should stop.
    fn handleSignals(self: *Daemon) bool {
        var info: linux.signalfd_siginfo = undefined;
        var stop = false;
        while (linux.errno(linux.read(self.signal_fd, std.mem.asBytes(&info).ptr, @sizeOf(linux.signalfd_siginfo))) == .SUCCESS) {
            log.info("received signal {d}, stopping", .{info.signo});
            stop = true;
        }
        return stop;
    }

    fn handleExits(self: *Daemon) void {
        while (self.children.next()) |exit| {
            if (self.greeter) |g| if (g.pid == exit.pid) self.greeterExited();
            if (self.user) |u| if (u.pid == exit.pid) self.userExited();
        }
    }

    fn greeterExited(self: *Daemon) void {
        if (self.greeter.?.ctrl >= 0) _ = linux.close(self.greeter.?.ctrl);
        self.greeter = null;
        self.closeGreeterConn();
        if (self.timer == .greeter_kill) self.arm(.none, 0);
        if (self.stopping) return;
        if (self.handoff) return self.finishHandoff();

        // Unrequested exit: a crash, or a greeter we dropped.
        self.killLogin();
        self.relay.reset();
        if (self.session_running) return;
        if (monotonicMs() - self.greeter_started_at >= greeter_healthy_ms) self.greeter_backoff_ms = 0;
        self.scheduleGreeterRestart();
    }

    fn scheduleGreeterRestart(self: *Daemon) void {
        const delay = self.greeter_backoff_ms;
        self.greeter_backoff_ms = @min(@max(1000, delay * 2), max_backoff_ms);
        if (delay == 0) return self.startGreeter();
        log.warn("restarting the greeter in {d} ms", .{delay});
        self.arm(.greeter_restart, delay);
    }

    fn userExited(self: *Daemon) void {
        const worker = self.user.?;
        if (worker.ctrl >= 0) _ = linux.close(worker.ctrl);
        self.user = null;
        self.relay.worker_fd = -1;
        const was_session = self.session_running;
        const was_autologin = self.user_autologin;
        self.session_running = false;
        self.user_autologin = false;
        if (self.stopping or self.handoff) return;

        if (was_session and was_autologin and monotonicMs() - self.session_started_at < autologin_crash_ms)
            log.err("autologin session ended within {d} ms; showing the greeter", .{autologin_crash_ms});
        if (!was_session) switch (self.relay.phase) {
            // The greeter is waiting for an answer that will not come.
            .authenticating => {
                self.relay.phase = .idle;
                self.relay.reply(.{ .failed = "The login process ended unexpectedly." }) catch self.dropGreeter(null);
            },
            .prompting, .authenticated => self.dropGreeter("login worker died"),
            .idle, .starting => {},
        };
        if (self.greeter == null and self.timer != .greeter_restart) {
            if (!self.is_test) vt_mod.activate(self.config.vt) catch {};
            self.blankVt();
            self.startGreeter();
        }
    }

    fn handleTimer(self: *Daemon) void {
        var expirations: u64 = 0;
        _ = linux.read(self.timer_fd, std.mem.asBytes(&expirations).ptr, 8);
        const fired = self.timer;
        self.timer = .none;
        switch (fired) {
            .none => {},
            .handoff_deadline => {
                log.warn("the greeter did not exit after sign-in; stopping it", .{});
                self.stopGreeter();
            },
            .greeter_kill => if (self.greeter) |g| {
                log.warn("the greeter's worker ignored SIGTERM; killing it", .{});
                _ = linux.kill(g.pid, .KILL);
            },
            .greeter_restart => if (self.greeter == null and !self.handoff) self.startGreeter(),
        }
    }

    fn arm(self: *Daemon, timer: Timer, ms: u32) void {
        self.timer = timer;
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
    }

    /// Stops every worker (each ends its own session first) and waits for
    /// them, killing any that outlast the grace period.
    fn stopAll(self: *Daemon) void {
        self.stopping = true;
        self.closeGreeterConn();
        self.children.signalAll(.TERM);
        const deadline = monotonicMs() + greeter_kill_ms;
        while (self.children.entries.items.len > 0) {
            self.handleExits();
            if (self.children.entries.items.len == 0) break;
            const remaining = deadline - monotonicMs();
            if (remaining <= 0) {
                self.children.signalAll(.KILL);
                break;
            }
            var fds = [_]linux.pollfd{.{ .fd = self.children.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, @intCast(remaining));
        }
    }
};

fn check(rc: usize) !usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => |err| {
            log.err("system call failed: {t}", .{err});
            return error.SystemCallFailed;
        },
    };
}

fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
