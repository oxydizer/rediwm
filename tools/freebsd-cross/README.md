# FreeBSD cross-check

`check.sh` builds the whole tree for `x86_64-freebsd.15.0` on a Linux host, so
the next FreeBSD build error is found here and not in a tester's log. Zig
reports errors only in code it reaches, so one fix often exposes the next
layer; this loop is cheap, a tester's round trip is not.

    tools/freebsd-cross/check.sh                          # Debug
    tools/freebsd-cross/check.sh -Doptimize=ReleaseSafe
    tools/freebsd-cross/check.sh test                     # compiles the tests

It needs Arch Linux (pacman says which headers are libc's), `bwrap`,
`pkg-config`, `python3` and `zig`. State is in `~/.cache/rediwm-freebsd-cross`
(`REDIWM_FREEBSD_WORK` to move it); the first run is slow, later ones reuse
Zig's caches.

## How it works

* `zig translate-c` and `zig build-exe` always add the host's `/usr/include`,
  so a plain `-target x86_64-freebsd` finds glibc and gives false results. The
  build runs in `bwrap` with `/usr/include` replaced by symlinks to the
  third-party headers only (cairo, wlroots, ...); Zig then uses its bundled
  FreeBSD libc headers.
* Libraries are found by name at configure time, so each missing one gets an
  empty FreeBSD `.so` (`zig build-lib -dynamic`), made on demand by looping on
  "unable to find dynamic system library". A `pkg-config` wrapper puts them
  and the header farm on the search paths.
* `.15.0` because Zig's default FreeBSD version predates `inotify_*` in libc.

## What a pass means

Every Zig and C unit compiled and the build got to the link. The remaining
errors are expected and filtered out: `undefined symbol` (the libraries are
empty), `rediwm-cursorgen` (a host tool that needs the hidden headers), test
binaries that cannot run here, and `auth-tests` (no pkg-config for PAM).

It cannot show: anything that runs; differences between Zig's bundled headers
and the target release's own; library versions (the farm holds this host's
cairo, wlroots, ...); `readline.pc` quirks (the wrapper strips Arch's glibc
feature macros). A `libc.h`-only check, without the farm:

    bwrap --ro-bind / / --tmpfs /usr/include --tmpfs /usr/local/include \
      --bind SCRATCH SCRATCH --setenv ZIG_GLOBAL_CACHE_DIR SCRATCH/zglobal \
      --dev /dev --proc /proc zig translate-c -target x86_64-freebsd -lc src/c/libc.h
