#define WLR_USE_UNSTABLE
#include "ribbon.h"
#include "node.h"
#include <stdlib.h>
#include <string.h>

struct ribbon_node {
    struct wlr_addon addon;
    struct rediwm_ribbon mesh;
};
static void destroy(struct wlr_addon *addon) {
    struct ribbon_node *r = wl_container_of(addon, r, addon);
    wlr_addon_finish(addon);
    free(r);
}
static const struct wlr_addon_interface impl = {"rediwm-ribbon", destroy};
static bool no_input(struct rediwm_buffer *b, double *x, double *y) {
    (void)b; (void)x; (void)y;
    return false;
}
struct rediwm_buffer *rediwm_ribbon_create(struct rediwm_tree *parent) {
    struct ribbon_node *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    struct rediwm_buffer *b = rediwm_buffer_create(parent, NULL);
    if (!b) { free(r); return NULL; }
    b->point_accepts_input = no_input;
    wlr_addon_init(&r->addon, &b->node.addons, NULL, &impl);
    return b;
}
const struct rediwm_ribbon *rediwm_ribbon_get(struct rediwm_node *node) {
    struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &impl);
    struct ribbon_node *r;
    return addon ? (r = wl_container_of(addon, r, addon), &r->mesh) : NULL;
}
void rediwm_ribbon_update(struct rediwm_buffer *b, const struct rediwm_ribbon *mesh,
        int x, int y, int width, int height) {
    struct rediwm_ribbon *dst = (struct rediwm_ribbon *)rediwm_ribbon_get(&b->node);
    if (!dst || mesh->count > REDIWM_RIBBON_VERTICES) return;
    *dst = *mesh;
    rediwm_node_set_position(&b->node, x, y);
    rediwm_buffer_set_dest_size(b, width, height);
    rediwm_node_set_enabled(&b->node, mesh->count >= 4);
    // Content can animate without moving the node. Attribute damage to this
    // painted leaf so retained glass above it sees the change.
    if (b->node.scene->buffer_damaged)
        b->node.scene->buffer_damaged(b->node.scene->changed_data, b, NULL);
    rediwm_node_touch(&b->node);
}
