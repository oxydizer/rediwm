// Glass: the CSS backdrop-filter behind the compositor's own surfaces (window
// titlebars, the taskbar, the start and power menus). This file only registers
// effects; the owned output pass blurs and composites them (scene_output.c,
// stage 5 of docs/plans/scene-graph.md). An effect is a scene node without a
// buffer placed below its target: its place in paint order is where the blur
// reads the framebuffer, and resolve gives it the target's box (projection.c).
#define WLR_USE_UNSTABLE
#include <stdlib.h>
#include <wlr/util/addon.h>
#include "glass.h"
#include "node_surface.h"
#include "scene_graph.h"

enum glass_kind { GLASS_TITLEBAR, GLASS_TASKBAR, GLASS_PANEL, GLASS_SIDEBAR, GLASS_CLIENT };
// Gaussian sigma in logical pixels and saturation for each backdrop.
static const struct { float sigma, saturation; } appearance[] = {
	[GLASS_TITLEBAR] = {22, 1.5f},
	[GLASS_TASKBAR] = {24, 1.5f},
	[GLASS_PANEL] = {26, 1.6f},
	[GLASS_SIDEBAR] = {8, 1.6f},
	[GLASS_CLIENT] = {26, 1.f},
};
struct glass_effect;
struct glass_engine {
	struct wl_list effects;
	// A dragged opaque titlebar keeps its last blur (stage 5, D2).
	struct glass_effect *held;
	uint64_t next_serial;
};
struct glass_effect {
	struct glass_engine *engine;
	struct wl_list link;
	struct rediwm_buffer *node, *target;
	struct wl_listener destroy, target_destroy;
	struct wlr_addon addon; // on the node, for rediwm_glass_effect_info
	enum glass_kind kind;
	uint64_t serial;
	float radius, opacity;
	struct rediwm_glass_region region; // GLASS_CLIENT only
};

struct glass_engine *rediwm_glass_create(void)
{
	struct glass_engine *engine = calloc(1, sizeof(*engine));
	if (!engine)
		return NULL;
	wl_list_init(&engine->effects);
	return engine;
}
static void handle_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_effect *effect = wl_container_of(listener, effect, destroy);
	if (effect->kind == GLASS_CLIENT) {
		if (effect->target->surface) effect->target->surface->glass = NULL;
		pixman_region32_fini(&effect->region.local);
		free(effect->region.layout);
	}
	wlr_addon_finish(&effect->addon);
	if (effect->engine->held == effect)
		effect->engine->held = NULL;
	wl_list_remove(&effect->destroy.link);
	wl_list_remove(&effect->target_destroy.link);
	wl_list_remove(&effect->link);
	free(effect);
}
static void handle_target_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_effect *effect = wl_container_of(listener, effect, target_destroy);
	rediwm_node_destroy(&effect->node->node);
}
static void addon_destroy(struct wlr_addon *addon) { wlr_addon_finish(addon); }
static const struct wlr_addon_interface effect_addon = {.name = "rediwm glass effect",
							  .destroy = addon_destroy};
static struct glass_effect *effect_of(struct rediwm_node *node)
{
	struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &effect_addon);
	struct glass_effect *effect;
	return addon ? (effect = wl_container_of(addon, effect, addon)) : NULL;
}
bool rediwm_glass_effect_info(struct rediwm_node *node, struct rediwm_glass_info *out)
{
	struct glass_effect *effect = effect_of(node);
	if (!effect)
		return false;
	*out = (struct rediwm_glass_info){
	    .target = effect->target,
	    .region = effect->kind == GLASS_CLIENT ? &effect->region : NULL,
	    .sigma = appearance[effect->kind].sigma,
	    .saturation = appearance[effect->kind].saturation,
	    .opacity = effect->opacity,
	    .radius = effect->radius,
	    .serial = effect->serial,
	    .held = effect->engine->held == effect,
	};
	return true;
}
bool rediwm_glass_is_effect_node(struct rediwm_node *node)
{
	return node->type == REDIWM_NODE_BUFFER && effect_of(node);
}
static bool accepts_input(struct rediwm_buffer *buffer, double *x, double *y)
{
	(void)buffer;
	(void)x;
	(void)y;
	return false;
}
struct glass_effect *rediwm_glass_attach(struct glass_engine *engine,
					 struct rediwm_buffer *target,
					 struct rediwm_node *before, enum glass_kind kind)
{
	if (!engine)
		return NULL;
	struct glass_effect *effect = calloc(1, sizeof(*effect));
	if (!effect)
		return NULL;
	effect->node = rediwm_buffer_create(target->node.parent, NULL);
	if (!effect->node) {
		free(effect);
		return NULL;
	}
	effect->engine = engine;
	effect->target = target;
	effect->kind = kind;
	effect->opacity = 1;
	effect->serial = ++engine->next_serial;
	effect->node->point_accepts_input = accepts_input;
	wlr_addon_init(&effect->addon, &effect->node->node.addons, NULL, &effect_addon);
	rediwm_node_place_below(&effect->node->node, before);
	effect->destroy.notify = handle_destroy;
	wl_signal_add(&effect->node->node.events.destroy, &effect->destroy);
	effect->target_destroy.notify = handle_target_destroy;
	wl_signal_add(&target->node.events.destroy, &effect->target_destroy);
	wl_list_insert(&engine->effects, &effect->link);
	return effect;
}
void rediwm_glass_hold(struct glass_engine *engine, struct glass_effect *effect)
{
	if (engine)
		engine->held = effect;
}
void rediwm_glass_configure(struct glass_effect *effect, float radius, float opacity)
{
	if (!effect || (effect->radius == radius && effect->opacity == opacity))
		return;
	effect->radius = radius;
	effect->opacity = opacity;
	rediwm_node_touch(&effect->node->node);
}
void rediwm_glass_detach(struct glass_effect *effect)
{
	if (effect)
		rediwm_node_destroy(&effect->node->node);
}
void rediwm_glass_destroy(struct glass_engine *engine)
{
	if (!engine)
		return;
	struct glass_effect *effect, *tmp;
	wl_list_for_each_safe(effect, tmp, &engine->effects, link)
		rediwm_node_destroy(&effect->node->node);
	free(engine);
}

struct rediwm_node *rediwm_glass_node(struct glass_effect *effect)
{
	return &effect->node->node;
}

bool rediwm_glass_set_surface_region(struct glass_engine *engine, struct rediwm_surface *surface,
                                     const pixman_region32_t *region)
{
	struct glass_effect *effect = surface->glass;
	if (effect && pixman_region32_equal(&effect->region.local, region))
		return true;
	// Replacing the effect damages both masks even when their extents match.
	rediwm_glass_detach(effect);
	if (!pixman_region32_not_empty(region))
		return true;
	effect = rediwm_glass_attach(engine, surface->buffer, &surface->buffer->node, GLASS_CLIENT);
	if (!effect)
		return false;
	surface->glass = effect;
	pixman_region32_init(&effect->region.local);
	effect->region.count = pixman_region32_n_rects(region);
	effect->region.layout = calloc(effect->region.count, sizeof(*effect->region.layout));
	if (effect->region.layout && pixman_region32_copy(&effect->region.local, region))
		return true;
	rediwm_glass_detach(effect);
	return false;
}
