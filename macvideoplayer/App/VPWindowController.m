//
//  VPWindowController.m
//  macvideoplayer
//

#import "VPWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "VPFFmpegLibrary.h"
#import "VPFFmpegOptions.h"
#import "VPConfigurationBuilder.h"
#import "VPProcessingPlan.h"
#import "VPPreparedMedia.h"
#import "VPSkin.h"
#import "VPPlaybackEngine.h"
#import "VPFFmpegPlayer.h"
#import "VPVideoView.h"
#import "VPHUDOverlayView.h"
#import "VPConfigManager.h"
#import "VPURLHelper.h"
#import "VPMediaProbe.h"
#import "VPDiscSupport.h"
#import "VPDVDPlayer.h"
#import "VPBluRayNavigator.h"
#import "VPBluRayMenuView.h"
#import "VPDiscNavigationBar.h"
#import "VPSubtitles.h"
#import "VPEffectPipeline.h"
#import "VPEffectRenderer.h"
#import "VPPostProcessing.h"
#import "VPPostProcessingWindowController.h"
#import "VPShaderEditorWindowController.h"
#import "VPPlaylistWindowController.h"
#import "VPAIEnhancer.h"
#import "VPMediaAnalyzer.h"
#import "VPLicenseWindowController.h"
#import "VPAudioFilterWindowController.h"
#import "VPAudioOutputWindowController.h"
#import "VPAudioDeviceManager.h"
#import "VPAudioFilters.h"
#import <objc/runtime.h>
#import "VPSpeakerLevelsWindowController.h"
#import "VPAudioVisualizer.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

/// Applies the playback speed; defaultRate (which keeps the speed across pauses) needs macOS 13.
static void ApplySpeed(AVPlayer *player, float speed) {
    if (@available(macOS 13.0, *)) player.defaultRate = speed;
    if (player.rate > 0) player.rate = speed;
}

static BOOL LooksLikeAudio(NSURL *url) {
    static NSSet *audio;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        audio = [NSSet setWithArray:@[@"mp3", @"mp2", @"m4a", @"m4b", @"m4r", @"aac", @"ac3", @"eac3", @"ec3", @"dts", @"dtshd", @"wav", @"w64", @"flac", @"aiff", @"aif", @"aifc",
                                      @"ogg", @"oga", @"opus", @"spx", @"wma", @"ape", @"wv", @"mka", @"mpc", @"amr", @"au", @"snd", @"caf", @"tta", @"tak", @"ra", @"gsm", @"mid", @"midi", @"alac", @"mlp", @"thd", @"dsf", @"dff"]];
    });
    return [audio containsObject:url.pathExtension.lowercaseString];
}

@interface VPWindowController () <NSWindowDelegate, VPPlaybackEngineDelegate, VPHUDOverlayDelegate, NSMenuItemValidation, NSMenuDelegate, VPBluRayNavigatorDelegate, VPBluRayMenuViewDelegate>
@property (nonatomic, strong) VPConfigurationBuilder *builder;
@property (nonatomic, strong) VPPreparedMedia *preparedMedia;
@property (nonatomic, strong) VPMediaProbe *probe;
@property (nonatomic, strong) NSURL *sourceURL;
@property (nonatomic, copy) NSString *sourceTitle;
@property (nonatomic, strong) NSMutableDictionary *activeOptions;
@property (nonatomic, strong) NSMutableDictionary *trackOverrides;     // audioStream / videoStream / burnSubtitleStream
@property (nonatomic) NSInteger subtitleSelection;                      // -1 off, otherwise subtitle track index
@property (nonatomic) NSInteger audioSelection;
@property (nonatomic) NSInteger videoSelection;
@property (nonatomic) double preparedOffset;
@property (nonatomic) NSUInteger playbackGeneration;
@property (nonatomic) NSUInteger mediaToken;           // changes only when a different item starts

@property (nonatomic) float volumeLevel;                              // 0–1, kept across items
@property (nonatomic) BOOL muted;
@property (nonatomic) BOOL preferAVPlayer;      // AirPlay needs an AVPlayer, so the in-process player is skipped for this item
@property (nonatomic) BOOL airPlayPending;       // show the route picker as soon as the AVPlayer is up
@property (nonatomic) BOOL mayFallback;
@property (nonatomic) BOOL mediaActive;
@property (nonatomic) BOOL metadataShownForMedia;
@property (nonatomic) BOOL compositionInstalled;
@property (nonatomic) float speed;
@property (nonatomic, strong) NSWindow *settingsWindow;
@property (nonatomic, strong) NSTextView *settingsText;
@property (nonatomic, strong) VPFFmpegJob *ffmpegJob;
@property (nonatomic, strong, nullable) VPLicenseWindowController *licenseWindowController;
@property (nonatomic, strong, nullable) VPAudioFilterWindowController *audioFilterController;
@property (nonatomic, strong, nullable) VPAudioOutputWindowController *audioOutputController;
@property (nonatomic, strong, nullable) VPSpeakerLevelsWindowController *speakerLevelsController;
@property (nonatomic) BOOL bufferingStatusShown;
@property (nonatomic) NSUInteger speakerAnalysisToken;   // media token the automatic speaker levels were last requested for
@property (nonatomic, strong, nullable) VPDVDPlayer *dvdPlayer;             // present only while a DVD plays through its own menus
@property (nonatomic, strong, nullable) VPDiscNavigationBar *dvdNavigationBar;
@property (nonatomic, strong, nullable) VPBluRayNavigator *bluRayNavigator;   // present while a Blu-ray plays through its own menus
@property (nonatomic, strong, nullable) VPBluRayMenuView *bluRayMenuView;
@property (nonatomic, strong, nullable) VPDiscNavigationBar *bluRayNavigationBar;   // stays up across the disc's menus and titles
@property (nonatomic, strong, nullable) VPBluRayPlaylist *bluRayCurrentPlaylist;    // the movie playlist playing now, nil in a menu
@property (nonatomic, strong, nullable) NSTimer *discBarTimer;
@property (nonatomic) NSInteger pendingBluRayAudio;     // 1-based audio stream the disc chose for the title about to start
@property (nonatomic) double pendingBluRayStart;        // where in that title it starts (a chapter), in seconds
@property (nonatomic) BOOL startingBluRayItem;          // the next startPlaylistItem: is the disc's doing, not the user's
@property (nonatomic) BOOL bluRayMenuLooping;           // an animated menu video plays underneath the buttons
@property (nonatomic, strong, nullable) VPMediaProfile *mediaProfile;     // the adaptive AI profile of the current file, once measured
@property (nonatomic) BOOL adaptiveDeinterlaceApplied;                     // adaptive AI switched the deinterlacer on for this file
@property (nonatomic, strong) NSArray<NSPopUpButton *> *qualityMenus;
@property (nonatomic, strong) VPPlaybackEngine *playbackEngine;
@property (nonatomic, strong) VPVideoView *videoView;
@property (nonatomic, strong) VPHUDOverlayView *hudOverlay;
@property (nonatomic, strong) VPConfigManager *configManager;
@property (nonatomic, strong) VPPlaylist *playlist;
@property (nonatomic, strong) VPAudioAnalyzer *analyzer;
@property (nonatomic, strong) VPPlaylistWindowController *playlistController;
@property (nonatomic, strong) VPPostProcessingWindowController *postController;
@property (nonatomic, strong) VPShaderEditorWindowController *shaderController;
@property (nonatomic, strong) id localEventMonitor;
@property (nonatomic, strong) NSTimer *preferenceTimer;
@end

/// Data source for the disc list of the Open Disc sheet; a double-click presses the sheet's Open button.
@interface VPDiscPicker : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) NSArray<NSURL *> *discs;
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, weak) NSTableView *table;
@property (nonatomic, weak) NSButton *defaultButton;
@end

@implementation VPDiscPicker
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.discs.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"disc" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)];
        cell.identifier = @"disc";
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"opticaldisc" accessibilityDescription:nil] ?: [NSImage new]];
        icon.frame = NSMakeRect(4, 3, 20, 20);
        NSTextField *label = [NSTextField labelWithString:@""];
        label.frame = NSMakeRect(30, 4, 386, 18);
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:icon]; [cell addSubview:label];
        cell.textField = label;
    }
    cell.textField.stringValue = self.titles[row];
    cell.toolTip = self.discs[row].path;
    return cell;
}
- (void)openClicked:(id)sender {
    if (self.table.clickedRow >= 0) [self.defaultButton performClick:nil];
}
@end

@implementation VPWindowController

- (instancetype)initWithConfigManager:(VPConfigManager *)configManager {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                  styleMask:(NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Mac Video Player";
    window.minSize = NSMakeSize(560, 340);
    window.releasedWhenClosed = NO;
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    window.backgroundColor = NSColor.blackColor;
    window.frameAutosaveName = @"VPPlayerWindow";
    if (![window setFrameUsingName:@"VPPlayerWindow"]) [window center];

    self = [super initWithWindow:window];
    if (self) {
        _configManager = configManager;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(speakerLevelsDidChange:) name:VPAudioFiltersDidChangeNotification object:nil];
        _playlist = [VPPlaylist new];
        _speed = 1;
        _subtitleSelection = -1;
        _trackOverrides = [NSMutableDictionary dictionary];
        window.delegate = self;
        [self setupContentView];
        [self setupPlaybackEngine];
        [self loadPreferences];
        [self setupEventMonitor];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(effectsChanged:) name:VPPostProcessingDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playlistChanged:) name:VPPlaylistDidChangeNotification object:_playlist];
    }
    return self;
}

- (void)dealloc {
    if (self.localEventMonitor) [NSEvent removeMonitor:self.localEventMonitor];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Setup

- (void)setupContentView {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.backgroundColor = [[NSColor blackColor] CGColor];

    _videoView = [[VPVideoView alloc] initWithFrame:contentView.bounds];
    _videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:_videoView];
    __weak typeof(self) weakSelf = self;
    _volumeLevel = [self.configManager.playbackOptions[@"volume"] isKindOfClass:NSNumber.class] ? [self.configManager.playbackOptions[@"volume"] floatValue] : 1;
    _videoView.seekHandler = ^(double seconds) { [weakSelf seekToAbsolute:seconds]; };
    _videoView.volumeHandler = ^(float level) { weakSelf.volumeLevel = level; if (level > 0) weakSelf.muted = NO; [weakSelf applyVolume]; [weakSelf showVolumeOSD]; };
    [_videoView setVolumeLevel:_volumeLevel muted:NO];
    _videoView.dropHandler = ^(NSArray<NSURL *> *urls) { [weakSelf openURLs:urls shuffle:weakSelf.playlist.shuffle]; };
    _videoView.contextMenu = [self buildContextMenu];
    _analyzer = [VPAudioAnalyzer new];
    _videoView.analyzer = _analyzer;

    // HUD overlay (on top of everything), inset from the window edge like a floating chrome card.
    NSRect hudFrame = NSMakeRect(12, 12, 372, contentView.bounds.size.height - 24);
    _hudOverlay = [[VPHUDOverlayView alloc] initWithFrame:hudFrame];
    _hudOverlay.delegate = self;
    _hudOverlay.autoresizingMask = NSViewHeightSizable;
    _hudOverlay.revealsOnMouseMovement = YES;
    [contentView addSubview:_hudOverlay];

    [self applySkin:VPSkin.defaultSkin];
    [self loadBackgroundImage];
    // The HUD greets the user on launch, then fades away and returns when the pointer moves.
    [_hudOverlay showAnimated:NO];
}

- (void)applySkin:(NSDictionary *)skin {
    [self.videoView applySkin:skin];
    self.hudOverlay.skin = skin;
}

- (void)loadBackgroundImage {
    NSString *path = self.configManager.backgroundImagePath;
    NSImage *image = path.length ? [[NSImage alloc] initWithContentsOfFile:path.stringByExpandingTildeInPath] : nil;
    self.videoView.splashImage = image;   // nil restores the built-in macvideoplayer artwork
}

- (void)setupPlaybackEngine {
    _playbackEngine = [[VPPlaybackEngine alloc] init];
    _playbackEngine.delegate = self;
    _playbackEngine.looping = NO;
}

- (void)setupEventMonitor {
    __weak typeof(self) weakSelf = self;
    self.localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
        VPWindowController *controller = weakSelf;
        if (!controller || event.window != controller.window) return event;
        if (event.type == NSEventTypeMouseMoved) {
            [controller.hudOverlay noteMouseMovedAtWindowPoint:event.locationInWindow];
            return event;
        }
        return [controller handleKeyEvent:event];
    }];
}

#pragma mark - Preferences

- (void)loadPreferences {
    NSDictionary *options = self.configManager.playbackOptions;
    self.videoView.fpsVisible = [options[@"showFPS"] boolValue];
    self.videoView.visualizerOverVideo = [options[@"visualizer"] boolValue];
    NSString *style = options[@"visualizerStyle"];
    NSUInteger styleIndex = style ? [VPVisualizerStyleNames() indexOfObject:style] : NSNotFound;
    self.videoView.visualizerStyle = styleIndex == NSNotFound ? VPVisualizerStyleBars : (VPVisualizerStyle)styleIndex;
    self.playlist.shuffle = [options[@"shuffle"] boolValue];
    NSString *repeat = options[@"repeat"];
    self.playlist.repeatMode = [repeat isEqual:@"all"] ? VPRepeatAll : ([repeat isEqual:@"one"] ? VPRepeatOne : VPRepeatOff);
    if ([options[@"postProcessing"] isKindOfClass:NSDictionary.class]) [VPPostProcessing.shared applyDictionary:options[@"postProcessing"]];
    [self syncToggleStates];
}

/// Updates one key in the user's default config file without touching command-line overrides.
- (void)savePreference:(NSString *)key value:(id)value {
    NSString *path = [VPConfigManager defaultConfigPath];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    id parsed = existing ? [NSJSONSerialization JSONObjectWithData:existing options:0 error:nil] : nil;
    NSMutableDictionary *dict = [parsed isKindOfClass:NSDictionary.class] ? [parsed mutableCopy] : [NSMutableDictionary dictionary];
    dict[key] = value;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

- (void)syncToggleStates {
    [self.hudOverlay setToggle:@"shuffle" on:self.playlist.shuffle];
    [self.hudOverlay setToggle:@"visualizer" on:self.videoView.visualizerOverVideo];
    [self.hudOverlay setToggle:@"fps" on:self.videoView.fpsVisible];
    [self.videoView setShuffleOn:self.playlist.shuffle repeatMode:self.playlist.repeatMode];
}

#pragma mark - Keyboard

- (NSEvent *)handleKeyEvent:(NSEvent *)event {
    if (self.dvdPlayer && [self.dvdPlayer handleKeyEvent:event]) return nil;
    if (self.bluRayMenuView && [self.bluRayMenuView handleKeyEvent:event]) return nil;
    [self.videoView showControls];
    NSResponder *firstResponder = self.window.firstResponder;
    if ([firstResponder isKindOfClass:[NSTextView class]] || [firstResponder isKindOfClass:[NSTextField class]]) return event;   // typing in a field

    unsigned short keyCode = event.keyCode;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    NSString *character = event.charactersIgnoringModifiers.lowercaseString;

    switch (keyCode) {
        case 49: if (!command) { [self togglePlayPause:nil]; return nil; } break;   // Space
        case 48: [self toggleHUD:nil]; return nil;                                  // Tab
        case 53: if (self.hudOverlay.isVisible) { [self.hudOverlay hideAnimated:YES]; return nil; } break;   // Escape
        case 123: if (!command) { if (flags & NSEventModifierFlagShift) [self seekBackward:nil]; else [self stepFrames:-1]; return nil; } break;   // ← previous frame (⇧ 5 s back)
        case 124: if (!command) { if (flags & NSEventModifierFlagShift) [self seekForward:nil]; else [self stepFrames:1]; return nil; } break;      // → next frame (⇧ 5 s ahead)
        case 126: [self nudgeVolume:0.1f]; return nil;                              // ↑
        case 125: [self nudgeVolume:-0.1f]; return nil;                             // ↓
    }
    if (command) return event;
    if ([character isEqual:@"n"]) { [self playNext:nil]; return nil; }
    if ([character isEqual:@"p"]) { [self playPrevious:nil]; return nil; }
    if ([character isEqual:@"s"]) { [self toggleShuffle:nil]; return nil; }
    if ([character isEqual:@"r"]) { [self cycleRepeat:nil]; return nil; }
    if ([character isEqual:@"m"]) { [self toggleMute:nil]; return nil; }
    if ([character isEqual:@"v"]) { [self toggleVisualizer:nil]; return nil; }
    if ([character isEqual:@"d"]) { [self toggleFPS:nil]; return nil; }
    if ([character isEqual:@"i"]) { [self showMediaInfo:nil]; return nil; }
    if ([character isEqual:@"f"]) { [self.window toggleFullScreen:nil]; return nil; }
    if ([character isEqual:@"["]) { [self changeSpeedBy:-0.25f]; return nil; }
    if ([character isEqual:@"]"]) { [self changeSpeedBy:0.25f]; return nil; }
    return event;
}

- (void)nudgeVolume:(float)delta {
    self.volumeLevel = MAX(0, MIN(1, self.volumeLevel + delta));
    if (delta > 0) self.muted = NO;
    [self applyVolume];
    [self showVolumeOSD];
}

- (void)showVolumeOSD {
    NSString *symbol = self.muted || self.volumeLevel <= 0 ? @"speaker.slash.fill" : self.volumeLevel < 0.34 ? @"speaker.wave.1.fill" : self.volumeLevel < 0.67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill";
    [self.videoView showOSDText:self.muted ? @"Muted" : [NSString stringWithFormat:@"Volume %.0f%%", self.volumeLevel * 100] symbol:symbol level:self.muted ? 0 : self.volumeLevel];
}

/// Pushes the volume and mute state to whichever player is running and to the controls bar.
- (void)applyVolume {
    self.dvdPlayer.volume = self.muted ? 0 : self.volumeLevel;
    VPFFmpegPlayer *ffmpeg = self.playbackEngine.ffmpegPlayer;
    if (ffmpeg) ffmpeg.volume = self.muted ? 0 : self.volumeLevel;
    else if (self.playbackEngine.player) {
        self.playbackEngine.player.volume = self.volumeLevel;
        self.playbackEngine.player.muted = self.muted;
    }
    [self.videoView setVolumeLevel:self.volumeLevel muted:self.muted];
    [self.videoView showControls];
}

/// Steps the picture by whole frames; playback pauses, as in other players.
- (void)stepFrames:(NSInteger)count {
    if (!self.mediaActive) return;
    VPFFmpegPlayer *ffmpeg = self.playbackEngine.ffmpegPlayer;
    if (ffmpeg) {
        [ffmpeg stepFrames:count];
    } else if (self.playbackEngine.currentItem) {
        [self.playbackEngine pause];
        [self.playbackEngine.currentItem stepByCount:count];
    } else return;
    [self.videoView setPlaying:NO];
    [self.videoView showOSDText:count > 0 ? (count == 1 ? @"Next frame" : [NSString stringWithFormat:@"+%ld frames", (long)count]) : (count == -1 ? @"Previous frame" : [NSString stringWithFormat:@"%ld frames", (long)count])
                         symbol:count > 0 ? @"forward.frame.fill" : @"backward.frame.fill" level:-1];
}

- (void)applySpeedToPlayback {
    if (self.playbackEngine.ffmpegPlayer) self.playbackEngine.ffmpegPlayer.rate = self.speed;
    else ApplySpeed(self.playbackEngine.player, self.speed);
}

- (void)changeSpeedBy:(float)delta {
    self.speed = MAX(0.25f, MIN(4, self.speed + delta));
    [self applySpeedToPlayback];
    self.videoView.statusText = [NSString stringWithFormat:@"Speed %.2f×", self.speed];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Speed %.2f×", self.speed] symbol:@"speedometer" level:-1];
}

#pragma mark - Opening media

- (void)resolvingDiscImages:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *))completion {
    // Disc images are mounted first; their volumes replace them in the list.
    NSMutableArray *resolved = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSNumber *, NSURL *> *mounted = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < urls.count; i++) {
        if ([VPDiscSupport isDiscImage:urls[i]] && [VPDiscSupport kindForURL:urls[i]] == VPDiscKindNone) {
            dispatch_group_enter(group);
            self.videoView.statusText = @"Mounting disc image…";
            [VPDiscSupport mountImageAtURL:urls[i] completion:^(NSURL *volume, NSError *error) {
                if (volume) mounted[@(i)] = volume; else if (error) [self reportPlaybackError:error];
                dispatch_group_leave(group);
            }];
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        for (NSUInteger i = 0; i < urls.count; i++) {
            NSURL *url = mounted[@(i)] ?: urls[i];
            if (![VPDiscSupport isDiscImage:urls[i]] || mounted[@(i)] || [VPDiscSupport kindForURL:urls[i]] != VPDiscKindNone) [resolved addObject:url];
        }
        completion(resolved);
    });
}

/// Puts every video and audio option of the context menu back to its default. Opening something new does this;
/// moving through a playlist does not.
- (void)resetEnhancementOptions {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    [ai resetVideoAI];
    [ai resetAudioAI];
    ai.targetSampleRate = @"auto";
    ai.audioAIEnabled = NO;
    VPAudioFilters *filters = VPAudioFilters.shared;
    filters.autoSpeakerLevels = NO;
    [filters setAutomaticSpeakerLevels:nil];
    [filters resetSpeakerLevels];
    [filters resetEqualizer];
    [VPPostProcessing.shared resetAdjustments];
    [ai changed];
}

static NSString * const kVPKeepEnhancementOptionsKey = @"VPKeepEnhancementOptions";

/// "Keep Audio & Video Options Between Files": when on, opening another file leaves the AI, equalizer, speaker and
/// post-processing settings as they are instead of resetting them.
- (BOOL)keepsEnhancementOptions { return [NSUserDefaults.standardUserDefaults boolForKey:kVPKeepEnhancementOptionsKey]; }

- (IBAction)toggleKeepEnhancementOptions:(id)sender {
    BOOL on = ![self keepsEnhancementOptions];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kVPKeepEnhancementOptionsKey];
    [self.videoView showOSDText:on ? @"Audio & video options are kept between files" : @"Audio & video options reset for each opened file" symbol:@"slider.horizontal.3" level:-1];
}

- (void)openURLs:(NSArray<NSURL *> *)urls shuffle:(BOOL)shuffle {
    if (!urls.count) return;
    // DVD and Blu-ray images are read directly: the sandbox does not allow mounting them.
    if (urls.count == 1 && [VPDiscSupport isDiscImage:urls[0]] && [VPDiscSupport kindForURL:urls[0]] == VPDiscKindNone) {
        VPDiscKind imageKind = [VPDiscSupport kindOfDiscImageAtURL:urls[0]];
        if (imageKind == VPDiscKindDVD || imageKind == VPDiscKindBluRay) {
            [self stopPlayback:nil];
            if (![self keepsEnhancementOptions]) [self resetEnhancementOptions];
            [self.playlist clear];
            [self startDiscAtURL:urls[0] bluRayImage:imageKind == VPDiscKindBluRay];
            return;
        }
    }
    [self resolvingDiscImages:urls completion:^(NSArray<NSURL *> *resolved) {
        [self stopPlayback:nil];
        if (![self keepsEnhancementOptions]) [self resetEnhancementOptions];
        [self.playlist clear];
        if (shuffle != self.playlist.shuffle) self.playlist.shuffle = shuffle;
        // An authored DVD plays through the disc's own navigation engine so its real menus show.
        for (NSURL *u in resolved) {
            NSURL *dvd = [VPDiscSupport dvdNavigationURLForURL:u];
            if (dvd) { [self startDVDAtURL:dvd]; return; }
            // An AACS-protected Blu-ray folder goes through the disc engine, whose libaacs decrypts it.
            NSURL *bluRay = [VPDiscSupport bluRayNavigationURLForURL:u];
            if (bluRay && [VPDVDPlayer isAACSProtectedBluRayAtURL:bluRay]) { [self startDiscAtURL:bluRay bluRayImage:YES]; return; }
            // An authored Blu-ray with HDMV menus plays through its own navigation too.
            if (bluRay && [self startBluRayAtURL:bluRay]) return;
        }
        NSUInteger added = [self.playlist addInputs:resolved];
        if (!added) {
            [self reportPlaybackError:[NSError errorWithDomain:@"macvideoplayerErrorDomain" code:93 userInfo:@{NSLocalizedDescriptionKey:@"Nothing playable was found in what you chose. Folders need media files, and discs need an unprotected DVD, Blu-ray, VCD, SVCD, or Audio CD structure."}]];
            return;
        }
        [self syncToggleStates];
        [self startPlaylistItem:[self.playlist advanceAutomatically:NO]];
    }];
}

- (void)openFile:(NSURL *)fileURL { if (fileURL) [self openURLs:@[fileURL] shuffle:self.playlist.shuffle]; }

- (void)enqueueURLs:(NSArray<NSURL *> *)urls {
    [self resolvingDiscImages:urls completion:^(NSArray<NSURL *> *resolved) {
        BOOL wasEmpty = self.playlist.items.count == 0;
        [self.playlist addInputs:resolved];
        if (wasEmpty && !self.mediaActive) [self startPlaylistItem:[self.playlist advanceAutomatically:NO]];
        else self.videoView.statusText = [NSString stringWithFormat:@"%lu items in the playlist", (unsigned long)self.playlist.items.count];
    }];
}

- (void)startPlaylistItem:(VPPlaylistItem *)item {
    if (!item) return;
    BOOL fromDisc = self.startingBluRayItem;
    self.startingBluRayItem = NO;
    if (!fromDisc) [self endBluRayNavigation];      // the user chose something else: the disc's menus are done
    [self stopPlaybackKeepingStage];
    self.preferAVPlayer = NO; self.airPlayPending = NO;
    NSError *error = nil;
    NSDictionary *options = [VPProcessingPlan resolvedOptions:[self.configManager toDictionary] error:&error];
    if (!options) { [self reportPlaybackError:error]; return; }
    self.activeOptions = [options mutableCopy] ?: [NSMutableDictionary dictionary];
    self.sourceURL = item.url;
    self.sourceTitle = item.title;
    NSUInteger token = ++self.mediaToken;
    self.probe = nil;
    self.metadataShownForMedia = NO;
    self.mediaActive = YES;
    self.trackOverrides = [NSMutableDictionary dictionary];
    self.subtitleSelection = -1; self.audioSelection = 0; self.videoSelection = 0;
    if (self.pendingBluRayAudio > 1) {              // the disc picked a later audio stream, such as the commentary
        self.audioSelection = self.pendingBluRayAudio - 1;
        self.trackOverrides[@"audioStream"] = @(self.audioSelection);
    }
    self.pendingBluRayAudio = 0;
    double resume = self.pendingBluRayStart;
    self.pendingBluRayStart = 0;
    [self.videoView setSubtitleTrack:nil];
    self.window.title = [NSString stringWithFormat:@"Mac Video Player — %@", item.title];
    self.hudOverlay.revealsOnMouseMovement = NO;
    [self.hudOverlay hideAnimated:YES];
    self.videoView.mediaLoaded = YES;
    self.videoView.hasVideo = !LooksLikeAudio(item.url);
    [self updateStatusText:@"Checking media…"];
    [self loadSubtitleSidecarForCurrentMedia];

    // A file measured before gets its own enhancement profile back before the first frame.
    [self adoptCachedProfileForCurrentMedia];

    // Probe in parallel: it feeds the metadata card, track menus and frame-rate display.
    [VPMediaProbe probeURL:item.url completion:^(VPMediaProbe *probe) {
        if (token != self.mediaToken || !probe) return;
        [self probeDidFinish:probe];
    }];
    [self startCurrentWithResume:resume forcePrepared:NO];
}

/// With "automatic" speaker levels on, measures the current file (once per file; the analyzer keeps a session
/// cache) and hands the balanced levels to the audio path. Runs when a file starts and when the box is ticked.
- (void)analyzeSpeakerLevelsIfNeeded {
    VPAudioFilters *filters = VPAudioFilters.shared;
    if (!filters.autoSpeakerLevels || !self.sourceURL || !self.mediaActive || self.speakerAnalysisToken == self.mediaToken) return;
    self.speakerAnalysisToken = self.mediaToken;
    NSURL *analysisURL = self.sourceURL;
    if (self.dvdPlayer) analysisURL = [VPDiscSupport menuStructureForURL:self.sourceURL].mainTitle.playbackURL ?: self.sourceURL;
    NSUInteger token = self.mediaToken;
    void (^apply)(VPMediaProfile *) = ^(VPMediaProfile *profile) {
        if (token != self.mediaToken || !VPAudioFilters.shared.autoSpeakerLevels) return;
        VPAudioFilters *f = VPAudioFilters.shared;
        if (!profile) { f.autoSpeakerStatus = @"This file could not be analyzed."; [f setAutomaticSpeakerLevels:nil]; return; }
        if (profile.speakerRMS.count == 0) f.autoSpeakerStatus = @"Stereo or mono: there are no surround channels to balance.";
        else if (profile.speakerLevels.count == 0) f.autoSpeakerStatus = @"Analyzed: this mix is already well balanced.";
        else f.autoSpeakerStatus = @"Analyzed: levels set for this file.";
        [f setAutomaticSpeakerLevels:profile.speakerLevels];
        [f changed];
    };
    VPMediaProfile *cached = self.mediaProfile ?: [VPMediaAnalyzer cachedProfileForURL:self.sourceURL];
    if (cached) { apply(cached); return; }
    filters.autoSpeakerStatus = @"Analyzing the audio…";
    [filters changed];
    [VPMediaAnalyzer analyzeURL:analysisURL probe:self.probe completion:^(VPMediaProfile *profile) {
        if (profile && token == self.mediaToken && !self.mediaProfile) self.mediaProfile = profile;
        apply(profile);
    }];
}

- (void)probeDidFinish:(VPMediaProbe *)probe {
    self.probe = probe;
    // Convert text subtitle tracks in the background so choosing one later is instant (they are cached per track).
    if (self.sourceURL.isFileURL) {
        NSUInteger prefetched = 0;
        for (VPTrack *track in probe.subtitleTracks) {
            if (track.bitmap || prefetched++ >= 4) continue;
            [VPSubtitleTrack prefetchTrackForMedia:self.sourceURL subtitleIndex:track.index];
        }
    }
    [self analyzeSpeakerLevelsIfNeeded];
    self.videoView.hasVideo = probe.hasVideo;
    self.videoView.sourceFrameRate = probe.frameRate;
    if (probe.duration > 0 && (self.preparedMedia || self.playbackEngine.ffmpegPlayer.duration <= 0)) {
        self.videoView.knownDuration = probe.duration;
    }
    if (!self.metadataShownForMedia && ![self.configManager.playbackOptions[@"showMetadata"] isEqual:@NO]) {
        self.metadataShownForMedia = YES;
        [self.videoView showMetadataLines:[self metadataLinesForProbe:probe]];
    }
    [self analyzeCurrentMediaIfNeeded];
}

#pragma mark - Adaptive (per-file) AI

/// Applies a profile measured earlier for this exact file before playback starts, so even the deinterlacer
/// and the output layout are right from the first frame. Clears any profile left from the previous file.
- (void)adoptCachedProfileForCurrentMedia {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    // The video and audio options are deliberately left alone: they stay as set while a playlist moves on to its
    // next item, and are only reset when the user opens something new (see -resetEnhancementOptions).
    ai.adaptiveProfile = nil;
    [VPAudioFilters.shared setAutomaticSpeakerLevels:nil];   // measured for the previous file
    self.mediaProfile = nil;
    self.adaptiveDeinterlaceApplied = NO;
    if (!(ai.adaptiveVideoEnabled || ai.adaptiveAudioEnabled) || !self.sourceURL) return;
    VPMediaProfile *cached = [VPMediaAnalyzer cachedProfileForURL:self.sourceURL];
    if (!cached) return;
    self.mediaProfile = cached;
    [ai applyAdaptiveProfile:cached];
    if (ai.adaptiveVideoEnabled && cached.wantsDeinterlace && ![self.activeOptions[@"deinterlace"] boolValue]) {
        self.activeOptions[@"deinterlace"] = @YES;
        self.activeOptions[@"inverseTelecine"] = @NO;
        self.adaptiveDeinterlaceApplied = YES;
    }
}

/// Measures the current file in the background when an adaptive preset is on, then applies the result live.
- (void)analyzeCurrentMediaIfNeeded {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (!(ai.adaptiveVideoEnabled || ai.adaptiveAudioEnabled) || !self.sourceURL || !self.mediaActive) return;
    if (self.mediaProfile) { [self applyMediaProfile:self.mediaProfile]; return; }
    // A DVD is measured through its main feature; the navigation stream itself cannot be sampled.
    NSURL *analysisURL = self.sourceURL;
    if (self.dvdPlayer) analysisURL = [VPDiscSupport menuStructureForURL:self.sourceURL].mainTitle.playbackURL ?: self.sourceURL;
    NSUInteger token = self.mediaToken;
    [self updateStatusText:@"Adaptive AI is analyzing picture and sound…"];
    [VPMediaAnalyzer analyzeURL:analysisURL probe:self.probe completion:^(VPMediaProfile *profile) {
        if (token != self.mediaToken) return;
        if (!profile) { [self updateStatusText:@"Adaptive AI could not read this file"]; return; }
        self.mediaProfile = profile;
        [self applyMediaProfile:profile];
    }];
}

/// Pushes the profile into the AI stage and makes the running playback reflect it. The audio graph swaps
/// live inside the in-process player; a deinterlacer change or a native player restarts at the same spot.
- (void)applyMediaProfile:(VPMediaProfile *)profile {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    [ai applyAdaptiveProfile:profile];
    BOOL needsRestart = NO;
    // The DVD engine deinterlaces on its own and swaps its audio graph live, so it never restarts.
    if (ai.adaptiveVideoEnabled && profile.wantsDeinterlace && !self.dvdPlayer && ![self.activeOptions[@"deinterlace"] boolValue]) {
        self.activeOptions[@"deinterlace"] = @YES;
        self.activeOptions[@"inverseTelecine"] = @NO;
        self.adaptiveDeinterlaceApplied = YES;
        needsRestart = YES;
    }
    if (ai.adaptiveAudioEnabled && !self.playbackEngine.ffmpegPlayer && !self.dvdPlayer) needsRestart = YES;
    if (needsRestart && self.mediaActive) {
        [self restartAtPosition:[self.videoView currentMediaTime]];
    } else {
        if (ai.adaptiveAudioEnabled) {
            NSString *graph = [self combinedAudioFilterGraph];
            if (self.dvdPlayer) [self.dvdPlayer applyAudioFiltersGraph:graph];
            else if (self.playbackEngine.ffmpegPlayer) [self.playbackEngine.ffmpegPlayer applyAudioFiltersGraph:graph];
        }
        // The native player's composition is sized for the upscale factor, so it is rebuilt when that changes.
        if (self.playbackEngine.player && !self.playbackEngine.ffmpegPlayer) self.compositionInstalled = NO;
        [self refreshEffectsForcingRedraw:YES];
    }
    [self updateProcessingHUD];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Adaptive AI: %@", profile.summary.length ? profile.summary : @"profile applied"] symbol:@"sparkles" level:-1];
    [self updateStatusText:@""];
}

/// The probe's lines, with the queue title (for example "DVD — MY_MOVIE") standing in when the file carries no title tag.
- (NSArray<NSString *> *)metadataLinesForProbe:(VPMediaProbe *)probe {
    BOOL visualizerShown = !probe.hasVideo || self.videoView.visualizerOverVideo;
    NSMutableArray *lines = [[probe overlayLinesForURL:self.sourceURL detailed:visualizerShown] mutableCopy];
    BOOL disc = [@[@"ffconcat", @"vob", @"m2ts", @"mts", @"dat", @"evo", @"iso"] containsObject:self.sourceURL.pathExtension.lowercaseString ?: @""];
    if (disc && self.sourceTitle.length && lines.count) lines[0] = self.sourceTitle;
    return lines;
}

- (void)updateStatusText:(NSString *)detail {
    NSString *position = self.playlist.items.count > 1 ? [NSString stringWithFormat:@"[%ld/%lu] ", (long)self.playlist.currentIndex + 1, (unsigned long)self.playlist.items.count] : @"";
    self.videoView.statusText = detail.length ? [NSString stringWithFormat:@"%@%@ — %@", position, self.sourceTitle ?: @"", detail] : [position stringByAppendingString:self.sourceTitle ?: @""];
}

#pragma mark - Playback flow

/// Starts (or restarts, after a track change or distant seek) the current source.
- (void)startCurrentWithResume:(double)resume forcePrepared:(BOOL)force {
    NSURL *url = self.sourceURL;
    NSDictionary *options = self.activeOptions;
    NSString *backend = options[@"playbackBackend"] ?: @"auto";
    BOOL disc = [@[@"ffconcat", @"vob", @"m2ts", @"mts", @"dat", @"evo", @"iso"] containsObject:url.pathExtension.lowercaseString ?: @""];
    BOOL externalFilters = [VPFFmpegOptions requiresPreparation:options];
    if ([backend isEqual:@"ffplay"]) {
        NSMutableDictionary *external = [options mutableCopy]; external[@"ffmpeg"] = @YES;
        [self startURL:url options:external fallback:NO offset:0]; return;
    }
    if ([backend isEqual:@"native"] && (externalFilters || disc)) {
        [self reportPlaybackError:[NSError errorWithDomain:@"macvideoplayerErrorDomain" code:84 userInfo:@{NSLocalizedDescriptionKey:disc ? @"Discs need FFmpeg. Choose the auto or prepared backend." : @"Native playback cannot execute FFmpeg filter stages. Choose auto or prepared."}]];
        return;
    }
    // Anything that would need conversion plays in the in-process FFmpeg player instead: it decodes and filters live,
    // so seeks are instant because nothing is converted ahead of time.
    BOOL wantsPrepared = externalFilters || disc || force || self.trackOverrides.count;
    if (wantsPrepared && !self.preferAVPlayer && ![backend isEqual:@"prepared"] && [self canPlayInProcessWithOptions:options]) {
        if ([self startInProcessResumeAt:resume]) return;
    }
    if ([backend isEqual:@"prepared"] || externalFilters || disc || force || self.trackOverrides.count) { [self prepareCurrentMediaResumeAt:resume]; return; }
    [self updateStatusText:@"Checking media…"];
    NSUInteger generation = self.playbackGeneration;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.playbackGeneration) return;
            if (!asset.playable && [backend isEqual:@"auto"]) {
                if (self.preferAVPlayer || ![self canPlayInProcessWithOptions:options] || ![self startInProcessResumeAt:resume]) [self prepareCurrentMediaResumeAt:resume];
            }
            else [self startURL:url options:options fallback:[backend isEqual:@"auto"] offset:0];
        });
    }];
}

- (void)startURL:(NSURL *)url options:(NSDictionary *)options fallback:(BOOL)fallback offset:(double)offset {
    self.mayFallback = fallback;
    NSError *error = nil;
    if (![self.playbackEngine playURL:url options:options error:&error]) {
        if (fallback) { self.mayFallback = NO; [self prepareCurrentMediaResumeAt:0]; }
        else [self reportPlaybackError:error];
        return;
    }
    if (self.playbackEngine.player) {
        [self.videoView attachPlayer:self.playbackEngine.player];
        [self applyVolume];
        self.videoView.displayOffset = offset;
        if (self.probe.duration > 0 && self.preparedMedia) self.videoView.knownDuration = self.probe.duration;
        self.preparedOffset = offset;
        if (!self.preparedMedia && self.playbackEngine.player.currentItem) [self.analyzer attachToItem:self.playbackEngine.player.currentItem];
        if (self.speed != 1) [self applySpeedToPlayback];
        [self.videoView setPlaying:YES];
        self.compositionInstalled = [VPEffectPipeline optionsRequireProcessing:self.activeOptions] || VPPostProcessing.shared.isActive;
        [self refreshEffectsForcingRedraw:NO];
        [self updateStatusText:self.preparedMedia ? @"Converted with FFmpeg" : @""];
        if (self.airPlayPending) {
            self.airPlayPending = NO;
            [self.videoView showAirPlayOverlay];
            [self.videoView showOSDText:@"Choose an AirPlay device (top right)" symbol:@"airplayvideo" level:-1];
        }
    } else {
        [self.videoView setStatusText:@"Playing in FFplay — controls are in its window"];
    }
}

/// The user's audio filter chain plus the 10-band Equalizer and AI audio stage, as one libavfilter graph string.
- (NSString *)combinedAudioFilterGraph {
    return [self combinedAudioFilterGraphLeavingRateToPlayer:NO];
}

/// With `leaveRate` the in-process player converts the sample rate itself (Apple's mastering converter) when
/// Hi-Fidelity is on, so the graph must not resample first.
- (NSString *)combinedAudioFilterGraphLeavingRateToPlayer:(BOOL)leaveRate {
    NSMutableArray *audio = [NSMutableArray array];
    NSString *customAF = self.configManager.playbackOptions[@"af"];
    if ([customAF isKindOfClass:NSString.class] && customAF.length > 0) {
        [audio addObject:customAF];
    }
    if (VPAudioFilters.shared.isActive && VPAudioFilters.shared.graph.length > 0) {
        [audio addObject:VPAudioFilters.shared.graph];
    }
    NSString *aiGraph = VPAIEnhancer.shared.isAudioAIActive ? [VPAIEnhancer.shared audioFilterGraphStringForDeviceUID:self.activeOptions[@"audioDevice"]] : @"";
    if (aiGraph.length > 0) [audio addObject:aiGraph];
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    NSString *layout = self.activeOptions[@"audioLayout"] ?: @"auto";
    if ([layout isEqual:@"auto"] && ai.isAudioAIActive) layout = ai.targetLayout ?: @"auto";
    if ([layout isEqual:@"2.0"]) layout = @"stereo";
    if ([layout isEqual:@"4.0"]) layout = @"quad";
    BOOL appleSurround = ai.audioAIEnabled && ( [ai.surroundMethod isEqual:@"apple_51"] || [ai.surroundMethod isEqual:@"apple_71"]);
    if (![layout isEqual:@"auto"] && !appleSurround) {
        BOOL matrix = ai.isAudioAIActive && [ai.surroundMethod isEqual:@"matrix_ai"];
        NSInteger sourceChannels = self.probe.audioTracks.count > (NSUInteger)MAX(0, self.audioSelection)
            ? self.probe.audioTracks[MAX(0, self.audioSelection)].channels : 2;
        BOOL upmix = (!ai.isAudioAIActive || [ai.surroundMethod isEqual:@"none"]) && sourceChannels <= 2 &&
            ![layout isEqual:@"mono"] && ![layout isEqual:@"stereo"];
        if (matrix || upmix) {
            [audio addObject:@"aformat=channel_layouts=stereo"];
            [audio addObject:[VPAIEnhancer matrixPanForLayout:layout]];
        } else {
            [audio addObject:[NSString stringWithFormat:@"aformat=channel_layouts=%@", layout]];
        }
    }
    NSString *rate = [self.activeOptions[@"audioSampleRate"] description];
    if ((!rate.length || [rate isEqual:@"auto"]) && ai.audioAIEnabled) rate = ai.effectiveTargetSampleRate;
    BOOL playerConverts = leaveRate && ai.audioAIEnabled && ai.hiFiAudio;
    if (!playerConverts && rate.doubleValue >= 8000 && rate.doubleValue <= 384000) {
        [audio addObject:[NSString stringWithFormat:@"aresample=%d", rate.intValue]];
    }
    return [audio componentsJoinedByString:@","];
}

/// YES when the only reason for preparation is audio processing, which the in-process player can do live.
- (BOOL)canPlayInProcessWithOptions:(NSDictionary *)options {
    // Raw FFplay arguments were never supported, and burned-in bitmap subtitles need the converter.
    return ![options[@"ffplayArguments"] count] && !self.trackOverrides[@"burnSubtitleStream"];
}

/// Plays through VPFFmpegPlayer: demuxed, decoded and filtered in memory, frames drawn by Metal/Core Image.
- (BOOL)startInProcessResumeAt:(double)resume {
    NSMutableDictionary *opts = [self.activeOptions mutableCopy];
    [opts addEntriesFromDictionary:self.trackOverrides];
    opts[@"af"] = [self combinedAudioFilterGraphLeavingRateToPlayer:YES];
    if (self.subtitleSelection >= 0) {
        opts[@"subtitleTrack"] = @(self.subtitleSelection);
    }
    // AI audio upsampling decides the speaker layout and sample rate the output device is opened with.
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (ai.isAudioAIActive) {
        NSString *layout = [opts[@"audioLayout"] length] ? opts[@"audioLayout"] : @"auto";
        if ([layout isEqual:@"auto"]) {
            if ([ai.surroundMethod hasSuffix:@"_51"]) layout = @"5.1";
            else if ([ai.surroundMethod hasSuffix:@"_71"]) layout = @"7.1";
            else if ([ai.surroundMethod isEqual:@"matrix_ai"]) layout = [ai matrixLayoutForDeviceUID:opts[@"audioDevice"]];   // every speaker the device has
            else if (![ai.targetLayout isEqual:@"auto"]) layout = ai.targetLayout;
            opts[@"audioLayout"] = layout;
        }
        NSString *rate = [opts[@"audioSampleRate"] description];
        if ((!rate.length || [rate isEqual:@"auto"]) && ai.effectiveTargetSampleRate.doubleValue >= 8000) opts[@"audioSampleRate"] = ai.effectiveTargetSampleRate;
    }
    opts[@"playbackBackend"] = @"ffmpeg";   // make the engine use the in-process player even for natively playable files

    // Video-side stages (vf, deinterlace, telecine, lanczos upscale) become a live libavfilter graph in the player.
    NSMutableDictionary *videoOptions = [opts mutableCopy];
    videoOptions[@"effect"] = @"none"; videoOptions[@"shader"] = @""; videoOptions[@"nativeStages"] = @[];
    if (![opts[@"scaler"] isEqual:@"lanczos"]) videoOptions[@"upscale"] = @1;
    NSDictionary *graphs = [VPFFmpegOptions filterGraphsForOptions:videoOptions error:nil];
    if (!graphs) return NO;
    NSString *video = graphs[@"videoFilter"] ?: @"";
    NSString *ext = self.sourceURL.pathExtension.lowercaseString ?: @"";
    if ([@[@"ffconcat", @"vob", @"m2ts", @"mts", @"dat", @"evo", @"iso"] containsObject:ext] && ![video containsString:@"bwdif"]) {
        // Preserve both fields of interlaced motion (59.94 Hz NTSC / 50 Hz PAL).
        // Progressive frames pass through without deinterlacing.
        NSString *deint = @"bwdif=mode=send_field:deint=interlaced";
        video = video.length ? [deint stringByAppendingFormat:@",%@", video] : deint;
    }
    if (video.length) opts[@"videoFilterGraph"] = video;

    [self.preparedMedia cancel]; self.preparedMedia = nil;
    [self.playbackEngine stop]; [self.videoView detachPlayer];
    NSError *error = nil;
    if (![self.playbackEngine playURL:self.sourceURL options:opts error:&error]) return NO;
    VPFFmpegPlayer *player = self.playbackEngine.ffmpegPlayer;
    if (!player) return NO;
    // A live stream has no timeline to resume on; seeking it only stalls the connection.
    if (resume > 0 && (self.sourceURL.isFileURL || self.probe.duration > 0)) [player seekToSeconds:resume];
    if (self.speed != 1) player.rate = self.speed;
    self.videoView.displayOffset = 0;
    self.preparedOffset = 0;
    [self.videoView attachStagePlayer:player];
    [self applyVolume];
    [self.videoView setPlaying:YES];
    self.compositionInstalled = NO;
    [self refreshEffectsForcingRedraw:NO];
    [self updateStatusText:@""];
    return YES;
}

- (void)prepareCurrentMediaResumeAt:(double)resume {
    self.mayFallback = NO;
    [self.playbackEngine stop]; [self.videoView detachPlayer];
    [self.preparedMedia cancel];
    self.preparedMedia = [VPPreparedMedia new];
    [self updateStatusText:[VPFFmpegLibrary supportsStreamingConversion] ? @"Preparing with FFmpeg…" : @"Converting with FFmpeg… playback begins when conversion finishes"];
    NSUInteger generation = self.playbackGeneration;
    NSMutableDictionary *prep = [self.activeOptions mutableCopy];
    [prep addEntriesFromDictionary:self.trackOverrides];
    prep[@"startOffset"] = @(resume);
    prep[@"audioOnly"] = @(self.probe ? !self.probe.hasVideo : LooksLikeAudio(self.sourceURL));
    VPPreparedMedia *media = self.preparedMedia;
    __weak typeof(self) weakSelf = self;
    [media prepareURL:self.sourceURL options:prep completion:^(NSURL *url, NSError *error) {
        VPWindowController *self = weakSelf;
        if (!self || generation != self.playbackGeneration || media != self.preparedMedia) return;
        if (error) { [self.preparedMedia cancel]; self.preparedMedia = nil; [self reportPlaybackError:error]; return; }
        NSMutableDictionary *native = [self.activeOptions mutableCopy];
        native[@"vf"] = @""; native[@"af"] = @""; native[@"ffmpeg"] = @NO; native[@"ffplayArguments"] = @[];
        native[@"audioLayout"] = @"auto"; native[@"deinterlace"] = @NO; native[@"inverseTelecine"] = @NO;
        native[@"hls"] = @(media.streaming);
        native[@"alreadyPrepared"] = @YES;   // FFmpeg has applied every filter; the engine must not reroute to its in-process player
        if ([native[@"scaler"] isEqual:@"lanczos"]) native[@"upscale"] = @1;
        [self startURL:url options:native fallback:NO offset:resume];
    }];
}

- (void)stopPlaybackKeepingStage {
    [self removeBluRayMenuView];
    [self.dvdPlayer stop];
    self.dvdPlayer = nil;
    [self.dvdNavigationBar removeFromSuperview];
    self.dvdNavigationBar = nil;
    self.playbackGeneration++;
    [self.playbackEngine stop];
    [self.analyzer detach];
    [self.videoView detachPlayer];
    [self.preparedMedia cancel]; self.preparedMedia = nil;
    self.compositionInstalled = NO;
    self.mediaActive = NO;
}

- (void)playbackEngineDidFail:(NSError *)error {
    if (self.mayFallback) { self.mayFallback = NO; [self prepareCurrentMediaResumeAt:0]; }
    else [self reportPlaybackError:error];
}

- (void)reportPlaybackError:(NSError *)error {
    [self.videoView setStatusText:error.localizedDescription ?: @"Playback failed"];
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Unable to play media";
    alert.informativeText = error.localizedDescription ?: @"The installed decoders could not open this input.";
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Seeking

- (void)seekToAbsolute:(double)target {
    if (self.dvdPlayer) { [self.dvdPlayer seekToSeconds:target]; return; }
    if (self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
        double length = self.playbackEngine.duration;
        target = MAX(0, target);
        if (isfinite(length) && length > 0) target = MIN(target, MAX(0, length - 0.5));
        [self.playbackEngine seekToSeconds:target];
        return;
    }
    AVPlayer *player = self.playbackEngine.player;
    if (!player) return;
    target = MAX(0, target);
    double duration = self.videoView.knownDuration > 0 ? self.videoView.knownDuration : CMTimeGetSeconds(player.currentItem.duration);
    if (isfinite(duration) && duration > 0) target = MIN(target, MAX(0, duration - 0.5));
    if (!self.preparedMedia) { [self.playbackEngine seekToSeconds:target]; return; }
    double local = target - self.preparedOffset;
    NSValue *rangeValue = player.currentItem.seekableTimeRanges.lastObject;
    double seekableEnd = rangeValue ? CMTimeGetSeconds(CMTimeRangeGetEnd(rangeValue.CMTimeRangeValue)) : 0;
    if (local < 0 || (self.preparedMedia.streaming && local > seekableEnd - 1)) {
        // Outside what FFmpeg has produced so far: restart the conversion at the requested position.
        [self restartAtPosition:target];
    } else [self.playbackEngine seekToSeconds:local];
}

- (void)restartAtPosition:(double)seconds {
    if (self.dvdPlayer) {
        // dvdnav owns the disc and its position; its directory is not an FFmpeg media input.
        self.dvdPlayer.audioOutputLayout = self.activeOptions[@"audioLayout"];
        [self.dvdPlayer applyAudioFiltersGraph:[self combinedAudioFilterGraph]];
        [self refreshEffectsForcingRedraw:YES];
        return;
    }
    self.playbackGeneration++;
    [self.playbackEngine stop]; [self.analyzer detach]; [self.videoView detachPlayer];
    [self updateStatusText:@"Seeking…"];
    [self startCurrentWithResume:seconds forcePrepared:YES];
}

- (void)seekByDelta:(double)delta {
    if (!self.playbackEngine.player && !self.playbackEngine.ffmpegPlayer) return;
    double target = MAX(0, [self.videoView currentMediaTime] + delta);
    [self seekToAbsolute:target];
    [self.videoView showOSDText:[NSString stringWithFormat:@"%@%.0fs", delta > 0 ? @"+" : @"−", fabs(delta)] symbol:delta > 0 ? @"goforward" : @"gobackward" level:-1];
}
- (IBAction)seekForward:(id)sender { [self seekByDelta:5]; }
- (IBAction)seekBackward:(id)sender { [self seekByDelta:-5]; }

#pragma mark - Effects

- (void)effectsChanged:(NSNotification *)note {
    [self refreshEffectsForcingRedraw:YES];
    [self.preferenceTimer invalidate];
    self.preferenceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *timer) {
        [self savePreference:@"postProcessing" value:[VPPostProcessing.shared dictionaryRepresentation]];
    }];
}

/// Makes the picture reflect the shader, filter chain and post-processing settings right now.
- (void)refreshEffectsForcingRedraw:(BOOL)redraw {
    if ((self.playbackEngine.isFFmpegPlaying || self.dvdPlayer) && self.activeOptions) {
        VPEffectRenderer *renderer = self.videoView.effectRenderer;
        BOOL needed = [VPEffectPipeline optionsRequireProcessing:self.activeOptions] || VPPostProcessing.shared.isActive;
        NSError *error = nil;
        renderer.processor = needed ? [VPEffectPipeline processorForOptions:self.activeOptions error:&error] : nil;
        if (redraw) [renderer setNeedsRedraw];
        return;
    }
    AVPlayerItem *item = self.playbackEngine.currentItem;
    if (!item || !self.activeOptions) return;
    BOOL needed = [VPEffectPipeline optionsRequireProcessing:self.activeOptions] || VPPostProcessing.shared.isActive;
    if (self.preparedMedia.streaming) {
        // HLS cannot take a video composition, so draw processed frames ourselves.
        VPEffectRenderer *renderer = self.videoView.effectRenderer;
        if (needed) {
            NSError *error = nil;
            VPImageProcessor processor = [VPEffectPipeline processorForOptions:self.activeOptions error:&error];
            renderer.processor = processor;
            if (!renderer.running) { [renderer startWithItem:item]; self.videoView.playerLayer.hidden = YES; }
            else if (redraw) [renderer setNeedsRedraw];
        } else if (renderer.running) {
            [renderer stop]; self.videoView.playerLayer.hidden = NO;
        }
        return;
    }
    if (needed != self.compositionInstalled) {
        NSError *error = nil;
        if (![VPEffectPipeline configureItem:item options:self.activeOptions error:&error]) [self.videoView setStatusText:error.localizedDescription];
        self.compositionInstalled = needed;
        redraw = YES;
    }
    AVPlayer *player = self.playbackEngine.player;
    if (redraw && needed && player.rate == 0) {
        // A paused frame is only re-rendered when the player seeks to it.
        [player seekToTime:player.currentTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
}

#pragma mark - Transport actions

- (IBAction)togglePlayPause:(id)sender {
    if (self.dvdPlayer) {
        [self.dvdPlayer togglePlayPause];
        BOOL playing = self.dvdPlayer.isPlaying;
        [self.videoView setPlaying:playing];
        [self.videoView showOSDText:playing ? @"Play" : @"Paused" symbol:playing ? @"play.fill" : @"pause.fill" level:-1];
        return;
    }
    if (!self.mediaActive && self.playlist.items.count) { [self startPlaylistItem:self.playlist.currentItem ?: [self.playlist advanceAutomatically:NO]]; return; }
    [self.playbackEngine togglePlayPause];
    BOOL nowPlaying = self.playbackEngine.ffmpegPlayer ? self.playbackEngine.ffmpegPlayer.isPlaying : self.playbackEngine.player.rate > 0;
    [self.videoView setPlaying:nowPlaying];
    [self.videoView showOSDText:nowPlaying ? @"Play" : @"Paused" symbol:nowPlaying ? @"play.fill" : @"pause.fill" level:-1];
}

- (IBAction)stopPlayback:(id)sender {
    [self endBluRayNavigation];
    [self stopPlaybackKeepingStage];
    [self.videoView setSubtitleTrack:nil];
    [self.videoView hideMetadata];
    self.videoView.mediaLoaded = NO;
    self.videoView.hasVideo = YES;
    [self.videoView setPlaying:NO];
    [self.videoView setStatusText:@"Stopped — open media from the menu or press Tab"];
    self.window.title = @"Mac Video Player";
    self.hudOverlay.revealsOnMouseMovement = YES;
}

- (IBAction)playNext:(id)sender {
    VPPlaylistItem *item = [self.playlist advanceAutomatically:NO];
    if (item) [self startPlaylistItem:item]; else [self.videoView setStatusText:@"The playlist is empty"];
}

- (IBAction)playPrevious:(id)sender {
    // Like most players: a restart if we are past the first few seconds, otherwise the previous item.
    if ([self.videoView currentMediaTime] > 4 && (self.playbackEngine.player || self.playbackEngine.ffmpegPlayer)) { [self seekToAbsolute:0]; return; }
    VPPlaylistItem *item = [self.playlist retreat];
    if (item) [self startPlaylistItem:item];
}

- (IBAction)toggleShuffle:(id)sender {
    self.playlist.shuffle = !self.playlist.shuffle;
    [self savePreference:@"shuffle" value:@(self.playlist.shuffle)];
    [self syncToggleStates];
    self.videoView.statusText = self.playlist.shuffle ? @"Shuffle on" : @"Shuffle off";
    [self.videoView showOSDText:self.playlist.shuffle ? @"Shuffle on" : @"Shuffle off" symbol:@"shuffle" level:-1];
}

- (IBAction)cycleRepeat:(id)sender {
    self.playlist.repeatMode = (VPRepeatMode)((self.playlist.repeatMode + 1) % 3);
    [self persistRepeat];
}
- (IBAction)setRepeatMode:(NSMenuItem *)sender {
    self.playlist.repeatMode = (VPRepeatMode)sender.tag;
    [self persistRepeat];
}
- (void)persistRepeat {
    NSArray *names = @[@"off", @"all", @"one"];
    [self savePreference:@"repeat" value:names[self.playlist.repeatMode]];
    [self syncToggleStates];
    self.videoView.statusText = [NSString stringWithFormat:@"Repeat %@", names[self.playlist.repeatMode]];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Repeat %@", names[self.playlist.repeatMode]] symbol:self.playlist.repeatMode == VPRepeatOne ? @"repeat.1" : @"repeat" level:-1];
}

- (IBAction)toggleMute:(id)sender {
    self.muted = !self.muted;
    [self applyVolume];
    self.videoView.statusText = self.muted ? @"Muted" : @"Sound on";
    [self showVolumeOSD];
}

- (IBAction)setPlaybackSpeed:(NSMenuItem *)sender {
    self.speed = sender.tag / 100.0f;
    ApplySpeed(self.playbackEngine.player, self.speed);
    self.videoView.statusText = [NSString stringWithFormat:@"Speed %.2f×", self.speed];
    [self.videoView showOSDText:[NSString stringWithFormat:@"Speed %.2f×", self.speed] symbol:@"speedometer" level:-1];
}

- (void)playlistChanged:(NSNotification *)note { [self syncToggleStates]; }

#pragma mark - Opening panels

/// Where Open panels start. Never a mounted volume: a disc drive that has stalled blocks every read of /Volumes, and
/// a panel that opens there (as the system would after the last disc was browsed) hangs the whole app.
- (NSURL *)safeOpenPanelDirectory {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSNumber *directory in @[@(NSMoviesDirectory), @(NSMusicDirectory), @(NSDownloadsDirectory)]) {
        NSURL *url = [fm URLsForDirectory:(NSSearchPathDirectory)directory.integerValue inDomains:NSUserDomainMask].firstObject;
        if (url) return url;
    }
    return [NSURL fileURLWithPath:NSHomeDirectory()];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.directoryURL = [self safeOpenPanelDirectory];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.message = @"Choose one or more audio or video files. Several files become a playlist.";
    // Accept all files; the decoders, not filename extensions, decide what is playable.
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URLs.count) [self openURLs:panel.URLs shuffle:self.playlist.shuffle];
    }];
}

- (IBAction)openFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.directoryURL = [self safeOpenPanelDirectory];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.message = @"Choose folders to queue, or .m3u / .pls playlist files.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URLs.count) [self openURLs:panel.URLs shuffle:self.playlist.shuffle];
    }];
}

/// Lists the mounted discs in a sheet so one can be opened with a click, a double-click or Return. (Choosing a
/// disc in an Open panel only navigates into its folders, which looked like nothing happening.)
- (IBAction)openDisc:(id)sender {
    [self updateStatusText:@"Looking for discs…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Reading every mounted volume can stall on a slow drive, so it never runs on the main thread.
        NSArray<NSURL *> *discs = [VPDiscSupport mountedDiscs];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSURL *disc in discs) [names addObject:[VPDiscSupport titleForDisc:disc]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusText:@""];
            if (!discs.count) { [self browseForDisc]; return; }
            [self presentDiscPickerForDiscs:discs titles:names];
        });
    });
}

- (void)presentDiscPickerForDiscs:(NSArray<NSURL *> *)discs titles:(NSArray<NSString *> *)titles {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Open Disc";
    alert.informativeText = @"Choose a DVD, Blu-ray, VCD, SVCD or audio CD. Double-click a disc or select it and press Return.";
    NSButton *open = [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Browse…"];
    [alert addButtonWithTitle:@"Cancel"];

    VPDiscPicker *picker = [VPDiscPicker new];
    picker.discs = discs;
    picker.titles = titles;
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 440, 160)];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"disc"];
    column.width = 420;
    [table addTableColumn:column];
    table.headerView = nil;
    table.rowHeight = 26;
    table.dataSource = picker;
    table.delegate = picker;
    table.target = picker;
    table.doubleAction = @selector(openClicked:);
    picker.table = table;
    picker.defaultButton = open;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 440, MIN(200, MAX(80, discs.count * 26 + 4)))];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    alert.accessoryView = scroll;
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    objc_setAssociatedObject(alert, "VPDiscPicker", picker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // the sheet's controls hold it weakly

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            NSInteger row = table.selectedRow;
            if (row >= 0 && row < (NSInteger)discs.count) [self openURLs:@[discs[row]] shuffle:NO];
        } else if (response == NSAlertSecondButtonReturn) {
            [self browseForDisc];
        }
    }];
    [alert.window makeFirstResponder:table];
}

/// For a ripped disc folder (VIDEO_TS, BDMV) or an image, which are not mounted volumes.
- (void)browseForDisc {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes"];
    panel.message = @"Choose a ripped disc folder (VIDEO_TS, BDMV), a disc image (.iso) or a mounted disc, then press Open.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) [self openURLs:@[panel.URL] shuffle:NO];
    }];
}

- (IBAction)openLocation:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Open URL";
    alert.informativeText = @"Enter the address of a video, audio file or stream (http, https, rtsp, rtmp, udp, HLS…).";
    [alert addButtonWithTitle:@"Open"]; [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)];
    field.placeholderString = @"https://example.com/stream.m3u8";
    alert.accessoryView = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSURL *url = [VPURLHelper urlFromString:[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        if (url) [self openURLs:@[url] shuffle:NO];
    }];
    [alert.window makeFirstResponder:field];
}

- (IBAction)showPlaylist:(id)sender {
    if (!self.playlistController) {
        self.playlistController = [[VPPlaylistWindowController alloc] initWithPlaylist:self.playlist];
        __weak typeof(self) weakSelf = self;
        self.playlistController.playHandler = ^(NSInteger index) { [weakSelf startPlaylistItem:[weakSelf.playlist selectIndex:index]]; };
        self.playlistController.discHandler = ^{ [weakSelf openDisc:nil]; };
    }
    [self.playlistController showWindow:nil];
}

#pragma mark - VPHUDOverlayDelegate

- (void)hudOverlayDidSelectFileURL:(NSURL *)fileURL { [self openFile:fileURL]; }
- (void)hudOverlayDidSelectFolderURL:(NSURL *)folderURL { [self openURLs:@[folderURL] shuffle:self.playlist.shuffle]; }

#pragma mark - Tracks and subtitles

- (void)populateTracksMenu:(NSMenu *)menu kind:(NSInteger)kind {
    [menu removeAllItems];
    if (self.dvdPlayer) { [self populateDiscTracksMenu:menu kind:kind]; return; }
    VPMediaProbe *probe = self.probe;
    if (kind == VPTrackKindSubtitle) {
        NSMenuItem *off = [menu addItemWithTitle:@"Off" action:@selector(selectSubtitleTrack:) keyEquivalent:@""];
        off.tag = -1;
        off.target = self;
        off.state = self.subtitleSelection == -1 ? NSControlStateValueOn : NSControlStateValueOff;
        for (VPTrack *track in probe.subtitleTracks) {
            NSMenuItem *item = [menu addItemWithTitle:[track displayName] action:@selector(selectSubtitleTrack:) keyEquivalent:@""];
            item.tag = track.index;
            item.target = self;
            item.state = self.subtitleSelection == track.index ? NSControlStateValueOn : NSControlStateValueOff;
            if (track.bitmap) item.toolTip = @"Picture-based subtitles are drawn onto the video by FFmpeg, which restarts playback at the current position.";
        }
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *loadItem = [menu addItemWithTitle:@"Load Subtitle File…" action:@selector(loadSubtitleFile:) keyEquivalent:@""];
        loadItem.target = self;
        return;
    }
    NSArray<VPTrack *> *tracks = kind == VPTrackKindAudio ? probe.audioTracks : probe.videoTracks;
    NSInteger selected = kind == VPTrackKindAudio ? self.audioSelection : self.videoSelection;
    if (!tracks.count) {
        NSString *message = !self.mediaActive ? @"Open media to see its tracks" : (probe ? @"No tracks" : @"Track details are still loading");
        NSMenuItem *none = [menu addItemWithTitle:message action:nil keyEquivalent:@""];
        none.enabled = NO;
        return;
    }
    for (VPTrack *track in tracks) {
        NSMenuItem *item = [menu addItemWithTitle:[track displayName] action:kind == VPTrackKindAudio ? @selector(selectAudioTrack:) : @selector(selectVideoTrack:) keyEquivalent:@""];
        item.tag = track.index;
        item.target = self;
        item.state = selected == track.index ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

/// Disc audio and subtitle streams come straight from the disc engine, so no media probe is involved.
- (void)populateDiscTracksMenu:(NSMenu *)menu kind:(NSInteger)kind {
    VPDVDPlayer *dvd = self.dvdPlayer;
    if (kind == VPTrackKindVideo) {
        NSMenuItem *only = [menu addItemWithTitle:@"The disc has one video stream" action:nil keyEquivalent:@""];
        only.enabled = NO;
        return;
    }
    BOOL subtitles = kind == VPTrackKindSubtitle;
    NSArray<NSDictionary *> *tracks = subtitles ? [dvd subtitleTracks] : [dvd audioTracks];
    NSInteger selected = subtitles ? [dvd selectedSubtitleTrackID] : [dvd selectedAudioTrackID];
    if (!tracks.count) {
        NSMenuItem *none = [menu addItemWithTitle:@"No tracks yet" action:nil keyEquivalent:@""];
        none.enabled = NO;
        return;
    }
    for (NSDictionary *track in tracks) {
        NSMenuItem *item = [menu addItemWithTitle:track[@"name"] action:subtitles ? @selector(selectDiscSubtitle:) : @selector(selectDiscAudio:) keyEquivalent:@""];
        item.tag = [track[@"id"] integerValue];
        item.target = self;
        item.state = item.tag == selected ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (IBAction)selectDiscAudio:(NSMenuItem *)sender {
    if ([self.dvdPlayer selectAudioTrackID:sender.tag]) [self updateStatusText:[NSString stringWithFormat:@"Audio: %@", sender.title]];
}

- (IBAction)selectDiscSubtitle:(NSMenuItem *)sender {
    if ([self.dvdPlayer selectSubtitleTrackID:sender.tag]) [self updateStatusText:sender.tag < 0 ? @"Subtitles Off" : [NSString stringWithFormat:@"Subtitles: %@", sender.title]];
}

- (IBAction)showTracksMenu:(id)sender {
    NSMenu *menu = self.videoView.contextMenu;
    [self menuNeedsUpdate:menu];
    if ([sender isKindOfClass:NSView.class]) [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, ((NSView *)sender).bounds.size.height + 4) inView:sender];
    else [menu popUpMenuPositioningItem:nil atLocation:NSEvent.mouseLocation inView:nil];
}

- (IBAction)selectAudioTrack:(NSMenuItem *)sender {
    NSInteger index = sender.tag;
    self.audioSelection = index;
    self.trackOverrides[@"audioStream"] = @(index);
    
    // Seamless dynamic track switch in FFmpeg player if currently playing with FFmpeg
    if (self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
        if ([self.playbackEngine selectAudioTrack:index]) {
            [self updateStatusText:[NSString stringWithFormat:@"Audio Track %ld", (long)(index + 1)]];
            return;
        }
    }
    
    AVPlayerItem *item = self.playbackEngine.currentItem;
    if (self.preparedMedia || !item || self.probe.audioTracks.count < 2) {
        [self restartAtPosition:[self.videoView currentMediaTime]];
        return;
    }
    // Native playback: switch inside the item without interrupting it.
    [item.asset loadMediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible completionHandler:^(AVMediaSelectionGroup *group, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (group && (NSInteger)group.options.count > index) {
                [item selectMediaOption:group.options[index] inMediaSelectionGroup:group];
                [self updateStatusText:[NSString stringWithFormat:@"Audio Track %ld", (long)(index + 1)]];
            } else {
                self.trackOverrides[@"playbackBackend"] = @"ffmpeg";
                [self restartAtPosition:[self.videoView currentMediaTime]];
            }
        });
    }];
}

- (IBAction)selectVideoTrack:(NSMenuItem *)sender {
    self.videoSelection = sender.tag;
    self.trackOverrides[@"videoStream"] = @(sender.tag);
    [self restartAtPosition:[self.videoView currentMediaTime]];
}

- (IBAction)selectSubtitleTrack:(NSMenuItem *)sender {
    NSInteger index = sender.tag;
    BOOL hadBurn = self.trackOverrides[@"burnSubtitleStream"] != nil;
    self.subtitleSelection = index;
    [self.trackOverrides removeObjectForKey:@"burnSubtitleStream"];
    [self.videoView setSubtitleTrack:nil];
    [self.videoView setLiveSubtitleImage:nil text:nil];
    if (index < 0) {
        if (self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
            [self.playbackEngine selectSubtitleTrack:-1];
        } else if (hadBurn) {
            [self restartAtPosition:[self.videoView currentMediaTime]];
        }
        [self updateStatusText:@"Subtitles Off"];
        return;
    }
    VPTrack *track = nil;
    for (VPTrack *candidate in self.probe.subtitleTracks) {
        if (candidate.index == index) {
            track = candidate;
            break;
        }
    }
    // Text tracks come from the pre-extracted cue list (instant, and complete from the start of the file);
    // only picture-based tracks need the live decoder.
    BOOL liveDecode = track.bitmap || !self.sourceURL.isFileURL;
    if (!liveDecode && self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
        [self.playbackEngine selectSubtitleTrack:-1];
    }
    if (liveDecode && self.playbackEngine.isFFmpegPlaying && self.playbackEngine.ffmpegPlayer) {
        if ([self.playbackEngine selectSubtitleTrack:index]) {
            [self updateStatusText:[NSString stringWithFormat:@"Subtitles: %@", track.displayName ?: [NSString stringWithFormat:@"Track %ld", (long)(index + 1)]]];
            return;
        }
    }
    if (track.bitmap) {
        if (!self.preferAVPlayer && [self startInProcessResumeAt:[self.videoView currentMediaTime]]) {
            [self updateStatusText:[NSString stringWithFormat:@"Subtitles: %@", track.displayName ?: [NSString stringWithFormat:@"Track %ld", (long)(index + 1)]]];
            return;
        }
        self.trackOverrides[@"burnSubtitleStream"] = @(index);
        [self prepareCurrentMediaResumeAt:[self.videoView currentMediaTime]];
        return;
    }
    if (hadBurn) [self restartAtPosition:[self.videoView currentMediaTime]];
    self.videoView.statusText = @"Loading subtitles…";
    NSUInteger token = self.mediaToken;
    [VPSubtitleTrack extractFromMedia:self.sourceURL subtitleIndex:index completion:^(VPSubtitleTrack *subtitles, NSError *error) {
        if (token != self.mediaToken || self.subtitleSelection != index) return;
        if (!subtitles) {
            self.subtitleSelection = -1;
            self.videoView.statusText = error.localizedDescription ?: @"These subtitles could not be converted to text.";
            return;
        }
        [self.videoView setSubtitleTrack:subtitles];
        [self updateStatusText:[NSString stringWithFormat:@"Subtitles: %@", track.displayName ?: @"On"]];
    }];
}

- (IBAction)loadSubtitleFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = @"Choose a subtitle file (.srt, .vtt, .ass, .ssa).";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        VPSubtitleTrack *track = [VPSubtitleTrack trackWithContentsOfURL:panel.URL error:&error];
        if (!track) { [self reportPlaybackError:error]; return; }
        [self.trackOverrides removeObjectForKey:@"burnSubtitleStream"];
        self.subtitleSelection = -2;      // external file: no embedded track is checked
        [self.videoView setSubtitleTrack:track];
        self.videoView.statusText = [NSString stringWithFormat:@"Subtitles: %@", panel.URL.lastPathComponent];
    }];
}

/// Picks up "Movie.srt" next to "Movie.mkv" automatically.
- (void)loadSubtitleSidecarForCurrentMedia {
    if (!self.sourceURL.isFileURL) return;
    NSURL *base = [self.sourceURL URLByDeletingPathExtension];
    for (NSString *ext in @[@"srt", @"vtt", @"ass", @"ssa"]) {
        NSURL *candidate = [base URLByAppendingPathExtension:ext];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate.path]) continue;
        VPSubtitleTrack *track = [VPSubtitleTrack trackWithContentsOfURL:candidate error:nil];
        if (track) { self.subtitleSelection = -2; [self.videoView setSubtitleTrack:track]; return; }
    }
}

#pragma mark - Display actions

- (IBAction)toggleHUD:(id)sender { [self.hudOverlay toggle]; }

- (IBAction)toggleVisualizer:(id)sender {
    self.videoView.visualizerOverVideo = !self.videoView.visualizerOverVideo;
    [self savePreference:@"visualizer" value:@(self.videoView.visualizerOverVideo)];
    [self syncToggleStates];
    // A streamed AVPlayer item cannot be tapped for the visualizer; move it to the in-process player.
    if (self.videoView.visualizerOverVideo && self.mediaActive && self.playbackEngine.player && !self.playbackEngine.ffmpegPlayer &&
        !self.dvdPlayer && !self.sourceURL.isFileURL) {
        double position = [self.videoView currentMediaTime];
        if (![self startInProcessResumeAt:position]) [self restartAtPosition:position];
    }
    if (self.probe) [self.videoView showMetadataLines:[self metadataLinesForProbe:self.probe]];
    self.videoView.statusText = self.videoView.visualizerOverVideo ? @"Visualizer on (always shown for audio-only media)" : @"Visualizer over video off";
}

- (IBAction)cycleVisualizerStyle:(id)sender {
    VPVisualizerStyle next = (VPVisualizerStyle)((self.videoView.visualizerStyle + 1) % VPVisualizerStyleCount);
    self.videoView.visualizerStyle = next;
    [self savePreference:@"visualizerStyle" value:VPVisualizerStyleNames()[next]];
    self.videoView.statusText = [NSString stringWithFormat:@"Visualizer style: %@", VPVisualizerStyleNames()[next]];
}

- (IBAction)toggleFPS:(id)sender {
    self.videoView.fpsVisible = !self.videoView.fpsVisible;
    [self savePreference:@"showFPS" value:@(self.videoView.fpsVisible)];
    [self syncToggleStates];
}

- (IBAction)showMediaInfo:(id)sender {
    if (!self.probe) { self.videoView.statusText = self.mediaActive ? @"Media details are still loading" : @"Open media first"; return; }
    [self.videoView showMetadataLines:[self metadataLinesForProbe:self.probe]];
}

- (IBAction)showAirPlay:(id)sender {
    [self.hudOverlay hideAnimated:YES];
    if (!self.mediaActive) { self.videoView.statusText = @"Start playing something, then choose an AirPlay device"; return; }
    if (!self.playbackEngine.player) {
        // The in-process player has no AVPlayer to hand to AirPlay; continue this item through the AVPlayer path instead.
        self.preferAVPlayer = YES;
        self.airPlayPending = YES;
        [self.videoView showOSDText:@"Preparing for AirPlay…" symbol:@"airplayvideo" level:-1];
        [self restartAtPosition:[self.videoView currentMediaTime]];
        return;
    }
    [self.videoView showAirPlayOverlay];
    [self.videoView showOSDText:@"Choose an AirPlay device (top right)" symbol:@"airplayvideo" level:-1];
}

- (IBAction)showPostProcessing:(id)sender {
    if (!self.postController) {
        self.postController = [VPPostProcessingWindowController new];
        __weak typeof(self) weakSelf = self;
        self.postController.openShaderEditor = ^{ [weakSelf showShaderEditor:nil]; };
    }
    [self.postController refresh];
    [self.postController showWindow:nil];
}

- (IBAction)showShaderEditor:(id)sender {
    if (!self.shaderController) {
        self.shaderController = [VPShaderEditorWindowController new];
        __weak typeof(self) weakSelf = self;
        self.shaderController.itemProvider = ^AVPlayerItem *{ return weakSelf.playbackEngine.currentItem; };
    }
    [self.shaderController showWindow:nil];
}

- (IBAction)showHelp:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"macvideoplayer shortcuts";
    alert.informativeText = @"Space  play / pause\nTab  show or hide the menu panel\n← →  previous / next frame     ⇧← ⇧→  seek 5 seconds     ↑ ↓  volume\nN / P  next / previous     S  shuffle     R  repeat\nF  full screen     M  mute     I  media info\nV  visualizer over video     D  FPS display\n[ and ]  slower / faster\n\n⌘O open file    ⌘U open URL    ⌘L playlist\n⌘B configuration builder    ⌘,  settings\n\nDrop files, folders, playlists or disc folders onto the window. Right-click for quick options.\nCommand line: macvideoplayer play a.mkv b.mp3 --shuffle   ·   macvideoplayer help";
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    BOOL playing = self.dvdPlayer ? self.dvdPlayer.isPlaying : self.playbackEngine.ffmpegPlayer ? self.playbackEngine.ffmpegPlayer.isPlaying : self.playbackEngine.player.rate > 0;
    if (action == @selector(togglePlayPause:)) { item.title = playing ? @"Pause" : @"Play"; return self.mediaActive || self.playlist.items.count > 0; }
    if (action == @selector(stopPlayback:) || action == @selector(seekForward:) || action == @selector(seekBackward:) || action == @selector(toggleMute:) || action == @selector(setPlaybackSpeed:)) {
        if (action == @selector(setPlaybackSpeed:)) item.state = fabsf(item.tag / 100.0f - self.speed) < 0.01f ? NSControlStateValueOn : NSControlStateValueOff;
        if (action == @selector(toggleMute:)) item.state = self.muted ? NSControlStateValueOn : NSControlStateValueOff;
        return self.mediaActive;
    }
    if (action == @selector(toggleKeepEnhancementOptions:)) { item.state = [self keepsEnhancementOptions] ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(playNext:) || action == @selector(playPrevious:)) return self.playlist.items.count > 0;
    if (action == @selector(toggleShuffle:)) { item.state = self.playlist.shuffle ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(setRepeatMode:)) { item.state = item.tag == self.playlist.repeatMode ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(toggleVisualizer:)) { item.state = self.videoView.visualizerOverVideo ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(toggleFPS:)) { item.state = self.videoView.fpsVisible ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(toggleHUD:)) { item.state = self.hudOverlay.isVisible ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (action == @selector(showAirPlay:) || action == @selector(showMediaInfo:) || action == @selector(loadSubtitleFile:)) return self.mediaActive;
    return YES;
}

#pragma mark - Context menu

- (NSMenu *)buildContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"macvideoplayer"];
    menu.autoenablesItems = YES;
    menu.delegate = self;   // rebuilt each time it opens so checkmarks match the current state
    return menu;
}

- (NSMenuItem *)addTo:(NSMenu *)menu title:(NSString *)title action:(SEL)action object:(id)object checked:(BOOL)checked {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self; item.representedObject = object;
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (NSMenu *)submenuNamed:(NSString *)title in:(NSMenu *)menu {
    NSMenuItem *parent = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
    sub.autoenablesItems = YES;
    parent.submenu = sub;
    return sub;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.videoView.contextMenu) return;
    [menu removeAllItems];
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    for (NSArray *row in @[@[@"Play", @"togglePlayPause:"], @[@"Next", @"playNext:"], @[@"Previous", @"playPrevious:"], @[@"Mute", @"toggleMute:"]]) {
        [self addTo:menu title:row[0] action:NSSelectorFromString(row[1]) object:nil checked:NO];
    }
    NSMenu *speed = [self submenuNamed:@"Speed" in:menu];
    for (NSNumber *percent in @[@25, @50, @75, @100, @125, @150, @200, @300, @400]) {
        NSMenuItem *item = [self addTo:speed title:[NSString stringWithFormat:@"%.2g×", percent.doubleValue / 100] action:@selector(setPlaybackSpeed:) object:nil checked:fabsf(percent.floatValue / 100 - self.speed) < 0.01f];
        item.tag = percent.integerValue;
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenu *tracks = [self submenuNamed:@"Tracks & Subtitles" in:menu];
    [self populateTracksMenu:[self submenuNamed:@"Audio Track" in:tracks] kind:VPTrackKindAudio];
    [self populateTracksMenu:[self submenuNamed:@"Video Track" in:tracks] kind:VPTrackKindVideo];
    [self populateTracksMenu:[self submenuNamed:@"Subtitles" in:tracks] kind:VPTrackKindSubtitle];
    if (self.dvdPlayer || self.bluRayNavigator) [self addTo:menu title:@"Disc Main Menu" action:@selector(showDiscMenu:) object:nil checked:NO];
    [self addTo:menu title:@"Playlist…" action:@selector(showPlaylist:) object:nil checked:NO];
    [self addTo:menu title:@"AirPlay…" action:@selector(showAirPlay:) object:nil checked:self.playbackEngine.player.externalPlaybackActive];
    [self addTo:menu title:@"Show Menu Panel" action:@selector(toggleHUD:) object:nil checked:NO];
    [self addTo:menu title:@"Keep Audio & Video Options Between Files" action:@selector(toggleKeepEnhancementOptions:) object:nil checked:[self keepsEnhancementOptions]];
    [menu addItem:NSMenuItem.separatorItem];

    // Video
    NSMenu *video = [self submenuNamed:@"Video" in:menu];
    NSMenu *aspect = [self submenuNamed:@"Aspect Ratio" in:video];
    NSArray *aspects = @[@"Auto", @"16:9", @"16:10", @"4:3", @"21:9", @"1:1", @"Stretch", @"Crop to Fill"];
    for (NSUInteger i = 0; i < aspects.count; i++) {
        NSMenuItem *item = [self addTo:aspect title:aspects[i] action:@selector(selectAspectRatio:) object:nil checked:(NSUInteger)self.videoView.aspectRatio == i];
        item.tag = (NSInteger)i;
    }
    NSMenu *quality = [self submenuNamed:@"Quality Presets" in:video];
    for (NSString *name in [VPEffectPipeline videoQualityPresetNames]) {
        [self addTo:quality title:name action:@selector(selectVideoQualityPreset:) object:name checked:NO];
    }
    [self addTo:video title:@"Deinterlace" action:@selector(toggleDeinterlace:) object:nil checked:[self.activeOptions[@"deinterlace"] boolValue]];
    [self addTo:video title:@"Inverse Telecine" action:@selector(toggleInverseTelecine:) object:nil checked:[self.activeOptions[@"inverseTelecine"] boolValue]];
    [video addItem:NSMenuItem.separatorItem];
    [self addTo:video title:@"Post-Processing…" action:@selector(showPostProcessing:) object:nil checked:NO];
    [self addTo:video title:@"Shader Editor…" action:@selector(showShaderEditor:) object:nil checked:NO];

    // AI video
    NSMenu *aiVideo = [self submenuNamed:@"AI Video Enhancement" in:menu];
    NSString *activeVideo = ai.isVideoAIActive ? ai.activeVideoPreset : @"none";
    [self addTo:aiVideo title:@"Off" action:@selector(selectAIVideoPreset:) object:@"none" checked:!ai.isVideoAIActive];
    [aiVideo addItem:NSMenuItem.separatorItem];
    NSArray *videoPresets = @[@[@"Adaptive AI (Analyze This File)", @"adaptive"], @[@"Vivid & Crisp", @"vivid_crisp"], @[@"Cinema HDR", @"cinema_hdr"], @[@"Anime Pop", @"anime_pop"], @[@"Super Resolution 2×", @"super_resolution_2x"], @[@"Clean Restore (Denoise)", @"clean_restore"]];
    for (NSArray *preset in videoPresets) [self addTo:aiVideo title:preset[0] action:@selector(selectAIVideoPreset:) object:preset[1] checked:[activeVideo isEqual:preset[1]]];
    [aiVideo addItem:NSMenuItem.separatorItem];
    NSMenu *upscale = [self submenuNamed:@"AI Upscaling" in:aiVideo];
    for (NSNumber *factor in @[@1, @1.5, @2, @3, @4]) {
        NSMenuItem *item = [self addTo:upscale title:factor.doubleValue <= 1 ? @"Off" : [NSString stringWithFormat:@"%.2g×", factor.doubleValue] action:@selector(selectAIUpscale:) object:factor checked:ai.isVideoAIActive ? fabs(ai.upscaleFactor - factor.doubleValue) < 0.01 : factor.doubleValue <= 1];
        (void)item;
    }
    NSArray *videoToggles = @[@[@"Clarity", @"clarityBoost", @0.6], @[@"Sharpen", @"luminanceSharpness", @0.6], @[@"Denoise", @"adaptiveDenoise", @0.5], @[@"Micro Contrast", @"microContrast", @0.5], @[@"Vivid Color", @"vividVibrance", @0.7]];
    for (NSArray *t in videoToggles) [self addTo:aiVideo title:t[0] action:@selector(toggleAIVideoLevel:) object:t checked:ai.videoAIEnabled && [[ai valueForKey:t[1]] doubleValue] > 0.01];
    [self addTo:aiVideo title:@"HDR Tone Mapping" action:@selector(toggleAIVideoFlag:) object:@"hdrDynamicTone" checked:ai.videoAIEnabled && ai.hdrDynamicTone];
    [self addTo:aiVideo title:@"Cinema Color Grade" action:@selector(toggleAIVideoFlag:) object:@"cinemaColorGrade" checked:ai.videoAIEnabled && ai.cinemaColorGrade];
    [self addTo:aiVideo title:@"Subject Focus (Vision)" action:@selector(toggleAIVideoFlag:) object:@"visionSaliencyFocus" checked:ai.videoAIEnabled && ai.visionSaliencyFocus];

    [self addTo:menu title:@"Speaker Levels…" action:@selector(showSpeakerLevels:) object:nil checked:NO];

    NSMenu *equalizer = [self submenuNamed:@"Equalizer" in:menu];
    VPAudioFilters *audioFilters = VPAudioFilters.shared;
    [self addTo:equalizer title:@"Enabled" action:@selector(toggleContextEqualizer:) object:nil checked:audioFilters.enabled && audioFilters.equalizerEnabled];
    [self addTo:equalizer title:@"Edit 10 Bands…" action:@selector(showEqualizer:) object:nil checked:NO];
    [equalizer addItem:NSMenuItem.separatorItem];
    for (NSString *preset in VPAudioFilters.equalizerPresets) {
        if ([preset isEqual:@"Custom"]) continue;
        [self addTo:equalizer title:preset action:@selector(selectContextEqualizerPreset:) object:preset checked:[audioFilters.equalizerPreset isEqual:preset]];
    }

    // AI audio
    NSMenu *aiAudio = [self submenuNamed:@"AI Audio" in:menu];
    NSString *activeAudio = ai.isAudioAIActive ? ai.activeAudioPreset : @"none";
    [self addTo:aiAudio title:@"Off" action:@selector(selectAIAudioPreset:) object:@"none" checked:!ai.isAudioAIActive];
    [aiAudio addItem:NSMenuItem.separatorItem];
    NSArray *audioPresets = @[@[@"Cinema Clarity + Surround (DSP)", @"cinema_restore"], @[@"Adaptive AI (Analyze This File)", @"adaptive"], @[@"Directional Matrix", @"matrix_ai"], @[@"Clear Dialogue", @"clear_dialogue"], @[@"Spatial 3D", @"spatial_3d"], @[@"Surround 5.1 Upmix", @"surround_51"], @[@"Surround 7.1 Upmix", @"surround_71"], @[@"Studio Master", @"studio_master"], @[@"Night Mode", @"night_mode"], @[@"Loudness Normalize", @"loudnorm"], @[@"Bass Punch", @"bass_punch"]];
    for (NSArray *preset in audioPresets) [self addTo:aiAudio title:preset[0] action:@selector(selectAIAudioPreset:) object:preset[1] checked:[activeAudio isEqual:preset[1]]];
    [aiAudio addItem:NSMenuItem.separatorItem];
    NSMenu *surround = [self submenuNamed:@"Upsample to Surround" in:aiAudio];
    NSArray *methods = @[@[@"Off", @"none"], @[@"Directional Matrix", @"matrix_ai"], @[@"Spatial Stereo (Apple-style)", @"apple_spatial"], @[@"5.1 (Apple Accelerate)", @"apple_51"], @[@"7.1 (Apple Accelerate)", @"apple_71"], @[@"5.1 (FFmpeg)", @"ffmpeg_51"], @[@"7.1 (FFmpeg)", @"ffmpeg_71"], @[@"Wide Stereo", @"stereo_wide"], @[@"Virtual Subwoofer 2.1", @"subwoofer_21"]];
    for (NSArray *m in methods) [self addTo:surround title:m[0] action:@selector(selectAISurroundMethod:) object:m[1] checked:[ai.surroundMethod isEqual:m[1]]];
    NSMenu *rate = [self submenuNamed:@"Upsample Sample Rate" in:aiAudio];
    for (NSString *r in @[@"auto", @"48000", @"96000", @"192000", @"384000"]) {
        [self addTo:rate title:[r isEqual:@"auto"] ? @"Source Rate" : [NSString stringWithFormat:@"%g kHz", r.doubleValue / 1000] action:@selector(selectAISampleRate:) object:r checked:[ai.targetSampleRate isEqual:r]];
    }
    NSArray *audioToggles = @[@[@"Surround Fill (Apple Upmixer)", @"surroundFill"], @[@"Gentle Noise Reduction + Clarity", @"audioClarity"], @[@"Bass Extension (DSP)", @"bassExtension"], @[@"Dialogue Boost", @"dialogueBoost"], @[@"Harmonic Crystalizer", @"harmonicCrystalizer"], @[@"Bass Impact", @"bassImpact"], @[@"Treble Sparkle", @"trebleSparkle"], @[@"Night Mode Compression", @"nightMode"], @[@"Loudness Normalization", @"loudnessNormalize"]];
    NSMutableArray *audioTogglesWithHiFi = [NSMutableArray arrayWithObject:@[@"Hi-Fidelity (96 kHz, Apple SRC)", @"hiFiAudio"]];
    [audioTogglesWithHiFi addObjectsFromArray:audioToggles];
    audioToggles = audioTogglesWithHiFi;
    [aiAudio addItem:NSMenuItem.separatorItem];
    for (NSArray *t in audioToggles) [self addTo:aiAudio title:t[0] action:@selector(toggleAIAudioFlag:) object:t[1] checked:ai.audioAIEnabled && [[ai valueForKey:t[1]] boolValue]];
    [aiAudio addItem:NSMenuItem.separatorItem];
    [self addTo:aiAudio title:@"Audio Filters…" action:@selector(showAudioFilters:) object:nil checked:NO];
    [self addTo:aiAudio title:@"Audio Output…" action:@selector(showAudioOutput:) object:nil checked:NO];
    NSMenu *encoded = [self submenuNamed:@"Export Enhanced Audio" in:aiAudio];
    [self addTo:encoded title:@"AC-3 5.1 File…" action:@selector(exportEnhancedAudio:) object:@"ac3" checked:NO];
    [self addTo:encoded title:@"DTS 5.1 File…" action:@selector(exportEnhancedAudio:) object:@"dts" checked:NO];
    [self addTo:encoded title:@"Cancel Export" action:@selector(stopFFmpeg:) object:nil checked:NO];

    [menu addItem:NSMenuItem.separatorItem];
    [self addTo:menu title:@"Shuffle" action:@selector(toggleShuffle:) object:nil checked:self.playlist.shuffle];
    [self addTo:menu title:@"Visualizer" action:@selector(toggleVisualizer:) object:nil checked:self.videoView.visualizerOverVideo];
    [self addTo:menu title:@"FPS Display" action:@selector(toggleFPS:) object:nil checked:self.videoView.fpsVisible];
    [self addTo:menu title:@"Take Snapshot" action:@selector(takeSnapshot:) object:nil checked:NO];
    [self addTo:menu title:@"Media Info" action:@selector(showMediaInfo:) object:nil checked:NO];
}

#pragma mark - AI actions

/// Redraws the picture after an AI video setting changed.
- (void)aiVideoDidChangeWithMessage:(NSString *)message {
    [VPAIEnhancer.shared changed];
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView showOSDText:message symbol:@"sparkles" level:-1];
}

/// Audio changes alter the filter graph and often the output layout, so playback restarts at the same spot (instant in the in-process player).
- (void)aiAudioDidChangeWithMessage:(NSString *)message {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (ai.audioAIEnabled && ([ai.surroundMethod hasSuffix:@"_51"] || [ai.surroundMethod hasSuffix:@"_71"])) {
        // Selecting a surround format must not leave an old stereo output override in place.
        self.activeOptions[@"audioLayout"] = [ai.surroundMethod hasSuffix:@"_71"] ? @"7.1" : @"5.1";
    }
    [VPAIEnhancer.shared changed];
    [self.videoView showOSDText:message symbol:@"waveform.badge.magnifyingglass" level:-1];
    if (!self.mediaActive) return;
    BOOL surround = ai.audioAIEnabled && ([ai.surroundMethod hasSuffix:@"_51"] || [ai.surroundMethod hasSuffix:@"_71"] || [ai.surroundMethod isEqual:@"matrix_ai"]);
    if ((self.playbackEngine.ffmpegPlayer || self.dvdPlayer) && !surround) {
        // The in-process player swaps its audio graph live and re-renders the audio it has buffered with the new
        // filters, so the change is heard at once and nothing reconnects or re-buffers.
        [self applyAudioFiltersNow];
        return;
    }
    // Streams cannot resume at an old position, and restarting through the in-process player avoids a slow HLS conversion.
    double position = [self.videoView currentMediaTime];
    if (self.dvdPlayer || self.bluRayNavigator) { [self restartAtPosition:position]; return; }
    if (![self startInProcessResumeAt:position]) [self restartAtPosition:position];
}

- (IBAction)selectAIVideoPreset:(NSMenuItem *)sender {
    NSString *name = sender.representedObject;
    if ([name isEqual:@"none"]) {
        // Off means every AI video option is off: preset, upscale, each adjustment, adaptive mode,
        // and anything adaptive mode switched on outside the enhancer.
        VPAIEnhancer.shared.videoAIEnabled = NO;
        [VPAIEnhancer.shared resetVideoAI];
        if (self.adaptiveDeinterlaceApplied) {
            self.adaptiveDeinterlaceApplied = NO;
            self.activeOptions[@"deinterlace"] = @NO;
            [self aiVideoDidChangeWithMessage:@"AI Video: Off"];
            if (self.mediaActive) [self restartAtPosition:[self.videoView currentMediaTime]];
            return;
        }
    }
    else [VPAIEnhancer.shared applyVideoPreset:name];
    [self aiVideoDidChangeWithMessage:[name isEqual:@"none"] ? @"AI Video: Off" : [NSString stringWithFormat:@"AI Video: %@", sender.title]];
    if ([name isEqual:@"adaptive"]) [self analyzeCurrentMediaIfNeeded];
}

- (IBAction)selectAIUpscale:(NSMenuItem *)sender {
    double factor = [sender.representedObject doubleValue];
    VPAIEnhancer.shared.upscaleFactor = factor;
    if (factor > 1) VPAIEnhancer.shared.videoAIEnabled = YES;
    [self aiVideoDidChangeWithMessage:factor > 1 ? [NSString stringWithFormat:@"AI Upscale %.2g×", factor] : @"AI Upscale: Off"];
}

- (IBAction)toggleAIVideoLevel:(NSMenuItem *)sender {
    NSArray *spec = sender.representedObject;
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    BOOL on = ai.videoAIEnabled && [[ai valueForKey:spec[1]] doubleValue] > 0.01;
    [ai setValue:on ? @0 : spec[2] forKey:spec[1]];
    if (!on) ai.videoAIEnabled = YES;
    [self aiVideoDidChangeWithMessage:[NSString stringWithFormat:@"AI %@: %@", spec[0], on ? @"Off" : @"On"]];
}

- (IBAction)toggleAIVideoFlag:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    BOOL on = ai.videoAIEnabled && [[ai valueForKey:sender.representedObject] boolValue];
    [ai setValue:@(!on) forKey:sender.representedObject];
    if (!on) ai.videoAIEnabled = YES;
    [self aiVideoDidChangeWithMessage:[NSString stringWithFormat:@"%@: %@", sender.title, on ? @"Off" : @"On"]];
}

- (IBAction)selectAIAudioPreset:(NSMenuItem *)sender {
    NSString *name = sender.representedObject;
    if ([name isEqual:@"none"]) { VPAIEnhancer.shared.audioAIEnabled = NO; [VPAIEnhancer.shared resetAudioAI]; }
    else [VPAIEnhancer.shared applyAudioPreset:name];
    if ([name isEqual:@"cinema_restore"]) {
        NSUInteger channels = [VPAudioDeviceManager outputChannelCountForDeviceUID:self.activeOptions[@"audioDevice"]];
        if (channels >= 6 && channels < 8) {
            VPAIEnhancer.shared.surroundMethod = @"apple_51";
            VPAIEnhancer.shared.targetLayout = @"5.1";
        }
    }
    if ([name isEqual:@"adaptive"] && self.mediaProfile) {
        // Already measured: applying the profile restarts or re-filters as needed on its own.
        [self analyzeCurrentMediaIfNeeded];
        return;
    }
    [self aiAudioDidChangeWithMessage:[name isEqual:@"none"] ? @"AI Audio: Off" : [NSString stringWithFormat:@"AI Audio: %@", sender.title]];
    if ([name isEqual:@"adaptive"]) [self analyzeCurrentMediaIfNeeded];
}

- (IBAction)selectAISurroundMethod:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    ai.surroundMethod = sender.representedObject;
    ai.targetLayout = [ai.surroundMethod hasSuffix:@"_51"] ? @"5.1" :
        [ai.surroundMethod hasSuffix:@"_71"] ? @"7.1" :
        [ai.surroundMethod isEqual:@"subwoofer_21"] ? @"2.1" : @"auto";
    ai.audioAIEnabled = YES;
    [self aiAudioDidChangeWithMessage:[NSString stringWithFormat:@"Upsample: %@", sender.title]];
}

/// Audio ▸ Speaker Levels…: a panel with a slider per speaker group; changes reach the playing audio at once.
/// Per-speaker gains are applied by the in-process FFmpeg player. When the current media plays through AVPlayer
/// instead, the first adjustment moves it to the in-process player, resuming from the same position.
- (void)speakerLevelsDidChange:(NSNotification *)note {
    [self analyzeSpeakerLevelsIfNeeded];
    if (!VPAudioFilters.shared.hasSpeakerLevels || !self.mediaActive || self.dvdPlayer || self.bluRayNavigator ||
        self.playbackEngine.ffmpegPlayer) return;
    double position = [self.videoView currentMediaTime];
    if (![self startInProcessResumeAt:position]) [self restartAtPosition:position];
}

- (IBAction)showSpeakerLevels:(id)sender {
    if (!self.speakerLevelsController) self.speakerLevelsController = [VPSpeakerLevelsWindowController new];
    [self.speakerLevelsController showWindow:nil];
}

- (IBAction)selectAISampleRate:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    ai.targetSampleRate = sender.representedObject;
    if (![sender.representedObject isEqual:@"auto"]) ai.audioAIEnabled = YES;
    [self aiAudioDidChangeWithMessage:[NSString stringWithFormat:@"Sample Rate: %@", sender.title]];
}

- (IBAction)toggleAIAudioFlag:(NSMenuItem *)sender {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    BOOL on = ai.audioAIEnabled && [[ai valueForKey:sender.representedObject] boolValue];
    [ai setValue:@(!on) forKey:sender.representedObject];
    if (!on) ai.audioAIEnabled = YES;
    [self aiAudioDidChangeWithMessage:[NSString stringWithFormat:@"%@: %@", sender.title, on ? @"Off" : @"On"]];
}

#pragma mark - Windows and tools

- (void)showBuilder:(id)sender {
    if (!self.builder) self.builder = [[VPConfigurationBuilder alloc] initWithConfig:self.configManager player:self];
    [self.builder refresh]; [self.builder showWindow:nil];
}
- (void)windowWillClose:(NSNotification *)notification { [self endBluRayNavigation]; [self stopPlaybackKeepingStage]; }

#pragma mark - VPPlaybackEngineDelegate

- (void)playbackEngineDidStartPlaying { [self.videoView setPlaying:YES]; }
- (void)playbackEngineDidPause { [self.videoView setPlaying:NO]; }
- (void)playbackEngineDidStop { }

/// Streams: the bottom bar says so while audio is loading or has run out, and clears when playback is smooth.
- (void)playbackEngineBufferingDidChange:(BOOL)buffering progress:(double)progress {
    if (buffering) [self updateStatusText:[NSString stringWithFormat:@"Buffering… %d%%", (int)round(progress * 100)]];
    else if (self.bufferingStatusShown) [self updateStatusText:@""];
    self.bufferingStatusShown = buffering;
}

- (void)playbackEngineDidReachEnd {
    [self.videoView setPlaying:NO];
    if (self.bluRayNavigator) {
        // A menu video repeats under its buttons; a title that ends hands control back to the disc's commands,
        // which normally bring the menu back.
        if (self.bluRayMenuLooping) [self restartAtPosition:0]; else [self.bluRayNavigator playbackDidFinish];
        return;
    }
    VPPlaylistItem *next = [self.playlist advanceAutomatically:YES];
    if (next) { [self startPlaylistItem:next]; return; }
    // End of the queue: return to the stage and bring the menu back.
    [self stopPlayback:nil];
    [self.videoView setStatusText:@"Finished"];
    [self.hudOverlay showAnimated:YES];
}

- (void)playbackEngineDidUpdateTime:(CMTime)time { }

#pragma mark - Configuration window (advanced JSON editor)

- (void)showConfiguration:(id)sender {
    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 560) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.releasedWhenClosed = NO;
        self.settingsWindow.minSize = NSMakeSize(760, 560);
        self.settingsWindow.title = @"Configuration — JSON options and FFmpeg arguments";
        NSView *content = self.settingsWindow.contentView;
        NSTextField *help = [NSTextField wrappingLabelWithString:@"Edit all configuration keys below. Apply affects the next opened media. FFplay has its own playback window. Run FFmpeg uses ffmpegArguments exactly as entered; include input and output paths."];
        help.frame = NSMakeRect(16, 490, 728, 54);
        help.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [content addSubview:help];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 64, 728, 326)];
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scroll.hasVerticalScroller = YES;
        self.settingsText = [[NSTextView alloc] initWithFrame:scroll.bounds];
        self.settingsText.richText = NO;
        self.settingsText.automaticQuoteSubstitutionEnabled = NO;
        self.settingsText.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        self.settingsText.autoresizingMask = NSViewWidthSizable;
        scroll.documentView = self.settingsText;
        [content addSubview:scroll];
        NSArray *labels = @[@"Audio sample rate", @"Video processing", @"Upscale factor", @"Scaling backend"];
        NSArray *choices = @[
            @[@"auto", @"max", @"44100", @"48000", @"88200", @"96000", @"176400", @"192000", @"384000", @"768000"],
            @[@"none", @"deinterlace", @"inverseTelecine"],
            @[@"1", @"1.5", @"2", @"3", @"4"],
            @[@"metal", @"lanczos"]
        ];
        NSMutableArray *menus = [NSMutableArray array];
        for (NSUInteger i = 0; i < labels.count; i++) {
            NSTextField *label = [NSTextField labelWithString:labels[i]];
            label.frame = NSMakeRect(16 + i * 183, 453, 176, 22);
            label.autoresizingMask = NSViewMinYMargin;
            [content addSubview:label];
            NSPopUpButton *menu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16 + i * 183, 417, 176, 28) pullsDown:NO];
            [menu addItemsWithTitles:choices[i]];
            menu.tag = i;
            menu.target = self;
            menu.action = @selector(qualityOptionChanged:);
            menu.autoresizingMask = NSViewMinYMargin;
            menu.accessibilityLabel = labels[i];
            [content addSubview:menu];
            [menus addObject:menu];
        }
        self.qualityMenus = menus;
        NSArray *titles = @[@"Load…", @"Save As…", @"Apply", @"Run FFmpeg", @"Stop FFmpeg", @"5.1 Preset"];
        NSArray *selectors = @[@"loadConfiguration:", @"saveConfiguration:", @"applyConfiguration:", @"runFFmpeg:", @"stopFFmpeg:", @"surroundPreset:"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSButton *button = [NSButton buttonWithTitle:titles[i] target:self action:NSSelectorFromString(selectors[i])];
            button.frame = NSMakeRect(16 + i * 121, 18, 116, 32);
            [content addSubview:button];
        }
        [self.settingsWindow center];
    }
    [self refreshConfiguration];
    [self.settingsWindow makeKeyAndOrderFront:nil];
}

- (void)refreshConfiguration {
    NSMutableDictionary *dict = [[self.configManager toDictionary] mutableCopy];
    NSDictionary *examples = @{@"audioSampleRate":@"auto", @"deinterlace":@NO, @"inverseTelecine":@NO, @"fieldOrder":@"auto", @"upscale":@1, @"scaler":@"metal", @"audioLayout":@"auto", @"effect":@"none", @"shader":@"", @"vf":@"", @"af":@"", @"ffplayArguments":@[], @"ffmpegArguments":@[], @"loop":@NO, @"mute":@NO, @"ffmpeg":@NO, @"showMetadata":@YES, @"showFPS":@NO, @"visualizer":@NO, @"shuffle":@NO, @"repeat":@"off"};
    for (NSString *key in examples) if (!dict[key]) dict[key] = examples[key];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    self.settingsText.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *selections = @[dict[@"audioSampleRate"], [dict[@"inverseTelecine"] boolValue] ? @"inverseTelecine" : ([dict[@"deinterlace"] boolValue] ? @"deinterlace" : @"none"), [dict[@"upscale"] stringValue], dict[@"scaler"]];
    for (NSUInteger i = 0; i < self.qualityMenus.count; i++) {
        NSPopUpButton *menu = self.qualityMenus[i];
        if ([menu indexOfItemWithTitle:selections[i]] < 0) [menu addItemWithTitle:selections[i]];
        [menu selectItemWithTitle:selections[i]];
    }
}

- (void)qualityOptionChanged:(NSPopUpButton *)sender {
    if (![self readConfiguration]) return;
    NSMutableDictionary *dict = [[self.configManager toDictionary] mutableCopy];
    NSString *value = sender.titleOfSelectedItem;
    switch (sender.tag) {
        case 0: dict[@"audioSampleRate"] = value; break;
        case 1:
            dict[@"deinterlace"] = @([value isEqual:@"deinterlace"]);
            dict[@"inverseTelecine"] = @([value isEqual:@"inverseTelecine"]);
            if (![value isEqual:@"none"]) dict[@"scaler"] = @"lanczos";
            break;
        case 2: dict[@"upscale"] = @(value.doubleValue); break;
        case 3: dict[@"scaler"] = value; break;
    }
    NSError *error = nil;
    if (![self.configManager applyDictionary:dict error:&error]) [self configurationError:error];
    else [self refreshConfiguration];
}

- (void)configurationError:(NSError *)error {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Configuration";
    alert.informativeText = error.localizedDescription ?: @"Invalid JSON object.";
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
}

- (BOOL)readConfiguration {
    NSError *error = nil;
    id dict = [NSJSONSerialization JSONObjectWithData:[self.settingsText.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    if (![dict isKindOfClass:NSDictionary.class] || ![self.configManager applyDictionary:dict error:&error]) {
        [self configurationError:error]; return NO;
    }
    return YES;
}

- (void)applyConfiguration:(id)sender {
    if ([self readConfiguration]) { [self loadBackgroundImage]; [self loadPreferences]; }
}

- (void)surroundPreset:(id)sender {
    if (![self readConfiguration]) return;
    NSMutableDictionary *dict = [[self.configManager toDictionary] mutableCopy];
    dict[@"audioLayout"] = @"5.1"; dict[@"effect"] = @"none"; dict[@"shader"] = @""; dict[@"rate"] = @1;
    [self.configManager applyDictionary:dict error:nil];
    [self refreshConfiguration];
}

- (void)loadConfiguration:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.configManager loadFromPath:panel.URL.path error:&error]) [self configurationError:error];
        else { [self loadPreferences]; [self refreshConfiguration]; }
    }];
}

- (void)saveConfiguration:(id)sender {
    if (![self readConfiguration]) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"config.json";
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.configManager saveToPath:panel.URL.path error:&error]) [self configurationError:error];
    }];
}

- (void)exportEnhancedAudio:(NSMenuItem *)sender {
    if (!self.sourceURL || self.ffmpegJob.running) {
        [self.videoView showOSDText:self.ffmpegJob.running ? @"A conversion is already running" : @"Open a media file first" symbol:@"waveform" level:-1];
        return;
    }
    NSURL *input = self.sourceURL;
    NSString *codec = sender.representedObject;
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    NSString *graph = ai.isAudioAIActive ? [ai audioFilterGraphStringForDeviceUID:self.activeOptions[@"audioDevice"]] : @"";
    // Core AC-3/DTS export is 5.1 at 48 kHz; 7.1 is folded down by speaker label.
    NSString *tail = @"aformat=channel_layouts=5.1,aresample=48000,alimiter=limit=0.95:level=0";
    NSDictionary *options = @{
        @"audioOnly": @YES, @"audioStream": @(MAX(0, self.audioSelection)),
        @"audioCodec": codec, @"format": codec,
        @"audioBitRate": [codec isEqual:@"ac3"] ? @640000 : @1411200,
        @"appleSurroundLayout": @"5.1", @"surroundFill": @(ai.audioAIEnabled && ai.surroundFill),
        @"audioFilter": graph.length ? [graph stringByAppendingFormat:@",%@", tail] : tail,
        @"overwrite": @YES
    };
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [[input.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:codec];
    panel.message = @"Export the selected audio track with the current enhancement controls as a 5.1 file. Playback uses PCM; this does not enable receiver bitstream output.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        if (self.ffmpegJob.running) return;
        self.ffmpegJob = [VPFFmpegJob new];
        [self.videoView showOSDText:@"Exporting enhanced audio…" symbol:@"waveform" level:-1];
        __weak typeof(self) weakSelf = self;
        [self.ffmpegJob startInput:input output:panel.URL options:options completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) [weakSelf configurationError:error];
                else [weakSelf.videoView showOSDText:@"Audio export complete" symbol:@"checkmark" level:-1];
            });
        }];
    }];
}

- (void)runFFmpeg:(id)sender {
    if (![self readConfiguration] || self.ffmpegJob.running) return;
    NSArray *args = self.configManager.playbackOptions[@"ffmpegArguments"];
    if (!args.count) {
        [self configurationError:[NSError errorWithDomain:@"macvideoplayerErrorDomain" code:73 userInfo:@{NSLocalizedDescriptionKey:@"Enter ffmpegArguments as an array of individual argument strings."}]];
        return;
    }
    NSURL *input = nil, *output = nil;
    NSDictionary *options = nil;
    NSError *error = nil;
    if (![VPFFmpegLibrary parseArguments:args input:&input output:&output options:&options error:&error]) {
        [self configurationError:error];
        return;
    }
    self.ffmpegJob = [VPFFmpegJob new];
    __weak typeof(self) weakSelf = self;
    [self.ffmpegJob startInput:input output:output options:options completion:^(NSError * _Nullable jobError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (jobError) {
                [weakSelf configurationError:jobError];
            } else {
                [weakSelf configurationError:[NSError errorWithDomain:@"macvideoplayerFFmpeg" code:0 userInfo:@{NSLocalizedDescriptionKey:@"FFmpeg conversion finished successfully."}]];
            }
        });
    }];
}
- (void)stopFFmpeg:(id)sender {
    if (self.ffmpegJob.running) [self.ffmpegJob cancel];
}


#pragma mark - Aspect Ratio, Quality Presets, Snapshot & Missing Actions

- (IBAction)selectAspectRatio:(nullable NSMenuItem *)sender {
    if (!sender) return;
    VPAspectRatio ar = (VPAspectRatio)sender.tag;
    self.videoView.aspectRatio = ar;
    self.activeOptions[@"aspectRatio"] = @(ar);
    [self.videoView setNeedsLayout:YES];
    [self.videoView layoutSubtreeIfNeeded];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Aspect Ratio: %@", sender.title]];
}

- (void)updateProcessingHUD {
    [self.hudOverlay setNeedsDisplay:YES];
}

- (IBAction)openStream:(id)sender {
    [self openLocation:sender];
}

- (IBAction)openDiscImage:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"iso", @"img", @"toast", @"cdr", @"bin", @"nrg"];
#pragma clang diagnostic pop
    panel.message = @"Choose a DVD or Blu-ray disc image (.iso).";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) [self openURLs:@[panel.URL] shuffle:NO];
    }];
}

/// Blu-ray decryption needs the user's own KEYDB.cfg; it is copied to where libaacs looks for it.
- (IBAction)installAACSKeyDatabase:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.message = [NSString stringWithFormat:@"Choose your AACS key database (KEYDB.cfg). %@",
                     [VPDVDPlayer hasAACSKeyDatabase] ? @"This replaces the one already installed." : @"Protected Blu-rays cannot play without it."];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if ([VPDVDPlayer installAACSKeyDatabaseAtURL:panel.URL error:&error]) {
            [self.videoView showOSDText:@"AACS key database installed" symbol:@"key" level:-1];
        } else {
            [self reportPlaybackError:error];
        }
    }];
}

/// BD+ discs need device data that only the user can supply; this opens the folder libbdplus reads it from.
- (IBAction)showBDPlusDataFolder:(id)sender {
    NSError *error = nil;
    NSURL *folder = [VPDVDPlayer bdplusDataFolderURL:&error];
    if (folder) [NSWorkspace.sharedWorkspace openURL:folder]; else [self reportPlaybackError:error];
}

/// Loads the user's own aes_keys.bin and slots.bin for libbdplus (either or both can be chosen at once).
- (IBAction)installBDPlusKeys:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.message = @"Choose your BD+ files: aes_keys.bin and/or slots.bin. They are copied to where libbdplus reads them.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSMutableArray<NSString *> *installed = [NSMutableArray array];
        for (NSURL *url in panel.URLs) {
            NSError *error = nil;
            NSString *name = [VPDVDPlayer installBDPlusFileAtURL:url error:&error];
            if (name) [installed addObject:name]; else { [self reportPlaybackError:error]; return; }
        }
        if (installed.count) {
            [self.videoView showOSDText:[NSString stringWithFormat:@"BD+ installed: %@", [installed componentsJoinedByString:@", "]] symbol:@"key" level:-1];
        }
    }];
}

- (IBAction)openPlaylistFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"m3u", @"m3u8", @"pls"];
#pragma clang diagnostic pop
    panel.message = @"Choose a playlist file to load.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            if ([self.playlist loadPlaylistFromURL:panel.URL clearExisting:YES error:&err]) {
                if (self.playlist.items.count > 0) {
                    [self startPlaylistItem:[self.playlist selectIndex:0]];
                }
                [self.videoView setStatusText:[NSString stringWithFormat:@"Loaded playlist with %lu items", (unsigned long)self.playlist.items.count]];
            } else {
                [self.videoView setStatusText:err.localizedDescription ?: @"Failed to load playlist"];
            }
        }
    }];
}

- (IBAction)savePlaylistFile:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"m3u"];
#pragma clang diagnostic pop
    panel.nameFieldStringValue = @"playlist.m3u";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            if ([self.playlist saveToURL:panel.URL error:&err]) {
                [self.videoView setStatusText:@"Playlist saved successfully"];
            } else {
                [self.videoView setStatusText:err.localizedDescription ?: @"Failed to save playlist"];
            }
        }
    }];
}

- (IBAction)chooseSubtitleFont:(id)sender {
    NSFontManager *fm = [NSFontManager sharedFontManager];
    [fm orderFrontFontPanel:sender];
}

- (IBAction)setSubtitleFontFromMenu:(NSMenuItem *)sender {
    if (sender.title.length) {
        self.activeOptions[@"subtitleFont"] = sender.title;
        [self.videoView setStatusText:[NSString stringWithFormat:@"Subtitle Font: %@", sender.title]];
    }
}

- (IBAction)setSubtitleStyleFromMenu:(NSMenuItem *)sender {
    if (sender.title.length) {
        self.activeOptions[@"subtitleStyle"] = sender.title;
        [self.videoView setStatusText:[NSString stringWithFormat:@"Subtitle Style: %@", sender.title]];
    }
}

- (IBAction)selectSubtitlePosition:(NSMenuItem *)sender {
    if (sender.title.length) {
        self.activeOptions[@"subtitlePosition"] = sender.title;
        [self.videoView setStatusText:[NSString stringWithFormat:@"Subtitle Position: %@", sender.title]];
    }
}

- (IBAction)selectPostProcessingLevel:(NSMenuItem *)sender {
    double level = sender.tag / 100.0;
    VPPostProcessing.shared.level = level;
    VPPostProcessing.shared.enabled = (level > 0.01);
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Post-Processing: %.0f%%", level * 100.0]];
}

- (void)applyVideoQualityPresetNamed:(NSString *)name {
    NSDictionary *preset = [VPEffectPipeline optionsForVideoQualityPresetNamed:name];
    if (!preset) return;
    [self.activeOptions addEntriesFromDictionary:preset];
    if (preset[@"upscale"]) {
        VPAIEnhancer.shared.upscaleFactor = [preset[@"upscale"] doubleValue];
        // A quality preset the user picked may turn AI upscaling on; it never turns the rest of the AI video stack on.
        if (VPAIEnhancer.shared.upscaleFactor > 1.01) VPAIEnhancer.shared.videoAIEnabled = YES;
    }
    if (preset[@"enabled"]) {
        VPPostProcessing.shared.enabled = [preset[@"enabled"] boolValue];
    }
    if (preset[@"level"]) {
        VPPostProcessing.shared.level = [preset[@"level"] doubleValue];
    }
    if (preset[@"contrast"]) VPPostProcessing.shared.contrast = [preset[@"contrast"] doubleValue];
    if (preset[@"sharpness"]) VPPostProcessing.shared.sharpness = [preset[@"sharpness"] doubleValue];
    if (preset[@"saturation"]) VPPostProcessing.shared.saturation = [preset[@"saturation"] doubleValue];
    if (preset[@"noiseReduction"]) VPPostProcessing.shared.noiseReduction = [preset[@"noiseReduction"] doubleValue];
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Preset: %@", name]];
}

- (IBAction)selectVideoQualityPreset:(NSMenuItem *)sender {
    [self applyVideoQualityPresetNamed:sender.representedObject ?: sender.title];
}

- (IBAction)toggleDeinterlace:(id)sender {
    BOOL current = [self.activeOptions[@"deinterlace"] boolValue];
    self.activeOptions[@"deinterlace"] = @(!current);
    if (!current) self.activeOptions[@"inverseTelecine"] = @NO;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:!current ? @"Deinterlace: Enabled" : @"Deinterlace: Disabled"];
}

- (IBAction)toggleInverseTelecine:(id)sender {
    BOOL current = [self.activeOptions[@"inverseTelecine"] boolValue];
    self.activeOptions[@"inverseTelecine"] = @(!current);
    if (!current) self.activeOptions[@"deinterlace"] = @NO;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:!current ? @"Inverse Telecine: Enabled" : @"Inverse Telecine: Disabled"];
}

- (IBAction)setDeinterlaceMode:(NSMenuItem *)sender {
    self.activeOptions[@"deinterlaceMode"] = sender.representedObject ?: sender.title;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Deinterlace Mode: %@", sender.title]];
}

- (IBAction)setDeinterlaceFieldOrder:(NSMenuItem *)sender {
    self.activeOptions[@"fieldOrder"] = sender.representedObject ?: sender.title;
    [self refreshEffectsForcingRedraw:YES];
    [self.videoView setStatusText:[NSString stringWithFormat:@"Field Order: %@", sender.title]];
}

- (IBAction)takeSnapshot:(id)sender {
    CIImage *image = self.videoView.effectRenderer.currentImage ?: self.videoView.effectRenderer.currentSourceImage;
    if (!image) {
        [self.videoView setStatusText:@"No video frame available for snapshot"];
        return;
    }
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [ctx createCGImage:image fromRect:image.extent];
    if (!cgImage) {
        [self.videoView setStatusText:@"Snapshot capture failed"];
        return;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    CGImageRelease(cgImage);
    // PNG is lossless; the frame is captured now so the saved image matches what was on screen
    // when the user asked, even though the save panel is modal.
    NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!pngData) {
        [self.videoView setStatusText:@"Snapshot capture failed"];
        return;
    }

    static NSString *const kLastSnapshotDirKey = @"VPLastSnapshotDirectory";
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Save Snapshot";
    panel.message = @"Choose where to save the snapshot as a lossless PNG.";
    panel.allowedContentTypes = @[UTTypePNG];
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = [NSString stringWithFormat:@"macvideoplayer_snapshot_%@.png", [df stringFromDate:[NSDate date]]];
    NSString *lastDir = [[NSUserDefaults standardUserDefaults] stringForKey:kLastSnapshotDirKey];
    if (lastDir.length) panel.directoryURL = [NSURL fileURLWithPath:lastDir isDirectory:YES];

    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if (![pngData writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            [weakSelf.videoView setStatusText:[NSString stringWithFormat:@"Snapshot save failed: %@", error.localizedDescription]];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:panel.URL.URLByDeletingLastPathComponent.path forKey:kLastSnapshotDirKey];

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setData:pngData forType:NSPasteboardTypePNG];

        [weakSelf.videoView setStatusText:[NSString stringWithFormat:@"Snapshot saved: %@", panel.URL.lastPathComponent]];
        [weakSelf.videoView showOSDText:@"Snapshot saved" symbol:@"camera.fill" level:-1];
    }];
}

- (IBAction)replayIntro:(id)sender {
    [self.videoView playIntroWithCompletion:nil];
}

- (IBAction)showLicenseWindow:(id)sender {
    if (!self.licenseWindowController) {
        self.licenseWindowController = [[VPLicenseWindowController alloc] init];
    }
    [self.licenseWindowController showWindow:sender];
    [self.licenseWindowController.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)toggleControlsOverlay:(id)sender {
    self.videoView.controlsEnabled = !self.videoView.controlsEnabled;
    [self.videoView setStatusText:self.videoView.controlsEnabled ? @"Controls enabled" : @"Controls hidden"];
    [self.hudOverlay setToggle:@"controls" on:self.videoView.controlsEnabled];
}

- (IBAction)showAudioFilters:(id)sender {
    if (!self.audioFilterController) {
        self.audioFilterController = [VPAudioFilterWindowController new];
        __weak typeof(self) weakSelf = self;
        self.audioFilterController.applyHandler = ^{
            [weakSelf applyAudioFiltersNow];
        };
    }
    [self.audioFilterController reload];
    [self.audioFilterController showWindow:nil];
}

- (IBAction)toggleContextEqualizer:(id)sender {
    VPAudioFilters *filters = VPAudioFilters.shared;
    filters.equalizerEnabled = !(filters.enabled && filters.equalizerEnabled);
    if (filters.equalizerEnabled) filters.enabled = YES;
    [filters changed];
    [self.audioFilterController reload];
    [self applyAudioFiltersNow];
}

- (IBAction)selectContextEqualizerPreset:(NSMenuItem *)sender {
    VPAudioFilters *filters = VPAudioFilters.shared;
    filters.enabled = YES;
    [filters applyEqualizerPreset:sender.representedObject];
    filters.equalizerEnabled = YES;
    [filters changed];
    [self.audioFilterController reload];
    [self applyAudioFiltersNow];
}

- (IBAction)showEqualizer:(id)sender {
    [self showAudioFilters:sender];
    [self.audioFilterController focusEqualizer];
}

#pragma mark - DVD menus

/// Plays an authored DVD through its own navigation engine, starting with the disc's menus.
/// `videoTS` is the VIDEO_TS folder from +[VPDiscSupport dvdNavigationURLForURL:].
- (void)startDVDAtURL:(NSURL *)videoTS { [self startDiscAtURL:videoTS bluRayImage:NO]; }

/// Starts a DVD folder or DVD image, or (bluRayImage) a Blu-ray image, in the disc playback engine.
- (void)startDiscAtURL:(NSURL *)videoTS bluRayImage:(BOOL)bluRayImage {
    // Direct disc opening bypasses startPlaylistItem:, which normally initializes the effects options.
    NSError *optionsError = nil;
    NSDictionary *options = [VPProcessingPlan resolvedOptions:[self.configManager toDictionary] error:&optionsError];
    if (!options) { [self reportPlaybackError:optionsError]; return; }
    [self endBluRayNavigation];
    [self stopPlaybackKeepingStage];
    self.activeOptions = [options mutableCopy];
    [self.videoView cancelIntro];
    NSURL *discRoot = [videoTS.lastPathComponent.uppercaseString isEqualToString:@"VIDEO_TS"] ? videoTS.URLByDeletingLastPathComponent : videoTS;
    self.sourceURL = discRoot;
    self.sourceTitle = [VPDiscSupport isDiscImage:discRoot]
        ? [NSString stringWithFormat:@"%@ — %@", bluRayImage ? @"Blu-ray" : @"DVD", discRoot.lastPathComponent]
        : [VPDiscSupport titleForDisc:discRoot];
    self.probe = nil;
    self.metadataShownForMedia = NO;
    ++self.mediaToken;
    self.trackOverrides = [NSMutableDictionary dictionary];
    [self adoptCachedProfileForCurrentMedia];

    VPDVDPlayer *dvd = [VPDVDPlayer new];
    __weak typeof(self) weakSelf = self;
    dvd.errorHandler = ^(NSError *error) { [weakSelf reportPlaybackError:error]; };
    dvd.statusHandler = ^(NSString *status) { [weakSelf dvdStatusDidChange:status]; };
    dvd.volume = self.muted ? 0 : self.volumeLevel;
    dvd.audioOutputLayout = self.activeOptions[@"audioLayout"];
    [dvd applyAudioFiltersGraph:[self combinedAudioFilterGraph]];
    NSError *error = nil;
    if (!(bluRayImage ? [dvd openBluRayImageAtURL:videoTS error:&error] : [dvd openDiscAtURL:videoTS error:&error])) {
        [self reportPlaybackError:error ?: [NSError errorWithDomain:@"macvideoplayerDVD" code:4 userInfo:@{
            NSLocalizedDescriptionKey:@"Unable to start DVD menu playback."}]];
        return;
    }
    self.dvdPlayer = dvd;
    self.mediaActive = YES;
    self.window.title = [NSString stringWithFormat:@"Mac Video Player — %@", self.sourceTitle];
    self.hudOverlay.revealsOnMouseMovement = NO;
    [self.hudOverlay hideAnimated:NO];

    // The disc's frames go through the stage like any other in-process source: same controls, same effects.
    self.videoView.mediaLoaded = YES;
    self.videoView.hasVideo = YES;
    self.videoView.displayOffset = 0;
    self.preparedOffset = 0;
    [self.videoView attachStagePlayer:dvd];
    [self.videoView setPlaying:YES];
    self.compositionInstalled = NO;
    [self refreshEffectsForcingRedraw:NO];

    // Disc navigation sits at the top of the stage: always visible in a menu, and with the controls during a title.
    // DVD menus are drawn by the disc engine, which cannot take mouse clicks, so the bar's buttons (Menu, Play,
    // Titles, Chapters, arrows, Select) are the clickable way through them.
    VPDiscNavigationBar *bar = [[VPDiscNavigationBar alloc] initWithMenuTitle:bluRayImage ? @"Disc Menu" : @"DVD Menu"];
    __weak VPDVDPlayer *weakDVD = dvd;
    bar.menuHandler = ^{ [weakDVD showDiscMenu]; };
    bar.playHandler = ^{ [weakDVD playMainTitle]; };
    bar.navigateHandler = ^(VPDiscDirection direction) { [weakDVD navigate:(VPDVDNavigation)direction]; };
    bar.previousChapterHandler = ^{ [weakDVD previousChapter]; };
    bar.nextChapterHandler = ^{ [weakDVD nextChapter]; };
    bar.titlesProvider = ^NSArray<NSDictionary *> *{
        NSMutableArray *entries = [NSMutableArray array];
        for (NSDictionary *title in [weakDVD discTitles]) {
            NSInteger index = [title[@"index"] integerValue];
            double minutes = [title[@"duration"] doubleValue] / 60;
            [entries addObject:@{@"title": [NSString stringWithFormat:@"%@ — %d:%02d", title[@"name"], (int)minutes, (int)fmod([title[@"duration"] doubleValue], 60)],
                                 @"handler": ^{ [weakDVD selectTitle:index]; }}];
        }
        return entries;
    };
    bar.chaptersProvider = ^NSArray<NSDictionary *> *{
        NSMutableArray *entries = [NSMutableArray array];
        for (NSDictionary *chapter in [weakDVD discChapters]) {
            NSInteger index = [chapter[@"index"] integerValue];
            [entries addObject:@{@"title": chapter[@"name"], @"handler": ^{ [weakDVD selectChapter:index]; }}];
        }
        return entries;
    };
    [self installDiscBar:bar];
    self.dvdNavigationBar = bar;
    [self updateStatusText:@"Loading DVD…"];
    [self analyzeCurrentMediaIfNeeded];
}

/// The DVD engine reports where the disc is a few times a second; the bar follows the controls' visibility.
- (void)dvdStatusDidChange:(NSString *)status {
    if (!self.dvdPlayer) return;
    self.dvdNavigationBar.hidden = !(self.dvdPlayer.inMenu || self.videoView.controlsVisible);
    if (status.length) [self updateStatusText:status];
}

/// File ▸ DVD / Blu-ray Menu: returns to the disc's authored menu. Without a disc playing it starts the
/// current disc, then the first mounted DVD or Blu-ray, and otherwise asks for a disc.
- (IBAction)showDiscMenu:(id)sender {
    if (self.dvdPlayer) { [self.dvdPlayer showDiscMenu]; return; }
    if (self.bluRayNavigator) { [self.bluRayNavigator showTopMenu]; return; }
    NSURL *dvd = self.sourceURL ? [VPDiscSupport dvdNavigationURLForURL:self.sourceURL] : nil;
    NSURL *bluRay = self.sourceURL ? [VPDiscSupport bluRayNavigationURLForURL:self.sourceURL] : nil;
    if (!dvd && !bluRay) {
        for (NSURL *mounted in [VPDiscSupport mountedDiscs]) {
            dvd = [VPDiscSupport dvdNavigationURLForURL:mounted];
            if (dvd) break;
            bluRay = [VPDiscSupport bluRayNavigationURLForURL:mounted];
            if (bluRay) break;
        }
    }
    if (dvd) { [self startDVDAtURL:dvd]; return; }
    if (bluRay && [VPDVDPlayer isAACSProtectedBluRayAtURL:bluRay]) { [self startDiscAtURL:bluRay bluRayImage:YES]; return; }
    if (bluRay && [self startBluRayAtURL:bluRay]) return;
    [self openDisc:sender];
}

#pragma mark - Blu-ray menus

/// Plays an authored Blu-ray through its HDMV navigation: the disc's own menus first, then whatever their buttons
/// start. Returns NO when the disc has no navigation this player can run (for example Java menus), so the caller
/// can fall back to playing it as ordinary media.
- (BOOL)startBluRayAtURL:(NSURL *)discRoot {
    VPBluRayNavigator *navigator = [VPBluRayNavigator navigatorForDiscRoot:discRoot];
    if (!navigator) return NO;
    NSError *optionsError = nil;
    NSDictionary *options = [VPProcessingPlan resolvedOptions:[self.configManager toDictionary] error:&optionsError];
    if (!options) { [self reportPlaybackError:optionsError]; return YES; }
    [self endBluRayNavigation];
    [self stopPlaybackKeepingStage];
    self.activeOptions = [options mutableCopy];
    [self.videoView cancelIntro];
    self.sourceURL = discRoot;
    self.sourceTitle = [VPDiscSupport titleForDisc:discRoot];
    self.probe = nil;
    ++self.mediaToken;
    navigator.delegate = self;
    self.bluRayNavigator = navigator;
    [self installBluRayNavigationBar];
    [self updateStatusText:@"Loading Blu-ray…"];
    [navigator start];
    return YES;
}

/// Leaves the disc's navigation: no more commands run and its menu comes off the picture.
- (void)endBluRayNavigation {
    VPBluRayNavigator *navigator = self.bluRayNavigator;
    navigator.delegate = nil;
    self.bluRayNavigator = nil;
    self.bluRayMenuLooping = NO;
    self.pendingBluRayAudio = 0;
    self.pendingBluRayStart = 0;
    [self removeBluRayMenuView];
    [self.discBarTimer invalidate];
    self.discBarTimer = nil;
    [self.bluRayNavigationBar removeFromSuperview];
    self.bluRayNavigationBar = nil;
    self.bluRayCurrentPlaylist = nil;
    // The navigator may be the one calling us; keep it alive until its method has returned.
    if (navigator) dispatch_async(dispatch_get_main_queue(), ^{ (void)navigator; });
}

- (void)removeBluRayMenuView {
    self.bluRayMenuView.delegate = nil;
    [self.bluRayMenuView removeFromSuperview];
    self.bluRayMenuView = nil;
}

/// Adds a disc bar centred at the top of the window, above the picture and below the menu panel.
- (void)installDiscBar:(VPDiscNavigationBar *)bar {
    NSRect content = self.window.contentView.bounds;
    bar.frame = NSMakeRect(round(NSMidX(content) - bar.frame.size.width / 2), NSMaxY(content) - bar.frame.size.height - 12, bar.frame.size.width, bar.frame.size.height);
    [self.window.contentView addSubview:bar positioned:NSWindowBelow relativeTo:self.hudOverlay];
}

/// The Blu-ray bar: the same buttons as a DVD's, driven by the navigator. It shows whenever a menu is up and
/// otherwise with the playback controls, so it is there as soon as a disc loads and never gets in the way of a film.
- (void)installBluRayNavigationBar {
    VPDiscNavigationBar *bar = [[VPDiscNavigationBar alloc] initWithMenuTitle:@"Blu-ray Menu"];
    __weak typeof(self) weakSelf = self;
    bar.menuHandler = ^{ [weakSelf.bluRayNavigator showTopMenu]; };
    bar.playHandler = ^{ [weakSelf.bluRayNavigator playMainMovie]; };
    bar.navigateHandler = ^(VPDiscDirection direction) {
        VPBluRayMenuView *menu = weakSelf.bluRayMenuView;
        switch (direction) {
            case VPDiscDirectionUp: [menu moveSelection:VPBluRayMenuDirectionUp]; break;
            case VPDiscDirectionDown: [menu moveSelection:VPBluRayMenuDirectionDown]; break;
            case VPDiscDirectionLeft: [menu moveSelection:VPBluRayMenuDirectionLeft]; break;
            case VPDiscDirectionRight: [menu moveSelection:VPBluRayMenuDirectionRight]; break;
            case VPDiscDirectionSelect: [menu activateSelectedButton]; break;
        }
    };
    bar.previousChapterHandler = ^{ [weakSelf stepBluRayChapter:-1]; };
    bar.nextChapterHandler = ^{ [weakSelf stepBluRayChapter:1]; };
    bar.titlesProvider = ^NSArray<NSDictionary *> *{
        NSMutableArray *entries = [NSMutableArray array];
        NSUInteger number = 0;
        for (VPBluRayPlaylist *playlist in [weakSelf.bluRayNavigator moviePlaylists]) {
            number++;
            [entries addObject:@{@"title": [NSString stringWithFormat:@"Title %lu — %d:%02d (playlist %@)", (unsigned long)number, (int)(playlist.duration / 60), (int)fmod(playlist.duration, 60), playlist.name],
                                 @"checked": @([weakSelf.bluRayCurrentPlaylist.name isEqualToString:playlist.name]),
                                 @"handler": ^{ [weakSelf.bluRayNavigator playMoviePlaylist:playlist]; }}];
        }
        return entries;
    };
    bar.chaptersProvider = ^NSArray<NSDictionary *> *{
        NSMutableArray *entries = [NSMutableArray array];
        NSArray<NSNumber *> *marks = weakSelf.bluRayCurrentPlaylist.markTimes;
        for (NSUInteger i = 0; i < marks.count; i++) {
            double start = marks[i].doubleValue;
            [entries addObject:@{@"title": [NSString stringWithFormat:@"Chapter %lu — %d:%02d", (unsigned long)i + 1, (int)(start / 60), (int)fmod(start, 60)],
                                 @"handler": ^{ [weakSelf seekToAbsolute:start]; }}];
        }
        return entries;
    };
    [self installDiscBar:bar];
    self.bluRayNavigationBar = bar;
    self.discBarTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) {
        VPWindowController *controller = weakSelf;
        if (!controller) { [timer invalidate]; return; }
        controller.bluRayNavigationBar.hidden = !(controller.bluRayMenuView || controller.videoView.controlsVisible);
    }];
}

/// Chapter skip while a title plays: jumps to the next or previous chapter mark of the playlist.
- (void)stepBluRayChapter:(int)direction {
    NSArray<NSNumber *> *marks = self.bluRayCurrentPlaylist.markTimes;
    if (!marks.count) return;
    double now = [self.videoView currentMediaTime];
    double target = -1;
    if (direction > 0) { for (NSNumber *mark in marks) if (mark.doubleValue > now + 1) { target = mark.doubleValue; break; } }
    else { for (NSNumber *mark in marks.reverseObjectEnumerator) if (mark.doubleValue < now - 3) { target = mark.doubleValue; break; } if (target < 0) target = 0; }
    if (target >= 0) [self seekToAbsolute:target];
}

- (void)bluRayNavigator:(VPBluRayNavigator *)navigator playPlaylist:(VPBluRayPlaylist *)playlist startSeconds:(double)seconds audioStream:(NSInteger)audioStream {
    NSURL *url = [VPDiscSupport playbackURLForBluRayPlaylist:playlist.name discRoot:navigator.discRoot];
    if (!url) {
        [self bluRayNavigator:navigator didEndWithMessage:[NSString stringWithFormat:@"Playlist %@ on the disc could not be opened.", playlist.name]];
        return;
    }
    VPPlaylistItem *item = [VPPlaylistItem new];
    item.url = url;
    item.title = [NSString stringWithFormat:@"%@ · playlist %@", self.sourceTitle, playlist.name];
    self.pendingBluRayAudio = audioStream;
    self.pendingBluRayStart = seconds;
    self.bluRayCurrentPlaylist = playlist;
    self.bluRayMenuLooping = NO;
    self.startingBluRayItem = YES;
    [self startPlaylistItem:item];
}

- (void)bluRayNavigator:(VPBluRayNavigator *)navigator showMenuForPlaylist:(VPBluRayPlaylist *)playlist page:(VPBluRayMenuPage *)page selectedButton:(NSInteger)buttonID {
    // A short menu clip (usually one frame) is a still picture behind the buttons; a longer one is a video that
    // repeats under them.
    NSURL *loopURL = playlist.duration > 5 ? [VPDiscSupport playbackURLForBluRayPlaylist:playlist.name discRoot:navigator.discRoot] : nil;
    if (loopURL) {
        VPPlaylistItem *item = [VPPlaylistItem new];
        item.url = loopURL;
        item.title = [NSString stringWithFormat:@"%@ · menu", self.sourceTitle];
        self.startingBluRayItem = YES;
        [self startPlaylistItem:item];
        self.bluRayMenuLooping = YES;
    } else {
        [self stopPlaybackKeepingStage];
        self.bluRayMenuLooping = NO;
        self.mediaActive = YES;
        self.videoView.mediaLoaded = YES;
        self.videoView.hasVideo = YES;
        [self.videoView setPlaying:NO];
        [self.videoView hideMetadata];
        self.window.title = [NSString stringWithFormat:@"Mac Video Player — %@", self.sourceTitle];
        self.hudOverlay.revealsOnMouseMovement = NO;
        [self.hudOverlay hideAnimated:YES];
        [self updateStatusText:@"Blu-ray menu"];
    }

    self.bluRayCurrentPlaylist = nil;
    VPBluRayMenuView *menu = [[VPBluRayMenuView alloc] initWithFrame:self.videoView.bounds];
    menu.delegate = self;
    menu.page = page;
    menu.selectedButtonID = buttonID;
    [self.videoView insertOverlayBelowControls:menu];
    self.bluRayMenuView = menu;

    if (!loopURL) {
        NSURL *clip = playlist.clipURLs.firstObject;
        __weak VPBluRayMenuView *weakMenu = menu;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CIImage *frame = [VPFFmpegLibrary frameAtTime:0 fromURL:clip error:nil];
            CGImageRef cgImage = frame ? [[CIContext context] createCGImage:frame fromRect:frame.extent] : NULL;
            NSImage *image = cgImage ? [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage))] : nil;
            if (cgImage) CGImageRelease(cgImage);
            dispatch_async(dispatch_get_main_queue(), ^{ weakMenu.backgroundImage = image; });
        });
    }
}

- (void)bluRayNavigator:(VPBluRayNavigator *)navigator didEndWithMessage:(NSString *)message {
    [self endBluRayNavigation];
    [self stopPlayback:nil];
    [self.videoView setStatusText:message.length ? message : @"Finished"];
    [self.hudOverlay showAnimated:YES];
    if (message.length) NSLog(@"macvideoplayer Blu-ray: %@", message);
}

- (void)bluRayMenuView:(VPBluRayMenuView *)view didActivateButton:(VPBluRayButton *)button {
    [self.bluRayNavigator activateButton:button.buttonID];
}

- (void)applyAudioFiltersNow {
    NSString *graph = [self combinedAudioFilterGraphLeavingRateToPlayer:self.dvdPlayer == nil];
    
    if (self.dvdPlayer) {
        [self.dvdPlayer applyAudioFiltersGraph:graph];
        [self.videoView setStatusText:graph.length > 0 ? [NSString stringWithFormat:@"Audio filter: %@", graph] : @"Audio filters bypassed / cleared"];
    } else if (self.playbackEngine.ffmpegPlayer) {
        [self.playbackEngine.ffmpegPlayer applyAudioFiltersGraph:graph];
        if (graph.length > 0) {
            [self.videoView setStatusText:[NSString stringWithFormat:@"Audio filter: %@", graph]];
        } else {
            [self.videoView setStatusText:@"Audio filters bypassed / cleared"];
        }
    } else if (self.mediaActive) {
        double pos = [self.videoView currentMediaTime];
        if (![self startInProcessResumeAt:pos]) {
            [self restartAtPosition:pos];
        }
    }
    [self updateProcessingHUD];
}

- (IBAction)showAudioOutput:(id)sender {
    if (!self.audioOutputController) {
        self.audioOutputController = [VPAudioOutputWindowController new];
        __weak typeof(self) weakSelf = self;
        self.audioOutputController.currentSettings = ^NSDictionary<NSString *,NSString *> *{
            NSMutableDictionary *settings = [NSMutableDictionary dictionary];
            settings[@"audioSampleRate"] = weakSelf.activeOptions[@"audioSampleRate"] ?: @"auto";
            settings[@"audioLayout"] = weakSelf.activeOptions[@"audioLayout"] ?: @"auto";
            settings[@"audioDevice"] = weakSelf.activeOptions[@"audioDevice"] ?: @"";
            return settings;
        };
        self.audioOutputController.applyHandler = ^(NSDictionary<NSString *,NSString *> *settings) {
            [weakSelf applyAudioOutputSettings:settings];
        };
    }
    [self.audioOutputController reload];
    [self.audioOutputController showWindow:nil];
}

- (void)applyAudioOutputSettings:(NSDictionary<NSString *, NSString *> *)settings {
    NSString *uid = settings[@"audioDevice"];
    if (uid.length > 0) {
        NSError *error = nil;
        [VPAudioDeviceManager setOutputDeviceUID:uid error:&error];
        if (error) {
            [self.videoView setStatusText:error.localizedDescription];
        } else {
            [self.videoView setStatusText:[NSString stringWithFormat:@"Audio output: %@", uid]];
        }
    }
    
    NSMutableDictionary *opts = [self.activeOptions mutableCopy] ?: [NSMutableDictionary dictionary];
    if (settings[@"audioSampleRate"]) opts[@"audioSampleRate"] = settings[@"audioSampleRate"];
    if (settings[@"audioLayout"]) opts[@"audioLayout"] = settings[@"audioLayout"];
    if (settings[@"audioDevice"]) opts[@"audioDevice"] = settings[@"audioDevice"];
    self.activeOptions = opts;
    
    if (self.mediaActive) {
        double pos = [self.videoView currentMediaTime];
        [self restartAtPosition:pos];
    }
}
@end
