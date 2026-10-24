//
//  VPBluRayMenuView.h
//  macvideoplayer
//

#import <AppKit/AppKit.h>
#import "VPBluRayNavigator.h"

NS_ASSUME_NONNULL_BEGIN

@class VPBluRayMenuView;

typedef NS_ENUM(NSInteger, VPBluRayMenuDirection) {
    VPBluRayMenuDirectionUp,
    VPBluRayMenuDirectionDown,
    VPBluRayMenuDirectionLeft,
    VPBluRayMenuDirectionRight
};

@protocol VPBluRayMenuViewDelegate <NSObject>
- (void)bluRayMenuView:(VPBluRayMenuView *)view didActivateButton:(VPBluRayButton *)button;
@end

/// Draws a Blu-ray menu page over the picture: the button pictures in their normal, selected and activated
/// states, laid out in the video's 16:9 area. Clicks that miss every button fall through to the player below,
/// so the playback controls keep working.
@interface VPBluRayMenuView : NSView
@property (nonatomic, weak, nullable) id<VPBluRayMenuViewDelegate> delegate;
@property (nonatomic, strong, nullable) VPBluRayMenuPage *page;
/// The menu's still background. nil when live video plays underneath.
@property (nonatomic, strong, nullable) NSImage *backgroundImage;
@property (nonatomic) NSInteger selectedButtonID;
/// Arrow keys move the selection, Return/Enter/Space activate it and number keys pick a numbered button.
/// Returns YES when the key was used.
- (BOOL)handleKeyEvent:(NSEvent *)event;
/// Moves the highlight to the neighbour the disc defines in that direction (the on-screen arrow buttons use this).
- (void)moveSelection:(VPBluRayMenuDirection)direction;
/// Activates the highlighted button, as a click or Return would.
- (void)activateSelectedButton;
@end

NS_ASSUME_NONNULL_END
