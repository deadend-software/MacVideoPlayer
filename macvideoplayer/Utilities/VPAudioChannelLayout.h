// Maps FFmpeg sample order to Core Audio speaker positions.
#ifndef VPAudioChannelLayout_h
#define VPAudioChannelLayout_h

#import <AudioToolbox/AudioToolbox.h>
#include <libavutil/channel_layout.h>
#include <stddef.h>

static inline OSStatus VPSetAudioQueueChannelLayout(AudioQueueRef queue, const AVChannelLayout *source) {
    if (!source || source->nb_channels < 1 || source->nb_channels > 32) return kAudio_ParamError;
    UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) +
                          source->nb_channels * sizeof(AudioChannelDescription));
    AudioChannelLayout *layout = calloc(1, size);
    if (!layout) return kAudio_MemFullError;
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = source->nb_channels;
    BOOL hasSides = av_channel_layout_index_from_channel(source, AV_CHAN_SIDE_LEFT) >= 0;
    for (int i = 0; i < source->nb_channels; i++) {
        AudioChannelLabel label;
        switch (av_channel_layout_channel_from_index(source, i)) {
            case AV_CHAN_FRONT_LEFT: label = kAudioChannelLabel_Left; break;
            case AV_CHAN_FRONT_RIGHT: label = kAudioChannelLabel_Right; break;
            case AV_CHAN_FRONT_CENTER: label = kAudioChannelLabel_Center; break;
            case AV_CHAN_LOW_FREQUENCY: label = kAudioChannelLabel_LFEScreen; break;
            case AV_CHAN_BACK_LEFT: label = hasSides ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround; break;
            case AV_CHAN_BACK_RIGHT: label = hasSides ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround; break;
            case AV_CHAN_SIDE_LEFT: label = kAudioChannelLabel_LeftSurround; break;
            case AV_CHAN_SIDE_RIGHT: label = kAudioChannelLabel_RightSurround; break;
            case AV_CHAN_BACK_CENTER: label = kAudioChannelLabel_CenterSurround; break;
            default: free(layout); return kAudio_ParamError;
        }
        layout->mChannelDescriptions[i].mChannelLabel = label;
    }
    OSStatus status = AudioQueueSetProperty(queue, kAudioQueueProperty_ChannelLayout, layout, size);
    free(layout);
    return status;
}
#endif
