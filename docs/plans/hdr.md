# Plan: HDR output

Status: decided 2026-11-24 (D1-D6 take the recommended options); Phases 1-3
and 5 built, Phase 3 not yet tried on an HDR display (none was available);
Phase 4 next. See Progress at the end. Written 2026-11-16 from the outside
audit in discussion #27 (github.com/oxydizer/rediwm/discussions/27). Its
author could not read `src/`, so this version checks its assumptions against
our code and the wlroots 0.20.2 source, and folds in the changes.

Scope: HDR10 output (PQ, BT.2020) on DRM outputs, an SDR white level, and
color-management-v1 content (HDR video, games) on top of it. Out of scope:
ICC profiles, HLG output, HDR on nested or headless sessions (the host or
backend decides those), wide gamut without HDR.

## Decision: opt-in HDR in the GLES2 pass, no Vulkan

HDR is a per-output setting, **off by default**, implemented in our own GLES2
output pass. The audit's recommended path stays (its Path B). Its Path A, a
port to wlroots' Vulkan renderer, is dropped, and so is the variant of making
Vulkan an opt-in renderer just for HDR:

* **Our pass is our own code.** `rediwm_scene_pass_begin`
  (`src/scene_pass.h:21`) is our own GLES2 implementation of the wlroots render
  pass interface: about 260 raw GL calls in `scene_pass*.c`, and our own GLSL
  programs for rounded and polygon shapes, sectors, shadows, dimming, glass
  backdrops and ribbons. Even a plain `wlr_render_pass_add_texture` runs our
  code, not wlroots'.
* **Vulkan would not do the colour work for us.** wlroots' HDR math (transfer
  function decode, primaries, the FP16 blend image, the output encode) lives
  inside its private Vulkan render pass. The public Vulkan API
  (`include/wlr/render/vulkan.h`) only hands out the instance, physical device,
  device and queue family, plus a texture's image attributes. An opt-in Vulkan
  mode would be a second implementation of our pass in Vulkan, and we would
  still write the colour math ourselves.
* **Two renderers forever.** Every effect (glow, dimming, flames, polygon
  shapes, glass) would be written twice, or HDR mode would lack it. The
  integration suites run GLES2 on llvmpipe; Vulkan would need lavapipe and a
  second set of reference screenshots.
* **Not live, not per output.** The renderer is chosen once at startup
  (`src/wlr/renderer.zig:39`), and one renderer serves every output, so
  turning HDR on would need a compositor restart and would move SDR monitors
  to Vulkan too. On GLES2, HDR switches per output while running: an image
  description, a render format and a shader variant.

Revisit only if wlroots drops its GLES2 renderer.

## What the code says

Verified 2026-11-16 on master (df0b032) and wlroots 0.20.2; re-checked
2026-11-24 on c738a87 (still wlroots 0.20.2), with corrections marked:

* **The DRM side does not depend on the renderer** (the audit's highest risk,
  its Phase 0 go/no-go). `wlr_output_state_set_image_description` is checked
  only against `supported_primaries` and `supported_transfer_functions`
  (wlroots `types/output/output.c:703`). These come from the EDID and the
  connector's `Colorspace` and `HDR_OUTPUT_METADATA` properties
  (`backend/drm/util.c:97-106`). The atomic commit sets both properties from
  the description (`backend/drm/atomic.c:384-392`), and `max bpc` follows a
  10-bit render format (`max_bpc_for_format`). No wlroots patch is needed.
* **Stale HDR state is reset.** Every atomic commit writes `Colorspace` and
  `HDR_OUTPUT_METADATA` from the connector's cached state, which starts at
  zero. A compositor that crashed in HDR, or a greeter that follows a session
  in HDR, comes up in SDR on its first commit.
* **GLES2 can hold the formats.** wlroots' GLES2 format table has
  `XBGR2101010`/`ABGR2101010` and `XBGR16161616F`/`ABGR16161616F`, gated by
  `EXT_texture_type_2_10_10_10_REV` and the half-float extensions
  (`render/gles2/pixel_format.c`). Rendering into a 10-bit dmabuf and an FP16
  texture also needs `EXT_color_buffer_half_float`; Phase 0 checks it on our
  drivers.
* **The protocols are advertised but SDR-only.** `src/extra_protocols.c:254-265`
  builds the colour manager's lists from the renderer, and GLES2 reports no
  input colour transforms, so the transfer function and primaries lists are
  empty and `parametric` is off. `rediwm_surface_edge_is_srgb` and
  `node_surface.c` already read per-surface descriptions; nothing draws
  differently with them.
* **The output format is never set.** `wlr_output_configure_primary_swapchain`
  (now `src/scene_output_async.c:184`, moved with the tearing swapchain)
  picks the default 8-bit format; the `setRenderFormat` binding exists
  (`src/wlr/output.zig:208`) but is unused.
* **Glass blurs encoded values.** `scene_pass_backdrop.c` never linearizes.
  Client glass from ext-background-effect (`src/background_effect.c`,
  d929bdc) feeds the same glass engine and backdrop pass, so it needs no
  separate linear path.
* **The hardware cursor would be wrong.** wlroots colour-converts a cursor
  for an HDR output by passing `color_transform` to the cursor's render pass
  (`types/output/cursor.c:259`), but the GLES2 renderer ignores that option
  (`features.output_color_transform = false`, never read in `render/gles2/`).
  An sRGB cursor would go out as PQ.
* **Output capture would be wrong.** Output screencopy and ext-image-copy
  copy the committed buffer through the renderer with no conversion. Window
  capture (`src/capture/window_source.zig`) renders through our pass and can
  render SDR directly.
* **Direct scanout already checks colour** (corrected 2026-11-24; the first
  draft said it did not). `try_scanout` (`src/scene_output.c:102`) has, since
  the owned pass (96b7eb0), compared the surface's transfer function and
  primaries with the output's committed image description, allowed only sRGB
  or gamma 2.2 sRGB where there is none, and refused YCbCr. It does not
  compare mastering luminance, which is acceptable for HDR10.
* **Night light uses the KMS gamma table** (`src/output/frame.zig`, the
  `color_transform` in the output state). On a PQ signal that table is wrong.
  Since d929bdc wlr-gamma-control clients also write that table through
  `src/output/gamma.zig`; their ramps are wrong on PQ too (D6).

## Off means off

With every output at `hdr = off`, nothing changes for anyone:

* No HDR GL program is compiled. HDR programs are built on demand like the
  polygon ones, since each linked program costs about 140 KiB of RSS.
* No FP16 buffers, 8-bit render format, no image description in any commit.
* Frames with only sRGB surfaces are byte-identical to today's (scene-pass
  tests plus a before/after screenshot diff), and idle CPU and RAM stay at the
  baseline.

The one possible exception is D3 (what the colour manager advertises).

## Pipeline when on

Per HDR output:

1. **Blend in linear light into an FP16 buffer.** It is retained, so it is
   only redrawn where there is damage. Primaries are BT.2020 (D1), and 1.0 is
   the SDR white level (D2).
2. **Inputs convert on sampling.** sRGB textures (shell buffers, Cairo text,
   wallpaper, X11 clients, sRGB Wayland clients) get unpremultiplied, decoded,
   converted from BT.709 to BT.2020, scaled by the white level and
   premultiplied again. Theme colours (`col.Straight`) and analytic draws
   (rects, shadows, the veil, dim) get the same treatment in their uniforms.
   Surfaces with a parametric description (Phase 4) decode their own transfer
   function and primaries.
3. **Glass blurs in linear light**, in FP16 backdrop images.
4. **Encode** the damaged region from the FP16 buffer into the
   `XRGB2101010` swapchain buffer: gamut clip, PQ encode, and night light as
   a linear-light RGB multiply. The age damage of the swapchain buffer is
   re-encoded from the retained FP16 buffer, so nothing is drawn twice.
5. **Commit** the image description (PQ, BT.2020, mastering luminance from
   the EDID) with the frame through `Output.commitFrameState`, as a commit
   reason in `commitIsRedundant`.

Memory when on: about 8 bytes per pixel extra for the FP16 buffer (about
63 MiB at 3840x2160), FP16 glass backdrops, and the HDR programs. The 10-bit
swapchain is the same size as the 8-bit one. This is the main reason HDR is
opt-in.

Side channels:

* **Cursor:** HDR outputs use the software cursor
  (`wlr_output_lock_software_cursors`) until wlroots' GLES2 renderer honours
  pass colour transforms or we render cursor buffers ourselves. The software
  cursor is drawn by our pass (`scene_output_effects.c`), so it gets step 2.
* **Direct scanout:** on an HDR output, allowed only for a surface whose
  description matches the output's. `try_scanout` already does this once
  the output commits its description; Phase 3 only adds a test for it.
* **Gamma ramps:** night light becomes a linear-light multiply in the encode
  (step 4). A wlr-gamma-control client's ramp is refused on an HDR output
  (D6); it gets the protocol's `failed` event, as on an output without a
  gamma table.
* **Capture:** an owned output capture source that renders the output through
  the pass in SDR mode into the client's 8-bit buffer. This follows how
  `WindowCaptureSource` replaced wlroots' helper. Capture clients only ever
  see SDR formats. IPC screenshots also get SDR, with a raw option for pixel
  probe tests.
* **Xwayland:** X11 clients are sRGB and composited at the white level.
* **Lock screen:** SDR content at the white level, on the same output state
  (no mode flip on lock).
* **Greeter:** never sets HDR, whatever the output config says.
* **Brightness:** laptop panels with HDR keep backlight control; the white
  level is separate from brightness.

## Decisions

Decided 2026-11-24: every decision takes the recommended option. The
alternatives are kept for the record.

* **D1, working primaries: BT.2020.** It is the signal's gamut, and the
  encode is then just a clip and PQ. (Rejected: BT.709 with negative values,
  scRGB-style; cheaper for an all-sRGB desktop, but the encode needs a
  matrix.)
* **D2, SDR white level: per output**, since the setting already lives on the
  output: `sdr_white`, default 203 nits (BT.2408 reference white), 80-1000 in
  the config, capped below the EDID's peak once Phase 3 reads it.
* **D3, colour manager when HDR is off.** Its lists are global and sent when a
  client binds, not per output. Once Phase 4 lands: advertise parametric
  support always, send each surface its output's description as preferred
  (sRGB on SDR outputs, so well-behaved clients send SDR there), and tone map
  with a cheap clip and knee, built on demand, if HDR content lands on an SDR
  output anyway. (Rejected: advertising only when some output has HDR at
  startup; it keeps today's protocol behaviour exactly but needs a restart
  after turning HDR on.)
* **D4, `auto`: not yet.** Ship `off`/`on` first, as an enum so `auto` (on
  when the EDID says PQ) can be added after tone mapping and brightness have
  been seen on several monitors.
* **D5, blend look: accept linear blending.** Translucency and antialiased
  edges (window_bg 0.80, shadows, text) look slightly different from the SDR
  path, which blends encoded values; other HDR compositors do the same.
  (Rejected: blending SDR content in an encoded space and converting after;
  exact match, but HDR content then blends wrongly.)
* **D6, gamma ramps on HDR outputs: refused** (added 2026-11-24 with
  wlr-gamma-control). A ramp is written for an SDR signal, and the hardware
  table must stay neutral under PQ. The client gets `failed`; night light
  keeps working in the encode. (Rejected: applying the ramp to the
  linear-light value in the encode; no client writes ramps for that.)
* **Where the linear pass runs without an HDR signal.** With `hdr = "on"`, a
  DRM output that cannot signal HDR stays SDR, unchanged. Headless and nested
  outputs run the linear pass with an sRGB encode instead: that is how
  Phase 2 is checked, by the integration suites and in a nested window, with
  no test hook. Settings offers the HDR switch only where the output can
  signal it.

## Phases

Each phase ends testable on real hardware, and the work can stop after any of
them with a working compositor. Week counts are rough guesses for one person.

| Phase | Work | Exit check | Est. |
|---|---|---|---|
| 0. Hardware recon | `drm_info` (`Colorspace`, `HDR_OUTPUT_METADATA`, plane formats) and `edid-decode` (static metadata, luminance) on the test monitor; GL extensions for 10-bit and FP16 rendering on Intel/AMD/NVIDIA; read wlroots' `supported_*` bits for the output. The code-side questions are answered above. | Written list of what the test monitor and drivers support | 2-3 days |
| 1. Plumbing | `hdr = off/on` and `sdr_white` in `[[outputs]]` (`config/output_config.zig`, `output_save.zig`), IPC `set_output_config` and `rediwm-msg output-config`, IPC output state, the Settings display page (`control_center/sections/display.zig`, "Not supported by this display" when the output cannot do HDR), `Output.applyAndPersist`. Same path as `adaptive_sync` (8f6f223). No rendering change. | Config round-trips; Settings shows availability; frames unchanged | 1 wk |
| 2. Linear pass | FP16 blend buffer, input conversion for every draw kind, theme colours, linear glass, software cursor; HDR programs on demand. Encode back to sRGB for now (headless and nested outputs, see the last decision). | With HDR on in a headless or nested session, the output looks like SDR within D5's tolerance (screenshot diff); off is byte-identical | 2-3 wks |
| 3. Encode and scan out | PQ encode, `XRGB2101010` render format with a test-commit fallback, image description commit and commit reason, night light in the encode, D6's ramp refusal, software cursor lock, a test of the existing scanout gate, `sdr_white` capped from the EDID. | PQ test pattern and a known HDR still correct on a real monitor; toggling HDR drops no frames | 2 wks |
| 4. Client content | Parametric descriptions backed by the pass (sRGB, gamma 2.2, linear, PQ, BT.2020) replacing the renderer lists in `extra_protocols.c`; per-surface decode; preferred description per output; color-representation-v1 YCbCr coefficients and range; D3's tone map. dmabuf and explicit sync paths unchanged. | mpv, a Proton HDR game (Wayland driver) and browser HDR video right under HDR and cleanly SDR elsewhere | 2-3 wks |
| 5. Side channels | Owned output capture source in SDR, IPC screenshot SDR/raw, lock and greeter rules, mixed HDR/SDR outputs and the camera across them. | grim, wf-recorder, OBS and portal sharing look right with HDR on; every row of the README protocol table is correct under HDR or documented SDR-only | 1-2 wks |
| 6. Hardening | Hardware checklist in `TESTING.md` (nested and headless cannot exercise HDR), pixel probes through the raw IPC read, idle CPU and RAM re-measured with HDR off and on. | HDR off at the baseline; HDR on cost written down | 1 wk |

## Risks

* **Drivers.** HDR needs atomic KMS and both connector properties; NVIDIA and
  older kernels differ. FP16 render targets are an extension in GLES2.
* **Tone mapping and brightness.** Other compositors kept iterating after
  first shipping. The audit cites GNOME 48's notes that HDR often disables
  hardware brightness on laptops (not checked here).
* **Owning colour science.** Transfer functions, gamut maps and PQ encode are
  ours to get right; wlroots' Vulkan shaders (`render/vulkan/shaders/`) are a
  reference, not code we can call.
* **Cost when on.** FP16 doubles blend and backdrop memory and bandwidth.
  Measure after Phase 2, not at the end.
* **Test coverage.** Everything past Phase 2 needs a real HDR monitor, which
  makes regressions easy to miss. Phase 6's raw probes are the guard.
* **No HDR monitor yet.** On 2026-11-24 the only display on the development
  laptop is its eDP panel (BOE, i915), whose EDID has 8 bits per colour and
  no HDR static metadata. Phases 1 and 2 can be built and checked on it;
  Phase 0 and Phases 3-6 wait for an external HDR monitor.

## Progress

* 2026-11-24: plan re-checked against c738a87 and decided (D1-D6).
* 2026-11-24, Phase 1 built (on d929bdc): `[[outputs]] hdr = "off"|"on"`
  and `sdr_white` (config, `output_save`, `Patch`), `output/hdr.zig`
  (mode, white level, `supported` from wlroots' `supported_*` bits, `active`
  = a committed image description), IPC `set_output_config` (parsing moved
  to `ipc/protocol_params_output.zig`) and outputs `hdr`, `hdr_supported`,
  `hdr_active`, `sdr_white`, `rediwm-msg output-config --hdr/--sdr-white`,
  and an HDR card in Settings > Displays: "Not supported by this display",
  or Off/On, the white level while on, and a note that output stays SDR
  until Phase 3. wlr-output-management has no HDR field, so clients cannot
  change it. Tests: `loader_sections_tests`, `ipc_tests`, the serializer
  fixture, `tests/wlr_protocols.py` (round trip, refusals, saved file) and
  `tests/control_center.py` (headless card). The Settings switch itself
  only appears on an HDR display, so it has no automated test.
* 2026-11-24, Phase 2 built: linear blending, encoded back to sRGB.
  * Pass: `scene_pass_linear.c` builds, the first time an output asks, the
    `LINEAR` twins of the shaped programs (every colour read goes through
    `LIN()`: unpremultiply, gamma 2.2, BT.709 to BT.2020, premultiply; the
    dim and glass saturation use BT.2020 luminance and the gamma-2.2
    equivalent of the brightness step), a twin of the ribbon program, and the
    encode (BT.2020 to BT.709, clip, gamma 1/2.2). The renderer probes an FP16
    format that renders (ES 3 sized, OES sized, OES unsized) and needs
    bilinear FP16 for glass (ES 3 or `OES_texture_half_float_linear`). Glass
    scratch and kept blurs are FP16 in linear passes; a blur records its
    encoding, and compositing it in a pass of the other kind fails the pass.
  * Output: `rediwm_scene_output_set_linear` keeps an FP16 image per output.
    Each frame draws only `pending_commit_damage` into it, then encodes the
    swapchain buffer's age damage, so nothing is drawn twice; a new or
    resized image, scan-out or a failed frame makes the next frame draw it
    whole. Switching repaints the output and re-takes its glass. The damage
    audit skips linear frames.
  * Zig: `output/hdr.zig` `linearWanted` (hdr on, not the greeter, and
    headless, nested or HDR10-capable) is applied before every build
    (`Server.buildOutputState`, so captures too) and at once on a settings
    change (`syncAll`). IPC outputs gain `hdr_linear`.
  * Checked: `scene_pass_test_linear.c` (opaque round trip, linear blend
    against the formula, kept image, partial encode, nothing after the
    encode, dim, glass in FP16 and the encoding guard, with and without
    vertex arrays); `tests/hdr_linear.py` at scale 1 and 1.5 (live switch,
    wallpaper within 3 levels, off gives back the frame from before, and
    damage-only frames equal a full redraw byte for byte); HDR-off frames are
    byte-identical to the build before Phase 2 at scale 1 and 1.5;
    `glass_reblur.py`, `wlr_protocols.py`, unit tests, Debug, ReleaseSafe and
    `-Ddamage-audit` builds.
  * Look (D5): translucent light colours over dark (the start menu outline,
    the taskbar button backing) come out a little lighter, glass spreads
    bright colours further, text edges differ by a few levels. Saturated
    colours can move by up to 3 levels in a channel near zero: the BT.2020 to
    sRGB conversion reaches it by cancellation, FP16 leaves about 3e-5, and
    gamma 2.2 is steep near black. PQ output (Phase 3) does not show this.
  * Cost when on (Debug build, headless 1280x720 on the Intel iGPU, the glass
    start menu open, the pointer sweeping): GPU per frame 1.12-1.13 ms off,
    1.24-1.29 ms on at the median (+10-15 %); CPU per frame within noise.
    Memory: the FP16 image is 8 bytes per pixel (7 MiB at 1280x720, 63 MiB at
    3840x2160) plus FP16 glass scratch and about six programs (140 KiB each),
    only while some output is linear; the image is freed when it switches off.
  * Not in Phase 2: the software cursor lock and everything else that only
    matters with a PQ signal is Phase 3. The software cursor already goes
    through the pass, so it is decoded like everything else.
  * Found on the way, failing before Phase 2 too: `test-scene-pass`'s
    `ribbon_gate` since the flame restyle in 475817c (the linear gates run
    before it), `tests/glass_hold.py` ("mixed-scale desktop keeps
    repainting"), and `tests/control_center.py`'s window resize check.
* 2026-11-24, Phase 3 built without an HDR display (the user chose to go
  ahead); everything below that needs the real signal is unverified.
  * `output/hdr_policy.zig` decides per frame: the signal when the setting is
    on, the output blends linear, is DRM, takes PQ and BT.2020 and is lit. A
    refusal (every test commit fails, two failed commits, or a commit the
    driver takes without showing it) holds until the mode or the setting
    changes; a switch off is retried until it holds. Unit-tested.
  * `output/hdr.zig` `prepare`, from `runFrame` before the build, test-commits
    XRGB2101010, then XBGR2101010, with the image description (PQ, BT.2020
    primaries, mastering luminance and MaxCLL/MaxFALL from the EDID's
    suggested range, zero when unknown), puts them on the frame state and
    switches the encode for that frame. The switch counts in
    `commitIsRedundant`; `committed` (from `commitFrameState`) counts only
    commits that carry it. The gamma table changes hands in the switching
    commit.
  * Encode: one program, mode sRGB or PQ (ST 2084, 1.0 at the SDR white over
    10000 cd/m², clipped), after a linear BT.2020 matrix. Night light on the
    signal is that matrix (`night_light/color.zig` `hdrAdjust`: the white
    point the gamma table would apply, as linear gain under gamma 2.2, in
    BT.2020); the per-output `gamma` setting does not apply under the signal.
  * `sdr_white` is capped at the desired content maximum luminance in the
    EDID's CTA-861 HDR static metadata block (`output/edid_hdr.zig`, read from
    sysfs once, unit-tested). Displays that describe HDR only in DisplayID
    blocks get no cap.
  * Software cursors are locked while the signal is on; client gamma ramps
    fail (D6), at the switch and on later requests.
  * IPC outputs gain `hdr_refused`; the Settings note says HDR is
    experimental, or that the display refused it.
  * Checked: the PQ encode against the ST 2084 formula (white level, grey,
    sRGB red in the BT.2020 container, the matrix first, a bad white level,
    8- and 10-bit buffers) in `scene_pass_test_linear.c`; the policy, EDID
    parser and night light matrix in unit tests; `ImageDescription`'s layout
    in `test-wlroots`; the headless suites (`hdr_linear.py`,
    `night_light.py`, `wlr_protocols.py`, `greeter.py`). Not checked:
    anything on a real DRM HDR output, including that wlroots' test commit
    allocates a buffer for a render format change as expected, and the
    existing scan-out gate under a committed description (no headless output
    can commit one).
  * First run on an HDR display: `rediwm-msg outputs` shows `hdr_supported`;
    with `hdr = "on"` the log says "HDR10 on" and `hdr_active` turns true
    (or `hdr_refused`, with the reason logged); the display reports HDR in its
    own menu; SDR white looks like the `sdr_white` setting and follows it;
    night light tints without the gamma table; gammastep is refused; the
    cursor looks right; switching drops no frames; turning it off returns to
    SDR; grim, a portal screen share and the screenshot tool show SDR colours.
* 2026-11-24, Phase 5 (captures) built before Phase 4, so that turning HDR on
  breaks no screenshot or screen share.
  * Every output whose frames come from the linear pass is captured from an
    sRGB encode of its FP16 image (`rediwm_scene_output_sdr_copy`: an 8-bit
    ARGB8888 buffer per output, encoded at most once per build), not from its
    committed buffer. Headless outputs follow the same rule, where both are
    the same picture: that is how the paths are tested.
  * ext-image-copy-capture: `capture_sdr.c` wraps the `impl` of wlroots'
    output source when a session starts; `copy_frame` copies the SDR encode
    (`wlr_ext_image_copy_capture_frame_v1_copy_buffer`, then `ready`) and
    everything else, cursor sessions included, is wlroots'. Wrapped sources
    are resolved to their output through the module, since
    `wlr_output_try_from_ext_image_capture_source_v1` checks the `impl`.
  * wlr-screencopy: `guardScreencopy` hands each requested frame on a linear
    output to the module, which replaces the frame's private commit listener;
    at the commit it copies the SDR encode (shm by `wlr_texture_read_pixels`,
    dmabuf by a render pass) and sends flags, damage (the whole box) and
    ready. A frame that finds the output no longer linear goes back to
    wlroots' handler. Both hooks depend on wlroots 0.20 internals.
  * The screenshot tool and IPC `sample_pixels` read the SDR encode;
    `sample_pixels` takes `raw` for the buffer the output sends (pixel probes
    of PQ). `rediwm-msg perf` counts `capture_sdr_copies`.
  * Checked by `tests/hdr_linear.py` on a headless linear output: screencopy,
    grim, ext-image-copy-capture in shm and dmabuf buffers all match the
    screen and are counted, an output without HDR counts none, and HDR on one
    of two outputs leaves the other byte-identical.
  * Lock and greeter: capture is refused while locked or authenticating
    before any of this runs; the greeter never blends linearly.
  * Open: copies are SDR as encoded for an SDR display, so an HDR source
    looks clipped in a capture once Phase 4 draws HDR content; screencopy
    `copy_with_damage` frames on a linear output complete at every commit
    with full damage instead of waiting for damage.

## Sources

* Discussion #27, the original audit.
* wlroots 0.20.2: `types/output/output.c`, `types/output/cursor.c`,
  `backend/drm/atomic.c`, `backend/drm/util.c`, `render/gles2/`,
  `include/wlr/render/pass.h`, `include/wlr/render/vulkan.h`.
* Jay compositor HDR docs (the OpenGL renderer has no colour management):
  docs.rs/crate/jay-compositor/1.15.0/source/book/src/hdr.md.
* ITU-R BT.2408 (203 nit reference white).
