// SDR captures of outputs that blend in linear light (docs/plans/hdr.md, phase 5);
// see capture_sdr.h. Both hooks reach into wlroots 0.20 objects: an output
// source's public `impl`, and a screencopy frame's private commit listener.
// Re-check both after a wlroots update.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "capture_sdr.h"
#include "scene_output.h"
#include "scene_outputs.h"
#include "wlr-screencopy-unstable-v1-protocol.h"
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <wlr/interfaces/wlr_ext_image_capture_source_v1.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_ext_image_capture_source_v1.h>
#include <wlr/types/wlr_ext_image_copy_capture_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/util/log.h>

struct wrapped {
    struct wl_list link; // rediwm_capture_sdr.wrapped
    struct wlr_ext_image_capture_source_v1 *source;
    struct wlr_output *output;
    const struct wlr_ext_image_capture_source_v1_interface *original;
    struct wl_listener destroy;
};
struct rediwm_capture_sdr {
    struct rediwm_output_renderer *renderer;
    struct rediwm_scene_outputs *outputs;
    struct wl_list wrapped;
};

// Captures served from an SDR encode (`rediwm-msg perf`: capture_sdr_copies).
uint64_t rediwm_capture_sdr_copies;
// The screencopy hook is a bare wl_listener: it finds the context here.
static struct rediwm_capture_sdr *instance;
// wlroots' own handler of a screencopy frame's output commit, kept from the
// first frame taken (every frame has the same one).
static wl_notify_func_t wlroots_screencopy_commit;

static struct wlr_buffer *sdr_for(struct wlr_output *output) {
    if (!instance) return NULL;
    struct rediwm_scene_output *out = rediwm_scene_outputs_get(instance->outputs, output);
    return out ? rediwm_scene_output_sdr_copy(instance->renderer, out) : NULL;
}
static struct wrapped *find(struct wlr_ext_image_capture_source_v1 *source) {
    if (!instance) return NULL;
    struct wrapped *w;
    wl_list_for_each(w, &instance->wrapped, link) if (w->source == source) return w;
    return NULL;
}
static void now(struct timespec *when) {
    clock_gettime(CLOCK_MONOTONIC, when);
}

// ---- ext-image-copy-capture: a wrapped wlroots output source -------------------
static void wrapped_start(struct wlr_ext_image_capture_source_v1 *source, bool with_cursors) {
    struct wrapped *w = find(source);
    if (w && w->original->start) w->original->start(source, with_cursors);
}
static void wrapped_stop(struct wlr_ext_image_capture_source_v1 *source) {
    struct wrapped *w = find(source);
    if (w && w->original->stop) w->original->stop(source);
}
static void wrapped_request_frame(struct wlr_ext_image_capture_source_v1 *source, bool schedule_frame) {
    struct wrapped *w = find(source);
    if (w && w->original->request_frame) w->original->request_frame(source, schedule_frame);
}
// Called while the output commits, so the linear image is that commit's frame.
static void wrapped_copy_frame(struct wlr_ext_image_capture_source_v1 *source,
        struct wlr_ext_image_copy_capture_frame_v1 *frame, struct wlr_ext_image_capture_source_v1_frame_event *event) {
    struct wrapped *w = find(source);
    if (!w) return;
    struct wlr_buffer *sdr = sdr_for(w->output);
    if (!sdr) {
        w->original->copy_frame(source, frame, event);
        return;
    }
    if (!wlr_ext_image_copy_capture_frame_v1_copy_buffer(frame, sdr, w->output->renderer)) return;
    rediwm_capture_sdr_copies++;
    struct timespec when;
    now(&when);
    wlr_ext_image_copy_capture_frame_v1_ready(frame, w->output->transform, &when);
}
static struct wlr_ext_image_capture_source_v1_cursor *wrapped_get_pointer_cursor(
        struct wlr_ext_image_capture_source_v1 *source, struct wlr_seat *seat) {
    struct wrapped *w = find(source);
    return w && w->original->get_pointer_cursor ? w->original->get_pointer_cursor(source, seat) : NULL;
}
static const struct wlr_ext_image_capture_source_v1_interface wrapped_impl = {
    .start = wrapped_start,
    .stop = wrapped_stop,
    .request_frame = wrapped_request_frame,
    .copy_frame = wrapped_copy_frame,
    .get_pointer_cursor = wrapped_get_pointer_cursor,
};
static void wrapped_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct wrapped *w = wl_container_of(listener, w, destroy);
    wl_list_remove(&w->destroy.link);
    wl_list_remove(&w->link);
    free(w);
}
void rediwm_capture_sdr_wrap_source(struct rediwm_capture_sdr *c, struct wlr_ext_image_capture_source_v1 *source) {
    if (find(source) || source->impl == &wrapped_impl) return;
    struct wlr_output *output = wlr_output_try_from_ext_image_capture_source_v1(source);
    if (!output) return;
    struct wrapped *w = calloc(1, sizeof(*w));
    if (!w) return;
    w->source = source;
    w->output = output;
    w->original = source->impl;
    w->destroy.notify = wrapped_destroyed;
    wl_signal_add(&source->events.destroy, &w->destroy);
    wl_list_insert(&c->wrapped, &w->link);
    source->impl = &wrapped_impl;
}
struct wlr_output *rediwm_capture_sdr_source_output(struct rediwm_capture_sdr *c, struct wlr_ext_image_capture_source_v1 *source) {
    (void)c;
    struct wrapped *w = find(source);
    return w ? w->output : wlr_output_try_from_ext_image_capture_source_v1(source);
}

// ---- wlr-screencopy: a taken frame ------------------------------------------
static bool copy_into(struct wlr_screencopy_frame_v1 *frame, struct wlr_buffer *sdr) {
    struct wlr_renderer *renderer = frame->output->renderer;
    struct wlr_texture *texture = wlr_texture_from_buffer(renderer, sdr);
    if (!texture) return false;
    bool ok = false;
    const struct wlr_box *box = &frame->box;
    if (frame->buffer_cap == WLR_BUFFER_CAP_DATA_PTR) {
        void *data;
        uint32_t format;
        size_t stride;
        if (wlr_buffer_begin_data_ptr_access(frame->buffer, WLR_BUFFER_DATA_PTR_ACCESS_WRITE, &data, &format, &stride)) {
            ok = format == frame->shm_format && wlr_texture_read_pixels(texture, &(struct wlr_texture_read_pixels_options){
                .data = data, .format = format, .stride = (uint32_t)stride,
                .src_box = {box->x, box->y, box->width, box->height}});
            wlr_buffer_end_data_ptr_access(frame->buffer);
        }
    } else if (frame->buffer_cap == WLR_BUFFER_CAP_DMABUF) {
        struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, frame->buffer, NULL);
        if (pass) {
            wlr_render_pass_add_texture(pass, &(struct wlr_render_texture_options){
                .texture = texture, .src_box = {box->x, box->y, box->width, box->height},
                .dst_box = {0, 0, box->width, box->height}, .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
            ok = wlr_render_pass_submit(pass);
        }
    }
    wlr_texture_destroy(texture);
    return ok;
}
// Replaces wlroots' handler for a taken frame: the commit's frame as SDR.
static void taken_commit(struct wl_listener *listener, void *data) {
    struct wlr_screencopy_frame_v1 *frame = wl_container_of(listener, frame, WLR_PRIVATE.output_commit);
    struct wlr_output_event_commit *event = data;
    if (!(event->state->committed & WLR_OUTPUT_STATE_BUFFER) || !frame->buffer) return;
    struct wlr_buffer *sdr = sdr_for(frame->output);
    if (!sdr) {
        // Not linear (any more): wlroots copies the committed buffer itself.
        if (wlroots_screencopy_commit) wlroots_screencopy_commit(listener, data);
        return;
    }
    // Done with this frame whatever happens: wlroots frees it when the client
    // destroys it, and must not copy into it again.
    wl_list_remove(&listener->link);
    wl_list_init(&listener->link);
    if (!copy_into(frame, sdr)) {
        zwlr_screencopy_frame_v1_send_failed(frame->resource);
        return;
    }
    rediwm_capture_sdr_copies++;
    zwlr_screencopy_frame_v1_send_flags(frame->resource, 0);
    if (frame->with_damage && wl_resource_get_version(frame->resource) >= ZWLR_SCREENCOPY_FRAME_V1_DAMAGE_SINCE_VERSION)
        zwlr_screencopy_frame_v1_send_damage(frame->resource, 0, 0, (uint32_t)frame->box.width, (uint32_t)frame->box.height);
    const uint64_t sec = (uint64_t)event->when.tv_sec;
    zwlr_screencopy_frame_v1_send_ready(frame->resource, (uint32_t)(sec >> 32), (uint32_t)sec, (uint32_t)event->when.tv_nsec);
}
void rediwm_capture_sdr_take_screencopy(struct rediwm_capture_sdr *c, struct wlr_screencopy_frame_v1 *frame) {
    (void)c;
    struct wl_listener *listener = &frame->WLR_PRIVATE.output_commit;
    if (listener->notify == taken_commit || !frame->buffer) return;
    if (!wlroots_screencopy_commit) wlroots_screencopy_commit = listener->notify;
    else if (listener->notify != wlroots_screencopy_commit) {
        wlr_log(WLR_ERROR, "screencopy frame with an unknown commit handler; left to wlroots");
        return;
    }
    listener->notify = taken_commit;
}

struct rediwm_capture_sdr *rediwm_capture_sdr_create(struct rediwm_output_renderer *renderer, struct rediwm_scene_outputs *outputs) {
    if (instance) return NULL;
    struct rediwm_capture_sdr *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->renderer = renderer;
    c->outputs = outputs;
    wl_list_init(&c->wrapped);
    instance = c;
    return c;
}
void rediwm_capture_sdr_destroy(struct rediwm_capture_sdr *c) {
    if (!c) return;
    struct wrapped *w, *next;
    wl_list_for_each_safe(w, next, &c->wrapped, link) {
        w->source->impl = w->original;
        wl_list_remove(&w->destroy.link);
        wl_list_remove(&w->link);
        free(w);
    }
    if (instance == c) instance = NULL;
    free(c);
}
