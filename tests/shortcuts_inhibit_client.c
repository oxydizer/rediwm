// Keyboard-shortcuts-inhibit peer driven by shortcuts_inhibit.py. Key events
// print as "key <code> <state>" (zoom_client.c).
#define main zoom_fixture_main
#include "zoom_client.c"
#undef main
#include "keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h"
#include <poll.h>

static struct zwp_keyboard_shortcuts_inhibit_manager_v1 *inhibit_manager;
static struct zwp_keyboard_shortcuts_inhibitor_v1 *inhibitor;

static void on_active(void *d, struct zwp_keyboard_shortcuts_inhibitor_v1 *i) { (void)d; (void)i; puts("active"); }
static void on_inactive(void *d, struct zwp_keyboard_shortcuts_inhibitor_v1 *i) { (void)d; (void)i; puts("inactive"); }
static const struct zwp_keyboard_shortcuts_inhibitor_v1_listener inhibitor_listener = {on_active, on_inactive};

static void inhibit_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t version) {
  printf("global %s %u\n", iface, version);
  if (!strcmp(iface, "zwp_keyboard_shortcuts_inhibit_manager_v1"))
    inhibit_manager = wl_registry_bind(r, id, &zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1);
  else global(d, r, id, iface, version);
}
static const struct wl_registry_listener inhibit_registry = {inhibit_global, removed};

static void command(char *line) {
  if (!strcmp(line, "inhibit")) {
    inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(inhibit_manager, surface, seat);
    zwp_keyboard_shortcuts_inhibitor_v1_add_listener(inhibitor, &inhibitor_listener, NULL);
  } else if (!strcmp(line, "uninhibit")) {
    zwp_keyboard_shortcuts_inhibitor_v1_destroy(inhibitor);
    inhibitor = NULL;
  } else if (strcmp(line, "sync")) {
    fprintf(stderr, "Unknown command: %s\n", line);
    abort();
  }
  assert(wl_display_roundtrip(display) >= 0);
  printf("ack %s\n", line);
}

int main(int argc, char **argv) {
  setbuf(stdout, NULL);
  display = wl_display_connect(NULL); assert(display);
  wl_registry_add_listener(wl_display_get_registry(display), &inhibit_registry, NULL);
  assert(wl_display_roundtrip(display) >= 0);
  assert(wl_display_roundtrip(display) >= 0);
  assert(inhibit_manager && seat);
  app_id = argc > 1 ? argv[1] : "rediwm.shortcuts-inhibit";
  surface = wl_compositor_create_surface(compositor);
  xdg = xdg_wm_base_get_xdg_surface(wm, surface); xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  toplevel = xdg_surface_get_toplevel(xdg); xdg_toplevel_add_listener(toplevel, &top_listener, NULL);
  xdg_toplevel_set_title(toplevel, app_id); xdg_toplevel_set_app_id(toplevel, app_id);
  wl_surface_commit(surface);
  puts("ready");
  struct pollfd fds[2] = {{.fd = wl_display_get_fd(display), .events = POLLIN}, {.fd = STDIN_FILENO, .events = POLLIN}};
  char line[1024]; size_t used = 0;
  while (1) {
    assert(wl_display_dispatch_pending(display) >= 0);
    wl_display_flush(display);
    if (poll(fds, 2, -1) < 0) break;
    if (fds[0].revents & POLLIN) { if (wl_display_dispatch(display) < 0) break; }
    if (fds[1].revents & POLLIN) {
      char ch; if (read(STDIN_FILENO, &ch, 1) != 1) break;
      if (ch == '\n') { line[used] = 0; command(line); used = 0; }
      else { assert(used + 1 < sizeof(line)); line[used++] = ch; }
    }
    if (fds[1].revents & POLLHUP) break;
  }
  wl_display_disconnect(display);
  return 0;
}
