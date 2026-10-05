// Dedicated test client for launch_placeholder.py.
#define _GNU_SOURCE
#include "xdg-shell-client-protocol.h"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static struct xdg_toplevel *toplevel;

static const char *app_id = "test.placeholder";
static const char *title = "Test Placeholder App";
static int width = 640, height = 480;
static int force_w = 0, force_h = 0;
static int sleep_ms = 0;
static int exit_before_map = 0;
static unsigned fill_color = 0xff00ff00; // bright green (ARGB8888)

static void released(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {released};

static void paint(struct wl_surface *s, int w, int h, unsigned color) {
    size_t size = (size_t)w * (size_t)h * 4;
    int fd = memfd_create("ph-client-shm", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    unsigned *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            pixels[y * w + x] = color;
        }
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(s, buffer, 0, 0);
    wl_surface_damage(s, 0, 0, w, h);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
}

static void configured(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);

    int pw = force_w > 0 ? force_w : width;
    int ph = force_h > 0 ? force_h : height;
    if (pw <= 0) pw = 640;
    if (ph <= 0) ph = 480;

    paint(surface, pw, ph, fill_color);
    wl_surface_commit(surface);
    wl_display_flush(display);
    printf("CLIENT_COMMITTED %d %d\n", pw, ph);
    fflush(stdout);
}

static const struct xdg_surface_listener xdg_listener = {.configure = configured};

static void top_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
    (void)data;
    (void)t;
    (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
    printf("CLIENT_CONFIGURE %d %d\n", w, h);
    fflush(stdout);
}

static void top_close(void *data, struct xdg_toplevel *t) {
    (void)data;
    (void)t;
    printf("CLIENT_CLOSE\n");
    fflush(stdout);
    exit(0);
}

static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure,
    .close = top_close,
};

static void ping(void *d, struct xdg_wm_base *base, uint32_t serial) {
    (void)d;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};

static void global(void *d, struct wl_registry *r, uint32_t id, const char *interface, uint32_t v) {
    (void)d;
    (void)v;
    if (!strcmp(interface, "wl_compositor")) {
        compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
    } else if (!strcmp(interface, "wl_shm")) {
        shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
    } else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
}

static void removed(void *d, struct wl_registry *r, uint32_t id) {
    (void)d;
    (void)r;
    (void)id;
}
static const struct wl_registry_listener registry_listener = {global, removed};

static void sigterm_handler(int sig) {
    (void)sig;
    printf("CLIENT_SIGTERM\n");
    fflush(stdout);
    _exit(0);
}

int main(int argc, char *argv[]) {
    signal(SIGTERM, sigterm_handler);
    setbuf(stdout, NULL);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--app-id") && i + 1 < argc) {
            app_id = argv[++i];
        } else if (!strcmp(argv[i], "--title") && i + 1 < argc) {
            title = argv[++i];
        } else if (!strcmp(argv[i], "--sleep-ms") && i + 1 < argc) {
            sleep_ms = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--force-size") && i + 2 < argc) {
            force_w = atoi(argv[++i]);
            force_h = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--exit-before-map")) {
            exit_before_map = 1;
        }
    }

    if (const char *env_sleep = getenv("CLIENT_SLEEP_MS")) {
        sleep_ms = atoi(env_sleep);
    }
    if (getenv("CLIENT_EXIT_BEFORE_MAP")) {
        exit_before_map = 1;
    }
    if (const char *env_app = getenv("CLIENT_APP_ID")) {
        app_id = env_app;
    }

    if (sleep_ms > 0) {
        printf("CLIENT_SLEEPING %d ms\n", sleep_ms);
        fflush(stdout);
        struct timespec ts = {
            .tv_sec = sleep_ms / 1000,
            .tv_nsec = (long)(sleep_ms % 1000) * 1000000L,
        };
        nanosleep(&ts, NULL);
    }

    if (exit_before_map) {
        printf("CLIENT_EXITING_BEFORE_MAP\n");
        fflush(stdout);
        return 0;
    }

    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "failed to connect to wayland display\n");
        return 1;
    }

    struct wl_registry *r = wl_display_get_registry(display);
    wl_registry_add_listener(r, &registry_listener, NULL);
    wl_display_roundtrip(display);
    assert(compositor && shm && wm);

    surface = wl_compositor_create_surface(compositor);
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &xdg_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(toplevel, &top_listener, NULL);

    if (title) xdg_toplevel_set_title(toplevel, title);
    if (app_id) xdg_toplevel_set_app_id(toplevel, app_id);

    wl_surface_commit(surface);
    wl_display_flush(display);

    while (wl_display_dispatch(display) >= 0) {
    }

    return 0;
}
