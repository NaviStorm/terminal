#import <AppKit/AppKit.h>

@class MTProfile;

@interface TerminalView : NSView <NSMenuItemValidation>
@property(nonatomic, strong) MTProfile *profile;
- (void)stopSession;
- (void)selectVisibleText:(id)sender;
@end

@protocol MTTerminalMenuProvider <NSObject>
- (NSMenu *)menuForTerminal:(TerminalView *)terminal;
@end
