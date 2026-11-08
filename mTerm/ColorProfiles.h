#import <AppKit/AppKit.h>

typedef NS_ENUM(NSUInteger, MTColorSlot) {
    MTForeground = 16, MTBackground, MTCursor, MTSelection, MTSelectedText, MTColorCount
};
// Au-delà du RGB 24 bits, le moteur renvoie un indice de palette.
enum { MTPaletteReference = 0x1000000 };

@interface MTPalette : NSObject
@property(readonly) NSData *data;
+ (NSArray<NSString *> *)presetNames;
+ (instancetype)preset:(NSUInteger)index;
- (NSInteger)presetIndex;
- (NSColor *)color:(NSUInteger)slot;
- (NSColor *)resolve:(uint32_t)value;
- (instancetype)replacing:(NSUInteger)slot withColor:(NSColor *)color;
- (NSDictionary<NSString *, MTPalette *> *)importURL:(NSURL *)url error:(NSError **)error;
@end

@interface MTProfile : NSObject
@property(copy) NSString *name;
@property(readonly) NSString *identifier;
@property(strong) MTPalette *light, *dark;
@property BOOL separate;
- (MTPalette *)paletteForAppearance:(NSAppearance *)appearance;
@end

extern NSNotificationName const MTProfilesChanged;
@interface MTProfiles : NSObject
+ (instancetype)shared;
@property(readonly) NSArray<MTProfile *> *profiles;
@property(strong) MTProfile *defaultProfile;
@property(readonly) NSDictionary<NSString *, NSData *> *importedPresets;
- (NSString *)storePreset:(MTPalette *)palette named:(NSString *)name;
- (MTPalette *)importedPaletteNamed:(NSString *)name;
- (MTProfile *)addCopyOf:(MTProfile *)source;
- (void)remove:(MTProfile *)profile;
- (void)save;
@end

void MTShowColorSettings(void);
