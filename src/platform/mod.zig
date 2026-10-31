//! Everything that differs between operating systems, behind one interface:
//! child processes, file-change notification, the program's own path and
//! syscall filters.
//! Callers never test the OS; `std.os.linux` is used only in here (see
//! `AGENTS.md` beside this file). No compositor imports.
pub const child = @import("child.zig");
pub const exe = @import("exe.zig");
pub const power_supply = @import("power_supply.zig");
pub const charge_limit = @import("charge_limit.zig");
pub const watch = @import("watch.zig");
pub const seccomp = @import("seccomp.zig");

test {
    _ = child;
    _ = exe;
    _ = watch;
    _ = @import("seccomp_tests.zig");
}
