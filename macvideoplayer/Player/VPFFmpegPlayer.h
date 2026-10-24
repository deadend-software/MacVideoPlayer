//
//  VPFFmpegPlayer.h
//  macvideoplayer
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "VPStagePlayer.h"

NS_ASSUME_NONNULL_BEGIN

@class VPFFmpegSourceInfo;

@protocol VPFFmpegPlayerDelegate <NSObject>
@optional
- (void)ffmpegPlayerDidStartPlaying;
- (void)ffmpegPlayerDidFail:(NSError *)error;
- (void)ffmpegPlayerDidPause;
- (void)ffmpegPlayerDidStop;
- (void)ffmpegPlayerDidReachEnd;
- (void)ffmpegPlayerDidUpdateTime:(double)currentTime duration:(double)duration;
/// A network stream is waiting for audio (YES) or has enough again (NO); progress is 0...1 of the 3-second buffer.
- (void)ffmpegPlayerBufferingDidChange:(BOOL)buffering progress:(double)progress;
@end

/// High-performance in-memory media player powered directly by FFmpeg C libraries
/// (libavcodec, libavformat, libswscale, libswresample, libavfilter) and Metal.
/// Performs zero-conversion direct playback of any format supported by FFmpeg.
@interface VPFFmpegPlayer : NSObject <VPStagePlayer>

@property (nonatomic, weak, nullable) id<VPFFmpegPlayerDelegate> delegate;

@property (nonatomic, copy, nullable) void (^frameHandler)(CVPixelBufferRef pixelBuffer, double pts);
@property (nonatomic, copy, nullable) void (^audioSamplesHandler)(const float *samples, NSUInteger count, NSUInteger channels);
@property (nonatomic, copy, nullable) void (^subtitleHandler)(NSImage *_Nullable image, NSString *_Nullable text);

@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, assign) BOOL looping;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) float rate;
@property (nonatomic, readonly) BOOL hasVideo;
@property (nonatomic, readonly) BOOL hasAudio;
@property (nonatomic, readonly) CGSize videoSize;
@property (nonatomic, readonly) double videoFPS;

@property (nonatomic, strong, readonly, nullable) VPFFmpegSourceInfo *sourceInfo;

- (BOOL)openURL:(NSURL *)url options:(nullable NSDictionary *)options error:(NSError **)error;
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekToSeconds:(double)seconds;
/// Pauses and shows the frame `count` frames after (or, when negative, before) the one on screen.
- (void)stepFrames:(NSInteger)count;
- (void)togglePlayPause;
- (void)applyAudioFiltersGraph:(nullable NSString *)graphString;
- (BOOL)selectAudioTrack:(int)trackOrdinal;
- (BOOL)selectSubtitleTrack:(int)trackOrdinal;

@end

NS_ASSUME_NONNULL_END
