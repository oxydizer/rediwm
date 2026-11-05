//! The running program's own executable, for launching its siblings
//! (`rediwm-files`, `rediwm-pdf`, the Files terminal helper) and itself.
//! Linux reads `/proc/self/exe`, FreeBSD asks `kern.proc.pathname`;
//! `self_exe.h` is the C side.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd)
        @compileError("platform.exe is not ported to this OS yet (docs/plans/freebsd.md, phase 1)");
}

/// Room for any path the callers hand to `std.process.spawn`.
pub const max_path = 4096;

/// The absolute path of the running executable, in `buf`. Null when the link
/// cannot be read or the path does not fit.
pub fn path(buf: []u8) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const rc = linux.readlink("/proc/self/exe", buf.ptr, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0 or rc >= buf.len) return null;
            return buf[0..rc];
        },
        .freebsd => {
            // CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, this process (sys/sysctl.h).
            const mib = [4]c_int{ 1, 14, 12, -1 };
            var len: usize = buf.len;
            if (std.c.sysctl(&mib, 4, buf.ptr, &len, null, 0) != 0) return null;
            // The length counts the terminating NUL.
            if (len < 2 or buf[len - 1] != 0) return null;
            return buf[0 .. len - 1];
        },
        else => unreachable,
    }
}

/// `<directory of this executable>/<name>`, NUL-terminated in `buf`. Null
/// when the executable's path is unknown or the result does not fit.
pub fn sibling(buf: []u8, name: []const u8) ?[:0]const u8 {
    var exe: [max_path]u8 = undefined;
    const dir = std.fs.path.dirname(path(&exe) orelse return null) orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch null;
}

/// The sibling when it exists and is executable, else bare `name`, which the
/// spawner looks up on `PATH`.
pub fn siblingOrName(buf: []u8, name: []const u8) []const u8 {
    const found = sibling(buf, name) orelse return name;
    const accessible = switch (builtin.os.tag) {
        .linux => linux.errno(linux.access(found.ptr, std.posix.X_OK)) == .SUCCESS,
        .freebsd => std.c.access(found.ptr, std.posix.X_OK) == 0,
        else => unreachable,
    };
    return if (accessible) found else name;
}

/// Replaces this process with a fresh copy of the same program image. Returns
/// only when the exec failed; callable between fork and exec (no allocation).
pub fn execSelf(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
    switch (builtin.os.tag) {
        .linux => _ = linux.execve("/proc/self/exe", argv, envp),
        .freebsd => {
            // By path: a program replaced on disk since it started runs as the
            // new image (a descriptor kept from startup would run the old one).
            var buf: [max_path]u8 = undefined;
            const found = path(buf[0 .. max_path - 1]) orelse return;
            buf[found.len] = 0;
            _ = std.c.execve(@ptrCast(&buf), argv, envp);
        },
        else => unreachable,
    }
}

test "own path is absolute and siblings sit beside it" {
    var buf: [max_path]u8 = undefined;
    const self = path(&buf).?;
    try std.testing.expect(std.fs.path.isAbsolute(self));
    var other: [max_path]u8 = undefined;
    const beside = sibling(&other, "rediwm-files").?;
    try std.testing.expectEqualStrings(std.fs.path.dirname(self).?, std.fs.path.dirname(beside).?);
    try std.testing.expectEqualStrings("rediwm-files", std.fs.path.basename(beside));
    // No such sibling: the bare name is left to the spawner's PATH lookup.
    try std.testing.expectEqualStrings("rediwm-no-such-program", siblingOrName(&other, "rediwm-no-such-program"));
    // The test binary itself is an executable sibling.
    try std.testing.expectEqualStrings(self, siblingOrName(&other, std.fs.path.basename(self)));
}
