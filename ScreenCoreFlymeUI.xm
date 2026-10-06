// =============================================================================
//  ScreenCoreFlymeUI.xm — 把 ScreenCore 小窗改成魅族 Flyme 操作逻辑
// =============================================================================
//  需求：
//    ① 小窗四周「蓝色」区域点击 → 缩小小窗 / 挂起（原行为，本 tweak 保留不拦）
//    ② 小窗底部新增 homebar 小横条：
//         · 横条上滑 → 缩小小窗、挂起（收成左上角小窗 / dock）
//         · 横条下拉 → 小窗变全屏
//    ③ 小窗状态下点击小窗以外的空白 → 关闭小窗
//    原「左/上白色 → 全屏」「下/右红色 → 关闭」由 ② 取代。
//
//  实现：纯 hook，不改 ScreenCore.dylib 二进制（arm64e 签名保持完好，可整体卸载回退）。
//
//  三个部件：
//    [A] homebar  — 挂在 SCFloatingContainerView 底部，带 UIPanGestureRecognizer
//    [B] shield   — 容器父视图里、容器正下方的一层全屏透明遮罩；
//                   用容器屏幕矩形做命中判断：窗外轻点 → 关闭
//    [C] 外侧带    — 遮罩上从「窗左/上带」起手 → 挂起；从「窗下/右带」下拉 → 全屏
// =============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import <dispatch/dispatch.h>

// 显式声明，避免不同 SDK 下 CFPreferences 头未引入导致链接失败
extern CFPropertyListRef CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID);

// -----------------------------------------------------------------------------
// 可调参数（真机不合适时改这里）
// -----------------------------------------------------------------------------
#define kSCFlymeEnabled           1

// --- homebar ---
#define kSCHomeBarHitHeight       26.0    // 手势承载层高度(pt)，贴小窗底部
#define kSCHomeBarWidthRatio      0.40    // 横条宽度 = 小窗宽 × 该比例
#define kSCHomeBarMaxWidth        120.0
#define kSCHomeBarHeight          4.5
#define kSCHomeBarBottomInset     6.0     // 横条距承载层底部
#define kSCHomeBarAlpha           0.85

// --- 手势判定 ---
#define kSCTossVelocity           350.0   // pt/s，视为「甩」
#define kSCTossTranslation        22.0    // pt，慢速拖动兜底阈值
#define kSCTapSlop                12.0    // pt，位移小于该值算「点击」
#define kSCEdgeBandMax            140.0   // 窗「外侧带」最大厚度(pt)

// --- 挂起(dock)方向：corner ∈{2,4}→右，∈{1,3}→左，0→右 ---
#define kSCCornerLeft             1
#define kSCCornerRight            2
#define kSCForceCorner            -1      // 1/2/3/4 可强制指定；-1 = 读插件设置

// --- 日志 ---
#define kSCFlymeLog               1

#if kSCFlymeLog
  #define SCLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[FlymeUI] " fmt, ##__VA_ARGS__)
#else
  #define SCLog(fmt, ...)
#endif

// =============================================================================
// 运行时类型（类由 ScreenCore.dylib 提供）
// =============================================================================
@interface SCFloatingContainerView : UIView
@end

@interface NSObject (SCFlymePrivateAPI)
- (id)delegate;
- (BOOL)isDocked;
- (void)sc_floatingContainerViewDidRequestClose:(UIView *)container;
- (void)sc_floatingContainerView:(UIView *)container
         didRequestDockFromCorner:(NSInteger)corner;
- (void)sc_floatingContainerViewDidRequestFullscreen:(UIView *)container;
@end

// =============================================================================
// 工具
// =============================================================================
static Class g_ContainerClass = Nil;

static inline Class SCFlymeContainerClass(void) {
    if (!g_ContainerClass) g_ContainerClass = NSClassFromString(@"SCFloatingContainerView");
    return g_ContainerClass;
}

static NSArray<UIWindow *> *SCFlymeWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w) [out addObject:w];
    }
    return out;
}

static void SCFlymeCollect(UIView *root, Class cls, NSMutableArray *out) {
    for (UIView *sub in root.subviews) {
        if (cls && [sub isKindOfClass:cls]) [out addObject:sub];
        SCFlymeCollect(sub, cls, out);
    }
}

static BOOL SCFlymeIsDocked(UIView *c) {
    return [c respondsToSelector:@selector(isDocked)] && [(id)c isDocked];
}

/// 所有「正在悬浮」的小窗（排除 dock 态 / 隐藏 / 未布局）
static NSArray<SCFloatingContainerView *> *SCFlymeFloating(void) {
    Class cls = SCFlymeContainerClass();
    NSMutableArray *all = [NSMutableArray array];
    if (!cls) return all;
    for (UIWindow *w in SCFlymeWindows()) SCFlymeCollect(w, cls, all);

    NSMutableArray *out = [NSMutableArray array];
    for (SCFloatingContainerView *c in all) {
        if (SCFlymeIsDocked(c)) continue;
        if (c.hidden || c.alpha < 0.05) continue;
        if (CGRectIsEmpty(c.bounds)) continue;
        [out addObject:c];
    }
    return out;
}

/// 容器在「屏幕坐标系(窗口坐标)」里的矩形
static CGRect SCFlymeScreenRect(UIView *v) {
    if (!v.window) return CGRectNull;
    return [v convertRect:v.bounds toCoordinateSpace:v.window];
}

// =============================================================================
// 原插件入口
// =============================================================================
static void SCFlymeClose(UIView *c) {
    id del = [(id)c delegate];
    SCLog("→ CLOSE");
    if ([del respondsToSelector:@selector(sc_floatingContainerViewDidRequestClose:)]) {
        [del sc_floatingContainerViewDidRequestClose:c];
    }
}

static NSInteger SCFlymeDockCorner(void) {
#if kSCForceCorner > 0
    return (NSInteger)kSCForceCorner;
#else
    static NSInteger cached = -1;
    if (cached > 0) return cached;
    NSNumber *side = (NSNumber *)CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("splitDefaultDockSide"), CFSTR("com.susudear.screencoreprefs")));
    NSInteger v = ([side isKindOfClass:NSNumber.class]) ? side.integerValue : 0;
    cached = (v == 1) ? kSCCornerRight : kSCCornerLeft;
    SCLog("splitDefaultDockSide=%ld → dock corner %ld", (long)v, (long)cached);
    return cached;
#endif
}

/// 缩小小窗 / 挂起
static void SCFlymeSuspend(UIView *c) {
    id del = [(id)c delegate];
    NSInteger corner = SCFlymeDockCorner();
    SCLog("→ SUSPEND (dock corner %ld)", (long)corner);
    if ([del respondsToSelector:@selector(sc_floatingContainerView:didRequestDockFromCorner:)]) {
        [del sc_floatingContainerView:c didRequestDockFromCorner:corner];
    }
}

/// 小窗变全屏
static void SCFlymeFullscreen(UIView *c) {
    id del = [(id)c delegate];
    SCLog("→ FULLSCREEN");
    if ([del respondsToSelector:@selector(sc_floatingContainerViewDidRequestFullscreen:)]) {
        [del sc_floatingContainerViewDidRequestFullscreen:c];
    }
}

// =============================================================================
// [B][C] shield：窗外遮罩（点空白关闭 / 外侧带手势）
// =============================================================================
static const void *kSCShieldKey      = &kSCShieldKey;      // 遮罩视图
static const void *kSCShieldCtxKey   = &kSCShieldCtxKey;   // 手势上下文
static const void *kSCShieldOwnerKey = &kSCShieldOwnerKey; // 遮罩 ↔ 容器

typedef NS_ENUM(NSInteger, SCFlymeZone) {
    SCFlymeZoneOutside = 0,   // 不在任何外侧带 → 空白
    SCFlymeZoneLeft,
    SCFlymeZoneTop,
    SCFlymeZoneRight,
    SCFlymeZoneBottom,
};

@interface SCFlymeSwipeContext : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, assign) CGPoint start;      // 遮罩坐标(≈ 屏幕坐标)
@property (nonatomic, assign) BOOL bottomRight;   // YES: 下/右带；NO: 上/左带
@property (nonatomic, assign) BOOL handled;
@end

@implementation SCFlymeSwipeContext
@end

/// 点在某个容器周围属于哪条「外侧带」
static SCFlymeZone SCFlymeZoneFor(UIView *container, CGPoint p, CGRect *outRect) {
    CGRect r = SCFlymeScreenRect(container);
    if (CGRectIsNull(r)) return SCFlymeZoneOutside;
    if (outRect) *outRect = r;
    if (CGRectContainsPoint(r, p)) return SCFlymeZoneOutside;   // 窗内

    CGFloat band = MIN(kSCEdgeBandMax, MAX(r.size.width, r.size.height) * 0.25);
    if (band < 24.0) band = 24.0;

    if (p.x >= r.origin.x && p.x <= CGRectGetMaxX(r)) {
        if (p.y < r.origin.y && p.y >= r.origin.y - band) return SCFlymeZoneTop;
        if (p.y > CGRectGetMaxY(r) && p.y <= CGRectGetMaxY(r) + band) return SCFlymeZoneBottom;
    }
    if (p.y >= r.origin.y && p.y <= CGRectGetMaxY(r)) {
        if (p.x < r.origin.x && p.x >= r.origin.x - band) return SCFlymeZoneLeft;
        if (p.x > CGRectGetMaxX(r) && p.x <= CGRectGetMaxX(r) + band) return SCFlymeZoneRight;
    }
    return SCFlymeZoneOutside;
}

/// 最上层、且包含点 p 的容器
static SCFloatingContainerView *SCFlymeContainerContaining(CGPoint p) {
    for (SCFloatingContainerView *c in SCFlymeFloating().reverseObjectEnumerator) {
        CGRect r = SCFlymeScreenRect(c);
        if (!CGRectIsNull(r) && CGRectContainsPoint(r, p)) return c;
    }
    return nil;
}

@interface SCFlymeShieldView : UIView
@end

@implementation SCFlymeShieldView

// 窗内区域不拦截；其余全部拦截（不穿透后台 App，同时能收到点击）
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!SCFlymeContainerClass()) return NO;
    if (SCFlymeFloating().count == 0) {
        self.userInteractionEnabled = NO;
        return NO;
    }
    self.userInteractionEnabled = YES;
    if (SCFlymeContainerContaining(point)) return NO;   // 窗内 → 交给小窗
    return YES;                                          // 窗外 → 拦截
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    NSArray *floating = SCFlymeFloating();
    if (!touch || floating.count == 0) return;

    CGPoint p = [touch locationInView:self];
    SCFloatingContainerView *top = floating.lastObject;

    CGRect rect = CGRectNull;
    SCFlymeZone zone = SCFlymeZoneFor(top, p, &rect);

    SCFlymeSwipeContext *ctx = [SCFlymeSwipeContext new];
    ctx.container = top;
    ctx.start = p;
    ctx.bottomRight = (zone == SCFlymeZoneBottom || zone == SCFlymeZoneRight);
    objc_setAssociatedObject(self, kSCShieldCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SCLog("shield begin zone=%ld p=(%.0f,%.0f) rect=%@",
          (long)zone, p.x, p.y, NSStringFromCGRect(rect));
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    SCFlymeSwipeContext *ctx = objc_getAssociatedObject(self, kSCShieldCtxKey);
    UITouch *touch = touches.anyObject;
    if (!ctx || ctx.handled || !touch) return;

    CGPoint p = [touch locationInView:self];
    CGFloat dx = p.x - ctx.start.x;
    CGFloat dy = p.y - ctx.start.y;

    BOOL trigger = NO, wantFullscreen = NO;
    if (ctx.bottomRight) {                       // 下/右带
        if (dy >= kSCTossTranslation) { trigger = YES; wantFullscreen = YES; }
        else if (dy <= -kSCTossTranslation || dx <= -kSCTossTranslation) { trigger = YES; }
    } else {                                     // 上/左带
        if (dy <= -kSCTossTranslation || dx <= -kSCTossTranslation) { trigger = YES; }
        else if (dy >= kSCTossTranslation) { trigger = YES; wantFullscreen = YES; }
    }

    if (trigger) {
        ctx.handled = YES;
        UIView *c = ctx.container;
        objc_setAssociatedObject(self, kSCShieldCtxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SCLog("shield swipe dx=%.0f dy=%.0f → %s", dx, dy,
              wantFullscreen ? "FULLSCREEN" : "SUSPEND");
        if (wantFullscreen) SCFlymeFullscreen(c);
        else                SCFlymeSuspend(c);
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    SCFlymeSwipeContext *ctx = objc_getAssociatedObject(self, kSCShieldCtxKey);
    objc_setAssociatedObject(self, kSCShieldCtxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!ctx || ctx.handled) return;

    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint p = [touch locationInView:self];
    if (hypot(p.x - ctx.start.x, p.y - ctx.start.y) > kSCTapSlop) return;  // 拖动而非点击

    SCFlymeZone zone = SCFlymeZoneFor(ctx.container, ctx.start, NULL);
    if (zone != SCFlymeZoneOutside) {
        // 外侧带轻点：下/右带 → 全屏；上/左带 → 缩小小窗挂起
        if (ctx.bottomRight) {
            SCLog("shield TAP bottom/right → FULLSCREEN");
            SCFlymeFullscreen(ctx.container);
        } else {
            SCLog("shield TAP top/left → SUSPEND");
            SCFlymeSuspend(ctx.container);
        }
        return;
    }

    // 真正的空白 → 关闭最上层小窗
    SCFloatingContainerView *top = SCFlymeFloating().lastObject;
    if (!top) return;
    SCLog("shield TAP blank → CLOSE");
    UIView *c = top;
    dispatch_async(dispatch_get_main_queue(), ^{
        SCFlymeClose(c);     // 延后一拍，避免在触摸回调里改视图层级
    });
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, kSCShieldCtxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

/// 给 container 的父视图装上 / 更新遮罩（遮罩必须在容器正下方）
static void SCFlymeSyncShield(UIView *container) {
    UIView *parent = container.superview;
    if (!parent) return;

    SCFlymeShieldView *shield = objc_getAssociatedObject(container, kSCShieldKey);
    if (!shield) {
        shield = [[SCFlymeShieldView alloc] initWithFrame:parent.bounds];
        shield.backgroundColor = UIColor.clearColor;
        shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        shield.userInteractionEnabled = YES;
        objc_setAssociatedObject(container, kSCShieldKey, shield, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(shield, kSCShieldOwnerKey, container, OBJC_ASSOCIATION_ASSIGN);
        SCLog("shield installed below %p in %{public}s", container, object_getClassName(parent));
    }
    shield.frame = parent.bounds;
    [parent insertSubview:shield belowSubview:container];   // 保证叠放顺序
    [parent bringSubviewToFront:container];
}

// =============================================================================
// [A] homebar
// =============================================================================
static const void *kSCHitKey = &kSCHitKey;   // 承载层
static const void *kSCBarKey = &kSCBarKey;   // 视觉横条
static const void *kSCPanKey = &kSCPanKey;   // 手势

@interface SCFloatingContainerView (SCFlymeHomeBar)
@end

@implementation SCFloatingContainerView (SCFlymeHomeBar)

- (void)scFlymeHomeBarPan:(UIPanGestureRecognizer *)g {
    if (SCFlymeIsDocked(self)) return;

    CGPoint v = [g velocityInView:self];
    CGPoint t = [g translationInView:self];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        BOOL up   = (v.y <= -kSCTossVelocity) || (v.y < 0 && t.y <= -kSCTossTranslation);
        BOOL down = (v.y >=  kSCTossVelocity) || (v.y > 0 && t.y >=  kSCTossTranslation);
        SCLog("homebar end v=(%.0f,%.0f) t=(%.0f,%.0f) up=%d down=%d",
              v.x, v.y, t.x, t.y, up, down);
        if (up)        SCFlymeSuspend(self);       // 上滑 → 缩小小窗挂起
        else if (down) SCFlymeFullscreen(self);    // 下拉 → 变全屏
        [g setTranslation:CGPointZero inView:self];
    }
}

@end

%hook SCFloatingContainerView

- (void)layoutSubviews {
    %orig;

    if (!SCFlymeContainerClass()) return;

    UIView *hit = objc_getAssociatedObject(self, kSCHitKey);
    UIView *bar = objc_getAssociatedObject(self, kSCBarKey);

    // dock 态 / 隐藏态：不需要 homebar
    if (SCFlymeIsDocked(self) || self.hidden) {
        hit.hidden = YES;
        return;
    }

    CGRect b = self.bounds;
    if (CGRectIsEmpty(b) || self.window == nil) return;

    // ---- 懒创建 ----
    if (!hit) {
        hit = [[UIView alloc] initWithFrame:CGRectZero];
        hit.backgroundColor = UIColor.clearColor;
        hit.userInteractionEnabled = YES;
        [self addSubview:hit];
        objc_setAssociatedObject(self, kSCHitKey, hit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                   action:@selector(scFlymeHomeBarPan:)];
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        [hit addGestureRecognizer:pan];
        objc_setAssociatedObject(self, kSCPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:kSCHomeBarAlpha];
        bar.layer.cornerRadius = kSCHomeBarHeight / 2.0;
        bar.layer.shadowColor = UIColor.blackColor.CGColor;
        bar.layer.shadowOpacity = 0.3;
        bar.layer.shadowRadius = 2.0;
        bar.layer.shadowOffset = CGSizeMake(0, 0.5);
        bar.userInteractionEnabled = NO;
        [hit addSubview:bar];
        objc_setAssociatedObject(self, kSCBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        SCLog("homebar installed on %p bounds=%@", self, NSStringFromCGRect(b));
    }

    // ---- 布局：承载层贴底，横条居中 ----
    hit.hidden = NO;
    CGFloat hitH = kSCHomeBarHitHeight;
    if (b.size.height < hitH * 2.5) hitH = MAX(10.0, b.size.height * 0.28);

    hit.frame = CGRectMake(0, b.size.height - hitH, b.size.width, hitH);

    CGFloat barW = MIN(b.size.width * kSCHomeBarWidthRatio, kSCHomeBarMaxWidth);
    if (barW < 24.0) barW = MIN(b.size.width, 24.0);
    bar.frame = CGRectMake((b.size.width - barW) / 2.0,
                           MAX(0.0, hitH - kSCHomeBarHeight - kSCHomeBarBottomInset),
                           barW, kSCHomeBarHeight);

    [self bringSubviewToFront:hit];
}

// homebar 区域必须命中容器（避免被内容视图吃掉）
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL inside = %orig;
    if (inside) return YES;
    UIView *hit = objc_getAssociatedObject(self, kSCHitKey);
    if (hit && !hit.hidden && CGRectContainsPoint(hit.frame, point)) return YES;
    return NO;
}

- (void)didMoveToSuperview {
    %orig;
    if (!SCFlymeContainerClass()) return;
    if (self.superview) {
        SCFlymeSyncShield(self);
    } else {
        UIView *shield = objc_getAssociatedObject(self, kSCShieldKey);
        [shield removeFromSuperview];
        objc_setAssociatedObject(self, kSCShieldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (!SCFlymeContainerClass()) return;
    if (self.window && self.superview) SCFlymeSyncShield(self);
}

%end

// =============================================================================
// 兜底：宿主窗口命中测试，保证「窗外点击不穿透到后台应用」
// =============================================================================
%hook SCFloatingHostWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    if (!SCFlymeContainerClass()) return hit;

    NSArray *floating = SCFlymeFloating();
    if (floating.count == 0) return hit;

    for (SCFloatingContainerView *c in floating) {
        CGRect r = SCFlymeScreenRect(c);
        if (!CGRectIsNull(r) && CGRectContainsPoint(r, point)) return hit;   // 窗内原样
    }
    return hit;   // 窗外：遮罩层会先被命中；此处不改变结果
}

%end

// =============================================================================
%ctor {
    SCLog("ScreenCoreFlymeUI loaded — homebar: 上滑挂起 / 下拉全屏；窗外点击: 关闭");
}
