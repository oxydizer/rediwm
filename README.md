<a name="top"></a>
<div align="center">
 
  <img src="https://github.com/user-attachments/assets/0c8ab1b7-32f7-4f7a-b5d5-715cccc6d0b9" alt="RediWM — One process. A whole desktop. A Wayland compositor with its shell and everyday apps built in, written in Zig." width="100%" />
  <br /><br />
  <a href="#building-from-source"><img src="https://img.shields.io/badge/Zig-0.17-F7A41D?style=for-the-badge&amp;logo=zig&amp;logoColor=white&amp;labelColor=0B0E12" alt="Built with Zig 0.17" /></a>
  <a href="https://gitlab.freedesktop.org/wlroots/wlroots"><img src="https://img.shields.io/badge/wlroots-0.20-ED233E?style=for-the-badge&amp;labelColor=0B0E12" alt="Powered by wlroots 0.20" /></a>
  <a href="#features"><img src="https://img.shields.io/badge/Desktop-Wayland-ED233E?style=for-the-badge&amp;logo=wayland&amp;logoColor=white&amp;labelColor=0B0E12" alt="Wayland desktop" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-303640?style=for-the-badge&amp;labelColor=0B0E12" alt="Licensed under MIT or Apache 2.0" /></a>
  <br /><br />
  <a href="#installation"><img src="https://img.shields.io/badge/GET_STARTED-ED233E?style=for-the-badge&amp;logo=linux&amp;logoColor=white" alt="Get started" /></a>
  &nbsp;
  <a href="#themes"><img src="https://img.shields.io/badge/EXPLORE_THE_DESKTOP-303640?style=for-the-badge" alt="Explore the desktop" /></a>
  <br /><br />
  <a href="#features"><b>Features</b></a> &nbsp;·&nbsp;
  <a href="#built-in-apps"><b>Built-in apps</b></a> &nbsp;·&nbsp;
  <a href="#keyboard-shortcuts"><b>Shortcuts</b></a> &nbsp;·&nbsp;
  <a href="#configuration"><b>Configuration</b></a> &nbsp;·&nbsp;
  <a href="#ipc"><b>IPC</b></a> &nbsp;·&nbsp;
  <a href="#documentation"><b>Docs</b></a>
  <br /><br />
</div>

**RediWM** is a [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) Wayland compositor that draws its **entire desktop shell in one process**: taskbar, start menu, settings, lock and login screens, notifications and on-screen displays.

No separate bar to configure. No launcher to bolt on. No notification daemon to wire up. **Just one desktop, built together.**

https://github.com/user-attachments/assets/a9f8529d-19c4-4a45-a4be-95a184bde15f

<table width="100%">
  <tr>
    <td width="25%" align="center" valign="top"><h3>1–2s</h3><b>From start to desktop</b></td>
    <td width="25%" align="center" valign="top"><h3>1 process</h3><b>Compositor + desktop shell</b></td>
    <td width="25%" align="center" valign="top"><h3>&lt; 200 MB</h3><b>Idle RAM usage</b></td>
    <td width="25%" align="center" valign="top"><h3>&lt; 1% CPU</h3><b>Idle CPU usage</b></td>
  </tr>
</table>

<hr />

<a name="themes"></a>

<table align="center" width="100%">
  <tr>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/b4cbd48c-ccab-452e-8457-2d1b8c096def"><img src="https://github.com/user-attachments/assets/b4cbd48c-ccab-452e-8457-2d1b8c096def" alt="RediWM theme showcase 1" width="440" height="275" /></a></td>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/a65979e4-17d5-488d-8d0a-fc1a8d2d2c82"><img src="https://github.com/user-attachments/assets/a65979e4-17d5-488d-8d0a-fc1a8d2d2c82" alt="RediWM theme showcase 3" width="440" height="275" /></a></td>
  </tr>
  <tr>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/10f9becc-bcd9-4089-872b-4a03d1dba818"><img src="https://github.com/user-attachments/assets/10f9becc-bcd9-4089-872b-4a03d1dba818" alt="RediWM theme showcase 2" width="440" height="275" /></a></td>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/dd0cdae7-4c4d-401c-9624-80895897d0de"><img src="https://github.com/user-attachments/assets/dd0cdae7-4c4d-401c-9624-80895897d0de" alt="RediWM theme showcase 4" width="440" height="275" /></a></td>
  </tr>
</table>

<a name="built-in-apps"></a>
### Built-in apps

<table align="center" width="100%">
  <tr>
    <th width="50%" align="center">⚙️ Settings</th>
    <th width="50%" align="center">📁 File manager</th>
  </tr>
  <tr>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/80af0119-b57c-4642-9092-3e4885aab92e"><img src="https://github.com/user-attachments/assets/80af0119-b57c-4642-9092-3e4885aab92e" alt="RediWM Settings" width="440" /></a></td>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/57d244a3-7ae1-4456-8139-f5320caa688c"><img src="https://github.com/user-attachments/assets/57d244a3-7ae1-4456-8139-f5320caa688c" alt="RediWM file manager" width="440" /></a></td>
  </tr>
  <tr>
    <th width="50%" align="center">🖼️ Image / PDF viewer</th>
    <th width="50%" align="center">📝 Text editor</th>
  </tr>
  <tr>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/47c51bdd-2879-4e52-b5e5-0faf2b85ec05"><img src="https://github.com/user-attachments/assets/47c51bdd-2879-4e52-b5e5-0faf2b85ec05" alt="RediWM image and PDF viewer" width="440" /></a></td>
    <td width="50%" align="center" valign="middle"><a href="https://github.com/user-attachments/assets/91b25a5d-140d-43ea-a33f-b8f1921e0288"><img src="https://github.com/user-attachments/assets/91b25a5d-140d-43ea-a33f-b8f1921e0288" alt="RediWM text editor" width="440" /></a></td>
  </tr>
</table>

<hr />

<a name="features"></a>

<table width="100%">
  <tr>
    <td width="33%" valign="top"><h3>Sharp on HiDPI</h3>Xwayland native scaling keeps X11 applications sharp on high-density displays.</td>
    <td width="34%" valign="top"><h3>Lock / Login screen</h3>PAM-backed lock and login screens, with the optional <code>rediwm-dm</code> display manager.</td>
    <td width="33%" valign="top"><h3>Your notifications</h3>A built-in notification daemon with actions, images and do-not-disturb rules.</td>
  </tr>
  <tr>
    <td width="33%" valign="top"><h3>Night light</h3>Adjust the display colour temperature with the built-in night light.</td>
    <td width="34%" valign="top"><h3>Multi-monitor support</h3>Use multiple monitors in the same desktop session.</td>
    <td width="33%" valign="top"><h3>Tiling / stacking layouts</h3>Arrange windows using tiling or stacking layouts.</td>
  </tr>
</table>

**Built-in shell and apps.** Taskbar, start menu, desktop icons, settings, file manager, image/PDF viewer and text editor. No separate Waybar, greeter, launcher or notification daemon is required.

**Wayland tools.** Works with `wlr-randr`, `kanshi`, `swaylock`, `swayidle`, `grim`, `wf-recorder`, `wayvnc` and docks.

<a name="installation"></a>
## 🚀 Get RediWM

### Linux installer

**Arch and derivatives — including Artix and CachyOS — Debian, Ubuntu and Fedora:**

```sh
curl -fsSL https://rediwm.redios.org/install.sh | sh
```

<details>
<summary><b>🔐 Include the optional RediWM display manager</b></summary>

Install the prebuilt release together with **`rediwm-dm`**:

```sh
curl -fsSL https://rediwm.redios.org/install.sh | sh -s -- --dm
```

</details>

### NixOS · x86_64

Use the [flake and NixOS module](docs/nix.md), **not the shell installer above**.

To build just the package, without configuring a login session:

```sh
nix build github:oxydizer/rediwm
```

<a name="building-from-source"></a>
### Build it yourself

Requires **Zig 0.17**, **wlroots 0.20**, and the development dependencies below.

<details>
<summary><b>📦 Full dependency list</b></summary>

Wayland, wayland-protocols, xkbcommon, pixman, FreeType, HarfBuzz, Fontconfig, librsvg/GdkPixbuf, PangoCairo, libinput, PAM, libpulse, libpipewire-0.3, Poppler GLib, libarchive, libjpeg, libpng, libwebp and GNU Readline.

</details>

```sh
# Try it nested inside your current Wayland session
zig build run -- foot

# Build for daily use and measurements
zig build -Doptimize=ReleaseSafe

# Install the session and restart the running session
sh scripts/install-session.sh

# Or install without restarting, including rediwm-dm
sh scripts/install-session.sh --no-restart --dm
```

For custom prefixes and distribution packages, see [Installation layouts and packaging](docs/installation.md).

<hr />

<a name="keyboard-shortcuts"></a>
## ⌨️ Keyboard shortcuts

| Keys | Action |
| :--- | :--- |
| <kbd>Super</kbd> + <kbd>Space</kbd> | Open the centred app launcher |
| <kbd>Super</kbd> + <kbd>T</kbd> / <kbd>E</kbd> / <kbd>B</kbd> | Terminal / Files / browser |
| <kbd>Super</kbd> + <kbd>Q</kbd> / <kbd>F</kbd> / <kbd>M</kbd> | Close / fullscreen / maximise |
| <kbd>Super</kbd> + <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> | Slide to the neighbouring desktop |
| <kbd>Super</kbd> + <kbd>Ctrl</kbd> + <kbd>arrows</kbd> | Focus the window in that direction |
| <kbd>Alt</kbd> + <kbd>Tab</kbd> | Switch windows |
| <kbd>Super</kbd> + <kbd>1…5</kbd> or <kbd>=</kbd> / <kbd>-</kbd> / <kbd>0</kbd> | Zoom a window |
| <kbd>Super</kbd> + <kbd>Shift</kbd> + <kbd>=</kbd> / <kbd>-</kbd> / <kbd>0</kbd> | Zoom the desktop |
| <kbd>Super</kbd> + <kbd>A</kbd> | Canvas window overview |
| <kbd>Super</kbd> + <kbd>L</kbd> | Lock the screen |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>S</kbd> / <kbd>Print</kbd> | Region / full-screen screenshot |
| <kbd>Super</kbd> + <kbd>Z</kbd> | Undo the last window move or resize |
| <kbd>Super</kbd> + <kbd>Shift</kbd> + <kbd>E</kbd> | Quit RediWM |

Canvas bindings live in `[keybinds]`; set one to `"noop"` to disable it.

<a name="configuration"></a>
## 🎛️ Configuration

```text
$XDG_CONFIG_HOME/rediwm/config.toml
```

RediWM writes commented defaults on first run and **reloads on save**. A parse error keeps the previous configuration active. Set `REDIWM_CONFIG` to override the path.

<details>
<summary><b>🗂️ Configuration sections</b></summary>

`[theme]` · `[input]` · `[input_method]` · `[compositor]` · `[region]` · `[idle]` · `[night_light]` · `[notifications]` · `[desktop]` · `[polkit]` · `[ipc]` · and more.

</details>

<details>
<summary><b>🪟 Per-window rules and a Picture-in-Picture example</b></summary>

Window rules match by globs. For each property, the **last matching rule wins**.

```toml
[[window_rules]]
app_id = ["firefox", "chromium"]
title = "*Picture-in-Picture*"
opacity = 0.9
skip_taskbar = true
focus = false
```

**Matchers:** `app_id`, `title`, `x11_class`, `x11_instance`, `backend`, `dialog` and `exclude_*`.

**Properties:** `output`, `x`, `y`, `center`, `width`, `height`, `maximized`, `fullscreen`, `focus`, `depth`, `opacity`, `decorations` and `skip_taskbar`.

</details>

<a name="ipc"></a>
## 🔌 Scriptable

Use **`rediwm-msg`** to talk to RediWM's JSON IPC:

```sh
rediwm-msg outputs
rediwm-msg output-config DP-1 --scale 1.5
rediwm-msg notifications
```

The socket is `$XDG_RUNTIME_DIR/rediwm-<WAYLAND_DISPLAY>.sock`, or the path specified by `REDIWM_SOCKET`, in a private directory only. The protocol reference is [`src/ipc/protocol.zig`](src/ipc/protocol.zig).

<details>
<summary><b>📡 Wire format and request examples</b></summary>

IPC v1 is UTF-8 JSON, with **one request and one response per newline**. Every request uses the envelope below; command names are case-sensitive `snake_case`.

```json
{"version":1,"id":1,"command":"windows"}
{"version":1,"id":2,"command":"move_cursor","params":{"x":100,"y":200}}
```

</details>

**Automation is opt-in.** Synthetic input and pixel reads require `automation = true` in `[ipc]`, or `REDIWM_IPC_AUTOMATION=1`. **All IPC requests are refused while locked.**

<hr />

<a name="documentation"></a>
## 📚 Docs

| Explore | What is inside |
| :--- | :--- |
| [Security](SECURITY.md) | Security boundaries and design decisions |
| [Testing](TESTING.md) | Unit and headless integration tests |
| [Installation and packaging](docs/installation.md) | Custom prefixes and distribution packages |
| [NixOS](docs/nix.md) | Flake and NixOS module |
| [D-Bus transport](src/dbus/README.md) | D-Bus integration |
| [Polkit agent](src/polkit/README.md) | Polkit integration |
| [IPC protocol](src/ipc/protocol.zig) | Command and message reference |

### Credits

Typography by **Manrope** and **JetBrains Mono** (SIL OFL 1.1). Cursors by [phinger-cursors](https://github.com/phisch/phinger-cursors) (CC BY-SA 4.0).

<a name="license"></a>
### License

RediWM's own code is dual-licensed under either the [Apache License, Version 2.0](LICENSE-APACHE) or the [MIT License](LICENSE-MIT).

Bundled third-party assets retain their own licenses: fonts in `assets/fonts` under SIL OFL 1.1, and cursors in `assets/cursors` under CC BY-SA 4.0.

<br />
<div align="center">
  <hr />
  <h3>One process. Your whole desktop.</h3>
  <p><b>RediWM</b> · Built in Zig · Powered by wlroots</p>
  <a href="#top">↑ Back to the top</a>
  <br /><br />
</div>
