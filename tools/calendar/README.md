# Calendar Phase 0 probes

Noninstalled backend evaluation tools for the [calendar plan](../../docs/plans/calendar.md).
The [qualification record](../../docs/plans/calendar-phase0.md) tracks results;
[account setup](../../docs/plans/calendar-accounts.md) prepares the later live runs.
These tools use synthetic local data. They do not implement OAuth, provider
sync, a production store, service supervision or the app/popup integration.

## Run

From the repository root:

```sh
python3 tools/calendar/probe.py inventory
python3 tools/calendar/probe.py local --backend native
python3 tools/calendar/probe.py local --backend eds --idle-seconds 15
python3 tools/calendar/probe.py local --backend all --output /tmp/calendar-local.json
```

Python 3, a C compiler and `pkg-config` are required. The native probe links
SQLite and libical. EDS additionally needs `libecal-2.0`, `libedataserver-1.2`,
the source-registry/calendar-factory executables and local calendar module,
`dbus-daemon`, `gdbus` and `glib-compile-schemas`. The inventory reports libcurl,
libsecret and detected CalDAV/Microsoft365 modules separately; library presence
does not demonstrate HTTP synchronization, keyring access or provider support.

The default `local` backend selection is `all`. Exit codes are `0` for the
requested local checks passing, `1` for a probe failure and `2` for unavailable
backend development dependencies. `inventory` reports missing dependencies
without failing. Every report retains `phase0_complete: false` and
`backend_decision: pending`. An output report is created privately and is never
overwritten. The repository build and installed programs do not depend on EDS
or these tools.

## Test an extracted EDS package

No host package installation is necessary when a compatible binary package is
already available. Extract it into a scratch directory and pass its `usr`
directory. Its shared-library dependencies must also be available; a package
from a different distribution or ABI is not interchangeable.

For the cached Arch package used in the first run:

```sh
umask 077
calendar_eds_root=$(mktemp -d /tmp/calendar-eds.XXXXXX)
tar -xf /var/cache/pacman/pkg/evolution-data-server-3.60.2-5-x86_64.pkg.tar.zst \
  -C "$calendar_eds_root"
python3 tools/calendar/probe.py local \
  --eds-prefix "$calendar_eds_root/usr" --idle-seconds 15
```

That archive path is machine-specific. `--eds-prefix` accepts the same layout
from another compatible package. The runner relocates `.pc` directory values
in a temporary copy and sets a private library search path; it does not edit
the extracted package or install it. Only the local EDS calendar backend is
loaded. The Microsoft provider lives in an additional package and is not
exercised here.

## What each check establishes

`native_probe.c` parses, serializes and reparses an embedded timezone, a
recurring master, moved/cancelled exceptions and unknown metadata. It expands
a bounded master range with an exclusion across an Auckland DST change. A
small synthetic SQLite schema checks rollback and retention of a pending edit
and base revision through cache replacement and database reopen. It does not
apply detached exceptions to an agenda, resolve a conflict, recover from power
loss or send a pending edit to a provider.

`eds_probe.c` creates a local calendar, creates/edits a recurring master and
moves one occurrence. The runner stops the calendar factory, source registry
and bus, starts fresh processes, then reads the stored event and exception
using the original occurrence identity. This establishes orderly restart
persistence, not recovery from a crash during a write. Its blocking C API
calls are confined to the disposable CLI; an eventual service bridge still
needs asynchronous subscriptions and cancellation.

The Linux-only idle observation reports PSS/RSS and per-thread context-switch
deltas after the client disconnects. Threads entering or leaving the sample
are counted separately; departed threads' final counters are unavailable.
This local-only runtime disables backend subprocesses and uses `--keep-running`
for measurement. It is not the production process layout or a qualified idle
budget. There is no equivalent native-service measurement because that service
does not exist yet.

## Isolation and teardown

Each invocation builds into a fresh mode-0700 temporary directory. HOME and
all XDG paths point inside it. The environment excludes inherited display,
bus, proxy and credential settings. The EDS run starts its own bus with no
activation service directories, points the system bus at a nonexistent private
socket, loads only the local calendar module and uses memory-backed settings.
No network account is configured, no keyring is activated, and no host EDS or
compositor service is contacted. This is fixture isolation, not an OS network
sandbox for arbitrary untrusted code.

Compiler and probe calls have deadlines; owned process groups are terminated
on timeout or teardown, including children whose parent has already exited.
The runner removes temporary state after either success or failure. The C
probes are intended to be run through this wrapper. EDS also checks the private
directory and bus environment before connecting.
