// Per-output state: see scene_outputs.h.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_outputs.h"
#include <assert.h>
#include <stdlib.h>
#include <time.h>
#include <wlr/backend.h>
#include <wlr/backend/drm.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/util/region.h>
#include <wlr/util/transform.h>

#ifdef REDIWM_FRAME_TRACE
static struct {
  struct wlr_output *output;
  uint64_t first_ns, last_ns;
} trace_slots[8];

static uint64_t trace_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void rediwm_trace_damage(struct wlr_output *output) {
  for (size_t i = 0; i < 8; i++) {
    if (trace_slots[i].output != output && trace_slots[i].output != NULL) continue;
    trace_slots[i].output = output;
    trace_slots[i].last_ns = trace_now_ns();
    if (trace_slots[i].first_ns == 0) trace_slots[i].first_ns = trace_slots[i].last_ns;
    return;
  }
}

uint64_t rediwm_trace_take_damage(struct wlr_output *output, uint64_t *last_ns) {
  for (size_t i = 0; i < 8; i++) {
    if (trace_slots[i].output != output) continue;
    uint64_t first = trace_slots[i].first_ns;
    *last_ns = trace_slots[i].last_ns;
    trace_slots[i].first_ns = trace_slots[i].last_ns = 0;
    return first;
  }
  *last_ns = 0;
  return 0;
}
#endif

void rediwm_scene_output_damage(struct rediwm_scene_output *out, const pixman_region32_t *damage) {
  struct wlr_output *output = out->output;

  pixman_region32_t clipped;
  pixman_region32_init(&clipped);
  pixman_region32_intersect_rect(&clipped, damage, 0, 0, output->width, output->height);

  if (!pixman_region32_empty(&clipped)) {
    rediwm_trace_damage(output);
    wlr_output_schedule_frame(output);
    wlr_damage_ring_add(&out->damage_ring, &clipped);
    pixman_region32_union(&out->pending_commit_damage, &out->pending_commit_damage, &clipped);
  }

  pixman_region32_fini(&clipped);
}

void rediwm_scene_output_damage_whole(struct rediwm_scene_output *out) {
  wlr_damage_ring_add_whole(&out->damage_ring);
  pixman_region32_union_rect(&out->pending_commit_damage, &out->pending_commit_damage, 0, 0,
                             out->output->width, out->output->height);
  rediwm_trace_damage(out->output);
  wlr_output_schedule_frame(out->output);
}

bool rediwm_scene_output_needs_frame(const struct rediwm_scene_output *out) {
  return out->output->needs_frame || !pixman_region32_empty((pixman_region32_t *)&out->pending_commit_damage);
}

bool rediwm_scene_output_has_pending_damage(const struct rediwm_scene_output *out) {
  return !pixman_region32_empty((pixman_region32_t *)&out->pending_commit_damage);
}

static void output_commit(struct wl_listener *listener, void *data) {
  struct rediwm_scene_output *out = wl_container_of(listener, out, output_commit);
  struct wlr_output_event_commit *event = data;
  const struct wlr_output_state *state = event->state;

  // If the output has been committed with a certain damage, we know that region will be
  // acknowledged by the backend so we don't need to keep track of it anymore.
  if (state->committed & WLR_OUTPUT_STATE_BUFFER) {
    if (state->committed & WLR_OUTPUT_STATE_DAMAGE) {
      pixman_region32_subtract(&out->pending_commit_damage, &out->pending_commit_damage, &state->damage);
    } else {
      pixman_region32_fini(&out->pending_commit_damage);
      pixman_region32_init(&out->pending_commit_damage);
    }
  }

  // A new mode, or the output coming on, changes what every pixel shows. (Which surfaces
  // are on it is the projection's to work out each frame.)
  if (state->committed & (WLR_OUTPUT_STATE_TRANSFORM | WLR_OUTPUT_STATE_SCALE |
                          WLR_OUTPUT_STATE_SUBPIXEL | WLR_OUTPUT_STATE_MODE | WLR_OUTPUT_STATE_ENABLED))
    rediwm_scene_output_damage_whole(out);
}

static void output_damage(struct wl_listener *listener, void *data) {
  struct rediwm_scene_output *out = wl_container_of(listener, out, output_damage);
  struct wlr_output *output = out->output;
  struct wlr_output_event_damage *event = data;

  int width, height;
  wlr_output_transformed_resolution(output, &width, &height);

  pixman_region32_t damage;
  pixman_region32_init(&damage);
  pixman_region32_copy(&damage, event->damage);
  wlr_region_transform(&damage, &damage, wlr_output_transform_invert(output->transform), width, height);
  rediwm_scene_output_damage(out, &damage);
  pixman_region32_fini(&damage);
}

static void output_needs_frame(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_scene_output *out = wl_container_of(listener, out, output_needs_frame);
  rediwm_trace_damage(out->output);
  wlr_output_schedule_frame(out->output);
}

static void layout_output_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_scene_output *out = wl_container_of(listener, out, layout_output_destroy);
  wl_list_remove(&out->layout_output_destroy.link);
  wl_list_init(&out->layout_output_destroy.link);
  out->layout_output = NULL;
}

static void set_position(struct rediwm_scene_output *out, int x, int y) {
  if (out->x == x && out->y == y) return;
  out->x = x;
  out->y = y;
  rediwm_scene_output_damage_whole(out);
}

static void layout_changed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_scene_outputs *outputs = wl_container_of(listener, outputs, layout_change);
  struct rediwm_scene_output *out;
  wl_list_for_each(out, &outputs->outputs, link) {
    if (out->layout_output) set_position(out, out->layout_output->x, out->layout_output->y);
  }
}

static void layout_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_scene_outputs *outputs = wl_container_of(listener, outputs, layout_destroy);
  wl_list_remove(&outputs->layout_change.link);
  wl_list_init(&outputs->layout_change.link);
  wl_list_remove(&outputs->layout_destroy.link);
  wl_list_init(&outputs->layout_destroy.link);
  outputs->layout = NULL;
}

static void color_manager_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_scene_outputs *outputs = wl_container_of(listener, outputs, color_manager_destroy);
  wl_list_remove(&outputs->color_manager_destroy.link);
  wl_list_init(&outputs->color_manager_destroy.link);
  outputs->color_manager_v1 = NULL;
}

static bool env_enabled(const char *name) {
  const char *value = getenv(name);
  return value && value[0] && value[0] != '0';
}

struct rediwm_scene_outputs *rediwm_scene_outputs_create(struct wlr_output_layout *layout) {
  struct rediwm_scene_outputs *outputs = calloc(1, sizeof(*outputs));
  if (!outputs) return NULL;
  wl_list_init(&outputs->outputs);
  outputs->direct_scanout = !env_enabled("WLR_SCENE_DISABLE_DIRECT_SCANOUT");
  wl_list_init(&outputs->color_manager_destroy.link);
  outputs->layout = layout;
  outputs->layout_change.notify = layout_changed;
  wl_signal_add(&layout->events.change, &outputs->layout_change);
  outputs->layout_destroy.notify = layout_destroyed;
  wl_signal_add(&layout->events.destroy, &outputs->layout_destroy);
  return outputs;
}

void rediwm_scene_outputs_destroy(struct rediwm_scene_outputs *outputs) {
  if (!outputs) return;
  struct rediwm_scene_output *out, *tmp;
  wl_list_for_each_safe(out, tmp, &outputs->outputs, link) rediwm_scene_output_destroy(out);
  if (outputs->layout) {
    wl_list_remove(&outputs->layout_change.link);
    wl_list_remove(&outputs->layout_destroy.link);
  }
  // The manager outlives this and would walk a freed listener when the display goes.
  wl_list_remove(&outputs->color_manager_destroy.link);
  free(outputs);
}

void rediwm_scene_outputs_set_color_manager(struct rediwm_scene_outputs *outputs,
                                            struct wlr_color_manager_v1 *manager) {
  wl_list_remove(&outputs->color_manager_destroy.link);
  wl_list_init(&outputs->color_manager_destroy.link);
  outputs->color_manager_v1 = manager;
  if (!manager) return;
  outputs->color_manager_destroy.notify = color_manager_destroyed;
  wl_signal_add(&manager->events.destroy, &outputs->color_manager_destroy);
}

static void addon_destroyed(struct wlr_addon *addon) {
  struct rediwm_scene_output *out = wl_container_of(addon, out, addon);
  rediwm_scene_output_destroy(out);
}

static const struct wlr_addon_interface output_addon_impl = {
    .name = "rediwm_scene_output",
    .destroy = addon_destroyed,
};

struct rediwm_scene_output *rediwm_scene_output_create(struct rediwm_scene_outputs *outputs,
                                                       struct wlr_output *output,
                                                       struct wlr_output_layout_output *layout_output) {
  struct rediwm_scene_output *out = calloc(1, sizeof(*out));
  if (!out) return NULL;

  out->output = output;
  out->outputs = outputs;
  wlr_damage_ring_init(&out->damage_ring);
  pixman_region32_init(&out->pending_commit_damage);

  // The lowest free index, with the list kept in index order.
  int prev_index = -1;
  struct wl_list *prev_link = &outputs->outputs;
  struct rediwm_scene_output *current;
  wl_list_for_each(current, &outputs->outputs, link) {
    if (prev_index + 1 != current->index) break;
    prev_index = current->index;
    prev_link = &current->link;
  }

  int drm_fd = wlr_backend_get_drm_fd(output->backend);
  if (drm_fd >= 0 && output->backend->features.timeline && output->renderer != NULL &&
      output->renderer->features.timeline) {
    out->in_timeline = wlr_drm_syncobj_timeline_create(drm_fd);
    out->out_timeline = wlr_drm_syncobj_timeline_create(drm_fd);
    if (out->in_timeline == NULL || out->out_timeline == NULL) {
      wlr_drm_syncobj_timeline_unref(out->in_timeline);
      wlr_drm_syncobj_timeline_unref(out->out_timeline);
      wlr_damage_ring_finish(&out->damage_ring);
      pixman_region32_fini(&out->pending_commit_damage);
      free(out);
      return NULL;
    }
  }

  out->index = prev_index + 1;
  assert(out->index < 64);
  wl_list_insert(prev_link, &out->link);
  wlr_addon_init(&out->addon, &output->addons, outputs, &output_addon_impl);
  wl_signal_init(&out->events.destroy);

  out->output_commit.notify = output_commit;
  wl_signal_add(&output->events.commit, &out->output_commit);
  out->output_damage.notify = output_damage;
  wl_signal_add(&output->events.damage, &out->output_damage);
  out->output_needs_frame.notify = output_needs_frame;
  wl_signal_add(&output->events.needs_frame, &out->output_needs_frame);

  wl_list_init(&out->layout_output_destroy.link);
  if (layout_output) {
    out->layout_output = layout_output;
    out->layout_output_destroy.notify = layout_output_destroyed;
    wl_signal_add(&layout_output->events.destroy, &out->layout_output_destroy);
    out->x = layout_output->x;
    out->y = layout_output->y;
  }
  rediwm_scene_output_damage_whole(out);
  return out;
}

void rediwm_scene_output_destroy(struct rediwm_scene_output *out) {
  if (!out) return;
  wl_signal_emit_mutable(&out->events.destroy, NULL);

  wlr_addon_finish(&out->addon);
  wlr_damage_ring_finish(&out->damage_ring);
  pixman_region32_fini(&out->pending_commit_damage);
  wl_list_remove(&out->link);
  wl_list_remove(&out->output_commit.link);
  wl_list_remove(&out->output_damage.link);
  wl_list_remove(&out->output_needs_frame.link);
  wl_list_remove(&out->layout_output_destroy.link);
  if (out->in_timeline != NULL) {
    wlr_drm_syncobj_timeline_signal(out->in_timeline, UINT64_MAX);
    wlr_drm_syncobj_timeline_unref(out->in_timeline);
  }
  if (out->out_timeline != NULL) {
    wlr_drm_syncobj_timeline_signal(out->out_timeline, UINT64_MAX);
    wlr_drm_syncobj_timeline_unref(out->out_timeline);
  }
  free(out);
}

struct rediwm_scene_output *rediwm_scene_outputs_get(struct rediwm_scene_outputs *outputs,
                                                     struct wlr_output *output) {
  struct wlr_addon *addon = wlr_addon_find(&output->addons, outputs, &output_addon_impl);
  if (!addon) return NULL;
  struct rediwm_scene_output *out = wl_container_of(addon, out, addon);
  return out;
}
