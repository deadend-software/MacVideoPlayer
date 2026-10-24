//
//  VPDiscNavigationBar.m
//  macvideoplayer
//

#import "VPDiscNavigationBar.h"

typedef NS_ENUM(NSInteger, VPDiscBarAction) {
    VPDiscBarActionMenu = 100,
    VPDiscBarActionPlay,
    VPDiscBarActionTitles,
    VPDiscBarActionChapters,
    VPDiscBarActionPreviousChapter,
    VPDiscBarActionNextChapter
    // 0…4 are the VPDiscDirection values of the arrow and Select buttons.
};

@implementation VPDiscNavigationBar

- (instancetype)initWithMenuTitle:(NSString *)menuTitle {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 10, 36)])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.62].CGColor;
        self.layer.cornerRadius = 9;
        self.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;

        // title, tag, width, tooltip. A nil title is a gap between groups.
        NSArray<NSArray *> *items = @[
            @[menuTitle, @(VPDiscBarActionMenu), @98, @"Go to the disc's own menu (Escape on a DVD, ⌥⌘M)"],
            @[@"▶ Play", @(VPDiscBarActionPlay), @70, @"Play the main feature"],
            @[@"Titles ▾", @(VPDiscBarActionTitles), @76, @"Choose a title to play"],
            @[@"Chapters ▾", @(VPDiscBarActionChapters), @92, @"Jump to a chapter of the title that is playing"],
            @[@"⏮", @(VPDiscBarActionPreviousChapter), @34, @"Previous chapter"],
            @[@"⏭", @(VPDiscBarActionNextChapter), @34, @"Next chapter"],
            @[NSNull.null, @0, @10, @""],
            @[@"◀", @(VPDiscDirectionLeft), @34, @"Move the menu highlight left (arrow keys)"],
            @[@"▲", @(VPDiscDirectionUp), @34, @"Move the menu highlight up"],
            @[@"▼", @(VPDiscDirectionDown), @34, @"Move the menu highlight down"],
            @[@"▶", @(VPDiscDirectionRight), @34, @"Move the menu highlight right"],
            @[@"Select", @(VPDiscDirectionSelect), @62, @"Choose the highlighted menu button (Return, or click the button itself)"]];
        CGFloat x = 8;
        for (NSArray *item in items) {
            CGFloat width = [item[2] doubleValue];
            if (item[0] == NSNull.null) { x += width; continue; }
            NSButton *button = [NSButton buttonWithTitle:item[0] target:self action:@selector(pressed:)];
            button.tag = [item[1] integerValue];
            button.bezelStyle = NSBezelStyleRounded;
            button.toolTip = item[3];
            button.frame = NSMakeRect(x, 4, width, 28);
            [self addSubview:button];
            x += width + 4;
        }
        self.frame = NSMakeRect(0, 0, x + 4, 36);
    }
    return self;
}

- (void)pressed:(NSButton *)sender {
    switch (sender.tag) {
        case VPDiscBarActionMenu: if (self.menuHandler) self.menuHandler(); break;
        case VPDiscBarActionPlay: if (self.playHandler) self.playHandler(); break;
        case VPDiscBarActionTitles: [self popUpEntries:self.titlesProvider ? self.titlesProvider() : nil below:sender]; break;
        case VPDiscBarActionChapters: [self popUpEntries:self.chaptersProvider ? self.chaptersProvider() : nil below:sender]; break;
        case VPDiscBarActionPreviousChapter: if (self.previousChapterHandler) self.previousChapterHandler(); break;
        case VPDiscBarActionNextChapter: if (self.nextChapterHandler) self.nextChapterHandler(); break;
        default: if (self.navigateHandler) self.navigateHandler((VPDiscDirection)sender.tag); break;
    }
}

/// Shows a clickable list under the button. Long lists scroll like any pop-up menu.
- (void)popUpEntries:(NSArray<NSDictionary *> *)entries below:(NSView *)anchor {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    if (!entries.count) {
        NSMenuItem *none = [menu addItemWithTitle:@"None available" action:nil keyEquivalent:@""];
        none.enabled = NO;
    }
    for (NSDictionary *entry in entries) {
        NSMenuItem *item = [menu addItemWithTitle:entry[@"title"] ?: @"" action:@selector(entryChosen:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = entry[@"handler"];
        item.state = [entry[@"checked"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -2) inView:anchor];
}

- (void)entryChosen:(NSMenuItem *)sender {
    void (^handler)(void) = sender.representedObject;
    if (handler) handler();
}

@end
