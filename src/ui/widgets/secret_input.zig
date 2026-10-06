//! Caller-owned sensitive storage. No heap copies, clipboard or shaping cache.
const std = @import("std");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const ui_paint = @import("../paint.zig");
const Renderer = ui_paint.Renderer;

/// Bullets beyond this many are not drawn; no caller stores more characters.
const max_bullets = 512;

/// Masked characters drawn as circles instead of bullet glyphs, so their size
/// and spacing are the caller's choice rather than the face's. Both are in
/// ems of the field's font size.
pub const Dots = struct {
    diameter: f32,
    /// Centre to centre; the caret sits halfway between two dots.
    pitch: f32,
};

/// `Dots` in whole device pixels (as logical units): every dot then
/// rasterizes identically and the gaps cannot wander by a pixel.
const DotGrid = struct {
    pitch: f32,
    /// A cell's left edge to its dot's.
    lead: f32,
    diameter: f32,

    fn init(dots: Dots, font_size: f32, scale: f32) DotGrid {
        const pitch = @max(1, @round(dots.pitch * font_size * scale));
        const diameter = std.math.clamp(@round(dots.diameter * font_size * scale), 1, pitch);
        return .{ .pitch = pitch / scale, .lead = @floor((pitch - diameter) / 2) / scale, .diameter = diameter / scale };
    }
};

/// Characters, not bytes, capped at what the mask draws.
fn masked(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |b| {
        if (b & 0xc0 != 0x80) count += 1;
    }
    return @min(count, max_bullets);
}

pub const Input = struct {
    storage: []u8,
    len: usize = 0,
    cursor: usize = 0,
    pub fn value(self: *const Input) []const u8 {
        return self.storage[0..self.len];
    }
    pub fn clear(self: *Input) void {
        std.crypto.secureZero(u8, self.storage);
        self.len = 0;
        self.cursor = 0;
    }
    pub fn insert(self: *Input, bytes: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(bytes) or bytes.len > self.storage.len - self.len) return false;
        for (bytes) |b| if (b < 32 or b == 127) return false;
        std.mem.copyBackwards(u8, self.storage[self.cursor + bytes.len .. self.len + bytes.len], self.storage[self.cursor..self.len]);
        @memcpy(self.storage[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
        return true;
    }
    pub fn left(self: *Input) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor > 0 and self.storage[self.cursor] & 0xc0 == 0x80) self.cursor -= 1;
    }
    pub fn right(self: *Input) void {
        if (self.cursor == self.len) return;
        self.cursor += 1;
        while (self.cursor < self.len and self.storage[self.cursor] & 0xc0 == 0x80) self.cursor += 1;
    }
    pub fn backspace(self: *Input) void {
        const end = self.cursor;
        self.left();
        self.remove(self.cursor, end);
    }
    pub fn delete(self: *Input) void {
        const start = self.cursor;
        self.right();
        const end = self.cursor;
        self.cursor = start;
        self.remove(start, end);
    }
    fn remove(self: *Input, start: usize, end: usize) void {
        const old = self.len;
        std.mem.copyForwards(u8, self.storage[start..], self.storage[end..old]);
        self.len -= end - start;
        std.crypto.secureZero(u8, self.storage[self.len..old]);
    }
    pub const Look = struct {
        hidden: bool,
        caret: bool,
        placeholder: []const u8,
        /// Off when the caller animates the caret itself from the returned
        /// `CaretPlace` (a blinking, gliding overlay).
        draw_caret: bool = true,
        /// Mask with circles rather than bullet glyphs. The caret and the
        /// placeholder stay on `font_size` either way.
        dots: ?Dots = null,
    };

    /// Where the caret belongs, in the renderer's logical units.
    pub const CaretPlace = struct {
        /// The text's left edge; the caret sits `offset` past it.
        origin_x: f32,
        offset: f32,
        y: f32,
        w: f32,
        h: f32,
        /// How far the text is scrolled. When it changes the text moved under
        /// the caret, so a glide would sweep in from the wrong place.
        scroll: f32,
    };

    /// Paint through the UI renderer's uncached sensitive text path. Neither
    /// the response nor a derived glyph run survives this call in a text cache.
    /// The frame around it is `field.paintSecret`'s. Returns the caret's
    /// place when `look.caret` is set.
    pub fn paint(self: *const Input, r: *Renderer, x: f32, y: f32, w: f32, h: f32, font_size: f32, look: Look) ?CaretPlace {
        const t = r.palette orelse theme.global;
        const dots: ?Dots = if (look.hidden and self.len > 0) look.dots else null;
        const advance = if (dots) |spec|
            self.paintDots(r, x, y, w, h, font_size, spec)
        else
            self.paintText(r, x, y, w, h, font_size, look);
        const scroll = scrollFor(advance, w);
        if (!look.caret) return null;
        // The face's ink box, which is what the text is centred on.
        const ink = text.verticalMetrics(.manrope, font_size, r.scale) catch
            text.VMetrics{ .ascent = font_size * 0.8, .descent = font_size * 0.2 };
        const ink_h = ink.ascent + ink.descent;
        const place = CaretPlace{ .origin_x = x, .offset = advance - scroll, .y = y + (h - ink_h) / 2, .w = t.caret_width, .h = ink_h, .scroll = scroll };
        if (look.draw_caret) r.fillRect(place.origin_x + place.offset, place.y, place.w, place.h, .{ .color = t.caretColor() });
        return place;
    }
    /// How far the row scrolls to keep a caret `advance` in is in a box `w` wide.
    fn scrollFor(advance: f32, w: f32) f32 {
        return @max(0, advance - w + 2);
    }

    /// Bullet glyphs (or the clear text, or the placeholder) through the
    /// sensitive text path. Returns the caret's advance.
    fn paintText(self: *const Input, r: *Renderer, x: f32, y: f32, w: f32, h: f32, font_size: f32, look: Look) f32 {
        const t = r.palette orelse theme.global;
        var mask: [max_bullets * 3]u8 = undefined;
        const shown = if (look.hidden) self.bullets(&mask) else self.value();
        const prefix = if (look.hidden)
            shown[0..@min(shown.len, masked(self.value()[0..self.cursor]) * 3)]
        else
            self.value()[0..self.cursor];
        const advance = text.measureSensitiveWidth(prefix, .manrope, font_size, r.scale) catch 0;
        r.drawTextScrolled(.{ .x = x, .y = y, .w = w, .h = h, .scroll_x = scrollFor(advance, w), .style = .{
            .content = if (shown.len == 0) look.placeholder else shown,
            .font_size = font_size,
            .color = if (shown.len == 0) t.faint else t.fg,
            .sensitive = true,
        } });
        return advance;
    }

    /// One circle per character on a fixed pitch, centred in the box and
    /// clipped to it. Returns the caret's advance.
    fn paintDots(self: *const Input, r: *Renderer, x: f32, y: f32, w: f32, h: f32, font_size: f32, spec: Dots) f32 {
        const t = r.palette orelse theme.global;
        const grid = DotGrid.init(spec, font_size, r.scale);
        const advance = grid.pitch * @as(f32, @floatFromInt(masked(self.value()[0..self.cursor])));
        const origin = @round((x - scrollFor(advance, w)) * r.scale) / r.scale;
        const top = @round(((y + h / 2) - grid.diameter / 2) * r.scale) / r.scale;
        r.clean = false;
        var clipped = r.*;
        clipped.clip = ui_paint.intersectClip(r.clip, .{ .x = x, .y = y, .w = w, .h = h });
        for (0..masked(self.value())) |i| {
            const dot_x = origin + grid.pitch * @as(f32, @floatFromInt(i)) + grid.lead;
            if (dot_x + grid.diameter <= x or dot_x >= x + w) continue;
            clipped.fillRect(dot_x, top, grid.diameter, grid.diameter, .{ .color = t.fg, .radius = grid.diameter / 2 });
        }
        return advance;
    }

    pub fn bullets(self: *const Input, out: []u8) []const u8 {
        var n: usize = 0;
        for (self.value()) |b| if (b & 0xc0 != 0x80 and n + 3 <= out.len) {
            @memcpy(out[n..][0..3], "•");
            n += 3;
        };
        return out[0..n];
    }
};
test "sensitive input edits UTF-8 in place and scrubs removed bytes" {
    var bytes: [12]u8 = @splat(0);
    var input = Input{ .storage = &bytes };
    try std.testing.expect(input.insert("aéz"));
    input.left();
    input.backspace();
    try std.testing.expectEqualStrings("az", input.value());
    try std.testing.expectEqual(@as(u8, 0), bytes[2]);
    try std.testing.expect(input.insert("世"));
    var mask: [36]u8 = undefined;
    try std.testing.expectEqualStrings("•••", input.bullets(&mask));
    try std.testing.expect(!input.insert("\n"));
    try std.testing.expect(!input.insert("0123456789"));
    input.delete();
    try std.testing.expectEqualStrings("a世", input.value());
    input.clear();
    try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(0)), &bytes);
}
