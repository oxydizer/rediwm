// The session: app scopes and the session bus.
// Part of rediwm-transfers (helper.cpp).
#include "helper.hpp"

namespace helper {

static bool bus_attempted = false;

// Same transient scope contract as session/app_scope.zig and the terminal
// helper.
void place_scope(pid_t pid, char const *app) {
  if (!use_scopes)
    return;
  GError *e = nullptr;
  auto connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &e);
  g_clear_error(&e);
  if (connection) {
    GVariantBuilder props, pids, aux;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a(sv)"));
    g_variant_builder_init(&pids, G_VARIANT_TYPE("au"));
    g_variant_builder_add(&pids, "u", guint32(pid));
    g_variant_builder_add(&props, "(sv)", "PIDs", g_variant_builder_end(&pids));
    g_variant_builder_add(&props, "(sv)", "Slice",
                          g_variant_new_string("app.slice"));
    g_variant_builder_add(&props, "(sv)", "CollectMode",
                          g_variant_new_string("inactive-or-failed"));
    g_variant_builder_init(&aux, G_VARIANT_TYPE("a(sa(sv))"));
    auto name =
        "app-rediwm-" + std::string(app) + "-" + std::to_string(pid) + ".scope";
    auto reply = g_dbus_connection_call_sync(
        connection, "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager", "StartTransientUnit",
        g_variant_new("(ssa(sv)a(sa(sv)))", name.c_str(), "fail", &props, &aux),
        nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, 1500, nullptr, &e);
    if (reply)
      g_variant_unref(reply);
    g_clear_error(&e);
    g_object_unref(connection);
  }
}
// The session bus, opened when first needed: for the "Download complete"
// notification. Downloads show in the shell's Transfers panel through Files,
// so the helper has no tray icon of its own.
GDBusConnection *session_bus() {
  if (!bus_attempted) {
    bus_attempted = true;
    GError *error = nullptr;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    g_clear_error(&error);
  }
  return bus;
}

} // namespace helper
