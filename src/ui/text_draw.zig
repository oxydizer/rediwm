//! Measuring and drawing runs: widths, caret offsets, ellipsis, vertical metrics and ink baselines.

const std = @import("std");
const text = @import("text.zig");
const c = text.c;
const Rect = text.Rect;
const Color = text.Color;
const Font = text.Font;
const size26 = text.size26;
const primaryId = text.primaryId;
const ensureLoaded = text.ensureLoaded;
const applySize = text.applySize;
const setSize = text.setSize;
const previousUtf8Boundary = text.previousUtf8Boundary;
const Run = text.Run;
const shapedRun = text.shapedRun;
const uncachedRun = text.uncachedRun;
const clearSensitiveRun = text.clearSensitiveRun;
const glyphBitmap = text.glyphBitmap;
const snap26_6 = text.snap26_6;
const blendBitmap = text.blendBitmap;
const blendColorBitmap = text.blendColorBitmap;
const blendPixel = text.blendPixel;
const devicePixels = text.devicePixels;

/// Prepare common UI glyphs without drawing. Call on the compositor thread:
/// FreeType slots and these caches are shared with normal rendering.
pub fn warmGlyphs(font: Font, size_px: f32, scale: f32, chars: []const u8) !void {
    const size = size26(size_px, scale);
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size, chars);
    for (run.glyphs) |glyph| {
        const face = ensureLoaded(glyph.face) catch continue;
        applySize(face, size) catch continue;
        _ = glyphBitmap(face, glyph.face, glyph.index, false);
    }
}

/// Longest prefix of `utf8` that fits in `available_26_6` with an ellipsis
/// appended, written into `storage`. The cut point comes from walking the
/// already-shaped run's advances rather than re-shaping every prefix, so a
/// long client-supplied title costs one extra shaping, not one per character.
pub fn fitWithEllipsis(font: Font, size: c.FT_F26Dot6, utf8: []const u8, available_26_6: i32, storage: []u8) ![]const u8 {
    const ellipsis = "\u{2026}";
    const dots = try shapedRun(font, size, ellipsis);
    if (dots.width > available_26_6) return "";

    const limit = @min(utf8.len, storage.len - ellipsis.len);
    const full = try shapedRun(font, size, utf8[0..limit]);

    var budget = available_26_6 - dots.width;
    var cut: usize = limit;
    for (full.glyphs) |glyph| {
        if (budget < glyph.x_advance) {
            cut = @min(@as(usize, glyph.cluster), limit);
            break;
        }
        budget -= glyph.x_advance;
    }

    // Shaping the prefix can differ slightly from the advances measured in
    // the middle of a run (kerning at the new boundary), so confirm the cut
    // and step back a character at a time if it still overflows.
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const candidate_len = cut + ellipsis.len;
        @memcpy(storage[0..cut], utf8[0..cut]);
        @memcpy(storage[cut..candidate_len], ellipsis);
        const candidate = try shapedRun(font, size, storage[0..candidate_len]);
        if (candidate.width <= available_26_6 or cut == 0) return storage[0..candidate_len];
        cut = previousUtf8Boundary(utf8, cut);
    }
    @memcpy(storage[0..ellipsis.len], ellipsis);
    return storage[0..ellipsis.len];
}

// Logical-pixel width the text would take if drawn with draw(), for callers
// that need to right-align or center a run (the taskbar clock).
pub fn measureWidth(utf8: []const u8, font: Font, size_px: f32, scale: f32) !i32 {
    return @intFromFloat(@ceil(try measureWidthF(utf8, font, size_px, scale)));
}

// Unrounded logical-pixel advance of a run. `measureWidth` ceils this to a
// whole pixel, which is right for laying a box out around text but wrong for
// positioning something *inside* the run: a text caret placed at the ceiled
// prefix width drifts up to a pixel right of the glyph it sits before, and
// the drift changes with every keystroke. Callers that need the pen position
// rather than a box size want this one.
pub fn measureWidthF(utf8: []const u8, font: Font, size_px: f32, scale: f32) !f32 {
    if (utf8.len == 0) return 0;
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size26(size_px, scale), utf8);
    return @as(f32, @floatFromInt(run.width)) / 64.0 / scale;
}

/// Byte offset in `utf8` nearest to `target_px` logical pixels from the start
/// of the run — the inverse of `measureWidthF`, for turning a click into a
/// caret position. The run is shaped once and walked, so clusters and
/// ligatures land on real boundaries rather than on a byte count; the point is
/// compared against each glyph's midpoint, which is what makes clicking the
/// right half of a character put the caret after it.
///
/// Assumes a left-to-right run, like everything else here: `draw` advances one
/// pen in one direction and `text.zig` has no bidi.
pub fn offsetAtX(utf8: []const u8, font: Font, size_px: f32, scale: f32, target_px: f32) !usize {
    if (utf8.len == 0 or target_px <= 0) return 0;
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size26(size_px, scale), utf8);
    const target = target_px * 64.0 * scale;
    var pen: f32 = 0;
    for (run.glyphs) |glyph| {
        const advance: f32 = @floatFromInt(glyph.x_advance);
        if (target < pen + advance / 2) return @min(glyph.cluster, utf8.len);
        pen += advance;
    }
    return utf8.len;
}

/// Logical-pixel vertical extent of a face at a size, both positive and
/// measured from the baseline. `draw` centers `ascent + descent` in its box,
/// so anything that has to line up with drawn text vertically — a caret, a
/// selection highlight, an underline — must be derived from these rather
/// than from a multiple of the font size, which is a different number for
/// every face.
pub const VMetrics = struct { ascent: f32, descent: f32 };

pub fn verticalMetrics(font: Font, size_px: f32, scale: f32) !VMetrics {
    const slot = try setSize(font, size_px, scale);
    const metrics = slot.ft_face.*.size.*.metrics;
    return .{
        .ascent = @as(f32, @floatFromInt(metrics.ascender)) / 64.0 / scale,
        .descent = @as(f32, @floatFromInt(-metrics.descender)) / 64.0 / scale,
    };
}

// Logical-pixel line height (ascender - descender) for callers that need to
// size a box around text without drawing it yet (ui/measure.zig).
pub fn lineHeight(font: Font, size_px: f32, scale: f32) !f32 {
    const slot = try setSize(font, size_px, scale);
    const metrics = slot.ft_face.*.size.*.metrics;
    const height_26_6 = metrics.ascender - metrics.descender;
    return @as(f32, @floatFromInt(height_26_6)) / 64.0 / scale;
}

pub fn draw(
    pixels: []u32,
    width: i32,
    height: i32,
    rect: Rect,
    utf8: []const u8,
    color: Color,
    scale: f32,
    font: Font,
    size_px: f32,
) !void {
    return drawOpts(pixels, width, height, utf8, color, scale, font, size_px, .{ .rect = rect });
}

/// `rect` places the pen and baseline; `clip` (defaulting to `rect`) bounds
/// which pixels may be touched. Keeping the two separate is what lets a text
/// field scroll horizontally: the run is laid out from an origin left of the
/// field — a negative `rect.x` — while only the field's own pixels are
/// written. Passing `rect` as the clip, which `draw` does, would instead slide
/// the text back to the clip's left edge and show its beginning again.
pub const DrawOptions = struct {
    rect: Rect,
    clip: ?Rect = null,
    /// Additional buffer-pixel scissor, independent of pen layout and logical
    /// clipping. Damage edges use floor/ceil, not text placement's rounding.
    device_clip: ?Rect = null,
    /// Replace an overlong run with one ellipsized to fit `rect`. A scrolling
    /// field wants this off — it shows the overflow by moving, not by cutting.
    ellipsize: bool = true,
    /// Do not cache text or glyph sequences; disables ellipsizing.
    sensitive: bool = false,
    /// Center the visible glyph bounds rather than the font line metrics.
    /// For standalone labels; editable fields retain their stable baseline.
    center_ink: bool = false,
    /// Synthetic italic; callers allow for horizontal ink overhang in `clip`.
    italic: bool = false,
    /// Buffer-pixel row of the baseline, instead of centring the line in
    /// `rect`: for callers that place text by baseline (the Cairo clients,
    /// through ui/cairo.zig).
    baseline: ?i32 = null,
    /// Underline the shaped glyph cluster at this UTF-8 byte offset.
    accelerator: ?Accelerator = null,
};

pub const Accelerator = struct {
    byte_offset: usize,
    color: Color,
};

pub fn drawOpts(
    pixels: []u32,
    width: i32,
    height: i32,
    utf8: []const u8,
    color: Color,
    scale: f32,
    font: Font,
    size_px: f32,
    options: DrawOptions,
) !void {
    const rect = options.rect;
    if (utf8.len == 0 or rect.w <= 0 or rect.h <= 0) return;
    const size = size26(size_px, scale);
    _ = try setSize(font, size_px, scale);

    const x0 = devicePixels(rect.x, scale);
    const y0 = devicePixels(rect.y, scale);
    // Clamped to the buffer, as it always was: the baseline is centred in
    // `y0..y1`, and changing that would move every existing caller's text.
    const y1 = @min(height, devicePixels(rect.y + rect.h, scale));

    const clip = options.clip orelse rect;
    if (clip.w <= 0 or clip.h <= 0) return;
    var clip_x0 = devicePixels(clip.x, scale);
    var clip_y0 = devicePixels(clip.y, scale);
    var clip_x1 = @min(width, devicePixels(clip.x + clip.w, scale));
    var clip_y1 = @min(height, devicePixels(clip.y + clip.h, scale));
    if (options.device_clip) |damage| {
        clip_x0 = @max(clip_x0, damage.x);
        clip_y0 = @max(clip_y0, damage.y);
        clip_x1 = @min(clip_x1, damage.x + damage.w);
        clip_y1 = @min(clip_y1, damage.y + damage.h);
    }
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

    var fitted_storage: [4096]u8 = undefined;
    var run = if (options.sensitive) try uncachedRun(font, size, utf8) else try shapedRun(font, size, utf8);
    defer if (options.sensitive) clearSensitiveRun(run);
    if (options.ellipsize and !options.sensitive) {
        const available = (@min(width, devicePixels(rect.x + rect.w, scale)) - x0) * 64;
        const tolerance: i32 = @as(i32, @intFromFloat(@ceil(scale * 2.0))) * 64;
        if (run.width > available + tolerance) {
            const fitted = try fitWithEllipsis(font, size, utf8, available, &fitted_storage);
            if (fitted.len == 0) return;
            run = try shapedRun(font, size, fitted);
        }
    }

    // Re-fetch after shaping: fallback intern can grow `faces` and move the
    // primary Face that `setSize` returned.
    const slot = try ensureLoaded(primaryId(font));
    try applySize(slot, size);
    const metrics = slot.ft_face.*.size.*.metrics;
    const ink_height = metrics.ascender - metrics.descender;
    var baseline = snap26_6(y0 * 64 + @divTrunc((y1 - y0) * 64 - ink_height, 2) + metrics.ascender) * 64;
    if (options.center_ink) {
        if (inkCenteredBaseline(run, size, y0, y1)) |row| baseline = row * 64;
    }
    if (options.baseline) |row| baseline = row * 64;
    var pen_x = x0 * 64;
    var pen_y = baseline;
    var accelerator_left: ?i32 = null;
    var accelerator_right: i32 = 0;
    for (run.glyphs) |glyph| {
        if (options.accelerator) |accelerator| {
            if (accelerator.byte_offset <= std.math.maxInt(u32) and
                glyph.cluster == @as(u32, @intCast(accelerator.byte_offset)))
            {
                const glyph_left = @min(pen_x, pen_x + glyph.x_advance);
                const glyph_right = @max(pen_x, pen_x + glyph.x_advance);
                accelerator_left = if (accelerator_left) |left| @min(left, glyph_left) else glyph_left;
                accelerator_right = @max(accelerator_right, glyph_right);
            }
        }
        const face = ensureLoaded(glyph.face) catch {
            pen_x += glyph.x_advance;
            pen_y += glyph.y_advance;
            continue;
        };
        applySize(face, size) catch {
            pen_x += glyph.x_advance;
            pen_y += glyph.y_advance;
            continue;
        };
        if (glyphBitmap(face, glyph.face, glyph.index, options.italic)) |bitmap| {
            // Keep the accumulated pen fractional to avoid spacing drift;
            // snap only the final bitmap placement to the nearest pixel.
            const origin_x = snap26_6(pen_x + glyph.x_offset) + bitmap.left;
            const origin_y = snap26_6(pen_y - glyph.y_offset) - bitmap.top;
            if (bitmap.cols > 0) {
                if (bitmap.color) {
                    blendColorBitmap(pixels, width, height, clip_x0, clip_y0, clip_x1, clip_y1, origin_x, origin_y, bitmap, color.a);
                } else {
                    blendBitmap(pixels, width, height, clip_x0, clip_y0, clip_x1, clip_y1, origin_x, origin_y, bitmap, color);
                }
            }
        }
        pen_x += glyph.x_advance;
        pen_y += glyph.y_advance;
    }

    // Use the shaped cluster's pen advance rather than measuring a prefix:
    // this stays aligned with kerning, fallback faces and fractional advances.
    if (options.accelerator) |accelerator| {
        if (accelerator_left) |left| {
            const line_left = @max(clip_x0, @max(0, snap26_6(left)));
            const line_right = @min(clip_x1, @min(width, snap26_6(accelerator_right)));
            const line_y = snap26_6(baseline + 64);
            const thickness = @max(1, devicePixels(1, scale));
            const line_bottom = @min(clip_y1, line_y + thickness);
            var py = @max(clip_y0, line_y);
            while (py < line_bottom) : (py += 1) {
                var px = line_left;
                while (px < line_right) : (px += 1) {
                    blendPixel(&pixels[@intCast(py * width + px)], accelerator.color, 1);
                }
            }
        }
    }
}

/// Buffer-pixel baseline row that centres the visible glyph bounds of `run`
/// between rows `y0` and `y1`; null when nothing in it has ink.
pub fn inkCenteredBaseline(run: Run, size: c.FT_F26Dot6, y0: i32, y1: i32) ?i32 {
    var top: i32 = std.math.maxInt(i32);
    var bottom: i32 = std.math.minInt(i32);
    var offset_y: c.FT_Pos = 0;
    for (run.glyphs) |glyph| {
        defer offset_y += glyph.y_advance;
        const face = ensureLoaded(glyph.face) catch continue;
        applySize(face, size) catch continue;
        if (glyphBitmap(face, glyph.face, glyph.index, false)) |bitmap| {
            if (bitmap.cols == 0 or bitmap.rows == 0) continue;
            const origin_y = snap26_6(offset_y - glyph.y_offset) - bitmap.top;
            top = @min(top, origin_y);
            bottom = @max(bottom, origin_y + bitmap.rows);
        }
    }
    if (top >= bottom) return null;
    return @divFloor(y0 + y1 - top - bottom + 1, 2);
}

/// The `DrawOptions.baseline` that `center_ink` would pick for `sample` in
/// `rect` (which must lie inside the buffer). A line drawn in pieces, such as
/// tabular digits, gives every piece this row: centring each piece on its own
/// ink would lift a colon to mid-height and let a flat "1" sit a row off a
/// round "0".
pub fn inkBaseline(sample: []const u8, font: Font, size_px: f32, scale: f32, rect: Rect) !i32 {
    const size = size26(size_px, scale);
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size, sample);
    return inkCenteredBaseline(run, size, devicePixels(rect.y, scale), devicePixels(rect.y + rect.h, scale)) orelse error.NoInk;
}
