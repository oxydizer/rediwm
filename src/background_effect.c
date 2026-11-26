// ext-background-effect-v1. Tie region changes to wlroots' surface state queue,
// including commits cached by synchronized subsurfaces or explicit sync.
#define WLR_USE_UNSTABLE
#include <stdlib.h>
#include <wlr/types/wlr_compositor.h>
#include "background_effect.h"
#include "ext-background-effect-v1-protocol.h"
#include "glass.h"
#include "node_surface.h"

struct region_state {
  pixman_region32_t region;
  bool set;
};

struct background_effect {
  struct wl_resource *resource;
  struct glass_engine *engine;
  struct wlr_addon addon;
  struct wlr_surface_synced synced;
  struct region_state pending, current;
};

static void state_init(void *data) {
  struct region_state *state = data;
  pixman_region32_init(&state->region);
}

static void state_finish(void *data) {
  struct region_state *state = data;
  pixman_region32_fini(&state->region);
}

static void state_move(void *dest, void *source) {
  struct region_state *to = dest, *from = source;
  if (!from->set) return;
  pixman_region32_t old = to->region;
  to->region = from->region;
  to->set = true;
  from->region = old;
  pixman_region32_clear(&from->region);
  from->set = false;
}

static const struct wlr_surface_synced_impl synced_impl = {
  .state_size = sizeof(struct region_state),
  .init_state = state_init, .finish_state = state_finish, .move_state = state_move,
};

static void surface_gone(struct wlr_addon *addon) {
  struct background_effect *effect = wl_container_of(addon, effect, addon);
  if (effect->resource) wl_resource_set_user_data(effect->resource, NULL);
  wlr_addon_finish(addon);
  wlr_surface_synced_finish(&effect->synced);
  free(effect);
}

static const struct wlr_addon_interface addon_impl = {"ext-background-effect-v1", surface_gone};

static struct background_effect *effect_for(struct wlr_surface *surface) {
  struct wlr_addon *addon = wlr_addon_find(&surface->addons, NULL, &addon_impl);
  struct background_effect *effect;
  return addon ? wl_container_of(addon, effect, addon) : NULL;
}

static void destroy_request(struct wl_client *client, struct wl_resource *resource) {
  (void)client;
  wl_resource_destroy(resource);
}

static void effect_released(struct wl_resource *resource) {
  struct background_effect *effect = wl_resource_get_user_data(resource);
  if (!effect) return;
  effect->resource = NULL;
  // Keep the synced state on the surface. Destroy/recreate before a commit
  // must leave the old applied region visible until the new state latches.
  pixman_region32_clear(&effect->pending.region);
  effect->pending.set = true;
}

static void set_region(struct wl_client *client, struct wl_resource *resource,
                       struct wl_resource *region) {
  struct background_effect *effect = wl_resource_get_user_data(resource);
  if (!effect) {
    wl_resource_post_error(resource, EXT_BACKGROUND_EFFECT_SURFACE_V1_ERROR_SURFACE_DESTROYED,
                           "wl_surface has been destroyed");
    return;
  }
  if (region) {
    if (!pixman_region32_copy(&effect->pending.region, wlr_region_from_resource(region))) {
      wl_client_post_no_memory(client);
      return;
    }
  } else {
    pixman_region32_clear(&effect->pending.region);
  }
  effect->pending.set = true;
}

static const struct ext_background_effect_surface_v1_interface surface_impl = {
  .destroy = destroy_request, .set_blur_region = set_region,
};

static void get_effect(struct wl_client *client, struct wl_resource *manager,
                       uint32_t id, struct wl_resource *surface_resource) {
  struct wlr_surface *surface = wlr_surface_from_resource(surface_resource);
  struct background_effect *effect = effect_for(surface);
  if (effect && effect->resource) {
    wl_resource_post_error(manager, EXT_BACKGROUND_EFFECT_MANAGER_V1_ERROR_BACKGROUND_EFFECT_EXISTS,
                           "wl_surface already has a background effect");
    return;
  }
  if (!effect) {
    effect = calloc(1, sizeof(*effect));
    if (!effect || !wlr_surface_synced_init(&effect->synced, surface, &synced_impl,
                                             &effect->pending, &effect->current)) {
      free(effect);
      wl_client_post_no_memory(client);
      return;
    }
    effect->engine = wl_resource_get_user_data(manager);
    wlr_addon_init(&effect->addon, &surface->addons, NULL, &addon_impl);
  }
  effect->resource = wl_resource_create(client, &ext_background_effect_surface_v1_interface, 1, id);
  if (!effect->resource) {
    wl_client_post_no_memory(client);
    return;
  }
  wl_resource_set_implementation(effect->resource, &surface_impl, effect, effect_released);
}

static const struct ext_background_effect_manager_v1_interface manager_impl = {
  .destroy = destroy_request, .get_background_effect = get_effect,
};

static void bind_manager(struct wl_client *client, void *engine, uint32_t version, uint32_t id) {
  struct wl_resource *resource = wl_resource_create(client, &ext_background_effect_manager_v1_interface, version, id);
  if (!resource) {
    wl_client_post_no_memory(client);
    return;
  }
  wl_resource_set_implementation(resource, &manager_impl, engine, NULL);
  ext_background_effect_manager_v1_send_capabilities(resource,
      engine ? EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR : 0);
}

bool rediwm_background_effect_create(struct wl_display *display, struct glass_engine *engine) {
  return wl_global_create(display, &ext_background_effect_manager_v1_interface, 1, engine, bind_manager) != NULL;
}

void rediwm_background_effect_update(struct rediwm_surface *surface, int width, int height) {
  struct background_effect *effect = effect_for(surface->surface);
  if (!effect || !effect->engine) return;
  if (!surface->glass && !pixman_region32_not_empty(&effect->current.region)) return;
  // Clip in surface-local units before translating to the visible buffer's
  // origin. A wl_region may extend far beyond the mapped surface.
  pixman_region32_t region;
  pixman_region32_init(&region);
  bool ok = true;
  if (width > 0 && height > 0 && surface->surface->buffer) {
    ok = pixman_region32_intersect_rect(&region, &effect->current.region,
                                        surface->clip.x, surface->clip.y, width, height);
    pixman_region32_translate(&region, -surface->clip.x, -surface->clip.y);
  }
  if (!ok || !rediwm_glass_set_surface_region(effect->engine, surface, &region))
    wl_resource_post_no_memory(surface->surface->resource);
  pixman_region32_fini(&region);
}
