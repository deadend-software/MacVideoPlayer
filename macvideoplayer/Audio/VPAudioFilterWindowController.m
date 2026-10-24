#import "VPAudioFilterWindowController.h"
#import "VPAudioFilters.h"

@interface VPChainTableView : NSTableView
@property (nonatomic, copy, nullable) void (^deleteHandler)(void);
@end

@implementation VPChainTableView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 51 || event.keyCode == 117) { // Delete or Forward Delete
        if (self.deleteHandler) { self.deleteHandler(); return; }
    }
    [super keyDown:event];
}
@end

@interface VPAudioFilterWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
// 10-Band Graphic Equalizer Controls
@property (nonatomic, strong) NSBox *equalizerBox;
@property (nonatomic, strong) NSButton *eqEnableCheckbox;
@property (nonatomic, strong) NSPopUpButton *eqPresetPopup;
@property (nonatomic, strong) NSSlider *eqPreampSlider;
@property (nonatomic, strong) NSTextField *eqPreampValueLabel;
@property (nonatomic, strong) NSMutableArray<NSSlider *> *eqBandSliders;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *eqBandValueLabels;

// FFmpeg Audio Filter Library Controls
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *categoryPopup;
@property (nonatomic, strong) NSTableView *libraryTable;
@property (nonatomic, strong) NSTextField *libraryDetail;
@property (nonatomic, strong) NSTextField *libraryOptions;

// Active Filter Chain & Inspector Controls
@property (nonatomic, strong) VPChainTableView *chainTable;
@property (nonatomic, strong) NSTextField *inspectorTitle;
@property (nonatomic, strong) NSSlider *amountSlider;
@property (nonatomic, strong) NSTextField *amountLabel;
@property (nonatomic, strong) NSTextField *expressionField;
@property (nonatomic, strong) NSButton *updateButton;

@property (nonatomic, strong) NSTextField *customField;
@property (nonatomic, strong) NSTextField *graphLabel;
@property (nonatomic, strong) NSTextField *statusLabel;

@property (nonatomic, strong) NSButton *liveUpdateCheckbox;
@property (nonatomic, strong) NSButton *bypassCheckbox;

@property (nonatomic, strong) NSArray<VPAudioFilterTemplate *> *allTemplates;
@property (nonatomic, strong) NSMutableArray<VPAudioFilterTemplate *> *filteredTemplates;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *stages;
@end

@implementation VPAudioFilterWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 820)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Equalizer & Audio Filters — 10-Band EQ + FFmpeg Audio Chain";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(940, 760);
    window.frameAutosaveName = @"VPAudioFilterWindowV2";
    if ((self = [super initWithWindow:window])) {
        window.delegate = self;
        _allTemplates = [VPAudioFilters library];
        _filteredTemplates = [_allTemplates mutableCopy];
        _stages = [NSMutableArray array];
        _eqBandSliders = [NSMutableArray arrayWithCapacity:10];
        _eqBandValueLabels = [NSMutableArray arrayWithCapacity:10];
        [self buildUI];
        [window center];
        [self reload];
    }
    return self;
}

- (void)focusEqualizer {
    [self reload];
    if (self.eqPresetPopup) {
        [self.window makeFirstResponder:self.eqPresetPopup];
    }
}

#pragma mark - UI Building

- (void)buildUI {
    NSView *content = self.window.contentView;
    CGFloat width = [self.window contentRectForFrameRect:self.window.frame].size.width;
    CGFloat height = [self.window contentRectForFrameRect:self.window.frame].size.height;
    if (width < 980) width = 980;
    if (height < 820) height = 820;

    // =========================================================================
    // TOP SECTION: 10-BAND GRAPHIC EQUALIZER + PREAMP + PRESETS
    // =========================================================================
    CGFloat eqBoxHeight = 205.0;
    CGFloat eqBoxY = height - eqBoxHeight - 12.0;
    self.equalizerBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, eqBoxY, width - 40, eqBoxHeight)];
    self.equalizerBox.title = @"10-Band Graphic Equalizer (±12 dB)";
    self.equalizerBox.titleFont = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.equalizerBox.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    NSView *eqView = self.equalizerBox.contentView;

    // Header row inside EQ box: Enable checkbox, Preset selector, Reset button
    self.eqEnableCheckbox = [NSButton checkboxWithTitle:@"Enable Equalizer" target:self action:@selector(eqEnableToggled:)];
    self.eqEnableCheckbox.frame = NSMakeRect(14, eqBoxHeight - 52, 140, 22);
    self.eqEnableCheckbox.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    [eqView addSubview:self.eqEnableCheckbox];

    NSTextField *presetLbl = [NSTextField labelWithString:@"Preset:"];
    presetLbl.frame = NSMakeRect(168, eqBoxHeight - 50, 48, 18);
    presetLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [eqView addSubview:presetLbl];

    self.eqPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(218, eqBoxHeight - 54, 185, 26) pullsDown:NO];
    for (NSString *preset in [VPAudioFilters equalizerPresets]) {
        [self.eqPresetPopup addItemWithTitle:preset];
    }
    self.eqPresetPopup.target = self;
    self.eqPresetPopup.action = @selector(eqPresetChanged:);
    [eqView addSubview:self.eqPresetPopup];

    NSButton *eqResetBtn = [NSButton buttonWithTitle:@"Flat (0 dB)" target:self action:@selector(eqResetClicked:)];
    eqResetBtn.frame = NSMakeRect(412, eqBoxHeight - 54, 96, 26);
    eqResetBtn.bezelStyle = NSBezelStyleRounded;
    [eqView addSubview:eqResetBtn];

    NSTextField *eqHintLbl = [NSTextField labelWithString:@"Drag sliders for instant live EQ adjustment (-12 dB to +12 dB)"];
    eqHintLbl.frame = NSMakeRect(524, eqBoxHeight - 50, 400, 18);
    eqHintLbl.font = [NSFont systemFontOfSize:11];
    eqHintLbl.textColor = NSColor.secondaryLabelColor;
    [eqView addSubview:eqHintLbl];

    // Preamp Vertical Slider on the left
    CGFloat sliderBottomY = 26.0;
    CGFloat sliderHeight = 96.0;
    CGFloat valueLabelY = sliderBottomY + sliderHeight + 2.0;

    self.eqPreampValueLabel = [NSTextField labelWithString:@"+0.0 dB"];
    self.eqPreampValueLabel.frame = NSMakeRect(14, valueLabelY, 64, 15);
    self.eqPreampValueLabel.alignment = NSTextAlignmentCenter;
    self.eqPreampValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];
    [eqView addSubview:self.eqPreampValueLabel];

    self.eqPreampSlider = [NSSlider sliderWithValue:0.0 minValue:-12.0 maxValue:12.0 target:self action:@selector(eqPreampChanged:)];
    self.eqPreampSlider.vertical = YES;
    self.eqPreampSlider.continuous = YES;
    self.eqPreampSlider.numberOfTickMarks = 5;
    self.eqPreampSlider.frame = NSMakeRect(32, sliderBottomY, 28, sliderHeight);
    [eqView addSubview:self.eqPreampSlider];

    NSTextField *preampNameLbl = [NSTextField labelWithString:@"Preamp"];
    preampNameLbl.frame = NSMakeRect(14, 6, 64, 16);
    preampNameLbl.alignment = NSTextAlignmentCenter;
    preampNameLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    [eqView addSubview:preampNameLbl];

    // Vertical separator between Preamp and 10 Bands
    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(90, 10, 1, eqBoxHeight - 66)];
    sep.boxType = NSBoxSeparator;
    [eqView addSubview:sep];

    // dB scale reference labels (+12, 0, -12)
    NSTextField *topDB = [NSTextField labelWithString:@"+12"];
    topDB.frame = NSMakeRect(96, sliderBottomY + sliderHeight - 14, 28, 14);
    topDB.font = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular];
    topDB.textColor = NSColor.secondaryLabelColor;
    [eqView addSubview:topDB];

    NSTextField *midDB = [NSTextField labelWithString:@"  0"];
    midDB.frame = NSMakeRect(96, sliderBottomY + (sliderHeight / 2.0) - 7, 28, 14);
    midDB.font = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular];
    midDB.textColor = NSColor.secondaryLabelColor;
    [eqView addSubview:midDB];

    NSTextField *botDB = [NSTextField labelWithString:@"-12"];
    botDB.frame = NSMakeRect(96, sliderBottomY, 28, 14);
    botDB.font = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular];
    botDB.textColor = NSColor.secondaryLabelColor;
    [eqView addSubview:botDB];

    // 10 Band Sliders
    NSArray<NSString *> *bandLabels = [VPAudioFilters equalizerBandLabels];
    CGFloat startX = 132.0;
    CGFloat bandSpacing = 78.0;
    for (NSUInteger i = 0; i < 10; i++) {
        CGFloat x = startX + i * bandSpacing;

        NSTextField *valLbl = [NSTextField labelWithString:@"+0.0"];
        valLbl.frame = NSMakeRect(x - 18, valueLabelY, 64, 15);
        valLbl.alignment = NSTextAlignmentCenter;
        valLbl.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];
        [eqView addSubview:valLbl];
        [self.eqBandValueLabels addObject:valLbl];

        NSSlider *bandSlider = [NSSlider sliderWithValue:0.0 minValue:-12.0 maxValue:12.0 target:self action:@selector(eqBandSliderChanged:)];
        bandSlider.tag = (NSInteger)i;
        bandSlider.vertical = YES;
        bandSlider.continuous = YES;
        bandSlider.numberOfTickMarks = 5;
        bandSlider.frame = NSMakeRect(x, sliderBottomY, 28, sliderHeight);
        [eqView addSubview:bandSlider];
        [self.eqBandSliders addObject:bandSlider];

        NSString *freqText = (i < bandLabels.count) ? [NSString stringWithFormat:@"%@ Hz", bandLabels[i]] : @"";
        NSTextField *freqLbl = [NSTextField labelWithString:freqText];
        freqLbl.frame = NSMakeRect(x - 18, 6, 64, 16);
        freqLbl.alignment = NSTextAlignmentCenter;
        freqLbl.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
        freqLbl.textColor = NSColor.secondaryLabelColor;
        [eqView addSubview:freqLbl];
    }

    [content addSubview:self.equalizerBox];

    // =========================================================================
    // LOWER SECTION: FFMPEG FILTER LIBRARY (LEFT) & ACTIVE FILTER CHAIN (RIGHT)
    // =========================================================================
    CGFloat panesTopY = eqBoxY - 10.0;

    // LEFT PANE: FFmpeg Filter Library
    NSTextField *libTitle = [NSTextField labelWithString:@"FFmpeg Audio Filter Library"];
    libTitle.frame = NSMakeRect(20, panesTopY - 22, 260, 20);
    libTitle.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    libTitle.autoresizingMask = NSViewMinYMargin;
    [content addSubview:libTitle];

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, panesTopY - 52, 240, 24)];
    self.searchField.placeholderString = @"Search filters…";
    self.searchField.delegate = self;
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);
    self.searchField.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.searchField];

    self.categoryPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(268, panesTopY - 53, 192, 26) pullsDown:NO];
    for (NSString *cat in [VPAudioFilters categories]) {
        [self.categoryPopup addItemWithTitle:cat];
    }
    self.categoryPopup.target = self;
    self.categoryPopup.action = @selector(categoryChanged:);
    self.categoryPopup.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.categoryPopup];

    // Library Table
    NSScrollView *libScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 224, 440, panesTopY - 284)];
    libScroll.hasVerticalScroller = YES;
    libScroll.borderType = NSBezelBorder;
    libScroll.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;

    self.libraryTable = [[NSTableView alloc] initWithFrame:libScroll.bounds];
    NSTableColumn *colName = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    colName.title = @"Filter (Double-click to Add)";
    colName.width = 285;
    colName.resizingMask = NSTableColumnAutoresizingMask;
    [self.libraryTable addTableColumn:colName];

    NSTableColumn *colCat = [[NSTableColumn alloc] initWithIdentifier:@"cat"];
    colCat.title = @"Category";
    colCat.width = 130;
    [self.libraryTable addTableColumn:colCat];

    self.libraryTable.dataSource = self;
    self.libraryTable.delegate = self;
    self.libraryTable.rowHeight = 24;
    self.libraryTable.doubleAction = @selector(addFromLibrary:);
    self.libraryTable.target = self;
    libScroll.documentView = self.libraryTable;
    [content addSubview:libScroll];

    // Library Filter Info Box
    NSBox *libInfoBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 146, 440, 72)];
    libInfoBox.title = @"Filter Info & Syntax";
    libInfoBox.titleFont = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    libInfoBox.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;

    self.libraryDetail = [NSTextField wrappingLabelWithString:@"Select an FFmpeg audio filter above to view its details."];
    self.libraryDetail.frame = NSMakeRect(8, 24, 424, 30);
    self.libraryDetail.font = [NSFont systemFontOfSize:11];
    self.libraryDetail.textColor = NSColor.labelColor;
    [libInfoBox.contentView addSubview:self.libraryDetail];

    self.libraryOptions = [NSTextField wrappingLabelWithString:@""];
    self.libraryOptions.frame = NSMakeRect(8, 6, 424, 16);
    self.libraryOptions.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.libraryOptions.textColor = NSColor.secondaryLabelColor;
    [libInfoBox.contentView addSubview:self.libraryOptions];
    [content addSubview:libInfoBox];

    NSButton *addLibBtn = [NSButton buttonWithTitle:@"+ Add to Chain →" target:self action:@selector(addFromLibrary:)];
    addLibBtn.frame = NSMakeRect(20, 112, 150, 28);
    addLibBtn.bezelStyle = NSBezelStyleRounded;
    addLibBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    addLibBtn.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:addLibBtn];

    // RIGHT PANE: Active Audio Filter Chain
    NSTextField *chainTitle = [NSTextField labelWithString:@"Active Filter Chain (Processed After Equalizer)"];
    chainTitle.frame = NSMakeRect(480, panesTopY - 22, 460, 20);
    chainTitle.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    chainTitle.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    [content addSubview:chainTitle];

    // Chain Table
    NSScrollView *chainScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(480, 306, width - 500, panesTopY - 336)];
    chainScroll.hasVerticalScroller = YES;
    chainScroll.borderType = NSBezelBorder;
    chainScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinXMargin;

    self.chainTable = [[VPChainTableView alloc] initWithFrame:chainScroll.bounds];
    NSTableColumn *cIndex = [[NSTableColumn alloc] initWithIdentifier:@"idx"];
    cIndex.title = @"#";
    cIndex.width = 30;
    [self.chainTable addTableColumn:cIndex];

    NSTableColumn *cExpr = [[NSTableColumn alloc] initWithIdentifier:@"expr"];
    cExpr.title = @"Active Filter Expression";
    cExpr.width = 420;
    cExpr.resizingMask = NSTableColumnAutoresizingMask;
    [self.chainTable addTableColumn:cExpr];

    self.chainTable.dataSource = self;
    self.chainTable.delegate = self;
    self.chainTable.rowHeight = 24;
    __weak typeof(self) weakSelf = self;
    self.chainTable.deleteHandler = ^{
        [weakSelf removeStage:nil];
    };
    chainScroll.documentView = self.chainTable;
    [content addSubview:chainScroll];

    // Chain Action Buttons
    NSButton *upBtn = [NSButton buttonWithTitle:@"▲ Move Up" target:self action:@selector(moveUp:)];
    upBtn.frame = NSMakeRect(480, 272, 95, 26);
    upBtn.bezelStyle = NSBezelStyleRounded;
    upBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:upBtn];

    NSButton *downBtn = [NSButton buttonWithTitle:@"▼ Move Down" target:self action:@selector(moveDown:)];
    downBtn.frame = NSMakeRect(582, 272, 105, 26);
    downBtn.bezelStyle = NSBezelStyleRounded;
    downBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:downBtn];

    NSButton *remBtn = [NSButton buttonWithTitle:@"Remove Filter" target:self action:@selector(removeStage:)];
    remBtn.frame = NSMakeRect(694, 272, 115, 26);
    remBtn.bezelStyle = NSBezelStyleRounded;
    remBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:remBtn];

    NSButton *clrBtn = [NSButton buttonWithTitle:@"Clear Filters" target:self action:@selector(clearChain:)];
    clrBtn.frame = NSMakeRect(816, 272, 95, 26);
    clrBtn.bezelStyle = NSBezelStyleRounded;
    clrBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:clrBtn];

    // Filter Settings & Expression Inspector
    NSBox *inspectorBox = [[NSBox alloc] initWithFrame:NSMakeRect(480, 108, width - 500, 156)];
    inspectorBox.title = @"Filter Settings & Parameters (Update Selected)";
    inspectorBox.titleFont = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    inspectorBox.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable | NSViewMinXMargin;

    self.inspectorTitle = [NSTextField labelWithString:@"Select a filter in the chain to adjust its parameters."];
    self.inspectorTitle.frame = NSMakeRect(10, 108, 450, 18);
    self.inspectorTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [inspectorBox.contentView addSubview:self.inspectorTitle];

    self.amountSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(amountSliderChanged:)];
    self.amountSlider.frame = NSMakeRect(10, 84, 300, 20);
    self.amountSlider.continuous = YES;
    self.amountSlider.enabled = NO;
    [inspectorBox.contentView addSubview:self.amountSlider];

    self.amountLabel = [NSTextField labelWithString:@""];
    self.amountLabel.frame = NSMakeRect(318, 86, 140, 18);
    self.amountLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [inspectorBox.contentView addSubview:self.amountLabel];

    NSTextField *exprPrompt = [NSTextField labelWithString:@"Filter Expression (edit and update):"];
    exprPrompt.frame = NSMakeRect(10, 56, 240, 16);
    exprPrompt.font = [NSFont systemFontOfSize:11];
    exprPrompt.textColor = NSColor.secondaryLabelColor;
    [inspectorBox.contentView addSubview:exprPrompt];

    self.expressionField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 28, 330, 24)];
    self.expressionField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.expressionField.placeholderString = @"e.g. bass=g=8:f=100 or aecho=0.8:0.9:500:0.3";
    self.expressionField.target = self;
    self.expressionField.action = @selector(updateSelectedStage:);
    [inspectorBox.contentView addSubview:self.expressionField];

    self.updateButton = [NSButton buttonWithTitle:@"Update Filter" target:self action:@selector(updateSelectedStage:)];
    self.updateButton.frame = NSMakeRect(348, 26, 110, 28);
    self.updateButton.bezelStyle = NSBezelStyleRounded;
    self.updateButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [inspectorBox.contentView addSubview:self.updateButton];

    [content addSubview:inspectorBox];

    // Quick Custom Filter Entry
    NSTextField *custPrompt = [NSTextField labelWithString:@"Add Custom FFmpeg Audio Filter:"];
    custPrompt.frame = NSMakeRect(20, 80, 240, 16);
    custPrompt.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    custPrompt.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:custPrompt];

    self.customField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 54, 330, 24)];
    self.customField.placeholderString = @"e.g. pan=stereo|c0=c0-c1|c1=c1-c0 or dynaudnorm";
    self.customField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.customField.target = self;
    self.customField.action = @selector(addCustom:);
    self.customField.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:self.customField];

    NSButton *addCustBtn = [NSButton buttonWithTitle:@"+ Add Custom" target:self action:@selector(addCustom:)];
    addCustBtn.frame = NSMakeRect(356, 52, 104, 28);
    addCustBtn.bezelStyle = NSBezelStyleRounded;
    addCustBtn.autoresizingMask = NSViewMaxYMargin | NSViewMaxXMargin;
    [content addSubview:addCustBtn];

    // BOTTOM BAR: Live Graph, Status, Live Toggle, Bypass, and Apply
    self.graphLabel = [NSTextField wrappingLabelWithString:@""];
    self.graphLabel.frame = NSMakeRect(480, 72, width - 500, 32);
    self.graphLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.graphLabel.textColor = NSColor.secondaryLabelColor;
    self.graphLabel.selectable = YES;
    self.graphLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:self.graphLabel];

    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.frame = NSMakeRect(480, 52, width - 500, 18);
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = NSColor.labelColor;
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:self.statusLabel];

    self.liveUpdateCheckbox = [NSButton checkboxWithTitle:@"Live Audio Update (Auto-Apply)" target:self action:@selector(liveUpdateToggled:)];
    self.liveUpdateCheckbox.frame = NSMakeRect(20, 14, 230, 24);
    self.liveUpdateCheckbox.state = NSControlStateValueOn;
    self.liveUpdateCheckbox.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.liveUpdateCheckbox];

    self.bypassCheckbox = [NSButton checkboxWithTitle:@"Bypass All EQ & Filters (A/B Test)" target:self action:@selector(bypassChanged:)];
    self.bypassCheckbox.frame = NSMakeRect(255, 14, 220, 24);
    self.bypassCheckbox.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.bypassCheckbox];

    NSButton *saveBtn = [NSButton buttonWithTitle:@"Save Preset…" target:self action:@selector(saveChain:)];
    saveBtn.frame = NSMakeRect(480, 12, 105, 28);
    saveBtn.bezelStyle = NSBezelStyleRounded;
    saveBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:saveBtn];

    NSButton *loadBtn = [NSButton buttonWithTitle:@"Load Preset…" target:self action:@selector(loadChain:)];
    loadBtn.frame = NSMakeRect(590, 12, 105, 28);
    loadBtn.bezelStyle = NSBezelStyleRounded;
    loadBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:loadBtn];

    NSButton *applyBtn = [NSButton buttonWithTitle:@"Apply to Playing Audio" target:self action:@selector(apply:)];
    applyBtn.frame = NSMakeRect(706, 10, 254, 32);
    applyBtn.bezelStyle = NSBezelStyleRounded;
    applyBtn.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    applyBtn.keyEquivalent = @"\r";
    applyBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:applyBtn];
}

#pragma mark - Equalizer Actions & Sync

- (void)syncEqualizerControls {
    VPAudioFilters *af = VPAudioFilters.shared;
    self.eqEnableCheckbox.state = af.equalizerEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *preset = af.equalizerPreset ?: @"Flat";
    if ([self.eqPresetPopup itemWithTitle:preset]) {
        [self.eqPresetPopup selectItemWithTitle:preset];
    } else {
        [self.eqPresetPopup selectItemWithTitle:@"Custom"];
    }
    self.eqPreampSlider.doubleValue = af.equalizerPreamp;
    self.eqPreampValueLabel.stringValue = [NSString stringWithFormat:@"%+0.1f dB", af.equalizerPreamp];

    NSArray<NSNumber *> *bands = af.equalizerBands;
    for (NSUInteger i = 0; i < 10 && i < self.eqBandSliders.count; i++) {
        double gain = (i < bands.count) ? [bands[i] doubleValue] : 0.0;
        self.eqBandSliders[i].doubleValue = gain;
        self.eqBandSliders[i].enabled = af.equalizerEnabled;
        self.eqBandValueLabels[i].stringValue = [NSString stringWithFormat:@"%+0.1f", gain];
    }
    self.eqPreampSlider.enabled = af.equalizerEnabled;
}

- (void)eqEnableToggled:(id)sender {
    VPAudioFilters.shared.equalizerEnabled = (self.eqEnableCheckbox.state == NSControlStateValueOn);
    [self syncEqualizerControls];
    self.statusLabel.stringValue = VPAudioFilters.shared.equalizerEnabled ? @"Equalizer enabled." : @"Equalizer disabled.";
    [self commitAndApplyForced:YES];
}

- (void)eqPresetChanged:(id)sender {
    NSString *preset = self.eqPresetPopup.titleOfSelectedItem ?: @"Flat";
    if (![preset isEqualToString:@"Custom"]) {
        [VPAudioFilters.shared applyEqualizerPreset:preset];
        [self syncEqualizerControls];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Applied Equalizer preset: %@", preset];
        [self commitAndApplyForced:YES];
    }
}

- (void)eqResetClicked:(id)sender {
    [VPAudioFilters.shared resetEqualizer];
    [self syncEqualizerControls];
    self.statusLabel.stringValue = @"Equalizer reset to Flat (0 dB).";
    [self commitAndApplyForced:YES];
}

- (void)eqPreampChanged:(NSSlider *)sender {
    double val = sender.doubleValue;
    if (fabs(val) < 0.15) {
        val = 0.0;
        sender.doubleValue = 0.0;
    }
    VPAudioFilters.shared.equalizerPreamp = val;
    self.eqPreampValueLabel.stringValue = [NSString stringWithFormat:@"%+0.1f dB", val];
    [self commitAndApplyForced:NO];
}

- (void)eqBandSliderChanged:(NSSlider *)sender {
    NSUInteger idx = (NSUInteger)sender.tag;
    double val = sender.doubleValue;
    if (fabs(val) < 0.15) {
        val = 0.0;
        sender.doubleValue = 0.0;
    }
    [VPAudioFilters.shared setGain:val forBand:idx];
    if (idx < self.eqBandValueLabels.count) {
        self.eqBandValueLabels[idx].stringValue = [NSString stringWithFormat:@"%+0.1f", val];
    }
    [self.eqPresetPopup selectItemWithTitle:@"Custom"];
    [self commitAndApplyForced:NO];
}

#pragma mark - Model & State

- (void)reload {
    [self.stages removeAllObjects];
    for (NSDictionary *stage in VPAudioFilters.shared.stages) {
        [self.stages addObject:[stage mutableCopy]];
    }
    self.bypassCheckbox.state = VPAudioFilters.shared.enabled ? NSControlStateValueOff : NSControlStateValueOn;
    [self syncEqualizerControls];
    [self.chainTable reloadData];
    [self refreshGraph];
    [self syncInspector];
    if (self.libraryTable.selectedRow < 0 && self.filteredTemplates.count > 0) {
        [self.libraryTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.libraryTable scrollRowToVisible:0];
    }
}

- (void)refreshGraph {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *eq = VPAudioFilters.shared.equalizerGraph;
    if (eq.length > 0) [parts addObject:eq];
    for (NSDictionary *stage in self.stages) {
        NSString *text = [VPAudioFilters filterTextForStage:stage];
        if (text.length) [parts addObject:text];
    }
    NSString *graph = [parts componentsJoinedByString:@","];
    if (graph.length) {
        self.graphLabel.stringValue = [@"FFmpeg: -af " stringByAppendingString:graph];
    } else {
        self.graphLabel.stringValue = @"Equalizer is flat and filter chain is empty — audio is unaffected.";
    }
}

- (void)filterLibrary {
    NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSString *selCategory = self.categoryPopup.titleOfSelectedItem;
    BOOL allCats = [selCategory isEqualToString:@"All"] || !selCategory.length;

    [self.filteredTemplates removeAllObjects];
    for (VPAudioFilterTemplate *t in self.allTemplates) {
        if (!allCats && ![t.category isEqualToString:selCategory]) continue;
        if (query.length > 0) {
            BOOL matchesName = [t.identifier.lowercaseString containsString:query];
            BOOL matchesTitle = [t.title.lowercaseString containsString:query];
            BOOL matchesDetails = [t.details.lowercaseString containsString:query];
            BOOL matchesOpts = [t.optionsSummary.lowercaseString containsString:query];
            if (!matchesName && !matchesTitle && !matchesDetails && !matchesOpts) continue;
        }
        [self.filteredTemplates addObject:t];
    }
    [self.libraryTable reloadData];
    if (self.filteredTemplates.count > 0) {
        [self.libraryTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.libraryTable scrollRowToVisible:0];
    }
    [self syncLibraryInfo];
}

- (void)searchChanged:(id)sender {
    [self filterLibrary];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.searchField) {
        [self filterLibrary];
    }
}

- (void)categoryChanged:(id)sender {
    [self filterLibrary];
}

#pragma mark - Table DataSource & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.libraryTable) return (NSInteger)self.filteredTemplates.count;
    return (NSInteger)self.stages.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *ident = [NSString stringWithFormat:@"%@-%@", tableView == self.libraryTable ? @"lib" : @"chain", tableColumn.identifier];
    NSTextField *label = [tableView makeViewWithIdentifier:ident owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier = ident;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    if (tableView == self.libraryTable) {
        if (row < 0 || row >= (NSInteger)self.filteredTemplates.count) return label;
        VPAudioFilterTemplate *t = self.filteredTemplates[(NSUInteger)row];
        if ([tableColumn.identifier isEqualToString:@"name"]) {
            label.stringValue = [NSString stringWithFormat:@"%@ (%@)", t.title, t.identifier];
            label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
            label.textColor = NSColor.labelColor;
        } else {
            label.stringValue = t.category ?: @"";
            label.font = [NSFont systemFontOfSize:11];
            label.textColor = NSColor.secondaryLabelColor;
        }
    } else {
        if (row < 0 || row >= (NSInteger)self.stages.count) return label;
        NSDictionary *stage = self.stages[(NSUInteger)row];
        if ([tableColumn.identifier isEqualToString:@"idx"]) {
            label.stringValue = [NSString stringWithFormat:@"%ld", (long)(row + 1)];
            label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            label.textColor = NSColor.secondaryLabelColor;
        } else {
            NSString *title = [VPAudioFilters titleForStage:stage];
            NSString *expr = [VPAudioFilters filterTextForStage:stage];
            if ([stage[@"custom"] length]) {
                label.stringValue = expr;
            } else {
                label.stringValue = [NSString stringWithFormat:@"%@  [%@]", title, expr];
            }
            label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
            label.textColor = NSColor.labelColor;
        }
    }
    return label;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.libraryTable) {
        [self syncLibraryInfo];
    } else if (notification.object == self.chainTable) {
        [self syncInspector];
    }
}

- (void)syncLibraryInfo {
    NSInteger row = self.libraryTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.filteredTemplates.count) {
        self.libraryDetail.stringValue = @"Select an FFmpeg audio filter above to view its details.";
        self.libraryOptions.stringValue = @"";
        return;
    }
    VPAudioFilterTemplate *t = self.filteredTemplates[(NSUInteger)row];
    self.libraryDetail.stringValue = [NSString stringWithFormat:@"%@: %@", t.identifier, t.details];
    self.libraryOptions.stringValue = [NSString stringWithFormat:@"Default: %@   |   Options: %@", t.format, t.optionsSummary];
}

- (void)syncInspector {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) {
        self.inspectorTitle.stringValue = @"Select a filter in the chain to adjust and update it.";
        self.amountSlider.enabled = NO;
        self.amountLabel.stringValue = @"";
        self.expressionField.stringValue = @"";
        self.expressionField.enabled = NO;
        self.updateButton.enabled = NO;
        return;
    }

    NSDictionary *stage = self.stages[(NSUInteger)row];
    NSString *expr = [VPAudioFilters filterTextForStage:stage];
    self.expressionField.stringValue = expr ?: @"";
    self.expressionField.enabled = YES;
    self.updateButton.enabled = YES;

    VPAudioFilterTemplate *t = [VPAudioFilters templateWithIdentifier:stage[@"id"] ?: @""];
    if (t && [t.amountName isKindOfClass:[NSString class]] && t.amountName.length > 0 && ![stage[@"custom"] length]) {
        double amount = [stage[@"amount"] respondsToSelector:@selector(doubleValue)] ? [stage[@"amount"] doubleValue] : t.defaultAmount;
        self.inspectorTitle.stringValue = [NSString stringWithFormat:@"%@ — %@ (%@)", t.title, t.amountName, t.details];
        self.amountSlider.minValue = t.minimum;
        self.amountSlider.maxValue = t.maximum;
        self.amountSlider.doubleValue = amount;
        self.amountSlider.enabled = YES;
        self.amountLabel.stringValue = [NSString stringWithFormat:@"%@: %.3g %@", t.amountName, amount, t.unit];
    } else {
        if (t) {
            self.inspectorTitle.stringValue = [NSString stringWithFormat:@"%@ — Edit parameters below (%@)", t.title, t.optionsSummary];
        } else {
            self.inspectorTitle.stringValue = @"Custom Filter Expression — Edit parameters below";
        }
        self.amountSlider.enabled = NO;
        self.amountLabel.stringValue = @"";
    }
}

#pragma mark - Adding, Updating & Removing Filters

- (void)addFromLibrary:(id)sender {
    NSInteger row = self.libraryTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.filteredTemplates.count) return;
    VPAudioFilterTemplate *t = self.filteredTemplates[(NSUInteger)row];
    NSMutableDictionary *stage = [@{@"id": t.identifier} mutableCopy];
    if ([t.amountName isKindOfClass:[NSString class]] && t.amountName.length > 0) {
        stage[@"amount"] = @(t.defaultAmount);
    }
    [self.stages addObject:stage];
    [self.chainTable reloadData];
    NSInteger newIdx = (NSInteger)self.stages.count - 1;
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:newIdx] byExtendingSelection:NO];
    [self.chainTable scrollRowToVisible:newIdx];
    [self syncInspector];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Added '%@' to active chain.", t.title];
    [self commitAndApplyForced:YES];
}

- (void)addCustom:(id)sender {
    NSString *text = [self.customField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    [self.stages addObject:[@{@"custom": text} mutableCopy]];
    self.customField.stringValue = @"";
    [self.chainTable reloadData];
    NSInteger newIdx = (NSInteger)self.stages.count - 1;
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:newIdx] byExtendingSelection:NO];
    [self.chainTable scrollRowToVisible:newIdx];
    [self syncInspector];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Added custom filter '%@'.", text];
    [self commitAndApplyForced:YES];
}

- (void)amountSliderChanged:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) return;
    NSMutableDictionary *stage = self.stages[(NSUInteger)row];
    VPAudioFilterTemplate *t = [VPAudioFilters templateWithIdentifier:stage[@"id"] ?: @""];
    if (!t || ![t.amountName isKindOfClass:[NSString class]] || !t.amountName.length) return;

    double val = self.amountSlider.doubleValue;
    stage[@"amount"] = @(val);
    [stage removeObjectForKey:@"custom"];

    self.amountLabel.stringValue = [NSString stringWithFormat:@"%@: %.3g %@", t.amountName, val, t.unit];
    self.expressionField.stringValue = [VPAudioFilters filterTextForStage:stage];

    [self.chainTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                               columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
    [self commitAndApplyForced:NO];
}

- (void)updateSelectedStage:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) return;
    NSString *expr = [self.expressionField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!expr.length) return;

    NSMutableDictionary *stage = self.stages[(NSUInteger)row];
    stage[@"custom"] = expr;

    [self.chainTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                               columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
    [self syncInspector];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Updated filter #%ld to '%@'.", (long)(row + 1), expr];
    [self commitAndApplyForced:YES];
}

- (void)moveUp:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row <= 0 || row >= (NSInteger)self.stages.count) return;
    [self.stages exchangeObjectAtIndex:(NSUInteger)row withObjectAtIndex:(NSUInteger)(row - 1)];
    [self.chainTable reloadData];
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1] byExtendingSelection:NO];
    [self commitAndApplyForced:YES];
}

- (void)moveDown:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row + 1 >= (NSInteger)self.stages.count) return;
    [self.stages exchangeObjectAtIndex:(NSUInteger)row withObjectAtIndex:(NSUInteger)(row + 1)];
    [self.chainTable reloadData];
    [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
    [self commitAndApplyForced:YES];
}

- (void)removeStage:(id)sender {
    NSInteger row = self.chainTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.stages.count) return;
    [self.stages removeObjectAtIndex:(NSUInteger)row];
    [self.chainTable reloadData];
    NSInteger nextRow = MIN(row, (NSInteger)self.stages.count - 1);
    if (nextRow >= 0) {
        [self.chainTable selectRowIndexes:[NSIndexSet indexSetWithIndex:nextRow] byExtendingSelection:NO];
    }
    [self syncInspector];
    self.statusLabel.stringValue = @"Filter removed.";
    [self commitAndApplyForced:YES];
}

- (void)clearChain:(id)sender {
    if (!self.stages.count) return;
    [self.stages removeAllObjects];
    [self.chainTable reloadData];
    [self syncInspector];
    self.statusLabel.stringValue = @"All chain filters cleared.";
    [self commitAndApplyForced:YES];
}

#pragma mark - Apply to Live Audio

- (void)commitAndApplyForced:(BOOL)forced {
    VPAudioFilters.shared.stages = [self.stages copy];
    VPAudioFilters.shared.enabled = (self.bypassCheckbox.state != NSControlStateValueOn);
    [VPAudioFilters.shared changed];
    [self refreshGraph];

    if (forced || self.liveUpdateCheckbox.state == NSControlStateValueOn) {
        [self scheduleLiveApply];
    }
}

- (void)scheduleLiveApply {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(executeLiveApply) object:nil];
    [self performSelector:@selector(executeLiveApply) withObject:nil afterDelay:0.04];
}

- (void)executeLiveApply {
    if (self.applyHandler) {
        self.applyHandler();
    }
    NSString *graph = VPAudioFilters.shared.graph;
    if (VPAudioFilters.shared.isActive) {
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Live Audio Active: -af \"%@\"", graph];
    } else {
        self.statusLabel.stringValue = (self.bypassCheckbox.state == NSControlStateValueOn) ?
            @"Equalizer & filters bypassed on live audio (A/B testing mode)." :
            @"Equalizer is flat and live audio filter chain is empty.";
    }
}

- (void)apply:(id)sender {
    [self commitAndApplyForced:YES];
}

- (void)liveUpdateToggled:(id)sender {
    if (self.liveUpdateCheckbox.state == NSControlStateValueOn) {
        [self commitAndApplyForced:YES];
    }
}

- (void)bypassChanged:(id)sender {
    [self commitAndApplyForced:YES];
}

#pragma mark - Save & Load

- (void)saveChain:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"audio-eq-filters.json";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSDictionary *payload = [VPAudioFilters.shared dictionaryRepresentation];
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:nil];
        NSError *error = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            self.statusLabel.stringValue = error.localizedDescription;
        } else {
            self.statusLabel.stringValue = [@"Saved EQ & filter preset to " stringByAppendingString:panel.URL.lastPathComponent];
        }
    }];
}

- (void)loadChain:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        id json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:panel.URL] options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)json;
            if (dict[@"stages"] || dict[@"equalizerBands"]) {
                [VPAudioFilters.shared loadFromDictionary:dict];
                [self reload];
                self.statusLabel.stringValue = [@"Loaded EQ & filter preset from " stringByAppendingString:panel.URL.lastPathComponent];
                [self commitAndApplyForced:YES];
                return;
            }
        }
        NSArray *array = [json isKindOfClass:NSDictionary.class] ? json[@"audioFilters"] : json;
        if (![array isKindOfClass:NSArray.class]) {
            self.statusLabel.stringValue = @"Selected file does not contain a valid audio filter preset.";
            return;
        }
        [self.stages removeAllObjects];
        for (NSDictionary *stage in array) {
            if ([stage isKindOfClass:NSDictionary.class]) {
                [self.stages addObject:[stage mutableCopy]];
            }
        }
        [self.chainTable reloadData];
        [self refreshGraph];
        [self syncInspector];
        self.statusLabel.stringValue = [@"Loaded filter chain from " stringByAppendingString:panel.URL.lastPathComponent];
        [self commitAndApplyForced:YES];
    }];
}

@end
