const std = @import("std");
const tc = @import("model.zig").c;
const c = @import("../c.zig").api;

fn feed(t: *tc.FT, bytes: []const u8) void {
    tc.ft_feed(t, bytes.ptr, bytes.len);
}
fn cell(t: *tc.FT, row: i32, col: i32) !tc.FT_Cell {
    var result: tc.FT_Cell = undefined;
    try std.testing.expect(tc.ft_cell(t, row, col, &result));
    return result;
}
test "terminal accepts chunked Unicode and escape sequences, attributes and alternate screen" {
    const t = tc.ft_new(4, 20) orelse return error.OutOfMemory;
    defer tc.ft_free(t);
    for ("Aé界e\xcc\x81\x1b[31;1mZ") |byte| feed(t, &.{byte});
    try std.testing.expectEqual(@as(u32, 'A'), (try cell(t, 0, 0)).chars[0]);
    try std.testing.expectEqual(@as(u32, 'é'), (try cell(t, 0, 1)).chars[0]);
    try std.testing.expectEqual(@as(u8, 2), (try cell(t, 0, 2)).width);
    try std.testing.expectEqual(@as(u8, 0), (try cell(t, 0, 3)).width);
    try std.testing.expectEqual(@as(u32, 0x301), (try cell(t, 0, 4)).chars[1]);
    try std.testing.expect((try cell(t, 0, 5)).attrs & tc.FT_BOLD != 0);
    feed(t, "\x1b[38;2;12;34;56mQ");
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56 }, &(try cell(t, 0, 6)).fg);
    feed(t, "\x1b[?5h");
    try std.testing.expect((try cell(t, 0, 0)).attrs & tc.FT_REVERSE != 0);
    feed(t, "\x1b[?5l");
    try std.testing.expect((try cell(t, 0, 0)).attrs & tc.FT_REVERSE == 0);
    feed(t, "\x1b[?1049h\x1b[Halternate");
    try std.testing.expectEqual(@as(u32, 'a'), (try cell(t, 0, 0)).chars[0]);
    feed(t, "\x1b[?1049l");
    try std.testing.expectEqual(@as(u32, 'A'), (try cell(t, 0, 0)).chars[0]);
    tc.ft_resize(t, 8, 30);
    try std.testing.expectEqual(@as(i32, 8), tc.ft_rows(t));
    try std.testing.expectEqual(@as(u32, 'A'), (try cell(t, 0, 0)).chars[0]);
    tc.ft_resize(t, 0, 0);
    try std.testing.expectEqual(@as(i32, 30), tc.ft_cols(t));
}
test "terminal history stays bounded and preserves a reader's position" {
    const t = tc.ft_new(3, 80) orelse return error.OutOfMemory;
    defer tc.ft_free(t);
    for (0..100) |_| feed(t, "line\r\n");
    tc.ft_scroll(t, 30);
    const top = tc.ft_line(t) - tc.ft_offset(t);
    feed(t, "new\r\n");
    try std.testing.expectEqual(top, tc.ft_line(t) - tc.ft_offset(t));
    for (0..10000) |_| feed(t, "bounded\r\n");
    try std.testing.expect(tc.ft_history(t) <= 4096);
    try std.testing.expect(tc.ft_history_bytes(t) <= 8 * 1024 * 1024);
    tc.ft_scroll(t, -100000);
    try std.testing.expectEqual(@as(i32, 0), tc.ft_offset(t));
    feed(t, "\x1b[3J");
    try std.testing.expectEqual(@as(i32, 0), tc.ft_history(t));
}
test "terminal encodes controls, application cursors, bracketed paste and mouse modes" {
    const t = tc.ft_new(4, 20) orelse return error.OutOfMemory;
    defer tc.ft_free(t);
    var bytes: [128]u8 = undefined;
    tc.ft_key(t, c.XKB_KEY_c, "\x03", 1, 4);
    try std.testing.expectEqualStrings("\x03", bytes[0..tc.ft_take_output(t, &bytes, bytes.len)]);
    feed(t, "\x1b[?1h");
    tc.ft_key(t, c.XKB_KEY_Up, "", 0, 0);
    try std.testing.expectEqualStrings("\x1bOA", bytes[0..tc.ft_take_output(t, &bytes, bytes.len)]);
    feed(t, "\x1b[?2004h");
    try std.testing.expect(tc.ft_paste(t, "hi\n\x1btext", 8));
    try std.testing.expectEqualStrings("\x1b[200~hi\rtext\x1b[201~", bytes[0..tc.ft_take_output(t, &bytes, bytes.len)]);
    feed(t, "\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(tc.ft_mouse_mode(t) != 0);
    tc.ft_mouse(t, 1, 2, 1, true, 0);
    try std.testing.expectEqualStrings("\x1b[<0;3;2M", bytes[0..tc.ft_take_output(t, &bytes, bytes.len)]);
    // OSC 52 cannot touch the Wayland clipboard or emit a clipboard response.
    feed(t, "\x1b]52;c;?\x07\x1b]52;c;YmFk\x07");
    try std.testing.expectEqual(@as(usize, 0), tc.ft_take_output(t, &bytes, bytes.len));
    const large = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try std.testing.expect(!tc.ft_paste(t, large.ptr, large.len));
    try std.testing.expectEqual(@as(usize, 0), tc.ft_take_output(t, &bytes, bytes.len));
}
test "terminal sessions and palette defaults remain independent" {
    const t = tc.ft_new(3, 10) orelse return error.OutOfMemory;
    defer tc.ft_free(t);
    const other = tc.ft_new(3, 10) orelse return error.OutOfMemory;
    defer tc.ft_free(other);
    feed(t, "hello");
    tc.ft_palette(t, tc.FT_DEFAULT_FG, 12, 34, 56);
    try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56 }, &(try cell(t, 0, 0)).fg);
    try std.testing.expectEqual(@as(u32, 0), (try cell(other, 0, 0)).chars[0]);
}

test "terminal color queries match the theme and the painted xterm palette" {
    const t = tc.ft_new(3, 10) orelse return error.OutOfMemory;
    defer tc.ft_free(t);
    tc.ft_palette(t, tc.FT_DEFAULT_FG, 12, 34, 56);
    tc.ft_palette(t, tc.FT_DEFAULT_BG, 1, 2, 3);
    tc.ft_palette(t, tc.FT_CURSOR_COLOR, 255, 128, 0);
    tc.ft_palette(t, 1, 190, 21, 42);

    feed(t, "\x1b[31;48;5;17mA\x1b[38;5;232;48;5;255mB\x1b[0mC");
    try std.testing.expectEqual([3]u8{ 190, 21, 42 }, (try cell(t, 0, 0)).fg);
    try std.testing.expectEqual([3]u8{ 0, 0, 95 }, (try cell(t, 0, 0)).bg);
    try std.testing.expectEqual([3]u8{ 8, 8, 8 }, (try cell(t, 0, 1)).fg);
    try std.testing.expectEqual([3]u8{ 238, 238, 238 }, (try cell(t, 0, 1)).bg);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, (try cell(t, 0, 2)).bg);

    var bytes: [256]u8 = undefined;
    for ("\x1b]10;?;?;?\x1b") |byte| feed(t, &.{byte});
    try std.testing.expectEqual(@as(usize, 0), tc.ft_take_output(t, &bytes, bytes.len));
    feed(t, "\\\x1b]4;1;?;17;?;255;?\x07");
    try std.testing.expectEqualStrings(
        "\x1b]10;rgb:0c0c/2222/3838\x1b\\\x1b]11;rgb:0101/0202/0303\x1b\\" ++
            "\x1b]12;rgb:ffff/8080/0000\x1b\\\x1b]4;1;rgb:bebe/1515/2a2a\x1b\\" ++
            "\x1b]4;17;rgb:0000/0000/5f5f\x1b\\\x1b]4;255;rgb:eeee/eeee/eeee\x1b\\",
        bytes[0..tc.ft_take_output(t, &bytes, bytes.len)],
    );
    feed(t, "\x1b]4;256;?;-1;?;1;#000000\x07\x1b]11;#ffffff\x07\x1b]10;??\x07");
    try std.testing.expectEqual(@as(usize, 0), tc.ft_take_output(t, &bytes, bytes.len));
    try std.testing.expectEqual([3]u8{ 190, 21, 42 }, (try cell(t, 0, 0)).fg);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, (try cell(t, 0, 2)).bg);

    tc.ft_palette(t, tc.FT_DEFAULT_BG, 245, 246, 247);
    feed(t, "\x1b]11;?\x07");
    try std.testing.expectEqualStrings("\x1b]11;rgb:f5f5/f6f6/f7f7\x1b\\", bytes[0..tc.ft_take_output(t, &bytes, bytes.len)]);
    try std.testing.expectEqual([3]u8{ 245, 246, 247 }, (try cell(t, 0, 2)).bg);
}

const FailingAllocator = struct {
    calls: usize = 0,
    fail_at: usize,
    active: usize = 0,
    fn alloc(owner: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const self: *FailingAllocator = @ptrCast(@alignCast(owner.?));
        self.calls += 1;
        if (self.calls == self.fail_at) return null;
        const pointer = c.malloc(size) orelse return null;
        self.active += 1;
        return pointer;
    }
    fn free(owner: ?*anyopaque, pointer: ?*anyopaque) callconv(.c) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(owner.?));
        if (pointer != null) self.active -= 1;
        c.free(pointer);
    }
};
test "libvterm allocation failures release partial construction and fail resize safely" {
    var reached_success = false;
    for (1..40) |fail_at| {
        var state: FailingAllocator = .{ .fail_at = fail_at };
        const allocator: tc.FT_Allocator = .{ .owner = &state, .alloc = FailingAllocator.alloc, .free = FailingAllocator.free };
        if (tc.ft_new_alloc(4, 20, &allocator)) |t| {
            state.calls = 0;
            state.fail_at = 1;
            tc.ft_resize(t, 24, 120);
            try std.testing.expect(tc.ft_error(t) != null);
            var result: tc.FT_Cell = undefined;
            try std.testing.expect(!tc.ft_cell(t, 0, 0, &result));
            tc.ft_free(t);
            reached_success = true;
        }
        try std.testing.expectEqual(@as(usize, 0), state.active);
        if (reached_success) break;
    }
    try std.testing.expect(reached_success);
}
