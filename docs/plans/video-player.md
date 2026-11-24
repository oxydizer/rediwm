# Plan: native video player (`rediwm-video`)

Status: phases 0–3 complete on `feat/video-player`. Phase 2 measured H.264
playback on the Intel DRM panel on 2026-11-25. The wider phase 0 codec and
colour checks on nested and physical outputs remain open.

## What we want

A video player that sits beside Files, Images and PDF. It is written in Zig,
calls FFmpeg's libraries directly (libavformat, libavcodec, libavutil,
libswscale, libswresample) and draws its controls with the shared `ui`
widgets. It does not use GStreamer, libmpv or a toolkit. Decoded frames go to
the compositor with no copies where the hardware allows it.

**Reference: Glimpse** (github.com/Mel34/Glimpse). It is Rust, GTK4 and
libadwaita, not Zig. It is LGPL-2.1+, has 40 commits and 0 stars. We take its
design, not its code:

* a demuxer feeding bounded per-stream packet queues;
* VAAPI first. NV12/P010 frames are exported as DRM PRIME dmabufs and shown
  with no copies (GdkDmabufTexture behind GtkGraphicsOffload). If that fails it
  downloads to RGBA, and from the first import failure it stays on that path
  for the rest of the run;
* the audio clock is the master (PipeWire). Video-only files use a monotonic
  clock;
* seeks go to the previous keyframe and drop frames before the target;
* text subtitles: embedded tracks and external `.srt/.ass/.vtt`, off by
  default, with no bitmap subtitles;
* its key set (below), speed 0.5–2×, A-B loop, screenshot, volume to 150 %.

## Facts checked (2026-11-24)

* **Zig 0.17 translates FFmpeg's headers cleanly.** A header root with
  avformat, avcodec, hwcontext (+ `_drm`, `_vaapi`), mastering-display
  metadata, opt, imgutils, swscale and swresample builds and links through
  `addTranslateC`. `AVERROR(EAGAIN)`, `AVERROR_EOF` and `AV_NOPTS_VALUE` come
  out as usable values. So no C shim is needed for FFmpeg (scratch spike, not
  in the tree). System FFmpeg has libavcodec 63.1, libva 1.24 and libdrm 2.4.134.
* **This laptop has two VAAPI drivers.** `renderD128` is Intel iHD (H.264,
  HEVC Main10, …). `renderD129` is nvidia-vaapi-driver (H.264, HEVC Main10,
  VP9.2, AV1). The compositor renders on the Intel GPU. A dmabuf from the other
  GPU is a cross-device import, so the player must pick the render node named
  by linux-dmabuf feedback (`main_device`), not the first one it finds.
* **The compositor already has what a zero-copy player needs.** It has
  linux-dmabuf (v5 bindings), viewporter, single-pixel-buffer,
  presentation-time, color-representation, color-management (with HDR on
  master), content-type, idle-inhibit, fifo and alpha-modifier.
  `scene_pass_yuv.c` imports YUV dmabufs as external images. It passes the
  client's matrix and range at import and caches the EGLImage on the
  `wlr_buffer`. So **the player must reuse one `wl_buffer` per decoder surface**.
  A new buffer each frame would mean a new EGLImage import each frame.
* **Before phase 0, no app client used subsurfaces or client-side dmabuf.** `app_kit/window.zig`
  is one shm surface. Client bindings for `wp_presentation`,
  `wp_color_representation_v1` and `wp_content_type_v1` are now generated
  (`build/protocols.zig`).
* `rediwm-player` (audio, C) already vendors miniaudio 0.11.22. Its backends
  (PipeWire, Pulse, ALSA; OSS/sndio on FreeBSD) are loaded with dlopen. Nothing
  in the compositor consumes MPRIS today.

## Design

### Process and files

One process per window. This is the Images/PDF model, not the
single-instance audio player. The binary is `rediwm-video` (`src/video_main.zig`)
and the code is in `src/video/`, with its own `AGENTS.md`:

| File | Role |
|---|---|
| `c/av.h` | header root for a new `c_av` module (FFmpeg + libva + libdrm) |
| `demux.zig` | open, probe, pick streams, read thread, seek requests |
| `queue.zig` | bounded packet/frame queues with a generation number for flushes |
| `decode.zig` | one decode thread per active stream; send/receive loop |
| `hw.zig` | VAAPI device on the feedback render node, DRM PRIME export, fallback |
| `audio.zig` + `audio_out.c` | swresample to device format; a small miniaudio shim (ring + clock) |
| `clock.zig` | audio-master / monotonic clock, speed, pause |
| `present.zig` | surfaces, buffer cache, viewport, colour metadata, frame pacing |
| `osd.zig`, `subtitles.zig` | controls overlay and subtitle raster |
| `app.zig` + `app_*.zig`, `client.zig` + `client_*.zig` | state, input, window |

### Pipeline and threads

```
demux thread ──packets──▶ video decode ──frames (≤6)──▶ main thread: pick + present
             └─packets──▶ audio decode ──swr──▶ SPSC ring ──▶ miniaudio callback (clock)
             └─packets──▶ subtitle decode ──events──▶ main thread
```

* Packet queues are capped by bytes and by duration. The demuxer blocks when
  they are full and wakes on a condvar, never on a timer.
* **A seek** bumps a generation number. Each stage drops items from an older
  generation, the decoders call `avcodec_flush_buffers`, and the demuxer seeks
  to the keyframe before the target (`AVSEEK_FLAG_BACKWARD`). An *exact* seek
  then decodes and drops frames until it reaches the target. Dragging the seek
  bar uses keyframe seeks only.
* Software decode uses FFmpeg's frame threads (`thread_count = 0`). VAAPI uses
  `extra_hw_frames` = queue depth + 3 (buffers the compositor may still hold).
* The main thread runs the Wayland loop. Workers wake it with an eventfd
  through `platform`, as the other apps do.

### Presenting frames

Surfaces:

* **root**: the xdg_toplevel. A black single-pixel buffer stretched by the
  viewport, used for letterbox bars and the background.
* **video**: a desync subsurface. A viewport destination sets the letterboxed
  rectangle (crop through the viewport source).
* **osd**: an ARGB shm subsurface above the video. It covers only the control
  bar. While hidden it is unmapped (null attach), so a hidden OSD costs
  nothing.
* **subs**: an ARGB shm subsurface sized to the current cue. It is redrawn
  only when the cue changes.

**Hardware path:** VAAPI decode → `vaExportSurfaceHandle` once per VA surface
(composed layers, or separate layers recombined) →
`zwp_linux_buffer_params_v1`, one `wl_buffer` per VA surface, kept in a cache. A buffer holds a reference to its `AVFrame` until `release`. Before
attaching, the player calls `vaSyncSurface`. Matrix and range go through
`wp_color_representation_v1` (BT.601/709/2020, limited or full). The player
falls back to software when it cannot create the device, when the decoder
fails on its first packet, or when the compositor refuses the buffer
(`params.failed` / a format missing from feedback). It never retries that path
in the same run.

**Software path:** swscale converts to XRGB8888 (2101010 for 10-bit sources)
at the source size, into a shm pool of 3 buffers. A busy buffer is never
written. The compositor scales through the viewport. Uploading YUV through shm
is not worth doing (wlroots' GLES2 shm formats are RGB).

**Pacing:** the player keeps a per-frame deadline timer (timerfd) and never
polls. The timer fires one refresh before the frame's due time, when the
newest frame with `pts ≤ clock + latency` is attached. Presentation-time
feedback provides the refresh period and phase, and corrects the latency
estimate. While paused, no timer is armed and no callback is requested.
Nothing wakes the process (AGENTS.md: idle makes no wakeups). A dropped frame
is counted, not made up for.

**Hints:** `wp_content_type_v1` is set to `video`. An idle inhibitor is held on
the video surface while it is playing and mapped. Fullscreen uses
`xdg_toplevel.set_fullscreen`. In fullscreen the cursor hides together with
the OSD.

### Audio

The decoder's output goes through swresample to the device's rate, layout and
format, then into a lock-free SPSC ring. miniaudio's callback reads from the
ring and never blocks or allocates (rule from `src/player/AGENTS.md`).
**The clock** is the pts of the last sample handed to the device minus the
device's reported latency. Pausing stops the device. Volume (0–150 %) and mute
are applied in the callback with a short ramp. Speed changes need
pitch-correct time stretching. That is libavfilter's `atempo`, so speed waits
until a later phase.

### Controls (`osd.zig`)

The controls are the shared `ui` widgets: slider, buttons, menus. No control
is drawn or hit-tested by hand. They are play/pause, a seek bar with elapsed
and remaining time, volume, audio and subtitle track menus, and fullscreen.
They hide 3 s after the pointer last moved (a deadline, not a tick). Theme
tokens and text sizes follow the App-client rules in AGENTS.md. OSD repaints
follow frame callbacks (`app_clients_render_at_input_rate` lesson).

Keys, taken from Glimpse: Space/click play-pause · F/double-click fullscreen ·
Esc leave fullscreen · ←/→ ±5 s (Shift ±60 s) · ↑/↓ volume ±5 % · M mute ·
`,`/`.` frame step while paused · J/K cycle audio/subtitle track · Ctrl+O open.
Wheel over the seek bar seeks; elsewhere it changes the volume.

### Subtitles

Text subtitles come first: embedded subrip, mov_text and webvtt tracks, and
external `.srt`/`.vtt` files beside the video with the same base name. They are
drawn with `ui.text` at the theme's text size, scaled to the video height, with
an outline. ASS/SSA: see D5. Bitmap subtitles (PGS, DVD) are cheap with FFmpeg,
since `AVSubtitleRect` gives an indexed bitmap and a palette, so we do them too,
unlike Glimpse. Tracks are off by default. Track order puts the user's language
first.

### Colour and HDR

HDR is phase 5. It needs a 10-bit source (P010 on the hardware path,
2101010 in software), `wp_color_management_v1` parametric descriptions
(BT.2020 primaries, PQ or HLG, and mastering luminance from the stream's side
data), and an answer to one question first: what does the pass do with a PQ
surface on an SDR output (tone map, clip)? The plan in `docs/plans/hdr.md`
decides that, not the player.

### Safety

FFmpeg's demuxers and decoders are a large parser surface, and the files they
read are untrusted. v1 hardening: `protocol_whitelist=file` (FFmpeg can open local
files, including local playlist entries, and cannot use network protocols), local paths only, and
`format_whitelist` left at the default. A seccomp sandbox like PDF's is D4.
The hard part is that the sandbox must still allow DRM ioctls on the render
node and the audio socket's traffic after setup.

### Integration

* `data/rediwm-video.desktop` with `video/*` MIME types. Files opens videos
  through its normal associations and falls back to us, as it does with the
  audio player.
* Launches go through `app_scope.place`, as for every user app.
* Build: `build/video.zig` links the system's shared FFmpeg, never a vendored
  or static copy. `install.sh` and the release tarballs gain the FFmpeg and
  libva packages. The FreeBSD cross sysroot needs FFmpeg headers. VAAPI is
  optional at run time.

## Phases

0. **Hardware path (done 2026-11-24, headless).** `rediwm-video [--start S]
   [--paused] [--hwdec=no] FILE` decodes on the main thread and shows VAAPI
   frames through the buffer cache in a letterboxed subsurface, timed on the
   monotonic clock. There is no audio, no software path and no input yet.
   Results:
   * The compositor offers NV12 and P010 as linear, X/Y-tiled and Gen12 MC_CCS
     on Intel, and NVIDIA block-linear plus linear on NVIDIA. iHD exports
     Y-tiled, composed (one layer, two planes). nvidia-vaapi-driver refuses
     composed export: it gives R8 + RG88 in two objects with one block-linear
     modifier, which recombine into a valid NV12/P010 buffer.
   * The pixels match FFmpeg's own decode for H.264, HEVC Main10 (P010), VP9,
     AV1, a full-range clip and SD BT.601, on both GPUs. The mean error is 1–3
     levels; the residue is on chroma edges only.
   * The cache works: 6 buffers, 7 imports for 244 frames at 30 fps, none
     after startup, and releases match attaches.
   * Decoder choice matters: libdav1d (FFmpeg's default for AV1) has no
     VAAPI. VAAPI decoding is fast (540p H.264 at about 2000 fps).
   * Open: nested and DRM runs, which need the live desktop or a spare VT.
1. **Pipeline and software fallback (done 2026-11-24, headless).** One
   demux worker feeds bounded packet queues and one decoder per active
   stream. Seeks flush packets, pictures, resampler and PCM together. VAAPI
   failure reopens the software decoder at the current position. The video
   surface accepts source-size RGB shm, including 10-bit when advertised.
   The miniaudio device clock drives playback with audio. Video-only playback
   uses monotonic time. A one-shot timerfd schedules frames against
   presentation feedback. Space pauses, Left/Right seek 5 s (Shift for
   60 s), F toggles fullscreen, and Escape leaves fullscreen.
   `zig build test-video-integration` checks decoded pixels, a refused
   layout after a successful import, exact paused seeks, playback rate,
   short audio tracks, EOF replay and per-thread idle over a 5 s pause.
   The audio fixture uses miniaudio's paced null device. Intel also passed
   the pixel and input checks at scale 1.5. On NVIDIA, synchronizing VP9
   surfaces on the decode worker before decoding ahead fixed an intermittent
   first-frame stall. Thirty consecutive paused launches passed.
2. **Measure (done 2026-11-25, DRM).** On the same 1080p60 H.264 clip,
   the native player used 23% less player CPU than mpv. Package power was
   within run-to-run variation. See the [results](#phase-2-measurements).
3. **Controls (done, headless).** The pointer reveals a themed control bar
   with play/pause, elapsed and remaining time, seek, mute, volume (0–150%),
   open and fullscreen. Dragging previews keyframes and release seeks exactly.
   The bar unmaps after three seconds. In fullscreen the cursor hides with
   it. Click pauses, double-click toggles fullscreen, and comma/period step
   through decoded pictures while paused. The video advertises its content
   type and holds an idle inhibitor during mapped playback. Ctrl+O, launching
   without a filename, and URI-list drops use local files. Opening another
   movie keeps the window and volume. Track menus belong to phase 4.
4. **Tracks and subtitles (partial).** External SubRip is implemented.
   During playback, open an `.srt` with Ctrl+O or drop it onto the window.
   K toggles the loaded track. On first use it looks for a same-basename
   `.srt` beside the video and opens a subtitle chooser if the file is
   missing. Each video starts with subtitles off. Audio track switching,
   embedded subtitles, WebVTT, bitmap subtitles and ASS per D5 remain planned.
5. **HDR and 10-bit**, after the pass's answer above.
6. **Extras:** MPRIS through the `dbus` module (media keys, `playerctl`),
   speed with `atempo`, A-B loop, screenshot, the sandbox (D4).

## Phase 2 measurements

Four paired fullscreen runs on the laptop's BOE eDP-1 panel used the same
40-second, video-only 1080p60 H.264 High test pattern and Intel VAAPI device. The i9-12900H
was on AC in the performance platform profile. RediWM 0.1.0 drove the panel
at 2560×1600, 60 Hz and scale 1.6 through i915. Both players used dmabufs
and the compositor composited both. The native binary was ReleaseSafe. mpv
0.41.0 used `--no-config --hwdec=vaapi --vo=dmabuf-wayland`.

Each run warmed up for 5 seconds before the 15-second playback sample.
Player order alternated across pairs. CPU is percent of one logical core.
Power is average Intel package-0 RAPL watts over the interval and includes
other activity on the machine. The table gives medians across four runs.

| During playback | rediwm-video | mpv |
|---|---:|---:|
| Player CPU | 4.57% | 5.93% |
| Compositor CPU | 8.60% | 9.53% |
| Package power | 6.91 W | 6.86 W |
| Package power range | 6.78–6.92 W | 6.62–7.06 W |

Player and compositor CPU were lower with rediwm-video in every pair. Each
player had lower package power in two pairs. Both advanced about 15 seconds
of media per sample. RediWM counted one late frame in each launch, including
warmup. mpv reported zero decoder and VO drops inside the timed intervals.

**Paused:** each player held the first frame for four 8-second samples. All
three rediwm-video threads accumulated zero CPU nanoseconds and zero context
switches. mpv's main and VO threads each recorded one voluntary switch per
sample. The other 15 threads recorded none. The decode engine was idle for
both. Two additional 8-second samples per player reproduced these counts
with the first mpv control-socket query deferred until after sampling.
The [raw data](video-player-phase2.json) include the per-thread deltas,
individual power samples, display mode, binary and clip hashes. The
[benchmark instructions](../../TESTING.md#video-player-drm-benchmark)
reproduce the workload.

## Tests

* Clips are generated at test time with the `ffmpeg` CLI (already a test
  dependency, `TESTING.md`). The video is `testsrc2` with a burned-in frame
  counter or colour-coded time bars. Formats: H.264/AAC in MP4, VP9/Opus in
  WebM, 10-bit HEVC in MKV, plus an SRT and a file with no audio.
* `tests/video.py` runs a headless compositor and uses IPC screenshots. Checks:
  the first frame appears, a seek lands on the right frame (decode the counter
  from pixels), pause makes no wakeups (per-thread context switches over 5 s,
  AGENTS.md idle rule), the hardware and software paths give matching pixels
  within a tolerance, and fallback works when VAAPI is unavailable.
* Audio uses a noninstalled fixture built with a paced null device
  (`-DRV_TEST_NULL_DEVICE`), as `rediwm-player-test` is. There is never an
  environment switch in the installed binary.
* Unit tests (`src/video_tests.zig`) cover the queues, generations, clock
  maths, frame picking against a fake refresh, and subtitle timing.

## Decisions (accepted 2026-11-24, as recommended; D7 dropped)

* **D1 Name:** `rediwm-video`, app id `rediwm-video`, shown as "Videos".
  *Recommended.*
* **D2 Window host:** our own client in `src/video/` that reuses `app_kit`'s
  pieces (`window_buffer`, `window_outputs`, settings), or teaching
  `app_kit.window` about subsurfaces. *Recommended: our own client first.*
  `app_kit`'s contract is public (outside apps build against it). Move the
  subsurface support into it once a second app needs it.
* **D3 Audio output:** the vendored miniaudio behind a small C shim, or
  PipeWire directly (Glimpse), or libpulse. *Recommended: miniaudio.* It is
  already vendored, licensed and loaded at run time, and it covers FreeBSD too.
* **D4 Sandbox:** hardening only in v1 with seccomp in phase 6, or required
  from day one like PDF. *Recommended: phase 6.* The allowlist depends on what
  VAAPI and the audio backend do after setup, and phase 2 will show that.
* **D5 ASS subtitles:** libass, a new dependency with correct styling, or
  plain text with the tags removed, through `ui.text`. *Recommended: plain text
  in phase 4, libass later only if wanted.*
* **D6 Scope:** local files only in v1, with no URLs or streams.
  *Recommended.* This is also what makes `protocol_whitelist=file` possible.
* **D7 Files thumbnails:** dropped for now (user, 2026-11-24). If they come
  back, a `rediwm-video --thumbnail` helper keeps FFmpeg out of Files.
