//
//  VPMediaAnalyzer.h
//  vplay
//

#import <Foundation/Foundation.h>

@class VPMediaProbe;

NS_ASSUME_NONNULL_BEGIN

/// What one media file looks and sounds like, and the enhancement settings derived from that.
/// Two files get different profiles because their pictures, sound and encoding differ.
@interface VPMediaProfile : NSObject

@property (nonatomic, copy) NSString *fingerprint;   // path, size and modification time; the cache key
@property (nonatomic, copy) NSString *summary;       // short human-readable description for the OSD

// Picture measurements (sampled keyframes spread across the file)
@property (nonatomic) BOOL hasVideo;
@property (nonatomic) NSSize videoSize;
@property (nonatomic) double frameRate;
@property (nonatomic) BOOL interlaced;
@property (nonatomic, copy, nullable) NSString *videoCodec;
@property (nonatomic) int bitDepth;
@property (nonatomic) double bitsPerPixel;      // compressed bits per pixel per frame; low means heavy compression
@property (nonatomic) double meanLuma;          // 0..1
@property (nonatomic) double lumaSpread;        // standard deviation of luma, 0..1 (contrast)
@property (nonatomic) double darkFraction;      // share of near-black pixels
@property (nonatomic) double brightFraction;    // share of near-white pixels
@property (nonatomic) double saturation;        // 0..1 mean chroma saturation
@property (nonatomic) double colorfulness;      // 0..1 spread of colours
@property (nonatomic) double warmth;            // -1 (blue cast) .. 1 (red/yellow cast)
@property (nonatomic) double noise;             // estimated noise sigma in 8-bit levels
@property (nonatomic) double sharpness;         // 0..1 crispness of edges
@property (nonatomic) double flatness;          // share of flat, texture-free area (high for animation)
@property (nonatomic) double edgeDensity;       // share of strong edge pixels
@property (nonatomic) BOOL looksAnimated;

// Sound measurements (snippets spread across the file)
@property (nonatomic) BOOL hasAudio;
@property (nonatomic) int audioChannels;
@property (nonatomic) int sampleRate;
@property (nonatomic, copy, nullable) NSString *audioCodec;
@property (nonatomic) double rmsDB;             // average level, dBFS
@property (nonatomic) double peakDB;            // highest sample, dBFS
@property (nonatomic) double crestDB;           // peak minus average: dynamic range
@property (nonatomic) double spectralTiltDB;    // bass energy over treble energy, dB (high = dull, low = thin)
@property (nonatomic) double stereoCorrelation; // 1 = mono-like, 0 = very wide

// Derived picture settings (feed VPAIEnhancer)
@property (nonatomic) double denoise;
@property (nonatomic) double lineSharpness;
@property (nonatomic) double clarity;
@property (nonatomic) double microContrast;
@property (nonatomic) double vibrance;
@property (nonatomic) double shadowLift;
@property (nonatomic) double highlightRecovery;
@property (nonatomic) double saturationTrim;
@property (nonatomic) double temperatureShift;
@property (nonatomic) double upscale;
@property (nonatomic) BOOL wantsDeinterlace;

// Derived sound settings: a libavfilter graph fragment, empty when the sound needs nothing
@property (nonatomic, copy) NSString *audioGraph;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)profileWithDictionary:(NSDictionary *)dictionary;

@end

/// Quickly measures a media file and derives its enhancement profile. Results are kept in memory for
/// this run of the app only; nothing is saved to disk.
@interface VPMediaAnalyzer : NSObject

+ (NSString *)fingerprintForURL:(NSURL *)url;
/// A profile from an earlier analysis of the same file during this app session, or nil.
+ (nullable VPMediaProfile *)cachedProfileForURL:(NSURL *)url;
/// Analyzes off the main thread within a few seconds and completes on the main queue; nil when the file cannot be read.
+ (void)analyzeURL:(NSURL *)url probe:(nullable VPMediaProbe *)probe completion:(void (^)(VPMediaProfile *_Nullable profile))completion;

@end

NS_ASSUME_NONNULL_END
