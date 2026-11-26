#!/usr/bin/env python3
"""The Transfers taskbar item and panel against a fake Files endpoint.

The fake binds the socket Files would (`files-io-<wyhash(display)>.sock` in
the runtime directory), answers Subscribe with a snapshot of jobs in every
state the panel draws, and records the panel's requests. Nothing of the
host's is used. Screenshots go to /tmp/rediwm-transfers-*.png.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time

from PIL import Image
from ipc_client import IPCClient, spawn_compositor, stop_process

M = (1 << 64) - 1
SECRET = [0xa0761d6478bd642f, 0xe7037ed1a0b428db, 0x8ebc6af09c88c6e3, 0x589965cc75374cc3]


def _mum(a, b):
    x = a * b
    return x & M, (x >> 64) & M


def _mix(a, b):
    a, b = _mum(a, b)
    return a ^ b


def wyhash(data, seed=0):
    """Zig's std.hash.Wyhash, which names the Files endpoint's socket."""
    r4 = lambda i: int.from_bytes(data[i:i + 4], "little")
    r8 = lambda d, i: int.from_bytes(d[i:i + 8], "little")
    s0 = seed ^ _mix(seed ^ SECRET[0], SECRET[1])
    state = [s0, s0, s0]
    n = len(data)
    if n <= 16:
        if n >= 4:
            end, quarter = n - 4, (n >> 3) << 2
            a, b = (r4(0) << 32) | r4(quarter), (r4(end) << 32) | r4(end - quarter)
        elif n > 0:
            a, b = (data[0] << 16) | (data[n >> 1] << 8) | data[n - 1], 0
        else:
            a = b = 0
    else:
        i = 0
        if n >= 48:
            while i + 48 < n:
                for k in range(3):
                    state[k] = _mix(r8(data, i + 16 * k) ^ SECRET[k + 1], r8(data, i + 16 * k + 8) ^ state[k])
                i += 48
            state[0] ^= state[1] ^ state[2]
        rest, j = data[i:], 0
        while j + 16 < len(rest):
            state[0] = _mix(r8(rest, j) ^ SECRET[1], r8(rest, j + 8) ^ state[0])
            j += 16
        a, b = r8(data, n - 16), r8(data, n - 8)
    a, b = _mum(a ^ SECRET[1], b ^ state[0])
    return _mix(a ^ SECRET[0] ^ n, b ^ SECRET[1])


assert format(wyhash(b"wayland-1"), "x") == "fe2e549a325d1f1a"

MB = 1024 * 1024
# Files' download job ids (`io_service.torrent_job_base`).
TORRENT = 1 << 48


def job(job_id, **fields):
    value = {
        "id": job_id, "kind": "copy", "state": "running", "label": f"file-{job_id}.bin", "source_count": 1,
        "completed_bytes": 0, "total_bytes": 0, "rate_bytes_per_second": 0, "completed_items": 0, "total_items": 0,
        "started_at_ms": 0, "finished_at_ms": 0, "cancel_requested": False, "conflict": False, "waiting_for": "",
        "destination": "", "error_code": 0, "removed": False, "revision": job_id,
    }
    value.update(fields)
    return value


def snapshot_jobs(home):
    wave = [int((30 + 12 * ((i * 7) % 5) + (i % 3) * 4) * MB) for i in range(80)]
    return [
        job(1, label="archlinux-2026.11.01-x86_64.iso", completed_bytes=862 * MB, total_bytes=1229 * MB,
            rate_bytes_per_second=18 * MB, destination=f"{home}/Downloads/ISOs", rate_history=wave),
        job(2, label="Holiday photos", source_count=214, kind="move", state="paused", completed_bytes=1536 * MB,
            total_bytes=3686 * MB, destination=f"{home}/Pictures", rate_history=[9 * MB] * 30 + [0] * 20),
        job(3, label="report-final.pdf", state="queued", conflict=True, completed_bytes=0, total_bytes=4 * MB,
            destination=f"{home}/Documents"),
        job(4, label="backup.tar.zst", kind="extract", completed_bytes=40 * MB, total_bytes=900 * MB,
            waiting_for="USB Drive", destination="/run/media/u/USB Drive"),
        job(5, label="old-builds", kind="delete", completed_items=180, total_items=600, rate_history=[0] * 10),
        job(TORRENT + 1, kind="download", state="seeding", label="archlinux-2026.10.01-x86_64.iso", completed_bytes=1229 * MB,
            total_bytes=1229 * MB, rate_bytes_per_second=3 * MB, upload_rate_bytes_per_second=3 * MB,
            uploaded_bytes=418 * MB, ratio_limit=1, destination=f"{home}/Downloads/ISOs"),
        job(TORRENT + 2, kind="download", state="queued", label="Debian DVD set", choose_files=True,
            destination=f"{home}/Downloads"),
    ]


class FakeFiles:
    """One Files endpoint: a listening socket and the panel's connection."""

    def __init__(self, path, jobs):
        self.path = str(path)
        self.jobs = jobs
        self.requests = []
        self.conn = None
        self.sequence = 1
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            self.conn = conn
            buffered = b""
            while True:
                try:
                    data = conn.recv(65536)
                except OSError:
                    break
                if not data:
                    break
                buffered += data
                while b"\n" in buffered:
                    line, buffered = buffered.split(b"\n", 1)
                    request = json.loads(line)
                    with self.lock:
                        self.requests.append(request)
                    self.send({"version": 1, "id": request["id"], "result": {}})
                    if request["command"] == "Subscribe":
                        self.send({"version": 1, "event": "snapshot", "sequence": self.sequence, "jobs": self.jobs})

    def send(self, value):
        self.conn.sendall((json.dumps(value) + "\n").encode())

    def change(self, jobs):
        self.sequence += 1
        self.send({"version": 1, "event": "jobs", "sequence": self.sequence, "jobs": jobs})

    def commands(self):
        with self.lock:
            return [(r["command"], r.get("params", {})) for r in self.requests]

    def close(self):
        # The serving thread is blocked in recv on this socket: a bare close
        # would leave the connection up. Shut it down so the panel sees Files go.
        for sock in (self.conn, self.server):
            if sock:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                sock.close()
        os.unlink(self.path)


def wait_for(predicate, what, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


def run(scale, theme=None):
    with tempfile.TemporaryDirectory(prefix="rediwm-transfers-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        home.mkdir()
        config = "[compositor]\nxwayland = false\n" + (f'[theme]\nbase = "{theme}"\n' if theme else "")
        process, log = spawn_compositor(tmp, scale=scale, config_content=config, env_extra={"HOME": str(home), "XDG_CACHE_HOME": str(tmp / "cache")})
        fake = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = wait_for(lambda: next((p.name for p in tmp.iterdir() if p.name.startswith("wayland-") and not p.name.endswith(".lock")), None), "the Wayland socket")

                def items():
                    bar = ipc.get_shell_state()["taskbars"][0]
                    return bar, {item["name"]: item for item in bar["right_items"]}

                _, before = items()
                assert not before["transfers"]["visible"], "Transfers shows with nothing to show"
                fake = FakeFiles(tmp / f"files-io-{wyhash(display.encode()):x}.sock", snapshot_jobs(home))
                wait_for(lambda: items()[1]["transfers"]["visible"], "the Transfers item")
                wait_for(lambda: ("Subscribe", {}) in fake.commands(), "Subscribe")
                bar, found = items()
                box = found["transfers"]["box"]
                icon = box["x"] + box["width"] // 2, box["y"] + box["height"] // 2
                assert ipc.hit_test(*icon)["widget"] == "tray", ipc.hit_test(*icon)
                suffix = f"{scale}{'-' + theme if theme else ''}"

                def capture(name):
                    ipc.wait_for_frame()
                    path = Path(f"/tmp/rediwm-transfers-{name}-{suffix}.png")
                    path.unlink(missing_ok=True)  # The screenshot action never overwrites.
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").copy()

                shot = capture("icon")
                pixels = shot.width / ipc.get_outputs()[0]["logical_width"]
                crop = tuple(round(v * pixels) for v in (box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"]))
                shot.crop(crop).resize(((crop[2] - crop[0]) * 4, (crop[3] - crop[1]) * 4), Image.NEAREST).save(f"/tmp/rediwm-transfers-icon-zoom-{suffix}.png")

                ipc.click_at(*icon)
                time.sleep(0.35)
                point = icon[0], bar["box"]["y"] - 40
                hit = wait_for(lambda: (lambda h: h if h["target_type"] == "transfers_popup" else None)(ipc.hit_test(*point)), "the panel")
                capture("panel")

                def find(widget):
                    """The first point (scanning the panel, scrolling down a
                    screenful at a time) whose hit is `widget`."""
                    origin_x, origin_y = point[0] - hit["local_x"], point[1] - hit["local_y"]
                    top = max(int(origin_y), 0)
                    for _ in range(6):
                        for y in range(top, int(point[1]), 4):
                            for x in range(int(origin_x), int(origin_x + 400), 6):
                                if ipc.hit_test(x, y).get("widget") == widget:
                                    return x, y
                        ipc.move_cursor(*point)
                        ipc.scroll(0, -300)  # natural scrolling: negative pages down
                        ipc.wait_for_frame()
                    raise AssertionError(f"no {widget} in the panel")

                pause = find("pause")
                ipc.click_at(*pause)
                wait_for(lambda: any(c == "PauseJob" for c, _ in fake.commands()), "PauseJob")
                cancel = find("cancel")
                ipc.click_at(*cancel)
                capture("cancel-armed")
                assert not any(c == "CancelJob" for c, _ in fake.commands()), "one press cancelled"
                ipc.click_at(*cancel)
                wait_for(lambda: any(c == "CancelJob" for c, _ in fake.commands()), "CancelJob")
                resolve = find("resolve")
                ipc.click_at(*resolve)
                opened = wait_for(lambda: [p for c, p in fake.commands() if c == "OpenWindow"], "OpenWindow")
                assert opened[0]["job_id"] == 3 and opened[0]["path"] == f"{home}/Documents", opened
                assert opened[0].get("activation_token"), opened
                wait_for(lambda: ipc.hit_test(*point)["target_type"] != "transfers_popup", "the panel to close")

                # Downloads: stop seeding, and choose a download's files in Files.
                ipc.click_at(*icon)
                time.sleep(0.35)
                hit = wait_for(lambda: (lambda h: h if h["target_type"] == "transfers_popup" else None)(ipc.hit_test(*point)), "the panel for downloads")
                ipc.click_at(*find("stop_seeding"))
                wait_for(lambda: ("PauseJob", {"job_id": TORRENT + 1}) in fake.commands(), "PauseJob for the seeding download")
                ipc.click_at(*find("choose"))
                chosen = wait_for(lambda: [p for c, p in fake.commands() if c == "OpenWindow" and p.get("job_id") == TORRENT + 2], "OpenWindow for the download")
                assert chosen[0]["transfers"] and chosen[0]["path"] == f"{home}/Downloads", chosen
                wait_for(lambda: ipc.hit_test(*point)["target_type"] != "transfers_popup", "the panel to close again")

                # Jobs finish and retire: done rows, a cleared icon.
                fake.change([job(1, state="completed", completed_bytes=1229 * MB, total_bytes=1229 * MB, destination=f"{home}/Downloads/ISOs", label="archlinux-2026.11.01-x86_64.iso", removed=True),
                             job(5, kind="delete", state="failed", label="old-builds", removed=True)])
                ipc.click_at(*icon)
                time.sleep(0.35)
                hit = wait_for(lambda: (lambda h: h if h["target_type"] == "transfers_popup" else None)(ipc.hit_test(*point)), "the panel again")
                capture("finished")
                # Files leaves: live jobs go, finished ones stay until cleared.
                fake.close()
                fake = None
                wait_for(lambda: items()[1]["transfers"]["visible"], "finished jobs to keep the item")
                time.sleep(0.3)
                capture("disconnected")
                hit = wait_for(lambda: (lambda h: h if h["target_type"] == "transfers_popup" else None)(ipc.hit_test(*point)), "the panel after Files left")
                clear = find("clear_done")
                ipc.click_at(*clear)
                wait_for(lambda: not items()[1]["transfers"]["visible"], "the item to hide once cleared")
        finally:
            if fake:
                fake.close()
            stop_process(process)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default=os.environ.get("REDIWM_TEST_SCALE", "1"))
    parser.add_argument("--theme")
    args = parser.parse_args()
    run(args.scale, args.theme)
    print("transfers panel: ok")
