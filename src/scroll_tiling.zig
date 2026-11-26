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
    // A gesture or a settling release owns the view.
    if (scroll_motion.active(server, id)) {} else if (focusKey(server, id)) |key| strip.view = strip.revealView(key, center(server)) else strip.clampView();
    strip.place();
    return true;
}

/// Focus scrolls the strip to show `top`'s column.
pub fn reveal(top: *Top) void {
    const member = memberOf(top) orelse return;
    const server = top.server;
    const manager = &server.world.workspaces.tiler;
    if (manager.applying or scroll_motion.holdsView(server, member.workspace_id)) return;
    scroll_motion.stopSnap(server, member.workspace_id);
    const strip = &manager.strips[member.workspace_id - 1];
    const view = strip.revealView(tiling.key(member), center(server));
    if (view == strip.view) return;
    strip.view = view;
    strip.place();
    place(server, member.workspace_id, !@import("ui").anim.reducedMotion());
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

const Layer = enum(u8) { strip, floating, maximized };

fn layer(top: *Top) Layer {
    if (isMember(top)) return .strip;
    // A maximized or fullscreen owner's dialog stays in its layer.
    var current = top;
    for (0..32) |_| {
        if (current.maximized or current.fullscreen) return .maximized;
        current = current.parentWindow() orelse break;
    }
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
    const own_layer = layer(top);
    if (own_layer == .maximized) return null;
    const parent = top.frame_tree.node.parent orelse return null;
    var it = parent.children.iterator(.forward);
    while (it.next()) |node| {
        const other = stackedWindow(node, top.workspace_id) orelse continue;
        if (@backingInt(layer(other)) > @backingInt(own_layer)) return other;
    }
    return null;
}

/// Mapping, floating an unfocused member, and switching layouts can change
/// layers without a focus change. Keep relative order within each layer.
pub fn restack(server: *Server, id: u8) void {
    var first_float: ?*Node = null;
    var first_maximized: ?*Node = null;
    var it = server.world.tree.children.iterator(.forward);
    while (it.next()) |node| {
        const top = stackedWindow(node, id) orelse continue;
        const above = switch (layer(top)) {
            .strip => first_float orelse first_maximized,
            .floating => blk: {
                if (first_float == null) first_float = node;
                break :blk first_maximized;
            },
            .maximized => {
                if (first_maximized == null) first_maximized = node;
                continue;
            },
        };
        if (above) |sibling| {
            node.placeBelow(sibling);
            top.syncXwaylandStack();
        }
    }
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

/// Strip-order focus: along the strip, or within a column.
pub fn focus(server: *Server, top: *Top, arrow: Arrow) bool {
    const member = memberOf(top) orelse return false;
    const strip = &server.world.workspaces.tiler.strips[member.workspace_id - 1];
    const step = stepFor(strip.direction, arrow);
    const next = strip.neighbor(tiling.key(member), step) orelse return true;
    const target = windowFor(server, member.workspace_id, next) orelse return true;
    server.world.focus(target);
    return true;
}

/// Super+Shift+wheel and the horizontal wheel: focus `steps` columns along
/// workspace `id`'s strip; the view follows.
pub fn stepColumns(server: *Server, id: u8, steps: i32) void {
    const strip = &server.world.workspaces.tiler.strips[id - 1];
    var key = focusKey(server, id) orelse for (strip.columns.items, 0..) |_, c| {
        if (strip.memberNear(c, null)) |first| break first;
    } else return;
    var remaining = @abs(steps);
    while (remaining > 0) : (remaining -= 1) {
        key = strip.neighbor(key, if (steps > 0) .next_column else .previous_column) orelse break;
    }
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
