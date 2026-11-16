//! Opt-in timing for Files UI hot paths.
//! Enable with REDIWM_FILES_UI_PROFILE=1.

const std = @import("std");

pub fn start() ?u64 {
    if (std.c.getenv("REDIWM_FILES_UI_PROFILE") == null) return null;
    return nowNs();
}

pub fn finish(started: ?u64, stage: []const u8, item_count: usize) void {
    const start_ns = started orelse return;
    const elapsed_ns = nowNs() - start_ns;
    // Avoid flooding stderr with insignificant calls.
    if (elapsed_ns < 50_000) return;
    std.debug.print(
        "FILES_UI_PROFILE,{s},{d},{d}\n",
        .{ stage, elapsed_ns, item_count },
    );
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}
