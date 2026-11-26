// ---- Backdrops (stage 5b) -------------------------------------------------------
// Part of scene_pass.c.
#include "scene_pass_internal.h"

// 8-bit, or the renderer's FP16 format for a linear pass.
static void texture_storage(struct rediwm_scene_renderer *r, GLuint tex, bool linear, int w, int h) {
    glBindTexture(GL_TEXTURE_2D, tex);
    if (linear) glTexImage2D(GL_TEXTURE_2D, 0, r->half_internal, w, h, 0, GL_RGBA, r->half_type, NULL);
    else glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}
static bool attach(GLuint fbo, GLuint tex) {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}
// Two quarter-size scratch images shared by every effect, grown to the largest
// so far: what lies below the effect, and the horizontal blur pass. Linear
// passes have their own FP16 pair.
struct scratch { GLuint *prefix_tex, *prefix_fbo, *small_tex, *small_fbo; int *w, *h; };
static struct scratch scratch_of(struct rediwm_scene_renderer *r, bool linear) {
    if (linear) return (struct scratch){&r->lin_prefix_tex, &r->lin_prefix_fbo, &r->lin_small_tex,
        &r->lin_small_fbo, &r->lin_small_w, &r->lin_small_h};
    return (struct scratch){&r->prefix_tex, &r->prefix_fbo, &r->small_tex, &r->small_fbo, &r->small_w, &r->small_h};
}
static bool scratch(struct rediwm_scene_renderer *r, bool linear, int small_w, int small_h) {
    const struct scratch s = scratch_of(r, linear);
    if (!*s.prefix_tex) glGenTextures(1, s.prefix_tex);
    if (!*s.prefix_fbo) glGenFramebuffers(1, s.prefix_fbo);
    if (!*s.small_tex) glGenTextures(1, s.small_tex);
    if (!*s.small_fbo) glGenFramebuffers(1, s.small_fbo);
    if (small_w > *s.w || small_h > *s.h) {
        *s.w = small_w > *s.w ? small_w : *s.w;
        *s.h = small_h > *s.h ? small_h : *s.h;
        texture_storage(r, *s.prefix_tex, linear, *s.w, *s.h);
        texture_storage(r, *s.small_tex, linear, *s.w, *s.h);
        if (!attach(*s.prefix_fbo, *s.prefix_tex) || !attach(*s.small_fbo, *s.small_tex)) return false;
    }
    return true;
}
void rediwm_scene_renderer_destroy_backdrop(struct rediwm_scene_renderer *r, struct rediwm_backdrop *b) {
    if (!b) return;
    assert(!r->active);
    struct gl_state state;
    if (scene_pass_enter(r, &state)) {
        glDeleteTextures(1, &b->tex);
        glDeleteFramebuffers(1, &b->fbo);
        scene_pass_leave(r, &state);
    }
    free(b);
}
void rediwm_scene_pass_begin_backdrop(struct wlr_render_pass *base, struct wlr_box region, float factor) {
    struct pass *p = owned_pass(base);
    struct rediwm_scene_renderer *r = p->renderer;
    if (p->failed) return;
    if (!r->has_backdrops || p->redirected || region.width <= 0 || region.height <= 0 ||
            region.width > 16384 || region.height > 16384 || !isfinite(factor) || factor < 1 || factor > 64) {
        p->failed = true;
        return;
    }
    // Whole pixels of the image: it covers a little more than the region.
    const int small_w = (int)ceilf(region.width / factor), small_h = (int)ceilf(region.height / factor);
    const bool linear = p->linear != NULL;
    if (!scratch(r, linear, small_w, small_h)) { p->failed = true; return; }
    p->factor = factor;
    p->small_w = small_w;
    p->small_h = small_h;
    struct wlr_box buffer = {0, 0, p->buffer->width, p->buffer->height};
    if (!wlr_box_intersection(&p->valid, &region, &buffer)) { p->failed = true; return; }
    p->region = region;
    p->redirected = true;
    p->targets_set = 0;
    glBindFramebuffer(GL_FRAMEBUFFER, *scratch_of(r, linear).prefix_fbo);
    glViewport(0, 0, small_w, small_h);
    // Black where nothing is drawn, as the output is; the blur never reads
    // outside the buffer (see end_backdrop).
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}
void rediwm_scene_pass_end_backdrop(struct wlr_render_pass *base, struct rediwm_backdrop **out, float sigma) {
    struct pass *p = owned_pass(base);
    struct rediwm_scene_renderer *r = p->renderer;
    if (!p->redirected) { p->failed = true; return; }
    p->redirected = false;
    p->targets_set = 0;
    p->program = 0;
    p->blend_mode = -1;
    const GLuint target_fbo = pass_fbo(p);
    const bool linear = p->linear != NULL;
    const struct scratch s = scratch_of(r, linear);
    if (p->failed || !isfinite(sigma) || sigma <= 0 || sigma > 1024) {
        p->failed = true;
        glBindFramebuffer(GL_FRAMEBUFFER, target_fbo);
        glViewport(0, 0, p->buffer->width, p->buffer->height);
        return;
    }
    struct rediwm_backdrop *b = *out;
    if (!b) {
        b = calloc(1, sizeof(*b));
        if (!b) { p->failed = true; return; }
        glGenTextures(1, &b->tex);
        glGenFramebuffers(1, &b->fbo);
        *out = b;
    }
    const int small_w = p->small_w, small_h = p->small_h;
    if (b->width != small_w || b->height != small_h || b->linear != linear) {
        texture_storage(r, b->tex, linear, small_w, small_h);
        if (!attach(b->fbo, b->tex)) { p->failed = true; return; }
        b->width = small_w;
        b->height = small_h;
        b->linear = linear;
    }
    b->x = p->region.x;
    b->y = p->region.y;
    b->extent_w = small_w * p->factor;
    b->extent_h = small_h * p->factor;
    // Separable blur: horizontal into scratch, vertical into the backdrop. Only
    // what lies in the buffer is read: beyond it the edge is replicated.
    struct program *g = &r->blur;
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glActiveTexture(GL_TEXTURE0);
    glUseProgram(g->id);
    glUniform1i(g->sampler, 0);
    const float aw = *s.w, ah = *s.h;
    const float vx1 = (p->valid.x - p->region.x) / p->factor, vy1 = (p->valid.y - p->region.y) / p->factor;
    const float vx2 = fminf(small_w, (p->valid.x + p->valid.width - p->region.x) / p->factor);
    const float vy2 = fminf(small_h, (p->valid.y + p->valid.height - p->region.y) / p->factor);
    glUniform2f(g->src_scale, small_w / aw, small_h / ah);
    glUniform1f(g->sigma, sigma / p->factor);
    glBindFramebuffer(GL_FRAMEBUFFER, *s.small_fbo);
    glViewport(0, 0, small_w, small_h);
    glBindTexture(GL_TEXTURE_2D, *s.prefix_tex);
    glUniform2f(g->step_uv, 1.f / aw, 0);
    glUniform4f(g->limits, (vx1 + .5f) / aw, (vy1 + .5f) / ah, (vx2 - .5f) / aw, (vy2 - .5f) / ah);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindFramebuffer(GL_FRAMEBUFFER, b->fbo);
    glBindTexture(GL_TEXTURE_2D, *s.small_tex);
    glUniform2f(g->step_uv, 0, 1.f / ah);
    glUniform4f(g->limits, .5f / aw, (vy1 + .5f) / ah, (small_w - .5f) / aw, (vy2 - .5f) / ah);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindFramebuffer(GL_FRAMEBUFFER, target_fbo);
    glViewport(0, 0, p->buffer->width, p->buffer->height);
}
void rediwm_scene_pass_add_backdrop(struct wlr_render_pass *base, const struct rediwm_pass_shape *shape,
        struct wlr_box box, const struct rediwm_pass_backdrop *o) {
    struct pass *p = owned_pass(base);
    struct program *g = shaped_for(p->renderer, shape, false, p->linear != NULL);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    const struct rediwm_backdrop *b = o->backdrop;
    // A blur holds the encoding of the pass that took it.
    if (!g->id || !shape_usable(shape) || !b || !b->width || b->linear != (p->linear != NULL) || !isfinite(o->saturation) ||
            !isfinite(o->opacity) || !isfinite(o->front_opacity)) {
        p->failed = true;
        return;
    }
    struct wlr_gles2_texture_attribs front = {0};
    if (o->front) {
        if (!wlr_texture_is_gles2(o->front) || o->front_box.width <= 0 || o->front_box.height <= 0) {
            p->failed = true;
            return;
        }
        wlr_gles2_texture_get_attribs(o->front, &front);
    }
    const bool has_front = o->front && front.target == GL_TEXTURE_2D;
    scene_pass_setup(p, g, box, WLR_RENDER_BLEND_MODE_PREMULTIPLIED);
    struct rediwm_pass_shape bare = *shape; // the ring belongs to the surface over it
    bare.border = 0;
    scene_pass_set_shape(p, g, &bare);
    glUniform1f(g->mode, 3.f);
    glUniform1f(g->alpha, o->opacity);
    glUniform1f(g->saturation, o->saturation);
    glUniform4f(g->bmap, shape->box.x - b->x, shape->box.y - b->y, 1.f / b->extent_w, 1.f / b->extent_h);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, has_front ? front.tex : 0);
    if (has_front) {
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    glUniform1f(g->has_front, has_front ? 1.f : 0.f);
    glUniform1f(g->front_alpha, o->front_opacity);
    glUniform4f(g->fmap, shape->box.x - o->front_box.x, shape->box.y - o->front_box.y,
        has_front ? 1.f / o->front_box.width : 0, has_front ? 1.f / o->front_box.height : 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, b->tex);
    glUniform1i(g->sampler, 0);
    apply_dim(p, g);
    scene_pass_draw(p, o->clip);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
}
