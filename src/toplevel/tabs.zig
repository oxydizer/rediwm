//! Toplevel tab strip.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const geometry = @import("../geometry.zig");
const nowMs = Toplevel.nowMs;

/// Whether the window has a strip: it is in a compositor tab group, or its
/// client has published tabs (rediwm_titlebar_tabs_v1).
pub fn hasTabStrip(toplevel: *const Toplevel) bool {
    if (toplevel.titlebar_tabs) |published| if (published.active()) return true;
    return toplevel.tab_group != 0;
}

/// `storage` may be null for a window without a strip, which has no tabs.
pub fn tabStrip(toplevel: *Toplevel, storage: ?*[@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab) @import("../chrome_tabs.zig").Strip {
    var strip: @import("../chrome_tabs.zig").Strip = .{ .first = toplevel.tab_first, .hover = toplevel.tab_hover, .notice = toplevel.tab_notice, .drag = toplevel.tab_drag, .drop_index = toplevel.tab_drop };
    const selected = if (storage) |tabs| fillTabs(toplevel, tabs, &strip) else 0;
    const geom = @import("../chrome_tabs.zig").geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
    if (selected < strip.first) strip.first = selected;
    if (selected >= strip.first + geom.count) strip.first = selected + 1 -| geom.count;
    toplevel.tab_first = strip.first;
    return strip;
}

/// The strip's tabs into `storage`; returns the index of the selected tab: the
/// group member `toplevel` itself, or what the client published as selected.
fn fillTabs(toplevel: *Toplevel, storage: *[@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab, strip: *@import("../chrome_tabs.zig").Strip) usize {
    if (toplevel.titlebar_tabs) |published| if (published.active()) return published.fill(storage, strip);
    var members_storage: [@import("../window_tabs.zig").max_tabs]*Toplevel = undefined;
    const members = @import("../window_tabs.zig").members(toplevel, &members_storage);
    var selected: usize = 0;
    for (members, 0..) |member, i| {
        storage[i] = .{ .id = member.id, .title = member.title(), .active = member == toplevel, .attention = member.needs_attention };
        if (member == toplevel) selected = i;
    }
    strip.tabs = storage[0..members.len];
    return selected;
}

pub fn tabAt(toplevel: *Toplevel, x: f64, y: f64) @import("../chrome_tabs.zig").Hit {
    if (!toplevel.hasServerDecorations() or !toplevel.hasTabStrip()) return .none;
    var storage: [@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab = undefined;
    return @import("../chrome_tabs.zig").hit(toplevel.chrome_width - toplevel.controlInsets().right, toplevel.chromeDensity(), toplevel.tabStrip(&storage), x, y);
}

pub fn hoverTab(toplevel: *Toplevel, x: f64, y: f64) void {
    const next = @import("../chrome_tabs.zig").key(toplevel.tabAt(x, y));
    if (next == toplevel.tab_hover) return;
    toplevel.tab_hover = next;
    toplevel.syncChrome(false, nowMs()) catch {};
}

pub fn stepTab(toplevel: *Toplevel, forward: bool) void {
    if (toplevel.titlebar_tabs) |published| if (published.active()) {
        published.step(forward);
        return;
    };
    var storage: [@import("../window_tabs.zig").max_tabs]*Toplevel = undefined;
    const members = @import("../window_tabs.zig").members(toplevel, &storage);
    if (members.len < 2) return;
    for (members, 0..) |member, i| {
        if (member != toplevel) continue;
        const next = if (forward) (i + 1) % members.len else (i + members.len - 1) % members.len;
        toplevel.server.world.focus(members[next]);
        return;
    }
}

/// A left press on a tab of a published strip. Whether it is a click or a
/// reorder depends on where the pointer goes, so nothing is sent yet:
/// `tabRelease` does. `lx` is the pointer's x in the frame's coordinates.
/// False when the press is not on such a tab, and nothing is tracked.
pub fn tabPress(toplevel: *Toplevel, sx: f64, sy: f64, lx: f64) bool {
    const chrome_tabs = @import("../chrome_tabs.zig");
    const published = toplevel.titlebar_tabs orelse return false;
    if (!published.active()) return false;
    const id = switch (toplevel.tabAt(sx, sy)) {
        .tab => |id| id,
        else => return false,
    };
    var storage: [@import("../window_tabs.zig").max_tabs]chrome_tabs.Tab = undefined;
    const strip = toplevel.tabStrip(&storage);
    const g = chrome_tabs.geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
    return toplevel.tab_drag.press(strip, g, id, @floatCast(lx));
}

/// The pointer moved while a tab is pressed; true once that is a reorder. A
/// strip that changed under the press (the tab is gone, or the strip) ends it.
/// `ly` is the pointer's y in the frame's coordinates: far from the strip, a
/// drag of a detachable tab turns into one that leaves the window.
pub fn tabMotion(toplevel: *Toplevel, lx: f64, ly: f64) bool {
    if (!toplevel.tab_drag.pressed()) return false;
    const alive = if (toplevel.titlebar_tabs) |published| published.active() and published.has(toplevel.tab_drag.id) else false;
    if (!alive) {
        const was_dragging = toplevel.tab_drag.dragging();
        toplevel.tab_drag.cancel();
        if (was_dragging) toplevel.syncChrome(false, nowMs()) catch {};
        return false;
    }
    var changed = toplevel.tab_drag.motion(@floatCast(lx), toplevel.chromeDensity());
    if (toplevel.titlebar_tabs.?.detachable) {
        const band: f32 = @floatFromInt(toplevel.titlebarHeight());
        if (toplevel.tab_drag.pointerY(@floatCast(ly), band)) changed = true;
    }
    if (changed) toplevel.syncChrome(false, nowMs()) catch {};
    return toplevel.tab_drag.dragging();
}

/// The button came up: a press that never travelled selects the tab, a
/// reorder that ended elsewhere asks the client to move it. The client
/// commits the result; until then the strip shows the old order.
pub fn tabRelease(toplevel: *Toplevel) void {
    if (!toplevel.tab_drag.pressed()) return;
    const chrome_tabs = @import("../chrome_tabs.zig");
    const id = toplevel.tab_drag.id;
    const dragged = toplevel.tab_drag.dragging();
    if (toplevel.titlebar_tabs) |published| if (published.active() and published.has(id)) {
        var storage: [@import("../window_tabs.zig").max_tabs]chrome_tabs.Tab = undefined;
        const strip = toplevel.tabStrip(&storage);
        const g = chrome_tabs.geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
        if (toplevel.tab_drag.release(g)) |move| {
            published.sendMove(move.id, move.index);
        } else if (!dragged) published.sendSelect(id);
    };
    toplevel.tab_drag.cancel();
    if (dragged) toplevel.syncChrome(false, nowMs()) catch {};
}

/// The leading button was pressed: tell the client where it is, in its
/// surface's coordinates, so a menu can open under it.
pub fn activateLeading(toplevel: *Toplevel) void {
    const chrome_tabs = @import("../chrome_tabs.zig");
    const published = toplevel.titlebar_tabs orelse return;
    var storage: [@import("../window_tabs.zig").max_tabs]chrome_tabs.Tab = undefined;
    const strip = toplevel.tabStrip(&storage);
    const g = chrome_tabs.geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
    const r = g.leading orelse return;
    published.sendLeadingActivated(r.x, r.y, r.w, r.h, toplevel.borderWidth(), toplevel.titlebarHeight());
}

/// Another strip of the same client that a dragged-out tab would join.
pub const DropTarget = struct { toplevel: *Toplevel, index: usize };

/// Where a tab dropped at `sx` (frame coordinates) would go in this window's
/// strip; null when it has none.
pub fn tabDropIndex(toplevel: *Toplevel, sx: f64) ?usize {
    const chrome_tabs = @import("../chrome_tabs.zig");
    const published = toplevel.titlebar_tabs orelse return null;
    if (!published.active()) return null;
    var storage: [@import("../window_tabs.zig").max_tabs]chrome_tabs.Tab = undefined;
    const strip = toplevel.tabStrip(&storage);
    const g = chrome_tabs.geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
    return @import("ui").widgets.title_tabs.dropIndex(g, @floatCast(sx));
}

/// Shows (or removes) the marker for a tab about to be dropped here.
pub fn setTabDrop(toplevel: *Toplevel, index: ?usize) void {
    if (toplevel.tab_drop == index) return;
    toplevel.tab_drop = index;
    toplevel.syncChrome(false, nowMs()) catch {};
}

/// The button came up after the tab left the window: ask the client to move it
/// into `target`, or into a new window of its own at the pointer (`x`, `y`,
/// layout coordinates). Either only asks; the strip changes when the client
/// commits. A tab that cannot be asked for simply stays.
pub fn tabDetach(toplevel: *Toplevel, target: ?DropTarget, x: f64, y: f64) void {
    if (!toplevel.tab_drag.out) return toplevel.tabRelease();
    const id = toplevel.tab_drag.id;
    if (toplevel.titlebar_tabs) |published| if (published.active() and published.has(id)) {
        if (target) |t| {
            if (t.toplevel.titlebar_tabs) |destination| _ = published.sendDropOn(id, destination, t.index);
        } else _ = published.sendTearOff(&toplevel.server.shell.titlebar_tabs, id, x, y);
    };
    toplevel.tab_drag.cancel();
    toplevel.syncChrome(false, nowMs()) catch {};
}
