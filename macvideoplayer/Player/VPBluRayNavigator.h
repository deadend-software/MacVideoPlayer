//
//  VPBluRayNavigator.h
//  macvideoplayer
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A selectable button of an interactive-graphics (IG) menu page. Geometry is in video pixels, origin at the top left.
@interface VPBluRayButton : NSObject
@property (nonatomic) NSInteger buttonID;
@property (nonatomic) NSInteger numericValue;      // the number key that selects this button, or 0
@property (nonatomic) NSRect frame;
@property (nonatomic) NSInteger upID;               // neighbour button IDs, -1 when there is none
@property (nonatomic) NSInteger downID;
@property (nonatomic) NSInteger leftID;
@property (nonatomic) NSInteger rightID;
@property (nonatomic, strong, nullable) NSImage *normalImage;
@property (nonatomic, strong, nullable) NSImage *selectedImage;
@property (nonatomic, strong, nullable) NSImage *activatedImage;
@end

/// One decoded menu page: the buttons and their pictures.
@interface VPBluRayMenuPage : NSObject
@property (nonatomic) NSSize videoSize;
@property (nonatomic, copy) NSArray<VPBluRayButton *> *buttons;
@property (nonatomic) NSInteger defaultButtonID;   // -1 when the disc leaves the choice to the player
- (nullable VPBluRayButton *)buttonWithID:(NSInteger)buttonID;
@end

/// What a playlist (.mpls) contains, as far as playback and menus are concerned.
@interface VPBluRayPlaylist : NSObject
@property (nonatomic, copy) NSString *name;                      // "00001"
@property (nonatomic, copy) NSArray<NSURL *> *clipURLs;
@property (nonatomic) double duration;                           // seconds
@property (nonatomic) BOOL hasInteractiveGraphics;               // an IG stream: this playlist is a menu
@property (nonatomic) NSInteger audioStreamCount;
@property (nonatomic, copy) NSArray<NSNumber *> *markTimes;      // chapter (entry mark) start times in seconds
@end

@class VPBluRayNavigator;

@protocol VPBluRayNavigatorDelegate <NSObject>
/// Play a movie playlist. `audioStream` is 1-based; 0 keeps the playlist's default.
- (void)bluRayNavigator:(VPBluRayNavigator *)navigator playPlaylist:(VPBluRayPlaylist *)playlist
           startSeconds:(double)seconds audioStream:(NSInteger)audioStream;
/// Show the interactive menu carried by `playlist`.
- (void)bluRayNavigator:(VPBluRayNavigator *)navigator showMenuForPlaylist:(VPBluRayPlaylist *)playlist
                   page:(VPBluRayMenuPage *)page selectedButton:(NSInteger)buttonID;
/// Nothing is left to run (the disc's navigation ended or hit something this player cannot do).
- (void)bluRayNavigator:(VPBluRayNavigator *)navigator didEndWithMessage:(nullable NSString *)message;
@end

/// Runs a Blu-ray's HDMV navigation: index.bdmv, MovieObject.bdmv commands and the IG menus carried in
/// the menu playlists. It decides *what* plays; the window controller plays it and reports back when a title ends.
/// Discs whose menus are Java (BD-J) are not supported and are refused by +navigatorForDiscRoot:.
@interface VPBluRayNavigator : NSObject
@property (nonatomic, weak, nullable) id<VPBluRayNavigatorDelegate> delegate;
@property (nonatomic, strong, readonly) NSURL *discRoot;
/// nil unless the disc has a readable HDMV index and movie objects.
+ (nullable instancetype)navigatorForDiscRoot:(NSURL *)discRoot;
/// Runs First Playback, which on most discs ends in the top menu.
- (void)start;
/// The menu showed this button: runs the commands authored on it.
- (void)activateButton:(NSInteger)buttonID;
/// The playlist handed to the delegate has finished; navigation continues with the next command.
- (void)playbackDidFinish;
/// The viewer asked for the disc's top menu.
- (void)showTopMenu;
- (nullable VPBluRayPlaylist *)playlistNamed:(NSString *)name;
/// The disc's movie playlists (not menus, not trivially short), longest first, for a title list.
- (NSArray<VPBluRayPlaylist *> *)moviePlaylists;
/// Plays one playlist chosen by the viewer, outside the disc's own command flow; the top menu returns when it ends.
- (void)playMoviePlaylist:(VPBluRayPlaylist *)playlist;
/// Plays the longest movie playlist, which on an ordinary disc is the main feature.
- (void)playMainMovie;
@end

NS_ASSUME_NONNULL_END
