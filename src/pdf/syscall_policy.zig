//! The PDF parser's syscall policy, loaded by `sandbox.c` after the filesystem
//! policy. File opens are checked by Landlock. No exec, fork, socket/connect,
//! ptrace, process_vm_*, pidfd, io_uring, BPF, keyring, mount or general
//! ioctl/prctl is allowed. Unsupported and new syscalls are denied as well.
const std = @import("std");
const linux = std.os.linux;
const seccomp = @import("platform").seccomp;

const allowed = [_][]const u8{
    "read",            "write",          "readv",         "writev",
    "pread64",         "lseek",          "close",         "dup",
    "dup3",            "openat",         "fstat",         "fstatfs",
    "newfstatat",      "statx",          "faccessat",     "faccessat2",
    "readlinkat",      "getdents64",     "mmap",          "mprotect",
    "munmap",          "mremap",         "madvise",       "brk",
    "mlock",           "munlock",        "futex",         "futex_waitv",
    "set_robust_list", "rseq",           "sched_yield",   "sched_getaffinity",
    "rt_sigaction",    "rt_sigprocmask", "rt_sigreturn",  "sigaltstack",
    "getpid",          "gettid",         "getuid",        "geteuid",
    "getgid",          "getegid",        "clock_gettime", "gettimeofday",
    "clock_nanosleep", "nanosleep",      "uname",         "getrandom",
    "ppoll",           "pselect6",       "eventfd2",      "pipe2",
    "ftruncate",       "exit",           "exit_group",    "restart_syscall",
};

/// Calls newer architectures dropped; absent there, the default denial stands.
const legacy = [_][]const u8{
    "dup2", "open", "stat", "lstat", "access", "readlink", "poll", "select", "time",
};

const fcntl_commands = [_]u32{
    linux.F.GETFD,         linux.F.SETFD,     linux.F.GETFL,     linux.F.SETFL,
    linux.F.DUPFD_CLOEXEC, linux.F.GET_SEALS, linux.F.ADD_SEALS,
};

/// What a `pthread_create` passes to clone.
const thread_flags: u64 = linux.CLONE.VM | linux.CLONE.FS | linux.CLONE.FILES | linux.CLONE.SIGHAND |
    linux.CLONE.THREAD | linux.CLONE.SYSVSEM | linux.CLONE.SETTLS | linux.CLONE.PARENT_SETTID |
    linux.CLONE.CHILD_CLEARTID;

/// The program for a process `pid` whose only socket is `display`.
pub fn program(buf: []seccomp.Insn, display: u64, pid: u64) seccomp.Builder.Error![]const seccomp.Insn {
    var b = try seccomp.Builder.init(buf);
    inline for (allowed) |name| {
        const nr = comptime seccomp.number(name) orelse @compileError("no syscall " ++ name);
        try b.rule(nr, seccomp.allow);
    }
    inline for (legacy) |name| {
        if (comptime seccomp.number(name)) |nr| try b.rule(nr, seccomp.allow);
    }
    for (fcntl_commands) |command| {
        try b.ruleArg(seccomp.number("fcntl").?, seccomp.allow, .{ .index = 1, .value = command });
    }
    // MFD_CLOEXEC and MFD_ALLOW_SEALING only.
    try b.ruleArg(seccomp.number("memfd_create").?, seccomp.allow, .{ .index = 1, .value = 0, .mask = ~@as(u64, 3) });
    // glibc retries pthread_create with clone when clone3 returns ENOSYS.
    try b.rule(seccomp.number("clone3").?, seccomp.errno(.NOSYS));
    try b.ruleArg(seccomp.number("clone").?, seccomp.allow, .{ .index = 0, .value = thread_flags });
    try b.ruleArg(seccomp.number("tgkill").?, seccomp.allow, .{ .index = 0, .value = pid });
    try b.ruleArg(seccomp.number("sendmsg").?, seccomp.allow, .{ .index = 0, .value = display });
    try b.ruleArg(seccomp.number("recvmsg").?, seccomp.allow, .{ .index = 0, .value = display });
    return b.finish(seccomp.errno(.PERM));
}

fn install(display: c_int) !void {
    var buf: [512]seccomp.Insn = undefined;
    const fd = std.math.cast(u64, display) orelse return error.BadDescriptor;
    const pid = std.math.cast(u64, linux.getpid()) orelse return error.BadDescriptor;
    try seccomp.install(try program(&buf, fd, pid));
}

/// Called by `sandbox.c` once the filesystem policy is in place: 0 or -1.
export fn rediwm_pdf_syscall_policy(display: c_int) c_int {
    install(display) catch return -1;
    return 0;
}

const Call = linux.SECCOMP.data;

fn call(nr: u32, args: [6]u64) Call {
    return .{
        .nr = @bitCast(nr),
        .arch = seccomp.audit_arch,
        .instruction_pointer = 0,
        .arg0 = args[0],
        .arg1 = args[1],
        .arg2 = args[2],
        .arg3 = args[3],
        .arg4 = args[4],
        .arg5 = args[5],
    };
}

test "policy allows the parser's calls and its two descriptors, nothing else" {
    var buf: [512]seccomp.Insn = undefined;
    const display: u64 = 7;
    const pid: u64 = 4242;
    const p = try program(&buf, display, pid);
    const none: [6]u64 = @splat(0);
    const deny = seccomp.errno(.PERM);

    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(seccomp.number("read").?, none)));
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(seccomp.number("futex").?, none)));
    inline for ([_][]const u8{ "socket", "connect", "execve", "ptrace", "io_uring_setup", "pidfd_open", "process_vm_readv", "kill", "ioctl", "prctl" }) |name| {
        try std.testing.expectEqual(deny, seccomp.evaluate(p, call(seccomp.number(name).?, none)));
    }

    const fcntl = seccomp.number("fcntl").?;
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(fcntl, .{ 3, linux.F.ADD_SEALS, 0, 0, 0, 0 })));
    try std.testing.expectEqual(deny, seccomp.evaluate(p, call(fcntl, .{ 3, linux.F.SETOWN, 0, 0, 0, 0 })));

    const memfd = seccomp.number("memfd_create").?;
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(memfd, .{ 0, 3, 0, 0, 0, 0 })));
    try std.testing.expectEqual(deny, seccomp.evaluate(p, call(memfd, .{ 0, 4, 0, 0, 0, 0 })));

    const clone = seccomp.number("clone").?;
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(clone, .{ thread_flags, 0, 0, 0, 0, 0 })));
    try std.testing.expectEqual(deny, seccomp.evaluate(p, call(clone, .{ thread_flags & ~@as(u64, linux.CLONE.VM), 0, 0, 0, 0, 0 })));
    try std.testing.expectEqual(seccomp.errno(.NOSYS), seccomp.evaluate(p, call(seccomp.number("clone3").?, none)));

    const tgkill = seccomp.number("tgkill").?;
    try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(tgkill, .{ pid, 0, 0, 0, 0, 0 })));
    try std.testing.expectEqual(deny, seccomp.evaluate(p, call(tgkill, .{ pid + 1, 0, 0, 0, 0, 0 })));

    // Only the compositor's socket may carry bytes, and only it.
    inline for ([_][]const u8{ "sendmsg", "recvmsg" }) |name| {
        const nr = seccomp.number(name).?;
        try std.testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(nr, .{ display, 0, 0, 0, 0, 0 })));
        try std.testing.expectEqual(deny, seccomp.evaluate(p, call(nr, .{ display + 1, 0, 0, 0, 0, 0 })));
        try std.testing.expectEqual(deny, seccomp.evaluate(p, call(nr, .{ display | (1 << 32), 0, 0, 0, 0, 0 })));
    }
}
