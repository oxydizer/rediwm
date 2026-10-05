//! Greeter mode's model: which accounts and sessions can be chosen, the last
//! choice, and the rediwm-dm conversation. The greeter runs unprivileged as
//! rediwm-dm's greeter user; rediwm-dm owns PAM, credentials and starting the
//! session, so nothing here can grant a login by itself.
const std = @import("std");
const wl = @import("wayland").server.wl;
const dm_ipc = @import("dm_ipc.zig");
const ws = @import("wayland_sessions.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
});

extern fn rediwm_secret_clear([*]u8, usize) void;

const log = std.log.scoped(.greeter);

pub const User = struct {
    name: []const u8,
    real: []const u8,
    home: []const u8,
    uid: u32,
};

pub const Session = ws.Session;
pub const sessionLess = ws.sessionLess;

pub const Phase = enum { idle, authenticating, prompting, starting, cancelling, done };

pub const Event = union(enum) {
    /// An informational PAM message, or progress.
    status: []const u8,
    /// PAM wants another answer (a second factor, a new password...).
    prompt: struct { text: []const u8, visible: bool },
    /// Wrong credentials. The conversation is being cancelled.
    rejected,
    failed: []const u8,
    /// rediwm-dm accepted the session; the greeter must now exit.
    started,
    /// The daemon connection is gone. It is inherited, never reopened, so
    /// the greeter exits and rediwm-dm starts a fresh one.
    disconnected,
};

pub const Greeter = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    loop: *wl.EventLoop,
    users: []User = &.{},
    sessions: []Session = &.{},
    /// user name -> session id, from the state file.
    remembered: []const [2][]const u8 = &.{},
    user: usize = 0,
    session: usize = 0,
    state_path: ?[]const u8 = null,
    client: ?dm_ipc.Client = null,
    source: ?*wl.EventSource = null,
    phase: Phase = .idle,
    /// The first answer, typed before the daemon asks for it.
    pending: [512]u8 = @splat(0),
    pending_len: ?usize = null,
    message: [256]u8 = @splat(0),
    owner: ?*anyopaque = null,
    notify: ?*const fn (owner: ?*anyopaque, event: Event) void = null,

    pub fn create(io: std.Io, loop: *wl.EventLoop, environ: std.process.Environ) !*Greeter {
        const gpa = std.heap.c_allocator;
        const self = try gpa.create(Greeter);
        self.* = .{ .arena = .init(gpa), .io = io, .loop = loop };
        _ = c.mlock(&self.pending, self.pending.len);
        const a = self.arena.allocator();
        if (environ.getPosix("REDIWM_GREETER_FD")) |fd_str| {
            if (std.fmt.parseInt(c_int, fd_str, 10)) |fd| {
                // Nothing the greeter might spawn inherits the daemon socket.
                _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
                self.client = dm_ipc.Client.fromFd(fd);
                self.watch() catch {
                    self.client.?.close();
                    self.client = null;
                };
            } else |_| {}
        }
        self.users = loadUsers(a, io) catch |err| blk: {
            log.err("cannot list accounts: {}", .{err});
            break :blk &.{};
        };
        const data_dirs = environ.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        const search = environ.getPosix("PATH") orelse "/usr/local/sbin:/usr/local/bin:/usr/bin";
        self.sessions = ws.loadSessions(a, io, data_dirs, search) catch |err| blk: {
            log.err("cannot list sessions: {}", .{err});
            break :blk &.{};
        };
        self.state_path = statePath(a, environ) catch null;
        if (self.state_path) |path| self.restore(path);
        return self;
    }

    pub fn destroy(self: *Greeter) void {
        self.disconnect();
        self.clearPending();
        _ = c.munlock(&self.pending, self.pending.len);
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }

    pub fn selectedUser(self: *const Greeter) ?User {
        return if (self.users.len == 0) null else self.users[self.user];
    }

    pub fn selectedSession(self: *const Greeter) ?Session {
        return if (self.sessions.len == 0) null else self.sessions[self.session];
    }

    pub fn busy(self: *const Greeter) bool {
        return switch (self.phase) {
            .idle, .prompting => false,
            else => true,
        };
    }

    /// Moves the account selection and brings up that account's last session.
    pub fn cycleUser(self: *Greeter, delta: isize) void {
        if (self.users.len == 0 or self.phase != .idle) return;
        self.user = wrap(self.user, delta, self.users.len);
        self.recallSession();
    }

    pub fn cycleSession(self: *Greeter, delta: isize) void {
        if (self.sessions.len == 0 or self.phase != .idle) return;
        self.session = wrap(self.session, delta, self.sessions.len);
    }

    /// Starts a conversation for the selected account. `answer` is kept only
    /// until the daemon asks its first question.
    pub fn begin(self: *Greeter, first: []const u8) ![]const u8 {
        if (self.phase != .idle) return error.Busy;
        const user = self.selectedUser() orelse return error.NoAccount;
        if (self.selectedSession() == null) return error.NoSession;
        if (self.client == null) return error.NoService;
        if (first.len > self.pending.len) return error.TooLong;
        @memcpy(self.pending[0..first.len], first);
        self.pending_len = first.len;
        self.phase = .authenticating;
        self.send(.{ .login = user.name }) catch |err| {
            self.clearPending();
            self.disconnect();
            return err;
        };
        return "Signing in…";
    }

    /// Answers the question the daemon is waiting on.
    pub fn answer(self: *Greeter, response: []const u8) !void {
        if (self.phase != .prompting) return error.Busy;
        self.phase = .authenticating;
        self.send(.{ .answer = response }) catch |err| {
            self.disconnect();
            return err;
        };
    }

    /// Abandons a conversation that is waiting on the user.
    pub fn cancel(self: *Greeter) void {
        if (self.phase != .prompting) return;
        self.phase = .cancelling;
        self.send(.cancel) catch self.disconnect();
    }

    /// Adopts an already connected daemon peer (tests or manual adoption).
    pub fn adopt(self: *Greeter, fd: c_int) !void {
        self.disconnect();
        self.client = dm_ipc.Client.fromFd(fd);
        try self.watch();
    }

    fn watch(self: *Greeter) !void {
        self.source = try self.loop.addFd(*Greeter, self.client.?.fd, .{ .readable = true }, readable, self);
    }

    fn disconnect(self: *Greeter) void {
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.client) |*client| client.close();
        self.client = null;
        if (self.phase != .done) self.phase = .idle;
        self.clearPending();
    }

    fn send(self: *Greeter, request: dm_ipc.Request) !void {
        try (if (self.client) |*client| client else return error.NoService).send(request);
    }

    fn clearPending(self: *Greeter) void {
        rediwm_secret_clear(&self.pending, self.pending.len);
        self.pending_len = null;
    }

    fn readable(fd: c_int, mask: wl.EventMask, self: *Greeter) c_int {
        _ = fd;
        _ = mask;
        self.pump();
        return 0;
    }

    /// Handles every complete response the daemon has sent.
    pub fn pump(self: *Greeter) void {
        if (self.client) |*client| client.fill() catch |err| {
            if (err != error.Disconnected) log.warn("dm read failed: {}", .{err});
            return self.lost();
        };
        while (self.client) |*client| {
            const payload = (client.frame() catch return self.lost()) orelse return;
            var parsed = dm_ipc.parse(std.heap.c_allocator, payload) catch |err| {
                log.warn("dm sent an unreadable response: {}", .{err});
                return self.lost();
            };
            defer parsed.deinit();
            client.consume(payload);
            if (self.handle(parsed.response)) |event| self.emit(event);
        }
    }

    fn lost(self: *Greeter) void {
        const done = self.phase == .done;
        self.disconnect();
        if (!done) self.emit(.disconnected);
    }

    fn emit(self: *Greeter, event: Event) void {
        if (self.notify) |notify| notify(self.owner, event);
    }

    fn handle(self: *Greeter, response: dm_ipc.Response) ?Event {
        switch (self.phase) {
            .cancelling => {
                self.phase = .idle;
                return null;
            },
            .starting => return switch (response) {
                .ok => blk: {
                    self.phase = .done;
                    self.remember();
                    break :blk .started;
                },
                .denied, .failed => |text| self.fail(text),
                .question => self.fail("unexpected question"),
            },
            .authenticating => switch (response) {
                .ok => {
                    self.clearPending();
                    return self.start();
                },
                .question => |q| switch (q.kind) {
                    .secret, .visible => {
                        if (self.pending_len) |n| {
                            const sent = self.send(.{ .answer = self.pending[0..n] });
                            self.clearPending();
                            sent catch return self.failSend();
                            return null;
                        }
                        self.phase = .prompting;
                        return .{ .prompt = .{ .text = self.copy(q.text), .visible = q.kind == .visible } };
                    },
                    .info, .@"error" => {
                        const text = self.copy(q.text);
                        self.send(.{ .answer = null }) catch return self.failSend();
                        return .{ .status = text };
                    },
                },
                .denied => {
                    self.clearPending();
                    self.phase = .cancelling;
                    self.send(.cancel) catch return self.failSend();
                    return .rejected;
                },
                .failed => |text| return self.fail(text),
            },
            .idle, .prompting, .done => {
                log.warn("dm answered with no request outstanding", .{});
                self.disconnect();
                return .disconnected;
            },
        }
    }

    fn start(self: *Greeter) Event {
        const session = self.selectedSession() orelse return self.fail("no session selected");
        self.phase = .starting;
        self.send(.{ .start = session.id }) catch return self.failSend();
        return .{ .status = "Starting session…" };
    }

    fn fail(self: *Greeter, text: []const u8) Event {
        const message = self.setMessage("Sign-in failed: ", text);
        self.clearPending();
        self.phase = .cancelling;
        self.send(.cancel) catch self.disconnect();
        return .{ .failed = message };
    }

    fn failSend(self: *Greeter) Event {
        self.disconnect();
        return .disconnected;
    }

    fn copy(self: *Greeter, text: []const u8) []const u8 {
        return self.setMessage("", text);
    }

    fn setMessage(self: *Greeter, prefix: []const u8, text: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        @memcpy(self.message[0..prefix.len], prefix);
        var end = @min(trimmed.len, self.message.len - prefix.len);
        // Never cut a UTF-8 sequence in half.
        if (end < trimmed.len) while (end > 0 and trimmed[end] & 0xc0 == 0x80) : (end -= 1) {};
        @memcpy(self.message[prefix.len..][0..end], trimmed[0..end]);
        return self.message[0 .. prefix.len + end];
    }

    fn recallSession(self: *Greeter) void {
        const user = self.selectedUser() orelse return;
        for (self.remembered) |pair| {
            if (!std.mem.eql(u8, pair[0], user.name)) continue;
            for (self.sessions, 0..) |session, i| if (std.mem.eql(u8, session.id, pair[1])) {
                self.session = i;
                return;
            };
        }
    }

    fn restore(self: *Greeter, path: []const u8) void {
        const a = self.arena.allocator();
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 * 1024)) catch return;
        var last: ?[]const u8 = null;
        var pairs: std.ArrayList([2][]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "user")) {
                last = value;
            } else if (std.mem.startsWith(u8, key, "session.")) {
                pairs.append(a, .{ key["session.".len..], value }) catch return;
            }
        }
        self.remembered = pairs.items;
        if (last) |name| for (self.users, 0..) |user, i| if (std.mem.eql(u8, user.name, name)) {
            self.user = i;
        };
        self.recallSession();
    }

    /// Records the account and its session for the next greeting.
    fn remember(self: *Greeter) void {
        const path = self.state_path orelse return;
        const user = self.selectedUser() orelse return;
        const session = self.selectedSession() orelse return;
        var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer out.deinit();
        out.writer.print("user={s}\nsession.{s}={s}\n", .{ user.name, user.name, session.id }) catch return;
        for (self.remembered) |pair| {
            if (std.mem.eql(u8, pair[0], user.name)) continue;
            out.writer.print("session.{s}={s}\n", .{ pair[0], pair[1] }) catch return;
        }
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(self.io, dir) catch {};
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.new", .{path}) catch return;
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = out.written() }) catch |err| {
            log.info("cannot remember the last login in {s}: {}", .{ path, err });
            return;
        };
        cwd.rename(tmp, cwd, path, self.io) catch {};
    }
};

fn wrap(index: usize, delta: isize, len: usize) usize {
    const n: isize = @intCast(len);
    return @intCast(@mod(@as(isize, @intCast(index)) + delta, n));
}

fn statePath(a: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    if (environ.getPosix("XDG_STATE_HOME")) |dir| if (dir.len > 0) return std.fs.path.join(a, &.{ dir, "rediwm", "greeter.state" });
    const home = environ.getPosix("HOME") orelse return error.NoHome;
    return std.fs.path.join(a, &.{ home, ".local/state/rediwm/greeter.state" });
}

fn loadUsers(a: std.mem.Allocator, io: std.Io) ![]User {
    var range: ws.UidRange = .{};
    if (std.Io.Dir.cwd().readFileAlloc(io, "/etc/login.defs", a, .limited(256 * 1024))) |bytes| {
        range = ws.parseLoginDefs(bytes);
    } else |_| {}
    var users: std.ArrayList(User) = .empty;
    // NSS, not /etc/passwd, so systemd-homed and directory accounts appear.
    c.setpwent();
    defer c.endpwent();
    while (c.getpwent()) |pw| {
        const shell = if (pw.*.pw_shell) |s| std.mem.span(s) else "";
        if (!ws.loginAccount(range, pw.*.pw_uid, shell)) continue;
        const gecos = if (pw.*.pw_gecos) |g| std.mem.span(g) else "";
        const name = try a.dupe(u8, std.mem.span(pw.*.pw_name));
        var duplicate = false;
        for (users.items) |u| duplicate = duplicate or std.mem.eql(u8, u.name, name);
        if (duplicate) continue;
        try users.append(a, .{
            .name = name,
            .real = try a.dupe(u8, gecos[0 .. std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len]),
            .home = try a.dupe(u8, if (pw.*.pw_dir) |d| std.mem.span(d) else ""),
            .uid = pw.*.pw_uid,
        });
    }
    std.mem.sort(User, users.items, {}, struct {
        fn less(_: void, x: User, y: User) bool {
            return x.uid < y.uid;
        }
    }.less);
    return users.items;
}
