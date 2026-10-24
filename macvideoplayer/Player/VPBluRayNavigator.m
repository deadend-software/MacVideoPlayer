//
//  VPBluRayNavigator.m
//  macvideoplayer
//

#import "VPBluRayNavigator.h"

static const NSUInteger kVPInstructionSize = 12;
static const NSUInteger kVPMaxStepsPerRun = 200000;      // a navigation loop that never plays anything stops here
static const NSUInteger kVPMaxIGBytes = 256u << 20;      // how much of a menu clip is searched for its IG stream
static const NSInteger kVPNoButton = -1;

static inline uint16_t VPBE16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline uint32_t VPBE32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

#pragma mark - Bounds-checked reader

/// Reads big-endian fields and records overruns instead of crashing on a damaged or truncated file.
typedef struct {
    const uint8_t *bytes;
    NSUInteger length, position;
    BOOL overrun;
} VPReader;

static uint32_t VPRead(VPReader *r, NSUInteger count) {
    if (r->position + count > r->length) { r->overrun = YES; r->position = r->length; return 0; }
    uint32_t value = 0;
    for (NSUInteger i = 0; i < count; i++) value = (value << 8) | r->bytes[r->position + i];
    r->position += count;
    return value;
}

static void VPSkip(VPReader *r, NSUInteger count) {
    if (r->position + count > r->length) { r->overrun = YES; r->position = r->length; return; }
    r->position += count;
}

#pragma mark - Model classes

@implementation VPBluRayButton
@end

@implementation VPBluRayMenuPage
- (VPBluRayButton *)buttonWithID:(NSInteger)buttonID {
    for (VPBluRayButton *button in self.buttons) if (button.buttonID == buttonID) return button;
    return nil;
}
@end

@implementation VPBluRayPlaylist
@end

#pragma mark - Interactive graphics (IG) decoding

/// Joins the PES payloads of one PID from an m2ts file until the first display set (ICS … END) is complete.
/// m2ts source packets are 192 bytes: a 4-byte timestamp header and a 188-byte transport packet.
static NSData *VPReadIGStream(NSURL *clip, uint16_t pid) {
    NSData *file = [NSData dataWithContentsOfURL:clip options:NSDataReadingMappedIfSafe error:nil];
    if (file.length < 192) return nil;
    const uint8_t *bytes = file.bytes;
    NSUInteger limit = MIN(file.length, kVPMaxIGBytes);

    NSMutableData *stream = [NSMutableData data];
    NSMutableData *pes = nil;
    NSUInteger parsed = 0;
    BOOL sawComposition = NO;

    for (NSUInteger offset = 0; offset + 192 <= limit; offset += 192) {
        const uint8_t *packet = bytes + offset + 4;
        if (packet[0] != 0x47) break;
        if ((uint16_t)(((packet[1] & 0x1F) << 8) | packet[2]) != pid) continue;
        NSUInteger payloadStart = 4;
        uint8_t adaptation = (packet[3] >> 4) & 3;
        if (adaptation & 2) payloadStart += 1 + packet[4];
        if (!(adaptation & 1) || payloadStart >= 188) continue;
        const uint8_t *payload = packet + payloadStart;
        NSUInteger payloadLength = 188 - payloadStart;

        if (packet[1] & 0x40) {       // a new PES packet begins: finish the previous one
            if (pes) {
                [stream appendData:pes];
                // Stop as soon as a complete first display set has arrived.
                while (parsed + 3 <= stream.length) {
                    const uint8_t *s = (const uint8_t *)stream.bytes + parsed;
                    NSUInteger segmentLength = VPBE16(s + 1);
                    if (parsed + 3 + segmentLength > stream.length) break;
                    if (s[0] == 0x18) sawComposition = YES;
                    if (s[0] == 0x80 && sawComposition) return stream;
                    parsed += 3 + segmentLength;
                }
            }
            pes = nil;
            if (payloadLength < 9 || payload[0] || payload[1] || payload[2] != 1) continue;
            NSUInteger headerEnd = 9 + payload[8];
            if (headerEnd > payloadLength) continue;
            pes = [NSMutableData dataWithBytes:payload + headerEnd length:payloadLength - headerEnd];
        } else if (pes) {
            [pes appendBytes:payload length:payloadLength];
        }
    }
    if (pes) [stream appendData:pes];
    return stream.length ? stream : nil;
}

/// Expands the run-length encoding used by IG and PG bitmaps into one palette index per pixel.
static NSData *VPDecodeRLE(NSData *encoded, NSUInteger width, NSUInteger height) {
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
    uint8_t *out = pixels.mutableBytes;
    const uint8_t *in = encoded.bytes;
    NSUInteger length = encoded.length, i = 0, x = 0, y = 0;
    while (i < length && y < height) {
        uint8_t code = in[i++];
        NSUInteger run = 1;
        uint8_t color = code;
        if (code == 0) {
            if (i >= length) break;
            uint8_t flags = in[i++];
            if (flags == 0) { x = 0; y++; continue; }              // end of line
            if (flags < 0x40) { run = flags; color = 0; }
            else if (flags < 0x80) { if (i >= length) break; run = ((flags & 0x3F) << 8) | in[i++]; color = 0; }
            else if (flags < 0xC0) { if (i >= length) break; run = flags & 0x3F; color = in[i++]; }
            else { if (i + 1 >= length) break; run = ((flags & 0x3F) << 8) | in[i]; color = in[i + 1]; i += 2; }
        }
        for (NSUInteger k = 0; k < run && x < width; k++) out[y * width + x++] = color;
    }
    return pixels;
}

/// Draws palette-indexed pixels as a premultiplied RGBA image. IG palettes are YCrCb: BT.709 for HD, BT.601 for SD.
static NSImage *VPImageFromIndexedPixels(NSData *pixels, NSUInteger width, NSUInteger height, uint8_t (*palette)[4], BOOL hd) {
    if (!width || !height || pixels.length < width * height) return nil;
    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *out = rgba.mutableBytes;
    const uint8_t *in = pixels.bytes;
    for (NSUInteger i = 0; i < width * height; i++) {
        const uint8_t *entry = palette[in[i]];       // Y, Cr, Cb, alpha
        double alpha = entry[3] / 255.0;
        if (alpha <= 0) continue;
        double y = (entry[0] - 16) * 1.164, cr = entry[1] - 128.0, cb = entry[2] - 128.0;
        double r = hd ? y + 1.793 * cr : y + 1.596 * cr;
        double g = hd ? y - 0.213 * cb - 0.533 * cr : y - 0.391 * cb - 0.813 * cr;
        double b = hd ? y + 2.112 * cb : y + 2.018 * cb;
        out[i * 4 + 0] = (uint8_t)(MAX(0, MIN(255, r)) * alpha + 0.5);
        out[i * 4 + 1] = (uint8_t)(MAX(0, MIN(255, g)) * alpha + 0.5);
        out[i * 4 + 2] = (uint8_t)(MAX(0, MIN(255, b)) * alpha + 0.5);
        out[i * 4 + 3] = (uint8_t)(entry[3]);
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba.mutableBytes, width, height, 8, width * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef cgImage = context ? CGBitmapContextCreateImage(context) : NULL;
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
    if (!cgImage) return nil;
    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(width, height)];
    CGImageRelease(cgImage);
    return image;
}

/// Skips one effect sequence (windows, then effects with their composition objects) of an IG page.
static void VPSkipEffectSequence(VPReader *r) {
    uint32_t windows = VPRead(r, 1), effects = VPRead(r, 1);
    VPSkip(r, 9 * windows);
    for (uint32_t e = 0; e < effects && !r->overrun; e++) {
        VPSkip(r, 4);                                     // duration (3) + palette reference (1)
        uint32_t objects = VPRead(r, 1);
        for (uint32_t o = 0; o < objects && !r->overrun; o++) {
            VPSkip(r, 3);                                 // object and window references
            uint32_t flags = VPRead(r, 1);
            VPSkip(r, 4 + ((flags & 0x80) ? 8 : 0));      // position, plus the crop rectangle when cropped
        }
    }
}

/// Decodes the first IG display set of `clip` into the menu's first page. `commands` receives the HDMV command
/// list of every button, keyed by button ID.
static VPBluRayMenuPage *VPDecodeMenuPage(NSURL *clip, uint16_t pid, NSDictionary<NSNumber *, NSData *> **commands) {
    NSData *stream = VPReadIGStream(clip, pid);
    if (!stream) return nil;

    // Split the stream into segments: ICS (0x18), PDS (0x14), ODS (0x15), END (0x80).
    NSMutableData *composition = nil;
    NSMutableDictionary<NSNumber *, NSData *> *palettes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableData *> *objectData = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSValue *> *objectSizes = [NSMutableDictionary dictionary];
    NSUInteger videoHeight = 1080, videoWidth = 1920;
    const uint8_t *bytes = stream.bytes;
    NSUInteger position = 0;
    while (position + 3 <= stream.length) {
        uint8_t type = bytes[position];
        NSUInteger length = VPBE16(bytes + position + 1);
        if (position + 3 + length > stream.length) break;
        const uint8_t *body = bytes + position + 3;
        position += 3 + length;
        if (type == 0x18 && length >= 12) {
            uint8_t sequence = body[8];
            if (!composition) {
                videoWidth = VPBE16(body); videoHeight = VPBE16(body + 2);
                composition = [NSMutableData dataWithBytes:body + 12 length:length - 12];
            } else if (!(sequence & 0x80)) {
                [composition appendBytes:body + 9 length:length - 9];   // later fragment of the same composition
            }
        } else if (type == 0x14 && length >= 2) {
            palettes[@(body[0])] = [NSData dataWithBytes:body + 2 length:length - 2];
        } else if (type == 0x15 && length >= 4) {
            NSNumber *objectID = @(VPBE16(body));
            if (body[3] & 0x80) {                                       // first fragment: size, then the first bitmap data
                if (length < 11) continue;
                objectSizes[objectID] = [NSValue valueWithSize:NSMakeSize(VPBE16(body + 7), VPBE16(body + 9))];
                objectData[objectID] = [NSMutableData dataWithBytes:body + 11 length:length - 11];
            } else {
                [objectData[objectID] appendBytes:body + 4 length:length - 4];
            }
        } else if (type == 0x80 && composition) {
            break;
        }
    }
    if (!composition) return nil;

    VPReader r = { composition.bytes, composition.length, 0, NO };
    uint32_t modelFlags = VPRead(&r, 1);
    if (!(modelFlags & 0x80)) VPSkip(&r, 10);        // multiplexed streams carry two 5-byte time-outs
    VPSkip(&r, 3);                                    // user time-out duration
    uint32_t pageCount = VPRead(&r, 1);
    if (!pageCount) return nil;

    VPBluRayMenuPage *page = [VPBluRayMenuPage new];
    page.videoSize = NSMakeSize(videoWidth, videoHeight);
    page.defaultButtonID = kVPNoButton;
    NSMutableArray<VPBluRayButton *> *buttons = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSData *> *buttonCommands = [NSMutableDictionary dictionary];
    // Per button: the first object of its normal, selected and activated states.
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *stateObjects = [NSMutableDictionary dictionary];
    uint32_t paletteID = 0;

    // Only the first page is shown; later pages are skipped by the early return below.
    VPSkip(&r, 2);                                    // page ID, version
    VPSkip(&r, 8);                                    // user-operation mask
    VPSkipEffectSequence(&r);                         // in-effects
    VPSkipEffectSequence(&r);                         // out-effects
    VPSkip(&r, 1);                                    // animation frame rate
    uint32_t defaultSelected = VPRead(&r, 2);
    VPSkip(&r, 2);                                    // default activated button
    paletteID = VPRead(&r, 1);
    uint32_t groups = VPRead(&r, 1);
    for (uint32_t g = 0; g < groups && !r.overrun; g++) {
        uint32_t groupDefault = VPRead(&r, 2);
        uint32_t count = VPRead(&r, 1);
        if (page.defaultButtonID < 0 && groupDefault != 0xFFFF) page.defaultButtonID = groupDefault;
        for (uint32_t b = 0; b < count && !r.overrun; b++) {
            VPBluRayButton *button = [VPBluRayButton new];
            button.buttonID = VPRead(&r, 2);
            button.numericValue = VPRead(&r, 2);
            VPSkip(&r, 1);                            // auto-action flag
            double x = VPRead(&r, 2), y = VPRead(&r, 2);
            uint32_t up = VPRead(&r, 2), down = VPRead(&r, 2), left = VPRead(&r, 2), right = VPRead(&r, 2);
            button.upID = up == 0xFFFF ? kVPNoButton : up;
            button.downID = down == 0xFFFF ? kVPNoButton : down;
            button.leftID = left == 0xFFFF ? kVPNoButton : left;
            button.rightID = right == 0xFFFF ? kVPNoButton : right;
            uint32_t normal = VPRead(&r, 2); VPSkip(&r, 3);                 // start object, end object, flags
            VPSkip(&r, 1);                                                   // selected-state sound
            uint32_t selected = VPRead(&r, 2); VPSkip(&r, 3);
            VPSkip(&r, 1);                                                   // activated-state sound
            uint32_t activated = VPRead(&r, 2); VPSkip(&r, 2);
            uint32_t commandCount = VPRead(&r, 2);
            if (r.overrun || r.position + commandCount * kVPInstructionSize > r.length) { r.overrun = YES; break; }
            buttonCommands[@(button.buttonID)] = [NSData dataWithBytes:r.bytes + r.position length:commandCount * kVPInstructionSize];
            VPSkip(&r, commandCount * kVPInstructionSize);
            button.frame = NSMakeRect(x, y, 0, 0);
            stateObjects[@(button.buttonID)] = @[@(normal), @(selected), @(activated)];
            [buttons addObject:button];
        }
    }
    if (r.overrun || !buttons.count) return nil;
    if (page.defaultButtonID < 0 && defaultSelected != 0xFFFF) page.defaultButtonID = defaultSelected;
    if (page.defaultButtonID < 0) page.defaultButtonID = buttons.firstObject.buttonID;

    // Palette: entries are index, Y, Cr, Cb, alpha. Unlisted indexes stay transparent.
    NSMutableData *paletteStorage = [NSMutableData dataWithLength:256 * 4];
    uint8_t (*palette)[4] = paletteStorage.mutableBytes;
    NSData *entries = palettes[@(paletteID)] ?: palettes.allValues.firstObject;
    for (NSUInteger i = 0; i + 5 <= entries.length; i += 5) {
        const uint8_t *e = (const uint8_t *)entries.bytes + i;
        palette[e[0]][0] = e[1]; palette[e[0]][1] = e[2]; palette[e[0]][2] = e[3]; palette[e[0]][3] = e[4];
    }

    NSMutableDictionary<NSNumber *, NSImage *> *images = [NSMutableDictionary dictionary];
    NSImage *(^imageForObject)(NSNumber *) = ^NSImage *(NSNumber *objectID) {
        if (objectID.unsignedIntValue == 0xFFFF) return nil;
        NSImage *cached = images[objectID];
        if (cached) return cached;
        NSMutableData *encoded = objectData[objectID];
        NSValue *size = objectSizes[objectID];
        if (!encoded || !size) return nil;
        NSUInteger w = (NSUInteger)size.sizeValue.width, h = (NSUInteger)size.sizeValue.height;
        NSImage *image = VPImageFromIndexedPixels(VPDecodeRLE(encoded, w, h), w, h, palette, videoHeight >= 720);
        if (image) images[objectID] = image;
        return image;
    };

    for (VPBluRayButton *button in buttons) {
        NSArray<NSNumber *> *objects = stateObjects[@(button.buttonID)];
        button.normalImage = imageForObject(objects[0]);
        button.selectedImage = imageForObject(objects[1]);
        button.activatedImage = imageForObject(objects[2]);
        // The clickable area covers the largest of the three pictures.
        NSSize size = NSZeroSize;
        NSImage *pictures[3] = { button.normalImage, button.selectedImage, button.activatedImage };
        for (int i = 0; i < 3; i++) {
            size.width = MAX(size.width, pictures[i].size.width);
            size.height = MAX(size.height, pictures[i].size.height);
        }
        button.frame = NSMakeRect(button.frame.origin.x, button.frame.origin.y, size.width, size.height);
    }
    page.buttons = buttons;
    if (commands) *commands = buttonCommands;
    return page;
}

#pragma mark - HDMV instructions

/// One 12-byte index.bdmv entry: the movie object it runs, or -1 for a Java (BD-J) title.
static NSInteger VPReadIndexEntry(VPReader *r) {
    uint32_t type = VPRead(r, 1) >> 6;                 // 1 = HDMV movie object, 2 = BD-J
    VPSkip(r, 3);
    VPSkip(r, 2);                                      // playback type
    uint32_t reference = VPRead(r, 2);
    VPSkip(r, 4);
    return type == 1 ? (NSInteger)reference : -1;
}

typedef struct {
    uint8_t operandCount, group, subGroup;
    BOOL dstImmediate, srcImmediate;
    uint8_t branchOption, compareOption, setOption;
    uint32_t dst, src;
} VPHDMVInstruction;

static VPHDMVInstruction VPDecodeInstruction(const uint8_t *p) {
    VPHDMVInstruction in;
    in.operandCount = (p[0] >> 5) & 7;
    in.group = (p[0] >> 3) & 3;
    in.subGroup = p[0] & 7;
    in.dstImmediate = (p[1] >> 7) & 1;
    in.srcImmediate = (p[1] >> 6) & 1;
    in.branchOption = p[1] & 0x0F;
    in.compareOption = p[2] & 0x0F;
    in.setOption = p[3] & 0x0F;
    in.dst = VPBE32(p + 4);
    in.src = VPBE32(p + 8);
    return in;
}

typedef NS_ENUM(NSInteger, VPBluRayState) {
    VPBluRayStateIdle,
    VPBluRayStatePlaying,
    VPBluRayStateMenu
};

@interface VPBluRayNavigator () {
    NSMutableArray<NSData *> *_objects;                 // movie objects: 12-byte instructions
    NSInteger _firstPlaybackObject, _topMenuObject;     // -1 when the entry is a Java (BD-J) title
    NSArray<NSNumber *> *_titleObjects;
    uint32_t _gpr[4096];
    uint32_t _psr[128];
    NSData *_commands;                                  // the list being run: a movie object or a button's commands
    NSUInteger _pc;
    NSData *_menuCommands;                              // the list suspended while a button's commands run
    NSUInteger _menuPC;
    BOOL _inButton;
    NSData *_returnCommands;                            // CALL_* return point for RESUME
    NSUInteger _returnPC;
    VPBluRayState _state;
    BOOL _running;
    NSMutableDictionary<NSString *, VPBluRayPlaylist *> *_playlists;
    NSMutableDictionary<NSString *, NSNumber *> *_graphicsPIDs;
    NSDictionary<NSNumber *, NSData *> *_buttonCommands;
    NSInteger _requestedButton;
    BOOL _returnToMenuAfterPlayback;                    // set when the viewer picked a title from the bar
    NSUInteger _loadToken;                              // identifies the playlist load in flight; any navigation change voids it
}
@property (nonatomic, strong, readwrite) NSURL *discRoot;
@property (nonatomic, strong) NSURL *bdmvURL;
@end

@implementation VPBluRayNavigator

+ (nullable instancetype)navigatorForDiscRoot:(NSURL *)discRoot {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *bdmv = [discRoot.lastPathComponent.uppercaseString isEqualToString:@"BDMV"] ? discRoot : [discRoot URLByAppendingPathComponent:@"BDMV"];
    if (![fm fileExistsAtPath:[bdmv URLByAppendingPathComponent:@"index.bdmv"].path] ||
        ![fm fileExistsAtPath:[bdmv URLByAppendingPathComponent:@"MovieObject.bdmv"].path]) return nil;
    VPBluRayNavigator *navigator = [[self alloc] init];
    navigator.bdmvURL = bdmv;
    navigator.discRoot = [bdmv.lastPathComponent.uppercaseString isEqualToString:@"BDMV"] ? bdmv.URLByDeletingLastPathComponent : bdmv;
    return [navigator loadNavigationData] ? navigator : nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _playlists = [NSMutableDictionary dictionary];
        _graphicsPIDs = [NSMutableDictionary dictionary];
        _requestedButton = kVPNoButton;
    }
    return self;
}

#pragma mark - Loading index.bdmv and MovieObject.bdmv

- (BOOL)loadNavigationData {
    NSData *index = [NSData dataWithContentsOfURL:[self.bdmvURL URLByAppendingPathComponent:@"index.bdmv"]];
    NSData *objects = [NSData dataWithContentsOfURL:[self.bdmvURL URLByAppendingPathComponent:@"MovieObject.bdmv"]];
    if (index.length < 40 || objects.length < 0x32 || memcmp(index.bytes, "INDX", 4) || memcmp(objects.bytes, "MOBJ", 4)) return NO;

    // index.bdmv: First Playback and Top Menu entries (12 bytes each), then the title count and the titles.
    VPReader r = { index.bytes, index.length, VPBE32((const uint8_t *)index.bytes + 8) + 4, NO };
    _firstPlaybackObject = VPReadIndexEntry(&r);
    _topMenuObject = VPReadIndexEntry(&r);
    uint32_t titleCount = VPRead(&r, 2);
    NSMutableArray<NSNumber *> *titles = [NSMutableArray array];
    for (uint32_t i = 0; i < titleCount && !r.overrun; i++) [titles addObject:@(VPReadIndexEntry(&r))];
    if (r.overrun || _firstPlaybackObject < 0) return NO;   // a disc that starts in Java cannot be driven from here
    _titleObjects = titles;

    VPReader m = { objects.bytes, objects.length, 0x30, NO };
    uint32_t objectCount = VPRead(&m, 2);
    _objects = [NSMutableArray array];
    for (uint32_t i = 0; i < objectCount; i++) {
        VPSkip(&m, 2);                                 // resume intention and menu-call masks
        uint32_t commandCount = VPRead(&m, 2);
        if (m.overrun || m.position + commandCount * kVPInstructionSize > m.length) return NO;
        [_objects addObject:[NSData dataWithBytes:m.bytes + m.position length:commandCount * kVPInstructionSize]];
        VPSkip(&m, commandCount * kVPInstructionSize);
    }
    return _objects.count > 0 && (NSUInteger)_firstPlaybackObject < _objects.count;
}

#pragma mark - Playlists (.mpls)

- (VPBluRayPlaylist *)playlistNamed:(NSString *)name {
    VPBluRayPlaylist *cached;
    @synchronized (_playlists) { cached = _playlists[name]; }
    if (cached) return cached;
    NSData *data = [NSData dataWithContentsOfURL:[[self.bdmvURL URLByAppendingPathComponent:@"PLAYLIST"] URLByAppendingPathComponent:[name stringByAppendingString:@".mpls"]]];
    if (data.length < 20 || memcmp(data.bytes, "MPLS", 4)) return nil;

    VPReader header = { data.bytes, data.length, 8, NO };
    uint32_t playListOffset = VPRead(&header, 4), markOffset = VPRead(&header, 4);
    VPReader r = { data.bytes, data.length, playListOffset + 6, NO };
    uint32_t itemCount = VPRead(&r, 2);
    VPSkip(&r, 2);                                     // sub-path count

    VPBluRayPlaylist *playlist = [VPBluRayPlaylist new];
    playlist.name = name;
    NSMutableArray<NSURL *> *clips = [NSMutableArray array];
    NSMutableArray<NSNumber *> *itemIn = [NSMutableArray array], *itemBase = [NSMutableArray array];
    double total = 0;
    uint16_t graphicsPID = 0x1400;

    for (uint32_t i = 0; i < itemCount && !r.overrun; i++) {
        uint32_t length = VPRead(&r, 2);
        NSUInteger itemStart = r.position, itemEnd = itemStart + length;
        if (itemEnd > data.length || length < 20) break;
        char clipName[6] = {0};
        memcpy(clipName, (const uint8_t *)data.bytes + itemStart, 5);
        NSString *clip = [NSString stringWithUTF8String:clipName];
        for (NSString *ext in @[@"m2ts", @"M2TS"]) {
            NSURL *url = [[self.bdmvURL URLByAppendingPathComponent:@"STREAM"] URLByAppendingPathComponent:[clip stringByAppendingPathExtension:ext]];
            if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) { [clips addObject:url]; break; }
        }
        const uint8_t *item = (const uint8_t *)data.bytes + itemStart;
        double inTime = VPBE32(item + 12) / 45000.0, outTime = VPBE32(item + 16) / 45000.0;
        [itemIn addObject:@(inTime)];
        [itemBase addObject:@(total)];
        total += MAX(0, outTime - inTime);

        if (i == 0) {
            // STN table of the first item: video, audio, subtitle and IG streams.
            // It follows the clip name (5), codec (4), flags (2), STC (1), in/out times (8), user-operation mask (8),
            // random-access and still-mode bytes (2) and the still time (2): 32 bytes into the item.
            NSUInteger stn = itemStart + 32;
            if (((item[10] >> 4) & 1) && stn + 2 <= itemEnd) {          // multi-angle items list their other angles first
                uint8_t angles = item[32];
                stn += 2 + (angles > 1 ? (NSUInteger)(angles - 1) * 10 : 0);
            }
            if (stn + 16 <= itemEnd) {
                const uint8_t *table = (const uint8_t *)data.bytes + stn;
                NSUInteger counts[4] = { table[4], table[5], table[6], table[7] };    // video, audio, PG, IG
                playlist.audioStreamCount = (NSInteger)counts[1];
                NSUInteger cursor = stn + 16, streams = counts[0] + counts[1] + counts[2] + counts[3];
                for (NSUInteger s = 0; s < streams && cursor + 2 <= itemEnd; s++) {
                    NSUInteger entryLength = ((const uint8_t *)data.bytes)[cursor];
                    uint16_t pid = (entryLength >= 3 && ((const uint8_t *)data.bytes)[cursor + 1] == 1) ? VPBE16((const uint8_t *)data.bytes + cursor + 2) : 0;
                    cursor += 1 + entryLength;
                    if (cursor + 2 > itemEnd) break;
                    NSUInteger attributeLength = ((const uint8_t *)data.bytes)[cursor];
                    uint8_t coding = attributeLength ? ((const uint8_t *)data.bytes)[cursor + 1] : 0;
                    if (coding == 0x91) { playlist.hasInteractiveGraphics = YES; if (pid) graphicsPID = pid; }
                    cursor += 1 + attributeLength;
                }
            }
        }
        r.position = itemEnd;
    }
    if (!clips.count) return nil;
    playlist.clipURLs = clips;
    playlist.duration = total;

    // Entry marks are the chapters; their times are relative to the whole playlist.
    NSMutableArray<NSNumber *> *marks = [NSMutableArray array];
    if (markOffset > 0 && markOffset + 6 <= data.length) {
        VPReader mr = { data.bytes, data.length, markOffset + 4, NO };
        uint32_t markCount = VPRead(&mr, 2);
        for (uint32_t i = 0; i < markCount && !mr.overrun; i++) {
            VPSkip(&mr, 1);
            uint32_t type = VPRead(&mr, 1), item = VPRead(&mr, 2), tick = VPRead(&mr, 4);
            VPSkip(&mr, 6);
            if (type == 1 && item < itemIn.count) {
                [marks addObject:@(MAX(0, itemBase[item].doubleValue + tick / 45000.0 - itemIn[item].doubleValue))];
            }
        }
    }
    playlist.markTimes = marks;
    @synchronized (_playlists) {
        _playlists[name] = playlist;
        _graphicsPIDs[name] = @(graphicsPID);
    }
    return playlist;
}

#pragma mark - Running navigation

- (void)start {
    _state = VPBluRayStateIdle;
    memset(_gpr, 0, sizeof(_gpr));
    memset(_psr, 0, sizeof(_psr));
    _psr[1] = 1;                                       // primary audio stream
    _returnCommands = nil;
    [self jumpToObject:_firstPlaybackObject];
    [self run];
}

- (void)showTopMenu {
    if (![self jumpToTitle:0]) return;
    [self run];
}

- (void)playbackDidFinish {
    if (_state != VPBluRayStatePlaying) return;
    if (_running) {                                    // the delegate reported the end from inside its own start call
        dispatch_async(dispatch_get_main_queue(), ^{ [self playbackDidFinish]; });
        return;
    }
    _state = VPBluRayStateIdle;
    if (_returnToMenuAfterPlayback) { _returnToMenuAfterPlayback = NO; [self showTopMenu]; return; }
    [self run];
}

- (void)activateButton:(NSInteger)buttonID {
    NSData *commands = _state == VPBluRayStateMenu ? _buttonCommands[@(buttonID)] : nil;
    if (!commands.length) return;
    _menuCommands = _commands; _menuPC = _pc;
    _commands = commands; _pc = 0; _inButton = YES;
    [self run];
}

- (void)endWithMessage:(NSString *)message {
    _loadToken++;
    _commands = nil; _menuCommands = nil; _inButton = NO;
    _state = VPBluRayStateIdle;
    [self.delegate bluRayNavigator:self didEndWithMessage:message];
}

- (void)jumpToObject:(NSInteger)object {
    _loadToken++;
    if (object < 0 || (NSUInteger)object >= _objects.count) { [self endWithMessage:@"The disc jumped to a movie object that does not exist."]; return; }
    _commands = _objects[object]; _pc = 0;
    _inButton = NO; _menuCommands = nil;
    _returnToMenuAfterPlayback = NO;
}

/// Title 0 is the top menu and 0xFFFF is First Playback; titles 1…N follow index.bdmv.
- (BOOL)jumpToTitle:(uint32_t)title {
    NSInteger object = title == 0 ? _topMenuObject : title == 0xFFFF ? _firstPlaybackObject
                     : (title <= _titleObjects.count ? _titleObjects[title - 1].integerValue : -2);
    if (object == -2) { [self endWithMessage:[NSString stringWithFormat:@"The disc asked for title %u, which it does not list.", title]]; return NO; }
    if (object == -1) { [self endWithMessage:@"This part of the disc uses Java (BD-J) menus, which macvideoplayer cannot run."]; return NO; }
    [self jumpToObject:object];
    return _commands != nil;
}

- (uint32_t)operand:(uint32_t)value immediate:(BOOL)immediate {
    if (immediate) return value;
    return (value & 0x80000000) ? _psr[value & 0x7F] : _gpr[value & 0xFFF];
}

- (void)storeRegister:(uint32_t)reg value:(uint32_t)value {
    if (reg & 0x80000000) _psr[reg & 0x7F] = value; else _gpr[reg & 0xFFF] = value;
}

- (void)run {
    if (_running) return;
    _running = YES;
    NSUInteger steps = 0;
    BOOL yielded = NO;
    while (_commands && _pc * kVPInstructionSize < _commands.length && !yielded) {
        if (++steps > kVPMaxStepsPerRun) { [self endWithMessage:@"The disc's navigation looped without playing anything."]; break; }
        VPHDMVInstruction in = VPDecodeInstruction((const uint8_t *)_commands.bytes + _pc * kVPInstructionSize);
        _pc++;
        yielded = [self execute:in];
    }
    _running = NO;
    if (yielded || !_commands) return;

    // The list ran out. A button's commands return to its menu; a finished movie object ends navigation.
    if (_inButton) {
        _commands = _menuCommands; _pc = _menuPC; _menuCommands = nil; _inButton = NO;
        return;
    }
    [self endWithMessage:nil];
}

/// Runs one instruction. Returns YES when the run loop must stop (something started playing, or navigation ended).
- (BOOL)execute:(VPHDMVInstruction)in {
    uint32_t dst = in.operandCount >= 1 ? [self operand:in.dst immediate:in.dstImmediate] : 0;
    uint32_t src = in.operandCount >= 2 ? [self operand:in.src immediate:in.srcImmediate] : 0;

    switch (in.group) {
        case 0: {   // branch
            if (in.subGroup == 0) {
                if (in.branchOption == 1) _pc = dst;                               // GOTO
                else if (in.branchOption == 2) _pc = _commands.length / kVPInstructionSize;   // BREAK
            } else if (in.subGroup == 1) {
                switch (in.branchOption) {
                    case 0: [self jumpToObject:dst]; return _commands == nil;         // JUMP_OBJECT
                    case 1: [self jumpToTitle:dst]; return _commands == nil;          // JUMP_TITLE
                    case 2: case 3:                                                   // CALL_OBJECT / CALL_TITLE
                        _returnCommands = _commands; _returnPC = _pc;
                        if (in.branchOption == 2) [self jumpToObject:dst]; else [self jumpToTitle:dst];
                        return _commands == nil;
                    case 4:                                                           // RESUME
                        if (_returnCommands) { _commands = _returnCommands; _pc = _returnPC; _returnCommands = nil; _inButton = NO; _menuCommands = nil; }
                        break;
                }
            } else if (in.subGroup == 2) {
                switch (in.branchOption) {
                    case 0: case 1: case 2:                                           // PLAY_PL / PLAY_PL_PI / PLAY_PL_PM
                        return [self startPlaylist:dst mark:in.branchOption == 2 ? (NSInteger)src : -1];
                    default: break;                                                   // links and terminate: not needed for menus
                }
            }
            return NO;
        }
        case 1: {   // compare: run the next instruction only when the comparison holds
            BOOL holds = YES;
            switch (in.compareOption) {
                case 1: holds = (dst & src) != 0; break;
                case 2: holds = dst == src; break;
                case 3: holds = dst != src; break;
                case 4: holds = dst >= src; break;
                case 5: holds = dst > src; break;
                case 6: holds = dst <= src; break;
                case 7: holds = dst < src; break;
                default: break;
            }
            if (!holds) _pc++;
            return NO;
        }
        default: {  // set
            if (in.subGroup == 0) {
                uint32_t current = [self operand:in.dst immediate:NO];
                uint64_t result = current;
                switch (in.setOption) {
                    case 1: result = src; break;                                      // MOVE
                    case 2: if (!in.srcImmediate) { [self storeRegister:in.src value:current]; result = src; } break;   // SWAP
                    case 3: result = MIN((uint64_t)current + src, UINT32_MAX); break;
                    case 4: result = current > src ? current - src : 0; break;
                    case 5: result = MIN((uint64_t)current * src, UINT32_MAX); break;
                    case 6: if (src) result = current / src; break;
                    case 7: if (src) result = current % src; break;
                    case 8: if (src) result = 1 + arc4random_uniform(src); break;    // RND
                    case 9: result = current & src; break;
                    case 10: result = current | src; break;
                    case 11: result = current ^ src; break;
                    case 12: result = src < 32 ? (current | (1u << src)) : current; break;
                    case 13: result = src < 32 ? (current & ~(1u << src)) : current; break;
                    case 14: result = src < 32 ? (uint32_t)((uint64_t)current << src) : 0; break;
                    case 15: result = src < 32 ? current >> src : 0; break;
                }
                [self storeRegister:in.dst value:(uint32_t)result];
            } else if (in.subGroup == 1) {
                [self executeSystemSet:in];
            }
            return NO;
        }
    }
}

/// SET_STREAM and SET_BUTTON_PAGE pack flags and register numbers into their operands; other
/// system-set instructions (timers, stills, popup menus) do not matter to a static menu.
- (void)executeSystemSet:(VPHDMVInstruction)in {
    uint32_t dst = in.dst;
    uint32_t *registers = _gpr;
    BOOL immediate = in.dstImmediate;
    uint32_t (^field)(uint32_t) = ^uint32_t(uint32_t packed) {
        return immediate ? (packed & 0xFFF) : registers[packed & 0xFFF];
    };
    switch (in.setOption) {
        case 1: {   // SET_STREAM: the audio stream sits in the high half of dst, the subtitle stream in the low half
            uint32_t audio = dst >> 16, subtitle = dst & 0xFFFF;
            if (audio & 0x8000) _psr[1] = field(audio);
            if (subtitle & 0x8000) _psr[2] = field(subtitle) | ((subtitle & 0x4000) ? 0x80000000u : 0);
            break;
        }
        case 3: {   // SET_BUTTON_PAGE: the button that should start selected
            if (dst & 0x80000000) _requestedButton = field(dst & 0xFFFF);
            break;
        }
        default: break;
    }
}

#pragma mark - Titles chosen from the navigation bar

- (NSArray<VPBluRayPlaylist *> *)moviePlaylists {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self.bdmvURL URLByAppendingPathComponent:@"PLAYLIST"]
                                                          includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<VPBluRayPlaylist *> *movies = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSURL *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"mpls"]) continue;
        VPBluRayPlaylist *playlist = [self playlistNamed:file.URLByDeletingPathExtension.lastPathComponent];
        if (!playlist || playlist.hasInteractiveGraphics || playlist.duration < 20) continue;
        // Discs often carry several playlists over the same clips (language or commentary variants); list each once.
        NSString *signature = [[playlist.clipURLs valueForKey:@"lastPathComponent"] componentsJoinedByString:@"+"];
        if ([seen containsObject:signature]) continue;
        [seen addObject:signature];
        [movies addObject:playlist];
    }
    [movies sortUsingComparator:^NSComparisonResult(VPBluRayPlaylist *a, VPBluRayPlaylist *b) {
        return a.duration < b.duration ? NSOrderedDescending : a.duration > b.duration ? NSOrderedAscending : NSOrderedSame;
    }];
    return movies;
}

- (void)playMoviePlaylist:(VPBluRayPlaylist *)playlist {
    _loadToken++;
    _commands = nil; _menuCommands = nil; _inButton = NO;
    _state = VPBluRayStatePlaying;
    _returnToMenuAfterPlayback = YES;
    [self.delegate bluRayNavigator:self playPlaylist:playlist startSeconds:0 audioStream:0];
}

- (void)playMainMovie {
    VPBluRayPlaylist *main = [self moviePlaylists].firstObject;
    if (main) [self playMoviePlaylist:main];
}

#pragma mark - Starting playlists and menus

/// PLAY_PL: a playlist with an IG stream is a menu, anything else a movie. Returns YES when the run loop must stop.
/// The playlist and menu graphics are read from the disc on a background queue: a slow or failing optical drive
/// blocks file reads for a long time and must never freeze the interface.
- (BOOL)startPlaylist:(uint32_t)number mark:(NSInteger)mark {
    NSString *name = [NSString stringWithFormat:@"%05u", number];
    _inButton = NO; _menuCommands = nil;               // whatever started this playlist is left behind
    _state = VPBluRayStateIdle;                        // buttons are ignored until the disc has answered
    NSUInteger token = ++_loadToken;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VPBluRayPlaylist *playlist = [self playlistNamed:name];
        VPBluRayMenuPage *page = nil;
        NSDictionary<NSNumber *, NSData *> *commands = nil;
        if (playlist.hasInteractiveGraphics) {
            NSNumber *pid;
            @synchronized (self->_playlists) { pid = self->_graphicsPIDs[name]; }
            page = VPDecodeMenuPage(playlist.clipURLs.firstObject, pid.unsignedShortValue, &commands);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_loadToken) return;     // the viewer or the disc moved on while this was loading
            [self finishStartingPlaylist:playlist page:page commands:commands name:name mark:mark];
        });
    });
    return YES;
}

- (void)finishStartingPlaylist:(VPBluRayPlaylist *)playlist page:(VPBluRayMenuPage *)page commands:(NSDictionary<NSNumber *, NSData *> *)commands name:(NSString *)name mark:(NSInteger)mark {
    if (!playlist) { [self endWithMessage:[NSString stringWithFormat:@"The disc plays playlist %@, which could not be read.", name]]; return; }
    if (page) {
        _buttonCommands = commands;
        _state = VPBluRayStateMenu;
        NSInteger selected = _requestedButton >= 0 && [page buttonWithID:_requestedButton] ? _requestedButton : page.defaultButtonID;
        _requestedButton = kVPNoButton;
        [self.delegate bluRayNavigator:self showMenuForPlaylist:playlist page:page selectedButton:selected];
        return;
    }
    _state = VPBluRayStatePlaying;
    double start = (mark > 0 && (NSUInteger)mark < playlist.markTimes.count) ? playlist.markTimes[mark].doubleValue : 0;
    NSInteger audio = _psr[1];
    if (audio < 1 || audio > playlist.audioStreamCount) audio = 0;
    [self.delegate bluRayNavigator:self playPlaylist:playlist startSeconds:start audioStream:audio];
}

@end
