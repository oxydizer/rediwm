// One timer service per renderer/context, shared by all outputs. Timestamp
// pairs can bracket wlroots passes without nesting GL_TIME_ELAPSED queries.
#define WLR_USE_UNSTABLE
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>

#define SLOTS 8
struct gpu_sample { uint64_t ns, generation; };
struct query_pair {
    GLuint ids[2];
    bool pending;
    uint64_t generation;
    unsigned age;
};
struct gpu_timer {
    struct wlr_egl *egl;
    struct query_pair slots[SLOTS];
    int active;
    PFNGLGENQUERIESEXTPROC gen;
    PFNGLDELETEQUERIESEXTPROC del;
    PFNGLQUERYCOUNTEREXTPROC counter;
    PFNGLGETQUERYOBJECTUIVEXTPROC available;
    PFNGLGETQUERYOBJECTUI64VEXTPROC result;
};
struct saved_context {
    EGLDisplay display;
    EGLContext context;
    EGLSurface draw, read;
};
static bool enter(struct gpu_timer *timer, struct saved_context *saved) {
    saved->display = eglGetCurrentDisplay();
    saved->context = eglGetCurrentContext();
    saved->draw = eglGetCurrentSurface(EGL_DRAW);
    saved->read = eglGetCurrentSurface(EGL_READ);
    return eglMakeCurrent(wlr_egl_get_display(timer->egl), EGL_NO_SURFACE,
        EGL_NO_SURFACE, wlr_egl_get_context(timer->egl));
}
static void leave(struct gpu_timer *timer, const struct saved_context *saved) {
    if (saved->context != EGL_NO_CONTEXT)
        eglMakeCurrent(saved->display, saved->draw, saved->read, saved->context);
    else
        eglMakeCurrent(wlr_egl_get_display(timer->egl), EGL_NO_SURFACE,
            EGL_NO_SURFACE, EGL_NO_CONTEXT);
}
static bool has_extension(const char *extensions, const char *name) {
    if (!extensions) return false;
    size_t len = strlen(name);
    const char *p = extensions;
    while ((p = strstr(p, name))) {
        if ((p == extensions || p[-1] == ' ') && (p[len] == ' ' || p[len] == '\0'))
            return true;
        p += len;
    }
    return false;
}
struct gpu_timer *rediwm_gpu_timer_create(struct wlr_renderer *renderer) {
    if (!wlr_renderer_is_gles2(renderer)) return NULL;
    struct gpu_timer *timer = calloc(1, sizeof(*timer));
    if (!timer) return NULL;
    timer->egl = wlr_gles2_renderer_get_egl(renderer);
    timer->active = -1;
    struct saved_context saved;
    if (!enter(timer, &saved)) { free(timer); return NULL; }
    bool supported = has_extension((const char *)glGetString(GL_EXTENSIONS),
        "GL_EXT_disjoint_timer_query");
    timer->gen = (PFNGLGENQUERIESEXTPROC)eglGetProcAddress("glGenQueriesEXT");
    timer->del = (PFNGLDELETEQUERIESEXTPROC)eglGetProcAddress("glDeleteQueriesEXT");
    timer->counter = (PFNGLQUERYCOUNTEREXTPROC)eglGetProcAddress("glQueryCounterEXT");
    timer->available = (PFNGLGETQUERYOBJECTUIVEXTPROC)eglGetProcAddress("glGetQueryObjectuivEXT");
    timer->result = (PFNGLGETQUERYOBJECTUI64VEXTPROC)eglGetProcAddress("glGetQueryObjectui64vEXT");
    PFNGLGETQUERYIVEXTPROC query = (PFNGLGETQUERYIVEXTPROC)eglGetProcAddress("glGetQueryivEXT");
    supported = supported && timer->gen && timer->del && timer->counter &&
        timer->available && timer->result && query;
    GLint bits = 0;
    if (supported) query(GL_TIMESTAMP_EXT, GL_QUERY_COUNTER_BITS_EXT, &bits);
    // Smaller counters may wrap more than once during a long GPU stall.
    supported = supported && bits == 64;
    if (supported) {
        // Establish a disjoint baseline before issuing any timestamp.
        GLint ignored;
        glGetIntegerv(GL_GPU_DISJOINT_EXT, &ignored);
        for (unsigned i = 0; i < SLOTS; ++i) timer->gen(2, timer->slots[i].ids);
    }
    leave(timer, &saved);
    if (!supported) { free(timer); return NULL; }
    return timer;
}
void rediwm_gpu_timer_destroy(struct gpu_timer *timer) {
    struct saved_context saved;
    if (enter(timer, &saved)) {
        for (unsigned i = 0; i < SLOTS; ++i) timer->del(2, timer->slots[i].ids);
        leave(timer, &saved);
    }
    free(timer);
}
bool rediwm_gpu_timer_begin(struct gpu_timer *timer, uint64_t generation) {
    if (timer->active >= 0) return false;
    unsigned slot;
    for (slot = 0; slot < SLOTS && timer->slots[slot].pending; ++slot) {}
    if (slot == SLOTS) return false; // Never wait for a busy GPU.
    struct saved_context saved;
    if (!enter(timer, &saved)) return false;
    struct query_pair *pair = &timer->slots[slot];
    pair->generation = generation;
    pair->age = 0;
    timer->counter(pair->ids[0], GL_TIMESTAMP_EXT);
    timer->active = (int)slot;
    leave(timer, &saved);
    return true;
}
void rediwm_gpu_timer_end(struct gpu_timer *timer) {
    if (timer->active < 0) return;
    struct saved_context saved;
    struct query_pair *pair = &timer->slots[timer->active];
    if (enter(timer, &saved)) {
        timer->counter(pair->ids[1], GL_TIMESTAMP_EXT);
        pair->pending = true;
        // Submit the trailing timestamp, without waiting for execution.
        glFlush();
        leave(timer, &saved);
    }
    timer->active = -1;
}
static void recycle(struct gpu_timer *timer, struct query_pair *pair) {
    timer->del(2, pair->ids);
    timer->gen(2, pair->ids);
    pair->pending = false;
}
size_t rediwm_gpu_timer_collect(struct gpu_timer *timer, uint64_t generation,
        struct gpu_sample samples[SLOTS], uint64_t *dropped) {
    struct saved_context saved;
    if (!enter(timer, &saved)) return 0;
    GLint disjoint = 0;
    glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
    size_t count = 0;
    for (unsigned i = 0; i < SLOTS; ++i) {
        struct query_pair *pair = &timer->slots[i];
        if (!pair->pending) continue;
        if (disjoint || pair->generation != generation || ++pair->age > 120) {
            if (pair->generation == generation) ++*dropped;
            recycle(timer, pair);
            continue;
        }
        GLuint start_ready = 0, end_ready = 0;
        timer->available(pair->ids[0], GL_QUERY_RESULT_AVAILABLE_EXT, &start_ready);
        timer->available(pair->ids[1], GL_QUERY_RESULT_AVAILABLE_EXT, &end_ready);
        if (!start_ready || !end_ready) continue;
        GLuint64 start = 0, end = 0;
        timer->result(pair->ids[0], GL_QUERY_RESULT_EXT, &start);
        timer->result(pair->ids[1], GL_QUERY_RESULT_EXT, &end);
        pair->pending = false;
        // Drop timestamp wrap instead of publishing a bogus large duration.
        if (end >= start) samples[count++] = (struct gpu_sample){end - start, pair->generation};
        else ++*dropped;
    }
    // A disjoint event may happen while results are being collected, too.
    glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
    if (disjoint) {
        *dropped += count;
        count = 0;
        for (unsigned i = 0; i < SLOTS; ++i) {
            if (timer->slots[i].pending) {
                if (timer->slots[i].generation == generation) ++*dropped;
                recycle(timer, &timer->slots[i]);
            }
        }
    }
    leave(timer, &saved);
    return count;
}
