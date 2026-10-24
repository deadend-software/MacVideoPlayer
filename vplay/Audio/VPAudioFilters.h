#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const VPAudioFiltersDidChangeNotification;

/// One entry in the built-in catalogue of FFmpeg audio filters.
@interface VPAudioFilterTemplate : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *details;
@property (nonatomic, copy) NSString *format;
@property (nonatomic, copy, nullable) NSString *amountName;
@property (nonatomic) double minimum;
@property (nonatomic) double maximum;
@property (nonatomic) double defaultAmount;
@property (nonatomic, copy) NSString *unit;
@property (nonatomic, copy) NSString *optionsSummary;
@end

/// Holds the user's ordered chain of FFmpeg audio filters and 10-band Equalizer.
/// A stage dictionary has `id` (a template identifier) and `amount`, or `custom` (a raw libavfilter expression).
@interface VPAudioFilters : NSObject
@property (class, nonatomic, readonly) VPAudioFilters *shared;

/// Master enable for the audio filter & equalizer pipeline.
@property (nonatomic) BOOL enabled;

/// Ordered list of FFmpeg audio filter stage dictionaries.
@property (nonatomic, copy) NSArray<NSDictionary *> *stages;

/// 10-Band Graphic Equalizer (31 Hz, 62 Hz, 125 Hz, 250 Hz, 500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz, 16 kHz)
@property (nonatomic) BOOL equalizerEnabled;
@property (nonatomic) double equalizerPreamp; // -12.0 to +12.0 dB
@property (nonatomic, copy) NSArray<NSNumber *> *equalizerBands; // 10 NSNumbers (-12.0 to +12.0 dB)
@property (nonatomic, copy) NSString *equalizerPreset;

@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly, getter=isEqualizerActive) BOOL equalizerActive;
@property (nonatomic, readonly) NSString *equalizerGraph;
@property (nonatomic, readonly) NSString *stagesGraph;
@property (nonatomic, readonly) NSString *graph;

+ (NSArray<NSString *> *)categories;
+ (NSArray<VPAudioFilterTemplate *> *)library;
+ (nullable VPAudioFilterTemplate *)templateWithIdentifier:(NSString *)identifier;

+ (NSArray<NSNumber *> *)equalizerFrequencies;
+ (NSArray<NSString *> *)equalizerBandLabels;
+ (NSArray<NSString *> *)equalizerPresets;
+ (nullable NSArray<NSNumber *> *)gainsForEqualizerPreset:(NSString *)presetName;

- (void)applyEqualizerPreset:(NSString *)presetName;
- (void)resetEqualizer;
- (void)setGain:(double)gainDB forBand:(NSUInteger)bandIndex;

+ (NSString *)filterTextForStage:(NSDictionary *)stage;
+ (NSString *)titleForStage:(NSDictionary *)stage;

- (void)changed;
- (NSArray<NSDictionary *> *)stagesForPersistence;
- (void)loadFromArray:(nullable NSArray *)array enabled:(BOOL)enabled;
- (NSDictionary *)dictionaryRepresentation;
- (void)loadFromDictionary:(nullable NSDictionary *)dict;

/// Renders a short musical chord through `graph` into a temporary WAV file for previewing.
+ (void)renderDemoWithGraph:(nullable NSString *)graph completion:(void (^)(NSURL * _Nullable wavURL, NSString * _Nullable errorMessage))completion;
@end

NS_ASSUME_NONNULL_END
