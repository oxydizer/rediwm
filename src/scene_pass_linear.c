// Linear composition and output encoding.
// Part of scene_pass.c. A linear pass blends in linear light (BT.2020, 1.0 =
// SDR white) into an FP16 image of the output kept by the caller, then encodes
// the parts the output's buffer lacks. Nothing here is built or allocated
// until an output asks for it.
#include "scene_pass_internal.h"
#include "scene_pass_color.h"

// FP16 to the output's buffer, after `adjust` (night light, a matrix on linear
// BT.2020). `mode` 0: BT.2020 to BT.709, clipped, gamma 2.2, the inverse of
// GLSL_LIN inside sRGB's gamut. 1: HDR10, SMPTE ST 2084 (PQ) on BT.2020 with
// 1.0 at `white` (SDR white over 10000 cd/m²), clipped at 10000. Mode 2
// rolls extended highlights into the SDR range for a capture.
static const char encode_vertex[] =
    "attribute vec2 position; void main(){ gl_Position=vec4(position*2.-1.,0.,1.); }";
static const char encode_fragment[] =
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"
    GLSL_SDR_KNEE
    "uniform highp sampler2D tex; uniform vec2 target; uniform float mode, white; uniform mat3 adjust;"
    "void main(){ vec3 c=adjust*texture2D(tex,gl_FragCoord.xy/target).rgb;"
    "if(mode==1.){ vec3 p=pow(clamp(c*white,0.,1.),vec3(.1593017578125));"
    "gl_FragColor=vec4(pow((.8359375+18.8515625*p)/(1.+18.6875*p),vec3(78.84375)),1.); return; }"
    "c=" GLSL_BT2020_TO_BT709 "*c; if(mode==2.)c=knee(c); c=clamp(c,0.,1.);"
    "gl_FragColor=vec4(pow(c,vec3(1./2.2)),1.); }";

#ifndef GL_HALF_FLOAT
#define GL_HALF_FLOAT 0x140B
#endif
#ifndef GL_RGBA16F_EXT
#define GL_RGBA16F_EXT 0x881A
#endif

// The first FP16 texture format a framebuffer accepts here: sized with the ES 3
// type, sized with the OES type, unsized (ES 2 with OES_texture_half_float).
// Glass samples these images bilinearly, which ES 2 allows only with
// OES_texture_half_float_linear.
static bool probe_half(struct rediwm_scene_renderer *r) {
    const char *version = (const char *)glGetString(GL_VERSION);
    const bool es3 = version && strncmp(version, "OpenGL ES ", 10) == 0 && version[10] >= '3';
    if (!es3 && !wlr_gles2_renderer_check_ext(r->renderer, "GL_OES_texture_half_float_linear")) return false;
    const struct { GLint internal; GLenum type; } candidates[] = {
        {GL_RGBA16F_EXT, GL_HALF_FLOAT}, {GL_RGBA16F_EXT, GL_HALF_FLOAT_OES}, {GL_RGBA, GL_HALF_FLOAT_OES},
    };
    GLuint tex, fbo;
    glGenTextures(1, &tex);
    glGenFramebuffers(1, &fbo);
    bool found = false;
    while (glGetError() != GL_NO_ERROR) {}
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]) && !found; i++) {
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, candidates[i].internal, 4, 4, 0, GL_RGBA, candidates[i].type, NULL);
        if (glGetError() != GL_NO_ERROR) continue;
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE && glGetError() == GL_NO_ERROR) {
            r->half_internal = candidates[i].internal;
            r->half_type = candidates[i].type;
            found = true;
        }
    }
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &tex);
    while (glGetError() != GL_NO_ERROR) {}
    return found;
}

bool scene_pass_linear_build(struct rediwm_scene_renderer *r) {
    bool ok = true;
    if (!r->lin.id) ok = scene_pass_program_init(&r->lin, 512, scene_pass_shaped_vertex,
        "#define LINEAR 1\nuniform sampler2D tex;\n", scene_pass_shaped_fragment) && ok;
    if (r->shaped_external.id && !r->lin_external.id) ok = scene_pass_program_init(&r->lin_external, 1024,
        scene_pass_shaped_vertex, "#extension GL_OES_EGL_image_external : require\n#define LINEAR 1\n"
        "uniform samplerExternalOES tex;\n", scene_pass_shaped_fragment) && ok;
    if (r->shaped_poly.id && !r->lin_poly.id) ok = scene_pass_program_init(&r->lin_poly, 2048,
        scene_pass_shaped_vertex, "#define LINEAR 1\n#define POLY 1\nuniform sampler2D tex;\n",
        scene_pass_shaped_fragment) && ok;
    if (r->shaped_poly_external.id && !r->lin_poly_external.id) ok = scene_pass_program_init(&r->lin_poly_external,
        4096, scene_pass_shaped_vertex, "#extension GL_OES_EGL_image_external : require\n#define LINEAR 1\n"
        "#define POLY 1\nuniform samplerExternalOES tex;\n", scene_pass_shaped_fragment) && ok;
    if (!r->encode.id && scene_pass_program_init(&r->encode, 8192, encode_vertex, "", encode_fragment)) {
        r->encode_white = glGetUniformLocation(r->encode.id, "white");
        r->encode_adjust = glGetUniformLocation(r->encode.id, "adjust");
    }
    ok = r->encode.id && ok;
    ok = scene_pass_ribbon_build_linear(r) && ok;
    if (!ok) wlr_log(WLR_ERROR, "scene pass: a linear program failed to build; linear passes using it fail");
    return ok;
}

void scene_pass_linear_destroy(struct rediwm_scene_renderer *r) {
    struct program *programs[] = {&r->lin, &r->lin_external, &r->lin_poly, &r->lin_poly_external,
        &r->ribbon_lin, &r->encode};
    for (size_t i = 0; i < sizeof(programs) / sizeof(programs[0]); i++) {
        glDeleteProgram(programs[i]->id);
        *programs[i] = (struct program){0};
    }
    glDeleteTextures(1, &r->lin_prefix_tex);
    glDeleteFramebuffers(1, &r->lin_prefix_fbo);
    glDeleteTextures(1, &r->lin_small_tex);
    glDeleteFramebuffers(1, &r->lin_small_fbo);
    r->lin_prefix_tex = r->lin_prefix_fbo = r->lin_small_tex = r->lin_small_fbo = 0;
    r->lin_small_w = r->lin_small_h = 0;
}

bool rediwm_scene_renderer_enable_linear(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    if (r->linear_tried) return r->has_linear;
    r->linear_tried = true;
    if (!r->has_shapes) return false;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) return false;
    // The base programs' twins, the encode and, if ribbons are on, theirs. The
    // flag is set first so a twin built later (enable_external) is not missed.
    r->has_linear = probe_half(r);
    if (!r->has_linear) {
        wlr_log(WLR_ERROR, "scene pass: no renderable FP16 texture format, so no output blends in linear light");
    } else if (!scene_pass_linear_build(r) && (!r->lin.id || !r->encode.id)) {
        // Only the plain twin or the encode is fatal: without them nothing draws.
        scene_pass_linear_destroy(r);
        r->has_linear = false;
    }
    scene_pass_leave(r, &state);
    return r->has_linear;
}

bool rediwm_scene_renderer_ensure_linear_target(struct rediwm_scene_renderer *r,
        struct rediwm_linear_target **target, int width, int height, bool *fresh) {
    assert(!r->active);
    *fresh = false;
    if (!r->has_linear || width <= 0 || height <= 0 || width > 16384 || height > 16384) return false;
    struct rediwm_linear_target *t = *target;
    if (t && t->width == width && t->height == height) return true;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) return false;
    if (!t) {
        t = calloc(1, sizeof(*t));
        if (!t) { scene_pass_leave(r, &state); return false; }
        glGenTextures(1, &t->tex);
        glGenFramebuffers(1, &t->fbo);
        *target = t;
    }
    while (glGetError() != GL_NO_ERROR) {}
    glBindTexture(GL_TEXTURE_2D, t->tex);
    glTexImage2D(GL_TEXTURE_2D, 0, r->half_internal, width, height, 0, GL_RGBA, r->half_type, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->tex, 0);
    const bool ok = glGetError() == GL_NO_ERROR &&
        glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    t->width = ok ? width : 0;
    t->height = ok ? height : 0;
    scene_pass_leave(r, &state);
    *fresh = ok;
    return ok;
}

void rediwm_scene_renderer_destroy_linear_target(struct rediwm_scene_renderer *r, struct rediwm_linear_target *t) {
    if (!t) return;
    assert(!r->active);
    struct gl_state state;
    if (scene_pass_enter(r, &state)) {
        glDeleteTextures(1, &t->tex);
        glDeleteFramebuffers(1, &t->fbo);
        scene_pass_leave(r, &state);
    }
    free(t);
}

struct wlr_render_pass *rediwm_scene_pass_begin_linear(struct rediwm_scene_renderer *r,
        struct wlr_buffer *buffer, const struct wlr_buffer_pass_options *options,
        struct rediwm_linear_target *target) {
    if (!r->has_linear || !target || target->width != buffer->width || target->height != buffer->height)
        return NULL;
    struct wlr_render_pass *base = rediwm_scene_pass_begin(r, buffer, options);
    if (!base) return NULL;
    struct pass *p = owned_pass(base);
    p->linear = target;
    glBindFramebuffer(GL_FRAMEBUFFER, target->fbo);
    return base;
}

static bool encode_usable(const struct rediwm_pass_encode *e) {
    if (!e) return true;
    if (e->pq && !(isfinite(e->sdr_white) && e->sdr_white >= 1 && e->sdr_white <= 10000)) return false;
    for (int i = 0; i < 9; i++) if (!isfinite(e->adjust[i])) return false;
    return true;
}
void rediwm_scene_pass_encode(struct wlr_render_pass *base, const pixman_region32_t *region,
        const struct rediwm_pass_encode *options) {
    struct pass *p = owned_pass(base);
    struct rediwm_scene_renderer *r = p->renderer;
    if (p->failed) return;
    if (!p->linear || p->redirected || p->encoded || !r->encode.id || !encode_usable(options)) {
        p->failed = true;
        return;
    }
    if (!pixman_region32_not_empty((pixman_region32_t *)region)) { p->encoded = true; return; }
    glBindFramebuffer(GL_FRAMEBUFFER, wlr_gles2_renderer_get_buffer_fbo(r->renderer, p->buffer));
    glViewport(0, 0, p->buffer->width, p->buffer->height);
    glUseProgram(r->encode.id);
    p->program = r->encode.id;
    glUniform2f(r->encode.target, p->buffer->width, p->buffer->height);
    static const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    bool adjusted = false;
    if (options) for (int i = 0; i < 9; i++) if (options->adjust[i] != 0) adjusted = true;
    glUniformMatrix3fv(r->encode_adjust, 1, GL_FALSE, adjusted ? options->adjust : identity);
    glUniform1f(r->encode.mode, options && options->pq ? 1.f : options && options->tone_map ? 2.f : 0.f);
    glUniform1f(r->encode_white, options && options->pq ? options->sdr_white / 10000.f : 1.f);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, p->linear->tex);
    glUniform1i(r->encode.sampler, 0);
    glDisable(GL_BLEND);
    p->blend_mode = WLR_RENDER_BLEND_MODE_NONE;
    scene_pass_draw(p, region);
    p->encoded = true;
}
