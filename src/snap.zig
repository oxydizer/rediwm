// Drag-to-edge snapping and half/quarter-screen tiles: which zone the pointer
// is in, the frame rectangle each tile occupies, keyboard layout steps, and
// the translucent preview shown while a window is dragged.
//
// All rectangles are layout-space frames (titlebar and borders included);
// Toplevel.setTiledOn converts them to world-space client geometry.
const std = @import("std");
const wlr = @import("wlroots");
const col = @import("color.zig");
const theme = @import("ui").theme;

pub const Tile = enum { left, right, top_left, top_right, bottom_left, bottom_right };

/// What releasing a dragged window at the pointer does.
pub const Target = union(enum) {
    maximize,
    tile: Tile,
};

/// Compositor-owned window placement, as undo records it.
pub const Layout = union(enum) {
    floating,
    maximized,
    tiled: Tile,

    pub fn eql(a: Layout, b: Layout) bool {
        return std.meta.eql(a, b);
    }
};

/// Output edges the pointer can't cross into another output.
pub const OpenEdges = struct {
    left: bool = true,
    right: bool = true,
    top: bool = true,
    bottom: bool = true,
};

/// The pointer snaps within this many layout px of an open output edge.
pub const edge_px = 2;
/// A maximized or tiled window stays put until a drag travels this far.
pub const unsnap_px = 12;
/// Two titlebar presses this close in time and space are a double-click.
pub const double_click_ms = 400;
pub const double_click_px = 6;

/// Length along an edge, from each output corner, that selects a quarter.
pub fn cornerLength(output: wlr.Box) i32 {
    return std.math.clamp(@divTrunc(@min(output.width, output.height), 6), 16, 96);
}

/// The snap zone under layout point (x, y) on `output`, or null away from
/// the open edges. Left/right edges tile halves, the top edge maximizes, and
/// the ends of each edge select quarters (the bottom edge only has those:
/// the taskbar sits along it).
pub fn targetAt(x: f64, y: f64, output: wlr.Box, usable: wlr.Box, open: OpenEdges) ?Target {
    if (output.width <= 0 or output.height <= 0) return null;
    const ox: f64 = @floatFromInt(output.x);
    const oy: f64 = @floatFromInt(output.y);
    const ow: f64 = @floatFromInt(output.width);
    const oh: f64 = @floatFromInt(output.height);
    const edge: f64 = edge_px;
    const corner: f64 = @floatFromInt(cornerLength(output));
    const usable_top: f64 = @floatFromInt(usable.y);
    const usable_bottom: f64 = @floatFromInt(usable.y + usable.height);

    const at_left = open.left and x < ox + edge;
    const at_right = open.right and x >= ox + ow - edge;
    if (at_left or at_right) {
        if (y < usable_top + corner) return .{ .tile = if (at_left) .top_left else .top_right };
        if (y >= usable_bottom - corner) return .{ .tile = if (at_left) .bottom_left else .bottom_right };
        return .{ .tile = if (at_left) .left else .right };
    }
    const near_left = x < ox + corner;
    const near_right = x >= ox + ow - corner;
    if (open.top and y < oy + edge) {
        if (near_left) return .{ .tile = .top_left };
        if (near_right) return .{ .tile = .top_right };
        return .maximize;
    }
    if (open.bottom and y >= oy + oh - edge) {
        if (near_left) return .{ .tile = .bottom_left };
        if (near_right) return .{ .tile = .bottom_right };
    }
    return null;
}

/// The frame rectangle of `tile` inside `usable`, with `gap` px around and
/// between tiles. Adjacent tiles share the split exactly, whatever the parity.
pub fn tileRect(usable: wlr.Box, tile: Tile, gap: u32) wlr.Box {
    const limit = @divTrunc(@max(0, @min(usable.width, usable.height) - 2), 3);
    const g: i32 = @min(@as(i32, @intCast(@min(gap, std.math.maxInt(i32)))), limit);
    const inner_w = usable.width - 3 * g;
    const inner_h = usable.height - 3 * g;
    const left_w = @divTrunc(inner_w, 2);
    const top_h = @divTrunc(inner_h, 2);

    const left_x = usable.x + g;
    const right_x = left_x + left_w + g;
    const top_y = usable.y + g;
    const bottom_y = top_y + top_h + g;
    const full_h = usable.height - 2 * g;
    const right_w = inner_w - left_w;
    const bottom_h = inner_h - top_h;

    return switch (tile) {
        .left => .{ .x = left_x, .y = top_y, .width = left_w, .height = full_h },
        .right => .{ .x = right_x, .y = top_y, .width = right_w, .height = full_h },
        .top_left => .{ .x = left_x, .y = top_y, .width = left_w, .height = top_h },
        .top_right => .{ .x = right_x, .y = top_y, .width = right_w, .height = top_h },
        .bottom_left => .{ .x = left_x, .y = bottom_y, .width = left_w, .height = bottom_h },
        .bottom_right => .{ .x = right_x, .y = bottom_y, .width = right_w, .height = bottom_h },
    };
}

pub fn targetRect(usable: wlr.Box, target: Target, gap: u32) wlr.Box {
    return switch (target) {
        .maximize => usable,
        .tile => |tile| tileRect(usable, tile, gap),
    };
}

/// Edges a tile touches, for xdg-shell's tiled states (clients drop their
/// shadows and rounded corners there).
pub fn tiledEdges(tile: Tile) wlr.Edges {
    return switch (tile) {
        .left => .{ .top = true, .bottom = true, .left = true },
        .right => .{ .top = true, .bottom = true, .right = true },
        .top_left => .{ .top = true, .left = true },
        .top_right => .{ .top = true, .right = true },
        .bottom_left => .{ .bottom = true, .left = true },
        .bottom_right => .{ .bottom = true, .right = true },
    };
}

pub const Direction = enum { left, right, up, down };

/// Super+Shift+arrow: the layout one step in `dir`. Opposite halves and
/// maximize pass through floating; up/down split a half into its quarters and
/// join quarters back into halves.
pub fn step(layout: Layout, dir: Direction) Layout {
    return switch (layout) {
        .floating => switch (dir) {
            .left => .{ .tiled = .left },
            .right => .{ .tiled = .right },
            .up => .maximized,
            .down => .floating,
        },
        .maximized => switch (dir) {
            .left => .{ .tiled = .left },
            .right => .{ .tiled = .right },
            .up => .maximized,
            .down => .floating,
        },
        .tiled => |tile| switch (tile) {
            .left => switch (dir) {
                .left => layout,
                .right => .floating,
                .up => .{ .tiled = .top_left },
                .down => .{ .tiled = .bottom_left },
            },
            .right => switch (dir) {
                .left => .floating,
                .right => layout,
                .up => .{ .tiled = .top_right },
                .down => .{ .tiled = .bottom_right },
            },
            .top_left => switch (dir) {
                .left => layout,
                .right => .{ .tiled = .top_right },
                .up => .maximized,
                .down => .{ .tiled = .left },
            },
            .top_right => switch (dir) {
                .left => .{ .tiled = .top_left },
                .right => layout,
                .up => .maximized,
                .down => .{ .tiled = .right },
            },
            .bottom_left => switch (dir) {
                .left => layout,
                .right => .{ .tiled = .bottom_right },
                .up => .{ .tiled = .left },
                .down => .floating,
            },
            .bottom_right => switch (dir) {
                .left => .{ .tiled = .bottom_left },
                .right => layout,
                .up => .{ .tiled = .right },
                .down => .floating,
            },
        },
    };
}

/// The drop target shown while dragging: an accent-tinted fill with an
/// outline, above windows so it stays visible over whatever it will cover.
pub const Preview = struct {
    tree: ?*wlr.SceneTree = null,
    fill: ?*wlr.SceneRect = null,
    outline: [4]?*wlr.SceneRect = .{ null, null, null, null },

    const outline_px = 2;

    pub fn show(preview: *Preview, parent: *wlr.SceneTree, box: wlr.Box) void {
        const tree = preview.tree orelse preview.create(parent) catch return;
        tree.node.setPosition(box.x, box.y);
        preview.fill.?.setSize(box.width, box.height);
        const t = outline_px;
        const sides = [4][4]c_int{
            .{ 0, 0, box.width, t },
            .{ 0, box.height - t, box.width, t },
            .{ 0, t, t, box.height - 2 * t },
            .{ box.width - t, t, t, box.height - 2 * t },
        };
        for (preview.outline, sides) |rect, side| {
            rect.?.node.setPosition(side[0], side[1]);
            rect.?.setSize(@max(0, side[2]), @max(0, side[3]));
        }
        tree.node.raiseToTop();
        tree.node.setEnabled(true);
    }

    pub fn hide(preview: *Preview) void {
        if (preview.tree) |tree| tree.node.setEnabled(false);
    }

    fn create(preview: *Preview, parent: *wlr.SceneTree) !*wlr.SceneTree {
        const tree = try parent.createSceneTree();
        errdefer tree.node.destroy();
        const accent = col.Straight.fromRgba(theme.shellPalette().accent).premultiply();
        const fill = try col.createRect(tree, 0, 0, accent.scale(0.16));
        var outline: [4]?*wlr.SceneRect = undefined;
        for (&outline) |*rect| rect.* = try col.createRect(tree, 0, 0, accent.scale(0.55));
        preview.* = .{ .tree = tree, .fill = fill, .outline = outline };
        return tree;
    }
};

const testing = std.testing;
const test_screen: wlr.Box = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
const test_usable: wlr.Box = .{ .x = 0, .y = 0, .width = 1280, .height = 672 };

test "edges pick halves, maximize and quarters" {
    try testing.expectEqual(@as(?Target, .{ .tile = .left }), targetAt(0, 360, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, .{ .tile = .right }), targetAt(1279.9, 360, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, .maximize), targetAt(640, 0, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, .{ .tile = .top_left }), targetAt(0, 10, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, .{ .tile = .top_right }), targetAt(1275, 0, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, .{ .tile = .bottom_left }), targetAt(0, 700, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, .{ .tile = .bottom_right }), targetAt(1279, 719, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, null), targetAt(640, 719, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, null), targetAt(640, 360, test_screen, test_usable, .{}));
    try testing.expectEqual(@as(?Target, null), targetAt(3, 360, test_screen, test_usable, .{}));
}

test "edges shared with another output never snap" {
    const second: wlr.Box = .{ .x = 1280, .y = 0, .width = 1920, .height = 1080 };
    try testing.expectEqual(@as(?Target, null), targetAt(1280, 500, second, second, .{ .left = false }));
    try testing.expectEqual(@as(?Target, .{ .tile = .right }), targetAt(3199.5, 500, second, second, .{ .left = false }));
    try testing.expectEqual(@as(?Target, null), targetAt(1600, 0, second, second, .{ .top = false }));
}

test "tiles share their splits and keep the gap" {
    const odd: wlr.Box = .{ .x = 100, .y = 50, .width = 1281, .height = 673 };
    for ([_]u32{ 0, 8, 13 }) |gap| {
        const g: i32 = @intCast(gap);
        const l = tileRect(odd, .left, gap);
        const r = tileRect(odd, .right, gap);
        try testing.expectEqual(odd.x + g, l.x);
        try testing.expectEqual(l.x + l.width + g, r.x);
        try testing.expectEqual(odd.x + odd.width - g, r.x + r.width);
        try testing.expectEqual(odd.y + g, l.y);
        try testing.expectEqual(odd.y + odd.height - g, l.y + l.height);
        const tl = tileRect(odd, .top_left, gap);
        const bl = tileRect(odd, .bottom_left, gap);
        try testing.expectEqual(tl.y + tl.height + g, bl.y);
        try testing.expectEqual(odd.y + odd.height - g, bl.y + bl.height);
        try testing.expectEqual(l.width, tl.width);
        try testing.expectEqual(r.x, tileRect(odd, .bottom_right, gap).x);
    }
}

test "a huge gap leaves every tile at least a pixel" {
    const tiny: wlr.Box = .{ .x = 0, .y = 0, .width = 20, .height = 11 };
    inline for (std.meta.fields(Tile)) |field| {
        const rect = tileRect(tiny, @field(Tile, field.name), 512);
        try testing.expect(rect.width >= 1 and rect.height >= 1);
    }
}

test "keyboard steps walk halves, quarters and back" {
    try testing.expect(step(.floating, .left).eql(.{ .tiled = .left }));
    try testing.expect(step(.{ .tiled = .left }, .right).eql(.floating));
    try testing.expect(step(.{ .tiled = .left }, .up).eql(.{ .tiled = .top_left }));
    try testing.expect(step(.{ .tiled = .top_left }, .down).eql(.{ .tiled = .left }));
    try testing.expect(step(.{ .tiled = .top_left }, .up).eql(.maximized));
    try testing.expect(step(.maximized, .down).eql(.floating));
    try testing.expect(step(.maximized, .right).eql(.{ .tiled = .right }));
    try testing.expect(step(.{ .tiled = .bottom_right }, .down).eql(.floating));
}
