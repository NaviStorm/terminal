#import "ColorProfiles.h"
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MTSettingsCanvas : NSView
@end
@implementation MTSettingsCanvas
- (BOOL)isFlipped { return YES; }
@end

@interface MTOpacitySlider : NSSlider
@property(readonly) BOOL trackingMouse;
@end
@implementation MTOpacitySlider
- (void)mouseDown:(NSEvent *)event {
    _trackingMouse = YES;
    double previous = self.doubleValue;
    [super mouseDown:event];
    _trackingMouse = NO;
    if (self.doubleValue != previous) [MTProfiles.shared save];
}
@end

@interface MTColorSettings : NSWindowController <NSWindowDelegate,NSTableViewDelegate,NSTableViewDataSource,NSTextFieldDelegate>
@end

static MTColorSettings *openSettings;
void MTShowColorSettings(void) {
    if (!openSettings) openSettings = [MTColorSettings new];
    [openSettings showWindow:nil];
    [openSettings.window makeKeyAndOrderFront:nil];
}

@implementation MTColorSettings {
    MTProfile *_profile;
    NSTableView *_list;
    MTOpacitySlider *_opacity;
    NSTextField *_percentage, *_imageName;
    NSButton *_removeImage;
    CALayer *_previewBackground;
    MTBackgroundImage *_previewImage;
    NSTextField *_name, *_preview;
    NSButton *_separate, *_makeDefault, *_remove;
    NSSegmentedControl *_mode;
    NSPopUpButton *_presets;
    NSMutableArray<NSColorWell *> *_wells;
    BOOL _refreshing;
}

- (void)add:(NSView *)view frame:(NSRect)frame {
    view.frame = frame;
    [self.window.contentView addSubview:view];
}

- (void)label:(NSString *)title x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    [self add:[NSTextField labelWithString:title] frame:NSMakeRect(x,y,width,20)];
}

- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    [self add:button frame:frame];
    return button;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,770,565)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    if ((self = [super initWithWindow:window])) {
        window.title = @"Réglages — Profils de couleurs";
        window.releasedWhenClosed = NO;
        window.tabbingMode = NSWindowTabbingModeDisallowed;
        window.delegate = self;
        window.contentView = [[MTSettingsCanvas alloc] initWithFrame:window.contentView.bounds];
        _profile = MTProfiles.shared.defaultProfile;
        [self buildControls];
        [self reload];
        [window center];
    }
    return self;
}

- (void)buildControls {
    [self label:@"Profils" x:16 y:17 width:160];
    _list = [NSTableView new];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"profil"];
    column.width = 174;
    [_list addTableColumn:column];
    _list.headerView = nil;
    _list.allowsEmptySelection = NO;
    _list.rowHeight = 24;
    _list.delegate = self;
    _list.dataSource = self;
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _list;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    [self add:scroll frame:NSMakeRect(14,45,192,355)];
    [self button:@"+" action:@selector(addProfile:) frame:NSMakeRect(12,405,36,28)];
    _remove = [self button:@"−" action:@selector(removeProfile:) frame:NSMakeRect(48,405,36,28)];
    [self button:@"Dupliquer" action:@selector(duplicateProfile:) frame:NSMakeRect(88,405,119,28)];
    _makeDefault = [self button:@"Définir par défaut" action:@selector(makeDefault:) frame:NSMakeRect(12,445,194,30)];

    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    [self add:line frame:NSMakeRect(220,0,1,565)];
    [self label:@"Nom du profil" x:241 y:20 width:120];
    _name = [NSTextField new];
    _name.delegate = self;
    [self add:_name frame:NSMakeRect(378,16,366,25)];
    _separate = [NSButton checkboxWithTitle:@"Couleurs distinctes en mode clair et sombre" target:self action:@selector(changeSeparate:)];
    [self add:_separate frame:NSMakeRect(239,57,505,24)];
    [self label:@"Palette à modifier" x:241 y:97 width:135];
    _mode = [NSSegmentedControl segmentedControlWithLabels:@[@"Clair",@"Sombre"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMode:)];
    [self add:_mode frame:NSMakeRect(377,92,180,28)];
    [self label:@"Préréglage" x:241 y:138 width:120];
    _presets = [NSPopUpButton new];
    _presets.target = self;
    _presets.action = @selector(changePreset:);
    [self add:_presets frame:NSMakeRect(375,132,370,30)];
    _wells = [NSMutableArray arrayWithCapacity:MTColorCount];
    NSArray *ansi = @[@"Noir",@"Rouge",@"Vert",@"Jaune",@"Bleu",@"Magenta",@"Cyan",@"Blanc"];
    NSArray *roles = @[@"Texte",@"Fond",@"Curseur",@"Sélection",@"Texte sélectionné"];
    for (NSUInteger i = 0; i < MTColorCount; i++) {
        NSColorWell *well = [NSColorWell new];
        well.tag = i;
        well.target = self;
        well.action = @selector(editColor:);
        NSString *title;
        NSRect rect;
        if (i < 16) {
            title = [NSString stringWithFormat:@"ANSI %lu · %@%@",(unsigned long)i,ansi[i%8],i >= 8 ? @" intense" : @""];
            rect = NSMakeRect(318 + (i%8)*53,307 + (i/8)*35,48,27);
        } else {
            NSUInteger role = i - MTForeground;
            title = roles[role];
            CGFloat x = 241 + (role%3)*169, y = 180 + (role/3)*36;
            [self label:title x:x y:y+4 width:111];
            rect = NSMakeRect(x+112,y,45,26);
        }
        well.toolTip = title;
        [well setAccessibilityLabel:title];
        [self add:well frame:rect];
        [_wells addObject:well];
    }
    [self label:@"Palette ANSI" x:241 y:277 width:170];
    [self label:@"Normales" x:241 y:312 width:75];
    [self label:@"Intenses" x:241 y:347 width:75];
    [self label:@"Image de fond" x:241 y:389 width:130];
    _imageName = [NSTextField labelWithString:@""];
    _imageName.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self add:_imageName frame:NSMakeRect(378,389,159,20)];
    [self button:@"Choisir…" action:@selector(chooseImage:) frame:NSMakeRect(538,383,98,30)];
    _removeImage = [self button:@"Retirer" action:@selector(removeImage:) frame:NSMakeRect(640,383,106,30)];
    [self label:@"Opacité du fond" x:241 y:432 width:135];
    _opacity = [MTOpacitySlider new];
    _opacity.minValue = 0;
    _opacity.maxValue = 100;
    _opacity.continuous = YES;
    _opacity.target = self;
    _opacity.action = @selector(changeOpacity:);
    [_opacity setAccessibilityLabel:@"Opacité du fond en pourcentage"];
    [self add:_opacity frame:NSMakeRect(375,425,307,28)];
    _percentage = [NSTextField labelWithString:@""];
    _percentage.alignment = NSTextAlignmentRight;
    [self add:_percentage frame:NSMakeRect(685,431,60,20)];
    [self label:@"Aperçu" x:241 y:474 width:100];
    NSView *previewHost = [[NSView alloc] initWithFrame:NSMakeRect(241,501,504,33)];
    previewHost.wantsLayer = YES;
    _previewBackground = [CALayer layer];
    _previewBackground.frame = previewHost.bounds;
    _previewBackground.contentsGravity = kCAGravityResizeAspectFill;
    _previewBackground.masksToBounds = YES;
    [previewHost.layer addSublayer:_previewBackground];
    [self.window.contentView addSubview:previewHost];
    _preview = [NSTextField labelWithString:@""];
    _preview.alignment = NSTextAlignmentCenter;
    [self add:_preview frame:NSMakeRect(241,501,504,33)];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return MTProfiles.shared.profiles.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    MTProfile *p = MTProfiles.shared.profiles[row];
    return p == MTProfiles.shared.defaultProfile ? [@"★  " stringByAppendingString:p.name] : p.name;
}
- (void)tableViewSelectionDidChange:(NSNotification *)note {
    if (_refreshing || _list.selectedRow < 0) return;
    _profile = MTProfiles.shared.profiles[_list.selectedRow];
    [self reload];
}
- (MTPalette *)palette {
    return _profile.separate && _mode.selectedSegment == 1 ? _profile.dark : _profile.light;
}
- (void)applyPalette:(MTPalette *)palette {
    if (_profile.separate && _mode.selectedSegment == 1) _profile.dark = palette;
    else _profile.light = palette;
    [MTProfiles.shared save];
    [self reload];
}
- (void)reload {
    _refreshing = YES;
    [_list reloadData];
    NSUInteger row = [MTProfiles.shared.profiles indexOfObject:_profile];
    [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_list scrollRowToVisible:row];
    _name.stringValue = _profile.name;
    _separate.state = _profile.separate;
    _mode.enabled = _profile.separate;
    if (!_profile.separate || _mode.selectedSegment < 0) _mode.selectedSegment = 0;
    _makeDefault.enabled = _profile != MTProfiles.shared.defaultProfile;
    _remove.enabled = MTProfiles.shared.profiles.count > 1;
    [_presets removeAllItems];
    [_presets addItemsWithTitles:MTPalette.presetNames];
    NSDictionary *imports = MTProfiles.shared.importedPresets;
    NSArray *names = [imports.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [_presets addItemsWithTitles:names];
    MTPalette *palette = self.palette;
    NSInteger index = palette.presetIndex;
    if (index < 0) {
        NSData *data = palette.data;
        for (NSString *name in names) {
            if ([imports[name] isEqual:data]) {
                index = [_presets indexOfItemWithTitle:name];
                break;
            }
        }
    }
    if (index < 0) { [_presets addItemWithTitle:@"Personnalisé"]; index = _presets.numberOfItems - 1; }
    [_presets.menu addItem:NSMenuItem.separatorItem];
    [_presets addItemWithTitle:@"Importer un fichier .itermcolors…"];
    [_presets selectItemAtIndex:index];
    for (NSColorWell *well in _wells) well.color = [palette color:well.tag];
    _imageName.stringValue = _profile.imagePath.lastPathComponent ?: @"Aucune";
    _imageName.toolTip = _profile.imagePath;
    _removeImage.enabled = _profile.imagePath.length > 0;
    _opacity.integerValue = _profile.backgroundOpacity;
    _previewBackground.backgroundColor = [palette color:MTBackground].CGColor;
    [self refreshPreviewBackground];
    NSMutableAttributedString *sample = [[NSMutableAttributedString alloc] initWithString:@"❯  mTerm   Documents   sélection   ▏"
        attributes:@{NSForegroundColorAttributeName:[palette color:MTForeground],NSFontAttributeName:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]}];
    for (NSString *part in @[@"Documents",@"sélection",@"▏"]) {
        NSRange r = [sample.string rangeOfString:part];
        NSUInteger slot = [part isEqual:@"Documents"] ? 4 : ([part isEqual:@"▏"] ? MTCursor : MTSelectedText);
        [sample addAttribute:NSForegroundColorAttributeName value:[palette color:slot] range:r];
        if (slot == MTSelectedText) [sample addAttribute:NSBackgroundColorAttributeName value:[palette color:MTSelection] range:r];
    }
    _preview.attributedStringValue = sample;
    _refreshing = NO;
}

- (void)refreshPreviewBackground {
    _percentage.stringValue = [NSString stringWithFormat:@"%ld %%", (long)_profile.backgroundOpacity];
    _previewImage = _profile.backgroundOpacity ? [MTBackgroundImage imageAtPath:_profile.imagePath] : nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _previewBackground.contents = (__bridge id)_previewImage.pixels;
    _previewBackground.opacity = _profile.backgroundOpacity / 100.0;
    [CATransaction commit];
}

- (void)changeOpacity:(MTOpacitySlider *)slider {
    NSInteger value = lround(slider.doubleValue);
    if (_profile.backgroundOpacity == value) return;
    _profile.backgroundOpacity = value;
    [self refreshPreviewBackground];
    if (slider.trackingMouse)
        [NSNotificationCenter.defaultCenter postNotificationName:MTBackgroundChanged object:_profile];
    else [MTProfiles.shared save];
}

- (void)chooseImage:(id)sender {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowedContentTypes = @[UTTypeImage];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSString *path = panel.URL.URLByResolvingSymlinksInPath.path;
        MTBackgroundImage *image = [MTBackgroundImage imageAtPath:path];
        if (!image) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Impossible de lire cette image.";
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        self->_profile.imagePath = path;
        self->_previewImage = image;
        [MTProfiles.shared save];
        [self reload];
    }];
}

- (void)removeImage:(id)sender {
    _profile.imagePath = nil;
    [MTProfiles.shared save];
    [self reload];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    NSString *name = [_name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) _profile.name = name;
    [MTProfiles.shared save];
    [self reload];
}
- (void)addProfile:(id)sender { _profile = [MTProfiles.shared addCopyOf:nil]; [self reload]; }
- (void)duplicateProfile:(id)sender { _profile = [MTProfiles.shared addCopyOf:_profile]; [self reload]; }
- (void)removeProfile:(id)sender {
    [MTProfiles.shared remove:_profile];
    _profile = MTProfiles.shared.defaultProfile;
    [self reload];
}
- (void)makeDefault:(id)sender {
    MTProfiles.shared.defaultProfile = _profile;
    [MTProfiles.shared save];
    [self reload];
}
- (void)changeSeparate:(id)sender {
    _profile.separate = _separate.state == NSControlStateValueOn;
    [MTProfiles.shared save];
    [self reload];
}
- (void)changeMode:(id)sender { [self reload]; }
- (void)editColor:(NSColorWell *)sender { [self applyPalette:[self.palette replacing:sender.tag withColor:sender.color]]; }

- (void)changePreset:(id)sender {
    NSInteger index = _presets.indexOfSelectedItem;
    if (index == _presets.numberOfItems - 1) {
        [self reload];
        NSOpenPanel *panel = NSOpenPanel.openPanel;
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"itermcolors"]];
        [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
            if (result != NSModalResponseOK) return;
            NSError *error = nil;
            NSDictionary *imported = [self.palette importURL:panel.URL error:&error];
            if (!imported) {
                [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
                return;
            }
            NSString *name = panel.URL.URLByDeletingPathExtension.lastPathComponent;
            if (imported[@" (Light)"] || imported[@" (Dark)"]) {
                _profile.light = imported[@" (Light)"] ?: imported[@""] ?: _profile.light;
                _profile.dark = imported[@" (Dark)"] ?: imported[@""] ?: _profile.dark;
                _profile.separate = YES;
                [MTProfiles.shared storePreset:_profile.light named:[name stringByAppendingString:@" — clair"]];
                [MTProfiles.shared storePreset:_profile.dark named:[name stringByAppendingString:@" — sombre"]];
                [MTProfiles.shared save];
                [self reload];
            } else {
                [MTProfiles.shared storePreset:imported[@""] named:name];
                [self applyPalette:imported[@""]];
            }
        }];
    } else if (index < (NSInteger)MTPalette.presetNames.count) {
        [self applyPalette:[MTPalette preset:index]];
    } else if (MTProfiles.shared.importedPresets[_presets.titleOfSelectedItem]) {
        [self applyPalette:[MTProfiles.shared importedPaletteNamed:_presets.titleOfSelectedItem]];
    }
}
- (void)windowWillClose:(NSNotification *)note {
    [self.window makeFirstResponder:nil];
    for (NSColorWell *well in _wells) [well deactivate];
    openSettings = nil;
}
@end
