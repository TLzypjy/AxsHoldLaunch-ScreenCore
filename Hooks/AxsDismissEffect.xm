#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

// Logos does not inject substrate.h into a translation unit with no %hook
// block. Declare the entry point directly.
#ifdef __cplusplus
extern "C" {
#endif
void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);
#ifdef __cplusplus
}
#endif

// beautify.104: Metal fine-sand renderer (Hooks/AxsMetalSand.xm). Returns YES
// when the GPU engine took over; NO means caller should fall back to UIView.
BOOL axs_metalSandPlay(UIImage *shot, CGRect frameInWindow, CGFloat duration);

// ---------------------------------------------------------------------------
// beautify.101 - 9th style: ColorSand, rebuilt as a faithful UIView port of
// the reference plugin's Metal "fine sand" shader (mode 2). The card is diced
// into a dense grid; each tile keeps its ORIGINAL screenshot pixels and is
// round-masked into a sand grain. A diagonal breakup front sweeps from the
// BOTTOM-LEFT corner to the TOP-RIGHT corner -- tiles lift off in that order
// (begin = (unit.x + 1 - unit.y) * 0.18), then drift up-right, shrink, spin
// slightly and fade. This replaces the .100 pure-colour random field, which
// had the right direction but no sweep front and no source-image texture.
// The 8 existing styles remain untouched.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// beautify.97 - floating window DISMISS particle effect (STEP 1 of the
// animation plan). Scope is deliberately tiny and low-risk:
//
//   * Only runs when splitBeautifyDismissAnimEnabled == YES in the ScreenCore
//     preferences domain; default NO, so nothing changes until the user opts in.
//   * Hooks the close-session entry points but NEVER alters their behaviour:
//     the original implementation is always called with the exact same args,
//     return value untouched. The particle burst is a purely additive overlay
//     drawn on a temporary high-level window.
//   * The floating container is snapshotted BEFORE the original closes it,
//     diced into a grid, and fed to CAEmitterLayer as per-cell textures that
//     fly outward and fade. After ~1s everything is torn down.
//   * If anything is missing (no container, no window, no image, bad signature)
//     the effect simply no-ops with a log line. It can never block a close.
//
// This is an ENGINE PROBE: visual fidelity is secondary to proving that
// snapshot -> dice -> emit -> cleanup is stable in SpringBoard.
// ---------------------------------------------------------------------------

static NSString * const AXS_DM_LOG_PATH = @"/var/mobile/Documents/sc-dismiss-effect.log";

static void axs_dm_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_dm_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:DME] %@", message);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:AXS_DM_LOG_PATH error:nil];
        if ([[attr objectForKey:NSFileSize] unsignedLongLongValue] > 512 * 1024) {
            [fm removeItemAtPath:AXS_DM_LOG_PATH error:nil];
        }
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                          [[NSDate date] timeIntervalSince1970], message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:AXS_DM_LOG_PATH];
        if (handle == nil) {
            [line writeToFile:AXS_DM_LOG_PATH atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *ignored) {
    }
}

static unsigned long long axs_dm_seq = 0;

// --- config: read the opt-in switch from ScreenCore's own prefs domain ------
static BOOL axs_dm_enabled(void) {
    BOOL enabled = NO;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return NO;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyDismissAnimEnabled", @NO);
            if ([value isKindOfClass:[NSNumber class]]) enabled = [value boolValue];
        }
    } @catch (NSException *ignored) {
        enabled = NO;
    }
    return enabled;
}

// --- dismiss style ----------------------------------------------------------
// 9 styles share one master switch. Style 0 preserves the .98 behaviour.
typedef NS_ENUM(NSInteger, AXSDismissStyle) {
    AXSDismissStyleBlockBurst = 0,
    AXSDismissStyleGravity,
    AXSDismissStyleVortex,
    AXSDismissStyleShockwave,
    AXSDismissStyleDust,
    AXSDismissStylePixelDissolve,
    AXSDismissStyleBlinds,
    AXSDismissStyleGlass,
    AXSDismissStyleColorSand,   // beautify.100: pastel sand drifting up-right
};

static NSInteger axs_dm_style(void) {
    NSInteger s = AXSDismissStyleBlockBurst;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return s;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyDismissStyle", @0);
            if ([value isKindOfClass:[NSNumber class]]) {
                s = [value integerValue];
                if (s < 0 || s > AXSDismissStyleColorSand) s = AXSDismissStyleBlockBurst;
            }
        }
    } @catch (NSException *ignored) {
        s = AXSDismissStyleBlockBurst;
    }
    return s;
}

// beautify.103: dismissal animation speed. The panel exposes 0.3..3.0 (higher
// = faster); this returns the DURATION scale (= 1/speed) so every style can
// simply multiply its timings. Default 1.0 keeps all previous behaviour.
static CGFloat axs_dm_speedScale(void) {
    CGFloat speed = 1.0;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return 1.0;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyDismissSpeed", @1.0);
            if ([value isKindOfClass:[NSNumber class]]) {
                speed = [value floatValue];
                if (speed < 0.3) speed = 0.3;
                if (speed > 3.0) speed = 3.0;
            }
        }
    } @catch (NSException *ignored) {
        speed = 1.0;
    }
    if (speed < 0.3) speed = 1.0;   // NaN / zero guard
    return 1.0 / speed;
}

static NSString *axs_dm_styleName(NSInteger style) {
    switch (style) {
        case AXSDismissStyleGravity:       return @"gravity";
        case AXSDismissStyleVortex:        return @"vortex";
        case AXSDismissStyleShockwave:     return @"shockwave";
        case AXSDismissStyleDust:          return @"dust";
        case AXSDismissStylePixelDissolve: return @"pixel";
        case AXSDismissStyleBlinds:        return @"blinds";
        case AXSDismissStyleGlass:         return @"glass";
        case AXSDismissStyleColorSand:     return @"sand";
        default:                           return @"burst";
    }
}

static void axs_dm_gridForStyle(NSInteger style, int *cols, int *rows) {
    switch (style) {
        case AXSDismissStyleDust:          *cols = 14; *rows = 14; break;
        case AXSDismissStylePixelDissolve: *cols = 12; *rows = 12; break;
        case AXSDismissStyleBlinds:        *cols = 8;  *rows = 14; break;
        case AXSDismissStyleGlass:         *cols = 5;  *rows = 6;  break;
        default:                           *cols = 10; *rows = 10; break;
    }
}

// fract(sin(dot(v,(127.1,311.7)))*43758.5453) -- identical hash to the
// reference plugin's Metal dustHash, so grain randomness matches per-cell.
static float axs_dm_dustHash(CGFloat x, CGFloat y) {
    double v = sin((double)x * 127.1 + (double)y * 311.7) * 43758.5453;
    return (float)(v - floor(v));
}

static CGFloat axs_dm_randRange(CGFloat lo, CGFloat hi) {
    return lo + ((CGFloat)arc4random_uniform(1000) / 1000.0) * (hi - lo);
}

// --- view tree helpers ------------------------------------------------------
static UIView *axs_dm_findContainerView(void) {
    UIView *found = nil;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                int guard = 0;
                while (stack.count > 0 && guard < 600 && found == nil) {
                    UIView *v = [stack lastObject];
                    [stack removeLastObject];
                    guard++;
                    if (v == nil) continue;
                    NSString *cn = NSStringFromClass(v.class);
                    if ([cn isEqualToString:@"SCFloatingContainerView"]
                        && v.window != nil && !v.hidden && v.frame.size.width > 40) {
                        found = v;
                        break;
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
                if (found != nil) break;
            }
            if (found != nil) break;
        }
    } @catch (NSException *ignored) {
        found = nil;
    }
    return found;
}

static UIImage *axs_dm_snapshot(UIView *view) {
    UIImage *img = nil;
    @try {
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithBounds:view.bounds format:fmt];
        img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
        }];
    } @catch (NSException *ignored) {
        img = nil;
    }
    return img;
}

// --- particle overlay -------------------------------------------------------
static UIWindow *axs_dm_overlayWindow = nil;
static NSMutableArray *axs_dm_activeOverlays = nil;

// beautify.101: fine-sand dissolve with a bottom-left -> top-right breakup
// front, ported from the reference plugin's Metal mode-2 shader. The source
// screenshot is diced into a dense grid; each tile keeps its REAL pixels (a
// CGImage slice) and morphs into a round sand grain. Every tile carries its
// own launch delay so a diagonal front sweeps across the card: bottom-left
// lifts first, top-right last (begin = (x + 1 - y) * 0.18 + r*0.025). Grains
// then fly UP-RIGHT, shrink to 24%-56%, spin slightly and fade, over ~1.3s --
// matching DustDuration/DustDistance defaults of the reference plugin.
// Runs on the same windowScene-bound overlay as all styles (.98 visibility
// fix). The 8 original styles are untouched.
static void axs_dm_emitColorSand(UIView *sourceView, CGRect sourceFrameInWindow,
                                 NSInteger style, NSString *styleName) {
    @try {
        UIImage *shot = axs_dm_snapshot(sourceView);
        if (shot == nil || shot.CGImage == nil) {
            axs_dm_log(@"emit: sand snapshot failed");
            return;
        }
        CGImageRef full = shot.CGImage;
        NSUInteger px = CGImageGetWidth(full);
        NSUInteger py = CGImageGetHeight(full);
        if (px == 0 || py == 0) {
            axs_dm_log(@"emit: sand empty image %lux%lu", (unsigned long)px, (unsigned long)py);
            return;
        }

        UIWindow *host = nil;
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { host = w; break; }
            }
            if (host != nil) break;
        }
        if (host == nil) {
            axs_dm_log(@"emit: sand no key window");
            return;
        }

        UIWindow *overlay = [[UIWindow alloc] initWithFrame:host.bounds];
        if ([overlay respondsToSelector:@selector(setWindowScene:)]) {
            overlay.windowScene = host.windowScene;
        }
        overlay.windowLevel = UIWindowLevelAlert + 500;
        overlay.backgroundColor = [UIColor clearColor];
        overlay.userInteractionEnabled = NO;
        overlay.hidden = NO;

        // Dense grid for a fine-sand look. .102: cell shrunk 5.5pt -> 3.2pt
        // (roughly 3x more grains than .101). Hard total cap keeps SpringBoard
        // layer/animation creation bounded so this never turns into a stutter.
        CGFloat fw = sourceFrameInWindow.size.width;
        CGFloat fh = sourceFrameInWindow.size.height;
        int cols = (int)lround(fw / 3.2);
        int rows = (int)lround(fh / 3.2);
        if (cols < 28) cols = 28; if (cols > 96) cols = 96;
        if (rows < 20) rows = 20; if (rows > 76) rows = 76;
        const int AXS_SAND_MAX = 6000;
        if (cols * rows > AXS_SAND_MAX) {
            CGFloat k = sqrtf((CGFloat)AXS_SAND_MAX / (CGFloat)(cols * rows));
            cols = (int)lround((CGFloat)cols * k);
            rows = (int)lround((CGFloat)rows * k);
        }

        CGFloat speedScale = axs_dm_speedScale();
        const CGFloat total = 1.30 * speedScale;   // DustDuration default / speed
        const CGFloat D = 110.0;      // DustDistance default
        CGFloat tileW = fw / (CGFloat)cols;
        CGFloat tileH = fh / (CGFloat)rows;
        CGFloat ox = sourceFrameInWindow.origin.x;
        CGFloat oy = sourceFrameInWindow.origin.y;

        CALayer *root = [CALayer layer];
        root.frame = overlay.bounds;
        [overlay.layer addSublayer:root];

        NSUInteger seed = axs_dm_seq + 1;
        int made = 0;
        CFTimeInterval now = CACurrentMediaTime();
        CGFloat cw = (CGFloat)px / (CGFloat)cols;
        CGFloat ch = (CGFloat)py / (CGFloat)rows;

        for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
                // source-pixel crop (+1px overlap hides seams when scaled to fill)
                CGFloat cxp = (CGFloat)c * cw;
                CGFloat cyp = (CGFloat)r * ch;
                CGFloat cwi = cw + 1.0, chi = ch + 1.0;
                if (cxp + cwi > (CGFloat)px) cwi = (CGFloat)px - cxp;
                if (cyp + chi > (CGFloat)py) chi = (CGFloat)py - cyp;
                if (cwi <= 0 || chi <= 0) continue;
                CGImageRef piece = CGImageCreateWithImageInRect(
                    full, CGRectMake(cxp, cyp, cwi, chi));
                if (piece == NULL) continue;

                CGFloat ux = ((CGFloat)c + 0.5) / (CGFloat)cols; // 0 left -> 1 right
                CGFloat uy = ((CGFloat)r + 0.5) / (CGFloat)rows; // 0 top  -> 1 bottom

                float r1 = axs_dm_dustHash((CGFloat)c + (CGFloat)seed,
                                           (CGFloat)r + (CGFloat)seed * 0.371);
                float r2 = axs_dm_dustHash((CGFloat)c + (CGFloat)seed + 19.7,
                                           (CGFloat)r + (CGFloat)seed * 0.371 + 19.7);
                float r3 = axs_dm_dustHash((CGFloat)c + (CGFloat)seed + 72.3,
                                           (CGFloat)r + (CGFloat)seed * 0.371 + 72.3);

                CALayer *g = [CALayer layer];
                g.contents = (__bridge id)piece;
                g.contentsGravity = kCAGravityResize;
                g.frame = CGRectMake(ox + (CGFloat)c * tileW,
                                     oy + (CGFloat)r * tileH,
                                     tileW + 0.6, tileH + 0.6);
                g.masksToBounds = YES;
                g.cornerRadius = 0.0;
                [root addSublayer:g];
                CGImageRelease(piece);
                made++;

                // bottom-left -> top-right front: 0 at bottom-left, 0.36 at top-right
                CGFloat begin = (ux + 1.0 - uy) * 0.18 + r1 * 0.025;
                CGFloat delay = begin * total;                  // 0 .. ~0.5s
                CGFloat dur   = (0.56 + 0.035 * r2) * total;    // ~0.73 - 0.77s

                // drift up-right; slight jitter, no gravity fall. .102: wider
                // per-grain scatter so the field reads as loose fine sand.
                CGFloat dx = (0.62 + 1.05 * r1) * D + (r2 - 0.5) * D * 0.80;
                CGFloat dy = -(0.45 + 1.05 * r2) * D + (r1 - 0.5) * D * 0.35;
                CGFloat endScale = 0.16 + 0.26 * r3;            // 0.16 .. 0.42
                CGFloat endAngle = (r3 - 0.5) * 6.4;             // +-3.2 rad
                CGFloat rad = MIN(tileW, tileH) * 0.5;

                CATransform3D t1 = CATransform3DMakeScale(endScale, endScale, 1.0);
                t1 = CATransform3DRotate(t1, endAngle, 0, 0, 1);

                CABasicAnimation *ta = [CABasicAnimation animationWithKeyPath:@"transform"];
                ta.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
                ta.toValue   = [NSValue valueWithCATransform3D:t1];

                CABasicAnimation *pa = [CABasicAnimation animationWithKeyPath:@"position"];
                CGPoint p0 = g.position;
                pa.fromValue = [NSValue valueWithCGPoint:p0];
                pa.toValue   = [NSValue valueWithCGPoint:CGPointMake(p0.x + dx, p0.y + dy)];

                CAKeyframeAnimation *oa = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
                oa.values = @[@1.0, @1.0, @0.0];
                oa.keyTimes = @[@0.0, @(0.32 + 0.20 * r2), @1.0];

                CABasicAnimation *ra = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
                ra.fromValue = @0.0;
                ra.toValue   = @(rad);

                CAAnimationGroup *grp = [CAAnimationGroup animation];
                grp.animations = @[ta, pa, oa, ra];
                grp.duration = dur;
                grp.beginTime = now + delay;
                grp.fillMode = kCAFillModeForwards;
                grp.removedOnCompletion = NO;
                grp.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                [g addAnimation:grp forKey:@"sand"];
            }
        }
        if (made == 0) {
            axs_dm_log(@"emit: sand no grains, skip");
            overlay.hidden = YES;
            return;
        }

        if (axs_dm_activeOverlays == nil) axs_dm_activeOverlays = [NSMutableArray array];
        [axs_dm_activeOverlays addObject:overlay];
        axs_dm_overlayWindow = overlay;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.8 * speedScale + 0.15) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [root removeFromSuperlayer];
                overlay.hidden = YES;
                [axs_dm_activeOverlays removeObject:overlay];
                if (axs_dm_overlayWindow == overlay) axs_dm_overlayWindow = nil;
            } @catch (NSException *ignored) {
            }
            axs_dm_log(@"emit: sand cleaned grains=%d grid=%dx%d", made, cols, rows);
        });
        axs_dm_log(@"emit: burst cells=%d style=%ld(%@) img=%lux%lu frame=%@ scene=%@",
                   made, (long)style, styleName, (unsigned long)px, (unsigned long)py,
                   NSStringFromCGRect(sourceFrameInWindow),
                   overlay.windowScene ? @"set" : @"NIL");
    } @catch (NSException *e) {
        axs_dm_log(@"emit: sand EXCEPTION %@", [e reason]);
    }
}

// Dice the snapshot into a grid of UIImageViews and fly them outward.
// ROOT CAUSE FIX (beautify.98): on iOS 13+ a UIWindow created with only
// initWithFrame: has no windowScene and therefore renders NOTHING even when
// hidden=NO. That is why the .97 burst executed (logs proved it) but was
// invisible. Using plain UIImageViews instead of CAEmitterLayer also removes
// all the fragile emitter/texture parameter pitfalls.
static void axs_dm_emitParticlesFromView(UIView *sourceView, CGRect sourceFrameInWindow) {
    @try {
        NSInteger style = axs_dm_style();
        NSString *styleName = axs_dm_styleName(style);
        CGFloat speedScale = axs_dm_speedScale();
        // ColorSand: prefer the GPU Metal engine (.104). If Metal is unavailable
        // (old device / compile failure) fall back to the UIView sand field.
        // Either way the original 8 grid-based styles below are untouched.
        if (style == AXSDismissStyleColorSand) {
            UIImage *sandShot = axs_dm_snapshot(sourceView);
            CGFloat sandDuration = 1.30 * speedScale;
            BOOL usedMetal = NO;
            if (sandShot != nil && sandShot.CGImage != nil) {
                usedMetal = axs_metalSandPlay(sandShot, sourceFrameInWindow, sandDuration);
            }
            if (!usedMetal) {
                axs_dm_log(@"sand: metal unavailable, using UIView fallback");
                axs_dm_emitColorSand(sourceView, sourceFrameInWindow, style, styleName);
            } else {
                axs_dm_log(@"sand: metal engine active duration=%.2f", sandDuration);
            }
            return;
        }
        UIImage *shot = axs_dm_snapshot(sourceView);
        if (shot == nil || shot.CGImage == nil) {
            axs_dm_log(@"emit: snapshot failed");
            return;
        }
        CGImageRef full = shot.CGImage;
        NSUInteger px = CGImageGetWidth(full);
        NSUInteger py = CGImageGetHeight(full);
        if (px == 0 || py == 0) {
            axs_dm_log(@"emit: empty snapshot %lux%lu", (unsigned long)px, (unsigned long)py);
            return;
        }

        UIWindow *host = nil;
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { host = w; break; }
            }
            if (host != nil) break;
        }
        if (host == nil) {
            axs_dm_log(@"emit: no key window");
            return;
        }

        UIWindow *overlay = [[UIWindow alloc] initWithFrame:host.bounds];
        if ([overlay respondsToSelector:@selector(setWindowScene:)]) {
            overlay.windowScene = host.windowScene;
        }
        overlay.windowLevel = UIWindowLevelAlert + 500;
        overlay.backgroundColor = [UIColor clearColor];
        overlay.userInteractionEnabled = NO;
        overlay.hidden = NO;

        int cols = 10, rows = 10;
        axs_dm_gridForStyle(style, &cols, &rows);
        CGFloat pieceW = sourceFrameInWindow.size.width / (CGFloat)cols;
        CGFloat pieceH = sourceFrameInWindow.size.height / (CGFloat)rows;
        CGFloat ctrX = CGRectGetMidX(sourceFrameInWindow);
        CGFloat ctrY = CGRectGetMidY(sourceFrameInWindow);

        NSMutableArray *pieces = [NSMutableArray arrayWithCapacity:cols * rows];
        for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
                CGRect crop = CGRectMake((CGFloat)c * (CGFloat)px / (CGFloat)cols,
                                         (CGFloat)r * (CGFloat)py / (CGFloat)rows,
                                         (CGFloat)px / (CGFloat)cols,
                                         (CGFloat)py / (CGFloat)rows);
                CGImageRef piece = CGImageCreateWithImageInRect(full, crop);
                if (piece == NULL) continue;
                UIImage *texture = [UIImage imageWithCGImage:piece
                                                       scale:shot.scale
                                                 orientation:UIImageOrientationUp];
                UIImageView *iv = [[UIImageView alloc] initWithImage:texture];
                iv.frame = CGRectMake(sourceFrameInWindow.origin.x + (CGFloat)c * pieceW,
                                      sourceFrameInWindow.origin.y + (CGFloat)r * pieceH,
                                      pieceW, pieceH);
                iv.tag = r * 1000 + c;
                [overlay addSubview:iv];
                [pieces addObject:iv];
                CGImageRelease(piece);
            }
        }
        int made = (int)pieces.count;
        if (made == 0) {
            axs_dm_log(@"emit: no pieces, skip");
            overlay.hidden = YES;
            return;
        }

        if (axs_dm_activeOverlays == nil) axs_dm_activeOverlays = [NSMutableArray array];
        [axs_dm_activeOverlays addObject:overlay];
        axs_dm_overlayWindow = overlay;

        for (UIImageView *iv in pieces) {
            NSInteger row = iv.tag / 1000;
            CGFloat cx = iv.center.x, cy = iv.center.y;
            CGFloat dx = 0, dy = 0, spin = 0, sc = 1, delay = 0, dur = 0.75;
            UIViewAnimationOptions curve = UIViewAnimationOptionCurveEaseOut;

            switch (style) {
                case AXSDismissStyleGravity: {
                    dx = axs_dm_randRange(-50, 50);
                    dy = axs_dm_randRange(80, 220);
                    spin = axs_dm_randRange(-0.9, 0.9);
                    sc = axs_dm_randRange(0.35, 0.65);
                    delay = axs_dm_randRange(0, 0.15);
                    dur = 1.05; curve = UIViewAnimationOptionCurveEaseIn;
                    break;
                }
                case AXSDismissStyleVortex: {
                    CGFloat vx = ctrX - cx, vy = ctrY - cy;
                    CGFloat len = hypotf(vx, vy); if (len < 1) len = 1;
                    vx /= len; vy /= len;
                    CGFloat pull = len + axs_dm_randRange(20, 80);
                    CGFloat tang = axs_dm_randRange(90, 160);
                    dx = vx * pull - vy * tang;
                    dy = vy * pull + vx * tang;
                    spin = axs_dm_randRange(-3.0, 3.0);
                    sc = 0.0;
                    delay = ((CGFloat)row / (CGFloat)rows) * 0.18;
                    dur = 0.85;
                    break;
                }
                case AXSDismissStyleShockwave: {
                    CGFloat vx = cx - ctrX, vy = cy - ctrY;
                    CGFloat len = hypotf(vx, vy); if (len < 1) len = 1;
                    vx /= len; vy /= len;
                    CGFloat dist = len + axs_dm_randRange(160, 280);
                    dx = vx * dist; dy = vy * dist;
                    spin = 0; sc = 0.2;
                    delay = len / 320.0;
                    dur = 0.7;
                    break;
                }
                case AXSDismissStyleDust: {
                    dx = axs_dm_randRange(-45, 45);
                    dy = axs_dm_randRange(-170, -60);
                    spin = axs_dm_randRange(-0.5, 0.5);
                    sc = axs_dm_randRange(0.15, 0.4);
                    delay = axs_dm_randRange(0, 0.3);
                    dur = 1.25;
                    break;
                }
                case AXSDismissStylePixelDissolve: {
                    dx = 0; dy = 0; spin = 0; sc = 1;
                    delay = axs_dm_randRange(0, 0.7);
                    dur = 0.18;
                    break;
                }
                case AXSDismissStyleBlinds: {
                    dx = (row % 2 == 0) ? 16 : -16;
                    dy = 0; spin = 0; sc = 1;
                    delay = ((CGFloat)row / (CGFloat)(rows > 1 ? rows - 1 : 1)) * 0.6;
                    dur = 0.25;
                    break;
                }
                case AXSDismissStyleGlass: {
                    CGFloat ang = axs_dm_randRange(0, 6.2831853);
                    CGFloat dist = axs_dm_randRange(120, 300);
                    dx = cosf(ang) * dist;
                    dy = sinf(ang) * dist + 90;
                    spin = axs_dm_randRange(-2.6, 2.6);
                    sc = axs_dm_randRange(0.25, 0.5);
                    delay = axs_dm_randRange(0, 0.08);
                    dur = 0.95; curve = UIViewAnimationOptionCurveEaseIn;
                    break;
                }
                default: {
                    CGFloat ang = axs_dm_randRange(0, 6.2831853);
                    CGFloat dist = axs_dm_randRange(100, 320);
                    dx = cosf(ang) * dist;
                    dy = sinf(ang) * dist - 40;
                    spin = axs_dm_randRange(-1.0, 1.0);
                    sc = 0.12;
                    delay = axs_dm_randRange(0, 0.12);
                    dur = 0.75;
                    break;
                }
            }

            // beautify.103: apply the global speed multiplier to every style.
            dur *= speedScale;
            delay *= speedScale;
            [UIView animateWithDuration:dur delay:delay
                                options:curve
                             animations:^{
                if (dx != 0 || dy != 0) {
                    iv.center = CGPointMake(cx + dx, cy + dy);
                }
                iv.transform = CGAffineTransformConcat(
                    CGAffineTransformMakeRotation(spin),
                    CGAffineTransformMakeScale(sc, sc));
                iv.alpha = 0.0;
            } completion:nil];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.5 * speedScale + 0.15) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                for (UIView *v in overlay.subviews) [v removeFromSuperview];
                overlay.hidden = YES;
                [axs_dm_activeOverlays removeObject:overlay];
                if (axs_dm_overlayWindow == overlay) axs_dm_overlayWindow = nil;
            } @catch (NSException *ignored) {
            }
            axs_dm_log(@"emit: cleaned overlay cells=%d", made);
        });
        axs_dm_log(@"emit: burst cells=%d style=%ld(%@) img=%lux%lu frame=%@ scene=%@",
                   made, (long)style, styleName, (unsigned long)px, (unsigned long)py,
                   NSStringFromCGRect(sourceFrameInWindow),
                   overlay.windowScene ? @"set" : @"NIL");
    } @catch (NSException *e) {
        axs_dm_log(@"emit: EXCEPTION %@", [e reason]);
    }
}

static void axs_dm_trigger(NSString *tag) {
    unsigned long long seq = ++axs_dm_seq;
    if (!axs_dm_enabled()) {
        axs_dm_log(@"#%llu %@ disabled by switch", seq, tag);
        return;
    }
    axs_dm_log(@"#%llu %@ enabled, looking for container", seq, tag);
    UIView *container = axs_dm_findContainerView();
    if (container == nil) {
        axs_dm_log(@"#%llu %@ no container view, skip", seq, tag);
        return;
    }
    CGRect frame = [container convertRect:container.bounds toView:nil];
    axs_dm_log(@"#%llu %@ container=%@ frameInWindow=%@",
               seq, tag, NSStringFromClass(container.class), NSStringFromCGRect(frame));
    axs_dm_emitParticlesFromView(container, frame);
}

// --- replacements: original ALWAYS invoked, behaviour unchanged ------------

static IMP axs_orig_closeSession = NULL;
static void axs_dm_closeSession(id self, SEL _cmd, id session) {
    axs_dm_trigger(@"closeSession");
    if (axs_orig_closeSession != NULL) {
        ((void (*)(id, SEL, id))axs_orig_closeSession)(self, _cmd, session);
    }
}

static IMP axs_orig_closeAnimated = NULL;
static void axs_dm_closeAnimated(id self, SEL _cmd, id session, BOOL animated) {
    axs_dm_trigger(@"closeSession:animated:");
    if (axs_orig_closeAnimated != NULL) {
        ((void (*)(id, SEL, id, BOOL))axs_orig_closeAnimated)(self, _cmd, session, animated);
    }
}

static IMP axs_orig_closeAll = NULL;
static void axs_dm_closeAll(id self, SEL _cmd) {
    axs_dm_trigger(@"closeAllSessions");
    if (axs_orig_closeAll != NULL) {
        ((void (*)(id, SEL))axs_orig_closeAll)(self, _cmd);
    }
}

// --- installer --------------------------------------------------------------
static NSMutableSet *axs_dm_hooked = nil;

static Class axs_dm_firstClassDeclaring(SEL sel) {
    Class found = Nil;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes == NULL) return Nil;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        BOOL declared = NO;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == sel) { declared = YES; break; }
        }
        free(ms);
        if (declared) { found = cls; break; }
    }
    free(classes);
    return found;
}

// Verify a method's non-self argument types before hooking, so a signature
// mismatch can never shove a primitive into an id-typed parameter (a known
// crash source in this project). expected encoded as: '@' object, 'B'/'c' bool.
static BOOL axs_dm_sigMatches(Method m, const char *expected, NSUInteger count) {
    if (m == NULL) return NO;
    if (method_getNumberOfArguments(m) != count + 2) return NO;
    for (NSUInteger i = 0; i < count; i++) {
        char *raw = method_copyArgumentType(m, (unsigned int)(i + 2));
        if (raw == NULL) return NO;
        const char *p = raw;
        while (*p && strchr("rnNoORV", *p)) p++;
        char want = expected[i];
        BOOL ok;
        if (want == 'B') ok = (p[0] == 'B' || p[0] == 'c' || p[0] == 'b');
        else ok = (p[0] == '@' || p[0] == '#');
        free(raw);
        if (!ok) return NO;
    }
    return YES;
}

static void axs_dm_install(NSString *name, const char *expectedSig, NSUInteger argCount,
                           IMP replacement, IMP *original, NSString *tag) {
    if ([axs_dm_hooked containsObject:name]) return;
    SEL sel = NSSelectorFromString(name);
    Class cls = axs_dm_firstClassDeclaring(sel);
    if (cls == Nil) {
        axs_dm_log(@"INSTALL %@ selector absent (retry): %@", tag, name);
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    const char *enc = method_getTypeEncoding(m);
    if (!axs_dm_sigMatches(m, expectedSig, argCount)) {
        [axs_dm_hooked addObject:name];  // unexpected signature: skip for good
        axs_dm_log(@"INSTALL %@ SKIPPED signature mismatch enc=%s", tag, enc ? enc : "?");
        return;
    }
    axs_dm_log(@"INSTALL %@ class=%@ enc=%s args=%lu",
               tag, NSStringFromClass(cls), enc ? enc : "?", (unsigned long)argCount);
    MSHookMessageEx(cls, sel, replacement, original);
    [axs_dm_hooked addObject:name];
    axs_dm_log(@"INSTALL %@ HOOKED", tag);
}

static void axs_dm_installAll(void) {
    if (axs_dm_hooked == nil) axs_dm_hooked = [NSMutableSet set];
    axs_dm_install(@"sc_closeSession:", "@", 1,
                   (IMP)axs_dm_closeSession, &axs_orig_closeSession, @"closeSession");
    axs_dm_install(@"sc_closeSession:animated:", "@B", 2,
                   (IMP)axs_dm_closeAnimated, &axs_orig_closeAnimated, @"closeAnimated");
    axs_dm_install(@"sc_closeAllSessions", "", 0,
                   (IMP)axs_dm_closeAll, &axs_orig_closeAll, @"closeAll");
}

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") == nil) return;
        axs_dm_log(@"DME module loaded in SpringBoard (beautify.110, dismiss particles)");
        axs_dm_installAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
    }
}
