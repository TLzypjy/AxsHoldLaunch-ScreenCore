#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <dlfcn.h>
#include <stdint.h>

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
// .188: choose which compiled shader pipeline the open pass uses.
void axs_msd_setCoverMode(BOOL on);
void axs_msd_setCornerKill(uint32_t on, float radius);
BOOL axs_metalReplaceTexture(void *renderer, UIImage *img);
// .155: exact shared clock of the running open renderer.
CFTimeInterval axs_metalAssembleStartTime(void *renderer);
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

// .158: the card's remote (cross-process) content cannot be rasterized while
// the card is hidden -- the open-time capture retries all came back blank
// (log(46): "gpu texture never captured, deposit stays off"), so the GPU
// deposit pass never had real texels and the card popped in only after the
// dust finished. The card IS fully capturable while visible (the dismiss
// snapshot succeeds on every single close), so keep the latest visible-card
// snapshot around and reuse it as the deposit texture at the next open.
// Refresh points: every dismiss (texture creation) and 0.35s after every
// open completes (the card is visible again by then).
// .160 lesson: an associated-object cache on the container view DIES with
// the view -- ScreenCore recreates SCFloatingContainerView between close and
// open, so log(49) showed the refresh succeeding but the next open reading
// nothing. .161: key the cache by the WINDOW's bundle identity, which
// survives view recreation: try container.session.bundleIdentifier, then a
// manager.sessionsByBundleID lookup through the container's delegate, then
// sceneIdentifier / containerIdentifier; geometry is the last resort.
static NSMutableDictionary *axs_open_snapshotCache = nil;

static NSString *axs_open_cacheDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = @"/var/mobile/Library/Caches/sc-open-cache";
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        // .187: migrate any snapshots stored under the old Documents path so
        // nothing is lost when upgrading from .168-era builds.
        NSString *oldDir = @"/var/mobile/Documents/sc-open-cache";
        NSArray *old = [fm contentsOfDirectoryAtPath:oldDir error:NULL];
        for (NSString *fl in old) {
            if (![fl.pathExtension isEqualToString:@"png"]) continue;
            NSString *dst = [dir stringByAppendingPathComponent:fl];
            if (![fm fileExistsAtPath:dst]) {
                [fm moveItemAtPath:[oldDir stringByAppendingPathComponent:fl]
                            toPath:dst
                             error:NULL];
            }
        }
        if ([old count] == 0 || [fm contentsOfDirectoryAtPath:oldDir error:NULL].count == 0) {
            [fm removeItemAtPath:oldDir error:NULL];
        }
    });
    return dir;
}

static NSString *axs_open_windowKeyForView(UIView *view) {
    @try {
        if (view == nil) return nil;
        id session = nil;
        @try { session = [view valueForKey:@"session"]; } @catch (NSException *ignored) { }
        NSMutableArray *cands = [NSMutableArray arrayWithObject:view];
        if (session != nil) [cands addObject:session];
        for (id obj in cands) {
            if (obj == nil) continue;
            for (NSString *key in @[@"bundleIdentifier", @"bundleID", @"bundleId",
                                     @"sceneIdentifier", @"containerIdentifier"]) {
                NSString *val = nil;
                @try { val = [obj valueForKey:key]; } @catch (NSException *ignored) { }
                if ([val isKindOfClass:[NSString class]] && val.length > 0) return val;
            }
        }
        id mgr = nil;
        @try { mgr = [view valueForKey:@"delegate"]; } @catch (NSException *ignored) { }
        if (mgr != nil) {
            NSDictionary *byBundle = nil;
            @try { byBundle = [mgr valueForKey:@"sessionsByBundleID"]; } @catch (NSException *ignored) { }
            if ([byBundle isKindOfClass:[NSDictionary class]]) {
                for (NSString *bid in byBundle) {
                    id sess = byBundle[bid];
                    if (sess == nil) continue;
                    id cv = nil;
                    @try { cv = [sess valueForKey:@"containerView"]; } @catch (NSException *ignored) { }
                    if (cv == view) return bid;
                    id rec = nil;
                    @try { rec = [sess valueForKey:@"record"]; } @catch (NSException *ignored) { }
                    id rcv = nil;
                    @try { rcv = [rec valueForKey:@"containerView"]; } @catch (NSException *ignored) { }
                    if (rcv == view) return bid;
                }
            }
        }
    } @catch (NSException *ignored) { }
    CGRect f = view.frame;
    return [NSString stringWithFormat:@"geom-%.0fx%.0f", f.size.width, f.size.height];
}

static void axs_open_cacheCardSnapshot(UIView *owner, UIImage *img) {
    @try {
        if (owner == nil || img == nil || img.CGImage == NULL) return;
        if (CGImageGetWidth(img.CGImage) < 256 || CGImageGetHeight(img.CGImage) < 256) return;
        NSString *key = axs_open_windowKeyForView(owner);
        if (key == nil) return;
        if (axs_open_snapshotCache == nil) axs_open_snapshotCache = [NSMutableDictionary new];
        axs_open_snapshotCache[key] = img;
        axs_dm_log(@"OPEN snapshot cached key=%@ %zux%zu", key,
                   (size_t)CGImageGetWidth(img.CGImage),
                   (size_t)CGImageGetHeight(img.CGImage));
        // .168: persist per window so even the first open after a respring
        // has the last-known content (the accept-time capture usually comes
        // back blank because the remote content is not attached yet).
        NSString *pngPath = [[axs_open_cacheDir()
                              stringByAppendingPathComponent:key]
                             stringByAppendingPathExtension:@"png"];
        UIImage *pngImg = img;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                NSData *png = UIImagePNGRepresentation(pngImg);
                if (png != nil) [png writeToFile:pngPath atomically:YES];
            } @catch (NSException *ignored) { }
        });
    } @catch (NSException *ignored) { }
}

static UIImage *axs_open_cachedCardSnapshotForView(UIView *owner) {
    @try {
        if (owner == nil) return nil;
        NSString *key = axs_open_windowKeyForView(owner);
        if (key == nil) return nil;
        UIImage *img = axs_open_snapshotCache[key];
        // .168: memory miss -> load the persisted snapshot from disk once.
        if (img == nil) {
            NSString *pngPath = [[axs_open_cacheDir()
                                  stringByAppendingPathComponent:key]
                                 stringByAppendingPathExtension:@"png"];
            img = [UIImage imageWithContentsOfFile:pngPath];
            if (img != nil) {
                axs_open_snapshotCache[key] = img;
                axs_dm_log(@"OPEN snapshot loaded from disk key=%@ %zux%zu", key,
                           (size_t)CGImageGetWidth(img.CGImage),
                           (size_t)CGImageGetHeight(img.CGImage));
            }
        }
        if (img == nil || img.CGImage == NULL) return nil;
        if (CGImageGetWidth(img.CGImage) < 256 || CGImageGetHeight(img.CGImage) < 256) return nil;
        return img;
    } @catch (NSException *ignored) {
        return nil;
    }
}

static BOOL axs_dm_imageIsBlank(UIImage *img);   // defined later in this file
static UIImage *axs_dm_roundSnapshot(UIImage *img, UIView *refView);   // defined later in this file
static UIImage *axs_dm_fixSnapshotCorners(UIImage *img, UIView *refView);   // defined later in this file


// .158: cheap 1x-scale capture of a VISIBLE card (no unhide games needed).
static UIImage *axs_open_captureVisibleCardCheap(UIView *card) {
    UIImage *shot = nil;
    @try {
        if (card == nil || card.hidden || card.window == nil) return nil;
        // .168: device scale -- a 1x capture stretched across the 3x screen
        // made the deposited corners soft, which read as a corner morph at
        // the handoff. Card-size rasters are cheap (the dismiss capture does
        // the same work on every close).
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:card.bounds format:fmt];
        shot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [card drawViewHierarchyInRect:card.bounds afterScreenUpdates:NO];
        }];
    } @catch (NSException *ignored) {
        return nil;
    }
    if (shot != nil && axs_dm_imageIsBlank(shot)) return nil;
    return axs_dm_fixSnapshotCorners(shot, card);
}

// .166: the floating container's own layer is square; the rounded corner
// radius lives on an inner content layer. A raw snapshot therefore carries
// square dark corners, which the GPU deposit tiles and the dissolve overlay
// paint around the rounded card as a right-angle glow. Re-render the image
// through a rounded-rect clip whose radius is read from the view's layer
// tree (container layer first, then the largest subview radius).
static void axs_dm_scanLayers(CALayer *layer, int depth, CGFloat *best, CGFloat *bgRadius) {
    if (layer == nil || depth > 4) return;
    @try {
        CGFloat r = layer.cornerRadius;
        if (r >= 1.0) {
            if (r > *best) *best = r;
            // the layer that actually paints the rounded card background is
            // the one whose radius matches what the user sees on screen
            if (layer.backgroundColor != NULL && *bgRadius < 1.0) *bgRadius = r;
        }
        for (CALayer *sub in layer.sublayers) {
            axs_dm_scanLayers(sub, depth + 1, best, bgRadius);
        }
    } @catch (NSException *ignored) { }
}

static CGFloat axs_dm_cornerRadiusForView(UIView *view) {
    @try {
        if (view == nil) return 0.0;
        CGFloat best = 0.0;
        CGFloat bgRadius = 0.0;
        axs_dm_scanLayers(view.layer, 0, &best, &bgRadius);
        return (bgRadius >= 1.0) ? bgRadius : best;
    } @catch (NSException *ignored) {
        return 0.0;
    }
}

// .167: save + clear the view's square backgrounds so the rounded content
// shape rasterizes with TRUE alpha corners (exact radius, no morphing at the
// handoffs). Only square layers (cornerRadius < 1) are cleared; the rounded
// background layers are left alone. Restore with axs_dm_restoreViewBackgrounds.
static void axs_dm_clearViewBackgrounds(UIView *view, NSMutableArray *saved) {
    @try {
        if (view.backgroundColor != nil) {
            [saved addObject:view.backgroundColor];
            view.backgroundColor = nil;
        } else {
            [saved addObject:[NSNull null]];
        }
        if (view.layer.cornerRadius < 1.0 && view.layer.backgroundColor != NULL) {
            [saved addObject:(__bridge id)view.layer.backgroundColor];
            view.layer.backgroundColor = NULL;
        } else {
            [saved addObject:[NSNull null]];
        }
    } @catch (NSException *ignored) { }
}

static void axs_dm_restoreViewBackgrounds(UIView *view, NSMutableArray *saved) {
    @try {
        if (saved.count < 2) return;
        id vbg = saved[0];
        view.backgroundColor = (vbg == [NSNull null]) ? nil : (UIColor *)vbg;
        id lbg = saved[1];
        view.layer.backgroundColor = (lbg == [NSNull null])
            ? NULL : (__bridge CGColorRef)lbg;
    } @catch (NSException *ignored) { }
}

// true-corner probe: are the four corners of the image opaque?
static BOOL axs_dm_cornersAreOpaque(UIImage *img) {
    @try {
        if (img == nil || img.CGImage == NULL) return NO;
        CGImageRef cg = img.CGImage;
        size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
        if (w == 0 || h == 0) return NO;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        size_t bpr = w * 4;
        NSMutableData *data = [NSMutableData dataWithLength:bpr * h];
        CGContextRef ctx = CGBitmapContextCreate([data mutableBytes], w, h, 8, bpr, cs,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        if (ctx == NULL) { CGColorSpaceRelease(cs); return NO; }
        CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        const uint8_t *px = (const uint8_t *)[data bytes];
        size_t pts[4][2] = {{2,2},{w-3,2},{2,h-3},{w-3,h-3}};
        for (int i = 0; i < 4; i++) {
            size_t x = pts[i][0], y = pts[i][1];
            if (px[(y * w + x) * 4 + 3] > 8) return YES;
        }
        return NO;
    } @catch (NSException *ignored) {
        return NO;
    }
}

// .167 final corner handling: true alpha corners win (exact radius); the
// .166 radius clip is only the fallback for snapshots whose corners stayed
// opaque despite the background clearing.
static UIImage *axs_dm_fixSnapshotCorners(UIImage *img, UIView *refView) {
    if (img == nil || img.CGImage == NULL) return img;
    BOOL opaque = axs_dm_cornersAreOpaque(img);
    CGFloat radius = axs_dm_cornerRadiusForView(refView);
    axs_dm_log(@"snapshot corners opaque=%d radius=%.1f %zux%zu",
               opaque, radius,
               (size_t)CGImageGetWidth(img.CGImage),
               (size_t)CGImageGetHeight(img.CGImage));
    if (!opaque) return img;
    return axs_dm_roundSnapshot(img, refView);
}

static UIImage *axs_dm_roundSnapshot(UIImage *img, UIView *refView) {
    @try {
        if (img == nil || img.CGImage == NULL) return img;
        CGFloat radius = axs_dm_cornerRadiusForView(refView);
        if (radius < 1.0) return img;
        CGSize sz = img.size;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        fmt.scale = img.scale;
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, sz.width, sz.height) format:fmt];
        UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            UIBezierPath *clip =
                [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height)
                                           cornerRadius:radius];
            [clip addClip];
            [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        }];
        return out;
    } @catch (NSException *ignored) {
        return img;
    }
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
        NSMutableArray *savedBg = [NSMutableArray array];
        axs_dm_clearViewBackgrounds(sourceView, savedBg);
        UIImage *shot = axs_dm_snapshot(sourceView);
        axs_dm_restoreViewBackgrounds(sourceView, savedBg);
        shot = axs_dm_fixSnapshotCorners(shot, sourceView);
        if (shot == nil || shot.CGImage == nil) {
            axs_dm_log(@"emit: snapshot failed");
            return NO;
        }
        // .158/.160: the card is fully visible here -- cache the snapshot on
        // THIS container for its own next open's GPU deposit texture
        // (open-time capture of a hidden card is impossible with
        // cross-process content).
        axs_open_cacheCardSnapshot(sourceView, shot);
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

// ---- beautify.141: ARC-open assemble animation ------------------------------
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
// .144: per-card "already assembled / owned by us" state. Replaces the
// one-shot axs_open_selfRestore for suppressing OUR OWN reveal: after a card
// has been taken over by an assemble, its reveal (hidden=NO) and every later
// present/overlay-cleanup visibility event would otherwise be read as a brand
// new open and re-trigger the assemble forever (.143 infinite loop). This flag
// stays set for the whole time the card is displayed and is cleared only on a
// genuine dismiss (axs_dm_trigger / didMoveToWindow off-window).
static char axs_open_assembledKey;
static CFAbsoluteTime axs_open_lastDismissHide = -1e9;
// .116: our own assemble restores the card (hidden=NO) which would re-trigger
// the open detection -> infinite loop. Flag suppresses exactly that one event.
// .149: the flag is one-shot and can be ORPHANED -- it is set right before the
// safety-net unhide, but if that unhide never reaches our hooks (container
// detached, event eaten), the flag survives and silently EATS the user's next
// genuine open (no particles, card pops in). Every arm now records WHEN it
// was armed; becameVisible releases flags older than 0.6s instead of skipping.
static BOOL axs_open_selfRestore = NO;
static CFAbsoluteTime axs_open_selfRestoreAt = -1e9;
static void axs_open_armSelfRestore(void) {
    axs_open_selfRestore = YES;
    axs_open_selfRestoreAt = CACurrentMediaTime();
}
// .149: window during which an accepted open OWNS the card (assemble +
// reveal + cleanup). Repeated visibility events inside the window are ours
// even if the assembled flag was lost; outside it a set flag is STALE (a
// missed dismissal path) and must be released so the next open gets its
// particles instead of popping the card in with no animation.
static CFAbsoluteTime axs_open_openActiveUntil = 0;
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

// .194: open style -- 0 = classic .168 deposit (default), 1 = wallpaper cover,
// 2 = live cover (real card visible, darkened own-snapshot erased by dust).
static BOOL axs_open_coverStyle(void) {
    BOOL cover = NO;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return NO;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenStyle", @0);
            if ([value isKindOfClass:[NSNumber class]]) cover = [value integerValue] == 1;
        }
    } @catch (NSException *ignored) {
        cover = NO;
    }
    return cover;
}

// .194: style 2 -- LIVE COVER. Real card stays visible under the overlay;
// the cover is a darkened copy of the card's OWN fresh snapshot, erased
// per-cell by the dust so the crisp live window is revealed underneath.
// Completely independent of any screen-capture API.
static BOOL axs_open_liveCoverStyle(void) {
    BOOL on = NO;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return NO;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenStyle", @0);
            if ([value isKindOfClass:[NSNumber class]]) on = [value integerValue] == 2;
        }
    } @catch (NSException *ignored) {
        on = NO;
    }
    return on;
}

// .196: style 3 -- REAL-WINDOW REVEAL. The live card is never hidden and no
// screen/card snapshot is used at all. A per-cell CALayer mask opens on the
// exact hash clock shared with the metal dust, so the flying grains appear to
// carry the real window into place. Content is always the LIVE view tree.
static BOOL axs_open_realRevealStyle(void) {
    BOOL on = NO;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return NO;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenStyle", @0);
            if ([value isKindOfClass:[NSNumber class]]) on = [value integerValue] == 3;
        }
    } @catch (NSException *ignored) {
        on = NO;
    }
    return on;
}

// .196: mask driver. Paints a cols x rows alpha bitmap every display frame;
// CALayer scales it over the whole card. Only the alpha matters to a mask.
@interface AXSOpenRevealDriver : NSObject
@property (nonatomic, weak) UIView *card;
@property (nonatomic, assign) CFTimeInterval start;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSUInteger cols;
@property (nonatomic, assign) NSUInteger rows;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSMutableData *bits;
@property (nonatomic, assign) CGContextRef bmp;
@property (nonatomic, strong) CALayer *maskLayer;
- (void)startOnCard:(UIView *)card start:(CFTimeInterval)start
           duration:(NSTimeInterval)duration frame:(CGRect)frame density:(CGFloat)density;
- (void)stop;
@end

static inline CGFloat axs_open_smoothstep196(CGFloat a, CGFloat b, CGFloat x) {
    CGFloat t = (x - a) / (b - a);
    if (t < 0) t = 0; if (t > 1) t = 1;
    return t * t * (3.0 - 2.0 * t);
}

@implementation AXSOpenRevealDriver

- (void)startOnCard:(UIView *)card start:(CFTimeInterval)start
           duration:(NSTimeInterval)duration frame:(CGRect)frame density:(CGFloat)density {
    self.card = card;
    self.start = start;
    self.duration = duration;
    // Mirror the metal open-mode grid (style 8 / openMode 1) so every mask
    // cell lines up with the dust grain landing on that exact cell.
    int particles = (int)lround(22000.0 * density);
    if (particles < 200) particles = 200;
    if (particles > 48000) particles = 48000;
    CGFloat aspect = frame.size.height > 0.5 ? frame.size.width / frame.size.height : 1.0;
    NSUInteger c = (NSUInteger)lround(sqrtf((float)particles * (float)aspect));
    NSUInteger r = (NSUInteger)((particles + (int)c - 1) / (int)c);
    if (c < 2) c = 2; if (c > 320) c = 320;
    if (r < 2) r = 2; if (r > 320) r = 320;
    self.cols = c; self.rows = r;
    NSUInteger bpr = c * 4;
    self.bits = [NSMutableData dataWithLength:bpr * r];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    self.bmp = CGBitmapContextCreate([self.bits mutableBytes], c, r, 8, bpr, cs,
                                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    CALayer *mask = [CALayer layer];
    mask.frame = card.bounds;
    mask.contentsGravity = kCAGravityResize;
    mask.backgroundColor = [UIColor clearColor].CGColor;
    self.maskLayer = mask;
    card.layer.mask = mask;
    SEL tick196 = @selector(tick:);
    self.link = [CADisplayLink displayLinkWithTarget:self selector:tick196];
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)paintAtTime:(CGFloat)t {
    CGContextRef ctx = self.bmp;
    if (ctx == NULL) return;
    NSUInteger cols = self.cols, rows = self.rows;
    UInt8 *bytes = (UInt8 *)[self.bits mutableBytes];
    size_t bpr = cols * 4;
    memset(bytes, 0, bpr * rows);
    for (NSUInteger cy = 0; cy < rows; cy++) {
        CGFloat uy = (cy + 0.5f) / (CGFloat)rows;
        // CGImage data row 0 renders at the VISUAL TOP; shader cell y=0 is
        // also the top (order=0.96*unit.y opens top first). Keep them aligned
        // so each cell opens exactly where its dust grain lands.
        UInt8 *row = bytes + cy * bpr;
        for (NSUInteger cx = 0; cx < cols; cx++) {
            uint32_t h = (uint32_t)cx * 73856093u ^ (uint32_t)cy * 19349663u ^ 83492791u;
            h ^= h >> 13u; h *= 1274126177u; h ^= h >> 16u;
            CGFloat hf = (CGFloat)(h & 0xffffu) / 65535.0f;
            CGFloat order = 0.96f * uy + 0.04f * hf;
            CGFloat arrival = 0.35f + 0.65f * order;
            CGFloat dock = axs_open_smoothstep196(arrival - 0.03f, arrival - 0.004f, t);
            UInt8 a = (UInt8)(dock * 255.0f);
            UInt8 *p = row + cx * 4;
            p[0] = a; p[1] = a; p[2] = a; p[3] = a;   // premultiplied white
        }
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    if (img != NULL) {
        self.maskLayer.contents = (__bridge id)img;
        CGImageRelease(img);
    }
}

- (void)tick:(CADisplayLink *)link {
    @try {
        UIView *card = self.card;
        if (card == nil || card.window == nil) { [self stop]; return; }
        CFTimeInterval elapsed = CACurrentMediaTime() - self.start;
        CGFloat t = self.duration > 0 ? (CGFloat)(elapsed / self.duration) : 1.0f;
        if (t < 0) t = 0; if (t > 1) t = 1;
        [self paintAtTime:t];
    } @catch (NSException *ignored) {
        [self stop];
    }
}

- (void)stop {
    @try {
        [_link invalidate];
        _link = nil;
        UIView *card = self.card;
        if (card != nil && card.layer.mask == self.maskLayer) card.layer.mask = nil;
        if (_bmp != NULL) { CGContextRelease(_bmp); _bmp = NULL; }
        self.bits = nil;
    } @catch (NSException *ignored) { }
}
@end

// .188: wallpaper-cover state, declared before markGone which resets it.
static BOOL axs_open_revealLive = NO;
static UIImage *axs_open_wallpaperShot = nil;

// .146: wipe driver association key (declared early so markGone can clear it)
static char axs_open_wipeDriverKey;

static void axs_open_markGone(UIView *v) {
    objc_setAssociatedObject(v, &axs_open_goneKey, @(CACurrentMediaTime()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // .188: a real hide/dismiss ends any wallpaper-cover reveal in flight.
    axs_open_revealLive = NO;
    // .146: a real dismiss/hide must stop any running reveal driver and drop
    // its mask, otherwise a reused card keeps a half-built ragged mask.
    @try {
        id driver = objc_getAssociatedObject(v, &axs_open_wipeDriverKey);
        if (driver != nil) {
            [driver performSelector:@selector(stop)];
            objc_setAssociatedObject(v, &axs_open_wipeDriverKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (v.layer.mask != nil) v.layer.mask = nil;
    } @catch (NSException *ignored) { }
}

// .144: card-level assembled state -- persists across ALL visibility events
// until a real dismiss, unlike the one-shot selfRestore flag.
static void axs_open_setAssembled(UIView *v, BOOL yes) {
    if (v == nil) return;
    objc_setAssociatedObject(v, &axs_open_assembledKey,
                             yes ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL axs_open_isAssembled(UIView *v) {
    if (v == nil) return NO;
    NSNumber *n = objc_getAssociatedObject(v, &axs_open_assembledKey);
    return n ? [n boolValue] : NO;
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

// .188: wallpaper-cover style state (ported from .182 architecture only)

// .188: capture the screen state while the card is hidden -- this becomes the
// COVER texture: the overlay paints it back over the card region and fades it
// out per cell as dust arrives, uncovering the REAL card beneath (fresh content).
// .190 C-plan: mine the largest CGImage from a system snapshot view's layer
// tree. snapshotViewAfterScreenUpdates: is rendered by the system compositor;
// its backing CGImages are REAL composited pixels. Re-drawing that view via
// drawViewHierarchyInRect (.188) rasterizes to black -- mining avoids it.
// .191: blank probe is defined later in the file; declare it here so the
// capture strategies below can reject a rendered-but-empty bitmap.
static BOOL axs_dm_imageIsBlank(UIImage *img);

// .191: USER-CHOOSEN "offscreen render" strategy. The system snapshot view
// (snapshotViewAfterScreenUpdates:) is compositor-owned -- .188 proved that
// re-drawing it with drawViewHierarchyInRect yields SOLID BLACK, and .190
// proved its layer contents is a private CAImageRef (no CGImage to mine).
// renderInContext: walks the layer tree through CoreGraphics directly, which
// is a DIFFERENT path and can composite layers that drawViewHierarchyInRect
// refuses to. We render the snapshot view (and, as a second shot, the key
// window) into an offscreen bitmap and keep the first non-blank result.
static UIImage *axs_open_offscreenRender(UIView *view, CGSize size, CGFloat scale) {
    if (view == nil || size.width < 40.0 || size.height < 40.0) return nil;
    UIImage *img = nil;
    @try {
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;   // keep the real alpha so empty areas stay detectable
        fmt.scale = scale;
        CGRect bounds = CGRectMake(0, 0, size.width, size.height);
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:bounds format:fmt];
        img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [view.layer renderInContext:ctx.CGContext];
        }];
    } @catch (NSException *ignored) { img = nil; }
    if (img == nil || img.CGImage == NULL) return nil;
    if ((CGFloat)CGImageGetWidth(img.CGImage) < size.width * 0.8) return nil;
    return img;
}

static CGImageRef axs_open_largestSnapCGImage(CALayer *layer, int depth, CGImageRef best) {
    if (layer == nil || depth > 8) return best;
    @try {
        id contents = layer.contents;
        if (contents != nil && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
            CGImageRef cg = (__bridge CGImageRef)contents;
            size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
            size_t bw = (best != NULL) ? CGImageGetWidth(best) * CGImageGetHeight(best) : 0;
            if (w >= 128 && h >= 128 && w * h > bw) best = cg;
        }
        for (CALayer *sub in layer.sublayers) {
            best = axs_open_largestSnapCGImage(sub, depth + 1, best);
        }
    } @catch (NSException *ignored) { }
    return best;
}

// .190: UIGetScreenImage() is a private UIKit symbol on jailbroken iOS.
// Resolve via dlsym so a missing symbol cannot fail linkage.
static CGImageRef axs_open_screenImageViaUIGet(void) {
    @try {
        typedef CGImageRef (*AXSGetScreenImageFn)(void);
        void *h = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
        if (h == NULL) h = RTLD_DEFAULT;
        AXSGetScreenImageFn fn = (AXSGetScreenImageFn)dlsym(h, "UIGetScreenImage");
        if (fn != NULL) return fn();
    } @catch (NSException *ignored) { }
    return NULL;
}

// .192: display-layer capture. CGDisplayCreateImage(CGMainDisplayID()) reads
// the composited framebuffer straight from WindowServer/IOSurface -- unlike
// all UIKit snapshot paths (.188-.191) it does NOT go through a view/layer
// tree, so it can see cross-process content behind the floating card. The
// symbols are Apple-private on iOS; resolve them dynamically across the
// frameworks that may export them, and log each attempt so one run tells us
// exactly which link failed.
typedef CGImageRef (*AXSDisplayCreateImageFn)(uint32_t displayID);
typedef uint32_t (*AXSMainDisplayIDFn)(void);
static CGImageRef axs_open_screenImageViaCGDisplay(NSString **outWhy) {
    AXSMainDisplayIDFn mainID = NULL;
    AXSDisplayCreateImageFn createImg = NULL;
    const char *paths[] = {
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/System/Library/Frameworks/UIKit.framework/UIKit",
        "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    };
    void *h = NULL;
    for (int i = 0; i < 4; i++) {
        void *p = dlopen(paths[i], RTLD_LAZY | RTLD_LOCAL);
        if (p == NULL) p = RTLD_DEFAULT;
        AXSMainDisplayIDFn m = (AXSMainDisplayIDFn)dlsym(p, "CGMainDisplayID");
        AXSDisplayCreateImageFn c = (AXSDisplayCreateImageFn)dlsym(p, "CGDisplayCreateImage");
        if (m != NULL && c != NULL) { mainID = m; createImg = c; h = p; break; }
        if (m != NULL && mainID == NULL) mainID = m;
        if (c != NULL && createImg == NULL) createImg = c;
    }
    if (mainID == NULL) {
        mainID = (AXSMainDisplayIDFn)dlsym(RTLD_DEFAULT, "CGMainDisplayID");
        createImg = (AXSDisplayCreateImageFn)dlsym(RTLD_DEFAULT, "CGDisplayCreateImage");
    }
    (void)h;
    if (mainID == NULL || createImg == NULL) {
        if (outWhy != NULL) *outWhy = [NSString stringWithFormat:@"symbols main=%d create=%d",
                                       (int)(mainID != NULL), (int)(createImg != NULL)];
        return NULL;
    }
    uint32_t did = mainID();
    CGImageRef img = createImg(did);
    if (img == NULL) {
        if (outWhy != NULL) *outWhy = [NSString stringWithFormat:@"did=%u returned NULL", did];
        return NULL;
    }
    return img;
}

// .190: alpha probe of the cover's center pixel -- logged so we can confirm
// in one run whether the mask is opaque (1.0) or transparent (0.0).
static CGFloat axs_open_centerAlpha(UIImage *img) {
    CGImageRef cg = (img != nil) ? img.CGImage : NULL;
    if (cg == NULL) return -1.0;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return -1.0;
    CGContextRef c = CGBitmapContextCreate(NULL, 1, 1, 8, 4,
                                           CGColorSpaceCreateDeviceRGB(),
                                           kCGImageAlphaPremultipliedLast);
    if (c == NULL) return -1.0;
    CGRect one = CGRectMake((CGFloat)(w / 2), (CGFloat)(h / 2), 1, 1);
    CGImageRef px = CGImageCreateWithImageInRect(cg, one);
    CGFloat a = -1.0;
    if (px != NULL) {
        CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), px);
        UInt8 *data = (UInt8 *)CGBitmapContextGetData(c);
        if (data != NULL) a = (CGFloat)data[3] / 255.0;
        CGImageRelease(px);
    }
    CGContextRelease(c);
    return a;
}

// .195: the live style uses the card's REAL pixels as the DEPOSIT texture.
// .194 darkened this into a near-black silhouette and erased it cell by cell,
// which looked like a black floating-window image being wiped away. The
// reference effect is the opposite: the real card stays hidden, the desktop
// shows through, and each arriving grain paints that cell's real window
// pixels (classic .168 deposit pipeline, openMode=2). No darkening, no cover
// pipeline -- `src` is already corner-clipped by axs_dm_fixSnapshotCorners.
static UIImage *axs_open_makeLiveCover(UIImage *src) {
    if (src == nil || src.CGImage == NULL) return nil;
    return src;
}

// .190: capture the screen state while the card is hidden -- this becomes the
// COVER texture. C-plan: grab REAL composited pixels without any re-render.
static UIImage *axs_open_captureWallpaper(UIView *card) {
    @try {
        UIWindow *win = card.window;
        if (win == nil) return nil;
        CGRect frame = [card convertRect:card.bounds toView:win];
        if (frame.size.width < 40.0 || frame.size.height < 40.0) return nil;
        CGFloat radius = axs_dm_cornerRadiusForView(card);
        CGSize screenPt = [UIScreen mainScreen].bounds.size;

        // .191: USER-CHOOSEN strategy -- offscreen-render the system snapshot
        // view via renderInContext (NOT drawViewHierarchyInRect: .188 proved
        // that path yields solid black, and NOT layer-mining: .190 proved the
        // contents is a private CAImageRef with no CGImage). Try first.
        CGImageRef fullRef = NULL;
        NSString *src = @"none";
        CGFloat scale = [UIScreen mainScreen].scale;
        // .192: PRIMARY -- display-layer framebuffer capture. This is the only
        // path that bypasses the view/layer tree entirely and can see the real
        // composited screen behind the card. Tried first.
        @try {
            NSString *why = @"unknown";
            CGImageRef disp = axs_open_screenImageViaCGDisplay(&why);
            if (disp != NULL && (CGFloat)CGImageGetWidth(disp) >= screenPt.width * 0.8) {
                fullRef = disp;
                src = @"CGDisplay";
                axs_dm_log(@"OPEN wallpaper: CGDisplay OK %zux%zu",
                           (size_t)CGImageGetWidth(disp), (size_t)CGImageGetHeight(disp));
            } else {
                axs_dm_log(@"OPEN wallpaper: CGDisplay failed (%@)", why);
                if (disp != NULL) CGImageRelease(disp);
            }
        } @catch (NSException *e) {
            axs_dm_log(@"OPEN wallpaper: CGDisplay exception %@", [e reason]);
        }
        // .191 fallback A: offscreen-render the system snapshot view.
        @try {
            if (fullRef == NULL) {
                UIView *forceSnap = [[UIScreen mainScreen] snapshotViewAfterScreenUpdates:YES];
                UIImage *rendered = axs_open_offscreenRender(forceSnap, screenPt, scale);
                if (rendered != nil && !axs_dm_imageIsBlank(rendered)) {
                    fullRef = rendered.CGImage;
                    src = @"snapshotOffscreen";
                } else {
                    axs_dm_log(@"OPEN wallpaper: snapshotOffscreen blank/nil");
                }
            }
        } @catch (NSException *ignored) { }
        // Fallback 1 (.190): mine a real CGImage out of the snapshot layer tree.
        if (fullRef == NULL) {
            @try {
                UIView *forceSnap2 = [[UIScreen mainScreen] snapshotViewAfterScreenUpdates:YES];
                CGImageRef mined = axs_open_largestSnapCGImage(forceSnap2.layer, 0, NULL);
                if (mined != NULL && (CGFloat)CGImageGetWidth(mined) >= screenPt.width * 0.8) {
                    fullRef = mined;
                    src = @"snapshotLayer";
                } else {
                    axs_dm_log(@"OPEN wallpaper: snapshotLayer no CGImage");
                }
            } @catch (NSException *ignored) { }
        }
        // Fallback 2 (.190): UIGetScreenImage() via dlsym.
        if (fullRef == NULL) {
            CGImageRef screenImg = axs_open_screenImageViaUIGet();
            if (screenImg != NULL && (CGFloat)CGImageGetWidth(screenImg) >= screenPt.width * 0.8) {
                fullRef = screenImg;
                src = @"UIGetScreenImage";
            } else {
                axs_dm_log(@"OPEN wallpaper: UIGetScreenImage nil");
                if (screenImg != NULL) CGImageRelease(screenImg);
            }
        }
        if (fullRef == NULL) {
            axs_dm_log(@"OPEN wallpaper cover: no composited screen image");
            return nil;
        }

        // Map the card frame (points) into the captured image's pixel space.
        CGFloat imgW = (CGFloat)CGImageGetWidth(fullRef);
        CGFloat imgH = (CGFloat)CGImageGetHeight(fullRef);
        CGFloat sx = imgW / MAX(screenPt.width, 1.0);
        CGFloat sy = imgH / MAX(screenPt.height, 1.0);
        CGRect pr = CGRectMake(frame.origin.x * sx, frame.origin.y * sy,
                               frame.size.width * sx, frame.size.height * sy);
        if (pr.origin.x < 0) pr.origin.x = 0;
        if (pr.origin.y < 0) pr.origin.y = 0;
        if (pr.origin.x + pr.size.width > imgW) pr.size.width = imgW - pr.origin.x;
        if (pr.origin.y + pr.size.height > imgH) pr.size.height = imgH - pr.origin.y;
        if (pr.size.width < 8 || pr.size.height < 8) return nil;
        CGImageRef sub = CGImageCreateWithImageInRect(fullRef, pr);
        if (sub == NULL) return nil;
        UIImage *area = [UIImage imageWithCGImage:sub scale:sx orientation:UIImageOrientationUp];
        CGImageRelease(sub);

        // Clip to the card's exact corner radius -> true alpha rounded corners.
        UIGraphicsImageRendererFormat *fmt2 = [UIGraphicsImageRendererFormat defaultFormat];
        fmt2.scale = sx;
        fmt2.opaque = NO;
        UIGraphicsImageRenderer *r2 =
            [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, frame.size.width, frame.size.height) format:fmt2];
        UIImage *cover = [r2 imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:
                CGRectMake(0, 0, frame.size.width, frame.size.height)
                                               cornerRadius:radius];
            [clip addClip];
            [area drawInRect:CGRectMake(0, 0, frame.size.width, frame.size.height)];
        }];
        CGFloat alpha = axs_open_centerAlpha(cover);
        axs_dm_log(@"OPEN wallpaper cover captured %.0fx%.0f radius=%.1f src=%@ alpha=%.2f full=%zux%zu",
                   frame.size.width, frame.size.height, radius, src, alpha,
                   (size_t)CGImageGetWidth(fullRef), (size_t)CGImageGetHeight(fullRef));
        return cover;
    } @catch (NSException *ignored) {
        return nil;
    }
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

// .145: colored sand texture for the open reveal. The reference plugin's
// grains are vivid cyan/purple/orange, NOT fragments of the whole screen --
// .144 cut the home-screen clock into the particles by capturing the full
// _UIScenePresentationView. A generated gradient gives every grain a stable
// color (the shader samples it with a per-cell hash) with zero capture cost.
static UIImage *axs_open_sandTexture(void) {
    @try {
        CGFloat S = 128.0;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        fmt.scale = 1.0;
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, S, S) format:fmt];
        return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGContextRef c = ctx.CGContext;
            NSArray *cols = @[
                (id)[UIColor colorWithRed:0.18 green:0.86 blue:0.92 alpha:1.0].CGColor, // cyan
                (id)[UIColor colorWithRed:0.42 green:0.42 blue:0.95 alpha:1.0].CGColor, // indigo
                (id)[UIColor colorWithRed:0.86 green:0.36 blue:0.78 alpha:1.0].CGColor, // magenta
                (id)[UIColor colorWithRed:1.00 green:0.55 blue:0.28 alpha:1.0].CGColor, // orange
                (id)[UIColor colorWithRed:0.99 green:0.82 blue:0.35 alpha:1.0].CGColor  // yellow
            ];
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGGradientRef grad = CGGradientCreateWithColors(cs, (CFArrayRef)cols, NULL);
            CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(S, S), 0);
            CGGradientRelease(grad);
            CGColorSpaceRelease(cs);
        }];
    } @catch (NSException *ignored) {
        return nil;
    }
}

// .154: capture the REAL card as the particle texture. The shader now makes
// each grain a fragment of this image and docks it into its own grid cell, so
// the settled grains literally assemble the floating window -- no second mask
// layer, hence no gap. Only the card itself is rasterized (never the full
// screen), so the home-screen clock can never be cut into the grains (.144).
static BOOL axs_dm_imageIsBlank(UIImage *img);   // defined later in this file
static UIImage * __attribute__((unused)) axs_open_captureCardForAssembly(UIView *card) {
    UIImage *shot = nil;
    @try {
        if (card.layer.mask != nil) card.layer.mask = nil;
        // A hidden view still rasterizes its layer tree into an offscreen
        // context via drawViewHierarchyInRect, so try that first (zero risk of
        // leaking a native frame to screen).
        shot = axs_dm_snapshot(card);
    } @catch (NSException *ignored) { shot = nil; }
    if (shot != nil && !axs_dm_imageIsBlank(shot)) return shot;
    // Fallback: briefly unhide through the ORIGINAL setHidden IMP (bypassing
    // our hook) inside the same runloop turn, capture, then re-hide before any
    // screen commit -- no native frame can slip through.
    @try {
        if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), NO);
            card.alpha = 1.0;
            shot = axs_dm_snapshot(card);
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), YES);
        }
    } @catch (NSException *ignored) { shot = nil; }
    if (shot != nil && !axs_dm_imageIsBlank(shot)) return shot;
    return nil;
}

// .157: ALL-GPU open reveal (reference architecture). The CPU mask driver is
// GONE: no CAShapeLayer, no CADisplayLink, no per-frame CGPath rebuild. The
// card stays hidden for the whole animation while the Metal overlay paints
// (a) fine dust rising from the screen-bottom band into each cell and (b)
// deposited REAL card texels gated by the SAME per-cell hash arrival clock --
// both in one Metal encoder, zero CPU work per frame. Only the card snapshot
// is fetched asynchronously below and swapped into the renderer mid-flight.

// Cheap 1x-scale capture of the card. The brief unhide + capture + re-hide
// happens INSIDE one runloop turn through the ORIGINAL setHidden IMP, so no
// CA commit can ever slip a native frame to the screen.
static UIImage *axs_open_captureCardCheap(UIView *card) {
    UIImage *shot = nil;
    @try {
        if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), NO);
            card.alpha = 1.0;
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.opaque = NO;
            fmt.scale = 1.0;
            UIGraphicsImageRenderer *r =
                [[UIGraphicsImageRenderer alloc] initWithBounds:card.bounds format:fmt];
            shot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [card drawViewHierarchyInRect:card.bounds afterScreenUpdates:NO];
            }];
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), YES);
        }
    } @catch (NSException *ignored) {
        @try {
            if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
                ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), YES);
            }
        } @catch (NSException *ignored2) { }
        shot = nil;
    }
    if (shot != nil && axs_dm_imageIsBlank(shot)) return nil;
    return axs_dm_fixSnapshotCorners(shot, card);
}

// Retry on a low cadence: the hidden card's remote content can take a few
// frames to commit after the present starts. As soon as the capture is
// non-blank it is swapped into the live renderer, which arms the GPU deposit
// pass (cardReady). The renderer-pointer guard inside axs_metalReplaceTexture
// makes late retries after cleanup harmless.
static void axs_open_gpuTextureRetry(UIView *card, void *renderer, NSInteger triesLeft) {
    @try {
        if (renderer == NULL || card == nil || card.window == nil) return;
        UIImage *shot = axs_open_captureCardCheap(card);
        if (shot != nil) {
            if (axs_metalReplaceTexture(renderer, shot)) {
                axs_dm_log(@"OPEN gpu texture ready %zux%zu triesLeft=%ld",
                           (size_t)CGImageGetWidth(shot.CGImage),
                           (size_t)CGImageGetHeight(shot.CGImage), (long)triesLeft);
            }
            return;
        }
        if (triesLeft <= 1) {
            axs_dm_log(@"OPEN gpu texture never captured, deposit stays off");
            return;
        }
        __weak UIView *weakCard = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.033 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCard;
            if (c != nil) axs_open_gpuTextureRetry(c, renderer, triesLeft - 1);
        });
    } @catch (NSException *ignored) { }
}

// .157: final handoff -- the overlay has been showing the deposited real-card
// image; unhiding the real card swaps identical pixels, then the overlay
// fades out on its own. Idempotent and mask-free.
static void axs_open_endWipeReveal(UIView *card) {
    @try {
        card.alpha = 1.0;
        if (axs_open_revealLive) {
            // .188: the card has been VISIBLE beneath the cover since accept;
            // nothing to unhide.
        } else {
            if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
                ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), NO);
            } else {
                card.hidden = NO;
            }
        }
        // .191: OWNERSHIP HANDOFF for BOTH paths. .190 only refreshed these in
        // the revealLive (cover-success) branch. When the wallpaper capture
        // failed and we fell back to the classic path, the ownership window
        // armed at accept (duration+0.3) expired ~0.3s before this reveal, and
        // the arm-self-restore fired at duration*0.55 was already older than
        // 0.6s. The next repeated ScreenCore visibility event then saw BOTH
        // flags stale/orphaned -> released them -> re-assembled the card, which
        // is the ~2s "auto open loop" in log71. Re-arm both here so the reveal
        // unhide and all post-reveal presents are swallowed as our own until
        // a genuine dismiss clears them.
        axs_open_setAssembled(card, YES);
        axs_open_openActiveUntil = CACurrentMediaTime() + 3.0;
        axs_open_armSelfRestore();
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
static void __attribute__((unused)) axs_open_collectSceneViews(UIView *root, NSMutableArray *outArr, int depth, int *budget) {
    if (root == nil || depth > 6 || (*budget) <= 0) return;
    (*budget)--;
    const char *cn = object_getClassName(root);
    if (strcmp(cn, "_UIScenePresentationView") == 0) [outArr addObject:root];
    for (UIView *sv in root.subviews) axs_open_collectSceneViews(sv, outArr, depth + 1, budget);
}

static UIImage * __attribute__((unused)) axs_open_captureAppContent(void) {
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
    // .141: render at HALF resolution -- the texture only feeds small
    // grains, and the full-screen rasterization (430x932) was blocking the
    // main thread ~0.4s (visible as animation stutter)
    for (UIView *v in cands) {
        CGSize small = CGSizeMake(MAX(v.bounds.size.width * 0.5, 120.0),
                                  MAX(v.bounds.size.height * 0.5, 120.0));
        UIImage *shot = nil;
        @try {
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.opaque = NO;
            fmt.scale = 1.0;
            UIGraphicsImageRenderer *r =
                [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, small.width, small.height) format:fmt];
            shot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [v drawViewHierarchyInRect:CGRectMake(0, 0, v.bounds.size.width, v.bounds.size.height) afterScreenUpdates:NO];
            }];
        } @catch (NSException *ignored) {
            shot = nil;
        }
        if (!axs_dm_imageIsBlank(shot)) {
            axs_dm_log(@"OPEN scene capture ok class=%@ px=%zux%zu",
                       NSStringFromClass([v class]),
                       (size_t)small.width, (size_t)small.height);
            return shot;
        }
        @try {
            UIGraphicsImageRendererFormat *fmt2 = [UIGraphicsImageRendererFormat defaultFormat];
            fmt2.opaque = NO;
            fmt2.scale = 1.0;
            UIGraphicsImageRenderer *r2 =
                [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, small.width, small.height) format:fmt2];
            UIImage *shot2 = [r2 imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [v.layer renderInContext:ctx.CGContext];
            }];
            if (!axs_dm_imageIsBlank(shot2)) {
                axs_dm_log(@"OPEN scene capture ok (renderInContext) px=%zux%zu",
                           (size_t)small.width, (size_t)small.height);
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
        BOOL settled = (polls >= 2 && frame.size.width > 40.0
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
            axs_open_armSelfRestore();
            card.hidden = NO;
            return;
        }
        // .157: the deposit pass needs the real card texels. .158: a hidden
        // card cannot be rasterized (cross-process content), so seed the
        // texture with the cached visible-card snapshot from the last
        // dismiss/open; the async retry below still tries a fresh capture and
        // swaps it in mid-flight when one ever succeeds. The sand texture is
        // only the last-resort placeholder (dust color stays palette-driven).
        UIImage *tex = nil;
        NSString *texKind = nil;
        BOOL realReveal = axs_open_realRevealStyle();
        BOOL liveCover = !realReveal && axs_open_liveCoverStyle() && axs_open_wallpaperShot != nil;
        // .195: style 2 deposits real pixels (classic pipeline); only style 1
        // uses the cover/erase pipeline. .196: style 3 uses NO screenshot at
        // all -- metal draws dust only, the live card is revealed by a mask.
        BOOL useCover = !realReveal && !liveCover && (axs_open_coverStyle() && axs_open_wallpaperShot != nil);
        if (realReveal) {
            axs_dm_log(@"OPEN real reveal: live window + per-cell mask, no snapshot");
        }
        UIImage *cachedCard = axs_open_cachedCardSnapshotForView(card);
        if (cachedCard != nil && cachedCard.CGImage != NULL
            && CGImageGetWidth(cachedCard.CGImage) >= 256) {
            tex = cachedCard;
            texKind = @"cached-card";
        }
        if (realReveal) {
            tex = axs_open_sandTexture();
            texKind = @"real-reveal";
        }
        if (useCover) {
            // .188: the WALLPAPER is the cover texture -- it fades out per cell
            // as dust arrives, uncovering the REAL card beneath. Applied after
            // the cached-card fallback so the classic path stays byte-identical.
            tex = axs_open_wallpaperShot;
            texKind = @"wallpaper";
        }
        if (liveCover && tex != nil) texKind = @"live-cover";
        if (tex == nil) { tex = axs_open_sandTexture(); texKind = @"reference-dust"; }
        if (tex == nil) { tex = axs_open_bgTexture(card); texKind = @"bg-color"; }
        if (tex == nil) {
            axs_dm_log(@"OPEN texture unavailable, native card restored");
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            card.hidden = NO;
            return;
        }
        // .188: arm the chosen shader pipeline BEFORE the first draw (the
        // Metal pipeline is compiled lazily on first render).
        axs_msd_setCoverMode(useCover);   // .196: realReveal -> NO (dust only)
        // .197: style 3 also kills grains landing outside the rounded corners
        // (square-corner halo). Other styles pass 0 => shader unchanged.
        if (realReveal) {
            CGFloat rr = axs_dm_cornerRadiusForView(card);
            if (rr < 1.0) rr = 40.0;
            axs_msd_setCornerKill(1u, (float)rr);
            axs_dm_log(@"OPEN real reveal corner kill armed radius=%.1f", rr);
        } else {
            axs_msd_setCornerKill(0u, 0.0f);
        }
        void *renderer = axs_metalAssemblePlayRet(tex, frame, duration, density, sourcePoint);
        if (renderer == NULL) {
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            card.hidden = NO;
            axs_dm_log(@"OPEN assemble unavailable, native card restored");
            return;
        }
        // all fallback paths above already returned, so the assemble WILL run.
        // .157: the card stays hidden the WHOLE time; the Metal overlay draws
        // both the dust and the deposited real-card texels (all GPU).
        @try {
            if (card.layer.mask != nil) card.layer.mask = nil;
            card.alpha = 1.0;
        } @catch (NSException *ignored) { }
        axs_dm_log(@"OPEN assemble started duration=%.2f density=%.2f polls=%ld texture=%@ source=%@ (%@)",
                   duration, density, (long)polls, texKind,
                   NSStringFromCGPoint(sourcePoint), sourceKind);
        // .157: ALL-GPU reveal. The card stays hidden for the whole animation;
        // the Metal overlay deposits real-card texels per cell with the same
        // hash clock as the dust (openMode=2 pass). No CAShapeLayer mask, no
        // per-frame CPU path rebuild. Disarm the intercept window, make the
        // hidden state explicit through the ORIGINAL IMP, then start the async
        // capture retry so the deposit pass gets the real texture mid-flight.
        axs_open_interceptUntil = 0;
        @try {
            card.alpha = 1.0;
            if (useCover) {
                // .188: unhide through the ORIGINAL IMP so our hook does not
                // re-enter; the card sits visible beneath the cover overlay.
                if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
                    ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), NO);
                } else if (axs_open_orig_setHidden == (IMP)1) {
                    struct objc_super sup = { (id)card, class_getSuperclass(object_getClass(card)) };
                    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, @selector(setHidden:), NO);
                }
                axs_open_revealLive = YES;
            } else if (realReveal) {
                // .196: the REAL window is the content -- keep it visible the
                // whole time; the mask hides it until each cell opens.
                axs_open_revealLive = YES;
            } else {
                if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
                    ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), YES);
                } else {
                    card.hidden = YES;
                }
            }
        } @catch (NSException *ignored) { }
        // .196: start the reveal mask on the renderer's EXACT clock so each
        // cell opens precisely when its dust grain lands.
        if (realReveal) {
            AXSOpenRevealDriver *drv = [AXSOpenRevealDriver new];
            CFTimeInterval metalStart = axs_metalAssembleStartTime(renderer);
            [drv startOnCard:card
                       start:(metalStart > 0 ? metalStart : CACurrentMediaTime())
                    duration:duration frame:frame density:density];
            objc_setAssociatedObject(card, &axs_open_wipeDriverKey, drv,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            axs_dm_log(@"OPEN real reveal mask armed %lux%lu duration=%.2f",
                       (unsigned long)drv.cols, (unsigned long)drv.rows, duration);
        }
        // .195: the live style DEPOSITS real pixels, so a mid-flight swap to a
        // fresher capture improves content freshness (never kills the effect).
        // Only the wallpaper-cover style must keep its cover texture intact.
        if (!useCover && !realReveal) {
            __weak UIView *weakCardTex = card;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *c = weakCardTex;
                if (c != nil) axs_open_gpuTextureRetry(c, renderer, 30);
            });
        }
        // .158: 0.35s after the open finished the card is visible again --
        // grab a fresh snapshot (cheap 1x) so the NEXT open deposits current
        // content, not the stale cached one.
        __weak UIView *weakCardCache = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((duration + 0.35) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCardCache;
            if (c == nil) return;
            UIImage *fresh = axs_open_captureVisibleCardCheap(c);
            if (fresh != nil) {
                axs_open_cacheCardSnapshot(c, fresh);
                axs_dm_log(@"OPEN cached card snapshot refreshed %zux%zu",
                           (size_t)CGImageGetWidth(fresh.CGImage),
                           (size_t)CGImageGetHeight(fresh.CGImage));
            }
        });
        // Release the in-flight guard partway through so a genuine re-open can
        // still self-heal, and do the final safety sweep at overlay dissolve.
        // .195: own weak capture -- weakCardTex is scoped inside the
        // !useCover block (only the wallpaper cover skips the swap).
        __weak UIView *weakCardGuard = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * 0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCardGuard;
            if (c != nil) {
                axs_open_assembleInFlight = NO;
                axs_open_armSelfRestore();
            }
        });
        __weak UIView *weakCard3 = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 0.05) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c3 = weakCard3;
            if (c3 != nil) axs_open_endWipeReveal(c3);
        });
        return;
    } @catch (NSException *ignored) {
        axs_open_assembleInFlight = NO;
        card.hidden = NO;
    }
}

static void axs_open_becameVisible(UIView *v) {
    @try {
        // .192: CHECK THE OWNERSHIP WINDOW FIRST. In .191 this test ran LAST,
        // AFTER the stale/orphaned age checks. The window was only
        // "duration+0.3" from accept, but pollStep settles ~0.26s before the
        // assemble even starts, so the window EXPIRED mid-animation (~1.94s)
        // while reveal lands ~2.0s and cleanup ~2.3s. The age checks therefore
        // fired on our OWN repeated visibility events and re-assembled every
        // ~2s (the loop in log71/log72). Moving this to the top means every
        // event inside the full assemble+reveal+cleanup window is unconditionally
        // ours, whatever state the flags are in; the age-based cleanup below
        // only runs once a genuinely NEW open arrives after the window closes.
        {
            CFAbsoluteTime nowB = CACurrentMediaTime();
            if (nowB < axs_open_openActiveUntil) {
                axs_dm_log(@"OPEN candidate skipped (open still active %.2fs)",
                           axs_open_openActiveUntil - nowB);
                return;
            }
        }
        // .144: a card already owned by an assemble is STILL the same visible
        // window -- its own reveal and ScreenCore's repeated presents must not
        // start a new assemble. This is persistent (unlike selfRestore) and is
        // cleared only on a genuine dismiss / off-window.
        // .149: but if the flag survives PAST our animation window while no
        // assemble is running, it is STALE (a dismissal path missed its
        // release). Skipping then eats a genuine open -- no particles, card
        // pops in. Release the stale flag and fall through to accept.
        if (axs_open_isAssembled(v)) {
            CFAbsoluteTime nowA = CACurrentMediaTime();
            if (!axs_open_assembleInFlight && nowA > axs_open_openActiveUntil) {
                axs_open_setAssembled(v, NO);
                axs_dm_log(@"OPEN stale assembled flag released, re-assembling");
            } else {
                axs_dm_log(@"OPEN candidate skipped (already assembled)");
                return;
            }
        }
        // .149: one-shot self-restore with an age check. The safety net arms
        // it immediately before its own unhide, so the legit consume happens
        // within milliseconds. If the flag is still here >0.6s later, its
        // restore event never arrived (orphaned) -- release it and let this
        // genuine open assemble instead of silently eating it.
        if (axs_open_selfRestore) {
            axs_open_selfRestore = NO;
            if (CACurrentMediaTime() - axs_open_selfRestoreAt > 0.6) {
                axs_dm_log(@"OPEN orphaned self-restore flag released, re-assembling");
            } else {
                axs_dm_log(@"OPEN candidate skipped (self restore)");
                return;
            }
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
        // .165: the flight + reveal read too fast at the default speed;
        // the base duration goes 0.85s -> 1.15s (speed slider still scales).
        CGFloat duration = 1.15 / axs_open_speedScale();
        // .192: own the card for the WHOLE assemble+reveal+cleanup window.
        // .191 used duration+0.3 which expired mid-animation (pollStep settles
        // ~0.26s) and let stale/orphaned checks fire on our own events.
        // duration+1.5 covers settle + reveal(duration+0.05) + cache refresh
        // (duration+0.35) with margin.
        axs_open_openActiveUntil = CACurrentMediaTime() + duration + 1.5;
        CGRect cardFrame = [card convertRect:card.bounds toView:nil];
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        // .147: fallback must NEVER be the card center (that made grains
        // appear to sprout from the middle of the screen). Use the bottom
        // center of the screen -- the lift gesture normally ends down there.
        CGPoint sourcePoint = CGPointMake(CGRectGetMidX(cardFrame), screenH - 90.0);
        NSString *sourceKind = @"fallback-screen-bottom";
        if (nowT - axs_open_arcIconPosAt <= 6.0
            && axs_open_arcIconPos.x >= 0 && axs_open_arcIconPos.y >= 0) {
            sourcePoint = axs_open_arcIconPos;
            sourceKind = @"arc-icon";
        } else if (nowT - axs_open_lastTouchUpAt <= 4.0
            && axs_open_lastTouchUp.x >= 0 && axs_open_lastTouchUp.y >= 0) {
            sourcePoint = axs_open_lastTouchUp;
            sourceKind = @"last-lift";
        }
        axs_dm_log(@"OPEN source point %@ (%@)", NSStringFromCGPoint(sourcePoint), sourceKind);
        // .167: fill the per-window cache BEFORE hiding -- the first ever
        // open of a window has no snapshot yet, so its deposit pass had
        // nothing to paint and the card only popped in after the dust.
        // .194: hoisted so the live-cover branch can reuse this fresh capture.
        UIImage *preShot = nil;
        @try {
            preShot = axs_open_captureVisibleCardCheap(card);
            if (preShot != nil) axs_open_cacheCardSnapshot(card, preShot);
        } @catch (NSException *ignored) { }
        // .122: hide from frame 0 (invisible). The native present animation is
        // NOT intercepted -- it still runs and its completions still fire, but
        // the addAnimation hook clamps its duration to 0.01s so it finishes
        // instantly behind our particles (see axs_open_addAnimation).
        // .123: the whole flow runs OUTSIDE the UIKit window-setup stack and
        // the poll uses weak captures only (see axs_open_pollStep) -- no
        // block-copy of strong view captures anywhere.
        BOOL wantRealReveal = axs_open_realRevealStyle();
        BOOL wantLiveCover = !wantRealReveal && axs_open_liveCoverStyle();
        // .194: hide at frame 0 for ALL styles (no real-card flash before the
        // cover overlay's first frame). .196: style 3 keeps the LIVE card
        // present (masked) from frame 0 -- it IS the revealed content.
        if (!wantRealReveal) card.hidden = YES;
        if (wantLiveCover) {
            // .194: cover = darkened copy of the card's OWN pixels. The
            // accept-time capture (preShot) is usually blank because remote
            // content is not attached yet; the snapshot cached at dismiss (or
            // loaded from disk) is the reliable source -- log73 proves it is
            // always present (texture=cached-card). The plate is only a dark
            // silhouette, so slight staleness is invisible; the REAL window
            // revealed underneath is always live content.
            UIImage *src = preShot;
            if (src == nil || src.CGImage == NULL) src = axs_open_cachedCardSnapshotForView(card);
            UIImage *plate = axs_open_makeLiveCover(src);
            if (plate != nil) {
                axs_open_wallpaperShot = plate;
                axs_dm_log(@"OPEN live cover captured %.0fx%.0f (card own pixels, deposit)",
                           plate.size.width, plate.size.height);
            } else {
                axs_dm_log(@"OPEN live cover failed, using classic style");
                axs_open_wallpaperShot = nil;
            }
        } else if (wantRealReveal) {
            // .196: no capture at all. The live window is shown through the
            // per-cell mask; there is no stale image to capture or deposit.
            axs_dm_log(@"OPEN real reveal accepted, snapshot bypassed");
        } else if (axs_open_coverStyle()) {
            // .188: capture the screen WITHOUT the card; failure falls back to
            // the classic cached-card deposit for this open.
            UIImage *wall = axs_open_captureWallpaper(card);
            if (wall == nil) {
                axs_dm_log(@"OPEN wallpaper capture failed, using classic style");
                axs_open_wallpaperShot = nil;
            } else {
                axs_open_wallpaperShot = wall;
            }
        }
        // .196: style 3 holds the LIVE card visible (behind the mask) from
        // frame 0, so arm revealLive now -- otherwise a native setHidden:NO
        // during the settle polls would be snapped back to hidden. Other
        // styles keep the unconditional reset; pollStep re-arms YES on cover.
        axs_open_revealLive = wantRealReveal;
        axs_open_assembleInFlight = YES;
        // .144: mark the card as owned from the FIRST frame. Every later
        // visibility event (our reveal, overlay cleanup, repeated present)
        // now resolves to "already assembled" and cannot re-enter this path.
        axs_open_setAssembled(card, YES);
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
        && axs_open_enabled() && !axs_open_revealLive) {
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

// ===========================================================================
// beautify.193 -- READ-ONLY PROBE. No animation logic is touched.
// Goal: prove we can grab the floating-icon's REAL UIView at tap time and
// snapshot its true pixels (the reference plugin does exactly this via its
// tray-capture callback). Two zero-risk strategies:
//   1) On every touch, dump the hit-view's superview chain (the floating icon
//      is guaranteed to be in that chain) + the full TOJB class/method map.
//   2) For each candidate view, snapshot it and offscreen-render it, then log
//      pixel size + layer.contents class -- the same "mini-capture hierarchy
//      image pixels" probe the reference plugin logs.
// Everything is wrapped in @try and only writes to axs_dm_log.
// ===========================================================================

static BOOL axs_probe_done = NO;
static NSInteger axs_probe_touchSeq = 0;

// Strategy 1a: enumerate every TOJB* class and its methods once.
static void axs_probe_dumpTOJBClasses(void) {
    if (axs_probe_done) return;
    axs_probe_done = YES;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        axs_dm_log(@"PROBE TOJB class list empty");
        return;
    }
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (classes == NULL) return;
    count = objc_getClassList(classes, count);
    axs_dm_log(@"PROBE TOJB scan classes=%d", count);
    int tojbClasses = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cname = class_getName(cls);
        if (cname == NULL) continue;
        if (strstr(cname, "TOJB") == NULL && strstr(cname, "Troll") == NULL) continue;
        tojbClasses++;
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(cls, &mcount);
        axs_dm_log(@"PROBE TOJB CLASS %s methods=%u", cname, mcount);
        for (unsigned int j = 0; j < mcount; j++) {
            SEL sel = method_getName(methods[j]);
            const char *enc = method_getTypeEncoding(methods[j]);
            axs_dm_log(@"PROBE TOJB METHOD %s | %s", sel ? sel_getName(sel) : "?", enc ? enc : "?");
        }
        if (methods != NULL) free(methods);
    }
    free(classes);
    axs_dm_log(@"PROBE TOJB done tojbClasses=%d", tojbClasses);
}

// Snapshot + offscreen render ONE candidate view, log pixel evidence.
static void axs_probe_captureView(UIView *v, NSString *label) {
    if (v == nil) return;
    CGRect bounds = [v bounds];
    int hierarchyOK = 0, imageOK = 0;
    CGSize pixels = CGSizeZero;
    NSString *contentsClass = @"?";
    @try {
        UIView *snap = [v snapshotViewAfterScreenUpdates:YES];
        hierarchyOK = (snap != nil) ? 1 : 0;
    } @catch (NSException *ignored) { }
    @try {
        UIGraphicsBeginImageContextWithOptions(bounds.size, NO, 0.0);
        [v drawViewHierarchyInRect:bounds afterScreenUpdates:YES];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (img != nil && img.CGImage != nil) {
            imageOK = 1;
            pixels = CGSizeMake((CGFloat)CGImageGetWidth(img.CGImage),
                                (CGFloat)CGImageGetHeight(img.CGImage));
        }
    } @catch (NSException *ignored) { }
    @try {
        id contents = v.layer.contents;
        contentsClass = contents != nil ? NSStringFromClass([contents class]) : @"nil";
    } @catch (NSException *ignored) { }
    axs_dm_log(@"PROBE mini-capture %@ class=%@ frame=%@ hierarchy=%d image=%d pixels=%zux%zu layerContents=%@",
               label, NSStringFromClass([v class]), NSStringFromCGRect([v frame]),
               hierarchyOK, imageOK, (size_t)pixels.width, (size_t)pixels.height, contentsClass);
}

// Dump the touch view's superview chain; snapshot each candidate up to 6 deep.
static void axs_probe_dumpTouchChain(UIView *touchView) {
    axs_probe_touchSeq++;
    if (axs_probe_touchSeq % 5 != 1) return;   // throttle: only 1 in 5 taps
    axs_dm_log(@"PROBE TOUCH#%ld hitView=%@", (long)axs_probe_touchSeq,
               touchView != nil ? NSStringFromClass([touchView class]) : @"nil");
    UIView *cur = touchView;
    int depth = 0;
    while (cur != nil && depth < 6) {
        @try {
            axs_dm_log(@"PROBE CHAIN[%d] class=%@ frame=%@ alpha=%.2f hidden=%d",
                       depth, NSStringFromClass([cur class]),
                       NSStringFromCGRect([cur frame]), [cur alpha], [cur isHidden]);
            // capture only compact views (icon-sized), skip full-screen containers
            CGRect f = [cur frame];
            if (f.size.width > 0 && f.size.width <= 180 && f.size.height > 0 && f.size.height <= 180) {
                axs_probe_captureView(cur, [NSString stringWithFormat:@"CHAIN[%d]", depth]);
            }
        } @catch (NSException *ignored) { }
        cur = [cur superview];
        depth++;
    }
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
            // .193: read-only probe -- dump hit view chain + capture icon pixels
            axs_probe_dumpTOJBClasses();
            axs_probe_dumpTouchChain(touchView);
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
                axs_open_armSelfRestore();
                // .144: the dismiss is complete -- release the card so the
                // user's NEXT genuine open can assemble. Until now the card
                // stayed "assembled" and every repeated present during the
                // dismiss was ignored.
                axs_open_setAssembled(container, NO);
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
    // beautify.141: ARC-open assemble hooks (class may load later -> retried)
    axs_open_installAll();
}

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") == nil) return;
        axs_dm_log(@"DME module loaded in SpringBoard (beautify.141, dismiss+open)");
        axs_dm_installAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_dm_installAll(); });
    }
}
