//! Which keys repeat in compositor-drawn UI. `Keyboard` owns the timer and
//! re-delivers a held key to the shell target that took its press; each
//! target decides which of its keys may repeat, from these classes. Action
//! keys (Return, Escape, Tab, Space on a button) never repeat: a held Return
//! on the lock would resubmit, one on a dialog would confirm twice.
const xkb = @import("xkbcommon");

/// Text and caret keys: printable characters, Backspace, Delete, Left, Right.
pub fn editing(sym: xkb.Keysym, utf8: []const u8) bool {
    return switch (@intFromEnum(sym)) {
        xkb.Keysym.BackSpace, xkb.Keysym.Delete, xkb.Keysym.Left, xkb.Keysym.Right => true,
        else => printable(utf8),
    };
}

/// List navigation: Up, Down, Page Up, Page Down.
pub fn navigation(sym: xkb.Keysym) bool {
    return switch (@intFromEnum(sym)) {
        xkb.Keysym.Up, xkb.Keysym.Down, xkb.Keysym.Page_Up, xkb.Keysym.Page_Down => true,
        else => false,
    };
}

/// Return, Tab and Escape produce control characters, so they are not text.
fn printable(utf8: []const u8) bool {
    return utf8.len > 0 and utf8[0] >= 32 and utf8[0] != 127;
}

test "text and caret keys repeat; action keys do not" {
    const std = @import("std");
    const sym = struct {
        fn of(value: u32) xkb.Keysym {
            return @enumFromInt(value);
        }
    }.of;
    try std.testing.expect(editing(sym(xkb.Keysym.a), "a"));
    try std.testing.expect(editing(sym(xkb.Keysym.space), " "));
    try std.testing.expect(editing(sym(xkb.Keysym.eacute), "é"));
    try std.testing.expect(editing(sym(xkb.Keysym.BackSpace), "\x08"));
    try std.testing.expect(editing(sym(xkb.Keysym.Left), ""));
    try std.testing.expect(!editing(sym(xkb.Keysym.Return), "\r"));
    try std.testing.expect(!editing(sym(xkb.Keysym.Tab), "\t"));
    try std.testing.expect(!editing(sym(xkb.Keysym.Escape), "\x1b"));
    try std.testing.expect(!editing(sym(xkb.Keysym.Home), ""));
    try std.testing.expect(navigation(sym(xkb.Keysym.Page_Down)));
    try std.testing.expect(!navigation(sym(xkb.Keysym.Left)));
}
