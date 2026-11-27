# Using RediWM

## Keys

| Keys | Action |
| --- | --- |
| Super+Space | centered app launcher |
| Super+Shift+Space | next keyboard layout or input method |
| Super+T / E / B | terminal / Files / browser |
| Super+Q, Super+F, Super+M | close, fullscreen, maximize |
| Super+Shift+arrows | tile halves and quarters |
| Super+Shift+W | switch between Canvas and your last tiled mode |
| Super+arrows | slide to the neighbouring desktop |
| Super+Ctrl+arrows | focus the window in that direction |
| Alt+Tab | window switcher |
| Super+1..5, Super+=/-/0 | window zoom |
| Super+Shift+=/-/0 | desktop zoom |
| Super+A | canvas window overview |
| Super+L | lock |
| Ctrl+Shift+S, Print | region / full-screen screenshot |
| Super+Z | undo the last window move or resize |
| Super+Shift+E | quit |
| Super+Escape | take shortcuts back from a VM or remote desktop |

Everything lives under `[keybinds]` in the config. Set a binding to `"noop"`
to turn it off.

Super+Shift+W (`toggle_desktop_mode`) saves the choice as `desktop_mode`.
Switching back to Canvas restores window positions and zoom. Returning to
Tiling or Scrolling restores the tiled layout.
Existing configs with their own `[keybinds]` get it unless the key is taken.
The taskbar's **Desktop mode** item (off by default; turn it on in Settings →
Appearance) shows the current mode. Left-click it to switch modes, or
right-click it to choose **Canvas**, **Tiling** or **Scrolling** from a menu. A checkmark
shows which mode is active.

### Scrolling

Switching to Scrolling arranges open windows along the strip, including
windows that were snapped, maximized, fullscreen or manually floated.
Workspace layout overrides and floating app and window rules still apply.
Returning from Canvas also restores the strip's floating choices.
New windows open in a column to the right of the focused column.
Each display shows its own workspace. Moving focus along one strip
scrolls that display, and its windows and menus stop at the display edge.
Floating windows stay in place.
Settings → Desktop lets you change the initial column width, centring, and
the layout of individual workspaces.

On a portrait or rotated display the strip runs up and down instead: each
column becomes a full-width row, and Up/Down take the role of Left/Right in
the shortcuts below. Settings → Displays → **Scrolling direction** chooses
Automatic (the display's longer side), Horizontal or Vertical for each display.

If a display disconnects, its workspaces are available on a remaining display.
Reconnecting it returns its strip and restores each display's workspace selection.

| Shortcut | Action in a scrolling workspace |
| --- | --- |
| Super+Left / Right | Focus the previous or next column; a maximized or fullscreen window keeps its place in that order |
| Super+Up / Down | Focus another window in the column |
| Super+Shift+arrows | Reorder columns or windows within a column |
| Super+Ctrl+arrows | Adjust column width or window height in 32 px steps |
| Super+W | Cycle the focused column through the width presets |
| Super+[ / ] | Join the adjacent column or leave a shared column on that side |
| Super+V | Float the focused window or return it to the strip |

With a touchpad or mouse:

- A **three-finger swipe** along the strip scrolls it with your fingers,
  wherever the pointer is. Past either end it gives a little and springs
  back. When you lift your fingers it settles on the nearest column edge,
  carrying on if you flicked, and focus moves to a column it shows.
- **Two fingers** scroll the strip over empty space (the gaps between
  columns); over a window they scroll the window, as everywhere else.
- **Super+Shift+wheel** or **Super+horizontal wheel** steps focus through
  the columns. Super+wheel still changes workspace.
- **Super+right-drag** resizes: near a column's side it sets the column's
  width, near its top or bottom the window's height within the column.
  Escape puts it back, and Super+Z undoes it.
- **Super+drag** moves a window. Near a column's side it gets a column of its
  own there; over the middle it joins that column above or below the window
  under the pointer. Hold it near the end of the display to scroll the strip.

While a strip moves, a thin bar along the display's edge shows which stretch
of it is on screen (it follows the mini-map setting). **Super+A** zooms the
display out over its whole strip: click a window, or pick one with the arrow
keys and Enter, and the strip goes there; Escape leaves it as it was. Columns
opening or closing push their neighbours aside smoothly.

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

Press **Super+A** to spread the canvas windows into separate live previews on
the monitor under the pointer. Four windows form a 2×2 grid; five form two
centred above three. Previews preserve aspect ratios and fill the screen with
only narrow gaps between them. Offscreen and minimized windows are included; hidden tabs
are excluded.

Hovering a preview enlarges it by about 10% and lifts it above its neighbours;
scrolling up over it zooms it further around the pointer, and scrolling down
returns it to the hover size.

Click a preview, or select one with the arrow keys and press Enter, to visit it.
Selecting a minimized window restores it. Escape, Super+A again, or clicking
empty space returns to the previous view and leaves minimized windows minimized.
The spread changes only presentation: window positions, sizes and saved depths
stay intact. This overview applies to canvas mode.

With `focus_zoom` enabled, accepting a window applies its normal focus boost or
camera depth. Cancelling still restores the original view.

The action is `toggle_overview`. Its default Super+A binding is added to existing
canvas configs unless that key is already assigned. Set `"super+a" = "noop"`
under `[keybinds]` to disable it, or change it in Settings → Keyboard Shortcuts.

## Window switcher

Alt+Tab cycles windows; Alt+Shift+Tab cycles backwards. Release Alt to focus
the selected window, or press Escape to cancel.

Choose **Settings → Appearance → Motion & feedback → Window switcher → Circular**,
or set this in your configuration:

```toml
[compositor]
switcher_style = "circular"
```

Windows from the same app share a stack around the circle, with a badge in the
centre showing how many; stepping onto that app's stack fans it open. The
selected window's title appears in the centre. Previews fan around the hub
with their top edge at the outer rim; tall windows are cropped at the bottom.
Up to three cards per app and eight apps per page are visible. Tab and
Shift+Tab move between apps, so a quick Alt+Tab always returns to the previous
app; while the switcher is open, the key above Tab (Shift for backwards) or
Up/Down steps through the selected app's windows, most recently used first.
With only one app open, Tab steps through its windows. Small outputs and renderers without polygon support
use the horizontal strip. Set `switcher_style = "linear"` to use the default
horizontal strip.

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
