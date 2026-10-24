#ifndef VPAudioSync_h
#define VPAudioSync_h

#include <math.h>
#include <stdint.h>
#include <string.h>

// More history than the eight outstanding AudioQueue buffers. No allocation on
// the audio callback. All access is serialized by the player's audio lock.
#define VP_AUDIO_SYNC_SPANS 64
typedef struct {
    double sampleStart;
    double mediaStart;
    double mediaFrames;
    double totalFrames;
} VPAudioSyncSpan;

typedef struct {
    VPAudioSyncSpan spans[VP_AUDIO_SYNC_SPANS];
    unsigned first, count;
    double submittedFrames, mediaEnd, lastClock;
} VPAudioSync;

static inline void VPAudioSyncReset(VPAudioSync *sync, double pts) {
    memset(sync, 0, sizeof(*sync));
    sync->mediaEnd = sync->lastClock = pts;
}

static inline void VPAudioSyncAppend(VPAudioSync *sync, double pts,
                                     double mediaFrames, double totalFrames, double rate) {
    if (sync->count == VP_AUDIO_SYNC_SPANS) {
        sync->first = (sync->first + 1) % VP_AUDIO_SYNC_SPANS;
        sync->count--;
    }
    unsigned index = (sync->first + sync->count++) % VP_AUDIO_SYNC_SPANS;
    sync->spans[index] = (VPAudioSyncSpan){sync->submittedFrames, pts, mediaFrames, totalFrames};
    sync->submittedFrames += totalFrames;
    sync->mediaEnd = pts + mediaFrames / rate;
}

// Queue sample time starts at zero, not at the first clock query. Silence added
// for an underrun occupies device time but must not advance media time.
static inline double VPAudioSyncClock(VPAudioSync *sync, double sampleTime, double rate) {
    if (!sync->count || !isfinite(sampleTime) || rate <= 0) return sync->lastClock;
    double pts = sync->mediaEnd;
    for (unsigned i = 0; i < sync->count; i++) {
        VPAudioSyncSpan span = sync->spans[(sync->first + i) % VP_AUDIO_SYNC_SPANS];
        if (sampleTime < span.sampleStart + span.totalFrames) {
            double frames = fmax(0, fmin(span.mediaFrames, sampleTime - span.sampleStart));
            pts = span.mediaStart + frames / rate;
            break;
        }
    }
    // A stale hardware timestamp must not move the display backwards.
    sync->lastClock = fmax(sync->lastClock, pts);
    return sync->lastClock;
}

#endif
