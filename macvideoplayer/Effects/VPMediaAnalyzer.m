//
//  VPMediaAnalyzer.m
//  macvideoplayer
//

#import "VPMediaAnalyzer.h"
#import "VPAudioFilters.h"
#import "VPMediaProbe.h"
#import "VPFFmpeg.h"
#import <libavutil/pixdesc.h>
#import <AppKit/AppKit.h>
#import <math.h>

static NSString *const kVPMediaProfileCacheKey = @"VPMediaProfilesV1";
static const NSUInteger kVPMediaProfileCacheLimit = 150;
static const double kVPAnalysisBudgetSeconds = 6.0;

#pragma mark - Profile

@implementation VPMediaProfile

+ (NSArray<NSString *> *)persistedKeys {
    return @[@"fingerprint", @"summary", @"hasVideo", @"frameRate", @"interlaced", @"videoCodec", @"bitDepth", @"bitsPerPixel",
             @"meanLuma", @"lumaSpread", @"darkFraction", @"brightFraction", @"saturation", @"colorfulness", @"warmth",
             @"noise", @"sharpness", @"flatness", @"edgeDensity", @"looksAnimated",
             @"hasAudio", @"audioChannels", @"sampleRate", @"audioCodec", @"rmsDB", @"peakDB", @"crestDB", @"spectralTiltDB", @"stereoCorrelation", @"speakerRMS", @"speakerLevels",
             @"denoise", @"lineSharpness", @"clarity", @"microContrast", @"vibrance", @"shadowLift", @"highlightRecovery",
             @"saturationTrim", @"temperatureShift", @"upscale", @"wantsDeinterlace", @"audioGraph",
             @"hueShare", @"colorPop", @"hueGains", @"contrastCurve", @"lineDefinition", @"localContrast", @"flatSmoothing"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _summary = @"";
        _audioGraph = @"";
        _speakerRMS = @{};
        _speakerLevels = @{};
        _upscale = 1.0;
        _hueShare = @[];
        _hueGains = @[];
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (NSString *key in [VPMediaProfile persistedKeys]) {
        id value = [self valueForKey:key];
        if ([value isKindOfClass:NSNumber.class] && !isfinite([value doubleValue])) continue;
        if (value) dict[key] = value;
    }
    dict[@"videoWidth"] = @(self.videoSize.width);
    dict[@"videoHeight"] = @(self.videoSize.height);
    dict[@"savedAt"] = @([NSDate date].timeIntervalSince1970);
    return dict;
}

+ (instancetype)profileWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class] || ![dictionary[@"fingerprint"] isKindOfClass:NSString.class]) return nil;
    VPMediaProfile *profile = [VPMediaProfile new];
    for (NSString *key in [self persistedKeys]) {
        id value = dictionary[key];
        if (value && value != NSNull.null) [profile setValue:value forKey:key];
    }
    profile.videoSize = NSMakeSize([dictionary[@"videoWidth"] doubleValue], [dictionary[@"videoHeight"] doubleValue]);
    if (!profile.summary) profile.summary = @"";
    if (!profile.audioGraph) profile.audioGraph = @"";
    if (!profile.speakerRMS) profile.speakerRMS = @{};
    if (!profile.speakerLevels) profile.speakerLevels = @{};
    if (!profile.hueShare) profile.hueShare = @[];
    if (!profile.hueGains) profile.hueGains = @[];
    return profile;
}

@end

#pragma mark - Time budget

typedef struct { CFAbsoluteTime deadline; } VPAnalysisClock;

static int VPAnalysisInterrupt(void *opaque) {
    return CFAbsoluteTimeGetCurrent() > ((VPAnalysisClock *)opaque)->deadline;
}

static BOOL VPExpired(const VPAnalysisClock *clock) {
    return CFAbsoluteTimeGetCurrent() > clock->deadline;
}

#pragma mark - Picture statistics

typedef struct {
    double luma, spread, dark, bright, noise, sharpness, flatness, edges;
    int frames;
} VPPictureStats;

typedef struct {
    double saturation, warmth, colorfulness;
    double hue[12];       // coloured pixels per hue sector
    int frames;
} VPColorStats;

/// Luma statistics of one full-resolution grey frame. Pixels are sampled on a grid for large frames.
static void VPAccumulateLuma(const uint8_t *gray, int width, int height, int stride, VPPictureStats *stats) {
    if (width < 8 || height < 8) return;
    int step = (width * height > 1280 * 720) ? 2 : 1;
    uint64_t hist[256] = {0};
    double sum = 0, sumSq = 0;
    uint64_t count = 0;
    for (int y = 0; y < height; y += step) {
        const uint8_t *row = gray + (size_t)y * stride;
        for (int x = 0; x < width; x += step) {
            uint8_t v = row[x];
            hist[v]++;
            sum += v;
            sumSq += (double)v * v;
            count++;
        }
    }
    if (!count) return;
    double mean = sum / count;
    double variance = MAX(0, sumSq / count - mean * mean);
    uint64_t dark = 0, bright = 0;
    for (int i = 0; i < 40; i++) dark += hist[i];
    for (int i = 220; i < 256; i++) bright += hist[i];

    // Gradients separate flat area, texture and edges; the residual against the 4-neighbour mean
    // over non-edge pixels estimates noise (for Gaussian noise the mean |residual| is about 0.89 sigma).
    uint64_t flat = 0, edge = 0, inner = 0, residualCount = 0;
    double residualSum = 0, edgeGradient = 0;
    for (int y = 1; y < height - 1; y += step) {
        const uint8_t *row = gray + (size_t)y * stride;
        const uint8_t *up = row - stride, *down = row + stride;
        for (int x = 1; x < width - 1; x += step) {
            int p = row[x];
            int g = abs(row[x + 1] - row[x - 1]) + abs(down[x] - up[x]);
            inner++;
            if (g > 40) {
                edge++;
                edgeGradient += g;
            } else {
                if (g < 6) flat++;
                int neighbours = (row[x - 1] + row[x + 1] + up[x] + down[x] + 2) / 4;
                residualSum += abs(p - neighbours);
                residualCount++;
            }
        }
    }
    if (!inner) return;
    stats->luma += mean / 255.0;
    stats->spread += sqrt(variance) / 255.0;
    stats->dark += (double)dark / count;
    stats->bright += (double)bright / count;
    stats->noise += residualCount ? (residualSum / residualCount) / 0.89 : 0;
    stats->sharpness += edge ? (edgeGradient / edge) / 255.0 : 0;
    stats->flatness += (double)flat / inner;
    stats->edges += (double)edge / inner;
    stats->frames++;
}

/// Colour statistics of a small RGB thumbnail: saturation, red/blue balance and Hasler colourfulness.
static void VPAccumulateColor(const uint8_t *rgb, int width, int height, int stride, VPColorStats *stats) {
    double saturationSum = 0, warmthSum = 0, rgSum = 0, rgSq = 0, ybSum = 0, ybSq = 0;
    uint64_t saturated = 0, n = 0;
    for (int y = 0; y < height; y++) {
        const uint8_t *row = rgb + (size_t)y * stride;
        for (int x = 0; x < width; x++) {
            int r = row[3 * x], g = row[3 * x + 1], b = row[3 * x + 2];
            int mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
            if (mx > 24) { saturationSum += (mx - mn) / (double)mx; saturated++; }
            if (mx > 40 && (mx - mn) * 5 > mx) {   // clearly coloured: count it in its hue sector
                double d = mx - mn, h;
                if (mx == r) h = fmod((g - b) / d + 6.0, 6.0);
                else if (mx == g) h = (b - r) / d + 2.0;
                else h = (r - g) / d + 4.0;
                stats->hue[MIN(11, (int)(h * 2.0))]++;
            }
            warmthSum += (r - b) / 255.0;
            double rg = r - g, yb = 0.5 * (r + g) - b;
            rgSum += rg; rgSq += rg * rg; ybSum += yb; ybSq += yb * yb;
            n++;
        }
    }
    if (!n) return;
    double rgMean = rgSum / n, ybMean = ybSum / n;
    double rgVar = MAX(0, rgSq / n - rgMean * rgMean), ybVar = MAX(0, ybSq / n - ybMean * ybMean);
    stats->saturation += saturated ? saturationSum / saturated : 0;
    stats->warmth += warmthSum / n;
    stats->colorfulness += (sqrt(rgVar + ybVar) + 0.3 * sqrt(rgMean * rgMean + ybMean * ybMean)) / 255.0;
    stats->frames++;
}

#pragma mark - Video sampling

static void VPAnalyzeVideo(AVFormatContext *fmt, VPMediaProfile *profile, VPAnalysisClock *clock) {
    int index = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (index < 0) return;
    AVStream *stream = fmt->streams[index];
    if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) return;   // cover art inside an audio file is not video
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) return;
    AVCodecContext *codec = avcodec_alloc_context3(decoder);
    if (!codec) return;
    avcodec_parameters_to_context(codec, stream->codecpar);
    codec->thread_count = 2;
    codec->skip_frame = AVDISCARD_NONKEY;   // keyframes sit where a seek lands and decode on their own
    if (avcodec_open2(codec, decoder, NULL) < 0) { avcodec_free_context(&codec); return; }

    profile.hasVideo = YES;
    profile.videoCodec = @(avcodec_get_name(codec->codec_id));
    profile.videoSize = NSMakeSize(codec->width, codec->height);
    AVRational rate = av_guess_frame_rate(fmt, stream, NULL);
    profile.frameRate = rate.den > 0 ? av_q2d(rate) : 0;
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(codec->pix_fmt);
    profile.bitDepth = desc ? desc->comp[0].depth : 8;
    profile.interlaced = stream->codecpar->field_order != AV_FIELD_PROGRESSIVE && stream->codecpar->field_order != AV_FIELD_UNKNOWN;
    int64_t bitRate = stream->codecpar->bit_rate > 0 ? stream->codecpar->bit_rate : fmt->bit_rate;
    if (bitRate > 0 && codec->width > 0 && codec->height > 0 && profile.frameRate > 0) {
        profile.bitsPerPixel = (double)bitRate / ((double)codec->width * codec->height * profile.frameRate);
    }

    double duration = fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
    static const double fractions[] = {0.06, 0.2, 0.35, 0.5, 0.65, 0.8, 0.93};
    int samples = duration > 20 ? 7 : (duration > 2 ? 3 : 1);

    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    struct SwsContext *grayScaler = NULL, *colorScaler = NULL;
    int scaledWidth = 0, scaledHeight = 0, grayStride = 0;
    enum AVPixelFormat scaledFormat = AV_PIX_FMT_NONE;
    uint8_t *gray = NULL;
    const int colorWidth = 160, colorHeight = 90, colorStride = colorWidth * 3;
    uint8_t *color = av_malloc((size_t)colorStride * colorHeight);
    VPPictureStats picture = {0};
    VPColorStats colour = {0};

    for (int s = 0; s < samples && !VPExpired(clock); s++) {
        if (duration > 0 && samples > 1) {
            int64_t target = av_rescale_q((int64_t)(fractions[s] * duration * AV_TIME_BASE), AV_TIME_BASE_Q, stream->time_base);
            if (stream->start_time != AV_NOPTS_VALUE) target += stream->start_time;
            av_seek_frame(fmt, index, target, AVSEEK_FLAG_BACKWARD);
        }
        avcodec_flush_buffers(codec);
        BOOL got = NO;
        for (int reads = 0; !got && reads < 600 && !VPExpired(clock); reads++) {
            int ret = av_read_frame(fmt, packet);
            if (ret < 0) {
                avcodec_send_packet(codec, NULL);   // drain what the decoder still holds
            } else if (packet->stream_index != index) {
                av_packet_unref(packet);
                continue;
            } else {
                avcodec_send_packet(codec, packet);
                av_packet_unref(packet);
            }
            while (avcodec_receive_frame(codec, frame) >= 0) {
                if (!got && frame->width > 0 && frame->height > 0) {
                    if (!grayScaler || scaledWidth != frame->width || scaledHeight != frame->height || scaledFormat != frame->format) {
                        sws_freeContext(grayScaler); sws_freeContext(colorScaler); av_free(gray);
                        scaledWidth = frame->width; scaledHeight = frame->height; scaledFormat = frame->format;
                        grayScaler = sws_getContext(scaledWidth, scaledHeight, scaledFormat, scaledWidth, scaledHeight, AV_PIX_FMT_GRAY8, SWS_POINT, NULL, NULL, NULL);
                        colorScaler = sws_getContext(scaledWidth, scaledHeight, scaledFormat, colorWidth, colorHeight, AV_PIX_FMT_RGB24, SWS_AREA, NULL, NULL, NULL);
                        grayStride = FFALIGN(scaledWidth, 32);
                        gray = av_malloc((size_t)grayStride * scaledHeight);
                    }
                    if (grayScaler && gray) {
                        uint8_t *dst[4] = {gray, NULL, NULL, NULL};
                        int strides[4] = {grayStride, 0, 0, 0};
                        sws_scale(grayScaler, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, dst, strides);
                        VPAccumulateLuma(gray, scaledWidth, scaledHeight, grayStride, &picture);
                    }
                    if (colorScaler && color) {
                        uint8_t *dst[4] = {color, NULL, NULL, NULL};
                        int strides[4] = {colorStride, 0, 0, 0};
                        sws_scale(colorScaler, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, dst, strides);
                        VPAccumulateColor(color, colorWidth, colorHeight, colorStride, &colour);
                    }
                    got = YES;
                }
                av_frame_unref(frame);
            }
            if (ret < 0) break;
        }
    }

    if (picture.frames) {
        double n = picture.frames;
        profile.meanLuma = picture.luma / n;
        profile.lumaSpread = picture.spread / n;
        profile.darkFraction = picture.dark / n;
        profile.brightFraction = picture.bright / n;
        profile.noise = picture.noise / n;
        profile.sharpness = picture.sharpness / n;
        profile.flatness = picture.flatness / n;
        profile.edgeDensity = picture.edges / n;
    }
    if (colour.frames) {
        double n = colour.frames;
        profile.saturation = colour.saturation / n;
        profile.warmth = colour.warmth / n;
        profile.colorfulness = colour.colorfulness / n;
        double total = 0;
        for (int i = 0; i < 12; i++) total += colour.hue[i];
        NSMutableArray *share = [NSMutableArray arrayWithCapacity:12];
        for (int i = 0; i < 12; i++) [share addObject:@(total > 0 ? colour.hue[i] / total : 0)];
        profile.hueShare = share;
    }
    // Animation: large flat colour fields with little grain. Crisp line art confirms it, but soft or
    // upscaled cels still count when the picture is overwhelmingly flat and coloured (film grain and
    // real-world texture keep live action well below that flatness).
    BOOL crispCels = profile.flatness > 0.55 && profile.edgeDensity > 0.02 && profile.noise < 2.5 && profile.sharpness > 0.3;
    BOOL softCels = profile.flatness > 0.7 && profile.noise < 2.0 && profile.saturation > 0.25;
    profile.looksAnimated = picture.frames > 0 && (crispCels || softCels);

    sws_freeContext(grayScaler);
    sws_freeContext(colorScaler);
    av_free(gray);
    av_free(color);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
}

#pragma mark - Audio sampling

static void VPAnalyzeAudio(AVFormatContext *fmt, VPMediaProfile *profile, VPAnalysisClock *clock) {
    int index = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (index < 0) return;
    AVStream *stream = fmt->streams[index];
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!decoder) return;
    AVCodecContext *codec = avcodec_alloc_context3(decoder);
    if (!codec) return;
    avcodec_parameters_to_context(codec, stream->codecpar);
    if (avcodec_open2(codec, decoder, NULL) < 0 || codec->sample_rate <= 0) { avcodec_free_context(&codec); return; }

    profile.audioCodec = @(avcodec_get_name(codec->codec_id));
    profile.audioChannels = codec->ch_layout.nb_channels;
    profile.sampleRate = codec->sample_rate;

    double duration = fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
    static const double fractions[] = {0.15, 0.5, 0.85};
    int segments = duration > 30 ? 3 : 1;
    const double segmentSeconds = 2.0;

    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    SwrContext *swr = NULL;
    AVChannelLayout stereo, swrLayout = {0};
    av_channel_layout_default(&stereo, 2);
    enum AVSampleFormat swrFormat = AV_SAMPLE_FMT_NONE;
    int swrRate = 0;
    float *buffer = NULL;
    int bufferCapacity = 0;   // in stereo frames

    double sumSq = 0, sumL2 = 0, sumR2 = 0, sumLR = 0, sumBass2 = 0, sumTreble2 = 0, peak = 0;
    uint64_t count = 0;
    // Per-channel energy in the file's own layout (no downmix), for the automatic speaker levels.
    SwrContext *nativeSwr = NULL;
    AVChannelLayout nativeLayout = {0};
    enum AVSampleFormat nativeFormat = AV_SAMPLE_FMT_NONE;
    int nativeRate = 0, nativeChannels = 0, nativeCapacity = 0;
    float *nativeBuffer = NULL;
    double channelEnergy[16] = {0};
    uint64_t nativeCount = 0;

    for (int s = 0; s < segments && !VPExpired(clock); s++) {
        if (duration > 0 && segments > 1) {
            int64_t target = av_rescale_q((int64_t)(fractions[s] * duration * AV_TIME_BASE), AV_TIME_BASE_Q, stream->time_base);
            if (stream->start_time != AV_NOPTS_VALUE) target += stream->start_time;
            av_seek_frame(fmt, index, target, AVSEEK_FLAG_BACKWARD);
        }
        avcodec_flush_buffers(codec);
        double bass = 0, low = 0;   // one-pole filter states: 200 Hz low-pass (bass) and 4 kHz low-pass (treble = rest)
        uint64_t wanted = (uint64_t)(segmentSeconds * codec->sample_rate), taken = 0;
        for (int reads = 0; taken < wanted && reads < 4000 && !VPExpired(clock); reads++) {
            int ret = av_read_frame(fmt, packet);
            if (ret < 0) {
                avcodec_send_packet(codec, NULL);
            } else if (packet->stream_index != index) {
                av_packet_unref(packet);
                continue;
            } else {
                avcodec_send_packet(codec, packet);
                av_packet_unref(packet);
            }
            while (avcodec_receive_frame(codec, frame) >= 0) {
                if (taken >= wanted || frame->nb_samples <= 0 || frame->sample_rate <= 0) { av_frame_unref(frame); continue; }
                if (!swr || swrFormat != frame->format || swrRate != frame->sample_rate || av_channel_layout_compare(&swrLayout, &frame->ch_layout) != 0) {
                    swr_free(&swr);
                    av_channel_layout_uninit(&swrLayout);
                    av_channel_layout_copy(&swrLayout, &frame->ch_layout);
                    swrFormat = frame->format;
                    swrRate = frame->sample_rate;
                    if (swr_alloc_set_opts2(&swr, &stereo, AV_SAMPLE_FMT_FLT, swrRate, &swrLayout, swrFormat, swrRate, 0, NULL) < 0 || swr_init(swr) < 0) {
                        swr_free(&swr);
                    }
                }
                if (!swr) { av_frame_unref(frame); continue; }
                if (frame->ch_layout.nb_channels >= 3 && frame->ch_layout.nb_channels <= 16) {
                    if (!nativeSwr || nativeFormat != frame->format || nativeRate != frame->sample_rate ||
                        av_channel_layout_compare(&nativeLayout, &frame->ch_layout) != 0) {
                        swr_free(&nativeSwr);
                        av_channel_layout_uninit(&nativeLayout);
                        av_channel_layout_copy(&nativeLayout, &frame->ch_layout);
                        nativeFormat = frame->format; nativeRate = frame->sample_rate; nativeChannels = nativeLayout.nb_channels;
                        if (swr_alloc_set_opts2(&nativeSwr, &nativeLayout, AV_SAMPLE_FMT_FLT, nativeRate, &nativeLayout, nativeFormat, nativeRate, 0, NULL) < 0 || swr_init(nativeSwr) < 0) {
                            swr_free(&nativeSwr);
                        }
                    }
                    int nativeOut = frame->nb_samples + 256;
                    if (nativeSwr && nativeOut > nativeCapacity) {
                        av_free(nativeBuffer);
                        nativeCapacity = nativeOut;
                        nativeBuffer = av_malloc((size_t)nativeCapacity * nativeChannels * sizeof(float));
                    }
                    if (nativeSwr && nativeBuffer) {
                        uint8_t *nativePlanes[1] = {(uint8_t *)nativeBuffer};
                        int got = swr_convert(nativeSwr, nativePlanes, nativeOut, (const uint8_t **)frame->extended_data, frame->nb_samples);
                        for (int i = 0; i < got; i++) {
                            for (int c = 0; c < nativeChannels; c++) {
                                double v = nativeBuffer[(size_t)i * nativeChannels + c];
                                channelEnergy[c] += v * v;
                            }
                        }
                        if (got > 0) nativeCount += got;
                    }
                }
                int outCount = frame->nb_samples + 256;
                if (outCount > bufferCapacity) {
                    av_free(buffer);
                    bufferCapacity = outCount;
                    buffer = av_malloc((size_t)bufferCapacity * 2 * sizeof(float));
                }
                uint8_t *out[1] = {(uint8_t *)buffer};
                int converted = buffer ? swr_convert(swr, out, outCount, (const uint8_t **)frame->extended_data, frame->nb_samples) : 0;
                double aBass = exp(-2.0 * M_PI * 200.0 / frame->sample_rate);
                double aLow = exp(-2.0 * M_PI * 4000.0 / frame->sample_rate);
                for (int i = 0; i < converted; i++) {
                    double l = buffer[2 * i], r = buffer[2 * i + 1];
                    double m = 0.5 * (l + r);
                    bass = aBass * bass + (1 - aBass) * m;
                    low = aLow * low + (1 - aLow) * m;
                    double treble = m - low;
                    sumSq += m * m; sumL2 += l * l; sumR2 += r * r; sumLR += l * r;
                    sumBass2 += bass * bass; sumTreble2 += treble * treble;
                    peak = MAX(peak, MAX(fabs(l), fabs(r)));
                }
                if (converted > 0) { count += converted; taken += converted; }
                av_frame_unref(frame);
            }
            if (ret < 0) break;
        }
    }

    if (count > 0) {
        profile.hasAudio = YES;
        double rms = sqrt(sumSq / count);
        profile.rmsDB = 20.0 * log10(MAX(rms, 1e-6));
        profile.peakDB = 20.0 * log10(MAX(peak, 1e-6));
        profile.crestDB = profile.peakDB - profile.rmsDB;
        profile.spectralTiltDB = 10.0 * log10((sumBass2 + 1e-12) / (sumTreble2 + 1e-12));
        double denominator = sqrt(sumL2 * sumR2);
        profile.stereoCorrelation = denominator > 0 ? MAX(-1, MIN(1, sumLR / denominator)) : 1;
    }

    if (nativeCount > 0 && nativeChannels >= 3) {
        // Average the channels of each speaker group, so a pair counts as one speaker.
        NSMutableDictionary<NSString *, NSNumber *> *energy = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *members = [NSMutableDictionary dictionary];
        for (int c = 0; c < nativeChannels; c++) {
            NSString *group = VPSpeakerGroupForChannelIndex(&nativeLayout, c);
            if (!group) continue;
            energy[group] = @(energy[group].doubleValue + channelEnergy[c] / nativeCount);
            members[group] = @(members[group].intValue + 1);
        }
        NSMutableDictionary<NSString *, NSNumber *> *levels = [NSMutableDictionary dictionary];
        for (NSString *group in energy) levels[group] = @(10.0 * log10(MAX(energy[group].doubleValue / members[group].intValue, 1e-12)));
        profile.speakerRMS = levels;
    }
    av_free(nativeBuffer);
    swr_free(&nativeSwr);
    av_channel_layout_uninit(&nativeLayout);
    av_free(buffer);
    swr_free(&swr);
    av_channel_layout_uninit(&swrLayout);
    av_channel_layout_uninit(&stereo);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
}

#pragma mark - Analyzer

@implementation VPMediaAnalyzer

static double VPClamp(double value, double low, double high) { return MAX(low, MIN(high, value)); }

+ (NSString *)fingerprintForURL:(NSURL *)url {
    if (!url.isFileURL) return url.absoluteString ?: @"";
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    return [NSString stringWithFormat:@"%@|%llu|%.0f", url.path, attributes.fileSize, attributes.fileModificationDate.timeIntervalSince1970];
}

/// Profiles live only for this run of the app: nothing about the AI effects is written to disk.
/// The key under which an earlier build saved them is cleared so no stale profiles linger.
+ (NSMutableDictionary<NSString *, VPMediaProfile *> *)sessionCache {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kVPMediaProfileCacheKey];
    });
    return cache;
}

+ (VPMediaProfile *)cachedProfileForURL:(NSURL *)url {
    if (!url) return nil;
    @synchronized ([self sessionCache]) {
        return [self sessionCache][[self fingerprintForURL:url]];
    }
}

+ (void)storeProfile:(VPMediaProfile *)profile {
    if (!profile.fingerprint.length) return;
    @synchronized ([self sessionCache]) {
        NSMutableDictionary *cache = [self sessionCache];
        if (cache.count >= kVPMediaProfileCacheLimit) [cache removeAllObjects];
        cache[profile.fingerprint] = profile;
    }
}

/// Turns the measurements into enhancement settings. Every rule nudges the picture or sound toward a
/// balanced presentation while keeping what makes the file itself: animation keeps its clean lines and
/// colour, a deliberately dark or warm film is only moderated, grain is cleaned only where it is present.
/// Balances the speaker groups against the front pair: dialogue that is buried in the center comes forward, and
/// surround, side or bass channels that overpower the front are pulled back (or lifted when almost inaudible).
/// Trims stay within a few dB, so the mix keeps the shape the engineers gave it.
static NSDictionary<NSString *, NSNumber *> *VPDeriveSpeakerLevels(NSDictionary<NSString *, NSNumber *> *rms) {
    double front = rms[@"front"] ? rms[@"front"].doubleValue : -200;
    if (front < -60) return @{};
    NSMutableDictionary<NSString *, NSNumber *> *levels = [NSMutableDictionary dictionary];
    void (^set)(NSString *, double) = ^(NSString *group, double db) {
        db = round(MAX(-6.0, MIN(6.0, db)) * 2.0) / 2.0;
        if (fabs(db) >= 0.5) levels[group] = @(db);
    };
    if (rms[@"center"] && rms[@"center"].doubleValue > -60) {
        set(@"center", MAX(0, (front - 3.0) - rms[@"center"].doubleValue));              // keep dialogue within 3 dB of the front
    }
    for (NSString *group in @[@"rear", @"side"]) {
        if (!rms[group] || rms[group].doubleValue < -60) continue;
        double relative = rms[group].doubleValue - front;                               // ambience normally sits 8-12 dB under the front
        if (relative > -4) set(group, -(relative + 9.0) * 0.5);
        else if (relative < -16) set(group, MIN(4.0, (-12.0 - relative) * 0.5));
    }
    if (rms[@"subwoofer"] && rms[@"subwoofer"].doubleValue > -70) {
        double relative = rms[@"subwoofer"].doubleValue - front;                        // the LFE channel is band-limited, so it measures low
        if (relative > -2) set(@"subwoofer", -(relative + 6.0) * 0.5);
        else if (relative < -22) set(@"subwoofer", MIN(3.0, (-16.0 - relative) * 0.5));
    }
    return levels;
}

+ (void)deriveSettingsForProfile:(VPMediaProfile *)p screenHeight:(double)screenHeight {
    p.speakerLevels = VPDeriveSpeakerLevels(p.speakerRMS);
    NSMutableArray<NSString *> *notes = [NSMutableArray array];

    if (p.hasVideo) {
        BOOL efficientCodec = [@[@"hevc", @"av1", @"vp9"] containsObject:p.videoCodec ?: @""];
        BOOL heavyCompression = p.bitsPerPixel > 0 && p.bitsPerPixel < (efficientCodec ? 0.04 : 0.08);
        double noiseLevel = VPClamp((p.noise - 1.0) / 5.0, 0, 1);          // sigma 1 is clean, sigma 6 is heavy grain
        double softness = VPClamp((0.45 - p.sharpness) / 0.35, 0, 1);      // mean edge gradient; 0.45 is crisp

        double denoise = noiseLevel * 0.85 + (heavyCompression ? 0.15 : 0);
        if (p.looksAnimated) denoise *= 0.6;
        if (p.bitDepth >= 10) denoise *= 0.8;
        p.denoise = VPClamp(denoise, 0, 1);

        double detailScale = 1.0 - 0.5 * noiseLevel;   // never sharpen grain
        p.lineSharpness = VPClamp((p.looksAnimated ? 0.25 + 0.45 * softness : 0.15 + 0.5 * softness) * detailScale, 0, 1);
        p.clarity = VPClamp((p.looksAnimated ? 0.2 + 0.2 * softness : 0.15 + 0.35 * softness) * detailScale, 0, 1);

        p.microContrast = p.lumaSpread < 0.16 ? 0.55 : (p.lumaSpread < 0.22 ? 0.35 : 0.15);

        // The file's own "stencil": every number below comes from this file's measurements, so a flat-coloured cartoon
        // and a grainy concert film end up with different colour, line, contrast and smoothing treatments.
        double mutedness = VPClamp((0.45 - p.saturation) / 0.35, 0, 1);       // 1 = washed out, 0 = already rich
        double lowContrast = VPClamp((0.26 - p.lumaSpread) / 0.14, 0, 1);     // 1 = flat tonal range
        double grain = VPClamp((p.noise - 1.0) / 4.0, 0, 1);
        p.colorPop = VPClamp((p.looksAnimated ? 0.60 : 0.40) + 0.35 * mutedness - (p.saturation > 0.5 ? 0.15 : 0), 0, 0.95);
        p.contrastCurve = VPClamp(0.30 + 0.45 * lowContrast - (p.darkFraction > 0.5 ? 0.15 : 0), 0.15, 0.85);
        p.localContrast = VPClamp((p.looksAnimated ? 0.30 : 0.50) + 0.4 * lowContrast - 0.3 * grain, 0.15, 0.9);
        // Ink lines of animation are strengthened hardest; in live action only real edges are firmed up.
        p.lineDefinition = VPClamp((p.looksAnimated ? 0.55 + 0.35 * softness : 0.18 + 0.30 * softness + 3.0 * p.edgeDensity) * (1.0 - 0.5 * grain), 0, 0.95);
        // Flat colour areas of animation (and its compression mosquito noise) are cleaned and made even.
        p.flatSmoothing = p.looksAnimated ? VPClamp(0.35 + 0.5 * grain + (heavyCompression ? 0.2 : 0), 0, 0.9) : 0;
        NSMutableArray *gains = [NSMutableArray arrayWithCapacity:12];
        for (int i = 0; i < 12; i++) {
            double share = i < (int)p.hueShare.count ? [p.hueShare[i] doubleValue] : 0;
            double gain = 0.2;                                  // every hue gets a little lift
            if (share > 0.28) gain = 0.05;                      // a hue that fills the picture is kept from going neon
            else if (share > 0.03) gain = 0.35 + 0.4 * (0.28 - share) / 0.25;   // accent colours are what should pop
            if (i == 1) gain *= 0.5;                            // orange sector: skin tones stay natural
            [gains addObject:@(VPClamp(gain, -0.5, 0.9))];
        }
        p.hueGains = gains;
        // Stronger overall picture work than before: the point of the adaptive look is that it is noticeable.
        p.lineSharpness = VPClamp(p.lineSharpness * 1.35 + 0.1, 0, 1);
        p.clarity = VPClamp(p.clarity * 1.35 + 0.1, 0, 1);
        p.microContrast = VPClamp(p.microContrast * 1.3, 0, 1);
        p.shadowLift = p.darkFraction > 0.5 ? 0.45 : (p.darkFraction > 0.35 ? 0.25 : 0);
        p.highlightRecovery = p.brightFraction > 0.12 ? 0.4 : (p.brightFraction > 0.06 ? 0.2 : 0);

        double vibrance = p.saturation < 0.18 ? 0.5 : (p.saturation < 0.28 ? 0.3 : (p.saturation < 0.4 ? 0.15 : 0.05));
        if (p.looksAnimated) vibrance *= 0.7;
        p.vibrance = VPClamp(vibrance * 1.6 + 0.2, 0, 1);
        double trim = p.saturation > 0.5 ? -0.12 : (p.saturation > 0.42 ? -0.06 : 0);
        p.saturationTrim = p.looksAnimated ? trim * 0.5 : trim;
        p.temperatureShift = fabs(p.warmth) > 0.1 ? VPClamp(-p.warmth * 0.4, -0.3, 0.3) : 0;   // moderate a cast, keep the look

        double height = p.videoSize.height, width = p.videoSize.width, upscale = 1.0;
        if (height > 0) {
            if (height <= 600) upscale = 2.0;
            else if (height <= 800) upscale = screenHeight >= 1400 ? 1.5 : 1.0;
            else if (height <= 1100) upscale = screenHeight >= 2000 ? 1.5 : 1.0;
        }
        if (width * upscale > 8192 || height * upscale > 8192) upscale = 1.0;
        p.upscale = upscale;
        p.wantsDeinterlace = p.interlaced;

        [notes addObject:p.looksAnimated ? @"animation" : @"live action"];
        if (p.darkFraction > 0.35) [notes addObject:@"dark scenes"];
        else if (p.meanLuma > 0.6) [notes addObject:@"bright picture"];
        if (fabs(p.warmth) > 0.1) [notes addObject:p.warmth > 0 ? @"warm tones" : @"cool tones"];
        if (p.saturation < 0.18) [notes addObject:@"muted colour"];
        else if (p.saturation > 0.42) [notes addObject:@"vivid colour"];
        if (p.noise > 3) [notes addObject:@"grainy"];
        if (p.sharpness < 0.3) [notes addObject:@"soft detail"];
        if (heavyCompression) [notes addObject:@"heavy compression"];
        [notes addObject:[NSString stringWithFormat:@"colour pop %.0f%%", p.colorPop * 100]];
        if (p.looksAnimated) [notes addObject:@"ink lines firmed"];
        if (upscale > 1.01) [notes addObject:[NSString stringWithFormat:@"%.2g× upscale", upscale]];
        if (p.wantsDeinterlace) [notes addObject:@"deinterlaced"];
    }

    if (p.hasAudio) {
        NSMutableArray<NSString *> *filters = [NSMutableArray array];
        // Very dynamic, quiet mixes get gentle levelling first, pitched 10 dB above their own average,
        // so dialogue stays audible without the peaks ever being pumped by the final limiter.
        BOOL wideDynamics = p.crestDB > 20 && p.rmsDB < -24;
        if (wideDynamics) {
            [filters addObject:[NSString stringWithFormat:@"acompressor=threshold=%.0fdB:ratio=2:attack=25:release=300:makeup=1", VPClamp(p.rmsDB + 10, -40, -10)]];
        }

        // Level: aim for about -18 dBFS average, never pushing the peaks past -1 dBFS.
        double gain = -18.0 - p.rmsDB;
        gain = MIN(gain, -1.0 - p.peakDB);
        gain = VPClamp(gain, -8.0, 10.0);
        if (fabs(gain) >= 0.5) [filters addObject:[NSString stringWithFormat:@"volume=%.1fdB", gain]];

        // Tonal balance: bass (below 200 Hz) over treble (above 4 kHz) energy. Speech-led mixes sit near
        // 0 to 8 dB, music 8 to 16 dB; only a real imbalance is nudged part of the way back.
        double bassGain = 0, trebleGain = 0;
        if (p.spectralTiltDB > 18) {
            trebleGain = MIN(4.0, (p.spectralTiltDB - 18) * 0.35);
            bassGain = -MIN(2.0, (p.spectralTiltDB - 18) * 0.12);
        } else if (p.spectralTiltDB < 0) {
            bassGain = MIN(4.0, -p.spectralTiltDB * 0.5);
            trebleGain = -MIN(1.5, -p.spectralTiltDB * 0.15);
        }
        if (fabs(bassGain) >= 0.5) [filters addObject:[NSString stringWithFormat:@"bass=g=%.1f:f=110:w=0.6", bassGain]];
        if (fabs(trebleGain) >= 0.5) [filters addObject:[NSString stringWithFormat:@"treble=g=%.1f:f=7000:w=0.6", trebleGain]];

        // A stereo track that is nearly mono gets a little width; identical channels have nothing to widen.
        BOOL nearMono = p.audioChannels == 2 && p.stereoCorrelation > 0.97 && p.stereoCorrelation < 0.995;
        if (nearMono) [filters addObject:@"extrastereo=m=1.25"];
        p.audioGraph = [filters componentsJoinedByString:@","];

        if (p.rmsDB < -26) [notes addObject:@"quiet mix"];
        else if (p.rmsDB > -14) [notes addObject:@"loud mix"];
        if (p.spectralTiltDB > 18) [notes addObject:@"dull sound"];
        else if (p.spectralTiltDB < 0) [notes addObject:@"thin sound"];
        if (wideDynamics) [notes addObject:@"wide dynamics"];
        if (nearMono) [notes addObject:@"near-mono"];
        if (p.audioChannels >= 6) [notes addObject:@"surround source"];
    }

    p.summary = [notes componentsJoinedByString:@" · "];
}

+ (VPMediaProfile *)analyzeSynchronously:(NSURL *)url probe:(VPMediaProbe *)probe screenHeight:(double)screenHeight {
    VPAnalysisClock clock = { CFAbsoluteTimeGetCurrent() + kVPAnalysisBudgetSeconds };
    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) return nil;
    fmt->interrupt_callback.callback = VPAnalysisInterrupt;
    fmt->interrupt_callback.opaque = &clock;
    const char *location = url.isFileURL ? url.path.fileSystemRepresentation : url.absoluteString.UTF8String;
    AVDictionary *options = NULL;
    // The disc playlists the app writes are concat files with absolute paths, which the demuxer only
    // accepts in unsafe mode.
    if ([url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) av_dict_set(&options, "safe", "0", 0);
    int opened = avformat_open_input(&fmt, location, NULL, &options);
    av_dict_free(&options);
    if (opened < 0) return nil;
    if (avformat_find_stream_info(fmt, NULL) < 0) { avformat_close_input(&fmt); return nil; }

    VPMediaProfile *profile = [VPMediaProfile new];
    profile.fingerprint = [self fingerprintForURL:url];
    VPAnalyzeVideo(fmt, profile, &clock);
    VPAnalyzeAudio(fmt, profile, &clock);
    avformat_close_input(&fmt);
    if (!profile.hasVideo && !profile.hasAudio) return nil;
    if (probe.isInterlaced) profile.interlaced = YES;
    [self deriveSettingsForProfile:profile screenHeight:screenHeight];
    return profile;
}

+ (void)analyzeURL:(NSURL *)url probe:(VPMediaProbe *)probe completion:(void (^)(VPMediaProfile *))completion {
    NSScreen *screen = NSScreen.mainScreen;
    double screenHeight = screen ? screen.frame.size.height * screen.backingScaleFactor : 2160;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.deadendsoftware.macvideoplayer.media-analyzer", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    dispatch_async(queue, ^{
        VPMediaProfile *profile = [self analyzeSynchronously:url probe:probe screenHeight:screenHeight];
        if (profile) [self storeProfile:profile];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(profile); });
    });
}

@end
