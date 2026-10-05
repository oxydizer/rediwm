//! Launch placeholder matching logic.
//!
//! Match real windows to placeholders using layered criteria (most trustworthy first):
//! 1. Activation token
//! 2. Process ID / /proc ppid chain walking
//! 3. App ID / desktop entry stem matching
const std = @import("std");

pub fn parsePpidFromStat(stat_content: []const u8) ?i32 {
    // Linux /proc/<pid>/stat format:
    // pid (comm) state ppid pgrp session tty_nr ...
    // Note that comm can contain arbitrary characters including parentheses and spaces.
    const last_paren = std.mem.lastIndexOfScalar(u8, stat_content, ')') orelse return null;
    if (last_paren + 2 >= stat_content.len) return null;

    // After ')': space, state character, space, ppid
    const remainder = std.mem.trimStart(u8, stat_content[last_paren + 1 ..], " \t");
    // Remainder begins with state character (e.g. 'S' or 'R')
    var it = std.mem.splitScalar(u8, remainder, ' ');
    _ = it.next() orelse return null; // skip state
    const ppid_str = it.next() orelse return null;
    return std.fmt.parseInt(i32, ppid_str, 10) catch null;
}

pub fn matchesPidChain(client_pid: i32, target_pid: i32) bool {
    if (client_pid <= 0 or target_pid <= 0) return false;
    if (client_pid == target_pid) return true;

    var cur_pid = client_pid;
    var depth: usize = 0;
    while (depth < 5) : (depth += 1) {
        var path_buf: [64:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{cur_pid}) catch break;
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
        }, 0) catch break;
        defer _ = std.c.close(fd);

        var stat_buf: [1024]u8 = undefined;
        const bytes_read = std.posix.read(fd, &stat_buf) catch break;
        const ppid = parsePpidFromStat(stat_buf[0..bytes_read]) orelse break;
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

test "parse ppid from /proc/<pid>/stat" {
    // Normal process stat
    const sample1 = "12345 (bash) S 6789 12345 12345 34816 12345 4194304 2337 0 0 0 0 0 0 0 20 0 1 0";
    try std.testing.expectEqual(@as(?i32, 6789), parsePpidFromStat(sample1));

    // Process comm with parentheses and spaces inside
    const sample2 = "999 (my (complex) app) R 1001 999 999 0 0 0 0 0 0 0";
    try std.testing.expectEqual(@as(?i32, 1001), parsePpidFromStat(sample2));

    // Malformed
    try std.testing.expect(parsePpidFromStat("") == null);
    try std.testing.expect(parsePpidFromStat("not valid stat") == null);
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
