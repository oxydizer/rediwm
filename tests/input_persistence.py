#!/usr/bin/env python3
"""Input settings survive a fresh headless compositor and preserve user config."""
import tempfile
import time
import tomllib
from pathlib import Path

from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-input-save-") as directory:
        root = Path(directory)
        config = '# keep this comment\n[input]\ninvert_scroll = false\ntap_drag = false\n'
        expected = None
        for restart in range(2):
            runtime = root / str(restart)
            runtime.mkdir()
            process, log = spawn_compositor(runtime, config_content=config, env_extra={
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/rediwm-test-bus",
                "PULSE_SERVER": "unix:/nonexistent/rediwm-test-audio",
                "REDIWM_THEME": "",
            })
            try:
                with IPCClient(runtime, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    ipc.action('open_control_center')

                    def widgets():
                        return ipc.get_widget_tree("control_center")["widgets"]

                    def click(widget, fraction=.5):
                        box = ipc.get_shell_state()["control_center"]["box"]
                        rect = widget["box"]
                        ipc.move_cursor(round(box["x"] + rect["x"] + rect["width"] * fraction),
                                        round(box["y"] + rect["y"] + rect["height"] / 2))
                        ipc.pointer_button(272, True)
                        ipc.pointer_button(272, False)
                        time.sleep(.15)

                    click(next(w for w in widgets() if w["label"] == "Input"))
                    if restart == 0:
                        click(next(w for w in widgets() if w["role"] == "slider"), .8)
                        for index in range(2):
                            click([w for w in widgets() if w["role"] == "toggle"][index])
                        for index in range(2):
                            click([w for w in widgets() if w["role"] == "stepper"][index], .9)
                        config = (runtime / "rediwm-config.toml").read_text()
                        saved = tomllib.loads(config)["input"]
                        assert saved["pointer_speed"] > 0, saved
                        assert saved["natural_scroll"] is False, saved
                        assert saved["tap_to_click"] is False, saved
                        assert saved["key_repeat_delay"] != 400, saved
                        assert saved["key_repeat_rate"] != 25, saved
                        assert saved["tap_drag"] is False and saved["invert_scroll"] is False
                        assert "# keep this comment" in config
                        # Reopen to compare precisely the same rebuilt widget tree.
                        ipc.action('open_control_center')
                        ipc.action('open_control_center')
                        click(next(w for w in widgets() if w["label"] == "Input"))
                        expected = [(w["role"], w["label"], w["box"]) for w in widgets()]
                    else:
                        assert [(w["role"], w["label"], w["box"]) for w in widgets()] == expected
                        # Toggle and increment restored values to inspect state that
                        # the widget-tree protocol does not expose directly.
                        for index in range(2):
                            click([w for w in widgets() if w["role"] == "toggle"][index])
                        for index in range(2):
                            click([w for w in widgets() if w["role"] == "stepper"][index], .9)
                        restored = tomllib.loads((runtime / "rediwm-config.toml").read_text())["input"]
                        assert restored["natural_scroll"] is True
                        assert restored["tap_to_click"] is True
                        assert restored["key_repeat_delay"] == saved["key_repeat_delay"] + 50
                        assert restored["key_repeat_rate"] == saved["key_repeat_rate"] + 5
            finally:
                stop_process(process)
                log.close()
        print("PASS: Input settings persisted through UI changes and compositor restart")


if __name__ == "__main__":
    run()
