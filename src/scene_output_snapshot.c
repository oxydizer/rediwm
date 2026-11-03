// A frozen, shaped window for the minimize ribbon. Reuse resolved geometry and
// the ordinary draw path, without changing output visibility or surface feedback.
#include "scene_output_internal.h"
#include "explicit_sync.h"
#include "node_surface.h"

struct snapshot {
    struct rediwm_output_renderer *renderer;
    struct rediwm_scene_output *out;
    struct rediwm_node *root;
    struct rediwm_read_fence *fence;
    struct wlr_render_pass *pass;
    struct output_view view;
    pixman_region32_t damage;
    unsigned count;
};

static bool snapshot_item(const struct rediwm_item *item, struct rediwm_node *node, void *data) {
    struct snapshot *s = data;
    if (item->kind == REDIWM_ITEM_EFFECT || item->kind == REDIWM_ITEM_SHADOW ||
            item->kind == REDIWM_ITEM_RIBBON) return true;
    struct rediwm_node *ancestor = node;
    while (ancestor && ancestor != s->root)
        ancestor = ancestor->parent ? &ancestor->parent->node : NULL;
    if (!ancestor) return true;
    struct rediwm_buffer *buffer = rediwm_buffer_from_node(node);
    if (item->content.opacity == 0 || (item->kind == REDIWM_ITEM_RECT && item->content.color[3] == 0) ||
            (buffer && !buffer->buffer && !buffer->texture && !buffer->is_single_pixel_buffer)) return true;
    struct rediwm_snap b = rediwm_edges_snap(item->edges);
    struct entry e = {.item = *item, .transport = node, .box = {b.x, b.y, b.width, b.height}};
    pixman_region32_init_rect(&e.visible, b.x, b.y, b.width, b.height);
    pixman_region32_init(&e.opaque);
    if (buffer && buffer->surface) rediwm_read_fence_note(s->fence, buffer->surface->surface);
    bool ok = scene_output_render_entry(s->renderer, &e, s->out, s->pass, &s->view, &s->damage, false);
    pixman_region32_fini(&e.opaque);
    pixman_region32_fini(&e.visible);
    s->count++;
    return ok;
}

bool rediwm_output_snapshot(struct rediwm_output_renderer *r, struct rediwm_projection *projection,
        struct rediwm_scene_output *out, struct rediwm_node *root, struct wlr_box box, float scale,
        struct wlr_buffer *buffer, struct rediwm_read_fence *fence, struct rediwm_buffer *dest) {
    struct wlr_buffer_pass_options options = {0};
    rediwm_read_fence_begin(fence, &options);
    struct wlr_render_pass *pass = rediwm_output_begin_pass(r, buffer, &options);
    if (!pass) { rediwm_read_fence_end(fence, false); return false; }
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, buffer->width, buffer->height}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    struct snapshot s = {.renderer = r, .out = out, .root = root, .pass = pass, .fence = fence,
        .view = {.logical = box, .scale = scale, .width = buffer->width, .height = buffer->height,
            .trans_width = buffer->width, .trans_height = buffer->height}};
    pixman_region32_init_rect(&s.damage, 0, 0, buffer->width, buffer->height);
    bool ok = rediwm_projection_for_each_item(projection, false, snapshot_item, &s);
    bool submitted = wlr_render_pass_submit(pass);
    rediwm_read_fence_end(fence, submitted);
    pixman_region32_fini(&s.damage);
    if (!ok || !submitted || !s.count) return false;
    struct wlr_texture *texture = wlr_texture_from_buffer(out->output->renderer, buffer);
    if (!texture) return false;
    rediwm_buffer_set_buffer(dest, buffer);
    rediwm_buffer_set_texture(dest, texture);
    return true;
}
