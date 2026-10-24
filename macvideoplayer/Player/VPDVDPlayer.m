//
//  VPDVDPlayer.m
//  macvideoplayer
//

#import "VPDVDPlayer.h"
#import "VPFFmpeg.h"
#import "VPAudioChannelLayout.h"
#import "VPAppleSurroundProcessor.h"
#import "VPAIEnhancer.h"
#import "VPSurroundRouting.h"
#import <vlc/vlc.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

static NSString *const VPDVDErrorDomain = @"macvideoplayerDVD";
enum {
    kVPDVDRingSize = 6,                  // BGRA pictures the engine cycles through
    kVPDVDAudioRate = 48000,
    kVPDVDAudioRingSeconds = 6,          // the engine hands sound over up to a couple of seconds early
    kVPDVDAudioQueueBuffers = 4,
    kVPDVDAudioQueueFrames = 1024        // about 21 ms per pull
};

@interface VPDVDPlayer () {
    libvlc_instance_t *_instance;
    libvlc_media_player_t *_player;

    // Video: the engine draws into these pixel buffers; display hands one to the stage.
    CVPixelBufferRef _ring[kVPDVDRingSize];
    unsigned _ringWidth, _ringHeight, _ringPitch;
    int _ringIndex;

    // Audio. The engine pushes float stereo 48 kHz ahead of time; it runs through the libavfilter graph
    // into a ring buffer, and an AudioQueue pulls from the ring at a steady rate. Playback of the ring
    // starts when the engine's clock reaches the presentation time of the first sample, which keeps the
    // sound in step with the picture without ever scheduling individual buffers.
    os_unfair_lock _audioLock;
    AVFilterGraph *_graph;
    AVFilterContext *_graphSource, *_graphSink;
    SwrContext *_swr;
    AVChannelLayout _swrLayout, _swrOutputLayout;
    enum AVSampleFormat _swrFormat;
    int _swrRate;
    AVFrame *_inputFrame, *_outputFrame;
    int64_t _samplesIn;
    NSString *_graphString;
    BOOL _graphDirty;
    float *_floatScratch;                // the engine's 16-bit stereo chunk converted to float
    size_t _floatScratchFrames;

    float *_audioRing;                   // interleaved frames
    size_t _audioRingFrames, _audioRead, _audioWrite, _audioFill;
    int _audioChannels, _audioRate;
    unsigned _inputChannels, _inputRate;
    AVChannelLayout _inputSpeakerLayout;
    AVChannelLayout _queueLayout;
    int64_t _anchorPTS;                  // engine time of the first sample waiting in the ring, -1 if none
    BOOL _gateOpen;                      // the ring is being played out
    AudioQueueRef _queue;
    AudioQueueBufferRef _queueBuffers[kVPDVDAudioQueueBuffers];
    BOOL _queuePaused;
    float _volume;
    uint64_t _droppedFrames, _underrunFrames, _playedFrames;

    int _lastTitle, _lastChapter;
    BOOL _reportedError;
    BOOL _openedBluRay;                  // the current location is a Blu-ray, so failures may be missing AACS keys
}
@property (nonatomic, strong) VPAppleSurroundProcessor *appleSurroundProcessor;
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, copy) NSString *lastStatus;
@property (nonatomic, readwrite) BOOL inMenu;
// Called from the engine's threads through the C callbacks below.
- (double)sampleAspectRatioForWidth:(unsigned)width height:(unsigned)height;
- (void)prepareRingWidth:(unsigned)width height:(unsigned)height;
- (unsigned)ringPitch;
- (nullable CVPixelBufferRef)nextRingBuffer;
- (void)releaseRing;
- (void)prepareAudioChannels:(unsigned)channels rate:(unsigned)rate;
- (void)processAudioSamples:(const int16_t *)samples frames:(unsigned)frames pts:(int64_t)pts;
- (void)pauseAudio;
- (void)resumeAudio;
- (void)flushAudio;
- (void)fillQueueBuffer:(AudioQueueBufferRef)buffer;
/// Opens any libvlc location; openDiscAtURL: builds the dvdnav location and calls this.
- (BOOL)openLocation:(NSString *)location mediaOptions:(NSArray<NSString *> *)mediaOptions error:(NSError **)error;
/// Counters for tests: frames played, dropped because the ring was full, and silence inserted on underrun.
- (NSDictionary<NSString *, NSNumber *> *)debugStatistics;
@end

#pragma mark - libvlc video callbacks (engine threads)

static unsigned VPDVDVideoSetup(void **opaque, char *chroma, unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines) {
    VPDVDPlayer *player = (__bridge VPDVDPlayer *)*opaque;
    memcpy(chroma, "BGRA", 4);
    // DVD pixels are not square (720 wide for both 4:3 and 16:9). Ask the engine for square pixels so the
    // stage shows the right shape; it scales with the aspect the disc declares for this stream.
    unsigned sourceWidth = *width, sourceHeight = *height;
    double sar = [player sampleAspectRatioForWidth:sourceWidth height:sourceHeight];
    unsigned squareWidth = (unsigned)MAX(2, lround(sourceWidth * sar / 2.0) * 2);
    *width = squareWidth;
    [player prepareRingWidth:squareWidth height:sourceHeight];
    pitches[0] = [player ringPitch];
    lines[0] = sourceHeight;
    return kVPDVDRingSize - 2;
}

static void VPDVDVideoCleanup(void *opaque) {
    VPDVDPlayer *player = (__bridge VPDVDPlayer *)opaque;
    [player releaseRing];
}

static void *VPDVDVideoLock(void *opaque, void **planes) {
    VPDVDPlayer *player = (__bridge VPDVDPlayer *)opaque;
    CVPixelBufferRef buffer = [player nextRingBuffer];
    if (!buffer) { planes[0] = NULL; return NULL; }
    CVPixelBufferLockBaseAddress(buffer, 0);
    planes[0] = CVPixelBufferGetBaseAddress(buffer);
    return buffer;
}

static void VPDVDVideoUnlock(void *opaque, void *picture, void *const *planes) {
    if (picture) CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0);
}

static void VPDVDVideoDisplay(void *opaque, void *picture) {
    VPDVDPlayer *player = (__bridge VPDVDPlayer *)opaque;
    if (!picture) return;
    void (^handler)(CVPixelBufferRef, double) = player.frameHandler;
    if (handler) handler((CVPixelBufferRef)picture, player.currentTime);
}

#pragma mark - libvlc audio callbacks (engine threads)

static int VPDVDAudioSetup(void **data, char *format, unsigned *rate, unsigned *channels) {
    memcpy(format, "S16N", 4);
    if (*channels < 1 || *channels > 8) return -1;
    [(__bridge VPDVDPlayer *)*data prepareAudioChannels:*channels rate:*rate];
    return 0;
}

static void VPDVDAudioPlay(void *data, const void *samples, unsigned count, int64_t pts) {
    [(__bridge VPDVDPlayer *)data processAudioSamples:(const int16_t *)samples frames:count pts:pts];
}
static void VPDVDAudioPause(void *data, int64_t pts) { [(__bridge VPDVDPlayer *)data pauseAudio]; }
static void VPDVDAudioResume(void *data, int64_t pts) { [(__bridge VPDVDPlayer *)data resumeAudio]; }
static void VPDVDAudioFlush(void *data, int64_t pts) { [(__bridge VPDVDPlayer *)data flushAudio]; }

static void VPDVDAudioQueueOutput(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    [(__bridge VPDVDPlayer *)inUserData fillQueueBuffer:inBuffer];
}

@implementation VPDVDPlayer

@synthesize frameHandler = _frameHandler;

- (instancetype)init {
    if ((self = [super init])) {
        _audioLock = OS_UNFAIR_LOCK_INIT;
        _volume = 1;
        _lastTitle = -1;
        _lastChapter = -1;
        _anchorPTS = -1;
        _swrFormat = AV_SAMPLE_FMT_NONE;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:VPDVDErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - AACS (Blu-ray decryption)

+ (NSURL *)aacsKeyDatabaseURL {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/aacs/KEYDB.cfg"];
    return [NSURL fileURLWithPath:path];
}

+ (BOOL)hasAACSKeyDatabase {
    return [NSFileManager.defaultManager fileExistsAtPath:self.aacsKeyDatabaseURL.path];
}

+ (BOOL)installAACSKeyDatabaseAtURL:(NSURL *)source error:(NSError **)error {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *destination = self.aacsKeyDatabaseURL;
    if (![fileManager createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSData *contents = [NSData dataWithContentsOfURL:source options:0 error:error];
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (!contents) return NO;
    return [contents writeToURL:destination options:NSDataWritingAtomic error:error];
}

+ (NSURL *)bdplusDataFolderURL:(NSError **)error {
    NSURL *folder = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/bdplus/vm0"] isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return folder;
}

+ (NSString *)installBDPlusFileAtURL:(NSURL *)source error:(NSError **)error {
    NSString *name = source.lastPathComponent.lowercaseString;
    NSURL *folder = nil;
    if ([name isEqualToString:@"aes_keys.bin"]) {
        folder = [self bdplusDataFolderURL:error];
    } else if ([name isEqualToString:@"slots.bin"]) {
        // libbdplus keeps its persistent slots in the cache folder, not next to the keys.
        folder = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/bdplus"] isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:error]) folder = nil;
    } else {
        if (error) *error = [NSError errorWithDomain:VPDVDErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"“%@” is not a BD+ file this player loads. Choose aes_keys.bin or slots.bin.", source.lastPathComponent]}];
        return nil;
    }
    if (!folder) return nil;
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSData *contents = [NSData dataWithContentsOfURL:source options:0 error:error];
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (!contents) return nil;
    if (contents.length == 0) {
        if (error) *error = [NSError errorWithDomain:VPDVDErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"“%@” is empty.", source.lastPathComponent]}];
        return nil;
    }
    NSString *installedName = name;   // libbdplus looks the files up by their lower-case names
    return [contents writeToURL:[folder URLByAppendingPathComponent:installedName] options:NSDataWritingAtomic error:error] ? installedName : nil;
}

+ (BOOL)isAACSProtectedBluRayAtURL:(NSURL *)discRoot {
    BOOL isDirectory = NO;
    NSString *aacs = [discRoot.path stringByAppendingPathComponent:@"AACS"];
    return [NSFileManager.defaultManager fileExistsAtPath:aacs isDirectory:&isDirectory] && isDirectory;
}

#pragma mark - Opening

- (BOOL)openDiscAtURL:(NSURL *)videoTS error:(NSError **)error {
    NSURLComponents *location = [NSURLComponents new];
    location.scheme = @"dvdnav";
    location.host = @"";
    location.path = videoTS.path;
    return [self openLocation:location.URL.absoluteString mediaOptions:@[@":dvdnav-menu"] error:error];
}

- (BOOL)openBluRayImageAtURL:(NSURL *)image error:(NSError **)error {
    NSURLComponents *location = [NSURLComponents new];
    location.scheme = @"bluray";
    location.host = @"";
    location.path = image.path;
    return [self openLocation:location.URL.absoluteString mediaOptions:@[] error:error];
}

- (BOOL)openLocation:(NSString *)location mediaOptions:(NSArray<NSString *> *)mediaOptions error:(NSError **)error {
    [self stop];
    _reportedError = NO;
    _lastTitle = -1;
    _lastChapter = -1;
    self.lastStatus = nil;

    // The engine's plugins live inside the app; a test harness may point VLC_PLUGIN_PATH elsewhere.
    NSString *plugins = [[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"VLC"] stringByAppendingPathComponent:@"plugins"];
    BOOL pluginsIsDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:plugins isDirectory:&pluginsIsDirectory] && pluginsIsDirectory) {
        setenv("VLC_PLUGIN_PATH", plugins.fileSystemRepresentation, 1);
    } else if (getenv("VLC_PLUGIN_PATH") == NULL) {
        if (error) *error = [self errorWithCode:1 description:@"The DVD playback engine is missing from this copy of the app, so the disc's menus cannot be shown. Rebuild the app to embed the DVD runtime."];
        return NO;
    }

    // libbluray loads libaacs by name at run time to decrypt AACS discs; point it at the copy embedded with the engine.
    _openedBluRay = [location hasPrefix:@"bluray:"];
    NSString *aacs = [[[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"VLC"] stringByAppendingPathComponent:@"lib"] stringByAppendingPathComponent:@"libaacs"];
    if ([NSFileManager.defaultManager fileExistsAtPath:[aacs stringByAppendingString:@".0.dylib"]]) {
        setenv("LIBAACS_PATH", aacs.fileSystemRepresentation, 1);
    }
    // BD+ discs also need libbdplus, loaded the same way.
    NSString *bdplus = [[aacs stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"libbdplus"];
    if ([NSFileManager.defaultManager fileExistsAtPath:[bdplus stringByAppendingString:@".0.dylib"]]) {
        setenv("LIBBDPLUS_PATH", bdplus.fileSystemRepresentation, 1);
    }

    // Subpictures stay on: menu buttons and highlights are subpictures and are blended into the frames
    // the engine hands over. Interlaced DVD material is deinterlaced by the engine when flagged. The
    // engine's own gain stays at unity; the app controls volume on its output.
    const char *arguments[] = {
        "--no-video-title-show", "--no-osd", "--no-snapshot-preview", "--no-sub-autodetect-file",
        "--no-plugins-cache", "--no-media-library", "--no-stats", "--disc-caching=1000",
        "--deinterlace=-1", "--deinterlace-mode=yadif", "--gain=1.0", "--no-volume-save", "--audio-replay-gain-mode=none"
    };
    _instance = libvlc_new((int)(sizeof(arguments) / sizeof(arguments[0])), arguments);
    if (!_instance) {
        if (error) *error = [self errorWithCode:1 description:@"The bundled DVD playback engine could not be initialized."];
        return NO;
    }
    libvlc_set_user_agent(_instance, "macvideoplayer", "macvideoplayer");
    libvlc_set_app_id(_instance, "com.deadendsoftware.macvideoplayer", "1.3", "AppIcon");

    _player = libvlc_media_player_new(_instance);
    if (!_player) {
        [self stop];
        if (error) *error = [self errorWithCode:1 description:@"The bundled DVD playback engine could not create a player."];
        return NO;
    }
    // Frames and sound come to the app; nothing is drawn or played by the engine itself.
    libvlc_video_set_callbacks(_player, VPDVDVideoLock, VPDVDVideoUnlock, VPDVDVideoDisplay, (__bridge void *)self);
    libvlc_video_set_format_callbacks(_player, VPDVDVideoSetup, VPDVDVideoCleanup);
    libvlc_audio_set_callbacks(_player, VPDVDAudioPlay, VPDVDAudioPause, VPDVDAudioResume, VPDVDAudioFlush, NULL, (__bridge void *)self);
    // This engine build's memory output only produces 16-bit integer samples: asked for float it still
    // hands over S16, so the request is made explicit and the samples are converted to float here.
    libvlc_audio_set_format_callbacks(_player, VPDVDAudioSetup, NULL);
    libvlc_audio_set_volume(_player, 100);
    libvlc_video_set_key_input(_player, 0);

    libvlc_media_t *media = libvlc_media_new_location(_instance, location.UTF8String);
    if (!media) {
        [self stop];
        if (error) *error = [self errorWithCode:2 description:@"The DVD location could not be opened by the DVD playback engine."];
        return NO;
    }
    for (NSString *option in mediaOptions) libvlc_media_add_option(media, option.UTF8String);
    libvlc_media_player_set_media(_player, media);
    libvlc_media_release(media);

    if (libvlc_media_player_play(_player) != 0) {
        [self stop];
        if (error) *error = [self errorWithCode:2 description:@"The DVD could not be opened. Check that the disc is still mounted."];
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateStatus];
    }];
    return YES;
}

#pragma mark - Video pictures

- (double)sampleAspectRatioForWidth:(unsigned)width height:(unsigned)height {
    double sar = 0;
    libvlc_media_t *media = _player ? libvlc_media_player_get_media(_player) : NULL;
    if (media) {
        libvlc_media_track_t **tracks = NULL;
        unsigned count = libvlc_media_tracks_get(media, &tracks);
        for (unsigned i = 0; i < count; i++) {
            libvlc_media_track_t *track = tracks[i];
            if (track->i_type != libvlc_track_video || !track->video || track->video->i_sar_num == 0 || track->video->i_sar_den == 0) continue;
            BOOL matches = track->video->i_width == width && track->video->i_height == height;
            if (matches || sar == 0) sar = (double)track->video->i_sar_num / track->video->i_sar_den;
            if (matches) break;
        }
        if (count) libvlc_media_tracks_release(tracks, count);
        libvlc_media_release(media);
    }
    // Standard-definition discs default to 4:3 when the stream does not say.
    if (sar <= 0) sar = (width == 720 && (height == 480 || height == 576)) ? (4.0 * height) / (3.0 * width) : 1.0;
    return sar;
}

- (void)prepareRingWidth:(unsigned)width height:(unsigned)height {
    [self releaseRing];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @64
    };
    for (int i = 0; i < kVPDVDRingSize; i++) {
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &_ring[i]) != kCVReturnSuccess) _ring[i] = NULL;
    }
    _ringWidth = width;
    _ringHeight = height;
    _ringPitch = _ring[0] ? (unsigned)CVPixelBufferGetBytesPerRow(_ring[0]) : width * 4;
    _ringIndex = 0;
}

- (unsigned)ringPitch { return _ringPitch; }

- (CVPixelBufferRef)nextRingBuffer {
    CVPixelBufferRef buffer = _ring[_ringIndex];
    _ringIndex = (_ringIndex + 1) % kVPDVDRingSize;
    return buffer;
}

- (void)releaseRing {
    for (int i = 0; i < kVPDVDRingSize; i++) {
        if (_ring[i]) { CVPixelBufferRelease(_ring[i]); _ring[i] = NULL; }
    }
    _ringWidth = _ringHeight = _ringPitch = 0;
}

#pragma mark - Audio graph

/// Called with `_audioLock` held, on the engine's audio thread.
- (void)rebuildGraphLocked {
    _graphDirty = NO;
    [self tearDownGraphLocked];
    NSString *graph = VPResolvedSurroundGraph(_graphString, &_inputSpeakerLayout);
    if (!graph.length) return;   // plain pass-through

    _graph = avfilter_graph_alloc();
    if (!_graph) return;
    char description[256];
    snprintf(description, sizeof(description), "time_base=1/%u:sample_rate=%u:sample_fmt=flt:channel_layout=%s", _inputRate, _inputRate, VPVLCLayoutName(_inputChannels));
    if (avfilter_graph_create_filter(&_graphSource, avfilter_get_by_name("abuffer"), "in", description, NULL, _graph) < 0 ||
        avfilter_graph_create_filter(&_graphSink, avfilter_get_by_name("abuffersink"), "out", NULL, NULL, _graph) < 0) {
        [self tearDownGraphLocked];
        return;
    }
    AVFilterInOut *outputs = avfilter_inout_alloc(), *inputs = avfilter_inout_alloc();
    outputs->name = av_strdup("in"); outputs->filter_ctx = _graphSource; outputs->pad_idx = 0; outputs->next = NULL;
    inputs->name = av_strdup("out"); inputs->filter_ctx = _graphSink; inputs->pad_idx = 0; inputs->next = NULL;
    int result = avfilter_graph_parse_ptr(_graph, graph.UTF8String, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (result >= 0) result = avfilter_graph_config(_graph, NULL);
    if (result < 0) {
        // A graph that will not configure must not silence the disc: fall back to pass-through.
        [self tearDownGraphLocked];
        return;
    }
    if (!_inputFrame) _inputFrame = av_frame_alloc();
    if (!_outputFrame) _outputFrame = av_frame_alloc();
    _samplesIn = 0;
}

- (void)tearDownGraphLocked {
    if (_graph) avfilter_graph_free(&_graph);
    _graphSource = NULL;
    _graphSink = NULL;
}

- (void)applyAudioFiltersGraph:(NSString *)graphString {
    os_unfair_lock_lock(&_audioLock);
    self.appleSurroundProcessor = nil;
    _graphString = [graphString copy];
    _graphDirty = YES;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)prepareAudioChannels:(unsigned)channels rate:(unsigned)rate {
    os_unfair_lock_lock(&_audioLock);
    _inputChannels = channels;
    _inputRate = rate;
    av_channel_layout_uninit(&_inputSpeakerLayout);
    av_channel_layout_from_string(&_inputSpeakerLayout, VPVLCLayoutName(channels));
    _floatScratchFrames = 0;
    _graphDirty = YES;
    _samplesIn = 0;
    _audioRead = _audioWrite = _audioFill = 0;
    _anchorPTS = -1;
    _gateOpen = NO;
    self.appleSurroundProcessor = nil;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)processAudioSamples:(const int16_t *)pcm frames:(unsigned)frames pts:(int64_t)pts {
    if (!pcm || frames == 0) return;
    os_unfair_lock_lock(&_audioLock);
    // Retain all decoded speakers, converting VLC's WG4 order to FFmpeg's native order.
    if (_floatScratchFrames < frames) {
        free(_floatScratch);
        _floatScratchFrames = MAX((size_t)frames, (size_t)4096);
        _floatScratch = malloc(_floatScratchFrames * _inputChannels * sizeof(float));
    }
    float *samples = _floatScratch;
    if (!samples) { os_unfair_lock_unlock(&_audioLock); return; }
    const float scale = 1.0f / 32768.0f;
    for (size_t i = 0; i < frames; i++) {
        for (unsigned c = 0; c < _inputChannels; c++)
            samples[i * _inputChannels + c] = pcm[i * _inputChannels + VPVLCChannelIndex(_inputChannels, c)] * scale;
    }

    if (_graphDirty) [self rebuildGraphLocked];
    if (!_graph) {
        [self appendInterleaved:samples frames:(int)frames channels:(int)_inputChannels rate:(int)_inputRate pts:pts layout:&_inputSpeakerLayout];
        os_unfair_lock_unlock(&_audioLock);
        return;
    }
    AVFrame *in = _inputFrame;
    in->nb_samples = (int)frames;
    in->format = AV_SAMPLE_FMT_FLT;
    in->sample_rate = (int)_inputRate;
    av_channel_layout_uninit(&in->ch_layout);
    av_channel_layout_copy(&in->ch_layout, &_inputSpeakerLayout);
    in->pts = _samplesIn;
    _samplesIn += frames;
    if (av_frame_get_buffer(in, 0) >= 0) {
        memcpy(in->data[0], samples, (size_t)frames * _inputChannels * sizeof(float));
        int fed = av_buffersrc_add_frame(_graphSource, in);
        (void)fed;   // a frame the graph refuses is simply skipped
    }
    av_frame_unref(in);
    int64_t anchor = pts;
    while (av_buffersink_get_frame(_graphSink, _outputFrame) >= 0) {
        [self convertAndAppendFrame:_outputFrame pts:anchor];
        anchor = -1;
        av_frame_unref(_outputFrame);
    }
    os_unfair_lock_unlock(&_audioLock);
}

/// Converts whatever the graph produced (any layout, planar or packed) to interleaved float and queues it.
- (void)convertAndAppendFrame:(AVFrame *)frame pts:(int64_t)pts {
    if (frame->nb_samples <= 0 || frame->ch_layout.nb_channels <= 0 || frame->sample_rate <= 0) return;
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (ai.audioAIEnabled && ([ai.surroundMethod isEqual:@"apple_51"] || [ai.surroundMethod isEqual:@"apple_71"])) {
        if (!self.appleSurroundProcessor) self.appleSurroundProcessor = [VPAppleSurroundProcessor new];
        self.appleSurroundProcessor.surroundFill = ai.surroundFill;
        frame = [self.appleSurroundProcessor processFrame:frame layout:[ai.surroundMethod isEqual:@"apple_71"] ? @"7.1" : @"5.1"];
    } else {
        self.appleSurroundProcessor = nil;
    }
    AVChannelLayout outputLayout = {0};
    NSString *selectedLayout = self.audioOutputLayout ?: @"auto";
    if ([selectedLayout isEqual:@"auto"] && ai.audioAIEnabled) {
        if ([ai.surroundMethod hasSuffix:@"_51"]) selectedLayout = @"5.1";
        else if ([ai.surroundMethod hasSuffix:@"_71"]) selectedLayout = @"7.1";
    }
    if ([selectedLayout isEqual:@"4.0"]) selectedLayout = @"quad";
    if ([selectedLayout isEqual:@"2.0"]) selectedLayout = @"stereo";
    if ([selectedLayout isEqual:@"auto"] || av_channel_layout_from_string(&outputLayout, selectedLayout.UTF8String) < 0)
        av_channel_layout_copy(&outputLayout, &frame->ch_layout);
    if (!_swr || _swrFormat != frame->format || _swrRate != frame->sample_rate ||
        av_channel_layout_compare(&_swrLayout, &frame->ch_layout) != 0 ||
        av_channel_layout_compare(&_swrOutputLayout, &outputLayout) != 0) {
        swr_free(&_swr);
        av_channel_layout_uninit(&_swrLayout);
        av_channel_layout_copy(&_swrLayout, &frame->ch_layout);
        av_channel_layout_uninit(&_swrOutputLayout);
        av_channel_layout_copy(&_swrOutputLayout, &outputLayout);
        _swrFormat = frame->format;
        _swrRate = frame->sample_rate;
        if (swr_alloc_set_opts2(&_swr, &_swrOutputLayout, AV_SAMPLE_FMT_FLT, _swrRate, &_swrLayout, _swrFormat, _swrRate, 0, NULL) < 0 || swr_init(_swr) < 0) {
            swr_free(&_swr);
            av_channel_layout_uninit(&outputLayout);
            return;
        }
    }
    int channels = outputLayout.nb_channels;
    av_channel_layout_uninit(&outputLayout);
    float *converted = av_malloc((size_t)frame->nb_samples * channels * sizeof(float));
    if (!converted) return;
    uint8_t *out[1] = {(uint8_t *)converted};
    int produced = swr_convert(_swr, out, frame->nb_samples, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (produced > 0) [self appendInterleaved:converted frames:produced channels:channels rate:frame->sample_rate pts:pts layout:&_swrOutputLayout];
    av_free(converted);
}

#pragma mark - Audio output

/// Called with `_audioLock` held. Creates the ring and the pulling queue for a channel count and rate.
- (void)ensureOutputChannels:(int)channels rate:(int)rate layout:(const AVChannelLayout *)sourceLayout {
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    const AVChannelLayout *outputLayout = sourceLayout ?: &stereo;
    if (_queue && _audioChannels == channels && _audioRate == rate &&
        av_channel_layout_compare(&_queueLayout, outputLayout) == 0) return;
    [self disposeOutputLocked];
    av_channel_layout_copy(&_queueLayout, outputLayout);
    _audioChannels = channels;
    _audioRate = rate;
    _audioRingFrames = (size_t)rate * kVPDVDAudioRingSeconds;
    _audioRing = calloc(_audioRingFrames * channels, sizeof(float));
    _audioRead = _audioWrite = _audioFill = 0;
    _anchorPTS = -1;
    _gateOpen = NO;

    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = channels * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    if (AudioQueueNewOutput(&format, VPDVDAudioQueueOutput, (__bridge void *)self, NULL, NULL, 0, &_queue) != noErr) { _queue = NULL; return; }
    VPSetAudioQueueChannelLayout(_queue, &_queueLayout);
    AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, _volume);
    // Prime the queue with silence; from here on it keeps pulling from the ring.
    UInt32 bytes = kVPDVDAudioQueueFrames * channels * sizeof(float);
    for (int i = 0; i < kVPDVDAudioQueueBuffers; i++) {
        if (AudioQueueAllocateBuffer(_queue, bytes, &_queueBuffers[i]) != noErr) { _queueBuffers[i] = NULL; continue; }
        memset(_queueBuffers[i]->mAudioData, 0, bytes);
        _queueBuffers[i]->mAudioDataByteSize = bytes;
        AudioQueueEnqueueBuffer(_queue, _queueBuffers[i], 0, NULL);
    }
    _queuePaused = NO;
    AudioQueueStart(_queue, NULL);
}

/// Called with `_audioLock` held.
- (void)disposeOutputLocked {
    if (_queue) {
        AudioQueueRef oldQueue = _queue;
        _queue = NULL;
        // A synchronous stop waits for callbacks, which also take _audioLock.
        // Mark the queue inactive and release the lock so they can finish.
        os_unfair_lock_unlock(&_audioLock);
        AudioQueueStop(oldQueue, true);
        AudioQueueDispose(oldQueue, true);
        os_unfair_lock_lock(&_audioLock);
    }
    for (int i = 0; i < kVPDVDAudioQueueBuffers; i++) _queueBuffers[i] = NULL;
    av_channel_layout_uninit(&_queueLayout);
    free(_audioRing);
    _audioRing = NULL;
    _audioRingFrames = _audioRead = _audioWrite = _audioFill = 0;
    _anchorPTS = -1;
    _gateOpen = NO;
}

/// Called with `_audioLock` held. Appends played-out samples to the ring; the first sample after a start
/// or flush records the engine time at which the ring should begin playing.
- (void)appendInterleaved:(const float *)data frames:(int)frames channels:(int)channels rate:(int)rate pts:(int64_t)pts layout:(const AVChannelLayout *)layout {
    [self ensureOutputChannels:channels rate:rate layout:layout];
    if (!_queue || !_audioRing || frames <= 0) return;
    void (^tap)(const float *, NSUInteger, NSUInteger) = self.audioSamplesHandler;
    if (tap) tap(data, (NSUInteger)frames, (NSUInteger)channels);
    if (_anchorPTS < 0 && _audioFill == 0 && pts > 0) _anchorPTS = pts;
    size_t room = _audioRingFrames - _audioFill;
    if ((size_t)frames > room) {
        // The engine is further ahead than the ring holds; keep the oldest sound, drop the excess.
        _droppedFrames += (size_t)frames - room;
        frames = (int)room;
    }
    size_t first = MIN((size_t)frames, _audioRingFrames - _audioWrite);
    memcpy(_audioRing + _audioWrite * channels, data, first * channels * sizeof(float));
    if ((size_t)frames > first) memcpy(_audioRing, data + first * channels, ((size_t)frames - first) * channels * sizeof(float));
    _audioWrite = (_audioWrite + frames) % _audioRingFrames;
    _audioFill += frames;
}

/// AudioQueue pull (its own thread): silence until the ring's first sample is due, then the ring's content.
- (void)fillQueueBuffer:(AudioQueueBufferRef)buffer {
    os_unfair_lock_lock(&_audioLock);
    if (!_queue) { os_unfair_lock_unlock(&_audioLock); return; }
    int channels = _audioChannels;
    size_t frames = buffer->mAudioDataBytesCapacity / (channels * sizeof(float));
    float *out = buffer->mAudioData;
    size_t copied = 0;
    if (!_gateOpen && _anchorPTS > 0 && _audioFill > 0) {
        int64_t wait = _anchorPTS - libvlc_clock();
        // Open once the first sample is due within half a pull; later than that only costs a few ms.
        if (wait <= (int64_t)(frames * 500000 / _audioRate)) _gateOpen = YES;
    }
    if (_gateOpen) {
        copied = MIN(frames, _audioFill);
        size_t first = MIN(copied, _audioRingFrames - _audioRead);
        memcpy(out, _audioRing + _audioRead * channels, first * channels * sizeof(float));
        if (copied > first) memcpy(out + first * channels, _audioRing, (copied - first) * channels * sizeof(float));
        _audioRead = (_audioRead + copied) % _audioRingFrames;
        _audioFill -= copied;
        _playedFrames += copied;
        if (copied < frames && !_queuePaused) _underrunFrames += frames - copied;
        if (_audioFill == 0) _anchorPTS = -1;   // the next sample to arrive re-anchors the timeline
    }
    if (copied < frames) memset(out + copied * channels, 0, (frames - copied) * channels * sizeof(float));
    buffer->mAudioDataByteSize = (UInt32)(frames * channels * sizeof(float));
    AudioQueueEnqueueBuffer(_queue, buffer, 0, NULL);
    os_unfair_lock_unlock(&_audioLock);
}

- (void)pauseAudio {
    os_unfair_lock_lock(&_audioLock);
    if (_queue) AudioQueuePause(_queue);
    _queuePaused = YES;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)resumeAudio {
    os_unfair_lock_lock(&_audioLock);
    if (_queue) AudioQueueStart(_queue, NULL);
    _queuePaused = NO;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)flushAudio {
    os_unfair_lock_lock(&_audioLock);
    self.appleSurroundProcessor = nil;
    _audioRead = _audioWrite = _audioFill = 0;   // sound not yet played belongs to before the jump
    _anchorPTS = -1;
    _gateOpen = NO;
    if (_graph) _graphDirty = YES;               // start the filters from silence after a jump
    os_unfair_lock_unlock(&_audioLock);
}

- (void)setVolume:(float)volume {
    _volume = MAX(0, MIN(1, volume));
    os_unfair_lock_lock(&_audioLock);
    if (_queue) AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, _volume);
    os_unfair_lock_unlock(&_audioLock);
}

- (float)volume { return _volume; }

- (NSDictionary<NSString *, NSNumber *> *)debugStatistics {
    os_unfair_lock_lock(&_audioLock);
    NSDictionary *stats = @{@"played": @(_playedFrames), @"dropped": @(_droppedFrames), @"underrun": @(_underrunFrames),
                            @"buffered": @(_audioFill), @"channels": @(_audioChannels), @"rate": @(_audioRate)};
    os_unfair_lock_unlock(&_audioLock);
    return stats;
}

#pragma mark - State

- (BOOL)isPlaying { return _player && libvlc_media_player_is_playing(_player); }
- (double)currentTime { return _player ? MAX(0, libvlc_media_player_get_time(_player)) / 1000.0 : 0; }
- (double)duration {
    if (!_player || self.inMenu) return 0;
    libvlc_time_t length = libvlc_media_player_get_length(_player);
    return length > 0 ? length / 1000.0 : 0;
}

- (void)updateStatus {
    if (!_player) return;
    libvlc_state_t state = libvlc_media_player_get_state(_player);
    NSString *status = nil;
    if (state == libvlc_Error) {
        [self.statusTimer invalidate];
        self.statusTimer = nil;
        status = @"DVD playback failed";
        if (!_reportedError && self.errorHandler) {
            _reportedError = YES;
            NSString *failure = nil;
            if (_openedBluRay) {
                failure = [VPDVDPlayer hasAACSKeyDatabase]
                    ? @"The Blu-ray could not be decrypted or read. Its keys may be missing from your KEYDB.cfg, a BD+ disc may need data in the BD+ folder (File ▸ Show BD+ Data Folder), or the disc may be damaged."
                    : @"The Blu-ray could not be read. Protected discs need a key database: choose File ▸ Install AACS Key Database…, select your KEYDB.cfg, then reopen the disc.";
            }
            self.errorHandler([self errorWithCode:3 description:failure ?: @"The DVD engine could not read this disc. Encrypted discs and damaged discs cannot be played; check the disc and drive, then reopen it."]);
        }
    } else if (state == libvlc_Ended || state == libvlc_Stopped) {
        status = @"The disc has finished · DVD Menu starts it again";
    } else if (state == libvlc_Opening || state == libvlc_Buffering || state == libvlc_NothingSpecial) {
        status = @"Loading DVD…";
    } else {
        int title = libvlc_media_player_get_title(_player);
        int chapter = libvlc_media_player_get_chapter(_player);
        self.inMenu = title <= 0;
        if (title <= 0) status = @"DVD Menu · arrows and Return, or the DVD bar";
        else status = chapter > 0 ? [NSString stringWithFormat:@"Title %d · Chapter %d", title, chapter] : [NSString stringWithFormat:@"Title %d", title];
    }
    if (status && ![status isEqualToString:self.lastStatus]) {
        self.lastStatus = status;
        if (self.statusHandler) self.statusHandler(status);
    } else if (self.statusHandler && status) {
        self.statusHandler(@"");   // a tick without change still lets the window refresh the DVD bar
    }
}

#pragma mark - Controls

- (void)showDiscMenu {
    if (!_player) return;
    libvlc_state_t state = libvlc_media_player_get_state(_player);
    if (state == libvlc_Ended || state == libvlc_Stopped || state == libvlc_Error) {
        _reportedError = NO;
        libvlc_media_player_play(_player);
        return;
    }
    libvlc_media_player_set_pause(_player, 0);
    libvlc_media_player_set_title(_player, 0);   // title 0 is the navigation VM's menu domain
}

- (void)navigate:(VPDVDNavigation)direction {
    if (!_player) return;
    static const libvlc_navigate_mode_t modes[] = {libvlc_navigate_activate, libvlc_navigate_up, libvlc_navigate_down, libvlc_navigate_left, libvlc_navigate_right};
    if (direction < 0 || direction > VPDVDNavigationRight) return;
    libvlc_media_player_navigate(_player, modes[direction]);
}

- (NSArray<NSDictionary *> *)tracksFromDescriptions:(libvlc_track_description_t *)list skipDisabled:(BOOL)skipDisabled {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (libvlc_track_description_t *track = list; track; track = track->p_next) {
        if (skipDisabled && track->i_id < 0) continue;
        NSString *name = track->psz_name ? [NSString stringWithUTF8String:track->psz_name] : nil;
        if (!name.length) name = track->i_id < 0 ? @"Off" : [NSString stringWithFormat:@"Track %d", track->i_id];
        if (track->i_id < 0) name = @"Off";
        [result addObject:@{@"id": @(track->i_id), @"name": name}];
    }
    return result;
}

- (NSArray<NSDictionary *> *)audioTracks {
    if (!_player) return @[];
    libvlc_track_description_t *list = libvlc_audio_get_track_description(_player);
    NSArray *tracks = [self tracksFromDescriptions:list skipDisabled:YES];
    if (list) libvlc_track_description_list_release(list);
    return tracks;
}

- (NSArray<NSDictionary *> *)subtitleTracks {
    if (!_player) return @[];
    libvlc_track_description_t *list = libvlc_video_get_spu_description(_player);
    NSArray *tracks = [self tracksFromDescriptions:list skipDisabled:NO];
    if (list) libvlc_track_description_list_release(list);
    return tracks;
}

- (NSInteger)selectedAudioTrackID { return _player ? libvlc_audio_get_track(_player) : -1; }
- (NSInteger)selectedSubtitleTrackID { return _player ? libvlc_video_get_spu(_player) : -1; }
- (BOOL)selectAudioTrackID:(NSInteger)trackID { return _player && libvlc_audio_set_track(_player, (int)trackID) == 0; }
- (BOOL)selectSubtitleTrackID:(NSInteger)trackID { return _player && libvlc_video_set_spu(_player, (int)trackID) == 0; }

- (NSArray<NSDictionary *> *)discTitles {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    if (!_player) return result;
    libvlc_title_description_t **titles = NULL;
    int count = libvlc_media_player_get_full_title_descriptions(_player, &titles);
    for (int i = 0; i < count; i++) {
        // Menus and zero-length entries are navigation, not something to "play".
        if ((titles[i]->i_flags & libvlc_title_menu) || titles[i]->i_duration < 5000) continue;
        NSString *name = titles[i]->psz_name ? [NSString stringWithUTF8String:titles[i]->psz_name] : nil;
        [result addObject:@{@"index": @(i), @"name": name.length ? name : [NSString stringWithFormat:@"Title %d", i],
                            @"duration": @(titles[i]->i_duration / 1000.0)}];
    }
    if (titles) libvlc_title_descriptions_release(titles, (unsigned)count);
    return result;
}

- (NSArray<NSDictionary *> *)discChapters {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    int title = _player ? libvlc_media_player_get_title(_player) : -1;
    if (title < 0) return result;
    libvlc_chapter_description_t **chapters = NULL;
    int count = libvlc_media_player_get_full_chapter_descriptions(_player, title, &chapters);
    for (int i = 0; i < count; i++) {
        NSString *name = chapters[i]->psz_name ? [NSString stringWithUTF8String:chapters[i]->psz_name] : nil;
        [result addObject:@{@"index": @(i), @"name": name.length ? name : [NSString stringWithFormat:@"Chapter %d", i + 1],
                            @"start": @(chapters[i]->i_time_offset / 1000.0), @"duration": @(chapters[i]->i_duration / 1000.0)}];
    }
    if (chapters) libvlc_chapter_descriptions_release(chapters, (unsigned)count);
    return result;
}

- (void)selectTitle:(NSInteger)index {
    if (!_player) return;
    libvlc_media_player_set_pause(_player, 0);
    libvlc_media_player_set_title(_player, (int)index);
}

- (void)selectChapter:(NSInteger)index {
    if (_player) libvlc_media_player_set_chapter(_player, (int)index);
}

- (void)nextChapter { if (_player) libvlc_media_player_next_chapter(_player); }
- (void)previousChapter { if (_player) libvlc_media_player_previous_chapter(_player); }

- (void)playMainTitle {
    NSDictionary *longest = nil;
    for (NSDictionary *title in [self discTitles]) {
        if (!longest || [title[@"duration"] doubleValue] > [longest[@"duration"] doubleValue]) longest = title;
    }
    if (longest) [self selectTitle:[longest[@"index"] integerValue]];
}

- (void)togglePlayPause {
    if (!_player) return;
    libvlc_state_t state = libvlc_media_player_get_state(_player);
    if (state == libvlc_Ended || state == libvlc_Stopped) libvlc_media_player_play(_player);
    else libvlc_media_player_pause(_player);
}

- (void)seekToSeconds:(double)seconds {
    if (_player && !self.inMenu && libvlc_media_player_is_seekable(_player))
        libvlc_media_player_set_time(_player, (libvlc_time_t)(MAX(0, seconds) * 1000));
}

- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (!_player || (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption))) return NO;
    switch (event.keyCode) {
        case 123: [self navigate:VPDVDNavigationLeft]; return YES;
        case 124: [self navigate:VPDVDNavigationRight]; return YES;
        case 125: [self navigate:VPDVDNavigationDown]; return YES;
        case 126: [self navigate:VPDVDNavigationUp]; return YES;
        case 36: case 76: [self navigate:VPDVDNavigationActivate]; return YES;   // Return, keypad Enter
        case 53: [self showDiscMenu]; return YES;                                 // Escape
        case 49: [self togglePlayPause]; return YES;                              // Space
        default: return NO;
    }
}

#pragma mark - Teardown

- (void)stop {
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    libvlc_media_player_t *player = _player;
    libvlc_instance_t *instance = _instance;
    _player = NULL;
    _instance = NULL;
    if (player) {
        // Stopping tears down the engine's threads; it is blocking but no longer touches AppKit.
        libvlc_media_player_stop(player);
        libvlc_media_player_release(player);
    }
    if (instance) libvlc_release(instance);
    [self releaseRing];
    os_unfair_lock_lock(&_audioLock);
    [self disposeOutputLocked];
    [self tearDownGraphLocked];
    swr_free(&_swr);
    av_channel_layout_uninit(&_swrLayout);
    av_channel_layout_uninit(&_swrOutputLayout);
    _swrFormat = AV_SAMPLE_FMT_NONE;
    av_channel_layout_uninit(&_inputSpeakerLayout);
    self.appleSurroundProcessor = nil;
    if (_inputFrame) av_frame_free(&_inputFrame);
    if (_outputFrame) av_frame_free(&_outputFrame);
    free(_floatScratch);
    _floatScratch = NULL;
    _floatScratchFrames = 0;
    os_unfair_lock_unlock(&_audioLock);
}

@end
