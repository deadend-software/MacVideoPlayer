#import <Foundation/Foundation.h>

struct AVChannelLayout;

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

/// Per-speaker volume trim in dB (-12...+12), keyed by speaker group: front, center, subwoofer, rear, side.
/// "rear" is the surround pair of a 5.1 layout (or the back pair of a 7.1 layout); "side" exists only in 7.1.
/// The trims act on the decoded channels before any downmix, so they also shape a stereo or headphone mix.
/// Changing a level takes effect on the playing audio immediately.
@property (atomic, readonly) NSUInteger speakerRevision;
/// When on, the levels come from an analysis of the playing file (see VPMediaAnalyzer) and the manual levels are
/// kept aside, untouched, until it is switched off again.
@property (nonatomic) BOOL autoSpeakerLevels;
/// Shown next to the checkbox: "Analyzing…", what was found, or why nothing could be changed.
@property (atomic, copy, nullable) NSString *autoSpeakerStatus;
/// Levels measured for the current file, keyed like the manual ones; nil clears them (a new file started).
- (void)setAutomaticSpeakerLevels:(nullable NSDictionary<NSString *, NSNumber *> *)levels;
@property (atomic, readonly) BOOL hasAutomaticSpeakerLevels;
+ (NSArray<NSString *> *)speakerGroups;
+ (NSString *)titleForSpeakerGroup:(NSString *)group;
- (double)levelForSpeakerGroup:(NSString *)group;
- (void)setLevel:(double)decibels forSpeakerGroup:(NSString *)group;
- (void)resetSpeakerLevels;
@property (nonatomic, readonly) BOOL hasSpeakerLevels;

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

/// The speaker group (front, center, subwoofer, rear, side) that channel `index` of `layout` belongs to, or nil for
/// channels with no speaker group (such as height channels). A layout with back channels has a distinct side pair;
/// without them the side channels are the surround pair and count as rear.
NSString *_Nullable VPSpeakerGroupForChannelIndex(const struct AVChannelLayout *layout, int index);

NS_ASSUME_NONNULL_END
