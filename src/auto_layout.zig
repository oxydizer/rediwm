//! Recursive split geometry, independent of compositor objects and focus order.
//! Members arrive in stable insertion order. Suspended leaves retain their split;
//! overflow is admitted oldest-first and retried only when the caller changes state.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Box = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Key = struct { id: u64, group: bool = false };
pub const Member = struct {
    key: Key,
    order: u64 = 0,
    active: bool = true,
    min_width: i32 = 1,
    min_height: i32 = 1,
    max_width: i32 = 0,
    max_height: i32 = 0,
    /// Where a new member goes: this placed leaf is split. Without one, or when
    /// it has no tile, the member splits the leaf admitted before it.
    anchor: ?Key = null,
};
pub const Axis = enum { horizontal, vertical };
pub const Direction = enum { left, right, up, down };
pub const Placement = struct { anchor: Key, axis: Axis, ratio: f64 = 0.5, before: bool = false };
pub const Split = struct { axis: Axis, ratio: f64, span: i32 };
const Size = struct { width: i32 = 0, height: i32 = 0 };
pub const Node = struct {
    member: ?Member = null,
    children: ?struct { a: *Node, b: *Node } = null,
    axis: Axis = .horizontal,
    ratio: f64 = 0.5,
    enabled: bool = false,
    rect: ?Box = null,
    outer_edges: std.EnumSet(Direction) = .empty,
    split: ?Split = null,

    fn destroy(node: *Node, allocator: Allocator) void {
        if (node.children) |c| {
            c.a.destroy(allocator);
            c.b.destroy(allocator);
        }
        allocator.destroy(node);
    }
    fn find(node: *Node, key: Key) ?*Node {
        if (node.member) |m| return if (std.meta.eql(m.key, key)) node else null;
        const c = node.children.?;
        return c.a.find(key) orelse c.b.find(key);
    }
    fn parent(node: *Node, key: Key) ?*Node {
        const c = node.children orelse return null;
        for ([_]*Node{ c.a, c.b }) |child| {
            if (child.member) |m| if (std.meta.eql(m.key, key)) return node;
        }
        return c.a.parent(key) orelse c.b.parent(key);
    }
    fn clone(node: *const Node, allocator: Allocator) Allocator.Error!*Node {
        const copy = try allocator.create(Node);
        errdefer allocator.destroy(copy);
        copy.* = node.*;
        if (node.children) |c| {
            const a = try c.a.clone(allocator);
            errdefer a.destroy(allocator);
            copy.children = .{ .a = a, .b = try c.b.clone(allocator) };
        }
        return copy;
    }
    fn firstKey(node: *Node) Key {
        if (node.member) |m| return m.key;
        const c = node.children.?;
        return if (c.a.minimum(0).width > 0 or c.b.minimum(0).width == 0) c.a.firstKey() else c.b.firstKey();
    }
    fn splitFor(node: *Node, key: Key, axis: ?Axis) ?*Node {
        const c = node.children orelse return null;
        const child = if (c.a.find(key) != null) c.a else if (c.b.find(key) != null) c.b else return null;
        if (child.splitFor(key, axis)) |found| return found;
        if (node.split != null and (axis == null or node.axis == axis.?)) return node;
        return null;
    }
    fn collect(node: *Node, allocator: Allocator, members: *std.ArrayList(Member)) Allocator.Error!void {
        if (node.member) |m| return members.append(allocator, m);
        const c = node.children.?;
        try c.a.collect(allocator, members);
        try c.b.collect(allocator, members);
    }
    fn minimum(node: *const Node, gap: i32) Size {
        if (node.member) |m| return if (node.enabled) .{ .width = @max(1, m.min_width), .height = @max(1, m.min_height) } else .{};
        const c = node.children.?;
        const a = c.a.minimum(gap);
        const b = c.b.minimum(gap);
        if (a.width == 0) return b;
        if (b.width == 0) return a;
        return switch (node.axis) {
            .horizontal => .{ .width = a.width +| b.width +| gap, .height = @max(a.height, b.height) },
            .vertical => .{ .width = @max(a.width, b.width), .height = a.height +| b.height +| gap },
        };
    }
    fn place(node: *Node, box: Box, gap: i32, outer_edges: std.EnumSet(Direction)) void {
        node.rect = null;
        node.split = null;
        if (node.member) |m| {
            if (!node.enabled) return;
            var rect = box;
            if (m.max_width > 0) rect.width = @min(rect.width, @max(m.min_width, m.max_width));
            if (m.max_height > 0) rect.height = @min(rect.height, @max(m.min_height, m.max_height));
            node.rect = rect;
            node.outer_edges = outer_edges;
            return;
        }
        const c = node.children.?;
        const a = c.a.minimum(gap);
        const b = c.b.minimum(gap);
        if (a.width == 0 or b.width == 0) {
            c.a.place(box, gap, outer_edges);
            c.b.place(box, gap, outer_edges);
            return;
        }
        var first = box;
        var second = box;
        switch (node.axis) {
            .horizontal => {
                const available = box.width - gap;
                first.width = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(available)) * node.ratio))), a.width, available - b.width);
                second.x += first.width + gap;
                second.width = available - first.width;
            },
            .vertical => {
                const available = box.height - gap;
                first.height = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(available)) * node.ratio))), a.height, available - b.height);
                second.y += first.height + gap;
                second.height = available - first.height;
            },
        }
        const span = if (node.axis == .horizontal) box.width - gap else box.height - gap;
        node.split = .{ .axis = node.axis, .span = span, .ratio = @as(f64, @floatFromInt(if (node.axis == .horizontal) first.width else first.height)) / @as(f64, @floatFromInt(span)) };
        var first_edges = outer_edges;
        var second_edges = outer_edges;
        first_edges.remove(if (node.axis == .horizontal) .right else .down);
        second_edges.remove(if (node.axis == .horizontal) .left else .up);
        c.a.place(first, gap, first_edges);
        c.b.place(second, gap, second_edges);
    }
};

pub const Tree = struct {
    root: ?*Node = null,

    pub fn deinit(tree: *Tree, allocator: Allocator) void {
        if (tree.root) |node| node.destroy(allocator);
        tree.* = .{};
    }
    pub fn contains(tree: *const Tree, key: Key) bool {
        return if (tree.root) |node| node.find(key) != null else false;
    }
    /// Edges facing the outside of the layout. A live divider remains resizable.
    pub fn outerEdges(tree: *const Tree, key: Key) std.EnumSet(Direction) {
        const node = (tree.root orelse return .empty).find(key) orelse return .empty;
        return if (node.rect != null) node.outer_edges else .empty;
    }
    pub fn rectangle(tree: *const Tree, key: Key) ?Box {
        const node = (tree.root orelse return null).find(key) orelse return null;
        return node.rect;
    }
    pub fn insert(tree: *Tree, allocator: Allocator, member: Member, beside: ?Key, axis: Axis) !void {
        if (tree.contains(member.key)) return;
        const leaf = try allocator.create(Node);
        errdefer allocator.destroy(leaf);
        leaf.* = .{ .member = member };
        const root = tree.root orelse {
            tree.root = leaf;
            return;
        };
        var anchor = if (beside) |key| root.find(key) orelse root else root;
        while (anchor.children) |c| anchor = c.b;
        const previous = try allocator.create(Node);
        previous.* = anchor.*;
        anchor.* = .{ .children = .{ .a = previous, .b = leaf }, .axis = axis };
    }
    pub fn clone(tree: *const Tree, allocator: Allocator) !Tree {
        return .{ .root = if (tree.root) |root| try root.clone(allocator) else null };
    }
    /// Compare placement, ignoring cached geometry and live client constraints.
    pub fn eql(tree: *const Tree, other: *const Tree) bool {
        return eqlNode(tree.root, other.root);
    }
    fn eqlNode(a: ?*const Node, b: ?*const Node) bool {
        const first = a orelse return b == null;
        const second = b orelse return false;
        if (first.member) |member| {
            return if (second.member) |other| std.meta.eql(member.key, other.key) else false;
        }
        if (second.member != null or first.axis != second.axis or first.ratio != second.ratio) return false;
        const ac = first.children.?;
        const bc = second.children.?;
        return eqlNode(ac.a, bc.a) and eqlNode(ac.b, bc.b);
    }
    pub fn getMember(tree: *const Tree, key: Key) ?Member {
        return ((tree.root orelse return null).find(key) orelse return null).member;
    }
    pub fn rename(tree: *Tree, old: Key, new: Key) void {
        if (tree.contains(new)) return;
        const node = (tree.root orelse return).find(old) orelse return;
        node.member.?.key = new;
    }
    pub fn placement(tree: *const Tree, key: Key) ?Placement {
        const parent = (tree.root orelse return null).parent(key) orelse return null;
        const c = parent.children.?;
        const before = c.a.find(key) != null;
        return .{ .anchor = (if (before) c.b else c.a).firstKey(), .axis = parent.axis, .ratio = parent.ratio, .before = before };
    }
    pub fn insertAt(tree: *Tree, allocator: Allocator, value: Member, at: Placement) !void {
        if (tree.contains(value.key)) return;
        try tree.insert(allocator, value, at.anchor, at.axis);
        const node = (tree.root orelse return).parent(value.key) orelse return;
        node.ratio = std.math.clamp(at.ratio, 0.05, 0.95);
        if (at.before) std.mem.swap(*Node, &node.children.?.a, &node.children.?.b);
    }
    pub fn splitFor(tree: *const Tree, key: Key, axis: ?Axis) ?Split {
        return ((tree.root orelse return null).splitFor(key, axis) orelse return null).split;
    }
    pub fn setRatio(tree: *Tree, key: Key, axis: Axis, ratio: f64) void {
        if (!std.math.isFinite(ratio)) return;
        const node = (tree.root orelse return).splitFor(key, axis) orelse return;
        node.ratio = std.math.clamp(ratio, 0.05, 0.95);
    }
    /// Used by drag previews on a private copy; admission order stays independent
    /// of split traversal and survives swaps and subtree moves.
    pub fn arrangeExisting(tree: *Tree, allocator: Allocator, usable: Box, gap: u32) !void {
        const root = tree.root orelse return;
        var members: std.ArrayList(Member) = .empty;
        defer members.deinit(allocator);
        try root.collect(allocator, &members);
        std.mem.sort(Member, members.items, {}, struct {
            fn less(_: void, a: Member, b: Member) bool {
                return if (a.order != b.order) a.order < b.order else a.key.id < b.key.id;
            }
        }.less);
        tree.arrange(members.items, usable, gap);
    }
    pub fn neighbor(tree: *const Tree, key: Key, direction: Direction) ?Key {
        const source = tree.rectangle(key) orelse return null;
        var result: ?Key = null;
        var score: f64 = std.math.inf(f64);
        neighborNode(tree.root orelse return null, key, source, direction, &result, &score);
        return result;
    }
    fn neighborNode(node: *Node, key: Key, source: Box, direction: Direction, result: *?Key, best: *f64) void {
        if (node.children) |c| {
            neighborNode(c.a, key, source, direction, result, best);
            neighborNode(c.b, key, source, direction, result, best);
            return;
        }
        const m = node.member.?;
        if (std.meta.eql(m.key, key)) return;
        const box = node.rect orelse return;
        const dx = @as(f64, @floatFromInt(box.x - source.x)) + @as(f64, @floatFromInt(box.width - source.width)) / 2;
        const dy = @as(f64, @floatFromInt(box.y - source.y)) + @as(f64, @floatFromInt(box.height - source.height)) / 2;
        const along = switch (direction) {
            .left => -dx,
            .right => dx,
            .up => -dy,
            .down => dy,
        };
        if (along <= 0) return;
        const across = if (direction == .left or direction == .right) dy else dx;
        const score = along * along + 4 * across * across;
        if (score < best.*) {
            best.* = score;
            result.* = m.key;
        }
    }
    pub fn remove(tree: *Tree, allocator: Allocator, key: Key) void {
        tree.root = removeNode(tree.root, allocator, key);
    }
    fn removeNode(maybe_node: ?*Node, allocator: Allocator, key: Key) ?*Node {
        const node = maybe_node orelse return null;
        if (node.member) |m| {
            if (!std.meta.eql(m.key, key)) return node;
            allocator.destroy(node);
            return null;
        }
        const c = node.children.?;
        const a = removeNode(c.a, allocator, key);
        const b = removeNode(c.b, allocator, key);
        if (a != null and b != null) {
            node.children = .{ .a = a.?, .b = b.? };
            return node;
        }
        allocator.destroy(node);
        return a orelse b;
    }
    pub fn swap(tree: *Tree, a: Key, b: Key) void {
        const root = tree.root orelse return;
        const one = root.find(a) orelse return;
        const two = root.find(b) orelse return;
        std.mem.swap(?Member, &one.member, &two.member);
    }
    pub fn rotate(tree: *Tree, key: Key) void {
        const node = (tree.root orelse return).splitFor(key, null) orelse return;
        node.axis = if (node.axis == .horizontal) .vertical else .horizontal;
    }
    pub fn resize(tree: *Tree, key: Key, delta: f64) void {
        if (!std.math.isFinite(delta)) return;
        const node = (tree.root orelse return).parent(key) orelse return;
        node.ratio = std.math.clamp(node.ratio + delta, 0.05, 0.95);
    }
    fn missing(node: *Node, members: []const Member) ?Key {
        if (node.member) |m| {
            for (members) |candidate| if (std.meta.eql(m.key, candidate.key)) return null;
            return m.key;
        }
        const c = node.children.?;
        return missing(c.a, members) orelse missing(c.b, members);
    }
    /// Membership synchronization is transactional per insertion on allocation failure.
    pub fn sync(tree: *Tree, allocator: Allocator, members: []const Member, usable: Box, requested_gap: u32) !void {
        while (tree.root) |root| {
            const key = missing(root, members) orelse break;
            tree.remove(allocator, key);
        }
        if (tree.root) |root| {
            for (members) |member| {
                if (root.find(member.key)) |node| node.member = member;
            }
        }
        tree.arrange(members, usable, requested_gap);
        var beside: ?Key = null;
        for (members) |member| {
            if (!tree.contains(member.key)) {
                const at = if (member.anchor) |anchor| (if (tree.rectangle(anchor) != null) anchor else beside) else beside;
                var rect = usable;
                if (at) |key| rect = tree.rectangle(key) orelse usable;
                try tree.insert(allocator, member, at, if (rect.width >= rect.height) .horizontal else .vertical);
                tree.arrange(members, usable, requested_gap);
            }
            if (tree.rectangle(member.key) != null) beside = member.key;
        }
    }
    pub fn arrange(tree: *Tree, members: []const Member, usable: Box, requested_gap: u32) void {
        const root = tree.root orelse return;
        const gap: i32 = @intCast(@min(requested_gap, @as(u32, @intCast(@max(0, @divTrunc(@min(usable.width, usable.height) - 1, 2))))));
        const box: Box = .{ .x = usable.x + gap, .y = usable.y + gap, .width = @max(0, usable.width - 2 * gap), .height = @max(0, usable.height - 2 * gap) };
        disable(root);
        for (members) |member| {
            const node = root.find(member.key) orelse continue;
            node.enabled = member.active;
            const size = root.minimum(gap);
            if (size.width > box.width or size.height > box.height) node.enabled = false;
        }
        root.place(box, gap, .full);
    }
    fn disable(node: *Node) void {
        node.enabled = false;
        if (node.children) |c| {
            disable(c.a);
            disable(c.b);
        }
    }
};

const testing = std.testing;
const screen: Box = .{ .x = -1280, .y = -120, .width = 1281, .height = 673 };
test "stable splits, gaps, suspension, overflow and recovery" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    var members = [_]Member{ .{ .key = .{ .id = 1 }, .min_width = 200 }, .{ .key = .{ .id = 2 }, .min_width = 200 }, .{ .key = .{ .id = 3 }, .min_width = 200 } };
    try tree.sync(testing.allocator, &members, screen, 8);
    const first = tree.rectangle(members[0].key).?;
    const second = tree.rectangle(members[1].key).?;
    const third = tree.rectangle(members[2].key).?;
    try testing.expectEqual(first.x + first.width + 8, second.x);
    try testing.expectEqual(second.y + second.height + 8, third.y);
    try testing.expectEqual(screen.x + screen.width - 8, third.x + third.width);
    try testing.expectEqual(std.EnumSet(Direction).initMany(&.{ .left, .up, .down }), tree.outerEdges(members[0].key));
    try testing.expectEqual(std.EnumSet(Direction).initMany(&.{ .right, .down }), tree.outerEdges(members[2].key));
    try tree.sync(testing.allocator, &members, screen, 8);
    try testing.expectEqual(first, tree.rectangle(members[0].key).?);
    members[1].active = false;
    try tree.sync(testing.allocator, &members, screen, 8);
    try testing.expectEqual(first, tree.rectangle(members[0].key).?);
    try testing.expectEqual(@as(?Box, null), tree.rectangle(members[1].key));
    try testing.expectEqual(std.EnumSet(Direction).initMany(&.{ .right, .up, .down }), tree.outerEdges(members[2].key));
    members[1].active = true;
    members[2].min_width = 1200;
    try tree.sync(testing.allocator, &members, screen, 8);
    try testing.expectEqual(@as(?Box, null), tree.rectangle(members[2].key));
    members[2].min_width = 200;
    try tree.sync(testing.allocator, &members, screen, 8);
    try testing.expectEqual(third, tree.rectangle(members[2].key).?);
    try tree.sync(testing.allocator, members[0..1], screen, 8);
    try testing.expectEqual(screen.width - 16, tree.rectangle(members[0].key).?.width);
    try testing.expectEqual(std.EnumSet(Direction).full, tree.outerEdges(members[0].key));
}

test "rotation, resizing, swapping and bounded clients" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    const members = [_]Member{ .{ .key = .{ .id = 1 } }, .{ .key = .{ .id = 2 }, .max_width = 300 } };
    try tree.sync(testing.allocator, &members, screen, 8);
    try testing.expectEqual(@as(i32, 300), tree.rectangle(members[1].key).?.width);
    tree.swap(members[0].key, members[1].key);
    tree.arrange(&members, screen, 8);
    try testing.expect(tree.rectangle(members[1].key).?.x < tree.rectangle(members[0].key).?.x);
    tree.rotate(members[0].key);
    tree.resize(members[0].key, 0.2);
    tree.arrange(&members, screen, 8);
    try testing.expect(tree.rectangle(members[1].key).?.height > tree.rectangle(members[0].key).?.height);
    tree.remove(testing.allocator, members[0].key);
    tree.arrange(members[1..], screen, 8);
    try testing.expect(!tree.contains(members[0].key));
}

test "a new member splits its anchor, else the member before it" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    var members = [_]Member{ .{ .key = .{ .id = 1 }, .order = 1 }, .{ .key = .{ .id = 2 }, .order = 2 }, .{ .key = .{ .id = 3 }, .order = 3, .anchor = .{ .id = 1 } } };
    try tree.sync(testing.allocator, members[0..2], screen, 8);
    const second = tree.rectangle(members[1].key).?;
    try tree.sync(testing.allocator, &members, screen, 8);
    // The tall left tile splits top/bottom; the right one keeps its tile.
    const first = tree.rectangle(members[0].key).?;
    const third = tree.rectangle(members[2].key).?;
    try testing.expectEqual(second, tree.rectangle(members[1].key).?);
    try testing.expectEqual(first.x, third.x);
    try testing.expectEqual(first.y + first.height + 8, third.y);
    // An anchor without a tile falls back to the member admitted before.
    members[0].active = false;
    var fourth = [_]Member{ members[0], members[1], members[2], .{ .key = .{ .id = 4 }, .order = 4, .anchor = .{ .id = 1 } } };
    try tree.sync(testing.allocator, &fourth, screen, 8);
    try testing.expectEqual(tree.placement(fourth[3].key).?.anchor, members[2].key);
}

test "insertion allocation failures preserve the original leaf" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var tree: Tree = .{};
            defer tree.deinit(allocator);
            const one: Member = .{ .key = .{ .id = 1 } };
            try tree.insert(allocator, one, null, .horizontal);
            tree.insert(allocator, .{ .key = .{ .id = 2 } }, one.key, .vertical) catch |err| {
                try testing.expect(tree.contains(one.key));
                return err;
            };
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "directional controls, reinsertion and cancellation preserve surviving members" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    const members = [_]Member{ .{ .key = .{ .id = 1 }, .order = 1 }, .{ .key = .{ .id = 2 }, .order = 2 }, .{ .key = .{ .id = 3 }, .order = 3 } };
    try tree.sync(testing.allocator, &members, screen, 8);
    const before = tree.rectangle(members[2].key).?;
    const at = tree.placement(members[2].key).?;
    tree.remove(testing.allocator, members[2].key);
    try tree.insertAt(testing.allocator, members[2], at);
    tree.arrange(&members, screen, 8);
    try testing.expectEqual(before, tree.rectangle(members[2].key).?);
    try testing.expectEqual(members[1].key, tree.neighbor(members[2].key, .up).?);
    var saved = try tree.clone(testing.allocator);
    defer saved.deinit(testing.allocator);
    try testing.expect(tree.eql(&saved));
    // Re-raster geometry alone is not a user layout change.
    try saved.arrangeExisting(testing.allocator, .{ .x = -100, .y = 20, .width = 1100, .height = 720 }, 12);
    try testing.expect(tree.eql(&saved));
    const split = tree.splitFor(members[2].key, .horizontal).?;
    tree.setRatio(members[2].key, split.axis, 0.8);
    try testing.expect(!tree.eql(&saved));
    tree.arrange(&members, screen, 8);
    try testing.expect(tree.rectangle(members[2].key).?.width < before.width);
    // A snapshot contains keys, not client pointers. Closing a neighbor while
    // resizing and then cancelling prunes the closed leaf safely.
    try saved.sync(testing.allocator, members[1..], screen, 8);
    try testing.expect(!saved.contains(members[0].key));
    try testing.expectEqual(before.height, saved.rectangle(members[2].key).?.height);
    saved.rename(members[2].key, .{ .id = 42, .group = true });
    try testing.expect(saved.contains(.{ .id = 42, .group = true }));
}

test "snapshot allocation failures leave a live layout intact" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var tree: Tree = .{};
            defer tree.deinit(allocator);
            try tree.insert(allocator, .{ .key = .{ .id = 1 } }, null, .horizontal);
            try tree.insert(allocator, .{ .key = .{ .id = 2 } }, null, .vertical);
            var copy = tree.clone(allocator) catch |err| {
                try testing.expect(tree.contains(.{ .id = 1 }) and tree.contains(.{ .id = 2 }));
                return err;
            };
            defer copy.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
