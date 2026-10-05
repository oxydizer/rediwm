#!/usr/bin/env python3
"""Output balance through Settings and private PipeWire sinks; no host audio."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from hardware_keys import private_audio, wait
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-balance-") as directory:
        tmp = Path(directory)
        with private_audio(tmp) as (audio_env, pactl):
            pactl("load-module", "module-null-sink", "sink_name=balance_mono", "channels=1", "channel_map=mono")
            pactl("load-module", "module-null-sink", "sink_name=balance_reversed", "channels=2", "channel_map=front-right,front-left")
            pactl("load-module", "module-null-sink", "sink_name=balance_surround", "channels=6",
                  "channel_map=front-left,front-right,rear-left,rear-right,front-center,lfe")
            env = {key: audio_env[key] for key in ("PIPEWIRE_RUNTIME_DIR", "PULSE_SERVER", "DBUS_SESSION_BUS_ADDRESS")}
            process, log = spawn_compositor(tmp, scale=scale,
                config_content='[animations]\nreduced_motion = "on"\n', env_extra=env)
            try:
                with IPCClient(tmp) as ipc:
                    ui = UIDriver(ipc)
                    ipc.open_control_center()
                    ui.wait_settled("control_center")
                    ui.click(ui.find("Audio", panel="control_center"))
                    wait(lambda: ipc.get_shell_state()["control_center"]["category"] == "audio", "Audio page")

                    def sink(name="osd_test"):
                        return next(s for s in json.loads(pactl("--format=json", "list", "sinks")) if s["name"] == name)

                    def volumes(name="osd_test"):
                        return {channel: v["value"] / 65536 for channel, v in sink(name)["volume"].items()}

                    def balance(name="osd_test"):
                        v = volumes(name)
                        left, right = v["front-left"], v["front-right"]
                        return (right - left) / max(left, right) if max(left, right) else 0

                    def slider():
                        return ui.find("output_balance", panel="control_center")

                    def value():
                        return slider()["value"]

                    def adjust(fraction):
                        ui.click(slider(), fraction=max(.002, min(.998, fraction)))

                    def balanced(expected, name="osd_test"):
                        wait(lambda: abs(balance(name) - expected) < .03, f"{name} balance {expected}")
                        wait(lambda: abs(value() - expected) < .03, "balance UI follows server")

                    def volume(expected, name="osd_test"):
                        wait(lambda: abs(max(volumes(name).values()) - expected) < .003, "master volume")

                    def choose(name):
                        subprocess.run(["pw-metadata", "0", "default.audio.sink", json.dumps({"name": name}), "Spa:String:JSON"],
                                       env=audio_env, check=True, capture_output=True)
                        wait(lambda: f"Default Sink: {name}" in pactl("info"), "default sink")
                        wait(lambda: any(w["label"] == sink(name)["description"] for w in ui.widgets()), "output UI")

                    wait(lambda: abs(value()) < .01, "initial centre")
                    adjust(0)
                    balanced(-1)
                    volume(.5)
                    adjust(1)
                    balanced(1)
                    volume(.5)
                    adjust(.5)
                    balanced(0)
                    print("PASS: left/right endpoints and centre preserve master level")

                    # Externally set unequal channels, then edit the master
                    # slider and press volume keys: neither may re-centre them.
                    pactl("set-sink-volume", "osd_test", "50%", "25%")
                    balanced(-.5)
                    ui.click(ui.find("output_volume", panel="control_center"), fraction=.8)
                    volume(.8)
                    balanced(-.5)
                    ipc.key_press("XF86AudioRaiseVolume")
                    volume(.85)
                    balanced(-.5)
                    for _ in range(5):
                        ipc.key_press("XF86AudioLowerVolume")
                    volume(.6)
                    balanced(-.5)
                    assert abs(ipc.action('get_audio_state')["master_volume"] - .6) < .01
                    print("PASS: volume slider, hardware keys and OSD retain balance")

                    # Alternate absolute commands without waiting for the
                    # subscription cache between operations.
                    for position, target in ((1, .3), (0, .7), (.5, .4)):
                        adjust(position)
                        ipc.action('set_master_volume', {"volume": target})
                    volume(.4)
                    balanced(0)
                    print("PASS: interleaved balance and volume changes retain the final values")

                    pactl("set-sink-mute", "osd_test", "1")
                    adjust(1)
                    balanced(1)
                    assert sink()["mute"]
                    pactl("set-sink-mute", "osd_test", "0")
                    ipc.action('set_master_volume', {"volume": 0})
                    volume(0)
                    wait(lambda: value() > .99, "silent output retains balance")
                    adjust(0)
                    wait(lambda: value() < -.99, "balance can change while silent")
                    ipc.key_press("XF86AudioRaiseVolume")
                    volume(.05)
                    balanced(-1)
                    ipc.action('set_master_volume', {"volume": .5})
                    volume(.5)
                    balanced(-1)
                    print("PASS: mute and zero-volume round trip preserve selected balance")

                    choose("balance_mono")
                    wait(lambda: not any(w["name"] == "output_balance" for w in ui.widgets()), "mono has no balance slider")
                    ipc.action('set_master_volume', {"volume": .4})
                    volume(.4, "balance_mono")
                    choose("balance_reversed")
                    wait(lambda: any(w["name"] == "output_balance" for w in ui.widgets()), "stereo balance returns")
                    ipc.action('set_master_volume', {"volume": .5})
                    volume(.5, "balance_reversed")
                    adjust(0)
                    balanced(-1, "balance_reversed")
                    assert volumes("balance_reversed")["front-right"] == 0
                    print("PASS: mono unavailable and reversed channel order handled")

                    choose("balance_surround")
                    ipc.action('set_master_volume', {"volume": .5})
                    volume(.5, "balance_surround")
                    adjust(0)
                    balanced(-1, "balance_surround")
                    v = volumes("balance_surround")
                    assert v["rear-right"] == 0 and abs(v["rear-left"] - .5) < .003, v
                    assert abs(v["front-center"] - .5) < .003 and abs(v["lfe"] - .5) < .003, v
                    choose("osd_test")
                    balanced(-1)
                    window = next(w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings")
                    ipc.close_window(window["id"])
                    ui.wait_absent("control_center")
                    ipc.open_control_center()
                    ui.wait_settled("control_center")
                    ui.click(ui.find("Audio", panel="control_center"))
                    balanced(-1)
                    adjust(.5)
                    balanced(0)
                    if path := os.environ.get("REDIWM_BALANCE_PREVIEW"):
                        ipc.wait_for_frame()
                        ipc.screenshot(path)
                    print(f"PASS: surround channels, device switching and reopening settings at {scale}x")
            except Exception:
                log.flush()
                print((tmp / "compositor.log").read_text(errors="replace")[-10000:])
                raise
            finally:
                stop_process(process)
                log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--scale", default="1")
    run(parser.parse_args().scale)
