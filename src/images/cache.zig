//! Recently viewed full-resolution images. Ownership moves; pixels are not copied.
const std = @import("std");
const c = @import("../files/c.zig").api;
const Image = @import("loader.zig").Image;
pub const Stamp = struct {
    device: u64,
    inode: u64,
    size: i64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
    pub fn read(path: [:0]const u8) ?Stamp {
        var st: c.struct_stat = undefined;
        if (c.stat(path, &st) != 0) return null;
        return .{ .device = st.st_dev, .inode = st.st_ino, .size = st.st_size, .mtime = st.st_mtim.tv_sec, .mtime_ns = st.st_mtim.tv_nsec, .ctime = st.st_ctim.tv_sec, .ctime_ns = st.st_ctim.tv_nsec };
    }
};
const Entry = struct { index: usize, image: Image, stamp: Stamp };
pub const Cache = struct {
    entries: [16]?Entry = @splat(null),
    bytes: usize = 0,
    byte_limit: usize = limit,
    pub const limit = 96 * 1024 * 1024;
    pub fn deinit(self: *Cache) void {
        for (0..self.entries.len) |i| self.remove(i);
    }
    fn remove(self: *Cache, i: usize) void {
        if (self.entries[i]) |entry| {
            self.bytes -= entry.image.pixels.len * 4;
            entry.image.deinit();
            self.entries[i] = null;
        }
    }
    pub fn put(self: *Cache, index: usize, image: Image, stamp: ?Stamp) void {
        const size = image.pixels.len * 4;
        if (stamp == null or size > self.byte_limit) {
            image.deinit();
            return;
        }
        for (0..self.entries.len) |i| {
            if (self.entries[i]) |entry| {
                if (entry.index == index) self.remove(i);
            }
        }
        self.remove(self.entries.len - 1);
        var i: usize = self.entries.len - 1;
        while (i > 0) : (i -= 1) self.entries[i] = self.entries[i - 1];
        self.entries[0] = .{ .index = index, .image = image, .stamp = stamp.? };
        self.bytes += size;
        i = self.entries.len;
        while (self.bytes > self.byte_limit and i > 0) {
            i -= 1;
            self.remove(i);
        }
    }
    pub fn take(self: *Cache, index: usize, stamp: ?Stamp) ?Image {
        for (&self.entries, 0..) |*slot, i| {
            const entry = slot.* orelse continue;
            if (entry.index != index) continue;
            if (stamp == null or !std.meta.eql(entry.stamp, stamp.?)) {
                self.remove(i);
                return null;
            }
            const image = entry.image;
            self.bytes -= image.pixels.len * 4;
            slot.* = null;
            return image;
        }
        return null;
    }
    pub fn contains(self: *const Cache, index: usize) bool {
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (entry.index == index) return true;
            }
        }
        return false;
    }
};

test "recent image cache transfers ownership, bounds memory, and rejects changed files" {
    const a = std.heap.c_allocator;
    const stamp = Stamp{ .device = 1, .inode = 1, .size = 8, .mtime = 1, .mtime_ns = 0, .ctime = 1, .ctime_ns = 0 };
    var cache: Cache = .{ .byte_limit = 16 };
    defer cache.deinit();
    for (0..3) |index| {
        const pixels = try a.alloc(u32, 2);
        @memset(pixels, @intCast(index));
        cache.put(index, .{ .pixels = pixels, .w = 2, .h = 1 }, stamp);
    }
    try std.testing.expectEqual(@as(usize, 16), cache.bytes);
    try std.testing.expect(cache.take(0, stamp) == null);
    const image = cache.take(1, stamp).?;
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 1), image.pixels[0]);
    var changed = stamp;
    changed.mtime_ns = 1;
    try std.testing.expect(cache.take(2, changed) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
}
