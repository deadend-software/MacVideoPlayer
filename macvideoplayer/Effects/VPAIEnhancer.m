//
//  VPAIEnhancer.m
//  macvideoplayer
//

#import "VPAIEnhancer.h"
#import "VPAudioDeviceManager.h"
#import "VPMediaAnalyzer.h"
#import <Vision/Vision.h>
#import <Accelerate/Accelerate.h>

NSNotificationName const VPAIEnhancerDidChangeNotification = @"VPAIEnhancerDidChangeNotification";

@interface VPAIEnhancer ()
@property (atomic, readwrite) NSUInteger revision;
@end

@implementation VPAIEnhancer {
    NSString *_gradeCubeKey;
    NSData *_gradeCubeData;
}

+ (instancetype)shared {
    static VPAIEnhancer *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[self alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // AI video enhancement is off until the user picks a preset, an upscale factor, or an adjustment;
        // every one of those paths switches videoAIEnabled on itself.
        _videoAIEnabled = NO;
        _activeVideoPreset = @"none";
        _upscaleFactor = 1.0;
        _clarityBoost = 0.0;
        _luminanceSharpness = 0.0;
        _adaptiveDenoise = 0.0;
        _microContrast = 0.0;
        _vividVibrance = 0.0;
        _hdrDynamicTone = NO;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
        _shadowLift = 0.0;
        _highlightRecovery = 0.0;
        _saturationTrim = 0.0;
        _temperatureShift = 0.0;
        _hueGains = @[];
        _adaptiveVideoEnabled = NO;
        _adaptiveAudioEnabled = NO;
        
        _audioAIEnabled = YES;
        _activeAudioPreset = @"none";
        _surroundMethod = @"none";
        _surroundFill = YES;
        _outputCodec = @"pcm";
        _targetLayout = @"auto";
        _targetSampleRate = @"auto";
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        
        _revision = 1;
    }
    return self;
}

- (void)changed {
    self.revision++;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VPAIEnhancerDidChangeNotification object:self];
    });
}

#pragma mark - Active Checks

- (BOOL)isVideoAIActive {
    if (!self.videoAIEnabled) return NO;
    return (self.upscaleFactor > 1.0 ||
            self.clarityBoost > 0.01 ||
            self.luminanceSharpness > 0.01 ||
            self.adaptiveDenoise > 0.01 ||
            self.microContrast > 0.01 ||
            self.vividVibrance > 0.01 ||
            self.hdrDynamicTone ||
            self.cinemaColorGrade ||
            self.visionSaliencyFocus ||
            self.shadowLift > 0.01 ||
            self.highlightRecovery > 0.01 ||
            fabs(self.saturationTrim) > 0.01 ||
            fabs(self.temperatureShift) > 0.01 ||
            self.colorPop > 0.01 || self.contrastCurve > 0.01 || self.lineDefinition > 0.01 ||
            self.localContrast > 0.01 || self.flatSmoothing > 0.01 ||
            self.adaptiveVideoEnabled ||
            ![self.activeVideoPreset isEqualToString:@"none"]);
}

- (NSString *)effectiveTargetSampleRate {
    return self.hiFiAudio && [self.targetSampleRate isEqualToString:@"auto"] ? @"96000" : self.targetSampleRate;
}

- (BOOL)isAudioAIActive {
    if (!self.audioAIEnabled) return NO;
    return (self.adaptiveAudioEnabled ||
            ![self.surroundMethod isEqualToString:@"none"] ||
            ![self.activeAudioPreset isEqualToString:@"none"] ||
            self.dialogueBoost ||
            self.harmonicCrystalizer ||
            self.loudnessNormalize ||
            self.nightMode ||
            self.hiFiAudio || self.bassImpact || self.audioClarity || self.bassExtension ||
            self.trebleSparkle ||
            ![self.targetSampleRate isEqualToString:@"auto"] ||
            ![self.targetLayout isEqualToString:@"auto"] ||
            ![self.outputCodec isEqualToString:@"pcm"]);
}

#pragma mark - Image Processing (Apple CoreImage & Vision AI)

/// Applies a Core Image filter by name.
static CIImage *VPApply(CIImage *image, NSString *name, NSDictionary *parameters) {
    return [image imageByApplyingFilter:name withInputParameters:parameters];
}

/// How much of the picture is a line or an edge: 0 in flat areas, 1 on lines, with soft shoulders. It is measured on a
/// lightly blurred luma so that noise and film grain are not mistaken for detail, and it is what keeps sharpening on
/// the lines and denoising off them.
static CIImage *VPEdgeMask(CIImage *image, double detailScale) {
    CGRect extent = image.extent;
    CIImage *luma = VPApply(image.imageByClampingToExtent, @"CIColorControls", @{kCIInputSaturationKey: @0});
    CIImage *soft = VPApply(luma, @"CIGaussianBlur", @{kCIInputRadiusKey: @(1.3 * detailScale)});
    CIImage *edges = VPApply(soft, @"CIEdges", @{kCIInputIntensityKey: @5.0});
    // Soft threshold: gradients under about 0.16 count as flat, over about 0.41 as a full edge.
    CIVector *gain = [CIVector vectorWithX:4 Y:0 Z:0 W:0];
    CIImage *mask = VPApply(edges, @"CIColorMatrix", @{
        @"inputRVector": gain, @"inputGVector": gain, @"inputBVector": gain,
        @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0],
        @"inputBiasVector": [CIVector vectorWithX:-0.64 Y:-0.64 Z:-0.64 W:1]});
    mask = VPApply(mask, @"CIColorClamp", @{@"inputMinComponents": [CIVector vectorWithX:0 Y:0 Z:0 W:1],
                                           @"inputMaxComponents": [CIVector vectorWithX:1 Y:1 Z:1 W:1]});
    // Widen it a little so the whole neighbourhood of a line is covered and the blend has no visible seam.
    mask = VPApply(mask, @"CIGaussianBlur", @{kCIInputRadiusKey: @(1.2 * detailScale)});
    return [mask imageByCroppingToRect:extent];
}

/// Blends `foreground` over `background` where the mask is bright.
static CIImage *VPBlend(CIImage *foreground, CIImage *background, CIImage *mask) {
    CIImage *blended = VPApply(foreground, @"CIBlendWithMask", @{kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask});
    return [blended imageByCroppingToRect:background.extent];
}

#pragma mark - File-specific colour grade (3D look-up table)

/// Builds the colour cube for a grade: an S-curve on brightness, a vibrance-style saturation push that favours muted
/// colours, and a per-hue extra gain. Skin-tone orange is protected. Values are sRGB-encoded, RGBA, red varying fastest.
static NSData *VPBuildGradeCube(double pop, double curve, NSArray<NSNumber *> *hueGains, int dim) {
    NSMutableData *data = [NSMutableData dataWithLength:(size_t)dim * dim * dim * 4 * sizeof(float)];
    float *out = data.mutableBytes;
    double gains[12];
    for (int i = 0; i < 12; i++) gains[i] = i < (int)hueGains.count ? hueGains[i].doubleValue : 0;
    double k = curve * 0.35;
    for (int bi = 0; bi < dim; bi++) for (int gi = 0; gi < dim; gi++) for (int ri = 0; ri < dim; ri++) {
        double r = ri / (double)(dim - 1), g = gi / (double)(dim - 1), b = bi / (double)(dim - 1);
        // Brightness S-curve, applied as a ratio so hue is untouched.
        double y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        if (k > 0 && y > 0.002) {
            double y2 = y - k * sin(2.0 * M_PI * y) / (2.0 * M_PI);
            double ratio = y2 / y;
            r = MIN(1, r * ratio); g = MIN(1, g * ratio); b = MIN(1, b * ratio);
        }
        double mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b)), d = mx - mn;
        if (d > 0.02 && mx > 0.04) {
            double s = d / mx, h;
            if (mx == r) h = fmod((g - b) / d + 6.0, 6.0);
            else if (mx == g) h = (b - r) / d + 2.0;
            else h = (r - g) / d + 4.0;                      // 0..6
            double pos = h * 2.0 - 0.5;                       // sector centres at 0, 1 ... 11
            int i0 = ((int)floor(pos) % 12 + 12) % 12, i1 = (i0 + 1) % 12;
            double t = pos - floor(pos);
            double hueGain = gains[i0] * (1 - t) + gains[i1] * t;
            double skin = (h > 0.15 && h < 0.75 && s < 0.7) ? 0.5 : 1.0;   // orange/yellow-orange, moderate saturation
            double room = 1.0 - s;                            // already-vivid colours have little room left
            double boost = (pop * 0.9 * room + hueGain * (0.4 + 0.6 * room)) * skin;
            double s2 = MAX(0, MIN(1, s * (1.0 + boost)));
            double ratio = s2 / s;
            // Scale distance from the grey level of the same peak: saturation change at constant brightness.
            r = mx - (mx - r) * ratio; g = mx - (mx - g) * ratio; b = mx - (mx - b) * ratio;
        }
        size_t index = (((size_t)bi * dim + gi) * dim + ri) * 4;
        out[index] = (float)MAX(0, MIN(1, r)); out[index + 1] = (float)MAX(0, MIN(1, g));
        out[index + 2] = (float)MAX(0, MIN(1, b)); out[index + 3] = 1.0f;
    }
    return data;
}

/// Scales a grey mask's brightness by `amount` (0...1).
static CIImage *VPScaleMask(CIImage *mask, double amount) {
    CIVector *v = [CIVector vectorWithX:(CGFloat)amount Y:0 Z:0 W:0];
    CIVector *gv = [CIVector vectorWithX:0 Y:(CGFloat)amount Z:0 W:0];
    CIVector *bv = [CIVector vectorWithX:0 Y:0 Z:(CGFloat)amount W:0];
    return VPApply(mask, @"CIColorMatrix", @{@"inputRVector": v, @"inputGVector": gv, @"inputBVector": bv,
                                              @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1]});
}

/// The mask's complement: bright where the original is dark.
static CIImage *VPInvertMask(CIImage *mask) {
    CIVector *r = [CIVector vectorWithX:-1 Y:0 Z:0 W:0], *g = [CIVector vectorWithX:0 Y:-1 Z:0 W:0], *b = [CIVector vectorWithX:0 Y:0 Z:-1 W:0];
    return VPApply(mask, @"CIColorMatrix", @{@"inputRVector": r, @"inputGVector": g, @"inputBVector": b,
                                              @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1],
                                              @"inputBiasVector": [CIVector vectorWithX:1 Y:1 Z:1 W:0]});
}

- (NSData *)gradeCubeData {
    NSString *key = [NSString stringWithFormat:@"%.3f|%.3f|%@", self.colorPop, self.contrastCurve, [self.hueGains componentsJoinedByString:@","]];
    @synchronized (self) {
        if ([_gradeCubeKey isEqualToString:key] && _gradeCubeData) return _gradeCubeData;
    }
    // 48 points per axis: a 1.7 MB table (cheap for the GPU) fine enough that the curve and hue shaping stay smooth.
    NSData *cube = VPBuildGradeCube(self.colorPop, self.contrastCurve, self.hueGains, 48);
    @synchronized (self) { _gradeCubeKey = key; _gradeCubeData = cube; }
    return cube;
}

- (CIImage *)processImage:(CIImage *)input {
    if (!input || !self.videoAIEnabled || !self.isVideoAIActive) {
        return input;
    }
    
    CGRect extent = input.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) return input;
    
    CIImage *output = input;
    
    // 1. Upscale first. Everything after this runs at the final size, so lines are sharpened at their real width
    //    instead of being sharpened small and then magnified, which is what makes upscaled video look crunchy.
    if (self.upscaleFactor > 1.01) {
        double scale = self.upscaleFactor;
        CIImage *normalized = [[output imageByCroppingToRect:extent] imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        CIImage *scaled = VPApply(normalized, @"CILanczosScaleTransform", @{kCIInputScaleKey: @(scale), kCIInputAspectRatioKey: @1.0});
        extent = CGRectMake(0, 0, ceil(extent.size.width * scale), ceil(extent.size.height * scale));
        output = [scaled imageByCroppingToRect:extent];
    }
    // Filter radii are in output pixels, so they grow with the picture: the same softness at 480p and at 4K.
    double detailScale = MAX(0.75, MIN(2.0, extent.size.height / 1080.0));
    
    // 2. Denoise flat areas only. Lines and edges keep their original pixels, so cleaning a noisy picture never
    //    smears the detail the viewer is looking at. (Strength is deliberately modest: heavy noise reduction
    //    gives faces a waxy look.)
    if (self.adaptiveDenoise > 0.01) {
        float noise = (float)(MIN(1.0, self.adaptiveDenoise) * 0.02);
        CIImage *cleaned = VPApply(output, @"CINoiseReduction", @{@"inputNoiseLevel": @(noise), @"inputSharpness": @(0.4)});
        output = VPBlend(output, cleaned, VPEdgeMask(output, detailScale));
    }
    
    // 2b. Flat colour areas (cels, skies, walls) are evened out with a median filter where there is no line, which
    //     removes banding speckle and compression noise and leaves the colour fields clean for the colour stage.
    if (self.flatSmoothing > 0.01) {
        CIImage *median = VPApply(output.imageByClampingToExtent, @"CIMedianFilter", @{});
        CIImage *flat = VPScaleMask(VPInvertMask(VPEdgeMask(output, detailScale)), MIN(1.0, self.flatSmoothing));
        output = VPBlend([median imageByCroppingToRect:extent], output, flat);
    }
    
    // 3. Tone. Highlight and shadow recovery are mild: shadows are opened, not flattened.
    if (self.hdrDynamicTone) {
        output = VPApply(output, @"CIHighlightShadowAdjust", @{@"inputHighlightAmount": @(0.92), @"inputShadowAmount": @(0.2)});
    }
    // Per-file tone shaping from the adaptive profile: open shadows, recover highlights, trim an oversaturated source
    // and moderate a colour cast without removing the look.
    if (self.shadowLift > 0.01 || self.highlightRecovery > 0.01) {
        output = VPApply(output, @"CIHighlightShadowAdjust", @{
            @"inputHighlightAmount": @(1.0 - MIN(1.0, self.highlightRecovery) * 0.5),
            @"inputShadowAmount": @(MIN(1.0, self.shadowLift) * 0.6)});
    }
    if (fabs(self.saturationTrim) > 0.01) {
        output = VPApply(output, @"CIColorControls", @{kCIInputSaturationKey: @(1.0 + MAX(-0.5, MIN(0.5, self.saturationTrim)))});
    }
    if (fabs(self.temperatureShift) > 0.01) {
        // Positive shifts warm the picture (more red, less blue); negative shifts cool it.
        double k = MAX(-0.5, MIN(0.5, self.temperatureShift)) * 0.12;
        output = VPApply(output, @"CIColorMatrix", @{
            @"inputRVector": [CIVector vectorWithX:1.0 + k Y:0 Z:0 W:0],
            @"inputBVector": [CIVector vectorWithX:0 Y:0 Z:1.0 - k W:0]});
    }
    
    // 4. Contrast: a gentle S-curve that deepens blacks and lifts whites smoothly. Unlike a global contrast
    //    multiplier it cannot clip, so detail in the darkest and brightest areas survives.
    if (self.cinemaColorGrade) {
        output = VPApply(output, @"CIColorControls", @{kCIInputContrastKey: @1.04, kCIInputSaturationKey: @1.06});
        output = VPApply(output, @"CITemperatureAndTint", @{@"inputNeutral": [CIVector vectorWithX:6500 Y:0],
                                                            @"inputTargetNeutral": [CIVector vectorWithX:6400 Y:0]});
    }
    if (self.microContrast > 0.01) {
        double a = MIN(1.0, self.microContrast) * 0.07;
        output = VPApply(output, @"CIToneCurve", @{
            @"inputPoint0": [CIVector vectorWithX:0 Y:0],
            @"inputPoint1": [CIVector vectorWithX:0.25 Y:0.25 - a],
            @"inputPoint2": [CIVector vectorWithX:0.5 Y:0.5],
            @"inputPoint3": [CIVector vectorWithX:0.75 Y:0.75 + a],
            @"inputPoint4": [CIVector vectorWithX:1 Y:1]});
    }
    
    // 4b. The file's own grade: S-curve contrast, colour pop and per-hue saturation from one look-up table.
    if (self.colorPop > 0.01 || self.contrastCurve > 0.01) {
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CIImage *graded = VPApply(output, @"CIColorCubeWithColorSpace", @{@"inputCubeDimension": @48, @"inputCubeData": [self gradeCubeData],
                                                                       @"inputColorSpace": (__bridge id)srgb});
        CGColorSpaceRelease(srgb);
        output = [graded imageByCroppingToRect:extent];
    }
    // 4c. Local contrast: a wide, soft unsharp mask gives objects depth and form (large shapes, not fine grain).
    if (self.localContrast > 0.01) {
        output = VPApply(output.imageByClampingToExtent, @"CIUnsharpMask", @{kCIInputRadiusKey: @(14.0 * detailScale), kCIInputIntensityKey: @(MIN(1.0, self.localContrast) * 0.7)});
        output = [output imageByCroppingToRect:extent];
    }
    // 4d. Line definition: darker neighbours spread a little into line pixels, so outlines and ink lines come out
    //     firmer and cleaner. Only the edge mask is touched; faces, skies and textures keep their own pixels.
    if (self.lineDefinition > 0.01) {
        double window = MAX(1.0, round(detailScale));
        CIImage *thick = VPApply(output.imageByClampingToExtent, @"CIMorphologyMinimum", @{kCIInputRadiusKey: @(window)});
        CIImage *mask = VPScaleMask(VPEdgeMask(output, detailScale), MIN(1.0, self.lineDefinition) * 0.85);
        output = VPBlend([thick imageByCroppingToRect:extent], output, mask);
    }
    
    // 5. Colour: Apple's vibrance lifts muted colours most and leaves saturated ones and skin tones alone, so the
    //    picture becomes vivid without turning orange or neon.
    if (self.vividVibrance > 0.01) {
        output = VPApply(output, @"CIVibrance", @{@"inputAmount": @(MIN(1.0, self.vividVibrance) * 0.65)});
    }
    
    // 6. Sharpen last, and only along lines. Luma-only sharpening keeps colour noise out; the result is then held
    //    to the range of its own neighbourhood (no pixel may overshoot the brightest or darkest pixel next to it),
    //    which removes halos; and the edge mask confines the effect to real lines, leaving skin, sky and grain alone.
    double lumaAmount = MIN(1.0, self.luminanceSharpness), detailAmount = MIN(1.0, self.clarityBoost);
    if (lumaAmount > 0.01 || detailAmount > 0.01) {
        CIImage *sharpened = output;
        if (lumaAmount > 0.01) sharpened = VPApply(sharpened, @"CISharpenLuminance", @{kCIInputSharpnessKey: @(lumaAmount * 0.8)});
        if (detailAmount > 0.01) sharpened = VPApply(sharpened, @"CIUnsharpMask", @{kCIInputRadiusKey: @(1.1 * detailScale), kCIInputIntensityKey: @(detailAmount * 0.6)});
        CIImage *surround = output.imageByClampingToExtent;
        double window = MAX(1.0, round(detailScale));
        CIImage *localMax = VPApply(surround, @"CIMorphologyMaximum", @{kCIInputRadiusKey: @(window)});
        CIImage *localMin = VPApply(surround, @"CIMorphologyMinimum", @{kCIInputRadiusKey: @(window)});
        CIImage *limited = VPApply(sharpened.imageByClampingToExtent, @"CIMinimumCompositing", @{kCIInputBackgroundImageKey: localMax});
        limited = VPApply(limited, @"CIMaximumCompositing", @{kCIInputBackgroundImageKey: localMin});
        limited = [limited imageByCroppingToRect:extent];
        output = VPBlend(limited, output, VPEdgeMask(output, detailScale));
    }
    
    return [output imageByCroppingToRect:extent];
}

#pragma mark - Audio Filter Graph Generation

+ (NSString *)layoutForChannelCount:(NSUInteger)channels {
    switch (channels) {
        case 0: case 2: return @"stereo";
        case 1: return @"mono";
        case 3: return @"2.1";
        case 4: return @"4.0";
        case 5: return @"5.0";
        case 6: case 7: return @"5.1";
        default: return @"7.1";
    }
}

- (NSString *)matrixLayoutForDeviceUID:(NSString *)deviceUID {
    NSString *target = self.targetLayout ?: @"auto";
    if ([target isEqualToString:@"2.0"]) return @"stereo";
    if (![target isEqualToString:@"auto"]) return target;
    return [VPAIEnhancer layoutForChannelCount:[VPAudioDeviceManager outputChannelCountForDeviceUID:deviceUID]];
}

/// Directional matrix: fronts retain L/R, center uses the common sum, and surrounds
/// use difference content. Mono dialogue does not create artificial rear ambience.
+ (NSString *)matrixPanForLayout:(NSString *)layout {
    NSString *sum = @"0.5*c0+0.5*c1";
    // Every speaker gets a share of both channels so near-mono stereo still reaches all of them.
    NSString *rearL = @"0.6*c0-0.2*c1", *rearR = @"0.6*c1-0.2*c0";
    NSString *sideL = @"0.5*c0-0.1*c1", *sideR = @"0.5*c1-0.1*c0";
    if ([layout isEqualToString:@"mono"]) return [NSString stringWithFormat:@"pan=mono|FC=%@", sum];
    if ([layout isEqualToString:@"2.1"]) return [NSString stringWithFormat:@"pan=2.1|FL=c0|FR=c1|LFE=%@", sum];
    if ([layout isEqualToString:@"4.0"] || [layout isEqualToString:@"quad"]) return [NSString stringWithFormat:@"pan=quad|FL=c0|FR=c1|BL=%@|BR=%@", rearL, rearR];
    // FFmpeg's 4.1 is front left/right, center, subwoofer and one back center speaker.
    if ([layout isEqualToString:@"4.1"]) return [NSString stringWithFormat:@"pan=4.1|FL=c0|FR=c1|FC=%@|LFE=%@|BC=%@", sum, sum, sum];
    if ([layout isEqualToString:@"5.0"]) return [NSString stringWithFormat:@"pan=5.0|FL=c0|FR=c1|FC=%@|BL=%@|BR=%@", sum, rearL, rearR];
    if ([layout isEqualToString:@"5.1"]) return [NSString stringWithFormat:@"pan=5.1|FL=c0|FR=c1|FC=%@|LFE=%@|BL=%@|BR=%@", sum, sum, rearL, rearR];
    if ([layout isEqualToString:@"7.1"]) return [NSString stringWithFormat:@"pan=7.1|FL=c0|FR=c1|FC=%@|LFE=%@|BL=%@|BR=%@|SL=%@|SR=%@", sum, sum, rearL, rearR, sideL, sideR];
    return @"pan=stereo|FL=0.8*c0+0.2*c1|FR=0.2*c0+0.8*c1";
}

- (NSString *)audioFilterGraphString {
    return [self audioFilterGraphStringForDeviceUID:nil];
}

- (NSString *)audioFilterGraphStringForDeviceUID:(NSString *)deviceUID {
    if (!self.audioAIEnabled || !self.isAudioAIActive) {
        return @"";
    }
    
    NSMutableArray<NSString *> *filters = [NSMutableArray array];
    
    if (self.audioClarity) {
        // A gentle presence lift only. Spectral denoising (afftdn) is left out on purpose: its noise tracking leaves
        // watery "musical noise" that sounds wavy on music and dialogue.
        [filters addObject:@"equalizer=f=3000:t=q:w=1:g=1.2"];
    }
    if (self.bassExtension) {
        // A plain low shelf: asubboost's internal delay line and feedback make the bass wobble.
        [filters addObject:@"bass=g=2:f=90:w=0.6"];
    }

    // 1. Clean Dialogue Filter (vocal presence & articulation without harsh resonance)
    if (self.dialogueBoost) {
        [filters addObject:@"highpass=f=80:w=0.7"];
        [filters addObject:@"equalizer=f=350:t=q:w=1.2:g=-2.5"];
        [filters addObject:@"equalizer=f=2800:t=q:w=1.0:g=3.2"];
        [filters addObject:@"equalizer=f=5000:t=q:w=1.2:g=1.8"];
    }
    
    // 2. Harmonic Crystalizer & Exciter (gentle harmonic sheen, no sample difference spikes)
    if (self.harmonicCrystalizer) {
        [filters addObject:@"aexciter=amount=0.3:drive=2:freq=7000:ceil=16000"];
    }
    
    // 2b. Hi-Fidelity: the sample-rate conversion itself is done by Apple's converter in the player. Here only a very
    //     light harmonic stage restores the "air" that lossy codecs (AC-3, DTS, AAC, MP3) cut off. Nothing is
    //     filtered out or compressed, so the sound keeps its body and dynamics.
    if (self.hiFiAudio) {
        [filters addObject:@"aexciter=amount=0.18:drive=2:freq=9000:ceil=20000"];
    }
    
    // 3. Bass Punch & Sub-Harmonic Impact (tight punch without woofer bottoming or clipping)
    if (self.bassImpact) {
        [filters addObject:@"bass=g=3.0:f=90:w=0.7"];
    }
    
    // 4. Treble Sparkle & Air (open top-end air without sibilance tearing)
    if (self.trebleSparkle) {
        [filters addObject:@"treble=g=2.2:f=10000:w=0.7"];
    }
    
    // 5. Night Mode (Dialogue Clarity + Dynamic Peak Compression)
    if (self.nightMode) {
        [filters addObject:@"equalizer=f=2500:t=q:w=1.0:g=2.5"];
        [filters addObject:@"acompressor=threshold=-22dB:ratio=3:attack=20:release=400:makeup=1.5"];
    }
    
    // 5b. Per-file sound corrections measured from this very file: level, tonal balance, dynamics, width.
    if (self.adaptiveAudioEnabled && self.adaptiveAudioGraph.length > 0) {
        [filters addObject:self.adaptiveAudioGraph];
    }
    
    // 6. Surround Sound Upsampling (Matrix AI, Apple AI & FFmpeg methods)
    if ([self.surroundMethod isEqualToString:@"matrix_ai"]) {
        // Everything is folded to stereo first so the matrix has a known input, then spread over every speaker.
        [filters addObject:@"aformat=channel_layouts=stereo"];
        NSString *layout = [self matrixLayoutForDeviceUID:deviceUID];
        [filters addObject:[VPAIEnhancer matrixPanForLayout:layout]];
        if ([layout isEqual:@"5.1"]) [filters addObject:@"adelay=0|0|0|0|23|27"];
        if ([layout isEqual:@"7.1"]) [filters addObject:@"adelay=0|0|0|0|23|27|11|14"];
        if ([layout hasSuffix:@".1"]) [filters addObject:@"lowpass=f=120:c=LFE"];
    } else if ([self.surroundMethod isEqualToString:@"apple_spatial"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        // Mid/side widening has no delay, so it cannot comb-filter the way a delayed crossfeed does.
        [filters addObject:@"extrastereo=m=1.3"];
    } else if ([self.surroundMethod isEqualToString:@"apple_51"]) {
        // The playback stream runs VPAppleSurroundProcessor using Accelerate.
        // Keep the source channels intact until that stage.
        [filters addObject:@"anull"];
    } else if ([self.surroundMethod isEqualToString:@"apple_71"]) {
        [filters addObject:@"anull"];
    } else if ([self.surroundMethod isEqualToString:@"ffmpeg_51"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"surround=chl_out=5.1:chl_in=stereo"];
    } else if ([self.surroundMethod isEqualToString:@"ffmpeg_71"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"surround=chl_out=7.1:chl_in=stereo"];
    } else if ([self.surroundMethod isEqualToString:@"stereo_wide"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"extrastereo=m=1.4"];
    } else if ([self.surroundMethod isEqualToString:@"subwoofer_21"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"virtualbass=cutoff=100:strength=1.5"];
        [filters addObject:@"bass=g=3.5:f=75:w=0.7"];
        if ([self.targetLayout isEqualToString:@"2.1"]) {
            [filters addObject:@"pan=2.1|c0=c0|c1=c1|c2=0.5*c0+0.5*c1"];
        }
    }
    
    // 7. Dynamic Loudness Normalization (Real-time zero latency)
    if (self.loudnessNormalize) {
        [filters addObject:@"acompressor=threshold=-20dB:ratio=3:attack=20:release=400:makeup=1.5"];
    }
    
    // 8. Universal Master Limiter - prevents clipping on the DAC output. The release is slow and smoothed by the
    //    program-dependent ASC mode: a fast release makes loud passages pump, which sounds like a wavering level.
    if (filters.count > 0) {
        [filters addObject:@"alimiter=limit=0.97:attack=7:release=250:asc=1:asc_level=0.6:level=0"];
    }
    
    return [filters componentsJoinedByString:@","];
}

#pragma mark - Presets

- (void)applyVideoPreset:(NSString *)presetName {
    _activeVideoPreset = [presetName copy] ?: @"none";
    _videoAIEnabled = YES;
    
    if ([presetName isEqualToString:@"adaptive"]) {
        // Settings come from the file itself; until it has been analyzed the picture passes through untouched.
        _adaptiveVideoEnabled = YES;
        if (_adaptiveProfile) { [self applyAdaptiveProfile:_adaptiveProfile]; return; }
        [self resetVideoParameters];
        [self changed];
        return;
    }
    _adaptiveVideoEnabled = NO;
    _hueGains = @[];   // a preset applies the same grade to every file; only "adaptive" shapes it per hue
    
    if ([presetName isEqualToString:@"vivid_crisp"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.65;
        _luminanceSharpness = 0.70;
        _adaptiveDenoise = 0.20;
        _microContrast = 0.55;
        _vividVibrance = 0.80;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = YES;
        _colorPop = 0.80; _contrastCurve = 0.50; _lineDefinition = 0.50; _localContrast = 0.60; _flatSmoothing = 0.0;
    } else if ([presetName isEqualToString:@"cinema_hdr"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.45;
        _luminanceSharpness = 0.55;
        _adaptiveDenoise = 0.15;
        _microContrast = 0.65;
        _vividVibrance = 0.55;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = YES;
        _visionSaliencyFocus = YES;
        _colorPop = 0.60; _contrastCurve = 0.70; _lineDefinition = 0.25; _localContrast = 0.75; _flatSmoothing = 0.0;
    } else if ([presetName isEqualToString:@"anime_pop"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.60;
        _luminanceSharpness = 0.75;
        _adaptiveDenoise = 0.35;
        _microContrast = 0.45;
        _vividVibrance = 0.85;
        _hdrDynamicTone = NO;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
        _colorPop = 0.90; _contrastCurve = 0.45; _lineDefinition = 0.85; _localContrast = 0.35; _flatSmoothing = 0.70;
    } else if ([presetName isEqualToString:@"super_resolution_2x"]) {
        _upscaleFactor = 2.0;
        _clarityBoost = 0.60;
        _luminanceSharpness = 0.55;
        _adaptiveDenoise = 0.25;
        _microContrast = 0.40;
        _vividVibrance = 0.45;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = YES;
        _colorPop = 0.50; _contrastCurve = 0.35; _lineDefinition = 0.55; _localContrast = 0.45; _flatSmoothing = 0.25;
    } else if ([presetName isEqualToString:@"clean_restore"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.35;
        _luminanceSharpness = 0.40;
        _adaptiveDenoise = 0.65;
        _microContrast = 0.30;
        _vividVibrance = 0.35;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
        _colorPop = 0.40; _contrastCurve = 0.30; _lineDefinition = 0.35; _localContrast = 0.35; _flatSmoothing = 0.50;
    } else {
        [self resetVideoAI];
        return;
    }
    
    [self changed];
}

- (void)applyAudioPreset:(NSString *)presetName {
    _activeAudioPreset = [presetName copy] ?: @"none";
    _audioAIEnabled = YES;
    
    if ([presetName isEqualToString:@"adaptive"]) {
        _adaptiveAudioEnabled = YES;
        _audioClarity = NO;
        _bassExtension = NO;
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
        _adaptiveAudioGraph = _adaptiveProfile.audioGraph;
        [self changed];
        return;
    }
    _adaptiveAudioEnabled = NO;
    _audioClarity = [presetName isEqual:@"cinema_restore"];
    _bassExtension = _audioClarity;
    if (_audioClarity) {
        _surroundFill = YES;
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"apple_71";
        _targetLayout = @"7.1";
        [self changed];
        return;
    }
    
    if ([presetName isEqualToString:@"matrix_ai"]) {
        // Sound from every speaker of the output device; the tone is left alone.
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"matrix_ai";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"clear_dialogue"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = YES;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = YES;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"spatial_3d"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = YES;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = YES;
        _surroundMethod = @"apple_spatial";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"surround_51"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = NO;
        _surroundMethod = @"apple_51";
        _targetLayout = @"5.1";
    } else if ([presetName isEqualToString:@"surround_71"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = YES;
        _surroundMethod = @"apple_71";
        _targetLayout = @"7.1";
    } else if ([presetName isEqualToString:@"studio_master"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = YES;
        _loudnessNormalize = YES;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = YES;
        _surroundMethod = @"stereo_wide";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"night_mode"]) {
        _dialogueBoost = YES;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = YES;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"loudnorm"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = YES;
        _nightMode = NO;
        _bassImpact = NO;
        _trebleSparkle = NO;
        _surroundMethod = @"none";
        _targetLayout = @"auto";
    } else if ([presetName isEqualToString:@"bass_punch"]) {
        _dialogueBoost = NO;
        _harmonicCrystalizer = NO;
        _loudnessNormalize = NO;
        _nightMode = NO;
        _bassImpact = YES;
        _trebleSparkle = NO;
        _surroundMethod = @"subwoofer_21";
        _targetLayout = @"2.1";
    } else {
        [self resetAudioAI];
        return;
    }
    
    [self changed];
}

- (void)resetVideoParameters {
    _upscaleFactor = 1.0;
    _clarityBoost = 0.0;
    _luminanceSharpness = 0.0;
    _adaptiveDenoise = 0.0;
    _microContrast = 0.0;
    _vividVibrance = 0.0;
    _hdrDynamicTone = NO;
    _cinemaColorGrade = NO;
    _visionSaliencyFocus = NO;
    _shadowLift = 0.0;
    _highlightRecovery = 0.0;
    _saturationTrim = 0.0;
    _temperatureShift = 0.0;
    _colorPop = 0.0;
    _hueGains = @[];
    _contrastCurve = 0.0;
    _lineDefinition = 0.0;
    _localContrast = 0.0;
    _flatSmoothing = 0.0;
}

- (void)resetVideoAI {
    _videoAIEnabled = NO;
    _activeVideoPreset = @"none";
    _adaptiveVideoEnabled = NO;
    [self resetVideoParameters];
    [self changed];
}

- (void)applyAdaptiveProfile:(VPMediaProfile *)profile {
    _adaptiveProfile = profile;
    if (_adaptiveVideoEnabled && profile.hasVideo) {
        _videoAIEnabled = YES;
        _activeVideoPreset = @"adaptive";
        [self resetVideoParameters];
        _adaptiveDenoise = profile.denoise;
        _luminanceSharpness = profile.lineSharpness;
        _clarityBoost = profile.clarity;
        _microContrast = profile.microContrast;
        _vividVibrance = profile.vibrance;
        _shadowLift = profile.shadowLift;
        _highlightRecovery = profile.highlightRecovery;
        _saturationTrim = profile.saturationTrim;
        _temperatureShift = profile.temperatureShift;
        _colorPop = profile.colorPop;
        _hueGains = profile.hueGains ?: @[];
        _contrastCurve = profile.contrastCurve;
        _lineDefinition = profile.lineDefinition;
        _localContrast = profile.localContrast;
        _flatSmoothing = profile.flatSmoothing;
        _upscaleFactor = profile.upscale > 1.01 ? profile.upscale : 1.0;
    }
    if (_adaptiveAudioEnabled) {
        _audioAIEnabled = YES;
        _activeAudioPreset = @"adaptive";
        _adaptiveAudioGraph = profile.hasAudio ? profile.audioGraph : @"";
    }
    [self changed];
}

- (void)resetAudioAI {
    _activeAudioPreset = @"none";
    _adaptiveAudioEnabled = NO;
    _adaptiveAudioGraph = nil;
    _audioClarity = NO;
    _bassExtension = NO;
    _surroundFill = NO;
    _surroundMethod = @"none";
    _dialogueBoost = NO;
    _harmonicCrystalizer = NO;
    _loudnessNormalize = NO;
    _nightMode = NO;
    _bassImpact = NO;
    _trebleSparkle = NO;
    _hiFiAudio = NO;
    _targetLayout = @"auto";
    _outputCodec = @"pcm";
    [self changed];
}

#pragma mark - Helper Names

+ (NSString *)displayNameForCodec:(NSString *)codec {
    static NSDictionary *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"pcm": @"Direct Hi-Fi Linear PCM (32-bit Float)",
            @"ac3": @"Dolby Digital AC-3 (5.1 Surround / Stereo)",
            @"eac3": @"Dolby Digital Plus E-AC-3 (7.1 Surround)",
            @"dts": @"DTS Coherent Acoustics (5.1 Surround)",
            @"aac": @"Advanced Audio Coding (AAC-LC / HE-AAC)",
            @"alac": @"Apple Lossless Audio Codec (ALAC 24-bit)",
            @"flac": @"Free Lossless Audio Codec (FLAC)",
            @"opus": @"Ogg Opus (Interactive Audio Codec)",
            @"mp3": @"MPEG Audio Layer 3 (MP3)"
        };
    });
    return names[codec] ?: codec;
}

+ (NSString *)displayNameForLayout:(NSString *)layout {
    static NSDictionary *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"auto": @"Auto (Match Source)",
            @"mono": @"Mono (1.0)",
            @"stereo": @"Stereo (2.0)",
            @"2.1": @"2.1 (Stereo + Subwoofer)",
            @"4.0": @"4.0 (Quadraphonic)",
            @"4.1": @"4.1 (Center, Rear Center + Subwoofer)",
            @"5.0": @"5.0 (Surround, No Subwoofer)",
            @"5.1": @"5.1 (Surround + Subwoofer)",
            @"7.1": @"7.1 (Full Cinema Surround)"
        };
    });
    return names[layout] ?: layout;
}

+ (NSString *)displayNameForSurroundMethod:(NSString *)method {
    static NSDictionary *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"none": @"Off (Stereo / Direct)",
            @"matrix_ai": @"Directional Surround Matrix",
            @"apple_spatial": @"Spatial Stereo (Apple-style)",
            @"apple_51": @"5.1 Surround Upmixer (Apple Accelerate)",
            @"apple_71": @"7.1 Surround Upmixer (Apple Accelerate)",
            @"ffmpeg_51": @"FFmpeg Matrix 5.1 Surround",
            @"ffmpeg_71": @"FFmpeg Matrix 7.1 Surround",
            @"stereo_wide": @"Stereo Stage Expander (Wide)",
            @"subwoofer_21": @"2.1 Subwoofer Bass Synthesis"
        };
    });
    return names[method] ?: method;
}

@end
