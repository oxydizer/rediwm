/* The StatusNotifier item and its D-Bus menu: the taskbar's way to show that
 * something is playing and to pause or stop it. Clicking the icon opens the
 * menu (ItemIsMenu). The icon is drawn here, so no icon theme is needed.
 * https://specifications.freedesktop.org/status-notifier-item/latest-single/ */
#include <math.h>
#include <string.h>
#include <unistd.h>

#include "player.h"

#define ITEM_IFACE "org.kde.StatusNotifierItem"
#define MENU_IFACE "com.canonical.dbusmenu"
#define ITEM_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define ICON_SIZE 32

static char *item_name;
static guint menu_revision = 1;

static const char item_xml[] =
    "<node><interface name='" ITEM_IFACE "'>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewIcon'/><signal name='NewToolTip'/><signal name='NewStatus'><arg type='s'/></signal>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "</interface></node>";

static const char menu_xml[] =
    "<node><interface name='" MENU_IFACE "'>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='in'/><arg type='u' direction='in'/></method>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "<property name='Version' type='u' access='read'/>"
    "<property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "</interface></node>";

/* Coverage of a point by an anti-aliased glyph, 0..1: 4x4 samples per pixel. */
static float inside_triangle(float x, float y, float cx, float cy, float r) {
    float left = cx - r * 0.55f, right = cx + r * 0.85f;
    if (x < left || x > right) return 0;
    float half = r * (right - x) / (right - left);
    return fabsf(y - cy) <= half ? 1 : 0;
}

static float inside_bars(float x, float y, float cx, float cy, float r) {
    float bar = r * 0.3f, gap = r * 0.22f;
    if (fabsf(y - cy) > r * 0.8f) return 0;
    float d = fabsf(x - cx);
    return d >= gap && d <= gap + bar ? 1 : 0;
}

/* A red disc with a white play triangle (playing) or pause bars (paused),
 * straight (not premultiplied) ARGB32 in network byte order. */
static GVariant *icon_pixmap(void) {
    guint8 pixels[ICON_SIZE * ICON_SIZE * 4];
    float c = ICON_SIZE / 2.0f, radius = ICON_SIZE / 2.0f - 1.5f;
    for (int y = 0; y < ICON_SIZE; y++)
        for (int x = 0; x < ICON_SIZE; x++) {
            float disc = 0, glyph = 0;
            for (int sy = 0; sy < 4; sy++)
                for (int sx = 0; sx < 4; sx++) {
                    float px = x + (sx + 0.5f) / 4, py = y + (sy + 0.5f) / 4;
                    float dx = px - c, dy = py - c;
                    if (dx * dx + dy * dy <= radius * radius) disc += 1.0f / 16;
                    glyph += (player.status == PL_PAUSED ? inside_bars(px, py, c, c, radius * 0.62f) : inside_triangle(px, py, c, c, radius * 0.62f)) / 16;
                }
            guint8 *p = &pixels[(y * ICON_SIZE + x) * 4];
            float alpha = disc;
            float shade = glyph; /* 0: accent, 1: white */
            p[0] = (guint8)lroundf(alpha * 255);
            p[1] = (guint8)lroundf(230 + shade * 25);
            p[2] = (guint8)lroundf(57 + shade * 198);
            p[3] = (guint8)lroundf(70 + shade * 185);
        }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a(iiay)"));
    g_variant_builder_add(&b, "(ii@ay)", ICON_SIZE, ICON_SIZE,
                          g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, pixels, sizeof pixels, 1));
    return g_variant_builder_end(&b);
}

static GVariant *item_get(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *name, GError **e, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)e; (void)d;
    if (!strcmp(name, "Category")) return g_variant_new_string("ApplicationStatus");
    if (!strcmp(name, "Id")) return g_variant_new_string("rediwm-player");
    if (!strcmp(name, "Title")) return g_variant_new_string("Audio Player");
    if (!strcmp(name, "Status")) return g_variant_new_string("Active");
    if (!strcmp(name, "IconName")) return g_variant_new_string("");
    if (!strcmp(name, "IconPixmap")) return icon_pixmap();
    if (!strcmp(name, "ItemIsMenu")) return g_variant_new_boolean(TRUE);
    if (!strcmp(name, "Menu")) return g_variant_new_object_path(MENU_PATH);
    if (!strcmp(name, "ToolTip"))
        return g_variant_new("(s@a(iiay)ss)", "", g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0), player.title ? player.title : "Audio Player",
                             player.status == PL_PAUSED ? "Paused" : "Playing");
    return NULL;
}

static void item_call(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *method, GVariant *p, GDBusMethodInvocation *inv, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)p; (void)d;
    /* The menu is the primary interaction; a middle click toggles playback. */
    if (!strcmp(method, "SecondaryActivate")) player_toggle();
    g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant *menu_row(int id, const char *label, gboolean enabled, gboolean separator) {
    GVariantBuilder properties, children;
    g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
    if (separator) g_variant_builder_add(&properties, "{sv}", "type", g_variant_new_string("separator"));
    else {
        g_variant_builder_add(&properties, "{sv}", "label", g_variant_new_string(label));
        g_variant_builder_add(&properties, "{sv}", "enabled", g_variant_new_boolean(enabled));
    }
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    return g_variant_new("(ia{sv}av)", id, &properties, &children);
}

static GVariant *menu_get(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *name, GError **e, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)e; (void)d;
    if (!strcmp(name, "Version")) return g_variant_new_uint32(3);
    if (!strcmp(name, "TextDirection")) return g_variant_new_string("ltr");
    if (!strcmp(name, "Status")) return g_variant_new_string("normal");
    return NULL;
}

enum { ROW_TITLE = 1, ROW_SEPARATOR, ROW_TOGGLE, ROW_STOP, ROW_BACK, ROW_FORWARD };

static void menu_call(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *method, GVariant *p, GDBusMethodInvocation *inv, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)d;
    if (!strcmp(method, "GetLayout")) {
        GVariantBuilder properties, children;
        g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
        g_variant_builder_add(&children, "v", menu_row(ROW_TITLE, player.title ? player.title : "Audio Player", FALSE, FALSE));
        g_variant_builder_add(&children, "v", menu_row(ROW_SEPARATOR, "", FALSE, TRUE));
        g_variant_builder_add(&children, "v", menu_row(ROW_TOGGLE, player.status == PL_PLAYING ? "Pause" : "Play", TRUE, FALSE));
        g_variant_builder_add(&children, "v", menu_row(ROW_BACK, "Back 10 seconds", TRUE, FALSE));
        g_variant_builder_add(&children, "v", menu_row(ROW_FORWARD, "Forward 10 seconds", TRUE, FALSE));
        g_variant_builder_add(&children, "v", menu_row(ROW_STOP, "Stop", TRUE, FALSE));
        g_dbus_method_invocation_return_value(inv, g_variant_new("(u(ia{sv}av))", menu_revision, 0, &properties, &children));
        return;
    }
    if (!strcmp(method, "AboutToShow")) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", FALSE));
        return;
    }
    if (!strcmp(method, "Event")) {
        gint id;
        const char *event;
        GVariant *value;
        guint timestamp;
        g_variant_get(p, "(i&svu)", &id, &event, &value, &timestamp);
        g_variant_unref(value);
        if (!strcmp(event, "clicked")) {
            if (id == ROW_TOGGLE) player_toggle();
            else if (id == ROW_BACK) player_seek(-10 * G_USEC_PER_SEC);
            else if (id == ROW_FORWARD) player_seek(10 * G_USEC_PER_SEC);
            else if (id == ROW_STOP) player_quit();
        }
    }
    g_dbus_method_invocation_return_value(inv, NULL);
}

static void announce(GDBusConnection *connection, const gchar *name, const gchar *owner, gpointer data) {
    (void)name; (void)owner; (void)data;
    g_dbus_connection_call(connection, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                           "RegisterStatusNotifierItem", g_variant_new("(s)", item_name), NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, NULL, NULL, NULL);
}

void tray_register(void) {
    static const GDBusInterfaceVTable item_vtable = {item_call, item_get, NULL, {0}};
    static const GDBusInterfaceVTable menu_vtable = {menu_call, menu_get, NULL, {0}};
    GDBusNodeInfo *item = g_dbus_node_info_new_for_xml(item_xml, NULL);
    GDBusNodeInfo *menu = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    g_dbus_connection_register_object(player.bus, ITEM_PATH, g_dbus_node_info_lookup_interface(item, ITEM_IFACE), &item_vtable, NULL, NULL, NULL);
    g_dbus_connection_register_object(player.bus, MENU_PATH, g_dbus_node_info_lookup_interface(menu, MENU_IFACE), &menu_vtable, NULL, NULL, NULL);
    g_dbus_node_info_unref(item);
    g_dbus_node_info_unref(menu);
    item_name = g_strdup_printf("org.kde.StatusNotifierItem-%d-1", (int)getpid());
    g_bus_own_name_on_connection(player.bus, item_name, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
    /* The watcher may start after the player (or restart): register whenever it appears. */
    g_bus_watch_name_on_connection(player.bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_WATCHER_FLAGS_NONE, announce, NULL, NULL, NULL);
}

void tray_changed(void) {
    if (!item_name) return;
    g_dbus_connection_emit_signal(player.bus, NULL, ITEM_PATH, ITEM_IFACE, "NewIcon", NULL, NULL);
    g_dbus_connection_emit_signal(player.bus, NULL, ITEM_PATH, ITEM_IFACE, "NewToolTip", NULL, NULL);
    menu_revision++;
    g_dbus_connection_emit_signal(player.bus, NULL, MENU_PATH, MENU_IFACE, "LayoutUpdated", g_variant_new("(ui)", menu_revision, 0), NULL);
}

/* The same transient scope contract as session/app_scope.zig: the player gets
 * its own cgroup in app.slice, since systemd-oomd kills whole cgroups. */
void tray_place_scope(void) {
    GVariantBuilder props, pids, aux;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a(sv)"));
    g_variant_builder_init(&pids, G_VARIANT_TYPE("au"));
    g_variant_builder_add(&pids, "u", (guint32)getpid());
    g_variant_builder_add(&props, "(sv)", "PIDs", g_variant_builder_end(&pids));
    g_variant_builder_add(&props, "(sv)", "Slice", g_variant_new_string("app.slice"));
    g_variant_builder_add(&props, "(sv)", "CollectMode", g_variant_new_string("inactive-or-failed"));
    g_variant_builder_init(&aux, G_VARIANT_TYPE("a(sa(sv))"));
    char *name = g_strdup_printf("app-rediwm-player-%d.scope", (int)getpid());
    g_dbus_connection_call(player.bus, "org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager",
                           "StartTransientUnit", g_variant_new("(ssa(sv)a(sa(sv)))", name, "fail", &props, &aux), NULL,
                           G_DBUS_CALL_FLAGS_NO_AUTO_START, 1500, NULL, NULL, NULL);
    g_free(name);
}
