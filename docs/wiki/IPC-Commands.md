# IPC Commands

Names are the wire names (`"command": "..."`). The CLI column is the
`rediwm-msg` spelling. Run `rediwm-msg describe` for exact params.
**[auto]** means it needs [automation](IPC.md#automation-synthetic-input-and-pixels).
"Action" in the CLI column means `rediwm-msg action <name>`.

## Info

| Command | CLI | What it does |
| --- | --- | --- |
| `version` | `version` | build version |
| `capabilities` | `capabilities` | supported command names |
| `describe_ipc` | `describe` | protocol version, kinds, parameter schemas |
| `get_runtime_info` | `runtime` | compositor, wlroots, backend, renderer |
| `get_config_status` | `config` | effective config and reload status |
| `reload_config` | `reload` | reload the config file |
| `get_performance_stats` | `perf` | commit, paint and error counters |
| `reset_performance_stats` | `perf-reset` | zero them |
| `get_panel_stats` / `reset_panel_stats` | Action | panel paint and allocation counters |
| `get_animations` | none | live animations: site, value, velocity, target, settled, curve |
| `set_anim_time` | Action `--ms <N\|null>` | override animation time, `null` clears it |

## Windows

| Command | CLI | Params |
| --- | --- | --- |
| `windows` | `windows` | list toplevels |
| `focused_window` | `focused-window` | |
| `get_window_debug` | `window-debug <id>` | geometry, decoration, serials |
| `get_window_rules` | `window-rules <id>` | matched rules and effective properties |
| `match_window_rules` | `match-window-rules` | dry run: `app_id`, `title`, `x11_class`, `x11_instance`, `backend`, `dialog` |
| `focus_window` | Action `focus-window --id` | |
| `close_window` | Action `close-window [--id]` | no id closes the focused window |
| `move_window_to` | Action `move-window-to --id` | `--x --y` or `--output` |
| `maximize_window` | `maximize <id>` | |
| `minimize_window` | `minimize <id>` | |
| `restore_window` | `restore <id>` | |
| `fullscreen_window` | `fullscreen <id> [--output]` | |
| `set_window_size` | none | `id`, `width`, `height`, requests a client resize |
| `set_window_zoom` | `set-zoom <id> <pct>` | |
| `undo` | none | undo the last move, resize, zoom, pan or focus change |
| `spawn` | Action `spawn [--] CMD ARGS...` | argument vector, no shell |
| `launch_app` | `launch <desktop_id>` | by desktop file ID |
| `stop_xwayland` | none | disconnects the compositor-owned Xwayland |

## Outputs, camera, workspaces

| Command | CLI | What it does |
| --- | --- | --- |
| `outputs` | `outputs` | list outputs |
| `set_output_config` | `output-config <out> ...` | mode, transform, position, scale, enable. Applied and saved |
| `workspaces` | `workspaces` | there's one, the canvas (`workspace_id = 1`) |
| `get_camera` | none | position, bounds, zoom |
| `set_camera` / `reset_camera` | none | `set_camera` takes integer `x`, `y` |
| `set_zoom` | none | camera zoom, `percent` (a supported step) |
| `get_state` | `state` | atomic snapshot of windows, outputs, camera, shell |

`output-config` flags: `--width --height --refresh-mhz --x --y`,
`--scale <1..3|auto>`, `--position auto`, `--transform <normal|90|180|270|flipped|flipped_90|flipped_180|flipped_270>`,
`--enabled`/`--disabled`, `--primary`/`--no-primary`. `auto` clears the override.

## Inspecting the shell and scene

| Command | CLI | What it does |
| --- | --- | --- |
| `get_shell_state` | `shell-state [--output]` | panels, progress, taskbars |
| `list_panels` | `panels` | registered panels and open state |
| `get_widget_tree` | `widget-tree <panel>` | semantic widget tree of an open panel |
| `get_input_state` | `input-state` | pointer, focus, keys, buttons, grabs |
| `hit_test` | `hit-test <x> <y> [--output]` | what's at those layout coordinates |
| `get_scene_tree` | `scene-tree [--max-depth]` | scene node hierarchy |
| `get_layer_surfaces` | `layers` | layer-shell surfaces |
| `get_text_input` | `text-input` | input-method state and candidate placement, never the text |
| `get_capture_state` | none | active screen capture sessions |
| `get_idle_state` | none | idle state, deadlines, inhibitors |

## Panels and menus

| Command | CLI |
| --- | --- |
| `open_start_menu` | Action `open-start-menu` |
| `open_control_center` | Action `open-control-center` |
| `open_power_menu` | Action `open-power-menu` |
| `open_appearance` | none |
| `close_panel` | `close-panel <panel>` |
| **[auto]** `click_widget` | none, `path`, optional `button`, `at` |
| **[auto]** `hover_widget` | none, `path`, optional `at` |

## Input

| Command | CLI | Notes |
| --- | --- | --- |
| **[auto]** `move_cursor` | Action `move-cursor --x --y [--output]` | |
| **[auto]** `move_cursor_relative` | Action `move-cursor-relative --dx --dy` | |
| **[auto]** `pointer_button` | Action `pointer-button --button --pressed` | Linux button codes |
| **[auto]** `click` | Action `click [--button]` | left by default |
| **[auto]** `scroll` | Action `scroll --dx --dy` | |
| **[auto]** `key` | Action `key --keycode --pressed` | Linux keycodes |
| **[auto]** `key_press` | Action `key-press --key` | named key or chord |
| **[auto]** `type_text` | Action `type-text --text` | |
| **[auto]** `drag` | Action `drag --from-x --from-y --to-x --to-y [--button]` | |
| **[auto]** `pinch` | none | phase `begin`/`update`/`end`, `scale`, `dx`, `dy`, `rotation`, `fingers`, `cancelled` |
| **[auto]** `swipe` | none | phase, `dx`, `dy`, `fingers`, `cancelled` |
| `get_keyboard_layouts` | `keyboard-layouts` | zero-based active index |
| `switch_layout` | `switch-layout <next\|prev\|index>` | |

## Screenshots and pixels

| Command | CLI | Notes |
| --- | --- | --- |
| **[auto]** `screenshot` | Action `screenshot` | `--output`, `--window`, `--mode`, `--include-cursor`, `--path`, `--save`. Raw params also take `crop` and `crop_space` (`logical` or `device`) |
| **[auto]** `dump_buffer` | `dump-buffer <target>` | targets: `titlebar`, `skirt`, `start_menu`, `control_center`, `power_menu`, `taskbar`. `--id`, `--output` |
| **[auto]** `sample_pixels` | `sample-pixels <x> <y> <w> <h>` | raw framebuffer pixels |
| `stop_all_capture` | none | ends every screen capture session |

Prefer `screenshot` and `dump_buffer` over host `grim` when debugging. Host
tools show host scaling and any window covering yours.

## Waiting

`wait_for` (`wait`) and `wait_for_frame` (`wait-frame`). See
[IPC](IPC.md#waiting-instead-of-sleeping) for the condition list.

## Audio

| Command | CLI |
| --- | --- |
| `get_audio_state` | Action `get-audio-state` |
| `set_master_volume` | Action `set-master-volume --volume 0..1` |
| `toggle_mute` | Action `toggle-mute` |
| `set_app_volume` | Action `set-app-volume --index N --volume 0..1` |
| `set_app_mute` | Action `set-app-mute --index N --muted true\|false` |

Volumes are clamped to 0..1.

## Notifications

| Command | What it does |
| --- | --- |
| `get_notifications` (`notifications`) | active toasts, history, DND status |
| `dismiss_notification` | `id`, optional `reason` |
| `invoke_notification_action` | `id`, `action_key` |
| `set_dnd` | `enabled` |
| `clear_notifications` | clears closed history |

## Night light and idle

| Command | What it does |
| --- | --- |
| `get_night_light` (`night-light`) | status and colour curves |
| `set_night_light` | `enabled` and/or `temperature` (1700 to 10000), at least one |
| `set_night_light_clock` | `unix_seconds`, override the clock (testing) |
| `set_idle_config` | `enabled`, `blank_after_seconds`, `suspend_after_seconds` |
| `advance_idle_time` | `seconds`, move the idle clock (testing) |

## Settings and appearance

These work without opening Settings.

| Command | Params and behaviour |
| --- | --- |
| `get_services` | system services, raw systemd state, `activation_us`, total `boot_us`. First calls may say `loading`/`analyzing`, unknown times are null |
| `set_service_mode` | `service`, `mode`: `on`, `disabled`, `on-demand`. Changes boot policy only, doesn't start or stop the unit. `on-demand` needs an existing activation trigger and disables boot enablement. `deferred` returns `UnsupportedServiceMode`. Static and masked units are read-only |
| `get_sounds` | theme and events, with enabled/available flags and resolved files |
| `play_sound` | `event` from `get_sounds`. Plays with `/usr/bin/paplay`, returns the PID, not "finished" |
| `get_wallpaper` | selection, resolved and displayed paths, dimensions, loading and fallback status |
| `set_wallpaper` | `path`: a wallpaper name or a file, `""` restores the default. Decoding is async, poll `get_wallpaper` |
| `get_theme` | theme `tokens`, theme file path (null if inline), dark mode. Colours are straight RGBA, 0 to 1 |
| `set_accent_color` | `color`: `#RRGGBB` or `#RRGGBBAA` |
| `get_processes` | window-owning app processes grouped by PID, with window IDs, RSS and CPU sampled for about 200 ms. 100% is one logical CPU. Gone processes have null usage |

`set_wallpaper`, `set_accent_color` and `set_night_light` save to the config
by default. Pass `"persist": false` for a session-only change. If saving fails
you get the error before anything changes live.

Service changes use systemd's interactive authorization and only return
"accepted". Watch `get_services.action_pending`, raw state and `status` for the
result.

## Session

| Command | Notes |
| --- | --- |
| `restart_shell` | restarts the compositor in place, **disconnects all apps** |

## Examples

```sh
rediwm-msg --raw '{"version":1,"command":"get_theme"}'
rediwm-msg --raw '{"version":1,"command":"set_accent_color","params":{"color":"#e05a47"}}'
rediwm-msg --raw '{"version":1,"command":"set_night_light","params":{"enabled":true,"temperature":4000,"persist":false}}'
```
