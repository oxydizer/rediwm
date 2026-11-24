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
#include <string.h>
#include <unistd.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>
#include <wlr/render/interface.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/util/log.h>
#include <wlr/util/transform.h>

struct program {
    GLuint id;
    unsigned bit; // which bit of pass.targets_set tracks this program's target size
    GLint target, dst, color, alpha, opaque, sampler, coords;
    // Shaped programs only (-1 elsewhere): the shape, and the shadow's own terms.
    GLint mode, origin, size, radii, npoly, poly, border, bcolor, glow, gcolor, offset, softness, hide, use_shape, dim;
    GLint sector_map, sector_coords, sector_rect;
    // What `dim` holds now (a uniform keeps its value between draws and passes).
    float dim_brightness, dim_saturation;
    // The backdrop composite (shaped mode 3) and the blur program.
    GLint bmap, fmap, saturation, front, front_alpha, has_front;
    GLint step_uv, sigma, limits, src_scale;
};
struct rediwm_backdrop {
    GLuint tex, fbo;
    int width, height;     // the reduced size
    bool linear;           // FP16 linear light (a linear pass), else 8-bit as drawn
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
    struct program blur, ribbon;
    GLuint ribbon_vertices;
    GLint ribbon_fade;
    GLuint prefix_tex, prefix_fbo, small_tex, small_fbo;
    int small_w, small_h;
    bool has_backdrops, backdrops_tried;
    // Phase 2 of docs/plans/hdr.md, built by enable_linear the first time an
    // output blends in linear light and never otherwise: the shaped programs
    // with LINEAR defined (every input decoded to linear BT.2020, 1.0 = SDR
    // white), the ribbon likewise, the encode from the FP16 target into the
    // output's buffer, and FP16 scratch for glass. A base program built later
    // (external, polygons, ribbons) gets its linear twin then.
    struct program lin, lin_external, lin_poly, lin_poly_external, ribbon_lin, encode;
    GLint ribbon_lin_fade, encode_white, encode_adjust;
    GLuint lin_prefix_tex, lin_prefix_fbo, lin_small_tex, lin_small_fbo;
    int lin_small_w, lin_small_h;
    GLint half_internal;   // the FP16 texture format that renders here
    GLenum half_type;
    bool has_linear, linear_tried;
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
    // A linear pass (rediwm_scene_pass_begin_linear) draws into this FP16 image
    // of the buffer and reaches the buffer only through rediwm_scene_pass_encode,
    // after which nothing more may be drawn.
    struct rediwm_linear_target *linear;
    bool encoded;
};
struct rediwm_linear_target {
    GLuint tex, fbo;
    int width, height;
};

// The unit quad every draw is made of.
static const GLfloat positions[] = {0, 0, 1, 0, 0, 1, 1, 1};

// The program a draw of `shape` (NULL: none) uses: the polygon variant for an
// outline, the linear one in a linear pass.
static inline struct program *shaped_for(struct rediwm_scene_renderer *r,
        const struct rediwm_pass_shape *shape, bool external, bool linear) {
    const bool poly = shape && (shape->poly_count > 0 || shape->sector.radii[1] > 0);
    if (linear) {
        if (external) return poly ? &r->lin_poly_external : &r->lin_external;
        return poly ? &r->lin_poly : &r->lin;
    }
    if (external) return poly ? &r->shaped_poly_external : &r->shaped_external;
    return poly ? &r->shaped_poly : &r->shaped;
}
// What the pass draws into: its FP16 image when linear, else the buffer.
static inline GLuint pass_fbo(const struct pass *p) {
    return p->linear ? p->linear->fbo : wlr_gles2_renderer_get_buffer_fbo(p->renderer->renderer, p->buffer);
}
// GLSL shared by the linear programs: an sRGB colour as the display shows it
// (gamma 2.2, as node_surface.c describes sRGB surfaces), premultiplied, to
// linear BT.2020 with 1.0 at SDR white, still premultiplied. Its inverse is
// the encode (scene_pass_linear.c).
#define GLSL_BT709_TO_BT2020 "mat3(.627404,.069097,.016391,.329283,.919540,.088013,.043313,.011362,.895595)"
#define GLSL_LIN \
    "vec4 lin(vec4 c){ if(c.a<=0.) return vec4(0.);" \
    "vec3 s=pow(clamp(c.rgb/c.a,0.,1.),vec3(2.2));" \
    "return vec4(" GLSL_BT709_TO_BT2020 "*s*c.a,c.a); }"
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
    const struct rediwm_pass_sector *a = &s->sector;
    for (int i = 0; i < 2; i++) {
        if (!isfinite(a->center[i]) || !isfinite(a->radii[i]) ||
            !isfinite(a->axis[i]) || !isfinite(a->half_angle[i])) return false;
    }
    if (a->radii[1] < 0) return false;
    if (a->radii[1] > 0 && (s->poly_count || a->radii[0] < 0 || a->radii[0] >= a->radii[1] ||
        fabsf(a->axis[0] * a->axis[0] + a->axis[1] * a->axis[1] - 1.f) > 1e-4f ||
        a->half_angle[0] < 0 || a->half_angle[1] <= 0 ||
        fabsf(a->half_angle[0] * a->half_angle[0] + a->half_angle[1] * a->half_angle[1] - 1.f) > 1e-4f)) return false;
    if (!isfinite(s->sector_texture_height) || s->sector_texture_height < 0) return false;
    if (s->sector_texture_height > 0 && (a->radii[1] <= 0 ||
        (s->sector_texture_flip != 1 && s->sector_texture_flip != -1) ||
        s->sector_texture_transform < WL_OUTPUT_TRANSFORM_NORMAL ||
        s->sector_texture_transform > WL_OUTPUT_TRANSFORM_FLIPPED_270)) return false;
    for (int i = 0; i < 4; i++) if (!isfinite(s->sector_texture_rect[i])) return false;
    if (s->sector_texture_rect[2] < 0 || s->sector_texture_rect[3] < 0 ||
        (s->sector_texture_rect[2] > 0 && s->sector_texture_rect[3] <= 0)) return false;
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
bool scene_pass_program_init(struct program *, unsigned, const char *, const char *, const char *);
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
// The sources the linear programs are built from (scene_pass.c, scene_pass_ribbon.c).
extern const char scene_pass_shaped_vertex[], scene_pass_shaped_fragment[];
// Builds the linear twin of every base program that exists and lacks one, inside
// scene_pass_enter (scene_pass_linear.c); false when one failed to build.
bool scene_pass_linear_build(struct rediwm_scene_renderer *r);
bool scene_pass_ribbon_build_linear(struct rediwm_scene_renderer *r);
void scene_pass_linear_destroy(struct rediwm_scene_renderer *r);

#endif
