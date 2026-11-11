// Drawing entries through the owned pass (scene_pass.c): clipped shapes, rects,
// textures, shadows and glass. Part of scene_output.c.
#include "scene_output_internal.h"

// Which device corner each logical corner (tl, tr, br, bl) lands on, found by
// moving a one-pixel box in each corner of a small frame through the same
// transform device_box applies, so the two cannot disagree.
static void device_radii(float out[4], const float in[4], enum wl_output_transform transform) {
    enum { W = 3, H = 5 };
    const struct wlr_box corners[4] = {{0, 0, 1, 1}, {W - 1, 0, 1, 1}, {W - 1, H - 1, 1, 1}, {0, H - 1, 1, 1}};
    const int w = (transform & 1) ? H : W, h = (transform & 1) ? W : H;
    for (int i = 0; i < 4; i++) {
        struct wlr_box b;
        wlr_box_transform(&b, &corners[i], wlr_output_transform_invert(transform), W, H);
        out[b.x < w / 2 ? (b.y < h / 2 ? 0 : 3) : (b.y < h / 2 ? 1 : 2)] = in[i];
    }
}
// A polygon's vertices (layout space) in the shape's device box: the snapped layout
// box `f` is stretched over the device box so the corners of the two coincide, then
// taken through the output's transform with the same probing as device_radii (the
// box's own size matters for a flip, which is why this is not a pixel box).
static void device_points(float out[][2], const double in[][2], int n, struct rediwm_snap f,
                          const struct wlr_box *box, enum wl_output_transform transform) {
    enum { W = 3, H = 5 };
    struct wlr_box px[3], at[3] = {{0, 0, 1, 1}, {1, 0, 1, 1}, {0, 1, 1, 1}};
    for (int i = 0; i < 3; i++) wlr_box_transform(&px[i], &at[i], wlr_output_transform_invert(transform), W, H);
    const int ex[2] = {px[1].x - px[0].x, px[1].y - px[0].y}, ey[2] = {px[2].x - px[0].x, px[2].y - px[0].y};
    const double pre_w = (transform & 1) ? box->height : box->width, pre_h = (transform & 1) ? box->width : box->height;
    const double shift[2] = {(ex[0] < 0 ? pre_w : 0) + (ey[0] < 0 ? pre_h : 0),
                             (ex[1] < 0 ? pre_w : 0) + (ey[1] < 0 ? pre_h : 0)};
    for (int i = 0; i < n; i++) {
        const double lx = (in[i][0] - f.x) * pre_w / f.width, ly = (in[i][1] - f.y) * pre_h / f.height;
        out[i][0] = (float)(ex[0] * lx + ey[0] * ly + shift[0]);
        out[i][1] = (float)(ex[1] * lx + ey[1] * ly + shift[1]);
    }
}
// Circles retain one uniform scale even when the enclosing quad's snapped
// width and height differ by a pixel. Convert their exact layout-space centre
// and unit axis through the output transform, then anchor at the device box.
static void device_sector(struct rediwm_pass_sector *out, const struct rediwm_sector *in,
                          const struct wlr_box *box, const struct output_view *v) {
    *out = (struct rediwm_pass_sector){0};
    if (in->radii[1] <= 0) return;
    enum { W = 3, H = 5 };
    struct wlr_box px[3], at[3] = {{0, 0, 1, 1}, {1, 0, 1, 1}, {0, 1, 1, 1}};
    for (int i = 0; i < 3; i++) wlr_box_transform(&px[i], &at[i], wlr_output_transform_invert(v->transform), W, H);
    const int ex[2] = {px[1].x - px[0].x, px[1].y - px[0].y};
    const int ey[2] = {px[2].x - px[0].x, px[2].y - px[0].y};
    const double x = (in->center[0] - v->logical.x) * v->scale;
    const double y = (in->center[1] - v->logical.y) * v->scale;
    const int origin[2] = {box->x, box->y};
    for (int i = 0; i < 2; i++) {
        const double shift = (ex[i] < 0 ? v->trans_width : 0) + (ey[i] < 0 ? v->trans_height : 0);
        out->center[i] = (float)(ex[i] * x + ey[i] * y + shift - origin[i]);
        out->axis[i] = (float)(ex[i] * in->axis[0] + ey[i] * in->axis[1]);
        out->radii[i] = (float)(in->radii[i] * v->scale);
        out->half_angle[i] = (float)in->half_angle[i];
    }
}
// The pass's shape for a clip: the clip's box snapped in layout space like any
// item's, then taken to device pixels by the same function as the pieces that
// tile it, so the shape and the quads agree on every pixel column. A ring is
// whole device pixels, never thinner than one.
static void shape_for(struct rediwm_pass_shape *s, const struct rediwm_clip *c, const struct output_view *v) {
    const struct rediwm_snap f = rediwm_edges_snap(c->edges);
    s->box = device_box((struct wlr_box){f.x, f.y, f.width, f.height}, v);
    float radii[4];
    for (int i = 0; i < 4; i++) radii[i] = (float)(c->radii[i] * v->scale);
    device_radii(s->radii, radii, v->transform);
    s->poly_count = c->poly_count;
    if (c->poly_count) device_points(s->poly, c->poly, c->poly_count, f, &s->box, v->transform);
    device_sector(&s->sector, &c->sector, &s->box, v);
    s->sector_texture_height = (float)(c->sector_texture_height * v->scale);
    s->sector_texture_flip = v->transform >= WL_OUTPUT_TRANSFORM_FLIPPED ? -1.f : 1.f;
    s->sector_texture_transform = v->transform;
    memset(s->sector_texture_rect, 0, sizeof(s->sector_texture_rect));
    s->border = c->border > 0 ? fmaxf(1.f, roundf((float)(c->border * v->scale))) : 0.f;
    for (int i = 0; i < 4; i++) s->border_color[i] = c->border_color[i];
    s->glow_radius = s->glow_depth = 0;
    memset(s->glow_center, 0, sizeof(s->glow_center));
    memset(s->glow_color, 0, sizeof(s->glow_color));
    if (c->glow_radius > 0 && c->glow_color[3] > 0) {
        // The highlight's point goes through the same transform as the box, as a
        // one-pixel box (the loss is under a layout pixel, far inside its radius).
        const struct wlr_box at = device_box((struct wlr_box){(int)floor(c->glow_x), (int)floor(c->glow_y), 1, 1}, v);
        s->glow_center[0] = at.x + at.width * .5f - s->box.x;
        s->glow_center[1] = at.y + at.height * .5f - s->box.y;
        s->glow_radius = (float)(c->glow_radius * v->scale);
        s->glow_depth = (float)(c->glow_depth * v->scale);
        for (int i = 0; i < 4; i++) s->glow_color[i] = c->glow_color[i];
    }
}
// The node's own texture cache. Do not keep an extra buffer lock: shm clients must
// still update in place.
static struct wlr_texture *buffer_texture(struct rediwm_buffer *b, struct wlr_renderer *renderer) {
    if (!b->buffer || b->texture) return b->texture;
    struct wlr_client_buffer *client = wlr_client_buffer_get(b->buffer);
    if (client) return client->texture;
    struct wlr_texture *texture = wlr_texture_from_buffer(renderer, b->buffer);
    if (!texture) return NULL;
    if (b->own_buffer) {
        b->own_buffer = false;
        wlr_buffer_unlock(b->buffer);
    }
    rediwm_buffer_set_texture(b, texture);
    return texture;
}
// Most entries lie outside a small repaint, and the region arithmetic below
// (scale, expand, transform) is what costs at fractional scale. Reject from the
// device box first. A clip is a subregion of the entry's box rounded outward by
// wlr_region_scale and then expanded by one pixel, so two pixels of margin
// around the rounded box can never reject an entry that would have drawn.
static bool misses_damage(const struct wlr_box *dst, pixman_region32_t *damage) {
    const pixman_box32_t *extents = pixman_region32_extents(damage);
    return dst->x - 2 >= extents->x2 || dst->x + dst->width + 2 <= extents->x1 ||
        dst->y - 2 >= extents->y2 || dst->y + dst->height + 2 <= extents->y1;
}
static void render_effect(struct entry *e, struct wlr_render_pass *pass, const struct output_view *v,
        struct rediwm_output_renderer *r, struct rediwm_scene_output *out, const pixman_region32_t *clip,
        bool backdrop) {
    struct effect_cache *c = e->cache;
    if (!c) return;
    struct wlr_renderer *renderer = out->output->renderer;
    if (e->reblur && !backdrop && !pixman_region32_not_empty((pixman_region32_t *)clip)) {
        // Hidden here (kept only for another effect's blur): re-take it when shown.
        c->valid = false;
        return;
    }
    if (e->reblur && !backdrop) {
        // Draw what lies below the effect, bottom up, into a quarter-size image of
        // the region the blur reads, and blur that (stage 5f): no full-size copy.
        c->region = device_box(e->padded, v);
        c->sigma = e->sigma * v->scale;
        // A quarter of the logical size, as glass.c blurred: the same pixels at any
        // scale (a quarter of the device size cost 2.25 times more at 1.5).
        rediwm_scene_pass_begin_backdrop(pass, c->region, 4 * (float)v->scale);
        struct entry *entries = r->entries.data;
        const size_t len = r->entries.size / sizeof(*entries);
        const size_t here = (size_t)(e - entries);
        // Cull within the blur's region as the screen is culled: walking down from
        // the effect, an item that opaque items below the effect hide entirely is
        // not drawn (a fullscreen client under the taskbar hides everything else).
        pixman_region32_t region, hidden;
        pixman_region32_init_rect(&region, c->region.x, c->region.y, c->region.width, c->region.height);
        pixman_region32_init(&hidden);
        bool draw[len];
        for (size_t j = here + 1; j < len; j++) {
            struct entry *below = &entries[j];
            const struct wlr_box b = device_box(below->box, v);
            draw[j] = pixman_region32_contains_rectangle(&region, &(pixman_box32_t){b.x, b.y, b.x + b.width,
                b.y + b.height}) != PIXMAN_REGION_OUT &&
                pixman_region32_contains_rectangle(&hidden, &(pixman_box32_t){b.x, b.y, b.x + b.width,
                b.y + b.height}) != PIXMAN_REGION_IN;
            if (draw[j] && pixman_region32_not_empty(&below->opaque)) {
                pixman_region32_t opaque;
                pixman_region32_init(&opaque);
                pixman_region32_copy(&opaque, &below->opaque);
                device_region(&opaque, v, false);
                pixman_region32_union(&hidden, &hidden, &opaque);
                pixman_region32_fini(&opaque);
            }
        }
        for (size_t j = len; j > here + 1; j--)
            if (draw[j - 1]) scene_output_render_entry(r, &entries[j - 1], out, pass, v, &region, true);
        pixman_region32_fini(&hidden);
        pixman_region32_fini(&region);
        rediwm_scene_pass_end_backdrop(pass, &c->backdrop, c->sigma);
        c->valid = true;
        c->carried = false;
        rediwm_scene_output_reblurs++;
    }
    if (!c->valid || !c->backdrop || !pixman_region32_not_empty((pixman_region32_t *)clip)) return;
    const struct wlr_box dst = device_box(e->box, v);
    struct rediwm_pass_shape shape = {.box = dst};
    if (e->item.clip) {
        shape_for(&shape, e->item.clip, v);
    } else {
        const float radius = e->glass.radius * e->item.scale * v->scale;
        for (int i = 0; i < 4; i++) shape.radii[i] = radius;
    }
    shape.border = 0;
    struct rediwm_pass_backdrop o = {.backdrop = c->backdrop, .saturation = e->glass.saturation,
        .opacity = e->glass.opacity * e->item.content.opacity, .clip = clip};
    // The surface over the effect: its alpha is made up to the coverage.
    struct entry *entries = r->entries.data;
    const size_t len = r->entries.size / sizeof(*entries);
    for (size_t i = 0; i < len; i++) {
        struct entry *f = &entries[i];
        if (f->transport != e->front || f->item.kind == REDIWM_ITEM_RECT) continue;
        struct rediwm_buffer *b = rediwm_buffer_from_node(f->transport);
        if (b->is_single_pixel_buffer || b->transform != WL_OUTPUT_TRANSFORM_NORMAL) break;
        o.front = buffer_texture(b, renderer);
        o.front_box = device_box(f->box, v);
        o.front_opacity = f->item.content.opacity;
        break;
    }
    // The effect shows what is behind its window: it is dimmed with the window.
    const struct rediwm_content *content = &e->item.content;
    const bool graded = content->dim_brightness > 0 || content->dim_saturation > 0;
    if (graded) rediwm_scene_pass_set_dim(pass, content->dim_brightness, content->dim_saturation);
    rediwm_scene_pass_add_backdrop(pass, &shape, dst, &o);
    if (graded) rediwm_scene_pass_set_dim(pass, 0, 0);
}
// `backdrop`: drawing into an effect's quarter-size image (stage 5f), where an
// item counts with its whole box, not what is visible of it on screen, and
// `damage` is the region the blur reads.
bool scene_output_render_entry(struct rediwm_output_renderer *r, struct entry *e, struct rediwm_scene_output *out,
        struct wlr_render_pass *pass, const struct output_view *v, pixman_region32_t *damage, bool backdrop) {
    struct wlr_box dst = device_box(e->box, v);
    if (misses_damage(&dst, damage)) return true;
    pixman_region32_t clip, blend, core;
    pixman_region32_init(&clip);
    pixman_region32_init(&blend);
    pixman_region32_init(&core);
    bool graded = false;
    if (backdrop) pixman_region32_init_rect(&clip, dst.x, dst.y, dst.width, dst.height);
    else {
        pixman_region32_copy(&clip, &e->visible);
        device_region(&clip, v, true);
    }
    pixman_region32_intersect(&clip, &clip, damage);
    bool ok = true;
    if (e->item.kind == REDIWM_ITEM_EFFECT) {
        // A re-blur takes its blur even where the effect itself is hidden.
        render_effect(e, pass, v, r, out, &clip, backdrop);
        goto done;
    }
    if (!pixman_region32_not_empty(&clip)) goto done;
    if (e->item.kind == REDIWM_ITEM_RIBBON) {
        scene_output_render_ribbon(e, pass, v, dst, &clip);
        goto done;
    }
    // A clipped item is drawn in two parts: `core` (its interior, which the model
    // proves fully covered and opaque) as before, without the shape, and the rest
    // (corners, ring, anything translucent) through the shape.
    struct rediwm_pass_shape shape;
    const bool shaped = e->item.clip != NULL;
    if (shaped) {
        shape_for(&shape, e->item.clip, v);
        pixman_region32_copy(&core, &e->opaque);
        device_region(&core, v, false);
        // One rectangle, deeper than the corner arcs and the ring. The model's cover
        // is a cross of up to three, which leaves about twelve scissored draws per
        // window for what a rim of a few shaded pixels costs far less than: draws
        // dominated the output build in a drag.
        float depth = fmaxf(fmaxf(shape.radii[0], shape.radii[1]), fmaxf(shape.radii[2], shape.radii[3]));
        if (shape.poly_count || shape.sector.radii[1] > 0) depth = (float)(e->item.clip->inset * v->scale);
        const int inset = (int)ceilf(fmaxf(depth, shape.border + shape.glow_depth)) + REDIWM_CLIP_OPAQUE_MARGIN;
        if (shape.box.width > 2 * inset && shape.box.height > 2 * inset)
            pixman_region32_intersect_rect(&core, &core, shape.box.x + inset, shape.box.y + inset,
                shape.box.width - 2 * inset, shape.box.height - 2 * inset);
        else
            pixman_region32_clear(&core);
        pixman_region32_intersect(&core, &core, &clip);
        pixman_region32_subtract(&clip, &clip, &core);
    }
    const struct rediwm_content *c = &e->item.content;
    if (shaped) memcpy(shape.sector_texture_rect, c->sector_rect, sizeof(shape.sector_texture_rect));
    // A window that is not the focus is drawn dimmed, whole: the pass grades each
    // draw (the interior, the rim and the ring alike) until it is reset below.
    graded = c->dim_brightness > 0 || c->dim_saturation > 0;
    if (graded) rediwm_scene_pass_set_dim(pass, c->dim_brightness, c->dim_saturation);
    if (e->item.kind == REDIWM_ITEM_SHADOW) {
        // The offset is taken to device pixels as the difference of two snapped
        // boxes, so an output transform turns it with them.
        const struct rediwm_shadow *sh = e->item.shadow;
        struct rediwm_clip moved = sh->shape;
        moved.edges.x1 += sh->offset_x;
        moved.edges.x2 += sh->offset_x;
        moved.edges.y1 += sh->offset_y;
        moved.edges.y2 += sh->offset_y;
        struct rediwm_pass_shape at;
        shape_for(&shape, &sh->shape, v);
        shape_for(&at, &moved, v);
        struct rediwm_pass_shadow shadow = {
            .offset_x = (float)(at.box.x - shape.box.x), .offset_y = (float)(at.box.y - shape.box.y),
            .softness = (float)(sh->softness * v->scale), .hide_inside = true, .clip = &clip};
        for (int i = 0; i < 4; i++) shadow.color[i] = sh->color[i] * c->opacity;
        rediwm_scene_pass_add_shadow(pass, &shape, &shadow);
    } else if (e->item.kind == REDIWM_ITEM_RECT) {
        struct wlr_render_rect_options rect = {.box = dst,
            .color = {c->color[0], c->color[1], c->color[2], c->color[3]}};
        if (pixman_region32_not_empty(&core)) {
            rect.clip = &core;
            wlr_render_pass_add_rect(pass, &rect);
        }
        rect.clip = &clip;
        if (!shaped) wlr_render_pass_add_rect(pass, &rect);
        else if (pixman_region32_not_empty(&clip)) rediwm_scene_pass_add_rect_shaped(pass, &rect, &shape);
    } else {
        struct rediwm_buffer *b = rediwm_buffer_from_node(e->transport);
        if (b->is_single_pixel_buffer) {
            const uint32_t *color = b->single_pixel_buffer_color;
            // Match wlroots' single-pixel path during parity, including its
            // treatment of opacity (only alpha is multiplied there).
            struct wlr_render_rect_options rect = {.box = dst,
                .color = {(float)color[0] / (float)UINT32_MAX, (float)color[1] / (float)UINT32_MAX,
                    (float)color[2] / (float)UINT32_MAX, (float)color[3] / (float)UINT32_MAX * c->opacity}};
            if (pixman_region32_not_empty(&core)) {
                rect.clip = &core;
                wlr_render_pass_add_rect(pass, &rect);
            }
            rect.clip = &clip;
            if (!shaped) wlr_render_pass_add_rect(pass, &rect);
            else if (pixman_region32_not_empty(&clip)) rediwm_scene_pass_add_rect_shaped(pass, &rect, &shape);
        } else {
            struct wlr_texture *texture = buffer_texture(b, out->output->renderer);
            if (!texture) { ok = false; goto done; }
            struct wlr_render_texture_options t = {
                .texture = texture, .dst_box = dst, .src_box = c->src_box,
                .transform = wlr_output_transform_compose(wlr_output_transform_invert(c->transform), v->transform),
                .alpha = &c->opacity, .filter_mode = c->filter_mode,
                .wait_timeline = b->wait_timeline, .wait_point = b->wait_point,
            };
            if (pixman_region32_not_empty(&core)) {
                t.clip = &core;
                t.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
                wlr_render_pass_add_texture(pass, &t);
            }
            t.clip = &clip;
            if (shaped) {
                t.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED;
                if (pixman_region32_not_empty(&clip)) rediwm_scene_pass_add_texture_shaped(pass, &t, &shape);
            } else {
                pixman_region32_copy(&blend, &e->opaque);
                device_region(&blend, v, false);
                pixman_region32_subtract(&blend, &clip, &blend);
                t.blend_mode = pixman_region32_not_empty(&blend) ? WLR_RENDER_BLEND_MODE_PREMULTIPLIED : WLR_RENDER_BLEND_MODE_NONE;
                wlr_render_pass_add_texture(pass, &t);
            }
        }
        e->sampled = true;
    }
done:
    // What is drawn next (the next item, the software cursor) is not this item's.
    if (graded) rediwm_scene_pass_set_dim(pass, 0, 0);
    pixman_region32_fini(&clip);
    pixman_region32_fini(&blend);
    pixman_region32_fini(&core);
    return ok;
}
