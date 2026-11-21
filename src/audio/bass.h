#pragma once
#include <stdbool.h>
struct rediwm_bass;
struct rediwm_bass *rediwm_bass_create(void (*notify)(void *), void *data);
void rediwm_bass_destroy(struct rediwm_bass *bass);
/* 0: unavailable, 1: ready, 2: setting could not be saved. */
int rediwm_bass_get(struct rediwm_bass *bass, float *gain, float *treble);
/* Bass boost in dB, 0..12. */
bool rediwm_bass_set(struct rediwm_bass *bass, float gain);
/* Treble cut or boost in dB, -6..6. */
bool rediwm_bass_set_treble(struct rediwm_bass *bass, float treble);
/* Fades the filter's output out (true) or back in. Safe from any thread and
 * under any lock. Returns whether the filter is live, i.e. a fade will play. */
bool rediwm_bass_set_mute(struct rediwm_bass *bass, bool muted);
/* PipeWire is evidently up again (the PulseAudio connection came back):
 * retry a lost connection that backed off or gave up. Same thread and lock
 * rules as rediwm_bass_set_mute. */
void rediwm_bass_reconnect(struct rediwm_bass *bass);
