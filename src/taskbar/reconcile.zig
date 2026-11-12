//! Taskbar chips: start logo, icons and reconciling chips with the windows.

const std = @import("std");
const Taskbar = @import("../Taskbar.zig");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const geometry = @import("../geometry.zig");
const icon_service = @import("../icon_service.zig");
const scene_data = @import("../scene_data.zig");
const taskbar_items = @import("config").taskbar_items;
const start_button = @import("../taskbar/start_button.zig");
const ui_theme = @import("ui").theme;
const Output = @import("../Output.zig");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const log = std.log.scoped(.taskbar);
const paint_start = Taskbar.paint_start;
const paint_tray = Taskbar.paint_tray;
const paint_clock = Taskbar.paint_clock;
const paint_capture = Taskbar.paint_capture;
const ChipState = Taskbar.ChipState;
const ChipMemo = Taskbar.ChipMemo;
const chipGap = Taskbar.chipGap;
const tileSize = Taskbar.tileSize;
const startIconSize = Taskbar.startIconSize;
const sharedChipWidth = Taskbar.sharedChipWidth;
const classify = Taskbar.classify;

pub fn refreshStartLogo(bar: *Taskbar) void {
    const size_px = geometry.devicePixels(startIconSize(), bar.wlr_output.scale);
    const custom = ui_theme.global.start_button_icon;
    var lookup = bar.server.iconLookup(if (custom.len > 0) custom else start_button.builtin_logo, size_px);
    if (lookup != .ready and custom.len > 0) {
        lookup = bar.server.iconLookup(start_button.builtin_logo, size_px);
    }
    const old_id: ?u64 = if (bar.start_logo) |icon| icon.id else null;
    updateIcon(bar.server, &bar.start_logo, lookup);
    const new_id: ?u64 = if (bar.start_logo) |icon| icon.id else null;
    if (old_id != new_id) {
        bar.start_dirty = true;
        bar.markDirty(paint_start);
    }
}

// Keeps `IconService`'s refcount in sync with whichever icon `*held` last
// pointed at, mirroring `Toplevel.updateHeldIcon`. `held` is either
// `&bar.start_logo` or a chip's `&state.icon`.
pub fn updateIcon(server: *Server, held: *?icon_service.Entry, lookup: icon_service.Lookup) void {
    const new_icon: ?icon_service.Entry = switch (lookup) {
        .ready => |e| e,
        .pending, .missing => null,
    };
    const old_id: ?u64 = if (held.*) |e| e.id else null;
    const new_id: ?u64 = if (new_icon) |e| e.id else null;
    if (old_id != new_id) {
        if (old_id) |id| server.iconRelease(id);
        if (new_id) |id| server.iconAcquire(id);
    }
    held.* = new_icon;
}

// `world.toplevels` is the focus/raise stack (front = topmost), which
// reorders on every click. Chips must not visually shuffle when a window is
// merely focused or minimized, so we walk a copy sorted by each toplevel's
// stable creation-order `id` instead — the on-screen chip order then only
// changes when a window actually opens or closes.
pub fn taskbarOrderLessThan(_: void, a: *Toplevel, b: *Toplevel) bool {
    return (if (a.tab_group != 0) a.tab_group else a.id) < (if (b.tab_group != 0) b.tab_group else b.id);
}

/// Returns a window's position in the taskbar-owned order, if present.
pub fn chipOrderIndex(order: []const u64, id: u64) ?usize {
    return std.mem.indexOfScalar(u64, order, id);
}

/// Moves an existing chip to another position without changing the relative
/// order of the other chips. Returns false for invalid or unchanged moves.
pub fn moveChipOrder(order: []u64, from: usize, to: usize) bool {
    if (from >= order.len or to >= order.len or from == to) return false;

    const id = order[from];
    if (from < to) {
        var i = from;
        while (i < to) : (i += 1) {
            order[i] = order[i + 1];
        }
    } else {
        var i = from;
        while (i > to) {
            order[i] = order[i - 1];
            i -= 1;
        }
    }
    order[to] = id;
    return true;
}

fn chipOrderLessThan(order: []const u64, a: *Toplevel, b: *Toplevel) bool {
    const a_index = chipOrderIndex(order, a.id) orelse return taskbarOrderLessThan({}, a, b);
    const b_index = chipOrderIndex(order, b.id) orelse return taskbarOrderLessThan({}, a, b);
    return a_index < b_index;
}

// Returns whether any chip needs a frame: a new raster, a FLIP, or removal.
pub fn reconcile(bar: *Taskbar, now_ms: i64) bool {
    var changed = false;
    var visible: std.ArrayList(*Toplevel) = .empty;
    defer visible.deinit(gpa);
    var it = bar.server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (!bar.itemShown(.windows) or !@import("../workspaces.zig").visible(toplevel) or (bar.server.world.workspaces.active and toplevel.currentOutput() != Output.fromWlr(bar.wlr_output)) or toplevel.tab_hidden or (toplevel.live_rules.skip_taskbar orelse false)) continue;
        visible.append(gpa, toplevel) catch break;
    }
    std.mem.sort(*Toplevel, visible.items, {}, taskbarOrderLessThan);

    // Keep order entries for live windows even while they are hidden, on
    // another workspace/output, or temporarily excluded from the taskbar.
    // Only a window that has left the world is removed.
    var order_index: usize = 0;
    while (order_index < bar.chip_order.items.len) {
        const id = bar.chip_order.items[order_index];
        var live = false;
        var world_it = bar.server.world.toplevels.iterator(.forward);
        while (world_it.next()) |toplevel| {
            if (toplevel.id == id) {
                live = true;
                break;
            }
        }
        if (live) {
            order_index += 1;
        } else {
            _ = bar.chip_order.orderedRemove(order_index);
        }
    }

    // Seed new windows in the existing stable order. Once a window has an
    // entry, later focus changes and reconciliation cannot move it.
    var custom_order_ready = true;
    bar.chip_order.ensureTotalCapacity(gpa, bar.chip_order.items.len + visible.items.len) catch {
        log.err("reconcile: could not reserve taskbar order", .{});
        custom_order_ready = false;
    };
    if (custom_order_ready) {
        for (visible.items) |toplevel| {
            if (chipOrderIndex(bar.chip_order.items, toplevel.id) == null) {
                bar.chip_order.appendAssumeCapacity(toplevel.id);
            }
        }
        std.mem.sort(*Toplevel, visible.items, bar.chip_order.items, chipOrderLessThan);
    }

    const layout = bar.calculateLayout(visible.items.len);
    if (!std.meta.eql(layout, bar.item_layout)) {
        bar.item_layout = layout;
        bar.start_dirty = true;
        bar.clock_dirty = true;
        bar.tray_dirty = @splat(true);
        bar.battery_dirty = true;
        bar.capture_dirty = true;
        bar.app_tray_generation = 0;
        bar.markDirty(paint_start | paint_clock | paint_tray | paint_capture);
        changed = true;
    }
    const chip_w = sharedChipWidth(bar, visible.items.len);
    var next: std.ArrayList(ChipState) = .empty;
    var x: f32 = bar.item_layout.x[@intFromEnum(taskbar_items.Item.windows)] orelse 0;
    for (visible.items) |toplevel| {
        const new_target = x;
        var state: ChipState = found: {
            for (bar.chips.items, 0..) |chip, i| {
                if (chip.toplevel == toplevel) break :found bar.chips.orderedRemove(i);
            }
            break :found .{ .toplevel = toplevel, .target_x = new_target };
        };
        if (state.buffer_node == null) {
            const node = bar.tree.createSceneBuffer(null) catch |err| {
                log.err("reconcile: could not create chip buffer: {}", .{err});
                break;
            };
            node.setFilterMode(.bilinear);
            scene_data.SceneData.attach(&bar.node_data, &node.node);
            // Chips are created after the fixed tray/clock nodes, but their
            // original painter order was below those controls.
            node.node.placeBelow(&bar.clock_node.node);
            state.buffer_node = node;
        }
        const old_render = state.renderX(now_ms);
        state.kind = classify(toplevel);
        const app_id = toplevel.appId();
        updateIcon(bar.server, &state.icon, bar.server.iconLookup(app_id, geometry.devicePixels(tileSize(), bar.wlr_output.scale)));
        state.target_x = new_target;
        // Fixed width shared by every chip: it must not change when the
        // window's title changes, only when the width setting, available
        // space or number of open windows changes `chip_w` itself.
        state.width = chip_w;
        const delta = old_render - new_target;
        if (@abs(delta) >= 0.5) {
            // FLIP: the chip already occupies `delta` px away from its new
            // slot; ease that offset back to zero instead of jumping.
            state.flip = .initCurve(delta, 0, now_ms, anim.curveFor(.taskbar_flip));
            changed = true;
        }
        if (!state.dirty) {
            if (state.painted) |painted| {
                state.dirty = !std.meta.eql(painted, ChipMemo.capture(bar, &state, now_ms));
            } else state.dirty = true;
        }
        if (state.dirty) changed = true;
        next.append(gpa, state) catch break;
        x += state.width + @as(f32, @floatFromInt(chipGap()));
    }
    // Whatever is left belongs to windows that closed or left the taskbar.
    if (bar.chips.items.len > 0) changed = true;
    for (bar.chips.items) |chip| {
        if (chip.buffer_node) |node| node.node.destroy();
        if (chip.raster) |raster| raster.base.drop();
        if (chip.icon) |e| bar.server.iconRelease(e.id);
    }
    bar.chips.deinit(gpa);
    bar.chips = next;

    if (bar.hover_target == .chip) {
        var still_present = false;
        for (bar.chips.items) |chip| {
            if (chip.toplevel == bar.hover_target.chip) {
                still_present = true;
                break;
            }
        }
        if (!still_present) bar.hover_target = .none;
    }
    return changed;
}
