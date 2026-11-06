#!/usr/bin/env python3
"""Language reloads, desktop-entry names and pseudo-locale widget bounds."""
import json
import os
from pathlib import Path
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def isolated_environment(tmp):
    """Keep catalogs, launch history, app settings and services off the host."""
    result = {"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_FILES_DEVICES": "0"}
    for name, key in (("home", "HOME"), ("data", "XDG_DATA_HOME"),
                      ("config", "XDG_CONFIG_HOME"), ("cache", "XDG_CACHE_HOME"),
                      ("state", "XDG_STATE_HOME")):
        (tmp / name).mkdir(exist_ok=True)
        result[key] = str(tmp / name)
    result["XDG_DATA_DIRS"] = str(tmp / "data")
    result["XDG_CONFIG_DIRS"] = str(tmp / "config")
    return result


def overflow_issues(widgets):
    """Return labelled, visible widgets whose measured text exceeds their box."""
    issues = []
    for widget in widgets:
        if not widget.get("label") or not widget.get("visible"):
            continue
        width = widget.get("text_width")
        box_width = widget.get("box", {}).get("width", 0)
        # Synthetic hit targets carry accessibility labels rather than painted
        # text. Their width is null; measured retained labels are the gate.
        if width is not None and width > box_width + 0.5:
            issues.append({"path": widget.get("path"), "name": widget.get("name"),
                           "label": widget["label"], "text_width": width,
                           "box_width": box_width, "clipped": widget.get("clipped", False),
                           "reason": "text exceeds widget"})
    return issues


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-i18n-") as directory:
        tmp = Path(directory)
        env = isolated_environment(tmp)
        # Explicit region language must win over every inherited locale hint.
        env.update(LANG="de_DE.UTF-8", LC_MESSAGES="fr_FR.UTF-8", LC_ALL="C", LANGUAGE="es")
        applications = tmp / "data/applications"
        applications.mkdir()
        (applications / "rediwm-i18n-fixture.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Language fixture\n"
            "Name[de]=Prüfprogramm\nName[pt_BR]=Aplicativo de teste\n"
            "Exec=/usr/bin/true\nIcon=application-x-executable\n", encoding="utf-8")

        def config(language):
            return ('[compositor]\nxwayland = false\n[animations]\nenabled = false\n'
                    '[polkit]\nenable = false\n[region]\n'
                    f'language = {json.dumps(language)}\nformats = "C"\n')

        process, log = spawn_compositor(tmp, config_content=config("C"), env_extra=env)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for("catalog_published", timeout_ms=10000)
                ui = UIDriver(ipc)

                def labels(panel):
                    return [w["label"] for w in ui.widgets(panel) if w.get("label")]

                def reload(language):
                    (tmp / "rediwm-config.toml").write_text(config(language))
                    ipc.reload_config()
                    ipc.wait_for_frame()

                def application_name(expected):
                    ipc.action("open_start_menu")
                    deadline = time.monotonic() + 10
                    while expected not in labels("start_menu"):
                        if time.monotonic() >= deadline:
                            raise AssertionError((expected, labels("start_menu")))
                        ipc.wait_for_frame()
                        time.sleep(.05)
                    ui.wait_settled("start_menu")
                    ipc.key_down_up(1)
                    ui.wait_absent("start_menu")

                application_name("Language fixture")
                reload("de_DE.UTF-8")
                application_name("Prüfprogramm")
                reload("pt_BR.UTF-8")
                application_name("Aplicativo de teste")
                reload("C")
                application_name("Language fixture")

                ipc.action("open_power_menu")
                ui.wait_settled("power_menu")
                assert "Lock" in labels("power_menu")
                english_paths = {w["name"]: w["path"] for w in ui.widgets("power_menu") if w.get("name")}
                reload("qps")
                ui.wait_settled("power_menu")
                pseudo = ui.widgets("power_menu")
                assert any(w.get("text_width", 0) for w in pseudo), "widget text measurements unavailable"
                assert "Lock" not in labels("power_menu"), "open menu kept the old language"
                assert english_paths == {w["name"]: w["path"] for w in pseudo if w.get("name")}, "language changed stable widget names"
                issues = overflow_issues(pseudo)
                assert not issues, json.dumps(issues, ensure_ascii=False, indent=2)
                reload("C")
                ui.wait_settled("power_menu")
                assert "Lock" in labels("power_menu"), "English did not return after pseudo-locale"
                ipc.key_down_up(1)
                ui.wait_absent("power_menu")

                ipc.action("open_control_center")
                ui.wait_settled("control_center")
                settings = next(w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings")
                assert settings["title"] == "RediWM Settings"
                reload("qps")
                ui.wait_settled("control_center")
                updated = next(w for w in ipc.get_windows() if w["id"] == settings["id"])
                assert updated["title"] != settings["title"], "shell title kept the old language"
                assert ui.find("settings_search", panel="control_center")["label"] != "Search settings…", "retained field kept the old placeholder"
                reload("C")
                ui.wait_settled("control_center")
                updated = next(w for w in ipc.get_windows() if w["id"] == settings["id"])
                assert updated["title"] == "RediWM Settings"
                ipc.close_window(settings["id"])
                ui.wait_absent("control_center")
            print("PASS: explicit language precedence, desktop-name/cache reloads, live shell titles/placeholders, qps labels and measured bounds")
        except Exception:
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()
