# ScreenCore Flyme UI

把 ScreenCore 分屏插件（`com.susudear.screencore`）的**小窗操作逻辑**改成**魅族 Flyme 式**。

> 只用 hook 实现，**不改 `ScreenCore.dylib` 二进制**（arm64e ptruath 签名保持完好），
> 卸载这个 deb 就 100% 恢复原逻辑，安全可回退。

---

## 一、改成了什么（对照表）

> **兼容性**：已核对 **ScreenCore 2.0.1 (arm64e)**——`SCFloatingContainerView`、
> `SCFloatingHostWindow`、`isDocked` 以及三个 delegate 回调都没有改名，
> 所以本插件直接适用于 2.0.x。要装的 deb 是 `2.1.0`（配合 ScreenCore ≥ 2.0.0）。
> 2.0.1 相对旧版新增了 `SCArcAdjustmentView`、`SCFloatingWindowTransitionCoordinator`
> 等类，但小窗容器与操作回调没动。

| 操作 | 原版 ScreenCore | 本插件（Flyme 式） |
|---|---|---|
| 点小窗四周**蓝色**区域 | 缩小小窗 / 挂起 | **保持不变**（本插件不拦） |
| 点小窗**左/上白色**区域 | 小窗变全屏 | 改为：**缩小小窗挂起**（外侧带轻点） |
| 点小窗**下/右红色**区域 | 关闭小窗 | 改为：**小窗变全屏**（外侧带轻点） |
| 小窗底部 | 无 | **新增 homebar 小横条** |
| homebar **上滑** | — | **缩小小窗、挂起（收成左上角小窗 / dock）** |
| homebar **下拉** | — | **小窗变全屏** |
| 点小窗**以外的空白** | 无 | **关闭小窗** |

---

## 二、逆向依据（对 `ScreenCore` v1.0.7 / arm64e 的实测）

插件没有公开 API，本插件调用的都是**插件自己内部使用的回调**，因此与后续版本兼容性最好：

```
关闭小窗：  [delegate sc_floatingContainerViewDidRequestClose:容器]
缩小小窗：  [delegate sc_floatingContainerView:容器 didRequestDockFromCorner:corner]
变全屏：    [delegate sc_floatingContainerViewDidRequestFullscreen:容器]
状态判断：  [容器 isDocked]
容器类名：  SCFloatingContainerView（宿主窗口 SCFloatingHostWindow）
```

这些 selector 全部存在于 `ScreenCore.dylib` 的 `__objc_methname` 里，是插件
`sc_handleCloseTap:` / `sc_handleDockTap:` / `sc_handleFullscreenTap:` 三个手势
处理函数最终走的同一条路径。

**corner → 挂起方向**（来自插件 `sc_dockSession:fromCorner:` 的分支）：

| corner | 收边方向 |
|---|---|
| 1、3 | 左 |
| 2、4 | 右 |
| 0 | 右 |

本插件默认读插件设置 `splitDefaultDockSide`（`com.susudear.screencoreprefs`，0=左 / 1=右）
来自动选 corner = 1（左上）或 2（右上）。**如果你的真机上收边方向反了**，改
`ScreenCoreFlymeUI.xm` 顶部：

```c
#define kSCCornerLeft             1     // 「左上」用的 corner
#define kSCCornerRight            2     // 「右上」用的 corner
#define kSCForceCorner            -1    // 直接写 1/2/3/4 可强制固定，忽略插件设置
```

---

## 三、交互几何（从你的录屏实测）

录屏 `RPReplay_Final1791245998.MP4` 是 886×1920（iPhone 逻辑 443×960 pt），
调试窗口显示：

* 小窗可视内容 ≈ **x 74–803 px、y 316–1614 px**（≈ 37–402 pt × 158–807 pt）
* 蓝色两侧带 ≈ 每侧 **30 pt**（窗左右外侧）
* 红色下带 ≈ **41 pt**，右带 ≈ **43 pt**（窗下/右外侧）
* 白色左/上带与蓝色带重合

本插件按这些比例实现：

* **homebar** 贴在小窗**底边外侧**（不压 App 内容），手势承载层高 14 pt 并贴容器底边，
  横条画在承载层里靠下：宽 = 窗宽 × 60%（≤150 pt）、高 4 pt、圆角、半透明白
* **外侧带** 厚度 = min(140 pt, max(窗宽,窗高) × 25%)，最小 24 pt
* 轻点位移 < 12 pt 才算「点击」；拖过 22 pt 或速度 > 350 pt/s 才算「滑动」

### 横条位置/大小怎么调

都在 `ScreenCoreFlymeUI.xm` 顶部：

| 宏 | 默认 | 作用 |
|---|---|---|
| `kSCHomeBarHitHeight` | 14.0 | 手势承载层高度。**调小** = 横条更靠外、更不压内容 |
| `kSCHomeBarBottomInset` | 1.5 | 横条距承载层底部。**调大** = 横条往上挪 |
| `kSCHomeBarWidthRatio` | 0.60 | 横条宽度 = 窗宽 × 该比例 |
| `kSCHomeBarMaxWidth` | 150.0 | 横条最大宽度 |
| `kSCHomeBarHeight` | 4.0 | 横条粗细 |

装好后日志会打印一次实际几何，照着这个数字调最准：

```
[FlymeUI] homebar laid out: bounds=(x,y,w,h) hit=(x,y,w,h) bar=(x,y,w,h)
```

`bounds` 是小窗容器矩形，`bar` 是横条实际位置（相对小窗左上角）。
若 `bar.y + bar.height` 明显小于 `bounds.height`，说明横条还压在窗内，把
`kSCHomeBarHitHeight` 或 `kSCHomeBarBottomInset` 往下调即可。

---

## 四、工程结构

```
ScreenCoreFlymeClose/
├── ScreenCoreFlymeUI.xm        ← 全部逻辑（唯一需要改的文件）
├── ScreenCoreFlymeUI.plist     ← 注入目标：com.apple.springboard
├── Makefile                    ← Theos 构建脚本
├── control                     ← deb 元信息
├── .github/workflows/build.yml ← GitHub Actions 云端编译
└── README.md
```

### 代码三个部件

| 部件 | 位置 | 作用 |
|---|---|---|
| **[A] homebar** | `%hook SCFloatingContainerView` | 在容器底部加透明承载层 + 小横条 + `UIPanGestureRecognizer`；上滑 `SCFlymeSuspend`，下拉 `SCFlymeFullscreen`。`isDocked` 时不显示 |
| **[B] shield** | `SCFlymeShieldView` | 在容器**父视图**里、容器正下方插一层全屏透明遮罩。`pointInside:` 先用容器屏幕矩形判断：窗内返回 NO（放行小窗），窗外返回 YES（拦截 + 收事件） |
| **[C] 外侧带** | `SCFlymeZoneFor()` | 把窗外点击分成 左/上带（→ 挂起）和 下/右带（→ 全屏）；真正的空白 → 关闭 |

`SCFloatingHostWindow.hitTest:` 做兜底，保证窗外点击不会穿透到后台 App。

---

## 五、打包成 .deb

新 arm64e ABI 必须在 macOS + Xcode 上编译，Windows 本机无法编译。

### 已经编好了（三种越狱各一个）

| 文件 | 用在哪种越狱 | 装到哪 |
|---|---|---|
| **`ScreenCoreFlymeUI_2.2.0_roothide.deb`** | **Relaxin / RootHide（roothide，随机 jbroot）** | `<jbroot>/Library/MobileSubstrate/DynamicLibraries/` |
| `ScreenCoreFlymeUI_2.2.0_rootless.deb` | Dopamine / palera1n rootless / XinaA15 | `/var/jb/Library/…` |
| `ScreenCoreFlymeUI_2.2.0_rootful.deb` | unc0ver / checkra1n rootful | `/Library/…` |

> **roothide 用户必须装 `_roothide` 那个。** roothide 的越狱根不是 `/var/jb` 而是随机
> 路径，普通 rootless 包装进去不会被加载 —— 这正是一开始"完全没用"的原因。
> 对照 RootHidePatcher 的 `patch.sh`：roothide 包要做两件事 ——
> 把 `var/jb/*` 抬到包根目录、control 里 `Architecture: iphoneos-arm64e`。
> 本仓库的 Makefile 用 `THEOS_PACKAGE_INSTALL_PREFIX=/` 直接编出这种结构
> （`make package roothide=1`），CI 里的 `roothide` 那一格就是这么编的。

编译仓库：<https://github.com/fatyangOOQT/screencore-flyme>

> **注意**：ScreenCore 自己有个「小窗底部上滑关闭」开关
> （`splitBottomSwipeUpCloseEnabled`，在插件设置里）。如果它开着，
> 贴着小窗底边往上滑可能被插件先判成「关闭」而不是「挂起」，
> 和 homebar 上滑挂起打架。日志里每次挂起都会打印这个开关的当前值：
> `→ SUSPEND (dock corner 1, splitBottomSwipeUpCloseEnabled=1)`，
> 是 1 的话建议去插件设置里把它关掉。

> **踩过的两个坑**（自己改 Makefile 时注意）：
> 1. `TARGET` 不要写死 SDK 版本（如 `iphone:clang:16.5:15.0`），否则 Theos 会去
>    `$THEOS/sdks` 找不存在的 `iPhoneOS16.5.sdk` 而报错。用 `iphone:clang:latest:15.0`。
> 2. **不要给 `SCFloatingContainerView` 写 ObjC category** —— 这个类只在运行时存在，
>    编译期会产生 `_OBJC_CLASS_$_SCFloatingContainerView` 未定义符号导致链接失败。
>    本插件用手势 target 对象 + 关联对象持有小窗来绕开。
> 3. `%orig` 只能当语句用（`%orig;`）或赋给变量（`BOOL x = %orig;`），
>    不能直接写进 `if (%orig)`，否则 Logos 展开后不是合法表达式。

### 方式 A：GitHub Actions 云端编译（推荐，免费）

1. fork / 新建仓库，把本文件夹**全部内容**（含隐藏的 `.github` 目录）拖进去 → **Commit**。
2. 打开仓库 **Actions** 标签 → **Build Tweak** 自动跑（约 2 分钟）。
3. 跑完点进这次运行 → 页面底部 **Artifacts** → 下载：
   * `ScreenCoreFlymeUI-rootless` → rootless 用；
   * `ScreenCoreFlymeUI-rootful` → rootful 用。
4. 解压得到 `.deb` → Filza / Sileo 安装 → 注销（respring）。

### 方式 B：本机 Theos（macOS / 越狱 iPhone）

```bash
make package THEOS_PACKAGE_SCHEME=rootless   # rootless
make package                                 # rootful
```

老设备（A11 及以下，无 arm64e）：把 `Makefile` 里 `ARCHS := arm64e arm64` 改成 `ARCHS := arm64`。

---

## 六、真机调试（重要）

> **这台设备的环境**：iPhone 15 Pro / iOS 17.3 / **Relaxin**（ElleKit 注入、rootless）。
> `os_log` 在 iOS 14+ **不会写进 syslog**，`idevicesyslog | grep FlymeUI` 抓不到东西 ——
> 所以本插件把日志同时写到 **stderr** 和 **文件**，主要看文件。

### 看日志（不需要电脑、不需要终端）

日志文件名跟 dylib 同目录（路径不写死，三种越狱都对）：

```
roothide : <jbroot>/Library/MobileSubstrate/DynamicLibraries/ScreenCoreFlymeUI.log
rootless : /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenCoreFlymeUI.log
rootful  : /Library/MobileSubstrate/DynamicLibraries/ScreenCoreFlymeUI.log
```

1. Filza 进到 `DynamicLibraries/` 目录，找到 **`ScreenCoreFlymeUI.log`**；
2. 装好插件 → 注销 → **呼出一次小窗** → 回 Filza 打开/刷新这个文件。

日志开头会自己写明位置，形如：

```
10-06 11:28:41 [1234] ==================================================
10-06 11:28:41 [1234] ScreenCoreFlymeUI 2.2.0  build Oct  6 2026 11:20:03
10-06 11:28:41 [1234] pid=1234
10-06 11:28:41 [1234] self  = /var/containers/.../Library/MobileSubstrate/DynamicLibraries/ScreenCoreFlymeUI.dylib
10-06 11:28:41 [1234] log   = /var/containers/.../Library/MobileSubstrate/DynamicLibraries/ScreenCoreFlymeUI.log
10-06 11:28:41 [1234]   image: .../DynamicLibraries/ScreenCore.dylib
10-06 11:28:41 [1234] container class = SCFloatingContainerView
10-06 11:28:41 [1234] OK：hook 已就绪。呼出小窗后应能看到 homebar 相关日志。
10-06 11:28:52 [1234] homebar installed on 0x104aabbc0 bounds={{0, 0}, {363, 578}}
10-06 11:28:52 [1234] homebar laid out: bounds=(0,0,363,578) hit=(0,564,363,14) bar=(72,572,218,4)
10-06 11:28:52 [1234] shield installed below 0x104aabbc0 in SCFloatingHostRootView (parent bounds=...)
```

### 三条判断路径

| 日志现象 | 结论 | 下一步 |
|---|---|---|
| **文件里什么都没有 / 文件不存在** | 插件没加载 | Relaxin 下检查 ElleKit 是否正常、deb 是否装进 `/var/jb/…`；把 `dpkg -l \| grep flyme` 结果发我 |
| 有 banner 但 `container class = (NOT FOUND)` | 小窗容器类名不是 `SCFloatingContainerView` | 把日志发我，我用扫描到的真实类名重写 hook |
| banner + `container class = …` + `homebar laid out: …` 都有，但界面没变化 | 代码在跑，是几何或被别的东西盖住 | 把 `homebar laid out` 那行发我，我按真实数字改，或把横条改挂到父视图上 |

### 也可以用电脑抓 syslog（次要手段）

```bash
idevicesyslog | grep FlymeUI     # 只在 stderr 那一路有效
```

### 上手检查清单

1. 呼出小窗 → 看小窗底部是否出现**白色小横条**；
2. 横条**上滑** → 小窗应缩成左上角小窗（若方向反了，改 `kSCCornerLeft/kSCCornerRight`）；
3. 横条**下拉** → 应变成全屏；
4. 点小窗**外面** → 应关闭小窗；
5. 点小窗**四周蓝色** → 应仍能缩小小窗（原行为保留）。

### 想只要其中一部分

* 只要 homebar、不要改红/白区域：把 `SCFlymeShieldView` 的 `pointInside:`
  里最后一行的 `return YES;` 改成 `return NO;`（遮罩不再拦截，红/白区域恢复原逻辑）。
* 只要"点空白关闭"、不要外侧带手势：把 `- (void)touchesMoved:withEvent:` 整个方法体删掉。
* 关掉日志：`#define kSCFlymeLog 0`。

---

## 七、卸载 / 回退

Sileo / Filza 里卸载 **ScreenCore Flyme UI**（`com.susudear.screencore.flymeui`），
注销 SpringBoard。原插件二进制从未被修改，立刻恢复原交互。

---

## 八、已知限制

1. **未在真机验证**：本插件是在 Windows 上通过对 `ScreenCore.dylib` 的静态逆向 +
   你录屏里的调试窗口几何推导出来的，必须按第六节在真机上过一遍。
2. `corner → 收边方向` 是纯静态分析结论，方向不对改两个宏即可（见第二节）。
3. 若你的插件版本不是 1.0.7，selector 名字一般不变（都是 `sc_` 系列），但请先
   `grep` 一下 deb 里的 `ScreenCore.dylib` 是否含
   `sc_floatingContainerViewDidRequestFullscreen:`。
