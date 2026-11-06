//! Reading a directory and examining its entries, for the Files folder-size
//! walk. Linux reads with `getdents64` into a buffer the caller reuses and
//! examines with `statx`; FreeBSD reads with `fdopendir`/`readdir` and
//! examines with `fstatat`. An entry is never followed if it is a link.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd)
        @compileError("platform.dirwalk is not ported to this OS yet (docs/plans/freebsd.md, phase 1)");
}

pub const Kind = enum { directory, regular, other };

pub const Entry = struct {
    size: u64,
    nlink: u64,
    ino: u64,
    /// Equal for entries on the same file system.
    dev: u64,
    kind: Kind,
    /// The root of a mounted file system. Linux says so even for a second
    /// mount of the same device; FreeBSD has only the device to compare.
    mount_root: bool,
};

/// Alignment of the buffer given to `Reader.init`.
pub const buffer_align = @alignOf(u64);

pub const ReadError = error{
    /// The directory was removed or its descriptor closed while it was read.
    Gone,
    Failed,
};

/// The entries of one open directory, without "." and "..". A name is valid
/// until the next call.
pub const Reader = if (builtin.os.tag == .linux) LinuxReader else FreebsdReader;

const LinuxReader = struct {
    fd: c_int,
    buf: []align(buffer_align) u8,
    pos: usize = 0,
    len: usize = 0,

    /// Reads into `buf` (a few KiB at least); `fd` stays the caller's.
    pub fn init(fd: c_int, buf: []align(buffer_align) u8) ReadError!LinuxReader {
        return .{ .fd = fd, .buf = buf };
    }

    pub fn deinit(_: *LinuxReader) void {}

    pub fn next(self: *LinuxReader) ReadError!?[*:0]const u8 {
        while (true) {
            if (self.pos >= self.len) {
                const rc = linux.getdents64(self.fd, self.buf.ptr, @intCast(self.buf.len));
                switch (linux.errno(rc)) {
                    .SUCCESS => {},
                    .NOENT, .BADF => return error.Gone,
                    else => return error.Failed,
                }
                if (rc == 0) return null;
                self.pos = 0;
                self.len = rc;
            }
            const d: *const linux.dirent64 = @ptrCast(@alignCast(&self.buf[self.pos]));
            self.pos += d.reclen;
            const name: [*:0]const u8 = @ptrCast(&d.name);
            if (!isDot(name)) return name;
        }
    }
};

const FreebsdReader = struct {
    dir: *std.c.DIR,

    /// `buf` is not used. `fdopendir` owns the descriptor it is given, so it
    /// gets a copy and `fd` stays the caller's.
    pub fn init(fd: c_int, _: []align(buffer_align) u8) ReadError!FreebsdReader {
        const copy = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (copy < 0) return error.Failed;
        const dir = std.c.fdopendir(copy) orelse {
            _ = std.c.close(copy);
            return error.Failed;
        };
        return .{ .dir = dir };
    }

    pub fn deinit(self: *FreebsdReader) void {
        _ = std.c.closedir(self.dir);
    }

    pub fn next(self: *FreebsdReader) ReadError!?[*:0]const u8 {
        while (true) {
            // readdir returns null at the end and on an error; only errno tells.
            std.c._errno().* = 0;
            const entry = std.c.readdir(self.dir) orelse {
                const err = std.c._errno().*;
                if (err == 0) return null;
                if (err == @backingInt(std.c.E.NOENT) or err == @backingInt(std.c.E.BADF)) return error.Gone;
                return error.Failed;
            };
            const name: [*:0]const u8 = @ptrCast(&entry.name);
            if (!isDot(name)) return name;
        }
    }
};

fn isDot(name: [*:0]const u8) bool {
    const text = std.mem.span(name);
    return std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..");
}

/// `name` in the directory `dir_fd`, or null if it cannot be examined.
pub fn statAt(dir_fd: c_int, name: [*:0]const u8) ?Entry {
    return switch (builtin.os.tag) {
        .linux => linuxStat(dir_fd, name, linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT),
        .freebsd => freebsdStat(dir_fd, name),
        else => unreachable,
    };
}

/// What an open descriptor names.
pub fn statFd(fd: c_int) ?Entry {
    return switch (builtin.os.tag) {
        .linux => linuxStat(fd, "", linux.AT.EMPTY_PATH),
        .freebsd => freebsdStatFd(fd),
        else => unreachable,
    };
}

/// `STATX_ATTR_MOUNT_ROOT`, which the build's headers may not name.
const statx_attr_mount_root: u64 = 0x2000;

fn linuxStat(dir_fd: c_int, name: [*:0]const u8, flags: u32) ?Entry {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dir_fd, name, flags | linux.AT.STATX_DONT_SYNC, linux.STATX{ .SIZE = true, .NLINK = true, .INO = true, .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    const type_bits = stx.mode & linux.S.IFMT;
    return .{
        .size = stx.size,
        .nlink = stx.nlink,
        .ino = stx.ino,
        .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
        .kind = if (type_bits == linux.S.IFDIR) .directory else if (type_bits == linux.S.IFREG) .regular else .other,
        .mount_root = @as(u64, @bitCast(stx.attributes)) & statx_attr_mount_root != 0,
    };
}

fn freebsdStat(dir_fd: c_int, name: [*:0]const u8) ?Entry {
    var info: std.c.Stat = undefined;
    if (std.c.fstatat(dir_fd, name, &info, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return freebsdEntry(&info);
}

fn freebsdStatFd(fd: c_int) ?Entry {
    var info: std.c.Stat = undefined;
    if (std.c.fstat(fd, &info) != 0) return null;
    return freebsdEntry(&info);
}

fn freebsdEntry(info: *const std.c.Stat) Entry {
    const type_bits = info.mode & std.posix.S.IFMT;
    return .{
        .size = @intCast(@max(info.size, 0)),
        .nlink = @intCast(info.nlink),
        .ino = @intCast(info.ino),
        .dev = @intCast(info.dev),
        .kind = if (type_bits == std.posix.S.IFDIR) .directory else if (type_bits == std.posix.S.IFREG) .regular else .other,
        .mount_root = false,
    };
}
