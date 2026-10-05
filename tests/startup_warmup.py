#!/usr/bin/env python3
"""Check bounded startup icon preparation before the launcher is opened."""
from pathlib import Path
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-warmup-test-") as directory:
        tmp = Path(directory)
        data = tmp / "data"
        apps = data / "applications"
        apps.mkdir(parents=True)
        for index in range(12):
            icon = data / f"app-{index:02}.svg"
            icon.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="38" '
                            'height="38"><rect width="38" height="38" fill="red"/></svg>')
            (apps / f"app-{index:02}.desktop").write_text(
                f"[Desktop Entry]\nType=Application\nName=App {index:02}\n"
                f"Exec=/bin/true\nIcon={icon}\n")
        process, log = spawn_compositor(tmp, scale=scale, outputs="2", env_extra={
            "XDG_DATA_HOME": str(data), "XDG_DATA_DIRS": str(tmp / "empty"),
        })
        try:
            with IPCClient(socket_path=tmp) as client:
                client.wait_for("catalog_published", timeout_ms=5000)

                def stats():
                    result = client.action('get_performance_stats')
                    return result.get("PerformanceStats", result)

                deadline = time.monotonic() + 5
                # The taskbar also requests its one shared 42px start logo.
                while stats()["icon_decode_count"] < 9:
                    assert time.monotonic() < deadline, "startup icons did not finish"
                    time.sleep(.01)
                # Allow later frames/timer steps: two outputs must not launch
                # another warmup, nor should startup decode the remaining apps.
                time.sleep(.1)
                before = stats()
                assert before["icon_decode_count"] == 9, before
                size = round(38 * float(scale))
                logo_size = round(42 * float(scale))
                assert before["icon_decoded_bytes"] == (8 * size * size + logo_size * logo_size) * 4, before
                started = time.monotonic()
                client.open_start_menu()
                client.wait_for("menu_opened", timeout_ms=5000)
                elapsed = time.monotonic() - started
                assert stats()["icon_cache_hits"] > before["icon_cache_hits"]
                print(f"Startup warmup at {scale}x: eight icons prepared; "
                      f"first menu open {elapsed:.3f}s (includes animation)")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    for scale in ("1", "1.5"):
        run(scale)
