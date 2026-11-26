#!/usr/bin/env python3
"""Legacy text fields and a real input-method-v2 peer on an isolated seat."""
from functools import partial
import os
from pathlib import Path
import tempfile

from input_protocols import Peer, compile_client
from wlr_protocols import Session, locked
from xwayland import wait_for


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-text-input-v1-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        session = Session(tmp, config='[compositor]\nxwayland = false\n[keybinds]\n"F12" = "lock_screen"\n',
                          scale=os.environ.get("REDIWM_TEST_SCALE", "1"))
        peer = partial(Peer, tmp, session.env, session.children)
        ipc = session.ipc

        def state():
            return ipc.query("get_text_input")

        try:
            app = peer("legacy", "rediwm.legacy", "v1")
            app.expect("global zwp_text_input_manager_v1 1\n")
            app.expect("v1-enter first\n")  # activate preceded map, with no IME yet
            app.send("v1-context")
            app.send("v1-caret 40 30")
            assert state()["focused"]["pending"]
            ime = peer("ime", "ime")
            ime.send("method")
            ime.expect("surround aéx界 3 1\n")
            ime.expect("content 192 10\n")  # v1 DATE is 9, v3 DATE is 10
            assert state()["focused"]["surrounding_bytes"] == len("aéx界".encode())
            assert "aéx界" not in str(state())

            # Clients can omit commit_state. Once supplied, only the client's
            # serial belongs on v1 events, independently of the IME done count.
            ime.send("commit-only")
            app.expect("v1-commit first 0 [final]\n")
            app.send("v1-serial 73")
            ime.send("compose")
            app.expect("v1-delete first -2 3\nv1-commit first 73 [composed]\n"
                       "v1-style first 0 4 6\nv1-cursor first 0\nv1-preedit first 73 [pré]\n")
            ime.send("delete-only")
            app.expect("v1-preedit first 73 []\nv1-delete first -2 3\nv1-commit first 73 []\n")
            ime.send("preedit-text pending")
            app.expect("v1-preedit first 73 [pending]\n")
            app.send("v1-reset")
            assert app.text().split("v1-preedit first 73 [pending]\n")[-1].count("v1-preedit first 73 []\n") == 1
            count = app.text().count("[composed]")
            ime.send("stale")
            app.send("sync")
            assert app.text().count("[composed]") == count

            ime.send("popup")
            wait_for(lambda: state()["popups"] and state()["popups"][0]["visible"], "v1 candidate popup")
            ipc.wait_for("window_geometry_settled", window_id=session.window("rediwm.legacy")["id"])
            original = state()["popups"][0]
            app.send("v1-caret 96 50")
            app.send("sync")
            assert state()["focused"]["cursor_rectangle"] == {"x": 96, "y": 50, "width": 2, "height": 18}
            moved = state()["popups"][0]
            assert (moved["x"] - original["x"], moved["y"] - original["y"]) == (56, 20), (original, moved)
            app.send("v1-second")
            app.expect("v1-leave first\nv1-enter second\n")
            app.send("v1-disable")  # The first field no longer owns the IME.
            ime.send("commit-only")
            app.expect("v1-commit second 0 [final]\n")

            modern = peer("modern", "rediwm.modern", "both")
            modern.expect("text-enter\n")
            app.expect("v1-leave second\n")
            seen = ime.text().count("surround aéx界")
            app.send("v1-drop-pending")
            app.send("v1-context")
            ime.send("sync")
            assert ime.text().count("surround aéx界") == seen
            app.send("v1-enable")  # Background activation may wait for focus.
            app.send("v1-serial 99")
            ime.send("commit-text only-modern")
            modern.expect("commit only-modern\n")
            app.send("sync")
            assert "only-modern" not in app.text()
            # A toolkit using both protocols for the same surface chooses
            # its field explicitly. Disabling its old v3 field cannot end v1.
            modern.send("v1-enable")
            modern.send("disable")
            ime.send("commit-text mixed-v1")
            modern.expect("v1-commit first 0 [mixed-v1]\n")
            modern.send("enable")
            modern.expect("v1-leave first\n")
            ime.send("commit-text mixed-v3")
            modern.expect("commit mixed-v3\n")
            assert "[mixed-v3]" not in modern.text() and "commit mixed-v1\n" not in modern.text()
            ipc.focus_window(session.window("rediwm.legacy")["id"])
            ime.send("preedit-text reconnect")
            app.expect("v1-preedit first 99 [reconnect]\n")
            ime.process.terminate()
            ime.process.wait(timeout=5)
            app.expect("v1-preedit first 99 []\n")
            replacement = peer("replacement", "ime")
            replacement.send("method")
            replacement.expect("surround aéx界 3 1\n")
            replacement.send("commit-only")
            app.expect("v1-commit first 99 [final]\n")
            app.send("v1-destroy-target")
            replacement.expect("deactivate\n")

            field = peer("locked", "rediwm.lock-test", "v1")
            field.expect("v1-enter first\n")
            replacement.send("commit-text before-lock")
            field.expect("v1-commit first 0 [before-lock]\n")
            ipc.action("key", {"keycode": 88, "pressed": True})
            wait_for(lambda: locked(ipc), "session lock")
            field.expect("v1-leave first\n")
            field.send("v1-enable")
            replacement.send("commit-text after-lock")
            field.send("sync")
            assert "after-lock" not in field.text() and field.text().count("v1-enter first\n") == 1
        except BaseException:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text(errors="replace")[-2500:])
            raise
        finally:
            session.close()
    print("PASS: text-input-v1 edits, context, focus, popup, reconnect, destruction and lock")


if __name__ == "__main__":
    run()
