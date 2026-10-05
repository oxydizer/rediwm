# Using RediWM

## Keys

| Keys | Action |
| --- | --- |
| Super+Space | start menu |
| Super+T / E / B | terminal / Files / browser |
| Super+Q, Super+F, Super+M | close, fullscreen, maximize |
| Super+Shift+arrows | tile halves and quarters |
| Super+arrows | slide to the neighbouring desktop |
| Super+Ctrl+arrows | focus the window in that direction |
| Alt+Tab | window switcher |
| Super+1..5, Super+=/-/0 | window zoom |
| Super+Shift+=/-/0 | desktop zoom |
| Super+L | lock |
| Ctrl+Shift+S, Print | region / full-screen screenshot |
| Super+Z | undo the last window move or resize |
| Super+Shift+E | quit |
| Super+Escape | take shortcuts back from a VM or remote desktop |

Everything lives under `[keybinds]` in the config. Set a binding to `"noop"`
to turn it off.

## Mouse

- **Alt+drag** moves a window, **Alt+right-drag** resizes.
- **Super+Alt+mouse** or a middle-button drag pans the desktop.
- **Super+Alt+scroll** zooms the desktop, **Alt+scroll** over a window zooms
  just that window. Scrolling on a titlebar does the same.
- Drag a window to a screen edge to tile or maximize it (`snap_to_edges`).

## The canvas

The desktop is one big canvas, `canvas_columns` x `canvas_rows` screens (3x3 by
default). You pan around it and zoom out to see everything. Desktop zoom scales
all windows together around the pointer, up to 100%, and doesn't change their
world positions. Desktop icons and the taskbar stay fixed on screen by default.
The mini map shows where you are and hides itself after a moment.

The volume/brightness OSD also shows the desktop zoom percentage.

## Window switching zoom

Settings > Appearance, or `[compositor] focus_zoom`. Controls what Alt+Tab,
directional focus and taskbar clicks do to the camera.

| Mode | What happens |
| --- | --- |
| `boost` (default) | the selected floating window goes to 100% on-screen size, then goes back when you switch away. Saved zoom and position are untouched |
| `keep` | just pans |
| `camera` | zooms the desktop to the window's depth and fades windows that would grow past full size. Desktop zoom then steps through window depths |

Reveals ease over 320 ms. Animation speed and reduced motion apply. You can
override the pan with `[animations.camera_reveal]`.

## Window tabs

Settings > Appearance > Window tabs lets you pick apps that get tabs, using
RediWM chrome (XDG, KDE or X11 decorations). Open the app once and it shows up
in the list.

- The **+** button opens another window as a tab in that frame. Normal
  launches stay separate.
- Each tab has its own close button. The outer close button closes the whole
  group and respects app confirmation dialogs.
- Arrow buttons or scrolling over the strip switch tabs. Alt+scroll still
  zooms the window.
- The app needs a desktop entry with a usable launch command. Launches that
  only activate an existing window don't make a tab.
- Saved in `[compositor] window_tab_apps`.

## Settings

Start menu cog. It's a normal window covering display modes, scale, night
light, input, audio, appearance, shortcuts and the desktop canvas. Changes are
written to the config and your comments stay intact.

## Locking

- The lock screen covers every output. Escape clears the field and never
  unlocks.
- Volume and brightness work behind the lock: the hardware keys, or the
  sliders at the bottom of the screen (click the speaker to mute). A slider
  appears only if there's a sound output or a backlight to control. The login
  screen has no sliders.
- It engages before the system sleeps and waits until it's on screen first
  (`lock_on_suspend`, on by default). `loginctl lock-session` works too.
- RediWM doesn't lock on idle by itself. Run swayidle from `[[autostart]]`:
  `swayidle -w timeout 300 'swaylock -f'`.
- Lock-screen UI can't be driven by virtual input.

## Games, VMs, X11

- Games get pointer lock and relative motion.
- Xwayland starts on the first X11 connection. With native scaling, X11 apps
  render at `ceil(max output scale)` and stay sharp on HiDPI.
- Known limits from wlroots 0.20: X11 to Wayland drag and drop doesn't start,
  and X11 pointer input on a second output doesn't arrive.
