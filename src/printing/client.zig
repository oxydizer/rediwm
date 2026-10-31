//! The Printers page owns this worker and both eventfds. Idle blocks forever;
//! hiding the page cancels socket I/O, joins the worker, and drops its inventory.
const std = @import("std");
const wl = @import("wayland").server.wl;
const cups = @import("cups.zig");
const usb = @import("usb_sysfs.zig");
const http = @import("http.zig");
const tools = @import("tools.zig");
const preferences = @import("preferences.zig");
const options = @import("options.zig");
const endpoint = @import("endpoint.zig");
const platform = @import("platform.zig");
const daemon_watch = @import("daemon_watch.zig");
const c = @import("native.zig").c;
const a = std.heap.c_allocator;

pub const State = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    generation: u64 = 0,
    cups: ?cups.Snapshot = null,
    usb: ?usb.Snapshot = null,
    failure: ?anyerror = null,
    action_error: ?anyerror = null,
    selected: []const u8 = "",
    groups: []const options.Group = &.{},
    ppd: []const u8 = "",
    remote: bool = false,
    admin_local: bool = false,
    platform: platform.Info = .{},
    receipt: ?Receipt = null,
    probe: ?bool = null,
    fn destroy(self: *State) void {
        if (self.cups) |*snapshot| snapshot.deinit();
        if (self.usb) |snapshot| snapshot.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }
};

pub const TestKind = enum { driver, raw, ruler };
pub const Print = struct { queue: []const u8, kind: TestKind, media: tools.Media, media_keyword: []const u8 = "", language: ?tools.Language = null, dpi: u32 = 203, queue_resolution: ?cups.ipp.Resolution = null };
pub const Receipt = struct {
    id: i32,
    kind: TestKind,
    media: tools.Media,
    language: ?tools.Language,
    queue_resolution: ?cups.ipp.Resolution,
    queue_name: [128]u8 = @splat(0),
    queue_len: usize = 0,

    pub fn matchesQueue(self: Receipt, queue: []const u8) bool {
        return self.queue_len > 0 and self.queue_len <= self.queue_name.len and std.mem.eql(u8, self.queue_name[0..self.queue_len], queue);
    }
};
pub const Save = struct { queue: []const u8, state: preferences.UserState };
pub const Rename = struct { old: []const u8, new: []const u8 };
pub const Action = union(enum) { refresh, catalog, select: []const u8, cancel_job: i32, personal_default: []const u8, save: Save, test_print: Print, probe: []const u8, rename_preferences: Rename };
const Command = struct {
    arena: std.heap.ArenaAllocator,
    action: Action,
    fn create(action: Action) !*Command {
        const self = try a.create(Command);
        self.* = .{ .arena = .init(a), .action = action };
        errdefer self.destroy();
        const mem = self.arena.allocator();
        self.action = switch (action) {
            .select => |value| .{ .select = try mem.dupe(u8, value) },
            .personal_default => |value| .{ .personal_default = try mem.dupe(u8, value) },
            .probe => |value| .{ .probe = try mem.dupe(u8, value) },
            .save => |value| .{ .save = .{ .queue = try mem.dupe(u8, value.queue), .state = value.state } },
            .rename_preferences => |value| .{ .rename_preferences = .{ .old = try mem.dupe(u8, value.old), .new = try mem.dupe(u8, value.new) } },
            .test_print => |value| blk: {
                var copy = value;
                copy.queue = try mem.dupe(u8, value.queue);
                copy.media_keyword = try mem.dupe(u8, value.media_keyword);
                break :blk .{ .test_print = copy };
            },
            else => action,
        };
        return self;
    }
    fn destroy(self: *Command) void {
        self.arena.deinit();
        a.destroy(self);
    }
};

pub const Client = struct {
    io: std.Io,
    env: std.process.Environ,
    owner: *anyopaque,
    changed: *const fn (*anyopaque) void,
    source: ?*wl.EventSource = null,
    wake_worker: c_int = -1,
    wake_main: c_int = -1,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    reload: std.atomic.Value(bool) = .init(true),
    command: ?*Command = null,
    loading: std.atomic.Value(bool) = .init(false),
    subscriptions: std.atomic.Value(bool) = .init(false),
    subscription_id: ?i32 = null,
    subscription_attempted: bool = false,
    subscription_server: [1024]u8 = undefined,
    subscription_server_len: usize = 0,
    subscription_user: [256]u8 = undefined,
    subscription_user_len: usize = 0,
    watch: ?daemon_watch.Watch = null,
    selected_queue: [512]u8 = undefined,
    selected_len: usize = 0,
    want_catalog: bool = false,
    receipt: ?Receipt = null,
    probe_result: ?bool = null,
    mutex: c.pthread_mutex_t = undefined,
    /// Guarded with mutex along with commands and pending snapshots. A USB
    /// reload begun before a user action must not clear that action's busy flag.
    generation: u64 = 0,
    pending: ?*State = null,
    pending_allocation_failure: ?u64 = null,
    current: ?*State = null,
    failure: ?anyerror = null,
    busy: bool = true,

    pub fn create(io: std.Io, env: std.process.Environ, loop: *wl.EventLoop, owner: *anyopaque, changed: *const fn (*anyopaque) void) !*Client {
        const self = try a.create(Client);
        errdefer a.destroy(self);
        self.* = .{ .io = io, .env = env, .owner = owner, .changed = changed };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        self.wake_worker = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_worker < 0) return error.EventFdFailed;
        errdefer _ = c.close(self.wake_worker);
        self.wake_main = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_main < 0) return error.EventFdFailed;
        errdefer _ = c.close(self.wake_main);
        self.source = try loop.addFd(*Client, self.wake_main, .{ .readable = true }, ready, self);
        errdefer self.source.?.remove();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.thread.?.setName(io, "rediwm-printers") catch {};
        return self;
    }
    pub fn destroy(self: *Client) void {
        self.source.?.remove();
        self.stop.store(true, .release);
        signal(self.wake_worker);
        self.thread.?.join();
        _ = c.close(self.wake_worker);
        _ = c.close(self.wake_main);
        if (self.pending) |state| state.destroy();
        if (self.current) |state| state.destroy();
        if (self.command) |command| command.destroy();
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }
    pub fn refresh(self: *Client) void {
        self.act(.refresh) catch {};
    }
    pub fn invalidate(self: *Client) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.reload.store(true, .release);
        if (!self.loading.load(.acquire)) signal(self.wake_worker);
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    pub fn enableSubscriptions(self: *Client) void {
        if (self.subscriptions.swap(true, .acq_rel)) return;
        self.invalidate();
    }
    pub fn act(self: *Client, action: Action) !void {
        if (self.busy) return error.Busy;
        const command = try Command.create(action);
        self.busy = true;
        self.failure = null;
        _ = c.pthread_mutex_lock(&self.mutex);
        self.generation +%= 1;
        self.command = command;
        self.reload.store(true, .release);
        signal(self.wake_worker);
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    pub fn cancelJob(self: *Client, id: i32) void {
        if (self.busy or id <= 0) return;
        // Recheck ownership against our current snapshot, outside the widget.
        const snapshot = if (self.current) |state| state.cups orelse return else return;
        for (snapshot.jobs) |job| if (job.id == id and job.cancellable()) {
            self.act(.{ .cancel_job = id }) catch {};
            return;
        };
    }
    fn ready(_: c_int, _: wl.EventMask, self: *Client) c_int {
        drain(self.wake_main);
        _ = c.pthread_mutex_lock(&self.mutex);
        const state = self.pending;
        self.pending = null;
        const generation = self.generation;
        const allocation_failure = self.pending_allocation_failure;
        self.pending_allocation_failure = null;
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (state) |next| {
            if (self.current) |previous| previous.destroy();
            self.current = next;
            if (next.generation == generation) self.busy = false;
        }
        if (allocation_failure) |failed_generation| if (failed_generation == generation) {
            self.busy = false;
            self.failure = error.OutOfMemory;
        };
        if (state != null or allocation_failure != null) self.changed(self.owner);
        return 0;
    }
    fn publish(self: *Client, state: *State) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        if (self.pending) |old| old.destroy();
        self.pending = state;
        _ = c.pthread_mutex_unlock(&self.mutex);
        signal(self.wake_main);
    }
    fn load(self: *Client, command: ?*Command, generation: u64) !*State {
        defer if (command) |item| item.destroy();
        const state = try a.create(State);
        state.* = .{};
        errdefer state.destroy();
        state.generation = generation;
        state.usb = usb.scan(a, self.io, .{}) catch null;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const mem = arena.allocator();
        state.platform = platform.load(state.arena.allocator(), self.io) catch .{};
        const socket = cups.server(mem, self.io, self.env) catch |err| {
            state.failure = err;
            return state;
        };
        if (self.subscription_id != null and !std.mem.eql(u8, socket, self.subscription_server[0..self.subscription_server_len])) self.cancelSubscription();
        const username = cups.user(mem) catch |err| {
            state.failure = err;
            return state;
        };
        state.remote = (try endpoint.parseServer(socket)).unix == null;
        state.admin_local = for (cups.local_sockets) |path| {
            if (std.mem.eql(u8, socket, path)) break true;
        } else false;
        if (self.watch) |*watch| if (watch.fd() < 0) {
            watch.deinit(a);
            self.watch = null;
        };
        if (self.watch == null) self.watch = daemon_watch.Watch.init(a, socket) catch null;
        if (command) |item| self.perform(mem, socket, username, item.action) catch |err| {
            if (err == error.Cancelled) return err;
            state.action_error = err;
        };
        state.cups = cups.load(a, self.io, socket, username, self.wake_worker) catch |err| {
            if (err == error.Cancelled) return err;
            state.failure = err;
            self.subscription_attempted = self.subscription_id != null;
            return state;
        };
        const data = &state.cups.?;
        const owned = data.arena.allocator();
        data.user_default = (preferences.defaultPrinter(owned, self.io, self.env) catch null) orelse "";
        for (data.printers) |*printer| {
            printer.user = preferences.loadState(owned, self.io, self.env, printer.name) catch .{};
            if (printer.device_id.len == 0) if (state.usb) |*inventory| {
                const match = usb.matchQueue(inventory, printer.device_uri);
                if (match.device) |device| printer.device_id = try owned.dupe(u8, device.device_id);
            };
            if (nodePath(printer.device_uri)) |path| printer.node_kind = if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |stat| switch (stat.kind) {
                .character_device => .character,
                .file => .regular,
                else => .other,
            } else |err| if (err == error.FileNotFound) .missing else .unavailable;
        }
        if (self.want_catalog) data.drivers = cups.drivers(owned, self.io, socket, username, self.wake_worker) catch |err| blk: {
            if (err == error.Cancelled) return err;
            data.drivers_error = err;
            break :blk &.{};
        };
        if (self.selected_len == 0 and data.printers.len > 0) self.setSelected(data.printers[0].name);
        state.selected = try owned.dupe(u8, self.selected_queue[0..self.selected_len]);
        for (data.printers) |*printer| if (std.mem.eql(u8, printer.name, state.selected)) {
            state.groups = options.parseAttributes(owned, printer.attributes) catch &.{};
            state.ppd = cups.ppd(owned, self.io, socket, username, printer.name, self.wake_worker) catch |err| blk: {
                if (err == error.Cancelled) return err;
                break :blk "";
            };
            if (state.ppd.len > 0) {
                const extra = options.parsePpd(owned, state.ppd) catch &.{};
                state.groups = try std.mem.concat(owned, options.Group, &.{ state.groups, extra });
            }
            if (std.mem.startsWith(u8, printer.device_uri, "ipp://")) {
                _ = cups.probe(owned, self.io, printer.device_uri, username, self.wake_worker) catch |err| {
                    if (err == error.Cancelled) return err;
                    printer.network_reachable = false;
                    break;
                };
                printer.network_reachable = true;
            }
            break;
        };
        if (!state.remote and self.subscriptions.load(.acquire) and !self.subscription_attempted) {
            self.subscription_attempted = true;
            self.subscription_id = cups.subscribe(mem, self.io, socket, username, self.wake_worker) catch null;
            if (self.subscription_id != null) {
                self.subscription_server_len = @min(socket.len, self.subscription_server.len);
                @memcpy(self.subscription_server[0..self.subscription_server_len], socket[0..self.subscription_server_len]);
                self.subscription_user_len = @min(username.len, self.subscription_user.len);
                @memcpy(self.subscription_user[0..self.subscription_user_len], username[0..self.subscription_user_len]);
            }
        }
        state.receipt = self.receipt;
        state.probe = self.probe_result;
        return state;
    }
    fn setSelected(self: *Client, value: []const u8) void {
        if (!std.mem.eql(u8, value, self.selected_queue[0..self.selected_len])) self.receipt = null;
        self.selected_len = @min(value.len, self.selected_queue.len);
        @memcpy(self.selected_queue[0..self.selected_len], value[0..self.selected_len]);
    }
    fn perform(self: *Client, mem: std.mem.Allocator, socket: []const u8, username: []const u8, action: Action) !void {
        switch (action) {
            .refresh => {},
            .catalog => self.want_catalog = true,
            .select => |queue| self.setSelected(queue),
            .cancel_job => |id| try cups.cancelJob(mem, self.io, socket, username, id, self.wake_worker),
            .personal_default => |queue| try preferences.setDefault(mem, self.io, self.env, queue),
            .save => |value| try preferences.saveState(mem, self.io, self.env, value.queue, value.state),
            .rename_preferences => |value| {
                self.setSelected(value.new);
                preferences.renameQueue(mem, self.io, self.env, value.old, value.new) catch return error.PreferencesMigration;
            },
            .probe => |uri| {
                self.probe_result = null;
                self.probe_result = try cups.probe(mem, self.io, uri, username, self.wake_worker);
            },
            .test_print => |value| {
                self.receipt = null;
                if (!preferences.validQueue(value.queue)) return error.InvalidPrinterName;
                const document = if (value.kind == .raw)
                    try tools.rawTest(mem, value.language orelse return error.UnknownLanguage, value.media, value.dpi)
                else
                    try tools.testPdf(mem, value.media, if (value.kind == .ruler) .ruler else .page);
                const id = try cups.print(mem, self.io, socket, username, value.queue, value.kind == .raw, value.media_keyword, document, self.wake_worker);
                var receipt: Receipt = .{ .id = id, .kind = value.kind, .media = value.media, .language = value.language, .queue_resolution = value.queue_resolution, .queue_len = value.queue.len };
                @memcpy(receipt.queue_name[0..value.queue.len], value.queue);
                self.receipt = receipt;
            },
        }
    }
    fn run(self: *Client) void {
        var netlink = ueventSocket();
        defer if (netlink >= 0) {
            _ = c.close(netlink);
        };
        defer if (self.watch) |*watch| watch.deinit(a);
        var rescan_at: ?i64 = null;
        while (!self.stop.load(.acquire)) {
            if (self.reload.swap(false, .acq_rel)) {
                _ = c.pthread_mutex_lock(&self.mutex);
                const command = self.command;
                self.command = null;
                const generation = self.generation;
                drain(self.wake_worker);
                const stopping = self.stop.load(.acquire);
                self.loading.store(true, .release);
                _ = c.pthread_mutex_unlock(&self.mutex);
                if (stopping) {
                    if (command) |item| item.destroy();
                    break;
                }
                const state = self.load(command, generation) catch |err| {
                    self.loading.store(false, .release);
                    if (err == error.Cancelled) {
                        if (!self.stop.load(.acquire)) self.reload.store(true, .release);
                    } else {
                        _ = c.pthread_mutex_lock(&self.mutex);
                        if (self.command) |queued| queued.destroy();
                        self.command = null;
                        self.reload.store(false, .release);
                        self.pending_allocation_failure = self.generation;
                        _ = c.pthread_mutex_unlock(&self.mutex);
                        signal(self.wake_main);
                    }
                    continue;
                };
                self.loading.store(false, .release);
                self.publish(state);
                rescan_at = null;
            }
            if (self.reload.load(.acquire)) continue;
            const timeout: c_int = if (rescan_at) |deadline| @intCast(@max(0, deadline - http.nowMs())) else -1;
            var fds = [_]c.struct_pollfd{ .{ .fd = self.wake_worker, .events = c.POLLIN, .revents = 0 }, .{ .fd = netlink, .events = c.POLLIN, .revents = 0 }, .{ .fd = if (self.watch) |watch| watch.fd() else -1, .events = c.POLLIN, .revents = 0 } };
            const n = c.poll(&fds, fds.len, timeout);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return;
            }
            if (fds[0].revents != 0) drain(self.wake_worker);
            if (fds[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) {
                _ = c.close(netlink);
                netlink = -1;
            }
            if (fds[1].revents & c.POLLIN != 0 and drainUevents(netlink) and rescan_at == null) rescan_at = http.nowMs() + 300;
            if (fds[2].revents != 0) if (self.watch) |*watch| if (watch.changed()) {
                self.cancelSubscription();
                self.subscription_attempted = false;
                if (rescan_at == null) rescan_at = http.nowMs() + 100;
            };
            if (rescan_at) |deadline| if (http.nowMs() >= deadline) {
                self.reload.store(true, .release);
            };
        }
        self.cancelSubscription();
    }
    fn cancelSubscription(self: *Client) void {
        if (self.subscription_id) |id| cups.unsubscribeNoWait(self.subscription_server[0..self.subscription_server_len], self.subscription_user[0..self.subscription_user_len], id);
        self.subscription_id = null;
        self.subscription_attempted = false;
    }
};

fn signal(fd: c_int) void {
    const one: u64 = 1;
    _ = c.write(fd, &one, @sizeOf(u64));
}
fn nodePath(uri: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return null;
    const backend = uri[0..colon];
    if (!std.mem.eql(u8, backend, "file") and !std.mem.eql(u8, backend, "tspl")) return null;
    var path = uri[colon + 1 ..];
    if (std.mem.startsWith(u8, path, "//")) {
        if (!std.mem.startsWith(u8, path, "///")) return null;
        path = path[2..];
    }
    const prefix = "/dev/usb/";
    if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len or path.len > 255) return null;
    const leaf = path[prefix.len..];
    if (std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return null;
    for (leaf) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return null;
    return path;
}
fn drain(fd: c_int) void {
    var count: u64 = 0;
    _ = c.read(fd, &count, @sizeOf(u64));
}
fn ueventSocket() c_int {
    const fd = c.socket(c.AF_NETLINK, c.SOCK_DGRAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, c.NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;
    var addr = std.mem.zeroes(c.struct_sockaddr_nl);
    addr.nl_family = c.AF_NETLINK;
    addr.nl_groups = 1;
    if (c.bind(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_nl)) != 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
}
fn drainUevents(fd: c_int) bool {
    var changed = false;
    for (0..256) |_| {
        var bytes: [8192]u8 = undefined;
        var sender: c.struct_sockaddr_nl = undefined;
        var len: c.socklen_t = @sizeOf(c.struct_sockaddr_nl);
        const n = c.recvfrom(fd, &bytes, bytes.len, 0, .{ .__sockaddr__ = @ptrCast(&sender) }, &len);
        if (n <= 0) break;
        if (sender.nl_pid != 0) continue;
        var words = std.mem.splitScalar(u8, bytes[0..@intCast(n)], 0);
        while (words.next()) |word| if (std.mem.eql(u8, word, "SUBSYSTEM=usb") or std.mem.eql(u8, word, "SUBSYSTEM=usbmisc")) {
            changed = true;
        };
    }
    return changed;
}
