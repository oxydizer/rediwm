#!/bin/sh
# Probe of FreeBSD's login and seat stack for RediWM (docs/plans/freebsd.md,
# "Login and seat"). It only reads: packages, services, PAM stacks, devices,
# ConsoleKit2's D-Bus interfaces and what polkit says about this shell. A bus
# call may start a service that is installed but not running, which is part of
# the answer. It writes one report; send that file back.
#
# Run it from a console login (not ssh) as the user who will run RediWM:
#
#     sh tools/freebsd-probe/login-probe.sh [report-file]    # ./login-probe.txt

report=${1:-login-probe.txt}
ck=org.freedesktop.ConsoleKit
ck_manager=/org/freedesktop/ConsoleKit/Manager

section() { printf '\n==== %s ====\n' "$*" >> "$report"; }

# One command, its output and exit status; a missing tool is a finding too.
run() {
    printf '\n$ %s\n' "$*" >> "$report"
    if command -v "$1" > /dev/null 2>&1; then
        "$@" >> "$report" 2>&1
        printf '[exit %s]\n' "$?" >> "$report"
    else
        printf '[%s not installed]\n' "$1" >> "$report"
    fi
}

bus() { # bus DEST PATH MEMBER [ARG...]: a system bus method call
    dest=$1 path=$2 member=$3
    shift 3
    run dbus-send --system --print-reply --dest="$dest" "$path" "$member" "$@"
}

main() {
    section "who and where"
    run uname -srm
    run id
    run tty
    # Only the session variables, never the whole environment.
    printf '\n$ env (XDG_*, DBUS_*)\n' >> "$report"
    env | grep -E '^(XDG_|DBUS_)' | sort >> "$report" 2>&1
    if [ -n "$XDG_RUNTIME_DIR" ]; then run ls -ld "$XDG_RUNTIME_DIR"; fi

    section "packages and services"
    run pkg info -x '^(seatd|consolekit|dbus|polkit|pam_xdg|libudev|libinput|wlroots|drm-kmod|gpu-firmware)'
    run service -e
    run pgrep -lf 'seatd|dbus-daemon|console-kit|polkitd|powerd'

    section "seat: seatd, devices, console"
    run ls -l /var/run/seatd.sock /run/seatd.sock
    run getent group seatd video
    run kldstat
    run ls -l /dev/dri /dev/input /dev/console /dev/ttyv0
    run sysctl kern.vty kern.evdev.rcpt_mask hw.acpi.supported_sleep_state hw.acpi.lid_switch_state

    section "PAM"
    run grep -n '^session' /etc/pam.d/login
    run sh -c "grep -n -E 'pam_(ck_connector|xdg|systemd)' /etc/pam.d/* /usr/local/etc/pam.d/*"

    section "ConsoleKit2: sessions and interfaces"
    run ck-list-sessions
    bus org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames
    bus "$ck" "$ck_manager" org.freedesktop.DBus.Introspectable.Introspect
    bus "$ck" "$ck_manager" "$ck.Manager.GetSessionForUnixProcess" uint32:$$
    bus "$ck" "$ck_manager" "$ck.Manager.GetCurrentSession"

    session=$(dbus-send --system --print-reply --dest="$ck" "$ck_manager" \
        "$ck.Manager.GetSessionForUnixProcess" uint32:$$ 2> /dev/null |
        sed -n 's/.*object path "\(.*\)"/\1/p')
    if [ -n "$session" ]; then
        section "ConsoleKit2: this shell's session ($session)"
        bus "$ck" "$session" org.freedesktop.DBus.Introspectable.Introspect
        for member in GetId GetSeatId GetSessionType GetUnixUser IsLocal IsActive \
            GetDisplayDevice GetX11Display GetRemoteHostName GetLockedHint; do
            bus "$ck" "$session" "$ck.Session.$member"
        done
    else
        section "ConsoleKit2: no session for this shell"
    fi

    section "polkit (no -u, so it cannot prompt)"
    run pkaction --version
    run pkcheck --action-id org.freedesktop.policykit.exec --process $$
}

if ! : > "$report"; then
    echo "login-probe: cannot write $report" >&2
else
    main
    echo "login-probe: wrote $report"
fi
