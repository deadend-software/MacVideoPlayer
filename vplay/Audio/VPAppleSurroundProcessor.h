#import <Foundation/Foundation.h>
#import "VPFFmpeg.h"

// Apple Accelerate DSP, not a trained dialogue-separation model.
// One instance per playback stream; used only on that stream's audio thread.
@interface VPAppleSurroundProcessor : NSObject
// Optional audible ambience for quiet authored surrounds; off preserves their mix.
@property (nonatomic) BOOL surroundFill;
- (void)reset;
// Returns a borrowed frame valid until the next call. Authored surround is preserved
// when surroundFill is off; expanding 5.x to 7.1 synthesizes the missing rear pair.
- (AVFrame *)processFrame:(AVFrame *)frame layout:(NSString *)layout;
@end
