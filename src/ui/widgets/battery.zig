//! The battery badge: a rounded frame holding a battery glyph (outline, cap,
//! level fill), the percentage and, on external power, a charging bolt. The
//! taskbar's look, shared so anything else that shows a battery draws the same
//! one.
//!
//! Stateless like the other painters here. `sample` is the artwork itself, one
//! device pixel at a time in the badge's own logical units, so a host that
//! rasterizes per pixel (the taskbar) and `paint` (any `Renderer`) cannot
//! drift apart. The caller owns the data: it hides the badge when no battery is
//! present, and it owns the connection shimmer's clock (`Spec.shimmer`).
//!
//! The badge is `width` logical pixels wide. Its height is the host's (the
//! taskbar uses its tray height, `default_height` at the defaults); the glyph
//! stays centred and the frame stretches.
const std = @import("std");
const paint_mod = @import("../paint.zig");
const sdf = @import("../sdf.zig");
const text = @import("../text.zig");
const theme = @import("../theme.zig");

pub const width = 112;
pub const default_height: f32 = 34;
/// The percentage's cell, for hosts that draw the label themselves.
pub const label_x: f32 = 45;
pub const label_w: f32 = 43;
pub const label_size: f32 = 14;

/// Charge at or below which the fill turns red, then amber.
pub const critical_percent = 10;
pub const low_percent = 25;

pub const Spec = struct {
    percent: u8,
    /// External power: draws the bolt.
    plugged: bool = false,
    /// Progress of the one-shot "connected" sweep along the frame, 0..1.
    /// 1 (or 0) is at rest; the sweep starts and ends outside the badge.
    shimmer: f32 = 1,
    height: f32 = default_height,
    /// Draw the percentage (`paint` only; `sample` never draws text).
    label: bool = true,
};

/// Palette for the badge, shared by its pixel and Renderer paths.
pub const Colors = struct {
    border: [4]f32,
    fg: [4]f32,
    bg: [4]f32,
    full: [4]f32,
    low: [4]f32,
    critical: [4]f32,
    shimmer: [4]f32,

    pub fn of(t: theme.Theme) Colors {
        return .{ .border = t.taskbar_border, .fg = t.window_fg, .bg = t.battery_bg, .full = t.battery_full, .low = t.battery_low, .critical = t.battery_critical, .shimmer = t.battery_shimmer };
    }
};

/// Straight (not premultiplied) colour.
pub const Rgba = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    fn scaled(c: Rgba, alpha: f32) Rgba {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = std.math.clamp(c.a * alpha, 0, 1) };
    }

    fn over(source: Rgba, destination: Rgba) Rgba {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }

    fn ink(c: Rgba) text.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
};

const green = rgb(32, 226, 157);
const amber = rgb(250, 204, 65);
const red = rgb(245, 75, 85);

/// The fill colour for a charge.
pub fn levelColor(percent: u8) Rgba {
    return paletteLevelColor(percent, Colors.of(theme.global));
}

fn paletteLevelColor(percent: u8, colors: Colors) Rgba {
    return fromArray(if (percent <= critical_percent) colors.critical else if (percent <= low_percent) colors.low else colors.full);
}

/// The badge at logical point (`x`, `y`) measured from its top-left corner,
/// for a device grid of `scale`. Transparent outside the artwork.
pub fn sample(x: f32, y: f32, scale: f32, spec: Spec, colors: Colors) Rgba {
    const w: f32 = width;
    // The glyph is authored around y=17 of the default 34 px frame and stays
    // centred however tall the host makes the frame.
    const gy = y - spec.height / 2 + 17;
    const outer = edge(sdf.sdRoundedBox(x, y, 0.5, 0.5, w - 1, spec.height - 1, 5), scale);
    const inner = edge(sdf.sdRoundedBox(x, y, 1.5, 1.5, w - 3, spec.height - 3, 4), scale);
    var color = fromArray(colors.border).scaled(outer - inner);
    color = fromArray(colors.bg).scaled(inner).over(color);
    color = fromArray(colors.shimmer).scaled(shimmerIntensity(spec.shimmer, x, w) * (outer - inner)).over(color);

    const body = edge(sdf.sdRoundedBox(x, gy, 10, 10, 27, 14, 2.5), scale);
    const hollow = edge(sdf.sdRoundedBox(x, gy, 11.5, 11.5, 24, 11, 1), scale);
    const cap = edge(sdf.sdRoundedBox(x, gy, 37, 14, 2.5, 6, 0.8), scale);
    color = fromArray(colors.fg).scaled(@max(body - hollow, cap) * 0.85).over(color);

    const percent = @min(spec.percent, 100);
    if (percent > 0) {
        const level = edge(sdf.sdRoundedBox(x, gy, 13, 13, 21 * @as(f32, @floatFromInt(percent)) / 100, 8, 0.8), scale);
        color = paletteLevelColor(percent, colors).scaled(level).over(color);
    }
    if (spec.plugged) color = fromArray(colors.full).scaled(edge(boltDistance(x - 93, gy - 7), scale)).over(color);
    return color;
}

/// A single band of light sliding along the frame, narrow and smooth, whose
/// ends start and finish entirely outside the badge. The caller clips this to
/// the frame, leaving the contents alone.
pub fn shimmerIntensity(progress: f32, x: f32, badge_width: f32) f32 {
    if (progress <= 0 or progress >= 1) return 0;
    const half_width: f32 = 23;
    const center = -half_width + progress * (badge_width + 2 * half_width);
    const t = @max(0, 1 - @abs(x - center) / half_width);
    return 0.7 * t * t * (3 - 2 * t);
}

/// Paints the badge with its top-left at (`x`, `y`) in the renderer's logical
/// units, blended over what is there. Palette comes from the renderer.
pub fn paint(r: *paint_mod.Renderer, x: f32, y: f32, spec: Spec) void {
    r.clean = false;
    const s = r.scale;
    const t = r.palette orelse theme.global;
    const colors = Colors.of(t);
    var x0: f32 = x * s;
    var y0: f32 = y * s;
    var x1: f32 = (x + width) * s;
    var y1: f32 = (y + spec.height) * s;
    if (r.effectiveClip()) |c| {
        x0 = @max(x0, c.x * s);
        y0 = @max(y0, c.y * s);
        x1 = @min(x1, (c.x + c.w) * s);
        y1 = @min(y1, (c.y + c.h) * s);
    }
    const left: i32 = @intFromFloat(@floor(@max(0, x0)));
    const top: i32 = @intFromFloat(@floor(@max(0, y0)));
    const right: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), x1)));
    const bottom: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), y1)));
    var py = top;
    while (py < bottom) : (py += 1) {
        const ly = (@as(f32, @floatFromInt(py)) + 0.5) / s - y;
        var px = left;
        while (px < right) : (px += 1) {
            const lx = (@as(f32, @floatFromInt(px)) + 0.5) / s - x;
            const color = sample(lx, ly, s, spec, colors);
            if (color.a <= 0) continue;
            text.blendPixel(&r.pixels[@intCast(py * r.width + px)], color.ink(), 1);
        }
    }
    if (!spec.label) return;
    var buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d}%", .{@min(spec.percent, 100)}) catch return;
    text.drawOpts(r.pixels, r.width, r.height, label, fromArray(colors.fg).ink(), s, .manrope, label_size, .{
        .rect = .{
            .x = @intFromFloat(@round(x + label_x)),
            .y = @intFromFloat(@round(y)),
            .w = @intFromFloat(label_w),
            .h = @intFromFloat(@round(spec.height)),
        },
        .center_ink = true,
        .device_clip = .{ .x = left, .y = top, .w = @max(0, right - left), .h = @max(0, bottom - top) },
    }) catch {};
}

/// Signed distance to the charging bolt, negative inside.
fn boltDistance(x: f32, y: f32) f32 {
    const points = [_][2]f32{ .{ 8, 0 }, .{ 1, 11 }, .{ 6, 11 }, .{ 4, 20 }, .{ 12, 8 }, .{ 7, 8 } };
    var inside = false;
    var distance: f32 = 1e10;
    for (points, 0..) |a, i| {
        const b = points[(i + 1) % points.len];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const t = std.math.clamp(((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy), 0, 1);
        distance = @min(distance, @sqrt(std.math.pow(f32, x - a[0] - t * dx, 2) + std.math.pow(f32, y - a[1] - t * dy, 2)));
        if ((a[1] > y) != (b[1] > y) and x < a[0] + (y - a[1]) * dx / dy) inside = !inside;
    }
    return if (inside) -distance else distance;
}

fn edge(distance: f32, scale: f32) f32 {
    return std.math.clamp(0.5 - distance * scale, 0, 1);
}

fn rgb(r: u8, g: u8, b: u8) Rgba {
    return .{ .r = @as(f32, @floatFromInt(r)) / 255.0, .g = @as(f32, @floatFromInt(g)) / 255.0, .b = @as(f32, @floatFromInt(b)) / 255.0, .a = 1 };
}

fn fromArray(c: [4]f32) Rgba {
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
}

test "the fill follows the charge and changes colour at the thresholds" {
    const colors = Colors.of(.{});
    const mid = 17; // the glyph's centre row at the default height
    for ([_]struct { percent: u8, want: Rgba }{
        .{ .percent = 5, .want = red },
        .{ .percent = 20, .want = amber },
        .{ .percent = 80, .want = green },
    }) |case| {
        const px = sample(13.5, mid, 1, .{ .percent = case.percent }, colors);
        try std.testing.expectApproxEqAbs(case.want.r, px.r, 0.02);
        try std.testing.expectApproxEqAbs(case.want.g, px.g, 0.02);
        try std.testing.expectApproxEqAbs(case.want.b, px.b, 0.02);
    }
    // Half full: the fill reaches about the middle of its 21 px well.
    const filled = sample(20, mid, 1, .{ .percent = 50 }, colors);
    const empty = sample(30, mid, 1, .{ .percent = 50 }, colors);
    try std.testing.expect(filled.g > 0.6 and empty.g < 0.3);
}

test "the bolt appears only on external power and the glyph stays centred in a taller frame" {
    const colors = Colors.of(.{});
    const bolt = sample(99, 17, 1, .{ .percent = 50, .plugged = true }, colors);
    try std.testing.expect(bolt.a > 0.9 and bolt.g > 0.8 and bolt.r < 0.2);
    try std.testing.expect(sample(99, 17, 1, .{ .percent = 50 }, colors).g < 0.3);
    const tall = sample(14, 30, 1, .{ .percent = 80, .height = 60 }, colors);
    try std.testing.expect(tall.g > 0.7);
}

test "paint draws the same artwork as sample, clipped to the badge, with the label optional" {
    const scale: f32 = 1.5;
    const w: i32 = @intFromFloat(@ceil((width + 20) * scale));
    const h: i32 = @intFromFloat(@ceil((default_height + 20) * scale));
    const plain = try std.testing.allocator.alloc(u32, @intCast(w * h));
    defer std.testing.allocator.free(plain);
    const labelled = try std.testing.allocator.alloc(u32, plain.len);
    defer std.testing.allocator.free(labelled);
    @memset(plain, 0);
    @memset(labelled, 0);
    var r = paint_mod.Renderer.init(plain, w, h, scale);
    paint(&r, 10, 10, .{ .percent = 80, .plugged = true, .label = false });
    var rl = paint_mod.Renderer.init(labelled, w, h, scale);
    paint(&rl, 10, 10, .{ .percent = 80, .plugged = true });
    // Nothing outside the frame.
    try std.testing.expectEqual(@as(u32, 0), plain[0]);
    try std.testing.expectEqual(@as(u32, 0), plain[plain.len - 1]);
    // A glyph pixel matches `sample` through the same blend.
    const px: i32 = @intFromFloat((10 + 14) * scale);
    const py: i32 = @intFromFloat((10 + 17) * scale);
    const want = sample((@as(f32, @floatFromInt(px)) + 0.5) / scale - 10, (@as(f32, @floatFromInt(py)) + 0.5) / scale - 10, scale, .{ .percent = 80, .plugged = true }, Colors.of(theme.global));
    var expected: u32 = 0;
    text.blendPixel(&expected, want.ink(), 1);
    try std.testing.expectEqual(expected, plain[@intCast(py * w + px)]);
    // The label adds ink inside its cell and nowhere else.
    var changed_inside = false;
    for (0..@intCast(h)) |iy| for (0..@intCast(w)) |ix| {
        const i = iy * @as(usize, @intCast(w)) + ix;
        if (plain[i] == labelled[i]) continue;
        const lx = (@as(f32, @floatFromInt(ix)) + 0.5) / scale - 10;
        try std.testing.expect(lx >= label_x - 1 and lx <= label_x + label_w + 1);
        changed_inside = true;
    };
    try std.testing.expect(changed_inside);
    // A scrolling host clips the percentage as well as the raster artwork.
    @memset(labelled, 0);
    rl.clip = .{ .x = 10, .y = 10, .w = 30, .h = default_height };
    paint(&rl, 10, 10, .{ .percent = 80 });
    for (0..@intCast(h)) |iy| for (0..@intCast(w)) |ix| {
        if (ix >= 60) try std.testing.expectEqual(@as(u32, 0), labelled[iy * @as(usize, @intCast(w)) + ix]);
    };
}
