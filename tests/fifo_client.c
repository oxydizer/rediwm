// wp_fifo_v1 fixture for tests/fifo.py. No host-session access.
//
// Default mode reads one command per stdin line and answers on stdout, ending
// each answer with "done". Commits are sent back to back (no waiting between
// them) so only the compositor's barrier can spread them over refreshes; the
// outcome is read from presentation feedback ("presented <label> <seq> <ns>"
// or "discarded <label>"). `fifo_client already-exists` and
// `fifo_client surface-destroyed` provoke the two protocol errors instead.
#define _GNU_SOURCE
#include "fifo-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "linux-drm-syncobj-v1-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <inttypes.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xf86drm.h>

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wp_fifo_manager_v1 *fifo_manager;
static struct zwp_linux_dmabuf_v1 *dmabuf;
static struct wp_linux_drm_syncobj_manager_v1 *syncobj_manager;
static clockid_t clock_id = CLOCK_MONOTONIC;
static unsigned color_seq;

struct window {
  struct wl_surface *surface;
  struct xdg_surface *xdg;
  struct xdg_toplevel *toplevel;
  struct wp_fifo_v1 *fifo;
  bool configured;
  int width, height;
  bool opaque;
};

#define MAX_FEEDBACK 64
// Heap records: a forgotten feedback ("send") still gets its event later and
// must not land in a record the next command reuses.
struct feedback {
  char label[16];
  bool resolved, presented, orphan;
  uint64_t seq, ns;
};
static struct feedback *feedbacks[MAX_FEEDBACK];
static unsigned feedback_count;

static void feedback_resolved(struct feedback *fb) {
  fb->resolved = true;
  if (fb->orphan) free(fb);
}

// Stops tracking the current feedbacks; they free themselves when resolved.
static void forget_feedback(void) {
  for (unsigned i = 0; i < feedback_count; i++) {
    if (feedbacks[i]->resolved) free(feedbacks[i]);
    else feedbacks[i]->orphan = true;
  }
  feedback_count = 0;
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(clock_id, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

// ---- Registry ------------------------------------------------------------------

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
  (void)data;
  if (strcmp(interface, wl_compositor_interface.name) == 0)
    compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
  else if (strcmp(interface, wl_subcompositor_interface.name) == 0)
    subcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
  else if (strcmp(interface, wl_shm_interface.name) == 0)
    shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
  else if (strcmp(interface, xdg_wm_base_interface.name) == 0)
    wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
  else if (strcmp(interface, wp_presentation_interface.name) == 0)
    presentation = wl_registry_bind(registry, name, &wp_presentation_interface, 1);
  else if (strcmp(interface, wp_fifo_manager_v1_interface.name) == 0)
    fifo_manager = wl_registry_bind(registry, name, &wp_fifo_manager_v1_interface, 1);
  else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0 && version >= 3)
    dmabuf = wl_registry_bind(registry, name, &zwp_linux_dmabuf_v1_interface, 3);
  else if (strcmp(interface, wp_linux_drm_syncobj_manager_v1_interface.name) == 0)
    syncobj_manager = wl_registry_bind(registry, name, &wp_linux_drm_syncobj_manager_v1_interface, 1);
}
static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data, (void)registry, (void)name;
}
static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {wm_ping};

static void presentation_clock(void *data, struct wp_presentation *p, uint32_t id) {
  (void)data, (void)p;
  clock_id = (clockid_t)id;
}
static const struct wp_presentation_listener presentation_listener = {presentation_clock};

// ---- Feedback ------------------------------------------------------------------

static void fb_sync_output(void *data, struct wp_presentation_feedback *f, struct wl_output *o) {
  (void)data, (void)f, (void)o;
}
static void fb_presented(void *data, struct wp_presentation_feedback *f, uint32_t sec_hi,
                         uint32_t sec_lo, uint32_t nsec, uint32_t refresh, uint32_t seq_hi,
                         uint32_t seq_lo, uint32_t flags) {
  (void)refresh, (void)flags;
  struct feedback *fb = data;
  fb->presented = true;
  fb->seq = ((uint64_t)seq_hi << 32) | seq_lo;
  fb->ns = ((((uint64_t)sec_hi << 32) | sec_lo) * 1000000000u) + nsec;
  wp_presentation_feedback_destroy(f);
  feedback_resolved(fb);
}
static void fb_discarded(void *data, struct wp_presentation_feedback *f) {
  wp_presentation_feedback_destroy(f);
  feedback_resolved(data);
}
static const struct wp_presentation_feedback_listener fb_listener = {fb_sync_output, fb_presented,
                                                                     fb_discarded};

static void request_feedback(struct wl_surface *surface, const char *label) {
  assert(feedback_count < MAX_FEEDBACK);
  struct feedback *fb = calloc(1, sizeof(*fb));
  assert(fb);
  feedbacks[feedback_count++] = fb;
  snprintf(fb->label, sizeof(fb->label), "%s", label);
  wp_presentation_feedback_add_listener(wp_presentation_feedback(presentation, surface),
                                        &fb_listener, fb);
}

// Dispatches until `done()` or the timeout; false on timeout or error.
static bool pump(bool (*done)(void), int timeout_ms) {
  uint64_t deadline = now_ns() + (uint64_t)timeout_ms * 1000000u;
  while (!done()) {
    if (wl_display_dispatch_pending(display) < 0) return false;
    if (done()) break;
    if (wl_display_flush(display) < 0 && errno != EAGAIN) return false;
    uint64_t now = now_ns();
    if (now >= deadline) return false;
    struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
    if (wl_display_prepare_read(display) != 0) continue;
    int ready = poll(&pfd, 1, (int)((deadline - now) / 1000000u) + 1);
    if (ready > 0) {
      if (wl_display_read_events(display) < 0) return false;
    } else {
      wl_display_cancel_read(display);
    }
  }
  return true;
}

static bool all_resolved(void) {
  for (unsigned i = 0; i < feedback_count; i++)
    if (!feedbacks[i]->resolved) return false;
  return true;
}

// Reports and forgets every feedback.
static void report(void) {
  bool ok = pump(all_resolved, 10000);
  for (unsigned i = 0; i < feedback_count; i++) {
    struct feedback *fb = feedbacks[i];
    if (!fb->resolved)
      printf("pending %s\n", fb->label);
    else if (fb->presented)
      printf("presented %s %" PRIu64 " %" PRIu64 "\n", fb->label, fb->seq, fb->ns);
    else
      printf("discarded %s\n", fb->label);
  }
  if (!ok) printf("timeout\n");
  forget_feedback();
}

// ---- Buffers -------------------------------------------------------------------

static void buffer_release(void *data, struct wl_buffer *buffer) {
  (void)data;
  wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {buffer_release};

static void attach_shm(struct wl_surface *surface, int width, int height, bool opaque) {
  const int stride = width * 4;
  const size_t size = (size_t)stride * (size_t)height;
  int fd = memfd_create("fifo-fixture", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
  uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  uint32_t color = 0xff203050u + ((++color_seq & 0x3f) << 16);
  for (size_t i = 0; i < size / 4; i++) pixels[i] = color;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(
      pool, 0, width, height, stride, opaque ? WL_SHM_FORMAT_XRGB8888 : WL_SHM_FORMAT_ARGB8888);
  wl_buffer_add_listener(buffer, &buffer_listener, NULL);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage_buffer(surface, 0, 0, width, height);
  wl_shm_pool_destroy(pool);
  munmap(pixels, size);
  close(fd);
}

// ---- Windows -------------------------------------------------------------------

static void xdg_configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
  struct window *w = data;
  xdg_surface_ack_configure(xdg, serial);
  w->configured = true;
}
static const struct xdg_surface_listener xdg_listener = {xdg_configure};

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h,
                               struct wl_array *states) {
  (void)data, (void)t, (void)w, (void)h, (void)states;
}
static void toplevel_close(void *data, struct xdg_toplevel *t) { (void)data, (void)t; }
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure, .close = toplevel_close};

static struct window *configuring;
static bool window_configured(void) { return configuring->configured; }

// Maps a toplevel with a first shm buffer (none when `no_buffer`) and waits
// until it is shown.
static void window_create(struct window *w, const char *app_id, int width, int height, bool opaque,
                          bool with_fifo, bool no_buffer) {
  *w = (struct window){.width = width, .height = height, .opaque = opaque};
  w->surface = wl_compositor_create_surface(compositor);
  if (with_fifo) w->fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, w->surface);
  w->xdg = xdg_wm_base_get_xdg_surface(wm, w->surface);
  xdg_surface_add_listener(w->xdg, &xdg_listener, w);
  w->toplevel = xdg_surface_get_toplevel(w->xdg);
  xdg_toplevel_add_listener(w->toplevel, &toplevel_listener, w);
  xdg_toplevel_set_app_id(w->toplevel, app_id);
  xdg_toplevel_set_title(w->toplevel, app_id);
  wl_surface_commit(w->surface);
  configuring = w;
  assert(pump(window_configured, 5000));
  if (no_buffer) return;
  attach_shm(w->surface, width, height, opaque);
  request_feedback(w->surface, "map");
  wl_surface_commit(w->surface);
  report();
}

static void window_destroy(struct window *w) {
  if (w->fifo) wp_fifo_v1_destroy(w->fifo);
  xdg_toplevel_destroy(w->toplevel);
  xdg_surface_destroy(w->xdg);
  wl_surface_destroy(w->surface);
  *w = (struct window){0};
}

// Commits `n` buffers back to back, each with set_barrier + wait_barrier
// when `fifo`, and presentation feedback.
static void burst(struct window *w, const char *prefix, int n, bool fifo) {
  for (int i = 0; i < n; i++) {
    char label[16];
    snprintf(label, sizeof(label), "%s%d", prefix, i);
    attach_shm(w->surface, w->width, w->height, w->opaque);
    if (fifo) {
      wp_fifo_v1_set_barrier(w->fifo);
      wp_fifo_v1_wait_barrier(w->fifo);
    }
    request_feedback(w->surface, label);
    wl_surface_commit(w->surface);
  }
  wl_display_flush(display);
}

// ---- Subsurfaces ---------------------------------------------------------------

static void subsurface_case(struct window *parent, int n, bool sync) {
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, surface, parent->surface);
  struct wp_fifo_v1 *fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
  wl_subsurface_set_position(sub, 20, 20);
  if (sync) wl_subsurface_set_sync(sub);
  else wl_subsurface_set_desync(sub);
  attach_shm(surface, 120, 80, true);
  request_feedback(surface, "sub-map");
  wl_surface_commit(surface);
  wl_surface_commit(parent->surface);
  report();
  for (int i = 0; i < n; i++) {
    char label[16];
    snprintf(label, sizeof(label), "s%d", i);
    attach_shm(surface, 120, 80, true);
    wp_fifo_v1_set_barrier(fifo);
    wp_fifo_v1_wait_barrier(fifo);
    request_feedback(surface, label);
    wl_surface_commit(surface);
    // A synchronized subsurface's state applies with its parent's commit.
    wl_surface_commit(parent->surface);
  }
  wl_display_flush(display);
  report();
  wp_fifo_v1_destroy(fifo);
  wl_subsurface_destroy(sub);
  wl_surface_destroy(surface);
  wl_surface_commit(parent->surface);
  wl_display_roundtrip(display);
}

// ---- Explicit sync -------------------------------------------------------------

struct timeline {
  uint32_t handle;
  struct wp_linux_drm_syncobj_timeline_v1 *proxy;
};

static int drm_fd = -1;
static struct gbm_device *gbm;

static void timeline_create(struct timeline *t) {
  assert(drmSyncobjCreate(drm_fd, 0, &t->handle) == 0);
  int fd = -1;
  assert(drmSyncobjHandleToFD(drm_fd, t->handle, &fd) == 0);
  t->proxy = wp_linux_drm_syncobj_manager_v1_import_timeline(syncobj_manager, fd);
  close(fd);
}

static void timeline_signal(struct timeline *t, uint64_t point) {
  assert(drmSyncobjTimelineSignal(drm_fd, &t->handle, &point, 1) == 0);
}

static struct wl_buffer *dmabuf_buffer(int width, int height) {
  struct gbm_bo *bo = gbm_bo_create(gbm, (uint32_t)width, (uint32_t)height, GBM_FORMAT_XRGB8888,
                                    GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
  assert(bo);
  int fd = gbm_bo_get_fd(bo);
  assert(fd >= 0);
  uint64_t modifier = gbm_bo_get_modifier(bo);
  struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(dmabuf);
  zwp_linux_buffer_params_v1_add(params, fd, 0, gbm_bo_get_offset(bo, 0), gbm_bo_get_stride(bo),
                                 (uint32_t)(modifier >> 32), (uint32_t)modifier);
  struct wl_buffer *buffer = zwp_linux_buffer_params_v1_create_immed(
      params, width, height, GBM_FORMAT_XRGB8888, 0);
  zwp_linux_buffer_params_v1_destroy(params);
  close(fd);
  // The compositor imported the dmabuf; the bo can go once the buffer does.
  // A fixture this short keeps it for its lifetime.
  return buffer;
}

// Commit 1 sets a barrier but its acquire point is not yet materialized, so
// wlroots caches it; commit 2 waits for that barrier. When the point is
// signalled, commit 1 applies and commit 2 must still wait one latch.
static void explicit_sync_case(void) {
  const char *node = getenv("FIFO_RENDER_NODE");
  drm_fd = open(node ? node : "/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
  assert(drm_fd >= 0);
  gbm = gbm_create_device(drm_fd);
  assert(gbm);
  struct window w;
  window_create(&w, "rediwm.fifo-sync", 320, 200, true, true, true);
  struct wp_linux_drm_syncobj_surface_v1 *sync =
      wp_linux_drm_syncobj_manager_v1_get_surface(syncobj_manager, w.surface);
  struct timeline map_tl, first_tl, second_tl, release_tl;
  timeline_create(&map_tl);
  timeline_create(&first_tl);
  timeline_create(&second_tl);
  timeline_create(&release_tl);

  timeline_signal(&map_tl, 1);
  wl_surface_attach(w.surface, dmabuf_buffer(320, 200), 0, 0);
  wl_surface_damage_buffer(w.surface, 0, 0, 320, 200);
  wp_linux_drm_syncobj_surface_v1_set_acquire_point(sync, map_tl.proxy, 0, 1);
  wp_linux_drm_syncobj_surface_v1_set_release_point(sync, release_tl.proxy, 0, 1);
  request_feedback(w.surface, "es-map");
  wl_surface_commit(w.surface);
  report();

  wl_surface_attach(w.surface, dmabuf_buffer(320, 200), 0, 0);
  wl_surface_damage_buffer(w.surface, 0, 0, 320, 200);
  wp_linux_drm_syncobj_surface_v1_set_acquire_point(sync, first_tl.proxy, 0, 1);
  wp_linux_drm_syncobj_surface_v1_set_release_point(sync, release_tl.proxy, 0, 2);
  wp_fifo_v1_set_barrier(w.fifo);
  request_feedback(w.surface, "es1");
  wl_surface_commit(w.surface);

  timeline_signal(&second_tl, 1);
  wl_surface_attach(w.surface, dmabuf_buffer(320, 200), 0, 0);
  wl_surface_damage_buffer(w.surface, 0, 0, 320, 200);
  wp_linux_drm_syncobj_surface_v1_set_acquire_point(sync, second_tl.proxy, 0, 1);
  wp_linux_drm_syncobj_surface_v1_set_release_point(sync, release_tl.proxy, 0, 3);
  wp_fifo_v1_set_barrier(w.fifo);
  wp_fifo_v1_wait_barrier(w.fifo);
  request_feedback(w.surface, "es2");
  wl_surface_commit(w.surface);
  // Both commits are queued in the compositor before the first can apply.
  wl_display_roundtrip(display);
  usleep(50000);
  wl_display_roundtrip(display);
  printf("unresolved-before-signal %d\n", feedbacks[0]->resolved || feedbacks[1]->resolved ? 0 : 1);
  timeline_signal(&first_tl, 1);
  report();

  wp_linux_drm_syncobj_surface_v1_destroy(sync);
  window_destroy(&w);
  wl_display_roundtrip(display);
}

// ---- Protocol errors -------------------------------------------------------------

static int expect_error(const struct wl_interface *interface, uint32_t code) {
  wl_display_roundtrip(display);
  const struct wl_interface *got = NULL;
  uint32_t id = 0;
  if (wl_display_get_error(display) != EPROTO) {
    printf("no protocol error\n");
    return 1;
  }
  uint32_t got_code = wl_display_get_protocol_error(display, &got, &id);
  printf("error %s %u\n", got ? got->name : "?", got_code);
  return got == interface && got_code == code ? 0 : 1;
}

static int error_mode(const char *mode) {
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct wp_fifo_v1 *fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
  if (strcmp(mode, "already-exists") == 0) {
    wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
    return expect_error(&wp_fifo_manager_v1_interface, WP_FIFO_MANAGER_V1_ERROR_ALREADY_EXISTS);
  }
  if (strcmp(mode, "recreate") == 0) {
    // A fifo may be made again once the first is destroyed.
    wp_fifo_v1_destroy(fifo);
    wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
    wl_display_roundtrip(display);
    printf("error none %d\n", wl_display_get_error(display));
    return wl_display_get_error(display) == 0 ? 0 : 1;
  }
  wl_surface_destroy(surface);
  wp_fifo_v1_set_barrier(fifo);
  return expect_error(&wp_fifo_v1_interface, WP_FIFO_V1_ERROR_SURFACE_DESTROYED);
}

// ---- Commands --------------------------------------------------------------------

int main(int argc, char **argv) {
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!fifo_manager) {
    printf("no wp_fifo_manager_v1\n");
    return 1;
  }
  assert(compositor && subcompositor && shm && wm && presentation);
  xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  wp_presentation_add_listener(presentation, &presentation_listener, NULL);
  wl_display_roundtrip(display);
  if (argc > 1) return error_mode(argv[1]);

  struct window main_window, cover = {0}, extra;
  window_create(&main_window, "rediwm.fifo-fixture", 320, 200, false, true, false);
  printf("ready %d %d\n", dmabuf != NULL, syncobj_manager != NULL);
  printf("done\n");
  fflush(stdout);

  char line[128];
  while (fgets(line, sizeof(line), stdin)) {
    int n = 0;
    if (sscanf(line, "burst %d", &n) == 1) {
      burst(&main_window, "b", n, true);
      report();
    } else if (sscanf(line, "plain %d", &n) == 1) {
      burst(&main_window, "p", n, false);
      report();
    } else if (sscanf(line, "send %d", &n) == 1) {
      // Fire and forget (the window is hidden: feedback never resolves).
      burst(&main_window, "h", n, true);
      wl_display_roundtrip(display);
      forget_feedback();
    } else if (strncmp(line, "empty", 5) == 0) {
      // An update that only sets a barrier changes nothing on screen.
      wp_fifo_v1_set_barrier(main_window.fifo);
      wl_surface_commit(main_window.surface);
      uint64_t sent = now_ns();
      attach_shm(main_window.surface, main_window.width, main_window.height, false);
      wp_fifo_v1_set_barrier(main_window.fifo);
      wp_fifo_v1_wait_barrier(main_window.fifo);
      request_feedback(main_window.surface, "e");
      wl_surface_commit(main_window.surface);
      bool ok = pump(all_resolved, 10000);
      if (ok && feedbacks[0]->presented)
        printf("latency_ms %.2f\n", (double)(feedbacks[0]->ns - sent) / 1e6);
      report();
    } else if (sscanf(line, "sub %d", &n) == 1) {
      subsurface_case(&main_window, n, strstr(line, "sync") && !strstr(line, "desync"));
    } else if (sscanf(line, "destroy-fifo %d", &n) == 1) {
      burst(&main_window, "d", n, true);
      wp_fifo_v1_destroy(main_window.fifo);
      main_window.fifo = NULL;
      report();
      main_window.fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, main_window.surface);
    } else if (sscanf(line, "destroy-surface %d", &n) == 1) {
      window_create(&extra, "rediwm.fifo-extra", 200, 150, false, true, false);
      burst(&extra, "x", n, true);
      // Keep the fifo object; its surface goes with commits still held.
      struct wp_fifo_v1 *orphan = extra.fifo;
      extra.fifo = NULL;
      window_destroy(&extra);
      wl_display_roundtrip(display);
      wp_fifo_v1_destroy(orphan);
      wl_display_roundtrip(display);
      forget_feedback();
      printf("survived\n");
    } else if (strncmp(line, "cover", 5) == 0) {
      window_create(&cover, "rediwm.fifo-cover", 900, 700, true, false, false);
    } else if (strncmp(line, "uncover", 7) == 0) {
      window_destroy(&cover);
      wl_display_roundtrip(display);
    } else if (strncmp(line, "explicit-sync", 13) == 0) {
      explicit_sync_case();
    } else {
      printf("unknown %s", line);
    }
    printf("done\n");
    fflush(stdout);
    if (wl_display_get_error(display)) {
      printf("display error %d\n", wl_display_get_error(display));
      return 1;
    }
  }
  return 0;
}
