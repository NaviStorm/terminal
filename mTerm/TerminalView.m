#import "TerminalView.h"
#import "Engine.h"
#import <util.h>
#import <fcntl.h>
#import <sys/wait.h>
#import <sys/ioctl.h>

static const CGFloat inset = 8;
static NSColor *Color(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                               green:((rgb >> 8) & 255) / 255.0
                                blue:(rgb & 255) / 255.0 alpha:1];
}

@implementation TerminalView {
    MTParser *_parser;
    uint16_t _rows, _cols;
    NSFont *_font, *_bold;
    CGFloat _cw, _ch;
    int _fd;
    dispatch_source_t _reader, _writer;
    BOOL _writing;
    NSMutableData *_pending;
    NSUInteger _sent;
    NSInteger _anchor, _focus;
    NSInteger _lastMouseCell;
    BOOL _localDrag;
    NSTrackingArea *_tracking;
    NSString *_status;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _fd = -1;
        _lastMouseCell = -1;
        _anchor = _focus = -1;
        [self setTerminalFontSize:14];
        _parser = mt_new(1, 1);
        [self resizeGrid];
        [self startSession];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)setTerminalFontSize:(CGFloat)size {
    if (_font.pointSize == size) return;
    NSFont *font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    CGFloat cellWidth = [@"M" sizeWithAttributes:@{NSFontAttributeName:font}].width;
    CGFloat cellHeight = ceil(font.ascender - font.descender + font.leading);
    NSWindow *window = self.window;
    NSRect frame = window.frame;
    BOOL resizeWindow = window && _parser && !(window.styleMask & NSWindowStyleMaskFullScreen);
    if (resizeWindow) {
        CGFloat width = MAX(window.contentMinSize.width, ceil(2 * inset + _cols * cellWidth));
        CGFloat height = MAX(window.contentMinSize.height, ceil(2 * inset + _rows * cellHeight));
        // La différence inclut la barre de titre et, le cas échéant, les onglets.
        NSSize decoration = NSMakeSize(NSWidth(frame) - NSWidth(self.bounds),
                                       NSHeight(frame) - NSHeight(self.bounds));
        NSRect visible = (window.screen ?: NSScreen.mainScreen).visibleFrame;
        if (width + decoration.width > NSWidth(visible) ||
            floor((width - 2 * inset) / cellWidth) != _cols) {
            NSBeep();
            return;
        }
        CGFloat top = MIN(NSMaxY(frame), NSMaxY(visible));
        frame.size.width = width + decoration.width;
        frame.size.height = MIN(height + decoration.height, NSHeight(visible));
        frame.origin.x = MAX(NSMinX(visible), MIN(NSMinX(frame), NSMaxX(visible) - NSWidth(frame)));
        frame.origin.y = MAX(NSMinY(visible), top - NSHeight(frame));
    }
    _font = font;
    _bold = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightBold];
    _cw = cellWidth;
    _ch = cellHeight;
    if (resizeWindow) [window setFrame:frame display:YES];
    [self resizeGrid];
    self.needsDisplay = YES;
}

- (void)increaseFont:(id)sender { [self setTerminalFontSize:MIN(72, _font.pointSize + 1)]; }
- (void)decreaseFont:(id)sender { [self setTerminalFontSize:MAX(6, _font.pointSize - 1)]; }

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    if ((flags & NSEventModifierFlagCommand) && !(flags & (NSEventModifierFlagControl | NSEventModifierFlagOption))) {
        NSString *key = event.charactersIgnoringModifiers;
        if ([@[@"+", @"=", @"/"] containsObject:key]) { [self increaseFont:nil]; return YES; }
        if ([@[@"-", @"_"] containsObject:key]) { [self decreaseFont:nil]; return YES; }
    }
    return [super performKeyEquivalent:event];
}

- (void)resizeGrid {
    if (!_parser) return;
    uint16_t cols = MIN(4096, MAX(2, floor((self.bounds.size.width - 2*inset) / _cw)));
    uint16_t rows = MIN(4096, MAX(1, floor((self.bounds.size.height - 2*inset) / _ch)));
    if (rows == _rows && cols == _cols) return;
    _rows = rows;
    _cols = cols;
    mt_resize(_parser, rows, cols);
    if (_fd >= 0) {
        struct winsize size = { .ws_row = rows, .ws_col = cols };
        ioctl(_fd, TIOCSWINSZ, &size);
    }
    _anchor = _focus = -1;
    self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self resizeGrid];
}

- (void)startSession {
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"TERM"] = @"xterm-256color";
    if (!env[@"LANG"]) env[@"LANG"] = @"en_US.UTF-8";
    NSString *shell = env[@"SHELL"] ?: @"/bin/zsh";
    if (![NSFileManager.defaultManager isExecutableFileAtPath:shell]) shell = @"/bin/zsh";
    env[@"SHELL"] = shell;
    char **envp = calloc(env.count + 1, sizeof(char *));
    NSUInteger i = 0;
    for (NSString *key in env) envp[i++] = strdup([NSString stringWithFormat:@"%@=%@", key, env[key]].UTF8String);
    char *path = strdup(shell.fileSystemRepresentation);
    char *home = strdup(NSHomeDirectory().fileSystemRepresentation);
    char *login = strdup([[@"-" stringByAppendingString:shell.lastPathComponent] UTF8String]);
    struct winsize size = { .ws_row = _rows, .ws_col = _cols };
    int fd;
    pid_t pid = forkpty(&fd, NULL, NULL, &size);
    if (pid == 0) {
        chdir(home);
        char *args[] = { login, NULL };
        execve(path, args, envp);
        _exit(127);
    }
    for (i = 0; envp[i]; i++) free(envp[i]);
    free(envp); free(path); free(home); free(login);
    if (pid < 0) {
        _status = @"Impossible d’ouvrir le pseudo-terminal.";
        return;
    }
    _fd = fd;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    dispatch_source_t child = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(child, ^{
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        dispatch_source_cancel(child);
    });
    dispatch_resume(child);
    __weak TerminalView *weakSelf = self;
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_reader, ^{ [weakSelf readOutput]; });
    _writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_writer, ^{ [weakSelf flushInput]; });
    // Les deux sources doivent avoir terminé avant de recycler le descripteur.
    dispatch_group_t group = dispatch_group_create();
    for (dispatch_source_t source in @[_reader, _writer]) {
        dispatch_group_enter(group);
        dispatch_source_set_cancel_handler(source, ^{ dispatch_group_leave(group); });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ close(fd); });
    dispatch_resume(_reader);
}

- (void)readOutput {
    uint8_t bytes[16384];
    ssize_t count = read(_fd, bytes, sizeof(bytes));
    if (count > 0) {
        mt_feed(_parser, bytes, count);
        self.needsDisplay = YES;
    } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
        _status = @"Session terminée";
        [self stopSession];
        self.needsDisplay = YES;
    }
}

- (void)stopSession {
    if (!_reader) return;
    dispatch_source_cancel(_reader);
    if (!_writing) dispatch_resume(_writer);
    dispatch_source_cancel(_writer);
    _reader = _writer = nil;
    _pending = nil;
    _fd = -1;
}

- (void)dealloc {
    [self stopSession];
    if (_parser) mt_free(_parser);
}

- (void)flushInput {
    const uint8_t *bytes = _pending.bytes;
    ssize_t count = write(_fd, bytes + _sent, _pending.length - _sent);
    if (count < 0) {
        if (errno != EINTR && errno != EAGAIN) {
            _status = @"Connexion au terminal interrompue.";
            [self stopSession];
            self.needsDisplay = YES;
        }
        return;
    }
    _sent += count;
    if (_sent == _pending.length) {
        _sent = 0;
        _pending = nil;
        dispatch_suspend(_writer);
        _writing = NO;
    }
}

- (void)sendText:(NSString *)text {
    if (!text.length || _fd < 0) return;
    mt_scroll(_parser, INT32_MIN);
    _anchor = _focus = -1;
    self.needsDisplay = YES;
    [self enqueueInput:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)enqueueInput:(NSData *)data {
    if (!data.length || _fd < 0) return;
    if (!_pending) _pending = [NSMutableData data];
    [_pending appendData:data];
    if (!_writing) {
        _writing = YES;
        dispatch_resume(_writer);
    }
}

- (void)keyDown:(NSEvent *)event {
    NSString *letters = event.charactersIgnoringModifiers;
    if (!letters.length) return;
    NSString *suffix;
    switch ([letters characterAtIndex:0]) {
        case NSUpArrowFunctionKey: suffix = @"A"; break;
        case NSDownArrowFunctionKey: suffix = @"B"; break;
        case NSRightArrowFunctionKey: suffix = @"C"; break;
        case NSLeftArrowFunctionKey: suffix = @"D"; break;
        case NSHomeFunctionKey: suffix = @"H"; break;
        case NSEndFunctionKey: suffix = @"F"; break;
        case NSDeleteFunctionKey: [self sendText:@"\033[3~"]; return;
        case NSPageUpFunctionKey: [self sendText:@"\033[5~"]; return;
        case NSPageDownFunctionKey: [self sendText:@"\033[6~"]; return;
        default: [self sendText:event.characters]; return;
    }
    [self sendText:[(mt_application_cursor(_parser) ? @"\033O" : @"\033[") stringByAppendingString:suffix]];
}

- (NSInteger)cellAt:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = MAX(0, MIN(_rows-1, floor((p.y-inset)/_ch)));
    NSInteger col = MAX(0, MIN(_cols-1, floor((p.x-inset)/_cw)));
    return row * _cols + col;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingInVisibleRect | NSTrackingActiveInKeyWindow | NSTrackingMouseMoved
        owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (BOOL)applicationTracks:(NSEvent *)event {
    return mt_mouse_enabled(_parser) && !(event.modifierFlags & NSEventModifierFlagOption);
}

- (void)reportEvent:(NSEvent *)event button:(uint8_t)button release:(BOOL)release motion:(BOOL)motion {
    NSInteger cell = [self cellAt:event];
    if (motion && cell == _lastMouseCell) return;
    uint8_t modifiers = (event.modifierFlags & NSEventModifierFlagShift ? 4 : 0) |
                        (event.modifierFlags & NSEventModifierFlagControl ? 16 : 0);
    uint8_t bytes[32];
    size_t len = mt_mouse_report(_parser, button, release, motion, modifiers, cell/_cols, cell%_cols, bytes);
    if (len) {
        _lastMouseCell = cell;
        [self enqueueInput:[NSData dataWithBytes:bytes length:len]];
    }
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    _localDrag = ![self applicationTracks:event];
    _anchor = _localDrag ? [self cellAt:event] : -1;
    _focus = -1;
    if (!_localDrag) [self reportEvent:event button:0 release:NO motion:NO];
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_localDrag) {
        _focus = [self cellAt:event];
        self.needsDisplay = YES;
    } else {
        [self reportEvent:event button:0 release:NO motion:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (_localDrag && _focus >= 0 && _anchor >= 0) {
        _focus = [self cellAt:event];
        [self copy:nil];
        self.needsDisplay = YES;
    } else if (!_localDrag) {
        [self reportEvent:event button:0 release:YES motion:NO];
    }
    _localDrag = NO;
}

- (void)mouseMoved:(NSEvent *)event {
    if ([self applicationTracks:event]) [self reportEvent:event button:3 release:NO motion:YES];
}

- (void)rightMouseDown:(NSEvent *)event {
    if ([self applicationTracks:event]) [self reportEvent:event button:2 release:NO motion:NO];
    else [super rightMouseDown:event];
}
- (void)rightMouseDragged:(NSEvent *)event {
    if ([self applicationTracks:event]) [self reportEvent:event button:2 release:NO motion:YES];
}
- (void)rightMouseUp:(NSEvent *)event {
    if ([self applicationTracks:event]) [self reportEvent:event button:2 release:YES motion:NO];
}
- (void)otherMouseDown:(NSEvent *)event {
    if (event.buttonNumber == 2 && [self applicationTracks:event]) [self reportEvent:event button:1 release:NO motion:NO];
}
- (void)otherMouseDragged:(NSEvent *)event {
    if (event.buttonNumber == 2 && [self applicationTracks:event]) [self reportEvent:event button:1 release:NO motion:YES];
}
- (void)otherMouseUp:(NSEvent *)event {
    if (event.buttonNumber == 2 && [self applicationTracks:event]) [self reportEvent:event button:1 release:YES motion:NO];
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat delta = event.scrollingDeltaY;
    if (!delta) return;
    int lines = MAX(1, round(fabs(delta) / (event.hasPreciseScrollingDeltas ? _ch : 1)));
    if ([self applicationTracks:event]) {
        for (int i = 0; i < lines; i++)
            [self reportEvent:event button:delta > 0 ? 64 : 65 release:NO motion:NO];
        return;
    }
    mt_scroll(_parser, delta > 0 ? lines : -lines);
    _anchor = _focus = -1;
    self.needsDisplay = YES;
}

- (void)copy:(id)sender {
    if (_focus < 0 || _anchor < 0) return;
    NSInteger a = MIN(_anchor,_focus), b = MAX(_anchor,_focus);
    char *text = mt_selection(_parser,a/_cols,a%_cols,b/_cols,b%_cols+1);
    if (*text) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:@(text) forType:NSPasteboardTypeString];
    }
    mt_string_free(text);
}

- (void)paste:(id)sender {
    NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    if (mt_bracketed_paste(_parser)) s = [NSString stringWithFormat:@"\033[200~%@\033[201~",s];
    [self sendText:s];
}

- (void)drawRect:(NSRect)dirty {
    [Color(0x161616) setFill];
    NSRectFill(dirty);
    NSRange selection = NSMakeRange(0, 0);
    if (_anchor >= 0 && _focus >= 0) {
        NSInteger first = MIN(_anchor, _focus), last = MAX(_anchor, _focus);
        MTPaint edge;
        if (!mt_cell(_parser, first/_cols, first%_cols, &edge) && first%_cols > 0) first--;
        if (mt_cell(_parser, last/_cols, last%_cols, &edge) && edge.wide && last%_cols + 1 < _cols) last++;
        selection = NSMakeRange(first, last - first + 1);
    }
    for (uint16_t row = 0; row < _rows; row++) {
        @autoreleasepool {
            NSUInteger rowStart = row * _cols;
            NSRange highlight = NSIntersectionRange(selection, NSMakeRange(rowStart, _cols));
            if (highlight.length) {
                [NSColor.selectedTextBackgroundColor setFill];
                NSRectFill(NSMakeRect(inset + (highlight.location - rowStart) * _cw,
                                      inset + row * _ch, highlight.length * _cw, _ch));
            }
            for (uint16_t col = 0; col < _cols; col++) {
                MTPaint cell;
                if (!mt_cell(_parser,row,col,&cell)) continue;
                CGRect rect = CGRectMake(inset+col*_cw,inset+row*_ch,_cw*(cell.wide ? 2 : 1),_ch);
                if (!CGRectIntersectsRect(rect,dirty)) continue;
                BOOL selected = NSLocationInRange(rowStart + col, highlight);
                if (!selected && cell.bg != 0x161616) {
                    [Color(cell.bg) setFill];
                    NSRectFill(rect);
                }
                if (!cell.len) continue;
                NSString *s = [[NSString alloc] initWithBytes:cell.bytes length:cell.len encoding:NSUTF8StringEncoding];
                [s drawAtPoint:rect.origin withAttributes:@{
                    NSFontAttributeName:cell.bold ? _bold : _font,
                    NSForegroundColorAttributeName:selected ? NSColor.selectedTextColor : Color(cell.fg),
                    NSUnderlineStyleAttributeName:@(cell.underline)
                }];
            }
        }
    }
    uint16_t row, col;
    if (!_status && mt_cursor(_parser,&row,&col)) {
        [NSColor.whiteColor setFill];
        NSRectFill(NSMakeRect(inset+col*_cw,inset+(1+row)*_ch-2,_cw,2));
    }
    if (_status) [_status drawAtPoint:NSMakePoint(inset,NSMaxY(self.bounds)-_ch)
                       withAttributes:@{NSForegroundColorAttributeName:NSColor.whiteColor,
                                        NSBackgroundColorAttributeName:Color(0x161616)}];
}
@end
