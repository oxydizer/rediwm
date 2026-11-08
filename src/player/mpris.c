/* The MPRIS interface (https://specifications.freedesktop.org/mpris-spec/):
 * how Files, playerctl and any other media client start, observe and control
 * the player. There is no polling: clients get PropertiesChanged when the
 * track or status changes and Seeked after a jump, and read Position when
 * they need it. */
#include <string.h>

#include "player.h"

#define ROOT_IFACE "org.mpris.MediaPlayer2"
#define PLAYER_IFACE "org.mpris.MediaPlayer2.Player"
#define TRACK_ID "/org/rediwm/Player/Track/1"

static const char root_xml[] =
    "<node><interface name='" ROOT_IFACE "'>"
    "<method name='Raise'/><method name='Quit'/>"
    "<property name='CanQuit' type='b' access='read'/>"
    "<property name='CanRaise' type='b' access='read'/>"
    "<property name='HasTrackList' type='b' access='read'/>"
    "<property name='Identity' type='s' access='read'/>"
    "<property name='DesktopEntry' type='s' access='read'/>"
    "<property name='SupportedUriSchemes' type='as' access='read'/>"
    "<property name='SupportedMimeTypes' type='as' access='read'/>"
    "</interface></node>";

static const char player_xml[] =
    "<node><interface name='" PLAYER_IFACE "'>"
    "<method name='Next'/><method name='Previous'/><method name='Pause'/>"
    "<method name='PlayPause'/><method name='Stop'/><method name='Play'/>"
    "<method name='Seek'><arg type='x' direction='in'/></method>"
    "<method name='SetPosition'><arg type='o' direction='in'/><arg type='x' direction='in'/></method>"
    "<method name='OpenUri'><arg type='s' direction='in'/></method>"
    "<signal name='Seeked'><arg type='x'/></signal>"
    "<property name='PlaybackStatus' type='s' access='read'/>"
    "<property name='Rate' type='d' access='read'/>"
    "<property name='MinimumRate' type='d' access='read'/>"
    "<property name='MaximumRate' type='d' access='read'/>"
    "<property name='Volume' type='d' access='readwrite'/>"
    "<property name='Position' type='x' access='read'/>"
    "<property name='Metadata' type='a{sv}' access='read'/>"
    "<property name='CanGoNext' type='b' access='read'/>"
    "<property name='CanGoPrevious' type='b' access='read'/>"
    "<property name='CanPlay' type='b' access='read'/>"
    "<property name='CanPause' type='b' access='read'/>"
    "<property name='CanSeek' type='b' access='read'/>"
    "<property name='CanControl' type='b' access='read'/>"
    "</interface></node>";

static GVariant *metadata(void) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    if (player.path) {
        g_variant_builder_add(&b, "{sv}", "mpris:trackid", g_variant_new_object_path(TRACK_ID));
        gint64 length = rp_engine_length_us(player.engine);
        if (length > 0) g_variant_builder_add(&b, "{sv}", "mpris:length", g_variant_new_int64(length));
        g_variant_builder_add(&b, "{sv}", "xesam:title", g_variant_new_string(player.title));
        if (player.uri) g_variant_builder_add(&b, "{sv}", "xesam:url", g_variant_new_string(player.uri));
    }
    return g_variant_builder_end(&b);
}

static GVariant *mime_types(void) {
    static const char *const types[] = {"audio/mpeg", "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav", "audio/vnd.wave", NULL};
    return g_variant_new_strv(types, -1);
}

static GVariant *root_get(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *name, GError **e, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)e; (void)d;
    if (!strcmp(name, "CanQuit")) return g_variant_new_boolean(TRUE);
    if (!strcmp(name, "CanRaise") || !strcmp(name, "HasTrackList")) return g_variant_new_boolean(FALSE);
    if (!strcmp(name, "Identity")) return g_variant_new_string("Audio Player");
    if (!strcmp(name, "DesktopEntry")) return g_variant_new_string("rediwm-player");
    if (!strcmp(name, "SupportedUriSchemes")) {
        static const char *const schemes[] = {"file", NULL};
        return g_variant_new_strv(schemes, -1);
    }
    if (!strcmp(name, "SupportedMimeTypes")) return mime_types();
    return NULL;
}

static GVariant *player_get(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *name, GError **e, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)e; (void)d;
    if (!strcmp(name, "PlaybackStatus")) return g_variant_new_string(player_status_name());
    if (!strcmp(name, "Rate") || !strcmp(name, "MinimumRate") || !strcmp(name, "MaximumRate")) return g_variant_new_double(1.0);
    if (!strcmp(name, "Volume")) return g_variant_new_double(rp_engine_volume(player.engine));
    if (!strcmp(name, "Position")) return g_variant_new_int64(player.path ? rp_engine_position_us(player.engine) : 0);
    if (!strcmp(name, "Metadata")) return metadata();
    if (!strcmp(name, "CanGoNext") || !strcmp(name, "CanGoPrevious")) return g_variant_new_boolean(FALSE);
    if (!strcmp(name, "CanPlay") || !strcmp(name, "CanPause") || !strcmp(name, "CanSeek") || !strcmp(name, "CanControl")) return g_variant_new_boolean(TRUE);
    return NULL;
}

static gboolean player_set(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *name, GVariant *value, GError **error, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)d;
    if (!strcmp(name, "Volume")) {
        player_set_volume(g_variant_get_double(value));
        return TRUE;
    }
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_PROPERTY_READ_ONLY, "%s is read-only", name);
    return FALSE;
}

static void root_call(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *method, GVariant *p, GDBusMethodInvocation *inv, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)p; (void)d;
    g_dbus_method_invocation_return_value(inv, NULL);
    if (!strcmp(method, "Quit")) player_quit();
}

static gboolean open_uri(const char *uri) {
    char *path = g_filename_from_uri(uri, NULL, NULL);
    if (!path && g_path_is_absolute(uri)) path = g_strdup(uri);
    if (!path) return FALSE;
    gboolean ok = player_open(path);
    g_free(path);
    return ok;
}

static void player_call(GDBusConnection *c, const gchar *s, const gchar *o, const gchar *i, const gchar *method, GVariant *p, GDBusMethodInvocation *inv, gpointer d) {
    (void)c; (void)s; (void)o; (void)i; (void)d;
    if (!strcmp(method, "OpenUri")) {
        const char *uri;
        g_variant_get(p, "(&s)", &uri);
        if (!open_uri(uri)) {
            g_dbus_method_invocation_return_error(inv, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "cannot play %s", uri);
            return;
        }
    } else if (!strcmp(method, "Play")) player_play();
    else if (!strcmp(method, "Pause")) player_pause();
    else if (!strcmp(method, "PlayPause")) player_toggle();
    else if (!strcmp(method, "Stop")) player_quit();
    else if (!strcmp(method, "Seek")) {
        gint64 offset;
        g_variant_get(p, "(x)", &offset);
        player_seek(offset);
    } else if (!strcmp(method, "SetPosition")) {
        const char *track;
        gint64 position;
        g_variant_get(p, "(&ox)", &track, &position);
        if (!strcmp(track, TRACK_ID)) player_set_position(position);
    }
    /* Next and Previous: there is no queue. */
    g_dbus_method_invocation_return_value(inv, NULL);
}

static void register_one(const char *xml, const char *iface, const GDBusInterfaceVTable *vtable) {
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(xml, NULL);
    g_dbus_connection_register_object(player.bus, MPRIS_PATH, g_dbus_node_info_lookup_interface(info, iface), vtable, NULL, NULL, NULL);
    g_dbus_node_info_unref(info);
}

void mpris_register(void) {
    static const GDBusInterfaceVTable root_vtable = {root_call, root_get, NULL, {0}};
    static const GDBusInterfaceVTable player_vtable = {player_call, player_get, player_set, {0}};
    register_one(root_xml, ROOT_IFACE, &root_vtable);
    register_one(player_xml, PLAYER_IFACE, &player_vtable);
}

void mpris_changed(void) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&props, "{sv}", "PlaybackStatus", g_variant_new_string(player_status_name()));
    g_variant_builder_add(&props, "{sv}", "Metadata", metadata());
    g_dbus_connection_emit_signal(player.bus, NULL, MPRIS_PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                  g_variant_new("(sa{sv}as)", PLAYER_IFACE, &props, NULL), NULL);
}

void mpris_seeked(void) {
    g_dbus_connection_emit_signal(player.bus, NULL, MPRIS_PATH, PLAYER_IFACE, "Seeked",
                                  g_variant_new("(x)", rp_engine_position_us(player.engine)), NULL);
}
