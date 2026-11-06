//! The pinned-app strip and the suggestion cards.

const i18n = @import("i18n");
const std = @import("std");
const Allocator = std.mem.Allocator;
const wlr = @import("wlroots");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const panel = @import("panel.zig");
const menuPalette = panel.menuPalette;
const StartMenu = @import("StartMenu.zig");

pub fn pinButton(menu: *StartMenu, index: usize) Widget {
    const result = menu.model.results[index];
    const pinned = menu.server.launcher_history.pinned(result.id);
    const full = !pinned and menu.server.launcher_history.pinCount() >= 5;
    return .{
        .name = "pin_app",
        .kind = .{ .button = .{
            .label = if (pinned) i18n.tr("Unpin application") else if (full) i18n.tr("Five applications already pinned") else i18n.tr("Pin application"),
            .icon = if (pinned) .checkmark else .plus,
            .variant = if (pinned) .primary else .ghost,
            .size = .sm,
            .owner = menu,
            .id = index,
            .on_click = onPinClick,
            .state = if (result.app_entry == null) .disabled else .idle,
        } },
        .width = .{ .fixed = 28 },
        .height = .{ .fixed = 28 },
    };
}

pub fn buildCards(menu: *StartMenu, a: Allocator) !?[2]Widget {
    menu.card_count = 0;
    menu.card_icons = @splat(null);
    if (menu.model.query.items.len > 0) {
        menu.card_selection = null;
        return null;
    }
    const wanted = menu.wantedSize();
    var box: wlr.Box = undefined;
    menu.server.output_layout.getBox(menu.wlr_output, &box);
    // Leave room for search and results on short/fractionally scaled outputs.
    if (@min(wanted.height, @as(f32, @floatFromInt(box.height)) * 0.85) < 420) {
        menu.card_selection = null;
        return null;
    }
    const width = @min(wanted.width, @as(f32, @floatFromInt(box.width)) - 40);
    const capacity: usize = @intFromFloat(std.math.clamp(@floor((width - 40) / 116), 1, 5));
    menu.card_count = menu.server.launcher_history.cards(menu.model.results, menu.card_indices[0..capacity]);
    const have_history = menu.card_count > 0;
    if (!have_history) {
        for (menu.model.results, 0..) |result, i| {
            if (result.app_entry == null) continue;
            menu.card_indices[menu.card_count] = i;
            menu.card_count += 1;
            if (menu.card_count == capacity) break;
        }
    }
    if (menu.card_count == 0) {
        menu.card_selection = null;
        return null;
    }
    if (menu.card_selection) |selected| {
        if (selected >= menu.card_count) menu.card_selection = null;
    }
    const t = menuPalette();
    const cards = try a.alloc(Widget, menu.card_count);
    for (menu.card_indices[0..menu.card_count], 0..) |index, i| {
        const result = menu.model.results[index];
        const top = try a.dupe(Widget, &.{
            .{ .kind = .container, .width = .{ .flex = 1 } },
            menu.pinButton(index),
        });
        const children = try a.dupe(Widget, &.{
            .{ .kind = .container, .direction = .row, .width = .{ .percent = 1 }, .height = .{ .fixed = 28 }, .children = top },
            .{ .kind = .{ .image = .{ .fallback_icon = .generic, .radius = t.radius } }, .width = .{ .fixed = 48 }, .height = .{ .fixed = 48 } },
            .{ .kind = .{ .text = .{ .content = result.name, .font_size = t.app_text_size, .color = t.fg } }, .width = .{ .percent = 1 }, .height = .{ .fixed = 22 } },
        });
        cards[i] = .{
            .name = "recent_app",
            .kind = .{ .row = .{
                .owner = menu,
                .id = index,
                .on_click = onCardClick,
                .selected = menu.card_selection == i,
                .background = .{ .color = t.start_menu_search_bg, .radius = t.radius, .border_width = 1, .border_color = t.border_soft },
                .hover_background = .{ .color = t.start_menu_selected_bg, .radius = t.radius, .border_width = 1, .border_color = t.start_menu_selected_border },
            } },
            .direction = .column,
            .@"align" = .center,
            .gap = 6,
            .padding = layout.Edges.xy(10, 6),
            .width = .{ .fixed = (width - 40 - @as(f32, @floatFromInt(capacity - 1)) * 10) / @as(f32, @floatFromInt(capacity)) },
            .height = .{ .fixed = 126 },
            .children = children,
        };
    }
    return .{
        .{ .name = "recent_heading", .kind = .container, .direction = .row, .@"align" = .center, .padding = layout.Edges.xy(24, 6), .height = .{ .fixed = 34 }, .children = try a.dupe(Widget, &.{.{ .kind = .{ .text = .{
            .content = if (have_history) i18n.tr("Pinned & Recent") else i18n.tr("Quick Launch"),
            .font_size = t.app_heading_size,
            .weight = 600,
            .color = t.dim,
        } } }}) },
        .{ .name = "recent_cards", .kind = .container, .direction = .row, .gap = 10, .padding = .{ .left = 20, .right = 20, .bottom = 16 }, .width = .{ .percent = 1 }, .children = cards },
    };
}

pub fn onCardClick(owner: ?*anyopaque, id: usize) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    menu.activateResult(id);
}

pub fn onPinClick(owner: ?*anyopaque, id: usize) void {
    const menu: *StartMenu = @ptrCast(@alignCast(owner orelse return));
    if (id >= menu.model.results.len) return;
    const result = menu.model.results[id];
    if (result.app_entry == null) return;
    const scroll = menu.currentScrollOffset();
    const history = &menu.server.launcher_history;
    if (!history.pinned(result.id) and history.pinCount() >= 5) {
        menu.model.error_msg = i18n.tr("Unpin an application first (five pins maximum).");
    } else {
        menu.model.error_msg = null;
        history.togglePin(menu.server, result.id);
        if (menu.model.snapshot) |snap| menu.model.bindSnapshot(snap, true) catch {};
    }
    menu.buildTree();
    menu.restoreScrollOffset(scroll);
    menu.requestRepaint();
}
