//! Building the widget tree, keeping the results' scroll offset across rebuilds.

const i18n = @import("i18n");
const std = @import("std");
const wlr = @import("wlroots");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const theme = ui.theme;
const panel = @import("panel.zig");
const menuPalette = panel.menuPalette;
const StartMenu = @import("StartMenu.zig");
const paintHighlights = StartMenu.paintHighlights;
const onQueryChanged = StartMenu.onQueryChanged;
const onRowClick = StartMenu.onRowClick;
const onCategoryAll = StartMenu.onCategoryAll;
const onCategoryApps = StartMenu.onCategoryApps;
const onSettingsButtonClick = StartMenu.onSettingsButtonClick;
const onPowerButtonClick = StartMenu.onPowerButtonClick;

pub fn refreshCatalog(menu: *StartMenu) void {
    const snap = menu.server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    const scroll = menu.currentScrollOffset();
    menu.model.bindSnapshot(snap, true) catch return;
    menu.buildTree();
    menu.relayout();
    menu.restoreScrollOffset(scroll);
}

pub fn currentScrollOffset(menu: *StartMenu) f32 {
    for (menu.root.children) |*viewport| {
        if (viewport.kind == .scroll_container) return ui.widgets.scroll_container.restingOffset(viewport);
    }
    return 0;
}

pub fn restoreScrollOffset(menu: *StartMenu, offset: f32) void {
    for (menu.root.children) |*viewport| {
        if (viewport.kind == .scroll_container) {
            ui.widgets.scroll_container.scrollBy(viewport, offset - viewport.kind.scroll_container.scroll_offset);
            return;
        }
    }
}

pub fn buildTree(menu: *StartMenu) void {
    if (menu.mode == .start) menu.card_selection = null;
    menu.dispatcher.reset();
    // Fresh rows carry no pointer state; let the hover fill fade out.
    menu.setHoverRow(null);
    menu.syncSelectionGlide();
    _ = menu.tree_arena.reset(.retain_capacity);
    const a = menu.tree_arena.allocator();

    const t = menuPalette();
    // 1. Search Box
    const sw_children = a.alloc(Widget, 1) catch return;
    const query_val = a.dupe(u8, menu.model.query.items) catch return;
    sw_children[0] = .{
        .name = "search_input",
        .kind = .{ .text_input = .{
            .placeholder = if (menu.mode == .launcher) i18n.tr("Search applications…") else i18n.tr("Type to search…"),
            .field = .{ .leading_icon = .search, .leading_icon_size = 24, .leading_icon_color = t.window_fg },
            .value = query_val,
            .cursor_pos = @min(menu.query_cursor, query_val.len),
            .selection_anchor = if (menu.query_anchor) |anchor| @min(anchor, query_val.len) else null,
            .on_change = onQueryChanged,
        } },
        .width = .{ .percent = 1 },
    };

    const search_wrapper = a.create(Widget) catch return;
    search_wrapper.* = .{
        .name = "search",
        .kind = .container,
        .width = .{ .percent = 1 },
        .padding = layout.Edges{ .top = 20, .left = 20, .right = 20, .bottom = 10 },
        .children = sw_children,
    };

    // Automatically focus search input
    menu.dispatcher.focused = &sw_children[0];

    // 2. Heading: Grid glyph + "Applications" + count
    const grid_icon = a.create(Widget) catch return;
    grid_icon.* = .{
        .kind = .{ .icon = .{ .id = .grid, .color = t.dim } },
        .width = .{ .fixed = 14 },
        .height = .{ .fixed = 14 },
    };

    const heading_label = a.create(Widget) catch return;
    heading_label.* = .{
        .kind = .{ .text = .{
            .content = i18n.tr("Applications"),
            .font_size = 12,
            .weight = 600,
            .color = t.dim,
        } },
    };

    const count_str: []const u8 = if (menu.model.isLoading())
        "…"
    else
        std.fmt.allocPrint(a, "{d}", .{menu.model.countApplications()}) catch "0";
    const heading_count = a.create(Widget) catch return;
    heading_count.* = .{
        .kind = .{ .text = .{
            .content = count_str,
            .font_size = 11,
            .weight = 400,
            .color = t.faint,
        } },
    };

    const heading_children = a.alloc(Widget, 3) catch return;
    heading_children[0] = grid_icon.*;
    heading_children[1] = heading_label.*;
    heading_children[2] = heading_count.*;

    const heading_wrapper = a.create(Widget) catch return;
    heading_wrapper.* = .{
        .kind = .container,
        .direction = .row,
        .@"align" = .center,
        .gap = 8,
        .width = .{ .percent = 1 },
        .height = .{ .fixed = 24 },
        .padding = layout.Edges{ .top = 0, .left = 24, .right = 24, .bottom = 4 },
        .children = heading_children,
    };

    // 3. Results scroll container
    const row_count = menu.model.results.len;
    const row_widgets = a.alloc(Widget, row_count) catch return;
    menu.visible_icon_ids = a.alloc(?u64, row_count) catch return;
    @memset(menu.visible_icon_ids, null);

    for (menu.model.results, 0..) |res, idx| {
        const is_sel = (idx == menu.model.selected_index);

        // Resolve icons only after layout, for rows in the viewport.
        const img_widget = a.create(Widget) catch return;
        img_widget.* = .{
            .kind = .{ .image = .{
                .pixels = null,
                .width = 0,
                .height = 0,
                .radius = 8,
                .fallback_icon = if (res.is_settings) .settings else .generic,
            } },
            .width = .{ .fixed = 38 },
            .height = .{ .fixed = 38 },
        };

        // Text column (title + description)
        const title_widget = a.create(Widget) catch return;
        title_widget.* = .{
            .kind = .{ .text = .{
                .content = res.name,
                .font_size = if (menu.mode == .launcher) t.app_text_size else 13.5,
                .weight = 600,
                .color = t.fg,
            } },
        };

        const desc_widget = a.create(Widget) catch return;
        desc_widget.* = .{
            .kind = .{ .text = .{
                .content = res.description,
                .font_size = if (menu.mode == .launcher) t.app_status_size else 11.5,
                .weight = 400,
                .color = t.dim,
            } },
        };

        const col_children = a.alloc(Widget, 2) catch return;
        col_children[0] = title_widget.*;
        col_children[1] = desc_widget.*;

        const col_widget = a.create(Widget) catch return;
        col_widget.* = .{
            .kind = .container,
            .direction = .column,
            .gap = 2,
            .width = .{ .flex = 1 },
            .children = col_children,
        };

        // Row children: image, text column, optional enter hint
        var row_kids: []Widget = undefined;
        if (menu.mode == .launcher) {
            var output_box: wlr.Box = undefined;
            menu.server.output_layout.getBox(menu.wlr_output, &output_box);
            const show_id = @min(menu.wantedSize().width, @as(f32, @floatFromInt(output_box.width)) - 40) >= 700;
            row_kids = a.alloc(Widget, if (show_id) 5 else 4) catch return;
            row_kids[0] = img_widget.*;
            row_kids[1] = col_widget.*;
            if (show_id) row_kids[2] = .{
                .kind = .{ .text = .{ .content = res.id, .font_size = t.app_status_size, .color = t.dim } },
                .width = .{ .fixed = 170 },
            };
            row_kids[row_kids.len - 2] = menu.pinButton(idx);
            row_kids[row_kids.len - 1] = .{ .kind = .{ .icon = .{ .id = .chevron_right, .color = t.dim } }, .width = .{ .fixed = 14 }, .height = .{ .fixed = 14 } };
        } else if (is_sel) {
            const hint_widget = a.create(Widget) catch return;
            hint_widget.* = .{
                .kind = .{
                    .text = .{
                        // i18n: raw — Enter key glyph.
                        .content = "↵",
                        .font_size = 14,
                        .color = t.accent,
                    },
                },
            };
            row_kids = a.alloc(Widget, 3) catch return;
            row_kids[0] = img_widget.*;
            row_kids[1] = col_widget.*;
            row_kids[2] = hint_widget.*;
        } else {
            row_kids = a.alloc(Widget, 2) catch return;
            row_kids[0] = img_widget.*;
            row_kids[1] = col_widget.*;
        }

        row_widgets[idx] = .{
            .kind = .{ .row = .{
                .owner = menu,
                .id = idx,
                .on_click = onRowClick,
                .selected = is_sel,
                .underlay = true,
            } },
            .direction = .row,
            .@"align" = .center,
            .gap = 16,
            .padding = layout.Edges.xy(theme.global.start_menu_icon_left_pad, theme.global.start_menu_icon_bottom_pad),
            .width = .{ .percent = 1 },
            .height = .{ .fixed = 56 },
            .children = row_kids,
        };
    }

    const scroll_widget = a.create(Widget) catch return;
    scroll_widget.* = .{
        .name = "results",
        .kind = .{ .scroll_container = .{ .underlay = .{ .owner = menu, .paint = paintHighlights } } },
        .direction = .column,
        .gap = 4,
        .padding = layout.Edges.xy(16, 4),
        .width = .{ .percent = 1 },
        .height = .{ .flex = 1 },
        .children = row_widgets,
    };

    // 4. Optional Error Banner
    var error_widget: ?*Widget = null;
    if (menu.model.error_msg) |err_msg| {
        const err_text = a.create(Widget) catch return;
        err_text.* = .{
            .kind = .{ .text = .{
                .content = err_msg,
                .font_size = 12,
                .color = t.danger,
            } },
        };
        const err_children = a.alloc(Widget, 1) catch return;
        err_children[0] = err_text.*;

        const ew = a.create(Widget) catch return;
        ew.* = .{
            .kind = .{ .rect = .{
                .color = .{ t.danger[0], t.danger[1], t.danger[2], 0.15 },
                .radius = 6,
            } },
            .padding = layout.Edges.xy(12, 6),
            .margin = layout.Edges.xy(20, 4),
            .width = .{ .percent = 1 },
            .children = err_children,
        };
        error_widget = ew;
    }

    // 5. Footer: Category buttons ("All", "Apps") and the power button,
    // which opens power_menu.zig's Lock/Log Out/Restart/Power Off modal.
    const all_btn = a.create(Widget) catch return;
    const all_sel = (menu.model.category == .all);
    all_btn.* = .{
        .name = "all",
        .kind = .{ .button = .{
            .label = i18n.tr("All"),
            .variant = if (all_sel) .primary else .secondary,
            .owner = menu,
            .on_click = onCategoryAll,
        } },
        .height = .{ .fixed = 26 },
    };

    const apps_btn = a.create(Widget) catch return;
    const apps_sel = (menu.model.category == .apps);
    apps_btn.* = .{
        .name = "apps",
        .kind = .{ .button = .{
            .label = i18n.tr("Apps"),
            .variant = if (apps_sel) .primary else .secondary,
            .owner = menu,
            .on_click = onCategoryApps,
        } },
        .height = .{ .fixed = 26 },
    };

    const cat_kids = a.alloc(Widget, 2) catch return;
    cat_kids[0] = all_btn.*;
    cat_kids[1] = apps_btn.*;

    const cat_box = a.create(Widget) catch return;
    cat_box.* = .{
        .name = "categories",
        .kind = .container,
        .direction = .row,
        .@"align" = .center,
        .gap = 8,
        .children = cat_kids,
    };

    const power_btn = a.create(Widget) catch return;
    power_btn.* = .{
        .name = "power",
        .kind = .{ .button = .{
            .variant = .ghost,
            .icon = .power,
            .icon_scale = 0.585,
            .label = i18n.tr("Power"),
            .owner = menu,
            .on_click = onPowerButtonClick,
        } },
        .width = .{ .fixed = 39 },
        .height = .{ .fixed = 39 },
    };

    const action_kids = a.alloc(Widget, 2) catch return;
    action_kids[0] = .{
        .name = "settings",
        .kind = .{ .button = .{
            .variant = .ghost,
            .icon = .settings,
            .icon_scale = 0.585,
            .label = i18n.tr("Settings"),
            .owner = menu,
            .on_click = onSettingsButtonClick,
        } },
        .width = .{ .fixed = 39 },
        .height = .{ .fixed = 39 },
    };
    action_kids[1] = power_btn.*;
    const actions: Widget = .{ .kind = .container, .direction = .row, .gap = 16, .@"align" = .center, .children = action_kids };
    const footer_kids = a.alloc(Widget, 2) catch return;
    footer_kids[0] = cat_box.*;
    footer_kids[1] = actions;

    const footer_widget = a.create(Widget) catch return;
    footer_widget.* = .{
        .kind = .{ .rect = .{
            .color = .{ 0, 0, 0, 0 },
            .border_width = if (t.start_menu_bevel > 0) 0 else 1,
            .border_color = t.border_soft,
        } },
        .underlay = if (t.start_menu_bevel > 0) .{ .owner = null, .paint = paintFooterDivider } else null,
        .direction = .row,
        .@"align" = .center,
        .justify = .space_between,
        .padding = layout.Edges.xy(20, 20),
        .width = .{ .percent = 1 },
        .height = .{ .fixed = 79 },
        .children = footer_kids,
    };

    // Root container
    const has_err = (error_widget != null);
    const root_kids = a.alloc(Widget, if (has_err) 6 else 5) catch return;
    root_kids[0] = search_wrapper.*;
    root_kids[1] = heading_wrapper.*;
    root_kids[2] = .{
        .kind = .{ .rect = .{ .color = t.border_soft } },
        .width = .{ .percent = 1 },
        .height = .{ .fixed = 1 },
    };
    if (has_err) {
        root_kids[3] = error_widget.?.*;
        root_kids[4] = scroll_widget.*;
        root_kids[5] = footer_widget.*;
    } else {
        root_kids[3] = scroll_widget.*;
        root_kids[4] = footer_widget.*;
    }

    var children = root_kids;
    if (menu.mode == .launcher) {
        const recent = menu.buildCards(a) catch return;
        var launcher_kids: std.ArrayList(Widget) = .empty;
        launcher_kids.append(a, search_wrapper.*) catch return;
        if (recent) |cards| launcher_kids.appendSlice(a, &cards) catch return;
        launcher_kids.append(a, heading_wrapper.*) catch return;
        if (error_widget) |err| launcher_kids.append(a, err.*) catch return;
        launcher_kids.append(a, scroll_widget.*) catch return;
        if (row_count == 0) launcher_kids.append(a, .{
            .name = "no_results",
            .kind = .{ .text = .{ .content = i18n.tr("No applications found"), .font_size = t.app_text_size, .color = t.dim } },
            .margin = layout.Edges.xy(24, 16),
        }) catch return;
        children = launcher_kids.toOwnedSlice(a) catch return;
    }

    menu.root = .{
        .kind = .{ .rect = .{
            .color = t.start_menu_bg,
            .radius = t.start_menu_radius,
            .bevel = t.start_menu_bevel,
            .border_width = 1,
            .border_color = t.start_menu_border,
        } },
        .direction = .column,
        .width = .{ .fixed = menu.wantedSize().width },
        .height = .auto,
        .children = children,
        .padding = if (menu.mode == .launcher) .{ .bottom = 16 } else .{},
    };
    menu.root.linkParents();
    // Bind before the opening click release, which otherwise clears search focus.
    menu.dispatcher.tree = &menu.root;
    if (menu.panel_box.width > 0 and menu.panel_box.height > 0) {
        const width: f32 = @floatFromInt(menu.panel_box.width);
        const height: f32 = @floatFromInt(menu.panel_box.height);
        menu.root.width = .{ .fixed = width };
        menu.root.height = .{ .fixed = height };
        ui.measure.measure(&menu.root, width, height);
        ui.arrange.arrange(&menu.root, 0, 0, width, height);
    }
}

// The panel owns its beveled outer border; the footer needs only a separator.
fn paintFooterDivider(_: ?*anyopaque, widget: *const Widget, renderer: *ui.paint.Renderer) void {
    renderer.fillRect(widget.computed_x, widget.computed_y, widget.computed_width, 1, .{ .color = (renderer.palette orelse theme.global).border_soft });
}
