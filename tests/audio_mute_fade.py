#!/usr/bin/env python3
"""Mute and unmute fade through the bass filter in a private audio session.

Requires PipeWire, WirePlumber (smart filters), dbus-run-session, pactl,
pw-dump, pw-record, pw-link and paplay. A tone plays through the filter into a
null sink whose monitor is recorded; no host devices or settings are touched.
"""
import array
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time
import wave

from hardware_keys import wait
from ipc_client import IPCClient, spawn_compositor, stop_process

RATE = 48000
WINDOW_MS = 5


def levels(raw):
    """Peak level per 5 ms window, relative to the loudest window."""
    data = array.array("h")
    data.frombytes(raw[:len(raw) // 2 * 2])
    window = RATE * WINDOW_MS // 1000
    peaks = [max(map(abs, data[i:i + window])) for i in range(0, len(data) - window, window)]
    top = max(peaks) or 1
    return [p / top for p in peaks]


def transition(values, start_ms, falling):
    """Milliseconds between the 90% and 10% crossings after `start_ms`."""
    first, last = (.9, .1) if falling else (.1, .9)
    i = start_ms // WINDOW_MS
    # Start from the settled level, then find where it leaves it.
    while i < len(values) and not (values[i] >= first if falling else values[i] <= first):
        i += 1
    while i < len(values) and not (values[i] < first if falling else values[i] > first):
        i += 1
    j = i
    while j < len(values) and not (values[j] < last if falling else values[j] > last):
        j += 1
    assert j < len(values), f"no {'fade out' if falling else 'fade in'} after {start_ms} ms"
    return i * WINDOW_MS, (j - i) * WINDOW_MS


def run(tmp):
    runtime = tmp / "audio"
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), PIPEWIRE_RUNTIME_DIR=str(runtime),
               PULSE_SERVER="unix:" + str(runtime / "pulse/native"),
               DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(runtime / "no-bus"),
               GIO_USE_VFS="local", XDG_STATE_HOME=str(tmp / "state"), XDG_CONFIG_HOME=str(tmp / "config"))
    env.pop("PIPEWIRE_REMOTE", None)
    procs = []
    audio_log = (tmp / "audio.log").open("w")

    def command(*args):
        return subprocess.check_output(args, env=env, text=True, stderr=subprocess.DEVNULL, timeout=5)

    def device_muted():
        return "yes" in command("pactl", "get-sink-mute", "fade_test")

    try:
        for args in (["pipewire", "-c", "/usr/share/pipewire/pipewire.conf"], ["pipewire-pulse"]):
            procs.append(subprocess.Popen(args, env=env, stdout=audio_log, stderr=audio_log))
        wait(lambda: subprocess.run(["pactl", "info"], env=env, capture_output=True).returncode == 0, "private audio")
        # The policy-only profile has no ALSA, Bluetooth or camera monitors.
        procs.append(subprocess.Popen(["dbus-run-session", "--", "wireplumber", "--profile=policy"],
                                      env=env, stdout=audio_log, stderr=audio_log))
        command("pactl", "load-module", "module-null-sink", "sink_name=fade_test")
        wait(lambda: "filters" in command("pw-metadata", "-l"), "smart-filter policy")
        command("pactl", "set-default-sink", "fade_test")
        extra = {key: env[key] for key in ("PIPEWIRE_RUNTIME_DIR", "PULSE_SERVER", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "DBUS_SESSION_BUS_ADDRESS")}
        config = '[compositor]\nxwayland = false\n[keybinds]\n"F12" = "quit"\n'
        process, log = spawn_compositor(tmp, env_extra=extra, config_content=config)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)

                def bass_node():
                    return any(n["type"] == "PipeWire:Interface:Node" and
                               n["info"]["props"].get("node.name", "").startswith("rediwm.bass.")
                               for n in json.loads(command("pw-dump")))
                wait(bass_node, "bass filter")

                def muted():
                    return ipc.action('get_audio_state')["master_muted"]

                tone = tmp / "tone.wav"
                with wave.open(str(tone), "wb") as w:
                    w.setnchannels(2)
                    w.setsampwidth(2)
                    w.setframerate(RATE)
                    frames = array.array("h")
                    for i in range(RATE * 12):
                        v = int(8000 * math.sin(2 * math.pi * 440 * i / RATE))
                        frames.extend((v, v))
                    w.writeframes(frames.tobytes())
                # Linked by hand: WirePlumber moves a sink-monitor capture onto
                # the smart filter's own (pre-fade) monitor.
                recording = tmp / "monitor.raw"
                recorder = subprocess.Popen(["pw-record", "--raw", "--format=s16", "--rate=48000", "--channels=1", "--latency=5ms",
                                             "-P", "{ node.name = fade_probe node.autoconnect = false }", "-"],
                                            env=env, stdout=recording.open("wb"), stderr=audio_log)
                procs.append(recorder)
                wait(lambda: "fade_probe:" in command("pw-link", "-i"), "recorder ports")
                port = next(line.strip() for line in command("pw-link", "-i").splitlines() if line.strip().startswith("fade_probe:"))
                command("pw-link", "fade_test:monitor_FL", port)
                procs.append(subprocess.Popen(["paplay", str(tone)], env=env, stdout=audio_log, stderr=audio_log))
                time.sleep(1.5)

                started = time.monotonic()
                marks = {}

                def mark(name):
                    marks[name] = round((time.monotonic() - started) * 1000)

                # Mute: reads as muted at once, the device follows the fade.
                mark("mute")
                ipc.key_press("XF86AudioMute")
                wait(muted, "muted")
                assert not device_muted(), "device muted before the fade played"
                wait(device_muted, "device muted after the fade")
                mark("device muted")
                time.sleep(.6)
                mark("unmute")
                ipc.key_press("XF86AudioMute")
                wait(lambda: not muted(), "unmuted")
                time.sleep(1)
                # Unmuting mid-fade turns the fade around; the device never mutes.
                mark("flick")
                ipc.key_press("XF86AudioMute")
                time.sleep(.06)
                ipc.key_press("XF86AudioMute")
                wait(lambda: not muted(), "flick unmuted")
                time.sleep(.6)
                assert not device_muted(), "a cancelled mute still muted the device"
                time.sleep(.4)
                # Another client unmuting fades the filter back in too.
                ipc.key_press("XF86AudioMute")
                wait(device_muted, "device muted again")
                time.sleep(.4)
                mark("external unmute")
                command("pactl", "set-sink-mute", "fade_test", "0")
                time.sleep(1)
                recorder.terminate()
                recorder.wait()

                values = levels(recording.read_bytes())
                # The recording started before `started`: align on the first fade.
                fade_out_at, fade_out = transition(values, 0, falling=True)
                offset = fade_out_at - marks["mute"]
                device_delay = marks["device muted"] - marks["mute"]
                assert 90 <= fade_out <= 170, f"fade out took {fade_out} ms"
                assert 200 <= device_delay <= 1000, f"device muted {device_delay} ms after the key"
                _, fade_in = transition(values, offset + marks["unmute"], falling=False)
                assert 160 <= fade_in <= 280, f"fade in took {fade_in} ms"
                flick = values[(offset + marks["flick"]) // WINDOW_MS:(offset + marks["flick"] + 600) // WINDOW_MS]
                assert min(flick) > .05, f"a cancelled mute went silent ({min(flick):.2f})"
                assert flick[-1] > .9, "a cancelled mute did not fade back in"
                _, external = transition(values, offset + marks["external unmute"], falling=False)
                assert 160 <= external <= 280, f"external unmute faded in over {external} ms"
                print(f"fade out {fade_out} ms, device mute after {device_delay} ms, fade in {fade_in} ms, "
                      f"cancelled mute dipped to {min(flick):.0%}, external unmute fade {external} ms")

                # Quitting mid-fade still leaves the device muted.
                ipc.key_press("XF86AudioMute")
                wait(muted, "muted before quit")
                try:
                    ipc.key_press("F12")
                except EOFError:
                    pass  # It quit before replying.
            process.wait(timeout=10)
            assert device_muted(), "quitting during the fade left the device unmuted"
            print("PASS: mute fades out before the device mutes, unmute fades in, cancel and quit are clean")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            stop_process(process)
            log.close()
    finally:
        for proc in reversed(procs):
            stop_process(proc)
        audio_log.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="rediwm-mute-fade-") as directory:
        run(Path(directory))
