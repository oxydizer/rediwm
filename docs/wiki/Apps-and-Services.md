# Apps and Services

## Files (`rediwm-files`)

The file manager. Space opens images, PDFs and text files.

- **Git:** detects repos, subfolders and linked worktrees. The sidebar shows
  the branch and ahead/behind from what's known locally. Badges: M modified,
  A added, D deleted, R renamed, U conflict, ? untracked. Click the repo name
  to jump to its root. It never fetches or changes anything, and never runs a
  repo's own programs. A repo whose config names filter or Git LFS commands
  (think archives and USB sticks) is shown as a plain folder.
- **Archives:** browse ZIP, TAR (gz, bz2, xz, zstd) and 7z like folders. They're
  read-only. Opening a member extracts just that file to private temp storage
  that's removed on exit. Context menu has **Extract** and **Extract to...**.
  Name clashes ask Skip/Rename/Cancel, nothing is overwritten, and paths
  outside the destination are rejected. No passworded archives, links or
  special files yet.
- **Thumbnails:** JPEG and PNG are decoded without GdkPixbuf (it's slow and
  goes through sandboxed loaders). Shared freedesktop cache in
  `$XDG_CACHE_HOME/thumbnails`. `REDIWM_FILES_THUMBNAILS=0` turns them off.
- **Devices:** USB sticks and drives show up via UDisks2. Eject means unmount,
  the device stays listed, dimmed. `REDIWM_FILES_DEVICES=0` disables it.
- **Pins:** drop a folder on the PLACES sidebar to pin it. Stored one path per
  line in `$XDG_STATE_HOME/rediwm/files-places`.
- Drag a file out and the window slides aside (`dodge_file_drags`).
- File and folder icons open with one click in list and icons view, with a hand
  cursor on hover. Names select; Ctrl/Shift clicks and dragging still work.
  Turn this off in Settings → General (`files_single_click_open`).

## Text editor (`rediwm-editor [FILE ...]`)

Tabs, one window per display. UTF-8 files up to 4 GiB (they must fit in free
memory), keeps BOM and line endings, asks before discarding changes. Only the
lines on screen are ever laid out, so opening, scrolling and Find stay fast on
huge files, and a single line of many megabytes is folded onto several rows.
Editing near the start of a very large file moves the rest of the text, which
costs a few milliseconds per 100 MB per keystroke.

| Keys | Action |
| --- | --- |
| Ctrl+N / O / S | new tab / open / save |
| Ctrl+Shift+S | save as |
| Ctrl+PageUp/Down | switch tabs |
| Ctrl+W | close tab |
| Ctrl+F, F3 | find |
| F10 | menu (Open Recent is a submenu: Right opens it) |

**Open Recent** (in the menu) lists the last ten text files that still exist,
newest first, from the same freedesktop history (`recently-used.xbel`) that
Files' Recent view uses, so files opened from Files or saved with Save As appear
too. **Clear Recent** forgets the text files in that history, which also removes
them from Files' Recent; other kinds of files stay.

## Images (`rediwm-images`) and PDF (`rediwm-pdf FILE`)

Files, Images and the editor also run on other Wayland compositors.

The PDF viewer is sandboxed with Landlock (ABI 3 or newer) and needs a
compositor with `security-context-v1`, which RediWM has. It refuses to parse
a document if it can't isolate itself. Each PDF gets its own viewer. Web links
copy their address instead of opening.

Print (toolbar button or Ctrl+P) opens the print dialog of xdg-desktop-portal
(GTK's, by default). A helper started before the sandbox hands the portal the
file you opened; the sandboxed parser can only ask it to print.

## Network settings

Settings → Network talks to NetworkManager over D-Bus; nothing here runs `nmcli`.

- **Details:** the wired adapter and the connected Wi-Fi network list IPv4 and
  IPv6 addresses, gateway, DNS servers, search domains, MAC, whether the
  profile is automatic or manual, and for Wi-Fi the security, signal, band and
  channel, link speed and access point. Address rows have a copy button.
- **Saved connections:** Wi-Fi and Ethernet have **Edit settings…**. It sets
  connect-automatically, IPv4 and IPv6 (Automatic, Manual with address,
  prefix and gateway, Link-local only, or Disabled), DNS (automatic or your own
  servers), MTU and metered, and writes them back to the profile. Only those
  keys change; secrets and everything else in the profile are left as they were.
  Saving reapplies the connection if it is in use. **Forget** (two clicks)
  deletes the profile, and the Wi-Fi row also has **Disconnect**.
- **Unlock:** changing a saved connection needs the polkit action
  `org.freedesktop.NetworkManager.settings.modify.system`. The page asks once
  without interaction when it opens. Where policy already allows it (the usual
  default for a local session) nothing shows; otherwise the page offers
  **Unlock**, like Services, which asks through your polkit agent.
- **VPN:** NetworkManager VPN and WireGuard connections are listed with
  Connect, Disconnect and Remove. Add one with your VPN's NetworkManager plugin
  or `nmcli connection import`. RediWM has no secret agent, so a VPN that asks
  for a password at connect time needs its credentials saved in the profile.
- **Proxy:** Off, Manual (HTTP, HTTPS, SOCKS and a bypass list) or Automatic (a
  script address). It is stored in GSettings `org.gnome.system.proxy`, which GTK
  and GIO apps and Firefox's "system proxy" read, so it needs the
  gsettings-desktop-schemas package. A manual proxy is also exported as
  `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy` (both cases) to apps
  RediWM starts afterwards; Off and Automatic export nothing and leave your own
  login environment alone. Proxy credentials are not stored here.
- **Airplane mode** soft-blocks every radio through `/dev/rfkill`, so
  NetworkManager and BlueZ both follow. Turning it off puts each radio back as
  it was before. It is hidden where there is no rfkill, and disabled while a
  hardware switch is blocking a radio.

## Desktop

Icons and wallpaper from `~/Desktop`, on by default (`[desktop] enabled`). A
`.desktop` launcher only runs if it's installed, owned by root and executable,
or an exact copy of an installed entry. Anything else shows as a plain file
until you pick **Allow Launching** in its menu. The wallpaper comes from
`wallpaper` in the config, Settings, or `set_wallpaper` over IPC.

## Notifications

RediWM is the notification daemon. Actions, images, do-not-disturb, history.
Rules go in `[[notification_rules]]`. If you'd rather use dunst, set
`[notifications] daemon = "dunst"` and restart. Inspect and drive them over
IPC: `notifications`, `set_dnd`, `dismiss_notification`,
`invoke_notification_action`.

## Lock, login and polkit

- **Lock:** see [Using RediWM](Using-RediWM.md#locking). Locks never unlock
  because of a crash: after a crash while locked, `rediwm-session` locks again
  before the backend even starts.
- **Greeter / `rediwm-dm`:** the greeter is a lock that never unlocks, only
  `rediwm-dm` decides. It runs as an unprivileged user on its own VT. To use
  it: install with `--dm`, disable your current display manager,
  `sudo systemctl enable rediwm-dm`, reboot. Options in `/etc/rediwm/dm.conf`.
  It does no Xwayland, autostart, IPC, tray, portal or services.
- **Polkit:** RediWM is a polkit agent (`[polkit] enable`). Capture and screen
  sharing are refused during a prompt.
- **Accounts:** account management goes through `rediwm-accounts-helper` under
  `pkexec`. The compositor never runs as root.

## Screen capture and sharing

`wlr-screencopy` and `ext-image-copy-capture` work (grim, wf-recorder, OBS,
the portal). Any capture lights the taskbar **Stop sharing** indicator. It's
refused while locked or during a polkit prompt. `stop_all_capture` over IPC
ends everything. See `docs/screen-sharing.md`.

## App scopes

On a real session each app you launch is moved into its own
`app-rediwm-<id>-<pid>.scope` so systemd-oomd kills one runaway app and not
your whole session. Off in nested and headless sessions unless
`REDIWM_APP_SCOPES=1`.

## Startup

The desktop renders before autostart runs, and audio and session environment
setup never block frames or input. Autostart entries go in `[[autostart]]`.
