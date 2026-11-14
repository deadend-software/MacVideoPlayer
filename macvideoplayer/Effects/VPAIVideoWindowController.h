#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Controls for AI video enhancement: a look (preset), upscaling, a slider for every adjustment, and a comparison
/// (enhanced, original, or a split) so the effect can be judged on the picture that is playing.
@interface VPAIVideoWindowController : NSWindowController
/// Called after every change so the picture can be redrawn.
@property (nonatomic, copy, nullable) void (^pictureNeedsRefresh)(void);
/// Re-reads every control from the enhancer (after a change made elsewhere, such as the context menu).
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
