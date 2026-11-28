//! Debug guard for the Files responsiveness invariant
//! (docs/plans/files-io-threading-and-ownership.md §1, §13).
//!
//! The UI event-loop thread and the I/O coordinator thread must not perform
//! potentially blocking filesystem work. Each marks itself with `markCurrent`.
//! Filesystem helpers call `blocking()` before such work.
//!
//! The plan's audit table of known violations (U1 to U17) is empty since
//! stage S4: there are no exemptions, and none may be added.
//!
//! The guard is active in Debug builds only. A violation panics in tests
//! and is logged with a stack trace in a Debug Files session, so a missed
//! call site shows up without ending the user's session.
const std = @import("std");
const builtin = @import("builtin");

const active = builtin.mode == .debug;

pub const Role = enum { none, ui, coordinator };

threadlocal var role: Role = .none;

/// Marks the calling thread. The UI thread calls this once at startup, the
/// coordinator at the top of its thread.
pub fn markCurrent(new_role: Role) void {
    role = new_role;
}

pub fn currentRole() Role {
    return role;
}

/// Called by filesystem helpers before work that can block. Does nothing on
/// unmarked threads (workers, tests).
pub fn blocking(comptime what: []const u8) void {
    if (!active) return;
    if (role == .none) return;
    if (builtin.is_test)
        std.debug.panic("blocking filesystem call on the {s} thread: {s}", .{ @tagName(role), what });
    std.log.err("blocking filesystem call on the {s} thread: {s}", .{ @tagName(role), what });
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
}

test "unmarked threads pass" {
    blocking("unmarked");
}
