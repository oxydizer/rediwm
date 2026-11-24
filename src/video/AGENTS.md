# Video player

`rediwm-video` (`src/video_main.zig`) plays one local file per window. It
calls FFmpeg's libraries directly through the `c_av` module (`src/c/av.h`);
the plan and its decisions are in `docs/plans/video-player.md`.

* **Decode on the compositor's device.** The render node comes from
  linux-dmabuf feedback `main_device` (`feedback.zig`, `hw.renderNode`), never
  the first node found: hybrid laptops have one VAAPI driver per GPU, and a
  buffer from the other GPU is a cross-device import.
* **Check feedback before creating a buffer.** On linux-dmabuf v4+ an
  unadvertised format/modifier is a protocol error, and so is a failed
  `create_immed`. `buffers.zig` uses asynchronous `create` once per new VA
  surface. A refusal restarts the pipeline in software at the current time.
* **One `wl_buffer` per VA surface, kept.** The compositor caches its
  EGLImage on the buffer (`scene_pass_yuv.c`); a buffer per frame would
  re-import every frame. Count `Created GL FBO` lines in the compositor log:
  one per surface at start, none during playback. A buffer holds a clone of
  its frame until `release`, so the decoder can't write a surface on screen.
  The decode worker calls `vaSyncSurface` before it queues the frame or
  submits more packets. Waiting on the Wayland thread after decoding ahead
  can hang on NVIDIA VP9.
* **Export** with `vaExportSurfaceHandle` directly, once per surface, not
  `av_hwframe_map` per frame. Composed layers first (Intel, AMD); otherwise
  separate layers, recombined under the surface's fourcc (nvidia-vaapi-driver
  gives R8 + RG88 in two objects). All planes must share one modifier.
* **Pick a decoder with a VAAPI config** (`hw.decoderFor`): FFmpeg prefers
  libdav1d for AV1, which has no hardware path; the native `av1` decoder does.
* **Hardware frames crop on the left/top only through `crop_left/crop_top`:**
  FFmpeg already subtracts the right/bottom crop from `width/height`. H.264
  surfaces are 16-line aligned (960x544 for 540p); the viewport source crops.
* **Colour:** matrix and range go through `wp_color_representation_v1`, only
  as pairs the compositor advertised. An untagged stream is BT.709 at HD sizes
  and BT.601 below (mpv's convention). Test clips must be tagged *and*
  converted with the matching matrix (`scale=out_color_matrix=bt709`), or the
  reference and the player disagree in green.
* **Workers own their FFmpeg contexts.** The demuxer owns the format after
  probe. Each decoder owns its codec and audio owns the resampler. Packet
  queues, the six-picture queue and the generation share a mutex. A seek
  stops the device before resetting the PCM ring and wakes every blocked
  producer. A paused seek primes video alone so a long audio lead cannot
  block the preview. Resume starts both streams from that target. A seek
  before the first video timestamp uses the audio index to preserve the
  introduction. Check the generation again before publishing decoded work.
* **The device callback is lock-free.** Its input is 48 kHz stereo f32 in
  timestamped blocks. The playhead includes silence through underruns so a
  short audio stream cannot stall the demuxer behind a full video queue.
  Only the noninstalled integration fixture selects the paced null device.
* **Local playback** sets FFmpeg's protocol whitelist to `file`.
* **Idle makes no wakeups.** Play and seek use one-shot timerfd deadlines
  and worker eventfds. Pause and EOF stop audio and disarm the timer.
  `zig build test-video-integration` measures all player threads.

* **Controls are a desynchronized ARGB subsurface.** Its empty input region
  sends pointer events to the root. `osd.zig` translates them into widget
  coordinates, paints only on free shm buffers, and gates repainting on a
  single frame callback. The hide and single-click deadlines share the
  player's timerfd. Unmap the strip with a null attach and restore the
  cursor with the current pointer-enter serial.
* **Scrubbing and frame steps use presentation timestamps.** A scrub owns
  playback until release, previews the preceding keyframe and finishes with
  an exact seek. A backward step starts one stream tick before the displayed
  PTS so the preceding GOP is available at keyframe boundaries.
* **File selection and drops are event-driven.** Poll the Files chooser's
  child handle and the URI-list pipe with Wayland. Negotiate copy only and
  finish the offer after opening a local file. Stage the new pipeline before
  retiring the old one. When both have audio, stop the device and join the
  old producer before reusing the ring with the new worker wake descriptors.
