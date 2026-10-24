//
//  VPAIEnhancer.m
//  vplay
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

@implementation VPAIEnhancer

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
            self.adaptiveVideoEnabled ||
            ![self.activeVideoPreset isEqualToString:@"none"]);
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
            self.bassImpact || self.audioClarity || self.bassExtension ||
            self.trebleSparkle ||
            ![self.targetSampleRate isEqualToString:@"auto"] ||
            ![self.targetLayout isEqualToString:@"auto"] ||
            ![self.outputCodec isEqualToString:@"pcm"]);
}

#pragma mark - Image Processing (Apple CoreImage & Vision AI)

- (CIImage *)processImage:(CIImage *)input {
    if (!input || !self.videoAIEnabled || !self.isVideoAIActive) {
        return input;
    }
    
    CGRect extent = input.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) return input;
    
    CIImage *output = input;
    
    // 1. Adaptive AI De-Noise (runs before sharpening to avoid sharpening noise artifacts)
    if (self.adaptiveDenoise > 0.01) {
        float noise = (float)(self.adaptiveDenoise * 0.04);
        output = [output imageByApplyingFilter:@"CINoiseReduction"
                           withInputParameters:@{
                               @"inputNoiseLevel": @(noise),
                               @"inputSharpness": @(0.35)
                           }];
    }
    
    // 2. Dynamic HDR Highlights & Shadows Recovery
    if (self.hdrDynamicTone) {
        output = [output imageByApplyingFilter:@"CIHighlightShadowAdjust"
                           withInputParameters:@{
                               @"inputHighlightAmount": @(0.85),
                               @"inputShadowAmount": @(1.35)
                           }];
    }
    
    // 2b. Per-file tone shaping from the adaptive profile: open shadows, recover highlights,
    //     trim an oversaturated source and moderate a colour cast without removing the look.
    if (self.shadowLift > 0.01 || self.highlightRecovery > 0.01) {
        output = [output imageByApplyingFilter:@"CIHighlightShadowAdjust"
                           withInputParameters:@{
                               @"inputHighlightAmount": @(1.0 - self.highlightRecovery * 0.5),
                               @"inputShadowAmount": @(self.shadowLift * 0.6)
                           }];
    }
    if (fabs(self.saturationTrim) > 0.01) {
        output = [output imageByApplyingFilter:@"CIColorControls"
                           withInputParameters:@{kCIInputSaturationKey: @(1.0 + self.saturationTrim)}];
    }
    if (fabs(self.temperatureShift) > 0.01) {
        // Positive shifts warm the picture (more red, less blue); negative shifts cool it.
        double k = self.temperatureShift * 0.12;
        output = [output imageByApplyingFilter:@"CIColorMatrix"
                           withInputParameters:@{
                               @"inputRVector": [CIVector vectorWithX:1.0 + k Y:0 Z:0 W:0],
                               @"inputBVector": [CIVector vectorWithX:0 Y:0 Z:1.0 - k W:0]
                           }];
    }
    
    // 3. Apple Perceptual Vibrance (skin-tone protecting vibrance model)
    if (self.vividVibrance > 0.01) {
        float amount = (float)(self.vividVibrance * 1.6);
        output = [output imageByApplyingFilter:@"CIVibrance"
                           withInputParameters:@{
                               @"inputAmount": @(amount)
                           }];
    }
    
    // 4. Cinema Color Grade & Micro-Contrast
    if (self.cinemaColorGrade) {
        output = [output imageByApplyingFilter:@"CIColorControls"
                           withInputParameters:@{
                               kCIInputContrastKey: @(1.08),
                               kCIInputSaturationKey: @(1.12),
                               kCIInputBrightnessKey: @(0.01)
                           }];
        output = [output imageByApplyingFilter:@"CITemperatureAndTint"
                           withInputParameters:@{
                               @"inputNeutral": [CIVector vectorWithX:6500 Y:0],
                               @"inputTargetNeutral": [CIVector vectorWithX:6300 Y:0]
                           }];
    } else if (self.microContrast > 0.01) {
        float contrast = (float)(1.0 + self.microContrast * 0.22);
        output = [output imageByApplyingFilter:@"CIColorControls"
                           withInputParameters:@{
                               kCIInputContrastKey: @(contrast)
                           }];
    }
    
    // 5. Luminance Sharpness (pure luma sharpening, avoiding chroma noise)
    if (self.luminanceSharpness > 0.01) {
        float sharpness = (float)(self.luminanceSharpness * 1.4);
        output = [output imageByApplyingFilter:@"CISharpenLuminance"
                           withInputParameters:@{
                               kCIInputSharpnessKey: @(sharpness)
                           }];
    }
    
    // 6. Crisp Detail Boost (Adaptive Unsharp Mask)
    if (self.clarityBoost > 0.01) {
        float intensity = (float)(self.clarityBoost * 1.1);
        output = [output imageByApplyingFilter:@"CIUnsharpMask"
                           withInputParameters:@{
                               kCIInputRadiusKey: @(2.2),
                               kCIInputIntensityKey: @(intensity)
                           }];
    }
    
    // 7. AI Upscaling & Super-Resolution (Lanczos with edge preservation)
    if (self.upscaleFactor > 1.01) {
        double scale = self.upscaleFactor;
        CIImage *cropped = [output imageByCroppingToRect:extent];
        CIImage *normalized = [cropped imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        CIImage *scaled = [normalized imageByApplyingFilter:@"CILanczosScaleTransform"
                                        withInputParameters:@{
                                            kCIInputScaleKey: @(scale),
                                            kCIInputAspectRatioKey: @1.0
                                        }];
        CGRect scaledExtent = CGRectMake(0, 0, ceil(extent.size.width * scale), ceil(extent.size.height * scale));
        output = [scaled imageByCroppingToRect:scaledExtent];
        return output;
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
    NSString *rearL = @"0.5*c0-0.5*c1", *rearR = @"0.5*c1-0.5*c0";
    NSString *sideL = @"0.65*c0-0.65*c1", *sideR = @"0.65*c1-0.65*c0";
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
        // Gentle spectral denoising and presence EQ; this is not a trained AI model.
        [filters addObject:@"afftdn=nr=6:nf=-55:tn=1"];
        [filters addObject:@"equalizer=f=2500:t=q:w=1:g=1.5"];
    }
    if (self.bassExtension) {
        [filters addObject:@"asubboost=dry=0.9:wet=0.15:boost=1.5:feedback=0.3:cutoff=90"];
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
        [filters addObject:@"aexciter=amount=0.8:drive=1.2:freq=7000:ceil=18000"];
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
        [filters addObject:@"acompressor=threshold=-22dB:ratio=4:attack=10:release=150:makeup=1.5"];
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
        [filters addObject:@"stereowiden=delay=15:feedback=0.15:crossfeed=0.25"];
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
        [filters addObject:@"stereowiden=delay=12:feedback=0.1:crossfeed=0.3"];
    } else if ([self.surroundMethod isEqualToString:@"subwoofer_21"]) {
        [filters addObject:@"aformat=channel_layouts=stereo"];
        [filters addObject:@"virtualbass=cutoff=100:strength=2.5"];
        [filters addObject:@"bass=g=3.5:f=75:w=0.7"];
        if ([self.targetLayout isEqualToString:@"2.1"]) {
            [filters addObject:@"pan=2.1|c0=c0|c1=c1|c2=0.5*c0+0.5*c1"];
        }
    }
    
    // 7. Dynamic Loudness Normalization (Real-time zero latency)
    if (self.loudnessNormalize) {
        [filters addObject:@"acompressor=threshold=-20dB:ratio=3:attack=10:release=120:makeup=1.5"];
    }
    
    // 8. Universal Master Limiter - Prevents any clipping or cracking on CoreAudio DAC output
    if (filters.count > 0) {
        [filters addObject:@"alimiter=limit=0.95:attack=5:release=50:asc=0:level=0"];
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
    
    if ([presetName isEqualToString:@"vivid_crisp"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.55;
        _luminanceSharpness = 0.65;
        _adaptiveDenoise = 0.20;
        _microContrast = 0.45;
        _vividVibrance = 0.70;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = YES;
    } else if ([presetName isEqualToString:@"cinema_hdr"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.35;
        _luminanceSharpness = 0.45;
        _adaptiveDenoise = 0.15;
        _microContrast = 0.60;
        _vividVibrance = 0.40;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = YES;
        _visionSaliencyFocus = YES;
    } else if ([presetName isEqualToString:@"anime_pop"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.70;
        _luminanceSharpness = 0.80;
        _adaptiveDenoise = 0.40;
        _microContrast = 0.50;
        _vividVibrance = 0.90;
        _hdrDynamicTone = NO;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
    } else if ([presetName isEqualToString:@"super_resolution_2x"]) {
        _upscaleFactor = 2.0;
        _clarityBoost = 0.60;
        _luminanceSharpness = 0.50;
        _adaptiveDenoise = 0.25;
        _microContrast = 0.30;
        _vividVibrance = 0.30;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = YES;
    } else if ([presetName isEqualToString:@"clean_restore"]) {
        _upscaleFactor = 1.0;
        _clarityBoost = 0.30;
        _luminanceSharpness = 0.40;
        _adaptiveDenoise = 0.75;
        _microContrast = 0.25;
        _vividVibrance = 0.20;
        _hdrDynamicTone = YES;
        _cinemaColorGrade = NO;
        _visionSaliencyFocus = NO;
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
