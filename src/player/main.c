/* rediwm-player [--scope] [--] FILE
 *
 * Plays FILE in the session's player. If a player is already running, FILE is
 * handed to it with MPRIS OpenUri and this process exits at once. */
#include <glib-unix.h>
#include <stdlib.h>
#include <string.h>

#include "player.h"

Player player = {0};
static char *initial_path;
static gboolean use_scope;
static int exit_code;

const char *player_status_name(void) {
    switch (player.status) {
    case PL_PLAYING: return "Playing";
    case PL_PAUSED: return "Paused";
    default: return "Stopped";
    }
}

void player_changed(void) {
    mpris_changed();
    tray_changed();
}

void player_quit(void) {
    player.status = PL_STOPPED;
    if (player.loop) g_main_loop_quit(player.loop);
}

static void clear_track(void) {
    g_clear_pointer(&player.path, g_free);
    g_clear_pointer(&player.title, g_free);
    g_clear_pointer(&player.uri, g_free);
}

gboolean player_open(const char *path) {
    char *absolute = g_canonicalize_filename(path, NULL);
    if (rp_engine_open(player.engine, absolute) != 0) {
        g_printerr("rediwm-player: cannot play %s\n", absolute);
        g_free(absolute);
        clear_track();
        exit_code = 1;
        player_quit();
        return FALSE;
    }
    clear_track();
    player.path = absolute;
    char *base = g_path_get_basename(absolute);
    char *dot = strrchr(base, '.');
    if (dot && dot != base) *dot = 0;
    player.title = base;
    player.uri = g_filename_to_uri(absolute, NULL, NULL);
    player.status = PL_PLAYING;
    player_changed();
    return TRUE;
}

void player_play(void) {
    if (player.status == PL_STOPPED || !player.path) return;
    if (rp_engine_resume(player.engine) == 0) player.status = PL_PLAYING;
    player_changed();
}

void player_pause(void) {
    if (player.status != PL_PLAYING) return;
    rp_engine_pause(player.engine);
    player.status = PL_PAUSED;
    player_changed();
}

void player_toggle(void) {
    if (player.status == PL_PLAYING) player_pause(); else player_play();
}

void player_seek(gint64 offset_us) {
    if (!player.path) return;
    player_set_position(rp_engine_position_us(player.engine) + offset_us);
}

void player_set_position(gint64 position_us) {
    if (!player.path) return;
    rp_engine_seek_us(player.engine, position_us);
    mpris_seeked();
}

void player_set_volume(double volume) {
    rp_engine_set_volume(player.engine, volume);
}

/* The audio thread's end-of-track report, moved to the main loop. */
static gboolean track_ended(gpointer data) {
    (void)data;
    player_quit();
    return G_SOURCE_REMOVE;
}

static void ended(void *user) {
    (void)user;
    g_main_context_invoke(NULL, track_ended, NULL);
}

static gboolean on_signal(gpointer data) {
    (void)data;
    player_quit();
    return G_SOURCE_REMOVE;
}

/* Asks the running player to play `path`. TRUE when it accepted. */
static gboolean forward(const char *path) {
    char *absolute = g_canonicalize_filename(path, NULL);
    char *uri = g_filename_to_uri(absolute, NULL, NULL);
    g_free(absolute);
    if (!uri) return FALSE;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(player.bus, MPRIS_NAME, MPRIS_PATH, "org.mpris.MediaPlayer2.Player", "OpenUri",
                                                  g_variant_new("(s)", uri), NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, NULL, &error);
    g_free(uri);
    g_clear_error(&error);
    if (reply) g_variant_unref(reply);
    return reply != NULL;
}

static void name_acquired(GDBusConnection *connection, const gchar *name, gpointer data) {
    (void)connection;
    (void)name;
    (void)data;
    if (use_scope) tray_place_scope();
    tray_register();
    if (initial_path) player_open(initial_path);
}

static void name_lost(GDBusConnection *connection, const gchar *name, gpointer data) {
    (void)connection;
    (void)name;
    (void)data;
    /* Another player won the race for the name: give it the file. */
    if (player.status == PL_STOPPED && initial_path && forward(initial_path)) {
        player_quit();
        return;
    }
    exit_code = 1;
    player_quit();
}

int main(int argc, char **argv) {
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--scope")) use_scope = TRUE;
        else if (!strcmp(argv[i], "--no-scope")) use_scope = FALSE;
        else if (!strcmp(argv[i], "--")) { i++; break; }
        else break;
    }
    if (i < argc) initial_path = argv[i];
    GError *error = NULL;
    player.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!player.bus) {
        g_printerr("rediwm-player: no session bus: %s\n", error->message);
        return 1;
    }
    if (initial_path && forward(initial_path)) return 0;
    if (!initial_path) {
        g_printerr("usage: rediwm-player [--scope] [--] FILE\n");
        return 2;
    }
    player.engine = rp_engine_new(ended, NULL);
    if (!player.engine) {
        g_printerr("rediwm-player: no audio output available\n");
        return 1;
    }
    player.loop = g_main_loop_new(NULL, FALSE);
    g_unix_signal_add(SIGTERM, on_signal, NULL);
    g_unix_signal_add(SIGINT, on_signal, NULL);
    mpris_register();
    g_bus_own_name_on_connection(player.bus, MPRIS_NAME, G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE, name_acquired, name_lost, NULL, NULL);
    g_main_loop_run(player.loop);
    rp_engine_free(player.engine);
    clear_track();
    g_main_loop_unref(player.loop);
    g_object_unref(player.bus);
    return exit_code;
}
