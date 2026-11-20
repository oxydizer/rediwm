//! Client of `rediwm-cups`, the helper process that holds libcups, so the
//! compositor itself never maps libcups, gnutls or the other crypto libraries.
//! The validated helper-shaped arguments are an internal command format, not a
//! D-Bus dependency. The helper is started by the first request and killed by
//! `destroy`; if it dies, the request in flight fails and the next one starts a
//! fresh one. Frames are in `direct_protocol.zig`.
const std = @import("std");
const wire = @import("dbus").wire;
const wl = @import("wayland").server.wl;
const c = @import("c");
const platform = @import("platform");
const proto = @import("direct_protocol.zig");
const a = std.heap.c_allocator;

pub const helper_name = "rediwm-cups";

/// The helper's pidfd on the event loop: it reaps the process whenever it ends
/// and, while the worker still owns it, reports an unexpected death.
const Proc = struct {
    pid: platform.child.Pid,
    handle: platform.child.Handle,
    source: *wl.EventSource,
    worker: ?*Worker,

    fn watch(loop: *wl.EventLoop, pid: platform.child.Pid, worker: *Worker) !*Proc {
        const self = try a.create(Proc);
        errdefer a.destroy(self);
        const handle = try platform.child.Handle.open(pid);
        errdefer handle.close();
        self.* = .{ .pid = pid, .handle = handle, .source = undefined, .worker = worker };
        self.source = try loop.addFd(*Proc, handle.fd, .{ .readable = true }, exited, self);
        return self;
    }

    /// Ends the process; the watch stays until the exit is collected, and
    /// nobody is told about it.
    fn kill(self: *Proc) void {
        self.worker = null;
        self.handle.signal(.KILL) catch {};
    }

    fn exited(_: c_int, _: wl.EventMask, self: *Proc) c_int {
        _ = platform.child.reap(self.pid);
        const worker = self.worker;
        self.source.remove();
        self.handle.close();
        a.destroy(self);
        if (worker) |w| {
            w.proc = null;
            w.lost();
        }
        return 0;
    }
};

pub const Worker = struct {
    io: std.Io,
    loop: *wl.EventLoop,
    owner: *anyopaque,
    callback: *const fn (*anyopaque) void,
    exe_buffer: [4096]u8 = undefined,
    exe: [:0]const u8 = undefined,
    sock: c_int = -1,
    source: ?*wl.EventSource = null,
    proc: ?*Proc = null,
    receiver: proto.Receiver = .{},
    inbound: [proto.max_report]u8 = undefined,
    /// What the helper last reported: 0 working, 1 wants a password, 2 done.
    /// Like the C worker's, it starts at 2 and `submit` moves it to 0.
    state_value: c_int = 2,
    result_value: c_int = 0,
    discovery: bool = false,
    arena: std.heap.ArenaAllocator = .init(a),
    found: std.ArrayList([5][]const u8) = .empty,

    /// Finds the helper but does not start it.
    pub fn create(io: std.Io, loop: *wl.EventLoop, owner: *anyopaque, callback: *const fn (*anyopaque) void) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        self.* = .{ .io = io, .loop = loop, .owner = owner, .callback = callback };
        self.exe = platform.exe.sibling(&self.exe_buffer, helper_name) orelse return error.NoExecutable;
        if (c.access(self.exe.ptr, c.X_OK) != 0) return error.NoExecutable;
        return self;
    }

    /// Kills the helper, even in the middle of a request or a password prompt.
    /// No callback follows.
    pub fn destroy(self: *Worker) void {
        self.dropConnection();
        self.found.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn state(self: *Worker) c_int {
        return self.state_value;
    }

    pub fn result(self: *Worker) c_int {
        return self.result_value;
    }

    fn connect(self: *Worker) !void {
        if (self.sock >= 0) return;
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &pair) != 0) return error.SocketFailed;
        // The helper's end is its stdin; ours must not outlive this call in the child.
        defer _ = c.close(pair[1]);
        errdefer _ = c.close(pair[0]);
        var process = try std.process.spawn(self.io, .{
            .argv = &.{self.exe},
            .stdin = .{ .file = .{ .handle = pair[1], .flags = .{ .nonblocking = false } } },
            .stdout = .ignore,
        });
        const pid = process.id.?;
        process.id = null;
        const proc = Proc.watch(self.loop, pid, self) catch |err| {
            platform.child.killAndReap(pid);
            return err;
        };
        const source = self.loop.addFd(*Worker, pair[0], .{ .readable = true }, readable, self) catch |err| {
            proc.kill();
            return err;
        };
        self.sock = pair[0];
        self.source = source;
        self.proc = proc;
        self.receiver = .{};
    }

    fn dropConnection(self: *Worker) void {
        if (self.source) |source| source.remove();
        self.source = null;
        if (self.sock >= 0) _ = c.close(self.sock);
        self.sock = -1;
        if (self.proc) |proc| proc.kill();
        self.proc = null;
    }

    /// The helper ended or broke the protocol. A request in flight fails as an
    /// uncertain result (the callback comes last: it may free the worker).
    fn lost(self: *Worker) void {
        self.dropConnection();
        if (self.state_value == 2) return;
        self.state_value = 2;
        self.result_value = 1;
        self.callback(self.owner);
    }

    /// Ends the helper without reporting it here: its socket then reads as
    /// closed, which `lost` turns into a failed request on the next loop turn.
    fn poison(self: *Worker) void {
        if (self.proc) |proc| proc.handle.signal(.KILL) catch {};
    }

    pub fn destination(self: *Worker, _: u8, len: usize) ?[]u8 {
        return if (len <= self.inbound.len) &self.inbound else null;
    }

    fn readable(_: c_int, _: wl.EventMask, self: *Worker) c_int {
        // One frame per call: the callback may free the worker, and the loop
        // is level-triggered, so a second frame is simply the next call.
        switch (self.receiver.read(self.sock, self)) {
            .again => {},
            .frame => self.deliver(),
            .closed, .invalid => self.lost(),
        }
        return 0;
    }

    fn deliver(self: *Worker) void {
        const payload = self.receiver.payload();
        switch (@as(proto.Report, @enumFromInt(self.receiver.kind))) {
            .state => {
                // A prompt is only valid while a request runs, and an end for one
                // that is running or waiting for a password. Anything else means
                // the helper is confused: do not trust it.
                const next: u8 = if (payload.len == 5) payload[0] else 0;
                const valid = switch (self.state_value) {
                    0 => next == 1 or next == 2,
                    1 => next == 2,
                    else => false,
                };
                if (!valid) return self.lost();
                self.state_value = next;
                self.result_value = std.mem.readInt(i32, payload[1..5], .little);
                self.callback(self.owner);
            },
            .device => {
                var fields: [5][:0]const u8 = undefined;
                const count = proto.strings(payload, &fields) orelse return self.lost();
                if (count != 5 or !self.discovery or self.state_value != 0 or self.found.items.len >= proto.max_devices) return self.lost();
                var device: [5][]const u8 = undefined;
                const mem = self.arena.allocator();
                for (fields, 0..) |field, i| device[i] = mem.dupe(u8, field) catch return self.lost();
                self.found.append(a, device) catch return self.lost();
            },
            _ => self.lost(),
        }
    }

    fn clearDevices(self: *Worker) void {
        self.found.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn cancel(self: *Worker) void {
        if (self.sock >= 0 and !proto.send(self.sock, @intFromEnum(proto.Command.cancel), &.{})) self.poison();
    }

    pub fn finish(self: *Worker) void {
        if (self.sock >= 0 and !proto.send(self.sock, @intFromEnum(proto.Command.finish), &.{})) self.poison();
    }

    /// The password goes from the caller's locked storage into the socket
    /// without being copied, and the helper receives it into a locked page.
    pub fn credentials(self: *Worker, user: []const u8, password: []const u8) !void {
        if (user.len == 0 or user.len > proto.max_user or password.len > proto.max_password) return error.InvalidCredentials;
        for (user) |ch| if (ch < 0x21 or ch == 0x7f) return error.InvalidCredentials;
        if (std.mem.indexOfScalar(u8, password, 0) != null) return error.InvalidCredentials;
        if (self.state_value != 1 or self.sock < 0) return;
        const nul = [_]u8{0};
        if (!proto.send(self.sock, @intFromEnum(proto.Command.credentials), &.{ user, &nul, password })) return self.poison();
        self.state_value = 0;
    }

    fn appendString(list: *std.ArrayList(u8), value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidArgument;
        try list.appendSlice(a, value);
        try list.append(a, 0);
    }

    pub fn submit(self: *Worker, method: []const u8, signature: []const u8, bytes: []const u8, reset: bool) !void {
        if (self.state_value != 2) return error.Busy;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(a);
        try payload.append(a, @intFromBool(reset));
        try appendString(&payload, method);
        const discovery = std.mem.eql(u8, method, "DevicesGet");
        if (!discovery) {
            var reader: wire.Reader = .{ .bytes = bytes };
            var count: usize = 0;
            var i: usize = 0;
            while (i < signature.len) : (i += 1) switch (signature[i]) {
                's' => {
                    count += 1;
                    try appendString(&payload, try reader.string());
                },
                'b' => {
                    count += 1;
                    try appendString(&payload, if (try reader.boolean()) "true" else "false");
                },
                'a' => {
                    i += 1;
                    if (i >= signature.len or signature[i] != 's') return error.InvalidSignature;
                    var values = try reader.array(4);
                    while (values.offset < values.bytes.len) {
                        count += 1;
                        try appendString(&payload, try values.string());
                    }
                },
                else => return error.InvalidSignature,
            };
            try reader.done();
            if (count > proto.max_args) return error.TooManyArguments;
        }
        if (payload.items.len > proto.max_command) return error.RequestTooLarge;
        try self.connect();
        if (!proto.send(self.sock, @intFromEnum(proto.Command.submit), &.{payload.items})) {
            self.dropConnection();
            return error.WorkerFailed;
        }
        self.discovery = discovery;
        if (discovery) self.clearDevices();
        self.state_value = 0;
        self.result_value = 0;
    }

    pub fn devices(self: *Worker, writer: *wire.Writer) !void {
        const dict = try writer.beginArray(8);
        const names = [_][]const u8{ "device-uri", "device-info", "device-make-and-model", "device-id", "device-class" };
        for (self.found.items, 0..) |device, i| {
            for (names, device) |name, value| {
                var key: [64]u8 = undefined;
                try writer.alignTo(8);
                try writer.string(try std.fmt.bufPrint(&key, "{s}:{d}", .{ name, i }));
                try writer.string(value);
            }
        }
        try writer.endArray(dict);
    }
};
