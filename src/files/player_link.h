/* Files' link to rediwm-player (MPRIS over the session bus).
 *
 * A GLib thread watches the player's bus name and publishes what it plays:
 * which file, whether it is playing and how far it is. Changes are announced
 * on an eventfd, so an idle Files makes no wakeups (position between changes
 * is extrapolated by the caller). The same thread starts the player or hands
 * it a file. Without a session bus everything is a no-op. No GLib headers
 * here: see AGENTS.md, "Build and platform gotchas". */
#ifndef REDIWM_PLAYER_LINK_H
#define REDIWM_PLAYER_LINK_H

#include <stdint.h>

typedef struct pl_link pl_link;
typedef struct pl_playlist pl_playlist;
/* Immutable folder snapshot; caller releases the returned reference. */
pl_playlist *pl_get_playlist(pl_link *link);
unsigned pl_playlist_count(const pl_playlist *list);
const char *pl_playlist_path(const pl_playlist *list, unsigned index);
void pl_playlist_free(pl_playlist *list);

typedef struct {
    int status;          /* 0: no player, 1: playing, 2: paused */
    char path[1024];     /* the current track's file name; empty if unknown or too long */
    int64_t position_us; /* where it was at `stamp_ms` */
    int64_t length_us;   /* 0 when unknown */
    int64_t stamp_ms;    /* CLOCK_MONOTONIC milliseconds of the position reading */
} pl_state;

/* Starts the thread. NULL when it cannot be started. */
pl_link *pl_start(void);
/* Ends the thread without waiting for it. */
void pl_stop_link(pl_link *link);

/* Readable when `pl_take` has something new. */
int pl_wake_fd(const pl_link *link);
void pl_clear_wake(pl_link *link);
/* Copies the newest state; 1 if it differs from the last one handed over. */
int pl_take(pl_link *link, pl_state *out);

/* Plays `path`: in the running player, or in a new one started from
 * `executable` (`scope` places it in its own app scope). */
void pl_play(pl_link *link, const char *path, const char *executable, int scope);
void pl_play_pause(pl_link *link);
void pl_stop_playback(pl_link *link);
void pl_seek(pl_link *link, int64_t offset);

#endif
