#import "VPDiscSupport.h"
#import <math.h>

@implementation VPDiscStreamInfo
@end

@implementation VPDiscChapter
@end

@implementation VPDiscTitle
@end

@implementation VPDiscMenuStructure
- (VPDiscTitle *)mainTitle {
    for (VPDiscTitle *t in self.titles) {
        if (t.isMainFeature) return t;
    }
    return self.titles.firstObject;
}
- (VPDiscTitle *)primaryMenu {
    return self.menus.firstObject;
}
@end

@implementation VPFFConcatMetadata
@end

static NSMutableDictionary<NSString *, VPDiscMenuStructure *> *gDiscMenuCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static uint16_t VPReadBE16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static uint32_t VPReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int VPBCDToInt(uint8_t bcd) {
    return ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F);
}

static double VPDVDPlaybackTimeToSeconds(const uint8_t *p) {
    int hh = VPBCDToInt(p[0]);
    int mm = VPBCDToInt(p[1]);
    int ss = VPBCDToInt(p[2]);
    int ff = VPBCDToInt(p[3] & 0x3F);
    uint8_t rateCode = (p[3] >> 6) & 0x03;
    double fps = (rateCode == 3) ? 29.97 : 25.0;
    return (double)hh * 3600.0 + (double)mm * 60.0 + (double)ss + ((double)ff / fps);
}

static uint32_t VPYCbCrToRGBA(uint8_t y, uint8_t cr, uint8_t cb) {
    // DVD CLUT stores 4 bytes per entry: [0]=0, [1]=Y, [2]=Cr(V), [3]=Cb(U)
    double yd = (double)y - 16.0;
    double crd = (double)cr - 128.0;
    double cbd = (double)cb - 128.0;
    int r = (int)llround(1.164 * yd + 1.596 * crd);
    int g = (int)llround(1.164 * yd - 0.813 * crd - 0.391 * cbd);
    int b = (int)llround(1.164 * yd + 2.018 * cbd);
    r = MAX(0, MIN(255, r));
    g = MAX(0, MIN(255, g));
    b = MAX(0, MIN(255, b));
    return ((uint32_t)r << 24) | ((uint32_t)g << 16) | ((uint32_t)b << 8) | 0xFFu;
}

@implementation VPDiscSupport

+ (NSString *)displayLanguageForCode:(NSString *)code {
    if (!code.length) return @"Unknown";
    NSString *lower = [code.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"en": @"English", @"eng": @"English",
            @"es": @"Spanish", @"spa": @"Spanish",
            @"fr": @"French", @"fra": @"French", @"fre": @"French",
            @"de": @"German", @"deu": @"German", @"ger": @"German",
            @"it": @"Italian", @"ita": @"Italian",
            @"pt": @"Portuguese", @"por": @"Portuguese",
            @"ja": @"Japanese", @"jpn": @"Japanese",
            @"ko": @"Korean", @"kor": @"Korean",
            @"zh": @"Chinese", @"zho": @"Chinese", @"chi": @"Chinese",
            @"ru": @"Russian", @"rus": @"Russian",
            @"nl": @"Dutch", @"nld": @"Dutch", @"dut": @"Dutch",
            @"sv": @"Swedish", @"swe": @"Swedish",
            @"no": @"Norwegian", @"nor": @"Norwegian",
            @"da": @"Danish", @"dan": @"Danish",
            @"fi": @"Finnish", @"fin": @"Finnish",
            @"pl": @"Polish", @"pol": @"Polish",
            @"cs": @"Czech", @"ces": @"Czech", @"cze": @"Czech",
            @"hu": @"Hungarian", @"hun": @"Hungarian",
            @"tr": @"Turkish", @"tur": @"Turkish",
            @"ar": @"Arabic", @"ara": @"Arabic",
            @"he": @"Hebrew", @"heb": @"Hebrew",
            @"hi": @"Hindi", @"hin": @"Hindi",
            @"th": @"Thai", @"tha": @"Thai",
            @"vi": @"Vietnamese", @"vie": @"Vietnamese",
            @"el": @"Greek", @"ell": @"Greek", @"gre": @"Greek",
            @"ro": @"Romanian", @"ron": @"Romanian", @"rum": @"Romanian",
            @"uk": @"Ukrainian", @"ukr": @"Ukrainian",
            @"id": @"Indonesian", @"ind": @"Indonesian"
        };
    });
    if (map[lower]) return map[lower];
    NSString *localized = [[NSLocale currentLocale] displayNameForKey:NSLocaleLanguageCode value:lower];
    return localized.length ? localized : code.uppercaseString;
}

+ (NSString *)nameForKind:(VPDiscKind)kind {
    switch (kind) {
        case VPDiscKindDVD: return @"DVD";
        case VPDiscKindBluRay: return @"Blu-ray";
        case VPDiscKindAudioCD: return @"Audio CD";
        case VPDiscKindSVCD: return @"SVCD";
        case VPDiscKindVCD: return @"VCD";
        default: return @"Media";
    }
}

+ (BOOL)hasChildDirectory:(NSString *)name atURL:(NSURL *)url {
    BOOL isDir = NO;
    NSString *path = [url.path stringByAppendingPathComponent:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

+ (BOOL)isAudioCDFolder:(NSURL *)url {
    NSString *tocPath = [url.path stringByAppendingPathComponent:@".TOC.plist"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:tocPath]) return YES;
    NSArray<NSURL *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:url
                                                            includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    if (!items.count) return NO;
    NSInteger cddaCount = 0;
    for (NSURL *item in items) {
        NSString *ext = item.pathExtension.lowercaseString;
        NSString *name = item.lastPathComponent.lowercaseString;
        if ([ext isEqualToString:@"cdda"] || ([ext isEqualToString:@"aiff"] && [name containsString:@"audio track"])) {
            cddaCount++;
        }
    }
    return cddaCount > 0;
}

+ (VPDiscKind)kindForURL:(NSURL *)url {
    if (!url.isFileURL) return VPDiscKindNone;
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ffconcat"]) {
        VPFFConcatMetadata *meta = [self parseFFConcatFileAtURL:url];
        if ([meta.discKindName isEqualToString:@"DVD"]) return VPDiscKindDVD;
        if ([meta.discKindName isEqualToString:@"Blu-ray"]) return VPDiscKindBluRay;
        if ([meta.discKindName isEqualToString:@"Audio CD"]) return VPDiscKindAudioCD;
        if ([meta.discKindName isEqualToString:@"SVCD"]) return VPDiscKindSVCD;
        if ([meta.discKindName isEqualToString:@"VCD"]) return VPDiscKindVCD;
        return VPDiscKindDVD;
    }
    NSString *last = url.lastPathComponent.uppercaseString;
    if ([last isEqualToString:@"VIDEO_TS"] || [self hasChildDirectory:@"VIDEO_TS" atURL:url] || [ext isEqualToString:@"ifo"] || [ext isEqualToString:@"vob"]) {
        return VPDiscKindDVD;
    }
    if ([last isEqualToString:@"BDMV"] || [self hasChildDirectory:@"BDMV" atURL:url] || [ext isEqualToString:@"bdmv"] || [ext isEqualToString:@"mpls"] || [ext isEqualToString:@"m2ts"]) {
        return VPDiscKindBluRay;
    }
    if ([last isEqualToString:@"MPEG2"] || [self hasChildDirectory:@"MPEG2" atURL:url] || [self hasChildDirectory:@"SVCD" atURL:url]) {
        return VPDiscKindSVCD;
    }
    if ([last isEqualToString:@"MPEGAV"] || [self hasChildDirectory:@"MPEGAV" atURL:url] || [self hasChildDirectory:@"VCD" atURL:url] || [ext isEqualToString:@"dat"]) {
        return VPDiscKindVCD;
    }
    if ([ext isEqualToString:@"cdda"] || [self isAudioCDFolder:url]) {
        return VPDiscKindAudioCD;
    }
    if ([url.URLByDeletingLastPathComponent.lastPathComponent.uppercaseString isEqualToString:@"VOLUMES"] && [self isAudioCDFolder:url.URLByDeletingLastPathComponent]) {
        return VPDiscKindAudioCD;
    }
    return VPDiscKindNone;
}

+ (BOOL)isDiscOrImageURL:(NSURL *)url {
    if ([self kindForURL:url] != VPDiscKindNone) return YES;
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"iso", @"img", @"toast", @"cdr", @"bin", @"cue", @"nrg"] containsObject:ext];
}

+ (NSURL *)resolveDiscRootForURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"vob"] || [ext isEqualToString:@"ifo"] || [ext isEqualToString:@"bup"]) {
        NSURL *parent = url.URLByDeletingLastPathComponent;
        if ([parent.lastPathComponent.uppercaseString isEqualToString:@"VIDEO_TS"]) {
            return parent.URLByDeletingLastPathComponent;
        }
        return parent;
    }
    if ([ext isEqualToString:@"mpls"] || [ext isEqualToString:@"m2ts"] || [ext isEqualToString:@"bdmv"]) {
        NSURL *cur = url.URLByDeletingLastPathComponent;
        for (int i = 0; i < 4; i++) {
            if ([cur.lastPathComponent.uppercaseString isEqualToString:@"BDMV"]) {
                return cur.URLByDeletingLastPathComponent;
            }
            cur = cur.URLByDeletingLastPathComponent;
        }
    }
    if ([url.lastPathComponent.uppercaseString isEqualToString:@"VIDEO_TS"] ||
        [url.lastPathComponent.uppercaseString isEqualToString:@"BDMV"]) {
        return url.URLByDeletingLastPathComponent;
    }
    return url;
}

#pragma mark - DVD IFO Binary Parser

+ (void)parseDVDIFO:(NSURL *)ifoURL
      intoMenuTitle:(VPDiscTitle *_Nullable)menuTitle
        featureTitle:(VPDiscTitle *_Nullable)featureTitle {
    NSData *data = [NSData dataWithContentsOfURL:ifoURL];
    if (data.length < 0x400) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (memcmp(bytes, "DVDVIDEO-VTS", 12) != 0 && memcmp(bytes, "DVDVIDEO-VMG", 12) != 0) {
        return;
    }
    BOOL isVTS = (memcmp(bytes, "DVDVIDEO-VTS", 12) == 0);

    // Menu Video Attributes at 0x100
    uint16_t menuVidAttr = VPReadBE16(bytes + 0x100);
    int menuAspectCode = (menuVidAttr >> 10) & 0x03;
    double menuAspect = (menuAspectCode == 3) ? (16.0 / 9.0) : (4.0 / 3.0);
    if (menuTitle) menuTitle.aspectRatio = menuAspect;

    if (!isVTS) return;

    // Title Set Video Attributes at 0x200
    uint16_t vtsVidAttr = VPReadBE16(bytes + 0x200);
    int vtsAspectCode = (vtsVidAttr >> 10) & 0x03;
    double vtsAspect = (vtsAspectCode == 3) ? (16.0 / 9.0) : (4.0 / 3.0);
    if (featureTitle) featureTitle.aspectRatio = vtsAspect;

    // Audio Streams at 0x202 (count) and 0x204..0x243 (8 x 8 bytes)
    uint16_t audioCount = MIN(8, VPReadBE16(bytes + 0x202));
    NSMutableArray<VPDiscStreamInfo *> *audioList = [NSMutableArray array];
    for (int i = 0; i < audioCount; i++) {
        const uint8_t *attr = bytes + 0x204 + (i * 8);
        uint8_t codingMode = (attr[0] >> 5) & 0x07;
        BOOL hasLang = ((attr[0] >> 2) & 0x03) == 1;
        int channels = (attr[1] & 0x07) + 1;
        int sampleRate = ((attr[1] >> 4) & 0x03) == 1 ? 96000 : 48000;

        NSString *codecName = @"ac3";
        NSString *codecLabel = @"Dolby AC-3";
        int substreamID = 0x80 + i;
        switch (codingMode) {
            case 0: codecName = @"ac3"; codecLabel = @"Dolby AC-3"; substreamID = 0x80 + i; break;
            case 2:
            case 3: codecName = @"mp2"; codecLabel = @"MPEG Audio"; substreamID = 0xC0 + i; break;
            case 4: codecName = @"pcm_dvd"; codecLabel = @"LPCM"; substreamID = 0xA0 + i; break;
            case 6: codecName = @"dts"; codecLabel = @"DTS"; substreamID = 0x88 + i; break;
            default: break;
        }
        NSString *langCode = @"und";
        if (hasLang && attr[2] >= 'a' && attr[2] <= 'z' && attr[3] >= 'a' && attr[3] <= 'z') {
            char lc[3] = { (char)attr[2], (char)attr[3], 0 };
            langCode = [NSString stringWithUTF8String:lc] ?: @"und";
        }
        NSString *langName = [self displayLanguageForCode:langCode];
        NSString *chDesc = (channels == 6) ? @"5.1ch" : (channels == 2 ? @"Stereo" : (channels == 1 ? @"Mono" : [NSString stringWithFormat:@"%dch", channels]));

        VPDiscStreamInfo *s = [[VPDiscStreamInfo alloc] init];
        s.index = i;
        s.streamID = substreamID;
        s.codecName = codecName;
        s.language = langCode;
        s.channels = channels;
        s.sampleRate = sampleRate;
        s.isSubtitle = NO;
        s.title = [NSString stringWithFormat:@"Track %d — %@ (%@ %@)", i + 1, langName, codecLabel, chDesc];
        [audioList addObject:s];
    }

    // Subpicture Streams at 0x254 (count) and 0x256..0x315 (32 x 6 bytes)
    uint16_t subpCount = MIN(32, VPReadBE16(bytes + 0x254));
    NSMutableArray<VPDiscStreamInfo *> *subList = [NSMutableArray array];
    for (int i = 0; i < subpCount; i++) {
        const uint8_t *attr = bytes + 0x256 + (i * 6);
        // Check if entry is populated
        if (attr[0] == 0 && attr[1] == 0 && attr[2] == 0 && attr[3] == 0) continue;
        NSString *langCode = @"und";
        if (attr[2] >= 'a' && attr[2] <= 'z' && attr[3] >= 'a' && attr[3] <= 'z') {
            char lc[3] = { (char)attr[2], (char)attr[3], 0 };
            langCode = [NSString stringWithUTF8String:lc] ?: @"und";
        }
        NSString *langName = [self displayLanguageForCode:langCode];
        uint8_t codeExt = attr[5];
        NSString *extNote = @"";
        if (codeExt == 2) extNote = @" (Large)";
        else if (codeExt == 5 || codeExt == 6) extNote = @" (Closed Captions / SDH)";
        else if (codeExt == 9) extNote = @" (Forced)";
        else if (codeExt == 13 || codeExt == 14) extNote = @" (Director Commentary)";

        VPDiscStreamInfo *sub = [[VPDiscStreamInfo alloc] init];
        sub.index = (int)subList.count;
        sub.streamID = 0x20 + i;
        sub.codecName = @"dvd_subtitle";
        sub.language = langCode;
        sub.isSubtitle = YES;
        sub.title = [NSString stringWithFormat:@"Subtitle %d — %@%@", (int)subList.count + 1, langName, extNote];
        [subList addObject:sub];
    }

    if (featureTitle) {
        featureTitle.audioStreams = audioList;
        featureTitle.subtitleStreams = subList;
    }

    // Parse VTS_PGCIT (Program Chain Information Table) at sector pointer 0xCC
    uint32_t pgcitSector = VPReadBE32(bytes + 0xCC);
    uint64_t pgcitOffset = (uint64_t)pgcitSector * 2048ULL;
    if (pgcitSector > 0 && pgcitOffset + 16 <= data.length && featureTitle) {
        const uint8_t *pgcit = bytes + pgcitOffset;
        uint16_t numPGCs = VPReadBE16(pgcit);
        double bestDuration = 0.0;
        NSArray<VPDiscChapter *> *bestChapters = @[];
        NSArray<NSNumber *> *bestPalette = nil;
        NSArray *bestCells = @[];

        for (uint16_t p = 0; p < numPGCs && p < 64; p++) {
            if (featureTitle.dvdProgramChain > 0 && p + 1 != featureTitle.dvdProgramChain) continue;
            uint64_t srpPos = pgcitOffset + 8 + ((uint64_t)p * 8);
            if (srpPos + 8 > data.length) break;
            uint32_t pgcRelOffset = VPReadBE32(bytes + srpPos + 4);
            uint64_t pgcOffset = pgcitOffset + pgcRelOffset;
            if (pgcOffset + 0xEC > data.length) continue;

            const uint8_t *pgc = bytes + pgcOffset;
            uint8_t numPrograms = pgc[2];
            uint8_t numCells = pgc[3];
            double duration = VPDVDPlaybackTimeToSeconds(pgc + 4);
            if (duration <= bestDuration && bestDuration > 0) continue;

            // Read 16-entry YCbCr CLUT palette at PGC + 0xA4
            NSMutableArray<NSNumber *> *palette = [NSMutableArray arrayWithCapacity:16];
            for (int c = 0; c < 16; c++) {
                const uint8_t *pe = pgc + 0xA4 + (c * 4);
                uint32_t rgba = VPYCbCrToRGBA(pe[1], pe[2], pe[3]);
                [palette addObject:@(rgba)];
            }

            // Read Program Map (PGC + 0xE6) and Cell Playback Info Table (PGC + 0xE8)
            uint16_t progMapOffset = VPReadBE16(pgc + 0xE6);
            uint16_t cellPlayOffset = VPReadBE16(pgc + 0xE8);
            NSMutableArray<VPDiscChapter *> *chapters = [NSMutableArray array];
            NSMutableArray *selectedCells = [NSMutableArray array];
            uint16_t cellPositionOffset = VPReadBE16(pgc + 0xEA);

            if (progMapOffset > 0 && cellPlayOffset > 0 &&
                pgcOffset + progMapOffset + numPrograms <= data.length &&
                pgcOffset + cellPlayOffset + ((uint64_t)numCells * 24) <= data.length) {
                const uint8_t *progMap = pgc + progMapOffset;
                const uint8_t *cellTable = pgc + cellPlayOffset;

                // Precalculate cumulative start time of each cell (1-indexed)
                NSMutableArray<NSNumber *> *cellStarts = [NSMutableArray arrayWithCapacity:numCells + 1];
                NSMutableArray<NSNumber *> *cellDurations = [NSMutableArray arrayWithCapacity:numCells + 1];
                [cellStarts addObject:@0.0];
                [cellDurations addObject:@0.0];
                double accum = 0.0;
                for (int c = 0; c < numCells; c++) {
                    const uint8_t *cell = cellTable + (c * 24);
                    // Angle blocks contain alternative versions of the same time.
                    // Keep the first cell of each block, never sum both angles.
                    BOOL alternateAngle = ((cell[0] >> 4) & 3) == 1 && ((cell[0] >> 6) & 3) != 1;
                    double cDur = alternateAngle ? 0.0 : VPDVDPlaybackTimeToSeconds(cell + 4);
                    if (!alternateAngle && cellPositionOffset > 0 &&
                        pgcOffset + cellPositionOffset + ((uint64_t)c + 1) * 4 <= data.length) {
                        const uint8_t *position = pgc + cellPositionOffset + c * 4;
                        uint32_t first = VPReadBE32(cell + 8), last = VPReadBE32(cell + 20);
                        if (last >= first) {
                            [selectedCells addObject:@{@"first":@(first), @"last":@(last),
                                @"vob":@(VPReadBE16(position)), @"cell":@(position[3])}];
                        }
                    }
                    [cellStarts addObject:@(accum)];
                    [cellDurations addObject:@(cDur)];
                    accum += cDur;
                }

                for (int prog = 0; prog < numPrograms; prog++) {
                    uint8_t entryCell = progMap[prog];
                    uint8_t nextEntryCell = (prog + 1 < numPrograms) ? progMap[prog + 1] : (numCells + 1);
                    if (entryCell < 1 || entryCell > numCells) continue;
                    double startSec = [cellStarts[entryCell] doubleValue];
                    double chapDur = 0.0;
                    for (int c = entryCell; c < nextEntryCell && c <= numCells; c++) {
                        chapDur += [cellDurations[c] doubleValue];
                    }
                    VPDiscChapter *ch = [[VPDiscChapter alloc] init];
                    ch.index = prog + 1;
                    ch.startTime = startSec;
                    ch.duration = chapDur;
                    int mins = (int)(startSec / 60.0);
                    int secs = (int)fmod(startSec, 60.0);
                    ch.title = [NSString stringWithFormat:@"Chapter %d (%02d:%02d)", prog + 1, mins, secs];
                    [chapters addObject:ch];
                }
            }

            bestDuration = duration;
            bestPalette = palette;
            bestChapters = chapters;
            bestCells = selectedCells;
        }

        featureTitle.dvdCells = bestCells;
        if (bestDuration > 0) featureTitle.duration = bestDuration;
        if (bestPalette.count == 16) featureTitle.clutPaletteRGBA = bestPalette;
        if (bestChapters.count > 0) featureTitle.chapters = bestChapters;
    }
}

#pragma mark - Blu-ray MPLS Binary Parser

+ (nullable VPDiscTitle *)parseBluRayMPLS:(NSURL *)mplsURL streamDir:(NSURL *)streamDir index:(NSInteger)idx {
    NSData *data = [NSData dataWithContentsOfURL:mplsURL];
    if (data.length < 64) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (memcmp(bytes, "MPLS0100", 8) != 0 && memcmp(bytes, "MPLS0200", 8) != 0 && memcmp(bytes, "MPLS0300", 8) != 0) {
        return nil;
    }

    uint32_t playListOffset = VPReadBE32(bytes + 8);
    uint32_t markOffset = VPReadBE32(bytes + 12);
    if (playListOffset == 0 || playListOffset + 10 > data.length) return nil;

    uint16_t numPlayItems = VPReadBE16(bytes + playListOffset + 6);
    if (numPlayItems == 0) return nil;

    NSMutableArray<NSURL *> *segmentURLs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *itemInTimes = [NSMutableArray array];
    NSMutableArray<NSNumber *> *itemStartOffsets = [NSMutableArray array];
    NSMutableArray<VPDiscStreamInfo *> *audioStreams = [NSMutableArray array];
    NSMutableArray<VPDiscStreamInfo *> *subStreams = [NSMutableArray array];

    double totalDuration = 0.0;
    uint64_t pos = playListOffset + 10;

    for (uint16_t i = 0; i < numPlayItems; i++) {
        if (pos + 2 > data.length) break;
        uint16_t itemLen = VPReadBE16(bytes + pos);
        uint64_t itemStart = pos + 2;
        if (itemStart + itemLen > data.length || itemLen < 18) break;

        char clipName[6] = {0};
        memcpy(clipName, bytes + itemStart, 5);
        NSString *clipStr = [NSString stringWithUTF8String:clipName];
        if (clipStr.length == 5) {
            NSString *m2tsPath = [streamDir.path stringByAppendingPathComponent:[clipStr stringByAppendingString:@".m2ts"]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:m2tsPath]) {
                m2tsPath = [streamDir.path stringByAppendingPathComponent:[clipStr stringByAppendingString:@".M2TS"]];
            }
            if ([[NSFileManager defaultManager] fileExistsAtPath:m2tsPath]) {
                [segmentURLs addObject:[NSURL fileURLWithPath:m2tsPath]];
            }
        }

        uint32_t inTime = VPReadBE32(bytes + itemStart + 12);
        uint32_t outTime = VPReadBE32(bytes + itemStart + 16);
        double clipDur = (outTime > inTime) ? ((double)(outTime - inTime) / 45000.0) : 0.0;
        [itemInTimes addObject:@((double)inTime / 45000.0)];
        [itemStartOffsets addObject:@(totalDuration)];
        totalDuration += clipDur;

        // Parse STN_table of first PlayItem for Audio & PGS Subtitle tracks
        if (i == 0 && itemLen >= 34) {
            uint8_t multiAngle = (bytes[itemStart + 10] >> 4) & 0x01;
            uint64_t stnOffset = itemStart + 30;
            if (multiAngle && stnOffset + 2 <= itemStart + itemLen) {
                uint8_t numAngles = bytes[stnOffset];
                stnOffset += 2 + (numAngles > 1 ? (uint64_t)(numAngles - 1) * 10 : 0);
            }
            if (stnOffset + 16 <= itemStart + itemLen) {
                const uint8_t *stn = bytes + stnOffset;
                uint8_t numVideo = stn[4];
                uint8_t numAudio = stn[5];
                uint8_t numPG = stn[6];
                uint64_t sp = stnOffset + 16;

                for (int s = 0; s < (int)numVideo + (int)numAudio + (int)numPG; s++) {
                    if (sp + 2 > itemStart + itemLen) break;
                    uint8_t entryLen = bytes[sp];
                    if (sp + 1 + entryLen > itemStart + itemLen) break;
                    uint8_t streamType = bytes[sp + 1];
                    int pid = (entryLen >= 3) ? VPReadBE16(bytes + sp + 2) : 0;
                    sp += 1 + entryLen;

                    if (sp + 2 > itemStart + itemLen) break;
                    uint8_t attrLen = bytes[sp];
                    if (sp + 1 + attrLen > itemStart + itemLen) break;
                    uint8_t codingType = (attrLen >= 1) ? bytes[sp + 1] : 0;

                    if (s >= numVideo && s < numVideo + numAudio) {
                        uint8_t formatByte = (attrLen >= 2) ? bytes[sp + 2] : 0;
                        int chCode = (formatByte >> 4) & 0x0F;
                        int channels = (chCode == 6) ? 6 : (chCode == 3 ? 2 : (chCode == 1 ? 1 : 6));
                        NSString *lang = @"und";
                        if (attrLen >= 5 && bytes[sp + 3] >= 'a' && bytes[sp + 3] <= 'z') {
                            char lc[4] = { (char)bytes[sp + 3], (char)bytes[sp + 4], (char)bytes[sp + 5], 0 };
                            lang = [NSString stringWithUTF8String:lc] ?: @"und";
                        }
                        NSString *codecLabel = @"Audio";
                        NSString *codecName = @"ac3";
                        switch (codingType) {
                            case 0x80: codecName = @"pcm_bluray"; codecLabel = @"LPCM"; break;
                            case 0x81: codecName = @"ac3"; codecLabel = @"Dolby Digital"; break;
                            case 0x82: codecName = @"dca"; codecLabel = @"DTS"; break;
                            case 0x83: codecName = @"truehd"; codecLabel = @"Dolby TrueHD"; break;
                            case 0x84: codecName = @"eac3"; codecLabel = @"Dolby Digital Plus"; break;
                            case 0x85: codecName = @"dca"; codecLabel = @"DTS-HD High Res"; break;
                            case 0x86: codecName = @"dca"; codecLabel = @"DTS-HD Master Audio"; break;
                            default: break;
                        }
                        VPDiscStreamInfo *as = [[VPDiscStreamInfo alloc] init];
                        as.index = (int)audioStreams.count;
                        as.streamID = (streamType == 1) ? pid : (0x1100 + as.index);
                        as.codecName = codecName;
                        as.language = lang;
                        as.channels = channels;
                        as.sampleRate = 48000;
                        as.isSubtitle = NO;
                        as.title = [NSString stringWithFormat:@"Track %d — %@ (%@)", as.index + 1, [self displayLanguageForCode:lang], codecLabel];
                        [audioStreams addObject:as];
                    } else if (s >= numVideo + numAudio) {
                        NSString *lang = @"und";
                        if (attrLen >= 4 && bytes[sp + 2] >= 'a' && bytes[sp + 2] <= 'z') {
                            char lc[4] = { (char)bytes[sp + 2], (char)bytes[sp + 3], (char)bytes[sp + 4], 0 };
                            lang = [NSString stringWithUTF8String:lc] ?: @"und";
                        }
                        VPDiscStreamInfo *ss = [[VPDiscStreamInfo alloc] init];
                        ss.index = (int)subStreams.count;
                        ss.streamID = (streamType == 1) ? pid : (0x1200 + ss.index);
                        ss.codecName = (codingType == 0x92) ? @"subrip" : @"hdmv_pgs_subtitle";
                        ss.language = lang;
                        ss.isSubtitle = YES;
                        ss.title = [NSString stringWithFormat:@"Subtitle %d — %@ (PGS)", ss.index + 1, [self displayLanguageForCode:lang]];
                        [subStreams addObject:ss];
                    }
                    sp += 1 + attrLen;
                }
            }
        }
        pos = itemStart + itemLen;
    }

    if (!segmentURLs.count) return nil;

    // Parse PlayListMark for Chapter timestamps
    NSMutableArray<VPDiscChapter *> *chapters = [NSMutableArray array];
    if (markOffset > 0 && markOffset + 6 <= data.length) {
        uint16_t numMarks = VPReadBE16(bytes + markOffset + 4);
        uint64_t mp = markOffset + 6;
        for (uint16_t m = 0; m < numMarks; m++) {
            if (mp + 14 > data.length) break;
            uint8_t markType = bytes[mp + 1];
            uint16_t itemRef = VPReadBE16(bytes + mp + 2);
            uint32_t markTick = VPReadBE32(bytes + mp + 4);
            mp += 14;
            if (markType == 0x01 && itemRef < itemInTimes.count) {
                double itemIn = [itemInTimes[itemRef] doubleValue];
                double itemBase = [itemStartOffsets[itemRef] doubleValue];
                double chapTime = MAX(0.0, itemBase + ((double)markTick / 45000.0) - itemIn);
                VPDiscChapter *ch = [[VPDiscChapter alloc] init];
                ch.index = (NSInteger)chapters.count + 1;
                ch.startTime = chapTime;
                int mins = (int)(chapTime / 60.0);
                int secs = (int)fmod(chapTime, 60.0);
                ch.title = [NSString stringWithFormat:@"Chapter %ld (%02d:%02d)", (long)ch.index, mins, secs];
                [chapters addObject:ch];
            }
        }
        for (NSUInteger c = 0; c < chapters.count; c++) {
            double nextStart = (c + 1 < chapters.count) ? chapters[c + 1].startTime : totalDuration;
            chapters[c].duration = MAX(0.0, nextStart - chapters[c].startTime);
        }
    }

    VPDiscTitle *title = [[VPDiscTitle alloc] init];
    title.index = idx;
    title.duration = totalDuration;
    title.aspectRatio = 16.0 / 9.0;
    title.segmentURLs = segmentURLs;
    title.audioStreams = audioStreams;
    title.subtitleStreams = subStreams;
    title.chapters = chapters;
    return title;
}

#pragma mark - FFConcat Writing & Parsing with Embedded Disc Metadata

+ (NSURL *)writeFFConcatForTitle:(VPDiscTitle *)title
                        discKind:(VPDiscKind)kind
                        discRoot:(NSURL *)discRoot
                            name:(NSString *)name {
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vplay-disc-playlists"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *safeName = [[name componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"_"];
    NSString *fileName = [NSString stringWithFormat:@"%@-%lu.ffconcat", safeName, (unsigned long)[discRoot.path hash]];
    NSURL *concatURL = [NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:fileName]];

    NSMutableString *content = [NSMutableString stringWithString:@"ffconcat version 1.0\n"];
    [content appendFormat:@"# vplay-disc: %@\n", [self nameForKind:kind]];
    [content appendFormat:@"# vplay-root: %@\n", discRoot.path];
    [content appendFormat:@"# vplay-title: %@\n", title.title ?: name];
    [content appendFormat:@"# vplay-menu: %d\n", title.isMenu ? 1 : 0];
    if (title.duration > 0) [content appendFormat:@"# vplay-duration: %.3f\n", title.duration];
    if (title.aspectRatio > 0) [content appendFormat:@"# vplay-aspect: %.6f\n", title.aspectRatio];

    if (title.clutPaletteRGBA.count == 16) {
        NSMutableArray<NSString *> *hexes = [NSMutableArray arrayWithCapacity:16];
        for (NSNumber *n in title.clutPaletteRGBA) {
            [hexes addObject:[NSString stringWithFormat:@"%08X", [n unsignedIntValue]]];
        }
        [content appendFormat:@"# vplay-palette: %@\n", [hexes componentsJoinedByString:@","]];
    }

    for (VPDiscStreamInfo *as in title.audioStreams) {
        [content appendFormat:@"# vplay-audio: %d|%d|%@|%@|%d|%d|%@\n",
         as.index, as.streamID, as.codecName ?: @"ac3", as.language ?: @"und", as.channels, as.sampleRate, as.title ?: @""];
    }
    for (VPDiscStreamInfo *ss in title.subtitleStreams) {
        [content appendFormat:@"# vplay-subp: %d|%d|%@|%@|%@\n",
         ss.index, ss.streamID, ss.codecName ?: @"dvd_subtitle", ss.language ?: @"und", ss.title ?: @""];
    }
    for (VPDiscChapter *ch in title.chapters) {
        [content appendFormat:@"# vplay-chapter: %ld|%.3f|%.3f|%@\n",
         (long)ch.index, ch.startTime, ch.duration, ch.title ?: @""];
    }

    for (NSDictionary *cell in title.dvdCells) {
        [content appendFormat:@"# vplay-cell: %@|%@|%@|%@\n", cell[@"first"], cell[@"last"], cell[@"vob"], cell[@"cell"]];
    }
    for (NSURL *seg in title.segmentURLs) {
        NSString *escaped = [seg.path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        [content appendFormat:@"file '%@'\n", escaped];
    }

    [content writeToURL:concatURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return concatURL;
}

+ (nullable VPFFConcatMetadata *)parseFFConcatFileAtURL:(NSURL *)url {
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return nil;

    VPFFConcatMetadata *meta = [[VPFFConcatMetadata alloc] init];
    meta.discKindName = @"DVD";
    meta.aspectRatio = 0.0;
    NSMutableArray<VPDiscStreamInfo *> *audios = [NSMutableArray array];
    NSMutableArray<VPDiscStreamInfo *> *subs = [NSMutableArray array];
    NSMutableArray<VPDiscChapter *> *chaps = [NSMutableArray array];
    NSMutableArray<NSURL *> *segs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *palette = [NSMutableArray array];
    NSMutableArray *cells = [NSMutableArray array];

    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"# vplay-disc:"]) {
            meta.discKindName = [[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        } else if ([line hasPrefix:@"# vplay-title:"]) {
            meta.titleName = [[line substringFromIndex:14] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        } else if ([line hasPrefix:@"# vplay-menu:"]) {
            meta.isMenu = [[[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] intValue] != 0;
        } else if ([line hasPrefix:@"# vplay-duration:"]) {
            meta.duration = [[[line substringFromIndex:17] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] doubleValue];
        } else if ([line hasPrefix:@"# vplay-aspect:"]) {
            meta.aspectRatio = [[[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] doubleValue];
        } else if ([line hasPrefix:@"# vplay-palette:"]) {
            NSString *csv = [[line substringFromIndex:16] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            for (NSString *hex in [csv componentsSeparatedByString:@","]) {
                unsigned int val = 0;
                [[NSScanner scannerWithString:hex] scanHexInt:&val];
                [palette addObject:@(val)];
            }
        } else if ([line hasPrefix:@"# vplay-audio:"]) {
            NSArray<NSString *> *parts = [[[line substringFromIndex:14] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@"|"];
            if (parts.count >= 7) {
                VPDiscStreamInfo *as = [[VPDiscStreamInfo alloc] init];
                as.index = [parts[0] intValue];
                as.streamID = [parts[1] intValue];
                as.codecName = parts[2];
                as.language = parts[3];
                as.channels = [parts[4] intValue];
                as.sampleRate = [parts[5] intValue];
                as.title = parts[6];
                as.isSubtitle = NO;
                [audios addObject:as];
            }
        } else if ([line hasPrefix:@"# vplay-subp:"]) {
            NSArray<NSString *> *parts = [[[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@"|"];
            if (parts.count >= 5) {
                VPDiscStreamInfo *ss = [[VPDiscStreamInfo alloc] init];
                ss.index = [parts[0] intValue];
                ss.streamID = [parts[1] intValue];
                ss.codecName = parts[2];
                ss.language = parts[3];
                ss.title = parts[4];
                ss.isSubtitle = YES;
                [subs addObject:ss];
            }
        } else if ([line hasPrefix:@"# vplay-chapter:"]) {
            NSArray<NSString *> *parts = [[[line substringFromIndex:16] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@"|"];
            if (parts.count >= 4) {
                VPDiscChapter *ch = [[VPDiscChapter alloc] init];
                ch.index = [parts[0] integerValue];
                ch.startTime = [parts[1] doubleValue];
                ch.duration = [parts[2] doubleValue];
                ch.title = parts[3];
                [chaps addObject:ch];
            }
        } else if ([line hasPrefix:@"# vplay-cell:"]) {
            NSArray *parts = [[[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@"|"];
            if (parts.count == 4) {
                [cells addObject:@{@"first":@([parts[0] longLongValue]), @"last":@([parts[1] longLongValue]),
                    @"vob":@([parts[2] intValue]), @"cell":@([parts[3] intValue])}];
            }
        } else if ([line hasPrefix:@"file "]) {
            NSString *path = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([path hasPrefix:@"'"] && [path hasSuffix:@"'"] && path.length >= 2) {
                path = [path substringWithRange:NSMakeRange(1, path.length - 2)];
                path = [path stringByReplacingOccurrencesOfString:@"'\\''" withString:@"'"];
            }
            if (path.length) [segs addObject:[NSURL fileURLWithPath:path]];
        }
    }

    meta.dvdCells = cells;
    meta.paletteRGBA = palette;
    meta.audioStreams = audios;
    meta.subtitleStreams = subs;
    meta.chapters = chaps;
    meta.segmentURLs = segs;
    return meta;
}

+ (BOOL)isDiscImage:(NSURL *)url {
    if (!url.isFileURL) return NO;
    return [@[@"iso", @"img", @"toast", @"cdr", @"bin", @"nrg"] containsObject:url.pathExtension.lowercaseString ?: @""];
}

+ (NSString *)titleForDisc:(NSURL *)url {
    NSURL *root = [self resolveDiscRootForURL:url] ?: url;
    VPDiscKind kind = [self kindForURL:root];
    if (kind == VPDiscKindNone) kind = [self kindForURL:url];
    NSString *kindName = [self nameForKind:kind];
    NSString *volName = root.lastPathComponent ?: url.lastPathComponent ?: @"Disc";
    return [NSString stringWithFormat:@"%@ — %@", kindName, volName];
}

+ (NSArray<NSURL *> *)mountedDiscs {
    NSMutableArray<NSURL *> *discs = [NSMutableArray array];
    NSURL *volumes = [NSURL fileURLWithPath:@"/Volumes"];
    NSArray<NSURL *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:volumes
                                                               includingPropertiesForKeys:nil
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                    error:nil];
    for (NSURL *vol in children) {
        if ([self kindForURL:vol] != VPDiscKindNone) {
            [discs addObject:vol];
        }
    }
    return discs;
}

+ (void)mountImageAtURL:(NSURL *)url completion:(void (^)(NSURL *_Nullable volume, NSError *_Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
        task.arguments = @[@"attach", @"-plist", @"-nobrowse", @"-readonly", url.path];
        NSPipe *out = [NSPipe pipe];
        task.standardOutput = out;
        task.standardError = [NSPipe pipe];
        NSError *launchErr = nil;
        if (![task launchAndReturnError:&launchErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, launchErr);
            });
            return;
        }
        [task waitUntilExit];
        NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
        NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
        NSURL *mountedVolume = nil;
        for (NSDictionary *entity in plist[@"system-entities"]) {
            NSString *mountPoint = entity[@"mount-point"];
            if (mountPoint.length) {
                mountedVolume = [NSURL fileURLWithPath:mountPoint];
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (mountedVolume) {
                if (completion) completion(mountedVolume, nil);
            } else {
                NSError *err = [NSError errorWithDomain:@"VPlayErrorDomain" code:95 userInfo:@{
                    NSLocalizedDescriptionKey: @"Disk image could not be mounted."
                }];
                if (completion) completion(nil, err);
            }
        });
    });
}

+ (nullable NSArray<NSURL *> *)playableURLsForDisc:(NSURL *)url error:(NSError **)error {
    return [self playableURLsFromURL:url error:error];
}

#pragma mark - Complete Disc Structure Builder

+ (nullable VPDiscMenuStructure *)menuStructureForURL:(NSURL *)url {
    if (!url) return nil;
    if ([url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) {
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if ([line hasPrefix:@"# vplay-root:"]) {
                NSString *rootPath = [[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (rootPath.length) {
                    url = [NSURL fileURLWithPath:rootPath];
                    break;
                }
            }
        }
    }

    NSURL *discRoot = [self resolveDiscRootForURL:url];
    NSString *cacheKey = discRoot.path ?: url.path;
    @synchronized (gDiscMenuCache()) {
        if (gDiscMenuCache()[cacheKey]) return gDiscMenuCache()[cacheKey];
    }

    VPDiscKind kind = [self kindForURL:discRoot];
    if (kind == VPDiscKindNone) kind = [self kindForURL:url];
    if (kind == VPDiscKindNone) return nil;

    VPDiscMenuStructure *structure = [[VPDiscMenuStructure alloc] init];
    structure.discRootURL = discRoot;
    structure.kind = kind;
    structure.discName = discRoot.lastPathComponent ?: [self nameForKind:kind];

    NSMutableArray<VPDiscTitle *> *menus = [NSMutableArray array];
    NSMutableArray<VPDiscTitle *> *titles = [NSMutableArray array];

    if (kind == VPDiscKindDVD) {
        NSURL *videoTS = [self hasChildDirectory:@"VIDEO_TS" atURL:discRoot] ? [discRoot URLByAppendingPathComponent:@"VIDEO_TS"] : discRoot;
        NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:videoTS
                                                                includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:nil];
        // Check Top Menu (VIDEO_TS.VOB)
        NSURL *vmgIfo = [videoTS URLByAppendingPathComponent:@"VIDEO_TS.IFO"];
        NSURL *vmgVob = [videoTS URLByAppendingPathComponent:@"VIDEO_TS.VOB"];
        NSNumber *vmgSize = nil;
        [vmgVob getResourceValue:&vmgSize forKey:NSURLFileSizeKey error:nil];
        if (vmgSize.unsignedLongLongValue > 64 * 1024) {
            VPDiscTitle *topMenu = [[VPDiscTitle alloc] init];
            topMenu.index = 0;
            topMenu.title = @"DVD Top Menu (Title Menu)";
            topMenu.isMenu = YES;
            topMenu.aspectRatio = 16.0 / 9.0;
            topMenu.segmentURLs = @[vmgVob];
            [self parseDVDIFO:vmgIfo intoMenuTitle:topMenu featureTitle:nil];
            topMenu.playbackURL = [self writeFFConcatForTitle:topMenu discKind:VPDiscKindDVD discRoot:discRoot name:@"DVD-Top-Menu"];
            [menus addObject:topMenu];
        }

        // Group VTS_xx_y.VOB files by Title Set (01..99)
        NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *vtsVobs = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSURL *> *vtsMenuVobs = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSURL *> *vtsIfos = [NSMutableDictionary dictionary];

        for (NSURL *file in files) {
            NSString *upper = file.lastPathComponent.uppercaseString;
            if (![upper hasPrefix:@"VTS_"] || upper.length < 12) continue;
            NSString *tsKey = [upper substringWithRange:NSMakeRange(4, 2)];
            if ([upper hasSuffix:@"_0.IFO"]) {
                vtsIfos[tsKey] = file;
            } else if ([upper hasSuffix:@"_0.VOB"]) {
                NSNumber *sz = nil;
                [file getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                if (sz.unsignedLongLongValue > 64 * 1024) {
                    vtsMenuVobs[tsKey] = file;
                }
            } else if ([upper hasSuffix:@".VOB"]) {
                if (!vtsVobs[tsKey]) vtsVobs[tsKey] = [NSMutableArray array];
                [vtsVobs[tsKey] addObject:file];
            }
        }

        NSArray<NSString *> *sortedKeys = [vtsVobs.allKeys sortedArrayUsingSelector:@selector(compare:)];
        VPDiscTitle *longestTitle = nil;
        uint64_t longestBytes = 0;

        for (NSString *tsKey in sortedKeys) {
            NSArray<NSURL *> *segs = [vtsVobs[tsKey] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
                return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
            }];
            uint64_t totalBytes = 0;
            for (NSURL *u in segs) {
                NSNumber *sz = nil;
                [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                totalBytes += sz.unsignedLongLongValue;
            }
            if (totalBytes < 64 * 1024) continue;

            VPDiscTitle *feature = [[VPDiscTitle alloc] init];
            feature.index = titles.count + 1;
            feature.dvdProgramChain = 1;
            feature.isMenu = NO;
            feature.aspectRatio = 16.0 / 9.0;
            feature.segmentURLs = segs;

            VPDiscTitle *rootMenu = nil;
            if (vtsMenuVobs[tsKey]) {
                rootMenu = [[VPDiscTitle alloc] init];
                rootMenu.index = [tsKey integerValue];
                rootMenu.title = [NSString stringWithFormat:@"DVD Root Menu (Title Set %@)", tsKey];
                rootMenu.isMenu = YES;
                rootMenu.aspectRatio = 16.0 / 9.0;
                rootMenu.segmentURLs = @[vtsMenuVobs[tsKey]];
            }

            if (vtsIfos[tsKey]) {
                [self parseDVDIFO:vtsIfos[tsKey] intoMenuTitle:rootMenu featureTitle:feature];
            }

            if (rootMenu) {
                rootMenu.audioStreams = feature.audioStreams;
                rootMenu.clutPaletteRGBA = feature.clutPaletteRGBA;
                rootMenu.playbackURL = [self writeFFConcatForTitle:rootMenu discKind:VPDiscKindDVD discRoot:discRoot name:[NSString stringWithFormat:@"DVD-Menu-VTS-%@", tsKey]];
                [menus addObject:rootMenu];
            }

            int mins = (int)(feature.duration / 60.0);
            int secs = (int)fmod(feature.duration, 60.0);
            NSString *durStr = feature.duration > 0 ? [NSString stringWithFormat:@" (%d:%02d)", mins, secs] : @"";
            feature.title = [NSString stringWithFormat:@"Title %@%@ — %lu Chapters", tsKey, durStr, (unsigned long)feature.chapters.count];
            feature.playbackURL = [self writeFFConcatForTitle:feature discKind:VPDiscKindDVD discRoot:discRoot name:[NSString stringWithFormat:@"DVD-VTS-%@-PGC-1", tsKey]];
            [titles addObject:feature];

            NSData *ifoData = vtsIfos[tsKey] ? [NSData dataWithContentsOfURL:vtsIfos[tsKey]] : nil;
            if (ifoData.length >= 0xD0) {
                const uint8_t *ifoBytes = ifoData.bytes;
                uint64_t table = (uint64_t)VPReadBE32(ifoBytes + 0xCC) * 2048;
                if (table > 0 && table + 8 <= ifoData.length) {
                    NSUInteger chainCount = MIN(64, VPReadBE16(ifoBytes + table));
                    for (NSUInteger chain = 2; chain <= chainCount; chain++) {
                        VPDiscTitle *episode = [VPDiscTitle new];
                        episode.index = titles.count + 1;
                        episode.dvdProgramChain = chain;
                        episode.segmentURLs = segs;
                        [self parseDVDIFO:vtsIfos[tsKey] intoMenuTitle:nil featureTitle:episode];
                        if (!episode.dvdCells.count) continue;
                        episode.title = [NSString stringWithFormat:@"Title %ld — Program %lu (%d:%02d)",
                            (long)episode.index, (unsigned long)chain, (int)(episode.duration / 60), (int)fmod(episode.duration, 60)];
                        episode.playbackURL = [self writeFFConcatForTitle:episode discKind:VPDiscKindDVD discRoot:discRoot
                            name:[NSString stringWithFormat:@"DVD-VTS-%@-PGC-%lu", tsKey, (unsigned long)chain]];
                        [titles addObject:episode];
                    }
                }
            }
            if (totalBytes > longestBytes) {
                longestBytes = totalBytes;
                longestTitle = feature;
            }
        }
        if (longestTitle) {
            longestTitle.isMainFeature = YES;
            longestTitle.title = [longestTitle.title stringByAppendingString:@" ★ Main Feature"];
            longestTitle.playbackURL = [self writeFFConcatForTitle:longestTitle discKind:VPDiscKindDVD discRoot:discRoot name:[NSString stringWithFormat:@"DVD-Main-%02ld", (long)longestTitle.index]];
        }
    } else if (kind == VPDiscKindBluRay) {
        NSURL *bdmv = [self hasChildDirectory:@"BDMV" atURL:discRoot] ? [discRoot URLByAppendingPathComponent:@"BDMV"] : discRoot;
        NSURL *playlistDir = [bdmv URLByAppendingPathComponent:@"PLAYLIST"];
        NSURL *streamDir = [bdmv URLByAppendingPathComponent:@"STREAM"];

        NSArray<NSURL *> *mplsFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:playlistDir
                                                                    includingPropertiesForKeys:nil
                                                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                         error:nil];
        mplsFiles = [mplsFiles sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];

        NSMutableSet<NSString *> *seenSignatures = [NSMutableSet set];
        VPDiscTitle *longestTitle = nil;
        double longestDur = 0.0;
        NSInteger titleIdx = 1;

        for (NSURL *mpls in mplsFiles) {
            NSString *ext = mpls.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"mpls"]) continue;
            VPDiscTitle *t = [self parseBluRayMPLS:mpls streamDir:streamDir index:titleIdx];
            if (!t || t.segmentURLs.count == 0) continue;

            NSMutableArray<NSString *> *segNames = [NSMutableArray array];
            for (NSURL *u in t.segmentURLs) [segNames addObject:u.lastPathComponent];
            NSString *sig = [segNames componentsJoinedByString:@"+"];
            if ([seenSignatures containsObject:sig]) continue;
            [seenSignatures addObject:sig];

            NSString *playlistCode = mpls.URLByDeletingPathExtension.lastPathComponent;
            if (t.duration > 0 && t.duration < 90.0 && t.chapters.count <= 1) {
                t.isMenu = YES;
                t.title = [NSString stringWithFormat:@"Blu-ray Menu / Loop (%@ — %.0fs)", playlistCode, t.duration];
                t.playbackURL = [self writeFFConcatForTitle:t discKind:VPDiscKindBluRay discRoot:discRoot name:[NSString stringWithFormat:@"BD-Menu-%@", playlistCode]];
                [menus addObject:t];
            } else {
                t.index = titleIdx++;
                int mins = (int)(t.duration / 60.0);
                int secs = (int)fmod(t.duration, 60.0);
                t.title = [NSString stringWithFormat:@"Title %ld (%@) — %d:%02d (%lu Chapters)",
                           (long)t.index, playlistCode, mins, secs, (unsigned long)t.chapters.count];
                t.playbackURL = [self writeFFConcatForTitle:t discKind:VPDiscKindBluRay discRoot:discRoot name:[NSString stringWithFormat:@"BD-Title-%@", playlistCode]];
                [titles addObject:t];
                if (t.duration > longestDur) {
                    longestDur = t.duration;
                    longestTitle = t;
                }
            }
        }

        // Fallback if PLAYLIST folder was missing or empty: scan STREAM/*.m2ts directly
        if (titles.count == 0) {
            NSArray<NSURL *> *m2tsFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:streamDir
                                                                        includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                                           options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                             error:nil];
            for (NSURL *f in m2tsFiles) {
                if (![f.pathExtension.lowercaseString isEqualToString:@"m2ts"]) continue;
                VPDiscTitle *t = [[VPDiscTitle alloc] init];
                t.index = (NSInteger)titles.count + 1;
                t.title = [NSString stringWithFormat:@"Stream %@", f.lastPathComponent];
                t.aspectRatio = 16.0 / 9.0;
                t.segmentURLs = @[f];
                t.playbackURL = f;
                [titles addObject:t];
            }
            longestTitle = titles.firstObject;
        }

        if (longestTitle) {
            longestTitle.isMainFeature = YES;
            longestTitle.title = [longestTitle.title stringByAppendingString:@" ★ Main Feature"];
            if ([longestTitle.playbackURL.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) {
                longestTitle.playbackURL = [self writeFFConcatForTitle:longestTitle discKind:VPDiscKindBluRay discRoot:discRoot name:[NSString stringWithFormat:@"BD-Main-%ld", (long)longestTitle.index]];
            }
        }
    } else if (kind == VPDiscKindAudioCD) {
        NSArray<NSURL *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:discRoot
                                                                includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:nil];
        items = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];
        NSInteger idx = 1;
        for (NSURL *trackURL in items) {
            NSString *ext = trackURL.pathExtension.lowercaseString;
            if (![@[@"aiff", @"aif", @"cdda", @"wav", @"flac"] containsObject:ext]) continue;
            NSNumber *sz = nil;
            [trackURL getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
            double estSeconds = (sz.doubleValue > 44.0) ? ((sz.doubleValue - 44.0) / (44100.0 * 4.0)) : 0.0;
            VPDiscTitle *t = [[VPDiscTitle alloc] init];
            t.index = idx++;
            int mins = (int)(estSeconds / 60.0);
            int secs = (int)fmod(estSeconds, 60.0);
            t.title = [NSString stringWithFormat:@"Track %02ld — %@ (%d:%02d)", (long)t.index, trackURL.URLByDeletingPathExtension.lastPathComponent, mins, secs];
            t.duration = estSeconds;
            t.segmentURLs = @[trackURL];
            t.playbackURL = trackURL;
            t.isMainFeature = (t.index == 1);
            [titles addObject:t];
        }
    } else if (kind == VPDiscKindSVCD || kind == VPDiscKindVCD) {
        NSString *subDir = (kind == VPDiscKindSVCD) ? @"MPEG2" : @"MPEGAV";
        NSURL *dir = [self hasChildDirectory:subDir atURL:discRoot] ? [discRoot URLByAppendingPathComponent:subDir] : discRoot;
        NSArray<NSURL *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                                                includingPropertiesForKeys:nil
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:nil];
        items = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];
        NSInteger idx = 1;
        for (NSURL *f in items) {
            NSString *ext = f.pathExtension.lowercaseString;
            if (![@[@"mpg", @"mpeg", @"dat", @"vob"] containsObject:ext]) continue;
            VPDiscTitle *t = [[VPDiscTitle alloc] init];
            t.index = idx++;
            t.title = [NSString stringWithFormat:@"%@ Track %ld (%@)", [self nameForKind:kind], (long)t.index, f.lastPathComponent];
            t.aspectRatio = 4.0 / 3.0;
            t.segmentURLs = @[f];
            t.playbackURL = f;
            t.isMainFeature = (t.index == 1);
            [titles addObject:t];
        }
    }

    structure.menus = menus;
    structure.titles = titles;
    @synchronized (gDiscMenuCache()) {
        gDiscMenuCache()[cacheKey] = structure;
    }
    return structure;
}

#pragma mark - DVD navigation

+ (nullable NSURL *)dvdNavigationURLForURL:(NSURL *)url {
    if (!url.isFileURL || [url.pathExtension.lowercaseString isEqualToString:@"ffconcat"]) return nil;
    if ([self kindForURL:url] != VPDiscKindDVD) return nil;
    NSURL *root = [self resolveDiscRootForURL:url];
    NSURL *videoTS = [self hasChildDirectory:@"VIDEO_TS" atURL:root] ? [root URLByAppendingPathComponent:@"VIDEO_TS"] : root;
    // The navigation VM needs the disc's manager tables; without them this is loose VOB/IFO files.
    NSString *manager = [videoTS.path stringByAppendingPathComponent:@"VIDEO_TS.IFO"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:manager]) return nil;
    return videoTS;
}

#pragma mark - Playable URLs Entry Point

+ (nullable NSArray<NSURL *> *)playableURLsFromURL:(NSURL *)url error:(NSError **)error {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([@[@"iso", @"img", @"toast", @"cdr", @"bin", @"nrg"] containsObject:ext]) {
        return [self mountDiskImageAndResolve:url error:error];
    }

    // Direct .vob or .m2ts file selected by user
    if ([ext isEqualToString:@"vob"] || [ext isEqualToString:@"m2ts"]) {
        // Build structure in background cache so Disc Menu window & stream metadata are populated
        VPDiscMenuStructure *structure = [self menuStructureForURL:url];
        for (VPDiscTitle *t in [structure.titles arrayByAddingObjectsFromArray:structure.menus]) {
            if ([t.segmentURLs containsObject:url] && t.playbackURL) {
                return @[t.playbackURL];
            }
        }
        return @[url];
    }

    VPDiscMenuStructure *structure = [self menuStructureForURL:url];
    if (!structure) return @[url];

    NSMutableArray<NSURL *> *ordered = [NSMutableArray array];
    // Put Main Feature first so playback starts immediately on the main title,
    // followed by all other titles and disc menus so the user can switch to any menu or title!
    if (structure.mainTitle.playbackURL) {
        [ordered addObject:structure.mainTitle.playbackURL];
    }
    for (VPDiscTitle *t in structure.titles) {
        if (t.playbackURL && ![ordered containsObject:t.playbackURL]) {
            [ordered addObject:t.playbackURL];
        }
    }
    for (VPDiscTitle *m in structure.menus) {
        if (m.playbackURL && ![ordered containsObject:m.playbackURL]) {
            [ordered addObject:m.playbackURL];
        }
    }

    if (ordered.count > 0) return ordered;
    if (error) {
        *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:91 userInfo:@{
            NSLocalizedDescriptionKey: @"No playable streams were found on the selected disc."
        }];
    }
    return nil;
}

+ (nullable NSArray<NSURL *> *)mountDiskImageAndResolve:(NSURL *)imageURL error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
    task.arguments = @[@"attach", @"-plist", @"-nobrowse", @"-readonly", imageURL.path];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:error]) return nil;
    [task waitUntilExit];
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    for (NSDictionary *entity in plist[@"system-entities"]) {
        NSString *mountPoint = entity[@"mount-point"];
        if (mountPoint.length) {
            return [self playableURLsFromURL:[NSURL fileURLWithPath:mountPoint] error:error];
        }
    }
    if (error) {
        *error = [NSError errorWithDomain:@"VPlayErrorDomain" code:95 userInfo:@{
            NSLocalizedDescriptionKey: @"Disk image could not be mounted."
        }];
    }
    return nil;
}

@end
