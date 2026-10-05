//! Compositor lifetime for one login: readiness handshake, publication, a
//! bounded crash-restart loop, and teardown of everything the compositor left
//! behind. The supervisor is a child subreaper, so double-forked helpers stay
//! in its tree even after compositor failure.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("login_sys.zig");
const publication = @import("publication.zig");

const Pid = linux.pid_t;
const PidSet = std.AutoArrayHashMapUnmanaged(Pid, void);

const max_crashes = 5;
const crash_window_ms = 60_000;
const readiness_timeout_ms = 30_000;

/// Abort-like deaths restart; anything else ends the session.
const crash_signals = [_]linux.SIG{ .ILL, .ABRT, .BUS, .FPE, .SEGV };

/// Queued ahead of everything else for a compositor whose predecessor crashed
/// while locked; `session/activation.zig` takes it before readiness.
const lock_request = "lock";

/// The compositor's lock reports, sent whenever the session locks or unlocks.
fn lockReport(packet: []const u8) ?bool {
    if (std.mem.eql(u8, packet, "locked")) return true;
    if (std.mem.eql(u8, packet, "unlocked")) return false;
    return null;
}

pub fn Options(comptime Publication: type) type {
    return struct {
        allocator: std.mem.Allocator,
        compositor: [:0]const u8,
        env: *std.process.Environ.Map,
        log_fd: i32,
        publication: ?*Publication,
    };
}

pub fn supervise(comptime Publication: type, options: Options(Publication)) !u8 {
    const allocator = options.allocator;
    var previous_subreaper: c_int = 0;
    _ = try sys.check(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&previous_subreaper), 0, 0, 0));
    _ = try sys.check(linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0));
    defer _ = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), @intCast(previous_subreaper), 0, 0, 0);

    var preexisting = try descendants(allocator, linux.getpid());
    defer preexisting.deinit(allocator);

    // Logout signals arrive through a signalfd; the child gets the old mask back.
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, .TERM);
    linux.sigaddset(&mask, .INT);
    var old_mask: linux.sigset_t = undefined;
    _ = try sys.check(linux.sigprocmask(linux.SIG.BLOCK, &mask, &old_mask));
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
    const signal_fd: i32 = @intCast(try sys.check(linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)));
    defer sys.close(signal_fd);

    var attempts: std.ArrayList(i64) = .empty;
    defer attempts.deinit(allocator);
    // A crash must never unlock the session: whoever is at the keyboard
    // would otherwise get the desktop back without a password.
    var locked = false;
    var stopping = false;
    while (!stopping) {
        const now = sys.monotonicMs();
        var kept: usize = 0;
        for (attempts.items) |stamp| {
            if (now - stamp < crash_window_ms) {
                attempts.items[kept] = stamp;
                kept += 1;
            }
        }
        attempts.items.len = kept;
        if (attempts.items.len == max_crashes) {
            sys.diagnostic("{d} crashes within 60s, giving up", .{max_crashes});
            return 1;
        }
        if (attempts.items.len > 0) sys.diagnostic("restart {d}/{d} after compositor crash", .{ attempts.items.len + 1, max_crashes });
        try attempts.append(allocator, now);

        var pair: [2]i32 = undefined;
        _ = try sys.check(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &pair));
        const parent = pair[0];
        var parent_open = true;
        defer if (parent_open) sys.close(parent);
        const child = pair[1];
        if (locked) _ = sys.retry(linux.sendto, .{ parent, lock_request, lock_request.len, linux.MSG.NOSIGNAL, null, 0 }) catch |err| {
            sys.close(child);
            sys.diagnostic("cannot restart the compositor locked ({t}); ending the session", .{err});
            return 1;
        };
        const pid = spawn(allocator, options.compositor, options.env, child, options.log_fd, &old_mask) catch |err| {
            sys.close(child);
            return err;
        };
        sys.close(child);
        const pidfd: i32 = @intCast(try sys.check(linux.pidfd_open(pid, 0)));

        var status: ?u32 = null;
        {
            defer {
                sys.close(parent);
                parent_open = false;
                status = stopGroup(allocator, pid, pidfd, &preexisting);
                sys.close(pidfd);
                if (options.publication) |p| p.restore() catch |err| sys.diagnostic("activation cleanup pending: {t}", .{err});
            }
            stopping = try waitForExit(allocator, parent, pidfd, signal_fd, options.publication, &locked);
        }
        if (stopping) return 0;
        const raw = status orelse return 1;
        if (linux.W.IFSIGNALED(raw)) {
            const sig = linux.W.TERMSIG(raw);
            if (std.mem.indexOfScalar(linux.SIG, &crash_signals, sig) != null) continue;
            return @truncate(128 + @intFromEnum(sig));
        }
        return linux.W.EXITSTATUS(raw);
    }
    return 0;
}

/// Serves readiness handshakes and records lock reports until the compositor
/// exits (false) or the supervisor is asked to stop (true).
fn waitForExit(allocator: std.mem.Allocator, parent: i32, pidfd: i32, signal_fd: i32, maybe_publication: anytype, locked: *bool) !bool {
    var deadline: ?i64 = sys.monotonicMs() + readiness_timeout_ms;
    var parent_open = true;
    var packet: [16384]u8 = undefined;
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = signal_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (parent_open) parent else -1, .events = linux.POLL.IN, .revents = 0 },
        };
        const timeout: i32 = if (deadline) |d| @intCast(@max(0, d - sys.monotonicMs())) else -1;
        const ready = try sys.retry(linux.poll, .{ &fds, fds.len, timeout });
        if (ready == 0) {
            sys.diagnostic("compositor readiness timed out", .{});
            return false;
        }
        if (fds[0].revents != 0) {
            if (parent_open) drainLockReports(parent, locked);
            return false;
        }
        if (fds[1].revents != 0) {
            var info: linux.signalfd_siginfo = undefined;
            _ = linux.read(signal_fd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
            return true;
        }
        if (fds[2].revents == 0) continue;
        const n = sys.retry(linux.recvfrom, .{ parent, &packet, packet.len, 0, null, null }) catch |err| switch (err) {
            error.ConnectionReset => return false,
            else => return err,
        };
        if (n == 0) {
            parent_open = false;
            continue;
        }
        if (lockReport(packet[0..n])) |state| {
            locked.* = state;
            continue;
        }
        if (maybe_publication) |p| publish(allocator, p, packet[0..n]);
        _ = sys.retry(linux.sendto, .{ parent, "ready", 5, linux.MSG.NOSIGNAL, null, 0 }) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionReset => return false,
            else => return err,
        };
        deadline = null;
    }
}

/// A compositor that locked and then crashed may die before its report is
/// read; what it left queued still decides how the next one starts.
fn drainLockReports(parent: i32, locked: *bool) void {
    var packet: [16]u8 = undefined;
    while (true) {
        const n = sys.retry(linux.recvfrom, .{ parent, &packet, packet.len, linux.MSG.DONTWAIT, null, null }) catch return;
        if (n == 0) return;
        if (lockReport(packet[0..n])) |state| locked.* = state;
    }
}

/// Publication failures never block direct launches: the ack is sent regardless.
fn publish(allocator: std.mem.Allocator, p: anytype, packet: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const values = parseReadiness(arena.allocator(), packet) catch |err| {
        sys.diagnostic("activation unavailable: invalid readiness message ({t}); direct launches remain usable", .{err});
        return;
    };
    p.publish(values) catch |err| {
        sys.diagnostic("activation unavailable: {t}; direct launches remain usable", .{err});
        p.restore() catch |cleanup| sys.diagnostic("activation rollback pending: {t}", .{cleanup});
    };
}

fn parseReadiness(arena: std.mem.Allocator, packet: []const u8) ![]publication.Pair {
    const parsed = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), arena, packet, .{ .allocate = .alloc_always });
    const out = try arena.alloc(publication.Pair, parsed.map.count());
    for (parsed.map.keys(), parsed.map.values(), out) |key, value, *pair| pair.* = .{ .key = key, .value = value };
    return out;
}

fn spawn(allocator: std.mem.Allocator, compositor: [:0]const u8, env: *std.process.Environ.Map, session_fd: i32, log_fd: i32, old_mask: *const linux.sigset_t) !Pid {
    var fd_text: [16]u8 = undefined;
    try env.put("REDIWM_SESSION_FD", try std.fmt.bufPrint(&fd_text, "{d}", .{session_fd}));
    const envp = try env.createPosixBlock(allocator, .{});
    defer envp.deinit(allocator);
    const argv = [_:null]?[*:0]const u8{compositor.ptr};

    const rc = try sys.check(linux.fork());
    if (rc == 0) {
        // Only raw syscalls between fork and exec.
        _ = linux.setsid();
        _ = linux.dup2(log_fd, 1);
        _ = linux.dup2(log_fd, 2);
        // The readiness fd is the only descriptor the compositor inherits.
        _ = linux.fcntl(session_fd, linux.F.SETFD, 0);
        const default: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.PIPE, &default, null);
        _ = linux.sigprocmask(linux.SIG.SETMASK, old_mask, null);
        _ = linux.execve(compositor.ptr, &argv, envp.slice.ptr);
        linux.exit_group(127);
    }
    return @intCast(rc);
}

/// The owned process tree, read from /proc at teardown, including adopted children.
fn descendants(allocator: std.mem.Allocator, root: Pid) !PidSet {
    var result: PidSet = .empty;
    errdefer result.deinit(allocator);
    var pending: std.ArrayList(Pid) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, root);
    var path_buf: [64]u8 = undefined;
    var dirents: [4096]u8 align(8) = undefined;
    while (pending.pop()) |pid| {
        const task_path = try std.fmt.bufPrintZ(&path_buf, "/proc/{d}/task", .{pid});
        const dir = sys.openZ(task_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch continue;
        defer sys.close(dir);
        while (true) {
            const n = sys.check(linux.getdents64(dir, &dirents, dirents.len)) catch break;
            if (n == 0) break;
            var offset: usize = 0;
            while (offset < n) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&dirents[offset]);
                offset += entry.reclen;
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (name[0] == '.') continue;
                var children_path: [96]u8 = undefined;
                const file = std.fmt.bufPrintZ(&children_path, "/proc/{d}/task/{s}/children", .{ pid, name }) catch continue;
                const fd = sys.openZ(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch continue;
                defer sys.close(fd);
                const text = sys.readAll(allocator, fd) catch continue;
                defer allocator.free(text);
                var it = std.mem.tokenizeScalar(u8, text, ' ');
                while (it.next()) |token| {
                    const child = std.fmt.parseInt(Pid, std.mem.trim(u8, token, "\n"), 10) catch continue;
                    const gop = try result.getOrPut(allocator, child);
                    if (!gop.found_existing) try pending.append(allocator, child);
                }
            }
        }
    }
    return result;
}

/// Holds pidfds throughout so an exiting or reused PID can never redirect a
/// signal to an unrelated process. Returns the compositor's wait status, or
/// null when it is stuck in the kernel.
fn stopGroup(allocator: std.mem.Allocator, compositor: Pid, compositor_fd: i32, preexisting: *const PidSet) ?u32 {
    var handles: std.AutoArrayHashMapUnmanaged(Pid, i32) = .empty;
    defer {
        for (handles.values()) |fd| sys.close(fd);
        handles.deinit(allocator);
    }
    collect(allocator, &handles, compositor, preexisting);
    send(&handles, compositor_fd, .TERM);
    // One bounded grace period, ended early once everything has exited.
    awaitExit(allocator, &handles, compositor_fd, 1000);
    collect(allocator, &handles, compositor, preexisting);
    send(&handles, compositor_fd, .KILL);
    awaitExit(allocator, &handles, compositor_fd, 2000);

    var status: u32 = 0;
    const reaped = sys.retry(linux.wait4, .{ compositor, &status, linux.W.NOHANG, null }) catch 0;
    for (handles.keys()) |pid| {
        var ignored: u32 = 0;
        _ = linux.wait4(pid, &ignored, linux.W.NOHANG, null);
    }
    if (reaped != compositor) {
        sys.diagnostic("killed compositor remains in kernel I/O; leaving it to logind teardown", .{});
        return null;
    }
    return status;
}

fn collect(allocator: std.mem.Allocator, handles: *std.AutoArrayHashMapUnmanaged(Pid, i32), compositor: Pid, preexisting: *const PidSet) void {
    var tree = descendants(allocator, linux.getpid()) catch return;
    defer tree.deinit(allocator);
    for (tree.keys()) |pid| {
        if (pid == compositor or preexisting.contains(pid) or handles.contains(pid)) continue;
        const rc = linux.pidfd_open(pid, 0);
        if (linux.errno(rc) != .SUCCESS) continue;
        handles.put(allocator, pid, @intCast(rc)) catch sys.close(@intCast(rc));
    }
}

fn send(handles: *const std.AutoArrayHashMapUnmanaged(Pid, i32), compositor_fd: i32, sig: linux.SIG) void {
    signalPidfd(compositor_fd, sig);
    for (handles.values()) |fd| signalPidfd(fd, sig);
}

fn signalPidfd(fd: i32, sig: linux.SIG) void {
    switch (linux.errno(linux.pidfd_send_signal(fd, sig, null, 0))) {
        .PERM => sys.diagnostic("privileged descendant must be stopped by logind session teardown", .{}),
        else => {},
    }
}

/// Waits for every pidfd to become readable (exited), up to `timeout_ms`.
fn awaitExit(allocator: std.mem.Allocator, handles: *const std.AutoArrayHashMapUnmanaged(Pid, i32), compositor_fd: i32, timeout_ms: i64) void {
    const fds = allocator.alloc(linux.pollfd, handles.count() + 1) catch return;
    defer allocator.free(fds);
    fds[0] = .{ .fd = compositor_fd, .events = linux.POLL.IN, .revents = 0 };
    for (handles.values(), fds[1..]) |fd, *p| p.* = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    const deadline = sys.monotonicMs() + timeout_ms;
    while (true) {
        const remaining = deadline - sys.monotonicMs();
        if (remaining <= 0) return;
        _ = sys.retry(linux.poll, .{ fds.ptr, fds.len, @as(i32, @intCast(remaining)) }) catch return;
        // An exited process stays readable; stop watching it.
        var live = false;
        for (fds) |*p| {
            if (p.revents != 0) p.fd = -1;
            if (p.fd >= 0) live = true;
        }
        if (!live) return;
    }
}

test "readiness packets decode to allowlist candidates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const values = try parseReadiness(arena.allocator(), "{\"WAYLAND_DISPLAY\":\"wayland-1\",\"PATH\":\"/bin\"}");
    try std.testing.expectEqual(2, values.len);
    try std.testing.expectEqualStrings("WAYLAND_DISPLAY", values[0].key);
    try std.testing.expectEqualStrings("wayland-1", values[0].value);
    try std.testing.expectError(error.UnexpectedToken, parseReadiness(arena.allocator(), "{\"PATH\":1}"));
}
