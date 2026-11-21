//! Where the system's own helper programs live. Distro packages put them in
//! `/usr/bin` (`/bin` before the /usr merge), ports in `/usr/local/bin`.
const std = @import("std");

/// The directories searched, in order. Root-owned on every supported system.
const system_dirs = [_][]const u8{ "/usr/bin", "/bin", "/usr/local/bin" };

/// Programs a system without systemd as PID 1 replaces. RediOS under redinit
/// installs init-aware wrappers in `/usr/local/bin`, because the real tools
/// refuse to run there ("System has not been booted with systemd"). Under
/// systemd the wrappers hand over to the real tool, so preferring them is safe.
const init_aware = [_][]const u8{ "systemctl", "loginctl", "journalctl" };
const local_first_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };

/// Is `name` one of the programs the init system may stand in for?
pub fn isInitAware(comptime name: []const u8) bool {
    inline for (init_aware) |known| if (std.mem.eql(u8, name, known)) return true;
    return false;
}

/// The directories searched for `name`, in order. An init-aware program looks in
/// `/usr/local/bin` first (still a root-owned directory, still never `PATH`).
pub fn searchDirs(comptime name: []const u8) []const []const u8 {
    return if (comptime isInitAware(name)) &local_first_dirs else &system_dirs;
}

/// `name` in the system directories, never on `PATH`: for programs that run
/// as root or are handed a secret (`pkexec`, `systemctl`), where a
/// user-writable `PATH` entry must not win. Null when none is executable.
pub fn system(io: std.Io, comptime name: []const u8) ?[:0]const u8 {
    inline for (comptime searchDirs(name)) |dir| {
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

test "init-aware programs prefer the wrapper in /usr/local/bin" {
    // A real systemctl in /usr/bin must never win over the wrapper: under redinit
    // it exits with "System has not been booted with systemd".
    inline for (.{ "systemctl", "loginctl", "journalctl" }) |name| {
        const dirs = searchDirs(name);
        try std.testing.expectEqualStrings("/usr/local/bin", dirs[0]);
        try std.testing.expectEqualStrings("/usr/bin", dirs[1]);
    }
    // Everything else keeps the distribution first, so a port cannot shadow it.
    inline for (.{ "pkexec", "ssh-keygen", "gio" }) |name| {
        try std.testing.expectEqualStrings("/usr/bin", searchDirs(name)[0]);
        try std.testing.expect(!isInitAware(name));
    }
}
