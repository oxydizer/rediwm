#!/usr/bin/env python3
"""Desktop selection follows theme accents, overrides and reloads during a drag."""
import math
import os
from pathlib import Path
import tempfile

from PIL import Image

from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-desktop-selection-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        desktop = home / "Desktop"
        desktop.mkdir(parents=True)
        wallpaper = tmp / "black.png"
        Image.new("RGB", (8, 8)).save(wallpaper)
        env = dict(HOME=str(home), XDG_CONFIG_HOME=str(tmp / "config"),
                   XDG_DATA_HOME=str(tmp / "data"), XDG_CACHE_HOME=str(tmp / "cache"),
                   XDG_STATE_HOME=str(tmp / "state"), DBUS_SESSION_BUS_ADDRESS="",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent",
                   REDIWM_DESKTOP_DIR=str(desktop), REDIWM_DESKTOP_BUILTINS="0")

        def config(pack, overrides=""):
            return (f'[compositor]\nxwayland = false\nwallpaper = "{wallpaper}"\n'
                    '[desktop]\nenabled = true\n[animations]\nenabled = false\n'
                    f'[theme]\nbase = "{pack}"\n{overrides}')

        process, log = spawn_compositor(tmp, scale=str(scale),
                                        config_content=config("blackout"), env_extra=env)
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                ipc.wait_for("wallpaper_presented")
                ipc.move_cursor(300, 200)
                ipc.pointer_button(272, True)
                ipc.move_cursor(600, 400)
                cases = (
                    ("blackout", (251, 227, 1), .15, (251, 227, 1), ""),
                    ("redi-blue", (0, 209, 255), .15, (0, 209, 255), ""),
                    # Existing explicit desktop colours still take precedence.
                    ("rediwm-light", (14, 165, 160), .15, (14, 165, 160), ""),
                    ("gold", (218, 169, 110), .18, (220, 172, 115), ""),
                    ("blackout", (20, 180, 80), .25, (20, 180, 80),
                     'desktop_selection = "rgba(20,180,80,0.25)"\n'
                     'desktop_selection_border = "#14B450"\n'),
                    ("blackout", (0, 0, 0), 0, (20, 180, 80),
                     'desktop_selection = "#00000000"\n'
                     'desktop_selection_border = "#14B450"\n'),
                    ("blackout", (251, 227, 1), .15, (251, 227, 1), ""),
                )
                for index, (pack, fill, alpha, border, overrides) in enumerate(cases):
                    # Keep the button down: a reload must repaint the unchanged
                    # interior as well as its edges, without another motion.
                    (tmp / "rediwm-config.toml").write_text(config(pack, overrides))
                    ipc.reload_config()
                    ipc.wait_for_frame()
                    path = tmp / f"selection-{index}.png"
                    ipc.screenshot(str(path))
                    image = Image.open(path).convert("RGB")
                    assert image.getpixel((round(250 * scale), round(300 * scale))) == (0, 0, 0)
                    pixel = image.getpixel((round(450 * scale), round(300 * scale)))
                    expected = tuple(round(channel * alpha) for channel in fill)
                    assert max(abs(a - b) for a, b in zip(pixel, expected)) <= 2, (pack, pixel, expected)
                    # Cairo's 1px outline straddles pixels at these scales.
                    # Its brightest sample must be the border hue at >=40%
                    # coverage; red inherited from another theme cannot pass.
                    edge = max((image.getpixel((round(450 * scale), y))
                                for y in range(math.floor(200 * scale) - 2,
                                               math.ceil(200 * scale) + 3)), key=sum)
                    coverage = sum(a * b for a, b in zip(edge, border)) / sum(b * b for b in border)
                    assert .4 <= coverage <= 1.01, (pack, edge, border, coverage)
                    assert max(abs(a - b * coverage) for a, b in zip(edge, border)) <= 3, (pack, edge, border)
                    image.save(f"/tmp/desktop-selection-{pack}-{scale}.png")
                ipc.pointer_button(272, False)
            print(f"PASS: desktop selection accents, explicit colours and live drag reload (scale={scale})")
        except Exception:
            print((tmp / "compositor.log").read_text()[-4000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run(1)
    run(1.5)
