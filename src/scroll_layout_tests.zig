const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const scroll = @import("scroll_layout.zig");
const Strip = scroll.Strip;
const Member = scroll.Member;
const Box = scroll.Box;
const Key = scroll.Key;

// 1000 wide with 10 px gaps: 980 between the outer gaps, so ½ is 485.
const screen: Box = .{ .x = 100, .y = 50, .width = 1000, .height = 600 };
const presets = [_]f64{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1 };

fn member(id: u64) Member {
    return .{ .key = .{ .id = id }, .order = id };
}

test "new columns open after their anchor and leave the others alone" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    var members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, members[0..2], screen, 10, .{});
    const first = strip.rectangle(members[0].key).?;
    const second = strip.rectangle(members[1].key).?;
    try testing.expectEqual(Box{ .x = 110, .y = 60, .width = 485, .height = 580 }, first);
    try testing.expectEqual(Box{ .x = 605, .y = 60, .width = 485, .height = 580 }, second);
    try testing.expectEqual(@as(f64, 0), strip.maxView());
    // A third column opens beside its anchor, past the edge: nothing shrinks.
    members[2].anchor = members[0].key;
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    try testing.expectEqual(first, strip.rectangle(members[0].key).?);
    try testing.expectEqual(second.width, strip.rectangle(members[2].key).?.width);
    try testing.expectEqual(second.x, strip.rectangle(members[2].key).?.x);
    try testing.expectEqual(second.x + 495, strip.rectangle(members[1].key).?.x);
    try testing.expectEqual(@as(f64, 495), strip.maxView());
    // Two arrivals with the same anchor keep their order behind it.
    var more = [_]Member{ members[0], members[1], members[2], member(4), member(5) };
    more[3].anchor = members[1].key;
    more[4].anchor = members[1].key;
    try strip.sync(testing.allocator, &more, screen, 10, .{});
    const order = [_]u64{ 1, 3, 2, 4, 5 };
    for (strip.columns.items, order) |column, id| try testing.expectEqual(id, column.cells.items[0].member.key.id);
    try strip.sync(testing.allocator, more[1..], screen, 10, .{});
    try testing.expect(!strip.contains(members[0].key));
    try testing.expectEqual(@as(usize, 4), strip.columns.items.len);
}

test "reveal scrolls the least, centres wide columns and stays in limits" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3), member(4) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    // Columns start at 0, 495, 990, 1485; the strip is 1970 long.
    try testing.expectEqual(@as(i32, 1970), strip.extent);
    strip.reveal(members[2].key, .on_overflow);
    try testing.expectEqual(@as(f64, 495), strip.view);
    try testing.expectEqual(@as(i32, 110), strip.rectangle(members[1].key).?.x);
    strip.reveal(members[3].key, .on_overflow);
    try testing.expectEqual(@as(f64, 990), strip.view);
    strip.reveal(members[1].key, .never);
    try testing.expectEqual(@as(f64, 495), strip.view);
    // Always centres, clamped at the ends of the strip.
    strip.reveal(members[1].key, .always);
    try testing.expectEqual(@as(f64, 495 + 242.5 - 490), strip.view);
    strip.reveal(members[0].key, .always);
    try testing.expectEqual(@as(f64, 0), strip.view);
    // A column wider than the view is centred on overflow, flush with never.
    strip.setWidth(members[2].key, 1);
    try strip.sync(testing.allocator, &members, .{ .x = 0, .y = 0, .width = 1000, .height = 600 }, 10, .{});
    strip.columns.items[2].size = 1200;
    strip.extent += 1200 - 980;
    strip.reveal(members[2].key, .on_overflow);
    try testing.expectEqual(@as(f64, 990 + 600 - 490), strip.view);
    // Once it fills the view it stays where a gesture left it.
    strip.view = 1050;
    try testing.expect(strip.columnCovers(2, 1050) and !strip.columnFits(2, 1050));
    strip.reveal(members[2].key, .on_overflow);
    try testing.expectEqual(@as(f64, 1050), strip.view);
    strip.view = 0;
    try testing.expect(!strip.columnCovers(2, 0));
    strip.reveal(members[2].key, .never);
    try testing.expectEqual(@as(f64, 990), strip.view);
    // A strip shorter than its viewport starts at the leading edge.
    try strip.sync(testing.allocator, members[0..1], screen, 10, .{});
    strip.clampView();
    try testing.expectEqual(@as(f64, 0), strip.view);
}

test "suspended members keep their place and take no room" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    var members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    const third = strip.rectangle(members[2].key).?;
    members[1].active = false;
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    try testing.expectEqual(@as(?Box, null), strip.rectangle(members[1].key));
    try testing.expectEqual(strip.rectangle(members[0].key).?.x + 495, strip.rectangle(members[2].key).?.x);
    try testing.expectEqual(members[2].key, strip.neighbor(members[0].key, .next_column).?);
    members[1].active = true;
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    try testing.expectEqual(third, strip.rectangle(members[2].key).?);
}

test "consume joins a neighbour column and expel leaves it" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    try testing.expect(!try strip.consume(testing.allocator, members[0].key, .before));
    try testing.expect(try strip.consume(testing.allocator, members[1].key, .before));
    strip.arrange(screen, 10, .horizontal);
    try testing.expectEqual(@as(usize, 2), strip.columns.items.len);
    const top = strip.rectangle(members[0].key).?;
    const bottom = strip.rectangle(members[1].key).?;
    try testing.expectEqual(top.x, bottom.x);
    try testing.expectEqual(Box{ .x = 110, .y = 60, .width = 485, .height = 285 }, top);
    try testing.expectEqual(top.y + top.height + 10, bottom.y);
    try testing.expectEqual(screen.y + screen.height - 10, bottom.y + bottom.height);
    try testing.expectEqual(members[1].key, strip.neighbor(members[0].key, .next_member).?);
    try testing.expectEqual(members[0].key, strip.neighbor(members[1].key, .previous_member).?);
    // From the lower member, the next column is reached and back again.
    try testing.expectEqual(members[2].key, strip.neighbor(members[1].key, .next_column).?);
    try testing.expectEqual(members[0].key, strip.neighbor(members[2].key, .previous_column).?);
    // Sharing a column, consume expels to that side.
    try testing.expect(try strip.consume(testing.allocator, members[0].key, .after));
    strip.arrange(screen, 10, .horizontal);
    try testing.expectEqual(@as(usize, 3), strip.columns.items.len);
    try testing.expectEqual(@as(u64, 2), strip.columns.items[0].cells.items[0].member.key.id);
    try testing.expectEqual(@as(u64, 1), strip.columns.items[1].cells.items[0].member.key.id);
    try testing.expect(strip.moveColumn(members[0].key, .after));
    try testing.expectEqual(@as(u64, 1), strip.columns.items[2].cells.items[0].member.key.id);
    try testing.expect(!strip.moveColumn(members[0].key, .after));
}

test "moving within a column and resizing members across it" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    _ = try strip.consume(testing.allocator, members[1].key, .before);
    strip.arrange(screen, 10, .horizontal);
    const height = strip.rectangle(members[0].key).?.height;
    strip.stepWeight(members[0].key, 32);
    strip.place();
    try testing.expectEqual(height + 32, strip.rectangle(members[0].key).?.height);
    try testing.expectEqual(height - 32, strip.rectangle(members[1].key).?.height);
    try testing.expect(strip.moveInColumn(members[0].key, .after));
    strip.place();
    try testing.expect(strip.rectangle(members[0].key).?.y > strip.rectangle(members[1].key).?.y);
    try testing.expect(!strip.moveInColumn(members[0].key, .after));
}

test "preset widths cycle upward, manual steps and client limits" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    var members = [_]Member{ member(1), member(2) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    const key = members[0].key;
    strip.cycleWidth(key, &presets);
    try testing.expectEqual(presets[2], strip.widthOf(key).?);
    strip.cycleWidth(key, &presets);
    try testing.expectEqual(@as(f64, 1), strip.widthOf(key).?);
    strip.cycleWidth(key, &presets);
    try testing.expectEqual(presets[0], strip.widthOf(key).?);
    strip.setWidth(key, 0.5);
    strip.arrange(screen, 10, .horizontal);
    strip.stepWidth(key, 32);
    strip.arrange(screen, 10, .horizontal);
    try testing.expectEqual(@as(i32, 485 + 32), strip.rectangle(key).?.width);
    // A manual width cycles to the next preset above it.
    strip.cycleWidth(key, &presets);
    try testing.expectEqual(presets[2], strip.widthOf(key).?);
    strip.setWidth(key, 0.5);
    // A column widens to its largest minimum; a smaller maximum is centred.
    members[0].min_width = 600;
    members[1].max_width = 300;
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    try testing.expectEqual(@as(i32, 600), strip.rectangle(key).?.width);
    const bounded = strip.rectangle(members[1].key).?;
    try testing.expectEqual(@as(i32, 300), bounded.width);
    try testing.expectEqual(strip.columns.items[1].start + 110 + @divTrunc(485 - 300, 2), bounded.x);
}

test "members that cannot fit across a column move the newest out" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    var members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    _ = try strip.consume(testing.allocator, members[1].key, .before);
    _ = try strip.consume(testing.allocator, members[2].key, .before);
    try testing.expectEqual(@as(usize, 1), strip.columns.items.len);
    members[1].min_height = 300;
    members[2].min_height = 280;
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    try testing.expectEqual(@as(usize, 2), strip.columns.items.len);
    try testing.expectEqual(@as(u64, 3), strip.columns.items[1].cells.items[0].member.key.id);
    strip.setWeight(members[0].key, 20);
    strip.place();
    const last = strip.rectangle(members[1].key).?;
    try testing.expectEqual(@as(i32, 300), last.height);
    try testing.expectEqual(screen.y + screen.height - 10, last.y + last.height);
}

test "a vertical strip stacks full-width rows" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3) };
    const portrait: Box = .{ .x = 0, .y = 0, .width = 600, .height = 1000 };
    try strip.sync(testing.allocator, &members, portrait, 10, .{ .direction = .vertical });
    try testing.expectEqual(Box{ .x = 10, .y = 10, .width = 580, .height = 485 }, strip.rectangle(members[0].key).?);
    try testing.expectEqual(@as(i32, 505), strip.rectangle(members[1].key).?.y);
    strip.reveal(members[2].key, .on_overflow);
    try testing.expectEqual(@as(i32, 505), strip.rectangle(members[2].key).?.y);
    // Transposed, the widths are the same fractions of the other axis.
    strip.view = 0;
    strip.arrange(screen, 10, .horizontal);
    try testing.expectEqual(Box{ .x = 110, .y = 60, .width = 485, .height = 580 }, strip.rectangle(members[0].key).?);
    try testing.expect(strip.columnShown(members[1].key));
    try testing.expect(!strip.columnShown(members[2].key));
}

test "a transposed strip keeps the same stretch in view" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3), member(4) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    strip.reveal(members[3].key, .on_overflow);
    try testing.expectEqual(@as(f64, 990), strip.view);
    // Portrait: 1480 between the outer gaps, so ½ is 735 and the view scales
    // from a 990 px span to 1490.
    const portrait: Box = .{ .x = 0, .y = 0, .width = 600, .height = 1500 };
    strip.arrange(portrait, 10, .vertical);
    try testing.expectEqual(@as(f64, 1490), strip.view);
    const last = strip.rectangle(members[3].key).?;
    try testing.expectEqual(Box{ .x = 10, .y = 755, .width = 580, .height = 735 }, last);
    try testing.expect(strip.columnShown(members[2].key));
    try testing.expect(!strip.columnShown(members[1].key));
    // And back: the view returns to where it was.
    strip.arrange(screen, 10, .horizontal);
    try testing.expectEqual(@as(f64, 990), strip.view);
}

test "a released gesture snaps to column edges or centres" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3), member(4) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    // Columns start at 0, 495, 990 and 1485; the view goes up to 990.
    try testing.expectEqual(scroll.Snap{ .view = 495, .column = 1 }, strip.snapView(300, .on_overflow).?);
    try testing.expectEqual(scroll.Snap{ .view = 990, .column = 2 }, strip.snapView(800, .on_overflow).?);
    try testing.expectEqual(scroll.Snap{ .view = 0, .column = 0 }, strip.snapView(-200, .never).?);
    try testing.expectEqual(scroll.Snap{ .view = 247.5, .column = 1 }, strip.snapView(300, .always).?);
    try testing.expect(strip.columnFits(1, 495) and strip.columnFits(2, 495) and !strip.columnFits(3, 495));
    var empty: Strip = .{};
    try testing.expectEqual(@as(?scroll.Snap, null), empty.snapView(0, .on_overflow));
}

test "drops land between columns or beside a member" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    const one = members[0].key;
    const two = members[1].key;
    // Columns are drawn at x 110..595 and 605..1090; edge zones are 97 px.
    try testing.expectEqual(scroll.Drop{ .column = .{ .anchor = one, .side = .before } }, strip.dropAt(120, 300, null).?);
    try testing.expectEqual(scroll.Drop{ .join = .{ .anchor = one, .side = .before } }, strip.dropAt(350, 100, null).?);
    try testing.expectEqual(scroll.Drop{ .join = .{ .anchor = one, .side = .after } }, strip.dropAt(350, 500, null).?);
    try testing.expectEqual(scroll.Drop{ .column = .{ .anchor = one, .side = .after } }, strip.dropAt(590, 300, null).?);
    try testing.expectEqual(scroll.Drop{ .column = .{ .anchor = two, .side = .before } }, strip.dropAt(600, 300, null).?);
    try testing.expectEqual(scroll.Drop{ .column = .{ .anchor = members[2].key, .side = .after } }, strip.dropAt(4000, 300, null).?);
    // The moving member's own column is as good as gone; over itself is no drop.
    try testing.expectEqual(scroll.Drop{ .column = .{ .anchor = two, .side = .before } }, strip.dropAt(350, 300, one).?);
    _ = try strip.consume(testing.allocator, two, .before);
    strip.place();
    try testing.expectEqual(@as(?scroll.Drop, null), strip.dropAt(350, 500, two));
    try testing.expectEqual(scroll.Drop{ .join = .{ .anchor = one, .side = .before } }, strip.dropAt(350, 100, two).?);
    var empty: Strip = .{};
    try testing.expectEqual(scroll.Drop{ .column = .{} }, empty.dropAt(0, 0, null).?);
}

test "dropping inserts a column or joins one, and sizes are set absolutely" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    strip.remove(testing.allocator, members[2].key);
    try testing.expect(try strip.insertDrop(testing.allocator, members[2], .{ .join = .{ .anchor = members[0].key, .side = .after } }, 0.5));
    try strip.rearrange(testing.allocator);
    const top = strip.rectangle(members[0].key).?;
    const below = strip.rectangle(members[2].key).?;
    try testing.expect(top.x == below.x and top.y < below.y);
    try testing.expectEqual(@as(usize, 2), strip.columnCount(members[0].key));
    strip.setCrossSize(members[0].key, 200);
    strip.place();
    try testing.expectEqual(@as(i32, 200), strip.rectangle(members[0].key).?.height);
    strip.remove(testing.allocator, members[2].key);
    try testing.expect(try strip.insertDrop(testing.allocator, members[2], .{ .column = .{ .anchor = members[1].key, .side = .before } }, 0.25));
    try testing.expect(!try strip.insertDrop(testing.allocator, members[2], .{ .column = .{} }, 0.5));
    strip.setWidthPixels(members[1].key, 300);
    try strip.rearrange(testing.allocator);
    try testing.expectEqual(@as(u64, 3), strip.columns.items[1].cells.items[0].member.key.id);
    try testing.expectEqual(@as(?i32, 300), strip.columnSize(members[1].key));
    try testing.expectEqual(@as(?i32, 238), strip.columnSize(members[2].key));
}

test "the strip overview fits the whole strip and keeps its order" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3), member(4) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    strip.reveal(members[3].key, .on_overflow);
    // 1970 px of strip in 980: half size, from the viewport's leading edge.
    try testing.expectApproxEqAbs(@as(f64, 980.0 / 1970.0), strip.overviewScale(), 1e-9);
    const first = strip.rectangle(members[0].key).?;
    const last = strip.rectangle(members[3].key).?;
    const a = strip.overviewPoint(@floatFromInt(first.x), @floatFromInt(first.y));
    const d = strip.overviewPoint(@floatFromInt(last.x + last.width), @floatFromInt(last.y));
    try testing.expectApproxEqAbs(@as(f64, 110), a[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1090), d[0], 1e-6);
    // Centred across: 580 px tall columns shrink about the middle.
    try testing.expectApproxEqAbs(@as(f64, 60 + 580 * (1 - strip.overviewScale()) / 2), a[1], 1e-6);
    // A short strip still zooms out a little, centred.
    var short: Strip = .{};
    defer short.deinit(testing.allocator);
    try short.sync(testing.allocator, members[0..1], screen, 10, .{});
    try testing.expectEqual(@as(f64, 0.9), short.overviewScale());
}

test "snapshots compare placement, not the view" {
    var strip: Strip = .{};
    defer strip.deinit(testing.allocator);
    const members = [_]Member{ member(1), member(2), member(3) };
    try strip.sync(testing.allocator, &members, screen, 10, .{});
    var saved = try strip.clone(testing.allocator);
    defer saved.deinit(testing.allocator);
    try testing.expect(strip.eql(&saved));
    strip.reveal(members[2].key, .on_overflow);
    try testing.expect(strip.eql(&saved));
    strip.cycleWidth(members[0].key, &presets);
    try testing.expect(!strip.eql(&saved));
    saved.rename(members[1].key, .{ .id = 9, .group = true });
    try testing.expect(saved.contains(.{ .id = 9, .group = true }));
}

test "allocation failures leave the strip intact" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var strip: Strip = .{};
            defer strip.deinit(allocator);
            const members = [_]Member{ member(1), member(2), member(3) };
            try strip.sync(allocator, members[0..2], screen, 10, .{});
            strip.sync(allocator, &members, screen, 10, .{}) catch |err| {
                try testing.expect(strip.contains(members[0].key) and strip.contains(members[1].key));
                return err;
            };
            _ = strip.consume(allocator, members[2].key, .before) catch |err| {
                try testing.expect(strip.contains(members[2].key));
                return err;
            };
            var copy = try strip.clone(allocator);
            defer copy.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
