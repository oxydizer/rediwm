// Real ext-image-copy-capture-v1 / ext-image-capture-source-v1 wire traffic:
// present a known solid-color window, then capture it through the actual
// protocol (no compositor-internal screenshot IPC) and let the Python driver
// sample specific pixels out of the returned buffer. Supports the whole-output
// shm path ("capture"), a real GBM/DMA-BUF path ("capture_dmabuf"), and the
// stage 3 per-window shm path ("window_capture", via
// ext-foreign-toplevel-list-v1 + ext-foreign-toplevel-image-capture-source-v1
// against this client's own toplevel handle).
#define _GNU_SOURCE
#include "ext-foreign-toplevel-list-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "single-pixel-buffer-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include <assert.h>
#include <drm/drm_fourcc.h>
#include <fcntl.h>
#include <gbm.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <wayland-client.h>

#define WIDTH 200
#define HEIGHT 150

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_viewporter *viewporter;
static struct wp_single_pixel_buffer_manager_v1 *pixel_mgr;
static struct wl_output *output;
static struct ext_image_copy_capture_manager_v1 *copy_mgr;
static struct ext_output_image_capture_source_manager_v1 *source_mgr;
static struct ext_foreign_toplevel_list_v1 *toplevel_list;
static struct ext_foreign_toplevel_image_capture_source_manager_v1 *toplevel_source_mgr;
static struct zwp_linux_dmabuf_v1 *dmabuf_mgr;

// The fixture's own toplevel, matched by app_id among whatever handles the
// compositor advertises (a real desktop may have other windows/handles).
static struct ext_foreign_toplevel_handle_v1 *fixture_handle;
static bool fixture_handle_done;

static struct ext_image_capture_source_v1 *source;
static struct ext_image_copy_capture_session_v1 *session;
static struct ext_image_copy_capture_frame_v1 *frame;

static uint32_t buf_width, buf_height;
static uint32_t shm_format;
static bool have_shm_format;
static bool session_done_flag, session_stopped_flag;

// The currently mapped capture destination, whichever path produced it:
// a plain shm mmap, or a mapped GBM dma-buf transfer. `sample` reads from
// here using `active_stride`, which may exceed width*4 once GBM allocation
// alignment enters the picture.
static void *pixels;
static uint32_t pixels_size;
static uint32_t active_stride;

static uint8_t dmabuf_device_bytes[32];
static size_t dmabuf_device_len;
static uint32_t dmabuf_format_code;
static uint64_t dmabuf_modifier;
static bool have_dmabuf_format;

static struct gbm_device *gbm_dev;
static int gbm_fd = -1;
static struct gbm_bo *gbm_active_bo;
static void *gbm_map_data;

static void top_configure(void *data, struct xdg_toplevel *top, int32_t w, int32_t h, struct wl_array *states) {
  (void)data; (void)top; (void)w; (void)h; (void)states;
}
static void top_close(void *data, struct xdg_toplevel *top) {
  (void)data; (void)top;
  exit(0);
}
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = top_close};

static struct wl_surface *surface;
static struct wp_viewport *viewport;

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
  (void)data; (void)time;
  wl_callback_destroy(callback);
  printf("presented\n");
}
static const struct wl_callback_listener frame_listener = {frame_done};

// Overridable via env so the Python driver can run two independent fixture
// clients at once (stage 3's occlusion and destroy cases): each must have
// its own app_id to unambiguously match its own
// ext_foreign_toplevel_handle_v1, and a distinguishable color to prove
// which window a capture actually returned. `capture_target_app_id`
// defaults to this client's own app_id, but the destroy case points a
// second "watcher" client's `window_capture` at a *different* client's
// window, to prove that client's disconnect stops the watcher's session
// gracefully rather than leaving it hanging.
static const char *fixture_app_id = "rediwm.capture-fixture";
static const char *capture_target_app_id;
static bool fixture_green;

static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(xdg, serial);
  static bool drawn;
  if (drawn) return;
  drawn = true;
  wp_viewport_set_destination(viewport, WIDTH, HEIGHT);
  struct wl_buffer *buffer = fixture_green
      ? wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(pixel_mgr, 0, 0xffffffff, 0, 0xffffffff)
      : wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(pixel_mgr, 0xffffffff, 0, 0, 0xffffffff);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage(surface, 0, 0, INT32_MAX, INT32_MAX);
  wl_callback_add_listener(wl_surface_frame(surface), &frame_listener, NULL);
  wl_surface_commit(surface);
}
// Stage 3's resize case: change only the surface's logical (viewport
// destination) size and re-commit, without a new xdg_surface configure
// round-trip — enough to move `Toplevel.clientGeometry()`, which is all a
// window capture source keys its buffer size off of.
static void resize_surface(unsigned w, unsigned h) {
  wp_viewport_set_destination(viewport, (int32_t)w, (int32_t)h);
  wl_surface_damage(surface, 0, 0, INT32_MAX, INT32_MAX);
  wl_surface_commit(surface);
  printf("resized %u %u\n", w, h);
}
static const struct xdg_surface_listener xdg_listener = {configure};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};

static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
  (void)data;
  if (!strcmp(interface, "wl_compositor")) {
    compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
  } else if (!strcmp(interface, "wl_shm")) {
    shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
  } else if (!strcmp(interface, "xdg_wm_base")) {
    wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  } else if (!strcmp(interface, "wp_viewporter")) {
    viewporter = wl_registry_bind(registry, id, &wp_viewporter_interface, 1);
  } else if (!strcmp(interface, "wp_single_pixel_buffer_manager_v1")) {
    pixel_mgr = wl_registry_bind(registry, id, &wp_single_pixel_buffer_manager_v1_interface, 1);
  } else if (!strcmp(interface, "wl_output")) {
    assert(!output && "fixture expects exactly one output");
    output = wl_registry_bind(registry, id, &wl_output_interface, version >= 4 ? 4 : version);
  } else if (!strcmp(interface, "ext_image_copy_capture_manager_v1")) {
    assert(version == 1);
    copy_mgr = wl_registry_bind(registry, id, &ext_image_copy_capture_manager_v1_interface, 1);
  } else if (!strcmp(interface, "ext_output_image_capture_source_manager_v1")) {
    assert(version == 1);
    source_mgr = wl_registry_bind(registry, id, &ext_output_image_capture_source_manager_v1_interface, 1);
  } else if (!strcmp(interface, "zwp_linux_dmabuf_v1")) {
    dmabuf_mgr = wl_registry_bind(registry, id, &zwp_linux_dmabuf_v1_interface, version >= 2 ? 2 : version);
  } else if (!strcmp(interface, "ext_foreign_toplevel_list_v1")) {
    toplevel_list = wl_registry_bind(registry, id, &ext_foreign_toplevel_list_v1_interface, 1);
  } else if (!strcmp(interface, "ext_foreign_toplevel_image_capture_source_manager_v1")) {
    assert(version == 1);
    toplevel_source_mgr = wl_registry_bind(
        registry, id, &ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1);
  }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
  (void)data; (void)registry; (void)id;
}
static const struct wl_registry_listener registry_listener = {global, removed};

static void toplevel_handle_title(void *data, struct ext_foreign_toplevel_handle_v1 *h, const char *title) {
  (void)data; (void)h; (void)title;
}
static char toplevel_handle_app_id_buf[128];
static void toplevel_handle_app_id(void *data, struct ext_foreign_toplevel_handle_v1 *h, const char *app_id) {
  (void)data; (void)h;
  // Track the app_id of whichever handle is currently being described (the
  // protocol sends a handle's initial properties as a contiguous burst
  // ending in `done`); `toplevel_handle_done` below decides if it's ours.
  snprintf(toplevel_handle_app_id_buf, sizeof(toplevel_handle_app_id_buf), "%s", app_id);
}
static void toplevel_handle_identifier(void *data, struct ext_foreign_toplevel_handle_v1 *h, const char *identifier) {
  (void)data; (void)h; (void)identifier;
}
static void toplevel_handle_closed(void *data, struct ext_foreign_toplevel_handle_v1 *h) {
  (void)data;
  if (h == fixture_handle) fixture_handle = NULL;
}
static struct ext_foreign_toplevel_handle_v1 *pending_handle;
static void toplevel_handle_done(void *data, struct ext_foreign_toplevel_handle_v1 *h) {
  (void)data;
  if (h == pending_handle && !strcmp(toplevel_handle_app_id_buf, capture_target_app_id)) {
    fixture_handle = h;
    fixture_handle_done = true;
  }
}
static const struct ext_foreign_toplevel_handle_v1_listener toplevel_handle_listener = {
  .closed = toplevel_handle_closed,
  .done = toplevel_handle_done,
  .title = toplevel_handle_title,
  .app_id = toplevel_handle_app_id,
  .identifier = toplevel_handle_identifier,
};
static void toplevel_list_toplevel(void *data, struct ext_foreign_toplevel_list_v1 *list,
                                    struct ext_foreign_toplevel_handle_v1 *handle) {
  (void)data; (void)list;
  pending_handle = handle;
  toplevel_handle_app_id_buf[0] = '\0';
  ext_foreign_toplevel_handle_v1_add_listener(handle, &toplevel_handle_listener, NULL);
}
static void toplevel_list_finished(void *data, struct ext_foreign_toplevel_list_v1 *list) {
  (void)data; (void)list;
}
static const struct ext_foreign_toplevel_list_v1_listener toplevel_list_listener = {
  .toplevel = toplevel_list_toplevel,
  .finished = toplevel_list_finished,
};

static void session_buffer_size(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t width, uint32_t height) {
  (void)data; (void)s;
  buf_width = width;
  buf_height = height;
}
static void session_shm_format(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t format) {
  (void)data; (void)s;
  if (!have_shm_format) {
    shm_format = format;
    have_shm_format = true;
  }
}
static void session_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *s, struct wl_array *device) {
  (void)data; (void)s;
  dmabuf_device_len = device->size < sizeof(dmabuf_device_bytes) ? device->size : sizeof(dmabuf_device_bytes);
  memcpy(dmabuf_device_bytes, device->data, dmabuf_device_len);
}
static void session_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *s, uint32_t format, struct wl_array *modifiers) {
  (void)data; (void)s;
  // First advertised format/modifier pair is enough for this compatibility
  // spike; a real client would pick based on its own supported formats.
  if (!have_dmabuf_format && modifiers->size >= sizeof(uint64_t)) {
    dmabuf_format_code = format;
    dmabuf_modifier = ((uint64_t *)modifiers->data)[0];
    have_dmabuf_format = true;
  }
}
static void session_done(void *data, struct ext_image_copy_capture_session_v1 *s) {
  (void)data; (void)s;
  session_done_flag = true;
}
static void session_stopped(void *data, struct ext_image_copy_capture_session_v1 *s) {
  (void)data; (void)s;
  session_stopped_flag = true;
  printf("stopped\n");
}
static const struct ext_image_copy_capture_session_v1_listener session_listener = {
  .buffer_size = session_buffer_size,
  .shm_format = session_shm_format,
  .dmabuf_device = session_dmabuf_device,
  .dmabuf_format = session_dmabuf_format,
  .done = session_done,
  .stopped = session_stopped,
};

static void frame_transform(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t transform) {
  (void)data; (void)f; (void)transform;
}
static void frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *f, int32_t x, int32_t y, int32_t width, int32_t height) {
  (void)data; (void)f; (void)x; (void)y; (void)width; (void)height;
}
static void frame_presentation_time(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t hi, uint32_t lo, uint32_t nsec) {
  (void)data; (void)f; (void)hi; (void)lo; (void)nsec;
}
static bool frame_ready_flag, frame_failed_flag;
static uint32_t frame_failed_reason;
static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f) {
  (void)data; (void)f;
  frame_ready_flag = true;
}
static void frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
  (void)data; (void)f;
  frame_failed_flag = true;
  frame_failed_reason = reason;
}
static const struct ext_image_copy_capture_frame_v1_listener frame_listener_v = {
  .transform = frame_transform,
  .damage = frame_damage,
  .presentation_time = frame_presentation_time,
  .ready = frame_ready,
  .failed = frame_failed,
};

// Shared by begin_capture (output source) and begin_window_capture (foreign-
// toplevel source): create a session on whichever source was just obtained,
// wait for real buffer_size/shm_format events, then capture one shm frame.
static void capture_via_source(void) {
  session = ext_image_copy_capture_manager_v1_create_session(copy_mgr, source, 0);
  // Reset per-session/per-frame flags so a second "capture" command in the
  // same process (proving a fresh request recovers after a stopped session)
  // waits for this session's own real events instead of falling straight
  // through on a previous session's stale true flags.
  session_done_flag = session_stopped_flag = false;
  have_shm_format = false;
  frame_ready_flag = frame_failed_flag = false;
  ext_image_copy_capture_session_v1_add_listener(session, &session_listener, NULL);
  while (!session_done_flag && !session_stopped_flag) assert(wl_display_dispatch(display) >= 0);
  assert(session_done_flag);
  assert(have_shm_format);
  assert(buf_width > 0 && buf_height > 0);

  uint32_t stride = buf_width * 4;
  active_stride = stride;
  pixels_size = stride * buf_height;
  int fd = memfd_create("capture-shm", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, pixels_size) == 0);
  pixels = mmap(NULL, pixels_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)pixels_size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, (int32_t)buf_width, (int32_t)buf_height, (int32_t)stride, shm_format);
  wl_shm_pool_destroy(pool);
  close(fd);

  frame = ext_image_copy_capture_session_v1_create_frame(session);
  ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener_v, NULL);
  ext_image_copy_capture_frame_v1_attach_buffer(frame, buffer);
  ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, (int32_t)buf_width, (int32_t)buf_height);
  ext_image_copy_capture_frame_v1_capture(frame);

  while (!frame_ready_flag && !frame_failed_flag) assert(wl_display_dispatch(display) >= 0);
  if (frame_failed_flag) {
    printf("failed %u\n", frame_failed_reason);
  } else {
    printf("ready %u %u %u\n", buf_width, buf_height, shm_format);
  }
}

static void begin_capture(void) {
  source = ext_output_image_capture_source_manager_v1_create_source(source_mgr, output);
  capture_via_source();
}

// Stage 3 (docs/screen-sharing.md): request a per-window source through
// ext_foreign_toplevel_image_capture_source_manager_v1 instead of the output
// manager, against the fixture's own toplevel handle (matched by app_id via
// ext_foreign_toplevel_list_v1, not assumed to be the first/only handle).
static void begin_window_capture(void) {
  assert(fixture_handle_done && fixture_handle && "fixture toplevel handle not seen yet");
  source = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(toplevel_source_mgr, fixture_handle);
  capture_via_source();
}

// The dmabuf_device event carries a raw dev_t. Real clients (and this one)
// resolve it through sysfs rather than assuming a fixed render node, since
// nothing in the protocol guarantees which node the compositor will name.
static int open_dmabuf_device(void) {
  assert(dmabuf_device_len == sizeof(dev_t));
  dev_t dev;
  memcpy(&dev, dmabuf_device_bytes, sizeof(dev));
  char uevent_path[64];
  snprintf(uevent_path, sizeof(uevent_path), "/sys/dev/char/%u:%u/uevent", major(dev), minor(dev));
  FILE *f = fopen(uevent_path, "r");
  assert(f);
  char line[256], devname[128] = {0};
  while (fgets(line, sizeof(line), f)) {
    if (sscanf(line, "DEVNAME=%127s", devname) == 1) break;
  }
  fclose(f);
  assert(devname[0]);
  char dev_path[160];
  snprintf(dev_path, sizeof(dev_path), "/dev/%s", devname);
  printf("dmabuf_device %s\n", dev_path);
  return open(dev_path, O_RDWR | O_CLOEXEC);
}

static void begin_capture_dmabuf(void) {
  source = ext_output_image_capture_source_manager_v1_create_source(source_mgr, output);
  session = ext_image_copy_capture_manager_v1_create_session(copy_mgr, source, 0);
  session_done_flag = session_stopped_flag = false;
  have_shm_format = have_dmabuf_format = false;
  ext_image_copy_capture_session_v1_add_listener(session, &session_listener, NULL);
  while (!session_done_flag && !session_stopped_flag) assert(wl_display_dispatch(display) >= 0);
  assert(session_done_flag);
  assert(have_dmabuf_format);
  assert(buf_width > 0 && buf_height > 0);

  gbm_fd = open_dmabuf_device();
  assert(gbm_fd >= 0);
  gbm_dev = gbm_create_device(gbm_fd);
  assert(gbm_dev);

  struct gbm_bo *bo;
  if (dmabuf_modifier == DRM_FORMAT_MOD_INVALID) {
    bo = gbm_bo_create(gbm_dev, buf_width, buf_height, dmabuf_format_code, GBM_BO_USE_RENDERING);
  } else {
    bo = gbm_bo_create_with_modifiers2(gbm_dev, buf_width, buf_height, dmabuf_format_code,
                                        &dmabuf_modifier, 1, GBM_BO_USE_RENDERING);
  }
  assert(bo);
  gbm_active_bo = bo;

  int dmabuf_fd = gbm_bo_get_fd(bo);
  assert(dmabuf_fd >= 0);
  uint32_t bo_stride = gbm_bo_get_stride(bo);
  uint32_t bo_offset = gbm_bo_get_offset(bo, 0);
  uint64_t bo_modifier = gbm_bo_get_modifier(bo);
  printf("dmabuf_alloc %u %u %u %#lx\n", bo_stride, bo_offset, dmabuf_format_code, (unsigned long)bo_modifier);

  struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(dmabuf_mgr);
  zwp_linux_buffer_params_v1_add(params, dmabuf_fd, 0, bo_offset, bo_stride,
                                  (uint32_t)(bo_modifier >> 32), (uint32_t)(bo_modifier & 0xffffffff));
  struct wl_buffer *buffer = zwp_linux_buffer_params_v1_create_immed(
      params, (int32_t)buf_width, (int32_t)buf_height, dmabuf_format_code, 0);
  zwp_linux_buffer_params_v1_destroy(params);
  close(dmabuf_fd);
  // Surface a fatal INVALID_WL_BUFFER/INVALID_FORMAT protocol error now,
  // rather than have it show up confusingly on the later capture request.
  assert(wl_display_roundtrip(display) >= 0);

  frame = ext_image_copy_capture_session_v1_create_frame(session);
  ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener_v, NULL);
  ext_image_copy_capture_frame_v1_attach_buffer(frame, buffer);
  ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, (int32_t)buf_width, (int32_t)buf_height);
  frame_ready_flag = frame_failed_flag = false;
  ext_image_copy_capture_frame_v1_capture(frame);

  while (!frame_ready_flag && !frame_failed_flag) assert(wl_display_dispatch(display) >= 0);
  if (frame_failed_flag) {
    printf("failed %u\n", frame_failed_reason);
    return;
  }

  uint32_t map_stride = 0;
  pixels = gbm_bo_map(bo, 0, 0, buf_width, buf_height, GBM_BO_TRANSFER_READ, &map_stride, &gbm_map_data);
  assert(pixels && pixels != MAP_FAILED);
  active_stride = map_stride;
  printf("ready %u %u %u\n", buf_width, buf_height, dmabuf_format_code);
}

int main(void) {
  setbuf(stdout, NULL);
  const char *app_id_override = getenv("CAPTURE_APP_ID");
  if (app_id_override) fixture_app_id = app_id_override;
  fixture_green = getenv("CAPTURE_GREEN") != NULL;
  const char *target_override = getenv("CAPTURE_TARGET_APP_ID");
  capture_target_app_id = target_override ? target_override : fixture_app_id;
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  assert(wl_display_roundtrip(display) >= 0);
  assert(compositor && shm && wm && viewporter && pixel_mgr && output);
  assert(copy_mgr && source_mgr);
  assert(toplevel_list && toplevel_source_mgr);
  ext_foreign_toplevel_list_v1_add_listener(toplevel_list, &toplevel_list_listener, NULL);

  surface = wl_compositor_create_surface(compositor);
  viewport = wp_viewporter_get_viewport(viewporter, surface);
  struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_add_listener(top, &top_listener, NULL);
  xdg_toplevel_set_app_id(top, fixture_app_id);
  wl_surface_commit(surface);

  // Poll both fds, not a blocking fgets: the initial xdg_surface.configure
  // (and thus mapping) must be processed even before the driver sends its
  // first stdin command, or the two sides deadlock waiting on each other.
  struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
  for (;;) {
    if (wl_display_dispatch_pending(display) < 0 || wl_display_flush(display) < 0) break;
    assert(poll(fds, 2, -1) >= 0);
    if (fds[0].revents && wl_display_dispatch(display) < 0) break;
    if (fds[1].revents) {
      char line[128];
      if (!fgets(line, sizeof(line), stdin)) break;
      if (!strncmp(line, "capture_dmabuf", 14)) {
        begin_capture_dmabuf();
      } else if (!strncmp(line, "window_capture", 14)) {
        begin_window_capture();
      } else if (!strncmp(line, "resize", 6)) {
        unsigned w, h;
        assert(sscanf(line, "resize %u %u", &w, &h) == 2);
        resize_surface(w, h);
      } else if (!strncmp(line, "capture", 7)) {
        begin_capture();
      } else if (!strncmp(line, "sample", 6)) {
        unsigned x, y;
        assert(sscanf(line, "sample %u %u", &x, &y) == 2);
        assert(x < buf_width && y < buf_height);
        uint8_t *p = (uint8_t *)pixels + y * active_stride + x * 4;
        printf("pixel %u %u %u %u %u %u\n", x, y, p[0], p[1], p[2], p[3]);
      } else if (!strncmp(line, "quit", 4)) {
        break;
      }
    }
  }
  return 0;
}
