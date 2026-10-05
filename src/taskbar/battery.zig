//! Linux power-supply snapshots, never read during paint.
//!
//! A read is not free: the battery's `uevent` evaluates ACPI `_BST` and the AC
//! adapter's `_PSR`, measured at 1-1.5 ms of kernel CPU charged to the
//! compositor.
//! Kernel power_supply uevents (plug, unplug, charge state) trigger an
//! immediate read; capacity is re-read on the taskbar's minute tick, because
//! many firmwares never announce percentage changes.
const std = @import("std");
const linux = std.os.linux;

pub const State = struct {
    percent: ?u8 = null,
    plugged: bool = false,
    charging: bool = false,
    full: bool = false,
    health: ?u8 = null,
    full_wh: ?f64 = null,
    cycles: ?u32 = null,

    pub fn status(self: State) []const u8 {
        if (self.charging) return "Charging";
        if (self.full) return "Fully Charged";
        if (self.plugged) return "Plugged In";
        return "On Battery";
    }
};

fn field(contents: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == '=')
            return line[key.len + 1 ..];
    }
    return null;
}

const Snapshot = struct {
    sum: u32 = 0,
    count: u32 = 0,
    online: bool = false,
    charging: bool = false,
    full_count: u32 = 0,
    health_sum: u32 = 0,
    health_count: u32 = 0,
    energy_sum: f64 = 0,
    energy_count: u32 = 0,
    cycles: ?u32 = null,

    fn add(self: *Snapshot, contents: []const u8) void {
        const kind = field(contents, "POWER_SUPPLY_TYPE") orelse return;
        // Ignore peripheral batteries (mice, keyboards, etc.).
        if (std.mem.eql(u8, field(contents, "POWER_SUPPLY_SCOPE") orelse "", "Device")) return;
        if (!std.mem.eql(u8, kind, "Battery")) {
            if (std.mem.eql(u8, field(contents, "POWER_SUPPLY_ONLINE") orelse "", "1")) self.online = true;
            return;
        }
        if (std.mem.eql(u8, field(contents, "POWER_SUPPLY_PRESENT") orelse "1", "0")) return;
        const raw = std.fmt.parseInt(u32, field(contents, "POWER_SUPPLY_CAPACITY") orelse return, 10) catch return;
        // ACPI computes capacity from ENERGY_NOW / ENERGY_FULL; on a worn pack
        // the firmware's stale "full" estimate makes this read 101% or more.
        // Clamp instead of rejecting, or the battery icon disappears.
        const percent = @min(raw, 100);
        self.sum += percent;
        self.count += 1;
        if (std.mem.eql(u8, field(contents, "POWER_SUPPLY_STATUS") orelse "", "Charging")) self.charging = true;
        if (std.mem.eql(u8, field(contents, "POWER_SUPPLY_STATUS") orelse "", "Full")) self.full_count += 1;
        const energy = number(contents, "POWER_SUPPLY_ENERGY_FULL");
        const charge = number(contents, "POWER_SUPPLY_CHARGE_FULL");
        const full = energy orelse charge;
        const design = number(contents, if (energy != null) "POWER_SUPPLY_ENERGY_FULL_DESIGN" else "POWER_SUPPLY_CHARGE_FULL_DESIGN");
        if (full) |f| if (design) |d| {
            if (d > 0 and f > 0) {
                self.health_sum += @intFromFloat(@round(@min(100, f / d * 100)));
                self.health_count += 1;
            }
        };
        // Charge-only drivers need the nominal voltage to express Wh.
        const wh = if (energy) |e| e / 1_000_000 else if (charge) |q| blk: {
            const voltage = number(contents, "POWER_SUPPLY_VOLTAGE_MIN_DESIGN") orelse break :blk null;
            break :blk @as(?f64, q * voltage / 1_000_000_000_000);
        } else null;
        if (wh) |value| if (value > 0) {
            self.energy_sum += value;
            self.energy_count += 1;
        };
        self.cycles = std.fmt.parseInt(u32, field(contents, "POWER_SUPPLY_CYCLE_COUNT") orelse "", 10) catch null;
    }

    fn state(self: Snapshot) State {
        return .{
            // Equal-pack average when more than one system battery is present.
            .percent = if (self.count == 0) null else @intCast((self.sum + self.count / 2) / self.count),
            .plugged = self.online or self.charging,
            .charging = self.charging,
            .full = self.count > 0 and self.full_count == self.count,
            .health = if (self.count > 0 and self.health_count == self.count) @intCast((self.health_sum + self.count / 2) / self.count) else null,
            .full_wh = if (self.count > 0 and self.energy_count == self.count) self.energy_sum else null,
            // Cycle counts belong to a pack; summing them is misleading.
            .cycles = if (self.count == 1) self.cycles else null,
        };
    }
};

fn number(contents: []const u8, key: []const u8) ?f64 {
    const value = std.fmt.parseInt(u64, field(contents, key) orelse return null, 10) catch return null;
    return @floatFromInt(value);
}

pub fn read(io: std.Io, allocator: std.mem.Allocator) State {
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/power_supply", .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var snapshot: Snapshot = .{};
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        var path_buf: [512]u8 = undefined;
        // A HID peripheral battery's uevent can send a synchronous GET_REPORT
        // to the device; `scope` is static, so check it before reading that.
        const scope_path = std.fmt.bufPrint(&path_buf, "{s}/scope", .{entry.name}) catch continue;
        var scope_buf: [16]u8 = undefined;
        if (dir.readFile(io, scope_path, &scope_buf)) |scope| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, scope, "\n"), "Device")) continue;
        } else |_| {}
        const path = std.fmt.bufPrint(&path_buf, "{s}/uevent", .{entry.name}) catch continue;
        const contents = dir.readFileAlloc(io, path, allocator, .limited(16384)) catch continue;
        defer allocator.free(contents);
        snapshot.add(contents);
    }
    return snapshot.state();
}

/// Nonblocking socket on the kernel's uevent multicast group; `null` leaves
/// only the minute poll. Receiving needs no privileges, and sending to the
/// group does, so nothing unprivileged can fake these (they only trigger a
/// sysfs read anyway).
pub fn openUeventSocket() ?std.posix.fd_t {
    const rc = linux.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT);
    // Raw syscalls return -errno; std.posix.errno expects libc's -1/errno.
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(rc);
    const addr: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl))) != .SUCCESS) {
        _ = std.posix.system.close(fd);
        return null;
    }
    return fd;
}

/// Empties the socket. True when any message could change `read`'s result,
/// including an overflow that may have dropped one.
pub fn drainUevents(fd: std.posix.fd_t) bool {
    var relevant = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => if (isSystemPowerSupplyUevent(buf[0..rc])) {
                relevant = true;
            },
            .INTR => {},
            .NOBUFS => relevant = true,
            else => return relevant,
        }
    }
}

/// Kernel uevents are `action@devpath` then NUL-separated KEY=VALUE pairs.
/// Peripheral batteries are ignored by `read`, so their events are too.
fn isSystemPowerSupplyUevent(msg: []const u8) bool {
    var fields = std.mem.splitScalar(u8, msg, 0);
    if (std.mem.indexOfScalar(u8, fields.first(), '@') == null) return false;
    var power_supply = false;
    while (fields.next()) |kv| {
        if (std.mem.eql(u8, kv, "SUBSYSTEM=power_supply")) power_supply = true;
        if (std.mem.eql(u8, kv, "POWER_SUPPLY_SCOPE=Device")) return false;
    }
    return power_supply;
}

test "battery percentage and external power are independent" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=82\nPOWER_SUPPLY_STATUS=Discharging\n");
    try std.testing.expectEqual(State{ .percent = 82 }, s.state());
    s.add("POWER_SUPPLY_TYPE=Mains\nPOWER_SUPPLY_ONLINE=1\n");
    try std.testing.expectEqual(State{ .percent = 82, .plugged = true }, s.state());
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=100\nPOWER_SUPPLY_STATUS=Full\n");
    s.add("POWER_SUPPLY_TYPE=USB\nPOWER_SUPPLY_ONLINE=1\n");
    try std.testing.expectEqual(State{ .percent = 100, .plugged = true, .full = true }, s.state());
}

test "only system power_supply uevents trigger a read" {
    try std.testing.expect(isSystemPowerSupplyUevent("change@/devices/platform/ACPI0003:00/power_supply/AC0\x00ACTION=change\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_NAME=AC0\x00POWER_SUPPLY_ONLINE=1\x00"));
    try std.testing.expect(isSystemPowerSupplyUevent("remove@/devices/x/power_supply/BAT1\x00ACTION=remove\x00SUBSYSTEM=power_supply"));
    try std.testing.expect(!isSystemPowerSupplyUevent("change@/devices/x/power_supply/hid-mouse\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_SCOPE=Device\x00"));
    try std.testing.expect(!isSystemPowerSupplyUevent("add@/devices/pci0000:00/usb1/1-1\x00ACTION=add\x00SUBSYSTEM=usb\x00"));
    try std.testing.expect(!isSystemPowerSupplyUevent("libudev\x00SUBSYSTEM=power_supply\x00"));
}

test "draining reports a queued power_supply event once and stops at EAGAIN" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &fds)));
    defer for (fds) |fd| {
        _ = std.posix.system.close(fd);
    };
    const usb = "add@/devices/usb1\x00SUBSYSTEM=usb\x00";
    const ac = "change@/devices/AC0/power_supply/AC0\x00SUBSYSTEM=power_supply\x00";
    try std.testing.expect(!drainUevents(fds[0]));
    _ = linux.sendto(fds[1], usb, usb.len, 0, null, 0);
    try std.testing.expect(!drainUevents(fds[0]));
    _ = linux.sendto(fds[1], ac, ac.len, 0, null, 0);
    _ = linux.sendto(fds[1], usb, usb.len, 0, null, 0);
    try std.testing.expect(drainUevents(fds[0]));
    try std.testing.expect(!drainUevents(fds[0]));
}

test "over-full capacity from a worn pack clamps to 100 instead of hiding" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=101\nPOWER_SUPPLY_STATUS=Discharging\n");
    try std.testing.expectEqual(State{ .percent = 100 }, s.state());
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=300\n");
    try std.testing.expectEqual(@as(?u8, 100), s.state().percent);
}

test "absent peripheral and invalid batteries are hidden; charging works without AC entry" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=90\nPOWER_SUPPLY_SCOPE=Device\n");
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=90\nPOWER_SUPPLY_PRESENT=0\n");
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=-1\n");
    try std.testing.expectEqual(@as(?u8, null), s.state().percent);
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=0\nPOWER_SUPPLY_STATUS=Charging\n");
    try std.testing.expectEqual(State{ .percent = 0, .plugged = true, .charging = true }, s.state());
}

test "battery details use full versus design capacity and preserve missing readings" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=100\nPOWER_SUPPLY_STATUS=Full\nPOWER_SUPPLY_ENERGY_FULL=57000000\nPOWER_SUPPLY_ENERGY_FULL_DESIGN=90000000\nPOWER_SUPPLY_CYCLE_COUNT=482\n");
    try std.testing.expectEqual(@as(?u8, 63), s.state().health);
    try std.testing.expectEqual(@as(?f64, 57), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, 482), s.state().cycles);
    try std.testing.expectEqualStrings("Fully Charged", s.state().status());
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=80\n");
    try std.testing.expectEqual(@as(?u8, null), s.state().health);
    try std.testing.expectEqual(@as(?f64, null), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, null), s.state().cycles);
    try std.testing.expect(!s.state().full);
}

test "charge-only battery uses nominal voltage; invalid details stay unavailable" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=50\nPOWER_SUPPLY_CHARGE_FULL=4000000\nPOWER_SUPPLY_CHARGE_FULL_DESIGN=5000000\nPOWER_SUPPLY_VOLTAGE_MIN_DESIGN=12000000\nPOWER_SUPPLY_CYCLE_COUNT=0\n");
    try std.testing.expectEqual(@as(?u8, 80), s.state().health);
    try std.testing.expectEqual(@as(?f64, 48), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, 0), s.state().cycles);
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=20\nPOWER_SUPPLY_ENERGY_FULL=-1\nPOWER_SUPPLY_ENERGY_FULL_DESIGN=0\nPOWER_SUPPLY_CYCLE_COUNT=-1\n");
    try std.testing.expectEqual(@as(?u8, null), s.state().health);
    try std.testing.expectEqual(@as(?f64, null), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, null), s.state().cycles);
}
