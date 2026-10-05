// Test-only hot-unplug injection and scene lifetime check in the real compositor.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/backend.h>

static struct wlr_scene *scene;
static struct wlr_output *target, *dying;
static struct wl_event_source *timer;
static unsigned mutations;
static bool cursor_destroyed;

void wlr_cursor_destroy(struct wlr_cursor *cursor) {
    void (*destroy)(struct wlr_cursor *) = dlsym(RTLD_NEXT, "wlr_cursor_destroy");
    assert(destroy);
    cursor_destroyed = true;
    destroy(cursor);
}

void wlr_backend_destroy(struct wlr_backend *backend) {
    void (*destroy)(struct wlr_backend *) = dlsym(RTLD_NEXT, "wlr_backend_destroy");
    assert(destroy);
    // Output/device callbacks may finish gestures and use the cursor/seat.
    assert(!cursor_destroyed);
    destroy(backend);
}

static int unplug(void *data) {
    (void)data;
    if (access(getenv("REDIWM_TEST_UNPLUG"), F_OK) != 0) {
        wl_event_source_timer_update(timer, 20);
        return 0;
    }
    wl_event_source_remove(timer);
    dying = target;
    wlr_output_destroy(target);
    dying = NULL;
    assert(mutations > 0);
    return 0;
}

struct wlr_scene_output *wlr_scene_output_create(struct wlr_scene *s,
        struct wlr_output *output) {
    struct wlr_scene_output *(*create)(struct wlr_scene *, struct wlr_output *) =
        dlsym(RTLD_NEXT, "wlr_scene_output_create");
    assert(create);
    struct wlr_scene_output *result = create(s, output);
    if (!target && result) {
        scene = s;
        target = output;
        timer = wl_event_loop_add_timer(output->event_loop, unplug, NULL);
        assert(timer);
        wl_event_source_timer_update(timer, 20);
    }
    return result;
}

void wlr_scene_node_destroy(struct wlr_scene_node *node) {
    void (*destroy)(struct wlr_scene_node *) =
        dlsym(RTLD_NEXT, "wlr_scene_node_destroy");
    assert(destroy);
    if (dying) {
        // Removing per-output chrome must never uncover surfaces on an output
        // whose destroy signal is already in progress (wlroots issue #4096).
        assert(wlr_scene_get_scene_output(scene, dying) == NULL);
        ++mutations;
    }
    destroy(node);
}
