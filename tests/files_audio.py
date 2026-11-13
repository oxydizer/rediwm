#!/usr/bin/env python3
"""Files plays audio in rediwm-player: play button, double click, default app.

Runs a headless compositor, Files and the player on a private session bus.
The player is the fixture build (zig build test-files-audio passes it as the
first argument): the same code with miniaudio's null device, paced like
hardware, so nothing reaches host audio. Files starts it as its sibling
`rediwm-player`, as installed. Pass --keep-shots DIR to keep screenshots.
"""
import shutil
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import wave

from files_browser import wait_for

ROOT = Path(__file__).resolve().parents[1]


def write_tone(path, seconds):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(b"".join(struct.pack("<hh", 800, 800) for _ in range(22050 * seconds)))


SONG_X, SONG_Y = 503, 168
LIST_NAME_X, LIST_SONG_Y = 287, 210  # song.wav's name in list view


def run():
    fixture = next(a for a in sys.argv[1:] if not a.startswith("--") and Path(a).is_file())
    keep = sys.argv[sys.argv.index("--keep-shots") + 1] if "--keep-shots" in sys.argv else None
    with tempfile.TemporaryDirectory(prefix="rediwm-files-audio-") as directory:
        tmp = Path(directory)
        os.chmod(directory, 0o700)
        home = tmp / "Home"
        music = home / "Music"
        music.mkdir(parents=True)
        write_tone(music / "song.wav", 30)
        write_tone(music / "z-second.wav", 30)
        for i in range(10):
            shutil.copyfile(music / "song.wav", music / f"zz-{i:02}.wav")
        (music / "notes.txt").write_text("not audio")
        (music / "track.ogg").write_bytes(b"OggS")
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        shutil.copy(ROOT / "zig-out/bin/rediwm-files", bin_dir / "rediwm-files")
        shutil.copy(fixture, bin_dir / "rediwm-player")
        config = tmp / "config.toml"
        config.write_text("")
        config_home = tmp / "config"
        config_home.mkdir()
        data = tmp / "data"
        data.mkdir()
        env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=directory, XDG_DATA_HOME=str(data),
                   XDG_CONFIG_HOME=str(config_home), REDIWM_CONFIG=str(config), WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
                   REDIWM_SCALE="1", XDG_STATE_HOME=str(tmp / "state"), REDIWM_IPC_AUTOMATION="1")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        env.pop("REDIWM_FILES_DEVICES", None)
        processes = []
        bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                               stdout=subprocess.PIPE, text=True)
        processes.append(bus)
        env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
        env["DBUS_SYSTEM_BUS_ADDRESS"] = env["DBUS_SESSION_BUS_ADDRESS"]

        def start(binary, *args, **extra):
            with (tmp / (binary + ".log")).open("a") as log:
                exe = bin_dir / binary if (bin_dir / binary).exists() else ROOT / "zig-out/bin" / binary
                p = subprocess.Popen([str(exe), *args],
                                     env=dict(env, **extra), stdout=log, stderr=log)
            processes.append(p)
            return p

        def mpris(prop):
            out = subprocess.run(["busctl", "--user", "get-property", "org.mpris.MediaPlayer2.rediwm",
                                  "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", prop],
                                 env=env, capture_output=True, text=True)
            return out.stdout.strip()

        def status():
            return mpris("PlaybackStatus")

        try:
            start("rediwm")
            paths = wait_for(lambda: list(tmp.glob("rediwm-*.sock")), "IPC unavailable")
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(paths[0]))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    result = json.loads(reader.readline())
                    assert "Ok" in result, result
                    return result["Ok"]

                def action(name, params):
                    return request({"version": 1, "command": name, "params": params})

                def windows():
                    return [w for w in request({"version": 1, "command": "windows"}).get("Windows", [])
                            if w["app_id"] == "rediwm-files"]

                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                files = start("rediwm-files", str(music), WAYLAND_DISPLAY=display)
                win = wait_for(lambda: next(iter(windows()), None), "file manager did not map")
                action("focus_window", {"id": win["id"]})
                time.sleep(.5)

                def box():
                    return request({"version": 1, "command": "get_window_debug", "params": {"id": win["id"]}})["WindowDebug"]["client_box"]

                def move(x, y):
                    b = box()
                    action("move_cursor", {"x": b["x"] + x, "y": b["y"] + y})
                    time.sleep(.2)

                def click(x, y, times=1):
                    move(x, y)
                    for _ in range(times):
                        for pressed in (True, False):
                            action("pointer_button", {"button": 272, "pressed": pressed})
                        time.sleep(.08)
                    time.sleep(.3)

                shots = []

                def shot(name):
                    path = tmp / (name + ".png")
                    action("screenshot", {"path": str(path)})
                    wait_for(path.exists, "no screenshot")
                    time.sleep(.2)
                    if keep:
                        Path(keep).mkdir(parents=True, exist_ok=True)
                        (Path(keep) / (name + ".png")).write_bytes(path.read_bytes())
                    shots.append(path)

                # Grid view by name: notes.txt, song.wav, track.ogg, z-second.wav.
                # song.wav's icon centre, in window-local pixels.
                b = box()
                shot("grid-idle")
                from ipc_client import IPCClient
                with IPCClient(tmp) as ipc:
                    def cursor():
                        return ipc.get_input_state()["cursor_name"]

                    found = (SONG_X, SONG_Y)
                    move(*found)
                    assert cursor() == "pointer", "no clickable play overlay over song.wav: " + cursor()
                    shot("grid-hover")
                    # The hit is on the play overlay of one of the audio icons.
                    click(*found)
                    wait_for(lambda: status() == 's "Playing"', "click on the play button did not start playback")
                    assert "song.wav" in mpris("Metadata"), mpris("Metadata")
                    shot("grid-playing")
                    click(*found)
                    wait_for(lambda: status() == 's "Paused"', "second click did not pause")
                    click(*found)
                    wait_for(lambda: status() == 's "Playing"', "third click did not resume")
                    # The toolbar follows playback and remains usable while paused.
                    click(338, 82)
                    wait_for(lambda: status() == 's "Paused"', "toolbar did not pause")
                    # Narrow inline bar: Previous, Play, Next, then the title and
                    # time above the Settings slider (x 402-578), Stop, Playlist.
                    click(500, 90)
                    wait_for(lambda: int(mpris("Position").split()[1]) > 10_000_000,
                             "toolbar seek did not move position")
                    # The shared scrollbar thumb also supports dragging outside
                    # its gutter, without resuming a paused track.
                    move(500, 89)
                    action("pointer_button", {"button": 272, "pressed": True})
                    move(400, 110)
                    action("pointer_button", {"button": 272, "pressed": False})
                    wait_for(lambda: int(mpris("Position").split()[1]) < 10_000_000,
                             "scrollbar drag did not seek backwards")
                    assert status() == 's "Paused"'
                    click(500, 89)
                    wait_for(lambda: int(mpris("Position").split()[1]) > 10_000_000,
                             "scrollbar click did not seek forwards")
                    shot("toolbar-paused")
                    # Previous restarts a track that has played past 3 s; the
                    # first track has nothing before it either way.
                    click(304, 82)
                    wait_for(lambda: int(mpris("Position").split()[1]) < 3_000_000,
                             "Previous did not restart the track")
                    assert "song.wav" in mpris("Metadata"), mpris("Metadata")
                    # Navigation must not hide the controls for the current track.
                    click(92, 28)  # Up to Home
                    shot("toolbar-other-folder")
                    assert status() == 's "Paused"'
                    click(644, 82)
                    shot("playlist-other-folder")
                    # Only supported audio appears: song.wav then z-second.wav.
                    # The popup retains Music even though Files now shows Home.
                    click(430, 196)
                    wait_for(lambda: "z-second.wav" in mpris("Metadata"),
                             "playlist did not play the second audio file from Music")
                    # Keyboard navigation reaches tracks below the visible rows.
                    for pressed in (True, False):
                        action("key", {"keycode": 107, "pressed": pressed})  # End
                    shot("playlist-scrolled")
                    for pressed in (True, False):
                        action("key", {"keycode": 28, "pressed": pressed})
                    wait_for(lambda: "zz-09.wav" in mpris("Metadata"),
                             "playlist keyboard navigation did not reach last track")
                    click(644, 82)  # dismiss playlist
                    # The last track has no Next; Previous early in a track
                    # goes back one, and Next returns.
                    move(372, 82)
                    assert cursor() != "pointer", "Next is enabled on the last track"
                    click(304, 82)
                    wait_for(lambda: "zz-08.wav" in mpris("Metadata"), "Previous did not go back a track")
                    click(372, 82)
                    wait_for(lambda: "zz-09.wav" in mpris("Metadata"), "Next did not advance a track")
                    click(338, 82)
                    wait_for(lambda: status() == 's "Paused"', "playlist track did not pause")
                    # A wide window fits the title and the time pill beside the slider.
                    action("set_window_size", {"id": win["id"], "width": 1200, "height": 540})
                    wait_for(lambda: box()["width"] == 1200, "Files did not resize")
                    time.sleep(.5)
                    shot("toolbar-wide")
                    # A narrow window gives the player its own row.
                    action("set_window_size", {"id": win["id"], "width": 560, "height": 500})
                    wait_for(lambda: box()["width"] == 560, "Files did not resize")
                    time.sleep(.5)
                    shot("toolbar-narrow")
                    click(70, 176)
                    wait_for(lambda: status() == 's "Playing"', "narrow toolbar did not resume")
                    click(488, 176)
                    wait_for(lambda: status() == "", "toolbar Stop did not exit player")
                    shot("toolbar-stopped")
                    action("set_window_size", {"id": win["id"], "width": 960, "height": 540})
                    wait_for(lambda: box()["width"] == 960, "Files did not resize back")
                    time.sleep(.5)
                    click(28, 28)  # Back to Music
                    click(*found)
                    wait_for(lambda: status() == 's "Playing"', "play did not restart")
                    click(338, 82)
                    wait_for(lambda: status() == 's "Paused"', "toolbar did not pause restarted track")
                    click(338, 82)
                    wait_for(lambda: status() == 's "Playing"', "toolbar did not resume")
                    click(726, 82)  # list view: the button sits right of the name
                    time.sleep(.6)
                    shot("list-playing")
                    # Closing Files leaves the player running.
                    action("close_window", {"id": win["id"]})
                    wait_for(lambda: not windows(), "Files did not close")
                    time.sleep(.5)
                    assert status() == 's "Playing"', "playback stopped with Files"
                    subprocess.run(["busctl", "--user", "call", "org.mpris.MediaPlayer2.rediwm",
                                    "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Stop"],
                                   env=env, check=True, capture_output=True)
                    wait_for(lambda: status() == "", "the player did not exit on Stop")

                    def stop_player():
                        subprocess.run(["busctl", "--user", "call", "org.mpris.MediaPlayer2.rediwm",
                                        "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Stop"],
                                       env=env, check=True, capture_output=True)
                        wait_for(lambda: status() == "", "the player did not exit on Stop")

                    def open_files():
                        files = start("rediwm-files", str(music), WAYLAND_DISPLAY=display)
                        new = wait_for(lambda: next(iter(windows()), None), "file manager did not map")
                        action("focus_window", {"id": new["id"]})
                        time.sleep(.5)
                        return new

                    # Double click plays in the built-in player (the view stayed a list).
                    win = open_files()
                    click(LIST_NAME_X, LIST_SONG_Y, times=2)
                    wait_for(lambda: status() == 's "Playing"', "double click did not play the file")
                    stop_player()
                    # An explicit default application replaces the built-in player.
                    marker = tmp / "opened"
                    opener = tmp / "opener.sh"
                    opener.write_text('#!/bin/sh\nprintf "%s" "$1" > "' + str(marker) + '"\n')
                    opener.chmod(0o755)
                    (data / "applications").mkdir(exist_ok=True)
                    (data / "applications" / "rediwm-test-audio.desktop").write_text(
                        "[Desktop Entry]\nType=Application\nName=Test Audio\n"
                        f"Exec={opener} %f\nMimeType=audio/x-wav;audio/vnd.wave;audio/wav;\n")
                    (config_home / "mimeapps.list").write_text(
                        "[Default Applications]\naudio/x-wav=rediwm-test-audio.desktop;\n")
                    action("close_window", {"id": win["id"]})
                    wait_for(lambda: not windows(), "Files did not close")
                    win = open_files()
                    # Files remembers list view across launches. Switch back
                    # to grid so the preview click targets the song icon.
                    click(691, 82)
                    time.sleep(.6)
                    # An explicit default must not suppress built-in preview.
                    shot("explicit-default-view")
                    move(*found)
                    assert cursor() == "pointer", (
                        "audio preview control is not hit-testable with an explicit default: "
                        + cursor()
                    )
                    click(*found)
                    wait_for(lambda: status() == 's "Playing"',
                             "explicit default suppressed the audio preview button")
                    assert "song.wav" in mpris("Metadata"), mpris("Metadata")
                    stop_player()
                    click(726, 82)  # switch to list view
                    click(LIST_NAME_X, LIST_SONG_Y, times=2)
                    wait_for(marker.exists, "the explicit default application was not used")
                    assert marker.read_text() == str(music / "song.wav"), marker.read_text()
                    time.sleep(.5)
                    assert status() == "", "the built-in player started despite an explicit default"
        finally:
            for p in reversed(processes):
                p.terminate()
            for p in processes:
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
            for log in sorted(tmp.glob("*.log")):
                text = log.read_text()
                if "--verbose" in sys.argv or sys.exc_info()[0] is not None:
                    print("==", log.name, "\n", text[-2000:])
    print("ok")


if __name__ == "__main__":
    run()
