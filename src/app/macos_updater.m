// Attyx — Sparkle auto-update integration (macOS)
// Initialises SPUStandardUpdaterController for automatic background checks
// and provides a "Check for Updates..." action for the menu bar.
// Skipped entirely when the app is installed via Homebrew Cask.

#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

static SPUStandardUpdaterController* g_updater = nil;

static BOOL isPackageManaged(void) {
    NSString* path = [[NSBundle mainBundle] bundlePath];
    // Homebrew Cask installs live under /opt/homebrew/Caskroom/ or /usr/local/Caskroom/
    if ([path containsString:@"/Caskroom/"]) return YES;
    // Homebrew formula installs (unlikely for .app but check anyway)
    if ([path containsString:@"/Cellar/"]) return YES;
    return NO;
}

void attyx_updater_init(void) {
    if (isPackageManaged()) return;

    // Per-architecture feed URL override.  Info.plist has the arm64 URL as
    // default; override at runtime for Intel builds.
#if !__arm64__
    NSBundle* bundle = [NSBundle mainBundle];
    NSString* x64Feed = @"https://semos.sh/appcast-x64.xml";
    [bundle.infoDictionary setValue:x64Feed forKey:@"SUFeedURL"];
#endif

    g_updater = [[SPUStandardUpdaterController alloc]
        initWithStartingUpdater:YES
                updaterDelegate:nil
             userDriverDelegate:nil];
}

void attyx_updater_check(void) {
    if (g_updater) [g_updater checkForUpdates:nil];
}

BOOL attyx_updater_available(void) {
    return g_updater != nil;
}
