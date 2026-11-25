//! What a file copy does about a destination that already exists, and the
//! times a copy keeps so a later copy can recognise it.
const std = @import("std");
const c = @import("c.zig").api;

/// FAT and exFAT keep modification times to 2 s (and no nanoseconds), so a
/// file copied there reads up to that much apart from its source.
pub const coarse_window_ns: i128 = 2 * std.time.ns_per_s;

pub const Existing = enum {
    /// Nothing has the name: copy.
    none,
    /// A regular file of the same size and modification time: it is this
    /// file already, so the copy is done without writing (rsync's quick check).
    same,
    /// Something else has the name: ask before anything is written.
    other,
};

fn nanoseconds(time: c.struct_timespec) i128 {
    return @as(i128, time.tv_sec) * std.time.ns_per_s + time.tv_nsec;
}

/// Whether `existing` looks like an earlier copy of `source`: a regular file
/// of the same size and the same modification time. The time must match to
/// the nanosecond, except on a filesystem that keeps whole seconds only (no
/// nanoseconds at all), where it may be up to 2 s apart. Two different files
/// written moments apart therefore never pass for each other.
pub fn sameFile(source: c.struct_stat, existing: c.struct_stat) bool {
    if ((existing.st_mode & c.S_IFMT) != c.S_IFREG) return false;
    if (existing.st_size != source.st_size) return false;
    const apart = nanoseconds(existing.st_mtim) - nanoseconds(source.st_mtim);
    if (apart == 0) return true;
    const coarse = existing.st_mtim.tv_nsec == 0 or source.st_mtim.tv_nsec == 0;
    return coarse and @abs(apart) < coarse_window_ns;
}

/// Looks at `name` in `parent_fd` without following a symlink.
pub fn check(parent_fd: c_int, name: [*:0]const u8, source: c.struct_stat) Existing {
    var existing: c.struct_stat = undefined;
    if (c.fstatat(parent_fd, name, &existing, c.AT_SYMLINK_NOFOLLOW) != 0) {
        // Anything but "not there" is left to the copy itself, which then
        // fails or meets the name at publication.
        return .none;
    }
    return if (sameFile(source, existing)) .same else .other;
}

/// Gives the copy its source's access and modification times. Best effort:
/// a filesystem that refuses keeps the copy's own times.
pub fn keepTimes(source_fd: c_int, destination_fd: c_int) void {
    var source: c.struct_stat = undefined;
    if (c.fstat(source_fd, &source) != 0) return;
    const times = [2]c.struct_timespec{ source.st_atim, source.st_mtim };
    _ = c.futimens(destination_fd, &times);
}

fn statWith(size: i64, sec: i64, nsec: i64, kind: c_uint) c.struct_stat {
    var value = std.mem.zeroes(c.struct_stat);
    value.st_mode = kind | 0o644;
    value.st_size = size;
    value.st_mtim = .{ .tv_sec = sec, .tv_nsec = nsec };
    return value;
}

test "a destination of the same size and time is the same file" {
    const source = statWith(4096, 1_700_000_000, 500, c.S_IFREG);
    try std.testing.expect(sameFile(source, source));
    // A coarse filesystem's copy: whole seconds, within 2 s either way.
    try std.testing.expect(sameFile(source, statWith(4096, 1_700_000_001, 0, c.S_IFREG)));
    try std.testing.expect(sameFile(source, statWith(4096, 1_699_999_999, 0, c.S_IFREG)));
    try std.testing.expect(!sameFile(source, statWith(4096, 1_700_000_003, 0, c.S_IFREG)));
    // A fine-grained one must match exactly: a file written a moment later
    // with the same size is another file.
    try std.testing.expect(!sameFile(source, statWith(4096, 1_700_000_000, 501, c.S_IFREG)));
    // Another size, or not a regular file: ask.
    try std.testing.expect(!sameFile(source, statWith(4095, 1_700_000_000, 500, c.S_IFREG)));
    try std.testing.expect(!sameFile(source, statWith(4096, 1_700_000_000, 500, c.S_IFDIR)));
}
