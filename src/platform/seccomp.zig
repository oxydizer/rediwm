//! Seccomp-BPF filters without libseccomp: a builder for the small linear
//! programs the sandboxes need, a reference evaluator for tests, and the call
//! that loads one. Linux only; the FreeBSD port restricts with Capsicum
//! behind the same kind of entry point (`docs/plans/freebsd.md`).
//!
//! A program is the header, then one block per rule in the order they were
//! added (the first match wins), then the default action. The header kills
//! the process for a foreign architecture and, on x86-64, for an x32 number
//! (it shares the audit arch; its numbers carry bit 30; -1 is exempt, see
//! `Builder.init`). No allocation: the
//! caller owns the instruction buffer, so a program can be built after the
//! filesystem has been closed.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const SECCOMP = linux.SECCOMP;

/// One classic-BPF instruction (`struct sock_filter`).
pub const Insn = extern struct { code: u16, jt: u8, jf: u8, k: u32 };

const SockFprog = extern struct { len: u16, filter: [*]const Insn };

comptime {
    std.debug.assert(@sizeOf(Insn) == 8);
}

// BPF_LD|BPF_W|BPF_ABS, BPF_ALU|BPF_AND|BPF_K, BPF_JMP|BPF_JEQ|BPF_K,
// BPF_JMP|BPF_JGE|BPF_K, BPF_RET|BPF_K.
const ld_abs: u16 = 0x20;
const and_k: u16 = 0x54;
const jeq_k: u16 = 0x15;
const jge_k: u16 = 0x35;
const ret_k: u16 = 0x06;

/// The kernel refuses longer programs.
pub const max_insns = 4096;

const x32_bit: u32 = 0x40000000;
const x32_abi = switch (builtin.abi) {
    .gnux32, .muslx32 => true,
    else => false,
};

/// The kernel's `AUDIT_ARCH_*` for this build: the machine, plus the 64-bit
/// and little-endian flags. (`linux.AUDIT.ARCH` does not compile in Zig 0.17.)
pub const audit_arch: u32 = blk: {
    const em = std.elf.EM;
    const bits64: u32 = 0x80000000;
    const le: u32 = 0x40000000;
    break :blk switch (builtin.cpu.arch) {
        .x86_64 => @as(u32, @backingInt(em.X86_64)) | bits64 | le,
        .aarch64 => @as(u32, @backingInt(em.AARCH64)) | bits64 | le,
        .riscv64 => @as(u32, @backingInt(em.RISCV)) | bits64 | le,
        .loongarch64 => @as(u32, @backingInt(em.LOONGARCH)) | bits64 | le,
        .powerpc64le => @as(u32, @backingInt(em.PPC64)) | bits64 | le,
        .s390x => @as(u32, @backingInt(em.S390)) | bits64,
        else => @compileError("no seccomp audit arch for this target"),
    };
};

const little = builtin.cpu.arch.endian() == .little;
const nr_offset: u32 = @offsetOf(SECCOMP.data, "nr");
const arch_offset: u32 = @offsetOf(SECCOMP.data, "arch");

fn argOffset(index: u3, high: bool) u32 {
    const base: u32 = @offsetOf(SECCOMP.data, "arg0") + 8 * @as(u32, index);
    return base + if (high == little) @as(u32, 4) else 0;
}

/// What a call gets: the filter's verdicts.
pub const allow: u32 = SECCOMP.RET.ALLOW;
pub const kill_process: u32 = SECCOMP.RET.KILL_PROCESS;

pub fn errno(code: linux.E) u32 {
    return SECCOMP.RET.ERRNO | @as(u32, @backingInt(code));
}

/// The number of syscall `name` on this architecture, or null where it does
/// not exist (the legacy calls newer architectures dropped).
pub fn number(comptime name: []const u8) ?u32 {
    if (!@hasField(linux.SYS, name)) return null;
    return @intCast(@backingInt(@field(linux.SYS, name)));
}

/// A condition on one argument: `(argument & mask) == value`, over all 64 bits.
pub const Arg = struct {
    index: u3,
    value: u64,
    mask: u64 = std.math.maxInt(u64),
};

pub const Builder = struct {
    buf: []Insn,
    len: usize = 0,

    pub const Error = error{ProgramTooLarge};

    pub fn init(buf: []Insn) Error!Builder {
        var self = Builder{ .buf = buf };
        try self.push(.{ .code = ld_abs, .jt = 0, .jf = 0, .k = arch_offset });
        try self.push(.{ .code = jeq_k, .jt = 1, .jf = 0, .k = audit_arch });
        try self.push(.{ .code = ret_k, .jt = 0, .jf = 0, .k = kill_process });
        try self.push(.{ .code = ld_abs, .jt = 0, .jf = 0, .k = nr_offset });
        if (builtin.cpu.arch == .x86_64 and !x32_abi) {
            // -1 is no x32 call but what a tracer writes to skip one: it is
            // just an unknown number here and gets the default action.
            try self.push(.{ .code = jge_k, .jt = 0, .jf = 2, .k = x32_bit });
            try self.push(.{ .code = jeq_k, .jt = 1, .jf = 0, .k = std.math.maxInt(u32) });
            try self.push(.{ .code = ret_k, .jt = 0, .jf = 0, .k = kill_process });
        }
        return self;
    }

    /// Calls to syscall `nr` get `action`.
    pub fn rule(self: *Builder, nr: u32, action: u32) Error!void {
        try self.push(.{ .code = jeq_k, .jt = 0, .jf = 1, .k = nr });
        try self.push(.{ .code = ret_k, .jt = 0, .jf = 0, .k = action });
    }

    /// Calls to syscall `nr` whose argument matches `arg` get `action`; any
    /// other call to it falls through to the next rule, so several of these
    /// for one syscall are alternatives.
    pub fn ruleArg(self: *Builder, nr: u32, action: u32, arg: Arg) Error!void {
        std.debug.assert(arg.index < 6);
        const skip = self.len;
        try self.push(.{ .code = jeq_k, .jt = 0, .jf = 0, .k = nr });
        var mismatch: [2]usize = undefined;
        const offsets = [2]u32{ argOffset(arg.index, false), argOffset(arg.index, true) };
        const values = [2]u64{ arg.value, arg.value >> 32 };
        const masks = [2]u64{ arg.mask, arg.mask >> 32 };
        for (&mismatch, offsets, values, masks) |*at, offset, value, mask| {
            try self.push(.{ .code = ld_abs, .jt = 0, .jf = 0, .k = offset });
            const word: u32 = @truncate(mask);
            if (word != std.math.maxInt(u32)) try self.push(.{ .code = and_k, .jt = 0, .jf = 0, .k = word });
            at.* = self.len;
            try self.push(.{ .code = jeq_k, .jt = 0, .jf = 0, .k = @truncate(value) });
        }
        try self.push(.{ .code = ret_k, .jt = 0, .jf = 0, .k = action });
        // The accumulator held the number; later rules compare it again.
        const restore = self.len;
        try self.push(.{ .code = ld_abs, .jt = 0, .jf = 0, .k = nr_offset });
        for (mismatch) |at| try self.jumpTo(at, restore);
        try self.jumpTo(skip, self.len);
    }

    /// The finished program: every call no rule matched gets `default`.
    pub fn finish(self: *Builder, default: u32) Error![]const Insn {
        try self.push(.{ .code = ret_k, .jt = 0, .jf = 0, .k = default });
        return self.buf[0..self.len];
    }

    fn push(self: *Builder, insn: Insn) Error!void {
        if (self.len == self.buf.len or self.len == max_insns) return error.ProgramTooLarge;
        self.buf[self.len] = insn;
        self.len += 1;
    }

    /// Makes the jump at `at` go to `target` when its comparison fails.
    fn jumpTo(self: *Builder, at: usize, target: usize) Error!void {
        self.buf[at].jf = std.math.cast(u8, target - (at + 1)) orelse return error.ProgramTooLarge;
    }
};

/// What `program` returns for a call, as the kernel would run it. For tests.
pub fn evaluate(program: []const Insn, call: SECCOMP.data) u32 {
    const bytes = std.mem.asBytes(&call);
    var acc: u32 = 0;
    var pc: usize = 0;
    while (true) : (pc += 1) {
        const insn = program[pc];
        switch (insn.code) {
            ld_abs => acc = std.mem.readInt(u32, bytes[insn.k..][0..4], builtin.cpu.arch.endian()),
            and_k => acc &= insn.k,
            jeq_k => pc += if (acc == insn.k) insn.jt else insn.jf,
            jge_k => pc += if (acc >= insn.k) insn.jt else insn.jf,
            ret_k => return insn.k,
            else => unreachable,
        }
    }
}

// Through libc rather than `linux.seccomp` so a test can interpose the call.
extern "c" fn syscall(number: c_long, ...) c_long;

/// Loads `program` on every thread of the process. The caller has set
/// `PR_SET_NO_NEW_PRIVS`, and the process is single-threaded, so nothing
/// escapes the filter by already running elsewhere.
pub fn install(program: []const Insn) error{InstallFailed}!void {
    const prog = SockFprog{ .len = @intCast(program.len), .filter = program.ptr };
    const rc = syscall(@backingInt(linux.SYS.seccomp), @as(c_long, SECCOMP.SET_MODE_FILTER), @as(c_long, SECCOMP.FILTER_FLAG.TSYNC), @intFromPtr(&prog));
    if (rc != 0) return error.InstallFailed;
}
