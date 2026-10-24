#import "VPSpeakerLevelsWindowController.h"
#import "VPAudioFilters.h"

@interface VPSpeakerLevelsWindowController ()
@property (nonatomic, copy) NSDictionary<NSString *, NSSlider *> *sliders;
@property (nonatomic, copy) NSDictionary<NSString *, NSTextField *> *valueLabels;
@property (nonatomic, copy) NSArray<NSButton *> *resetButtons;
@property (nonatomic, strong) NSButton *autoCheckbox;
@property (nonatomic, strong) NSTextField *autoStatus;
@end

@implementation VPSpeakerLevelsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 380)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Speaker Levels";
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) {
        [self buildInterface];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:VPAudioFiltersDidChangeNotification object:nil];
        [window center];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)buildInterface {
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    NSMutableDictionary *sliders = [NSMutableDictionary dictionary], *labels = [NSMutableDictionary dictionary];
    NSMutableArray<NSButton *> *resetButtons = [NSMutableArray array];
    NSDictionary *hints = @{@"front": @"Left and right speakers", @"center": @"Dialogue", @"subwoofer": @"Low-frequency effects",
                            @"rear": @"Surround pair (5.1) or back pair (7.1)", @"side": @"Side pair, 7.1 only"};
    for (NSString *group in VPAudioFilters.speakerGroups) {
        NSTextField *title = [NSTextField labelWithString:[VPAudioFilters titleForSpeakerGroup:group]];
        title.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
        title.toolTip = hints[group];
        [title.widthAnchor constraintEqualToConstant:130].active = YES;

        NSSlider *slider = [NSSlider sliderWithValue:0 minValue:-12 maxValue:12 target:self action:@selector(sliderMoved:)];
        slider.numberOfTickMarks = 25;
        slider.allowsTickMarkValuesOnly = NO;
        slider.identifier = group;
        slider.toolTip = hints[group];
        [slider.widthAnchor constraintGreaterThanOrEqualToConstant:170].active = YES;

        NSTextField *value = [NSTextField labelWithString:@"0 dB"];
        value.alignment = NSTextAlignmentRight;
        value.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        [value.widthAnchor constraintEqualToConstant:56].active = YES;

        NSButton *reset = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(resetOne:)];
        reset.identifier = group;
        reset.controlSize = NSControlSizeSmall;

        NSStackView *row = [NSStackView stackViewWithViews:@[title, slider, value, reset]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 10;
        [rows addObject:row];
        sliders[group] = slider;
        labels[group] = value;
        [resetButtons addObject:reset];
    }
    self.resetButtons = resetButtons;
    self.sliders = sliders;
    self.valueLabels = labels;

    NSTextField *note = [NSTextField wrappingLabelWithString:@"Applies to the playing audio at once, before any downmix. Rear is the surround pair on 5.1 and the back pair on 7.1; Side exists only on 7.1 sources."];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    NSButton *resetAll = [NSButton buttonWithTitle:@"Reset All" target:self action:@selector(resetAll:)];

    self.autoCheckbox = [NSButton checkboxWithTitle:@"Find the ideal levels for each file automatically (AI analysis)" target:self action:@selector(autoToggled:)];
    self.autoCheckbox.toolTip = @"Measures the loudness of each speaker group in the playing file and balances them: buried dialogue comes forward and overpowering surround or bass is pulled back. The sliders show the result.";
    self.autoStatus = [NSTextField wrappingLabelWithString:@""];
    self.autoStatus.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.autoStatus.textColor = NSColor.secondaryLabelColor;
    [self.autoStatus.widthAnchor constraintEqualToConstant:400].active = YES;
    NSView *separator = [NSBox new];
    ((NSBox *)separator).boxType = NSBoxSeparator;
    [separator.widthAnchor constraintEqualToConstant:400].active = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:[@[self.autoCheckbox, self.autoStatus, separator] arrayByAddingObjectsFromArray:[rows arrayByAddingObjectsFromArray:@[note, resetAll]]]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [note.widthAnchor constraintEqualToConstant:400].active = YES;

    NSView *content = self.window.contentView;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    [self refresh];
}

- (void)showWindow:(id)sender {
    [self refresh];
    [super showWindow:sender];
}

/// Syncs every control with the stored levels (also reacts to changes made from the menus).
- (void)refresh {
    VPAudioFilters *filters = VPAudioFilters.shared;
    BOOL automatic = filters.autoSpeakerLevels;
    self.autoCheckbox.state = automatic ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoStatus.stringValue = automatic ? (filters.autoSpeakerStatus ?: @"Play a file and its levels will be measured.") : @"";
    self.autoStatus.hidden = !automatic;
    for (NSSlider *slider in self.sliders.allValues) slider.enabled = !automatic;
    for (NSButton *button in self.resetButtons) button.enabled = !automatic;
    for (NSString *group in VPAudioFilters.speakerGroups) {
        double level = [VPAudioFilters.shared levelForSpeakerGroup:group];
        self.sliders[group].doubleValue = level;
        self.valueLabels[group].stringValue = [NSString stringWithFormat:@"%+.1f dB", level];
        if (fabs(level) < 0.05) self.valueLabels[group].stringValue = @"0 dB";
    }
}

- (void)autoToggled:(NSButton *)checkbox {
    VPAudioFilters.shared.autoSpeakerStatus = nil;
    VPAudioFilters.shared.autoSpeakerLevels = checkbox.state == NSControlStateValueOn;
}

- (void)sliderMoved:(NSSlider *)slider {
    double snapped = fabs(slider.doubleValue) < 0.4 ? 0 : slider.doubleValue;   // a notch at 0 dB
    [VPAudioFilters.shared setLevel:snapped forSpeakerGroup:slider.identifier];
}

- (void)resetOne:(NSButton *)button {
    [VPAudioFilters.shared setLevel:0 forSpeakerGroup:button.identifier];
}

- (void)resetAll:(id)sender {
    [VPAudioFilters.shared resetSpeakerLevels];
}

@end
