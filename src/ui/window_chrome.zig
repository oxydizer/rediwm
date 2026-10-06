//! Window decoration geometry and close glyph shared by compositor chrome
//! and app dialogs. No compositor or Wayland dependencies.
const std = @import("std");
const theme = @import("theme.zig");
const sdf = @import("sdf.zig");
const sdRoundedBox = sdf.sdRoundedBox;
pub const title_inset: i32 = 18;
pub const title_icon_size: i32 = 22;
pub const title_icon_gap: i32 = 10;
const icon_scale: f32 = 1.11;
pub const button_glyph_scale: f32 = icon_scale * 1.1;
pub const control_radius: f32 = 4;
/// Round chrome uses half the shorter side: circles for controls, pills for tabs.
pub fn cornerRadius(round: bool, width: f32, height: f32, default_radius: f32) f32 {
    return if (round) @min(width, height) / 2 else default_radius;
}

pub const ControlKind = enum { minimize, maximize, close };

// Charcoal header with evenly spaced, unboxed window controls.
pub const frame_border: i32 = 1;
const titlebar_pad_right: i32 = 12;
const btn_size: i32 = 34;
const close_size: i32 = 34;
// Preserve the original icon/control proportions when changing bar height.
const reference_titlebar_height: f32 = 55;
// Decoration density and the user-selected height are independent of output raster scale.
pub const Metrics = struct {
    density: f32 = 1,

    pub fn contentScale(self: Metrics) f32 {
        return self.density * theme.global.chrome_height / reference_titlebar_height;
    }

    pub fn length(self: Metrics, value: i32) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(value)) * self.contentScale()))));
    }

    pub fn iconSize(self: Metrics) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(title_icon_size)) * self.contentScale() * icon_scale))));
    }

    pub fn titlebarHeight(self: Metrics) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(theme.global.chrome_height * self.density))));
    }

    pub fn controlGap(self: Metrics) i32 {
        return @as(i32, @intFromFloat(@round(theme.global.chrome_control_gap * self.density)));
    }
};

pub fn frameRadius() f32 {
    return theme.global.radius_lg;
}

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(rect: Rect, px: f64, py: f64) bool {
        return px >= @as(f64, @floatFromInt(rect.x)) and
            px < @as(f64, @floatFromInt(rect.x + rect.w)) and
            py >= @as(f64, @floatFromInt(rect.y)) and
            py < @as(f64, @floatFromInt(rect.y + rect.h));
    }

    pub fn centerX(rect: Rect) f32 {
        return @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w)) / 2;
    }

    pub fn centerY(rect: Rect) f32 {
        return @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) / 2;
    }
};

pub fn controlRect(frame_width: i32, kind: ControlKind) Rect {
    return controlRectScaled(frame_width, kind, 1);
}

pub fn controlRectScaled(frame_width: i32, kind: ControlKind, density: f32) Rect {
    const m: Metrics = .{ .density = density };
    const close_x = frame_width - frame_border - m.length(titlebar_pad_right) - m.length(close_size);
    const max_x = close_x - m.controlGap() - m.length(btn_size);
    const min_x = max_x - m.controlGap() - m.length(btn_size);
    return switch (kind) {
        .close => .{
            .x = close_x,
            .y = @divTrunc(m.titlebarHeight() - m.length(close_size), 2),
            .w = m.length(close_size),
            .h = m.length(close_size),
        },
        .maximize => .{
            .x = max_x,
            .y = @divTrunc(m.titlebarHeight() - m.length(btn_size), 2),
            .w = m.length(btn_size),
            .h = m.length(btn_size),
        },
        .minimize => .{
            .x = min_x,
            .y = @divTrunc(m.titlebarHeight() - m.length(btn_size), 2),
            .w = m.length(btn_size),
            .h = m.length(btn_size),
        },
    };
}

pub fn closeIconCoverage(px: f32, py: f32, btn: Rect, diag: f32, scale: f32) f32 {
    // Match the other controls with a compact, 12px diagonal cross.
    const cx = btn.centerX();
    const cy = btn.centerY();
    const d = @min(
        sdOrientedBox(px, py, cx, cy, 7.5, 0.95, diag, diag),
        sdOrientedBox(px, py, cx, cy, 7.5, 0.95, diag, -diag),
    );
    return edgeCoverage(d, scale);
}

inline fn sdOrientedBox(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32, cos_a: f32, sin_a: f32) f32 {
    const dx = px - cx;
    const dy = py - cy;
    const rx = cos_a * dx + sin_a * dy;
    const ry = -sin_a * dx + cos_a * dy;
    const qx = @abs(rx) - half_w;
    const qy = @abs(ry) - half_h;
    const outside_x = @max(qx, 0);
    const outside_y = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(outside_x * outside_x + outside_y * outside_y);
}

// Same ramp, but for a distance measured in logical pixels while sampling on a
// denser grid: the edge stays one device pixel wide however far it is scaled.
inline fn edgeCoverage(distance: f32, scale: f32) f32 {
    return clamp01(0.5 - distance * scale);
}

inline fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}
