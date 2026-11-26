//! Feedback for backlight changes already handled by the kernel or firmware.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("Server.zig");
const osd = @import("osd.zig");

const Watch = @This();
const bus = dbus.connection.bus_name;
const bus_path = dbus.connection.bus_path;
const service = "org.freedesktop.UPower";
const backlight = service ++ ".KbdBacklight";
const path_root = "/org/freedesktop/UPower/KbdBacklight";
const changed = "BrightnessChangedWithSource";
const owner_rule = "type='signal',sender='" ++ bus ++ "',interface='" ++ bus ++ "',member='NameOwnerChanged',path='" ++ bus_path ++ "',arg0='" ++ service ++ "'";
const brightness_rule = "type='signal',sender='" ++ service ++ "',interface='" ++ backlight ++ "',member='" ++ changed ++ "',path_namespace='" ++ path_root ++ "'";
const eq = std.mem.eql;

server: *Server,
conn: *dbus.Connection,
service_owner: ?[]u8 = null,
owner_changed: bool = false,
pending_serial: ?u32 = null,
pending_level: u32 = 0,

pub fn create(server: *Server, allocator: std.mem.Allocator) !*Watch {
    const conn = try dbus.Connection.openSystem(allocator, server.wl_server.getEventLoop(), server.environ);
    errdefer conn.destroy();
    const self = try allocator.create(Watch);
    errdefer allocator.destroy(self);
    self.* = .{ .server = server, .conn = conn };
    _ = try conn.hello(self, onHello);
    return self;
}

pub fn destroy(self: *Watch) void {
    const allocator = self.conn.allocator;
    self.setOwner("");
    self.conn.destroy();
    allocator.destroy(self);
}

fn onHello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Watch = @ptrCast(@alignCast(owner.?));
    _ = result catch return;
    self.subscribe(conn) catch conn.close();
}

fn subscribe(self: *Watch, conn: *dbus.Connection) !void {
    try conn.registerSignal(.{
        .sender = bus,
        .path = bus_path,
        .interface = bus,
        .member = "NameOwnerChanged",
        .owner = self,
        .callback = onOwnerChanged,
    });
    try conn.registerSignal(.{
        .interface = backlight,
        .member = changed,
        .owner = self,
        .callback = onBrightnessChanged,
    });
    _ = try conn.addMatch(owner_rule, null, null);
    _ = try conn.addMatch(brightness_rule, null, null);
    var body: wire.Writer = .{ .allocator = conn.allocator };
    defer body.deinit();
    try body.string(service);
    _ = try conn.call(bus, bus_path, bus, "GetNameOwner", "s", &body, self, onInitialOwner, 5000);
}

fn onInitialOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Watch = @ptrCast(@alignCast(owner.?));
    if (self.owner_changed) return;
    var msg = result catch return;
    if (msg.kind != .method_return or !eq(u8, msg.headers.sender orelse "", bus) or !eq(u8, msg.headers.signature, "s")) return;
    self.setOwner(msg.body.string() catch return);
}

fn onOwnerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
    const self: *Watch = @ptrCast(@alignCast(owner.?));
    if (!eq(u8, msg.headers.signature, "sss")) return;
    var body = msg.body;
    if (!eq(u8, try body.string(), service)) return;
    _ = try body.string();
    const current = try body.string();
    self.owner_changed = true;
    self.setOwner(current);
}

fn setOwner(self: *Watch, name: []const u8) void {
    if (self.service_owner) |old| self.conn.allocator.free(old);
    self.service_owner = if (name.len == 0) null else self.conn.allocator.dupe(u8, name) catch null;
    self.pending_serial = null;
}

fn onBrightnessChanged(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    const self: *Watch = @ptrCast(@alignCast(owner.?));
    const sender = self.service_owner orelse return;
    if (!eq(u8, msg.headers.sender orelse "", sender) or !eq(u8, msg.headers.signature, "is")) return;
    const path = msg.headers.path orelse return;
    // Older UPower emits from the root object. Newer versions also expose per-device objects.
    if (!eq(u8, path, path_root) and !std.mem.startsWith(u8, path, path_root ++ "/")) return;
    var body = msg.body;
    const level = try body.int(i32);
    if (level < 0 or !eq(u8, try body.string(), "internal")) return;
    self.pending_level = @intCast(level);
    const args: wire.Writer = .{ .allocator = conn.allocator };
    self.pending_serial = conn.call(sender, path, backlight, "GetMaxBrightness", "", &args, self, onMaximum, 5000) catch null;
}

fn onMaximum(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const self: *Watch = @ptrCast(@alignCast(owner.?));
    const sender = self.service_owner orelse return;
    var msg = result catch return;
    if (msg.kind != .method_return or msg.headers.reply_serial != self.pending_serial or
        !eq(u8, msg.headers.sender orelse "", sender) or !eq(u8, msg.headers.signature, "i")) return;
    const max = msg.body.int(i32) catch return;
    if (max <= 0) return;
    const maximum: u32 = @intCast(max);
    osd.show(self.server, .{ .kind = .keyboard_backlight, .keyboard = .{
        .current = @min(self.pending_level, maximum),
        .maximum = maximum,
    } });
}
