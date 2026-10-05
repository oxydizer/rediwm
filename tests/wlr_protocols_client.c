#define _GNU_SOURCE
#include "xdg-shell-client-protocol.h"
#include "xdg-toplevel-tag-v1-client-protocol.h"
#include "content-type-v1-client-protocol.h"
#include "tearing-control-v1-client-protocol.h"
#include "color-management-v1-client-protocol.h"
#include "color-representation-v1-client-protocol.h"
#include "ext-workspace-v1-client-protocol.h"
// Test fixture for wlr-screencopy-unstable-v1 and ext-session-lock-v1.
//
//   screencopy        copy the first output once; prints "ready W H nonzero=N",
//                     "failed" or "disconnected"
//   lock              lock with a solid surface per output; prints "locked" or
//                     "finished", then obeys stdin: "unlock" or "exit" (dies
//                     without unlocking)
#include "ext-session-lock-v1-client-protocol.h"
#include "security-context-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include <assert.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

#define MAX_OUTPUTS 8

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_output *outputs[MAX_OUTPUTS];
static int output_count;
static struct zwlr_screencopy_manager_v1 *screencopy;
static struct ext_session_lock_manager_v1 *lock_manager;
static struct wp_security_context_manager_v1 *security_context_manager;
static bool dump_registry_mode = false;

static bool bind_extra(struct wl_registry *, uint32_t, const char *);
static bool extras_mode;
static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
  (void)data;
  (void)version;
  if (dump_registry_mode) {
    printf("%s\n", interface);
    return;
  }
  if (bind_extra(registry, name, interface)) return;
  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
  } else if (strcmp(interface, wl_shm_interface.name) == 0) {
    shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
  } else if (strcmp(interface, wl_output_interface.name) == 0 && output_count < MAX_OUTPUTS) {
    outputs[output_count++] = wl_registry_bind(registry, name, &wl_output_interface, 1);
  } else if (strcmp(interface, zwlr_screencopy_manager_v1_interface.name) == 0) {
    screencopy = wl_registry_bind(registry, name, &zwlr_screencopy_manager_v1_interface, 3);
  } else if (strcmp(interface, ext_session_lock_manager_v1_interface.name) == 0) {
    lock_manager = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
  } else if (strcmp(interface, wp_security_context_manager_v1_interface.name) == 0) {
    security_context_manager = wl_registry_bind(registry, name, &wp_security_context_manager_v1_interface, 1);
  }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

static struct wl_buffer *create_buffer(uint32_t format, int width, int height, int stride,
                                       uint32_t fill, void **pixels_out) {
  const size_t size = (size_t)stride * (size_t)height;
  int fd = memfd_create("wlr-protocols-fixture", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
  uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  for (size_t i = 0; i < size / 4; i++) pixels[i] = fill;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, format);
  wl_shm_pool_destroy(pool);
  close(fd);
  if (pixels_out) *pixels_out = pixels;
  return buffer;
}

// Dispatches until `done` or the connection drops ("disconnected", exit 3).
static void dispatch_until(const bool *done) {
  while (!*done) {
    if (wl_display_dispatch(display) < 0) {
      printf("disconnected\n");
      fflush(stdout);
      exit(3);
    }
  }
}

// ---- screencopy -----------------------------------------------------------

static struct {
  uint32_t format;
  int width, height, stride;
  bool have_shm, finished;
  uint32_t *pixels;
  struct wl_buffer *buffer;
} copy;

static void frame_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format,
                         uint32_t width, uint32_t height, uint32_t stride) {
  (void)data;
  (void)frame;
  copy.format = format;
  copy.width = (int)width;
  copy.height = (int)height;
  copy.stride = (int)stride;
  copy.have_shm = true;
}

static void frame_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t flags) {
  (void)data;
  (void)frame;
  (void)flags;
}

static void frame_ready(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t sec_hi,
                        uint32_t sec_lo, uint32_t nsec) {
  (void)data;
  (void)frame;
  (void)sec_hi;
  (void)sec_lo;
  (void)nsec;
  size_t nonzero = 0;
  for (int y = 0; y < copy.height; y++) {
    const uint32_t *row = (const uint32_t *)((const uint8_t *)copy.pixels + (size_t)y * (size_t)copy.stride);
    for (int x = 0; x < copy.width; x++) nonzero += (row[x] & 0x00ffffff) != 0;
  }
  printf("ready %d %d nonzero=%zu\n", copy.width, copy.height, nonzero);
  copy.finished = true;
}

static void frame_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
  (void)data;
  (void)frame;
  printf("failed\n");
  copy.finished = true;
}

static void frame_damage(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t x,
                         uint32_t y, uint32_t width, uint32_t height) {
  (void)data;
  (void)frame;
  (void)x;
  (void)y;
  (void)width;
  (void)height;
}

static void frame_linux_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame,
                               uint32_t format, uint32_t width, uint32_t height) {
  (void)data;
  (void)frame;
  (void)format;
  (void)width;
  (void)height;
}

static bool buffer_done;
static void frame_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
  (void)data;
  (void)frame;
  buffer_done = true;
}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    frame_buffer, frame_flags, frame_ready, frame_failed, frame_damage, frame_linux_dmabuf,
    frame_buffer_done,
};

static int run_screencopy(void) {
  if (!screencopy || output_count == 0) {
    printf("unsupported\n");
    return 2;
  }
  struct zwlr_screencopy_frame_v1 *frame =
      zwlr_screencopy_manager_v1_capture_output(screencopy, 0, outputs[0]);
  zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, NULL);
  dispatch_until(&buffer_done);
  assert(copy.have_shm);
  copy.buffer = create_buffer(copy.format, copy.width, copy.height, copy.stride, 0, (void **)&copy.pixels);
  zwlr_screencopy_frame_v1_copy(frame, copy.buffer);
  dispatch_until(&copy.finished);
  fflush(stdout);
  return 0;
}

// ---- ext-session-lock -----------------------------------------------------

static bool locked, finished;

static void lock_surface_configure(void *data, struct ext_session_lock_surface_v1 *lock_surface,
                                   uint32_t serial, uint32_t width, uint32_t height) {
  struct wl_surface *surface = data;
  ext_session_lock_surface_v1_ack_configure(lock_surface, serial);
  struct wl_buffer *buffer =
      create_buffer(WL_SHM_FORMAT_XRGB8888, (int)width, (int)height, (int)width * 4, 0xff203040, NULL);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage(surface, 0, 0, INT32_MAX, INT32_MAX);
  wl_surface_commit(surface);
}

static const struct ext_session_lock_surface_v1_listener lock_surface_listener = {
    lock_surface_configure,
};

static void lock_locked(void *data, struct ext_session_lock_v1 *lock) {
  (void)data;
  (void)lock;
  locked = true;
  printf("locked\n");
  fflush(stdout);
}

static void lock_finished(void *data, struct ext_session_lock_v1 *lock) {
  (void)data;
  (void)lock;
  finished = true;
  printf("finished\n");
  fflush(stdout);
}

static const struct ext_session_lock_v1_listener lock_listener = {lock_locked, lock_finished};

static int run_lock(void) {
  if (!lock_manager || !compositor || !shm) {
    printf("unsupported\n");
    return 2;
  }
  struct ext_session_lock_v1 *lock = ext_session_lock_manager_v1_lock(lock_manager);
  ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
  for (int i = 0; i < output_count; i++) {
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct ext_session_lock_surface_v1 *lock_surface =
        ext_session_lock_v1_get_lock_surface(lock, surface, outputs[i]);
    ext_session_lock_surface_v1_add_listener(lock_surface, &lock_surface_listener, surface);
  }
  wl_display_flush(display);

  char line[64];
  struct pollfd fds[2] = {
      {.fd = wl_display_get_fd(display), .events = POLLIN},
      {.fd = STDIN_FILENO, .events = POLLIN},
  };
  for (;;) {
    while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
    wl_display_flush(display);
    if (poll(fds, 2, -1) < 0) return 1;
    if (fds[0].revents & POLLIN) {
      if (wl_display_read_events(display) < 0) return 3;
    } else {
      wl_display_cancel_read(display);
    }
    if (wl_display_dispatch_pending(display) < 0) return 3;
    if (finished) {
      ext_session_lock_v1_destroy(lock);
      wl_display_roundtrip(display);
      return 0;
    }
    if (!(fds[1].revents & (POLLIN | POLLHUP))) continue;
    if (!fgets(line, sizeof(line), stdin) || strncmp(line, "exit", 4) == 0) _exit(0);
    if (strncmp(line, "unlock", 6) == 0 && locked) {
      ext_session_lock_v1_unlock_and_destroy(lock);
      wl_display_roundtrip(display);
      printf("unlocked\n");
      fflush(stdout);
      return 0;
    }
  }
}

static int run_security_context(const char *socket_path, const char *engine, const char *app_id, const char *instance_id) {
  if (!security_context_manager) {
    printf("unsupported\n");
    fflush(stdout);
    return 2;
  }
  int listen_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  assert(listen_fd >= 0);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
  unlink(socket_path);
  if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(listen_fd, 16) < 0) {
    perror("bind/listen failed");
    close(listen_fd);
    return 1;
  }

  int close_pipe[2];
  assert(pipe2(close_pipe, O_CLOEXEC) == 0);

  struct wp_security_context_v1 *ctx =
      wp_security_context_manager_v1_create_listener(security_context_manager, listen_fd, close_pipe[0]);
  close(listen_fd);
  close(close_pipe[0]);

  if (engine && strcmp(engine, "none") != 0 && strcmp(engine, "-") != 0) {
    wp_security_context_v1_set_sandbox_engine(ctx, engine);
  }
  if (app_id && strcmp(app_id, "none") != 0 && strcmp(app_id, "-") != 0) {
    wp_security_context_v1_set_app_id(ctx, app_id);
  }
  if (instance_id && strcmp(instance_id, "none") != 0 && strcmp(instance_id, "-") != 0) {
    wp_security_context_v1_set_instance_id(ctx, instance_id);
  }
  wp_security_context_v1_commit(ctx);
  wp_security_context_v1_destroy(ctx);
  wl_display_roundtrip(display);

  printf("listening\n");
  fflush(stdout);

  char line[64];
  while (fgets(line, sizeof(line), stdin)) {
    if (strncmp(line, "exit", 4) == 0) break;
  }
  close(close_pipe[1]);
  unlink(socket_path);
  return 0;
}

// ---- supplementary standard protocols ------------------------------------
static struct xdg_wm_base *xdg;
static struct xdg_toplevel_tag_manager_v1 *tags;
static struct wp_content_type_manager_v1 *content_manager;
static struct wp_tearing_control_manager_v1 *tearing_manager;
static struct wp_color_manager_v1 *color_manager;
static struct wp_color_representation_manager_v1 *representation_manager;
static struct ext_workspace_manager_v1 *workspace_manager;
static bool parametric_supported;
static uint32_t supported_tf, supported_primaries;
static bool configured, image_ready, color_done, representation_done;
static unsigned workspace_count, group_count, workspace_outputs;
static bool canvas_name, canvas_id, canvas_active;
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data; xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener xdg_listener = {.ping = ping};
static void ws_id(void *data, struct ext_workspace_handle_v1 *w, const char *id) {
  (void)data; (void)w; canvas_id = strcmp(id, "rediwm-canvas") == 0;
}
static void ws_name(void *data, struct ext_workspace_handle_v1 *w, const char *name) {
  (void)data; (void)w; canvas_name = strcmp(name, "Canvas") == 0;
}
static void ws_coordinates(void *data, struct ext_workspace_handle_v1 *w, struct wl_array *coords) {
  (void)data; (void)w; (void)coords;
}
static void ws_state(void *data, struct ext_workspace_handle_v1 *w, uint32_t state) {
  (void)data; (void)w; canvas_active = (state & EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE) != 0;
}
static void ws_caps(void *data, struct ext_workspace_handle_v1 *w, uint32_t caps) {
  (void)data; (void)w; assert(caps == 0);
}
static void ws_removed(void *data, struct ext_workspace_handle_v1 *w) { (void)data; (void)w; }
static const struct ext_workspace_handle_v1_listener ws_listener = {
  .id = ws_id, .name = ws_name, .coordinates = ws_coordinates,
  .state = ws_state, .capabilities = ws_caps, .removed = ws_removed,
};
static void group_caps(void *d, struct ext_workspace_group_handle_v1 *g, uint32_t caps) {
  (void)d; (void)g; assert(caps == 0);
}
static void group_output_enter(void *d, struct ext_workspace_group_handle_v1 *g, struct wl_output *o) {
  (void)d; (void)g; (void)o; workspace_outputs++;
}
static void group_output_leave(void *d, struct ext_workspace_group_handle_v1 *g, struct wl_output *o) {
  (void)d; (void)g; (void)o; workspace_outputs--;
}
static void group_workspace(void *d, struct ext_workspace_group_handle_v1 *g, struct ext_workspace_handle_v1 *w) {
  (void)d; (void)g; (void)w;
}
static void group_removed(void *d, struct ext_workspace_group_handle_v1 *g) { (void)d; (void)g; }
static const struct ext_workspace_group_handle_v1_listener group_listener = {
  .capabilities = group_caps, .output_enter = group_output_enter, .output_leave = group_output_leave,
  .workspace_enter = group_workspace, .workspace_leave = group_workspace, .removed = group_removed,
};
static void workspace_group(void *d, struct ext_workspace_manager_v1 *m, struct ext_workspace_group_handle_v1 *g) {
  (void)d; (void)m; group_count++; ext_workspace_group_handle_v1_add_listener(g, &group_listener, NULL);
}
static void workspace(void *d, struct ext_workspace_manager_v1 *m, struct ext_workspace_handle_v1 *w) {
  (void)d; (void)m; workspace_count++; ext_workspace_handle_v1_add_listener(w, &ws_listener, NULL);
}
static void workspace_done(void *d, struct ext_workspace_manager_v1 *m) { (void)d; (void)m; }
static const struct ext_workspace_manager_v1_listener workspace_listener = {
  .workspace_group = workspace_group, .workspace = workspace, .done = workspace_done, .finished = workspace_done,
};
static void color_uint(void *d, struct wp_color_manager_v1 *m, uint32_t v) { (void)d; (void)m; (void)v; }
static void color_feature(void *d, struct wp_color_manager_v1 *m, uint32_t v) {
  (void)d; (void)m; if (v == WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC) parametric_supported = true;
}
static void color_tf(void *d, struct wp_color_manager_v1 *m, uint32_t v) {
  (void)d; (void)m; if (!supported_tf || v == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22) supported_tf = v;
}
static void color_primaries(void *d, struct wp_color_manager_v1 *m, uint32_t v) {
  (void)d; (void)m; if (!supported_primaries || v == WP_COLOR_MANAGER_V1_PRIMARIES_SRGB) supported_primaries = v;
}
static void color_finished(void *d, struct wp_color_manager_v1 *m) { (void)d; (void)m; color_done = true; }
static const struct wp_color_manager_v1_listener color_listener = {
  .supported_intent = color_uint, .supported_feature = color_feature,
  .supported_tf_named = color_tf, .supported_primaries_named = color_primaries, .done = color_finished,
};
static void alpha_mode(void *d, struct wp_color_representation_manager_v1 *m, uint32_t v) { (void)d; (void)m; (void)v; }
static void coeff_range(void *d, struct wp_color_representation_manager_v1 *m, uint32_t c, uint32_t r) { (void)d; (void)m; (void)c; (void)r; }
static void representation_finished(void *d, struct wp_color_representation_manager_v1 *m) { (void)d; (void)m; representation_done = true; }
static const struct wp_color_representation_manager_v1_listener representation_listener = {
  .supported_alpha_mode = alpha_mode, .supported_coefficients_and_ranges = coeff_range, .done = representation_finished,
};
static bool bind_extra(struct wl_registry *r, uint32_t name, const char *iface) {
  if (!extras_mode) return false;
#define BIND(member, type) if (strcmp(iface, #type) == 0) { member = wl_registry_bind(r, name, &type##_interface, 1);
  BIND(xdg, xdg_wm_base) xdg_wm_base_add_listener(xdg, &xdg_listener, NULL); }
  else BIND(tags, xdg_toplevel_tag_manager_v1) }
  else BIND(content_manager, wp_content_type_manager_v1) }
  else BIND(tearing_manager, wp_tearing_control_manager_v1) }
  else BIND(color_manager, wp_color_manager_v1) wp_color_manager_v1_add_listener(color_manager, &color_listener, NULL); }
  else BIND(representation_manager, wp_color_representation_manager_v1) wp_color_representation_manager_v1_add_listener(representation_manager, &representation_listener, NULL); }
  else BIND(workspace_manager, ext_workspace_manager_v1) ext_workspace_manager_v1_add_listener(workspace_manager, &workspace_listener, NULL); }
  else return false;
#undef BIND
  return true;
}
static void configured_surface(void *d, struct xdg_surface *s, uint32_t serial) {
  (void)d; xdg_surface_ack_configure(s, serial); configured = true;
}
static const struct xdg_surface_listener surface_listener = {.configure = configured_surface};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
  (void)d; (void)t; (void)w; (void)h; (void)states;
}
static void top_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; }
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = top_close};
static void image_failed(void *d, struct wp_image_description_v1 *i, uint32_t cause, const char *msg) {
  (void)d; (void)i; (void)cause; fprintf(stderr, "image description: %s\n", msg); abort();
}
static void image_created(void *d, struct wp_image_description_v1 *i, uint32_t identity) {
  (void)d; (void)i; (void)identity; image_ready = true;
}
static const struct wp_image_description_v1_listener image_listener = {.failed = image_failed, .ready = image_created};
static int run_extras(void) {
  assert(xdg && tags && content_manager && tearing_manager && color_manager && representation_manager && workspace_manager);
  assert(wl_display_roundtrip(display) >= 0);
  assert(workspace_count == 1 && group_count == 1 && canvas_name && canvas_id && canvas_active && workspace_outputs == (unsigned)output_count);
  assert(color_done && representation_done);
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(xdg, surface);
  xdg_surface_add_listener(xs, &surface_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
  xdg_toplevel_add_listener(top, &top_listener, NULL);
  xdg_toplevel_set_app_id(top, "rediwm.protocol-extras");
  xdg_toplevel_set_fullscreen(top, outputs[0]);
  xdg_toplevel_tag_manager_v1_set_toplevel_tag(tags, top, "settings");
  xdg_toplevel_tag_manager_v1_set_toplevel_description(tags, top, "Settings window");
  struct wp_content_type_v1 *content = wp_content_type_manager_v1_get_surface_content_type(content_manager, surface);
  wp_content_type_v1_set_content_type(content, WP_CONTENT_TYPE_V1_TYPE_VIDEO);
  struct wp_tearing_control_v1 *tearing = wp_tearing_control_manager_v1_get_tearing_control(tearing_manager, surface);
  wp_tearing_control_v1_set_presentation_hint(tearing, WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC);
  struct wp_color_representation_surface_v1 *representation = wp_color_representation_manager_v1_get_surface(representation_manager, surface);
  wp_color_representation_surface_v1_set_alpha_mode(representation, WP_COLOR_REPRESENTATION_SURFACE_V1_ALPHA_MODE_PREMULTIPLIED_ELECTRICAL);
  struct wp_color_management_surface_v1 *color = wp_color_manager_v1_get_surface(color_manager, surface);
  if (parametric_supported) {
  assert(supported_tf && supported_primaries);
  struct wp_image_description_creator_params_v1 *params = wp_color_manager_v1_create_parametric_creator(color_manager);
  wp_image_description_creator_params_v1_set_tf_named(params, supported_tf);
  wp_image_description_creator_params_v1_set_primaries_named(params, supported_primaries);
  struct wp_image_description_v1 *image = wp_image_description_creator_params_v1_create(params);
  wp_image_description_v1_add_listener(image, &image_listener, NULL);
  dispatch_until(&image_ready);
  wp_color_management_surface_v1_set_image_description(color, image, WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
  wp_image_description_v1_destroy(image);
  }
  wl_surface_commit(surface);
  dispatch_until(&configured);
  struct wl_buffer *buffer = create_buffer(WL_SHM_FORMAT_ARGB8888, 160, 100, 640, 0xff448866, NULL);
  wl_surface_attach(surface, buffer, 0, 0); wl_surface_damage(surface, 0, 0, 160, 100); wl_surface_commit(surface);
  assert(wl_display_roundtrip(display) >= 0);
  puts("extras-ready"); fflush(stdout);
  char line[80];
  while (fgets(line, sizeof(line), stdin)) {
    if (strncmp(line, "exit", 4) == 0) break;
    xdg_toplevel_tag_manager_v1_set_toplevel_tag(tags, top, "main");
    wp_content_type_v1_set_content_type(content, WP_CONTENT_TYPE_V1_TYPE_GAME);
    wp_tearing_control_v1_set_presentation_hint(tearing, WP_TEARING_CONTROL_V1_PRESENTATION_HINT_VSYNC);
    wl_surface_commit(surface);
    assert(wl_display_roundtrip(display) >= 0);
    puts("extras-updated"); fflush(stdout);
  }
  xdg_toplevel_destroy(top); xdg_surface_destroy(xs); wl_surface_destroy(surface);
  assert(wl_display_roundtrip(display) >= 0);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s screencopy|lock|security-context|dump-registry|guess-bind|try-nested\n", argv[0]);
    return 1;
  }
  if (strcmp(argv[1], "dump-registry") == 0) dump_registry_mode = true;
  extras_mode = strcmp(argv[1], "extras") == 0;
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (extras_mode) return run_extras();
  if (strcmp(argv[1], "screencopy") == 0) return run_screencopy();
  if (strcmp(argv[1], "lock") == 0) return run_lock();
  if (strcmp(argv[1], "dump-registry") == 0) {
    printf("done\n");
    fflush(stdout);
    return 0;
  }
  if (strcmp(argv[1], "security-context") == 0) {
    if (argc < 3) return 1;
    const char *sock_path = argv[2];
    const char *engine = argc > 3 ? argv[3] : "org.rediwm.test";
    const char *app_id = argc > 4 ? argv[4] : "org.example.Sandboxed";
    const char *instance_id = argc > 5 ? argv[5] : NULL;
    return run_security_context(sock_path, engine, app_id, instance_id);
  }
  if (strcmp(argv[1], "guess-bind") == 0) {
    if (argc < 4) return 1;
    uint32_t id = (uint32_t)atoi(argv[2]);
    const char *iface_name = argv[3];
    uint32_t ver = argc > 4 ? (uint32_t)atoi(argv[4]) : 1;
    struct wl_interface dummy_iface = {
        .name = iface_name,
        .version = (int)ver,
        .method_count = 0,
        .methods = NULL,
        .event_count = 0,
        .events = NULL,
    };
    wl_registry_bind(registry, id, &dummy_iface, ver);
    int rc = wl_display_roundtrip(display);
    if (rc < 0 || wl_display_get_error(display) != 0) {
      printf("error: %d\n", wl_display_get_error(display));
      fflush(stdout);
      return 0;
    }
    printf("bound\n");
    fflush(stdout);
    return 1;
  }
  if (strcmp(argv[1], "try-nested") == 0) {
    if (!security_context_manager) {
      printf("not_advertised\n");
      fflush(stdout);
      return 0;
    }
    int fds[2];
    assert(pipe2(fds, O_CLOEXEC) == 0);
    wp_security_context_manager_v1_create_listener(security_context_manager, fds[0], fds[1]);
    close(fds[0]);
    close(fds[1]);
    int rc = wl_display_roundtrip(display);
    if (rc < 0 || wl_display_get_error(display) != 0) {
      printf("nested_error: %d\n", wl_display_get_error(display));
      fflush(stdout);
      return 0;
    }
    printf("unexpected_success\n");
    fflush(stdout);
    return 1;
  }
  return 1;
}
