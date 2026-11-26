//! What a tiled mode leaves behind when the desktop switches to Canvas. Canvas
//! keeps it for the rest of the session, and the next tiled mode puts it back by
//! window id: the workspaces with their layouts, outputs and focus, the split
//! trees, and where floating windows stood. Windows opened in the meantime join
//! as new ones; closed ones drop out at the next reflow. Across restarts the
//! saved layout does the same (`workspace_persistence.zig`).
const std = @import("std");
const Server = @import("Server.zig");
const Top = @import("Toplevel.zig");
const Output = @import("Output.zig");
const workspaces = @import("workspaces.zig");
const layout = @import("auto_layout.zig");
const tiling = @import("auto_tiling.zig");
const scroll = @import("scroll_layout.zig");
const gpa = @import("main.zig").gpa;

pub const Memory = struct {
    slots: [workspaces.count]Slot = @splat(.{}),
    trees: [workspaces.count]layout.Tree = @splat(.{}),
    strips: [workspaces.count]scroll.Strip = @splat(.{}),
    windows: std.ArrayList(Window) = .empty,

    const Slot = struct {
        exists: bool = false,
        layout: ?workspaces.Layout = null,
        output: ?*Output = null,
        displaced: ?workspaces.Disconnected = null,
        shown: bool = false,
        native_selection: bool = false,
        focus: ?u64 = null,
    };
    const Window = struct {
        id: u64,
        workspace: u8,
        order: u64,
        key: layout.Key,
        floating: bool,
        floating_override: ?bool,
        reinsert: ?layout.Placement,
        auto_restore: ?Top.RestoreGeometry,
        /// Where a floating window stood; tiles take theirs from the tree.
        geometry: ?Top.RestoreGeometry,
        dialog_offset: ?struct { owner: u64, x: i32, y: i32 },
    };

    /// Takes the split trees and strips out of the tiler, which the caller is
    /// leaving.
    pub fn capture(server: *Server) !Memory {
        const manager = &server.world.workspaces;
        var memory: Memory = .{};
        errdefer memory.deinit();
        var it = server.world.toplevels.iterator(.forward);
        while (it.next()) |top| {
            if (top.workspace_id == 0 or top.backend == .placeholder) continue;
            const floating = top.auto_target == null and !top.fullscreen and top.layout() == .floating;
            const owner = if (floating) @import("scroll_tiling.zig").memberOf(top) else null;
            try memory.windows.append(gpa, .{
                .id = top.id,
                .workspace = top.workspace_id,
                .order = top.workspace_order,
                .key = tiling.key(top),
                .floating = top.auto_float,
                .floating_override = top.auto_float_override,
                .reinsert = top.auto_reinsert,
                .auto_restore = top.auto_restore,
                .geometry = if (floating) top.rememberGeometry() else null,
                .dialog_offset = if (owner) |o| .{ .owner = o.id, .x = top.x - o.x, .y = top.y - o.y } else null,
            });
        }
        for (manager.slots, 0..) |slot, index| {
            memory.slots[index] = .{
                .exists = slot.exists,
                .layout = slot.layout,
                .output = slot.output,
                .displaced = slot.displaced,
                .shown = if (slot.output) |output| output.workspace_id == index + 1 else false,
                .native_selection = if (slot.output) |output| workspaces.nativeSelection(output) == index + 1 else false,
                .focus = slot.focus,
            };
            memory.trees[index] = manager.tiler.trees[index];
            manager.tiler.trees[index] = .{};
            memory.strips[index] = manager.tiler.strips[index];
            manager.tiler.strips[index] = .{};
        }
        return memory;
    }

    pub fn deinit(memory: *Memory) void {
        for (&memory.trees) |*tree| tree.deinit(gpa);
        for (&memory.strips) |*strip| strip.deinit(gpa);
        memory.windows.deinit(gpa);
    }

    pub fn forgetOutput(memory: *Memory, output: *Output) void {
        for (&memory.slots) |*slot| if (slot.output == output) {
            if (slot.displaced == null) slot.displaced = workspaces.Disconnected.init(std.mem.span(output.wlr_output.name), slot.native_selection);
            slot.output = null;
            slot.shown = false;
        };
    }

    /// Before outputs get workspaces: each output shows what it showed.
    pub fn restoreSlots(memory: *Memory, server: *Server) void {
        const manager = &server.world.workspaces;
        for (memory.slots, 0..) |saved, index| {
            if (!saved.exists) continue;
            const live = if (saved.output) |output| (if (output.isLogicallyEnabled()) output else null) else null;
            const output = live orelse server.getDefaultOutput();
            const displaced = saved.displaced orelse if (live == null and saved.output != null)
                workspaces.Disconnected.init(std.mem.span(saved.output.?.wlr_output.name), saved.native_selection)
            else
                null;
            manager.slots[index] = .{
                .exists = true,
                .layout = saved.layout,
                .output = output,
                .displaced = displaced,
                .box = if (output) |out| out.usableBox() else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .focus = saved.focus,
            };
            if (saved.shown) if (live) |out| if (out.workspace_id == 0) {
                out.workspace_id = @intCast(index + 1);
            };
            if (!saved.shown and saved.native_selection) if (live) |out| {
                out.borrowed_from_workspace = @intCast(index + 1);
            };
        }
    }

    /// After every window has a fresh membership: remembered ones get theirs
    /// back, and the trees return under the windows' current keys.
    pub fn restoreWindows(memory: *Memory, server: *Server) void {
        const manager = &server.world.workspaces;
        for (memory.windows.items) |saved| {
            const top = server.findToplevelById(saved.id) orelse continue;
            if (!manager.slots[saved.workspace - 1].exists) continue;
            top.workspace_id = saved.workspace;
            top.workspace_order = saved.order;
            top.auto_float = saved.floating;
            top.auto_float_override = saved.floating_override;
            top.auto_reinsert = saved.reinsert;
            if (top.auto_target == null) top.auto_restore = saved.auto_restore;
            // Tabs grouped or split up on the canvas keep their tile.
            const key = tiling.key(top);
            if (!std.meta.eql(key, saved.key)) {
                memory.trees[saved.workspace - 1].rename(saved.key, key);
                memory.strips[saved.workspace - 1].rename(saved.key, key);
            }
        }
        for (&manager.tiler.trees, &memory.trees) |*tree, *saved| {
            tree.deinit(gpa);
            tree.* = saved.*;
            saved.* = .{};
        }
        for (&manager.tiler.strips, &memory.strips) |*strip, *saved| {
            strip.deinit(gpa);
            strip.* = saved.*;
            saved.* = .{};
        }
        for (&manager.slots) |*slot| if (slot.focus) |id| {
            if (server.findToplevelById(id) == null) slot.focus = null;
        };
    }

    /// Once the camera is pinned, floating windows go back where they stood.
    pub fn restoreFloating(memory: *Memory, server: *Server) void {
        for (memory.windows.items) |saved| {
            const geometry = saved.geometry orelse continue;
            const top = server.findToplevelById(saved.id) orelse continue;
            if (top.workspace_id != saved.workspace or top.fullscreen or top.layout() != .floating) continue;
            top.restoreGeometryNow(geometry);
        }
    }

    /// Ordinary map placement clamps each window separately to its output.
    /// Reattach dialogs to their column after that pass, so the first strip
    /// reflow carries both windows by the same distance.
    pub fn restoreDialogs(memory: *Memory, server: *Server) void {
        for (memory.windows.items) |saved| {
            const offset = saved.dialog_offset orelse continue;
            const top = server.findToplevelById(saved.id) orelse continue;
            if (top.fullscreen or top.layout() != .floating or server.world.workspaces.layoutOf(top.workspace_id) != .scrolling) continue;
            var ancestor = top.parentWindow();
            for (0..32) |_| {
                const owner = ancestor orelse break;
                if (owner.id == offset.owner) {
                    top.setPosition(owner.x + offset.x, owner.y + offset.y);
                    break;
                }
                ancestor = owner.parentWindow();
            }
        }
    }
};
