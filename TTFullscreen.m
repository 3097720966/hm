// TTFullscreen v3
// 目的：去掉 TauriTavern 的上下黑边（WKWebView 被缩在安全区里，约 47pt/34pt）。
// v2 做法（多管齐下）：
//  1. 给 rootViewController 设置负的 additionalSafeAreaInsets，抵消系统安全区
//     （Auto Layout 钉在 safeAreaLayoutGuide 上的情况靠这条解决）
//  2. 把 WKWebView 及其所有父视图的 frame 强制撑满窗口（frame 布局的情况靠这条）
//  3. 0.5s 定时器 + 布局钩子反复执行，防止被原生代码改回去
//  4. 把真实安全区写进网页的 CSS 变量 --tt-inset-top / --tt-inset-bottom
//  5. 启动 3 秒后出现绿色调试浮层 "TTFullscreen v3"（点一下消失）。
//     没看到这个浮层 = dylib 根本没被加载（问题在注入，不在代码）。
// 不要浮层：编译时加 -DTT_DEBUG=0

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#ifndef TT_DEBUG
#define TT_DEBUG 1
#endif

static BOOL gApplying = NO;
static NSUInteger gTicks = 0;
static NSUInteger gLogCount = 0;

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
    if (!gApplying) {
        gApplying = YES;
        UIWindow *win = self.window;
        if (win) { TTCancelSafe(win); TTFill(self); }
        gApplying = NO;
    }
}
- (void)tt_setFrame:(CGRect)frame {
    [self tt_setFrame:frame];
    if (!gApplying) {
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

#if TT_DEBUG
static NSString *TTDump(UIWindow *win) {
    NSMutableString *s = [NSMutableString stringWithString:@"TTFullscreen v3 (loaded)\n"];
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
        TTLog(@"TTFullscreen v3 constructor ran");
        Class c = WKWebView.class;
        TTSwizzle(c, @selector(layoutSubviews), @selector(tt_layoutSubviews));
        TTSwizzle(c, @selector(setFrame:), @selector(tt_setFrame:));
        dispatch_async(dispatch_get_main_queue(), ^{
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
