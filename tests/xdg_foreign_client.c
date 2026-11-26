// Included by wlr_protocols_client.c. Each process owns one xdg toplevel.
#include "xdg-foreign-unstable-v1-client-protocol.h"
#include "xdg-foreign-unstable-v2-client-protocol.h"

static struct zxdg_exporter_v1 *exporter_v1;
static struct zxdg_importer_v1 *importer_v1;
static struct zxdg_exporter_v2 *exporter_v2;
static struct zxdg_importer_v2 *importer_v2;

static bool bind_xdg_foreign(struct wl_registry *r, uint32_t name, const char *iface) {
  if (foreign_version == 1 && !strcmp(iface, "zxdg_exporter_v1"))
    exporter_v1 = wl_registry_bind(r, name, &zxdg_exporter_v1_interface, 1);
  else if (foreign_version == 1 && !strcmp(iface, "zxdg_importer_v1"))
    importer_v1 = wl_registry_bind(r, name, &zxdg_importer_v1_interface, 1);
  else if (foreign_version == 2 && !strcmp(iface, "zxdg_exporter_v2"))
    exporter_v2 = wl_registry_bind(r, name, &zxdg_exporter_v2_interface, 1);
  else if (foreign_version == 2 && !strcmp(iface, "zxdg_importer_v2"))
    importer_v2 = wl_registry_bind(r, name, &zxdg_importer_v2_interface, 1);
  else return false;
  return true;
}

static void handle_v1(void *data, struct zxdg_exported_v1 *object, const char *handle) {
  (void)data; (void)object; puts(handle);
}
static void handle_v2(void *data, struct zxdg_exported_v2 *object, const char *handle) {
  (void)data; (void)object; puts(handle);
}
static void revoked_v1(void *data, struct zxdg_imported_v1 *object) {
  (void)object; *(bool *)data = true;
}
static void revoked_v2(void *data, struct zxdg_imported_v2 *object) {
  (void)object; *(bool *)data = true;
}

static void export_parent(struct wl_surface *surface) {
  static const struct zxdg_exported_v1_listener listener_v1 = {.handle = handle_v1};
  static const struct zxdg_exported_v2_listener listener_v2 = {.handle = handle_v2};
  struct zxdg_exported_v1 *v1 = NULL;
  struct zxdg_exported_v2 *v2 = NULL;
  if (foreign_version == 1) {
    v1 = zxdg_exporter_v1_export(exporter_v1, surface);
    zxdg_exported_v1_add_listener(v1, &listener_v1, NULL);
  } else {
    v2 = zxdg_exporter_v2_export_toplevel(exporter_v2, surface);
    zxdg_exported_v2_add_listener(v2, &listener_v2, NULL);
  }
  assert(wl_display_roundtrip(display) >= 0);
  assert(getchar() == '\n'); // Revoke the handle while the parent is still mapped.
  if (v1) zxdg_exported_v1_destroy(v1);
  if (v2) zxdg_exported_v2_destroy(v2);
  assert(wl_display_roundtrip(display) >= 0);
}

static void import_parent(struct wl_surface *surface, const char *handle) {
  static const struct zxdg_imported_v1_listener listener_v1 = {.destroyed = revoked_v1};
  static const struct zxdg_imported_v2_listener listener_v2 = {.destroyed = revoked_v2};
  bool revoked = false;
  struct zxdg_imported_v1 *v1 = NULL;
  struct zxdg_imported_v2 *v2 = NULL;
  if (foreign_version == 1) {
    v1 = zxdg_importer_v1_import(importer_v1, handle);
    zxdg_imported_v1_add_listener(v1, &listener_v1, &revoked);
    zxdg_imported_v1_set_parent_of(v1, surface);
  } else {
    v2 = zxdg_importer_v2_import_toplevel(importer_v2, handle);
    zxdg_imported_v2_add_listener(v2, &listener_v2, &revoked);
    zxdg_imported_v2_set_parent_of(v2, surface);
  }
  assert(wl_display_roundtrip(display) >= 0);
  if (!revoked) {
    puts("parented");
    dispatch_until(&revoked);
  }
  puts("revoked");
  if (v1) zxdg_imported_v1_destroy(v1);
  if (v2) zxdg_imported_v2_destroy(v2);
}

static int run_xdg_foreign(const char *handle) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  assert(foreign_version == 1 ? (exporter_v1 && importer_v1) : (exporter_v2 && importer_v2));
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(xdg, surface);
  xdg_surface_add_listener(xs, &surface_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
  xdg_toplevel_add_listener(top, &top_listener, NULL);
  xdg_toplevel_set_app_id(top, handle ? "rediwm.foreign-child" : "rediwm.foreign-parent");
  wl_surface_commit(surface);
  dispatch_until(&configured);
  struct wl_buffer *buffer = create_buffer(WL_SHM_FORMAT_ARGB8888, 120, 80, 480, 0xff334455, NULL);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_commit(surface);
  if (handle) import_parent(surface, handle);
  else export_parent(surface);
  assert(getchar() == '\n'); // Keep both windows mapped for the workspace assertions.
  xdg_toplevel_destroy(top);
  xdg_surface_destroy(xs);
  wl_surface_destroy(surface);
  wl_buffer_destroy(buffer);
  assert(wl_display_roundtrip(display) >= 0);
  wl_display_disconnect(display);
  return 0;
}
