// A person's picture: their image centre-cropped into a circle, or a head
// and shoulders silhouette. Shared by the lock/greeter and the polkit dialog.
const std = @import("std");
const theme = @import("../theme.zig");
const paint_mod = @import("../paint.zig");
const Renderer = paint_mod.Renderer;

pub const Options = struct {
    image: ?paint_mod.Image = null,
    /// A hairline ring around the circle (the lock's large avatar).
    ring: bool = false,
};

/// A `size`-wide circle with its top-left corner at `x`, `y`.
pub fn paint(r: *Renderer, x: f32, y: f32, size: f32, opts: Options) void {
    const t = r.palette orelse theme.global;
    r.fillRect(x, y, size, size, .{
        .color = t.surface_hover,
        .radius = size / 2,
        .border_width = if (opts.ring) size / 80 else 0,
        .border_color = t.dim,
    });
    if (opts.image) |image| {
        // Inside the ring rather than over it.
        const inset: f32 = if (opts.ring) size / 60 else 0;
        const inner = size - 2 * inset;
        r.drawImageCover(x + inset, y + inset, inner, inner, inner / 2, image);
        return;
    }
    const head = size * 0.28;
    r.fillRect(x + (size - head) / 2, y + size * 0.21, head, head, .{ .color = t.dim, .radius = head / 2 });
    const body_w = size * 0.55;
    const body_h = size * 0.29;
    r.fillRect(x + (size - body_w) / 2, y + size * 0.55, body_w, body_h, .{ .color = t.dim, .radius = body_h / 2 });
}

test "an image is centre-cropped into the circle" {
    // A wide image: red left third, green middle, blue right third. Covering
    // a square crops the sides, so the circle's centre and its left and right
    // edges all land in the green middle.
    var src: [9 * 3]u32 = undefined;
    for (0..3) |row| for (0..9) |col| {
        src[row * 9 + col] = if (col < 3) 0xffff0000 else if (col < 6) 0xff00ff00 else 0xff0000ff;
    };
    var pixels: [30 * 30]u32 = @splat(0);
    var r = Renderer.init(&pixels, 30, 30, 1);
    paint(&r, 0, 0, 30, .{ .image = .{ .pixels = &src, .width = 9, .height = 3 } });
    try std.testing.expectEqual(@as(u32, 0xff00ff00), pixels[15 * 30 + 15]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), pixels[15 * 30 + 2]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), pixels[15 * 30 + 27]);
    // Corners stay outside the circle.
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
}

test "without an image the silhouette is drawn in the dim colour" {
    var pixels: [40 * 40]u32 = @splat(0);
    var r = Renderer.init(&pixels, 40, 40, 1);
    var t: theme.Theme = .{};
    t.dim = .{ 0, 0, 1, 1 };
    t.surface_hover = .{ 0, 0, 0, 0 };
    r.palette = t;
    paint(&r, 0, 0, 40, .{});
    // Head centre and body centre.
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[@as(usize, 14) * 40 + 20]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[@as(usize, 28) * 40 + 20]);
    try std.testing.expectEqual(@as(u32, 0), pixels[@as(usize, 20) * 40 + 3]);
}
