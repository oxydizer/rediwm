#!/bin/sh
# Fake pkexec for tests/firewall_settings.py, bind-mounted over /usr/bin/pkexec
# in the test's private mount namespace only. Called as
#   pkexec --disable-internal-agent <helper> read|manage
# it runs the fake helper instead, and exits 126 (a dismissed dialog) when the
# test asks it to refuse that mode.
[ "$1" = "--disable-internal-agent" ] && shift
mode="$2"
[ -e "$FIREWALL_FAKE_DIR/deny-$mode" ] && exit 126
PKEXEC_UID=$(id -u) exec python3 -I "$FIREWALL_FAKE_HELPER" "$mode"
