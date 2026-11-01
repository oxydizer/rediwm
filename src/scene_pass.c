// Stage 3 drawing backend. No output, scene traversal or geometry policy here.
#include "scene_pass_internal.h"

// The parts: this file holds the renderer, its GL state and programs;
// scene_pass_draw.c the pass and its draws (rects, textures, shapes, shadows,
// dim); scene_pass_backdrop.c the glass backdrops. Shared types and helpers
// are in scene_pass_internal.h.

bool scene_pass_enter(struct rediwm_scene_renderer *r, struct gl_state *s) {
    struct wlr_egl *egl = wlr_gles2_renderer_get_egl(r->renderer);
    s->display = wlr_egl_get_display(egl);
    s->previous_display = eglGetCurrentDisplay();
    s->context = eglGetCurrentContext();
    s->draw = eglGetCurrentSurface(EGL_DRAW);
    s->read = eglGetCurrentSurface(EGL_READ);
    if (!eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
            wlr_egl_get_context(egl))) return false;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &s->fbo);
    glGetIntegerv(GL_CURRENT_PROGRAM, &s->program);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &s->array_buffer);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &s->active_texture);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &s->texture);
    if (r->has_external) glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES, &s->external);
    glGetIntegerv(GL_VIEWPORT, s->viewport);
    glGetIntegerv(GL_SCISSOR_BOX, s->scissor_box);
    glGetIntegerv(GL_BLEND_SRC_RGB, &s->src_rgb);
    glGetIntegerv(GL_BLEND_DST_RGB, &s->dst_rgb);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &s->src_alpha);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &s->dst_alpha);
    glGetIntegerv(GL_BLEND_EQUATION_RGB, &s->equation_rgb);
    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &s->equation_alpha);
    s->blend = glIsEnabled(GL_BLEND);
    s->scissor = glIsEnabled(GL_SCISSOR_TEST);
    if (r->has_vao) {
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING_OES, &s->vertex_array);
    } else {
        struct attrib_state *a = &s->attrib;
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a->enabled);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a->size);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a->type);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a->normalized);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a->stride);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &a->buffer);
        glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &a->pointer);
    }
    return true;
}
void scene_pass_leave(struct rediwm_scene_renderer *r, struct gl_state *s) {
    if (r->has_vao) {
        r->bind_vertex_array(s->vertex_array);
    } else {
        const struct attrib_state *a = &s->attrib;
        glBindBuffer(GL_ARRAY_BUFFER, a->buffer);
        glVertexAttribPointer(0, a->size, a->type, a->normalized, a->stride, a->pointer);
        (a->enabled ? glEnableVertexAttribArray : glDisableVertexAttribArray)(0);
    }
    glBindBuffer(GL_ARRAY_BUFFER, s->array_buffer);
    glBindFramebuffer(GL_FRAMEBUFFER, s->fbo);
    glUseProgram(s->program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, s->texture);
    if (r->has_external) glBindTexture(GL_TEXTURE_EXTERNAL_OES, s->external);
    glActiveTexture(s->active_texture);
    glViewport(s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3]);
    glScissor(s->scissor_box[0], s->scissor_box[1], s->scissor_box[2], s->scissor_box[3]);
    glBlendFuncSeparate(s->src_rgb, s->dst_rgb, s->src_alpha, s->dst_alpha);
    glBlendEquationSeparate(s->equation_rgb, s->equation_alpha);
    (s->blend ? glEnable : glDisable)(GL_BLEND);
    (s->scissor ? glEnable : glDisable)(GL_SCISSOR_TEST);
    if (s->previous_display != EGL_NO_DISPLAY)
        eglMakeCurrent(s->previous_display, s->draw, s->read, s->context);
    else
        eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

// Shaped draws (stage 4b): the same quad and texture coordinates, plus the
// position relative to the shape's corner, evaluated in the vertex stage so the
// fragment's distance function works on window-sized numbers, not on output ones.
static const char shaped_vertex[] =
    "attribute vec2 position; uniform vec2 target, origin; uniform vec4 dst, coords[2];"
    "varying vec2 uv; varying vec2 local;"
    "void main(){ vec4 row=position.y<.5?coords[0]:coords[1];"
    "uv=position.x<.5?row.xy:row.zw; vec2 p=dst.xy+position*dst.zw;"
    "local=p-origin; gl_Position=vec4(p/target*2.-1.,0.,1.); }";
// One distance function for every piece of a window, so titlebar, client, border
// and shadow agree on the arc to the last bit. The radius is picked by quadrant
// and capped to what fits, as the compositor caps it before scaling.
#define SHAPED_HEAD \
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n" \
    "varying vec2 uv; varying vec2 local; uniform vec2 size; uniform vec4 radii, bcolor, color;" \
    "uniform float border; uniform vec4 glow, gcolor;" \
    /* A polygon's distance: the nearest edge, signed by an even-odd crossing count; */ \
    /* the loop of rediwm_sd_polygon (scene_graph.h). poly[npoly] repeats poly[0]. */ \
    /* Only the polygon programs (POLY, built on demand) carry it: the others */ \
    /* compile to what they did before polygons existed. */ \
    "\n#ifdef POLY\n" \
    "uniform float npoly; uniform vec2 poly[17], sector_map; uniform vec4 sector_coords[2];" \
    "float sdpoly(vec2 p){ float d=dot(p-poly[0],p-poly[0]); float s=1.;" \
    "for(int i=0;i<16;i++){ if(float(i)>=npoly) break; vec2 a=poly[i], b=poly[i+1];" \
    "vec2 e=b-a, w=p-a; float h=clamp(dot(w,e)/max(dot(e,e),1e-4),0.,1.); vec2 q=w-e*h; d=min(d,dot(q,q));" \
    "bool c0=p.y>=a.y, c1=p.y<b.y, c2=e.x*w.y>e.y*w.x;" \
    "if((c0&&c1&&c2)||(!c0&&!c1&&!c2)) s=-s; }" \
    "return s*sqrt(d); }" \
    /* The same uniforms carry an analytic sector when npoly is -1. Fold */ \
    /* across its centre line: one finite radial edge covers both sides. */ \
    "float sdsector(vec2 p){ vec2 q=p-poly[0]; float r=length(q);" \
    "vec2 v=vec2(abs(q.x*poly[2].y-q.y*poly[2].x),dot(q,poly[2]));" \
    "vec2 e=poly[3].yx; float t=clamp(dot(v,e),poly[1].x,poly[1].y);" \
    "float d=length(v-e*t); bool angle=v.y>=r*poly[3].x;" \
    "if(angle)d=min(d,min(abs(r-poly[1].x),abs(r-poly[1].y)));" \
    "return angle&&r>=poly[1].x&&r<=poly[1].y?-d:d; }" \
    "vec2 sector_uv(vec2 p){ vec2 q=p-poly[0]; float r=length(q);" \
    "float across=dot(q,vec2(-poly[2].y,poly[2].x))*sector_map.y;" \
    "float angle=r>.00001?atan(across,dot(q,poly[2])):0.;" \
    "return vec2(.5+angle/(2.*atan(poly[3].y,poly[3].x)),(poly[1].y-r)/sector_map.x); }" \
    "\n#endif\n" \
    "float sdf(vec2 p, vec4 r){" \
    "\n#ifdef POLY\n" \
    "if(npoly<-.5) return sdsector(p);" \
    "if(npoly>.5) return sdpoly(p);" \
    "\n#endif\n" \
    "vec2 q=p-size*.5;" \
    "float rad=q.x<0.?(q.y<0.?r.x:r.w):(q.y<0.?r.y:r.z);" \
    "rad=clamp(rad,0.,min(size.x,size.y)*.5);" \
    "vec2 d=abs(q)-(size*.5-vec2(rad));" \
    "return length(max(d,0.))+min(max(d.x,d.y),0.)-rad; }" \
    "float cov(float d){ return clamp(.5-d,0.,1.); }"
// A border is part of the same pass as its body. The ring is composited OVER the
// body inside the shape and the result is scaled by the shape's coverage, which
// is what the border rects of the legacy path do (a translucent border, as the
// default theme has, tints the fill beneath it instead of replacing it). For an
// opaque ring this equals splitting the pixel into body and ring coverage that
// add up to the shape's, the spike's model. As two draws the coverages would
// multiply, and a seam would show where each is partly covered.
//
// `mode` 0 draws the texture, 1 the solid colour, 3 a backdrop composite (see
// add_backdrop), 2 the shape's shadow: the
// shape moved by `offset`, falling off over `softness` outside it with the
// smoothstep of the CPU chrome's shadow (`chrome.shadowCoverage`, the same
// distance field, so corners match it as exactly as edges), kept out of the shape
// when `hide` is set, which matters under translucent windows. One program for the
// three because a program costs the driver 130-150 KiB however small it is.
static const char shaped_fragment[] = SHAPED_HEAD
    "uniform float alpha, opaque, mode, softness, hide; uniform vec2 offset, dim;"
    "uniform sampler2D front; uniform vec4 bmap, fmap; uniform float saturation, front_alpha, has_front, use_shape;"
    // A dimmed window (rediwm_scene_pass_set_dim): colour pulled toward its
    // luminance, then darker. Linear in the colour, so a premultiplied pixel and
    // its straight colour come out the same, and an undimmed one is not touched.
    "vec3 grade(vec3 c){ if(dim.x<=0.&&dim.y<=0.) return c;"
    "float l=dot(c,vec3(.213,.715,.072)); return mix(vec3(l),c,1.-dim.y)*(1.-dim.x); }"
    "void main(){"
    // 3: a backdrop composite (stage 5b). `tex` is the kept blur; the alpha is
    // chosen against the surface drawn over it, so the pair has the coverage.
    "if(mode>2.5){ vec3 rgb=texture2D(tex,(local+bmap.xy)*bmap.zw).rgb;"
    "float l=dot(rgb,vec3(.213,.715,.072)); rgb=clamp(vec3(l)+(rgb-vec3(l))*saturation,0.,1.);rgb=grade(rgb);"
    "float c=cov(sdf(local,radii))*alpha;"
    "float f=has_front>.5?texture2D(front,(local+fmap.xy)*fmap.zw).a*front_alpha:0.;"
    "float a=f>=.99999?0.:clamp((c-f)/(1.-f),0.,1.); gl_FragColor=vec4(rgb*a,a); return; }"
    "if(mode>1.5){ float s=clamp(1.-sdf(local-offset,radii)/softness,0.,1.); s=s*s*(3.-2.*s);"
    "if(hide>.5)s*=1.-cov(sdf(local,radii)); gl_FragColor=color*s; return; }"
    "vec4 c=color; if(mode<.5){ vec2 at=uv; float content=1.;"
    "\n#ifdef POLY\n"
    "if(use_shape>.5&&npoly<-.5&&sector_map.x>0.){ vec2 p=sector_uv(local);"
    "content=clamp((1.-p.y)*sector_map.x+.5,0.,1.); p=clamp(p,0.,1.);"
    "at=mix(mix(sector_coords[0].xy,sector_coords[0].zw,p.x),"
    "mix(sector_coords[1].xy,sector_coords[1].zw,p.x),p.y); }"
    "\n#endif\n"
    "c=texture2D(tex,at); if(opaque>.5)c.a=1.; c*=alpha*content; }"
    // Without a shape (every plain draw) the colour is written as it is: the
    // plain programs are gone (stage 5, D4), and this costs one uniform branch.
    "if(use_shape<.5){ gl_FragColor=vec4(grade(c.rgb),c.a); return; }"
    "float d=sdf(local,radii);"
    "float w=border>0.?1.-cov(d+border):0.;"
    "vec4 o=c*(1.-bcolor.a*w)+bcolor*w;"
    // The highlight (a smoothstep of the distance from its point), over the ring
    // and, when it has depth, fading inward past it.
    "if(glow.z>0.){ float g=clamp(1.-length(local-glow.xy)/glow.z,0.,1.); g=g*g*(3.-2.*g);"
    "float t=glow.w>0.?1.-smoothstep(0.,1.,(-d-border)/glow.w):w;"
    "o=o*(1.-gcolor.a*g*t)+gcolor*(g*t); }"
    "o.rgb=grade(o.rgb); gl_FragColor=o*cov(d); }";

// The backdrop blur (stage 5b): glass.c's kernel, 49 taps, sigma in texels of the
// target, reading a source texture that may be larger than the region (scratch),
// clamped to the texels that were really copied, so an edge replicates.
static const char blur_vertex[] =
    "attribute vec2 position; varying vec2 uv;"
    "void main(){ uv=position; gl_Position=vec4(position*2.-1.,0.,1.); }";
static const char blur_fragment[] =
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"
    "varying vec2 uv; uniform sampler2D tex;"
    "uniform vec2 step_uv, src_scale; uniform float sigma; uniform vec4 limits;"
    "void main(){ vec4 sum=vec4(0.); float weight=0.; vec2 at=uv*src_scale;"
    "for(int i=-24;i<=24;i++){ float x=float(i); float w=exp(-.5*x*x/(sigma*sigma));"
    "sum+=texture2D(tex,clamp(at+x*step_uv,limits.xy,limits.zw))*w; weight+=w; }"
    "gl_FragColor=vec4(sum.rgb/weight,1.); }";

static GLuint shader(GLenum type, const char *prefix, const char *source) {
    GLuint id = glCreateShader(type);
    if (!id) return 0;
    const char *strings[] = {prefix, source};
    glShaderSource(id, 2, strings, NULL);
    glCompileShader(id);
    GLint ok;
    glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(id, sizeof(log), NULL, log);
        wlr_log(WLR_ERROR, "scene pass shader: %s", log);
        glDeleteShader(id);
        return 0;
    }
    return id;
}
static bool program_init(struct program *p, unsigned bit, const char *vertex_source,
        const char *prefix, const char *source) {
    p->bit = bit;
    GLuint vs = shader(GL_VERTEX_SHADER, "", vertex_source);
    GLuint fs = shader(GL_FRAGMENT_SHADER, prefix, source);
    if (vs && fs) {
        p->id = glCreateProgram();
        glAttachShader(p->id, vs);
        glAttachShader(p->id, fs);
        glBindAttribLocation(p->id, 0, "position");
        glLinkProgram(p->id);
        GLint ok;
        glGetProgramiv(p->id, GL_LINK_STATUS, &ok);
        // The linked executable owns everything needed for draws. Deleting an
        // attached shader only marks it for deletion; detach it as well so the
        // driver can release its source and compiler IR now.
        glDetachShader(p->id, vs);
        glDetachShader(p->id, fs);
        if (!ok) {
            glDeleteProgram(p->id);
            p->id = 0;
        }
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!p->id) return false;
    p->target = glGetUniformLocation(p->id, "target");
    p->dst = glGetUniformLocation(p->id, "dst");
    p->color = glGetUniformLocation(p->id, "color");
    p->alpha = glGetUniformLocation(p->id, "alpha");
    p->opaque = glGetUniformLocation(p->id, "opaque");
    p->sampler = glGetUniformLocation(p->id, "tex");
    p->coords = glGetUniformLocation(p->id, "coords[0]");
    p->mode = glGetUniformLocation(p->id, "mode");
    p->origin = glGetUniformLocation(p->id, "origin");
    p->size = glGetUniformLocation(p->id, "size");
    p->radii = glGetUniformLocation(p->id, "radii");
    p->npoly = glGetUniformLocation(p->id, "npoly");
    p->poly = glGetUniformLocation(p->id, "poly[0]");
    p->sector_map = glGetUniformLocation(p->id, "sector_map");
    p->sector_coords = glGetUniformLocation(p->id, "sector_coords[0]");
    p->border = glGetUniformLocation(p->id, "border");
    p->bcolor = glGetUniformLocation(p->id, "bcolor");
    p->glow = glGetUniformLocation(p->id, "glow");
    p->gcolor = glGetUniformLocation(p->id, "gcolor");
    p->offset = glGetUniformLocation(p->id, "offset");
    p->softness = glGetUniformLocation(p->id, "softness");
    p->hide = glGetUniformLocation(p->id, "hide");
    p->use_shape = glGetUniformLocation(p->id, "use_shape");
    p->dim = glGetUniformLocation(p->id, "dim");
    p->bmap = glGetUniformLocation(p->id, "bmap");
    p->fmap = glGetUniformLocation(p->id, "fmap");
    p->saturation = glGetUniformLocation(p->id, "saturation");
    p->front = glGetUniformLocation(p->id, "front");
    p->front_alpha = glGetUniformLocation(p->id, "front_alpha");
    p->has_front = glGetUniformLocation(p->id, "has_front");
    p->step_uv = glGetUniformLocation(p->id, "step_uv");
    p->sigma = glGetUniformLocation(p->id, "sigma");
    p->limits = glGetUniformLocation(p->id, "limits");
    p->src_scale = glGetUniformLocation(p->id, "src_scale");
    // Samplers default to unit 0, and two of different types there (the external
    // program's `tex` and `front`) make every draw invalid: `front` is unit 1.
    if (p->front >= 0) {
        glUseProgram(p->id);
        glUniform1i(p->front, 1);
    }
    return true;
}
static const char ext_prefix[] =
    "#extension GL_OES_EGL_image_external : require\nuniform samplerExternalOES tex;\n";
struct rediwm_scene_renderer *rediwm_scene_renderer_create(struct wlr_renderer *renderer) {
    if (!wlr_renderer_is_gles2(renderer)) return NULL;
    struct rediwm_scene_renderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->renderer = renderer;
    r->has_external = wlr_gles2_renderer_check_ext(renderer, "GL_OES_EGL_image_external");
    r->gen_vertex_arrays = (PFNGLGENVERTEXARRAYSOESPROC)eglGetProcAddress("glGenVertexArraysOES");
    r->bind_vertex_array = (PFNGLBINDVERTEXARRAYOESPROC)eglGetProcAddress("glBindVertexArrayOES");
    r->delete_vertex_arrays = (PFNGLDELETEVERTEXARRAYSOESPROC)eglGetProcAddress("glDeleteVertexArraysOES");
    r->has_vao = wlr_gles2_renderer_check_ext(renderer, "GL_OES_vertex_array_object") &&
        r->gen_vertex_arrays && r->bind_vertex_array && r->delete_vertex_arrays;
    r->create_sync = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
    r->destroy_sync = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
    r->wait_sync = (PFNEGLWAITSYNCKHRPROC)eglGetProcAddress("eglWaitSyncKHR");
    r->dup_fence = (PFNEGLDUPNATIVEFENCEFDANDROIDPROC)eglGetProcAddress("eglDupNativeFenceFDANDROID");
    r->has_sync = renderer->features.timeline && r->create_sync &&
        r->destroy_sync && r->wait_sync && r->dup_fence;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) { free(r); return NULL; }
    // Every draw goes through the shaped programs; one without a shape costs a
    // uniform branch. A GL program costs the driver 130-150 KiB however small,
    // so the plain ones are gone (stage 5, D4 of docs/plans/scene-graph-stage5.md).
    bool ok = program_init(&r->shaped, 8, shaped_vertex, "uniform sampler2D tex;\n", shaped_fragment);
    r->has_shapes = r->shapes_tried = ok;
    if (ok && r->has_vao) {
        r->gen_vertex_arrays(1, &r->vertex_array);
        r->bind_vertex_array(r->vertex_array);
        glGenBuffers(1, &r->vertices);
        glBindBuffer(GL_ARRAY_BUFFER, r->vertices);
        glBufferData(GL_ARRAY_BUFFER, sizeof(positions), positions, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
        glEnableVertexAttribArray(0);
        ok = r->vertex_array && r->vertices && glGetError() == GL_NO_ERROR;
    }
    if (!ok) {
        if (r->vertex_array) r->delete_vertex_arrays(1, &r->vertex_array);
        glDeleteBuffers(1, &r->vertices);
        glDeleteProgram(r->shaped.id);
        glDeleteProgram(r->shaped_external.id);
    }
    scene_pass_leave(r, &state);
    if (!ok) { free(r); return NULL; }
    return r;
}
void rediwm_scene_renderer_destroy(struct rediwm_scene_renderer *r) {
    if (!r) return;
    assert(!r->active);
    struct gl_state state;
    if (scene_pass_enter(r, &state)) {
        if (r->vertex_array) r->delete_vertex_arrays(1, &r->vertex_array);
        glDeleteBuffers(1, &r->vertices);
        glDeleteProgram(r->shaped.id);
        glDeleteProgram(r->shaped_external.id);
        glDeleteProgram(r->shaped_poly.id);
        glDeleteProgram(r->shaped_poly_external.id);
        glDeleteProgram(r->blur.id);
        glDeleteTextures(1, &r->prefix_tex);
        glDeleteFramebuffers(1, &r->prefix_fbo);
        glDeleteTextures(1, &r->small_tex);
        glDeleteFramebuffers(1, &r->small_fbo);
        scene_pass_leave(r, &state);
    }
    free(r);
}

// The shaped programs are built with the renderer (stage 5, D4): every draw uses
// them. Kept so callers need not know.
bool rediwm_scene_renderer_enable_shapes(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    return r->has_shapes;
}

bool rediwm_scene_renderer_enable_external(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    if (r->external_tried) return r->external_ok;
    r->external_tried = true;
    if (!r->has_external) return r->external_ok = true;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) return false;
    r->external_ok = program_init(&r->shaped_external, 16, shaped_vertex, ext_prefix, shaped_fragment);
    scene_pass_leave(r, &state);
    return r->external_ok;
}

// The polygon programs: the shaped ones again with POLY defined (scene_pass.h).
bool rediwm_scene_renderer_enable_polygons(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    if (r->polys_tried) return r->has_polys;
    r->polys_tried = true;
    if (!r->has_shapes) return false;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) return false;
    r->has_polys = program_init(&r->shaped_poly, 64, shaped_vertex, "#define POLY 1\nuniform sampler2D tex;\n", shaped_fragment) &&
        (!r->has_external || program_init(&r->shaped_poly_external, 128, shaped_vertex,
            "#extension GL_OES_EGL_image_external : require\n#define POLY 1\nuniform samplerExternalOES tex;\n", shaped_fragment));
    if (!r->has_polys) {
        wlr_log(WLR_ERROR, "scene pass: polygon programs failed to build, outlines are not drawn");
        glDeleteProgram(r->shaped_poly.id);
        glDeleteProgram(r->shaped_poly_external.id);
        r->shaped_poly.id = r->shaped_poly_external.id = 0;
    }
    scene_pass_leave(r, &state);
    return r->has_polys;
}

bool rediwm_scene_renderer_enable_backdrops(struct rediwm_scene_renderer *r) {
    assert(!r->active);
    if (r->backdrops_tried) return r->has_backdrops;
    r->backdrops_tried = true;
    if (!r->has_shapes) return false;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) return false;
    r->has_backdrops = program_init(&r->blur, 32, blur_vertex, "", blur_fragment);
    if (!r->has_backdrops) {
        wlr_log(WLR_ERROR, "scene pass: blur program failed to build, glass is a plain tint");
        glDeleteProgram(r->blur.id);
        r->blur.id = 0;
    }
    scene_pass_leave(r, &state);
    return r->has_backdrops;
}
