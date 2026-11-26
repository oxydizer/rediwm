//! Overview presentation: stable window IDs, balanced grid and live frame
//! transforms. No client size or saved window geometry changes.
const std = @import("std");
const World = @import("../World.zig");
const Top = @import("../Toplevel.zig");
const Self = @import("overview.zig");
const layout = @import("overview_layout.zig");
const ui = @import("ui");
const gpa = @import("../main.zig").gpa;

pub const Card = struct {
    id: u64,
    target: layout.Rect = .{},
    presented: layout.Rect = .{},
    /// Hover/wheel magnification of `target` and its top-left offset (layout px).
    magnify: ui.anim.Anim = .{ .from = 1, .to = 1 },
    shift_x: ui.anim.Anim = .{},
    shift_y: ui.anim.Anim = .{},
};

pub fn find(self: *Self, id: u64) ?*Card {
    for (self.cards.items) |*card| if (card.id == id) return card;
    return null;
}

pub fn prepare(self: *Self, world: *World) !void {
    var i: usize = 0;
    while (i < self.cards.items.len) {
        const gone = if (Self.find(world, self.cards.items[i].id)) |top| !onStrip(self, top) else true;
        if (gone) {
            _ = self.cards.orderedRemove(i);
        } else i += 1;
    }
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (!Self.eligible(top) or find(self, top.id) != null or !onStrip(self, top)) continue;
        try self.cards.append(gpa, .{ .id = top.id });
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
    if (self.strip != 0) {
        // Each window where it sits on the strip, the strip scaled to fit.
        const strip = &world.workspaces.tiler.strips[self.strip - 1];
        const s = strip.overviewScale();
        for (self.cards.items) |*card| {
            const top = Self.find(world, card.id).?;
            const at = strip.overviewPoint(@floatFromInt(top.x), @floatFromInt(top.y));
            card.target = .{ .x = at[0], .y = at[1], .width = @as(f64, @floatFromInt(top.chrome_width)) * s, .height = @as(f64, @floatFromInt(top.chrome_height)) * s };
        }
        return;
    }
    const area = self.output.?.usableBox();
    const bounds: layout.Rect = .{ .x = @floatFromInt(area.x), .y = @floatFromInt(area.y), .width = @floatFromInt(area.width), .height = @floatFromInt(area.height) };
    for (self.cards.items, 0..) |*card, index| {
        const top = Self.find(world, card.id).?;
        card.target = layout.place(self.cards.items.len, index, bounds, @floatFromInt(top.chrome_width), @floatFromInt(top.chrome_height));
    }
}

/// A strip overview shows the windows of its workspace, minimized ones aside.
fn onStrip(self: *const Self, top: *const Top) bool {
    return self.strip == 0 or (top.workspace_id == self.strip and !top.minimized);
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
    const goal = @import("overview_hover.zig").rect(card, now);
    const displayed_scale = scale * z + (goal.width / @as(f64, @floatFromInt(top.chrome_width)) - scale * z) * amount;
    const left = normal.x + (goal.x - normal.x) * amount;
    const upper = normal.y + (goal.y - normal.y) * amount;
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
