// The output swapchain while a game tears. An atomic asynchronous flip is
// refused unless the buffer's modifier is in the primary plane's
// IN_FORMATS_ASYNC, which can be narrower than IN_FORMATS (Intel Gen12 takes
// RC_CCS but not RC_CCS_CC or MC_CCS asynchronously). wlroots picks the
// swapchain modifiers from IN_FORMATS alone, and the allocator then takes the
// best one, so every flip of a tearing game was refused. While
// `tearing_buffers` is set the swapchain is rebuilt from the modifiers it
// already allows that the plane also flips asynchronously, and rebuilt with
// the defaults once it is cleared.
#include "scene_output_internal.h"
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <wlr/backend/drm.h>
#include <wlr/render/drm_format_set.h>

static uint64_t plane_property(int fd, uint32_t plane_id, const char *name, bool *found) {
    *found = false;
    uint64_t value = 0;
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, plane_id, DRM_MODE_OBJECT_PLANE);
    if (!props) return 0;
    for (uint32_t i = 0; i < props->count_props && !*found; i++) {
        drmModePropertyRes *prop = drmModeGetProperty(fd, props->props[i]);
        if (!prop) continue;
        if (strcmp(prop->name, name) == 0) {
            value = props->prop_values[i];
            *found = true;
        }
        drmModeFreeProperty(prop);
    }
    drmModeFreeObjectProperties(props);
    return value;
}

static bool add_blob_formats(int fd, uint32_t blob_id, struct wlr_drm_format_set *set) {
    drmModePropertyBlobRes *blob = drmModeGetPropertyBlob(fd, blob_id);
    if (!blob) return false;
    bool ok = false;
    const struct drm_format_modifier_blob *head = blob->data;
    const size_t length = blob->length;
    if (length < sizeof(*head) || head->version != FORMAT_BLOB_CURRENT) goto out;
    if (head->formats_offset > length || head->count_formats > (length - head->formats_offset) / sizeof(uint32_t)) goto out;
    if (head->modifiers_offset > length ||
        head->count_modifiers > (length - head->modifiers_offset) / sizeof(struct drm_format_modifier)) goto out;
    const uint32_t *formats = (const uint32_t *)((const char *)head + head->formats_offset);
    const struct drm_format_modifier *mods =
        (const struct drm_format_modifier *)((const char *)head + head->modifiers_offset);
    for (uint32_t i = 0; i < head->count_modifiers; i++) {
        for (uint32_t bit = 0; bit < 64; bit++) {
            if (!(mods[i].formats & (UINT64_C(1) << bit))) continue;
            const uint64_t index = (uint64_t)mods[i].offset + bit;
            if (index >= head->count_formats) break;
            if (wlr_drm_format_set_add(set, formats[index], mods[i].modifier)) ok = true;
        }
    }
out:
    drmModeFreePropertyBlob(blob);
    return ok;
}

// IN_FORMATS_ASYNC of the primary plane that can drive the output's CRTC.
// False on a backend other than DRM, a kernel without the property, or
// anything the queries refuse.
static bool read_async_formats(struct wlr_output *output, struct wlr_drm_format_set *set) {
    if (!wlr_output_is_drm(output)) return false;
    const int fd = wlr_drm_backend_get_non_master_fd(output->backend);
    if (fd < 0) return false;
    bool ok = false;
    drmModeRes *res = NULL;
    drmModeConnector *conn = NULL;
    drmModeEncoder *enc = NULL;
    drmModePlaneRes *planes = NULL;
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0) goto out;
    res = drmModeGetResources(fd);
    conn = drmModeGetConnectorCurrent(fd, wlr_drm_connector_get_id(output));
    if (!res || !conn || conn->encoder_id == 0) goto out;
    enc = drmModeGetEncoder(fd, conn->encoder_id);
    if (!enc || enc->crtc_id == 0) goto out;
    int crtc_index = -1;
    for (int i = 0; i < res->count_crtcs && i < 32; i++)
        if (res->crtcs[i] == enc->crtc_id) crtc_index = i;
    if (crtc_index < 0) goto out;
    planes = drmModeGetPlaneResources(fd);
    if (!planes) goto out;
    for (uint32_t i = 0; i < planes->count_planes; i++) {
        drmModePlane *plane = drmModeGetPlane(fd, planes->planes[i]);
        if (!plane) continue;
        const bool drives = (plane->possible_crtcs & (1u << crtc_index)) != 0;
        const uint32_t id = plane->plane_id;
        drmModeFreePlane(plane);
        if (!drives) continue;
        bool found;
        if (plane_property(fd, id, "type", &found) != DRM_PLANE_TYPE_PRIMARY || !found) continue;
        const uint64_t blob = plane_property(fd, id, "IN_FORMATS_ASYNC", &found);
        ok = found && blob != 0 && add_blob_formats(fd, (uint32_t)blob, set);
        break;
    }
out:
    if (planes) drmModeFreePlaneResources(planes);
    if (enc) drmModeFreeEncoder(enc);
    if (conn) drmModeFreeConnector(conn);
    if (res) drmModeFreeResources(res);
    close(fd);
    return ok;
}

static bool format_has(const struct wlr_drm_format *format, uint64_t modifier) {
    for (size_t i = 0; i < format->len; i++)
        if (format->modifiers[i] == modifier) return true;
    return false;
}

static bool test_swapchain(struct wlr_output *output, struct wlr_swapchain *swapchain,
        const struct wlr_output_state *state, bool tearing) {
    struct wlr_buffer *buffer = wlr_swapchain_acquire(swapchain);
    if (!buffer) return false;
    struct wlr_output_state copy = *state;
    copy.committed |= WLR_OUTPUT_STATE_BUFFER;
    copy.buffer = buffer;
    copy.tearing_page_flip = tearing;
    const bool ok = wlr_output_test_state(output, &copy);
    wlr_buffer_unlock(buffer);
    return ok;
}

enum async_result { ASYNC_FAILED, ASYNC_ALREADY, ASYNC_REPLACED };

// Replaces output->swapchain (which wlroots just configured) with one limited
// to the modifiers the plane flips asynchronously.
static enum async_result use_async_swapchain(struct wlr_output *output, const struct wlr_output_state *state) {
    struct wlr_swapchain *current = output->swapchain;
    const uint32_t fourcc = current->format.format;
    struct wlr_drm_format_set async = {0};
    if (!read_async_formats(output, &async)) {
        wlr_drm_format_set_finish(&async);
        wlr_log(WLR_INFO, "Output '%s': no asynchronous flip formats to read; tearing buffers unchanged", output->name);
        return ASYNC_FAILED;
    }
    const struct wlr_drm_format *allowed = wlr_drm_format_set_get(&async, fourcc);
    struct wlr_drm_format_set picked = {0};
    size_t kept = 0;
    for (size_t i = 0; allowed && i < current->format.len; i++) {
        if (!format_has(allowed, current->format.modifiers[i])) continue;
        if (wlr_drm_format_set_add(&picked, fourcc, current->format.modifiers[i])) kept++;
    }
    wlr_drm_format_set_finish(&async);
    enum async_result result = ASYNC_FAILED;
    const struct wlr_drm_format *format = wlr_drm_format_set_get(&picked, fourcc);
    if (!format) {
        wlr_log(WLR_INFO, "Output '%s': none of the swapchain's %zu modifiers flips asynchronously",
            output->name, current->format.len);
    } else if (kept == current->format.len) {
        result = ASYNC_ALREADY;
    } else {
        struct wlr_swapchain *swapchain = wlr_swapchain_create(output->allocator, current->width, current->height, format);
        if (swapchain && test_swapchain(output, swapchain, state, false)) {
            wlr_log(WLR_INFO, "Output '%s': tearing buffers use %zu of %zu modifiers (asynchronous flip test %s)",
                output->name, kept, current->format.len,
                test_swapchain(output, swapchain, state, true) ? "passed" : "refused");
            wlr_swapchain_destroy(current);
            output->swapchain = swapchain;
            result = ASYNC_REPLACED;
        } else {
            wlr_log(WLR_INFO, "Output '%s': could not use a swapchain for asynchronous flips", output->name);
            if (swapchain) wlr_swapchain_destroy(swapchain);
        }
    }
    wlr_drm_format_set_finish(&picked);
    return result;
}

bool scene_output_configure_swapchain(struct rediwm_scene_output *out, const struct wlr_output_state *state) {
    struct wlr_output *output = out->output;
    const bool want = out->tearing_buffers && !out->async_unavailable;
    if (out->async_swapchain && !want) {
        // wlroots keeps any swapchain of the right size and format: drop it so
        // the default modifiers (and their compression) come back.
        wlr_swapchain_destroy(output->swapchain);
        output->swapchain = NULL;
        out->async_swapchain = false;
        wlr_log(WLR_DEBUG, "Output '%s': tearing buffers released", output->name);
    }
    struct wlr_swapchain *before = output->swapchain;
    if (!wlr_output_configure_primary_swapchain(output, state, &output->swapchain)) return false;
    if (output->swapchain != before) out->async_swapchain = false;
    if (want && !out->async_swapchain) {
        switch (use_async_swapchain(output, state)) {
        case ASYNC_REPLACED:
        case ASYNC_ALREADY: out->async_swapchain = true; break;
        case ASYNC_FAILED: out->async_unavailable = true; break;
        }
    }
    return true;
}
