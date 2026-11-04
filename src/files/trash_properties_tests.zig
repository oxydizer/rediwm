const std = @import("std");
const c = @import("c.zig").api;
const icon_theme = @import("../icon_theme.zig");
const trash_properties = @import("trash_properties.zig");
const State = trash_properties.State;

fn writeFile(dir_fd: c_int, name: [*:0]const u8, content: []const u8) !void {
    const fd = c.openat(dir_fd, name, c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    defer _ = c.close(fd);
    if (c.write(fd, content.ptr, content.len) != @as(isize, @intCast(content.len))) return error.WriteFailed;
}

fn waitForTotals(state: *State) !void {
    var tries: usize = 0;
    while (!state.poll()) : (tries += 1) {
        if (tries > 500) return error.TotalsNeverArrived;
        _ = c.usleep(10_000);
    }
}

test "keys and clicks reach Close and Open" {
    var state = try State.init("/nonexistent-rediwm-trash", -1);
    defer state.deinit();
    try std.testing.expectEqual(trash_properties.Action.none, state.key(c.XKB_KEY_a));
    try std.testing.expectEqual(trash_properties.Action.close, state.key(c.XKB_KEY_Escape));
    // Close has the focus first, so Enter closes without a Tab.
    try std.testing.expectEqual(trash_properties.Action.close, state.key(c.XKB_KEY_Return));
    try std.testing.expectEqual(trash_properties.Action.none, state.key(c.XKB_KEY_Tab));
    try std.testing.expect(state.keyboard_focus and state.focus == .open);
    try std.testing.expectEqual(trash_properties.Action.open, state.key(c.XKB_KEY_Return));
    try std.testing.expectEqual(trash_properties.Action.none, state.key(c.XKB_KEY_ISO_Left_Tab));
    try std.testing.expectEqual(trash_properties.Action.close, state.key(c.XKB_KEY_space));

    const g = state.geometry(800, 600);
    try std.testing.expectEqual(trash_properties.Action.close, state.click(800, 600, g.box.x + g.close.x + 3, g.box.y + g.close.y + 3));
    try std.testing.expectEqual(trash_properties.Action.open, state.click(800, 600, g.box.x + g.open.x + 3, g.box.y + g.open.y + 3));
    // Text and empty space are not buttons.
    try std.testing.expectEqual(trash_properties.Action.none, state.click(800, 600, g.box.x + 40, g.box.y + g.box.h - 20));
    try std.testing.expectEqual(trash_properties.Action.none, state.click(800, 600, 2, 2));
}

test "the window counts the Trash and draws a pack's trash artwork" {
    var template = "/tmp/rediwm-trash-card-XXXXXX".* ++ [_]u8{0};
    const root = c.mkdtemp(&template) orelse return error.TempFailed;
    const root_fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(root_fd >= 0);
    defer _ = c.rmdir(root);
    defer _ = c.close(root_fd);
    // The pack: icons/user-trash.svg, a solid green square.
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(root_fd, "icons", 0o700));
    defer _ = c.unlinkat(root_fd, "icons", c.AT_REMOVEDIR);
    try writeFile(root_fd, "icons/user-trash.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\"><rect width=\"48\" height=\"48\" fill=\"#00ff00\"/></svg>");
    defer _ = c.unlinkat(root_fd, "icons/user-trash.svg", 0);
    // The Trash itself: two entries, one of them a folder.
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(root_fd, "files", 0o700));
    defer _ = c.unlinkat(root_fd, "files", c.AT_REMOVEDIR);
    try writeFile(root_fd, "files/note.txt", "hello");
    defer _ = c.unlinkat(root_fd, "files/note.txt", 0);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(root_fd, "files/dir", 0o700));
    defer _ = c.unlinkat(root_fd, "files/dir", c.AT_REMOVEDIR);
    try writeFile(root_fd, "files/dir/data", "0123456789");
    defer _ = c.unlinkat(root_fd, "files/dir/data", 0);

    var files_path: [128]u8 = undefined;
    const files = try std.fmt.bufPrint(&files_path, "{s}/files", .{std.mem.span(root)});
    var state = try State.init(files, -1);
    defer state.deinit();
    try std.testing.expect(state.totals == null);
    try waitForTotals(&state);
    try std.testing.expectEqual(@as(u64, 2), state.totals.?.items);
    try std.testing.expectEqual(@as(i64, 15), state.totals.?.bytes);
    try std.testing.expect(!state.totals.?.partial);

    const w = 640;
    const h = 480;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    const cfg: icon_theme.Config = .{ .theme_name = "", .override_root = std.mem.span(root), .base_dirs = &.{} };
    state.draw(cr, w, h, 0, 0, null, cfg, std.testing.io);
    c.cairo_surface_flush(surface);

    // Centre of the icon tile: the pack's artwork, not the built-in glyph.
    const g = state.geometry(w, h);
    const x: usize = @intFromFloat(g.box.x + 24 + 32);
    const y: usize = @intFromFloat(g.box.y + 66 + @max(0, @as(f32, @floatFromInt((@import("ui").window_chrome.Metrics{}).titlebarHeight())) - 49) + 32);
    const pixels: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    const stride: usize = @intCast(@divExact(c.cairo_image_surface_get_stride(surface), 4));
    const pixel = pixels[y * stride + x];
    try std.testing.expectEqual(@as(u32, 0xff00ff00), pixel);
}
