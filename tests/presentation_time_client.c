// Isolated wp_presentation fixture. No host-session access.
#define _GNU_SOURCE
#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include <assert.h>
#include <stdbool.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

struct output {
  struct wl_output *proxy;
  char name[64];
};

struct feedback {
  char label[32];
  char output[64];
  bool tracked;
};

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wl_surface *surface;
static struct xdg_surface *xdg_surface;
static struct xdg_toplevel *toplevel;
static struct output outputs[16];
static unsigned output_count;
static unsigned requested_version;
static uint32_t presentation_clock;
static bool clock_received, configured;
static unsigned pending, color_seq;

static void buffer_release(void *data, struct wl_buffer *buffer) {
  (void)data;
  wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {buffer_release};

static void paint(void) {
  const int width = 320, height = 200, stride = width * 4;
  const size_t size = (size_t)stride * height;
  int fd = memfd_create("presentation-fixture", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
  uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  uint32_t color = 0xff204060u + ((++color_seq & 0x1f) << 16);
  for (size_t i = 0; i < size / 4; i++) pixels[i] = color;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(
      pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
  wl_buffer_add_listener(buffer, &buffer_listener, NULL);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage_buffer(surface, 0, 0, width, height);
  wl_shm_pool_destroy(pool);
  munmap(pixels, size);
  close(fd);
}

static struct output *find_output(struct wl_output *proxy) {
  for (unsigned i = 0; i < output_count; i++)
    if (outputs[i].proxy == proxy) return &outputs[i];
  return NULL;
}

static void feedback_sync_output(void *data,
    struct wp_presentation_feedback *proxy, struct wl_output *output) {
  (void)proxy;
  struct feedback *feedback = data;
  struct output *found = find_output(output);
  assert(found && found->name[0]);
  snprintf(feedback->output, sizeof(feedback->output), "%s", found->name);
}

static void feedback_presented(void *data,
    struct wp_presentation_feedback *proxy, uint32_t sec_hi, uint32_t sec_lo,
    uint32_t nsec, uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo,
    uint32_t flags) {
  struct feedback *feedback = data;
  uint64_t sec = ((uint64_t)sec_hi << 32) | sec_lo;
  uint64_t seq = ((uint64_t)seq_hi << 32) | seq_lo;
  assert(clock_received && nsec < 1000000000u && feedback->output[0]);
  assert((flags & ~0xfu) == 0);
  struct timespec now;
  assert(clock_gettime((clockid_t)presentation_clock, &now) == 0);
  int64_t age = ((int64_t)now.tv_sec - (int64_t)sec) * INT64_C(1000000000)
      + now.tv_nsec - nsec;
  assert(age >= -INT64_C(100000000) && age < INT64_C(30000000000));
  printf("presented %s %" PRIu64 " %u %u %" PRIu64 " %u %s\n",
      feedback->label, sec, nsec, refresh, seq, flags, feedback->output);
  bool tracked = feedback->tracked;
  wp_presentation_feedback_destroy(proxy);
  free(feedback);
  if (tracked) {
    assert(pending > 0);
    pending--;
  }
}

static void feedback_discarded(void *data,
    struct wp_presentation_feedback *proxy) {
  struct feedback *feedback = data;
  printf("discarded %s\n", feedback->label);
  bool tracked = feedback->tracked;
  wp_presentation_feedback_destroy(proxy);
  free(feedback);
  if (tracked) {
    assert(pending > 0);
    pending--;
  }
}

static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = feedback_sync_output,
    .presented = feedback_presented,
    .discarded = feedback_discarded,
};

static void request_feedback_for(struct wl_surface *target, const char *label,
                                 bool tracked) {
  assert(presentation);
  struct feedback *feedback = calloc(1, sizeof(*feedback));
  assert(feedback);
  snprintf(feedback->label, sizeof(feedback->label), "%s", label);
  feedback->tracked = tracked;
  struct wp_presentation_feedback *proxy =
      wp_presentation_feedback(presentation, target);
  assert(proxy);
  wp_presentation_feedback_add_listener(proxy, &feedback_listener, feedback);
  if (tracked) pending++;
}

static void await_feedback(void) {
  assert(wl_display_flush(display) >= 0);
  while (pending > 0) assert(wl_display_dispatch(display) >= 0);
}

static void commit_feedback(const char *label) {
  request_feedback_for(surface, label, true);
  paint();
  wl_surface_commit(surface);
  await_feedback();
}

static void presentation_clock_id(void *data,
    struct wp_presentation *proxy, uint32_t clock_id) {
  (void)data; (void)proxy;
  struct timespec now;
  assert(clock_gettime((clockid_t)clock_id, &now) == 0);
  presentation_clock = clock_id;
  clock_received = true;
}
static const struct wp_presentation_listener presentation_listener = {
    .clock_id = presentation_clock_id,
};

static void output_geometry(void *data, struct wl_output *output, int32_t x,
    int32_t y, int32_t pw, int32_t ph, int32_t subpixel, const char *make,
    const char *model, int32_t transform) {
  (void)data; (void)output; (void)x; (void)y; (void)pw; (void)ph;
  (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *output, uint32_t flags,
    int32_t width, int32_t height, int32_t refresh) {
  (void)data; (void)output; (void)flags; (void)width; (void)height; (void)refresh;
}
static void output_done(void *data, struct wl_output *output) {
  (void)data; (void)output;
}
static void output_scale(void *data, struct wl_output *output, int32_t factor) {
  (void)data; (void)output; (void)factor;
}
static void output_name(void *data, struct wl_output *output, const char *name) {
  (void)output;
  snprintf(((struct output *)data)->name, sizeof(outputs[0].name), "%s", name);
}
static void output_description(void *data, struct wl_output *output,
                               const char *description) {
  (void)data; (void)output; (void)description;
}
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done,
    .scale = output_scale, .name = output_name,
    .description = output_description,
};

static void registry_global(void *data, struct wl_registry *registry,
    uint32_t id, const char *interface, uint32_t version) {
  (void)data;
  if (!strcmp(interface, wl_compositor_interface.name)) {
    compositor = wl_registry_bind(registry, id, &wl_compositor_interface, 4);
  } else if (!strcmp(interface, wl_shm_interface.name)) {
    shm = wl_registry_bind(registry, id, &wl_shm_interface, 1);
  } else if (!strcmp(interface, xdg_wm_base_interface.name)) {
    wm = wl_registry_bind(registry, id, &xdg_wm_base_interface, 2);
  } else if (!strcmp(interface, wp_presentation_interface.name)) {
    assert(version == 2 && requested_version <= version);
    presentation = wl_registry_bind(registry, id, &wp_presentation_interface,
                                    requested_version);
    wp_presentation_add_listener(presentation, &presentation_listener, NULL);
  } else if (!strcmp(interface, wl_output_interface.name)) {
    assert(version >= 4 && output_count < 16);
    struct output *output = &outputs[output_count++];
    output->proxy = wl_registry_bind(registry, id, &wl_output_interface, 4);
    wl_output_add_listener(output->proxy, &output_listener, output);
  }
}
static void registry_removed(void *data, struct wl_registry *registry,
                             uint32_t id) {
  (void)data; (void)registry; (void)id;
}
static const struct wl_registry_listener registry_listener = {
    registry_global, registry_removed,
};

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {wm_ping};

static void surface_configure(void *data, struct xdg_surface *proxy,
                              uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(proxy, serial);
  configured = true;
}
static const struct xdg_surface_listener xdg_surface_listener = {
    surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *proxy,
    int32_t width, int32_t height, struct wl_array *states) {
  (void)data; (void)proxy; (void)width; (void)height; (void)states;
}
static void toplevel_close(void *data, struct xdg_toplevel *proxy) {
  (void)data; (void)proxy;
  exit(0);
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure, .close = toplevel_close,
};

static void run_command(const char *command) {
  if (!strcmp(command, "present")) {
    commit_feedback("single");
  } else if (!strcmp(command, "same")) {
    request_feedback_for(surface, "same-a", true);
    request_feedback_for(surface, "same-b", true);
    paint();
    wl_surface_commit(surface);
    await_feedback();
  } else if (!strcmp(command, "supersede")) {
    request_feedback_for(surface, "stale", true);
    paint();
    wl_surface_commit(surface);
    request_feedback_for(surface, "fresh", true);
    paint();
    wl_surface_commit(surface);
    await_feedback();
  } else if (!strcmp(command, "manager")) {
    // The feedback object is independent of the manager proxy. Also leave an
    // uncommitted feedback and its surface alive for display teardown.
    request_feedback_for(surface, "manager", true);
    struct wl_surface *orphan = wl_compositor_create_surface(compositor);
    request_feedback_for(orphan, "orphan", false);
    wp_presentation_destroy(presentation);
    presentation = NULL;
    paint();
    wl_surface_commit(surface);
    await_feedback();
  } else if (!strcmp(command, "live")) {
    puts("done");
    while (wl_display_dispatch(display) >= 0) {}
    exit(0);
  } else {
    assert(!"unknown command");
  }
  puts("done");
}

int main(int argc, char **argv) {
  assert(argc == 2);
  requested_version = (unsigned)atoi(argv[1]);
  assert(requested_version == 1 || requested_version == 2);
  setbuf(stdout, NULL);
  display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  assert(wl_display_roundtrip(display) >= 0);
  assert(wl_display_roundtrip(display) >= 0);
  assert(compositor && shm && wm && presentation && clock_received);
  assert(output_count > 0);
  for (unsigned i = 0; i < output_count; i++) assert(outputs[i].name[0]);
  printf("global 2 clock %u outputs %u\n", presentation_clock, output_count);

  xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  surface = wl_compositor_create_surface(compositor);
  xdg_surface = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, NULL);
  toplevel = xdg_surface_get_toplevel(xdg_surface);
  xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
  xdg_toplevel_set_app_id(toplevel, "rediwm.presentation-fixture");
  xdg_toplevel_set_title(toplevel, "Presentation timing fixture");
  wl_surface_commit(surface);
  while (!configured) assert(wl_display_dispatch(display) >= 0);
  commit_feedback("initial");
  puts("ready");

  char command[64];
  while (fgets(command, sizeof(command), stdin)) {
    command[strcspn(command, "\r\n")] = '\0';
    run_command(command);
  }
  return 0;
}
