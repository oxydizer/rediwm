// Stage 3 gates: parity with wlroots, failing closed, damage, GL state,
// external and YUV textures, and synchronization.
// Included by scene_pass_test.c, in its one unit with scene_pass.c.

static void parity(struct rediwm_scene_renderer *r, struct wlr_buffer *actual,
        struct wlr_buffer *expected, bool shaped) {
    const struct rediwm_pass_shape cover = {.box = {-50, -50, WIDTH + 100, HEIGHT + 100}};
    const struct rediwm_pass_shape *shape = shaped ? &cover : NULL;
    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, -10, 8, 65, 31);
    pixman_region32_union_rect(&clip, &clip, 71, 43, 81, 80);
    int worst = 0, cases = 0;
    for (int opaque = 0; opaque < 2; opaque++) {
        struct wlr_texture *t = texture_create(r->renderer, opaque);
        for (int tr = 0; tr < 8; tr++) for (int filter = 0; filter < 2; filter++)
        for (int crop = 0; crop < 2; crop++) for (int partial = 0; partial < 2; partial++) {
            float alpha = partial ? .61 : 1;
            struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
            assert(pass);
            clear(pass);
            paint(pass, t, tr, filter, crop, alpha, partial ? &clip : NULL, NULL);
            assert(wlr_render_pass_submit(pass));
            pass = rediwm_scene_pass_begin(r, actual, NULL);
            assert(pass);
            clear(pass);
            paint(pass, t, tr, filter, crop, alpha, partial ? &clip : NULL, shape);
            assert(wlr_render_pass_submit(pass));
            int d = compare(r, actual, expected);
            if (d > 1) {
                fprintf(stderr, "parity: shaped=%d opaque=%d transform=%d filter=%d crop=%d partial=%d diff=%d\n",
                    shaped, opaque, tr, filter, crop, partial, d);
                abort();
            }
            if (d > worst) worst = d;
            cases++;
        }
        wlr_texture_destroy(t);
    }
    pixman_region32_fini(&clip);
    printf("PASS: %d texture/transform/crop/filter/alpha/damage cases%s (max difference %d)\n", cases,
        shaped ? " through the shaped programs" : "", worst);
}
// The shaped programs are built with the renderer (stage 5, D4). A bad shape is
// the caller's bug: it must fail the pass at submit, not draw something else,
// and the next pass must work.
static void shapes_fail_closed(struct rediwm_scene_renderer *r, struct wlr_buffer *buffer) {
    assert(rediwm_scene_renderer_enable_shapes(r));
    const struct rediwm_pass_shape shape = {.box = {10, 10, 50, 50}, .radii = {5, -1, 5, 5}};
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(pass);
    rediwm_scene_pass_add_rect_shaped(pass, &(struct wlr_render_rect_options){
        .box = {10, 10, 50, 50}, .color = {1, 0, 0, 1}}, &shape);
    assert(!wlr_render_pass_submit(pass));
    pass = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(pass && wlr_render_pass_submit(pass));
    puts("PASS: shapes are built with the renderer; a bad shape fails the pass and the next pass works");
}
static void damage(struct rediwm_scene_renderer *r, struct wlr_buffer *actual,
        struct wlr_buffer *expected) {
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, actual, NULL);
    assert(pass);
    clear(pass);
    assert(wlr_render_pass_submit(pass));
    uint8_t before[WIDTH * HEIGHT * 4], after[sizeof(before)];
    read_pixels(r, actual, before);
    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, 11, 13, 23, 17);
    pixman_region32_union_rect(&clip, &clip, 71, 60, 13, 19);
    struct wlr_texture *t = texture_create(r->renderer, false);
    pass = rediwm_scene_pass_begin(r, actual, NULL);
    assert(pass);
    paint(pass, t, 3, 0, 1, .73, &clip, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, actual, after);
    int changed = 0;
    for (int y = 0; y < HEIGHT; y++) for (int x = 0; x < WIDTH; x++) {
        bool same = memcmp(&before[4 * (y * WIDTH + x)], &after[4 * (y * WIDTH + x)], 4) == 0;
        if (!pixman_region32_contains_point(&clip, x, y, NULL)) assert(same);
        else changed += !same;
    }
    assert(changed > 0);
    // An empty damage region must not paint anything, even after a prior clip.
    pixman_region32_clear(&clip);
    pass = rediwm_scene_pass_begin(r, actual, NULL);
    assert(pass);
    paint(pass, t, 1, 1, 0, 1, &clip, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, actual, before);
    assert(memcmp(before, after, sizeof(before)) == 0);
    // NONE must replace rather than alpha blend, on both texture and rect paths.
    for (int owned = 0; owned < 2; owned++) {
        pass = owned ? rediwm_scene_pass_begin(r, actual, NULL) :
            wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
        assert(pass);
        clear(pass);
        wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options){
            .texture = t, .dst_box = {17, 19, TW, TH}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
        });
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {71, 8, 11, 13}, .color = {.1, .2, .1, .3}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
        });
        assert(wlr_render_pass_submit(pass));
    }
    assert(compare(r, actual, expected) <= 1);
    wlr_texture_destroy(t);
    pixman_region32_fini(&clip);
    puts("PASS: disjoint and empty damage preserve untouched pixels; disabled blending matches wlroots");
}
static void state_restoration(struct rediwm_scene_renderer *r, struct wlr_buffer *buffer) {
    struct gl_state original;
    assert(scene_pass_enter(r, &original));
    GLuint vbo, textures[2], caller_vao = 0;
    if (r->has_vao) {
        r->gen_vertex_arrays(1, &caller_vao);
        r->bind_vertex_array(caller_vao);
    }
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, 128, NULL, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 16, (void *)4);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, GL_SHORT, GL_TRUE, 8, (void *)16);
    glDisableVertexAttribArray(1);
    glGenTextures(2, textures);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textures[0]);
    glActiveTexture(GL_TEXTURE3);
    glBindTexture(GL_TEXTURE_2D, textures[1]);
    glViewport(7, 9, 53, 41);
    glScissor(2, 3, 19, 23);
    glEnable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE, GL_ZERO, GL_ONE_MINUS_SRC_ALPHA);
    glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_SUBTRACT);
    struct gl_state before = {0}, after = {0};
    assert(scene_pass_enter(r, &before));
    scene_pass_leave(r, &before);
    struct wlr_texture *t = texture_create(r->renderer, false);
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(pass);
    assert(!rediwm_scene_pass_begin(r, buffer, NULL)); // no nested owned passes
    clear(pass);
    paint(pass, t, 1, 0, 1, .5, NULL, NULL);
    assert(wlr_render_pass_submit(pass));
    assert(scene_pass_enter(r, &after));
    scene_pass_leave(r, &after);
    assert(memcmp(&before, &after, sizeof(before)) == 0);
    GLint value;
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &value);
    assert(value == (GLint)vbo);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &value);
    assert(value == 3);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &value);
    assert(value == 16);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_SIZE, &value);
    assert(value == 2);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_TYPE, &value);
    assert(value == GL_SHORT);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &value);
    assert(!value);
    assert(glGetError() == GL_NO_ERROR);
    wlr_texture_destroy(t);
    glDeleteBuffers(1, &vbo);
    glDeleteTextures(2, textures);
    if (caller_vao) r->delete_vertex_arrays(1, &caller_vao);
    scene_pass_leave(r, &original);
    puts("PASS: GL bindings, attributes, blend/scissor/viewport and EGL context restored");
}
static void external_texture(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator,
        struct wlr_buffer *actual, struct wlr_buffer *expected) {
    if (!r->has_external) { puts("SKIP: external-OES unavailable"); return; }
    struct wlr_buffer *source = target(allocator);
    struct wlr_texture *pattern = texture_create(r->renderer, false);
    struct wlr_render_pass *base = wlr_renderer_begin_buffer_pass(r->renderer, source, NULL);
    assert(base);
    clear(base);
    paint(base, pattern, 0, 1, 0, 1, NULL, NULL);
    assert(wlr_render_pass_submit(base));
    wlr_texture_destroy(pattern);
    struct wlr_texture *reference = wlr_texture_from_buffer(r->renderer, source);
    assert(reference);
    struct wlr_dmabuf_attributes dma;
    assert(wlr_buffer_get_dmabuf(source, &dma) && dma.n_planes == 1);
    EGLint attrs[32] = {EGL_WIDTH, dma.width, EGL_HEIGHT, dma.height,
        EGL_LINUX_DRM_FOURCC_EXT, dma.format, EGL_DMA_BUF_PLANE0_FD_EXT, dma.fd[0],
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, dma.offset[0], EGL_DMA_BUF_PLANE0_PITCH_EXT, dma.stride[0]};
    int n = 12;
    if (dma.modifier != DRM_FORMAT_MOD_INVALID) {
        attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
        attrs[n++] = dma.modifier & UINT32_MAX;
        attrs[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
        attrs[n++] = dma.modifier >> 32;
    }
    attrs[n] = EGL_NONE;
    PFNEGLCREATEIMAGEKHRPROC create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    PFNEGLDESTROYIMAGEKHRPROC destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bind_image =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    assert(create_image && destroy_image && bind_image);
    struct gl_state state;
    assert(scene_pass_enter(r, &state));
    EGLImageKHR image = create_image(state.display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
    assert(image != EGL_NO_IMAGE_KHR);
    struct wlr_gles2_texture_attribs a = {.target = GL_TEXTURE_EXTERNAL_OES, .has_alpha = true};
    glGenTextures(1, &a.tex);
    glBindTexture(a.target, a.tex);
    bind_image(a.target, image);
    glTexParameteri(a.target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(a.target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    scene_pass_leave(r, &state);
    for (int tr = 0; tr < 8; tr++) for (int filter = 0; filter < 2; filter++) {
        float alpha = .73;
        struct wlr_render_texture_options o = {
            .texture = reference, .src_box = {4.25, 8.5, 107.5, 71.25},
            .dst_box = {7, 9, 111, 79}, .transform = tr, .filter_mode = filter, .alpha = &alpha,
        };
        base = wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
        assert(base);
        clear(base);
        wlr_render_pass_add_texture(base, &o);
        assert(wlr_render_pass_submit(base));
        base = rediwm_scene_pass_begin(r, actual, NULL);
        assert(base);
        clear(base);
        struct pass *p = wl_container_of(base, p, base);
        // Force a real external EGLImage through the same draw routine; this
        // driver's normal import of an RGB dmabuf chooses a 2D target.
        texture_draw(p, &o, a, NULL);
        assert(wlr_render_pass_submit(base));
        assert(compare(r, actual, expected) <= 1);
        // The shaped external program with a cover-everything shape is the same draw.
        const struct rediwm_pass_shape cover = {.box = {-50, -50, WIDTH + 100, HEIGHT + 100}};
        base = rediwm_scene_pass_begin(r, actual, NULL);
        assert(base);
        clear(base);
        p = wl_container_of(base, p, base);
        texture_draw(p, &o, a, &cover);
        assert(wlr_render_pass_submit(base));
        assert(compare(r, actual, expected) <= 1);
        // And through a rounded, bordered shape the external texture equals the 2D
        // one of the same pixels: the clip does not depend on the sampler.
        const struct rediwm_pass_shape round = {.box = {12, 14, 100, 70},
            .radii = {18, 9, 25.5f, 3}, .border = 2, .border_color = {.5f, .1f, .1f, .5f}};
        base = rediwm_scene_pass_begin(r, expected, NULL);
        assert(base);
        clear(base);
        rediwm_scene_pass_add_texture_shaped(base, &o, &round);
        assert(wlr_render_pass_submit(base));
        base = rediwm_scene_pass_begin(r, actual, NULL);
        assert(base);
        clear(base);
        p = wl_container_of(base, p, base);
        texture_draw(p, &o, a, &round);
        assert(wlr_render_pass_submit(base));
        assert(compare(r, actual, expected) <= 1);
        // Two blank images would also match: the corner must be cut, the middle drawn.
        uint8_t shown[WIDTH * HEIGHT * 4];
        read_pixels(r, actual, shown);
        assert(memcmp(&shown[4 * (15 * WIDTH + 13)], &shown[0], 4) == 0);
        assert(memcmp(&shown[4 * (50 * WIDTH + 60)], &shown[0], 4) != 0);
    }
    assert(scene_pass_enter(r, &state));
    glDeleteTextures(1, &a.tex);
    destroy_image(state.display, image);
    scene_pass_leave(r, &state);
    wlr_texture_destroy(reference);
    wlr_buffer_drop(source);
    puts("PASS: external-OES EGLImage matches wlroots across all transforms and filters, plain and shaped");
}
// Driver-converted YUV. A linear NV12 dmabuf is imported by wlroots exactly as a
// video client's would be. Mesa reports it external-only, so both passes must
// sample it through samplerExternalOES and leave the YUV->RGB conversion to the
// driver. Mesa's gbm cannot allocate NV12, so a linear R8 buffer 1.5x as tall is
// described as two planes of one dmabuf (chroma on a page boundary), as a video
// client would send it. This covers the external program with real YUV; it does
// not cover other drivers' conversion or any tiled/compressed modifier.
static void external_yuv(struct rediwm_scene_renderer *r, struct wlr_buffer *actual,
        struct wlr_buffer *expected, bool deep) {
    enum { YW = 64, YH = 64 };
    if (!r->has_external) { puts("SKIP: external-OES unavailable"); return; }
    int drm_fd = wlr_renderer_get_drm_fd(r->renderer);
    struct gbm_device *gbm = drm_fd >= 0 ? gbm_create_device(drm_fd) : NULL;
    struct gbm_bo *bo = gbm ? gbm_bo_create(gbm, deep ? YW * 2 : YW, YH * 3 / 2, GBM_FORMAT_R8, GBM_BO_USE_LINEAR) : NULL;
    if (!bo || gbm_bo_get_modifier(bo) != DRM_FORMAT_MOD_LINEAR) {
        printf("SKIP: gbm cannot allocate a linear buffer for %s\n", deep ? "P010" : "NV12");
        if (bo) gbm_bo_destroy(bo);
        if (gbm) gbm_device_destroy(gbm);
        return;
    }
    uint32_t stride = gbm_bo_get_stride(bo);
    struct wlr_dmabuf_attributes dma = {.width = YW, .height = YH, .format = deep ? DRM_FORMAT_P010 : DRM_FORMAT_NV12,
        .modifier = DRM_FORMAT_MOD_LINEAR, .n_planes = 2,
        .offset = {0, stride * YH}, .stride = {stride, stride}};
    assert(dma.offset[1] % 4096 == 0);
    for (int i = 0; i < 2; i++) {
        dma.fd[i] = gbm_bo_get_fd(bo);
        assert(dma.fd[i] >= 0);
    }
    size_t length = dma.offset[1] + (size_t)dma.stride[1] * (YH / 2);
    uint8_t *map = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, dma.fd[0], 0);
    assert(map != MAP_FAILED);
    struct dma_buf_sync sync = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
    ioctl(dma.fd[0], DMA_BUF_IOCTL_SYNC, &sync);
    for (int y = 0; y < YH; y++) for (int x = 0; x < YW; x++) {
        uint8_t *row = map + y * dma.stride[0];
        const uint8_t luma = 16 + (x * 3 + y * 5) % 220;
        if (deep) ((uint16_t *)row)[x] = (uint16_t)luma << 8;
        else row[x] = luma;
    }
    for (int y = 0; y < YH / 2; y++) for (int x = 0; x < YW / 2; x++) {
        uint8_t *row = map + dma.offset[1] + y * dma.stride[1];
        uint8_t u = 32 + (x * 11 + y * 3) % 192, v = 32 + (x * 5 + y * 13) % 192;
        if (abs(x - 10) < 3 && abs(y - 10) < 3) { u = 96; v = 176; }
        if (deep) {
            ((uint16_t *)row)[2*x] = (uint16_t)u << 8;
            ((uint16_t *)row)[2*x+1] = (uint16_t)v << 8;
        } else {
            row[2*x] = u;
            row[2*x+1] = v;
        }
    }
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
    ioctl(dma.fd[0], DMA_BUF_IOCTL_SYNC, &sync);
    munmap(map, length);
    struct wlr_texture *texture = wlr_texture_from_dmabuf(r->renderer, &dma);
    struct wlr_gles2_texture_attribs a = {0};
    if (texture) wlr_gles2_texture_get_attribs(texture, &a);
    if (!texture || a.target != GL_TEXTURE_EXTERNAL_OES) {
        printf("SKIP: no external sampler for %s\n", deep ? "P010" : "NV12");
    } else {
        assert(!a.has_alpha);
        yuv_levels(r, actual, texture, &dma);
        float alpha = .81f;
        for (int tr = 0; tr < 8; tr++) for (int filter = 0; filter < 2; filter++) {
            struct wlr_render_texture_options o = {
                .texture = texture, .src_box = {2.25, 3.5, 40.5, 30.25},
                .dst_box = {7, 9, 111, 79}, .transform = tr, .filter_mode = filter, .alpha = &alpha,
            };
            struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(r->renderer, expected, NULL);
            assert(pass);
            clear(pass);
            wlr_render_pass_add_texture(pass, &o);
            assert(wlr_render_pass_submit(pass));
            pass = rediwm_scene_pass_begin(r, actual, NULL);
            assert(pass);
            clear(pass);
            wlr_render_pass_add_texture(pass, &o);
            assert(wlr_render_pass_submit(pass));
            assert(compare(r, actual, expected) <= 1);
        }
        // Parity with a blank image would prove nothing: the video must have drawn.
        uint8_t pixels[WIDTH * HEIGHT * 4];
        read_pixels(r, actual, pixels);
        int drawn = 0;
        for (size_t i = 0; i < sizeof(pixels); i += 4)
            if (abs(pixels[i] - 28) > 8 || abs(pixels[i + 1] - 59) > 8 || abs(pixels[i + 2] - 94) > 8) drawn++;
        assert(drawn > 4000);
        printf("PASS: external-only %s matches wlroots across transforms and filters\n", deep ? "P010" : "NV12");
    }
    if (texture) wlr_texture_destroy(texture);
    wlr_dmabuf_attributes_finish(&dma);
    gbm_bo_destroy(bo);
    gbm_device_destroy(gbm);
}
static void synchronization(struct rediwm_scene_renderer *r, struct wlr_buffer *buffer) {
    if (!r->has_sync) { puts("SKIP: renderer timelines unavailable"); return; }
    struct wlr_drm_syncobj_timeline *timeline =
        wlr_drm_syncobj_timeline_create(wlr_renderer_get_drm_fd(r->renderer));
    assert(timeline);
    assert(wlr_drm_syncobj_timeline_signal(timeline, 1));
    struct wlr_texture *t = texture_create(r->renderer, false);
    struct wlr_render_pass *base = rediwm_scene_pass_begin(r, buffer,
        &(struct wlr_buffer_pass_options){.signal_timeline = timeline, .signal_point = 2});
    assert(base);
    clear(base);
    wlr_render_pass_add_texture(base, &(struct wlr_render_texture_options){
        .texture = t, .dst_box = {7, 9, TW, TH}, .wait_timeline = timeline, .wait_point = 1,
    });
    assert(wlr_render_pass_submit(base));
    uint8_t pixels[WIDTH * HEIGHT * 4];
    read_pixels(r, buffer, pixels); // finish the submitted GPU work before querying
    bool signaled = false;
    assert(wlr_drm_syncobj_timeline_check(timeline, 2, DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT, &signaled));
    assert(signaled);
    base = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(base);
    // A point that has never materialized must fail closed, without sampling.
    wlr_render_pass_add_texture(base, &(struct wlr_render_texture_options){
        .texture = t, .wait_timeline = timeline, .wait_point = 99,
    });
    assert(!wlr_render_pass_submit(base));
    // Failure released the destination lock and the renderer's active pass.
    base = rediwm_scene_pass_begin(r, buffer, NULL);
    assert(base && wlr_render_pass_submit(base));
    wlr_texture_destroy(t);
    wlr_drm_syncobj_timeline_unref(timeline);
    puts("PASS: acquire/release timeline points and recovery from unavailable acquire");
}
