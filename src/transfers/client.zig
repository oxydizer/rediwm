//! The compositor's subscription to the Files endpoint
//! (`files/io_endpoint.zig`): one non-blocking stream socket on the event
//! loop, fed into `model.Model`.
//!
//! Files runs only while a window is open or work remains, so the socket
//! comes and goes. Nothing polls for it: an inotify watch on the runtime
//! directory sees the socket appear, and a hangup means Files left. A
//! second-long timer runs only while jobs are live, for the speed history.
const std = @import("std");
const platform = @import("platform");
const wl = @import("wayland").server.wl;
const c = @import("c");
const Server = @import("../Server.zig");
const model_mod = @import("model.zig");
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.transfers);

/// Endpoint lines are at most a snapshot of every job with its history.
const max_line = 1 << 20;
const tick_ms = 1000;
/// Progress arrives as often as Files publishes it; the icon and panel
/// repaint at most this often (appearing and going are shown at once).
const repaint_ms = 200;
/// Files binds its socket before it listens: a refused connect right after
/// the socket appears is retried this often, this many times.
const retry_ms = 50;
const retries = 20;

pub const Control = enum { pause, @"resume", cancel };

pub const Client = struct {
    server: *Server,
    model: model_mod.Model = .{},
    socket_path: [:0]u8,
    socket_name: []const u8,
    watcher: platform.watch.Watcher = .{},
    watch: platform.watch.Watch = platform.watch.none,
    watch_source: ?*wl.EventSource = null,
    fd: c_int = -1,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    ticking: bool = false,
    repaint_timer: ?*wl.EventSource = null,
    repaint_pending: bool = false,
    /// Whether the taskbar item was shown at the last repaint.
    shown: bool = false,
    retry_timer: ?*wl.EventSource = null,
    retries_left: u8 = 0,
    inbox: std.ArrayList(u8) = .empty,
    outbox: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,

    pub fn create(server: *Server) !*Client {
        const display = server.wl_server_socket_name orelse return error.NoDisplay;
        const runtime = if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| std.mem.span(dir) else return error.NoRuntimeDir;
        // The name Files binds: `files/io_endpoint.zig` `Paths.init`.
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/files-io-{x}.sock", .{ runtime, std.hash.Wyhash.hash(0, display) }, 0);
        errdefer gpa.free(path);
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .socket_path = path, .socket_name = std.fs.path.basename(path) };
        const loop = server.wl_server.getEventLoop();
        self.timer = try loop.addTimer(*Client, onTick, self);
        self.repaint_timer = try loop.addTimer(*Client, onRepaint, self);
        self.retry_timer = try loop.addTimer(*Client, onRetry, self);
        if (platform.watch.Watcher.init()) |watcher| {
            self.watcher = watcher;
            self.watch = watcher.add(runtime, .{ .created = true, .moved_to = true }) orelse platform.watch.none;
            if (self.watch != platform.watch.none) {
                self.watch_source = loop.addFd(*Client, watcher.fd, .{ .readable = true }, onWatch, self) catch null;
            }
        } else |_| log.warn("no directory watch; the Transfers panel connects only at startup", .{});
        self.connect();
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.closeSocket();
        if (self.timer) |timer| timer.remove();
        if (self.repaint_timer) |timer| timer.remove();
        if (self.retry_timer) |timer| timer.remove();
        if (self.watch_source) |source| source.remove();
        self.watcher.deinit();
        self.inbox.deinit(gpa);
        self.outbox.deinit(gpa);
        gpa.free(self.socket_path);
        gpa.destroy(self);
    }

    pub fn connected(self: *const Client) bool {
        return self.fd >= 0;
    }

    /// Connects, retrying a refused connect a few times (see `retries`).
    fn connectSoon(self: *Client) void {
        self.connect();
        if (self.fd >= 0) return;
        self.retries_left = retries;
        if (self.retry_timer) |timer| timer.timerUpdate(retry_ms) catch {};
    }

    fn onRetry(self: *Client) c_int {
        if (self.fd >= 0 or self.retries_left == 0) return 0;
        self.retries_left -= 1;
        self.connect();
        if (self.fd < 0 and self.retries_left > 0) if (self.retry_timer) |timer| timer.timerUpdate(retry_ms) catch {};
        return 0;
    }

    fn connect(self: *Client) void {
        if (self.fd >= 0) return;
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        if (self.socket_path.len >= addr.sun_path.len) return;
        addr.sun_family = c.AF_UNIX;
        @memcpy(@as([*]u8, @ptrCast(&addr.sun_path))[0..self.socket_path.len], self.socket_path);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return;
        // A listening Unix socket accepts at once; a stale file refuses.
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) {
            _ = c.close(fd);
            return;
        }
        self.source = self.server.wl_server.getEventLoop().addFd(*Client, fd, .{ .readable = true }, onFd, self) catch {
            _ = c.close(fd);
            return;
        };
        self.fd = fd;
        self.inbox.clearRetainingCapacity();
        self.outbox.clearRetainingCapacity();
        log.info("subscribed to Files transfers", .{});
        self.request("Subscribe", "{}");
    }

    fn closeSocket(self: *Client) void {
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.inbox.clearAndFree(gpa);
        self.outbox.clearAndFree(gpa);
    }

    fn disconnect(self: *Client) void {
        self.closeSocket();
        self.model.disconnected();
        self.changed();
    }

    /// Pause, resume or cancel a job; the answer comes as a job change.
    pub fn control(self: *Client, which: Control, job_id: u64) void {
        var params: [48]u8 = undefined;
        const command = switch (which) {
            .pause => "PauseJob",
            .@"resume" => "ResumeJob",
            .cancel => "CancelJob",
        };
        self.request(command, std.fmt.bufPrint(&params, "{{\"job_id\":{d}}}", .{job_id}) catch return);
    }

    /// Opens Files at `path`, or raises the window of `job_id` when it is
    /// still open (its conflict asks there). The new window may take focus.
    pub fn openWindow(self: *Client, path: []const u8, job_id: ?u64) void {
        if (self.fd < 0) {
            // Files is not running: start it there.
            const argv: []const []const u8 = &.{ "rediwm-files", path };
            return @import("../config_runtime/actions.zig").spawnArgv(self.server, argv);
        }
        const token = self.server.activation.createToken();
        if (token) |t| t.data = @ptrCast(&self.server.activation);
        const params = std.json.Stringify.valueAlloc(gpa, .{
            .path = path,
            .job_id = job_id,
            .activation_token = if (token) |t| std.mem.span(t.name()) else null,
        }, .{ .emit_null_optional_fields = false }) catch return;
        defer gpa.free(params);
        self.request("OpenWindow", params);
    }

    fn request(self: *Client, command: []const u8, params: []const u8) void {
        if (self.fd < 0) return;
        const id = self.next_id;
        self.next_id += 1;
        self.outbox.print(gpa, "{{\"version\":1,\"id\":\"{d}\",\"command\":\"{s}\",\"params\":{s}}}\n", .{ id, command, params }) catch return;
        self.flush();
    }

    fn flush(self: *Client) void {
        while (self.outbox.items.len > 0) {
            const n = c.send(self.fd, self.outbox.items.ptr, self.outbox.items.len, c.MSG_NOSIGNAL);
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err == .INTR) continue;
                if (err != .AGAIN) return self.disconnect();
                break;
            }
            const sent: usize = @intCast(n);
            std.mem.copyForwards(u8, self.outbox.items[0 .. self.outbox.items.len - sent], self.outbox.items[sent..]);
            self.outbox.shrinkRetainingCapacity(self.outbox.items.len - sent);
        }
        if (self.source) |source| source.fdUpdate(.{ .readable = true, .writable = self.outbox.items.len > 0 }) catch {};
    }

    fn onFd(_: c_int, mask: wl.EventMask, self: *Client) c_int {
        if (mask.writable) self.flush();
        if (self.fd < 0) return 0;
        if (mask.readable or mask.hangup or mask.@"error") self.receive();
        return 0;
    }

    fn receive(self: *Client) void {
        var any = false;
        // Bounded: a burst larger than this waits for the next dispatch.
        for (0..16) |_| {
            self.inbox.ensureUnusedCapacity(gpa, 64 * 1024) catch return self.disconnect();
            const room = self.inbox.unusedCapacitySlice();
            const n = c.read(self.fd, room.ptr, room.len);
            if (n == 0) return self.disconnect();
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err == .INTR) continue;
                if (err == .AGAIN) break;
                return self.disconnect();
            }
            self.inbox.items.len += @intCast(n);
            any = self.takeLines() or any;
            if (self.fd < 0) return;
        }
        if (any) self.changed();
    }

    /// Applies every complete line; returns whether the model changed.
    fn takeLines(self: *Client) bool {
        var changed_any = false;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.inbox.items, start, '\n')) |end| {
            const line = self.inbox.items[start..end];
            start = end + 1;
            const changed_line = self.model.applyLine(gpa, line) catch |err| {
                log.warn("Files endpoint line rejected: {}", .{err});
                continue;
            };
            changed_any = changed_any or changed_line;
        }
        const rest = self.inbox.items.len - start;
        std.mem.copyForwards(u8, self.inbox.items[0..rest], self.inbox.items[start..]);
        self.inbox.shrinkRetainingCapacity(rest);
        if (rest > max_line) {
            log.warn("Files endpoint line too long; reconnecting", .{});
            self.disconnect();
            self.connect();
        }
        return changed_any;
    }

    fn onWatch(_: c_int, _: wl.EventMask, self: *Client) c_int {
        const Scan = struct {
            name: []const u8,
            seen: bool = false,
            lost: bool = false,
            fn event(scan: *@This(), ev: platform.watch.Event) void {
                if (ev.flags.overflow or std.mem.eql(u8, ev.name, scan.name)) scan.seen = true;
                if (ev.flags.lost()) scan.lost = true;
            }
        };
        var scan: Scan = .{ .name = self.socket_name };
        self.watcher.drainBounded(&scan, Scan.event, 8) catch {
            scan.lost = true;
        };
        if (scan.lost) {
            if (self.watch_source) |source| source.remove();
            self.watch_source = null;
            self.watcher.deinit();
            return 0;
        }
        // Files binds afresh after a crash, so a new socket replaces the
        // old connection's.
        if (scan.seen) {
            if (self.fd >= 0) self.disconnect();
            self.connectSoon();
        }
        return 0;
    }

    fn onTick(self: *Client) c_int {
        self.ticking = false;
        if (self.model.live_len == 0) return 0;
        self.model.tick();
        self.changed();
        return 0;
    }

    /// Clears the panel's done list.
    pub fn clearDone(self: *Client) void {
        self.model.clearDone();
        self.changed();
    }

    /// Something shown changed: the taskbar item, its icon and the panel.
    fn changed(self: *Client) void {
        if (self.model.live_len > 0 and !self.ticking) {
            if (self.timer) |timer| timer.timerUpdate(tick_ms) catch {};
            self.ticking = true;
        }
        if (self.model.present() != self.shown) return self.repaint();
        if (self.repaint_pending) return;
        self.repaint_pending = true;
        if (self.repaint_timer) |timer| timer.timerUpdate(repaint_ms) catch {};
    }

    fn onRepaint(self: *Client) c_int {
        self.repaint();
        return 0;
    }

    fn repaint(self: *Client) void {
        self.repaint_pending = false;
        if (self.repaint_timer) |timer| timer.timerUpdate(0) catch {};
        self.shown = self.model.present();
        @import("hooks.zig").changed(self.server, &self.model);
    }
};
