/* Bass boost and treble DSP, loaded by bass.c's filter-chain as a LADSPA
 * plugin (installed as lib/rediwm/ladspa/rediwm-bass.so next to the binaries).
 *
 * A low shelf adds real bass for headphones and speakers that can play it.
 * Small speakers can't, so the band below the shelf corner also drives a
 * harmonic generator: its 2nd and 3rd harmonics, band-limited to the low mids,
 * make the ear hear the fundamental the speaker is missing. Both back off
 * while the bass band is already loud, and a lookahead peak limiter replaces
 * a preamp cut, so the slider raises bass instead of lowering everything else.
 *
 * Treble is a high shelf ahead of the same limiter. It has no backoff: treble
 * peaks are transients a level detector misses, so only the limiter can catch
 * them.
 *
 * Mute fades the output out and back in. The filter stays in the graph even
 * when flat so this works; the host mutes the device itself once the fade has
 * played (pipewire.zig).
 *
 * Runs on PipeWire's data thread inside the compositor: run() never
 * allocates or blocks, and non-finite input can't poison the filter state. */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The LADSPA 1.1 ABI; ladspa.h isn't installed everywhere. */
typedef float LADSPA_Data;
typedef void *LADSPA_Handle;
typedef struct {
    int HintDescriptor;
    LADSPA_Data LowerBound, UpperBound;
} LADSPA_PortRangeHint;
typedef struct LADSPA_Descriptor {
    unsigned long UniqueID;
    const char *Label;
    int Properties;
    const char *Name, *Maker, *Copyright;
    unsigned long PortCount;
    const int *PortDescriptors;
    const char *const *PortNames;
    const LADSPA_PortRangeHint *PortRangeHints;
    void *ImplementationData;
    LADSPA_Handle (*instantiate)(const struct LADSPA_Descriptor *descriptor, unsigned long rate);
    void (*connect_port)(LADSPA_Handle instance, unsigned long port, LADSPA_Data *data);
    void (*activate)(LADSPA_Handle instance);
    void (*run)(LADSPA_Handle instance, unsigned long count);
    void (*run_adding)(LADSPA_Handle instance, unsigned long count);
    void (*set_run_adding_gain)(LADSPA_Handle instance, LADSPA_Data gain);
    void (*deactivate)(LADSPA_Handle instance);
    void (*cleanup)(LADSPA_Handle instance);
} LADSPA_Descriptor;
enum {
    PROPERTY_HARD_RT_CAPABLE = 0x4,
    PORT_INPUT = 0x1, PORT_OUTPUT = 0x2, PORT_CONTROL = 0x4, PORT_AUDIO = 0x8,
    HINT_BOUNDED = 0x3, HINT_LOGARITHMIC = 0x10,
    HINT_DEFAULT_MIDDLE = 0xC0, HINT_DEFAULT_HIGH = 0x100, HINT_DEFAULT_0 = 0x200, HINT_DEFAULT_1 = 0x240,
};

#define PI 3.14159265358979323846
#define SQRT1_2 0.70710678118654752440
/* Harmonic level relative to the bass band at full Amount and Harmonics = 1,
 * and the 3rd harmonic's level relative to the 2nd. */
#define HARMONIC_LEVEL 1.0
#define THIRD_HARMONIC 0.6
/* Mute fade lengths in seconds: long enough to hear as a fade, short enough
 * that muting still feels immediate. pipewire.zig waits for the fade out. */
#define MUTE_FADE_OUT 0.200
#define MUTE_FADE_IN 0.340

enum {
    IN_L, IN_R, OUT_L, OUT_R,
    AMOUNT,    /* dB of low shelf: the Settings slider */
    CORNER,    /* Hz: shelf corner and top of the harmonic source band */
    HARMONICS, /* harmonic level scale */
    HEADROOM,  /* dBFS the boosted bass band may reach before the boost backs off */
    CEILING,   /* dBFS limiter ceiling */
    TREBLE,    /* dB of high shelf, cut or boost: the second Settings slider */
    TREBLE_CORNER, /* Hz: high shelf corner */
    LATENCY,   /* output: lookahead in samples, reported to PipeWire */
    MUTE,      /* 1 fades the output out, 0 back in */
    PORT_COUNT
};

static const int port_descriptors[PORT_COUNT] = {
    [IN_L] = PORT_INPUT | PORT_AUDIO, [IN_R] = PORT_INPUT | PORT_AUDIO,
    [OUT_L] = PORT_OUTPUT | PORT_AUDIO, [OUT_R] = PORT_OUTPUT | PORT_AUDIO,
    [AMOUNT] = PORT_INPUT | PORT_CONTROL, [CORNER] = PORT_INPUT | PORT_CONTROL,
    [HARMONICS] = PORT_INPUT | PORT_CONTROL, [HEADROOM] = PORT_INPUT | PORT_CONTROL,
    [CEILING] = PORT_INPUT | PORT_CONTROL, [TREBLE] = PORT_INPUT | PORT_CONTROL,
    [TREBLE_CORNER] = PORT_INPUT | PORT_CONTROL, [LATENCY] = PORT_OUTPUT | PORT_CONTROL,
    [MUTE] = PORT_INPUT | PORT_CONTROL,
};
static const char *const port_names[PORT_COUNT] = {
    "InL", "InR", "OutL", "OutR", "Amount", "Corner", "Harmonics", "Headroom", "Ceiling",
    "Treble", "TrebleCorner", "latency", "Mute",
};
static const LADSPA_PortRangeHint port_hints[PORT_COUNT] = {
    [AMOUNT] = { HINT_BOUNDED | HINT_DEFAULT_0, 0, 12 },
    /* The logarithmic middle of 40..490 is 140 Hz. */
    [CORNER] = { HINT_BOUNDED | HINT_LOGARITHMIC | HINT_DEFAULT_MIDDLE, 40, 490 },
    [HARMONICS] = { HINT_BOUNDED | HINT_DEFAULT_1, 0, 2 },
    /* The middle of -12..6 is -3 dBFS: loud bass backs off before the rest of
     * the mix has to go through the limiter. */
    [HEADROOM] = { HINT_BOUNDED | HINT_DEFAULT_MIDDLE, -12, 6 },
    /* The high default of -4..0 is -1 dBFS. */
    [CEILING] = { HINT_BOUNDED | HINT_DEFAULT_HIGH, -4, 0 },
    [TREBLE] = { HINT_BOUNDED | HINT_DEFAULT_0, -6, 6 },
    /* The logarithmic middle of 2000..18000 is 6 kHz: above the 2-5 kHz range
     * where a boost turns harsh. */
    [TREBLE_CORNER] = { HINT_BOUNDED | HINT_LOGARITHMIC | HINT_DEFAULT_MIDDLE, 2000, 18000 },
    [MUTE] = { HINT_BOUNDED | HINT_DEFAULT_0, 0, 1 },
};

typedef struct { double b0, b1, b2, a1, a2; } biquad;
typedef struct { double z1, z2; } biquad_state;

enum filter_type { LOWPASS, HIGHPASS, LOW_SHELF, HIGH_SHELF };

/* RBJ cookbook biquads with Q = 1/sqrt(2). */
static biquad design(enum filter_type type, double rate, double freq, double gain_db) {
    double w = 2 * PI * freq / rate, c = cos(w), alpha = sin(w) * SQRT1_2;
    double b0, b1, b2, a0, a1 = -2 * c, a2;
    if (type == LOW_SHELF) {
        double a = pow(10, gain_db / 40), s = 2 * sqrt(a) * alpha;
        b0 = a * ((a + 1) - (a - 1) * c + s);
        b1 = 2 * a * ((a - 1) - (a + 1) * c);
        b2 = a * ((a + 1) - (a - 1) * c - s);
        a0 = (a + 1) + (a - 1) * c + s;
        a1 = -2 * ((a - 1) + (a + 1) * c);
        a2 = (a + 1) + (a - 1) * c - s;
    } else if (type == HIGH_SHELF) {
        double a = pow(10, gain_db / 40), s = 2 * sqrt(a) * alpha;
        b0 = a * ((a + 1) + (a - 1) * c + s);
        b1 = -2 * a * ((a - 1) + (a + 1) * c);
        b2 = a * ((a + 1) + (a - 1) * c - s);
        a0 = (a + 1) - (a - 1) * c + s;
        a1 = 2 * ((a - 1) - (a + 1) * c);
        a2 = (a + 1) - (a - 1) * c - s;
    } else {
        b0 = b2 = type == LOWPASS ? (1 - c) / 2 : (1 + c) / 2;
        b1 = type == LOWPASS ? 1 - c : -(1 + c);
        a0 = 1 + alpha;
        a2 = 1 - alpha;
    }
    return (biquad){ b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 };
}

/* Transposed direct form II in double precision: stable for low corners at
 * any sample rate. */
static inline double filter(const biquad *f, biquad_state *s, double x) {
    double y = f->b0 * x + s->z1;
    s->z1 = f->b1 * x - f->a1 * y + s->z2;
    s->z2 = f->b2 * x - f->a2 * y;
    return y;
}

struct bass {
    LADSPA_Data *port[PORT_COUNT];
    double rate;
    float amount, corner, treble, treble_corner; /* what the filters are designed for */
    biquad shelf, band, harmonic_hp, harmonic_lp, treble_shelf;
    biquad_state shelf_state[2], band_state[2], harmonic_state[2], treble_state[2];
    /* Bass band envelopes: waveform peak (normalises the harmonic generator)
     * and level (drives the backoff). */
    double peak, level, peak_release, level_attack, level_release;
    /* Limiter: the output is delayed by `lookahead`, and its gain follows the
     * smallest gain any sample in the last `window` needs (lookahead + hold),
     * kept in a monotonic queue. */
    double gain, gain_attack, gain_release;
    uint32_t lookahead, window, pos, queue_head, queue_len;
    uint64_t now;
    float *delay;
    double *queue_gain;
    uint64_t *queue_time;
    /* Mute: `fade` runs linearly from 1 (audible) to 0; the output gain is
     * its square, an even-sounding fade that ends without a slope. */
    double fade, fade_out_step, fade_in_step;
    /* Unset until the first run, which starts at the Mute control's state:
     * a filter activated while muted mustn't fade out from full volume. */
    bool fade_primed;
};

static void reset(struct bass *b) {
    memset(b->shelf_state, 0, sizeof(b->shelf_state));
    memset(b->band_state, 0, sizeof(b->band_state));
    memset(b->harmonic_state, 0, sizeof(b->harmonic_state));
    memset(b->treble_state, 0, sizeof(b->treble_state));
    memset(b->delay, 0, 2 * (size_t)b->lookahead * sizeof(*b->delay));
    b->peak = b->level = 0;
    b->gain = 1;
    b->fade = 1;
    b->fade_primed = false;
    b->pos = b->queue_head = b->queue_len = 0;
    b->now = 0;
}

static void cleanup(LADSPA_Handle handle) {
    struct bass *b = handle;
    free(b->delay);
    free(b->queue_gain);
    free(b->queue_time);
    free(b);
}

static LADSPA_Handle instantiate(const LADSPA_Descriptor *descriptor, unsigned long rate) {
    (void)descriptor;
    if (rate < 8000 || rate > 768000) return NULL;
    struct bass *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->rate = (double)rate;
    b->lookahead = (uint32_t)lround(0.002 * b->rate);
    b->window = b->lookahead + (uint32_t)lround(0.020 * b->rate);
    b->delay = calloc(2 * (size_t)b->lookahead, sizeof(*b->delay));
    b->queue_gain = calloc(b->window + 1, sizeof(*b->queue_gain));
    b->queue_time = calloc(b->window + 1, sizeof(*b->queue_time));
    if (!b->delay || !b->queue_gain || !b->queue_time) {
        cleanup(b);
        return NULL;
    }
    b->peak_release = exp(-1 / (0.060 * b->rate));
    b->level_attack = 1 - exp(-1 / (0.005 * b->rate));
    b->level_release = 1 - exp(-1 / (0.300 * b->rate));
    /* 98% of the way to a new gain before the sample needing it comes out. */
    b->gain_attack = 1 - exp(-4.0 / b->lookahead);
    b->gain_release = 1 - exp(-1 / (0.100 * b->rate));
    b->fade_out_step = 1 / (MUTE_FADE_OUT * b->rate);
    b->fade_in_step = 1 / (MUTE_FADE_IN * b->rate);
    b->amount = b->corner = b->treble = b->treble_corner = NAN;
    reset(b);
    return b;
}

static void connect_port(LADSPA_Handle handle, unsigned long port, LADSPA_Data *data) {
    struct bass *b = handle;
    if (port >= PORT_COUNT) return;
    b->port[port] = data;
    if (port == LATENCY && data) *data = (LADSPA_Data)b->lookahead;
}

static void activate(LADSPA_Handle handle) {
    reset(handle);
}

static float control(const struct bass *b, int port, float lo, float hi, float fallback) {
    float v = b->port[port] ? *b->port[port] : fallback;
    if (!(v >= lo)) return v == v ? lo : fallback;
    return v > hi ? hi : v;
}

static inline uint32_t wrap(uint32_t i, uint32_t size) {
    return i >= size ? i - size : i;
}

/* Delays `y` by the lookahead and applies a gain that keeps it under `ceiling`,
 * times the mute fade. */
static void limit(struct bass *b, const double y[2], double ceiling, LADSPA_Data *out_l, LADSPA_Data *out_r) {
    double peak = fmax(fabs(y[0]), fabs(y[1]));
    double need = peak > ceiling ? ceiling / peak : 1;
    uint32_t size = b->window + 1;
    while (b->queue_len && b->queue_gain[wrap(b->queue_head + b->queue_len - 1, size)] >= need) b->queue_len--;
    uint32_t tail = wrap(b->queue_head + b->queue_len, size);
    b->queue_gain[tail] = need;
    b->queue_time[tail] = b->now;
    b->queue_len++;
    while (b->now - b->queue_time[b->queue_head] >= b->window) {
        b->queue_head = wrap(b->queue_head + 1, size);
        b->queue_len--;
    }
    double target = b->queue_gain[b->queue_head];
    b->gain += (target < b->gain ? b->gain_attack : b->gain_release) * (target - b->gain);
    double gain = b->gain * b->fade * b->fade;
    LADSPA_Data *out[2] = { out_l, out_r };
    for (int ch = 0; ch < 2; ch++) {
        float *slot = &b->delay[(size_t)ch * b->lookahead + b->pos];
        double v = *slot * gain;
        *slot = (float)y[ch];
        /* Catches the attack's last 2% and maps NaN to silence. */
        if (!(fabs(v) <= ceiling)) v = v > 0 ? ceiling : v < 0 ? -ceiling : 0;
        *out[ch] = (LADSPA_Data)v;
    }
    b->pos = wrap(b->pos + 1, b->lookahead);
    b->now++;
}

/* Flushes decaying state before it turns denormal, and recovers from state
 * that went non-finite. */
static void sanitize(struct bass *b) {
    biquad_state *states[] = {
        &b->shelf_state[0], &b->shelf_state[1], &b->band_state[0],
        &b->band_state[1], &b->harmonic_state[0], &b->harmonic_state[1],
        &b->treble_state[0], &b->treble_state[1],
    };
    double *values[2 * sizeof(states) / sizeof(states[0]) + 2];
    size_t n = 0;
    for (size_t i = 0; i < sizeof(states) / sizeof(states[0]); i++) {
        values[n++] = &states[i]->z1;
        values[n++] = &states[i]->z2;
    }
    values[n++] = &b->peak;
    values[n++] = &b->level;
    bool finite = isfinite(b->gain) && isfinite(b->fade);
    for (size_t i = 0; i < n; i++) {
        finite = finite && isfinite(*values[i]);
        if (fabs(*values[i]) < 1e-25) *values[i] = 0;
    }
    if (!finite) reset(b);
}

static void run(LADSPA_Handle handle, unsigned long count) {
    struct bass *b = handle;
    if (b->port[LATENCY]) *b->port[LATENCY] = (LADSPA_Data)b->lookahead;
    const LADSPA_Data *in[2] = { b->port[IN_L], b->port[IN_R] };
    LADSPA_Data *out[2] = { b->port[OUT_L], b->port[OUT_R] };
    if (!in[0] || !in[1] || !out[0] || !out[1]) return;

    float amount = control(b, AMOUNT, 0, 12, 0), corner = control(b, CORNER, 40, 490, 140);
    if (amount != b->amount || corner != b->corner) {
        b->amount = amount;
        b->corner = corner;
        b->shelf = design(LOW_SHELF, b->rate, corner, amount);
        b->band = design(LOWPASS, b->rate, corner, 0);
        b->harmonic_hp = design(HIGHPASS, b->rate, 0.8 * corner, 0);
        b->harmonic_lp = design(LOWPASS, b->rate, 3.75 * corner, 0);
    }
    float treble = control(b, TREBLE, -6, 6, 0), treble_corner = control(b, TREBLE_CORNER, 2000, 18000, 6000);
    if (treble != b->treble || treble_corner != b->treble_corner) {
        b->treble = treble;
        b->treble_corner = treble_corner;
        /* Keeps the corner below Nyquist at low sample rates. */
        b->treble_shelf = design(HIGH_SHELF, b->rate, fmin(treble_corner, 0.4 * b->rate), treble);
        /* A flat shelf is skipped. Zero is the state a 0 dB shelf settles in,
         * so the shelf picks up cleanly when it comes back. */
        if (treble == 0) memset(b->treble_state, 0, sizeof(b->treble_state));
    }
    double boost = pow(10, amount / 20.0);
    double headroom = pow(10, control(b, HEADROOM, -12, 6, -3) / 20.0);
    double ceiling = pow(10, control(b, CEILING, -4, 0, -1) / 20.0);
    double harmonics = HARMONIC_LEVEL * control(b, HARMONICS, 0, 2, 1) * amount / 12.0;

    bool muted = control(b, MUTE, 0, 1, 0) >= 0.5f;
    if (!b->fade_primed) {
        b->fade = muted ? 0 : 1;
        b->fade_primed = true;
    }

    for (unsigned long i = 0; i < count; i++) {
        /* Read both inputs before writing: the host may process in place. */
        double x[2] = { in[0][i], in[1][i] }, y[2];
        for (int ch = 0; ch < 2; ch++)
            if (!isfinite(x[ch])) x[ch] = 0;

        b->fade = muted ? fmax(0, b->fade - b->fade_out_step) : fmin(1, b->fade + b->fade_in_step);

        /* Mono bass band, 4th-order Linkwitz-Riley below the corner. */
        double band = filter(&b->band, &b->band_state[1], filter(&b->band, &b->band_state[0], 0.5 * (x[0] + x[1])));
        double level = fabs(band);
        /* Instant attack keeps |band| <= peak, so band / peak stays in [-1, 1]. */
        b->peak = level > b->peak ? level : b->peak * b->peak_release;
        b->level += (level > b->level ? b->level_attack : b->level_release) * (level - b->level);

        /* The boosted band may reach `headroom`; backing off never cuts. */
        double allowed = b->level * boost > headroom ? headroom / b->level : boost;
        double share = boost > 1 ? (fmax(allowed, 1) - 1) / (boost - 1) : 0;

        /* Chebyshev T2 and T3 turn a unit sine into its 2nd and 3rd harmonics;
         * scaling by the peak keeps them proportional to the band. */
        double norm = b->peak > 1e-9 ? band / b->peak : 0, sq = norm * norm;
        double h = ((2 * sq - 1) + THIRD_HARMONIC * norm * (4 * sq - 3)) * b->peak;
        h = filter(&b->harmonic_lp, &b->harmonic_state[1], filter(&b->harmonic_hp, &b->harmonic_state[0], h));
        /* Small speakers depend on the harmonics, so they back off more gently. */
        h *= harmonics * sqrt(share);

        for (int ch = 0; ch < 2; ch++) {
            double shelved = filter(&b->shelf, &b->shelf_state[ch], x[ch]);
            y[ch] = x[ch] + share * (shelved - x[ch]) + h;
            if (treble != 0) y[ch] = filter(&b->treble_shelf, &b->treble_state[ch], y[ch]);
        }
        limit(b, y, ceiling, &out[0][i], &out[1][i]);
    }
    sanitize(b);
}

static const LADSPA_Descriptor descriptor = {
    .UniqueID = 5131,
    .Label = "rediwm_bass",
    .Properties = PROPERTY_HARD_RT_CAPABLE,
    .Name = "RediWM Bass Boost",
    .Maker = "RediWM",
    .Copyright = "None",
    .PortCount = PORT_COUNT,
    .PortDescriptors = port_descriptors,
    .PortNames = port_names,
    .PortRangeHints = port_hints,
    .instantiate = instantiate,
    .connect_port = connect_port,
    .activate = activate,
    .run = run,
    .cleanup = cleanup,
};

__attribute__((visibility("default"))) const LADSPA_Descriptor *ladspa_descriptor(unsigned long index);
const LADSPA_Descriptor *ladspa_descriptor(unsigned long index) {
    return index == 0 ? &descriptor : NULL;
}
