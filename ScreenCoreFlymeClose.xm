// ScreenCoreFlymeClose.xm
// ============================================================================
//  把 ScreenCore 分屏插件的小窗操作逻辑，改成魅族 Flyme 式：
//    ① 点击小窗外空白处 → 关闭小窗
//    ② 小窗底部新增一条 homebar 小横条，从横条上滑 → 挂起小窗(收成 dock)
//    ③ 从横条下拉 → 小窗变全屏
//
//  不改动 ScreenCore.dylib 二进制（保持 arm64e 签名完整、可卸载回退）。
// ============================================================================

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

// ---------- 让编译器知道 ScreenCore 的这两个类是 UIView 子类 ----------
// 运行时类由原插件提供；这里只给编译期类型，使 self.bounds / addSubview: /
// 向 UIView* 形参传值等通过类型检查。
@interface SCFloatingContainerView : UIView
@end
@interface SCPassthroughRootView : UIView
@end

// ---------- 原插件私有回调（经 delegate 调用）：声明签名以通过 ARC ----------
@interface NSObject (SCFlymePrivateAPI)
- (id)delegate;
- (BOOL)isDocked;
- (void)sc_floatingContainerViewDidRequestClose:(UIView *)container;
- (void)sc_floatingContainerView:(UIView *)container
            didRequestDockFromCorner:(NSInteger)corner;
- (void)sc_floatingContainerViewDidRequestFullscreen:(UIView *)container;
@end

// ---------- 类解析（运行时按类名查找，避免编译期链接 ScreenCore） ----------
static Class g_ContainerClass;      // SCFloatingContainerView

static void sc_ensure_classes(void) {
    if (g_ContainerClass) return;
    g_ContainerClass = NSClassFromString(@"SCFloatingContainerView");
}

// ---------- 收集所有窗口（用 UIWindowScene，替代 iOS15 已废弃的 .windows） ----------
static NSArray<UIWindow *> *sc_all_windows(void) {
    NSMutableArray<UIWindow *> *ws = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w) [ws addObject:w];
            }
        }
    }
    return ws;
}

// ---------- 递归收集子视图中的小窗容器（用静态函数，避免 block retain cycle） ----------
static void sc_collect_recursive(UIView *v, Class containerClass, NSMutableArray *out) {
    for (UIView *sub in v.subviews) {
        if (containerClass && [sub isKindOfClass:containerClass]) {
            [out addObject:sub];
        }
        sc_collect_recursive(sub, containerClass, out);
    }
}

// ---------- 收集所有小窗容器 ----------
static NSArray<UIView *> *sc_all_containers(void) {
    sc_ensure_classes();
    NSMutableArray *result = [NSMutableArray array];
    for (UIWindow *win in sc_all_windows()) {
        if (!win) continue;
        sc_collect_recursive(win, g_ContainerClass, result);
    }
    return result;
}

// ============================================================================
// 点击空白关闭小窗
// ============================================================================

// ---------- 判断：该屏幕点是否为"小窗内容 / dock 之外"的空白 ----------
static BOOL sc_is_blank_tap(UIView *passthrough, CGPoint point) {
    CGPoint screenPt = [passthrough convertPoint:point toView:nil];  // 跨窗口统一坐标

    NSArray *containers = sc_all_containers();
    BOOL hasFloating = NO;
    for (UIView *c in containers) {
        BOOL docked = NO;
        if ([(id)c respondsToSelector:@selector(isDocked)]) {
            docked = [(id)c isDocked];
        }
        if (!docked) hasFloating = YES;   // 存在浮层小窗

        CGRect r = [c convertRect:c.bounds toView:nil];
        if (CGRectContainsPoint(r, screenPt)) {
            return NO;                     // 点在小窗内容 / dock 内 → 非空白
        }
    }
    return hasFloating;                    // 有浮层小窗、但点在小窗之外 → 空白
}

// ---------- 关闭最上层未 docked 的浮层小窗（复用原插件关闭路径） ----------
static void sc_close_top_floating(void) {
    NSArray *containers = sc_all_containers();
    for (UIView *c in [containers reverseObjectEnumerator]) {
        if ([(id)c respondsToSelector:@selector(isDocked)] && [(id)c isDocked]) continue;
        id del = [(id)c delegate];
        if ([del respondsToSelector:@selector(sc_floatingContainerViewDidRequestClose:)]) {
            [del sc_floatingContainerViewDidRequestClose:c];
            return;
        }
    }
}

// ============================================================================
// homebar：小窗底部横条 + 上滑挂起 / 下拉全屏
// ============================================================================

static const void *kFlymeTouchKey = &kFlymeTouchKey;   // 底部透明 touch 层(含横条)
static const void *kFlymePanKey   = &kFlymePanKey;     // 上滑/下拉手势
static const void *kFlymeBarKey   = &kFlymeBarKey;     // 横条(视觉)

// Flyme 挂起的 dock corner 值（逆向：corner ∈{2,4}→右、∈{1,3}→左）。
// 按插件设置 splitDefaultDockSide(0=左/1=右，默认左) 映射；真机不符就改这两个宏。
#define kFlymeCornerForLeftDock  1
#define kFlymeCornerForRightDock 2

static NSInteger sc_flyme_dock_corner(void) {
    NSNumber *v = (NSNumber *)CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"),
        CFSTR("com.susudear.screencoreprefs")));
    NSInteger side = (v && [v isKindOfClass:NSNumber.class]) ? [v integerValue] : 0;
    return (side == 1) ? kFlymeCornerForRightDock : kFlymeCornerForLeftDock;
}

// 挂起小窗成 dock（复用原插件挂起入口）
static void sc_flyme_dock(UIView *container) {
    id del = [(id)container delegate];
    if ([del respondsToSelector:@selector(sc_floatingContainerView:didRequestDockFromCorner:)]) {
        [del sc_floatingContainerView:container
                didRequestDockFromCorner:sc_flyme_dock_corner()];
    }
}

// 小窗变全屏（复用原插件"全屏"入口，与 sc_handleFullscreenTap 同链）
static void sc_flyme_fullscreen(UIView *container) {
    id del = [(id)container delegate];
    if ([del respondsToSelector:@selector(sc_floatingContainerViewDidRequestFullscreen:)]) {
        [del sc_floatingContainerViewDidRequestFullscreen:container];
    }
}

%hook SCFloatingContainerView

- (void)layoutSubviews {
    %orig;
    // dock 态不显示 homebar
    if ([(id)self respondsToSelector:@selector(isDocked)] && [(id)self isDocked]) {
        UIView *tl = objc_getAssociatedObject(self, kFlymeTouchKey);
        tl.hidden = YES;
        return;
    }

    // ---- 懒创建：homebar 底部 touch 层 + 手势 + 视觉横条 ----
    UIView *touchLayer = objc_getAssociatedObject(self, kFlymeTouchKey);
    if (!touchLayer) {
        touchLayer = [[UIView alloc] initWithFrame:CGRectZero];
        touchLayer.backgroundColor = [UIColor clearColor];
        touchLayer.userInteractionEnabled = YES;
        [self addSubview:touchLayer];
        objc_setAssociatedObject(self, kFlymeTouchKey, touchLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(sc_flyme_handlePan:)];
        pan.maximumNumberOfTouches = 1;
        [touchLayer addGestureRecognizer:pan];
        objc_setAssociatedObject(self, kFlymePanKey, pan,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        bar.layer.cornerRadius = 2.5;
        bar.layer.shadowColor = [UIColor blackColor].CGColor;
        bar.layer.shadowOpacity = 0.25;
        bar.layer.shadowRadius = 1.5;
        bar.layer.shadowOffset = CGSizeMake(0, 0.5);
        bar.userInteractionEnabled = NO;
        [touchLayer addSubview:bar];
        objc_setAssociatedObject(self, kFlymeBarKey, bar,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // ---- 布局：touch 层贴容器底部，横条居中 ----
    touchLayer.hidden = NO;
    CGRect b = self.bounds;
    CGFloat hitH = 28;                                   // 手势承载区高度
    touchLayer.frame = CGRectMake(0, b.size.height - hitH, b.size.width, hitH);

    UIView *bar = objc_getAssociatedObject(self, kFlymeBarKey);
    if (bar) {
        CGFloat bw = MIN(b.size.width * 0.4, 120.0);
        CGFloat bH = 4.5;
        bar.frame = CGRectMake((b.size.width - bw) / 2.0,
                               hitH - bH - 7.0,
                               bw, bH);
    }
}

- (void)sc_flyme_handlePan:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint v = [g velocityInView:self];
    if (v.y < -400) {                 // 上滑 → 挂起小窗成 dock
        sc_flyme_dock(self);
    } else if (v.y > 400) {           // 下拉 → 小窗变全屏
        sc_flyme_fullscreen(self);
    }
}

%end

// ============================================================================
// Hook：全屏手势层（点击空白必达这一层）
// ============================================================================
%hook SCPassthroughRootView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL orig = %orig;
    if (sc_is_blank_tap(self, point)) {   // 空白点击且有浮层小窗 → 捕获
        return YES;
    }
    return orig;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    if (touch) {
        CGPoint p = [touch locationInView:self];
        if (sc_is_blank_tap(self, p)) {
            sc_close_top_floating();     // 点击空白 → 关闭浮层小窗
            return;                      // 吞掉这次触摸
        }
    }
    %orig;
}

%end
