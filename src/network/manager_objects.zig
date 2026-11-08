//! Reading NetworkManager's objects into devices and networks, and its saved connections.

const i18n = @import("i18n");
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const gpa = @import("../main.zig").gpa;
const secure = @import("secure_allocator.zig").allocator;
const eq = std.mem.eql;
const manager_mod = @import("manager.zig");
const Manager = manager_mod.Manager;
const nm = manager_mod.nm;
const objects_root = manager_mod.objects_root;
const wireless = manager_mod.wireless;
const wired = manager_mod.wired;
const device_iface = manager_mod.device_iface;
const ip4_iface = manager_mod.ip4_iface;
const ip6_iface = manager_mod.ip6_iface;
const active_iface = manager_mod.active_iface;
const ap_iface = manager_mod.ap_iface;
const settings_iface = manager_mod.settings_iface;
const Path = manager_mod.Path;
const Network = manager_mod.Network;
const Ethernet = manager_mod.Ethernet;
const Config = manager_mod.Config;
const ActiveConnection = manager_mod.ActiveConnection;
const props_mod = @import("manager_props.zig");
const IpObject = struct { v6: bool, cfg: Config };
const Device = manager_mod.Device;
const Request = manager_mod.Request;
const sameNetwork = manager_mod.sameNetwork;
const parseSaved = manager_mod.parseSaved;

pub fn fetch(self: *Manager) void {
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

pub fn gotObjects(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
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
        self.message = i18n.tr("Could not read Wi-Fi networks");
        self.refresh();
        return;
    };
    if (!self.fromOwner(msg) or msg.kind != .method_return or !eq(u8, msg.headers.signature, "a{oa{sa{sv}}}")) return;
    self.parseObjects(&msg.body) catch {
        self.message = i18n.tr("Could not read Wi-Fi networks");
        self.refresh();
        return;
    };
    if (self.scan_pending) {
        self.scan_pending = false;
        self.scan();
    }
    if (self.access == .unknown) self.checkAccess(false);
    self.refresh();
}

pub fn parseObjects(self: *Manager, b: *wire.Reader) !void {
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
    var configs: std.ArrayList(IpObject) = .empty;
    defer configs.deinit(gpa);
    var actives: std.ArrayList(ActiveConnection) = .empty;
    defer actives.deinit(gpa);
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
        var cfg: Config = .{ .path = Path.init(path) };
        var act: ActiveConnection = .{ .path = Path.init(path) };
        var is_ap = false;
        var is_wifi = false;
        var is_wired = false;
        var is_ip4 = false;
        var is_ip6 = false;
        var is_active = false;
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
            is_ip6 = is_ip6 or eq(u8, iface, ip6_iface);
            is_active = is_active or eq(u8, iface, active_iface);
            var props = try ifaces.array(8);
            while (props.offset < props.bytes.len) {
                try props.alignTo(8);
                const key = try props.string();
                const sig = try props.variant();
                if (eq(u8, iface, device_iface)) {
                    if (eq(u8, key, "Interface") and eq(u8, sig, "s")) {
                        eth.name.set(try props.string());
                        dev.name = eth.name;
                    } else if (eq(u8, key, "Driver") and eq(u8, sig, "s")) eth.driver.set(try props.string()) else if (eq(u8, key, "Managed") and eq(u8, sig, "b")) eth.managed = try props.boolean() else if (eq(u8, key, "Ip4Config") and eq(u8, sig, "o")) {
                        eth.ip4.set(try props.objectPath());
                        dev.ip4 = eth.ip4;
                    } else if (eq(u8, key, "Ip6Config") and eq(u8, sig, "o")) {
                        eth.ip6.set(try props.objectPath());
                        dev.ip6 = eth.ip6;
                    } else if (eq(u8, key, "ActiveConnection") and eq(u8, sig, "o")) {
                        eth.active_connection.set(try props.objectPath());
                        dev.active_connection = eth.active_connection;
                    } else if (eq(u8, key, "HwAddress") and eq(u8, sig, "s")) {
                        eth.mac.set(try props.string());
                        dev.mac = eth.mac;
                    } else if (eq(u8, key, "AvailableConnections") and eq(u8, sig, "ao")) {
                        var list = try props.array(4);
                        while (list.offset < list.bytes.len) {
                            const profile = try list.objectPath();
                            if (!eth.has_profile) eth.profile.set(profile);
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
                if (eq(u8, iface, ip4_iface) or eq(u8, iface, ip6_iface)) {
                    if (!try props_mod.ipProperty(&cfg, eq(u8, iface, ip6_iface), key, sig, &props)) try props.skip(sig);
                    continue;
                }
                if (eq(u8, iface, active_iface)) {
                    if (eq(u8, key, "Id") and eq(u8, sig, "s")) act.id.set(try props.string()) else if (eq(u8, key, "Type") and eq(u8, sig, "s")) act.kind.set(try props.string()) else if (eq(u8, key, "Connection") and eq(u8, sig, "o")) act.profile.set(try props.objectPath()) else if (eq(u8, key, "State") and eq(u8, sig, "u")) act.state = try props.uint32() else try props.skip(sig);
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
                } else if (eq(u8, iface, wireless) and eq(u8, key, "Bitrate") and eq(u8, sig, "u")) {
                    dev.bitrate = try props.uint32();
                } else if (eq(u8, iface, wireless) and eq(u8, key, "HwAddress") and eq(u8, sig, "s")) {
                    dev.mac.set(try props.string());
                } else if (eq(u8, iface, ap_iface) and eq(u8, key, "Frequency") and eq(u8, sig, "u")) {
                    ap.frequency = try props.uint32();
                } else if (eq(u8, iface, ap_iface) and eq(u8, key, "HwAddress") and eq(u8, sig, "s")) {
                    ap.bssid.set(try props.string());
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
        if ((is_ip4 or is_ip6) and configs.items.len < 64) try configs.append(gpa, .{ .v6 = is_ip6, .cfg = cfg });
        if (is_active and actives.items.len < self.actives.len) try actives.append(gpa, act);
    }
    self.available = true;
    self.state = state;
    self.connectivity = connectivity;
    self.ethernet_count = ethernet.items.len;
    for (ethernet.items, self.ethernet[0..self.ethernet_count]) |eth, *out| {
        out.* = eth;
        if (eth.connected()) out.link = linkOf(configs.items, eth.ip4.slice(), eth.ip6.slice());
    }
    self.active_count = actives.items.len;
    @memcpy(self.actives[0..actives.items.len], actives.items);
    self.checkWired();
    self.count = 0;
    const previous_device = self.device;
    self.device = .{};
    self.wifi = .{};
    var chosen: ?*Device = null;
    for (devices.items) |*dev| {
        if (chosen == null or dev.state == 100) chosen = dev;
    }
    if (chosen) |dev| {
        if (!eq(u8, previous_device.slice(), dev.path.slice()) or dev.last_scan != self.last_scan) self.stopScan();
        self.last_scan = dev.last_scan;
        self.device = dev.path;
        self.wifi = .{ .name = dev.name, .mac = dev.mac, .bitrate = if (dev.state == 100) dev.bitrate else 0, .active = dev.active_connection };
        if (dev.state == 100) {
            self.wifi.link = linkOf(configs.items, dev.ip4.slice(), dev.ip6.slice());
            for (actives.items) |active| if (eq(u8, active.path.slice(), dev.active_connection.slice())) {
                self.wifi.profile = active.profile;
            };
        }
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
                self.message = i18n.tr("Connection failed. Check the password and try again.");
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
    if (eq(u8, self.message, i18n.tr("NetworkManager is unavailable"))) self.message = "";
}

fn linkOf(configs: []const IpObject, ip4: []const u8, ip6: []const u8) manager_mod.Link {
    var link: manager_mod.Link = .{};
    for (configs) |config| {
        if (!config.v6 and eq(u8, config.cfg.path.slice(), ip4)) link.v4 = config.cfg;
        if (config.v6 and eq(u8, config.cfg.path.slice(), ip6)) link.v6 = config.cfg;
    }
    return link;
}

pub fn less(_: void, a: Network, b: Network) bool {
    if (a.connected != b.connected) return a.connected;
    if (a.strength != b.strength) return a.strength > b.strength;
    return std.mem.order(u8, a.ssid.slice(), b.ssid.slice()) == .lt;
}

pub fn applySaved(self: *Manager) void {
    for (self.networks[0..self.count]) |*net| {
        net.saved = .{};
        for (self.saved[0..self.saved_count]) |s| if (s.security == net.security and eq(u8, s.ssid.slice(), net.ssid.slice())) {
            net.saved = s.path;
            break;
        };
    }
}

pub fn fetchSaved(self: *Manager, path: Path) void {
    const req = gpa.create(Request) catch return;
    req.* = .{ .manager = self, .epoch = self.epoch, .path = path };
    const b: wire.Writer = .{ .allocator = secure };
    _ = self.conn.?.call(self.owner.slice(), path.slice(), settings_iface, "GetSettings", "", &b, req, gotSaved, 5000) catch {
        gpa.destroy(req);
    };
}

pub fn gotSaved(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
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
