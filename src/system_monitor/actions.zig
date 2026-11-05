//! Action authority is checked again at execution, never trusted from a row.
const std = @import("std");
const platform = @import("platform");
const proc = @import("proc.zig");
const c = proc.c;
pub const Kind = enum { end, force };

pub fn execute(identity: proc.Identity, kind: Kind) !void {
    const process = platform.child.Handle.open(identity.pid) catch |err| return signalError(err);
    defer process.close();
    // Open the process record AFTER the handle. If PID reuse occurs between
    // them, the old handle reports the exit and the final liveness gate fails.
    const entry = try proc.Process.open(identity.pid);
    defer entry.close();
    var stat_buf: [4096]u8 = undefined;
    const stat = try entry.stat(&stat_buf);
    if (stat.start != identity.start) return error.ProcessExited;
    var status_buf: [16384]u8 = undefined;
    const uids = try entry.uids(&status_buf);
    if (!proc.owned(uids, c.getuid())) return error.PermissionDenied;
    if (try proc.isProtected(entry, identity.pid)) return error.ProtectedProcess;
    // The handle names the task it was opened on, not whichever task
    // currently occupies /proc/PID.
    const live = process.pid() catch return error.IdentityUnavailable;
    if (live != identity.pid) return error.ProcessExited;
    if (process.exited()) return error.ProcessExited;
    process.signal(if (kind == .end) .TERM else .KILL) catch |err| return signalError(err);
}

fn signalError(err: platform.child.Error) error{ ProcessExited, PermissionDenied, PidfdUnavailable, SignalFailed } {
    return switch (err) {
        error.NoSuchProcess => error.ProcessExited,
        error.PermissionDenied => error.PermissionDenied,
        error.Unsupported => error.PidfdUnavailable,
        error.Failed => error.SignalFailed,
    };
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.ProcessExited => "Process already exited",
        error.PermissionDenied => "Permission denied: only your own processes can be managed",
        error.ProtectedProcess => "This essential RediWM session process is protected",
        error.PidfdUnavailable => "Safe process actions require Linux pidfd support",
        error.IdentityUnavailable => "Could not verify the process identity",
        else => "Could not send the signal",
    };
}
