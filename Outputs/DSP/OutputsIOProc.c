#include "OutputsIOProc.h"
#include "OutputsDSP.h"

OSStatus od_device_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *client)
{
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputTime;
    if (client == NULL || output == NULL) {
        return noErr;
    }
    unsigned frames = 0;
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        const AudioBuffer *buffer = &output->mBuffers[i];
        if (buffer->mNumberChannels > 0 && buffer->mDataByteSize > 0) {
            frames = buffer->mDataByteSize / (buffer->mNumberChannels * (UInt32)sizeof(float));
            break;
        }
    }
    if (frames == 0) {
        return noErr;
    }
    od_process((ODEngine *)client, input, output, frames);
    return noErr;
}

const AudioDeviceIOProc od_ioproc = od_device_ioproc;
