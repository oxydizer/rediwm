/* The audio engine of rediwm-player: one decoded file played through one
 * miniaudio device. No GLib headers here.
 *
 * The data callback runs on miniaudio's audio thread and never blocks; every
 * other call belongs to the main thread. The device only runs while playing:
 * pausing stops it, so a paused player makes no wakeups. */
#ifndef REDIWM_PLAYER_ENGINE_H
#define REDIWM_PLAYER_ENGINE_H

#include <stdint.h>

typedef struct rp_engine rp_engine;

/* Called on the audio thread, once, when the track played to its end. It must
 * only hand the event to another thread. */
typedef void (*rp_ended_fn)(void *user);

/* NULL when no playback backend can be started. */
rp_engine *rp_engine_new(rp_ended_fn ended, void *user);
void rp_engine_free(rp_engine *e);

/* Replaces the current track and starts it. 0 on success; -1 when the file
 * cannot be decoded, -2 when no output device can be opened. */
int rp_engine_open(rp_engine *e, const char *path);
/* Drops the current track and releases the device. */
void rp_engine_close(rp_engine *e);

int rp_engine_resume(rp_engine *e);
void rp_engine_pause(rp_engine *e);
int rp_engine_playing(rp_engine *e);

/* Microseconds; the length is 0 when the format cannot tell. */
int64_t rp_engine_position_us(rp_engine *e);
int64_t rp_engine_length_us(rp_engine *e);
/* Clamped to the track. */
void rp_engine_seek_us(rp_engine *e, int64_t position);

void rp_engine_set_volume(rp_engine *e, double volume);
double rp_engine_volume(rp_engine *e);

#endif
