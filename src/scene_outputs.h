// What the compositor keeps per output besides the output itself (stage 7c of
// scene-graph work): where it sits in the layout, the damage the
// backend has not yet taken, the damage ring for its buffer swapchain, and the
// explicit-sync timelines. It replaces wlr_scene_output, wlr_scene_output_layout and
// the parts of wlr_scene that registered outputs (wlroots 0.20, MIT licensed; the
// handlers follow types/wlr_scene.c and types/scene/output_layout.c).
//
// The output pass (scene_output.c) draws from the projection and asks this for
// the damage to repaint; the frame loop asks `needs_frame`.
#pragma once
#include <pixman.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_damage_ring.h>
#include <wlr/util/addon.h>

struct wlr_output;
struct wlr_output_layout;
struct wlr_output_layout_output;
struct wlr_color_manager_v1;
struct wlr_drm_syncobj_timeline;
struct rediwm_scene_outputs;

struct rediwm_scene_output {
  struct wlr_output *output;
  struct wl_list link; // rediwm_scene_outputs.outputs, by index
  struct rediwm_scene_outputs *outputs;
  struct wlr_addon addon;
  struct wlr_damage_ring damage_ring;
  int x, y; // in the layout
  int index; // below 64: a bit in the projection's masks
  struct {
    struct wl_signal destroy;
  } events;
  // What was damaged and not yet committed with a buffer.
  pixman_region32_t pending_commit_damage;
  bool prev_scanout;
  // Explicit sync: the pass signals `in` when it has drawn, the scanout signals `out`.
  struct wlr_drm_syncobj_timeline *in_timeline, *out_timeline;
  uint64_t in_point, out_point;
  struct wlr_output_layout_output *layout_output; // NULL once the layout dropped it
  struct wl_listener layout_output_destroy, output_commit, output_damage, output_needs_frame;
};

struct rediwm_scene_outputs {
  struct wl_list outputs; // rediwm_scene_output.link
  // Scanning a client buffer out directly; WLR_SCENE_DISABLE_DIRECT_SCANOUT turns it off.
  bool direct_scanout;
  // For the preferred image description of surfaces; NULL until set.
  struct wlr_color_manager_v1 *color_manager_v1;
  struct wlr_output_layout *layout;
  struct wl_listener color_manager_destroy, layout_change, layout_destroy;
};

// What a buffer node reports (the structs wlr_scene emitted, with our outputs).
struct rediwm_outputs_update_event {
  struct rediwm_scene_output **active;
  size_t size;
};
struct rediwm_output_sample_event {
  struct rediwm_scene_output *output;
  bool direct_scanout;
  struct wlr_drm_syncobj_timeline *release_timeline;
  uint64_t release_point;
};
struct rediwm_frame_done_event {
  struct rediwm_scene_output *output;
  struct timespec when;
};

// Outputs follow `layout`: they take its positions as it changes.
struct rediwm_scene_outputs *rediwm_scene_outputs_create(struct wlr_output_layout *layout);
void rediwm_scene_outputs_destroy(struct rediwm_scene_outputs *);
void rediwm_scene_outputs_set_color_manager(struct rediwm_scene_outputs *, struct wlr_color_manager_v1 *);

// NULL on allocation failure. `layout_output` gives the position and keeps it current.
struct rediwm_scene_output *rediwm_scene_output_create(struct rediwm_scene_outputs *,
                                                       struct wlr_output *,
                                                       struct wlr_output_layout_output *layout_output);
void rediwm_scene_output_destroy(struct rediwm_scene_output *);
struct rediwm_scene_output *rediwm_scene_outputs_get(struct rediwm_scene_outputs *, struct wlr_output *);

// Damage in the output's device pixels (a frame is requested if any is on the buffer).
void rediwm_scene_output_damage(struct rediwm_scene_output *, const pixman_region32_t *);
void rediwm_scene_output_damage_whole(struct rediwm_scene_output *);
// Whether anything asks for a frame: the output itself, or damage not yet committed.
bool rediwm_scene_output_needs_frame(const struct rediwm_scene_output *);
bool rediwm_scene_output_has_pending_damage(const struct rediwm_scene_output *);

// Frame timing trace (-Dframe-trace, src/output/frame_trace.zig): when content last asked
// this output for a frame. A no-op in every other build.
#ifdef REDIWM_FRAME_TRACE
void rediwm_trace_damage(struct wlr_output *);
// The first damage since the last take (0 if none); `last_ns` gets the latest.
uint64_t rediwm_trace_take_damage(struct wlr_output *, uint64_t *last_ns);
#else
static inline void rediwm_trace_damage(struct wlr_output *output) { (void)output; }
#endif
