// Test-only keyboard delivered through wlroots' native device path. An isolated
// compositor loads this library; production has no synthetic-input bypass.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/interfaces/wlr_pointer.h>

static struct wlr_backend *backend;
static struct wlr_keyboard keyboard;
static bool initialized;
static struct wlr_pointer pointer;
static const struct wlr_pointer_impl pointer_impl = {.name = "polkit-test-pointer"};
static const struct wlr_keyboard_impl impl = {.name = "polkit-test-device"};
static int input_ready(int fd, uint32_t mask, void *data) {
    (void)mask; (void)data;
    if (!initialized) {
        initialized = true;
        wlr_keyboard_init(&keyboard, &impl, "polkit-test-keyboard");
        wl_signal_emit_mutable(&backend->events.new_input, &keyboard.base);
        wlr_pointer_init(&pointer, &pointer_impl, "polkit-test-pointer");
        wl_signal_emit_mutable(&backend->events.new_input, &pointer.base);
    }
    uint32_t packet[2];
    ssize_t n;
    while ((n = read(fd, packet, sizeof(packet))) == sizeof(packet)) {
        if (packet[0] == UINT32_MAX) {
            struct wlr_pointer_motion_absolute_event motion = {.pointer = &pointer, .time_msec = 1,
                .x = (packet[1] >> 16) / 65535.0, .y = (packet[1] & 65535) / 65535.0};
            wl_signal_emit_mutable(&pointer.events.motion_absolute, &motion);
            continue;
        }
        if (packet[0] == UINT32_MAX - 1) {
            struct wlr_pointer_button_event button = {.pointer = &pointer, .time_msec = 1,
                .button = 272, .state = packet[1] ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED};
            wlr_pointer_notify_button(&pointer, &button);
            continue;
        }
        struct wlr_keyboard_key_event event = {
            .time_msec = 1, .keycode = packet[0], .update_state = true,
            .state = packet[1] ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED,
        };
        wlr_keyboard_notify_key(&keyboard, &event);
    }
    assert(n <= 0);
    return 0;
}
struct wlr_backend *wlr_headless_backend_create(struct wl_event_loop *loop) {
    struct wlr_backend *(*real_create)(struct wl_event_loop *) = dlsym(RTLD_NEXT, "wlr_headless_backend_create");
    assert(real_create);
    backend = real_create(loop);
    const char *path = getenv("REDIWM_TEST_POLKIT_INPUT");
    assert(path && backend);
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    assert(fd >= 0);
    assert(wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, input_ready, NULL));
    return backend;
}
