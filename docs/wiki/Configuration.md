# Configuration

The file is `$XDG_CONFIG_HOME/rediwm/config.toml`. `REDIWM_CONFIG` overrides
the path. It's written with commented defaults on first run and reloads when
you save. A parse error keeps the previous config. You can also reload with
`rediwm-msg reload`, and check status with `rediwm-msg config`.

## Sections

`[theme]`, `[input]`, `[input_method]`, `[compositor]`, `[region]`, `[animations.*]`,
`[idle]`, `[night_light]`, `[notifications]`, `[desktop]`, `[polkit]`, `[ipc]`,
`[keybinds]`, `[[outputs]]`, `[[autostart]]`, `[[window_rules]]`,
`[[notification_rules]]`, `[[sandbox_allow]]`.

## It's not full TOML

The parser reads a **line-based subset**. Don't run it through a generic TOML
formatter. The rules:

- One `key = value` per line. Arrays on one line too.
- Strings use double quotes and are taken verbatim. No escape processing, so
  `\n`, `\"` and `\u` mean exactly those characters.
- No single-quoted strings, no multiline strings or arrays, no inline tables,
  no arbitrary dotted keys, no dates.
- `#` starts a comment outside double quotes.

```toml
app_id = ["firefox", "chromium"]   # fine
```

## Theme

Colors, text sizes, corner radii and control styling belong in `[theme]`.
See the [complete theme reference](Theme.md) for every supported key and its
built-in default. Appearance preserves these overrides when it saves.

## Region & Language

Settings → Region & Language lets you choose a personal language, regional
formats and time zone. Empty choices inherit the login environment; system
defaults are unchanged. RediWM's interface currently uses English.

Personal clock and calendar preferences apply immediately and are saved in
`[region]`:

```toml
[region]
clock_24h = false
clock_show_seconds = false
clock_show_day = true
first_day_of_week = "sunday"
```

`clock_24h` applies to the taskbar, calendar and built-in lock screen.
`clock_show_seconds` adds seconds to the taskbar time. `clock_show_day` shows
the date line beneath it, using the selected regional format (`formats`, or
the inherited locale). Both lines are centered; hiding the date centers the
time vertically. These two options apply only to the taskbar clock.
`first_day_of_week` accepts any lowercase weekday name, and changes both the
weekday headings and date positions in the taskbar calendar. Existing configs
keep 12-hour time and Sunday first until changed.

## Handy `[compositor]` keys

| Key | Default | Notes |
| --- | --- | --- |
| `allow_tearing` | `false` | lets focused fullscreen clients request async presentation |
| `window_tab_apps` | `[]` | app IDs that get tabs |
| `default_file_manager`, `default_terminal` | `""` | desktop IDs, empty means Files / auto terminal |
| `taskbar_position` | `"bottom"` | `top` or `bottom` |
| `taskbar_items` | battery, network, volume, clock | prefix a name with `-` to hide it |
| `focus_follows_mouse` | `false` | |
| `canvas_columns`, `canvas_rows` | `3`, `3` | 1 to 10 |
| `mini_map_enabled` | `true` | |
| `mini_map_position` | `"bottom_right"` | `bottom_left`, `bottom_center`, `bottom_right` |
| `mini_map_hide_ms` | `1500` | 500 to 10000 |
| `desktop_icons_fixed` | `true` | |
| `desktop_switch_ms` | `220` | Super+arrow slide, 100 to 3000 |
| `zoom_steps` | `[1.0, 0.85, 0.70, 0.55, 0.40]` | |
| `camera_zoom_min`, `camera_zoom_max` | `0.25`, `1.0` | |
| `focus_zoom` | `"boost"` | `keep`, `boost`, `camera` |
| `window_gap` | `0` | px between snapped windows |
| `snap_to_edges` | `true` | |
| `dodge_file_drags` | `true` | file manager slides aside while you drag a file out |
| `switcher_opacity`, `inactive_opacity` | `1.0` | |
| `border_radius` | `10` | Legacy frame radius; `[theme].radius_lg` takes precedence. |
| `xwayland` | `true` | `false` means native only |
| `xwayland_native_scaling` | `false` | sharp X11 on fractional scales, restart needed |
| `xwayland_scale` | `0` | 0 is automatic, 1.0 to 4.0 explicit, restart needed |
| `dark_mode` | `false` | live, goes through the Settings portal |
| `placeholder_delay_ms` | `0` | splash only if the app is this slow to show, 0 disables |
| `wallpaper` | unset | file in `~/.local/share/rediwm/wallpapers`, or a path |
| `lid_close` | `"display_off"` | `display_off`, `lock`, `suspend`, `ignore` |
| `lock_on_suspend` | `true` | |
| `sound_theme`, `sound_enabled`, `sound_disabled_events` | `"freedesktop"`, `true`, `[]` | event sounds, used by `play_sound` |

## Outputs

```toml
[[outputs]]
name = "DP-2"
x = -1920              # negative origin is only possible here
y = 0
scale = "auto"         # "auto" or 1 to 3
width = 1920           # optional mode
height = 1080
refresh_mhz = 60000    # omit for the highest at this size
enabled = true
primary = false
transform = "normal"   # normal, 90, 180, 270, flipped variants
night_light = false    # never tint this monitor
gamma = 1.0            # 0.5 to 2.0
```

Omit coordinates for automatic left-to-right placement. Scale and placement
apply live. `REDIWM_SCALE` overrides every output. Changes from Settings,
`wlr-randr`, kanshi or `rediwm-msg output-config` are all saved here.

## Idle and night light

```toml
[idle]
blank_after_seconds = 600    # 0 disables
suspend_after_seconds = 0    # 0 disables

[night_light]
enabled = true
schedule = "always"          # "always", "fixed" or "sun"
temperature = 5000           # 1700 to 10000 K
# fixed: day_temperature, start, end, transition_minutes (0 to 180)
# sun:   latitude, longitude
```

Night light is on by default as a soft warm tint all day.

## Window rules

Matched by glob. For each property the last matching rule wins.

```toml
[[window_rules]]
app_id = ["firefox", "chromium"]
title = "*Picture-in-Picture*"
opacity = 0.9
skip_taskbar = true
focus = false
```

- **Matchers:** `app_id`, `title`, `tag`, `x11_class`, `x11_instance`,
  `backend`, `dialog`, and `exclude_*` versions.
- **Properties:** `output`, `x`, `y`, `center`, `width`, `height`, `maximized`,
  `fullscreen`, `focus`, `depth`, `opacity`, `decorations`, `skip_taskbar`.

To debug a rule, ask the compositor:

```sh
rediwm-msg window-rules 12                       # what matched this window
rediwm-msg match-window-rules --app-id foo       # dry run
```

`tag` comes from the client (xdg-toplevel-tag), so it's metadata, not trusted
identity.

## `[ipc]`

```toml
[ipc]
automation = true   # synthetic input and screen capture. Restart required
```

Read once at startup. Details on [IPC](IPC.md).

## `[polkit]`

```toml
[polkit]
enable = true
helper_socket = "/run/polkit/agent-helper.socket"
```

## `[[autostart]]`

```toml
[[autostart]]
cmd = "nm-applet"    # one entry per program
```

## `[[sandbox_allow]]`

See [Protocols and Sandboxing](Protocols-and-Sandboxing.md).
