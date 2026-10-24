//
//  VPDiscNavigationBar.h
//  macvideoplayer
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPDiscDirection) {
    VPDiscDirectionSelect = 0,
    VPDiscDirectionUp,
    VPDiscDirectionDown,
    VPDiscDirectionLeft,
    VPDiscDirectionRight
};

/// The on-screen controls of a DVD or Blu-ray: the disc's menu, Play (the main feature), a list of titles, a list of
/// chapters, chapter skip and the arrow/Select buttons for navigating a menu. Everything is a button the mouse can
/// click, so a disc can be driven without the keyboard. The same bar serves both disc types; the window controller
/// fills in what each button does.
@interface VPDiscNavigationBar : NSView
/// Title of the first button, such as "DVD Menu" or "Blu-ray Menu".
- (instancetype)initWithMenuTitle:(NSString *)menuTitle;

@property (nonatomic, copy, nullable) void (^menuHandler)(void);
@property (nonatomic, copy, nullable) void (^playHandler)(void);
@property (nonatomic, copy, nullable) void (^navigateHandler)(VPDiscDirection direction);
@property (nonatomic, copy, nullable) void (^previousChapterHandler)(void);
@property (nonatomic, copy, nullable) void (^nextChapterHandler)(void);
/// Called when the Titles or Chapters button is clicked. Each entry is @{@"title": NSString, @"checked": NSNumber
/// (optional), @"handler": void (^)(void)}. An empty list shows a disabled "None available" row.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> * (^titlesProvider)(void);
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> * (^chaptersProvider)(void);
@end

NS_ASSUME_NONNULL_END
