// =============================================================================
//  ScreenCoreFlymeUI.xm — 把 ScreenCore 小窗改成魅族 Flyme 操作逻辑
// =============================================================================
//  适配 ScreenCore 2.0.x（已核对 2.0.1 arm64e：SCFloatingContainerView /
//  SCFloatingHostWindow / isDocked 与三个 delegate 回调均未改名）。
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
#if __has_include(<dyld.h>)
  #import <dyld.h>
#else
  #import <mach-o/dyld.h>
#endif
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <stdarg.h>
#import <time.h>
#import <unistd.h>
#import <sys/stat.h>

// 显式声明，避免不同 SDK 下 CFPreferences 头未引入导致链接失败
extern CFPropertyListRef CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID);

// -----------------------------------------------------------------------------
// 可调参数（真机不合适时改这里）
// -----------------------------------------------------------------------------
#define kSCFlymeEnabled           1

// --- homebar ---
// 横条位置：贴在小窗的「底边外侧」，不压住 App 自己的内容。
//   计算方式：hitLayer 是一块贴在容器底边的透明手势层，横条画在这块层里、
//   尽量靠下（pill 中心对齐容器底边，一半在窗外侧）。
//   真机如果觉得还是往里盖住了 App 内容，就把 kSCHomeBarHitHeight 调小、
//   或把 kSCHomeBarBottomInset 调大（单位 pt）。
#define kSCHomeBarHitHeight       14.0    // 手势承载层高度（贴底边，窄一点避免盖内容）
#define kSCHomeBarWidthRatio      0.60    // 横条宽度 = 小窗宽 × 该比例（Flyme 观感更宽）
#define kSCHomeBarMaxWidth        150.0
#define kSCHomeBarHeight          4.0     // 横条粗细
#define kSCHomeBarBottomInset     1.5     // 横条底部距承载层底部
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
// 注意：iOS 14+ 的 os_log 不会写进 syslog，idevicesyslog 抓不到。
// 所以这里把日志同时写到 stderr 和文件，用 Filza 就能看。
#define kSCFlymeLog               1
#define kSCLogPath                "/var/mobile/Library/Logs/ScreenCoreFlymeUI.log"
#define kSCLogMaxBytes            (768 * 1024)

#if kSCFlymeLog
  #define SCLog(fmt, ...) SCFlymeLogLine(fmt, ##__VA_ARGS__)
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
// 日志实现：stderr + 文件（/var/mobile/Library/Logs/ScreenCoreFlymeUI.log）
// =============================================================================
#if kSCFlymeLog
static void SCFlymeLogLine(const char *fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    // 1) stderr（越狱环境里会进 syslog，能用 idevicesyslog 抓）
    fprintf(stderr, "[FlymeUI] %s\n", msg);

    // 2) 文件（主要手段：Filza 直接看）
    static FILE *fp = NULL;
    if (!fp) {
        mkdir("/var/mobile/Library/Logs", 0755);
        struct stat st;
        if (stat(kSCLogPath, &st) == 0 && st.st_size > kSCLogMaxBytes) {
            unlink(kSCLogPath);   // 太大就重开，避免无限增长
        }
        fp = fopen(kSCLogPath, "a");
        if (!fp) return;          // 写不了文件也不影响功能
    }
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);
    fprintf(fp, "%s [%d] %s\n", ts, getpid(), msg);
    fflush(fp);                   // 立刻落盘，崩溃也不丢日志
}
#else
static inline void SCFlymeLogLine(const char *fmt, ...) {}
#endif

// =============================================================================
// 工具
// =============================================================================
static Class g_ContainerClass = Nil;

/// 兜底：如果 SCFloatingContainerView 这个名字取不到，就从已加载的镜像里
/// 遍历所有类，用「有 isDocked + 有 sc_floatingContainerViewDidRequestClose:」来认它。
static Class SCFlymeResolveContainerClass(void) {
    if (g_ContainerClass) return g_ContainerClass;

    Class named = NSClassFromString(@"SCFloatingContainerView");
    if (named) {
        g_ContainerClass = named;
        return g_ContainerClass;
    }

    SCLog("SCFloatingContainerView not found by name — scanning loaded classes…");
    unsigned int total = objc_getClassList(NULL, 0);
    if (total == 0) return Nil;
    Class *buf = (Class *)malloc(sizeof(Class) * total);
    if (!buf) return Nil;
    total = objc_getClassList(buf, (int)total);
    for (unsigned int i = 0; i < total; i++) {
        Class c = buf[i];
        const char *n = class_getName(c);
        if (!n) continue;
        if (strncmp(n, "SC", 2) != 0) continue;
        BOOL hasDocked = class_getInstanceMethod(c, @selector(isDocked)) != NULL;
        BOOL hasClose = class_getInstanceMethod(
            c, @selector(sc_floatingContainerViewDidRequestClose:)) != NULL;
        BOOL hasDock = class_getInstanceMethod(
            c, @selector(sc_floatingContainerView:didRequestDockFromCorner:)) != NULL;
        BOOL hasFull = class_getInstanceMethod(
            c, @selector(sc_floatingContainerViewDidRequestFullscreen:)) != NULL;
        if (hasDocked && hasClose && hasDock && hasFull) {
            SCLog("  -> resolved container class: %s", n);
            g_ContainerClass = c;
            break;
        }
    }
    free(buf);
    return g_ContainerClass;
}

static inline Class SCFlymeContainerClass(void) {
    return SCFlymeResolveContainerClass();
}

/// 把 ScreenCore 注入的镜像路径全打出来，确认插件到底加载了没
static void SCFlymeDumpImages(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (p && strstr(p, "ScreenCore")) SCLog("  image: %s", p);
    }
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
    // ScreenCore 自己也有「小窗底部上滑关闭」(splitBottomSwipeUpCloseEnabled)：
    // 若开着，贴着小窗底边往上滑可能被它先判成关闭，和 homebar 上滑挂起打架。
    // 这里只做提示，不在运行时强改用户设置。
    NSNumber *swipeUpClose = (NSNumber *)CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("splitBottomSwipeUpCloseEnabled"), CFSTR("com.susudear.screencoreprefs")));
    SCLog("→ SUSPEND (dock corner %ld, splitBottomSwipeUpCloseEnabled=%d)",
          (long)corner, swipeUpClose ? swipeUpClose.boolValue : -1);
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
        SCLog("shield installed below %p in %{public}s (parent bounds=%@)",
          container, object_getClassName(parent), NSStringFromCGRect(parent.bounds));
    }
    shield.frame = parent.bounds;
    [parent insertSubview:shield belowSubview:container];   // 保证叠放顺序
    [parent bringSubviewToFront:container];
}

// =============================================================================
// [A] homebar
//  注意：不能给 SCFloatingContainerView 写 category —— 那个类只在运行时存在，
//  编译期链接会产生 "_OBJC_CLASS_$_SCFloatingContainerView" 未定义符号。
//  所以用手势的 target 对象 + objc 关联对象来记住是哪个小窗。
// =============================================================================
static const void *kSCHitKey = &kSCHitKey;   // 承载层
static const void *kSCBarKey = &kSCBarKey;   // 视觉横条
static const void *kSCPanKey = &kSCPanKey;   // 手势
static const void *kSCPanOwnerKey = &kSCPanOwnerKey;   // 手势 → 容器(弱)
static const void *kSCLoggedKey = &kSCLoggedKey;       // 只打印一次几何

@interface SCFlymeHomeBarTarget : NSObject
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)g;
@end

@implementation SCFlymeHomeBarTarget

+ (instancetype)shared {
    static SCFlymeHomeBarTarget *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [SCFlymeHomeBarTarget new]; });
    return shared;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *c = objc_getAssociatedObject(g, kSCPanOwnerKey);
    if (!c || SCFlymeIsDocked(c)) return;

    CGPoint v = [g velocityInView:c];
    CGPoint t = [g translationInView:c];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        BOOL up   = (v.y <= -kSCTossVelocity) || (v.y < 0 && t.y <= -kSCTossTranslation);
        BOOL down = (v.y >=  kSCTossVelocity) || (v.y > 0 && t.y >=  kSCTossTranslation);
        SCLog("homebar end v=(%.0f,%.0f) t=(%.0f,%.0f) up=%d down=%d",
              v.x, v.y, t.x, t.y, up, down);
        if (up)        SCFlymeSuspend(c);       // 上滑 → 缩小小窗挂起
        else if (down) SCFlymeFullscreen(c);    // 下拉 → 变全屏
        [g setTranslation:CGPointZero inView:c];
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
            [[UIPanGestureRecognizer alloc] initWithTarget:SCFlymeHomeBarTarget.shared
                                                   action:@selector(handlePan:)];
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;
        [hit addGestureRecognizer:pan];
        objc_setAssociatedObject(self, kSCPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pan, kSCPanOwnerKey, self, OBJC_ASSOCIATION_ASSIGN);

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

    // ---- 布局：承载层贴容器底边，横条画在承载层里、尽量靠外（下）----
    hit.hidden = NO;
    CGFloat hitH = kSCHomeBarHitHeight;
    if (b.size.height < hitH * 2.5) hitH = MAX(8.0, b.size.height * 0.12);

    // 承载层底部对齐容器底边：横条中心正好落在小窗下边线上（外侧视觉）
    hit.frame = CGRectMake(0, b.size.height - hitH, b.size.width, hitH);

    CGFloat barW = MIN(b.size.width * kSCHomeBarWidthRatio, kSCHomeBarMaxWidth);
    if (barW < 28.0) barW = MIN(b.size.width, 28.0);
    bar.frame = CGRectMake((b.size.width - barW) / 2.0,
                           MAX(0.0, hitH - kSCHomeBarHeight - kSCHomeBarBottomInset),
                           barW, kSCHomeBarHeight);

    [self bringSubviewToFront:hit];

    if (!objc_getAssociatedObject(self, kSCLoggedKey)) {
        objc_setAssociatedObject(self, kSCLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SCLog("homebar laid out: bounds=(%.0f,%.0f,%.0f,%.0f) hit=(%.0f,%.0f,%.0f,%.0f) bar=(%.0f,%.0f,%.0f,%.0f)",
              b.origin.x, b.origin.y, b.size.width, b.size.height,
              hit.frame.origin.x, hit.frame.origin.y, hit.frame.size.width, hit.frame.size.height,
              bar.frame.origin.x, bar.frame.origin.y, bar.frame.size.width, bar.frame.size.height);
    }
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
    // 加载时把关键事实全打出来，便于定位「到底哪一步没生效」
    SCLog("==================================================");
    SCLog("ScreenCoreFlymeUI 2.2.0  build %s %s", __DATE__, __TIME__);
    SCLog("pid=%d  logfile=%s", getpid(), kSCLogPath);
    SCFlymeDumpImages();
    Class c = SCFlymeContainerClass();
    SCLog("container class = %s", c ? class_getName(c) : "(NOT FOUND)");
    if (!c) {
        SCLog("!! 找不到小窗容器类：插件可能没装好，或类名变了。");
        SCLog("!! 请把上面的 image: 行和这行一起发给我。");
    } else {
        SCLog("OK：hook 已就绪。呼出小窗后应能看到 homebar 相关日志。");
    }
    SCLog("==================================================");
}
