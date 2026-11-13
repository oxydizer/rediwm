//! Overview presentation: stable window IDs, balanced grid, live frame transforms
//! and cached readable captions. No client size or saved window geometry changes.
const std = @import("std");
const World = @import("../World.zig");
const Top = @import("../Toplevel.zig");
const Self = @import("overview.zig");
const sn = @import("../node.zig");
const layout = @import("overview_layout.zig");
const ui = @import("ui");
const gpa = @import("../main.zig").gpa;

pub const Card = struct {
    id: u64,
    label: *sn.Buffer,
    label_hash: u64 = 0,
    label_width: i32 = 0,
    label_height: i32 = 0,
    label_scale: f32 = 0,
    target: layout.Rect = .{},
    caption: layout.Rect = .{},
    presented: layout.Rect = .{},
};

pub fn find(self: *Self, id: u64) ?*Card {
    for (self.cards.items) |*card| if (card.id == id) return card;
    return null;
}

pub fn prepare(self: *Self, world: *World) !void {
    var i: usize = 0;
    while (i < self.cards.items.len) {
        if (Self.find(world, self.cards.items[i].id) == null) {
            self.cards.items[i].label.node.destroy();
            _ = self.cards.orderedRemove(i);
        } else i += 1;
    }
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (!Self.eligible(top) or find(self, top.id) != null) continue;
        try self.cards.ensureUnusedCapacity(gpa, 1);
        const label = try self.tree.?.createSceneBuffer(null);
        label.point_accepts_input = Self.ignoreInput;
        self.cards.appendAssumeCapacity(.{ .id = top.id, .label = label });
    }
    // Stable spatial order, including identical overlapping frames. Focusing
    // a window changes stacking order but must not shuffle the next overview.
    std.mem.sort(Card, self.cards.items, world, struct {
        fn less(w: *World, a: Card, b: Card) bool {
            const left = Self.find(w, a.id).?;
            const right = Self.find(w, b.id).?;
            if (left.y != right.y) return left.y < right.y;
            if (left.x != right.x) return left.x < right.x;
            return left.id < right.id;
        }
    }.less);
    const area = self.output.?.usableBox();
    const bounds: layout.Rect = .{ .x = @floatFromInt(area.x), .y = @floatFromInt(area.y), .width = @floatFromInt(area.width), .height = @floatFromInt(area.height) };
    for (self.cards.items, 0..) |*card, index| {
        const top = Self.find(world, card.id).?;
        const p = layout.place(self.cards.items.len, index, bounds, @floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height), ui.theme.global.switcher_title_size + 12);
        card.target = p.frame;
        card.caption = p.label;
        try paintLabel(self, card, top);
    }
}

fn paintLabel(self: *Self, card: *Card, top: *Top) !void {
    const title = top.title();
    const hash = std.hash.Wyhash.hash(@intFromBool(top.minimized), title);
    const width: i32 = @max(1, @as(i32, @intFromFloat(@round(card.caption.width))));
    const height: i32 = @max(1, @as(i32, @intFromFloat(@round(card.caption.height))));
    const scale = self.output.?.wlr_output.scale;
    if (card.label_width == width and card.label_height == height and card.label_hash == hash and card.label_scale == scale) return;
    const image = try @import("../panel_buffer.zig").PanelBuffer.create(width, height, self.output.?.wlr_output.scale);
    defer image.base.drop();
    const t = ui.theme.global;
    var renderer = ui.paint.Renderer.init(image.pixels, image.width, image.height, self.output.?.wlr_output.scale);
    renderer.fillRect(0, 0, @floatFromInt(width), @floatFromInt(height), .{ .color = t.switcher_item_bg, .radius = 5 });
    const font = @min(t.switcher_title_size, @as(f32, @floatFromInt(height)) - 4);
    renderer.drawText(8, 0, @floatFromInt(@max(1, width - 16)), @floatFromInt(height), .{
        .content = if (title.len > 0) title else top.appId(),
        .font_size = @max(1, font),
        .color = if (top.minimized) t.switcher_dim else t.switcher_fg,
    });
    card.label.setBuffer(&image.base);
    card.label.setDestSize(width, height);
    card.label_width = width;
    card.label_height = height;
    card.label_hash = hash;
    card.label_scale = scale;
}

/// Override the source frame's presentation only. The projection still draws
/// the real client buffers, subsurfaces, chrome and shapes and paces their frames.
pub fn apply(self: *Self, top: *Top, x: i32, y: i32, scale: f64, now: i64) bool {
    if (!self.active() or top.closing) return false;
    const card = find(self, top.id) orelse return false;
    const world = &top.server.world;
    const amount = self.amount(now);
    const normal = world.toLayout(@floatFromInt(x), @floatFromInt(y));
    const z = world.camera.zoom();
    const displayed_scale = scale * z + (card.target.width / @as(f64, @floatFromInt(top.chrome_width)) - scale * z) * amount;
    const left = normal.x + (card.target.x - normal.x) * amount;
    const upper = normal.y + (card.target.y - normal.y) * amount;
    const p = world.toWorld(left, upper);
    const wx: i32 = @intFromFloat(@round(p.x));
    const wy: i32 = @intFromFloat(@round(p.y));
    _ = @import("../projection.zig").setTreeZoom(&top.frame_tree.node, displayed_scale / z);
    top.frame_tree.node.setPosition(wx, wy);
    top.frame_tree.node.setEnabled(true);
    const snapped = world.toLayout(@floatFromInt(wx), @floatFromInt(wy));
    card.presented = .{ .x = snapped.x, .y = snapped.y, .width = @as(f64, @floatFromInt(top.chrome_width)) * displayed_scale, .height = @as(f64, @floatFromInt(top.chrome_height)) * displayed_scale };
    return true;
}

pub fn paint(self: *Self, now: i64) void {
    const alpha: f32 = @floatCast(self.amount(now));
    for (self.cards.items) |*card| {
        card.label.node.setPosition(@intFromFloat(@round(card.caption.x)), @intFromFloat(@round(card.caption.y)));
        card.label.setOpacity(alpha);
    }
    const selected = if (self.selected) |id| find(self, id) else null;
    for (self.edges) |edge| edge.node.setEnabled(selected != null and !self.returning);
    const card = selected orelse return;
    const p = card.presented;
    const x: i32 = @intFromFloat(@round(p.x) - 3);
    const y: i32 = @intFromFloat(@round(p.y) - 3);
    const w: i32 = @max(6, @as(i32, @intFromFloat(@round(p.x + p.width) - @round(p.x))) + 6);
    const h: i32 = @max(6, @as(i32, @intFromFloat(@round(p.y + p.height) - @round(p.y))) + 6);
    const rects = [_][4]i32{ .{ x, y, w, 3 }, .{ x, y + h - 3, w, 3 }, .{ x, y, 3, h }, .{ x + w - 3, y, 3, h } };
    for (self.edges, rects) |edge, rect| {
        edge.node.setPosition(rect[0], rect[1]);
        edge.setDestSize(rect[2], rect[3]);
        edge.setOpacity(alpha);
    }
}

pub fn picked(self: *Self, world: *World, x: f64, y: f64) ?u64 {
    const now = ui.anim.nowMs();
    var i = self.cards.items.len;
    while (i > 0 and self.amount(now) > 0.01) {
        i -= 1;
        const card = self.cards.items[i];
        if (card.caption.contains(x, y)) return card.id;
    }
    // While spreading/returning, frames can still overlap. The projection
    // knows their actual stacking order, clips and subsurfaces at this instant.
    const top = switch (@import("../scene_data.zig").hitTest(world.server, x, y)) {
        .surface => |hit| hit.toplevel,
        .chrome => |hit| hit.toplevel,
        .control_center => |hit| hit.cc.toplevel,
        else => return null,
    };
    return if (self.contains(top.id) and top.effectiveOpacity(now) > 0.001) top.id else null;
}
