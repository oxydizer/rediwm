// A deliberately tiny TOML reader for the shell-chrome theme file: only a
// `[theme]` section header, bare numeric/boolean values, and quoted string values
// (colors as "#rrggbb"/"#rrggbbaa" or "rgba(r,g,b,a)", font names as plain
// strings). No arrays, tables-of-tables, dates, or multi-line strings — the
// token set below is everything this engine actually reads.
//
// Widgets read colors and sizes from `global` at construction/paint time.
// Config reload rebuilds or invalidates retained UI when any token changes;
// standalone clients use their own settings loader.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.theme);

// `parseColor` itself (below) is only used at runtime: `std.fmt.parseFloat`
// blows comptime's default 1000-backwards-branch quota, so these defaults —
// sourced from interface3d/styles.css — are spelled as plain
// comptime-cheap division instead of `parseColor(...) catch unreachable`.
pub const Theme = struct {
    font: []const u8 = "Manrope",
    mono_font: []const u8 = "JetBrains Mono",
    // Empty uses the bundled Redi SVG; otherwise an absolute icon path.
    start_button_icon: []const u8 = "",
    /// Unset preserves the bundled SVG colours; custom icons keep their colours.
    start_button_logo_color: ?[4]f32 = null,
    font_size: f32 = 13.0,
    radius: f32 = 5.0, // --r-sm (buttons/taskbar chips)
    radius_md: f32 = 7.0,
    radius_lg: f32 = 10.0,
    title_size: f32 = 13.5,
    /// Window titlebar height; icons and controls scale with it.
    chrome_height: f32 = 46.0,
    /// Space between window controls, independent of their size.
    chrome_control_gap: f32 = 4.0,
    /// Circular window controls and pill-shaped tabs, including tab controls.
    chrome_round_buttons: bool = false,
    // Window decorations use neutral charcoal independently of shell glass.
    window_bg: [4]f32 = .{ @as(f32, 7.6) / 255.0, 9.0 / 255.0, 11.0 / 255.0, 0.80 }, // 80% darkness and opacity
    // Neutral foregrounds keep text and monochrome icons free of a blue tint.
    window_fg: [4]f32 = .{ 245.0 / 255.0, 245.0 / 255.0, 245.0 / 255.0, 1 }, // #f5f5f5
    window_dim: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6
    window_border: [4]f32 = .{ 1, 1, 1, 0.09 },
    window_border_hover: [4]f32 = .{ 1, 1, 1, 0.13 },
    window_divider: [4]f32 = .{ 1, 1, 1, 0.045 },
    window_close_hover: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 1 },
    // App windows (Files, Images, PDF). All their text is `window_fg`
    // (`window_dim`/`text_secondary` stay for shell popups), menus
    // `window_bg`, red accents the shell palette's accent.
    text_secondary: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6
    app_bg: [4]f32 = .{ 24.0 / 255.0, 28.0 / 255.0, 34.0 / 255.0, 1 }, // #181c22, main content
    app_toolbar: [4]f32 = .{ 29.0 / 255.0, 34.0 / 255.0, 41.0 / 255.0, 1 }, // #1d2229
    app_sidebar: [4]f32 = .{ 27.0 / 255.0, 33.0 / 255.0, 40.0 / 255.0, 1 }, // #1b2128
    app_bar: [4]f32 = .{ 35.0 / 255.0, 42.0 / 255.0, 51.0 / 255.0, 1 }, // #232a33, column headers, status bars
    app_item: [4]f32 = .{ 34.0 / 255.0, 40.0 / 255.0, 46.0 / 255.0, 1 }, // #22282e, rows, cards, thumbnails
    app_item_hover: [4]f32 = .{ 37.0 / 255.0, 43.0 / 255.0, 50.0 / 255.0, 1 }, // #252b32
    app_item_border: [4]f32 = .{ 45.0 / 255.0, 51.0 / 255.0, 58.0 / 255.0, 1 }, // #2d333a
    app_item_selected: [4]f32 = .{ 78.0 / 255.0, 37.0 / 255.0, 46.0 / 255.0, 1 }, // #4e252e
    app_nav_selected: [4]f32 = .{ 91.0 / 255.0, 36.0 / 255.0, 46.0 / 255.0, 1 }, // #5b242e, sidebar and menu rows
    app_git_added: [4]f32 = .{ 34.0 / 255.0, 197.0 / 255.0, 94.0 / 255.0, 1 }, // #22c55e, added lines
    app_divider: [4]f32 = .{ 55.0 / 255.0, 63.0 / 255.0, 72.0 / 255.0, 1 }, // #373f48
    app_icon: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6, sidebar glyphs
    scrollbar_thumb: [4]f32 = .{ 89.0 / 255.0, 98.0 / 255.0, 110.0 / 255.0, 1 }, // #59626e
    /// Unset follows the surface accent during hover/drag.
    scrollbar_thumb_active: ?[4]f32 = null,
    taskbar_title_size: f32 = 12.5,
    taskbar_size: f32 = 44.0,
    // Gap between adjacent taskbar window-item pills, logical px. Also
    // drives each pill's top/bottom margin within the bar (capped — see
    // Taskbar.chipVerticalMargin), so one slider spaces pills on every side
    // at once instead of only widening the horizontal gap between them.
    chip_gap: f32 = 4.0,
    // Preferred window-button width; crowded taskbars shrink buttons to fit.
    chip_width: f32 = 220.0,
    // Gap between the start button and the first taskbar chip, logical px.
    start_button_gap: f32 = 4.0,
    // Size of the start button's icon/logo, logical px. Clamped to the
    // button's own size at paint time (Taskbar.startIconSize), so it also
    // shrinks if `taskbar_size` shrinks the button below this.
    start_button_icon_size: f32 = 36.0,
    button_font_size: f32 = 12.5,
    bg: [4]f32 = .{ 9.0 / 255.0, 11.0 / 255.0, 24.0 / 255.0, 1 }, // #090b18
    fg: [4]f32 = .{ 245.0 / 255.0, 245.0 / 255.0, 245.0 / 255.0, 1 }, // #f5f5f5
    dim: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6
    faint: [4]f32 = .{ 160.0 / 255.0, 160.0 / 255.0, 160.0 / 255.0, 1 }, // #a0a0a0
    accent: [4]f32 = .{ 94.0 / 255.0, 234.0 / 255.0, 212.0 / 255.0, 1 }, // #5eead4
    surface: [4]f32 = .{ 1, 1, 1, 0.05 }, // --glass-soft
    border: [4]f32 = .{ 1, 1, 1, 0.09 }, // --border
    accent_2: [4]f32 = .{ 167.0 / 255.0, 139.0 / 255.0, 250.0 / 255.0, 1 },
    accent_3: [4]f32 = .{ 244.0 / 255.0, 114.0 / 255.0, 182.0 / 255.0, 1 },
    danger: [4]f32 = .{ 248.0 / 255.0, 113.0 / 255.0, 113.0 / 255.0, 1 },
    glass: [4]f32 = .{ 15.0 / 255.0, 19.0 / 255.0, 38.0 / 255.0, 0.56 },
    glass_strong: [4]f32 = .{ 12.0 / 255.0, 15.0 / 255.0, 30.0 / 255.0, 0.74 },
    taskbar_bg: [4]f32 = .{ 24.0 / 255.0, 28.0 / 255.0, 34.0 / 255.0, 0.96 }, // #181c22
    border_soft: [4]f32 = .{ 1, 1, 1, 0.06 },
    border_hover: [4]f32 = .{ 1, 1, 1, 0.22 },
    surface_hover: [4]f32 = .{ 1, 1, 1, 0.08 },
    taskbar_surface: [4]f32 = .{ 1, 1, 1, 0.025 },
    taskbar_hover: [4]f32 = .{ 1, 1, 1, 0.05 },
    taskbar_border: [4]f32 = .{ 1, 1, 1, 0.07 },
    on_accent: [4]f32 = .{ 8.0 / 255.0, 33.0 / 255.0, 28.0 / 255.0, 1 },
    border_focus: [4]f32 = .{ 94.0 / 255.0, 234.0 / 255.0, 212.0 / 255.0, 0.40 }, // rgba(94,234,212,0.40)
    // Text insertion caret (paint.zig's `paintTextInput`), not the mouse
    // pointer. Null means "whatever accent is in effect here", which is what
    // the caret used literally before this token existed — and panels remap
    // `accent` for their own palette (`start_menu.menuPalette`), so a
    // concrete default would have quietly recoloured the start menu's caret.
    // Setting `caret` in the file overrides that everywhere.
    caret: ?[4]f32 = null,
    caret_width: f32 = 1.5,
    scrollbar_width: f32 = 8.0, // logical pixels, shared by every scrollbar (widgets/scrollbar.zig)
    /// Highlight behind selected text. Null follows the accent in effect at
    /// `selection_alpha`, for the same reason `caret` does — panels remap
    /// `accent`, and a selection that ignored that would clash with the field
    /// it sits in.
    selection: ?[4]f32 = null,
    selection_alpha: f32 = 0.35,
    /// Colour of the selected text itself. Null leaves it as it was: a
    /// translucent highlight reads fine over unchanged text, and inverting
    /// only helps once the highlight is opaque.
    selection_fg: ?[4]f32 = null,
    /// Text fields (`ui/widgets/field.zig`). The start menu's search box is
    /// the reference look; it swaps in `start_menu_search_bg` for its own.
    field_bg: [4]f32 = .{ 21.0 / 255.0, 26.0 / 255.0, 31.0 / 255.0, 1 }, // #151a1f
    field_border: [4]f32 = .{ 63.0 / 255.0, 70.0 / 255.0, 77.0 / 255.0, 1 }, // #3f464d
    /// Border of the focused field. Null follows the accent in effect, for
    /// the same reason `caret` does.
    field_border_focus: ?[4]f32 = null,
    field_radius: f32 = 8.0,
    shadow: [4]f32 = .{ 0, 0, 0, 0.35 },
    shadow_size: f32 = 24.0, // blur/softness radius, logical px
    shadow_offset_y: f32 = 8.0, // vertical offset, logical px
    // 0 sizes the menu to the output (`start_menu/size.zig`); set either to pin it.
    start_menu_width: f32 = 0,
    start_menu_max_height: f32 = 0,
    start_menu_radius: f32 = 14.0,
    start_menu_bg: [4]f32 = .{ 29.0 / 255.0, 34.0 / 255.0, 41.0 / 255.0, 0.98 }, // #1d2229
    start_menu_border: [4]f32 = .{ 1, 1, 1, 0.12 },
    start_menu_search_bg: [4]f32 = .{ 21.0 / 255.0, 26.0 / 255.0, 31.0 / 255.0, 1 },
    start_menu_selected_bg: [4]f32 = .{ 1, 1, 1, 0.045 },
    start_menu_selected_border: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 0.35 },
    start_menu_selected_marker: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 1 },
    // Outer panel position, logical px from the output's left/bottom edges
    // (bottom is on top of the taskbar's own height).
    start_menu_left_pad: f32 = 2.0,
    start_menu_bottom_pad: f32 = 6.0,
    // Inset applied to each app row (icon + label together), logical px.
    start_menu_icon_left_pad: f32 = 12.0,
    start_menu_icon_bottom_pad: f32 = 6.0,

    // Additional appearance tokens. All fields are parsed and saved through
    // the type-derived key lists below; defaults preserve the stock look.
    toggle_track: [4]f32 = .{ 1, 1, 1, 0.12 },
    control_thumb: [4]f32 = .{ 1, 1, 1, 1 },
    slider_track: [4]f32 = .{ 1, 1, 1, 0.08 },
    pill_bg: [4]f32 = .{ 1, 1, 1, 0.05 },
    swatch_border: [4]f32 = .{ 1, 1, 1, 0.10 },
    swatch_border_selected: [4]f32 = .{ 1, 1, 1, 0.6 },
    settings_card_bg: [4]f32 = .{ 1, 1, 1, 0.025 },
    lock_bg: [4]f32 = .{ 0.015, 0.018, 0.028, 1 },
    lock_fg: [4]f32 = .{ 0.97, 0.97, 0.98, 1 },
    lock_dim: [4]f32 = .{ 0.66, 0.68, 0.73, 1 },
    lock_divider: [4]f32 = .{ 0.3, 0.32, 0.36, 0.6 },
    lock_session_fg: [4]f32 = .{ 0.86, 0.87, 0.9, 1 },
    switcher_bg: [4]f32 = .{ 0.035, 0.04, 0.055, 1 },
    switcher_border: [4]f32 = .{ 0.6, 0.2, 0.26, 0.65 },
    switcher_item_bg: [4]f32 = .{ 0.09, 0.10, 0.12, 1 },
    switcher_item_border: [4]f32 = .{ 1, 1, 1, 0.13 },
    switcher_fg: [4]f32 = .{ 0.94, 0.95, 0.97, 1 },
    switcher_dim: [4]f32 = .{ 0.6, 0.62, 0.66, 1 },
    switcher_icon_bg: [4]f32 = .{ 0.10, 0.11, 0.13, 1 },
    switcher_selected_border: [4]f32 = .{ 1, 0.12, 0.20, 1 },
    calendar_border: [4]f32 = .{ 1, 1, 1, 0.16 },
    osd_border: [4]f32 = .{ 1, 1, 1, 0.12 },
    screenshot_shade: [4]f32 = .{ 0, 0, 0, 0.36 },
    screenshot_border: [4]f32 = .{ 1, 6.0 / 255.0, 23.0 / 255.0, 1 },
    screenshot_fg: [4]f32 = .{ 1, 1, 1, 1 },
    screenshot_label_bg: [4]f32 = .{ 0.04, 0.05, 0.06, 0.95 },
    screenshot_label_border: [4]f32 = .{ 1, 1, 1, 0.2 },
    battery_bg: [4]f32 = .{ 0.02, 0.04, 0.04, 0.28 },
    battery_full: [4]f32 = .{ 32.0 / 255.0, 226.0 / 255.0, 157.0 / 255.0, 1 },
    battery_low: [4]f32 = .{ 250.0 / 255.0, 204.0 / 255.0, 65.0 / 255.0, 1 },
    battery_critical: [4]f32 = .{ 245.0 / 255.0, 75.0 / 255.0, 85.0 / 255.0, 1 },
    battery_shimmer: [4]f32 = .{ 110.0 / 255.0, 1, 200.0 / 255.0, 1 },
    desktop_fg: [4]f32 = .{ 238.0 / 255.0, 241.0 / 255.0, 251.0 / 255.0, 1 },
    desktop_text_shadow: [4]f32 = .{ 0, 0, 0, 0.22 },
    desktop_hover: [4]f32 = .{ 1, 1, 1, 0.06 },
    desktop_selected: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 0.12 },
    desktop_selection: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 0.15 },
    desktop_selection_border: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 1 },
    desktop_drop_border: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 0.8 },
    desktop_dialog_bg: [4]f32 = .{ 0.035, 0.043, 0.094, 0.98 },
    desktop_notice_bg: [4]f32 = .{ 0.12, 0.035, 0.06, 0.95 },
    desktop_icon_start: [4]f32 = .{ 0.25, 0.65, 0.66, 1 },
    desktop_icon_end: [4]f32 = .{ 0.35, 0.31, 0.62, 1 },
    file_broken: [4]f32 = .{ 239.0 / 255.0, 68.0 / 255.0, 68.0 / 255.0, 1 },
    file_folder_back: [4]f32 = .{ 0.64, 0.67, 0.71, 1 },
    file_folder_front: [4]f32 = .{ 0.72, 0.75, 0.79, 1 },
    file_document: [4]f32 = .{ 148.0 / 255.0, 163.0 / 255.0, 184.0 / 255.0, 1 },
    file_document_lines: [4]f32 = .{ 203.0 / 255.0, 213.0 / 255.0, 225.0 / 255.0, 1 },
    file_spinner: [4]f32 = .{ 0.65, 0.68, 0.72, 1 },
    image_checker_dark: [4]f32 = .{ 0.13, 0.14, 0.15, 1 },
    image_checker_light: [4]f32 = .{ 0.17, 0.18, 0.19, 1 },
    image_crop_shade: [4]f32 = .{ 0, 0, 0, 0.58 },
    image_crop_border: [4]f32 = .{ 1, 1, 1, 1 },
    image_crop_grid: [4]f32 = .{ 1, 1, 1, 0.4 },
    image_dialog_backdrop: [4]f32 = .{ 0, 0, 0, 0.65 },
    pdf_page_shadow: [4]f32 = .{ 0, 0, 0, 0.35 },
    pdf_page_border: [4]f32 = .{ 0, 0, 0, 0.15 },
    pdf_loading: [4]f32 = .{ 0.6, 0.6, 0.6, 1 },
    pdf_search_match: [4]f32 = .{ 1, 0.90, 0, 0.40 },
    pdf_search_match_active: [4]f32 = .{ 1, 0.60, 0, 0.65 },
    pdf_thumbnail_bg: [4]f32 = .{ 0.95, 0.96, 0.98, 1 },
    pdf_thumbnail_shadow: [4]f32 = .{ 0, 0, 0, 0.3 },
    pdf_search_shadow: [4]f32 = .{ 0, 0, 0, 0.4 },
    pdf_dialog_backdrop: [4]f32 = .{ 0, 0, 0, 0.6 },
    dialog_backdrop: [4]f32 = .{ 0, 0, 0, 0.18 },
    settings_radius: f32 = 8,
    settings_sidebar_radius: f32 = 10,
    settings_card_radius: f32 = 9,
    checkbox_radius: f32 = 4,
    toggle_radius: f32 = 5,
    toggle_thumb_radius: f32 = 4,
    slider_track_height: f32 = 5.5,
    slider_settings_track_height: f32 = 11,
    slider_thumb_size: f32 = 12,
    slider_settings_thumb_height: f32 = 20,
    slider_thumb_radius: f32 = 4,
    slider_track_grow: f32 = 0.25,
    slider_track_tint_alpha: f32 = 0.45,
    slider_fill_alpha: f32 = 0.6,
    pill_active_alpha: f32 = 0.16,
    pill_border_active_alpha: f32 = 0.55,
    segmented_selected_alpha: f32 = 0.15,
    swatch_radius: f32 = 6,
    swatch_glow_alpha: f32 = 0.8,
    dialog_badge_radius: f32 = 16,
    dialog_badge_alpha: f32 = 0.18,
    dialog_glyph_lift: f32 = 0.3,
    dialog_title_size: f32 = 26,
    dialog_subtitle_size: f32 = 15,
    dialog_inset_radius: f32 = 12,
    scrollbar_radius: f32 = 3,
    scrollbar_rest_width: f32 = 0.75,
    scrollbar_active_width: f32 = 1.125,
    switcher_radius: f32 = 24,
    switcher_item_radius: f32 = 12,
    switcher_icon_radius: f32 = 10,
    switcher_selection_radius: f32 = 15,
    switcher_title_size: f32 = 15,
    switcher_app_size: f32 = 12,
    calendar_radius: f32 = 9,
    calendar_opacity: f32 = 0.98,
    osd_radius: f32 = 10,
    osd_opacity: f32 = 0.97,
    lock_wallpaper_opacity: f32 = 0.24,
    image_checker_size: f32 = 12,

    // Shell palettes follow the start-menu accent unless explicitly overridden.
    shell_accent: ?[4]f32 = null,
    shell_on_accent: ?[4]f32 = null,
    shell_border_focus: ?[4]f32 = null,
    window_close_fg: [4]f32 = .{ 1, 1, 1, 1 },
    start_button_hover: [4]f32 = .{ 1, 1, 1, 0.035 },
    start_button_indicator: [4]f32 = .{ 1, 1, 1, 0.5 },
    start_button_radius: f32 = 6,
    polkit_backdrop: [4]f32 = .{ 0, 0, 0, 0.55 },
    power_menu_backdrop: [4]f32 = .{ 0, 0, 0, 0.45 },
    mini_map_bg_opacity: f32 = 0.91,
    mini_map_grid_alpha: f32 = 0.065,
    mini_map_border_alpha: f32 = 0.12,
    mini_map_window_alpha: f32 = 0.55,
    mini_map_marker_alpha: f32 = 0.12,
    mini_map_marker_border_alpha: f32 = 0.85,
    mini_map_radius: f32 = 4,

    app_text_size: f32 = 13,
    app_heading_size: f32 = 12,
    app_status_size: f32 = 11.5,
    desktop_text_size: f32 = 11.5,
    window_close_hover_alpha: f32 = 0.85,
    button_disabled_alpha: f32 = 0.5,
    button_hover_brightness: f32 = 1.08,
    button_selected_alpha: f32 = 0.6,
    button_selected_hover_alpha: f32 = 0.7,

    pub fn caretColor(t: Theme) [4]f32 {
        return t.caret orelse t.accent;
    }

    pub fn controlFocusColor(t: Theme) [4]f32 {
        return t.shell_border_focus orelse t.fg;
    }

    pub fn fieldFocusColor(t: Theme) [4]f32 {
        return t.field_border_focus orelse t.shell_border_focus orelse t.accent;
    }

    pub fn selectionColor(t: Theme) [4]f32 {
        if (t.selection) |color| return color;
        return .{ t.accent[0], t.accent[1], t.accent[2], t.accent[3] * t.selection_alpha };
    }
};

/// Neutral window greys with the start menu's marker as accent: the palette
/// of the shell's own surfaces (start menu, lock screen, polkit dialog).
pub fn shellPalette() Theme {
    var t = global;
    t.fg = t.window_fg;
    t.dim = t.window_dim;
    t.accent = t.shell_accent orelse t.start_menu_selected_marker;
    t.on_accent = t.shell_on_accent orelse t.window_fg;
    t.border_focus = t.shell_border_focus orelse t.accent;
    return t;
}

/// The colour tokens the taskbar draws with. A taskbar theme (Appearance's
/// "Task Bar theme", `[taskbar_theme]` in the config) replaces just these, and
/// only on the taskbar: every other surface keeps the main theme. Geometry
/// (`taskbar_size`, chip and start-button sizes and gaps, radii) stays with the
/// main theme, which has sliders for it.
pub const TaskbarToken = enum {
    taskbar_bg,
    taskbar_surface,
    taskbar_hover,
    taskbar_border,
    border_soft,
    surface_hover,
    window_fg,
    window_dim,
    danger,
    window_close_hover,
    start_button_hover,
    start_button_indicator,
    start_button_logo_color,
    battery_bg,
    battery_full,
    battery_low,
    battery_critical,
    battery_shimmer,
};

/// The chosen taskbar theme; null follows `global`. Only its `TaskbarToken`
/// fields mean anything (see `taskbarTokens`).
pub var taskbar_override: ?Theme = null;

/// A taskbar colour: the taskbar theme's when one is chosen, else the main
/// theme's. The taskbar reads these instead of `global` so the two can differ.
pub fn taskbar(comptime token: TaskbarToken) @FieldType(Theme, @tagName(token)) {
    if (taskbar_override) |chosen| return @field(chosen, @tagName(token));
    return @field(global, @tagName(token));
}

/// Just `t`'s taskbar tokens over a default theme: the form `taskbar_override`
/// holds, so nothing else of `t` (its strings in particular) is kept.
pub fn taskbarTokens(t: Theme) Theme {
    var out: Theme = .{};
    inline for (std.meta.fields(TaskbarToken)) |field| @field(out, field.name) = @field(t, field.name);
    return out;
}

/// Whether two themes' taskbar tokens look the same once written: colours
/// compare as `writeTaskbarInto` stores them, so a saved and reloaded theme
/// still equals the preset it came from.
pub fn taskbarTokensEql(a: Theme, b: Theme) bool {
    inline for (std.meta.fields(TaskbarToken)) |field| {
        if (!sameWritten(@field(a, field.name), @field(b, field.name))) return false;
    }
    return true;
}

fn sameWritten(a: anytype, b: @TypeOf(a)) bool {
    if (comptime @TypeOf(a) == ?[4]f32) {
        const left = a orelse return b == null;
        const right = b orelse return false;
        return sameWritten(left, right);
    }
    return std.meta.eql(quantize(a), quantize(b));
}

pub fn taskbarOverrideEql(a: ?Theme, b: ?Theme) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return taskbarTokensEql(left, right);
}

/// Applies `key` only when it is a taskbar token, so a section holding a whole
/// theme file's keys still yields just the taskbar's. False for any other key.
pub fn applyTaskbarKey(allocator: Allocator, t: *Theme, key: []const u8, value: []const u8) !bool {
    if (std.meta.stringToEnum(TaskbarToken, key) == null) return false;
    try applyKey(allocator, t, key, value);
    return true;
}

/// Appearance presets write ordinary numeric theme tokens, so hand-edited
/// radii remain the source of truth and repeated picks never compound.
pub const RadiusPreset = enum { sharp, default, round };

pub fn applyRadiusPreset(t: *Theme, preset: RadiusPreset) void {
    const defaults: Theme = .{};
    inline for (std.meta.fields(Theme)) |field| {
        if (comptime field.type == f32 and (std.mem.startsWith(u8, field.name, "radius") or std.mem.endsWith(u8, field.name, "_radius"))) {
            const base = @field(defaults, field.name);
            @field(t, field.name) = switch (preset) {
                .sharp => @min(base, 4),
                .default => base,
                .round => base * 1.3,
            };
        }
    }
}

/// Custom numeric radii need not match any preset: show no selected segment
/// so choosing Default can restore every radius, even when `radius` is still 5.
pub fn radiusPreset(t: Theme) ?RadiusPreset {
    for ([_]RadiusPreset{ .sharp, .default, .round }) |preset| {
        var candidate: Theme = .{};
        applyRadiusPreset(&candidate, preset);
        var matches = true;
        inline for (std.meta.fields(Theme)) |field| {
            if (comptime field.type == f32 and (std.mem.startsWith(u8, field.name, "radius") or std.mem.endsWith(u8, field.name, "_radius"))) {
                if (@abs(@field(t, field.name) - @field(candidate, field.name)) > 0.001) matches = false;
            }
        }
        if (matches) return preset;
    }
    return null;
}

/// Process-wide theme. Widget defaults read this at construction/paint
/// time, so reskinning is "edit the file, restart" rather than a live
/// property to push through the tree.
pub var global: Theme = .{};

// Keep the darkness slider anchored to the original charcoal, independently
// of the default theme tint.
const chrome_base: [4]f32 = .{ 38.0 / 255.0, 45.0 / 255.0, 55.0 / 255.0, 1 };

/// Brightness of an sRGB-encoded colour: enough to say which of two
/// charcoals looks darker, which is all the chrome darkness compares.
fn luma(color: [4]f32) f32 {
    return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
}

/// How far the chrome tint `bg` is darkened from the stock colour, 0...1.
/// The tint is what shows at full opacity (a translucent titlebar mixes in
/// the wallpaper behind it), so darkening it is the way to a chrome that is
/// both opaque and dark. A custom colour lighter than stock reads 0.
pub fn chromeDarkness(bg: [4]f32) f32 {
    return std.math.clamp(1 - luma(bg) / luma(chrome_base), 0.0, 1.0);
}

/// `bg` at the brightness `darkness` leaves of the stock chrome colour, with
/// its own hue and alpha. Near-black keeps no hue to scale, so that borrows
/// the stock one.
pub fn withChromeDarkness(bg: [4]f32, darkness: f32) [4]f32 {
    const stock = chrome_base;
    const hue = if (luma(bg) < 0.01) stock else bg;
    const scale = (1 - std.math.clamp(darkness, 0.0, 1.0)) * luma(stock) / luma(hue);
    return .{ @min(1, hue[0] * scale), @min(1, hue[1] * scale), @min(1, hue[2] * scale), bg[3] };
}

/// `REDIWM_THEME`, matching this project's existing env-var config
/// conventions (`REDIWM_SCALE`, `REDIWM_ICON_THEME` in icon_theme.zig).
/// Unset means "use the built-in defaults above", not an error.
pub fn resolvePath(environ: std.process.Environ) ?[]const u8 {
    return environ.getPosix("REDIWM_THEME");
}

/// Best-effort: logs and falls back to defaults on any failure (missing
/// file, malformed TOML) rather than failing compositor startup over a
/// theme file.
pub fn loadGlobal(allocator: Allocator, io: Io, path: []const u8) void {
    global = load(allocator, io, path) catch |err| blk: {
        log.warn("loadGlobal: failed to load '{s}': {}, using defaults", .{ path, err });
        break :blk .{};
    };
}

pub fn load(allocator: Allocator, io: Io, path: []const u8) !Theme {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

// Derive supported keys from Theme so a field cannot be exposed through IPC
// but silently omitted by TOML parsing or Appearance's save.
fn keysOf(comptime T: type) []const []const u8 {
    const keys = comptime blk: {
        var count: usize = 0;
        for (std.meta.fields(Theme)) |field| if (field.type == T) {
            count += 1;
        };
        var names: [count][]const u8 = undefined;
        var i: usize = 0;
        for (std.meta.fields(Theme)) |field| {
            if (field.type == T) {
                names[i] = field.name;
                i += 1;
            }
        }
        break :blk names;
    };
    return &keys;
}
const color_keys = keysOf([4]f32);
const number_keys = keysOf(f32);
const boolean_keys = keysOf(bool);
const optional_color_keys = keysOf(?[4]f32);
const string_keys = keysOf([]const u8);

/// Parses theme file bytes. String fields (`font`, `mono_font`) are duped
/// with `allocator` and, like `icon_theme.resolveConfig`'s paths, meant to
/// live for the process lifetime — pass a persistent allocator, not an
/// arena that gets torn down.
pub fn parse(allocator: Allocator, bytes: []const u8) !Theme {
    var t: Theme = .{};
    try overlay(allocator, &t, bytes);
    return t;
}

/// Applies `[theme]` keys from `bytes` onto an existing theme, leaving
/// unspecified fields untouched. Used to merge `REDIWM_THEME` over the
/// compositor config's `[theme]` section.
pub fn overlay(allocator: Allocator, t: *Theme, bytes: []const u8) !void {
    var in_theme_section = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_theme_section = std.mem.eql(u8, line[1..close], "theme");
            continue;
        }
        if (!in_theme_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        try applyKey(allocator, t, key, value);
    }
}

/// Drops a `#` comment that is not inside a quoted string.
pub fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '"' and (i == 0 or line[i - 1] != '\\')) in_string = !in_string;
        if (ch == '#' and !in_string) return std.mem.trimEnd(u8, line[0..i], " \t");
    }
    return line;
}

pub fn applyKey(allocator: Allocator, t: *Theme, key: []const u8, value: []const u8) !void {
    @setEvalBranchQuota(10000);
    inline for (boolean_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(t, name) = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidBoolean;
            return;
        }
    }
    inline for (string_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            const text = try unquote(value);
            if (comptime std.mem.eql(u8, name, "start_button_icon")) {
                if (text.len > 0 and !std.fs.path.isAbsolute(text)) return error.InvalidIconPath;
            }
            @field(t, name) = try allocator.dupe(u8, text);
            return;
        }
    }
    if (std.mem.eql(u8, key, "taskbar_height")) {
        const number = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(number) or number < 0 or number > 4096) return error.InvalidSize;
        t.taskbar_size = number;
        return;
    }
    inline for (number_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            const number = try std.fmt.parseFloat(f32, value);
            if (!std.math.isFinite(number) or number < 0 or number > 4096) return error.InvalidSize;
            if (comptime std.mem.eql(u8, name, "scrollbar_width")) {
                if (number < 4 or number > 24) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "chip_width")) {
                if (number < 64 or number > 400) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "chrome_height")) {
                if (number < 28 or number > 84) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "chrome_control_gap")) {
                if (number > 24) return error.InvalidSize;
            }
            if (comptime std.mem.endsWith(u8, name, "_alpha") or std.mem.endsWith(u8, name, "_opacity") or std.mem.eql(u8, name, "dialog_glyph_lift")) {
                if (number > 1) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "image_checker_size")) {
                if (number < 1 or number > 128) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "scrollbar_rest_width") or std.mem.eql(u8, name, "scrollbar_active_width")) {
                if (number < 0.25 or number > 1.125) return error.InvalidSize;
            }
            @field(t, name) = number;
            return;
        }
    }
    inline for (optional_color_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(t, name) = try parseColor(try unquote(value));
            return;
        }
    }
    inline for (color_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(t, name) = try parseColor(try unquote(value));
            return;
        }
    }
    // Unknown key: ignore, so a newer theme file with extra tokens still
    // loads under an older build.
}

/// Serializes `t` back into this file's tiny TOML dialect, replacing the
/// whole `[theme]` section, and writes it to `path`. Round-trips every value
/// but reformats colors as `rgba(...)` regardless of how the file originally
/// spelled them — this reader has no comments or alternate spellings worth
/// preserving, just the values themselves. Values equal to the defaults are
/// left out, so changing a default reaches everyone who never changed that
/// key. Best-effort: logs
/// and returns without touching the file on any failure, matching
/// `loadGlobal`'s "never crash over a theme file" stance; does not update
/// `global` itself — call `loadGlobal` afterward to do that via the same
/// path malformed-file errors already take.
pub fn save(allocator: Allocator, io: Io, path: []const u8, t: Theme) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    writeInto(allocator, &buf, t) catch |err| {
        log.warn("save: failed to format '{s}': {}", .{ path, err });
        return;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch |err| {
        log.warn("save: failed to write '{s}': {}", .{ path, err });
    };
}

fn appendLine(allocator: Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var line: [160]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&line, fmt, args));
}

/// A colour as written: 8-bit channels and alpha to three decimals.
fn quantize(c: [4]f32) [4]u32 {
    var q: [4]u32 = undefined;
    for (0..3) |i| q[i] = @intFromFloat(@round(std.math.clamp(c[i], 0, 1) * 255));
    q[3] = @intFromFloat(@round(std.math.clamp(c[3], 0, 1) * 1000));
    return q;
}

fn appendColor(allocator: Allocator, buf: *std.ArrayList(u8), key: []const u8, c: [4]f32) !void {
    const q = quantize(c);
    try appendLine(allocator, buf, "{s} = \"rgba({d},{d},{d},{d:.3})\"\n", .{ key, q[0], q[1], q[2], std.math.clamp(c[3], 0, 1) });
}

pub fn writeInto(allocator: Allocator, buf: *std.ArrayList(u8), t: Theme) !void {
    const defaults: Theme = .{};
    try buf.appendSlice(allocator, "[theme]\n");
    inline for (boolean_keys) |name| {
        if (@field(t, name) != @field(defaults, name)) try appendLine(allocator, buf, "{s} = {}\n", .{ name, @field(t, name) });
    }
    inline for (string_keys) |name| {
        if (!std.mem.eql(u8, @field(t, name), @field(defaults, name))) {
            try buf.appendSlice(allocator, name ++ " = \"");
            try buf.appendSlice(allocator, @field(t, name));
            try buf.appendSlice(allocator, "\"\n");
        }
    }
    inline for (number_keys) |name| {
        // Keep the frame radius explicit even at Default, so a legacy
        // compositor.border_radius cannot reappear after saving the theme.
        if (comptime std.mem.eql(u8, name, "radius_lg")) {
            try appendLine(allocator, buf, "{s} = {d}\n", .{ name, @field(t, name) });
            continue;
        }
        if (@field(t, name) != @field(defaults, name)) try appendLine(allocator, buf, "{s} = {d}\n", .{ name, @field(t, name) });
    }
    inline for (color_keys) |name| {
        if (!std.meta.eql(quantize(@field(t, name)), quantize(@field(defaults, name)))) try appendColor(allocator, buf, name, @field(t, name));
    }
    // Written only when set: an emitted value would pin these to the accent of
    // whichever palette happened to be current, turning "follow the accent"
    // into a fixed colour on the first save.
    inline for (optional_color_keys) |name| {
        if (@field(t, name)) |color| try appendColor(allocator, buf, name, color);
    }
}

/// The `[taskbar_theme]` section for `t`'s taskbar tokens. Values equal to the
/// defaults are left out, as `writeInto` does: the section's presence, not its
/// keys, says a taskbar theme is chosen, and it reads back over the defaults.
pub fn writeTaskbarInto(allocator: Allocator, buf: *std.ArrayList(u8), t: Theme) !void {
    const defaults: Theme = .{};
    try buf.appendSlice(allocator, "[taskbar_theme]\n");
    inline for (std.meta.fields(TaskbarToken)) |field| {
        const value = @field(t, field.name);
        if (comptime @TypeOf(value) == ?[4]f32) {
            if (value) |color| try appendColor(allocator, buf, field.name, color);
        } else if (!std.meta.eql(quantize(value), quantize(@field(defaults, field.name)))) {
            try appendColor(allocator, buf, field.name, value);
        }
    }
}

pub fn unquote(v: []const u8) ![]const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return error.ExpectedQuotedString;
}

/// Accepts "#rrggbb", "#rrggbbaa", or "rgba(r,g,b,a)" (r/g/b 0-255, a 0-1)
/// and returns straight-alpha RGBA, matching every other `[4]f32` color in
/// this codebase (chrome.Color, Taskbar.Color).
pub fn parseColor(s: []const u8) ![4]f32 {
    if (s.len > 0 and s[0] == '#') return parseHex(s);
    if (std.mem.startsWith(u8, s, "rgba(")) return parseRgba(s);
    return error.InvalidColor;
}

fn parseHex(s: []const u8) ![4]f32 {
    if (s.len != 7 and s.len != 9) return error.InvalidColor;
    const r = try std.fmt.parseInt(u8, s[1..3], 16);
    const g = try std.fmt.parseInt(u8, s[3..5], 16);
    const b = try std.fmt.parseInt(u8, s[5..7], 16);
    const a: u8 = if (s.len == 9) try std.fmt.parseInt(u8, s[7..9], 16) else 255;
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn parseRgba(s: []const u8) ![4]f32 {
    if (!std.mem.endsWith(u8, s, ")")) return error.InvalidColor;
    const inner = s["rgba(".len .. s.len - 1];
    var comps: [4]f32 = .{ 0, 0, 0, 1 };
    var it = std.mem.splitScalar(u8, inner, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidColor;
        const v = try std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t"));
        if (!std.math.isFinite(v) or v < 0 or v > (if (i < 3) @as(f32, 255) else 1)) return error.InvalidColor;
        comps[i] = if (i < 3) v / 255.0 else v;
    }
    if (i < 3) return error.InvalidColor;
    return comps;
}

test "parseColor hex with and without alpha" {
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, try parseColor("#ffffff"));
    const with_alpha = try parseColor("#ffffff80");
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), with_alpha[3], 1e-6);
}

test "parseColor rgba" {
    for ([_][]const u8{ "rgba(nan,0,0,1)", "rgba(0,0,0,inf)", "rgba(256,0,0,1)", "rgba(0,0,0,2)", "rgba(-1,0,0,1)" }) |bad| {
        try std.testing.expectError(error.InvalidColor, parseColor(bad));
    }
    const c = try parseColor("rgba(255,255,255,0.045)");
    try std.testing.expectEqual(@as(f32, 1), c[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.045), c[3], 1e-6);
}

test "parse reads the spec's example theme file" {
    const sample =
        \\[theme]
        \\font         = "Manrope"
        \\mono_font    = "JetBrains Mono"
        \\font_size    = 13.0
        \\radius       = 5.0
        \\bg           = "#090b18"
        \\accent       = "#5eead4"
        \\surface      = "rgba(255,255,255,0.045)"
        \\border_focus = "rgba(94,234,212,0.40)"
    ;
    const t = try parse(std.testing.allocator, sample);
    defer std.testing.allocator.free(t.font);
    defer std.testing.allocator.free(t.mono_font);

    try std.testing.expectEqualStrings("Manrope", t.font);
    try std.testing.expectEqualStrings("JetBrains Mono", t.mono_font);
    try std.testing.expectEqual(@as(f32, 13.0), t.font_size);
    try std.testing.expectEqual(@as(f32, 5.0), t.radius);
    try std.testing.expectApproxEqAbs(@as(f32, 0.045), t.surface[3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), t.border_focus[3], 1e-6);
}

test "writeInto then parse round-trips every field" {
    var t: Theme = .{};
    // Exercise every registered field with a non-default value, so omission
    // from either parser or serializer cannot pass as a default round-trip.
    // Keys defaulting to 0 (automatic sizes) would stay at the default under *= 0.9.
    inline for (number_keys) |name| @field(t, name) = if (@field(t, name) == 0) 500 else @field(t, name) * 0.9;
    inline for (color_keys) |name| @field(t, name) = .{ 16.0 / 255.0, 32.0 / 255.0, 48.0 / 255.0, 0.321 };
    inline for (optional_color_keys) |name| @field(t, name) = .{ 16.0 / 255.0, 32.0 / 255.0, 48.0 / 255.0, 0.321 };
    t.accent = .{ 167.0 / 255.0, 139.0 / 255.0, 250.0 / 255.0, 1 };
    t.radius = 8;
    t.font_size = 14;
    t.radius_md = 9;
    t.radius_lg = 12;
    t.glass = .{ 0.2, 0.4, 0.6, 0.56 };
    t.taskbar_bg = .{ 0.1, 0.2, 0.3, 0.62 };
    t.start_button_icon = "/tmp/custom logo.svg";
    t.shadow_size = 32;
    t.shadow = .{ 0, 0, 0, 0.45 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeInto(std.testing.allocator, &buf, t);

    const parsed = try parse(std.testing.allocator, buf.items);
    // writeInto omits unchanged fonts; parse keeps their borrowed defaults.
    defer std.testing.allocator.free(parsed.start_button_icon);
    try std.testing.expectEqualStrings(t.start_button_icon, parsed.start_button_icon);

    inline for (number_keys) |name| try std.testing.expectEqual(@field(t, name), @field(parsed, name));
    inline for (color_keys) |name| {
        for (@field(t, name), @field(parsed, name)) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1.0 / 255.0);
        }
    }
    inline for (optional_color_keys) |name| try std.testing.expectEqual(@field(t, name), @field(parsed, name));
    try std.testing.expectEqual(@as(f32, 8), parsed.radius);
    try std.testing.expectEqual(@as(f32, 14), parsed.font_size);
    try std.testing.expectApproxEqAbs(t.accent[0], parsed.accent[0], 1.0 / 255.0);
    try std.testing.expectApproxEqAbs(t.accent[1], parsed.accent[1], 1.0 / 255.0);
    try std.testing.expectApproxEqAbs(t.accent[2], parsed.accent[2], 1.0 / 255.0);
    try std.testing.expectApproxEqAbs(t.border_focus[3], parsed.border_focus[3], 1e-3);
}

test "writeInto omits defaults except the explicit frame radius" {
    var t: Theme = .{};
    t.radius = 9;
    t.window_bg[3] = 0.5;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeInto(std.testing.allocator, &buf, t);
    try std.testing.expectEqualStrings("[theme]\nradius = 9\nradius_lg = 10\nwindow_bg = \"rgba(8,9,11,0.500)\"\n", buf.items);
}

test "theme sizes reject non-finite and unsafe geometry" {
    for ([_][]const u8{ "nan", "inf", "-1", "1000000" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(std.testing.allocator, &t, "radius_lg", value));
    }
}

test "caret colour follows the accent in effect until the file sets one" {
    var t: Theme = .{};
    // Panels remap `accent` for their own palette; an unset caret has to
    // follow that, which is what it did before the token existed.
    t.accent = .{ 1, 0, 0, 1 };
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, t.caretColor());

    try applyKey(std.testing.allocator, &t, "caret", "\"rgba(0,255,0,1)\"");
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, t.caretColor());

    // Round-trips only once set, so saving a theme cannot freeze "follow the
    // accent" into a literal colour.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeInto(std.testing.allocator, &buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\ncaret = ") == null);

    buf.clearRetainingCapacity();
    try writeInto(std.testing.allocator, &buf, t);
    const parsed = try parse(std.testing.allocator, buf.items);
    // writeInto omits unchanged fonts; parse keeps their borrowed defaults.
    try std.testing.expectEqual([4]f32{ 0, 1, 0, 1 }, parsed.caret.?);
}

test "bundled RediWM Dark preset round-trips to Theme{}'s defaults field-for-field" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.80), (Theme{}).window_bg[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.80), chromeDarkness((Theme{}).window_bg), 1e-5);
    const bytes = @embedFile("theme-rediwm-dark");
    const t = try parse(std.testing.allocator, bytes);
    defer std.testing.allocator.free(t.font);
    defer std.testing.allocator.free(t.mono_font);

    const defaults: Theme = .{};
    try std.testing.expectEqualStrings(defaults.font, t.font);
    try std.testing.expectEqualStrings(defaults.mono_font, t.mono_font);
    inline for (number_keys) |name| try std.testing.expectEqual(@field(defaults, name), @field(t, name));
    inline for (color_keys) |name| {
        for (@field(defaults, name), @field(t, name)) |expected, actual| {
            try std.testing.expectApproxEqAbs(expected, actual, 1.0 / 255.0);
        }
    }
}

test "scrollbar width validates and survives theme serialization" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "0", "3", "25", "nan", "inf" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(a, &t, "scrollbar_width", value));
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[theme]\nscrollbar_width = 19\n");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeInto(a, &buf, t);
    const restored = try parse(arena.allocator(), buf.items);
    try std.testing.expectEqual(@as(f32, 19), restored.scrollbar_width);
}

test "chrome darkness scales the tint's brightness and keeps its hue and alpha" {
    const stock = chrome_base;
    try std.testing.expectEqual(@as(f32, 0), chromeDarkness(stock));
    // Zero darkness is the stock colour exactly, at whatever opacity it had.
    const untouched = withChromeDarkness(.{ stock[0], stock[1], stock[2], 0.37 }, 0);
    try std.testing.expectEqual(stock[0], untouched[0]);
    try std.testing.expectEqual(stock[1], untouched[1]);
    try std.testing.expectEqual(stock[2], untouched[2]);
    try std.testing.expectEqual(@as(f32, 0.37), untouched[3]);

    // Half darkness reads back as half, with the stock hue.
    const half = withChromeDarkness(stock, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), chromeDarkness(half), 1e-5);
    try std.testing.expectApproxEqAbs(stock[0] / stock[2], half[0] / half[2], 1e-5);
    try std.testing.expectApproxEqAbs(stock[1] / stock[2], half[1] / half[2], 1e-5);
    try std.testing.expect(half[0] < stock[0] and half[1] < stock[1] and half[2] < stock[2]);

    // Full darkness is black; going back up recovers the stock hue.
    const black = withChromeDarkness(stock, 1);
    try std.testing.expectEqual(@as(f32, 0), black[0] + black[1] + black[2]);
    const back = withChromeDarkness(black, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), chromeDarkness(back), 1e-5);
    try std.testing.expectApproxEqAbs(stock[0] / stock[2], back[0] / back[2], 1e-5);
}

test "chrome darkness follows a custom tint and survives 8-bit storage" {
    // A user's own darker charcoal reads as darkened, not as 0.
    const custom: [4]f32 = .{ 16.0 / 255.0, 18.0 / 255.0, 21.0 / 255.0, 0.98 };
    const d = chromeDarkness(custom);
    try std.testing.expect(d > 0.5 and d < 0.7);
    // Moving the slider keeps the tint's hue rather than resetting to stock.
    const moved = withChromeDarkness(custom, 0.5);
    try std.testing.expectApproxEqAbs(custom[0] / custom[2], moved[0] / moved[2], 1e-5);
    try std.testing.expectEqual(@as(f32, 0.98), moved[3]);
    // A lighter-than-stock colour reads 0 and is never pushed past white.
    try std.testing.expectEqual(@as(f32, 0), chromeDarkness(.{ 1, 1, 1, 1 }));
    const white = withChromeDarkness(.{ 1, 1, 1, 1 }, 0);
    try std.testing.expect(white[0] <= 1 and white[1] <= 1 and white[2] <= 1);
    // Reloading from the theme file quantises to 8 bits; the readout stays put.
    const stored: [4]f32 = .{ @round(moved[0] * 255) / 255.0, @round(moved[1] * 255) / 255.0, @round(moved[2] * 255) / 255.0, moved[3] };
    try std.testing.expectApproxEqAbs(chromeDarkness(moved), chromeDarkness(stored), 0.01);
}

test "chrome geometry validates and survives theme serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "0", "27", "85", "nan", "inf" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(a, &t, "chrome_height", value));
    }
    for ([_][]const u8{ "-1", "25", "nan", "inf" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidSize, applyKey(a, &t, "chrome_control_gap", value));
    }
    for ([_][]const u8{ "1", "\"true\"", "True" }) |value| {
        var t: Theme = .{};
        try std.testing.expectError(error.InvalidBoolean, applyKey(a, &t, "chrome_round_buttons", value));
    }
    try std.testing.expect(!(try parse(a, "[theme]\nchrome_round_buttons = false\n")).chrome_round_buttons);
    const t = try parse(a, "[theme]\nchrome_height = 28\nchrome_control_gap = 0\nchrome_round_buttons = true\n");
    var buf: std.ArrayList(u8) = .empty;
    try writeInto(a, &buf, t);
    const restored = try parse(a, buf.items);
    try std.testing.expectEqual(@as(f32, 28), restored.chrome_height);
    try std.testing.expectEqual(@as(f32, 0), restored.chrome_control_gap);
    try std.testing.expect(restored.chrome_round_buttons);
}
