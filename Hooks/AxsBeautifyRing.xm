#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
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

// beautify.47：3D 侧透视常量。m34 为透视距离，真机可在 -1/500..-1/800 微调；
// AXS_TILT_SIDE_SIGN 只在真机左右方向反了时取反（右侧 +1 / 左侧 -1）。
#define AXS_TILT_M34        (-1.0 / 600.0)
#define AXS_TILT_SIDE_SIGN  (1.0)

static void axs_ring_scanTick(void);
static void axs_ring_installLayoutHook(void);           // 定义在扫描节之后
static void axs_ring_probeNativeChainOnce(void);        // beautify.46：定义在 layout hook 之后
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
        // beautify.47：侧倾开关（默认 NO）+ 3D 透视角度（默认 3.0，clamp 0..6）
        // 旧保存值 >6.0（.44–.46 的 10° -planar tilt）必须夹紧到 6.0，不能沿用过大角度。
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyTiltEnabled" defaultValue:@NO];
        axs_snap_tiltEnabled = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
        v = [cfg axs_holdlaunch_theirValueForKey:@"splitBeautifyTiltAngle" defaultValue:@3.0];
        axs_snap_tiltAngle = axs_ring_clamp([v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 3.0, 0.0, 6.0);

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

        CGRect frame = container.bounds;
        CALayer *pres = container.layer.presentationLayer;
        if ([pres isKindOfClass:[CALayer class]]) frame = [(CALayer *)pres frame];
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
        if (frame.size.width > sw * 0.45) return NO;
        if (frame.origin.x <= 12.0) return YES;
        if (sw - (frame.origin.x + frame.size.width) <= 12.0) return YES;
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
        CALayer *pres = container.layer.presentationLayer;
        if ([pres isKindOfClass:[CALayer class]]) {
            CGRect pf = [(CALayer *)pres frame];             // 相对 superlayer
            CALayer *sl = container.layer.superlayer;
            if (sl != nil) pf = [sl convertRect:pf toLayer:w.layer];
            if (pf.size.width > 0) f = pf;
        }
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
// beautify.47：手势命中区（overlay/边条/角区）原始 frame/transform，供恢复（平面命中）
@property (nonatomic, strong) NSMutableDictionary *tiltHitOriginals; // key(ptr)->NSValue(frame) / key+"T"->NSValue(transform3D)
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
// --- beautify.47：3D 侧透视（绕 Y 轴 rotationY + m34），替代 .46 的 2D rotation.z ----
// .46 真机现象：黑色应用内容层单独做了 2D 旋转，外层白色 Dock 卡片背景/遮罩未跟随，
//   导致白边/三角露底；10° 平面歪头过大，且 2D 旋转后四周边缘/角区手势失效。
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
        CGRect winBBox = axs_ring_tiltBBox(proj);
        if (winBBox.size.width <= 0 || winBBox.size.height <= 0) return;
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
static UIView *axs_ring_tiltProbeTarget(AXSRingLinkDriver *driver, UIView *container) {
    UIView *found = nil;
    @try {
        if (container == nil) return nil;
        UIWindow *w = container.window;
        if (w == nil) return nil;
        UIView *rootV = (w.rootViewController != nil) ? w.rootViewController.view : nil;
        UIView *overlay = axs_ring_findTiltOverlay(container);

        // 原生链路对象（指令 二.1/四.1）：从 container / delegate / window / rootVC 探测。
        id del = [container respondsToSelector:@selector(delegate)] ? [(id)container delegate] : nil;
        NSMutableArray *chain = [NSMutableArray array];
        if (del != nil) [chain addObject:del];
        if (w != nil) [chain addObject:w];
        if (w.rootViewController != nil) [chain addObject:w.rootViewController];
        NSArray *nativeKeys = @[@"session", @"manager", @"dockRecord", @"record",
                                @"itemView", @"contentHostView", @"backgroundEffectView",
                                @"hostWindow", @"rootView", @"cardView", @"containerView"];
        NSMutableArray *nativeObjs = [NSMutableArray array];
        for (id base in chain) {
            for (NSString *k in nativeKeys) {
                id v = axs_ring_nsValue(base, k);
                if (v != nil && ![nativeObjs containsObject:v]) [nativeObjs addObject:v];
            }
        }
        for (NSString *k in nativeKeys) {
            id v = axs_ring_nsValue(container, k);
            if (v != nil && ![nativeObjs containsObject:v]) [nativeObjs addObject:v];
        }

        // 候选 UIView 池（指令 四.1）：整卡容器 SCDockedFloatingItemView 优先，
        // 然后 container 自身 + superview 链(<=8) + 原生 UIView 对象；overlay 仅为
        // 参考不入池（手势层必须留在 identity 平面，禁止进入 3D 宿主）。
        Class itemCls = objc_getClass("SCDockedFloatingItemView");
        NSMutableArray *cands = [NSMutableArray array];
        for (id o in nativeObjs) {
            if ([o isKindOfClass:itemCls] && ![cands containsObject:o]) [cands addObject:o];
        }
        [cands addObject:container];
        UIView *av = container.superview;
        int hops = 0;
        while (av != nil && hops < 8) {
            if (itemCls != Nil && [av isKindOfClass:itemCls] && ![cands containsObject:av]) {
                [cands insertObject:av atIndex:0];   // 整卡容器提到最前
            } else if (![cands containsObject:av]) {
                [cands addObject:av];
            }
            av = av.superview;
            hops++;
        }
        for (id o in nativeObjs) {
            if ([o isKindOfClass:[UIView class]] && ![cands containsObject:o]) [cands addObject:o];
        }

        // 完整宿主链路日志（指令 五.2/五.3/五.4/五.9）：类名+地址+frame/bounds/anchor/clips+3D。
        NSMutableString *lines = [NSMutableString string];
        [lines appendFormat:@"\n  overlay=%@ nativeObjs=%lu itemCls=%@",
         axs_ring_nsDesc(overlay), (unsigned long)nativeObjs.count,
         itemCls != Nil ? @"YES" : @"no"];
        for (id o in nativeObjs) [lines appendFormat:@"\n  native %@", axs_ring_nsDesc(o)];
        int idx = 0;
        for (UIView *v in cands) {
            [lines appendFormat:@"\n  [%d] %@", idx, axs_ring_nsView3D(v)];
            idx++;
        }
        BOOL nativeDocked = axs_ring_containerIsDocked(container);
        int nativeSide = axs_ring_containerDockSide(container);
        double rawAngle = axs_ring_tiltAngle();
        axs_ring_log(@"ring tilt probe chain: enabled=%d angle=%.1f clamped=%.1f docked=%d side=%d "
                     @"container=%@ overlay=%@%@",
                     axs_ring_tiltEnabled() ? 1 : 0, rawAngle,
                     axs_ring_clamp(rawAngle, 0.0, 6.0),
                     nativeDocked ? 1 : 0, nativeSide,
                     axs_ring_nsDesc(container), axs_ring_nsDesc(overlay), lines);

        // 宿主选择（指令 四.1）：优先整卡容器 SCDockedFloatingItemView / 其安全父级；
        // 必须同时包住 container（黑色内容）与其白色背景/装饰祖先，且自身非裁剪、
        // 非 overlay/window/rootVC。找不到安全公共祖先就不强挂（指令 六.11）。
        UIView *itemView = nil;
        for (UIView *v in cands) {
            if (itemCls != Nil && [v isKindOfClass:itemCls]) { itemView = v; break; }
        }
        if (itemView != nil) {
            // 整卡容器若非裁剪 → 直接用；若裁剪 → 取其安全非裁剪父级（不裁 3D 边角）
            if (!itemView.layer.masksToBounds) found = itemView;
            else {
                UIView *p = itemView.superview;
                int g = 0;
                while (p != nil && g < 6) {
                    if (p != overlay && p != w && p != rootV && !p.layer.masksToBounds
                        && [itemView isDescendantOfView:p]) { found = p; break; }
                    p = p.superview; g++;
                }
                if (found == nil) found = itemView;  // 无安全父级则仍用整卡容器（记录 clips=1）
            }
        }
        if (found == nil) {
            // 退化：container 往上找同时含 container 的最近非裁剪祖先（保证背景/装饰同层）
            av = container.superview;
            hops = 0;
            while (av != nil && hops < 8) {
                if (av != overlay && av != w && av != rootV && av != container
                    && !av.layer.masksToBounds && [container isDescendantOfView:av]) {
                    found = av; break;
                }
                av = av.superview;
                hops++;
            }
        }
        driver.tiltHostName = found != nil ? NSStringFromClass(found.class) : @"none";
        driver.tiltOverlayInHost = (found != nil && overlay != nil)
                                   ? [overlay isDescendantOfView:found] : NO;
        axs_ring_log(@"ring tilt 3D host: container=%@ host=%@ overlayInHost=%d "
                     @"hostClips=%d hops=%d",
                     NSStringFromClass(container.class), driver.tiltHostName,
                     driver.tiltOverlayInHost ? 1 : 0,
                     (found != nil && found.layer.masksToBounds) ? 1 : 0, hops);
    } @catch (NSException *exception) {
        axs_ring_logException(@"ring tilt probe", exception, container);
        found = nil;
    }
    return found;
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

// 施加/恢复某 driver 的 3D 侧透视。核心：
//   rotationY = CATransform3DRotate(identity, sideSign*angleRad, 0,1,0); rotationY.m34 = -1/600
//   tilted3D  = CATransform3DConcat(base3D, rotationY)   // 保留原生缩放/平移
// 手势 overlay 留在 identity 平面，命中区按投影后四角更新 frame（不改 transform/alpha/mask）。
static void axs_ring_applyTilt(AXSRingLinkDriver *driver) {
    @try {
        UIView *container = driver.container;
        if (container == nil) return;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        BOOL needProbe = !driver.tiltProbed || driver.tiltTarget == nil
                         || (now - driver.tiltLastProbeTime >= 1.0);
        if (needProbe) {
            UIView *prev = driver.tiltTarget;
            UIView *next = axs_ring_tiltProbeTarget(driver, container);
            if (next != prev) {
                driver.tiltNeedRebase = YES;
                driver.tiltBaseTransform = CATransform3DIdentity;
                driver.lastTilt = CATransform3DIdentity;
            }
            driver.tiltTarget = next;
            driver.tiltProbed = YES;
            driver.tiltLastProbeTime = now;
            driver.tiltOverlayView = axs_ring_findTiltOverlay(container);
        }
        UIView *target = driver.tiltTarget;
        if (target == nil) return;

        BOOL tiltOn = axs_ring_tiltEnabled();
        BOOL docked = axs_ring_containerIsDocked(container);
        double angle = axs_ring_clamp(axs_ring_tiltAngle(), 0.0, 6.0);  // 旧>6 已夹紧
        int side = 0;
        double rad = 0.0;
        // 居中大窗不做透视（docked=NO 直接回原生 base，指令 四.5/六.7）
        BOOL shouldTilt = tiltOn && docked && angle > 0.0 && container.window != nil;
        if (shouldTilt) {
            side = axs_ring_containerDockSide(container);
            rad = AXS_TILT_SIDE_SIGN * side * angle * M_PI / 180.0;    // 角度转弧度（指令 四.2）
        }

        // rotationY（绕垂直 Y 轴）+ m34 透视。竖边保持垂直，只左右侧边形成轻微梯形透视。
        CATransform3D rotationY = CATransform3DIdentity;
        if (shouldTilt) {
            rotationY = CATransform3DRotate(CATransform3DIdentity, (CGFloat)rad, 0.0, 1.0, 0.0);
            rotationY.m34 = AXS_TILT_M34;
        }

        // 幂等基线：layer.transform 读回 3D；cur==lastTilt → 我们写的值还在，base 不变；
        // 原生覆盖 / 方法命中 → 以当前值作新 base 重新采样（绝不把已叠加的 tilted 当 base 累积）。
        CATransform3D cur = target.layer.transform;
        BOOL rebase = axs_ring_tiltGlobalRebase || driver.tiltNeedRebase
                      || !axs_ring_t3dEqual(cur, driver.lastTilt);
        if (rebase) {
            driver.tiltBaseTransform = cur;
            driver.tiltNeedRebase = NO;
        }
        CATransform3D base3D = driver.tiltBaseTransform;
        CATransform3D want = CATransform3DConcat(base3D, rotationY);    // 复合（指令 四.3）

        BOOL rotationChanged = !axs_ring_t3dEqual(rotationY, driver.lastRotation);
        BOOL wantChanged = !axs_ring_t3dEqual(want, cur);
        if (wantChanged || rotationChanged) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.layer.anchorPoint = CGPointMake(0.5, 0.5);           // 锚点居中（指令 四.2）
            target.layer.transform = want;                              // 3D 透视作用于视觉宿主层
            [CATransaction commit];
            driver.lastTilt = want;
            driver.hasTilt = shouldTilt;
        }
        driver.lastRotation = rotationY;

        // 手势层（指令 四.4/六.9）：overlay/边条/角区保持 identity 屏幕平面，绝不继承 3D。
        // 若 overlay 物理挂在宿主子树内（tiltOverlayInHost），父级 3D 会外溢——给 overlay
        // 自身施加父级复合的逆变换抵消，使其视觉/命中维持平面；命中区另按投影四角同步 frame。
        UIView *ov = driver.tiltOverlayView;
        if (ov != nil) {
            CATransform3D ocur = ov.layer.transform;
            if (rebase || !axs_ring_t3dEqual(ocur, driver.lastOverlayTilt)) {
                driver.overlayBaseTransform = ocur;
            }
            CATransform3D obase = driver.overlayBaseTransform;
            CATransform3D planar = CATransform3DIdentity;
            if (driver.tiltOverlayInHost && shouldTilt) {
                // 抵消父级链路 3D：逆(base3D·rotationY)·base3D ≈ 抵消 rotationY 的平面效果
                planar = CATransform3DConcat(CATransform3DInvert(want), base3D);
            }
            CATransform3D owant = CATransform3DConcat(obase, planar);
            if (!axs_ring_t3dEqual(owant, ocur) || rotationChanged) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                ov.layer.transform = owant;
                [CATransaction commit];
                driver.lastOverlayTilt = owant;
            }
        }

        // 命中区按投影后四角更新 frame（指令 四.4/五.10）：只改 frame，不改 transform/alpha/
        // userInteractionEnabled/gesture。透明区域透传、ring/glow 非交互层不参与命中。
        UIWindow *w = container.window;
        CGPoint proj[4] = { CGPointZero, CGPointZero, CGPointZero, CGPointZero };
        NSString *cornersStr = @"n/a";
        if (w != nil) {
            @try {
                axs_ring_tiltProjectCorners(target, w, proj);
                cornersStr = axs_ring_nsCorners(proj);
            } @catch (NSException *e) {
                cornersStr = @"project-exception";
            }
        }
        @try {
            axs_ring_tiltSyncHitFrame(driver, shouldTilt, proj, w);   // 命中区按投影同步（平面层）
        } @catch (NSException *e) {
            axs_ring_log(@"ring tilt hit-sync exception: %@", e);
        }

        // 3D 链路关键日志（1s 节流或状态变化强制）：能确认背景+内容是否同层、overlay 是否平面。
        BOOL force = rotationChanged || rebase || (shouldTilt != driver.hasTilt);
        if (force || now - axs_ring_tiltApplyLogTime >= 1.0) {
            axs_ring_tiltApplyLogTime = now;
            NSMutableString *hit = [NSMutableString string];
            UIView *ov2 = driver.tiltOverlayView;
            [hit appendFormat:@"overlay=%@", axs_ring_nsHitRegion(ov2)];
            if (ov2 != nil) {
                NSMutableArray *regions = [NSMutableArray array];
                axs_ring_tiltCollectHitRegions(ov2, regions, 0);
                [hit appendFormat:@" regions(%lu)", (unsigned long)regions.count];
                for (UIView *r in regions) [hit appendFormat:@"\n    region %@", axs_ring_nsHitRegion(r)];
            }
            axs_ring_log(@"ring tilt 3D apply: enabled=%d docked=%d angle=%.1f clamped=%.1f "
                         @"side=%d sideSign=%.1f rad=%.4f m34=%.6f "
                         @"container=%@ host=%@ overlayInHost=%d "
                         @"base3D=%@ rotationY=%@ tilted3D=%@ rebase=%d trigger=%@ "
                         @"corners=%@\n  hit %@",
                         tiltOn ? 1 : 0, docked ? 1 : 0, angle, angle, side,
                         AXS_TILT_SIDE_SIGN, rad, AXS_TILT_M34,
                         NSStringFromClass(container.class),
                         driver.tiltHostName ?: @"none", driver.tiltOverlayInHost ? 1 : 0,
                         axs_ring_nsTransform3D(base3D), axs_ring_nsTransform3D(rotationY),
                         axs_ring_nsTransform3D(want), rebase ? 1 : 0,
                         axs_ring_tiltTriggerName, cornersStr, hit);
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
        UIView *target = driver.tiltTarget;
        UIView *ov = driver.tiltOverlayView;
        BOOL had = driver.hasTilt || !CATransform3DIsIdentity(driver.lastOverlayTilt);
        if (!had) return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (target != nil) target.layer.transform = driver.tiltBaseTransform;   // 原生 base3D
        if (ov != nil) ov.layer.transform = driver.overlayBaseTransform;         // overlay 平面初始
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
        driver.lastTilt = driver.tiltBaseTransform;
        driver.lastOverlayTilt = driver.overlayBaseTransform;
        driver.lastRotation = CATransform3DIdentity;
        driver.hasTilt = NO;
        axs_ring_log(@"ring tilt 3D reset: host=%@ base3D=%@",
                     driver.tiltHostName ?: @"none", axs_ring_nsTransform3D(driver.tiltBaseTransform));
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
        NSMutableArray *gone = [NSMutableArray array];
        for (NSString *key in axs_ring_drivers) {
            AXSRingLinkDriver *d = axs_ring_drivers[key];
            if (d.container == nil || ![live containsObject:d.container]) [gone addObject:key];
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
                             @"sc_restoreAllDockedSessionsAnimated:", @"sc_isSessionDocked:"];
        NSArray *ivars = @[@"appliedTransform", @"originalHostTransform", @"originalTransform",
                           @"docked", @"dockSide", @"hostWindow", @"contentHostView", @"itemView",
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
        axs_ring_log(@"ring native chain probe (beautify.47):%@", report);
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
