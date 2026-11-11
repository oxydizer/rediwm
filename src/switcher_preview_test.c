// Preview lifetime and synchronization with real scene nodes, buffers and addons.
// Only the DRM timeline endpoints and client-buffer identification are mocked;
// this noninstalled fixture needs no renderer, output backend or DRM device.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "node.h"
#include "scene_outputs.h"
#include "switcher_preview.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>

static struct wlr_surface a, b, implicit;
static struct wlr_drm_syncobj_timeline acquire_a, acquire_b, release;
static struct wlr_linux_drm_syncobj_surface_v1_state state_a, state_b;
static int released, freed;
static struct wlr_linux_drm_syncobj_surface_v1_state *last_state;
static uint64_t last_point;
static struct wl_event_loop *last_loop;
struct wlr_linux_drm_syncobj_surface_v1_state *wlr_linux_drm_syncobj_v1_get_surface_state(struct wlr_surface *surface) {
  if (surface == &implicit) return NULL;
  assert(surface == &a || surface == &b);
  return surface == &a ? &state_a : &state_b;
}
bool wlr_linux_drm_syncobj_v1_state_add_release_point(struct wlr_linux_drm_syncobj_surface_v1_state *state, struct wlr_drm_syncobj_timeline *timeline, uint64_t point, struct wl_event_loop *loop) {
  assert(timeline == &release);
  released++;
  last_state = state;
  last_point = point;
  last_loop = loop;
  return true;
}
struct wlr_drm_syncobj_timeline *wlr_drm_syncobj_timeline_ref(struct wlr_drm_syncobj_timeline *timeline) {
  timeline->private.n_refs++;
  return timeline;
}
void wlr_drm_syncobj_timeline_unref(struct wlr_drm_syncobj_timeline *timeline) {
  if (!timeline) return;
  assert(timeline->private.n_refs > 0);
  timeline->private.n_refs--;
}
static void destroy_buffer(struct wlr_buffer *buffer) {
  struct wlr_client_buffer *client = (struct wlr_client_buffer *)buffer;
  assert(client->private.n_ignore_locks == 0);
  wlr_buffer_finish(buffer);
  freed++;
  free(buffer);
}
static const struct wlr_buffer_impl client_impl = {.destroy = destroy_buffer};
struct wlr_client_buffer *wlr_client_buffer_get(struct wlr_buffer *buffer) {
  return buffer->impl == &client_impl ? (struct wlr_client_buffer *)buffer : NULL;
}
static struct wlr_client_buffer *new_client(void) {
  struct wlr_client_buffer *client = calloc(1, sizeof(*client));
  assert(client);
  wlr_buffer_init(&client->base, &client_impl, 40, 30);
  wlr_buffer_lock(&client->base);
  wlr_buffer_drop(&client->base);
  return client;
}
static void init_surface(struct wlr_surface *surface) {
  wl_signal_init(&surface->events.destroy);
  wl_signal_init(&surface->events.commit);
  wl_list_init(&surface->current_outputs);
  pixman_region32_init_rect(&surface->buffer_damage, 0, 0, 40, 30);
  surface->buffer = new_client();
  surface->current.seq = 1;
}
int main(void) {
  init_surface(&a);
  init_surface(&b);
  init_surface(&implicit);
  state_a.acquire_timeline = &acquire_a;
  state_a.acquire_point = 11;
  state_b.acquire_timeline = &acquire_b;
  state_b.acquire_point = 22;
  struct rediwm_scene *scene = rediwm_scene_create(NULL, NULL);
  assert(scene);
  struct rediwm_buffer *preview = rediwm_buffer_create(&scene->tree, NULL);
  assert(preview);
  assert(rediwm_switcher_preview_set_surface(preview, NULL));
  assert(wl_list_empty(&preview->events.output_sample.listener_list));

  // Updating a commit replaces acquire points without accumulating locks/refs.
  assert(rediwm_switcher_preview_set_surface(preview, &a));
  assert(preview->buffer == &a.buffer->base);
  assert(preview->wait_timeline == &acquire_a && preview->wait_point == 11);
  assert(a.buffer->private.n_ignore_locks == 1 && acquire_a.private.n_refs == 1);
  assert(rediwm_switcher_preview_get_surface(preview) == &a);
  // A commit is followed without the caller: the binding listens for it.
  a.current.seq++;
  state_a.acquire_point = 12;
  wl_signal_emit_mutable(&a.events.commit, &a);
  assert(a.buffer->private.n_ignore_locks == 1 && acquire_a.private.n_refs == 1);
  assert(preview->wait_point == 12);
  struct wl_event_loop *loop = wl_event_loop_create();
  assert(loop);
  struct wlr_output output = {.event_loop = loop};
  struct rediwm_scene_output scene_output = {.output = &output};
  struct rediwm_output_sample_event sample = {.output = &scene_output, .release_timeline = &release, .release_point = 30};
  // Even an occluded source with no active outputs gets this GPU release fence.
  wl_signal_emit_mutable(&preview->events.output_sample, &sample);
  assert(released == 1 && last_state == &state_a && last_point == 30 && last_loop == loop);
  assert(wl_list_empty(&a.current_outputs));
  // Rebinding removes the old source's listener and releases its timeline/lock.
  assert(rediwm_switcher_preview_set_surface(preview, &b));
  assert(a.buffer->private.n_ignore_locks == 0 && b.buffer->private.n_ignore_locks == 1);
  assert(acquire_a.private.n_refs == 0 && acquire_b.private.n_refs == 1);
  assert(wl_list_empty(&a.events.destroy.listener_list) && wl_list_empty(&a.events.commit.listener_list));
  wl_signal_emit_mutable(&preview->events.output_sample, &sample);
  assert(released == 2 && last_state == &state_b);
  // Source-first teardown clears content but leaves the preview safe to reuse.
  wl_signal_emit_mutable(&b.events.destroy, NULL);
  assert(!preview->buffer && !preview->wait_timeline && b.buffer->private.n_ignore_locks == 0);
  assert(wl_list_empty(&b.events.destroy.listener_list) && wl_list_empty(&b.events.commit.listener_list));
  assert(!rediwm_switcher_preview_get_surface(preview));
  wl_signal_emit_mutable(&preview->events.output_sample, &sample);
  assert(released == 2);
  assert(rediwm_switcher_preview_set_surface(preview, &a));
  // Node-first teardown must detach the source listener before freeing the node.
  rediwm_node_destroy(&preview->node);
  assert(wl_list_empty(&a.events.destroy.listener_list) && wl_list_empty(&a.events.commit.listener_list));
  assert(a.buffer->private.n_ignore_locks == 0 && acquire_a.private.n_refs == 0);
  wl_signal_emit_mutable(&a.events.destroy, NULL);
  wlr_buffer_unlock(&a.buffer->base);
  wlr_buffer_unlock(&b.buffer->base);
  assert(freed == 2);

  // The node may own the final client-buffer lock: its ignore mark must be
  // removed before that lock destroys the buffer, not in late addon teardown.
  preview = rediwm_buffer_create(&scene->tree, NULL);
  assert(preview && rediwm_switcher_preview_set_surface(preview, &implicit));
  assert(!preview->wait_timeline && implicit.buffer->private.n_ignore_locks == 1);
  wl_signal_emit_mutable(&preview->events.output_sample, &sample);
  assert(released == 2);
  wlr_buffer_unlock(&implicit.buffer->base);
  implicit.buffer = NULL;
  rediwm_node_destroy(&preview->node);
  assert(freed == 3 && wl_list_empty(&implicit.events.destroy.listener_list));
  wl_signal_emit_mutable(&implicit.events.destroy, NULL);
  rediwm_scene_destroy(scene);
  pixman_region32_fini(&a.buffer_damage);
  pixman_region32_fini(&b.buffer_damage);
  pixman_region32_fini(&implicit.buffer_damage);
  wl_event_loop_destroy(loop);
  puts("preview binding lifecycle, acquire and release tests passed");
}
