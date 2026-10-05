#!/usr/bin/env python3
"""Startup path: IPC and a first presented frame while catalogue scan /
wallpaper decode are still running, then publication updates an open menu.
Run after zig build.
"""
from pathlib import Path
import json
import re
import socket
import tempfile
import time

from ipc_client import ROOT, IPCClient, spawn_compositor, stop_process

# The cache file is named for its schema; follow the compositor's version.
CATALOG_CACHE = "catalog-v{}.bin".format(re.search(
    r"schema_version: u16 = (\d+);",
    (ROOT / "src/start_menu/catalog_cache.zig").read_text()).group(1))


def stats(client):
    result = client.action('get_performance_stats')
    payload = result.get("PerformanceStats", result)
    return payload.get("startup", payload)


def write_apps(data: Path, count: int = 4):
    apps = data / "applications"
    apps.mkdir(parents=True)
    for index in range(count):
        (apps / f"app-{index:02}.desktop").write_text(
            f"[Desktop Entry]\nType=Application\nName=App {index:02}\n"
            f"Exec=/bin/true\nIcon=foot\n"
        )
    return apps


def test_responsive_before_publication():
    with tempfile.TemporaryDirectory(prefix="rediwm-startup-") as directory:
        tmp = Path(directory)
        data = tmp / "data"
        write_apps(data)
        cache = tmp / "cache"
        cache.mkdir()
        process, log = spawn_compositor(tmp, env_extra={
            "XDG_DATA_HOME": str(data),
            "XDG_DATA_DIRS": str(tmp / "empty"),
            "XDG_CACHE_HOME": str(cache),
            "REDIWM_CATALOG_SCAN_DELAY_MS": "800",
            "REDIWM_WALLPAPER_DECODE_DELAY_MS": "800",
            "REDIWM_DISABLE_CATALOG_CACHE": "1",
        })
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                first = stats(client)
                assert first["first_presented_ns"] > 0, first
                assert first["socket_ready_ns"] > 0, first
                assert first["ipc_ready_ns"] > 0, first
                assert first["catalog_published_ns"] == 0, first
                assert first["wallpaper_presented_ns"] == 0, first
                assert first["catalog_state"] in ("pending", "loading"), first
                assert first["wallpaper_state"] in ("solid", "decoding"), first
                assert first["first_presented_ns"] < 800_000_000, first

                client.open_start_menu()
                client.wait_for("menu_opened", timeout_ms=5000)
                shell = client.get_shell_state()
                menu = shell.get("start_menu") or shell
                # Settings is available while the scan is still running.
                assert (menu.get("result_count") or 0) >= 1, menu

                client.wait_for("catalog_published", timeout_ms=5000)
                client.wait_for("wallpaper_presented", timeout_ms=5000)
                published = stats(client)
                assert published["catalog_state"] == "published", published
                assert published["wallpaper_state"] == "presented", published
                assert published["catalog_entries"] >= 4, published
                assert published["catalog_published_ns"] > first["first_presented_ns"], published

                client.wait_for_frame(timeout_ms=2000)
                after = client.get_shell_state().get("start_menu") or {}
                assert (after.get("result_count") or 0) >= 5, after  # 4 apps + Settings
                print("startup: first presented/IPC before catalogue and wallpaper; open menu refreshed")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()


def test_cache_then_revalidate():
    with tempfile.TemporaryDirectory(prefix="rediwm-startup-cache-") as directory:
        tmp = Path(directory)
        data = tmp / "data"
        write_apps(data, 3)
        cache = tmp / "cache"
        cache.mkdir()
        env = {
            "XDG_DATA_HOME": str(data),
            "XDG_DATA_DIRS": str(tmp / "empty"),
            "XDG_CACHE_HOME": str(cache),
        }
        process, log = spawn_compositor(tmp, env_extra=env)
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                client.wait_for("catalog_published", timeout_ms=5000)
                assert stats(client)["catalog_entries"] >= 3
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()

        cache_files = list(cache.rglob(CATALOG_CACHE))
        assert cache_files, f"cache not written under {cache}"

        env["REDIWM_CATALOG_SCAN_DELAY_MS"] = "600"
        with tempfile.TemporaryDirectory(prefix="rediwm-startup-cache2-") as runtime_dir:
            runtime = Path(runtime_dir)
            process, log = spawn_compositor(runtime, env_extra=env)
            try:
                with IPCClient(socket_path=runtime, timeout=15) as client:
                    first = stats(client)
                    assert first["catalog_state"] == "cache", first
                    assert first["catalog_provisional"] is True, first
                    assert first["catalog_entries"] >= 3, first
                    assert first["catalog_published_ns"] == 0, first
                    client.action('launch_app', {"desktop_id": "app-00.desktop"})
                    client.wait_for("catalog_published", timeout_ms=5000)
                    done = stats(client)
                    assert done["catalog_state"] == "published", done
                    assert done["catalog_provisional"] is False, done
                    print("startup: cache shown provisionally, launch during revalidate, then published")
            except Exception:
                print((runtime / "compositor.log").read_text())
                raise
            finally:
                stop_process(process)
                log.close()


def test_corrupt_cache_falls_back():
    with tempfile.TemporaryDirectory(prefix="rediwm-startup-corrupt-") as directory:
        tmp = Path(directory)
        data = tmp / "data"
        write_apps(data, 2)
        cache_dir = tmp / "cache" / "rediwm"
        cache_dir.mkdir(parents=True)
        (cache_dir / CATALOG_CACHE).write_bytes(b"not a cache")
        process, log = spawn_compositor(tmp, env_extra={
            "XDG_DATA_HOME": str(data),
            "XDG_DATA_DIRS": str(tmp / "empty"),
            "XDG_CACHE_HOME": str(tmp / "cache"),
            "REDIWM_CATALOG_SCAN_DELAY_MS": "200",
        })
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                first = stats(client)
                assert first["catalog_state"] != "cache", first
                client.wait_for("catalog_published", timeout_ms=5000)
                done = stats(client)
                assert done["catalog_entries"] >= 2, done
                print("startup: corrupt cache ignored, scan published")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()


def test_early_shutdown_joins_workers():
    with tempfile.TemporaryDirectory(prefix="rediwm-startup-stop-") as directory:
        tmp = Path(directory)
        data = tmp / "data"
        write_apps(data)
        process, log = spawn_compositor(tmp, env_extra={
            "XDG_DATA_HOME": str(data),
            "XDG_DATA_DIRS": str(tmp / "empty"),
            "XDG_CACHE_HOME": str(tmp / "cache"),
            "REDIWM_CATALOG_SCAN_DELAY_MS": "2000",
            "REDIWM_WALLPAPER_DECODE_DELAY_MS": "2000",
            "REDIWM_DISABLE_CATALOG_CACHE": "1",
        })
        try:
            with IPCClient(socket_path=tmp, timeout=5) as client:
                _ = stats(client)
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        started = time.monotonic()
        stop_process(process)
        log.close()
        elapsed = time.monotonic() - started
        assert elapsed < 1.5, f"shutdown blocked on workers for {elapsed:.2f}s"
        print(f"startup: early shutdown joined workers in {elapsed:.3f}s")


def test_stalled_audio_does_not_block():
    with tempfile.TemporaryDirectory(prefix="rediwm-startup-audio-") as directory:
        tmp = Path(directory)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as pulse:
            pulse.bind(str(tmp / "pulse"))
            pulse.listen(1)
            pulse.settimeout(5)
            process, log = spawn_compositor(tmp, config_content='[compositor]\nxwayland = false\n', env_extra={
                "PULSE_SERVER": "unix:" + str(tmp / "pulse"),
                "PIPEWIRE_RUNTIME_DIR": str(tmp),
                "DBUS_SESSION_BUS_ADDRESS": "unix:" + str(tmp / "missing-bus"),
            })
            try:
                # Accept the connection but never answer its authentication.
                # Keep it open during shutdown too: joining PA must not wait
                # for this deliberately unresponsive sound server.
                connection, _ = pulse.accept()
                with connection, IPCClient(socket_path=tmp, timeout=2) as client:
                    first = stats(client)
                    assert first["first_presented_ns"] > 0, first
                    client.click_at(100, 100)
                    assert stats(client)["first_input_ns"] > 0
                    started = time.monotonic()
                    stop_process(process)
                    elapsed = time.monotonic() - started
                    assert process.returncode == 0, process.returncode
                    assert elapsed < 1.5, f"shutdown waited for audio for {elapsed:.2f}s"
                    print(f"startup: desktop/input responsive with stalled audio; shutdown {elapsed:.3f}s")
            except Exception:
                print((tmp / "compositor.log").read_text())
                raise
            finally:
                if process.poll() is None:
                    stop_process(process)
                log.close()


if __name__ == "__main__":
    test_responsive_before_publication()
    test_cache_then_revalidate()
    test_corrupt_cache_falls_back()
    test_early_shutdown_joins_workers()
    test_stalled_audio_does_not_block()
