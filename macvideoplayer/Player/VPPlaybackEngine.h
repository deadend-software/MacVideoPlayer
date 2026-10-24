//
//  VPPlaybackEngine.h
//  macvideoplayer
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class VPFFmpegPlayer;

NS_ASSUME_NONNULL_BEGIN

@protocol VPPlaybackEngineDelegate <NSObject>
@optional
- (void)playbackEngineDidStartPlaying;
- (void)playbackEngineDidFail:(NSError *)error;
- (void)playbackEngineDidPause;
- (void)playbackEngineDidStop;
- (void)playbackEngineDidReachEnd;
- (void)playbackEngineDidUpdateTime:(CMTime)time;
/// A stream is loading or waiting for data (YES) or playing smoothly again (NO); progress is 0...1 of the buffer target.
- (void)playbackEngineBufferingDidChange:(BOOL)buffering progress:(double)progress;
@end

@interface VPPlaybackEngine : NSObject

@property (nonatomic, strong, readonly, nullable) AVPlayer *player;
@property (nonatomic, strong, readonly, nullable) AVPlayerItem *currentItem;
@property (nonatomic, strong, readonly, nullable) VPFFmpegPlayer *ffmpegPlayer;
@property (nonatomic, readonly) BOOL isFFmpegPlaying;
/// YES while an external FFplay window is playing instead of the built-in player.
@property (nonatomic, readonly) BOOL usesExternalPlayer;
@property (nonatomic, weak, nullable) id<VPPlaybackEngineDelegate> delegate;
@property (nonatomic, assign) BOOL looping;
@property (nonatomic, assign, readonly) BOOL isPlaying;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;

- (BOOL)playURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error;
- (void)pause;
- (void)resume;
- (void)stop;
- (void)seekToSeconds:(double)seconds;
- (void)setRate:(float)rate;
- (void)setVolume:(float)volume;
- (void)togglePlayPause;
- (BOOL)selectAudioTrack:(NSInteger)index;
- (BOOL)selectSubtitleTrack:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
