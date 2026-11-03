// Use a flat sheet to observe the consuming front independently of its pull.
static void ribbon_minimize(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        const pixman_region32_t *clip) {
    const uint32_t blue = 0xff2040c0;
    struct wlr_texture *texture = wlr_texture_from_pixels(r->renderer, DRM_FORMAT_ARGB8888, 4, 1, 1, &blue);
    assert(texture);
    struct rediwm_ribbon mesh = {.edge = 2, .count = 96,
        .color = {1, 0, 0, 1}, .core_color = {1, .7, .5, 1}};
    for (int i = 0; i < 96; i++) {
        mesh.vertices[i][0] = (i % 2) * 80;
        mesh.vertices[i][1] = (i / 2) * 60.f / 47;
        mesh.vertices[i][2] = i % 2;
        mesh.vertices[i][3] = (i / 2) / 47.f;
    }
    const float progress[] = {0, .18, .4, .68};
    for (int direction = 0; direction < 2; direction++) {
        mesh.fade[1] = direction;
        for (size_t frame = 0; frame < sizeof(progress) / sizeof(progress[0]); frame++) {
            mesh.fade[0] = progress[frame];
            struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buf, NULL);
            assert(pass);
            wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
                .box = {0, 0, WIDTH, HEIGHT}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
            rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 60}, &mesh, clip, 1, texture);
            wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
                .box = {100, 70, 20, 15}, .color = {0, 1, 0, 1}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
            assert(wlr_render_pass_submit(pass));
            uint8_t pixels[WIDTH * HEIGHT * 4];
            read_pixels(r, buf, pixels);
            const int far = direction ? 59 : 20, near = direction ? 20 : 59;
            if (frame == 0) {
                assert(pixels[(far * WIDTH + 50) * 4 + 2] == 192);
                assert(pixels[(near * WIDTH + 50) * 4 + 2] == 192);
            } else if (frame < 3) {
                assert(pixels[(far * WIDTH + 50) * 4 + 2] > 120);
                assert(pixels[(near * WIDTH + 50) * 4 + 3] < 25);
                // Both vertical sides light from the consuming edge only.
                for (int x = 10; x <= 89; x += 79) {
                    assert(pixels[(far * WIDTH + x) * 4] < 60);
                    assert(pixels[(near * WIDTH + x) * 4] > 100);
                }
            } else {
                // The front eats the entire body before the final collapse;
                // only the lit sides may remain outside this interior region.
                for (int y = 10; y < 70; y++)
                    for (int x = 20; x < 80; x++) assert(pixels[(y * WIDTH + x) * 4 + 3] < 8);
                for (int x = 10; x <= 89; x += 79) assert(pixels[(far * WIDTH + x) * 4] > 100);
            }
            assert(pixels[(75 * WIDTH + 110) * 4 + 1] == 255);
            for (size_t i = 0; i < sizeof(pixels); i += 4)
                for (int c = 0; c < 3; c++) assert(pixels[i + c] <= pixels[i + 3]);
        }
    }
    wlr_texture_destroy(texture);
    puts("PASS: minimize consumes the whole sheet and lights both sides with the advancing front");
}

static void ribbon_drag_sheet(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        const pixman_region32_t *clip, struct rediwm_ribbon mesh) {
    mesh.edge = 4;
    mesh.fade[1] = 1;
    for (int frame = 0; frame < 2; frame++) {
        struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buf, NULL);
        assert(pass);
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {0, 0, WIDTH, HEIGHT}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
        rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 60}, &mesh, clip, 1, NULL);
        assert(wlr_render_pass_submit(pass));
        uint8_t pixels[WIDTH * HEIGHT * 4];
        read_pixels(r, buf, pixels);
        int head = pixels[(40 * WIDTH + 85) * 4 + 3];
        int tail = pixels[(40 * WIDTH + 35) * 4 + 3];
        assert(frame == 0 ? (head > tail && tail > 0 && head < 25) : head == 0);
        for (size_t i = 0; i < sizeof(pixels); i += 4)
            for (int c = 0; c < 3; c++) assert(pixels[i + c] <= pixels[i + 3]);
        mesh.fade[1] = 0;
    }
    puts("PASS: drag sheet is faint, graded towards its sources and fades completely");
}

// The optional program must respect damage and leave subsequent quad draws intact.
static void ribbon_gate(struct rediwm_scene_renderer *r, struct wlr_buffer *buf) {
    assert(!r->ribbon.id && !r->ribbon_vertices);
    assert(rediwm_scene_renderer_set_ribbons(r, true));
    assert(rediwm_scene_renderer_set_ribbons(r, true));
    struct rediwm_ribbon mesh = {.count = 4,
        .vertices = {{0, 0, -1, .6}, {0, 20, 1, .6}, {80, 0, -1, .6}, {80, 20, 1, .6}},
        .color = {1, 0, 0, 1}, .core_color = {1, .7, .5, 1}, .fade = {1, 1}};
    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, 30, 0, 10, HEIGHT);
    struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, buf, NULL);
    assert(pass);
    clear(pass);
    rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 20}, &mesh, &clip, 1, NULL);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {50, 50, 30, 20}, .color = {0, 1, 0, 1}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    assert(wlr_render_pass_submit(pass));
    uint8_t pixels[WIDTH * HEIGHT * 4];
    read_pixels(r, buf, pixels);
    int peak = 0;
    for (int y = 10; y < 30; y++) {
        int red = pixels[(y * WIDTH + 35) * 4];
        if (red > peak) peak = red;
    }
    assert(peak > 100); // a folded core, not necessarily at the strip's centre
    assert(abs(pixels[(20 * WIDTH + 25) * 4] - 28) <= 1); // outside damage
    assert(pixels[(60 * WIDTH + 65) * 4 + 1] == 255); // ordinary quad after mesh
    // The border profile has a hot edge and a soft outward halo. Read it over
    // transparency to catch non-premultiplied highlights as well as hard cuts.
    mesh.edge = 1;
    for (int i = 0; i < 4; i++) {
        mesh.vertices[i][2] = i % 2;
        mesh.vertices[i][3] = 1;
    }
    pass = rediwm_scene_pass_begin(r, buf, NULL);
    assert(pass);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, WIDTH, HEIGHT}, .color = {0, 0, 0, 0}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 20}, &mesh, &clip, .8, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, buf, pixels);
    int rim = pixels[(10 * WIDTH + 35) * 4];
    int halo = pixels[(16 * WIDTH + 35) * 4];
    int far = pixels[(29 * WIDTH + 35) * 4];
    assert(rim > 150 && halo > 10 && halo < rim && far < 3);
    for (size_t i = 0; i < sizeof(pixels); i += 4) {
        assert(pixels[i] <= pixels[i + 3] && pixels[i + 1] <= pixels[i + 3] && pixels[i + 2] <= pixels[i + 3]);
    }
    // Two separated, softened sources at the head become one core downstream.
    mesh.edge = 0;
    for (int i = 0; i < 4; i++) {
        mesh.vertices[i][1] = (i % 2) * 60;
        mesh.vertices[i][2] = (i % 2) * 2 - 1;
        mesh.vertices[i][3] = i / 2;
    }
    pixman_region32_union_rect(&clip, &clip, 0, 0, WIDTH, HEIGHT);
    pass = rediwm_scene_pass_begin(r, buf, NULL);
    assert(pass);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, WIDTH, HEIGHT}, .color = {0, 0, 0, 0}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 60}, &mesh, &clip, 1, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, buf, pixels);
    const int columns[] = {35, 85};
    for (int i = 0; i < 2; i++) {
        int peaks = 0;
        bool previous = false;
        for (int y = 10; y < 70; y++) {
            bool hot = pixels[(y * WIDTH + columns[i]) * 4 + 1] > 12;
            if (hot && !previous) peaks++;
            previous = hot;
        }
        assert(peaks == i + 1);
    }
    // A stopped trail erases from its tail (left) towards its sources (right),
    // keeping the surviving head bright until the front reaches it.
    for (int frame = 0; frame < 2; frame++) {
        mesh.fade[1] = frame == 0 ? .5 : 0;
        pass = rediwm_scene_pass_begin(r, buf, NULL);
        assert(pass);
        wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
            .box = {0, 0, WIDTH, HEIGHT}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
        rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 60}, &mesh, &clip, 1, NULL);
        assert(wlr_render_pass_submit(pass));
        read_pixels(r, buf, pixels);
        int head = 0;
        for (int y = 10; y < 70; y++) {
            assert(pixels[(y * WIDTH + 35) * 4 + 3] == 0);
            int alpha = pixels[(y * WIDTH + 85) * 4 + 3];
            if (alpha > head) head = alpha;
        }
        assert(frame == 0 ? head > 100 : head == 0);
    }
    puts("PASS: stopped ribbons erase from tail to head");
    ribbon_drag_sheet(r, buf, &clip, mesh);
    ribbon_minimize(r, buf, &clip);
    mesh.edge = 3;
    mesh.count = 4;
    mesh.fade[0] = 1;
    mesh.fade[1] = 0;
    for (int i = 0; i < 4; i++) {
        mesh.vertices[i][0] = (i % 2) * 80;
        mesh.vertices[i][1] = (i / 2) * 60;
        mesh.vertices[i][2] = (i % 2) * 2 - 1;
        mesh.vertices[i][3] = i / 2;
    }
    pass = rediwm_scene_pass_begin(r, buf, NULL);
    assert(pass);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, WIDTH, HEIGHT}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
    rediwm_scene_pass_add_ribbon(pass, (struct wlr_box){10, 10, 80, 60}, &mesh, &clip, 1, NULL);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, buf, pixels);
    assert(pixels[(40 * WIDTH + 50) * 4] > 15); // translucent rectangular band
    // The resize sheet must reach BOTH outlines. The trail's edge fade used
    // to leave transparent gutters here, increasingly wide on large resizes.
    for (int y = 10; y < 70; y++) {
        for (int x = 10; x < 90; x++) {
            assert(pixels[(y * WIDTH + x) * 4 + 3] >= 50);
        }
    }
    for (size_t i = 0; i < sizeof(pixels); i += 4)
        for (int c = 0; c < 3; c++) assert(pixels[i + c] <= pixels[i + 3]);
    assert(rediwm_scene_renderer_set_ribbons(r, false));
    assert(!r->ribbon.id && !r->ribbon_vertices);
    assert(rediwm_scene_renderer_set_ribbons(r, false));
    pixman_region32_fini(&clip);
    puts("PASS: two ribbon sources merge, respect damage, restore quad state and release GPU resources");
}
