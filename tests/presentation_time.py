#!/usr/bin/env python3
"""Exercise stable presentation-time feedback on isolated headless outputs."""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in (
        ("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
        ("presentation-time", "stable/presentation-time/presentation-time.xml"),
    ):
        for mode, suffix in (("client-header", "client-protocol.h"),
                             ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(protocols / path),
                            str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/presentation_time_client.c"), *sources,
                    "-lwayland-client", "-o", str(tmp / "client")], check=True)


def parse_presented(line):
    fields = line.split()
    assert len(fields) == 8 and fields[0] == "presented", line
    return {
        "label": fields[1], "sec": int(fields[2]), "nsec": int(fields[3]),
        "refresh": int(fields[4]), "seq": int(fields[5]),
        "flags": int(fields[6]), "output": fields[7],
    }


def run_case(binary, version, scale, full):
    with tempfile.TemporaryDirectory(prefix="rediwm-presentation-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale=str(scale), outputs="2" if full else "1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"),
                       "WLR_RENDERER_ALLOW_SOFTWARE": "1",
                       "WLR_RENDERER": os.environ.get("REDIWM_TEST_RENDERER", "pixman")})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None),
                                   "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*")
                           if not p.name.endswith(".lock"))
            with client_log.open("w") as output:
                client = subprocess.Popen([str(binary), str(version)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True,
                                          env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp),
                                                   WAYLAND_DISPLAY=display))

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                    if w["app_id"] == "rediwm.presentation-fixture"), None),
                    "presentation fixture did not map")
                layout = wait_for(lambda: ipc.get_outputs()
                    if len(ipc.get_outputs()) == (2 if full else 1) else None,
                    "output layout did not settle")
                ordered_outputs = sorted(layout, key=lambda output: output["x"])
                first_output = ordered_outputs[0]["name"]
                second_output = ordered_outputs[-1]["name"]
                wait_for(lambda: "ready\n" in client_log.read_text(),
                         "initial presentation feedback missing")
                output_count = 2 if full else 1
                text = client_log.read_text()
                assert "global 2 clock " in text and f"outputs {output_count}\n" in text
                initial = parse_presented(next(line for line in text.splitlines()
                                               if line.startswith("presented initial ")))
                assert initial["output"] in {output["name"] for output in layout}, initial

                done_count = 0

                def command(value):
                    nonlocal done_count
                    start = len(client_log.read_text().splitlines())
                    client.stdin.write(value + "\n")
                    client.stdin.flush()
                    done_count += 1
                    wait_for(lambda: client_log.read_text().splitlines().count("done") >= done_count,
                             f"client did not finish {value!r}")
                    return client_log.read_text().splitlines()[start:]

                ipc.action("move_window_to", {"id": win["id"], "x": 100, "y": 100})
                normal = parse_presented(next(line for line in command("present")
                                              if line.startswith("presented ")))
                assert normal["output"] == first_output, (normal, layout)

                if full:
                    ipc.set_zoom(win["id"], 70)
                    projected = parse_presented(next(line for line in command("present")
                                                   if line.startswith("presented ")))
                    assert projected["output"] == first_output, projected
                    ipc.action("set_zoom", {"percent": 70})
                    ipc.action("set_camera", {"x": 80, "y": 40})
                    camera = parse_presented(next(line for line in command("present")
                                                if line.startswith("presented ")))
                    assert camera["output"] == first_output, camera
                    ipc.action("reset_camera")
                    ipc.set_zoom(win["id"], 100)

                    ipc.action("move_window_to", {"id": win["id"], "x": 1400, "y": 100})
                    second = parse_presented(next(line for line in command("present")
                                                if line.startswith("presented ")))
                    assert second["output"] == second_output, (second, layout)

                    same = [parse_presented(line) for line in command("same")
                            if line.startswith("presented ")]
                    assert {item["label"] for item in same} == {"same-a", "same-b"}, same
                    comparable = ("sec", "nsec", "refresh", "seq", "flags", "output")
                    assert all(same[0][key] == same[1][key] for key in comparable), same

                    superseded = command("supersede")
                    assert "discarded stale" in superseded, superseded
                    fresh = parse_presented(next(line for line in superseded
                                                if line.startswith("presented fresh ")))
                    assert fresh["output"] == second_output, fresh

                manager = parse_presented(next(line for line in command("manager")
                                               if line.startswith("presented manager ")))
                assert manager["output"] == (second_output if full else first_output), manager

                # Keep an uncommitted feedback, its surface and the remaining
                # protocol resources alive while the display shuts down.
                client.stdin.write("live\n")
                client.stdin.flush()
                done_count += 1
                wait_for(lambda: client_log.read_text().splitlines().count("done") >= done_count,
                         "live client did not settle")
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            client.wait(timeout=5)
            assert client.returncode == 0, client_log.read_text()
            scope = "full feedback/projection/output" if full else "compatibility"
            print(f"presentation-time: v{version} {scope} passed ({scale:g}x)")
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if client_log.exists():
                print(client_log.read_text())
            raise
        finally:
            if client and client.poll() is None:
                stop_process(client)
            if client and client.stdin:
                client.stdin.close()
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def run():
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    with tempfile.TemporaryDirectory(prefix="rediwm-presentation-build-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        run_case(tmp / "client", 1, scale, False)
        run_case(tmp / "client", 2, scale, True)


if __name__ == "__main__":
    run()
