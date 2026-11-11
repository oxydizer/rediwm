// The owned pass and its draws: rects, textures, shapes, shadows and the dim.
// Part of scene_pass.c.
#include "scene_pass_internal.h"

void scene_pass_setup(struct pass *p, struct program *program, struct wlr_box box,
        enum wlr_render_blend_mode blend) {
    if (p->program != program->id) {
        glUseProgram(program->id);
        p->program = program->id;
    }
    if (!(p->targets_set & program->bit)) {
        if (p->redirected) glUniform2f(program->target, p->small_w * p->factor, p->small_h * p->factor);
        else glUniform2f(program->target, p->buffer->width, p->buffer->height);
        p->targets_set |= program->bit;
    }
    if (p->redirected) {
        box.x -= p->region.x;
        box.y -= p->region.y;
    }
    glUniform4f(program->dst, box.x, box.y, box.width, box.height);
    if (p->blend_mode != (int)blend) {
        (blend == WLR_RENDER_BLEND_MODE_NONE ? glDisable : glEnable)(GL_BLEND);
        p->blend_mode = blend;
    }
}
void scene_pass_draw(const struct pass *p, const pixman_region32_t *clip) {
    if (!clip) {
        glDisable(GL_SCISSOR_TEST);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        return;
    }
    int n;
    const pixman_box32_t *boxes = pixman_region32_rectangles((pixman_region32_t *)clip, &n);
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < n; i++) {
        if (p->redirected) {
            // Outward to whole small pixels; the region's origin is a multiple of none.
            const int x1 = (int)floorf((boxes[i].x1 - p->region.x) / p->factor);
            const int y1 = (int)floorf((boxes[i].y1 - p->region.y) / p->factor);
            const int x2 = (int)ceilf((boxes[i].x2 - p->region.x) / p->factor);
            const int y2 = (int)ceilf((boxes[i].y2 - p->region.y) / p->factor);
            glScissor(x1, y1, x2 - x1, y2 - y1);
        } else {
            glScissor(boxes[i].x1, boxes[i].y1, boxes[i].x2 - boxes[i].x1, boxes[i].y2 - boxes[i].y1);
        }
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
}
void scene_pass_set_shape(const struct pass *p, const struct program *g, const struct rediwm_pass_shape *s) {
    glUniform1f(g->use_shape, 1.f);
    if (p->redirected) glUniform2f(g->origin, s->box.x - p->region.x, s->box.y - p->region.y);
    else glUniform2f(g->origin, s->box.x, s->box.y);
    glUniform2f(g->size, s->box.width, s->box.height);
    glUniform4f(g->radii, s->radii[0], s->radii[1], s->radii[2], s->radii[3]);
    const bool sector = s->sector.radii[1] > 0;
    if (g->sector_map >= 0) glUniform2f(g->sector_map, s->sector_texture_height, s->sector_texture_flip);
    if (g->sector_rect >= 0) glUniform4fv(g->sector_rect, 1, s->sector_texture_rect);
    if (g->npoly >= 0) glUniform1f(g->npoly, sector ? -1.f : (float)s->poly_count);
    if (sector && g->poly >= 0) {
        const float payload[4][2] = {
            {s->sector.center[0], s->sector.center[1]},
            {s->sector.radii[0], s->sector.radii[1]},
            {s->sector.axis[0], s->sector.axis[1]},
            {s->sector.half_angle[0], s->sector.half_angle[1]},
        };
        glUniform2fv(g->poly, 4, &payload[0][0]);
    } else if (s->poly_count && g->poly >= 0) {
        // The walk closes the outline on a copy of the first vertex.
        float v[REDIWM_PASS_POLY_MAX + 1][2];
        memcpy(v, s->poly, sizeof(float) * 2 * s->poly_count);
        v[s->poly_count][0] = v[0][0];
        v[s->poly_count][1] = v[0][1];
        glUniform2fv(g->poly, s->poly_count + 1, &v[0][0]);
    }
    glUniform1f(g->border, s->border);
    glUniform4f(g->bcolor, s->border_color[0], s->border_color[1], s->border_color[2],
        s->border_color[3]);
    glUniform4f(g->glow, s->glow_center[0], s->glow_center[1], s->glow_radius, s->glow_depth);
    glUniform4f(g->gcolor, s->glow_color[0], s->glow_color[1], s->glow_color[2], s->glow_color[3]);
}
static void add_rect(struct wlr_render_pass *base, const struct wlr_render_rect_options *o) {
    struct pass *p = wl_container_of(base, p, base);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    struct wlr_box box;
    wlr_render_rect_options_get_box(o, p->buffer, &box);
    struct program *g = &p->renderer->shaped;
    scene_pass_setup(p, g, box, o->blend_mode);
    glUniform4f(g->color, o->color.r, o->color.g, o->color.b, o->color.a);
    glUniform1f(g->mode, 1.f);
    glUniform1f(g->use_shape, 0.f);
    apply_dim(p, g);
    scene_pass_draw(p, o->clip);
}
static void rect_shaped(struct pass *p, const struct wlr_render_rect_options *o,
        const struct rediwm_pass_shape *shape) {
    struct program *g = shaped_for(p->renderer, shape, false);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    if (!g->id || !shape_usable(shape)) { p->failed = true; return; }
    struct wlr_box box;
    wlr_render_rect_options_get_box(o, p->buffer, &box);
    scene_pass_setup(p, g, box, o->blend_mode);
    glUniform4f(g->color, o->color.r, o->color.g, o->color.b, o->color.a);
    glUniform1f(g->mode, 1.f);
    scene_pass_set_shape(p, g, shape);
    apply_dim(p, g);
    scene_pass_draw(p, o->clip);
}
static bool wait_point(struct pass *p, struct wlr_drm_syncobj_timeline *timeline, uint64_t point) {
    if (!timeline) return true;
    struct rediwm_scene_renderer *r = p->renderer;
    if (!r->has_sync) return false;
    int fd = wlr_drm_syncobj_timeline_export_sync_file(timeline, point);
    if (fd < 0) return false;
    EGLint attrs[] = {EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fd, EGL_NONE};
    EGLSyncKHR sync = r->create_sync(p->state.display, EGL_SYNC_NATIVE_FENCE_ANDROID, attrs);
    if (sync == EGL_NO_SYNC_KHR) { close(fd); return false; }
    // EGL owns the fd after a successful import. GPU wait, never a CPU poll.
    bool ok = r->wait_sync(p->state.display, sync, 0) == EGL_TRUE;
    r->destroy_sync(p->state.display, sync);
    return ok;
}
static void texture_draw(struct pass *p, const struct wlr_render_texture_options *o,
        struct wlr_gles2_texture_attribs a, const struct rediwm_pass_shape *shape) {
    struct rediwm_scene_renderer *r = p->renderer;
    struct program *program = a.target == GL_TEXTURE_2D ? shaped_for(r, shape, false) :
        a.target == GL_TEXTURE_EXTERNAL_OES ? shaped_for(r, shape, true) : NULL;
    if (!program || !program->id || (shape && !shape_usable(shape))) { p->failed = true; return; }
    struct wlr_box dst;
    struct wlr_fbox src;
    wlr_render_texture_options_get_dst_box(o, &dst);
    wlr_render_texture_options_get_src_box(o, &src);
    scene_pass_setup(p, program, dst, o->blend_mode);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(a.target, a.tex);
    GLint filter = o->filter_mode == WLR_SCALE_FILTER_NEAREST ? GL_NEAREST : GL_LINEAR;
    glTexParameteri(a.target, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(a.target, GL_TEXTURE_MAG_FILTER, filter);
    glUniform1i(program->sampler, 0);
    glUniform1f(program->alpha, wlr_render_texture_options_get_alpha(o));
    glUniform1f(program->opaque, !a.has_alpha);
    GLfloat uv[8];
    const bool polar = shape && shape->sector_texture_height > 0;
    // Sector coordinates already follow the output's rotation/reflection.
    // Remove that part from the source transform before applying its UV crop.
    const enum wl_output_transform source_transform = polar ?
        wlr_output_transform_compose(o->transform,
            wlr_output_transform_invert(shape->sector_texture_transform)) : o->transform;
    for (int i = 0; i < 4; i++) {
        double x = positions[2 * i], y = positions[2 * i + 1], u, v;
        // Map destination corners back to the untransformed source rectangle.
        switch (source_transform) {
        case WL_OUTPUT_TRANSFORM_NORMAL: u = x; v = y; break;
        case WL_OUTPUT_TRANSFORM_90: u = 1 - y; v = x; break;
        case WL_OUTPUT_TRANSFORM_180: u = 1 - x; v = 1 - y; break;
        case WL_OUTPUT_TRANSFORM_270: u = y; v = 1 - x; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED: u = 1 - x; v = y; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED_90: u = y; v = x; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED_180: u = x; v = 1 - y; break;
        case WL_OUTPUT_TRANSFORM_FLIPPED_270: u = 1 - y; v = 1 - x; break;
        default: p->failed = true; return;
        }
        uv[2 * i] = (src.x + u * src.width) / o->texture->width;
        uv[2 * i + 1] = (src.y + v * src.height) / o->texture->height;
    }
    glUniform4fv(program->coords, 2, uv);
    if (polar && program->sector_coords >= 0) glUniform4fv(program->sector_coords, 2, uv);
    glUniform1f(program->mode, 0.f);
    if (shape) scene_pass_set_shape(p, program, shape);
    else glUniform1f(program->use_shape, 0.f);
    apply_dim(p, program);
    scene_pass_draw(p, o->clip);
}
static void texture_add(struct wlr_render_pass *base, const struct wlr_render_texture_options *o,
        const struct rediwm_pass_shape *shape) {
    struct pass *p = wl_container_of(base, p, base);
    if (p->failed || (o->clip && !pixman_region32_not_empty(o->clip))) return;
    if (!wlr_texture_is_gles2(o->texture) || o->texture->renderer != p->renderer->renderer ||
            !wait_point(p, o->wait_timeline, o->wait_point)) {
        p->failed = true;
        return;
    }
    struct wlr_gles2_texture_attribs a;
    wlr_gles2_texture_get_attribs(o->texture, &a);
    texture_draw(p, o, a, shape);
}
static void add_texture(struct wlr_render_pass *base, const struct wlr_render_texture_options *o) {
    texture_add(base, o, NULL);
}
static bool submit(struct wlr_render_pass *base) {
    struct pass *p = wl_container_of(base, p, base);
    struct rediwm_scene_renderer *r = p->renderer;
    bool ok = !p->failed;
    if (p->signal_timeline) {
        EGLSyncKHR sync = r->create_sync(p->state.display, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
        if (sync == EGL_NO_SYNC_KHR) {
            ok = false;
        } else {
            glFlush();
            int fd = r->dup_fence(p->state.display, sync);
            r->destroy_sync(p->state.display, sync);
            if (fd < 0) ok = false;
            else {
                ok = wlr_drm_syncobj_timeline_import_sync_file(p->signal_timeline, p->signal_point, fd) && ok;
                close(fd);
            }
        }
        wlr_drm_syncobj_timeline_unref(p->signal_timeline);
    } else {
        glFlush();
    }
    // Failed submissions must not leave untracked reads in flight: callers
    // register release points only after success (see explicit_sync.c).
    if (!ok) glFinish();
    scene_pass_leave(r, &p->state);
    wlr_buffer_unlock(p->buffer);
    r->active = false;
    free(p);
    return ok;
}
const struct wlr_render_pass_impl scene_pass_impl = {
    .submit = submit, .add_rect = add_rect, .add_texture = add_texture,
};
struct wlr_render_pass *rediwm_scene_pass_begin(struct rediwm_scene_renderer *r,
        struct wlr_buffer *buffer, const struct wlr_buffer_pass_options *options) {
    if (r->active || (options && (options->timer || options->color_transform ||
            (options->signal_timeline && !r->has_sync)))) return NULL;
    struct pass *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (!scene_pass_enter(r, &p->state)) { free(p); return NULL; }
    GLuint fbo = wlr_gles2_renderer_get_buffer_fbo(r->renderer, buffer);
    if (!fbo) { scene_pass_leave(r, &p->state); free(p); return NULL; }
    p->renderer = r;
    p->buffer = wlr_buffer_lock(buffer);
    if (options && options->signal_timeline) {
        p->signal_timeline = wlr_drm_syncobj_timeline_ref(options->signal_timeline);
        p->signal_point = options->signal_point;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, buffer->width, buffer->height);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    p->blend_mode = -1;
    if (r->has_vao) {
        r->bind_vertex_array(r->vertex_array);
    } else {
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, positions);
        glEnableVertexAttribArray(0);
    }
    r->active = true;
    wlr_render_pass_init(&p->base, &scene_pass_impl);
    return &p->base;
}

void rediwm_scene_pass_add_rect_shaped(struct wlr_render_pass *base,
        const struct wlr_render_rect_options *o, const struct rediwm_pass_shape *shape) {
    rect_shaped(owned_pass(base), o, shape);
}
void rediwm_scene_pass_add_texture_shaped(struct wlr_render_pass *base,
        const struct wlr_render_texture_options *o, const struct rediwm_pass_shape *shape) {
    owned_pass(base);
    texture_add(base, o, shape);
}
void rediwm_scene_pass_add_shadow(struct wlr_render_pass *base,
        const struct rediwm_pass_shape *shape, const struct rediwm_pass_shadow *shadow) {
    struct pass *p = owned_pass(base);
    struct program *g = shaped_for(p->renderer, shape, false);
    if (p->failed || (shadow->clip && !pixman_region32_not_empty(shadow->clip))) return;
    if (!g->id || !shape_usable(shape) || !isfinite(shadow->offset_x) ||
            !isfinite(shadow->offset_y) || !isfinite(shadow->softness) || shadow->softness > 4096 ||
            fabsf(shadow->offset_x) > 65536 || fabsf(shadow->offset_y) > 65536) {
        p->failed = true;
        return;
    }
    // A quarter pixel is a hard edge; zero would divide by it.
    const float softness = shadow->softness < .25f ? .25f : shadow->softness;
    // The quad reaches the softness past the shape, and as far again as the offset.
    const int pad = (int)ceilf(softness) + (int)ceilf(fmaxf(fabsf(shadow->offset_x), fabsf(shadow->offset_y)));
    const struct wlr_box box = {shape->box.x - pad, shape->box.y - pad,
        shape->box.width + 2 * pad, shape->box.height + 2 * pad};
    scene_pass_setup(p, g, box, WLR_RENDER_BLEND_MODE_PREMULTIPLIED);
    glUniform4f(g->color, shadow->color[0], shadow->color[1], shadow->color[2], shadow->color[3]);
    struct rediwm_pass_shape bare = *shape; // the shadow has no border of its own
    bare.border = 0;
    scene_pass_set_shape(p, g, &bare);
    glUniform1f(g->mode, 2.f);
    glUniform2f(g->offset, shadow->offset_x, shadow->offset_y);
    glUniform1f(g->softness, softness);
    glUniform1f(g->hide, shadow->hide_inside ? 1.f : 0.f);
    scene_pass_draw(p, shadow->clip);
}

void rediwm_scene_pass_set_dim(struct wlr_render_pass *base, float brightness, float saturation) {
    struct pass *p = owned_pass(base);
    if (!(brightness >= 0 && brightness <= 1 && saturation >= 0 && saturation <= 1)) {
        p->failed = true;
        return;
    }
    p->dim_brightness = brightness;
    p->dim_saturation = saturation;
}
