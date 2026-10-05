// Modal dialog chrome: the card, a header with an icon badge, title and
// subtitle, and an inset panel for the thing being acted on. The polkit
// prompt uses it; Files' delete confirmation has the same shape.
const std = @import("std");
const layout = @import("../layout.zig");
const theme = @import("../theme.zig");
const Renderer = @import("../paint.zig").Renderer;
const Rect = @import("field.zig").Rect;

const chrome = @import("../window_chrome.zig");

/// Position and pointer grab for a dialog embedded in its host's content.
/// Hosts send primary-button events and repaint when motion returns true.
pub const Placement = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    grab: ?struct { x: f64, y: f64 } = null,

    pub fn box(self: Placement, centered: Rect, w: i32, h: i32) Rect {
        var result = centered;
        result.x = std.math.clamp(centered.x + self.dx, 8, @max(8, @as(f32, @floatFromInt(w)) - centered.w - 8));
        result.y = std.math.clamp(centered.y + self.dy, 8, @max(8, @as(f32, @floatFromInt(h)) - centered.h - 8));
        return result;
    }

    pub fn button(self: *Placement, centered: Rect, w: i32, h: i32, x: f64, y: f64, pressed: bool) bool {
        if (!pressed) {
            const grabbed = self.grab != null;
            self.grab = null;
            return grabbed;
        }
        const placed = self.box(centered, w, h);
        const px = x - placed.x;
        const py = y - placed.y;
        const close = closeBox(placed.w);
        if (px < 0 or px >= placed.w or py < 0 or py >= @as(f64, @floatFromInt((chrome.Metrics{}).titlebarHeight()))) return false;
        if (px >= close.x and px < close.x + close.w and py >= close.y and py < close.y + close.h) return false;
        self.grab = .{ .x = px, .y = py };
        return true;
    }

    pub fn motion(self: *Placement, centered: Rect, w: i32, h: i32, x: f64, y: f64) bool {
        const grab = self.grab orelse return false;
        const old = self.box(centered, w, h);
        self.dx = @as(f32, @floatCast(x - grab.x)) - centered.x;
        self.dy = @as(f32, @floatCast(y - grab.y)) - centered.y;
        const placed = self.box(centered, w, h);
        self.dx = placed.x - centered.x;
        self.dy = placed.y - centered.y;
        return placed.x != old.x or placed.y != old.y;
    }
};

/// Keep the app visible while giving the modal focus.
pub fn backdropColor() [4]f32 {
    return theme.global.dialog_backdrop;
}
pub const badge: f32 = 66;
/// Badge's right edge to the title.
pub const title_gap: f32 = 22;

pub fn paintFrame(r: *Renderer, box: Rect) void {
    const t = r.palette orelse theme.global;
    // Raise an app card with the theme's soft surface tint. Composite it
    // here so the body stays opaque, including when the theme uses glass.
    const a = std.math.clamp(t.surface[3], 0, 1);
    const bg: [4]f32 = .{
        t.surface[0] * a + t.app_item[0] * (1 - a),
        t.surface[1] * a + t.app_item[1] * (1 - a),
        t.surface[2] * a + t.app_item[2] * (1 - a),
        1,
    };
    paintFrameWithBackground(r, box, bg);
}

/// App dialogs can share the host's menu background without the shell tint.
pub fn paintFrameWithBackground(r: *Renderer, box: Rect, bg: [4]f32) void {
    const t = r.palette orelse theme.global;
    r.fillRect(box.x, box.y, box.w, box.h, .{ .color = bg, .radius = t.radius_lg, .border_width = 1, .border_color = t.window_border });
}

/// An embedded window header: identical height, tint and radius to chrome.
/// Clip the full rounded frame to the title band so its lower edge stays flat.
pub fn paintTitlebar(r: *Renderer, box: Rect) void {
    const t = r.palette orelse theme.global;
    const height: f32 = @floatFromInt((chrome.Metrics{}).titlebarHeight());
    const old_clip = r.clip;
    r.clip = @import("../paint.zig").intersectClip(old_clip, .{ .x = box.x, .y = box.y, .w = box.w, .h = height });
    r.fillRect(box.x, box.y, box.w, box.h, .{
        .color = .{ t.window_bg[0], t.window_bg[1], t.window_bg[2], 1 },
        .radius = t.radius_lg,
        .border_width = chrome.frame_border,
        .border_color = t.window_border,
    });
    r.fillRect(box.x + 1, box.y + height - 1, box.w - 2, 1, .{ .color = t.window_divider });
    r.clip = old_clip;
}

/// Paint each band once, preserving antialiasing at the outer corners.
pub fn paintWindowFrame(r: *Renderer, box: Rect, background: ?[4]f32) void {
    paintTitlebar(r, box);
    const height: f32 = @floatFromInt((chrome.Metrics{}).titlebarHeight());
    const old_clip = r.clip;
    r.clip = @import("../paint.zig").intersectClip(old_clip, .{ .x = box.x, .y = box.y + height, .w = box.w, .h = @max(0, box.h - height) });
    if (background) |bg| paintFrameWithBackground(r, box, bg) else paintFrame(r, box);
    r.clip = old_clip;
}

pub fn closeBox(width: f32) Rect {
    const box = chrome.controlRect(@intFromFloat(width), .close);
    return .{ .x = @floatFromInt(box.x), .y = @floatFromInt(box.y), .w = @floatFromInt(box.w), .h = @floatFromInt(box.h) };
}

/// The app icon and title use the window's chrome metrics, leaving room for
/// its close control. Dialog bodies keep the app's own text sizes.
pub fn paintWindowTitle(r: *Renderer, box: Rect, title: []const u8, icon: layout.IconId, image: ?@import("../paint.zig").Image) void {
    const t = r.palette orelse theme.global;
    const metrics: chrome.Metrics = .{};
    const x = box.x + @as(f32, @floatFromInt(metrics.length(chrome.title_inset)));
    const size: f32 = @floatFromInt(metrics.iconSize());
    const height: f32 = @floatFromInt(metrics.titlebarHeight());
    const y = box.y + @floor((height - size) / 2);
    if (image) |im| r.drawImageCover(x, y, size, size, 0, im) else r.drawIcon(x, y, size, size, .{ .id = icon, .color = t.fg });
    const tx = x + size + @as(f32, @floatFromInt(metrics.length(chrome.title_icon_gap)));
    r.drawText(tx, box.y, @max(0, box.x + closeBox(box.w).x - tx - 8), height - 1, .{ .content = title, .font_size = t.title_size, .weight = 600, .color = t.fg });
}

pub const Header = struct {
    icon: layout.IconId,
    title: []const u8,
    subtitle: []const u8 = "",
    /// Null is the palette's muted `dim`.
    subtitle_color: ?[4]f32 = null,
};

/// Badge at `x`, `y`; title and subtitle beside it, within `w`.
pub fn paintHeader(r: *Renderer, x: f32, y: f32, w: f32, header: Header) void {
    const t = r.palette orelse theme.global;
    const a = t.accent;
    r.fillRect(x, y, badge, badge, .{ .color = .{ a[0], a[1], a[2], a[3] * t.dialog_badge_alpha }, .radius = t.dialog_badge_radius });
    // The accent lifted toward white so the glyph reads on its own tint.
    const glyph: [4]f32 = .{ a[0] + (1 - a[0]) * t.dialog_glyph_lift, a[1] + (1 - a[1]) * t.dialog_glyph_lift, a[2] + (1 - a[2]) * t.dialog_glyph_lift, a[3] };
    r.drawIcon(x + 15, y + 14, 36, 36, .{ .id = header.icon, .color = glyph });
    const tx = x + badge + title_gap;
    const tw = @max(0, w - badge - title_gap);
    r.drawText(tx, y, tw, 38, .{ .content = header.title, .font_size = t.dialog_title_size, .weight = 600, .color = t.fg });
    if (header.subtitle.len > 0) r.drawText(tx, y + 39, tw, 26, .{ .content = header.subtitle, .font_size = t.dialog_subtitle_size, .color = header.subtitle_color orelse t.dim });
}

/// The panel holding what the dialog is about (an account, a file).
pub fn paintInset(r: *Renderer, box: Rect) void {
    const t = r.palette orelse theme.global;
    r.fillRect(box.x, box.y, box.w, box.h, .{ .color = t.surface, .radius = t.dialog_inset_radius });
}

test "header badge takes an accent tint and the frame opaque app colours" {
    var pixels: [200 * 100]u32 = @splat(0);
    var r = Renderer.init(&pixels, 200, 100, 1);
    var t: theme.Theme = .{};
    t.window_bg = .{ 1, 1, 1, 1 };
    t.app_item = .{ 0, 0, 0, 0.2 };
    t.radius_lg = 10;
    t.surface = .{ 1, 1, 1, 0 };
    t.accent = .{ 1, 0, 0, 1 };
    r.palette = t;
    paintFrame(&r, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[50 * 200 + 100]);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
    // The radius follows window chrome rather than the old fixed 18 px.
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[12 * 200 + 1]);
    paintHeader(&r, 10, 10, 180, .{ .icon = .lock, .title = "" });
    // Badge's straight top edge, clear of the glyph: red at 18% over black.
    const tint = pixels[12 * 200 + 40];
    try std.testing.expect((tint >> 16) & 0xff > 30 and (tint >> 16) & 0xff < 60);
    try std.testing.expectEqual(@as(u32, 0), tint & 0xffff);
}
