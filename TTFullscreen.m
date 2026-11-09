// TTFullscreen v4
// 目的：去掉 TauriTavern 的上下黑边（WKWebView 被缩在安全区里，约 47pt/34pt）。
// v4 相对 v3 的改动：修复 2.4.0 唤起输入法卡死/卡退
//  原因：2.4.0 新增原生 KeyboardScrollView/WindowHost，键盘弹出时原生会改 webview
//        和父视图的 frame 把内容顶起来；而 v3 的 setFrame/layoutSubviews 钩子 +
//        0.5s 定时器会立刻把它们撑回整个窗口，两边每一帧互相覆盖，主线程被打满。
//  做法：键盘显示期间（以及收起后 0.6s 内）暂停一切干预，让原生自己处理；
//        键盘收起、动画结束后再恢复去黑边。
// 备用开关：编译加 -DTT_FORCE_FRAME=0 则不再强改 frame，只保留负的 additionalSafeAreaInsets。
// 不要调试浮层：编译时加 -DTT_DEBUG=0

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#ifndef TT_DEBUG
#define TT_DEBUG 1
#endif

#ifndef TT_FORCE_FRAME
#define TT_FORCE_FRAME 1
#endif

static BOOL gApplying = NO;
static NSUInteger gTicks = 0;
static NSUInteger gLogCount = 0;
static BOOL gKeyboardUp = NO;          // 键盘是否显示中
static NSTimeInterval gResumeAt = 0;   // 键盘收起后，到这个时间点前仍保持暂停

static NSTimeInterval TTNow(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

// 键盘期间 / 刚收起时暂停所有干预
static BOOL TTPaused(void) {
    return gKeyboardUp || TTNow() < gResumeAt;
}

static void TTLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TTLog(NSString *fmt, ...) {
    if (gLogCount > 150) return;
    gLogCount++;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return;
    NSString *path = [dir stringByAppendingPathComponent:@"TTFullscreen.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static UIWindow *TTWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    if (fallback) return fallback;
    // 没有 UIScene（tao/wry 常见）：走旧接口
    UIApplication *app = UIApplication.sharedApplication;
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow) return w;
        if (!fallback) fallback = w;
    }
    if (fallback) return fallback;
    id<UIApplicationDelegate> d = app.delegate;
    if ([d respondsToSelector:@selector(window)]) return [d window];
    return nil;
}

static WKWebView *TTFindWeb(UIView *v) {
    if ([v isKindOfClass:WKWebView.class]) return (WKWebView *)v;
    for (UIView *s in v.subviews) {
        WKWebView *r = TTFindWeb(s);
        if (r) return r;
    }
    return nil;
}

// 抵消系统安全区（rootVC 以及它 present 出来的 VC）
static void TTCancelSafe(UIWindow *win) {
    UIEdgeInsets dev = win.safeAreaInsets; // 设备级安全区，不含 VC 的 additional
    UIEdgeInsets want = UIEdgeInsetsMake(-dev.top, -dev.left, -dev.bottom, -dev.right);
    UIViewController *vc = win.rootViewController;
    while (vc) {
        if (!UIEdgeInsetsEqualToEdgeInsets(vc.additionalSafeAreaInsets, want)) {
            vc.additionalSafeAreaInsets = want;
            TTLog(@"additionalSafeAreaInsets -> %@ on %@", NSStringFromUIEdgeInsets(want), NSStringFromClass(vc.class));
        }
        vc = vc.presentedViewController;
    }
}

// 把 webview 及所有祖先视图撑满窗口
static void TTFill(WKWebView *wv) {
    UIWindow *win = wv.window;
    if (!win) return;

    UIScrollView *sc = wv.scrollView;
    if (sc.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
        sc.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }

#if TT_FORCE_FRAME
    UIView *v = wv;
    while (v && v != win) {
        UIView *sv = v.superview;
        if (!sv) break;
        CGRect target = [sv convertRect:win.bounds fromView:win];
        if (!CGRectEqualToRect(v.frame, target)) {
            TTLog(@"frame %@ %@ -> %@", NSStringFromClass(v.class),
                  NSStringFromCGRect(v.frame), NSStringFromCGRect(target));
            v.frame = target;
        }
        v = sv;
    }
#endif
}

static void TTInjectInsets(WKWebView *wv, UIWindow *win) {
    UIEdgeInsets d = win.safeAreaInsets;
    NSString *js = [NSString stringWithFormat:
        @"(function(){var s=document.documentElement&&document.documentElement.style;"
        @"if(!s)return;"
        @"s.setProperty('--tt-inset-top','%.0fpx');"
        @"s.setProperty('--tt-inset-bottom','%.0fpx');})();",
        d.top, d.bottom];
    [wv evaluateJavaScript:js completionHandler:nil];
}

static void TTApplyAll(void) {
    if (gApplying) return;
    if (TTPaused()) return;          // v4：键盘期间不碰
    UIWindow *win = TTWindow();
    if (!win) return;
    gApplying = YES;
    TTCancelSafe(win);
    WKWebView *wv = TTFindWeb(win);
    if (wv) {
        TTFill(wv);
        if (gTicks % 2 == 0) TTInjectInsets(wv, win);
    }
    gApplying = NO;
}

@interface WKWebView (TTFullscreen)
@end

@implementation WKWebView (TTFullscreen)
- (void)tt_layoutSubviews {
    [self tt_layoutSubviews];
    if (!gApplying && !TTPaused()) {
        gApplying = YES;
        UIWindow *win = self.window;
        if (win) { TTCancelSafe(win); TTFill(self); }
        gApplying = NO;
    }
}
- (void)tt_setFrame:(CGRect)frame {
    [self tt_setFrame:frame];
    if (!gApplying && !TTPaused()) {
        gApplying = YES;
        UIWindow *win = self.window;
        if (win) TTFill(self);
        gApplying = NO;
    }
}
@end

static void TTSwizzle(Class c, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(c, orig);
    Method m2 = class_getInstanceMethod(c, repl);
    if (!m1 || !m2) return;
    if (class_addMethod(c, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(c, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

// 键盘状态监听：键盘显示时暂停，收起后等动画结束再恢复
static void TTInstallKeyboardObservers(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mq = NSOperationQueue.mainQueue;

    [nc addObserverForName:UIKeyboardWillShowNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        gKeyboardUp = YES;
        TTLog(@"keyboard will show -> paused");
    }];

    [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        gKeyboardUp = NO;
        gResumeAt = TTNow() + 0.6;
        TTLog(@"keyboard will hide -> resume in 0.6s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TTApplyAll();
        });
    }];

    // 兜底：回到前台时重置状态，避免键盘通知丢失导致一直暂停
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        gKeyboardUp = NO;
    }];
}

#if TT_DEBUG
static NSString *TTDump(UIWindow *win) {
    NSMutableString *s = [NSMutableString stringWithString:@"TTFullscreen v4 (loaded)\n"];
    [s appendFormat:@"screen %@\n", NSStringFromCGRect(UIScreen.mainScreen.bounds)];
    [s appendFormat:@"window %@\n", NSStringFromCGRect(win.frame)];
    [s appendFormat:@"devSafe %@\n", NSStringFromUIEdgeInsets(win.safeAreaInsets)];
    UIViewController *vc = win.rootViewController;
    if (vc) {
        [s appendFormat:@"rootVC %@\naddSafe %@\n", NSStringFromClass(vc.class),
                        NSStringFromUIEdgeInsets(vc.additionalSafeAreaInsets)];
    }
    WKWebView *wv = TTFindWeb(win);
    if (!wv) { [s appendString:@"no WKWebView\n"]; return s; }
    [s appendFormat:@"webSafe %@\n", NSStringFromUIEdgeInsets(wv.safeAreaInsets)];
    [s appendString:@"-- webview -> window --\n"];
    for (UIView *v = wv; v; v = v.superview) {
        [s appendFormat:@"%@ %@ ar=%d\n", NSStringFromClass(v.class),
                        NSStringFromCGRect(v.frame), (int)v.translatesAutoresizingMaskIntoConstraints];
    }
    return s;
}

static void TTShowOverlay(int retries) {
    UIWindow *win = TTWindow();
    if (!win) {
        if (retries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                TTShowOverlay(retries - 1);
            });
        }
        return;
    }
    CGFloat w = win.bounds.size.width - 16;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(8, 90, w, 10)];
    l.numberOfLines = 0;
    l.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    l.textColor = UIColor.greenColor;
    l.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.88];
    l.text = TTDump(win);
    CGSize sz = [l sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    l.frame = CGRectMake(8, 90, w, sz.height);
    l.userInteractionEnabled = YES;
    [l addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:l action:@selector(removeFromSuperview)]];
    [win addSubview:l];
}
#endif

__attribute__((constructor)) static void TTInit(void) {
    @autoreleasepool {
        TTLog(@"TTFullscreen v4 constructor ran");
        Class c = WKWebView.class;
        TTSwizzle(c, @selector(layoutSubviews), @selector(tt_layoutSubviews));
        TTSwizzle(c, @selector(setFrame:), @selector(tt_setFrame:));
        dispatch_async(dispatch_get_main_queue(), ^{
            TTInstallKeyboardObservers();
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                gTicks++;
                TTApplyAll();
            }];
        });
#if TT_DEBUG
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TTShowOverlay(5);
        });
#endif
    }
}
