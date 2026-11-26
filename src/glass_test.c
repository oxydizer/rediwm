// Glass registry and its geometry in the graph (stage 5 of docs/plans/scene-graph.md).
// The output pass blurs; its pixel gates are in scene_pass_test.c and
// tests/glass_reblur.py. Needs no GPU.
#include <stdbool.h>
#include <stdlib.h>
static bool fail_next_glass_allocation;
static void *glass_test_calloc(size_t count, size_t size)
{
	if (fail_next_glass_allocation) {
		fail_next_glass_allocation = false;
		return NULL;
	}
	return calloc(count, size);
}
#define calloc glass_test_calloc
#include "glass.c"
#undef calloc
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <drm_fourcc.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/util/log.h>
#include <wlr/types/wlr_output_layout.h>
#include "projection.h"
#include "scene_outputs.h"
#include "scene_graph.h"

struct test_buffer {
	struct wlr_buffer base;
};
static void buffer_destroy(struct wlr_buffer *base)
{
	struct test_buffer *buffer = wl_container_of(base, buffer, base);
	free(buffer);
}
static const struct wlr_buffer_impl buffer_impl = {.destroy = buffer_destroy};
static struct test_buffer *buffer_create(int width, int height)
{
	struct test_buffer *buffer = calloc(1, sizeof(*buffer));
	assert(buffer);
	wlr_buffer_init(&buffer->base, &buffer_impl, width, height);
	return buffer;
}
static void registry_checks(void)
{
	struct rediwm_scene *own = rediwm_scene_create(NULL, NULL);
	assert(own);
	struct glass_engine *engine = rediwm_glass_create();
	assert(engine);
	struct rediwm_buffer *target = rediwm_buffer_create(&own->tree, NULL);
	rediwm_buffer_set_dest_size(target, 200, 60);
	struct glass_effect *effect = rediwm_glass_attach(engine, target, &target->node, GLASS_TITLEBAR);
	assert(effect && rediwm_glass_is_effect_node(&effect->node->node));
	assert(!rediwm_glass_is_effect_node(&target->node));
	// Below its target, so the blur reads what lies under the surface.
	assert(effect->node->node.link.next == &target->node.link);
	struct rediwm_glass_info info;
	assert(!rediwm_glass_effect_info(&target->node, &info));
	assert(rediwm_glass_effect_info(&effect->node->node, &info));
	assert(info.target == target && info.sigma == 22 && info.saturation == 1.5f && info.opacity == 1);
	assert(!info.held && info.serial);
	rediwm_glass_configure(effect, 10, .5f);
	assert(rediwm_glass_effect_info(&effect->node->node, &info) && info.radius == 10 && info.opacity == .5f);
	// A node address may be reused; the serial is not.
	struct rediwm_buffer *panel = rediwm_buffer_create(&own->tree, NULL);
	struct glass_effect *other = rediwm_glass_attach(engine, panel, &panel->node, GLASS_PANEL);
	struct rediwm_glass_info other_info;
	assert(rediwm_glass_effect_info(&other->node->node, &other_info));
	assert(other_info.serial != info.serial && other_info.sigma == 26 && other_info.saturation == 1.6f);
	// The dragged titlebar holds its own effect.
	rediwm_glass_hold(engine, effect);
	assert(rediwm_glass_effect_info(&effect->node->node, &info) && info.held);
	assert(rediwm_glass_effect_info(&other->node->node, &other_info) && !other_info.held);
	// Removing the target removes its effect, and a held one is released.
	rediwm_node_destroy(&target->node);
	assert(engine->held == NULL);
	assert(engine->effects.next == &other->link && other->link.next == &engine->effects);
	// Allocation failure leaves nothing behind.
	fail_next_glass_allocation = true;
	assert(!rediwm_glass_attach(engine, panel, &panel->node, GLASS_PANEL));
	// A live notification can turn its blur off without removing its card.
	rediwm_glass_hold(engine, other);
	rediwm_glass_detach(other);
	assert(engine->held == NULL && wl_list_empty(&engine->effects));
	assert(wl_list_length(&own->tree.children) == 1);
	other = rediwm_glass_attach(engine, panel, &panel->node, GLASS_SIDEBAR);
	assert(other && rediwm_glass_effect_info(&other->node->node, &info));
	assert(info.serial != other_info.serial);
	assert(info.sigma == 8 && info.saturation == 1.6f);
	rediwm_glass_destroy(engine);
	assert(wl_list_length(&own->tree.children) == 1); // the panel; its effect went
	rediwm_scene_destroy(own);
	fputs("PASS: glass registry: info, serials, holds, target lifetime, allocation failure\n", stderr);
}
static bool projection_input(struct rediwm_buffer *buffer, double *x, double *y) {
    (void)buffer;
    // Model a cropped surface's input callback, including a source-local offset.
    if (*x < 10) return false;
    *x += 7; *y += 9;
    return true;
}
struct items { struct rediwm_item effect, target, client; };
static struct rediwm_node *client_node;
static bool find_items(const struct rediwm_item *item, struct rediwm_node *transport, void *data) {
    struct items *found = data;
    if (item->kind == REDIWM_ITEM_EFFECT) found->effect = *item;
    else if (transport == client_node) found->client = *item;
    else if (transport->type == REDIWM_NODE_BUFFER && !rediwm_buffer_from_node(transport)->buffer &&
             item->width == 200) found->target = *item;
    return true;
}
static void projection_checks(struct rediwm_scene_outputs *scene, struct glass_engine *engine) {
    struct rediwm_scene *own = rediwm_scene_create(NULL, NULL);
    struct rediwm_tree *source = rediwm_tree_create(&own->tree);
    struct rediwm_projection *p = rediwm_projection_create(own, source, scene);
    assert(own && source && p);
    struct rediwm_tree *frame = rediwm_tree_create(source);
    rediwm_node_set_position(&frame->node, 101, 51);
    struct test_buffer *image = buffer_create(400, 260);
    struct rediwm_buffer *client = rediwm_buffer_create(frame, &image->base);
    client_node = &client->node;
    wlr_buffer_drop(&image->base);
    rediwm_buffer_set_source_box(client, &(struct wlr_fbox){10, 10, 380, 240});
    rediwm_buffer_set_dest_size(client, 400, 260);
    client->point_accepts_input = projection_input;
    const double levels[] = {1, .85, .70, .55, 1};
    for (size_t j = 0; j < sizeof(levels)/sizeof(levels[0]); j++) {
        double wz = levels[j];
        assert(rediwm_projection_set_tree_zoom(&frame->node, wz));
        for (size_t i = 0; i < sizeof(levels)/sizeof(levels[0]); i++) {
            double z = levels[i];
            rediwm_projection_sync(p, z, -20, -30, 0, 0);
            struct items found = {0};
            rediwm_projection_for_each_item(p, false, find_items, &found);
            const struct rediwm_item *shown = &found.client;
            assert(shown->kind == REDIWM_ITEM_BUFFER);
            const struct rediwm_snap snap = rediwm_edges_snap(shown->edges);
            assert(snap.x == lround(121*z) && snap.y == lround(81*z));
            assert(snap.width == lround(121*z+400*wz*z) - lround(121*z));
            assert(fabs(shown->scale - wz*z) < .0001);
            assert(shown->content.src_box.x == 10 && shown->content.src_box.width == 380);
            assert(frame->node.x == 101 && frame->node.y == 51);
            assert(client->dst_width == 400 && client->dst_height == 260);
            struct rediwm_hit hit;
            assert(rediwm_projection_node_at(p, snap.x + snap.width * .5, snap.y + snap.height * .5, &hit));
            assert(hit.own == &client->node);
            assert(fabs(hit.x - 207) < .0001 && fabs(hit.y - 139) < .0001);
            assert(!rediwm_projection_node_at(p, snap.x + 1, snap.y + 1, &hit));
        }
    }
    // An effect has its target's box at every zoom, and is shown only with it.
    assert(rediwm_projection_set_tree_zoom(&frame->node, .70));
    struct rediwm_buffer *target = rediwm_buffer_create(frame, NULL);
    rediwm_node_set_position(&target->node, 0, 0);
    rediwm_buffer_set_dest_size(target, 200, 60);
    struct glass_effect *effect = rediwm_glass_attach(engine, target, &target->node, GLASS_TITLEBAR);
    assert(effect);
    for (size_t i = 0; i < sizeof(levels)/sizeof(levels[0]); i++) {
        rediwm_projection_sync(p, levels[i], 0, 0, 0, 0);
        struct items found = {0};
        rediwm_projection_for_each_item(p, false, find_items, &found);
        assert(found.effect.kind == REDIWM_ITEM_EFFECT && found.target.width == 200);
        assert(found.effect.edges.x1 == found.target.edges.x1 && found.effect.edges.y2 == found.target.edges.y2);
        assert(found.effect.width == 200 && found.effect.height == 60);
        assert(fabs(found.effect.scale - .70 * levels[i]) < .0001);
    }
    rediwm_node_set_enabled(&target->node, false);
    rediwm_projection_sync(p, .55, 0, 0, 0, 0);
    struct items hidden = {0};
    rediwm_projection_for_each_item(p, false, find_items, &hidden);
    assert(hidden.effect.kind != REDIWM_ITEM_EFFECT);
    // Source destruction tears down the graph's items, including effects.
    rediwm_node_destroy(&frame->node);
    struct items gone = {0};
    rediwm_projection_for_each_item(p, false, find_items, &gone);
    assert(gone.client.width == 0 && gone.effect.kind != REDIWM_ITEM_EFFECT);
    rediwm_projection_destroy(p);
    rediwm_scene_destroy(own);
    fputs("PASS: projection geometry, input, glass geometry and destruction\n", stderr);
}
int main(void)
{
	wlr_log_init(WLR_ERROR, NULL);
	registry_checks();
	struct wl_display *display = wl_display_create();
	assert(display);
	struct wlr_output_layout *layout = wlr_output_layout_create(display);
	assert(layout);
	struct rediwm_scene_outputs *scene = rediwm_scene_outputs_create(layout);
	assert(scene);
	struct glass_engine *engine = rediwm_glass_create();
	assert(engine);
	projection_checks(scene, engine);
	rediwm_glass_destroy(engine);
	rediwm_scene_outputs_destroy(scene);
	wlr_output_layout_destroy(layout);
	wl_display_destroy(display);
	return 0;
}
