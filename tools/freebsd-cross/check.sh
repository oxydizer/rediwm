#!/bin/bash
# Cross-builds the tree for FreeBSD on a Linux host, to find what the next
# FreeBSD build would fail on before anyone has to run one. Nothing is run:
# the check is that every Zig and C unit compiles and the build reaches the
# link. See README.md for what a clean result means and what it cannot show.
#
#   tools/freebsd-cross/check.sh [zig build arguments...]
#   tools/freebsd-cross/check.sh -Doptimize=ReleaseSafe
#   tools/freebsd-cross/check.sh test
#
# Needs Arch Linux (pacman names the packages whose headers are kept), bwrap,
# pkg-config, python3 and zig. State lives in $REDIWM_FREEBSD_WORK (default
# ~/.cache/rediwm-freebsd-cross); it is safe to delete.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${REDIWM_FREEBSD_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/rediwm-freebsd-cross}
TARGET=x86_64-freebsd.15.0 # Zig's default FreeBSD version predates inotify in libc

# Runs "$@" in a sandbox where the host's libc headers are gone (so Zig's own
# FreeBSD ones are used) and the third-party headers are still there.
sandboxed() {
    bwrap --ro-bind / / --tmpfs /tmp --bind "$WORK" "$WORK" \
        --ro-bind /usr/include "$WORK/hostinc" --ro-bind "$WORK/inc" /usr/include \
        --tmpfs /usr/local/include \
        --setenv PATH "$WORK/bin:$PATH" --setenv ZIG_GLOBAL_CACHE_DIR "$WORK/zglobal" \
        --dev /dev --proc /proc --chdir "$ROOT" "$@"
}

# /usr/include for the sandbox: symlinks to every top-level header or directory
# that no libc package owns. `sys` mixes libc and other files, so it is dropped
# and given back as just the one header libudev.h wants.
make_header_farm() {
    local owned
    owned=$(pacman -Qlq glibc linux-api-headers gcc gcc-libs libxcrypt 2>/dev/null | grep '^/usr/include/') || return 1
    OWNED="$owned" python3 - "$WORK" <<'PY' || return 1
import os, sys
work = sys.argv[1]
owned = set(os.environ["OWNED"].split("\n"))
root = "/usr/include"
for name in sorted(os.listdir(root)):
    path = os.path.join(root, name)
    files = []
    if os.path.isdir(path) and not os.path.islink(path):
        for d, _, fs in os.walk(path):
            files += [os.path.join(d, f) for f in fs]
    else:
        files = [path]
    inside = [f for f in files if f in owned or f + "/" in owned]
    if inside:  # all libc, or mixed (`sys`): not kept
        continue
    os.symlink(os.path.join(work, "hostinc", name), os.path.join(work, "inc", name))
PY
    mkdir -p "$WORK/inc/sys" && : >"$WORK/inc/sys/sysmacros.h"
}

setup() {
    mkdir -p "$WORK/hostinc" "$WORK/stubs/lib" "$WORK/stubwork" "$WORK/zglobal" "$WORK/zlocal" "$WORK/bin" || return 1
    if [ ! -d "$WORK/inc" ]; then
        mkdir -p "$WORK/inc" && make_header_farm || { rm -rf "$WORK/inc"; echo "could not build the header farm (is this Arch?)"; return 1; }
    fi
    echo 'int rediwm_stub;' >"$WORK/stubwork/stub.c"
    # pkg-config as the sandbox sees it: Arch's readline asks for glibc feature
    # macros, empty libraries are findable, and the header farm is on the path.
    cat >"$WORK/bin/pkg-config" <<WRAP
#!/bin/bash
out=\$(/usr/bin/pkg-config "\$@") || exit \$?
out=\$(echo "\$out" | sed -e 's/-D_DEFAULT_SOURCE//g' -e 's/-D_XOPEN_SOURCE=[0-9]*//g')
case " \$* " in *" --libs"*) out="\$out -L$WORK/stubs/lib";; esac
case " \$* " in *" --cflags"*) out="\$out -I/usr/include";; esac
echo "\$out"
WRAP
    chmod +x "$WORK/bin/pkg-config"
}

# An empty FreeBSD shared library for every one the build could not find.
# Prints how many it made.
make_stubs() {
    local made=0 name
    for name in $(grep -ho 'unable to find dynamic system library "[^"]*"' "$1" | sed 's/.*"\(.*\)"/\1/' | sort -u); do
        [ -e "$WORK/stubs/lib/lib$name.so" ] && continue
        (cd "$WORK/stubwork" && zig build-lib -target x86_64-freebsd -dynamic -OReleaseSmall stub.c --name "$name" -femit-bin="$WORK/stubs/lib/lib$name.so" >/dev/null 2>&1) && made=$((made + 1))
    done
    echo "$made"
}

cross_build() {
    sandboxed zig build --cache-dir "$WORK/zlocal" --prefix "$WORK/out" --search-prefix "$WORK/stubs" \
        -Dtarget=$TARGET --summary failures -freference-trace=6 "$@"
}

main() {
    setup || return 1
    local log="$WORK/last.log" pass made
    for pass in 1 2 3 4; do
        cross_build "$@" >"$log" 2>&1
        made=$(make_stubs "$log")
        [ "$made" = 0 ] && break
    done
    # What a clean result still contains: the empty libraries leave undefined
    # symbols, the host tool rediwm-cursorgen needs the hidden headers, test
    # binaries cannot run here, and auth-tests builds without pkg-config.
    local real
    real=$(grep -E 'error:' "$log" | grep -vE 'compilation errors|process exited|undefined symbol|LibCStdLibHeaderNotFound|unable to execute|failed command|security/pam_appl.h')
    grep -E 'Build Summary' "$log"
    if [ -n "$real" ]; then
        echo "$real" | sed -E "s|$WORK/zlocal/o/[0-9a-f]*/||" | sort -u | cut -c1-240
        echo "FreeBSD cross-check: FAIL (full log: $log)"
        return 1
    fi
    echo "FreeBSD cross-check: PASS (only link-time and host-tool errors remain; log: $log)"
}

main "$@"
