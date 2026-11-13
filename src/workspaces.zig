//! Conventional workspace ownership. Stack/focus order is deliberately separate
//! from membership; IDs and insertion order survive focus, minimize and remap.
const std = @import("std");
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const Output = @import("Output.zig");
const camera = @import("camera.zig");
const wlr = @import("wlroots");
const protocol = @import("ipc/protocol.zig");
const Self = @This();
pub const count = 32;
pub const CanvasWindow = struct {
    geometry: Top.RestoreGeometry,
    zoom_index: usize,
    layout: @import("snap.zig").Layout,
    fullscreen: bool,
    maximize_restore: ?Top.RestoreGeometry,
    tile_restore: ?Top.RestoreGeometry,
    fullscreen_restore: ?Top.RestoreGeometry,
};
const Workspace = struct {
    automatic: bool = true,
    exists: bool = false,
    output: ?*Output = null,
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    focus: ?u64 = null,
};
tiler: @import("auto_tiling.zig").Manager = .{},
active: bool = false,
changing: bool = false,
slots: [count]Workspace = @splat(.{}),
saved_camera: camera.Camera = .{},
saved_bounds: camera.Bounds = .{},
next_order: u64 = 1,
generation: u64 = 0,

pub fn visible(top: *const Top) bool {
    const self = &top.server.world.workspaces;
    if (!self.active) return true;
    if (top.workspace_id == 0 or top.workspace_id > count) return false;
    const output = self.slots[top.workspace_id - 1].output orelse return false;
    return output.isLogicallyEnabled() and output.workspace_id == top.workspace_id;
}

pub fn outputFor(top: *const Top) ?*Output {
    if (!top.server.world.workspaces.active or top.workspace_id == 0) return null;
    return top.server.world.workspaces.slots[top.workspace_id - 1].output;
}

pub fn mapped(self: *Self, top: *Top) void {
    if (!self.active) {
        if (top.canvas_state != null) restoreCanvas(top, true);
        return;
    }
    if (top.workspace_generation != self.generation) {
        top.workspace_id = 0;
        top.workspace_order = 0;
        top.workspace_generation = self.generation;
        top.auto_float = false;
        top.auto_float_override = null;
        top.auto_seen = null;
        top.auto_reinsert = null;
        top.auto_anchor = null;
    }
    if (top.parentWindow()) |parent| top.workspace_id = parent.workspace_id;
    if (top.workspace_id == 0) {
        const output = top.currentOutput() orelse return;
        top.workspace_id = output.workspace_id;
    }
    if (top.workspace_order == 0) {
        top.workspace_order = self.next_order;
        self.next_order += 1;
        // Called before the new window takes focus: this is the one it splits.
        if (top.workspace_id != 0) top.auto_anchor = self.slots[top.workspace_id - 1].focus;
    }
    if (top.server.layout_autosave) |autosave| autosave.mapped(top);
    top.zoom_index = 0;
    top.zoom_scale = 1;
    top.zoom_anim.cancel(1);
    if (outputFor(top)) |output| fit(top, output);
    @import("auto_tiling.zig").observe(top);
}

pub fn rememberFocus(self: *Self, top: *Top) void {
    if (self.active and top.workspace_id != 0) self.slots[top.workspace_id - 1].focus = top.id;
}

pub fn reveal(self: *Self, top: *Top) void {
    if (!self.active or self.changing) return;
    if (visible(top) and top.server.getDefaultOutput() == outputFor(top)) return;
    self.switchTo(top.server, top.workspace_id);
}

pub fn cancelGestures(server: *Server) void {
    server.world.overview.cancel(&server.world);
    server.switcher.cancel();
    _ = server.input.cancelDrag();
    server.input.clearGrab();
    server.input.pan_session = null;
    server.input.finger_pan = false;
    server.input.gesture = .none;
    server.input.zoom_scroll.reset();
    server.world.cancelPan();
    server.world.pinching = false;
    var keyboards = server.input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| keyboard.cancelModeRepeats();
}

pub fn setMode(self: *Self, server: *Server, enabled: bool) void {
    if (self.active == enabled or self.changing or server.greeter_mode) return;
    self.changing = true;
    defer self.changing = false;
    cancelGestures(server);
    finishTransitions(server);
    server.undo.clear();
    const applying = server.undo.applying;
    server.undo.applying = true;
    defer server.undo.applying = applying;
    if (enabled) {
        self.generation += 1;
        self.saved_camera = server.world.camera;
        self.saved_bounds = server.world.bounds;
        // Capture before changing the camera: currentOutput uses presentation.
        self.assignOutputs(server);
        var it = server.world.toplevels.iterator(.reverse);
        while (it.next()) |top| {
            top.finishMoveAnimation();
            top.finishZoomAnimation();
            top.canvas_state = .{
                .geometry = top.rememberGeometry(),
                .zoom_index = top.zoom_index,
                .layout = top.layout(),
                .fullscreen = top.fullscreen,
                .maximize_restore = top.maximize_restore,
                .tile_restore = top.tile_restore,
                .fullscreen_restore = top.fullscreen_restore,
            };
            if (top.currentOutput()) |output| top.workspace_id = output.workspace_id;
            top.auto_float = false;
            top.auto_float_override = null;
            top.auto_seen = null;
            top.auto_reinsert = null;
            top.auto_anchor = null;
            top.workspace_generation = self.generation;
            top.workspace_order = self.next_order;
            self.next_order += 1;
        }
        self.active = true;
        server.world.camera = .{ .focus_zoom = 1 };
        server.world.snapCamera();
        it = server.world.toplevels.iterator(.reverse);
        while (it.next()) |top| self.mapped(top);
    } else {
        if (server.layout_autosave) |autosave| {
            autosave.saveNow();
            autosave.cancelWorkspaceRestore();
        }
        self.active = false;
        self.tiler.deinit();
        server.world.camera = self.saved_camera;
        server.world.camera.zoom_index = @min(server.world.camera.zoom_index, camera.zoom_levels.len - 1);
        server.world.snapCamera();
        const topology_changed = self.saved_bounds.origin_x != server.world.bounds.origin_x or
            self.saved_bounds.origin_y != server.world.bounds.origin_y or
            self.saved_bounds.width != server.world.bounds.width or self.saved_bounds.height != server.world.bounds.height;
        var it = server.world.toplevels.iterator(.forward);
        while (it.next()) |top| {
            restoreCanvas(top, topology_changed);
        }
        self.slots = @splat(.{});
        var outputs = server.outputs.iterator(.forward);
        while (outputs.next()) |output| output.workspace_id = 0;
    }
    self.tiler.quiet = true;
    self.tiler.schedule(server);
    self.refresh(server);
    focusFallback(server, null);
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| if (top.in_world) top.syncChrome(false, Top.nowMs()) catch {};
    server.world.applyCamera();
    if (server.input.open_control_center) |cc| {
        cc.shortcuts.cancel();
        cc.refresh();
    }
}

fn assignOutputs(self: *Self, server: *Server) void {
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (!output.isLogicallyEnabled() or output.workspace_id != 0) continue;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.exists) continue;
            slot.* = .{ .exists = true, .output = output, .box = output.usableBox() };
            output.workspace_id = @intCast(index + 1);
            break;
        }
    }
}

/// Called after output layout changes and before an Output is freed.
pub fn forgetOutput(self: *Self, output: *Output) void {
    for (&self.slots) |*slot| if (slot.output == output) {
        slot.output = null;
    };
    output.workspace_id = 0;
}

pub fn syncOutputs(self: *Self, server: *Server) void {
    if (!self.active or self.changing) return;
    self.assignOutputs(server);
    var fallback: ?*Output = null;
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| if (output.isLogicallyEnabled()) {
        fallback = output;
        break;
    };
    for (&self.slots, 0..) |*slot, index| {
        if (!slot.exists) continue;
        if (slot.output) |output| if (!output.isLogicallyEnabled()) {
            output.workspace_id = 0;
            slot.output = null;
        };
        const moved = slot.output == null;
        if (moved) slot.output = fallback;
        const output = slot.output orelse continue;
        const box = output.usableBox();
        if (moved or !std.meta.eql(box, slot.box)) {
            if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
            finishTransitions(server);
            var tops = server.world.toplevels.iterator(.forward);
            while (tops.next()) |top| if (top.workspace_id == index + 1) {
                _ = top.moveFromUsableToOutput(slot.box, output);
                fit(top, output);
            };
            slot.box = box;
            self.tiler.quiet = true;
        }
    }
    self.tiler.schedule(server);
    self.refresh(server);
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(server);
    if (focused == null) focusFallback(server, null);
}

pub fn switchTo(self: *Self, server: *Server, id: u8) void {
    if (!self.active or self.changing or id == 0 or id > count or server.locker != null or server.polkit_dialog != null) return;
    cancelGestures(server);
    if (server.layout_autosave) |autosave| autosave.navigation();
    const slot = &self.slots[id - 1];
    const output = slot.output orelse server.getDefaultOutput() orelse return;
    slot.exists = true;
    slot.output = output;
    slot.box = output.usableBox();
    const previous = output.workspace_id;
    output.workspace_id = id;
    // Selecting a workspace on another output focuses that output, never
    // duplicates membership onto the output under the pointer.
    if (Output.atLayout(server, server.input.cursor.x, server.input.cursor.y) != output) {
        _ = server.input.cursor.warp(null, @as(f64, @floatFromInt(slot.box.x)) + @as(f64, @floatFromInt(slot.box.width)) / 2, @as(f64, @floatFromInt(slot.box.y)) + @as(f64, @floatFromInt(slot.box.height)) / 2);
    }
    transition(server, output, previous, id);
    self.refresh(server);
    focusFallback(server, id);
}

/// Slides the workspace `output` showed out and `id`'s in, the higher number
/// arriving from the right (or below), along an axis no other display shares;
/// with displays on both axes, or reduced motion, they cross-fade. Runs before
/// `refresh`, while a frame still says whether its window was shown.
fn transition(server: *Server, output: *Output, previous: u8, id: u8) void {
    if (previous == 0 or previous == id) return;
    const box = output.cached_box;
    const sign: f32 = if (id > previous) 1 else -1;
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (@import("ui").anim.reducedMotion()) {
        // Motion is off; the fade is what remains of the transition.
    } else if (clearOfOutputs(server, output, .{ .x = box.x - box.width, .y = box.y, .width = 3 * box.width, .height = box.height })) {
        dx = sign * @as(f32, @floatFromInt(box.width));
    } else if (clearOfOutputs(server, output, .{ .x = box.x, .y = box.y - box.height, .width = box.width, .height = 3 * box.height })) {
        dy = sign * @as(f32, @floatFromInt(box.height));
    }
    const fade = dx == 0 and dy == 0;
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| {
        if (!top.in_world or top.closing) continue;
        const shown = top.frame_tree.node.enabled;
        if (top.workspace_id == id and @import("window_tabs.zig").visible(top)) {
            // A window moved along with the switch is already in place.
            if (!shown or top.switch_leaving) top.switchIn(dx, dy, fade);
        } else if (top.workspace_id == previous and shown and !top.switch_leaving) {
            top.switchOut(-dx, -dy, fade);
        }
    }
}

/// Whether no output but `output` meets `strip`, the band a slide crosses.
fn clearOfOutputs(server: *Server, output: *Output, strip: wlr.Box) bool {
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |other| {
        if (other == output or !other.isLogicallyEnabled()) continue;
        const b = other.cached_box;
        if (b.x < strip.x + strip.width and strip.x < b.x + b.width and b.y < strip.y + strip.height and strip.y < b.y + b.height) return false;
    }
    return true;
}

/// Ends every workspace switch transition at once.
fn finishTransitions(server: *Server) void {
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| top.finishSwitch();
}

pub fn cycle(self: *Self, server: *Server, forward: bool) void {
    const output = server.getDefaultOutput() orelse return;
    if (!self.active or output.workspace_id == 0) return;
    const current: usize = output.workspace_id - 1;
    for (1..count + 1) |step| {
        const index = if (forward) (current + step) % count else (current + count - step) % count;
        if (self.slots[index].exists) {
            self.switchTo(server, @intCast(index + 1));
            return;
        }
    }
}

fn root(top: *Top) *Top {
    var result = top;
    for (0..32) |_| {
        result = result.parentWindow() orelse return result;
    }
    return result;
}

pub fn moveTo(self: *Self, top: *Top, id: u8) void {
    self.transfer(top, id, true);
}

pub fn placed(self: *Self, top: *Top, output: *Output) void {
    if (self.active and top.workspace_id != output.workspace_id) self.transfer(top, output.workspace_id, false);
}

fn transfer(self: *Self, top: *Top, id: u8, translate: bool) void {
    const server = top.server;
    if (!self.active or id == 0 or id > count or server.locker != null or server.polkit_dialog != null) return;
    const leader = root(top);
    if (leader.workspace_id == id) return;
    var transaction = @import("layout_undo.zig").Transaction.begin(server, &.{ leader.workspace_id, id });
    defer transaction.finish();
    const source = outputFor(leader);
    const slot = &self.slots[id - 1];
    slot.exists = true;
    if (slot.output == null) slot.output = source orelse server.getDefaultOutput();
    const destination = slot.output orelse return;
    slot.box = destination.usableBox();
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |member| {
        const owner = root(member);
        if (owner != leader and (leader.tab_group == 0 or owner.tab_group != leader.tab_group)) continue;
        member.workspace_id = id;
        // Joins beside the destination's focused window, as a new one would.
        member.auto_anchor = slot.focus;
        if (source) |out| {
            if (translate and out != destination) _ = member.moveFromUsableToOutput(out.usableBox(), destination);
        }
        fit(member, destination);
    }
    self.tiler.schedule(server);
    self.switchTo(server, id);
    server.world.focus(top);
}

pub fn focusFallback(server: *Server, workspace: ?u8) void {
    if (server.locker != null or server.polkit_dialog != null) return;
    // Lifecycle and visibility repair are not user navigation. In particular,
    // closing the focused leaf must leave layout undo for surviving members.
    const applying = server.undo.applying;
    server.undo.applying = true;
    defer server.undo.applying = applying;
    if (workspace) |id| if (server.world.workspaces.slots[id - 1].focus) |remembered| {
        if (server.findToplevelById(remembered)) |top| if (top.workspace_id == id and visible(top) and !top.tab_hidden and !top.minimized) {
            server.world.focus(top);
            return;
        };
    };
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| {
        if (!visible(top) or top.tab_hidden or top.minimized) continue;
        if (workspace) |id| if (top.workspace_id != id) continue;
        server.world.focus(top);
        return;
    }
    tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| if (top.activated) top.setActivated(false);
    server.input.seat.keyboardNotifyClearFocus();
}

fn fit(top: *Top, output: *Output) void {
    if (top.fullscreen) {
        top.setFullscreenOn(output);
    } else if (top.maximized) {
        top.setMaximizedOn(output);
    } else if (top.tile) |tile| {
        top.setTiledOn(output, tile);
    } else {
        _ = top.moveFromUsableToOutput(output.usableBox(), output);
    }
    top.finishMoveAnimation();
}

pub fn refresh(self: *Self, server: *Server) void {
    _ = self;
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| {
        if (!visible(top)) {
            top.detachInput();
            top.setActivated(false);
            if (top.backend == .xwayland) top.backend.xwayland.xsurface.restack(null, .below);
        }
        top.applyVisualTransform(Top.nowMs());
        top.syncForeign();
        if (server.ipc) |ipc| @import("ipc/events.zig").onWindowChanged(ipc, top);
    }
    var closing = server.world.closing.iterator(.forward);
    while (closing.next()) |top| if (!visible(top)) top.frame_tree.node.setEnabled(false);
    var nodes = server.world.tree.children.iterator(.forward);
    while (nodes.next()) |node| {
        const data_node = @import("scene_data.zig").SceneData.fromNode(node) orelse continue;
        if (data_node.role == .xwayland_unmanaged) data_node.role.xwayland_unmanaged.syncWorkspaceVisibility();
    }
    server.input.seat.pointerNotifyClearFocus();
    server.refreshTaskbars();
    server.scheduleFrames();
    @import("extra_protocols.zig").syncWorkspaces(server);
}

pub fn data(self: *Self, server: *Server, allocator: std.mem.Allocator) ![]const protocol.WorkspaceData {
    if (!self.active) return &.{.{ .id = 1, .name = "Canvas", .is_focused = true }};
    var list: std.ArrayList(protocol.WorkspaceData) = .empty;
    errdefer list.deinit(allocator);
    const output = server.getDefaultOutput();
    for (self.slots, 0..) |slot, index| {
        if (!slot.exists) continue;
        var flat: std.ArrayList(@import("config").workspace_layout.Node) = .empty;
        if (self.tiler.trees[index].root) |root_node| try @import("workspace_persistence.zig").nodes(allocator, &flat, root_node);
        try list.append(allocator, .{
            .id = index + 1,
            .name = names[index],
            .is_focused = if (output) |out| out.workspace_id == index + 1 else false,
            .is_visible = if (slot.output) |out| out.workspace_id == index + 1 else false,
            .output = if (slot.output) |out| std.mem.span(out.wlr_output.name) else null,
            .automatic = slot.automatic,
            .window_gap = server.config.compositor.windowGap(),
            .nodes = flat.items,
        });
    }
    return list.toOwnedSlice(allocator);
}
pub const names: [count][:0]const u8 = blk: {
    @setEvalBranchQuota(20000);
    var result: [count][:0]const u8 = undefined;
    for (0..count) |i| result[i] = std.fmt.comptimePrint("{d}", .{i + 1});
    break :blk result;
};

fn restoreCanvas(top: *Top, topology_changed: bool) void {
    top.clearAutoTile(top.canvas_state == null);
    top.auto_float = false;
    top.auto_float_override = null;
    top.auto_seen = null;
    top.auto_reinsert = null;
    top.auto_anchor = null;
    if (top.canvas_state) |saved| {
        if (top.fullscreen) top.setFullscreen(false);
        top.leaveLayout();
        top.setZoomOrigin(@min(saved.zoom_index, camera.zoom_levels.len - 1));
        top.restoreGeometry(saved.geometry);
        top.setPosition(saved.geometry.x, saved.geometry.y);
        top.applyLayout(saved.layout);
        if (saved.fullscreen) top.setFullscreen(true);
        top.maximize_restore = saved.maximize_restore;
        top.tile_restore = saved.tile_restore;
        top.fullscreen_restore = saved.fullscreen_restore;
        if (topology_changed) if (top.currentOutput()) |output| fit(top, output);
    } else if (top.currentOutput()) |output| fit(top, output);
    top.canvas_state = null;
    top.workspace_id = 0;
}
