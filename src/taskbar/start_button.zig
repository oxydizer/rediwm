// The start button that opens/closes the start menu: geometry, idle/hover/
// press/open state machine, and the SDF body/indicator plugged into
// Taskbar.render()'s per-pixel loop. The logo (bundled Redi SVG or configured path) is composited
// by Taskbar, not here. This module owns no wlroots objects; Taskbar owns the
// `State` instance and drives it the same way it drives ChipState/TrayState.
//
// The button's own size, the icon size within it, its left inset and its gap
// to the first chip are all theme-driven and can change at runtime (taskbar
// size, item gap, start button settings), so unlike the fixed constants this
// module used to export, every geometry function here takes them as explicit
// parameters supplied by Taskbar (the one place that reads `ui_theme.global`
// for taskbar layout).
const anim = @import("ui").anim;
const chrome = @import("../chrome.zig");

const Anim = anim.Anim;

const theme = @import("ui").theme;
// Fallback glyph size when the logo cannot be rasterized.
pub const glyph_size_px: f32 = 19;
pub const builtin_logo = "builtin:redi-logo";

const indicator_diameter: f32 = 4;
const indicator_gap: f32 = 9;
pub fn top(bar_height: i32, btn_size: i32) f32 {
    return @floatFromInt(@divTrunc(bar_height - btn_size, 2));
}

pub const State = struct {
    hover: Anim = .{},
    open_amt: Anim = .{},
    open: bool = false,

    pub fn animating(state: State, now_ms: i64) bool {
        return !state.hover.settled(now_ms) or !state.open_amt.settled(now_ms);
    }
};

pub fn hitTest(sx: f64, sy: f64, bar_height: i32, edge_pad: i32, btn_size: i32) bool {
    const t: f64 = top(bar_height, btn_size);
    return sx >= @as(f64, @floatFromInt(edge_pad)) and sx < @as(f64, @floatFromInt(edge_pad + btn_size)) and
        sy >= t and sy < t + @as(f64, @floatFromInt(btn_size));
}

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    fn fromRgba(c: [4]f32) Color {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }

    pub fn scaled(c: Color, alpha: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * alpha };
    }
};

fn sdCircle(px: f32, py: f32, cx: f32, cy: f32, r: f32) f32 {
    return @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)) - r;
}

fn edgeCoverage(distance: f32, scale: f32) f32 {
    return @max(0, @min(1, 0.5 - distance * scale));
}

/// Fixed coordinates shared by the logo blit and the button body.
pub const Mapped = struct {
    x: f32,
    y: f32,
    box_x: f32,
    box_y: f32,
};

pub const Paint = struct {
    hover: f32,
    open_amt: f32,

    pub fn init(state: State, now_ms: i64) Paint {
        return .{ .hover = state.hover.value(now_ms), .open_amt = state.open_amt.value(now_ms) };
    }
};

pub fn mapPoint(_: Paint, px: f32, py: f32, bar_height: i32, edge_pad: i32, btn_size: i32) Mapped {
    return .{
        .x = px,
        .y = py,
        .box_x = @floatFromInt(edge_pad),
        .box_y = top(bar_height, btn_size),
    };
}

/// Per-pixel contribution for the button body and its open-indicator dot, in
/// logical taskbar-strip coordinates (origin at the bar's top-left), matching
/// the rest of Taskbar.render()'s per-pixel loop. Null outside both regions.
pub fn paintPixel(state: Paint, px: f32, py: f32, bar_height: i32, scale: f32, edge_pad: i32, btn_size: i32) ?Color {
    const fsize: f32 = @floatFromInt(btn_size);
    const base_top = top(bar_height, btn_size);
    const base_left: f32 = @floatFromInt(edge_pad);

    const open_amt = state.open_amt;
    if (open_amt > 0) {
        const dot_cx = base_left + fsize / 2;
        const dot_cy = base_top + fsize + indicator_gap + indicator_diameter / 2;
        const cov = edgeCoverage(sdCircle(px, py, dot_cx, dot_cy, indicator_diameter / 2), scale);
        if (cov > 0) return Color.fromRgba(theme.taskbar(.start_button_indicator)).scaled(cov * open_amt);
    }

    const mapped = mapPoint(state, px, py, bar_height, edge_pad, btn_size);
    const box_x = mapped.box_x;
    const box_y = mapped.box_y;
    const lx = mapped.x;
    const ly = mapped.y;

    const cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, box_x, box_y, fsize, fsize, theme.global.start_button_radius), scale);
    if (cov <= 0) return null;

    const highlight = @max(state.hover, open_amt);
    return Color.fromRgba(theme.taskbar(.start_button_hover)).scaled(cov * highlight);
}
