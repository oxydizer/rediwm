//! Debug guard for the Files responsiveness invariant
//! (docs/plans/files-io-threading-and-ownership.md §1, §13).
//!
//! The UI event-loop thread and the I/O coordinator thread must not perform
//! potentially blocking filesystem work. Each marks itself with `markCurrent`.
//! Filesystem helpers call `blocking()` before such work. A call site that is
//! still known to violate the rule opens a named `Exemption` scope around it.
//!
//! The exemption list is the audit table of the plan. A stage may remove
//! entries, never add one; when an entry's last call site is migrated, delete
//! it here so the compiler finds any leftover use.
//!
//! The guard is active in Debug builds only. A violation panics in tests
//! and is logged with a stack trace in a Debug Files session, so a missed
//! call site shows up without ending the user's session.
const std = @import("std");
const builtin = @import("builtin");

const active = builtin.mode == .debug;

pub const Role = enum { none, ui, coordinator };

/// Audited call sites that still block on a guarded thread, by plan id.
pub const Exemption = enum {
    /// App transfer preparation: lstat, readlink, stat (S3).
    u1_transfer_prepare,
    /// JobRunner start and polling (S3, needs phase 2).
    u2_job_runner,
    /// Per-window Runtime pumping on the UI thread (S3).
    u3_window_runtime,
    /// Trash restore (S3).
    u7_trash_restore,
    /// New folder, new file, rename, unique-name generation (S3).
    u8_small_mutations,
    /// Properties open and permission toggles (S3).
    u9_properties,
    /// File chooser path checks (S3).
    u10_chooser,
    /// Places: create directory, pin kind checks (S3).
    u11_places,
    /// Terminal and drop path canonicalisation (S3).
    u12_path_resolution,
    /// Archive publication cursor open and reads (S4).
    u13_archive_publication,
    /// Archive staging discard (S4).
    u14_archive_discard,
    /// Transferred-out staging lease deletion (S4).
    u15_staging_lease,
};

threadlocal var role: Role = .none;
threadlocal var exemption_depth: u32 = 0;

/// Marks the calling thread. The UI thread calls this once at startup, the
/// coordinator at the top of its thread.
pub fn markCurrent(new_role: Role) void {
    role = new_role;
}

pub fn currentRole() Role {
    return role;
}

/// An open exemption. End it with `defer scope.end()`.
pub const Scope = struct {
    pub fn end(_: Scope) void {
        if (!active) return;
        std.debug.assert(exemption_depth > 0);
        exemption_depth -= 1;
    }
};

pub fn exempt(comptime _: Exemption) Scope {
    if (active) exemption_depth += 1;
    return .{};
}

/// Called by filesystem helpers before work that can block. Does nothing on
/// unmarked threads (workers, tests) or inside an exemption.
pub fn blocking(comptime what: []const u8) void {
    if (!active) return;
    if (role == .none or exemption_depth > 0) return;
    if (builtin.is_test)
        std.debug.panic("blocking filesystem call on the {s} thread: {s}", .{ @tagName(role), what });
    std.log.err("blocking filesystem call on the {s} thread: {s}", .{ @tagName(role), what });
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
}

test "unmarked threads and exempted scopes pass" {
    blocking("unmarked");
    markCurrent(.ui);
    defer markCurrent(.none);
    const scope = exempt(.u8_small_mutations);
    defer scope.end();
    blocking("exempted");
}
