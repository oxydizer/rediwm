//! A tab dragged out of its window: which strip of the same client it hovers,
//! the marker that strip shows, and the request sent when the button comes up.
const Input = @import("../Input.zig");
const Toplevel = @import("../Toplevel.zig");
const scene_data = @import("../scene_data.zig");

/// The strip under the pointer that may take the tab, if the drag is out.
pub fn target(input: *Input, source: *Toplevel) ?Toplevel.DropTarget {
    if (!source.tab_drag.out) return null;
    const own = source.titlebar_tabs orelse return null;
    if (!own.detachable) return null;
    const res = switch (scene_data.hitTest(input.server, input.cursor.x, input.cursor.y)) {
        .chrome => |chrome| chrome,
        else => return null,
    };
    if (res.toplevel == source) return null;
    const other = res.toplevel.titlebar_tabs orelse return null;
    if (!other.active() or !other.detachable) return null;
    // Never another application's strip.
    if (other.resource.getClient() != own.resource.getClient()) return null;
    if (res.sy >= @as(f64, @floatFromInt(res.toplevel.titlebarHeight()))) return null;
    const index = res.toplevel.tabDropIndex(res.sx) orelse return null;
    return .{ .toplevel = res.toplevel, .index = index };
}

/// Keeps the drop marker on the strip under the pointer, and only there.
pub fn update(input: *Input, source: *Toplevel) void {
    const found = target(input, source);
    if (input.tab_drop_target) |previous| {
        if (found == null or found.?.toplevel != previous) {
            previous.setTabDrop(null);
            input.tab_drop_target = null;
        }
    }
    if (found) |f| {
        f.toplevel.setTabDrop(f.index);
        input.tab_drop_target = f.toplevel;
    }
}

pub fn clear(input: *Input) void {
    if (input.tab_drop_target) |previous| previous.setTabDrop(null);
    input.tab_drop_target = null;
}

/// The button came up on a pressed tab.
pub fn finish(input: *Input, source: *Toplevel) void {
    const found = target(input, source);
    clear(input);
    source.tabDetach(found, input.cursor.x, input.cursor.y);
}
