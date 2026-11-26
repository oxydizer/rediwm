# Files transfers

Files opens `.torrent` files directly. Magnet handlers use the installed
`rediwm-transfers.desktop` entry, which invokes `rediwm-files --torrent URI`.
It advertises support without replacing an existing default application.
Downloads, like copies, are followed in the shell's Transfers panel; Files has
no list of its own.

Folder listings also show transfer status beside the name, a circular progress
indicator and a play/pause button. Hover the circle for percentage, download and
upload speeds, connected peers, seeds, known peers and ETA. A stalled or paused
download has no ETA until data is arriving again. Space toggles the focused
transfer; clicking its circle opens its files. A visible `.torrent` source gets
these controls too. Before publication, the destination folder shows a transfer
entry for the staged download; it opens as a folder and is excluded from
copy, rename, trash and drag operations. Completion replaces it with the real
published folder. No files are renamed to encode progress.

## A torrent is a folder

Opening a `.torrent` file enters it like a folder or an archive: its files
are ghosts, each with a checkbox, and browsing starts inside the folder the
torrent keeps its files in. Looking adds nothing (the helper reads the file,
`inspect`). Ticking means downloading: the first tick adds the torrent and
downloads what is ticked into the folder the `.torrent` file is in. A folder's
checkbox ticks or unticks everything in it and shows a dash while only part of
it is ticked. Space ticks the selected rows (or unticks them, when all are
ticked); clicking a row selects it without ticking it. An unticked file is
faint and shows its size; a ticked one fills with its progress; a finished
one is a real file that opens. Unticking keeps what has arrived, and ticking
more files of a finished download fetches them into its published folder.
The status bar counts the ticks and the bytes they hold.

A magnet asks for its destination folder, which then shows the download as a
ghost folder; it reads "Fetching file list…" until the metadata arrives, then
its files can be ticked the same way. The download's row in its destination
folder, its circle and the shell panel's Choose files… all open the same
folder view. Downloads start with ratio 1 seeding and a 1 MiB/s upload limit.
The session upload ceiling is 1 MiB/s.

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

Remove (cancel in the panel) always keeps payloads, including partials. Moving or editing files outside the transfer
engine can interrupt seeding; pause/remove the transfer before reorganizing
its data. This version does not include tracker editing, torrent creation,
streaming previews or automatic move tracking.

## Validation

`zig build test-files-torrents` runs real engine and headless UI tests
without contacting public peers, trackers or the user's session bus. Set
`REDIWM_TEST_BIN_DIR` to an alternate build's `bin` directory to exercise it. The
fixture network shim is never installed or linked into production binaries.
See `TESTING.md` for dependencies and isolation rules.
