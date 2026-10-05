# IPC

RediWM has a JSON IPC over a Unix socket. Use it to script the compositor,
inspect state, or drive it from tests. `rediwm-msg` is the friendly client,
see [rediwm-msg](rediwm-msg.md). Every command is in [IPC Commands](IPC-Commands.md).

## The socket

`$XDG_RUNTIME_DIR/rediwm-<WAYLAND_DISPLAY>.sock`, or whatever `REDIWM_SOCKET`
says. It lives in a private directory (owned by you, no group/other access) and
is created with umask 0177. If the directory isn't private the server refuses
to start the IPC.

## Wire format

UTF-8 JSON, one request per line, one response per line.

```json
{"version":1,"id":1,"command":"windows"}
{"version":1,"id":2,"command":"move_cursor","params":{"x":100,"y":200}}
```

| Field | Rules |
| --- | --- |
| `version` | required, the integer `1` |
| `command` | required, case-sensitive snake_case |
| `params` | optional object |
| `id` | optional, a non-negative integer or a string up to 256 bytes. Echoed back once the request parses. Parse errors have no id |

Anything else is rejected: extra envelope fields, duplicate JSON keys, bare
strings, `{"query":...}` / `{"action":...}` envelopes, PascalCase names and
CLI aliases. There's no separate "query" vs "action" on the wire, both are just
`command`.

Responses:

```json
{"id":1,"Ok":{"Windows":[]}}
{"id":1,"Err":"InvalidRequest"}
```

Response tags are case-sensitive and different from command names. Clients
should ignore unknown response fields. New commands show up in `capabilities`,
and a breaking change would mean a new protocol version.

Try it with no tools at all:

```sh
echo '{"version":1,"command":"version"}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/rediwm-wayland-1.sock
```

## Discovering things

```sh
rediwm-msg capabilities    # canonical command names
rediwm-msg describe        # params, kinds, protocol version
```

`describe_ipc` is the source of truth for parameter schemas. The code
reference is `src/ipc/protocol.zig` and `src/ipc/commands.zig`.

## Queries vs actions

Queries read state. Actions change something. Both use the same envelope.
The split only matters in `rediwm-msg` (`rediwm-msg action focus-window ...`
for actions that don't have a top-level subcommand).

## Events

`event_stream` turns the connection into a feed. You get an acknowledgement,
then newline-delimited tagged events until you disconnect.

```sh
rediwm-msg event-stream
rediwm-msg event-stream --events window_opened,window_closed
rediwm-msg event-stream --window 12
rediwm-msg event-stream --output DP-1
```

Raw params: `{"window_id"?: n, "output"?: "name", "events"?: ["..."]}`.

Events you can filter on:

| Group | Events |
| --- | --- |
| Windows | `window_opened`, `window_closed`, `window_changed`, `window_focused`, `window_moved`, `window_urgency_changed` |
| Outputs | `output_added`, `output_changed`, `output_removed` |
| Camera | `camera_changed` |
| Input | `keyboard_layouts_changed`, `keyboard_layout_switched` |
| Config | `config_loaded` |
| Polkit | `polkit_prompt_opened`, `polkit_prompt_closed` |
| Notifications | `notification_shown`, `notification_closed`, `notification_action` |
| Launching | `launch_started`, `launch_matched`, `launch_timeout` |
| UI | `widget_changed` |

`state_snapshot` is always delivered, whatever you filter. A `window_id`
filter only affects window events. Event subscriptions are re-checked against
the lock state, so you get nothing while the session is locked.

## Waiting instead of sleeping

If you're scripting, don't `sleep`. Use the wait commands.

```sh
rediwm-msg wait window_mapped --timeout 5000
rediwm-msg wait window_closed --id 12
rediwm-msg wait-frame --output DP-1
```

`wait_for` takes a condition and a timeout (default 5000 ms) and returns the
condition, elapsed ms and state. Raw example:

```json
{"version":1,"command":"wait_for","params":{"condition":{"window_mapped":{"app_id":"foot"}},"timeout_ms":5000}}
```

Conditions:

| Condition | Params |
| --- | --- |
| `menu_opened`, `menu_closed` | none |
| `control_center_opened`, `control_center_closed` | none |
| `power_menu_opened`, `power_menu_closed` | none |
| `window_mapped` | optional `id`, `app_id`, `title` |
| `window_closed` | `id` |
| `window_focused` | optional `id` |
| `window_geometry_settled` | `id` |
| `output_frame` | optional `output` |
| `catalog_published`, `wallpaper_presented` | none |
| `notification_count` | optional `count`, `app_name`, `summary` |
| `notification_closed` | `id` |
| `notification_action` | `id`, optional `action_key` |
| `launch_started`, `launch_matched`, `launch_timeout` | optional `desktop_id` (and `window_id` for matched) |
| `widget_present`, `widget_absent` | `path` |
| `widget_state` | `path`, `field`, `equals` |
| `panel_settled` | `panel` |

`wait_for_frame` blocks until the next frame commit on an output and returns
the output, `frame_seq` and elapsed time. The CLI's `wait` takes a condition
name plus `--id`/`--output`/`--timeout`. For conditions with richer params
(`app_id`, `title`, `path`, ...), use `--raw`.

## Automation (synthetic input and pixels)

Off by default. These commands are refused unless automation is on:

`move_cursor`, `move_cursor_relative`, `pointer_button`, `click`, `scroll`,
`key`, `key_press`, `type_text`, `drag`, `screenshot`, `dump_buffer`,
`sample_pixels`, `pinch`, `swipe`, `click_widget`, `hover_widget`.

Turn it on:

```toml
[ipc]
automation = true
```

or start with `REDIWM_IPC_AUTOMATION=1`. It's read once at startup, so you
need a restart. When it's on, the compositor logs a warning, because any
client of the socket can then type and take screenshots.

## Security rules

- Everything is refused with `SessionLocked` while the session is locked.
- Sandboxed callers (Flatpak and friends, detected via `SO_PEERPIDFD` and
  `.flatpak-info`) need an explicit `[[sandbox_allow]]` with the `ipc` group.
  They fail closed, and the check is redone on config reload.
  Synthetic input and capture additionally need the `automation` group.
- The socket is only reachable by your uid.
- Virtual input never reaches the lock or auth UI.

## Writing a client

Python is the easiest. This is basically what `tests/ipc_client.py` does:

```python
import json, os, socket

path = f"{os.environ['XDG_RUNTIME_DIR']}/rediwm-{os.environ['WAYLAND_DISPLAY']}.sock"
s = socket.socket(socket.AF_UNIX)
s.connect(path)
f = s.makefile("rw")

def call(command, params=None, id=1):
    req = {"version": 1, "id": id, "command": command}
    if params is not None:
        req["params"] = params
    f.write(json.dumps(req) + "\n"); f.flush()
    resp = json.loads(f.readline())
    if "Err" in resp:
        raise RuntimeError(resp["Err"])
    return resp["Ok"]

print(call("windows"))
call("focus_window", {"id": 3})
```

For events, open a second connection, send `event_stream`, then keep calling
`readline()`.

Tips:

- Use `get_state` when you need windows, outputs, camera and shell to agree.
  Separate queries can race.
- Coordinates are layout coordinates, not per-output pixels.
- Set a socket timeout. `wait_for` can take up to its own timeout to answer.
- `restart_shell` drops your connection and every app. That's expected.
