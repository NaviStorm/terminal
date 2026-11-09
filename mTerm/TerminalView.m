#import "TerminalView.h"
#import "Engine.h"
#import "ColorProfiles.h"
#import <QuartzCore/QuartzCore.h>
#import <util.h>
#import <libproc.h>
#import <fcntl.h>
#import <sys/wait.h>
#import <sys/ioctl.h>

static const NSUInteger inputHighWaterMark = 1024 * 1024;
static const NSUInteger inputChunkSize = 16 * 1024;
static const CGFloat inset = 8;
static const CGFloat paneHeaderHeight = 23;

@interface MTPaneHeader : NSView
@property(nonatomic, readonly) NSTextField *caption;
@end

@implementation MTPaneHeader
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _caption = [NSTextField labelWithString:@""];
        _caption.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        _caption.lineBreakMode = NSLineBreakByTruncatingHead;
        _caption.frame = NSMakeRect(26,3,MAX(0,NSWidth(frame)-54),17);
        _caption.autoresizingMask = NSViewWidthSizable;
        [self addSubview:_caption];
        NSButton *close = [self button:@"xmark" title:@"Fermer le volet" action:@selector(closePane:)];
        close.frame = NSMakeRect(2,1,22,21);
        NSButton *menu = [self button:@"ellipsis.circle" title:@"Menu du volet" action:@selector(openPaneMenu:)];
        menu.frame = NSMakeRect(NSWidth(frame)-25,1,23,21);
        menu.autoresizingMask = NSViewMinXMargin;
    }
    return self;
}
- (NSButton *)button:(NSString *)symbol title:(NSString *)title action:(SEL)action {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bordered = NO;
    button.toolTip = title;
    [self addSubview:button];
    return button;
}
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return hit == _caption ? self : hit;
}
- (void)mouseDown:(NSEvent *)event { [self.window makeFirstResponder:self.superview]; }
- (void)closePane:(id)sender {
    TerminalView *pane = (TerminalView *)self.superview;
    [(id<MTTerminalWindowDelegate>)self.window.delegate requestCloseTerminal:pane];
}
- (void)openPaneMenu:(NSButton *)button {
    [self.window makeFirstResponder:self.superview];
    NSMenu *menu = [(id<MTTerminalWindowDelegate>)self.window.delegate menuForTerminal:(TerminalView *)self.superview];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(button.frame),0) inView:self];
}
- (void)drawRect:(NSRect)dirty {
    [[NSColor.windowBackgroundColor blendedColorWithFraction:0.35 ofColor:NSColor.grayColor] setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0,0,NSWidth(self.bounds),1));
}
@end
static NSString *const fontSizeKey = @"TerminalFontSize";
static const NSInteger minimumFontSize = 6;
static const NSInteger maximumFontSize = 72;

@implementation TerminalView {
    MTParser *_parser;
    uint16_t _rows, _cols;
    NSFont *_font, *_bold;
    CGFloat _cw, _ch;
    int _fd;
    dispatch_source_t _reader, _writer;
    BOOL _writing, _readerPaused;
    NSMutableArray<NSMutableData *> *_pending;
    NSUInteger _pendingBytes;
    NSUInteger _sent;
    NSInteger _anchor, _focus;
    NSInteger _lastMouseCell;
    BOOL _localDrag;
    NSInteger _clickCount;
    int32_t _initialFirst, _initialLast;
    NSTrackingArea *_tracking;
    MTPaneHeader *_paneHeader;
    NSString *_shellName;
    NSString *_status, *_directory, *_shellTitle, *_query;
    pid_t _shellPID;
    BOOL _titleUpdatePending;
    NSString *_markedText;
    NSRange _markedSelection;
    NSEvent *_textKeyEvent;
}

- (instancetype)initWithFrame:(NSRect)frame {
    return [self initWithFrame:frame directory:nil];
}

- (instancetype)initWithFrame:(NSRect)frame directory:(NSString *)directory {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        _directory = [directory copy] ?: NSHomeDirectory();
        _profile = MTProfiles.shared.defaultProfile;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(profilesChanged:)
                                                   name:MTProfilesChanged object:MTProfiles.shared];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgroundChanged:)
                                                   name:MTBackgroundChanged object:nil];
        _fd = -1;
        _lastMouseCell = -1;
        _anchor = _focus = -1;
        NSInteger size = [NSUserDefaults.standardUserDefaults integerForKey:fontSizeKey];
        if (size < minimumFontSize || size > maximumFontSize) size = 14;
        [self setTerminalFontSize:size savePreference:NO];
        _parser = mt_new(2, 2, (uint16_t)MTScrollbackLines());
        [self resizeGrid];
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeString]];
        [self startSession];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return _profile.backgroundOpacity == 100; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder {
    self.needsDisplay = YES;
    [self updateSessionTitle];
    return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
    if (self.hasMarkedText) {
        _markedText = nil;
        [self.inputContext discardMarkedText];
    }
    self.needsDisplay = YES;
    return [super resignFirstResponder];
}

- (void)setTerminalFontSize:(CGFloat)size savePreference:(BOOL)savePreference {
    if (_font.pointSize == size) return;
    NSFont *font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    CGFloat cellWidth = [@"M" sizeWithAttributes:@{NSFontAttributeName:font}].width;
    CGFloat cellHeight = ceil(font.ascender - font.descender + font.leading);
    NSWindow *window = self.window;
    NSRect frame = window.frame;
    BOOL resizeWindow = window && ![self.superview isKindOfClass:NSSplitView.class] && _parser && !(window.styleMask & NSWindowStyleMaskFullScreen);
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
    if (savePreference) [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)size forKey:fontSizeKey];
    if (resizeWindow) [window setFrame:frame display:YES];
    [self resizeGrid];
    self.needsDisplay = YES;
}

- (void)increaseFont:(id)sender { [self setTerminalFontSize:MIN(maximumFontSize, _font.pointSize + 1) savePreference:YES]; }
- (void)decreaseFont:(id)sender { [self setTerminalFontSize:MAX(minimumFontSize, _font.pointSize - 1) savePreference:YES]; }

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    if ((flags & NSEventModifierFlagCommand) && !(flags & (NSEventModifierFlagControl | NSEventModifierFlagOption))) {
        NSString *key = event.charactersIgnoringModifiers;
        if ([@[@"+", @"=", @"/"] containsObject:key]) { [self increaseFont:nil]; return YES; }
        if ([@[@"-", @"_"] containsObject:key]) { [self decreaseFont:nil]; return YES; }
    }
    return [super performKeyEquivalent:event];
}

- (CGFloat)gridTop { return inset + (_paneHeader ? paneHeaderHeight : 0); }

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    if (!self.superview) return;
    if ([self.superview isKindOfClass:NSSplitView.class]) {
        if (_paneHeader) return;
        _paneHeader = [[MTPaneHeader alloc] initWithFrame:NSMakeRect(0,0,NSWidth(self.bounds),paneHeaderHeight)];
        _paneHeader.autoresizingMask = NSViewWidthSizable;
        [self addSubview:_paneHeader];
        [self updatePaneHeader];
    } else if (_paneHeader) {
        [_paneHeader removeFromSuperview];
        _paneHeader = nil;
    } else {
        return;
    }
    [self resizeGrid];
    self.needsDisplay = YES;
}

- (void)updatePaneHeader {
    if (!_paneHeader) return;
    NSString *path = _directory.stringByAbbreviatingWithTildeInPath;
    NSString *caption = [NSString stringWithFormat:@"%@ (-%@)", path, _shellName];
    if (![_paneHeader.caption.stringValue isEqual:caption]) {
        _paneHeader.caption.stringValue = caption;
        _paneHeader.toolTip = caption;
    }
}

- (void)resizeGrid {
    if (!_parser) return;
    uint16_t cols = MIN(4096, MAX(2, floor((self.bounds.size.width - 2*inset) / _cw)));
    uint16_t rows = MIN(4096, MAX(2, floor((self.bounds.size.height - self.gridTop - inset) / _ch)));
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
    self.needsDisplay = YES;
}

- (NSString *)currentDirectory {
    struct proc_vnodepathinfo info;
    if (_shellPID > 0 && proc_pidinfo(_shellPID, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        const char *path = info.pvi_cdir.vip_path;
        if (path[0] == '/') {
            NSString *directory = [NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)];
            if (directory && ![_directory isEqualToString:directory]) {
                _directory = directory;
                [self updatePaneHeader];
            }
        }
    }
    return _directory;
}

- (BOOL)hasForegroundJob {
    pid_t foreground = _fd >= 0 ? tcgetpgrp(_fd) : -1;
    return foreground > 0 && foreground != _shellPID;
}

- (void)openDirectoryInFinder:(id)sender {
    if (![NSWorkspace.sharedWorkspace selectFile:nil inFileViewerRootedAtPath:self.currentDirectory]) NSBeep();
}

- (void)updateSessionTitle {
    NSString *title = _shellTitle.length ? _shellTitle : self.currentDirectory.stringByAbbreviatingWithTildeInPath;
    if (![self.window.title isEqual:title]) self.window.title = title;
}

- (void)refreshTitleAfterOutput {
    char *title = mt_take_title(_parser);
    if (title) {
        _shellTitle = [NSString stringWithUTF8String:title];
        mt_string_free(title);
        if (self.window.firstResponder == self) [self updateSessionTitle];
    }
    if (!_titleUpdatePending && (_paneHeader || (!_shellTitle.length && self.window.firstResponder == self))) {
        _titleUpdatePending = YES;
        __weak TerminalView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
            TerminalView *view = weakSelf;
            if (!view) return;
            view->_titleUpdatePending = NO;
            if (!view->_shellTitle.length && view.window.firstResponder == view) [view updateSessionTitle];
            else if (view->_paneHeader) [view currentDirectory];
        });
    }
}

- (void)startSession {
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"TERM"] = @"xterm-256color";
    if (!env[@"LANG"]) env[@"LANG"] = @"en_US.UTF-8";
    NSString * __attribute__((objc_precise_lifetime)) shell = env[@"SHELL"] ?: @"/bin/zsh";
    if (![NSFileManager.defaultManager isExecutableFileAtPath:shell]) shell = @"/bin/zsh";
    _shellName = shell.lastPathComponent;
    env[@"SHELL"] = shell;
    env[@"PWD"] = _directory;
    char **envp = calloc(env.count + 1, sizeof(*envp));
    if (!envp) {
        _status = @"Mémoire insuffisante pour lancer le shell.";
        return;
    }
    NSUInteger copied = 0;
    for (NSString *key in env) {
        const char *entry = [NSString stringWithFormat:@"%@=%@", key, env[key]].UTF8String;
        if (!entry || !(envp[copied] = strdup(entry))) break;
        copied++;
    }

    // Ces pointeurs sont empruntés avant forkpty. Les chaînes restent en vie
    // jusqu’au retour du fork et le fils appelle uniquement des fonctions POSIX.
    NSString * __attribute__((objc_precise_lifetime)) homePath = NSHomeDirectory();
    NSString * __attribute__((objc_precise_lifetime)) loginName = [@"-" stringByAppendingString:_shellName];
    const char *path = shell.fileSystemRepresentation;
    const char *directory = _directory.fileSystemRepresentation;
    const char *home = homePath.fileSystemRepresentation;
    char *args[] = { (char *)loginName.UTF8String, NULL };
    struct winsize size = { .ws_row = _rows, .ws_col = _cols };
    int fd = -1;
    BOOL ready = copied == env.count && path && directory && home && args[0];
    pid_t pid = ready ? forkpty(&fd, NULL, NULL, &size) : -1;
    if (pid == 0) {
        if (chdir(directory) < 0 && chdir(home) < 0) _exit(126);
        execve(path, args, envp);
        _exit(127);
    }
    for (NSUInteger i = 0; i < copied; i++) free(envp[i]);
    free(envp);
    if (pid < 0) {
        _status = ready ? @"Impossible d’ouvrir le pseudo-terminal." : @"Impossible de préparer l’environnement du shell.";
        return;
    }
    _shellPID = pid;
    _fd = fd;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    __weak TerminalView *weakSelf = self;
    dispatch_source_t child = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(child, ^{
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        dispatch_source_cancel(child);
        [weakSelf finishSession];
    });
    dispatch_resume(child);
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
    if (_readerPaused || _fd < 0) return;
    uint8_t bytes[16384];
    ssize_t count = read(_fd, bytes, sizeof(bytes));
    if (count > 0) {
        mt_feed(_parser, bytes, count);
        char *replies = mt_take_replies(_parser);
        if (replies) {
            [self enqueueBytes:replies length:strlen(replies)];
            mt_string_free(replies);
            // Admettre toutes les réponses de cette lecture, puis attendre que
            // le PTY les absorbe avant de traiter un autre bloc de sortie.
            if (_pendingBytes > inputHighWaterMark) {
                dispatch_suspend(_reader);
                _readerPaused = YES;
            }
        }
        [self refreshTitleAfterOutput];
        self.needsDisplay = YES;
    } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
        [self finishSession];
    }
}

- (void)finishSession {
    if (_fd < 0) return;
    [self stopSession];
    id<MTTerminalWindowDelegate> delegate = (id)self.window.delegate;
    [delegate terminalSessionDidEnd:self];
}

- (void)stopSession {
    if (!_reader) return;
    if (_readerPaused) dispatch_resume(_reader);
    _readerPaused = NO;
    dispatch_source_cancel(_reader);
    if (!_writing) dispatch_resume(_writer);
    dispatch_source_cancel(_writer);
    _reader = _writer = nil;
    _pending = nil;
    _pendingBytes = _sent = 0;
    _fd = -1;
    _shellPID = 0;
}

- (void)dealloc {
    [self stopSession];
    if (_parser) mt_free(_parser);
}

- (void)flushInput {
    NSData *head = _pending.firstObject;
    if (!head) return;
    const uint8_t *bytes = head.bytes;
    ssize_t count = write(_fd, bytes + _sent, head.length - _sent);
    if (count < 0) {
        if (errno != EINTR && errno != EAGAIN) [self finishSession];
        return;
    }
    _sent += count;
    _pendingBytes -= count;
    if (_sent == head.length) {
        [_pending removeObjectAtIndex:0];
        _sent = 0;
    }
    if (_readerPaused && _pendingBytes <= inputHighWaterMark / 2) {
        _readerPaused = NO;
        dispatch_resume(_reader);
    }
    if (!_pendingBytes) {
        _pending = nil;
        dispatch_suspend(_writer);
        _writing = NO;
    }
}

- (BOOL)sendText:(NSString *)text asPaste:(BOOL)paste {
    if (!text.length || _fd < 0) return YES;
    BOOL bracketed = paste && mt_bracketed_paste(_parser);
    static const char beginPaste[] = "\033[200~", endPaste[] = "\033[201~";
    NSUInteger framing = bracketed ? sizeof(beginPaste) + sizeof(endPaste) - 2 : 0;
    if (_pendingBytes >= inputHighWaterMark) return NO;
    NSUInteger room = inputHighWaterMark - _pendingBytes;
    // Vérifier le texte et les deux marqueurs avant toute copie ou écriture.
    if (room < framing || text.length > room - framing ||
        [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > room - framing) return NO;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;
    mt_scroll(_parser, INT32_MIN);
    _anchor = _focus = -1;
    self.needsDisplay = YES;
    if (bracketed) [self enqueueBytes:beginPaste length:sizeof(beginPaste)-1];
    [self enqueueBytes:data.bytes length:data.length];
    if (bracketed) [self enqueueBytes:endPaste length:sizeof(endPaste)-1];
    return YES;
}

- (void)sendText:(NSString *)text {
    if (![self sendText:text asPaste:NO]) NSBeep();
}

- (void)enqueueBytes:(const void *)input length:(NSUInteger)count {
    if (!count || _fd < 0) return;
    if (!_pending) _pending = [NSMutableArray array];
    const uint8_t *bytes = input;
    NSUInteger offset = 0;
    while (offset < count) {
        NSMutableData *tail = _pending.lastObject;
        if (!tail || tail.length == inputChunkSize) {
            tail = [NSMutableData data];
            [_pending addObject:tail];
        }
        NSUInteger length = MIN(inputChunkSize - tail.length, count - offset);
        [tail appendBytes:bytes + offset length:length];
        offset += length;
    }
    _pendingBytes += count;
    if (!_writing) {
        _writing = YES;
        dispatch_resume(_writer);
    }
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length ? [characters characterAtIndex:0] : 0;
    BOOL printable = !characters.length || (key >= 32 && key != 127 && !(key >= 0xf700 && key <= 0xf8ff));
    if (self.hasMarkedText || (printable && !(event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand)))) {
        _textKeyEvent = event;
        BOOL handled = [self.inputContext handleEvent:event];
        _textKeyEvent = nil;
        if (handled) return;
    }
    [self sendTerminalKey:event];
}

- (void)sendTerminalKey:(NSEvent *)event {
    NSString *letters = event.charactersIgnoringModifiers;
    if (!letters.length) return;
    unichar key = [letters characterAtIndex:0];
    NSEventModifierFlags flags = event.modifierFlags;
    NSInteger modifier = 1 + !!(flags & NSEventModifierFlagShift) + 2 * !!(flags & NSEventModifierFlagOption)
                           + 4 * !!(flags & NSEventModifierFlagControl);
    NSString *suffix = nil;
    NSInteger number = 0;
    BOOL application = mt_application_cursor(_parser);
    switch (key) {
        case NSUpArrowFunctionKey: suffix = @"A"; break;
        case NSDownArrowFunctionKey: suffix = @"B"; break;
        case NSRightArrowFunctionKey: suffix = @"C"; break;
        case NSLeftArrowFunctionKey: suffix = @"D"; break;
        case NSHomeFunctionKey: suffix = @"H"; break;
        case NSEndFunctionKey: suffix = @"F"; break;
        case NSInsertFunctionKey: number = 2; break;
        case NSDeleteFunctionKey: number = 3; break;
        case NSPageUpFunctionKey: number = 5; break;
        case NSPageDownFunctionKey: number = 6; break;
        case NSF1FunctionKey ... NSF4FunctionKey:
            suffix = [@"PQRS" substringWithRange:NSMakeRange(key - NSF1FunctionKey, 1)];
            application = YES;
            break;
        case NSF5FunctionKey ... NSF12FunctionKey: {
            const NSInteger codes[] = {15,17,18,19,20,21,23,24};
            number = codes[key - NSF5FunctionKey];
            break;
        }
        case NSBackTabCharacter:
        case '\t':
            if (flags & NSEventModifierFlagShift) { [self sendText:@"\033[Z"]; return; }
            // Une tabulation simple est transmise telle quelle.
            __attribute__((fallthrough));
        default: [self sendText:event.characters]; return;
    }
    NSString *sequence;
    if (number) {
        sequence = modifier == 1 ? [NSString stringWithFormat:@"\033[%ld~",(long)number]
            : [NSString stringWithFormat:@"\033[%ld;%ld~",(long)number,(long)modifier];
    } else {
        sequence = modifier == 1 ? [(application ? @"\033O" : @"\033[") stringByAppendingString:suffix]
            : [NSString stringWithFormat:@"\033[1;%ld%@",(long)modifier,suffix];
    }
    [self sendText:sequence];
}

// Le document de saisie est la composition en cours. Le shell possède le texte déjà validé.
- (BOOL)hasMarkedText { return _markedText.length > 0; }
- (NSRange)markedRange { return self.hasMarkedText ? NSMakeRange(0,_markedText.length) : NSMakeRange(NSNotFound,0); }
- (NSRange)selectedRange { return self.hasMarkedText ? _markedSelection : NSMakeRange(0,0); }
- (NSArray *)validAttributesForMarkedText { return @[]; }

- (NSString *)compositionWithText:(id)value replacing:(NSRange)range {
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    if (_markedText && range.location <= _markedText.length && range.length <= _markedText.length - range.location)
        return [_markedText stringByReplacingCharactersInRange:range withString:text];
    return text;
}

- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)replacement {
    NSUInteger start = MIN(replacement.location, _markedText.length);
    if (replacement.location == NSNotFound) start = 0;
    _markedText = [[self compositionWithText:value replacing:replacement] copy];
    start = MIN(start, _markedText.length);
    NSUInteger pos = start + MIN(selection.location, _markedText.length - start);
    _markedSelection = NSMakeRange(pos, MIN(selection.length, _markedText.length - pos));
    [self.inputContext invalidateCharacterCoordinates];
    self.needsDisplay = YES;
}

- (void)insertText:(id)value replacementRange:(NSRange)replacement {
    NSString *text = [self compositionWithText:value replacing:replacement];
    _markedText = nil;
    [self sendText:text];
    self.needsDisplay = YES;
}

- (void)insertText:(id)value { [self insertText:value replacementRange:NSMakeRange(NSNotFound,0)]; }
- (void)unmarkText {
    if (self.hasMarkedText) [self insertText:_markedText replacementRange:NSMakeRange(NSNotFound,0)];
}

- (void)doCommandBySelector:(SEL)selector {
    if (self.hasMarkedText && selector == @selector(cancelOperation:)) {
        _markedText = nil;
        self.needsDisplay = YES;
    } else if (_textKeyEvent) {
        [self sendTerminalKey:_textKeyEvent];
    } else {
        [super doCommandBySelector:selector];
    }
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
    if (!self.hasMarkedText || range.location >= _markedText.length) {
        if (actual) *actual = NSMakeRange(NSNotFound,0);
        return nil;
    }
    range.length = MIN(range.length, _markedText.length - range.location);
    if (actual) *actual = range;
    return [[NSAttributedString alloc] initWithString:[_markedText substringWithRange:range]];
}

- (NSRect)compositionRect {
    uint16_t row = 0, col = 0;
    mt_cursor(_parser,&row,&col);
    CGFloat width = MAX(_cw, [_markedText sizeWithAttributes:@{NSFontAttributeName:_font}].width);
    CGFloat x = MAX(inset, MIN(inset + col*_cw, NSWidth(self.bounds) - inset - width));
    return NSMakeRect(x, self.gridTop + row*_ch, width, _ch);
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    NSRect rect = [self compositionRect];
    NSUInteger index = MIN(range.location,_markedText.length);
    rect.origin.x += [[_markedText substringToIndex:index] sizeWithAttributes:@{NSFontAttributeName:_font}].width;
    rect.size.width = _cw;
    if (actual) *actual = NSMakeRange(index,0);
    return [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    NSPoint local = [self convertPoint:[self.window convertPointFromScreen:point] fromView:nil];
    if (!self.hasMarkedText || !NSPointInRect(local, [self compositionRect])) return NSNotFound;
    CGFloat offset = local.x - NSMinX([self compositionRect]);
    __block NSUInteger nearest = _markedText.length;
    __block CGFloat x = 0;
    [_markedText enumerateSubstringsInRange:self.markedRange options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) {
            x += [part sizeWithAttributes:@{NSFontAttributeName:self->_font}].width;
            if (offset < x) { nearest = range.location; *stop = YES; }
        }];
    return nearest;
}

- (NSInteger)cellAt:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = MAX(0, MIN(_rows-1, floor((p.y-self.gridTop)/_ch)));
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
    if (len && _pendingBytes <= inputHighWaterMark - len) {
        _lastMouseCell = cell;
        [self enqueueBytes:bytes length:len];
    }
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    _localDrag = ![self applicationTracks:event];
    _anchor = _localDrag ? [self cellAt:event] : -1;
    _focus = -1;
    _clickCount = event.clickCount;
    if (!_localDrag) {
        [self reportEvent:event button:0 release:NO motion:NO];
    } else if (_clickCount >= 2) {
        mt_click_range(_parser, (int32_t)_anchor, _clickCount >= 3, &_initialFirst, &_initialLast);
        _anchor = _initialFirst;
        _focus = _initialLast;
    }
    self.needsDisplay = YES;
}

- (void)extendSelectionTo:(NSInteger)cell {
    if (_anchor < 0) return;
    if (_clickCount < 2) { _focus = cell; return; }
    int32_t first, last;
    mt_click_range(_parser, (int32_t)cell, _clickCount >= 3, &first, &last);
    _anchor = MIN(_initialFirst, first);
    _focus = MAX(_initialLast, last);
}

- (void)mouseDragged:(NSEvent *)event {
    if (_localDrag) {
        [self extendSelectionTo:[self cellAt:event]];
        self.needsDisplay = YES;
    } else {
        [self reportEvent:event button:0 release:NO motion:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (_localDrag && _focus >= 0 && _anchor >= 0) {
        [self extendSelectionTo:[self cellAt:event]];
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

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if ([self applicationTracks:event]) return nil;
    [self.window makeKeyWindow];
    [self.window makeFirstResponder:self];
    id<MTTerminalWindowDelegate> provider = (id)self.window.delegate;
    return [provider respondsToSelector:@selector(menuForTerminal:)] ? [provider menuForTerminal:self] : [super menuForEvent:event];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    if ([self applicationTracks:event]) [self reportEvent:event button:2 release:NO motion:NO];
    else {
        NSMenu *menu = [self menuForEvent:event];
        if (menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    }
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

- (void)selectVisibleText:(id)sender {
    _anchor = 0;
    _focus = (NSInteger)_rows * _cols - 1;
    self.needsDisplay = YES;
    [self copy:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(copy:)) return _focus >= 0 && _anchor >= 0;
    if (item.action == @selector(paste:)) return _fd >= 0 &&
        [NSPasteboard.generalPasteboard availableTypeFromArray:@[NSPasteboardTypeString]] != nil;
    return YES;
}

- (BOOL)searchFor:(NSString *)query from:(int32_t)start reverse:(BOOL)reverse {
    if (!query.length) return NO;
    int32_t first, last;
    if (!mt_find(_parser, query.UTF8String, start, reverse, &first, &last)) return NO;
    _anchor = first;
    _focus = last;
    self.needsDisplay = YES;
    return YES;
}

- (void)findText:(id)sender {
    NSAlert *dialog = [NSAlert new];
    dialog.messageText = @"Rechercher dans le terminal";
    NSSearchField *field = [[NSSearchField alloc] initWithFrame:NSMakeRect(0,0,300,26)];
    field.stringValue = _query ?: @"";
    dialog.accessoryView = field;
    [dialog addButtonWithTitle:@"Rechercher"];
    [dialog addButtonWithTitle:@"Annuler"];
    dialog.window.initialFirstResponder = field;
    [dialog beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertFirstButtonReturn || !field.stringValue.length || !self.window) return;
        self->_query = [field.stringValue copy];
        if (![self searchFor:self->_query from:-1 reverse:NO]) {
            NSAlert *empty = [NSAlert new];
            empty.messageText = @"Aucune occurrence dans cet historique";
            [empty beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

- (void)findNext:(id)sender {
    if (!_query.length) { [self findText:sender]; return; }
    if (![self searchFor:_query from:(int32_t)MIN(_anchor,_focus) reverse:NO]) NSBeep();
}

- (void)findPrevious:(id)sender {
    if (!_query.length) { [self findText:sender]; return; }
    int32_t start = _anchor >= 0 ? (int32_t)MIN(_anchor,_focus) : (int32_t)_rows * _cols;
    if (![self searchFor:_query from:start reverse:YES]) NSBeep();
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

- (void)insertPastedText:(NSString *)s {
    if ([self sendText:s asPaste:YES]) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Collage trop volumineux pour la file du terminal";
    alert.informativeText = @"Le collage n’a pas été envoyé. Attendez que le terminal lise les données en attente ou collez le texte par portions de moins de 1 Mio.";
    if (self.window && !self.window.attachedSheet) [alert beginSheetModalForWindow:self.window completionHandler:nil];
    else NSBeep();
}

- (void)paste:(id)sender {
    [self insertPastedText:[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSDictionary *options = @{NSPasteboardURLReadingFileURLsOnlyKey:@YES};
    if (_fd < 0 || !(sender.draggingSourceOperationMask & NSDragOperationCopy)) return NSDragOperationNone;
    NSPasteboard *board = sender.draggingPasteboard;
    BOOL supported = [board canReadObjectForClasses:@[NSURL.class] options:options] ||
                     [board availableTypeFromArray:@[NSPasteboardTypeString]] != nil;
    return supported ? NSDragOperationCopy : NSDragOperationNone;
}

// Les octets de contrôle sont représentés en octal pour ne pas les envoyer au PTY.
static void AppendShellPath(NSMutableString *text, NSString *path) {
    [text appendString:@"'"];
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < path.length; i++) {
        unichar c = [path characterAtIndex:i];
        if (c != '\'' && c >= 32 && c != 127) continue;
        [text appendString:[path substringWithRange:NSMakeRange(start,i-start)]];
        if (c == '\'') [text appendString:@"'\\''"];
        else [text appendFormat:@"'$'\\%03o''", (unsigned)c];
        start = i + 1;
    }
    [text appendString:[path substringFromIndex:start]];
    [text appendString:@"'"];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if ([self draggingEntered:sender] == NSDragOperationNone) return NO;
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    NSMutableString *paths = [NSMutableString string];
    for (NSURL *url in urls) {
        if (!url.isFileURL || !url.path.length) continue;
        if (paths.length) [paths appendString:@" "];
        AppendShellPath(paths, url.path);
    }
    NSString *text = paths.length ? paths : [sender.draggingPasteboard stringForType:NSPasteboardTypeString];
    if (!text.length) return NO;
    [self.window makeFirstResponder:self];
    if (!paths.length) {
        // Empêcher le contenu déposé de terminer lui-même le collage encadré.
        text = [text stringByReplacingOccurrencesOfString:@"\033" withString:@""];
        if (!mt_bracketed_paste(_parser) && ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,32)]].location != NSNotFound || [text containsString:@"\177"])) {
            NSAlert *preview = [NSAlert new];
            preview.messageText = @"Envoyer ce texte au terminal ?";
            preview.informativeText = @"Ce programme traite les retours à la ligne et les caractères de contrôle comme des frappes clavier.";
            NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,400,120)];
            scroll.hasVerticalScroller = YES;
            NSTextView *editor = [[NSTextView alloc] initWithFrame:scroll.bounds];
            editor.richText = NO;
            editor.string = text;
            scroll.documentView = editor;
            preview.accessoryView = scroll;
            [preview addButtonWithTitle:@"Envoyer"];
            [preview addButtonWithTitle:@"Annuler"];
            [preview beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
                if (result == NSAlertFirstButtonReturn) [self insertPastedText:editor.string];
            }];
            return YES;
        }
    }
    [self insertPastedText:text];
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self refreshProfileBackground];
}

- (void)backgroundChanged:(NSNotification *)note {
    if (note.object == _profile) [self refreshProfileBackground];
}

- (void)refreshProfileBackground {
    [self applyBackgroundColor];
    id<MTTerminalWindowDelegate> delegate = (id)self.window.delegate;
    if ([delegate respondsToSelector:@selector(updateBackgroundForWindow:)])
        [delegate updateBackgroundForWindow:self.window];
}

- (void)applyBackgroundColor {
    NSColor *color = [[_profile paletteForAppearance:self.effectiveAppearance] color:MTBackground];
    BOOL dim = _paneHeader && self.window.firstResponder != self;
    if (dim) color = [color blendedColorWithFraction:0.32 ofColor:NSColor.grayColor];
    CGFloat opacity = _profile.backgroundOpacity / 100.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.backgroundColor = [color colorWithAlphaComponent:opacity].CGColor;
    [CATransaction commit];
}

- (void)profilesChanged:(NSNotification *)note {
    if (![MTProfiles.shared.profiles containsObject:_profile]) _profile = MTProfiles.shared.defaultProfile;
    [self refreshProfileBackground];
    self.needsDisplay = YES;
}

- (void)setProfile:(MTProfile *)profile {
    _profile = profile;
    [self refreshProfileBackground];
    self.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer { return YES; }

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.needsDisplay = YES;
}

- (NSRange)visibleSelection {
    NSRange selection = NSMakeRange(0, 0);
    if (_anchor >= 0 && _focus >= 0) {
        NSInteger first = MIN(_anchor, _focus), last = MAX(_anchor, _focus);
        MTPaint edge;
        if (!mt_cell(_parser, first/_cols, first%_cols, &edge) && first%_cols > 0) first--;
        if (mt_cell(_parser, last/_cols, last%_cols, &edge) && edge.wide && last%_cols + 1 < _cols) last++;
        selection = NSMakeRange(first, last - first + 1);
    }
    return selection;
}

- (void)updateLayer {
    if (!_parser) return;
    MTPalette *palette = [_profile paletteForAppearance:self.effectiveAppearance];
    [self applyBackgroundColor];
    BOOL dim = [self.superview isKindOfClass:NSSplitView.class] && self.window.firstResponder != self;
    NSColor *veil = [NSColor colorWithWhite:0.5 alpha:1];

    uint16_t rows = 0, cols = 0, row = 0, col = 0;
    mt_content_size(_parser, &rows, &cols);
    NSRange selection = [self visibleSelection];
    if (selection.length) {
        NSUInteger last = NSMaxRange(selection) - 1;
        rows = MAX(rows, last/_cols + 1);
        cols = MAX(cols, selection.location/_cols == last/_cols ? last%_cols + 1 : _cols);
    }
    BOOL cursor = !_status && self.window.firstResponder == self && mt_cursor(_parser,&row,&col);
    if (cursor) { rows = MAX(rows,row+1); cols = MAX(cols,col+1); }
    // Le fond uni est porté par la couche. Seule la zone dessinée a une image.
    NSRect area = NSZeroRect;
    if (rows && cols)
        area = NSMakeRect(0,0,inset + cols*_cw + _cw,self.gridTop + rows*_ch + 1);
    if (self.hasMarkedText) area = NSUnionRect(area, [self compositionRect]);
    if (_status) area = self.bounds;
    area = NSIntersectionRect(self.bounds, NSMakeRect(0,0,NSMaxX(area),NSMaxY(area)));
    if (NSIsEmptyRect(area)) { self.layer.contents = nil; return; }

    CGFloat scale = self.window.backingScaleFactor ?: 1;
    size_t w = ceil(NSWidth(area)*scale), h = ceil(NSHeight(area)*scale);
    CGContextRef bitmap = CGBitmapContextCreate(NULL,w,h,8,0,NSColorSpace.sRGBColorSpace.CGColorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    if (!bitmap) return;
    CGContextTranslateCTM(bitmap,0,h);
    CGContextScaleCTM(bitmap,scale,-scale);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:YES];
    CGContextClearRect(bitmap, CGRectMake(0,0,w/scale,h/scale));
    [self drawCellsInRows:rows columns:cols palette:palette selection:selection];
    if (cursor) {
        [[palette color:MTCursor] setFill];
        NSRectFill(NSMakeRect(inset+col*_cw,self.gridTop+(1+row)*_ch-2,_cw,2));
    }
    [self drawInputAndStatus:palette];
    if (dim) {
        [[veil colorWithAlphaComponent:0.32] setFill];
        NSRectFillUsingOperation(NSMakeRect(0,0,w/scale,h/scale), NSCompositingOperationSourceAtop);
    }
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contentsScale = scale;
    self.layer.contents = CFBridgingRelease(image);
    [CATransaction commit];
}

- (void)drawCellsInRows:(uint16_t)rows columns:(uint16_t)cols palette:(MTPalette *)palette selection:(NSRange)selection {
    CGFloat gridTop = self.gridTop;
    for (uint16_t row = 0; row < MIN(rows,_rows); row++) {
        @autoreleasepool {
            NSUInteger rowStart = row * _cols;
            NSRange highlight = NSIntersectionRange(selection, NSMakeRange(rowStart, _cols));
            if (highlight.length) {
                [[palette color:MTSelection] setFill];
                NSRectFill(NSMakeRect(inset + (highlight.location - rowStart) * _cw,
                                      gridTop + row * _ch, highlight.length * _cw, _ch));
            }
            for (uint16_t col = 0; col < MIN(cols,_cols); col++) {
                MTPaint cell;
                if (!mt_cell(_parser,row,col,&cell)) continue;
                CGRect rect = CGRectMake(inset+col*_cw,gridTop+row*_ch,_cw*(cell.wide ? 2 : 1),_ch);
                BOOL selected = NSLocationInRange(rowStart + col, highlight);
                if (!selected && cell.bg != MTPaletteReference + MTBackground) {
                    [[palette resolve:cell.bg] setFill];
                    NSRectFill(rect);
                }
                if (!cell.len) continue;
                NSString *s = [[NSString alloc] initWithBytes:cell.bytes length:cell.len encoding:NSUTF8StringEncoding];
                [s drawAtPoint:rect.origin withAttributes:@{
                    NSFontAttributeName:cell.bold ? _bold : _font,
                    NSForegroundColorAttributeName:selected ? [palette color:MTSelectedText] : [palette resolve:cell.fg],
                    NSUnderlineStyleAttributeName:@(cell.underline)
                }];
            }
        }
    }
}

- (void)drawInputAndStatus:(MTPalette *)palette {
    if (self.hasMarkedText && self.window.firstResponder == self) {
        NSRect rect = [self compositionRect];
        [[palette color:MTBackground] setFill];
        NSRectFill(rect);
        NSMutableAttributedString *marked = [[NSMutableAttributedString alloc] initWithString:_markedText attributes:@{
            NSFontAttributeName:_font, NSForegroundColorAttributeName:[palette color:MTForeground],
            NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle)}];
        [marked addAttribute:NSBackgroundColorAttributeName value:[palette color:MTSelection] range:_markedSelection];
        [marked drawAtPoint:rect.origin];
    }
    if (_status) [_status drawAtPoint:NSMakePoint(inset,NSMaxY(self.bounds)-_ch)
                       withAttributes:@{NSForegroundColorAttributeName:[palette color:MTForeground],
                                        NSBackgroundColorAttributeName:[palette color:MTBackground]}];
}
@end
