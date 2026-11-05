//! Page-owned CUPS change hints on the system bus. The upstream dbus notifier
//! uses a unique sender, without acquiring org.cups.cupsd.Notifier as a name.
//! Authenticate that sender through the bus daemon before requesting a reload.
//! Nothing in a notification is used as printer state or displayed to users.
const std = @import("std");
const dbus = @import("dbus");
const wl = @import("wayland").server.wl;
const wire = dbus.wire;
const eq = std.mem.eql;
const interface = "org.cups.cupsd.Notifier";
const path = "/org/cups/cupsd/Notifier";
const rule = "type='signal',interface='" ++ interface ++ "',path='" ++ path ++ "'";
const bus = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";

pub const Listener = struct {
    allocator: std.mem.Allocator,
    conn: *dbus.Connection,
    owner: *anyopaque,
    changed: *const fn (*anyopaque) void,
    uids: [3]u32 = .{ 0, 0, 0 },
    sender: ?[]u8 = null,
    pending_sender: ?[]u8 = null,
    closing: bool = false,
    /// True once AddMatch succeeds. IPP subscription creation and cancellation
    /// belong to the cancellable worker, never to a D-Bus callback.
    ready: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, env: std.process.Environ, loop: *wl.EventLoop, owner: *anyopaque, changed: *const fn (*anyopaque) void) !*Listener {
        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);
        const conn = try dbus.Connection.openSystem(allocator, loop, env);
        errdefer conn.destroy();
        self.* = .{ .allocator = allocator, .conn = conn, .owner = owner, .changed = changed };
        // Read only the local passwd database: NSS and user names from signals
        // must never introduce an unbounded resolver wait on the compositor.
        const passwd = std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", allocator, .limited(256 * 1024)) catch "";
        defer if (passwd.len != 0) allocator.free(passwd);
        self.uids = serviceUids(passwd, @intCast(std.c.getuid()));
        _ = try conn.hello(self, onHello);
        return self;
    }

    pub fn destroy(self: *Listener) void {
        self.closing = true;
        // Destroying this private connection atomically removes its matches
        // from the bus, including when Hello or authentication is pending.
        self.conn.destroy();
        if (self.sender) |sender| self.allocator.free(sender);
        if (self.pending_sender) |sender| self.allocator.free(sender);
        self.allocator.destroy(self);
    }

    fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Listener = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const msg = result catch return;
        if (!fromBus(msg) or msg.kind != .method_return) return;
        conn.registerSignal(.{ .path = path, .interface = interface, .owner = self, .callback = onSignal }) catch return;
        _ = conn.addMatch(rule, self, onMatch) catch return;
    }

    fn onMatch(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Listener = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const msg = result catch return;
        self.ready = fromBus(msg) and msg.kind == .method_return;
        // The initial inventory may have completed before AddMatch. Wake the
        // owner once so it can enable its worker's IPP subscription now.
        if (self.ready) self.changed(self.owner);
    }

    fn onSignal(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
        const self: *Listener = @ptrCast(@alignCast(owner orelse return));
        if (self.closing or !self.ready or msg.kind != .signal or
            !eq(u8, msg.headers.path orelse "", path) or
            !eq(u8, msg.headers.interface orelse "", interface) or
            !knownMember(msg.headers.member orelse "")) return;
        const sender = msg.headers.sender orelse return;
        if (sender.len < 2 or sender.len > 255 or sender[0] != ':') return;
        if (self.sender) |verified| {
            if (eq(u8, sender, verified)) {
                self.changed(self.owner);
                return;
            }
        }
        // One outstanding verification bounds work even if a client floods
        // signals. Unique sender names cannot change owners on a live bus.
        if (self.pending_sender != null) return;
        self.pending_sender = try self.allocator.dupe(u8, sender);
        errdefer {
            self.allocator.free(self.pending_sender.?);
            self.pending_sender = null;
        }
        var body: wire.Writer = .{ .allocator = self.allocator };
        defer body.deinit();
        try body.string(sender);
        _ = try conn.call(bus, bus_path, bus, "GetConnectionUnixUser", "s", &body, self, onCredentials, 1500);
    }

    fn onCredentials(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Listener = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const candidate = self.pending_sender orelse return;
        self.pending_sender = null;
        var keep = false;
        defer if (!keep) self.allocator.free(candidate);
        var msg = result catch return;
        if (!fromBus(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "u")) return;
        const uid = msg.body.uint32() catch return;
        if (!trustedUid(uid, self.uids)) return;
        if (self.sender) |old| self.allocator.free(old);
        self.sender = candidate;
        keep = true;
        self.changed(self.owner);
    }
};

fn fromBus(msg: wire.Message) bool {
    return eq(u8, msg.headers.sender orelse "", bus);
}

fn knownMember(member: []const u8) bool {
    for ([_][]const u8{
        "ServerRestarted",     "ServerStarted",            "ServerStopped",
        "PrinterRestarted",    "PrinterShutdown",          "PrinterStopped",
        "PrinterStateChanged", "PrinterFinishingsChanged", "PrinterMediaChanged",
        "PrinterAdded",        "PrinterDeleted",           "PrinterModified",
        "JobState",            "JobCreated",               "JobCompleted",
        "JobStopped",          "JobConfigChanged",         "JobProgress",
    }) |known| if (eq(u8, known, member)) return true;
    return false;
}

fn trustedUid(uid: u32, uids: [3]u32) bool {
    for (uids) |trusted| if (uid == trusted) return true;
    return false;
}

/// Common CUPS service accounts only. Custom users and a CUPS daemon run as
/// the desktop user safely retain action-driven refresh. A notification is
/// never a reason to accept another desktop user's sender as a system service.
fn serviceUids(passwd: []const u8, desktop_uid: u32) [3]u32 {
    var result: [3]u32 = .{ 0, 0, 0 };
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        if (!eq(u8, name, "lp") and !eq(u8, name, "cups")) continue;
        _ = fields.next() orelse continue;
        const uid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (uid == 0 or uid >= 1000 or uid == desktop_uid) continue;
        result[if (eq(u8, name, "lp")) @as(usize, 1) else 2] = uid;
    }
    return result;
}

test "notifier hints accept only known members and trusted service credentials" {
    const t = std.testing;
    const uids = serviceUids("alex:x:1000:1000::/:/bin/sh\nlp:x:7:7::/:/usr/bin/nologin\ncups:x:209:209::/:/usr/bin/nologin\n", 1000);
    try t.expect(trustedUid(0, uids));
    try t.expect(trustedUid(7, uids));
    try t.expect(trustedUid(209, uids));
    try t.expect(!trustedUid(1000, uids));
    try t.expect(knownMember("JobCompleted"));
    try t.expect(knownMember("ServerRestarted"));
    try t.expect(!knownMember("PrinterStateChangedInjected"));
    try t.expectEqual([3]u32{ 0, 0, 0 }, serviceUids("lp:x:1000:1000\ncups:x:99:99\n", 99));
}

test "notifier creation honours an explicit unavailable bus without contacting the host bus" {
    const t = std.testing;
    const display = try wl.Server.create();
    defer display.destroy();
    const env: std.process.Environ = .{ .block = .{ .slice = &.{"DBUS_SYSTEM_BUS_ADDRESS=unsupported:tag=x"} } };
    var callbacks: usize = 0;
    const Changed = struct {
        fn changed(owner: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(owner));
            count.* += 1;
        }
    };
    try t.expectError(error.NoSupportedAddress, Listener.create(t.allocator, t.io, env, display.getEventLoop(), &callbacks, Changed.changed));
    try t.expectEqual(@as(usize, 0), callbacks);
}

test "notifier ignores forged credential replies and untrusted desktop senders" {
    const t = std.testing;
    const Changed = struct {
        fn changed(owner: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(owner));
            count.* += 1;
        }
    };
    // Credential callbacks only need a borrowed connection identity; no socket
    // or real bus is opened by this test.
    var conn: dbus.Connection = undefined;
    var callbacks: usize = 0;
    var listener: Listener = .{ .allocator = t.allocator, .conn = &conn, .owner = &callbacks, .changed = Changed.changed, .uids = .{ 0, 7, 209 }, .ready = true };
    defer if (listener.sender) |sender| t.allocator.free(sender);
    var encoded_uid: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded_uid, 0, .little);
    var reply: wire.Message = .{ .kind = .method_return, .serial = 1, .headers = .{ .sender = ":1.forged", .signature = "u", .reply_serial = 1 }, .body = .{ .bytes = &encoded_uid } };
    listener.pending_sender = try t.allocator.dupe(u8, ":1.20");
    Listener.onCredentials(&listener, &conn, reply);
    try t.expect(listener.sender == null);
    try t.expect(listener.pending_sender == null);
    try t.expectEqual(@as(usize, 0), callbacks);

    reply.headers.sender = bus;
    std.mem.writeInt(u32, &encoded_uid, 1000, .little);
    listener.pending_sender = try t.allocator.dupe(u8, ":1.20");
    Listener.onCredentials(&listener, &conn, reply);
    try t.expect(listener.sender == null);
    try t.expectEqual(@as(usize, 0), callbacks);

    std.mem.writeInt(u32, &encoded_uid, 7, .little);
    listener.pending_sender = try t.allocator.dupe(u8, ":1.21");
    Listener.onCredentials(&listener, &conn, reply);
    try t.expectEqualStrings(":1.21", listener.sender.?);
    try t.expectEqual(@as(usize, 1), callbacks);
    var signal: wire.Message = .{ .kind = .signal, .serial = 2, .headers = .{ .sender = ":1.21", .path = path, .interface = interface, .member = "PrinterStateChanged" }, .body = .{ .bytes = &.{} } };
    try Listener.onSignal(&listener, &conn, signal);
    try t.expectEqual(@as(usize, 2), callbacks);
    signal.headers.interface = "untrusted.Notifier";
    try Listener.onSignal(&listener, &conn, signal);
    try t.expectEqual(@as(usize, 2), callbacks);
    listener.closing = true;
    signal.headers.interface = interface;
    try Listener.onSignal(&listener, &conn, signal);
    try t.expectEqual(@as(usize, 2), callbacks);
}
