//! Chrome colours (borders and fill) and painting the window controls with SDF coverage.

const std = @import("std");
const sdf = @import("ui").sdf;
const col = @import("color.zig");
const geometry = @import("geometry.zig");
const theme = @import("ui").theme;
const text = @import("ui").text;
const window_chrome = @import("ui").window_chrome;
const btn_radius = window_chrome.control_radius;
const button_glyph_scale = window_chrome.button_glyph_scale;
const ControlKind = window_chrome.ControlKind;
const Rect = window_chrome.Rect;
const chrome_mod = @import("chrome.zig");
const controlSlot = chrome_mod.controlSlot;
const mix = chrome_mod.mix;

pub fn borderFill(hover: f32) Color {
    const t = clamp01(hover);
    if (t <= 0) return Color.border();
    if (t >= 1) return Color.border_hover();
    return Color.lerp(Color.border(), Color.border_hover(), t);
}

/// Straight border edges, matching the rasterized corner arcs.
pub fn borderColor(hover: f32) col.Premul {
    return borderFill(hover).straight().premultiply();
}

pub fn windowBorderFill(hover: f32, workspace_focus: bool) Color {
    return if (workspace_focus) Color.fromRgba(theme.global.workspace_active_border) else borderFill(hover);
}

pub fn windowBorderColor(hover: f32, workspace_focus: bool) col.Premul {
    return windowBorderFill(hover, workspace_focus).straight().premultiply();
}

/// Chrome backing beneath the border, shared by the header and client sides.
pub fn fillColor() col.Premul {
    return Color.chrome().straight().premultiply();
}

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // Decoration-specific colors leave the rest of the shell independent.
    pub fn chrome() Color {
        return fromRgba(theme.global.window_bg);
    }
    fn border() Color {
        return fromRgba(theme.global.window_border);
    }
    pub fn divider() Color {
        return fromRgba(theme.global.window_divider);
    }
    fn text_dim() Color {
        return fromRgba(theme.global.window_dim);
    }

    // .window:hover border, .win-btn:hover, .win-btn.close:hover and --text.
    fn border_hover() Color {
        return fromRgba(theme.global.window_border_hover);
    }
    fn control_hover() Color {
        return fromRgba(theme.global.surface_hover);
    }
    fn close_hover() Color {
        var c = fromRgba(theme.global.window_close_hover);
        c.a *= theme.global.window_close_hover_alpha;
        return c;
    }
    pub fn text() Color {
        return fromRgba(theme.global.window_fg);
    }
    fn textOnClose() Color {
        return Color.fromRgba(theme.global.window_close_fg);
    }

    pub fn fromRgba(rgba: [4]f32) Color {
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }

    // Unpacks a premultiplied 0xAARRGGBB sample (icon_cache.Entry.pixels'
    // format) back to this struct's straight alpha. Mirrors
    // Taskbar.Color.fromPremultiplied; the two Color types are private to
    // each file, so this is a small, deliberate duplicate rather than a
    // shared one.
    pub fn fromPremultiplied(sample: u32) Color {
        const a: f32 = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
        if (a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const r: f32 = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(sample & 0xff)) / 255.0;
        return .{ .r = r / a, .g = g / a, .b = b / a, .a = a };
    }

    pub fn over(source: Color, destination: Color) Color {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }

    pub fn lerp(from: Color, to: Color, t: f32) Color {
        return .{
            .r = from.r + (to.r - from.r) * t,
            .g = from.g + (to.g - from.g) * t,
            .b = from.b + (to.b - from.b) * t,
            .a = from.a + (to.a - from.a) * t,
        };
    }

    pub fn scaled(color: Color, alpha: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * alpha };
    }

    fn straight(color: Color) col.Straight {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    }

    pub fn argb(color: Color) u32 {
        return color.straight().argb();
    }
};

/// The window controls of one raster. Everything that does not depend on the
/// pixel (the chip's box and fill, the glyph inks) is worked out once, not for
/// every pixel of the control group.
pub const Controls = struct {
    min_btn: Rect,
    max_btn: Rect,
    close_btn: Rect,
    diag: f32,
    scale: f32,
    maximized: bool,
    glyph_scale: f32,
    // Every glyph lies within 7.6 glyph units of its button's centre (the
    // close cross's corners), and its ramp reaches 0.5 / (scale * glyph_scale)
    // beyond that: farther away on either axis its coverage is zero. 9 units
    // leave room for rounding.
    glyph_reach: f32,
    show_chip: bool,
    chip_x: f32 = 0,
    chip_y: f32 = 0,
    chip_width: f32 = 0,
    chip_height: f32 = 0,
    chip_radius: f32 = 0,
    chip_bevel: f32 = 0,
    chip_fill: Color = undefined,
    chip_alpha: f32 = 0,
    min_ink: Color,
    max_ink: Color,
    close_ink: Color,

    pub fn init(
        min_btn: Rect,
        max_btn: Rect,
        close_btn: Rect,
        chip_pos: f32,
        chip_alpha: f32,
        diag: f32,
        scale: f32,
        density: f32,
        maximized: bool,
    ) Controls {
        // Enlarge glyphs within the existing hover chips and hit targets.
        const glyph_scale = density * button_glyph_scale;
        var controls: Controls = .{
            .min_btn = min_btn,
            .max_btn = max_btn,
            .close_btn = close_btn,
            .diag = diag,
            .scale = scale,
            .maximized = maximized,
            .glyph_scale = glyph_scale,
            .glyph_reach = 9 * glyph_scale + 0.5 / scale,
            .show_chip = chip_alpha > 0,
            .min_ink = iconColor(chip_pos, chip_alpha, .minimize),
            .max_ink = iconColor(chip_pos, chip_alpha, .maximize),
            .close_ink = iconColor(chip_pos, chip_alpha, .close),
        };
        // Window-control hover chip, drawn under the glyph. One chip
        // slides between the buttons; its rect and red-ness are interpolated
        // from the slot coordinate.
        if (controls.show_chip) {
            const pos = std.math.clamp(chip_pos, 0, 2);
            const from_max = pos >= 1;
            const a_btn = if (from_max) max_btn else min_btn;
            const b_btn = if (from_max) close_btn else max_btn;
            const t = if (from_max) pos - 1 else pos;
            controls.chip_width = mix(@floatFromInt(a_btn.w), @floatFromInt(b_btn.w), t);
            controls.chip_height = mix(@floatFromInt(a_btn.h), @floatFromInt(b_btn.h), t);
            controls.chip_x = mix(@floatFromInt(a_btn.x), @floatFromInt(b_btn.x), t);
            controls.chip_y = mix(@floatFromInt(a_btn.y), @floatFromInt(b_btn.y), t);
            controls.chip_radius = window_chrome.cornerRadius(theme.global.chrome_round_buttons, controls.chip_width, controls.chip_height, btn_radius * density);
            controls.chip_bevel = theme.global.chrome_button_bevel * density;
            controls.chip_fill = Color.lerp(Color.control_hover(), Color.close_hover(), clamp01(pos - 1));
            controls.chip_alpha = clamp01(chip_alpha);
        }
        return controls;
    }

    fn reaches(c: *const Controls, btn: Rect, px: f32, py: f32) bool {
        return @abs(px - btn.centerX()) <= c.glyph_reach and @abs(py - btn.centerY()) <= c.glyph_reach;
    }

    pub fn paint(c: *const Controls, base: Color, px: f32, py: f32) Color {
        var color = base;
        if (c.show_chip) {
            const distance = if (c.chip_bevel > 0)
                sdf.sdBeveledBox(px, py, c.chip_x, c.chip_y, c.chip_width, c.chip_height, c.chip_bevel)
            else
                sdRoundedBox(px, py, c.chip_x, c.chip_y, c.chip_width, c.chip_height, c.chip_radius);
            const chip = edgeCoverage(distance, c.scale);
            if (chip > 0) color = c.chip_fill.scaled(chip * c.chip_alpha).over(color);
        }
        const g = c.glyph_scale;
        if (c.reaches(c.min_btn, px, py)) {
            const btn = c.min_btn;
            const min_cov = minimizeIconCoverage(btn.centerX() + (px - btn.centerX()) / g, btn.centerY() + (py - btn.centerY()) / g, btn, c.scale * g);
            if (min_cov > 0) color = c.min_ink.scaled(min_cov).over(color);
        }
        if (c.reaches(c.max_btn, px, py)) {
            const btn = c.max_btn;
            const max_cov = maximizeIconCoverage(btn.centerX() + (px - btn.centerX()) / g, btn.centerY() + (py - btn.centerY()) / g, btn, c.scale * g, c.maximized);
            if (max_cov > 0) color = c.max_ink.scaled(max_cov).over(color);
        }
        if (c.reaches(c.close_btn, px, py)) {
            const btn = c.close_btn;
            const close_cov = closeIconCoverage(btn.centerX() + (px - btn.centerX()) / g, btn.centerY() + (py - btn.centerY()) / g, btn, c.diag, c.scale * g);
            if (close_cov > 0) color = c.close_ink.scaled(close_cov).over(color);
        }
        return color;
    }
};

// Resting glyphs use neutral dim ink, --text on hover, #fff over close red.
pub fn iconColor(chip_pos: f32, chip_alpha: f32, kind: ControlKind) Color {
    // Keep the theme's dim brightness without its blue tint on the controls.
    const dim = Color.text_dim();
    const luminance = dim.r * 0.2126 + dim.g * 0.7152 + dim.b * 0.0722;
    const resting = Color{ .r = luminance, .g = luminance, .b = luminance, .a = dim.a };
    const weight = clamp01(1 - @abs(chip_pos - controlSlot(kind))) * clamp01(chip_alpha);
    return Color.lerp(resting, if (kind == .close) Color.textOnClose() else Color.text(), weight);
}

pub fn minimizeIconCoverage(px: f32, py: f32, btn: Rect, scale: f32) f32 {
    // A 12px dash at the lower edge of the glyph area.
    const cx = btn.centerX();
    const cy = btn.centerY() + 5;
    return edgeCoverage(sdRoundedBox(px, py, cx - 6, cy - 0.85, 12, 1.7, 0.85), scale);
}

pub fn maximizeIconCoverage(px: f32, py: f32, btn: Rect, scale: f32, maximized: bool) f32 {
    // A 10px outlined square, balanced against the dash and close glyph.
    const cx = btn.centerX();
    const cy = btn.centerY();
    if (!maximized) return outlineSquare(px, py, cx, cy, scale);
    // The lower-left window shows only its left and bottom edges, leaving
    // a clear gap around the complete upper-right window.
    const lower = edgeCoverage(@min(
        sdRoundedBox(px, py, cx - 7, cy - 3, 1.5, 10, 0.5),
        sdRoundedBox(px, py, cx - 7, cy + 5.5, 10, 1.5, 0.5),
    ), scale);
    return @max(lower, outlineSquare(px - 2, py + 2, cx, cy, scale));
}

pub fn outlineSquare(px: f32, py: f32, cx: f32, cy: f32, scale: f32) f32 {
    const outer = edgeCoverage(sdRoundedBox(px, py, cx - 5, cy - 5, 10, 10, 1), scale);
    const inner = edgeCoverage(sdRoundedBox(px, py, cx - 3.5, cy - 3.5, 7, 7, 0.5), scale);
    return clamp01(outer - inner);
}

pub const closeIconCoverage = window_chrome.closeIconCoverage;

// Shared with ui/paint.zig, which must not depend on the compositor.
pub const sdQuad = sdf.sdQuad;

pub const sdRoundedBox = sdf.sdRoundedBox;

pub const coverage = sdf.coverage;

// Same ramp, but for a distance measured in logical pixels while sampling on a
// denser grid: the edge stays one device pixel wide however far it is scaled.
pub inline fn edgeCoverage(distance: f32, scale: f32) f32 {
    return clamp01(0.5 - distance * scale);
}

pub fn devicePixels(logical: i32, scale: f32) i32 {
    return geometry.devicePixels(logical, scale);
}

pub inline fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}
