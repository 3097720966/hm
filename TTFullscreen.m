// TTFullscreen v1
// 目的：让 TauriTavern 的 WKWebView 铺满整个窗口（去掉上下黑边）。
// 做法：在 WKWebView 布局时，把它和它的所有父视图的 frame 撑到窗口大小。
// v1 带一个调试浮层（启动 5 秒后出现，点一下消失），用来查看视图层级。
// 不想要浮层：编译时加 -DTT_DEBUG=0。

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#ifndef TT_DEBUG
#define TT_DEBUG 1
#endif

static BOOL gApplying = NO;

static UIWindow *TTWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

static WKWebView *TTFindWeb(UIView *v) {
    if ([v isKindOfClass:WKWebView.class]) return (WKWebView *)v;
    for (UIView *s in v.subviews) {
        WKWebView *r = TTFindWeb(s);
        if (r) return r;
    }
    return nil;
}

// 把 webview 及其所有祖先视图撑满窗口
static void TTFill(WKWebView *wv) {
    if (gApplying) return;
    UIWindow *win = wv.window;
    if (!win) return;
    gApplying = YES;

    UIScrollView *sc = wv.scrollView;
    if (sc.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
        sc.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }

    UIView *v = wv;
    while (v && v != win) {
        UIView *sv = v.superview;
        if (!sv) break;
        CGRect target = [sv convertRect:win.bounds fromView:win];
        CGRect f = v.frame;
        // 只放大，不缩小；已经一样就不动
        if (!CGRectEqualToRect(f, target) && CGRectContainsRect(target, f)) {
            v.frame = target;
        }
        v = sv;
    }
    gApplying = NO;
}

@interface WKWebView (TTFullscreen)
@end

@implementation WKWebView (TTFullscreen)
- (void)tt_layoutSubviews {
    [self tt_layoutSubviews];
    TTFill(self);
}
- (void)tt_setFrame:(CGRect)frame {
    [self tt_setFrame:frame];
    TTFill(self);
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
    NSMutableString *s = [NSMutableString stringWithString:@"TTFullscreen v1\n"];
    [s appendFormat:@"screen %@\n", NSStringFromCGRect(UIScreen.mainScreen.bounds)];
    [s appendFormat:@"window %@\n", NSStringFromCGRect(win.frame)];
    [s appendFormat:@"winSafe %@\n", NSStringFromUIEdgeInsets(win.safeAreaInsets)];
    UIViewController *vc = win.rootViewController;
    if (vc) {
        [s appendFormat:@"rootVC %@ addSafe %@\n", NSStringFromClass(vc.class),
                        NSStringFromUIEdgeInsets(vc.additionalSafeAreaInsets)];
    }
    WKWebView *wv = TTFindWeb(win);
    if (!wv) { [s appendString:@"no WKWebView\n"]; return s; }
    [s appendFormat:@"webSafe %@\n", NSStringFromUIEdgeInsets(wv.safeAreaInsets)];
    [s appendFormat:@"adjust %ld\n", (long)wv.scrollView.contentInsetAdjustmentBehavior];
    [s appendString:@"-- 视图链 (webview -> window) --\n"];
    for (UIView *v = wv; v; v = v.superview) {
        [s appendFormat:@"%@ %@ ar=%d\n", NSStringFromClass(v.class),
                        NSStringFromCGRect(v.frame), (int)v.translatesAutoresizingMaskIntoConstraints];
    }
    return s;
}

static void TTShowOverlay(int retries) {
    UIWindow *win = TTWindow();
    if (!win || !TTFindWeb(win)) {
        if (retries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
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
        Class c = WKWebView.class;
        TTSwizzle(c, @selector(layoutSubviews), @selector(tt_layoutSubviews));
        TTSwizzle(c, @selector(setFrame:), @selector(tt_setFrame:));
#if TT_DEBUG
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TTShowOverlay(3);
        });
#endif
    }
}
