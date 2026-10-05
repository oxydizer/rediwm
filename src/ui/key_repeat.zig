//! Client-side key repeat for the shell's own Wayland clients (Files,
//! Images). Wayland leaves repeat to clients: the compositor sends only
//! `wl_keyboard.repeat_info`, the user's `[input] key_repeat_delay`/`_rate`,
//! and each client times its own repeats. This is that timer as plain state;
//! the client folds `timeoutMs` into its poll and delivers each `due` key as
//! a fresh press. Which keys may repeat is the app's call, from the keymap's
//! `xkb_keymap_key_repeats` and its own focus (a held Delete must not trash
//! file after file).
const std = @import("std");

/// The monotonic clock the repeat deadlines are on.
pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Text and caret keys in a field: printable characters, Backspace, Delete,
/// Left and Right. Return, Tab and Escape are control characters.
pub fn editingKey(backspace_delete_left_right: bool, utf8: []const u8) bool {
    return backspace_delete_left_right or (utf8.len > 0 and utf8[0] >= 32 and utf8[0] != 127);
}

pub const KeyRepeat = struct {
    /// Repeats per second; 0 disables repeat, as `repeat_info` specifies.
    rate: u32 = 25,
    delay_ms: u32 = 400,
    /// The held key (evdev code) and when it next repeats.
    key: ?u32 = null,
    next_ms: i64 = 0,

    pub fn setInfo(self: *KeyRepeat, rate: i32, delay_ms: i32) void {
        self.rate = @intCast(@max(0, rate));
        self.delay_ms = @intCast(@max(0, delay_ms));
        if (self.rate == 0) self.key = null;
    }

    /// A press. A key that repeats replaces the held one; one that doesn't
    /// (a modifier) leaves it running, so Shift can join a held key.
    /// `repeats` is the keymap's and the app's verdict together.
    pub fn press(self: *KeyRepeat, key: u32, keymap_repeats: bool, app_repeats: bool, now_ms: i64) void {
        if (!keymap_repeats) return;
        if (!app_repeats or self.rate == 0) {
            self.key = null;
            return;
        }
        self.key = key;
        self.next_ms = now_ms + self.delay_ms;
    }

    pub fn release(self: *KeyRepeat, key: u32) void {
        if (self.key == key) self.key = null;
    }

    /// Focus left or the keymap changed.
    pub fn stop(self: *KeyRepeat) void {
        self.key = null;
    }

    /// Milliseconds until the next repeat is due, for a poll timeout.
    pub fn timeoutMs(self: KeyRepeat, now_ms: i64) ?i64 {
        if (self.key == null) return null;
        return @max(0, self.next_ms - now_ms);
    }

    /// The held key if a repeat is due, advancing to the next one. A late
    /// wakeup (a busy frame) yields one repeat, not a burst to catch up.
    pub fn due(self: *KeyRepeat, now_ms: i64) ?u32 {
        const key = self.key orelse return null;
        if (now_ms < self.next_ms or self.rate == 0) return null;
        const interval: i64 = @divTrunc(1000, @as(i64, self.rate));
        self.next_ms = @max(self.next_ms + interval, now_ms + @divTrunc(interval, 2));
        return key;
    }
};

test "a held key repeats after the delay at the rate, until released" {
    var r = KeyRepeat{};
    r.setInfo(20, 300);
    r.press(30, true, true, 1000);
    try std.testing.expectEqual(@as(?i64, 300), r.timeoutMs(1000));
    try std.testing.expectEqual(@as(?u32, null), r.due(1299));
    try std.testing.expectEqual(@as(?u32, 30), r.due(1300));
    try std.testing.expectEqual(@as(?u32, null), r.due(1349));
    try std.testing.expectEqual(@as(?u32, 30), r.due(1350));
    // One repeat for a long stall, then back on the rate.
    try std.testing.expectEqual(@as(?u32, 30), r.due(2000));
    try std.testing.expectEqual(@as(?u32, null), r.due(2010));
    r.release(30);
    try std.testing.expectEqual(@as(?i64, null), r.timeoutMs(2100));
    try std.testing.expectEqual(@as(?u32, null), r.due(5000));
}

test "modifiers leave a held key repeating; other keys take over or stop it" {
    var r = KeyRepeat{};
    r.press(30, true, true, 0);
    r.press(42, false, false, 100); // Shift
    try std.testing.expectEqual(@as(?u32, 30), r.key);
    r.release(42);
    try std.testing.expectEqual(@as(?u32, 30), r.key);
    r.press(48, true, true, 200);
    try std.testing.expectEqual(@as(?u32, 48), r.key);
    // Releasing the first key no longer matters; a key the app won't repeat
    // (Delete in a file list) ends the repeat instead of adopting it.
    r.release(30);
    try std.testing.expectEqual(@as(?u32, 48), r.key);
    r.press(111, true, false, 300);
    try std.testing.expectEqual(@as(?u32, null), r.key);
    // Rate 0 turns repeat off.
    r.setInfo(0, 400);
    r.press(30, true, true, 400);
    try std.testing.expectEqual(@as(?u32, null), r.key);
}
