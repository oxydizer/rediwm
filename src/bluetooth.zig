//! BlueZ settings client. Created on first use, with signal-driven snapshots,
//! bounded discovery and an application pairing agent (never the default agent).
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("Server.zig");
const gpa = @import("main.zig").gpa;
const Text = @import("network/manager.zig").Text;
pub const Path = Text(256);
const eq = std.mem.eql;
const service = "org.bluez";
const properties = "org.freedesktop.DBus.Properties";
const agent_path = "/org/rediwm/BluetoothAgent";
const wl = @import("wayland").server.wl;

pub const Adapter = struct { path: Path = .{}, name: Text(128) = .{}, powered: bool = false, discovering: bool = false };
pub const Device = struct {
    path: Path = .{},
    adapter: Path = .{},
    name: Text(256) = .{},
    address: Text(64) = .{},
    icon: Text(64) = .{},
    paired: bool = false,
    connected: bool = false,
    trusted: bool = false,
    blocked: bool = false,
    battery: ?u8 = null,
    rssi: ?i16 = null,
    audio: bool = false,
    microphone: bool = false,
    input: bool = false,
    pub fn title(d: *const Device) []const u8 {
        return if (d.name.len > 0) d.name.slice() else d.address.slice();
    }
};
pub const Prompt = enum { none, confirm, authorize, pin, passkey, display };
const Request = struct { manager: *Manager, epoch: u64, generation: u64 = 0, path: Path = .{}, pair: bool = false };

pub const Manager = struct {
    server: *Server,
    conn: ?*dbus.Connection = null,
    owner: Path = .{},
    epoch: u64 = 0,
    generation: u64 = 0,
    closing: bool = false,
    fetching: bool = false,
    again: bool = false,
    available: bool = false,
    adapters: [16]Adapter = @splat(.{}),
    adapter_count: usize = 0,
    devices: [256]Device = @splat(.{}),
    count: usize = 0,
    busy: bool = false,
    pairing: ?Path = null,
    agent_ready: bool = false,
    scan_path: Path = .{},
    scan_timer: ?*wl.EventSource = null,
    prompt: Prompt = .none,
    code: Text(32) = .{},
    reply: ?dbus.Connection.Deferred = null,
    message: []const u8 = "Bluetooth service is unavailable",

    pub fn create(server: *Server) !*Manager {
        const m = try gpa.create(Manager);
        m.* = .{ .server = server };
        m.opened();
        return m;
    }
    pub fn destroy(m: *Manager) void {
        m.closed();
        m.closing = true;
        if (m.scan_timer) |timer| timer.remove();
        if (m.conn) |conn| {
            conn.flush() catch {};
            conn.destroy();
        }
        gpa.destroy(m);
    }
    pub fn opened(m: *Manager) void {
        if (m.conn == null or m.conn.?.closed) {
            if (m.conn) |conn| conn.destroy();
            m.conn = dbus.Connection.openSystem(gpa, m.server.wl_server.getEventLoop(), m.server.environ) catch {
                m.conn = null;
                return;
            };
            m.conn.?.on_disconnect = .{ .owner = m, .callback = disconnected };
            _ = m.conn.?.hello(m, hello) catch m.conn.?.close();
        } else m.fetch();
    }
    pub fn closed(m: *Manager) void {
        m.stopScan();
        m.cancelPair();
    }
    fn notify(m: *Manager) void {
        if (!m.closing) if (m.server.input.open_control_center) |cc| if (cc.page == .bluetooth) cc.refresh();
    }
    fn clearPrompt(m: *Manager) void {
        if (m.reply) |*reply| if (m.conn) |conn| conn.releaseDeferred(reply);
        m.reply = null;
        m.prompt = .none;
        m.code = .{};
    }
    fn reset(m: *Manager) void {
        m.epoch +%= 1;
        m.generation +%= 1;
        m.clearPrompt();
        if (m.scan_timer) |timer| timer.timerUpdate(0) catch {};
        m.scan_path = .{};
        m.owner = .{};
        m.available = false;
        m.agent_ready = false;
        m.adapter_count = 0;
        m.count = 0;
        m.busy = false;
        m.pairing = null;
        m.fetching = false;
        m.again = false;
        m.message = "Bluetooth service is unavailable";
        m.notify();
    }
    fn disconnected(owner: ?*anyopaque) void {
        const m: *Manager = @ptrCast(@alignCast(owner.?));
        if (!m.closing) m.reset();
    }
    fn hello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const m: *Manager = @ptrCast(@alignCast(owner.?));
        const msg = result catch return;
        if (m.closing or msg.kind != .method_return) return;
        conn.registerSignal(.{ .sender = "org.freedesktop.DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .owner = m, .callback = ownerChanged }) catch return;
        _ = conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'", null, null) catch return;
        conn.registerSignal(.{ .owner = m, .callback = changed }) catch return;
        _ = conn.addMatch("type='signal',sender='org.bluez'", null, null) catch return;
        inline for (.{ "Release", "Cancel", "RequestPinCode", "RequestPasskey", "DisplayPinCode", "DisplayPasskey", "RequestConfirmation", "RequestAuthorization", "AuthorizeService" }) |member| {
            conn.register(.{ .path = agent_path, .interface = "org.bluez.Agent1", .member = member, .owner = m, .callback = agent }) catch return;
        }
        var b: wire.Writer = .{ .allocator = gpa };
        defer b.deinit();
        b.string(service) catch return;
        _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &b, m, gotOwner, 5000) catch return;
    }
    fn gotOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const m: *Manager = @ptrCast(@alignCast(owner.?));
        var msg = result catch return;
        if (m.closing or m.owner.len != 0 or msg.kind != .method_return) return;
        m.owner.set(msg.body.string() catch return);
        m.serviceReady();
    }
    fn ownerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
        const m: *Manager = @ptrCast(@alignCast(owner.?));
        var b = msg.body;
        if (!eq(u8, msg.headers.signature, "sss") or !eq(u8, try b.string(), service)) return;
        _ = try b.string();
        const next = try b.string();
        m.reset();
        m.owner.set(next);
        if (next.len > 0) m.serviceReady();
    }
    fn serviceReady(m: *Manager) void {
        m.fetch();
        var b: wire.Writer = .{ .allocator = gpa };
        defer b.deinit();
        b.objectPath(agent_path) catch return;
        b.string("KeyboardDisplay") catch return;
        m.request("/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", "os", &b, .{}, false, registered, 5000) catch {
            m.message = "Could not register the pairing agent";
        };
    }
    fn registered(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const r: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(r);
        const m = r.manager;
        if (m.closing or r.epoch != m.epoch) return;
        const msg = result catch {
            m.message = "Could not register the pairing agent";
            m.notify();
            return;
        };
        m.agent_ready = msg.kind == .method_return and m.fromOwner(msg);
        if (!m.agent_ready) m.message = "Pairing is unavailable: could not register the Bluetooth agent";
        m.notify();
    }
    fn fromOwner(m: *Manager, msg: wire.Message) bool {
        return m.owner.len != 0 and eq(u8, m.owner.slice(), msg.headers.sender orelse "");
    }
    fn changed(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
        const m: *Manager = @ptrCast(@alignCast(owner.?));
        if (!m.fromOwner(msg)) return;
        const iface = msg.headers.interface orelse "";
        if (!eq(u8, iface, properties) and !eq(u8, iface, "org.freedesktop.DBus.ObjectManager")) return;
        if (m.server.input.open_control_center) |cc| {
            if (cc.page == .bluetooth) m.fetch();
        } else if (m.busy) m.fetch();
    }
    fn request(m: *Manager, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, b: *const wire.Writer, device: Path, pair: bool, callback: dbus.Connection.Callback, timeout: u32) !void {
        const conn = m.conn orelse return error.Disconnected;
        if (m.owner.len == 0) return error.Disconnected;
        const r = try gpa.create(Request);
        errdefer gpa.destroy(r);
        r.* = .{ .manager = m, .epoch = m.epoch, .generation = m.generation, .path = device, .pair = pair };
        _ = try conn.call(m.owner.slice(), path, iface, member, sig, b, r, callback, timeout);
    }
    fn fetch(m: *Manager) void {
        if (m.closing or m.owner.len == 0) return;
        if (m.fetching) {
            m.again = true;
            return;
        }
        const b: wire.Writer = .{ .allocator = gpa };
        m.request("/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", "", &b, .{}, false, gotObjects, 5000) catch return;
        m.fetching = true;
    }
    fn gotObjects(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const r: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(r);
        const m = r.manager;
        if (m.closing or r.epoch != m.epoch) return;
        m.fetching = false;
        defer {
            m.notify();
            if (m.again) {
                m.again = false;
                m.fetch();
            }
        }
        var msg = result catch {
            m.message = "Could not read Bluetooth devices";
            return;
        };
        if (!m.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{oa{sa{sv}}}")) return;
        m.parse(&msg.body) catch {
            m.message = "Could not read Bluetooth devices";
            return;
        };
        m.available = true;
        if (eq(u8, m.message, "Bluetooth service is unavailable")) m.message = "";
    }
    fn parse(m: *Manager, b: *wire.Reader) !void {
        var devices: std.ArrayList(Device) = .empty;
        defer devices.deinit(gpa);
        var adapters: std.ArrayList(Adapter) = .empty;
        defer adapters.deinit(gpa);
        var objects = try b.array(8);
        while (objects.offset < objects.bytes.len) {
            try objects.alignTo(8);
            const path = try objects.objectPath();
            var d: Device = .{ .path = Path.init(path) };
            var a: Adapter = .{ .path = Path.init(path) };
            var is_device = false;
            var is_adapter = false;
            var interfaces = try objects.array(8);
            while (interfaces.offset < interfaces.bytes.len) {
                try interfaces.alignTo(8);
                const iface = try interfaces.string();
                const device = eq(u8, iface, "org.bluez.Device1");
                const is_adapter_iface = eq(u8, iface, "org.bluez.Adapter1");
                const battery = eq(u8, iface, "org.bluez.Battery1");
                is_device = is_device or device;
                is_adapter = is_adapter or is_adapter_iface;
                var props = try interfaces.array(8);
                while (props.offset < props.bytes.len) {
                    try props.alignTo(8);
                    const key = try props.string();
                    const sig = try props.variant();
                    var value = props;
                    try props.skip(sig);
                    if (device) {
                        if (eq(u8, sig, "s")) {
                            const str = try value.string();
                            if (eq(u8, key, "Alias")) d.name.set(str) else if (eq(u8, key, "Name") and d.name.len == 0) d.name.set(str) else if (eq(u8, key, "Address")) d.address.set(str) else if (eq(u8, key, "Icon")) d.icon.set(str);
                        } else if (eq(u8, sig, "o") and eq(u8, key, "Adapter")) d.adapter.set(try value.objectPath()) else if (eq(u8, sig, "b")) {
                            const on = try value.boolean();
                            if (eq(u8, key, "Paired")) d.paired = on else if (eq(u8, key, "Connected")) d.connected = on else if (eq(u8, key, "Trusted")) d.trusted = on else if (eq(u8, key, "Blocked")) d.blocked = on;
                        } else if (eq(u8, key, "RSSI") and eq(u8, sig, "n")) d.rssi = try value.int(i16) else if (eq(u8, key, "UUIDs") and eq(u8, sig, "as")) {
                            var uuids = try value.array(4);
                            while (uuids.offset < uuids.bytes.len) {
                                const uuid = try uuids.string();
                                d.audio = d.audio or std.ascii.eqlIgnoreCase(uuid, "0000110b-0000-1000-8000-00805f9b34fb");
                                d.microphone = d.microphone or std.ascii.eqlIgnoreCase(uuid, "0000111e-0000-1000-8000-00805f9b34fb") or std.ascii.eqlIgnoreCase(uuid, "00001108-0000-1000-8000-00805f9b34fb");
                                d.input = d.input or std.ascii.eqlIgnoreCase(uuid, "00001124-0000-1000-8000-00805f9b34fb") or std.ascii.eqlIgnoreCase(uuid, "00001812-0000-1000-8000-00805f9b34fb");
                            }
                        }
                    } else if (is_adapter_iface) {
                        if (eq(u8, sig, "s") and eq(u8, key, "Alias")) a.name.set(try value.string()) else if (eq(u8, sig, "b") and eq(u8, key, "Powered")) a.powered = try value.boolean() else if (eq(u8, sig, "b") and eq(u8, key, "Discovering")) a.discovering = try value.boolean();
                    } else if (battery and eq(u8, key, "Percentage") and eq(u8, sig, "y")) d.battery = @min(100, try value.byte());
                }
            }
            if (is_device and devices.items.len < m.devices.len) try devices.append(gpa, d);
            if (is_adapter and adapters.items.len < m.adapters.len) try adapters.append(gpa, a);
        }
        try b.done();
        m.count = devices.items.len;
        @memcpy(m.devices[0..m.count], devices.items);
        m.adapter_count = adapters.items.len;
        @memcpy(m.adapters[0..m.adapter_count], adapters.items);
    }
    pub fn find(m: *Manager, path: Path) ?*const Device {
        for (m.devices[0..m.count]) |*d| if (eq(u8, path.slice(), d.path.slice())) return d;
        return null;
    }
    pub fn adapter(m: *Manager, path: Path) ?*const Adapter {
        for (m.adapters[0..m.adapter_count]) |*a| if (eq(u8, path.slice(), a.path.slice())) return a;
        return null;
    }
    fn canAct(m: *Manager) bool {
        return !m.closing and m.available and m.server.locker == null;
    }
    pub fn set(m: *Manager, path: Path, iface: []const u8, key: []const u8, on: bool) void {
        if (!m.canAct() or m.busy) return;
        var b: wire.Writer = .{ .allocator = gpa };
        defer b.deinit();
        b.string(iface) catch return;
        b.string(key) catch return;
        b.variant("b") catch return;
        b.boolean(on) catch return;
        m.start(path, properties, "Set", "ssv", &b, false);
    }
    fn start(m: *Manager, path: Path, iface: []const u8, member: []const u8, sig: []const u8, b: *const wire.Writer, pair: bool) void {
        m.generation +%= 1;
        m.request(path.slice(), iface, member, sig, b, path, pair, completed, if (pair) 120000 else 20000) catch {
            m.message = "Could not send Bluetooth request";
            m.notify();
            return;
        };
        m.busy = true;
        m.message = "";
        if (pair) m.pairing = path;
        m.notify();
    }
    pub fn deviceAction(m: *Manager, path: Path, member: []const u8) void {
        if (!m.canAct() or m.busy) return;
        const d = m.find(path) orelse return;
        const a = m.adapter(d.adapter) orelse return;
        if (!a.powered or (eq(u8, member, "Pair") and !m.agent_ready)) return;
        const b: wire.Writer = .{ .allocator = gpa };
        m.start(path, "org.bluez.Device1", member, "", &b, eq(u8, member, "Pair"));
    }
    pub fn remove(m: *Manager, path: Path) void {
        if (!m.canAct() or m.busy) return;
        const d = m.find(path) orelse return;
        var b: wire.Writer = .{ .allocator = gpa };
        defer b.deinit();
        b.objectPath(path.slice()) catch return;
        m.start(d.adapter, "org.bluez.Adapter1", "RemoveDevice", "o", &b, false);
    }
    fn completed(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const r: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(r);
        const m = r.manager;
        if (m.closing or r.epoch != m.epoch or r.generation != m.generation) return;
        m.busy = false;
        if (r.pair) {
            m.pairing = null;
            m.clearPrompt();
        }
        const msg = result catch {
            if (r.pair) {
                const b: wire.Writer = .{ .allocator = gpa };
                _ = conn.call(m.owner.slice(), r.path.slice(), "org.bluez.Device1", "CancelPairing", "", &b, null, ignored, 5000) catch {};
            }
            m.message = "Bluetooth request timed out or was disconnected";
            m.notify();
            return;
        };
        // The bus itself may reject a call before it reaches bluetoothd.
        const bus_error = msg.kind == .error_reply and eq(u8, msg.headers.sender orelse "", "org.freedesktop.DBus");
        if (!m.fromOwner(msg) and !bus_error) {
            m.notify();
            return;
        }
        if (msg.kind != .method_return) {
            const name = msg.headers.error_name orelse "";
            m.message = if (std.mem.endsWith(u8, name, "NotAuthorized") or std.mem.endsWith(u8, name, "AccessDenied")) "Permission denied" else if (std.mem.endsWith(u8, name, "NotReady")) "Bluetooth is off or blocked by the hardware switch" else if (std.mem.endsWith(u8, name, "AuthenticationRejected")) "Pairing was rejected" else if (std.mem.endsWith(u8, name, "AuthenticationCanceled")) "Pairing was cancelled" else "Bluetooth request failed. Check that the device is nearby and ready.";
        } else if (r.pair and m.server.locker == null) {
            const b: wire.Writer = .{ .allocator = gpa };
            m.start(r.path, "org.bluez.Device1", "Connect", "", &b, false);
        }
        m.fetch();
        m.notify();
    }
    pub fn scan(m: *Manager, path: Path) void {
        if (!m.canAct() or m.scan_path.len != 0) return;
        const a = m.adapter(path) orelse return;
        if (!a.powered) return;
        if (m.scan_timer == null) m.scan_timer = m.server.wl_server.getEventLoop().addTimer(*Manager, scanExpired, m) catch return;
        const b: wire.Writer = .{ .allocator = gpa };
        m.request(path.slice(), "org.bluez.Adapter1", "StartDiscovery", "", &b, path, false, scanned, 5000) catch return;
        m.scan_path = path;
        m.scan_timer.?.timerUpdate(30000) catch m.stopScan();
        m.notify();
    }
    fn scanned(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const r: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(r);
        const m = r.manager;
        if (m.closing or r.epoch != m.epoch) return;
        const msg = result catch {
            m.stopScan();
            m.message = "Could not start discovery";
            m.notify();
            return;
        };
        if (msg.kind != .method_return) {
            m.stopScan();
            m.message = "Could not start discovery";
        } else m.fetch();
        m.notify();
    }
    fn scanExpired(m: *Manager) c_int {
        m.stopScan();
        return 0;
    }
    pub fn stopScan(m: *Manager) void {
        if (m.scan_timer) |timer| timer.timerUpdate(0) catch {};
        if (m.scan_path.len != 0) if (m.conn) |conn| {
            const b: wire.Writer = .{ .allocator = gpa };
            _ = conn.call(m.owner.slice(), m.scan_path.slice(), "org.bluez.Adapter1", "StopDiscovery", "", &b, null, ignored, 5000) catch {};
        };
        m.scan_path = .{};
        m.notify();
    }
    fn ignored(_: ?*anyopaque, _: *dbus.Connection, _: dbus.Connection.Failure!wire.Message) void {}
    pub fn cancelPair(m: *Manager) void {
        if (m.reply != null) m.respond(false, "");
        if (m.pairing) |path| if (m.conn) |conn| {
            const b: wire.Writer = .{ .allocator = gpa };
            _ = conn.call(m.owner.slice(), path.slice(), "org.bluez.Device1", "CancelPairing", "", &b, null, ignored, 5000) catch {};
            m.generation +%= 1;
            m.busy = false;
            m.pairing = null;
        };
        m.clearPrompt();
        m.notify();
    }
    fn agent(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
        const m: *Manager = @ptrCast(@alignCast(owner.?));
        const member = msg.headers.member orelse "";
        if (!m.fromOwner(msg)) {
            try conn.replyError(msg, "org.bluez.Error.Rejected", "Unexpected sender");
            return;
        }
        const empty: wire.Writer = .{ .allocator = gpa };
        if (eq(u8, member, "Cancel") or eq(u8, member, "Release")) {
            m.clearPrompt();
            if (eq(u8, member, "Release")) m.agent_ready = false;
            try conn.reply(msg, "", &empty);
            m.notify();
            return;
        }
        const visible = if (m.server.input.open_control_center) |cc| cc.page == .bluetooth and cc.toplevel.in_world and !cc.toplevel.minimized else false;
        var b = msg.body;
        const path = try b.objectPath();
        if (m.server.locker != null or !visible or m.pairing == null or !eq(u8, path, m.pairing.?.slice())) {
            try conn.replyError(msg, "org.bluez.Error.Rejected", "No active pairing request");
            return;
        }
        if (m.reply != null) {
            try conn.replyError(msg, "org.bluez.Error.Rejected", "A pairing prompt is already open");
            return;
        }
        m.code = .{};
        if (eq(u8, member, "DisplayPinCode")) {
            m.code.set(try b.string());
            m.prompt = .display;
            try conn.reply(msg, "", &empty);
        } else if (eq(u8, member, "DisplayPasskey") or eq(u8, member, "RequestConfirmation")) {
            const code = try b.uint32();
            var buffer: [16]u8 = undefined;
            m.code.set(try std.fmt.bufPrint(&buffer, "{d:0>6}", .{code}));
            if (eq(u8, member, "DisplayPasskey")) {
                _ = try b.int(u16);
                m.prompt = .display;
                try conn.reply(msg, "", &empty);
            } else {
                m.prompt = .confirm;
                m.reply = try conn.deferReply(msg);
            }
        } else {
            m.prompt = if (eq(u8, member, "RequestPinCode")) .pin else if (eq(u8, member, "RequestPasskey")) .passkey else .authorize;
            if (eq(u8, member, "AuthorizeService")) _ = try b.string();
            m.reply = try conn.deferReply(msg);
        }
        m.notify();
    }
    pub fn respond(m: *Manager, accept: bool, value: []const u8) void {
        const conn = m.conn orelse return;
        const reply = if (m.reply) |*r| r else return;
        var b: wire.Writer = .{ .allocator = gpa };
        defer b.deinit();
        if (!accept or m.server.locker != null) {
            conn.replyErrorDeferred(reply, "org.bluez.Error.Rejected", "Pairing rejected") catch {};
            m.clearPrompt();
            m.notify();
            return;
        }
        const sig: []const u8 = switch (m.prompt) {
            .pin => blk: {
                if (value.len == 0 or value.len > 16) {
                    m.message = "Enter a PIN of 1–16 characters";
                    m.notify();
                    return;
                }
                b.string(value) catch return;
                break :blk "s";
            },
            .passkey => blk: {
                const key = std.fmt.parseInt(u32, value, 10) catch {
                    m.message = "Enter a numeric passkey";
                    m.notify();
                    return;
                };
                if (key > 999999 or value.len == 0 or value.len > 6) {
                    m.message = "Enter a passkey of up to six digits";
                    m.notify();
                    return;
                }
                b.uint32(key) catch return;
                break :blk "u";
            },
            else => "",
        };
        conn.replyDeferred(reply, sig, &b) catch {
            m.message = "Could not answer pairing request";
        };
        m.clearPrompt();
        m.notify();
    }
};
