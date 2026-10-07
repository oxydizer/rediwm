//! Character ranges shared by selection hit testing, painting and copying.
const std = @import("std");
const layout = @import("layout.zig");

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn text(self: Range, utf8: []const u8) []const u8 {
        var it = (std.unicode.Utf8View.init(utf8) catch return "").iterator();
        var index: usize = 0;
        while (index < self.start) : (index += 1) _ = it.nextCodepointSlice() orelse return "";
        const first = it.i;
        while (index < self.end) : (index += 1) _ = it.nextCodepointSlice() orelse break;
        return utf8[first..it.i];
    }
};

/// Nearest insertion position. Zero-area rectangles (line breaks) are not
/// pointer targets, but remain in the copied range between visible glyphs.
pub fn position(rects: []const layout.Rect, pt: layout.Point) ?usize {
    var best: ?usize = null;
    var distance = std.math.inf(f64);
    for (rects, 0..) |r, i| {
        if (r.w <= 0 or r.h <= 0) continue;
        const dx = pt.x - std.math.clamp(pt.x, r.x, r.x + r.w);
        const dy = pt.y - std.math.clamp(pt.y, r.y, r.y + r.h);
        const d = dx * dx + dy * dy;
        if (d < distance) {
            distance = d;
            best = i + @as(usize, if (pt.x >= r.x + r.w / 2) 1 else 0);
        }
    }
    return best;
}

pub fn between(rects: []const layout.Rect, from: layout.Point, to: layout.Point) ?Range {
    const start = position(rects, from) orelse return null;
    const end = position(rects, to) orelse return null;
    if (start == end) return null;
    return .{ .start = @min(start, end), .end = @max(start, end) };
}
