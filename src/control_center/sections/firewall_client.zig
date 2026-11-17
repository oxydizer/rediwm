//! Runs `rediwm-firewall-helper` through pkexec, one request at a time, for
//! the Firewall section while it is on screen. Event-driven: the reply pipe
//! and the child's exit wake the loop; the only timers are the request's
//! deadline and, while a change waits to revert, one at its deadline.
const std = @import("std");
const wl = @import("wayland").server.wl;
const c = @import("c");
const platform = @import("platform");
const fw = @import("firewall");
const Child = @import("../../session/child.zig");
const a = std.heap.c_allocator;

pub const Mode = enum { read, manage };

const helper_path = @import("install_paths").bin ++ "/rediwm-firewall-helper";
const policy_dirs = [_][]const u8{ "/usr/share/polkit-1/actions", "/usr/local/share/polkit-1/actions", "/etc/polkit-1/actions" };

/// Whether polkit has our actions for this helper. Without them pkexec falls
/// back to its generic action, which asks for an administrator password even
/// to read, so nothing runs: a build whose policy is not installed (a
/// development or test compositor) never reaches the session's polkit agent.
pub fn policyInstalled(io: std.Io) bool {
    const needle = "<annotate key=\"org.freedesktop.policykit.exec.path\">" ++ helper_path ++ "</annotate>";
    for (policy_dirs) |dir| {
        var buffer: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/org.rediwm.firewall.policy", .{dir}) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 10)) catch continue;
        defer a.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// What the last run ended as, for the page's message line.
pub const Outcome = enum { none, ok, failed, denied, broken };

pub const Client = struct {
    io: std.Io,
    loop: *wl.EventLoop,
    owner: *anyopaque,
    changed: *const fn (*anyopaque) void,
    child: ?*Child = null,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    revert_timer: ?*wl.EventSource = null,
    fd: c_int = -1,
    bytes: std.ArrayList(u8) = .empty,
    /// The latest status; kept while a newer request runs.
    current: ?std.json.Parsed(fw.protocol.Reply) = null,
    busy: bool = false,
    op: fw.protocol.Op = .status,
    mode: Mode = .read,
    outcome: Outcome = .none,
    failure_buf: [160]u8 = undefined,
    failure_len: usize = 0,
    /// A status read was asked for while busy; it runs when the request ends.
    refresh_pending: bool = false,

    pub fn create(io: std.Io, loop: *wl.EventLoop, owner: *anyopaque, changed: *const fn (*anyopaque) void) !*Client {
        const self = try a.create(Client);
        self.* = .{ .io = io, .loop = loop, .owner = owner, .changed = changed };
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.cancel();
        if (self.revert_timer) |timer| timer.remove();
        if (self.current) |*value| value.deinit();
        self.bytes.deinit(a);
        a.destroy(self);
    }

    /// Stops a running request. A pkexec still asking for the password ends;
    /// the helper itself runs as root and finishes on its own deadline.
    pub fn cancel(self: *Client) void {
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.timer) |timer| timer.remove();
        self.timer = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.child) |child| {
            child.signal(.TERM);
            child.detach();
        }
        self.child = null;
        self.busy = false;
        self.refresh_pending = false;
    }

    pub fn status(self: *const Client) ?*const fw.model.Status {
        const value = &(self.current orelse return null);
        return &value.value.status;
    }

    pub fn failure(self: *const Client) []const u8 {
        return self.failure_buf[0..self.failure_len];
    }

    pub fn send(self: *Client, req: fw.protocol.Request, mode: Mode) !void {
        if (self.busy) {
            if (req.op == .status) {
                self.refresh_pending = true;
                return;
            }
            return error.Busy;
        }
        const bytes = try std.json.Stringify.valueAlloc(a, req, .{});
        defer a.free(bytes);
        if (bytes.len > fw.model.max_request) return error.RequestTooLarge;
        var sockets: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets) != 0) return error.PipeFailed;
        defer {
            _ = c.close(sockets[0]);
            _ = c.close(sockets[1]);
        }
        const pkexec = platform.tool.system(self.io, "pkexec") orelse return error.NoPkexec;
        var process = try std.process.spawn(self.io, .{
            .argv = &.{ pkexec, "--disable-internal-agent", helper_path, @tagName(mode) },
            .stdin = .{ .file = .{ .handle = sockets[0], .flags = .{ .nonblocking = false } } },
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        errdefer process.kill(self.io);
        errdefer self.cancel();
        self.fd = process.stdout.?.handle;
        process.stdout = null;
        const flags = c.fcntl(self.fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(self.fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.PipeFailed;
        self.source = try self.loop.addFd(*Client, self.fd, .{ .readable = true }, readable, self);
        self.timer = try self.loop.addTimer(*Client, timeout, self);
        // The password prompt may wait for the user; a read never prompts on
        // Linux but may on FreeBSD.
        try self.timer.?.timerUpdate(if (mode == .manage) 180000 else 90000);
        self.child = try Child.watch(a, self.loop, process.id.?, self, exited);
        process.id = null;
        const sent = c.send(sockets[1], bytes.ptr, bytes.len, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
        if (sent != bytes.len or c.shutdown(sockets[1], c.SHUT_WR) != 0) return error.RequestWriteFailed;
        self.bytes.clearRetainingCapacity();
        self.busy = true;
        self.op = req.op;
        self.mode = mode;
        self.outcome = .none;
    }

    fn drain(self: *Client) void {
        var buffer: [16384]u8 = undefined;
        while (self.fd >= 0) {
            const n = c.read(self.fd, &buffer, buffer.len);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0 and std.posix.errno(n) == .AGAIN) return;
            if (n <= 0) {
                if (self.source) |source| source.remove();
                self.source = null;
                return;
            }
            const count: usize = @intCast(n);
            if (self.bytes.items.len + count > fw.model.max_reply) {
                self.bytes.clearRetainingCapacity();
                if (self.child) |child| child.signal(.TERM);
                return;
            }
            self.bytes.appendSlice(a, buffer[0..count]) catch return;
        }
    }

    fn readable(_: c_int, _: wl.EventMask, self: *Client) c_int {
        self.drain();
        return 0;
    }

    fn timeout(self: *Client) c_int {
        if (self.child) |child| child.signal(.TERM);
        return 0;
    }

    fn setFailure(self: *Client, text: []const u8) void {
        const n = @min(text.len, self.failure_buf.len);
        @memcpy(self.failure_buf[0..n], text[0..n]);
        self.failure_len = n;
    }

    fn exited(raw: ?*anyopaque, _: *Child, exit: ?u32) void {
        const self: *Client = @ptrCast(@alignCast(raw.?));
        self.drain();
        self.child = null;
        const op = self.op;
        const pending = self.refresh_pending;
        self.cancel();
        self.refresh_pending = pending;
        // `exit` is the raw wait status.
        const code: u32 = if (exit) |wait| (if (std.posix.W.IFEXITED(wait)) std.posix.W.EXITSTATUS(wait) else 255) else 255;
        self.failure_len = 0;
        // pkexec: 126 when the dialog was dismissed, 127 when not authorized.
        if (code == 126 or code == 127) {
            self.outcome = .denied;
        } else if (self.bytes.items.len == 0) {
            self.outcome = if (code == 0) .ok else .broken;
        } else if (std.json.parseFromSlice(fw.protocol.Reply, a, self.bytes.items, .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .max_value_len = fw.model.max_reply })) |reply| {
            if (reply.value.failure) |text| self.setFailure(text);
            self.outcome = if (reply.value.failure == null) .ok else .failed;
            if (op == .authorize) {
                var discard = reply;
                discard.deinit();
            } else {
                if (self.current) |*previous| previous.deinit();
                self.current = reply;
            }
        } else |_| self.outcome = .broken;
        self.armRevert();
        self.op = op;
        self.changed(self.owner);
    }

    /// One wake at the revert deadline so the page shows what came back.
    fn armRevert(self: *Client) void {
        const left = if (self.status()) |s| s.revert_in else 0;
        if (left == 0) {
            if (self.revert_timer) |timer| timer.remove();
            self.revert_timer = null;
            return;
        }
        if (self.revert_timer == null) self.revert_timer = self.loop.addTimer(*Client, reverted, self) catch return;
        self.revert_timer.?.timerUpdate(@intCast(@as(u32, @min(left + 2, 400)) * 1000)) catch {};
    }

    fn reverted(self: *Client) c_int {
        if (self.revert_timer) |timer| timer.remove();
        self.revert_timer = null;
        self.send(.{ .op = .status }, self.mode) catch {};
        return 0;
    }

    /// Runs a status read queued while busy.
    pub fn flush(self: *Client) void {
        if (!self.busy and self.refresh_pending) {
            self.refresh_pending = false;
            self.send(.{ .op = .status }, self.mode) catch {};
        }
    }
};
