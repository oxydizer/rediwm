//! Settings → Displays: the arrangement card (drag displays, pick one to
//! edit, make one the main display).

const i18n = @import("i18n");
const std = @import("std");
const wlr = @import("wlroots");
const layout = @import("ui").layout;
const panel = @import("../panel.zig");
const Output = @import("../../Output.zig");
const display = @import("display.zig");
const Section = display.Section;
const labelWidget = display.labelWidget;
const valueWidget = display.valueWidget;
const transformFromWl = display.transformFromWl;

pub fn buildArrangement(out: *Section, selected_name: []const u8) void {
    out.has_arrangement = false;
    out.make_main = false;
    out.arrangement_selected = null;
    const server = out.cc.server;
    const allocator = out.arena.allocator();
    var count: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (arrangeable(output) != null) count += 1;
    }
    if (count < 2) return;
    out.arrangement_names = allocator.alloc([]const u8, count) catch return;
    out.arrangement_items = allocator.alloc(layout.ArrangementItem, count) catch return;
    out.arrangement_origins = allocator.alloc(layout.ArrangementItem, count) catch return;
    const primary = server.effectivePrimaryOutput();
    var selected_is_main = false;
    var index: usize = 0;
    it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const box = arrangeable(output) orelse continue;
        const name = allocator.dupe(u8, std.mem.span(output.wlr_output.name)) catch return;
        out.arrangement_names[index] = name;
        // The mode as the screen stands: a portrait screen reads tall.
        const rotated = switch (transformFromWl(output.wlr_output.transform)) {
            .@"90", .@"270", .flipped_90, .flipped_270 => true,
            else => false,
        };
        const mode_w = if (rotated) output.wlr_output.height else output.wlr_output.width;
        const mode_h = if (rotated) output.wlr_output.width else output.wlr_output.height;
        out.arrangement_items[index] = .{
            .x = box.x,
            .y = box.y,
            .width = box.width,
            .height = box.height,
            .label = name,
            .detail = std.fmt.allocPrint(allocator, "{d} × {d}", .{ mode_w, mode_h }) catch "",
            .primary = output == primary,
        };
        if (std.mem.eql(u8, name, selected_name)) {
            out.arrangement_selected = index;
            selected_is_main = output == primary;
        }
        index += 1;
    }
    @memcpy(out.arrangement_origins, out.arrangement_items);
    // A tall arrangement (stacked, or portrait screens) gets a taller canvas.
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (out.arrangement_items) |item| {
        min_x = @min(min_x, item.x);
        min_y = @min(min_y, item.y);
        max_x = @max(max_x, item.x + item.width);
        max_y = @max(max_y, item.y + item.height);
    }
    const canvas_height: f32 = if (3 * (max_y - min_y) > 2 * (max_x - min_x)) 280 else 220;

    var hint = valueWidget(i18n.tr("Drag displays to match your desk. Click one to edit it."));
    hint.kind.text.font_size = 12;
    hint.width = .{ .flex = 1 };
    out.main_text_children = .{
        labelWidget(i18n.tr("Main display")),
        valueWidget(if (selected_is_main) i18n.tr("Desktop icons appear on this display.") else i18n.tr("Where desktop icons appear.")),
    };
    out.main_text_children[1].kind.text.font_size = 12;
    out.main_row_children = .{
        .{ .kind = .container, .direction = .column, .gap = 4, .width = .{ .flex = 1 }, .children = &out.main_text_children },
        .{ .name = "make_main", .kind = .{ .button = .{ .label = i18n.tr("Make main display"), .owner = out, .on_click = &onMakeMain } }, .height = .{ .fixed = 32 } },
    };
    // The selected display is already main: nothing to offer.
    out.main_row_count = if (selected_is_main or out.arrangement_selected == null) 1 else 2;
    out.arrangement_children = .{
        panel.sectionTitle(i18n.tr("Arrangement")),
        hint,
        .{ .name = "arrangement", .kind = .{ .arrangement = .{ .items = out.arrangement_items, .selected = out.arrangement_selected } }, .width = .{ .percent = 1 }, .height = .{ .fixed = canvas_height } },
        .{ .kind = .container, .direction = .row, .@"align" = .center, .gap = 12, .children = out.main_row_children[0..out.main_row_count] },
    };
    out.has_arrangement = true;
}

/// An output's layout box while it is on and placed.
fn arrangeable(output: *Output) ?wlr.Box {
    if (!output.isAvailable()) return null;
    var box: wlr.Box = undefined;
    output.server.output_layout.getBox(output.wlr_output, &box);
    if (box.width <= 0 or box.height <= 0) return null;
    return box;
}

fn onMakeMain(owner: ?*anyopaque, _: usize) void {
    const out: *Section = @ptrCast(@alignCast(owner orelse return));
    out.make_main = true;
}

fn arrangementData(out: *Section) ?*layout.ArrangementData {
    if (!out.has_arrangement or out.arrangement_children[2].kind != .arrangement) return null;
    return &out.arrangement_children[2].kind.arrangement;
}

/// After a drop: every display's new position, shifted so the arrangement
/// starts at 0,0 (X11 has no negative screen coordinates). Section-arena memory.
pub fn pendingArrangement(out: *Section) ?[]Output.Placement {
    const data = arrangementData(out) orelse return null;
    if (data.drag != null) return null;
    var moved = false;
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    for (data.items, out.arrangement_origins) |item, origin| {
        if (item.x != origin.x or item.y != origin.y) moved = true;
        min_x = @min(min_x, item.x);
        min_y = @min(min_y, item.y);
    }
    if (!moved) return null;
    // Once: the rebuild that follows applying it starts from the new layout.
    @memcpy(out.arrangement_origins, data.items);
    const server = out.cc.server;
    const placements = out.arena.allocator().alloc(Output.Placement, data.items.len) catch return null;
    for (data.items, out.arrangement_names, placements) |item, name, *placement| {
        placement.* = .{ .output = server.findOutputByName(name) orelse return null, .x = item.x - min_x, .y = item.y - min_y };
    }
    return placements;
}

/// The output name of a display picked in the arrangement.
pub fn pendingArrangementSelection(out: *Section) ?[]const u8 {
    const data = arrangementData(out) orelse return null;
    const selected = data.selected orelse return null;
    if (data.drag != null or selected == out.arrangement_selected or selected >= out.arrangement_names.len) return null;
    out.arrangement_selected = selected;
    return out.arrangement_names[selected];
}

pub fn pendingMakeMain(out: *Section) bool {
    defer out.make_main = false;
    return out.has_arrangement and out.make_main;
}
