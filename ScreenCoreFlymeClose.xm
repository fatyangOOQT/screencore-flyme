// ScreenCoreFlymeClose.xm
// ============================================================================
//  把 ScreenCore 分屏插件的小窗操作逻辑，改成魅族 Flyme 式：
//    ① 点击小窗外空白处 → 关闭小窗
//    ② 小窗底部新增一条 homebar 小横条，从横条上滑 → 挂起小窗(收成 dock)
//    ③ 从横条下拉 → 小窗变全屏
//
//  原理（基于对 ScreenCore.dylib v1.0.7 的逆向）：
//   - 小窗内容容器 = SCFloatingContainerView（含 contentClipView / delegate）
//   - 原插件关闭按钮通过  [delegate sc_floatingContainerViewDidRequestClose:容器] 关闭小窗
//   - 原插件"挂起成 dock"通过
//        [delegate sc_floatingContainerView:容器 didRequestDockFromCorner:corner]
//     其中 corner 由原代码从某个 view 的 tag 读取；
//     逆向 sc_dockSession:fromCorner: 确认 corner 被归一化映射到 dock side(0=左/1=右)：
//        corner ∈ {2,4} → 右； corner ∈ {1,3} → 左
//   - 全屏手势层 = SCGestureOverlayWindow -> SCPassthroughRootView，
//     所有"小窗内容之外"的空白点击都会落到这一层
//   - 因此 hook SCPassthroughRootView 的 pointInside / touchesBegan：
//       * 点击点不在任何小窗容器 frame 内、且当前存在未 docked 的浮层小窗
//         → 视为"空白点击"，捕获并调用原插件的关闭方法关闭小窗（不穿透后台应用）
//   - 并 hook SCFloatingContainerView：
//       * 在浮层小窗底部添加一条 homebar 小横条(含透明 touch 层)
//       * 在该 touch 层上绑单指 pan 手势(UIPanGestureRecognizer)
//       * 手势向上甩 → 调用 delegate 的 didRequestDockFromCorner: 挂起小窗成 dock
//       * 手势向下拉 → 调用 delegate 的 sc_floatingContainerViewDidRequestFullscreen:
//                      (与 sc_handleFullscreenTap @0x2c0f8 同一条链) 小窗变全屏
//   - 不改动 ScreenCore.dylib 二进制（保持 arm64e 签名完整、可卸载回退）
// ============================================================================

#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

// ---------- 类解析（运行时按类名查找，避免编译期依赖 ScreenCore） ----------
static Class g_ContainerClass;      // SCFloatingContainerView
static Class g_HostWindowClass;     // SCFloatingHostWindow

static void sc_ensure_classes(void) {
    if (g_ContainerClass && g_HostWindowClass) return;
    g_ContainerClass = NSClassFromString(@"SCFloatingContainerView");
    g_HostWindowClass = NSClassFromString(@"SCFloatingHostWindow");
}

// ---------- 收集所有小窗容器（递归扫描所有 app 窗口的子视图） ----------
static NSArray<UIView *> *sc_all_containers(void) {
    sc_ensure_classes();
    NSMutableArray *result = [NSMutableArray array];
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (!win) continue;
        void (^scan)(UIView *) = ^(UIView *v) {
            for (UIView *sub in v.subviews) {
                if (g_ContainerClass && [sub isKindOfClass:g_ContainerClass]) {
                    [result addObject:sub];
                }
                scan(sub);
            }
        };
        scan(win);
    }
    return result;
}

// ============================================================================
// 点击空白关闭小窗
// ============================================================================

// ---------- 判断：该屏幕点是否为"小窗内容 / dock 之外"的空白 ----------
static BOOL sc_is_blank_tap(UIView *passthrough, CGPoint point) {
    CGPoint screenPt = [passthrough convertPoint:point toView:nil];  // 跨窗口统一坐标系

    NSArray *containers = sc_all_containers();
    BOOL hasFloating = NO;
    for (UIView *c in containers) {
        BOOL docked = NO;
        if ([(id)c respondsToSelector:@selector(isDocked)]) {
            docked = [(id)c isDocked];
        }
        if (!docked) hasFloating = YES;   // 存在浮层小窗

        CGRect r = [c convertRect:c.bounds toView:nil];  // 容器屏幕 frame
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

// 关联对象键（避免重复创建 homebar / 手势）
static const void *kFlymeTouchKey = &kFlymeTouchKey;   // 底部透明 touch 层(含横条视觉)
static const void *kFlymePanKey   = &kFlymePanKey;     // 上滑挂起手势
static const void *kFlymeBarKey   = &kFlymeBarKey;     // 横条(视觉)

// Flyme 挂起的 dock corner 值。
// 逆向确认：原插件从某 view 的 tag 读 corner，并归一化映射到 dock side：
//   corner ∈ {2,4} → 右； corner ∈ {1,3} → 左
// 此处按用户插件设置 splitDefaultDockSide(0=左/1=右，默认左) 映射：
//   左 → corner 1；右 → corner 2
// 若真机上收边方向与你设置不符，改下面两个宏即可。
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
        [del sc_floatingContainerView:container didRequestDockFromCorner:sc_flyme_dock_corner()];
    }
}

// 小窗变全屏（复用原插件"全屏"入口，与 sc_handleFullscreenTap 同一条链）
static void sc_flyme_fullscreen(UIView *container) {
    id del = [(id)container delegate];
    if ([del respondsToSelector:@selector(sc_floatingContainerViewDidRequestFullscreen:)]) {
        [del sc_floatingContainerViewDidRequestFullscreen:container];
    }
}

%hook SCFloatingContainerView

- (void)layoutSubviews {
    %orig;
    // 仅在"浮层小窗"态显示 homebar；dock 态不显示
    if ([(id)self respondsToSelector:@selector(isDocked)] && [(id)self isDocked]) {
        UIView *tl = objc_getAssociatedObject(self, kFlymeTouchKey);
        tl.hidden = YES;
        return;
    }

    // ---- 懒创建：homebar 底部 touch 层 + 上滑手势 + 视觉横条 ----
    UIView *touchLayer = objc_getAssociatedObject(self, kFlymeTouchKey);
    if (!touchLayer) {
        touchLayer = [[UIView alloc] initWithFrame:CGRectZero];
        touchLayer.backgroundColor = [UIColor clearColor];
        touchLayer.userInteractionEnabled = YES;   // 参与命中，作为上滑手势的承载区
        [self addSubview:touchLayer];
        objc_setAssociatedObject(self, kFlymeTouchKey, touchLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 上滑挂起手势（Flyme：横条上滑挂起）
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(sc_flyme_handlePan:)];
        pan.maximumNumberOfTouches = 1;
        [touchLayer addGestureRecognizer:pan];
        objc_setAssociatedObject(self, kFlymePanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 视觉小横条（homebar 样式：半透明白圆角小条）
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        bar.layer.cornerRadius = 2.5;
        bar.layer.shadowColor = [UIColor blackColor].CGColor;
        bar.layer.shadowOpacity = 0.25;
        bar.layer.shadowRadius = 1.5;
        bar.layer.shadowOffset = CGSizeMake(0, 0.5);
        bar.userInteractionEnabled = NO;   // 视觉不拦截，交互全部交给 touch 层
        [touchLayer addSubview:bar];
        objc_setAssociatedObject(self, kFlymeBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // ---- 布局：touch 层贴容器底部，横条居中 ----
    touchLayer.hidden = NO;
    CGRect b = self.bounds;
    CGFloat hitH = 28;                                   // 手势承载区高度(便于上滑)
    touchLayer.frame = CGRectMake(0, b.size.height - hitH, b.size.width, hitH);

    UIView *bar = objc_getAssociatedObject(self, kFlymeBarKey);
    if (bar) {
        CGFloat bw  = MIN(b.size.width * 0.4, 120.0);    // 横条宽度(≤120)
        CGFloat bH  = 4.5;                                // 横条高度
        bar.frame = CGRectMake((b.size.width - bw) / 2.0,
                               hitH - bH - 7.0,          // 贴底部、略留边
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
    // 空白点击且当前有浮层小窗 → 捕获该点（拦截，不穿透后台应用）
    if (sc_is_blank_tap(self, point)) {
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
