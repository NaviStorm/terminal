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
    NSString *_status;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _fd = -1;
        _anchor = _focus = -1;
        _font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
        _bold = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightBold];
        _cw = [@"M" sizeWithAttributes:@{NSFontAttributeName:_font}].width;
        _ch = ceil(_font.ascender - _font.descender + _font.leading);
        _parser = mt_new(1, 1);
        [self resizeGrid];
        [self startSession];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

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
    if (!_pending) _pending = [NSMutableData data];
    [_pending appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
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

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    _anchor = [self cellAt:event];
    _focus = -1;
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    _focus = [self cellAt:event];
    self.needsDisplay = YES;
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat delta = event.scrollingDeltaY;
    if (!delta) return;
    int lines = MAX(1, round(fabs(delta) / (event.hasPreciseScrollingDeltas ? _ch : 1)));
    mt_scroll(_parser, delta > 0 ? lines : -lines);
    _anchor = _focus = -1;
    self.needsDisplay = YES;
}

- (void)copy:(id)sender {
    if (_focus < 0 || _anchor < 0) return;
    NSInteger a = MIN(_anchor,_focus), b = MAX(_anchor,_focus);
    char *text = mt_selection(_parser,a/_cols,a%_cols,b/_cols,b%_cols+1);
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:@(text) forType:NSPasteboardTypeString];
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
    for (uint16_t row = 0; row < _rows; row++) {
        @autoreleasepool {
            for (uint16_t col = 0; col < _cols; col++) {
                MTPaint cell;
                if (!mt_cell(_parser,row,col,&cell)) continue;
                CGRect rect = CGRectMake(inset+col*_cw,inset+row*_ch,_cw*(cell.wide ? 2 : 1),_ch);
                if (!CGRectIntersectsRect(rect,dirty)) continue;
                NSInteger index = row*_cols+col;
                BOOL selected = _focus >= 0 && index >= MIN(_anchor,_focus) && index <= MAX(_anchor,_focus);
                if (selected || cell.bg != 0x161616) {
                    [(selected ? NSColor.selectedTextBackgroundColor : Color(cell.bg)) setFill];
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
