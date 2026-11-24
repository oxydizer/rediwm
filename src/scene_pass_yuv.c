// External samplers return RGB. Supply the client's coefficients and range at
// EGLImage import, before the driver converts/clamps the samples. The original
// buffer, plane layout, modifier and acquire/release synchronization stay intact.
#include "scene_pass_internal.h"
#include "node.h"
#include <drm_fourcc.h>

struct yuv_image {
    struct wlr_addon addon;
    struct wl_list link;
    EGLDisplay display;
    EGLImageKHR image;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image;
    enum wlr_color_encoding encoding;
    enum wlr_color_range range;
};
static void yuv_destroy(struct wlr_addon *addon) {
    struct yuv_image *y = wl_container_of(addon, y, addon);
    y->destroy_image(y->display, y->image);
    wlr_addon_finish(addon);
    wl_list_remove(&y->link);
    free(y);
}
static const struct wlr_addon_interface yuv_impl = {"rediwm-ycbcr", yuv_destroy};
void scene_pass_yuv_finish(struct rediwm_scene_renderer *r) {
    struct yuv_image *y, *next;
    wl_list_for_each_safe(y, next, &r->yuv_images, link) yuv_destroy(&y->addon);
}

static EGLImageKHR import_yuv(PFNEGLCREATEIMAGEKHRPROC create_image, EGLDisplay display, const struct wlr_dmabuf_attributes *d,
        enum wlr_color_encoding encoding, enum wlr_color_range range) {
    static const EGLint plane_fd[] = {EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
        EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT};
    static const EGLint mod_lo[] = {EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
        EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT};
    // EGL specifies offset and pitch immediately after each plane's fd token.
    EGLint attrs[11 + WLR_DMABUF_MAX_PLANES * 10] = {
        EGL_WIDTH, d->width, EGL_HEIGHT, d->height, EGL_LINUX_DRM_FOURCC_EXT, d->format,
        EGL_YUV_COLOR_SPACE_HINT_EXT, encoding == WLR_COLOR_ENCODING_BT2020 ? EGL_ITU_REC2020_EXT :
            encoding == WLR_COLOR_ENCODING_BT709 ? EGL_ITU_REC709_EXT : EGL_ITU_REC601_EXT,
        EGL_SAMPLE_RANGE_HINT_EXT, range == WLR_COLOR_RANGE_FULL ? EGL_YUV_FULL_RANGE_EXT : EGL_YUV_NARROW_RANGE_EXT,
    };
    if (d->n_planes < 1 || d->n_planes > WLR_DMABUF_MAX_PLANES) return EGL_NO_IMAGE_KHR;
    const bool modifiers = d->modifier != DRM_FORMAT_MOD_INVALID &&
        strstr(eglQueryString(display, EGL_EXTENSIONS), "EGL_EXT_image_dma_buf_import_modifiers") != NULL;
    if (!modifiers && (d->n_planes == 4 ||
            (d->modifier != DRM_FORMAT_MOD_INVALID && d->modifier != DRM_FORMAT_MOD_LINEAR))) return EGL_NO_IMAGE_KHR;
    size_t n = 10;
    for (int i = 0; i < d->n_planes; i++) {
        attrs[n++] = plane_fd[i]; attrs[n++] = d->fd[i];
        attrs[n++] = plane_fd[i] + 1; attrs[n++] = d->offset[i];
        attrs[n++] = plane_fd[i] + 2; attrs[n++] = d->stride[i];
        if (modifiers) {
            attrs[n++] = mod_lo[i]; attrs[n++] = (uint32_t)d->modifier;
            attrs[n++] = mod_lo[i] + 1; attrs[n++] = (uint32_t)(d->modifier >> 32);
        }
    }
    attrs[n] = EGL_NONE;
    return create_image(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
}

bool scene_pass_yuv_texture(struct pass *p, struct wlr_gles2_texture_attribs *texture) {
    const struct rediwm_buffer *b = p->source;
    if (b->color_encoding == WLR_COLOR_ENCODING_NONE || b->color_encoding == WLR_COLOR_ENCODING_IDENTITY)
        return true;
    if (!b->buffer) return false;
    struct wlr_addon *addon = wlr_addon_find(&b->buffer->addons, p->renderer, &yuv_impl);
    struct yuv_image *y = addon ? wl_container_of(addon, y, addon) : NULL;
    if (!y || y->encoding != b->color_encoding || y->range != b->color_range) {
        struct wlr_dmabuf_attributes dma;
        if (!wlr_buffer_get_dmabuf(b->buffer, &dma)) return false;
        PFNEGLCREATEIMAGEKHRPROC create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
        PFNEGLDESTROYIMAGEKHRPROC destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
        if (!create_image || !destroy_image) return false;
        EGLImageKHR image = import_yuv(create_image, p->state.display, &dma, b->color_encoding, b->color_range);
        if (image == EGL_NO_IMAGE_KHR) return false;
        if (!y) {
            y = calloc(1, sizeof(*y));
            if (!y) { destroy_image(p->state.display, image); return false; }
            wlr_addon_init(&y->addon, &b->buffer->addons, p->renderer, &yuv_impl);
            wl_list_insert(&p->renderer->yuv_images, &y->link);
        } else {
            y->destroy_image(y->display, y->image);
        }
        y->display = p->state.display;
        y->image = image;
        y->destroy_image = destroy_image;
        y->encoding = b->color_encoding;
        y->range = b->color_range;
    }
    if (!p->yuv_texture) glGenTextures(1, &p->yuv_texture);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, p->yuv_texture);
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bind_image =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    if (!bind_image) return false;
    bind_image(GL_TEXTURE_EXTERNAL_OES, y->image);
    if (glGetError() != GL_NO_ERROR) return false;
    texture->target = GL_TEXTURE_EXTERNAL_OES;
    texture->tex = p->yuv_texture;
    return true;
}
