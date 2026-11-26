// wlroots owns protocol resources; this bridge owns compositor policy/listeners.
#define _POSIX_C_SOURCE 200809L
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "extra_protocols.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <wlr/backend/drm.h>
#include <wlr/render/gles2.h>
#include <wlr/util/log.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_color_representation_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_content_type_v1.h>
#include <wlr/types/wlr_drm_lease_v1.h>
#include <wlr/types/wlr_ext_workspace_v1.h>
#include <wlr/types/wlr_output_layout.h>
#include "scene_outputs.h"
#include "surface_feedback.h"
#include <wlr/types/wlr_tearing_control_v1.h>
#include <wlr/types/wlr_xdg_dialog_v1.h>
#include <wlr/types/wlr_xdg_foreign_registry.h>
#include <wlr/types/wlr_xdg_foreign_v1.h>
#include <wlr/types/wlr_xdg_foreign_v2.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_system_bell_v1.h>
#include <wlr/types/wlr_xdg_toplevel_tag_v1.h>

struct rediwm_protocols {
  struct rediwm_color_feedback feedback;
  struct wlr_content_type_manager_v1 *content;
  struct wlr_tearing_control_manager_v1 *tearing;
  struct wlr_drm_lease_v1_manager *lease;
  struct wlr_ext_workspace_group_handle_v1 *group;
  struct wlr_ext_workspace_manager_v1 *workspaces;
  struct wlr_ext_workspace_handle_v1 *canvas, *workspace[32];
  struct wl_listener workspace_commit;
  void (*activate_workspace)(void *, unsigned);
  bool workspace_mode;
  struct wl_listener tag, description, lease_request, layout_add;
  struct wl_listener system_bell;
  struct wl_listener new_dialog;
  struct wl_list dialogs; // struct dialog_watch.link
  struct wl_list outputs;
  struct rediwm_scene_outputs *scene; // set once the outputs follow the color manager
  void *data;
  bool (*blocked)(void *);
  void (*changed)(void *, struct wlr_surface *);
  void (*ring)(void *);
  void (*modal)(void *, struct wlr_surface *);
};
static void system_bell_ring(struct wl_listener *listener, void *data) {
  (void)data; // Audible feedback is the same with or without an associated surface.
  struct rediwm_protocols *p = wl_container_of(listener, p, system_bell);
  if (!p->blocked(p->data)) p->ring(p->data);
}
// wlroots keeps each dialog's modal flag (read it with rediwm_xdg_toplevel_modal);
// a watch only reports set_modal/unset_modal. A dialog object the client destroys
// first drops the hint without a report: losing modality needs no answer, and when
// the toplevel goes first our window is already gone. wlroots asserts that nothing
// still listens when it frees a dialog.
struct dialog_watch {
  struct wl_list link;
  struct wl_listener set_modal, destroy;
  struct wlr_xdg_dialog_v1 *dialog;
  struct rediwm_protocols *protocols;
};
static void dialog_watch_free(struct dialog_watch *w) {
  wl_list_remove(&w->set_modal.link); wl_list_remove(&w->destroy.link); wl_list_remove(&w->link);
  free(w);
}
static void dialog_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct dialog_watch *w = wl_container_of(listener, w, destroy);
  dialog_watch_free(w);
}
static void dialog_set_modal(struct wl_listener *listener, void *data) {
  (void)data;
  struct dialog_watch *w = wl_container_of(listener, w, set_modal);
  w->protocols->modal(w->protocols->data, w->dialog->xdg_toplevel->base->surface);
}
static void on_new_dialog(struct wl_listener *listener, void *data) {
  struct rediwm_protocols *p = wl_container_of(listener, p, new_dialog);
  struct wlr_xdg_dialog_v1 *dialog = data;
  struct dialog_watch *w = calloc(1, sizeof(*w));
  if (!w) { wl_resource_post_no_memory(dialog->resource); return; }
  w->dialog = dialog; w->protocols = p;
  w->set_modal.notify = dialog_set_modal; wl_signal_add(&dialog->events.set_modal, &w->set_modal);
  w->destroy.notify = dialog_destroyed; wl_signal_add(&dialog->events.destroy, &w->destroy);
  wl_list_insert(&p->dialogs, &w->link);
}
bool rediwm_xdg_toplevel_modal(struct wlr_xdg_toplevel *top) {
  struct wlr_xdg_dialog_v1 *dialog = top ? wlr_xdg_dialog_v1_try_from_wlr_xdg_toplevel(top) : NULL;
  return dialog && dialog->modal;
}
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
  struct wlr_ext_workspace_group_handle_v1 *group;
};
static void output_removed(struct wl_listener *listener, void *data) {
  (void)data;
  struct workspace_output *o = wl_container_of(listener, o, destroy);
  if (o->group) wlr_ext_workspace_group_handle_v1_destroy(o->group);
  if (o->protocols->group) wlr_ext_workspace_group_handle_v1_output_leave(o->protocols->group, o->output);
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
  if (!p->workspace_mode && p->group) wlr_ext_workspace_group_handle_v1_output_enter(p->group, lo->output);
}
static void workspace_commit(struct wl_listener *listener, void *data) {
  struct rediwm_protocols *p = wl_container_of(listener, p, workspace_commit);
  if (p->blocked(p->data) || !p->activate_workspace) return;
  struct wlr_ext_workspace_v1_commit_event *event = data;
  struct wlr_ext_workspace_v1_request *request;
  wl_list_for_each(request, event->requests, link) {
    if (request->type != WLR_EXT_WORKSPACE_V1_REQUEST_ACTIVATE || !request->activate.workspace) continue;
    for (unsigned i = 0; i < 32; i++) if (request->activate.workspace == p->workspace[i]) {
      p->activate_workspace(p->data, i + 1);
      break;
    }
  }
}
void rediwm_workspace_mode(struct rediwm_protocols *p, bool enabled, void (*activate)(void *, unsigned)) {
  if (!p) return;
  p->activate_workspace = activate;
  if (p->workspace_mode == enabled) return;
  p->workspace_mode = enabled;
  struct workspace_output *o;
  if (enabled) {
    if (p->canvas) wlr_ext_workspace_handle_v1_destroy(p->canvas);
    p->canvas = NULL;
    if (p->group) wlr_ext_workspace_group_handle_v1_destroy(p->group);
    p->group = NULL;
  } else {
    p->group = wlr_ext_workspace_group_handle_v1_create(p->workspaces, 0);
    for (unsigned i = 0; i < 32; i++) {
      if (p->workspace[i]) wlr_ext_workspace_handle_v1_destroy(p->workspace[i]);
      p->workspace[i] = NULL;
    }
    wl_list_for_each(o, &p->outputs, link) {
      if (o->group) wlr_ext_workspace_group_handle_v1_destroy(o->group);
      o->group = NULL;
      if (p->group) wlr_ext_workspace_group_handle_v1_output_enter(p->group, o->output);
    }
    p->canvas = wlr_ext_workspace_handle_v1_create(p->workspaces, "rediwm-canvas", 0);
    if (p->canvas) {
      wlr_ext_workspace_handle_v1_set_group(p->canvas, p->group);
      wlr_ext_workspace_handle_v1_set_name(p->canvas, "Canvas");
      wlr_ext_workspace_handle_v1_set_active(p->canvas, true);
    }
  }
}
void rediwm_workspace_update(struct rediwm_protocols *p, unsigned id, const char *name, struct wlr_output *output, bool active) {
  if (!p || id == 0 || id > 32 || !p->workspace_mode) return;
  struct wlr_ext_workspace_handle_v1 **slot = &p->workspace[id - 1];
  if (!*slot) {
    char identifier[40];
    snprintf(identifier, sizeof(identifier), "rediwm-workspace-%u", id);
    *slot = wlr_ext_workspace_handle_v1_create(p->workspaces, identifier, EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE);
    if (!*slot) return;
    wlr_ext_workspace_handle_v1_set_name(*slot, name);
  }
  struct wlr_ext_workspace_group_handle_v1 *group = NULL;
  struct workspace_output *o;
  wl_list_for_each(o, &p->outputs, link) if (o->output == output) {
    if (!o->group) {
      o->group = wlr_ext_workspace_group_handle_v1_create(p->workspaces, 0);
      if (o->group) wlr_ext_workspace_group_handle_v1_output_enter(o->group, output);
    }
    group = o->group;
    break;
  }
  wlr_ext_workspace_handle_v1_set_group(*slot, group);
  wlr_ext_workspace_handle_v1_set_active(*slot, active);
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
  wl_list_remove(&p->system_bell.link);
  wl_list_remove(&p->new_dialog.link);
  struct dialog_watch *w, *wtmp;
  wl_list_for_each_safe(w, wtmp, &p->dialogs, link) dialog_watch_free(w);
  wl_list_remove(&p->lease_request.link); wl_list_remove(&p->layout_add.link);
  // The outputs go before the display: detach the colour manager they follow.
  if (p->scene) {
    rediwm_color_feedback_finish(&p->feedback);
    p->scene->feedback = NULL;
    rediwm_scene_outputs_set_color_manager(p->scene, NULL);
  }
  wl_list_remove(&p->workspace_commit.link);
  free(p);
}
struct rediwm_protocols *rediwm_protocols_create(struct wl_display *display,
    struct wlr_backend *backend, struct wlr_renderer *renderer, struct rediwm_scene_outputs *scene,
    struct wlr_output_layout *layout, void *data, bool (*blocked)(void *),
    void (*changed)(void *, struct wlr_surface *), void (*ring)(void *),
    void (*modal)(void *, struct wlr_surface *)) {
  struct rediwm_protocols *p = calloc(1, sizeof(*p));
  if (!p) return NULL;
  p->data = data; p->blocked = blocked; p->changed = changed; p->ring = ring; p->modal = modal;
  wl_list_init(&p->system_bell.link);
  wl_list_init(&p->new_dialog.link); wl_list_init(&p->dialogs);
  wl_list_init(&p->workspace_commit.link);
  wl_list_init(&p->outputs); wl_list_init(&p->tag.link); wl_list_init(&p->description.link);
  wl_list_init(&p->lease_request.link); wl_list_init(&p->layout_add.link);
  if (!wlr_alpha_modifier_v1_create(display)) goto fail;
  // The display owns the registry. A handle exported by either version works with both importers.
  struct wlr_xdg_foreign_registry *foreign = wlr_xdg_foreign_registry_create(display);
  if (!foreign || !wlr_xdg_foreign_v1_create(display, foreign) ||
      !wlr_xdg_foreign_v2_create(display, foreign)) goto fail;
  p->content = wlr_content_type_manager_v1_create(display, 1);
  p->tearing = wlr_tearing_control_manager_v1_create(display, 1);
  struct wlr_xdg_toplevel_tag_manager_v1 *tags = wlr_xdg_toplevel_tag_manager_v1_create(display, 1);
  struct wlr_xdg_system_bell_v1 *bell = wlr_xdg_system_bell_v1_create(display, 1);
  struct wlr_xdg_wm_dialog_v1 *dialogs = wlr_xdg_wm_dialog_v1_create(display, 1);
  if (!p->content || !p->tearing || !tags || !bell || !dialogs) goto fail;
  p->new_dialog.notify = on_new_dialog;
  wl_signal_add(&dialogs->events.new_dialog, &p->new_dialog);
  p->system_bell.notify = system_bell_ring;
  wl_signal_add(&bell->events.ring, &p->system_bell);
  p->tag.notify = on_tag; wl_signal_add(&tags->events.set_tag, &p->tag);
  p->description.notify = on_description; wl_signal_add(&tags->events.set_description, &p->description);
  const enum wp_color_representation_surface_v1_alpha_mode alpha =
      WP_COLOR_REPRESENTATION_SURFACE_V1_ALPHA_MODE_PREMULTIPLIED_ELECTRICAL;
  const struct wlr_color_representation_v1_coeffs_and_range pairs[] = {
      { WP_COLOR_REPRESENTATION_SURFACE_V1_COEFFICIENTS_IDENTITY, WP_COLOR_REPRESENTATION_SURFACE_V1_RANGE_FULL },
#define YUV_RANGES(c) { WP_COLOR_REPRESENTATION_SURFACE_V1_COEFFICIENTS_##c, WP_COLOR_REPRESENTATION_SURFACE_V1_RANGE_FULL }, \
                      { WP_COLOR_REPRESENTATION_SURFACE_V1_COEFFICIENTS_##c, WP_COLOR_REPRESENTATION_SURFACE_V1_RANGE_LIMITED }
      YUV_RANGES(BT601), YUV_RANGES(BT709), YUV_RANGES(BT2020),
#undef YUV_RANGES
  };
  const struct wlr_color_representation_v1_options representation = {
      .supported_alpha_modes = &alpha, .supported_alpha_modes_len = 1,
      .supported_coeffs_and_ranges = pairs,
      .supported_coeffs_and_ranges_len = wlr_gles2_renderer_check_ext(renderer, "GL_OES_EGL_image_external")
          ? sizeof(pairs) / sizeof(pairs[0]) : 1,
  };
  if (!wlr_color_representation_manager_v1_create(display, 1, &representation)) goto fail;
  const enum wp_color_manager_v1_transfer_function functions[] = {
      WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_COMPOUND_POWER_2_4,
      WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ,
  };
  const enum wp_color_manager_v1_primaries primaries[] = {
      WP_COLOR_MANAGER_V1_PRIMARIES_SRGB, WP_COLOR_MANAGER_V1_PRIMARIES_BT2020,
  };
  const enum wp_color_manager_v1_render_intent intent = WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL;
  const struct wlr_color_manager_v1_options options = {
      .features = {.parametric = true, .set_mastering_display_primaries = true},
      .render_intents = &intent, .render_intents_len = 1,
      .transfer_functions = functions, .transfer_functions_len = sizeof(functions) / sizeof(functions[0]),
      .primaries = primaries, .primaries_len = sizeof(primaries) / sizeof(primaries[0]),
  };
  struct wlr_color_manager_v1 *color = wlr_color_manager_v1_create(display, 2, &options);
  if (!color) goto fail;
  p->feedback.display = display;
  p->feedback.manager = color;
  wl_list_init(&p->feedback.hdr_surfaces);
  scene->feedback = &p->feedback;
  rediwm_scene_outputs_set_color_manager(scene, color);
  p->scene = scene;
  struct wlr_ext_workspace_manager_v1 *workspaces = wlr_ext_workspace_manager_v1_create(display, 1);
  if (!workspaces) goto fail;
  p->workspaces = workspaces;
  p->workspace_commit.notify = workspace_commit;
  wl_signal_add(&workspaces->events.commit, &p->workspace_commit);
  p->group = wlr_ext_workspace_group_handle_v1_create(workspaces, 0);
  struct wlr_ext_workspace_handle_v1 *canvas = wlr_ext_workspace_handle_v1_create(workspaces, "rediwm-canvas", 0);
  if (!p->group || !canvas) goto fail;
  p->canvas = canvas;
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
