//
//  VPDVDPlayer.h
//  vplay
//

#import <AppKit/AppKit.h>
#import "VPStagePlayer.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPDVDNavigation) {
    VPDVDNavigationActivate = 0,
    VPDVDNavigationUp,
    VPDVDNavigationDown,
    VPDVDNavigationLeft,
    VPDVDNavigationRight
};

/// Authored DVD playback through libdvdnav (menus, highlights, stills, title jumps). Decoded frames and
/// sound are handed to the app instead of being drawn by the engine, so the stage's transport controls,
/// the Core Image effects (including AI video) and the audio filter graph (including AI audio) all apply.
@interface VPDVDPlayer : NSObject <VPStagePlayer>

@property (nonatomic, copy, nullable) void (^frameHandler)(CVPixelBufferRef pixelBuffer, double pts);
/// The interleaved float samples about to be played, after the filter graph (for meters and visualizers).
@property (nonatomic, copy, nullable) void (^audioSamplesHandler)(const float *samples, NSUInteger count, NSUInteger channels);
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;
@property (nonatomic, assign) float volume;
@property (atomic, copy, nullable) NSString *audioOutputLayout;
/// YES while the disc shows one of its menus rather than a title.
@property (nonatomic, readonly) BOOL inMenu;
@property (nonatomic, copy, nullable) void (^errorHandler)(NSError *error);
/// Called on the main queue a few times per second with a short description of where the disc is
/// ("DVD Menu", "Title 1 · Chapter 3"); the window shows it and uses it to refresh the DVD bar.
@property (nonatomic, copy, nullable) void (^statusHandler)(NSString *status);

/// `videoTS` is the disc's VIDEO_TS folder (see +[VPDiscSupport dvdNavigationURLForURL:]).
- (BOOL)openDiscAtURL:(NSURL *)videoTS error:(NSError **)error;
- (void)showDiscMenu;
- (void)navigate:(VPDVDNavigation)direction;
- (void)togglePlayPause;
- (void)seekToSeconds:(double)seconds;
/// Arrow keys, Return, Escape and Space drive the disc; returns NO for keys it does not use.
- (BOOL)handleKeyEvent:(NSEvent *)event;
/// Replaces the libavfilter graph the disc's sound runs through (nil or empty for none). Takes effect at once.
- (void)applyAudioFiltersGraph:(nullable NSString *)graphString;
- (void)stop;

@end

/// On-screen DVD navigation (menu, arrows, select) for the menus of a disc; sits above the stage.
@interface VPDVDNavigationBar : NSView
- (instancetype)initWithPlayer:(VPDVDPlayer *)player;
@end

NS_ASSUME_NONNULL_END
