// Client surfaces in the own scene: see node_surface.h. The logic is wlroots' own
// (types/scene/surface.c, wlroots 0.20, MIT licensed), moved onto own nodes;
// node_subsurface_tree.c and node_xdg_shell.c port the rest of types/scene.
// wlroots 0.20 ABI, pinned by build.zig.zon (as in projection.c).
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "node_surface.h"
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_color_representation_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_presentation_time.h>
#include "scene_outputs.h"
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include <wlr/util/transform.h>

// ---- The surface -----------------------------------------------------------------

static double get_surface_preferred_buffer_scale(struct wlr_surface *surface) {
  double scale = 1;
  struct wlr_surface_output *surface_output;
  wl_list_for_each(surface_output, &surface->current_outputs, link) {
    if (surface_output->output->scale > scale) scale = surface_output->output->scale;
  }
  return scale;
}

// Output used for frame pacing (surface frame callbacks, presentation time feedback,
// etc), may be NULL.
static struct wlr_output *get_surface_frame_pacing_output(struct wlr_surface *surface) {
  struct wlr_output *frame_pacing_output = NULL;
  struct wlr_surface_output *surface_output;
  wl_list_for_each(surface_output, &surface->current_outputs, link) {
    if (!surface_output->private.suspended &&
        (frame_pacing_output == NULL || surface_output->output->refresh > frame_pacing_output->refresh))
      frame_pacing_output = surface_output->output;
  }
  return frame_pacing_output;
}

struct wlr_output *rediwm_surface_frame_pacing_output(struct wlr_surface *surface) {
  return get_surface_frame_pacing_output(surface);
}

static int get_tf_preference(enum wlr_color_transfer_function tf) {
  switch (tf) {
  case WLR_COLOR_TRANSFER_FUNCTION_GAMMA22:
    return 0;
  case WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ:
    return 1;
  case WLR_COLOR_TRANSFER_FUNCTION_BT1886:
  case WLR_COLOR_TRANSFER_FUNCTION_SRGB:
  case WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR:
    return -1;
  }
  abort(); // unreachable
}

static int get_primaries_preference(enum wlr_color_named_primaries primaries) {
  switch (primaries) {
  case WLR_COLOR_NAMED_PRIMARIES_SRGB:
    return 0;
  case WLR_COLOR_NAMED_PRIMARIES_BT2020:
    return 1;
  }
  abort(); // unreachable
}

static void get_surface_preferred_image_description(struct wlr_surface *surface,
                                                    struct wlr_image_description_v1_data *out) {
  struct wlr_output_image_description preferred = {
      .transfer_function = WLR_COLOR_TRANSFER_FUNCTION_GAMMA22,
      .primaries = WLR_COLOR_NAMED_PRIMARIES_SRGB,
  };

  struct wlr_surface_output *surface_output;
  wl_list_for_each(surface_output, &surface->current_outputs, link) {
    const struct wlr_output_image_description *img_desc = surface_output->output->image_description;
    if (img_desc == NULL) continue;
    if (get_tf_preference(preferred.transfer_function) < get_tf_preference(img_desc->transfer_function))
      preferred.transfer_function = img_desc->transfer_function;
    if (get_primaries_preference(preferred.primaries) < get_primaries_preference(img_desc->primaries))
      preferred.primaries = img_desc->primaries;
  }

  *out = (struct wlr_image_description_v1_data){
      .tf_named = wlr_color_manager_v1_transfer_function_from_wlr(preferred.transfer_function),
      .primaries_named = wlr_color_manager_v1_primaries_from_wlr(preferred.primaries),
  };
}

static void handle_scene_buffer_outputs_update(struct wl_listener *listener, void *data) {
  struct rediwm_surface *surface = wl_container_of(listener, surface, outputs_update);
  struct rediwm_outputs_update_event *event = data;
  struct rediwm_scene_outputs *scene = surface->buffer->node.scene->outputs;

  // If the surface is no longer visible on any output in the scene, keep the last sent
  // preferred configuration to avoid unnecessary redraws.
  bool suspend = event->size == 0;

  // To avoid sending redundant leave/enter events when a surface is hidden and then
  // shown without moving to a different output the following policy is implemented:
  //
  // 1. When a surface transitions from being visible on >0 outputs to being visible on 0
  //    outputs don't send any leave events.
  //
  // 2. When a surface transitions from being visible on 0 outputs to being visible on >0
  //    outputs send leave events for all entered outputs on which the surface is no
  //    longer visible as well as enter events for any outputs not already entered.
  struct wlr_surface_output *entered_output, *tmp;
  wl_list_for_each_safe(entered_output, tmp, &surface->surface->current_outputs, link) {
    bool active = false;
    for (size_t i = 0; i < event->size; i++) {
      if (entered_output->output == event->active[i]->output) {
        active = true;
        break;
      }
    }

    struct rediwm_scene_output *scene_output;
    if (scene) wl_list_for_each(scene_output, &scene->outputs, link) {
      if (scene_output->output == entered_output->output) {
        entered_output->private.suspended = suspend;
        if (!suspend && !active) wlr_surface_send_leave(surface->surface, entered_output->output);
        break;
      }
    }
  }

  // No reason to update the preferred configuration if we aren't sending leave/enter
  // events.
  if (suspend) return;

  for (size_t i = 0; i < event->size; i++) {
    // This function internally checks if an enter event was already sent for the output
    // to avoid sending redundant events.
    wlr_surface_send_enter(surface->surface, event->active[i]->output);
  }

  double scale = get_surface_preferred_buffer_scale(surface->surface);
  wlr_fractional_scale_v1_notify_scale(surface->surface, scale);
  wlr_surface_set_preferred_buffer_scale(surface->surface, ceil(scale));

  if (scene && scene->color_manager_v1 != NULL) {
    struct wlr_image_description_v1_data img_desc = {0};
    get_surface_preferred_image_description(surface->surface, &img_desc);
    wlr_color_manager_v1_set_surface_preferred_image_description(scene->color_manager_v1,
                                                                 surface->surface, &img_desc);
  }
}

static void handle_scene_buffer_output_sample(struct wl_listener *listener, void *data) {
  struct rediwm_surface *surface = wl_container_of(listener, surface, output_sample);
  const struct rediwm_output_sample_event *event = data;
  struct wlr_output *output = event->output->output;
  if (get_surface_frame_pacing_output(surface->surface) != output) return;

  if (event->direct_scanout)
    wlr_presentation_surface_scanned_out_on_output(surface->surface, output);
  else
    wlr_presentation_surface_textured_on_output(surface->surface, output);

  struct wlr_linux_drm_syncobj_surface_v1_state *syncobj_surface_state =
      wlr_linux_drm_syncobj_v1_get_surface_state(surface->surface);
  if (syncobj_surface_state != NULL && event->release_timeline != NULL) {
    wlr_linux_drm_syncobj_v1_state_add_release_point(syncobj_surface_state, event->release_timeline,
                                                     event->release_point, output->event_loop);
  }
}

static void handle_scene_buffer_frame_done(struct wl_listener *listener, void *data) {
  struct rediwm_surface *surface = wl_container_of(listener, surface, frame_done);
  struct rediwm_frame_done_event *event = data;
  if (get_surface_frame_pacing_output(surface->surface) != event->output->output) return;

  wlr_surface_send_frame_done(surface->surface, &event->when);
}

static void scene_surface_handle_surface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_surface *surface = wl_container_of(listener, surface, surface_destroy);
  rediwm_node_destroy(&surface->buffer->node);
}

// This is used for wlr_scene where it unconditionally locks buffers preventing reuse of
// the existing texture for shm clients. With the usage pattern of surface handling, we
// can mark its locked buffer as safe for mutation.
static void client_buffer_mark_next_can_damage(struct wlr_client_buffer *buffer) {
  buffer->private.n_ignore_locks++;
}

static void unmark_client_buffer(struct rediwm_buffer *scene_buffer) {
  if (!scene_buffer->buffer) return;

  struct wlr_client_buffer *buffer = wlr_client_buffer_get(scene_buffer->buffer);
  if (!buffer) return;

  // If the buffer was a single-pixel buffer where we cached its color then it won't have
  // been marked as damage-allowed.
  if (buffer->private.n_ignore_locks > 0) buffer->private.n_ignore_locks--;
}

static int min(int a, int b) { return a < b ? a : b; }

static void surface_reconfigure(struct rediwm_surface *scene_surface) {
  struct rediwm_buffer *scene_buffer = scene_surface->buffer;
  struct wlr_surface *surface = scene_surface->surface;
  struct wlr_surface_state *state = &surface->current;

  struct wlr_fbox src_box;
  wlr_surface_get_buffer_source_box(surface, &src_box);

  pixman_region32_t opaque;
  pixman_region32_init(&opaque);
  pixman_region32_copy(&opaque, &surface->opaque_region);

  int width = state->width;
  int height = state->height;

  if (!wlr_box_empty(&scene_surface->clip)) {
    struct wlr_box *clip = &scene_surface->clip;

    int buffer_width = state->buffer_width;
    int buffer_height = state->buffer_height;
    width = min(clip->width, width - clip->x);
    height = min(clip->height, height - clip->y);

    wlr_fbox_transform(&src_box, &src_box, state->transform, buffer_width, buffer_height);
    wlr_output_transform_coords(state->transform, &buffer_width, &buffer_height);

    src_box.x += (double)(clip->x * src_box.width) / state->width;
    src_box.y += (double)(clip->y * src_box.height) / state->height;
    src_box.width *= (double)width / state->width;
    src_box.height *= (double)height / state->height;

    wlr_fbox_transform(&src_box, &src_box, wlr_output_transform_invert(state->transform),
                       buffer_width, buffer_height);

    pixman_region32_translate(&opaque, -clip->x, -clip->y);
    pixman_region32_intersect_rect(&opaque, &opaque, 0, 0, width, height);
  }

  if (width <= 0 || height <= 0) {
    rediwm_buffer_set_buffer(scene_buffer, NULL);
    pixman_region32_fini(&opaque);
    return;
  }

  float opacity = 1.0;
  const struct wlr_alpha_modifier_surface_v1_state *alpha_modifier_state =
      wlr_alpha_modifier_v1_get_surface_state(surface);
  if (alpha_modifier_state != NULL) opacity = (float)alpha_modifier_state->multiplier;

  enum wlr_color_transfer_function tf = WLR_COLOR_TRANSFER_FUNCTION_GAMMA22;
  enum wlr_color_named_primaries primaries = WLR_COLOR_NAMED_PRIMARIES_SRGB;
  const struct wlr_image_description_v1_data *img_desc =
      wlr_surface_get_image_description_v1_data(surface);
  if (img_desc != NULL) {
    tf = wlr_color_manager_v1_transfer_function_to_wlr(img_desc->tf_named);
    primaries = wlr_color_manager_v1_primaries_to_wlr(img_desc->primaries_named);
  }

  enum wlr_color_encoding color_encoding = WLR_COLOR_ENCODING_NONE;
  enum wlr_color_range color_range = WLR_COLOR_RANGE_NONE;
  const struct wlr_color_representation_v1_surface_state *color_repr =
      wlr_color_representation_v1_get_surface_state(surface);
  if (color_repr != NULL) {
    if (color_repr->coefficients != 0)
      color_encoding = wlr_color_representation_v1_color_encoding_to_wlr(color_repr->coefficients);
    if (color_repr->range != 0)
      color_range = wlr_color_representation_v1_color_range_to_wlr(color_repr->range);
  }

  rediwm_buffer_set_opaque_region(scene_buffer, &opaque);
  rediwm_buffer_set_source_box(scene_buffer, &src_box);
  rediwm_buffer_set_dest_size(scene_buffer, width, height);
  rediwm_buffer_set_transform(scene_buffer, state->transform);
  rediwm_buffer_set_opacity(scene_buffer, opacity);
  // The colour description has no setters of its own: the buffer set below reports it.
  scene_buffer->transfer_function = tf;
  scene_buffer->primaries = primaries;
  scene_buffer->color_encoding = color_encoding;
  scene_buffer->color_range = color_range;

  // A commit that attached nothing and damaged nothing shows the same content. Setting
  // the buffer again would report the node changed and build a whole frame for a
  // client that only asked for a frame callback (the lock mark below nets to zero).
  if (surface->buffer && scene_buffer->buffer == &surface->buffer->base &&
      !(state->committed & WLR_SURFACE_STATE_BUFFER) &&
      !pixman_region32_not_empty(&surface->buffer_damage)) {
    pixman_region32_fini(&opaque);
    return;
  }

  unmark_client_buffer(scene_buffer);

  if (surface->buffer) {
    // If we've cached the buffer's single-pixel buffer color then any in-place updates
    // to the texture wouldn't be reflected in rendering. So only allow in-place texture
    // updates if it's not a single pixel buffer. Note that we can't use the cached
    // scene_buffer->is_single_pixel_buffer because that's only set later on.
    bool is_single_pixel_buffer = false;
    if (surface->buffer->source != NULL) {
      struct wlr_single_pixel_buffer_v1 *spb =
          wlr_single_pixel_buffer_v1_try_from_buffer(surface->buffer->source);
      is_single_pixel_buffer = spb != NULL;
    }
    if (!is_single_pixel_buffer) client_buffer_mark_next_can_damage(surface->buffer);

    struct wlr_linux_drm_syncobj_surface_v1_state *syncobj_surface_state =
        wlr_linux_drm_syncobj_v1_get_surface_state(surface);

    struct rediwm_buffer_options options = {
        .damage = &surface->buffer_damage,
    };
    if (syncobj_surface_state != NULL) {
      options.wait_timeline = syncobj_surface_state->acquire_timeline;
      options.wait_point = syncobj_surface_state->acquire_point;
    }
    rediwm_buffer_set_buffer_with_options(scene_buffer, &surface->buffer->base, &options);
  } else {
    rediwm_buffer_set_buffer(scene_buffer, NULL);
  }

  pixman_region32_fini(&opaque);
}

static void handle_scene_surface_surface_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_surface *surface = wl_container_of(listener, surface, surface_commit);

  surface_reconfigure(surface);

  // If the surface has requested a frame done event, honour that. The frame_callback_list
  // will be populated in this case. We should only schedule the frame however if the node
  // is enabled and there is an output intersecting, otherwise the frame done events would
  // never reach the surface anyway.
  bool enabled = rediwm_node_coords(&surface->buffer->node, NULL, NULL);
  struct wlr_output *output = get_surface_frame_pacing_output(surface->surface);
  if (!wl_list_empty(&surface->surface->current.frame_callback_list) && output && enabled) {
    struct rediwm_scene *scene = surface->buffer->node.scene;
    if (scene && scene->frame_callbacks)
      scene->frame_callbacks(output);
    else
      wlr_output_schedule_frame(output);
  }
}

static bool scene_buffer_point_accepts_input(struct rediwm_buffer *buffer, double *sx, double *sy) {
  struct rediwm_surface *scene_surface = buffer->surface;

  *sx += scene_surface->clip.x;
  *sy += scene_surface->clip.y;

  return wlr_surface_point_accepts_input(scene_surface->surface, *sx, *sy);
}

static void surface_node_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_surface *surface = wl_container_of(listener, surface, node_destroy);

  unmark_client_buffer(surface->buffer);
  surface->buffer->surface = NULL;
  surface->buffer->point_accepts_input = NULL;

  wl_list_remove(&surface->node_destroy.link);
  wl_list_remove(&surface->outputs_update.link);
  wl_list_remove(&surface->output_sample.link);
  wl_list_remove(&surface->frame_done.link);
  wl_list_remove(&surface->surface_destroy.link);
  wl_list_remove(&surface->surface_commit.link);

  free(surface);
}

struct rediwm_surface *rediwm_surface_create(struct rediwm_tree *parent, struct wlr_surface *wlr_surface) {
  struct rediwm_surface *surface = calloc(1, sizeof(*surface));
  if (surface == NULL) return NULL;

  struct rediwm_buffer *scene_buffer = rediwm_buffer_create(parent, NULL);
  if (!scene_buffer) {
    free(surface);
    return NULL;
  }

  surface->buffer = scene_buffer;
  surface->surface = wlr_surface;
  scene_buffer->surface = surface;
  scene_buffer->point_accepts_input = scene_buffer_point_accepts_input;

  surface->node_destroy.notify = surface_node_destroyed;
  wl_signal_add(&scene_buffer->node.events.destroy, &surface->node_destroy);

  surface->outputs_update.notify = handle_scene_buffer_outputs_update;
  wl_signal_add(&scene_buffer->events.outputs_update, &surface->outputs_update);

  surface->output_sample.notify = handle_scene_buffer_output_sample;
  wl_signal_add(&scene_buffer->events.output_sample, &surface->output_sample);

  surface->frame_done.notify = handle_scene_buffer_frame_done;
  wl_signal_add(&scene_buffer->events.frame_done, &surface->frame_done);

  surface->surface_destroy.notify = scene_surface_handle_surface_destroy;
  wl_signal_add(&wlr_surface->events.destroy, &surface->surface_destroy);

  surface->surface_commit.notify = handle_scene_surface_surface_commit;
  wl_signal_add(&wlr_surface->events.commit, &surface->surface_commit);

  surface_reconfigure(surface);

  return surface;
}

void rediwm_surface_set_clip(struct rediwm_surface *surface, const struct wlr_box *clip) {
  if (clip ? wlr_box_equal(clip, &surface->clip) : wlr_box_empty(&surface->clip)) return;

  if (clip)
    surface->clip = *clip;
  else
    surface->clip = (struct wlr_box){0};

  surface_reconfigure(surface);
}
