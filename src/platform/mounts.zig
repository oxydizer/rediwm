//! Which mount a path is on, for naming a filesystem Files waits on
//! ("Waiting for <mount>…"). Linux reads `/proc/self/mountinfo`, which the
//! kernel answers from memory: it never waits on the mounts it lists, so a dead
//! network mount cannot hang the reader. Other systems report no mount table.
//! `diskOf` finds the disk behind a filesystem in `/sys` (also in memory).
const std = @import("std");
const builtin = @import("builtin");

pub const Mount = struct {
    /// Owned by the caller.
    point: []u8,
    /// No block device behind it (device major 0): a network, FUSE or
    /// virtual filesystem, each of which has a device number of its own.
    anonymous: bool,
};

/// The mount that contains `path` (absolute, no `..`), or null when there is
/// no mount table.
pub fn mountOf(allocator: std.mem.Allocator, path: []const u8) !?Mount {
    var table = Table.load(allocator) orelse return null;
    defer table.deinit();
    var scratch: [4096]u8 = undefined;
    const found = table.find(path, &scratch) orelse return null;
    return .{ .point = try allocator.dupe(u8, found.point), .anonymous = found.anonymous };
}

/// The mount table as read once, for matching many paths against it.
pub const Table = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    /// Null when the system has no mount table or it cannot be read.
    pub fn load(allocator: std.mem.Allocator) ?Table {
        switch (builtin.os.tag) {
            .linux => {
                const bytes = readMountinfo(allocator) catch return null;
                return .{ .allocator = allocator, .bytes = bytes };
            },
            else => return null,
        }
    }

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    /// The mount containing `path`; `point` lives in `scratch`.
    pub fn find(self: *const Table, path: []const u8, scratch: []u8) ?Borrowed {
        const found = containingMount(self.bytes, path) orelse return null;
        return .{ .point = unescapeInto(scratch, found.point) orelse return null, .anonymous = found.anonymous };
    }
};

pub const Borrowed = struct { point: []const u8, anonymous: bool };

/// The disk a filesystem lives on, for limiting how much runs on it at once
/// (worker-pools §4.4).
pub const Disk = struct {
    /// The whole disk's device number (`major << 32 | minor`): partitions,
    /// btrfs subvolumes and a FUSE filesystem on the disk share it.
    key: u64,
    /// Spinning or attached over USB: parallel writes make it slower. A
    /// virtio disk's rotational flag says nothing about what backs it, so it
    /// is not taken as spinning.
    serial: bool,
};

/// The disk behind the filesystem with device number `st_dev` (as `stat`
/// returns it), or null for a network or virtual filesystem, or when the
/// system has no such table (Linux reads `/proc/self/mountinfo` and `/sys`,
/// both answered from memory).
pub fn diskOf(st_dev: u64) ?Disk {
    switch (builtin.os.tag) {
        .linux => {},
        else => return null,
    }
    const major = ((st_dev >> 8) & 0xfff) | ((st_dev >> 32) & ~@as(u64, 0xfff));
    const minor = (st_dev & 0xff) | ((st_dev >> 12) & ~@as(u64, 0xff));
    var block_major = major;
    var block_minor = minor;
    if (major == 0) {
        // Anonymous: btrfs subvolume, FUSE filesystem or network mount. Its
        // mountinfo line names the block device it sits on, if any.
        const table = readMountinfo(std.heap.page_allocator) catch return null;
        defer std.heap.page_allocator.free(table);
        var want: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&want, "{d}:{d}", .{ major, minor }) catch return null;
        const source = mountSource(table, id) orelse return null;
        if (!std.mem.startsWith(u8, source, "/dev/")) return null;
        var path: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&path, "{s}", .{source}, 0) catch return null;
        const linux = std.os.linux;
        var info: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &info)) != .SUCCESS) return null;
        block_major = info.rdev_major;
        block_minor = info.rdev_minor;
    }
    var link: [64]u8 = undefined;
    const sys = std.fmt.bufPrintSentinel(&link, "/sys/dev/block/{d}:{d}", .{ block_major, block_minor }, 0) catch return null;
    var real_buf: [4096]u8 = undefined;
    const real_z = std.c.realpath(sys, &real_buf) orelse return null;
    var real: []const u8 = std.mem.span(real_z);
    // A partition's directory sits inside its disk's.
    var probe: [4200]u8 = undefined;
    const partition = std.fmt.bufPrintSentinel(&probe, "{s}/partition", .{real}, 0) catch return null;
    if (std.c.access(partition, 0) == 0) real = std.fs.path.dirname(real) orelse return null;

    var text: [32]u8 = undefined;
    const dev_text = readSmall(&probe, real, "dev", &text) orelse return null;
    const colon = std.mem.indexOfScalar(u8, dev_text, ':') orelse return null;
    const disk_major = std.fmt.parseInt(u64, dev_text[0..colon], 10) catch return null;
    const disk_minor = std.fmt.parseInt(u64, dev_text[colon + 1 ..], 10) catch return null;
    var rot: [8]u8 = undefined;
    const rotational = if (readSmall(&probe, real, "queue/rotational", &rot)) |value| std.mem.eql(u8, value, "1") else false;
    const usb = std.mem.indexOf(u8, real, "/usb") != null;
    // A virtual machine's virtio disk reports rotational whatever backs it.
    const virtio = std.mem.indexOf(u8, real, "/virtio") != null;
    return .{ .key = disk_major << 32 | disk_minor, .serial = usb or (rotational and !virtio) };
}

/// The source of the mountinfo line whose device is `id` ("0:41").
fn mountSource(mountinfo: []const u8, id: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const device = fields.next() orelse continue;
        if (!std.mem.eql(u8, device, id)) continue;
        const dash = std.mem.indexOf(u8, line, " - ") orelse return null;
        var tail = std.mem.splitScalar(u8, line[dash + 3 ..], ' ');
        _ = tail.next() orelse return null; // filesystem type
        return tail.next();
    }
    return null;
}

/// A short sysfs attribute, trimmed.
fn readSmall(path_buf: []u8, dir: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    const path = std.fmt.bufPrintSentinel(path_buf, "{s}/{s}", .{ dir, name }, 0) catch return null;
    const system = std.posix.system;
    const fd = system.open(path, .{ .CLOEXEC = true }, @as(std.posix.mode_t, 0));
    if (fd < 0) return null;
    defer _ = system.close(fd);
    const rc = system.read(fd, out.ptr, out.len);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return std.mem.trim(u8, out[0..@intCast(rc)], " \n");
}

fn readMountinfo(allocator: std.mem.Allocator) ![]u8 {
    const system = std.posix.system;
    const fd = system.open("/proc/self/mountinfo", .{ .CLOEXEC = true }, @as(std.posix.mode_t, 0));
    if (fd < 0) return error.Unavailable;
    defer _ = system.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (out.items.len < 4 << 20) {
        const rc = system.read(fd, &buf, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unavailable,
        }
        if (rc == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(rc)]);
    }
    return out.toOwnedSlice(allocator);
}

const Found = struct { point: []const u8, anonymous: bool };

/// The longest mount point in `mountinfo` (still escaped) that contains
/// `path` at a component boundary.
fn containingMount(mountinfo: []const u8, path: []const u8) ?Found {
    var best: ?Found = null;
    var best_len: usize = 0;
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        // id parent major:minor root mount-point ...
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const device = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const point = fields.next() orelse continue;
        if (point.len == 0 or point[0] != '/') continue;
        var scratch: [4096]u8 = undefined;
        const plain = unescapeInto(&scratch, point) orelse continue;
        if (!contains(plain, path) or plain.len < best_len) continue;
        best = .{ .point = point, .anonymous = std.mem.startsWith(u8, device, "0:") };
        best_len = plain.len;
    }
    return best;
}

fn contains(mount: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, mount, "/")) return path.len > 0 and path[0] == '/';
    return std.mem.startsWith(u8, path, mount) and (path.len == mount.len or path[mount.len] == '/');
}

/// mountinfo escapes space, tab, newline and backslash as `\ooo`.
fn unescapeInto(out: []u8, text: []const u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (len += 1) {
        if (len == out.len) return null;
        if (text[i] == '\\' and i + 4 <= text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 4], 8)) |byte| {
                out[len] = byte;
                i += 4;
                continue;
            } else |_| {}
        }
        out[len] = text[i];
        i += 1;
    }
    return out[0..len];
}

fn unescape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var scratch: [4096]u8 = undefined;
    return allocator.dupe(u8, unescapeInto(&scratch, text) orelse return error.NameTooLong);
}

test "a table finds what the one-shot lookup finds" {
    const bytes = try std.testing.allocator.dupe(u8, "22 1 8:2 / / rw - ext4 /dev/sda2 rw\n30 22 0:40 / /mnt/nas rw - nfs4 s:/ rw\n");
    var table: Table = .{ .allocator = std.testing.allocator, .bytes = bytes };
    defer table.deinit();
    var scratch: [64]u8 = undefined;
    const nas = table.find("/mnt/nas/x", &scratch).?;
    try std.testing.expectEqualStrings("/mnt/nas", nas.point);
    try std.testing.expect(nas.anonymous);
}

test "the longest containing mount wins, at component boundaries, escapes undone" {
    const table =
        \\22 1 8:2 / / rw - ext4 /dev/sda2 rw
        \\30 22 0:40 / /mnt/net rw - nfs4 server:/ rw
        \\31 22 8:17 / /run/media/u/USB\040STICK rw - vfat /dev/sdb1 rw
        \\32 22 0:41 / /mnt/netbook rw - fuse.sshfs h: rw
    ;
    const net = containingMount(table, "/mnt/net/a/b").?;
    try std.testing.expectEqualStrings("/mnt/net", net.point);
    try std.testing.expect(net.anonymous);
    try std.testing.expectEqualStrings("/mnt/net", containingMount(table, "/mnt/net").?.point);
    try std.testing.expectEqualStrings("/mnt/netbook", containingMount(table, "/mnt/netbook/x").?.point);
    try std.testing.expect(!containingMount(table, "/home/u").?.anonymous);
    try std.testing.expectEqualStrings("/", containingMount(table, "/home/u").?.point);
    const usb = containingMount(table, "/run/media/u/USB STICK/photos").?.point;
    const name = try unescape(std.testing.allocator, usb);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("/run/media/u/USB STICK", name);
}

test "the source of a mountinfo line" {
    const table =
        \\22 1 8:2 / / rw - ext4 /dev/sda2 rw
        \\32 22 0:41 / /mnt/usb rw - fuseblk /dev/sdb1 rw
        \\33 22 0:42 / /mnt/nas rw - nfs4 server:/share rw
    ;
    try std.testing.expectEqualStrings("/dev/sdb1", mountSource(table, "0:41").?);
    try std.testing.expectEqualStrings("server:/share", mountSource(table, "0:42").?);
    try std.testing.expect(mountSource(table, "0:9") == null);
}

/// `st_dev` as glibc encodes it, from a major and minor number.
fn makedev(major: u64, minor: u64) u64 {
    return ((major & 0xfffff000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffffff00) << 12) | (minor & 0xff);
}

test "the root filesystem's disk is found without failing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const info = @import("fs.zig").stat("/") orelse return error.SkipZigTest;
    // Containers may have no block device behind `/`: then null.
    if (diskOf(makedev(info.dev >> 32, info.dev & 0xffffffff))) |disk| try std.testing.expect(disk.key != 0);
    // A network-like anonymous device with no line resolves to nothing.
    try std.testing.expect(diskOf(makedev(0, 999_999)) == null);
}
