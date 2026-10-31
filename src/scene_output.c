// Owned output assembly, wlroots 0.20 ABI. Geometry is resolved by projection;
// scene nodes below are resource/feedback transports, never world geometry.
#include "scene_output_internal.h"

// The parts: scene_output_collect.c turns the graph into this frame's entries,
// scene_output_effects.c decides which glass blurs are re-taken and
// scene_output_draw.c draws entries and effects. This file keeps the
// per-output state, direct scanout, the damage audit and the frame build.

struct rediwm_output_renderer *rediwm_output_renderer_create(struct wlr_renderer *renderer) {
    struct rediwm_output_renderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->pass = rediwm_scene_renderer_create(renderer);
    if (!r->pass) { free(r); return NULL; }
    wl_array_init(&r->entries);
    wl_list_init(&r->outputs);
    return r;
}
bool rediwm_output_renderer_enable_shapes(struct rediwm_output_renderer *r) {
    return rediwm_scene_renderer_enable_shapes(r->pass);
}
bool rediwm_output_renderer_enable_external(struct rediwm_output_renderer *r) {
    return rediwm_scene_renderer_enable_external(r->pass);
}
bool rediwm_output_renderer_enable_polygons(struct rediwm_output_renderer *r) {
    return rediwm_scene_renderer_enable_polygons(r->pass);
}
bool rediwm_output_renderer_enable_backdrops(struct rediwm_output_renderer *r) {
    r->has_backdrops = rediwm_scene_renderer_enable_backdrops(r->pass);
    return r->has_backdrops;
}
static void cache_destroy(struct rediwm_output_renderer *r, struct effect_cache *c) {
    rediwm_scene_renderer_destroy_backdrop(r->pass, c->backdrop);
    wl_list_remove(&c->link);
    free(c);
}
static void output_state_destroy(struct output_state *os) {
    struct effect_cache *c, *next;
    wl_list_for_each_safe(c, next, &os->caches, link) cache_destroy(os->renderer, c);
    wl_list_remove(&os->destroy.link);
    wl_list_remove(&os->link);
    free(os);
}
static void output_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct output_state *os = wl_container_of(listener, os, destroy);
    output_state_destroy(os);
}
static struct output_state *output_state_find(struct rediwm_output_renderer *r, struct wlr_output *output) {
    struct output_state *os;
    wl_list_for_each(os, &r->outputs, link) if (os->output == output) return os;
    return NULL;
}
static struct output_state *output_state_get(struct rediwm_output_renderer *r, struct wlr_output *output) {
    struct output_state *os = output_state_find(r, output);
    if (os) return os;
    os = calloc(1, sizeof(*os));
    if (!os) return NULL;
    os->renderer = r;
    os->output = output;
    wl_list_init(&os->caches);
    os->destroy.notify = output_destroyed;
    wl_signal_add(&output->events.destroy, &os->destroy);
    wl_list_insert(&r->outputs, &os->link);
    return os;
}
void rediwm_output_renderer_destroy(struct rediwm_output_renderer *r) {
    if (!r) return;
    struct output_state *os, *next;
    wl_list_for_each_safe(os, next, &r->outputs, link) output_state_destroy(os);
    rediwm_scene_renderer_destroy(r->pass);
    wl_array_release(&r->entries);
    free(r);
}
struct wlr_render_pass *rediwm_output_begin_pass(struct rediwm_output_renderer *r,
        struct wlr_buffer *buffer, const struct wlr_buffer_pass_options *options) {
    return rediwm_scene_pass_begin(r->pass, buffer, options);
}
bool rediwm_scene_output_set_veil(struct rediwm_output_renderer *r, struct rediwm_scene_output *out, float alpha) {
    alpha = alpha < 0 ? 0 : alpha > 1 ? 1 : alpha;
    struct output_state *os = alpha > 0 ? output_state_get(r, out->output) : output_state_find(r, out->output);
    if (!os) return alpha == 0;
    if (os->veil == alpha) return true;
    os->veil = alpha;
    os->veil_changed = true;
    rediwm_scene_output_damage_whole(out);
    return true;
}
static void sample(struct entry *e, struct rediwm_scene_output *out, bool scanout) {
    if (e->item.kind == REDIWM_ITEM_RECT) return;
    struct rediwm_buffer *b = rediwm_buffer_from_node(e->transport);
    struct rediwm_output_sample_event event = {
        .output = out, .direct_scanout = scanout,
        .release_timeline = scanout ? out->out_timeline : out->in_timeline,
        .release_point = scanout ? out->out_point : out->in_point,
    };
    wl_signal_emit_mutable(&b->events.output_sample, &event);
}
static bool try_scanout(struct entry *e, struct rediwm_scene_output *out,
        struct wlr_output_state *state, const struct output_view *v) {
    if (e->item.clip || e->item.kind != REDIWM_ITEM_SURFACE || !out->outputs->direct_scanout ||
        (state->committed & (WLR_OUTPUT_STATE_MODE | WLR_OUTPUT_STATE_ENABLED | WLR_OUTPUT_STATE_RENDER_FORMAT)) ||
        !wlr_output_is_direct_scanout_allowed(out->output)) return false;
    struct rediwm_buffer *b = rediwm_buffer_from_node(e->transport);
    const struct rediwm_content *c = &e->item.content;
    // Scanout shows the client's buffer as it is: a dimmed window needs the pass.
    if (!b->buffer || c->transform != v->transform || c->opacity != 1 ||
        c->dim_brightness > 0 || c->dim_saturation > 0) return false;
    const struct wlr_output_image_description *desc = state->committed & WLR_OUTPUT_STATE_IMAGE_DESCRIPTION ?
        state->image_description : out->output->image_description;
    if (desc) {
        if (c->transfer_function != desc->transfer_function || c->primaries != desc->primaries) return false;
    } else if (!((c->transfer_function == 0 && c->primaries == 0) ||
        (c->transfer_function == WLR_COLOR_TRANSFER_FUNCTION_GAMMA22 &&
         c->primaries == WLR_COLOR_NAMED_PRIMARIES_SRGB))) return false;
    if (!((c->color_encoding == WLR_COLOR_ENCODING_NONE && c->color_range == WLR_COLOR_RANGE_NONE) ||
        (c->color_encoding == WLR_COLOR_ENCODING_IDENTITY && c->color_range == WLR_COLOR_RANGE_FULL))) return false;
    struct wlr_box dst = device_box(e->box, v);
    // Keep the guaranteed fullscreen case. Partial coverage never bypasses
    // the black/background draw, even if it was the only visible entry.
    if (dst.x != 0 || dst.y != 0 || dst.width != v->width || dst.height != v->height) return false;
    if (pixman_region32_contains_rectangle(&e->opaque, &(pixman_box32_t){
        v->logical.x, v->logical.y, v->logical.x + v->logical.width,
        v->logical.y + v->logical.height}) != PIXMAN_REGION_IN) return false;
    struct wlr_output_state pending;
    wlr_output_state_init(&pending);
    if (!wlr_output_state_copy(&pending, state)) { wlr_output_state_finish(&pending); return false; }
    struct wlr_buffer *buffer = b->buffer;
    struct wlr_client_buffer *client = wlr_client_buffer_get(buffer);
    if (client && client->source && client->source->n_locks > 0) buffer = client->source;
    wlr_output_state_set_buffer(&pending, buffer);
    pending.buffer_src_box = c->src_box;
    pending.buffer_dst_box = dst;
    if (b->wait_timeline)
        wlr_output_state_set_wait_timeline(&pending, b->wait_timeline, b->wait_point);
    if (out->out_timeline)
        wlr_output_state_set_signal_timeline(&pending, out->out_timeline, ++out->out_point);
    bool ok = wlr_output_test_state(out->output, &pending) && wlr_output_state_copy(state, &pending);
    wlr_output_state_finish(&pending);
    if (ok) sample(e, out, true);
    return ok;
}
#ifdef REDIWM_DAMAGE_AUDIT
// Debug audit of the damage (`zig build -Ddamage-audit=true`, TESTING.md): after a
// frame is drawn into the swapchain buffer with only the damage it was given, the
// same entries are drawn whole into a private buffer and the two are compared. A
// difference is a region the damage should have covered; it is logged with the
// entries over it. Reads two frames back every time: slow, and off by default.
static struct { struct wlr_output *output; struct wlr_buffer *buffer; } audit_slots[8];
static bool audit_read(struct wlr_renderer *renderer, struct wlr_buffer *buffer, uint8_t *pixels) {
    struct wlr_texture *texture = wlr_texture_from_buffer(renderer, buffer);
    if (!texture) return false;
    bool ok = wlr_texture_read_pixels(texture, &(struct wlr_texture_read_pixels_options){
        .data = pixels, .format = DRM_FORMAT_ARGB8888, .stride = (uint32_t)buffer->width * 4});
    wlr_texture_destroy(texture);
    return ok;
}
static void audit_damage(struct rediwm_output_renderer *r, struct rediwm_scene_output *out,
        struct wlr_buffer *real, struct entry *entries, size_t len, const struct output_view *v,
        const pixman_region32_t *damage, float veil) {
    struct wlr_output *output = out->output;
    int slot = -1;
    for (int i = 0; i < 8; i++) {
        if (audit_slots[i].output == output) { slot = i; break; }
        if (slot < 0 && !audit_slots[i].output) slot = i;
    }
    if (slot < 0) return;
    if (audit_slots[slot].output != output || (audit_slots[slot].buffer &&
            (audit_slots[slot].buffer->width != real->width || audit_slots[slot].buffer->height != real->height))) {
        if (audit_slots[slot].buffer) wlr_buffer_drop(audit_slots[slot].buffer);
        audit_slots[slot].buffer = NULL;
        audit_slots[slot].output = output;
    }
    if (!audit_slots[slot].buffer)
        audit_slots[slot].buffer = wlr_allocator_create_buffer(output->allocator, real->width, real->height,
            &output->swapchain->format);
    struct wlr_buffer *copy = audit_slots[slot].buffer;
    if (!copy) return;
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r->pass, copy, &(struct wlr_buffer_pass_options){0});
    if (!pass) return;
    pixman_region32_t whole;
    pixman_region32_init_rect(&whole, 0, 0, real->width, real->height);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, real->width, real->height}, .color = {0, 0, 0, 1}, .clip = &whole});
    // Blurs are kept as the real pass left them: this audits damage, not glass.
    for (size_t i = 0; i < len; i++) entries[i].reblur = false;
    for (size_t i = len; i > 0; i--) scene_output_render_entry(r, &entries[i - 1], out, pass, v, &whole, false);
    if (veil > 0) wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, real->width, real->height}, .color = {0, 0, 0, veil}, .clip = &whole});
    wlr_output_add_software_cursors_to_render_pass(output, pass, &whole);
    bool submitted = wlr_render_pass_submit(pass);
    pixman_region32_fini(&whole);
    if (!submitted) return;
    const size_t bytes = (size_t)real->width * real->height * 4;
    uint8_t *a = malloc(bytes), *b = malloc(bytes);
    if (a && b && audit_read(output->renderer, real, a) && audit_read(output->renderer, copy, b)) {
        // GLES2 at a fractional scale can differ by a level or two with render history.
        const int tolerance = floor(v->scale) != v->scale ? 3 : 1;
        long differing = 0, inside = 0;
        int x1 = real->width, y1 = real->height, x2 = 0, y2 = 0, worst = 0;
        for (int y = 0; y < real->height; y++) {
            for (int x = 0; x < real->width; x++) {
                const size_t o = ((size_t)y * real->width + x) * 4;
                int d = 0;
                for (int c = 0; c < 4; c++) { int e = abs((int)a[o + c] - (int)b[o + c]); if (e > d) d = e; }
                if (d <= tolerance) continue;
                differing++;
                if (pixman_region32_contains_point((pixman_region32_t *)damage, x, y, NULL)) inside++;
                if (d > worst) worst = d;
                if (x < x1) x1 = x;
                if (y < y1) y1 = y;
                if (x + 1 > x2) x2 = x + 1;
                if (y + 1 > y2) y2 = y + 1;
            }
        }
        if (differing) {
            const pixman_box32_t *ex = pixman_region32_extents((pixman_region32_t *)damage);
            wlr_log(WLR_ERROR, "damage audit %s: %ld pixels differ (worst %d, %ld inside the damage) in %d,%d-%d,%d; "
                "damage %d,%d-%d,%d", output->name, differing, worst, inside, x1, y1, x2, y2,
                ex->x1, ex->y1, ex->x2, ex->y2);
            const struct wlr_box mine = {x1, y1, x2 - x1, y2 - y1};
            for (size_t i = 0; i < len; i++) {
                struct wlr_box hit;
                if (!wlr_box_intersection(&hit, &entries[i].box, &mine)) continue;
                wlr_log(WLR_ERROR, "damage audit:   entry %zu id %llu kind %d opacity %.3f box %d,%d %dx%d clip %d", i,
                    (unsigned long long)entries[i].item.id, (int)entries[i].item.kind,
                    entries[i].item.content.opacity, entries[i].box.x, entries[i].box.y, entries[i].box.width,
                    entries[i].box.height, entries[i].item.clip != NULL);
            }
        }
    }
    free(a);
    free(b);
}
#endif
bool rediwm_scene_output_build_state(struct rediwm_output_renderer *r,
        struct rediwm_projection *projection, struct rediwm_scene_output *out, struct wlr_output_state *state) {
    if ((state->committed & WLR_OUTPUT_STATE_ENABLED) && !state->enabled) return true;
    struct wlr_output *output = out->output;
    // KMS colour state is applied later by Output.commitFrameState, for either presenter.
    struct output_view v = {.width = output->width, .height = output->height,
        .scale = state->committed & WLR_OUTPUT_STATE_SCALE ? state->scale : output->scale,
        .transform = state->committed & WLR_OUTPUT_STATE_TRANSFORM ? state->transform : output->transform,
        .logical = {.x = out->x, .y = out->y}};
    if (state->committed & WLR_OUTPUT_STATE_MODE) {
        v.width = state->mode_type == WLR_OUTPUT_STATE_MODE_FIXED ? state->mode->width : state->custom_mode.width;
        v.height = state->mode_type == WLR_OUTPUT_STATE_MODE_FIXED ? state->mode->height : state->custom_mode.height;
    }
    v.trans_width = v.width;
    v.trans_height = v.height;
    wlr_output_transform_coords(v.transform, &v.trans_width, &v.trans_height);
    v.logical.width = v.trans_width / v.scale;
    v.logical.height = v.trans_height / v.scale;
    if (v.scale != output->scale || v.transform != output->transform ||
        v.width != output->width || v.height != output->height)
        rediwm_scene_output_damage_whole(out);
    r->projection = projection;
    rediwm_projection_feedback_begin(projection);
    struct collector collector = {.renderer = r, .view = &v};
    struct rediwm_scene_output *other;
    wl_list_for_each(other, &out->outputs->outputs, link) {
        if (other == out || !other->output->enabled || collector.others == 15) continue;
        struct wlr_box *box = &collector.other[collector.others++];
        *box = (struct wlr_box){.x = other->x, .y = other->y};
        wlr_output_effective_resolution(other->output, &box->width, &box->height);
    }
    pixman_region32_init(&collector.covered);
    pixman_region32_init(&collector.reads);
    bool collected = rediwm_projection_for_each_item(projection, true, scene_output_collect, &collector);
    if (collector.has_cover) pixman_region32_fini(&collector.cover);
    pixman_region32_fini(&collector.reads);
    if (!collected) {
        pixman_region32_fini(&collector.covered);
        scene_output_clear_entries(r);
        return false;
    }
    rediwm_projection_feedback_end(projection);
    struct entry *entries = r->entries.data;
    size_t len = r->entries.size / sizeof(*entries);
    // Effects decide before the damage is handed on: a re-blur changes the
    // effect's pixels (reported and kept in the ring for the other buffers) and
    // repaints the whole region it reads (this buffer only).
    pixman_region32_t changed;
    pixman_region32_init(&changed);
    struct output_state *os = r->has_backdrops ? output_state_get(r, output) : NULL;
    struct output_state *veiled = output_state_find(r, output);
    const float veil = veiled ? veiled->veil : 0;
    if (os && !scene_output_decide_effects(r, os, out, &v, &changed)) {
        pixman_region32_fini(&changed);
        pixman_region32_fini(&collector.covered);
        scene_output_clear_entries(r);
        return false;
    }
    if (pixman_region32_not_empty(&changed)) {
        pixman_region32_intersect_rect(&changed, &changed, 0, 0, v.width, v.height);
        wlr_damage_ring_add(&out->damage_ring, &changed);
        pixman_region32_union(&out->pending_commit_damage,
            &out->pending_commit_damage, &changed);
    }
    pixman_region32_fini(&changed);
    wlr_output_state_set_damage(state, &out->pending_commit_damage);
    bool scanout = len == 1 && veil == 0 && try_scanout(&entries[0], out, state, &v);
    if (out->prev_scanout != scanout) {
        out->prev_scanout = scanout;
        wlr_log(WLR_DEBUG, "Direct scan-out %s", scanout ? "enabled" : "disabled");
    }
    bool ok = scanout;
    struct wlr_buffer *buffer = NULL;
    if (scanout) goto done;
    if (!wlr_output_configure_primary_swapchain(output, state, &output->swapchain)) goto done;
    buffer = wlr_swapchain_acquire(output->swapchain);
    if (!buffer) goto done;
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r->pass, buffer,
        &(struct wlr_buffer_pass_options){.signal_timeline = out->in_timeline,
            .signal_point = ++out->in_point});
    if (!pass) goto done;
    pixman_region32_t damage, background;
    pixman_region32_init(&damage);
    pixman_region32_init(&background);
    wlr_damage_ring_rotate_buffer(&out->damage_ring, buffer, &damage);
    pixman_region32_intersect_rect(&damage, &damage, 0, 0, v.width, v.height);
    device_region(&collector.covered, &v, false);
    pixman_region32_subtract(&background, &damage, &collector.covered);
    if (floor(v.scale) != v.scale) {
        wlr_region_expand(&background, &background, 1);
        pixman_region32_intersect(&background, &background, &damage);
    }
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, buffer->width, buffer->height}, .color = {0, 0, 0, 1}, .clip = &background});
    ok = true;
    for (size_t i = len; i > 0; i--)
        if (!scene_output_render_entry(r, &entries[i - 1], out, pass, &v, &damage, false)) ok = false;
    if (veil > 0) wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, buffer->width, buffer->height}, .color = {0, 0, 0, veil}, .clip = &damage});
    wlr_output_add_software_cursors_to_render_pass(output, pass, &damage);
    bool submitted = wlr_render_pass_submit(pass);
    // Successful reads still need release points when another item failed to
    // import. No sample event is sent for a failed GPU submission.
    if (submitted) for (size_t i = 0; i < len; i++) if (entries[i].sampled) sample(&entries[i], out, false);
#ifdef REDIWM_DAMAGE_AUDIT
    if (submitted && ok) audit_damage(r, out, buffer, entries, len, &v, &damage, veil);
#endif
    ok = ok && submitted;
    pixman_region32_fini(&background);
    pixman_region32_fini(&damage);
    if (ok) {
        wlr_output_state_set_buffer(state, buffer);
        if (out->in_timeline) {
            wlr_output_state_set_wait_timeline(state, out->in_timeline, out->in_point);
            wlr_output_state_set_signal_timeline(state, out->out_timeline, ++out->out_point);
        }
    }
done:
    if (buffer) wlr_buffer_unlock(buffer);
    if (!ok) rediwm_scene_output_damage_whole(out);
    pixman_region32_fini(&collector.covered);
    if (ok && veiled) veiled->veil_changed = false;
    if (os) {
        // Outside the pass: drop the blurs of effects this output no longer shows;
        // after a failed frame, trust none of them.
        struct effect_cache *c, *next;
        wl_list_for_each_safe(c, next, &os->caches, link) {
            if (!ok) c->valid = false;
            if (!c->seen) cache_destroy(r, c);
        }
    }
    scene_output_clear_entries(r);
    return ok;
}
