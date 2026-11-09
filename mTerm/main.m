#import <AppKit/AppKit.h>
#import "TerminalView.h"
#import "ColorProfiles.h"

static NSString *const terminalFrameName = @"TerminalWindow";

static char tabOrderContext;

@interface MTTerminalWindow : NSWindow
- (void)observeTabOrder;
@end

@implementation MTTerminalWindow
- (void)observeTabOrder {
    [self addObserver:self forKeyPath:@"tabGroup.windows" options:NSKeyValueObservingOptionInitial context:&tabOrderContext];
}

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == &tabOrderContext) [self styleTabAsActive:self.mainWindow];
    else [super observeValueForKeyPath:path ofObject:object change:change context:context];
}

- (void)styleTabAsActive:(BOOL)active {
    NSString *marker = active ? @"●  " : @"○  ";
    NSFontWeight weight = active ? NSFontWeightBold : NSFontWeightMedium;
    NSArray *windows = self.tabGroup.windows;
    NSUInteger index = [windows indexOfObjectIdenticalTo:self];
    NSString *tabTitle = [NSString stringWithFormat:@"%@ #%lu", self.title, (unsigned long)(index == NSNotFound ? 1 : index + 1)];
    self.tab.title = tabTitle;
    NSMutableAttributedString *label = [[NSMutableAttributedString alloc]
        initWithString:[marker stringByAppendingString:tabTitle]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:NSFont.systemFontSize weight:weight],
                     NSForegroundColorAttributeName:NSColor.labelColor}];
    if (active) [label addAttribute:NSForegroundColorAttributeName value:NSColor.controlAccentColor range:NSMakeRange(0,1)];
    self.tab.attributedTitle = label;
}

- (void)becomeMainWindow {
    [super becomeMainWindow];
    [self styleTabAsActive:YES];
}

- (void)resignMainWindow {
    [super resignMainWindow];
    [self styleTabAsActive:NO];
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    self.tab.toolTip = title;
    [self styleTabAsActive:self.mainWindow];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSSplitViewDelegate, NSMenuItemValidation, MTTerminalWindowDelegate>
@end

@implementation AppDelegate {
    NSMutableSet<NSWindow *> *_windows;
    NSHashTable<NSWindow *> *_fullScreenTransitions;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSMenu *bar = [NSMenu new];
    NSMenu *app = [NSMenu new];
    [bar addItemWithTitle:@"mTerm" action:nil keyEquivalent:@""].submenu = app;
    [app addItemWithTitle:@"Réglages…" action:@selector(showSettings:) keyEquivalent:@","].target = self;
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Masquer mTerm" action:@selector(hide:) keyEquivalent:@"h"].target = NSApp;
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Quitter mTerm" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenu *session = [[NSMenu alloc] initWithTitle:@"Session"];
    [bar addItemWithTitle:@"Session" action:nil keyEquivalent:@""].submenu = session;
    [session addItemWithTitle:@"Nouvelle fenêtre" action:@selector(newWindow:) keyEquivalent:@"n"].target = self;
    [session addItemWithTitle:@"Nouvel onglet" action:@selector(newTab:) keyEquivalent:@"t"].target = self;
    [session addItemWithTitle:@"Scinder verticalement" action:@selector(splitVertically:) keyEquivalent:@"d"].target = self;
    NSMenuItem *horizontal = [session addItemWithTitle:@"Scinder horizontalement" action:@selector(splitHorizontally:) keyEquivalent:@"d"];
    horizontal.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    horizontal.target = self;
    NSMenu *navigation = [[NSMenu alloc] initWithTitle:@"Activer un volet"];
    [session addItemWithTitle:navigation.title action:nil keyEquivalent:@""].submenu = navigation;
    NSArray *directions = @[@"À gauche", @"À droite", @"Au-dessus", @"En dessous"];
    const unichar arrows[] = {NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey};
    for (NSUInteger i = 0; i < directions.count; i++) {
        NSString *key = [NSString stringWithCharacters:&arrows[i] length:1];
        NSMenuItem *item = [navigation addItemWithTitle:directions[i] action:@selector(focusNeighbor:) keyEquivalent:key];
        item.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
        item.target = self;
    }
    [session addItemWithTitle:@"Fermer" action:@selector(closeSession:) keyEquivalent:@"w"].target = self;
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Édition"];
    [bar addItemWithTitle:@"Édition" action:nil keyEquivalent:@""].submenu = edit;
    [edit addItemWithTitle:@"Copier" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Coller" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:@"Rechercher…" action:@selector(findText:) keyEquivalent:@"f"];
    [edit addItemWithTitle:@"Occurrence suivante" action:@selector(findNext:) keyEquivalent:@"g"];
    NSMenuItem *previous = [edit addItemWithTitle:@"Occurrence précédente" action:@selector(findPrevious:) keyEquivalent:@"g"];
    previous.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"Présentation"];
    [bar addItemWithTitle:@"Présentation" action:nil keyEquivalent:@""].submenu = view;
    [view addItemWithTitle:@"Agrandir la police" action:@selector(increaseFont:) keyEquivalent:@"+"];
    [view addItemWithTitle:@"Réduire la police" action:@selector(decreaseFont:) keyEquivalent:@"-"];
    NSMenu *profiles = [[NSMenu alloc] initWithTitle:@"Profil de couleurs"];
    profiles.delegate = self;
    [view addItemWithTitle:profiles.title action:nil keyEquivalent:@""].submenu = profiles;
    NSApp.mainMenu = bar;
    _windows = [NSMutableSet set];
    _fullScreenTransitions = [NSHashTable weakObjectsHashTable];
    [self newWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)openAlongside:(NSWindow *)parent movingTerminal:(TerminalView *)existing {
    NSRect frame = parent ? [parent contentRectForFrameRect:parent.frame] : NSMakeRect(0,0,800,480);
    MTTerminalWindow *window = [[MTTerminalWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"mTerm";
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.contentMinSize = NSMakeSize(240,120);
    window.tabbingIdentifier = @"mTerm";
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    if (!parent && (_windows.count || ![window setFrameUsingName:terminalFrameName])) {
        [window center];
    }
    TerminalView *view = existing ?: [[TerminalView alloc] initWithFrame:window.contentView.bounds
                                                                   directory:parent ? [self activeTerminal].currentDirectory : nil];
    window.contentView = view;
    [_windows addObject:window];
    if (parent) {
        window.tabbingMode = NSWindowTabbingModeAutomatic;
        [parent addTabbedWindow:window ordered:NSWindowAbove];
    }
    [window makeFirstResponder:view];
    [window makeKeyAndOrderFront:nil];
    window.tabbingMode = NSWindowTabbingModeAutomatic;
    [window observeTabOrder];
}

- (NSMenu *)menuForTerminal:(TerminalView *)terminal {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Session"];
    [menu addItemWithTitle:@"Nouvelle fenêtre" action:@selector(newWindow:) keyEquivalent:@"n"].target = self;
    [menu addItemWithTitle:@"Nouvel onglet" action:@selector(newTab:) keyEquivalent:@"t"].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Scinder verticalement" action:@selector(splitVertically:) keyEquivalent:@"d"].target = self;
    NSMenuItem *horizontal = [menu addItemWithTitle:@"Scinder horizontalement" action:@selector(splitHorizontally:) keyEquivalent:@"d"];
    horizontal.target = self;
    horizontal.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [menu addItemWithTitle:@"Déplacer le volet vers une nouvelle fenêtre" action:@selector(detachPane:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Copier" action:@selector(copy:) keyEquivalent:@"c"].target = terminal;
    [menu addItemWithTitle:@"Coller" action:@selector(paste:) keyEquivalent:@"v"].target = terminal;
    [menu addItemWithTitle:@"Sélectionner le texte visible" action:@selector(selectVisibleText:) keyEquivalent:@""].target = terminal;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenu *profiles = [[NSMenu alloc] initWithTitle:@"Profil de couleurs"];
    profiles.delegate = self;
    [menu addItemWithTitle:profiles.title action:nil keyEquivalent:@""].submenu = profiles;
    [menu addItemWithTitle:@"Fermer la session" action:@selector(closeSession:) keyEquivalent:@"w"].target = self;
    return menu;
}

- (void)showSettings:(id)sender { MTShowColorSettings(); }

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    TerminalView *terminal = [self activeTerminal];
    for (MTProfile *profile in MTProfiles.shared.profiles) {
        NSMenuItem *item = [menu addItemWithTitle:profile.name action:@selector(selectProfile:) keyEquivalent:@""];
        item.representedObject = profile;
        item.target = terminal ? self : nil;
        item.state = terminal.profile == profile ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)selectProfile:(NSMenuItem *)sender {
    [self activeTerminal].profile = sender.representedObject;
}

- (TerminalView *)activeTerminal {
    NSResponder *responder = NSApp.keyWindow.firstResponder;
    return [responder isKindOfClass:TerminalView.class] ? (TerminalView *)responder : nil;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(splitVertically:) || item.action == @selector(splitHorizontally:) ||
        item.action == @selector(selectProfile:) || item.action == @selector(focusNeighbor:)) return [self activeTerminal] != nil;
    if (item.action == @selector(detachPane:)) return [[self activeTerminal].superview isKindOfClass:NSSplitView.class];
    if (item.action == @selector(closeSession:)) return NSApp.keyWindow != nil;
    return YES;
}

- (void)focusNeighbor:(NSMenuItem *)sender {
    TerminalView *current = [self activeTerminal];
    if (!current) return;
    unichar arrow = [sender.keyEquivalent characterAtIndex:0];
    BOOL horizontal = arrow == NSLeftArrowFunctionKey || arrow == NSRightArrowFunctionKey;
    BOOL forward = arrow == NSRightArrowFunctionKey || arrow == NSUpArrowFunctionKey;
    // Les coordonnées de fenêtre ont leur origine en bas à gauche, même pour les vues inversées.
    NSRect source = [current convertRect:current.bounds toView:nil];
    CGFloat low = horizontal ? NSMinY(source) : NSMinX(source);
    CGFloat high = horizontal ? NSMaxY(source) : NSMaxX(source);
    CGFloat bestGap = CGFLOAT_MAX, bestOverlap = 0;
    TerminalView *best = nil;
    NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:current.window.contentView];
    while (pending.count) {
        NSView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:NSSplitView.class]) {
            [pending addObjectsFromArray:view.subviews];
            continue;
        }
        if (view == current || ![view isKindOfClass:TerminalView.class] || NSIsEmptyRect(view.visibleRect)) continue;
        NSRect rect = [view convertRect:view.bounds toView:nil];
        CGFloat gap, overlap;
        if (horizontal) {
            gap = forward ? NSMinX(rect) - NSMaxX(source) : NSMinX(source) - NSMaxX(rect);
            overlap = MIN(high, NSMaxY(rect)) - MAX(low, NSMinY(rect));
        } else {
            gap = forward ? NSMinY(rect) - NSMaxY(source) : NSMinY(source) - NSMaxY(rect);
            overlap = MIN(high, NSMaxX(rect)) - MAX(low, NSMinX(rect));
        }
        if (gap >= 0 && overlap > 0 && (gap < bestGap || (gap == bestGap && overlap > bestOverlap))) {
            best = (TerminalView *)view;
            bestGap = gap;
            bestOverlap = overlap;
        }
    }
    if (best) [current.window makeFirstResponder:best];
}

- (void)replacePane:(NSView *)old with:(NSView *)replacement inWindow:(NSWindow *)window {
    replacement.frame = old.frame;
    replacement.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (old == window.contentView) window.contentView = replacement;
    else [old.superview replaceSubview:old with:replacement];
}

- (void)splitActivePaneVertically:(BOOL)vertical {
    TerminalView *current = [self activeTerminal];
    if (!current) return;
    NSWindow *window = current.window;
    NSSplitView *split = [[NSSplitView alloc] initWithFrame:current.frame];
    split.vertical = vertical;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    CGFloat length = vertical ? NSWidth(current.bounds) : NSHeight(current.bounds);
    CGFloat half = floor((length - split.dividerThickness) / 2);
    if (half < (vertical ? 80 : 48)) { NSBeep(); return; }

    NSRect pane = current.bounds;
    if (vertical) pane.size.width = half;
    else pane.size.height = half;
    TerminalView *next = [[TerminalView alloc] initWithFrame:pane directory:current.currentDirectory];
    next.profile = current.profile;
    [self replacePane:current with:split inWindow:window];
    current.frame = pane;
    [split addSubview:current];
    [split addSubview:next];
    split.delegate = self;
    [split adjustSubviews];
    [split setPosition:half ofDividerAtIndex:0];
    [window makeFirstResponder:next];
}

- (void)splitVertically:(id)sender { [self splitActivePaneVertically:YES]; }
- (void)splitHorizontally:(id)sender { [self splitActivePaneVertically:NO]; }

- (CGFloat)splitView:(NSSplitView *)split constrainSplitPosition:(CGFloat)position ofSubviewAt:(NSInteger)divider {
    CGFloat length = (split.vertical ? NSWidth(split.bounds) : NSHeight(split.bounds)) - split.dividerThickness;
    CGFloat minimum = MIN(split.vertical ? 80 : 48, length / 2);
    return MAX(minimum, MIN(length - minimum, position));
}

- (void)removePaneFromSplit:(TerminalView *)current {
    NSWindow *window = current.window;
    NSSplitView *split = (NSSplitView *)current.superview;
    NSResponder *previousFocus = window.firstResponder;
    NSView *remaining = split.subviews.firstObject == current ? split.subviews.lastObject : split.subviews.firstObject;
    [remaining removeFromSuperview];
    [current removeFromSuperview];
    [self replacePane:split with:remaining inWindow:window];
    if ([previousFocus isKindOfClass:TerminalView.class] && previousFocus != current) {
        [window makeFirstResponder:previousFocus];
        return;
    }
    NSView *focus = remaining;
    while ([focus isKindOfClass:NSSplitView.class]) focus = focus.subviews.firstObject;
    [window makeFirstResponder:focus];
}

- (void)detachPane:(id)sender {
    TerminalView *current = [self activeTerminal];
    if (![current.superview isKindOfClass:NSSplitView.class]) return;
    [self removePaneFromSplit:current];
    [self openAlongside:nil movingTerminal:current];
}

- (void)terminalSessionDidEnd:(TerminalView *)terminal {
    if ([terminal.superview isKindOfClass:NSSplitView.class]) {
        [self removePaneFromSplit:terminal];
    } else if (terminal.window.contentView == terminal) {
        [terminal.window close];
    }
}

- (void)closeSession:(id)sender {
    TerminalView *current = [self activeTerminal];
    if (current) {
        [current stopSession];
        [self terminalSessionDidEnd:current];
    } else {
        [NSApp.keyWindow performClose:sender];
    }
}

- (void)stopSessionsInView:(NSView *)view {
    if ([view isKindOfClass:TerminalView.class]) [(TerminalView *)view stopSession];
    else for (NSView *child in view.subviews) [self stopSessionsInView:child];
}

- (void)newWindow:(id)sender { [self openAlongside:nil movingTerminal:nil]; }
- (void)newTab:(id)sender { [self openAlongside:[_windows containsObject:NSApp.keyWindow] ? NSApp.keyWindow : nil movingTerminal:nil]; }
- (void)newWindowForTab:(id)sender { [self newTab:sender]; }

- (void)saveNormalFrame:(NSWindow *)window {
    if (![_windows containsObject:window] || window.miniaturized ||
        (window.styleMask & NSWindowStyleMaskFullScreen) ||
        [_fullScreenTransitions containsObject:window]) return;
    [window saveFrameUsingName:terminalFrameName];
}

- (void)windowDidBecomeKey:(NSNotification *)note { [self saveNormalFrame:note.object]; }

- (void)windowGeometryChanged:(NSNotification *)note {
    NSWindow *window = note.object;
    if (window.keyWindow) [self saveNormalFrame:window];
}

- (void)windowDidMove:(NSNotification *)note { [self windowGeometryChanged:note]; }
- (void)windowDidResize:(NSNotification *)note { [self windowGeometryChanged:note]; }

- (void)windowWillEnterFullScreen:(NSNotification *)note {
    [self saveNormalFrame:note.object];
    [_fullScreenTransitions addObject:note.object];
}

- (void)windowDidExitFullScreen:(NSNotification *)note {
    [_fullScreenTransitions removeObject:note.object];
    [self windowGeometryChanged:note];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
    [_fullScreenTransitions removeObject:window];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (window) [self saveNormalFrame:window];
}

- (void)windowWillClose:(NSNotification *)note {
    NSWindow *window = note.object;
    if (_windows.count == 1) [self saveNormalFrame:window];
    [window removeObserver:window forKeyPath:@"tabGroup.windows" context:&tabOrderContext];
    [self stopSessionsInView:window.contentView];
    [_windows removeObject:window];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *__attribute__((objc_precise_lifetime)) delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
        (void)delegate;
    }
    return 0;
}
