//! The theme parsers' syscall policy, loaded by `native.c` in the disposable
//! child after its filesystem policy: no socket may be created or connected.
//! Everything else is allowed; Landlock and the memory limit confine the rest.
const std = @import("std");
const seccomp = @import("platform").seccomp;

pub fn program(buf: []seccomp.Insn) seccomp.Builder.Error![]const seccomp.Insn {
    var b = try seccomp.Builder.init(buf);
    try b.rule(seccomp.number("socket").?, seccomp.errno(.PERM));
    try b.rule(seccomp.number("connect").?, seccomp.errno(.PERM));
    return b.finish(seccomp.allow);
}

/// Called by `native.c` once the filesystem policy is in place: 0 or -1.
export fn rediwm_theme_syscall_policy() c_int {
    var buf: [32]seccomp.Insn = undefined;
    const filter = program(&buf) catch return -1;
    seccomp.install(filter) catch return -1;
    return 0;
}

fn call(nr: u32, arch: u32) std.os.linux.SECCOMP.data {
    return .{
        .nr = @bitCast(nr),
        .arch = arch,
        .instruction_pointer = 0,
        .arg0 = 0,
        .arg1 = 0,
        .arg2 = 0,
        .arg3 = 0,
        .arg4 = 0,
        .arg5 = 0,
    };
}

test "sockets are refused, other calls pass, foreign ABIs are killed" {
    var buf: [32]seccomp.Insn = undefined;
    const p = try program(&buf);
    const native = seccomp.audit_arch;
    for ([_]u32{ seccomp.number("socket").?, seccomp.number("connect").? }) |nr| {
        try std.testing.expectEqual(seccomp.errno(.PERM), seccomp.evaluate(p, call(nr, native)));
    }
    for ([_]u32{ seccomp.number("read").?, seccomp.number("openat").?, seccomp.number("mmap").?, seccomp.number("socketpair").? }) |nr| {
        try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(nr, native)));
    }
    try std.testing.expectEqual(seccomp.kill_process, seccomp.evaluate(p, call(seccomp.number("read").?, native ^ 1)));
}
