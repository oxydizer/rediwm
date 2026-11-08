// Optional ribbon program: never built or visited by ordinary window draws.
#include "scene_pass_internal.h"
#include "ribbon.h"

static const char ribbon_vertex[] =
    "attribute vec4 position; uniform vec2 target; uniform vec4 dst;"
    "uniform mediump int mode; uniform mediump vec2 fade;"
    "varying vec2 ribbon; void main(){"
    "vec2 p=dst.xy+position.xy;"
    // A strip is a sequence of trapezoids. Perspective-correct interpolation
    // with reciprocal row width prevents each triangle shearing the text in
    // opposite directions (visible as a zipper along every vertical edge).
    "float w=1.; if(mode==2){"
        "float along=mix(position.w,1.-position.w,fade.y);"
        "float pull=smoothstep(0.,1.,(fade.x*1.5-(1.-along)*.58)/.92);"
        "float remain=1.-pull;"
        "w=1./max(.0001,remain*remain+.015*pull*(1.-fade.x));"
    "}"
    "gl_Position=vec4((p/target*2.-1.)*w,0.,w); ribbon=position.zw; }";
static const char ribbon_fragment[] =
    "#ifdef GL_OES_standard_derivatives\n#extension GL_OES_standard_derivatives : enable\n#endif\n"
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"
    "varying vec2 ribbon; uniform vec4 color, bcolor;"
    "uniform mediump int mode; uniform mediump vec2 fade; uniform sampler2D tex; uniform float alpha;"
    // Dense coloured sheets with restrained creases and narrow, faint halos.
    // Divide before squaring so the finest widths do not underflow on mediump.
    "float ridge(float x,float w){ float q=min(abs(x)/w,8.); return exp(-q*q); }"
    // Approximate pixel coverage without fattening subpixel creases into tubes.
    "float filament(float x,float w){\n"
    "#ifdef GL_OES_standard_derivatives\n"
        "float pixel=length(vec2(dFdx(x),dFdy(x)));"
        "float filtered=sqrt(w*w+pixel*pixel/6.);"
        "return ridge(x,filtered)*w/filtered;\n"
    "#else\nreturn ridge(x,w);\n#endif\n}"
    // Both the flames and their connecting sheet erase from tail to sources.
    "float trailOpacity(float t){"
        "float front=mix(-.12,1.12,1.-fade.y);"
        "return mix(fade.x,1.,t)*smoothstep(front-.10,front+.10,t)*smoothstep(0.,.14,t)"
            "*(1.-smoothstep(1.,2.,ribbon.y));"
    "}"
    "void main(){ float x=ribbon.x, d=abs(x), t=clamp(ribbon.y,0.,1.);"
    "if(mode==2){"
        "vec2 uv=ribbon; float p=fade.x;"
        "float along=mix(uv.y,1.-uv.y,fade.y);"
        "float wave=.018*sin(uv.x*23.+p*17.)+.012*sin(uv.x*51.-p*11.);"
        // Consume the full sheet while it still has width, before the pull
        // collapses it into the destination. Both side creases ignite with it.
        "float front=1.04-1.85*p+wave*sin(p*3.141593);"
        "float burn=along-front;"
        "float alive=1.-smoothstep(-.035,.035,burn);"
        "float inside=step(0.,uv.x)*step(uv.x,1.);"
        "vec4 body=texture2D(tex,clamp(uv,0.,1.))*inside;"
        "float edge=min(abs(uv.x),abs(1.-uv.x));"
        "float lit=smoothstep(-.10,.02,burn);"
        "float hot=filament(edge,.0028)*lit+filament(burn,.006)*inside;"
        "float glow=.10*ridge(edge,.012)*lit+.12*ridge(burn,.025)*inside;"
        "float band=.65*ridge(edge,.006)*lit+.70*ridge(burn,.014)*inside;"
        "float light=clamp(.25*hot+band+glow,0.,1.)*smoothstep(0.,.12,p)*(1.-smoothstep(.82,1.,p));"
        "vec4 fire=mix(color,bcolor,clamp(hot,0.,1.)*.22);"
        "float a=light*fire.a;"
        "float fold=.12*sin(along*15.-p*9.)*sin(p*3.141593);"
        "float ghost=.10*(1.-alive)*(1.-smoothstep(.04,.20,burn));"
        "body*=(alive+ghost)*(1.-smoothstep(.78,1.,p))*(1.-.38*smoothstep(.15,.85,along)*p)*alpha;"
        "body.rgb*=1.+fold; body.rgb=min(body.rgb,vec3(body.a));"
        "gl_FragColor=vec4(fire.rgb*a,a)+body*(1.-a); return;"
    "}"
    "float core, light, opacity=t;"
    "if(mode==1){"
        "core=ridge(d,.055);"
        "light=.12*exp(-7.*d)+.72*ridge(d,.19)+.18*core;"
    "}else if(mode==3){"
        "float rim=d-.90;"
        "float f=.40*sin(t*12.566371+fade.y);"
        "core=.35*filament(rim,.009)+.16*filament(x-f,.007);"
        // The resize band joins two outlines. Keep a continuous coloured
        // sheet across its full width, including the window and target edges.
        "light=.35*core+.36+.06*ridge(rim,.025)+.18*ridge(x,.65)"
            "+.08*ridge(x-f,.10)+.05*ridge(x+f*.7,.20);"
        "opacity=fade.x;"
    "}else if(mode==4){"
        // A low-opacity colour wash, stronger near the window and softly
        // feathered into the two flames. No hot creases in the middle.
        "core=0.;"
        "light=.10*(.55+.45*d*d)*smoothstep(0.,1.,t);"
        "opacity=trailOpacity(t);"
    "}else{"
        // Two attachment points (x = +/- .55) feed the edges of one sheet.
        // The edges meet farther down the trail, retaining a single tapered tail.
        "float split=smoothstep(.30,.92,t);"
        "float center=.16*sin(t*7.)*(1.-t);"
        "float spread=.55*split;"
        "float a=x-center-spread,b=x-center+spread;"
        // Fine roots and a hairline tail, swelling gently through the fold.
        // Different profiles keep the two creases from reading as parallel tubes.
        "float swell=sin(t*3.141593);"
        "float wa=.009+.015*swell*swell;"
        "float wb=.008+.012*swell*(.7+.3*sin(t*5.+.6));"
        "core=.45*clamp(filament(a,wa)+.82*filament(b,wb),0.,1.);"
        "float sheet=.58*ridge(x-center,.12+spread);"
        "float fold=.10*ridge(x-center-.12*sin(t*9.)*(1.-t),.045);"
        "light=.025*ridge(x-center,.55)+sheet+fold"
            "+.07*ridge(a,wa*2.+.01)+.06*ridge(b,wb*2.+.01)+.35*core;"
        // Advance a soft erasing front from the frozen tail to its sources.
        // At rest only coverage changes; the surviving folds stay in place.
        "opacity=trailOpacity(t);"
    "}"
    "float coverage=mode==3?1.:1.-smoothstep(.78,1.,d);"
    "float a=opacity*clamp(light,0.,1.)*coverage;"
    "vec4 c=mix(color,bcolor,core*.22);"
    "gl_FragColor=vec4(c.rgb*c.a*a,c.a*a); }";

bool rediwm_scene_renderer_set_ribbons(struct rediwm_scene_renderer *r, bool enabled) {
    assert(!r->active);
    if (enabled == (r->ribbon.id != 0)) return true;
    struct gl_state state;
    if (!scene_pass_enter(r, &state)) return false;
    bool ok = true;
    if (enabled) {
        ok = scene_pass_program_init(&r->ribbon, 256, ribbon_vertex, "", ribbon_fragment);
        if (ok) {
            r->ribbon_fade = glGetUniformLocation(r->ribbon.id, "fade");
            glGenBuffers(1, &r->ribbon_vertices);
            ok = r->ribbon_vertices && glGetError() == GL_NO_ERROR;
        }
    }
    if (!enabled || !ok) {
        glDeleteProgram(r->ribbon.id);
        glDeleteBuffers(1, &r->ribbon_vertices);
        r->ribbon = (struct program){0};
        r->ribbon_vertices = 0;
    }
    scene_pass_leave(r, &state);
    return ok;
}

void rediwm_scene_pass_add_ribbon(struct wlr_render_pass *base, struct wlr_box box,
        const struct rediwm_ribbon *mesh, const pixman_region32_t *clip, float opacity,
        struct wlr_texture *texture) {
    struct pass *p = owned_pass(base);
    struct rediwm_scene_renderer *r = p->renderer;
    if (p->failed || mesh->count < 4 || !pixman_region32_not_empty((pixman_region32_t *)clip)) return;
    if (!r->ribbon.id || mesh->count > REDIWM_RIBBON_VERTICES) { p->failed = true; return; }
    scene_pass_setup(p, &r->ribbon, box, WLR_RENDER_BLEND_MODE_PREMULTIPLIED);
    glUniform1i(r->ribbon.mode, mesh->edge);
    glUniform1f(r->ribbon.alpha, opacity);
    if (mesh->edge == 2) {
        if (!texture || !wlr_texture_is_gles2(texture)) { p->failed = true; return; }
        struct wlr_gles2_texture_attribs a;
        wlr_gles2_texture_get_attribs(texture, &a);
        if (a.target != GL_TEXTURE_2D) { p->failed = true; return; }
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, a.tex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glUniform1i(r->ribbon.sampler, 0);
    }
    glUniform2fv(r->ribbon_fade, 1, mesh->fade);
    glUniform4f(r->ribbon.color, mesh->color[0], mesh->color[1], mesh->color[2], mesh->color[3] * opacity);
    glUniform4f(r->ribbon.bcolor, mesh->core_color[0], mesh->core_color[1], mesh->core_color[2], mesh->core_color[3] * opacity);
    glBindBuffer(GL_ARRAY_BUFFER, r->ribbon_vertices);
    float vertices[REDIWM_RIBBON_VERTICES][4];
    const void *data = mesh->vertices;
    if (p->redirected) {
        // Backdrop captures have already scaled dst; their mesh offsets must
        // follow it into the reduced image as well.
        for (uint32_t i = 0; i < mesh->count; i++) {
            for (int j = 0; j < 4; j++) vertices[i][j] = mesh->vertices[i][j];
            vertices[i][0] /= p->factor;
            vertices[i][1] /= p->factor;
        }
        data = vertices;
    }
    glBufferData(GL_ARRAY_BUFFER, mesh->count * sizeof(mesh->vertices[0]), data, GL_STREAM_DRAW);
    glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, NULL);
    glEnableVertexAttribArray(0);
    int n;
    const pixman_box32_t *boxes = pixman_region32_rectangles((pixman_region32_t *)clip, &n);
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < n; i++) {
        if (p->redirected) {
            const int x1 = floorf((boxes[i].x1 - p->region.x) / p->factor);
            const int y1 = floorf((boxes[i].y1 - p->region.y) / p->factor);
            const int x2 = ceilf((boxes[i].x2 - p->region.x) / p->factor);
            const int y2 = ceilf((boxes[i].y2 - p->region.y) / p->factor);
            glScissor(x1, y1, x2 - x1, y2 - y1);
        } else glScissor(boxes[i].x1, boxes[i].y1, boxes[i].x2 - boxes[i].x1, boxes[i].y2 - boxes[i].y1);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, mesh->count);
    }
    // Restore the quad VAO/attribute used by every subsequent owned draw.
    glBindBuffer(GL_ARRAY_BUFFER, r->has_vao ? r->vertices : 0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, r->has_vao ? NULL : positions);
}
