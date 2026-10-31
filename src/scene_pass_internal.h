// Private to scene_pass*.c and scene_pass_test.c: the renderer's programs and GL
// state, the pass, and the per-draw helpers the parts share (`static inline` when
// small, so a file boundary costs them no inlining). Everyone else uses scene_pass.h.
#ifndef REDIWM_SCENE_PASS_INTERNAL_H
#define REDIWM_SCENE_PASS_INTERNAL_H

#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_pass.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>
#include <wlr/render/interface.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/util/log.h>

struct program {
    GLuint id;
    unsigned bit; // which bit of pass.targets_set tracks this program's target size
    GLint target, dst, color, alpha, opaque, sampler, coords;
    // Shaped programs only (-1 elsewhere): the shape, and the shadow's own terms.
    GLint mode, origin, size, radii, npoly, poly, border, bcolor, glow, gcolor, offset, softness, hide, use_shape, dim;
    // What `dim` holds now (a uniform keeps its value between draws and passes).
    float dim_brightness, dim_saturation;
    // The backdrop composite (shaped mode 3) and the blur program.
    GLint bmap, fmap, saturation, front, front_alpha, has_front;
    GLint step_uv, sigma, limits, src_scale;
};
struct rediwm_backdrop {
    GLuint tex, fbo;
    int width, height;     // the reduced size
    int x, y;              // device pixel the image starts at
    float extent_w, extent_h; // device pixels it covers (width * factor)
};
struct attrib_state {
    GLint enabled, size, type, normalized, stride, buffer;
    void *pointer;
};
struct gl_state {
    EGLDisplay display, previous_display;
    EGLContext context;
    EGLSurface draw, read;
    GLint fbo, program, array_buffer, vertex_array, active_texture, texture, external;
    GLint viewport[4], scissor_box[4];
    GLint src_rgb, dst_rgb, src_alpha, dst_alpha, equation_rgb, equation_alpha;
    GLboolean blend, scissor;
    struct attrib_state attrib;
};
struct rediwm_scene_renderer {
    struct wlr_renderer *renderer;
    // Rounded-rectangle shapes (stage 4b), built with the renderer: one program for
    // a 2D texture, a solid colour and the shape's shadow (they differ in a mode
    // uniform, which every fragment of a draw reads the same). The one for external
    // textures is built by enable_external.
    struct program shaped, shaped_external;
    bool external_tried, external_ok;
    // The same, with the polygon distance compiled in (POLY), built on demand by
    // enable_polygons the first time a theme gives a window or the bar an outline.
    // Draws of a polygon shape use these; every other draw the programs above,
    // which are what they were before polygons.
    struct program shaped_poly, shaped_poly_external;
    bool polys_tried, has_polys;
    // Backdrops (stage 5b), built by enable_backdrops: the blur, and scratch the
    // size of the largest region so far: the copy, and the horizontal pass.
    struct program blur;
    GLuint prefix_tex, prefix_fbo, small_tex, small_fbo;
    int small_w, small_h;
    bool has_backdrops, backdrops_tried;
    bool active, has_external, has_sync, has_vao, has_shapes, shapes_tried;
    GLuint vertex_array, vertices;
    PFNGLGENVERTEXARRAYSOESPROC gen_vertex_arrays;
    PFNGLBINDVERTEXARRAYOESPROC bind_vertex_array;
    PFNGLDELETEVERTEXARRAYSOESPROC delete_vertex_arrays;
    PFNEGLCREATESYNCKHRPROC create_sync;
    PFNEGLDESTROYSYNCKHRPROC destroy_sync;
    PFNEGLWAITSYNCKHRPROC wait_sync;
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC dup_fence;
};
struct pass {
    struct wlr_render_pass base;
    struct rediwm_scene_renderer *renderer;
    struct wlr_buffer *buffer;
    struct gl_state state;
    struct wlr_drm_syncobj_timeline *signal_timeline;
    uint64_t signal_point;
    bool failed;
    GLuint program;
    unsigned targets_set;
    int blend_mode;
    float dim_brightness, dim_saturation; // rediwm_scene_pass_set_dim
    // Between begin_backdrop and end_backdrop draws land in a quarter-size image
    // of `region` (stage 5f): boxes move by its origin, scissors shrink by four.
    bool redirected;
    struct wlr_box region, valid; // device pixels; `valid` is the part in the buffer
    float factor;                 // device pixels per pixel of the image
    int small_w, small_h;
};

// The unit quad every draw is made of.
static const GLfloat positions[] = {0, 0, 1, 0, 0, 1, 1, 1};

// The program a draw of `shape` (NULL: none) uses: the polygon variant for an outline.
static inline struct program *shaped_for(struct rediwm_scene_renderer *r,
        const struct rediwm_pass_shape *shape, bool external) {
    const bool poly = shape && shape->poly_count > 0;
    if (external) return poly ? &r->shaped_poly_external : &r->shaped_external;
    return poly ? &r->shaped_poly : &r->shaped;
}
// The shape's uniforms. A degenerate or non-finite shape is the caller's bug;
// it fails the pass at submit like any other bad draw.
static inline bool shape_usable(const struct rediwm_pass_shape *s) {
    if (!isfinite(s->border) || s->border < 0) return false;
    for (int i = 0; i < 4; i++) if (!isfinite(s->radii[i]) || s->radii[i] < 0) return false;
    if (s->poly_count < 0 || s->poly_count == 1 || s->poly_count == 2 || s->poly_count > REDIWM_PASS_POLY_MAX) return false;
    for (int i = 0; i < s->poly_count; i++) {
        const float *a = s->poly[i], *b = s->poly[i + 1 < s->poly_count ? i + 1 : 0];
        if (!isfinite(a[0]) || !isfinite(a[1]) || (a[0] == b[0] && a[1] == b[1])) return false;
    }
    for (int i = 0; i < 4; i++) if (!isfinite(s->border_color[i]) || !isfinite(s->glow_color[i])) return false;
    return isfinite(s->glow_radius) && isfinite(s->glow_depth) && s->glow_radius >= 0 && s->glow_depth >= 0 &&
        isfinite(s->glow_center[0]) && isfinite(s->glow_center[1]);
}
// The pass's dim for a draw of `g`. The uniform keeps its value, so it is set only
// when this program last held something else (a program starts at 0, as a pass does).
static inline void apply_dim(struct pass *p, struct program *g) {
    if (g->dim_brightness == p->dim_brightness && g->dim_saturation == p->dim_saturation) return;
    glUniform2f(g->dim, p->dim_brightness, p->dim_saturation);
    g->dim_brightness = p->dim_brightness;
    g->dim_saturation = p->dim_saturation;
}
extern const struct wlr_render_pass_impl scene_pass_impl;
// Only a pass from rediwm_scene_pass_begin carries these: handing in a wlroots
// pass is a programming error, not something to degrade around.
static inline struct pass *owned_pass(struct wlr_render_pass *base) {
    assert(base->impl == &scene_pass_impl);
    struct pass *p = wl_container_of(base, p, base);
    return p;
}

// Shared between the parts (scene_pass_*.c).
// Makes the renderer's EGL context current, saving the caller's context and GL
// state in `s`.
bool scene_pass_enter(struct rediwm_scene_renderer *r, struct gl_state *s);
// Restores what scene_pass_enter saved.
void scene_pass_leave(struct rediwm_scene_renderer *r, struct gl_state *s);
// Uses `program` for a draw of `box` (device pixels) with `blend`; scene_pass_draw
// then draws the quad, scissored to `clip` (NULL: all of it).
void scene_pass_setup(struct pass *p, struct program *program, struct wlr_box box,
        enum wlr_render_blend_mode blend);
void scene_pass_draw(const struct pass *p, const pixman_region32_t *clip);
void scene_pass_set_shape(const struct pass *p, const struct program *g, const struct rediwm_pass_shape *s);

#endif
