# Audio player

`rediwm-player` is a background player for one file at a time, written in C
with GIO (like `files/volumes.c`, no Zig). Files starts it and follows it
(`files/player_link.c`, `files/app_audio.zig`); the taskbar sees only its
StatusNotifier item.

* **One instance per session, owned by the bus name `org.mpris.MediaPlayer2.rediwm`.**
  A second `rediwm-player FILE` forwards `OpenUri` and exits; losing the name
  race forwards too. MPRIS (`mpris.c`) is the only control surface: Files,
  `playerctl` and the tray menu all go through the same `player_*` functions in
  `main.c`. Keep MPRIS standard (no extra properties); Files reads `Position` on
  `PropertiesChanged`/`Seeked` and extrapolates.
* **Idle makes no wakeups.** The miniaudio device runs only while playing
  (`rp_engine_pause` stops it), there are no timers, and the process exits when
  the track ends or `Stop`/`Quit` arrives. Nothing may poll `Position`.
* **The audio callback never blocks or allocates.** Seeks while playing are an
  atomic request applied by the callback; while paused the decoder is touched
  directly (the device is stopped). New tracks reopen decoder and device.
* **Formats:** miniaudio's built-in WAV, FLAC and MP3 only, listed in
  `formats.zig` (Files imports it: add an extension there only with a decoder
  behind it). Vorbis/Opus/AAC need extra decoding backends.
* **Backends** are dlopen'd at run time and the null device is deliberately not
  in the list. `-DRP_TEST_NULL_DEVICE` (build/player.zig) builds the noninstalled
  `rediwm-player-test` fixture for `tests/files_audio.py` (`zig build
  test-files-audio`), whose paced null device reaches no host audio; never use
  it in the installed binary, and never add an environment switch for it.
* **App scope:** `--scope` (passed by Files per `terminalScopes()`) makes the
  player place itself in its own `app.slice` scope when it wins the name
  (`tray_place_scope`).
* **The tray icon is drawn in `tray.c`** (straight, not premultiplied, network
  ARGB) so no icon theme is needed; `ItemIsMenu` makes a click open the menu.
  Menu labels are English: this C program has no i18n yet.
* miniaudio is vendored in `third_party/miniaudio/` (v0.11.22, public domain /
  MIT-0) and compiled only in `miniaudio_impl.c`, as its own library with
  UBSan off and no `-Werror`.
