/* Single producer (the FFmpeg audio worker), single consumer (miniaudio).
 * Publish complete stereo blocks with their media timestamps. Only the main
 * thread starts/stops the device. Reset requires a stopped device and the
 * producer lock. Neither lock nor allocator is used by the callback. */
#define _POSIX_C_SOURCE 200809L
#include "../player/ma_config.h"
#include "../../third_party/miniaudio/miniaudio.h"
#include <errno.h>
#include <stdatomic.h>
#ifdef RV_TEST_NULL_DEVICE
#include <stdio.h>
#endif
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { RATE = 48000, CHANNELS = 2, BLOCK = 1024, SLOTS = 32 };
#define NS INT64_C(1000000000)
struct block { float pcm[BLOCK * CHANNELS]; unsigned count; int64_t first_sample; };
struct rv_audio {
    ma_context context;
    ma_device device;
    struct block slots[SLOTS];
    atomic_uint head, tail;
    unsigned offset; /* consumer only */
    atomic_bool eof, drained;
    atomic_uint volume; /* percentage, written by the UI */
    float gain, target_gain, gain_step;
    unsigned ramp_left;
    atomic_int_fast64_t clock_offset, limit;
    int64_t latency, cursor, last_media_end;
    int space_fd, main_fd;
#ifdef RV_TEST_NULL_DEVICE
    uint64_t nonzero_frames;
    float peak;
#endif
};

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * NS + t.tv_nsec;
}

static void wake(int fd) {
    const uint64_t one = 1;
    while (write(fd, &one, sizeof one) < 0 && errno == EINTR) {}
}

static int64_t sample_time(int64_t sample) {
    return (sample / RATE) * NS + (sample % RATE) * NS / RATE;
}

static void callback(ma_device *dev, void *output, const void *input, ma_uint32 count) {
    (void)input;
    struct rv_audio *a = dev->pUserData;
    float *out = output;
    const int64_t now = now_ns();
    unsigned used = 0, head = atomic_load(&a->head);
    memset(out, 0, count * CHANNELS * sizeof(float));
    while (used < count && head != atomic_load(&a->tail)) {
        struct block *b = &a->slots[head % SLOTS];
        int64_t start = b->first_sample + a->offset;
        if (a->cursor == INT64_MIN) a->cursor = start;
        if (start > a->cursor) {
            int64_t gap = start - a->cursor;
            unsigned silence = gap < count - used ? (unsigned)gap : count - used;
            a->cursor += silence;
            used += silence;
            continue;
        }
        unsigned n = b->count - a->offset;
        if (start < a->cursor) {
            int64_t late = a->cursor - start;
            if (late < n) n = (unsigned)late;
        } else {
            if (n > count - used) n = count - used;
            memcpy(out + used * CHANNELS, b->pcm + a->offset * CHANNELS, n * CHANNELS * sizeof(float));
            used += n;
            a->cursor += n;
            a->last_media_end = sample_time(a->cursor);
        }
        a->offset += n;
        if (a->offset == b->count) {
            a->offset = 0;
            atomic_store(&a->head, ++head);
            wake(a->space_fd);
        }
    }
    float target = (float)atomic_load_explicit(&a->volume, memory_order_relaxed) / 100.0f;
    if (target != a->target_gain) {
        a->target_gain = target;
        a->ramp_left = RATE / 200; /* 5 ms */
        a->gain_step = (target - a->gain) / (float)a->ramp_left;
    }
    if (a->ramp_left || a->gain != 1.0f) {
        for (unsigned i = 0; i < count; ++i) {
            if (a->ramp_left) {
                a->gain += a->gain_step;
                if (--a->ramp_left == 0) a->gain = a->target_gain;
            }
            out[i * CHANNELS] *= a->gain;
            out[i * CHANNELS + 1] *= a->gain;
        }
    }
#ifdef RV_TEST_NULL_DEVICE
    for (unsigned i = 0; i < used; ++i) {
        float value = out[i * CHANNELS];
        if (value != 0.0f) ++a->nonzero_frames;
        float magnitude = value < 0.0f ? -value : value;
        if (magnitude > a->peak) a->peak = magnitude;
    }
#endif
    /* Silence is also paced by the device. In particular, when audio ends
     * well before video, the bounded video queue can hold the demuxer short
     * of EOF. Freezing the master on its last PCM sample would deadlock it. */
    if (a->cursor != INT64_MIN) {
        a->cursor += count - used;
        int64_t end = sample_time(a->cursor);
        atomic_store(&a->limit, end);
        atomic_store(&a->clock_offset, end - a->latency - now);
        if (atomic_load(&a->eof) && head == atomic_load(&a->tail) &&
            end - a->latency >= a->last_media_end && !atomic_exchange(&a->drained, 1))
            wake(a->main_fd);
    }
}

struct rv_audio *rv_audio_open(int space_fd, int main_fd) {
#ifdef RV_TEST_NULL_DEVICE
    static const ma_backend backends[] = {ma_backend_null};
#else
    static const ma_backend backends[] = {
        ma_backend_pulseaudio, ma_backend_alsa, ma_backend_jack, ma_backend_sndio, ma_backend_oss
    };
#endif
    struct rv_audio *a = calloc(1, sizeof *a);
    if (!a) return NULL;
    a->space_fd = space_fd;
    a->main_fd = main_fd;
    atomic_init(&a->volume, 100);
    a->gain = a->target_gain = 1.0f;
    ma_context_config context = ma_context_config_init();
    context.pulse.pApplicationName = "Videos";
    if (ma_context_init(backends, sizeof backends / sizeof *backends, &context, &a->context) != MA_SUCCESS) goto failed;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = CHANNELS;
    cfg.sampleRate = RATE;
    cfg.periodSizeInMilliseconds = 10;
    cfg.pUserData = a;
    cfg.dataCallback = callback;
    if (ma_device_init(&a->context, &cfg, &a->device) != MA_SUCCESS) {
        ma_context_uninit(&a->context);
        goto failed;
    }
    a->latency = NS * a->device.playback.internalPeriodSizeInFrames *
        a->device.playback.internalPeriods / a->device.playback.internalSampleRate;
    return a;
failed:
    free(a);
    return NULL;
}

void rv_audio_close(struct rv_audio *a) {
    ma_device_uninit(&a->device);
#ifdef RV_TEST_NULL_DEVICE
    fprintf(stderr, "null device played %llu nonzero frames, peak %.6f\n",
            (unsigned long long)a->nonzero_frames, a->peak);
#endif
    ma_context_uninit(&a->context);
    free(a);
}

void rv_audio_volume(struct rv_audio *a, unsigned percent) { atomic_store(&a->volume, percent); }
int rv_audio_start(struct rv_audio *a) { return ma_device_start(&a->device) == MA_SUCCESS; }
void rv_audio_stop(struct rv_audio *a) { ma_device_stop(&a->device); }
void rv_audio_eof(struct rv_audio *a) { atomic_store(&a->eof, 1); }
int rv_audio_drained(struct rv_audio *a) { return atomic_load(&a->drained); }
/* The old producer is joined and the callback stopped before handoff. */
void rv_audio_rebind(struct rv_audio *a, int space_fd, int main_fd) {
    a->space_fd = space_fd;
    a->main_fd = main_fd;
}
void rv_audio_reset(struct rv_audio *a) {
    atomic_store(&a->head, 0);
    atomic_store(&a->tail, 0);
    atomic_store(&a->drained, 0);
    atomic_store(&a->eof, 0);
    atomic_store(&a->clock_offset, INT64_MIN);
    a->offset = 0;
    a->cursor = INT64_MIN;
    a->last_media_end = 0;
}

int64_t rv_audio_clock(struct rv_audio *a) {
    int64_t offset = atomic_load(&a->clock_offset);
    if (offset == INT64_MIN) return INT64_MIN;
    int64_t clock = now_ns() + offset, limit = atomic_load(&a->limit);
    return clock < limit ? clock : limit;
}

/* Called under the producer lock while the device is stopped. */
int64_t rv_audio_first(struct rv_audio *a) {
    unsigned head = atomic_load(&a->head);
    if (a->cursor != INT64_MIN) return sample_time(a->cursor);
    return head == atomic_load(&a->tail) ? INT64_MIN :
        sample_time(a->slots[head % SLOTS].first_sample + a->offset);
}

unsigned rv_audio_write(struct rv_audio *a, const float *pcm, unsigned n, int64_t first_sample) {
    unsigned tail = atomic_load(&a->tail);
    if (tail - atomic_load(&a->head) == SLOTS) return 0;
    if (n > BLOCK) n = BLOCK;
    struct block *b = &a->slots[tail % SLOTS];
    memcpy(b->pcm, pcm, n * CHANNELS * sizeof(float));
    b->count = n;
    b->first_sample = first_sample;
    atomic_store(&a->tail, tail + 1);
    return n;
}
