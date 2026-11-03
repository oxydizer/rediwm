const i18n = @import("i18n");
// Control center "Appearance" section: UI font, font size, and corner
// radius, all of which write back to REDIWM_THEME and hot-reload (design
// doc Part 3, Section 2), plus the apps' dark mode and the wallpaper, which
// are `[compositor] dark_mode` and `wallpaper` in config.toml.
//
// Widget callbacks carry their owning Section explicitly.
const std = @import("std");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const theme = @import("ui").theme;
const theme_presets = @import("config").theme_pack;
const Widget = layout.Widget;
const main = @import("../../main.zig");
const panel = @import("../panel.zig");
const loader = @import("config").loader;
const Taskbar = @import("../../Taskbar.zig");
const Server = @import("../../Server.zig");
const dock_mod = @import("../../Dock.zig");
const taskbar_items = @import("config").taskbar_items;
const cursor_theme = @import("../../cursor_theme.zig");
const wallpapers = @import("../../wallpapers.zig");
const wallpaper_strip = @import("../../wallpaper_strip.zig");
const folder_picker = @import("../folder_picker.zig");
const wl = @import("wayland").server.wl;
const anim = @import("ui").anim;
const col = @import("../../color.zig");
const geometry = @import("../../geometry.zig");
const start_button = @import("../../taskbar/start_button.zig");
const menu_size = @import("../../start_menu/size.zig");
const wlr = @import("wlroots");
const app_theme = @import("config").app_theme;
const AppColorsJob = @import("../../config_runtime/app_theme.zig").Job;
const appearance_wallpaper = @import("appearance_wallpaper.zig");
const appearance_colors = @import("appearance_colors.zig");
const appearance_themes = @import("appearance_themes.zig");
const appearance_chrome = @import("appearance_chrome.zig");
const appearance_items = @import("appearance_items.zig");
const appearance_dock = @import("appearance_dock.zig");
pub const tile_w = appearance_wallpaper.tile_w;
pub const tile_h = appearance_wallpaper.tile_h;
pub const tile_pad = appearance_wallpaper.tile_pad;
pub const tile_extent = appearance_wallpaper.tile_extent;
pub const strip_gap = appearance_wallpaper.strip_gap;
pub const check_size = appearance_wallpaper.check_size;
pub const chosen_dir = appearance_wallpaper.chosen_dir;
pub const stripFolder = appearance_wallpaper.stripFolder;
pub const tildePath = appearance_wallpaper.tildePath;
pub const stopStrip = appearance_wallpaper.stopStrip;
pub const deinit = appearance_wallpaper.deinit;
pub const appColorsNote = appearance_colors.appColorsNote;
pub const onApplyAppColors = appearance_colors.onApplyAppColors;
pub const appColorsFailure = appearance_colors.appColorsFailure;
pub const finishAppColors = appearance_colors.finishAppColors;
pub const appColorsReady = appearance_colors.appColorsReady;
pub const stripWake = appearance_wallpaper.stripWake;
pub const restartStrip = appearance_wallpaper.restartStrip;
pub const buildWallpaper = appearance_wallpaper.buildWallpaper;
pub const buildStrip = appearance_wallpaper.buildStrip;
pub const onStripTile = appearance_wallpaper.onStripTile;
pub const onStripCheck = appearance_wallpaper.onStripCheck;
pub const pickStripEntry = appearance_wallpaper.pickStripEntry;
pub const onWallpaperPicked = appearance_wallpaper.onWallpaperPicked;
pub const applyWallpaper = appearance_wallpaper.applyWallpaper;
pub const onChooseWallpaperFolder = appearance_wallpaper.onChooseWallpaperFolder;
pub const onFolderChosen = appearance_wallpaper.onFolderChosen;
pub const applyThemeChange = appearance_themes.applyThemeChange;
pub const applyThemeChangeImpl = appearance_themes.applyThemeChangeImpl;
pub const saveThemeChange = appearance_themes.saveThemeChange;
pub const onChooseStartLogo = appearance_themes.onChooseStartLogo;
pub const onStartLogoChosen = appearance_themes.onStartLogoChosen;
pub const onAutoMenuSize = appearance_themes.onAutoMenuSize;
pub const onResetStartLogo = appearance_themes.onResetStartLogo;
pub const refreshTheme = appearance_themes.refreshTheme;
pub const onResetTheme = appearance_themes.onResetTheme;
pub const themeFailure = appearance_themes.themeFailure;
pub const onInstallTheme = appearance_themes.onInstallTheme;
pub const themeFileChosen = appearance_themes.themeFileChosen;
pub const onReplaceTheme = appearance_themes.onReplaceTheme;
pub const onRemoveTheme = appearance_themes.onRemoveTheme;
pub const onExportTheme = appearance_themes.onExportTheme;
pub const exportFileChosen = appearance_themes.exportFileChosen;
pub const onIconThemePicked = appearance_themes.onIconThemePicked;
pub const onThemePicked = appearance_themes.onThemePicked;
pub const onTaskbarThemePicked = appearance_themes.onTaskbarThemePicked;
pub const ClockStyle = appearance_chrome.ClockStyle;
pub const onFontFamilyChanged = appearance_chrome.onFontFamilyChanged;
pub const onFontSizeChanged = appearance_chrome.onFontSizeChanged;
pub const onRadiusChanged = appearance_chrome.onRadiusChanged;
pub const onShadowChanged = appearance_chrome.onShadowChanged;
pub const onBorderGlowChanged = appearance_chrome.onBorderGlowChanged;
pub const onChromeOpacityChanged = appearance_chrome.onChromeOpacityChanged;
pub const onChromeDarknessChanged = appearance_chrome.onChromeDarknessChanged;
pub const onInactiveDimChanged = appearance_chrome.onInactiveDimChanged;
pub const onInactiveOpacityChanged = appearance_chrome.onInactiveOpacityChanged;
pub const onTerminalOpacityChanged = appearance_chrome.onTerminalOpacityChanged;
pub const max_window_gap = appearance_chrome.max_window_gap;
pub const onWindowGapChanged = appearance_chrome.onWindowGapChanged;
pub const onTaskbarPositionChanged = appearance_chrome.onTaskbarPositionChanged;
pub const onTaskbarAlignmentChanged = appearance_chrome.onTaskbarAlignmentChanged;
pub const onFocusZoomChanged = appearance_chrome.onFocusZoomChanged;
pub const onSwitcherStyleChanged = appearance_chrome.onSwitcherStyleChanged;
pub const onDragFeedbackChanged = appearance_chrome.onDragFeedbackChanged;
pub const onDragScaleChanged = appearance_chrome.onDragScaleChanged;
pub const onAnimationsEnabledChanged = appearance_chrome.onAnimationsEnabledChanged;
pub const onAnimSpeedChanged = appearance_chrome.onAnimSpeedChanged;
pub const onReducedMotionChanged = appearance_chrome.onReducedMotionChanged;
pub const onCursorThemePicked = appearance_chrome.onCursorThemePicked;
pub const onDarkModeChanged = appearance_chrome.onDarkModeChanged;
pub const onSplashStartupChanged = appearance_chrome.onSplashStartupChanged;
pub const onDodgeFileDragsChanged = appearance_chrome.onDodgeFileDragsChanged;
pub const saveItems = appearance_items.saveItems;
pub const item_row_height = appearance_items.item_row_height;
pub const itemRowStyle = appearance_items.itemRowStyle;
pub const itemZoneStyle = appearance_items.itemZoneStyle;
pub const itemName = appearance_items.itemName;
pub const syncItems = appearance_items.syncItems;
pub const itemHandle = appearance_items.itemHandle;
pub const beginItemDrag = appearance_items.beginItemDrag;
pub const previewItems = appearance_items.previewItems;
pub const moveItemDrag = appearance_items.moveItemDrag;
pub const endItemDrag = appearance_items.endItemDrag;
pub const restoreItemFocus = appearance_items.restoreItemFocus;
pub const captureItemFocus = appearance_items.captureItemFocus;
pub const itemKey = appearance_items.itemKey;
pub const ItemToggle = appearance_items.ItemToggle;
pub const buildWindowTabs = appearance_dock.buildWindowTabs;
pub const onWindowTabsChanged = appearance_dock.onWindowTabsChanged;
pub const section = appearance_dock.section;
pub const onDockChanged = appearance_dock.onDockChanged;
pub const onDockAutoHideChanged = appearance_dock.onDockAutoHideChanged;
pub const onDockOpacityChanged = appearance_dock.onDockOpacityChanged;
pub const onDockActiveHighlightChanged = appearance_dock.onDockActiveHighlightChanged;
pub const onDockShowTrashChanged = appearance_dock.onDockShowTrashChanged;
pub const onDockPositionChanged = appearance_dock.onDockPositionChanged;
pub const onDockHeightChanged = appearance_dock.onDockHeightChanged;
pub const updateDockZoomLabel = appearance_dock.updateDockZoomLabel;
pub const onDockHoverZoomChanged = appearance_dock.onDockHoverZoomChanged;

pub const segmented_width: f32 = 180;
/// The dock's corner radius slider. A theme's `dock_radius` of zero means "the
/// window radius", so the slider starts at 1 px (square to the eye) and a
/// chosen value is never mistaken for it. Half the tallest dock caps it.
pub const dock_radius_min: f32 = 1;
pub const dock_radius_max: f32 = 48;

pub const font_values = [3]f32{ 12, 13, 14 };
pub const font_labels = [_]i18n.Message{ i18n.msg("Small"), i18n.msg("Medium"), i18n.msg("Large") };
pub const radius_labels = [_]i18n.Message{ i18n.msg("Sharp"), i18n.msg("Default"), i18n.msg("Round") };
pub const shadow_size_values = [3]f32{ 0, 16, 32 };
pub const shadow_alpha_values = [3]f32{ 0, 0.28, 0.45 };
pub const shadow_labels = [_]i18n.Message{ i18n.msg("None"), i18n.msg("Soft"), i18n.msg("Strong") };
pub const anim_speed_values = [4]f32{ 0.5, 1.0, 1.5, 2.0 };
pub const anim_speed_labels = [_][]const u8{ "0.5×", "1.0×", "1.5×", "2.0×" };
pub const reduced_motion_values = [3]anim.ReducedMotion{ .auto, .on, .off };
pub const reduced_motion_labels = [_]i18n.Message{ i18n.msg("Auto"), i18n.msg("On"), i18n.msg("Off") };
pub const focus_zoom_labels = [_]i18n.Message{ i18n.msg("Keep zoom"), i18n.msg("Boost window"), i18n.msg("Focus camera") };
pub const focus_zoom_descriptions = [_]i18n.Message{
    i18n.msg("Pan to the selected window without changing zoom."),
    i18n.msg("Temporarily show the selected window at full size; keep desktop zoom."),
    i18n.msg("Zoom the desktop to the selected window's level; fade windows passed by the camera."),
};

pub fn indexOfReducedMotion(m: anim.ReducedMotion) usize {
    return switch (m) {
        .auto => 0,
        .on => 1,
        .off => 2,
    };
}

/// One "label + value" slider row (e.g. "Taskbar size ... 54px"), keyed by
/// index into `Section.px` below. Grouped into an array instead of one field
/// per control since the pixel sliders
/// are otherwise identical boilerplate.
pub const PxControl = struct {
    header_children: [2]Widget = undefined,
    group_children: [2]Widget = undefined,
    value_buf: [16]u8 = undefined,
};

pub const px_taskbar_size = 0;
pub const px_chip_gap = 1;
pub const px_start_button_gap = 2;
pub const px_start_icon_size = 3;
pub const px_menu_left = 4;
pub const px_menu_bottom = 5;
pub const px_icon_left = 6;
pub const px_icon_bottom = 7;
pub const px_scrollbar_width = 8;
pub const px_chip_width = 9;
pub const px_window_gap = 10;
pub const px_chrome_height = 11;
pub const px_chrome_control_gap = 12;
pub const px_menu_width = 13;
pub const px_menu_height = 14;
pub const px_dock_height = 15;
pub const px_dock_hover_zoom = 16;
pub const px_taskbar_edge_gap = 17;
pub const px_taskbar_length = 18;
pub const px_taskbar_radius = 19;
pub const px_dock_opacity = 20;
pub const px_dock_radius = 21;

pub const Section = struct {
    cc: *panel.ControlCenter = undefined,
    root: Widget = undefined,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    presets: []const theme_presets.Pack = &.{},
    top_children: [2]Widget = undefined,
    font_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    font_families: ?[][]const u8 = null,
    /// Installed cursor themes, scanned once per section like the fonts.
    cursor_themes: ?[]cursor_theme.Theme = null,
    cursor_row_children: [2]Widget = undefined,
    family_row_children: [2]Widget = undefined,
    row_storage: [row_count]Widget = undefined,
    /// The page: `groups`, each one card with a title over its rows.
    group_storage: [row_count + groups.len]Widget = undefined,
    group_cards: [groups.len]Widget = undefined,
    dock_children: [2]Widget = undefined,
    dock_position_children: [2]Widget = undefined,
    dock_auto_hide_children: [2]Widget = undefined,
    dock_active_children: [2]Widget = undefined,
    dock_trash_children: [2]Widget = undefined,
    dock_group_children: [10]Widget = undefined,
    focus_zoom_children: [3]Widget = undefined,
    switcher_style_children: [2]Widget = undefined,
    drag_feedback_children: [2]Widget = undefined,
    drag_scale_header_children: [2]Widget = undefined,
    drag_scale_children: [2]Widget = undefined,
    drag_scale_value_buf: [16]u8 = undefined,
    /// Rescanned on every build, so images added meanwhile show up.
    wallpapers: []const wallpapers.Entry = &.{},
    wallpaper_children: [3]Widget = undefined,
    /// What the wallpaper strip shows: the chosen folder's images, or
    /// the wallpaper directories'. Thumbnails decode on a worker.
    strip_entries: []const wallpapers.Entry = &.{},
    strip: ?*wallpaper_strip.Strip = null,
    strip_source: ?*wl.EventSource = null,
    /// `wallpaper_children[strip_index]` holds a scroll container to carry over.
    strip_built: bool = false,
    wallpaper_row_children: [2]Widget = undefined,
    wallpaper_footer_children: [2]Widget = undefined,
    theme_row_children: [2]Widget = undefined,
    theme_actions: [5]Widget = undefined,
    theme_preview_pending: bool = false,
    theme_message: []const u8 = "",
    theme_message_buf: [768]u8 = undefined,
    theme_pending_path: ?[]u8 = null,
    icon_theme_row: [2]Widget = undefined,
    icon_theme_names: []const []const u8 = &.{},

    taskbar_theme_row_children: [2]Widget = undefined,
    app_colors_children: [3]Widget = undefined,
    app_colors_buttons: [2]Widget = undefined,
    app_colors_job: ?*AppColorsJob = null,
    app_colors_source: ?*wl.EventSource = null,
    app_colors_message: []const u8 = "",
    app_colors_message_buf: [384]u8 = undefined,
    dark_row_children: [2]Widget = undefined,
    dark_label_children: [2]Widget = undefined,
    splash_row_children: [2]Widget = undefined,
    splash_label_children: [2]Widget = undefined,
    dodge_row_children: [2]Widget = undefined,
    dodge_label_children: [2]Widget = undefined,
    dim_row_children: [2]Widget = undefined,
    dim_label_children: [2]Widget = undefined,
    anim_enabled_row_children: [2]Widget = undefined,
    anim_enabled_label_children: [2]Widget = undefined,
    anim_speed_row_children: [2]Widget = undefined,
    reduced_motion_row_children: [2]Widget = undefined,
    effect_row_children: [3][2]Widget = undefined,
    effect_label_children: [3][2]Widget = undefined,
    font_row_children: [2]Widget = undefined,
    radius_row_children: [2]Widget = undefined,
    shadow_row_children: [2]Widget = undefined,
    glow_row_children: [2]Widget = undefined,
    glow_label_children: [2]Widget = undefined,
    opacity_header_children: [2]Widget = undefined,
    opacity_group_children: [2]Widget = undefined,
    opacity_value_buf: [16]u8 = undefined,
    darkness_header_children: [2]Widget = undefined,
    darkness_group_children: [2]Widget = undefined,
    darkness_value_buf: [16]u8 = undefined,
    /// Chrome geometry and tint share one card.
    chrome_group_children: [4]Widget = undefined,
    tabs_children: [3]Widget = undefined,
    tabs_built: bool = false,
    tabs_scroll: @import("ui").layout.ScrollState = .{},
    inactive_opacity_header_children: [2]Widget = undefined,
    inactive_opacity_group_children: [2]Widget = undefined,
    inactive_opacity_value_buf: [16]u8 = undefined,
    terminal_opacity_header_children: [2]Widget = undefined,
    terminal_opacity_group_children: [2]Widget = undefined,
    terminal_opacity_value_buf: [16]u8 = undefined,
    px: [22]PxControl = undefined,
    taskbar_section_children: [14]Widget = undefined,
    taskbar_position_children: [2]Widget = undefined,
    taskbar_alignment_children: [2]Widget = undefined,
    clock_bold_children: [2]Widget = undefined,
    clock_italic_children: [2]Widget = undefined,
    items_children: [6]Widget = undefined,
    /// Per section: its title and the well that holds its rows.
    items_section_children: [3][2]Widget = undefined,
    /// What an empty well shows instead of rows.
    items_placeholder: [3][1]Widget = undefined,
    /// Spacer, text, spacer: centred, since a lone text in a row is flexed.
    items_placeholder_body: [3][3]Widget = undefined,
    /// Rows follow `order`; `syncItems` hands each well its run of them.
    item_rows: [taskbar_items.count]Widget = undefined,
    /// Grip, label, section selector, visibility toggle.
    item_controls: [taskbar_items.count][4]Widget = undefined,
    item_drag: ?struct { index: usize, press_y: f32, moved: bool = false, items: taskbar_items.Config } = null,
    item_focus: ?taskbar_items.Item = null,
    start_menu_section_children: [9]Widget = undefined,
    start_size_children: [2]Widget = undefined,
    start_logo_children: [2]Widget = undefined,
    start_logo_body: [2]Widget = undefined,
    start_logo_tile: [1]Widget = undefined,
    start_logo_info: [2]Widget = undefined,
    start_logo_buttons: [2]Widget = undefined,
    start_logo_error: ?[]const u8 = null,
    /// The preview is waiting on the icon service; `iconsReady` rebuilds.
    start_logo_pending: bool = false,
};

/// Slider ranges for the start menu's size. They only bound what the sliders
/// offer: `StartMenu.relayout` caps both to the output and floors them at
/// 320 x 240, which a hand-edited theme can still reach but leaves one row.
/// Until a slider is moved the theme holds 0 and the menu is sized to the
/// output (`start_menu/size.zig`); the sliders show that size.
pub const menu_width_min = menu_size.min_width;
pub const menu_width_max: f32 = 900;
pub const menu_height_min = menu_size.min_height;
pub const menu_height_max: f32 = 900;
pub const start_logo_tile_size: f32 = 56;

pub const StartLogo = struct {
    image: layout.ImageData,
    /// Logical size the image is drawn at.
    size: i32,
    /// A chosen file failed to load, so `image` is the bundled logo.
    failed: bool,
};

/// The logo the taskbar is showing: the chosen file, else the bundled R (also
/// when the file cannot be loaded), with the bundled one tinted the way
/// `Taskbar.paintPartPixel` tints it. Mirrors `Taskbar.refreshStartLogo`.
/// Pixels are copied into `a`, so nothing is pinned in the icon service.
pub fn startLogoImage(out: *Section, a: std.mem.Allocator, logical: i32) StartLogo {
    const server = out.cc.server;
    const custom = theme.global.start_button_icon;
    const size_px = geometry.devicePixels(logical, out.cc.toplevel.render_scale);
    var result: StartLogo = .{ .image = .{ .fallback_icon = null }, .size = logical, .failed = false };
    out.start_logo_pending = false;

    var lookup = server.iconLookup(if (custom.len > 0) custom else start_button.builtin_logo, size_px);
    if (lookup == .missing and custom.len > 0) {
        result.failed = true;
        lookup = server.iconLookup(start_button.builtin_logo, size_px);
    }
    const entry = switch (lookup) {
        .ready => |e| e,
        .pending => {
            out.start_logo_pending = true;
            return result;
        },
        .missing => return result,
    };
    const pixels = a.dupe(u32, entry.pixels) catch return result;
    if (custom.len == 0) {
        if (theme.taskbar(.start_button_logo_color)) |tint| {
            for (pixels) |*pixel| {
                var c = col.Straight.fromRgba(tint);
                c.a *= @as(f32, @floatFromInt(pixel.* >> 24)) / 255.0;
                pixel.* = c.argb();
            }
        }
    }
    result.image = .{ .pixels = pixels, .width = entry.size, .height = entry.size, .fallback_icon = null };
    return result;
}

/// A decode finished: a preview that was waiting for one can now show it.
pub fn iconsReady(s: *Section) void {
    if ((s.start_logo_pending or s.theme_preview_pending) and s.cc.page == .appearance) s.cc.refresh();
}

pub fn indexOfNearest(values: []const f32, v: f32) usize {
    var best: usize = 0;
    var best_d = @abs(values[0] - v);
    for (values, 0..) |candidate, i| {
        const d = @abs(candidate - v);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

pub fn labelWidget(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = theme.global.app_text_size, .weight = 600, .color = t.fg } } };
}

pub fn valueWidget(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = theme.global.app_text_size, .color = t.dim } } };
}

/// The readout beside a slider, in a rounded label.
pub fn pillWidget(content: []const u8) Widget {
    return ui_slider.valuePill(content, theme.global.app_text_size, panel.palette().dim);
}

pub fn sectionLabel(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = theme.global.app_heading_size, .weight = 700, .color = t.dim } } };
}

/// Builds one "label ... value / slider" pixel-value row and formats its
/// initial value into `out.px[idx].value_buf`.
pub fn pxGroup(out: *Section, idx: usize, label_text: []const u8, value: f32, min: f32, max: f32, step: f32, on_change: *const fn (?*anyopaque, usize, f32) void) Widget {
    return unitGroup(out, idx, label_text, value, min, max, step, on_change, "px");
}

/// `pxGroup` for a value that isn't in pixels, such as a percentage.
pub fn unitGroup(out: *Section, idx: usize, label_text: []const u8, value: f32, min: f32, max: f32, step: f32, on_change: *const fn (?*anyopaque, usize, f32) void, unit: []const u8) Widget {
    const formatted = std.fmt.bufPrint(&out.px[idx].value_buf, "{d}{s}", .{ @as(i32, @intFromFloat(@round(value))), unit }) catch "?";
    out.px[idx].header_children = .{ labelWidget(label_text), pillWidget(formatted) };
    const header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.px[idx].header_children };
    const slider: Widget = .{ .kind = .{ .slider = .{ .value = value, .min = min, .max = max, .step = step, .owner = out, .on_change = on_change } } };
    out.px[idx].group_children = .{ header, slider };
    return .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.px[idx].group_children };
}

/// Comptime-specialized `on_change` handler for `Section.px[idx]`, writing
/// straight to `theme.global.<field>`. Each (idx, field) instantiation is a
/// distinct function; the callback owner identifies the section.
/// `taskbar_geometry` picks
/// which of applyThemeChange's two taskbar-refresh paths to use: the
/// fields that resize taskbar items (taskbar_size, chip_width, chip_gap,
/// start_button_gap, start_button_icon_size) need the full relayout since
/// they can change item sizes without changing `bar.box.height`, the only
/// thing the cheap height-guarded refresh notices; the start-menu-popup
/// padding fields don't touch taskbar geometry at all.
pub fn PxHandler(comptime idx: usize, comptime field: []const u8, comptime taskbar_geometry: bool) type {
    return UnitHandler(idx, field, taskbar_geometry, "px");
}

pub fn UnitHandler(comptime idx: usize, comptime field: []const u8, comptime taskbar_geometry: bool, comptime unit: []const u8) type {
    return struct {
        pub fn changed(owner: ?*anyopaque, _: usize, value: f32) void {
            const s = section(owner);
            @field(theme.global, field) = value;
            const formatted = std.fmt.bufPrint(&s.px[idx].value_buf, "{d}" ++ unit, .{@as(i32, @intFromFloat(@round(value)))}) catch "?";
            s.px[idx].header_children[1].kind.text.content = formatted;
            s.px[idx].header_children[1].markDirty();
            applyThemeChangeImpl(section(owner), taskbar_geometry);
        }
    };
}

pub fn build(out: *Section, cc: *panel.ControlCenter) void {
    out.item_drag = null;
    out.cc = cc;
    if (out.tabs_built and out.tabs_children[2].kind == .scroll_container) out.tabs_scroll = out.tabs_children[2].kind.scroll_container;
    _ = out.arena.reset(.free_all);
    const t = theme.global;
    const server = out.cc.server;
    const arena = out.arena.allocator();

    const matched_index = buildThemeRows(out, arena);

    buildWallpaper(out, arena);

    const pal = panel.palette();
    buildColorRows(out, arena, pal);

    buildBehaviorRows(out, pal);
    buildEffectRows(out, pal);

    buildFontRows(out, arena, t, pal);

    const chrome_row = buildChromeRow(out, t);

    const inactive_opacity_row = inactiveOpacityRow(out);

    const terminal_opacity_row = terminalOpacityRow(out);

    const gap_val: f32 = @floatFromInt(@min(out.cc.server.config.compositor.windowGap(), max_window_gap));
    const window_gap_row = pxGroup(out, px_window_gap, i18n.tr("Snapped window gap"), gap_val, 0, max_window_gap, 1, &onWindowGapChanged);

    const taskbar_section = buildTaskbarSection(out, t, pal);

    const start_menu_section = buildStartMenuSection(out, arena, t, pal);

    const pack_controls = buildThemePackRows(out, arena, server, pal, matched_index);
    buildDockRows(out, server);
    out.row_storage = .{
        .{ .kind = .container, .direction = .column, .gap = 8, .children = pack_controls },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.icon_theme_row },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.theme_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.taskbar_theme_row_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.app_colors_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dark_row_children },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.wallpaper_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.splash_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dodge_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.anim_enabled_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.anim_speed_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.reduced_motion_row_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.focus_zoom_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.switcher_style_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.drag_feedback_children },
        .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.drag_scale_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.effect_row_children[0] },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.effect_row_children[1] },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.effect_row_children[2] },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.cursor_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.family_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.font_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.radius_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.shadow_row_children },
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.glow_row_children },
        chrome_row,
        buildWindowTabs(out),
        .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.dim_row_children },
        inactive_opacity_row,
        terminal_opacity_row,
        window_gap_row,
        pxGroup(out, px_scrollbar_width, i18n.tr("Scrollbar width"), t.scrollbar_width, 4, 24, 1, &PxHandler(px_scrollbar_width, "scrollbar_width", false).changed),
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.dock_group_children },
        taskbar_section,
        start_menu_section,
    };
    var at: usize = 0;
    for (groups, &out.group_cards) |group, *card| {
        const start = at;
        if (group.title) |title| {
            out.group_storage[at] = panel.sectionTitle(title.get());
            at += 1;
        }
        for (group.rows) |row| {
            out.group_storage[at] = out.row_storage[@intFromEnum(row)];
            at += 1;
        }
        // An untitled group is one row that brings its own title.
        card.* = if (group.title == null) out.group_storage[start] else .{ .kind = .container, .direction = .column, .gap = 16, .children = out.group_storage[start..at] };
    }
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("APPEARANCE"), .font_size = theme.global.app_heading_size, .weight = 700, .color = pal.dim } } },
        .{ .kind = .container, .direction = .column, .gap = 12, .children = &out.group_cards },
    };
    out.root = .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
}

const appearance_rows = @import("appearance_rows.zig");
const buildThemeRows = appearance_rows.buildThemeRows;
const buildColorRows = appearance_rows.buildColorRows;
const buildBehaviorRows = appearance_rows.buildBehaviorRows;
const buildEffectRows = appearance_rows.buildEffectRows;
const buildFontRows = appearance_rows.buildFontRows;
const buildChromeRow = appearance_rows.buildChromeRow;
const inactiveOpacityRow = appearance_rows.inactiveOpacityRow;
const terminalOpacityRow = appearance_rows.terminalOpacityRow;

const appearance_sections = @import("appearance_sections.zig");
const buildTaskbarSection = appearance_sections.buildTaskbarSection;
const buildStartMenuSection = appearance_sections.buildStartMenuSection;
const buildThemePackRows = appearance_sections.buildThemePackRows;
const buildDockRows = appearance_sections.buildDockRows;

pub const strip_index = 1;

/// `row_storage`, in the order `build` fills it.
pub const Row = enum {
    theme_pack,
    icon_theme,
    theme,
    taskbar_theme,
    app_colors,
    dark_mode,
    wallpaper,
    launch_splash,
    dodge_file_drags,
    animations,
    animation_speed,
    reduced_motion,
    focus_zoom,
    switcher_style,
    drag_feedback,
    drag_scale,
    effect_window_move,
    effect_window_resize,
    effect_window_minimize,
    cursor,
    font_family,
    font_size,
    radius,
    shadow,
    edge_glow,
    chrome_opacity,
    window_tabs,
    inactive_dim,
    inactive_opacity,
    terminal_opacity,
    window_gap,
    scrollbar_width,
    dock,
    taskbar,
    start_menu,
};
pub const row_count = @typeInfo(Row).@"enum".field_names.len;

pub const groups = [_]struct { title: ?i18n.Message, rows: []const Row }{
    .{ .title = i18n.msg("Themes & colours"), .rows = &.{ .theme, .taskbar_theme, .theme_pack, .icon_theme, .dark_mode, .app_colors } },
    .{ .title = i18n.msg("Wallpaper"), .rows = &.{.wallpaper} },
    .{ .title = i18n.msg("Fonts & cursor"), .rows = &.{ .font_family, .font_size, .cursor } },
    .{ .title = i18n.msg("Windows"), .rows = &.{ .radius, .shadow, .edge_glow, .chrome_opacity, .window_tabs, .inactive_dim, .inactive_opacity, .terminal_opacity, .window_gap, .scrollbar_width } },
    .{ .title = i18n.msg("Motion & feedback"), .rows = &.{ .animations, .animation_speed, .reduced_motion, .focus_zoom, .switcher_style, .drag_feedback, .drag_scale, .dodge_file_drags, .launch_splash } },
    .{ .title = i18n.msg("Effects"), .rows = &.{ .effect_window_move, .effect_window_resize, .effect_window_minimize } },
    .{ .title = null, .rows = &.{.dock} },
    .{ .title = null, .rows = &.{.taskbar} },
    .{ .title = null, .rows = &.{.start_menu} },
};

comptime {
    // Every row is shown exactly once.
    var seen = @as([row_count]bool, @splat(false));
    for (groups) |group| for (group.rows) |row| {
        if (seen[@intFromEnum(row)]) @compileError("row in two groups: " ++ @tagName(row));
        seen[@intFromEnum(row)] = true;
    };
    for (seen, 0..) |shown, i| if (!shown) @compileError("row in no group: " ++ @tagName(@as(Row, @enumFromInt(i))));
}
