#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#pragma mark - 扫描令牌

@interface ScanToken : NSObject
@property (atomic, assign) BOOL cancelled;
@end

@implementation ScanToken
@end

#pragma mark - 桥接

@interface AppBridge : NSObject <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, weak) WKWebView *web;
@property (nonatomic, strong) ScanToken *token;
@property (nonatomic, strong) NSArray *lastBatch;
@end

static NSSet *SkipDirs(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"Caches", @"Cache", @".Trash", @"Trash",
            @"node_modules", @".git", @"DerivedData", @".build",
            @".npm", @".cache", @".pnpm-store", @".yarn", @".gradle",
            @".rustup", @".cargo", @"__pycache__", @".venv", @"venv",
            @"Pods", @".next", @".turbo", @".parcel-cache"
        ]];
    });
    return set;
}

/// 扫描整块启动盘时需要跳过的系统位置（无法访问或纯系统数据）
static NSSet *SystemSkipPaths(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"/System", @"/usr", @"/bin", @"/sbin", @"/dev", @"/cores",
            @"/Volumes", @"/private/var/db", @"/private/var/folders",
            @"/private/var/vm", @"/private/var/log", @"/private/var/tmp",
            @"/private/var/run", @"/private/var/root",
            @"/.Spotlight-V100", @"/.fseventsd", @"/.DocumentRevisions-V100",
            @"/.TemporaryItems", @"/.Trashes", @"/Library/Developer/CoreSimulator"
        ]];
    });
    return set;
}

@implementation AppBridge

- (void)send:(NSDictionary *)event {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!json) return;
    NSString *js = [NSString stringWithFormat:@"window.__native && window.__native(%@);", json];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.web evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    const char *jsEnv = getenv("QS_JS");
    if (!jsEnv) return;
    NSString *js = [NSString stringWithUTF8String:jsEnv];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [webView evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *cmd = body[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]]) return;

    if ([cmd isEqualToString:@"ready"]) {
        [self send:@{@"type": @"init",
                     @"home": NSHomeDirectory(),
                     @"version": @"1.1.0"}];
    } else if ([cmd isEqualToString:@"scan"]) {
        [self scanWith:body];
    } else if ([cmd isEqualToString:@"cancel"]) {
        [self.token setCancelled:YES];
    } else if ([cmd isEqualToString:@"trash"]) {
        [self trash:body[@"paths"]];
    } else if ([cmd isEqualToString:@"undo"]) {
        [self undo];
    } else if ([cmd isEqualToString:@"reveal"]) {
        NSMutableArray *urls = [NSMutableArray array];
        for (NSString *p in body[@"paths"]) {
            if ([p isKindOfClass:[NSString class]]) {
                [urls addObject:[NSURL fileURLWithPath:p]];
            }
        }
        if (urls.count) {
            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
        }
    } else if ([cmd isEqualToString:@"open"]) {
        NSString *p = body[@"path"];
        if ([p isKindOfClass:[NSString class]]) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p]];
        }
    } else if ([cmd isEqualToString:@"copyPath"]) {
        NSString *p = body[@"path"];
        if ([p isKindOfClass:[NSString class]]) {
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:p forType:NSPasteboardTypeString];
        }
    } else if ([cmd isEqualToString:@"chooseFolder"]) {
        [self chooseFolder];
    } else if ([cmd isEqualToString:@"openTrash"]) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@".Trash"]]];
    } else if ([cmd isEqualToString:@"disk"]) {
        [self sendDisk];
    }
}

- (void)chooseFolder {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"扫描此文件夹";
    panel.message = @"选择一个要分析的文件夹";
    panel.directoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        [self send:@{@"type": @"root", @"root": panel.URL.path}];
    }
}

- (void)sendDisk {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];
    long long total = [attrs[NSFileSystemSize] longLongValue];
    long long free = [attrs[NSFileSystemFreeSize] longLongValue];
    [self send:@{@"type": @"disk", @"total": @(total), @"free": @(free)}];
}

#pragma mark 扫描

- (void)scanWith:(NSDictionary *)opts {
    [self.token setCancelled:YES];
    ScanToken *tok = [ScanToken new];
    self.token = tok;

    NSString *root = opts[@"root"];
    if (![root isKindOfClass:[NSString class]] || root.length == 0) root = NSHomeDirectory();
    long long minSize = [opts[@"minSize"] longLongValue];
    BOOL hidden = [opts[@"includeHidden"] boolValue];
    BOOL skip = [opts[@"skipCaches"] boolValue];
    BOOL wholeDisk = [root isEqualToString:@"/"];
    NSSet *skipPaths = wholeDisk ? SystemSkipPaths() : [NSSet set];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (getenv("QS_LOG")) fprintf(stderr, "QS: block start root=%s\n", [root UTF8String]);
        NSDate *started = [NSDate date];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *keys = @[NSURLIsRegularFileKey, NSURLIsDirectoryKey,
                          NSURLIsSymbolicLinkKey, NSURLFileSizeKey,
                          NSURLContentModificationDateKey];

        NSDirectoryEnumerationOptions options = NSDirectoryEnumerationSkipsPackageDescendants;
        if (!hidden) options |= NSDirectoryEnumerationSkipsHiddenFiles;

        NSURL *rootURL = [NSURL fileURLWithPath:root];
        if (getenv("QS_LOG")) fprintf(stderr, "QS: before enumerator\n");
        NSDirectoryEnumerator *en = [fm enumeratorAtURL:rootURL
                             includingPropertiesForKeys:keys
                                                options:options
                                           errorHandler:^BOOL(NSURL *url, NSError *error) {
            return YES;
        }];


        NSMutableArray *items = [NSMutableArray arrayWithCapacity:8192];
        long long scanned = 0;
        long long bytes = 0;
        BOOL truncated = NO;
        NSDate *lastPush = [NSDate dateWithTimeIntervalSince1970:0];

        for (NSURL *url in en) {
            if (tok.cancelled) break;

            NSDictionary *values = [url resourceValuesForKeys:keys error:NULL];
            if (!values) continue;
            scanned++;

            if (-[lastPush timeIntervalSinceNow] > 0.1) {
                lastPush = [NSDate date];
                [self send:@{@"type": @"progress",
                             @"scanned": @(scanned),
                             @"matched": @(items.count),
                             @"bytes": @(bytes),
                             @"current": url.path ?: @""}];
            }

            if ([values[NSURLIsDirectoryKey] boolValue]) {
                NSString *dirPath = url.path;
                BOOL skipIt = NO;
                if (wholeDisk && dirPath && [skipPaths containsObject:dirPath]) skipIt = YES;
                if (skip && [SkipDirs() containsObject:url.lastPathComponent]) skipIt = YES;
                if (skipIt) [en skipDescendants];
                continue;
            }
            if ([values[NSURLIsSymbolicLinkKey] boolValue]) continue;
            if (![values[NSURLIsRegularFileKey] boolValue]) continue;

            long long size = [values[NSURLFileSizeKey] longLongValue];
            if (size < minSize) continue;

            NSString *path = url.path;
            if (!path) continue;
            NSString *name = url.lastPathComponent ?: @"";
            NSString *folder = [path stringByDeletingLastPathComponent];
            NSString *ext = url.pathExtension.lowercaseString ?: @"";
            NSTimeInterval mt = [values[NSURLContentModificationDateKey] timeIntervalSince1970];

            [items addObject:@[path, name, folder, @(size), @((long long)(mt * 1000.0)), ext]];
            bytes += size;

            if (items.count >= 300000) { truncated = YES; break; }
        }

        NSTimeInterval duration = -[started timeIntervalSinceNow];
        BOOL cancelled = tok.cancelled;

        [self send:@{@"type": @"done",
                     @"items": items,
                     @"scanned": @(scanned),
                     @"bytes": @(bytes),
                     @"duration": @(duration),
                     @"truncated": @(truncated),
                     @"cancelled": @(cancelled),
                     @"root": root}];
    });
}

#pragma mark 删除（走废纸篓）

- (void)trash:(NSArray *)paths {
    if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray *records = [NSMutableArray array];
        NSMutableArray *failed = [NSMutableArray array];

        for (NSString *path in paths) {
            if (![path isKindOfClass:[NSString class]]) continue;
            NSURL *url = [NSURL fileURLWithPath:path];
            NSURL *resulting = nil;
            NSError *error = nil;
            if ([fm trashItemAtURL:url resultingItemURL:&resulting error:&error]) {
                [records addObject:@{@"path": path, @"trashed": resulting.path ?: @""}];
            } else {
                [failed addObject:path];
            }
        }

        self.lastBatch = records;

        [self send:@{@"type": @"trashed",
                     @"removed": [records valueForKey:@"path"],
                     @"failed": failed}];
    });
}

- (void)undo {
    NSArray *batch = self.lastBatch;
    self.lastBatch = nil;
    if (batch.count == 0) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSInteger restored = 0;
        for (NSDictionary *record in [batch reverseObjectEnumerator]) {
            NSString *src = record[@"trashed"];
            NSString *dst = record[@"path"];
            if (src.length == 0 || dst.length == 0) continue;
            if ([fm fileExistsAtPath:dst]) continue;
            if ([fm moveItemAtPath:src toPath:dst error:NULL]) restored++;
        }
        [self send:@{@"type": @"undone", @"restored": @(restored)}];
    });
}

@end

#pragma mark - 主程序

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) AppBridge *bridge;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];

    NSRect frame = NSMakeRect(0, 0, 1180, 790);
    NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:mask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = @"清盘";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.backgroundColor = [NSColor colorWithSRGBRed:0.051 green:0.114 blue:0.212 alpha:1.0];
    self.window.minSize = NSMakeSize(1000, 660);
    [self.window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [self.window center];
    self.window.releasedWhenClosed = NO;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    self.bridge = [AppBridge new];
    [ucc addScriptMessageHandler:self.bridge name:@"app"];
    config.userContentController = ucc;
    config.suppressesIncrementalRendering = NO;

    WKWebView *web = [[WKWebView alloc] initWithFrame:self.window.contentView.bounds
                                        configuration:config];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.bridge.web = web;
    web.navigationDelegate = self.bridge;

    if (@available(macOS 12.0, *)) {
        web.underPageBackgroundColor = [NSColor colorWithSRGBRed:0.016 green:0.035 blue:0.059 alpha:1.0];
    }
    @try {
        [web setValue:@NO forKey:@"drawsBackground"];
    } @catch (NSException *e) { }

    [self.window.contentView addSubview:web];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    NSString *html = [NSString stringWithContentsOfFile:htmlPath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (html.length > 0) {
        NSURL *base = [NSURL fileURLWithPath:[htmlPath stringByDeletingLastPathComponent]];
        [web loadHTMLString:html baseURL:base];
    } else {
        [web loadHTMLString:@"<body style='background:#04090F;color:#fff;font:14px -apple-system'>界面文件缺失</body>"
                    baseURL:nil];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self buildMenu];
    [self runSelfCheckIfNeeded:web];
}

// 仅用于开发自检：QS_JS 注入脚本，QS_SNAPSHOT 保存快照后退出
- (void)runSelfCheckIfNeeded:(WKWebView *)web {

    const char *shot = getenv("QS_SNAPSHOT");
    if (!shot) return;
    NSString *path = [NSString stringWithUTF8String:shot];

    double delay = 4.0;
    const char *delayEnv = getenv("QS_SNAP_DELAY");
    if (delayEnv) delay = atof(delayEnv);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WKSnapshotConfiguration *cfg = [WKSnapshotConfiguration new];
        [web takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *image, NSError *error) {
            if (image) {
                NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:path atomically:YES];
            }
            [NSApp terminate:nil];
        }];
    });
}

- (void)buildMenu {
    NSMenu *menubar = [NSMenu new];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menubar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 清盘" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"隐藏 清盘" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 清盘" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [menubar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    NSApp.mainMenu = menubar;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
