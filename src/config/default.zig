// Documented default written to $XDG_CONFIG_HOME/rediwm/config.toml on first run.
pub const source =
    \\# ~/.config/rediwm/config.toml
    \\# Line-based TOML subset: one assignment/array per line, double-quoted strings.
    \\# No escape decoding, literal/multiline strings, inline tables or dotted keys.
    \\# See README.md, Configuration, for the supported syntax.
    \\
    \\# ───────────────────────────────────────────────
    \\# Theme — merged with/replaces REDIWM_THEME
    \\# ───────────────────────────────────────────────
    \\[theme]
    \\font         = "Manrope"
    \\mono_font    = "JetBrains Mono"
    \\# start_button_icon = "/absolute/path/to/logo.svg" # omitted/empty: bundled Redi logo
    \\font_size    = 13.0
    \\title_size = 13.5          # window title font size, independent of titlebar height
    \\chrome_height = 46.0       # window titlebar height, 28–84px; scales icons and controls
    \\chrome_control_gap = 4.0   # gap between window controls, 0–24px
    \\radius       = 5.0          # --r-sm base
    \\chrome_round_buttons = false # true: circular window controls and pill-shaped tabs
    \\bg           = "#090b18"    # shell background
    \\fg           = "#eef1fb"    # --text
    \\dim          = "#9aa2c4"    # --text-dim
    \\faint        = "#666d92"    # --text-faint
    \\accent       = "#5eead4"
    \\accent_2     = "#a78bfa"
    \\accent_3     = "#f472b6"
    \\danger       = "#f87171"
    \\glass        = "rgba(15,19,38,0.56)"
    \\border       = "rgba(255,255,255,0.09)"
    \\caret_width  = 1.5          # text insertion caret, not the mouse pointer
    \\scrollbar_width = 8.0      # every scrollbar, 4–24 logical px
    \\selection_alpha = 0.35       # highlight opacity when it follows the accent
    \\taskbar_size = 44.0         # taskbar height in pixels (36.0 to 84.0)
    \\chip_width  = 220.0        # preferred window item width, 64–400px; shrinks to fit
    \\chip_gap     = 4.0          # gap between taskbar window-item pills; also sets
    \\                            # each pill's top/bottom margin in the bar (capped)
    \\start_button_gap = 4.0     # gap to the left of the start button and between start button and first pill
    \\start_button_icon_size = 36.0  # start button logo size; capped to the button itself
    \\# start_menu_width = 560.0       # start menu size; omitted or 0 sizes it to the screen
    \\# start_menu_max_height = 600.0
    \\start_menu_left_pad = 2.0          # start menu distance from left edge
    \\start_menu_bottom_pad = 6.0        # start menu gap above the taskbar
    \\start_menu_icon_left_pad = 12.0   # start menu app row left/right inset
    \\start_menu_icon_bottom_pad = 6.0   # start menu app row top/bottom inset
    \\# More colors and styling: docs/wiki/Theme.md (all keys are optional).
    \\# control_thumb = "#ffffff"     # sliders and toggle thumbs
    \\# toggle_track = "rgba(255,255,255,0.12)"
    \\# slider_track_height = 5.5
    \\# app_text_size = 13.0
    \\# app_heading_size = 12.0
    \\# app_status_size = 11.5
    \\# desktop_selection = "rgba(237,27,46,0.15)"
    \\# battery_full = "#20e29d"
    \\# shell_accent = "#ed1b2e"      # unset follows start_menu_selected_marker
    \\# caret        = "#5eead4"   # unset follows whichever accent is in effect
    \\# selection    = "#5eead4"   # likewise, at selection_alpha
    \\# selection_fg = "#0a0e22"   # unset leaves selected text its normal colour
    \\
    \\# ───────────────────────────────────────────────
    \\# Input devices
    \\# ───────────────────────────────────────────────
    \\[input]
    \\natural_scroll    = true
    \\invert_scroll     = true      # flips scroll direction in the compositor itself,
    \\                              # so it works even on mice libinput won't natural-scroll
    \\pointer_speed         = -0.3      # -1.0 to 1.0
    \\pointer_speed_touchpad = -0.3      # -1.0 to 1.0
    \\accel_profile         = "bezier"   # flat | bezier
    \\accel_p1              = [0.0, 0.0]
    \\accel_p2              = [0.15, 1.0]
    \\accel_max_speed       = 10.0     # counts/ms at which curve reaches 1.0
    \\pan_speed         = 2.0      # 1.0-4.0, camera pan distance multiplier (modifier-drag / middle-drag)
    \\pan_modifier      = "super_alt" # super_alt | super: hold to pan by moving the pointer;
    \\                              # Super+Alt+wheel always zooms the whole desktop
    \\middle_button_pan = true      # middle-mouse-button drag pans the canvas; false leaves modifier-drag
    \\                              # panning intact and frees the middle button for client use
    \\wheel_acceleration     = 1.0  # 0-4; fast mouse-wheel runs scroll further per notch (0 = off)
    \\wheel_acceleration_max = 5.0  # 1-20; cap on the per-notch multiplier
    \\# wheel_acceleration_exclude = ["some-game"]  # app ids (prefix match) that get plain notches
    \\smooth_scroll     = false     # glide mouse-wheel notches in apps too (shell panels always glide)
    \\# smooth_scroll_exclude = ["brave", "chromium", "google-chrome", "microsoft-edge", "vivaldi",
    \\#                          "opera", "firefox", "librewolf", "floorp", "zen"]  # default: browsers,
    \\#                          # which smooth wheel scrolling themselves
    \\tap_to_click      = true
    \\tap_drag          = true
    \\disable_while_typing = true
    \\disable_while_typing_touchpad = true
    \\# Empty XKB names use XKB_DEFAULT_* or system defaults.
    \\xkb_layout = ""              # e.g. "us,ru"
    \\xkb_variant = ""
    \\xkb_options = ""             # e.g. "grp:caps_toggle"
    \\xkb_model = ""
    \\key_repeat_delay  = 400       # ms
    \\key_repeat_rate   = 25        # keys/sec
    \\cursor_theme      = "default"   # "default" = system cursor theme; or "phinger-cursors-dark" / "phinger-cursors-light" (bundled)
    \\cursor_size       = 32
    \\caret_blink_ms    = 1060      # full on+off cycle; 0 = never blink
    \\caret_blink_timeout = 10      # seconds idle before it goes solid; 0 = never
    \\caret_motion_ms   = 80        # glide between positions; 0 = snap
    \\
    \\# ───────────────────────────────────────────────
    \\# Compositor behaviour
    \\# ───────────────────────────────────────────────
    \\[input_method]
    \\env = "none"                 # none | fcitx | ibus; daemon uses [[autostart]]
    \\
    \\[compositor]
    \\# Allow fullscreen clients to request asynchronous presentation (may tear).
    \\allow_tearing = false
    \\# Only windows launched with the chrome + join that window’s tabs.
    \\window_tab_apps = []       # app IDs; Appearance provides a checkbox list
    \\# Desktop application IDs; empty keeps Files and the automatic terminal.
    \\default_file_manager = ""
    \\default_terminal = ""
    \\# Right-side taskbar items, left to right; prefix a name with - to hide it.
    \\taskbar_position = "bottom" # top or bottom
    \\taskbar_items = ["battery", "network", "volume", "clock"]
    \\focus_follows_mouse   = false
    \\canvas_columns        = 3      # screens wide (1-10)
    \\canvas_rows           = 3      # screens tall (1-10)
    \\mini_map_enabled     = true
    \\mini_map_position    = "bottom_right" # bottom_left, bottom_center, bottom_right
    \\mini_map_hide_ms     = 1500  # idle delay before hiding, 500-10000 ms
    \\desktop_icons_fixed   = true   # keep desktop icons fixed on screen
    \\desktop_switch_ms     = 220    # Super+arrow desktop slide, 100-3000 ms
    \\zoom_steps            = [1.0, 0.85, 0.70, 0.55, 0.40]
    \\camera_zoom_min       = 0.25
    \\camera_zoom_max       = 1.0
    \\focus_zoom            = "boost" # Window switching: keep, boost, or camera
    \\window_gap            = 0      # px around and between snapped windows
    \\snap_to_edges         = true   # drag a window to a screen edge to tile or maximize it
    \\dodge_file_drags      = true   # a file manager slides aside while you drag a file out of it
    \\switcher_opacity      = 1.0   # 0.0-1.0, background only; previews stay opaque
    \\inactive_opacity      = 1.0   # 0.0-1.0, 1.0 = no change
    \\border_radius         = 10    # window corner radius
    \\xwayland              = true  # X11 apps via Xwayland; false keeps native-only
    \\xwayland_native_scaling = false # sharp X11 apps on fractional scales (requires restart)
    \\xwayland_scale = 0 # global render factor: 0 = automatic, 1.0-4.0 = explicit (requires restart)
    \\dark_mode             = false # apps and web pages prefer dark (live; via the Settings portal)
    \\placeholder_delay_ms  = 0     # show splash only if app hasn't appeared after N ms (0 disables)
    \\# wallpaper = ""               # empty = RediWM's; a file in ~/.local/share/rediwm/wallpapers, or a path
    \\lid_close             = "display_off" # closing the laptop lid: display_off (built-in screen off while another display is on), lock, suspend, ignore
    \\lock_on_suspend       = true  # lock before the system sleeps (menu, lid, idle or another program)
    \\
    \\# ───────────────────────────────────────────────
    \\# Region & Language — this user's RediWM session only, not system defaults
    \\# ───────────────────────────────────────────────
    \\[region]
    \\timezone = ""              # empty inherits login; e.g. Pacific/Auckland
    \\language = ""              # installed locale for new apps; e.g. en_NZ.utf8
    \\formats = ""               # installed locale for regional date/number/currency formats
    \\clock_24h = false           # taskbar, calendar and lock screen
    \\clock_show_seconds = false # taskbar clock only
    \\clock_show_day = true      # taskbar date line, in regional format
    \\first_day_of_week = "sunday" # any lowercase weekday name
    \\
    \\# ───────────────────────────────────────────────
    \\# Animations — springs by default; hot-reload keeps in-flight velocity
    \\# ───────────────────────────────────────────────
    \\# [animations]
    \\# enabled = true
    \\# speed = 1.0                 # 0 = jump to the target; 0.5 = half speed
    \\# reduced_motion = "auto"     # auto | on | off — auto follows enable-animations
    \\#
    \\# [animations.panel_slide]
    \\# spring = { damping_ratio = 1.0, stiffness = 900 }
    \\#
    \\# [animations.wheel_scroll]    # mouse-wheel glide in shell panels; off = true to step
    \\# spring = { damping_ratio = 1.0, stiffness = 800 }
    \\#
    \\# [animations.taskbar_press]
    \\# duration_ms = 90
    \\# ease = "out_cubic"
    \\#
    \\# [animations.camera_pan]
    \\# duration_ms = 160
    \\# ease = "out_cubic"
    \\# decay_rate = 0.998
    \\
    \\# ───────────────────────────────────────────────
    \\# Authentication
    \\# ───────────────────────────────────────────────
    \\# Native authentication agent (real login sessions only).
    \\[polkit]
    \\enable = true
    \\helper_socket = "/run/polkit/agent-helper.socket"
    \\# Reload affects new requests; accepted requests finish with their old settings.
    \\
    \\# ───────────────────────────────────────────────
    \\# Idle policy
    \\# ───────────────────────────────────────────────
    \\[idle]
    \\# enabled = true             # default: true for login mode, false for nested/headless
    \\blank_after_seconds = 600   # 0 disables display blanking
    \\suspend_after_seconds = 0   # 0 disables automatic suspend
    \\
    \\# ───────────────────────────────────────────────
    \\# Night light and color temperature
    \\# On by default: a soft warm tint, all day. Set enabled = false to turn
    \\# it off, or switch schedule to "fixed"/"sun" to only warm up at night.
    \\# ───────────────────────────────────────────────
    \\[night_light]
    \\enabled = true
    \\schedule = "always"         # "always" | "fixed" | "sun"
    \\temperature = 5000          # K, 1700–10000; used for "always" and as the night target for "fixed"/"sun"
    \\#
    \\# schedule = "fixed"
    \\# day_temperature = 6500      # K by day; 6500 = neutral
    \\# start = "21:00"             # warming begins
    \\# end = "07:00"               # cooling begins
    \\# transition_minutes = 30     # ramp length, 0–180
    \\#
    \\# schedule = "sun"
    \\# latitude = 51.51            # −90 to 90
    \\# longitude = -0.13           # −180 to 180
    \\
    \\# Output overrides, matched by name (see this
    \\# compositor's own output list). Omit coordinates to keep automatic
    \\# left-to-right placement. scale defaults to "auto" (EDID density on DRM).
    \\# Numeric scale accepts 1–3; REDIWM_SCALE overrides all outputs.
    \\# Scale and placement changes apply live.
    \\# Uncomment to put a second monitor to the left of the primary, at a
    \\# negative x - the only way to give an output a negative origin:
    \\# [[outputs]]
    \\# name = "DP-1"
    \\# scale = "auto"
    \\# width = 1920               # optional display mode, saved by Displays
    \\# height = 1080
    \\# refresh_mhz = 60000        # 60 Hz; omit to use highest at this size
    \\# x = 0
    \\# y = 0
    \\# enabled = true             # set false to keep this monitor disabled
    \\# primary = true             # preferred fallback output
    \\# transform = "normal"       # normal, 90, 180, 270, or flipped variants
    \\#
    \\# [[outputs]]
    \\# name = "DP-2"
    \\# x = -1920
    \\# y = 0
    \\# primary = false
    \\# transform = "normal"
    \\# night_light = false         # colour-critical monitor: never tinted
    \\# gamma = 1.0                 # 0.5–2.0; applies with or without night light
    \\
    \\# ───────────────────────────────────────────────
    \\# Startup applications
    \\# ───────────────────────────────────────────────
    \\# [[autostart]]
    \\# cmd = "nm-applet"           # one entry per program
    \\
    \\[desktop]
    \\enabled = true                # desktop icons and wallpaper from ~/Desktop
    \\
    \\# [notifications]
    \\# daemon = "dunst"            # optional external daemon; restart required
    \\
    \\# [ipc]
    \\# automation = true           # IPC synthetic input and screen capture; restart required
    \\
    \\# ───────────────────────────────────────────────
    \\# Window rules
    \\# ───────────────────────────────────────────────
    \\# Ordered rules match windows by identity and set initial placement, size,
    \\# decorations or live properties. For each property the last matching rule wins.
    \\# Patterns are case-sensitive globs (* matches any sequence, ? matches one UTF-8 char).
    \\#
    \\# [[window_rules]]
    \\# app_id = "org.telegram.desktop"
    \\# exclude_title = "Media viewer"
    \\# output = "DP-2"
    \\# center = true
    \\# width = 900
    \\# height = 700
    \\#
    \\# [[window_rules]]
    \\# app_id = ["firefox", "chromium"]
    \\# title = "*Picture-in-Picture*"
    \\# opacity = 0.9
    \\# skip_taskbar = true
    \\# focus = false
    \\
    \\# ───────────────────────────────────────────────
    \\# Keybindings
    \\# Format: "modifiers+key" = "action [args]"
    \\# Modifiers: super/mod, ctrl, alt, shift
    \\# ───────────────────────────────────────────────
    \\[keybinds]
    \\# Laptop controls (also available while menus or the lock screen are open)
    \\"XF86AudioRaiseVolume" = "volume_up"
    \\"XF86AudioLowerVolume" = "volume_down"
    \\"XF86AudioMute" = "volume_mute"
    \\"XF86AudioMicMute" = "mic_mute"
    \\"XF86MonBrightnessUp" = "brightness_up"
    \\"XF86MonBrightnessDown" = "brightness_down"
    \\
    \\# Application launch
    \\"super+t"           = "spawn default-terminal"
    \\"super+b"           = "spawn firefox"
    \\"super+e"           = "spawn default-file-manager"
    \\"super+space"       = "toggle_start_menu"
    \\
    \\# Window management
    \\"super+q"           = "close_window"
    \\"super+f"           = "toggle_fullscreen"
    \\"super+m"           = "toggle_maximize"
    \\# Halves and quarters; dragging a window to a screen edge snaps it too
    \\"super+shift+left"  = "tile_left"
    \\"super+shift+right" = "tile_right"
    \\"super+shift+up"    = "tile_up"
    \\"super+shift+down"  = "tile_down"
    \\
    \\# ZUI spatial
    \\"super+1"           = "set_depth 0"
    \\"super+2"           = "set_depth 1"
    \\"super+3"           = "set_depth 2"
    \\"super+4"           = "set_depth 3"
    \\"super+5"           = "set_depth 4"
    \\"super+equal"       = "zoom_in"
    \\"super+minus"       = "zoom_out"
    \\"super+0"           = "zoom_reset"
    \\
    \\# Camera
    \\"super+shift+equal" = "camera_zoom_in"
    \\"super+shift+minus" = "camera_zoom_out"
    \\"super+shift+0"     = "camera_zoom_reset"
    \\
    \\# Focus and screen-sized canvas panning
    \\"alt+tab"           = "focus_next"
    \\"alt+shift+tab"     = "focus_prev"
    \\"ctrl+tab"          = "focus_next"
    \\"ctrl+shift+tab"    = "focus_prev"
    \\"super+left"        = "pan_left"
    \\"super+right"       = "pan_right"
    \\"super+up"          = "pan_up"
    \\"super+down"        = "pan_down"
    \\
    \\"super+ctrl+left" = "focus_left"
    \\"super+ctrl+right" = "focus_right"
    \\"super+ctrl+up" = "focus_up"
    \\"super+ctrl+down" = "focus_down"
    \\# Session
    \\"super+l"           = "lock_screen"
    \\"ctrl+alt+l"        = "lock_screen"
    \\"super+shift+e"     = "quit"
    \\# poweroff/reboot/suspend go through logind, as the logged-in user;
    \\# system policy (polkit) decides whether to allow or challenge them.
    \\"ctrl+alt+delete"   = "poweroff"
    \\# Take shortcuts back from a VM or remote desktop that captured the keyboard
    \\"super+escape"      = "restore_shortcuts"
    \\
    \\# Screenshots
    \\"ctrl+shift+s"      = "screenshot_region"
    \\"super+print"       = "screenshot_output"
    \\"print"             = "screenshot_output"
    \\
    \\# Canvas bookmarks
    \\"super+F1"          = "save_layout home"
    \\"super+F2"          = "save_layout work"
    \\"super+F3"          = "save_layout comms"
    \\"ctrl+super+F1"     = "restore_layout home"
    \\"ctrl+super+F2"     = "restore_layout work"
    \\"ctrl+super+F3"     = "restore_layout comms"
    \\
    \\# Undo last spatial action (move, resize, zoom, pan, or focus)
    \\"super+z"           = "undo"
    \\
    \\# ───────────────────────────────────────────────
    \\# Sandboxed app allowances (security-context-v1)
    \\# ───────────────────────────────────────────────
    \\# Sandboxed clients (such as Flatpaks) connected through a security context
    \\# see a restricted set of Wayland globals and are denied IPC access by default.
    \\# Capabilities can be granted per app ID. On reload, Wayland global grants
    \\# apply to new connections (globals an app already bound stay bound until it
    \\# reconnects); IPC allowances take effect immediately.
    \\#
    \\# [[sandbox_allow]]
    \\# app_id = "com.obsproject.Studio"   # exact match on the security-context app id
    \\# engine = "org.flatpak"             # optional; default matches any engine
    \\# allow  = ["capture"]               # groups: capture, windows, clipboard, input,
    \\#                                    # input_method, outputs, lock, layer_shell,
    \\#                                    # idle, ipc, automation
;
