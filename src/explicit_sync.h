#pragma once
#include <stdbool.h>
struct wl_event_loop;
struct wlr_buffer_pass_options;
struct wlr_renderer;
struct wlr_surface;

// Explicit synchronization (wp_linux_drm_syncobj_v1) for client buffers the
// compositor reads outside wlr_scene's own output rendering.

// Whether the protocol can be advertised: wlroots needs timelines from both
// the renderer and the backend, and a DRM device to create them on.
bool rediwm_explicit_sync_supported(struct wlr_renderer *, bool backend_timeline);
// Whether the surface's current buffer came with an acquire point.
bool rediwm_surface_explicit_sync(struct wlr_surface *);

// Release points for GPU passes that sample client buffers. NULL (no
// timeline support) is accepted everywhere and does nothing.
struct rediwm_read_fence;
struct rediwm_read_fence *rediwm_read_fence_create(struct wlr_renderer *,
                                                   struct wl_event_loop *);
void rediwm_read_fence_destroy(struct rediwm_read_fence *);
// Makes the next pass signal a new point on the fence's timeline.
void rediwm_read_fence_begin(struct rediwm_read_fence *,
                             struct wlr_buffer_pass_options *);
// The pass begun above reads the surface's current buffer.
void rediwm_read_fence_note(struct rediwm_read_fence *, struct wlr_surface *);
// Registers the point as a release point of every noted surface, once the
// pass was submitted; a failed pass never materializes it.
void rediwm_read_fence_end(struct rediwm_read_fence *, bool submitted);

// CPU reads cannot wait on the GPU. This tells whether a surface's current
// buffer is ready to read now, and otherwise calls `ready` once it is.
struct rediwm_acquire_wait;
struct rediwm_acquire_wait *rediwm_acquire_wait_create(struct wl_event_loop *,
                                                       void (*ready)(void *),
                                                       void *data);
void rediwm_acquire_wait_destroy(struct rediwm_acquire_wait *);
// True when the buffer can be read. False arms the wait, replacing an
// earlier one; `ready` runs from the event loop, never from this call.
bool rediwm_acquire_wait_ready(struct rediwm_acquire_wait *,
                               struct wlr_surface *);
void rediwm_acquire_wait_cancel(struct rediwm_acquire_wait *);
