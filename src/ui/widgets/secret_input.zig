//! Caller-owned sensitive storage. No heap copies, clipboard or shaping cache.
const std = @import("std");
const text = @import("../text.zig");
const theme = @import("../theme.zig");
const Renderer = @import("../paint.zig").Renderer;

/// Bullets beyond this many are not drawn; no caller stores more characters.
const max_bullets = 512;
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
        var mask: [max_bullets * 3]u8 = undefined;
        const shown = if (look.hidden) self.bullets(&mask) else self.value();
        const prefix = if (look.hidden) blk: {
            var count: usize = 0;
            for (self.value()[0..self.cursor]) |b| {
                if (b & 0xc0 != 0x80) count += 1;
            }
            break :blk shown[0..@min(shown.len, count * 3)];
        } else self.value()[0..self.cursor];
        const advance = text.measureSensitiveWidth(prefix, .manrope, font_size, r.scale) catch 0;
        const scroll = @max(0, advance - w + 2);
        r.drawTextScrolled(.{ .x = x, .y = y, .w = w, .h = h, .scroll_x = scroll, .style = .{
            .content = if (shown.len == 0) look.placeholder else shown,
            .font_size = font_size,
            .color = if (shown.len == 0) t.faint else t.fg,
            .sensitive = true,
        } });
        if (!look.caret) return null;
        // The face's ink box, which is what the text is centred on.
        const ink = text.verticalMetrics(.manrope, font_size, r.scale) catch
            text.VMetrics{ .ascent = font_size * 0.8, .descent = font_size * 0.2 };
        const ink_h = ink.ascent + ink.descent;
        const place = CaretPlace{ .origin_x = x, .offset = advance - scroll, .y = y + (h - ink_h) / 2, .w = t.caret_width, .h = ink_h, .scroll = scroll };
        if (look.draw_caret) r.fillRect(place.origin_x + place.offset, place.y, place.w, place.h, .{ .color = t.caretColor() });
        return place;
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
