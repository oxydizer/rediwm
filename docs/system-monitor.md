# System Monitor

Open **System Monitor** from the launcher, with **Ctrl+Alt+Del**, or by
running `rediwm-monitor`. The shortcut restores and focuses an existing
window, including one on another workspace. It dismisses open shell popups,
the window switcher and screenshot selection, and takes focus even when a
client has inhibited compositor shortcuts.

CPU and RAM summary cards show large current percentages and shaded 60-second
graphs. CPU includes its reported frequency and logical CPU count; RAM includes
used/total capacity and a usage bar. Graph axes show CPU percentages and memory
capacity. The cards use a compact layout in narrow windows. System RAM usage is
`MemTotal - MemAvailable`; process memory is resident memory. A process
using one CPU core reads 100%, so multithreaded processes can exceed 100%.
New processes and the first sample after resuming show an em dash until
there is a second CPU measurement. Unavailable data also shows an em dash.
Nonlocal account names fall back to their numeric UID.

The bottom bar groups CPU, RAM, swap, network, uptime and CPU/GPU temperatures
beside the process actions. It wraps the readouts and actions at smaller
window sizes. CPU shows online logical CPUs and CPU 0's reported frequency;
RAM and swap show used/total capacity and a percentage. Network arrows show
total upload/download rates across non-loopback interfaces (virtual interfaces
can count the same traffic again). The first sample after resume or an interface
change shows a dash. Temperature has separate **CPU** and **GPU** rows. CPU
shows the hottest supported CPU sensor. GPU shows the hottest reported GPU die
or package temperature, using Linux hwmon for AMD, Intel and Nouveau, or the
optional NVIDIA management library for the proprietary driver. GPU junction
and memory channels are excluded. NVIDIA telemetry is released while paused
or minimized. Missing metrics show a dash; FreeBSD currently provides
CPU count, frequency and uptime, with network and temperature unavailable.

The list starts with your processes, sorted by CPU usage. Click a column to
sort; click again to reverse. **My processes / All processes** changes the
ownership filter. Search matches names, PIDs and users. Selection follows
the PID and start time as rows move; refreshes preserve the scroll offset.

**End process** sends SIGTERM. **Force quit** requires confirmation naming
the target before sending SIGKILL. Both actions recheck identity, ownership
and essential RediWM session protection at execution, including after a
confirmation has been open. Signals use a validated pidfd. Other users'
processes can be viewed where `/proc` permits but cannot be managed here.
The monitor never requests elevated privileges.

The process table has alternating rows, column dividers, process glyphs and
colored state indicators. CPU bars fill at one core (100%); resident-memory
bars are relative to the largest process in the snapshot, including processes
outside the current filter. Exact values stay visible, and bars hide when the
window is too narrow to fit them.

Process rows use Files' rounded hover and selection cards. The hover fades in
and glides between rows; selection fades use the accent outline. Both follow
the theme and animation settings and stop requesting frames when settled.

| Key | Action |
| --- | --- |
| Ctrl+F | Focus search and select its text |
| Up / Down | Select a process; leave search for the list |
| Page Up / Page Down | Move by a visible page |
| Home / End | First / last process when outside search |
| Tab / Shift+Tab | Navigate controls |
| Enter / Space | Activate the focused control |
| Delete | End selected process |
| Shift+Delete | Open Force quit confirmation |
| Escape | Cancel confirmation or clear search |
| Ctrl+Q / Ctrl+W | Close |

Collection runs once per second in a worker in the monitor process.
**Pause updates** and minimizing suspend collection; restoring respects the
pause setting. Losing keyboard focus does not suspend collection. The
worker blocks without periodic wakes when paused or minimized. Closing
cancels collection and joins it. Minimize signaling uses xdg-shell v6's
`suspended` state, supplied by RediWM; other compositors must support that
state for minimize suspension. Live themes use filesystem notifications.
Fractional scaling uses fractional-scale-v1 and viewporter when available.

## Existing shortcut configuration

Both presets now use `open_system_monitor`. Explicit user bindings are
preserved. Existing canvas shortcut lists inherit Ctrl+Alt+Delete when that
key is unassigned, so **Open System Monitor** also appears under **System**
in Settings → Keyboard Shortcuts. For an older canvas config containing
`"ctrl+alt+delete" = "poweroff"`, replace that line in
`~/.config/rediwm/config.toml`:

```toml
[keybinds]
"ctrl+alt+delete" = "open_system_monitor"
```

For explicit workspace overrides, use the existing section:

```toml
[keybinds.workspace]
"Ctrl+Alt+Delete" = "open_system_monitor"
```

Lock, greeter, authentication prompts and shortcut editing keep priority.
The app gets its own application scope when scope management is enabled.

## Building and testing

`zig build` installs the app, desktop entry and icon in the build prefix.
`zig build monitor` builds just those files. The session installer includes
them too. `zig build test-monitor` tests accounting, collection, identity,
process actions, the list model and worker lifetime.

`python3 tests/system_monitor.py` exercises both desktop modes in private
headless compositors; repeat with `REDIWM_TEST_SCALE=1.5`. All action targets
are disposable test children. See [TESTING.md](../TESTING.md).

Accounting follows the [Linux proc documentation](https://docs.kernel.org/filesystems/proc.html);
actions follow the [pidfd signal contract](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html).
