// Attyx — Auto-update (macOS)
// Uses codesign verification and in-place replacement to avoid the
// App Management permission prompt. Reads the appcast feed for version info.
// Skipped entirely when the app is installed via Homebrew Cask.
// Set ATTYX_FEED_URL env var to override the feed URL (useful for testing).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/stat.h>

// ---------------------------------------------------------------------------
// Appcast model + XML parser
// ---------------------------------------------------------------------------

@interface AttyxAppcastItem : NSObject
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *downloadURL;
@property (nonatomic, copy) NSString *releaseNotesURL;
@end

@implementation AttyxAppcastItem
@end

@interface AttyxAppcastParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) AttyxAppcastItem *item;
@property (nonatomic, copy) NSString *element;
@property (nonatomic, assign) BOOL inItem;
@property (nonatomic, strong) NSMutableString *chars;
@end

@implementation AttyxAppcastParser

- (AttyxAppcastItem *)parseData:(NSData *)data {
    NSXMLParser *p = [[NSXMLParser alloc] initWithData:data];
    p.delegate = self;
    _chars = [NSMutableString new];
    [p parse];
    return _item;
}

- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)el
  namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn
    attributes:(NSDictionary *)attrs {
    if ([el isEqualToString:@"item"]) {
        _inItem = YES;
        _item = [AttyxAppcastItem new];
    } else if ([el isEqualToString:@"enclosure"] && _inItem) {
        _item.downloadURL = attrs[@"url"];
        _item.version = attrs[@"sparkle:shortVersionString"]
                     ?: attrs[@"sparkle:version"];
    } else if ([el isEqualToString:@"sparkle:releaseNotesLink"] && _inItem) {
        [_chars setString:@""];
        _element = el;
    }
}

- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s {
    if (_element) [_chars appendString:s];
}

- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)el
  namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn {
    if ([el isEqualToString:@"sparkle:releaseNotesLink"] && _inItem) {
        _item.releaseNotesURL = [_chars stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([el isEqualToString:@"item"]) _inItem = NO;
    _element = nil;
}

@end

// ---------------------------------------------------------------------------
// Version comparison (numeric dotted: "0.2.15" vs "0.3.0")
// ---------------------------------------------------------------------------

static NSComparisonResult cmpVersions(NSString *a, NSString *b) {
    NSArray *ap = [a componentsSeparatedByString:@"."];
    NSArray *bp = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(ap.count, bp.count);
    for (NSUInteger i = 0; i < n; i++) {
        int av = (i < ap.count) ? [ap[i] intValue] : 0;
        int bv = (i < bp.count) ? [bp[i] intValue] : 0;
        if (av < bv) return NSOrderedAscending;
        if (av > bv) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

// ---------------------------------------------------------------------------
// Update window
// ---------------------------------------------------------------------------

@interface AttyxUpdateWindow : NSWindowController <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) AttyxAppcastItem *item;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSButton *installBtn;
@property (nonatomic, strong) NSButton *laterBtn;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, copy) NSString *pendingAppPath;
@end

@implementation AttyxUpdateWindow

- (instancetype)initWithItem:(AttyxAppcastItem *)item {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 460)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"Software Update";
    win.titlebarAppearsTransparent = YES;
    win.movableByWindowBackground = YES;
    [win center];
    self = [super initWithWindow:win];
    if (self) { _item = item; [self buildUI]; }
    return self;
}

- (void)buildUI {
    NSView *v = self.window.contentView;
    CGFloat w = v.bounds.size.width, pad = 24;
    CGFloat top = v.bounds.size.height;

    // --- Header: icon + text ---
    CGFloat iconSize = 72;
    CGFloat headerY = top - 20 - iconSize;
    NSImageView *icon = [[NSImageView alloc]
        initWithFrame:NSMakeRect(pad, headerY, iconSize, iconSize)];
    icon.image = [NSApp applicationIconImage];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [v addSubview:icon];

    CGFloat textX = pad + iconSize + 16;
    CGFloat textW = w - textX - pad;

    NSTextField *title = [NSTextField labelWithString:
        @"A new version of Attyx is available!"];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(textX, headerY + 42, textW, 22);
    [v addSubview:title];

    NSString *cur = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *info = [NSString stringWithFormat:
        @"Attyx %@ is available \u2014 you have %@.", _item.version, cur];
    NSTextField *ver = [NSTextField labelWithString:info];
    ver.font = [NSFont systemFontOfSize:13];
    ver.textColor = [NSColor secondaryLabelColor];
    ver.frame = NSMakeRect(textX, headerY + 20, textW, 18);
    [v addSubview:ver];

    NSTextField *rnl = [NSTextField labelWithString:@"Release Notes:"];
    rnl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    rnl.textColor = [NSColor secondaryLabelColor];
    rnl.frame = NSMakeRect(textX, headerY, textW, 16);
    [v addSubview:rnl];

    CGFloat sepY = headerY - 10;

    // --- Bottom: buttons + status (anchored to bottom) ---
    CGFloat bh = 32, bottomPad = 16;

    CGFloat sep2Y = bottomPad + bh + 12;

    CGFloat installW = 180;
    _installBtn = [[NSButton alloc]
        initWithFrame:NSMakeRect(w - pad - installW, bottomPad, installW, bh)];
    _installBtn.title = @"Install Update";
    _installBtn.bezelStyle = NSBezelStyleRounded;
    _installBtn.keyEquivalent = @"\r";
    _installBtn.target = self;
    _installBtn.action = @selector(onInstall:);
    _installBtn.controlSize = NSControlSizeRegular;
    [v addSubview:_installBtn];

    _laterBtn = [[NSButton alloc]
        initWithFrame:NSMakeRect(w - pad - installW - 12 - 100, bottomPad, 100, bh)];
    _laterBtn.title = @"Later";
    _laterBtn.bezelStyle = NSBezelStyleRounded;
    _laterBtn.keyEquivalent = @"\033";
    _laterBtn.target = self;
    _laterBtn.action = @selector(onLater:);
    _laterBtn.controlSize = NSControlSizeRegular;
    [v addSubview:_laterBtn];

    // Status label (left of buttons)
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.frame = NSMakeRect(pad, bottomPad + 8, w - 2 * pad - 260, 16);
    [v addSubview:_statusLabel];

    // Progress bar (above separator, shown during download)
    _progress = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(pad, sep2Y + 6, w - 2 * pad, 4)];
    _progress.style = NSProgressIndicatorStyleBar;
    _progress.hidden = YES;
    [v addSubview:_progress];

    // --- WebView: fills space between separators ---
    CGFloat webTop = sepY - 8;
    CGFloat webBottom = sep2Y + 14;
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    // Inject dark-mode-aware CSS wrapper
    NSString *cssScript =
        @"var s = document.createElement('style');"
        @"s.textContent = '"
        @"  :root { color-scheme: light dark; }"
        @"  body { font-family: -apple-system, system-ui; font-size: 13px;"
        @"         padding: 16px; margin: 0;"
        @"         color: -apple-system-label;"
        @"         background: transparent; }"
        @"  a { color: -apple-system-blue; }"
        @"';"
        @"document.head.appendChild(s);";
    WKUserScript *userScript = [[WKUserScript alloc]
        initWithSource:cssScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:userScript];

    _webView = [[WKWebView alloc]
        initWithFrame:NSMakeRect(pad, webBottom, w - 2 * pad, webTop - webBottom)
        configuration:config];
    [_webView setValue:@NO forKey:@"drawsBackground"];
    _webView.wantsLayer = YES;
    _webView.layer.cornerRadius = 6;
    _webView.layer.masksToBounds = YES;
    // Subtle inset look
    _webView.layer.borderWidth = 0.5;
    _webView.layer.borderColor =
        [NSColor.separatorColor colorWithAlphaComponent:0.3].CGColor;
    if (_item.releaseNotesURL) {
        NSURL *u = [NSURL URLWithString:_item.releaseNotesURL];
        if (u) [_webView loadRequest:[NSURLRequest requestWithURL:u]];
    }
    [v addSubview:_webView];
}

- (void)onInstall:(id)sender {
    if (_pendingAppPath) {
        // Already downloaded and verified — do the swap now
        _statusLabel.stringValue = @"Installing…";
        _statusLabel.textColor = [NSColor secondaryLabelColor];
        _installBtn.enabled = NO;
        _laterBtn.enabled = NO;
        NSString *curApp = [[NSBundle mainBundle] bundlePath];
        [self swapApp:curApp with:_pendingAppPath];
        return;
    }

    _installBtn.enabled = NO;
    _laterBtn.enabled = NO;
    _progress.hidden = NO;
    _progress.indeterminate = YES;
    [_progress startAnimation:nil];
    _statusLabel.stringValue = @"Downloading update…";

    NSURL *url = [NSURL URLWithString:_item.downloadURL];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:
        [NSURLSessionConfiguration defaultSessionConfiguration]
        delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    [[s downloadTaskWithURL:url] resume];
}

- (void)onLater:(id)sender {
    [self.window close];
}

- (void)showReadyToInstall {
    _progress.hidden = YES;
    _statusLabel.stringValue = @"Ready to install. Attyx will relaunch.";
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _installBtn.title = @"Install and Relaunch";
    _installBtn.enabled = YES;
    _laterBtn.title = @"Later";
    _laterBtn.enabled = YES;
}

// --- NSURLSessionDownloadDelegate ---

- (void)URLSession:(NSURLSession *)s
      downloadTask:(NSURLSessionDownloadTask *)t
      didWriteData:(int64_t)bw
 totalBytesWritten:(int64_t)tw
totalBytesExpectedToWrite:(int64_t)te {
    if (te > 0) {
        _progress.indeterminate = NO;
        _progress.maxValue = 100;
        _progress.doubleValue = (double)tw / (double)te * 100.0;
        _statusLabel.stringValue = [NSString stringWithFormat:
            @"Downloading… %.1f MB / %.1f MB",
            tw / 1048576.0, te / 1048576.0];
    }
}

- (void)URLSession:(NSURLSession *)s
      downloadTask:(NSURLSessionDownloadTask *)t
didFinishDownloadingToURL:(NSURL *)loc {
    _statusLabel.stringValue = @"Verifying update…";
    [self installFromZip:loc];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t
didCompleteWithError:(NSError *)err {
    if (err) [self fail:err.localizedDescription];
}

// --- Install flow ---

- (void)installFromZip:(NSURL *)zipURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [[NSUUID UUID] UUIDString]];
    [fm createDirectoryAtPath:tmp
        withIntermediateDirectories:YES attributes:nil error:nil];

    // Extract zip
    NSTask *unzip = [[NSTask alloc] init];
    unzip.launchPath = @"/usr/bin/ditto";
    unzip.arguments = @[@"-xk", zipURL.path, tmp];
    unzip.standardOutput = [NSPipe pipe];
    unzip.standardError = [NSPipe pipe];
    [unzip launch];
    [unzip waitUntilExit];
    if (unzip.terminationStatus != 0) {
        [self fail:@"Failed to extract update."];
        return;
    }

    // Find the .app bundle
    NSString *appName = nil;
    for (NSString *f in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
        if ([f hasSuffix:@".app"]) { appName = f; break; }
    }
    if (!appName) { [self fail:@"No .app found in archive."]; return; }
    NSString *newApp = [tmp stringByAppendingPathComponent:appName];

    // Verify code signature
    NSTask *cs = [[NSTask alloc] init];
    cs.launchPath = @"/usr/bin/codesign";
    cs.arguments = @[@"--verify", @"--deep", @"--strict", newApp];
    cs.standardOutput = [NSPipe pipe];
    cs.standardError = [NSPipe pipe];
    [cs launch];
    [cs waitUntilExit];
    if (cs.terminationStatus != 0) {
        [self fail:@"Code signature verification failed."];
        return;
    }

    // Verify team ID matches the running app
    NSString *curApp = [[NSBundle mainBundle] bundlePath];
    NSString *curTeam = [self teamID:curApp];
    NSString *newTeam = [self teamID:newApp];
    if (curTeam && newTeam && ![curTeam isEqualToString:newTeam]) {
        [self fail:@"Update signing identity mismatch."];
        return;
    }

    _pendingAppPath = newApp;
    [self showReadyToInstall];
}

- (NSString *)teamID:(NSString *)appPath {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/codesign";
    t.arguments = @[@"-dvv", appPath];
    NSPipe *p = [NSPipe pipe];
    t.standardError = p; // codesign prints info to stderr
    t.standardOutput = [NSPipe pipe];
    [t launch];
    [t waitUntilExit];
    NSString *out = [[NSString alloc]
        initWithData:[p.fileHandleForReading readDataToEndOfFile]
        encoding:NSUTF8StringEncoding];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"TeamIdentifier="]) {
            return [line substringFromIndex:@"TeamIdentifier=".length];
        }
    }
    return nil;
}

- (void)swapApp:(NSString *)curApp with:(NSString *)newApp {
    pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
    NSString *script = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"attyx_update.sh"];

    NSString *sh = [NSString stringWithFormat:
        @"#!/bin/bash\n"
        @"while kill -0 %d 2>/dev/null; do sleep 0.1; done\n"
        @"rm -rf '%@'\n"
        @"mv '%@' '%@'\n"
        @"open '%@'\n"
        @"rm -f '%@'\n",
        pid, curApp, newApp, curApp, curApp, script];

    [sh writeToFile:script atomically:YES
        encoding:NSUTF8StringEncoding error:nil];
    chmod(script.fileSystemRepresentation, 0755);

    NSTask *bg = [[NSTask alloc] init];
    bg.launchPath = @"/bin/bash";
    bg.arguments = @[script];
    [bg launch];

    [NSApp terminate:nil];
}

- (void)fail:(NSString *)msg {
    _statusLabel.stringValue = msg;
    _statusLabel.textColor = [NSColor systemRedColor];
    _progress.hidden = YES;
    _installBtn.enabled = YES;
    _laterBtn.enabled = YES;
}

@end

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

static NSString *g_feedURL = nil;
static AttyxUpdateWindow *g_updateWin = nil;

static BOOL isPackageManaged(void) {
    NSString *p = [[NSBundle mainBundle] bundlePath];
    return [p containsString:@"/Caskroom/"] || [p containsString:@"/Cellar/"];
}

static void doCheck(void) {
    NSURL *url = [NSURL URLWithString:g_feedURL];
    if (!url) return;
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:
      ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) return;
        AttyxAppcastItem *item = [[AttyxAppcastParser new] parseData:data];
        if (!item.version || !item.downloadURL) return;
        NSString *cur = [[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (!cur || cmpVersions(cur, item.version) != NSOrderedAscending)
            return;
        dispatch_async(dispatch_get_main_queue(), ^{
            g_updateWin = [[AttyxUpdateWindow alloc] initWithItem:item];
            [g_updateWin showWindow:nil];
            [g_updateWin.window makeKeyAndOrderFront:nil];
        });
    }] resume];
}

void attyx_updater_init(void) {
    // Environment variable override (for local testing)
    const char *envURL = getenv("ATTYX_FEED_URL");
    if (envURL) g_feedURL = [NSString stringWithUTF8String:envURL];

#ifdef ATTYX_DISABLE_UPDATER
    if (!g_feedURL) return;
#endif

    if (isPackageManaged()) return;

    if (!g_feedURL) {
#if __arm64__
        g_feedURL = [[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"SUFeedURL"];
#else
        g_feedURL = @"https://semos.sh/appcast-x64.xml";
#endif
    }
    if (!g_feedURL) return;

    // Auto-check 5 seconds after launch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ doCheck(); });
}

void attyx_updater_check(void) {
    if (g_feedURL) doCheck();
}

BOOL attyx_updater_available(void) {
    return g_feedURL != nil;
}
