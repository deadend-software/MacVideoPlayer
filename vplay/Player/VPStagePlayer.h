//
//  VPStagePlayer.h
//  vplay
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// A playback engine that hands decoded frames to the stage (VPVideoView) instead of drawing them itself,
/// so the same transport controls, overlays and Core Image effects apply whatever the source is.
@protocol VPStagePlayer <NSObject>
@property (nonatomic, copy, nullable) void (^frameHandler)(CVPixelBufferRef pixelBuffer, double pts);
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;
@property (nonatomic, assign) float volume;
@optional
@property (nonatomic, copy, nullable) void (^subtitleHandler)(NSImage *_Nullable image, NSString *_Nullable text);
@end

NS_ASSUME_NONNULL_END
