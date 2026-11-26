//! Building the Appearance page's Taskbar, Start menu and Dock sections and the theme pack controls.

const i18n = @import("i18n");
const std = @import("std");
const layout = @import("ui").layout;
const theme = @import("ui").theme;
const theme_presets = @import("config").theme_pack;
const Widget = layout.Widget;
const panel = @import("../panel.zig");
const loader = @import("config").loader;
const Taskbar = @import("../../Taskbar.zig");
const Server = @import("../../Server.zig");
const dock_mod = @import("../../Dock.zig");
const taskbar_items = @import("config").taskbar_items;
const folder_picker = @import("../folder_picker.zig");
const menu_size = @import("../../start_menu/size.zig");
const wlr = @import("wlroots");
const appearance_themes = @import("appearance_themes.zig");
const appearance_chrome = @import("appearance_chrome.zig");
const appearance_items = @import("appearance_items.zig");
const appearance_dock = @import("appearance_dock.zig");
const onChooseStartLogo = appearance_themes.onChooseStartLogo;
const onAutoMenuSize = appearance_themes.onAutoMenuSize;
const onResetStartLogo = appearance_themes.onResetStartLogo;
const onResetTheme = appearance_themes.onResetTheme;
const onInstallTheme = appearance_themes.onInstallTheme;
const onReplaceTheme = appearance_themes.onReplaceTheme;
const onRemoveTheme = appearance_themes.onRemoveTheme;
const onExportTheme = appearance_themes.onExportTheme;
const onIconThemePicked = appearance_themes.onIconThemePicked;
const ClockStyle = appearance_chrome.ClockStyle;
const onTaskbarPositionChanged = appearance_chrome.onTaskbarPositionChanged;
const item_row_height = appearance_items.item_row_height;
const itemRowStyle = appearance_items.itemRowStyle;
const itemZoneStyle = appearance_items.itemZoneStyle;
const syncItems = appearance_items.syncItems;
const ItemToggle = appearance_items.ItemToggle;
const onDockChanged = appearance_dock.onDockChanged;
const onDockAutoHideChanged = appearance_dock.onDockAutoHideChanged;
const onDockOpacityChanged = appearance_dock.onDockOpacityChanged;
const onDockActiveHighlightChanged = appearance_dock.onDockActiveHighlightChanged;
const onDockShowTrashChanged = appearance_dock.onDockShowTrashChanged;
const onDockPositionChanged = appearance_dock.onDockPositionChanged;
const onDockHeightChanged = appearance_dock.onDockHeightChanged;
const updateDockZoomLabel = appearance_dock.updateDockZoomLabel;
const onDockHoverZoomChanged = appearance_dock.onDockHoverZoomChanged;
const menu_width_min = menu_size.min_width;
const menu_height_min = menu_size.min_height;
const appearance = @import("appearance.zig");
const segmented_width = appearance.segmented_width;
const dock_radius_min = appearance.dock_radius_min;
const dock_radius_max = appearance.dock_radius_max;
const px_taskbar_size = appearance.px_taskbar_size;
const px_chip_gap = appearance.px_chip_gap;
const px_start_button_gap = appearance.px_start_button_gap;
const px_start_icon_size = appearance.px_start_icon_size;
const px_menu_left = appearance.px_menu_left;
const px_menu_bottom = appearance.px_menu_bottom;
const px_icon_left = appearance.px_icon_left;
const px_icon_bottom = appearance.px_icon_bottom;
const px_chip_width = appearance.px_chip_width;
const px_menu_width = appearance.px_menu_width;
const px_menu_height = appearance.px_menu_height;
const px_dock_height = appearance.px_dock_height;
const px_dock_hover_zoom = appearance.px_dock_hover_zoom;
const px_taskbar_edge_gap = appearance.px_taskbar_edge_gap;
const px_taskbar_length = appearance.px_taskbar_length;
const px_taskbar_radius = appearance.px_taskbar_radius;
const px_dock_opacity = appearance.px_dock_opacity;
const px_dock_radius = appearance.px_dock_radius;
const Section = appearance.Section;
const menu_width_max = appearance.menu_width_max;
const menu_height_max = appearance.menu_height_max;
const start_logo_tile_size = appearance.start_logo_tile_size;
const startLogoImage = appearance.startLogoImage;
const labelWidget = appearance.labelWidget;
const sectionLabel = appearance.sectionLabel;
const pxGroup = appearance.pxGroup;
const unitGroup = appearance.unitGroup;
const PxHandler = appearance.PxHandler;
const UnitHandler = appearance.UnitHandler;

/// The Taskbar section: position, geometry, clock style and the item sections.
pub fn buildTaskbarSection(out: *Section, t: theme.Theme, pal: theme.Theme) Widget {
    out.taskbar_position_children = .{
        labelWidget(i18n.tr("Taskbar position")),
        .{ .name = "taskbar_position", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Top"), i18n.msg("Bottom") }), .selected = @intFromEnum(out.cc.server.config.compositor.taskbar_position), .owner = out, .on_change = &onTaskbarPositionChanged } }, .width = .{ .fixed = segmented_width } },
    };
    const position_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_position_children };
    out.taskbar_auto_hide_children = .{
        labelWidget(i18n.tr("Auto-hide taskbar")),
        .{ .name = "taskbar_auto_hide", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.taskbar_auto_hide, .owner = out, .on_change = &appearance_chrome.onTaskbarAutoHideChanged } } },
    };
    const auto_hide_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_auto_hide_children };
    out.taskbar_alignment_children = .{
        labelWidget(i18n.tr("Taskbar alignment")),
        .{ .name = "taskbar_alignment", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Left"), i18n.msg("Center"), i18n.msg("Right") }), .selected = @intFromEnum(out.cc.server.config.compositor.taskbar_alignment), .owner = out, .on_change = &appearance_chrome.onTaskbarAlignmentChanged } }, .width = .{ .fixed = segmented_width } },
    };
    const alignment_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_alignment_children };
    const taskbar_min: f32 = @floatFromInt(Taskbar.min_bar_height);
    const taskbar_row = pxGroup(out, px_taskbar_size, i18n.tr("Taskbar size"), std.math.clamp(t.taskbar_size, taskbar_min, 84.0), taskbar_min, 84, 2, &PxHandler(px_taskbar_size, "taskbar_size", true).changed);
    // A floating bar: its gap from the edge, its length and its corners. At
    // 0 px, 100 % and 0 px it is the original flush, full-width, square bar.
    const edge_gap_row = pxGroup(out, px_taskbar_edge_gap, i18n.tr("Taskbar gap from edge"), std.math.clamp(t.taskbar_edge_gap, 0.0, 48.0), 0, 48, 2, &PxHandler(px_taskbar_edge_gap, "taskbar_edge_gap", true).changed);
    out.px[px_taskbar_edge_gap].group_children[1].name = "taskbar_edge_gap";
    const length_row = unitGroup(out, px_taskbar_length, i18n.tr("Taskbar length"), std.math.clamp(t.taskbar_length, 30.0, 100.0), 30, 100, 2, &UnitHandler(px_taskbar_length, "taskbar_length", true, "%").changed, "%");
    out.px[px_taskbar_length].group_children[1].name = "taskbar_length";
    const radius_row = pxGroup(out, px_taskbar_radius, i18n.tr("Taskbar corner radius"), std.math.clamp(t.taskbar_radius, 0.0, 42.0), 0, 42, 1, &PxHandler(px_taskbar_radius, "taskbar_radius", true).changed);
    out.px[px_taskbar_radius].group_children[1].name = "taskbar_radius";
    // Also sets each pill's top/bottom margin within the bar (capped) —
    // see Taskbar.chipVerticalMargin — so this one slider spaces chips on
    // every side at once instead of only widening the horizontal gap.
    const chip_width_row = pxGroup(out, px_chip_width, i18n.tr("Window item width"), t.chip_width, 64, 400, 4, &PxHandler(px_chip_width, "chip_width", true).changed);
    const chip_gap_row = pxGroup(out, px_chip_gap, i18n.tr("Window item gap"), std.math.clamp(t.chip_gap, 0.0, 24.0), 0, 24, 2, &PxHandler(px_chip_gap, "chip_gap", true).changed);
    const start_gap_row = pxGroup(out, px_start_button_gap, i18n.tr("Start button gap"), std.math.clamp(t.start_button_gap, 0.0, 40.0), 0, 40, 2, &PxHandler(px_start_button_gap, "start_button_gap", true).changed);
    const start_icon_row = pxGroup(out, px_start_icon_size, i18n.tr("Start button icon size"), std.math.clamp(t.start_button_icon_size, 16.0, 42.0), 16, 42, 2, &PxHandler(px_start_icon_size, "start_button_icon_size", true).changed);
    out.clock_bold_children = .{
        labelWidget(i18n.tr("Bold clock text")),
        .{ .name = "clock_bold", .kind = .{ .toggle = .{ .on = theme.taskbar(.clock_bold), .owner = out, .on_change = &ClockStyle("clock_bold").changed } } },
    };
    out.clock_italic_children = .{
        labelWidget(i18n.tr("Italic clock text")),
        .{ .name = "clock_italic", .kind = .{ .toggle = .{ .on = theme.taskbar(.clock_italic), .owner = out, .on_change = &ClockStyle("clock_italic").changed } } },
    };
    const clock_bold_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.clock_bold_children };
    const clock_italic_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.clock_italic_children };
    // Each section is an inset well of raised rows; a whole row is its grip.
    inline for (0..taskbar_items.count) |i| {
        out.item_controls[i] = .{
            .{ .kind = .{ .button = .{ .label = i18n.tr("Drag to move"), .icon = .drag_handle, .variant = .ghost, .owner = out, .id = i } }, .width = .{ .fixed = 28 }, .height = .{ .fixed = 28 } },
            .{ .kind = .{ .text = .{ .content = "", .font_size = theme.global.app_text_size, .weight = 600, .color = pal.fg } }, .width = .{ .flex = 1 } },
            .{ .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Left"), i18n.msg("Center"), i18n.msg("Right") }), .selected = 0, .owner = out, .id = i, .on_change = &appearance_items.onItemSectionChanged } }, .width = .{ .fixed = appearance_items.item_section_width } },
            .{ .kind = .{ .toggle = .{ .on = false, .owner = out, .on_change = &ItemToggle(i).changed } } },
        };
        out.item_rows[i] = .{ .kind = .{ .rect = itemRowStyle(false) }, .direction = .row, .gap = 8, .@"align" = .center, .padding = .{ .top = 6, .right = 10, .bottom = 6, .left = 6 }, .children = &out.item_controls[i] };
    }
    inline for (.{ i18n.msg("LEFT"), i18n.msg("CENTER"), i18n.msg("RIGHT") }, .{ "left", "center", "right" }, 0..) |label, name, zone| {
        out.items_placeholder_body[zone] = .{
            .{ .kind = .container, .width = .{ .flex = 1 } },
            // Slack: a fractional raster scale hints wider than the logical measure.
            .{ .kind = .{ .text = .{ .content = i18n.tr("Drag items here"), .font_size = theme.global.settings_description_size, .color = pal.dim } }, .min_width = @import("ui").measure.textNaturalAtScale(i18n.tr("Drag items here"), .sans, 400, theme.global.settings_description_size, out.cc.toplevel.render_scale).w + 6 },
            .{ .kind = .container, .width = .{ .flex = 1 } },
        };
        out.items_placeholder[zone] = .{.{ .kind = .container, .height = .{ .fixed = item_row_height }, .@"align" = .center, .children = &out.items_placeholder_body[zone] }};
        out.items_section_children[zone] = .{
            sectionLabel(label.get()),
            .{ .name = "taskbar_zone_" ++ name, .kind = .{ .rect = itemZoneStyle(false) }, .direction = .column, .gap = 6, .padding = layout.Edges.all(6), .@"align" = .stretch },
        };
    }
    _ = syncItems(out, out.cc.server.config.compositor.taskbar_items, null);
    out.items_children = .{
        labelWidget(i18n.tr("Taskbar sections")),
        .{ .kind = .{ .text = .{ .content = i18n.tr("Drag an item to reorder it or move it to another section. Switch it off to hide it. Battery appears when available."), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 6, .@"align" = .stretch, .children = &out.items_section_children[0] },
        .{ .kind = .container, .direction = .column, .gap = 6, .@"align" = .stretch, .children = &out.items_section_children[1] },
        .{ .kind = .container, .direction = .column, .gap = 6, .@"align" = .stretch, .children = &out.items_section_children[2] },
        .{ .name = "taskbar_capture_notice", .kind = .{ .text = .{ .content = if (out.cc.server.config.compositor.taskbar_items.shown(.capture))
            i18n.tr("Screen capture appears while recording or sharing your screen. Keeping it enabled is recommended.")
        else
            i18n.tr("Warning: Screen capture is hidden. Recording and screen sharing can continue without a visible indicator or Stop sharing button. Hiding it is not recommended."), .font_size = theme.global.settings_description_size, .color = pal.dim } } },
    };
    const items_group: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .@"align" = .stretch, .children = &out.items_children };
    out.taskbar_section_children = .{ panel.sectionTitle(i18n.tr("Taskbar")), position_row, auto_hide_row, alignment_row, taskbar_row, edge_gap_row, length_row, radius_row, chip_width_row, chip_gap_row, start_gap_row, start_icon_row, clock_bold_row, clock_italic_row, items_group };
    const taskbar_section: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.taskbar_section_children };
    return taskbar_section;
}

/// The Start menu section: the button logo, menu size and paddings.
pub fn buildStartMenuSection(out: *Section, arena: std.mem.Allocator, t: theme.Theme, pal: theme.Theme) Widget {
    var output_box: wlr.Box = undefined;
    out.cc.server.output_layout.getBox(out.cc.wlr_output, &output_box);
    const menu_now = menu_size.wanted(t, @floatFromInt(output_box.width), @floatFromInt(output_box.height));
    const menu_pinned = t.start_menu_width > 0 or t.start_menu_max_height > 0;
    const menu_width_row = pxGroup(out, px_menu_width, i18n.tr("Menu width"), std.math.clamp(menu_now.width, menu_width_min, menu_width_max), menu_width_min, menu_width_max, 10, &PxHandler(px_menu_width, "start_menu_width", false).changed);
    out.px[px_menu_width].group_children[1].name = "start_menu_width";
    const menu_height_row = pxGroup(out, px_menu_height, i18n.tr("Menu height"), std.math.clamp(menu_now.height, menu_height_min, menu_height_max), menu_height_min, menu_height_max, 10, &PxHandler(px_menu_height, "start_menu_max_height", false).changed);
    out.px[px_menu_height].group_children[1].name = "start_menu_height";
    const menu_left_row = pxGroup(out, px_menu_left, i18n.tr("Menu left padding"), std.math.clamp(t.start_menu_left_pad, 0.0, 40.0), 0, 40, 2, &PxHandler(px_menu_left, "start_menu_left_pad", false).changed);
    const menu_bottom_row = pxGroup(out, px_menu_bottom, i18n.tr("Menu bottom padding"), std.math.clamp(t.start_menu_bottom_pad, 0.0, 40.0), 0, 40, 2, &PxHandler(px_menu_bottom, "start_menu_bottom_pad", false).changed);
    const icon_left_row = pxGroup(out, px_icon_left, i18n.tr("Icon left padding"), std.math.clamp(t.start_menu_icon_left_pad, 0.0, 32.0), 0, 32, 2, &PxHandler(px_icon_left, "start_menu_icon_left_pad", false).changed);
    const icon_bottom_row = pxGroup(out, px_icon_bottom, i18n.tr("Icon bottom padding"), std.math.clamp(t.start_menu_icon_bottom_pad, 0.0, 24.0), 0, 24, 2, &PxHandler(px_icon_bottom, "start_menu_icon_bottom_pad", false).changed);
    out.start_logo_buttons = .{
        .{ .name = "start_logo_choose", .kind = .{ .button = .{ .label = i18n.tr("Choose file…"), .owner = out, .on_click = &onChooseStartLogo, .state = if (folder_picker.running()) .disabled else .idle } }, .width = .auto, .min_width = 124, .height = .{ .fixed = 30 } },
        .{ .name = "start_logo_reset", .kind = .{ .button = .{ .label = i18n.tr("Reset to default"), .owner = out, .on_click = &onResetStartLogo, .state = if (t.start_button_icon.len == 0 or folder_picker.running()) .disabled else .idle } }, .width = .auto, .min_width = 140, .height = .{ .fixed = 30 } },
    };
    const logo = startLogoImage(out, arena, Taskbar.startIconSize());
    const logo_note: []const u8 = out.start_logo_error orelse blk: {
        if (t.start_button_icon.len == 0) break :blk i18n.tr("Default R logo · PNG or SVG");
        const name = std.fs.path.basename(t.start_button_icon);
        if (logo.failed) break :blk i18n.allocPrint(arena, i18n.tr("{name} could not be loaded · showing the default R"), .{ .name = name }) catch name;
        break :blk name;
    };
    // The logo sits on the taskbar, so it is shown on the taskbar's colour.
    var tile_bg = theme.taskbar(.taskbar_bg);
    tile_bg[3] = 1;
    out.start_logo_tile = .{.{
        .name = "start_logo_preview",
        .kind = .{ .image = logo.image },
        .width = .{ .fixed = @floatFromInt(logo.size) },
        .height = .{ .fixed = @floatFromInt(logo.size) },
    }};
    out.start_logo_info = .{
        .{ .name = "start_logo_file", .kind = .{ .text = .{ .content = logo_note, .font_size = theme.global.settings_description_size, .color = pal.dim } } },
        .{ .kind = .container, .direction = .row, .gap = 8, .children = &out.start_logo_buttons },
    };
    out.start_logo_body = .{
        .{
            .name = "start_logo_tile",
            .kind = .{ .rect = .{ .color = tile_bg, .radius = 10, .border_width = 1, .border_color = pal.border_soft } },
            .width = .{ .fixed = start_logo_tile_size },
            .height = .{ .fixed = start_logo_tile_size },
            .justify = .center,
            .@"align" = .center,
            .children = &out.start_logo_tile,
        },
        .{ .kind = .container, .direction = .column, .gap = 8, .justify = .center, .width = .{ .flex = 1 }, .children = &out.start_logo_info },
    };
    out.start_logo_children = .{
        labelWidget(i18n.tr("Start button logo")),
        .{ .kind = .container, .direction = .row, .gap = 12, .@"align" = .center, .children = &out.start_logo_body },
    };
    const logo_row: Widget = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.start_logo_children };
    out.start_size_children = .{
        .{ .name = "start_menu_size_note", .kind = .{ .text = .{ .content = if (menu_pinned) i18n.tr("Custom size") else i18n.tr("Sized to fit your screen · move a slider to set your own"), .font_size = theme.global.settings_description_size, .color = pal.dim } }, .width = .{ .flex = 1 } },
        .{ .name = "start_menu_size_auto", .kind = .{ .button = .{ .label = i18n.tr("Size to screen"), .owner = out, .on_click = &onAutoMenuSize, .state = if (menu_pinned) .idle else .disabled } }, .width = .auto, .min_width = 124, .height = .{ .fixed = 30 } },
    };
    const menu_size_row: Widget = .{ .kind = .container, .direction = .row, .gap = 8, .@"align" = .center, .children = &out.start_size_children };
    out.start_menu_section_children = .{ panel.sectionTitle(i18n.tr("Start menu")), logo_row, menu_width_row, menu_height_row, menu_size_row, menu_left_row, menu_bottom_row, icon_left_row, icon_bottom_row };
    const start_menu_section: Widget = .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.start_menu_section_children };
    return start_menu_section;
}

/// The theme pack actions and preview, and the icon theme picker; returns the pack controls.
pub fn buildThemePackRows(out: *Section, arena: std.mem.Allocator, server: *Server, pal: theme.Theme, matched_index: ?usize) []Widget {
    out.theme_actions = .{
        .{ .name = "theme_reset", .kind = .{ .button = .{ .label = i18n.tr("Reset to theme"), .owner = out, .on_click = &onResetTheme } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_install", .kind = .{ .button = .{ .label = i18n.tr("Install theme…"), .owner = out, .on_click = &onInstallTheme } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_remove", .kind = .{ .button = .{ .label = i18n.tr("Remove"), .owner = out, .on_click = &onRemoveTheme, .state = if (matched_index != null and out.presets[matched_index.?].user_installed) .idle else .disabled } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_export", .kind = .{ .button = .{ .label = i18n.tr("Save look…"), .owner = out, .on_click = &onExportTheme } }, .height = .{ .fixed = 32 } },
        .{ .name = "theme_replace", .kind = .{ .button = .{ .label = i18n.tr("Replace installed theme"), .owner = out, .on_click = &onReplaceTheme, .state = if (out.theme_pending_path != null) .idle else .disabled } }, .height = .{ .fixed = 32 } },
    };
    var pack_preview: Widget = .{ .kind = .container };
    out.theme_preview_pending = false;
    if (server.config.theme_pack) |pack| {
        if (pack.root.len > 0) {
            if (theme_presets.asset(arena, server.io, pack.root, "preview.png")) |path| {
                const result = server.iconLookup(path, 192);
                if (result == .ready) {
                    const entry = result.ready;
                    if (arena.dupe(u32, entry.pixels)) |pixels| {
                        pack_preview = .{ .name = "theme_preview", .kind = .{ .image = .{ .pixels = pixels, .width = entry.size, .height = entry.size, .fallback_icon = null } }, .width = .{ .fixed = 160 }, .height = .{ .fixed = 100 } };
                    } else |_| {}
                } else if (result == .pending) out.theme_preview_pending = true;
            } else |_| {}
        }
    }
    const pack_controls = arena.dupe(Widget, &.{
        .{ .kind = .container, .direction = .row, .gap = 8, .children = out.theme_actions[0..4] },
        .{ .kind = .{ .text = .{ .content = if (out.theme_message.len > 0) out.theme_message else i18n.tr("Packs include colours and artwork. Personal edits are saved as overrides."), .font_size = theme.global.app_status_size, .color = pal.dim } } },
        .{ .kind = .container, .children = if (out.theme_pending_path != null) out.theme_actions[4..5] else &.{} },
        pack_preview,
    }) catch @constCast(&[_]Widget{});
    const icon_themes = @import("../../icon_theme.zig").listNames(arena, server.io, server.icon_theme_cfg) catch &.{};
    out.icon_theme_names = icon_themes;
    const icon_labels = arena.dupe([]const u8, icon_themes) catch @constCast(icon_themes);
    if (icon_labels.len > 0) icon_labels[0] = i18n.tr("System default");
    var icon_selected: ?usize = null;
    for (icon_themes, 0..) |name, i| if (std.mem.eql(u8, name, server.config.compositor.icon_theme)) {
        icon_selected = i;
    };
    out.icon_theme_row = .{
        labelWidget(i18n.tr("Icon theme")),
        .{ .name = "icon_theme", .kind = .{ .select = .{ .labels = icon_labels, .selected = icon_selected, .placeholder = i18n.tr("Pack or system default"), .owner = out, .on_change = &onIconThemePicked } }, .width = .{ .fixed = segmented_width } },
    };
    return pack_controls;
}

/// The Dock section rows.
pub fn buildDockRows(out: *Section, server: *Server) void {
    out.dock_children = .{
        labelWidget(i18n.tr("RediWM dock")),
        .{ .name = "dock_enabled", .kind = .{ .toggle = .{ .on = out.cc.server.config.compositor.dock_enabled, .owner = out, .on_change = &onDockChanged } } },
    };
    out.dock_position_children = .{
        labelWidget(i18n.tr("Dock position")),
        .{ .name = "dock_position", .kind = .{ .segmented = .{ .labels = panel.translatedLabels(&.{ i18n.msg("Top"), i18n.msg("Bottom"), i18n.msg("Left"), i18n.msg("Right") }), .selected = @intFromEnum(server.config.compositor.dock_position), .owner = out, .on_change = &onDockPositionChanged } }, .width = .{ .fixed = segmented_width } },
    };
    out.dock_auto_hide_children = .{
        labelWidget(i18n.tr("Auto-hide dock")),
        .{ .name = "dock_auto_hide", .kind = .{ .toggle = .{ .on = server.config.compositor.dock_auto_hide, .owner = out, .on_change = &onDockAutoHideChanged } } },
    };
    const dock_height_row = pxGroup(out, px_dock_height, i18n.tr("Dock size"), @floatFromInt(server.config.compositor.dock_height), @floatFromInt(loader.dock_height_min), @floatFromInt(loader.dock_height_max), 2, &onDockHeightChanged);
    out.px[px_dock_height].group_children[1].name = "dock_height";
    const dock_zoom_row = pxGroup(out, px_dock_hover_zoom, i18n.tr("Dock hover zoom (1.00× disables)"), server.config.compositor.dock_hover_zoom, 1, loader.dock_hover_zoom_max, 0.05, &onDockHoverZoomChanged);
    out.px[px_dock_hover_zoom].group_children[1].name = "dock_hover_zoom";
    updateDockZoomLabel(out);
    // The slider shows the opacity the dock is drawn with, whether the theme or
    // `dock_opacity` set it; the radius, whether it is the dock's own or the windows'.
    const dock_pal = theme.shellPalette();
    const dock_opacity_row = unitGroup(out, px_dock_opacity, i18n.tr("Dock opacity"), @round(dock_mod.background(&server.config.compositor, dock_pal)[3] * 100), 0, 100, 1, &onDockOpacityChanged, "%");
    out.px[px_dock_opacity].group_children[1].name = "dock_opacity";
    const dock_radius_row = pxGroup(out, px_dock_radius, i18n.tr("Dock corner radius"), std.math.clamp(dock_mod.cornerRadius(dock_pal), dock_radius_min, dock_radius_max), dock_radius_min, dock_radius_max, 1, &PxHandler(px_dock_radius, "dock_radius", false).changed);
    out.px[px_dock_radius].group_children[1].name = "dock_radius";
    out.dock_active_children = .{
        labelWidget(i18n.tr("Highlight active app")),
        .{ .name = "dock_active_highlight", .kind = .{ .toggle = .{ .on = server.config.compositor.dock_active_highlight, .owner = out, .on_change = &onDockActiveHighlightChanged } } },
    };
    out.dock_trash_children = .{
        labelWidget(i18n.tr("Show Trash")),
        .{ .name = "dock_show_trash", .kind = .{ .toggle = .{ .on = server.config.compositor.dock_show_trash, .owner = out, .on_change = &onDockShowTrashChanged } } },
    };
    out.dock_group_children = .{
        panel.sectionTitle(i18n.tr("Dock")),
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_position_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_auto_hide_children },
        dock_height_row,
        dock_zoom_row,
        dock_opacity_row,
        dock_radius_row,
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_active_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dock_trash_children },
    };
}
