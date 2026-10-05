// wlroots owns protocol resources; this bridge owns compositor policy/listeners.
#define _POSIX_C_SOURCE 200809L
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "extra_protocols.h"
#include <stdlib.h>
#include <string.h>
#include <wlr/backend/drm.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/util/log.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_color_representation_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_content_type_v1.h>
#include <wlr/types/wlr_drm_lease_v1.h>
#include <wlr/types/wlr_ext_workspace_v1.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_tearing_control_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_toplevel_tag_v1.h>

struct rediwm_protocols {
  struct wlr_content_type_manager_v1 *content;
  struct wlr_tearing_control_manager_v1 *tearing;
  struct wlr_drm_lease_v1_manager *lease;
  struct wlr_ext_workspace_group_handle_v1 *group;
  struct wl_listener tag, description, lease_request, layout_add;
  struct wl_list outputs;
  struct wlr_scene *scene; // set once the scene follows the color manager
  void *data;
  bool (*blocked)(void *);
  void (*changed)(void *, struct wlr_surface *);
};
struct metadata { struct wlr_addon addon; struct wl_listener top_destroy; char *tag, *description; };
static void metadata_destroy(struct wlr_addon *addon) {
  struct metadata *m = wl_container_of(addon, m, addon);
  wl_list_remove(&m->top_destroy.link);
  wlr_addon_finish(addon);
  free(m->tag); free(m->description); free(m);
}
static void metadata_top_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct metadata *m = wl_container_of(listener, m, top_destroy);
  metadata_destroy(&m->addon);
}
static const struct wlr_addon_interface metadata_impl = {"rediwm-toplevel-tag", metadata_destroy};
static struct metadata *metadata_get(struct wlr_surface *surface, bool create) {
  struct wlr_addon *addon = wlr_addon_find(&surface->addons, NULL, &metadata_impl);
  if (addon) { struct metadata *m = wl_container_of(addon, m, addon); return m; }
  if (!create) return NULL;
  struct metadata *m = calloc(1, sizeof(*m));
  if (m) {
    wl_list_init(&m->top_destroy.link);
    m->top_destroy.notify = metadata_top_destroy;
    wlr_addon_init(&m->addon, &surface->addons, NULL, &metadata_impl);
  }
  return m;
}
const char *rediwm_surface_tag(struct wlr_surface *surface, bool description) {
  struct metadata *m = surface ? metadata_get(surface, false) : NULL;
  return m ? (description ? m->description : m->tag) : NULL;
}
static void set_metadata(struct rediwm_protocols *p, struct wlr_xdg_toplevel *top, const char *value, bool description) {
  struct metadata *m = metadata_get(top->base->surface, true);
  char *copy = strdup(value);
  if (!m || !copy) { free(copy); wl_resource_post_no_memory(top->resource); return; }
  if (wl_list_empty(&m->top_destroy.link)) wl_signal_add(&top->events.destroy, &m->top_destroy);
  char **slot = description ? &m->description : &m->tag;
  if (*slot && strcmp(*slot, value) == 0) { free(copy); return; }
  free(*slot); *slot = copy;
  p->changed(p->data, top->base->surface);
}
static void on_tag(struct wl_listener *listener, void *data) {
  struct rediwm_protocols *p = wl_container_of(listener, p, tag);
  struct wlr_xdg_toplevel_tag_manager_v1_set_tag_event *ev = data;
  set_metadata(p, ev->toplevel, ev->tag, false);
}
static void on_description(struct wl_listener *listener, void *data) {
  struct rediwm_protocols *p = wl_container_of(listener, p, description);
  struct wlr_xdg_toplevel_tag_manager_v1_set_description_event *ev = data;
  set_metadata(p, ev->toplevel, ev->description, true);
}
struct workspace_output {
  struct wl_list link;
  struct wl_listener destroy;
  struct rediwm_protocols *protocols;
  struct wlr_output *output;
};
static void output_removed(struct wl_listener *listener, void *data) {
  (void)data;
  struct workspace_output *o = wl_container_of(listener, o, destroy);
  wlr_ext_workspace_group_handle_v1_output_leave(o->protocols->group, o->output);
  wl_list_remove(&o->destroy.link); wl_list_remove(&o->link); free(o);
}
static void output_added(struct wl_listener *listener, void *data) {
  struct rediwm_protocols *p = wl_container_of(listener, p, layout_add);
  struct wlr_output_layout_output *lo = data;
  struct workspace_output *o = calloc(1, sizeof(*o));
  if (!o) return;
  o->protocols = p; o->output = lo->output;
  o->destroy.notify = output_removed;
  wl_signal_add(&lo->events.destroy, &o->destroy);
  wl_list_insert(&p->outputs, &o->link);
  wlr_ext_workspace_group_handle_v1_output_enter(p->group, lo->output);
}
static void lease_requested(struct wl_listener *listener, void *data) {
  struct rediwm_protocols *p = wl_container_of(listener, p, lease_request);
  struct wlr_drm_lease_request_v1 *request = data;
  if (request->invalid || request->n_connectors == 0 || p->blocked(p->data)) { wlr_drm_lease_request_v1_reject(request); return; }
  for (size_t i = 0; i < request->n_connectors; i++) {
    struct wlr_output *output = request->connectors[i] ? request->connectors[i]->output : NULL;
    if (!output || !output->non_desktop || !wlr_output_is_drm(output)) {
      wlr_drm_lease_request_v1_reject(request); return;
    }
  }
  wlr_drm_lease_request_v1_grant(request);
}
void rediwm_protocols_offer(struct rediwm_protocols *p, struct wlr_output *output) {
  if (p && p->lease && output->non_desktop && wlr_output_is_drm(output))
    wlr_drm_lease_v1_manager_offer_output(p->lease, output);
}
void rediwm_protocols_revoke(struct rediwm_protocols *p) {
  if (!p || !p->lease) return;
  struct wlr_drm_lease_device_v1 *device;
  wl_list_for_each(device, &p->lease->devices, link) {
    struct wlr_drm_lease_v1 *lease, *tmp;
    wl_list_for_each_safe(lease, tmp, &device->leases, link) wlr_drm_lease_v1_revoke(lease);
  }
}
bool rediwm_protocols_tearing(struct rediwm_protocols *p, struct wlr_surface *surface) {
  return p && surface && wlr_tearing_control_manager_v1_surface_hint_from_surface(p->tearing, surface) == WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC;
}
const char *rediwm_protocols_content(struct rediwm_protocols *p, struct wlr_surface *surface) {
  if (!p || !surface) return NULL;
  switch (wlr_surface_get_content_type_v1(p->content, surface)) {
    case WP_CONTENT_TYPE_V1_TYPE_PHOTO: return "photo";
    case WP_CONTENT_TYPE_V1_TYPE_VIDEO: return "video";
    case WP_CONTENT_TYPE_V1_TYPE_GAME: return "game";
    default: return NULL;
  }
}
bool rediwm_surface_edge_is_srgb(struct wlr_surface *surface) {
  const struct wlr_image_description_v1_data *d = wlr_surface_get_image_description_v1_data(surface);
  const struct wlr_color_representation_v1_surface_state *r = wlr_color_representation_v1_get_surface_state(surface);
  return (!d || ((!d->tf_named || d->tf_named == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_SRGB) &&
    (!d->primaries_named || d->primaries_named == WP_COLOR_MANAGER_V1_PRIMARIES_SRGB))) &&
    (!r || (!r->coefficients && r->alpha_mode == WP_COLOR_REPRESENTATION_SURFACE_V1_ALPHA_MODE_PREMULTIPLIED_ELECTRICAL));
}
void rediwm_protocols_destroy(struct rediwm_protocols *p) {
  if (!p) return;
  struct workspace_output *o, *tmp;
  wl_list_for_each_safe(o, tmp, &p->outputs, link) output_removed(&o->destroy, NULL);
  wl_list_remove(&p->tag.link); wl_list_remove(&p->description.link);
  wl_list_remove(&p->lease_request.link); wl_list_remove(&p->layout_add.link);
  // wlroots 0.20's scene teardown leaves its color manager listener linked, and
  // the scene goes before the display: the manager's display-destroy signal
  // would then walk freed memory. Unlink it while both are alive.
  if (p->scene && p->scene->color_manager_v1) {
    wl_list_remove(&p->scene->private.color_manager_v1_destroy.link);
    wl_list_init(&p->scene->private.color_manager_v1_destroy.link);
    p->scene->color_manager_v1 = NULL;
  }
  free(p);
}
struct rediwm_protocols *rediwm_protocols_create(struct wl_display *display,
    struct wlr_backend *backend, struct wlr_renderer *renderer, struct wlr_scene *scene,
    struct wlr_output_layout *layout, void *data, bool (*blocked)(void *),
    void (*changed)(void *, struct wlr_surface *)) {
  struct rediwm_protocols *p = calloc(1, sizeof(*p));
  if (!p) return NULL;
  p->data = data; p->blocked = blocked; p->changed = changed;
  wl_list_init(&p->outputs); wl_list_init(&p->tag.link); wl_list_init(&p->description.link);
  wl_list_init(&p->lease_request.link); wl_list_init(&p->layout_add.link);
  p->content = wlr_content_type_manager_v1_create(display, 1);
  p->tearing = wlr_tearing_control_manager_v1_create(display, 1);
  struct wlr_xdg_toplevel_tag_manager_v1 *tags = wlr_xdg_toplevel_tag_manager_v1_create(display, 1);
  if (!p->content || !p->tearing || !tags) goto fail;
  p->tag.notify = on_tag; wl_signal_add(&tags->events.set_tag, &p->tag);
  p->description.notify = on_description; wl_signal_add(&tags->events.set_description, &p->description);
  if (!wlr_color_representation_manager_v1_create_with_renderer(display, 1, renderer)) goto fail;
  struct wlr_color_manager_v1_options options = {0};
  options.features.parametric = renderer->features.input_color_transform;
  const enum wp_color_manager_v1_render_intent intent = WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL;
  options.render_intents = &intent; options.render_intents_len = 1;
  // A renderer without input transforms returns empty capability lists.
  // It still exposes output/surface feedback, but no parametric creator.
  options.transfer_functions = wlr_color_manager_v1_transfer_function_list_from_renderer(renderer, &options.transfer_functions_len);
  options.primaries = wlr_color_manager_v1_primaries_list_from_renderer(renderer, &options.primaries_len);
  struct wlr_color_manager_v1 *color = wlr_color_manager_v1_create(display, 2, &options);
  free((void *)options.transfer_functions); free((void *)options.primaries);
  if (!color) goto fail;
  wlr_scene_set_color_manager_v1(scene, color);
  p->scene = scene;
  struct wlr_ext_workspace_manager_v1 *workspaces = wlr_ext_workspace_manager_v1_create(display, 1);
  if (!workspaces) goto fail;
  p->group = wlr_ext_workspace_group_handle_v1_create(workspaces, 0);
  struct wlr_ext_workspace_handle_v1 *canvas = wlr_ext_workspace_handle_v1_create(workspaces, "rediwm-canvas", 0);
  if (!p->group || !canvas) goto fail;
  wlr_ext_workspace_handle_v1_set_group(canvas, p->group);
  wlr_ext_workspace_handle_v1_set_name(canvas, "Canvas");
  wlr_ext_workspace_handle_v1_set_active(canvas, true);
  p->layout_add.notify = output_added; wl_signal_add(&layout->events.add, &p->layout_add);
  struct wlr_output_layout_output *lo;
  wl_list_for_each(lo, &layout->outputs, link) output_added(&p->layout_add, lo);
  p->lease = wlr_drm_lease_v1_manager_create(display, backend);
  if (p->lease) { p->lease_request.notify = lease_requested; wl_signal_add(&p->lease->events.request, &p->lease_request); }
  return p;
fail:
  wlr_log(WLR_ERROR, "Could not initialize supplementary Wayland protocols");
  rediwm_protocols_destroy(p);
  return NULL;
}
