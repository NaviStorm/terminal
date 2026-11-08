#import <AppKit/AppKit.h>

@class MTProfile;

@interface TerminalView : NSView <NSMenuItemValidation>
@property(nonatomic, strong) MTProfile *profile;
- (void)stopSession;
- (void)selectVisibleText:(id)sender;
@end

@protocol MTTerminalWindowDelegate <NSObject>
- (void)terminalSessionDidEnd:(TerminalView *)terminal;
- (NSMenu *)menuForTerminal:(TerminalView *)terminal;
@end
