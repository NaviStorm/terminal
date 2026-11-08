#import <AppKit/AppKit.h>
#import "TerminalView.h"

static NSString *const terminalFrameName = @"TerminalWindow";

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppDelegate {
    NSMutableSet<NSWindow *> *_windows;
    NSHashTable<NSWindow *> *_fullScreenTransitions;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSMenu *bar = [NSMenu new];
    NSMenu *app = [NSMenu new];
    [bar addItemWithTitle:@"mTerm" action:nil keyEquivalent:@""].submenu = app;
    [app addItemWithTitle:@"Quitter mTerm" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenu *session = [[NSMenu alloc] initWithTitle:@"Session"];
    [bar addItemWithTitle:@"Session" action:nil keyEquivalent:@""].submenu = session;
    [session addItemWithTitle:@"Nouvelle fenêtre" action:@selector(newWindow:) keyEquivalent:@"n"].target = self;
    [session addItemWithTitle:@"Nouvel onglet" action:@selector(newTab:) keyEquivalent:@"t"].target = self;
    [session addItemWithTitle:@"Fermer" action:@selector(performClose:) keyEquivalent:@"w"];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Édition"];
    [bar addItemWithTitle:@"Édition" action:nil keyEquivalent:@""].submenu = edit;
    [edit addItemWithTitle:@"Copier" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Coller" action:@selector(paste:) keyEquivalent:@"v"];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"Présentation"];
    [bar addItemWithTitle:@"Présentation" action:nil keyEquivalent:@""].submenu = view;
    [view addItemWithTitle:@"Agrandir la police" action:@selector(increaseFont:) keyEquivalent:@"+"];
    [view addItemWithTitle:@"Réduire la police" action:@selector(decreaseFont:) keyEquivalent:@"-"];
    NSApp.mainMenu = bar;
    _windows = [NSMutableSet set];
    _fullScreenTransitions = [NSHashTable weakObjectsHashTable];
    [self newWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)openAlongside:(NSWindow *)parent {
    NSRect frame = parent ? [parent contentRectForFrameRect:parent.frame] : NSMakeRect(0,0,800,480);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
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
    TerminalView *view = [[TerminalView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    [_windows addObject:window];
    if (parent) {
        window.tabbingMode = NSWindowTabbingModeAutomatic;
        [parent addTabbedWindow:window ordered:NSWindowAbove];
    }
    [window makeFirstResponder:view];
    [window makeKeyAndOrderFront:nil];
    window.tabbingMode = NSWindowTabbingModeAutomatic;
}

- (void)newWindow:(id)sender { [self openAlongside:nil]; }
- (void)newTab:(id)sender { [self openAlongside:NSApp.keyWindow]; }
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
    [(TerminalView *)window.contentView stopSession];
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
