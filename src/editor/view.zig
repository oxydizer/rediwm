//! What is on screen. Text reaches Pango one display segment at a time (see
//! lines.zig) and layouts are cached by content, so opening, scrolling and
//! editing cost the same for a megabyte as for a gigabyte: only the lines
//! near the viewport are ever laid out. The scroll position is a byte offset
//! (`Document.top`) plus a pixel offset into that line, never a pixel count
//! from the start of the file, which would need every line's height.
const std = @import("std");
const c = @import("../files/c.zig").api;
const p = @import("pango.zig");
const Document = @import("document.zig").Document;
const lines = @import("lines.zig");
const a = std.heap.c_allocator;

/// Documents up to this size are measured exactly, so their scrollbar and
/// scrolling behave as if the whole text were one layout. Larger ones
/// estimate their height from the lines seen so far.
const exact_limit: usize = 32 * 1024;
/// How far from the view, in viewports, a position is still looked up by
/// walking lines rather than by jumping the view to it.
const reach_views = 3;

pub const Line = struct {
    seg: lines.Segment,
    layout: *p.Layout,
    height: f64,

    /// The text laid out, for translating Pango indices.
    pub fn textLen(l: Line) usize {
        return l.seg.text_end - l.seg.start;
    }
    pub fn index(l: Line, pos: usize) c_int {
        return @intCast(@min(pos -| l.seg.start, l.textLen()));
    }
};

/// Layouts of recently shown segments, keyed by their text, so editing one
/// line or scrolling by one line lays out one line. Nothing here depends on
/// where in the document a segment is, only on its bytes, the width and the font.
pub const Layouts = struct {
    const Entry = struct { layout: *p.Layout, height: f64, used: u64, len: usize };
    const max_entries = 2048;
    const max_bytes = 1024 * 1024;
    map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    surface: ?*c.cairo_surface_t = null,
    cr: ?*c.cairo_t = null,
    font: ?*p.Font = null,
    family: u64 = 0,
    size: f64 = 0,
    width: i32 = 0,
    scale: i32 = 0,
    /// Advanced once per painted frame; entries used this frame or the last survive a sweep.
    frame: u64 = 2,
    bytes: usize = 0,
    /// Sizes at which the cache next drops what the last frames did not use;
    /// doubled when that frees nothing, so one long walk is not swept per line.
    trim_count: usize = max_entries,
    trim_bytes: usize = max_bytes,
    sampled_bytes: f64 = 0,
    sampled_height: f64 = 0,
    /// Changes whenever cached heights stop being valid.
    epoch: usize = 1,

    pub fn deinit(l: *Layouts) void {
        l.flush();
        l.map.deinit(a);
        if (l.font) |f| p.pango_font_description_free(f);
        if (l.cr) |cr| c.cairo_destroy(cr);
        if (l.surface) |s| c.cairo_surface_destroy(s);
    }

    fn flush(l: *Layouts) void {
        var it = l.map.valueIterator();
        while (it.next()) |e| p.g_object_unref(e.layout);
        l.map.clearRetainingCapacity();
        l.bytes = 0;
        l.sampled_bytes = 0;
        l.sampled_height = 0;
        l.epoch +%= 1;
    }

    /// Sets how text is laid out; a change drops every cached layout.
    /// `wrap_width` is in logical pixels, null for no wrapping.
    pub fn configure(l: *Layouts, family: []const u8, size: f64, wrap_width: ?i32, scale: i32) void {
        const hash = std.hash.Wyhash.hash(0, family);
        const width: i32 = if (wrap_width) |w| @max(1, w) * 1024 else -1;
        if (l.font != null and l.family == hash and l.size == size and l.width == width and l.scale == scale) return;
        l.flush();
        l.family = hash;
        l.size = size;
        l.width = width;
        l.scale = scale;
        var buf: [256:0]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "{s}", .{family}) catch "monospace";
        if (l.font) |f| p.pango_font_description_free(f);
        l.font = p.pango_font_description_from_string(name);
        if (l.font) |f| p.pango_font_description_set_absolute_size(f, size * 1024);
        if (l.cr) |cr| c.cairo_destroy(cr);
        if (l.surface) |s| c.cairo_surface_destroy(s);
        l.surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
        l.cr = c.cairo_create(l.surface);
        c.cairo_scale(l.cr, @floatFromInt(scale), @floatFromInt(scale));
    }

    pub fn beginFrame(l: *Layouts) void {
        l.frame += 1;
    }

    fn sweep(l: *Layouts) void {
        var doomed: std.ArrayList(u64) = .empty;
        defer doomed.deinit(a);
        var it = l.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.used + 1 < l.frame) doomed.append(a, kv.key_ptr.*) catch return;
        }
        for (doomed.items) |key| l.drop(key);
    }

    fn drop(l: *Layouts, key: u64) void {
        const e = (l.map.fetchRemove(key) orelse return).value;
        l.bytes -= e.len;
        p.g_object_unref(e.layout);
    }

    /// The layout of one segment of `text`, or null if memory ran out.
    pub fn line(l: *Layouts, text: []const u8, seg: lines.Segment) ?Line {
        const content = text[seg.start..seg.text_end];
        const key = std.hash.Wyhash.hash(0, content);
        if (l.map.getPtr(key)) |e| {
            if (e.len == content.len and std.mem.eql(u8, std.mem.span(p.pango_layout_get_text(e.layout)), content)) {
                e.used = l.frame;
                return .{ .seg = seg, .layout = e.layout, .height = e.height };
            }
            l.drop(key);
        }
        const cr = l.cr orelse return null;
        const font = l.font orelse return null;
        if (l.map.count() >= l.trim_count or l.bytes >= l.trim_bytes) {
            l.sweep();
            l.trim_count = @max(max_entries, l.map.count() * 2);
            l.trim_bytes = @max(max_bytes, l.bytes * 2);
        }
        const layout = p.pango_cairo_create_layout(cr) orelse return null;
        p.pango_layout_set_font_description(layout, font);
        p.pango_layout_set_width(layout, l.width);
        p.pango_layout_set_wrap(layout, 2);
        p.pango_layout_set_text(layout, content.ptr, @intCast(content.len));
        p.pango_cairo_update_layout(cr, layout);
        var extents: p.Rectangle = undefined;
        p.pango_layout_get_extents(layout, null, &extents);
        const height = @max(1, @as(f64, @floatFromInt(extents.height)) / 1024);
        l.map.put(a, key, .{ .layout = layout, .height = height, .used = l.frame, .len = content.len }) catch {
            p.g_object_unref(layout);
            return null;
        };
        l.bytes += content.len;
        l.sampled_bytes += @floatFromInt(content.len + 1);
        l.sampled_height += height;
        return .{ .seg = seg, .layout = layout, .height = height };
    }

    /// Average height per byte of the text laid out so far.
    pub fn heightPerByte(l: *const Layouts) f64 {
        return if (l.sampled_bytes > 0) l.sampled_height / l.sampled_bytes else 0.25;
    }
};

pub const Row = struct { line: Line, y: f64 };

/// Remembers the exact height of a small document so the scrollbar does not
/// re-measure it on every query.
pub const Measure = struct {
    revision: usize = std.math.maxInt(usize),
    epoch: usize = 0,
    total: f64 = 0,
    top: usize = std.math.maxInt(usize),
    before: f64 = 0,
};

/// Scrollbar geometry in one unit: pixels for a small document, bytes for a
/// large one (whose pixel height is only an estimate that keeps improving, and
/// a drag in progress must not see its units change under it).
pub const Extent = struct { content: f64, viewport: f64, offset: f64 };

/// The view of one document: where it is scrolled to and how tall it is.
pub const Port = struct {
    doc: *Document,
    layouts: *Layouts,
    /// Height of the text area in logical pixels.
    height: f64,
    /// Pixels of the top line scrolled out of view.
    dy: *f64,

    fn text(s: Port) []const u8 {
        return s.doc.text.items;
    }
    fn lineAt(s: Port, pos: usize) ?Line {
        return s.layouts.line(s.text(), s.doc.segmentAt(pos));
    }
    fn nextLine(s: Port, l: Line) ?Line {
        return s.layouts.line(s.text(), lines.after(s.text(), l.seg, lines.fold) orelse return null);
    }
    fn prevLine(s: Port, l: Line) ?Line {
        return s.layouts.line(s.text(), lines.before(s.text(), l.seg, lines.fold) orelse return null);
    }
    /// The first visible line, snapping `doc.top` onto a segment start.
    fn topLine(s: Port) ?Line {
        const l = s.lineAt(s.doc.top) orelse return null;
        s.doc.top = l.seg.start;
        return l;
    }

    /// Keeps `dy` inside the top line by moving the top line itself.
    fn normalize(s: Port) void {
        var cur = s.topLine() orelse return;
        var guard: usize = 0;
        while (guard < 100_000) : (guard += 1) {
            if (s.dy.* < 0) {
                const prev = s.prevLine(cur) orelse {
                    s.dy.* = 0;
                    break;
                };
                cur = prev;
                s.dy.* += prev.height;
            } else if (s.dy.* >= cur.height) {
                const next = s.nextLine(cur) orelse break;
                s.dy.* -= cur.height;
                cur = next;
            } else break;
        }
        s.doc.top = cur.seg.start;
    }

    /// Scrolls so the end of the text sits at the bottom of the view (or the
    /// start at the top, if everything fits).
    pub fn scrollToEnd(s: Port) void {
        var cur = s.lineAt(s.text().len) orelse return;
        var acc = cur.height;
        while (acc < s.height) {
            cur = s.prevLine(cur) orelse {
                s.doc.top = 0;
                s.dy.* = 0;
                return;
            };
            acc += cur.height;
        }
        s.doc.top = cur.seg.start;
        s.dy.* = acc - s.height;
    }

    /// Normalizes the position and pulls it back if it shows space past the end.
    pub fn clamp(s: Port) void {
        s.normalize();
        var cur = s.topLine() orelse return;
        var y = -s.dy.*;
        while (true) {
            y += cur.height;
            if (y >= s.height) return;
            cur = s.nextLine(cur) orelse break;
        }
        s.scrollToEnd();
    }

    pub fn scrollBy(s: Port, pixels: f64) void {
        s.dy.* += pixels;
        s.clamp();
    }

    /// The lines intersecting the view, with their top edges relative to it.
    pub fn visible(s: Port, rows: *std.ArrayList(Row)) void {
        rows.clearRetainingCapacity();
        var cur = s.topLine() orelse return;
        var y = -s.dy.*;
        while (true) {
            rows.append(a, .{ .line = cur, .y = y }) catch return;
            y += cur.height;
            if (y >= s.height) return;
            cur = s.nextLine(cur) orelse return;
        }
    }

    /// The line containing `pos` and its top edge relative to the view, or
    /// null if it is more than a few viewports away.
    pub fn locate(s: Port, pos: usize) ?Row {
        const target = s.doc.segmentAt(pos).start;
        var cur = s.topLine() orelse return null;
        var y = -s.dy.*;
        const reach = s.height * reach_views;
        if (target >= cur.seg.start) {
            while (y <= reach) {
                if (cur.seg.start == target) return .{ .line = cur, .y = y };
                y += cur.height;
                cur = s.nextLine(cur) orelse return null;
            }
        } else {
            while (y >= -reach) {
                cur = s.prevLine(cur) orelse return null;
                y -= cur.height;
                if (cur.seg.start == target) return .{ .line = cur, .y = y };
            }
        }
        return null;
    }

    /// Scrolls so the line holding `pos` is about a third of the way down.
    pub fn jumpTo(s: Port, pos: usize) void {
        var cur = s.lineAt(pos) orelse return;
        const want = s.height / 3;
        var above: f64 = 0;
        while (above < want) {
            cur = s.prevLine(cur) orelse break;
            above += cur.height;
        }
        s.doc.top = cur.seg.start;
        s.dy.* = @max(0, above - want);
        s.clamp();
    }

    /// The byte offset nearest (x, y), both relative to the view's text origin.
    pub fn indexAt(s: Port, x: f64, y: f64) usize {
        var cur = s.topLine() orelse return 0;
        var top = -s.dy.*;
        var guard: usize = 0;
        while (y < top and guard < 10_000) : (guard += 1) {
            cur = s.prevLine(cur) orelse break;
            top -= cur.height;
        }
        while (y >= top + cur.height and guard < 10_000) : (guard += 1) {
            const next = s.nextLine(cur) orelse break;
            top += cur.height;
            cur = next;
        }
        const local = std.math.clamp(y - top, 0, cur.height - 0.01);
        var idx: c_int = 0;
        var trailing: c_int = 0;
        _ = p.pango_layout_xy_to_index(cur.layout, @intFromFloat(std.math.clamp(x * 1024, -1e9, 1e9)), @intFromFloat(local * 1024), &idx, &trailing);
        var offset = cur.seg.start + @as(usize, @intCast(@max(0, idx)));
        while (trailing > 0 and offset < cur.seg.text_end) : (trailing -= 1) offset += std.unicode.utf8ByteSequenceLength(s.text()[offset]) catch 1;
        return @min(offset, cur.seg.text_end);
    }

    /// The scrollable length and the current offset in the same units.
    pub fn extent(s: Port, memo: *Measure) Extent {
        const len = s.text().len;
        if (len <= exact_limit) {
            if (memo.revision != s.doc.revision or memo.epoch != s.layouts.epoch) {
                memo.* = .{ .revision = s.doc.revision, .epoch = s.layouts.epoch };
                var total: f64 = 0;
                var cur = s.lineAt(0);
                while (cur) |l| : (cur = s.nextLine(l)) total += l.height;
                memo.total = total;
            }
            if (memo.top != s.doc.top) {
                var before: f64 = 0;
                var cur = s.lineAt(0);
                while (cur) |l| : (cur = s.nextLine(l)) {
                    if (l.seg.start >= s.doc.top) break;
                    before += l.height;
                }
                memo.top = s.doc.top;
                memo.before = before;
            }
            return .{ .content = memo.total, .viewport = s.height, .offset = memo.before + s.dy.* };
        }
        const cur = s.lineAt(s.doc.top) orelse return .{ .content = 0, .viewport = 0, .offset = 0 };
        const fraction = std.math.clamp(s.dy.* / cur.height, 0, 1);
        const at = @as(f64, @floatFromInt(cur.seg.start)) + fraction * @as(f64, @floatFromInt(cur.seg.len()));
        return .{ .content = @floatFromInt(len + 1), .viewport = s.height / s.layouts.heightPerByte(), .offset = at };
    }

    /// Scrolls to `offset`, which is in the units `extent` reports.
    pub fn seek(s: Port, memo: *Measure, offset: f64) void {
        const e = s.extent(memo);
        if (offset >= e.content - e.viewport - 0.5) return s.scrollToEnd();
        if (s.text().len <= exact_limit) {
            var acc: f64 = 0;
            var cur = s.lineAt(0);
            while (cur) |l| : (cur = s.nextLine(l)) {
                if (acc + l.height > offset or s.nextLine(l) == null) {
                    s.doc.top = l.seg.start;
                    s.dy.* = offset - acc;
                    break;
                }
                acc += l.height;
            }
        } else {
            const at = @min(@max(0, offset), @as(f64, @floatFromInt(s.text().len)));
            const cur = s.lineAt(@intFromFloat(at)) orelse return;
            const fraction = std.math.clamp((at - @as(f64, @floatFromInt(cur.seg.start))) / @as(f64, @floatFromInt(@max(1, cur.seg.len()))), 0, 1);
            s.doc.top = cur.seg.start;
            s.dy.* = fraction * cur.height;
        }
        s.clamp();
    }
};

fn testLayouts() Layouts {
    var l: Layouts = .{};
    l.configure("monospace", 13, null, 1);
    return l;
}

fn bigText(a_: std.mem.Allocator, lines_n: usize) !std.ArrayList(u8) {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a_);
    for (0..lines_n) |i| try text.print(a_, "line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    return text;
}

test "scrolling a large document only ever walks a few lines" {
    var source = try bigText(std.testing.allocator, 200_000);
    defer source.deinit(std.testing.allocator);
    var doc = try Document.init(source.items);
    defer doc.deinit();
    var layouts = testLayouts();
    defer layouts.deinit();
    var dy: f64 = 0;
    const port: Port = .{ .doc = &doc, .layouts = &layouts, .height = 400, .dy = &dy };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    port.visible(&rows);
    try std.testing.expect(rows.items.len > 10 and rows.items.len < 60);
    const line_h = rows.items[0].line.height;
    port.scrollBy(line_h * 1000.5);
    port.visible(&rows);
    try std.testing.expectEqual(@as(usize, 1000), std.mem.count(u8, doc.text.items[0..doc.top], "\n"));
    try std.testing.expectApproxEqAbs(line_h / 2, dy, 0.01);
    port.scrollBy(-line_h * 10_000);
    try std.testing.expectEqual(@as(usize, 0), doc.top);
    try std.testing.expectEqual(@as(f64, 0), dy);
    port.scrollToEnd();
    port.visible(&rows);
    const last = rows.items[rows.items.len - 1];
    try std.testing.expectApproxEqAbs(@as(f64, 400), last.y + last.line.height, 0.01);
    try std.testing.expect(last.line.seg.start == doc.text.items.len);
    // Far positions are reached by jumping, near ones by walking.
    port.jumpTo(doc.text.items.len / 2);
    const mid = port.locate(doc.text.items.len / 2).?;
    try std.testing.expect(mid.y >= 0 and mid.y < 400);
    try std.testing.expect(port.locate(0) == null);
    port.scrollBy(line_h * 3);
    layouts.beginFrame();
    layouts.beginFrame();
    port.visible(&rows);
    try std.testing.expect(rows.items.len < 60);
}

test "a three megabyte single line is folded and stays addressable" {
    const mib3 = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer std.testing.allocator.free(mib3);
    for (mib3, 0..) |*b, i| b.* = if (i % 11 == 10) ' ' else 'a' + @as(u8, @intCast(i % 26));
    var doc = try Document.init(mib3);
    defer doc.deinit();
    var layouts = testLayouts();
    defer layouts.deinit();
    var dy: f64 = 0;
    const port: Port = .{ .doc = &doc, .layouts = &layouts, .height = 300, .dy = &dy };
    port.jumpTo(1_500_000);
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(a);
    port.visible(&rows);
    try std.testing.expect(rows.items.len >= 1);
    // A piece may be shorter or longer than the fold by the look-back for a space.
    for (rows.items) |r| try std.testing.expect(r.line.seg.len() <= lines.fold + 300);
    const hit = port.indexAt(30, 20);
    try std.testing.expect(hit > 1_000_000 and hit < 2_000_000);
    var memo: Measure = .{};
    const e = port.extent(&memo);
    try std.testing.expect(e.content > e.viewport and e.offset > 0 and e.offset < e.content - e.viewport);
    port.seek(&memo, 0);
    try std.testing.expectEqual(@as(usize, 0), doc.top);
}

test "small documents measure exactly and seek by pixels" {
    var doc = try Document.init("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n");
    defer doc.deinit();
    var layouts = testLayouts();
    defer layouts.deinit();
    var dy: f64 = 0;
    const port: Port = .{ .doc = &doc, .layouts = &layouts, .height = 40, .dy = &dy };
    var memo: Measure = .{};
    var e = port.extent(&memo);
    const row = e.content / 9;
    try std.testing.expect(row > 5);
    port.seek(&memo, row * 2.5);
    e = port.extent(&memo);
    try std.testing.expectApproxEqAbs(row * 2.5, e.offset, 0.01);
    try std.testing.expectEqual(@as(usize, 8), doc.top);
    port.seek(&memo, 1e9);
    port.clamp();
    e = port.extent(&memo);
    try std.testing.expectApproxEqAbs(e.content - 40, e.offset, 0.01);
}
