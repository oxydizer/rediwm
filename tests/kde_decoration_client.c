#define _GNU_SOURCE
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-client-protocol.h"
#include "server-decoration-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct org_kde_kwin_server_decoration_manager *manager;
static struct zxdg_decoration_manager_v1 *xdg_manager;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static struct xdg_toplevel *top;
static struct org_kde_kwin_server_decoration *decoration;
static struct zxdg_toplevel_decoration_v1 *xdg_decoration;
static bool configured, hold_paint, running = true;
static int width = 400, height = 260;

static void released(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {released};
static void paint(void) {
    if (!configured || hold_paint) return;
    int size = width * height * 4;
    int fd = memfd_create("kde-decoration-test", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, size) == 0);
    unsigned *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    for (int i = 0; i < width * height; i++) pixels[i] = 0xff234567;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
}
static void configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);
    configured = true;
    paint();
}
static const struct xdg_surface_listener surface_listener = {configure};
static void top_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void top_close(void *data, struct xdg_toplevel *t) {
    (void)data; (void)t;
    puts("close");
    running = false;
}
static const struct xdg_toplevel_listener top_listener = {top_configure, top_close};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};
static void mode(void *data, struct org_kde_kwin_server_decoration *d, uint32_t value) {
    (void)data; (void)d;
    printf("mode %u\n", value);
    paint();
}
static const struct org_kde_kwin_server_decoration_listener decoration_listener = {mode};
static void default_mode(void *data, struct org_kde_kwin_server_decoration_manager *m, uint32_t value) {
    (void)data; (void)m;
    printf("default %u\n", value);
}
static const struct org_kde_kwin_server_decoration_manager_listener manager_listener = {default_mode};
static void xdg_mode(void *data, struct zxdg_toplevel_decoration_v1 *d, uint32_t value) {
    (void)data; (void)d;
    printf("xdg mode %u\n", value);
}
static const struct zxdg_toplevel_decoration_v1_listener xdg_decoration_listener = {xdg_mode};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 2);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    } else if (!strcmp(interface, "org_kde_kwin_server_decoration_manager")) {
        manager = wl_registry_bind(registry, name, &org_kde_kwin_server_decoration_manager_interface, 1);
        org_kde_kwin_server_decoration_manager_add_listener(manager, &manager_listener, NULL);
    } else if (!strcmp(interface, "zxdg_decoration_manager_v1")) xdg_manager = wl_registry_bind(registry, name, &zxdg_decoration_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {global, removed};
static void create_decoration(int requested) {
    decoration = org_kde_kwin_server_decoration_manager_create(manager, surface);
    org_kde_kwin_server_decoration_add_listener(decoration, &decoration_listener, NULL);
    if (requested >= 0) org_kde_kwin_server_decoration_request_mode(decoration, requested);
}
static void create_role(void) {
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_app_id(top, "test.kde-decoration");
    xdg_toplevel_set_title(top, "KDE decoration fixture");
}
int main(int argc, char **argv) {
    assert(argc == 3);
    setbuf(stdout, NULL);
    display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && wm && manager && xdg_manager);
    surface = wl_compositor_create_surface(compositor);
    int requested = atoi(argv[2]);
    if (!strcmp(argv[1], "early")) {
        create_decoration(requested);
        assert(wl_display_roundtrip(display) >= 0);
    }
    create_role();
    if (strcmp(argv[1], "early")) create_decoration(requested);
    if (!strcmp(argv[1], "both")) {
        xdg_decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(xdg_manager, top);
        zxdg_toplevel_decoration_v1_add_listener(xdg_decoration, &xdg_decoration_listener, NULL);
        zxdg_toplevel_decoration_v1_set_mode(xdg_decoration, 1);
    }
    wl_surface_commit(surface);
    while (running) {
        assert(wl_display_dispatch_pending(display) >= 0);
        wl_display_flush(display);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[0].revents & POLLIN) assert(wl_display_dispatch(display) >= 0);
        if (fds[1].revents & POLLIN) {
            char command;
            assert(read(STDIN_FILENO, &command, 1) == 1);
            if (command >= '0' && command <= '2') org_kde_kwin_server_decoration_request_mode(decoration, command - '0');
            else if (command == 'h') hold_paint = true;
            else if (command == 'p') { hold_paint = false; paint(); }
            else if (command == 'f') xdg_toplevel_set_fullscreen(top, NULL);
            else if (command == 'w') xdg_toplevel_unset_fullscreen(top);
            else if (command == 'u') {
                configured = false;
                wl_surface_attach(surface, NULL, 0, 0);
                wl_surface_commit(surface);
            } else if (command == 'm') wl_surface_commit(surface);
            else if (command == 'r') {
                org_kde_kwin_server_decoration_release(decoration);
                decoration = NULL;
                paint();
            } else if (command == 'c') { create_decoration(2); paint(); }
            else if (command == 'x') {
                zxdg_toplevel_decoration_v1_set_mode(xdg_decoration, 2);
            } else if (command == 'd') {
                configured = false;
                if (xdg_decoration) zxdg_toplevel_decoration_v1_destroy(xdg_decoration);
                xdg_toplevel_destroy(top);
                xdg_surface_destroy(xdg);
                wl_surface_destroy(surface);
                assert(wl_display_roundtrip(display) >= 0);
                org_kde_kwin_server_decoration_request_mode(decoration, 2);
                org_kde_kwin_server_decoration_release(decoration);
                assert(wl_display_roundtrip(display) >= 0);
                puts("destroyed surface before decoration");
                break;
            }
        }
    }
    wl_display_disconnect(display);
    return 0;
}
