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
const paint_icons = @import("paint_icons.zig");
const paint_image = @import("paint_image.zig");
const paint_widgets = @import("paint_widgets.zig");
pub const iconDistance = paint_icons.iconDistance;
pub const sdSegment = paint_icons.sdSegment;
pub const sdCircle = paint_icons.sdCircle;
pub const sdBox = paint_icons.sdBox;
pub const sdRoundedBoxCentered = paint_icons.sdRoundedBoxCentered;
pub const sdBoxRot = paint_icons.sdBoxRot;
pub const paintImage = paint_image.paintImage;
pub const overPremultiplied = paint_image.overPremultiplied;
pub const max_footprint = paint_image.max_footprint;
pub const max_taps = paint_image.max_taps;
pub const Taps = paint_image.Taps;
pub const boxAverage = paint_image.boxAverage;
pub const boxSample = paint_image.boxSample;
pub const blendPremultipliedPixel = paint_image.blendPremultipliedPixel;
pub const paintRow = paint_widgets.paintRow;
pub const paintButton = paint_widgets.paintButton;
pub const paintCheckbox = paint_widgets.paintCheckbox;
pub const paintTextInput = paint_widgets.paintTextInput;
pub const paintToggle = paint_widgets.paintToggle;
pub const paintSlider = paint_widgets.paintSlider;
pub const paintPill = paint_widgets.paintPill;
pub const centeredTextX = paint_widgets.centeredTextX;
pub const labelWidth = paint_widgets.labelWidth;
pub const paintSegmented = paint_widgets.paintSegmented;
pub const paintSwatch = paint_widgets.paintSwatch;
pub const stepper_button_width = paint_widgets.stepper_button_width;
pub const paintStepper = paint_widgets.paintStepper;
pub const paintScrollContainer = paint_widgets.paintScrollContainer;
pub const intersectClip = paint_widgets.intersectClip;
pub const paintSelect = paint_widgets.paintSelect;
pub const paintOverlays = paint_widgets.paintOverlays;

pub const anim = @import("anim.zig");
pub const text_mod = @import("text.zig");
pub const sdf = @import("sdf.zig");
pub const theme = @import("theme.zig");
pub const ui_input = @import("input.zig");
pub const field_widget = @import("widgets/field.zig");
pub const button_widget = @import("widgets/button.zig");
pub const checkbox_widget = @import("widgets/checkbox.zig");
pub const scrollbar = @import("widgets/scrollbar.zig");

/// Columns whose horizontal taps `drawImageSmooth` keeps at once (on the stack).
const taps_strip = 64;

/// A logical-pixel clip rectangle, intersected as scroll containers nest.
pub const ClipRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Premultiplied 0xAARRGGBB pixels, row-major without padding.
pub const Image = struct { pixels: []const u32, width: i32, height: i32 };

pub fn fontFor(style: TextStyle) text_mod.Font {
    return switch (style.family) {
        .sans => if (style.weight >= 700) .manrope_heavy else if (style.weight >= 600) .manrope_bold else .manrope,
        .mono => if (style.weight >= 600) .mono_bold else .mono,
    };
}

/// Geometry + colours of one rounded-rect fill, so the general (edge and
/// corner) shading path can be shared by the spans on either side of the
/// interior fast path without repeating it.
pub const RoundedFill = struct {
    box_x: f32,
    box_y: f32,
    box_w: f32,
    box_h: f32,
    radius: f32,
    border: f32,
    fg: text_mod.Color,
    border_color: text_mod.Color,
    replace: bool = false,

    pub inline fn shade(f: RoundedFill, pixels: []u32, index: usize, sx: f32, sy: f32) void {
        const outer = sdf.coverage(sdf.sdRoundedBox(sx, sy, f.box_x, f.box_y, f.box_w, f.box_h, f.radius));
        if (outer <= 0) return;
        var color = f.fg;
        if (f.border > 0) {
            const inner = sdf.coverage(sdf.sdRoundedBox(sx, sy, f.box_x + f.border, f.box_y + f.border, f.box_w - 2 * f.border, f.box_h - 2 * f.border, @max(f.radius - f.border, 0)));
            color = lerpColor(f.border_color, f.fg, inner);
        }
        if (f.replace) {
            var source: u32 = 0;
            blendPixel(&source, color, outer);
            pixels[index] = blendConstOver(pixels[index], source, 255 - byte(outer));
        } else blendPixel(&pixels[index], color, outer);
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
pub inline fn blendConstOver(dst: u32, src: u32, inv: u32) u32 {
    const rb = (dst & 0x00FF00FF) * inv + 0x00800080;
    const ag = ((dst >> 8) & 0x00FF00FF) * inv + 0x00800080;
    const rb_done = ((rb + ((rb >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    const ag_done = (ag + ((ag >> 8) & 0x00FF00FF)) & 0xFF00FF00;
    return src +% (rb_done | ag_done);
}

pub inline fn clampToInt(value: f32, lo: i32, hi: i32) i32 {
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

    pub fn textDamageClip(r: *const Renderer) ?text_mod.Rect {
        return r.textClip(r.damage_clip);
    }

    pub fn textClip(r: *const Renderer, clip: ?ClipRect) ?text_mod.Rect {
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
            .replace = style.replace,
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
        const store_interior = on_clear or style.replace or style.color[3] >= 1;

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
        if (style.highlight_query.len > 0) {
            const pal = r.palette orelse theme.global;
            // Use the same face, scale and hinted advances as the label. Keep
            // highlights inside its box, including when the label ellipsizes.
            const limit = text_mod.measureWidthF(style.content, font, style.font_size, r.scale) catch 0;
            const ellipsis = if (limit > w) text_mod.measureWidthF("…", font, style.font_size, r.scale) catch 0 else 0;
            const metrics = text_mod.verticalMetrics(font, style.font_size, r.scale) catch text_mod.VMetrics{ .ascent = style.font_size, .descent = 0 };
            const line_h = @min(h, metrics.ascent + metrics.descent);
            var words = std.mem.tokenizeAny(u8, style.highlight_query, " \t\r\n");
            while (words.next()) |word| {
                var offset: usize = 0;
                while (@import("fold.zig").indexOf(style.content[offset..], word, .{ .turkish = @import("i18n").isTurkish() })) |match| {
                    const start = offset + match.start;
                    const end = offset + match.end;
                    if (end <= offset) break;
                    offset = end;
                    const left = text_mod.measureWidthF(style.content[0..start], font, style.font_size, r.scale) catch continue;
                    const right = text_mod.measureWidthF(style.content[0..end], font, style.font_size, r.scale) catch continue;
                    const clipped_right = @min(right, w - ellipsis);
                    if (clipped_right > left) r.fillRect(@as(f32, @floatFromInt(rect.x)) + left, y + (h - line_h) / 2, clipped_right - left, line_h, .{
                        .color = .{ pal.accent[0], pal.accent[1], pal.accent[2], 0.25 },
                        .radius = 2,
                    });
                }
            }
        }
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
        r.drawImageSampled(x, y, w, h, radius, image, false);
    }

    /// `drawImageCover` for an image that animates in size or sits at a
    /// fractional position (the dock's hover zoom): every pixel is the area
    /// average of the source it covers, so edges neither stair-step nor crawl
    /// from frame to frame.
    pub fn drawImageSmooth(r: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: f32, image: Image) void {
        r.drawImageSampled(x, y, w, h, radius, image, true);
    }

    pub fn drawImageSampled(r: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: f32, image: Image, comptime smooth: bool) void {
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
        // Source pixels one device pixel spans, at least one so that enlarging
        // blends neighbours (bilinear) rather than repeating them.
        const footprint = std.math.clamp(k, 1, max_footprint);
        const stride: usize = @intCast(image.width);
        if (smooth) {
            // A column shares its horizontal taps: work them out once per strip
            // of columns, not once per pixel.
            var across: [taps_strip]Taps = undefined;
            var strip = x0;
            while (strip < x1) : (strip += taps_strip) {
                const strip_end = @min(x1, strip + taps_strip);
                for (across[0..@intCast(strip_end - strip)], 0..) |*taps, i| {
                    const sx = @as(f32, @floatFromInt(strip + @as(i32, @intCast(i)))) + 0.5;
                    taps.* = Taps.init(off_x + (sx - x * s) * k, footprint / 2, image.width);
                }
                var py = y0;
                while (py < y1) : (py += 1) {
                    const sy = @as(f32, @floatFromInt(py)) + 0.5;
                    const down = Taps.init(off_y + (sy - y * s) * k, footprint / 2, image.height);
                    var px = strip;
                    while (px < strip_end) : (px += 1) {
                        const sx = @as(f32, @floatFromInt(px)) + 0.5;
                        const cov = sdf.coverage(sdf.sdRoundedBox(sx, sy, x * s, y * s, w * s, h * s, radius * s));
                        if (cov <= 0) continue;
                        const sample = boxAverage(image, across[@intCast(px - strip)], down);
                        blendPremultipliedPixel(&r.pixels[@intCast(py * r.width + px)], sample, cov);
                    }
                }
            }
            return;
        }
        var py = y0;
        while (py < y1) : (py += 1) {
            const sy = @as(f32, @floatFromInt(py)) + 0.5;
            const v = off_y + (sy - y * s) * k;
            var px = x0;
            while (px < x1) : (px += 1) {
                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = sdf.coverage(sdf.sdRoundedBox(sx, sy, x * s, y * s, w * s, h * s, radius * s));
                if (cov <= 0) continue;
                const u = off_x + (sx - x * s) * k;
                const sample = image.pixels[
                    @as(usize, @intFromFloat(std.math.clamp(@floor(v), 0, src_h - 1))) * stride +
                        @as(usize, @intFromFloat(std.math.clamp(@floor(u), 0, src_w - 1)))
                ];
                blendPremultipliedPixel(&r.pixels[@intCast(py * r.width + px)], sample, cov);
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
        // Sample the glyph's own (unrotated) coordinate frame at the point
        // that would land on this destination pixel after rotating by
        // `style.rotation`, i.e. rotate the sample backwards.
        const rot = style.rotation;
        const cos_r = @cos(-rot);
        const sin_r = @sin(-rot);

        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                var sx = @as(f32, @floatFromInt(px)) + 0.5;
                var sy = @as(f32, @floatFromInt(py)) + 0.5;
                if (rot != 0) {
                    const dx = sx - cx;
                    const dy = sy - cy;
                    sx = cx + dx * cos_r - dy * sin_r;
                    sy = cy + dx * sin_r + dy * cos_r;
                }
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

pub inline fn toColor(c: [4]f32) text_mod.Color {
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
}

pub inline fn lerpColor(a: text_mod.Color, b: text_mod.Color, t: f32) text_mod.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

pub inline fn lerp4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
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

pub inline fn byte(v: f32) u32 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

test {
    _ = @import("paint_tests.zig");
}
