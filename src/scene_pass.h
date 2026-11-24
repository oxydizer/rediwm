// GLES2 drawing for the owned scene output pass. The caller owns output policy
// (damage, culling, feedback, swapchain and commit). Using the wlroots pass
// interface also lets software cursors use the same pass.
#pragma once
#include <stdbool.h>
#include <wlr/render/pass.h>
#include <wlr/util/box.h>

struct rediwm_scene_renderer;
struct rediwm_ribbon;
bool rediwm_scene_renderer_set_ribbons(struct rediwm_scene_renderer *, bool);
void rediwm_scene_pass_add_ribbon(struct wlr_render_pass *, struct wlr_box,
    const struct rediwm_ribbon *, const pixman_region32_t *, float, struct wlr_texture *);
// The renderer must be GLES2 and outlive this object and all its passes.
struct rediwm_scene_renderer *rediwm_scene_renderer_create(struct wlr_renderer *);
void rediwm_scene_renderer_destroy(struct rediwm_scene_renderer *);
// Exactly one pass at a time. Submit even after a draw fails: submit reports
// the failure and restores the GL/EGL state. Destination and texture lifetimes
// follow wlr_renderer_begin_buffer_pass. No timers or output colour transforms
// are supported; non-NULL requests fail instead of silently ignoring them.
struct wlr_render_pass *rediwm_scene_pass_begin(struct rediwm_scene_renderer *,
    struct wlr_buffer *, const struct wlr_buffer_pass_options *);

// Stage 4b of docs/plans/scene-graph.md: rounded-rectangle shapes. One shape
// clips every piece of a window (titlebar, client, border, shadow), and each
// piece is a draw that names the shape, so they agree on the arc to the last bit
// and there is no per-piece corner approximation. Plain add_rect/add_texture
// calls are unchanged and never touch these programs.
//
// All numbers are device pixels of the destination buffer, in the same space as
// `box` of the draws (y down, row 0 first). The caller snaps the box (see
// rediwm_edges_snap in scene_graph.h) and scales the radii and border; nothing
// is rounded here, so a fractional radius or border is drawn as given.
enum { REDIWM_PASS_POLY_MAX = 16 };
struct rediwm_pass_sector {
  float center[2]; // device pixels from the shape box's corner
  float radii[2]; // inner, outer; outer 0 disables the sector
  float axis[2]; // unit direction of the sector's centre line
  float half_angle[2]; // cosine, sine of half its span (0 < span <= pi)
};
struct rediwm_pass_shape {
  struct wlr_box box;
  // Top-left, top-right, bottom-right, bottom-left. A radius larger than half
  // the short side is capped to it.
  float radii[4];
  // A polygon instead of the rounded rectangle when `poly_count` is 3 or more:
  // its vertices in device pixels from the box's corner, and `radii` is not used.
  // Simple, no two neighbouring vertices the same, either winding.
  int poly_count;
  float poly[REDIWM_PASS_POLY_MAX][2];
  // A circular annular sector instead of either outline above. Its outer and
  // inner arcs are analytic circles, so no tessellation reaches the image.
  struct rediwm_pass_sector sector;
  // Opt-in polar texture framing: the source top follows the outer arc and
  // source rows advance inward. Full source height in device pixels; 0 keeps
  // ordinary rectangular texture coordinates. Output reflection and transform
  // are tracked separately so the source is never rotated or mirrored twice.
  float sector_texture_height, sector_texture_flip;
  enum wl_output_transform sector_texture_transform;
  // With polar framing: the part of that image this texture fills, as fractions
  // of it (x, y, width, height), so several textures share one framing (a
  // window and its subsurfaces). Nothing is drawn outside it, the ring
  // included. A zero width is the whole image.
  float sector_texture_rect[4];
  // Width of the ring just inside the edge. The same fragment that draws the body
  // composites the ring over it, then applies the shape's coverage, so a
  // translucent border tints the fill beneath it, as the legacy border rects do,
  // and an opaque one equals splitting the pixel between body and ring exactly.
  // 0 draws no ring.
  float border;
  float border_color[4]; // premultiplied
  // A highlight over the ring near `glow_center` (device pixels from the box's
  // corner): `glow_color` (premultiplied) fades with the distance to
  // `glow_radius`, and past the ring it reaches `glow_depth` inward. 0 radius: none.
  float glow_center[2];
  float glow_radius, glow_depth;
  float glow_color[4];
};
struct rediwm_pass_shadow {
  float offset_x, offset_y; // how far the shadow is shifted from the shape
  // Full strength inside the moved shape, falling to nothing this far outside it
  // with a smoothstep, as the CPU chrome's shadow does; below 0.25 it is 0.25.
  float softness;
  float color[4];           // premultiplied, at full strength under the shape's edge
  // Keep the shadow out of the shape, so a translucent window does not show it.
  bool hide_inside;
  const pixman_region32_t *clip; // damage, as for any draw; NULL for everything
};

// Builds the shaped programs, which cost the driver about 430 KiB and are
// therefore not made with the renderer. Call it once, outside a pass, before the
// first shaped draw; later calls return the first result. False when they did not
// build: shaped draws then fail the pass at submit, plain drawing is unaffected.
bool rediwm_scene_renderer_enable_shapes(struct rediwm_scene_renderer *);
// Builds the program that draws external textures, which only imported client
// buffers are, so a process with no clients (the greeter) skips its compile. Call it
// outside a pass, before the first such draw; later calls return the first result.
// False when it did not build. Without it an external draw fails the pass.
bool rediwm_scene_renderer_enable_external(struct rediwm_scene_renderer *);
// Builds the programs that draw polygons or circular sectors, which are the
// shaped ones with the polygon distance compiled in: another 280 KiB or so, so only
// on request, outside a pass, before the first such draw. False when they did not
// build; a polygon draw then fails the pass, so callers must not make one.
bool rediwm_scene_renderer_enable_polygons(struct rediwm_scene_renderer *);

// These take a pass from rediwm_scene_pass_begin only (a wlroots pass is a
// programming error). `box` of the options is the piece to draw; the shape is
// what clips it, so a piece is usually a part of the shape's box.
//
// Edges are anti-aliased by multiplying the piece's premultiplied colour by the
// shape's pixel coverage, so the blend mode must be PREMULTIPLIED wherever the
// shape's edge crosses the piece. NONE is only right inside the part of the shape
// that is fully covered (see rediwm_clip_opaque in scene_graph.h).
void rediwm_scene_pass_add_rect_shaped(struct wlr_render_pass *,
    const struct wlr_render_rect_options *, const struct rediwm_pass_shape *);
void rediwm_scene_pass_add_texture_shaped(struct wlr_render_pass *,
    const struct wlr_render_texture_options *, const struct rediwm_pass_shape *);
// The shape's shadow. The quad reaches the softness and the offset past the box.
void rediwm_scene_pass_add_shadow(struct wlr_render_pass *, const struct rediwm_pass_shape *,
    const struct rediwm_pass_shadow *);

// Takes this fraction (0 to 1) of the brightness and of the colour away from every
// rect, texture and backdrop composite that follows, shaped or not, until it is set
// again; 0 and 0 is how a pass starts, and what the caller restores after the item
// it was set for, so what is drawn next (the software cursor) is never graded.
// Colour is pulled toward the pixel's luminance, then everything is scaled, on
// premultiplied values, so a translucent pixel keeps its alpha. A shadow is not
// graded. A fraction outside 0 to 1 fails the pass at submit.
void rediwm_scene_pass_set_dim(struct wlr_render_pass *, float brightness, float saturation);

// Stage 5b of docs/plans/scene-graph.md: backdrop effects (glass). An effect
// blurs what the pass has drawn so far under a region and composites it through
// its shape, under the surface it backs. The blur is kept between frames in a
// `rediwm_backdrop`, owned by the caller, so an effect is re-blurred only when
// what lies below it changed (stage 5, D1); compositing a kept blur is cheap.
struct rediwm_backdrop;
// Builds the blur program (about 140 KiB), outside a pass. Requires
// rediwm_scene_renderer_enable_shapes, whose program composites. Later calls
// return the first result; without it, backdrop calls fail the pass.
bool rediwm_scene_renderer_enable_backdrops(struct rediwm_scene_renderer *);
// Frees a backdrop's GL resources; outside a pass. NULL is a no-op.
void rediwm_scene_renderer_destroy_backdrop(struct rediwm_scene_renderer *, struct rediwm_backdrop *);
// Draws what lies below an effect into an image of `region` (device pixels of
// this pass's buffer) reduced by `factor` (at least 1; glass uses 4 times the
// output scale, a quarter of the logical size, as glass.c did): from here to
// rediwm_scene_pass_end_backdrop every draw of this pass lands in that image,
// which starts black. The caller draws the items below the effect, bottom up,
// clipped as it likes; nothing reaches the buffer meanwhile.
void rediwm_scene_pass_begin_backdrop(struct wlr_render_pass *, struct wlr_box region, float factor);
// Blurs that image with a Gaussian of `sigma` device pixels into `*backdrop`
// (created if NULL) and returns drawing to the buffer. Beyond the buffer's edge
// the blur replicates it.
void rediwm_scene_pass_end_backdrop(struct wlr_render_pass *, struct rediwm_backdrop **, float sigma);
struct rediwm_pass_backdrop {
  const struct rediwm_backdrop *backdrop;
  float saturation; // 1 leaves colours as they are
  float opacity;    // the effect's, times the shape's coverage
  // The surface drawn over the effect, whose alpha the effect makes up to the
  // coverage (its alpha a: the effect draws (coverage - a) / (1 - a)), so the pair
  // is exactly as opaque as the shape and a curved edge is not covered twice.
  // NULL when nothing is drawn over it.
  struct wlr_texture *front;
  struct wlr_box front_box; // where `front` is drawn, whole texture, untransformed
  float front_opacity;
  const pixman_region32_t *clip;
};
// Composites `backdrop` through `shape` over `box` (device pixels).
void rediwm_scene_pass_add_backdrop(struct wlr_render_pass *, const struct rediwm_pass_shape *,
    struct wlr_box box, const struct rediwm_pass_backdrop *);

// Phase 2 of docs/plans/hdr.md: blending in linear light. A linear pass draws
// into an FP16 image of the buffer (`rediwm_linear_target`, kept by the caller
// between frames so only damage is redrawn) with programs that decode every
// colour they read (textures, rects, rings, shadows, ribbons) from sRGB as
// displayed (gamma 2.2) to linear BT.2020, 1.0 at SDR white, and blur glass in
// FP16 too. rediwm_scene_pass_encode then writes chosen parts of that image to
// the buffer, the last thing the pass does. Draws, backdrops and blurs are the
// same calls as in any pass; a blur keeps the encoding it was taken in, and
// compositing it in a pass of the other kind fails the pass.
struct rediwm_linear_target;
// Builds the linear programs (about 140 KiB each: one per base program built so
// far, the encode and the ribbon's twin), outside a pass; later calls return the
// first result. False when the renderer has no renderable FP16 format or the
// programs did not build: linear passes cannot begin then.
bool rediwm_scene_renderer_enable_linear(struct rediwm_scene_renderer *);
// Makes `*target` an FP16 image of `width` x `height` (creating it if NULL),
// outside a pass. `*fresh` says its contents are new and undefined: the next
// pass must draw all of it. False on failure; `*target` is then still the
// caller's to destroy.
bool rediwm_scene_renderer_ensure_linear_target(struct rediwm_scene_renderer *,
    struct rediwm_linear_target **target, int width, int height, bool *fresh);
void rediwm_scene_renderer_destroy_linear_target(struct rediwm_scene_renderer *, struct rediwm_linear_target *);
// As rediwm_scene_pass_begin, drawing into `target`, which must be the buffer's size.
struct wlr_render_pass *rediwm_scene_pass_begin_linear(struct rediwm_scene_renderer *,
    struct wlr_buffer *, const struct wlr_buffer_pass_options *, struct rediwm_linear_target *target);
// How a linear pass is encoded into the buffer. NULL is sRGB with no adjustment.
struct rediwm_pass_encode {
  // HDR10: SMPTE ST 2084 (PQ) on BT.2020, for a buffer of 10 bits a channel
  // and an output that commits that image description. Else sRGB as displayed
  // (gamma 2.2, BT.709).
  bool pq;
  float sdr_white; // cd/m² that 1.0 (SDR white) is sent at under PQ, 1 to 10000
  // Applied to linear BT.2020 first, column-major (night light on an HDR
  // output, whose gamma table must stay neutral). All zero is the identity.
  float adjust[9];
};
// Encodes `region` (device pixels) of the target into the buffer. Once per
// linear pass, outside a backdrop; any draw after it fails the pass.
void rediwm_scene_pass_encode(struct wlr_render_pass *, const pixman_region32_t *region,
    const struct rediwm_pass_encode *);
