//! Where the system's own helper programs live. Distro packages put them in
//! `/usr/bin` (`/bin` before the /usr merge), ports in `/usr/local/bin`.
const std = @import("std");

/// The directories searched, in order. Root-owned on every supported system.
const system_dirs = [_][]const u8{ "/usr/bin", "/bin", "/usr/local/bin" };

/// `name` in the system directories, never on `PATH`: for programs that run
/// as root or are handed a secret (`pkexec`, `systemctl`), where a
/// user-writable `PATH` entry must not win. Null when none is executable.
pub fn system(io: std.Io, comptime name: []const u8) ?[:0]const u8 {
    inline for (system_dirs) |dir| {
        const path = dir ++ "/" ++ name;
        if (std.Io.Dir.accessAbsolute(io, path, .{ .execute = true })) |_| return path else |_| {}
    }
    return null;
}

test "system programs come from the system directories" {
    const sh = system(std.testing.io, "sh").?;
    try std.testing.expect(std.mem.endsWith(u8, sh, "/sh"));
    try std.testing.expect(std.fs.path.isAbsolute(sh));
    try std.testing.expectEqual(@as(?[:0]const u8, null), system(std.testing.io, "rediwm-no-such-program"));
}
