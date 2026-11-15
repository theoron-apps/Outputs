#include "../Outputs/DSP/OutputsDSP.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const double pi = 3.14159265358979323846;
static atomic_uint checks;

static void check(int condition, const char *name) {
    ++checks;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}

static AudioBufferList *list_create(unsigned buffers) {
    AudioBufferList *list = calloc(1, offsetof(AudioBufferList, mBuffers) + buffers * sizeof(AudioBuffer));
    check(list != NULL, "allocate buffer list");
    list->mNumberBuffers = buffers;
    return list;
}

static float *buffer_create(AudioBufferList *list, unsigned buffer, unsigned channels, unsigned frames) {
    float *data = calloc((size_t)channels * frames + 8u, sizeof(float));
    check(data != NULL, "allocate audio buffer");
    list->mBuffers[buffer] = (AudioBuffer){channels, channels * frames * (unsigned)sizeof(float), data};
    return data;
}

static void list_destroy(AudioBufferList *list) {
    for (unsigned b = 0; b < list->mNumberBuffers; ++b) free(list->mBuffers[b].mData);
    free(list);
}

static ODEngine *engine_create(double rate, unsigned maxFrames) {
    ODEngine *e = od_create(rate, maxFrames);
    check(e != NULL, "create engine");
    int buffer = 0, offset = 0, channels = 2;
    od_set_source_layout(e, 1, &buffer, &offset);
    od_set_output_layout(e, 1, &buffer, &offset, &channels);
    od_set_route(e, 0, 0, 1);
    return e;
}

static void test_delays(void) {
    const unsigned frames = 2u * (48u * (OD_MAX_DELAY_MS + 1000u) + 131u) + 1u;
    const float delays[] = {0.0f, 1.0f, 180.0f, 999.0f, 1000.0f, 2500.0f, 3000.0f};
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, frames);
    float *out = buffer_create(output, 0, 2, frames);
    ODEngine *e = engine_create(48000.0, 127);
    in[0] = 0.5f;
    in[1] = -0.25f;
    for (unsigned d = 0; d < sizeof(delays) / sizeof(delays[0]); ++d) {
        od_set_output_delay_ms(e, 0, delays[d]);
        od_reset(e);
        unsigned sample = (unsigned)llround(delays[d] * 48.0);
        od_process(e, input, output, frames);
        int accurate = 1;
        for (unsigned f = 0; f < frames; ++f) {
            if (out[2u * f] != (f == sample ? 0.5f : 0.0f) ||
                out[2u * f + 1u] != (f == sample ? -0.25f : 0.0f)) accurate = 0;
        }
        check(accurate, "exact stereo impulse delay and ring wrap, oversized callback");
    }
    od_reset(e);
    od_process(e, NULL, output, frames);
    int clear = 1;
    for (unsigned f = 0; f < frames * 2u; ++f) if (out[f] != 0.0f) clear = 0;
    check(clear, "reset clears entire delay history");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS delay accuracy, reset, ring wrap, frames > maxFrames");
}

static void test_layouts_and_routing(void) {
    const unsigned frames = 131;
    AudioBufferList *input = list_create(1), *output = list_create(3);
    float *in = buffer_create(input, 0, 5, frames);
    float *out0 = buffer_create(output, 0, 8, frames);
    float *out1 = buffer_create(output, 1, 8, frames);
    output->mBuffers[2] = (AudioBuffer){2, frames * 2u * (unsigned)sizeof(float), NULL};
    ODEngine *e = od_create(48000.0, 32);
    check(e != NULL, "create routing engine");
    int sources[] = {0, 0, 4}, sourceOffsets[] = {1, 4, 0};
    int outputs[] = {0, 0, 1, 1, 2, 7};
    int offsets[] = {1, 4, 1, 6, 0, 0};
    int channels[] = {2, 1, 4, 2, 2, 2};
    od_set_source_layout(e, 3, sources, sourceOffsets);
    od_set_output_layout(e, 6, outputs, offsets, channels);
    od_set_route(e, 0, 0, 1);
    od_set_route(e, 0, 2, 1);
    od_set_route(e, 1, 1, 1);
    od_set_route(e, 1, 2, 1);
    od_set_route(e, 2, 3, 1);
    for (unsigned f = 0; f < frames; ++f) {
        in[f * 5u + 1u] = 0.2f;
        in[f * 5u + 2u] = 0.4f;
        in[f * 5u + 4u] = 0.1f;
    }
    for (unsigned i = 0; i < frames * 8u; ++i) out0[i] = out1[i] = 7.0f;
    out0[frames * 8u] = out1[frames * 8u] = 123.0f;
    od_process(e, input, output, frames);
    int correct = 1;
    for (unsigned f = 0; f < frames; ++f) {
        for (unsigned c = 0; c < 8; ++c) {
            float expected0 = c == 1 ? 0.2f : c == 2 ? 0.4f : c == 4 ? 0.1f : 0.0f;
            float expected1 = c == 1 ? 0.3f : c == 2 ? 0.5f : 0.0f;
            if (fabsf(out0[f * 8u + c] - expected0) > 1e-7f ||
                fabsf(out1[f * 8u + c] - expected1) > 1e-7f) correct = 0;
        }
    }
    check(correct, "routing, offsets, mono source, absent buffers, uncovered and extra channels zero");
    check(out0[frames * 8u] == 123.0f && out1[frames * 8u] == 123.0f, "output byte bounds");
    check(fabsf(od_source_level(e, 0) - 0.4f) < 1e-6f, "source stereo peak meter");
    check(fabsf(od_output_level(e, 2) - 0.5f) < 1e-6f, "output stereo peak meter");
    od_set_route(e, 0, 0, 0);
    od_process(e, input, output, frames);
    check(out0[1] == 0.0f && out0[2] == 0.0f, "live route disable");
    od_reset(e);
    od_process(e, NULL, output, frames);
    check(out1[1] == 0.0f && out1[2] == 0.0f, "null input silence");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS routing, layouts, mono sources, absent and null buffers, meters");
}

static void test_gain_and_mono(void) {
    const unsigned frames = 48000;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, frames);
    float *out = buffer_create(output, 0, 3, frames);
    ODEngine *e = engine_create(48000.0, 63);
    int buffer = 0, offset = 1, channels = 1;
    od_set_output_layout(e, 1, &buffer, &offset, &channels);
    for (unsigned f = 0; f < frames; ++f) {
        in[2u * f] = 0.2f;
        in[2u * f + 1u] = 0.6f;
    }
    od_set_output_gain(e, 0, 0.5f);
    od_process(e, input, output, frames);
    check(fabsf(out[1] - 0.2f) < 1e-7f && out[0] == 0.0f && out[2] == 0.0f,
          "initial gain and stereo to mono average");
    od_set_output_gain(e, 0, 1.0f);
    od_process(e, input, output, frames);
    check(out[1] > 0.2f && out[1] < 0.201f, "gain change begins smoothly");
    check(fabsf(out[480u * 3u + 1u] - (0.4f - 0.2f / expf(1.0f))) < 0.001f,
          "gain smoothing 10 ms time constant");
    check(fabsf(out[(frames - 1u) * 3u + 1u] - 0.4f) < 1e-6f, "gain converges");
    od_set_output_gain(e, 0, 0.0f);
    od_process(e, input, output, frames);
    check(fabsf(out[(frames - 1u) * 3u + 1u]) < 1e-9f, "gain mute");
    for (unsigned f = 0; f < frames; ++f) {
        in[2u * f] = 0.5f;
        in[2u * f + 1u] = -0.5f;
    }
    od_set_output_gain(e, 0, 1.0f);
    od_reset(e);
    od_process(e, input, output, frames);
    check(out[1] == 0.0f && od_output_level(e, 0) == 0.0f, "mono meter measures downmixed signal");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS gain, smoothing and mono downmix");
}

static double sine_response(ODEngine *e, AudioBufferList *input, AudioBufferList *output, double frequency) {
    unsigned frames = input->mBuffers[0].mDataByteSize / (2u * (unsigned)sizeof(float));
    float *in = input->mBuffers[0].mData, *out = output->mBuffers[0].mData;
    od_reset(e);
    for (unsigned f = 0; f < frames; ++f) {
        float value = (float)(0.02 * sin(2.0 * pi * frequency * f / 48000.0));
        in[2u * f] = in[2u * f + 1u] = value;
    }
    od_process(e, input, output, frames);
    double inputEnergy = 0.0, outputEnergy = 0.0;
    for (unsigned f = frames / 2u; f < frames; ++f) {
        inputEnergy += (double)in[2u * f] * in[2u * f];
        outputEnergy += (double)out[2u * f] * out[2u * f];
    }
    return sqrt(outputEnergy / inputEnergy);
}

static void test_eq(void) {
    const unsigned frames = 96000;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, frames);
    float *out = buffer_create(output, 0, 2, frames);
    ODEngine *e = engine_create(48000.0, 256);
    float gains[OD_EQ_BANDS] = {0};
    od_set_output_eq(e, 0, gains);
    for (unsigned f = 0; f < frames * 2u; ++f) in[f] = (float)((int)(f % 301u) - 150) / 200.0f;
    in[1] = -0.0f;
    in[2] = FLT_TRUE_MIN;
    in[3] = -FLT_TRUE_MIN;
    od_process(e, input, output, frames);
    check(memcmp(in, out, frames * 2u * sizeof(float)) == 0, "zero EQ is bit-identical passthrough");
    gains[0] = 12.0f;
    od_set_output_eq(e, 0, gains);
    double corner = sine_response(e, input, output, 60.0);
    double low = sine_response(e, input, output, 10.0);
    double high = sine_response(e, input, output, 1000.0);
    check(fabs(corner - pow(10.0, 6.0 / 20.0)) < 0.02, "60 Hz RBJ shelf corner is +6 dB for +12 dB shelf");
    check(low > 3.9 && low < 4.05, "+12 dB low shelf approaches 4x below corner");
    check(fabs(high - 1.0) < 0.01, "60 Hz shelf leaves 1 kHz unchanged");
    printf("PASS EQ bypass and shelf: 10 Hz %.4fx, 60 Hz %.4fx, 1 kHz %.4fx\n", low, corner, high);
    const double centers[] = {60.0, 250.0, 1000.0, 4000.0, 12000.0};
    for (int b = 1; b < OD_EQ_BANDS; ++b) {
        memset(gains, 0, sizeof(gains));
        gains[b] = 12.0f;
        od_set_output_eq(e, 0, gains);
        double response = sine_response(e, input, output, centers[b]);
        double expected = b == 4 ? pow(10.0, 6.0 / 20.0) : pow(10.0, 12.0 / 20.0);
        check(fabs(response - expected) < 0.03, "RBJ peaking and high shelf responses");
        gains[b] = -12.0f;
        od_set_output_eq(e, 0, gains);
        response = sine_response(e, input, output, centers[b]);
        check(fabs(response - 1.0 / expected) < 0.02, "RBJ peaking and high shelf cuts");
    }
    memset(gains, 0, sizeof(gains));
    gains[2] = 100.0f;
    od_set_output_eq(e, 0, gains);
    check(fabs(sine_response(e, input, output, 1000.0) - pow(10.0, 12.0 / 20.0)) < 0.03,
          "EQ gain clamped at +12 dB");
    memset(gains, 0, sizeof(gains));
    od_set_output_eq(e, 0, gains);
    od_process(e, input, output, frames);
    check(memcmp(in, out, frames * 2u * sizeof(float)) == 0, "live EQ bypass clears filter tails");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
}

static void test_clicks(void) {
    const unsigned frames = 144192;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, frames);
    float *out = buffer_create(output, 0, 4, frames);
    ODEngine *e = engine_create(48000.0, 47);
    int buffers[] = {0, 0}, offsets[] = {0, 2}, channels[] = {2, 2};
    od_set_output_layout(e, 2, buffers, offsets, channels);
    od_set_output_delay_ms(e, 1, 1.0f);
    for (unsigned f = 0; f < frames * 2u; ++f) in[f] = 0.7f;
    od_set_test_clicks(e, 1);
    od_process(e, input, output, frames);
    int correct = 1;
    double peak = 0.0;
    for (unsigned f = 0; f < frames; ++f) {
        unsigned phase = f % 48000u;
        float expected = 0.0f;
        if (phase > 0 && phase < 191u) expected = (float)(pow(10.0, -6.0 / 20.0) *
            (0.5 - 0.5 * cos(2.0 * pi * phase / 191.0)) * sin(2.0 * pi * 2000.0 * phase / 48000.0));
        if (out[f * 4u] != expected || out[f * 4u + 1u] != expected) correct = 0;
        float delayed = f >= 48u ? out[(f - 48u) * 4u] : 0.0f;
        if (out[f * 4u + 2u] != delayed || out[f * 4u + 3u] != delayed) correct = 0;
        if (fabs(expected) > peak) peak = fabs(expected);
    }
    check(correct, "click is identical across outputs before delay, period 48000, length 192");
    check(peak > 0.49 && peak <= pow(10.0, -6.0 / 20.0), "windowed click -6 dBFS peak");
    od_set_test_clicks(e, 0);
    od_process(e, input, output, 31);
    od_set_test_clicks(e, 1);
    od_process(e, input, output, 192);
    check(out[0] == 0.0f && out[4] != 0.0f, "click phase restarts on enable");
    od_set_test_clicks(e, 1);
    od_process(e, input, output, 192);
    check(out[4] == 0.0f, "repeated enable does not restart phase");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS click period, waveform, duration, replacement, per-output delay and restart");
}

static void test_delay_crossfade(void) {
    const unsigned block = 127, total = 144000;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, block);
    float *out = buffer_create(output, 0, 2, block);
    ODEngine *e = engine_create(48000.0, 31);
    double previous = 0.0, largest = 0.0;
    for (unsigned base = 0; base < total; base += block) {
        unsigned frames = total - base < block ? total - base : block;
        for (unsigned f = 0; f < frames; ++f) {
            in[f * 2u] = in[f * 2u + 1u] = (float)(0.7 * sin(2.0 * pi * 440.0 * (base + f) / 48000.0));
        }
        if (base == 12700u) od_set_output_delay_ms(e, 0, 180.0f);
        if (base >= 50800u && base < 55880u) od_set_output_delay_ms(e, 0, (float)((base / block) % 19u));
        if (base == 76200u) od_set_output_delay_ms(e, 0, 999.0f);
        od_process(e, input, output, frames);
        for (unsigned f = 0; f < frames; ++f) {
            double jump = fabs(out[f * 2u] - previous);
            if (jump > largest) largest = jump;
            previous = out[f * 2u];
        }
    }
    check(largest < 0.045, "delay crossfade has no discontinuity on 440 Hz sine");
    printf("PASS live delay crossfade, maximum sample step %.6f\n", largest);
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
}

static void test_limiter_and_invalid_audio(void) {
    const unsigned frames = 48000;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 8, frames);
    float *out = buffer_create(output, 0, 2, frames);
    ODEngine *e = engine_create(48000.0, 97);
    int buffers[] = {0, 0, 0, 0}, offsets[] = {0, 2, 4, 6};
    od_set_source_layout(e, 4, buffers, offsets);
    for (int s = 0; s < 4; ++s) od_set_route(e, s, 0, 1);
    for (unsigned f = 0; f < frames; ++f)
        for (unsigned c = 0; c < 8; ++c) in[f * 8u + c] = (f & 1u) ? -1.0f : 1.0f;
    od_process(e, input, output, frames);
    int bounded = 1;
    for (unsigned i = 0; i < frames * 2u; ++i)
        if (!isfinite(out[i]) || fabsf(out[i]) > 1.0f || fabsf(out[i]) < 0.9f) bounded = 0;
    check(bounded, "four full-scale sources limited to [-1,1]");
    check(od_source_level(e, 0) == 1.0f && od_output_level(e, 0) <= 1.0f, "meters bounded");
    for (unsigned i = 0; i < frames * 8u; ++i) in[i] = 0.0f;
    od_process(e, input, output, 14400);
    check(fabsf(od_source_level(e, 0) - expf(-1.0f)) < 0.001f, "300 ms meter release");
    const float invalid[] = {NAN, INFINITY, -INFINITY, FLT_MAX, -FLT_MAX, 1e-40f};
    for (unsigned i = 0; i < frames * 8u; ++i) in[i] = invalid[i % 6u];
    float eq[OD_EQ_BANDS] = {12, 12, 12, 12, 12};
    od_set_output_eq(e, 0, eq);
    od_set_output_gain(e, 0, FLT_MAX);
    od_process(e, input, output, frames);
    bounded = 1;
    for (unsigned i = 0; i < frames * 2u; ++i)
        if (!isfinite(out[i]) || fabsf(out[i]) > 1.0f) bounded = 0;
    check(bounded, "nonfinite input and extreme finite gain produce bounded finite output");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS soft limiter, finite output, extreme input and meter release");
}

static void test_short_buffers_and_validation(void) {
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, 3);
    float *out = buffer_create(output, 0, 2, 5);
    ODEngine *e = engine_create(8000.0, 2);
    for (unsigned i = 0; i < 6; ++i) in[i] = 0.25f;
    for (unsigned i = 0; i < 18; ++i) out[i] = 9.0f;
    od_process(e, input, output, 40);
    check(out[0] == 0.25f && out[5] == 0.25f && out[6] == 0.0f && out[9] == 0.0f && out[10] == 9.0f,
          "short input and output buffers respect mDataByteSize");
    int invalid = -1, offset = -2, channels = -3;
    od_set_source_layout(e, 1, &invalid, &offset);
    od_set_output_layout(e, 1, &invalid, &offset, &channels);
    od_process(e, input, output, 40);
    check(out[0] == 0.0f, "invalid layout is silent");
    od_set_source_layout(e, 100, NULL, NULL);
    od_set_output_layout(e, 100, NULL, NULL, NULL);
    od_set_route(e, -1, 0, 1);
    od_set_route(e, 0, 100, 1);
    od_set_output_eq(e, 100, NULL);
    od_set_output_gain(e, -1, NAN);
    od_set_output_delay_ms(e, 100, INFINITY);
    od_process(e, NULL, NULL, 40);
    od_process(e, input, output, 0);
    od_process(NULL, input, output, 40);
    check(od_output_level(e, -1) == 0.0f && od_source_level(e, 100) == 0.0f, "invalid meter indices");
    check(od_create(0.0, 32) == NULL && od_create(NAN, 32) == NULL && od_create(48000.0, 0) == NULL,
          "invalid create arguments");
    check(od_create((double)(UINT_MAX - 1u) * 1000.0 / OD_MAX_DELAY_MS + 1.0, 32) == NULL,
          "reject sample rates that overflow maximum delay samples");
    od_destroy(NULL);
    od_reset(NULL);
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    e = engine_create(8000.0, 64);
    input = list_create(1);
    output = list_create(1);
    in = buffer_create(input, 0, 2, 8000);
    out = buffer_create(output, 0, 2, 8000);
    for (unsigned i = 0; i < 16000; ++i) in[i] = (float)(0.01 * sin(i * 0.23));
    float gains[OD_EQ_BANDS] = {12, -12, 12, -12, 12};
    od_set_output_eq(e, 0, gains);
    od_process(e, input, output, 8000);
    int finite = 1;
    for (unsigned i = 0; i < 16000; ++i) if (!isfinite(out[i]) || fabsf(out[i]) > 1.0f) finite = 0;
    check(finite, "EQ frequencies below Nyquist at 8 kHz sample rate");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS short buffers, invalid arguments, null calls and low sample rate");
}

typedef struct {
    ODEngine *engine;
    AudioBufferList *input, *output;
    float *in, *out;
    unsigned capacity;
    size_t position;
} TapeIO;

static TapeIO tape_create(unsigned capacity, float delay) {
    TapeIO io = {0};
    io.engine = engine_create(48000.0, 31);
    io.input = list_create(1);
    io.output = list_create(1);
    io.in = buffer_create(io.input, 0, 2, capacity);
    io.out = buffer_create(io.output, 0, 4, capacity);
    io.capacity = capacity;
    int buffers[] = {0, 0}, offsets[] = {0, 2}, channels[] = {2, 2};
    od_set_output_layout(io.engine, 2, buffers, offsets, channels);
    od_set_route(io.engine, 0, 1, 1);
    od_set_output_delay_ms(io.engine, 0, delay);
    od_set_output_delay_ms(io.engine, 1, delay);
    return io;
}

static void tape_destroy(TapeIO *io) {
    od_destroy(io->engine);
    list_destroy(io->input);
    list_destroy(io->output);
}

static void tape_render(TapeIO *io, unsigned frames) {
    check(frames <= io->capacity, "tape fixture capacity");
    for (unsigned f = 0; f < frames; ++f) {
        double time = (double)(io->position + f) / 48000.0;
        io->in[f * 2u] = (float)(0.5 * sin(2.0 * pi * 1000.0 * time + 0.37));
        io->in[f * 2u + 1u] = (float)(0.37 * sin(2.0 * pi * 1733.0 * time + 0.19));
    }
    od_process(io->engine, io->input, io->output, frames);
    io->position += frames;
}

static unsigned tape_crossings(const TapeIO *io, unsigned begin, unsigned frames) {
    unsigned crossings = 0;
    for (unsigned f = begin + 1u; f < begin + frames; ++f)
        if (io->out[(f - 1u) * 4u] <= 0.0f && io->out[f * 4u] > 0.0f) ++crossings;
    return crossings;
}

static int tape_matches_reference(const TapeIO *io, unsigned begin, unsigned frames) {
    for (unsigned f = begin; f < begin + frames; ++f)
        if (memcmp(&io->out[f * 4u], &io->out[f * 4u + 2u], 2u * sizeof(float)) != 0) return 0;
    return 1;
}

static int tape_bounded(const TapeIO *io, unsigned frames) {
    for (unsigned i = 0; i < frames * 4u; ++i)
        if (!isfinite(io->out[i]) || fabsf(io->out[i]) > 1.0f) return 0;
    return 1;
}

static double tape_largest_step(const TapeIO *io, unsigned frames, double previous[2]) {
    double largest = 0.0;
    for (unsigned f = 0; f < frames; ++f) {
        for (unsigned c = 0; c < 2; ++c) {
            double value = io->out[f * 4u + c];
            largest = fmax(largest, fabs(value - previous[c]));
            previous[c] = value;
        }
    }
    return largest;
}

static void test_tape_default(void) {
    TapeIO io = tape_create(160137, 2500.0f);
    check(od_output_running(io.engine, 0) == 1 && od_output_running(io.engine, 1) == 1,
          "outputs default to running");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 160137);
    int unchanged = tape_matches_reference(&io, 0, 160137);
    for (unsigned f = 0; f < 160137; ++f) {
        for (unsigned c = 0; c < 2; ++c) {
            float expected = f < 120000u ? 0.0f : io.in[(f - 120000u) * 2u + c];
            if (memcmp(&io.out[f * 4u + c], &expected, sizeof(float)) != 0) unchanged = 0;
        }
    }
    check(unchanged, "default running is bit-identical to original integer-delay passthrough");
    tape_destroy(&io);
    io = tape_create(997, 180.0f);
    od_set_output_delay_ms(io.engine, 1, 0.0f);
    float *reference = calloc(48000u * 2u, sizeof(float));
    check(reference != NULL, "allocate legacy processing reference");
    float eq[OD_EQ_BANDS] = {3, -2, 4, 1, -3};
    for (int o = 0; o < 2; ++o) {
        od_set_output_gain(io.engine, o, 0.5f);
        od_set_output_eq(io.engine, o, eq);
    }
    unsigned base = 0;
    unchanged = 1;
    while (base < 48000u) {
        unsigned frames = 48000u - base < 997u ? 48000u - base : 997u;
        if (base == 12961u) {
            od_set_output_gain(io.engine, 0, 0.9f);
            od_set_output_gain(io.engine, 1, 0.9f);
        }
        if (base == 30907u) {
            eq[2] = -5.0f;
            od_set_output_eq(io.engine, 0, eq);
            od_set_output_eq(io.engine, 1, eq);
        }
        tape_render(&io, frames);
        for (unsigned f = 0; f < frames; ++f) {
            for (unsigned c = 0; c < 2; ++c) {
                reference[(base + f) * 2u + c] = io.out[f * 4u + c + 2u];
                float expected = base + f < 8640u ? 0.0f : reference[(base + f - 8640u) * 2u + c];
                if (memcmp(&io.out[f * 4u + c], &expected, sizeof(float)) != 0) unchanged = 0;
            }
        }
        base += frames;
    }
    check(unchanged, "default running preserves legacy gain and EQ changes before integer delay bit for bit");
    free(reference);
    tape_destroy(&io);
    puts("PASS default running, exact delayed stereo passthrough, oversized odd callback");
}

static void test_tape_stop(void) {
    TapeIO io = tape_create(48001, 1.0f);
    tape_render(&io, 48001);
    double previous[] = {io.out[48000u * 4u], io.out[48000u * 4u + 1u]};
    od_set_output_running(io.engine, 0, 0);
    check(od_output_running(io.engine, 0) == 0, "running accessor returns stop target before audio callback");
    tape_render(&io, 38401);
    check(tape_bounded(&io, 38401), "tape stop produces finite bounded stereo audio");
    check(tape_largest_step(&io, 38401, previous) < 0.09, "no discontinuity when tape stop begins or ends");
    unsigned last = UINT_MAX;
    int decreasing = 1;
    printf("Tape stop 50 ms frequencies:");
    for (unsigned w = 0; w < 14; ++w) {
        unsigned count = tape_crossings(&io, w * 2400u, 2400);
        if (count > last) decreasing = 0;
        last = count;
        printf(" %u", count * 20u);
    }
    putchar('\n');
    check(decreasing && tape_crossings(&io, 0, 2400) >= 40u && last <= 1u,
          "tape stop pitch decreases monotonically in successive 50 ms windows");
    int silent = 1;
    for (unsigned f = 33600; f < 38401; ++f)
        if (io.out[f * 4u] != 0.0f || io.out[f * 4u + 1u] != 0.0f) silent = 0;
    check(silent && od_output_level(io.engine, 0) == 0.0f, "stop ends in exact silence and zero meter after 700 ms");
    check(od_output_running(io.engine, 1) == 1 && od_output_level(io.engine, 1) > 0.4f,
          "tape stop is isolated to its output");
    tape_destroy(&io);
    puts("PASS tape stop pitch, duration, continuity, silence and meters");
}

static void test_tape_spin_up(void) {
    TapeIO io = tape_create(160001, 2500.0f);
    tape_render(&io, 160001);
    od_set_output_running(io.engine, 0, 0);
    tape_render(&io, 38401);
    od_set_output_running(io.engine, 0, 1);
    check(od_output_running(io.engine, 0) == 1, "running accessor returns spin-up target");
    tape_render(&io, 24001);
    double previous[] = {0.0, 0.0};
    check(io.out[0] == 0.0f && io.out[1] == 0.0f, "spin up begins with zero fade-in gain");
    check(tape_largest_step(&io, 24001, previous) < 0.09, "spin up and normal-position crossfade are continuous");
    check(tape_crossings(&io, 0, 2400) < tape_crossings(&io, 14400, 2400), "spin-up pitch rises toward original frequency");
    check(tape_matches_reference(&io, 21600, 2401), "spin up returns to bit-identical normal delayed stereo by 450 ms");
    check(tape_bounded(&io, 24001), "spin up produces finite bounded audio at 2500 ms delay");
    tape_destroy(&io);
    puts("PASS spin up, fade-in, continuity and exact return to delayed reference");
}

static void test_tape_mid_ramp_and_retention(void) {
    TapeIO io = tape_create(48001, 0.0f);
    tape_render(&io, 48001);
    double previous[] = {io.out[48000u * 4u], io.out[48000u * 4u + 1u]};
    const unsigned lengths[] = {24001, 2401, 4801, 7201, 961, 16801, 721, 24001};
    double largest = 0.0;
    int finite = 1;
    for (unsigned i = 0; i < sizeof(lengths) / sizeof(lengths[0]); ++i) {
        od_set_output_running(io.engine, 0, i & 1u);
        tape_render(&io, lengths[i]);
        largest = fmax(largest, tape_largest_step(&io, lengths[i], previous));
        if (!tape_bounded(&io, lengths[i])) finite = 0;
    }
    for (unsigned i = 0; i < 60; ++i) {
        od_set_output_running(io.engine, 0, i & 1u);
        tape_render(&io, 5761);
        largest = fmax(largest, tape_largest_step(&io, 5761, previous));
        if (!tape_bounded(&io, 5761)) finite = 0;
    }
    check(largest < 0.09 && finite, "mid-ramp reversals and bounded-history resync have no discontinuity");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(tape_matches_reference(&io, 21600, 2401), "repeated reversals recover exact reference timing");
    od_set_output_delay_ms(io.engine, 0, 3000.0f);
    od_set_output_delay_ms(io.engine, 1, 3000.0f);
    tape_render(&io, 48001);
    od_set_output_running(io.engine, 0, 0);
    for (unsigned i = 0; i < 7; ++i) tape_render(&io, 48001);
    check(od_output_level(io.engine, 0) == 0.0f, "long stopped output remains silent across ring wraps");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(tape_bounded(&io, 24001) && tape_matches_reference(&io, 21600, 2401),
          "spin up after long stop at maximum delay recovers finite exact reference");
    tape_destroy(&io);
    printf("PASS mid-ramp reversals, repeated toggles, long stop and 3000 ms delay, maximum step %.6f\n", largest);
}

static void test_tape_immediate(void) {
    TapeIO io = tape_create(48001, 1.0f);
    tape_render(&io, 48001);
    od_set_output_running_immediate(io.engine, 0, 0);
    check(od_output_running(io.engine, 0) == 0, "immediate stop publishes target");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(io.out[0] == 0.0f && io.out[1] == 0.0f && tape_crossings(&io, 0, 2400) < 15u,
          "immediate stop then running before one callback still produces spin up");
    check(tape_matches_reference(&io, 21600, 2401), "immediate stop then spin up restores exact reference");
    od_set_output_running_immediate(io.engine, 0, 0);
    tape_render(&io, 1);
    check(io.out[0] == 0.0f && io.out[1] == 0.0f && od_output_level(io.engine, 0) == 0.0f,
          "immediate stop silences audio and meter in next callback");
    od_set_output_running_immediate(io.engine, 0, 1);
    tape_render(&io, 1);
    check(tape_matches_reference(&io, 0, 1), "immediate running restores normal read position without a ramp");
    od_set_output_running_immediate(io.engine, 0, 0);
    od_reset(io.engine);
    tape_render(&io, 48001);
    check(od_output_running(io.engine, 0) == 0 && od_output_level(io.engine, 0) == 0.0f,
          "reset retains stopped target and clears tape history");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(tape_matches_reference(&io, 21600, 2401), "spin up after reset restores normal delayed reference");
    od_set_output_running(NULL, 0, 0);
    od_set_output_running(io.engine, -1, 0);
    od_set_output_running_immediate(NULL, 0, 0);
    od_set_output_running_immediate(io.engine, OD_MAX_OUTPUTS, 0);
    check(od_output_running(NULL, 0) == 0 && od_output_running(io.engine, -1) == 0 &&
          od_output_running(io.engine, OD_MAX_OUTPUTS) == 0, "running API validates pointers and output indices");
    tape_destroy(&io);
    io = tape_create(24001, 0.0f);
    od_set_output_running_immediate(io.engine, 0, 0);
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(io.out[0] == 0.0f && io.out[1] == 0.0f && tape_crossings(&io, 0, 2400) < 15u &&
          tape_matches_reference(&io, 21600, 2401), "fresh engine can start stopped then spin up before its first callback");
    tape_destroy(&io);
    puts("PASS immediate commands, coalesced startup spin up, reset, single-frame callbacks and API validation");
}

static void test_tape_clicks_and_eq(void) {
    TapeIO io = tape_create(48001, 0.0f);
    float gains[OD_EQ_BANDS] = {12, -12, 12, 12, -12};
    od_set_output_eq(io.engine, 0, gains);
    od_set_output_gain(io.engine, 0, 8.0f);
    tape_render(&io, 48001);
    od_set_output_running(io.engine, 0, 0);
    tape_render(&io, 38401);
    check(tape_bounded(&io, 38401) && od_output_level(io.engine, 0) == 0.0f,
          "limiter bounds interpolated audio and stopped EQ has no residual tails");
    od_set_test_clicks(io.engine, 1);
    tape_render(&io, 48001);
    int silent = 1;
    float clickPeak = 0.0f;
    for (unsigned f = 0; f < 48001; ++f) {
        if (io.out[f * 4u] != 0.0f || io.out[f * 4u + 1u] != 0.0f) silent = 0;
        clickPeak = fmaxf(clickPeak, fabsf(io.out[f * 4u + 2u]));
    }
    check(silent && clickPeak > 0.49f, "stopped output silences test clicks while other output clicks");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(tape_bounded(&io, 24001), "clicks spin up through EQ gain and limiter without NaN or Inf");
    tape_destroy(&io);
    puts("PASS clicks through tape stage, EQ, gain, limiter and exact stopped silence");
}

static void test_tape_return_reversal(void) {
    TapeIO io = tape_create(48001, 137.3f);
    float gains[OD_EQ_BANDS] = {12, 0, 6, 0, 0};
    for (int o = 0; o < 2; ++o) {
        od_set_output_gain(io.engine, o, 0.4f);
        od_set_output_eq(io.engine, o, gains);
    }
    tape_render(&io, 48001);
    od_set_output_running_immediate(io.engine, 0, 0);
    tape_render(&io, 1);
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 17521);
    double previous[] = {io.out[17520u * 4u], io.out[17520u * 4u + 1u]};
    od_set_output_running(io.engine, 0, 0);
    tape_render(&io, 4801);
    check(tape_largest_step(&io, 4801, previous) < 0.09 && tape_bounded(&io, 4801),
          "reversing during catch-up crossfade remains continuous with active EQ");
    od_set_output_running(io.engine, 0, 1);
    tape_render(&io, 24001);
    check(tape_matches_reference(&io, 21600, 2401),
          "spin-up recovery is bit-identical even with active EQ and gain");
    od_set_output_running(io.engine, 0, 0);
    tape_render(&io, 48001);
    check(io.out[48000u * 4u] == 0.0f && io.out[48000u * 4u + 1u] == 0.0f &&
          od_output_level(io.engine, 0) == 0.0f, "stopped filtered output has no tail after return reversal");
    tape_destroy(&io);
    puts("PASS reversal during catch-up, active EQ continuity and bit-identical filtered recovery");
}

typedef struct {
    ODEngine *engine;
    atomic_uint ready, done, bad;
} Stress;

static void test_source_gain(void) {
    const unsigned frames = 48000;
    AudioBufferList *input = list_create(2), *output = list_create(2);
    float *a = buffer_create(input, 0, 2, frames);
    float *b = buffer_create(input, 1, 2, frames);
    float *left = buffer_create(output, 0, 2, frames);
    float *right = buffer_create(output, 1, 2, frames);
    ODEngine *e = od_create(48000.0, 512);
    int sourceBuffers[2] = {0, 1}, sourceOffsets[2] = {0, 0};
    od_set_source_layout(e, 2, sourceBuffers, sourceOffsets);
    int outBuffers[2] = {0, 1}, outOffsets[2] = {0, 0}, outChannels[2] = {2, 2};
    od_set_output_layout(e, 2, outBuffers, outOffsets, outChannels);
    for (int s = 0; s < 2; ++s) {
        for (int o = 0; o < 2; ++o) od_set_route(e, s, o, 1);
    }
    for (unsigned f = 0; f < frames; ++f) {
        a[2u * f] = a[2u * f + 1u] = 0.2f;
        b[2u * f] = b[2u * f + 1u] = 0.1f;
    }
    od_process(e, input, output, frames);
    float reference = left[(frames - 1u) * 2u];
    check(fabsf(reference - 0.3f) < 1e-6f, "default source gain is unity");
    od_set_source_gain(e, 0, 0.5f);
    od_process(e, input, output, frames);
    double largest = 0.0;
    for (unsigned f = 1; f < frames; ++f) largest = fmax(largest, fabs((double)left[2u * f] - (double)left[2u * (f - 1u)]));
    check(largest < 0.002, "source gain change is smooth");
    check(fabsf(left[(frames - 1u) * 2u] - 0.2f) < 1e-5f, "source gain 0.5 halves its contribution");
    check(fabsf(right[(frames - 1u) * 2u] - 0.2f) < 1e-5f, "source gain applies to every routed output");
    od_set_source_gain(e, 1, 5.0f);
    od_set_source_gain(e, 0, NAN);
    od_process(e, input, output, frames);
    check(left[(frames - 1u) * 2u] > 0.35f && isfinite(left[(frames - 1u) * 2u]), "source gain clamps and rejects NaN");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS per-source gain, smoothing, clamping and routing");
}

static void test_source_gain_regressions(void) {
    const unsigned frames = 48001;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 4, frames);
    float *out = buffer_create(output, 0, 8, frames);
    ODEngine *e = od_create(48000.0, 31);
    check(e != NULL, "create source gain regression engine");
    int sourceBuffers[] = {0, 0}, sourceOffsets[] = {0, 2};
    int outputBuffers[] = {0, 0, 0, 0}, outputOffsets[] = {0, 2, 4, 6}, channels[] = {2, 2, 2, 2};
    od_set_source_layout(e, 2, sourceBuffers, sourceOffsets);
    od_set_output_layout(e, 4, outputBuffers, outputOffsets, channels);
    od_set_route(e, 0, 0, 1);
    od_set_route(e, 0, 1, 1);
    od_set_route(e, 0, 3, 1);
    od_set_route(e, 1, 0, 1);
    od_set_route(e, 1, 2, 1);
    od_set_route(e, 1, 3, 1);
    for (unsigned f = 0; f < frames; ++f) {
        in[f * 4u] = (float)((int)(f % 113u) - 56) / 256.0f;
        in[f * 4u + 1u] = (float)((int)((f * 7u) % 131u) - 65) / 256.0f;
        in[f * 4u + 2u] = (float)((int)(f % 73u) - 36) / 512.0f;
        in[f * 4u + 3u] = (float)((int)((f * 3u) % 97u) - 48) / 512.0f;
    }
    in[0] = -0.0f;
    in[1] = FLT_TRUE_MIN;
    od_process(e, input, output, frames);
    int exact = 1;
    for (unsigned f = 0; f < frames; ++f) {
        for (unsigned c = 0; c < 2; ++c) {
            float sum = (float)((double)in[f * 4u + c] + in[f * 4u + c + 2u]);
            if (memcmp(&out[f * 8u + c], &sum, sizeof(float)) != 0 ||
                memcmp(&out[f * 8u + c + 2u], &in[f * 4u + c], sizeof(float)) != 0 ||
                memcmp(&out[f * 8u + c + 4u], &in[f * 4u + c + 2u], sizeof(float)) != 0 ||
                memcmp(&out[f * 8u + c + 6u], &sum, sizeof(float)) != 0) exact = 0;
        }
    }
    check(exact, "default source gains preserve original stereo mixing bit for bit including signed zero and subnormals");
    od_set_source_gain(e, 0, 1.0f);
    od_set_source_gain(e, 1, 1.0f);
    od_process(e, input, output, frames);
    check(memcmp(&out[2], &in[0], 2u * sizeof(float)) == 0,
          "explicit unity source gain preserves signed zero and subnormals");
    for (unsigned f = 0; f < frames; ++f) {
        in[f * 4u] = 0.2f;
        in[f * 4u + 1u] = -0.3f;
        in[f * 4u + 2u] = 0.1f;
        in[f * 4u + 3u] = 0.15f;
    }
    od_set_source_gain(e, 0, 0.5f);
    od_process(e, input, output, frames);
    const unsigned last = (frames - 1u) * 8u;
    check(fabsf(out[last] - (0.2f * 0.5f + 0.1f)) < 1e-7f &&
          fabsf(out[last + 1u] - (-0.3f * 0.5f + 0.15f)) < 1e-7f &&
          fabsf(out[last + 2u] - 0.1f) < 1e-7f && fabsf(out[last + 3u] + 0.15f) < 1e-7f,
          "half source gain halves only its stereo contribution in a two-source mix");
    check(fabsf(od_source_level(e, 0) - 0.15f) < 0.01f, "source meter reflects post-gain contribution");
    int shared = 1;
    for (unsigned f = 0; f < frames; ++f) {
        if (memcmp(&out[f * 8u], &out[f * 8u + 6u], 2u * sizeof(float)) != 0 ||
            out[f * 8u + 4u] != 0.1f || out[f * 8u + 5u] != 0.15f ||
            fabsf(out[f * 8u] - (out[f * 8u + 2u] + 0.1f)) > 1e-7f ||
            fabsf(out[f * 8u + 1u] - (out[f * 8u + 3u] + 0.15f)) > 1e-7f) shared = 0;
    }
    check(shared, "one source smoothing trajectory feeds all routes and leaves the other source unchanged");
    double previous[] = {out[last + 2u], out[last + 3u]};
    od_set_source_gain(e, 0, 0.0f);
    od_process(e, input, output, frames);
    double largest = 0.0;
    for (unsigned f = 0; f < frames; ++f) {
        for (unsigned c = 0; c < 2; ++c) {
            double value = out[f * 8u + c + 2u];
            largest = fmax(largest, fabs(value - previous[c]));
            previous[c] = value;
        }
    }
    check(largest < 0.0004 && out[2] > 0.099f && out[2] < 0.1f,
          "source mute is smooth including the first sample at a callback boundary");
    check(fabsf(out[479u * 8u + 2u] - (float)(0.1 * exp(-1.0))) < 1e-6f,
          "source gain smoothing has a 10 ms time constant");
    check(out[last + 2u] == 0.0f && out[last + 3u] == 0.0f &&
          out[last] == 0.1f && out[last + 1u] == 0.15f, "source mute converges to exact silence without muting the other source");
    od_set_source_gain(e, 0, 8.0f);
    od_process(e, input, output, frames);
    check(fabsf(out[last + 2u] - 0.4f) < 1e-7f && fabsf(out[last + 3u] + 0.6f) < 1e-7f,
          "source gain clamps at two");
    od_set_source_gain(e, 0, -1.0f);
    od_process(e, input, output, frames);
    check(out[last + 2u] == 0.0f && out[last + 3u] == 0.0f, "source gain clamps at zero");
    od_set_source_gain(NULL, 0, 1.0f);
    od_set_source_gain(e, -1, 1.0f);
    od_set_source_gain(e, OD_MAX_SOURCES, 1.0f);
    od_process(e, input, output, 1);
    check(out[2] == 0.0f && out[3] == 0.0f, "source gain validates engine and source indices");
    od_set_source_gain(e, 0, INFINITY);
    od_set_source_gain(e, 1, -INFINITY);
    od_process(e, input, output, frames);
    int finite = 1;
    for (unsigned i = 0; i < frames * 8u; ++i)
        if (!isfinite(out[i]) || fabsf(out[i]) > 1.0f) finite = 0;
    check(finite, "nonfinite source gains remain bounded and finite");
    od_destroy(e);
    list_destroy(input);
    list_destroy(output);
    puts("PASS source gain bit identity, stereo mix, independent routes, boundary smoothing, range and validation");
}

static void *stress_audio(void *context) {
    Stress *stress = context;
    AudioBufferList *input = list_create(1), *output = list_create(1);
    float *in = buffer_create(input, 0, 2, 64);
    float *out = buffer_create(output, 0, 2, 64);
    for (unsigned i = 0; i < 128; ++i) in[i] = (float)(0.1 * sin(i * 0.1));
    atomic_store(&stress->ready, 1u);
    unsigned blocks = 0;
    while (!atomic_load(&stress->done) || blocks < 2000) {
        od_process(stress->engine, input, output, 64);
        for (unsigned i = 0; i < 128; ++i)
            if (!isfinite(out[i]) || fabsf(out[i]) > 1.0f) atomic_store(&stress->bad, 1u);
        ++blocks;
    }
    list_destroy(input);
    list_destroy(output);
    return NULL;
}

static void test_concurrent_setters(void) {
    Stress stress;
    stress.engine = engine_create(48000.0, 32);
    atomic_init(&stress.ready, 0u);
    atomic_init(&stress.done, 0u);
    atomic_init(&stress.bad, 0u);
    pthread_t thread;
    check(pthread_create(&thread, NULL, stress_audio, &stress) == 0, "start audio stress thread");
    while (!atomic_load(&stress.ready)) {}
    int metersValid = 1;
    for (unsigned i = 0; i < 20000; ++i) {
        float gains[OD_EQ_BANDS];
        for (unsigned b = 0; b < OD_EQ_BANDS; ++b) gains[b] = (float)((int)((i + b) % 25u) - 12);
        od_set_output_eq(stress.engine, 0, gains);
        od_set_output_gain(stress.engine, 0, (float)(i % 4u) * 0.5f);
        od_set_source_gain(stress.engine, 0, (float)(i % 7u) * 0.5f);
        od_set_output_delay_ms(stress.engine, 0, (float)(i % 1001u));
        od_set_route(stress.engine, 0, 0, i & 1u);
        od_set_test_clicks(stress.engine, i % 7u == 0);
        if (i % 11u == 0) od_set_output_running_immediate(stress.engine, 0, i & 1u);
        else od_set_output_running(stress.engine, 0, i & 1u);
        float source = od_source_level(stress.engine, 0), output = od_output_level(stress.engine, 0);
        if (!isfinite(source) || !isfinite(output) || source < 0 || source > 1 || output < 0 || output > 1) metersValid = 0;
    }
    atomic_store(&stress.done, 1u);
    check(pthread_join(thread, NULL) == 0, "join audio stress thread");
    check(!atomic_load(&stress.bad) && metersValid, "concurrent EQ, gain, delay, routes, clicks and meters");
    od_destroy(stress.engine);
    puts("PASS concurrent main-thread setters and audio processing");
}

int main(void) {
    test_delays();
    test_layouts_and_routing();
    test_gain_and_mono();
    test_eq();
    test_clicks();
    test_delay_crossfade();
    test_limiter_and_invalid_audio();
    test_short_buffers_and_validation();
    test_tape_default();
    test_tape_stop();
    test_tape_spin_up();
    test_tape_mid_ramp_and_retention();
    test_tape_immediate();
    test_tape_clicks_and_eq();
    test_tape_return_reversal();
    test_source_gain();
    test_source_gain_regressions();
    test_concurrent_setters();
    printf("All DSP tests passed (%u checks).\n", atomic_load(&checks));
    return 0;
}
