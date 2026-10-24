//
//  VPBluRayMenuView.m
//  macvideoplayer
//

#import "VPBluRayMenuView.h"

static const NSTimeInterval kVPActivationFlash = 0.15;   // how long the activated picture shows before the commands run

@implementation VPBluRayMenuView {
    NSTrackingArea *_trackingArea;
    NSInteger _activatedButtonID;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        _selectedButtonID = -1;
        _activatedButtonID = -1;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }      // button positions are measured from the top left, like the disc's video
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return NO; }

- (void)setPage:(VPBluRayMenuPage *)page {
    _page = page;
    [self setNeedsDisplay:YES];
}

- (void)setBackgroundImage:(NSImage *)backgroundImage {
    _backgroundImage = backgroundImage;
    [self setNeedsDisplay:YES];
}

- (void)setSelectedButtonID:(NSInteger)selectedButtonID {
    if (_selectedButtonID == selectedButtonID) return;
    _selectedButtonID = selectedButtonID;
    [self setNeedsDisplay:YES];
}

#pragma mark - Geometry

/// The 16:9 (or whatever the disc declares) picture area, fitted and centred inside the view.
- (NSRect)videoRect {
    NSSize video = self.page.videoSize;
    if (video.width <= 0 || video.height <= 0) video = NSMakeSize(1920, 1080);
    CGFloat scale = MIN(self.bounds.size.width / video.width, self.bounds.size.height / video.height);
    NSSize size = NSMakeSize(video.width * scale, video.height * scale);
    return NSMakeRect(round((self.bounds.size.width - size.width) / 2), round((self.bounds.size.height - size.height) / 2), size.width, size.height);
}

- (NSRect)rectForButton:(VPBluRayButton *)button {
    NSRect video = [self videoRect];
    CGFloat scale = video.size.width / MAX(1, self.page.videoSize.width);
    return NSMakeRect(video.origin.x + button.frame.origin.x * scale, video.origin.y + button.frame.origin.y * scale,
                      button.frame.size.width * scale, button.frame.size.height * scale);
}

- (VPBluRayButton *)buttonAtPoint:(NSPoint)point {
    for (VPBluRayButton *button in self.page.buttons) {
        if (NSPointInRect(point, [self rectForButton:button])) return button;
    }
    return nil;
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    if (!self.page) return;
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    if (self.backgroundImage) {
        [self.backgroundImage drawInRect:[self videoRect] fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                fraction:1 respectFlipped:YES hints:nil];
    }
    for (VPBluRayButton *button in self.page.buttons) {
        NSImage *picture = button.buttonID == _activatedButtonID ? button.activatedImage
                         : button.buttonID == self.selectedButtonID ? button.selectedImage : button.normalImage;
        if (!picture) continue;
        [picture drawInRect:[self rectForButton:button] fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                   fraction:1 respectFlipped:YES hints:nil];
    }
}

#pragma mark - Mouse

/// Only the buttons take clicks; everywhere else the player's own controls and gestures keep working.
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return [self buttonAtPoint:local] ? self : nil;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                 options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                   owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
    VPBluRayButton *button = [self buttonAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (button && _activatedButtonID < 0) self.selectedButtonID = button.buttonID;
}

- (void)mouseDown:(NSEvent *)event {
    VPBluRayButton *button = [self buttonAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (button) [self activateButton:button];
}

#pragma mark - Keyboard

- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (!self.page || self.hidden || !self.superview || _activatedButtonID >= 0) return NO;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) return NO;

    switch (event.keyCode) {
        case 126: [self moveSelection:VPBluRayMenuDirectionUp]; return YES;
        case 125: [self moveSelection:VPBluRayMenuDirectionDown]; return YES;
        case 123: [self moveSelection:VPBluRayMenuDirectionLeft]; return YES;
        case 124: [self moveSelection:VPBluRayMenuDirectionRight]; return YES;
        case 36: case 76: case 49:      // Return, keypad Enter, Space
            [self activateSelectedButton];
            return YES;
        default: break;
    }

    NSString *digits = event.charactersIgnoringModifiers;
    if (digits.length == 1 && [digits characterAtIndex:0] >= '1' && [digits characterAtIndex:0] <= '9') {
        NSInteger value = [digits integerValue];
        for (VPBluRayButton *button in self.page.buttons) {
            if (button.numericValue == value) { self.selectedButtonID = button.buttonID; [self activateButton:button]; return YES; }
        }
    }
    return NO;
}

- (void)moveSelection:(VPBluRayMenuDirection)direction {
    VPBluRayButton *current = [self.page buttonWithID:self.selectedButtonID];
    NSInteger neighbour = -1;
    if (current) {
        switch (direction) {
            case VPBluRayMenuDirectionUp: neighbour = current.upID; break;
            case VPBluRayMenuDirectionDown: neighbour = current.downID; break;
            case VPBluRayMenuDirectionLeft: neighbour = current.leftID; break;
            case VPBluRayMenuDirectionRight: neighbour = current.rightID; break;
        }
    }
    VPBluRayButton *next = neighbour >= 0 ? [self.page buttonWithID:neighbour] : nil;
    if (next) self.selectedButtonID = next.buttonID;
    else if (!current) self.selectedButtonID = self.page.buttons.firstObject.buttonID;
}

- (void)activateSelectedButton {
    VPBluRayButton *current = [self.page buttonWithID:self.selectedButtonID];
    if (current) [self activateButton:current];
}

#pragma mark - Activation

/// Shows the activated picture for a moment, then hands the button to the delegate to run its commands.
- (void)activateButton:(VPBluRayButton *)button {
    if (_activatedButtonID >= 0) return;
    self.selectedButtonID = button.buttonID;
    _activatedButtonID = button.buttonID;
    [self setNeedsDisplay:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVPActivationFlash * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VPBluRayMenuView *view = weakSelf;
        if (!view || view->_activatedButtonID != button.buttonID) return;
        view->_activatedButtonID = -1;
        [view setNeedsDisplay:YES];
        [view.delegate bluRayMenuView:view didActivateButton:button];
    });
}

@end
