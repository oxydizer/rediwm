// A tagged NV12 buffer, before and after changing only its representation.
#include <wlr/interfaces/wlr_buffer.h>
struct test_yuv_buffer {
    struct wlr_buffer base;
    struct wlr_dmabuf_attributes dma;
};
static bool test_get_dma(struct wlr_buffer *b, struct wlr_dmabuf_attributes *dma) {
    struct test_yuv_buffer *source = wl_container_of(b, source, base);
    *dma = source->dma;
    return true;
}
static void yuv_levels(struct rediwm_scene_renderer *r, struct wlr_buffer *target,
        struct wlr_texture *texture, const struct wlr_dmabuf_attributes *dma) {
    const struct wlr_buffer_impl impl = {.destroy = wlr_buffer_finish, .get_dmabuf = test_get_dma};
    struct test_yuv_buffer source = {.dma = *dma};
    wlr_buffer_init(&source.base, &impl, dma->width, dma->height);
    struct rediwm_buffer node = {.buffer = &source.base};
    const struct { enum wlr_color_encoding encoding; double kr, kb; } matrices[] = {
        {WLR_COLOR_ENCODING_BT601, .299, .114}, {WLR_COLOR_ENCODING_BT709, .2126, .0722},
        {WLR_COLOR_ENCODING_BT2020, .2627, .0593},
    };
    // The fixture below writes Y=16+(3*x+5*y)%220 at each luma pixel.
    // Four adjacent chroma samples have the same U,V here to remove siting ambiguity.
    for (size_t i = 0; i < 3; i++) for (int full = 0; full <= 1; full++) {
        node.color_encoding = matrices[i].encoding;
        node.color_range = full ? WLR_COLOR_RANGE_FULL : WLR_COLOR_RANGE_LIMITED;
        struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, target, NULL);
        assert(pass);
        rediwm_scene_pass_set_source(pass, &node);
        wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options){
            .texture = texture, .filter_mode = WLR_SCALE_FILTER_NEAREST, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
        assert(wlr_render_pass_submit(pass));
        uint8_t pixels[WIDTH * HEIGHT * 4];
        read_pixels(r, target, pixels);
        const int x = 20, y = 20;
        const double luma = (16. + (3*x + 5*y)%220 - (full ? 0 : 16)) / (full ? 255 : 219);
        const double cb = (96. - 128) / (full ? 255 : 224), cr = (176. - 128) / (full ? 255 : 224);
        const double kr = matrices[i].kr, kb = matrices[i].kb;
        const double red = luma + 2*(1-kr)*cr, blue = luma + 2*(1-kb)*cb;
        const double rgb[] = {red, (luma-kr*red-kb*blue)/(1-kr-kb), blue};
        for (int j = 0; j < 3; j++) {
            int expected = lround(255 * fmin(1, fmax(0, rgb[j])));
            int got = pixels[(WIDTH*y+x)*4+j];
            if (abs(got-expected) > 3) fprintf(stderr, "YCbCr matrix %zu full %d channel %d: %d vs %d\n",
                i, full, j, got, expected);
            assert(abs(got-expected) <= 3);
        }
    }
    wlr_buffer_drop(&source.base);
    printf("PASS: tagged %s uses BT.601, BT.709 and BT.2020, full and limited\n",
        dma->format == DRM_FORMAT_P010 ? "P010" : "NV12");
}
