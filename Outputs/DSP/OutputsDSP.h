#ifndef OUTPUTS_DSP_H
#define OUTPUTS_DSP_H

#include <CoreAudio/CoreAudioTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OD_MAX_OUTPUTS 8
#define OD_MAX_SOURCES 9
#define OD_EQ_BANDS 5
#define OD_MAX_DELAY_MS 3000

typedef struct ODEngine ODEngine;

ODEngine *od_create(double sampleRate, unsigned maxFrames);
void od_destroy(ODEngine *engine);
void od_set_source_layout(ODEngine *engine, int sourceCount,
                          const int *bufferIndex, const int *channelOffset);
void od_set_output_layout(ODEngine *engine, int outputCount,
                          const int *bufferIndex, const int *channelOffset,
                          const int *channelCount);
void od_set_source_gain(ODEngine *engine, int source, float linear);
void od_set_route(ODEngine *engine, int source, int output, int enabled);
void od_set_output_gain(ODEngine *engine, int output, float linear);
void od_set_output_delay_ms(ODEngine *engine, int output, float ms);
void od_set_output_running(ODEngine *engine, int output, int running);
void od_set_output_running_immediate(ODEngine *engine, int output, int running);
int od_output_running(ODEngine *engine, int output);
void od_set_output_eq(ODEngine *engine, int output,
                      const float gainsDb[OD_EQ_BANDS]);
void od_set_test_clicks(ODEngine *engine, int enabled);
float od_output_level(ODEngine *engine, int output);
float od_source_level(ODEngine *engine, int source);
void od_reset(ODEngine *engine);
void od_process(ODEngine *engine, const AudioBufferList *input,
                AudioBufferList *output, unsigned frames);

#ifdef __cplusplus
}
#endif

#endif
