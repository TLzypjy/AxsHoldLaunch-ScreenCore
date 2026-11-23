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
BOOL axs_metalSandPlay(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                       uint32_t style, CGFloat density);
BOOL axs_metalAssemblePlay(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                           CGFloat density, CGPoint sourcePoint);
// .140: open assemble returning the live renderer handle + mid-flight texture swap
void *axs_metalAssemblePlayRet(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                               CGFloat density, CGPoint sourcePoint);
BOOL axs_metalReplaceTexture(void *renderer, UIImage *img);
// .131: open assemble returning the live renderer handle (used by the wipe flow)
void *axs_metalAssemblePlayRet(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                               CGFloat density, CGPoint sourcePoint);

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

// beautify.112: particle density multiplier from the panel (0.5..3.0, default
// 1.0). Scales the per-style grain grid; applied inside the Metal renderer.
static CGFloat axs_dm_densityScale(void) {
    CGFloat density = 1.0;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return 1.0;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyDismissDensity", @1.0);
            if ([value isKindOfClass:[NSNumber class]]) {
                density = [value floatValue];
                if (density < 0.5) density = 0.5;
                if (density > 3.0) density = 3.0;
            }
        }
    } @catch (NSException *ignored) {
        density = 1.0;
    }
    if (density <= 0.0 || density != density) density = 1.0;   // NaN / zero guard
    return density;
}

// beautify.112: per-style base timeline (seconds at speed=1). These values are
// mirrored 1:1 inside the Metal vertex shader (begin/span are fractions of
// T0), so the speed slider keeps scaling the whole timeline uniformly.
static CGFloat axs_dm_styleBaseDuration(NSInteger style) {
    switch (style) {
        case AXSDismissStyleGravity:       return 1.20;  // 0.15 delay + 1.05 anim
        case AXSDismissStyleVortex:        return 1.03;  // 0.18 + 0.85
        case AXSDismissStyleShockwave:     return 1.83;  // max 1.13 + 0.70
        case AXSDismissStyleDust:          return 1.55;  // 0.30 + 1.25
        case AXSDismissStylePixelDissolve: return 0.88;  // 0.70 + 0.18
        case AXSDismissStyleBlinds:        return 0.85;  // 0.60 + 0.25
        case AXSDismissStyleGlass:         return 1.03;  // 0.08 + 0.95
        case AXSDismissStyleColorSand:     return 1.30;  // reference sand
        default:                           return 0.87;  // 0.12 + 0.75
    }
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

// --- dissolve effect (GPU) --------------------------------------------------
// beautify.112: ONE GPU path for every style. Snapshot the card, hand it to
// the unified Metal renderer (style + density select the motion model and the
// grain grid), report success so the caller can hide the real card. There is
// intentionally NO CPU fallback anymore: if Metal is unavailable the dissolve
// simply does not play and the card closes natively.
static BOOL axs_dm_emitParticlesFromView(UIView *sourceView, CGRect sourceFrameInWindow) {
    @try {
        NSInteger style = axs_dm_style();
        CGFloat speedScale = axs_dm_speedScale();
        CGFloat density = axs_dm_densityScale();
        UIImage *shot = axs_dm_snapshot(sourceView);
        if (shot == nil || shot.CGImage == nil) {
            axs_dm_log(@"emit: snapshot failed");
            return NO;
        }
        CGFloat duration = axs_dm_styleBaseDuration(style) * speedScale;
        BOOL played = axs_metalSandPlay(shot, sourceFrameInWindow, duration,
                                        (uint32_t)style, density);
        if (played) {
            axs_dm_log(@"emit: gpu engine active style=%ld(%@) duration=%.2f density=%.2f",
                       (long)style, axs_dm_styleName(style), duration, density);
        } else {
            axs_dm_log(@"emit: gpu unavailable, native close only");
        }
        return played;
    } @catch (NSException *e) {
        axs_dm_log(@"emit: EXCEPTION %@", [e reason]);
        return NO;
    }
}

// ---- beautify.140: ARC-open assemble animation ------------------------------
static NSMutableSet *axs_dm_hooked = nil;

// Scope (user decision): only ARC-menu opens for now (fullscreen->floating
// later). There is no known-signature "open" selector on the manager, so we
// detect opens via SCFloatingContainerView visibility transitions instead:
//   * setHidden:NO / didMoveToWindow(on-window) after being gone >= 0.4s
//   * suppressed for 3s after our own dismiss (which hides + restores the card)
// SIGNATURE SAFETY: setHidden:/didMoveToWindow are UIView-inherited. Hooking
// them blindly via MSHookMessageEx would patch UIView itself (global). So:
//   - if the subclass declares the method -> hook at subclass level (safe)
//   - otherwise -> class_addMethod an override that forwards with msgSendSuper
static char axs_open_goneKey;
static CFAbsoluteTime axs_open_lastDismissHide = -1e9;
// .116: our own assemble restores the card (hidden=NO) which would re-trigger
// the open detection -> infinite loop. Flag suppresses exactly that one event.
static BOOL axs_open_selfRestore = NO;
// .116: last finger-lift position (ARC menu tap), tracked via UIWindow sendEvent
static CGPoint axs_open_lastTouchUp = {-1, -1};
static CFAbsoluteTime axs_open_lastTouchUpAt = 0;
// .119: position of the LONG-PRESS that summoned the ARC menu (the icon the
// finger was held down on). Users expect grains to fly from THERE, not from
// the menu item they tap afterwards (which sits mid-screen).
static CGPoint axs_open_arcIconPos = {-1, -1};
static CFAbsoluteTime axs_open_arcIconPosAt = 0;
static IMP axs_open_orig_setHidden = NULL;   // NULL = not installed; (IMP)1 = class_addMethod super-forward
static IMP axs_open_orig_didMove = NULL;

static BOOL axs_open_enabled(void) {
    BOOL on = YES;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return YES;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenAnimEnabled", @YES);
            if ([value isKindOfClass:[NSNumber class]]) on = [value boolValue];
        }
    } @catch (NSException *ignored) {
        on = YES;
    }
    return on;
}

static void axs_open_markGone(UIView *v) {
    objc_setAssociatedObject(v, &axs_open_goneKey, @(CACurrentMediaTime()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// .122: animation-modification window state (declared before first use)
static CFAbsoluteTime axs_open_interceptUntil = 0;
// .125: true while the particle assemble owns the card (hidden from frame 0)
static BOOL axs_open_assembleInFlight = NO;

// .125: independent open-effect controls (like the dismiss has)
static CGFloat axs_open_speedScale(void) {
    CGFloat speed = 1.0;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return 1.0;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenSpeed", @1.0);
            if ([value isKindOfClass:[NSNumber class]]) {
                speed = [value floatValue];
                if (speed < 0.3) speed = 0.3;
                if (speed > 3.0) speed = 3.0;
            }
        }
    } @catch (NSException *ignored) {
        speed = 1.0;
    }
    if (speed <= 0.0 || speed != speed) speed = 1.0;
    return speed;
}

static CGFloat axs_open_density(void) {
    CGFloat density = 1.0;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return 1.0;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenDensity", @1.0);
            if ([value isKindOfClass:[NSNumber class]]) {
                density = [value floatValue];
                if (density < 0.5) density = 0.5;
                if (density > 3.0) density = 3.0;
            }
        }
    } @catch (NSException *ignored) {
        density = 1.0;
    }
    if (density <= 0.0 || density != density) density = 1.0;
    return density;
}

// .134: particle color = the card's background color (pure data read from
// the layer -- no rendering involved). The calculator is dark -> dark
// fragments, exactly like the reference video. Fallback: white.
static UIImage *axs_open_bgTexture(UIView *card) {
    UIColor *col = nil;
    CGFloat r1=0, g1=0, b1=0, a1=0;
    @try {
        CGColorRef bg = card.layer.backgroundColor;
        if (bg != NULL) {
            col = [UIColor colorWithCGColor:bg];
        } else {
            // try the first subview's background
            for (UIView *sv in card.subviews) {
                if (sv.layer.backgroundColor != NULL) {
                    col = [UIColor colorWithCGColor:sv.layer.backgroundColor];
                    break;
                }
            }
        }
        if (col != nil) {
            // .135: a fully transparent (clear) background would make the
            // grains invisible on any page -- fall back to dark gray
            [col getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
            if (a1 < 0.05) col = nil;
        }
    } @catch (NSException *ignored) {
        col = nil;
    }
    if (col == nil) col = [UIColor colorWithWhite:0.15 alpha:0.95];
    CGFloat fr=0, fg=0, fb=0, fa=0;
    [col getRed:&fr green:&fg blue:&fb alpha:&fa];
    axs_dm_log(@"OPEN grain color final %.2f %.2f %.2f %.2f (raw %.2f %.2f %.2f %.2f)",
               fr, fg, fb, fa, r1, g1, b1, a1);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, 1, 1) format:fmt];
    UIImage *tex = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSetFillColorWithColor(ctx.CGContext, col.CGColor);
        CGContextFillRect(ctx.CGContext, CGRectMake(0, 0, 1, 1));
    }];
    return tex;
}

// .134: right-top -> left-bottom wipe reveal. The real card is shown beneath
// the particle cloud with a mask that expands from the top-right corner --
// grains arrive there first, so the wipe keeps in sync with the convergence
// and the window appears to be composed grain by grain.
static void axs_open_startWipeReveal(UIView *card, CGFloat dur, CGPoint sourcePoint) {
    @try {
        CGSize sz = card.bounds.size;
        if (sz.width < 1 || sz.height < 1) return;
        // .139: overscan the mask by 40pt on every side -- the glow layers
        // live OUTSIDE the card bounds on the same layer; a bounds-tight mask
        // would clip them away for good
        CGFloat ov = 40.0;
        // .140: the wipe starts at the corner NEAREST the finger and grows
        // toward the opposite corner (dynamic direction)
        CGPoint srcInCard = [card convertPoint:sourcePoint fromView:nil];
        CGFloat x0 = (srcInCard.x > sz.width * 0.5) ? sz.width + ov : -ov;
        CGFloat y0 = (srcInCard.y > sz.height * 0.5) ? sz.height + ov : -ov;
        UIView *mv = [[UIView alloc] initWithFrame:CGRectMake(x0, y0, 0, 0)];
        mv.backgroundColor = [UIColor blackColor];
        mv.opaque = YES;
        card.layer.mask = mv.layer;
        [UIView animateWithDuration:dur animations:^{
            mv.frame = CGRectMake(-ov, -ov, sz.width + 2 * ov, sz.height + 2 * ov);
        }];
    } @catch (NSException *ignored) { }
}

// .139: remove the mask once the wipe completes -- a lingering mask keeps
// clipping the glow and any later geometry changes (perceived as broken
// gestures)
static void axs_open_endWipeReveal(UIView *card) {
    @try {
        if (card.layer.mask != nil) card.layer.mask = nil;
    } @catch (NSException *ignored) { }
}


// blank probe: samples the alpha channel on a sparse grid
static BOOL axs_dm_imageIsBlank(UIImage *img) {
    if (img == nil || img.CGImage == NULL) return YES;
    CGImageRef cg = img.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return YES;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    size_t bpr = w * 4;
    NSMutableData *data = [NSMutableData dataWithLength:bpr * h];
    CGContextRef ctx = CGBitmapContextCreate([data mutableBytes], w, h, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx == NULL) { CGColorSpaceRelease(cs); return YES; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    const uint8_t *px = (const uint8_t *)[data bytes];
    size_t step = ((w * h) / 256) + 1;
    BOOL anyOpaque = NO;
    for (size_t i = 0; i < w * h; i += step) {
        if (px[i * 4 + 3] > 8) { anyOpaque = YES; break; }
    }
    return !anyOpaque;
}

// .138: THE fix the reference tweak uses -- the floating window content is
// HOSTED from another process, but its layers attach locally under the app
// scene's _UIScenePresentationView in SpringBoard. Capturing THAT view (not
// the card, not the full screen) yields the live app content pixels.
static void axs_open_collectSceneViews(UIView *root, NSMutableArray *outArr, int depth, int *budget) {
    if (root == nil || depth > 6 || (*budget) <= 0) return;
    (*budget)--;
    const char *cn = object_getClassName(root);
    if (strcmp(cn, "_UIScenePresentationView") == 0) [outArr addObject:root];
    for (UIView *sv in root.subviews) axs_open_collectSceneViews(sv, outArr, depth + 1, budget);
}

static UIImage *axs_open_captureAppContent(void) {
    NSMutableArray *cands = [NSMutableArray array];
    int budget = 500;
    @try {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray *wins = [UIApplication sharedApplication].windows;
        #pragma clang diagnostic pop
        for (UIWindow *w in wins) {
            if (w == nil) continue;
            axs_open_collectSceneViews(w, cands, 0, &budget);
        }
    } @catch (NSException *ignored) {
        return nil;
    }
    if (cands.count == 0) return nil;
    // largest first (app scenes are fullscreen-sized)
    [cands sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat aa = a.bounds.size.width * a.bounds.size.height;
        CGFloat bb = b.bounds.size.width * b.bounds.size.height;
        return aa > bb ? NSOrderedAscending : (aa < bb ? NSOrderedDescending : NSOrderedSame);
    }];
    for (UIView *v in cands) {
        UIImage *shot = nil;
        @try {
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.opaque = NO;
            UIGraphicsImageRenderer *r =
                [[UIGraphicsImageRenderer alloc] initWithBounds:v.bounds format:fmt];
            shot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:NO];
            }];
        } @catch (NSException *ignored) {
            shot = nil;
        }
        if (!axs_dm_imageIsBlank(shot)) {
            axs_dm_log(@"OPEN scene capture ok class=%@ size=%@",
                       NSStringFromClass([v class]), NSStringFromCGSize(v.bounds.size));
            return shot;
        }
        @try {
            UIGraphicsImageRenderer *r2 =
                [[UIGraphicsImageRenderer alloc] initWithBounds:v.bounds];
            UIImage *shot2 = [r2 imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [v.layer renderInContext:ctx.CGContext];
            }];
            if (!axs_dm_imageIsBlank(shot2)) {
                axs_dm_log(@"OPEN scene capture ok (renderInContext) class=%@ size=%@",
                           NSStringFromClass([v class]), NSStringFromCGSize(v.bounds.size));
                return shot2;
            }
        } @catch (NSException *ignored) { }
    }
    axs_dm_log(@"OPEN scene capture: %lu candidates all blank", (unsigned long)cands.count);
    return nil;
}

static void axs_open_pollStep(UIView *card, NSInteger polls, CGFloat duration,
                              CGFloat density, CGPoint sourcePoint, NSString *sourceKind) {
    @try {
        if (card.window == nil) {
            axs_dm_log(@"OPEN poll aborted, card left window");
            return;
        }
        CGRect frame = [card convertRect:card.bounds toView:nil];
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        // .130: require >=0.15s of settle time so the app content has a
        // chance to load before the texture is captured
        BOOL settled = (polls >= 5 && frame.size.width > 40.0
                        && frame.size.width < screenW * 0.85);
        if (!settled && polls < 15) {
            __weak UIView *weakCard = card;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *c = weakCard;
                if (c == nil) return;
                axs_open_pollStep(c, polls + 1, duration, density, sourcePoint, sourceKind);
            });
            return;
        }
        if (!settled) {
            axs_dm_log(@"OPEN frame never settled, native card restored");
            axs_open_assembleInFlight = NO;
            axs_open_selfRestore = YES;
            card.hidden = NO;
            return;
        }
        // .140: start the grains IMMEDIATELY with the fallback color (no
        // capture wait), capture the app scene view in parallel, and swap the
        // texture mid-flight when the real content is ready.
        UIImage *dots = axs_open_bgTexture(card);
        if (dots == nil) {
            axs_dm_log(@"OPEN bg texture failed, native card restored");
            axs_open_assembleInFlight = NO;
            axs_open_selfRestore = YES;
            card.hidden = NO;
            return;
        }
        void *renderer = axs_metalAssemblePlayRet(dots, frame, duration, density, sourcePoint);
        if (renderer == NULL) {
            axs_open_assembleInFlight = NO;
            axs_open_selfRestore = YES;
            card.hidden = NO;
            axs_dm_log(@"OPEN assemble unavailable, native card restored");
            return;
        }
        axs_dm_log(@"OPEN assemble started duration=%.2f density=%.2f polls=%ld source=%@ (%@)",
                   duration, density, (long)polls,
                   NSStringFromCGPoint(sourcePoint), sourceKind);
        // .137/.140: wipe reveal in sync with the convergence
        __weak UIView *weakCard2 = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCard2;
            if (c == nil) return;
            @try {
                if (c.window == nil) return;
                axs_open_assembleInFlight = NO;
                axs_open_selfRestore = YES;
                c.hidden = NO;
                axs_open_startWipeReveal(c, duration, sourcePoint);
                // .139: drop the mask when the wipe completes, otherwise it
                // lingers and clips the glow / later geometry changes
                __weak UIView *weakCard3 = c;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIView *c3 = weakCard3;
                    if (c3 == nil) return;
                    axs_open_endWipeReveal(c3);
                });
            } @catch (NSException *ignored) {
                axs_open_assembleInFlight = NO;
                c.hidden = NO;
            }
        });
        // .140: parallel scene capture -> mid-flight texture swap
        __block void *weakRenderer = renderer;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCard2;
            if (c == nil) { weakRenderer = NULL; return; }
            @try {
                if (c.window == nil) { weakRenderer = NULL; return; }
                UIImage *tex = axs_open_captureAppContent();
                NSString *texKind = tex ? @"scene-presentation" : nil;
                if (tex != nil) {
                    BOOL swapped = axs_metalReplaceTexture(weakRenderer, tex);
                    axs_dm_log(@"OPEN texture swap %@ (%@)",
                               swapped ? @"OK" : @"FAILED", texKind ?: @"none");
                } else {
                    axs_dm_log(@"OPEN scene capture blank, keeping fallback grains");
                }
                weakRenderer = NULL;
            } @catch (NSException *ignored) {
                weakRenderer = NULL;
            }
        });
        return;
    } @catch (NSException *ignored) {
        axs_open_assembleInFlight = NO;
        card.hidden = NO;
    }
}

static void axs_open_becameVisible(UIView *v) {
    @try {
        if (axs_open_selfRestore) {
            axs_open_selfRestore = NO;
            axs_dm_log(@"OPEN candidate skipped (self restore)");
            return;
        }
        if (v.window == nil) return;
        if (v.bounds.size.width < 40 || v.bounds.size.height < 40) return;
        CFAbsoluteTime nowT = CACurrentMediaTime();
        NSNumber *gone = objc_getAssociatedObject(v, &axs_open_goneKey);
        CGFloat goneAt = gone ? [gone doubleValue] : -1e9;
        if (nowT - goneAt < 0.4) {
            axs_dm_log(@"OPEN candidate skipped (quick toggle %.2fs)", nowT - goneAt);
            return;
        }
        if (!axs_open_enabled()) {
            axs_dm_log(@"OPEN candidate ignored (switch off)");
            return;
        }
        axs_dm_log(@"OPEN candidate accepted frame=%@",
                   NSStringFromCGRect([v convertRect:v.bounds toView:nil]));
        UIView *card = v;
        axs_open_interceptUntil = CACurrentMediaTime() + 3.0;
        CGFloat density = axs_open_density();
        CGFloat duration = 0.85 / axs_open_speedScale();
        CGPoint sourcePoint = CGPointMake(CGRectGetMidX([card convertRect:card.bounds toView:nil]),
                                          CGRectGetMidY([card convertRect:card.bounds toView:nil]));
        NSString *sourceKind = @"fallback-card-center";
        if (nowT - axs_open_arcIconPosAt <= 4.0
            && axs_open_arcIconPos.x >= 0 && axs_open_arcIconPos.y >= 0) {
            sourcePoint = axs_open_arcIconPos;
            sourceKind = @"arc-icon";
        } else if (nowT - axs_open_lastTouchUpAt <= 2.0
            && axs_open_lastTouchUp.x >= 0 && axs_open_lastTouchUp.y >= 0) {
            sourcePoint = axs_open_lastTouchUp;
            sourceKind = @"last-lift";
        }
        axs_dm_log(@"OPEN source point %@ (%@)", NSStringFromCGPoint(sourcePoint), sourceKind);
        // .122: hide from frame 0 (invisible). The native present animation is
        // NOT intercepted -- it still runs and its completions still fire, but
        // the addAnimation hook clamps its duration to 0.01s so it finishes
        // instantly behind our particles (see axs_open_addAnimation).
        // .123: the whole flow runs OUTSIDE the UIKit window-setup stack and
        // the poll uses weak captures only (see axs_open_pollStep) -- no
        // block-copy of strong view captures anywhere.
        card.hidden = YES;
        axs_open_assembleInFlight = YES;
        axs_open_pollStep(card, 0, duration, density, sourcePoint, sourceKind);
    } @catch (NSException *ignored) { }
}

static void axs_open_setHidden(id self, SEL _cmd, BOOL hidden) {
    if (axs_open_orig_setHidden == (IMP)1) {
        struct objc_super sup = { (id)self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, hidden);
    } else if (axs_open_orig_setHidden != NULL) {
        ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(self, _cmd, hidden);
    }
    UIView *v = (UIView *)self;
    if (hidden) {
        axs_open_markGone(v);
        return;
    }
    // .125: if the native present just made the card visible while our
    // particle assemble is in flight (the assemble hides it at frame 0),
    // snap it back to hidden synchronously -- one property call, no blocks,
    // safe inside the UIKit stack (proven by .119). This removes every
    // visible native-animation frame; the async flow continues below.
    if (axs_open_assembleInFlight && !axs_open_selfRestore
        && axs_open_enabled()) {
        axs_open_markGone(v);
        if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(self, _cmd, YES);
        } else if (axs_open_orig_setHidden == (IMP)1) {
            struct objc_super sup = { (id)self, class_getSuperclass(object_getClass(self)) };
            ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, YES);
        }
        return;
    }
    axs_open_becameVisible(v);
}

static void axs_open_didMoveToWindow(id self, SEL _cmd) {
    if (axs_open_orig_didMove == (IMP)1) {
        struct objc_super sup = { (id)self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
    } else if (axs_open_orig_didMove != NULL) {
        ((void (*)(id, SEL))axs_open_orig_didMove)(self, _cmd);
    }
    UIView *v = (UIView *)self;
    if (v.window == nil) axs_open_markGone(v);
    else axs_open_becameVisible(v);
}

// subclass-safe install: hook the method at SCFloatingContainerView level only
static void axs_open_installOne(NSString *selName, const char *types,
                                IMP newImp, IMP *origOut, NSString *tag) {
    if ([axs_dm_hooked containsObject:tag]) return;
    Class cls = objc_getClass("SCFloatingContainerView");
    if (cls == Nil) return;   // class not loaded yet -> retried by installAll
    SEL sel = NSSelectorFromString(selName);
    Method own = NULL;
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        if (method_getName(ms[i]) == sel) { own = ms[i]; break; }
    }
    free(ms);
    if (own != NULL) {
        axs_dm_log(@"OPEN INSTALL %@ on SCFloatingContainerView (declared, enc=%s)",
                   selName, method_getTypeEncoding(own) ? method_getTypeEncoding(own) : "?");
        MSHookMessageEx(cls, sel, newImp, origOut);
    } else {
        if (!class_addMethod(cls, sel, newImp, types)) return;   // race: retry next pass
        *origOut = (IMP)1;   // marker: replacement must forward via msgSendSuper
        axs_dm_log(@"OPEN INSTALL %@ added override on SCFloatingContainerView (super-forward)", selName);
    }
    [axs_dm_hooked addObject:tag];
}

// .116: track the last finger-lift point anywhere in SpringBoard. UIWindow
// declares sendEvent: itself, so a class-level MSHook here is safe (no
// inherited-method pitfall). Purely passive: forward, then record.
static CGPoint axs_open_touchBeganPos = {-1, -1};
static CFAbsoluteTime axs_open_touchBeganAt = 0;
// .122: per the user's direction, the native present animation is not
// intercepted/covered -- it is MODIFIED: while an open is in flight, any
// CAAnimation added to the card's layer tree gets its duration clamped to
// 0.01s and is then forwarded unchanged. The animation still runs and its
// completion handlers still fire (ScreenCore state machine untouched), it
// just completes instantly and invisibly behind the particle assemble.
static IMP axs_open_orig_addAnimation = NULL;
// .127: REPLACE the native animation entirely. Per the user's direction the
// native animation is no longer clamped-and-run -- it is swallowed (never
// forwarded, zero execution) and its completion is fired manually, so
// ScreenCore's state machine still receives "animation finished". The
// particle assemble fully takes the native animation's place.
static void axs_open_addAnimation(id self, SEL _cmd, CAAnimation *anim, NSString *key) {
    @try {
        if (anim != nil && CACurrentMediaTime() < axs_open_interceptUntil) {
            // match by the layer's delegate (view-backed layers carry their
            // view as delegate) so the replace is armed before the card
            // pointer even exists. Only the floating container's tree is hit.
            id delegate = [(CALayer *)self delegate];
            if (delegate != nil
                && strcmp(object_getClassName(delegate), "SCFloatingContainerView") == 0) {
                // fire the animation's own completion manually (finished=YES):
                // UIView block animations attach their completion block to the
                // CAAnimation's delegate, so this is exactly the notification
                // UIKit would deliver when the animation finishes naturally.
                id animDelegate = [anim delegate];
                if (animDelegate != nil
                    && [animDelegate respondsToSelector:@selector(animationDidStop:finished:)]) {
                    __block id d = animDelegate;
                    __block CAAnimation *a = anim;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            ((void (*)(id, SEL, CAAnimation *, BOOL))objc_msgSend)(
                                d, @selector(animationDidStop:finished:), a, YES);
                        } @catch (NSException *ignored) { }
                        d = nil; a = nil;
                    });
                }
                axs_dm_log(@"OPEN native animation replaced anim=%@ key=%@",
                           NSStringFromClass([anim class]), key ?: @"nil");
                return;   // swallowed -- the native animation never executes
            }
        }
    } @catch (NSException *ignored) { }
    if (axs_open_orig_addAnimation != NULL) {
        ((void (*)(id, SEL, CAAnimation *, NSString *))axs_open_orig_addAnimation)(self, _cmd, anim, key);
    }
}

static void axs_open_installAnimationHook(void) {
    if ([axs_dm_hooked containsObject:@"OPEN:addAnimation"]) return;
    Class cls = objc_getClass("CALayer");
    if (cls == Nil) return;
    SEL sel = NSSelectorFromString(@"addAnimation:forKey:");
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    axs_dm_log(@"OPEN INSTALL addAnimation:forKey: on CALayer enc=%s", method_getTypeEncoding(m));
    MSHookMessageEx(cls, sel, (IMP)axs_open_addAnimation, &axs_open_orig_addAnimation);
    [axs_dm_hooked addObject:@"OPEN:addAnimation"];
}

static IMP axs_open_orig_sendEvent = NULL;
static void axs_open_sendEvent(id self, SEL _cmd, UIEvent *event) {
    if (axs_open_orig_sendEvent != NULL) {
        ((void (*)(id, SEL, UIEvent *))axs_open_orig_sendEvent)(self, _cmd, event);
    }
    @try {
        if (event == nil || [event type] != UIEventTypeTouches) return;
        UITouch *t = [event allTouches].anyObject;
        if (t == nil) return;
        UIView *touchView = [t view];
        UIWindow *win = touchView.window ?: (UIWindow *)self;
        CGPoint loc = [t locationInView:win];
        if ([t phase] == UITouchPhaseBegan) {
            axs_open_touchBeganPos = loc;
            axs_open_touchBeganAt = CACurrentMediaTime();
        } else if ([t phase] == UITouchPhaseEnded) {
            axs_open_lastTouchUp = loc;
            axs_open_lastTouchUpAt = CACurrentMediaTime();
            // .124: arm the animation-clamp window EARLY. The ARC tap -> menu ->
            // present sequence adds the native animations BEFORE becameVisible
            // runs, so arming only there missed them entirely (.123). The
            // filter inside the hook matches by layer delegate class name, so
            // no card pointer is needed yet.
            axs_open_interceptUntil = CACurrentMediaTime() + 5.0;
            // a long press (>=0.15s hold, matches the ARC trigger duration
            // setting) on one spot = the finger was held on the ARC icon.
            CGFloat held = CACurrentMediaTime() - axs_open_touchBeganAt;
            CGFloat moved = hypotf((float)(loc.x - axs_open_touchBeganPos.x),
                                   (float)(loc.y - axs_open_touchBeganPos.y));
            if (held >= 0.15 && moved < 30.0) {
                axs_open_arcIconPos = axs_open_touchBeganPos;
                axs_open_arcIconPosAt = CACurrentMediaTime();
            }
        }
    } @catch (NSException *ignored) { }
}

static void axs_open_installTouchTracking(void) {
    if ([axs_dm_hooked containsObject:@"OPEN:sendEvent"]) return;
    Class cls = objc_getClass("UIWindow");
    if (cls == Nil) return;
    SEL sel = NSSelectorFromString(@"sendEvent:");
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    axs_dm_log(@"OPEN INSTALL sendEvent: on UIWindow enc=%s", method_getTypeEncoding(m));
    MSHookMessageEx(cls, sel, (IMP)axs_open_sendEvent, &axs_open_orig_sendEvent);
    [axs_dm_hooked addObject:@"OPEN:sendEvent"];
}

static void axs_open_installAll(void) {
    axs_open_installOne(@"setHidden:", "v20@0:8B16",
                        (IMP)axs_open_setHidden, &axs_open_orig_setHidden, @"OPEN:setHidden:");
    axs_open_installOne(@"didMoveToWindow", "v16@0:8",
                        (IMP)axs_open_didMoveToWindow, &axs_open_orig_didMove, @"OPEN:didMove");
    axs_open_installTouchTracking();
    axs_open_installAnimationHook();
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
    BOOL played = axs_dm_emitParticlesFromView(container, frame);
    if (played) {
        // .111: hide the real card so ScreenCore's own close animation (card
        // sliding/shrinking toward the bottom-right corner) does not double-
        // expose behind the dissolving snapshot. The container is being closed
        // anyway; hiding it does not interrupt the native animation or its
        // completion handlers -- it just keeps them off-screen.
        container.hidden = YES;
        axs_open_lastDismissHide = CACurrentMediaTime();   // suppress the open hook on our own restore
        axs_dm_log(@"#%llu %@ card hidden behind dissolve", seq, tag);
        // safety net: restore visibility once the dissolve is fully cleaned up,
        // in case ScreenCore reuses this container view for a future session.
        CGFloat sp = axs_dm_speedScale();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.9 * sp + 0.3) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                // .124: precise event-level suppression of the open detector
                // (replaces the old 3s time window the user asked to remove)
                axs_open_selfRestore = YES;
                container.hidden = NO;
            } @catch (NSException *ignored) { }
        });
    }
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
    // beautify.140: ARC-open assemble hooks (class may load later -> retried)
    axs_open_installAll();
}

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") == nil) return;
        axs_dm_log(@"DME module loaded in SpringBoard (beautify.140, dismiss+open)");
        axs_dm_installAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
    }
}
