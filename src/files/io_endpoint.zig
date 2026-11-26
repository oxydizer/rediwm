//! The Files process's private endpoint (architecture §13, stage S6).
//!
//! One Files process per Wayland display serves a Unix stream socket in the
//! runtime directory. A launch of Files first tries it (`claim`): when a
//! process answers, the launch is handed over as `OpenWindow` and the
//! launcher exits; otherwise the launch becomes that process. The socket name
//! carries a hash of `WAYLAND_DISPLAY`, so a nested session has its own Files,
//! and it stays outside the compositor's `rediwm-*.sock` discovery. A lock
//! file serialises the decision, as for the editor (`editor/instance.zig`).
//!
//! The endpoint thread owns the listening socket and every connection, all
//! non-blocking. It never touches the Manager, a window or the display. An
//! accepted `OpenWindow` goes to the UI thread through a small ring and a
//! wake descriptor (`takeOpen`, `openWakeFd`); the UI thread opens the window.
//! Subscribers (`io_endpoint_subscribers.zig`) read the job table as external
//! consumers of the Service, and `PauseJob`, `ResumeJob` and `CancelJob` go
//! into its external control queue: the Service is all it reaches.
const std = @import("std");
const c = @import("c.zig").api;
const platform = @import("platform");
const wire = @import("io_endpoint_wire.zig");
const io_service = @import("io_service.zig");
const subscribers = @import("io_endpoint_subscribers.zig");

const Allocator = std.mem.Allocator;
const sys = std.posix.system;

/// Connections served at once: launchers come and go, the shell panel stays.
pub const max_connections = 8;
/// Open requests waiting for the UI thread. A burst beyond it is refused with
/// `SERVICE_BUSY`; the launcher then opens a process of its own.
pub const max_pending = 8;
/// Requests read from one connection per pass, so none starves the others.
const requests_per_pass = 8;
/// Unanswered bytes kept for a connection that does not read (a subscriber
/// has its own, larger bound: `subscribers.max_output`).
const max_output = 16 * 1024;
/// A connection that sends no complete request for this long is closed.
const idle_timeout_ms = 10_000;
/// How long a launcher waits for the running process to answer.
const handover_timeout_ms = 2_000;

/// An `OpenWindow` the UI thread turns into a window. Owns its strings.
pub const OpenRequest = struct {
    dir: []u8,
    select: ?[]u8 = null,
    transfers: bool = false,
    activation_token: ?[]u8 = null,
    job_id: ?u64 = null,

    pub fn deinit(self: *OpenRequest, allocator: Allocator) void {
        allocator.free(self.dir);
        if (self.select) |path| allocator.free(path);
        if (self.activation_token) |token| allocator.free(token);
        self.* = undefined;
    }

    fn fromWire(allocator: Allocator, open: wire.OpenWindow) !OpenRequest {
        const dir = try allocator.dupe(u8, open.path);
        errdefer allocator.free(dir);
        const select = if (open.select) |path| try allocator.dupe(u8, path) else null;
        errdefer if (select) |path| allocator.free(path);
        const token = if (open.activation_token) |t| try allocator.dupe(u8, t) else null;
        return .{ .dir = dir, .select = select, .transfers = open.transfers, .activation_token = token, .job_id = open.job_id };
    }
};

/// The socket a process of this display serves, and its lock file.
pub const Paths = struct {
    socket: [:0]u8,
    lock: [:0]u8,

    pub fn init(allocator: Allocator, runtime: []const u8, display: []const u8) !Paths {
        const socket = try std.fmt.allocPrintSentinel(allocator, "{s}/files-io-{x}.sock", .{ runtime, std.hash.Wyhash.hash(0, display) }, 0);
        errdefer allocator.free(socket);
        if (socket.len >= @sizeOf(@FieldType(c.struct_sockaddr_un, "sun_path"))) return error.PathTooLong;
        const lock = try std.fmt.allocPrintSentinel(allocator, "{s}.lock", .{socket}, 0);
        return .{ .socket = socket, .lock = lock };
    }

    pub fn fromEnviron(allocator: Allocator, environ: std.process.Environ) !Paths {
        const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
        if (!privateDirectory(allocator, runtime)) return error.RuntimeDirectoryNotPrivate;
        return init(allocator, runtime, environ.getPosix("WAYLAND_DISPLAY") orelse "wayland-0");
    }

    pub fn deinit(self: *Paths, allocator: Allocator) void {
        allocator.free(self.socket);
        allocator.free(self.lock);
        self.* = undefined;
    }

    fn sockaddr(self: *const Paths) c.struct_sockaddr_un {
        var result: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        result.sun_family = c.AF_UNIX;
        @memcpy(result.sun_path[0..self.socket.len], self.socket);
        return result;
    }
};

fn privateDirectory(allocator: Allocator, path: []const u8) bool {
    const z = allocator.dupeSentinel(u8, path, 0) catch return false;
    defer allocator.free(z);
    var st: c.struct_stat = undefined;
    return c.lstat(z, &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFDIR and
        st.st_uid == c.getuid() and st.st_mode & 0o077 == 0;
}

/// What a launch is after `claim`.
pub const Claim = union(enum) {
    /// The running process took the launch; this one exits.
    handed_over,
    /// This process is the instance: the listening socket to serve.
    instance: std.posix.fd_t,
    /// No endpoint either way (no private runtime directory, or the running
    /// process did not answer): run on its own, without serving.
    standalone,
};

/// Hands `open` to the running process of this display, or becomes it.
/// Blocking, bounded by `handover_timeout_ms`: it runs before any window.
pub fn claim(allocator: Allocator, paths: *const Paths, open: wire.OpenWindow) Claim {
    const lock = c.open(paths.lock, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (lock < 0) return .standalone;
    defer _ = c.close(lock);
    if (c.flock(lock, c.LOCK_EX) != 0) return .standalone;
    defer _ = c.flock(lock, c.LOCK_UN);

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return .standalone;
    var address = paths.sockaddr();
    if (std.c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) == 0) {
        defer _ = c.close(fd);
        return if (handOver(allocator, fd, open)) .handed_over else .standalone;
    }
    const err = std.posix.errno(@as(c_int, -1));
    if (err != .NOENT and err != .CONNREFUSED) {
        _ = c.close(fd);
        return .standalone;
    }
    // Nobody serves: a socket left by a process that died goes.
    _ = c.unlink(paths.socket);
    const old_mask = c.umask(0o177);
    const bound = std.c.bind(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) == 0;
    _ = c.umask(old_mask);
    if (!bound or c.listen(fd, max_connections) != 0 or
        c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK) != 0)
    {
        _ = c.close(fd);
        return .standalone;
    }
    return .{ .instance = fd };
}

/// Sends the launch and waits for the answer.
fn handOver(allocator: Allocator, fd: std.posix.fd_t, open: wire.OpenWindow) bool {
    const same_user = if (platform.peer.of(fd)) |peer| peer.uid == c.getuid() else false;
    if (!same_user) return false;
    const id = "launch";
    const line = wire.formatOpenWindow(allocator, id, open) catch return false;
    defer allocator.free(line);
    const deadline = nowMs() + handover_timeout_ms;
    var sent: usize = 0;
    while (sent < line.len) {
        if (!waitFor(fd, c.POLLOUT, deadline)) return false;
        const n = c.send(fd, line[sent..].ptr, line.len - sent, c.MSG_NOSIGNAL);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    var lines: wire.Lines = .{};
    var out: [wire.max_line]u8 = undefined;
    while (true) {
        if (lines.next(&out) catch return false) |response| return wire.isOk(allocator, response, id);
        if (!waitFor(fd, c.POLLIN, deadline)) return false;
        const room = lines.free();
        const n = c.recv(fd, room.ptr, room.len, 0);
        if (n <= 0) return false;
        lines.commit(@intCast(n));
    }
}

fn waitFor(fd: std.posix.fd_t, events: c_int, deadline: i64) bool {
    while (true) {
        const left = deadline - nowMs();
        if (left <= 0) return false;
        var pfd = [_]c.struct_pollfd{.{ .fd = fd, .events = @intCast(events), .revents = 0 }};
        const rc = c.poll(&pfd, 1, @intCast(left));
        if (rc > 0) return pfd[0].revents & (events | c.POLLHUP | c.POLLERR) != 0;
        if (rc == 0) return false;
        if (std.posix.errno(rc) != .INTR) return false;
    }
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

const Connection = struct {
    fd: std.posix.fd_t = -1,
    lines: wire.Lines = .{},
    output: std.ArrayList(u8) = .empty,
    last_request_ms: i64 = 0,
    /// When the client last took output, or had none waiting.
    last_drain_ms: i64 = 0,
    /// Set once it subscribed: it then stays, without a request timeout.
    subscriber: ?subscribers.Subscriber = null,

    fn active(self: *const Connection) bool {
        return self.fd >= 0;
    }

    fn outputLimit(self: *const Connection) usize {
        return if (self.subscriber != null) subscribers.max_output else max_output;
    }
};

/// The endpoint thread and what it hands the UI thread.
pub const Endpoint = struct {
    allocator: Allocator,
    /// Null in tests of the launch handover alone: no subscribing, no control.
    service: ?*io_service.Service = null,
    listen_fd: std.posix.fd_t = -1,
    /// Removed again when the endpoint stops; null when not ours to remove.
    socket_path: ?[:0]u8 = null,
    stop_fd: std.posix.fd_t = -1,
    open_wake_fd: std.posix.fd_t = -1,
    thread: ?std.Thread = null,
    connections: [max_connections]Connection = @splat(.{}),

    /// Single producer (the endpoint thread), single consumer (the UI thread).
    ring: [max_pending]OpenRequest = undefined,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),

    /// Serves `listen_fd` (from `claim`), which it now owns. `socket_path`
    /// is unlinked on `stop`.
    pub fn start(self: *Endpoint, allocator: Allocator, listen_fd: std.posix.fd_t, socket_path: []const u8, service: ?*io_service.Service) !void {
        self.* = .{ .allocator = allocator, .listen_fd = listen_fd, .service = service };
        errdefer {
            _ = sys.close(listen_fd);
            self.listen_fd = -1;
        }
        self.socket_path = try allocator.dupeSentinel(u8, socket_path, 0);
        errdefer {
            allocator.free(self.socket_path.?);
            self.socket_path = null;
        }
        self.stop_fd = platform.wake.create() orelse return error.WakeDescriptorCreateFailed;
        errdefer _ = sys.close(self.stop_fd);
        self.open_wake_fd = platform.wake.create() orelse return error.WakeDescriptorCreateFailed;
        errdefer _ = sys.close(self.open_wake_fd);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Stops serving: the socket goes first, so a launch from now on starts
    /// a process of its own, then the thread and every connection. Idempotent.
    pub fn stop(self: *Endpoint) void {
        const thread = self.thread orelse return;
        if (self.socket_path) |path| {
            _ = c.unlink(path);
            self.allocator.free(path);
            self.socket_path = null;
        }
        signal(self.stop_fd);
        thread.join();
        self.thread = null;
        for (&self.connections) |*conn| if (conn.active()) self.closeConnection(conn);
        _ = sys.close(self.listen_fd);
        self.listen_fd = -1;
    }

    /// After `stop`: frees requests nobody took and the wake descriptors.
    /// Requests accepted before `stop` are still there for `takeOpen` until
    /// then: their launchers were told yes.
    pub fn deinit(self: *Endpoint) void {
        self.stop();
        while (self.takeOpen()) |request| {
            var owned = request;
            owned.deinit(self.allocator);
        }
        if (self.stop_fd >= 0) _ = sys.close(self.stop_fd);
        if (self.open_wake_fd >= 0) _ = sys.close(self.open_wake_fd);
        self.stop_fd = -1;
        self.open_wake_fd = -1;
    }

    pub fn serving(self: *const Endpoint) bool {
        return self.thread != null;
    }

    /// Readable while open requests wait (UI thread polls it).
    pub fn openWakeFd(self: *const Endpoint) std.posix.fd_t {
        return self.open_wake_fd;
    }

    /// The next open request, owned by the caller. UI thread; never blocks.
    pub fn takeOpen(self: *Endpoint) ?OpenRequest {
        const tail = self.tail.load(.monotonic);
        if (tail == self.head.load(.acquire)) {
            drain(self.open_wake_fd);
            // A push between the check and the drain must not be lost.
            if (tail == self.head.load(.acquire)) return null;
        }
        const request = self.ring[tail % max_pending];
        self.tail.store(tail + 1, .release);
        return request;
    }

    fn push(self: *Endpoint, request: OpenRequest) bool {
        const head = self.head.load(.monotonic);
        if (head - self.tail.load(.acquire) >= max_pending) return false;
        self.ring[head % max_pending] = request;
        self.head.store(head + 1, .release);
        signal(self.open_wake_fd);
        return true;
    }

    fn threadMain(self: *Endpoint) void {
        var fds: [3 + max_connections]c.struct_pollfd = undefined;
        while (true) {
            fds[0] = .{ .fd = self.stop_fd, .events = c.POLLIN, .revents = 0 };
            fds[1] = .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
            // Table changes matter only while someone subscribes.
            const subscribed = for (&self.connections) |*conn| {
                if (conn.active() and conn.subscriber != null) break true;
            } else false;
            const table_fd = if (self.service) |service| (if (subscribed) service.externalWakeFd() else -1) else -1;
            fds[2] = .{ .fd = table_fd, .events = c.POLLIN, .revents = 0 };
            const now = nowMs();
            var timeout: c_int = -1;
            for (&self.connections, 0..) |*conn, i| {
                fds[3 + i] = .{ .fd = conn.fd, .events = 0, .revents = 0 };
                if (!conn.active()) continue;
                fds[3 + i].events = @intCast(c.POLLIN | @as(c_int, if (conn.output.items.len > 0) c.POLLOUT else 0));
                if (self.deadline(conn)) |at| {
                    const left: c_int = @intCast(std.math.clamp(at - now, 0, std.math.maxInt(c_int)));
                    timeout = if (timeout < 0) left else @min(timeout, left);
                }
            }
            const rc = c.poll(&fds, fds.len, timeout);
            if (rc < 0 and std.posix.errno(rc) != .INTR) return;
            if (fds[0].revents != 0) return;
            if (fds[1].revents & c.POLLIN != 0) self.accept();
            const table_changed = fds[2].revents & c.POLLIN != 0;
            if (table_changed) _ = self.service.?.drainExternalWake();
            const after = nowMs();
            for (&self.connections, 0..) |*conn, i| {
                if (!conn.active()) continue;
                const revents = fds[3 + i].revents;
                if (revents & c.POLLOUT != 0) self.flush(conn, after);
                if (conn.active() and revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) self.serve(conn, after);
                // After a change, or once output drained below the low water.
                if (conn.active() and conn.subscriber != null and (table_changed or revents & c.POLLOUT != 0)) self.pumpSubscriber(conn, after);
                if (conn.active()) if (self.deadline(conn)) |at| if (after >= at) self.closeConnection(conn);
            }
        }
    }

    /// When the connection is closed if nothing happens: a request client
    /// that sends nothing complete, a subscriber that takes no output.
    fn deadline(self: *Endpoint, conn: *const Connection) ?i64 {
        _ = self;
        if (conn.subscriber == null) return conn.last_request_ms + idle_timeout_ms;
        if (conn.output.items.len == 0) return null;
        return conn.last_drain_ms + subscribers.stall_ms;
    }

    fn accept(self: *Endpoint) void {
        while (true) {
            const fd = std.c.accept4(self.listen_fd, null, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
            if (fd < 0) return;
            const same_user = if (platform.peer.of(fd)) |peer| peer.uid == c.getuid() else false;
            const slot = for (&self.connections) |*conn| {
                if (!conn.active()) break conn;
            } else null;
            if (!same_user or slot == null) {
                _ = sys.close(fd);
                continue;
            }
            const now = nowMs();
            slot.?.* = .{ .fd = fd, .last_request_ms = now, .last_drain_ms = now };
        }
    }

    /// Reads what arrived and answers up to `requests_per_pass` requests.
    fn serve(self: *Endpoint, conn: *Connection, now: i64) void {
        const room = conn.lines.free();
        if (room.len > 0) {
            const n = c.recv(conn.fd, room.ptr, room.len, 0);
            if (n == 0) return self.closeConnection(conn);
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err != .AGAIN and err != .INTR) return self.closeConnection(conn);
            } else conn.lines.commit(@intCast(n));
        }
        var line_buf: [wire.max_line]u8 = undefined;
        var served: usize = 0;
        while (served < requests_per_pass) : (served += 1) {
            const line = conn.lines.next(&line_buf) catch {
                // No framing past an overlong line: answer and hang up.
                self.reply(conn, "", .INVALID_REQUEST, "Request too long");
                self.flush(conn, now);
                return self.closeConnection(conn);
            } orelse break;
            conn.last_request_ms = now;
            self.handle(conn, line, now);
            if (!conn.active()) return;
        }
        self.flush(conn, now);
    }

    fn handle(self: *Endpoint, conn: *Connection, line: []const u8, now: i64) void {
        var result = wire.parse(self.allocator, line) catch
            return self.reply(conn, "", .INTERNAL_ERROR, "Out of memory");
        switch (result) {
            .rejected => |*rejection| self.reply(conn, rejection.id(), rejection.code, rejection.message),
            .request => |*parsed| {
                defer parsed.deinit();
                switch (parsed.request) {
                    .open_window => |open| {
                        var request = OpenRequest.fromWire(self.allocator, open) catch
                            return self.reply(conn, parsed.id, .INTERNAL_ERROR, "Out of memory");
                        if (!self.push(request)) {
                            request.deinit(self.allocator);
                            return self.reply(conn, parsed.id, .SERVICE_BUSY, "Too many windows are being opened");
                        }
                        self.replyOk(conn, parsed.id);
                    },
                    .subscribe => {
                        const service = self.service orelse
                            return self.reply(conn, parsed.id, .INTERNAL_ERROR, "No job service");
                        if (conn.subscriber != null)
                            return self.reply(conn, parsed.id, .INVALID_STATE, "Already subscribed");
                        conn.subscriber = subscribers.Subscriber.init(service) catch |err| return switch (err) {
                            error.TooManyConsumers => self.reply(conn, parsed.id, .RESOURCE_LIMIT, "Too many subscribers"),
                            else => self.reply(conn, parsed.id, .SERVICE_BUSY, "The job service is stopping"),
                        };
                        // The answer first, then the snapshot.
                        self.replyOk(conn, parsed.id);
                        if (conn.active()) self.pumpSubscriber(conn, now);
                    },
                    .control => |control| {
                        const service = self.service orelse
                            return self.reply(conn, parsed.id, .INTERNAL_ERROR, "No job service");
                        service.sendControl(control.control, control.job_id) catch |err| return switch (err) {
                            error.JobNotFound => self.reply(conn, parsed.id, .JOB_NOT_FOUND, "No such job"),
                            error.InvalidState => self.reply(conn, parsed.id, .INVALID_STATE, "The job has ended"),
                            error.QueueFull, error.ServiceStopping => self.reply(conn, parsed.id, .SERVICE_BUSY, "Try again"),
                        };
                        self.replyOk(conn, parsed.id);
                    },
                }
            },
        }
    }

    fn pumpSubscriber(self: *Endpoint, conn: *Connection, now: i64) void {
        if (!conn.subscriber.?.pump(self.allocator, &conn.output)) return self.closeConnection(conn);
        self.flush(conn, now);
    }

    fn replyOk(self: *Endpoint, conn: *Connection, id: []const u8) void {
        const line = wire.formatOk(self.allocator, id) catch return self.closeConnection(conn);
        defer self.allocator.free(line);
        self.queue(conn, line);
    }

    fn reply(self: *Endpoint, conn: *Connection, id: []const u8, code: wire.ErrorCode, message: []const u8) void {
        const line = wire.formatError(self.allocator, id, code, message) catch return self.closeConnection(conn);
        defer self.allocator.free(line);
        self.queue(conn, line);
    }

    /// Appends an answer; a client that lets its output pile up is dropped
    /// (contract §9.3), never waited for.
    fn queue(self: *Endpoint, conn: *Connection, line: []const u8) void {
        if (conn.output.items.len + line.len > conn.outputLimit()) return self.closeConnection(conn);
        conn.output.appendSlice(self.allocator, line) catch return self.closeConnection(conn);
    }

    fn flush(self: *Endpoint, conn: *Connection, now: i64) void {
        if (conn.output.items.len == 0) {
            conn.last_drain_ms = now;
            return;
        }
        while (conn.output.items.len > 0) {
            const n = c.send(conn.fd, conn.output.items.ptr, conn.output.items.len, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err == .AGAIN or err == .INTR) return;
                return self.closeConnection(conn);
            }
            if (n == 0) return;
            conn.output.replaceRangeAssumeCapacity(0, @intCast(n), &.{});
            conn.last_drain_ms = now;
        }
    }

    fn closeConnection(self: *Endpoint, conn: *Connection) void {
        if (conn.subscriber) |*subscriber| subscriber.deinit(self.allocator);
        conn.output.deinit(self.allocator);
        _ = sys.close(conn.fd);
        conn.* = .{};
    }
};

fn signal(fd: std.posix.fd_t) void {
    const one: u64 = 1;
    _ = sys.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
}

fn drain(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = sys.read(fd, std.mem.asBytes(&value), @sizeOf(u64));
}
