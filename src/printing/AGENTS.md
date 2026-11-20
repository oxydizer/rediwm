# Printing

* `cups.zig` queries the configured Unix or cleartext TCP CUPS endpoint. TLS and
  authentication are explicit unsupported states; never fall back to a
  different server. Configuration read failures are not missing files.
  Both administration backends target the canonical local socket, never a
  custom Unix or remote endpoint. `admin.zig` selects cups-pk-helper when
  present, otherwise `direct.zig` runs the `rediwm-cups` helper
  (`src/cups_main.zig` + `direct.c`, frames in `direct_protocol.zig`). Never
  retry an uncertain mutation through another backend.
* **The compositor never links libcups.** libcups drags in gnutls, nettle,
  p11-kit and friends, which would be mapped in every session for a page used
  rarely; only `rediwm-cups` links it (`build/printing.zig`), and the compositor
  stays free of it (check `ldd`; `tests/printers_direct.py` checks the mappings).
  The helper starts on the first administration request (a read-only page never
  starts it), dies with `Worker.destroy` (SIGKILL: instant, even mid-prompt) and
  with the compositor (EOF on its socket, PDEATHSIG). A helper that dies fails
  the request in flight as uncertain, never retried; the next request starts a
  fresh one. It runs as the desktop user, non-dumpable, never as root, and
  refuses methods and argument counts `direct.c` does not implement.
* Inside the helper, `direct.c`'s worker alone uses libcups (including its
  thread-local authentication state). UI credentials use locked storage and are
  wiped on submit/cancel/hide; they travel from that storage into a `sendmsg`
  iovec (no copy) and are received into a locked page, never the plain frame
  buffer (`Receiver` picks the destination by frame kind, reading exactly the
  bytes a frame lacks). A chain may reuse its CUPS connection, but completion
  closes it and wipes the worker password. The deadline watcher owns a
  duplicated socket descriptor, never a borrowed descriptor that libcups could
  close/reuse during authentication. The helper has no timed wakeups while idle
  or waiting for user input: its loop sleeps in `poll(-1)`. Keep `direct.c`'s C
  API stable: `tests/printers_direct.py` drives it directly through ctypes.
* `Worker` callbacks may free the worker: the frame reader handles one frame per
  event-loop call and touches nothing after the callback. The helper's state
  frames are checked against the request state (a prompt only while a request
  runs); anything else drops the connection.
* IPP and HTTP replies are untrusted and bounded. Socket operations share an
  absolute deadline and include the worker cancellation fd in every wait.
* `cups.Snapshot` owns an arena. Parser helpers allocate into that arena;
  borrowed decoder fields must not escape it. Display strings are sanitized,
  but URI identity uses the complete validated value, never truncated text.
* `usb_sysfs` only reads sysfs and stats nodes. A unique serial can identify a
  USB queue; product strings and VID:PID alone cannot. Missing `usblp` is normal
  for libusb. Missing/inaccessible evidence stays unknown.
* The ladder is pure and reports evidence, not physical printing. A CUPS
  completed state or sheet counter alone cannot establish paper output.
  Reports exclude arbitrary names, messages, serials and URI authorities/paths.
* Worker lifetime and widget ownership: `src/control_center/AGENTS.md`.
  Remaining features and hardware/distro qualification: `docs/plans/printers.md`.
