// Included by wlr_protocols_client.c. Keep the exact same buffer attached
// while switching colour descriptions. The middle row is probed by hdr_content.py.
static int preferred_event(const void *data, void *proxy, uint32_t opcode,
                           const struct wl_message *message, union wl_argument *args) {
  (void)proxy; (void)opcode;
  uint32_t *named = (uint32_t *)data;
  if (!strcmp(message->name, "tf_named")) named[0] = args[0].u;
  if (!strcmp(message->name, "primaries_named")) named[1] = args[0].u;
  return 0;
}

static int run_hdr_pattern(void) {
  assert(wl_display_roundtrip(display) >= 0 && hdr_output && parametric_supported);
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct wp_color_management_surface_v1 *color = wp_color_manager_v1_get_surface(color_manager, surface);
  struct wp_color_management_surface_feedback_v1 *feedback = wp_color_manager_v1_get_surface_feedback(color_manager, surface);
  struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(xdg, surface);
  xdg_surface_add_listener(xs, &surface_listener, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
  xdg_toplevel_add_listener(top, &top_listener, NULL);
  xdg_toplevel_set_app_id(top, "rediwm.hdr-pattern");
  xdg_toplevel_set_fullscreen(top, hdr_output);
  wl_surface_commit(surface);
  dispatch_until(&configured);
  assert(hdr_width > 0 && hdr_height > 0);
  const uint32_t colors[] = {0xff000000, 0xff606060, 0xff949494, 0xffc0c0c0, 0xff887060};
  void *mapping;
  struct wl_buffer *buffer = create_buffer(WL_SHM_FORMAT_XRGB8888, hdr_width, hdr_height, 4*hdr_width, 0, &mapping);
  uint32_t *pixels = mapping;
  for (int y = 0; y < hdr_height; y++) for (int x = 0; x < hdr_width; x++)
    pixels[y*hdr_width+x] = colors[5*x/hdr_width];
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage(surface, 0, 0, hdr_width, hdr_height);
  wl_surface_commit(surface);
  assert(wl_display_roundtrip(display) >= 0);
  puts("pattern-ready"); fflush(stdout);
  char command[32];
  while (fgets(command, sizeof(command), stdin)) {
    command[strcspn(command, "\n")] = 0;
    if (!strcmp(command, "exit")) break;
    if (!strcmp(command, "preferred") || !strcmp(command, "late-preferred")) {
      if (!strcmp(command, "late-preferred")) {
        wp_color_management_surface_feedback_v1_destroy(feedback);
        feedback = wp_color_manager_v1_get_surface_feedback(color_manager, surface);
      }
      struct wp_image_description_v1 *desc = wp_color_management_surface_feedback_v1_get_preferred(feedback);
      image_ready = false;
      wp_image_description_v1_add_listener(desc, &image_listener, NULL);
      dispatch_until(&image_ready);
      uint32_t named[2] = {0};
      struct wp_image_description_info_v1 *info = wp_image_description_v1_get_information(desc);
      wl_proxy_add_dispatcher((struct wl_proxy *)info, preferred_event, named, NULL);
      assert(wl_display_roundtrip(display) >= 0);
      wp_image_description_v1_destroy(desc);
      printf("preferred %u %u\n", named[0], named[1]);
    } else if (!strcmp(command, "pq-child")) {
      // A game swapchain on a subsurface, with its parent still untagged.
      struct wl_surface *child = wl_compositor_create_surface(compositor);
      wl_subcompositor_get_subsurface(subcompositor, child, surface);
      struct wp_color_management_surface_v1 *child_color = wp_color_manager_v1_get_surface(color_manager, child);
      describe(child_color, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ, WP_COLOR_MANAGER_V1_PRIMARIES_BT2020);
      wl_surface_attach(child, buffer, 0, 0);
      wl_surface_damage(child, 0, 0, hdr_width, hdr_height);
      wl_surface_commit(child);
      wl_surface_commit(surface);
      assert(wl_display_roundtrip(display) >= 0);
      puts(command);
    } else {
      uint32_t primaries = WP_COLOR_MANAGER_V1_PRIMARIES_SRGB;
      uint32_t tf;
      if (!strcmp(command, "pq")) {
        tf = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ;
        primaries = WP_COLOR_MANAGER_V1_PRIMARIES_BT2020;
      } else if (!strcmp(command, "linear")) tf = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR;
      else if (!strcmp(command, "srgb")) tf = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_COMPOUND_POWER_2_4;
      else if (!strcmp(command, "gamma")) tf = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22;
      else if (!strcmp(command, "unset")) tf = 0;
      else return 2;
      if (tf) describe(color, tf, primaries);
      else wp_color_management_surface_v1_unset_image_description(color);
      wl_surface_commit(surface);
      assert(wl_display_roundtrip(display) >= 0);
      puts(command);
    }
    fflush(stdout);
  }
  return 0;
}
