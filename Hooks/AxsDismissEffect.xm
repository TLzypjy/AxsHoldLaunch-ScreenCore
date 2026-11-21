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

// ---------------------------------------------------------------------------
// beautify.100 - 9th style: ColorSand. Reproduces the iOS notification swipe
// clear effect from the reference video: the card stays put and "sandifies"
// into a dense field of fine pastel grains (pink/purple/blue/white) that drift
// UP and to the RIGHT, while the card snapshot fades out as a whole (no scale,
// no spin, no fall-back gravity). The 8 existing styles are untouched.
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

// beautify.100: pastel "sand" dissolve, matching the reference video where a
// dismissed iOS notification banner keeps its place and turns into a dense
// field of fine pink/purple/blue/white grains drifting UP and to the RIGHT.
// Plain UIViews (no CAEmitterLayer) on the same windowScene-bound overlay as
// every other style, so it inherits the .98 visibility fix.
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

        // Base layer: the whole card fades where it stands. It drifts slightly
        // up-right but never scales away or spins -- the video shows the body
        // dissolving in place, not shrinking to a point.
        UIImageView *base = [[UIImageView alloc] initWithImage:shot];
        base.frame = sourceFrameInWindow;
        base.contentMode = UIViewContentModeScaleToFill;
        [overlay addSubview:base];

        NSArray *sandColors = @[
            [UIColor colorWithRed:0.957 green:0.659 blue:0.816 alpha:1.0], // pink
            [UIColor colorWithRed:0.725 green:0.627 blue:0.910 alpha:1.0], // purple
            [UIColor colorWithRed:0.561 green:0.722 blue:0.918 alpha:1.0], // blue
            [UIColor colorWithRed:0.937 green:0.918 blue:0.969 alpha:1.0], // white
            [UIColor colorWithRed:0.659 green:0.847 blue:0.816 alpha:1.0], // mint
        ];

        NSMutableArray *grains = [NSMutableArray arrayWithCapacity:360];
        for (int i = 0; i < 360; i++) {
            CGFloat gs = axs_dm_randRange(1.2, 3.2);
            CGFloat gx = sourceFrameInWindow.origin.x
                       + axs_dm_randRange(0, sourceFrameInWindow.size.width);
            CGFloat gy = sourceFrameInWindow.origin.y
                       + axs_dm_randRange(0, sourceFrameInWindow.size.height);
            UIView *g = [[UIView alloc] initWithFrame:CGRectMake(gx, gy, gs, gs)];
            g.backgroundColor = [sandColors objectAtIndex:arc4random_uniform((uint32_t)sandColors.count)];
            g.layer.cornerRadius = gs * 0.5;
            g.alpha = axs_dm_randRange(0.55, 1.0);
            [overlay addSubview:g];
            [grains addObject:g];
        }
        int made = (int)grains.count;
        if (made == 0) {
            axs_dm_log(@"emit: sand no grains, skip");
            overlay.hidden = YES;
            return;
        }

        if (axs_dm_activeOverlays == nil) axs_dm_activeOverlays = [NSMutableArray array];
        [axs_dm_activeOverlays addObject:overlay];
        axs_dm_overlayWindow = overlay;

        // Card body: gentle up-right drift + whole-image fade, ~0.6s.
        CGPoint baseCtr = base.center;
        [UIView animateWithDuration:0.6 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            base.center = CGPointMake(baseCtr.x + 40, baseCtr.y - 40);
            base.alpha = 0.0;
        } completion:nil];

        // Grains: drift up and to the RIGHT (dx > 0, dy < 0), no gravity fall.
        for (UIView *g in grains) {
            CGFloat cx = g.center.x, cy = g.center.y;
            CGFloat dx = axs_dm_randRange(30, 130);
            CGFloat dy = axs_dm_randRange(-170, -60);
            CGFloat delay = axs_dm_randRange(0, 0.22);
            CGFloat dur = axs_dm_randRange(0.6, 1.0);
            [UIView animateWithDuration:dur delay:delay
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                g.center = CGPointMake(cx + dx, cy + dy);
                g.alpha = 0.0;
            } completion:nil];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                for (UIView *v in overlay.subviews) [v removeFromSuperview];
                overlay.hidden = YES;
                [axs_dm_activeOverlays removeObject:overlay];
                if (axs_dm_overlayWindow == overlay) axs_dm_overlayWindow = nil;
            } @catch (NSException *ignored) {
            }
            axs_dm_log(@"emit: sand cleaned grains=%d", made);
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
        // ColorSand uses its own grain-field engine; do not touch the original
        // 8 grid-based styles below.
        if (style == AXSDismissStyleColorSand) {
            axs_dm_emitColorSand(sourceView, sourceFrameInWindow, style, styleName);
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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
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
        axs_dm_log(@"DME module loaded in SpringBoard (beautify.97, dismiss particles)");
        axs_dm_installAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
    }
}
