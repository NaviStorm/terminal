#import <AppKit/AppKit.h>
#import "TerminalView.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppDelegate {
    NSMutableSet<NSWindow *> *_windows;
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
    NSApp.mainMenu = bar;
    _windows = [NSMutableSet set];
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
    TerminalView *view = [[TerminalView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = view;
    [_windows addObject:window];
    if (parent) {
        window.tabbingMode = NSWindowTabbingModeAutomatic;
        [parent addTabbedWindow:window ordered:NSWindowAbove];
    } else {
        [window center];
    }
    [window makeFirstResponder:view];
    [window makeKeyAndOrderFront:nil];
    window.tabbingMode = NSWindowTabbingModeAutomatic;
}

- (void)newWindow:(id)sender { [self openAlongside:nil]; }
- (void)newTab:(id)sender { [self openAlongside:NSApp.keyWindow]; }
- (void)newWindowForTab:(id)sender { [self newTab:sender]; }

- (void)windowWillClose:(NSNotification *)note {
    NSWindow *window = note.object;
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
