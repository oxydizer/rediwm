# Files transfers

Files opens `.torrent` files directly. Magnet handlers use the installed
`rediwm-transfers.desktop` entry, which invokes `rediwm-files --torrent URI`.
It advertises support without replacing an existing default application.
`rediwm-files --transfers` opens the transfer list. The Transfers section below
removable devices opens the same interface and shows aggregate activity.
Transfers appears in the main Files pane using the file-list rows and column
headers. Add torrent, Pause all and Stop seeding appear in the toolbar beside
the view icons. Open a row for file selection and per-transfer controls; Back
or a sidebar place returns to browsing folders.

Folder listings also show transfer status beside the name, a circular progress
indicator and a play/pause button. Hover the circle for percentage, download and
upload speeds, connected peers, seeds, known peers and ETA. A stalled or paused
download has no ETA until data is arriving again. Space toggles the focused
transfer; clicking its circle opens details. A visible `.torrent` source gets
these controls too. Before publication, the destination folder shows a transfer
entry for the staged download; it opens transfer details and is excluded from
copy, rename, trash and drag operations. Completion replaces it with the real
published folder. No files are renamed to encode progress.

Choose an existing destination folder, then choose files and start. Magnet
links fetch metadata first; they do not download payload until confirmed.
The first version has paged file selection, pause/resume, removal that keeps
files, and two upload limits (128 KiB/s or 1 MiB/s). Seeding can stop at download
completion, ratio 1 or ratio 2. The session upload ceiling is 1 MiB/s.

Downloads and seeding continue after the last Files window closes: Files stays
up without a window while the helper downloads or seeds, mirroring each
torrent as a job, so the shell's Transfers panel shows them (with their speed,
share ratio and Stop seeding) beside copies and extractions. The helper has no
tray icon of its own. A completion notification is sent when
a notification service is already running. Transfers recover when Files next
starts after logout or a helper crash; there is no new login autostart service.

## Build

Install development packages for **libtorrent-rasterbar**, **gio-unix-2.0**
and **json-glib-1.0**, plus a system C++17 compiler and pkg-config. The helper
is compiled with the system compiler to match the distribution's C++ ABI;
it is a native Linux helper. The tested libtorrent version is 2.1.2. Files
itself does not link C++ or libtorrent. `zig build` and `zig build files`
build and install `rediwm-transfers` beside `rediwm-files`.

## Storage and lifetime

The per-user helper listens on `$XDG_RUNTIME_DIR/files-transfers.sock`, mode
0600, with a singleton flock and same-user credential checks. The socket name
must not match the compositor's `rediwm-*.sock` discovery pattern. Files uses
nonblocking messages and a bounded connection-start deadline, not idle polling.
The helper sends bounded snapshots, disconnecting stalled subscribers rather
than blocking its engine. It permits up to 64 transfers and 512 files per
torrent; local torrent metadata is limited to 8 MiB.

Resume data and transfer settings live under
`$XDG_STATE_HOME/rediwm/transfers`, or `~/.local/state/rediwm/transfers`. Writes
use temporary files, fsync and rename. Active sessions checkpoint every 30
seconds and on state changes. SIGTERM requests final resume data with a bounded
shutdown deadline. The helper releases libtorrent entirely once all transfers
are paused and outstanding save alerts have drained; attached Files windows
then require no torrent worker timers. With no clients and no active transfers,
the helper exits. A later command restores the engine from saved state.

Incomplete data lives in the selected folder's private
`.rediwm-partials/INFOHASH/` directory. Completion pauses disk activity and
atomically publishes that whole directory as `TORRENT-NAME.download/`, retaining
the torrent's internal paths. Existing destination folders are never replaced.
The storage path is then updated and seeding resumes if allowed. A collision
pauses the transfer and preserves its partial data; rename the conflicting
folder and Resume to retry. This staging scheme keeps incomplete files out of
the normal folder view and thumbnail pipeline.

Remove always keeps payloads, including partials. Use Show in folder to locate
them before removing a transfer. Moving or editing files outside the transfer
engine can interrupt seeding; pause/remove the transfer before reorganizing
its data. This version does not include tracker editing, torrent creation,
streaming previews, automatic move tracking or individual file-row progress.

## Validation

`zig build test-files-torrents` runs real engine and headless UI tests
without contacting public peers, trackers or the user's session bus. Set
`REDIWM_TEST_BIN_DIR` to an alternate build's `bin` directory to exercise it. The
fixture network shim is never installed or linked into production binaries.
See `TESTING.md` for dependencies and isolation rules.
