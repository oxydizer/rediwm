/* rediwm-player: a small background audio player.
 *
 * One instance per session owns the audio device and the one track it plays.
 * It is driven over D-Bus through MPRIS (mpris.c), which is also how Files
 * starts and observes it, and shows a StatusNotifier item with a menu (tray.c).
 * It has no window, makes no wakeups while paused, and exits when the track
 * ends or is stopped. */
#ifndef REDIWM_PLAYER_H
#define REDIWM_PLAYER_H

#include <gio/gio.h>

#include "engine.h"

#define MPRIS_NAME "org.mpris.MediaPlayer2.rediwm"
#define MPRIS_PATH "/org/mpris/MediaPlayer2"

typedef enum { PL_STOPPED, PL_PLAYING, PL_PAUSED } pl_status;

typedef struct {
    GDBusConnection *bus;
    GMainLoop *loop;
    rp_engine *engine;
    char *path;  /* absolute file name of the current track */
    char *title; /* shown name: the file name without its extension */
    char *uri;   /* file:// URI of the current track */
    pl_status status;
} Player;

extern Player player;

/* Opens and starts a track, replacing the current one. FALSE (and the player
 * stopped) when it cannot be played. */
gboolean player_open(const char *path);
void player_play(void);
void player_pause(void);
void player_toggle(void);
/* Ends the program. */
void player_quit(void);
void player_seek(gint64 offset_us);
void player_set_position(gint64 position_us);
void player_set_volume(double volume);
const char *player_status_name(void);

/* The track or status changed: tell MPRIS clients and the tray. */
void player_changed(void);

void mpris_register(void);
void mpris_changed(void);
void mpris_seeked(void);

/* `scope`: place the process in its own app scope (see session/app_scope.zig). */
void tray_register(void);
void tray_changed(void);
void tray_place_scope(void);

#endif
