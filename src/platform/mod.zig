//! Everything that differs between operating systems, behind one interface:
//! child processes, file-change notification, the program's own path, where
//! the system's helper programs live, who is on the other end of a unix socket,
//! renaming without replacing, reading and examining directories,
//! process attributes (no core dumps, no new privileges), wake descriptors and
//! syscall filters.
//! Callers never test the OS; `std.os.linux` is used only in here (see
//! `AGENTS.md` beside this file). No compositor imports.
pub const login_io = @import("login_io.zig");
pub const login_process = @import("login_process.zig");
pub const child = @import("child.zig");
pub const dirwalk = @import("dirwalk.zig");
pub const exe = @import("exe.zig");
pub const fs = @import("fs.zig");
pub const peer = @import("peer.zig");
pub const process = @import("process.zig");
pub const wake = @import("wake.zig");
pub const power_supply = @import("power_supply.zig");
pub const rfkill = @import("rfkill.zig");
pub const charge_limit = @import("charge_limit.zig");
pub const watch = @import("watch.zig");
pub const seccomp = @import("seccomp.zig");
pub const system = @import("system.zig");
pub const tool = @import("tool.zig");

test {
    _ = login_process;
    _ = child;
    _ = dirwalk;
    _ = exe;
    _ = fs;
    _ = peer;
    _ = process;
    _ = rfkill;
    _ = wake;
    _ = system;
    _ = tool;
    _ = watch;
    _ = @import("seccomp_tests.zig");
}
