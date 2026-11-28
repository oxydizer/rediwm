#!/usr/bin/env python3
"""Hot-unplug a headless output while a real client remains connected."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-output-destroy-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server"],
            text=True))
        hook = tmp / "unplug.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "tests/output_destroy_hook.c"), "-o", str(hook),
                        *flags, "-ldl"], check=True)
        trigger = tmp / "unplug"
        reconnect = tmp / "replug"
        workspace_mode = os.getenv("REDIWM_TEST_WORKSPACES") == "1"
        config = '[compositor]\nxwayland = false\n' + ('desktop_mode = "tiling"\n[keybinds.workspace]\n' if workspace_mode else '[keybinds]\n') + '"F12" = "quit"\n'
        compositor, log = spawn_compositor(
            tmp, outputs="2", config_content=config,
            env_extra={"LD_PRELOAD": str(hook), "REDIWM_TEST_UNPLUG": str(trigger),
                       **({"REDIWM_TEST_REPLUG": str(reconnect)} if workspace_mode else {}),
                       "XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        hidden_client = None
        try:
            with IPCClient(tmp) as ipc:
                def window(id):
                    return next(w for w in ipc.get_windows() if w["id"] == id)

                def tiled_on(id, name):
                    out = next(o for o in ipc.get_outputs() if o["name"] == name)
                    box = ipc.get_window_debug(id)["chrome_box"]
                    return window(id)["placement"] == "automatic" and (
                        box["x"], box["y"], box["width"], box["height"]) == (
                        out["x"], out["y"], out["logical_width"], out["logical_height"] - out["bottom_exclusion"])

                wait_for(lambda: len(ipc.get_outputs()) == 2, "two outputs missing")
                display = next(p.name for p in tmp.glob("wayland-*")
                               if not p.name.endswith(".lock"))
                target = ipc.get_outputs()[0]
                ipc.move_cursor(20, 20, output=target["name"])
                client = subprocess.Popen([str(tmp / "client")], env=dict(
                    os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wait_for(lambda: ipc.get_windows(), "client did not map")
                # The first-created scene output is the hook's unplug target.
                target = ipc.get_outputs()[0]
                ipc.move_cursor(20, 20, output=target["name"])
                if not workspace_mode:
                    ipc.action('set_camera', {"x": 0, "y": 0})
                    px = target["logical_width"] - 40
                    py = target["logical_height"] - target["bottom_exclusion"] - 40
                    wait_for(lambda: ipc.hit_test(px, py, output=target["name"])["target_type"] == "mini_map", "mini map missing")
                    ipc.move_cursor(px, py, output=target["name"])
                    ipc.pointer_button(272, True)
                if workspace_mode:
                    top = ipc.get_windows()[0]
                    membership = top["workspace_id"]
                    hidden_client = subprocess.Popen([str(tmp / "client"), "--app-id", "unplug-hidden"], env=dict(
                        os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    hidden = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "unplug-hidden"), None), "hidden member maps")
                    ipc.action("move_to_workspace", {"id": hidden["id"], "workspace": 7})
                    ipc.focus_window(top["id"])
                    box = ipc.get_window_debug(top["id"])["client_box"]
                    out = next(o for o in ipc.get_outputs() if o["x"] <= box["x"] < o["x"] + o["logical_width"])
                    ipc.move_cursor(box["x"] - out["x"] + 50, box["y"] - out["y"] + 50, output=out["name"])
                    ipc.key(125, True)
                    ipc.pointer_button(272, True)
                    assert ipc.get_input_state()["cursor_mode"] == "move"
                trigger.touch()
                wait_for(lambda: len(ipc.get_outputs()) == 1, "output did not unplug")
                ipc.pointer_button(272, False)
                if workspace_mode: ipc.key(125, False)
                assert ipc.get_input_state()["cursor_mode"] == "passthrough"
                assert compositor.poll() is None
                assert client.poll() is None
                assert ipc.get_windows(), "client disappeared on hot-unplug"
                if workspace_mode:
                    top = next(w for w in ipc.get_windows() if w["app_id"] != "unplug-hidden")
                    assert top["workspace_id"] == membership, "unplug changed workspace membership"
                    assert window(hidden["id"])["workspace_id"] == 7
                    ipc.focus_window(top["id"])
                    assert ipc.get_focused_window()["id"] == top["id"]
                    assert next(w["id"] for w in ipc.get_workspaces() if w["is_focused"]) == top["workspace_id"]
                    surviving = ipc.get_outputs()[0]["name"]
                    wait_for(lambda: tiled_on(top["id"], surviving), "migrated member retiles")
                    reconnect.touch()
                    wait_for(lambda: len(ipc.get_outputs()) == 2, "output did not reconnect")
                    assert window(top["id"])["workspace_id"] == membership
                    slot = next(w for w in ipc.get_workspaces() if w["id"] == membership)
                    assert slot["output"] == surviving and slot["is_visible"], "reconnect moved an owned workspace"
                    hidden_slot = next(w for w in ipc.get_workspaces() if w["id"] == 7)
                    assert hidden_slot["output"] == surviving and not hidden_slot["is_visible"], "reconnect merged hidden membership"
                    wait_for(lambda: tiled_on(top["id"], surviving) and tiled_on(hidden["id"], surviving), "reconnect keeps both layouts on their owner")
                    ipc.focus_window(hidden["id"])
                    assert next(w for w in ipc.get_workspaces() if w["is_focused"])["id"] == 7
                    ipc.focus_window(top["id"])
                    added = next(o for o in ipc.get_outputs() if o["name"] != surviving)
                    assert added["name"] == target["name"], "reconnect lost connector identity"
                    ipc.move_cursor(200, 200, output=added["name"])
                    empty = next(w for w in ipc.get_workspaces() if w["is_focused"])
                    assert empty["id"] != membership and empty["output"] == added["name"]
                    ipc.action("switch_workspace", {"workspace": empty["id"]})
                    assert ipc.get_focused_window() is None, "new output stole the migrated member"
                    ipc.action("move_to_workspace", {"id": top["id"], "workspace": empty["id"]})
                    wait_for(lambda: tiled_on(top["id"], added["name"]), "retile after transfer to reconnected output")
                    ipc.focus_window(top["id"])
                    assert window(top["id"])["workspace_id"] == empty["id"]
                    ipc.action("undo")
                    wait_for(lambda: window(top["id"])["workspace_id"] == membership and tiled_on(top["id"], surviving), "undo transfer after reconnect")
                    print("PASS: output reconnect keeps migrated ownership, assigns an empty workspace and accepts reversible transfers")
                ipc.wait_for_frame(output=ipc.get_outputs()[0]["name"])
                # Quit can close IPC before its buffered reply is flushed.
                ipc.sock.sendall(b'{"version":1,"command":"key","params":{"keycode":88,"pressed":true}}\n')
                assert compositor.wait(timeout=5) == 0, "orderly shutdown failed"
                print("output destruction: scene detached before node cleanup; client and IPC survive")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if client is not None:
                stop_process(client)
            if hidden_client is not None:
                stop_process(hidden_client)
            stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()
