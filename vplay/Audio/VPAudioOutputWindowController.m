#import "VPAudioOutputWindowController.h"
#import "VPAudioDeviceManager.h"
#import "VPAudioChannelLayout.h"
#import <math.h>

@interface VPAudioOutputWindowController () <NSWindowDelegate>
@property (nonatomic, strong) NSPopUpButton *devices;
@property (nonatomic, strong) NSPopUpButton *rates;
@property (nonatomic, strong) NSPopUpButton *layouts;
@property (nonatomic, strong) NSTextField *info;
@property (nonatomic, strong) NSButton *speakerTestButton;
@property (nonatomic) AudioQueueRef speakerTestQueue;
@property (nonatomic, strong) NSTimer *speakerTestTimer;
- (void)stopSpeakerTest;
@property (nonatomic, copy) NSArray<NSDictionary *> *outputDevices;
@end

static void SpeakerTestFinished(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    // The queue may release its buffer before the device finishes playing it.
    // The UI timer allows the full tone sequence and hardware tail to finish.
}

@implementation VPAudioOutputWindowController

- (void)dealloc {
    if (_speakerTestQueue) AudioQueueDispose(_speakerTestQueue, true);
}

- (void)windowWillClose:(NSNotification *)notification { [self stopSpeakerTest]; }

- (void)stopSpeakerTest {
    [self.speakerTestTimer invalidate];
    self.speakerTestTimer = nil;
    AudioQueueRef queue = self.speakerTestQueue;
    self.speakerTestQueue = NULL;
    if (queue) AudioQueueDispose(queue, true);
    self.speakerTestButton.title = @"Test Speakers";
}

- (void)testSpeakers:(id)sender {
    if (self.speakerTestQueue) { [self stopSpeakerTest]; return; }
    NSString *uid = [self selectedDeviceUID] ?: [VPAudioDeviceManager defaultOutputDeviceUID];
    NSUInteger capacity = [VPAudioDeviceManager outputChannelCountForDeviceUID:uid];
    NSString *name = LayoutChoices()[self.layouts.indexOfSelectedItem][1];
    if ([name isEqual:@"auto"]) name = capacity >= 8 ? @"7.1" : capacity >= 6 ? @"5.1" : @"stereo";
    if ([name isEqual:@"4.0"]) name = @"quad";
    AVChannelLayout layout = {0};
    if (av_channel_layout_from_string(&layout, name.UTF8String) < 0) return;
    if (!capacity || layout.nb_channels > capacity) {
        self.info.stringValue = @"The selected output does not expose enough PCM channels for this layout. Check the connection and Configure Speakers in Audio MIDI Setup.";
        av_channel_layout_uninit(&layout);
        return;
    }
    const int rate = 48000, slot = 33600, tone = 24000;
    int channels = layout.nb_channels;
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mBytesPerPacket = channels * sizeof(float);
    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewOutput(&format, SpeakerTestFinished, (__bridge void *)self, NULL, NULL, 0, &queue);
    if (status == noErr && uid.length) {
        CFStringRef device = (__bridge CFStringRef)uid;
        status = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &device, sizeof(device));
    }
    if (status == noErr) status = VPSetAudioQueueChannelLayout(queue, &layout);
    AudioQueueBufferRef buffer = NULL;
    UInt32 bytes = (UInt32)(slot * channels * channels * sizeof(float));
    if (status == noErr) status = AudioQueueAllocateBuffer(queue, bytes, &buffer);
    if (status == noErr) {
        float *samples = buffer->mAudioData;
        memset(samples, 0, bytes);
        for (int c = 0; c < channels; c++) {
            double frequency = av_channel_layout_channel_from_index(&layout, c) == AV_CHAN_LOW_FREQUENCY ? 60 : 440;
            for (int i = 0; i < tone; i++) {
                double ramp = fmin(1.0, fmin(i / 480.0, (tone - 1 - i) / 480.0));
                samples[(c * slot + i) * channels + c] = 0.03f * ramp * sin(2 * M_PI * frequency * i / rate);
            }
        }
        buffer->mAudioDataByteSize = bytes;
        status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
    if (status == noErr) {
        self.speakerTestQueue = queue;
        status = AudioQueueStart(queue, NULL);
    }
    if (status != noErr) {
        if (queue) AudioQueueDispose(queue, true);
        self.speakerTestQueue = NULL;
        self.info.stringValue = [NSString stringWithFormat:@"Speaker test could not open this output (Core Audio %d).", (int)status];
    } else {
        self.speakerTestButton.title = @"Stop Speaker Test";
        __weak typeof(self) weakSelf = self;
        self.speakerTestTimer = [NSTimer scheduledTimerWithTimeInterval:(double)slot * channels / rate + 0.5 repeats:NO block:^(NSTimer *timer) {
            [weakSelf stopSpeakerTest];
        }];
        self.info.stringValue = channels == 8 ? @"Quiet tones: front left, front right, center, subwoofer, back left, back right, side left, side right. If a speaker is missing or misplaced, configure it in Audio MIDI Setup." :
            channels == 6 ? @"Quiet tones: front left, front right, center, subwoofer, surround left, surround right. If a speaker is missing or misplaced, configure it in Audio MIDI Setup." :
            @"Playing a quiet tone through each channel in speaker order. Check speaker assignments in Audio MIDI Setup.";
    }
    av_channel_layout_uninit(&layout);
}

static NSArray<NSArray *> *RateChoices(void) {
    return @[@[@"Auto — leave the device as it is", @"auto"], @[@"44.1 kHz  (CD)", @"44100"], @[@"48 kHz  (video)", @"48000"], @[@"88.2 kHz", @"88200"], @[@"96 kHz", @"96000"],
             @[@"176.4 kHz", @"176400"], @[@"192 kHz", @"192000"], @[@"352.8 kHz", @"352800"], @[@"384 kHz", @"384000"], @[@"Maximum the device supports", @"max"]];
}
static NSArray<NSArray *> *LayoutChoices(void) {
    return @[@[@"Auto — as recorded", @"auto"], @[@"Mono (1.0)", @"mono"], @[@"Stereo (2.0)", @"stereo"], @[@"2.1  (stereo + subwoofer)", @"2.1"], @[@"4.0  (quad)", @"4.0"],
             @[@"4.1  (fronts, center, rear center + subwoofer)", @"4.1"], @[@"5.0  (surround, no subwoofer)", @"5.0"], @[@"5.1  (surround + subwoofer)", @"5.1"], @[@"7.1  (full surround)", @"7.1"]];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 430) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Audio Output";
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) { window.delegate = self; [self buildUI]; [window center]; }
    return self;
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame; field.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [self.window.contentView addSubview:field];
    return field;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    NSTextField *intro = [NSTextField wrappingLabelWithString:@"Upsample the sound to a higher sample rate and choose how many speakers vplay should feed. Changes apply to the next sound and, for channel layouts, restart the playing media at the same position."];
    intro.frame = NSMakeRect(20, 366, 520, 50); intro.textColor = NSColor.secondaryLabelColor; intro.font = [NSFont systemFontOfSize:12];
    [content addSubview:intro];

    [self label:@"Output device" frame:NSMakeRect(20, 334, 160, 20)];
    self.devices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 328, 350, 28) pullsDown:NO];
    self.devices.target = self; self.devices.action = @selector(deviceChanged:);
    [content addSubview:self.devices];

    [self label:@"Sample rate" frame:NSMakeRect(20, 290, 160, 20)];
    self.rates = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 284, 350, 28) pullsDown:NO];
    for (NSArray *choice in RateChoices()) [self.rates addItemWithTitle:choice[0]];
    [content addSubview:self.rates];

    [self label:@"Speakers (channels)" frame:NSMakeRect(20, 246, 160, 20)];
    self.layouts = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 240, 350, 28) pullsDown:NO];
    for (NSArray *choice in LayoutChoices()) [self.layouts addItemWithTitle:choice[0]];
    [content addSubview:self.layouts];

    self.info = [NSTextField wrappingLabelWithString:@""];
    self.info.frame = NSMakeRect(20, 112, 520, 112); self.info.font = [NSFont systemFontOfSize:12]; self.info.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.info];

    self.speakerTestButton = [NSButton buttonWithTitle:@"Test Speakers" target:self action:@selector(testSpeakers:)];
    self.speakerTestButton.frame = NSMakeRect(20, 70, 180, 32);
    [content addSubview:self.speakerTestButton];

    NSButton *revert = [NSButton buttonWithTitle:@"Revert" target:self action:@selector(revert:)];
    revert.frame = NSMakeRect(20, 20, 90, 32); [content addSubview:revert];
    NSButton *apply = [NSButton buttonWithTitle:@"Apply" target:self action:@selector(apply:)];
    apply.frame = NSMakeRect(440, 20, 100, 32); apply.keyEquivalent = @"\r"; [content addSubview:apply];
}

- (void)reload {
    NSMutableArray *outputs = [NSMutableArray array];
    for (NSDictionary *device in [VPAudioDeviceManager listDevices]) if ([device[@"type"] isEqual:@"output"]) [outputs addObject:device];
    self.outputDevices = outputs;
    [self.devices removeAllItems];
    [self.devices addItemWithTitle:@"System default output"];
    for (NSDictionary *device in outputs) [self.devices addItemWithTitle:device[@"name"]];
    NSDictionary *current = self.currentSettings ? self.currentSettings() : @{};
    NSString *uid = current[@"audioDevice"];
    for (NSUInteger i = 0; i < outputs.count; i++) if ([outputs[i][@"uid"] isEqual:uid]) [self.devices selectItemAtIndex:i + 1];
    for (NSUInteger i = 0; i < RateChoices().count; i++) if ([RateChoices()[i][1] isEqual:current[@"audioSampleRate"] ?: @"auto"]) [self.rates selectItemAtIndex:i];
    NSString *layout = current[@"audioLayout"] ?: @"auto";
    if ([layout isEqual:@"2.0"]) layout = @"stereo";
    for (NSUInteger i = 0; i < LayoutChoices().count; i++) if ([LayoutChoices()[i][1] isEqual:layout]) [self.layouts selectItemAtIndex:i];
    [self refreshDeviceInfo];
}

- (NSString *)selectedDeviceUID {
    NSInteger index = self.devices.indexOfSelectedItem;
    return index > 0 ? self.outputDevices[index - 1][@"uid"] : nil;
}

- (void)refreshDeviceInfo {
    NSString *uid = [self selectedDeviceUID];
    NSArray<NSNumber *> *supported = [VPAudioDeviceManager supportedSampleRatesForDeviceUID:uid];
    double maximum = [VPAudioDeviceManager maximumSampleRateForDeviceUID:uid];
    for (NSUInteger i = 0; i < RateChoices().count; i++) {
        NSString *value = RateChoices()[i][1];
        BOOL ok = [value isEqual:@"auto"] || [value isEqual:@"max"] || [supported containsObject:@(value.integerValue)];
        NSMenuItem *item = [self.rates itemAtIndex:i];
        item.enabled = ok;
        item.title = ok ? RateChoices()[i][0] : [RateChoices()[i][0] stringByAppendingString:@" — not supported by this device"];
    }
    NSUInteger channels = [VPAudioDeviceManager outputChannelCountForDeviceUID:uid];
    NSMutableString *text = [NSMutableString stringWithFormat:@"Output exposes %lu PCM channels. 5.1 needs six; 7.1 needs eight. ", (unsigned long)channels];
    if (maximum > 0) [text appendFormat:@"This device runs at up to %.1f kHz. ", maximum / 1000];
    [text appendString:@"Resampling changes the output rate, not the detail in the recording.\n\n"];
    [text appendString:@"Use Test Speakers to check routing. Configure speaker positions in Audio MIDI Setup. AC-3/DTS file export does not enable live encoded output; playback sends PCM."];
    self.info.stringValue = text;
}

- (void)deviceChanged:(id)sender { [self stopSpeakerTest]; [self refreshDeviceInfo]; }

- (void)apply:(id)sender {
    [self stopSpeakerTest];
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    settings[@"audioSampleRate"] = RateChoices()[self.rates.indexOfSelectedItem][1];
    settings[@"audioLayout"] = LayoutChoices()[self.layouts.indexOfSelectedItem][1];
    NSString *uid = [self selectedDeviceUID];
    settings[@"audioDevice"] = uid ?: @"";
    if (self.applyHandler) self.applyHandler(settings);
}

- (void)revert:(id)sender { [self reload]; }
@end
