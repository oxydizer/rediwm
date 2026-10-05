#!/usr/bin/env python3
"""Held keys repeat in compositor-drawn UI at the configured [input] timing.

The start menu's search box stands in for every shell target: `Keyboard`
owns the one repeat timer for all of them (the lock and polkit dialog reject
the synthetic keyboard, so they can't be driven from here).
"""
from pathlib import Path
import tempfile
import time
from ipc_client import IPCClient, spawn_compositor, stop_process

KEY_A = 30
KEY_B = 48
KEY_BACKSPACE = 14
KEY_LEFTSHIFT = 42
DELAY_MS = 200
RATE = 20

CONFIG = f"""[compositor]
xwayland = false
[input]
key_repeat_delay = {DELAY_MS}
key_repeat_rate = {RATE}
"""


def query(client):
    menu = client.get_shell_state()["start_menu"]
    assert menu is not None, "start menu closed"
    return menu["search_text"] or ""


def hold(client, keycode, seconds):
    client.key(keycode, True)
    time.sleep(seconds)
    client.key(keycode, False)


def settled(client):
    """The query after any in-flight repeat tick has landed."""
    time.sleep(0.25)
    first = query(client)
    time.sleep(0.25)
    assert query(client) == first, "still repeating after release"
    return first


def check(tmp):
    with IPCClient(tmp, timeout=15) as client:
        client.wait_for("wallpaper_presented", timeout_ms=10000)
        client.open_start_menu()

        # A tap is one character: nothing repeats before the delay.
        client.key_down_up(KEY_A)
        assert settled(client) == "a"

        # Held for a second: the press, then one repeat per 1/rate after the
        # delay, about 17 in all. Wide bounds: the host may be busy.
        hold(client, KEY_A, 1.0)
        text = settled(client)
        assert set(text) == {"a"}, text
        expected = 1 + 1 + (1000 - DELAY_MS) * RATE // 1000
        assert expected // 2 <= len(text) <= expected + 6, (len(text), expected)

        # Backspace repeats too and empties the field.
        hold(client, KEY_BACKSPACE, 1.8)
        assert settled(client) == "", "held Backspace did not clear the query"

        # Shift joins a held key without ending its repeat.
        client.key(KEY_A, True)
        time.sleep(0.5)
        client.key(KEY_LEFTSHIFT, True)
        time.sleep(0.5)
        client.key(KEY_A, False)
        client.key(KEY_LEFTSHIFT, False)
        text = settled(client)
        assert text.startswith("a") and "A" in text, text

        # A second key takes the repeat over; releasing it ends the repeat
        # even though the first is still down.
        hold(client, KEY_BACKSPACE, 1.8)
        assert settled(client) == ""
        client.key(KEY_A, True)
        time.sleep(0.4)
        client.key(KEY_B, True)
        time.sleep(0.6)
        client.key(KEY_B, False)
        text = settled(client)
        assert text.count("b") > 3 and text.endswith("b"), text
        time.sleep(0.4)
        assert query(client) == text, "the first key resumed repeating"
        client.key(KEY_A, False)

        hold(client, KEY_BACKSPACE, 1.8)
        assert settled(client) == ""
        client.close_panel("start_menu")

        # A repeat ends with its menu. Reopening (a reversed close keeps the
        # same menu, a finished one may reuse its address) doesn't bring the
        # held key back: nothing is typed while it stays down.
        for pause in (0.05, 0.6):
            client.open_start_menu()
            client.key(KEY_A, True)
            time.sleep(0.5)
            client.close_panel("start_menu")
            time.sleep(pause)
            client.open_start_menu()
            before = query(client)
            time.sleep(0.5)
            client.key(KEY_A, False)
            assert settled(client) == before, f"a held key repeated into the reopened menu ({pause}s)"
            client.close_panel("start_menu")
            time.sleep(0.6)

def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-key-repeat-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, config_content=CONFIG)
        try:
            check(tmp)
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()
        assert "panic:" not in (tmp / "compositor.log").read_text()
    print("PASS: shell key repeat")


if __name__ == "__main__":
    run()
