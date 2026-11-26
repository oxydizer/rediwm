// Included by wlr_protocols_client.c. One process maps an owner and a dialog
// parented to it, marks the dialog modal (or not), then follows stdin commands:
// "modal", "plain" (unset_modal), "drop" (destroy the xdg_dialog_v1), "close"
// (destroy the dialog toplevel) and "quit". It answers each with "ok".
#include "xdg-dialog-v1-client-protocol.h"

static struct xdg_wm_dialog_v1 *wm_dialog;

static bool bind_xdg_dialog(struct wl_registry *r, uint32_t name, const char *iface) {
  if (strcmp(iface, xdg_wm_dialog_v1_interface.name)) return false;
  wm_dialog = wl_registry_bind(r, name, &xdg_wm_dialog_v1_interface, 1);
  return true;
}

struct dialog_window {
  struct wl_surface *surface;
  struct xdg_surface *xdg_surface;
  struct xdg_toplevel *toplevel;
  struct wl_buffer *buffer;
};

static void dialog_window_map(struct dialog_window *w, const char *app_id, struct xdg_toplevel *parent,
                              int width, int height, uint32_t fill, struct xdg_dialog_v1 **dialog, bool modal) {
  w->surface = wl_compositor_create_surface(compositor);
  w->xdg_surface = xdg_wm_base_get_xdg_surface(xdg, w->surface);
  xdg_surface_add_listener(w->xdg_surface, &surface_listener, NULL);
  w->toplevel = xdg_surface_get_toplevel(w->xdg_surface);
  xdg_toplevel_add_listener(w->toplevel, &top_listener, NULL);
  xdg_toplevel_set_app_id(w->toplevel, app_id);
  if (parent) xdg_toplevel_set_parent(w->toplevel, parent);
  if (dialog) {
    *dialog = xdg_wm_dialog_v1_get_xdg_dialog(wm_dialog, w->toplevel);
    if (modal) xdg_dialog_v1_set_modal(*dialog);
  }
  configured = false;
  wl_surface_commit(w->surface);
  dispatch_until(&configured);
  w->buffer = create_buffer(WL_SHM_FORMAT_ARGB8888, width, height, width * 4, fill, NULL);
  wl_surface_attach(w->surface, w->buffer, 0, 0);
  wl_surface_commit(w->surface);
}

static void dialog_window_destroy(struct dialog_window *w) {
  xdg_toplevel_destroy(w->toplevel);
  xdg_surface_destroy(w->xdg_surface);
  wl_surface_destroy(w->surface);
  wl_buffer_destroy(w->buffer);
}

// Keeps answering the compositor (configures, pings) while waiting for a
// command. The driver sends one command and waits for its "ok".
static bool dialog_command(char *line, size_t size) {
  for (;;) {
    while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
    wl_display_flush(display);
    struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
    if (poll(fds, 2, -1) < 0) {
      wl_display_cancel_read(display);
      return false;
    }
    if (fds[0].revents & POLLIN) {
      if (wl_display_read_events(display) < 0) return false;
      wl_display_dispatch_pending(display);
    } else {
      wl_display_cancel_read(display);
    }
    if (fds[1].revents & (POLLIN | POLLHUP)) {
      if (!fgets(line, (int)size, stdin)) return false;
      line[strcspn(line, "\n")] = 0;
      return true;
    }
  }
}

static int run_xdg_dialog(const char *initial) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  assert(xdg && wm_dialog);
  struct dialog_window owner = {0}, child = {0};
  struct xdg_dialog_v1 *dialog = NULL;
  dialog_window_map(&owner, "rediwm.dialog-owner", NULL, 480, 360, 0xff334455, NULL, false);
  assert(wl_display_roundtrip(display) >= 0);
  dialog_window_map(&child, "rediwm.dialog", owner.toplevel, 200, 120, 0xffcc3344, &dialog,
                    !strcmp(initial, "modal"));
  assert(wl_display_roundtrip(display) >= 0);
  puts("mapped");
  char line[64];
  while (dialog_command(line, sizeof(line))) {
    if (!strcmp(line, "modal")) xdg_dialog_v1_set_modal(dialog);
    else if (!strcmp(line, "plain")) xdg_dialog_v1_unset_modal(dialog);
    else if (!strcmp(line, "drop")) { xdg_dialog_v1_destroy(dialog); dialog = NULL; }
    else if (!strcmp(line, "close")) {
      if (dialog) xdg_dialog_v1_destroy(dialog);
      dialog = NULL;
      dialog_window_destroy(&child);
      child = (struct dialog_window){0};
    } else if (!strcmp(line, "quit")) break;
    else return 2;
    assert(wl_display_roundtrip(display) >= 0);
    puts("ok");
  }
  if (dialog) xdg_dialog_v1_destroy(dialog);
  if (child.toplevel) dialog_window_destroy(&child);
  dialog_window_destroy(&owner);
  xdg_wm_dialog_v1_destroy(wm_dialog);
  assert(wl_display_roundtrip(display) >= 0);
  wl_display_disconnect(display);
  return 0;
}
