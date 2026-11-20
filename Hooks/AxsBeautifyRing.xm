#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <string.h>
#import "AxsHoldLaunchConfig.h"
#import "AxsHoldLaunchPreferences.h"

// ---------------------------------------------------------------------------
// 美化 · 光圈外框 (ring frame, beautify.19) — 稳定圆角矩形描边 + 整框 mask 半径
//
// beautify.18 lesson: reusing the region/overlay masks' local CGPath directly
// exploded (paths carry -21.59 offsets and local 52×105 geometries; multiple
// partial paths concatenated; attach enumeration raced to radius=-1).
//
// This version (beautify.16 stable structure + fixes):
//   - zero session hooks; the 0.5s scan + window notifications do membership
//     only (attach/detach); geometry syncs on a per-container displayLink;
//   - the stroke is a stable rounded rect: rect = container presentation
//     bounds inset lineWidth/2, radius = the SELECTED whole-frame mask's
//     radius (bbox == container + 43.18pt margins), re-read per frame from
//     the cached mask layer (it tracks the window size), config fallback;
//   - the overlay mask path's -21.59 offset is NOT borrowed - only its radius;
//   - one stroke = one whole-frame path; ring transform identity.
// ---------------------------------------------------------------------------

#define AXS_RING_LOG_PATH @"/var/mobile/Documents/sc-ring.log"
#define AXS_RING_LAYER_NAME @"axsRingFrame"
#define AXS_RING_GRADIENT_NAME @"axsRingGradient"
#define AXS_RING_GLOW_NAME @"axsRingGlow"
#define AXS_RING_MAX_ENTRIES 4

// beautify.62：用户确认要 .51/.52 那种 3D 卡片侧翻（近大远小、朝中间倾倒），不是平面歪斜。
//   .61 的 rotation.z 平面歪斜被否。恢复绕 Y 轴 rotationY + m34 透视。
//   sideSign 方向语义：右贴 -1.0 / 左贴 +1.0 → 右挂 rad<0（朝中心）、左挂 rad>0。
//   透视增益：真机滑块最高 6°，单层 rotationY 顶边高差仅 ~1.4px（几乎不可见）。
//   用户认可的 .51 强侧翻是"矩阵累积"态顶边高差 ~27px；.52 修掉累积后强度丢失。
//   .62 用干净可控的 GAIN 把 6° 放大到有效 ~15°，一次性达到同等强度且不逐帧累积。
//   .63：宿主改回 container 下可见包装层（.51/.52 实证），container 自身变换被 dock scale 吞。
//   .64：sc-ring(35) 铁证——贴边可见小窗是 SCDockedFloatingItemView，隐藏容器壳抢宿主导致视觉零效果；
//        退出倾斜只清 m13/m31/m34 却留下 rotationY 的 cos(15.6)=0.9632，逐轮累积成 0.7984 缩小。
//        修复：贴边项优先宿主 + 复位回 nativeBase 全矩阵。角度/方向/透视常量不变。
//   .65：真正根因是透视矩阵复合顺序错——rotationY 后直接写 m34 对 z=0 平面 w≡1、透视失效，
//        只剩 cos 水平缩小。改为 R·P 显式写 m14=-sin/d、m34=cos/d，corners 已变梯形。
//   .66：sc-ring(37) 铁证——.65 矩阵生效(corners 梯形)但视觉仍正矩形，因为 .64 让
//        SCDockedFloatingItemView(子树仅 6.5×6.5 角标)抢占了宿主；真正画面在 container 下
//        含 _UIScenePresentationView 的 UIView 包装层。撤销抢占、恢复 wrapper 宿主，
//        使「正确的矩阵」首次写在「正确的层」上。角度/方向/透视常量不变。
//   .67：用户验收通过(.66 倾斜生效)。两处打磨：
//        a) 消除倾斜后小窗后面露出的浅灰白"阴影"——sc-ring(38) 视图树证明 container 下
//           第三个全尺寸 UIView(浅色背景壳)没跟着倾斜，从梯形边缘露出；补全为宿主一起侧翻。
//        b) 可调角度上限 6°→12°(AXS_TILT_ANGLE_MAX)，默认 3.0/step 0.5 不变。
//        角度方向/透视公式/全部安全机制不变。
//   .68：sc-ring(39)——阴影仍在且 SHADOW_SIB 从未命中(hosts 恒为2)。两处修复：
//        a) 补全不对称：probe 采样瞬间 SCFloatingHostWindow 原生 hidden，已入选宿主走
//           "fallback keep existing"绕过可见性复查，兄弟层却因同一窗口 hidden 被拒。
//           贴边稳态下兄弟层与宿主同窗，放行；补全决策改为直接 axs_ring_log(probeLog 只打一次)。
//        b) 未倾斜节点(container/root/docked item/兄弟层)原生 layer shadow 保持矩形，
//           从梯形边缘露出。SHADOW_PROBE 一次性输出 shadowOpacity/Radius/Path/bg/corner
//           诊断；倾斜激活期间暂存清零 shadowOpacity，退出恢复(SHADOW_NEUTRALIZED/RESTORED)。
//        视频另证：灰色块在 t=0/2/8s(小窗未贴边)已存在于屏幕右上角——疑似录屏工具悬浮
//        计时器/缩略图，若 SHADOW_PROBE 全为 0 且补全后仍见灰色，即为系统/其它 tweak 元素。
//   .69：sc-ring(40) 决定性证据——用户看到绿色/粉色光圈(ring)是未倾斜矩形套在梯形小窗
//        外，且确认"灰色跟着小窗动"。真相：ring/glow 挂在未倾斜的 container.layer 上，
//        半透明光晕在梯形边缘与矩形光圈间露出=用户持续反馈的"灰色阴影"。修复：
//        a) ring/glowInner/glowOuter 施加同一 tiltRotation（同坐标系同锚点，精确贴合梯形）；
//        b) 兄弟层全尺寸参照改用 container.bounds（旧"最大宿主bounds"随 probe 波动导致
//           1Hz add/drop 振荡）；c) 阴影中性化收窄到 container/root/dockedItem 三个稳定
//           节点（.68 曾把瞬时非宿主的宿主阴影清零且随 driver 重建永久丢失，0.24/60）。
#define AXS_TILT_M34          (-1.0 / 600.0)
#define AXS_TILT_SIDE_SIGN    (-1.0)
#define AXS_TILT_PERSPECTIVE_GAIN  (2.6)
// beautify.71：可调角度上限 6°→12°（用户要求增大）；默认 3.0 与 step 0.5 不变。
#define AXS_TILT_ANGLE_MAX    (12.0)

static void axs_ring_scanTick(void);
static void axs_ring_installLayoutHook(void);           // 定义在扫描节之后
static void axs_ring_probeNativeChainOnce(void);        // beautify.46：定义在 layout hook 之后
static NSString *axs_ring_tiltNativeBaseDesc(id obj);   // beautify.59：定义在 native probe 之前被 applyTilt 调用
static BOOL axs_ring_isOverlayNode(UIView *v);          // beautify.59：定义在分类区，圆角探针先行调用
static CGFloat axs_ring_tiltProbeCornerRadius(UIView *container); // beautify.59：CORNER_CLIP 探针
static BOOL axs_ring_layoutHookInstalled = NO;          // scanTick / %ctor 共用

// --- logging: single append-only file --------------------------------------

static void axs_ring_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_ring_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:Ring] %@", message);
    @try {
        NSString *line = [NSString stringWithFormat:@"%@\n", message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:AXS_RING_LOG_PATH];
        if (handle == nil) {
            [line writeToFile:AXS_RING_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *exception) {
        // logging must never take SpringBoard down
    }
}

// beautify.33：异常诊断日志（只写日志，绝不 rethrow，绝不中断主队列）。
// 捕获时记录 exception.name/reason、调用栈、以及涉及的 driver/container/layer 类名。
static void axs_ring_logException(NSString *where, NSException *ex, id obj) {
    @try {
        NSString *cls = obj ? NSStringFromClass([obj class]) : @"nil";
        NSArray *syms = [ex callStackSymbols];
        NSString *top = syms.count > 0 ? [[syms subarrayWithRange:NSMakeRange(0, MIN(4, syms.count))] componentsJoinedByString:@" | "] : @"(no symbols)";
        axs_ring_log(@"EXC %@ name=%@ reason=%@ objClass=%@ stack=%@",
                     where, ex.name ?: @"?", ex.reason ?: @"?", cls, top);
    } @catch (NSException *ignored) {
        // 日志本身出错也必须吞掉
    }
}

// --- beautify.46：命名空间化的运行时反射辅助（安全读取原生 Dock 链路） --------

// 安全 KVC：原生对象上的属性/ivar 只在本方法里读，一律 respondsToSelector / @try 守卫，
// 读不到返回 nil，绝不抛异常、绝不影响主队列。所有 key 都是只读探测，不写不替换。
static id axs_ring_nsValue(id obj, NSString *key) {
    if (obj == nil || key.length == 0) return nil;
    id v = nil;
    @try {
        // 只用 KVC：基本类型(BOOL/NSInteger)会被自动装箱成 NSNumber，避免用
        // id(*)(id,SEL) 调用返回基本类型的 getter 时 ARC 误 retain 寄存器值（崩溃）。
        v = [obj valueForKey:key];
    } @catch (NSException *exception) {
        v = nil;
    }
    return v;
}

// beautify.47：CATransform3D 的可读描述（3D 透视探针日志用）。
// CATransform3D 零值不是 identity，显式用 CATransform3DIsIdentity 判定。
static NSString *axs_ring_nsTransform3D(CATransform3D t) {
    return [NSString stringWithFormat:@"3D(a=%.4f b=%.4f c=%.4f d=%.4f "
            @"m13=%.5f m23=%.5f m31=%.4f m32=%.4f m34=%.5f tx=%.2f ty=%.2f tz=%.2f)%@",
            t.m11, t.m12, t.m21, t.m22,
            t.m13, t.m23, t.m31, t.m32, t.m34, t.m41, t.m42, t.m43,
            CATransform3DIsIdentity(t) ? @"[identity]" : @""];
}

// beautify.59：CGAffineTransform 的可读描述（完整层级探针里 view.transform 用）。
static NSString *axs_ring_nsTransform2D(CGAffineTransform t) {
    return [NSString stringWithFormat:@"2D(a=%.4f b=%.4f c=%.4f d=%.4f tx=%.2f ty=%.2f)%@",
            t.a, t.b, t.c, t.d, t.tx, t.ty,
            CGAffineTransformIsIdentity(t) ? @"[identity]" : @""];
}

// 对象摘要：类名@地址，nil 安全
static NSString *axs_ring_nsDesc(id obj) {
    if (obj == nil) return @"nil";
    return [NSString stringWithFormat:@"%@@%p", NSStringFromClass([obj class]), obj];
}

// --- config (com.susudear.screencoreprefs, live via cfprefsd snapshot) ------

static double axs_ring_clamp(double v, double lo, double hi) {
    if (!(v >= lo)) v = lo;
    if (v > hi) v = hi;
    return v;
}

// beautify.39：美化总开关（小窗边框美化）前置声明，定义见下方
static BOOL axs_ring_decorEnabled(void);

// beautify.40：总开关 splitBeautifyDecorEnabled 只允许出现在「插件自绘装饰层
// 是否可见」的判断里（attach 初始显隐 / applyGlow 显隐 / refreshAppearance
// 显隐），与子开关做与运算；绝不能进入容器扫描、attach/detach 生命周期、
// scanTick 摘除分支或任何原始容器/宿主 window 的 hidden/alpha/frame 路径——
// 总闸 OFF 时浮窗本体必须原样保留，只隐藏插件自建的 ring/gradient/glow。

// beautify.40：子开关读取保持纯净——总开关 splitBeautifyDecorEnabled
// 绝不能进入本函数，否则会经 scanTick 的 detach-all 分支与 attach 守卫
// 泄漏进容器扫描/挂载/摘除路径，误伤浮窗本体（.39 真机回归根因）。
// 总闸只在装饰层可见性判断处与子开关做与运算（见 attach/applyGlow/refresh）。
// beautify.42：偏好快照前置声明（定义在 parseHex 之后）
static void axs_ring_refreshConfigSnapshot(void);

// beautify.42：快照变量（声明前置供各 getter 读取；赋值统一在
// refreshConfigSnapshot 内完成）
static BOOL   axs_snap_loaded = NO;
static BOOL   axs_snap_decor = YES;
static BOOL   axs_snap_ringOn = YES;
static BOOL   axs_snap_glowOn = NO;
static BOOL   axs_snap_ringCustom = YES;
static BOOL   axs_snap_glowCustom = NO;
static double axs_snap_thickness = 5.0;
static double axs_snap_glowRadius = 116.0;
static double axs_snap_glowBrightness = 100.0;
static double axs_snap_configRadius = 8.0;
static UIColor *axs_snap_ringColor = nil;       // 解析后的光圈颜色
static UIColor *axs_snap_glowColorBase = nil;   // 解析+alpha 补偿后的自定义光晕色
// beautify.47：侧贴小窗 3D 侧透视（默认关闭；角度默认 3.0，范围 0..6）
static BOOL   axs_snap_tiltEnabled = NO;
static double axs_snap_tiltAngle = 3.0;

static BOOL axs_ring_enabled(void) {
    // beautify.42：读快照，每帧 tick 零配置读取；saved 通知/挂载时刷新
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_ringOn;
}

// beautify.39：美化总开关（小窗边框美化）。beautify.40 起只用于装饰层可见性：
// 缺省 YES（旧用户该 key 不存在时保持现有显示效果）；NSNumber 按布尔解析，
// NSString 兼容 "0"/"no"/"false"/"off" 等写法，其余类型回退默认。
static BOOL axs_ring_decorEnabled(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_decor;
}

static double axs_ring_thickness(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_thickness;
}

static BOOL axs_ring_customColor(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_ringCustom;
}

static double axs_ring_configRadius(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_configRadius;
}

static UIColor *axs_ring_parseHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return fallback;
    NSString *h = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (h.length == 6 || h.length == 8) {
        unsigned int v = 0;
        NSScanner *scanner = [NSScanner scannerWithString:h];
        [scanner scanHexInt:&v];
        if (h.length == 6) v = (v << 8) | 0xFFu;
        return [UIColor colorWithRed:((v >> 24) & 0xFF) / 255.0
                               green:((v >> 16) & 0xFF) / 255.0
                                blue:((v >> 8) & 0xFF) / 255.0
                               alpha:(v & 0xFF) / 255.0];
    }
    return fallback;
}

// --- beautify.42：偏好快照刷新（saved 通知/挂载时调用一次，每帧 tick 零配置
// 读取、零字符串解析；颜色只在快照刷新时 parseHex 一次） -----------------------
// 变量声明见文件前部（各 getter 之前）

static void axs_ring_refreshConfigSnapshot(void) {
    @try {
        AxsHoldLaunchConfig *cfg = [AxsHoldLaunchConfig axs_holdlaunch_shared];
        if (![cfg respondsToSelector:@selector(axs_holdlaunch_theirValueForKey:defaultValue:)]) return;
        id v;
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyDecorEnabled" defaultValue:@YES];
        if ([v isKindOfClass:[NSNumber class]]) axs_snap_decor = [v boolValue];
        else if ([v isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)v lowercaseString];
            axs_snap_decor = !(s.length > 0
                               && ([s isEqualToString:@"0"] || [s isEqualToString:@"no"]
                                   || [s isEqualToString:@"false"] || [s isEqualToString:@"off"]));
        } else axs_snap_decor = YES;

        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyRingFrameEnabled" defaultValue:@YES];
        axs_snap_ringOn = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyGlowEnabled" defaultValue:@NO];
        axs_snap_glowOn = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyRingCustomColorEnabled" defaultValue:@YES];
        axs_snap_ringCustom = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : YES;
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyGlowCustomEnabled" defaultValue:@NO];
        axs_snap_glowCustom = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;

        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyRingThickness" defaultValue:@5.0];
        axs_snap_thickness = axs_ring_clamp([v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 5.0, 0.5, 30.0);
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyGlowRadius" defaultValue:@116.0];
        axs_snap_glowRadius = axs_ring_clamp([v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 116.0, 0.0, 200.0);
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyGlowBrightness" defaultValue:@100.0];
        axs_snap_glowBrightness = axs_ring_clamp([v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 100.0, 0.0, 100.0);
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitWindowCornerRadius" defaultValue:@8.0];
        axs_snap_configRadius = axs_ring_clamp([v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 8.0, 0.0, 60.0);
        // beautify.47：侧倾开关（默认 NO）+ 3D 透视角度（默认 3.0）
        // beautify.71：上限 6.0→12.0（AXS_TILT_ANGLE_MAX），用户要求增大可调角度。
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyTiltEnabled" defaultValue:@NO];
        axs_snap_tiltEnabled = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyTiltAngle" defaultValue:@3.0];
        axs_snap_tiltAngle = axs_ring_clamp([v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 3.0, 0.0, AXS_TILT_ANGLE_MAX);

        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyRingFrameColor" defaultValue:@"#93E3FD"];
        axs_snap_ringColor = axs_ring_parseHex([v isKindOfClass:[NSString class]] ? v : nil,
                                               [UIColor colorWithRed:0.576 green:0.890 blue:0.992 alpha:1.0]);
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyGlowColor" defaultValue:@"#FFFFFF"];
        UIColor *gc = axs_ring_parseHex([v isKindOfClass:[NSString class]] ? v : nil, [UIColor whiteColor]);
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if ([gc getRed:&r green:&g blue:&b alpha:&a] && a < 0.35) {
            gc = [UIColor colorWithRed:r green:g blue:b alpha:0.6];   // alpha 过低补回基础不透明度
        }
        axs_snap_glowColorBase = gc;
        axs_snap_loaded = YES;
    } @catch (NSException *exception) {
        // 快照失败沿用上次值；首次失败用默认兜底，绝不让 SpringBoard 出错
        if (!axs_snap_loaded) {
            axs_snap_ringColor = [UIColor colorWithRed:0.576 green:0.890 blue:0.992 alpha:1.0];
            axs_snap_glowColorBase = [UIColor whiteColor];
            axs_snap_loaded = YES;
        }
    }
}

// --- beautify.59：偏好双来源核查（指令 二） -----------------------------------
// 侧倾计算前记录两条来源：
//   1) /var/mobile/Library/Preferences/com.susudear.screencoreprefs.plist 原始值（直接读文件）
//   2) Tweak 快照/内存配置（axs_snap_tiltEnabled / axs_snap_tiltAngle）
// 日志标明 plist 原始 enabled/angle、快照 enabled/angle、夹紧后 angle，
// 以及是否走了错误旧域/旧 key/空默认值。只读不写，全程 @try 守卫。
static void axs_ring_tiltLogPreferenceSources(void) {
    @try {
        NSString *prefPath = axs_holdlaunch_theirPreferencesPath();
        NSDictionary *raw = prefPath.length > 0
                            ? [NSDictionary dictionaryWithContentsOfFile:prefPath] : nil;
        id rawEnabled = [raw isKindOfClass:[NSDictionary class]]
                        ? [raw objectForKey:@"splitBeautifyTiltEnabled"] : nil;
        id rawAngle = [raw isKindOfClass:[NSDictionary class]]
                      ? [raw objectForKey:@"splitBeautifyTiltAngle"] : nil;
        NSString *sRawEnabled = rawEnabled != nil ? [rawEnabled description] : @"(missing)";
        NSString *sRawAngle = rawAngle != nil ? [rawAngle description] : @"(missing)";

        // 快照（若尚未加载则强制刷新一次）
        if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
        double clamped = axs_ring_clamp(axs_snap_tiltAngle, 0.0, AXS_TILT_ANGLE_MAX);

        // 错误来源诊断：plist 有值但快照读默认；或 plist 缺失；或类型不对。
        // wrongDomain：文件里有旧 key（无 splitBeautify 前缀）的值，说明面板写到了旧 key；
        // emptyDefault：两个 key 都缺 → 快照走默认（NO/3.0）；
        // typeMismatch：原始值类型不是 NSNumber（BOOL/double 期望）。
        id legacyEnabled = [raw isKindOfClass:[NSDictionary class]]
                           ? [raw objectForKey:@"tiltEnabled"] : nil;
        id legacyAngle = [raw isKindOfClass:[NSDictionary class]]
                         ? [raw objectForKey:@"tiltAngle"] : nil;
        BOOL wrongDomain = (legacyEnabled != nil || legacyAngle != nil);
        BOOL emptyDefault = (rawEnabled == nil && rawAngle == nil);
        BOOL typeMismatch = ((rawEnabled != nil && ![rawEnabled isKindOfClass:[NSNumber class]])
                             || (rawAngle != nil && ![rawAngle isKindOfClass:[NSNumber class]]));
        // 面板显示开但快照 NO/0 的关键矛盾检测：plist 原始 enabled=YES 而快照 NO。
        BOOL snapshotMismatch = NO;
        if ([rawEnabled isKindOfClass:[NSNumber class]] && [rawEnabled boolValue]
            && !axs_snap_tiltEnabled) snapshotMismatch = YES;

        axs_ring_log(@"ring tilt PREFS plistPath=%@ exists=%d "
                     @"plistRaw(enabled=%@ angle=%@) snapshot(enabled=%d angle=%.1f) "
                     @"clamped=%.1f default(NO/3.0) "
                     @"wrongDomain=%d emptyDefault=%d typeMismatch=%d snapshotMismatch=%d",
                     prefPath, raw != nil ? 1 : 0,
                     sRawEnabled, sRawAngle,
                     axs_snap_tiltEnabled ? 1 : 0, axs_snap_tiltAngle,
                     clamped, wrongDomain ? 1 : 0, emptyDefault ? 1 : 0,
                     typeMismatch ? 1 : 0, snapshotMismatch ? 1 : 0);
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring tilt PREFS", exception, nil);
    }
}

static UIColor *axs_ring_color(void) {
    // beautify.42：读快照（解析只在快照刷新时做一次）
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_ringColor;
}

// --- 光晕配置 (beautify.30)：独立于光圈外框，沿用同一偏好域与快照 -------------

static BOOL axs_ring_glowEnabled(void) {
    // beautify.40：同 axs_ring_enabled——总闸不进本函数（纯子开关读取）
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_glowOn;
}

// --- beautify.41：单个容器的侧贴小窗分类 --------------------------------------
// splitBeautifyDecorEnabled 只控侧贴/窄边小窗的装饰层；居中大浮窗完全忽略
// 总开关，继续按光圈外框/窗口光晕子开关显示。分类按单个容器独立计算，
// 绝不在扫描入口用总开关一刀切。

// 动态探测协议：让编译器看到 ScreenCore 内部对象可能带的可选选择子，
// 全部调用点都有 respondsToSelector 守卫，对象不实现即返回 NO/nil。
@protocol AXSRingDockedProbe <NSObject>
@optional
- (BOOL)isDocked;
- (id)session;
- (id)manager;
// beautify.46：原生 Dock 链路对象（存在才读，全部 respondsToSelector 守卫）
- (id)dockSide;
- (id)dockRecord;
- (id)record;
- (id)hostWindow;
- (id)contentHostView;
- (id)itemView;
- (id)rootView;
@end

// 对象自身是否报告 docked（内部状态优先）
static BOOL axs_ring_objectIsDocked(id obj) {
    if (obj == nil) return NO;
    id<AXSRingDockedProbe> probe = obj;
    if ([probe respondsToSelector:@selector(isDocked)]) {
        return ([probe isDocked]) ? YES : NO;
    }
    return NO;
}

// 单容器 docked 判定：
// 1) 内部状态优先——沿 delegate → 父视图链 → window/rootViewController →
//    window 本体解析关联对象（含经 session/manager 属性间接一层到
//    SCFloatingSceneSession/manager），任一对象 respondsToSelector:
//    @selector(isDocked) 即以内部状态为准；
// 2) 内部状态读不到时用几何兜底：presentationLayer.frame（或 bounds）
//    宽 ≤ 屏宽 45%，且原点距左边缘或右边缘 ≤ 12pt，同时满足才判侧贴，
//    否则一律按居中大浮窗处理；
// 3) 分类全程 @try/@catch，失败按居中大浮窗处理，绝不影响主队列。
static BOOL axs_ring_containerIsDocked(UIView *container) {
    if (container == nil) return NO;
    @try {
        NSMutableArray *cands = [NSMutableArray array];
        if ([container respondsToSelector:@selector(delegate)]) {
            id del = [(id)container delegate];
            if (del != nil) [cands addObject:del];
        }
        UIView *sv = container.superview;
        int hops = 0;
        while (sv != nil && hops < 6) {
            [cands addObject:sv];
            sv = sv.superview;
            hops++;
        }
        UIWindow *w = container.window;
        if (w != nil) {
            [cands addObject:w];
            id rvc = [w rootViewController];
            if (rvc != nil) [cands addObject:rvc];
        }
        for (id c in cands) {
            if (axs_ring_objectIsDocked(c)) return YES;
            id<AXSRingDockedProbe> probe = c;
            if ([probe respondsToSelector:@selector(session)]) {
                if (axs_ring_objectIsDocked([probe session])) return YES;
            }
            if ([probe respondsToSelector:@selector(manager)]) {
                if (axs_ring_objectIsDocked([probe manager])) return YES;
            }
        }

        // beautify.59（指令 七）：几何兜底用「model layer / view.frame」换算到主屏坐标，
        // 绝不用 presentationLayer.frame——.49 把自己写入的 3D 经 presentation 反馈，
        // 导致脱离侧贴后 docked 判定抖动、base 被污染成倾斜矩阵、居中残留 m13/m31/m34。
        CGRect frame = container.frame;
        if (container.superview != nil) frame = [container.superview convertRect:frame toView:w];
        CGFloat sw = 0;
        if (w != nil) {
            sw = w.bounds.size.width;
        } else {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    sw = ((UIWindowScene *)scene).screen.bounds.size.width;
                    break;
                }
            }
        }
        if (sw <= 0) return NO;
        CGFloat leftGap = frame.origin.x;
        CGFloat rightGap = sw - (frame.origin.x + frame.size.width);
        CGFloat ratio = frame.size.width / sw;
        // beautify.59（指令 七.2）：原生状态滞后为 0 时几何兜底不能被否决——
        // 几何贴边成立（ratio<0.45 且边距≤80pt）即判侧贴；居中大窗 ratio≥0.45 天然排除。
        if (ratio >= 0.45) return NO;
        if (leftGap <= 80.0 && leftGap <= rightGap) return YES;
        if (rightGap <= 80.0) return YES;
        return NO;
    } @catch (NSException *exception) {
        return NO;
    }
}

// --- beautify.44：侧倾配置 getter（读 .42 偏好快照，零每帧 defaults 读取） ---
static BOOL axs_ring_tiltEnabled(void) {
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_tiltEnabled;
}
static double axs_ring_tiltAngle(void) {
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_tiltAngle;
}

// 侧贴方向：+1 右侧 / -1 左侧。沿用 .41/.43 的「内部状态优先、几何兜底」思路。
// 1) 沿 delegate → 父视图链 → window/rootVC → session/manager 探测带 side 语义的
//    BOOL（isLeftDocked/isRightDocked/isDockedLeft/isDockedRight/leftDocked/rightDocked）
//    或枚举（dockSide/side/dockPosition：常见 0=左 1=右，也兼容字符串 left/right）；
// 2) 读不到时用容器中心与屏幕中心比较，偏左 -1，偏右 +1；
// 3) 全程 @try/@catch，失败按几何结果走；几何也读不到时默认 +1（右侧）。
static int axs_ring_containerDockSide(UIView *container) {
    if (container == nil) return 1;
    @try {
        NSMutableArray *cands = [NSMutableArray array];
        if ([container respondsToSelector:@selector(delegate)]) {
            id del = [(id)container delegate];
            if (del != nil) [cands addObject:del];
        }
        UIView *sv = container.superview;
        int hops = 0;
        while (sv != nil && hops < 6) { [cands addObject:sv]; sv = sv.superview; hops++; }
        UIWindow *w = container.window;
        if (w != nil) {
            [cands addObject:w];
            id rvc = [w rootViewController];
            if (rvc != nil) [cands addObject:rvc];
        }
        for (id c in cands) {
            // BOOL 语义探测
            NSString *leftSels[] = {@"isLeftDocked", @"isDockedLeft", @"leftDocked", @"isOnLeftSide"};
            NSString *rightSels[] = {@"isRightDocked", @"isDockedRight", @"rightDocked", @"isOnRightSide"};
            for (int i = 0; i < 4; i++) {
                SEL sl = NSSelectorFromString(leftSels[i]);
                if ([c respondsToSelector:sl]) {
                    BOOL (*imp)(id, SEL) = (BOOL (*)(id, SEL))[c methodForSelector:sl];
                    if (imp && imp(c, sl)) return -1;
                }
                SEL sr = NSSelectorFromString(rightSels[i]);
                if ([c respondsToSelector:sr]) {
                    BOOL (*imp)(id, SEL) = (BOOL (*)(id, SEL))[c methodForSelector:sr];
                    if (imp && imp(c, sr)) return 1;
                }
            }
            // 枚举/对象语义探测
            NSArray *enumSels = @[@"dockSide", @"side", @"dockPosition", @"dockEdge"];
            for (NSString *sn in enumSels) {
                SEL s = NSSelectorFromString(sn);
                if (![c respondsToSelector:s]) continue;
                id val = ((id(*)(id, SEL))[c methodForSelector:s])(c, s);
                if ([val isKindOfClass:[NSString class]]) {
                    NSString *low = [(NSString *)val lowercaseString];
                    if ([low containsString:@"left"]) return -1;
                    if ([low containsString:@"right"]) return 1;
                }
                if ([val isKindOfClass:[NSNumber class]]) {
                    NSInteger iv = [val integerValue];
                    if (iv == 0) return -1;   // 常见枚举 0=左
                    if (iv == 1) return 1;    // 1=右
                }
            }
        }
        // 几何兜底（beautify.45）：必须在 window 坐标系里比较真实位置。
        // .44 用 container.bounds（origin 恒为 0）算中心，无动画时永远判左侧。
        // 用 container.frame（相对父视图）convert 到 window；presentation 优先。
        CGRect f = container.frame;
        if (container.superview != nil && w != nil) {
            f = [container.superview convertRect:f toView:w];
        }
        // beautify.59：不用 presentationLayer（避免自身 3D 反馈），用 model frame。
        CGFloat cx = f.origin.x + f.size.width / 2.0;
        CGFloat sw = 0;
        if (w != nil) sw = w.bounds.size.width;
        else {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    sw = ((UIWindowScene *)scene).screen.bounds.size.width;
                    break;
                }
            }
        }
        if (sw <= 0) return 1;
        return (cx < sw / 2.0) ? -1 : 1;
    } @catch (NSException *exception) {
        return 1;
    }
}

// --- beautify.59：侧贴判断核查（指令 三） -------------------------------------
// 对当前浮窗同时核查 isDocked/_docked、dockSide/dockPosition/dockEdge、左右候选
// 选择子，以及几何边距兜底。日志输出 session/record/manager/container/hostWindow
// 的类名地址、docked/dockSide/几何 frame/宽高比/左右边距和最终判定。
static void axs_ring_tiltLogDockState(UIView *container) {
    @try {
        if (container == nil) return;
        UIWindow *w = container.window;
        NSMutableArray *direct = [NSMutableArray array];
        id del = [container respondsToSelector:@selector(delegate)] ? [(id)container delegate] : nil;
        if (del != nil) [direct addObject:del];
        [direct addObject:container];
        UIView *sv = container.superview;
        int hops = 0;
        while (sv != nil && hops < 6) { [direct addObject:sv]; sv = sv.superview; hops++; }
        if (w != nil) [direct addObject:w];
        if (w.rootViewController != nil) [direct addObject:w.rootViewController];
        // 间接一层：session / record / manager / dockRecord
        NSArray *linkKeys = @[@"session", @"record", @"manager", @"dockRecord"];
        NSMutableArray *all = [NSMutableArray arrayWithArray:direct];
        for (id c in direct) {
            for (NSString *k in linkKeys) {
                id v = axs_ring_nsValue(c, k);
                if (v != nil && ![all containsObject:v]) [all addObject:v];
            }
        }

        NSMutableString *chain = [NSMutableString string];
        NSArray *stateKeys = @[@"isDocked", @"_docked", @"docked", @"dockSide",
                               @"dockPosition", @"dockEdge",
                               @"isLeftDocked", @"isDockedLeft", @"leftDocked",
                               @"isRightDocked", @"isDockedRight", @"rightDocked"];
        for (id c in all) {
            NSMutableString *states = [NSMutableString string];
            for (NSString *k in stateKeys) {
                id v = axs_ring_nsValue(c, k);
                if (v != nil) [states appendFormat:@" %@=%@", k, [v description]];
            }
            [chain appendFormat:@"\n    %@%@", axs_ring_nsDesc(c), states];
        }

        // 几何：window 坐标系里的 frame / 宽高比 / 左距 / 右距
        CGRect f = container.frame;
        if (container.superview != nil && w != nil) {
            f = [container.superview convertRect:f toView:w];
        }
        CALayer *pres = container.layer.presentationLayer;
        if ([pres isKindOfClass:[CALayer class]]) {
            CGRect pf = [(CALayer *)pres frame];
            CALayer *sl = container.layer.superlayer;
            if (sl != nil) pf = [sl convertRect:pf toLayer:w.layer];
            if (pf.size.width > 0) f = pf;
        }
        CGFloat sw = w.bounds.size.width;
        CGFloat leftGap = f.origin.x;
        CGFloat rightGap = sw - (f.origin.x + f.size.width);
        CGFloat ratio = (sw > 0) ? f.size.width / sw : 0.0;
        BOOL docked = axs_ring_containerIsDocked(container);
        int side = axs_ring_containerDockSide(container);
        NSString *verdict = !docked ? @"centerLarge" : (side < 0 ? @"leftDocked" : @"rightDocked");
        axs_ring_log(@"ring tilt DOCK container=%@ hostWindow=%@ "
                     @"frame=%@ ratio=%.3f leftGap=%.1f rightGap=%.1f "
                     @"docked=%d side=%d verdict=%@ chain=%@",
                     axs_ring_nsDesc(container), axs_ring_nsDesc(w),
                     NSStringFromCGRect(f), ratio, leftGap, rightGap,
                     docked ? 1 : 0, side, verdict, chain);
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring tilt DOCK", exception, container);
    }
}

// 按窗口类型分别接总开关（指令 三）：
// docked=YES（侧贴小窗）：ringAllowed = master && ringOn，glowAllowed = master && glowOn；
// docked=NO（居中大浮窗）：忽略 master，ringAllowed = ringOn，glowAllowed = glowOn。
// 条件按单个 driver/单个容器判断——绝不因 master=NO 遍历全部 driver detach。
static BOOL axs_ring_ringAllowedFor(BOOL docked) {
    if (docked) return axs_ring_decorEnabled() && axs_ring_enabled();
    return axs_ring_enabled();
}

static BOOL axs_ring_glowAllowedFor(BOOL docked) {
    if (docked) return axs_ring_decorEnabled() && axs_ring_glowEnabled();
    return axs_ring_glowEnabled();
}

static BOOL axs_ring_glowCustomColor(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_glowCustom;
}

static double axs_ring_glowRadiusValue(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_glowRadius;
}

// beautify.31 修复：光晕颜色来源。
// - 自定义开：glowColor（保留 RGB，alpha 过低补回基础不透明度）
// - 自定义关：跟随光圈边框色——边框单色用 ringFrameColor；边框彩虹按与
//   conic 渐变同一 4.0s 旋转周期采样当前色相；光圈关闭拿不到色则回退白。
static UIColor *axs_ring_glowCustomColorValue(void) {
    // beautify.42：读快照（解析+alpha 补偿只在快照刷新时做一次）
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_glowColorBase;
}

static UIColor *axs_ring_glowColor(void) {
    if (axs_ring_glowCustomColor()) return axs_ring_glowCustomColorValue();

    // 跟随边框：光圈必须开着才有边框色可跟
    if (axs_ring_enabled()) {
        if (axs_ring_customColor()) {
            return axs_ring_color();                 // 边框单色 = ringFrameColor
        }
        // 彩虹跑马灯：conic 渐变每 4.0s 转一圈（见 makeGradient 的 spin.duration）
        // 用同一周期与起点算当前色相，光晕与边框色相同步，且仅设颜色、不另加动画
        double period = 4.0;
        double t = fmod(CACurrentMediaTime(), period) / period;
        if (t < 0) t += 1.0;
        return [UIColor colorWithHue:t saturation:1.0 brightness:1.0 alpha:1.0];
    }
    return [UIColor whiteColor];                     // 光圈关闭兜底
}

// 是否处于「跟随边框彩虹」：需要每帧刷新光晕色相（不重建几何、不另加动画）
static BOOL axs_ring_glowFollowsRainbow(void) {
    return axs_ring_glowEnabled() && !axs_ring_glowCustomColor()
        && axs_ring_enabled() && !axs_ring_customColor();
}

// 光晕范围（面板 0–200，默认 116）。radius=0 不显示。
static double axs_ring_glowRange(void) {
    return axs_ring_glowRadiusValue();
}

// beautify.32 光晕亮度：面板 0–100，默认 100 → 系数 0.0–1.0。
// 只缩放光晕不透明度/alpha，不改色相、范围、模糊半径或光圈描边。
static double axs_ring_glowBrightness(void) {
    // beautify.42：读快照
    if (!axs_snap_loaded) axs_ring_refreshConfigSnapshot();
    return axs_snap_glowBrightness;
}

static CGFloat axs_ring_glowBrightnessFactor(void) {
    return (CGFloat)(axs_ring_glowBrightness() / 100.0);
}

// --- 跑马灯：conic 闭环取色 + 渐变层线性旋转（TXT beautify.24 三.3.A） --------

static NSArray<UIColor *> *axs_ring_rainbow(void) {
    // HSB 色相均分闭环：12 段 + 首尾同色（hue 0°=360°），conic 收口无缝
    NSMutableArray<UIColor *> *cs = [NSMutableArray array];
    const NSUInteger steps = 12;
    for (NSUInteger i = 0; i <= steps; i++) {
        double hue = (double)i / (double)steps;
        [cs addObject:[UIColor colorWithHue:hue saturation:1.0 brightness:1.0 alpha:1.0]];
    }
    return cs;
}

static CAGradientLayer *axs_ring_makeGradient(BOOL custom, UIColor *color) {
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.type = kCAGradientLayerConic;
    grad.startPoint = CGPointMake(0.5, 0.5);
    grad.endPoint = CGPointMake(0.5, 0.0);
    if (custom) {
        grad.colors = @[ (__bridge id)color.CGColor, (__bridge id)color.CGColor ];
        grad.locations = @[ @0.0, @1.0 ];
        // 自定义单色：纯色环，不加任何动画（TXT beautify.24 三.4）
    } else {
        NSArray<UIColor *> *rainbow = axs_ring_rainbow();
        NSUInteger n = rainbow.count;
        NSMutableArray *colors = [NSMutableArray array];
        NSMutableArray *locations = [NSMutableArray array];
        for (NSUInteger i = 0; i < n; i++) {
            [colors addObject:(__bridge id)rainbow[i].CGColor];
            [locations addObject:@((double)i / (double)(n - 1))];
        }
        grad.colors = colors;
        grad.locations = locations;

        // 跑马灯 = 渐变层线性旋转 0→2π（TXT beautify.25 四.1）：
        // 首尾旋转值同角无缝，色环整体连续流动；colors 数组静态闭合，
        // 不做任何关键帧/位移动画（四.3）。环遮罩在父层 ring.mask 上，
        // 旋转渐变子层不影响环形状
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0.0;
        spin.toValue = @(M_PI * 2.0);
        spin.duration = 4.0;
        spin.repeatCount = HUGE_VALF;
        spin.removedOnCompletion = NO;
        [grad addAnimation:spin forKey:@"axsRingMarquee"];
    }
    return grad;
}

// --- 圆角矩形 CGPath 半径提取（probe 日志用） --------------------------------

typedef struct {
    CGFloat radius;
    CGPoint from;
    BOOL started;
} AXSRingPathCtx;

static void axs_ring_pathApplier(void *info, const CGPathElement *element) {
    AXSRingPathCtx *ctx = (AXSRingPathCtx *)info;
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            ctx->from = element->points[0];
            ctx->started = YES;
            break;
        case kCGPathElementAddLineToPoint:
            ctx->from = element->points[0];
            break;
        case kCGPathElementAddCurveToPoint: {
            CGPoint cp1 = element->points[0];
            CGFloat dr = fabs(cp1.y - ctx->from.y);
            if (dr < 0.01) dr = fabs(cp1.x - ctx->from.x);
            if (ctx->radius < 0.01 && dr > 0.5) ctx->radius = dr;
            ctx->from = element->points[3];
            break;
        }
        default: break;
    }
}

static CGFloat axs_ring_radiusFromPath(CGPathRef path) {
    if (path == nil) return 0;
    AXSRingPathCtx ctx = { 0, CGPointZero, NO };
    CGPathApply(path, &ctx, axs_ring_pathApplier);
    return ctx.radius;
}

// --- 探测辅助（只读） --------------------------------------------------------

// 读 CAShapeLayer 类型的 ivar（SCFloatingCornerGestureRegionView 的
// _interactiveMaskLayer 等）
static CAShapeLayer *axs_ring_ivarShape(id obj, const char *name) {
    if (obj == nil) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
        if (ivar == nil) return nil;
        id v = object_getIvar(obj, ivar);
        return [v isKindOfClass:[CAShapeLayer class]] ? v : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

// 递归收集子树内所有 CAShapeLayer 遮罩（layer.mask + _interactiveMaskLayer）
static void axs_ring_collectMasks(UIView *view, int depth, NSMutableArray<CAShapeLayer *> *out) {
    if (view == nil || depth > 4) return;
    if ([view.layer.mask isKindOfClass:[CAShapeLayer class]]) {
        [out addObject:(CAShapeLayer *)view.layer.mask];
    }
    CAShapeLayer *im = axs_ring_ivarShape(view, "_interactiveMaskLayer");
    if (im != nil && im.path != nil) [out addObject:im];
    for (UIView *sub in view.subviews) {
        axs_ring_collectMasks(sub, depth + 1, out);
    }
}

// --- 每容器驱动（CADisplayLink 一对一；容器消失即停） -------------------------

@class AXSRingLinkDriver;
@class AXSRingHealthTarget;

static void axs_ring_syncDriver(AXSRingLinkDriver *driver);
static void axs_ring_applyTilt(AXSRingLinkDriver *driver);
static void axs_ring_resetTilt(AXSRingLinkDriver *driver);

@interface AXSRingLinkDriver : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) CALayer *ring;            // axsRingFrame
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) CAShapeLayer *shape;      // ring.mask
@property (nonatomic, weak) CAShapeLayer *radiusMask;   // 整框 overlay mask（兜底半径来源）
@property (nonatomic, weak) UIView *overlay;            // SCFloatingInteractionOverlayView
@property (nonatomic, weak) CALayer *realLayer;         // 真实裁剪层（bbox≈容器 bounds，几何源）
@property (nonatomic, weak) CALayer *mountLayer;        // 挂载层（非裁剪祖先，masksToBounds=0）
@property (nonatomic, strong) CAShapeLayer *glowInner;   // beautify.31 内层柔光（贴边）
@property (nonatomic, strong) CAShapeLayer *glowOuter;   // beautify.31 外层宽扩散
@property (nonatomic, assign) CGFloat overlayR;         // overlay mask 当前半径（对照日志）
@property (nonatomic, assign) CGRect lastBounds;        // 上帧应用的 presentation bounds
@property (nonatomic, assign) CGFloat lastRadius;       // 上帧应用的环圆角
@property (nonatomic, assign) CGFloat lastLineWidth;
@property (nonatomic, assign) double lastGlowRange;     // 上帧光晕范围（0=未显示）
@property (nonatomic, assign) double lastGlowBrightness;// 上帧光晕亮度（0–100）
@property (nonatomic, assign) BOOL lastGlowEnabled;
@property (nonatomic, assign) BOOL lastIsDocked;        // beautify.43：上帧侧贴/居中分类（每帧重算，记录不门控）
@property (nonatomic, assign) BOOL lastRingAllowed;     // beautify.43：上帧光圈可见性（记录不门控）
@property (nonatomic, assign) BOOL lastGlowAllowed;     // beautify.43：上帧光晕可见性（记录不门控）
@property (nonatomic, assign) CGRect lastPathBounds;    // beautify.42：上帧描边路径矩形（未变不重建 CGPath）
@property (nonatomic, assign) double lastPathRadius;    // beautify.42：上帧描边路径圆角
@property (nonatomic, assign) CGFloat lastGradientDiag; // beautify.42：上帧渐变层对角线（未变不更新 frame）
@property (nonatomic, assign) CGRect lastGlowGeomBounds;   // beautify.42：上帧光晕几何矩形
@property (nonatomic, assign) CGFloat lastGlowGeomRadius;  // beautify.42：上帧光晕几何圆角
@property (nonatomic, assign) CGFloat lastGlowInnerBlur;   // beautify.42
@property (nonatomic, assign) CGFloat lastGlowOuterBlur;   // beautify.42
@property (nonatomic, assign) CGFloat lastGlowInnerOp;     // beautify.42
@property (nonatomic, assign) CGFloat lastGlowOuterOp;     // beautify.42
@property (nonatomic, strong) UIColor *lastGlowColorObj;   // beautify.42：上帧光晕颜色
@property (nonatomic, copy) NSString *radiusSource;     // overlayMask|config
@property (nonatomic, assign) BOOL loggedAttach;
// beautify.47：3D 侧透视宿主 UIView（同时包住白色背景/黑色内容/装饰层的公共祖先）
@property (nonatomic, weak) UIView *tiltTarget;          // 3D 透视宿主（整卡容器/安全祖先）
@property (nonatomic, assign) BOOL tiltProbed;           // 已做过层级探针（避免每帧重探）
@property (nonatomic, assign) CATransform3D lastTilt;    // 上次「我们写入」的复合 transform3D（幂等基线）
@property (nonatomic, assign) BOOL hasTilt;              // 是否曾施加过透视（用于 detach 恢复 base）
// 探测失败节流到 1s 一次；overlay 若物理挂在宿主子树内，需抵消父级 3D（保持屏幕平面）。
@property (nonatomic, assign) NSTimeInterval tiltLastProbeTime;
@property (nonatomic, weak) UIView *tiltOverlayView;
@property (nonatomic, assign) BOOL tiltOverlayInHost;     // overlay 是否为宿主子孙（需逆变换抵消）
@property (nonatomic, assign) CATransform3D lastOverlayTilt;
// beautify.47：复合变换基线（全部升级为 CATransform3D）。base=宿主原生 transform3D 快照；
// rotationY 含 m34 透视，与 base 复合；恢复回 base（不是 identity）。
@property (nonatomic, assign) CATransform3D tiltBaseTransform;   // 原生 base3D 快照
@property (nonatomic, assign) CATransform3D lastRotation;        // 上次施加的 rotationY(含 m34)
@property (nonatomic, copy)   NSString *tiltHostName;            // 宿主类名（探针日志）
@property (nonatomic, assign) BOOL tiltNeedRebase;               // 原生方法命中后强制重采样 base
@property (nonatomic, assign) CATransform3D overlayBaseTransform;// overlay 原生 base3D 快照
@property (nonatomic, assign) BOOL loggedTiltChain;              // 3D 链路日志只写一次
// beautify.59：presentationLayer 复核——记录上一帧写入的 want，下一帧读回实际 presentation transform，
// 若被原生布局重置为 identity 则定位触发方法（指令 六.4/八.9）。
@property (nonatomic, assign) CATransform3D tiltLastWrote;       // 上一帧写入 layer.transform 的 want
@property (nonatomic, assign) BOOL tiltHasWrote;                 // 是否已写入过（首帧不复核）
@property (nonatomic, assign) NSInteger tiltVerifyPending;       // >0 表示还需再等 N 帧再复核（跳开动画插值）
@property (nonatomic, assign) NSInteger tiltResetReportCount;    // 重置日志节流（最多报若干次）
// beautify.47：手势命中区（overlay/边条/角区）原始 frame/transform，供恢复（平面命中）
@property (nonatomic, strong) NSMutableDictionary *tiltHitOriginals; // key(ptr)->NSValue(frame) / key+"T"->NSValue(transform3D)
// beautify.59：多视觉宿主（CONTENT 分支根 + BACKGROUND 分支根），彼此为兄弟、都不含 overlay。
// key 带宿主地址；nativeBase 只在首次写入透视前读取一次，绝不把倾斜后矩阵当 nativeBase。
@property (nonatomic, strong) NSArray *tiltVisualHosts;              // UIView* 数组
@property (nonatomic, strong) NSMutableDictionary *tiltVisualBase;   // key(ptr)->NSValue(CATransform3D) 原生 base
@property (nonatomic, strong) NSMutableDictionary *tiltVisualWrote;  // key(ptr)->NSValue(CATransform3D) 上次写入
@property (nonatomic, strong) NSMutableDictionary *tiltVisualNames;  // key(ptr)->类名（日志）
@property (nonatomic, strong) NSMutableDictionary *tiltVisualClips;  // key(ptr)->NSValue(BOOL) 原生 clipsToBounds（侧贴临时关闭后复位恢复）
@property (nonatomic, strong) NSMutableDictionary *tiltVisualMask;   // key(ptr)->NSNull：插件已给宿主挂 AxsTiltCornerMask（复位移除）
@property (nonatomic, strong) NSMutableDictionary *tiltVisualCorner; // key(ptr)->NSValue(CGFloat) CORNER_CLIP 探到的圆角半径
@property (nonatomic, assign) BOOL tiltVisualProbed;                 // 本 driver 是否已探测过视觉宿主
@property (nonatomic, assign) NSTimeInterval tiltVisualProbeTime;    // 视觉宿主重探节流
@property (nonatomic, assign) BOOL loggedZOrder;                     // beautify.59：ZORDER 日志只写一次
@property (nonatomic, assign) BOOL lastDockSnap;                     // beautify.59：上帧贴边态（翻转时抓拍快照）
@property (nonatomic, assign) BOOL tiltShadowWasActive;              // beautify.71：本 driver 是否处于倾斜态（全局计数对账用）
@property (nonatomic, assign) int scanMissCount;                     // beautify.71：连续缺席扫描次数（宽限期防抖）
@property (nonatomic, assign) BOOL tiltShadowProbed;                 // beautify.71：SHADOW_PROBE 每次倾斜会话只输出一次
- (void)tick;
@end

@implementation AXSRingLinkDriver
// beautify.43：恢复 .41 的 displayLink 刷新时机——driver 存活期间每帧同步，
// 不因“静止”暂停、不早退。大窗贴边变小窗时 docked/allowed 必须在同一帧
// 重新计算并提交 hidden/alpha；.42 的静止暂停与待同步门控正是贴边后
// 边框/光晕残留 0.2–0.3s 的回归根因，本版整体回退（指令 三.1/三.2）。
- (void)tick {
    @try {
        axs_ring_syncDriver(self);
    } @catch (NSException *exception) {
        axs_ring_log(@"ring tick exception: %@", exception);
    }
}
@end

// --- 光晕层 (beautify.31) ----------------------------------------------------
// 纯 CAShapeLayer 同色柔光，两层同路径：内层紧贴边框（较高不透明/小 blur），
// 外层宽扩散（低不透明/大 blur）。shadowColor 始终是边框色或所选光晕色，
// 绝不用黑/灰。填充 alpha 压到 ~0.01（几乎透明、不染窗口内部），用显式
// shadowPath = 窗口圆角矩形投光，mask 挖空窗口内部；不包 UIView、不接管触摸。
static CAShapeLayer *axs_ring_makeGlowLayer(NSString *name) {
    CAShapeLayer *glow = [CAShapeLayer layer];
    glow.name = name;
    glow.strokeColor = nil;
    glow.lineWidth = 0.0;
    glow.shadowOffset = CGSizeZero;
    glow.shadowRadius = 8.0;
    glow.shadowOpacity = 0.30;
    glow.shadowColor = [UIColor whiteColor].CGColor;
    glow.fillColor = [[UIColor whiteColor] colorWithAlphaComponent:0.01].CGColor;
    glow.masksToBounds = NO;                         // 外发光不被自身边界裁掉
    glow.contentsScale = [UIScreen mainScreen].scale;

    CAShapeLayer *donut = [CAShapeLayer layer];      // even-odd 挖空窗口内部
    donut.fillColor = [UIColor whiteColor].CGColor;
    donut.fillRule = kCAFillRuleEvenOdd;
    glow.mask = donut;
    return glow;
}

// 大半径降低不透明度，防止亮部爆白/爆色（116 默认 1.0，200 约 0.65）。
static CGFloat axs_ring_glowOpacityScale(double range) {
    if (range <= 116.0) return 1.0;
    return (CGFloat)axs_ring_clamp(1.0 - (range - 116.0) / 84.0 * 0.35, 0.6, 1.0);
}

// 用窗口矩形 + 圆角 + 外扩余量，配置一层柔光的 frame / shadowPath / mask / 颜色。
// bounds 是 mountLayer 坐标系下的窗口矩形；pad 已含 blur + 线宽 + 8pt 余量。
// beautify.42：几何（frame/shadowPath/mask）只在 bounds/圆角变化时重建；
// 颜色/blur/opacity 只在偏好或缓存值变化时更新——两部分互相独立。
static void axs_ring_configGlowLayer(CAShapeLayer *glow, CGRect bounds,
                                     CGFloat pathRadius, CGFloat pad,
                                     CGFloat blur, CGFloat opacity, UIColor *color,
                                     BOOL geomChanged, BOOL colorChanged) {
    if (glow == nil) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (geomChanged) {
        glow.frame = CGRectMake(bounds.origin.x - pad, bounds.origin.y - pad,
                                bounds.size.width + 2 * pad, bounds.size.height + 2 * pad);

        // shadowPath 在层自身坐标系里 = 窗口圆角矩形（相对外扩 pad），不随放大 frame 变形
        CGRect win = CGRectMake(pad, pad, bounds.size.width, bounds.size.height);
        UIBezierPath *winPath = [UIBezierPath bezierPathWithRoundedRect:win cornerRadius:pathRadius];
        glow.path = winPath.CGPath;
        glow.shadowPath = winPath.CGPath;

        // even-odd mask：外框(整层) + 内孔(窗口圆角矩形) → 内部完全不染色
        UIBezierPath *maskPath = [UIBezierPath bezierPathWithRect:glow.bounds];
        [maskPath appendPath:winPath];
        ((CAShapeLayer *)glow.mask).frame = glow.bounds;
        ((CAShapeLayer *)glow.mask).path = maskPath.CGPath;
    }
    if (colorChanged) {
        glow.shadowRadius = blur;
        glow.shadowOpacity = opacity;                                    // 已含亮度系数
        glow.shadowColor = color.CGColor;
        glow.fillColor = [color colorWithAlphaComponent:0.01 * axs_ring_glowBrightnessFactor()].CGColor; // 近透明，不染内部
    }
    glow.hidden = NO;
    [CATransaction commit];
}

// 每帧只更新光晕颜色（彩虹跟随用），不重建几何、不留隐式动画。
static void axs_ring_updateGlowColor(AXSRingLinkDriver *driver) {
    UIColor *color = axs_ring_glowColor();
    CGFloat fillAlpha = 0.01 * axs_ring_glowBrightnessFactor();   // beautify.32 亮度缩放 alpha
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    driver.glowInner.fillColor = [color colorWithAlphaComponent:fillAlpha].CGColor;
    driver.glowInner.shadowColor = color.CGColor;
    driver.glowOuter.fillColor = [color colorWithAlphaComponent:fillAlpha].CGColor;
    driver.glowOuter.shadowColor = color.CGColor;
    [CATransaction commit];
}

// 用窗口矩形 + 圆角 + 范围配置两层柔光；range<=0 / 关闭 / 亮度0 则隐藏两层。
static void axs_ring_applyGlow(AXSRingLinkDriver *driver, CGRect bounds,
                               CGFloat pathRadius, double range, CGFloat lineWidth) {
    if (driver.glowInner == nil || driver.glowOuter == nil) return;
    // beautify.41：按本容器分类拦截——sync 每帧都会走到这里，必须在此拦，
    // 否则侧贴小窗（master=OFF）或光晕子开关 OFF 时会被 sync 每帧重新点亮
    if (range <= 0.5 || !axs_ring_glowAllowedFor(axs_ring_containerIsDocked(driver.container))
        || axs_ring_glowBrightness() <= 0.5) {
        driver.glowInner.hidden = YES;
        driver.glowOuter.hidden = YES;
        return;
    }
    CGFloat r = (CGFloat)axs_ring_clamp(range, 0.0, 200.0);
    CGFloat innerBlur = (CGFloat)axs_ring_clamp(r * 0.30, 1.0, 60.0);
    CGFloat outerBlur = (CGFloat)axs_ring_clamp(r * 0.85, 2.0, 170.0);
    CGFloat pad = MAX(innerBlur, outerBlur) + lineWidth + 8.0;   // 最大 blur + 线宽 + 余量
    CGFloat scale = axs_ring_glowOpacityScale(range);
    CGFloat bright = axs_ring_glowBrightnessFactor();            // 亮度系数（不改 blur/色相）
    UIColor *color = axs_ring_glowColor();
    CGFloat innerOp = 0.35 * scale * bright;
    CGFloat outerOp = 0.14 * scale * bright;

    // beautify.42：几何/颜色/参数缓存比对——全未变则跳过整帧光晕重建
    // （shadowPath 只在 bounds/圆角变化时重建，颜色/blur/opacity 只在
    // 偏好或缓存值变化时更新）
    BOOL geomChanged = !CGRectEqualToRect(bounds, driver.lastGlowGeomBounds)
                    || fabs(driver.lastGlowGeomRadius - pathRadius) > 0.05;
    BOOL colorChanged = driver.lastGlowColorObj == nil || ![color isEqual:driver.lastGlowColorObj];
    BOOL innerChanged = fabs(driver.lastGlowInnerBlur - innerBlur) > 0.05
                     || fabs(driver.lastGlowInnerOp - innerOp) > 0.002;
    BOOL outerChanged = fabs(driver.lastGlowOuterBlur - outerBlur) > 0.05
                     || fabs(driver.lastGlowOuterOp - outerOp) > 0.002;
    if (!geomChanged && !colorChanged && !innerChanged && !outerChanged) return;

    axs_ring_configGlowLayer(driver.glowInner, bounds, (CGFloat)pathRadius, pad,
                             innerBlur, innerOp, color, geomChanged, colorChanged || innerChanged);
    axs_ring_configGlowLayer(driver.glowOuter, bounds, (CGFloat)pathRadius, pad,
                             outerBlur, outerOp, color, geomChanged, colorChanged || outerChanged);

    driver.lastGlowGeomBounds = bounds;
    driver.lastGlowGeomRadius = pathRadius;
    driver.lastGlowInnerBlur = innerBlur;
    driver.lastGlowOuterBlur = outerBlur;
    driver.lastGlowInnerOp = innerOp;
    driver.lastGlowOuterOp = outerOp;
    driver.lastGlowColorObj = color;
}

static NSMutableDictionary<NSString *, AXSRingLinkDriver *> *axs_ring_drivers = nil;

// beautify.43：扫描去重——同一轮多条通知（窗口可见性/saved 连发）只排一次
// 主队列 scanTick，避免重复 dispatch（指令 六.3）
static BOOL axs_ring_scanQueued = NO;
static void axs_ring_queueScan(void) {
    if (axs_ring_scanQueued) return;
    axs_ring_scanQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        axs_ring_scanQueued = NO;
        axs_ring_scanTick();
    });
}

// beautify.43：窗口通知/偏好 saved 回调内，对所有在册 driver 立即按当前
// docked/allowed 重算并同步提交可见性（指令 三.5/六.2）。displayLink 每帧
// 也做同样提交，这里只是事件到达时的即时补一拍，不引入任何延迟或状态缓存。
static void axs_ring_syncAllDriversNow(void) {
    for (AXSRingLinkDriver *dd in [axs_ring_drivers.allValues copy]) {
        if (![dd isKindOfClass:[AXSRingLinkDriver class]]) continue;
        axs_ring_syncDriver(dd);
    }
}

// 容器子树里找 interaction overlay（一层即中，找不到再进一层）
static UIView *axs_ring_findOverlay(UIView *container) {
    Class cls = objc_getClass("SCFloatingInteractionOverlayView");
    if (cls == nil) return nil;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:cls]) return sub;
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:cls]) return sub2;
        }
    }
    return nil;
}

// 掩码选择（TXT beautify.21 三.1.c）：整框 overlay mask——bbox 原点≈(0,0) 且
// 尺寸≈容器宽高+43.18pt；原点带负坐标的是角区/边条局部 mask，一律跳过。
// 它是手势命中区裁剪，半径只作兜底与对照，不再做任何缩放换算。
static BOOL axs_ring_selectMask(AXSRingLinkDriver *driver, UIView *container) {
    CGFloat expandedW = container.bounds.size.width + 43.18;
    CGFloat expandedH = container.bounds.size.height + 43.18;
    NSMutableArray<CAShapeLayer *> *masks = [NSMutableArray array];
    if (driver.overlay != nil) axs_ring_collectMasks(driver.overlay, 0, masks);
    axs_ring_collectMasks(container, 0, masks);
    for (CAShapeLayer *m in masks) {
        if (m.path == nil) continue;
        CGRect bb = CGPathGetBoundingBox(m.path);
        if (fabs(bb.origin.x) < 0.5 && fabs(bb.origin.y) < 0.5
            && fabs(bb.size.width - expandedW) < 8 && fabs(bb.size.height - expandedH) < 8) {
            driver.radiusMask = m;
            driver.overlayR = axs_ring_radiusFromPath(m.path);
            return YES;
        }
    }
    return NO;
}

// 真实裁剪层查找（TXT beautify.21 二.2）：在容器 layer 子树里找 bounds ≈
// 容器 bounds 的裁剪层（masksToBounds / 挂 mask / cornerRadius>0.5），
// 它的 cornerRadius 或自身 mask 半径才是黑窗真实圆角；跳过环自己的子树；
// 容器子树找不到再看一层 superview 子树。
static void axs_ring_walkClip(CALayer *layer, CGRect target, CALayer *ownRing, int depth,
                              CALayer **best, CGFloat *bestScore) {
    if (layer == nil || depth > 6) return;
    if (layer != ownRing) {
        CGRect b = layer.bounds;
        if (b.size.width > 20 && fabs(b.size.width - target.size.width) < 2
            && fabs(b.size.height - target.size.height) < 2) {
            BOOL clipper = layer.masksToBounds || layer.mask != nil || layer.cornerRadius > 0.5;
            if (clipper) {
                CGFloat score = (layer.cornerRadius > 0.5 ? 0.0 : 10.0)
                              + (layer.masksToBounds ? 0.0 : 5.0) + (CGFloat)depth * 0.1;
                if (score < *bestScore) { *bestScore = score; *best = layer; }
            }
        }
    }
    for (CALayer *sub in layer.sublayers) {
        axs_ring_walkClip(sub, target, ownRing, depth + 1, best, bestScore);
    }
}

static BOOL axs_ring_findRealClip(AXSRingLinkDriver *driver, UIView *container) {
    CALayer *best = nil;
    CGFloat bestScore = 1e9;
    axs_ring_walkClip(container.layer, container.bounds, driver.ring, 0, &best, &bestScore);
    if (best == nil && container.superview != nil) {
        bestScore = 1e9;
        axs_ring_walkClip(container.superview.layer, container.bounds, driver.ring, 0, &best, &bestScore);
    }
    driver.realLayer = best;
    return (best != nil);
}

// 挂载层查找（TXT beautify.23 二.1）：容器层自身优先；它也 clips=1 就沿
// superlayer 链向上找第一个 masksToBounds=0 的层，兜底回容器层。
// 裁剪层只提供圆角与几何，不能当环的父层（贴边描边会被切掉）。
static CALayer *axs_ring_findMount(UIView *container) {
    CALayer *l = container.layer;
    int hops = 0;
    while (l != nil && l.masksToBounds && hops < 8) {
        l = l.superlayer;
        hops++;
    }
    return l ?: container.layer;
}

// 全树一次性探针（TXT beautify.21 二）：从容器所在 window 的 layer 树递归
// 遍历，记录 SC*/_UI*/裁剪层的几何、cornerRadius、mask bbox/半径，定位
// 真实圆角来源；进程内只跑一次，不每帧写日志。
static int axs_ring_treeLines = 0;

static void axs_ring_treeWalk(CALayer *layer, int depth) {
    if (layer == nil || depth > 10 || axs_ring_treeLines > 140) return;
    NSString *cls = NSStringFromClass(layer.class);
    CAShapeLayer *m = [layer.mask isKindOfClass:[CAShapeLayer class]] ? (CAShapeLayer *)layer.mask : nil;
    BOOL interesting = [cls hasPrefix:@"SC"] || [cls hasPrefix:@"_UI"]
                       || layer.cornerRadius > 0.5 || layer.masksToBounds
                       || (m != nil && m.path != nil);
    if (interesting) {
        axs_ring_treeLines++;
        NSMutableString *line = [NSMutableString string];
        for (int i = 0; i < depth; i++) [line appendString:@" "];
        id del = layer.delegate;
        NSString *name = [del isKindOfClass:[UIView class]] ? NSStringFromClass([del class]) : cls;
        [line appendFormat:@"%@ frame=%@ bounds=%@ corner=%.2f clips=%d",
             name, NSStringFromCGRect(layer.frame), NSStringFromCGRect(layer.bounds),
             layer.cornerRadius, layer.masksToBounds ? 1 : 0];
        if (m != nil && m.path != nil) {
            [line appendFormat:@" maskBbox=%@ maskR=%.1f",
                 NSStringFromCGRect(CGPathGetBoundingBox(m.path)), axs_ring_radiusFromPath(m.path)];
        } else if (layer.mask != nil) {
            [line appendFormat:@" mask=%@", NSStringFromClass(layer.mask.class)];
        }
        axs_ring_log(@"ring tree: %@", line);
    }
    for (CALayer *sub in layer.sublayers) {
        axs_ring_treeWalk(sub, depth + 1);
    }
}

static BOOL axs_ring_treeProbed = NO;

static void axs_ring_treeProbe(UIView *container) {
    if (axs_ring_treeProbed) return;
    axs_ring_treeProbed = YES;
    UIWindow *w = container.window;
    if (w == nil) return;
    axs_ring_treeLines = 0;
    axs_ring_log(@"ring tree: window=%@ frame=%@ bounds=%@",
                 NSStringFromClass(w.class), NSStringFromCGRect(w.frame), NSStringFromCGRect(w.bounds));
    axs_ring_treeWalk(w.layer, 0);
}

// --- 几何同步（displayLink 每帧 + layoutSubviews 钩子共用） --------------------

// preferModel=YES（布局钩子路径）：手势直改模型后布局未提交，模型即最新值，
// 环用模型尺寸可与卡片同一个 commit 生效——右/下边（origin+size）不再滞后一帧
// （TXT beautify.22 三.3）；bounds 正被 CA 动画驱动时跳过，交 displayLink。
// displayLink 路径一律 presentation 优先（TXT 三.1/三.2）。
static void axs_ring_syncDriver2(AXSRingLinkDriver *driver, BOOL preferModel) {
    UIView *container = driver.container;
    if (container == nil || driver.ring == nil) return;
    if (container.window == nil) {          // 离层：等扫描/布局钩子 detach
        axs_ring_resetTilt(driver);         // beautify.44：窗口隐藏/离层立即回正
        return;
    }

    // beautify.43：每帧先算 docked 与 ringAllowed/glowAllowed 并同步提交可见性，
    // 先于一切几何 changed 判断、独立执行（指令 三.3/三.4、六.2/六.5）。
    // 状态变化视为 changed 项（visChanged 参与下方 changed 判断），但绝不以
    // lastBounds/lastRadius/lastLineWidth 未变跳过 hidden/alpha 提交。
    BOOL docked = axs_ring_containerIsDocked(container);
    BOOL ringAllowed = axs_ring_ringAllowedFor(docked);
    BOOL glowAllowed = axs_ring_glowAllowedFor(docked);
    BOOL visChanged = (docked != driver.lastIsDocked)
                   || (ringAllowed != driver.lastRingAllowed)
                   || (glowAllowed != driver.lastGlowAllowed);
    if (visChanged) {
        UIWindow *w = container.window;
        CGFloat sw = (w != nil) ? w.bounds.size.width : 0;
        CGFloat wRatio = (sw > 0) ? container.bounds.size.width / sw : 0;
        axs_ring_log(@"decor classify: container=%p frame=%@ wRatio=%.2f docked=%d master=%d ringAllowed=%d glowAllowed=%d",
                     container, NSStringFromCGRect(container.bounds), wRatio,
                     docked ? 1 : 0, axs_ring_decorEnabled() ? 1 : 0,
                     ringAllowed ? 1 : 0, glowAllowed ? 1 : 0);
    }
    // CATransaction 关隐式动画：隐藏 hidden=YES + alpha=0，恢复 hidden=NO + alpha=1，
    // 同一帧同步生效、无 fade 残留；只操作插件自建装饰层（ring/gradient/shape/glow），
    // 绝不触碰原始容器、宿主 root view/window 或应用内容（指令 三.6/六.6）。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    driver.ring.hidden = !ringAllowed;
    driver.ring.opacity = ringAllowed ? 1.0 : 0.0;
    if (driver.gradient != nil) {
        driver.gradient.hidden = !ringAllowed;
        driver.gradient.opacity = ringAllowed ? 1.0 : 0.0;
    }
    if (driver.shape != nil) {
        driver.shape.hidden = !ringAllowed;
        driver.shape.opacity = ringAllowed ? 1.0 : 0.0;
    }
    // beautify.43：glow 的 hidden/alpha 在此双向显式提交，完全脱离光晕几何
    // 缓存（.42 的 geomChanged 早退曾使隐藏后 hidden=NO 无法恢复）。applyGlow
    // 仍会按 range/brightness 做二次拦截，两者一致；glowAllowed=NO（含 master
    // OFF 的侧贴小窗）强制隐藏，恢复时同帧设回（指令 三.6/六.3/六.4）
    if (driver.glowInner != nil) {
        driver.glowInner.hidden = !glowAllowed;
        driver.glowInner.opacity = glowAllowed ? 1.0 : 0.0;
    }
    if (driver.glowOuter != nil) {
        driver.glowOuter.hidden = !glowAllowed;
        driver.glowOuter.opacity = glowAllowed ? 1.0 : 0.0;
    }
    [CATransaction commit];
    driver.lastIsDocked = docked;
    driver.lastRingAllowed = ringAllowed;
    driver.lastGlowAllowed = glowAllowed;

    // beautify.44：侧倾独立于几何 changed 判断，每帧重算（内部幂等：angle/side/
    // target 未变即跳过写 transform），保证滑条/开关/侧贴切换同帧生效
    axs_ring_applyTilt(driver);

    @try {
        double lineWidth = axs_ring_thickness();
        if (lineWidth < 0.5) lineWidth = 0.5;

        // 挂载层：非裁剪祖先（masksToBounds=0）——环挂进裁剪层会被自身圆角
        // mask 切到不可见（TXT beautify.23 二.1）；addSublayer 即置最上层（二.3）
        // beautify.42：缓存优先——弱引用失效/离树/开始裁剪才重新查找
        CALayer *mount = driver.mountLayer;
        if (!(mount != nil && mount.superlayer != nil && !mount.masksToBounds)) {
            mount = axs_ring_findMount(container);
            driver.mountLayer = mount;
        }
        if (driver.ring.superlayer != mount) {
            [driver.ring removeFromSuperlayer];
            [mount addSublayer:driver.ring];
        }

        // 几何源仍是真实裁剪层：presentation frame 经 convertRect:fromLayer:
        // 换算到挂载层坐标（TXT beautify.23 二.2）；右/下终点 = 换算后 origin+size
        // beautify.42：静止优先读 model frame（presentation == model，零视觉
        // 差异）；只有 bounds/position 存在 CA 动画时才读 presentationLayer
        CALayer *src = driver.realLayer ?: mount;
        BOOL srcAnimating = ([src animationForKey:@"bounds"] != nil
                             || [src animationForKey:@"position"] != nil);
        if (preferModel && srcAnimating) {
            return;                          // 弹簧动画进行中：displayLink 按 presentation 跟
        }
        CGRect bounds;
        if (!preferModel && srcAnimating) {
            CALayer *pres = src.presentationLayer;     // 视觉矩形
            CALayer *mp = mount.presentationLayer;
            if (pres != nil && mp != nil) {
                bounds = [mp convertRect:pres.frame fromLayer:pres];
            } else {
                bounds = [mount convertRect:src.frame fromLayer:src];
            }
        } else {
            bounds = [mount convertRect:src.frame fromLayer:src];
        }
        if (bounds.size.width < 20 || bounds.size.height < 20) return;

        // 圆角取值（TXT beautify.21 三）：overlay mask 是手势命中区裁剪，
        // 不是黑窗内容的真实圆角（外扩矩形缩半径方向错了）——优先级改为：
        //   a) 真实裁剪层 layer.cornerRadius；
        //   b) 该层自身 mask 的圆角（按其自身 bbox 换算）；
        //   c) overlay 整框 mask 半径原值（不做 mw/mh 缩放）；
        //   d) 配置圆角。逐帧重读，静止由 changed 检查跳过。
        CGFloat radius = 0;
        NSString *source = @"config";
        // beautify.42：缓存优先——realLayer 弱引用失效/离树才重新查找
        if (driver.realLayer == nil || driver.realLayer.superlayer == nil) {
            axs_ring_findRealClip(driver, container);
        }
        if (driver.realLayer != nil && driver.realLayer.cornerRadius > 0.5) {
            radius = driver.realLayer.cornerRadius;
            source = @"realCorner";
        }
        if (radius <= 0.5 && driver.realLayer != nil) {
            CAShapeLayer *rm = [driver.realLayer.mask isKindOfClass:[CAShapeLayer class]]
                                   ? (CAShapeLayer *)driver.realLayer.mask : nil;
            if (rm != nil && rm.path != nil) {
                CGRect bb = CGPathGetBoundingBox(rm.path);
                CGRect lb = driver.realLayer.bounds;
                CGFloat rMask = axs_ring_radiusFromPath(rm.path);
                if (rMask > 0.5 && bb.size.width > 1.0 && bb.size.height > 1.0
                    && lb.size.width > 1.0 && lb.size.height > 1.0) {
                    CGFloat kx = lb.size.width / bb.size.width;
                    CGFloat ky = lb.size.height / bb.size.height;
                    CGFloat rr = (CGFloat)MIN(rMask * kx, rMask * ky);
                    if (rr > 0.5) { radius = rr; source = @"realMask"; }
                }
            }
        }
        if (radius <= 0.5) {
            // beautify.42：缓存优先——radiusMask 失效/离树才重选
            if (driver.radiusMask == nil || driver.radiusMask.path == nil
                || driver.radiusMask.superlayer == nil) {
                axs_ring_selectMask(driver, container);
            }
            if (driver.radiusMask != nil && driver.radiusMask.path != nil) {
                CGFloat rMask = axs_ring_radiusFromPath(driver.radiusMask.path);
                if (rMask > 0.5) {
                    radius = rMask;             // 原值直用，不再缩放（TXT 三.1.c）
                    source = @"overlayMask";
                    driver.overlayR = rMask;
                }
            }
        }
        if (radius <= 0.5) {
            radius = (CGFloat)axs_ring_configRadius();
            source = @"config";
        }
        driver.radiusSource = source;

        // beautify.41：光晕按本容器分类闸门（侧贴小窗受 master 控制，
        // 居中大浮窗忽略 master 只按 glowOn）
        BOOL glowOn = axs_ring_glowAllowedFor(docked);
        double glowRange = glowOn ? axs_ring_glowRange() : 0.0;
        double glowBright = axs_ring_glowBrightness();
        // 彩虹跟随模式：颜色每帧随 conic 旋转变化，需要逐帧更新光晕色相
        if (glowOn && axs_ring_glowFollowsRainbow()) {
            axs_ring_updateGlowColor(driver);
        }
        // beautify.43：visChanged（docked/allowed 状态变化）本身即 changed 项，
        // 不能被 lastBounds/lastRadius/lastLineWidth 未变跳过；可见性提交已在
        // 上方无条件完成，这里只决定是否重建几何（指令 六.5）。
        BOOL changed = visChanged
                    || !CGRectEqualToRect(bounds, driver.lastBounds)
                    || fabs(driver.lastRadius - radius) > 0.05
                    || driver.lastLineWidth != (CGFloat)lineWidth
                    || driver.lastGlowEnabled != glowOn
                    || fabs(driver.lastGlowRange - glowRange) > 0.5
                    || fabs(driver.lastGlowBrightness - glowBright) > 0.5;  // beauty.32 亮度
        if (!changed) return; // 静止：几何/光晕未变只跳过几何重建（可见性已在上方提交）

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        driver.ring.frame = bounds;              // ringContainer.frame = 容器 bounds
        driver.shape.frame = driver.ring.bounds;
        // 路径矩形 = 容器 bounds，不整边内缩（TXT beautify.20 三.4）：
        // 描边中心线贴窗口边，外半覆盖接缝，四角不再留空隙
        CGRect r = driver.ring.bounds;
        double pathRadius = axs_ring_clamp(radius, 1.0, MAX(MIN(r.size.width, r.size.height) / 2.0, 1.0));
        // beautify.42：bounds/圆角未变不重建 UIBezierPath/CGPath、不重设 shape.path
        BOOL pathChanged = !CGRectEqualToRect(r, driver.lastPathBounds)
                        || fabs(driver.lastPathRadius - pathRadius) > 0.05;
        if (pathChanged) {
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:pathRadius];
            driver.shape.path = p.CGPath;
            driver.lastPathBounds = r;
            driver.lastPathRadius = pathRadius;
        }
        driver.shape.lineWidth = lineWidth;      // 描边宽度 = 配置值（固定屏幕点）
        // 渐变层铺对角线边长的居中正方形（TXT beautify.25 三.2）：长方形一转
        // 就盖不住整框（.24 断段根因），正方形任意旋转角都完整覆盖，conic
        // 圆心=环心不变，超出部分由 ring.mask 描边裁掉
        // beautify.42：只对角线变化才更新渐变层 frame
        {
            CGFloat w = driver.ring.bounds.size.width;
            CGFloat h = driver.ring.bounds.size.height;
            CGFloat diag = (CGFloat)sqrt((double)w * w + (double)h * h) + 2.0;
            if (fabs(diag - driver.lastGradientDiag) > 0.5) {
                driver.gradient.frame = CGRectMake((w - diag) / 2.0, (h - diag) / 2.0, diag, diag);
                driver.lastGradientDiag = diag;
            }
        }
        [CATransaction commit];

        // 光晕：与描边同帧、同一 presentation 矩形与圆角；不摘层、不停 link
        axs_ring_applyGlow(driver, bounds, (CGFloat)pathRadius, glowRange, (CGFloat)lineWidth);

        driver.lastBounds = bounds;
        driver.lastRadius = radius;
        driver.lastLineWidth = (CGFloat)lineWidth;
        driver.lastGlowEnabled = glowOn;
        driver.lastGlowRange = glowRange;
        driver.lastGlowBrightness = glowBright;
    } @catch (NSException *exception) {
        axs_ring_log(@"ring sync exception: %@", exception);
    }
}

// displayLink 路径：presentation 优先（TXT beautify.22 三.1）
static void axs_ring_syncDriver(AXSRingLinkDriver *driver) {
    axs_ring_syncDriver2(driver, NO);
}

// --- beautify.44：侧贴小窗 2D 侧倾（rotation.z only，无 3D 透视/缩放/位移） -----
// beautify.45 修复目标层探测（指令 二.3/三.4/四.11）：
// 真机 ScreenCore 二进制里只有 SCFloatingContainerView（内容本体）与
// SCFloatingInteractionOverlayView（手势层）两个 SC 宿主类；指令列举的
// SCFloatingHostWindow / SCFloatingRootViewController / SCFloatingHostRootView
// 在包内并不存在，不能硬编码类名去找（必然找不到 → found=nil → 永不倾斜）。
// 新策略不依赖类名猜测：
//   1) 找到手势 overlay 实例（SCFloatingInteractionOverlayView）；
//   2) 从 container 沿 superview 链向上找同时包含「内容 container + 手势 overlay」
//      的最近公共祖先 UIView（它必然也在装饰层之上，三者一起旋转）；
//   3) 该祖先必须非裁剪（自身 layer.masksToBounds=0），否则旋转会被父层裁掉；
//      被裁剪则继续向上找更外层安全祖先，直到 window/rootVC.view 前为止；
//   4) 找不到安全公共祖先就记日志放弃，绝不挂到裁剪层或宿主 window。
// 完整宿主链路（每层类名/frame/bounds/transform/anchorPoint/clips）写入探针日志。
// --- beautify.71：透视矩阵 concat 顺序修正（真正的"没有倾斜"根因）------------
// sc-ring(36).log + 参照视频铁证：.64 每帧 want==curNow（m13=0.26892 m31=-0.2689
// m34=-0.00167），但 corners 四角恒为正矩形，截图/视频里小窗也没有近大远小。
// 根因：.62~.64 把 m34 直接写进 rotationY 矩阵得到 R·P，对 z=0 的被变换平面
//   透视除法 w≡1，m34 完全失效，只剩 cos(rad) 水平缩放。用户参照图的 3D 梯形
//   需要 M=P·R（CATransform3DConcat(perspective, rotationY)）。.65 只改这一处；
//   角度/GAIN/m34 常量/sideSign/宿主选择/全部安全机制不变。
// --- beautify.62：恢复 3D 卡片侧翻（绕 Y 轴 rotationY + m34），用户确认要近大远小效果 ----
// .61 的 2D 平面歪斜（rotation.z）被用户否："角度不对，只是往左旋转了一点"。
// 用户要的是参考图/.51 那种卡片侧翻：近沿大、远沿小、朝中间倾倒。
// .62 恢复 rotationY + m34，并用 AXS_TILT_PERSPECTIVE_GAIN 把单层 6° 放大到有效 ~15.6°，
// 达到 .51 累积态的强透视（顶边 y 差 ~27px）但不逐帧累积。方向 sideSign=-1 不动。
// 以下 .47/.46 历史说明保留作追溯：
// .46 真机现象：黑色应用内容层单独做了 2D 旋转，外层白色 Dock 卡片背景/遮罩未跟随，
//   导致白边/三角露底；该问题由"单一本地 container 宿主"修复（背景内容同层跟随）。
// .47 修复（指令 四）：
//   - 视觉宿主改为能同时包住白色背景+黑色内容+装饰层的公共祖先（优先整卡容器
//     SCDockedFloatingItemView / 其安全非裁剪父级），三者一起进入 3D 变换；
//   - 变换由 CGAffineTransformMakeRotation(rotation.z) 升级为 CATransform3D：
//     rotationY = CATransform3DRotate(identity, sideSign*angleRad, 0,1,0)，
//     rotationY.m34 = -1/600 透视距离，竖边保持垂直、左右侧边轻微梯形；
//   - 复合 tilted3D = CATransform3DConcat(base3D, rotationY)，保留原生缩放/平移；
//     幂等基线对抗原生每帧写回；关闭/居中/角度0/离层恢复 base3D 而非 identity；
//   - 手势 overlay/边条/角区留在 identity 屏幕平面，不继承宿主 3D；命中区按透视后
//     四角屏幕坐标同步（只改 frame，不改 transform/alpha/userInteractionEnabled）；
//   - 角度范围 0..6、默认 3、旧 >6 夹紧；居中大窗不透视。
//   探针日志写 /var/mobile/Documents/sc-ring.log，完整字段见 axs_ring_applyTilt。

// 原生方法命中标记（hook 内设置，applyTilt 消费）：跨 driver 共享，命中后下一个
// displayLink 帧对所有 driver 重新采样 base。triggerName 记录是哪个原生方法触发。
static BOOL axs_ring_tiltGlobalRebase = NO;
static NSString *axs_ring_tiltTriggerName = @"displayLink";
static void axs_ring_noteNativeTrigger(NSString *name) {
    axs_ring_tiltGlobalRebase = YES;
    axs_ring_tiltTriggerName = (name.length > 0) ? [name copy] : @"nativeLayout";
}
static NSTimeInterval axs_ring_tiltApplyLogTime = 0;

// beautify.47：CATransform3D 幂等比较（浮点数精确相等，与 2D CGAffineTransformEqualTo 等价）。
static BOOL axs_ring_t3dEqual(CATransform3D a, CATransform3D b) {
    return CATransform3DEqualToTransform(a, b);
}

// beautify.59（指令 三.2）：矩阵是否「干净」——无插件透视分量（m13/m23/m31/m32/m34≈0），
// 仅允许原生 2D scale/translation。已带透视分量的矩阵禁止缓存为 nativeBase。
static BOOL axs_ring_tiltMatrixClean(CATransform3D t) {
    // beautify.61：2D 旋转分量 m12/m21 也视为"插件已写"，禁止缓存为 nativeBase，
    // 否则下一帧 Concat(nativeBase, tiltRotation) 会把旋转反复累积（.49 同类坑）。
    return fabs(t.m12) < 1e-4 && fabs(t.m21) < 1e-4
        && fabs(t.m13) < 1e-4 && fabs(t.m23) < 1e-4
        && fabs(t.m31) < 1e-4 && fabs(t.m32) < 1e-4
        && fabs(t.m34) < 1e-6;
}

// beautify.59（指令 三.8）：矩阵全分量有限（NaN/Inf 检查），SAFE_ABORT 用。
static BOOL axs_ring_tiltMatrixFinite(CATransform3D t) {
    CGFloat v[16] = { t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24,
                      t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44 };
    for (int i = 0; i < 16; i++) if (!isfinite(v[i])) return NO;
    return YES;
}

// beautify.59：复位只清插件 3D 透视分量（m13/m23/m31/m32/m34），保留当前
// 2D scale/translation——绝不把过期 cleanBase（如贴边缩放 0.3287）写回已变化
// 的原生布局（.57「小窗转浮窗时浮窗特别小」的根因：展开复位恢复了贴边缩放）。
static CATransform3D axs_ring_tiltStripPerspective(CATransform3D t) {
    // beautify.61：同时清 2D 旋转分量 m12/m21（rotation.z），保留原生 scale/translation。
    t.m12 = 0; t.m21 = 0;
    t.m13 = 0; t.m23 = 0; t.m31 = 0; t.m32 = 0; t.m34 = 0;
    return t;
}

// beautify.59（指令 五.1）：CORNER_CLIP 探针——从 container 子树找真正承载圆角的层
// （cornerRadius>0.5），跳过 overlay/远程场景根。返回圆角半径；0 表示未找到。
static CGFloat axs_ring_tiltProbeCornerRadius(UIView *container) {
    if (container == nil) return 0.0;
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:container];
        int guard = 0;
        while (stack.count > 0 && guard < 400) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            guard++;
            if (v == nil || axs_ring_isOverlayNode(v)) continue;
            NSString *cn = NSStringFromClass(v.class);
            if ([cn rangeOfString:@"_UIScene"].location != NSNotFound) continue;  // 远程场景根跳过
            CGFloat r = v.layer.cornerRadius;
            if (r > 0.5 && v.layer.bounds.size.width > 1) return r;
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    } @catch (NSException *e) { }
    return 0.0;
}

// 3D 宿主链的视图描述（frame/bounds/anchorPoint/clips + layer.transform3D），指令 五.4。
static NSString *axs_ring_nsView3D(UIView *v) {
    if (v == nil) return @"nil";
    CALayer *l = v.layer;
    return [NSString stringWithFormat:@"%@@%p frame=%@ bounds=%@ anchor=%.2f,%.2f clips=%d t3d=%@",
            NSStringFromClass(v.class), v,
            NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
            l.anchorPoint.x, l.anchorPoint.y, l.masksToBounds ? 1 : 0,
            axs_ring_nsTransform3D(l.transform)];
}

// beautify.59：完整层级探针（指令 四）。每层输出 11 项：
// 类名/地址、superview、frame/bounds/anchor、view.transform、layer.transform、
// layer.sublayerTransform、presentationLayer.transform、hidden/alpha/clips/mask、
// 子树是否含白色 backgroundEffectView、是否含内容 contentHostView/itemView、
// 是否含手势 overlay。栈式 DFS 避免递归 block 的 ARC 自捕获（-Werror）。
static BOOL axs_ring_subtreeHasClass(UIView *v, NSArray *names, NSString **hitName) {
    if (v == nil) return NO;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
    while (stack.count > 0) {
        UIView *x = [stack lastObject];
        [stack removeLastObject];
        NSString *cn = NSStringFromClass([x class]);
        for (NSString *n in names) {
            if ([cn rangeOfString:n].location != NSNotFound) {
                if (hitName != NULL) *hitName = cn;
                return YES;
            }
        }
        // 也检查 layer.name（ring/glow 挂载层靠 name 标识）
        if ([x.layer.name length] > 0) {
            for (NSString *n in names) {
                if ([x.layer.name rangeOfString:n].location != NSNotFound) {
                    if (hitName != NULL) *hitName = x.layer.name;
                    return YES;
                }
            }
        }
        [stack addObjectsFromArray:x.subviews];
    }
    return NO;
}

// ===== beautify.59：视觉分支分类（content/overlay/background/decor）=============
// 真机 sc-ring(21).log 铁证：黑色应用内容在 _UIScenePresentationView（container 子树内、
// 但为 overlay 的兄弟分支）；SCFloatingInteractionOverlayView + 边条 + 角区是另一条分支。
// 通用 UIView 不能作为内容证据（.49 的 hostHasContent=1(-) 假阳性根因）。
static BOOL axs_ring_classNameContains(UIView *v, NSArray *fragments) {
    if (v == nil) return NO;
    NSString *cn = NSStringFromClass([v class]);
    for (NSString *f in fragments) {
        if ([cn rangeOfString:f].location != NSNotFound) return YES;
    }
    return NO;
}
// OVERLAY 节点：手势 overlay、四条边条、四角区（含其直接 superview 链由调用方判定）。
static BOOL axs_ring_isOverlayNode(UIView *v) {
    return axs_ring_classNameContains(v, @[@"SCFloatingInteractionOverlayView",
                                           @"SCFloatingCornerGestureRegionView",
                                           @"SCFloatingEdgeGestureRegionView"]);
}
// 子树是否含 OVERLAY（含自身），nil-safe 栈式 DFS。
static BOOL axs_ring_subtreeHasOverlay(UIView *v) {
    return axs_ring_subtreeHasClass(v, @[@"SCFloatingInteractionOverlayView",
                                         @"SCFloatingCornerGestureRegionView",
                                         @"SCFloatingEdgeGestureRegionView"], NULL);
}
// 子树是否含真正的场景 CONTENT（严格类名，不含通用 UIView）。
static BOOL axs_ring_subtreeHasSceneContent(UIView *v) {
    return axs_ring_subtreeHasClass(v, @[@"_UIScenePresentationView",
                                         @"_UISceneLayerHostContainerView",
                                         @"_UITouchPassthroughView",
                                         @"_UIContextLayerHostView"], NULL);
}

static NSString *axs_ring_nsViewFull(UIView *v) {
    if (v == nil) return @"nil";
    CALayer *l = v.layer;
    CALayer *pres = l.presentationLayer;
    CATransform3D presT = (pres != nil) ? pres.transform : CATransform3DIdentity;
    NSString *maskDesc = l.mask != nil ? NSStringFromClass(l.mask.class) : @"none";
    NSString *bgHit = nil, *ctHit = nil, *ovHit = nil;
    BOOL hasBg = axs_ring_subtreeHasClass(v, @[@"backgroundEffectView", @"BackgroundEffectView", @"EffectView"], &bgHit);
    BOOL hasCt = axs_ring_subtreeHasClass(v, @[@"contentHostView", @"ContentHostView", @"itemView", @"ItemView"], &ctHit);
    BOOL hasOv = axs_ring_subtreeHasClass(v, @[@"InteractionOverlay", @"InteractionOverlayView"], &ovHit);
    return [NSString stringWithFormat:
            @"%@@%p super=%@ frame=%@ bounds=%@ anchor=%.2f,%.2f "
            @"viewT=%@ layerT=%@ subT=%@ presT=%@ "
            @"hidden=%d alpha=%.2f clips=%d mask=%@ "
            @"hasBG=%d(%@) hasContent=%d(%@) hasOverlay=%d(%@)",
            NSStringFromClass(v.class), v,
            v.superview ? NSStringFromClass(v.superview.class) : @"nil",
            NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
            l.anchorPoint.x, l.anchorPoint.y,
            axs_ring_nsTransform2D(v.transform),
            axs_ring_nsTransform3D(l.transform),
            axs_ring_nsTransform3D(l.sublayerTransform),
            axs_ring_nsTransform3D(presT),
            v.hidden ? 1 : 0, v.alpha, l.masksToBounds ? 1 : 0, maskDesc,
            hasBg ? 1 : 0, bgHit ?: @"-",
            hasCt ? 1 : 0, ctHit ?: @"-",
            hasOv ? 1 : 0, ovHit ?: @"-"];
}

// 从 root 向下递归打印完整可见层级（最多 depth 层、count 个节点，防爆炸）。
static void axs_ring_tiltDumpHierarchy(UIView *root, int maxDepth, int maxNodes) {
    @try {
        if (root == nil) return;
        NSMutableString *lines = [NSMutableString string];
        NSMutableArray *stack = [NSMutableArray arrayWithObjects:root, @0, nil]; // view, depth (NSNumber)
        int count = 0;
        while (stack.count >= 2 && count < maxNodes) {
            NSNumber *depthN = [stack lastObject]; [stack removeLastObject];
            UIView *v = [stack lastObject]; [stack removeLastObject];
            if (v == nil) continue;
            int depth = [depthN intValue];
            [lines appendFormat:@"\n    %@d%d %@", [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                                                       withString:@" " startingAtIndex:0],
             depth, axs_ring_nsViewFull(v)];
            count++;
            if (depth >= maxDepth) continue;
            // 逆序压栈以保持 subviews 原顺序
            for (UIView *sub in [v.subviews reverseObjectEnumerator]) {
                [stack addObject:sub];
                [stack addObject:@(depth + 1)];
            }
        }
        axs_ring_log(@"ring tilt HIERARCHY root=%@ nodes=%d%@",
                     axs_ring_nsDesc(root), count, lines);
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring tilt HIERARCHY", exception, root);
    }
}

// 把 view 的 bounds 四角经其 layer.transform(3D) 投影到 window 坐标（指令 五.10）。
// 用 CATransform3D 作用于相对 anchorPoint 的角点，再经 convertPoint 到 window；
// 全程 @try 由调用方包裹。返回 4 个点：左上/右上/左下/右下。
static void axs_ring_tiltProjectCorners(UIView *v, UIWindow *w, CGPoint out[4]) {
    CGRect b = v.bounds;
    CGPoint ap = v.layer.anchorPoint;
    CGPoint c = v.center;                 // position 在 superlayer 坐标系
    CGFloat lx = -ap.x * b.size.width;    // 相对 anchor 的左/上
    CGFloat rx = (1.0 - ap.x) * b.size.width;
    CGFloat ty = -ap.y * b.size.height;
    CGFloat by = (1.0 - ap.y) * b.size.height;
    CGPoint local[4] = {
        CGPointMake(lx, ty), CGPointMake(rx, ty),
        CGPointMake(lx, by), CGPointMake(rx, by)
    };
    CATransform3D t = v.layer.transform;
    for (int i = 0; i < 4; i++) {
        CGPoint p = local[i];
        // 行向量乘 3D 矩阵：x' = x*m11 + y*m21 + m41（m34 透视作用于 z=0 平面时引入 w）
        CGFloat x = p.x, y = p.y;
        CGFloat X = x * t.m11 + y * t.m21 + t.m41;
        CGFloat Y = x * t.m12 + y * t.m22 + t.m42;
        CGFloat W = x * t.m14 + y * t.m24 + t.m44;
        if (fabs(W) > 0.0001) { X /= W; Y /= W; }
        CGPoint inSuper = CGPointMake(c.x + X, c.y + Y);
        CGPoint inWindow = (v.superview != nil && w != nil)
                           ? [v.superview convertPoint:inSuper toView:w] : inSuper;
        out[i] = inWindow;
    }
}

// 投影四角的字符串描述（日志用）
static NSString *axs_ring_nsCorners(CGPoint p[4]) {
    return [NSString stringWithFormat:@"LT(%.1f,%.1f) RT(%.1f,%.1f) LB(%.1f,%.1f) RB(%.1f,%.1f)",
            p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y, p[3].x, p[3].y];
}

// 四角外接矩形（投影命中区 bbox，指令 五.10）
static CGRect axs_ring_tiltBBox(CGPoint p[4]) {
    CGFloat minX = MIN(MIN(p[0].x, p[1].x), MIN(p[2].x, p[3].x));
    CGFloat maxX = MAX(MAX(p[0].x, p[1].x), MAX(p[2].x, p[3].x));
    CGFloat minY = MIN(MIN(p[0].y, p[1].y), MIN(p[2].y, p[3].y));
    CGFloat maxY = MAX(MAX(p[0].y, p[1].y), MAX(p[2].y, p[3].y));
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

// 按投影后命中区同步 overlay.frame（指令 四.4/六.5）：只改 frame，不改 transform/
// alpha/mask/userInteractionEnabled；原生 frame 存 tiltHitOriginals 供恢复。
// 仅当 overlay 是纯平面层（不在 3D 宿主内）时更新；在宿主内时靠逆变换抵消，frame 交原生。
static void axs_ring_tiltSyncHitFrame(AXSRingLinkDriver *driver, BOOL shouldTilt,
                                      CGPoint proj[4], UIWindow *w) {
    UIView *ov = driver.tiltOverlayView;
    if (ov == nil || driver.tiltOverlayInHost) return;
    NSMutableDictionary *store = driver.tiltHitOriginals;
    if (store == nil) return;
    NSString *key = [NSString stringWithFormat:@"ov.frame.%p", ov];
    if (shouldTilt) {
        if ([store objectForKey:key] == nil) {
            [store setObject:[NSValue valueWithCGRect:ov.frame] forKey:key]; // 首次记录原生 frame
        }
        // beautify.59（指令 三.9）：投影角点 NaN/Inf 时保留上一次有效几何，跳过本次更新，
        // 绝不把 NaN 写进命中 frame / ring 渐变层（.23 的 CAGradientLayer NaN 根因）。
        BOOL cornersFinite = isfinite(proj[0].x) && isfinite(proj[0].y) && isfinite(proj[1].x)
                             && isfinite(proj[1].y) && isfinite(proj[2].x) && isfinite(proj[2].y)
                             && isfinite(proj[3].x) && isfinite(proj[3].y);
        if (!cornersFinite) return;
        CGRect winBBox = axs_ring_tiltBBox(proj);
        if (winBBox.size.width <= 0 || winBBox.size.height <= 0) return;
        if (!isfinite(winBBox.origin.x) || !isfinite(winBBox.origin.y)
            || !isfinite(winBBox.size.width) || !isfinite(winBBox.size.height)) return;
        CGRect inSuper = (w != nil && ov.superview != nil)
                         ? [w convertRect:winBBox toView:ov.superview] : winBBox;
        if (!CGRectEqualToRect(inSuper, ov.frame)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ov.frame = inSuper;                       // 命中区按投影 bbox 对齐（平面）
            [CATransaction commit];
        }
    } else {
        NSValue *orig = [store objectForKey:key];
        if (orig != nil) {
            CGRect r = [orig CGRectValue];
            if (!CGRectEqualToRect(r, ov.frame)) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                ov.frame = r;                         // 回原生命中区
                [CATransaction commit];
            }
            [store removeObjectForKey:key];
        }
    }
}

static UIView *axs_ring_findTiltOverlay(UIView *container) {
    if (container == nil) return nil;
    UIWindow *w = container.window;
    if (w == nil) return nil;
    Class overlayCls = objc_getClass("SCFloatingInteractionOverlayView");
    if (overlayCls == Nil) return nil;
    UIView *parent = container.superview;
    if (parent != nil) {
        for (UIView *sib in parent.subviews) {
            if (sib != container && [sib isKindOfClass:overlayCls]) return sib;
        }
    }
    // 栈式迭代找（不用递归 block，规避 ARC retain-cycle / 初始化自捕获 -Werror）
    UIView *found = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
    while (stack.count > 0) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        if (v != container && [v isKindOfClass:overlayCls]) { found = v; break; }
        [stack addObjectsFromArray:v.subviews];
    }
    return found;
}

// .46 原生链路探测：打印候选对象，返回宿主 UIView（原生 transform 写入层优先）。
// beautify.59：收集视觉宿主集合（指令 四）。返回 UIView* 数组（ autoreleased ）。
// 规则：从 container 子树找「含 CONTENT 或 BACKGROUND 可见本体、且子树与 overlaySet 不相交」
// 的最深层节点。content 分支与 background 分支为兄弟时各自作为一个宿主写同一透视矩阵；
// 绝不向上退到同时包住 overlay 的 container / hostWindow。
// 用「含 _UIScenePresentationView 等真实场景类」作为 CONTENT 证据，禁用通用 UIView。
// beautify.59（指令 三.4）：有效可见性——沿祖先链乘 alpha、查 hidden（含 window），
// 阈值 0.01。不可见时 reason 给出祖先链原因（INVISIBLE_SKIP）。
static BOOL axs_ring_tiltEffectiveVisible(UIView *v, CGFloat *outAlpha, NSString **reason) {
    if (v == nil) { if (reason) *reason = @"nil"; return NO; }
    CGFloat alpha = 1.0;
    UIView *cur = v;
    int g = 0;
    while (cur != nil && g < 16) {
        alpha *= cur.alpha;
        if (cur.hidden) {
            if (reason) *reason = [NSString stringWithFormat:@"hidden@%@", NSStringFromClass(cur.class)];
            return NO;
        }
        if (cur.window == nil && cur != v && [cur isKindOfClass:[UIWindow class]] == NO) {
            // 还没到 window 就断了：离层候选视为不可见
            if (reason) *reason = @"offWindow";
            return NO;
        }
        if ([cur isKindOfClass:[UIWindow class]]) break;
        cur = cur.superview; g++;
    }
    if (outAlpha) *outAlpha = alpha;
    if (alpha <= 0.01) {
        if (reason) *reason = [NSString stringWithFormat:@"effectiveAlpha=%.3f", alpha];
        return NO;
    }
    return YES;
}

// beautify.59 收集视觉宿主（指令 三/四）：扫描根升到 hostWindow，覆盖 rootView 下
// 并列的 SCDockedFloatingItemView 分支（真机贴边预览本体，.52 因只扫 container 子树
// 把矩阵写进了 alpha=0 的过渡分支）。候选先做有效可见性过滤（INVISIBLE_SKIP）：
// 第一优先 = 有效可见且不带手势的 SCDockedFloatingItemView（预览内容在其 layer 子层）；
// 第二优先 = container 子树的 CONTENT_WRAPPER/BACKGROUND_WRAPPER（同样需有效可见）。
// 两分支都不可见 → 返回空（本帧跳过透视，等下一个可见帧），禁止给隐藏分支写矩阵。
static NSArray *axs_ring_collectVisualHosts(UIView *container, NSMutableString *logOut) {
    NSMutableArray *hosts = [NSMutableArray array];
    if (container == nil) return hosts;
    @try {
        UIWindow *w = container.window;
        UIView *scanRoot = (w != nil) ? w : container;
        // beautify.59（指令 二.B.1）：贴边后可见 docked item 常被移到 DockManager 所在的
        // 其它窗口（.26 日志当前窗口树内 SCDockedFloatingItemView=0）——扫描根扩展为
        // connectedScenes 下全部 window（含当前 SCFloatingHostWindow），逐窗口扫描。
        NSMutableArray *scanRoots = [NSMutableArray array];
        if (w != nil) [scanRoots addObject:w];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                if (win != nil && ![scanRoots containsObject:win]) [scanRoots addObject:win];
            }
        }
        if ([scanRoots count] == 0) [scanRoots addObject:scanRoot];
        if (logOut != NULL) {
            [logOut appendFormat:@"\n  ALL_WINDOWS_PROBE windows=%lu:", (unsigned long)scanRoots.count];
            for (UIWindow *win in scanRoots) {
                [logOut appendFormat:@"\n    %@ rootVC=%@ hidden=%d key=%.0f",
                 axs_ring_nsDesc(win),
                 (win.rootViewController != nil) ? NSStringFromClass(win.rootViewController.class) : @"nil",
                 win.hidden ? 1 : 0, win.isKeyWindow ? 1.0 : 0.0];
            }
        }
        // 1) OVERLAY 分支整体收集（扫描根 = 全部窗口）
        NSMutableArray *overlayNodes = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray array];
        for (UIWindow *sroot in scanRoots) [stack addObject:sroot];
        int guard = 0;
        while (stack.count > 0 && guard < 900) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            guard++;
            if (axs_ring_isOverlayNode(v)) [overlayNodes addObject:v];
            [stack addObjectsFromArray:v.subviews];
        }
        if (logOut != NULL) {
            [logOut appendFormat:@"\n  overlaySet(%lu):", (unsigned long)overlayNodes.count];
            for (UIView *o in overlayNodes) [logOut appendFormat:@" %@", axs_ring_nsDesc(o)];
        }

        // 2) DOCK_MANAGER / DOCK_RECORD 探针（指令 二.B.2/.B.4）：全窗口收集 DockManager，
        //    ivar/属性 nil-safe 读取 itemViews/itemsContainerView/delegate 与 record 状态。
        NSMutableArray *dockManagers = [NSMutableArray array];
        for (UIWindow *sroot in scanRoots) {
            NSMutableArray *mstack = [NSMutableArray arrayWithObject:sroot];
            int mguard = 0;
            while (mstack.count > 0 && mguard < 300) {
                UIView *v = [mstack lastObject];
                [mstack removeLastObject];
                mguard++;
                if (v == nil) continue;
                NSString *cn = NSStringFromClass(v.class);
                if ([cn rangeOfString:@"DockManager"].location != NSNotFound
                    && ![dockManagers containsObject:v]) [dockManagers addObject:v];
                [mstack addObjectsFromArray:v.subviews];
            }
        }
        if (logOut != NULL && dockManagers.count > 0) {
            for (id dm in dockManagers) {
                id ivs = axs_ring_nsValue(dm, @"itemViews");
                id icv = axs_ring_nsValue(dm, @"itemsContainerView");
                id dlg = [dm respondsToSelector:@selector(delegate)] ? [(id)dm delegate] : nil;
                [logOut appendFormat:@"\n  DOCK_MANAGER_PROBE %@ itemViews=%@ itemsContainer=%@ delegate=%@",
                 axs_ring_nsDesc(dm), axs_ring_nsDesc(ivs), axs_ring_nsDesc(icv), axs_ring_nsDesc(dlg)];
                if ([ivs isKindOfClass:[NSArray class]]) {
                    for (id rec in (NSArray *)ivs) {
                        id sess = axs_ring_nsValue(rec, @"session");
                        id dv = axs_ring_nsValue(rec, @"dockSide");
                        id fv = axs_ring_nsValue(rec, @"frame");
                        id itv = axs_ring_nsValue(rec, @"itemView");
                        [logOut appendFormat:@"\n  DOCK_RECORD_PROBE %@ session=%@ dockSide=%@ frame=%@ itemView=%@",
                         axs_ring_nsDesc(rec), axs_ring_nsDesc(sess), axs_ring_nsDesc(dv),
                         axs_ring_nsDesc(fv), axs_ring_nsDesc(itv)];
                    }
                }
            }
        }

        // 2b) DOCKED_ITEM 候选（指令 四.1 第一优先）：全部窗口收集 SCDockedFloatingItemView。
        //     .55 修正：不再用 subtreeHasOverlay 一票否决（overlay 在独立窗口时误伤），
        //     改为精确排除 overlay 节点自身与其后代。
        NSMutableArray *dockedItems = [NSMutableArray array];
        for (UIWindow *sroot in scanRoots) {
            NSMutableArray *dstack = [NSMutableArray arrayWithObject:sroot];
            int dguard = 0;
            while (dstack.count > 0 && dguard < 600) {
                UIView *v = [dstack lastObject];
                [dstack removeLastObject];
                dguard++;
                if (v == nil) continue;
                if (!axs_ring_isOverlayNode(v)) {
                    NSString *cn = NSStringFromClass(v.class);
                    // beautify.59：前缀匹配防子类/改名（精确匹配在 .27 全窗口 0 命中）
                    if ([cn rangeOfString:@"DockedFloatingItem"].location != NSNotFound
                        && ![dockedItems containsObject:v]) [dockedItems addObject:v];
                } else {
                    continue;   // overlay 节点：其子树不可能是 docked item
                }
                [dstack addObjectsFromArray:v.subviews];
            }
        }
        // .64：贴边可见小窗本体（SCDockedFloatingItemView）优先于隐藏容器壳作宿主。
        //   sc-ring(35) 视图树铁证：docked=1 时真正显示的是 SCFloatingHostRootView 下的
        //   SCDockedFloatingItemView（frame=88x190.7, alpha=1, hasContent=1）；container 下
        //   两个 UIView 只是浮窗壳，写矩阵视觉零效果。tap 手势属于"内容本体"，不是边条/角区，
        //   允许该根直接做视觉宿主；SCFloatingInteractionOverlayView 仍绝不倾斜。
        BOOL hasDockedVisualHost = NO;
        for (UIView *di in dockedItems) {
            CGFloat ea = 0.0; NSString *reason = nil;
            BOOL visible = axs_ring_tiltEffectiveVisible(di, &ea, &reason);
            if (logOut != NULL) {
                [logOut appendFormat:@"\n  DOCKED_BRANCH_PROBE %@ frame=%@ effAlpha=%.3f visible=%d %@ gestureCount=%lu subviews=%lu sublayers=%lu",
                 axs_ring_nsDesc(di), NSStringFromCGRect(di.frame), ea, visible ? 1 : 0,
                 reason ?: @"-", (unsigned long)di.gestureRecognizers.count,
                 (unsigned long)di.subviews.count, (unsigned long)di.layer.sublayers.count];
            }
            // beautify.59（指令 九.4）：DOCKED_ITEM_PROBE——layer 子树里是否含 CALayerHost/
            // 图片层/背景层（贴边预览内容的真实承载位置）。
            if (logOut != NULL) {
                NSMutableArray *lstack = [NSMutableArray arrayWithObject:di.layer];
                int lguard = 0;
                BOOL hasLayerHost = NO, hasImageLayer = NO;
                long layerCount = 0;
                while (lstack.count > 0 && lguard < 200) {
                    CALayer *cl = [lstack lastObject]; [lstack removeLastObject];
                    lguard++;
                    if (cl == nil) continue;
                    layerCount++;
                    NSString *lcn = NSStringFromClass(cl.class);
                    if ([lcn rangeOfString:@"CALayerHost"].location != NSNotFound) hasLayerHost = YES;
                    if ([lcn rangeOfString:@"Image"].location != NSNotFound) hasImageLayer = YES;
                    [lstack addObjectsFromArray:cl.sublayers];
                }
                [logOut appendFormat:@"\n  DOCKED_ITEM_PROBE %@ layerNodes=%ld hasCALayerHost=%d hasImageLayer=%d gestures=%lu",
                 axs_ring_nsDesc(di), layerCount, hasLayerHost ? 1 : 0, hasImageLayer ? 1 : 0,
                 (unsigned long)di.gestureRecognizers.count];
            }
            if (!visible) {
                if (logOut != NULL) [logOut appendFormat:@"\n    INVISIBLE_SKIP %@", reason ?: @"-"];
                continue;
            }
            // LAYER_TREE_PROBE（指令 三.1）：宿主 layer 子树必须承载可见内容层。
            // .64：内容校验对所有贴边候选生效（原来只在无手势分支做，tap 根被直接漏掉）。
            NSMutableArray *lt = [NSMutableArray arrayWithObject:di.layer];
            int ltg = 0;
            BOOL hasContentLayer = NO;
            long lcount = 0;
            while (lt.count > 0 && ltg < 200) {
                CALayer *cl = [lt lastObject]; [lt removeLastObject];
                ltg++;
                if (cl == nil) continue;
                lcount++;
                NSString *lcn = NSStringFromClass(cl.class);
                if ([lcn rangeOfString:@"CALayerHost"].location != NSNotFound
                    || [lcn rangeOfString:@"Image"].location != NSNotFound
                    || [lcn rangeOfString:@"ContentHost"].location != NSNotFound
                    || cl.contents != nil) hasContentLayer = YES;
                [lt addObjectsFromArray:cl.sublayers];
            }
            if (logOut != NULL) [logOut appendFormat:@"\n  LAYER_TREE_PROBE %@ layerNodes=%ld hasContentLayer=%d",
                                 axs_ring_nsDesc(di), lcount, hasContentLayer ? 1 : 0];
            if (!hasContentLayer && lcount > 0) {
                if (logOut != NULL) [logOut appendFormat:@"\n    LAYER_TREE_MISSING_CONTENT (rejected as host)"];
                continue;
            }
            NSString *diCN = NSStringFromClass(di.class);
            BOOL isDockedVisual = ([diCN rangeOfString:@"DockedFloatingItem"].location != NSNotFound)
                                  && !axs_ring_subtreeHasOverlay(di);
            if (di.gestureRecognizers.count == 0 || isDockedVisual) {
                if (![hosts containsObject:di]) [hosts addObject:di];
                if (isDockedVisual) hasDockedVisualHost = YES;
                if (logOut != NULL) {
                    [logOut appendFormat:@"\n    HOST_CLASSIFY DOCKED_ITEM role=host%@",
                     isDockedVisual ? @" (visible docked preview)" : @""];
                    [logOut appendFormat:@"\n    DOCKED_ITEM_HOST (gesture-free, content in sublayers)%@",
                     isDockedVisual ? @" [.64 visual root]" : @""];
                    if (di.gestureRecognizers.count > 0 && isDockedVisual) {
                        [logOut appendFormat:@"\n    DOCKED_ITEM_TAP_ROOT_VISUAL_HOST gestures=%lu (tap root is the visible window; overlay stays planar)",
                         (unsigned long)di.gestureRecognizers.count];
                    }
                }
            } else {
                // 带手势（指令 四.3）：禁止倾斜交互根，选其子级有效可见、非手势的最大本地分支
                UIView *bestSub = nil; CGFloat bestArea = 0.0;
                for (UIView *sub in di.subviews) {
                    if (axs_ring_isOverlayNode(sub) || sub.gestureRecognizers.count > 0) continue;
                    CGFloat sa = 0.0; NSString *sr = nil;
                    if (!axs_ring_tiltEffectiveVisible(sub, &sa, &sr)) {
                        if (logOut != NULL) [logOut appendFormat:@"\n    INVISIBLE_SKIP sub %@ %@", axs_ring_nsDesc(sub), sr ?: @"-"];
                        continue;
                    }
                    CGFloat area = sub.frame.size.width * sub.frame.size.height;
                    if (area > bestArea) { bestArea = area; bestSub = sub; }
                }
                if (bestSub != nil) {
                    if (![hosts containsObject:bestSub]) [hosts addObject:bestSub];
                    if (logOut != NULL) [logOut appendFormat:@"\n    DOCKED_ITEM_SUB_HOST (gesture root protected) %@", axs_ring_nsDesc(bestSub)];
                } else if (logOut != NULL) {
                    [logOut appendFormat:@"\n    DOCKED_ITEM skipped: gesture root without safe local sub-branch"];
                }
            }
        }

        // 独立收集 sceneRoots（不限 hosts.count 状态，翻转/稳态都探）
        NSMutableArray *sceneRootsCollected = [NSMutableArray array];
        for (UIWindow *sroot in scanRoots) {
            NSMutableArray *scstack = [NSMutableArray arrayWithObject:sroot];
            int scg = 0;
            while (scstack.count > 0 && scg < 600) {
                UIView *v = [scstack lastObject];
                [scstack removeLastObject];
                scg++;
                if (v == nil || axs_ring_isOverlayNode(v)) continue;
                NSString *cn = NSStringFromClass(v.class);
                if ([cn rangeOfString:@"_UIScenePresentationView"].location != NSNotFound
                    && ![sceneRootsCollected containsObject:v]) [sceneRootsCollected addObject:v];
                [scstack addObjectsFromArray:v.subviews];
            }
        }

        // beautify.60 修复：远程 sceneRoot 不再作为宿主。
        // .31 真机铁证：写 _UIScenePresentationView.sublayerTransform 后 want 明明带旋转
        // （m13=0.1045 m31=-0.1045），但四角投影 LT(0,0) RT(430,0) LB(0,932) RB(430,932)
        // 纹丝不动、截图小窗仍是正矩形——远程场景根的变换被系统每帧吞掉，视觉零效果。
        // 回归 .52 用户认可的本地容器 layer.transform 路径。
        for (UIView *sr in sceneRootsCollected) {
            if (logOut != NULL) [logOut appendFormat:@"\n    SCENE_HOST_PROBE %@ role=probe-only (not a tilt host)", axs_ring_nsDesc(sr)];
        }

        // 2c) beautify.71：恢复 .51/.52 用户认可的「container 下可见包装层」作宿主。
        //     真机 sc-ring(34) 铁证：.62 把矩阵写进 container 自身（m13=0.088 m31=-0.269
        //     m34=-0.00167，want==curNow），但 corners 顶边 y 恒 40.0/40.0、截图仍是正矩形；
        //     因为 container 的 transform 被原生 dock scale(0.3287) 动画管线每帧吞掉。
        //     .51 认可版 hosts=3，写的是 container 直接子级 UIView（BACKGROUND_WRAPPER /
        //     hostView），want 累到 m13=-0.41 m34=-0.0065，才有顶边 y 差 27px 的强侧翻。
        //     .60 引入的 [hosts removeAllObjects]+只留 container Treatment 是 .60/.61/.62
        //     连续三版「没角度」的根因，这次删除。仅收集可见、承载内容、无 overlay、
        //     无手势的本地包装层（.52 安全约束），container 自身不再叠加。
        //     .66：撤销 .64 的 hasDockedVisualHost 抢占——sc-ring(37) 视图树铁证：
        //     SCDockedFloatingItemView 子树仅 6.5×6.5 角标、根本不画计算器画面；真正画面在
        //     container 下含 _UIScenePresentationView 的 UIView 包装层（0x812bd7b30）。
        //     .64 让空壳抢宿主 + LOCAL_WRAPPER_SKIPPED 是错误方向，与 .65 正确矩阵从未同时生效。
        //     改为无条件收集 localWrappers，与 .65 的正确 R·P 透视矩阵首次同时生效。
        {
            NSMutableArray *localWrappers = [NSMutableArray array];
            for (UIView *sub in container.subviews) {
                if (axs_ring_isOverlayNode(sub)) continue;
                if (axs_ring_subtreeHasOverlay(sub)) continue;
                // 注意：不能用 subtreeHasSceneContent 排除——container 直接子级 UIView 的子树
                // 本就含 _UIScenePresentationView（远程内容），写这个父层才能带动内容一起侧翻
                // （.51 认可实证）。只排除「自身就是 scene 根」的情况。
                NSString *subCN = NSStringFromClass(sub.class);
                if ([subCN rangeOfString:@"_UIScenePresentationView"].location != NSNotFound) continue;
                if ([subCN rangeOfString:@"_UISceneLayerHostContainerView"].location != NSNotFound) continue;
                if (sub.gestureRecognizers.count > 0) continue;       // 手势层保持平面
                if (CGRectIsEmpty(sub.frame) && sub.layer.sublayers.count == 0) continue;
                if (sub.layer.name != nil && [sub.layer.name rangeOfString:@"axsRing"].location != NSNotFound) continue;
                CGFloat ea = 0.0; NSString *wr = nil;
                if (!axs_ring_tiltEffectiveVisible(sub, &ea, &wr)) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    INVISIBLE_SKIP LOCAL_WRAPPER %@ %@", axs_ring_nsDesc(sub), wr ?: @"-"];
                    continue;
                }
                if (![localWrappers containsObject:sub]) [localWrappers addObject:sub];
                if (logOut != NULL) [logOut appendFormat:@"\n    HOST_CLASSIFY LOCAL_WRAPPER role=host\n    CONTAINER_SUB_HOST %@", axs_ring_nsDesc(sub)];
            }
            if (localWrappers.count > 0) {
                [hosts removeAllObjects];
                [hosts addObjectsFromArray:localWrappers];
                if (logOut != NULL) [logOut appendFormat:@"\n    LOCAL_WRAPPER_HOSTS_RESTORED count=%lu (real picture layer, .66)",
                                     (unsigned long)localWrappers.count];
            } else if (logOut != NULL) {
                [logOut appendFormat:@"\n    NO_LOCAL_WRAPPER container=%@ (fallback keep existing hosts)", axs_ring_nsDesc(container)];
            }
            // .66：保留 .64 的选择日志串（CI 校验依赖），但 docked 空壳不再抢占真画面宿主。
            if (hasDockedVisualHost && logOut != NULL) {
                [logOut appendFormat:@"\n    LOCAL_WRAPPER_SKIPPED (docked visual host present but empty shell; wrappers win in .66)"];
            }
        }

        // 3) 兜底参考（不再作为透视宿主——.28 证明 wrapper 变换被原生管线吞掉）：
        //    仅打印 CONTENT_WRAPPER / BACKGROUND_WRAPPER 探针供层级证据。
        if (hosts.count == 0) {
            // 3a) CONTENT_WRAPPER：sceneRoot 上方爬到 container 直接子级（.52 逻辑）+ effVis 过滤
            NSMutableArray *sceneRoots = [NSMutableArray array];
            NSMutableArray *wrappers = [NSMutableArray array];
            // beautify.59（指令 二）：候选元组统一为插件私有字典（axsNode 键），
            // 初始压栈必须是字典而非裸视图（.53 每帧 hosts=0 的根因：裸 container
            // 被当字典取 @"v" → objectForKeyedSubscript: unrecognized selector）。
            stack = [NSMutableArray arrayWithObject:@{@"axsNode": container}];
            guard = 0;
            while (stack.count > 0 && guard < 400) {
                id it = [stack lastObject];
                [stack removeLastObject];
                guard++;
                if (![it isKindOfClass:[NSDictionary class]]) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    METADATA_TYPE_SKIP node=%@ reason=not-dictionary actualClass=%@",
                                         axs_ring_nsDesc(it), NSStringFromClass([(NSObject *)it class])];
                    continue;
                }
                UIView *v = it[@"axsNode"];
                if (![v isKindOfClass:[UIView class]]) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    METADATA_TYPE_SKIP node=%@ reason=not-view", it];
                    continue;
                }
                @try {
                    if (axs_ring_isOverlayNode(v)) continue;
                    NSString *cn = NSStringFromClass(v.class);
                    if ([cn rangeOfString:@"_UIScenePresentationView"].location != NSNotFound
                        && ![sceneRoots containsObject:v]) [sceneRoots addObject:v];
                    for (UIView *sub in v.subviews) {
                        if (axs_ring_isOverlayNode(sub)) continue;
                        [stack addObject:@{@"axsNode": sub}];
                    }
                } @catch (NSException *ne) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    COLLECT_NODE_EXCEPTION node=%@ selector=subviews/%@ desc=%@",
                                         axs_ring_nsDesc(v), NSStringFromClass(v.class), ne];
                }
            }
            for (UIView *sr in sceneRoots) {
                if (logOut != NULL) [logOut appendFormat:@"\n    HOST_CLASSIFY REMOTE_SCENE role=banned\n    REMOTE_SCENE_ROOT (banned as tilt host) %@", axs_ring_nsDesc(sr)];
                UIView *wp = sr.superview;
                int g2 = 0;
                while (wp != nil && wp != container && wp.superview != container && g2 < 8) {
                    if (axs_ring_isOverlayNode(wp)) { wp = nil; break; }
                    wp = wp.superview; g2++;
                }
                if (wp != nil && wp != container && wp.superview == container
                    && !axs_ring_subtreeHasOverlay(wp) && ![wrappers containsObject:wp]) {
                    [wrappers addObject:wp];
                }
            }
            for (UIView *wp in wrappers) {
                CGFloat ea = 0.0; NSString *reason = nil;
                if (!axs_ring_tiltEffectiveVisible(wp, &ea, &reason)) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    INVISIBLE_SKIP CONTENT_WRAPPER %@ %@", axs_ring_nsDesc(wp), reason ?: @"-"];
                    continue;
                }
                if (![hosts containsObject:wp]) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    HOST_CLASSIFY CONTENT_LOCAL role=probe-only\n    CONTENT_WRAPPER %@", axs_ring_nsDesc(wp)];
                }
            }
            // 3b) BACKGROUND_WRAPPER：container 直接子级、不含 overlay/scene、z 序在内容包装之下
            for (UIView *sub in container.subviews) {
                if (axs_ring_isOverlayNode(sub)) continue;
                if (axs_ring_subtreeHasOverlay(sub)) continue;
                if (axs_ring_subtreeHasSceneContent(sub)) continue;
                BOOL isWrapper = NO;
                for (UIView *wp in wrappers) { if (sub == wp || [wp isDescendantOfView:sub]) isWrapper = YES; }
                if (isWrapper) continue;
                if (CGRectIsEmpty(sub.frame) && sub.layer.sublayers.count == 0) continue;
                if (sub.layer.name != nil && [sub.layer.name rangeOfString:@"axsRing"].location != NSNotFound) continue;
                CGFloat ea = 0.0; NSString *reason = nil;
                if (!axs_ring_tiltEffectiveVisible(sub, &ea, &reason)) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    INVISIBLE_SKIP BACKGROUND_WRAPPER %@ %@", axs_ring_nsDesc(sub), reason ?: @"-"];
                    continue;
                }
                NSUInteger bgIdx = [container.subviews indexOfObject:sub];
                NSUInteger cwIdx = wrappers.count > 0 ? [container.subviews indexOfObject:wrappers[0]] : NSNotFound;
                if (cwIdx != NSNotFound && bgIdx != NSNotFound && bgIdx > cwIdx) continue;
                if (![hosts containsObject:sub]) {
                    if (logOut != NULL) [logOut appendFormat:@"\n    HOST_CLASSIFY BACKGROUND_LOCAL role=probe-only\n    BACKGROUND_WRAPPER %@", axs_ring_nsDesc(sub)];
                }
                break;
            }
        }

        if (logOut != NULL) {
            [logOut appendFormat:@"\n  VISIBLE_BRANCH chosen(%lu):", (unsigned long)hosts.count];
            for (UIView *h in hosts) [logOut appendFormat:@" %@", axs_ring_nsDesc(h)];
            if (hosts.count == 0) [logOut appendFormat:@" (none visible this frame — skip tilt)"];
        }
    } @catch (NSException *e) {
        if (logOut != NULL) [logOut appendFormat:@"\n  collect exception=%@", e];
    }
    return hosts;
}


// 施加/恢复某 driver 的侧倾。核心：tilted = Concat(base, rotation)，base 为原生快照。
// 命中区（overlay/边条/角区）状态描述（指令 五.9）：superview transform / 自身 transform /
// frame / bounds / userInteractionEnabled / 手势 enabled。手势视图不进 3D 宿主，保持身份平面。
static NSString *axs_ring_nsHitRegion(UIView *v) {
    if (v == nil) return @"nil";
    NSString *ges = @"none";
    NSArray *grs = v.gestureRecognizers;
    if (grs.count > 0) {
        NSMutableArray *states = [NSMutableArray array];
        for (UIGestureRecognizer *g in grs) [states addObject:(g.enabled ? @"on" : @"off")];
        ges = [states componentsJoinedByString:@","];
    }
    return [NSString stringWithFormat:@"%@@%p superview=%@ superT3d=%@ selfT3d=%@ frame=%@ bounds=%@ userInt=%d ges=%@",
            NSStringFromClass(v.class), v,
            v.superview ? NSStringFromClass(v.superview.class) : @"nil",
            axs_ring_nsTransform3D(v.superview.layer.transform),
            axs_ring_nsTransform3D(v.layer.transform),
            NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
            v.userInteractionEnabled ? 1 : 0, ges];
}

// 收集手势命中区视图：overlay 自身 + 其子树中的边条/角区（SCFloatingCornerGestureRegionView
// 等类名含 Corner/Edge/Region/Gesture 的 UIView），用于日志与投影命中区同步（指令 四.4/五.9）。
static void axs_ring_tiltCollectHitRegions(UIView *root, NSMutableArray *out, int depth) {
    if (root == nil || depth > 6 || out.count >= 32) return;
    NSString *cn = NSStringFromClass(root.class);
    BOOL isRegion = ([cn rangeOfString:@"Corner"].location != NSNotFound)
                 || ([cn rangeOfString:@"Edge"].location != NSNotFound)
                 || ([cn rangeOfString:@"Region"].location != NSNotFound)
                 || ([cn rangeOfString:@"Gesture"].location != NSNotFound);
    if (isRegion && ![out containsObject:root]) [out addObject:root];
    for (UIView *sub in root.subviews) axs_ring_tiltCollectHitRegions(sub, out, depth + 1);
}

// beautify.71：全局阴影暂存表 + 活跃倾斜计数。per-driver 存储在 driver 重建时会
// 孤儿化（.68/.69 实测：宿主 0.24/60 原生阴影被清零后 driver 重建，永久丢失无法恢复）。
// 改为进程级：任意 driver 处于倾斜态时计数>0，计数归零（或 detach 对账）时统一恢复。
static NSMutableDictionary<NSString *, NSArray *> *axs_ring_tiltShadowSavedG = nil;
static int axs_ring_tiltShadowActiveCount = 0;

static void axs_ring_tiltShadowRestoreAll(void) {
    if (axs_ring_tiltShadowSavedG == nil || axs_ring_tiltShadowSavedG.count == 0) return;
    for (NSString *k in [axs_ring_tiltShadowSavedG copy]) {
        NSArray *pair = [axs_ring_tiltShadowSavedG objectForKey:k];
        if (pair.count != 2) continue;
        UIView *nd = pair[0];
        NSNumber *op = pair[1];
        if (nd == nil || nd.layer == nil) continue;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        nd.layer.shadowOpacity = [op floatValue];
        [CATransaction commit];
        axs_ring_log(@"ring tilt SHADOW_RESTORED %@ shadowOpacity=%.2f", axs_ring_nsDesc(nd), [op floatValue]);
    }
    [axs_ring_tiltShadowSavedG removeAllObjects];
}

// 施加/恢复某 driver 的 2D 平面歪斜（beautify.61：绕 Z 轴 rotation.z）。核心：
//   rad          = sideSign * side * angle * GAIN * M_PI/180     // GAIN 放大到有效 ~15.6°
//   tiltRotation = CATransform3DRotate(identity, rad, 0,1,0); tiltRotation.m34 = -1/600
//   want         = CATransform3DConcat(nativeBase, tiltRotation)  // 保留原生缩放/平移
// 手势 overlay 留在 identity 平面，命中区按投影后四角更新 frame（不改 transform/alpha/mask）。
static void axs_ring_applyTilt(AXSRingLinkDriver *driver) {
    @try {
        UIView *container = driver.container;
        if (container == nil) return;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        // 视觉宿主探测（节流 1s）：CONTENT/BACKGROUND 分支根，都不含 overlay。
        BOOL dockNow = axs_ring_containerIsDocked(container);
        BOOL dockFlipped = (dockNow != driver.lastDockSnap);
        if (dockFlipped) {
            driver.lastDockSnap = dockNow;
            // beautify.59（.27 日志结论）：贴边稳态时 SCFloatingHostWindow 被原生隐藏、
            // 可见贴边小窗由原生 Dock 通道渲染，而 docked item 只在贴边瞬间存在于树上
            // （.24 证实），首探 gate 从未抓到过。翻转瞬间强制重探 + 全窗口抓拍。
            driver.tiltVisualProbeTime = 0;   // 打破 1s 节流，本帧立即重探
            axs_ring_log(@"ring tilt DOCK_TRANSITION_SNAP: container=%@ docked=%d - forced re-probe + full-window snap",
                         axs_ring_nsDesc(container), dockNow ? 1 : 0);
            if (container.window != nil) {
                // 全窗口贴边瞬态抓拍：每个可见窗口的树摘要（找 Dock 渲染通道）
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                        if (win == nil || win.hidden) continue;
                        NSString *wcn = NSStringFromClass(win.class);
                        // 只抓嫌疑窗口：SC 系窗口 / 主屏 / 手势面板，避免 26 窗全量刷屏
                        if ([wcn hasPrefix:@"SC"] || [wcn isEqualToString:@"SBHomeScreenWindow"]
                            || [wcn rangeOfString:@"SGPanel"].location != NSNotFound) {
                            axs_ring_log(@"ring tilt SNAP WINDOW TREE %@ (docked=%d):", axs_ring_nsDesc(win), dockNow ? 1 : 0);
                            axs_ring_tiltDumpHierarchy(win, 14, 260);
                        }
                    }
                }
            }
        }
        BOOL needProbe = !driver.tiltVisualProbed
                         || (now - driver.tiltVisualProbeTime >= 1.0);
        if (needProbe) {
            NSMutableString *probeLog = [NSMutableString string];
            NSMutableArray *hosts = [NSMutableArray arrayWithArray:axs_ring_collectVisualHosts(container, probeLog)];
            // beautify.71：消除倾斜后露出的浅灰白"阴影"。sc-ring(38) 视图树铁证：
            //   container 下有 3 个同尺寸(267×580) d3 UIView，.66 只倾斜了含画面的两个，
            //   第三个全尺寸浅色背景壳没跟着倾斜，从梯形边缘露出 (236,236,233) 轮廓。
            //   补全：把所有与宿主同 bounds 尺寸、有效可见、非 overlay/手势/scene 根、
            //   尚未入选的 container 直接子 UIView 一并纳入 hosts，走同一套 nativeBase
            //   写入/复位/淘汰状态机，浅色壳随之一起侧翻，边缘不再露白。
            if (hosts.count > 0 && container != nil) {
                // .69：以 container.bounds 为"全尺寸"参照。旧逻辑取"最大宿主 bounds"，
                // 但宿主集合在 probe 间波动（不同分支宿主 bounds 不同，如 258×617），
                // 会导致兄弟层 1Hz 反复 add/drop 振荡（sc-ring(40) 实测）。container
                // bounds 与全尺寸兄弟层天然一致，判定稳定。
                CGRect refBounds = container.bounds;
                for (UIView *sib in container.subviews) {
                    if (sib == nil || [hosts containsObject:sib]) continue;
                    if (axs_ring_isOverlayNode(sib) || axs_ring_subtreeHasOverlay(sib)) continue;
                    NSString *scn = NSStringFromClass(sib.class);
                    if ([scn rangeOfString:@"_UIScenePresentationView"].location != NSNotFound
                        || [scn rangeOfString:@"_UISceneLayerHostContainerView"].location != NSNotFound) continue;
                    if (sib.layer.name != nil && [sib.layer.name rangeOfString:@"axsRing"].location != NSNotFound) continue;
                    // 只补全与宿主同尺寸的层：浅色背景壳全尺寸，6.5×6.5 角标被面积差排除
                    if (CGRectIsEmpty(sib.bounds) || fabs(sib.bounds.size.width - refBounds.size.width) > 1.0
                        || fabs(sib.bounds.size.height - refBounds.size.height) > 1.0) {
                        if (dockNow) axs_ring_log(@"ring tilt SHADOW_SIB_SIZE_SKIP %@ bounds=%@ ref=%@",
                                                  axs_ring_nsDesc(sib), NSStringFromCGRect(sib.bounds), NSStringFromCGRect(refBounds));
                        continue;
                    }
                    CGFloat sea = 0.0; NSString *sr = nil;
                    BOOL sibVisible = axs_ring_tiltEffectiveVisible(sib, &sea, &sr);
                    if (!sibVisible && dockNow && sr != nil
                        && [sr rangeOfString:@"SCFloating"].location != NSNotFound) {
                        // .68 关键修复：probe 采样瞬间 SCFloatingHostWindow 可能处于原生 hidden 态，
                        // 已入选宿主走"fallback keep existing"不再复查可见性，兄弟层却因同一
                        // 窗口 hidden 被拒——不对称导致 .67 补全从未命中（sc-ring(39) hosts 恒为 2）。
                        // 贴边稳态下与已入选宿主同窗，可见性随宿主，放行。
                        sibVisible = YES;
                        sr = [sr stringByAppendingString:@" (accepted: window-hidden docked steady, .71)"];
                    }
                    if (!sibVisible) {
                        if (dockNow) axs_ring_log(@"ring tilt SHADOW_SIB_SKIP %@ %@", axs_ring_nsDesc(sib), sr ?: @"-");
                        continue;
                    }
                    [hosts addObject:sib];
                    axs_ring_log(@"ring tilt SHADOW_SIB_ADDED %@ gest=%lu (full-size sibling follows tilt, .68)",
                                 axs_ring_nsDesc(sib), (unsigned long)sib.gestureRecognizers.count);
                }
            }
            // beautify.59/52：宿主集合变化时，被淘汰的旧宿主恢复 transform/clips/mask 并移除
            // 登记（指令 三.6 HOST_EVICTED），杜绝旧容器/旧 host 残留透视矩阵。
            for (UIView *oldH in driver.tiltVisualHosts) {
                if (oldH == nil || [hosts containsObject:oldH]) continue;
                NSString *okey = [NSString stringWithFormat:@"%p", oldH];
                // .64：必须恢复写倾斜前的完整 nativeBase。旧逻辑只清 m13/m31/m34，
                // 会把 rotationY 的 cos(15.6)=0.9632 留在 m11 当作原生缩放，逐轮累积缩小。
                NSValue *obaseVal = [driver.tiltVisualBase objectForKey:okey];
                CATransform3D oldRestore = (obaseVal != nil) ? [obaseVal CATransform3DValue]
                                                           : axs_ring_tiltStripPerspective(oldH.layer.transform);
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                oldH.layer.transform = oldRestore;
                oldH.layer.sublayerTransform = axs_ring_tiltStripPerspective(oldH.layer.sublayerTransform);
                NSNumber *ocv = [driver.tiltVisualClips objectForKey:okey];
                if (ocv != nil) oldH.clipsToBounds = [ocv boolValue];
                NSNumber *olv = [driver.tiltVisualClips objectForKey:[okey stringByAppendingString:@".layer"]];
                if (olv != nil) oldH.layer.masksToBounds = [olv boolValue];
                if ([driver.tiltVisualMask objectForKey:okey] != nil
                    && [oldH.layer.mask.name isEqualToString:@"AxsTiltCornerMask"]) {
                    oldH.layer.mask = nil;
                }
                [CATransaction commit];
                [driver.tiltVisualWrote removeObjectForKey:okey];
                [driver.tiltVisualBase removeObjectForKey:okey];
                [driver.tiltVisualNames removeObjectForKey:okey];
                [driver.tiltVisualClips removeObjectForKey:okey];
                [driver.tiltVisualClips removeObjectForKey:[okey stringByAppendingString:@".layer"]];
                [driver.tiltVisualMask removeObjectForKey:okey];
                [driver.tiltVisualCorner removeObjectForKey:okey];
                axs_ring_log(@"ring tilt HOST_EVICTED: %@ restored to native base",
                             axs_ring_nsDesc(oldH));
            }
            driver.tiltVisualHosts = hosts;
            driver.tiltVisualProbeTime = now;
            driver.tiltVisualProbed = YES;
            driver.tiltOverlayView = axs_ring_findTiltOverlay(container);
            if (!driver.loggedTiltChain) {
                driver.loggedTiltChain = YES;
                // 指令十：偏好双来源 + 侧贴多状态 + 完整 UIView 层级（三类关键诊断日志保留）
                axs_ring_tiltLogPreferenceSources();
                axs_ring_tiltLogDockState(container);
                if (container.window != nil) axs_ring_tiltDumpHierarchy(container.window, 12, 200);
                // 指令 十.6：overlay 自身平面状态 + 每个视觉宿主的 3D 描述
                NSMutableString *ovDesc = [NSMutableString string];
                UIView *ov0 = driver.tiltOverlayView;
                [ovDesc appendFormat:@" overlay=%@", axs_ring_nsHitRegion(ov0)];
                if (ov0 != nil) {
                    NSMutableArray *regs = [NSMutableArray array];
                    axs_ring_tiltCollectHitRegions(ov0, regs, 0);
                    for (UIView *r in regs) [ovDesc appendFormat:@"\n    region %@", axs_ring_nsHitRegion(r)];
                }
                for (UIView *h0 in hosts) [ovDesc appendFormat:@"\n    hostView %@", axs_ring_nsView3D(h0)];
                axs_ring_log(@"ring tilt VISUAL HOSTS (beautify.71): container=%@%@%@",
                             axs_ring_nsDesc(container), probeLog, ovDesc);
            }
        }
        NSArray *hosts = driver.tiltVisualHosts;

        BOOL tiltOn = axs_ring_tiltEnabled();
        BOOL docked = axs_ring_containerIsDocked(container);
        double angle = axs_ring_clamp(axs_ring_tiltAngle(), 0.0, AXS_TILT_ANGLE_MAX);
        int side = 0;
        double rad = 0.0;
        // 居中大窗 / 关闭 / 角度 0 → shouldTilt=NO，所有宿主回 nativeBase（清零透视）。
        BOOL shouldTilt = tiltOn && docked && angle > 0.0 && container.window != nil;
        if (shouldTilt) {
            side = axs_ring_containerDockSide(container);
            rad = AXS_TILT_SIDE_SIGN * side * angle * M_PI / 180.0;
        }
        // beautify.62：恢复 3D 卡片侧翻——绕 Y 轴 rotationY + m34 透视（用户否掉 .61 平面歪斜）。
        // 方向 sideSign=-1：右挂 side=1 → rad<0 → 左沿近/右沿收窄（朝中心），左挂相反。
        // 强度：rad 乘 AXS_TILT_PERSPECTIVE_GAIN，把滑块 6° 放大到有效 ~15.6°，
        //   复刻用户认可的 .51 强侧翻（顶边 y 差 ~27px），单层干净矩阵不逐帧累积。
        //   注意 GAIN 只作用于本帧 rad，nativeBase 仍是干净基线，cleanBase 状态机照旧防累积。
        if (shouldTilt) {
            rad = rad * AXS_TILT_PERSPECTIVE_GAIN;
        }
        CATransform3D tiltRotation = CATransform3DIdentity;
        if (shouldTilt) {
            // beautify.71（核心根因修复）：透视必须先于旋转复合，即 M = P · R。
            // .62~.64 用 CATransform3DRotate(identity,rad,0,1,0) 再直接写 .m34=-1/600，
            //   得到的是 R·P（旋转矩阵的第4行被塞 m34）。对被变换的 z=0 平面点，
            //   透视除法 w = 1 + z_input*m34 = 1（z_input 恒 0），m34 完全失效——
            //   四角只剩 m11=cos(rad)=0.963 的水平缩放，视觉上就是"正矩形、没有倾斜"。
            //   该错误从 .31 起被 corners 诊断掩盖：旧投影函数也只算 m11，读不到 m14。
            // 正确做法：把旋转矩阵右乘透视矩阵 R·P，展开后只需追加两个分量：
            //   M.m14 = sin(rad)/d = -sin(rad)*m34Const
            //   M.m34 = -cos(rad)/d = cos(rad)*m34Const
            // 这样对 z=0 的平面点 w' = 1 + x*M.m14，四角产生近大远小梯形
            //   （贴屏幕边更长、朝中间边更短），实测幅度 ~4%，与用户参照视频一致。
            // 显式写 m14/m34，不依赖 CATransform3DConcat 的复合顺序语义。
            tiltRotation = CATransform3DRotate(CATransform3DIdentity, (CGFloat)rad, 0.0, 1.0, 0.0);
            CGFloat sinRad = (CGFloat)sin(rad);
            CGFloat cosRad = (CGFloat)cos(rad);
            tiltRotation.m14 = -sinRad * AXS_TILT_M34;   // = sin(rad)/d
            tiltRotation.m34 =  cosRad * AXS_TILT_M34;   // = -cos(rad)/d
        }
        // beautify.71：原生 layer shadow 诊断 + 中性化（全局健壮版）。
        // sc-ring(41) 截图像素测量：灰色带沿倾斜后的梯形顶边平行延伸且带圆角——
        // 它是倾斜宿主自身的原生 layer shadow（sc-ring(40) PROBE：0.24/60/hasPath=1，
        // 随层倾斜所以与梯形平行）。.68 曾清零（当时看不到），.69 收窄中性化范围后
        // 灰带回归。修复：a) 中性化目标扩回 container/root/dockedItem/container 全部
        // 非 overlay 子层（含宿主）；b) 暂存表改进程级全局（driver 重建不再孤儿化）；
        // c) 全局活跃倾斜计数归零时统一恢复（多 driver 并存互不打架）。
        if (axs_ring_tiltShadowSavedG == nil) axs_ring_tiltShadowSavedG = [NSMutableDictionary dictionary];
        if (shouldTilt && !driver.tiltShadowWasActive) {
            axs_ring_tiltShadowActiveCount++;
            driver.tiltShadowWasActive = YES;
        } else if (!shouldTilt && driver.tiltShadowWasActive) {
            axs_ring_tiltShadowActiveCount--;
            driver.tiltShadowWasActive = NO;
        }
        {
            NSMutableArray *shadowNodes = [NSMutableArray array];   // 中性化目标
            NSMutableArray *probeNodes = [NSMutableArray array];    // 仅诊断
            if (container != nil && container.layer != nil) {
                [shadowNodes addObject:container];
                [probeNodes addObject:container];
                UIView *rv = container.superview;
                if (rv != nil) {
                    [shadowNodes addObject:rv];
                    [probeNodes addObject:rv];
                    for (UIView *rs in rv.subviews) {
                        NSString *rcn = NSStringFromClass(rs.class);
                        if ([rcn rangeOfString:@"SCDockedFloatingItemView"].location != NSNotFound) {
                            [shadowNodes addObject:rs];
                            [probeNodes addObject:rs];
                            break;
                        }
                    }
                }
                for (UIView *cs in container.subviews) {
                    if (axs_ring_isOverlayNode(cs)) continue;     // 手势层不处理
                    if (cs.layer == nil) continue;
                    [shadowNodes addObject:cs];                   // .70：含宿主——宿主原生阴影即灰带来源
                    [probeNodes addObject:cs];
                }
            }
            if (shouldTilt) {
                if (!driver.tiltShadowProbed) {
                    driver.tiltShadowProbed = YES;
                    for (UIView *nd in probeNodes) {
                        axs_ring_log(@"ring tilt SHADOW_PROBE %@ shadowOpacity=%.2f shadowRadius=%.1f hasPath=%d bg=%@ corner=%.1f",
                                     axs_ring_nsDesc(nd), nd.layer.shadowOpacity, nd.layer.shadowRadius,
                                     nd.layer.shadowPath != nil ? 1 : 0,
                                     nd.layer.backgroundColor != nil ? @"set" : @"nil",
                                     nd.layer.cornerRadius);
                    }
                }
                for (UIView *nd in shadowNodes) {
                    NSString *k = [NSString stringWithFormat:@"%p", nd];
                    if ([axs_ring_tiltShadowSavedG objectForKey:k] != nil) continue;
                    CGFloat so = nd.layer.shadowOpacity;
                    if (so > 0.001) {
                        [axs_ring_tiltShadowSavedG setObject:[NSArray arrayWithObjects:nd, [NSNumber numberWithFloat:so], nil] forKey:k];
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        nd.layer.shadowOpacity = 0.0;
                        [CATransaction commit];
                        axs_ring_log(@"ring tilt SHADOW_NEUTRALIZED %@ shadowOpacity=%.2f radius=%.1f",
                                     axs_ring_nsDesc(nd), so, nd.layer.shadowRadius);
                    }
                }
            } else if (axs_ring_tiltShadowActiveCount <= 0) {
                if (driver.tiltShadowProbed) driver.tiltShadowProbed = NO;
                axs_ring_tiltShadowRestoreAll();
            }
        }
        // beautify.71：光圈(ring)/光晕(glowInner/glowOuter)跟随倾斜——用户实测反馈
        // "光圈和光晕没有跟着倾斜"。三者经 findMount 挂在未倾斜的 container.layer 上，
        // 窗口内容倾斜成梯形后它们保持矩形：a) 视觉上光圈错位；b) 半透明光晕填充在
        // 梯形边缘与矩形光圈之间露出一条彩带，即用户从 .66 起持续反馈的"灰色阴影"
        // （跟窗移动、贴梯形边缘）。三层与宿主同处 container 坐标系、锚点同为窗口
        // 中心，直接施加同一 tiltRotation 即可精确贴合梯形；退出倾斜回 identity。
        {
            NSArray *decorLayers = [NSArray arrayWithObjects:driver.ring, driver.glowInner, driver.glowOuter, nil];
            for (CALayer *dl in decorLayers) {
                if (dl == nil || dl.superlayer == nil) continue;
                CATransform3D want = shouldTilt ? tiltRotation : CATransform3DIdentity;
                if (!axs_ring_t3dEqual(dl.transform, want)) {
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    dl.transform = want;
                    [CATransaction commit];
                }
            }
        }
        BOOL rotationChanged = !axs_ring_t3dEqual(tiltRotation, driver.lastRotation);
        BOOL forceRebase = axs_ring_tiltGlobalRebase || driver.tiltNeedRebase;

        // 对每个视觉宿主独立处理：nativeBase 只在首次写入透视前采样一次（key 带地址）。
        // 后续帧绝不把已叠加 tiltRotation 的矩阵当 nativeBase（.49 居中残留的根因）。
        BOOL anyWrote = NO;
        NSMutableString *hostLog = [NSMutableString string];
        UIView *firstHost = nil;
        // beautify.59（指令 二.A.3/4）：每帧写入前逐 host 重做存活+可见校验，
        // 过渡帧/隐藏帧/出树帧立即 STALE_HOST_EVICT（恢复 cleanBase、清缓存、移除登记），
        // 禁止沿用旧缓存对不可见分支继续写 tiltRotation（.26 hosts=2 写隐藏 wrapper 的根因）。
        NSMutableArray *staleEvict = [NSMutableArray array];
        for (UIView *h in hosts) {
            if (h == nil) { [staleEvict addObject:h ?: [NSNull null]]; continue; }
            NSString *evReason = nil;
            CGFloat evAlpha = 0.0;
            BOOL alive = (h.window != nil) && (h.superview != nil || h.layer.superlayer != nil)
                         && axs_ring_tiltEffectiveVisible(h, &evAlpha, &evReason);
            if (!alive) {
                NSString *skey = [NSString stringWithFormat:@"%p", h];
                NSValue *sbaseVal = [driver.tiltVisualBase objectForKey:skey];
                CATransform3D staleRestore = (sbaseVal != nil) ? [sbaseVal CATransform3DValue]
                                                             : axs_ring_tiltStripPerspective(h.layer.transform);
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                h.layer.transform = staleRestore;
                h.layer.sublayerTransform = axs_ring_tiltStripPerspective(h.layer.sublayerTransform);
                NSNumber *ocv = [driver.tiltVisualClips objectForKey:skey];
                if (ocv != nil) h.clipsToBounds = [ocv boolValue];
                NSNumber *olv = [driver.tiltVisualClips objectForKey:[skey stringByAppendingString:@".layer"]];
                if (olv != nil) h.layer.masksToBounds = [olv boolValue];
                if ([driver.tiltVisualMask objectForKey:skey] != nil
                    && [h.layer.mask.name isEqualToString:@"AxsTiltCornerMask"]) h.layer.mask = nil;
                [CATransaction commit];
                [driver.tiltVisualWrote removeObjectForKey:skey];
                [driver.tiltVisualBase removeObjectForKey:skey];
                [driver.tiltVisualNames removeObjectForKey:skey];
                [driver.tiltVisualClips removeObjectForKey:skey];
                [driver.tiltVisualClips removeObjectForKey:[skey stringByAppendingString:@".layer"]];
                [driver.tiltVisualMask removeObjectForKey:skey];
                [driver.tiltVisualCorner removeObjectForKey:skey];
                axs_ring_log(@"ring tilt STALE_HOST_EVICT host=%@ reason=%@ alpha=%.3f hidden=%d inTree=%d",
                             axs_ring_nsDesc(h), evReason ?: @"dead", evAlpha,
                             h.hidden ? 1 : 0, (h.window != nil) ? 1 : 0);
                [staleEvict addObject:h];
            }
        }
        if (staleEvict.count > 0) {
            NSMutableArray *kept = [NSMutableArray array];
            for (UIView *h in hosts) {
                if (h != nil && ![staleEvict containsObject:h]) [kept addObject:h];
            }
            driver.tiltVisualHosts = kept;
            hosts = kept;
        }
        for (UIView *h in hosts) {
            if (h == nil) continue;
            if (firstHost == nil) firstHost = h;
            // beautify.60：宿主恒为本地 container（单一），统一写 layer.transform。
            // .59 的 sublayerTransform/远程场景根路径视觉零效果，已彻底移除——
            // 无论类名如何，一律走本地 transform，杜绝写回远程根。
            BOOL hIsScene = NO;  // 保留变量避免大改 reset/分支；恒 NO = 只写 layer.transform
            NSString *key = [NSString stringWithFormat:@"%p", h];
            CATransform3D cur = h.layer.transform;
            NSValue *baseVal = [driver.tiltVisualBase objectForKey:key];
            NSValue *wroteVal = [driver.tiltVisualWrote objectForKey:key];
            CATransform3D nativeBase = (baseVal != nil) ? [baseVal CATransform3DValue] : cur;

            if (!shouldTilt) {
                // 复位：回 nativeBase（没有缓存则 identity），清零 m13/m31/m34；
                // beautify.59：恢复临时关闭的 clipsToBounds/masksToBounds。
                if (wroteVal != nil || forceRebase) {
                    // .64 关键修复：回到写倾斜前保存的完整 nativeBase。
                    // 只清 m13/m31/m34 会留下 rotationY 的 m11=cos(rad)=0.9632，
                    // 下一轮被当 cleanBase 再叠一次 -> 0.9277/0.8935/... 逐轮缩小浮窗。
                    CATransform3D restore = (baseVal != nil) ? nativeBase
                                                            : axs_ring_tiltStripPerspective(cur);
                    if (!axs_ring_t3dEqual(cur, restore)) {
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        if (hIsScene) h.layer.sublayerTransform = restore;
                        else h.layer.transform = restore;
                        [CATransaction commit];
                    }
                    NSNumber *clipsVal = [driver.tiltVisualClips objectForKey:key];
                    if (clipsVal != nil && !hIsScene) {
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        h.clipsToBounds = [clipsVal boolValue];
                        NSNumber *layerVal = [driver.tiltVisualClips objectForKey:[key stringByAppendingString:@".layer"]];
                        if (layerVal != nil) h.layer.masksToBounds = [layerVal boolValue];
                        [CATransaction commit];
                        [driver.tiltVisualClips removeObjectForKey:key];
                        [driver.tiltVisualClips removeObjectForKey:[key stringByAppendingString:@".layer"]];
                    }
                    // beautify.59：复位移除插件圆角 mask（指令 五.2 恢复原状）
                    if ([driver.tiltVisualMask objectForKey:key] != nil
                        && [h.layer.mask.name isEqualToString:@"AxsTiltCornerMask"]) {
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        h.layer.mask = nil;
                        [CATransaction commit];
                        [driver.tiltVisualMask removeObjectForKey:key];
                        [driver.tiltVisualCorner removeObjectForKey:key];
                    }
                    [driver.tiltVisualWrote removeObjectForKey:key];
                    anyWrote = YES;
                }
                [hostLog appendFormat:@"\n    host=%@(%@) restore=%@ cur=%@",
                 axs_ring_nsDesc(h), key, axs_ring_nsTransform3D(nativeBase), axs_ring_nsTransform3D(h.layer.transform)];
                continue;
            }

            // beautify.59（指令 三）：cleanBase 状态机——目标矩阵恒为 Concat(cleanBase, tiltRotation)，
            // 绝不在已倾斜矩阵上复合（.51 矩阵逐帧累积的根因：layoutSubviews 触发 forceRebase
            // 后把已带 m13/m31/m34 的 cur 当 nativeBase 再叠一次）。
            BOOL curIsOurs = (wroteVal != nil && axs_ring_t3dEqual(cur, [wroteVal CATransform3DValue]));
            BOOL curClean = axs_ring_tiltMatrixClean(cur);
            if (baseVal != nil) {
                nativeBase = [baseVal CATransform3DValue];
            } else if (curClean) {
                nativeBase = cur;
                [driver.tiltVisualBase setObject:[NSValue valueWithCATransform3D:nativeBase] forKey:key];
                [driver.tiltVisualNames setObject:NSStringFromClass(h.class) forKey:key];
                axs_ring_log(@"ring tilt BASE_CLEAN: host=%@ cleanBase=%@",
                             axs_ring_nsDesc(h), axs_ring_nsTransform3D(nativeBase));
            } else {
                // 污染且无 cleanBase（指令 三.3）：恢复 identity，本帧禁止叠加，BASE_PENDING。
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if (hIsScene) h.layer.sublayerTransform = CATransform3DIdentity;
                else h.layer.transform = CATransform3DIdentity;
                [CATransaction commit];
                [driver.tiltVisualWrote removeObjectForKey:key];
                [hostLog appendFormat:@"\n    host=%@ BASE_PENDING polluted=%@",
                 axs_ring_nsDesc(h), axs_ring_nsTransform3D(cur)];
                continue;
            }
            if (!curIsOurs && !curClean) {
                // BASE_STALE（指令 十.3）：cur 既不是我们写的也不干净——恢复 cleanBase 再计算。
                if (!axs_ring_t3dEqual(cur, nativeBase)) {
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    if (hIsScene) h.layer.sublayerTransform = nativeBase;
                    else h.layer.transform = nativeBase;
                    [CATransaction commit];
                    axs_ring_log(@"ring tilt BASE_STALE: host=%@ polluted=%@ restored=%@",
                                 axs_ring_nsDesc(h), axs_ring_nsTransform3D(cur), axs_ring_nsTransform3D(nativeBase));
                }
            } else if (!curIsOurs && curClean && !axs_ring_t3dEqual(cur, nativeBase)) {
                // 原生把 transform 重置为另一个干净值（原生 layout 时机）→ 重新捕获 cleanBase。
                nativeBase = cur;
                [driver.tiltVisualBase setObject:[NSValue valueWithCATransform3D:nativeBase] forKey:key];
                axs_ring_log(@"ring tilt BASE_CLEAN (recapture): host=%@ cleanBase=%@",
                             axs_ring_nsDesc(h), axs_ring_nsTransform3D(nativeBase));
            }
            CATransform3D want = CATransform3DConcat(nativeBase, tiltRotation);
            // SAFE_ABORT（指令 三.8）：NaN/Inf 或缩放退化 → 恢复 cleanBase 跳帧，绝不写异常矩阵。
            // beautify.60：阈值 0.15→0.02——.31 日志真机 container 原生 dock scale 仅
            // a=0.1238 d=0.0571，换回 container 宿主后 want.m11≈0.123/m22≈0.057 会被
            // 0.15 误判为退化而永久拦截（.58 曾把 0.35→0.15 修同类问题）。0.02 仍可拦截
            // 真正的几何退化（m11/m22≈0）与 NaN/Inf，但放行一切合法贴边缩放。
            if (!axs_ring_tiltMatrixFinite(want) || want.m11 < 0.02 || want.m22 < 0.02) {
                axs_ring_log(@"ring tilt SAFE_ABORT: host=%@ want=%@",
                             axs_ring_nsDesc(h), axs_ring_nsTransform3D(want));
                // .64：异常帧也回干净基线，不能把 cos(rad) 残留进 native 链路。
                CATransform3D safeRestore = (baseVal != nil) ? nativeBase
                                                            : axs_ring_tiltStripPerspective(cur);
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if (hIsScene) h.layer.sublayerTransform = safeRestore;
                else h.layer.transform = safeRestore;
                [CATransaction commit];
                [driver.tiltVisualWrote removeObjectForKey:key];
                continue;
            }
            BOOL needWrite = !axs_ring_t3dEqual(want, cur) || rotationChanged;
            if (needWrite) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if (hIsScene) {
                    // beautify.59：sublayerTransform 路径——宿主自身几何不动，
                    // 变换作用于内部子层（远程内容跟随透视）。
                    h.layer.sublayerTransform = want;
                } else {
                    h.layer.anchorPoint = CGPointMake(0.5, 0.5);
                    h.layer.transform = want;
                }
                // beautify.59/52（指令 五.2）：masksToBounds 关闭防 3D 溢出被裁平，圆角改由
                // 等价 CAShapeLayer mask 承载（mask 跟随 layer 一起透视，四角保持连续圆角）。
                // beautify.59：container 宿主例外——原圆角是原生视觉的一部分，禁止释放
                // （轻微透视溢出极小；释放会导致 .51 式尖角回归）。
                if (h != container && (h.clipsToBounds || h.layer.masksToBounds)) {
                    if ([driver.tiltVisualClips objectForKey:key] == nil) {
                        [driver.tiltVisualClips setObject:@(h.clipsToBounds ? 1 : 0) forKey:key];
                        [driver.tiltVisualClips setObject:@(h.layer.masksToBounds ? 1 : 0)
                                                   forKey:[key stringByAppendingString:@".layer"]];
                    }
                    if (h.clipsToBounds) h.clipsToBounds = NO;
                    h.layer.masksToBounds = NO;
                }
                if (h.layer.mask == nil && [driver.tiltVisualMask objectForKey:key] == nil) {
                    CGFloat radius = axs_ring_tiltProbeCornerRadius(container);
                    if (radius > 0.5) {
                        CAShapeLayer *cm = [CAShapeLayer layer];
                        cm.name = @"AxsTiltCornerMask";
                        cm.frame = h.layer.bounds;
                        CGPathRef p = CGPathCreateWithRoundedRect(h.layer.bounds, radius, radius, NULL);
                        cm.path = p;
                        CGPathRelease(p);
                        h.layer.mask = cm;
                        [driver.tiltVisualMask setObject:NSNull.null forKey:key];
                        [driver.tiltVisualCorner setObject:@(radius) forKey:key];
                        axs_ring_log(@"ring tilt CORNER_CLIP: host=%@ cornerRadius=%.2f mask=plugin",
                                     axs_ring_nsDesc(h), radius);
                    }
                } else if (h.layer.mask != nil
                           && [h.layer.mask.name isEqualToString:@"AxsTiltCornerMask"]) {
                    // 宿主 bounds 变化时同步插件 mask 路径（圆角随投影保持）
                    NSNumber *rVal = [driver.tiltVisualCorner objectForKey:key];
                    CGFloat radius = rVal != nil ? [rVal doubleValue] : 0.0;
                    if (radius > 0.5 && !CGRectEqualToRect(h.layer.mask.frame, h.layer.bounds)) {
                        h.layer.mask.frame = h.layer.bounds;
                        CGPathRef p = CGPathCreateWithRoundedRect(h.layer.bounds, radius, radius, NULL);
                        ((CAShapeLayer *)h.layer.mask).path = p;
                        CGPathRelease(p);
                    }
                }
                [CATransaction commit];
                [driver.tiltVisualWrote setObject:[NSValue valueWithCATransform3D:want] forKey:key];
                anyWrote = YES;
            }
            [hostLog appendFormat:@"\n    host=%@(%@) base=%@ want=%@ curNow=%@",
             axs_ring_nsDesc(h), key, axs_ring_nsTransform3D(nativeBase),
             axs_ring_nsTransform3D(want), axs_ring_nsTransform3D(h.layer.transform)];
        }
        driver.hasTilt = shouldTilt && anyWrote;
        driver.lastRotation = tiltRotation;
        if (forceRebase) {
            driver.tiltNeedRebase = NO;
        }

        // 手势 overlay：保持 identity，插件绝不写任何 3D/逆变换（指令 五.1）。
        // overlay 是 content 宿主的兄弟分支，本就不在宿主子树内，无需抵消。
        UIView *ov = driver.tiltOverlayView;
        BOOL overlayAncestorTilted = NO;
        if (ov != nil) {
            UIView *p = ov.superview;
            int g = 0;
            while (p != nil && g < 12) {
                for (UIView *h in hosts) {
                    if (p == h && !CATransform3DIsIdentity(h.layer.transform)) overlayAncestorTilted = YES;
                }
                p = p.superview; g++;
            }
        }
        // beautify.59 z-order 修正（指令 六.3）：3D 透视宿主的 zPosition/层级可能盖住手势区，
        // 每次写入后把 overlay 置顶并抬高 zPosition；边条/角区随 overlay 保持平面。
        if (shouldTilt && anyWrote && ov != nil) {
            @try {
                if (ov.superview != nil) [ov.superview bringSubviewToFront:ov];
                CGFloat maxHostZ = 0.0;
                for (UIView *h in hosts) {
                    if (h != nil && h.layer.zPosition > maxHostZ) maxHostZ = h.layer.zPosition;
                }
                if (ov.layer.zPosition <= maxHostZ) ov.layer.zPosition = maxHostZ + 100.0;
                if (!driver.loggedZOrder) {
                    driver.loggedZOrder = YES;
                    axs_ring_log(@"ring tilt ZORDER: overlay=%@ zPosition=%.1f maxHostZ=%.1f bringToFront=1",
                                 axs_ring_nsDesc(ov), ov.layer.zPosition, maxHostZ);
                }
            } @catch (NSException *e) {
                axs_ring_log(@"ring tilt zorder exception: %@", e);
            }
        }

        // 命中区按第一视觉宿主投影四角同步（只改 frame，overlay 自身保持平面）。
        UIWindow *w = container.window;
        CGPoint proj[4] = { CGPointZero, CGPointZero, CGPointZero, CGPointZero };
        NSString *cornersStr = @"n/a";
        if (w != nil && firstHost != nil) {
            @try {
                axs_ring_tiltProjectCorners(firstHost, w, proj);
                cornersStr = axs_ring_nsCorners(proj);
            } @catch (NSException *e) {
                cornersStr = @"project-exception";
            }
        }
        @try {
            axs_ring_tiltSyncHitFrame(driver, shouldTilt, proj, w);
        } @catch (NSException *e) {
            axs_ring_log(@"ring tilt hit-sync exception: %@", e);
        }

        // 3D 链路日志（1s 节流或状态变化强制）。
        BOOL forceLog = rotationChanged || forceRebase || (shouldTilt != driver.hasTilt);
        if (forceLog || now - axs_ring_tiltApplyLogTime >= 1.0) {
            axs_ring_tiltApplyLogTime = now;
            id del = [container respondsToSelector:@selector(delegate)] ? [(id)container delegate] : nil;
            NSString *nativeBaseDesc = axs_ring_tiltNativeBaseDesc(del != nil ? del : container);
            axs_ring_log(@"ring tilt 3D apply (beautify.71): enabled=%d docked=%d angle=%.1f "
                         @"side=%d sideSign=%.1f rad=%.4f gain=%.1f m34=%.6f container=%@ "
                         @"hosts=%lu overlayAncestorTilted=%d trigger=%@ nativeBase=%@ corners=%@%@",
                         tiltOn ? 1 : 0, docked ? 1 : 0, angle, side,
                         AXS_TILT_SIDE_SIGN, rad, AXS_TILT_PERSPECTIVE_GAIN,
                         tiltRotation.m34,
                         NSStringFromClass(container.class),
                         (unsigned long)hosts.count, overlayAncestorTilted ? 1 : 0,
                         axs_ring_tiltTriggerName, nativeBaseDesc, cornersStr, hostLog);
        }
        if (axs_ring_tiltGlobalRebase) {
            axs_ring_tiltGlobalRebase = NO;
            axs_ring_tiltTriggerName = @"displayLink";
        }
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring tilt apply", exception, driver.container);
    }
}

// detach/离层：恢复原生 base3D（不是 identity），绝不残留透视；overlay 回平面初始。
static void axs_ring_resetTilt(AXSRingLinkDriver *driver) {
    @try {
        UIView *ov = driver.tiltOverlayView;
        BOOL had = driver.hasTilt || driver.tiltVisualWrote.count > 0
                   || !CATransform3DIsIdentity(driver.lastOverlayTilt);
        if (!had) return;
        NSMutableString *resid = [NSMutableString string];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        // beautify.59：遍历所有视觉宿主恢复各自 nativeBase（key 带地址），清零 m13/m31/m34。
        for (UIView *h in driver.tiltVisualHosts) {
            if (h == nil) continue;
            NSString *key = [NSString stringWithFormat:@"%p", h];
            NSValue *baseVal = [driver.tiltVisualBase objectForKey:key];
            // .64：detach 也恢复完整 nativeBase；.59 的 strip 只清 3D 分量会留下 cos(rad) 缩放。
            CATransform3D restore = (baseVal != nil) ? [baseVal CATransform3DValue]
                                                    : axs_ring_tiltStripPerspective(h.layer.transform);
            h.layer.transform = restore;
            h.layer.sublayerTransform = axs_ring_tiltStripPerspective(h.layer.sublayerTransform);
            CATransform3D after = h.layer.transform;
            // beautify.59：恢复临时关闭的 clipsToBounds/masksToBounds（指令 六.6）
            NSNumber *clipsVal = [driver.tiltVisualClips objectForKey:key];
            if (clipsVal != nil) {
                h.clipsToBounds = [clipsVal boolValue];
                NSNumber *layerVal = [driver.tiltVisualClips objectForKey:[key stringByAppendingString:@".layer"]];
                if (layerVal != nil) h.layer.masksToBounds = [layerVal boolValue];
                [driver.tiltVisualClips removeObjectForKey:key];
                [driver.tiltVisualClips removeObjectForKey:[key stringByAppendingString:@".layer"]];
            }
            // beautify.59：复位移除插件圆角 mask（指令 五.2）
            if ([driver.tiltVisualMask objectForKey:key] != nil
                && [h.layer.mask.name isEqualToString:@"AxsTiltCornerMask"]) {
                h.layer.mask = nil;
                [driver.tiltVisualMask removeObjectForKey:key];
                [driver.tiltVisualCorner removeObjectForKey:key];
            }
            [resid appendFormat:@"\n    host=%@(%@) restore=%@ residual(m13=%.5f m31=%.5f m34=%.5f)",
             axs_ring_nsDesc(h), key, axs_ring_nsTransform3D(restore), after.m13, after.m31, after.m34];
        }
        if (ov != nil) ov.layer.transform = driver.overlayBaseTransform;  // overlay 平面初始
        [CATransaction commit];
        // 恢复命中区原生 frame（指令 五.11 无残留）
        if (ov != nil) {
            NSString *key = [NSString stringWithFormat:@"ov.frame.%p", ov];
            NSValue *orig = [driver.tiltHitOriginals objectForKey:key];
            if (orig != nil) {
                CGRect r = [orig CGRectValue];
                if (!CGRectEqualToRect(r, ov.frame)) {
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    ov.frame = r;
                    [CATransaction commit];
                }
                [driver.tiltHitOriginals removeObjectForKey:key];
            }
        }
        // 清空所有宿主的透视缓存，确保下次侧贴重新采样 nativeBase。
        [driver.tiltVisualWrote removeAllObjects];
        [driver.tiltVisualNames removeAllObjects];
        driver.lastOverlayTilt = driver.overlayBaseTransform;
        driver.lastRotation = CATransform3DIdentity;
        driver.hasTilt = NO;
        driver.tiltHasWrote = NO;
        driver.tiltVerifyPending = 0;
        driver.tiltLastWrote = CATransform3DIdentity;
        axs_ring_log(@"ring tilt 3D reset (beautify.71): hosts=%lu%@",
                     (unsigned long)driver.tiltVisualHosts.count, resid);
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring tilt reset", exception, driver.container);
    }
}

// --- attach / detach（成员扫描触发） ------------------------------------------

static void axs_ring_attachContainer(UIView *container) {
    NSString *key = [NSString stringWithFormat:@"%p", container];
    if (axs_ring_drivers[key] != nil) return;
    // beautify.42：挂载时刷新一次偏好快照（兜底；正常由 saved 通知驱动）
    axs_ring_refreshConfigSnapshot();
    // beautify.45：侧倾独立于美化开关——tilt 开启时即使光圈/光晕子开关都关，
    // 也要创建 driver（ring 层作为宿主仍在、只是 hidden），否则侧倾无机会生效
    // （指令 三.1：splitBeautifyDecorEnabled=NO 不影响侧倾）。
    if (!axs_ring_enabled() && !axs_ring_glowEnabled() && !axs_ring_tiltEnabled()) return;

    AXSRingLinkDriver *driver = [AXSRingLinkDriver new];
    driver.container = container;
    driver.overlay = axs_ring_findOverlay(container);
    // beautify.47：CATransform3D 零值不是 identity，显式初始化避免首帧误判
    driver.tiltBaseTransform = CATransform3DIdentity;
    driver.lastTilt = CATransform3DIdentity;
    driver.lastRotation = CATransform3DIdentity;
    driver.lastOverlayTilt = CATransform3DIdentity;
    driver.overlayBaseTransform = CATransform3DIdentity;
    driver.tiltHitOriginals = [NSMutableDictionary dictionary];
    // beautify.59：多视觉宿主缓存（key 带地址）
    driver.tiltVisualHosts = [NSArray array];
    driver.tiltVisualBase = [NSMutableDictionary dictionary];
    driver.tiltVisualWrote = [NSMutableDictionary dictionary];
    driver.tiltVisualNames = [NSMutableDictionary dictionary];
    driver.tiltVisualClips = [NSMutableDictionary dictionary];
    driver.tiltVisualMask = [NSMutableDictionary dictionary];
    driver.tiltVisualCorner = [NSMutableDictionary dictionary];

    // 先定位真实裁剪层（几何源+圆角来源）与非裁剪挂载层，再选整框 overlay
    // mask 作兜底/对照（此刻环尚未入树，无需跳过 ownRing）；未命中不落 -1
    axs_ring_selectMask(driver, container);
    axs_ring_findRealClip(driver, container);
    CALayer *mount = axs_ring_findMount(container);
    driver.mountLayer = mount;
    CALayer *src = driver.realLayer;

    CALayer *ring = [CALayer layer];
    ring.name = AXS_RING_LAYER_NAME;
    // 初始矩形 = 真实裁剪层换算到挂载层坐标（TXT beautify.23 二.2）
    ring.frame = (src != nil) ? [mount convertRect:src.frame fromLayer:src] : mount.bounds;
    ring.masksToBounds = NO;

    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.fillColor = nil;                   // 只当遮罩用
    shape.strokeColor = [UIColor whiteColor].CGColor;
    ring.mask = shape;

    CAGradientLayer *grad = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
    [ring addSublayer:grad];
    // beautify.41：按本容器分类接总闸——侧贴小窗受 master 控制，居中大浮窗
    // 完全忽略 master（只按光圈子开关）
    BOOL docked = axs_ring_containerIsDocked(container);
    BOOL ringAllowed = axs_ring_ringAllowedFor(docked);
    BOOL glowAllowed = axs_ring_glowAllowedFor(docked);
    ring.hidden = !ringAllowed;
    {
        UIWindow *w = container.window;
        CGFloat sw = (w != nil) ? w.bounds.size.width : 0;
        CGFloat wRatio = (sw > 0) ? container.bounds.size.width / sw : 0;
        axs_ring_log(@"decor classify: container=%p frame=%@ wRatio=%.2f docked=%d master=%d ringAllowed=%d glowAllowed=%d",
                     container, NSStringFromCGRect(container.bounds), wRatio,
                     docked ? 1 : 0, axs_ring_decorEnabled() ? 1 : 0,
                     ringAllowed ? 1 : 0, glowAllowed ? 1 : 0);
    }
    [mount addSublayer:ring];                // 挂非裁剪祖先层，置最上层（TXT 二.1/二.3）

    // beautify.31：两层柔光挂 ring 之下（描边盖在光晕上），同一 mountLayer。
    // 可见性由「本容器类型对应的光晕允许条件」决定（beautify.41：侧贴小窗
    // 受 master 控制，居中大浮窗忽略 master）；自定义开关只决定颜色来源。
    BOOL showGlow = glowAllowed;
    CAShapeLayer *glowInner = axs_ring_makeGlowLayer(AXS_RING_GLOW_NAME);
    CAShapeLayer *glowOuter = axs_ring_makeGlowLayer([AXS_RING_GLOW_NAME stringByAppendingString:@"Outer"]);
    glowInner.hidden = !showGlow;
    glowOuter.hidden = !showGlow;
    [mount insertSublayer:glowOuter below:ring];     // 外层宽扩散在下
    [mount insertSublayer:glowInner below:ring];     // 内层贴边在上（仍在描边下）

    driver.ring = ring;
    driver.shape = shape;
    driver.gradient = grad;
    driver.glowInner = glowInner;
    driver.glowOuter = glowOuter;

    driver.link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick)];
    [driver.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    // beautify.43：link 常驻不暂停，首帧同步由下方 axs_ring_syncDriver 完成
    axs_ring_drivers[key] = driver;

    // 全树一次性探针（进程内仅首次 attach）：定位真实圆角来源
    axs_ring_treeProbe(container);

    // 首帧即出几何
    axs_ring_syncDriver(driver);

    axs_ring_log(@"ring probe: container class=%@ bounds=%@ realLayer=%@ corner=%.2f",
                 NSStringFromClass(container.class), NSStringFromCGRect(container.bounds),
                 driver.realLayer ? NSStringFromClass(driver.realLayer.class) : @"none",
                 driver.realLayer ? driver.realLayer.cornerRadius : 0.0);
    CAShapeLayer *probeMask = nil;
    if (driver.realLayer != nil && [driver.realLayer.mask isKindOfClass:[CAShapeLayer class]]) {
        probeMask = (CAShapeLayer *)driver.realLayer.mask;
    }
    if (probeMask == nil || probeMask.path == nil) probeMask = driver.radiusMask;
    if (probeMask != nil && probeMask.path != nil) {
        axs_ring_log(@"ring probe: mask class=%@ bbox=%@ radius=%.1f",
                     NSStringFromClass(probeMask.class),
                     NSStringFromCGRect(CGPathGetBoundingBox(probeMask.path)),
                     axs_ring_radiusFromPath(probeMask.path));
    }

    if (!driver.loggedAttach) {
        driver.loggedAttach = YES;
        NSString *curve = @"n/a";
        if (src != nil && [src respondsToSelector:@selector(cornerCurve)]) {
            NSString *c = [(id)src cornerCurve];
            if ([c isKindOfClass:[NSString class]]) curve = c;
        }
        axs_ring_log(@"ring attach: scan container=%p mount=%@ mountClips=%d realFrame=%@ convRect=%@ corner=%.1f overlayR=%.1f rRing=%.1f source=%@ curve=%@",
                     container, NSStringFromClass(mount.class),
                     mount.masksToBounds ? 1 : 0,
                     NSStringFromCGRect(src ? src.frame : CGRectZero),
                     NSStringFromCGRect(driver.lastBounds),
                     (src != nil) ? src.cornerRadius : 0.0,
                     driver.overlayR, driver.lastRadius,
                     driver.radiusSource ?: @"config", curve);
    }
}

static void axs_ring_detachDriver(NSString *key) {
    AXSRingLinkDriver *driver = axs_ring_drivers[key];
    if (driver == nil) return;
    axs_ring_resetTilt(driver);               // beautify.44：恢复侧倾，绝不残留 transform
    // beautify.71：detach 对账——driver 带倾斜计数销毁时递减并恢复阴影，杜绝孤儿化
    if (driver.tiltShadowWasActive) {
        driver.tiltShadowWasActive = NO;
        axs_ring_tiltShadowActiveCount--;
        if (axs_ring_tiltShadowActiveCount <= 0) axs_ring_tiltShadowRestoreAll();
    }
    [driver.link invalidate];                // displayLink 随容器生命周期停止
    driver.ring.mask = nil;
    [driver.ring removeFromSuperlayer];      // 摘环、清动画、释放图层
    driver.glowInner.mask = nil;             // beautify.31：摘两层光晕，不留残影
    [driver.glowInner removeFromSuperlayer];
    driver.glowInner = nil;
    driver.glowOuter.mask = nil;
    [driver.glowOuter removeFromSuperlayer];
    driver.glowOuter = nil;
    [axs_ring_drivers removeObjectForKey:key];
    axs_ring_log(@"ring detach: scan container=%p", driver.container);
}

// --- 成员扫描（0.5s 定时器 + 窗口通知；只做集合对比，不做几何） ----------------

static void axs_ring_collectContainers(UIView *view, NSMutableArray *out, int depth) {
    if (view == nil || depth > 6) return;
    Class containerClass = objc_getClass("SCFloatingContainerView");
    if (containerClass != nil && [view isKindOfClass:containerClass]
        && view.window != nil && view.alpha > 0.01) {
        [out addObject:view];
    }
    for (UIView *sub in view.subviews) {
        axs_ring_collectContainers(sub, out, depth + 1);
    }
}

static void axs_ring_scanTick(void) {
    @try {
        if (!axs_ring_layoutHookInstalled) axs_ring_installLayoutHook(); // 类可能晚于 %ctor 注册
        axs_ring_probeNativeChainOnce();   // beautify.46：首次扫描核对原生 Dock 链路类/方法
        NSMutableArray *live = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                axs_ring_collectContainers(w, live, 0);
            }
        }

        // a) 已消失的容器 → detach（displayLink invalidate + 摘环）
        // beautify.71：宽限期防抖。sc-ring(42) 实测：贴边稳态中每次设置交互
        // （滑条/开关）会令原生侧瞬时改动容器 alpha/窗口可见性，容器掉出 live
        // 一拍即被 detach——倾斜复位（闪烁）+ 阴影恢复（灰带闪现）+ 重挂再倾斜，
        // 单次会话 detach/attach 各 120 次。改为连续 4 拍（0.5s×4=2s）缺席才拆；
        // 期间容器回归则原地续用，不再重挂。
        NSMutableArray *gone = [NSMutableArray array];
        for (NSString *key in axs_ring_drivers) {
            AXSRingLinkDriver *d = axs_ring_drivers[key];
            if (d.container == nil) { [gone addObject:key]; continue; }   // 真离层：立即拆
            if (![live containsObject:d.container]) {
                d.scanMissCount++;
                if (d.scanMissCount >= 4) [gone addObject:key];           // 连续 4 拍缺席才拆
            } else {
                d.scanMissCount = 0;
            }
        }
        for (NSString *key in gone) {
            axs_ring_detachDriver(key);
        }

        // beautify.43：定时器只做新旧容器 attach/detach 对比（指令 四.5）；
        // docked/allowed 状态与 hidden/alpha 提交由每个 driver 的 displayLink
        // 每帧同步完成，不依赖 0.5s 扫描，杜绝贴边后迟到的边框/光晕。

        if (!axs_ring_enabled()) {
            // TXT 二.6：开关关闭 → 全部摘除，完全无副作用
            for (NSString *key in [axs_ring_drivers.allKeys copy]) {
                axs_ring_detachDriver(key);
            }
            return;
        }

        // b) 新出现的容器 → attach；已在册的由各自 displayLink 驱动
        for (UIView *c in live) {
            axs_ring_attachContainer(c);
        }
    } @catch (NSException *exception) {
        axs_ring_log(@"ring scan exception: %@", exception);
    }
}

// --- resize 加速（TXT beautify.21 四.1）：hook SCFloatingContainerView 的
// layoutSubviews（UIKit 方法，不 hook 任何 sc_ 会话选择子）——resize 中
// ScreenCore 反复重建容器，新容器首次布局时立即挂环，不再等 0.5s 扫描；
// 在册容器照旧由各自 displayLink 驱动。

static void (*axs_ring_orig_layoutSubviews)(id, SEL);

static void axs_ring_hook_layoutSubviews(id self, SEL _cmd) {
    axs_ring_orig_layoutSubviews(self, _cmd);
    @try {
        // beautify.46：原生布局后（贴边/脱离/弹簧/方向都可能触发）标记侧倾基线重采样，
        // 使下一帧以原生最新 transform 为 base 重新叠加旋转（指令 三.3 的时机覆盖）。
        if (axs_ring_tiltEnabled()) axs_ring_noteNativeTrigger(@"layoutSubviews");
        if (axs_ring_drivers == nil) return;
        UIView *container = (UIView *)self;
        if (container.window == nil) return;
        NSString *key = [NSString stringWithFormat:@"%p", container];
        AXSRingLinkDriver *d = axs_ring_drivers[key];
        if (d == nil) {
            axs_ring_attachContainer(container);   // 重建的新容器立即挂环
        } else {
            // 手势改 bounds 触发的布局：模型即最新值，环与卡片同 commit 生效，
            // 右/下边（origin+size）不再滞后一帧（TXT beautify.22 三.3）
            // beautify.43：布局回调内直接重算 docked/allowed 并同步提交可见性，
            // 不等 displayLink 下一帧、不依赖唤醒（指令 三.5）
            axs_ring_syncDriver2(d, YES);
        }
    } @catch (NSException *exception) {
        // 布局路径上绝不抛异常
    }
}

static void axs_ring_installLayoutHook(void) {
    if (axs_ring_layoutHookInstalled) return;
    Class cls = objc_getClass("SCFloatingContainerView");
    if (cls == nil) return;
    SEL sel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == nil) return;
    // 先记原 IMP（可能是父类实现），再给本类加覆盖或替换本类 IMP——
    // 只影响 SCFloatingContainerView，不动 UIView
    axs_ring_orig_layoutSubviews = (void (*)(id, SEL))method_getImplementation(m);
    if (class_addMethod(cls, sel, (IMP)axs_ring_hook_layoutSubviews, method_getTypeEncoding(m))) {
        axs_ring_layoutHookInstalled = YES;
    } else {
        method_setImplementation(m, (IMP)axs_ring_hook_layoutSubviews);
        axs_ring_layoutHookInstalled = YES;
    }
    axs_ring_log(@"ring layout hook installed on SCFloatingContainerView");
}

// beautify.59：读取原生 base transform 值（appliedTransform/originalHostTransform/
// originalTransform，指令 六.2/八.5）。这些 ivar 可能是 NSValue(CATransform3D)、
// NSValue(CGAffineTransform) 或直接结构体——只用 KVC 只读探测，转成可读串。
static NSString *axs_ring_tiltNativeBaseDesc(id obj) {
    if (obj == nil) return @"nil";
    NSArray *keys = @[@"appliedTransform", @"originalHostTransform", @"originalTransform"];
    NSMutableString *out = [NSMutableString string];
    for (NSString *k in keys) {
        id v = axs_ring_nsValue(obj, k);
        if (v == nil) continue;
        NSString *desc = nil;
        if ([v isKindOfClass:[NSValue class]]) {
            const char *ty = [(NSValue *)v objCType];
            if (ty != NULL && strcmp(ty, @encode(CATransform3D)) == 0) {
                desc = axs_ring_nsTransform3D([(NSValue *)v CATransform3DValue]);
            } else if (ty != NULL && strcmp(ty, @encode(CGAffineTransform)) == 0) {
                desc = axs_ring_nsTransform2D([(NSValue *)v CGAffineTransformValue]);
            }
        }
        if (desc == nil) desc = [v description];
        [out appendFormat:@" %@=%@", k, desc];
    }
    return out.length > 0 ? out : @"(none readable)";
}

// beautify.46：核对原生 Dock 变换链路（指令 二）——探测指令列举的类/方法/ivar 是否
// 真实存在于当前二进制，结果写日志供真机验收比对。只探测、不 hook 签名不明的方法：
// 核心重算由 displayLink 每帧幂等基线 + layoutSubviews 时机覆盖，避免危险 hook 崩溃。
static BOOL axs_ring_nativeChainProbed = NO;
static void axs_ring_probeNativeChainOnce(void) {
    if (axs_ring_nativeChainProbed) return;
    axs_ring_nativeChainProbed = YES;
    @try {
        NSArray *classes = @[@"SCFloatingContainerView", @"SCFloatingInteractionOverlayView",
                             @"SCFloatingHostRootView", @"SCFloatingHostWindow",
                             @"SCFloatingSceneSession", @"SCFloatingDockRecord",
                             @"SCFloatingDockManager", @"SCDockedFloatingItemView",
                             @"SCFloatingCornerGestureRegionView", @"SCFloatingEdgeGestureRegionView"];
        NSArray *methods = @[@"applyTransform:", @"sc_setDockVisualTransform:",
                             @"sc_dockTransformForRecord:targetFrame:",
                             @"sc_initialTransformForSourceFrame:targetFrame:",
                             @"sc_layoutDockedItemsAnimated:", @"sc_dockSession:fromCorner:",
                             @"sc_undockSession:animated:",
                             @"sc_restoreRecordToNormalFrame:animated:completion:",
                             @"sc_restoreAllDockedSessionsAnimated:",
                             @"sc_containerGeometryDidChangeForSession:",
                             @"sc_floatingContainerViewDidChangeGeometry:",
                             @"sc_completeContainerGeometryTransitionForSession:",
                             @"sc_isSessionDocked:"];
        NSArray *ivars = @[@"appliedTransform", @"originalHostTransform", @"originalTransform",
                           @"docked", @"_docked", @"dockSide", @"dockPosition", @"dockEdge",
                           @"hostWindow", @"contentHostView", @"itemView",
                           @"backgroundEffectView", @"cardView", @"containerView"];
        NSMutableString *report = [NSMutableString stringWithString:@"\n"];
        for (NSString *cn in classes) {
            Class c = objc_getClass(cn.UTF8String);
            [report appendFormat:@"\n  class %@ = %@", cn, c != Nil ? @"YES" : @"no"];
            if (c == Nil) continue;
            for (NSString *mn in methods) {
                SEL s = NSSelectorFromString(mn);
                BOOL has = (class_getInstanceMethod(c, s) != NULL);
                if (has) [report appendFormat:@"\n    method %@ = YES", mn];
            }
            for (NSString *iv in ivars) {
                Ivar i = class_getInstanceVariable(c, iv.UTF8String);
                if (i != NULL) [report appendFormat:@"\n    ivar %@ = YES", iv];
            }
        }
        axs_ring_log(@"ring native chain probe (beautify.71):%@", report);
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring native chain probe", exception, nil);
    }
}

// --- 通知 / 定时器目标 ----------------------------------------------------------

@interface AXSRingHealthTarget : NSObject
- (void)axsRingTick;
- (void)axsRingWindowNote:(NSNotification *)note;
@end
@implementation AXSRingHealthTarget
- (void)axsRingTick { axs_ring_scanTick(); }
- (void)axsRingWindowNote:(NSNotification *)note {
    // beautify.43：窗口 key/可见性变化——当前回调内同步提交各 driver 可见性
    // （回窗/贴边即时生效），并做去重扫描处理新旧容器 attach/detach（指令 三.5/四.5）
    dispatch_async(dispatch_get_main_queue(), ^{
        axs_ring_syncAllDriversNow();
        axs_ring_queueScan();
    });
}
@end
static NSTimer *axs_ring_scanTimer = nil;

static AXSRingHealthTarget *axs_ring_healthTarget = nil;

// 偏好变更后刷新已有存活环的颜色（TXT beautify.26 三.4）：重建渐变层
// （自定义单色 ↔ 彩虹跑马灯互切），挂载/几何/圆角结构不动，环不断
static void axs_ring_refreshAppearance(void) {
    if (![axs_ring_drivers isKindOfClass:[NSDictionary class]]) return;

    // 先在锁外取一份 key 快照：fast-enumeration 一个 NSDictionary 得到的是 KEY
    // （NSString），不是 VALUE。beautify.33 崩溃根因正是此处误把 key 当 driver，
    // 对 NSString 发 -ring/-gradient → unrecognized selector → ___forwarding___。
    NSArray *keys = [axs_ring_drivers.allKeys copy];
    if (![keys isKindOfClass:[NSArray class]]) return;

    // beautify.41：偏好刷新按单个 driver 分类——居中大浮窗（docked=NO）忽略
    // 总开关，侧贴小窗（docked=YES）受 master 控制；全局配置（范围/亮度/颜色）
    // 在循环外取一次，允许条件在循环内按容器逐个计算。只驱动装饰层 hidden，
    // 绝不摘 driver、不触容器，大浮窗装饰层不会被偏好通知误删。
    double glowRangeCfg = axs_ring_glowRange();
    double glowBright = axs_ring_glowBrightness();
    UIColor *glowColor = axs_ring_glowColor();

    for (id key in keys) {
        @autoreleasepool {
            AXSRingLinkDriver *d = nil;
            @try {
                if (![key isKindOfClass:[NSString class]]) continue;
                id candidate = axs_ring_drivers[key];
                if (![candidate isKindOfClass:[AXSRingLinkDriver class]]) {
                    axs_ring_log(@"refresh skip non-driver key=%@ class=%@",
                                 key, NSStringFromClass([candidate class]));
                    continue;                       // 类型不符：只跳过，不影响主队列
                }
                d = (AXSRingLinkDriver *)candidate;
                CALayer *ring = d.ring;             // 弱引用先取局部并判空
                if (![ring isKindOfClass:[CALayer class]]) continue;

                BOOL docked = axs_ring_containerIsDocked(d.container);
                BOOL ringAllowed = axs_ring_ringAllowedFor(docked);
                BOOL glowAllowed = axs_ring_glowAllowedFor(docked);
                ring.hidden = !ringAllowed;         // 本容器类型对应的边框可见性

                // 先 retain 新层，再移除旧层，避免中间空引用
                CAGradientLayer *old = d.gradient;
                CAGradientLayer *g = axs_ring_makeGradient(axs_ring_customColor(), axs_ring_color());
                if (![g isKindOfClass:[CAGradientLayer class]]) { g = old; }
                g.frame = (old != nil) ? old.frame : ring.bounds;
                g.zPosition = 0;
                [ring insertSublayer:g atIndex:0];
                if ([old isKindOfClass:[CALayer class]] && old != g) {
                    [old removeFromSuperlayer];
                }
                d.gradient = g;

                // beautify.31/32：即时刷新光晕颜色与显隐；几何/半径/opacity 由
                // 下一帧 syncDriver 按同一 presentation 矩形补齐，不摘层、不停 link。
                CAShapeLayer *gi = d.glowInner;
                CAShapeLayer *go = d.glowOuter;
                double glowRange = glowAllowed ? glowRangeCfg : 0.0;
                BOOL showGlow = glowAllowed && glowRange > 0.5 && glowBright > 0.5;
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if ([gi isKindOfClass:[CAShapeLayer class]]) {
                    gi.hidden = !showGlow;
                    CGFloat fa = 0.01 * (CGFloat)(glowBright / 100.0);
                    gi.fillColor = [glowColor colorWithAlphaComponent:fa].CGColor;
                    gi.shadowColor = glowColor.CGColor;
                }
                if ([go isKindOfClass:[CAShapeLayer class]]) {
                    go.hidden = !showGlow;
                    CGFloat fa = 0.01 * (CGFloat)(glowBright / 100.0);
                    go.fillColor = [glowColor colorWithAlphaComponent:fa].CGColor;
                    go.shadowColor = glowColor.CGColor;
                }
                [CATransaction commit];
            } @catch (NSException *exception) {
                // 只跳过当前 driver 的本次刷新，不 rethrow、不中断 SpringBoard 主队列；
                // 保留现有光圈/光晕层与 displayLink 原样。
                axs_ring_logException(@"refreshAppearance driver", exception, d ?: key);
            }
        }
    }
}

// Darwin 通知：设置保存后立即重扫 + 刷新颜色（0.5s 定时器兜底）
// beautify.28 bug2: 先同步重载配置快照，确保 axs_ring_color() 读到的是刚写入
// 的新 hex，再刷新存活环；避免与 config 的异步 reload 竞争导致环不变色。
static void axs_ring_prefsChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // beautify.33：整个主队列 block 加异常保护。连续拖动滑条会高频触发本回调，
        // 任一步异常都只记录并吞掉，绝不 rethrow 到 SpringBoard 主队列。
        @try {
            AxsHoldLaunchConfig *cfg = [AxsHoldLaunchConfig axs_holdlaunch_shared];
            if ([cfg respondsToSelector:@selector(axs_holdlaunch_reload)]) {
                [cfg axs_holdlaunch_reload];
            }
            // beautify.43：偏好快照随 saved 通知刷新（安全优化，保留），并在
            // 当前回调内同步提交各 driver 可见性（总开关/子开关即时生效），
            // 刷新颜色 + 去重扫描（指令 四.4/六.2）
            axs_ring_refreshConfigSnapshot();
            axs_ring_tiltLogPreferenceSources();   // beautify.59：每次设置保存复查偏好双来源
            axs_ring_syncAllDriversNow();
            axs_ring_refreshAppearance();
            axs_ring_queueScan();
        } @catch (NSException *exception) {
            axs_ring_logException(@"prefsChanged main", exception, nil);
        }
    });
}

// --- entry: 启动即挂定时器与通知（无任何 hook） --------------------------------

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") != nil) {
            axs_ring_drivers = [NSMutableDictionary new];
            axs_ring_healthTarget = [AXSRingHealthTarget new];
            axs_ring_installLayoutHook();        // 类已注册则立即装钩，未注册由扫描重试
            axs_ring_refreshConfigSnapshot();    // beautify.42：启动即建偏好快照
            axs_ring_log(@"ring module loaded in SpringBoard");
            axs_ring_log(@"ring hooks ring=0 sessionHooks=0 layout=%d holdPress=1",
                         axs_ring_layoutHookInstalled ? 1 : 0);

            // 设置保存通知：开关变化立即生效
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, axs_ring_prefsChanged,
                                            (__bridge CFStringRef)AxsHoldLaunchTheirPrefsSaved,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            // 窗口可见性通知：降低扫描延迟（TXT 三.2）
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserver:axs_ring_healthTarget selector:@selector(axsRingWindowNote:)
                       name:UIWindowDidBecomeVisibleNotification object:nil];
            [nc addObserver:axs_ring_healthTarget selector:@selector(axsRingWindowNote:)
                       name:UIWindowDidBecomeHiddenNotification object:nil];
            [nc addObserver:axs_ring_healthTarget selector:@selector(axsRingWindowNote:)
                       name:UIWindowDidResignKeyNotification object:nil];

            axs_ring_scanTimer = [NSTimer timerWithTimeInterval:0.5
                                                         target:axs_ring_healthTarget
                                                       selector:@selector(axsRingTick)
                                                       userInfo:nil
                                                        repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:axs_ring_scanTimer forMode:NSRunLoopCommonModes];
        }
    }
}
