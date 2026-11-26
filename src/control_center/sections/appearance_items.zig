//! Appearance taskbar items: the reorderable list and its drag handling.

const std = @import("std");
const layout = @import("ui").layout;
const Widget = layout.Widget;
const main = @import("../../main.zig");
const panel = @import("../panel.zig");
const setting_save = @import("config").setting_save;
const taskbar_items = @import("config").taskbar_items;
const section = @import("appearance_dock.zig").section;
const Section = @import("appearance.zig").Section;

pub fn saveItems(s: *Section, items: taskbar_items.Config) void {
    const server = s.cc.server;
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "taskbar_items", items) catch |err| {
        std.log.warn("could not save taskbar items: {}", .{err});
        if (server.input.open_control_center) |cc| cc.refresh();
        return;
    };
    server.config.compositor.taskbar_items = items;
    server.refreshTaskbarsGeometry();
    if (server.input.open_control_center) |cc| cc.refresh();
}

pub const item_row_height: f32 = 40;
pub const item_section_width: f32 = 170;

/// The row's Left/Center/Right buttons: the item moves to the end of that
/// section, the same result as dropping it there.
pub fn onItemSectionChanged(owner: ?*anyopaque, id: usize, index: usize) void {
    if (index > 2 or id >= taskbar_items.count) return;
    const s = section(owner);
    var items = s.cc.server.config.compositor.taskbar_items;
    const zone: taskbar_items.Section = @enumFromInt(index);
    const item = items.order[id];
    if (items.section(item) == zone) return;
    _ = items.place(id, zone, taskbar_items.count);
    s.item_focus = item;
    saveItems(s, items);
}

pub fn itemRowStyle(lifted: bool) layout.RectStyle {
    const pal = panel.palette();
    return .{ .color = if (lifted) pal.app_item_selected else pal.app_item, .radius = 8, .border_width = 1, .border_color = if (lifted) pal.accent else pal.app_item_border };
}

pub fn itemZoneStyle(target: bool) layout.RectStyle {
    const pal = panel.palette();
    return .{ .color = pal.app_bg, .radius = 10, .border_width = 1, .border_color = if (target) pal.accent else pal.app_item_border };
}

pub fn itemName(item: taskbar_items.Item, comptime suffix: []const u8) []const u8 {
    return switch (item) {
        inline else => |tag| "taskbar_" ++ @tagName(tag) ++ suffix,
    };
}

/// Points the rows at `items` (row `i` shows `order[i]`) and gives each
/// section's well its run of rows, or its placeholder. True when a well's
/// row count changed, which needs a layout.
pub fn syncItems(out: *Section, items: taskbar_items.Config, dragged: ?usize) bool {
    const pal = panel.palette();
    var presence = if (out.cc.server.network) |manager| manager.presence() else taskbar_items.Presence{};
    presence.transfers = if (out.cc.server.transfers) |client| client.model.present() else false;
    for (&out.item_rows, &out.item_controls, items.order, 0..) |*row, *controls, item, i| {
        const lifted = dragged == i;
        row.name = itemName(item, "_row");
        row.kind = .{ .rect = itemRowStyle(lifted) };
        controls[0].name = itemName(item, "_order");
        controls[0].kind.button.state = if (lifted) .press else .idle;
        controls[1].kind.text.content = item.label();
        // `panel.restyle` colours text by weight: a hidden item's label is dim.
        const shown = items.resolved(item, presence);
        controls[1].kind.text.weight = if (shown) 600 else 400;
        controls[1].kind.text.color = if (shown) pal.fg else pal.dim;
        controls[2].name = itemName(item, "_section");
        controls[2].kind.segmented.selected = @intFromEnum(items.section(item));
        controls[3].name = itemName(item, "_visible");
        controls[3].kind.toggle.on = shown;
        for (controls) |*control| control.markDirty();
        row.markDirty();
    }
    var changed = false;
    var start: usize = 0;
    for (&out.items_section_children, &out.items_placeholder, 0..) |*zone, *placeholder, z| {
        var end = start;
        while (end < taskbar_items.count and @intFromEnum(items.section(items.order[end])) == z) end += 1;
        const well = &zone[1];
        const rows: []Widget = if (end == start) placeholder else out.item_rows[start..end];
        changed = changed or rows.ptr != well.children.ptr or rows.len != well.children.len;
        well.children = rows;
        well.kind = .{ .rect = itemZoneStyle(dragged != null and start <= dragged.? and dragged.? < end) };
        well.linkParents();
        well.markDirty();
        start = end;
    }
    return changed;
}

/// The row whose grip, label or background is at (x, y): a whole row drags,
/// only its toggle does not.
pub fn itemHandle(s: *Section, x: f32, y: f32) ?usize {
    const ui = @import("ui");
    const hit = ui.input.hitTest(&s.cc.root, x, y) orelse return null;
    for (&s.item_rows, &s.item_controls, 0..) |*row, *controls, i| {
        if (hit == row or hit == &controls[0] or hit == &controls[1]) return i;
    }
    return null;
}

pub fn beginItemDrag(s: *Section, x: f32, y: f32) bool {
    const index = itemHandle(s, x, y) orelse return false;
    // Keep the rows still if the handle was grabbed during a wheel glide.
    const scroll = &s.cc.body_children[1].kind.scroll_container;
    scroll.glide.cancel(scroll.scroll_offset);
    s.item_drag = .{ .index = index, .press_y = y, .items = s.cc.server.config.compositor.taskbar_items };
    @import("ui").input.reset();
    previewItems(s);
    return true;
}

pub fn previewItems(s: *Section) void {
    const drag = s.item_drag;
    const items = if (drag) |d| d.items else s.cc.server.config.compositor.taskbar_items;
    if (syncItems(s, items, if (drag) |d| d.index else null)) s.cc.layoutContent();
    s.cc.requestRepaint();
}

/// Rows move live: the pointer's section is the one whose title it is at or
/// below, its slot the count of that section's other rows whose middle it has passed.
pub fn moveItemDrag(s: *Section, y: f32) void {
    const drag = if (s.item_drag) |*d| d else return;
    if (!drag.moved and @abs(y - drag.press_y) < 4) return;
    drag.moved = true;
    var zone: usize = 0;
    for (1..3) |z| {
        if (y >= s.items_children[2 + z].computed_y) zone = z;
    }
    const current = @intFromEnum(drag.items.section(drag.items.order[drag.index]));
    var slot: usize = 0;
    var current_slot: usize = 0;
    for (drag.items.order, 0..) |item, i| {
        const z = @intFromEnum(drag.items.section(item));
        if (i == drag.index) continue;
        if (z == current and i < drag.index) current_slot += 1;
        if (z == zone and y > s.item_rows[i].computed_y + s.item_rows[i].computed_height / 2) slot += 1;
    }
    if (zone == current and slot == current_slot) return;
    drag.index = drag.items.place(drag.index, @enumFromInt(zone), slot);
    previewItems(s);
}

pub fn endItemDrag(s: *Section, commit: bool) void {
    const drag = s.item_drag orelse return;
    s.item_drag = null;
    s.item_focus = drag.items.order[drag.index];
    const saved = s.cc.server.config.compositor.taskbar_items;
    if (commit and !(std.meta.eql(drag.items.order, saved.order) and std.meta.eql(drag.items.sections, saved.sections))) {
        // A config reload during the grab can change visibility independently.
        var items = saved;
        items.order = drag.items.order;
        items.sections = drag.items.sections;
        items.normalize();
        saveItems(s, items);
    }
    previewItems(s);
    if (!s.cc.refresh_pending) restoreItemFocus(s);
}

pub fn restoreItemFocus(s: *Section) void {
    const item = s.item_focus orelse return;
    for (s.cc.server.config.compositor.taskbar_items.order, 0..) |candidate, i| {
        if (item == candidate) @import("ui").input.current.focus(&s.cc.root, &s.item_controls[i][0]);
    }
    s.item_focus = null;
}

pub fn captureItemFocus(s: *Section) void {
    if (s.item_focus != null) return;
    const focused = @import("ui").input.current.focused orelse return;
    for (&s.item_controls) |*controls| {
        if (focused != &controls[0]) continue;
        for (std.enums.values(taskbar_items.Item)) |item| {
            if (std.mem.eql(u8, controls[1].kind.text.content, item.label())) s.item_focus = item;
        }
        return;
    }
}

/// Up/Down on a focused grip moves its item one step, across sections too.
pub fn itemKey(s: *Section, key: @import("ui").input.Key) bool {
    if (s.item_drag != null) {
        if (key == .escape) endItemDrag(s, false);
        return true;
    }
    if (key != .up and key != .down) return false;
    const focused = @import("ui").input.current.focused orelse return false;
    for (&s.item_controls, 0..) |*controls, i| {
        if (focused != &controls[0]) continue;
        const before = s.cc.server.config.compositor.taskbar_items;
        var items = before;
        s.item_focus = items.order[i];
        items.move(i, key == .down);
        if (!std.meta.eql(items, before)) saveItems(s, items);
        return true;
    }
    return false;
}

pub fn ItemToggle(comptime index: usize) type {
    return struct {
        pub fn changed(owner: ?*anyopaque, _: usize, on: bool) void {
            const server = section(owner).cc.server;
            var items = server.config.compositor.taskbar_items;
            items.setVisible(items.order[index], on);
            saveItems(section(owner), items);
        }
    };
}
