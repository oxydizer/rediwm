// Pass 3 of the UI layout engine: walks the tree in paint order (parent
// before children, so later siblings/children overdraw earlier ones) and
// rasterizes it into a plain CPU pixel buffer — the same `[]u32`
// premultiplied-on-store ARGB8888 convention as chrome.zig/Taskbar.zig/
// ImageBuffer.zig, so the result hands straight to a `wlr.Buffer` the way
// those already do. There is no separate GPU "Renderer" type in this
// codebase to target; `Renderer` here fills that role for shell chrome.
const std = @import("std");

const layout = @import("layout.zig");

const log = std.log.scoped(.ui_paint);
const Widget = layout.Widget;
const RectStyle = layout.RectStyle;
const TextStyle = layout.TextStyle;
const IconStyle = layout.IconStyle;
const IconId = layout.IconId;
const ButtonData = layout.ButtonData;
const CheckboxData = layout.CheckboxData;
const TextInputData = layout.TextInputData;
const ScrollState = layout.ScrollState;
const ToggleData = layout.ToggleData;
const SliderData = layout.SliderData;
const SegmentedData = layout.SegmentedData;
const SwatchData = layout.SwatchData;
const StepperData = layout.StepperData;
const ImageData = layout.ImageData;
const RowData = layout.RowData;

const anim = @import("anim.zig");
const text_mod = @import("text.zig");
const sdf = @import("sdf.zig");
const theme = @import("theme.zig");
const ui_input = @import("input.zig");
const field_widget = @import("widgets/field.zig");
const button_widget = @import("widgets/button.zig");
const checkbox_widget = @import("widgets/checkbox.zig");
const scrollbar = @import("widgets/scrollbar.zig");

/// A logical-pixel clip rectangle, intersected as scroll containers nest.
pub const ClipRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Premultiplied 0xAARRGGBB pixels, row-major without padding.
pub const Image = struct { pixels: []const u32, width: i32, height: i32 };

fn fontFor(style: TextStyle) text_mod.Font {
    return switch (style.family) {
        .sans => if (style.weight >= 600) .manrope_bold else .manrope,
        .mono => if (style.weight >= 600) .mono_bold else .mono,
    };
}

/// Geometry + colours of one rounded-rect fill, so the general (edge and
/// corner) shading path can be shared by the spans on either side of the
/// interior fast path without repeating it.
const RoundedFill = struct {
    box_x: f32,
    box_y: f32,
    box_w: f32,
    box_h: f32,
    radius: f32,
    border: f32,
    fg: text_mod.Color,
    border_color: text_mod.Color,

    inline fn shade(f: RoundedFill, pixels: []u32, index: usize, sx: f32, sy: f32) void {
        const outer = sdf.coverage(sdf.sdRoundedBox(sx, sy, f.box_x, f.box_y, f.box_w, f.box_h, f.radius));
        if (outer <= 0) return;
        var color = f.fg;
        if (f.border > 0) {
            const inner = sdf.coverage(sdf.sdRoundedBox(sx, sy, f.box_x + f.border, f.box_y + f.border, f.box_w - 2 * f.border, f.box_h - 2 * f.border, @max(f.radius - f.border, 0)));
            color = lerpColor(f.border_color, f.fg, inner);
        }
        blendPixel(&pixels[index], color, outer);
    }
};

/// Source-over blend of one constant premultiplied colour at full coverage,
/// in integer lanes rather than `blendPixel`'s float round trip. The interior
/// of a translucent fill is thousands of identical blends per frame (the start
/// menu's own background is 336k of them), and this is the same
/// two-lanes-at-a-time trick pixman uses: `(x*inv + 128 + ((x*inv + 128) >> 8)) >> 8`
/// is exactly `round(x*inv/255)` for the 0..255*255 range the lanes can hold,
/// and no lane can carry into its neighbour because 255*255 < 65536.
///
/// `inv` must be `255 - alpha8` and `src` premultiplied by that same alpha8,
/// which is what keeps `src_c + dst_c*inv/255 <= 255` — i.e. what makes the
/// byte lanes unable to overflow into each other.
inline fn blendConstOver(dst: u32, src: u32, inv: u32) u32 {
    const rb = (dst & 0x00FF00FF) * inv + 0x00800080;
    const ag = ((dst >> 8) & 0x00FF00FF) * inv + 0x00800080;
    const rb_done = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    const ag_done = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
    return src +% (rb_done | ag_done);
}

inline fn clampToInt(value: f32, lo: i32, hi: i32) i32 {
    return @intFromFloat(std.math.clamp(value, @as(f32, @floatFromInt(lo)), @as(f32, @floatFromInt(hi))));
}

pub const Renderer = struct {
    // Optional palette for a panel without changing the process-wide theme.
    palette: ?theme.Theme = null,
    pixels: []u32,
    width: i32, // device px
    height: i32, // device px
    scale: f32 = 1,
    clip: ?ClipRect = null,
    // Repaint bounds must not change text layout or scroll-container geometry.
    damage_clip: ?ClipRect = null,

    /// Set by a caller painting into a buffer that is still all zeroes. The
    /// first fill over it needs no blending — source-over onto transparent is
    /// the source — so it can be stored outright. Any draw clears the flag.
    clean: bool = false,

    pub fn effectiveClip(r: *const Renderer) ?ClipRect {
        if (r.damage_clip) |damage| return intersectClip(r.clip, damage);
        return r.clip;
    }

    fn textDamageClip(r: *const Renderer) ?text_mod.Rect {
        return r.textClip(r.damage_clip);
    }

    fn textClip(r: *const Renderer, clip: ?ClipRect) ?text_mod.Rect {
        const box = clip orelse return null;
        const x: i32 = @intFromFloat(@floor(box.x * r.scale));
        const y: i32 = @intFromFloat(@floor(box.y * r.scale));
        const right: i32 = @intFromFloat(@ceil((box.x + box.w) * r.scale));
        const bottom: i32 = @intFromFloat(@ceil((box.y + box.h) * r.scale));
        return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    }

    pub fn init(pixels: []u32, width: i32, height: i32, scale: f32) Renderer {
        return .{ .pixels = pixels, .width = width, .height = height, .scale = scale };
    }

    /// This renderer with logical units `factor` times larger, so a screen
    /// laid out on a design canvas (the lock's `s`) can draw shared components
    /// at their own sizes. Clips carry over into the new units. Either renderer
    /// may draw first, so neither can assume clean pixels any more.
    pub fn zoomed(r: *Renderer, factor: f32) Renderer {
        r.clean = false;
        var out = r.*;
        out.scale = r.scale * factor;
        if (r.clip) |c| out.clip = .{ .x = c.x / factor, .y = c.y / factor, .w = c.w / factor, .h = c.h / factor };
        if (r.damage_clip) |c| out.damage_clip = .{ .x = c.x / factor, .y = c.y / factor, .w = c.w / factor, .h = c.h / factor };
        return out;
    }

    pub fn fillRect(r: *Renderer, x: f32, y: f32, w: f32, h: f32, style: RectStyle) void {
        if (w <= 0 or h <= 0) return;
        const s = r.scale;
        var dx0 = x * s;
        var dy0 = y * s;
        var dx1 = (x + w) * s;
        var dy1 = (y + h) * s;
        if (r.effectiveClip()) |c| {
            dx0 = @max(dx0, c.x * s);
            dy0 = @max(dy0, c.y * s);
            dx1 = @min(dx1, (c.x + c.w) * s);
            dy1 = @min(dy1, (c.y + c.h) * s);
        }
        const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
        const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
        const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), dx1)));
        const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), dy1)));
        if (x0 >= x1 or y0 >= y1) return;

        const on_clear = r.clean;
        r.clean = false;

        const shape: RoundedFill = .{
            .box_x = x * s,
            .box_y = y * s,
            .box_w = w * s,
            .box_h = h * s,
            .radius = style.radius * s,
            .border = style.border_width * s,
            .fg = toColor(style.color),
            .border_color = toColor(style.border_color),
        };

        // Interior fast path. Away from the corners the rounded-box SDF is just
        // the distance to the nearest straight edge, so every pixel at least
        // half a pixel inside the border inset is fully covered by `fg` — no
        // SDF, no border lerp, and for an opaque fill no blending at all. Only
        // the curved corners and edge feather need the general path. Two
        // intersecting rectangles cover the flat interior, including the wide
        // spans between the corners in the top and bottom bands.
        const cx = shape.box_x + shape.box_w / 2;
        const cy = shape.box_y + shape.box_h / 2;
        // Rows this far from centre have no corner curvature and clear both the
        // outer and the inner (border) edge by half a pixel.
        const band = shape.box_h / 2 - @max(shape.radius, shape.border + 0.5);
        const span = shape.box_w / 2 - (shape.border + 0.5);
        var fast_x0 = x1;
        var fast_x1 = x1;
        if (span >= 0) {
            fast_x0 = @max(x0, clampToInt(@ceil(cx - span - 0.5), x0, x1));
            fast_x1 = @min(x1, clampToInt(@floor(cx + span - 0.5) + 1, x0, x1));
            if (fast_x1 < fast_x0) fast_x1 = fast_x0;
        }
        const corner_span = shape.box_w / 2 - @max(shape.radius, shape.border + 0.5);
        const corner_band = shape.box_h / 2 - (shape.border + 0.5);
        var corner_x0 = x1;
        var corner_x1 = x1;
        if (corner_span >= 0) {
            corner_x0 = clampToInt(@ceil(cx - corner_span - 0.5), x0, x1);
            corner_x1 = clampToInt(@floor(cx + corner_span - 0.5) + 1, x0, x1);
            if (corner_x1 < corner_x0) corner_x1 = corner_x0;
        }
        // Premultiplied fill colour. The interior span is by construction
        // inside the border inset, so it is `fg` at full coverage whether or
        // not the fill has a border, and an opaque fill's premultiplied form
        // is just the colour itself.
        const alpha8 = byte(shape.fg.a);
        const inv_alpha = 255 - alpha8;
        const premul_fg = (alpha8 << 24) | (byte(shape.fg.r * shape.fg.a) << 16) |
            (byte(shape.fg.g * shape.fg.a) << 8) | byte(shape.fg.b * shape.fg.a);
        const store_interior = on_clear or style.color[3] >= 1;

        var py = y0;
        while (py < y1) : (py += 1) {
            const sy = @as(f32, @floatFromInt(py)) + 0.5;
            const row: usize = @intCast(py * r.width);
            const fast = band >= 0 and @abs(sy - cy) <= band;
            const corner_fast = corner_band >= 0 and @abs(sy - cy) <= corner_band;
            const skip_from = if (fast) fast_x0 else if (corner_fast) corner_x0 else x1;
            const skip_to = if (fast) fast_x1 else if (corner_fast) corner_x1 else x1;

            var px = x0;
            while (px < skip_from) : (px += 1) shape.shade(r.pixels, row + @as(usize, @intCast(px)), @as(f32, @floatFromInt(px)) + 0.5, sy);
            if (skip_to > skip_from) {
                const from = row + @as(usize, @intCast(skip_from));
                const to = row + @as(usize, @intCast(skip_to));
                if (store_interior) {
                    @memset(r.pixels[from..to], premul_fg);
                } else {
                    for (r.pixels[from..to]) |*pixel| pixel.* = blendConstOver(pixel.*, premul_fg, inv_alpha);
                }
                px = skip_to;
            }
            while (px < x1) : (px += 1) shape.shade(r.pixels, row + @as(usize, @intCast(px)), @as(f32, @floatFromInt(px)) + 0.5, sy);
        }
    }

    pub fn drawText(r: *Renderer, x: f32, y: f32, w: f32, h: f32, style: TextStyle) void {
        r.clean = false;
        if (style.content.len == 0 or w <= 0 or h <= 0) return;
        const font = fontFor(style);
        const rect = text_mod.Rect{
            .x = @intFromFloat(@round(x)),
            .y = @intFromFloat(@round(y)),
            .w = @intFromFloat(@round(w)),
            .h = @intFromFloat(@round(h)),
        };
        text_mod.drawOpts(r.pixels, r.width, r.height, style.content, toColor(style.color), r.scale, font, style.font_size, .{ .rect = rect, .sensitive = style.sensitive, .device_clip = r.textClip(r.effectiveClip()) }) catch |err| {
            log.err("drawText: could not rasterize label: {}", .{err});
        };
    }

    /// A run laid out from `x - scroll_x` but painted only inside the box (or
    /// inside `clip`, when the caller wants a narrower window onto the same
    /// run — which is how selected text gets its own colour without reshaping
    /// anything). Never ellipsizes: a scrolling field shows its overflow by
    /// moving, not by cutting.
    ///
    /// Unlike `drawText`, this also offsets the run horizontally and disables
    /// ellipsizing so the entire text remains reachable by scrolling.
    pub const ScrolledText = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        scroll_x: f32 = 0,
        /// Defaults to the box. Intersected with the renderer's own clip.
        clip: ?ClipRect = null,
        style: TextStyle,
    };

    pub fn drawTextScrolled(r: *Renderer, args: ScrolledText) void {
        r.clean = false;
        if (args.style.content.len == 0 or args.w <= 0 or args.h <= 0) return;

        var clip = args.clip orelse ClipRect{ .x = args.x, .y = args.y, .w = args.w, .h = args.h };
        clip = intersectClip(r.clip, intersectClip(.{ .x = args.x, .y = args.y, .w = args.w, .h = args.h }, clip));
        if (clip.w <= 0 or clip.h <= 0) return;

        text_mod.drawOpts(
            r.pixels,
            r.width,
            r.height,
            args.style.content,
            toColor(args.style.color),
            r.scale,
            fontFor(args.style),
            args.style.font_size,
            .{
                .rect = .{
                    .x = @intFromFloat(@round(args.x - args.scroll_x)),
                    .y = @intFromFloat(@round(args.y)),
                    // The pen box has to cover the whole run, not the visible
                    // window, or the baseline is computed against the wrong
                    // height and a narrowed clip would move the text.
                    .w = @intFromFloat(@round(args.w + args.scroll_x)),
                    .h = @intFromFloat(@round(args.h)),
                },
                .clip = .{
                    .x = @intFromFloat(@floor(clip.x)),
                    .y = @intFromFloat(@floor(clip.y)),
                    .w = @intFromFloat(@ceil(clip.w)),
                    .h = @intFromFloat(@ceil(clip.h)),
                },
                .device_clip = r.textDamageClip(),
                .ellipsize = false,
                .sensitive = args.style.sensitive,
            },
        ) catch |err| {
            log.err("drawTextScrolled: could not rasterize label: {}", .{err});
        };
    }

    /// `pixels` scaled to cover the box, centre-cropped (CSS `object-fit:
    /// cover`), and clipped to a rounded rect: an avatar.
    pub fn drawImageCover(r: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: f32, image: Image) void {
        r.clean = false;
        if (w <= 0 or h <= 0 or image.width <= 0 or image.height <= 0) return;
        const s = r.scale;
        var dx0 = x * s;
        var dy0 = y * s;
        var dx1 = (x + w) * s;
        var dy1 = (y + h) * s;
        if (r.effectiveClip()) |c| {
            dx0 = @max(dx0, c.x * s);
            dy0 = @max(dy0, c.y * s);
            dx1 = @min(dx1, (c.x + c.w) * s);
            dy1 = @min(dy1, (c.y + c.h) * s);
        }
        const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
        const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
        const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), dx1)));
        const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), dy1)));
        if (x0 >= x1 or y0 >= y1) return;

        const src_w: f32 = @floatFromInt(image.width);
        const src_h: f32 = @floatFromInt(image.height);
        // Source pixels per device pixel, equal on both axes; the longer
        // source side overflows and is cropped evenly.
        const k = @min(src_w / (w * s), src_h / (h * s));
        const off_x = (src_w - w * s * k) / 2;
        const off_y = (src_h - h * s * k) / 2;
        const stride: usize = @intCast(image.width);
        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const sy = @as(f32, @floatFromInt(py)) + 0.5;
                const cov = sdf.coverage(sdf.sdRoundedBox(sx, sy, x * s, y * s, w * s, h * s, radius * s));
                if (cov <= 0) continue;
                const ix: usize = @intFromFloat(std.math.clamp(@floor(off_x + (sx - x * s) * k), 0, src_w - 1));
                const iy: usize = @intFromFloat(std.math.clamp(@floor(off_y + (sy - y * s) * k), 0, src_h - 1));
                blendPremultipliedPixel(&r.pixels[@intCast(py * r.width + px)], image.pixels[iy * stride + ix], cov);
            }
        }
    }

    // A small, self-contained SDF glyph set (see layout.IconId's doc
    // comment) — not every id gets bespoke ink; unhandled ones fall back to
    // a filled dot rather than nothing, so a missing case reads as "wrong
    // icon" instead of "invisible".
    pub fn drawIcon(r: *Renderer, x: f32, y: f32, w: f32, h: f32, style: IconStyle) void {
        r.clean = false;
        if (w <= 0 or h <= 0) return;
        const s = r.scale;
        var dx0 = x * s;
        var dy0 = y * s;
        var dx1 = (x + w) * s;
        var dy1 = (y + h) * s;
        if (r.effectiveClip()) |c| {
            dx0 = @max(dx0, c.x * s);
            dy0 = @max(dy0, c.y * s);
            dx1 = @min(dx1, (c.x + c.w) * s);
            dy1 = @min(dy1, (c.y + c.h) * s);
        }
        const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
        const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
        const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), dx1)));
        const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), dy1)));
        if (x0 >= x1 or y0 >= y1) return;

        const cx = (x + w / 2) * s;
        const cy = (y + h / 2) * s;
        const half = @min(w, h) / 2 * s * 0.55;
        const thickness = @max(1.0, (style.stroke_width orelse (@min(w, h) * 0.14)) * s);
        const col = toColor(style.color);
        const mask = @import("shell_icons.zig").get(style.id, @intFromFloat(@round(@min(w, h) * s)));
        const side = @min(w, h) * s;
        const left = cx - side / 2;
        const top = cy - side / 2;

        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const sy = @as(f32, @floatFromInt(py)) + 0.5;
                const cov = if (mask) |m|
                    m.sample((sx - left) / side * @as(f32, @floatFromInt(m.size)) - 0.5, (sy - top) / side * @as(f32, @floatFromInt(m.size)) - 0.5)
                else
                    sdf.coverage(iconDistance(style.id, sx, sy, cx, cy, half, thickness));
                if (cov <= 0) continue;
                blendPixel(&r.pixels[@intCast(py * r.width + px)], col, cov);
            }
        }
    }
};

fn iconDistance(id: IconId, px: f32, py: f32, cx: f32, cy: f32, half: f32, thickness: f32) f32 {
    const t = thickness / 2;
    return switch (id) {
        .more => @min(sdCircle(px, py, cx, cy - half, t), @min(sdCircle(px, py, cx, cy, t), sdCircle(px, py, cx, cy + half, t))),
        .checkmark => @min(
            sdSegment(px, py, cx - half, cy + half * 0.1, cx - half * 0.25, cy + half * 0.6, t),
            sdSegment(px, py, cx - half * 0.25, cy + half * 0.6, cx + half, cy - half * 0.6, t),
        ),
        .close => @min(
            sdSegment(px, py, cx - half, cy - half, cx + half, cy + half, t),
            sdSegment(px, py, cx - half, cy + half, cx + half, cy - half, t),
        ),
        .chevron_down => @min(
            sdSegment(px, py, cx - half, cy - half * 0.3, cx, cy + half * 0.5, t),
            sdSegment(px, py, cx, cy + half * 0.5, cx + half, cy - half * 0.3, t),
        ),
        .chevron_left => @min(
            sdSegment(px, py, cx + half * 0.3, cy - half, cx - half * 0.5, cy, t),
            sdSegment(px, py, cx - half * 0.5, cy, cx + half * 0.3, cy + half, t),
        ),
        .region => blk: {
            // Corner brackets a third of the side long.
            const arm = half * 0.66;
            var d: f32 = std.math.floatMax(f32);
            for ([_]f32{ -1, 1 }) |sx| for ([_]f32{ -1, 1 }) |sy| {
                const x0 = cx + sx * half;
                const y0 = cy + sy * half;
                d = @min(d, sdSegment(px, py, x0, y0, x0 - sx * arm, y0, t));
                d = @min(d, sdSegment(px, py, x0, y0, x0, y0 - sy * arm, t));
            };
            break :blk d;
        },
        .chevron_right => @min(
            sdSegment(px, py, cx - half * 0.3, cy - half, cx + half * 0.5, cy, t),
            sdSegment(px, py, cx + half * 0.5, cy, cx - half * 0.3, cy + half, t),
        ),
        .chevron_up => @min(
            sdSegment(px, py, cx - half, cy + half * 0.3, cx, cy - half * 0.5, t),
            sdSegment(px, py, cx, cy - half * 0.5, cx + half, cy + half * 0.3, t),
        ),
        .minimize => sdSegment(px, py, cx - half, cy, cx + half, cy, t),
        .drag_handle => @min(
            sdSegment(px, py, cx - half, cy - half * 0.7, cx + half, cy - half * 0.7, t),
            @min(
                sdSegment(px, py, cx - half, cy, cx + half, cy, t),
                sdSegment(px, py, cx - half, cy + half * 0.7, cx + half, cy + half * 0.7, t),
            ),
        ),
        .plus => @min(
            sdSegment(px, py, cx - half, cy, cx + half, cy, t),
            sdSegment(px, py, cx, cy - half, cx, cy + half, t),
        ),
        .maximize => @max(sdBox(px, py, cx, cy, half, half), -sdBox(px, py, cx, cy, half - thickness, half - thickness)),
        // Speaker housing + cone + waves. Same silhouette as Taskbar.zig's
        // `volumeGlyphSd` (an independent SDF glyph set — this engine has
        // no shared primitives with the taskbar's own raster loop) but
        // through this function's px/py/cx/cy/half/thickness
        // parameterization rather than tile-local gx/gy.
        .volume_muted => blk: {
            const body = sdf.sdQuad(
                px,
                py,
                cx - half,
                cy - half * 0.4,
                cx + half * 0.3,
                cy - half * 0.95,
                cx + half * 0.3,
                cy + half * 0.95,
                cx - half,
                cy + half * 0.4,
            );
            const strike = sdSegment(px, py, cx - half, cy - half, cx + half, cy + half, t);
            break :blk @min(body, strike);
        },
        .volume_low => blk: {
            const body = sdf.sdQuad(
                px,
                py,
                cx - half,
                cy - half * 0.4,
                cx + half * 0.3,
                cy - half * 0.95,
                cx + half * 0.3,
                cy + half * 0.95,
                cx - half,
                cy + half * 0.4,
            );
            const far: f32 = 999;
            const mouth = cx + half * 0.32;
            const wave = if (px < mouth) far else @abs(sdCircle(px, py, cx + half * 0.14, cy, half * 0.54)) - t;
            break :blk @min(body, wave);
        },
        .volume => blk: {
            const body = sdf.sdQuad(
                px,
                py,
                cx - half,
                cy - half * 0.4,
                cx + half * 0.3,
                cy - half * 0.95,
                cx + half * 0.3,
                cy + half * 0.95,
                cx - half,
                cy + half * 0.4,
            );
            const far: f32 = 999;
            const mouth = cx + half * 0.32;
            const w1 = if (px < mouth) far else @abs(sdCircle(px, py, cx + half * 0.14, cy, half * 0.54)) - t;
            const w2 = if (px < mouth) far else @abs(sdCircle(px, py, cx + half * 0.14, cy, half * 0.88)) - t;
            break :blk @min(body, @min(w1, w2));
        },
        // Shared outline microphone and mute slash for Settings and the OSD.
        .mic_muted => @min(iconDistance(.mic_outline, px, py, cx, cy, half, thickness), sdSegment(px, py, cx - half, cy - half, cx + half, cy + half, t)),
        .mic_outline => blk: {
            const capsule = @abs(sdf.sdRoundedBox(px, py, cx - half * 0.3, cy - half * 0.9, half * 0.6, half * 1.2, half * 0.3)) - t;
            const ring = @abs(sdCircle(px, py, cx, cy + half * 0.05, half * 0.58)) - t;
            const arc = @max(ring, cy - half * 0.05 - py);
            const stand = sdSegment(px, py, cx, cy + half * 0.62, cx, cy + half, t);
            const base = sdSegment(px, py, cx - half * 0.35, cy + half, cx + half * 0.35, cy + half, t);
            break :blk @min(capsule, @min(arc, @min(stand, base)));
        },
        .caps_lock => blk: {
            const arrow = @min(sdSegment(px, py, cx - half * 0.7, cy, cx, cy - half * 0.7, t * 0.6), sdSegment(px, py, cx, cy - half * 0.7, cx + half * 0.7, cy, t * 0.6));
            const stem = sdSegment(px, py, cx, cy - half * 0.5, cx, cy + half * 0.35, t * 0.6);
            const base = sdSegment(px, py, cx - half * 0.55, cy + half * 0.75, cx + half * 0.55, cy + half * 0.75, t * 0.6);
            break :blk @min(arrow, @min(stem, base));
        },
        .brightness => blk: {
            var d = @abs(sdCircle(px, py, cx, cy, half * 0.4)) - t * 0.5;
            for (0..8) |i| {
                const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 4;
                const dx = @cos(angle);
                const dy = @sin(angle);
                d = @min(d, sdSegment(px, py, cx + dx * half * 0.7, cy + dy * half * 0.7, cx + dx * half, cy + dy * half, t * 0.5));
            }
            break :blk d;
        },
        .mic => blk: {
            const capsule = sdf.sdRoundedBox(px, py, cx - half * 0.3, cy - half * 0.9, half * 0.6, half * 1.1, half * 0.3);
            const stand = sdSegment(px, py, cx, cy + half * 0.3, cx, cy + half * 0.9, t);
            const base = sdSegment(px, py, cx - half * 0.4, cy + half * 0.9, cx + half * 0.4, cy + half * 0.9, t);
            break :blk @min(capsule, @min(stand, base));
        },
        .grid => blk: {
            const step = half * 0.45;
            const dot_r = thickness * 0.85;
            const d1 = sdCircle(px, py, cx - step, cy - step, dot_r);
            const d2 = sdCircle(px, py, cx + step, cy - step, dot_r);
            const d3 = sdCircle(px, py, cx - step, cy + step, dot_r);
            const d4 = sdCircle(px, py, cx + step, cy + step, dot_r);
            break :blk @min(@min(d1, d2), @min(d3, d4));
        },
        .search => @min(
            @abs(sdCircle(px, py, cx - half * 0.2, cy - half * 0.2, half * 0.65)) - t,
            sdSegment(px, py, cx + half * 0.28, cy + half * 0.28, cx + half, cy + half, t),
        ),
        // Power-menu glyphs (start menu footer button + power_menu.zig's
        // action tiles). Each is built by carving a notch out of a ring or
        // box with `@max(shape, -cutter)` — the same boolean-subtract trick
        // used below for `.maximize` — since this glyph set has no analytic
        // arc primitive.
        .power => blk: {
            const ring = @abs(sdCircle(px, py, cx, cy + half * 0.08, half * 0.62)) - t;
            const gap = sdBox(px, py, cx, cy - half * 0.5, half * 0.24, half * 0.3);
            const bar = sdSegment(px, py, cx, cy - half * 0.95, cx, cy - half * 0.05, t);
            break :blk @min(@max(ring, -gap), bar);
        },
        .clock => 1000, // Embedded SVG; no procedural fallback.
        .power_saver, .power_balanced, .power_performance => blk: {
            // Upper three quarters of a ring, open at the bottom, with a
            // needle from the hub.
            const hub_y = cy + half * 0.2;
            const radius = half * 1.15;
            const ring = @abs(sdCircle(px, py, cx, hub_y, radius)) - t;
            const dial = @max(ring, -sdBox(px, py, cx, hub_y + radius, radius * 0.72, radius));
            const angle: f32 = switch (id) {
                .power_saver => -0.75 * std.math.pi,
                .power_balanced => -0.5 * std.math.pi,
                else => -0.25 * std.math.pi,
            };
            const needle = sdSegment(px, py, cx, hub_y, cx + @cos(angle) * radius * 0.62, hub_y + @sin(angle) * radius * 0.62, t);
            break :blk @min(dial, @min(needle, sdCircle(px, py, cx, hub_y, t * 1.6)));
        },
        .@"suspend" => blk: {
            const r = half * 0.65;
            const outer = sdCircle(px, py, cx - r * 0.1, cy, r);
            const cutout = sdCircle(px, py, cx + r * 0.35, cy - r * 0.25, r * 0.85);
            break :blk @max(outer, -cutout);
        },
        .lock => blk: {
            const shackle_cy = cy - half * 0.26;
            const shackle = @abs(sdCircle(px, py, cx, shackle_cy, half * 0.38)) - t;
            const shackle_cut = sdBox(px, py, cx, shackle_cy + half * 0.55, half * 0.55, half * 0.45);
            const shackle_open = @max(shackle, -shackle_cut);
            const body = sdRoundedBoxCentered(px, py, cx, cy + half * 0.34, half * 1.05, half * 0.72, half * 0.16);
            const keyhole = sdCircle(px, py, cx, cy + half * 0.32, t * 0.9);
            break :blk @min(shackle_open, @max(body, -keyhole));
        },
        .logout => blk: {
            const frame_cx = cx - half * 0.32;
            const frame = @abs(sdRoundedBoxCentered(px, py, frame_cx, cy, half * 0.4, half * 0.6, half * 0.12)) - t;
            const gap = sdBox(px, py, frame_cx + half * 0.4, cy, half * 0.22, half * 0.34);
            const frame_open = @max(frame, -gap);
            const shaft = sdSegment(px, py, cx - half * 0.28, cy, cx + half * 0.5, cy, t);
            // A filled triangle reads as a crisp arrowhead at this stroke
            // weight; two thin segments (tried first) blurred into a blob.
            const arrow = sdf.sdQuad(
                px,
                py,
                cx + half * 0.95,
                cy,
                cx + half * 0.42,
                cy - half * 0.38,
                cx + half * 0.42,
                cy + half * 0.38,
                cx + half * 0.42,
                cy + half * 0.38,
            );
            break :blk @min(frame_open, @min(shaft, arrow));
        },
        // Restart glyph: an open ring read as a clockwise arrow — a small
        // notch (same proportions as `.power`'s gap; a bigger cutter reads
        // as "chunk missing" rather than "open ring") plugged by a filled
        // triangle tangent to the circle. Restarting the compositor itself
        // (see power_menu.zig) reuses the same ring with a small center dot
        // standing in for "the shell/window", rather than a second pictogram.
        .reboot, .restart_shell => blk: {
            const ring = @abs(sdCircle(px, py, cx, cy, half * 0.6)) - t;
            const diag: f32 = 0.7071;
            // Unit radial direction (center -> notch, at the upper-right)
            // and its perpendicular (tangent to the ring there).
            const radial_x = diag;
            const radial_y = -diag;
            const tangent_x = diag;
            const tangent_y = diag;
            const gap_cx = cx + half * 0.6 * radial_x;
            const gap_cy = cy + half * 0.6 * radial_y;
            const gap = sdBoxRot(px, py, gap_cx, gap_cy, half * 0.16, half * 0.16, diag, diag);
            const ring_open = @max(ring, -gap);
            // Triangle base spans the ring's radial thickness at the notch;
            // the tip points tangentially, so the open ring reads as one
            // continuous curved arrow rather than a ring plus a separate spike.
            const arrow_len = half * 0.5;
            const arrow_w = half * 0.3;
            const arrow = sdf.sdQuad(
                px,
                py,
                gap_cx + tangent_x * arrow_len,
                gap_cy + tangent_y * arrow_len,
                gap_cx + radial_x * arrow_w,
                gap_cy + radial_y * arrow_w,
                gap_cx - radial_x * arrow_w,
                gap_cy - radial_y * arrow_w,
                gap_cx - radial_x * arrow_w,
                gap_cy - radial_y * arrow_w,
            );
            const base = @min(ring_open, arrow);
            break :blk if (id == .restart_shell) @min(base, sdCircle(px, py, cx, cy, half * 0.24)) else base;
        },
        .git_branch, .home, .generic, .folder, .document, .terminal, .settings, .keyboard, .edit, .browser, .wifi, .ethernet, .globe, .mouse, .display, .music, .headphones, .bluetooth, .battery, .notification, .eye, .eye_off, .refresh, .cut, .copy, .paste, .trash, .trash_can, .view_grid, .view_list, .sort, .filter, .zoom_in, .zoom_out, .rotate, .crop, .undo, .save, .fit, .print, .open, .usb_stick, .drive, .eject, .users, .squares => sdCircle(px, py, cx, cy, half * 0.6),
    };
}

fn sdSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, half_thickness: f32) f32 {
    const pax = px - ax;
    const pay = py - ay;
    const bax = bx - ax;
    const bay = by - ay;
    const denom = bax * bax + bay * bay;
    const h = if (denom > 0) std.math.clamp((pax * bax + pay * bay) / denom, 0, 1) else 0;
    const dx = pax - bax * h;
    const dy = pay - bay * h;
    return @sqrt(dx * dx + dy * dy) - half_thickness;
}

fn sdCircle(px: f32, py: f32, cx: f32, cy: f32, radius: f32) f32 {
    const dx = px - cx;
    const dy = py - cy;
    return @sqrt(dx * dx + dy * dy) - radius;
}

fn sdBox(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32) f32 {
    const qx = @abs(px - cx) - half_w;
    const qy = @abs(py - cy) - half_h;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(ox * ox + oy * oy);
}

// `sdf.sdRoundedBox` takes a top-left corner; the icon glyphs above all
// work in center + half-extent terms like `sdBox`, so this just re-centers.
fn sdRoundedBoxCentered(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32, radius: f32) f32 {
    return sdf.sdRoundedBox(px, py, cx - half_w, cy - half_h, half_w * 2, half_h * 2, radius);
}

// `sdBox` rotated about its own center — used to carve an angled notch out
// of a ring (the `.reboot`/`.restart_shell` glyphs' gap), which an
// axis-aligned cutter can't reach.
fn sdBoxRot(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32, cos_a: f32, sin_a: f32) f32 {
    const dx = px - cx;
    const dy = py - cy;
    const rx = cos_a * dx + sin_a * dy;
    const ry = -sin_a * dx + cos_a * dy;
    const qx = @abs(rx) - half_w;
    const qy = @abs(ry) - half_h;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(ox * ox + oy * oy);
}

inline fn toColor(c: [4]f32) text_mod.Color {
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
}

inline fn lerpColor(a: text_mod.Color, b: text_mod.Color, t: f32) text_mod.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

inline fn lerp4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t };
}

// Re-exported so callers don't need a second import just for the blend
// primitive text.zig already had (see text.zig's own use in glyph drawing).
pub const blendPixel = text_mod.blendPixel;

pub fn paint(widget: *const Widget, renderer: *Renderer) void {
    paintTree(widget, renderer);
    paintOverlays(widget, renderer);
}

pub fn paintTree(widget: *const Widget, renderer: *Renderer) void {
    var recurse_children = true;
    switch (widget.kind) {
        .container => {},
        .rect => |style| renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, style),
        .text => |style| if (style.pill)
            paintPill(widget, style, renderer)
        else
            renderer.drawText(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, style),
        .icon => |style| renderer.drawIcon(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, style),
        .image => |data| paintImage(widget, data, renderer),
        .battery => |spec| @import("widgets/battery.zig").paint(renderer, widget.computed_x, widget.computed_y, spec),
        .avatar => @import("widgets/avatar.zig").paint(renderer, widget.computed_x, widget.computed_y, @min(widget.computed_width, widget.computed_height), .{}),
        .row => |data| paintRow(widget, data, renderer),
        .button => |data| paintButton(widget, data, renderer),
        .checkbox => |data| paintCheckbox(widget, data, renderer),
        .text_input => |data| paintTextInput(widget, data, renderer),
        .secret_input => |data| {
            const focused = ui_input.isFocused(widget);
            _ = field_widget.paintSecret(renderer, .{
                .x = widget.computed_x,
                .y = widget.computed_y,
                .w = widget.computed_width,
                .h = widget.computed_height,
            }, data.field, .{ .focused = focused, .revealed = data.revealed }, data.input, data.placeholder);
        },
        .scroll_container => |state| {
            paintScrollContainer(widget, state, renderer);
            recurse_children = false;
        },
        .toggle => |data| paintToggle(widget, data, renderer),
        .slider => |data| paintSlider(widget, data, renderer),
        .select => |data| paintSelect(widget, data, renderer),
        .segmented => |data| paintSegmented(widget, data, renderer),
        .swatch => |data| paintSwatch(widget, data, renderer),
        .stepper => |data| paintStepper(widget, data, renderer),
        .arrangement => |data| @import("widgets/arrangement.zig").paint(widget, data, renderer),
    }
    if (recurse_children) {
        if (widget.underlay) |under| under.paint(under.owner, widget, renderer);
        for (widget.children) |*child| paintTree(child, renderer);
    }
}

fn paintImage(widget: *const Widget, data: ImageData, renderer: *Renderer) void {
    renderer.clean = false;
    const s = renderer.scale;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    if (w <= 0 or h <= 0) return;

    var dx0 = x * s;
    var dy0 = y * s;
    var dx1 = (x + w) * s;
    var dy1 = (y + h) * s;
    if (renderer.effectiveClip()) |c| {
        dx0 = @max(dx0, c.x * s);
        dy0 = @max(dy0, c.y * s);
        dx1 = @min(dx1, (c.x + c.w) * s);
        dy1 = @min(dy1, (c.y + c.h) * s);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
    const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(renderer.width)), dx1)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(renderer.height)), dy1)));
    if (x0 >= x1 or y0 >= y1) return;

    const box_x = x * s;
    const box_y = y * s;
    const box_w = w * s;
    const box_h = h * s;
    const radius = data.radius * s;

    if (data.pixels) |pixels| {
        if (data.width <= 0 or data.height <= 0) return;

        // Icons are cached at the exact device size the row asks for, so the
        // usual case is a 1:1 blit: no sampling arithmetic, and the blend is
        // a plain premultiplied source-over in integer lanes. The general
        // path below stays for scaled or rounded draws.
        if (radius <= 0 and box_x == @floor(box_x) and box_y == @floor(box_y) and
            box_w == @as(f32, @floatFromInt(data.width)) and box_h == @as(f32, @floatFromInt(data.height)))
        {
            const src_stride: usize = @intCast(data.width);
            const off_x = x0 - @as(i32, @intFromFloat(box_x));
            const off_y = y0 - @as(i32, @intFromFloat(box_y));
            var row = y0;
            while (row < y1) : (row += 1) {
                const src_row: usize = @intCast(off_y + (row - y0));
                const src = pixels[src_row * src_stride ..][@intCast(off_x)..][0..@intCast(x1 - x0)];
                const dst = renderer.pixels[@intCast(row * renderer.width + x0)..][0..@intCast(x1 - x0)];
                for (dst, src) |*pixel, sample| pixel.* = overPremultiplied(pixel.*, sample);
            }
            return;
        }

        const src_w_f: f32 = @floatFromInt(data.width);
        const src_h_f: f32 = @floatFromInt(data.height);
        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const sy = @as(f32, @floatFromInt(py)) + 0.5;
                var cov: f32 = 1;
                if (radius > 0) {
                    cov = sdf.coverage(sdf.sdRoundedBox(sx, sy, box_x, box_y, box_w, box_h, radius));
                    if (cov <= 0) continue;
                }
                const norm_u = std.math.clamp((sx - box_x) / box_w, 0, 1);
                const norm_v = std.math.clamp((sy - box_y) / box_h, 0, 1);
                const ix: usize = @min(@as(usize, @intCast(@as(i32, @intFromFloat(@floor(norm_u * src_w_f))))), @as(usize, @intCast(data.width - 1)));
                const iy: usize = @min(@as(usize, @intCast(@as(i32, @intFromFloat(@floor(norm_v * src_h_f))))), @as(usize, @intCast(data.height - 1)));
                const sample = pixels[iy * @as(usize, @intCast(data.width)) + ix];
                blendPremultipliedPixel(&renderer.pixels[@intCast(py * renderer.width + px)], sample, cov);
            }
        }
    } else {
        const t = renderer.palette orelse theme.global;
        const bg_col = data.fallback_color orelse t.surface_hover;
        renderer.fillRect(x, y, w, h, .{ .color = bg_col, .radius = data.radius });
        if (data.fallback_icon) |icon_id| {
            const icon_pad = @min(w, h) * 0.25;
            renderer.drawIcon(x + icon_pad, y + icon_pad, w - 2 * icon_pad, h - 2 * icon_pad, .{ .id = icon_id, .color = t.dim });
        }
    }
}

/// Source-over of an already-premultiplied sample at full coverage, in
/// integer lanes — the same rounding trick as `blendConstOver`, and safe from
/// lane overflow for the same reason (a premultiplied sample has
/// `channel <= alpha`, so `src_c + dst_c*inv/255 <= 255`).
inline fn overPremultiplied(dst: u32, src: u32) u32 {
    const src_alpha = src >> 24;
    if (src_alpha == 0) return dst;
    if (src_alpha == 255) return src;
    const inv = 255 - src_alpha;
    const rb = (dst & 0x00FF00FF) * inv + 0x00800080;
    const ag = ((dst >> 8) & 0x00FF00FF) * inv + 0x00800080;
    const rb_done = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    const ag_done = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
    return src +% (rb_done | ag_done);
}

fn blendPremultipliedPixel(dst: *u32, sample: u32, coverage: f32) void {
    if (coverage <= 0) return;
    const sa_raw = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
    if (sa_raw <= 0) return;
    const sa = sa_raw * coverage;
    const inv = 1.0 - sa;
    const sr = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0 * coverage;
    const sg = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0 * coverage;
    const sb = @as(f32, @floatFromInt(sample & 0xff)) / 255.0 * coverage;

    const val = dst.*;
    const da = @as(f32, @floatFromInt((val >> 24) & 0xff)) / 255.0;
    const dr = @as(f32, @floatFromInt((val >> 16) & 0xff)) / 255.0;
    const dg = @as(f32, @floatFromInt((val >> 8) & 0xff)) / 255.0;
    const db = @as(f32, @floatFromInt(val & 0xff)) / 255.0;

    const a = sa + da * inv;
    const r = sr + dr * inv;
    const g = sg + dg * inv;
    const b = sb + db * inv;

    dst.* = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}

inline fn byte(v: f32) u32 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

fn paintRow(widget: *const Widget, data: RowData, renderer: *Renderer) void {
    if (data.underlay) return;
    const t = renderer.palette orelse theme.global;
    if (data.background) |base| {
        const style = if (data.selected) data.hover_background orelse base else switch (data.state) {
            .hover => data.hover_background orelse base,
            .press => data.press_background orelse data.hover_background orelse base,
            else => base,
        };
        renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, style);
        return;
    }
    if (data.selected) {
        renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
            .color = t.start_menu_selected_bg,
            .radius = t.radius,
            .border_width = 1,
            .border_color = t.start_menu_selected_border,
        });
        const marker_h = @max(10, widget.computed_height - 18);
        const marker_y = widget.computed_y + (widget.computed_height - marker_h) / 2;
        renderer.fillRect(widget.computed_x + 3, marker_y, 3, marker_h, .{
            .color = t.start_menu_selected_marker,
            .radius = 1.5,
        });
    } else if (data.state == .hover or data.state == .press) {
        renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
            .color = t.surface_hover,
            .radius = t.radius,
            .border_width = 1,
            .border_color = t.border_soft,
        });
    }
}

fn paintButton(widget: *const Widget, data: ButtonData, renderer: *Renderer) void {
    button_widget.paint(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, button_widget.optionsOf(data), .{ .pointer = data.state, .focused = ui_input.isFocused(widget) });
}

fn paintCheckbox(widget: *const Widget, data: CheckboxData, renderer: *Renderer) void {
    checkbox_widget.paint(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, data.label, .{ .icon = data.icon, .checked = data.checked, .disabled = data.disabled, .focused = ui_input.isFocused(widget) });
}

fn paintTextInput(widget: *const Widget, data: TextInputData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const focused = ui_input.isFocused(widget);
    const frame = field_widget.paintFrame(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, data.field, .{ .focused = focused });

    const inner_x = frame.text.x;
    const inner_w = frame.text.w;
    const font_size = frame.font_size;
    const shown = if (data.value.len > 0) data.value else data.placeholder;

    // Measure at the renderer's scale, not at 1.0: hinting quantizes advances
    // per ppem, so a prefix measured at 1x is not where the same prefix's pen
    // lands when drawn at 1.5x, and the caret drifts off the text.
    const scale = renderer.scale;
    const caret_pen = if (focused)
        text_mod.measureWidthF(data.value[0..@min(data.value.len, data.cursor_pos)], .manrope, font_size, scale) catch 0
    else
        0;

    // Scroll to caret. Without this an overlong value ellipsizes while the
    // caret keeps its unclipped position, i.e. draws outside the field.
    const caret = ui_input.activeCaret();
    const scroll_before = caret.scroll;
    const scroll_x = if (focused and data.value.len > 0)
        caret.scrollTo(caret_pen, inner_w, text_mod.measureWidthF(data.value, .manrope, font_size, scale) catch 0)
    else
        0;

    const text_style = TextStyle{
        .content = shown,
        .font_size = font_size,
        .color = if (data.value.len > 0) t.fg else t.faint,
    };
    const field_clip = intersectClip(
        renderer.clip,
        .{ .x = inner_x, .y = widget.computed_y, .w = inner_w, .h = widget.computed_height },
    );

    if (!focused) {
        // An unfocused field has no caret to keep in view, so it keeps the
        // ellipsis rather than an arbitrary scroll position.
        renderer.drawText(inner_x, widget.computed_y, inner_w, widget.computed_height, text_style);
        return;
    }

    // Span the face's own ascender..descender rather than a multiple of the
    // font size: `text.draw` centers that same ink box, so this is the only
    // extent that lines the caret and the selection up with the glyphs for any
    // face.
    const metrics = text_mod.verticalMetrics(.manrope, font_size, scale) catch
        text_mod.VMetrics{ .ascent = font_size * 0.8, .descent = font_size * 0.2 };
    const ink_h = metrics.ascent + metrics.descent;
    const ink_y = widget.computed_y + (widget.computed_height - ink_h) / 2;

    const now = anim.nowMs();
    // Scrolling moves the text immediately, so the caret must follow it.
    if (scroll_x != scroll_before) caret.snap = true;
    caret.track(now, caret_pen);
    const caret_x = inner_x + caret.offset(now) - scroll_x;

    // Selection highlight, under the text.
    const selection: ?ClipRect = if (data.selection()) |range| blk: {
        const start = text_mod.measureWidthF(data.value[0..range.start], .manrope, font_size, scale) catch 0;
        const end = text_mod.measureWidthF(data.value[0..range.end], .manrope, font_size, scale) catch 0;
        break :blk .{ .x = inner_x + start - scroll_x, .y = ink_y, .w = end - start, .h = ink_h };
    } else null;
    if (selection) |rect| {
        const prev = renderer.clip;
        renderer.clip = field_clip;
        renderer.fillRect(rect.x, rect.y, rect.w, rect.h, .{ .color = t.selectionColor() });
        renderer.clip = prev;
    }

    var run = Renderer.ScrolledText{
        .x = inner_x,
        .y = widget.computed_y,
        .w = inner_w,
        .h = widget.computed_height,
        .scroll_x = scroll_x,
        .style = text_style,
    };
    if (caret.revealing and caret.offset(now) < caret_pen) {
        // Keep the full shaped run in place and uncover it behind the caret.
        // Round inward: the text clip uses whole logical pixels, and rounding
        // out could expose ink ahead of the caret at fractional positions.
        const left = @floor(inner_x);
        run.clip = .{ .x = left, .y = widget.computed_y, .w = @max(0, @floor(caret_x) - left), .h = widget.computed_height };
        renderer.drawTextScrolled(run);
        // Inserting in the middle must not hide the existing suffix.
        if (data.cursor_pos < data.value.len) {
            const right = @ceil(inner_x + caret_pen - scroll_x);
            run.clip = .{ .x = right, .y = widget.computed_y, .w = @max(0, inner_x + inner_w - right), .h = widget.computed_height };
            renderer.drawTextScrolled(run);
        }
    } else {
        renderer.drawTextScrolled(run);
    }

    // Selected text in its own colour, if the theme asks for one: the same run
    // again, clipped to the highlight, so nothing is reshaped or re-measured
    // and the two passes cannot disagree about where a glyph sits.
    if (t.selection_fg) |selected_color| {
        if (selection) |rect| renderer.drawTextScrolled(.{
            .x = inner_x,
            .y = widget.computed_y,
            .w = inner_w,
            .h = widget.computed_height,
            .scroll_x = scroll_x,
            .clip = rect,
            .style = .{ .content = shown, .font_size = font_size, .color = selected_color },
        });
    }

    // Record what pointer hit testing will need: it has no palette and no
    // renderer, so this is the only place the two can agree on where the text
    // actually starts and at what size it was shaped.
    caret.field = .{ .text_x = inner_x, .font_size = font_size, .scale = scale };

    if (!caret.visible(now)) return;
    const caret_y = ink_y + caret.y.value(now);
    // Clipped like the text: a caret at the far end of a scrolled value must
    // not paint over the field's padding or its border.
    const prev_clip = renderer.clip;
    renderer.clip = field_clip;
    renderer.fillRect(caret_x, caret_y, t.caret_width, ink_h, .{ .color = t.caretColor() });
    renderer.clip = prev_clip;
}

fn paintToggle(widget: *const Widget, data: ToggleData, renderer: *Renderer) void {
    @import("widgets/toggle.zig").paint(renderer, .{
        .x = widget.computed_x,
        .y = widget.computed_y,
        .w = widget.computed_width,
        .h = widget.computed_height,
    }, .{ .on = data.on, .style = data.style, .disabled = data.disabled, .focused = ui_input.isFocused(widget) });
}

/// Shared slider styling and feedback, using the surface's theme palette.
pub fn paintSlider(widget: *const Widget, data: SliderData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const w = widget.computed_width;
    const cy = widget.computed_y + widget.computed_height / 2;
    const settings = data.style == .settings;
    const track_h = (if (settings) t.slider_settings_track_height else t.slider_track_height) * (1 + t.slider_track_grow * data.feel.wide);
    const thumb_w: f32 = t.slider_thumb_size;
    const thumb_h: f32 = if (settings) t.slider_settings_thumb_height else t.slider_thumb_size;
    const track_y = cy - track_h / 2;

    // The scrollbar's feedback: `accent` is 1 under the pointer or a drag and a
    // faint hold after a change (`widgets/slider.zig`).
    const tint = data.feel.accent;
    const track_color = lerp4(t.slider_track, .{ t.accent[0], t.accent[1], t.accent[2], t.slider_track_tint_alpha * t.accent[3] }, tint);
    renderer.fillRect(widget.computed_x, track_y, w, track_h, .{ .color = track_color, .radius = track_h / 2 });

    const frac = if (data.max > data.min) std.math.clamp((data.value - data.min) / (data.max - data.min), 0, 1) else 0;
    const fill_w = frac * w;
    const fill_rest: f32 = if (settings) 1 else t.slider_fill_alpha;
    const fill_color: [4]f32 = .{ t.accent[0], t.accent[1], t.accent[2], t.accent[3] * (fill_rest + (1 - fill_rest) * tint) };
    if (fill_w > 0) renderer.fillRect(widget.computed_x, track_y, fill_w, track_h, .{ .color = fill_color, .radius = track_h / 2 });

    const thumb_x = widget.computed_x + fill_w - thumb_w / 2;
    renderer.fillRect(thumb_x, cy - thumb_h / 2, thumb_w, thumb_h, .{ .color = t.control_thumb, .radius = if (settings) t.slider_thumb_radius else t.slider_thumb_size / 2 });
}

/// A slider's value readout: the text centred in a rounded label that fades
/// toward the accent while the slider is dragged (`style.glow`).
fn paintPill(widget: *const Widget, style: TextStyle, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    // An unavailable slider's readout is empty: no label at all.
    if (w <= 0 or h <= 0 or style.content.len == 0) return;
    const glow = std.math.clamp(style.glow, 0, 1);
    const wash = lerp4(t.pill_bg, .{ t.accent[0], t.accent[1], t.accent[2], t.pill_active_alpha * t.accent[3] }, glow);
    renderer.fillRect(x, y, w, h, .{
        .color = wash,
        .radius = h / 2,
        .border_width = 1,
        .border_color = lerp4(t.border, .{ t.accent[0], t.accent[1], t.accent[2], t.pill_border_active_alpha * t.accent[3] }, glow),
    });
    var text = style;
    text.color = lerp4(style.color, t.fg, glow);
    const text_x = centeredTextX(x, w, style.content, style.font_size);
    renderer.drawText(text_x, y, @max(0, x + w - text_x), h, text);
}

pub fn centeredTextX(cell_x: f32, cell_w: f32, label: []const u8, font_size: f32) f32 {
    return cell_x + @max(0, (cell_w - labelWidth(label, font_size)) / 2);
}

/// Width of a one-line label as `centeredTextX` measures it.
pub fn labelWidth(label: []const u8, font_size: f32) f32 {
    return @floatFromInt(text_mod.measureWidth(label, .manrope, font_size, 1.0) catch 0);
}

fn paintSegmented(widget: *const Widget, data: SegmentedData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
        .color = t.surface,
        .radius = t.radius,
        .border_width = 1,
        .border_color = t.border,
    });
    if (data.labels.len == 0) return;
    const cell_w = widget.computed_width / @as(f32, @floatFromInt(data.labels.len));
    for (data.labels, 0..) |label, i| {
        const cell_x = widget.computed_x + cell_w * @as(f32, @floatFromInt(i));
        const selected = i == data.selected;
        if (selected) {
            const accent_wash: [4]f32 = .{ t.accent[0], t.accent[1], t.accent[2], t.segmented_selected_alpha * t.accent[3] };
            renderer.fillRect(cell_x + 2, widget.computed_y + 2, cell_w - 4, widget.computed_height - 4, .{
                .color = accent_wash,
                .radius = @max(0, t.radius - 2),
                .border_width = 1,
                .border_color = t.accent,
            });
        }
        renderer.drawText(centeredTextX(cell_x, cell_w, label, t.font_size), widget.computed_y, cell_w, widget.computed_height, .{
            .content = label,
            .font_size = t.font_size,
            .weight = 600,
            .color = if (selected) t.fg else t.dim,
        });
    }
}

fn paintSwatch(widget: *const Widget, data: SwatchData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    const border_width: f32 = if (data.selected) 2 else 1;
    const border_color: [4]f32 = if (data.selected) t.swatch_border_selected else t.swatch_border;
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
        .color = data.color,
        .radius = t.swatch_radius,
        .border_width = border_width,
        .border_color = border_color,
    });
    if (data.selected) {
        // A 2px inset glow in the swatch's own color, approximated as an
        // inset ring rather than an actual blurred glow (no blur primitive
        // in this CPU rasterizer).
        const glow: [4]f32 = .{ data.color[0], data.color[1], data.color[2], t.swatch_glow_alpha * data.color[3] };
        renderer.fillRect(widget.computed_x + 3, widget.computed_y + 3, widget.computed_width - 6, widget.computed_height - 6, .{
            .color = .{ 0, 0, 0, 0 },
            .radius = 4,
            .border_width = 1,
            .border_color = glow,
        });
    }
}

const stepper_button_width: f32 = 28;

fn paintStepper(widget: *const Widget, data: StepperData, renderer: *Renderer) void {
    const t = renderer.palette orelse theme.global;
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, widget.computed_height, .{
        .color = t.surface,
        .radius = t.radius,
        .border_width = 1,
        .border_color = t.border,
    });
    renderer.drawIcon(widget.computed_x, widget.computed_y, stepper_button_width, widget.computed_height, .{ .id = .minimize, .color = t.fg });
    renderer.drawIcon(widget.computed_x + widget.computed_width - stepper_button_width, widget.computed_y, stepper_button_width, widget.computed_height, .{ .id = .plus, .color = t.fg });

    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d} {s}", .{ @as(i32, @intFromFloat(@round(data.value))), data.unit }) catch "";
    const mid_x = widget.computed_x + stepper_button_width;
    const mid_w = @max(0, widget.computed_width - 2 * stepper_button_width);
    renderer.drawText(centeredTextX(mid_x, mid_w, label, t.font_size), widget.computed_y, mid_w, widget.computed_height, .{
        .content = label,
        .font_size = t.font_size,
        .weight = 600,
        .color = t.fg,
    });
}

fn paintScrollContainer(widget: *const Widget, state: ScrollState, renderer: *Renderer) void {
    const prev_clip = renderer.clip;
    renderer.clip = intersectClip(prev_clip, .{ .x = widget.computed_x, .y = widget.computed_y, .w = widget.computed_width, .h = widget.computed_height });
    if (state.underlay) |under| under.paint(under.owner, widget, renderer);
    const sideways = widget.direction == .row;
    for (widget.children) |*child| {
        const outside = if (sideways)
            child.computed_x + child.computed_width < widget.computed_x or child.computed_x > widget.computed_x + widget.computed_width
        else
            child.computed_y + child.computed_height < widget.computed_y or child.computed_y > widget.computed_y + widget.computed_height;
        if (outside) continue;
        paintTree(child, renderer);
    }
    renderer.clip = prev_clip;

    const g = @import("widgets/scroll_container.zig").geometry(widget) orelse return;
    const t = renderer.palette orelse theme.global;
    scrollbar.paint(renderer, scrollbar.look(g, state.bar, theme.global.scrollbar_width, t));
}

pub fn intersectClip(a: ?ClipRect, b: ClipRect) ClipRect {
    const base = a orelse return b;
    const x0 = @max(base.x, b.x);
    const y0 = @max(base.y, b.y);
    const x1 = @min(base.x + base.w, b.x + b.w);
    const y1 = @min(base.y + base.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

test "scroll underlay paints beneath rows, which skip their own fill when told to" {
    const Hook = struct {
        fn paint(_: ?*anyopaque, scroll: *const Widget, r: *Renderer) void {
            r.fillRect(scroll.computed_x, scroll.computed_y, scroll.computed_width, 10, .{ .color = .{ 1, 0, 0, 1 } });
        }
    };
    var pixels = [_]u32{0} ** (20 * 20);
    var r = Renderer.init(&pixels, 20, 20, 1);
    var row = Widget{
        .kind = .{ .row = .{ .selected = true, .underlay = true } },
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 20,
        .computed_height = 20,
    };
    var kids = [_]Widget{row};
    var scroll = Widget{
        .kind = .{ .scroll_container = .{ .underlay = .{ .owner = null, .paint = Hook.paint } } },
        .children = &kids,
        .computed_x = 0,
        .computed_y = 0,
        .computed_width = 20,
        .computed_height = 20,
    };
    paintTree(&scroll, &r);
    // The underlay's red band survives; the underlay row drew nothing over it.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[5 * 20 + 5]);
    // Below the band nothing was drawn: an ordinary selected row would have.
    try std.testing.expectEqual(@as(u32, 0), pixels[15 * 20 + 10]);
    // A sidebar rect uses the same hook without becoming a scroll viewport.
    scroll.kind = .{ .rect = .{ .color = .{ 0, 0, 1, 1 } } };
    scroll.underlay = .{ .owner = null, .paint = Hook.paint };
    @memset(&pixels, 0);
    paintTree(&scroll, &r);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[5 * 20 + 5]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[15 * 20 + 10]);
    scroll.kind = .{ .scroll_container = .{ .underlay = scroll.underlay } };
    scroll.underlay = null;
    row.kind.row.underlay = false;
    kids[0] = row;
    @memset(&pixels, 0);
    paintTree(&scroll, &r);
    try std.testing.expect(pixels[15 * 20 + 10] != 0);
}

test "fillRect paints solid color inside a device-pixel buffer" {
    var pixels = [_]u32{0} ** (10 * 10);
    var r = Renderer.init(&pixels, 10, 10, 1);
    r.fillRect(1, 1, 4, 4, .{ .color = .{ 1, 0, 0, 1 } });
    // Center of the fill should be fully opaque red; a corner outside it stays clear.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[3 * 10 + 3]);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
}

test "fillRect respects the active clip rect" {
    var pixels = [_]u32{0} ** (10 * 10);
    var r = Renderer.init(&pixels, 10, 10, 1);
    r.clip = .{ .x = 0, .y = 0, .w = 5, .h = 10 };
    r.fillRect(0, 0, 10, 10, .{ .color = .{ 1, 1, 1, 1 } });
    try std.testing.expect(pixels[5 * 10 + 2] != 0); // column 2: inside the 5px-wide clip
    try std.testing.expectEqual(@as(u32, 0), pixels[5 * 10 + 7]); // column 7: outside it
}

test "rounded fill spans match per-pixel shading at fractional scales" {
    const cases = [_]struct { w: f32, h: f32, radius: f32, border: f32 }{
        .{ .w = 44, .h = 24, .radius = 8, .border = 1 },
        .{ .w = 24, .h = 44, .radius = 8, .border = 1 },
        .{ .w = 44, .h = 24, .radius = 0, .border = 0 },
        .{ .w = 44, .h = 24, .radius = 8, .border = 0.5 },
        .{ .w = 44, .h = 24, .radius = 2, .border = 4 },
        .{ .w = 44, .h = 24, .radius = 80, .border = 1 },
        .{ .w = 3, .h = 4, .radius = 1.5, .border = 1 },
        .{ .w = 3, .h = 4, .radius = 2, .border = 3 },
    };
    var actual: [96 * 96]u32 = undefined;
    var expected: [96 * 96]u32 = undefined;
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for ([_]f32{ 2, 2.3 }) |origin| {
            for (cases) |case| {
                for ([_]u32{ 0, 0xff182430, 0x80402010 }) |background| {
                    for ([_]f32{ 0.09, 0.78, 1 }) |alpha| {
                        @memset(&actual, background);
                        @memset(&expected, background);
                        var renderer = Renderer.init(&actual, 96, 96, scale);
                        renderer.clean = background == 0;
                        // Exercise both uncut corners and a clip through them.
                        if (origin != 2) renderer.clip = .{ .x = 5.2, .y = 3.7, .w = 33.1, .h = 35.4 };
                        const style: RectStyle = .{
                            .color = .{ 0.2, 0.6, 0.9, alpha },
                            .radius = case.radius,
                            .border_width = case.border,
                            .border_color = .{ 0.8, 0.1, 0.3, 0.35 },
                        };
                        renderer.fillRect(origin, origin, case.w, case.h, style);
                        const shape: RoundedFill = .{
                            .box_x = origin * scale,
                            .box_y = origin * scale,
                            .box_w = case.w * scale,
                            .box_h = case.h * scale,
                            .radius = case.radius * scale,
                            .border = case.border * scale,
                            .fg = toColor(style.color),
                            .border_color = toColor(style.border_color),
                        };
                        var clip = ClipRect{ .x = origin, .y = origin, .w = case.w, .h = case.h };
                        clip = intersectClip(renderer.clip, clip);
                        const x0: usize = @intFromFloat(@floor(clip.x * scale));
                        const y0: usize = @intFromFloat(@floor(clip.y * scale));
                        const x1: usize = @intFromFloat(@ceil((clip.x + clip.w) * scale));
                        const y1: usize = @intFromFloat(@ceil((clip.y + clip.h) * scale));
                        // Empty logical clips can have a nonempty rounded pixel
                        // extent; match fillRect's device clipping convention.
                        for (y0..y1) |y| {
                            for (x0..x1) |x| {
                                shape.shade(&expected, y * 96 + x, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                            }
                        }
                        for (actual, expected) |got, want| {
                            // Integer source-over and the float reference can
                            // differ by one quantization level, as above.
                            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                                const a: i32 = @intCast((got >> shift) & 255);
                                const b: i32 = @intCast((want >> shift) & 255);
                                try std.testing.expect(@abs(a - b) <= 1);
                            }
                            try std.testing.expect((got & 255) <= (got >> 24));
                            try std.testing.expect(((got >> 8) & 255) <= (got >> 24));
                            try std.testing.expect(((got >> 16) & 255) <= (got >> 24));
                        }
                    }
                }
            }
        }
    }
}

test "prototype button states retain neutral premultiplied fills" {
    const saved = theme.global;
    defer theme.global = saved;
    theme.global = .{};
    var pixels = [_]u32{0} ** (30 * 30);
    var renderer = Renderer.init(&pixels, 30, 30, 1);
    const Callback = struct {
        fn call(_: ?*anyopaque, _: usize) void {}
    };
    const widget = Widget{ .kind = .container, .computed_width = 30, .computed_height = 30 };
    paintButton(&widget, .{ .label = "", .on_click = Callback.call }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x0d0d0d0d), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .label = "", .on_click = Callback.call, .state = .hover }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x14141414), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .variant = .ghost, .label = "", .on_click = Callback.call }, &renderer);
    try std.testing.expectEqual(@as(u32, 0), pixels[15 * 30 + 15]);
    @memset(&pixels, 0);
    paintButton(&widget, .{ .variant = .ghost, .label = "", .on_click = Callback.call, .state = .hover }, &renderer);
    try std.testing.expectEqual(@as(u32, 0x14141414), pixels[15 * 30 + 15]);
}

test "translucent interior blend matches the float path within a unit" {
    // The interior fast path and the edge/corner path meet along every fill's
    // border, so their results have to agree to the eye: check the integer
    // blend never drifts more than one 8-bit step from blendPixel's float.
    const alphas = [_]f32{ 0.06, 0.3, 0.5, 0.78, 0.95 };
    for (alphas) |a| {
        const color: text_mod.Color = .{ .r = 0.2, .g = 0.6, .b = 0.9, .a = a };
        const alpha8 = byte(color.a);
        const inv = 255 - alpha8;
        const premul = (alpha8 << 24) | (byte(color.r * color.a) << 16) |
            (byte(color.g * color.a) << 8) | byte(color.b * color.a);
        for ([_]u32{ 0x00000000, 0xff000000, 0xffffffff, 0x80402010, 0x7f7f7f7f }) |dst| {
            var reference = dst;
            blendPixel(&reference, color, 1);
            const fast = blendConstOver(dst, premul, inv);
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const want: i32 = @intCast((reference >> shift) & 0xff);
                const got: i32 = @intCast((fast >> shift) & 0xff);
                try std.testing.expect(@abs(want - got) <= 1);
            }
        }
    }
}

test "premultiplied blit matches the float path within a unit" {
    for ([_]u32{ 0x00000000, 0x40201008, 0x80402010, 0xff3366aa, 0xffffffff }) |sample| {
        for ([_]u32{ 0x00000000, 0xff000000, 0xffffffff, 0x9a123456 }) |dst| {
            var reference = dst;
            blendPremultipliedPixel(&reference, sample, 1);
            const fast = overPremultiplied(dst, sample);
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const want: i32 = @intCast((reference >> shift) & 0xff);
                const got: i32 = @intCast((fast >> shift) & 0xff);
                try std.testing.expect(@abs(want - got) <= 1);
            }
        }
    }
}

fn paintSelect(widget: *const Widget, data: layout.SelectData, r: *Renderer) void {
    const t = r.palette orelse theme.global;
    const hovered = ui_input.activeDispatcher().hovered == widget;
    const focused = ui_input.isFocused(widget) and !data.disabled;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    r.fillRect(x, y, w, h, .{ .color = if (hovered and !data.disabled) t.surface_hover else t.surface, .radius = t.radius, .border_width = 1, .border_color = if (focused or data.open) t.accent else if (hovered and !data.disabled) t.border_hover else t.border });
    const valid = if (data.selected) |i| i < data.labels.len else false;
    r.drawText(x + 12, y, @max(0, w - 48), h, .{ .content = if (valid) data.labels[data.selected.?] else data.placeholder, .font_size = t.font_size, .weight = 600, .color = if (data.disabled) t.faint else if (valid) t.fg else t.dim });
    r.drawIcon(x + w - 28, y + (h - 16) / 2, 16, 16, .{ .id = if (data.open) .chevron_up else .chevron_down, .color = if (data.disabled) t.faint else t.dim });
}

/// Paint after the entire ordinary tree, outside scroll-container clips.
pub fn paintOverlays(widget: *const Widget, r: *Renderer) void {
    if (widget.kind == .select and widget.kind.select.open) {
        const select = @import("widgets/select.zig");
        const d = widget.kind.select;
        const b = select.popupBounds(widget);
        const t = r.palette orelse theme.global;
        var bg = t.bg;
        bg[3] = 1;
        r.fillRect(b.x, b.y, b.w, b.h, .{ .color = bg, .radius = t.radius, .border_width = 1, .border_color = t.border_hover });
        const row_h = select.rowHeight();
        const visible = select.visibleCount(widget);
        const end = @min(d.labels.len, d.first_visible + visible);
        for (d.first_visible..end) |i| {
            const y = b.y + select.padding + @as(f32, @floatFromInt(i - d.first_visible)) * row_h;
            if (i == d.highlighted) r.fillRect(b.x + 4, y, b.w - 8, row_h, .{ .color = .{ t.accent[0], t.accent[1], t.accent[2], 0.18 }, .radius = @max(0, t.radius - 3) });
            r.drawText(b.x + 12, y, @max(0, b.w - 46), row_h, .{ .content = d.labels[i], .font_size = t.font_size, .weight = if (d.selected == i) 600 else 400, .color = if (std.mem.indexOfScalar(usize, d.disabled_options, i) != null) t.faint else t.fg });
            if (d.selected == i) r.drawIcon(b.x + b.w - 28, y + (row_h - 16) / 2, 16, 16, .{ .id = .checkmark, .color = t.accent });
        }
        if (visible > 0) {
            const strip = scrollbar.gutter(theme.global.scrollbar_width);
            const track: scrollbar.Rect = .{ .x = b.x + b.w - strip, .y = b.y + 6, .w = strip, .h = b.h - 12 };
            if (scrollbar.Geometry.compute(.vertical, track, @floatFromInt(visible), @floatFromInt(d.labels.len), @floatFromInt(d.first_visible))) |g|
                scrollbar.paint(r, scrollbar.look(g, .{}, theme.global.scrollbar_width, t));
        }
    }
    for (widget.children) |*child| paintOverlays(child, r);
}

test "secret input widget never retains hidden or echo-on responses in run cache" {
    var bytes: [510]u8 = @splat(0);
    var field = @import("widgets/secret_input.zig").Input{ .storage = &bytes };
    defer field.clear();
    try std.testing.expect(field.insert("fixture-sensitive-response"));
    var pixels: [400 * 50]u32 = @splat(0);
    var renderer = Renderer.init(&pixels, 400, 50, 1);
    const before = text_mod.testingRunCacheCount();
    _ = field.paint(&renderer, 0, 0, 80, 42, 18, .{ .hidden = true, .caret = true, .placeholder = "" });
    _ = field.paint(&renderer, 0, 0, 80, 42, 18, .{ .hidden = false, .caret = true, .placeholder = "" });
    // And through the shared field, frame and all.
    _ = field_widget.paintSecret(&renderer, .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .{ .size = .lg, .trailing = .reveal }, .{ .focused = true }, &field, "");
    _ = field_widget.paintSecret(&renderer, .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .{ .size = .lg, .trailing = .reveal }, .{ .focused = true, .revealed = true }, &field, "");
    // Dotted masking: the caret keeps the field font's height, hidden or not.
    const box: field_widget.Rect = .{ .x = 0, .y = 0, .w = 400, .h = 50 };
    const dotted: field_widget.Options = .{ .size = .lg, .secret_dots = .{ .diameter = 0.46, .pitch = 1.05 } };
    const hidden = field_widget.paintSecret(&renderer, box, dotted, .{ .focused = true }, &field, "").caret.?;
    const clear = field_widget.paintSecret(&renderer, box, dotted, .{ .focused = true, .revealed = true }, &field, "").caret.?;
    try std.testing.expectEqual(clear.h, hidden.h);
    try std.testing.expectEqual(clear.y, hidden.y);
    try std.testing.expectEqual(before, text_mod.testingRunCacheCount());
}

// A partially scrolled row must retain the same glyph positions as the full row.
test "text clipping preserves layout at scroll edges" {
    for ([_]f32{ 1, 1.5 }) |scale| {
        var full: [240 * 90]u32 = @splat(0);
        var clipped: [240 * 90]u32 = @splat(0);
        var r = Renderer.init(&full, 240, 90, scale);
        const style: TextStyle = .{ .content = "Transmission label", .font_size = 16, .color = .{ 1, 1, 1, 1 } };
        r.drawText(4, 4, 140, 34, style);
        r.pixels = &clipped;
        r.clip = .{ .x = 18, .y = 20, .w = 90, .h = 12 };
        r.drawText(4, 4, 140, 34, style);
        const clip = r.textClip(r.clip).?;
        var ink: usize = 0;
        for (clipped, 0..) |pixel, i| {
            const x: i32 = @intCast(i % 240);
            const y: i32 = @intCast(i / 240);
            const inside = x >= clip.x and x < clip.x + clip.w and y >= clip.y and y < clip.y + clip.h;
            try std.testing.expectEqual(if (inside) full[i] else 0, pixel);
            if (pixel != 0) ink += 1;
        }
        try std.testing.expect(ink > 0);
    }
}

test "typing reveals text behind the gliding caret and preserves the suffix" {
    const saved_dispatcher = ui_input.active_dispatcher;
    defer ui_input.active_dispatcher = saved_dispatcher;
    const saved_config = ui_input.caret_config;
    defer ui_input.caret_config = saved_config;
    defer anim.setNowMs(null);
    ui_input.caret_config = .{ .motion_ms = 80 };

    for ([_]f32{ 1, 1.5 }) |scale| {
        for ([_][]const u8{ "ab", "abcd" }) |value| {
            var widget = Widget{ .kind = .{ .text_input = .{
                .value = try std.testing.allocator.dupe(u8, if (value.len == 2) "a" else "acd"),
                .placeholder = "",
                .cursor_pos = 1,
                .on_change = struct {
                    fn changed(_: ?*anyopaque, _: usize, _: []const u8) void {}
                }.changed,
            } }, .computed_width = 150, .computed_height = 40 };
            defer std.testing.allocator.free(widget.kind.text_input.value);
            var dispatcher = ui_input.Dispatcher{ .focused = &widget };
            ui_input.active_dispatcher = &dispatcher;
            var background: [240 * 90]u32 = @splat(0);
            var first = background;
            var middle = background;
            var complete = background;
            var r = Renderer.init(&background, 240, 90, scale);
            // Hide only the caret's ink so the comparison isolates the text.
            r.palette = theme.Theme{ .caret = .{ 0, 0, 0, 0 } };
            const frame = field_widget.paintFrame(&r, .{ .x = 0, .y = 0, .w = 150, .h = 40 }, .{}, .{ .focused = true });
            const start = try text_mod.measureWidthF("a", .manrope, frame.font_size, scale);
            const target = try text_mod.measureWidthF("ab", .manrope, frame.font_size, scale);
            dispatcher.caret.track(0, start);

            anim.setNowMs(1000);
            _ = try dispatcher.keyEvent(std.testing.allocator, .{ .char = "b" }, .{});
            r.pixels = &first;
            paintTextInput(&widget, widget.kind.text_input, &r);
            try std.testing.expect(dispatcher.caret.moving(1000));
            anim.setNowMs(1020);
            r.pixels = &middle;
            paintTextInput(&widget, widget.kind.text_input, &r);
            const mid = dispatcher.caret.offset(1020);
            try std.testing.expect(mid > start and mid < target);
            anim.setNowMs(1080);
            r.pixels = &complete;
            paintTextInput(&widget, widget.kind.text_input, &r);

            var hidden_ink: usize = 0;
            var suffix_ink: usize = 0;
            const suffix_x = @ceil(frame.text.x + target) * scale;
            for (complete, 0..) |pixel, i| {
                const x: f32 = @floatFromInt(i % 240);
                const start_x = @ceil(@floor(frame.text.x + start) * scale);
                const mid_x = @ceil(@floor(frame.text.x + mid) * scale);
                if (x >= start_x and x < suffix_x) {
                    try std.testing.expectEqual(background[i], first[i]);
                    if (pixel != background[i]) hidden_ink += 1;
                }
                if (x >= mid_x and x < suffix_x)
                    try std.testing.expectEqual(background[i], middle[i]);
                if (x >= suffix_x) {
                    try std.testing.expectEqual(pixel, first[i]);
                    try std.testing.expectEqual(pixel, middle[i]);
                    if (pixel != background[i]) suffix_ink += 1;
                }
            }
            try std.testing.expect(hidden_ink > 0);
            if (value.len > 2) try std.testing.expect(suffix_ink > 0);

            // Navigation cancels the reveal: existing text stays visible.
            dispatcher.caret.noteEdit(1100);
            try std.testing.expect(!dispatcher.caret.revealing);
        }
    }
}
