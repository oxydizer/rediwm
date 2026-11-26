//! Bridge from workspace membership to scrolling strips (`scroll_layout.zig`):
//! membership sync, the view following focus, the strip-order keyboard
//! actions, culling of columns outside the view, and the floating layer
//! that stays above the strip. World = layout holds: a scrolled window
//! really sits at its strip position, however far off-screen.
const std = @import("std");
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const Node = @import("node.zig").Node;
const scroll = @import("scroll_layout.zig");
const scroll_motion = @import("scroll_motion.zig");
const tiling = @import("auto_tiling.zig");
const workspaces = @import("workspaces.zig");
const Output = @import("Output.zig");
const keybinds = @import("config").keybinds;
const ScrollDirection = @import("config").output_config.ScrollDirection;
const gpa = @import("main.zig").gpa;

pub fn options(server: *Server, id: u8) scroll.Options {
    return .{ .direction = direction(server, id), .width = server.config.compositor.scroll_column_width };
}

/// `[[outputs]] scroll_direction`, with `auto` the longer side of `box`:
/// sideways on a landscape display, up and down on a portrait or rotated one.
pub fn resolve(choice: ScrollDirection, box: scroll.Box) scroll.Direction {
    return switch (choice) {
        .horizontal => .horizontal,
        .vertical => .vertical,
        .auto => if (box.height > box.width) .vertical else .horizontal,
    };
}

pub fn setting(output: *Output) ScrollDirection {
    return if (Output.configured(output.server, output.wlr_output)) |config| config.scroll_direction else .auto;
}

/// The direction a strip runs on `output`. The usable box is in layout
/// units, so it already reflects the output's transform.
pub fn outputDirection(output: *Output) scroll.Direction {
    const box = output.usableBox();
    return resolve(setting(output), .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height });
}

/// Workspace `id`'s strip takes the direction of the display showing it.
pub fn direction(server: *Server, id: u8) scroll.Direction {
    if (server.world.workspaces.slots[id - 1].output) |output| return outputDirection(output);
    return resolve(.auto, viewport(server, id));
}

pub fn center(server: *const Server) scroll.Center {
    return std.meta.stringToEnum(scroll.Center, @tagName(server.config.compositor.scroll_center)).?;
}

fn presets(server: *const Server, buffer: *[@import("config").loader.max_column_widths]f64) []const f64 {
    const cfg = server.config.compositor;
    for (cfg.scroll_column_widths[0..cfg.scroll_column_width_count], 0..) |width, i| buffer[i] = width;
    return buffer[0..cfg.scroll_column_width_count];
}

fn viewport(server: *Server, id: u8) scroll.Box {
    const slot = &server.world.workspaces.slots[id - 1];
    const box = if (slot.output) |output| output.usableBox() else slot.box;
    return .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
}

pub fn scrolling(server: *const Server, id: u8) bool {
    return server.world.workspaces.active and server.world.workspaces.layoutOf(id) == .scrolling;
}

/// Admit existing windows when their workspace starts scrolling. An explicit
/// layout override was already in effect when switching between tiled modes.
pub fn arrangeExisting(server: *Server, from_canvas: bool) void {
    const manager = &server.world.workspaces;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        const id = top.workspace_id;
        if (!scrolling(server, id) or top.currentIdentity().dialog) continue;
        const override = manager.slots[id - 1].layout;
        if (!from_canvas and override != null) continue;
        // Returning from Canvas keeps the strip's floating choices. A snap
        // carried over from Canvas itself is fitted by mapped() and opts out.
        const returning = from_canvas and (override == .scrolling or manager.last_tiled == .scrolling);
        if (!returning or top.tile != null) {
            top.auto_float = false;
            top.auto_float_override = null;
        }
        if (tiling.isFloating(top)) continue;
        if (top.fullscreen and top.open_rules.fullscreen == true) continue;
        if (top.maximized and top.open_rules.maximized == true) continue;
        top.prepareAutoTile();
    }
}

/// Whether the strip places `top`.
pub fn isMember(top: *const Top) bool {
    return !top.minimized and !top.fullscreen and !top.maximized and top.auto_target != null and top.workspace_id != 0 and scrolling(top.server, top.workspace_id);
}

/// The strip member a window belongs to: itself, or the owner its dialogs
/// move with.
pub fn memberOf(top: *Top) ?*Top {
    var current = top;
    for (0..32) |_| {
        if (isMember(current)) return current;
        current = current.parentWindow() orelse return null;
    }
    return null;
}

/// A maximized or fullscreen window keeps its column while it covers the
/// strip: the column takes no room, but arrows still stop there.
fn waiting(top: *Top) bool {
    if (top.minimized or !(top.maximized or top.fullscreen) or top.workspace_id == 0 or !scrolling(top.server, top.workspace_id)) return false;
    return top.server.world.workspaces.tiler.strips[top.workspace_id - 1].contains(tiling.key(top));
}

/// The window whose strip slot `top` navigates from: its member, or the
/// maximized or fullscreen window waiting in the strip that it belongs to.
fn slotOf(top: *Top) ?*Top {
    if (memberOf(top)) |member| return member;
    var current = top;
    for (0..32) |_| {
        if (waiting(current)) return current;
        current = current.parentWindow() orelse return null;
    }
    return null;
}

/// The slot of the window workspace `id` last focused.
fn focusedSlot(server: *Server, id: u8) ?*Top {
    const top = server.findToplevelById(server.world.workspaces.slots[id - 1].focus orelse return null) orelse return null;
    if (top.workspace_id != id) return null;
    return slotOf(top);
}

/// Strip keys arrows can stop at besides active members.
const Reach = struct {
    server: *Server,
    id: u8,

    fn reachable(reach: Reach, key: scroll.Key) bool {
        const top = windowFor(reach.server, reach.id, key) orelse return false;
        return waiting(top);
    }
};

/// The key the view follows on workspace `id`: its focused window's column.
/// Asks the strip, not the window: a window that just mapped has focus but
/// no tile until this reflow places it.
pub fn focusKey(server: *Server, id: u8) ?scroll.Key {
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    var current = server.findToplevelById(server.world.workspaces.slots[id - 1].focus orelse return null) orelse return null;
    for (0..32) |_| {
        if (current.workspace_id == id and strip.rectangle(tiling.key(current)) != null) return tiling.key(current);
        current = current.parentWindow() orelse return null;
    }
    return null;
}

/// Membership into the strip, then the view: the focused column stays where
/// a reveal puts it, also when the viewport changed.
pub fn sync(server: *Server, id: u8, members: []const scroll.Member) !bool {
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    const box = viewport(server, id);
    // With no known display size, defer placement until syncOutputs. A zero
    // cross extent would expel every stacked member and lose the saved view.
    if (box.width <= 0 or box.height <= 0) return false;
    try strip.sync(gpa, members, box, server.config.compositor.windowGap(), options(server, id));
    if (focusKey(server, id)) |key| {
        _ = showColumn(server, id, key);
    } else if (scroll_motion.settlingTo(server, id)) |target| {
        // The strip shrank under a settling release.
        if (target > strip.maxView()) {
            scroll_motion.stopSnap(server, id);
            strip.view = strip.maxView();
        }
    } else if (!scroll_motion.holdsView(server, id)) strip.clampView();
    strip.place();
    return true;
}

/// Moves workspace `id`'s view to show the column holding `key`, unless a
/// gesture holds the view or a settling release already ends with it in
/// view (so a click mid-glide does not stop it between columns). A release
/// heading elsewhere is cancelled and the reveal starts from its target,
/// so the view still rests on a column edge. True when the view changed;
/// the caller places the windows.
fn showColumn(server: *Server, id: u8, key: scroll.Key) bool {
    if (scroll_motion.holdsView(server, id)) return false;
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    const at = strip.locate(key) orelse return false;
    var changed = false;
    if (scroll_motion.settlingTo(server, id)) |target| {
        if (target <= strip.maxView() and strip.columnCovers(at.column, target)) return false;
        scroll_motion.stopSnap(server, id);
        strip.view = std.math.clamp(target, 0, strip.maxView());
        changed = true;
    }
    const view = strip.revealView(key, center(server));
    if (view != strip.view) {
        strip.view = view;
        changed = true;
    }
    return changed;
}

/// Focus scrolls the strip to show `top`'s column.
pub fn reveal(top: *Top) void {
    const member = memberOf(top) orelse return;
    const server = top.server;
    const id = member.workspace_id;
    const manager = &server.world.workspaces.tiler;
    if (manager.applying) return;
    if (!showColumn(server, id, tiling.key(member))) return;
    manager.strips[id - 1].place();
    place(server, id, !@import("ui").anim.reducedMotion());
}

/// Shows workspace `id`'s focused column when the view has left it: the
/// end of every settling release, whatever changed while it moved.
pub fn revealFocus(server: *Server, id: u8) void {
    const manager = &server.world.workspaces.tiler;
    if (manager.applying) return;
    const key = focusKey(server, id) orelse return;
    const strip = &manager.strips[id - 1];
    const at = strip.locate(key) orelse return;
    if (strip.columnCovers(at.column, strip.view)) return;
    if (!showColumn(server, id, key)) return;
    strip.place();
    place(server, id, !@import("ui").anim.reducedMotion());
}

/// The strip view jumps to show `top`'s column, windows placed there at
/// once: leaving the strip overview, which animates the way back itself.
pub fn jumpTo(top: *Top) void {
    const member = memberOf(top) orelse return;
    const server = top.server;
    const id = member.workspace_id;
    scroll_motion.stopSnap(server, id);
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    strip.view = strip.revealView(tiling.key(member), center(server));
    strip.place();
    place(server, id, false);
}

/// Moves every member of workspace `id` to its strip rectangle, and dialogs
/// with their owners. A move that keeps the size configures nobody.
pub fn place(server: *Server, id: u8, animate: bool) void {
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.workspace_id != id or !isMember(top)) continue;
        const rect = strip.rectangle(tiling.key(top)) orelse continue;
        const x = top.x;
        const y = top.y;
        top.setAutoTile(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, animate and workspaces.visible(top));
        carryDialogs(top, top.x - x, top.y - y, animate);
    }
}

/// Floating windows stay put while the strip scrolls; a dialog moves with
/// the strip member it belongs to, so it never ends up over another column.
pub fn carryDialogs(owner: *Top, dx: i32, dy: i32, animate: bool) void {
    if (dx == 0 and dy == 0) return;
    var it = owner.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top == owner or isMember(top) or top.fullscreen or top.maximized) continue;
        if (memberOf(top) != owner) continue;
        if (animate and workspaces.visible(top)) top.setPositionAnimated(top.x + dx, top.y + dy) else top.setPosition(top.x + dx, top.y + dy);
    }
}

/// A window of the strip wholly outside its workspace's display is not drawn
/// and takes no input; it keeps its membership (focus, Alt+Tab, taskbar).
pub fn culled(top: *Top, x: i32, y: i32) bool {
    if (!scrolling(top.server, top.workspace_id)) return false;
    const member = memberOf(top) orelse return false;
    const output = workspaces.outputFor(member) orelse return false;
    const box = output.cached_box;
    return x + top.chrome_width <= box.x or x >= box.x + box.width or
        y + top.chrome_height <= box.y or y >= box.y + box.height;
}

/// While a strip glides, panels hold their glass instead of re-blurring.
pub fn moving(server: *Server, id: u8) bool {
    if (!scrolling(server, id)) return false;
    if (scroll_motion.active(server, id)) return true;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.workspace_id == id and top.auto_target != null and
            (top.move_x.active() or top.move_y.active()) and workspaces.visible(top)) return true;
    }
    return false;
}

const Layer = enum(u8) { background, strip, floating, foreground };

/// Dialogs stay in the same layer as their covering owner.
fn coveringWindow(top: *Top) ?*Top {
    var current = top;
    var cover: ?*Top = null;
    for (0..32) |_| {
        if (current.maximized or current.fullscreen) cover = current;
        current = current.parentWindow() orelse break;
    }
    return cover;
}

fn focusedCover(server: *Server, focus_id: ?u64) ?*Top {
    const top = server.findToplevelById(focus_id orelse return null) orelse return null;
    return coveringWindow(top);
}

fn layer(top: *Top, foreground: ?*Top) Layer {
    if (isMember(top)) return .strip;
    if (coveringWindow(top)) |cover| return if (cover == foreground) .foreground else .background;
    return .floating;
}

fn stackedWindow(node: *Node, id: u8) ?*Top {
    const data = @import("scene_data.zig").SceneData.fromNode(node) orelse return null;
    if (data.role != .toplevel) return null;
    const top = data.role.toplevel;
    return if (top.in_world and !top.closing and top.workspace_id == id) top else null;
}

/// Raise a window to the top of its layer.
pub fn raiseFloor(top: *Top) ?*Top {
    if (!scrolling(top.server, top.workspace_id)) return null;
    const foreground = focusedCover(top.server, top.server.world.workspaces.slots[top.workspace_id - 1].focus);
    const own_layer = layer(top, foreground);
    if (own_layer == .foreground) return null;
    const parent = top.frame_tree.node.parent orelse return null;
    var it = parent.children.iterator(.forward);
    while (it.next()) |node| {
        const other = stackedWindow(node, top.workspace_id) orelse continue;
        if (@backingInt(layer(other, foreground)) > @backingInt(own_layer)) return other;
    }
    return null;
}

/// An unfocused maximized or fullscreen window goes behind the strip so it
/// cannot cover a newly revealed tile. Keep relative order within each layer.
pub fn restack(server: *Server, id: u8) void {
    const foreground = focusedCover(server, server.world.workspaces.slots[id - 1].focus);
    var first: [std.enums.values(Layer).len]?*Node = @splat(null);
    var it = server.world.tree.children.iterator(.forward);
    while (it.next()) |node| {
        const top = stackedWindow(node, id) orelse continue;
        const index: usize = @backingInt(layer(top, foreground));
        if (first[index] == null) first[index] = node;
        for (first[index + 1 ..]) |above| {
            const sibling = above orelse continue;
            node.placeBelow(sibling);
            top.syncXwaylandStack();
            break;
        }
    }
}

pub fn focusChanged(top: *Top, previous: ?u64) void {
    if (!scrolling(top.server, top.workspace_id)) return;
    if (focusedCover(top.server, previous) != coveringWindow(top)) restack(top.server, top.workspace_id);
}

pub const Arrow = enum { left, right, up, down };

/// An arrow as a strip step. On a vertical strip Up/Down move along it and
/// Left/Right within a row, so each arrow still points where focus goes.
pub fn stepFor(dir: scroll.Direction, arrow: Arrow) scroll.Step {
    return switch (dir) {
        .horizontal => switch (arrow) {
            .left => .previous_column,
            .right => .next_column,
            .up => .previous_member,
            .down => .next_member,
        },
        .vertical => switch (arrow) {
            .up => .previous_column,
            .down => .next_column,
            .left => .previous_member,
            .right => .next_member,
        },
    };
}

/// Strip-order focus: along the strip, or within a column, stopping at
/// maximized and fullscreen windows too. At the end of the strip the key
/// still brings the focused column into view.
pub fn focus(server: *Server, top: *Top, arrow: Arrow) bool {
    const from = slotOf(top) orelse return false;
    const id = from.workspace_id;
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    const step = stepFor(strip.direction, arrow);
    const next = strip.neighborWhere(tiling.key(from), step, Reach{ .server = server, .id = id }, Reach.reachable) orelse {
        revealFocus(server, id);
        return true;
    };
    const target = windowFor(server, id, next) orelse return true;
    server.world.focus(target);
    return true;
}

/// Super+arrow with no window focused (the desktop took the keyboard): the
/// strip under the pointer carries on from the window it focused last, or
/// focuses the column in view.
pub fn focusUnfocused(server: *Server, arrow: Arrow) void {
    const output = server.getDefaultOutput() orelse return;
    const id = output.workspace_id;
    if (id == 0 or !scrolling(server, id)) return;
    if (focusedSlot(server, id)) |slot| if (workspaces.visible(slot)) {
        _ = focus(server, slot, arrow);
        return;
    };
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    const snap = strip.snapView(strip.view, center(server)) orelse return;
    const key = strip.memberNear(snap.column, null) orelse return;
    server.world.focus(windowFor(server, id, key) orelse return);
}

/// Super+Shift+wheel and the horizontal wheel: focus `steps` columns along
/// workspace `id`'s strip; the view follows.
pub fn stepColumns(server: *Server, id: u8, steps: i32) void {
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    const focused = focusedSlot(server, id);
    const start = if (focused) |slot| tiling.key(slot) else for (strip.columns.items, 0..) |_, c| {
        if (strip.memberNear(c, null)) |first| break first;
    } else return;
    var key = start;
    var remaining = @abs(steps);
    while (remaining > 0) : (remaining -= 1) {
        key = strip.neighborWhere(key, if (steps > 0) .next_column else .previous_column, Reach{ .server = server, .id = id }, Reach.reachable) orelse break;
    }
    if (focused != null and std.meta.eql(key, start)) return revealFocus(server, id);
    const top = windowFor(server, id, key) orelse return;
    server.world.focus(top);
}

/// The window shown for strip key `key`: the member, or a tab group's
/// selected tab.
pub fn windowFor(server: *Server, id: u8, key: scroll.Key) ?*Top {
    var fallback: ?*Top = null;
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.workspace_id != id or !std.meta.eql(tiling.key(top), key)) continue;
        if (!top.tab_hidden) return top;
        fallback = top;
    }
    return fallback;
}

/// The tiling actions on a scrolling workspace. False for actions that only
/// apply to split tiles.
pub fn execute(server: *Server, top: *Top, action: keybinds.TilingAction) !bool {
    const strip = &server.world.workspaces.tiler.strips[top.workspace_id - 1];
    const key = tiling.key(top);
    switch (action) {
        .swap_left, .swap_right, .swap_up, .swap_down => {
            const side: scroll.Side = if (action == .swap_left or action == .swap_up) .before else .after;
            if (along(strip.direction, action == .swap_left or action == .swap_right))
                _ = strip.moveColumn(key, side)
            else
                _ = strip.moveInColumn(key, side);
        },
        .resize_split_left, .resize_split_right, .resize_split_up, .resize_split_down => {
            const pixels: i32 = if (action == .resize_split_left or action == .resize_split_up) -32 else 32;
            if (along(strip.direction, action == .resize_split_left or action == .resize_split_right))
                strip.stepWidth(key, pixels)
            else
                strip.stepWeight(key, pixels);
        },
        .consume_left => _ = try strip.consume(gpa, key, .before),
        .consume_right => _ = try strip.consume(gpa, key, .after),
        .cycle_column_width => {
            var buffer: [@import("config").loader.max_column_widths]f64 = undefined;
            strip.cycleWidth(key, presets(server, &buffer));
        },
        .toggle_split, .toggle_floating, .toggle_workspace_tiling => return false,
    }
    return true;
}

/// Whether a horizontal (Left/Right) or vertical arrow acts along the strip.
fn along(dir: scroll.Direction, horizontal_arrow: bool) bool {
    return horizontal_arrow == (dir == .horizontal);
}

test "arrows follow the strip's axis" {
    try std.testing.expectEqual(scroll.Step.next_column, stepFor(.horizontal, .right));
    try std.testing.expectEqual(scroll.Step.previous_member, stepFor(.horizontal, .up));
    try std.testing.expectEqual(scroll.Step.next_column, stepFor(.vertical, .down));
    try std.testing.expectEqual(scroll.Step.previous_member, stepFor(.vertical, .left));
    try std.testing.expect(along(.horizontal, true) and !along(.horizontal, false));
    try std.testing.expect(along(.vertical, false) and !along(.vertical, true));
}

test "auto scrolls along the longer side" {
    const landscape: scroll.Box = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const portrait: scroll.Box = .{ .x = 1920, .y = 0, .width = 1080, .height = 1920 };
    try std.testing.expectEqual(scroll.Direction.horizontal, resolve(.auto, landscape));
    try std.testing.expectEqual(scroll.Direction.vertical, resolve(.auto, portrait));
    try std.testing.expectEqual(scroll.Direction.horizontal, resolve(.auto, .{ .x = 0, .y = 0, .width = 900, .height = 900 }));
    try std.testing.expectEqual(scroll.Direction.horizontal, resolve(.horizontal, portrait));
    try std.testing.expectEqual(scroll.Direction.vertical, resolve(.vertical, landscape));
}
