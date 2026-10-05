// Deterministic fake driver: test query lifetimes and nonblocking reads without
// requiring a GPU. Real-renderer coverage lives in tests/perf.py (gles2 mode).
#include <assert.h>
#include "gpu_timing.c"

static bool is_gles = true, ready = false, extension = true;
static unsigned next_id = 1, live_queries, result_reads;
static unsigned disjoint_call, disjoint_at;
static uint64_t clock_ns, values[4096];
static GLint counter_bits = 64;
static EGLContext current = (EGLContext)(uintptr_t)7;
static const EGLContext renderer_context = (EGLContext)(uintptr_t)8;

bool wlr_renderer_is_gles2(struct wlr_renderer *renderer) { (void)renderer; return is_gles; }
struct wlr_egl *wlr_gles2_renderer_get_egl(struct wlr_renderer *renderer) {
    (void)renderer; return (struct wlr_egl *)(uintptr_t)1;
}
EGLDisplay wlr_egl_get_display(struct wlr_egl *egl) { (void)egl; return (EGLDisplay)(uintptr_t)2; }
EGLContext wlr_egl_get_context(struct wlr_egl *egl) { (void)egl; return renderer_context; }
EGLDisplay eglGetCurrentDisplay(void) { return (EGLDisplay)(uintptr_t)2; }
EGLContext eglGetCurrentContext(void) { return current; }
EGLSurface eglGetCurrentSurface(EGLint which) { (void)which; return EGL_NO_SURFACE; }
EGLBoolean eglMakeCurrent(EGLDisplay display, EGLSurface draw, EGLSurface read, EGLContext context) {
    (void)display; (void)draw; (void)read; current = context; return EGL_TRUE;
}
const GLubyte *glGetString(GLenum name) {
    assert(name == GL_EXTENSIONS);
    return (const GLubyte *)(extension ? "GL_EXT_disjoint_timer_query" : "");
}
void glGetIntegerv(GLenum name, GLint *out) {
    assert(name == GL_GPU_DISJOINT_EXT);
    *out = ++disjoint_call == disjoint_at;
}
void glFlush(void) {}
static void fake_gen(GLsizei n, GLuint *ids) {
    for (int i = 0; i < n; ++i) { ids[i] = next_id++; ++live_queries; }
    assert(next_id < 4096);
}
static void fake_del(GLsizei n, const GLuint *ids) {
    (void)ids; assert(live_queries >= (unsigned)n); live_queries -= n;
}
static void fake_counter(GLuint id, GLenum target) {
    assert(current == renderer_context && target == GL_TIMESTAMP_EXT);
    values[id] = clock_ns += 1000000;
}
static void fake_available(GLuint id, GLenum name, GLuint *out) {
    (void)id; assert(name == GL_QUERY_RESULT_AVAILABLE_EXT); *out = ready;
}
static void fake_result(GLuint id, GLenum name, GLuint64 *out) {
    assert(ready && name == GL_QUERY_RESULT_EXT); ++result_reads; *out = values[id];
}
static void fake_query(GLenum target, GLenum name, GLint *out) {
    assert(target == GL_TIMESTAMP_EXT && name == GL_QUERY_COUNTER_BITS_EXT); *out = counter_bits;
}
__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name) {
#define PROC(n, fn) if (!strcmp(name, n)) return (__eglMustCastToProperFunctionPointerType)fn
    PROC("glGenQueriesEXT", fake_gen);
    PROC("glDeleteQueriesEXT", fake_del);
    PROC("glQueryCounterEXT", fake_counter);
    PROC("glGetQueryObjectuivEXT", fake_available);
    PROC("glGetQueryObjectui64vEXT", fake_result);
    PROC("glGetQueryivEXT", fake_query);
#undef PROC
    return NULL;
}
int main(void) {
    struct wlr_renderer *renderer = (struct wlr_renderer *)(uintptr_t)1;
    is_gles = false;
    assert(!rediwm_gpu_timer_create(renderer));
    is_gles = true; extension = false;
    assert(!rediwm_gpu_timer_create(renderer));
    extension = true; counter_bits = 0;
    assert(!rediwm_gpu_timer_create(renderer));
    counter_bits = 64;
    struct gpu_timer *timer = rediwm_gpu_timer_create(renderer);
    assert(timer && live_queries == 16);
    assert(current == (EGLContext)(uintptr_t)7);
    for (unsigned i = 0; i < SLOTS; ++i) {
        assert(rediwm_gpu_timer_begin(timer, 1));
        rediwm_gpu_timer_end(timer);
    }
    assert(!rediwm_gpu_timer_begin(timer, 1));
    struct gpu_sample samples[SLOTS];
    uint64_t dropped = 0;
    assert(rediwm_gpu_timer_collect(timer, 1, samples, &dropped) == 0);
    assert(result_reads == 0 && dropped == 0); // Unavailable results never block.
    ready = true;
    assert(rediwm_gpu_timer_collect(timer, 1, samples, &dropped) == SLOTS);
    for (unsigned i = 0; i < SLOTS; ++i)
        assert(samples[i].ns == 1000000 && samples[i].generation == 1);
    assert(rediwm_gpu_timer_begin(timer, 1));
    rediwm_gpu_timer_end(timer);
    assert(rediwm_gpu_timer_collect(timer, 2, samples, &dropped) == 0);
    assert(dropped == 0); // Old generation does not pollute reset counters.

    assert(rediwm_gpu_timer_begin(timer, 2));
    rediwm_gpu_timer_end(timer);
    disjoint_at = disjoint_call + 1;
    assert(rediwm_gpu_timer_collect(timer, 2, samples, &dropped) == 0 && dropped == 1);
    assert(rediwm_gpu_timer_begin(timer, 2));
    rediwm_gpu_timer_end(timer);
    disjoint_at = disjoint_call + 2; // Disjoint during result retrieval.
    assert(rediwm_gpu_timer_collect(timer, 2, samples, &dropped) == 0 && dropped == 2);

    assert(rediwm_gpu_timer_begin(timer, 2));
    rediwm_gpu_timer_end(timer);
    ready = false;
    for (unsigned i = 0; i < 121; ++i)
        assert(rediwm_gpu_timer_collect(timer, 2, samples, &dropped) == 0);
    assert(dropped == 3 && live_queries == 16);
    ready = true;
    assert(rediwm_gpu_timer_begin(timer, 2));
    int slot = timer->active;
    rediwm_gpu_timer_end(timer);
    values[timer->slots[slot].ids[0]] = 2;
    values[timer->slots[slot].ids[1]] = 1;
    assert(rediwm_gpu_timer_collect(timer, 2, samples, &dropped) == 0 && dropped == 4);
    assert(rediwm_gpu_timer_begin(timer, 2));
    rediwm_gpu_timer_end(timer);
    rediwm_gpu_timer_destroy(timer); // Includes outstanding queries.
    assert(live_queries == 0 && current == (EGLContext)(uintptr_t)7);
    return 0;
}
