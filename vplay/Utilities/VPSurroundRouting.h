#import <Foundation/Foundation.h>
#import "VPFFmpeg.h"

// VLC 3 amem uses WG4 order: L R sides rears rear-center center LFE.
// Reorder to FFmpeg's native layout before any filtering or Core Audio output.
static inline const char *VPVLCLayoutName(unsigned channels) {
    static const char *names[] = {"", "mono", "stereo", "2.1", "quad", "5.0", "5.1", "6.1", "7.1"};
    return channels >= 1 && channels <= 8 ? names[channels] : "stereo";
}
static inline unsigned VPVLCChannelIndex(unsigned channels, unsigned destination) {
    static const unsigned order[9][8] = {
        {0}, {0}, {0,1}, {0,1,2}, {0,1,2,3},
        {0,1,4,2,3}, {0,1,4,5,2,3}, {0,1,5,6,4,2,3}, {0,1,6,7,4,5,2,3}
    };
    return channels >= 1 && channels <= 8 && destination < channels ? order[channels][destination] : destination;
}

// Resolve the built-in upmixer against the decoded frame, not a possibly stale UI probe.
static inline NSString *VPResolvedSurroundGraph(NSString *graph, const AVChannelLayout *source) {
    if (source->nb_channels <= 2) return graph;
    NSMutableArray<NSString *> *stages = [[graph componentsSeparatedByString:@","] mutableCopy];
    for (NSUInteger i = 1; i < stages.count; i++) {
        if ([stages[i] isEqual:@"lowpass=f=120:c=LFE"]) { stages[i] = @"anull"; continue; }
        NSString *stage = stages[i];
        BOOL surround = [stage hasPrefix:@"surround=chl_out="] && [stage containsString:@"chl_in=stereo"];
        BOOL matrix = [stage hasPrefix:@"pan="];
        if (![stages[i - 1] isEqual:@"aformat=channel_layouts=stereo"] || (!surround && !matrix)) continue;
        NSString *target = matrix ? [[stage substringFromIndex:4] componentsSeparatedByString:@"|"].firstObject :
            [[stage substringFromIndex:[@"surround=chl_out=" length]] componentsSeparatedByString:@":"].firstObject;
        if (matrix && i + 1 < stages.count && [stages[i + 1] hasPrefix:@"adelay=0|0|0|0|23|27"]) stages[i + 1] = @"anull";
        char description[128];
        av_channel_layout_describe(source, description, sizeof(description));
        NSString *input = @(description);
        stages[i - 1] = @"anull";
        if ([target isEqual:@"7.1"] && ([input isEqual:@"5.1"] || [input isEqual:@"5.1(side)"] || [input isEqual:@"5.0(side)"])) {
            stages[i] = [NSString stringWithFormat:@"surround=chl_in=%@:chl_out=7.1", input];
        } else {
            // Preserve authored positions; resampling handles only the requested layout conversion.
            stages[i] = [NSString stringWithFormat:@"aformat=channel_layouts=%@", target];
        }
    }
    return [stages componentsJoinedByString:@","];
}
