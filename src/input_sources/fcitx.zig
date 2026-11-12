//! Fcitx5 on the session bus, read and switched only: RediWM lists the input
//! methods of Fcitx's current group and asks Fcitx to change between them, and
//! never writes Fcitx's configuration (`fcitx5-configtool` stays its editor).
//! Keyboard layouts belong to RediWM, so Fcitx's `keyboard-*` entries are not
//! listed.
//!
//! Event-driven: NameOwnerChanged follows Fcitx starting, crashing and
//! restarting. Controller1 has no signal for the current method, but Fcitx
//! updates its tray item (and other objects it owns) on every change, so any
//! signal from Fcitx's unique name asks for `CurrentInputMethod` again, one
//! call at a time. `InputMethodGroupsChanged` re-reads the list.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;

const log = std.log.scoped(.input_sources);

pub const bus_name = "org.fcitx.Fcitx5";
const object_path = "/controller";
const interface = "org.fcitx.Fcitx.Controller1";
const call_timeout_ms: u32 = 3000;
const owner_rule = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',path='/org/freedesktop/DBus',arg0='" ++ bus_name ++ "'";

pub const Method = struct {
    /// Fcitx's unique name, e.g. "mozc", "pinyin".
    name: []const u8,
    /// "Mozc", or the native name when Fcitx has one.
    display: []const u8,
    /// Fcitx's short label ("あ", "拼"), or "".
    label: []const u8,
    /// Language code ("ja", "zh_CN"), or "".
    language: []const u8,
};

pub fn isKeyboard(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "keyboard-");
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    loop: *@import("wayland").server.wl.EventLoop,
    environ: std.process.Environ,
    conn: ?*dbus.Connection = null,
    owner: ?[]u8 = null,
    owner_rule_buf: [128]u8 = undefined,
    owner_rule_len: usize = 0,
    /// Each new owner starts a new epoch; replies from an older one are dropped.
    epoch: u64 = 0,
    closing: bool = false,

    /// What Fcitx reported last, owned by `arena`.
    arena: std.heap.ArenaAllocator,
    methods: []Method = &.{},
    current_buf: [128]u8 = undefined,
    current_len: usize = 0,
    group_buf: [128]u8 = undefined,
    group_len: usize = 0,

    querying: bool = false,
    query_again: bool = false,
    refreshing: bool = false,
    refresh_again: bool = false,

    /// Called after any change to `methods`, `current` or `running`.
    on_change: ?*const fn (owner: ?*anyopaque) void = null,
    change_owner: ?*anyopaque = null,

    pub fn create(allocator: std.mem.Allocator, loop: anytype, environ: std.process.Environ) !*Client {
        const self = try allocator.create(Client);
        self.* = .{ .allocator = allocator, .loop = loop, .environ = environ, .arena = .init(allocator) };
        self.connect();
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.closing = true;
        if (self.conn) |conn| conn.destroy();
        if (self.owner) |owner| self.allocator.free(owner);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn running(self: *const Client) bool {
        return self.owner != null;
    }

    /// Fcitx's current method, keyboards included; null while not running.
    pub fn current(self: *const Client) ?[]const u8 {
        if (self.owner == null or self.current_len == 0) return null;
        return self.current_buf[0..self.current_len];
    }

    /// The method from the list that is active, if any (not a keyboard).
    pub fn activeMethod(self: *const Client) ?usize {
        const name = self.current() orelse return null;
        for (self.methods, 0..) |method, i| if (std.mem.eql(u8, method.name, name)) return i;
        return null;
    }

    pub fn select(self: *Client, name: []const u8) void {
        var body = self.writer();
        defer body.deinit();
        body.string(name) catch return;
        self.send("SetCurrentIM", "s", &body);
        // Fcitx answers with a tray update as well; ask directly in case it does not.
        self.queryCurrent();
    }

    /// Back to plain keyboard input: Fcitx's inactive state passes keys to the
    /// layout RediWM chose.
    pub fn deactivate(self: *Client) void {
        if (self.activeMethod() == null) return;
        var body = self.writer();
        defer body.deinit();
        self.send("Deactivate", "", &body);
        self.queryCurrent();
    }

    fn writer(self: *Client) wire.Writer {
        return .{ .allocator = self.allocator };
    }

    fn send(self: *Client, member: []const u8, signature: []const u8, body: *const wire.Writer) void {
        const conn = self.conn orelse return;
        if (conn.closed or self.owner == null) return;
        _ = conn.call(bus_name, object_path, interface, member, signature, body, null, null, call_timeout_ms) catch |err| {
            log.warn("fcitx {s} failed: {}", .{ member, err });
        };
    }

    fn notify(self: *Client) void {
        if (self.closing) return;
        if (self.on_change) |callback| callback(self.change_owner);
    }

    fn connect(self: *Client) void {
        const conn = dbus.Connection.openSession(self.allocator, self.loop, self.environ) catch |err| {
            log.info("no session bus, Fcitx input methods unavailable: {}", .{err});
            return;
        };
        _ = conn.hello(self, onHello) catch |err| {
            log.warn("could not register on the session bus: {}", .{err});
            conn.destroy();
            return;
        };
        conn.on_disconnect = .{ .owner = self, .callback = onDisconnect };
        self.conn = conn;
    }

    fn onDisconnect(owner: ?*anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        self.setOwner(null);
    }

    fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Client = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        const msg = result catch {
            conn.close();
            return;
        };
        if (msg.kind != .method_return) {
            conn.close();
            return;
        }
        conn.registerSignal(.{
            .sender = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameOwnerChanged",
            .owner = self,
            .callback = onNameOwnerChanged,
        }) catch return;
        // Everything Fcitx emits; the sender is checked in the handler.
        conn.registerSignal(.{ .owner = self, .callback = onFcitxSignal }) catch return;
        _ = conn.addMatch(owner_rule, null, null) catch return;
        var body = self.writer();
        defer body.deinit();
        body.string(bus_name) catch return;
        _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &body, self, onNameOwner, call_timeout_ms) catch {};
    }

    fn onNameOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Client = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var msg = result catch return;
        if (msg.kind != .method_return) return; // Fcitx is not running yet.
        const unique = msg.body.string() catch return;
        if (self.owner != null) return; // NameOwnerChanged was first.
        self.setOwner(unique);
    }

    fn onNameOwnerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(owner orelse return));
        if (self.closing) return;
        var body = msg.body;
        const name = try body.string();
        _ = try body.string();
        const new_owner = try body.string();
        if (!std.mem.eql(u8, name, bus_name)) return;
        self.setOwner(if (new_owner.len == 0) null else new_owner);
    }

    fn setOwner(self: *Client, unique: ?[]const u8) void {
        if (self.conn) |conn| if (self.owner_rule_len > 0 and !conn.closed) {
            _ = conn.removeMatch(self.owner_rule_buf[0..self.owner_rule_len], null, null) catch {};
        };
        self.owner_rule_len = 0;
        if (self.owner) |old| self.allocator.free(old);
        self.owner = null;
        self.epoch +%= 1;
        _ = self.arena.reset(.retain_capacity);
        self.methods = &.{};
        self.current_len = 0;
        self.group_len = 0;
        self.querying = false;
        self.query_again = false;
        self.refreshing = false;
        self.refresh_again = false;
        if (unique) |name| {
            self.owner = self.allocator.dupe(u8, name) catch null;
            if (self.owner != null) {
                log.info("Fcitx5 is running ({s})", .{name});
                if (self.conn) |conn| {
                    const rule = std.fmt.bufPrint(&self.owner_rule_buf, "type='signal',sender='{s}'", .{name}) catch "";
                    self.owner_rule_len = rule.len;
                    if (rule.len > 0) _ = conn.addMatch(rule, null, null) catch {};
                }
                self.refresh();
            }
        } else log.info("Fcitx5 is not running", .{});
        self.notify();
    }

    fn fromOwner(self: *const Client, msg: wire.Message) bool {
        const owner = self.owner orelse return false;
        return std.mem.eql(u8, owner, msg.headers.sender orelse "");
    }

    fn onFcitxSignal(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(owner orelse return));
        if (self.closing or !self.fromOwner(msg)) return;
        if (std.mem.eql(u8, msg.headers.member orelse "", "InputMethodGroupsChanged")) self.refresh() else self.queryCurrent();
    }

    const Request = struct { client: *Client, epoch: u64 };

    fn request(self: *Client) ?*Request {
        const req = self.allocator.create(Request) catch return null;
        req.* = .{ .client = self, .epoch = self.epoch };
        return req;
    }

    fn call(self: *Client, member: []const u8, signature: []const u8, body: *const wire.Writer, callback: dbus.Connection.Callback) bool {
        const conn = self.conn orelse return false;
        if (conn.closed or self.owner == null) return false;
        const req = self.request() orelse return false;
        _ = conn.call(bus_name, object_path, interface, member, signature, body, req, callback, call_timeout_ms) catch {
            self.allocator.destroy(req);
            return false;
        };
        return true;
    }

    /// Takes a reply for the current owner, or frees a stale one.
    fn accept(owner: ?*anyopaque, result: dbus.Connection.Failure!wire.Message) ?struct { client: *Client, msg: wire.Message } {
        const req: *Request = @ptrCast(@alignCast(owner orelse return null));
        const self = req.client;
        const epoch = req.epoch;
        self.allocator.destroy(req);
        if (self.closing or epoch != self.epoch) return null;
        const msg = result catch return .{ .client = self, .msg = .{ .kind = .error_reply, .serial = 0, .headers = .{}, .body = .{ .bytes = &.{} } } };
        return .{ .client = self, .msg = msg };
    }

    pub fn queryCurrent(self: *Client) void {
        if (self.querying) {
            self.query_again = true;
            return;
        }
        var body = self.writer();
        defer body.deinit();
        self.querying = self.call("CurrentInputMethod", "", &body, onCurrent);
    }

    fn onCurrent(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const got = accept(owner, result) orelse return;
        const self = got.client;
        var msg = got.msg;
        self.querying = false;
        if (msg.kind == .method_return and self.fromOwner(msg) and std.mem.eql(u8, msg.headers.signature, "s")) {
            const name = msg.body.string() catch "";
            if (name.len <= self.current_buf.len and !std.mem.eql(u8, name, self.current_buf[0..self.current_len])) {
                @memcpy(self.current_buf[0..name.len], name);
                self.current_len = name.len;
                self.notify();
            }
        }
        if (self.query_again) {
            self.query_again = false;
            self.queryCurrent();
        }
    }

    /// Group name, then its entries, then the method descriptions.
    fn refresh(self: *Client) void {
        if (self.refreshing) {
            self.refresh_again = true;
            return;
        }
        var body = self.writer();
        defer body.deinit();
        self.refreshing = self.call("CurrentInputMethodGroup", "", &body, onGroup);
    }

    fn refreshDone(self: *Client) void {
        self.refreshing = false;
        if (self.refresh_again) {
            self.refresh_again = false;
            self.refresh();
        }
    }

    fn onGroup(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const got = accept(owner, result) orelse return;
        const self = got.client;
        var msg = got.msg;
        if (msg.kind != .method_return or !self.fromOwner(msg) or !std.mem.eql(u8, msg.headers.signature, "s")) return self.refreshDone();
        const group = msg.body.string() catch "";
        const len = @min(group.len, self.group_buf.len);
        @memcpy(self.group_buf[0..len], group[0..len]);
        self.group_len = len;
        var body = self.writer();
        defer body.deinit();
        body.string(self.group_buf[0..len]) catch return self.refreshDone();
        if (!self.call("InputMethodGroupInfo", "s", &body, onGroupInfo)) self.refreshDone();
    }

    fn onGroupInfo(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const got = accept(owner, result) orelse return;
        const self = got.client;
        var msg = got.msg;
        if (msg.kind != .method_return or !self.fromOwner(msg) or !std.mem.eql(u8, msg.headers.signature, "sa(ss)")) return self.refreshDone();
        _ = self.arena.reset(.retain_capacity);
        self.methods = parseGroup(self.arena.allocator(), &msg.body) catch &.{};
        var body = self.writer();
        defer body.deinit();
        if (!self.call("AvailableInputMethods", "", &body, onAvailable)) {
            self.refreshDone();
            self.notify();
        }
    }

    fn onAvailable(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const got = accept(owner, result) orelse return;
        const self = got.client;
        var msg = got.msg;
        if (msg.kind == .method_return and self.fromOwner(msg) and std.mem.eql(u8, msg.headers.signature, "a(ssssssb)")) {
            describe(self.arena.allocator(), self.methods, &msg.body) catch {};
        }
        self.refreshDone();
        self.notify();
        self.queryCurrent();
    }
};

/// `InputMethodGroupInfo` returns (default layout, [(method, layout)]). Keyboard
/// entries are dropped; the rest keep Fcitx's order. Strings are copied.
pub fn parseGroup(arena: std.mem.Allocator, body: *wire.Reader) ![]Method {
    _ = try body.string();
    var items = try body.array(8);
    var list: std.ArrayList(Method) = .empty;
    while (items.offset < items.bytes.len) {
        try items.alignTo(8);
        const name = try items.string();
        _ = try items.string();
        if (isKeyboard(name) or name.len == 0 or list.items.len >= 32) continue;
        const copy = try arena.dupe(u8, name);
        try list.append(arena, .{ .name = copy, .display = copy, .label = "", .language = "" });
    }
    return list.items;
}

/// Fills names and labels from `AvailableInputMethods`
/// (unique name, name, native name, icon, label, language code, configurable).
pub fn describe(arena: std.mem.Allocator, methods: []Method, body: *wire.Reader) !void {
    var items = try body.array(8);
    while (items.offset < items.bytes.len) {
        try items.alignTo(8);
        const unique = try items.string();
        const name = try items.string();
        const native = try items.string();
        _ = try items.string();
        const label = try items.string();
        const language = try items.string();
        _ = try items.boolean();
        for (methods) |*method| {
            if (!std.mem.eql(u8, method.name, unique)) continue;
            method.display = try arena.dupe(u8, if (name.len > 0) name else if (native.len > 0) native else unique);
            method.label = try arena.dupe(u8, label);
            method.language = try arena.dupe(u8, language);
        }
    }
}

test "group entries skip Fcitx keyboards and pick up names and labels" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var group: wire.Writer = .{ .allocator = a };
    defer group.deinit();
    try group.string("us");
    const items = try group.beginArray(8);
    for ([_][2][]const u8{ .{ "keyboard-us", "" }, .{ "mozc", "" }, .{ "pinyin", "" } }) |entry| {
        try group.alignTo(8);
        try group.string(entry[0]);
        try group.string(entry[1]);
    }
    try group.endArray(items);
    var reader: wire.Reader = .{ .bytes = group.bytes.items, .endian = .little };
    const methods = try parseGroup(arena.allocator(), &reader);
    try std.testing.expectEqual(@as(usize, 2), methods.len);
    try std.testing.expectEqualStrings("mozc", methods[0].name);

    var available: wire.Writer = .{ .allocator = a };
    defer available.deinit();
    const list = try available.beginArray(8);
    for ([_][6][]const u8{ .{ "mozc", "Mozc", "Mozc", "fcitx-mozc", "あ", "ja" }, .{ "keyboard-us", "English (US)", "", "input-keyboard", "us", "en" } }) |entry| {
        try available.alignTo(8);
        for (entry) |field| try available.string(field);
        try available.boolean(true);
    }
    try available.endArray(list);
    var available_reader: wire.Reader = .{ .bytes = available.bytes.items, .endian = .little };
    try describe(arena.allocator(), methods, &available_reader);
    try std.testing.expectEqualStrings("Mozc", methods[0].display);
    try std.testing.expectEqualStrings("あ", methods[0].label);
    try std.testing.expectEqualStrings("ja", methods[0].language);
    try std.testing.expectEqualStrings("pinyin", methods[1].display);
}
