const std = @import("std");
const tt = @import("title_tabs.zig");

const three = [_]tt.Tab{
    .{ .id = 1, .title = "one", .active = true, .attention = false },
    .{ .id = 2, .title = "two", .active = false, .attention = false },
    .{ .id = 3, .title = "three", .active = false, .attention = true },
};
const retitled = [_]tt.Tab{
    .{ .id = 1, .title = "uno", .active = true, .attention = false },
    .{ .id = 2, .title = "two", .active = false, .attention = false },
    .{ .id = 3, .title = "three", .active = false, .attention = true },
};
const width = 900;

fn strip() tt.Strip {
    return .{ .tabs = &three };
}

test "geometry lays three tabs side by side with the plus after them" {
    const g = tt.geometry(width, 1, strip());
    try std.testing.expectEqual(@as(usize, 3), g.count);
    try std.testing.expectEqual(@as(usize, 0), g.first);
    try std.testing.expect(g.previous == null and g.next == null);
    try std.testing.expect(g.tab(1).x > g.tab(0).x + g.tab(0).w);
    try std.testing.expect(g.plus.x >= g.tab(2).x + g.tab(2).w);
}

test "hit finds tabs, close buttons and the plus button" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    for (three, 0..) |t, i| {
        const r = g.tab(i);
        try std.testing.expectEqual(tt.Hit{ .tab = t.id }, tt.hit(width, 1, s, r.x + 2, r.y + r.h / 2));
        const c = g.close(i);
        try std.testing.expectEqual(tt.Hit{ .close = t.id }, tt.hit(width, 1, s, c.x + c.w / 2, c.y + c.h / 2));
    }
    try std.testing.expectEqual(tt.Hit.plus, tt.hit(width, 1, s, g.plus.x + g.plus.w / 2, g.plus.y + g.plus.h / 2));
    try std.testing.expectEqual(tt.Hit.none, tt.hit(width, 1, s, 0, 0));
}

test "an empty strip has no hits and no hash" {
    const s: tt.Strip = .{};
    try std.testing.expectEqual(tt.Hit.none, tt.hit(width, 1, s, 20, 20));
    try std.testing.expectEqual(@as(u64, 0), tt.hash(s));
}

test "a retitled tab changes the hash but not the layout hash" {
    const a = strip();
    const b: tt.Strip = .{ .tabs = &retitled };
    try std.testing.expect(tt.hash(a) != tt.hash(b));
    try std.testing.expectEqual(tt.layoutHash(a), tt.layoutHash(b));
}

test "keys keep tabs, close buttons and controls apart" {
    try std.testing.expect(tt.key(.{ .tab = 5 }) != tt.key(.{ .close = 5 }));
    try std.testing.expectEqual(@as(u64, 0), tt.key(.none));
    try std.testing.expect(tt.key(.plus) != tt.key(.previous));
    try std.testing.expect(tt.key(.previous) != tt.key(.next));
}

test "a press stays a click until the pointer travels past the threshold" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    const x = g.tab(0).x + g.width / 2;
    var d: tt.Drag = .{};
    try std.testing.expect(d.press(s, g, 1, x));
    try std.testing.expect(!d.motion(x + 2, 1));
    try std.testing.expect(!d.dragging());
    try std.testing.expectEqual(@as(?tt.Drag.Move, null), d.release(g));
    try std.testing.expect(!d.pressed());
}

test "press refuses a tab that is not visible" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    var d: tt.Drag = .{};
    try std.testing.expect(!d.press(s, g, 99, 10));
    try std.testing.expect(!d.pressed());
    try std.testing.expect(!d.motion(500, 1));
}

test "dragging one slot right moves the tab to the next index" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    const pitch = g.width + 4;
    const x = g.tab(0).x + g.width / 2;
    var d: tt.Drag = .{};
    try std.testing.expect(d.press(s, g, 1, x));
    try std.testing.expect(d.motion(x + pitch, 1));
    try std.testing.expect(d.dragging());
    const move = d.release(g) orelse return error.TestExpectedMove;
    try std.testing.expectEqual(@as(u64, 1), move.id);
    try std.testing.expectEqual(@as(usize, 1), move.index);
    try std.testing.expect(!d.pressed());
}

test "a drag past either end clamps to the first and last tab" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    const pitch = g.width + 4;
    const x = g.tab(1).x + g.width / 2;
    var d: tt.Drag = .{};
    try std.testing.expect(d.press(s, g, 2, x));
    try std.testing.expect(d.motion(x + 10 * pitch, 1));
    try std.testing.expectEqual(@as(usize, 2), (d.release(g) orelse return error.TestExpectedMove).index);
    try std.testing.expect(d.press(s, g, 2, x));
    try std.testing.expect(d.motion(x - 10 * pitch, 1));
    try std.testing.expectEqual(@as(usize, 0), (d.release(g) orelse return error.TestExpectedMove).index);
}

test "a drag that ends where it began is not a move" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    const x = g.tab(1).x + g.width / 2;
    var d: tt.Drag = .{};
    try std.testing.expect(d.press(s, g, 2, x));
    try std.testing.expect(d.motion(x + 10, 1));
    try std.testing.expect(d.dragging());
    try std.testing.expectEqual(@as(?tt.Drag.Move, null), d.release(g));
}

test "the preview steps passed tabs aside and follows the pointer" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    const pitch = g.width + 4;
    const x = g.tab(0).x + g.width / 2;
    var d: tt.Drag = .{};
    try std.testing.expect(d.press(s, g, 1, x));
    // Before the threshold nothing moves.
    try std.testing.expectEqual(g.tab(1).x, d.rect(g, 1).x);
    try std.testing.expect(d.motion(x + pitch, 1));
    try std.testing.expectApproxEqAbs(g.tab(1).x, d.rect(g, 0).x, 0.01);
    try std.testing.expectApproxEqAbs(g.tab(0).x, d.rect(g, 1).x, 0.01);
    try std.testing.expectApproxEqAbs(g.tab(2).x, d.rect(g, 2).x, 0.01);
    // Dragged the other way, the tabs before it step right.
    var back: tt.Drag = .{};
    const x2 = g.tab(2).x + g.width / 2;
    try std.testing.expect(back.press(s, g, 3, x2));
    try std.testing.expect(back.motion(x2 - pitch, 1));
    try std.testing.expectApproxEqAbs(g.tab(2).x, back.rect(g, 1).x, 0.01);
    try std.testing.expectApproxEqAbs(g.tab(0).x, back.rect(g, 0).x, 0.01);
}

test "the dragged tab never leaves the strip" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    var d: tt.Drag = .{};
    const x = g.tab(0).x + g.width / 2;
    try std.testing.expect(d.press(s, g, 1, x));
    try std.testing.expect(d.motion(-500, 1));
    try std.testing.expectApproxEqAbs(g.x, d.rect(g, 0).x, 0.01);
    try std.testing.expect(d.motion(5000, 1));
    try std.testing.expectApproxEqAbs(g.tab(2).x, d.rect(g, 0).x, 0.01);
}

test "a leading button takes the first slot and the tabs start after it" {
    const plain = tt.geometry(width, 1, strip());
    var s = strip();
    s.leading = true;
    const g = tt.geometry(width, 1, s);
    const lead = g.leading orelse return error.TestExpectedLeading;
    try std.testing.expect(plain.leading == null);
    try std.testing.expect(g.tab(0).x >= lead.x + lead.w);
    try std.testing.expectEqual(tt.Hit.leading, tt.hit(width, 1, s, lead.x + lead.w / 2, lead.y + lead.h / 2));
    // Without the button the same point is not a hit.
    try std.testing.expect(tt.hit(width, 1, strip(), lead.x + lead.w / 2, lead.y + lead.h / 2) != .leading);
    try std.testing.expect(tt.hash(s) != tt.hash(strip()));
}

test "keys stay distinct with the leading button" {
    try std.testing.expect(tt.key(.leading) != 0);
    for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |id| {
        try std.testing.expect(tt.key(.leading) != tt.key(.{ .tab = id }));
        try std.testing.expect(tt.key(.leading) != tt.key(.{ .close = id }));
    }
    try std.testing.expect(tt.key(.leading) != tt.key(.plus));
    try std.testing.expect(tt.key(.leading) != tt.key(.previous));
    try std.testing.expect(tt.key(.leading) != tt.key(.next));
}

test "a drag in progress changes the hash and a bare press does not" {
    const s = strip();
    const g = tt.geometry(width, 1, s);
    const x = g.tab(0).x + g.width / 2;
    var d: tt.Drag = .{};
    try std.testing.expect(d.press(s, g, 1, x));
    var pressed = s;
    pressed.drag = d;
    try std.testing.expectEqual(tt.hash(s), tt.hash(pressed));
    try std.testing.expect(d.motion(x + 20, 1));
    var moving = s;
    moving.drag = d;
    try std.testing.expect(tt.hash(s) != tt.hash(moving));
    try std.testing.expect(tt.layoutHash(s) != tt.layoutHash(moving));
    try std.testing.expect(d.motion(x + 30, 1));
    var later = s;
    later.drag = d;
    try std.testing.expect(tt.hash(moving) != tt.hash(later));
}
