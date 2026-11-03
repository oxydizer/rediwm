const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const seccomp = @import("seccomp.zig");

const testing = std.testing;
const Call = linux.SECCOMP.data;

fn call(nr: u32, arg0: u64, arg1: u64) Call {
    return .{
        .nr = @bitCast(nr),
        .arch = seccomp.audit_arch,
        .instruction_pointer = 0,
        .arg0 = arg0,
        .arg1 = arg1,
        .arg2 = 0,
        .arg3 = 0,
        .arg4 = 0,
        .arg5 = 0,
    };
}

const deny = seccomp.errno(.PERM);

test "listed calls get their action and everything else the default" {
    var buf: [32]seccomp.Insn = undefined;
    var b = try seccomp.Builder.init(&buf);
    try b.rule(10, seccomp.allow);
    try b.rule(11, seccomp.errno(.NOSYS));
    const p = try b.finish(deny);
    try testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(10, 0, 0)));
    try testing.expectEqual(seccomp.errno(.NOSYS), seccomp.evaluate(p, call(11, 0, 0)));
    try testing.expectEqual(deny, seccomp.evaluate(p, call(12, 0, 0)));
}

test "a foreign architecture or an x32 number kills the process" {
    var buf: [32]seccomp.Insn = undefined;
    var b = try seccomp.Builder.init(&buf);
    try b.rule(10, seccomp.allow);
    const p = try b.finish(deny);
    var foreign = call(10, 0, 0);
    foreign.arch = foreign.arch ^ 1;
    try testing.expectEqual(seccomp.kill_process, seccomp.evaluate(p, foreign));
    if (builtin.cpu.arch == .x86_64) {
        try testing.expectEqual(seccomp.kill_process, seccomp.evaluate(p, call(10 | 0x40000000, 0, 0)));
        // A tracer's "skip this call" number is only an unknown call.
        try testing.expectEqual(deny, seccomp.evaluate(p, call(0xffffffff, 0, 0)));
    }
}

test "argument rules compare all 64 bits and fall through to the next rule" {
    var buf: [64]seccomp.Insn = undefined;
    var b = try seccomp.Builder.init(&buf);
    // Alternatives for one syscall, then a plain rule after them: the
    // accumulator must hold the number again after a failed comparison.
    try b.ruleArg(20, seccomp.allow, .{ .index = 1, .value = 5 });
    try b.ruleArg(20, seccomp.allow, .{ .index = 1, .value = 0x1_0000_0006 });
    try b.ruleArg(21, seccomp.allow, .{ .index = 0, .value = 0, .mask = ~@as(u64, 3) });
    try b.rule(22, seccomp.allow);
    const p = try b.finish(deny);
    try testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(20, 9, 5)));
    try testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(20, 9, 0x1_0000_0006)));
    try testing.expectEqual(deny, seccomp.evaluate(p, call(20, 5, 6)));
    // The high word differs from either alternative.
    try testing.expectEqual(deny, seccomp.evaluate(p, call(20, 9, 0x2_0000_0005)));
    try testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(21, 3, 0)));
    try testing.expectEqual(deny, seccomp.evaluate(p, call(21, 4, 0)));
    try testing.expectEqual(deny, seccomp.evaluate(p, call(21, 1 << 40, 0)));
    try testing.expectEqual(seccomp.allow, seccomp.evaluate(p, call(22, 99, 99)));
}

test "a program that does not fit is an error, not a truncation" {
    var small: [8]seccomp.Insn = undefined;
    var b = try seccomp.Builder.init(&small);
    var failed = false;
    for (0..8) |n| b.rule(@intCast(n), seccomp.allow) catch {
        failed = true;
    };
    try testing.expect(failed);
    try testing.expectError(error.ProgramTooLarge, b.finish(deny));
}
