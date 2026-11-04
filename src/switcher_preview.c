// Live switcher thumbnails share client buffers, acquire points and GPU releases,
// but are not another surface view that changes preferred scale or output enters.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "switcher_preview.h"
#include "node.h"
#include "scene_outputs.h"
#include <assert.h>
#include <stdlib.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>

struct preview_binding {
  struct wlr_addon addon;
  struct rediwm_buffer *preview;
  struct wlr_surface *surface;
  struct wlr_client_buffer *marked;
  uint32_t commit_seq;
  struct wl_listener node_destroy, surface_destroy, output_sample;
};

static void unmark_buffer(struct preview_binding *binding) {
  if (!binding->marked) return;
  assert(binding->marked->private.n_ignore_locks > 0);
  binding->marked->private.n_ignore_locks--;
  binding->marked = NULL;
}

static void destroy_binding(struct wlr_addon *addon) {
  struct preview_binding *binding = wl_container_of(addon, binding, addon);
  unmark_buffer(binding);
  wl_list_remove(&binding->node_destroy.link);
  wl_list_remove(&binding->surface_destroy.link);
  wl_list_remove(&binding->output_sample.link);
  wlr_addon_finish(addon);
  free(binding);
}

static const struct wlr_addon_interface binding_impl = {
  .name = "rediwm switcher preview", .destroy = destroy_binding,
};

static void handle_node_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct preview_binding *binding = wl_container_of(listener, binding, node_destroy);
  // The node emits destroy before releasing content: remove the ignore-lock mark
  // now, while the client buffer is still alive, rather than during addon teardown.
  destroy_binding(&binding->addon);
}

static void handle_surface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct preview_binding *binding = wl_container_of(listener, binding, surface_destroy);
  rediwm_switcher_preview_set_surface(binding->preview, NULL);
}

static void handle_output_sample(struct wl_listener *listener, void *data) {
  struct preview_binding *binding = wl_container_of(listener, binding, output_sample);
  const struct rediwm_output_sample_event *event = data;
  if (!binding->surface || !event->release_timeline) return;
  // Commits and output rendering run synchronously on the Wayland event loop.
  // The caller updates the binding on each commit, before the next pass starts.
  assert(binding->commit_seq == binding->surface->current.seq);
  struct wlr_linux_drm_syncobj_surface_v1_state *state =
      wlr_linux_drm_syncobj_v1_get_surface_state(binding->surface);
  if (state) wlr_linux_drm_syncobj_v1_state_add_release_point(state,
      event->release_timeline, event->release_point, event->output->output->event_loop);
}

static struct preview_binding *find_binding(struct rediwm_buffer *preview) {
  struct wlr_addon *addon = wlr_addon_find(&preview->node.addons, NULL, &binding_impl);
  struct preview_binding *binding;
  return addon ? wl_container_of(addon, binding, addon) : NULL;
}

static struct preview_binding *create_binding(struct rediwm_buffer *preview) {
  struct preview_binding *binding = calloc(1, sizeof(*binding));
  if (!binding) return NULL;
  binding->preview = preview;
  wlr_addon_init(&binding->addon, &preview->node.addons, NULL, &binding_impl);
  wl_list_init(&binding->surface_destroy.link);
  binding->node_destroy.notify = handle_node_destroy;
  wl_signal_add(&preview->node.events.destroy, &binding->node_destroy);
  binding->surface_destroy.notify = handle_surface_destroy;
  binding->output_sample.notify = handle_output_sample;
  wl_signal_add(&preview->events.output_sample, &binding->output_sample);
  return binding;
}

static void follow_surface(struct preview_binding *binding, struct wlr_surface *surface) {
  if (binding->surface == surface) return;
  wl_list_remove(&binding->surface_destroy.link);
  wl_list_init(&binding->surface_destroy.link);
  binding->surface = surface;
  if (surface) wl_signal_add(&surface->events.destroy, &binding->surface_destroy);
}

bool rediwm_switcher_preview_set_owned(struct rediwm_buffer *preview,
                                       struct rediwm_buffer *source) {
  struct wlr_buffer *buffer = source ? source->buffer : NULL;
  if (!buffer) {
    rediwm_switcher_preview_set_surface(preview, NULL);
    return false;
  }
  struct preview_binding *binding = find_binding(preview);
  if (!binding && !(binding = create_binding(preview))) return false;
  follow_surface(binding, NULL);
  unmark_buffer(binding);
  // `rediwm_projection_present_owned` updates this client buffer in place while
  // nothing but ignorable locks hold it; the thumbnail's lock must stay one of them.
  struct wlr_client_buffer *client = wlr_client_buffer_get(buffer);
  if (client) {
    client->private.n_ignore_locks++;
    binding->marked = client;
  }
  rediwm_buffer_set_buffer(preview, buffer);
  return true;
}

bool rediwm_switcher_preview_set_surface(struct rediwm_buffer *preview,
                                         struct wlr_surface *surface) {
  struct preview_binding *binding = find_binding(preview);
  if (!binding) {
    if (!surface) {
      rediwm_buffer_set_buffer(preview, NULL);
      return true;
    }
    binding = create_binding(preview);
    if (!binding) return false;
  }
  follow_surface(binding, surface);
  unmark_buffer(binding);
  struct wlr_client_buffer *buffer = surface ? surface->buffer : NULL;
  struct rediwm_buffer_options options = {0};
  if (surface) {
    binding->commit_seq = surface->current.seq;
    options.damage = &surface->buffer_damage;
    struct wlr_linux_drm_syncobj_surface_v1_state *state =
        wlr_linux_drm_syncobj_v1_get_surface_state(surface);
    if (state) {
      options.wait_timeline = state->acquire_timeline;
      options.wait_point = state->acquire_point;
    }
  }
  if (buffer && (!buffer->source ||
      !wlr_single_pixel_buffer_v1_try_from_buffer(buffer->source))) {
    // Just like a surface node: a live thumbnail sees in-place shm updates.
    buffer->private.n_ignore_locks++;
    binding->marked = buffer;
  }
  rediwm_buffer_set_buffer_with_options(preview, buffer ? &buffer->base : NULL, &options);
  return true;
}
