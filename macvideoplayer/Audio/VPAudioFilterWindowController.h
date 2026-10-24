#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Browse, configure, add/remove/update and apply FFmpeg audio filters and 10-band Equalizer to live playing audio.
@interface VPAudioFilterWindowController : NSWindowController
/// Called when filters or equalizer bands are added, removed, updated or applied to live playing media.
@property (nonatomic, copy, nullable) void (^applyHandler)(void);
- (void)reload;
- (void)focusEqualizer;
@end

NS_ASSUME_NONNULL_END
