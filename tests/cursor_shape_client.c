// Headless cursor-shape fixture. Commands arrive on stdin, independently of focus.
#define _GNU_SOURCE
#include "cursor-shape-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-client-protocol.h"
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
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct wp_cursor_shape_manager_v1 *manager;
static struct wp_cursor_shape_device_v1 *device;
static struct xdg_wm_base *wm;
static struct wl_surface *surface, *cursor;
static struct zxdg_decoration_manager_v1 *decorations;
static uint32_t enter_serial;
static int manager_version;

static void released(void *data, struct wl_buffer *buffer) {
  (void)data;
  wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {released};
static void paint(struct wl_surface *s, int w, int h) {
  int fd = memfd_create("cursor-shape-fixture", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, w * h * 4) == 0);
  uint32_t *pixels = mmap(NULL, w * h * 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  for (int i = 0; i < w * h; i++) pixels[i] = 0xff305070;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, w * h * 4);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
  wl_buffer_add_listener(buffer, &buffer_listener, NULL);
  wl_surface_attach(s, buffer, 0, 0);
  wl_surface_damage(s, 0, 0, w, h);
  wl_surface_commit(s);
  wl_shm_pool_destroy(pool);
  munmap(pixels, w * h * 4);
  close(fd);
}
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(xdg, serial);
  paint(surface, 400, 260);
}
static const struct xdg_surface_listener xdg_listener = {configure};
static void top_configure(void *data, struct xdg_toplevel *top, int32_t w, int32_t h, struct wl_array *states) {
  (void)data; (void)top; (void)w; (void)h; (void)states;
}
static void top_close(void *data, struct xdg_toplevel *top) {
  (void)data; (void)top;
  exit(0);
}
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = top_close };
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};
static void enter(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
  (void)data; (void)p; (void)s; (void)x; (void)y;
  enter_serial = serial;
  printf("enter %u\n", serial);
}
static void leave(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) {
  (void)data; (void)p; (void)serial; (void)s;
  puts("leave");
}
static void motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
  (void)data; (void)p; (void)time; (void)x; (void)y;
}
static void button(void *data, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t b, uint32_t state) {
  (void)data; (void)p; (void)time; (void)b; (void)state;
  printf("button %u\n", serial);
}
static void axis(void *data, struct wl_pointer *p, uint32_t time, uint32_t a, wl_fixed_t value) {
  (void)data; (void)p; (void)time; (void)a; (void)value;
}
static const struct wl_pointer_listener pointer_listener = {
  .enter = enter, .leave = leave, .motion = motion, .button = button, .axis = axis,
};
static void new_pointer(void) {
  pointer = wl_seat_get_pointer(seat);
  wl_pointer_add_listener(pointer, &pointer_listener, NULL);
}
static void caps(void *data, struct wl_seat *s, uint32_t capabilities) {
  (void)data; (void)s;
  if ((capabilities & WL_SEAT_CAPABILITY_POINTER) && !pointer) new_pointer();
}
static const struct wl_seat_listener seat_listener = { .capabilities = caps };
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
  (void)data;
  if (!strcmp(interface, "wl_compositor"))
    compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
  else if (!strcmp(interface, "wl_shm"))
    shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
  else if (!strcmp(interface, "wl_seat")) {
    seat = wl_registry_bind(registry, id, &wl_seat_interface, 1);
    wl_seat_add_listener(seat, &seat_listener, NULL);
  } else if (!strcmp(interface, "xdg_wm_base")) {
    wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  } else if (!strcmp(interface, "zxdg_decoration_manager_v1"))
    decorations = wl_registry_bind(registry, id, &zxdg_decoration_manager_v1_interface, 1);
  else if (!strcmp(interface, "wp_cursor_shape_manager_v1")) {
    assert(version == 2);
    manager = wl_registry_bind(registry, id, &wp_cursor_shape_manager_v1_interface, manager_version);
    printf("manager %u bound %d\n", version, manager_version);
  }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
  (void)data; (void)registry; (void)id;
}
static const struct wl_registry_listener registry_listener = {global, removed};
static void decoration_configure(void *data, struct zxdg_toplevel_decoration_v1 *d, uint32_t mode) {
  (void)data; (void)d;
  assert(mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}
static const struct zxdg_toplevel_decoration_v1_listener decoration_listener = {decoration_configure};

int main(int argc, char **argv) {
  assert(argc == 3);
  manager_version = atoi(argv[2]);
  setbuf(stdout, NULL);
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  assert(wl_display_roundtrip(display) >= 0 && wl_display_roundtrip(display) >= 0);
  assert(compositor && shm && wm && pointer && manager && decorations);
  device = wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
  surface = wl_compositor_create_surface(compositor);
  cursor = wl_compositor_create_surface(compositor);
  struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_add_listener(top, &top_listener, NULL);
  xdg_toplevel_set_app_id(top, argv[1]);
  struct zxdg_toplevel_decoration_v1 *decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, top);
  zxdg_toplevel_decoration_v1_add_listener(decoration, &decoration_listener, NULL);
  zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  wl_surface_commit(surface);
  struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
  unsigned commands = 0;
  for (;;) {
    if (wl_display_dispatch_pending(display) < 0 || wl_display_flush(display) < 0) break;
    assert(poll(fds, 2, -1) >= 0);
    if (fds[0].revents && wl_display_dispatch(display) < 0) break;
    if (fds[1].revents) {
      char line[128];
      if (!fgets(line, sizeof(line), stdin)) break;
      uint32_t serial, shape;
      if (sscanf(line, "shape %u", &shape) == 1)
        wp_cursor_shape_device_v1_set_shape(device, enter_serial, shape);
      else if (sscanf(line, "serial %u %u", &serial, &shape) == 2)
        wp_cursor_shape_device_v1_set_shape(device, serial, shape);
      else if (!strcmp(line, "surface\n")) {
        wl_pointer_set_cursor(pointer, enter_serial, cursor, 2, 3);
        paint(cursor, 16, 16);
      } else if (!strcmp(line, "hide\n"))
        wl_pointer_set_cursor(pointer, enter_serial, NULL, 0, 0);
      else if (!strcmp(line, "destroy\n")) {
        wp_cursor_shape_device_v1_destroy(device);
        device = NULL;
      } else if (!strcmp(line, "device\n"))
        device = wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
      else if (!strcmp(line, "pointer\n")) {
        wp_cursor_shape_device_v1_destroy(device);
        wl_pointer_destroy(pointer);
        new_pointer();
        device = wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
      } else if (!strcmp(line, "manager\n")) {
        wp_cursor_shape_manager_v1_destroy(manager);
        manager = NULL;
      } else abort();
      if (wl_display_roundtrip(display) < 0) break;
      printf("done %u\n", ++commands);
    }
  }
  wl_display_disconnect(display);
  return 0;
}
