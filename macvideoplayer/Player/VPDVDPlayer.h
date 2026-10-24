//
//  VPDVDPlayer.h
//  macvideoplayer
//

#import <AppKit/AppKit.h>
#import "VPStagePlayer.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPDVDNavigation) {
    VPDVDNavigationActivate = 0,
    VPDVDNavigationUp,
    VPDVDNavigationDown,
    VPDVDNavigationLeft,
    VPDVDNavigationRight
};

/// Authored DVD playback through libdvdnav (menus, highlights, stills, title jumps). Decoded frames and
/// sound are handed to the app instead of being drawn by the engine, so the stage's transport controls,
/// the Core Image effects (including AI video) and the audio filter graph (including AI audio) all apply.
@interface VPDVDPlayer : NSObject <VPStagePlayer>

@property (nonatomic, copy, nullable) void (^frameHandler)(CVPixelBufferRef pixelBuffer, double pts);
/// The interleaved float samples about to be played, after the filter graph (for meters and visualizers).
@property (nonatomic, copy, nullable) void (^audioSamplesHandler)(const float *samples, NSUInteger count, NSUInteger channels);
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;
@property (nonatomic, assign) float volume;
@property (atomic, copy, nullable) NSString *audioOutputLayout;
/// YES while the disc shows one of its menus rather than a title.
@property (nonatomic, readonly) BOOL inMenu;
@property (nonatomic, copy, nullable) void (^errorHandler)(NSError *error);
/// Called on the main queue a few times per second with a short description of where the disc is
/// ("DVD Menu", "Title 1 · Chapter 3"); the window shows it and uses it to refresh the DVD bar.
@property (nonatomic, copy, nullable) void (^statusHandler)(NSString *status);

/// Where libaacs looks for the user's Blu-ray key database. The sandbox maps the home folder into the app's
/// container, so this is the file libaacs finds as ~/Library/Preferences/aacs/KEYDB.cfg.
+ (NSURL *)aacsKeyDatabaseURL;
+ (BOOL)hasAACSKeyDatabase;
/// Copies a key database the user chose into place.
+ (BOOL)installAACSKeyDatabaseAtURL:(NSURL *)source error:(NSError **)error;
/// YES for a Blu-ray folder (disc root) that carries AACS copy protection.
+ (BOOL)isAACSProtectedBluRayAtURL:(NSURL *)discRoot;
/// The folder libbdplus reads its device keys and tables from (created on demand). BD+ discs need data the
/// user supplies there; none is bundled.
+ (NSURL *)bdplusDataFolderURL:(NSError **)error;
/// Installs a BD+ file the user chose where libbdplus reads it: `aes_keys.bin` goes to the BD+ data folder and
/// `slots.bin` to the BD+ cache (~/Library/Caches/bdplus). Any other file name is refused. Returns the
/// installed file name, or nil with `error` set.
+ (nullable NSString *)installBDPlusFileAtURL:(NSURL *)source error:(NSError **)error;

/// `videoTS` is the disc's VIDEO_TS folder (see +[VPDiscSupport dvdNavigationURLForURL:]).
- (BOOL)openDiscAtURL:(NSURL *)videoTS error:(NSError **)error;
/// A Blu-ray disc image (.iso), read directly by the engine's Blu-ray module.
- (BOOL)openBluRayImageAtURL:(NSURL *)image error:(NSError **)error;
- (void)showDiscMenu;
- (void)navigate:(VPDVDNavigation)direction;
- (void)togglePlayPause;
- (void)seekToSeconds:(double)seconds;
/// The disc's titles that are real content, for the navigation bar: @{@"index", @"name", @"duration"} in seconds.
- (NSArray<NSDictionary *> *)discTitles;
/// Chapters of the title playing now: @{@"index", @"name", @"start", @"duration"}.
- (NSArray<NSDictionary *> *)discChapters;
- (void)selectTitle:(NSInteger)index;
- (void)selectChapter:(NSInteger)index;
- (void)nextChapter;
- (void)previousChapter;
/// The disc's audio and subtitle streams, read from the playback engine (no external tools): @{@"id", @"name"}.
/// Subtitles include the engine's "Disable" entry (id -1); audio never lists it.
- (NSArray<NSDictionary *> *)audioTracks;
- (NSArray<NSDictionary *> *)subtitleTracks;
/// The id of the stream playing now, or -1 when none (subtitles off).
- (NSInteger)selectedAudioTrackID;
- (NSInteger)selectedSubtitleTrackID;
- (BOOL)selectAudioTrackID:(NSInteger)trackID;
/// Pass -1 to turn subtitles off.
- (BOOL)selectSubtitleTrackID:(NSInteger)trackID;
/// Starts the longest title, which on an ordinary disc is the main feature.
- (void)playMainTitle;
/// Arrow keys, Return, Escape and Space drive the disc; returns NO for keys it does not use.
- (BOOL)handleKeyEvent:(NSEvent *)event;
/// Replaces the libavfilter graph the disc's sound runs through (nil or empty for none). Takes effect at once.
- (void)applyAudioFiltersGraph:(nullable NSString *)graphString;
- (void)stop;

@end


NS_ASSUME_NONNULL_END
