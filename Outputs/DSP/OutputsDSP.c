#include "OutputsDSP.h"

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Lock-free unsigned atomics required");
_Static_assert(sizeof(unsigned) == sizeof(float), "32-bit unsigned required");

typedef struct {
    double b0, b1, b2, a1, a2;
} ODCoefficients;

typedef struct {
    ODCoefficients band[OD_EQ_BANDS];
    int bypass;
} ODEQ;

typedef struct {
    double z1, z2;
} ODState;

typedef struct {
    int buffer, offset, channels;
} ODLayout;

typedef struct {
    atomic_uint gainBits, delay, eqMiddle, levelBits, running;
    ODEQ eq[3];
    unsigned eqBack, eqFront;
    ODState state[2][OD_EQ_BANDS], tapeState[2][OD_EQ_BANDS];
    float *ring;
    double *tapeRing;
    size_t write;
    unsigned oldDelay, newDelay, fadePosition;
    int fading;
    double gain, level;
    unsigned seenRunning, tapeRampPosition, returnPosition, enterPosition;
    int tapeTarget, tapeActive, tapeRamping, returning, entering;
    double tapeRate, tapeStartRate, tapeLag;
} ODOutput;

struct ODEngine {
    double sampleRate, gainPole, releasePole;
    unsigned maxFrames, maxDelay, fadeFrames, clickLength, clickPeriod;
    unsigned stopFrames, spinFrames, returnFrames, enterFrames;
    size_t ringFrames, tapeLagFrames;
    double stopCurve[1025];
    int sourceCount, outputCount, started;
    ODLayout sources[OD_MAX_SOURCES], outputs[OD_MAX_OUTPUTS];
    atomic_uint routes[OD_MAX_SOURCES][OD_MAX_OUTPUTS];
    atomic_uint sourceLevelBits[OD_MAX_SOURCES];
    atomic_uint sourceGainBits[OD_MAX_SOURCES];
    double sourceLevel[OD_MAX_SOURCES];
    double sourceGain[OD_MAX_SOURCES];
    ODOutput out[OD_MAX_OUTPUTS];
    atomic_uint clicks;
    unsigned seenClicks, clickPhase;
    float *clickBurst;
};

static const double od_pi = 3.14159265358979323846;

static unsigned od_bits(float value) {
    unsigned bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float od_float(unsigned bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static int od_valid_output(const ODEngine *e, int output) {
    return e && output >= 0 && output < OD_MAX_OUTPUTS;
}

static double od_clean(double x) {
    return isfinite(x) ? x : 0.0;
}

static double od_denormal(double x) {
    return fabs(x) < 1e-24 ? 0.0 : od_clean(x);
}

static double od_limit(double x) {
    const double knee = 0.8912509381337456;
    x = od_clean(x);
    double magnitude = fabs(x);
    if (magnitude <= knee) return x;
    double excess = magnitude - knee;
    double value = knee + (1.0 - knee) * (excess / (excess + 1.0 - knee));
    return copysign(fmin(value, 1.0), x);
}

static ODCoefficients od_coefficients(double sr, int band, double db) {
    static const double frequency[OD_EQ_BANDS] = {60.0, 250.0, 1000.0, 4000.0, 12000.0};
    ODCoefficients c = {1.0, 0.0, 0.0, 0.0, 0.0};
    if (db == 0.0) return c;
    double a = pow(10.0, db / 40.0);
    double w = 2.0 * od_pi * fmin(frequency[band], 0.45 * sr) / sr;
    double cosine = cos(w), sine = sin(w);
    double alpha = sine * 0.5;
    double a0;
    if (band == 0 || band == 4) {
        double beta = 2.0 * sqrt(a) * sine / sqrt(2.0);
        double plus = a + 1.0, minus = a - 1.0;
        if (band == 0) {
            c.b0 = a * (plus - minus * cosine + beta);
            c.b1 = 2.0 * a * (minus - plus * cosine);
            c.b2 = a * (plus - minus * cosine - beta);
            a0 = plus + minus * cosine + beta;
            c.a1 = -2.0 * (minus + plus * cosine);
            c.a2 = plus + minus * cosine - beta;
        } else {
            c.b0 = a * (plus + minus * cosine + beta);
            c.b1 = -2.0 * a * (minus + plus * cosine);
            c.b2 = a * (plus + minus * cosine - beta);
            a0 = plus - minus * cosine + beta;
            c.a1 = 2.0 * (minus - plus * cosine);
            c.a2 = plus - minus * cosine - beta;
        }
    } else {
        c.b0 = 1.0 + alpha * a;
        c.b1 = -2.0 * cosine;
        c.b2 = 1.0 - alpha * a;
        a0 = 1.0 + alpha / a;
        c.a1 = -2.0 * cosine;
        c.a2 = 1.0 - alpha / a;
    }
    c.b0 /= a0;
    c.b1 /= a0;
    c.b2 /= a0;
    c.a1 /= a0;
    c.a2 /= a0;
    return c;
}

ODEngine *od_create(double sampleRate, unsigned maxFrames) {
    if (!isfinite(sampleRate) || sampleRate < 1.0 ||
        sampleRate > (double)(UINT_MAX - 1u) * 1000.0 / OD_MAX_DELAY_MS || maxFrames == 0) return NULL;
    ODEngine *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    e->sampleRate = sampleRate;
    e->maxFrames = maxFrames;
    e->maxDelay = (unsigned)llround(sampleRate * OD_MAX_DELAY_MS / 1000.0);
    e->tapeLagFrames = (size_t)fmax(8.0, ceil(sampleRate));
    e->ringFrames = (size_t)e->maxDelay + e->tapeLagFrames + maxFrames + 4u;
    if (e->ringFrames > SIZE_MAX / (2u * sizeof(double))) {
        free(e);
        return NULL;
    }
    e->fadeFrames = (unsigned)fmax(2.0, round(0.020 * sampleRate));
    e->stopFrames = (unsigned)fmax(2.0, round(0.700 * sampleRate));
    e->spinFrames = (unsigned)fmax(2.0, round(0.350 * sampleRate));
    e->returnFrames = (unsigned)fmax(2.0, round(0.030 * sampleRate));
    e->enterFrames = (unsigned)fmax(2.0, round(0.005 * sampleRate));
    for (unsigned i = 0; i <= 1024u; ++i) e->stopCurve[i] = pow((double)i / 1024.0, 1.6);
    e->clickLength = (unsigned)fmax(2.0, round(0.004 * sampleRate));
    e->clickPeriod = (unsigned)fmax(1.0, round(sampleRate));
    e->gainPole = exp(-1.0 / (0.010 * sampleRate));
    e->releasePole = exp(-1.0 / (0.300 * sampleRate));
    atomic_init(&e->clicks, 0u);
    for (int s = 0; s < OD_MAX_SOURCES; ++s) {
        atomic_init(&e->sourceLevelBits[s], od_bits(0.0f));
        atomic_init(&e->sourceGainBits[s], od_bits(1.0f));
        e->sourceGain[s] = 1.0;
        for (int o = 0; o < OD_MAX_OUTPUTS; ++o) atomic_init(&e->routes[s][o], 0u);
    }
    for (int o = 0; o < OD_MAX_OUTPUTS; ++o) {
        ODOutput *v = &e->out[o];
        atomic_init(&v->gainBits, od_bits(1.0f));
        atomic_init(&v->delay, 0u);
        atomic_init(&v->levelBits, od_bits(0.0f));
        atomic_init(&v->running, 3u);
        v->seenRunning = 3u;
        v->tapeTarget = 1;
        v->tapeRate = 1.0;
        atomic_init(&v->eqMiddle, 1u);
        v->eqBack = 2u;
        v->gain = 1.0;
        for (int i = 0; i < 3; ++i) v->eq[i].bypass = 1;
        v->ring = calloc(e->ringFrames * 2u, sizeof(float));
        v->tapeRing = calloc(e->ringFrames * 2u, sizeof(double));
        if (!v->ring || !v->tapeRing) {
            od_destroy(e);
            return NULL;
        }
    }
    e->clickBurst = calloc(e->clickLength, sizeof(float));
    if (!e->clickBurst) {
        od_destroy(e);
        return NULL;
    }
    for (unsigned i = 0; i < e->clickLength; ++i) {
        double window = 0.5 - 0.5 * cos(2.0 * od_pi * i / (e->clickLength - 1u));
        e->clickBurst[i] = (float)(pow(10.0, -6.0 / 20.0) * window *
                                   sin(2.0 * od_pi * 2000.0 * i / sampleRate));
    }
    e->clickBurst[e->clickLength - 1u] = 0.0f;
    return e;
}

void od_destroy(ODEngine *e) {
    if (!e) return;
    for (int o = 0; o < OD_MAX_OUTPUTS; ++o) {
        free(e->out[o].ring);
        free(e->out[o].tapeRing);
    }
    free(e->clickBurst);
    free(e);
}

void od_set_source_layout(ODEngine *e, int count, const int *buffers, const int *offsets) {
    if (!e) return;
    e->sourceCount = buffers && offsets ? (count < 0 ? 0 : count > OD_MAX_SOURCES ? OD_MAX_SOURCES : count) : 0;
    for (int s = 0; s < e->sourceCount; ++s) e->sources[s] = (ODLayout){buffers[s], offsets[s], 2};
}

void od_set_output_layout(ODEngine *e, int count, const int *buffers,
                          const int *offsets, const int *channels) {
    if (!e) return;
    e->outputCount = buffers && offsets && channels ? (count < 0 ? 0 : count > OD_MAX_OUTPUTS ? OD_MAX_OUTPUTS : count) : 0;
    for (int o = 0; o < e->outputCount; ++o) e->outputs[o] = (ODLayout){buffers[o], offsets[o], channels[o]};
}

void od_set_source_gain(ODEngine *e, int source, float linear) {
    if (!e || source < 0 || source >= OD_MAX_SOURCES) return;
    float value = isfinite(linear) ? fmaxf(0.0f, fminf(linear, 2.0f)) : 1.0f;
    atomic_store_explicit(&e->sourceGainBits[source], od_bits(value), memory_order_relaxed);
}

void od_set_route(ODEngine *e, int source, int output, int enabled) {
    if (!od_valid_output(e, output) || source < 0 || source >= OD_MAX_SOURCES) return;
    atomic_store_explicit(&e->routes[source][output], enabled != 0, memory_order_relaxed);
}

void od_set_output_gain(ODEngine *e, int output, float linear) {
    if (!od_valid_output(e, output)) return;
    linear = isfinite(linear) ? fmaxf(0.0f, linear) : 0.0f;
    atomic_store_explicit(&e->out[output].gainBits, od_bits(linear), memory_order_relaxed);
}

void od_set_output_delay_ms(ODEngine *e, int output, float ms) {
    if (!od_valid_output(e, output)) return;
    double delay = isfinite(ms) ? fmax(0.0, fmin(ms, OD_MAX_DELAY_MS)) : 0.0;
    unsigned samples = (unsigned)llround(delay * e->sampleRate / 1000.0);
    atomic_store_explicit(&e->out[output].delay, samples, memory_order_relaxed);
}

void od_set_output_running(ODEngine *e, int output, int running) {
    if (!od_valid_output(e, output)) return;
    if (running) atomic_fetch_or_explicit(&e->out[output].running, 1u, memory_order_relaxed);
    else atomic_fetch_and_explicit(&e->out[output].running, ~1u, memory_order_relaxed);
}

void od_set_output_running_immediate(ODEngine *e, int output, int running) {
    if (!od_valid_output(e, output)) return;
    atomic_uint *command = &e->out[output].running;
    unsigned old = atomic_load_explicit(command, memory_order_relaxed);
    unsigned next;
    do {
        next = ((old & ~3u) + 4u) | (running ? 3u : 0u);
    } while (!atomic_compare_exchange_weak_explicit(command, &old, next,
                                                   memory_order_relaxed, memory_order_relaxed));
}

int od_output_running(ODEngine *e, int output) {
    return od_valid_output(e, output) ? (int)(atomic_load_explicit(&e->out[output].running, memory_order_relaxed) & 1u) : 0;
}

void od_set_output_eq(ODEngine *e, int output, const float gainsDb[OD_EQ_BANDS]) {
    if (!od_valid_output(e, output) || !gainsDb) return;
    ODOutput *v = &e->out[output];
    ODEQ *eq = &v->eq[v->eqBack];
    eq->bypass = 1;
    for (int b = 0; b < OD_EQ_BANDS; ++b) {
        double db = isfinite(gainsDb[b]) ? fmax(-12.0, fmin(12.0, gainsDb[b])) : 0.0;
        if (db != 0.0) eq->bypass = 0;
        eq->band[b] = od_coefficients(e->sampleRate, b, db);
    }
    v->eqBack = atomic_exchange_explicit(&v->eqMiddle, v->eqBack | 4u, memory_order_acq_rel) & 3u;
}

void od_set_test_clicks(ODEngine *e, int enabled) {
    if (!e) return;
    unsigned old = atomic_load_explicit(&e->clicks, memory_order_relaxed);
    unsigned next = enabled ? ((old & 1u) ? old : (old + 2u) | 1u) : old & ~1u;
    atomic_store_explicit(&e->clicks, next, memory_order_relaxed);
}

float od_output_level(ODEngine *e, int output) {
    return od_valid_output(e, output) ? od_float(atomic_load_explicit(&e->out[output].levelBits, memory_order_relaxed)) : 0.0f;
}

float od_source_level(ODEngine *e, int source) {
    return e && source >= 0 && source < OD_MAX_SOURCES ? od_float(atomic_load_explicit(&e->sourceLevelBits[source], memory_order_relaxed)) : 0.0f;
}

void od_reset(ODEngine *e) {
    if (!e) return;
    e->started = 0;
    e->clickPhase = 0;
    e->seenClicks = atomic_load_explicit(&e->clicks, memory_order_relaxed);
    for (int s = 0; s < OD_MAX_SOURCES; ++s) {
        e->sourceLevel[s] = 0.0;
        atomic_store_explicit(&e->sourceLevelBits[s], od_bits(0.0f), memory_order_relaxed);
    }
    for (int o = 0; o < OD_MAX_OUTPUTS; ++o) {
        ODOutput *v = &e->out[o];
        memset(v->ring, 0, e->ringFrames * 2u * sizeof(float));
        memset(v->tapeRing, 0, e->ringFrames * 2u * sizeof(double));
        memset(v->state, 0, sizeof(v->state));
        memset(v->tapeState, 0, sizeof(v->tapeState));
        v->write = 0;
        v->fading = 0;
        v->fadePosition = 0;
        v->level = 0.0;
        v->seenRunning = atomic_load_explicit(&v->running, memory_order_relaxed);
        v->tapeTarget = (int)(v->seenRunning & 1u);
        v->tapeRate = v->tapeTarget ? 1.0 : 0.0;
        v->tapeStartRate = v->tapeRate;
        v->tapeActive = !v->tapeTarget;
        v->tapeRamping = 0;
        v->returning = v->entering = 0;
        v->tapeRampPosition = v->returnPosition = v->enterPosition = 0;
        v->tapeLag = 0.0;
        atomic_store_explicit(&v->levelBits, od_bits(0.0f), memory_order_relaxed);
    }
}

static void od_read(const AudioBufferList *input, ODLayout layout, size_t frame, double value[2]) {
    value[0] = value[1] = 0.0;
    if (!input || layout.buffer < 0 || layout.offset < 0 || (unsigned)layout.buffer >= input->mNumberBuffers) return;
    const AudioBuffer *buffer = &input->mBuffers[layout.buffer];
    size_t stride = buffer->mNumberChannels;
    if (!buffer->mData || (size_t)layout.offset >= stride ||
        frame >= buffer->mDataByteSize / sizeof(float) / stride) return;
    const float *data = buffer->mData;
    size_t index = frame * stride + (unsigned)layout.offset;
    value[0] = od_clean(data[index]);
    value[1] = (size_t)layout.offset + 1u < stride ? od_clean(data[index + 1u]) : value[0];
}

static void od_zero(AudioBufferList *output, size_t frame) {
    if (!output) return;
    for (unsigned b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer *buffer = &output->mBuffers[b];
        size_t stride = buffer->mNumberChannels;
        if (!buffer->mData || stride == 0 || frame >= buffer->mDataByteSize / sizeof(float) / stride) continue;
        float *data = buffer->mData;
        for (size_t c = 0; c < stride; ++c) data[frame * stride + c] = 0.0f;
    }
}

static void od_write(AudioBufferList *output, ODLayout layout, size_t frame, const double value[2]) {
    if (!output || layout.buffer < 0 || layout.offset < 0 || layout.channels <= 0 ||
        (unsigned)layout.buffer >= output->mNumberBuffers) return;
    AudioBuffer *buffer = &output->mBuffers[layout.buffer];
    size_t stride = buffer->mNumberChannels;
    if (!buffer->mData || (size_t)layout.offset >= stride ||
        frame >= buffer->mDataByteSize / sizeof(float) / stride) return;
    float *data = buffer->mData;
    size_t index = frame * stride + (unsigned)layout.offset;
    data[index] = layout.channels == 1 ? (float)((value[0] + value[1]) * 0.5) : (float)value[0];
    if (layout.channels >= 2 && (size_t)layout.offset + 1u < stride) data[index + 1u] = (float)value[1];
}

static double od_filter(ODState states[2][OD_EQ_BANDS], const ODEQ *eq, int channel, double x) {
    if (eq->bypass) return x;
    for (int b = 0; b < OD_EQ_BANDS; ++b) {
        const ODCoefficients *c = &eq->band[b];
        ODState *s = &states[channel][b];
        double y = od_clean(c->b0 * x + s->z1);
        s->z1 = od_denormal(c->b1 * x - c->a1 * y + s->z2);
        s->z2 = od_denormal(c->b2 * x - c->a2 * y);
        x = y;
    }
    return x;
}

static void od_running_command(ODOutput *v, unsigned command) {
    if ((command & ~3u) != (v->seenRunning & ~3u)) {
        v->tapeTarget = (int)((command >> 1u) & 1u);
        v->tapeRate = v->tapeTarget ? 1.0 : 0.0;
        v->tapeActive = !v->tapeTarget;
        v->tapeRamping = v->returning = v->entering = 0;
        if (v->tapeTarget) v->tapeLag = 0.0;
        else {
            memset(v->tapeState, 0, sizeof(v->tapeState));
            v->level = 0.0;
        }
    }
    int target = (int)(command & 1u);
    if (target != v->tapeTarget) {
        if (!v->tapeActive) {
            memcpy(v->tapeState, v->state, sizeof(v->tapeState));
            v->entering = 1;
            v->enterPosition = 0;
        }
        v->tapeTarget = target;
        v->tapeStartRate = v->tapeRate;
        v->tapeRampPosition = 0;
        v->tapeRamping = v->tapeActive = 1;
    }
    v->seenRunning = command;
}

static double od_stop_curve(const ODEngine *e, double x) {
    double position = fmax(0.0, fmin(1.0, x)) * 1024.0;
    unsigned index = (unsigned)position;
    if (index >= 1024u) return 1.0;
    double fraction = position - index;
    return e->stopCurve[index] + (e->stopCurve[index + 1u] - e->stopCurve[index]) * fraction;
}

static double od_tape_step(const ODEngine *e, ODOutput *v) {
    if (v->tapeRamping) {
        unsigned duration = v->tapeTarget ? e->spinFrames : e->stopFrames;
        double t = (double)v->tapeRampPosition / (duration - 1u);
        double remaining = 1.0 - t;
        v->tapeRate = v->tapeTarget ? 1.0 - (1.0 - v->tapeStartRate) * remaining * remaining :
                                    v->tapeStartRate * od_stop_curve(e, remaining);
        if (++v->tapeRampPosition >= duration) {
            v->tapeRate = v->tapeTarget ? 1.0 : 0.0;
            v->tapeRamping = 0;
            if (!v->tapeTarget) {
                memset(v->tapeState, 0, sizeof(v->tapeState));
                v->level = 0.0;
                v->returning = 0;
            }
        }
    }
    int stopped = !v->tapeRamping && v->tapeRate == 0.0 && !v->tapeTarget;
    double threshold = (double)e->tapeLagFrames - e->returnFrames - 4.0;
    if (v->tapeActive && !stopped && !v->returning &&
        ((!v->tapeRamping && v->tapeTarget) || v->tapeLag >= threshold)) {
        v->returning = 1;
        v->returnPosition = 0;
    }
    double fade = fmin(1.0, v->tapeRate / od_stop_curve(e, 0.25));
    return fade * fade * (3.0 - 2.0 * fade);
}

static double od_tape_read(const ODEngine *e, const ODOutput *v, unsigned delay, int channel) {
    double age = delay + v->tapeLag;
    size_t whole = (size_t)age;
    double fraction = age - (double)whole;
    size_t index = (v->write + e->ringFrames - whole) % e->ringFrames;
    double p1 = v->tapeRing[index * 2u + (unsigned)channel];
    if (fraction == 0.0) return p1;
    size_t older = (index + e->ringFrames - 1u) % e->ringFrames;
    double p2 = v->tapeRing[older * 2u + (unsigned)channel];
    double p3 = v->tapeRing[((older + e->ringFrames - 1u) % e->ringFrames) * 2u + (unsigned)channel];
    double p0 = whole > 0 ? v->tapeRing[((index + 1u) % e->ringFrames) * 2u + (unsigned)channel] : 2.0 * p1 - p2;
    double a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
    double b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
    double c = 0.5 * (p2 - p0);
    return ((a * fraction + b) * fraction + c) * fraction + p1;
}

static void od_tape_advance(const ODEngine *e, ODOutput *v) {
    if (!v->tapeActive) return;
    if (v->entering && ++v->enterPosition >= e->enterFrames) v->entering = 0;
    if (v->returning && ++v->returnPosition >= e->returnFrames) {
        v->tapeLag = 0.0;
        v->returning = 0;
        if (!v->tapeRamping && v->tapeTarget) v->tapeActive = 0;
        else {
            v->entering = 1;
            v->enterPosition = 0;
        }
    }
    v->tapeLag += 1.0 - v->tapeRate;
    if (!v->tapeRamping && !v->tapeTarget) {
        double retained = fmax(0.0, (double)e->tapeLagFrames - e->spinFrames - e->returnFrames - 4.0);
        v->tapeLag = fmin(v->tapeLag, retained);
    }
}

void od_process(ODEngine *e, const AudioBufferList *input, AudioBufferList *output, unsigned frames) {
    if (!e) {
        for (size_t f = 0; f < frames; ++f) od_zero(output, f);
        return;
    }
    if (frames == 0) return;
    unsigned routes[OD_MAX_SOURCES][OD_MAX_OUTPUTS];
    unsigned delays[OD_MAX_OUTPUTS];
    double gains[OD_MAX_OUTPUTS];
    unsigned clicks = atomic_load_explicit(&e->clicks, memory_order_relaxed);
    if ((clicks & 1u) && clicks != e->seenClicks) e->clickPhase = 0;
    e->seenClicks = clicks;
    for (int s = 0; s < OD_MAX_SOURCES; ++s)
        for (int o = 0; o < OD_MAX_OUTPUTS; ++o)
            routes[s][o] = atomic_load_explicit(&e->routes[s][o], memory_order_relaxed);
    for (int o = 0; o < OD_MAX_OUTPUTS; ++o) {
        ODOutput *v = &e->out[o];
        gains[o] = od_float(atomic_load_explicit(&v->gainBits, memory_order_relaxed));
        delays[o] = atomic_load_explicit(&v->delay, memory_order_relaxed);
        od_running_command(v, atomic_load_explicit(&v->running, memory_order_relaxed));
        if (atomic_load_explicit(&v->eqMiddle, memory_order_acquire) & 4u) {
            v->eqFront = atomic_exchange_explicit(&v->eqMiddle, v->eqFront, memory_order_acq_rel) & 3u;
            if (v->eq[v->eqFront].bypass) {
                memset(v->state, 0, sizeof(v->state));
                memset(v->tapeState, 0, sizeof(v->tapeState));
            }
        }
        if (!e->started) {
            v->gain = gains[o];
            v->oldDelay = v->newDelay = delays[o];
        }
    }
    e->started = 1;
    double sourceTargets[OD_MAX_SOURCES];
    for (int s = 0; s < OD_MAX_SOURCES; ++s) {
        sourceTargets[s] = od_float(atomic_load_explicit(&e->sourceGainBits[s], memory_order_relaxed));
    }
    size_t base = 0;
    while (base < frames) {
        size_t remaining = frames - base;
        unsigned chunk = remaining < e->maxFrames ? (unsigned)remaining : e->maxFrames;
        for (unsigned n = 0; n < chunk; ++n) {
            size_t frame = base + n;
            double sources[OD_MAX_SOURCES][2] = {{0.0}};
            double click = (clicks & 1u) && e->clickPhase < e->clickLength ? e->clickBurst[e->clickPhase] : 0.0;
            for (int s = 0; s < OD_MAX_SOURCES; ++s) {
                if (s < e->sourceCount) {
                    if (clicks & 1u) sources[s][0] = sources[s][1] = click;
                    else od_read(input, e->sources[s], frame, sources[s]);
                    if (e->sourceGain[s] != sourceTargets[s]) {
                        e->sourceGain[s] = sourceTargets[s] + (e->sourceGain[s] - sourceTargets[s]) * e->gainPole;
                        if (fabs(e->sourceGain[s] - sourceTargets[s]) < 1e-9) e->sourceGain[s] = sourceTargets[s];
                    }
                    if (e->sourceGain[s] != 1.0) {
                        sources[s][0] *= e->sourceGain[s];
                        sources[s][1] *= e->sourceGain[s];
                    }
                }
                double peak = fmin(1.0, fmax(fabs(sources[s][0]), fabs(sources[s][1])));
                e->sourceLevel[s] = fmax(peak, od_denormal(e->sourceLevel[s] * e->releasePole));
            }
            od_zero(output, frame);
            for (int o = 0; o < OD_MAX_OUTPUTS; ++o) {
                ODOutput *v = &e->out[o];
                if (o >= e->outputCount) {
                    v->level = od_denormal(v->level * e->releasePole);
                    continue;
                }
                double signal[2] = {0.0, 0.0};
                if (clicks & 1u) signal[0] = signal[1] = click;
                else {
                    int first = 1;
                    for (int s = 0; s < e->sourceCount; ++s) {
                        if (!routes[s][o]) continue;
                        if (first) {
                            signal[0] = sources[s][0];
                            signal[1] = sources[s][1];
                            first = 0;
                        } else {
                            signal[0] += sources[s][0];
                            signal[1] += sources[s][1];
                        }
                    }
                }
                v->gain = gains[o] + (v->gain - gains[o]) * e->gainPole;
                if (fabs(v->gain - gains[o]) < 1e-12) v->gain = gains[o];
                if (!v->fading && delays[o] != v->newDelay) {
                    v->oldDelay = v->newDelay;
                    v->newDelay = delays[o];
                    v->fadePosition = 0;
                    v->fading = 1;
                }
                size_t oldRead = (v->write + e->ringFrames - v->oldDelay) % e->ringFrames;
                size_t newRead = (v->write + e->ringFrames - v->newDelay) % e->ringFrames;
                double mix = v->fading ? (double)v->fadePosition / (e->fadeFrames - 1u) : 1.0;
                double envelope = v->tapeActive ? od_tape_step(e, v) : 1.0;
                double returnMix = v->returning ? (double)v->returnPosition / (e->returnFrames - 1u) : 0.0;
                double enterMix = v->entering ? (double)v->enterPosition / (e->enterFrames - 1u) : 1.0;
                for (int c = 0; c < 2; ++c) {
                    v->tapeRing[v->write * 2u + (unsigned)c] = signal[c];
                    double filtered = od_filter(v->state, &v->eq[v->eqFront], c, signal[c] * v->gain);
                    v->ring[v->write * 2u + (unsigned)c] = (float)od_limit(filtered);
                    double a = v->ring[oldRead * 2u + (unsigned)c];
                    double b = v->ring[newRead * 2u + (unsigned)c];
                    signal[c] = v->fading ? a + (b - a) * mix : b;
                    if (v->tapeActive) {
                        double oldTape = od_tape_read(e, v, v->oldDelay, c);
                        double newTape = od_tape_read(e, v, v->newDelay, c);
                        double tape = v->fading ? oldTape + (newTape - oldTape) * mix : newTape;
                        double processed = 0.0;
                        if (v->tapeRamping || v->tapeTarget)
                            processed = (float)od_limit(od_filter(v->tapeState, &v->eq[v->eqFront], c, tape * envelope * v->gain));
                        double effect = v->returning ? processed + (signal[c] * envelope - processed) * returnMix : processed;
                        double entrance = signal[c] * envelope;
                        signal[c] = v->entering ? entrance + (effect - entrance) * enterMix : effect;
                        if (!v->tapeRamping && !v->tapeTarget) signal[c] = 0.0;
                    }
                }
                if (v->fading && ++v->fadePosition >= e->fadeFrames) {
                    v->fading = 0;
                    v->oldDelay = v->newDelay;
                }
                od_tape_advance(e, v);
                v->write = (v->write + 1u) % e->ringFrames;
                double peak = e->outputs[o].channels == 1 ? fabs((signal[0] + signal[1]) * 0.5) :
                              fmax(fabs(signal[0]), fabs(signal[1]));
                v->level = v->tapeActive && !v->tapeRamping && !v->tapeTarget ? 0.0 :
                           fmax(peak, od_denormal(v->level * e->releasePole));
                od_write(output, e->outputs[o], frame, signal);
            }
            if (clicks & 1u) {
                if (++e->clickPhase >= e->clickPeriod) e->clickPhase = 0;
            }
        }
        base += chunk;
    }
    for (int s = 0; s < OD_MAX_SOURCES; ++s)
        atomic_store_explicit(&e->sourceLevelBits[s], od_bits((float)e->sourceLevel[s]), memory_order_relaxed);
    for (int o = 0; o < OD_MAX_OUTPUTS; ++o)
        atomic_store_explicit(&e->out[o].levelBits, od_bits((float)e->out[o].level), memory_order_relaxed);
}
