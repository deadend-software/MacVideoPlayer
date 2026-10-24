#import "CEffects.h"
#import "../../../../macvideoplayer/Effects/VPAIEnhancer.m"
#import "../../../../macvideoplayer/Audio/VPAudioDeviceManager.m"
#import "VPFFmpeg.h"
#import <AudioToolbox/AudioToolbox.h>
#import "../../../../macvideoplayer/Audio/VPAppleSurroundProcessor.m"
#import "VPSurroundRouting.h"
#import "../../../../macvideoplayer/Utilities/VPFFmpegLibrary.m"

// Capture the real layout helper's Core Audio property without opening hardware.
static AudioChannelLabel labels[32];
static UInt32 labelCount;
static OSStatus CaptureLayout(AudioQueueRef queue, AudioQueuePropertyID property, const void *data, UInt32 size) {
    const AudioChannelLayout *layout = data;
    labelCount = layout->mNumberChannelDescriptions;
    for (UInt32 i = 0; i < labelCount; i++) labels[i] = layout->mChannelDescriptions[i].mChannelLabel;
    return noErr;
}
#define AudioQueueSetProperty CaptureLayout
#import "VPAudioChannelLayout.h"
#undef AudioQueueSetProperty

bool VPCheckSpeakerOrder(const char *name) {
    AVChannelLayout layout = {0};
    if (av_channel_layout_from_string(&layout, name) < 0) return false;
    bool result = VPSetAudioQueueChannelLayout(NULL, &layout) == noErr && labelCount == layout.nb_channels;
    // Explicit expected orders catch center/LFE/surround swaps, especially 4.1 versus 5.0.
    NSArray<NSNumber *> *expected = @{
        @"mono": @[@3], @"stereo": @[@1, @2], @"2.1": @[@1, @2, @4],
        @"quad": @[@1, @2, @5, @6], @"4.1": @[@1, @2, @3, @4, @9],
        @"5.0": @[@1, @2, @3, @5, @6], @"5.1": @[@1, @2, @3, @4, @5, @6],
        @"7.1": @[@1, @2, @3, @4, @33, @34, @5, @6]
    }[@(name)];
    result &= expected.count == labelCount;
    for (UInt32 i = 0; i < labelCount && i < expected.count; i++) result &= labels[i] == expected[i].unsignedIntValue;
    av_channel_layout_uninit(&layout);
    return result;
}

bool VPCheckAudioGraph(const char *method, const char *layout, const char *inputLayout, int channels) {
    @autoreleasepool {
        VPAIEnhancer *ai = [VPAIEnhancer new];
        ai.surroundMethod = @(method);
        ai.targetLayout = @(layout);
        if ([@(method) hasPrefix:@"preset:"]) [ai applyAudioPreset:[@(method) substringFromIndex:7]];
        AVChannelLayout sourceLayout = {0};
        av_channel_layout_from_string(&sourceLayout, inputLayout);
        NSString *filters = VPResolvedSurroundGraph([ai audioFilterGraphString], &sourceLayout);
        NSMutableArray *signals = [NSMutableArray array];
        for (int c = 0; c < sourceLayout.nb_channels; c++)
            [signals addObject:[NSString stringWithFormat:@"0.08*sin(2*PI*%d*t)+0.06*sin(2*PI*%d*t)", 60 + c * 23, 440 + c * 197]];
        av_channel_layout_uninit(&sourceLayout);
        NSString *description = [NSString stringWithFormat:
            @"aevalsrc=%@:s=48000:d=0.5:c=%@,%@,aformat=sample_fmts=flt,abuffersink",
            [signals componentsJoinedByString:@"|"], @(inputLayout), filters];
        AVFilterGraph *graph = avfilter_graph_alloc();
        AVFilterInOut *inputs = NULL, *outputs = NULL;
        int result = avfilter_graph_parse_ptr(graph, description.UTF8String, &inputs, &outputs, NULL);
        avfilter_inout_free(&inputs);
        avfilter_inout_free(&outputs);
        if (result >= 0) result = avfilter_graph_config(graph, NULL);
        AVFilterContext *sink = NULL;
        for (unsigned i = 0; i < graph->nb_filters; i++) {
            if (!strcmp(graph->filters[i]->filter->name, "abuffersink")) sink = graph->filters[i];
        }
        double energy[32] = {0};
        int samples = 0;
        AVFrame *frame = av_frame_alloc();
        VPAppleSurroundProcessor *apple = [VPAppleSurroundProcessor new];
        bool valid = result >= 0 && sink;
        while (valid && (result = av_buffersink_get_frame(sink, frame)) >= 0) {
            AVFrame *processed = frame;
            if ([ai.surroundMethod isEqual:@"apple_51"] || [ai.surroundMethod isEqual:@"apple_71"])
                processed = [apple processFrame:frame layout:[ai.surroundMethod isEqual:@"apple_71"] ? @"7.1" : @"5.1"];
            AVChannelLayout target = {0};
            av_channel_layout_from_string(&target, channels == 8 ? "7.1" : channels == 6 ? "5.1" : channels == 3 ? "2.1" : channels == 5 ? layout : channels == 4 ? "quad" : channels == 1 ? "mono" : "stereo");
            SwrContext *converter = NULL;
            int conversion = swr_alloc_set_opts2(&converter, &target, AV_SAMPLE_FMT_FLT, 48000, &processed->ch_layout,
                processed->format, processed->sample_rate, 0, NULL);
            if (conversion >= 0) conversion = swr_init(converter);
            float *data = calloc((size_t)processed->nb_samples * channels, sizeof(float));
            uint8_t *planes[] = {(uint8_t *)data};
            int count = conversion >= 0 ? swr_convert(converter, planes, processed->nb_samples, (const uint8_t **)processed->extended_data, processed->nb_samples) : -1;
            valid &= count > 0;
            for (int n = 0; n < count && valid; n++) {
                for (int c = 0; c < channels; c++) {
                    float sample = data[n * channels + c];
                    valid &= isfinite(sample) && fabsf(sample) <= 1.01;
                    energy[c] += sample * sample;
                }
            }
            samples += MAX(0, count);
            free(data);
            swr_free(&converter);
            av_channel_layout_uninit(&target);
            av_frame_unref(frame);
        }
        valid &= result == AVERROR_EOF && samples > 0;
        double totalEnergy = 0;
        for (int c = 0; c < channels; c++) {
            totalEnergy += energy[c];
            // Mono contains no independent rear ambience; directional extraction must not invent it.
            if (strcmp(inputLayout, "mono")) valid &= energy[c] > 0.000001;
        }
        valid &= totalEnergy > 0.000001;
        if (!valid) fprintf(stderr, "Graph failed: %s / %s / %s (result %d, samples %d)\n", method, layout, inputLayout, result, samples);
        av_frame_free(&frame);
        avfilter_graph_free(&graph);
        return valid;
    }
}

bool VPCheckVideoReset(void) {
    VPAIEnhancer *ai = [VPAIEnhancer new];
    if (ai.videoAIEnabled || ai.isVideoAIActive) return false;
    [ai applyVideoPreset:@"cinema_hdr"];
    ai.adaptiveVideoEnabled = YES;
    ai.visionSaliencyFocus = YES;
    ai.shadowLift = ai.highlightRecovery = ai.saturationTrim = ai.temperatureShift = 0.5;
    ai.audioAIEnabled = YES;
    ai.surroundMethod = @"apple_71";
    [ai resetVideoAI];
    return !ai.videoAIEnabled && !ai.isVideoAIActive && !ai.adaptiveVideoEnabled &&
        [ai.activeVideoPreset isEqual:@"none"] && ai.upscaleFactor == 1 &&
        ai.clarityBoost == 0 && ai.luminanceSharpness == 0 && ai.adaptiveDenoise == 0 &&
        ai.microContrast == 0 && ai.vividVibrance == 0 && !ai.hdrDynamicTone &&
        !ai.cinemaColorGrade && !ai.visionSaliencyFocus && ai.shadowLift == 0 &&
        ai.highlightRecovery == 0 && ai.saturationTrim == 0 && ai.temperatureShift == 0 &&
        ai.audioAIEnabled && [ai.surroundMethod isEqual:@"apple_71"];
}

bool VPCheckAppleDirections(const char *layout, int scenario) {
    VPAppleSurroundProcessor *processor = [VPAppleSurroundProcessor new];
    AVFrame *frame = av_frame_alloc();
    frame->format = AV_SAMPLE_FMT_FLTP;
    frame->sample_rate = 48000;
    frame->nb_samples = 12000;
    av_channel_layout_default(&frame->ch_layout, scenario == 4 ? 1 : 2);
    if (av_frame_get_buffer(frame, 0) < 0) { av_frame_free(&frame); return false; }
    for (int i = 0; i < frame->nb_samples; i++) {
        float signal = scenario == 5 ? 0 : sinf(2 * M_PI * 997 * i / 48000);
        ((float *)frame->data[0])[i] = scenario == 1 ? 0 : signal;
        if (frame->ch_layout.nb_channels == 2)
            ((float *)frame->data[1])[i] = scenario == 0 ? 0 : scenario == 3 ? -signal : signal;
    }
    AVFrame *output = [processor processFrame:frame layout:@(layout)];
    int channels = !strcmp(layout, "7.1") ? 8 : 6;
    bool valid = output->ch_layout.nb_channels == channels;
    double energy[8] = {0}, sideRearDifference = 0;
    if (valid) for (int i = 2000; i < output->nb_samples; i++) {
        for (int c = 0; c < channels; c++) {
            float value = ((float *)output->data[c])[i];
            valid &= isfinite(value) && fabsf(value) <= 1;
            energy[c] += value * value;
        }
        if (channels == 8) {
            float delta = ((float *)output->data[4])[i] - ((float *)output->data[6])[i];
            sideRearDifference += delta * delta;
        }
    }
    if (scenario == 0) valid &= energy[0] > 1 && energy[1] < 1e-8 && energy[2] < 1e-8;
    if (scenario == 1) valid &= energy[1] > 1 && energy[0] < 1e-8 && energy[2] < 1e-8;
    if (scenario == 2 || scenario == 4) {
        valid &= energy[0] > energy[2] && energy[2] > 1 && fabs(energy[0] - energy[1]) < 1e-5;
        for (int c = 4; c < channels; c++) valid &= energy[c] > 0.1 && energy[c] < energy[0] * 0.02;
    }
    if (scenario == 5) for (int c = 0; c < channels; c++) valid &= energy[c] == 0;
    if (scenario == 3) valid &= energy[2] < 1e-8 && energy[4] > 1 && energy[5] > 1 && (channels == 6 || (energy[6] > 1 && energy[7] > 1 && sideRearDifference > 1));
    // A high-frequency voice/effect must not be copied full-band into the subwoofer.
    valid &= energy[3] <= (energy[0] + energy[1]) * 0.01;
    av_frame_free(&frame);
    return valid;
}

bool VPCheckAuthoredChannels(const char *method, const char *layout) {
    AVChannelLayout source = {0};
    av_channel_layout_from_string(&source, layout);
    bool valid = true;
    for (int speaker = 0; speaker < source.nb_channels; speaker++) {
        VPAIEnhancer *ai = [VPAIEnhancer new];
        ai.surroundMethod = @(method);
        ai.targetLayout = @(layout);
        NSMutableArray *signals = [NSMutableArray array];
        for (int c = 0; c < source.nb_channels; c++)
            [signals addObject:c == speaker ? @"0.2*sin(2*PI*440*t)" : @"0"];
        NSString *filters = VPResolvedSurroundGraph([ai audioFilterGraphString], &source);
        NSString *description = [NSString stringWithFormat:@"aevalsrc=%@:s=48000:d=0.1:c=%@,%@,aformat=sample_fmts=fltp,abuffersink", [signals componentsJoinedByString:@"|"], @(layout), filters];
        AVFilterGraph *graph = avfilter_graph_alloc();
        AVFilterInOut *inputs = NULL, *outputs = NULL;
        int result = avfilter_graph_parse_ptr(graph, description.UTF8String, &inputs, &outputs, NULL);
        avfilter_inout_free(&inputs); avfilter_inout_free(&outputs);
        if (result >= 0) result = avfilter_graph_config(graph, NULL);
        AVFilterContext *sink = NULL;
        for (unsigned i = 0; i < graph->nb_filters; i++)
            if (!strcmp(graph->filters[i]->filter->name, "abuffersink")) sink = graph->filters[i];
        VPAppleSurroundProcessor *apple = [VPAppleSurroundProcessor new];
        AVFrame *frame = av_frame_alloc();
        double energy[8] = {0};
        valid &= result >= 0 && sink;
        while (valid && (result = av_buffersink_get_frame(sink, frame)) >= 0) {
            AVFrame *processed = [@(method) hasPrefix:@"apple_"] ? [apple processFrame:frame layout:@(layout)] : frame;
            valid &= av_channel_layout_compare(&processed->ch_layout, &source) == 0;
            if (valid) for (int c = 0; c < source.nb_channels; c++)
                for (int n = 0; n < processed->nb_samples; n++) {
                    float value = ((float *)processed->data[c])[n];
                    energy[c] += value * value;
                }
            av_frame_unref(frame);
        }
        valid &= result == AVERROR_EOF;
        for (int c = 0; c < source.nb_channels; c++) valid &= c == speaker ? energy[c] > 1 : energy[c] < 1e-8;
        av_frame_free(&frame); avfilter_graph_free(&graph);
        if (!valid) fprintf(stderr, "Authored routing failed: %s %s speaker %d\n", method, layout, speaker);
    }
    av_channel_layout_uninit(&source);
    return valid;
}

bool VPCheckDVDOrder(void) {
    // WG4 test input values identify L,R,side-L,side-R,rear-L,rear-R,C,LFE.
    const int input51[] = {11, 22, 55, 66, 33, 44};
    const int expected51[] = {11, 22, 33, 44, 55, 66};
    const int input71[] = {11, 22, 77, 88, 55, 66, 33, 44};
    const int expected71[] = {11, 22, 33, 44, 55, 66, 77, 88};
    for (unsigned c = 0; c < 6; c++) if (input51[VPVLCChannelIndex(6, c)] != expected51[c]) return false;
    for (unsigned c = 0; c < 8; c++) if (input71[VPVLCChannelIndex(8, c)] != expected71[c]) return false;
    return true;
}

bool VPCheckConvertedSurround(const char *layout) {
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *input = [directory URLByAppendingPathComponent:@"input.wav"];
    NSURL *output = [directory URLByAppendingPathComponent:@"output.wav"];
    NSError *error = nil;
    BOOL valid = [VPFFmpegLibrary renderAudioDemoWithGraph:@"anull" output:input error:&error];
    if (valid) valid = [[VPFFmpegJob new] runInput:input output:output options:@{
        @"audioOnly": @YES, @"audioCodec": @"pcm_f32le", @"audioFilter": @"anull",
        @"appleSurroundLayout": @(layout), @"duration": @1, @"overwrite": @YES
    } error:&error];
    NSDictionary *probe = valid ? [VPFFmpegLibrary probeURL:output error:&error] : nil;
    valid &= [probe[@"streams"][0][@"channels"] intValue] == (!strcmp(layout, "7.1") ? 8 : 6);
    if (!valid) fprintf(stderr, "Converted surround failed: %s %s\n", layout, error.description.UTF8String);
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    return valid;
}

bool VPCheckAudioEnhancementReset(void) {
    VPAIEnhancer *ai = [VPAIEnhancer new];
    [ai applyAudioPreset:@"cinema_restore"];
    bool valid = ai.audioClarity && ai.bassExtension && ai.surroundFill && ai.isAudioAIActive;
    [ai resetAudioAI];
    return valid && !ai.audioClarity && !ai.bassExtension && !ai.surroundFill && !ai.isAudioAIActive;
}

bool VPCheckSurroundFill(const char *inputLayout, const char *outputLayout) {
    VPAppleSurroundProcessor *processor = [VPAppleSurroundProcessor new];
    processor.surroundFill = YES;
    AVFrame *frame = av_frame_alloc();
    frame->format = AV_SAMPLE_FMT_FLTP;
    frame->sample_rate = 48000;
    frame->nb_samples = 8192;
    av_channel_layout_from_string(&frame->ch_layout, inputLayout);
    if (av_frame_get_buffer(frame, 0) < 0) { av_frame_free(&frame); return false; }
    int center = av_channel_layout_index_from_channel(&frame->ch_layout, AV_CHAN_FRONT_CENTER);
    for (int c = 0; c < frame->ch_layout.nb_channels; c++) {
        for (int i = 0; i < frame->nb_samples; i++) {
            ((float *)frame->data[c])[i] = (center < 0 || c == center) ? 0.8f * sinf(2 * M_PI * 500 * i / 48000) : 0;
        }
    }
    AVFrame *output = [processor processFrame:frame layout:@(outputLayout)];
    bool valid = output->ch_layout.nb_channels == (!strcmp(outputLayout, "7.1") ? 8 : 6);
    if (valid) for (int c = 4; c < output->ch_layout.nb_channels; c++) {
        double energy = 0;
        for (int i = 2000; i < output->nb_samples; i++) {
            float value = ((float *)output->data[c])[i];
            valid &= isfinite(value) && fabsf(value) < 1;
            energy += value * value;
        }
        valid &= energy > 0.1;
    }
    // Reset must remove the delayed bed completely.
    [processor reset];
    for (int c = 0; c < frame->ch_layout.nb_channels; c++) memset(frame->data[c], 0, frame->nb_samples * sizeof(float));
    output = [processor processFrame:frame layout:@(outputLayout)];
    for (int c = 0; c < output->ch_layout.nb_channels; c++)
        for (int i = 0; i < output->nb_samples; i++) valid &= ((float *)output->data[c])[i] == 0;
    // Full-scale correlated channels stress the 7.1-to-5.1 downmix headroom.
    [processor reset];
    for (int c = 0; c < frame->ch_layout.nb_channels; c++)
        for (int i = 0; i < frame->nb_samples; i++)
            ((float *)frame->data[c])[i] = sinf(2 * M_PI * 80 * i / 48000);
    output = [processor processFrame:frame layout:@(outputLayout)];
    for (int c = 0; c < output->ch_layout.nb_channels; c++)
        for (int i = 0; i < output->nb_samples; i++) {
            float value = ((float *)output->data[c])[i];
            valid &= isfinite(value) && fabsf(value) <= 1.000001f;
        }
    av_frame_free(&frame);
    return valid;
}

bool VPCheckEncodedSurround(const char *codec) {
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *input = [directory URLByAppendingPathComponent:@"input.wav"];
    NSURL *output = [directory URLByAppendingPathComponent:[@"encoded." stringByAppendingString:@(codec)]];
    NSURL *decoded = [directory URLByAppendingPathComponent:@"decoded.wav"];
    NSError *error = nil;
    BOOL valid = [VPFFmpegLibrary renderAudioDemoWithGraph:@"pan=mono|c0=0.5*c0+0.5*c1" output:input error:&error];
    VPAIEnhancer *ai = [VPAIEnhancer new];
    [ai applyAudioPreset:@"cinema_restore"];
    NSString *graph = [[ai audioFilterGraphString] stringByAppendingString:@",aformat=channel_layouts=5.1,aresample=48000,alimiter=limit=0.95:level=0"];
    if (valid) valid = [[VPFFmpegJob new] runInput:input output:output options:@{
        @"audioOnly": @YES, @"audioCodec": @(codec), @"format": @(codec),
        @"audioBitRate": !strcmp(codec, "ac3") ? @640000 : @1411200,
        @"audioFilter": graph, @"appleSurroundLayout": @"5.1", @"surroundFill": @YES,
        @"duration": @1, @"overwrite": @YES
    } error:&error];
    NSDictionary *probe = valid ? [VPFFmpegLibrary probeURL:output error:&error] : nil;
    valid &= [probe[@"streams"][0][@"channels"] intValue] == 6;
    valid &= [probe[@"streams"][0][@"codec_name"] isEqual:@(codec)];
    if (valid) valid = [[VPFFmpegJob new] runInput:output output:decoded options:@{
        @"audioOnly": @YES, @"audioCodec": @"pcm_f32le", @"overwrite": @YES
    } error:&error];
    AVFormatContext *format = NULL;
    VPInterrupt interrupt = {0};
    int result = valid ? OpenInput(decoded, &format, &interrupt) : -1;
    AVCodecContext *decoder = result >= 0 ? OpenDecoder(format->streams[0], &result) : NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    double rearEnergy[2] = {0};
    valid &= decoder != NULL;
    while (valid && av_read_frame(format, packet) >= 0) {
        valid &= avcodec_send_packet(decoder, packet) >= 0;
        while (valid && avcodec_receive_frame(decoder, frame) >= 0) {
            valid &= frame->format == AV_SAMPLE_FMT_FLT && frame->ch_layout.nb_channels == 6;
            if (valid) for (int i = 0; i < frame->nb_samples; i++) {
                const float *samples = (const float *)frame->data[0] + i * 6;
                for (int c = 0; c < 6; c++) valid &= isfinite(samples[c]) && fabsf(samples[c]) <= 1.01;
                rearEnergy[0] += samples[4] * samples[4];
                rearEnergy[1] += samples[5] * samples[5];
            }
            av_frame_unref(frame);
        }
        av_packet_unref(packet);
    }
    valid &= rearEnergy[0] > 0.01 && rearEnergy[1] > 0.01;
    av_frame_free(&frame); av_packet_free(&packet);
    avcodec_free_context(&decoder); avformat_close_input(&format);
    if (!valid) fprintf(stderr, "Encoded surround failed: %s %s\n", codec, error.description.UTF8String);
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    return valid;
}
