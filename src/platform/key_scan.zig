//! Read-only metadata scanner policy. Kept here with the other OS interfaces.
const std = @import("std");
const builtin = @import("builtin");
const seccomp = @import("seccomp.zig");
const process = @import("process.zig");

pub fn program(buf: []seccomp.Insn) ![]const seccomp.Insn {
    var b = try seccomp.Builder.init(buf);
    // O_ACCMODE | O_CREAT | O_EXCL | O_TRUNC | O_APPEND | __O_TMPFILE.
    const write_flags: u64 = 3 | 0o100 | 0o200 | 0o1000 | 0o2000 | 0o20000000;
    try b.ruleArg(seccomp.number("openat").?, seccomp.allow, .{ .index = 2, .value = 0, .mask = write_flags });
    if (seccomp.number("open")) |nr| try b.ruleArg(nr, seccomp.allow, .{ .index = 1, .value = 0, .mask = write_flags });
    for ([_]u64{ 1, 2 }) |fd| try b.ruleArg(seccomp.number("write").?, seccomp.allow, .{ .index = 0, .value = fd });
    inline for (.{ "read", "close", "pread64", "lseek", "fstat", "getdents64", "fcntl", "mmap", "mprotect", "munmap", "mremap", "brk", "madvise", "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "clock_gettime", "getpid", "getuid", "geteuid", "futex", "exit", "exit_group" }) |name| try b.rule(seccomp.number(name).?, seccomp.allow);
    inline for (.{ "newfstatat", "statx", "stat", "lstat", "getdents", "futex_time64", "clock_gettime64", "restart_syscall" }) |name| if (seccomp.number(name)) |nr| try b.rule(nr, seccomp.allow);
    return b.finish(seccomp.errno(.PERM));
}
extern "c" fn rediwm_key_scan_capsicum(c_int, c_int) c_int;
pub fn enter(directory: c_int, index: c_int) !void {
    try process.noNewPrivileges();
    if (builtin.os.tag == .linux) {
        var buf: [256]seccomp.Insn = undefined;
        try seccomp.install(try program(&buf));
    } else if (rediwm_key_scan_capsicum(directory, index) != 0) return error.ScannerSandboxUnavailable;
}

test "key scanner denies writes, execution and networking" {
    if (builtin.os.tag != .linux) return;
    var buf: [256]seccomp.Insn = undefined;
    const p = try program(&buf);
    var call: std.os.linux.SECCOMP.data = .{ .nr = 0, .arch = seccomp.audit_arch, .instruction_pointer = 0, .arg0 = 0, .arg1 = 0, .arg2 = 0, .arg3 = 0, .arg4 = 0, .arg5 = 0 };
    inline for (.{ "execve", "execveat", "socket", "connect", "unlink", "unlinkat", "renameat", "fchmod", "clone", "openat2" }) |name| {
        if (seccomp.number(name)) |nr| {
            call.nr = @bitCast(nr);
            try std.testing.expectEqual(seccomp.errno(.PERM), seccomp.evaluate(p, call));
        }
    }
    call.nr = @bitCast(seccomp.number("openat").?);
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call));
    for ([_]u64{ 1, 2, 0o100, 0o1000, 0o20000000 }) |flags| {
        call.arg2 = flags;
        try std.testing.expectEqual(seccomp.errno(.PERM), seccomp.evaluate(p, call));
    }
    call.nr = @bitCast(seccomp.number("write").?);
    for ([_]u64{ 0, 3, 17 }) |fd| {
        call.arg0 = fd;
        try std.testing.expectEqual(seccomp.errno(.PERM), seccomp.evaluate(p, call));
    }
    call.arg0 = 1;
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call));
}
