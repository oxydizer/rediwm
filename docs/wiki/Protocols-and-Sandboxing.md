# Protocols and Sandboxing

## Wayland protocols

On top of xdg-shell, layer-shell and Xwayland:

| Area | Protocols | Works with |
| --- | --- | --- |
| Displays | `wlr-output-management-v1`, `xdg-output-v1` | wlr-randr, kanshi, nwg-displays |
| Window lists | `wlr-foreign-toplevel-management-v1`, `ext-foreign-toplevel-list-v1` | docks, waybar, rofi/fuzzel, wlrctl |
| Capture | `wlr-screencopy-v1`, `ext-image-copy-capture-v1` | grim, wf-recorder, OBS, xdg-desktop-portal-wlr |
| Locking and idle | `ext-session-lock-v1`, `ext-idle-notify-v1`, `idle-inhibit-v1` | swaylock, gtklock, swayidle |
| Remote input | `virtual-pointer-v1`, `virtual-keyboard-v1` | wayvnc, KDE Connect, wtype |
| Clipboard | `wlr-data-control-v1`, `ext-data-control-v1`, primary selection | wl-clipboard |
| Input | `text-input-v3`, `input-method-v2`, `relative-pointer-v1`, `pointer-constraints-v1`, `keyboard-shortcuts-inhibit-v1`, `pointer-gestures-v1`, `cursor-shape-v1` | fcitx5, IBus, games, virt-manager |
| Workspace | `ext-workspace-v1` | one canvas workspace shared by all outputs |
| Window metadata | `xdg-toplevel-tag-v1`, `content-type-v1`, `xdg-activation-v1` | window rules, content hints, activation |
| Colour | `color-management-v1`, `color-representation-v1` | whatever the renderer supports |
| Presentation | `tearing-control-v1`, `drm-lease-v1` | opt-in fullscreen tearing, VR headsets |
| Rendering | `fractional-scale-v1`, `viewporter`, `single-pixel-buffer-v1`, `linux-dmabuf-v1`, `linux-drm-syncobj-v1`, `presentation-time` | |

## Things worth knowing

- Output changes from clients (wlr-randr, kanshi) are saved just like ones made
  in Settings.
- **Workspace:** the canvas is advertised as one workspace. You can't create,
  remove or switch workspaces through the protocol. Window IPC reports
  `workspace_id = 1`, plus `tag`, `description` and `content_type` when the
  client sets them. `[[window_rules]]` can match `tag` with the same globs as
  `app_id`.
- **Content type** hints (photo, video, game) don't change idle or focus
  policy.
- **Colour:** follows the renderer. Pixman gives colour feedback without
  parametric image creation, GPU renderers advertise what wlroots can convert.
  Output stays SDR. No HDR modes or ICC loading.
- **Tearing:** `[compositor] allow_tearing = true` honours async hints from
  focused fullscreen clients. If an output can't do it, that output falls back
  to synchronized presentation until it's recreated. Suppressed while locked.
- **DRM leases:** DRM backends only, physical non-desktop outputs only.
  Revoked on lock or auth. Private capture outputs are never offered.
- **Session lock clients:** a client `ext-session-lock` is treated as a real
  lock. If the client dies the session stays locked.
- **Remote input:** virtual pointer and keyboard can't touch the lock or auth
  UI.
- **Pointer lock:** active only when the client has both pointer and keyboard
  focus.
- **Shortcut inhibit** (VMs, remote desktops) blocks the switcher and
  screenshot shortcuts. Hardware keys, VT switching and open panels still win.
  **Super+Escape** takes shortcuts back.

## Sandboxed apps

Clients connecting through `wp_security_context_v1` (Flatpak etc.) only see
the safe Wayland globals. Privileged ones are hidden, and guessing the name of
a hidden global is a protocol error. Nested security contexts are fatal.

Grant access per app in the config:

```toml
[[sandbox_allow]]
app_id = "com.obsproject.Studio"   # exact match on the security-context app id
engine = "org.flatpak"             # optional, default matches any engine
allow  = ["capture"]
```

Groups:

| Group | Unlocks |
| --- | --- |
| `capture` | screencopy and image capture |
| `windows` | foreign toplevel lists, workspace |
| `clipboard` | data control |
| `input` | virtual pointer and keyboard |
| `input_method` | input method |
| `outputs` | output management, DRM leasing |
| `lock` | session lock |
| `layer_shell` | layer shell |
| `idle` | idle notify |
| `ipc` | the IPC socket |
| `automation` | synthetic input and pixel reads over IPC |

On reload, Wayland grants apply to new connections only (already bound
globals stay bound until the app reconnects). IPC grants apply immediately.
The greeter hides all of these.
