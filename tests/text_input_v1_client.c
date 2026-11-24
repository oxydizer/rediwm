/* Legacy fields for the input_protocol_client.c fixture. */
#include "text-input-unstable-v1-client-protocol.h"

static struct zwp_text_input_manager_v1 *legacy_manager;
static struct zwp_text_input_v1 *first_field, *second_field;
static int legacy_only;
static int mixed_inputs;

static void legacy_enter(void *name, struct zwp_text_input_v1 *input, struct wl_surface *s) {
  (void)input; assert(s == surface);
  printf("v1-enter %s\n", (char *)name);
}
static void legacy_leave(void *name, struct zwp_text_input_v1 *input) {
  (void)input; printf("v1-leave %s\n", (char *)name);
}
static void legacy_preedit(void *name, struct zwp_text_input_v1 *input, uint32_t serial,
                           const char *text, const char *fallback) {
  (void)input; (void)fallback; printf("v1-preedit %s %u [%s]\n", (char *)name, serial, text);
}
static void legacy_style(void *name, struct zwp_text_input_v1 *input, uint32_t i, uint32_t n, uint32_t style) {
  (void)input; printf("v1-style %s %u %u %u\n", (char *)name, i, n, style);
}
static void legacy_cursor(void *name, struct zwp_text_input_v1 *input, int32_t i) {
  (void)input; printf("v1-cursor %s %d\n", (char *)name, i);
}
static void legacy_commit(void *name, struct zwp_text_input_v1 *input, uint32_t serial, const char *text) {
  (void)input; printf("v1-commit %s %u [%s]\n", (char *)name, serial, text);
}
static void legacy_delete(void *name, struct zwp_text_input_v1 *input, int32_t i, uint32_t n) {
  (void)input; printf("v1-delete %s %d %u\n", (char *)name, i, n);
}
static const struct zwp_text_input_v1_listener legacy_listener = {
  .enter=legacy_enter, .leave=legacy_leave, .preedit_string=legacy_preedit,
  .preedit_styling=legacy_style, .preedit_cursor=legacy_cursor,
  .commit_string=legacy_commit, .delete_surrounding_text=legacy_delete,
};

static struct zwp_text_input_v1 *legacy_field(char *name) {
  struct zwp_text_input_v1 *field = zwp_text_input_manager_v1_create_text_input(legacy_manager);
  zwp_text_input_v1_add_listener(field, &legacy_listener, name);
  return field;
}

static void legacy_command(const char *line) {
  unsigned serial;
  int x, y;
  if (!strcmp(line, "v1-enable")) zwp_text_input_v1_activate(first_field, seat, surface);
  else if (!strcmp(line, "v1-disable")) zwp_text_input_v1_deactivate(first_field, seat);
  else if (!strcmp(line, "v1-reset")) zwp_text_input_v1_reset(first_field);
  else if (!strcmp(line, "v1-second")) {
    if (!second_field) second_field = legacy_field("second");
    zwp_text_input_v1_activate(second_field, seat, surface);
  } else if (!strcmp(line, "v1-drop-pending")) {
    struct wl_surface *unmapped = wl_compositor_create_surface(compositor);
    zwp_text_input_v1_activate(first_field, seat, unmapped);
    wl_surface_destroy(unmapped);
  } else if (!strcmp(line, "v1-context")) {
    zwp_text_input_v1_set_surrounding_text(first_field, "aéx界", 3, 1);
    zwp_text_input_v1_set_content_type(first_field, ZWP_TEXT_INPUT_V1_CONTENT_HINT_PASSWORD,
                                       ZWP_TEXT_INPUT_V1_CONTENT_PURPOSE_DATE);
  } else if (sscanf(line, "v1-serial %u", &serial) == 1)
    zwp_text_input_v1_commit_state(first_field, serial);
  else if (sscanf(line, "v1-caret %d %d", &x, &y) == 2)
    zwp_text_input_v1_set_cursor_rectangle(first_field, x, y, 2, 18);
  else if (!strcmp(line, "v1-destroy-target")) {
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xdg);
    wl_surface_destroy(surface);
  } else abort();
}
