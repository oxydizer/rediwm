# RediWM

RediWM is a wlroots compositor that draws its whole shell itself: taskbar,
start menu, settings, lock and login screens, notifications, OSDs. One process,
no waybar/greeter/launcher/notification daemon to wire up.

## Pages

- [Getting Started](Getting-Started.md): build, install, recover a stuck session
- [Using RediWM](Using-RediWM.md): keybinds, mouse, zoom, tabs, tiling
- [Configuration](Configuration.md): the config file, window rules, sandbox allowances
- [IPC](IPC.md): the socket, the wire format, events, waiting, automation
- [IPC Commands](IPC-Commands.md): every command, grouped
- [rediwm-msg](rediwm-msg.md): the CLI, with copy-paste recipes
- [Apps and Services](Apps-and-Services.md): Files, Images, PDF, Editor, desktop, notifications, lock/login
- [Protocols and Sandboxing](Protocols-and-Sandboxing.md): which Wayland protocols we speak and who gets what

## The binaries

| Binary | What it is |
| --- | --- |
| `rediwm` | the compositor |
| `rediwm-session` | supervises the compositor, restarts it after a crash |
| `rediwm-msg` | IPC command line client |
| `rediwm-dm` | optional login manager (only with `--dm`, never enabled for you) |
| `rediwm-files` | file manager |
| `rediwm-images` | image viewer |
| `rediwm-pdf` | sandboxed PDF viewer |
| `rediwm-editor` | text editor |
| `rediwm-desktop` | desktop icons and wallpaper |
| `rediwm-share-picker` | screen sharing picker |
| `rediwm-accounts-helper` | root helper for account management, runs under `pkexec` |

## Other docs in the repo

- `SECURITY.md`: security model
- `TESTING.md`: how the tests run
- `AGENTS.md`: implementation notes for contributors
