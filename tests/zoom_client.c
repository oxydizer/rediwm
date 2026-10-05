// Isolated Wayland fixture for desktop_zoom.py. No host-session access.
#define _GNU_SOURCE
#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-client-protocol.h"
#include <assert.h>
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
static struct wl_seat *seat;
static struct xdg_wm_base *wm;
static struct wl_surface *surface, *child, *popup_surface;
static struct xdg_surface *xdg, *popup_xdg;
static struct xdg_toplevel *toplevel;
static struct zxdg_decoration_manager_v1 *decoration_manager;
static struct zxdg_toplevel_decoration_v1 *decoration;
static int width = 400, height = 260, frames;
static void released(void *data, struct wl_buffer *buffer) {
  (void)data;
  wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {released};
static unsigned top_color = 0xffff0000, bot_color = 0xff0000ff;
static unsigned *edge_pixels;
static size_t edge_bytes;
static int edge_fd = -1, edge_bw, edge_bh;
static struct wl_buffer *edge_buffer;
static int edge_geom_inset;
static int edge_buf_scale = 1;
static int edge_transform;
static int edge_mode;
static int perf_mode;
static int perf_damage;
static const char *app_id = "rediwm.zoom-fixture";
static const char *title = "Zoom fixture";
static int late_app_id = 0;

static void fill_split(unsigned *pixels, int w, int h, unsigned top, unsigned bot) {
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++)
      pixels[y * w + x] = (y < h - 1) ? top : bot;
}

static void paint(struct wl_surface *s, int w, int h, unsigned color) {
  int fd = memfd_create("zoom-fixture", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, w * h * 4) == 0);
  unsigned *pixels =
      mmap(NULL, w * h * 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  if (color)
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++)
        pixels[y * w + x] = color;
  else if (edge_mode)
    fill_split(pixels, w, h, top_color, bot_color);
  else
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++)
        pixels[y * w + x] = y < h / 2 ? 0xffff0000 : 0xff0000ff;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, w * h * 4);
  struct wl_buffer *buffer =
      wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
  wl_surface_attach(s, buffer, 0, 0);
  wl_surface_damage(s, 0, 0, w, h);
  wl_buffer_add_listener(buffer, &buffer_listener, NULL);
  wl_shm_pool_destroy(pool);
  munmap(pixels, w * h * 4);
  close(fd);
}

static void edge_release(void *data, struct wl_buffer *buffer) {
  (void)data;
  if (buffer != edge_buffer)
    wl_buffer_destroy(buffer);
}

static const struct wl_buffer_listener edge_buffer_listener = {edge_release};

static void edge_ensure(int bw, int bh) {
  if (edge_buffer && edge_bw == bw && edge_bh == bh)
    return;
  if (edge_buffer) {
    wl_buffer_destroy(edge_buffer);
    edge_buffer = NULL;
  }
  if (edge_pixels) {
    munmap(edge_pixels, edge_bytes);
    edge_pixels = NULL;
  }
  if (edge_fd >= 0) {
    close(edge_fd);
    edge_fd = -1;
  }
  edge_bytes = (size_t)bw * (size_t)bh * 4;
  edge_fd = memfd_create("zoom-edge", MFD_CLOEXEC);
  assert(edge_fd >= 0 && ftruncate(edge_fd, (off_t)edge_bytes) == 0);
  edge_pixels = mmap(NULL, edge_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, edge_fd, 0);
  assert(edge_pixels != MAP_FAILED);
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, edge_fd, (int32_t)edge_bytes);
  edge_buffer = wl_shm_pool_create_buffer(pool, 0, bw, bh, bw * 4, WL_SHM_FORMAT_ARGB8888);
  wl_buffer_add_listener(edge_buffer, &edge_buffer_listener, NULL);
  wl_shm_pool_destroy(pool);
  edge_bw = bw;
  edge_bh = bh;
}

static void edge_commit(int reuse, int dmg_x, int dmg_y, int dmg_w, int dmg_h) {
  int bw = width * edge_buf_scale;
  int bh = height * edge_buf_scale;
  if (!reuse)
    edge_bw = edge_bh = 0;
  edge_ensure(bw, bh);
  fill_split(edge_pixels, bw, bh, top_color, bot_color);
  wl_surface_set_buffer_scale(surface, edge_buf_scale);
  wl_surface_set_buffer_transform(surface, edge_transform);
  xdg_surface_set_window_geometry(xdg, edge_geom_inset, edge_geom_inset,
                                  width - 2 * edge_geom_inset, height - 2 * edge_geom_inset);
  wl_surface_attach(surface, edge_buffer, 0, 0);
  if (dmg_w > 0 && dmg_h > 0)
    wl_surface_damage(surface, dmg_x, dmg_y, dmg_w, dmg_h);
  wl_surface_commit(surface);
}
static void frame_done(void *data, struct wl_callback *callback, uint32_t time);
static const struct wl_callback_listener frame_listener = {frame_done};
static void request_frame(void) {
  wl_callback_add_listener(wl_surface_frame(surface), &frame_listener, NULL);
}
static void frame_done(void *data, struct wl_callback *callback,
                       uint32_t time) {
  (void)data;
  (void)time;
  wl_callback_destroy(callback);
  printf("frame %d\n", ++frames);
  const char *live_file = getenv("REDIWM_TEST_LIVE_FILE");
  if (live_file) {
    unsigned color = 0xff112233;
    FILE *file = fopen(live_file, "r");
    if (file) {
      int w = width, h = height;
      // An optional title after the size is sent only when it changes.
      static char live_title[256];
      char next_title[256];
      int fields = fscanf(file, "%x %d %d %255[^\n]", &color, &w, &h, next_title);
      if (fields >= 3 && w > 0 && h > 0) {
        width = w;
        height = h;
      }
      if (fields == 4 && strcmp(next_title, live_title)) {
        snprintf(live_title, sizeof live_title, "%s", next_title);
        xdg_toplevel_set_title(toplevel, live_title);
      }
      fclose(file);
    }
    request_frame();
    paint(surface, width, height, color);
    wl_surface_commit(surface);
    return;
  }
  if (perf_mode) {
    request_frame();
    if (perf_damage)
      paint(surface, width, height, 0);
    wl_surface_commit(surface);
    return;
  }
  if (frames < 8) {
    request_frame();
    wl_surface_commit(surface);
  }
}
static void entered(void *data, struct wl_surface *s, struct wl_output *out) {
  (void)data;
  (void)s;
  (void)out;
  puts("output-enter");
}
static void left(void *data, struct wl_surface *s, struct wl_output *out) {
  (void)data;
  (void)s;
  (void)out;
  puts("output-leave");
}
static const struct wl_surface_listener surface_listener = {.enter = entered,
                                                            .leave = left};
static void configured(void *data, struct xdg_surface *xs, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(xs, serial);
  if (xs == popup_xdg) {
    paint(popup_surface, 100, 60, 0xffffff00);
    wl_surface_commit(popup_surface);
    return;
  }
  printf("configure %d %d\n", width, height);
  if (edge_mode && width > 2 * edge_geom_inset && height > 2 * edge_geom_inset)
    xdg_surface_set_window_geometry(xdg, edge_geom_inset, edge_geom_inset,
                                    width - 2 * edge_geom_inset, height - 2 * edge_geom_inset);
  paint(surface, width, height, 0);
  if (!child) {
    child = wl_compositor_create_surface(compositor);
    struct wl_subsurface *sub =
        wl_subcompositor_get_subsurface(subcompositor, child, surface);
    wl_subsurface_set_position(sub, 100, 80);
    paint(child, 60, 40, 0xff00ff00);
    wl_surface_commit(child);
  }
  request_frame();
  wl_surface_commit(surface);
  if (late_app_id && app_id) {
    xdg_toplevel_set_app_id(toplevel, app_id);
    wl_surface_commit(surface);
    late_app_id = 0;
  }
}
static const struct xdg_surface_listener xdg_listener = {configured};
static void top_configure(void *data, struct xdg_toplevel *t, int32_t w,
                          int32_t h, struct wl_array *states) {
  (void)data;
  (void)t;
  (void)states;
  if (w > 0)
    width = w;
  if (h > 0)
    height = h;
}
// A close-confirmation transient used by the window-group regression. The
// marker lets the harness cancel once, then allow the ordinary close path.
static struct wl_surface *confirm_surface;
static struct xdg_surface *confirm_xdg;
static struct xdg_toplevel *confirm_top;
static struct zxdg_toplevel_decoration_v1 *confirm_decoration;
static void confirm_configure(void *data, struct xdg_surface *s, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(s, serial);
  paint(confirm_surface, 240, 120, 0xffeeeeee);
  wl_surface_commit(confirm_surface);
}
static const struct xdg_surface_listener confirm_surface_listener = {confirm_configure};
static void confirm_size(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
  (void)data; (void)t; (void)w; (void)h; (void)states;
}
static void confirm_close(void *data, struct xdg_toplevel *t) {
  (void)data; (void)t;
  if (confirm_decoration) zxdg_toplevel_decoration_v1_destroy(confirm_decoration);
  confirm_decoration = NULL;
  xdg_toplevel_destroy(confirm_top);
  xdg_surface_destroy(confirm_xdg);
  wl_surface_destroy(confirm_surface);
  confirm_top = NULL;
}
static const struct xdg_toplevel_listener confirm_top_listener = { .configure = confirm_size, .close = confirm_close };
static void show_confirm(void) {
  if (confirm_top) return;
  confirm_surface = wl_compositor_create_surface(compositor);
  confirm_xdg = xdg_wm_base_get_xdg_surface(wm, confirm_surface);
  xdg_surface_add_listener(confirm_xdg, &confirm_surface_listener, NULL);
  confirm_top = xdg_surface_get_toplevel(confirm_xdg);
  xdg_toplevel_add_listener(confirm_top, &confirm_top_listener, NULL);
  xdg_toplevel_set_parent(confirm_top, toplevel);
  xdg_toplevel_set_app_id(confirm_top, app_id);
  xdg_toplevel_set_title(confirm_top, "Confirm close");
  wl_surface_commit(confirm_surface);
}
static void top_close(void *data, struct xdg_toplevel *t) {
  (void)data;
  (void)t;
  const char *marker = getenv("REDIWM_TEST_CLOSE_MARKER");
  if (marker && access(marker, F_OK) == 0) { show_confirm(); return; }
  exit(0);
}
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = top_close};
static void popup_configure(void *data, struct xdg_popup *p, int32_t x,
                            int32_t y, int32_t w, int32_t h) {
  (void)data;
  (void)p;
  printf("popup %d %d %d %d\n", x, y, w, h);
}
static void popup_done(void *data, struct xdg_popup *p) {
  (void)data;
  (void)p;
}
static const struct xdg_popup_listener popup_listener = {
    .configure = popup_configure, .popup_done = popup_done};
static void open_popup(void) {
  if (popup_surface)
    return;
  popup_surface = wl_compositor_create_surface(compositor);
  popup_xdg = xdg_wm_base_get_xdg_surface(wm, popup_surface);
  xdg_surface_add_listener(popup_xdg, &xdg_listener, NULL);
  struct xdg_positioner *pos = xdg_wm_base_create_positioner(wm);
  xdg_positioner_set_size(pos, 100, 60);
  xdg_positioner_set_anchor_rect(pos, 50, 40, 1, 1);
  xdg_positioner_set_anchor(pos, XDG_POSITIONER_ANCHOR_TOP_LEFT);
  xdg_positioner_set_gravity(pos, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
  // Like a browser context menu: keep the popup on screen by sliding, and
  // let the anchor rect follow the click when REDIWM_TEST_POPUP_AT is "x,y".
  if (getenv("REDIWM_TEST_POPUP_SLIDE"))
    xdg_positioner_set_constraint_adjustment(
        pos, XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X |
                 XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y);
  const char *at = getenv("REDIWM_TEST_POPUP_AT");
  int at_x, at_y;
  if (at && sscanf(at, "%d,%d", &at_x, &at_y) == 2)
    xdg_positioner_set_anchor_rect(pos, at_x, at_y, 1, 1);
  struct xdg_popup *popup = xdg_surface_get_popup(popup_xdg, xdg, pos);
  xdg_popup_add_listener(popup, &popup_listener, NULL);
  xdg_positioner_destroy(pos);
  wl_surface_commit(popup_surface);
}
static void ping(void *d, struct xdg_wm_base *base, uint32_t serial) {
  (void)d;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};
static const char *name(struct wl_surface *s) {
  return s == surface ? "main" : s == child ? "child" : "popup";
}
static void pointer_enter(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
  (void)d;
  (void)p;
  (void)serial;
  printf("enter %s %.3f %.3f\n", name(s), wl_fixed_to_double(x),
         wl_fixed_to_double(y));
}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s) {
  (void)d;
  (void)p;
  (void)serial;
  (void)s;
}
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t time,
                           wl_fixed_t x, wl_fixed_t y) {
  (void)d;
  (void)p;
  (void)time;
  printf("motion %.3f %.3f\n", wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial,
                           uint32_t time, uint32_t b, uint32_t state) {
  (void)d;
  (void)p;
  (void)serial;
  (void)time;
  printf("button %u %u\n", b, state);
  if (b == 272 && state && getenv("REDIWM_TEST_RESIZE"))
    xdg_toplevel_resize(toplevel, seat, serial, XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT);
  if (b == 273 && state)
    open_popup();
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t time,
                         uint32_t axis, wl_fixed_t value) {
  (void)d;
  (void)p;
  (void)time;
  (void)axis;
  printf("axis %.3f\n", wl_fixed_to_double(value));
}
static void pointer_frame(void *d, struct wl_pointer *p) {
  (void)d;
  (void)p;
}
static void pointer_source(void *d, struct wl_pointer *p, uint32_t s) {
  (void)d;
  (void)p;
  (void)s;
}
static void pointer_stop(void *d, struct wl_pointer *p, uint32_t t,
                         uint32_t a) {
  (void)d;
  (void)p;
  (void)t;
  (void)a;
}
static void pointer_discrete(void *d, struct wl_pointer *p, uint32_t a,
                             int32_t v) {
  (void)d;
  (void)p;
  (void)a;
  (void)v;
}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_source,
    .axis_stop = pointer_stop,
    .axis_discrete = pointer_discrete};
static void keymap(void *d, struct wl_keyboard *k, uint32_t format, int32_t fd,
                   uint32_t size) {
  (void)d;
  (void)k;
  (void)format;
  (void)size;
  close(fd);
}
static void key_enter(void *d, struct wl_keyboard *k, uint32_t serial,
                      struct wl_surface *s, struct wl_array *keys) {
  (void)d;
  (void)k;
  (void)serial;
  (void)s;
  (void)keys;
}
static void key_leave(void *d, struct wl_keyboard *k, uint32_t serial,
                      struct wl_surface *s) {
  (void)d;
  (void)k;
  (void)serial;
  (void)s;
}
static void key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t time,
                uint32_t code, uint32_t state) {
  (void)d;
  (void)k;
  (void)serial;
  (void)time;
  printf("key %u %u\n", code, state);
  if (!state) return;
  if (decoration && code == 63)
    zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
  if (decoration && code == 64)
    zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  if (decoration && code == 65)
    zxdg_toplevel_decoration_v1_unset_mode(decoration);
  if (code == 66) xdg_toplevel_set_maximized(toplevel);
  if (code == 67) xdg_toplevel_unset_maximized(toplevel);
  if (code == 68) xdg_toplevel_set_minimized(toplevel);
  if (!edge_mode) return;
  if (code == 2) {
    top_color ^= 0x00ff00;
    edge_commit(1, 0, 0, width, height > 1 ? height - 1 : 1);
    puts("edge above");
  } else if (code == 3) {
    bot_color = bot_color == 0xff0000ff ? 0xff00ff00 : 0xff0000ff;
    edge_commit(1, 0, height - 1, width, 1);
    puts("edge row");
  } else if (code == 4) {
    edge_commit(1, 0, 0, 0, 0);
    puts("edge none");
  } else if (code == 5) {
    edge_commit(0, 0, 0, width, height > 1 ? height - 1 : 1);
    puts("edge rotate");
  } else if (code == 6) {
    edge_commit(0, 0, 0, width, height);
    puts("edge full");
  } else if (code == 7) {
    edge_buf_scale = edge_buf_scale == 1 ? 2 : 1;
    edge_commit(0, 0, 0, width, height);
    puts("edge scale");
  } else if (code == 8) {
    edge_transform = edge_transform ? 0 : WL_OUTPUT_TRANSFORM_90;
    edge_commit(0, 0, 0, width, height);
    puts("edge transform");
  } else if (code == 9) {
    edge_geom_inset = edge_geom_inset ? 0 : 8;
    edge_commit(0, 0, 0, width, height);
    puts("edge geometry");
  } else if (code == 10) {
    wl_surface_attach(surface, NULL, 0, 0);
    wl_surface_commit(surface);
    puts("edge unmap");
  } else if (code == 11) {
    edge_commit(0, 0, 0, width, height);
    puts("edge remap");
  }
}
static void modifiers(void *d, struct wl_keyboard *k, uint32_t serial,
                      uint32_t depressed, uint32_t latched, uint32_t locked,
                      uint32_t group) {
  (void)d;
  (void)k;
  (void)serial;
  (void)depressed;
  (void)latched;
  (void)locked;
  (void)group;
}
static void repeat(void *d, struct wl_keyboard *k, int32_t rate,
                   int32_t delay) {
  (void)d;
  (void)k;
  (void)rate;
  (void)delay;
}
static const struct wl_keyboard_listener keyboard_listener = {
    keymap, key_enter, key_leave, key, modifiers, repeat};
static void caps(void *d, struct wl_seat *s, uint32_t c) {
  (void)d;
  if (c & WL_SEAT_CAPABILITY_POINTER)
    wl_pointer_add_listener(wl_seat_get_pointer(s), &pointer_listener, NULL);
  if (c & WL_SEAT_CAPABILITY_KEYBOARD)
    wl_keyboard_add_listener(wl_seat_get_keyboard(s), &keyboard_listener, NULL);
}
static void seat_name(void *d, struct wl_seat *s, const char *n) {
  (void)d;
  (void)s;
  (void)n;
}
static const struct wl_seat_listener seat_listener = {caps, seat_name};
static void global(void *d, struct wl_registry *r, uint32_t id,
                   const char *interface, uint32_t version) {
  (void)d;
  (void)version;
  if (!strcmp(interface, "wl_compositor"))
    compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
  else if (!strcmp(interface, "wl_subcompositor"))
    subcompositor = wl_registry_bind(r, id, &wl_subcompositor_interface, 1);
  else if (!strcmp(interface, "wl_shm"))
    shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
  else if (!strcmp(interface, "zxdg_decoration_manager_v1"))
    decoration_manager = wl_registry_bind(r, id, &zxdg_decoration_manager_v1_interface, 1);
  else if (!strcmp(interface, "xdg_wm_base")) {
    wm = wl_registry_bind(r, id, &xdg_wm_base_interface, 2);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  } else if (!strcmp(interface, "wl_seat")) {
    seat = wl_registry_bind(r, id, &wl_seat_interface, 5);
    wl_seat_add_listener(seat, &seat_listener, NULL);
  } else if (!strcmp(interface, "wl_output"))
    wl_registry_bind(r, id, &wl_output_interface, 1);
}
static void removed(void *d, struct wl_registry *r, uint32_t id) {
  (void)d;
  (void)r;
  (void)id;
}
static const struct wl_registry_listener registry_listener = {global, removed};
static void decoration_configure(void *data, struct zxdg_toplevel_decoration_v1 *d, uint32_t mode) {
  (void)data;
  (void)d;
  printf("decoration %u\n", mode);
}
static const struct zxdg_toplevel_decoration_v1_listener decoration_listener = {decoration_configure};
int main(int argc, char *argv[]) {
  setbuf(stdout, NULL);
  edge_mode = getenv("REDIWM_TEST_EDGE") != NULL;
  perf_mode = getenv("REDIWM_TEST_PERF") != NULL;
  perf_damage = getenv("REDIWM_TEST_PERF_DAMAGE") != NULL;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--app-id") && i + 1 < argc) {
      app_id = argv[++i];
    } else if (!strcmp(argv[i], "--title") && i + 1 < argc) {
      title = argv[++i];
    } else if (!strcmp(argv[i], "--late-app-id")) {
      late_app_id = 1;
    }
  }
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *r = wl_display_get_registry(display);
  wl_registry_add_listener(r, &registry_listener, NULL);
  wl_display_roundtrip(display);
  assert(compositor && subcompositor && shm && wm);
  surface = wl_compositor_create_surface(compositor);
  wl_surface_add_listener(surface, &surface_listener, NULL);
  xdg = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  toplevel = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_add_listener(toplevel, &top_listener, NULL);
  if (title) xdg_toplevel_set_title(toplevel, title);
  if (!late_app_id && app_id) xdg_toplevel_set_app_id(toplevel, app_id);
  const char *initial_state = getenv("REDIWM_TEST_INITIAL_STATE");
  if (initial_state && !strcmp(initial_state, "maximized"))
    xdg_toplevel_set_maximized(toplevel);
  if (initial_state && !strcmp(initial_state, "fullscreen"))
    xdg_toplevel_set_fullscreen(toplevel, NULL);
  const char *mode = getenv("REDIWM_TEST_DECORATION");
  if (decoration_manager && (!mode || strcmp(mode, "absent"))) {
    decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decoration_manager, toplevel);
    zxdg_toplevel_decoration_v1_add_listener(decoration, &decoration_listener, NULL);
    if (!mode || strcmp(mode, "default"))
      zxdg_toplevel_decoration_v1_set_mode(decoration,
          mode && !strcmp(mode, "client") ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE : ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  }
  wl_surface_commit(surface);
  while (wl_display_dispatch(display) >= 0) {
  }
  return 0;
}
