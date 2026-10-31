# Calendar Phase 0 evidence

Started 2026-10-31 against repository HEAD `805d866`. **Backend undecided;
Phase 0 is not complete.** This record implements the first local evaluation
slice of the [calendar plan](calendar.md). Reproduction commands are in the
[probe README](../../tools/calendar/README.md); the
[account setup guide](calendar-accounts.md) prepares the remaining live runs.

## Local dependencies and probes

The host is Arch Linux x86_64. EDS was absent from the installed development
environment; a cached package was extracted under `/tmp` without installing
packages or changing host services. A private bus, private HOME/XDG directories
and only EDS's local calendar module were used. No real accounts were contacted.

| Dependency | Observed version | Source / package license metadata |
| --- | --- | --- |
| SQLite | 3.54.0 (`3.54.0-1`) | Installed; `LicenseRef-Sqlite` |
| libical | 4.0.7 (`4.0.7-1`) | Installed; `LGPL-2.1-only`, `MPL-2.0` |
| libcurl | 8.23.0 (`8.23.0-1`) | Installed, inventoried only; `curl` |
| libsecret | 0.21.8.2 (`0.21.8.2-1`) | Installed, inventoried only; `LGPL-2.1-or-later` |
| Evolution Data Server | 3.60.2 (`3.60.2-5`) | Extracted Arch package; `LGPL-2.0-only AND LGPL-2.1-or-later` |

These are observed package metadata, not a completed redistribution/notices
audit. Other release-family versions and Microsoft365 package dependencies
still need qualification. The extracted EDS package contains the CalDAV module
but no Microsoft365 module. Absence here does not establish distribution-wide
unavailability: evolution-ews is a separate package.

Archive: `evolution-data-server-3.60.2-5-x86_64.pkg.tar.zst`.
SHA-256: `727827aed97c0c18c21f83fc27b0834be5b56bc0d9c9e5462cc6bd8482e5866f`.

| Check | Result | Limit |
| --- | --- | --- |
| Native `.ics` round trip | Pass: embedded timezone, recurrence, moved/cancelled original identities and unknown metadata retained | No provider conversion or detached-exception overlay |
| Native recurrence primitive | Pass: bounded master expansion, EXDATE and Auckland DST's 23-hour interval | Not a complete agenda expansion engine; other date/time cases pending |
| Native SQLite primitive | Pass: rollback, reopen and pending/base-revision retention after synthetic cache replacement | No HTTP, conflict resolver, crash injection or production schema |
| EDS local CRUD | Pass: create recurring event, edit series, move occurrence and read by original identity | No remote backend or OAuth |
| EDS restart persistence | Pass after stopping/restarting bus, registry and calendar factory | Orderly restart, not process death during a write or power-loss recovery |
| Harness timeout/cleanup | Pass: timeout with exited parent and live descendant; teardown of SIGTERM-ignoring descendant | Synthetic owned process groups only |
| Keyring | Library available; access, unlock and token storage not tested | Required before live sign-in |

Both C probes compile with `-std=c11 -Wall -Wextra -Werror`. The native probe
also passed an AddressSanitizer/UndefinedBehaviorSanitizer run and refused reuse
of its populated database without changing the stored bytes.

## Limited idle observation

The [recorded JSON](calendar-phase0-local.json) comes from the local probes with
`--idle-seconds 15`. The sample lasted 15.004 seconds, after the client closed
and a one-second settling interval. The calendar factory used
`--keep-running --backend-per-process=0`; registry modules were disabled and only
the local calendar module was loaded.

| Process | PSS, KiB | RSS, KiB | Surviving threads' voluntary / involuntary switches | Threads exited during sample |
| --- | ---: | ---: | --- | ---: |
| Private bus | 822 | 4,468 | 0 / 0 | 0 |
| EDS source registry | 5,581 | 20,124 | 0 / 0 | 1 |
| EDS calendar factory | 8,004 | 22,516 | 0 / 0 | 3 |

No new threads appeared. Final counters for departed threads are unavailable;
the zero deltas must not be described as zero total process wakeups. This is a
local-store observation, not a production footprint or performance acceptance
result. Repeat with the selected provider modules, subscriptions, keyring and
scheduled refresh enabled. There is no native service to compare yet.

## Provider qualification matrix

Client registrations and dedicated accounts are not yet prepared. The current
tools have no browser sign-in, token storage or live-provider commands. Follow
the [setup guide](calendar-accounts.md); do not export tokens into files or chat.

| Gate | Google | Personal Outlook | Microsoft 365 work/school |
| --- | --- | --- | --- |
| Public client registration and dedicated mailbox/calendar | Pending | Pending | Pending |
| Calendar-only consent, discovery, refresh and reconnect | Pending | Pending | Pending |
| Keyring storage, locked/missing keyring and revocation | Pending | Pending | Pending |
| Primary and secondary owned calendar round trips | Pending | Pending | Pending |
| Recurring master and moved/deleted exception | Pending | Pending | Pending |
| Offline write survives restart and invalid sync state | Pending | Pending | Pending |
| Concurrent edit surfaces a conflict | Pending | Pending | Pending |
| Lost response does not duplicate a create | Pending | Pending | Pending |
| Range-boundary movement and coverage behavior | Pending | Pending | Pending |

EDS remains a candidate. Its local baseline passes, but narrow-scope credential
integration and Graph behavior are not demonstrated. SQLite/libical primitives
also pass; that is not evidence of a working native sync engine. Neither
candidate has passed the backend-selection gate.

## Decisions and next work

1. Prepare the registrations and three account classes, and inventory the
   packaged Microsoft365 backend on supported distributions. Complete dependency
   and license-notice records.
2. Prototype the keyring client and browser/PKCE flow in the isolated tool,
   then prove EDS's reduced-scope initial sign-in **and refresh** for both
   providers. Keep any native REST details separate from EDS/CalDAV behavior.
3. Run the provider matrix using dedicated calendars, including offline and
   concurrent modifications. Record failure evidence rather than filling cells
   from source-code inspection or fake servers.
4. Choose the backend and freeze the app/service contract, offline horizon and
   supervision policy. Unix socket transport remains a proposal. The existing
   helper manager does not restart exited children; supervisor/backoff,
   compositor reconnection, single-writer ownership and logout teardown still
   need an executable prototype. Notification IDs must remain scoped to a
   notification-server lifetime separately from durable reminder identities.

## Repository validation

Debug build, ReleaseSafe build and `zig build test` pass. The popup-only suite
at scales 1 and 1.5 passes, including private German locale names and live format
reload. The full `tests/calendar_popup.py` suite fails at line 262,
`assert selected == "C"`, during Settings locale selection. An independently
built, clean detached HEAD worktree at `805d866` reproduces the same assertion;
this is pre-existing. No production calendar or Settings code was changed.

Run logs are under `/tmp/rediwm-calendar-*`; those paths are temporary. The
JSON and this record retain the local evidence after scratch directories are
removed. Full integration and live-provider completion remain separate gates.
