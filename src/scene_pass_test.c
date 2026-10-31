// Compare the actual owned drawing backend with wlroots, independently of
// scene traversal and output policy. A noninstalled, real-GPU fixture.
#include "scene_pass.c"
#include "scene_pass_draw.c"
#include "scene_pass_backdrop.c"
#include "scene_graph.h"
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <drm_fourcc.h>
#include <drm.h>
#include <gbm.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/render/allocator.h>
#include <wlr/render/drm_format_set.h>

enum { WIDTH = 127, HEIGHT = 93, TW = 23, TH = 17 };
static struct wlr_buffer *target(struct wlr_allocator *allocator) {
    uint64_t modifier = DRM_FORMAT_MOD_INVALID;
    struct wlr_drm_format format = {
        .format = DRM_FORMAT_ARGB8888, .len = 1, .capacity = 1, .modifiers = &modifier,
    };
    struct wlr_buffer *b = wlr_allocator_create_buffer(allocator, WIDTH, HEIGHT, &format);
    assert(b);
    return b;
}
static void read_pixels(struct rediwm_scene_renderer *r, struct wlr_buffer *b, uint8_t *pixels) {
    struct gl_state state;
    assert(scene_pass_enter(r, &state));
    glBindFramebuffer(GL_FRAMEBUFFER, wlr_gles2_renderer_get_buffer_fbo(r->renderer, b));
    glReadPixels(0, 0, WIDTH, HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    assert(glGetError() == GL_NO_ERROR);
    scene_pass_leave(r, &state);
}
static int compare(struct rediwm_scene_renderer *r, struct wlr_buffer *a, struct wlr_buffer *b) {
    uint8_t actual[WIDTH * HEIGHT * 4], expected[sizeof(actual)];
    read_pixels(r, a, actual);
    read_pixels(r, b, expected);
    int worst = 0;
    for (size_t i = 0; i < sizeof(actual); i++) {
        int d = abs(actual[i] - expected[i]);
        if (d > worst) worst = d;
    }
    return worst;
}
static void clear(struct wlr_render_pass *pass) {
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = {0, 0, WIDTH, HEIGHT}, .color = {.11, .23, .37, 1},
        .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
    });
}
// With a shape the owned pass draws through its shaped programs; wlroots' pass,
// which has no such thing, is always given NULL.
static void paint(struct wlr_render_pass *pass, struct wlr_texture *texture,
        int transform, int filter, int crop, float alpha, const pixman_region32_t *clip,
        const struct rediwm_pass_shape *shape) {
    struct wlr_render_rect_options rects[2] = {
        {.box = {8, -7, 49, 63}, .color = {.3, .06, .17, .5}, .clip = clip},
        {.box = {41, 29, 37, 53}, .color = {.1, .2, .05, .4}, .clip = clip},
    };
    struct wlr_render_texture_options t = {
        .texture = texture, .dst_box = {-3, 11, 112, 77},
        .src_box = crop ? (struct wlr_fbox){2.25, 3.5, 16.5, 11.25} : (struct wlr_fbox){0},
        .transform = transform, .filter_mode = filter, .alpha = &alpha, .clip = clip,
    };
    if (shape) rediwm_scene_pass_add_rect_shaped(pass, &rects[0], shape);
    else wlr_render_pass_add_rect(pass, &rects[0]);
    if (shape) rediwm_scene_pass_add_texture_shaped(pass, &t, shape);
    else wlr_render_pass_add_texture(pass, &t);
    if (shape) rediwm_scene_pass_add_rect_shaped(pass, &rects[1], shape);
    else wlr_render_pass_add_rect(pass, &rects[1]);
}
static struct wlr_texture *texture_create(struct wlr_renderer *renderer, bool opaque) {
    uint32_t pixels[TW * TH];
    for (int y = 0; y < TH; y++) for (int x = 0; x < TW; x++) {
        unsigned a = opaque ? (x * 47 + y * 19) % 256 : 80 + (x * 11 + y * 17) % 176;
        unsigned limit = opaque ? 256 : a + 1;
        pixels[y * TW + x] = a << 24 | ((x * 13 + y * 3) % limit) << 16 |
            ((x * 3 + y * 13) % limit) << 8 | ((x * 7 + y * 11) % limit);
    }
    struct wlr_texture *t = wlr_texture_from_pixels(renderer,
        opaque ? DRM_FORMAT_XRGB8888 : DRM_FORMAT_ARGB8888, TW * 4, TW, TH, pixels);
    assert(t);
    return t;
}
// `shaped` runs every case through the shaped programs, with a shape that covers
// the whole buffer and has no corners: it must still equal wlroots exactly.

#include "scene_pass_test_parity.c"
#include "scene_pass_test_shapes.c"
#include "scene_pass_test_shading.c"
#include "scene_pass_test_backdrop.c"

int main(void) {
    wlr_log_init(WLR_ERROR, NULL);
    struct wl_display *display = wl_display_create();
    assert(display);
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
    assert(backend);
    struct wlr_renderer *renderer = wlr_renderer_autocreate(backend);
    assert(renderer && wlr_renderer_is_gles2(renderer));
    struct wlr_allocator *allocator = wlr_allocator_autocreate(backend, renderer);
    assert(allocator);
    struct rediwm_scene_renderer *r = rediwm_scene_renderer_create(renderer);
    assert(r);
    assert(rediwm_scene_renderer_enable_external(r));
    assert(rediwm_scene_renderer_enable_external(r)); // idempotent
    struct wlr_buffer *actual = target(allocator), *expected = target(allocator);
    parity(r, actual, expected, false);
    shapes_fail_closed(r, actual);
    assert(rediwm_scene_renderer_enable_shapes(r));
    assert(rediwm_scene_renderer_enable_shapes(r)); // idempotent
    parity(r, actual, expected, true);
    damage(r, actual, expected);
    state_restoration(r, actual);
    external_texture(r, allocator, actual, expected);
    external_yuv(r, actual, expected);
    synchronization(r, actual);
    shaped_gates(r, allocator);
    assert(rediwm_scene_renderer_enable_backdrops(r));
    assert(rediwm_scene_renderer_enable_backdrops(r)); // idempotent
    backdrop_gates(r, allocator);
    // The ordinary wlroots pass must still work after owned GL has run.
    parity(r, actual, expected, false);
    if (r->has_vao) {
        // Exercise the GLES2 fallback even on hosts with vertex arrays.
        r->has_vao = false;
        parity(r, actual, expected, false);
        parity(r, actual, expected, true);
        state_restoration(r, actual);
        r->has_vao = true;
    }
    rediwm_scene_renderer_destroy(r);
    wlr_buffer_drop(actual);
    wlr_buffer_drop(expected);
    wlr_allocator_destroy(allocator);
    wlr_renderer_destroy(renderer);
    wlr_backend_destroy(backend);
    wl_display_destroy(display);
    puts("scene pass gates passed");
    return 0;
}
