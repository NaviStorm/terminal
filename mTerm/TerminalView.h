#import <AppKit/AppKit.h>

@class MTProfile;

@interface TerminalView : NSView <NSMenuItemValidation, NSTextInputClient>
@property(nonatomic, strong) MTProfile *profile;
- (instancetype)initWithFrame:(NSRect)frame directory:(NSString *)directory;
- (NSString *)currentDirectory;
- (void)findText:(id)sender;
- (void)findNext:(id)sender;
- (void)findPrevious:(id)sender;
- (BOOL)hasForegroundJob;
- (void)openDirectoryInFinder:(id)sender;
- (void)stopSession;
- (void)selectVisibleText:(id)sender;
@end

@protocol MTTerminalWindowDelegate <NSObject>
- (void)updateBackgroundForWindow:(NSWindow *)window;
- (void)requestCloseTerminal:(TerminalView *)terminal;
- (void)terminalSessionDidEnd:(TerminalView *)terminal;
- (NSMenu *)menuForTerminal:(TerminalView *)terminal;
@end
