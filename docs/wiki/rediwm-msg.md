# rediwm-msg

Command line client for the [IPC](IPC.md). It turns friendly subcommands into
v1 JSON, sends them, and pretty prints the reply.

```
rediwm-msg [options] <command>
```

| Option | What it does |
| --- | --- |
| `-s, --socket <PATH>` | socket path (default: `REDIWM_SOCKET`, else `$XDG_RUNTIME_DIR/rediwm-$WAYLAND_DISPLAY.sock`) |
| `-t, --timeout <MS>` | request/response timeout |
| `--raw [JSON]` | send a v1 JSON payload unchanged, from the arg or stdin |
| `--json` | print the JSON reply instead of the readable version |
| `-h, --help` | the full command list, always up to date |

`rediwm-msg raw [JSON|-]` does the same as `--raw`.

## Two kinds of subcommand

Most queries and a few actions are top level: `rediwm-msg windows`,
`rediwm-msg maximize 12`. The rest are under `action`:
`rediwm-msg action focus-window --id 12`. `--help` shows which is which.
Wire-name aliases like `get-state`, `get-perf`, `list-panels` also work.

## doctor

```sh
rediwm-msg doctor
```

Checks the socket and the environment and tells you what's off. Run this
first when nothing works. It runs even without a compositor to talk to.

## Recipes

**See what's open**

```sh
rediwm-msg windows
rediwm-msg focused-window
rediwm-msg state --json | jq '.Ok'
```

**Window management**

```sh
rediwm-msg action focus-window --id 12
rediwm-msg action move-window-to --id 12 --x 200 --y 100
rediwm-msg action move-window-to --id 12 --output DP-2
rediwm-msg fullscreen 12
rediwm-msg set-zoom 12 80
rediwm-msg action close-window            # focused one
```

**Launch things**

```sh
rediwm-msg launch org.gnome.Nautilus.desktop
rediwm-msg action spawn -- foot -e htop
```

**Displays**

```sh
rediwm-msg outputs
rediwm-msg output-config DP-1 --scale 1.5
rediwm-msg output-config DP-1 --width 2560 --height 1440 --refresh-mhz 144000
rediwm-msg output-config DP-2 --x -1920 --y 0
rediwm-msg output-config DP-2 --disabled
rediwm-msg output-config DP-1 --scale auto --position auto
```

**Debug a window rule**

```sh
rediwm-msg window-rules 12
rediwm-msg match-window-rules --app-id firefox --title "Picture-in-Picture"
```

**Watch events**

```sh
rediwm-msg event-stream --events window_opened,window_focused
```

**Scripted tests** (needs automation on)

```sh
rediwm-msg action spawn -- foot
rediwm-msg wait window_mapped --timeout 5000
rediwm-msg action key-press --key ctrl+shift+t
rediwm-msg action type-text --text "hello"
rediwm-msg wait-frame
rediwm-msg action screenshot --save /tmp/shot.png
rediwm-msg sample-pixels 100 100 1 1
```

**Poke at the UI**

```sh
rediwm-msg action open-start-menu
rediwm-msg panels
rediwm-msg widget-tree start_menu
rediwm-msg dump-buffer taskbar
rediwm-msg close-panel start_menu
```

**Audio and keyboard**

```sh
rediwm-msg action set-master-volume --volume 0.4
rediwm-msg action toggle-mute
rediwm-msg switch-layout next
```

**Anything without a subcommand**

```sh
rediwm-msg --raw '{"version":1,"command":"get_theme"}'
echo '{"version":1,"command":"set_dnd","params":{"enabled":true}}' | rediwm-msg --raw
```

## Exit behaviour

Bad arguments print an error and exit 1. A compositor `Err` is printed and
the exit code is nonzero. With no socket it tells you to set `REDIWM_SOCKET`
or `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`.
