#import "ColorProfiles.h"
#import <ImageIO/ImageIO.h>

NSNotificationName const MTBackgroundChanged = @"MTBackgroundChanged";
NSNotificationName const MTProfilesChanged = @"MTProfilesChanged";
typedef struct { uint32_t rgb[MTColorCount]; } MTColors;
#define ORIGINAL 0x161616,0xb64040,0x419849,0xc09835,0x527dcc,0xa458ac,0x389696,0xc8c8c8,0x747474,0xff7676,0x75d581,0xedd274,0x88abff,0xd68cdc,0x78dddd,0xffffff
#define SOLARIZED 0x073642,0xdc322f,0x859900,0xb58900,0x268bd2,0xd33682,0x2aa198,0xeee8d5,0x002b36,0xcb4b16,0x586e75,0x657b83,0x839496,0x6c71c4,0x93a1a1,0xfdf6e3
#define TANGO 0x2e3436,0xcc0000,0x4e9a06,0xc4a000,0x3465a4,0x75507b,0x06989a,0xd3d7cf,0x555753,0xef2929,0x8ae234,0xfce94f,0x729fcf,0xad7fa8,0x34e2e2,0xeeeeec
static const MTColors presets[] = {
    {{ORIGINAL,0xeeeeee,0x161616,0xffffff,0xb3d7ff,0x161616}},
    {{TANGO,0x222222,0xffffff,0x222222,0xb3d7ff,0x101010}},
    {{0x000000,0xff7777,0x99ff99,0xffff66,0x99bbff,0xff99ff,0x77ffff,0xffffff,
      0xaaaaaa,0xffaaaa,0xbbffbb,0xffffaa,0xbbccff,0xffbbff,0xbbffff,0xffffff,
      0xffffff,0x000000,0xffff00,0xffff00,0x000000}},
    {{SOLARIZED,0x839496,0x002b36,0x93a1a1,0x073642,0xfdf6e3}},
    {{SOLARIZED,0x657b83,0xfdf6e3,0x586e75,0xeee8d5,0x073642}},
    {{TANGO,0xd3d7cf,0x2e3436,0xeeeeec,0x3465a4,0xffffff}},
    {{TANGO,0x2e3436,0xeeeeec,0x2e3436,0x729fcf,0x000000}}
};

static NSColor *MTColorFromRGB(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0 alpha:1];
}
static uint32_t PackedColor(NSColor *color) {
    NSColor *s = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return ((uint32_t)lround(MAX(0,MIN(1,s.redComponent))*255) << 16) |
           ((uint32_t)lround(MAX(0,MIN(1,s.greenComponent))*255) << 8) |
            (uint32_t)lround(MAX(0,MIN(1,s.blueComponent))*255);
}

@implementation MTPalette {
    MTColors _values;
    NSColor *_cache[MTColorCount];
}
+ (NSArray *)presetNames {
    return @[@"Sombre", @"Clair", @"Contraste élevé", @"Solarized Dark", @"Solarized Light", @"Tango Dark", @"Tango Light"];
}
- (instancetype)initWithValues:(MTColors)values {
    if ((self = [super init])) _values = values;
    return self;
}
+ (instancetype)preset:(NSUInteger)index {
    return [[self alloc] initWithValues:presets[index]];
}
- (NSInteger)presetIndex {
    for (NSUInteger i = 0; i < sizeof(presets)/sizeof(*presets); i++)
        if (!memcmp(&_values, &presets[i], sizeof(_values))) return i;
    return -1;
}
- (NSColor *)color:(NSUInteger)slot {
    if (!_cache[slot]) _cache[slot] = MTColorFromRGB(_values.rgb[slot]);
    return _cache[slot];
}
- (NSColor *)resolve:(uint32_t)value {
    return value >= MTPaletteReference ? [self color:value - MTPaletteReference] : MTColorFromRGB(value);
}
- (instancetype)replacing:(NSUInteger)slot withColor:(NSColor *)color {
    MTColors updated = _values;
    updated.rgb[slot] = PackedColor(color);
    return [[MTPalette alloc] initWithValues:updated];
}
- (NSData *)data { return [NSData dataWithBytes:&_values length:sizeof(_values)]; }
+ (instancetype)fromData:(id)data fallback:(NSUInteger)preset {
    if (![data isKindOfClass:NSData.class] || [data length] != sizeof(MTColors)) return [self preset:preset];
    MTColors values;
    [data getBytes:&values length:sizeof(values)];
    return [[self alloc] initWithValues:values];
}
static BOOL ReadColor(id entry, uint32_t *result) {
    if (![entry isKindOfClass:NSDictionary.class]) return NO;
    CGFloat components[4] = {0,0,0,1};
    NSUInteger i = 0;
    for (NSString *key in @[@"Red Component", @"Green Component", @"Blue Component"]) {
        id component = entry[key];
        double value;
        if ([component isKindOfClass:NSNumber.class]) {
            value = [component doubleValue];
        } else if ([component isKindOfClass:NSString.class]) {
            NSScanner *scanner = [NSScanner scannerWithString:component];
            if (![scanner scanDouble:&value] || !scanner.isAtEnd) return NO;
        } else {
            return NO;
        }
        if (!isfinite(value) || value < 0 || value > 1) return NO;
        components[i++] = value;
    }
    NSString *model = entry[@"Color Space"];
    NSColorSpace *space = NSColorSpace.genericRGBColorSpace;
    if ([model isEqual:@"sRGB"]) space = NSColorSpace.sRGBColorSpace;
    if ([model isEqual:@"P3"] || [model isEqual:@"Display P3"]) space = NSColorSpace.displayP3ColorSpace;
    *result = PackedColor([NSColor colorWithColorSpace:space components:components count:4]);
    return YES;
}

- (NSDictionary *)palettesFromPlist:(NSDictionary *)plist {
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    NSArray *roles = @[@"Foreground Color", @"Background Color", @"Cursor Color", @"Selection Color", @"Selected Text Color"];
    NSArray *suffixes = @[@"", @" (Light)", @" (Dark)"];
    NSMutableDictionary *palettes = [NSMutableDictionary dictionary];
    MTColors base = _values;
    for (NSString *suffix in suffixes) {
        MTColors values = base;
        BOOL found = NO;
        for (NSUInteger i = 0; i < MTColorCount; i++) {
            NSString *key = i < 16 ? [NSString stringWithFormat:@"Ansi %lu Color", (unsigned long)i] : roles[i-16];
            id entry = plist[[key stringByAppendingString:suffix]];
            if (!entry) continue;
            if (!ReadColor(entry, &values.rgb[i])) return nil;
            found = YES;
        }
        if (found) {
            palettes[suffix] = [[MTPalette alloc] initWithValues:values];
            if (!suffix.length) base = values;
        }
    }
    return palettes.count ? palettes : nil;
}

- (NSDictionary *)importURL:(NSURL *)url error:(NSError **)error {
    NSNumber *size;
    if (![url getResourceValue:&size forKey:NSURLFileSizeKey error:error]) return nil;
    if (size.unsignedLongLongValue <= 1024*1024) {
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
        if (!data) return nil;
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
        if (!plist) return nil;
        NSDictionary *palettes = [self palettesFromPlist:plist];
        if (palettes) return palettes;
    }
    if (error) *error = [NSError errorWithDomain:@"mTerm.Profils" code:1 userInfo:@{
        NSLocalizedDescriptionKey:@"Le fichier doit contenir des couleurs iTerm2 valides et faire au plus 1 Mo."}];
    return nil;
}
@end

@implementation MTBackgroundImage
+ (instancetype)imageAtPath:(NSString *)path {
    if (!path.length) return nil;
    static NSMapTable<NSString *, MTBackgroundImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = NSMapTable.strongToWeakObjectsMapTable; });
    MTBackgroundImage *image = [cache objectForKey:path];
    if (image) return image;
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceShouldCache:@NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                         (__bridge CFDictionaryRef)options);
    if (!source) return nil;
    NSDictionary *thumbnail = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@2048,
                                (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES};
    CGImageRef pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbnail);
    CFRelease(source);
    if (!pixels) return nil;
    image = [self new];
    image->_pixels = pixels;
    image->_path = [path copy];
    [cache setObject:image forKey:path];
    return image;
}
- (void)dealloc { if (_pixels) CGImageRelease(_pixels); }
@end

@implementation MTProfile
- (instancetype)initWithRecord:(NSDictionary *)record {
    if ((self = [super init])) {
        _identifier = [record[@"id"] copy] ?: NSUUID.UUID.UUIDString;
        _name = [record[@"name"] copy] ?: @"Défaut";
        _light = [MTPalette fromData:record[@"palette"] fallback:0];
        _dark = record[@"dark"] ? [MTPalette fromData:record[@"dark"] fallback:0] : _light;
        NSNumber *opacity = record[@"backgroundOpacity"];
        _backgroundOpacity = opacity ? MAX(0, MIN(100, opacity.integerValue)) : 100;
        _imagePath = [record[@"imagePath"] copy];
        _separate = [record[@"separate"] boolValue];
    }
    return self;
}
- (NSDictionary *)record {
    NSMutableDictionary *record = [@{@"id":_identifier, @"name":_name, @"palette":_light.data,
                                     @"dark":_dark.data, @"separate":@(_separate),
                                     @"backgroundOpacity":@(_backgroundOpacity)} mutableCopy];
    if (_imagePath.length) record[@"imagePath"] = _imagePath;
    return record;
}
- (MTPalette *)paletteForAppearance:(NSAppearance *)appearance {
    if (!_separate) return _light;
    NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]];
    return [match isEqual:NSAppearanceNameDarkAqua] ? _dark : _light;
}
@end

@implementation MTProfiles {
    NSMutableArray<MTProfile *> *_items;
}
+ (instancetype)shared {
    static MTProfiles *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [self new]; });
    return store;
}
- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray array];
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"ColorProfiles"];
        for (NSDictionary *record in saved[@"items"]) {
            MTProfile *p = [[MTProfile alloc] initWithRecord:record];
            [_items addObject:p];
            if ([p.identifier isEqual:saved[@"default"]]) _defaultProfile = p;
        }
        if (!_items.count) [_items addObject:[[MTProfile alloc] initWithRecord:nil]];
        if (!_defaultProfile) _defaultProfile = _items.firstObject;
    }
    return self;
}
- (NSDictionary *)importedPresets {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"ImportedColorPresets"] ?: @{};
}
- (NSString *)storePreset:(MTPalette *)palette named:(NSString *)name {
    NSMutableDictionary *imports = [self.importedPresets mutableCopy];
    NSString *unique = name;
    for (NSUInteger i = 2; imports[unique] || [MTPalette.presetNames containsObject:unique] || [unique isEqual:@"Personnalisé"]; i++)
        unique = [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)i];
    imports[unique] = palette.data;
    [NSUserDefaults.standardUserDefaults setObject:imports forKey:@"ImportedColorPresets"];
    return unique;
}
- (MTPalette *)importedPaletteNamed:(NSString *)name {
    return [MTPalette fromData:self.importedPresets[name] fallback:0];
}
- (NSArray *)profiles { return _items; }
- (MTProfile *)addCopyOf:(MTProfile *)source {
    MTProfile *p = [[MTProfile alloc] initWithRecord:nil];
    p.name = source ? [source.name stringByAppendingString:@" — copie"] : @"Nouveau profil";
    if (source) {
        p.light = source.light;
        p.dark = source.dark;
        p.separate = source.separate;
        p.imagePath = source.imagePath;
        p.backgroundOpacity = source.backgroundOpacity;
    }
    [_items addObject:p];
    [self save];
    return p;
}
- (void)remove:(MTProfile *)profile {
    if (_items.count <= 1) return;
    [_items removeObject:profile];
    if (_defaultProfile == profile) _defaultProfile = _items.firstObject;
    [self save];
}
- (void)save {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:_items.count];
    for (MTProfile *p in _items) [items addObject:p.record];
    [NSUserDefaults.standardUserDefaults setObject:@{@"items":items, @"default":_defaultProfile.identifier} forKey:@"ColorProfiles"];
    [NSNotificationCenter.defaultCenter postNotificationName:MTProfilesChanged object:self];
}
@end
