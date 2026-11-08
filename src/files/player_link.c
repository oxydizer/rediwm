/* Link to rediwm-player; see player_link.h. */
#define _GNU_SOURCE
#include "player_link.h"

#include <gio/gio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>

#define MPRIS_NAME "org.mpris.MediaPlayer2.rediwm"
#define MPRIS_PATH "/org/mpris/MediaPlayer2"
#define PLAYER_IFACE "org.mpris.MediaPlayer2.Player"

struct pl_link {
    GMainContext *context;
    GMainLoop *loop;
    GDBusConnection *bus; /* link thread only */
    gboolean owned;       /* the player's name has an owner; link thread only */
    int wake_fd;
    GMutex lock;
    pl_state state; /* the newest */
    int dirty;
    char *folder; /* link thread only */
    GPtrArray *playlist; /* immutable, published under lock */
};

typedef struct {
    pl_link *link;
    char *path, *executable;
    int scope;
    int toggle;
    int64_t offset;
} command;

static int64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Runs on the link thread, never the UI/audio thread. Freeze the folder until
 * a track from another folder is opened; navigation in Files cannot change it. */
static gint compare_paths(gconstpointer a, gconstpointer b)
{
    return g_strcmp0(*(char *const *)a, *(char *const *)b);
}

static GPtrArray *folder_tracks(const char *folder)
{
    GPtrArray *paths = g_ptr_array_new_with_free_func(g_free);
    GDir *dir = g_dir_open(folder, 0, NULL);
    if (!dir) return paths;
    const char *name;
    while ((name = g_dir_read_name(dir))) {
        const char *ext = strrchr(name, '.');
        /* Keep in step with player/formats.zig's built-in decoders. */
        if (!ext || (g_ascii_strcasecmp(ext, ".wav") && g_ascii_strcasecmp(ext, ".wave") &&
                     g_ascii_strcasecmp(ext, ".flac") && g_ascii_strcasecmp(ext, ".mp3"))) continue;
        char *path = g_build_filename(folder, name, NULL);
        if (g_file_test(path, G_FILE_TEST_IS_REGULAR) && g_utf8_validate(path, -1, NULL))
            g_ptr_array_add(paths, path);
        else g_free(path);
    }
    g_dir_close(dir);
    g_ptr_array_sort(paths, compare_paths);
    return paths;
}

pl_playlist *pl_get_playlist(pl_link *l)
{
    g_mutex_lock(&l->lock);
    GPtrArray *list = l->playlist ? g_ptr_array_ref(l->playlist) : NULL;
    g_mutex_unlock(&l->lock);
    return (pl_playlist *)list;
}

unsigned pl_playlist_count(const pl_playlist *list) { return ((const GPtrArray *)list)->len; }
const char *pl_playlist_path(const pl_playlist *list, unsigned index)
{
    const GPtrArray *paths = (const GPtrArray *)list;
    return index < paths->len ? paths->pdata[index] : "";
}
void pl_playlist_free(pl_playlist *list) { if (list) g_ptr_array_unref((GPtrArray *)list); }

static void publish(pl_link *l, const pl_state *state)
{
    char *folder = state->status && state->path[0] ? g_path_get_dirname(state->path) : NULL;
    gboolean changed = g_strcmp0(folder, l->folder) != 0;
    GPtrArray *tracks = changed && folder ? folder_tracks(folder) : NULL;
    g_free(l->folder);
    l->folder = folder;
    g_mutex_lock(&l->lock);
    if (changed) {
        if (l->playlist) g_ptr_array_unref(l->playlist);
        l->playlist = tracks;
    }
    l->state = *state;
    l->dirty = 1;
    g_mutex_unlock(&l->lock);
    uint64_t one = 1;
    ssize_t written = write(l->wake_fd, &one, sizeof one);
    (void)written; /* A full counter means a wake is already pending. */
}

static void got_properties(GObject *source, GAsyncResult *result, gpointer data)
{
    pl_link *l = data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    if (!reply)
        return; /* the name vanished; its watcher reports that */
    pl_state state = {0};
    state.stamp_ms = now_ms();
    GVariant *all = g_variant_get_child_value(reply, 0);
    GVariantIter iter;
    const char *key;
    GVariant *value;
    g_variant_iter_init(&iter, all);
    while (g_variant_iter_next(&iter, "{&sv}", &key, &value)) {
        if (!strcmp(key, "PlaybackStatus")) {
            const char *status = g_variant_get_string(value, NULL);
            state.status = !strcmp(status, "Playing") ? 1 : !strcmp(status, "Paused") ? 2 : 0;
        } else if (!strcmp(key, "Position") && g_variant_is_of_type(value, G_VARIANT_TYPE_INT64)) {
            state.position_us = g_variant_get_int64(value);
        } else if (!strcmp(key, "Metadata")) {
            const char *url;
            gint64 length;
            if (g_variant_lookup(value, "xesam:url", "&s", &url)) {
                char *path = g_filename_from_uri(url, NULL, NULL);
                if (path && strlen(path) < sizeof state.path)
                    memcpy(state.path, path, strlen(path) + 1);
                g_free(path);
            }
            if (g_variant_lookup(value, "mpris:length", "x", &length))
                state.length_us = length;
        }
        g_variant_unref(value);
    }
    g_variant_unref(all);
    g_variant_unref(reply);
    publish(l, &state);
}

static void refresh(pl_link *l)
{
    if (!l->owned)
        return;
    g_dbus_connection_call(l->bus, MPRIS_NAME, MPRIS_PATH, "org.freedesktop.DBus.Properties", "GetAll", g_variant_new("(s)", PLAYER_IFACE),
                           G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, NULL, got_properties, l);
}

static void on_signal(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *name, GVariant *p, gpointer data)
{
    (void)c; (void)sender; (void)path; (void)iface; (void)name; (void)p;
    refresh(data);
}

static void name_appeared(GDBusConnection *c, const gchar *name, const gchar *owner, gpointer data)
{
    (void)c; (void)name; (void)owner;
    pl_link *l = data;
    l->owned = TRUE;
    refresh(l);
}

static void name_vanished(GDBusConnection *c, const gchar *name, gpointer data)
{
    (void)c; (void)name;
    pl_link *l = data;
    l->owned = FALSE;
    pl_state none = {0};
    publish(l, &none);
}

static gpointer thread_main(gpointer data)
{
    pl_link *l = data;
    g_main_context_push_thread_default(l->context);
    l->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (l->bus) {
        g_dbus_connection_signal_subscribe(l->bus, MPRIS_NAME, "org.freedesktop.DBus.Properties", "PropertiesChanged", MPRIS_PATH, PLAYER_IFACE,
                                           G_DBUS_SIGNAL_FLAGS_NONE, on_signal, l, NULL);
        g_dbus_connection_signal_subscribe(l->bus, MPRIS_NAME, PLAYER_IFACE, "Seeked", MPRIS_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_signal, l, NULL);
        g_bus_watch_name_on_connection(l->bus, MPRIS_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE, name_appeared, name_vanished, l, NULL);
        g_main_loop_run(l->loop);
    }
    g_main_context_pop_thread_default(l->context);
    return NULL;
}

pl_link *pl_start(void)
{
    pl_link *l = g_new0(pl_link, 1);
    l->wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (l->wake_fd < 0) {
        g_free(l);
        return NULL;
    }
    g_mutex_init(&l->lock);
    l->context = g_main_context_new();
    l->loop = g_main_loop_new(l->context, FALSE);
    GThread *thread = g_thread_try_new("player-link", thread_main, l, NULL);
    if (!thread) {
        close(l->wake_fd);
        g_free(l);
        return NULL;
    }
    g_thread_unref(thread);
    return l;
}

void pl_stop_link(pl_link *l)
{
    /* The thread owns the memory from here on and ends with the process. */
    g_main_loop_quit(l->loop);
}

int pl_wake_fd(const pl_link *l)
{
    return l->wake_fd;
}

void pl_clear_wake(pl_link *l)
{
    uint64_t value;
    ssize_t n = read(l->wake_fd, &value, sizeof value);
    (void)n;
}

int pl_take(pl_link *l, pl_state *out)
{
    g_mutex_lock(&l->lock);
    *out = l->state;
    int changed = l->dirty;
    l->dirty = 0;
    g_mutex_unlock(&l->lock);
    return changed;
}

static void command_free(command *cmd)
{
    g_free(cmd->path);
    g_free(cmd->executable);
    g_free(cmd);
}

static void spawn_player(command *cmd)
{
    /* GLib reaps the child itself, so the player outlives Files. */
    char *argv[] = {cmd->executable, cmd->scope ? "--scope" : "--no-scope", "--", cmd->path, NULL};
    GError *error = NULL;
    g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, &error);
    g_clear_error(&error);
}

/* The player may have been on its way out (its track just ended): then the
 * request is answered by a new one instead of being lost. */
static void open_uri_done(GObject *source, GAsyncResult *result, gpointer data)
{
    command *cmd = data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    if (reply)
        g_variant_unref(reply);
    else
        spawn_player(cmd);
    command_free(cmd);
}

static gboolean run_command(gpointer data)
{
    command *cmd = data;
    pl_link *l = cmd->link;
    if (!l->bus) {
        /* No session bus: the player could not work either. */
    } else if (cmd->toggle) {
        if (l->owned)
            g_dbus_connection_call(l->bus, MPRIS_NAME, MPRIS_PATH, PLAYER_IFACE, cmd->toggle == 2 ? "Stop" : cmd->toggle == 3 ? "Seek" : "PlayPause",
                                   cmd->toggle == 3 ? g_variant_new("(x)", cmd->offset) : NULL, NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, NULL, NULL, NULL);
    } else if (l->owned) {
        char *uri = g_filename_to_uri(cmd->path, NULL, NULL);
        if (uri) {
            g_dbus_connection_call(l->bus, MPRIS_NAME, MPRIS_PATH, PLAYER_IFACE, "OpenUri", g_variant_new("(s)", uri), NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, NULL, open_uri_done, cmd);
            g_free(uri);
            return G_SOURCE_REMOVE; /* open_uri_done owns the command */
        }
    } else {
        spawn_player(cmd);
    }
    command_free(cmd);
    return G_SOURCE_REMOVE;
}

static void send_command(pl_link *l, command *cmd)
{
    cmd->link = l;
    g_main_context_invoke(l->context, run_command, cmd);
}

void pl_play(pl_link *l, const char *path, const char *executable, int scope)
{
    command *cmd = g_new0(command, 1);
    cmd->path = g_strdup(path);
    cmd->executable = g_strdup(executable);
    cmd->scope = scope;
    send_command(l, cmd);
}

void pl_play_pause(pl_link *l)
{
    command *cmd = g_new0(command, 1);
    cmd->toggle = 1;
    send_command(l, cmd);
}

void pl_stop_playback(pl_link *l)
{
    command *cmd = g_new0(command, 1);
    cmd->toggle = 2;
    send_command(l, cmd);
}

void pl_seek(pl_link *l, int64_t offset)
{
    command *cmd = g_new0(command, 1);
    cmd->toggle = 3;
    cmd->offset = offset;
    send_command(l, cmd);
}
