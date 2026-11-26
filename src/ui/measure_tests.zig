const std = @import("std");
const layout = @import("layout.zig");
const measure = @import("measure.zig");
const arrange = @import("arrange.zig").arrange;
const paint = @import("paint.zig");
const text = @import("text.zig");

// Render through the normal widget passes and compare with the expected string
// drawn at the same origin and baseline with room for every glyph.
fn expectLabel(style: layout.TextStyle, width: layout.SizeConstraint, scale: f32, expected: []const u8) !void {
    errdefer std.debug.print("\nlabel \"{s}\" at {d}x, expected \"{s}\"\n", .{ style.content, scale, expected });
    var labels = [_]layout.Widget{.{ .kind = .{ .text = style }, .width = width }};
    var column: layout.Widget = .{ .kind = .container, .direction = .column, .children = &labels };
    column.linkParents();
    measure.measureAtScale(&column, 480, 36, scale);
    arrange(&column, 1, 0, 480, 36);
    const w = text.devicePixels(482, scale);
    const h = text.devicePixels(36, scale);
    const actual = try std.testing.allocator.alloc(u32, @intCast(w * h));
    defer std.testing.allocator.free(actual);
    const reference = try std.testing.allocator.alloc(u32, actual.len);
    defer std.testing.allocator.free(reference);
    @memset(actual, 0);
    @memset(reference, 0);
    var renderer = paint.Renderer.init(actual, w, h, scale);
    paint.paint(&column, &renderer);
    const rect: text.Rect = .{ .x = 1, .y = 0, .w = 480, .h = @intFromFloat(@round(labels[0].computed_height)) };
    try text.drawOpts(reference, w, h, expected, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, scale, paint.fontFor(style), style.font_size, .{ .rect = rect, .ellipsize = false });
    try std.testing.expect(!std.mem.allEqual(u32, reference, 0));
    try std.testing.expectEqualSlices(u32, reference, actual);
}

test "auto-width menu and Settings labels paint the complete text at their raster scale" {
    const white = [4]f32{ 1, 1, 1, 1 };
    const styles = [_]layout.TextStyle{
        .{ .content = "Software Center", .font_size = 11.5, .color = white },
        .{ .content = "Configuration editor for dconf", .font_size = 11.5, .color = white },
        .{ .content = "DB Browser for SQLite is a light GUI editor for SQLite databases", .font_size = 11.5, .color = white },
        .{ .content = "Keyboard Shortcuts", .font_size = 14, .weight = 600, .color = white },
    };
    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }) |scale| {
        for (styles) |style| try expectLabel(style, .auto, scale, style.content);
    }
}

test "a constrained label paints a fitting prefix followed by the ellipsis" {
    const style: layout.TextStyle = .{ .content = "MMMMMMMMMMMM", .family = .mono, .font_size = 13, .color = .{ 1, 1, 1, 1 } };
    const expected = "MMMMM…";
    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }) |scale| {
        const width = try text.measureWidth(expected, .mono, style.font_size, scale);
        try expectLabel(style, .{ .fixed = @floatFromInt(width + 1) }, scale, expected);
    }
}

test "a centered Settings button gives its semibold label the full measured width" {
    const button = @import("widgets/button.zig");
    const palette = @import("theme.zig").global;
    const label = "Keyboard Shortcuts";
    const size = button.metrics(.md, palette).font_size;
    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }) |scale| {
        const width = try text.measureWidth(label, .manrope_bold, size, scale);
        // Two spare logical pixels place the label one pixel in from the edge.
        const w = text.devicePixels(width + 2, scale);
        const h = text.devicePixels(32, scale);
        const actual = try std.testing.allocator.alloc(u32, @intCast(w * h));
        defer std.testing.allocator.free(actual);
        const expected = try std.testing.allocator.alloc(u32, actual.len);
        defer std.testing.allocator.free(expected);
        @memset(actual, 0);
        @memset(expected, 0);
        var renderer = paint.Renderer.init(actual, w, h, scale);
        button.paintContent(&renderer, .{ .x = 0, .y = 0, .w = @floatFromInt(width + 2), .h = 32 }, .{ .label = label }, .{});
        const rect: text.Rect = .{ .x = 1, .y = 0, .w = width + 1, .h = 32 };
        try text.drawOpts(expected, w, h, label, paint.toColor(palette.fg), scale, .manrope_bold, size, .{ .rect = rect, .ellipsize = false });
        try std.testing.expectEqualSlices(u32, expected, actual);
    }
}
