#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPDiscKind) {
    VPDiscKindNone = 0,
    VPDiscKindDVD,
    VPDiscKindBluRay,
    VPDiscKindSVCD,
    VPDiscKindVCD,
    VPDiscKindAudioCD
};

/// Metadata for an audio or subtitle track declared in DVD IFO or Blu-ray MPLS tables.
@interface VPDiscStreamInfo : NSObject
@property (nonatomic, assign) int index;           // Logical track index (0, 1, 2...)
@property (nonatomic, assign) int streamID;        // MPEG-PS substream ID (e.g. 0x80, 0x20) or MPEG-TS PID (e.g. 0x1100, 0x1200)
@property (nonatomic, copy) NSString *codecName;   // e.g. "ac3", "dts", "pcm_dvd", "dvd_subtitle", "hdmv_pgs_subtitle"
@property (nonatomic, copy) NSString *language;    // ISO 639-1/2 code or human readable language (e.g. "en", "eng", "English")
@property (nonatomic, copy) NSString *title;       // Human-readable description (e.g. "English (AC-3 5.1ch)")
@property (nonatomic, assign) int channels;        // Audio channels (2, 6, 8...)
@property (nonatomic, assign) int sampleRate;      // Audio sample rate (48000, 96000...)
@property (nonatomic, assign) BOOL isSubtitle;
@end

/// Chapter marker within a disc title.
@interface VPDiscChapter : NSObject
@property (nonatomic, assign) NSInteger index;     // 1-based chapter number
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) double startTime;    // Seconds from start of title
@property (nonatomic, assign) double duration;     // Seconds
@end

/// A playable Title or Menu on a DVD, Blu-ray, Audio CD, VCD, or SVCD.
@interface VPDiscTitle : NSObject
@property (nonatomic, assign) NSInteger dvdProgramChain;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSNumber *> *> *dvdCells;
@property (nonatomic, assign) NSInteger index;     // 1-based title number (0 for menus)
@property (nonatomic, copy) NSString *title;       // e.g. "DVD Root Menu", "Title 1 — Main Feature (1:58:24)"
@property (nonatomic, assign) BOOL isMenu;         // YES if this is a Top Menu / Root Menu / Title Menu
@property (nonatomic, assign) BOOL isMainFeature;  // YES if this is the primary feature title
@property (nonatomic, assign) double duration;     // Seconds
@property (nonatomic, assign) double aspectRatio;  // 16.0/9.0 or 4.0/3.0
@property (nonatomic, strong, nullable) NSURL *playbackURL; // .ffconcat or direct media file URL
@property (nonatomic, copy) NSArray<NSURL *> *segmentURLs;
@property (nonatomic, copy) NSArray<VPDiscChapter *> *chapters;
@property (nonatomic, copy) NSArray<VPDiscStreamInfo *> *audioStreams;
@property (nonatomic, copy) NSArray<VPDiscStreamInfo *> *subtitleStreams;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *clutPaletteRGBA; // 16 x uint32 RGBA for DVD subtitles
@end

/// Complete structure of an optical disc (Menus, Titles, Chapters, Audio & Subtitle Streams).
@interface VPDiscMenuStructure : NSObject
@property (nonatomic, strong) NSURL *discRootURL;
@property (nonatomic, assign) VPDiscKind kind;
@property (nonatomic, copy) NSString *discName;
@property (nonatomic, copy) NSArray<VPDiscTitle *> *menus;
@property (nonatomic, copy) NSArray<VPDiscTitle *> *titles;
@property (nonatomic, readonly, nullable) VPDiscTitle *mainTitle;
@property (nonatomic, readonly, nullable) VPDiscTitle *primaryMenu;
@end

/// parsed metadata from a vplay-generated .ffconcat file.
@interface VPFFConcatMetadata : NSObject
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSNumber *> *> *dvdCells;
@property (nonatomic, copy) NSString *discKindName;
@property (nonatomic, copy) NSString *titleName;
@property (nonatomic, assign) BOOL isMenu;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double aspectRatio;
@property (nonatomic, copy) NSArray<NSNumber *> *paletteRGBA; // 16 x uint32 RGBA
@property (nonatomic, copy) NSArray<VPDiscStreamInfo *> *audioStreams;
@property (nonatomic, copy) NSArray<VPDiscStreamInfo *> *subtitleStreams;
@property (nonatomic, copy) NSArray<VPDiscChapter *> *chapters;
@property (nonatomic, copy) NSArray<NSURL *> *segmentURLs;
@end

/// Detects optical disc folders, physical disc mounts, Audio CDs, and ISO/IMG images,
/// parses DVD (.IFO) and Blu-ray (.mpls) menu/title/chapter/stream structures,
/// and produces seamless multi-segment playback plans.
@interface VPDiscSupport : NSObject
+ (VPDiscKind)kindForURL:(NSURL *)url;
+ (NSString *)nameForKind:(VPDiscKind)kind;
+ (BOOL)isDiscOrImageURL:(NSURL *)url;
+ (BOOL)isDiscImage:(NSURL *)url;
+ (NSString *)titleForDisc:(NSURL *)url;
+ (NSArray<NSURL *> *)mountedDiscs;
+ (void)mountImageAtURL:(NSURL *)url completion:(void (^)(NSURL *_Nullable volume, NSError *_Nullable error))completion;
+ (nullable NSArray<NSURL *> *)playableURLsFromURL:(NSURL *)url error:(NSError **)error;
+ (nullable NSArray<NSURL *> *)playableURLsForDisc:(NSURL *)url error:(NSError **)error;
+ (nullable VPDiscMenuStructure *)menuStructureForURL:(NSURL *)url;
+ (nullable VPFFConcatMetadata *)parseFFConcatFileAtURL:(NSURL *)url;
+ (NSString *)displayLanguageForCode:(NSString *)code;
/// The VIDEO_TS folder of an authored DVD (disc volume, ripped folder, VIDEO_TS folder, or a file
/// inside it), ready for the DVD navigation engine. nil when the URL is not a complete DVD
/// structure, for example a lone VOB file, which plays through the regular media path instead.
+ (nullable NSURL *)dvdNavigationURLForURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
