// Explicit synchronization (wp_linux_drm_syncobj_v1) outside wlr_scene.
//
// A client using it commits a buffer before its GPU work is done and gets it
// back only once a release point signals. wlr_scene waits on the acquire point
// when it draws the buffer, and registers its render as a release point, but
// only on the surface's frame-pacing output. Glass backdrops and window
// capture sample client buffers in passes of their own, including buffers the
// outputs cull, and the edge probe reads them on the CPU. Without fences those
// reads race the client: drivers without implicit sync (NVIDIA) show stale or
// half-drawn pixels, and the client may reuse a buffer that is still being read.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "explicit_sync.h"
#include <stdint.h>
#include <stdlib.h>
#include <wayland-server-core.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <drm.h>

bool rediwm_explicit_sync_supported(struct wlr_renderer *renderer,
                                    bool backend_timeline) {
  return backend_timeline && renderer->features.timeline &&
         wlr_renderer_get_drm_fd(renderer) >= 0;
}

static struct wlr_linux_drm_syncobj_surface_v1_state *
acquire_state(struct wlr_surface *surface) {
  struct wlr_linux_drm_syncobj_surface_v1_state *state =
      surface ? wlr_linux_drm_syncobj_v1_get_surface_state(surface) : NULL;
  return state && state->acquire_timeline ? state : NULL;
}

bool rediwm_surface_explicit_sync(struct wlr_surface *surface) {
  return acquire_state(surface) != NULL;
}

struct rediwm_read_fence {
  struct wlr_drm_syncobj_timeline *timeline;
  struct wl_event_loop *loop;
  uint64_t point;
  bool armed;
  struct wl_array surfaces; // struct wlr_surface *
};

struct rediwm_read_fence *rediwm_read_fence_create(struct wlr_renderer *renderer,
                                                   struct wl_event_loop *loop) {
  if (!renderer->features.timeline)
    return NULL;
  int drm_fd = wlr_renderer_get_drm_fd(renderer);
  if (drm_fd < 0)
    return NULL;
  struct rediwm_read_fence *fence = calloc(1, sizeof(*fence));
  if (!fence)
    return NULL;
  fence->timeline = wlr_drm_syncobj_timeline_create(drm_fd);
  if (!fence->timeline) {
    free(fence);
    return NULL;
  }
  fence->loop = loop;
  wl_array_init(&fence->surfaces);
  return fence;
}

void rediwm_read_fence_destroy(struct rediwm_read_fence *fence) {
  if (!fence)
    return;
  wlr_drm_syncobj_timeline_unref(fence->timeline);
  wl_array_release(&fence->surfaces);
  free(fence);
}

void rediwm_read_fence_begin(struct rediwm_read_fence *fence,
                             struct wlr_buffer_pass_options *options) {
  if (!fence)
    return;
  options->signal_timeline = fence->timeline;
  options->signal_point = ++fence->point;
  fence->armed = true;
  fence->surfaces.size = 0;
}

void rediwm_read_fence_note(struct rediwm_read_fence *fence,
                            struct wlr_surface *surface) {
  if (!fence || !fence->armed || !acquire_state(surface))
    return;
  struct wlr_surface **slot = wl_array_add(&fence->surfaces, sizeof(*slot));
  if (slot)
    *slot = surface;
}

void rediwm_read_fence_end(struct rediwm_read_fence *fence, bool submitted) {
  if (!fence || !fence->armed)
    return;
  fence->armed = false;
  if (!submitted)
    return;
  // Passes are begun, recorded and submitted synchronously, so no surface can
  // have committed or been destroyed since it was noted.
  struct wlr_surface **surface;
  wl_array_for_each(surface, &fence->surfaces) {
    struct wlr_linux_drm_syncobj_surface_v1_state *state = acquire_state(*surface);
    if (state)
      wlr_linux_drm_syncobj_v1_state_add_release_point(
          state, fence->timeline, fence->point, fence->loop);
  }
  fence->surfaces.size = 0;
}

struct rediwm_acquire_wait {
  struct wl_event_loop *loop;
  void (*ready)(void *);
  void *data;
  struct wlr_drm_syncobj_timeline_waiter waiter;
  bool armed;
};

struct rediwm_acquire_wait *rediwm_acquire_wait_create(struct wl_event_loop *loop,
                                                       void (*ready)(void *),
                                                       void *data) {
  struct rediwm_acquire_wait *wait = calloc(1, sizeof(*wait));
  if (!wait)
    return NULL;
  wait->loop = loop;
  wait->ready = ready;
  wait->data = data;
  return wait;
}

void rediwm_acquire_wait_cancel(struct rediwm_acquire_wait *wait) {
  if (!wait || !wait->armed)
    return;
  wlr_drm_syncobj_timeline_waiter_finish(&wait->waiter);
  wait->armed = false;
}

void rediwm_acquire_wait_destroy(struct rediwm_acquire_wait *wait) {
  rediwm_acquire_wait_cancel(wait);
  free(wait);
}

static void acquired(struct wlr_drm_syncobj_timeline_waiter *waiter) {
  struct rediwm_acquire_wait *wait = wl_container_of(waiter, wait, waiter);
  rediwm_acquire_wait_cancel(wait);
  // May re-arm or cancel; the waiter is not touched after this.
  wait->ready(wait->data);
}

bool rediwm_acquire_wait_ready(struct rediwm_acquire_wait *wait,
                               struct wlr_surface *surface) {
  rediwm_acquire_wait_cancel(wait);
  struct wlr_linux_drm_syncobj_surface_v1_state *state = acquire_state(surface);
  // Without a wait nothing would retry; read now instead.
  if (!state || !wait)
    return true;
  // wlroots holds a commit until its acquire point has materialized, so the
  // flag only guards the check itself. A failed check reads anyway: at worst
  // stale pixels, as without explicit sync.
  bool signalled = false;
  if (!wlr_drm_syncobj_timeline_check(state->acquire_timeline,
                                      state->acquire_point,
                                      DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT,
                                      &signalled) ||
      signalled)
    return true;
  wait->armed = wlr_drm_syncobj_timeline_waiter_init(
      &wait->waiter, state->acquire_timeline, state->acquire_point, 0,
      wait->loop, acquired);
  return !wait->armed;
}
