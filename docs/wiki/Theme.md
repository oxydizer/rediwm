# Theme reference

Put these keys in `[theme]` in `$XDG_CONFIG_HOME/rediwm/config.toml`.
`REDIWM_CONFIG` selects another config file; `REDIWM_THEME` overlays another
file's `[theme]` section. Omitted keys use the built-in defaults below, and
Appearance saves custom tokens along with its sliders and selectors.

## Theme packs and the picker

The picker offers RediWM Dark, RediWM Light and Redi Blue (navy surfaces, cyan
accents, 98% chrome opacity, 30% selection tint). Light uses 75% window chrome
opacity and teal selection accents.

Redi-Mocha (Catppuccin Mocha palette, mauve accents, `wallpaper-mocha.png`) and
Gold are installed but hidden from the picker (`picker_hidden` in
`src/config/theme_pack.zig`). A config with `base = "redi-mocha"` or `"gold"`
loads as before, keeps its overrides, and still shows as selected; switching
away removes it from the list. `chamfer-blue` (`assets/themes/chamfer-blue.toml`)
is likewise not offered. Gold's clock is bold, not italic.

`start_button_logo_color` optionally tints the bundled R logo (Light uses a dark
tint); custom start-button icons keep their own colours.

**Taskbar theme** (Appearance, under Theme) takes the same presets plus "Same as
theme" and recolours only the taskbar; every other surface stays on the main
theme. It is saved as a `[taskbar_theme]` section that reads only these keys:
`clock_bold`, `clock_italic`, `taskbar_bg`, `taskbar_surface`, `taskbar_hover`,
`taskbar_border`, `taskbar_outline`, `border_soft`, `surface_hover`,
`window_fg`, `window_dim`, `danger`, `window_close_hover`,
`start_button_hover`, `start_button_indicator`, `start_button_logo_color` and
the `battery_*` colours. Other keys are ignored, so a whole theme file's body can
be pasted under the header; keys it omits take the built-in defaults, not the
main theme's. An empty section is the built-in colours; no section means the
taskbar follows `[theme]`. Sizes, gaps and radii always come from `[theme]`.

**Bold clock text** and **Italic clock text** (Appearance → Taskbar) style both
time and date, save into the taskbar theme (or the main theme when the taskbar
follows it), and default to false.

## GTK and Qt app colors

**Apply GTK colors** and **Apply Qt colors** (Settings → Appearance, below the
theme selectors) export the main theme's app backgrounds, toolbar, sidebar, text
and shell accent; the taskbar override is not used. Exports are snapshots: apply
again after changing a theme, then restart the apps.

**GTK:** written to `gtk-3.0/rediwm-colors.css` and `gtk-4.0/rediwm-colors.css`
under `$XDG_CONFIG_HOME` (else `~/.config`), with a marked import added at the
*end* of each `gtk.css` so it wins over other generators (matugen, DMS); the rest
of the file is kept, and an older block that sits first is moved. GTK3 gets
common widget overrides, GTK4 also the CSS variables recent libadwaita uses. No
theme package is patched and the dark-mode preference is never flipped.

**Qt:** needs **qt5ct** (Qt 5) or **qt6ct** (Qt 6). The toolkit configs select
native `colors/rediwm.conf` palettes and the palette-aware Fusion style; other
preferences are kept. RediWM launches get the platform theme at once; sign in
again for apps activated by D-Bus or launched elsewhere. The opt-in is recorded
in `rediwm/app-colors.conf`. KDE apps such as Dolphin read `kdeglobals`, so the
export also rewrites its `[Colors:*]` groups (Window, View, Button, Selection,
Tooltip, Complementary, Header), keeps other keys, and saves the first copy as
`kdeglobals.rediwm-backup`. That file is shared with any Plasma session.
Bundled Qt runtimes, sandboxed apps and apps with their own styles may need
their own configuration.

**Backups and undo:** the first existing config is backed up beside the original
as `<filename>.rediwm-backup`, and later applications keep that first backup. A
symlinked `gtk.css` or Qt config (e.g. from another theming tool) is replaced by
a regular file with its current contents plus the RediWM block; the target is not
modified. A symlinked config *folder* is refused and reported in Settings. To
undo GTK, remove the marked import blocks from both `gtk.css` files (or restore
the backups). To undo Qt, restore the qt5ct/qt6ct and `kdeglobals` backups (or
delete configs the export created if none exists), remove
`rediwm/app-colors.conf`, and sign in again.

## Token syntax

Colors accept `"#rrggbb"`, `"#rrggbbaa"` or `"rgba(r,g,b,a)"` (RGB 0–255, alpha
0–1). Numbers must be finite and nonnegative; sizes are logical pixels. Window
placement, animation timing, cursor theme and size, blur, inactive opacity and
frame radius have settings in the other config sections.

```toml
[theme]
shell_accent = "#86bfff"
toggle_track = "rgba(120,140,170,0.25)"
slider_track_height = 6
app_text_size = 14
pdf_search_match = "rgba(100,180,255,0.4)"
```

## Behavior

**Accent and focus.** Shell surfaces use `window_fg` and `window_dim`. Their
accent follows `start_menu_selected_marker` unless `shell_accent`,
`shell_on_accent` or `shell_border_focus` override it (and the control/field
focus rings). Text fields, carets and selections have optional overrides that
otherwise follow the accent of the surface showing them. Settings controls use
`settings_radius`.

**Files.** The New, Sort and Filter buttons share the secondary-button palette:
`surface` (background), `surface_hover` (hover) and `border_soft` (border), with
`window_fg` text and icons. Active Filter and view-mode buttons use
`shell_accent` (else `start_menu_selected_marker`), tinted by
`button_selected_alpha`. Dialog bodies and context menus use `app_toolbar` as
their background. Files follows edits while running.

**Reload.** The compositor reloads the theme when the config changes. Files and
Images follow saved colors and sizes; PDF and Editor load them at start.

**Radius.** The frame radius is the numeric `radius_lg`; the legacy
`[compositor].border_radius` applies only when the theme omits it. Appearance's
Radius presets write every numeric radius token: Default restores the built-in
radii, Sharp caps them at 4 px, Round uses 1.3 times the defaults. Individual
radii stay editable and the presets leave `taskbar_radius` alone. Cursor styling
is `[input].cursor_theme` and `cursor_size`; animation belongs in `[animations]`.

**Round window controls.** `chrome_round_buttons = true` makes window controls
circular and window tabs pill-shaped (tab close, new-tab and overflow follow).
Default `false`; reloads live; sizes and hit targets are unchanged.

**Window shape.** `window_shape` replaces the rounded rectangle of
server-decorated windows with a polygon of up to 16 `"x y"` points separated by
commas. A coordinate is logical px from the left/top edge, a negative one (`-0`
included) px from the right/bottom edge, and `N%` a fraction of the window, so an
outline fits any size. For example
`window_shape = "0 14, 14 0, -160 0, -148 3, -14 3, -0 17, -0 -14, -14 -0, 14 -0, 0 -14"`
cuts the corners and steps the top edge down for its last 160 px. Ring, shadow,
glass and pointer picking follow the outline. An unparseable outline is refused
at load; one that crosses itself at a window's size (narrower than its notches)
falls back to the rounded rectangle, as do maximized and fullscreen windows.
`window_top_band` (colour) and `window_top_band_height` (px, 0 = none) paint a
strip along the top of the titlebar, clipped by the shape. Titlebar icon, title,
controls and the tab strip's right end keep in from slanted or cut ends over the
rows they occupy. The outline's GL programs are built the first time a theme
asks for one, so themes without `window_shape` or `taskbar_shape` never pay for
them.

**Taskbar shape.** `taskbar_shape` does the same against the bar's own box (`-0`
is its right or bottom edge) and replaces `taskbar_radius`; for example
`"0 -0, 14 0, 300 0, 312 6, -14 6, -0 -0"` is a raised left section, a 6 px step
down and a slanted right tip. Items keep clear of slanted ends but not of a
notch in the middle; the notch is transparent, clicks in it reach what is below,
and glass follows the outline. The bar is painted once per layout change.

**Lock.** The lock background always paints opaque even if `lock_bg` has alpha;
`lock_wallpaper_opacity` sets its wallpaper overlay. Image pixels, PDF content,
application icons and fixed layout/hit-test geometry keep their own dimensions.

## Defaults

Every key below is optional. Entries marked `unset` follow another token.

### Colors

```text
# Windows and text
window_bg = "rgba(7.6,9,11,0.80)"  window_fg = "rgba(245,245,245,1)"
window_dim = "rgba(214,214,214,1)"  window_border = "rgba(255,255,255,0.09)"
window_border_hover = "rgba(255,255,255,0.13)"  window_divider = "rgba(255,255,255,0.045)"
window_close_hover = "rgba(237,27,46,1)"  window_close_fg = "rgba(255,255,255,1)"
text_secondary = "rgba(214,214,214,1)"
# Base palette and fields
bg = "rgba(9,11,24,1)"  fg = "rgba(245,245,245,1)"  dim = "rgba(214,214,214,1)"
faint = "rgba(160,160,160,1)"  accent = "rgba(94,234,212,1)"  accent_2 = "rgba(167,139,250,1)"
accent_3 = "rgba(244,114,182,1)"  surface = "rgba(255,255,255,0.05)"
surface_hover = "rgba(255,255,255,0.08)"  border = "rgba(255,255,255,0.09)"
border_soft = "rgba(255,255,255,0.06)"  border_hover = "rgba(255,255,255,0.22)"
border_focus = "rgba(94,234,212,0.4)"  border_glow_enabled = true
border_glow = "rgba(237,27,46,0.6)"  danger = "rgba(248,113,113,1)"  glass = "rgba(15,19,38,0.56)"
glass_strong = "rgba(12,15,30,0.74)"  on_accent = "rgba(8,33,28,1)"  caret = unset
selection = unset  selection_fg = unset  field_bg = "rgba(21,26,31,1)"
field_border = "rgba(63,70,77,1)"  field_border_focus = unset  shadow = "rgba(0,0,0,0.35)"
shell_accent = unset  shell_on_accent = unset  shell_border_focus = unset
# Controls
scrollbar_thumb = "rgba(89,98,110,1)"  scrollbar_thumb_active = unset  scrollbar_glow = 1.0
toggle_track = "rgba(255,255,255,0.12)"  control_thumb = "rgba(255,255,255,1)"
slider_track = "rgba(255,255,255,0.08)"  pill_bg = "rgba(255,255,255,0.05)"
swatch_border = "rgba(255,255,255,0.1)"  swatch_border_selected = "rgba(255,255,255,0.6)"
settings_card_bg = "rgba(255,255,255,0.025)"  dialog_backdrop = "rgba(0,0,0,0.18)"
relief_dark = "rgba(0,0,0,0.35)"  relief_light = "rgba(255,255,255,0.1)"
# Taskbar, start menu, battery
taskbar_bg = "rgba(24,28,34,0.96)"  taskbar_surface = "rgba(255,255,255,0.025)"
taskbar_hover = "rgba(255,255,255,0.05)"  taskbar_border = "rgba(255,255,255,0.07)"
taskbar_outline = unset  start_menu_bg = "rgba(29,34,41,0.98)"
start_menu_border = "rgba(255,255,255,0.12)"  start_menu_search_bg = "rgba(21,26,31,1)"
start_menu_selected_bg = "rgba(255,255,255,0.045)"
start_menu_selected_border = "rgba(237,27,46,0.35)"
start_menu_selected_marker = "rgba(237,27,46,1)"  start_button_hover = "rgba(255,255,255,0.035)"
start_button_indicator = "rgba(255,255,255,0.5)"  battery_bg = "rgba(5,10,10,0.28)"
battery_full = "rgba(32,226,157,1)"  battery_low = "rgba(250,204,65,1)"
battery_critical = "rgba(245,75,85,1)"  battery_shimmer = "rgba(110,255,200,1)"
# Overlays and lock
switcher_bg = "rgba(9,10,14,1)"  switcher_border = "rgba(153,51,66,0.65)"
switcher_item_bg = "rgba(23,26,31,1)"  switcher_item_border = "rgba(255,255,255,0.13)"
switcher_fg = "rgba(240,242,247,1)"  switcher_dim = "rgba(153,158,168,1)"
switcher_icon_bg = "rgba(26,28,33,1)"  switcher_selected_border = "rgba(255,31,51,1)"
calendar_border = "rgba(255,255,255,0.16)"  osd_border = "rgba(255,255,255,0.12)"
screenshot_shade = "rgba(0,0,0,0.36)"  screenshot_border = "rgba(255,6,23,1)"
screenshot_fg = "rgba(255,255,255,1)"  screenshot_label_bg = "rgba(10,13,15,0.95)"
screenshot_label_border = "rgba(255,255,255,0.2)"  polkit_backdrop = "rgba(0,0,0,0.55)"
power_menu_backdrop = "rgba(0,0,0,0.45)"  lock_bg = "rgba(4,5,7,1)"  lock_fg = "rgba(247,247,250,1)"
lock_dim = "rgba(168,173,186,1)"  lock_divider = "rgba(76,82,92,0.6)"
lock_session_fg = "rgba(219,222,230,1)"
# Desktop and apps
desktop_fg = "rgba(238,241,251,1)"  desktop_text_shadow = "rgba(0,0,0,0.22)"
desktop_hover = "rgba(255,255,255,0.06)"  desktop_selected = "rgba(237,27,46,0.12)"
desktop_selection = "rgba(237,27,46,0.15)"  desktop_selection_border = "rgba(237,27,46,1)"
desktop_drop_border = "rgba(237,27,46,0.8)"  desktop_dialog_bg = "rgba(9,11,24,0.98)"
desktop_notice_bg = "rgba(31,9,15,0.95)"  desktop_icon_start = "rgba(64,166,168,1)"
desktop_icon_end = "rgba(89,79,158,1)"  file_broken = "rgba(239,68,68,1)"
file_folder_back = "rgba(163,171,181,1)"  file_folder_front = "rgba(184,191,201,1)"
file_document = "rgba(148,163,184,1)"  file_document_lines = "rgba(203,213,225,1)"
file_spinner = "rgba(166,173,184,1)"  image_checker_dark = "rgba(33,36,38,1)"
image_checker_light = "rgba(43,46,48,1)"  image_crop_shade = "rgba(0,0,0,0.58)"
image_crop_border = "rgba(255,255,255,1)"  image_crop_grid = "rgba(255,255,255,0.4)"
image_dialog_backdrop = "rgba(0,0,0,0.65)"  pdf_page_shadow = "rgba(0,0,0,0.35)"
pdf_page_border = "rgba(0,0,0,0.15)"  pdf_loading = "rgba(153,153,153,1)"
pdf_search_match = "rgba(255,230,0,0.4)"  pdf_search_match_active = "rgba(255,153,0,0.65)"
pdf_thumbnail_bg = "rgba(242,245,250,1)"  pdf_thumbnail_shadow = "rgba(0,0,0,0.3)"
pdf_search_shadow = "rgba(0,0,0,0.4)"  pdf_dialog_backdrop = "rgba(0,0,0,0.6)"
status_connected = "rgba(51,219.3,114.75,1)"  display_tile_border = "rgba(255,255,255,0.16)"
app_bg = "rgba(24,28,34,1)"  app_toolbar = "rgba(29,34,41,1)"  app_sidebar = "rgba(27,33,40,1)"
app_bar = "rgba(35,42,51,1)"  app_item = "rgba(34,40,46,1)"  app_item_hover = "rgba(37,43,50,1)"
app_item_border = "rgba(45,51,58,1)"  app_item_selected = "rgba(78,37,46,1)"
app_nav_selected = "rgba(91,36,46,1)"  app_divider = "rgba(55,63,72,1)"
app_icon = "rgba(214,214,214,1)"
```

Notes: `accent_2`, `accent_3`, `glass_strong` and `border_focus` are
compatibility keys kept by the reader and saver; painters use the specific
tokens. `scrollbar_thumb_active` overrides the hover/drag color (unset: the
surface accent). `border_glow` alpha 0 turns the highlight off. `scrollbar_glow`
is the strength of the thumb's light (`0` = flat thumb, no highlight stripe).
`relief_dark` and `relief_light` are the neumorphic shadows cast away from and
toward the light.

### Sizes and styling

Numeric tokens accept 0–4096 unless constrained below; `*_alpha`, `*_opacity`
and `dialog_glyph_lift` accept 0–1. `""` for a shape means the rounded
rectangle; `0` for `start_menu_width` and `start_menu_max_height` means
automatic.

```text
# Base
font_size = 13.0  radius = 5.0  radius_md = 7.0  radius_lg = 10.0  title_size = 13.5
chrome_height = 46.0  chrome_control_gap = 4.0  window_shape = ""  window_top_band = "rgba(0,0,0,0)"
window_top_band_height = 0.0  window_close_hover_alpha = 0.85  shadow_size = 24.0
shadow_offset_y = 8.0  relief_depth = 0.0  relief_softness = 0.0  relief_light_angle = 135.0
border_glow_length = 72.0  border_glow_reach = 56.0  border_glow_depth = 3.0
# Taskbar, clock, start menu
taskbar_shape = ""  taskbar_title_size = 12.5  taskbar_size = 44.0  taskbar_edge_gap = 0.0
taskbar_length = 100.0  taskbar_radius = 0.0  taskbar_outline_width = 1.0  clock_bold = false
clock_italic = false  chip_gap = 4.0  chip_width = 220.0  start_button_gap = 4.0
start_button_icon_size = 42.0  start_menu_width = 0  start_menu_max_height = 0
start_menu_radius = 14.0  start_menu_left_pad = 2.0  start_menu_bottom_pad = 6.0
start_menu_icon_left_pad = 2.0  start_menu_icon_bottom_pad = 6.0  start_button_radius = 6
# Controls
button_font_size = 12.5  button_disabled_alpha = 0.5  button_hover_brightness = 1.08
button_selected_alpha = 0.6  button_selected_hover_alpha = 0.7  caret_width = 1.5
scrollbar_width = 8.0  scrollbar_radius = 3  scrollbar_rest_width = 0.75
scrollbar_active_width = 1.125  selection_alpha = 0.35  field_radius = 8.0  settings_radius = 8
settings_sidebar_radius = 10  settings_card_radius = 9  settings_title_size = 17
settings_description_size = 12  checkbox_radius = 4  toggle_radius = 5  toggle_thumb_radius = 4
slider_track_height = 5.5  slider_settings_track_height = 11  slider_thumb_size = 12
slider_settings_thumb_height = 20  slider_thumb_radius = 4  slider_track_grow = 0.25
slider_track_tint_alpha = 0.45  slider_fill_alpha = 0.6  pill_active_alpha = 0.16
pill_border_active_alpha = 0.55  segmented_selected_alpha = 0.15  swatch_radius = 6
swatch_glow_alpha = 0.8  dialog_badge_radius = 16  dialog_badge_alpha = 0.18
dialog_glyph_lift = 0.3  dialog_title_size = 26  dialog_subtitle_size = 15  dialog_inset_radius = 12
# Overlays and apps
switcher_radius = 24  switcher_item_radius = 12  switcher_icon_radius = 10
switcher_selection_radius = 15  switcher_title_size = 15  switcher_app_size = 12
calendar_radius = 9  calendar_opacity = 0.98  osd_radius = 10  osd_opacity = 0.97
lock_wallpaper_opacity = 0.24  image_checker_size = 12  mini_map_bg_opacity = 0.91
mini_map_grid_alpha = 0.065  mini_map_border_alpha = 0.12  mini_map_window_alpha = 0.55
mini_map_marker_alpha = 0.12  mini_map_marker_border_alpha = 0.85  mini_map_radius = 4
app_text_size = 13  app_heading_size = 12  app_status_size = 11.5  desktop_text_size = 11.5
```

Further ranges: `chrome_height` 28–84, `chrome_control_gap` 0–24, `chip_width`
64–400, `taskbar_length` 20–100 (percent), `taskbar_outline_width` 0–8,
`scrollbar_width` 4–24, `scrollbar_rest_width` and `scrollbar_active_width`
0.25–1.125 times the configured width, `image_checker_size` 1–128.

`relief_depth` (0 = off) is how many px buttons and fields cast a dark and a
light shadow from their edge; `relief_softness` (0 = 1.5 × depth) is the fade
length; `relief_light_angle` is degrees counter-clockwise from the right (135 =
upper left). Layouts cap some dimensions to fit; the scrollbar reserves room for
its maximum width, and `slider_*` keys control slider geometry while sharing the
scrollbar feedback.

**Taskbar geometry.** `taskbar_height` aliases `taskbar_size`. The bar is flush,
full-width and square by default. `taskbar_edge_gap` (0–64 px; Appearance's
**Taskbar gap from edge**) floats it off its screen edge, `taskbar_length`
shortens it (centred; never narrower than its items need, 420 px) and
`taskbar_radius` rounds it (a pill at half the bar's height). Windows and panels
treat the bar and its gap as reserved space. `taskbar_outline_width` and
`taskbar_outline` (unset: `border_soft`) style the bar's outline: a flush bar
draws it only on the side facing the windows, a floating or rounded one all
round. `taskbar_border` stays the colour of the window buttons' and battery's
outlines.

### Component relief

When `relief_depth` > 0, controls can opt into `"flat"` (default), `"raised"` or
`"inset"` relief through these keys, all defaulting to `"flat"`:

```text
button_relief  button_pressed_relief  field_relief  dialog_inset_relief
dialog_frame_relief  settings_card_relief  taskbar_chip_relief
taskbar_chip_active_relief  select_relief  select_popup_relief  checkbox_relief
toggle_track_relief  toggle_thumb_relief  slider_track_relief  slider_thumb_relief
segmented_relief  segmented_selected_relief  stepper_relief  swatch_relief
pill_relief  row_hover_relief  row_selected_relief  scrollbar_track_relief
```

- Raised shadows reach `relief_depth + relief_softness` past a box and are cut
  at clipped containers, so use `inset` for segments, rows, pills and
  `settings_card_relief` (the page scrolls in a clipped container). `dialog_frame_relief`
  raised shadows lie outside the card.
- The standard slider fill overlays the start of the track, so an inset
  `slider_track_relief` can have its left groove shadow covered. The shaded
  slider and toggle paths keep their procedural lighting and add relief on top,
  dropping only what it would double (the toggle's track rim under a non-flat
  track relief, the knob's cast shadow under a non-flat thumb relief). Shadows
  skip the knob and stay inside the track or slider box.
- `taskbar_chip_relief` and `taskbar_chip_active_relief` (focused chip) shade
  inside the edge: `inset` is a groove, `raised` swaps the lights. Main theme
  only; `[taskbar_theme]` does not carry them.
- `scrollbar_track_relief`: `flat` draws no track, `inset` cuts a groove for the
  thumb. Pair with `scrollbar_glow = 0` for a flat thumb.
- A theme leaving everything `flat` renders as before.

## Strings

| Key | Default | Meaning |
| --- | --- | --- |
| `font` | `"Manrope"` | Preferred proportional font family |
| `mono_font` | `"JetBrains Mono"` | Preferred monospace font family |
| `start_button_icon` | `""` | Bundled Redi logo; otherwise an absolute image path |

**Settings → Appearance → Start menu:** **Choose file…** picks a PNG or SVG for
the Start button logo and applies it at once; **Reset to default** restores the
bundled R. Both are saved with the theme, and a preview shows the logo as the
taskbar draws it (the R if the file cannot be loaded). **Menu width** (400–900)
and **Menu height** (360–900) set `start_menu_width` and `start_menu_max_height`,
capped to the output. At `0` the menu is sized to the screen: 560 x 600 on
about 1700 x 1070 logical px or more, otherwise 33% wide and 56% high, never
below 400 x 360. **Size to screen** returns to that.
