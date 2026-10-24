//
//  VPAIEnhancer.h
//  vplay
//

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const VPAIEnhancerDidChangeNotification;

@class VPMediaProfile;

@interface VPAIEnhancer : NSObject

+ (instancetype)shared;

#pragma mark - Video AI Enhancement Properties

@property (atomic) BOOL videoAIEnabled;              // Master switch; NO by default so playback starts untouched
@property (atomic, copy) NSString *activeVideoPreset; // @"none", @"adaptive", @"vivid_crisp", @"cinema_hdr", @"anime_pop", @"super_resolution_2x", @"clean_restore"

// AI Upscaling
@property (atomic) double upscaleFactor; // 1.0 (off), 1.5, 2.0, 3.0, 4.0

// AI Clarity & Sharpness
@property (atomic) double clarityBoost;        // 0.0 ... 1.0 (CIUnsharpMask adaptive)
@property (atomic) double luminanceSharpness;  // 0.0 ... 1.0 (CISharpenLuminance)
@property (atomic) double adaptiveDenoise;     // 0.0 ... 1.0 (CINoiseReduction)
@property (atomic) double microContrast;       // 0.0 ... 1.0 (Local contrast & detail)

// AI Color & Vividness
@property (atomic) double vividVibrance;       // 0.0 ... 1.0 (Apple CIVibrance - skin-tone preserving)
@property (atomic) BOOL hdrDynamicTone;        // CIHighlightShadowAdjust dynamic range
@property (atomic) BOOL cinemaColorGrade;      // Cinema S-curve & warm highlight balance

// Apple Vision AI Features
@property (atomic) BOOL visionSaliencyFocus;   // Apple Vision VNGenerateAttentionBasedSaliencyImageRequest

// Per-file tone shaping (set from the adaptive profile, adjustable like the others)
@property (atomic) double shadowLift;          // 0.0 ... 1.0 opens up crushed shadows
@property (atomic) double highlightRecovery;   // 0.0 ... 1.0 brings back blown highlights
@property (atomic) double saturationTrim;      // -0.5 ... 0.5 tames or lifts overall saturation
@property (atomic) double temperatureShift;    // -0.5 (cooler) ... 0.5 (warmer)

@property (atomic, readonly) BOOL isVideoAIActive;
@property (atomic, readonly) NSUInteger revision;

#pragma mark - Adaptive (per-file) enhancement

/// When on, the "adaptive" preset measures each file (picture, sound, encoding) and derives its own settings,
/// so two different files are enhanced differently. See VPMediaAnalyzer.
@property (atomic) BOOL adaptiveVideoEnabled;
@property (atomic) BOOL adaptiveAudioEnabled;
/// The profile of the file playing now, nil until it has been analyzed.
@property (atomic, strong, nullable) VPMediaProfile *adaptiveProfile;
/// Sound corrections derived for the current file (a libavfilter graph fragment).
@property (atomic, copy, nullable) NSString *adaptiveAudioGraph;
/// Copies the profile's derived settings into the active video and audio parameters.
- (void)applyAdaptiveProfile:(VPMediaProfile *)profile;

#pragma mark - Audio AI & Surround Properties

@property (atomic) BOOL audioAIEnabled;
@property (atomic, copy) NSString *activeAudioPreset; // @"none", @"adaptive", @"matrix_ai", @"clear_dialogue", @"spatial_3d", @"surround_51", @"surround_71", @"studio_master", @"night_mode", @"loudnorm", @"bass_punch"
@property (atomic, copy) NSString *surroundMethod;    // @"none", @"matrix_ai", @"apple_spatial", @"apple_51", @"apple_71", @"ffmpeg_51", @"ffmpeg_71", @"stereo_wide", @"subwoofer_21"
@property (atomic, copy) NSString *outputCodec;       // @"pcm", @"ac3", @"eac3", @"dts", @"aac", @"alac", @"flac", @"opus", @"mp3"
@property (atomic, copy) NSString *targetLayout;      // @"auto", @"mono", @"stereo", @"2.1", @"4.0", @"4.1", @"5.0", @"5.1", @"7.1"
@property (atomic, copy) NSString *targetSampleRate;  // @"auto", @"44100", @"48000", @"88200", @"96000", @"176400", @"192000", @"384000", @"max"

@property (atomic) BOOL surroundFill;
@property (atomic) BOOL audioClarity;
@property (atomic) BOOL bassExtension;
@property (atomic) BOOL dialogueBoost;
@property (atomic) BOOL harmonicCrystalizer;
@property (atomic) BOOL loudnessNormalize;
@property (atomic) BOOL nightMode;
@property (atomic) BOOL bassImpact;
@property (atomic) BOOL trebleSparkle;

@property (atomic, readonly) BOOL isAudioAIActive;

#pragma mark - Operations

- (void)changed;

// Process frame through Apple AI video filters
- (CIImage *)processImage:(CIImage *)input;

// Construct full FFmpeg / Apple AI audio filter graph string (for the system default output device)
- (NSString *)audioFilterGraphString;
/// Same graph, shaped for a specific output device: Matrix AI feeds every speaker that device has.
/// `deviceUID` nil means the system default output device.
- (NSString *)audioFilterGraphStringForDeviceUID:(nullable NSString *)deviceUID;
/// The speaker layout Matrix AI fills: the target layout, or when that is auto the output device's own speaker count.
- (NSString *)matrixLayoutForDeviceUID:(nullable NSString *)deviceUID;
/// Layout name ("mono", "stereo", "2.1", "4.0", "5.0", "5.1", "7.1") for a device with this many output channels.
+ (NSString *)layoutForChannelCount:(NSUInteger)channels;
/// Stereo-to-speaker mixing matrix for an explicit output layout.
+ (NSString *)matrixPanForLayout:(NSString *)layout;

// Presets
- (void)applyVideoPreset:(NSString *)presetName;
- (void)applyAudioPreset:(NSString *)presetName;

- (void)resetVideoAI;
- (void)resetAudioAI;

// Codec display title
+ (NSString *)displayNameForCodec:(NSString *)codec;
+ (NSString *)displayNameForLayout:(NSString *)layout;
+ (NSString *)displayNameForSurroundMethod:(NSString *)method;

@end

NS_ASSUME_NONNULL_END
