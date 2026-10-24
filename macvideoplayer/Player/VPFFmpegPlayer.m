//
//  VPFFmpegPlayer.m
//  macvideoplayer
//

#import "VPFFmpegPlayer.h"
#import "VPAudioSync.h"
#import "VPDVDNavigation.h"
#import "VPFFmpeg.h"
#import "VPAudioChannelLayout.h"
#import "VPAppleSurroundProcessor.h"
#import "VPAIEnhancer.h"
#import "VPAudioFilters.h"
#import "VPAudioDeviceManager.h"
#import "VPSurroundRouting.h"
#import "VPFFmpegSourceDatabase.h"
#import "VPDiscSupport.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import <CoreVideo/CVDisplayLink.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <pthread.h>
#import <fcntl.h>
#import <unistd.h>

#define AUDIO_BUFFER_COUNT 8
#define AUDIO_BUFFER_SIZE 65536
#define MAX_QUEUED_VIDEO_FRAMES 120
/// How much streamed audio is buffered before playback starts and after it runs dry.
static const double kNetworkPrerollSeconds = 3.0;
#define MAX_QUEUED_AUDIO_SECONDS 8.0
#define DISC_READAHEAD_CACHE_SIZE (2 * 1024 * 1024)

typedef struct {
    int count;
    int *fds;
    int64_t *sizes;
    int64_t *offsets;
    int64_t totalSize;
    int64_t physicalSize;
    VPDVDCellRange *dvdCells;
    size_t dvdCellCount;
    int64_t dvdNextPhysicalByte;
    bool dvdSelected;
    int64_t pos;
    int currentIdx;
    uint8_t *cacheBuf;
    int64_t cacheStart;
    int64_t cacheLen;
    size_t cacheCapacity;
} VPMultiFileIOContext;

static ssize_t RawPhysicalReadAt(VPMultiFileIOContext *ctx, int64_t pos, uint8_t *buf, size_t len) {
    if (!ctx || pos >= ctx->physicalSize || len == 0) return 0;
    size_t totalRead = 0;
    int64_t curPos = pos;
    while (totalRead < len && curPos < ctx->physicalSize) {
        int idx = ctx->currentIdx;
        if (idx < 0 || idx >= ctx->count || curPos < ctx->offsets[idx] || curPos >= ctx->offsets[idx] + ctx->sizes[idx]) {
            idx = 0;
            for (int i = 0; i < ctx->count; i++) {
                if (curPos >= ctx->offsets[i] && curPos < ctx->offsets[i] + ctx->sizes[i]) {
                    idx = i;
                    break;
                }
            }
            ctx->currentIdx = idx;
        }
        int64_t localOffset = curPos - ctx->offsets[idx];
        int64_t availInFile = ctx->sizes[idx] - localOffset;
        size_t toRead = (size_t)MIN((int64_t)(len - totalRead), availInFile);
        ssize_t n = pread(ctx->fds[idx], buf + totalRead, toRead, (off_t)localOffset);
        if (n <= 0) break;
        totalRead += (size_t)n;
        curPos += n;
        if (curPos >= ctx->offsets[idx] + ctx->sizes[idx] && idx + 1 < ctx->count) {
            ctx->currentIdx = idx + 1;
        }
    }
    return (ssize_t)totalRead;
}

// Project the selected PGC's cells onto one seekable stream. Within an
// interleaved angle block, NAV identity selects only angle 1's VOBUs.
static ssize_t RawMultiFileReadAt(VPMultiFileIOContext *ctx, int64_t pos, uint8_t *buf, size_t len) {
    if (!ctx->dvdCellCount) return RawPhysicalReadAt(ctx, pos, buf, len);
    size_t copied = 0;
    while (copied < len && pos < ctx->totalSize) {
        const VPDVDCellRange *range = NULL;
        for (size_t i = 0; i < ctx->dvdCellCount; i++) {
            const VPDVDCellRange *candidate = &ctx->dvdCells[i];
            if (pos >= candidate->logicalStart && pos < candidate->logicalStart + candidate->length) {
                range = candidate;
                break;
            }
        }
        if (!range) return copied ? (ssize_t)copied : AVERROR_INVALIDDATA;
        int64_t offset = pos - range->logicalStart;
        size_t amount = (size_t)MIN((int64_t)(len - copied), range->length - offset);
        int64_t physical = range->physicalStart + offset;
        // Every cache fill is sector aligned. After a seek, suppress partial
        // VOBUs until the next NAV pack establishes the angle identity.
        if (physical != ctx->dvdNextPhysicalByte || offset == 0) ctx->dvdSelected = false;
        ssize_t read = RawPhysicalReadAt(ctx, physical, buf + copied, amount);
        if (read <= 0) return copied ? (ssize_t)copied : read;
        if ((read % 2048) != 0) return AVERROR_INVALIDDATA;
        for (ssize_t i = 0; i < read; i += 2048) {
            VPDVDFilterSector(buf + copied + i, range->vob, range->cell, &ctx->dvdSelected);
        }
        ctx->dvdNextPhysicalByte = physical + read;
        pos += read;
        copied += (size_t)read;
    }
    return (ssize_t)copied;
}

static int MultiFileReadPacket(void *opaque, uint8_t *buf, int buf_size) {
    VPMultiFileIOContext *ctx = (VPMultiFileIOContext *)opaque;
    if (!ctx || ctx->pos >= ctx->totalSize || buf_size <= 0) return AVERROR_EOF;
    int totalCopied = 0;
    while (totalCopied < buf_size && ctx->pos < ctx->totalSize) {
        if (ctx->cacheBuf && ctx->cacheLen > 0 &&
            ctx->pos >= ctx->cacheStart && ctx->pos < ctx->cacheStart + ctx->cacheLen) {
            int64_t offsetInCache = ctx->pos - ctx->cacheStart;
            int64_t availInCache = ctx->cacheLen - offsetInCache;
            int toCopy = (int)MIN((int64_t)(buf_size - totalCopied), availInCache);
            memcpy(buf + totalCopied, ctx->cacheBuf + offsetInCache, (size_t)toCopy);
            totalCopied += toCopy;
            ctx->pos += toCopy;
            continue;
        }
        if (ctx->cacheBuf && ctx->cacheCapacity > 0) {
            ctx->cacheStart = ctx->dvdCellCount ? (ctx->pos / 2048) * 2048 : ctx->pos;
            ssize_t filled = RawMultiFileReadAt(ctx, ctx->cacheStart, ctx->cacheBuf, ctx->cacheCapacity);
            if (filled <= 0) {
                ctx->cacheLen = 0;
                break;
            }
            ctx->cacheLen = (int64_t)filled;
            continue;
        }
        ssize_t direct = RawMultiFileReadAt(ctx, ctx->pos, buf + totalCopied, (size_t)(buf_size - totalCopied));
        if (direct <= 0) break;
        totalCopied += (int)direct;
        ctx->pos += direct;
    }
    return totalCopied > 0 ? totalCopied : AVERROR_EOF;
}

static int64_t MultiFileSeek(void *opaque, int64_t offset, int whence) {
    VPMultiFileIOContext *ctx = (VPMultiFileIOContext *)opaque;
    if (!ctx) return -1;
    if (whence & AVSEEK_SIZE) return ctx->totalSize;
    int baseWhence = whence & ~AVSEEK_FORCE;
    int64_t target = -1;
    if (baseWhence == SEEK_SET) target = offset;
    else if (baseWhence == SEEK_CUR) target = ctx->pos + offset;
    else if (baseWhence == SEEK_END) target = ctx->totalSize + offset;
    if (target < 0) return -1;
    if (target > ctx->totalSize) target = ctx->totalSize;
    ctx->pos = target;
    return ctx->pos;
}

static void FreeMultiFileIOContext(VPMultiFileIOContext *ctx) {
    if (!ctx) return;
    if (ctx->fds) {
        for (int i = 0; i < ctx->count; i++) {
            if (ctx->fds[i] >= 0) close(ctx->fds[i]);
        }
        free(ctx->fds);
    }
    if (ctx->sizes) free(ctx->sizes);
    if (ctx->offsets) free(ctx->offsets);
    if (ctx->cacheBuf) free(ctx->cacheBuf);
    free(ctx->dvdCells);
    free(ctx);
}

static AVIOContext *CreateMultiFileIOFromFFConcat(NSURL *url, VPMultiFileIOContext **outCtx, NSString **outFirstPath) {
    if (!url.isFileURL || ![url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) return NULL;
    NSString *list = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!list.length) return NULL;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![trimmed hasPrefix:@"file '"] || trimmed.length < 8) continue;
        NSString *p = [[trimmed substringWithRange:NSMakeRange(6, trimmed.length - 7)] stringByReplacingOccurrencesOfString:@"'\\''" withString:@"'"];
        if (p.length) [paths addObject:p];
    }
    if (!paths.count) return NULL;
    NSString *firstExt = paths.firstObject.pathExtension.lowercaseString;
    NSSet *rawStreamExts = [NSSet setWithArray:@[@"vob", @"m2ts", @"mts", @"mpg", @"mpeg", @"dat", @"evo", @"ts"]];
    if (![rawStreamExts containsObject:firstExt ?: @""]) return NULL;
    
    int count = (int)paths.count;
    VPMultiFileIOContext *ctx = (VPMultiFileIOContext *)calloc(1, sizeof(VPMultiFileIOContext));
    ctx->count = count;
    ctx->fds = (int *)malloc(sizeof(int) * count);
    ctx->sizes = (int64_t *)calloc(count, sizeof(int64_t));
    ctx->offsets = (int64_t *)calloc(count, sizeof(int64_t));
    for (int i = 0; i < count; i++) ctx->fds[i] = -1;
    
    int64_t runningOffset = 0;
    for (int i = 0; i < count; i++) {
        int fd = open(paths[i].fileSystemRepresentation, O_RDONLY);
        if (fd < 0) {
            FreeMultiFileIOContext(ctx);
            return NULL;
        }
        fcntl(fd, F_RDAHEAD, 1);
        off_t sz = lseek(fd, 0, SEEK_END);
        if (sz <= 0) {
            close(fd);
            FreeMultiFileIOContext(ctx);
            return NULL;
        }
        ctx->fds[i] = fd;
        ctx->sizes[i] = (int64_t)sz;
        ctx->offsets[i] = runningOffset;
        runningOffset += (int64_t)sz;
    }
    ctx->physicalSize = runningOffset;
    ctx->totalSize = runningOffset;
    VPFFConcatMetadata *metadata = [VPDiscSupport parseFFConcatFileAtURL:url];
    if ([firstExt isEqualToString:@"vob"] && metadata.dvdCells.count) {
        ctx->dvdCells = calloc(metadata.dvdCells.count, sizeof(VPDVDCellRange));
        if (!ctx->dvdCells) { FreeMultiFileIOContext(ctx); return NULL; }
        int64_t logicalOffset = 0;
        for (NSDictionary *cell in metadata.dvdCells) {
            int64_t first = [cell[@"first"] longLongValue], last = [cell[@"last"] longLongValue];
            if (first < 0 || last < first || last >= runningOffset / 2048) {
                FreeMultiFileIOContext(ctx);
                return NULL;
            }
            VPDVDCellRange *range = &ctx->dvdCells[ctx->dvdCellCount++];
            *range = (VPDVDCellRange){first * 2048, logicalOffset, (last - first + 1) * 2048,
                [cell[@"vob"] unsignedShortValue], [cell[@"cell"] unsignedCharValue]};
            logicalOffset += range->length;
        }
        ctx->totalSize = logicalOffset;
        ctx->dvdNextPhysicalByte = -1;
    }
    ctx->pos = 0;
    ctx->currentIdx = 0;
    ctx->cacheCapacity = DISC_READAHEAD_CACHE_SIZE;
    ctx->cacheBuf = (uint8_t *)malloc(ctx->cacheCapacity);
    if (!ctx->cacheBuf && ctx->dvdCellCount) { FreeMultiFileIOContext(ctx); return NULL; }
    ctx->cacheStart = 0;
    ctx->cacheLen = 0;
    
    int ioBufferSize = 256 * 1024;
    uint8_t *ioBuffer = (uint8_t *)av_malloc(ioBufferSize);
    if (!ioBuffer) {
        FreeMultiFileIOContext(ctx);
        return NULL;
    }
    AVIOContext *avio = avio_alloc_context(ioBuffer, ioBufferSize, 0, ctx, MultiFileReadPacket, NULL, MultiFileSeek);
    if (!avio) {
        av_free(ioBuffer);
        FreeMultiFileIOContext(ctx);
        return NULL;
    }
    if (outCtx) *outCtx = ctx;
    if (outFirstPath) *outFirstPath = paths.firstObject;
    return avio;
}

static inline double MachTimeToSeconds(uint64_t machTime) {
    static mach_timebase_info_data_t sTimebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&sTimebase);
    });
    return ((double)machTime * (double)sTimebase.numer) / ((double)sTimebase.denom * 1e9);
}

static inline uint64_t SecondsToMachTime(double seconds) {
    static mach_timebase_info_data_t sTimebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&sTimebase);
    });
    return (uint64_t)((seconds * 1e9 * (double)sTimebase.denom) / (double)sTimebase.numer);
}

@interface VPDecodedVideoFrame : NSObject
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) double pts;
@property (nonatomic, assign) double duration;
@end

@implementation VPDecodedVideoFrame
- (void)dealloc {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}
@end

@interface VPFFmpegPlayer () {
@package
    AVFormatContext *_formatCtx;
    AVCodecContext *_videoCodecCtx;
    AVCodecContext *_audioCodecCtx;
    AVBufferRef *_hwDeviceCtx;
    struct SwsContext *_swsCtx;
    SwrContext *_swrCtx;
    AVChannelLayout _swrInLayout;
    enum AVSampleFormat _swrInFmt;
    int _swrInRate;
    AVChannelLayout _swrOutLayout;
    int _swrOutRate;
    int _swrOutChannels;
    AudioConverterRef _hiFiConverter;   // Apple's mastering-grade sample-rate converter, used by Hi-Fidelity
    double _hiFiInRate, _hiFiOutRate;
    int _hiFiChannels;
    NSMutableArray<NSValue *> *_retainedAudio;   // AVFrame clones of decoded audio not yet heard (see retainAudioFrameForRefilter:)
    os_unfair_lock _audioRetainLock;
    BOOL _hiFiLight;                    // the mastering converter could not keep up: use the lighter one
    BOOL _isNetworkSource;            // streamed over the network: audio is pre-rolled and re-buffered
    BOOL _bufferingReported;
    double _reportedBufferProgress;
    NSUInteger _seenSpeakerRevision;  // last speaker-level change this player already flushed its buffer for
    NSUInteger _swrSpeakerRevision;   // speaker-level revision the resampler's matrix was built for
    pthread_mutex_t _filterMutex;
    
    CVPixelBufferPoolRef _pixelBufferPool;
    size_t _poolWidth;
    size_t _poolHeight;
    
    int _videoStreamIndex;
    int _audioStreamIndex;
    AVRational _videoTimeBase;
    AVRational _audioTimeBase;
    
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[AUDIO_BUFFER_COUNT];
    AudioStreamBasicDescription _audioFormat;
    uint64_t _audioOutputMask;
    
    // Video filter graph (libavfilter), built from the first decoded frame; used on the demux thread only
    AVFilterGraph *_videoGraph;
    AVFilterContext *_videoSrcCtx;
    AVFilterContext *_videoSinkCtx;
    AVFrame *_videoFiltFrame;
    NSString *_videoFilterString;
    int _videoGraphWidth, _videoGraphHeight, _videoGraphFormat;
    enum AVColorSpace _videoGraphColorSpace;
    enum AVColorRange _videoGraphColorRange;

    // Audio filter graph (libavfilter)
    AVFilterGraph *_audioGraph;
    AVFilterContext *_audioSrcCtx;
    AVFilterContext *_audioSinkCtx;
    NSString *_currentAudioFilterGraph;
    NSString *_requestedAudioFilterGraph;
    int _filterInRate;
    enum AVSampleFormat _filterInFmt;
    AVChannelLayout _filterInLayout;
    
    // Subtitle decoding (DVD/Blu-ray bitmap + text subtitles)
    int _subtitleStreamIndex;
    int _selectedSubtitleOrdinal;
    int _desiredSubtitleSubstreamID;
    int _desiredAudioSubstreamID;
    AVCodecContext *_subtitleCodecCtx;
    AVRational _subtitleTimeBase;
    uint32_t _clutPalette[16];
    BOOL _hasClutPalette;
    double _subtitleClearPTS;
    BOOL _subtitleVisible;
    // Decoded subtitles waiting for their presentation time. The demuxer reads ahead of playback, so a subtitle must
    // not be shown when it is decoded but when the master clock reaches it.
    NSMutableArray<NSDictionary *> *_pendingSubtitles;
    double _forcedAspectRatio;
    BOOL _isDiscMedia;
    VPFFConcatMetadata *_discConcatMeta;
    
    // Audio ring buffer
    float *_audioRingBuffer;
    size_t _audioRingCapacity;
    size_t _audioRingReadPos;
    size_t _audioRingWritePos;
    size_t _audioRingAvailable;
    int64_t _audioSamplesPlayed;
    os_unfair_lock _audioLock;
    
    // Video frame queue
    NSMutableArray<VPDecodedVideoFrame *> *_videoQueue;
    os_unfair_lock _videoLock;
    
    // Threading & Synchronization
    NSThread *_demuxThread;
    NSCondition *_demuxCond;
    CVDisplayLinkRef _displayLink;
    dispatch_source_t _fallbackVideoTimer;
    dispatch_source_t _audioProgressTimer;
    uint64_t _lastDelegateNotifyHostTime;
    
    BOOL _running;
    BOOL _paused;
    BOOL _seeking;
    BOOL _seekRequested;
    BOOL _seekExact;          // set by frame stepping: land on the requested frame instead of the first frame near it
    BOOL _activeSeekExact;
    BOOL _abortDemux;
    double _seekTargetPTS;
    BOOL _eofReached;
    
    double _audioStartPTS;
    double _audioBasePTS;
    double _audioClockPTS;
    Float64 _audioQueueSampleTimeOffset;
    double _lastRenderedPTS;
    uint64_t _wallClockMachStart;
    double _wallClockBasePTS;
    
    AVIOContext *_customIO;
    VPMultiFileIOContext *_customFileIO;
    BOOL _audioQueueStarted;
    double _streamStartPTS;
    double _videoPTSOffset;
    double _lastRawVideoPTS;
    double _nextDecodedVideoPTS;
    double _audioPTSOffset;
    double _lastRawAudioPTS;
    double _nextDecodedAudioPTS;
    double _audioWriteHeadPTS;
    double _audioQueueEnqueuedEndPTS;
    int64_t _audioQueueFramesEnqueued;
    VPAudioSync _discAudioSync;
    BOOL _audioBufferQueued[AUDIO_BUFFER_COUNT];
    BOOL _discAudioRecovering;
    uint64_t _discAudioTailHostTime;
    double _discAudioTailBasePTS;
    BOOL _discAudioUnavailable;
}

@property (nonatomic, strong) VPAppleSurroundProcessor *appleSurroundProcessor;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) double currentTime;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) BOOL hasVideo;
@property (nonatomic, assign) BOOL hasAudio;
@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) double videoFPS;
@property (nonatomic, strong, readwrite, nullable) VPFFmpegSourceInfo *sourceInfo;

- (void)fillAudioBuffer:(AudioQueueBufferRef)buffer;
- (void)audioBufferReturned:(AudioQueueBufferRef)buffer;

@end

static void AQOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    VPFFmpegPlayer *player = (__bridge VPFFmpegPlayer *)inUserData;
    [player audioBufferReturned:inBuffer];
}

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    const enum AVPixelFormat *p;
    for (p = pix_fmts; *p != -1; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    return pix_fmts[0];
}

static int DemuxInterruptCallback(void *ctx) {
    VPFFmpegPlayer *player = (__bridge VPFFmpegPlayer *)ctx;
    if (!player) return 1;
    return player->_abortDemux ? 1 : 0;
}

static int StreamIndexForOrdinal(AVFormatContext *format, enum AVMediaType type, int ordinal) {
    if (!format || ordinal < 0) return -1;
    int cur = 0;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *st = format->streams[i];
        if (st->codecpar->codec_type != type) continue;
        if (type == AVMEDIA_TYPE_VIDEO && (st->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        if (cur == ordinal) return (int)i;
        cur++;
    }
    return -1;
}

@implementation VPFFmpegPlayer

- (instancetype)init {
    if ((self = [super init])) {
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
        _subtitleStreamIndex = -1;
        _selectedSubtitleOrdinal = -1;
        _desiredSubtitleSubstreamID = -1;
        _desiredAudioSubstreamID = -1;
        _subtitleClearPTS = -1.0;
        _pendingSubtitles = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(speakerLevelsDidChange:) name:VPAudioFiltersDidChangeNotification object:nil];
        _rate = 1.0f;
        _volume = 1.0f;
        _audioLock = OS_UNFAIR_LOCK_INIT;
        _videoLock = OS_UNFAIR_LOCK_INIT;
        _demuxCond = [NSCondition new];
        _videoQueue = [NSMutableArray arrayWithCapacity:MAX_QUEUED_VIDEO_FRAMES];
        _audioStartPTS = -1.0;
        _audioQueueSampleTimeOffset = -1.0;
        _wallClockMachStart = mach_absolute_time();
        
        // Buffer up to 10 seconds of 8-channel audio at up to 192kHz
        _audioRingCapacity = 192000 * 8 * 10;
        _audioRingBuffer = (float *)calloc(_audioRingCapacity, sizeof(float));
        
        memset(&_filterInLayout, 0, sizeof(_filterInLayout));
        _filterInRate = 0;
        _filterInFmt = AV_SAMPLE_FMT_NONE;
        
        pthread_mutexattr_t filterAttr;
        pthread_mutexattr_init(&filterAttr);
        pthread_mutexattr_settype(&filterAttr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_filterMutex, &filterAttr);
        pthread_mutexattr_destroy(&filterAttr);
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopAndNotify:NO];
    [self teardownAudioFilterGraph];
    [self cleanupSwrContext];
    pthread_mutex_destroy(&_filterMutex);
    if (_audioRingBuffer) {
        free(_audioRingBuffer);
        _audioRingBuffer = NULL;
    }
}

#pragma mark - Open & Configure

- (BOOL)openURL:(NSURL *)url options:(nullable NSDictionary *)options error:(NSError **)error {
    [self stopAndNotify:NO];
    
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"macvideoplayerErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid URL."}];
        return NO;
    }
    
    _isNetworkSource = !url.isFileURL;
    _bufferingReported = NO;
    static dispatch_once_t netOnce;
    dispatch_once(&netOnce, ^{ avformat_network_init(); });
    
    AVDictionary *formatOptions = NULL;
    av_dict_set(&formatOptions, "rw_timeout", "15000000", 0);
    const AVInputFormat *inputFmt = NULL;
    
    _abortDemux = NO;
    _formatCtx = avformat_alloc_context();
    if (_formatCtx) {
        _formatCtx->interrupt_callback.callback = DemuxInterruptCallback;
        _formatCtx->interrupt_callback.opaque = (__bridge void *)self;
        _formatCtx->flags |= AVFMT_FLAG_GENPTS;
    }
    
    NSString *path = url.path;
    NSString *firstSegmentPath = nil;
    _discConcatMeta = nil;
    _forcedAspectRatio = 0.0;
    _hasClutPalette = NO;
    _isDiscMedia = (url.isFileURL && ([url.pathExtension.lowercaseString isEqualToString:@"ffconcat"] ||
                                      [VPDiscSupport kindForURL:url] != VPDiscKindNone ||
                                      [path hasPrefix:@"/Volumes/"]));
    if (url.isFileURL && [url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) {
        _discConcatMeta = [VPDiscSupport parseFFConcatFileAtURL:url];
        if (_discConcatMeta) {
            _forcedAspectRatio = _discConcatMeta.aspectRatio;
            if (_discConcatMeta.paletteRGBA.count == 16) {
                for (int i = 0; i < 16; i++) {
                    _clutPalette[i] = _discConcatMeta.paletteRGBA[i].unsignedIntValue;
                }
                _hasClutPalette = YES;
            }
        }
        _customIO = CreateMultiFileIOFromFFConcat(url, &_customFileIO, &firstSegmentPath);
        if (!_customIO && _discConcatMeta.dvdCells.count) {
            // Falling back to raw concatenation would mix the angles again.
            [self cleanupFFmpeg];
            if (error) *error = [NSError errorWithDomain:@"macvideoplayerErrorDomain" code:AVERROR_INVALIDDATA
                userInfo:@{NSLocalizedDescriptionKey:@"Unable to open the selected DVD program cells. Reopen the disc and try again."}];
            return NO;
        }
        if (_customIO && _formatCtx) {
            if (_discConcatMeta.dvdCells.count && _discConcatMeta.duration > 0) {
                // IFO duration is authoritative. Probing the tail of interleaved
                // VOBs adds optical seeks and may find a silent final cell.
                _formatCtx->skip_estimate_duration_from_pts = 1;
            }
            _formatCtx->pb = _customIO;
            _formatCtx->flags |= AVFMT_FLAG_CUSTOM_IO;
            _formatCtx->probesize = 2 * 1024 * 1024;
            _formatCtx->max_analyze_duration = 2 * AV_TIME_BASE;
        } else {
            inputFmt = av_find_input_format("concat");
            av_dict_set(&formatOptions, "safe", "0", 0);
        }
    }
    
    const char *urlStr = _customIO ? (firstSegmentPath.fileSystemRepresentation ?: "") : ((url.isFileURL && path.length) ? path.fileSystemRepresentation : url.absoluteString.UTF8String);
    int ret = avformat_open_input(&_formatCtx, urlStr, (AVInputFormat *)inputFmt, &formatOptions);
    if (formatOptions) av_dict_free(&formatOptions);
    
    if (ret < 0) {
        [self cleanupFFmpeg];
        char errBuf[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, errBuf, sizeof(errBuf));
        if (error) *error = [NSError errorWithDomain:@"macvideoplayerErrorDomain" code:ret userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"FFmpeg failed to open media: %s", errBuf]}];
        return NO;
    }
    
    if (avformat_find_stream_info(_formatCtx, NULL) < 0) {
        [self cleanupFFmpeg];
        if (error) *error = [NSError errorWithDomain:@"macvideoplayerErrorDomain" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"Unable to read stream information."}];
        return NO;
    }
    
    VPFFmpegSourceInfo *sourceInfo = [[VPFFmpegSourceDatabase sharedDatabase] sourceInfoForURL:url];
    if (!sourceInfo) {
        sourceInfo = [[VPFFmpegSourceDatabase sharedDatabase] indexSourceAtURL:url withFormatContext:_formatCtx];
    }
    self.sourceInfo = sourceInfo;
    
    if (_discConcatMeta && _discConcatMeta.duration > 0) {
        self.duration = _discConcatMeta.duration;
    } else if (_formatCtx->duration != AV_NOPTS_VALUE && _formatCtx->duration > 0) {
        self.duration = (double)_formatCtx->duration / AV_TIME_BASE;
    } else if (_customFileIO && _customFileIO->totalSize > 0 && _formatCtx->bit_rate > 0) {
        self.duration = (double)_customFileIO->totalSize * 8.0 / (double)_formatCtx->bit_rate;
    } else if (sourceInfo && sourceInfo.duration > 0) {
        self.duration = sourceInfo.duration;
    } else if (_customFileIO && _customFileIO->totalSize > 0) {
        self.duration = (double)_customFileIO->totalSize / 750000.0;
    } else {
        self.duration = 0.0;
    }
    
    _streamStartPTS = (_formatCtx->start_time != AV_NOPTS_VALUE && _formatCtx->start_time > 0) ? ((double)_formatCtx->start_time / AV_TIME_BASE) : 0.0;
    _videoPTSOffset = -_streamStartPTS;
    _audioPTSOffset = -_streamStartPTS;
    _lastRawVideoPTS = -1.0;
    _nextDecodedVideoPTS = 0.0;
    _lastRawAudioPTS = -1.0;
    _nextDecodedAudioPTS = 0.0;
    _audioWriteHeadPTS = -1.0;
    _audioQueueEnqueuedEndPTS = -1.0;
    _audioQueueFramesEnqueued = 0;
    VPAudioSyncReset(&_discAudioSync, _audioBasePTS);
    _discAudioUnavailable = NO;
    memset(_audioBufferQueued, 0, sizeof(_audioBufferQueued));
    _discAudioRecovering = NO;
    _discAudioTailHostTime = 0;
    _audioQueueStarted = NO;
    
    // Find streams
    int reqVideoStream = options[@"videoStream"] ? [options[@"videoStream"] intValue] : -1;
    int reqAudioStream = options[@"audioStream"] ? [options[@"audioStream"] intValue] : -1;
    
    _videoStreamIndex = -1;
    if (reqVideoStream >= 0) {
        _videoStreamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_VIDEO, reqVideoStream);
    }
    if (_videoStreamIndex < 0) {
        _videoStreamIndex = av_find_best_stream(_formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    }
    
    _audioStreamIndex = -1;
    if (reqAudioStream >= 0) {
        _audioStreamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_AUDIO, reqAudioStream);
    }
    if (_audioStreamIndex < 0) {
        _audioStreamIndex = av_find_best_stream(_formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    }
    
    self.hasVideo = (_videoStreamIndex >= 0);
    self.hasAudio = (_audioStreamIndex >= 0);
    
    if (!self.hasVideo && !self.hasAudio) {
        [self cleanupFFmpeg];
        if (error) *error = [NSError errorWithDomain:@"macvideoplayerErrorDomain" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"No playable video or audio streams found."}];
        return NO;
    }
    
    // Setup video decoder
    if (self.hasVideo) {
        AVStream *vStream = _formatCtx->streams[_videoStreamIndex];
        _videoTimeBase = vStream->time_base;
        
        const AVCodec *vCodec = avcodec_find_decoder(vStream->codecpar->codec_id);
        if (vCodec) {
            _videoCodecCtx = avcodec_alloc_context3(vCodec);
            avcodec_parameters_to_context(_videoCodecCtx, vStream->codecpar);
            _videoCodecCtx->pkt_timebase = vStream->time_base;
            _videoCodecCtx->thread_count = 0; // Auto multi-threading for maximum decoding speed
            
            // Video filters need software frames, so they replace hardware decoding.
            _videoFilterString = [options[@"videoFilterGraph"] length] ? [options[@"videoFilterGraph"] copy] : nil;
            // Check if VideoToolbox is safely supported for this codec
            BOOL canUseVideoToolbox = NO;
            enum AVCodecID cid = vStream->codecpar->codec_id;
            if (cid == AV_CODEC_ID_H264) {
                // VideoToolbox handles standard 8-bit H.264 profiles; skip for Hi10P
                if (vStream->codecpar->profile != 110 && vStream->codecpar->profile != 122 && vStream->codecpar->profile != 244) {
                    canUseVideoToolbox = YES;
                }
            } else if (cid == AV_CODEC_ID_HEVC || cid == AV_CODEC_ID_PRORES) {
                canUseVideoToolbox = YES;
            }
            
            if (canUseVideoToolbox && !_videoFilterString) {
                if (av_hwdevice_ctx_create(&_hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
                    _videoCodecCtx->hw_device_ctx = av_buffer_ref(_hwDeviceCtx);
                    _videoCodecCtx->get_format = get_hw_format;
                }
            }
            
            if (avcodec_open2(_videoCodecCtx, vCodec, NULL) < 0) {
                // If open failed (e.g. hwaccel rejected), fallback to pure software decoding
                if (_hwDeviceCtx) {
                    av_buffer_unref(&_hwDeviceCtx);
                    _hwDeviceCtx = NULL;
                }
                avcodec_free_context(&_videoCodecCtx);
                _videoCodecCtx = avcodec_alloc_context3(vCodec);
                avcodec_parameters_to_context(_videoCodecCtx, vStream->codecpar);
                _videoCodecCtx->pkt_timebase = vStream->time_base;
                _videoCodecCtx->thread_count = 0;
                
                if (avcodec_open2(_videoCodecCtx, vCodec, NULL) < 0) {
                    avcodec_free_context(&_videoCodecCtx);
                    self.hasVideo = NO;
                }
            }
            
            if (self.hasVideo && _videoCodecCtx) {
                int vw = vStream->codecpar->width;
                int vh = vStream->codecpar->height;
                if (_forcedAspectRatio > 0.1 && vh > 0) {
                    vw = (int)llround((double)vh * _forcedAspectRatio);
                } else if (vStream->sample_aspect_ratio.num > 0 && vStream->sample_aspect_ratio.den > 0) {
                    double sar = av_q2d(vStream->sample_aspect_ratio);
                    if (sar > 0.2 && sar < 4.0 && fabs(sar - 1.0) > 0.02) {
                        vw = (int)llround((double)vw * sar);
                    }
                } else if (vStream->codecpar->sample_aspect_ratio.num > 0 && vStream->codecpar->sample_aspect_ratio.den > 0) {
                    double sar = av_q2d(vStream->codecpar->sample_aspect_ratio);
                    if (sar > 0.2 && sar < 4.0 && fabs(sar - 1.0) > 0.02) {
                        vw = (int)llround((double)vw * sar);
                    }
                }
                self.videoSize = CGSizeMake(vw, vh);
                double fps = 0.0;
                if (vStream->avg_frame_rate.den > 0 && vStream->avg_frame_rate.num > 0) {
                    fps = av_q2d(vStream->avg_frame_rate);
                }
                if ((fps < 10.0 || fps > 120.0) && vStream->r_frame_rate.den > 0 && vStream->r_frame_rate.num > 0) {
                    fps = av_q2d(vStream->r_frame_rate);
                }
                if (fps < 10.0 || fps > 120.0) {
                    fps = 29.97;
                }
                self.videoFPS = fps;
            }
        }
    }
    
    // Setup audio decoder & AudioQueue
    if (self.hasAudio) {
        AVStream *aStream = _formatCtx->streams[_audioStreamIndex];
        _audioTimeBase = aStream->time_base;
        
        const AVCodec *aCodec = avcodec_find_decoder(aStream->codecpar->codec_id);
        if (aCodec) {
            _audioCodecCtx = avcodec_alloc_context3(aCodec);
            avcodec_parameters_to_context(_audioCodecCtx, aStream->codecpar);
            _audioCodecCtx->pkt_timebase = aStream->time_base;
            _audioCodecCtx->thread_count = 0;
            
            if (avcodec_open2(_audioCodecCtx, aCodec, NULL) >= 0) {
                [self setupAudioOutputWithOptions:options];
                NSString *initialAF = options[@"af"] ?: options[@"audioFilterGraph"];
                if (initialAF.length > 0) {
                    _requestedAudioFilterGraph = [initialAF copy];
                    [self setupAudioFilterGraph:initialAF];
                }
            } else {
                avcodec_free_context(&_audioCodecCtx);
                self.hasAudio = NO;
            }
        }
    }
    
    if (options[@"subtitleTrack"] || options[@"subtitleStream"]) {
        int subOrd = options[@"subtitleTrack"] ? [options[@"subtitleTrack"] intValue] : [options[@"subtitleStream"] intValue];
        if (subOrd >= 0) {
            [self selectSubtitleTrack:subOrd];
        }
    }
    
    if (options[@"volume"]) {
        self.volume = [options[@"volume"] floatValue];
    }
    if (options[@"rate"]) {
        self.rate = [options[@"rate"] floatValue];
    }
    self.looping = [options[@"loop"] boolValue];
    
    return YES;
}

#pragma mark - Audio Queue Setup

- (void)setupAudioOutputWithOptions:(nullable NSDictionary *)options {
    double sampleRate = 48000.0;
    if (options[@"audioSampleRate"]) {
        NSString *srStr = [options[@"audioSampleRate"] description];
        if (![srStr isEqual:@"auto"] && ![srStr isEqual:@"max"]) {
            double customSR = srStr.doubleValue;
            if (customSR >= 8000 && customSR <= 384000) {
                sampleRate = customSR;
            }
        }
    }
    
    // Music is played at a fixed high rate whenever the device takes it. Everything buffered is then already at the
    // rate Hi-Fidelity and the other effects work at, so they can be switched on and off without reopening the
    // device (which would break the audio clock) and the change is simply re-rendered into the buffer.
    NSString *requestedRate = [options[@"audioSampleRate"] description];
    BOOL rateUnset = !requestedRate.length || [requestedRate isEqual:@"auto"];
    if (rateUnset && !self.hasVideo) {
        NSString *uid = options[@"audioDevice"];
        if ([[VPAudioDeviceManager supportedSampleRatesForDeviceUID:uid.length ? uid : nil] containsObject:@96000]) sampleRate = 96000.0;
    }
    
    int channels = 2;
    AVChannelLayout outLayout;
    av_channel_layout_default(&outLayout, 2);
    
    NSString *layoutStr = options[@"audioLayout"] ?: @"auto";
    if ([layoutStr isEqual:@"mono"] || [layoutStr isEqual:@"1.0"]) {
        channels = 1;
        av_channel_layout_default(&outLayout, 1);
    } else if ([layoutStr isEqual:@"auto"] && _audioCodecCtx->ch_layout.order == AV_CHANNEL_ORDER_NATIVE) {
        outLayout = _audioCodecCtx->ch_layout;
        channels = outLayout.nb_channels;
    } else if ([layoutStr isEqual:@"stereo"] || [layoutStr isEqual:@"2.0"] || [layoutStr isEqual:@"auto"]) {
        channels = 2;
        av_channel_layout_default(&outLayout, 2);
    } else if ([layoutStr isEqual:@"2.1"]) {
        channels = 3;
        av_channel_layout_from_string(&outLayout, "2.1");
    } else if ([layoutStr isEqual:@"4.0"] || [layoutStr isEqual:@"quad"]) {
        channels = 4;
        av_channel_layout_from_string(&outLayout, "quad");
    } else if ([layoutStr isEqual:@"4.1"]) {
        channels = 5;
        av_channel_layout_from_string(&outLayout, "4.1");
    } else if ([layoutStr isEqual:@"5.0"]) {
        channels = 5;
        av_channel_layout_from_string(&outLayout, "5.0");
    } else if ([layoutStr isEqual:@"5.1"]) {
        channels = 6;
        av_channel_layout_from_string(&outLayout, "5.1");
    } else if ([layoutStr isEqual:@"7.1"]) {
        channels = 8;
        av_channel_layout_from_string(&outLayout, "7.1");
    }
    
    _audioOutputMask = outLayout.u.mask;
    memset(&_audioFormat, 0, sizeof(_audioFormat));
    _audioFormat.mSampleRate = sampleRate;
    _audioFormat.mFormatID = kAudioFormatLinearPCM;
    _audioFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    _audioFormat.mChannelsPerFrame = channels;
    _audioFormat.mBitsPerChannel = 32;
    _audioFormat.mBytesPerFrame = channels * sizeof(float);
    _audioFormat.mFramesPerPacket = 1;
    _audioFormat.mBytesPerPacket = _audioFormat.mBytesPerFrame;
    
    OSStatus status = AudioQueueNewOutput(&_audioFormat, AQOutputCallback, (__bridge void *)self, NULL, NULL, 0, &_audioQueue);
    if (status != noErr) {
        _audioQueue = NULL;
        return;
    }
    
    // Use the same speaker order for resampling and Core Audio, including 4.1 versus 5.0.
    VPSetAudioQueueChannelLayout(_audioQueue, &outLayout);
    
    NSString *deviceUID = options[@"audioDevice"];
    if (deviceUID.length > 0) {
        CFStringRef devRef = (__bridge CFStringRef)deviceUID;
        AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_CurrentDevice, &devRef, sizeof(CFStringRef));
    }
    
    for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
        AudioQueueAllocateBuffer(_audioQueue, AUDIO_BUFFER_SIZE, &_audioBuffers[i]);
    }
    
    [self cleanupSwrContext];
    
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, self.volume);
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_PlayRate, self.rate);
}

#pragma mark - Master Clock

- (double)masterClock {
    return [self masterClockAtHostTime:mach_absolute_time()];
}

- (double)masterClockAtHostTime:(uint64_t)targetHostTime {
    if (_isDiscMedia && self.hasAudio && _audioQueue && !_discAudioUnavailable) {
        // Freeze during startup and missing hardware timestamps; a wall clock
        // would run ahead of sound while the optical drive is buffering.
        AudioTimeStamp ts = {0};
        OSStatus status = _audioQueueStarted
            ? AudioQueueGetCurrentTime(_audioQueue, NULL, &ts, NULL) : -1;
        os_unfair_lock_lock(&_audioLock);
        double clock = _discAudioSync.lastClock;
        if (status == noErr && (ts.mFlags & kAudioTimeStampSampleTimeValid)) {
            double rate = _audioFormat.mSampleRate;
            double sampleTime = ts.mSampleTime;
            if (!_paused && !_seeking && (ts.mFlags & kAudioTimeStampHostTimeValid)) {
                // Predict only as far as one display interval, including signed
                // host-time differences. Never extrapolate past submitted media.
                double delta = ((double)targetHostTime - (double)ts.mHostTime);
                double seconds = copysign(MachTimeToSeconds((uint64_t)fabs(delta)), delta);
                sampleTime += fmax(-0.05, fmin(0.05, seconds)) * rate * self.rate;
            }
            clock = VPAudioSyncClock(&_discAudioSync, sampleTime, rate);
        }
        if (_eofReached && _audioRingAvailable == 0 && _discAudioSync.count > 0 &&
            clock >= _discAudioSync.mediaEnd - 0.000001) {
            uint64_t now = mach_absolute_time();
            if (!_discAudioTailHostTime) {
                _discAudioTailHostTime = now;
                _discAudioTailBasePTS = MAX(self.currentTime, _discAudioSync.mediaEnd);
            }
            if (!_paused && targetHostTime > _discAudioTailHostTime) {
                clock = _discAudioTailBasePTS + MachTimeToSeconds(targetHostTime - _discAudioTailHostTime) * self.rate;
            }
        }
        os_unfair_lock_unlock(&_audioLock);
        return clock;
    }
    if (self.hasAudio && _audioQueue && _audioQueueStarted && _audioStartPTS >= 0) {
        AudioTimeStamp ts;
        OSStatus st = AudioQueueGetCurrentTime(_audioQueue, NULL, &ts, NULL);
        if (st == noErr && (ts.mFlags & kAudioTimeStampSampleTimeValid) && ts.mSampleTime >= 0) {
            os_unfair_lock_lock(&_audioLock);
            if (_audioQueueSampleTimeOffset < 0) {
                _audioQueueSampleTimeOffset = ts.mSampleTime;
            }
            double sampleRate = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
            double playedFrames = MAX(0.0, (double)(ts.mSampleTime - _audioQueueSampleTimeOffset));
            double currentAudioPTS;
            if (_audioQueueEnqueuedEndPTS >= 0 && _audioQueueFramesEnqueued > 0) {
                double framesInQueue = MAX(0.0, (double)_audioQueueFramesEnqueued - playedFrames);
                currentAudioPTS = _audioQueueEnqueuedEndPTS - (framesInQueue / sampleRate);
            } else {
                currentAudioPTS = _audioStartPTS + (playedFrames / sampleRate);
            }
            os_unfair_lock_unlock(&_audioLock);
            
            // Extrapolate precisely to target display host time using hardware anchor
            if ((ts.mFlags & kAudioTimeStampHostTimeValid) && ts.mHostTime > 0 && targetHostTime > ts.mHostTime) {
                double delta = MachTimeToSeconds(targetHostTime - ts.mHostTime) * _rate;
                return currentAudioPTS + delta;
            } else if (targetHostTime > 0) {
                uint64_t now = mach_absolute_time();
                if (targetHostTime > now) {
                    double delta = MachTimeToSeconds(targetHostTime - now) * _rate;
                    return currentAudioPTS + delta;
                }
            }
            return currentAudioPTS;
        }
    }
    
    uint64_t refTime = targetHostTime > 0 ? targetHostTime : mach_absolute_time();
    double wallDelta = MachTimeToSeconds(refTime > _wallClockMachStart ? (refTime - _wallClockMachStart) : 0) * _rate;
    return _wallClockBasePTS + wallDelta;
}

#pragma mark - Playback Controls

- (void)play {
    if (!self.isPlaying && !self.isPaused) {
        [_demuxCond lock];
        _running = YES;
        _paused = NO;
        _eofReached = NO;
        [_demuxCond unlock];
        
        self.isPlaying = YES;
        self.isPaused = NO;
        
        _wallClockMachStart = mach_absolute_time();
        _wallClockBasePTS = self.currentTime;
        _audioBasePTS = self.currentTime;
        _audioStartPTS = -1.0;
        _audioQueueSampleTimeOffset = -1.0;
        _audioSamplesPlayed = 0;
        _audioWriteHeadPTS = -1.0;
        _audioQueueEnqueuedEndPTS = -1.0;
        _audioQueueFramesEnqueued = 0;
        VPAudioSyncReset(&_discAudioSync, _audioBasePTS);
        _discAudioUnavailable = NO;
        memset(_audioBufferQueued, 0, sizeof(_audioBufferQueued));
        _discAudioRecovering = NO;
        _discAudioTailHostTime = 0;
        _audioQueueStarted = NO;
        
        [self startDemuxThread];
        [self startDisplayLinkSync];
        
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        if (del) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [del ffmpegPlayerDidStartPlaying];
            });
        }
    } else if (self.isPaused) {
        [_demuxCond lock];
        _paused = NO;
        [_demuxCond broadcast];
        [_demuxCond unlock];
        
        self.isPaused = NO;
        self.isPlaying = YES;
        
        _wallClockMachStart = mach_absolute_time();
        _wallClockBasePTS = self.currentTime;
        
        [self startDisplayLinkSync];
        
        if (_audioQueue && _audioQueueStarted) {
            if (_isDiscMedia) {
                for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) [self fillAudioBuffer:_audioBuffers[i]];
                _discAudioTailHostTime = 0;
            }
            AudioQueueStart(_audioQueue, NULL);
        }
    }
}

- (void)pause {
    if (self.isPlaying && !self.isPaused) {
        [_demuxCond lock];
        _paused = YES;
        [_demuxCond broadcast];
        [_demuxCond unlock];
        
        self.isPaused = YES;
        self.isPlaying = NO;
        self.currentTime = [self masterClock];
        
        [self stopDisplayLinkSync];
        
        if (_audioQueue) {
            AudioQueuePause(_audioQueue);
        }
        
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        if (del) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [del ffmpegPlayerDidPause];
            });
        }
    }
}

- (void)togglePlayPause {
    if (self.isPaused || !self.isPlaying) {
        [self play];
    } else {
        [self pause];
    }
}

- (void)stop {
    [self stopAndNotify:YES];
}

- (void)stopAndNotify:(BOOL)notifyDelegate {
    @synchronized (self) {
        if (!_running && !self.isPlaying && !_demuxThread && !_audioQueue && !_displayLink && !_formatCtx) {
            return;
        }
        
        self.isPlaying = NO;
        self.isPaused = NO;
        _seeking = NO;
        _seekRequested = NO;
        _abortDemux = YES;
        
        [_demuxCond lock];
        _running = NO;
        [_demuxCond broadcast];
        [_demuxCond unlock];
        
        // Wait for demux thread to safely exit
        while (_demuxThread && !_demuxThread.isFinished) {
            [NSThread sleepForTimeInterval:0.005];
        }
        _demuxThread = nil;
        
        [self stopDisplayLinkSync];
        
        if (_audioQueue) {
            AudioQueueRef aq = _audioQueue;
            _audioQueue = NULL;
            AudioQueueStop(aq, YES);
            AudioQueueDispose(aq, YES);
        }
        
        self.frameHandler = nil;
        self.audioSamplesHandler = nil;
        self.subtitleHandler = nil;
        
        [self clearAudioBuffer];
        [self clearVideoQueue];
        [self cleanupFFmpeg];
        
        self.currentTime = 0;
        _audioStartPTS = -1.0;
        _audioQueueSampleTimeOffset = -1.0;
        
        if (notifyDelegate) {
            id<VPFFmpegPlayerDelegate> del = self.delegate;
            if (del) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [del ffmpegPlayerDidStop];
                });
            }
        }
    }
}

- (void)seekToSeconds:(double)seconds {
    if (!_formatCtx) return;
    seconds = MAX(0.0, MIN(seconds, self.duration > 0 ? self.duration : seconds));
    
    [_demuxCond lock];
    _seekRequested = YES;
    _seekExact = NO;
    _seekTargetPTS = seconds;
    _seeking = YES;
    [_demuxCond broadcast];
    [_demuxCond unlock];
}

- (void)stepFrames:(NSInteger)count {
    if (!_formatCtx || !self.hasVideo || count == 0) return;
    if (self.isPlaying && !self.isPaused) [self pause];
    double frameDuration = 1.0 / MAX(1.0, self.videoFPS);
    [_demuxCond lock];
    double base = _lastRenderedPTS > 0 ? _lastRenderedPTS : self.currentTime;
    double target = MAX(0.0, base + count * frameDuration);
    if (self.duration > 0) target = MIN(target, self.duration);
    _seekRequested = YES;
    _seekExact = YES;
    _seekTargetPTS = target;
    _seeking = YES;
    [_demuxCond broadcast];
    [_demuxCond unlock];
}

- (BOOL)selectAudioTrack:(int)trackOrdinal {
    if (!_formatCtx || trackOrdinal < 0) return NO;
    [_demuxCond lock];
    _desiredAudioSubstreamID = -1;
    if (_discConcatMeta && trackOrdinal < (int)_discConcatMeta.audioStreams.count) {
        _desiredAudioSubstreamID = _discConcatMeta.audioStreams[trackOrdinal].streamID;
    }
    int streamIndex = -1;
    if (_desiredAudioSubstreamID > 0) {
        for (unsigned i = 0; i < _formatCtx->nb_streams; i++) {
            AVStream *st = _formatCtx->streams[i];
            if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                (st->id == _desiredAudioSubstreamID || (st->id & 0xFF) == (_desiredAudioSubstreamID & 0xFF))) {
                streamIndex = (int)i;
                break;
            }
        }
    }
    if (streamIndex < 0) {
        streamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_AUDIO, trackOrdinal);
    }
    if (streamIndex < 0 || streamIndex >= (int)_formatCtx->nb_streams) {
        [_demuxCond unlock];
        return (_desiredAudioSubstreamID > 0);
    }
    if (streamIndex == _audioStreamIndex && _audioCodecCtx) {
        [_demuxCond unlock];
        return YES;
    }
    
    if (_audioCodecCtx) {
        avcodec_free_context(&_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
    if (_subtitleCodecCtx) {
        avcodec_free_context(&_subtitleCodecCtx);
        _subtitleCodecCtx = NULL;
    }
    _subtitleStreamIndex = -1;
    _subtitleClearPTS = -1.0;
    _subtitleVisible = NO;
    _requestedAudioFilterGraph = nil;
    [self cleanupSwrContext];
    
    AVStream *aStream = _formatCtx->streams[streamIndex];
    _audioStreamIndex = streamIndex;
    _audioTimeBase = aStream->time_base;
    
    const AVCodec *aCodec = avcodec_find_decoder(aStream->codecpar->codec_id);
    if (aCodec) {
        _audioCodecCtx = avcodec_alloc_context3(aCodec);
        avcodec_parameters_to_context(_audioCodecCtx, aStream->codecpar);
        _audioCodecCtx->pkt_timebase = aStream->time_base;
        _audioCodecCtx->thread_count = 0;
        if (avcodec_open2(_audioCodecCtx, aCodec, NULL) >= 0) {
            self.hasAudio = YES;
            NSString *graphToApply = _requestedAudioFilterGraph ?: _currentAudioFilterGraph;
            if (graphToApply.length > 0) {
                [self setupAudioFilterGraph:graphToApply];
            }
        } else {
            avcodec_free_context(&_audioCodecCtx);
            _audioCodecCtx = NULL;
            self.hasAudio = NO;
        }
    } else {
        self.hasAudio = NO;
    }
    
    os_unfair_lock_lock(&_audioLock);
    _audioRingAvailable = 0;
    _audioRingReadPos = 0;
    _audioRingWritePos = 0;
    os_unfair_lock_unlock(&_audioLock);
    
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, YES);
        AudioQueueReset(_audioQueue);
    }
    os_unfair_lock_lock(&_audioLock);
    VPAudioSyncReset(&_discAudioSync, self.currentTime);
    _discAudioUnavailable = NO;
    memset(_audioBufferQueued, 0, sizeof(_audioBufferQueued));
    _discAudioRecovering = NO;
    _discAudioTailHostTime = 0;
    _audioQueueStarted = NO;
    _audioStartPTS = -1.0;
    _audioWriteHeadPTS = -1.0;
    _audioBasePTS = self.currentTime;
    os_unfair_lock_unlock(&_audioLock);
    
    [_demuxCond broadcast];
    [_demuxCond unlock];
    return YES;
}

- (BOOL)openSubtitleStreamAtIndexLocked:(int)streamIndex {
    if (!_formatCtx || streamIndex < 0 || streamIndex >= (int)_formatCtx->nb_streams) return NO;
    if (_subtitleCodecCtx) {
        avcodec_free_context(&_subtitleCodecCtx);
        _subtitleCodecCtx = NULL;
    }
    AVStream *sStream = _formatCtx->streams[streamIndex];
    const AVCodec *sCodec = avcodec_find_decoder(sStream->codecpar->codec_id);
    if (!sCodec) return NO;
    _subtitleCodecCtx = avcodec_alloc_context3(sCodec);
    if (!_subtitleCodecCtx) return NO;
    avcodec_parameters_to_context(_subtitleCodecCtx, sStream->codecpar);
    _subtitleCodecCtx->pkt_timebase = sStream->time_base;
    if (avcodec_open2(_subtitleCodecCtx, sCodec, NULL) < 0) {
        avcodec_free_context(&_subtitleCodecCtx);
        _subtitleCodecCtx = NULL;
        return NO;
    }
    _subtitleStreamIndex = streamIndex;
    _subtitleTimeBase = sStream->time_base;
    return YES;
}

- (BOOL)selectSubtitleTrack:(int)trackOrdinal {
    [_demuxCond lock];
    _selectedSubtitleOrdinal = trackOrdinal;
    @synchronized (_pendingSubtitles) { [_pendingSubtitles removeAllObjects]; }
    _subtitleClearPTS = -1.0;
    _subtitleVisible = NO;
    if (self.subtitleHandler) {
        self.subtitleHandler(nil, nil);
    }
    if (trackOrdinal < 0 || !_formatCtx) {
        if (_subtitleCodecCtx) {
            avcodec_free_context(&_subtitleCodecCtx);
            _subtitleCodecCtx = NULL;
        }
        _subtitleStreamIndex = -1;
        _desiredSubtitleSubstreamID = -1;
        [_demuxCond unlock];
        return YES;
    }
    _desiredSubtitleSubstreamID = -1;
    if (_discConcatMeta && trackOrdinal < (int)_discConcatMeta.subtitleStreams.count) {
        _desiredSubtitleSubstreamID = _discConcatMeta.subtitleStreams[trackOrdinal].streamID;
    } else if (_isDiscMedia) {
        _desiredSubtitleSubstreamID = 0x20 + trackOrdinal;
    }
    int streamIndex = -1;
    if (_desiredSubtitleSubstreamID > 0) {
        for (unsigned i = 0; i < _formatCtx->nb_streams; i++) {
            AVStream *st = _formatCtx->streams[i];
            if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE &&
                (st->id == _desiredSubtitleSubstreamID || (st->id & 0xFF) == (_desiredSubtitleSubstreamID & 0xFF))) {
                streamIndex = (int)i;
                break;
            }
        }
    }
    if (streamIndex < 0) {
        streamIndex = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_SUBTITLE, trackOrdinal);
    }
    if (streamIndex >= 0) {
        [self openSubtitleStreamAtIndexLocked:streamIndex];
    } else {
        if (_subtitleCodecCtx) {
            avcodec_free_context(&_subtitleCodecCtx);
            _subtitleCodecCtx = NULL;
        }
        _subtitleStreamIndex = -1;
    }
    [_demuxCond unlock];
    return YES;
}

- (void)setVolume:(float)volume {
    _volume = MAX(0.0f, MIN(volume, 1.0f));
    if (_audioQueue) {
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, _volume);
    }
}

- (void)setRate:(float)rate {
    _rate = MAX(0.25f, MIN(rate, 4.0f));
    if (_audioQueue) {
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_PlayRate, _rate);
    }
    _wallClockMachStart = mach_absolute_time();
    _wallClockBasePTS = self.currentTime;
}

#pragma mark - Demuxer Worker Thread

- (void)startDemuxThread {
    if (_demuxThread && !_demuxThread.isFinished) return;
    _demuxThread = [[NSThread alloc] initWithTarget:self selector:@selector(demuxThreadMain) object:nil];
    _demuxThread.name = @"com.macvideoplayer.ffmpeg.demux";
    _demuxThread.qualityOfService = NSQualityOfServiceUserInitiated;
    [_demuxThread start];
}

- (void)demuxThreadMain {
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    
    while (1) {
        [_demuxCond lock];
        if (!_running) {
            [_demuxCond unlock];
            break;
        }
        
        // Handle Seek Request
        if (_seekRequested) {
            double target = _seekTargetPTS;
            _activeSeekExact = _seekExact;
            _seekRequested = NO;
            [_demuxCond unlock];
            
            [self performSeekTo:target frame:frame packet:packet];
            continue;
        }
        
        // Handle Paused
        if (_paused) {
            [_demuxCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
            [_demuxCond unlock];
            continue;
        }
        
        // Backpressure check
        BOOL videoFull = NO;
        BOOL videoHardCap = NO;
        os_unfair_lock_lock(&_videoLock);
        NSUInteger vCount = _videoQueue.count;
        if (vCount >= MAX_QUEUED_VIDEO_FRAMES) videoFull = YES;
        if (vCount >= MAX_QUEUED_VIDEO_FRAMES * 2) videoHardCap = YES;
        os_unfair_lock_unlock(&_videoLock);
        
        BOOL audioFull = NO;
        os_unfair_lock_lock(&_audioLock);
        int ch = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
        double activeSampleRate = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
        if (_audioRingAvailable > (size_t)(activeSampleRate * ch * MAX_QUEUED_AUDIO_SECONDS)) audioFull = YES;
        os_unfair_lock_unlock(&_audioLock);
        
        // A declared but completely undecodable audio track must not deadlock
        // preroll against the video queue limit. Resume audio-master operation
        // if valid PCM subsequently arrives.
        if (_isDiscMedia && videoHardCap && _audioStartPTS < 0 && !_discAudioUnavailable) {
            _wallClockBasePTS = self.currentTime;
            _wallClockMachStart = mach_absolute_time();
            _discAudioUnavailable = YES;
        }
        // Audio-only media has no video queue to pace the reader, so the audio queue must: otherwise the decoder races
        // far ahead of the speakers, fills the ring and silently drops what it decodes next.
        if (videoHardCap || (videoFull && (audioFull || !self.hasAudio)) || (!self.hasVideo && self.hasAudio && audioFull)) {
            [_demuxCond unlock];
            [NSThread sleepForTimeInterval:0.006];
            continue;
        }
        [_demuxCond unlock];
        
        // Read next packet
        int ret = av_read_frame(_formatCtx, packet);
        if (ret < 0) {
            if (ret == AVERROR_EOF) {
                if (!_eofReached) {
                    // Drain delayed decoder/filter frames before declaring EOF.
                    if (_videoCodecCtx) [self decodeVideoPacket:NULL frame:frame];
                    if (_audioCodecCtx) [self decodeAudioPacket:NULL frame:frame];
                    if (_videoSrcCtx && av_buffersrc_add_frame_flags(_videoSrcCtx, NULL, 0) >= 0) {
                        AVRational timeBase = av_buffersink_get_time_base(_videoSinkCtx);
                        while (av_buffersink_get_frame(_videoSinkCtx, _videoFiltFrame) >= 0) {
                            double pts = _videoFiltFrame->pts == AV_NOPTS_VALUE ? _nextDecodedVideoPTS : _videoFiltFrame->pts * av_q2d(timeBase);
                            [self enqueueFilteredVideoFrame:_videoFiltFrame pts:pts fallbackDuration:1.0 / MAX(1.0, self.videoFPS)];
                            av_frame_unref(_videoFiltFrame);
                        }
                    }
                }
                [_demuxCond lock];
                _eofReached = YES;
                if (_isDiscMedia && _audioStartPTS < 0 && !_discAudioUnavailable) {
                    _wallClockBasePTS = self.currentTime;
                    _wallClockMachStart = mach_absolute_time();
                    _discAudioUnavailable = YES;
                }
                [_demuxCond unlock];
                if (_audioQueue && !_audioQueueStarted && _audioRingAvailable > 0 && self.isPlaying && !self.isPaused) {
                    for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
                        if ((_isDiscMedia || _audioBuffers[i]->mAudioDataByteSize == 0) && _audioRingAvailable > 0) {
                            [self fillAudioBuffer:_audioBuffers[i]];
                        }
                    }
                    _audioQueueStarted = YES;
                    AudioQueueStart(_audioQueue, NULL);
                }
                [_demuxCond lock];
                [_demuxCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                [_demuxCond unlock];
                [self checkEndOfStream];
            } else {
                [NSThread sleepForTimeInterval:0.005];
            }
            continue;
        }
        
        if (packet->stream_index >= 0 && packet->stream_index < (int)_formatCtx->nb_streams) {
            AVStream *pktStream = _formatCtx->streams[packet->stream_index];
            if (pktStream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE &&
                _selectedSubtitleOrdinal >= 0 && _subtitleStreamIndex < 0) {
                BOOL match = NO;
                if (_desiredSubtitleSubstreamID > 0) {
                    match = (pktStream->id == _desiredSubtitleSubstreamID ||
                             (pktStream->id & 0xFF) == (_desiredSubtitleSubstreamID & 0xFF));
                } else {
                    int idx = StreamIndexForOrdinal(_formatCtx, AVMEDIA_TYPE_SUBTITLE, _selectedSubtitleOrdinal);
                    match = (idx == packet->stream_index);
                }
                if (match) {
                    [_demuxCond lock];
                    [self openSubtitleStreamAtIndexLocked:packet->stream_index];
                    [_demuxCond unlock];
                }
            } else if (pktStream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
                       _desiredAudioSubstreamID > 0 && packet->stream_index != _audioStreamIndex) {
                if (pktStream->id == _desiredAudioSubstreamID ||
                    (pktStream->id & 0xFF) == (_desiredAudioSubstreamID & 0xFF)) {
                    [_demuxCond lock];
                    const AVCodec *aCodec = avcodec_find_decoder(pktStream->codecpar->codec_id);
                    if (aCodec) {
                        if (_audioCodecCtx) avcodec_free_context(&_audioCodecCtx);
                        _audioCodecCtx = avcodec_alloc_context3(aCodec);
                        avcodec_parameters_to_context(_audioCodecCtx, pktStream->codecpar);
                        _audioCodecCtx->pkt_timebase = pktStream->time_base;
                        _audioCodecCtx->thread_count = 0;
                        if (avcodec_open2(_audioCodecCtx, aCodec, NULL) >= 0) {
                            _audioStreamIndex = packet->stream_index;
                            _audioTimeBase = pktStream->time_base;
                            self.hasAudio = YES;
                            NSString *graphToApply = _requestedAudioFilterGraph ?: _currentAudioFilterGraph;
                            if (graphToApply.length > 0) {
                                [self setupAudioFilterGraph:graphToApply];
                            }
                        }
                    }
                    [_demuxCond unlock];
                }
            }
        }
        
        if (packet->stream_index == _videoStreamIndex && _videoCodecCtx) {
            [self decodeVideoPacket:packet frame:frame];
        } else if (packet->stream_index == _audioStreamIndex && _audioCodecCtx) {
            [self decodeAudioPacket:packet frame:frame];
        } else if (packet->stream_index == _subtitleStreamIndex && _subtitleCodecCtx) {
            [self decodeSubtitlePacket:packet];
        }
        
        av_packet_unref(packet);
    }
    
    av_packet_free(&packet);
    av_frame_free(&frame);
}

- (void)performSeekTo:(double)target frame:(AVFrame *)frame packet:(AVPacket *)packet {
    if (!_formatCtx) return;
    target = MAX(0.0, MIN(target, self.duration > 0 ? self.duration : target));
    
    double rawTarget = target + _streamStartPTS;
    int64_t seekTarget = (int64_t)(rawTarget * AV_TIME_BASE);
    
    // Multi-tier robust seeking strategy for MKV, MP4, WebM, TS, AVI, VOB/MPEG-PS
    int seekRet = -1;
    if (_videoStreamIndex >= 0 && _formatCtx->streams[_videoStreamIndex]) {
        AVRational tb = _formatCtx->streams[_videoStreamIndex]->time_base;
        int64_t streamTarget = av_rescale_q(seekTarget, AV_TIME_BASE_Q, tb);
        seekRet = avformat_seek_file(_formatCtx, _videoStreamIndex, INT64_MIN, streamTarget, streamTarget, AVSEEK_FLAG_BACKWARD);
        if (seekRet < 0) {
            seekRet = av_seek_frame(_formatCtx, _videoStreamIndex, streamTarget, AVSEEK_FLAG_BACKWARD);
        }
    }
    
    if (seekRet < 0) {
        seekRet = avformat_seek_file(_formatCtx, -1, INT64_MIN, seekTarget, seekTarget, AVSEEK_FLAG_BACKWARD);
        if (seekRet < 0) {
            seekRet = av_seek_frame(_formatCtx, -1, seekTarget, AVSEEK_FLAG_BACKWARD);
        }
    }
    
    if (seekRet < 0) {
        seekRet = avformat_seek_file(_formatCtx, -1, INT64_MIN, seekTarget, INT64_MAX, 0);
        if (seekRet < 0) {
            seekRet = av_seek_frame(_formatCtx, -1, seekTarget, 0);
        }
    }
    
    if (seekRet < 0 && _customFileIO && _customFileIO->totalSize > 0 && self.duration > 0) {
        int64_t byteTarget = (int64_t)((target / self.duration) * (double)_customFileIO->totalSize);
        byteTarget = MAX(0, MIN(byteTarget, _customFileIO->totalSize - 65536));
        avformat_seek_file(_formatCtx, -1, INT64_MIN, byteTarget, INT64_MAX, AVSEEK_FLAG_BYTE);
    }
    
    // Flush codec buffers and queues
    if (_videoCodecCtx) avcodec_flush_buffers(_videoCodecCtx);
    if (_audioCodecCtx) avcodec_flush_buffers(_audioCodecCtx);
    self.appleSurroundProcessor = nil;
    if (_hiFiConverter) AudioConverterReset(_hiFiConverter);
    if (_subtitleCodecCtx) avcodec_flush_buffers(_subtitleCodecCtx);
    @synchronized (_pendingSubtitles) { [_pendingSubtitles removeAllObjects]; }
    _subtitleClearPTS = -1.0;
    _subtitleVisible = NO;
    if (self.subtitleHandler) {
        self.subtitleHandler(nil, nil);
    }
    [self teardownVideoGraph];   // rebuilt from the first frame after the seek, dropping any buffered frames
    
    pthread_mutex_lock(&_filterMutex);
    NSString *curAF = [_requestedAudioFilterGraph ?: _currentAudioFilterGraph copy];
    if (curAF.length > 0 && _audioCodecCtx) {
        [self teardownAudioFilterGraphLocked];
        [self setupAudioFilterGraphLocked:curAF inputFrame:nil];
    }
    pthread_mutex_unlock(&_filterMutex);
    
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, YES);
        AudioQueueReset(_audioQueue);
        for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
            if (_audioBuffers[i]) {
                _audioBuffers[i]->mAudioDataByteSize = 0;
            }
        }
    }
    
    [self clearAudioBuffer];
    [self clearVideoQueue];
    _audioQueueStarted = NO;
    _audioStartPTS = -1.0;
    _audioBasePTS = target;
    _audioClockPTS = target;
    _audioQueueSampleTimeOffset = -1.0;
    _audioSamplesPlayed = 0;
    _audioWriteHeadPTS = -1.0;
    _audioQueueEnqueuedEndPTS = -1.0;
    _audioQueueFramesEnqueued = 0;
    VPAudioSyncReset(&_discAudioSync, _audioBasePTS);
    _discAudioUnavailable = NO;
    memset(_audioBufferQueued, 0, sizeof(_audioBufferQueued));
    _discAudioRecovering = NO;
    _discAudioTailHostTime = 0;
    _lastRenderedPTS = target;
    _wallClockMachStart = mach_absolute_time();
    _wallClockBasePTS = target;
    _videoPTSOffset = -_streamStartPTS;
    _audioPTSOffset = -_streamStartPTS;
    _lastRawVideoPTS = -1.0;
    _nextDecodedVideoPTS = target;
    _lastRawAudioPTS = -1.0;
    _nextDecodedAudioPTS = target;
    self.currentTime = target;
    
    // Decode forward to target so target frame displays immediately
    if (self.hasVideo && _videoCodecCtx) {
        __block BOOL gotFrame = NO;
        double slack = _activeSeekExact ? 0.5 / MAX(1.0, self.videoFPS) : 0.04;
        int maxPackets = 400;
        for (int i = 0; i < maxPackets && !gotFrame; i++) {
            [_demuxCond lock];
            if (_seekRequested) {
                [_demuxCond unlock];
                break;
            }
            [_demuxCond unlock];
            
            if (av_read_frame(_formatCtx, packet) < 0) break;
            
            if (packet->stream_index == _videoStreamIndex) {
                if (avcodec_send_packet(_videoCodecCtx, packet) >= 0) {
                    while (!gotFrame && avcodec_receive_frame(_videoCodecCtx, frame) >= 0) {
                        int64_t rawTS = (frame->best_effort_timestamp != AV_NOPTS_VALUE) ? frame->best_effort_timestamp : frame->pts;
                        double normPTS = target;
                        if (rawTS != AV_NOPTS_VALUE) {
                            double rawSec = rawTS * av_q2d(_videoTimeBase);
                            if (_lastRawVideoPTS < 0 && fabs((rawSec + _videoPTSOffset) - target) > 2.0) {
                                _videoPTSOffset = target - rawSec;
                                _audioPTSOffset = _videoPTSOffset;
                            }
                            _lastRawVideoPTS = rawSec;
                            normPTS = MAX(0.0, rawSec + _videoPTSOffset);
                        }
                        frame->pts = (int64_t)llround(normPTS / av_q2d(_videoTimeBase));
                        double baseDur = 1.0 / MAX(10.0, MIN(120.0, self.videoFPS));
                        double frameDur = baseDur * (1.0 + (frame->repeat_pict > 0 ? frame->repeat_pict * 0.5 : 0.0));
                        _nextDecodedVideoPTS = normPTS + frameDur;
                        [self filterVideoFrame:frame fallbackPTS:normPTS handler:^(AVFrame *out, double pts) {
                            if (gotFrame || !(pts >= target - slack || i >= maxPackets - 20)) return;
                            CVPixelBufferRef pb = [self pixelBufferFromFrame:out];
                            if (!pb) return;
                            self->_lastRenderedPTS = pts;
                            self.currentTime = pts;
                            self->_wallClockBasePTS = pts;
                            self->_wallClockMachStart = mach_absolute_time();
                            self->_audioBasePTS = pts;
                            self->_audioClockPTS = pts;
                            self->_nextDecodedAudioPTS = pts;
                            if (self.frameHandler) {
                                CVPixelBufferRetain(pb);
                                self.frameHandler(pb, pts);
                                CVPixelBufferRelease(pb);
                            }
                            CVPixelBufferRelease(pb);
                            gotFrame = YES;
                        }];
                    }
                }
            } else if (packet->stream_index == _audioStreamIndex && _audioCodecCtx) {
                int64_t rawAPts = (packet->pts != AV_NOPTS_VALUE) ? packet->pts : packet->dts;
                double aPts = (rawAPts != AV_NOPTS_VALUE) ? (rawAPts * av_q2d(_audioTimeBase) + _audioPTSOffset) : target;
                if (aPts >= target - 0.05) {
                    [self decodeAudioPacket:packet frame:frame];
                }
            } else if (packet->stream_index == _subtitleStreamIndex && _subtitleCodecCtx) {
                // Keeps a subtitle that started before the seek target but is still on screen at the target.
                [self decodeSubtitlePacket:packet];
            }
            av_packet_unref(packet);
        }
        if (_audioCodecCtx && _audioRingAvailable == 0) {
            for (int i = 0; i < 50 && _audioRingAvailable == 0; i++) {
                [_demuxCond lock];
                if (_seekRequested) {
                    [_demuxCond unlock];
                    break;
                }
                [_demuxCond unlock];
                if (av_read_frame(_formatCtx, packet) < 0) break;
                if (packet->stream_index == _audioStreamIndex) {
                    [self decodeAudioPacket:packet frame:frame];
                } else if (packet->stream_index == _videoStreamIndex) {
                    // Dropping these would leave a hole in the video right after the seek frame.
                    [self decodeVideoPacket:packet frame:frame];
                } else if (packet->stream_index == _subtitleStreamIndex && _subtitleCodecCtx) {
                    [self decodeSubtitlePacket:packet];
                }
                av_packet_unref(packet);
            }
        }
    } else if (!self.hasVideo && _audioCodecCtx) {
        for (int i = 0; i < 200; i++) {
            [_demuxCond lock];
            if (_seekRequested) {
                [_demuxCond unlock];
                break;
            }
            [_demuxCond unlock];
            
            if (av_read_frame(_formatCtx, packet) < 0) break;
            if (packet->stream_index == _audioStreamIndex) {
                [self decodeAudioPacket:packet frame:frame];
                av_packet_unref(packet);
                break;
            }
            av_packet_unref(packet);
        }
    }
    
    [_demuxCond lock];
    if (_seekRequested) {
        [_demuxCond unlock];
        return;
    }
    _eofReached = NO;
    _seeking = NO;
    [_demuxCond unlock];
    
    if (_audioQueue && _audioRingAvailable > 0 &&
        (!_isDiscMedia || _audioRingAvailable >= (size_t)(_audioFormat.mSampleRate * _audioFormat.mChannelsPerFrame * 0.65)) &&
        (!_isNetworkSource || _audioRingAvailable >= (size_t)(_audioFormat.mSampleRate * _audioFormat.mChannelsPerFrame * kNetworkPrerollSeconds))) {
        for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
            if ((_isDiscMedia || _audioBuffers[i]->mAudioDataByteSize == 0) && _audioRingAvailable > 0) {
                [self fillAudioBuffer:_audioBuffers[i]];
            }
        }
        if (self.isPlaying && !self.isPaused) {
            _audioQueueStarted = YES;
            AudioQueueStart(_audioQueue, NULL);
        }
    }
    
    id<VPFFmpegPlayerDelegate> del = self.delegate;
    if (del) {
        double cur = self.currentTime;
        double dur = self.duration;
        dispatch_async(dispatch_get_main_queue(), ^{
            [del ffmpegPlayerDidUpdateTime:cur duration:dur];
        });
    }
}

#pragma mark - Video Decoding & Metal Buffer Creation

- (void)decodeVideoPacket:(AVPacket *)packet frame:(AVFrame *)frame {
    int ret = avcodec_send_packet(_videoCodecCtx, packet);
    if (ret < 0) return;
    
    double fps = MAX(10.0, MIN(120.0, self.videoFPS > 0 ? self.videoFPS : 29.97));
    double baseFrameDur = 1.0 / fps;
    double tbSec = av_q2d(_videoTimeBase);
    
    while (ret >= 0) {
        ret = avcodec_receive_frame(_videoCodecCtx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;
        
        // Decoder duration already accounts for repeated fields. Average FPS does not
        // provide a reliable field duration for soft-telecined DVD material.
        double frameDur = frame->duration > 0 && tbSec > 0 ? frame->duration * tbSec : baseFrameDur;
        int64_t rawTS = (frame->best_effort_timestamp != AV_NOPTS_VALUE) ? frame->best_effort_timestamp : frame->pts;
        double normPTS = _nextDecodedVideoPTS;
        
        if (rawTS != AV_NOPTS_VALUE && tbSec > 0) {
            double rawSec = rawTS * tbSec;
            if (_lastRawVideoPTS < 0) {
                if (_streamStartPTS == 0.0 && rawSec > 0.5 && _nextDecodedVideoPTS == 0.0) {
                    _streamStartPTS = rawSec;
                    _videoPTSOffset = -rawSec;
                    if (_lastRawAudioPTS < 0) _audioPTSOffset = -rawSec;
                }
            } else {
                double delta = rawSec - _lastRawVideoPTS;
                // Detect DVD VOB cell/chapter/layer SCR resets or large timestamp discontinuities
                if (delta < -0.25 || delta > 1.5) {
                    _videoPTSOffset = _nextDecodedVideoPTS - rawSec;
                }
            }
            _lastRawVideoPTS = rawSec;
            normPTS = rawSec + _videoPTSOffset;
            if (normPTS < 0.0) normPTS = 0.0;
            // Preserve source presentation timestamps. Clamping against an estimated
            // next-frame time accumulates drift on variable-cadence DVD footage.
        }
        
        _nextDecodedVideoPTS = normPTS + frameDur;
        if (tbSec > 0) {
            frame->pts = (int64_t)llround(normPTS / tbSec);
        }
        
        [self filterVideoFrame:frame fallbackPTS:normPTS handler:^(AVFrame *out, double pts) {
            [self enqueueFilteredVideoFrame:out pts:pts fallbackDuration:frameDur];
        }];
    }
}

- (void)enqueueFilteredVideoFrame:(AVFrame *)frame pts:(double)pts fallbackDuration:(double)duration {
    CVPixelBufferRef pixelBuffer = [self pixelBufferFromFrame:frame];
    if (!pixelBuffer) return;
    VPDecodedVideoFrame *videoFrame = [VPDecodedVideoFrame new];
    videoFrame.pixelBuffer = pixelBuffer;
    videoFrame.pts = pts;
    AVRational timeBase = _videoSinkCtx ? av_buffersink_get_time_base(_videoSinkCtx) : _videoTimeBase;
    videoFrame.duration = frame->duration > 0 ? frame->duration * av_q2d(timeBase) : duration;
    os_unfair_lock_lock(&_videoLock);
    [_videoQueue addObject:videoFrame];
    os_unfair_lock_unlock(&_videoLock);
}

#pragma mark - Video Filter Graph

- (void)teardownVideoGraph {
    if (_videoGraph) avfilter_graph_free(&_videoGraph);
    _videoGraph = NULL; _videoSrcCtx = NULL; _videoSinkCtx = NULL;
    if (_videoFiltFrame) av_frame_free(&_videoFiltFrame);
}

- (BOOL)buildVideoGraphForFrame:(AVFrame *)frame {
    [self teardownVideoGraph];
    _videoGraph = avfilter_graph_alloc();
    const AVFilter *src = avfilter_get_by_name("buffer"), *sink = avfilter_get_by_name("buffersink");
    if (!_videoGraph || !src || !sink) { [self teardownVideoGraph]; return NO; }
    AVRational sar = frame->sample_aspect_ratio.num > 0 ? frame->sample_aspect_ratio : (AVRational){1, 1};
    AVRational fr = _formatCtx->streams[_videoStreamIndex]->avg_frame_rate;
    double frVal = (fr.num > 0 && fr.den > 0) ? av_q2d(fr) : 0.0;
    if (frVal < 10.0 || frVal > 120.0) {
        fr = _formatCtx->streams[_videoStreamIndex]->r_frame_rate;
        frVal = (fr.num > 0 && fr.den > 0) ? av_q2d(fr) : 0.0;
    }
    if (frVal < 10.0 || frVal > 120.0) fr = (AVRational){30000, 1001};
    NSString *args = [NSString stringWithFormat:@"video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d:frame_rate=%d/%d:colorspace=%d:range=%d",
                      frame->width, frame->height, frame->format, _videoTimeBase.num, _videoTimeBase.den, sar.num, sar.den, fr.num, fr.den, frame->colorspace, frame->color_range];
    AVFilterInOut *outputs = avfilter_inout_alloc(), *inputs = avfilter_inout_alloc();
    int err = avfilter_graph_create_filter(&_videoSrcCtx, src, "in", args.UTF8String, NULL, _videoGraph);
    if (err >= 0) err = avfilter_graph_create_filter(&_videoSinkCtx, sink, "out", NULL, NULL, _videoGraph);
    if (err >= 0 && outputs && inputs) {
        outputs->name = av_strdup("in"); outputs->filter_ctx = _videoSrcCtx; outputs->pad_idx = 0; outputs->next = NULL;
        inputs->name = av_strdup("out"); inputs->filter_ctx = _videoSinkCtx; inputs->pad_idx = 0; inputs->next = NULL;
        err = avfilter_graph_parse_ptr(_videoGraph, _videoFilterString.UTF8String, &inputs, &outputs, NULL);
    } else if (err >= 0) err = AVERROR(ENOMEM);
    avfilter_inout_free(&inputs); avfilter_inout_free(&outputs);
    if (err >= 0) err = avfilter_graph_config(_videoGraph, NULL);
    if (err < 0) {
        NSLog(@"[VPFFmpegPlayer] Video filter graph error %d for '%@'", err, _videoFilterString);
        [self teardownVideoGraph];
        return NO;
    }
    _videoFiltFrame = av_frame_alloc();
    _videoGraphWidth = frame->width; _videoGraphHeight = frame->height; _videoGraphFormat = frame->format;
    _videoGraphColorSpace = frame->colorspace;
    _videoGraphColorRange = frame->color_range;
    return YES;
}

/// Hands every frame the video filters produce for `frame` to `handler` (the frame itself when there are none).
- (void)filterVideoFrame:(AVFrame *)frame fallbackPTS:(double)fallback handler:(void (^)(AVFrame *out, double pts))handler {
    if (!_videoFilterString.length) {
        handler(frame, frame->pts != AV_NOPTS_VALUE ? frame->pts * av_q2d(_videoTimeBase) : fallback);
        return;
    }
    if (!_videoGraph || _videoGraphWidth != frame->width || _videoGraphHeight != frame->height || _videoGraphFormat != frame->format ||
        _videoGraphColorSpace != frame->colorspace || _videoGraphColorRange != frame->color_range) {
        if (![self buildVideoGraphForFrame:frame]) {   // an unusable filter must not blank the picture
            _videoFilterString = nil;
            handler(frame, frame->pts != AV_NOPTS_VALUE ? frame->pts * av_q2d(_videoTimeBase) : fallback);
            return;
        }
    }
    if (av_buffersrc_add_frame_flags(_videoSrcCtx, frame, AV_BUFFERSRC_FLAG_KEEP_REF) < 0) return;
    AVRational tb = av_buffersink_get_time_base(_videoSinkCtx);
    while (av_buffersink_get_frame(_videoSinkCtx, _videoFiltFrame) >= 0) {
        handler(_videoFiltFrame, _videoFiltFrame->pts != AV_NOPTS_VALUE ? _videoFiltFrame->pts * av_q2d(tb) : fallback);
        av_frame_unref(_videoFiltFrame);
    }
}

- (CVPixelBufferRef)pixelBufferFromFrame:(AVFrame *)frame {
    if (!frame) return NULL;
    
    // 1. Hardware-decoded via VideoToolbox
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (frame->data[3] != NULL) {
            CVPixelBufferRef hwBuffer = (CVPixelBufferRef)frame->data[3];
            if (hwBuffer && CFGetTypeID(hwBuffer) == CVPixelBufferGetTypeID()) {
                CVPixelBufferRetain(hwBuffer);
                return hwBuffer;
            }
        }
        return NULL;
    }
    
    // 2. Software decoded: convert to Metal-compatible 32BGRA IOSurface CVPixelBuffer
    int srcWidth = frame->width;
    int srcHeight = frame->height;
    if (srcWidth <= 0 || srcHeight <= 0) return NULL;
    
    int width = srcWidth;
    int height = srcHeight;
    if (_forcedAspectRatio > 0.1) {
        width = (int)llround((double)srcHeight * _forcedAspectRatio);
        if (width & 1) width++;
    } else if (frame->sample_aspect_ratio.num > 0 && frame->sample_aspect_ratio.den > 0) {
        double sar = av_q2d(frame->sample_aspect_ratio);
        if (sar > 0.2 && sar < 4.0 && fabs(sar - 1.0) > 0.02) {
            width = (int)llround((double)srcWidth * sar);
            if (width & 1) width++;
        }
    }
    
    // Maintain or create CVPixelBufferPool for high performance zero-fragmentation rendering
    if (!_pixelBufferPool || _poolWidth != (size_t)width || _poolHeight != (size_t)height) {
        if (_pixelBufferPool) {
            CVPixelBufferPoolRelease(_pixelBufferPool);
            _pixelBufferPool = NULL;
        }
        
        NSDictionary *poolAttributes = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @(MAX_QUEUED_VIDEO_FRAMES + 4) };
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES
        };
        
        CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes, (__bridge CFDictionaryRef)pixelAttributes, &_pixelBufferPool);
        if (poolStatus != kCVReturnSuccess) {
            _pixelBufferPool = NULL;
        } else {
            _poolWidth = (size_t)width;
            _poolHeight = (size_t)height;
        }
    }
    
    CVPixelBufferRef targetBuffer = NULL;
    if (_pixelBufferPool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &targetBuffer);
    }
    
    if (!targetBuffer) {
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES
        };
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelAttributes, &targetBuffer);
        if (status != kCVReturnSuccess || !targetBuffer) return NULL;
    }
    
    int swsFlags = (width != srcWidth) ? (SWS_BICUBIC | SWS_ACCURATE_RND) : SWS_FAST_BILINEAR;
    _swsCtx = sws_getCachedContext(_swsCtx, srcWidth, srcHeight, (enum AVPixelFormat)frame->format,
                                   width, height, AV_PIX_FMT_BGRA,
                                   swsFlags, NULL, NULL, NULL);
    if (!_swsCtx) {
        CVPixelBufferRelease(targetBuffer);
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(targetBuffer, 0);
    uint8_t *dstData[4] = { (uint8_t *)CVPixelBufferGetBaseAddress(targetBuffer), NULL, NULL, NULL };
    int dstLinesize[4] = { (int)CVPixelBufferGetBytesPerRow(targetBuffer), 0, 0, 0 };
    
    sws_scale(_swsCtx, (const uint8_t * const *)frame->data, frame->linesize, 0, srcHeight, dstData, dstLinesize);
    CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
    
    return targetBuffer;
}

#pragma mark - SWR Resampler Management

- (void)cleanupSwrContext {
    if (_swrCtx) {
        swr_free(&_swrCtx);
        _swrCtx = NULL;
    }
    av_channel_layout_uninit(&_swrInLayout);
    av_channel_layout_uninit(&_swrOutLayout);
    memset(&_swrInLayout, 0, sizeof(_swrInLayout));
    memset(&_swrOutLayout, 0, sizeof(_swrOutLayout));
    _swrInFmt = AV_SAMPLE_FMT_NONE;
    _swrInRate = 0;
    _swrOutRate = 0;
    _swrOutChannels = 0;
    if (_hiFiConverter) { AudioConverterDispose(_hiFiConverter); _hiFiConverter = NULL; }
}

#pragma mark - Audio Filter Graph & Decoding

- (void)teardownAudioFilterGraphLocked {
    if (_audioGraph) {
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        _audioSrcCtx = NULL;
        _audioSinkCtx = NULL;
    }
    av_channel_layout_uninit(&_filterInLayout);
    memset(&_filterInLayout, 0, sizeof(_filterInLayout));
    _filterInRate = 0;
    _filterInFmt = AV_SAMPLE_FMT_NONE;
    _currentAudioFilterGraph = nil;
    self.appleSurroundProcessor = nil;
    [self cleanupSwrContext];
}

- (void)teardownAudioFilterGraph {
    pthread_mutex_lock(&_filterMutex);
    [self teardownAudioFilterGraphLocked];
    pthread_mutex_unlock(&_filterMutex);
}

- (BOOL)setupAudioFilterGraph:(NSString *)filterGraphStr {
    pthread_mutex_lock(&_filterMutex);
    BOOL ok = [self setupAudioFilterGraphLocked:filterGraphStr inputFrame:nil];
    pthread_mutex_unlock(&_filterMutex);
    return ok;
}

- (BOOL)setupAudioFilterGraphLocked:(NSString *)filterGraphStr inputFrame:(nullable AVFrame *)inputFrame {
    [self teardownAudioFilterGraphLocked];
    
    if (!filterGraphStr || filterGraphStr.length == 0 || !_audioCodecCtx) {
        return YES;
    }
    
    _audioGraph = avfilter_graph_alloc();
    if (!_audioGraph) {
        return NO;
    }
    
    const AVFilter *abuffer = avfilter_get_by_name("abuffer");
    const AVFilter *abuffersink = avfilter_get_by_name("abuffersink");
    if (!abuffer || !abuffersink) {
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        return NO;
    }
    
    AVChannelLayout chLayout;
    memset(&chLayout, 0, sizeof(chLayout));
    if (inputFrame && inputFrame->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&chLayout, &inputFrame->ch_layout);
    } else if (_audioCodecCtx->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&chLayout, &_audioCodecCtx->ch_layout);
    } else {
        av_channel_layout_default(&chLayout, 2);
    }
    
    char chLayoutStr[128] = {0};
    av_channel_layout_describe(&chLayout, chLayoutStr, sizeof(chLayoutStr));
    if (chLayoutStr[0] == 0 || strcmp(chLayoutStr, "unknown") == 0) {
        int channels = chLayout.nb_channels > 0 ? chLayout.nb_channels : 2;
        snprintf(chLayoutStr, sizeof(chLayoutStr), "%dc", channels);
    }
    
    int sampleRate = 48000;
    if (inputFrame && inputFrame->sample_rate > 0) {
        sampleRate = inputFrame->sample_rate;
    } else if (_audioCodecCtx->sample_rate > 0) {
        sampleRate = _audioCodecCtx->sample_rate;
    }
    
    enum AVSampleFormat sampleFmt = AV_SAMPLE_FMT_FLTP;
    if (inputFrame && inputFrame->format != AV_SAMPLE_FMT_NONE) {
        sampleFmt = (enum AVSampleFormat)inputFrame->format;
    } else if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_NONE) {
        sampleFmt = _audioCodecCtx->sample_fmt;
    }
    
    AVRational timeBase = _audioTimeBase.den > 0 ? _audioTimeBase : (AVRational){1, sampleRate};
    
    char args[512];
    snprintf(args, sizeof(args),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             timeBase.num, timeBase.den, sampleRate,
             av_get_sample_fmt_name(sampleFmt), chLayoutStr);
    
    int err = avfilter_graph_create_filter(&_audioSrcCtx, abuffer, "in", args, NULL, _audioGraph);
    if (err < 0) {
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        return NO;
    }
    
    err = avfilter_graph_create_filter(&_audioSinkCtx, abuffersink, "out", NULL, NULL, _audioGraph);
    if (err < 0) {
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        return NO;
    }
    

    
    // If the filter string does not already have an alimiter, append a transparent brickwall limiter to catch peak overshoots cleanly without clipping or distortion
    NSString *effectiveGraphStr = VPResolvedSurroundGraph(filterGraphStr, &chLayout);
    if (![filterGraphStr containsString:@"alimiter"]) {
        effectiveGraphStr = [NSString stringWithFormat:@"%@,alimiter=limit=0.98:attack=5:release=50:asc=0:level=0", effectiveGraphStr];
    }
    
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs  = avfilter_inout_alloc();
    outputs->name       = av_strdup("in");
    outputs->filter_ctx = _audioSrcCtx;
    outputs->pad_idx    = 0;
    outputs->next       = NULL;
    
    inputs->name        = av_strdup("out");
    inputs->filter_ctx  = _audioSinkCtx;
    inputs->pad_idx     = 0;
    inputs->next        = NULL;
    
    err = avfilter_graph_parse_ptr(_audioGraph, effectiveGraphStr.UTF8String, &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    
    if (err < 0) {
        NSLog(@"[VPFFmpegPlayer] Audio filter graph parse error %d for '%@'", err, effectiveGraphStr);
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        _audioSrcCtx = NULL;
        _audioSinkCtx = NULL;
        return NO;
    }
    
    err = avfilter_graph_config(_audioGraph, NULL);
    if (err < 0 && ![effectiveGraphStr hasPrefix:@"aformat=channel_layouts=stereo,"]) {
        avfilter_graph_free(&_audioGraph);
        _audioGraph = avfilter_graph_alloc();
        if (_audioGraph &&
            avfilter_graph_create_filter(&_audioSrcCtx, abuffer, "in", args, NULL, _audioGraph) >= 0 &&
            avfilter_graph_create_filter(&_audioSinkCtx, abuffersink, "out", NULL, NULL, _audioGraph) >= 0) {
            NSString *stereoFallback = [@"aformat=channel_layouts=stereo," stringByAppendingString:effectiveGraphStr];
            AVFilterInOut *sOut = avfilter_inout_alloc();
            AVFilterInOut *sIn  = avfilter_inout_alloc();
            sOut->name = av_strdup("in"); sOut->filter_ctx = _audioSrcCtx; sOut->pad_idx = 0; sOut->next = NULL;
            sIn->name  = av_strdup("out"); sIn->filter_ctx = _audioSinkCtx; sIn->pad_idx = 0; sIn->next = NULL;
            err = avfilter_graph_parse_ptr(_audioGraph, stereoFallback.UTF8String, &sIn, &sOut, NULL);
            avfilter_inout_free(&sIn);
            avfilter_inout_free(&sOut);
            if (err >= 0) {
                err = avfilter_graph_config(_audioGraph, NULL);
            }
        }
    }
    if (err < 0) {
        NSLog(@"[VPFFmpegPlayer] Audio filter graph config error %d for '%@'", err, effectiveGraphStr);
        av_channel_layout_uninit(&chLayout);
        avfilter_graph_free(&_audioGraph);
        _audioGraph = NULL;
        _audioSrcCtx = NULL;
        _audioSinkCtx = NULL;
        return NO;
    }
    
    _filterInRate = sampleRate;
    _filterInFmt = sampleFmt;
    av_channel_layout_copy(&_filterInLayout, &chLayout);
    av_channel_layout_uninit(&chLayout);
    
    _currentAudioFilterGraph = [filterGraphStr copy];
    [self cleanupSwrContext];
    return YES;
}

/// The decoder runs far ahead of the speakers, so a change to how audio is processed would be heard only after the
/// buffered seconds have played. Dropping all but the last 40 ms makes it audible at once.
- (void)speakerLevelsDidChange:(NSNotification *)note {
    // The resampler picks up the new levels on the next frame (see speakerRevision), but the decoder is seconds
    // ahead of the speakers (a short file may already be fully buffered). Re-seeking to the current position
    // rebuilds that buffer with the new levels. Dragging a slider posts many changes, so they are coalesced, and
    // dropping the buffer instead would make a file that already reached its end stop playing.
    NSUInteger revision = VPAudioFilters.shared.speakerRevision;
    if (revision == _seenSpeakerRevision) return;
    _seenSpeakerRevision = revision;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySpeakerLevelsByReseeking) object:nil];
        [self performSelector:@selector(applySpeakerLevelsByReseeking) withObject:nil afterDelay:0.15];
    });
}

- (void)applySpeakerLevelsByReseeking {
    if (!_running || !_audioCodecCtx || !self.hasAudio) return;
    [self seekToSeconds:[self masterClock]];
}

- (void)dropBufferedAudioForImmediateChange {
    os_unfair_lock_lock(&_audioLock);
    int ch = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    double sr = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
    size_t keepSamples = (size_t)(sr * 0.04) * ch; // Keep 40ms to prevent AudioQueue underrun click
    if (_audioRingAvailable > keepSamples) {
        size_t droppedSamples = _audioRingAvailable - keepSamples;
        _audioRingWritePos = (_audioRingReadPos + keepSamples) % _audioRingCapacity;
        _audioRingAvailable = keepSamples;
        if (_audioWriteHeadPTS >= 0 && sr > 0 && ch > 0) {
            _audioWriteHeadPTS -= (double)(droppedSamples / ch) / sr;
            _audioClockPTS = _audioWriteHeadPTS;
        }
    }
    os_unfair_lock_unlock(&_audioLock);
}

- (void)applyAudioFiltersGraph:(nullable NSString *)graphString {
    NSString *graph = [graphString copy];
    // Re-rendering the buffered seconds can take a moment (Hi-Fidelity especially), so it never runs on the caller.
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("macvideoplayer.audio-refilter", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        pthread_mutex_lock(&self->_filterMutex);
        self->_requestedAudioFilterGraph = graph;
        [self setupAudioFilterGraphLocked:graph inputFrame:nil];
        BOOL rendered = [self refeedRetainedAudioLocked];
        pthread_mutex_unlock(&self->_filterMutex);
        // Without retained audio, local files drop their read-ahead to make the change audible at once. A network
        // stream keeps it: it only receives sound as fast as it plays, so a dropped buffer would never refill.
        if (!rendered && !self->_isNetworkSource) [self dropBufferedAudioForImmediateChange];
    });
}

/// Scales each input channel by its speaker group's trim inside the resampler's remix matrix, so the trims apply
/// to the real speaker channels and still carry through a downmix to fewer outputs.
/// Input callback for the Apple converter: hands over the block once, then reports that no more is available.
typedef struct { const float *samples; UInt32 frames; UInt32 channels; BOOL consumed; } VPHiFiInput;

static OSStatus VPHiFiInputProc(AudioConverterRef converter, UInt32 *ioPackets, AudioBufferList *ioData,
                                AudioStreamPacketDescription **packetDescriptions, void *userData) {
    VPHiFiInput *input = userData;
    if (input->consumed || input->frames == 0) { *ioPackets = 0; return 'more'; }
    input->consumed = YES;
    *ioPackets = input->frames;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = input->channels;
    ioData->mBuffers[0].mDataByteSize = input->frames * input->channels * sizeof(float);
    ioData->mBuffers[0].mData = (void *)input->samples;
    return noErr;
}

/// Converts interleaved float PCM between sample rates with Apple's AudioConverter at its mastering complexity and
/// maximum quality, the highest-grade sample-rate converter in CoreAudio. Returns a malloc'd buffer (nil on failure).
- (float *)hiFiResample:(const float *)samples frames:(int)frames channels:(int)channels fromRate:(double)inRate toRate:(double)outRate outFrames:(int *)outFrames {
    *outFrames = 0;
    if (_hiFiConverter && (_hiFiInRate != inRate || _hiFiOutRate != outRate || _hiFiChannels != channels)) {
        AudioConverterDispose(_hiFiConverter);
        _hiFiConverter = NULL;
    }
    if (!_hiFiConverter) {
        AudioStreamBasicDescription source = {0}, destination = {0};
        source.mFormatID = destination.mFormatID = kAudioFormatLinearPCM;
        source.mFormatFlags = destination.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        source.mChannelsPerFrame = destination.mChannelsPerFrame = (UInt32)channels;
        source.mBitsPerChannel = destination.mBitsPerChannel = 32;
        source.mFramesPerPacket = destination.mFramesPerPacket = 1;
        source.mBytesPerFrame = destination.mBytesPerFrame = (UInt32)channels * sizeof(float);
        source.mBytesPerPacket = destination.mBytesPerPacket = source.mBytesPerFrame;
        source.mSampleRate = inRate;
        destination.mSampleRate = outRate;
        if (AudioConverterNew(&source, &destination, &_hiFiConverter) != noErr) { _hiFiConverter = NULL; return NULL; }
        // Mastering complexity is very heavy. A network stream has no spare time to decode ahead, so it starts on the
        // lighter converter, and any source drops to it if mastering proves slower than playback (see below).
        if (_isNetworkSource) _hiFiLight = YES;
        UInt32 complexity = _hiFiLight ? kAudioConverterSampleRateConverterComplexity_Normal : kAudioConverterSampleRateConverterComplexity_Mastering;
        AudioConverterSetProperty(_hiFiConverter, kAudioConverterSampleRateConverterComplexity, sizeof(complexity), &complexity);
        UInt32 quality = _hiFiLight ? kAudioConverterQuality_High : kAudioConverterQuality_Max;
        AudioConverterSetProperty(_hiFiConverter, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);
        _hiFiInRate = inRate; _hiFiOutRate = outRate; _hiFiChannels = channels;
    }
    UInt32 capacity = (UInt32)ceil((double)frames * outRate / inRate) + 512;
    float *output = malloc((size_t)capacity * channels * sizeof(float));
    if (!output) return NULL;
    VPHiFiInput input = { samples, (UInt32)frames, (UInt32)channels, NO };
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = (UInt32)channels;
    list.mBuffers[0].mDataByteSize = capacity * channels * sizeof(float);
    list.mBuffers[0].mData = output;
    UInt32 produced = capacity;
    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    OSStatus status = AudioConverterFillComplexBuffer(_hiFiConverter, VPHiFiInputProc, &input, &produced, &list, NULL);
    if (status != noErr && status != 'more') { free(output); return NULL; }
    *outFrames = (int)produced;
    // Converting slower than half of real time starves the speakers (stuck buffering, then a tone): go lighter.
    double spent = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9;
    if (!_hiFiLight && inRate > 0 && spent > 0.5 * (double)frames / inRate) {
        _hiFiLight = YES;
        AudioConverterDispose(_hiFiConverter);
        _hiFiConverter = NULL;   // rebuilt on the next block with the lighter settings
    }
    return output;
}

- (void)applySpeakerLevelsToResampler:(SwrContext *)swr inLayout:(const AVChannelLayout *)inLayout outLayout:(const AVChannelLayout *)outLayout {
    VPAudioFilters *filters = VPAudioFilters.shared;
    if (!filters.hasSpeakerLevels) return;
    int inCount = inLayout->nb_channels, outCount = outLayout->nb_channels;
    if (inCount <= 0 || outCount <= 0) return;
    double *matrix = calloc((size_t)inCount * outCount, sizeof(double));
    if (!matrix) return;
    // The defaults libswresample would use itself, so an unadjusted channel sounds exactly as before.
    if (swr_build_matrix2(inLayout, outLayout, M_SQRT1_2, M_SQRT1_2, 0.0, 1.0, 1.0, matrix, inCount, AV_MATRIX_ENCODING_NONE, NULL) >= 0) {
        for (int i = 0; i < inCount; i++) {
            NSString *group = VPSpeakerGroupForChannelIndex(inLayout, i);
            double decibels = group ? [filters levelForSpeakerGroup:group] : 0.0;
            if (fabs(decibels) < 0.05) continue;
            double gain = pow(10.0, decibels / 20.0);
            for (int o = 0; o < outCount; o++) matrix[(size_t)o * inCount + i] *= gain;
        }
        swr_set_matrix(swr, matrix, inCount);
    }
    free(matrix);
}

- (void)resampleAndEnqueueAudioFrame:(AVFrame *)frame timeBase:(AVRational)timeBase {
    if (!frame || frame->nb_samples <= 0) return;
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (ai.audioAIEnabled && ([ai.surroundMethod isEqual:@"apple_51"] || [ai.surroundMethod isEqual:@"apple_71"])) {
        if (!self.appleSurroundProcessor) self.appleSurroundProcessor = [VPAppleSurroundProcessor new];
        self.appleSurroundProcessor.surroundFill = ai.surroundFill;
        frame = [self.appleSurroundProcessor processFrame:frame layout:[ai.surroundMethod isEqual:@"apple_71"] ? @"7.1" : @"5.1"];
    } else {
        self.appleSurroundProcessor = nil;
    }
    int inRate = frame->sample_rate > 0 ? frame->sample_rate : (_audioCodecCtx->sample_rate > 0 ? _audioCodecCtx->sample_rate : 48000);
    int targetRate = (int)_audioFormat.mSampleRate > 0 ? (int)_audioFormat.mSampleRate : 48000;
    int targetChannels = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    // Hi-Fidelity hands the rate change to Apple's converter: libswresample then only remixes at the source rate.
    BOOL appleSRC = ai.audioAIEnabled && ai.hiFiAudio && inRate != targetRate;
    int swrRate = appleSRC ? inRate : targetRate;
    enum AVSampleFormat inFmt = (enum AVSampleFormat)frame->format;
    
    AVChannelLayout inLayout;
    if (frame->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&inLayout, &frame->ch_layout);
    } else {
        av_channel_layout_default(&inLayout, 2);
    }
    
    AVChannelLayout outLayout = {0};
    if (_audioOutputMask) av_channel_layout_from_mask(&outLayout, _audioOutputMask);
    else av_channel_layout_default(&outLayout, targetChannels);
    
    BOOL needsReinit = NO;
    if (!_swrCtx) {
        needsReinit = YES;
    } else if (_swrInFmt != inFmt ||
               _swrInRate != inRate ||
               _swrOutRate != swrRate ||
               _swrOutChannels != targetChannels ||
               _swrSpeakerRevision != VPAudioFilters.shared.speakerRevision ||
               av_channel_layout_compare(&_swrInLayout, &inLayout) != 0 ||
               av_channel_layout_compare(&_swrOutLayout, &outLayout) != 0) {
        needsReinit = YES;
    }
    
    if (needsReinit) {
        [self cleanupSwrContext];
        
        _swrInFmt = inFmt;
        _swrInRate = inRate;
        _swrOutRate = swrRate;
        _swrOutChannels = targetChannels;
        _swrSpeakerRevision = VPAudioFilters.shared.speakerRevision;
        av_channel_layout_copy(&_swrInLayout, &inLayout);
        av_channel_layout_copy(&_swrOutLayout, &outLayout);
        
        swr_alloc_set_opts2(&_swrCtx,
                            &outLayout,
                            AV_SAMPLE_FMT_FLT,
                            swrRate,
                            &inLayout,
                            inFmt,
                            inRate,
                            0, NULL);
        if (_swrCtx) {
            av_opt_set_double(_swrCtx, "rematrix_maxval", 1.0, 0);
            // High-quality resampling: a longer, finer filter with a wider passband than the library defaults.
            av_opt_set_int(_swrCtx, "filter_size", 64, 0);
            av_opt_set_int(_swrCtx, "phase_shift", 12, 0);
            av_opt_set_double(_swrCtx, "cutoff", 0.985, 0);
            av_opt_set_double(_swrCtx, "precision", 28, 0);
            [self applySpeakerLevelsToResampler:_swrCtx inLayout:&inLayout outLayout:&outLayout];
            swr_init(_swrCtx);
        }
    }
    av_channel_layout_uninit(&inLayout);
    av_channel_layout_uninit(&outLayout);
    
    if (!_swrCtx) return;
    
    int64_t delay = swr_get_delay(_swrCtx, inRate);
    int outSamples = (int)av_rescale_rnd(delay + frame->nb_samples, swrRate, inRate, AV_ROUND_UP);
    if (outSamples <= 0) return;
    
    float *outBuffer = (float *)malloc((outSamples + 256) * targetChannels * sizeof(float));
    if (!outBuffer) return;
    uint8_t *outPlanes[1] = { (uint8_t *)outBuffer };
    
    const uint8_t **inPlanes = (const uint8_t **)(frame->extended_data ? frame->extended_data : frame->data);
    int converted = swr_convert(_swrCtx, outPlanes, outSamples + 256, inPlanes, frame->nb_samples);
    if (converted > 0 && appleSRC) {
        int appleFrames = 0;
        float *appleBuffer = [self hiFiResample:outBuffer frames:converted channels:targetChannels fromRate:inRate toRate:targetRate outFrames:&appleFrames];
        free(outBuffer);
        outBuffer = appleBuffer;
        converted = appleFrames;
    }
    if (converted > 0 && outBuffer) {
        AVRational tb = timeBase.den > 0 ? timeBase : _audioTimeBase;
        double pts = (frame->pts != AV_NOPTS_VALUE) ? (frame->pts * av_q2d(tb)) : _audioClockPTS;
        // swr output begins with samples retained from the previous input.
        if (_isDiscMedia && frame->pts != AV_NOPTS_VALUE) pts -= (double)delay / inRate;
        [self enqueueAudioSamples:outBuffer count:converted * targetChannels pts:pts];
    }
    free(outBuffer);
}

- (void)resampleAndEnqueueAudioFrame:(AVFrame *)frame {
    [self resampleAndEnqueueAudioFrame:frame timeBase:_audioTimeBase];
}

- (void)decodeAudioPacket:(AVPacket *)packet frame:(AVFrame *)frame {
    int ret = avcodec_send_packet(_audioCodecCtx, packet);
    if (ret < 0) return;
    
    double tbSec = av_q2d(_audioTimeBase);
    
    while (ret >= 0) {
        ret = avcodec_receive_frame(_audioCodecCtx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;
        
        int inRate = frame->sample_rate > 0 ? frame->sample_rate : (_audioCodecCtx->sample_rate > 0 ? _audioCodecCtx->sample_rate : 48000);
        double frameDur = (frame->nb_samples > 0 && inRate > 0) ? ((double)frame->nb_samples / (double)inRate) : 0.032;
        int64_t rawTS = (frame->best_effort_timestamp != AV_NOPTS_VALUE) ? frame->best_effort_timestamp : frame->pts;
        double normPTS = _nextDecodedAudioPTS;
        
        if (rawTS != AV_NOPTS_VALUE && tbSec > 0) {
            double rawSec = rawTS * tbSec;
            if (_lastRawAudioPTS < 0) {
                if (_streamStartPTS == 0.0 && rawSec > 0.5 && _nextDecodedAudioPTS == 0.0) {
                    _streamStartPTS = rawSec;
                    _audioPTSOffset = -rawSec;
                    if (_lastRawVideoPTS < 0) _videoPTSOffset = -rawSec;
                }
            } else {
                double delta = rawSec - _lastRawAudioPTS;
                if (delta < -0.25 || delta > 1.5) {
                    if (self.hasVideo && fabs(_videoPTSOffset - (_nextDecodedAudioPTS - rawSec)) < 0.5) {
                        _audioPTSOffset = _videoPTSOffset;
                    } else {
                        _audioPTSOffset = _nextDecodedAudioPTS - rawSec;
                    }
                }
            }
            _lastRawAudioPTS = rawSec;
            normPTS = rawSec + _audioPTSOffset;
            if (normPTS < 0.0) normPTS = 0.0;
        }
        
        _nextDecodedAudioPTS = normPTS + frameDur;
        if (tbSec > 0) {
            frame->pts = (int64_t)llround(normPTS / tbSec);
        }
        
        if (_audioStartPTS < 0 && normPTS < _audioBasePTS - 0.15) {
            continue;
        }
        
        pthread_mutex_lock(&_filterMutex);
        [self retainAudioFrameForRefilter:frame];
        [self pushAudioFrameThroughFiltersLocked:frame];
        pthread_mutex_unlock(&_filterMutex);
    }
}

/// Runs one decoded frame through the audio filter graph into the speaker ring. The caller holds `_filterMutex`.
- (void)pushAudioFrameThroughFiltersLocked:(AVFrame *)frame {
    if ((_audioGraph == NULL || _audioSrcCtx == NULL || _audioSinkCtx == NULL) && _requestedAudioFilterGraph.length > 0) {
        [self setupAudioFilterGraphLocked:_requestedAudioFilterGraph inputFrame:frame];
    }
    if (_audioGraph != NULL && _audioSrcCtx != NULL && _audioSinkCtx != NULL) {
        BOOL needsFilterRebuild = NO;
        if (_filterInRate > 0 && frame->sample_rate > 0 && frame->sample_rate != _filterInRate) {
            needsFilterRebuild = YES;
        }
        if (_filterInFmt != AV_SAMPLE_FMT_NONE && frame->format != AV_SAMPLE_FMT_NONE && frame->format != _filterInFmt) {
            needsFilterRebuild = YES;
        }
        if (_filterInLayout.nb_channels > 0 && frame->ch_layout.nb_channels > 0 &&
            av_channel_layout_compare(&_filterInLayout, &frame->ch_layout) != 0) {
            needsFilterRebuild = YES;
        }
        NSString *targetGraph = _requestedAudioFilterGraph ?: _currentAudioFilterGraph;
        if (needsFilterRebuild && targetGraph.length > 0) {
            [self setupAudioFilterGraphLocked:[targetGraph copy] inputFrame:frame];
        }
        
        int sRet = av_buffersrc_add_frame_flags(_audioSrcCtx, frame, AV_BUFFERSRC_FLAG_KEEP_REF);
        if (sRet >= 0) {
            AVFrame *filtFrame = av_frame_alloc();
            AVRational sinkTB = av_buffersink_get_time_base(_audioSinkCtx);
            while (1) {
                int gRet = av_buffersink_get_frame(_audioSinkCtx, filtFrame);
                if (gRet == AVERROR(EAGAIN) || gRet == AVERROR_EOF) break;
                if (gRet < 0) break;
                [self resampleAndEnqueueAudioFrame:filtFrame timeBase:sinkTB];
                av_frame_unref(filtFrame);
            }
            av_frame_free(&filtFrame);
        } else {
            [self resampleAndEnqueueAudioFrame:frame timeBase:_audioTimeBase];
        }
    } else {
        [self resampleAndEnqueueAudioFrame:frame timeBase:_audioTimeBase];
    }
}

#pragma mark - Instant audio changes

/// Decoded audio that has not been heard yet is kept, before any filtering, so that a change to the filter chain can
/// be applied to it at once: the new chain re-renders what is buffered instead of waiting for it to play out or
/// throwing it away (a network stream could not refill a dropped buffer).
- (void)retainAudioFrameForRefilter:(AVFrame *)frame {
    if (_isDiscMedia || frame->nb_samples <= 0 || frame->sample_rate <= 0) return;
    AVFrame *clone = av_frame_clone(frame);
    if (!clone) return;
    os_unfair_lock_lock(&_audioLock);
    double sr = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
    int ch = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    double ringStart = _audioWriteHeadPTS >= 0 ? _audioWriteHeadPTS - (double)_audioRingAvailable / (sr * ch) : -1;
    os_unfair_lock_unlock(&_audioLock);
    double tb = av_q2d(_audioTimeBase);
    os_unfair_lock_lock(&_audioRetainLock);
    if (!_retainedAudio) _retainedAudio = [NSMutableArray array];
    [_retainedAudio addObject:[NSValue valueWithPointer:clone]];
    // Forget what has already played, and never hold more than 20 seconds.
    while (_retainedAudio.count > 1) {
        AVFrame *first = [_retainedAudio.firstObject pointerValue];
        double end = (double)first->pts * tb + (double)first->nb_samples / first->sample_rate;
        double newest = (double)clone->pts * tb;
        if (end < ringStart - 0.5 || (ringStart < 0 && end < newest - 20.0) || end < newest - 20.0) {
            av_frame_free(&first);
            [_retainedAudio removeObjectAtIndex:0];
        } else break;
    }
    os_unfair_lock_unlock(&_audioRetainLock);
}

- (void)clearRetainedAudio {
    os_unfair_lock_lock(&_audioRetainLock);
    for (NSValue *value in _retainedAudio) { AVFrame *f = value.pointerValue; av_frame_free(&f); }
    [_retainedAudio removeAllObjects];
    os_unfair_lock_unlock(&_audioRetainLock);
}

/// Replaces the buffered (already filtered) audio with the retained frames filtered by the current graph. The caller
/// holds `_filterMutex`. Returns NO when nothing could be re-rendered.
- (BOOL)refeedRetainedAudioLocked {
    if (_isDiscMedia || !_audioFormat.mSampleRate) return NO;
    double sr = _audioFormat.mSampleRate;
    int ch = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    double tb = av_q2d(_audioTimeBase);
    os_unfair_lock_lock(&_audioRetainLock);
    NSArray<NSValue *> *frames = [_retainedAudio copy];
    os_unfair_lock_unlock(&_audioRetainLock);
    if (!frames.count) return NO;

    os_unfair_lock_lock(&_audioLock);
    double head = _audioWriteHeadPTS;
    if (head < 0 || _audioRingCapacity == 0) { os_unfair_lock_unlock(&_audioLock); return NO; }
    double ringStart = head - (double)_audioRingAvailable / (sr * ch);
    // Keep 50 ms of the old sound so the speakers never run dry, cut at the start of a retained frame.
    NSUInteger startIndex = NSNotFound;
    for (NSUInteger i = 0; i < frames.count; i++) {
        AVFrame *f = frames[i].pointerValue;
        if ((double)f->pts * tb >= ringStart + 0.05) { startIndex = i; break; }
    }
    if (startIndex == NSNotFound) { os_unfair_lock_unlock(&_audioLock); return NO; }
    double cut = (double)((AVFrame *)frames[startIndex].pointerValue)->pts * tb;
    if (cut < head - 0.001) {
        size_t keep = (size_t)llround((cut - ringStart) * sr) * ch;
        if (keep < _audioRingAvailable) {
            _audioRingWritePos = (_audioRingReadPos + keep) % _audioRingCapacity;
            _audioRingAvailable = keep;
            _audioWriteHeadPTS = cut;
            _audioClockPTS = cut;
        }
    } else {
        // The ring ends before the first frame this far on; continue from the first frame at or after its end.
        startIndex = NSNotFound;
        for (NSUInteger i = 0; i < frames.count; i++) {
            if ((double)((AVFrame *)frames[i].pointerValue)->pts * tb >= head - 0.001) { startIndex = i; break; }
        }
    }
    os_unfair_lock_unlock(&_audioLock);
    if (startIndex == NSNotFound) return YES;
    for (NSUInteger i = startIndex; i < frames.count; i++) [self pushAudioFrameThroughFiltersLocked:frames[i].pointerValue];
    return YES;
}

- (void)enqueueAudioSamples:(const float *)samples count:(int)count pts:(double)pts {
    if (count <= 0) return;
    
    int channels = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    double sampleRate = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
    size_t gapFrames = 0;
    if (_isDiscMedia) {
        // Keep the PCM ring on a continuous media timeline. Missing decoded
        // audio becomes timed silence; overlapping samples are not played twice.
        os_unfair_lock_lock(&_audioLock);
        double expectedPTS = _audioWriteHeadPTS;
        os_unfair_lock_unlock(&_audioLock);
        if (expectedPTS >= 0 && pts >= 0) {
            double delta = pts - expectedPTS;
            // Timestamps of consecutive frames wander by a few milliseconds; splicing in silence or dropping samples
            // for that is audible as a flutter, so only real gaps and overlaps (over 15 ms) are corrected.
            if (delta > 0.015 && delta <= 1.5) gapFrames = (size_t)llround(delta * sampleRate);
            if (delta < -0.015 && delta >= -1.5) {
                size_t trim = MIN((size_t)llround(-delta * sampleRate), (size_t)(count / channels));
                samples += trim * channels;
                count -= (int)(trim * channels);
                if (count == 0) return;
            }
            pts = expectedPTS + (double)gapFrames / sampleRate;
        }
        // Backpressure belongs on the decoder thread, never the audio callback.
        // Preserve samples instead of silently truncating a full ring.
        size_t required = (gapFrames + (size_t)(count / channels)) * channels;
        if (required > _audioRingCapacity) return;
        for (;;) {
            os_unfair_lock_lock(&_audioLock);
            BOOL room = _audioRingCapacity - _audioRingAvailable >= required;
            os_unfair_lock_unlock(&_audioLock);
            if (room) break;
            if (!_running || _seekRequested || _abortDemux) return;
            [NSThread sleepForTimeInterval:0.005];
        }
    }
    os_unfair_lock_lock(&_audioLock);
    if (_audioStartPTS < 0 && pts >= 0) {
        _audioStartPTS = pts;
        _discAudioUnavailable = NO;
        _audioBasePTS = pts;
        _audioQueueSampleTimeOffset = -1.0;
        _wallClockBasePTS = pts;
        _wallClockMachStart = mach_absolute_time();
    }
    
    for (size_t i = 0; i < gapFrames * channels; i++) {
        _audioRingBuffer[_audioRingWritePos] = 0.0f;
        _audioRingWritePos = (_audioRingWritePos + 1) % _audioRingCapacity;
    }
    _audioRingAvailable += gapFrames * channels;
    size_t framesAvailable = (_audioRingCapacity - _audioRingAvailable) / channels;
    size_t framesToWrite = MIN((size_t)(count / channels), framesAvailable);
    size_t samplesToWrite = framesToWrite * channels;
    
    for (size_t i = 0; i < samplesToWrite; i++) {
        float s = samples[i];
        if (isnan(s) || isinf(s)) {
            s = 0.0f;
        } else if (s > 0.95f) {
            // Smooth soft-knee saturation with continuous C1 derivative up to 1.0 to eliminate step discontinuities
            s = 0.95f + 0.05f * tanhf((s - 0.95f) / 0.05f);
            if (s > 1.0f) s = 1.0f;
        } else if (s < -0.95f) {
            s = -0.95f - 0.05f * tanhf((-s - 0.95f) / 0.05f);
            if (s < -1.0f) s = -1.0f;
        }
        _audioRingBuffer[_audioRingWritePos] = s;
        _audioRingWritePos = (_audioRingWritePos + 1) % _audioRingCapacity;
    }
    _audioRingAvailable += samplesToWrite;
    if (pts >= 0) {
        _audioClockPTS = pts;
        _audioWriteHeadPTS = pts + ((double)framesToWrite / sampleRate);
    } else if (_audioWriteHeadPTS >= 0) {
        _audioWriteHeadPTS += ((double)framesToWrite / sampleRate);
        _audioClockPTS = _audioWriteHeadPTS;
    }
    size_t availAfterWrite = _audioRingAvailable;
    os_unfair_lock_unlock(&_audioLock);
    
    // Prime AudioQueue once enough samples are buffered so startup does not immediately underrun
    if (_audioQueue) {
        size_t minStartupSamples = _isDiscMedia
            ? (size_t)(sampleRate * channels * 0.65)
            : (size_t)((AUDIO_BUFFER_SIZE / sizeof(float)) * 2);
        // Streams collect kNetworkPrerollSeconds of sound before the first one is played.
        if (_isNetworkSource) minStartupSamples = MAX(minStartupSamples, (size_t)(sampleRate * channels * kNetworkPrerollSeconds));
        if ((!_isDiscMedia && _audioQueueStarted) || availAfterWrite >= minStartupSamples || _eofReached) {
            for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
                if ((_isDiscMedia || _audioBuffers[i]->mAudioDataByteSize == 0) && _audioRingAvailable > 0) {
                    [self fillAudioBuffer:_audioBuffers[i]];
                }
            }
            if (!_audioQueueStarted && self.isPlaying && !self.isPaused) {
                _audioQueueStarted = YES;
                AudioQueueStart(_audioQueue, NULL);
            }
        }
    }
}

#pragma mark - Live Subtitle Decoding (DVD/Blu-ray Bitmap + Text)

- (void)decodeSubtitlePacket:(AVPacket *)packet {
    if (!_subtitleCodecCtx || !packet) return;
    AVSubtitle sub;
    memset(&sub, 0, sizeof(sub));
    int gotSub = 0;
    int ret = avcodec_decode_subtitle2(_subtitleCodecCtx, &sub, &gotSub, packet);
    if (ret < 0 || !gotSub) {
        return;
    }
    // Presentation window on the normalized media timeline. Without a timestamp the subtitle is shown right away.
    double rawStart = sub.pts != AV_NOPTS_VALUE ? (double)sub.pts / AV_TIME_BASE
                    : (packet->pts != AV_NOPTS_VALUE ? packet->pts * av_q2d(_subtitleTimeBase) : NAN);
    double startPTS = isnan(rawStart) ? [self masterClock] : rawStart + _videoPTSOffset + (double)sub.start_display_time / 1000.0;
    double endPTS = startPTS + ((sub.end_display_time > sub.start_display_time && sub.end_display_time < 60000)
                                ? (double)(sub.end_display_time - sub.start_display_time) / 1000.0 : 5.0);
    if (sub.num_rects == 0) {
        [self queueSubtitleImage:nil text:nil start:startPTS end:startPTS];
        avsubtitle_free(&sub);
        return;
    }

    AVSubtitleRect *firstRect = sub.rects[0];
    if (firstRect->type == SUBTITLE_BITMAP) {
        int canvasW = (_videoCodecCtx && _videoCodecCtx->width > 0) ? _videoCodecCtx->width : 720;
        int canvasH = (_videoCodecCtx && _videoCodecCtx->height > 0) ? _videoCodecCtx->height : 480;
        for (unsigned rIdx = 0; rIdx < sub.num_rects; rIdx++) {
            AVSubtitleRect *r = sub.rects[rIdx];
            if (r->x + r->w > canvasW) canvasW = r->x + r->w;
            if (r->y + r->h > canvasH) canvasH = r->y + r->h;
        }
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:canvasW
                          pixelsHigh:canvasH
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                        bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                         bytesPerRow:canvasW * 4
                        bitsPerPixel:32];
        uint8_t *dstPixels = rep.bitmapData;
        if (dstPixels) {
            memset(dstPixels, 0, (size_t)canvasW * (size_t)canvasH * 4);
            for (unsigned rIdx = 0; rIdx < sub.num_rects; rIdx++) {
                AVSubtitleRect *r = sub.rects[rIdx];
                if (r->type != SUBTITLE_BITMAP || !r->data[0] || r->w <= 0 || r->h <= 0) continue;
                const uint32_t *pal = (const uint32_t *)r->data[1];
                BOOL needsFallbackPalette = NO;
                if (pal && r->nb_colors <= 4) {
                    int visibleWhiteCount = 0;
                    for (int c = 0; c < r->nb_colors; c++) {
                        uint32_t argb = pal[c];
                        uint8_t a = (argb >> 24) & 0xFF;
                        uint8_t rv = (argb >> 16) & 0xFF;
                        uint8_t gv = (argb >> 8) & 0xFF;
                        uint8_t bv = argb & 0xFF;
                        if (a > 0 && (rv > 40 || gv > 40 || bv > 40)) {
                            visibleWhiteCount++;
                        }
                    }
                    if (visibleWhiteCount == 0) {
                        needsFallbackPalette = YES;
                    }
                }
                int rx = MAX(0, r->x);
                int ry = MAX(0, r->y);
                int rw = MIN(r->w, canvasW - rx);
                int rh = MIN(r->h, canvasH - ry);
                int srcStride = r->linesize[0] > 0 ? r->linesize[0] : r->w;
                for (int y = 0; y < rh; y++) {
                    const uint8_t *srcRow = r->data[0] + y * srcStride;
                    uint8_t *dstRow = dstPixels + ((ry + y) * canvasW + rx) * 4;
                    for (int x = 0; x < rw; x++) {
                        uint8_t idx = srcRow[x];
                        uint32_t argb = pal ? pal[idx] : 0;
                        uint8_t a = (argb >> 24) & 0xFF;
                        if (a == 0) continue;
                        uint8_t red = (argb >> 16) & 0xFF;
                        uint8_t green = (argb >> 8) & 0xFF;
                        uint8_t blue = argb & 0xFF;
                        if (needsFallbackPalette) {
                            if (_hasClutPalette && idx < 16) {
                                uint32_t clut = _clutPalette[idx];
                                red = (clut >> 24) & 0xFF;
                                green = (clut >> 16) & 0xFF;
                                blue = (clut >> 8) & 0xFF;
                            }
                            if (red < 30 && green < 30 && blue < 30) {
                                if (idx == 1 || idx == 3) {
                                    red = 255; green = 255; blue = 255;
                                } else {
                                    red = 0; green = 0; blue = 0;
                                }
                            }
                        }
                        dstRow[x * 4 + 0] = red;
                        dstRow[x * 4 + 1] = green;
                        dstRow[x * 4 + 2] = blue;
                        dstRow[x * 4 + 3] = a;
                    }
                }
            }
            NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(canvasW, canvasH)];
            [img addRepresentation:rep];
            [self queueSubtitleImage:img text:nil start:startPTS end:endPTS];
        }
    } else {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (unsigned rIdx = 0; rIdx < sub.num_rects; rIdx++) {
            AVSubtitleRect *r = sub.rects[rIdx];
            NSString *raw = nil;
            if (r->text && r->text[0]) {
                raw = [NSString stringWithUTF8String:r->text];
            } else if (r->ass && r->ass[0]) {
                NSString *ass = [NSString stringWithUTF8String:r->ass];
                NSArray<NSString *> *parts = [ass componentsSeparatedByString:@","];
                if (parts.count >= 9) {
                    raw = [[parts subarrayWithRange:NSMakeRange(8, parts.count - 8)] componentsJoinedByString:@","];
                } else {
                    raw = ass;
                }
            }
            if (raw.length) {
                raw = [raw stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
                raw = [raw stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\{[^\\}]*\\}" options:0 error:nil];
                raw = [re stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
                raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (raw.length) [lines addObject:raw];
            }
        }
        NSString *joined = [lines componentsJoinedByString:@"\n"];
        [self queueSubtitleImage:nil text:joined.length ? joined : nil start:startPTS end:endPTS];
    }
    avsubtitle_free(&sub);
}

- (void)queueSubtitleImage:(NSImage *)image text:(NSString *)text start:(double)start end:(double)end {
    NSDictionary *event = @{@"start": @(start), @"end": @(end), @"image": image ?: NSNull.null, @"text": text ?: NSNull.null};
    @synchronized (_pendingSubtitles) {
        [_pendingSubtitles addObject:event];
    }
}

/// Shows the newest subtitle whose start time has been reached and drops the ones it supersedes. A subtitle that
/// already ended (for example one decoded while seeking forward) is skipped rather than flashed on screen.
- (void)presentDueSubtitlesAtClock:(double)clock {
    NSDictionary *due = nil;
    @synchronized (_pendingSubtitles) {
        NSUInteger consumed = 0;
        for (NSDictionary *event in _pendingSubtitles) {
            if ([event[@"start"] doubleValue] > clock) break;
            due = event;
            consumed++;
        }
        if (consumed) [_pendingSubtitles removeObjectsInRange:NSMakeRange(0, consumed)];
    }
    if (!due) return;
    NSImage *image = [due[@"image"] isKindOfClass:NSImage.class] ? due[@"image"] : nil;
    NSString *text = [due[@"text"] isKindOfClass:NSString.class] ? due[@"text"] : nil;
    double end = [due[@"end"] doubleValue];
    if ((!image && !text) || end <= clock) {
        if (_subtitleVisible && self.subtitleHandler) self.subtitleHandler(nil, nil);
        _subtitleVisible = NO;
        _subtitleClearPTS = -1.0;
        return;
    }
    _subtitleVisible = YES;
    _subtitleClearPTS = end;
    if (self.subtitleHandler) self.subtitleHandler(image, text);
}

- (void)audioBufferReturned:(AudioQueueBufferRef)buffer {
    os_unfair_lock_lock(&_audioLock);
    for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
        if (_audioBuffers[i] == buffer) _audioBufferQueued[i] = NO;
    }
    os_unfair_lock_unlock(&_audioLock);
    [self fillAudioBuffer:buffer];
}

/// Gives the visualizer the sound as it is handed to the speakers (not as it was decoded, which is seconds earlier).
- (void)tapPlayedAudio:(const float *)samples frames:(size_t)frames channels:(int)channels {
    void (^tap)(const float *, NSUInteger, NSUInteger) = self.audioSamplesHandler;
    if (tap && frames > 0 && channels > 0) tap(samples, (NSUInteger)frames, (NSUInteger)channels);
}

- (void)fillAudioBuffer:(AudioQueueBufferRef)buffer {
    if (!_audioQueue || !_running || !self.isPlaying) return;
    
    if (_seeking) return;
    if (_isDiscMedia) {
        os_unfair_lock_lock(&_audioLock);
        int index = -1;
        for (int i = 0; i < AUDIO_BUFFER_COUNT; i++) {
            if (_audioBuffers[i] == buffer) { index = i; break; }
        }
        if (index < 0 || _audioBufferQueued[index]) {
            os_unfair_lock_unlock(&_audioLock);
            return;
        }
        int channels = MAX(1, (int)_audioFormat.mChannelsPerFrame);
        double rate = _audioFormat.mSampleRate;
        size_t frames = MIN((size_t)llround(rate * 0.05),
                            buffer->mAudioDataBytesCapacity / (sizeof(float) * channels));
        size_t available = _audioRingAvailable / channels;
        // Hysteresis prevents a slow drive from producing repeated short bursts.
        if (_discAudioRecovering && (available >= (size_t)(rate * 0.35) || _eofReached)) {
            _discAudioRecovering = NO;
        }
        size_t copied = _discAudioRecovering ? 0 : MIN(frames, available);
        double pts = copied && _audioWriteHeadPTS >= 0
            ? _audioWriteHeadPTS - (double)available / rate : _discAudioSync.mediaEnd;
        float *dst = buffer->mAudioData;
        for (size_t i = 0; i < copied * channels; i++) {
            dst[i] = _audioRingBuffer[(_audioRingReadPos + i) % _audioRingCapacity];
        }
        memset(dst + copied * channels, 0, (frames - copied) * channels * sizeof(float));
        buffer->mAudioDataByteSize = (UInt32)(frames * channels * sizeof(float));
        // Commit the clock map and ring consumption only after enqueue succeeds.
        OSStatus status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
        if (status == noErr) {
            _audioBufferQueued[index] = YES;
            _audioRingReadPos = (_audioRingReadPos + copied * channels) % _audioRingCapacity;
            _audioRingAvailable -= copied * channels;
            VPAudioSyncAppend(&_discAudioSync, pts, copied, frames, rate);
            _audioQueueEnqueuedEndPTS = _discAudioSync.mediaEnd;
            if (copied < frames && !_eofReached) _discAudioRecovering = YES;
        } else {
            buffer->mAudioDataByteSize = 0;
            copied = 0;
        }
        os_unfair_lock_unlock(&_audioLock);
        [self tapPlayedAudio:dst frames:copied channels:channels];
        return;
    }
    os_unfair_lock_lock(&_audioLock);
    int channels = (int)_audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
    double sampleRate = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
    size_t requestedFrames = (buffer->mAudioDataBytesCapacity / sizeof(float)) / channels;
    size_t availableFrames = _audioRingAvailable / channels;
    size_t framesToCopy = MIN(requestedFrames, availableFrames);
    size_t samplesToCopy = framesToCopy * channels;
    size_t samplesRequested = requestedFrames * channels;
    
    float *dst = (float *)buffer->mAudioData;
    for (size_t i = 0; i < samplesToCopy; i++) {
        dst[i] = _audioRingBuffer[_audioRingReadPos];
        _audioRingReadPos = (_audioRingReadPos + 1) % _audioRingCapacity;
    }
    _audioRingAvailable -= samplesToCopy;
    _audioSamplesPlayed += samplesToCopy;
    _audioQueueFramesEnqueued += (int64_t)requestedFrames;
    if (framesToCopy > 0 && _audioWriteHeadPTS >= 0 && sampleRate > 0) {
        double remainingRingSec = (double)(_audioRingAvailable / channels) / sampleRate;
        _audioQueueEnqueuedEndPTS = _audioWriteHeadPTS - remainingRingSec;
    }
    
    if (samplesToCopy < samplesRequested) {
        // Smoothly fade out the tail of copied samples if buffer underrun to prevent pop/click
        if (samplesToCopy > 0) {
            size_t fadeLen = MIN((size_t)64 * channels, samplesToCopy);
            for (size_t f = 0; f < fadeLen; f++) {
                float gain = 1.0f - ((float)f / (float)fadeLen);
                dst[samplesToCopy - fadeLen + f] *= gain;
            }
        }
        memset(dst + samplesToCopy, 0, (samplesRequested - samplesToCopy) * sizeof(float));
    }
    
    buffer->mAudioDataByteSize = (UInt32)(samplesRequested * sizeof(float));
    os_unfair_lock_unlock(&_audioLock);
    [self tapPlayedAudio:dst frames:framesToCopy channels:channels];
    
    // Audio buffer consumed; demux thread periodically checks backpressure
    
    if (_audioQueue && _running && self.isPlaying) {
        AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
    }
}

#pragma mark - Hardware Accelerated Video Presentation & Sync

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink,
                                   const CVTimeStamp *inNow,
                                   const CVTimeStamp *inOutputTime,
                                   CVOptionFlags flagsIn,
                                   CVOptionFlags *flagsOut,
                                   void *displayLinkContext) {
    @autoreleasepool {
        VPFFmpegPlayer *player = (__bridge VPFFmpegPlayer *)displayLinkContext;
        [player renderVideoFrameForTargetHostTime:inOutputTime->hostTime];
    }
    return kCVReturnSuccess;
}

- (void)startDisplayLinkSync {
    [self stopDisplayLinkSync];
    
    if (!self.hasVideo) {
        [self startFallbackAudioTimer];
        return;
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVReturn ret = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    if (ret == kCVReturnSuccess && _displayLink) {
        CVDisplayLinkSetOutputCallback(_displayLink, DisplayLinkCallback, (__bridge void *)self);
        CVDisplayLinkStart(_displayLink);
    } else {
        _displayLink = NULL;
        [self startFallbackVideoTimer];
    }
#pragma clang diagnostic pop
}

- (void)stopDisplayLinkSync {
    if (_displayLink) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkSetOutputCallback(_displayLink, NULL, NULL);
        CVDisplayLinkRelease(_displayLink);
#pragma clang diagnostic pop
        _displayLink = NULL;
    }
    if (_fallbackVideoTimer) {
        dispatch_source_cancel(_fallbackVideoTimer);
        _fallbackVideoTimer = NULL;
    }
    if (_audioProgressTimer) {
        dispatch_source_cancel(_audioProgressTimer);
        _audioProgressTimer = NULL;
    }
}

- (void)startFallbackVideoTimer {
    if (_fallbackVideoTimer) return;
    _fallbackVideoTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    uint64_t intervalNs = (uint64_t)((1.0 / MAX(30.0, MIN(120.0, self.videoFPS))) * NSEC_PER_SEC);
    dispatch_source_set_timer(_fallbackVideoTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 10);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_fallbackVideoTimer, ^{
        [weakSelf renderVideoFrameForTargetHostTime:mach_absolute_time()];
    });
    dispatch_resume(_fallbackVideoTimer);
}

- (void)startFallbackAudioTimer {
    if (_audioProgressTimer) return;
    _audioProgressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_audioProgressTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_audioProgressTimer, ^{
        VPFFmpegPlayer *player = weakSelf;
        if (!player || !player.isPlaying || player.isPaused) return;
        [player updateBufferingState];
        double clock = [player masterClock];
        player.currentTime = clock;
        id<VPFFmpegPlayerDelegate> del = player.delegate;
        double dur = player.duration;
        if (del) {
            [del ffmpegPlayerDidUpdateTime:clock duration:dur];
        }
    });
    dispatch_resume(_audioProgressTimer);
}

/// Tells the delegate when a stream is waiting for audio: before it starts (pre-roll) and whenever playback has
/// outrun the network. The progress is the share of the 3-second target that is buffered.
- (void)updateBufferingState {
    BOOL eligible = _isNetworkSource && _audioQueue && self.hasAudio && self.isPlaying && !self.isPaused && !_seeking;
    BOOL buffering = NO;
    double progress = 1;
    if (eligible) {
        double rate = _audioFormat.mSampleRate > 0 ? _audioFormat.mSampleRate : 48000.0;
        int channels = _audioFormat.mChannelsPerFrame > 0 ? (int)_audioFormat.mChannelsPerFrame : 2;
        os_unfair_lock_lock(&_audioLock);
        double seconds = (double)_audioRingAvailable / (rate * channels);
        os_unfair_lock_unlock(&_audioLock);
        BOOL ended = _eofReached;
        if (!_audioQueueStarted) buffering = !ended;
        else buffering = !ended && (_bufferingReported ? seconds < 1.0 : seconds < 0.05);
        progress = MIN(1.0, seconds / kNetworkPrerollSeconds);
    }
    if (buffering == _bufferingReported && !(buffering && fabs(progress - _reportedBufferProgress) >= 0.05)) return;
    _bufferingReported = buffering;
    _reportedBufferProgress = progress;
    id<VPFFmpegPlayerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(ffmpegPlayerBufferingDidChange:progress:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate ffmpegPlayerBufferingDidChange:buffering progress:progress]; });
    }
}

- (void)renderVideoFrameForTargetHostTime:(uint64_t)targetHostTime {
    [self updateBufferingState];
    if (!self.isPlaying || self.isPaused || _seeking) return;
    
    double clock = [self masterClockAtHostTime:targetHostTime];
    self.currentTime = clock;

    [self presentDueSubtitlesAtClock:clock];
    if (_subtitleVisible && _subtitleClearPTS > 0 && clock >= _subtitleClearPTS) {
        _subtitleVisible = NO;
        _subtitleClearPTS = -1.0;
        if (self.subtitleHandler) {
            self.subtitleHandler(nil, nil);
        }
    }
    
    uint64_t now = mach_absolute_time();
    if (now - _lastDelegateNotifyHostTime >= SecondsToMachTime(0.1)) {
        _lastDelegateNotifyHostTime = now;
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        double cur = clock;
        double dur = self.duration;
        if (del) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [del ffmpegPlayerDidUpdateTime:cur duration:dur];
            });
        }
    }
    
    os_unfair_lock_lock(&_videoLock);
    if (_videoQueue.count == 0) {
        os_unfair_lock_unlock(&_videoLock);
        return;
    }
    
    VPDecodedVideoFrame *frameToRender = nil;
    double frameDuration = 1.0 / MAX(10.0, MIN(120.0, self.videoFPS > 0 ? self.videoFPS : 29.97));
    double tolerance = _isDiscMedia ? 0.001 : MAX(0.015, frameDuration * 0.5);
    double dropThreshold = -MAX(0.10, 3.0 * frameDuration);
    
    while (_videoQueue.count > 0) {
        VPDecodedVideoFrame *candidate = _videoQueue.firstObject;
        double diff = candidate.pts - clock;
        
        // Only drop a late frame if the NEXT queued frame is also already due for presentation
        if ((_isDiscMedia || diff < dropThreshold) && _videoQueue.count > 1) {
            VPDecodedVideoFrame *nextCandidate = _videoQueue[1];
            if (nextCandidate.pts - clock <= tolerance) {
                [_videoQueue removeObjectAtIndex:0];
                continue;
            }
        }
        
        // Frame ready for presentation on this V-Sync pulse
        if (diff <= tolerance) {
            frameToRender = candidate;
            [_videoQueue removeObjectAtIndex:0];
            break;
        } else {
            // Frame is in the future; hold until next V-Sync
            break;
        }
    }
    os_unfair_lock_unlock(&_videoLock);
    
    // Video queue consumed; demux thread periodically checks backpressure
    
    if (frameToRender && self.frameHandler) {
        _lastRenderedPTS = frameToRender.pts;
        CVPixelBufferRef pb = frameToRender.pixelBuffer;
        if (pb) {
            CVPixelBufferRetain(pb);
            self.frameHandler(pb, frameToRender.pts);
            CVPixelBufferRelease(pb);
        }
    }
}

#pragma mark - Queue and Resource Cleanup

- (void)checkEndOfStream {
    [_demuxCond lock];
    BOOL eof = _eofReached;
    [_demuxCond unlock];
    if (!eof) return;
    
    os_unfair_lock_lock(&_videoLock);
    NSUInteger vCount = _videoQueue.count;
    os_unfair_lock_unlock(&_videoLock);
    
    os_unfair_lock_lock(&_audioLock);
    size_t aAvail = _audioRingAvailable;
    os_unfair_lock_unlock(&_audioLock);
    
    BOOL audioDrained = YES;
    if (_isDiscMedia && self.hasAudio && _audioQueueStarted) {
        double clock = [self masterClock];
        os_unfair_lock_lock(&_audioLock);
        audioDrained = clock >= _discAudioSync.mediaEnd - 0.001;
        os_unfair_lock_unlock(&_audioLock);
    }
    if (vCount == 0 && aAvail == 0 && audioDrained) {
        id<VPFFmpegPlayerDelegate> del = self.delegate;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.looping) {
                [self seekToSeconds:0];
            } else {
                [self pause];
                if (del) {
                    [del ffmpegPlayerDidReachEnd];
                }
            }
        });
    }
}

- (void)clearAudioBuffer {
    [self clearRetainedAudio];
    os_unfair_lock_lock(&_audioLock);
    _audioRingReadPos = 0;
    _audioRingWritePos = 0;
    _audioRingAvailable = 0;
    _audioSamplesPlayed = 0;
    os_unfair_lock_unlock(&_audioLock);
}

- (void)clearVideoQueue {
    os_unfair_lock_lock(&_videoLock);
    [_videoQueue removeAllObjects];
    os_unfair_lock_unlock(&_videoLock);
}

- (void)cleanupFFmpeg {
    [self clearRetainedAudio];
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    _poolWidth = 0;
    _poolHeight = 0;
    
    if (_videoCodecCtx) {
        avcodec_free_context(&_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
    if (_audioCodecCtx) {
        avcodec_free_context(&_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
    if (_hwDeviceCtx) {
        av_buffer_unref(&_hwDeviceCtx);
        _hwDeviceCtx = NULL;
    }
    if (_swsCtx) {
        sws_freeContext(_swsCtx);
        _swsCtx = NULL;
    }
    if (_swrCtx) {
        swr_free(&_swrCtx);
        _swrCtx = NULL;
    }
    [self teardownAudioFilterGraph];
    [self teardownVideoGraph];
    if (_formatCtx) {
        _formatCtx->interrupt_callback.callback = NULL;
        _formatCtx->interrupt_callback.opaque = NULL;
        if (_customIO && _formatCtx->pb == _customIO) {
            _formatCtx->pb = NULL;
        }
        avformat_close_input(&_formatCtx);
        _formatCtx = NULL;
    }
    if (_customIO) {
        avio_context_free(&_customIO);
        _customIO = NULL;
    }
    if (_customFileIO) {
        FreeMultiFileIOContext(_customFileIO);
        _customFileIO = NULL;
    }
    
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    self.hasVideo = NO;
    self.hasAudio = NO;
}

@end
