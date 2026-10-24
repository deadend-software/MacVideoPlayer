#include <stdbool.h>
bool VPCheckAudioGraph(const char *method, const char *layout, const char *inputLayout, int channels);
bool VPCheckVideoReset(void);
bool VPCheckSpeakerOrder(const char *layout);
bool VPCheckAppleDirections(const char *layout, int scenario);
bool VPCheckAuthoredChannels(const char *method, const char *layout);
bool VPCheckDVDOrder(void);
bool VPCheckConvertedSurround(const char *layout);

bool VPCheckSurroundFill(const char *inputLayout, const char *outputLayout);
bool VPCheckEncodedSurround(const char *codec);
bool VPCheckAudioEnhancementReset(void);
