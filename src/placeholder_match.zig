//! Launch placeholder matching logic.
//!
//! Match real windows to placeholders using layered criteria (most trustworthy first):
//! 1. Activation token
//! 2. Process ID / parent chain walking
//! 3. App ID / desktop entry stem matching
const std = @import("std");
const proc = @import("system_monitor/proc.zig");

pub fn matchesPidChain(client_pid: i32, target_pid: i32) bool {
    if (client_pid <= 0 or target_pid <= 0) return false;
    if (client_pid == target_pid) return true;

    var cur_pid = client_pid;
    var depth: usize = 0;
    while (depth < 5) : (depth += 1) {
        var stat_buf: [1024]u8 = undefined;
        const ppid = (proc.readStat(cur_pid, &stat_buf) orelse break).ppid;
        if (ppid <= 1) break;
        if (ppid == target_pid) return true;
        cur_pid = ppid;
    }
    return false;
}

pub fn matchesAppId(candidate: []const u8, startup_wm_class: ?[]const u8, desktop_id: []const u8) bool {
    if (candidate.len == 0) return false;

    // 1. StartupWMClass exact or case-insensitive
    if (startup_wm_class) |wmc| {
        if (wmc.len > 0 and std.ascii.eqlIgnoreCase(candidate, wmc)) return true;
    }

    if (desktop_id.len == 0) return false;

    // 2. Full desktop_id
    if (std.ascii.eqlIgnoreCase(candidate, desktop_id)) return true;

    // 3. Stem (without .desktop suffix)
    const stem = if (std.mem.endsWith(u8, desktop_id, ".desktop"))
        desktop_id[0 .. desktop_id.len - ".desktop".len]
    else
        desktop_id;

    if (std.ascii.eqlIgnoreCase(candidate, stem)) return true;

    // 4. Last dotted component (e.g. "org.mozilla.firefox" -> "firefox")
    if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot_idx| {
        const last_comp = stem[dot_idx + 1 ..];
        if (last_comp.len > 0 and std.ascii.eqlIgnoreCase(candidate, last_comp)) return true;
    }

    return false;
}

pub fn matchesToken(candidate_token: []const u8, placeholder_token: []const u8) bool {
    if (candidate_token.len == 0 or placeholder_token.len == 0) return false;
    return std.mem.eql(u8, candidate_token, placeholder_token);
}

test "app_id matching" {
    try std.testing.expect(matchesAppId("foot", null, "foot.desktop"));
    try std.testing.expect(matchesAppId("FOOT", null, "foot.desktop"));
    try std.testing.expect(matchesAppId("foot.desktop", null, "foot.desktop"));
    try std.testing.expect(matchesAppId("firefox", null, "org.mozilla.firefox.desktop"));
    try std.testing.expect(matchesAppId("org.mozilla.firefox", null, "org.mozilla.firefox.desktop"));
    try std.testing.expect(matchesAppId("brave-browser", "brave-browser", "brave-desktop.desktop"));
    try std.testing.expect(!matchesAppId("unrelated", null, "foot.desktop"));
    try std.testing.expect(!matchesAppId("", null, "foot.desktop"));
}
