# Theme reference

Put these keys in `[theme]` in `$XDG_CONFIG_HOME/rediwm/config.toml`.
`REDIWM_CONFIG` selects another config file; `REDIWM_THEME` overlays another
file's `[theme]` section. Omitted keys use the built-in defaults below.
Appearance saves custom tokens along with its sliders and selectors.
The bundled picker includes RediWM Dark, RediWM Light and Redi Blue. Redi Blue
uses navy surfaces, cyan accents, 98% chrome opacity and a 30% selection tint.
RediWM Light uses 75% window chrome opacity and teal selection accents.
`start_button_logo_color` optionally tints the bundled R logo; Light uses a
dark tint for contrast. Custom start-button icons retain their own colours.

Appearance also has a **Taskbar theme** picker under Theme, with the same
presets plus "Same as theme". It gives the taskbar the preset's colours and
leaves every other surface on the theme above. It is saved as a
`[taskbar_theme]` section holding only these keys: `taskbar_bg`,
`taskbar_surface`, `taskbar_hover`, `taskbar_border`, `border_soft`,
`surface_hover`, `window_fg`, `window_dim`, `danger`, `window_close_hover`,
`start_button_hover`, `start_button_indicator`, `start_button_logo_color` and
the `battery_*` colours. Unlisted keys are ignored, so a whole theme file's
body can be pasted under that header; keys it leaves out take the built-in
defaults, not the main theme's. The section's presence selects the taskbar
theme (an empty one is the built-in colours); without it the taskbar follows
`[theme]`. Sizes, gaps and radii always come from `[theme]`.

Colors accept `"#rrggbb"`, `"#rrggbbaa"`, or `"rgba(r,g,b,a)"` with RGB
channels from 0 to 255 and alpha from 0 to 1. Numbers must be finite and
nonnegative. Sizes are logical pixels. The tables describe appearance tokens;
window placement, animation timing, cursor themes and sizes, blur, inactive
opacity and frame radius also have settings in the other config sections.

```toml
[theme]
shell_accent = "#86bfff"
control_thumb = "#ffffff"
toggle_track = "rgba(120,140,170,0.25)"
slider_track_height = 6
app_text_size = 14
app_heading_size = 13
app_status_size = 12
desktop_selection = "rgba(80,140,220,0.2)"
desktop_selection_border = "#508cdc"
battery_full = "#40dca0"
image_checker_size = 16
pdf_search_match = "rgba(100,180,255,0.4)"
```

## Palettes and reload

Shell surfaces use `window_fg` and `window_dim`. Their accent normally follows
`start_menu_selected_marker`; `shell_accent`, `shell_on_accent` and
`shell_border_focus` override that palette and its control/field focus rings. Settings uses `settings_radius` for
controls. Text fields, carets and text selection have optional overrides that
otherwise follow the accent of the surface displaying them.

Files' New, Sort and Filter buttons share the secondary-button palette:
`surface` sets the background, `surface_hover` the hover fill, and `border_soft`
the border. Their text and icons use `window_fg`. Active Filter and view-mode
buttons use `shell_accent` (or `start_menu_selected_marker` when unset), tinted
by `button_selected_alpha`. All of these values can be set in `[theme]`;
Files follows edits while running.

Files' dialog bodies and context menus share `app_toolbar` as their background
color. Changing it in `[theme]` updates both.

The compositor reloads the theme when the config changes. Files and Images
follow saved colors and sizes; PDF and Editor load them when starting. The
compositor's frame radius is the numeric `[theme].radius_lg`. The legacy
`[compositor].border_radius` is used only when the theme omits `radius_lg`.
Appearance's Radius presets write all numeric radius tokens: Default restores
the current built-in radii, Sharp caps them at 4 px (the minimap's default),
and Round uses 1.3 times the defaults. Individual theme radii remain editable.
Cursor styling is `[input].cursor_theme` and `[input].cursor_size`; animation behavior belongs in `[animations]`.

Set `[theme].chrome_round_buttons = true` for circular window controls and
pill-shaped window tabs. Tab close, new-tab and overflow controls follow the
same setting. It defaults to `false`, preserving the existing corner radii,
and reloads live from the main config or the `REDIWM_THEME` file. Button sizes
and hit targets stay the same; `radius_lg` still controls the window frame.

The lock's background always paints opaque, even if `lock_bg` supplies alpha;
`lock_wallpaper_opacity` controls its wallpaper overlay. Actual image pixels,
PDF paper/content, application-provided icons and fixed layout/hit-test
geometry retain their content or structural dimensions.

## Colors

| Key | Built-in default |
| --- | --- |
| `window_bg` | `"rgba(7.6,9,11,0.80)"` |
| `window_fg` | `"rgba(245,245,245,1)"` |
| `window_dim` | `"rgba(214,214,214,1)"` |
| `window_border` | `"rgba(255,255,255,0.09)"` |
| `window_border_hover` | `"rgba(255,255,255,0.13)"` |
| `window_divider` | `"rgba(255,255,255,0.045)"` |
| `window_close_hover` | `"rgba(237,27,46,1)"` |
| `text_secondary` | `"rgba(214,214,214,1)"` |
| `app_bg` | `"rgba(24,28,34,1)"` |
| `app_toolbar` | `"rgba(29,34,41,1)"` |
| `app_sidebar` | `"rgba(27,33,40,1)"` |
| `app_bar` | `"rgba(35,42,51,1)"` |
| `app_item` | `"rgba(34,40,46,1)"` |
| `app_item_hover` | `"rgba(37,43,50,1)"` |
| `app_item_border` | `"rgba(45,51,58,1)"` |
| `app_item_selected` | `"rgba(78,37,46,1)"` |
| `app_nav_selected` | `"rgba(91,36,46,1)"` |
| `app_divider` | `"rgba(55,63,72,1)"` |
| `app_icon` | `"rgba(214,214,214,1)"` |
| `scrollbar_thumb` | `"rgba(89,98,110,1)"` |
| `scrollbar_thumb_active` | `unset` |
| `bg` | `"rgba(9,11,24,1)"` |
| `fg` | `"rgba(245,245,245,1)"` |
| `dim` | `"rgba(214,214,214,1)"` |
| `faint` | `"rgba(160,160,160,1)"` |
| `accent` | `"rgba(94,234,212,1)"` |
| `surface` | `"rgba(255,255,255,0.05)"` |
| `border` | `"rgba(255,255,255,0.09)"` |
| `accent_2` | `"rgba(167,139,250,1)"` |
| `accent_3` | `"rgba(244,114,182,1)"` |
| `danger` | `"rgba(248,113,113,1)"` |
| `glass` | `"rgba(15,19,38,0.56)"` |
| `glass_strong` | `"rgba(12,15,30,0.74)"` |
| `taskbar_bg` | `"rgba(24,28,34,0.96)"` |
| `border_soft` | `"rgba(255,255,255,0.06)"` |
| `border_hover` | `"rgba(255,255,255,0.22)"` |
| `surface_hover` | `"rgba(255,255,255,0.08)"` |
| `taskbar_surface` | `"rgba(255,255,255,0.025)"` |
| `taskbar_hover` | `"rgba(255,255,255,0.05)"` |
| `taskbar_border` | `"rgba(255,255,255,0.07)"` |
| `on_accent` | `"rgba(8,33,28,1)"` |
| `border_focus` | `"rgba(94,234,212,0.4)"` |
| `caret` | `unset` |
| `selection` | `unset` |
| `selection_fg` | `unset` |
| `field_bg` | `"rgba(21,26,31,1)"` |
| `field_border` | `"rgba(63,70,77,1)"` |
| `field_border_focus` | `unset` |
| `shadow` | `"rgba(0,0,0,0.35)"` |
| `start_menu_bg` | `"rgba(29,34,41,0.98)"` |
| `start_menu_border` | `"rgba(255,255,255,0.12)"` |
| `start_menu_search_bg` | `"rgba(21,26,31,1)"` |
| `start_menu_selected_bg` | `"rgba(255,255,255,0.045)"` |
| `start_menu_selected_border` | `"rgba(237,27,46,0.35)"` |
| `start_menu_selected_marker` | `"rgba(237,27,46,1)"` |
| `toggle_track` | `"rgba(255,255,255,0.12)"` |
| `control_thumb` | `"rgba(255,255,255,1)"` |
| `slider_track` | `"rgba(255,255,255,0.08)"` |
| `pill_bg` | `"rgba(255,255,255,0.05)"` |
| `swatch_border` | `"rgba(255,255,255,0.1)"` |
| `swatch_border_selected` | `"rgba(255,255,255,0.6)"` |
| `settings_card_bg` | `"rgba(255,255,255,0.025)"` |
| `lock_bg` | `"rgba(4,5,7,1)"` |
| `lock_fg` | `"rgba(247,247,250,1)"` |
| `lock_dim` | `"rgba(168,173,186,1)"` |
| `lock_divider` | `"rgba(76,82,92,0.6)"` |
| `lock_session_fg` | `"rgba(219,222,230,1)"` |
| `switcher_bg` | `"rgba(9,10,14,1)"` |
| `switcher_border` | `"rgba(153,51,66,0.65)"` |
| `switcher_item_bg` | `"rgba(23,26,31,1)"` |
| `switcher_item_border` | `"rgba(255,255,255,0.13)"` |
| `switcher_fg` | `"rgba(240,242,247,1)"` |
| `switcher_dim` | `"rgba(153,158,168,1)"` |
| `switcher_icon_bg` | `"rgba(26,28,33,1)"` |
| `switcher_selected_border` | `"rgba(255,31,51,1)"` |
| `calendar_border` | `"rgba(255,255,255,0.16)"` |
| `osd_border` | `"rgba(255,255,255,0.12)"` |
| `screenshot_shade` | `"rgba(0,0,0,0.36)"` |
| `screenshot_border` | `"rgba(255,6,23,1)"` |
| `screenshot_fg` | `"rgba(255,255,255,1)"` |
| `screenshot_label_bg` | `"rgba(10,13,15,0.95)"` |
| `screenshot_label_border` | `"rgba(255,255,255,0.2)"` |
| `battery_bg` | `"rgba(5,10,10,0.28)"` |
| `battery_full` | `"rgba(32,226,157,1)"` |
| `battery_low` | `"rgba(250,204,65,1)"` |
| `battery_critical` | `"rgba(245,75,85,1)"` |
| `battery_shimmer` | `"rgba(110,255,200,1)"` |
| `desktop_fg` | `"rgba(238,241,251,1)"` |
| `desktop_text_shadow` | `"rgba(0,0,0,0.22)"` |
| `desktop_hover` | `"rgba(255,255,255,0.06)"` |
| `desktop_selected` | `"rgba(237,27,46,0.12)"` |
| `desktop_selection` | `"rgba(237,27,46,0.15)"` |
| `desktop_selection_border` | `"rgba(237,27,46,1)"` |
| `desktop_drop_border` | `"rgba(237,27,46,0.8)"` |
| `desktop_dialog_bg` | `"rgba(9,11,24,0.98)"` |
| `desktop_notice_bg` | `"rgba(31,9,15,0.95)"` |
| `desktop_icon_start` | `"rgba(64,166,168,1)"` |
| `desktop_icon_end` | `"rgba(89,79,158,1)"` |
| `file_broken` | `"rgba(239,68,68,1)"` |
| `file_folder_back` | `"rgba(163,171,181,1)"` |
| `file_folder_front` | `"rgba(184,191,201,1)"` |
| `file_document` | `"rgba(148,163,184,1)"` |
| `file_document_lines` | `"rgba(203,213,225,1)"` |
| `file_spinner` | `"rgba(166,173,184,1)"` |
| `image_checker_dark` | `"rgba(33,36,38,1)"` |
| `image_checker_light` | `"rgba(43,46,48,1)"` |
| `image_crop_shade` | `"rgba(0,0,0,0.58)"` |
| `image_crop_border` | `"rgba(255,255,255,1)"` |
| `image_crop_grid` | `"rgba(255,255,255,0.4)"` |
| `image_dialog_backdrop` | `"rgba(0,0,0,0.65)"` |
| `pdf_page_shadow` | `"rgba(0,0,0,0.35)"` |
| `pdf_page_border` | `"rgba(0,0,0,0.15)"` |
| `pdf_loading` | `"rgba(153,153,153,1)"` |
| `pdf_search_match` | `"rgba(255,230,0,0.4)"` |
| `pdf_search_match_active` | `"rgba(255,153,0,0.65)"` |
| `pdf_thumbnail_bg` | `"rgba(242,245,250,1)"` |
| `pdf_thumbnail_shadow` | `"rgba(0,0,0,0.3)"` |
| `pdf_search_shadow` | `"rgba(0,0,0,0.4)"` |
| `pdf_dialog_backdrop` | `"rgba(0,0,0,0.6)"` |
| `dialog_backdrop` | `"rgba(0,0,0,0.18)"` |
| `shell_accent` | `unset` |
| `shell_on_accent` | `unset` |
| `shell_border_focus` | `unset` |
| `window_close_fg` | `"rgba(255,255,255,1)"` |
| `start_button_hover` | `"rgba(255,255,255,0.035)"` |
| `start_button_indicator` | `"rgba(255,255,255,0.5)"` |
| `polkit_backdrop` | `"rgba(0,0,0,0.55)"` |
| `power_menu_backdrop` | `"rgba(0,0,0,0.45)"` |

`accent_2`, `accent_3`, `glass_strong` and `border_focus` are compatibility
keys retained by the reader and saver; current painters use the specific
surface and control tokens above. `scrollbar_thumb_active` now overrides the
hover/drag color; omitted, it follows the surface accent.

## Sizes and styling

Numeric tokens accept 0–4096 unless constrained below. Fractions ending in
`_alpha` or `_opacity`, and `dialog_glyph_lift`, accept 0–1.

| Key | Built-in default |
| --- | --- |
| `font_size` | `13.0` |
| `radius` | `5.0` |
| `radius_md` | `7.0` |
| `radius_lg` | `10.0` |
| `title_size` | `13.5` |
| `chrome_height` | `46.0` |
| `chrome_control_gap` | `4.0` |
| `taskbar_title_size` | `12.5` |
| `taskbar_size` | `48.0` |
| `chip_gap` | `4.0` |
| `chip_width` | `220.0` |
| `start_button_gap` | `4.0` |
| `start_button_icon_size` | `42.0` |
| `button_font_size` | `12.5` |
| `caret_width` | `1.5` |
| `scrollbar_width` | `8.0` |
| `selection_alpha` | `0.35` |
| `field_radius` | `8.0` |
| `shadow_size` | `24.0` |
| `shadow_offset_y` | `8.0` |
| `start_menu_width` | `0` (automatic) |
| `start_menu_max_height` | `0` (automatic) |
| `start_menu_radius` | `14.0` |
| `start_menu_left_pad` | `2.0` |
| `start_menu_bottom_pad` | `6.0` |
| `start_menu_icon_left_pad` | `2.0` |
| `start_menu_icon_bottom_pad` | `6.0` |
| `settings_radius` | `8` |
| `settings_sidebar_radius` | `10` |
| `settings_card_radius` | `9` |
| `checkbox_radius` | `4` |
| `toggle_radius` | `5` |
| `toggle_thumb_radius` | `4` |
| `slider_track_height` | `5.5` |
| `slider_settings_track_height` | `11` |
| `slider_thumb_size` | `12` |
| `slider_settings_thumb_height` | `20` |
| `slider_thumb_radius` | `4` |
| `slider_track_grow` | `0.25` |
| `slider_track_tint_alpha` | `0.45` |
| `slider_fill_alpha` | `0.6` |
| `pill_active_alpha` | `0.16` |
| `pill_border_active_alpha` | `0.55` |
| `segmented_selected_alpha` | `0.15` |
| `swatch_radius` | `6` |
| `swatch_glow_alpha` | `0.8` |
| `dialog_badge_radius` | `16` |
| `dialog_badge_alpha` | `0.18` |
| `dialog_glyph_lift` | `0.3` |
| `dialog_title_size` | `26` |
| `dialog_subtitle_size` | `15` |
| `dialog_inset_radius` | `12` |
| `scrollbar_radius` | `3` |
| `scrollbar_rest_width` | `0.75` |
| `scrollbar_active_width` | `1.125` |
| `switcher_radius` | `24` |
| `switcher_item_radius` | `12` |
| `switcher_icon_radius` | `10` |
| `switcher_selection_radius` | `15` |
| `switcher_title_size` | `15` |
| `switcher_app_size` | `12` |
| `calendar_radius` | `9` |
| `calendar_opacity` | `0.98` |
| `osd_radius` | `10` |
| `osd_opacity` | `0.97` |
| `lock_wallpaper_opacity` | `0.24` |
| `image_checker_size` | `12` |
| `start_button_radius` | `6` |
| `mini_map_bg_opacity` | `0.91` |
| `mini_map_grid_alpha` | `0.065` |
| `mini_map_border_alpha` | `0.12` |
| `mini_map_window_alpha` | `0.55` |
| `mini_map_marker_alpha` | `0.12` |
| `mini_map_marker_border_alpha` | `0.85` |
| `mini_map_radius` | `4` |
| `app_text_size` | `13` |
| `app_heading_size` | `12` |
| `app_status_size` | `11.5` |
| `desktop_text_size` | `11.5` |
| `window_close_hover_alpha` | `0.85` |
| `button_disabled_alpha` | `0.5` |
| `button_hover_brightness` | `1.08` |
| `button_selected_alpha` | `0.6` |
| `button_selected_hover_alpha` | `0.7` |

| Additional constraint | Range |
| --- | --- |
| `chrome_height` | 28–84 |
| `chrome_control_gap` | 0–24 |
| `chip_width` | 64–400 |
| `scrollbar_width` | 4–24 |
| `scrollbar_rest_width`, `scrollbar_active_width` | 0.25–1.125 times the configured width |
| `image_checker_size` | 1–128 |

`taskbar_height` is an alias for `taskbar_size`. Layouts cap some dimensions to
fit their available space. The scrollbar reserves room for its maximum width;
`slider_*` keys control slider geometry while sharing the scrollbar feedback.

## Strings

| Key | Built-in default | Meaning |
| --- | --- | --- |
| `font` | `"Manrope"` | Compositor's preferred proportional font family |
| `mono_font` | `"JetBrains Mono"` | Compositor's preferred monospace font family |
| `start_button_icon` | `""` | Bundled Redi logo; otherwise an absolute image path |

In **Settings → Appearance → Start menu**, **Choose file…** selects a PNG or
SVG for the Start button logo and applies it immediately. **Reset to default**
restores the bundled R logo. Both choices are saved with the theme. A preview
beside the buttons shows the logo as the taskbar draws it (the bundled R when a
chosen file cannot be loaded). The **Menu width** (400–900) and **Menu height**
(360–900) sliders in the same section set `start_menu_width` and
`start_menu_max_height`; the menu is still capped to the output. Left at `0`
(the default) the menu is sized to the screen: 560 x 600 on a screen of about
1700 x 1070 logical pixels or more, and the same share of the screen (33% wide,
56% high) on smaller ones, never below 400 x 360. **Size to screen** returns to
that.
