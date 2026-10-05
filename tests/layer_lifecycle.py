#!/usr/bin/env python3
"""Disconnect and recreate real layer clients; no freed layers may remain listed."""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_layer_client(tmp):
    """A minimal real wlr-layer-shell client (tests/layer_client.c)."""
    protocol = ROOT / "protocol/wlr-layer-shell-unstable-v1.xml"
    xdg_dir = subprocess.check_output(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip()
    xdg = Path(xdg_dir) / "stable/xdg-shell/xdg-shell.xml"
    # Layer-shell popups refer to xdg_popup, so its interface must link too.
    for xml, stem in ((protocol, "wlr-layer-shell-unstable-v1"), (xdg, "xdg-shell")):
        subprocess.run(["wayland-scanner", "client-header", str(xml), str(tmp / f"{stem}-client-protocol.h")], check=True)
        subprocess.run(["wayland-scanner", "private-code", str(xml), str(tmp / f"{stem}-protocol.c")], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}", str(ROOT / "tests/layer_client.c"),
                    str(tmp / "wlr-layer-shell-unstable-v1-protocol.c"), str(tmp / "xdg-shell-protocol.c"),
                    "-lwayland-client", "-o", str(tmp / "layer-client")], check=True)
    return tmp / "layer-client"


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-layer-lifecycle-") as directory:
        tmp = Path(directory)
        layer_client = build_layer_client(tmp)
        compositor, log = spawn_compositor(
            tmp, config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*")
                               if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                for _ in range(3):
                    client = subprocess.Popen([str(layer_client)],
                                              env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    wait_for(lambda: ipc.query('get_layer_surfaces')["surfaces"], "layer client did not appear")
                    stop_process(client)
                    client = None
                    wait_for(lambda: not ipc.query('get_layer_surfaces')["surfaces"], "destroyed layer still listed")
                    assert compositor.poll() is None
                print("layer lifecycle: disconnect/recreate leaves no stale layer entries")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if client is not None:
                stop_process(client)
            stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()
