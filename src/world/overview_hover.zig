//! Overview hover and wheel magnification. The preview under the pointer grows
//! by `hover_factor` and the wheel zooms it further about the pointer. Each is a
//! presentation offset relative to the card's grid rectangle. A magnified preview
//! is drawn above its neighbours; `restack` puts the scene order back on exit.
const std = @import("std");
const World = @import("../World.zig");
const Top = @import("../Toplevel.zig");
const Self = @import("overview.zig");
const cards_mod = @import("overview_cards.zig");
const layout = @import("overview_layout.zig");
const scene_data = @import("../scene_data.zig");
const anim = @import("ui").anim;
const gpa = @import("../main.zig").gpa;

pub const hover_factor: f64 = 1.1;
/// Per wheel notch.
const wheel_step: f64 = 1.25;
/// Beyond the window's own size, wheel zoom stops at this multiple of the grid size.
const min_zoom_limit: f64 = 2;
const max_zoom_limit: f64 = 8;

/// A preview raised above the frame that was directly over it.
pub const Lift = struct { id: u64, above: ?u64 };

/// Grid rectangle plus magnification, in layout coordinates.
pub fn rect(card: *const cards_mod.Card, now: i64) layout.Rect {
    const f: f64 = card.magnify.value(now);
    return .{
        .x = card.target.x + card.shift_x.value(now),
        .y = card.target.y + card.shift_y.value(now),
        .width = card.target.width * f,
        .height = card.target.height * f,
    };
}

pub fn moving(self: *const Self, now: i64) bool {
    for (self.cards.items) |card| {
        if (!card.magnify.settled(now) or !card.shift_x.settled(now) or !card.shift_y.settled(now)) return true;
    }
    return false;
}

/// Follow the pointer: `id` is the preview under it, or null over empty space.
pub fn hover(self: *Self, world: *World, id: ?u64) void {
    if (self.hovered == id) return;
    world.server.input.zoom_scroll.reset();
    if (self.hovered) |old| if (cards_mod.find(self, old)) |card| settle(card, 1, 0, 0);
    self.hovered = id;
    if (id) |new| if (cards_mod.find(self, new)) |card| {
        if (Self.find(world, new)) |top| lift(self, top);
        const goal = fit(self, scaled(card.target, hover_factor));
        settle(card, hover_factor, goal.x - card.target.x, goal.y - card.target.y);
    };
    world.server.scheduleFrames();
}

/// Wheel zoom of the hovered preview, keeping the point under (x, y) fixed.
/// Negative steps (wheel up) zoom in.
pub fn zoom(self: *Self, world: *World, steps: i32, x: f64, y: f64) void {
    if (self.returning) return;
    const id = self.hovered orelse return;
    const card = cards_mod.find(self, id) orelse return;
    const top = Self.find(world, id) orelse return;
    const native = @as(f64, @floatFromInt(top.chrome_width)) / card.target.width;
    const limit = std.math.clamp(native, min_zoom_limit, max_zoom_limit);
    const current: f64 = card.magnify.to;
    const next = std.math.clamp(current * std.math.pow(f64, wheel_step, @floatFromInt(-steps)), hover_factor, @max(hover_factor, limit));
    if (@abs(next - current) < 1e-6) {
        world.server.input.zoom_scroll.reset();
        return;
    }
    const goal = if (next <= hover_factor + 1e-6) fit(self, scaled(card.target, hover_factor)) else blk: {
        const k = next / current;
        const from: layout.Rect = .{
            .x = card.target.x + card.shift_x.to,
            .y = card.target.y + card.shift_y.to,
            .width = card.target.width * current,
            .height = card.target.height * current,
        };
        break :blk fit(self, .{
            .x = x + (from.x - x) * k,
            .y = y + (from.y - y) * k,
            .width = from.width * k,
            .height = from.height * k,
        });
    };
    settle(card, next, goal.x - card.target.x, goal.y - card.target.y);
    world.server.scheduleFrames();
}

/// Undo the scene raises, newest first, before the overview lets go of its windows.
pub fn restack(self: *Self, world: *World) void {
    var i = self.lifts.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.lifts.items[i];
        const top = byId(world, entry.id) orelse continue;
        const above = byId(world, entry.above orelse continue) orelse continue;
        if (top.frame_tree.node.parent != above.frame_tree.node.parent) continue;
        top.frame_tree.node.placeBelow(&above.frame_tree.node);
    }
    self.lifts.clearRetainingCapacity();
}

fn lift(self: *Self, top: *Top) void {
    const node = &top.frame_tree.node;
    const parent = node.parent orelse return;
    var above: ?u64 = null;
    var found = false;
    var it = parent.children.iterator(.forward);
    while (it.next()) |sibling| {
        if (sibling == node) {
            found = true;
            continue;
        }
        if (!found) continue;
        const data = scene_data.SceneData.fromNode(sibling) orelse continue;
        if (data.role != .toplevel) continue;
        above = data.role.toplevel.id;
        break;
    }
    // Already above every other window: nothing to raise or restore.
    const id = above orelse return;
    self.lifts.append(gpa, .{ .id = top.id, .above = id }) catch return;
    node.raiseToTop();
}

fn byId(world: *World, id: u64) ?*Top {
    var it = world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.id == id) return top;
    return null;
}

fn settle(card: *cards_mod.Card, factor: f64, dx: f64, dy: f64) void {
    const now = anim.nowMs();
    const curve = anim.curveFor(.window_zoom);
    card.magnify.retargetTo(now, @floatCast(factor), curve);
    card.shift_x.retargetTo(now, @floatCast(dx), curve);
    card.shift_y.retargetTo(now, @floatCast(dy), curve);
}

fn scaled(r: layout.Rect, factor: f64) layout.Rect {
    const w = r.width * factor;
    const h = r.height * factor;
    return .{ .x = r.x + (r.width - w) / 2, .y = r.y + (r.height - h) / 2, .width = w, .height = h };
}

/// Keep a preview that fits inside the output; one larger than the output
/// covers it on that axis instead of leaving a gap at an edge.
fn fit(self: *const Self, r: layout.Rect) layout.Rect {
    const area = self.output.?.usableBox();
    var out = r;
    out.x = axis(r.x, r.width, @floatFromInt(area.x), @floatFromInt(area.width));
    out.y = axis(r.y, r.height, @floatFromInt(area.y), @floatFromInt(area.height));
    return out;
}

fn axis(start: f64, size: f64, lo: f64, span: f64) f64 {
    return if (size <= span)
        std.math.clamp(start, lo, lo + span - size)
    else
        std.math.clamp(start, lo + span - size, lo);
}
