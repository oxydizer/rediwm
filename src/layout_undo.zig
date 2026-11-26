//! Compositor bridge for owned workspace undo snapshots. Trees retain stable
//! identities; apply reconciles against current clients, constraints and outputs.
const std = @import("std");
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const workspaces = @import("workspaces.zig");
const tiling = @import("auto_tiling.zig");
const undo = @import("undo.zig");
const gpa = @import("main.zig").gpa;
pub const Snapshot = undo.LayoutSnapshot;

pub fn capture(server: *Server, ids: []const u8) ?*Snapshot {
    if (server.undo.applying or !server.world.workspaces.active) return null;
    if (server.undo.pending) |pending| if (pending.snapshot != null) return null;
    server.world.workspaces.tiler.flushNow(server);
    return captureOwned(server, ids) catch |err| {
        // An operation without a snapshot must not leave older geometry undo.
        server.undo.clear();
        std.log.warn("layout undo snapshot: {s}", .{@errorName(err)});
        return null;
    };
}

fn captureOwned(server: *Server, ids: []const u8) !*Snapshot {
    const snapshot = try gpa.create(Snapshot);
    snapshot.* = .{ .allocator = gpa, .generation = server.world.workspaces.generation };
    errdefer snapshot.destroy();
    if (@import("ipc/handlers.zig").findFocusedToplevel(server)) |top| snapshot.focus = top.id;
    // A pointer press can focus before the grab starts. Fold that focus into
    // the layout operation, just as the existing floating gesture undo does.
    if (server.undo.slot) |previous| {
        if (previous.kind == .focus and previous.press_seq == server.undo.press_seq) snapshot.focus = previous.focus;
    }
    var affected: [workspaces.count]bool = @splat(false);
    for (ids) |id| {
        if (id == 0 or id > workspaces.count or affected[id - 1]) continue;
        affected[id - 1] = true;
        const slot = &server.world.workspaces.slots[id - 1];
        var tree = try server.world.workspaces.tiler.trees[id - 1].clone(gpa);
        errdefer tree.deinit(gpa);
        var strip = try server.world.workspaces.tiler.strips[id - 1].clone(gpa);
        errdefer strip.deinit(gpa);
        try snapshot.workspaces.append(gpa, .{ .id = id, .layout = slot.layout, .tree = tree, .strip = strip });
    }
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.workspace_id == 0 or !affected[top.workspace_id - 1]) continue;
        try snapshot.windows.append(gpa, .{
            .id = top.id,
            .order = top.workspace_order,
            .key = tiling.key(top),
            .workspace = top.workspace_id,
            .floating = top.auto_float,
            .floating_override = top.auto_float_override,
            .geometry = geometry(top),
            .layout = top.layout(),
            .auto_restore = top.auto_restore,
            .tile_restore = top.tile_restore,
            .reinsert = top.auto_reinsert,
        });
    }
    return snapshot;
}

fn geometry(top: *Top) undo.Geometry {
    return top.pending_restore orelse top.forcedGeometry() orelse top.rememberGeometry();
}

/// A floating move can cross outputs only at release. Add the destination's
/// pre-transfer layout then, retaining the source snapshot from pointer press.
pub fn includeDestination(server: *Server, id: u8) void {
    const pending = server.undo.pending orelse return;
    const snapshot = pending.snapshot orelse return;
    for (snapshot.workspaces.items) |workspace| if (workspace.id == id) return;
    includeOwned(server, snapshot, id) catch |err| {
        std.log.warn("layout undo destination: {s}", .{@errorName(err)});
        server.undo.clear();
    };
}

fn includeOwned(server: *Server, snapshot: *Snapshot, id: u8) !void {
    const extra = try captureOwned(server, &.{id});
    defer extra.destroy();
    try snapshot.workspaces.ensureUnusedCapacity(gpa, extra.workspaces.items.len);
    try snapshot.windows.ensureUnusedCapacity(gpa, extra.windows.items.len);
    for (extra.workspaces.items) |*workspace| {
        snapshot.workspaces.appendAssumeCapacity(workspace.*);
        workspace.tree = .{};
        workspace.strip = .{};
    }
    snapshot.windows.appendSliceAssumeCapacity(extra.windows.items);
}

pub fn beginGesture(server: *Server, id: u8) bool {
    if (!server.world.workspaces.active) return false;
    // On allocation failure, keep workspace gestures out of the legacy
    // single-window path, which cannot restore a changed group layout.
    const snapshot = capture(server, &.{id}) orelse return true;
    server.undo.begin(.{ .kind = .workspace_layout, .press_seq = server.undo.press_seq, .at_ms = 0, .focus = snapshot.focus, .snapshot = snapshot });
    return true;
}

pub const Resize = struct { id: u64, width: i32, height: i32 };

pub fn commitGesture(server: *Server, resized: ?Resize) bool {
    const pending = server.undo.pending orelse return false;
    const snapshot = pending.snapshot orelse return false;
    server.undo.pending = null;
    recordWithResize(server, snapshot, resized);
    return true;
}

fn find(server: *Server, saved: Snapshot.Window) ?*Top {
    if (server.findToplevelById(saved.id)) |top| return top;
    // Placeholder replacement hands its insertion identity to the real client.
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.workspace_order == saved.order) return top;
    return null;
}

pub fn replaced(server: *Server, old: u64, new: u64) void {
    const entries = [_]?*undo.Change{
        if (server.undo.slot) |*entry| entry else null,
        if (server.undo.pending) |*entry| entry else null,
    };
    for (entries) |maybe_entry| {
        const entry = maybe_entry orelse continue;
        const snapshot = entry.snapshot orelse continue;
        if (entry.focus == old) entry.focus = new;
        if (snapshot.focus == old) snapshot.focus = new;
        for (snapshot.windows.items) |*window| if (window.id == old) {
            window.id = new;
        };
    }
}

fn changed(server: *Server, snapshot: *Snapshot) bool {
    for (snapshot.workspaces.items) |*saved| {
        const slot = &server.world.workspaces.slots[saved.id - 1];
        if (!std.meta.eql(slot.layout, saved.layout) or !saved.tree.eql(&server.world.workspaces.tiler.trees[saved.id - 1])) return true;
        if (!saved.strip.eql(&server.world.workspaces.tiler.strips[saved.id - 1])) return true;
    }
    for (snapshot.windows.items) |saved| {
        const top = find(server, saved) orelse continue;
        if (top.workspace_id != saved.workspace or top.auto_float != saved.floating or top.auto_float_override != saved.floating_override or !top.layout().eql(saved.layout)) return true;
        if (saved.layout == .floating and !top.minimized and !top.fullscreen and !std.meta.eql(geometry(top), saved.geometry)) return true;
    }
    return false;
}

/// Takes ownership. No-op gestures leave the previous undo entry intact.
pub fn record(server: *Server, snapshot: ?*Snapshot) void {
    recordWithResize(server, snapshot, null);
}

fn recordWithResize(server: *Server, snapshot: ?*Snapshot, resized: ?Resize) void {
    const saved = snapshot orelse return;
    // Configure replies may arrive after release. Compare the requested final
    // client size rather than discarding a real resize against its old buffer.
    const size_changed = blk: {
        const size = resized orelse break :blk false;
        for (saved.windows.items) |window| if (window.id == size.id) {
            break :blk window.geometry.width != size.width or window.geometry.height != size.height;
        };
        break :blk false;
    };
    if (!server.world.workspaces.active or saved.generation != server.world.workspaces.generation or (!size_changed and !changed(server, saved))) {
        saved.destroy();
        return;
    }
    const now = Server.undoNowMs();
    if (server.layout_autosave) |autosave| for (saved.workspaces.items) |workspace| autosave.touch(&.{workspace.id});
    server.undo.record(.{ .kind = .workspace_layout, .press_seq = server.undo.press_seq, .at_ms = now, .focus = saved.focus, .snapshot = saved }, now);
}

/// Suppress nested single-window/focus entries until the operation has finished.
pub const Transaction = struct {
    server: *Server,
    snapshot: ?*Snapshot,
    applying: bool,
    resized: ?Resize = null,

    pub fn begin(server: *Server, ids: []const u8) Transaction {
        const snapshot = capture(server, ids);
        const applying = server.undo.applying;
        server.undo.applying = true;
        return .{ .server = server, .snapshot = snapshot, .applying = applying };
    }
    pub fn finish(self: *Transaction) void {
        self.server.undo.applying = self.applying;
        recordWithResize(self.server, self.snapshot, self.resized);
        self.snapshot = null;
    }
};

/// Takes the trees out of the snapshot. No saved pointer is ever dereferenced;
/// absent clients disappear in reflow and new clients keep their insertion order.
pub fn apply(server: *Server, snapshot: *Snapshot) void {
    const manager = &server.world.workspaces;
    if (!manager.active or manager.generation != snapshot.generation) return;
    workspaces.cancelGestures(server);
    for (snapshot.workspaces.items) |*saved| {
        const slot = &manager.slots[saved.id - 1];
        slot.layout = saved.layout;
        for (snapshot.windows.items) |window| {
            if (window.workspace != saved.id) continue;
            if (find(server, window)) |top| {
                saved.tree.rename(window.key, tiling.key(top));
                saved.strip.rename(window.key, tiling.key(top));
            }
        }
        const tree = &manager.tiler.trees[saved.id - 1];
        tree.deinit(gpa);
        tree.* = saved.tree;
        saved.tree = .{};
        // Scrolling is navigation, not an edit: the view stays where it is.
        const strip = &manager.tiler.strips[saved.id - 1];
        const view = strip.view;
        strip.deinit(gpa);
        strip.* = saved.strip;
        strip.view = view;
        saved.strip = .{};
    }
    for (snapshot.windows.items) |saved| {
        const top = find(server, saved) orelse continue;
        top.finishMoveAnimation();
        top.clearAutoTile(false);
        top.workspace_id = saved.workspace;
        top.auto_float = saved.floating;
        top.auto_float_override = saved.floating_override;
        top.auto_restore = saved.auto_restore;
        top.auto_reinsert = saved.reinsert;
        top.auto_seen = null;
        // Forced layouts still belong to the workspace's current output after
        // undoing a transfer or after output migration.
        if (workspaces.outputFor(top)) |output| {
            if (top.fullscreen) top.setFullscreenOn(output) else if (top.maximized) top.setMaximizedOn(output);
        }
        // Lifecycle overrides remain live: undo does not unminimize or leave
        // fullscreen/maximize merely because another tile was rearranged.
        if (!top.minimized and !top.fullscreen and !top.maximized and saved.layout != .maximized) {
            if (saved.layout == .tiled) {
                if (workspaces.outputFor(top)) |output| top.setTiledOn(output, saved.layout.tiled);
            } else top.applyLayout(saved.layout);
            top.auto_float = saved.floating;
            top.auto_float_override = saved.floating_override; // leaveLayout opts out internally
            top.auto_restore = saved.auto_restore;
            if (saved.layout == .floating) {
                var floating = saved.geometry;
                const limits = top.sizeConstraints();
                floating.width = @max(floating.width, @max(1, limits.min_width));
                floating.height = @max(floating.height, @max(1, limits.min_height));
                if (limits.max_width > 0) floating.width = @min(floating.width, limits.max_width);
                if (limits.max_height > 0) floating.height = @min(floating.height, limits.max_height);
                top.restoreGeometryNow(floating);
            }
        }
        top.tile_restore = saved.tile_restore;
    }
    // Tabs or dialogs opened after capture follow their surviving group/owner.
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (top.parentWindow()) |owner| top.workspace_id = owner.workspace_id;
        if (top.tab_group == 0) continue;
        for (snapshot.windows.items) |saved| {
            const member = find(server, saved) orelse continue;
            if (member.tab_group == top.tab_group) {
                top.workspace_id = member.workspace_id;
                top.auto_float = member.auto_float;
                top.auto_float_override = member.auto_float_override;
                break;
            }
        }
    }
    manager.tiler.flushNow(server);
    manager.refresh(server);
    if (server.input.open_control_center) |cc| cc.refresh();
    if (snapshot.focus) |id| if (server.findToplevelById(id)) |top| {
        if (!top.minimized and !top.tab_hidden) {
            manager.reveal(top);
            server.world.focus(top);
            return;
        }
    };
    workspaces.focusFallback(server, null);
}
