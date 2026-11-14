#import "VPAIVideoWindowController.h"
#import "VPAIEnhancer.h"

@interface VPAIVideoWindowController ()
@property (nonatomic, strong) NSButton *enabledBox;
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSPopUpButton *upscalePopup;
@property (nonatomic, strong) NSSegmentedControl *compareControl;
@property (nonatomic, strong) NSButton *animeBox;
@property (nonatomic, strong) NSSlider *animeSlider;
@property (nonatomic, strong) NSTextField *animeValue;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *hdrBox;
@property (nonatomic, strong) NSButton *cinemaBox;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSSlider *> *sliders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *values;
/// Set while this window is the one changing the enhancer, so its own notification does not rebuild the controls mid-drag.
@property (nonatomic) BOOL editing;
@end

@implementation VPAIVideoWindowController

static NSArray<NSArray *> *PresetList(void) {
    return @[@[@"Off", @"none"], @[@"Adaptive AI (Analyze This File)", @"adaptive"], @[@"Vivid & Crisp", @"vivid_crisp"], @[@"Cinema HDR", @"cinema_hdr"],
             @[@"Anime Pop", @"anime_pop"], @[@"Super Resolution 2×", @"super_resolution_2x"], @[@"Clean Restore (Denoise)", @"clean_restore"]];
}

/// Sliders by group: key, title, minimum, maximum.
static NSArray<NSArray *> *SliderGroups(void) {
    return @[
        @[@"Detail", @[@[@"clarityBoost", @"Clarity", @0, @1], @[@"luminanceSharpness", @"Sharpness", @0, @1], @[@"lineDefinition", @"Line Definition", @0, @1],
                       @[@"localContrast", @"Depth (Local Contrast)", @0, @1], @[@"microContrast", @"Micro Contrast", @0, @1],
                       @[@"adaptiveDenoise", @"Noise Reduction", @0, @1], @[@"flatSmoothing", @"Flat Area Smoothing", @0, @1]]],
        @[@"Colour & Tone", @[@[@"vividVibrance", @"Vivid Colour", @0, @1], @[@"colorPop", @"Colour Pop", @0, @1], @[@"contrastCurve", @"Contrast Curve", @0, @1],
                              @[@"shadowLift", @"Shadow Lift", @0, @1], @[@"highlightRecovery", @"Highlight Recovery", @0, @1],
                              @[@"saturationTrim", @"Saturation", @-0.5, @0.5], @[@"temperatureShift", @"Warmth", @-0.5, @0.5]]]
    ];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 100) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"AI Video Enhancement";
    window.releasedWhenClosed = NO;
    // Stays above the video while the picture is being tuned, even when the player window is clicked.
    window.level = NSFloatingWindowLevel;
    window.hidesOnDeactivate = NO;
    if ((self = [super initWithWindow:window])) {
        _sliders = [NSMutableDictionary dictionary];
        _values = [NSMutableDictionary dictionary];
        [self buildUI];
        [window center];
        [self refresh];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(externalChange:) name:VPAIEnhancerDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark - Layout

- (NSTextField *)labelAt:(NSRect)frame text:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    return label;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    NSArray<NSArray *> *groups = SliderGroups();
    NSUInteger sliderRows = 0;
    for (NSArray *group in groups) sliderRows += [group[1] count];
    const CGFloat width = 480, rowHeight = 26, margin = 20;
    // Header (intro, look, upscale, compare, status), the groups with their titles, the two switches, the buttons.
    CGFloat height = 266 + sliderRows * rowHeight + groups.count * 30 + (groups.count - 1) * 12 + 34 + 56;
    [self.window setContentSize:NSMakeSize(width, height)];
    CGFloat y = height - 20;

    NSTextField *intro = [NSTextField wrappingLabelWithString:@"Pick a look, then fine-tune it. Changes apply to the picture as it plays. Use Compare to see the original next to the enhanced picture."];
    intro.frame = NSMakeRect(margin, y - 36, width - 2 * margin, 36);
    intro.textColor = NSColor.secondaryLabelColor; intro.font = [NSFont systemFontOfSize:12];
    [content addSubview:intro];
    y -= 50;

    self.enabledBox = [NSButton checkboxWithTitle:@"Enable AI video enhancement" target:self action:@selector(enabledToggled:)];
    self.enabledBox.frame = NSMakeRect(margin, y - 22, 260, 22);
    [content addSubview:self.enabledBox];
    NSButton *reset = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(resetAll:)];
    reset.frame = NSMakeRect(width - margin - 80, y - 24, 80, 26);
    [content addSubview:reset];
    y -= 34;

    [content addSubview:[self labelAt:NSMakeRect(margin, y - 20, 70, 20) text:@"Look:"]];
    self.presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(90, y - 24, width - 90 - margin, 26) pullsDown:NO];
    for (NSArray *preset in PresetList()) { [self.presetPopup addItemWithTitle:preset[0]]; self.presetPopup.lastItem.representedObject = preset[1]; }
    [self.presetPopup addItemWithTitle:@"Custom"];
    self.presetPopup.lastItem.representedObject = @"custom";
    self.presetPopup.target = self; self.presetPopup.action = @selector(presetChosen:);
    [content addSubview:self.presetPopup];
    y -= 34;

    [content addSubview:[self labelAt:NSMakeRect(margin, y - 20, 70, 20) text:@"Upscale:"]];
    self.upscalePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(90, y - 24, 140, 26) pullsDown:NO];
    for (NSNumber *factor in @[@1, @1.5, @2, @3, @4]) {
        [self.upscalePopup addItemWithTitle:factor.doubleValue <= 1 ? @"Off" : [NSString stringWithFormat:@"%.2g×", factor.doubleValue]];
        self.upscalePopup.lastItem.representedObject = factor;
    }
    self.upscalePopup.target = self; self.upscalePopup.action = @selector(upscaleChosen:);
    [content addSubview:self.upscalePopup];
    y -= 34;

    [content addSubview:[self labelAt:NSMakeRect(margin, y - 20, 70, 20) text:@"Compare:"]];
    self.compareControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Enhanced", @"Original", @"Split"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(compareChanged:)];
    self.compareControl.frame = NSMakeRect(90, y - 24, 250, 26);
    [content addSubview:self.compareControl];
    y -= 34;

    self.animeBox = [NSButton checkboxWithTitle:@"Anime mode" target:self action:@selector(animeToggled:)];
    self.animeBox.frame = NSMakeRect(margin, y - 22, 110, 22);
    self.animeBox.toolTip = @"For animation: removes colour fringing along lines, cleans flat colour and compression noise, deepens ink lines and lifts cel colour.";
    [content addSubview:self.animeBox];
    self.animeSlider = [NSSlider sliderWithValue:0.7 minValue:0.1 maxValue:1.0 target:self action:@selector(animeStrengthMoved:)];
    self.animeSlider.frame = NSMakeRect(184, y - 20, 210, 20);
    self.animeSlider.accessibilityLabel = @"Anime mode strength";
    [content addSubview:self.animeSlider];
    self.animeValue = [self labelAt:NSMakeRect(398, y - 20, width - 398 - margin, 20) text:@""];
    self.animeValue.alignment = NSTextAlignmentRight;
    self.animeValue.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [content addSubview:self.animeValue];
    y -= 34;

    self.statusLabel = [self labelAt:NSMakeRect(margin, y - 20, width - 2 * margin, 20) text:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [content addSubview:self.statusLabel];
    y -= 34;

    for (NSArray *group in groups) {
        if (group != groups.firstObject) y -= 12;
        NSTextField *title = [self labelAt:NSMakeRect(margin, y - 18, width - 2 * margin, 18) text:group[0]];
        title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        [content addSubview:title];
        NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(margin, y - 22, width - 2 * margin, 1)];
        rule.boxType = NSBoxSeparator;
        [content addSubview:rule];
        y -= 30;
        for (NSArray *row in group[1]) {
            [content addSubview:[self labelAt:NSMakeRect(margin, y - 20, 160, 20) text:row[1]]];
            NSSlider *slider = [NSSlider sliderWithValue:0 minValue:[row[2] doubleValue] maxValue:[row[3] doubleValue] target:self action:@selector(sliderMoved:)];
            slider.frame = NSMakeRect(184, y - 20, 210, 20);
            slider.identifier = row[0]; slider.accessibilityLabel = row[1];
            slider.continuous = YES;
            [content addSubview:slider];
            NSTextField *value = [self labelAt:NSMakeRect(398, y - 20, width - 398 - margin, 20) text:@""];
            value.alignment = NSTextAlignmentRight;
            value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
            [content addSubview:value];
            self.sliders[row[0]] = slider; self.values[row[0]] = value;
            y -= rowHeight;
        }
    }
    y -= 8;
    self.hdrBox = [NSButton checkboxWithTitle:@"HDR Tone Mapping" target:self action:@selector(flagToggled:)];
    self.hdrBox.identifier = @"hdrDynamicTone"; self.hdrBox.frame = NSMakeRect(margin, y - 22, 200, 22);
    [content addSubview:self.hdrBox];
    self.cinemaBox = [NSButton checkboxWithTitle:@"Cinema Colour Grade" target:self action:@selector(flagToggled:)];
    self.cinemaBox.identifier = @"cinemaColorGrade"; self.cinemaBox.frame = NSMakeRect(240, y - 22, 200, 22);
    [content addSubview:self.cinemaBox];

    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self.window action:@selector(performClose:)];
    done.frame = NSMakeRect(width - margin - 80, 16, 80, 30); done.keyEquivalent = @"\r";
    [content addSubview:done];
}

#pragma mark - Reading state

- (NSString *)percentText:(double)value signed:(BOOL)isSigned {
    long percent = lround(value * 100);
    return isSigned && percent > 0 ? [NSString stringWithFormat:@"+%ld%%", percent] : [NSString stringWithFormat:@"%ld%%", percent];
}

- (void)refresh {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    self.enabledBox.state = ai.isVideoAIActive ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSString *key in self.sliders) {
        NSSlider *slider = self.sliders[key];
        double value = [[ai valueForKey:key] doubleValue];
        slider.doubleValue = value;
        self.values[key].stringValue = [self percentText:value signed:slider.minValue < 0];
    }
    self.animeBox.state = ai.animeMode ? NSControlStateValueOn : NSControlStateValueOff;
    self.animeSlider.doubleValue = ai.animeStrength;
    self.animeSlider.enabled = ai.animeMode;
    self.animeValue.stringValue = [self percentText:ai.animeStrength signed:NO];
    self.hdrBox.state = ai.hdrDynamicTone ? NSControlStateValueOn : NSControlStateValueOff;
    self.cinemaBox.state = ai.cinemaColorGrade ? NSControlStateValueOn : NSControlStateValueOff;

    NSString *preset = ai.isVideoAIActive ? ai.activeVideoPreset : @"none";
    NSMenuItem *match = nil;
    for (NSMenuItem *item in self.presetPopup.itemArray) if ([item.representedObject isEqual:preset]) { match = item; break; }
    [self.presetPopup selectItem:match ?: self.presetPopup.lastItem];

    NSInteger upscaleIndex = 0;
    for (NSInteger i = 0; i < self.upscalePopup.numberOfItems; i++) {
        if (fabs([[self.upscalePopup itemAtIndex:i].representedObject doubleValue] - MAX(1.0, ai.upscaleFactor)) < 0.01) upscaleIndex = i;
    }
    [self.upscalePopup selectItemAtIndex:upscaleIndex];

    NSInteger mode = MAX(0, MIN(2, ai.comparisonMode));
    self.compareControl.selectedSegment = mode;
    [self updateStatus];
}

- (void)updateStatus {
    VPAIEnhancer *ai = VPAIEnhancer.shared;
    if (!ai.isVideoAIActive) { self.statusLabel.stringValue = @"Off — the picture is untouched."; self.statusLabel.textColor = NSColor.secondaryLabelColor; return; }
    NSUInteger adjustments = 0;
    for (NSString *key in self.sliders) if (fabs([[ai valueForKey:key] doubleValue]) > 0.01) adjustments++;
    if (ai.hdrDynamicTone) adjustments++;
    if (ai.cinemaColorGrade) adjustments++;
    if (ai.upscaleFactor > 1.01) adjustments++;
    if (ai.animeMode) adjustments++;
    NSString *name = self.presetPopup.titleOfSelectedItem ?: @"Custom";
    if (ai.animeMode) name = [ai.activeVideoPreset isEqual:@"none"] ? @"Anime mode" : [name stringByAppendingString:@" + anime mode"];
    NSString *state = ai.comparisonMode == 1 ? @" · showing the original" : (ai.comparisonMode == 2 ? @" · split: original left, enhanced right" : @"");
    if (ai.adaptiveVideoEnabled && !ai.adaptiveProfile) {
        self.statusLabel.stringValue = @"Adaptive AI — waiting for the file to be analyzed…";
    } else {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"On — %@, %lu adjustment%@%@", name, (unsigned long)adjustments, adjustments == 1 ? @"" : @"s", state];
    }
    self.statusLabel.textColor = NSColor.labelColor;
}

- (void)externalChange:(NSNotification *)note {
    if (!self.editing) [self refresh];
}

#pragma mark - Editing

/// Runs a change to the enhancer and redraws the picture.
- (void)applyChange:(void (^)(VPAIEnhancer *ai))change {
    self.editing = YES;
    change(VPAIEnhancer.shared);
    [VPAIEnhancer.shared changed];
    if (self.pictureNeedsRefresh) self.pictureNeedsRefresh();
    self.editing = NO;
}

/// A manual adjustment turns the effect on and ends any named look (the adaptive look would otherwise overwrite it).
- (void)adopt:(VPAIEnhancer *)ai {
    ai.videoAIEnabled = YES;
    if (ai.adaptiveVideoEnabled) ai.adaptiveVideoEnabled = NO;
    ai.activeVideoPreset = @"custom";
}

- (void)enabledToggled:(NSButton *)sender {
    BOOL on = sender.state == NSControlStateValueOn;
    [self applyChange:^(VPAIEnhancer *ai) {
        if (!on) { [ai resetVideoAI]; return; }
        // Turning it on with nothing selected would do nothing visible, so start from a balanced look.
        if (!ai.isVideoAIActive) [ai applyVideoPreset:@"vivid_crisp"];
        else ai.videoAIEnabled = YES;
    }];
    [self refresh];
}

- (void)presetChosen:(NSPopUpButton *)sender {
    NSString *key = sender.selectedItem.representedObject;
    if ([key isEqual:@"custom"]) { [self refresh]; return; }
    [self applyChange:^(VPAIEnhancer *ai) {
        if ([key isEqual:@"none"]) [ai resetVideoAI];
        else [ai applyVideoPreset:key];
    }];
    [self refresh];
}

- (void)upscaleChosen:(NSPopUpButton *)sender {
    double factor = [sender.selectedItem.representedObject doubleValue];
    [self applyChange:^(VPAIEnhancer *ai) {
        ai.upscaleFactor = factor;
        if (factor > 1.01) [self adopt:ai];
    }];
    [self refresh];
}

- (void)compareChanged:(NSSegmentedControl *)sender {
    [self applyChange:^(VPAIEnhancer *ai) { ai.comparisonMode = sender.selectedSegment; }];
    [self refresh];
}

- (void)sliderMoved:(NSSlider *)slider {
    NSString *key = slider.identifier;
    double value = slider.doubleValue;
    self.values[key].stringValue = [self percentText:value signed:slider.minValue < 0];
    [self applyChange:^(VPAIEnhancer *ai) {
        [ai setValue:@(value) forKey:key];
        [self adopt:ai];
    }];
    // Only the readouts that depend on the whole state; the sliders themselves are already where the user put them.
    self.enabledBox.state = NSControlStateValueOn;
    NSMenuItem *custom = self.presetPopup.lastItem;
    [self.presetPopup selectItem:custom];
    [self updateStatus];
}

- (void)animeToggled:(NSButton *)sender {
    BOOL on = sender.state == NSControlStateValueOn;
    [self applyChange:^(VPAIEnhancer *ai) {
        ai.animeMode = on;
        if (on) ai.videoAIEnabled = YES;
    }];
    [self refresh];
}

- (void)animeStrengthMoved:(NSSlider *)slider {
    double value = slider.doubleValue;
    self.animeValue.stringValue = [self percentText:value signed:NO];
    [self applyChange:^(VPAIEnhancer *ai) { ai.animeStrength = value; }];
}

- (void)flagToggled:(NSButton *)sender {
    NSString *key = sender.identifier;
    BOOL on = sender.state == NSControlStateValueOn;
    [self applyChange:^(VPAIEnhancer *ai) {
        [ai setValue:@(on) forKey:key];
        [self adopt:ai];
    }];
    [self refresh];
}

- (void)resetAll:(id)sender {
    [self applyChange:^(VPAIEnhancer *ai) { [ai resetVideoAI]; }];
    [self refresh];
}

@end
