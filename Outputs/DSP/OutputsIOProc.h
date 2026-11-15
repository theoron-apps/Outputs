#ifndef OutputsIOProc_h
#define OutputsIOProc_h

#include <CoreAudio/CoreAudio.h>

OSStatus od_device_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *client);

extern const AudioDeviceIOProc od_ioproc;

#endif
