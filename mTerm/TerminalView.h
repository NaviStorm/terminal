#import <AppKit/AppKit.h>

@class MTProfile;

@interface TerminalView : NSView
@property(nonatomic, strong) MTProfile *profile;
- (void)stopSession;
@end
