//! Files' device list: which of UDisks2's volumes the sidebar shows and how it
//! names them, over the GLib thread in volumes.c (which only transports).
//!
//! A volume stays listed while its device is attached, mounted or not, so
//! ejecting (unmounting) one leaves it there to mount again.
const std = @import("std");
const c = @cImport({
    @cInclude("volumes.h");
});

pub const Kind = enum {
    /// Flash media: USB sticks and memory cards.
    stick,
    /// Everything else, including an SSD in a USB enclosure.
    drive,
};

pub const Volume = struct {
    /// UDisks2 object path: what `Monitor.mount` and `unmount` take.
    id: []const u8,
    /// The filesystem label or the device's own name; empty when it has neither.
    label: []const u8,
    /// Where it is mounted, or null.
    mount: ?[]const u8,
    size: u64,
    kind: Kind,
};

/// The mount points a user's own mounts land in. System volumes mounted
/// anywhere else (/, /home, /boot) are not the user's to browse as devices.
const user_roots = [_][]const u8{ "/run/media/", "/media/", "/mnt/" };

fn text(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

fn inUserRoot(path: []const u8) bool {
    for (user_roots) |root| if (std.mem.startsWith(u8, path, root)) return true;
    return false;
}

/// Whether the sidebar lists this volume. UDisks2's own `HintIgnore` already
/// covers EFI system partitions, loop helpers and the like.
pub fn shown(record: *const c.vol_record) bool {
    if (record.hint_ignore != 0) return false;
    const mount = text(&record.mount);
    return !(record.hint_system != 0 and mount.len > 0 and !inUserRoot(mount));
}

pub fn kindOf(record: *const c.vol_record) Kind {
    if (record.optical != 0) return .drive;
    return if (record.removable != 0 or std.mem.startsWith(u8, text(&record.media), "flash")) .stick else .drive;
}

/// Null for volumes that are not listed. Strings are copied into `arena`.
pub fn classify(arena: std.mem.Allocator, record: *const c.vol_record) !?Volume {
    if (!shown(record)) return null;
    const label = if (text(&record.label).len > 0) text(&record.label) else text(&record.hint_name);
    const mount = text(&record.mount);
    return .{
        .id = try arena.dupe(u8, text(&record.object)),
        .label = try arena.dupe(u8, label),
        .mount = if (mount.len > 0) try arena.dupe(u8, mount) else null,
        .size = record.size,
        .kind = kindOf(record),
    };
}

/// Whether `path` is the mount point or inside it.
pub fn contains(mount: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, mount)) return false;
    return path.len == mount.len or path[mount.len] == '/' or std.mem.endsWith(u8, mount, "/");
}

/// More than this is not a sidebar's worth (and the hover keys stop at 100).
const max_listed = 32;

/// What the sidebar draws, replaced wholesale on every change.
pub const List = struct {
    arena: ?std.heap.ArenaAllocator = null,
    items: []const Volume = &.{},

    pub fn deinit(self: *List) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn replace(self: *List, allocator: std.mem.Allocator, records: []const c.vol_record) !void {
        var next = std.heap.ArenaAllocator.init(allocator);
        errdefer next.deinit();
        var items: std.ArrayList(Volume) = .empty;
        for (records) |*record| {
            if (items.items.len == max_listed) break;
            if (try classify(next.allocator(), record)) |volume| try items.append(next.allocator(), volume);
        }
        // `/dev` order, so rows keep their place as others come and go.
        std.mem.sort(Volume, items.items, {}, struct {
            fn less(_: void, a: Volume, b: Volume) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.less);
        if (self.arena) |*old| old.deinit();
        self.arena = next;
        self.items = items.items;
    }

    pub fn find(self: *const List, id: []const u8) ?*const Volume {
        for (self.items) |*volume| if (std.mem.eql(u8, volume.id, id)) return volume;
        return null;
    }
};

/// Whether the environment turns the device list off, as the tests do so a
/// host's own disks never appear in a screenshot.
pub fn disabled(environ: std.process.Environ) bool {
    const value = environ.getPosix("REDIWM_FILES_DEVICES") orelse return false;
    return std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "false");
}

pub const Result = c.vol_result;

pub fn resultId(result: *const Result) []const u8 {
    return text(&result.object);
}

pub fn resultPath(result: *const Result) []const u8 {
    return text(&result.path);
}

/// The status line for a failed mount or unmount of `name`.
pub fn failureMessage(buf: []u8, result: *const Result, name: []const u8) []const u8 {
    const code = text(&result.code);
    const verb = if (result.unmount != 0) "eject" else "mount";
    const message = if (std.mem.endsWith(u8, code, ".DeviceBusy"))
        std.fmt.bufPrint(buf, "{s} is busy", .{name})
    else if (std.mem.endsWith(u8, code, ".NotAuthorizedDismissed") or std.mem.endsWith(u8, code, ".Cancelled"))
        std.fmt.bufPrint(buf, "Cancelled", .{})
    else if (std.mem.indexOf(u8, code, ".NotAuthorized") != null)
        std.fmt.bufPrint(buf, "Not authorized to {s} {s}", .{ verb, name })
    else if (std.mem.endsWith(u8, code, ".Gone"))
        std.fmt.bufPrint(buf, "{s} is no longer available", .{name})
    else if (std.mem.endsWith(u8, code, ".AlreadyMounted"))
        std.fmt.bufPrint(buf, "{s} is already mounted", .{name})
    else
        std.fmt.bufPrint(buf, "Could not {s} {s}", .{ verb, name });
    return message catch "Could not use the device";
}

/// The GLib thread. Created once, after the window exists.
pub const Monitor = struct {
    handle: *c.vol_monitor,

    pub fn start() ?Monitor {
        return .{ .handle = c.vol_start() orelse return null };
    }

    /// Ends the thread without waiting for it; the monitor is unusable after.
    pub fn stop(self: Monitor) void {
        c.vol_stop(self.handle);
    }

    /// Readable when `take` or `nextResult` has something.
    pub fn wakeFd(self: Monitor) c_int {
        return c.vol_wake_fd(self.handle);
    }

    pub fn clearWake(self: Monitor) void {
        c.vol_clear_wake(self.handle);
    }

    /// Updates `list` if the volumes changed since the last call; true if so.
    pub fn take(self: Monitor, allocator: std.mem.Allocator, list: *List) !bool {
        var records: [*c]c.vol_record = null;
        var count: usize = 0;
        if (c.vol_take(self.handle, &records, &count) == 0) return false;
        defer std.c.free(records);
        try list.replace(allocator, if (count == 0) &.{} else records[0..count]);
        return true;
    }

    pub fn mount(self: Monitor, id: []const u8) void {
        var buf: [160]u8 = undefined;
        if (id.len >= buf.len) return;
        @memcpy(buf[0..id.len], id);
        buf[id.len] = 0;
        c.vol_mount(self.handle, &buf);
    }

    pub fn unmount(self: Monitor, id: []const u8) void {
        var buf: [160]u8 = undefined;
        if (id.len >= buf.len) return;
        @memcpy(buf[0..id.len], id);
        buf[id.len] = 0;
        c.vol_unmount(self.handle, &buf);
    }

    pub fn nextResult(self: Monitor) ?Result {
        var result: Result = undefined;
        return if (c.vol_next_result(self.handle, &result) != 0) result else null;
    }
};

fn testRecord(object: []const u8) c.vol_record {
    var record = std.mem.zeroes(c.vol_record);
    set(&record.object, object);
    return record;
}

fn set(field: []u8, value: []const u8) void {
    @memcpy(field[0..value.len], value);
}

test "volumes: UDisks2's ignore hint and system mounts are not listed" {
    var record = testRecord("/org/freedesktop/UDisks2/block_devices/nvme0n1p1");
    try std.testing.expect(shown(&record));
    record.hint_ignore = 1;
    try std.testing.expect(!shown(&record));

    record.hint_ignore = 0;
    record.hint_system = 1;
    // An internal partition nobody mounted is still a place to go.
    try std.testing.expect(shown(&record));
    set(&record.mount, "/home");
    try std.testing.expect(!shown(&record));
    set(&record.mount, "/run/media/user/DATA");
    try std.testing.expect(shown(&record));
    record.hint_system = 0;
    set(&record.mount, "/home");
    try std.testing.expect(shown(&record));
}

test "volumes: flash media get the stick, everything else the drive" {
    var record = testRecord("/org/freedesktop/UDisks2/block_devices/sdb1");
    try std.testing.expectEqual(Kind.drive, kindOf(&record));
    record.removable = 1;
    try std.testing.expectEqual(Kind.stick, kindOf(&record));
    record.optical = 1;
    try std.testing.expectEqual(Kind.drive, kindOf(&record));
    record.optical = 0;
    record.removable = 0;
    set(&record.bus, "usb");
    try std.testing.expectEqual(Kind.drive, kindOf(&record)); // A USB SSD.
    set(&record.media, "flash_sd");
    try std.testing.expectEqual(Kind.stick, kindOf(&record));
}

test "volumes: the list is sorted, labelled and replaced whole" {
    var list: List = .{};
    defer list.deinit();
    var b = testRecord("/org/freedesktop/UDisks2/block_devices/sdb1");
    set(&b.label, "BACKUP");
    set(&b.mount, "/run/media/user/BACKUP");
    b.size = 1 << 30;
    var a = testRecord("/org/freedesktop/UDisks2/block_devices/sda1");
    set(&a.hint_name, "Scratch");
    var hidden = testRecord("/org/freedesktop/UDisks2/block_devices/sdc1");
    hidden.hint_ignore = 1;
    try list.replace(std.testing.allocator, &.{ b, hidden, a });
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("Scratch", list.items[0].label);
    try std.testing.expectEqual(@as(?[]const u8, null), list.items[0].mount);
    try std.testing.expectEqualStrings("BACKUP", list.items[1].label);
    try std.testing.expectEqualStrings("/run/media/user/BACKUP", list.items[1].mount.?);
    try std.testing.expect(list.find("/org/freedesktop/UDisks2/block_devices/sdb1") != null);
    try std.testing.expect(list.find("/org/freedesktop/UDisks2/block_devices/sdc1") == null);

    try list.replace(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "volumes: a path is inside a mount only at a directory boundary" {
    try std.testing.expect(contains("/run/media/user/A", "/run/media/user/A"));
    try std.testing.expect(contains("/run/media/user/A", "/run/media/user/A/photos"));
    try std.testing.expect(!contains("/run/media/user/A", "/run/media/user/AB"));
    try std.testing.expect(!contains("/run/media/user/A", "/run/media/alex"));
}

test "volumes: failures read as sentences" {
    var buf: [128]u8 = undefined;
    var result = std.mem.zeroes(Result);
    set(&result.code, "org.freedesktop.UDisks2.Error.DeviceBusy");
    result.unmount = 1;
    try std.testing.expectEqualStrings("BACKUP is busy", failureMessage(&buf, &result, "BACKUP"));
    set(&result.code, "org.freedesktop.UDisks2.Error.NotAuthorized");
    try std.testing.expectEqualStrings("Not authorized to eject BACKUP", failureMessage(&buf, &result, "BACKUP"));
    result.code = std.mem.zeroes(@TypeOf(result.code));
    result.unmount = 0;
    try std.testing.expectEqualStrings("Could not mount BACKUP", failureMessage(&buf, &result, "BACKUP"));
}
