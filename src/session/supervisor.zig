//! Compositor lifetime for one login: readiness handshake, publication, a
//! bounded crash-restart loop, and teardown of everything the compositor left
//! behind. The supervisor is a child subreaper, so double-forked helpers stay
//! in its tree even after compositor failure.
const std = @import("std");
const c = std.c;
const proc = @import("../system_monitor/proc.zig");
const login_process = @import("platform").login_process;
const sys = @import("login_sys.zig");
const publication = @import("publication.zig");
const platform = @import("platform");

const Pid = std.posix.pid_t;
const Handle = platform.child.Handle;
const PidSet = proc.Tree;

const max_crashes = 5;
const crash_window_ms = 60_000;
const readiness_timeout_ms = 30_000;

/// Abort-like deaths restart; anything else ends the session.
const crash_signals = [_]std.posix.SIG{ .ILL, .ABRT, .BUS, .FPE, .SEGV };

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
    const previous_subreaper = try platform.process.childSubreaper();
    if (!previous_subreaper) try platform.process.setChildSubreaper(true);
    defer if (!previous_subreaper) platform.process.setChildSubreaper(false) catch {};

    var preexisting = try descendants(allocator, c.getpid());
    defer preexisting.deinit(allocator);

    var signals = try login_process.Signals.init();
    defer signals.deinit();

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
        _ = try sys.check(c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC, 0, &pair));
        const parent = pair[0];
        var parent_open = true;
        defer if (parent_open) sys.close(parent);
        const child = pair[1];
        if (locked) _ = sys.retry(c.sendto, .{ parent, lock_request, lock_request.len, std.posix.MSG.NOSIGNAL, null, 0 }) catch |err| {
            sys.close(child);
            sys.diagnostic("cannot restart the compositor locked ({t}); ending the session", .{err});
            return 1;
        };
        const pid = spawn(allocator, options.compositor, options.env, child, options.log_fd, &signals.old_mask) catch |err| {
            sys.close(child);
            return err;
        };
        sys.close(child);
        const process = try Handle.open(pid);

        var status: ?u32 = null;
        {
            defer {
                sys.close(parent);
                parent_open = false;
                status = stopGroup(allocator, pid, process, &preexisting);
                process.close();
                if (options.publication) |p| p.restore() catch |err| sys.diagnostic("activation cleanup pending: {t}", .{err});
            }
            stopping = try waitForExit(allocator, pid, parent, process, &signals, options.publication, &locked);
        }
        if (stopping) return 0;
        const raw = status orelse return 1;
        if (std.posix.W.IFSIGNALED(raw)) {
            const sig = std.posix.W.TERMSIG(raw);
            if (std.mem.indexOfScalar(std.posix.SIG, &crash_signals, sig) != null) continue;
            return @truncate(128 + @backingInt(sig));
        }
        return std.posix.W.EXITSTATUS(raw);
    }
    return 0;
}

/// Serves readiness handshakes and records lock reports until the compositor
/// exits (false) or the supervisor is asked to stop (true).
fn waitForExit(allocator: std.mem.Allocator, compositor: Pid, parent: i32, process: Handle, signals: *login_process.Signals, maybe_publication: anytype, locked: *bool) !bool {
    var deadline: ?i64 = sys.monotonicMs() + readiness_timeout_ms;
    var parent_open = true;
    var packet: [16384]u8 = undefined;
    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = process.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = signals.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (parent_open) parent else -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const timeout: i32 = if (deadline) |d| @intCast(@max(0, d - sys.monotonicMs())) else -1;
        const ready = try sys.retry(c.poll, .{ &fds, fds.len, timeout });
        if (ready == 0) {
            sys.diagnostic("compositor readiness timed out", .{});
            return false;
        }
        if (fds[0].revents != 0) {
            if (parent_open) drainLockReports(parent, locked);
            return false;
        }
        if (fds[1].revents != 0) {
            const sig = signals.next() orelse continue;
            if (sig == .CHLD) {
                reapAdopted(compositor);
                continue;
            }
            return true;
        }
        if (fds[2].revents == 0) continue;
        const n = sys.retry(c.recvfrom, .{ parent, &packet, packet.len, 0, null, null }) catch |err| switch (err) {
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
        _ = sys.retry(c.sendto, .{ parent, "ready", 5, std.posix.MSG.NOSIGNAL, null, 0 }) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionReset => return false,
            else => return err,
        };
        deadline = null;
    }
}

/// The supervisor is a child subreaper, so every orphan of the session (a
/// double-forked helper, an app whose launcher exited first) becomes its child
/// and stays a zombie until someone waits for it. Nothing did, so a day of use
/// left hundreds. Peek first (`NOWAIT`): the compositor's own status is
/// collected by `stopGroup` and must not be consumed here. A zombie compositor
/// can hide others behind it, but then the loop is already ending.
const reapAdopted = login_process.reapAdopted;

/// A compositor that locked and then crashed may die before its report is
/// read; what it left queued still decides how the next one starts.
fn drainLockReports(parent: i32, locked: *bool) void {
    var packet: [16]u8 = undefined;
    while (true) {
        const n = sys.retry(c.recvfrom, .{ parent, &packet, packet.len, std.posix.MSG.DONTWAIT, null, null }) catch return;
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

fn spawn(allocator: std.mem.Allocator, compositor: [:0]const u8, env: *std.process.Environ.Map, session_fd: i32, log_fd: i32, old_mask: *const std.posix.sigset_t) !Pid {
    var fd_text: [16]u8 = undefined;
    try env.put("REDIWM_SESSION_FD", try std.fmt.bufPrint(&fd_text, "{d}", .{session_fd}));
    const envp = try env.createPosixBlock(allocator, .{});
    defer envp.deinit(allocator);
    return login_process.spawn(compositor, envp.slice.ptr, session_fd, log_fd, old_mask);
}

const descendants = proc.descendants;

/// Holds process handles throughout so an exiting or reused PID can never
/// redirect a signal to an unrelated process. Returns the compositor's wait
/// status, or null when it is stuck in the kernel.
fn stopGroup(allocator: std.mem.Allocator, compositor: Pid, compositor_handle: Handle, preexisting: *const PidSet) ?u32 {
    var handles: std.AutoArrayHashMapUnmanaged(Pid, Handle) = .empty;
    defer {
        for (handles.values()) |handle| handle.close();
        handles.deinit(allocator);
    }
    collect(allocator, &handles, compositor, preexisting);
    send(&handles, compositor_handle, .TERM);
    // One bounded grace period, ended early once everything has exited.
    awaitExit(allocator, &handles, compositor_handle, 1000);
    collect(allocator, &handles, compositor, preexisting);
    send(&handles, compositor_handle, .KILL);
    awaitExit(allocator, &handles, compositor_handle, 2000);

    var status: u32 = 0;
    const reaped = sys.retry(c.wait4, .{ compositor, @as(*i32, @ptrCast(&status)), std.posix.W.NOHANG, null }) catch 0;
    for (handles.keys()) |pid| {
        var ignored: u32 = 0;
        _ = c.wait4(pid, @ptrCast(&ignored), std.posix.W.NOHANG, null);
    }
    if (reaped != compositor) {
        sys.diagnostic("killed compositor remains in kernel I/O; ending supervision", .{});
        return null;
    }
    return status;
}

fn collect(allocator: std.mem.Allocator, handles: *std.AutoArrayHashMapUnmanaged(Pid, Handle), compositor: Pid, preexisting: *const PidSet) void {
    var tree = descendants(allocator, c.getpid()) catch return;
    defer tree.deinit(allocator);
    for (tree.keys(), tree.values()) |pid, stamp| {
        if (pid == compositor or preexisting.contains(pid) or handles.contains(pid)) continue;
        const handle = Handle.open(pid) catch continue;
        if (!proc.treeIdentityMatches(pid, stamp)) {
            handle.close();
            continue;
        }
        handles.put(allocator, pid, handle) catch handle.close();
    }
}

fn send(handles: *const std.AutoArrayHashMapUnmanaged(Pid, Handle), compositor_handle: Handle, sig: std.posix.SIG) void {
    signalHandle(compositor_handle, sig);
    for (handles.values()) |handle| signalHandle(handle, sig);
}

fn signalHandle(handle: Handle, sig: std.posix.SIG) void {
    handle.signal(sig) catch |err| switch (err) {
        error.PermissionDenied => sys.diagnostic("privileged descendant must be stopped by the login owner", .{}),
        else => {},
    };
}

/// Waits for every handle to become readable (exited), up to `timeout_ms`.
fn awaitExit(allocator: std.mem.Allocator, handles: *const std.AutoArrayHashMapUnmanaged(Pid, Handle), compositor_handle: Handle, timeout_ms: i64) void {
    const fds = allocator.alloc(std.posix.pollfd, handles.count() + 1) catch return;
    defer allocator.free(fds);
    fds[0] = .{ .fd = compositor_handle.fd, .events = std.posix.POLL.IN, .revents = 0 };
    for (handles.values(), fds[1..]) |handle, *p| p.* = .{ .fd = handle.fd, .events = std.posix.POLL.IN, .revents = 0 };
    const deadline = sys.monotonicMs() + timeout_ms;
    while (true) {
        const remaining = deadline - sys.monotonicMs();
        if (remaining <= 0) return;
        _ = sys.retry(c.poll, .{ fds.ptr, @as(c.nfds_t, @intCast(fds.len)), @as(i32, @intCast(remaining)) }) catch return;
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
