//! Which mount a path is on, for naming a filesystem Files waits on
//! ("Waiting for <mount>…"). Linux reads `/proc/self/mountinfo`, which the
//! kernel answers from memory: it never waits on the mounts it lists, so a dead
//! network mount cannot hang the reader. Other systems report no mount table.
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
    switch (builtin.os.tag) {
        .linux => {
            const table = readMountinfo(allocator) catch return null;
            defer allocator.free(table);
            const found = containingMount(table, path) orelse return null;
            return .{ .point = try unescape(allocator, found.point), .anonymous = found.anonymous };
        },
        else => return null,
    }
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
