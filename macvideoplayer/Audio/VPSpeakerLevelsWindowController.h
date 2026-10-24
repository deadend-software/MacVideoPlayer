#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A small panel with one slider per speaker group (front, center, subwoofer, rear, side), -12 to +12 dB.
/// Sliders act on the playing audio immediately through VPAudioFilters.
@interface VPSpeakerLevelsWindowController : NSWindowController
@end

NS_ASSUME_NONNULL_END
