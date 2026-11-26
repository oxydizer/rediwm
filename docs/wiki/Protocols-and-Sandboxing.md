# Protocols and Sandboxing

## Wayland protocols

RediWM supports xdg-shell v7, wlr-layer-shell v5 and Xwayland. Tiled
Wayland windows receive resize hints for their outer edges. Panels can
reserve space on a specific output edge, including from a corner.

| Area | Protocols | Works with |
| --- | --- | --- |
| Core Wayland | `wl_fixes` v1 | clients can release a `wl_registry` on the server while keeping their connection open |
| Displays | `wlr-output-management-v1`, `xdg-output-v1` | wlr-randr, kanshi, nwg-displays |
| Window lists | `wlr-foreign-toplevel-management-v1`, `ext-foreign-toplevel-list-v1` | docks, waybar, rofi/fuzzel, wlrctl |
| Window parenting | `xdg-foreign-unstable-v1`, `xdg-foreign-unstable-v2` | a dialog in another process can use an exported window as its parent. Handles work across both versions. |
| Dialogs | `xdg-dialog-v1` | modal dialogs from GTK 4, Qt 6 and SDL 3 |
| Capture | `wlr-screencopy-v1`, `ext-image-copy-capture-v1` | grim, wf-recorder, OBS, xdg-desktop-portal-wlr |
| Locking and idle | `ext-session-lock-v1`, `ext-idle-notify-v1`, `idle-inhibit-v1` | swaylock, gtklock, swayidle |
| Remote input | `virtual-pointer-v1`, `virtual-keyboard-v1` | wayvnc, KDE Connect, wtype |
| Clipboard | `wlr-data-control-v1`, `ext-data-control-v1`, primary selection | wl-clipboard |
| Input | `text-input-v1`, `text-input-v3`, `input-method-v2`, `relative-pointer-v1`, `pointer-constraints-v1`, `keyboard-shortcuts-inhibit-v1`, `pointer-gestures-v1`, `cursor-shape-v1` | fcitx5, IBus, games, virt-manager |
| Workspace | `ext-workspace-v1` | one canvas workspace shared by all outputs |
| Window metadata | `xdg-toplevel-tag-v1`, `content-type-v1`, `xdg-activation-v1` | window rules, content hints, activation |
| Sound | `xdg-system-bell-v1` | applications can ring the desktop sound theme’s `bell` |
| Colour | `color-management-v1`, `color-representation-v1` | named RGB descriptions and YCbCr coefficients/ranges |
| Surface effects | `ext-background-effect-v1`, `alpha-modifier-v1` | Regional background blur and per-surface fades |
| Output gamma | `wlr-gamma-control-v1` | wlsunset, gammastep |
| Presentation | `commit-timing-v1`, `fifo-v1`, `tearing-control-v1`, `drm-lease-v1` | timed video frames, refresh-paced updates, opt-in fullscreen tearing, VR headsets |
| Rendering | `fractional-scale-v1`, `viewporter`, `single-pixel-buffer-v1`, `linux-dmabuf-v1` (v5 on renderers with DMA-BUF import), `linux-drm-syncobj-v1`, `presentation-time` | |

## Things worth knowing

- A commit timestamp specifies the earliest presentation time for that surface update.
  On a single fixed-refresh DRM output RediWM can prepare an update for an upcoming
  refresh using recent hardware presentation feedback. When the output timing is
  uncertain it waits for the timestamp itself. Later commits stay ordered.
- **Modal dialogs** (`xdg-dialog-v1`, or `_NET_WM_STATE_MODAL` from X11 apps)
  open over the middle of their window. Clicking, Alt-Tabbing to or choosing
  that window on the taskbar brings the dialog forward with the keyboard, since
  the app ignores the window until the dialog closes. Minimizing either one
  minimizes the window, and its dialogs come back when it is restored. Clicks
  still reach the window; the app decides what to do with them. Window IPC
  reports `parent_id` for any dialog and `is_modal` for a modal one.
- System bell requests share a 250 ms cooldown across clients. The bell stays
  silent while the session is locked or a polkit authentication prompt is open.
- Clients can blur a region behind a surface when the renderer advertises the
  blur capability. A surface's alpha multiplier combines with window opacity.
  Both requests take effect on the surface commit.
- On outputs with a hardware gamma table, an external gamma ramp overrides
  Night Light and the configured output gamma. Releasing control restores
  the current settings for that output. The Night Light IPC query reports
  `external` while a client controls the ramp.
- Output changes from clients (wlr-randr, kanshi) are saved just like ones made
  in Settings.
- Legacy text-input-v1 fields can use the same input method as v3 fields for
  composition, surrounding-text edits and candidate popups. V1 requests for
  on-screen keyboard visibility, a preferred language and actions on preedit
  text have no input-method-v2 equivalent.
- **Workspace:** the canvas is advertised as one workspace. You can't create,
  remove or switch workspaces through the protocol. Window IPC reports
  `workspace_id = 1`, plus `tag`, `description` and `content_type` when the
  client sets them. `[[window_rules]]` can match `tag` with the same globs as
  `app_id`.
- **Content type** hints (photo, video, game) don't change idle or focus
  policy.
- **Colour.** The compositor accepts named gamma 2.2, compound-power sRGB
  (protocol v2), extended linear and ST 2084 PQ, with sRGB or BT.2020
  primaries. The output showing the largest visible portion of a surface
  determines its preferred description. A PQ surface retains absolute
  luminance on HDR10 outputs and receives highlight roll-off on SDR outputs.
  Screencopy and image-copy-capture deliver SDR. External YCbCr buffers
  support BT.601, BT.709 and BT.2020 non-constant-luminance coefficients in
  full or limited range. EGL performs the conversion during sampling.
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
| `outputs` | output management, gamma control, DRM leasing |
| `lock` | session lock |
| `layer_shell` | layer shell |
| `idle` | idle notify |
| `ipc` | the IPC socket |
| `automation` | synthetic input and pixel reads over IPC |

On reload, Wayland grants apply to new connections only (already bound
globals stay bound until the app reconnects). IPC grants apply immediately.
The greeter hides all of these.
