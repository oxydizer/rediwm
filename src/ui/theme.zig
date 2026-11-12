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
const layout = @import("layout.zig");
pub const Relief = layout.Relief;

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
    /// Right padding in the chrome's reference units; downward shift in logical px.
    chrome_control_right_pad: f32 = 12,
    chrome_control_offset_y: f32 = 0,
    /// Circular window controls and pill-shaped tabs, including tab controls.
    chrome_round_buttons: bool = false,
    /// Straight 45-degree cuts on window controls, in reference units; overrides round buttons.
    chrome_button_bevel: f32 = 0,
    /// A polygon outline for server-decorated windows instead of the rounded
    /// rectangle (syntax in `window_shape.zig`); empty keeps `radius_lg`.
    window_shape: []const u8 = "",
    /// A strip of this colour along the top of the titlebar, `window_top_band_height`
    /// logical px tall (0 draws none), clipped by the window's shape.
    window_top_band: [4]f32 = .{ 0, 0, 0, 0 },
    window_top_band_height: f32 = 0,
    /// Angled title plate, capped before the window controls. Zero width disables it.
    window_title_plate: [4]f32 = .{ 0, 0, 0, 0 },
    window_title_plate_width: f32 = 0,
    window_title_plate_fg: ?[4]f32 = null,
    window_title_plate_inset: f32 = 5,
    window_title_plate_bevel: f32 = 7,
    /// Cut at the plate's bottom-left corner (the bevel above is its top-left).
    window_title_plate_bottom_bevel: f32 = 0,
    /// Right slant as a fraction of chrome_height; gaps/padding are logical px.
    window_title_plate_slant: f32 = 0.65,
    window_title_plate_control_gap: f32 = 8,
    window_title_plate_text_padding: f32 = 8,
    /// Short strokes following the actual frame outline at its four corners.
    window_corner_accent: [4]f32 = .{ 0, 0, 0, 0 },
    window_corner_extent: f32 = 0,
    /// Extra length during an interactive resize (zero leaves corners static).
    window_corner_resize_extra: f32 = 0,
    window_corner_width: f32 = 3,
    /// Inset beyond the frame's own border ring, and padding at stroke endpoints.
    window_corner_inset: f32 = 0,
    window_corner_end_padding: f32 = 2,
    /// Band of its own around the stroke on every side, ends included (zero
    /// width: none). The stroke moves in by the casing width.
    window_corner_casing: [4]f32 = .{ 0, 0, 0, 0 },
    window_corner_casing_width: f32 = 0,
    /// Cut the stroke's (and casing's) ends at 45 degrees, the outer edge longest.
    window_corner_cut_ends: bool = false,
    window_corner_resize_ms: f32 = 140,
    window_corner_restore_ms: f32 = 180,
    /// out_cubic, in_out_sine or flip_bezier; global animation preferences still apply.
    window_corner_resize_ease: []const u8 = "out_cubic",
    // Window decorations use neutral charcoal independently of shell glass.
    window_bg: [4]f32 = .{ @as(f32, 7.6) / 255.0, 9.0 / 255.0, 11.0 / 255.0, 0.80 }, // 80% darkness and opacity
    // Neutral foregrounds keep text and monochrome icons free of a blue tint.
    window_fg: [4]f32 = .{ 245.0 / 255.0, 245.0 / 255.0, 245.0 / 255.0, 1 }, // #f5f5f5
    window_dim: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6
    window_border: [4]f32 = .{ 1, 1, 1, 0.09 },
    window_border_hover: [4]f32 = .{ 1, 1, 1, 0.13 },
    /// Outer window frame, logical px (1–16, rounded to whole pixels).
    window_border_width: f32 = 1,
    /// Continuous inner frame band, reserved outside the client (zero: none).
    window_inner_border: [4]f32 = .{ 0, 0, 0, 0 },
    window_inner_border_width: f32 = 0,
    /// Active window outline in opt-in workspace mode (#ed1b2e).
    workspace_active_border: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 1 },
    window_divider: [4]f32 = .{ 1, 1, 1, 0.045 },
    window_close_hover: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 1 },
    // App windows (Files, Images, PDF). All their text is `window_fg`
    // (`window_dim`/`text_secondary` stay for shell popups), menus
    // `window_bg`, red accents the shell palette's accent.
    text_secondary: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6
    app_bg: [4]f32 = .{ 24.0 / 255.0, 28.0 / 255.0, 34.0 / 255.0, 1 }, // #181c22, main content
    app_toolbar: [4]f32 = .{ 29.0 / 255.0, 34.0 / 255.0, 41.0 / 255.0, 1 }, // #1d2229
    app_sidebar: [4]f32 = .{ 27.0 / 255.0, 33.0 / 255.0, 40.0 / 255.0, 1 }, // #1b2128
    app_sidebar_blur: bool = false, // backdrop behind translucent Settings/Files sidebars
    app_bar: [4]f32 = .{ 35.0 / 255.0, 42.0 / 255.0, 51.0 / 255.0, 1 }, // #232a33, column headers, status bars
    app_item: [4]f32 = .{ 34.0 / 255.0, 40.0 / 255.0, 46.0 / 255.0, 1 }, // #22282e, rows, cards, thumbnails
    app_item_hover: [4]f32 = .{ 37.0 / 255.0, 43.0 / 255.0, 50.0 / 255.0, 1 }, // #252b32
    app_item_border: [4]f32 = .{ 45.0 / 255.0, 51.0 / 255.0, 58.0 / 255.0, 1 }, // #2d333a
    app_item_selected: [4]f32 = .{ 78.0 / 255.0, 37.0 / 255.0, 46.0 / 255.0, 1 }, // #4e252e
    app_nav_selected: [4]f32 = .{ 91.0 / 255.0, 36.0 / 255.0, 46.0 / 255.0, 1 }, // #5b242e, sidebar and menu rows
    app_git_added: [4]f32 = .{ 34.0 / 255.0, 197.0 / 255.0, 94.0 / 255.0, 1 }, // #22c55e, added lines
    app_divider: [4]f32 = .{ 55.0 / 255.0, 63.0 / 255.0, 72.0 / 255.0, 1 }, // #373f48
    app_icon: [4]f32 = .{ 214.0 / 255.0, 214.0 / 255.0, 214.0 / 255.0, 1 }, // #d6d6d6, sidebar glyphs
    /// Client content can be light while compositor decorations stay dark.
    /// Unset values preserve the existing shared window palette.
    app_fg: ?[4]f32 = null,
    app_sidebar_fg: ?[4]f32 = null,
    app_sidebar_selected: ?[4]f32 = null,
    app_sidebar_hover: ?[4]f32 = null,
    /// Lights the selected sidebar row: a bright leading bar and an accent glow.
    app_sidebar_selected_marker: ?[4]f32 = null,
    /// Corners of sidebar row highlights (hover and selection).
    app_sidebar_item_radius: f32 = 5,
    /// Straight 45-degree corners on sidebar and item highlights; zero stays rounded.
    app_highlight_bevel: f32 = 0,
    app_surface_hover: ?[4]f32 = null,
    app_menu_bg: ?[4]f32 = null,
    app_field_bg: ?[4]f32 = null,
    app_field_border: ?[4]f32 = null,
    dock_bg: ?[4]f32 = null,
    dock_border: ?[4]f32 = null,
    dock_radius: f32 = 0, // zero follows the window frame radius
    /// Straight 45-degree corners on the dock instead of `dock_radius`; zero is rounded.
    dock_bevel: f32 = 0,
    /// A resting tile behind every dock icon (unset: none, the ghost button's
    /// hover only), its outline, and the outline while hovered, pressed or the
    /// highlighted active app (unset: the accent). Corners cut by `dock_item_bevel`.
    dock_item_bg: ?[4]f32 = null,
    dock_item_border: ?[4]f32 = null,
    dock_item_hover_border: ?[4]f32 = null,
    dock_item_bevel: f32 = 0,
    /// How far dock icons are drained of colour at rest (0 keeps them, 1 is
    /// grey); a hovered icon, or the highlighted active app, shows its colours.
    dock_icon_grey: f32 = 0,
    notification_bg: ?[4]f32 = null,
    notification_fg: ?[4]f32 = null,
    notification_dim: ?[4]f32 = null,
    notification_border: ?[4]f32 = null,
    notification_icon_bg: ?[4]f32 = null,
    notification_radius: f32 = 12,
    notification_blur: bool = false,
    // Optional Foot launch palette. Unset entries keep the terminal's config.
    terminal_bg: ?[4]f32 = null,
    terminal_fg: ?[4]f32 = null,
    terminal_cursor: ?[4]f32 = null,
    terminal_black: ?[4]f32 = null,
    terminal_red: ?[4]f32 = null,
    terminal_green: ?[4]f32 = null,
    terminal_yellow: ?[4]f32 = null,
    terminal_blue: ?[4]f32 = null,
    terminal_magenta: ?[4]f32 = null,
    terminal_cyan: ?[4]f32 = null,
    terminal_white: ?[4]f32 = null,
    terminal_bright_black: ?[4]f32 = null,
    terminal_bright_red: ?[4]f32 = null,
    terminal_bright_green: ?[4]f32 = null,
    terminal_bright_yellow: ?[4]f32 = null,
    terminal_bright_blue: ?[4]f32 = null,
    terminal_bright_magenta: ?[4]f32 = null,
    terminal_bright_cyan: ?[4]f32 = null,
    terminal_bright_white: ?[4]f32 = null,
    scrollbar_thumb: [4]f32 = .{ 89.0 / 255.0, 98.0 / 255.0, 110.0 / 255.0, 1 }, // #59626e
    /// Unset follows the surface accent during hover/drag.
    scrollbar_thumb_active: ?[4]f32 = null,
    /// Optional stationary diagonal hatching, shared by Cairo and widget bars.
    scrollbar_track: [4]f32 = .{ 0, 0, 0, 0 },
    scrollbar_track_stripe: [4]f32 = .{ 0, 0, 0, 0 },
    /// Pattern distances along the bar; slope 1 is diagonal, 0 is transverse.
    /// Zero period or width hides the stripes, retaining the track fill.
    scrollbar_track_stripe_period: f32 = 10,
    scrollbar_track_stripe_width: f32 = 5,
    scrollbar_track_stripe_slope: f32 = 1,
    /// Strength of the light on a hovered/dragged/scrolling thumb (1 = subtle,
    /// 0 = a flat thumb: no highlight stripe, only the colour feedback).
    scrollbar_glow: f32 = 1.0,
    taskbar_title_size: f32 = 12.5,
    clock_bold: bool = false,
    clock_italic: bool = false,
    taskbar_size: f32 = 44.0,
    // A floating bar: distance from the output edge it sits on (logical px),
    // its length as a percentage of that edge (centred), and its corner
    // radius. The defaults are the flush, full-width, square bar. The strip
    // the bar claims is its height plus the gap (`Taskbar.reservedHeight`).
    taskbar_edge_gap: f32 = 0,
    taskbar_length: f32 = 100,
    taskbar_radius: f32 = 0,
    // A polygon outline for the bar instead of the rounded rectangle, in the
    // syntax of `window_shape` but against the bar's own box; empty keeps
    // `taskbar_radius`. Items keep clear of its slanted ends, nothing else.
    taskbar_shape: []const u8 = "",
    // Thickness of the bar's own outline (colour: `taskbar_outline`). With a
    // flush, full-width, square bar only the edge facing the windows is drawn.
    taskbar_outline_width: f32 = 1,
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
    /// The bar's own outline; unset follows `border_soft`, which drew the
    /// bar's hairline before this token existed. `taskbar_border` stays the
    /// window buttons' and battery's.
    taskbar_outline: ?[4]f32 = null,
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
    /// Highlight on the focused window's edge where the pointer comes near
    /// (`Toplevel.setGlow`). Its alpha is the strength at full proximity; zero
    /// turns it off.
    border_glow_enabled: bool = true,
    /// Shared gate for proximity highlights painted inside interactive
    /// widget surfaces. The legacy key name is retained for theme compatibility.
    /// Colour and reach/length/depth are shared with the window-edge glow.
    button_hover_glow_enabled: bool = true,
    border_glow: [4]f32 = .{ 237.0 / 255.0, 27.0 / 255.0, 46.0 / 255.0, 0.60 },
    border_glow_length: f32 = 72.0, // along the edge, logical px; fades out smoothly
    border_glow_reach: f32 = 56.0, // pointer distance from the edge where it appears
    border_glow_depth: f32 = 3.0, // how far it bleeds inward past the 1 px ring
    shadow_size: f32 = 24.0, // blur/softness radius, logical px
    shadow_offset_y: f32 = 8.0, // vertical offset, logical px
    /// Neumorphic relief of buttons, fields and inset panels (`ui/relief.zig`):
    /// each casts a dark and a light shadow shifted `relief_depth` logical px
    /// from its edge, away from and toward the light. 0 turns relief off.
    relief_depth: f32 = 0,
    /// Fade-out length of those shadows, logical px; 0 follows 1.5 x the depth.
    relief_softness: f32 = 0,
    /// Where the light sits, in degrees counter-clockwise from the right (135
    /// is the upper left).
    relief_light_angle: f32 = 135,
    relief_dark: [4]f32 = .{ 0, 0, 0, 0.35 },
    relief_light: [4]f32 = .{ 1, 1, 1, 0.10 },

    // Component-level relief styles. Flat defaults preserve existing rendering
    // for controls that did not previously request relief.
    button_relief: Relief = .flat,
    button_pressed_relief: Relief = .flat,
    field_relief: Relief = .flat,
    dialog_inset_relief: Relief = .flat,
    /// The dialog card itself (`widgets/dialog.zig`). Raised shadows lie outside
    /// it, so keep them within the host's backdrop margin.
    dialog_frame_relief: Relief = .flat,
    /// The cards around Settings entries. The page scrolls in a clipped
    /// container, so a raised card's shadow is cut at its edge: prefer `inset`.
    settings_card_relief: Relief = .flat,
    /// Taskbar window chips, idle and active (focused). The chip raster ends a
    /// few px past the chip, so both shade inside the edge: `inset` is a
    /// groove, `raised` the same shading with light and dark swapped. Main
    /// theme only; `[taskbar_theme]` does not carry them.
    taskbar_chip_relief: Relief = .flat,
    taskbar_chip_active_relief: Relief = .flat,
    select_relief: Relief = .flat,
    select_popup_relief: Relief = .flat,
    checkbox_relief: Relief = .flat,
    toggle_track_relief: Relief = .flat,
    toggle_thumb_relief: Relief = .flat,
    slider_track_relief: Relief = .flat,
    slider_thumb_relief: Relief = .flat,
    // Relief for the controls that had none: the segmented control (frame and
    // selected cell), stepper, swatch, a slider's value pill, and list rows
    // (hovered, selected). A raised box casts shadows `relief_depth +
    // relief_softness` past its edge, so cells and rows packed into a layout
    // want `inset`.
    segmented_relief: Relief = .flat,
    segmented_selected_relief: Relief = .flat,
    stepper_relief: Relief = .flat,
    swatch_relief: Relief = .flat,
    pill_relief: Relief = .flat,
    row_hover_relief: Relief = .flat,
    row_selected_relief: Relief = .flat,
    /// The scrollbar's channel (`widgets/scrollbar.zig`): flat draws no track at
    /// all (the thumb alone), inset a groove the thumb sits in.
    scrollbar_track_relief: Relief = .flat,
    /// Relief on the scrollbar thumb; raised shadows stay inside its channel.
    scrollbar_thumb_relief: Relief = .flat,
    // 0 sizes the menu to the output (`start_menu/size.zig`); set either to pin it.
    start_menu_width: f32 = 0,
    start_menu_max_height: f32 = 0,
    start_menu_radius: f32 = 14.0,
    /// Straight 45-degree panel corners instead of start_menu_radius; zero is rounded.
    start_menu_bevel: f32 = 0,
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
    toggle_on: ?[4]f32 = null,
    toggle_thumb: ?[4]f32 = null,
    toggle_shaded: bool = false,
    control_thumb: [4]f32 = .{ 1, 1, 1, 1 },
    slider_track: [4]f32 = .{ 1, 1, 1, 0.08 },
    slider_shaded: bool = false,
    slider_highlight: ?[4]f32 = null,
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
    // Taskbar Wi-Fi and battery panels. Unset colours retain the stock look.
    popup_bg: ?[4]f32 = null,
    popup_border: ?[4]f32 = null,
    popup_radius: f32 = 9,
    popup_blur: bool = false,
    popup_card_bg: ?[4]f32 = null,
    popup_card_fg: ?[4]f32 = null,
    popup_card_dim: ?[4]f32 = null,
    popup_card_border: ?[4]f32 = null,
    popup_card_radius: f32 = 12,
    popup_battery_ring: ?[4]f32 = null,
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
    /// Unset desktop selection colours follow the shell accent.
    desktop_selected: ?[4]f32 = null,
    desktop_selection: ?[4]f32 = null,
    desktop_selection_border: ?[4]f32 = null,
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
    /// Settings section titles and explanatory text; row labels use app_text_size.
    settings_title_size: f32 = 17,
    settings_description_size: f32 = 12,
    /// Bluetooth's connected indicator, independent of the accent palette.
    status_connected: [4]f32 = .{ 0.2, 0.86, 0.45, 1 },
    /// Outline of an unselected screen in the display arrangement preview.
    display_tile_border: [4]f32 = .{ 1, 1, 1, 0.16 },
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
    /// Straight 45-degree corners on the power menu panel, logical px; its tiles
    /// and selection outline take three quarters. Zero keeps them rounded.
    power_menu_bevel: f32 = 0,
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

    /// Resolve once in standalone clients, keeping every shared widget and
    /// Cairo text caller on the same effective foreground and field palette.
    pub fn forApp(t: Theme) Theme {
        var result = t;
        result.window_fg = t.app_fg orelse t.window_fg;
        result.window_dim = t.app_fg orelse t.window_dim;
        result.window_bg = t.app_menu_bg orelse t.window_bg;
        result.field_bg = t.app_field_bg orelse t.field_bg;
        result.field_border = t.app_field_border orelse t.field_border;
        result.surface_hover = t.app_surface_hover orelse t.surface_hover;
        return result;
    }

    pub fn sidebarForeground(t: Theme) [4]f32 {
        return t.app_sidebar_fg orelse t.window_fg;
    }

    pub fn sidebarSelected(t: Theme) [4]f32 {
        return t.app_sidebar_selected orelse t.app_nav_selected;
    }

    pub fn sidebarHover(t: Theme) [4]f32 {
        return t.app_sidebar_hover orelse t.app_item_hover;
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

    pub fn desktopSelectedColor(t: Theme) [4]f32 {
        return t.desktop_selected orelse t.desktopAccent(0.12);
    }

    pub fn desktopSelectionColor(t: Theme) [4]f32 {
        return t.desktop_selection orelse t.desktopAccent(0.15);
    }

    pub fn desktopSelectionBorder(t: Theme) [4]f32 {
        return t.desktop_selection_border orelse t.desktopAccent(1);
    }

    fn desktopAccent(t: Theme, alpha: f32) [4]f32 {
        const color = t.shell_accent orelse t.start_menu_selected_marker;
        return .{ color[0], color[1], color[2], color[3] * alpha };
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

/// The colour and clock-style tokens the taskbar draws with. A taskbar theme (Appearance's
/// "Task Bar theme", `[taskbar_theme]` in the config) replaces just these, and
/// only on the taskbar: every other surface keeps the main theme. Geometry
/// (`taskbar_size`, chip and start-button sizes and gaps, radii) stays with the
/// main theme, which has sliders for it.
pub const TaskbarToken = enum {
    clock_bold,
    clock_italic,
    taskbar_bg,
    taskbar_surface,
    taskbar_hover,
    taskbar_border,
    taskbar_outline,
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

/// A taskbar token: the taskbar theme's when one is chosen, else the main
/// theme's. The taskbar reads these instead of `global` so the two can differ.
pub fn taskbar(comptime token: TaskbarToken) @FieldType(Theme, @tagName(token)) {
    if (taskbar_override) |chosen| return @field(chosen, @tagName(token));
    return @field(global, @tagName(token));
}

/// Just `t`'s taskbar tokens over a default theme: the form `taskbar_override`
/// holds, so nothing else of `t` (its strings in particular) is kept.
pub fn taskbarTokens(t: Theme) Theme {
    var out: Theme = .{};
    inline for (@typeInfo(TaskbarToken).@"enum".field_names) |field_name| @field(out, field_name) = @field(t, field_name);
    return out;
}

/// Whether two themes' taskbar tokens look the same once written: colours
/// compare as `writeTaskbarInto` stores them, so a saved and reloaded theme
/// still equals the preset it came from.
pub fn taskbarTokensEql(a: Theme, b: Theme) bool {
    inline for (@typeInfo(TaskbarToken).@"enum".field_names) |field_name| {
        if (!sameWritten(@field(a, field_name), @field(b, field_name))) return false;
    }
    return true;
}

fn sameWritten(a: anytype, b: @TypeOf(a)) bool {
    if (comptime @TypeOf(a) == bool) return a == b;
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

/// Whether a token is one the Sharp/Default/Round presets rescale. The
/// taskbar's corner radius is a shape of its own (its square default has
/// nothing to scale), so a preset must neither reset nor be undone by it.
fn presetRadius(comptime name: []const u8) bool {
    if (@FieldType(Theme, name) != f32) return false;
    if (!std.mem.startsWith(u8, name, "radius") and !std.mem.endsWith(u8, name, "_radius")) return false;
    return !std.mem.eql(u8, name, "taskbar_radius");
}

pub fn applyRadiusPreset(t: *Theme, preset: RadiusPreset) void {
    @setEvalBranchQuota(10000);
    const defaults: Theme = .{};
    inline for (@typeInfo(Theme).@"struct".field_names) |field_name| {
        if (comptime presetRadius(field_name)) {
            const base = @field(defaults, field_name);
            @field(t, field_name) = switch (preset) {
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
    @setEvalBranchQuota(10000);
    for ([_]RadiusPreset{ .sharp, .default, .round }) |preset| {
        var candidate: Theme = .{};
        applyRadiusPreset(&candidate, preset);
        var matches = true;
        inline for (@typeInfo(Theme).@"struct".field_names) |field_name| {
            if (comptime presetRadius(field_name)) {
                if (@abs(@field(t, field_name) - @field(candidate, field_name)) > 0.001) matches = false;
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
pub const chrome_base: [4]f32 = .{ 38.0 / 255.0, 45.0 / 255.0, 55.0 / 255.0, 1 };

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

const theme_file = @import("theme_file.zig");
pub const resolvePath = theme_file.resolvePath;
pub const loadGlobal = theme_file.loadGlobal;
pub const load = theme_file.load;
pub const color_keys = theme_file.color_keys;
pub const number_keys = theme_file.number_keys;
pub const optional_color_keys = theme_file.optional_color_keys;
pub const parse = theme_file.parse;
pub const overlay = theme_file.overlay;
pub const stripComment = theme_file.stripComment;
pub const applyKey = theme_file.applyKey;
pub const save = theme_file.save;
const quantize = theme_file.quantize;
pub const knownKey = theme_file.knownKey;
pub const writeInto = theme_file.writeInto;
pub const writeOverrides = theme_file.writeOverrides;
pub const saveOverlay = theme_file.saveOverlay;
pub const writeTaskbarInto = theme_file.writeTaskbarInto;
pub const unquote = theme_file.unquote;
pub const parseColor = theme_file.parseColor;

test {
    _ = @import("theme_tests.zig");
}
