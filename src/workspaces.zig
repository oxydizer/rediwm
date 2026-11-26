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
pub const Layout = @import("config").workspace_layout.Layout;
pub const DesktopMode = @import("config").loader.DesktopMode;
pub const Memory = @import("workspace_memory.zig").Memory;
pub const Disconnected = struct {
    name_buf: [128]u8,
    len: u8,
    shown: bool,

    pub fn init(connector: []const u8, shown: bool) ?Disconnected {
        if (connector.len == 0 or connector.len > 128) return null;
        var result = Disconnected{ .name_buf = undefined, .len = @intCast(connector.len), .shown = shown };
        @memcpy(result.name_buf[0..connector.len], connector);
        return result;
    }

    pub fn name(self: *const Disconnected) []const u8 {
        return self.name_buf[0..self.len];
    }
};
pub const Workspace = struct {
    /// The workspace's own layout; null follows the desktop mode (`layoutOf`).
    layout: ?Layout = null,
    exists: bool = false,
    output: ?*Output = null,
    displaced: ?Disconnected = null,
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    focus: ?u64 = null,
};
tiler: @import("auto_tiling.zig").Manager = .{},
active: bool = false,
/// Canvas, or the tiled mode in use, which sets each workspace's default layout.
mode: DesktopMode = .canvas,
/// The tiled mode `toggle_desktop_mode` returns to from Canvas.
last_tiled: DesktopMode = .workspaces,
/// What the last tiled mode left behind while Canvas is on.
memory: ?Memory = null,
changing: bool = false,
slots: [count]Workspace = @splat(.{}),
saved_camera: camera.Camera = .{},
saved_bounds: camera.Bounds = .{},
next_order: u64 = 1,
generation: u64 = 0,

pub fn deinit(self: *Self) void {
    self.tiler.deinit();
    if (self.memory) |*memory| memory.deinit();
    self.memory = null;
}

/// The layout a workspace uses when it has no choice of its own.
pub fn defaultLayout(self: *const Self) Layout {
    return if (self.mode == .scrolling) .scrolling else .split;
}

pub fn layoutOf(self: *const Self, id: u8) Layout {
    if (id == 0 or id > count) return .floating;
    return self.slots[id - 1].layout orelse self.defaultLayout();
}

/// Whether workspace `id` tiles its windows, as split tiles or a strip.
pub fn tiles(self: *const Self, id: u8) bool {
    return self.layoutOf(id) != .floating;
}

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

/// The workspace a connector shows when all displaced workspaces are home.
pub fn nativeSelection(output: *const Output) u8 {
    return if (output.borrowed_from_workspace != 0) output.borrowed_from_workspace else output.workspace_id;
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
    if (!self.active or top.workspace_id == 0) return;
    const slot = &self.slots[top.workspace_id - 1];
    if (slot.focus == top.id) return;
    slot.focus = top.id;
    if (top.server.layout_autosave) |autosave| autosave.changed();
}

/// Shows `top`: its workspace, and on a strip its column.
pub fn reveal(self: *Self, top: *Top) void {
    if (!self.active or self.changing) return;
    if (!visible(top) or top.server.getDefaultOutput() != outputFor(top)) self.switchTo(top.server, top.workspace_id);
    @import("scroll_tiling.zig").reveal(top);
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

/// Switches between Canvas and the tiled modes. Workspaces and Scrolling share
/// the workspaces and differ only in their default layout, so moving between
/// them just reflows; leaving for Canvas keeps the tiled layout in `memory`.
pub fn setMode(self: *Self, server: *Server, mode: DesktopMode) void {
    if (self.changing or server.greeter_mode) return;
    if (self.mode == mode and self.active == mode.tiled()) return;
    if (self.active and mode.tiled()) {
        if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
        self.mode = mode;
        self.last_tiled = mode;
        self.tiler.schedule(server);
        announceMode(server);
        return;
    }
    self.changing = true;
    defer self.changing = false;
    cancelGestures(server);
    finishTransitions(server);
    server.undo.clear();
    const applying = server.undo.applying;
    server.undo.applying = true;
    defer server.undo.applying = applying;
    if (mode.tiled()) self.enter(server, mode) else self.leave(server);
    self.tiler.quiet = true;
    self.tiler.schedule(server);
    self.refresh(server);
    const output = server.getDefaultOutput();
    focusFallback(server, if (self.active and output != null) output.?.workspace_id else null);
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| if (top.in_world) top.syncChrome(false, Top.nowMs()) catch {};
    server.world.applyCamera();
    announceMode(server);
}

fn enter(self: *Self, server: *Server, mode: DesktopMode) void {
    self.generation += 1;
    self.saved_camera = server.world.camera;
    self.saved_bounds = server.world.bounds;
    var memory = self.memory;
    self.memory = null;
    defer if (memory) |*m| m.deinit();
    // Capture before changing the camera: currentOutput uses presentation.
    if (memory) |*m| m.restoreSlots(server);
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
    if (memory) |*m| m.restoreWindows(server);
    self.active = true;
    self.mode = mode;
    self.last_tiled = mode;
    server.world.camera = .{ .focus_zoom = 1 };
    server.world.snapCamera();
    if (memory) |*m| m.restoreFloating(server);
    it = server.world.toplevels.iterator(.reverse);
    while (it.next()) |top| self.mapped(top);
    if (memory) |*m| m.restoreDialogs(server);
    if (server.layout_autosave) |autosave| autosave.entered();
}

fn leave(self: *Self, server: *Server) void {
    if (server.layout_autosave) |autosave| {
        autosave.saveNow();
        autosave.cancelWorkspaceRestore();
    }
    self.tiler.flushNow(server);
    if (self.memory) |*memory| memory.deinit();
    self.memory = Memory.capture(server) catch |err| blk: {
        std.log.warn("workspace memory: {s}", .{@errorName(err)});
        break :blk null;
    };
    self.active = false;
    self.mode = .canvas;
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
    if (server.xwayland) |xw| {
        xw.pointer_queue.reset(xw);
        xw.preferWorkspace(0);
    }
    self.slots = @splat(.{});
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        output.workspace_id = 0;
        output.borrowed_from_workspace = 0;
    }
}

/// Taskbar icons, the mode menu and Settings show the mode.
fn announceMode(server: *Server) void {
    var bars = server.outputs.iterator(.forward);
    while (bars.next()) |output| if (output.taskbar) |bar| bar.applyDesktopMode();
    server.input.window_menu.desktopModeChanged();
    if (server.input.open_control_center) |cc| {
        cc.shortcuts.cancel();
        cc.refresh();
    }
}

fn assignOutputs(self: *Self, server: *Server) void {
    // A slot may have borrowed another display while its connector was gone.
    // Release its borrowed selection before either output chooses a workspace.
    for (&self.slots, 1..) |*slot, id| {
        const home = slot.displaced orelse continue;
        const output = server.findOutputByName(home.name()) orelse continue;
        if (!output.isLogicallyEnabled()) continue;
        if (slot.output) |old| if (old.workspace_id == id) {
            old.workspace_id = 0;
        };
        slot.output = output;
        slot.displaced = null;
        if (home.shown) {
            output.workspace_id = @intCast(id);
            output.borrowed_from_workspace = 0;
        }
    }
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (!output.isLogicallyEnabled() or output.workspace_id != 0) continue;
        const previous = output.borrowed_from_workspace;
        output.borrowed_from_workspace = 0;
        if (previous != 0 and self.slots[previous - 1].output == output and self.slots[previous - 1].displaced == null) {
            output.workspace_id = previous;
            continue;
        }
        for (self.slots, 1..) |slot, id| {
            if (slot.output != output or slot.displaced != null) continue;
            output.workspace_id = @intCast(id);
            break;
        }
        if (output.workspace_id != 0) continue;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.exists) continue;
            slot.* = .{ .exists = true, .output = output, .box = output.usableBox() };
            output.workspace_id = @intCast(index + 1);
            break;
        }
        if (output.workspace_id != 0) continue;
        // All slots exist. Show a hidden workspace, retaining any connector
        // it is waiting for. Keep each other display's selection intact.
        for (&self.slots, 1..) |*slot, id| {
            if (slot.output) |old| if (old.workspace_id == id or old.borrowed_from_workspace == id) continue;
            slot.output = output;
            output.workspace_id = @intCast(id);
            break;
        }
    }
}

/// Called after output layout changes and before an Output is freed.
pub fn forgetOutput(self: *Self, output: *Output) void {
    for (&self.slots, 1..) |*slot, id| if (slot.output == output) {
        if (slot.displaced == null) slot.displaced = Disconnected.init(std.mem.span(output.wlr_output.name), nativeSelection(output) == id);
        slot.output = null;
    };
    if (self.memory) |*memory| memory.forgetOutput(output);
    output.workspace_id = 0;
    output.borrowed_from_workspace = 0;
}

pub fn syncOutputs(self: *Self, server: *Server) void {
    if (!self.active or self.changing) return;
    var fallback: ?*Output = null;
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (!output.isLogicallyEnabled()) {
            self.forgetOutput(output);
        } else if (fallback == null) fallback = output;
    }
    self.assignOutputs(server);
    for (&self.slots, 0..) |*slot, index| {
        if (!slot.exists) continue;
        const moved = slot.output == null;
        if (moved) slot.output = fallback;
        const output = slot.output orelse continue;
        const box = output.usableBox();
        if (moved or !std.meta.eql(box, slot.box)) {
            if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
            finishTransitions(server);
            var tops = server.world.toplevels.iterator(.forward);
            while (tops.next()) |top| if (top.workspace_id == index + 1) {
                // Reflow translates each strip member and carries its dialogs.
                // Independently fitting either would clamp away their offset.
                if (@import("scroll_tiling.zig").memberOf(top) != null and !top.fullscreen and !top.maximized) continue;
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
    if (slot.displaced == null) {
        output.borrowed_from_workspace = 0;
    } else if (previous != 0 and self.slots[previous - 1].displaced == null) {
        output.borrowed_from_workspace = previous;
    }
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

/// The higher-numbered workspace arrives from the right. Its output clips the
/// slide at the monitor edge. Reduced motion keeps the cross-fade.
fn transition(server: *Server, output: *Output, previous: u8, id: u8) void {
    if (previous == 0 or previous == id) return;
    const sign: f32 = if (id > previous) 1 else -1;
    const fade = @import("ui").anim.reducedMotion();
    const dx = if (fade) 0 else sign * @as(f32, @floatFromInt(output.cached_box.width));
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| {
        if (!top.in_world or top.closing) continue;
        const shown = top.frame_tree.node.enabled;
        if (top.workspace_id == id and @import("window_tabs.zig").visible(top)) {
            // A window moved along with the switch is already in place.
            if (!shown or top.switch_leaving) top.switchIn(dx, 0, fade);
        } else if (top.workspace_id == previous and shown and !top.switch_leaving) {
            top.switchOut(-dx, 0, fade);
        }
    }
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
    const carry_strip = self.layoutOf(id) == .scrolling and @import("scroll_tiling.zig").isMember(leader);
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |member| {
        const owner = root(member);
        if (owner != leader and (leader.tab_group == 0 or owner.tab_group != leader.tab_group)) continue;
        member.workspace_id = id;
        // Joins beside the destination's focused window, as a new one would.
        member.auto_anchor = slot.focus;
        if (carry_strip and !member.maximized and !member.fullscreen) continue;
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
    // `window_tabs.visible` also rules out a dialog hidden with its minimized
    // owner: focusing it would restore the owner.
    if (workspace) |id| if (id != 0) if (server.world.workspaces.slots[id - 1].focus) |remembered| {
        if (server.findToplevelById(remembered)) |top| if (top.workspace_id == id and @import("window_tabs.zig").visible(top)) {
            server.world.focus(top);
            return;
        };
    };
    var tops = server.world.toplevels.iterator(.forward);
    while (tops.next()) |top| {
        if (!@import("window_tabs.zig").visible(top)) continue;
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
            .automatic = self.tiles(@intCast(index + 1)),
            .layout = @tagName(self.layoutOf(@intCast(index + 1))),
            .window_gap = server.config.compositor.windowGap(),
            .nodes = flat.items,
            .columns = try @import("workspace_persistence.zig").columns(allocator, &self.tiler.strips[index]),
            .view = self.tiler.strips[index].view,
            .direction = if (self.layoutOf(@intCast(index + 1)) == .scrolling) @tagName(self.tiler.strips[index].direction) else null,
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
