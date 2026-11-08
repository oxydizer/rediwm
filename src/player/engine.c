#include "engine.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "ma_config.h"
#include "../../third_party/miniaudio/miniaudio.h"

struct rp_engine {
    ma_context context;
    ma_decoder decoder;
    ma_device device;
    int have_context, have_track;
    /* Written by the main thread, read by the audio thread, or the reverse. */
    atomic_int ended;
    atomic_llong seek_to; /* output frame, or -1 */
    atomic_llong cursor;  /* output frames played */
    atomic_int running;   /* the device was started and not stopped since */
    double volume;
    uint32_t rate;
    uint64_t length_frames;
    rp_ended_fn ended_fn;
    void *user;
};

static void data_callback(ma_device *device, void *out, const void *in, ma_uint32 frames) {
    (void)in;
    rp_engine *e = device->pUserData;
    long long seek = atomic_exchange(&e->seek_to, -1);
    if (seek >= 0) {
        ma_decoder_seek_to_pcm_frame(&e->decoder, (ma_uint64)seek);
        atomic_store(&e->cursor, seek);
    }
    ma_uint64 read = 0;
    ma_decoder_read_pcm_frames(&e->decoder, out, frames, &read);
    atomic_fetch_add(&e->cursor, (long long)read);
    if (read < frames) {
        size_t size = ma_get_bytes_per_frame(ma_format_f32, e->decoder.outputChannels);
        memset((char *)out + read * size, 0, (frames - read) * size);
        if (!atomic_exchange(&e->ended, 1) && e->ended_fn) e->ended_fn(e->user);
    }
}

rp_engine *rp_engine_new(rp_ended_fn ended, void *user) {
    rp_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->ended_fn = ended;
    e->user = user;
    e->volume = 1.0;
    atomic_init(&e->seek_to, -1);
    /* Real backends only: miniaudio's default order ends in a null device
     * that would "play" into silence. PipeWire is served by its Pulse layer. */
#ifdef RP_TEST_NULL_DEVICE
    /* The test fixture's build (build/player.zig): miniaudio's null device is
     * paced like hardware and reaches no real audio. Never in the installed player. */
    static const ma_backend backends[] = {ma_backend_null};
#else
    static const ma_backend backends[] = {
        ma_backend_pulseaudio, ma_backend_alsa, ma_backend_jack, ma_backend_sndio, ma_backend_oss,
    };
#endif
    ma_context_config config = ma_context_config_init();
    config.pulse.pApplicationName = "Audio Player";
    if (ma_context_init(backends, sizeof backends / sizeof *backends, &config, &e->context) != MA_SUCCESS) {
        free(e);
        return NULL;
    }
    e->have_context = 1;
    return e;
}

void rp_engine_close(rp_engine *e) {
    if (!e->have_track) return;
    ma_device_uninit(&e->device); /* stops it first, so the callback is gone */
    ma_decoder_uninit(&e->decoder);
    e->have_track = 0;
    atomic_store(&e->running, 0);
}

void rp_engine_free(rp_engine *e) {
    if (!e) return;
    rp_engine_close(e);
    if (e->have_context) ma_context_uninit(&e->context);
    free(e);
}

int rp_engine_open(rp_engine *e, const char *path) {
    rp_engine_close(e);
    ma_decoder_config decoding = ma_decoder_config_init(ma_format_f32, 0, 0);
    if (ma_decoder_init_file(path, &decoding, &e->decoder) != MA_SUCCESS) return -1;
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = e->decoder.outputChannels;
    config.sampleRate = e->decoder.outputSampleRate;
    config.dataCallback = data_callback;
    config.pUserData = e;
    /* Long periods keep the wakeups down; nothing here is interactive. */
    config.periodSizeInMilliseconds = 50;
    config.periods = 3;
    config.pulse.pStreamNamePlayback = "Audio Player";
    if (ma_device_init(&e->context, &config, &e->device) != MA_SUCCESS) {
        ma_decoder_uninit(&e->decoder);
        return -2;
    }
    e->have_track = 1;
    e->rate = e->decoder.outputSampleRate;
    ma_uint64 length = 0;
    e->length_frames = ma_decoder_get_length_in_pcm_frames(&e->decoder, &length) == MA_SUCCESS ? length : 0;
    atomic_store(&e->ended, 0);
    atomic_store(&e->cursor, 0);
    atomic_store(&e->seek_to, -1);
    ma_device_set_master_volume(&e->device, (float)e->volume);
    return rp_engine_resume(e) == 0 ? 0 : -2;
}

int rp_engine_resume(rp_engine *e) {
    if (!e->have_track) return -1;
    if (atomic_load(&e->running)) return 0;
    if (atomic_load(&e->ended)) {
        /* Replaying a finished track starts it over. */
        ma_decoder_seek_to_pcm_frame(&e->decoder, 0);
        atomic_store(&e->cursor, 0);
        atomic_store(&e->ended, 0);
    }
    if (ma_device_start(&e->device) != MA_SUCCESS) return -1;
    atomic_store(&e->running, 1);
    return 0;
}

void rp_engine_pause(rp_engine *e) {
    if (!e->have_track || !atomic_load(&e->running)) return;
    ma_device_stop(&e->device);
    atomic_store(&e->running, 0);
}

int rp_engine_playing(rp_engine *e) {
    return e->have_track && atomic_load(&e->running) && !atomic_load(&e->ended);
}

int64_t rp_engine_position_us(rp_engine *e) {
    if (!e->have_track || e->rate == 0) return 0;
    long long frames = atomic_load(&e->cursor);
    return (int64_t)((double)frames * 1000000.0 / e->rate);
}

int64_t rp_engine_length_us(rp_engine *e) {
    if (!e->have_track || e->rate == 0) return 0;
    return (int64_t)((double)e->length_frames * 1000000.0 / e->rate);
}

void rp_engine_seek_us(rp_engine *e, int64_t position) {
    if (!e->have_track || e->rate == 0) return;
    if (position < 0) position = 0;
    long long frame = (long long)((double)position * e->rate / 1000000.0);
    if (e->length_frames > 0 && (uint64_t)frame >= e->length_frames) frame = (long long)e->length_frames - 1;
    if (frame < 0) frame = 0;
    if (atomic_load(&e->running)) {
        atomic_store(&e->cursor, frame); /* position reads see it at once */
        atomic_store(&e->seek_to, frame); /* applied by the next callback */
    } else {
        /* The device is stopped, so nothing else touches the decoder. */
        ma_decoder_seek_to_pcm_frame(&e->decoder, (ma_uint64)frame);
        atomic_store(&e->cursor, frame);
        atomic_store(&e->ended, 0);
    }
}

void rp_engine_set_volume(rp_engine *e, double volume) {
    if (volume < 0) volume = 0;
    if (volume > 1.5) volume = 1.5;
    e->volume = volume;
    if (e->have_track) ma_device_set_master_volume(&e->device, (float)volume);
}

double rp_engine_volume(rp_engine *e) {
    return e->volume;
}
