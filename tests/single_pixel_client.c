// Real Wayland single-pixel buffers, isolated by the Python test's runtime dir.
#define _GNU_SOURCE
#include "single-pixel-buffer-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include <assert.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_subcompositor *subcompositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_viewporter *viewporter;
static struct wp_single_pixel_buffer_manager_v1 *manager;
static struct wl_surface *surface, *child;
static struct wp_viewport *viewport, *child_viewport;
static struct wl_buffer *background, *color;
static int width = 320, height = 240;
static unsigned buffer_id, frames;

static void released(void *data, struct wl_buffer *buffer) {
  (void)buffer;
  printf("release %u\n", (unsigned)(uintptr_t)data);
}
static const struct wl_buffer_listener buffer_listener = {released};
static struct wl_buffer *single(uint32_t r, uint32_t g, uint32_t b, uint32_t a) {
  struct wl_buffer *buffer = wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(manager, r, g, b, a);
  wl_buffer_add_listener(buffer, &buffer_listener, (void *)(uintptr_t)++buffer_id);
  return buffer;
}
static void attach(struct wl_surface *s, struct wl_buffer *buffer) {
  wl_surface_attach(s, buffer, 0, 0);
  wl_surface_damage(s, 0, 0, INT32_MAX, INT32_MAX);
  wl_surface_commit(s);
}
static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
  (void)data; (void)time;
  wl_callback_destroy(callback);
  printf("frame %u\n", ++frames);
}
static const struct wl_callback_listener frame_listener = {frame_done};
static void frame(void) {
  wl_callback_add_listener(wl_surface_frame(surface), &frame_listener, NULL);
  wl_surface_commit(surface);
}
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(xdg, serial);
  wp_viewport_set_destination(viewport, width, height);
  attach(surface, background);
  if (!child) {
    child = wl_compositor_create_surface(compositor);
    struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, child, surface);
    wl_subsurface_set_position(sub, 40, 50);
    wl_subsurface_set_desync(sub);
    child_viewport = wp_viewporter_get_viewport(viewporter, child);
    wp_viewport_set_destination(child_viewport, 160, 100);
    color = single(UINT32_MAX, 0, 0, UINT32_MAX);
    attach(child, color);
  }
  frame();
}
static const struct xdg_surface_listener xdg_listener = {configure};
static void top_configure(void *data, struct xdg_toplevel *top, int32_t w, int32_t h, struct wl_array *states) {
  (void)data; (void)top; (void)states;
  if (w > 0) width = w;
  if (h > 0) height = h;
}
static void top_close(void *data, struct xdg_toplevel *top) {
  (void)data; (void)top;
  exit(0);
}
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = top_close};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
  (void)data;
  if (!strcmp(interface, "wl_compositor"))
    compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
  else if (!strcmp(interface, "wl_subcompositor"))
    subcompositor = wl_registry_bind(registry, id, &wl_subcompositor_interface, 1);
  else if (!strcmp(interface, "wl_shm"))
    shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
  else if (!strcmp(interface, "xdg_wm_base")) {
    wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  } else if (!strcmp(interface, "wp_viewporter"))
    viewporter = wl_registry_bind(registry, id, &wp_viewporter_interface, 1);
  else if (!strcmp(interface, "wp_single_pixel_buffer_manager_v1")) {
    assert(version == 1);
    manager = wl_registry_bind(registry, id, &wp_single_pixel_buffer_manager_v1_interface, 1);
    puts("manager 1");
  }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
  (void)data; (void)registry; (void)id;
}
static const struct wl_registry_listener registry_listener = {global, removed};

static void use_shm(void) {
  int fd = memfd_create("single-pixel-shm", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, 16 * 16 * 4) == 0);
  uint32_t *pixels = mmap(NULL, 16 * 16 * 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  for (int i = 0; i < 16 * 16; i++) pixels[i] = 0xffff00ff;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, 16 * 16 * 4);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, 16, 16, 64, WL_SHM_FORMAT_ARGB8888);
  attach(child, buffer);
  wl_buffer_destroy(buffer);
  wl_shm_pool_destroy(pool);
  munmap(pixels, 16 * 16 * 4);
  close(fd);
}

int main(void) {
  setbuf(stdout, NULL);
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  assert(wl_display_roundtrip(display) >= 0);
  assert(compositor && subcompositor && shm && wm && viewporter && manager);
  background = single(0, 0, UINT32_MAX, UINT32_MAX);
  surface = wl_compositor_create_surface(compositor);
  viewport = wp_viewporter_get_viewport(viewporter, surface);
  struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_add_listener(top, &top_listener, NULL);
  xdg_toplevel_set_app_id(top, "rediwm.single-pixel-fixture");
  wl_surface_commit(surface);
  struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
  unsigned commands = 0;
  for (;;) {
    if (wl_display_dispatch_pending(display) < 0 || wl_display_flush(display) < 0) break;
    assert(poll(fds, 2, -1) >= 0);
    if (fds[0].revents && wl_display_dispatch(display) < 0) break;
    if (fds[1].revents) {
      char line[160];
      if (!fgets(line, sizeof(line), stdin)) break;
      uint32_t r, g, b, a;
      int w, h;
      if (sscanf(line, "color %u %u %u %u", &r, &g, &b, &a) == 4) {
        color = single(r, g, b, a);
        attach(child, color);
      } else if (sscanf(line, "resize %d %d", &w, &h) == 2) {
        wp_viewport_set_destination(child_viewport, w, h);
        wl_surface_commit(child);
      } else if (!strcmp(line, "shm\n")) use_shm();
      else if (!strcmp(line, "single\n")) attach(child, color);
      else if (!strcmp(line, "hide\n")) attach(child, NULL);
      else if (!strcmp(line, "destroy_buffer\n")) {
        wl_buffer_destroy(color);
        color = NULL;
      } else if (!strcmp(line, "manager\n")) {
        wp_single_pixel_buffer_manager_v1_destroy(manager);
        manager = NULL;
      } else abort();
      frame();
      if (wl_display_roundtrip(display) < 0) break;
      printf("done %u\n", ++commands);
    }
  }
  wl_display_disconnect(display);
  return 0;
}
