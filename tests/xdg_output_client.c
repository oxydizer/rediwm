// Read output metadata from the real Wayland wire; no surfaces or host access.
#include "xdg-output-client-protocol.h"
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct output {
  struct wl_output *wl;
  struct zxdg_output_v1 *xdg;
  char core_name[128], name[128], description[256];
  int x, y, width, height, mode_width, mode_height, scale;
  unsigned positions, sizes, names, descriptions, core_done, xdg_done;
  bool pending;
};
static struct output outputs[16];
static unsigned output_count;
static unsigned version, core_version;
static struct zxdg_output_manager_v1 *manager;

static void geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
                     int32_t pw, int32_t ph, int32_t subpixel, const char *make,
                     const char *model, int32_t transform) {
  (void)data; (void)output; (void)x; (void)y; (void)pw; (void)ph;
  (void)subpixel; (void)make; (void)model; (void)transform;
}
static void mode(void *data, struct wl_output *output, uint32_t flags,
                 int32_t width, int32_t height, int32_t refresh) {
  (void)output; (void)refresh;
  struct output *o = data;
  if (flags & WL_OUTPUT_MODE_CURRENT) { o->mode_width = width; o->mode_height = height; }
}
static void core_done(void *data, struct wl_output *output) {
  (void)output;
  struct output *o = data;
  if (o->xdg) {
    o->core_done++;
    if (version >= 3) o->pending = false;
  }
}
static void scale(void *data, struct wl_output *output, int32_t factor) {
  (void)output;
  ((struct output *)data)->scale = factor;
}
static void core_name(void *data, struct wl_output *output, const char *name) {
  (void)output;
  snprintf(((struct output *)data)->core_name, 128, "%s", name);
}
static void core_description(void *data, struct wl_output *output, const char *description) {
  (void)data; (void)output; (void)description;
}
static const struct wl_output_listener output_listener = {
  .geometry = geometry, .mode = mode, .done = core_done, .scale = scale,
  .name = core_name, .description = core_description,
};
static void position(void *data, struct zxdg_output_v1 *xdg, int32_t x, int32_t y) {
  (void)xdg;
  struct output *o = data;
  o->x = x; o->y = y; o->positions++; o->pending = true;
}
static void size(void *data, struct zxdg_output_v1 *xdg, int32_t width, int32_t height) {
  (void)xdg;
  struct output *o = data;
  o->width = width; o->height = height; o->sizes++; o->pending = true;
}
static void done(void *data, struct zxdg_output_v1 *xdg) {
  (void)xdg;
  struct output *o = data;
  o->xdg_done++;
  if (version < 3) o->pending = false;
}
static void name(void *data, struct zxdg_output_v1 *xdg, const char *name) {
  (void)xdg;
  struct output *o = data;
  snprintf(o->name, sizeof(o->name), "%s", name);
  o->names++;
}
static void description(void *data, struct zxdg_output_v1 *xdg, const char *description) {
  (void)xdg;
  struct output *o = data;
  snprintf(o->description, sizeof(o->description), "%s", description);
  o->descriptions++;
}
static const struct zxdg_output_v1_listener xdg_listener = {
  .logical_position = position, .logical_size = size, .done = done,
  .name = name, .description = description,
};
static void global(void *data, struct wl_registry *registry, uint32_t id,
                   const char *interface, uint32_t advertised) {
  (void)data;
  if (!strcmp(interface, "zxdg_output_manager_v1")) {
    assert(advertised == 3);
    manager = wl_registry_bind(registry, id, &zxdg_output_manager_v1_interface, version);
  } else if (!strcmp(interface, "wl_output")) {
    assert(output_count < 16 && advertised >= core_version);
    struct output *o = &outputs[output_count++];
    o->wl = wl_registry_bind(registry, id, &wl_output_interface, core_version);
    wl_output_add_listener(o->wl, &output_listener, o);
  }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
  (void)data; (void)registry; (void)id;
}
static const struct wl_registry_listener registry_listener = {global, removed};

int main(int argc, char **argv) {
  assert(argc == 3 || argc == 4);
  version = (unsigned)atoi(argv[1]);
  core_version = (unsigned)atoi(argv[2]);
  assert(version >= 1 && version <= 3 && core_version >= 2 && core_version <= 4);
  setbuf(stdout, NULL);
  struct wl_display *display = wl_display_connect(NULL);
  assert(display);
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  assert(wl_display_roundtrip(display) >= 0);
  assert(manager && output_count > 0);
  // Finish the initial wl_output event batch before requesting xdg metadata.
  assert(wl_display_roundtrip(display) >= 0);
  for (unsigned i = 0; i < output_count; i++) {
    outputs[i].xdg = zxdg_output_manager_v1_get_xdg_output(manager, outputs[i].wl);
    zxdg_output_v1_add_listener(outputs[i].xdg, &xdg_listener, &outputs[i]);
  }
  // Requests queued before manager destruction still create independent objects.
  zxdg_output_manager_v1_destroy(manager);
  assert(wl_display_roundtrip(display) >= 0);
  for (unsigned i = 0; i < output_count; i++) {
    struct output *o = &outputs[i];
    assert(o->positions == 1 && o->sizes == 1 && !o->pending);
    if (version < 3) assert(o->xdg_done == 1);
    else assert(o->core_done >= 1 && o->xdg_done == 0);
    if (version == 1) assert(o->names == 0 && o->descriptions == 0);
    else {
      assert(o->names == 1 && o->descriptions == 1 && o->description[0]);
      if (core_version >= 4) assert(!strcmp(o->core_name, o->name));
    }
    // Names follow the protocol's alphanumeric/dash restriction; safe in JSON.
    printf("{\"name\":\"%s\",\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d,"
           "\"mode_width\":%d,\"mode_height\":%d,\"scale\":%d}\n",
           version >= 2 ? o->name : o->core_name, o->x, o->y, o->width, o->height,
           o->mode_width, o->mode_height, o->scale);
  }
  if (argc == 4) {
    // Keep resources alive until compositor shutdown, checking lifetime handling.
    puts("ready");
    while (wl_display_dispatch(display) >= 0) {}
  } else {
    for (unsigned i = 0; i < output_count; i++) {
      zxdg_output_v1_destroy(outputs[i].xdg);
      if (core_version >= 3) wl_output_release(outputs[i].wl);
      else wl_output_destroy(outputs[i].wl);
    }
    assert(wl_display_roundtrip(display) >= 0);
  }
  wl_display_disconnect(display);
  return 0;
}
