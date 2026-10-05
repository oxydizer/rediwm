//! Asynchronous NetworkManager client. Snapshots are fetched on menu open and
//! service signals, never from a polling timer. No shell commands or argv secrets.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const gpa = @import("../main.zig").gpa;
const secure = @import("secure_allocator.zig").allocator;
const nm = "org.freedesktop.NetworkManager";
const root = "/org/freedesktop/NetworkManager";
// NetworkManager exports ObjectManager above its manager and device objects.
const objects_root = "/org/freedesktop";
const wireless = nm ++ ".Device.Wireless";
const wired = nm ++ ".Device.Wired";
const device_iface = nm ++ ".Device";
const ip4_iface = nm ++ ".IP4Config";
const ap_iface = nm ++ ".AccessPoint";
const settings_iface = nm ++ ".Settings.Connection";
const properties = "org.freedesktop.DBus.Properties";
const eq = std.mem.eql;

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, capacity);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn init(value: []const u8) @This() {
            var t: @This() = .{};
            t.set(value);
            return t;
        }
    };
}
pub const Path = Text(256);
pub const Security = enum { open, personal, sae, unsupported };
pub const Network = struct {
    path: Path = .{},
    ssid: Text(32) = .{},
    strength: u8 = 0,
    security: Security = .open,
    connected: bool = false,
    saved: Path = .{},
};
pub const Ethernet = struct {
    path: Path = .{},
    name: Text(64) = .{},
    driver: Text(64) = .{},
    mac: Text(64) = .{},
    ip4: Path = .{},
    address: Text(256) = .{},
    gateway: Text(64) = .{},
    dns: Text(256) = .{},
    state: u32 = 0,
    managed: bool = false,
    carrier: bool = false,
    speed: u32 = 0,
    has_profile: bool = false,

    pub fn connected(self: Ethernet) bool {
        return self.state == 100;
    }
    pub fn active(self: Ethernet) bool {
        return self.state >= 40 and self.state <= 100;
    }
    pub fn status(self: Ethernet) []const u8 {
        if (!self.managed) return "Unmanaged";
        if (!self.carrier) return "Cable unplugged";
        return switch (self.state) {
            40...90 => "Connecting…",
            100 => "Connected",
            110 => "Disconnecting…",
            120 => "Connection failed",
            else => "Disconnected",
        };
    }
};
const Ip4 = struct { path: Path, address: Text(256) = .{}, gateway: Text(64) = .{}, dns: Text(256) = .{} };
const Device = struct {
    path: Path = .{},
    active: Path = .{},
    state: u32 = 0,
    aps: [256]Path = @splat(.{}),
    count: usize = 0,
    last_scan: i64 = -1,
};
const Saved = struct { path: Path = .{}, ssid: Text(32) = .{}, security: Security = .open, loaded: bool = false };
const Request = struct { manager: *Manager, epoch: u64, path: Path, wired_generation: u64 = 0 };
const PasswordUpdate = struct {
    manager: *Manager,
    epoch: u64,
    net: Network,
    password: [128]u8 = @splat(0),
    len: usize,
};

pub const Manager = struct {
    server: *Server,
    conn: ?*dbus.Connection = null,
    owner: Path = .{},
    epoch: u64 = 0,
    closing: bool = false,
    fetching: bool = false,
    again: bool = false,
    available: bool = false,
    enabled: bool = false,
    hardware: bool = true,
    device: Path = .{},
    networks: [256]Network = @splat(.{}),
    count: usize = 0,
    saved: [128]Saved = @splat(.{}),
    saved_count: usize = 0,
    busy: bool = false,
    joining: ?Network = null,
    join_timer: ?*@import("wayland").server.wl.EventSource = null,
    scan_pending: bool = false,
    scanning: bool = false,
    last_scan: i64 = -1,
    scan_timer: ?*@import("wayland").server.wl.EventSource = null,
    message: []const u8 = "NetworkManager is unavailable",
    state: u32 = 0,
    connectivity: u32 = 0,
    ethernet: [16]Ethernet = @splat(.{}),
    ethernet_count: usize = 0,
    wired_pending: ?Path = null,
    wired_want_connected: bool = false,
    wired_accepted: bool = false,
    wired_timer: ?*@import("wayland").server.wl.EventSource = null,
    wired_message: []const u8 = "",
    wired_generation: u64 = 0,

    pub fn create(server: *Server) !*Manager {
        const self = try gpa.create(Manager);
        self.* = .{ .server = server };
        self.connect();
        return self;
    }
    pub fn destroy(self: *Manager) void {
        self.closing = true;
        if (self.join_timer) |timer| timer.remove();
        self.join_timer = null;
        if (self.scan_timer) |timer| timer.remove();
        self.scan_timer = null;
        if (self.wired_timer) |timer| timer.remove();
        self.wired_timer = null;
        if (self.conn) |conn| conn.destroy();
        gpa.destroy(self);
    }
    pub fn opened(self: *Manager) void {
        self.scan_pending = true;
        if (self.conn == null or self.conn.?.closed) self.connect() else self.fetch();
    }
    fn refresh(self: *Manager) void {
        if (self.closing) return;
        if (self.server.input.open_wifi) |popup| popup.changed();
        if (self.server.input.open_control_center) |cc| if (cc.page == .network) cc.refresh();
    }
    fn reset(self: *Manager) void {
        self.epoch +%= 1;
        self.owner = .{};
        if (self.join_timer) |timer| timer.timerUpdate(0) catch {};
        self.stopScan();
        self.last_scan = -1;
        self.available = false;
        self.enabled = false;
        self.hardware = true;
        self.count = 0;
        self.saved_count = 0;
        self.device = .{};
        self.state = 0;
        self.connectivity = 0;
        self.ethernet_count = 0;
        self.wired_pending = null;
        self.wired_message = "";
        if (self.wired_timer) |timer| timer.timerUpdate(0) catch {};
        self.busy = false;
        self.joining = null;
        self.message = "NetworkManager is unavailable";
        self.refresh();
    }
    fn connect(self: *Manager) void {
        if (self.conn) |old| old.destroy();
        self.conn = null;
        self.reset();
        const conn = dbus.Connection.openSystem(secure, self.server.wl_server.getEventLoop(), self.server.environ) catch return;
        conn.wipe_buffers = true;
        self.conn = conn;
        conn.on_disconnect = .{ .owner = self, .callback = disconnected };
        _ = conn.hello(self, hello) catch conn.close();
    }
    fn disconnected(owner: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (!self.closing) self.reset();
    }
    fn hello(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        const msg = result catch return;
        if (msg.kind != .method_return) return;
        conn.registerSignal(.{ .sender = "org.freedesktop.DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .owner = self, .callback = ownerChanged }) catch return;
        _ = conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ nm ++ "'", null, null) catch return;
        conn.registerSignal(.{ .owner = self, .callback = changed }) catch return;
        _ = conn.addMatch("type='signal',sender='" ++ nm ++ "',path_namespace='" ++ objects_root ++ "'", null, null) catch return;
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        b.string(nm) catch return;
        _ = conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", "s", &b, self, gotOwner, 5000) catch return;
    }
    fn gotOwner(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (self.closing or self.owner.len != 0) return;
        var msg = result catch return;
        if (msg.kind != .method_return) return;
        self.owner.set(msg.body.string() catch return);
        self.fetch();
    }
    fn ownerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        var b = msg.body;
        if (!eq(u8, try b.string(), nm)) return;
        _ = try b.string();
        const next = try b.string();
        self.reset();
        self.owner.set(next);
        self.fetch();
    }
    fn fromOwner(self: *Manager, msg: wire.Message) bool {
        return self.owner.len != 0 and eq(u8, self.owner.slice(), msg.headers.sender orelse "");
    }
    fn changed(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        if (!self.fromOwner(msg)) return;
        // Saved profiles may change without changing their object path.
        if (eq(u8, msg.headers.interface orelse "", settings_iface)) {
            for (self.saved[0..self.saved_count]) |*saved| if (eq(u8, saved.path.slice(), msg.headers.path orelse "")) {
                saved.loaded = false;
            };
        }
        const settings_open = if (self.server.input.open_control_center) |cc| cc.page == .network else false;
        if (self.server.input.open_wifi != null or settings_open or self.busy or self.wired_pending != null) self.fetch();
    }
    fn fetch(self: *Manager) void {
        if (self.closing or self.owner.len == 0) return;
        if (self.fetching) {
            self.again = true;
            return;
        }
        const conn = self.conn orelse return;
        const b: wire.Writer = .{ .allocator = secure };
        _ = conn.call(self.owner.slice(), objects_root, "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", "", &b, self, gotObjects, 5000) catch return;
        self.fetching = true;
        self.refresh();
    }
    fn gotObjects(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Manager = @ptrCast(@alignCast(owner.?));
        self.fetching = false;
        if (self.closing) return;
        defer self.refresh();
        defer {
            if (self.again) {
                self.again = false;
                self.fetch();
            }
        }
        var msg = result catch {
            self.message = "Could not read Wi-Fi networks";
            self.refresh();
            return;
        };
        if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{oa{sa{sv}}}")) return;
        self.parseObjects(&msg.body) catch {
            self.message = "Could not read Wi-Fi networks";
            self.refresh();
            return;
        };
        if (self.scan_pending) {
            self.scan_pending = false;
            self.scan();
        }
        self.refresh();
    }
    fn parseObjects(self: *Manager, b: *wire.Reader) !void {
        // Parse a complete snapshot before publishing, so rows never point at
        // half-updated objects. Multiple radios use the connected/first radio.
        var aps: std.ArrayList(Network) = .empty;
        defer aps.deinit(gpa);
        var devices: std.ArrayList(Device) = .empty;
        defer devices.deinit(gpa);
        var paths: std.ArrayList(Path) = .empty;
        defer paths.deinit(gpa);
        var ethernet: std.ArrayList(Ethernet) = .empty;
        defer ethernet.deinit(gpa);
        var configs: std.ArrayList(Ip4) = .empty;
        defer configs.deinit(gpa);
        var state: u32 = 0;
        var connectivity: u32 = 0;
        var objects = try b.array(8);
        while (objects.offset < objects.bytes.len) {
            try objects.alignTo(8);
            const path = try objects.objectPath();
            var ifaces = try objects.array(8);
            var ap: Network = .{ .path = Path.init(path) };
            var dev: Device = .{ .path = Path.init(path) };
            var eth: Ethernet = .{ .path = Path.init(path) };
            var ip4: Ip4 = .{ .path = Path.init(path) };
            var is_ap = false;
            var is_wifi = false;
            var is_wired = false;
            var is_ip4 = false;
            var flags: u32 = 0;
            var wpa: u32 = 0;
            var rsn: u32 = 0;
            while (ifaces.offset < ifaces.bytes.len) {
                try ifaces.alignTo(8);
                const iface = try ifaces.string();
                if (eq(u8, iface, settings_iface) and paths.items.len < 128) try paths.append(gpa, Path.init(path));
                is_ap = is_ap or eq(u8, iface, ap_iface);
                is_wifi = is_wifi or eq(u8, iface, wireless);
                is_wired = is_wired or eq(u8, iface, wired);
                is_ip4 = is_ip4 or eq(u8, iface, ip4_iface);
                var props = try ifaces.array(8);
                while (props.offset < props.bytes.len) {
                    try props.alignTo(8);
                    const key = try props.string();
                    const sig = try props.variant();
                    if (eq(u8, iface, device_iface)) {
                        if (eq(u8, key, "Interface") and eq(u8, sig, "s")) eth.name.set(try props.string()) else if (eq(u8, key, "Driver") and eq(u8, sig, "s")) eth.driver.set(try props.string()) else if (eq(u8, key, "Managed") and eq(u8, sig, "b")) eth.managed = try props.boolean() else if (eq(u8, key, "Ip4Config") and eq(u8, sig, "o")) eth.ip4.set(try props.objectPath()) else if (eq(u8, key, "HwAddress") and eq(u8, sig, "s")) eth.mac.set(try props.string()) else if (eq(u8, key, "AvailableConnections") and eq(u8, sig, "ao")) {
                            var list = try props.array(4);
                            while (list.offset < list.bytes.len) {
                                _ = try list.objectPath();
                                eth.has_profile = true;
                            }
                        } else if (eq(u8, key, "State") and eq(u8, sig, "u")) {
                            dev.state = try props.uint32();
                            eth.state = dev.state;
                        } else try props.skip(sig);
                        continue;
                    }
                    if (eq(u8, iface, wired)) {
                        if (eq(u8, key, "Carrier") and eq(u8, sig, "b")) eth.carrier = try props.boolean() else if (eq(u8, key, "Speed") and eq(u8, sig, "u")) eth.speed = try props.uint32() else if (eq(u8, key, "HwAddress") and eq(u8, sig, "s")) eth.mac.set(try props.string()) else try props.skip(sig);
                        continue;
                    }
                    if (eq(u8, iface, ip4_iface)) {
                        if (eq(u8, key, "Gateway") and eq(u8, sig, "s")) ip4.gateway.set(try props.string()) else if (eq(u8, key, "AddressData") and eq(u8, sig, "aa{sv}")) ip4.address = try addressList(&props) else if (eq(u8, key, "NameserverData") and eq(u8, sig, "aa{sv}")) ip4.dns = try addressList(&props) else try props.skip(sig);
                        continue;
                    }
                    if (eq(u8, iface, nm) and eq(u8, key, "State") and eq(u8, sig, "u")) {
                        state = try props.uint32();
                        continue;
                    }
                    if (eq(u8, iface, nm) and eq(u8, key, "Connectivity") and eq(u8, sig, "u")) {
                        connectivity = try props.uint32();
                        continue;
                    }
                    if (eq(u8, iface, nm) and eq(u8, key, "WirelessEnabled") and eq(u8, sig, "b")) self.enabled = try props.boolean() else if (eq(u8, iface, nm) and eq(u8, key, "WirelessHardwareEnabled") and eq(u8, sig, "b")) self.hardware = try props.boolean() else if (eq(u8, iface, nm ++ ".Device") and eq(u8, key, "State") and eq(u8, sig, "u")) dev.state = try props.uint32() else if (eq(u8, iface, wireless) and eq(u8, key, "ActiveAccessPoint") and eq(u8, sig, "o")) dev.active.set(try props.objectPath()) else if (eq(u8, iface, wireless) and eq(u8, key, "AccessPoints") and eq(u8, sig, "ao")) {
                        var list = try props.array(4);
                        while (list.offset < list.bytes.len) {
                            const p = try list.objectPath();
                            if (dev.count < dev.aps.len) {
                                dev.aps[dev.count] = Path.init(p);
                                dev.count += 1;
                            }
                        }
                    } else if (eq(u8, iface, wireless) and eq(u8, key, "LastScan") and eq(u8, sig, "x")) {
                        dev.last_scan = @bitCast(try props.uint64());
                    } else if (eq(u8, iface, ap_iface) and eq(u8, key, "Ssid") and eq(u8, sig, "ay")) {
                        var bytes = try props.array(1);
                        ap.ssid.set(try bytes.take(bytes.bytes.len - bytes.offset));
                    } else if (eq(u8, iface, ap_iface) and eq(u8, key, "Strength") and eq(u8, sig, "y")) ap.strength = try props.byte() else if (eq(u8, iface, ap_iface) and eq(u8, key, "Flags") and eq(u8, sig, "u")) flags = try props.uint32() else if (eq(u8, iface, ap_iface) and eq(u8, key, "WpaFlags") and eq(u8, sig, "u")) wpa = try props.uint32() else if (eq(u8, iface, ap_iface) and eq(u8, key, "RsnFlags") and eq(u8, sig, "u")) rsn = try props.uint32() else try props.skip(sig);
                }
            }
            if (is_ap and ap.ssid.len > 0 and aps.items.len < 256) {
                ap.security = if ((wpa | rsn) & 0x100 != 0) .personal else if (rsn & 0x400 != 0) .sae else if (flags & 1 != 0 or wpa != 0 or rsn != 0) .unsupported else .open;
                try aps.append(gpa, ap);
            }
            if (is_wifi and devices.items.len < 16) try devices.append(gpa, dev);
            if (is_wired and ethernet.items.len < self.ethernet.len) try ethernet.append(gpa, eth);
            if (is_ip4 and configs.items.len < 64) try configs.append(gpa, ip4);
        }
        self.available = true;
        self.state = state;
        self.connectivity = connectivity;
        self.ethernet_count = ethernet.items.len;
        for (ethernet.items, self.ethernet[0..self.ethernet_count]) |eth, *out| {
            out.* = eth;
            if (eth.connected()) for (configs.items) |config| {
                if (!eq(u8, config.path.slice(), eth.ip4.slice())) continue;
                out.address = config.address;
                out.gateway = config.gateway;
                out.dns = config.dns;
                break;
            };
        }
        self.checkWired();
        self.count = 0;
        const previous_device = self.device;
        self.device = .{};
        var chosen: ?*Device = null;
        for (devices.items) |*dev| {
            if (chosen == null or dev.state == 100) chosen = dev;
        }
        if (chosen) |dev| {
            if (!eq(u8, previous_device.slice(), dev.path.slice()) or dev.last_scan != self.last_scan) self.stopScan();
            self.last_scan = dev.last_scan;
            self.device = dev.path;
            for (aps.items) |candidate| {
                var belongs = false;
                for (dev.aps[0..dev.count]) |p| if (eq(u8, p.slice(), candidate.path.slice())) {
                    belongs = true;
                    break;
                };
                if (!belongs) continue;
                var net = candidate;
                net.connected = dev.state == 100 and eq(u8, dev.active.slice(), net.path.slice());
                var duplicate: ?usize = null;
                for (self.networks[0..self.count], 0..) |other, i| if (sameNetwork(other, net)) {
                    duplicate = i;
                    break;
                };
                if (duplicate) |i| {
                    const other = self.networks[i];
                    if (net.connected or (!other.connected and net.strength > other.strength)) self.networks[i] = net;
                } else {
                    self.networks[self.count] = net;
                    self.count += 1;
                }
            }
            if (self.joining) |joining| {
                for (self.networks[0..self.count]) |net| if (net.connected and sameNetwork(net, joining)) {
                    self.busy = false;
                    self.joining = null;
                    self.message = "";
                    break;
                };
                if (dev.state == 120) {
                    self.busy = false;
                    self.joining = null;
                    self.message = "Connection failed. Check the password and try again.";
                }
            }
        }
        // Drop removed profiles and fetch only new/invalidated ones.
        var i: usize = 0;
        while (i < self.saved_count) {
            var found = false;
            for (paths.items) |p| if (eq(u8, p.slice(), self.saved[i].path.slice())) {
                found = true;
                break;
            };
            if (!found) {
                self.saved_count -= 1;
                self.saved[i] = self.saved[self.saved_count];
            } else i += 1;
        }
        for (paths.items) |p| {
            var index: ?usize = null;
            for (self.saved[0..self.saved_count], 0..) |s, j| if (eq(u8, s.path.slice(), p.slice())) {
                index = j;
                break;
            };
            if (index == null and self.saved_count < self.saved.len) {
                index = self.saved_count;
                self.saved[self.saved_count] = .{ .path = p };
                self.saved_count += 1;
            }
            if (index) |j| if (!self.saved[j].loaded) {
                self.saved[j].loaded = true;
                self.fetchSaved(p);
            };
        }
        if (!self.enabled or !self.hardware or self.device.len == 0) {
            self.stopScan();
            self.busy = false;
            self.joining = null;
        }
        if (self.joining == null) if (self.join_timer) |timer| timer.timerUpdate(0) catch {};
        self.applySaved();
        std.mem.sort(Network, self.networks[0..self.count], {}, less);
        if (eq(u8, self.message, "NetworkManager is unavailable")) self.message = "";
    }
    fn less(_: void, a: Network, b: Network) bool {
        if (a.connected != b.connected) return a.connected;
        if (a.strength != b.strength) return a.strength > b.strength;
        return std.mem.order(u8, a.ssid.slice(), b.ssid.slice()) == .lt;
    }
    fn applySaved(self: *Manager) void {
        for (self.networks[0..self.count]) |*net| {
            net.saved = .{};
            for (self.saved[0..self.saved_count]) |s| if (s.security == net.security and eq(u8, s.ssid.slice(), net.ssid.slice())) {
                net.saved = s.path;
                break;
            };
        }
    }
    fn fetchSaved(self: *Manager, path: Path) void {
        const req = gpa.create(Request) catch return;
        req.* = .{ .manager = self, .epoch = self.epoch, .path = path };
        const b: wire.Writer = .{ .allocator = secure };
        _ = self.conn.?.call(self.owner.slice(), path.slice(), settings_iface, "GetSettings", "", &b, req, gotSaved, 5000) catch {
            gpa.destroy(req);
        };
    }
    fn gotSaved(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const req: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(req);
        const self = req.manager;
        if (self.closing or self.epoch != req.epoch) return;
        var msg = result catch return;
        if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{sa{sv}}")) return;
        const saved = parseSaved(&msg.body, req.path) catch return;
        for (self.saved[0..self.saved_count]) |*s| if (eq(u8, s.path.slice(), req.path.slice())) {
            s.* = saved;
            break;
        };
        self.applySaved();
        self.refresh();
    }
    pub fn searching(self: *const Manager) bool {
        return self.fetching or self.scanning;
    }
    fn stopScan(self: *Manager) void {
        self.scanning = false;
        if (self.scan_timer) |timer| timer.timerUpdate(0) catch {};
    }
    fn scanTimeout(self: *Manager) c_int {
        self.stopScan();
        self.refresh();
        return 0;
    }
    fn scanRequested(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const req: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(req);
        const self = req.manager;
        if (self.closing or self.epoch != req.epoch) return;
        const msg = result catch {
            self.stopScan();
            self.refresh();
            return;
        };
        if (!self.fromOwner(msg) or msg.kind != .method_return) {
            self.stopScan();
            self.refresh();
        }
        // Acceptance is not completion: LastScan changes when results arrive.
    }
    pub fn scan(self: *Manager) void {
        if (!self.available or !self.enabled or !self.hardware or self.device.len == 0 or self.scanning) return;
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        const a = b.beginArray(8) catch return;
        b.endArray(a) catch return;
        if (self.scan_timer == null) self.scan_timer = self.server.wl_server.getEventLoop().addTimer(*Manager, scanTimeout, self) catch return;
        const req = gpa.create(Request) catch return;
        req.* = .{ .manager = self, .epoch = self.epoch, .path = self.device };
        _ = self.conn.?.call(self.owner.slice(), self.device.slice(), wireless, "RequestScan", "a{sv}", &b, req, scanRequested, 5000) catch {
            gpa.destroy(req);
            return;
        };
        self.scanning = true;
        // Bound the indicator if a driver never reports scan completion.
        self.scan_timer.?.timerUpdate(15000) catch self.stopScan();
    }
    pub fn toggle(self: *Manager) void {
        if (!self.available or !self.hardware or self.busy) return;
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        b.string(nm) catch return;
        b.string("WirelessEnabled") catch return;
        b.variant("b") catch return;
        b.boolean(!self.enabled) catch return;
        self.action(root, properties, "Set", "ssv", &b);
    }
    pub fn setEthernet(self: *Manager, path: Path, on: bool) void {
        if (!self.available or self.wired_pending != null) return;
        const eth = for (self.ethernet[0..self.ethernet_count]) |eth| {
            if (eq(u8, eth.path.slice(), path.slice())) break eth;
        } else return;
        if (!eth.managed or (on and !eth.carrier)) return;
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        if (on) {
            if (eth.has_profile) {
                // Let NetworkManager choose the best existing profile; do not
                // replace the user's static addresses, DNS or authentication.
                b.objectPath("/") catch return;
            } else {
                writeWiredSettings(&b, eth.name.slice()) catch return;
            }
            b.objectPath(path.slice()) catch return;
            b.objectPath("/") catch return;
        }
        if (self.wired_timer == null) self.wired_timer = self.server.wl_server.getEventLoop().addTimer(*Manager, wiredTimeout, self) catch return;
        const req = gpa.create(Request) catch return;
        self.wired_generation +%= 1;
        req.* = .{ .manager = self, .epoch = self.epoch, .path = path, .wired_generation = self.wired_generation };
        _ = self.conn.?.callWithFlags(self.owner.slice(), if (on) root else path.slice(), if (on) nm else device_iface, if (!on) "Disconnect" else if (eth.has_profile) "ActivateConnection" else "AddAndActivateConnection", if (!on) "" else if (eth.has_profile) "ooo" else "a{sa{sv}}oo", &b, req, wiredDone, 15000, wire.flag_allow_interactive_authorization) catch {
            gpa.destroy(req);
            self.wired_message = "Could not send the Ethernet request.";
            self.refresh();
            return;
        };
        self.wired_pending = path;
        self.wired_want_connected = on;
        self.wired_accepted = false;
        self.wired_message = if (on) "Connecting Ethernet…" else "Disconnecting Ethernet…";
        self.wired_timer.?.timerUpdate(45000) catch {};
        self.refresh();
    }
    fn wiredDone(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const req: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(req);
        const self = req.manager;
        if (self.closing or self.epoch != req.epoch or self.wired_generation != req.wired_generation) return;
        const pending = self.wired_pending orelse return;
        if (!eq(u8, pending.slice(), req.path.slice())) return;
        const msg = result catch {
            self.finishWired("Ethernet request failed. Check permissions and try again.");
            return;
        };
        if (!self.fromOwner(msg) or msg.kind != .method_return) {
            self.finishWired("Ethernet request failed. Check permissions and try again.");
            return;
        }
        self.wired_accepted = true;
        self.fetch();
    }
    fn checkWired(self: *Manager) void {
        const pending = self.wired_pending orelse return;
        for (self.ethernet[0..self.ethernet_count]) |eth| {
            if (!eq(u8, eth.path.slice(), pending.slice())) continue;
            if (!self.wired_accepted) return;
            if (self.wired_want_connected and (!eth.carrier or eth.state == 120 or !eth.managed)) {
                self.finishWired("Ethernet could not connect. Check the cable and connection settings.");
            } else if ((self.wired_want_connected and eth.connected()) or (!self.wired_want_connected and !eth.active() and eth.state != 110)) self.finishWired("");
            return;
        }
        self.finishWired("Ethernet adapter was removed.");
    }
    fn finishWired(self: *Manager, message: []const u8) void {
        self.wired_pending = null;
        self.wired_message = message;
        if (self.wired_timer) |timer| timer.timerUpdate(0) catch {};
        self.refresh();
    }
    fn wiredTimeout(self: *Manager) c_int {
        self.finishWired("Ethernet connection timed out. Check the cable and try again.");
        return 0;
    }
    pub fn join(self: *Manager, net: Network, password: []const u8, autojoin: bool, hidden: bool) void {
        if (!self.available or !self.enabled or !self.hardware or self.device.len == 0 or self.busy) return;
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        if (net.saved.len != 0 and password.len != 0) {
            const update = secure.create(PasswordUpdate) catch return;
            update.* = .{ .manager = self, .epoch = self.epoch, .net = net, .len = password.len };
            @memcpy(update.password[0..password.len], password);
            _ = self.conn.?.call(self.owner.slice(), net.saved.slice(), settings_iface, "GetSettings", "", &b, update, passwordSettings, 5000) catch {
                secure.destroy(update);
                return;
            };
            self.busy = true;
        } else if (net.saved.len != 0) {
            b.objectPath(net.saved.slice()) catch return;
            b.objectPath(self.device.slice()) catch return;
            b.objectPath(if (hidden) "/" else net.path.slice()) catch return;
            self.action(root, nm, "ActivateConnection", "ooo", &b);
        } else {
            writeSettings(&b, net, password, autojoin, hidden) catch return;
            b.objectPath(self.device.slice()) catch return;
            b.objectPath(if (hidden) "/" else net.path.slice()) catch return;
            self.action(root, nm, "AddAndActivateConnection", "a{sa{sv}}oo", &b);
        }
        if (self.busy) {
            self.joining = net;
            if (self.join_timer == null) self.join_timer = self.server.wl_server.getEventLoop().addTimer(*Manager, joinTimeout, self) catch null;
            if (self.join_timer) |timer| timer.timerUpdate(45000) catch {};
            self.message = "Connecting…";
            self.refresh();
        }
    }
    // Replace only the secret, preserving saved IP, DNS, identity and routing
    // settings. The temporary context is locked and wiped when the call ends.
    fn passwordSettings(owner: ?*anyopaque, conn: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const update: *PasswordUpdate = @ptrCast(@alignCast(owner.?));
        const self = update.manager;
        if (self.closing or self.epoch != update.epoch) {
            secure.destroy(update);
            return;
        }
        var msg = result catch {
            secure.destroy(update);
            self.failed();
            return;
        };
        if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{sa{sv}}")) {
            secure.destroy(update);
            self.failed();
            return;
        }
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        replacePassword(&msg.body, &b, update.password[0..update.len]) catch {
            secure.destroy(update);
            self.failed();
            return;
        };
        _ = conn.callWithFlags(self.owner.slice(), update.net.saved.slice(), settings_iface, "Update", "a{sa{sv}}", &b, update, passwordUpdated, 15000, wire.flag_allow_interactive_authorization) catch {
            secure.destroy(update);
            self.failed();
            return;
        };
        std.crypto.secureZero(u8, &update.password);
    }
    fn passwordUpdated(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const update: *PasswordUpdate = @ptrCast(@alignCast(owner.?));
        defer secure.destroy(update);
        const self = update.manager;
        if (self.closing or self.epoch != update.epoch) return;
        const msg = result catch {
            self.failed();
            return;
        };
        if (!self.fromOwner(msg) or msg.kind != .method_return) {
            self.failed();
            return;
        }
        var b: wire.Writer = .{ .allocator = secure };
        defer b.deinit();
        b.objectPath(update.net.saved.slice()) catch {
            self.failed();
            return;
        };
        b.objectPath(self.device.slice()) catch {
            self.failed();
            return;
        };
        b.objectPath(update.net.path.slice()) catch {
            self.failed();
            return;
        };
        self.action(root, nm, "ActivateConnection", "ooo", &b);
        if (self.busy) self.message = "Connecting…";
    }
    fn action(self: *Manager, path: []const u8, iface: []const u8, method: []const u8, sig: []const u8, b: *wire.Writer) void {
        const req = gpa.create(Request) catch return;
        req.* = .{ .manager = self, .epoch = self.epoch, .path = .{} };
        _ = self.conn.?.callWithFlags(self.owner.slice(), path, iface, method, sig, b, req, actionDone, 15000, wire.flag_allow_interactive_authorization) catch {
            gpa.destroy(req);
            self.message = "Could not send the Wi-Fi request";
            self.refresh();
            return;
        };
        self.busy = true;
        self.message = "Updating Wi-Fi…";
        self.refresh();
    }
    fn actionDone(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const req: *Request = @ptrCast(@alignCast(owner.?));
        defer gpa.destroy(req);
        const self = req.manager;
        if (self.closing or self.epoch != req.epoch) return;
        const msg = result catch {
            self.failed();
            return;
        };
        if (!self.fromOwner(msg) or msg.kind != .method_return) {
            self.failed();
            return;
        }
        // The method accepts activation; the device state confirms completion.
        if (self.joining == null) {
            self.busy = false;
            self.message = "";
        }
        self.fetch();
        self.refresh();
    }
    fn joinTimeout(self: *Manager) c_int {
        self.failed();
        return 0;
    }
    fn failed(self: *Manager) void {
        if (self.join_timer) |timer| timer.timerUpdate(0) catch {};
        self.busy = false;
        self.joining = null;
        self.message = "Wi-Fi request failed. Check credentials and permissions.";
        self.refresh();
    }
};
pub fn sameNetwork(a: Network, b: Network) bool {
    return a.security == b.security and eq(u8, a.ssid.slice(), b.ssid.slice());
}
pub fn networkName(net: *const Network) []const u8 {
    return if (std.unicode.utf8ValidateSlice(net.ssid.slice())) net.ssid.slice() else "Wi-Fi network";
}
pub fn networkSubtitle(net: Network) []const u8 {
    return if (net.connected) (if (net.saved.len != 0) "Connected · Saved" else "Connected") else if (net.saved.len != 0) "Saved" else if (net.security == .open) "Open" else if (net.security == .unsupported) "Additional setup required" else "Secured";
}
pub fn joinError(net: Network, password: []const u8) ?[]const u8 {
    if (net.ssid.len == 0) return "Enter a network name.";
    if (net.security == .unsupported and net.saved.len == 0) return "This security type needs a network configuration tool.";
    if (net.connected or net.security == .open or (net.saved.len != 0 and password.len == 0)) return null;
    const hex = password.len == 64 and for (password) |c| {
        if (!std.ascii.isHex(c)) break false;
    } else true;
    if (net.security == .personal and !hex and (password.len < 8 or password.len > 63)) return "Use 8–63 characters or a 64-digit hex key.";
    if (net.security == .sae and (password.len < 1 or password.len > 63)) return "Enter a password (1–63 bytes).";
    return null;
}
fn addressList(b: *wire.Reader) !Text(256) {
    var out: Text(256) = .{};
    var list = try b.array(4);
    while (list.offset < list.bytes.len) {
        var entries = try list.array(8);
        while (entries.offset < entries.bytes.len) {
            try entries.alignTo(8);
            const key = try entries.string();
            const sig = try entries.variant();
            if (eq(u8, key, "address") and eq(u8, sig, "s")) {
                const value = try entries.string();
                const separator: []const u8 = if (out.len == 0) "" else ", ";
                if (out.len + separator.len + value.len <= out.bytes.len) {
                    @memcpy(out.bytes[out.len..][0..separator.len], separator);
                    out.len += separator.len;
                    @memcpy(out.bytes[out.len..][0..value.len], value);
                    out.len += value.len;
                }
            } else try entries.skip(sig);
        }
    }
    return out;
}
fn writeWiredSettings(b: *wire.Writer, name: []const u8) !void {
    const all = try b.beginArray(8);
    const conn = try section(b, "connection");
    try str(b, "id", name);
    try str(b, "type", "802-3-ethernet");
    try str(b, "interface-name", name);
    try b.endArray(conn);
    const eth = try section(b, "802-3-ethernet");
    try b.endArray(eth);
    const ip4 = try section(b, "ipv4");
    try str(b, "method", "auto");
    try b.endArray(ip4);
    const ip6 = try section(b, "ipv6");
    try str(b, "method", "auto");
    try b.endArray(ip6);
    try b.endArray(all);
}
fn parseSaved(b: *wire.Reader, path: Path) !Saved {
    var out: Saved = .{ .path = path, .loaded = true };
    var sections = try b.array(8);
    while (sections.offset < sections.bytes.len) {
        try sections.alignTo(8);
        const section_name = try sections.string();
        var props = try sections.array(8);
        while (props.offset < props.bytes.len) {
            try props.alignTo(8);
            const key = try props.string();
            const sig = try props.variant();
            if (eq(u8, section_name, "802-11-wireless") and eq(u8, key, "ssid") and eq(u8, sig, "ay")) {
                var bytes = try props.array(1);
                out.ssid.set(try bytes.take(bytes.bytes.len - bytes.offset));
            } else if (eq(u8, section_name, "802-11-wireless-security") and eq(u8, key, "key-mgmt") and eq(u8, sig, "s")) {
                const value = try props.string();
                out.security = if (eq(u8, value, "wpa-psk")) .personal else if (eq(u8, value, "sae")) .sae else .unsupported;
            } else try props.skip(sig);
        }
    }
    return out;
}
fn section(b: *wire.Writer, name: []const u8) !wire.Writer.Array {
    try b.alignTo(8);
    try b.string(name);
    return b.beginArray(8);
}
fn prop(b: *wire.Writer, name: []const u8, sig: []const u8) !void {
    try b.alignTo(8);
    try b.string(name);
    try b.variant(sig);
}
fn str(b: *wire.Writer, name: []const u8, value: []const u8) !void {
    try prop(b, name, "s");
    try b.string(value);
}
fn writeSettings(b: *wire.Writer, net: Network, password: []const u8, autojoin: bool, hidden: bool) !void {
    const all = try b.beginArray(8);
    const conn = try section(b, "connection");
    // SSIDs are byte strings. Use a valid UTF-8 display name for connection.id.
    try str(b, "id", if (std.unicode.utf8ValidateSlice(net.ssid.slice())) net.ssid.slice() else "Wi-Fi network");
    try str(b, "type", "802-11-wireless");
    try prop(b, "autoconnect", "b");
    try b.boolean(autojoin);
    try b.endArray(conn);
    const wifi = try section(b, "802-11-wireless");
    try prop(b, "ssid", "ay");
    const bytes = try b.beginArray(1);
    try b.raw(net.ssid.slice());
    try b.endArray(bytes);
    try str(b, "mode", "infrastructure");
    try prop(b, "hidden", "b");
    try b.boolean(hidden);
    try b.endArray(wifi);
    if (net.security != .open) {
        const security = try section(b, "802-11-wireless-security");
        try str(b, "key-mgmt", if (net.security == .sae) "sae" else "wpa-psk");
        try str(b, "psk", password);
        try b.endArray(security);
    }
    try b.endArray(all);
}

/// Dict entries start at an 8-byte boundary in both readers and writers, so
/// copying a complete unchanged entry preserves every nested value's alignment.
fn replacePassword(reader: *wire.Reader, b: *wire.Writer, password: []const u8) !void {
    b.endian = reader.endian;
    const all = try b.beginArray(8);
    var sections = try reader.array(8);
    var found_security = false;
    while (sections.offset < sections.bytes.len) {
        try sections.alignTo(8);
        const name = try sections.string();
        const out = try section(b, name);
        const security = eq(u8, name, "802-11-wireless-security");
        var entries = try sections.array(8);
        while (entries.offset < entries.bytes.len) {
            try entries.alignTo(8);
            const start = entries.offset;
            const key = try entries.string();
            const sig = try entries.variant();
            try entries.skip(sig);
            if (security and (eq(u8, key, "psk") or eq(u8, key, "psk-flags"))) continue;
            try b.alignTo(8);
            try b.raw(entries.bytes[start..entries.offset]);
        }
        if (security) {
            found_security = true;
            try str(b, "psk", password);
            try prop(b, "psk-flags", "u");
            try b.uint32(0);
        }
        try b.endArray(out);
    }
    if (!found_security) return error.MissingSecurity;
    try b.endArray(all);
}
