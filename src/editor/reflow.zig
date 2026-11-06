//! Glides the lines an edit moved. Enter pushes every line below it down and
//! carries the rest of its line onto a new one; Backspace joining two lines,
//! deleting lines, undo or a word that now wraps move lines too. Instead of
//! snapping, each visible line that changed place is drawn where it was and
//! eased to where it is, over the caret's motion time, and the caret rides the
//! line it sits in.
//!
//! Layout never animates: rows are laid out and hit-tested at rest. A `Move`
//! is only a paint offset for the row starting at one byte offset, and it ends
//! with the animation. Rows are matched to the lines of the previous frame
//! through the span an edit left alone (`Document.Change`): a row before it
//! keeps its start, a row after it starts `new_len - old_len` bytes later.
const std = @import("std");
const anim = @import("ui").anim;
const p = @import("pango.zig");
const view = @import("view.zig");
const Change = @import("document.zig").Change;
const a = std.heap.c_allocator;

/// A line that would have to travel further than this vertically is a jump,
/// not a glide (the caret's own rule, see `input.caret_snap_distance`), so the
/// whole edit snaps.
pub const max_glide: f64 = 120;

/// Where a row is drawn relative to its rest place.
pub const Offset = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    alpha: f32 = 1,

    /// Whole device pixels: a fractional offset re-hints every glyph.
    pub fn snapped(o: Offset, scale: f32) Offset {
        return .{ .dx = @round(o.dx * scale) / scale, .dy = @round(o.dy * scale) / scale, .alpha = o.alpha };
    }
};

/// What the remembered rows belong to: a different tab, or layouts that were
/// rebuilt (resize, font, wrapping), make them meaningless.
pub const Key = struct { tab: usize, epoch: usize, width: f64 };

const Shown = struct { start: usize, next: usize, y: f64 };
const Move = struct { start: usize, dx: f32, dy: f32, fade: bool };

pub const Reflow = struct {
    /// The visible rows as last laid out, in order: where each began and its
    /// rest place. Where it was drawn is that plus whatever `moves` still has.
    shown: std.ArrayList(Shown) = .empty,
    moves: std.ArrayList(Move) = .empty,
    /// 1 when an edit lands, easing to 0 when every row is at rest.
    clock: anim.Anim = .{},
    key: Key = .{ .tab = 0, .epoch = 0, .width = 0 },
    /// Length of the text `shown` describes; null until a frame was seen.
    len: ?usize = null,

    pub fn deinit(r: *Reflow) void {
        r.shown.deinit(a);
        r.moves.deinit(a);
    }

    /// Drops what was remembered and whatever is moving.
    pub fn forget(r: *Reflow) void {
        r.shown.clearRetainingCapacity();
        r.moves.clearRetainingCapacity();
        r.len = null;
    }

    pub fn moving(r: *const Reflow, now: i64) bool {
        return r.moves.items.len > 0 and !r.clock.settled(now);
    }

    /// Ends a finished animation. True once, when it ends, so the rows are
    /// drawn once more at rest.
    pub fn settle(r: *Reflow, now: i64) bool {
        if (r.moves.items.len == 0 or !r.clock.settled(now)) return false;
        r.moves.clearRetainingCapacity();
        return true;
    }

    /// Where the row beginning at byte `start` is drawn now, relative to rest.
    pub fn offset(r: *const Reflow, start: usize, now: i64) Offset {
        if (!r.moving(now)) return .{};
        const left = r.clock.value(now);
        for (r.moves.items) |m| {
            if (m.start != start) continue;
            return .{ .dx = m.dx * left, .dy = m.dy * left, .alpha = if (m.fade) 1 - left else 1 };
        }
        return .{};
    }

    /// Remembers the rows just laid out, so the next edit can start from
    /// where they are on screen. Call it when a frame is drawn.
    pub fn remember(r: *Reflow, key: Key, len: usize, rows: []const view.Row) void {
        r.shown.clearRetainingCapacity();
        r.key = key;
        r.len = len;
        for (rows) |row| {
            r.shown.append(a, .{ .start = row.line.seg.start, .next = row.line.seg.next, .y = row.y }) catch return r.forget();
        }
    }

    /// Where a remembered row is drawn at `now`.
    const Found = struct { start: usize, dx: f64, y: f64 };

    /// The remembered row holding old offset `o`, as drawn at `now`.
    fn find(r: *const Reflow, o: usize, now: i64) ?Found {
        var low: usize = 0;
        var high = r.shown.items.len;
        while (low < high) {
            const mid = (low + high) / 2;
            if (r.shown.items[mid].start <= o) low = mid + 1 else high = mid;
        }
        if (low == 0) return null;
        const row = r.shown.items[low - 1];
        if (o > row.next or (o == row.next and row.next != r.len)) return null;
        const at = r.offset(row.start, now);
        return .{ .start = row.start, .dx = at.dx, .y = row.y + at.dy };
    }

    /// Starts moving the rows an `edit` displaced; `rows` are the visible rows
    /// of the new text, at rest. Returns whether anything glides. If not
    /// (nothing moved, it moved too far, lines with new text appeared, motion
    /// is off) every row is at rest. Either way the new rows are remembered.
    pub fn apply(r: *Reflow, now: i64, ms: u32, key: Key, edit: Change, rows: []const view.Row) bool {
        const glided = r.plan(now, ms, key, edit, rows);
        if (!glided) r.moves.clearRetainingCapacity();
        r.remember(key, edit.new_len, rows);
        return glided;
    }

    fn plan(r: *Reflow, now: i64, ms: u32, key: Key, edit: Change, rows: []const view.Row) bool {
        const known = r.len orelse return false;
        if (known != edit.old_len or r.key.tab != key.tab or r.key.epoch != key.epoch) return false;
        const clock = anim.Anim.initDuration(1, 0, now, ms, .out_cubic);
        if (ms == 0 or clock.completesInstantly()) return false;
        var moves: std.ArrayList(Move) = .empty;
        var keep = false;
        defer if (!keep) moves.deinit(a);
        const lo = edit.lo;
        const hi = edit.hi();
        // Where the previous row was drawn relative to rest: the text after a
        // line break starts where the text before it ended.
        var before: Offset = .{};
        for (rows, 0..) |row, i| {
            const n = row.line.seg.start;
            const m = row.line.seg.next;
            var here: Offset = .{};
            var fade = false;
            if (n < lo or (n == lo and m > hi)) {
                // Before the edit, or the line it happened in: the same line.
                if (r.find(n, now)) |at| if (at.start == n) {
                    here = .{ .dx = @floatCast(at.dx), .dy = @floatCast(at.y - row.y) };
                };
            } else if (n < hi or (n == lo and m <= hi)) {
                // A line the edit made: nothing to glide from, and drawing
                // it at once would overprint the line it pushes down.
                if (row.line.textLen() > 0) return false;
            } else if (r.find(edit.oldAfter(n), now)) |at| {
                if (at.start == edit.oldAfter(n)) {
                    here = .{ .dx = @floatCast(at.dx), .dy = @floatCast(at.y - row.y) };
                } else if (n == hi and i > 0 and rows[i - 1].line.seg.next == n and rows[i - 1].line.seg.terminated()) {
                    // The rest of a line that was split starts where the
                    // text before the break now ends.
                    const above = rows[i - 1];
                    var end: p.Rectangle = undefined;
                    p.pango_layout_get_cursor_pos(above.line.layout, @intCast(above.line.textLen()), &end, null);
                    here = .{
                        .dx = before.dx + @as(f32, @floatFromInt(end.x)) / 1024,
                        .dy = @floatCast(above.y + before.dy + @as(f64, @floatFromInt(end.y)) / 1024 - row.y),
                    };
                    fade = true;
                }
            }
            before = here;
            if (@abs(here.dy) > max_glide or @abs(here.dx) > key.width) return false;
            if (!fade and @abs(here.dx) < 0.5 and @abs(here.dy) < 0.5) continue;
            moves.append(a, .{ .start = n, .dx = here.dx, .dy = here.dy, .fade = fade }) catch return false;
        }
        if (moves.items.len == 0) return false;
        keep = true;
        r.moves.deinit(a);
        r.moves = moves;
        r.clock = clock;
        return true;
    }
};

fn testLayouts() view.Layouts {
    var l: view.Layouts = .{};
    l.configure("monospace", 13, 400, 1);
    return l;
}

/// A document, the layouts of its rows and a `Reflow` watching them.
const Scene = struct {
    doc: @import("document.zig").Document,
    layouts: view.Layouts,
    dy: f64 = 0,
    rows: std.ArrayList(view.Row) = .empty,
    reflow: Reflow = .{},

    fn init(text: []const u8) !Scene {
        return .{ .doc = try @import("document.zig").Document.init(text), .layouts = testLayouts() };
    }
    fn deinit(s: *Scene) void {
        s.reflow.deinit();
        s.rows.deinit(a);
        s.layouts.deinit();
        s.doc.deinit();
    }
    fn key(s: *const Scene) Key {
        return .{ .tab = 1, .epoch = s.layouts.epoch, .width = 400 };
    }
    fn show(s: *Scene) void {
        const port: view.Port = .{ .doc = &s.doc, .layouts = &s.layouts, .height = 300, .dy = &s.dy };
        port.clamp();
        port.visible(&s.rows);
    }
    fn height(s: *const Scene) f32 {
        return @floatCast(s.rows.items[0].line.height);
    }
    /// Draws the first frame, so there is something to glide from.
    fn start(s: *Scene) void {
        s.show();
        s.reflow.forget();
        s.reflow.remember(s.key(), s.doc.text.items.len, s.rows.items);
    }
    fn edit(s: *Scene, now: i64) bool {
        s.show();
        return s.reflow.apply(now, 120, s.key(), s.doc.takeChange().?, s.rows.items);
    }
    fn at(s: *const Scene, row: usize, now: i64) Offset {
        return s.reflow.offset(s.rows.items[row].line.seg.start, now);
    }
};

test "Enter carries the rest of the line down and pushes later lines after it" {
    var s = try Scene.init("abcdef\nlast");
    defer s.deinit();
    s.start();
    s.doc.move(3, false);
    try s.doc.insert("\n");
    try std.testing.expect(s.edit(1000));
    try std.testing.expectEqual(@as(usize, 3), s.rows.items.len);
    const h = s.height();
    // The old last line was one line higher, and has not moved sideways.
    try std.testing.expectApproxEqAbs(-h, s.at(2, 1000).dy, 0.01);
    try std.testing.expectEqual(@as(f32, 0), s.at(2, 1000).dx);
    try std.testing.expectEqual(@as(f32, 1), s.at(2, 1000).alpha);
    // The tail starts right after "abc" on the first line, and fades in.
    const tail = s.at(1, 1000);
    try std.testing.expectApproxEqAbs(-h, tail.dy, 0.01);
    try std.testing.expect(tail.dx > 10);
    try std.testing.expectEqual(@as(f32, 0), tail.alpha);
    // The line the edit happened in does not move.
    try std.testing.expectEqual(Offset{}, s.at(0, 1000));
    // It eases out: a quarter of the way in, most of the distance is covered.
    const early = s.at(2, 1030);
    try std.testing.expect(early.dy < 0 and early.dy > -h / 2);
    try std.testing.expect(s.reflow.moving(1100));
    try std.testing.expect(!s.reflow.moving(1200));
    try std.testing.expect(s.reflow.settle(1200));
    try std.testing.expect(!s.reflow.settle(1200));
    try std.testing.expectEqual(Offset{}, s.at(2, 1200));
}

test "Enter at the start or end of a line glides without a sideways jump" {
    var s = try Scene.init("abc\ndef");
    defer s.deinit();
    s.start();
    s.doc.move(0, false);
    try s.doc.insert("\n");
    try std.testing.expect(s.edit(0));
    // "abc" was on the first line and is now on the second.
    try std.testing.expectApproxEqAbs(-s.height(), s.at(1, 0).dy, 0.01);
    try std.testing.expectEqual(@as(f32, 0), s.at(1, 0).dx);
    try std.testing.expectEqual(@as(f32, 1), s.at(1, 0).alpha);

    var end = try Scene.init("abc\ndef");
    defer end.deinit();
    end.start();
    end.doc.move(end.doc.lineEnd(0), false);
    try end.doc.insert("\n");
    try std.testing.expect(end.edit(0));
    // The new line is empty, but the caret still rides it from the line end.
    try std.testing.expect(end.at(1, 0).dx > 10);
    try std.testing.expectApproxEqAbs(-end.height(), end.at(1, 0).dy, 0.01);
}

test "joining lines glides the lines below up; typing glides nothing" {
    var s = try Scene.init("abc\ndef\nghi");
    defer s.deinit();
    s.start();
    s.doc.cursor = 4;
    s.doc.anchor = 3;
    try s.doc.insert("");
    try std.testing.expect(s.edit(0));
    try std.testing.expectEqual(@as(usize, 2), s.rows.items.len);
    try std.testing.expectApproxEqAbs(s.height(), s.at(1, 0).dy, 0.01);
    try std.testing.expectEqual(Offset{}, s.at(0, 0));

    var typing = try Scene.init("abc\ndef\nghi");
    defer typing.deinit();
    typing.start();
    try typing.doc.insert("x");
    try std.testing.expect(!typing.edit(0));
    try std.testing.expect(!typing.reflow.moving(0));
}

test "edits that cannot glide snap: new lines with text, far moves, other tabs, motion off" {
    var pasted = try Scene.init("abc\ndef");
    defer pasted.deinit();
    pasted.start();
    try pasted.doc.insert("one\ntwo\n");
    try std.testing.expect(!pasted.edit(0));
    try std.testing.expectEqual(@as(usize, 0), pasted.reflow.moves.items.len);

    // A few empty lines glide; enough to push a line across the window do not.
    const lines = try std.testing.allocator.alloc(u8, 83);
    defer std.testing.allocator.free(lines);
    for (0..40) |i| @memcpy(lines[i * 2 ..][0..2], "a\n");
    @memcpy(lines[80..], "end");
    var many = try Scene.init(lines);
    defer many.deinit();
    many.start();
    try many.doc.insert("\n\n");
    try std.testing.expect(many.edit(0));
    many.start();
    try many.doc.insert("\n\n\n\n\n\n\n\n\n\n\n\n");
    try std.testing.expect(!many.edit(0));

    var other = try Scene.init("abc");
    defer other.deinit();
    other.start();
    try other.doc.insert("\n");
    other.show();
    var key = other.key();
    key.tab = 2;
    try std.testing.expect(!other.reflow.apply(0, 120, key, other.doc.takeChange().?, other.rows.items));

    var still = try Scene.init("abc");
    defer still.deinit();
    still.start();
    try still.doc.insert("\n");
    still.show();
    try std.testing.expect(!still.reflow.apply(0, 0, still.key(), still.doc.takeChange().?, still.rows.items));

    // Changes that were not seen from the start of the text are refused.
    var unseen = try Scene.init("abc");
    defer unseen.deinit();
    unseen.start();
    try unseen.doc.insert("x");
    _ = unseen.doc.takeChange();
    try unseen.doc.insert("\n");
    try std.testing.expect(!unseen.edit(0));
}

test "a second edit during a glide continues from where the rows are drawn" {
    var s = try Scene.init("abc\ndef");
    defer s.deinit();
    s.start();
    try s.doc.insert("\n");
    try std.testing.expect(s.edit(1000));
    const h = s.height();
    const drawn = s.at(2, 1030);
    try std.testing.expect(drawn.dy < 0 and drawn.dy > -h);
    try s.doc.insert("\n");
    try std.testing.expect(s.edit(1030));
    // The last line starts the new glide where the old one had left it.
    try std.testing.expectApproxEqAbs(drawn.dy - h, s.at(3, 1030).dy, 0.01);
}
