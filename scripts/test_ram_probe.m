// Sonde chargée uniquement dans la copie temporaire préparée par test_ram.py.
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <mach/mach.h>

@protocol MTCompteurs <NSObject>
+ (void)getParserCreations:(uint64_t *)created destructions:(uint64_t *)freed;
@end

@protocol MTActionsDeTest
- (void)splitActivePaneVertically:(BOOL)vertical;
- (void)closeSession:(id)sender;
@end

static NSWindow *window;
static NSHashTable *panes, *headers;
static dispatch_source_t sampler;
static dispatch_queue_t samplingQueue;
static uint64_t closingPeak;
static double initialFootprint;

static void fail(NSString *message) {
    fprintf(stderr, "Mesure impossible : %s\n", message.UTF8String);
    exit(EXIT_FAILURE);
}

static uint64_t footprint(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        fail(@"lecture de l’empreinte physique de mTerm");
    return info.phys_footprint;
}

static void observeViews(NSView *view) {
    if ([view isKindOfClass:NSClassFromString(@"TerminalView")]) [panes addObject:view];
    if ([view isKindOfClass:NSClassFromString(@"MTPaneHeader")]) [headers addObject:view];
    for (NSView *child in view.subviews) observeViews(child);
}

static double report(const char *stage, int expected) {
    Class<MTCompteurs> terminal = NSClassFromString(@"TerminalView");
    if (![terminal respondsToSelector:@selector(getParserCreations:destructions:)])
        fail(@"cette version de mTerm ne fournit pas les compteurs. Recompilez la Release.");
    uint64_t created, freed;
    [terminal getParserCreations:&created destructions:&freed];
    if (freed > created || created - freed != (uint64_t)expected)
        fail([NSString stringWithFormat:@"%s : mt_new=%llu, mt_free=%llu, %d parseur(s) attendu(s)", stage, created, freed, expected]);
    observeViews(window.contentView);
    pid_t children[32];
    int count = proc_listchildpids(getpid(), children, sizeof(children));
    if (count != expected || panes.allObjects.count != expected ||
        headers.allObjects.count != (expected == 1 ? 0 : expected))
        fail([NSString stringWithFormat:@"%s : nombre de shells, de vues ou de bandeaux inattendu", stage]);

    for (NSView *pane in panes) {
        if (NSIsEmptyRect(pane.visibleRect) || NSIsEmptyRect(pane.bounds))
            fail([NSString stringWithFormat:@"%s : volet sans surface visible", stage]);
    }

    uint64_t shellBytes = 0;
    for (int i = 0; i < count; i++) {
        char name[PROC_PIDPATHINFO_MAXSIZE];
        struct rusage_info_v2 usage;
        if (proc_name(children[i], name, sizeof(name)) <= 0 || strcmp(name, "zsh") ||
            proc_pid_rusage(children[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0)
            fail(@"lecture de la mémoire d’un shell zsh");
        shellBytes += usage.ri_phys_footprint;
    }
    double mb = footprint() / 1e6;
    NSString *label = [@(stage) stringByPaddingToLength:28 withString:@" " startingAtIndex:0];
    printf("%s  %9.1f Mo  %27.1f Mo  %6llu  %7llu  %7llu\n", label.UTF8String, mb, shellBytes / 1e6, created, freed, created - freed);
    fflush(stdout);
    return mb;
}

static void startPeakSampler(void) {
    samplingQueue = dispatch_queue_create("mterm.test.pic", DISPATCH_QUEUE_SERIAL);
    sampler = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, samplingQueue);
    dispatch_source_set_timer(sampler, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sampler, ^{
        uint64_t bytes = footprint();
        if (bytes > closingPeak) closingPeak = bytes;
    });
    dispatch_resume(sampler);
}

// La copie de test a son propre bundle ID. Amorcer uniquement ses préférences
// de profil avant que mTerm ne crée la première session.
static void loadProfiles(void) {
    NSString *source = @(getenv("MTERM_TEST_SOURCE"));
    NSString *requested = @(getenv("MTERM_TEST_PROFILE"));
    unsetenv("MTERM_TEST_SOURCE");
    unsetenv("MTERM_TEST_PROFILE");
    NSDictionary *stored = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ColorProfiles"), (__bridge CFStringRef)source));
    NSMutableDictionary *profiles = [stored mutableCopy];
    if (requested.length) {
        NSString *match = nil;
        for (NSDictionary *record in profiles[@"items"]) {
            if ([requested isEqual:record[@"name"]]) {
                if (match) fail([NSString stringWithFormat:@"plusieurs profils portent le nom « %@ »", requested]);
                match = record[@"id"];
            }
        }
        if (!match && (profiles[@"items"] || ![requested isEqual:@"Défaut"]))
            fail([NSString stringWithFormat:@"profil « %@ » introuvable dans l’application mesurée", requested]);
        if (match) profiles[@"default"] = match;
    }
    if (profiles) [NSUserDefaults.standardUserDefaults registerDefaults:@{@"ColorProfiles":profiles}];
}

__attribute__((constructor)) static void startTest(void) {
    unsetenv("DYLD_INSERT_LIBRARIES"); // Les shells sont mesurés sans la sonde.
    @autoreleasepool { loadProfiles(); }
    dispatch_async(dispatch_get_main_queue(), ^{
        panes = NSHashTable.weakObjectsHashTable;
        headers = NSHashTable.weakObjectsHashTable;
        __block NSInteger tick = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            id<MTActionsDeTest> app = (id)NSApp.delegate;
            switch (++tick) {
                case 1: {
                    window = [[(id)app valueForKey:@"windows"] anyObject];
                    if (!window) fail(@"fenêtre de test introuvable");
                    NSRect screen = (window.screen ?: NSScreen.mainScreen).visibleFrame;
                    NSSize size = NSMakeSize(MIN(3058, NSWidth(screen)), MIN(1053, NSHeight(screen)));
                    [window setFrame:NSMakeRect(NSMidX(screen) - size.width / 2, NSMidY(screen) - size.height / 2,
                                                size.width, size.height) display:YES];
                    [NSApp activateIgnoringOtherApps:YES];
                    [window makeKeyAndOrderFront:nil];
                    NSBundle *bundle = NSBundle.mainBundle;
                    printf("mTerm %s (%s) — %.0f × %.0f points, écran %.1f×\n",
                           [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String],
                           [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String],
                           NSWidth(window.frame), NSHeight(window.frame), window.backingScaleFactor);
                    observeViews(window.contentView);
                    id profile = [panes.anyObject valueForKey:@"profile"];
                    if (!profile) fail(@"profil de la session de test introuvable");
                    printf("Profil : %s\n\n", [[profile valueForKey:@"name"] UTF8String]);
                    printf("%s  %s  %s  mt_new  mt_free  Vivants\n", [@"État" stringByPaddingToLength:28 withString:@" " startingAtIndex:0].UTF8String,
                           "RAM de mTerm", "RAM des shells zsh, séparément");
                    puts("----------------------------  ------------  ------------------------------  ------  -------  -------");
                    fflush(stdout);
                    break;
                }
                case 16: initialFootprint = report("1 volet au départ", 1); break;
                case 17: case 33: case 35: case 37:
                    if (NSApp.keyWindow != window) fail(@"garde la fenêtre de test au premier plan");
                    [app splitActivePaneVertically:tick == 17 || tick == 35];
                    break;
                case 32: report("2 volets avec bandeaux", 2); break;
                case 57: report("5 volets avec bandeaux", 5); startPeakSampler(); break;
                case 58: case 60: case 62: case 80:
                    if (NSApp.keyWindow != window) fail(@"la fenêtre de test a perdu le focus");
                    [app closeSession:nil];
                    break;
                case 79: report("Retour à 2 volets", 2); break;
                case 84: report("Retour à 1 volet, après 1 s", 1); break;
                case 100: report("Après 5 s", 1); break;
                case 140: {
                    double final = report("Après 15 s", 1);
                    dispatch_source_cancel(sampler);
                    dispatch_sync(samplingQueue, ^{
                        printf("\nPic de mTerm pendant la fermeture : %.1f Mo\n", closingPeak / 1e6);
                    });
                    printf("Écart final par rapport au départ : %+.1f Mo\n", final - initialFootprint);
                    [timer invalidate];
                    [NSApp terminate:nil];
                    break;
                }
            }
        }];
    });
}
