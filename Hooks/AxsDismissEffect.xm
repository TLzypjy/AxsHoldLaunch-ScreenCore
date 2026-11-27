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
void axs_msd_setCornerKill(uint32_t on, float radius);
void axs_msd_setDirectionMode(uint32_t mode);
BOOL axs_metalReplaceTexture(void *renderer, UIImage *img);
// .155: exact shared clock of the running open renderer.
CFTimeInterval axs_metalAssembleStartTime(void *renderer);
// .230: rect-to-rect particle transfer (float<->dock diagonal dissolve+assemble)
void *axs_metalDockTransferPlayRet(UIImage *shot, CGRect fromFrame, CGRect toFrame,
                                   CGFloat duration, CGFloat density,
                                   uint32_t departDir, uint32_t arriveDir);
void axs_msd_setTransferConfig(CGRect from, uint32_t departDir, uint32_t arriveDir);
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
static uint32_t axs_open_directionMode(void) {
    uint32_t mode = 0;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return 0;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenDirection", @0);
            if ([value isKindOfClass:[NSNumber class]]) mode = (uint32_t)[value integerValue];
        }
        if (mode > 7) mode = 0;
    } @catch (NSException *ignored) {
        mode = 0;
    }
    return mode;
}

// .208: only two styles remain -- 0 = live reveal, 1 = shockwave summon.
// Both are live-window reveals, so this is always YES; legacy stored values
// 3 (reveal) / 4 (shockwave) map inside the sibling getter.
static BOOL axs_open_realRevealStyle(void) {
    return YES;
}
// .207: style 4 -- shockwave summon. Live reveal forced radial from the touch,
// opening with double burst rings at the summon point.
static BOOL axs_open_shockwaveStyle(void) {
    BOOL on = NO;
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return NO;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenStyle", @0);
            NSInteger sv = [value integerValue];
            on = (sv == 1 || sv == 4);   // .208: 1 = shockwave, legacy 4 migrates
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
@property (nonatomic, assign) CGFloat frameW;      // .198 corner-aware reveal
@property (nonatomic, assign) CGFloat frameH;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) uint32_t dirMode;
@property (nonatomic, assign) CGFloat srcX;        // .206 radial-from-touch
@property (nonatomic, assign) CGFloat srcY;
@property (nonatomic, assign) CGFloat maxDist;     // farthest-corner distance
- (void)startOnCard:(UIView *)card start:(CFTimeInterval)start
           duration:(NSTimeInterval)duration frame:(CGRect)frame density:(CGFloat)density
                radius:(CGFloat)radius
                 dirMode:(uint32_t)dirMode
                  source:(CGPoint)sourcePoint;
- (void)stop;
@end

static inline CGFloat axs_open_smoothstep196(CGFloat a, CGFloat b, CGFloat x) {
    CGFloat t = (x - a) / (b - a);
    if (t < 0) t = 0; if (t > 1) t = 1;
    return t * t * (3.0 - 2.0 * t);
}

// .207: double shockwave ring at the burst point -- the style-4 opening (and
// only that; the .206 always-on hook on style 3 was removed per user).
// Two expanding stroked circles in the card's own window; GPU-composited,
// self-removing, touches nothing else.
static void axs_open_playShockwave(UIWindow *win, CGPoint point) {
    @try {
        if (win == nil) return;
        NSArray *waveCols = @[
            [UIColor colorWithRed:0.10 green:0.86 blue:0.94 alpha:1.0],
            [UIColor colorWithRed:0.68 green:0.28 blue:0.98 alpha:1.0],
        ];
        for (NSUInteger i = 0; i < 2; i++) {
            CGFloat r0 = 8.0;
            UIBezierPath *pth = [UIBezierPath bezierPathWithArcCenter:point
                                                              radius:r0
                                                          startAngle:0.0
                                                            endAngle:6.2831853
                                                           clockwise:YES];
            CAShapeLayer *ring = [CAShapeLayer layer];
            ring.path = pth.CGPath;
            ring.fillColor = [UIColor clearColor].CGColor;
            ring.strokeColor = [(UIColor *)waveCols[i] CGColor];
            ring.lineWidth = (i == 0 ? 5.0 : 9.0);
            ring.opacity = (i == 0 ? 0.9 : 0.45);
            ring.frame = CGRectMake(point.x - r0, point.y - r0, r0 * 2.0, r0 * 2.0);
            [win.layer addSublayer:ring];
            CGFloat dur = 0.55 + 0.20 * i;
            CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            scale.fromValue = @1.0;
            scale.toValue = @(16.0 + 8.0 * i);
            scale.duration = dur;
            scale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = (i == 0 ? @0.9 : @0.45);
            fade.toValue = @0.0;
            fade.duration = dur;
            CAAnimationGroup *grp = [CAAnimationGroup animation];
            grp.animations = @[ scale, fade ];
            grp.duration = dur;
            grp.removedOnCompletion = YES;
            [ring addAnimation:grp forKey:@"axs_open_wave206"];
            __weak CAShapeLayer *wring = ring;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.05) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { [wring removeFromSuperlayer]; } @catch (NSException *ignored) { }
            });
        }
    } @catch (NSException *ignored) { }
}

@implementation AXSOpenRevealDriver

- (void)startOnCard:(UIView *)card start:(CFTimeInterval)start
           duration:(NSTimeInterval)duration frame:(CGRect)frame density:(CGFloat)density
                radius:(CGFloat)radius
                 dirMode:(uint32_t)dirMode
                  source:(CGPoint)sourcePoint {
    self.card = card;
    self.dirMode = dirMode;   // .201: mask clock must match the metal clock
    self.start = start;
    self.duration = duration;
    self.frameW = frame.size.width;
    self.frameH = frame.size.height;
    self.cornerRadius = radius;   // .198: reveal mask respects the rounded corners
    // .206: radial-from-touch geometry (card-local source + farthest-corner dist)
    self.srcX = sourcePoint.x - frame.origin.x;
    self.srcY = sourcePoint.y - frame.origin.y;
    CGFloat fx6 = MAX(fabs(self.srcX), fabs(self.srcX - frame.size.width));
    CGFloat fy6 = MAX(fabs(self.srcY), fabs(self.srcY - frame.size.height));
    self.maxDist = MAX(sqrtf(fx6 * fx6 + fy6 * fy6), 1.0f);
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
            CGFloat ux = (cx + 0.5f) / (CGFloat)cols;
            CGFloat px = ux * self.frameW;          // card-local cell center
            CGFloat py = uy * self.frameH;          // .206: shared by radial + corner SDF
            CGFloat orderBase;
            if (self.dirMode == 0u) orderBase = uy;
            else if (self.dirMode == 1u) orderBase = 1.0f - uy;
            else if (self.dirMode == 2u) orderBase = (ux + uy) * 0.5f;
            else if (self.dirMode == 3u) orderBase = ((1.0f - ux) + uy) * 0.5f;
            else if (self.dirMode == 4u) orderBase = (ux + (1.0f - uy)) * 0.5f;
            else if (self.dirMode == 6u) {
                CGFloat dx6 = px - self.srcX;
                CGFloat dy6 = py - self.srcY;
                orderBase = fminf(sqrtf(dx6 * dx6 + dy6 * dy6) / self.maxDist, 1.0f);
            }
            else if (self.dirMode == 7u) {
                CGFloat dx7 = px - self.frameW * 0.5f;
                CGFloat dy7 = py - self.frameH * 0.5f;
                CGFloat md7 = sqrtf(self.frameW * self.frameW + self.frameH * self.frameH) * 0.5f;
                orderBase = 1.0f - fminf(sqrtf(dx7 * dx7 + dy7 * dy7) / md7, 1.0f);
            }
            else orderBase = ((1.0f - ux) + (1.0f - uy)) * 0.5f;
            CGFloat order = 0.96f * orderBase + 0.04f * hf;
            CGFloat arrival = 0.35f + 0.65f * order;
            CGFloat dock = axs_open_smoothstep196(arrival - 0.03f, arrival - 0.004f, t);
            // .198: cells outside the card's rounded corner arc NEVER open.
            // The container's square bounds carry a pale wash beyond the
            // rounded content; opening those cells flashed a square halo.
            CGFloat aF = dock;
            if (self.cornerRadius > 0.5f && self.frameW > 1.0f && self.frameH > 1.0f) {
                CGFloat qx = fabs(px - self.frameW * 0.5f) - (self.frameW * 0.5f - self.cornerRadius);
                CGFloat qy = fabs(py - self.frameH * 0.5f) - (self.frameH * 0.5f - self.cornerRadius);
                CGFloat dxo = qx > 0 ? qx : 0;
                CGFloat dyo = qy > 0 ? qy : 0;
                CGFloat innerMax = qx > qy ? qx : qy;   // MAX(qx,qy)
                CGFloat dOut = sqrtf(dxo * dxo + dyo * dyo)
                             + (innerMax < 0 ? innerMax : 0)
                             - self.cornerRadius;   // .199: rounded-rect SDF needs -r
                CGFloat kill = 1.0f - axs_open_smoothstep196(-1.5f, 1.5f, dOut);
                aF *= kill;
            }
            UInt8 a = (UInt8)(aF * 255.0f);
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
        if (t >= 1.0) {
            [self stop];   // fully open, release the display link
        }
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

// .146: wipe driver association key (declared early so markGone can clear it)
static char axs_open_wipeDriverKey;
// .198: accept-time static hide-mask association key (identity for the
// safety timer so only OUR mask is ever dropped)
static char axs_open_staticMaskKey;

static void axs_open_markGone(UIView *v) {
    objc_setAssociatedObject(v, &axs_open_goneKey, @(CACurrentMediaTime()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // .188: a real hide/dismiss ends any wallpaper-cover reveal in flight.
    axs_open_revealLive = NO;
    // .200: a REAL close is explicit user intent -- expire BOTH loop
    // protection gates so the immediate close->reopen animates (log80:
    // reopen 1.3s after a close was eaten by the ownership window with
    // 0.13s left, then twice more by fresh self-restore arms). Loop
    // artifacts only occur while the card stays visible with no close
    // event, so this cannot re-open that hole; the window is re-armed by
    // endWipeReveal/pollStep on the next accepted open anyway.
    axs_open_openActiveUntil = 0;
    axs_open_selfRestore = NO;
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
        BOOL realReveal = YES;   // .208: only live-reveal styles remain
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
        if (tex == nil) { tex = axs_open_sandTexture(); texKind = @"reference-dust"; }
        if (tex == nil) { tex = axs_open_bgTexture(card); texKind = @"bg-color"; }
        if (tex == nil) {
            axs_dm_log(@"OPEN texture unavailable, native card restored");
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            if (realReveal && card.layer.mask != nil) card.layer.mask = nil;  // .198 static hide-mask
            card.hidden = NO;
            return;
        }
        // .188: arm the chosen shader pipeline BEFORE the first draw (the
        // Metal pipeline is compiled lazily on first render).
        // .197: style 3 also kills grains landing outside the rounded corners
        // (square-corner halo). Other styles pass 0 => shader unchanged.
        CGFloat revealRadius = 0;   // .198 shared by corner-kill + reveal mask
        if (realReveal) {
            CGFloat rr = axs_dm_cornerRadiusForView(card);
            if (rr < 1.0) rr = 40.0;
            revealRadius = rr;
            axs_msd_setCornerKill(1u, (float)rr);
            axs_dm_log(@"OPEN real reveal corner kill armed radius=%.1f", rr);
        } else {
            axs_msd_setCornerKill(0u, 0.0f);
        }
        // .201: reveal direction -- the dust clock and the mask clock both read
        // this, so they stay aligned. .207: style 4 always reveals radially
        // from the burst point, whatever the direction pick says.
        uint32_t openDir = axs_open_directionMode();
        if (axs_open_shockwaveStyle()) openDir = 6u;
        axs_msd_setDirectionMode(openDir);
        // .216: dirMode 6 now expands from the CARD CENTER outward (user
        // request) instead of from the touch point -- feed the geometric
        // center as the radial source to both the dust clock and the mask
        // driver; the distance normalization is reused unchanged.
        CGPoint radialSource = sourcePoint;
        if (openDir == 6u) radialSource = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        void *renderer = axs_metalAssemblePlayRet(tex, frame, duration, density, radialSource);
        if (renderer == NULL) {
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            if (realReveal && card.layer.mask != nil) card.layer.mask = nil;  // .198 static hide-mask
            card.hidden = NO;
            axs_dm_log(@"OPEN assemble unavailable, native card restored");
            return;
        }
        // all fallback paths above already returned, so the assemble WILL run.
        // .157: the card stays hidden the WHOLE time; the Metal overlay draws
        // both the dust and the deposited real-card texels (all GPU).
        @try {
            // .198: style 3 keeps its accept-time static hide-mask here;
            // the driver below swaps in the clocked mask this same tick.
            if (!realReveal && card.layer.mask != nil) card.layer.mask = nil;
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
            // .208: only live-reveal styles remain -- the card stays visible
            // the whole time; the mask hides it until each cell opens.
            axs_open_revealLive = YES;
        } @catch (NSException *ignored) { }
        // .196: start the reveal mask on the renderer's EXACT clock so each
        // cell opens precisely when its dust grain lands.
        if (realReveal) {
            AXSOpenRevealDriver *drv = [AXSOpenRevealDriver new];
            CFTimeInterval metalStart = axs_metalAssembleStartTime(renderer);
            [drv startOnCard:card
                       start:(metalStart > 0 ? metalStart : CACurrentMediaTime())
                    duration:duration frame:frame density:density
                     radius:revealRadius
                    dirMode:openDir
                      source:radialSource];
            objc_setAssociatedObject(card, &axs_open_wipeDriverKey, drv,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            axs_dm_log(@"OPEN real reveal mask armed %lux%lu duration=%.2f",
                       (unsigned long)drv.cols, (unsigned long)drv.rows, duration);
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
        // .195: own weak capture.
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

// .236: dock flight guard -- dock 转场期间/尾部，open poll 会把重新出现的卡片
// （docked 几何或 docked item 本体）误判为呼出候选，在侧窗上再跑一遍完整
// assemble（双重聚合 + 浮窗圆角 36.8 的 corner kill 套在侧窗上=圆角对不上）。
// 转场矩形相关的候选在保卫窗口内一律跳过。
static CFAbsoluteTime axs_dock_flightGuardUntil = 0;
static CGRect axs_dock_guardFrameA = CGRectZero;
static CGRect axs_dock_guardFrameB = CGRectZero;

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
        // .236: dock flight guard -- 候选矩形与最近一次 dock 转场矩形相交时跳过，
        // 且不触碰 stale/self-restore 标记（守卫期过后由既有路径正常处理）。
        if (CACurrentMediaTime() < axs_dock_flightGuardUntil) {
            @try {
                CGRect cf = [v convertRect:v.bounds toView:nil];
                BOOL dockInvolved =
                    CGRectIntersectsRect(cf, axs_dock_guardFrameA)
                    || CGRectIntersectsRect(cf, axs_dock_guardFrameB);
                if (dockInvolved) {
                    axs_dm_log(@"OPEN candidate skipped (dock flight guard %.2fs)",
                               axs_dock_flightGuardUntil - CACurrentMediaTime());
                    return;
                }
            } @catch (NSException *ignored) { }
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
        // .194: hide at frame 0 for ALL styles (no real-card flash before the
        // cover overlay's first frame). .196: style 3 keeps the LIVE card
        // present (masked) from frame 0 -- it IS the revealed content.
        if (wantRealReveal) {
            // .196: no capture at all. The live window is shown through the
            // per-cell mask; there is no stale image to capture or deposit.
            // .198: hide the LIVE card behind a static full mask from the
            // accept frame. Between accept and the driver's first paint
            // (~90ms of poll settle) the card was previously visible
            // UNMASKED -> one-frame flash with square pale corners. An
            // empty CALayer has alpha 0 = fully hidden; the driver swaps
            // in its clocked mask seamlessly when it arms.
            axs_dm_log(@"OPEN real reveal accepted, snapshot bypassed");
            @try {
                CALayer *hideAll = [CALayer layer];
                hideAll.frame = card.bounds;
                hideAll.backgroundColor = [UIColor clearColor].CGColor;
                card.layer.mask = hideAll;
                objc_setAssociatedObject(card, &axs_open_staticMaskKey, hideAll,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UIView *wcard = card;
                __weak CALayer *wmask = hideAll;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        UIView *c = wcard;
                        CALayer *m = wmask;
                        if (c != nil && m != nil && c.layer.mask == m) c.layer.mask = nil;
                    } @catch (NSException *ignored) { }
                });
            } @catch (NSException *ignored) { }
            if (axs_open_shockwaveStyle()) {
                axs_open_playShockwave(card.window, sourcePoint);   // .207 style 4 opening
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
// .239: dock 态全局（addAnimation hook 与 enforce 共用；.238 定义在文件尾部
// 导致 hook 读不到——hook 需要在 dock 态吞掉 docked item 层树的动画，否则
// 原生延迟 2~3s 的「内容弹出+去侧倾」动画以 presentation 覆盖我们的 model tilt）。
static BOOL axs_dock_dockedState = NO;        // YES=当前处于 dock 侧窗态
static CGFloat axs_dock_dockedRadius = 0;     // docked item 真实圆角
static CGRect axs_dock_lastDockFrameRect = CGRectZero;   // 最近一次侧窗矩形
static __weak UIWindow *axs_dock_lastWindow = nil;
// .243: 场景内容栈压制（dock 期间隐藏，反向揭示完成后恢复）
static BOOL axs_dock_sceneSuppressed = NO;
static NSMutableArray *axs_dock_hiddenSceneViews = nil;
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
            // .239: dock 态下 docked item 层树动画一并吞掉——原生内容弹出后
            // 会以动画把 item 拉回正面，presentation 覆盖 model，我们的每帧
            // tilt 同步就失效了。completion 手动补发（与容器同款）。
            BOOL isDockItem = (delegate != nil && axs_dock_dockedState
                && strstr(object_getClassName(delegate), "DockedFloatingItem") != NULL);
            // .240: 原生动画常加在 item 的内容子层上（delegate 类名不是
            // DockedFloatingItem）——沿 superlayer 回溯判定是否处于 item 子树。
            if (!isDockItem && delegate != nil && axs_dock_dockedState) {
                CALayer *walk = (CALayer *)self;
                for (int hop = 0; walk != nil && hop < 6; hop++) {
                    id wd = walk.delegate;
                    if (wd != nil && strstr(object_getClassName(wd), "DockedFloatingItem") != NULL) {
                        isDockItem = YES;
                        break;
                    }
                    walk = walk.superlayer;
                }
            }
            if (delegate != nil
                && (strcmp(object_getClassName(delegate), "SCFloatingContainerView") == 0
                    || isDockItem)) {
                if (isDockItem) {
                    axs_dm_log(@"DOCK SWALLOW anim=%@ key=%@ on %s",
                               NSStringFromClass([anim class]), key ?: @"nil",
                               object_getClassName(delegate));
                }
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

// ===== beautify.235: 浮窗↔侧窗 混合架构（快照源消散 + 真视图逐帧揭示） ========
// 前置声明：定义在 dock 入口段（本块 reassertDst 每 tick 重找 docked item 用）。
static UIView *axs_dock_findDockedItem(UIWindow *win, CGRect targetFrame);
// .238: docked item 每帧 tilt 同步（定义在 dock 入口段，driver tick 与 ring 共用）。
void axs_dock_enforceDockedItemTilt(void);
// .234 实测结论（视频 86 + 日志 86 对齐）：
//   - 浮→侧：触发瞬间原生已把容器 frame 缩成侧窗（原生 dock spring 被
//     interceptUntil 吞掉→跳变），容器上的消散 mask 无效 → 浮窗整块瞬间消失；
//     侧窗本体由原生直接显示 → 整块直接出现。
//   - 侧→浮：docked item 被原生瞬间移除 → 瞬间消失；但容器（持久 view）的
//     逐格聚合是成功的（视频 4.0~4.6s 渐进聚合可见）。
//   即：持久 view（容器）挂 mask 有效；被原生接管的 endpoint 挂 mask 无效。
// .235 混合架构：
//   src（消散端）= 永远用连续快照层（整图 + 渐进 bitmap mask）——浮→侧用容器
//     缓存快照，侧→浮用触发瞬间对 docked item 的抓拍；真 src view 隐藏防重影。
//   dst（聚合端）= 永远用真 view（侧→浮=容器；浮→侧=SCDockedFloatingItemView）
//     逐格揭示：每 tick 验活（window/superview/类名），失效重找实例，
//     layer.mask 被覆盖则重挂，bounds 变化则校正 mask.frame，hidden 则恢复。
//     真圆角/真侧倾全部由系统原生渲染，绝不手动 transform。
//   Metal(openMode=3) 只画边界点对点细沙，纹理用 src 快照。
@interface AXSDockFlightDriver : NSObject
@property (nonatomic, weak)   UIWindow *win;
@property (nonatomic, strong) UIImage  *srcShot;
@property (nonatomic, strong) CALayer  *srcLayer;      // 快照消散层（连续整图）
@property (nonatomic, strong) CALayer  *srcMaskLayer;
@property (nonatomic, weak)   UIView   *srcView;       // 真 src（隐藏防重影，可 nil）
@property (nonatomic, assign) BOOL     srcSavedHidden;
@property (nonatomic, weak)   UIView   *dstView;       // 真聚合端（逐帧验活重挂）
@property (nonatomic, strong) CALayer  *dstMask;
@property (nonatomic, assign) BOOL     dstIsDocked;    // dst 是否 docked item（需重找）
@property (nonatomic, assign) CGRect   dstFrame;       // 重找匹配用（window 坐标）
@property (nonatomic, assign) BOOL     dstSavedHidden;
@property (nonatomic, strong) NSMutableData *srcBits;
@property (nonatomic, strong) NSMutableData *dstBits;
@property (nonatomic, assign) CGContextRef srcBmp;
@property (nonatomic, assign) CGContextRef dstBmp;
@property (nonatomic, assign) CFTimeInterval start;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) NSUInteger cols;
@property (nonatomic, assign) NSUInteger rows;
@property (nonatomic, assign) CGFloat srcW;
@property (nonatomic, assign) CGFloat srcH;
@property (nonatomic, assign) CGFloat dstW;
@property (nonatomic, assign) CGFloat dstH;
@property (nonatomic, assign) CGFloat srcCorner;
@property (nonatomic, assign) CGFloat dstCorner;
@property (nonatomic, assign) uint32_t departDir;
@property (nonatomic, assign) uint32_t arriveDir;
@property (nonatomic, assign) CGFloat srcTiltRad;     // .243: 消散层侧倾（反向=侧窗真实侧倾）
@property (nonatomic, assign) BOOL dstContentReady;   // .236: docked item 内容就绪前不揭示
@property (nonatomic, assign) CFTimeInterval dstRevealStart; // -1=未开始
- (void)startWithWindow:(UIWindow *)window
                srcShot:(UIImage *)srcShot
               srcFrame:(CGRect)srcFrame
                srcView:(UIView *)srcView
                dstView:(UIView *)dstView
               dstFrame:(CGRect)dstFrame
            dstIsDocked:(BOOL)dstIsDocked
               duration:(NSTimeInterval)duration
                density:(CGFloat)density
             srcCorner:(CGFloat)srcCorner
             dstCorner:(CGFloat)dstCorner
              srcTilt:(CGFloat)srcTiltRad
              departDir:(uint32_t)departDir
              arriveDir:(uint32_t)arriveDir;
- (void)stop;
@end

static inline CGFloat axs_dock_smooth(CGFloat a, CGFloat b, CGFloat x) {
    CGFloat t = (x - a) / (b - a);
    if (t < 0) t = 0; if (t > 1) t = 1;
    return t * t * (3.0 - 2.0 * t);
}

// 与 shader axsTransferOrder 完全一致（mode 0..7）。
static inline CGFloat axs_dock_order(CGFloat ux, CGFloat uy, uint32_t mode) {
    if (mode == 0u) return uy;
    if (mode == 1u) return 1.0f - uy;
    if (mode == 2u) return (ux + uy) * 0.5f;
    if (mode == 3u) return ((1.0f - ux) + uy) * 0.5f;
    if (mode == 4u) return (ux + (1.0f - uy)) * 0.5f;
    if (mode == 5u) return ((1.0f - ux) + (1.0f - uy)) * 0.5f;
    return ((1.0f - ux) + uy) * 0.5f;
}

@implementation AXSDockFlightDriver

- (CGContextRef)makeSrcBmp {
    NSUInteger bpr = self.cols * 4;
    NSMutableData *bits = [NSMutableData dataWithLength:bpr * self.rows];
    self.srcBits = bits;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate([bits mutableBytes], self.cols, self.rows,
                                             8, bpr, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    return bmp;
}
- (CGContextRef)makeDstBmp {
    NSUInteger bpr = self.cols * 4;
    NSMutableData *bits = [NSMutableData dataWithLength:bpr * self.rows];
    self.dstBits = bits;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate([bits mutableBytes], self.cols, self.rows,
                                             8, bpr, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    return bmp;
}

// src 快照消散层：连续整图 + 渐进 bitmap mask，插入窗口最底层。
- (void)installSrcLayerWithFrame:(CGRect)srcFrame {
    self.srcLayer = [CALayer layer];
    self.srcLayer.contents = (__bridge id)self.srcShot.CGImage;
    self.srcLayer.contentsGravity = kCAGravityResizeAspectFill;
    self.srcLayer.frame = srcFrame;
    self.srcLayer.masksToBounds = YES;
    // .242: 圆角只由 SDF mask 刻（层树里不再出现 12/36.8 的裸 CALayer 半径，
    // 防 ring 光晕半径探测被毒化）。视觉与 cornerRadius 完全一致。
    self.srcLayer.cornerRadius = 0.0f;
    self.srcLayer.shadowOpacity = 0.0f;
    // .243: 反向消散层带侧窗真实侧倾（DUMP：消散的是已侧倾的侧窗，不能变正面）
    if (self.srcTiltRad != 0.0f) {
        CGFloat rad = self.srcTiltRad;
        CATransform3D tiltRotation = CATransform3DRotate(CATransform3DIdentity, rad, 0.0, 1.0, 0.0);
        CGFloat sinRad = (CGFloat)sin(rad);
        CGFloat cosRad = (CGFloat)cos(rad);
        tiltRotation.m14 = -sinRad * (-1.0 / 600.0);
        tiltRotation.m34 =  cosRad * (-1.0 / 600.0);
        self.srcLayer.transform = tiltRotation;
    }
    self.srcMaskLayer = [CALayer layer];
    self.srcMaskLayer.frame = self.srcLayer.bounds;
    self.srcMaskLayer.contentsGravity = kCAGravityResize;
    self.srcLayer.mask = self.srcMaskLayer;
    self.srcW = srcFrame.size.width;
    self.srcH = srcFrame.size.height;
    @try { [self.win.layer insertSublayer:self.srcLayer atIndex:0]; } @catch (NSException *ignored) { }
}

// dst 真 view 挂渐进 bitmap mask。
- (void)attachDstMask {
    UIView *v = self.dstView;
    if (v == nil) return;
    if (self.dstMask == nil || v.layer.mask != self.dstMask) {
        CALayer *mask = [CALayer layer];
        mask.contentsGravity = kCAGravityResize;
        mask.frame = v.bounds;
        @try { v.layer.mask = mask; } @catch (NSException *ignored) { return; }
        self.dstMask = mask;
        self.dstW = v.bounds.size.width;
        self.dstH = v.bounds.size.height;
    } else if (self.dstMask.frame.size.width != v.bounds.size.width
               || self.dstMask.frame.size.height != v.bounds.size.height) {
        self.dstMask.frame = v.bounds;
        self.dstW = v.bounds.size.width;
        self.dstH = v.bounds.size.height;
    }
}

- (void)startWithWindow:(UIWindow *)window
                srcShot:(UIImage *)srcShot
               srcFrame:(CGRect)srcFrame
                srcView:(UIView *)srcView
                dstView:(UIView *)dstView
               dstFrame:(CGRect)dstFrame
            dstIsDocked:(BOOL)dstIsDocked
               duration:(NSTimeInterval)duration
                density:(CGFloat)density
             srcCorner:(CGFloat)srcCorner
             dstCorner:(CGFloat)dstCorner
              srcTilt:(CGFloat)srcTiltRad
              departDir:(uint32_t)departDir
              arriveDir:(uint32_t)arriveDir {
    self.win = window;
    self.srcTiltRad = srcTiltRad;
    self.srcShot = srcShot;
    self.srcView = srcView;
    self.dstView = dstView;
    self.dstFrame = dstFrame;
    self.dstIsDocked = dstIsDocked;
    self.duration = duration;
    self.departDir = departDir;
    self.arriveDir = arriveDir;
    self.srcCorner = srcCorner;
    self.dstCorner = dstCorner;
    // 网格与 Metal openMode=3 的 22000*density / aspect 对齐。
    int particles = (int)lround(22000.0 * density);
    if (particles < 200) particles = 200;
    if (particles > 48000) particles = 48000;
    CGFloat aspect = dstFrame.size.height > 0.5 ? dstFrame.size.width / dstFrame.size.height : 1.0;
    NSUInteger c = (NSUInteger)lround(sqrtf((float)particles * (float)aspect));
    NSUInteger r = (NSUInteger)((particles + (int)c - 1) / (int)c);
    if (c < 2) c = 2; if (c > 320) c = 320;
    if (r < 2) r = 2; if (r > 320) r = 320;
    self.cols = c; self.rows = r;

    // 隐藏真 src view 防重影（stop 时恢复原值）。
    if (self.srcView != nil) {
        self.srcSavedHidden = self.srcView.hidden;
        self.srcView.hidden = YES;
    }
    if (self.dstView != nil) {
        self.dstSavedHidden = self.dstView.hidden;
        // .237: dst 永远是 live card，dock 稳态被原生隐藏——揭示前强制显示，
        // 每 tick reassert 保活；stop 不再恢复 hidden（恢复会让窗口在揭示后消失）。
        self.dstView.hidden = NO;
    }
    [self installSrcLayerWithFrame:srcFrame];
    [self attachDstMask];
    self.srcBmp = [self makeSrcBmp];
    self.dstBmp = [self makeDstBmp];
    self.dstRevealStart = -1;
    self.dstContentReady = NO;
    if (self.dstIsDocked) {
        self.dstContentReady = [self dockedItemHasContent];
        if (self.dstContentReady) self.dstRevealStart = 0;
        axs_dm_log(@"DOCK FLIGHT dst content ready at start=%d", self.dstContentReady ? 1 : 0);
    }
    [self paintSrc:0.0];
    [self paintDst:0.0];
    self.start = CACurrentMediaTime();
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(dockFlightTick:)];
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// src: 按 depart 时钟逐格消隐（右上→左下先走），带真圆角 SDF。
- (void)paintSrc:(CGFloat)t {
    CGContextRef ctx = self.srcBmp;
    if (ctx == NULL || self.srcMaskLayer == nil) return;
    NSUInteger cols = self.cols, rows = self.rows;
    UInt8 *bytes = (UInt8 *)[self.srcBits mutableBytes];
    size_t bpr = cols * 4;
    memset(bytes, 0, bpr * rows);
    for (NSUInteger cy = 0; cy < rows; cy++) {
        CGFloat uy = (cy + 0.5f) / (CGFloat)rows;
        UInt8 *row = bytes + cy * bpr;
        for (NSUInteger cx = 0; cx < cols; cx++) {
            CGFloat ux = (cx + 0.5f) / (CGFloat)cols;
            uint32_t h = (uint32_t)cx * 73856093u ^ (uint32_t)cy * 19349663u ^ 83492791u;
            h ^= h >> 13u; h *= 1274126177u; h ^= h >> 16u;
            CGFloat hf = (CGFloat)(h & 0xffffu) / 65535.0f;
            CGFloat order = 0.96f * axs_dock_order(ux, uy, self.departDir) + 0.04f * hf;
            CGFloat depart = 0.02f + 0.50f * order;
            CGFloat a = 1.0f - axs_dock_smooth(depart - 0.006f, depart + 0.006f, t);
            CGFloat px = ux * self.srcW, py = uy * self.srcH;
            if (self.srcCorner > 0.5f && self.srcW > 1.0f && self.srcH > 1.0f) {
                CGFloat qx = fabs(px - self.srcW * 0.5f) - (self.srcW * 0.5f - self.srcCorner);
                CGFloat qy = fabs(py - self.srcH * 0.5f) - (self.srcH * 0.5f - self.srcCorner);
                CGFloat dxo = qx > 0 ? qx : 0, dyo = qy > 0 ? qy : 0;
                CGFloat inner = qx > qy ? qx : qy;
                CGFloat dOut = sqrtf(dxo * dxo + dyo * dyo) + (inner < 0 ? inner : 0) - self.srcCorner;
                a *= 1.0f - axs_dock_smooth(-1.5f, 1.5f, dOut);
            }
            UInt8 av = (UInt8)(a * 255.0f);
            UInt8 *q = row + cx * 4;
            q[0] = av; q[1] = av; q[2] = av; q[3] = av;
        }
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    if (img != NULL) {
        self.srcMaskLayer.contents = (__bridge id)img;
        CGImageRelease(img);
    }
}

// dst: 按 arrive 时钟逐格显现，带真圆角 SDF（真 view 的圆角/侧倾原生自渲染）。
- (void)paintDst:(CGFloat)t {
    CGContextRef ctx = self.dstBmp;
    if (ctx == NULL || self.dstMask == nil) return;
    NSUInteger cols = self.cols, rows = self.rows;
    UInt8 *bytes = (UInt8 *)[self.dstBits mutableBytes];
    size_t bpr = cols * 4;
    memset(bytes, 0, bpr * rows);
    for (NSUInteger cy = 0; cy < rows; cy++) {
        CGFloat uy = (cy + 0.5f) / (CGFloat)rows;
        UInt8 *row = bytes + cy * bpr;
        for (NSUInteger cx = 0; cx < cols; cx++) {
            CGFloat ux = (cx + 0.5f) / (CGFloat)cols;
            uint32_t h = (uint32_t)cx * 73856093u ^ (uint32_t)cy * 19349663u ^ 83492791u;
            h ^= h >> 13u; h *= 1274126177u; h ^= h >> 16u;
            CGFloat hf = (CGFloat)(h & 0xffffu) / 65535.0f;
            CGFloat order = 0.96f * axs_dock_order(ux, uy, self.arriveDir) + 0.04f * hf;
            CGFloat arrive = 0.38f + 0.56f * order;
            CGFloat a = axs_dock_smooth(arrive - 0.006f, arrive + 0.006f, t);
            CGFloat px = ux * self.dstW, py = uy * self.dstH;
            if (self.dstCorner > 0.5f && self.dstW > 1.0f && self.dstH > 1.0f) {
                CGFloat qx = fabs(px - self.dstW * 0.5f) - (self.dstW * 0.5f - self.dstCorner);
                CGFloat qy = fabs(py - self.dstH * 0.5f) - (self.dstH * 0.5f - self.dstCorner);
                CGFloat dxo = qx > 0 ? qx : 0, dyo = qy > 0 ? qy : 0;
                CGFloat inner = qx > qy ? qx : qy;
                CGFloat dOut = sqrtf(dxo * dxo + dyo * dyo) + (inner < 0 ? inner : 0) - self.dstCorner;
                a *= 1.0f - axs_dock_smooth(-1.5f, 1.5f, dOut);
            }
            UInt8 av = (UInt8)(a * 255.0f);
            UInt8 *q = row + cx * 4;
            q[0] = av; q[1] = av; q[2] = av; q[3] = av;
        }
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    if (img != NULL) {
        self.dstMask.contents = (__bridge id)img;
        CGImageRelease(img);
    }
}

// .236: docked item 内容就绪探测——内容（app 快照 image layer）被原生异步填充，
// 就绪前揭示只会得到「透明聚合」。逐层找 layer.contents != NULL。
- (BOOL)dockedItemHasContent {
    UIView *v = self.dstView;
    if (v == nil) return NO;
    if (v.layer.contents != NULL) return YES;
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
        int guardN = 0;
        while (stack.count > 0 && guardN++ < 240) {
            UIView *u = [stack lastObject];
            [stack removeLastObject];
            if (u == nil) continue;
            if (u.layer.contents != NULL) return YES;
            for (UIView *sub in u.subviews) [stack addObject:sub];
        }
    } @catch (NSException *ignored) { }
    return NO;
}

// .236: 内容就绪前 dst 全透明位图。
- (void)paintDstHidden {
    CGContextRef ctx = self.dstBmp;
    if (ctx == NULL || self.dstMask == nil) return;
    memset((UInt8 *)[self.dstBits mutableBytes], 0, self.cols * 4 * self.rows);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    if (img != NULL) {
        self.dstMask.contents = (__bridge id)img;
        CGImageRelease(img);
    }
}

// dst 每 tick 验活：docked item 可能被原生移除/重建，mask 可能被覆盖，
// hidden 可能被改动——逐项恢复，保证「逐格揭示真视图」始终成立。
- (void)reassertDst {
    UIView *v = self.dstView;
    BOOL alive = (v != nil && v.window != nil && v.superview != nil);
    if (alive && self.dstIsDocked
        && [NSStringFromClass(v.class) rangeOfString:@"DockedFloatingItem"].location == NSNotFound) {
        alive = NO;   // 实例被换成别的类：按失效处理
    }
    if (!alive && self.dstIsDocked) {
        UIView *found = axs_dock_findDockedItem(self.win, self.dstFrame);
        if (found != nil) {
            if (v != nil) { @try { if (v.layer.mask == self.dstMask) v.layer.mask = nil; } @catch (NSException *ignored) { } }
            self.dstView = found;
            self.dstMask = nil;   // 强制重挂
            v = found;
        }
    }
    if (v == nil) return;
    [self attachDstMask];
    if (self.dstView.hidden) self.dstView.hidden = NO;   // .237: live-card dst 强制保活
}

- (void)dockFlightTick:(CADisplayLink *)link {
    @try {
        CFTimeInterval elapsed = CACurrentMediaTime() - self.start;
        CGFloat t = self.duration > 0 ? (CGFloat)(elapsed / self.duration) : 1.0f;
        if (t < 0) t = 0; if (t > 1) t = 1;
        [self paintSrc:t];
        [self reassertDst];
        axs_dock_enforceDockedItemTilt();   // .238: item 与容器同 tilt（内容晚到也是侧倾）
        // .236: docked dst 的揭示由「内容就绪」门控——就绪前全透明；就绪后从
        // 此刻起跑子时钟（起飞时已就绪则铺满整个 flight）。真视图的圆角/侧倾
        // 仍由系统原生渲染，不施加任何 transform。
        if (self.dstIsDocked && !self.dstContentReady) {
            if ([self dockedItemHasContent]) {
                self.dstContentReady = YES;
                if (self.dstRevealStart < 0) self.dstRevealStart = elapsed;
                axs_dm_log(@"DOCK FLIGHT dst content became ready at %.2fs", elapsed);
            }
        }
        if (self.dstIsDocked) {
            if (!self.dstContentReady) {
                [self paintDstHidden];
            } else {
                CGFloat span = (self.dstRevealStart <= 0.001) ? MAX(self.duration, 0.5) : 0.8;
                CGFloat dstT = (CGFloat)((elapsed - self.dstRevealStart) / span);
                if (dstT < 0) dstT = 0; if (dstT > 1) dstT = 1;
                [self paintDst:dstT];
            }
        } else {
            [self paintDst:t];
        }
        if (t >= 1.0) [self paintSrc:1.0];
    } @catch (NSException *ignored) {
        [self stop];
    }
}

- (void)stop {
    @try {
        [_link invalidate]; _link = nil;
        if (self.srcLayer != nil) { @try { [self.srcLayer removeFromSuperlayer]; } @catch (NSException *ignored) { } self.srcLayer = nil; }
        self.srcMaskLayer = nil;
        if (self.dstView != nil) {
            @try { if (self.dstView.layer.mask == self.dstMask) self.dstView.layer.mask = nil; } @catch (NSException *ignored) { }
        }
        self.dstMask = nil;
        if (self.srcView != nil) self.srcView.hidden = self.srcSavedHidden;
        // .237: dst（live card）保持显示——dock 稳态就由它展示，恢复 hidden 会让
        // 侧窗在揭示完成后凭空消失（.236 实测）。
        if (_srcBmp != NULL) { CGContextRelease(_srcBmp); _srcBmp = NULL; }
        if (_dstBmp != NULL) { CGContextRelease(_dstBmp); _dstBmp = NULL; }
        self.srcBits = nil; self.dstBits = nil; self.srcShot = nil;
    } @catch (NSException *ignored) { }
}
@end

static char axs_dock_flightDriverKey;

// ===== beautify.228: 浮窗→侧窗 粒子聚合 ====================================
// 由 AxsBeautifyRing.xm 的 dock 翻转检测调用（浮窗变侧窗的那一帧）。
// 视觉：浮窗内容碎成粒子 → 从浮窗原位置飞向侧边 → 聚合成侧窗矩形 →
//       真侧窗显现，侧倾由现有 tilt 功能独立接管（终点保持矩形）。
// 完全 additive + 幂等：开关默认关；任何一步失败静默 no-op，绝不卡住原生 dock。
static BOOL axs_dock_assembleInFlight = NO;

static id axs_dock_pref(NSString *key, id def) {
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return def;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id v = imp(cfg, sel, key, def);
            return v != nil ? v : def;
        }
    } @catch (NSException *ignored) { }
    return def;
}

static UIView *axs_dock_findDockedItem(UIWindow *win, CGRect targetFrame) {
    UIView *best = nil;
    CGFloat bestDist = CGFLOAT_MAX;
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        int guard = 0;
        while (stack.count > 0 && guard++ < 600) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            if (v == nil) continue;
            NSString *cn = NSStringFromClass(v.class);
            if ([cn rangeOfString:@"DockedFloatingItem"].location != NSNotFound) {
                CGRect f = [v convertRect:v.bounds toView:nil];
                CGFloat dx = f.origin.x - targetFrame.origin.x;
                CGFloat dy = f.origin.y - targetFrame.origin.y;
                CGFloat dist = fabs(dx) + fabs(dy) + fabs(f.size.width - targetFrame.size.width);
                if (dist < bestDist) { bestDist = dist; best = v; }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    } @catch (NSException *ignored) { }
    return best;
}

// ===== beautify.238: docked item 每帧侧倾同步 + 圆角统一 ====================
// .237 实测：聚合完成 2~3 秒后原生把 docked item 的内容（正面、原生圆角）弹出
// 盖在容器上——item 不在容器树内，ring tilt 从不管理它 → 「右半正面左半侧倾」。
// 反向消散层用容器圆角 36.8，而侧窗稳态是 item 的原生圆角（更小）→「四角变更圆」。
// 修复：每帧给 item 施加与 ring 完全一致的 tilt（不隐藏、不动手势，内容弹出时
// 已是侧倾形态）；dock 期间容器圆角临时切到 item 真实值，反向恢复，消散层同源。
static CGFloat axs_dock_tiltAngleCfg(void) {
    CGFloat a = 3.0;
    id ta = axs_dock_pref(@"splitBeautifyTiltAngle", @3.0);
    if ([ta isKindOfClass:[NSNumber class]]) {
        a = [ta doubleValue];
        if (a < 0.0) a = 0.0;
        if (a > 30.0) a = 30.0;
    }
    if (a != a) a = 3.0;
    return a;
}

static CFAbsoluteTime axs_dock_dockedStateAt = 0;   // .241: 进入 dock 态的时刻

// .241: dock 态前 5s 内请求 ring 加速宿主探测（1s→0.1s）——原生为侧窗态
// 新建/重建的内容子视图会被即刻 tilt，杜绝「正面 2~3s 后才侧倾」。
BOOL axs_dock_probeBoost(void) {
    return (axs_dock_dockedState
            && axs_dock_lastWindow != nil
            && (CACurrentMediaTime() - axs_dock_dockedStateAt) < 5.0);
}

// .241: 一次性诊断转储——列出所有窗口中与目标矩形相交的可见视图
// （类名/frame/圆角/clips/hidden/alpha），定位正面内容与直角光晕来源。
static void axs_dock_dumpViewsAtFrame(CGRect frame, NSString *tag) {
    @try {
        axs_dm_log(@"DOCK DUMP [%@] begin frame=%@", tag, NSStringFromCGRect(frame));
        NSArray<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
        for (UIScene *sc in scenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w == nil || w.hidden) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                int guardN = 0;
                while (stack.count > 0 && guardN++ < 900) {
                    UIView *v = [stack lastObject];
                    [stack removeLastObject];
                    if (v == nil) continue;
                    CGRect f = [v convertRect:v.bounds toView:nil];
                    BOOL intersects = CGRectIntersectsRect(f, frame);
                    BOOL dockSized = f.size.width > 30.0 && f.size.width < 200.0
                                     && f.size.height > 60.0;
                    if (intersects && dockSized && !v.hidden && v.alpha > 0.05) {
                        axs_dm_log(@"DOCK DUMP [%@] %@ win=%@ frame=%@ corner=%.1f clips=%d alpha=%.2f contents=%@",
                                   tag, NSStringFromClass(v.class), NSStringFromClass(w.class),
                                   NSStringFromCGRect(f), v.layer.cornerRadius,
                                   v.layer.masksToBounds ? 1 : 0, v.alpha,
                                   v.layer.contents != NULL ? @"YES" : @"NO");
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        axs_dm_log(@"DOCK DUMP [%@] end", tag);
    } @catch (NSException *ignored) { }
}

// .242: 收集 dock 矩形上的「App 场景内容栈」链根。DUMP 93 铁证：dock 翻转时
// 原生把 _UIScenePresentationView 宿主链移出容器（ring tilt 宿主明确排除
// scene 根）→ 应用真实画面正面显示在侧窗矩形上。排除容器子树（ring 域）、
// overlay/手势区、item（单独 tilt）；对候选沿同尺寸祖先链爬到链根，避免链上
// 多层重复 tilt。
static NSArray *axs_dock_sceneRootsAt(UIWindow *win, CGRect dockFrame) {
    NSMutableArray *roots = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        int guardN = 0;
        while (stack.count > 0 && guardN++ < 900) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            if (v == nil) continue;
            NSString *cn = NSStringFromClass(v.class);
            BOOL excluded = [cn hasPrefix:@"SCFloating"]
                         || [cn isEqualToString:@"SCDockedFloatingItemView"]
                         || [cn isKindOfClass:[UIWindow class]];
            if (excluded) continue;   // 不下探容器子树（ring 域）/item/overlay
            CGRect f = [v convertRect:v.bounds toView:nil];
            BOOL dockSized = fabs(f.origin.x - dockFrame.origin.x) < 9.0
                          && fabs(f.origin.y - dockFrame.origin.y) < 9.0
                          && fabs(f.size.width - dockFrame.size.width) < 12.0
                          && fabs(f.size.height - dockFrame.size.height) < 14.0;
            if (dockSized && !v.hidden && v.alpha > 0.5) {
                UIView *root = v;
                while (root.superview != nil) {
                    UIView *p = root.superview;
                    NSString *pcn = NSStringFromClass(p.class);
                    if ([pcn hasPrefix:@"SCFloating"] || [p isKindOfClass:[UIWindow class]]) break;
                    CGRect pf = [p convertRect:p.bounds toView:nil];
                    if (fabs(pf.origin.x - dockFrame.origin.x) > 11.0
                        || fabs(pf.origin.y - dockFrame.origin.y) > 11.0
                        || fabs(pf.size.width - dockFrame.size.width) > 14.0
                        || fabs(pf.size.height - dockFrame.size.height) > 16.0) break;
                    root = p;
                }
                if (root != nil && ![seen containsObject:root]) {
                    [seen addObject:root];
                    [roots addObject:root];
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    } @catch (NSException *ignored) { }
    return roots;
}

// .243: 场景链成员里 cornerRadius>0.5 的那一层就是侧窗的可见圆角
// （DUMP 93：docked item/container 自身 corner=0，真实 36.8 在场景内容裁剪层）。
static CGFloat axs_dock_sceneCornerRadiusAt(UIWindow *win, CGRect dockFrame) {
    CGFloat found = 0;
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        int guardN = 0;
        while (stack.count > 0 && guardN++ < 900) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            if (v == nil) continue;
            NSString *cn = NSStringFromClass(v.class);
            BOOL excluded = [cn hasPrefix:@"SCFloating"]
                         || [cn isEqualToString:@"SCDockedFloatingItemView"]
                         || [cn isKindOfClass:[UIWindow class]];
            if (!excluded && v.layer.cornerRadius > 0.5f) {
                CGRect f = [v convertRect:v.bounds toView:nil];
                if (fabs(f.origin.x - dockFrame.origin.x) < 9.0
                    && fabs(f.origin.y - dockFrame.origin.y) < 9.0
                    && fabs(f.size.width - dockFrame.size.width) < 12.0
                    && fabs(f.size.height - dockFrame.size.height) < 14.0) {
                    if (v.layer.cornerRadius > found) found = v.layer.cornerRadius;
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
    } @catch (NSException *ignored) { }
    return found;
}

// 由 ring applyTilt 每帧 + driver tick 调用；自门控（非 dock 态直接返回）。
void axs_dock_enforceDockedItemTilt(void) {
    @try {
        if (!axs_dock_dockedState || axs_dock_lastWindow == nil) return;
        // .239: 对窗口树内【全部】DockedFloatingItem 实例施加 tilt——原生可能
        // 重建实例，只 tilt 最近匹配会把 transform 留在被替换的旧实例上。
        NSMutableArray *items = [NSMutableArray array];
        @try {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:axs_dock_lastWindow];
            int guardN = 0;
            while (stack.count > 0 && guardN++ < 600) {
                UIView *v = [stack lastObject];
                [stack removeLastObject];
                if (v == nil) continue;
                if ([NSStringFromClass(v.class)
                     rangeOfString:@"DockedFloatingItem"].location != NSNotFound) {
                    [items addObject:v];
                }
                [stack addObjectsFromArray:v.subviews];
            }
        } @catch (NSException *ignored) { }
        if (items.count == 0) return;
        // 与 AxsBeautifyRing.axs_ring_applyTilt 逐字同款：GAIN 2.6 + 显式 m14/m34。
        CGFloat sw = axs_dock_lastWindow.bounds.size.width;
        CGRect f0 = [(UIView *)items[0] convertRect:[(UIView *)items[0] bounds] toView:nil];
        BOOL rightSide = (f0.origin.x + f0.size.width * 0.5f) > sw * 0.5f;
        CGFloat rad = (rightSide ? -1.0 : 1.0) * axs_dock_tiltAngleCfg() * 2.6 * M_PI / 180.0;
        CATransform3D tiltRotation = CATransform3DRotate(CATransform3DIdentity, rad, 0.0, 1.0, 0.0);
        CGFloat sinRad = (CGFloat)sin(rad);
        CGFloat cosRad = (CGFloat)cos(rad);
        tiltRotation.m14 = -sinRad * (-1.0 / 600.0);
        tiltRotation.m34 =  cosRad * (-1.0 / 600.0);
        static CFTimeInterval axs_dock_enforceLogAt = 0;
        BOOL logNow = (CACurrentMediaTime() - axs_dock_enforceLogAt > 1.0);
        for (UIView *item in items) {
            if (item == nil || item.layer == nil) continue;
            if (item.hidden) item.hidden = NO;   // 侧窗本体应可见（壳保持可命中）
            // .240: 直接子视图=原生延迟弹出的正面内容载体——隐藏之，正面内容
            // 无论带什么动画都不再可见；壳本体与命中测试不受影响。
            for (UIView *sub in item.subviews) {
                if (sub != nil && !sub.hidden) sub.hidden = YES;
            }
            item.layer.transform = tiltRotation;
            if (logNow) {
                NSMutableString *kids = [NSMutableString string];
                for (UIView *sub in item.subviews) {
                    [kids appendFormat:@"%@(hidden=%d) ", NSStringFromClass(sub.class), sub.hidden ? 1 : 0];
                }
                axs_dm_log(@"DOCK ENFORCE items=%lu tilt=%.1f contents=%@ kids=[%@]",
                           (unsigned long)items.count, rad * 180.0 / M_PI,
                           item.layer.contents != NULL ? @"YES" : @"NO", kids);
            }
        }
        if (logNow) axs_dock_enforceLogAt = CACurrentMediaTime();
        // .243: App 场景内容栈直接隐藏（.242 的 tilt 会被场景机器每帧重写自身
        // transform 覆盖，斗不过）。dock 侧窗由容器独立渲染（揭示期已验证内容
        // 完整），场景栈是 TouchPassthrough 不承载触摸，隐藏安全。反向揭示
        // 完成后由 dock 入口统一恢复。
        if (axs_dock_sceneSuppressed) {
            @try {
                for (UIView *rootView in axs_dock_sceneRootsAt(axs_dock_lastWindow, axs_dock_lastDockFrameRect)) {
                    if (!rootView.hidden) {
                        rootView.hidden = YES;
                        [axs_dock_hiddenSceneViews addObject:rootView];
                    }
                }
            } @catch (NSException *ignored) { }
        }
    } @catch (NSException *ignored) { }
}

// container : SCFloatingContainerView（真浮窗容器）
// fromFrame : 消散源矩形（window 坐标）——浮窗或侧窗
// toFrame   : 聚合目标矩形（window 坐标）
// toDock    : YES=浮窗→侧窗；NO=侧窗→浮窗
// beautify.235: 混合架构——src 永远快照层逐格消散（浮→侧用容器缓存快照；
// 侧→浮用触发瞬间对 docked item 的抓拍，因为原生会瞬间移除它）；dst 永远
// 真 view 逐格揭示（浮→侧=docked item，每 tick 验活重找重挂；侧→浮=容器，
// .234 已证实有效）。真圆角/真侧倾由系统原生渲染。
void axs_dockAssemblePlay(UIView *container, CGRect fromFrame, CGRect toFrame, BOOL toDock) {
    @try {
        if (container == nil || container.window == nil) return;
        id sw = axs_dock_pref(@"splitBeautifyDockAnimEnabled", @NO);
        if (![sw isKindOfClass:[NSNumber class]] || ![sw boolValue]) {
            axs_dm_log(@"DOCK FLIGHT skipped (switch off)");
            return;
        }
        if (axs_dock_assembleInFlight) return;
        CGFloat speed = 1.0;
        id sp = axs_dock_pref(@"splitBeautifyDockSpeed", @1.0);
        if ([sp isKindOfClass:[NSNumber class]]) {
            speed = [sp floatValue];
            if (speed < 0.3) speed = 0.3;
            if (speed > 3.0) speed = 3.0;
        }
        if (speed != speed || speed <= 0.0) speed = 1.0;
        CGFloat density = 1.0;
        id de = axs_dock_pref(@"splitBeautifyDockDensity", @1.0);
        if ([de isKindOfClass:[NSNumber class]]) {
            density = [de floatValue];
            if (density < 0.5) density = 0.5;
            if (density > 3.0) density = 3.0;
        }
        if (density != density || density <= 0.0) density = 1.0;
        CGFloat duration = 1.15 / speed;
        if (toFrame.size.width < 8.0 || toFrame.size.height < 8.0) return;
        if (CGRectIsEmpty(fromFrame)) fromFrame = toFrame;

        UIWindow *win = container.window;
        axs_dock_lastWindow = win;
        axs_dock_lastDockFrameRect = toDock ? toFrame : fromFrame;

        // .239: dock 态切换。不再 mutate 容器圆角——.238 的 36.8→12 临时修改
        // 毒化了 ring 光晕的路径半径探测（光晕用 12 建浮窗 mask → 直角边，
        // 缓存 3~4s 才刷新）。圆角统一改为只走 mask SDF。
        UIView *dockItem = axs_dock_findDockedItem(win, toDock ? toFrame : fromFrame);
        // .243: 侧窗可见圆角=场景内容裁剪层（36.8，DUMP 铁证），item 自身
        // cornerRadius(12) 不是可见圆角——优先读场景链，item 值兜底。
        CGFloat sceneR = axs_dock_sceneCornerRadiusAt(win, toDock ? toFrame : fromFrame);
        if (sceneR > 0.5f) {
            axs_dock_dockedRadius = sceneR;
        } else if (dockItem != nil && dockItem.layer.cornerRadius > 0.5f) {
            axs_dock_dockedRadius = dockItem.layer.cornerRadius;
        }
        if (toDock) {
            axs_dock_dockedState = YES;
            axs_dock_dockedStateAt = CACurrentMediaTime();
            axs_dock_sceneSuppressed = YES;                 // .243: 场景栈压制开始
            if (axs_dock_hiddenSceneViews == nil) axs_dock_hiddenSceneViews = [NSMutableArray array];
            if (dockItem != nil) dockItem.layer.transform = CATransform3DIdentity;   // enforce 从 identity 起施加
        } else {
            axs_dock_dockedState = NO;
            if (dockItem != nil) {
                dockItem.layer.transform = CATransform3DIdentity;   // 交还原生
                for (UIView *sub in dockItem.subviews) {            // .240: 恢复被隐藏的内容子视图
                    if (sub != nil) sub.hidden = NO;
                }
            }
            // .243: 场景栈保持隐藏到反向揭示完成（下方 dispatch_after 恢复），
            // 避免它在飞行途中以正面形态插回浮窗矩形。
        }

        // .237: dst 永远是真容器（live card）。日志 88 实测：docked item 的
        // layer.contents 只是占位/装饰（start=1 却揭示出透明空壳），真实内容由
        // 原生异步填充且晚 5~6 秒才出现（出现还是正面，等 ring tilt 重探测才
        // 侧倾）。容器是持久、内容常驻、由 ring tilt 管理侧倾的真视图——
        // .235 open hook 误揭示容器时用户看到的就是正确的侧窗。
        // src 两向都用容器缓存快照（浮窗与侧窗 aspect ratio 一致，aspectFill
        // 即原生外观）。dock 稳态原生隐藏容器，dst 揭示前强制 unhide。
        UIImage *srcShot = axs_open_cachedCardSnapshotForView(container);
        if (srcShot == nil) srcShot = axs_open_captureVisibleCardCheap(container);
        if (srcShot == nil) srcShot = axs_dm_snapshot(container);
        if (srcShot == nil) {
            axs_dm_log(@"DOCK FLIGHT skipped (no src snapshot)");
            return;
        }

        UIView *dstView = container;
        CGRect dstFrame = toFrame;

        // .242: 圆角按「窗口真实外观」取值——DUMP 93 证实容器自身 corner=0，
        // 浮窗真实圆角 36.8 在场景内容裁剪层（树探测可得），侧窗真实圆角 12
        // 在 docked item 上。容器 layer.cornerRadius 读数(0)会掉进 12 兜底，
        // 正是「浮窗四角直角光晕」的来源。
        CGFloat srcCorner = toDock ? axs_dm_cornerRadiusForView(container)
                                   : (axs_dock_dockedRadius > 0.5f ? axs_dock_dockedRadius
                                                                   : axs_dm_cornerRadiusForView(container));
        CGFloat dstCorner = toDock ? (axs_dock_dockedRadius > 0.5f ? axs_dock_dockedRadius
                                                                   : axs_dm_cornerRadiusForView(dstView))
                                   : axs_dm_cornerRadiusForView(dstView);
        if (srcCorner < 1.0f) srcCorner = 12.0f;
        if (dstCorner < 1.0f) dstCorner = 12.0f;

        // 方向：源端总是右上→左下(3)；浮窗→侧窗目标右上→左下(3)，
        // 侧窗→浮窗目标左下→右上(4)。
        uint32_t departDir = 3u;
        uint32_t arriveDir = toDock ? 3u : 4u;

        // 边界细沙粒子（shader openMode=3），纹理=src 快照。
        void *renderer = axs_metalDockTransferPlayRet(srcShot, fromFrame, toFrame,
                                                      duration, density, departDir, arriveDir);
        if (renderer == nil) {
            axs_dm_log(@"DOCK FLIGHT metal unavailable -> native restore");
            return;
        }

        // .236: 保卫窗口覆盖 flight + 内容等待尾巴；候选矩形与转场矩形相交的
        // open 候选一律跳过（防第二次聚合 + 浮窗圆角 corner kill 污染侧窗）。
        axs_dock_flightGuardUntil = CACurrentMediaTime() + duration + 2.3;
        axs_dock_guardFrameA = fromFrame;
        axs_dock_guardFrameB = toFrame;

        // 快速连翻时停掉上一个 driver（mask/hidden 恢复后由新 driver 接管）。
        AXSDockFlightDriver *oldDrv = objc_getAssociatedObject(container, &axs_dock_flightDriverKey);
        if (oldDrv != nil) [oldDrv stop];

        // .243: 反向消散层侧倾=侧窗真实侧倾（右贴朝中心，与 enforce 同款）
        CGFloat srcTiltRad = 0.0;
        BOOL wasToDock = toDock;   // .244: 停止块按方向分流（正向不得解除场景压制）
        if (!toDock) {
            CGFloat screenW2 = win.bounds.size.width;
            BOOL rightSide2 = (fromFrame.origin.x + fromFrame.size.width * 0.5f) > screenW2 * 0.5f;
            srcTiltRad = (rightSide2 ? -1.0 : 1.0) * axs_dock_tiltAngleCfg() * 2.6 * M_PI / 180.0;
        }

        AXSDockFlightDriver *driver = [AXSDockFlightDriver new];
        [driver startWithWindow:win
                        srcShot:srcShot
                       srcFrame:fromFrame
                        srcView:nil
                        dstView:dstView
                       dstFrame:dstFrame
                    dstIsDocked:NO
                       duration:duration
                        density:density
                     srcCorner:srcCorner
                     dstCorner:dstCorner
                      srcTilt:srcTiltRad
                      departDir:departDir
                      arriveDir:arriveDir];
        objc_setAssociatedObject(container, &axs_dock_flightDriverKey, driver,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        axs_dock_assembleInFlight = YES;
        axs_dm_log(@"DOCK FLIGHT play from=%@ to=%@ toDock=%d dep=%u arr=%u dur=%.2f dens=%.2f srcR=%.1f dstR=%.1f gate=%d snap-src live-card-dst",
                   NSStringFromCGRect(fromFrame), NSStringFromCGRect(toFrame),
                   toDock ? 1 : 0, departDir, arriveDir, duration, density,
                   srcCorner, dstCorner, driver.dstContentReady ? 1 : 0);

        // .241: 一次性诊断转储——正向在内容弹出时刻(+1.5s)扫侧窗矩形，
        // 反向在浮窗揭示中(+0.6s)扫浮窗矩形，定位正面内容与直角光晕来源。
        {
            CGRect dumpFrame = toFrame;   // 正向扫侧窗矩形，反向扫浮窗矩形
            NSString *dumpTag = toDock ? @"fwd+1.5s" : @"rev+0.6s";
            NSTimeInterval dumpDelay = toDock ? 1.5 : 0.6;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(dumpDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                axs_dock_dumpViewsAtFrame(dumpFrame, dumpTag);
            });
        }

        __weak UIView *wcard = container;
        // .240: driver 停止回归 duration+0.15——tail(duration+2.0) 期间容器
        // mask 挂着，与「光晕在浮窗聚合完成后晚 2~3s 才出现」的时刻两次精确
        // 吻合（dstIsDocked=NO 后内容门控已不需要尾巴）。mask 一撤光晕即回。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((duration + 0.15) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            axs_dock_assembleInFlight = NO;
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((duration + 0.18) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIView *c = wcard;
                if (c != nil) {
                    AXSDockFlightDriver *drv = objc_getAssociatedObject(c, &axs_dock_flightDriverKey);
                    [drv stop];
                    objc_setAssociatedObject(c, &axs_dock_flightDriverKey, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                // .244: 只有反向（侧→浮）结束才恢复场景内容栈并解除压制。
                // .243 的恢复块正/反向共用——正向 flight 结束（1.33s）就把场景栈
                // 放回来了，DUMP 95 实锤 1.5s 时场景链全部 hidden=NO，正面内容
                // 随即盖住侧窗（「还是有啊」的直接原因）。
                if (!wasToDock) {
                    for (UIView *sv in axs_dock_hiddenSceneViews) {
                        if (sv != nil) sv.hidden = NO;
                    }
                    [axs_dock_hiddenSceneViews removeAllObjects];
                    axs_dock_sceneSuppressed = NO;
                }
            } @catch (NSException *ignored) { }
        });
    } @catch (NSException *ignored) {
        axs_dock_assembleInFlight = NO;
    }
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
