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
void *axs_metalAssemblePlayRet(UIImage *shot, UIImage *shotB, CGRect frameInWindow, CGFloat duration,
                               CGFloat density, CGPoint sourcePoint,
                               CGRect sourceRect, CGFloat cornerRadius);
// .183: the Metal tick fires this ONCE when min(dock) >= 0.999 -- the same-frame
// handoff that restores the real card and drops the overlay in one runloop turn.
void axs_msd_setRevealSwapFn(void (*fn)(void));
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
        // .169: migrate any snapshots stored under the old Documents path so
        // nothing is lost when upgrading from .168.
        NSString *oldDir = @"/var/mobile/Documents/sc-open-cache";
        NSArray *old = [fm contentsOfDirectoryAtPath:oldDir error:NULL];
        for (NSString *f in old) {
            if (![f.pathExtension isEqualToString:@"png"]) continue;
            NSString *dst = [dir stringByAppendingPathComponent:f];
            if (![fm fileExistsAtPath:dst]) {
                [fm moveItemAtPath:[oldDir stringByAppendingPathComponent:f]
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

// .176: reject captures whose CENTER is transparent. The accept-time
// pre-hide capture runs before the remote content attaches and contains only
// chrome pixels; caching it overwrote the good dismiss-time snapshot and the
// next open deposited an empty texture (probe: alpha 0 0 0 0 -> dust-only).
static BOOL axs_dm_centerHasContent(UIImage *img) {
    @try {
        if (img == nil || img.CGImage == NULL) return NO;
        CGImageRef cg = img.CGImage;
        size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
        if (w == 0 || h == 0) return NO;
        const size_t S = 32;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        if (cs == NULL) return NO;
        uint8_t px[S * S * 4];
        CGContextRef ctx = CGBitmapContextCreate(px, S, S, 8, S * 4, cs,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        if (ctx == NULL) { CGColorSpaceRelease(cs); return NO; }
        CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)S, (CGFloat)S), cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        // .177: MAJORITY rule -- "any pixel" let sparse-chrome empty captures
        // (remote content not attached yet) pass and poison the cache.
        size_t opaqueCount = 0;
        for (size_t y = 10; y < 22; y++) {
            for (size_t x = 10; x < 22; x++) {
                if (px[(y * S + x) * 4 + 3] > 8) opaqueCount++;
            }
        }
        return opaqueCount >= 72;
    } @catch (NSException *ignored) {
        return NO;
    }
}

// .183: the cached dismiss-time snapshot is the CARD texture for openParticle.
static UIImage *axs_open_cachedCardSnapshotForView(UIView *owner) {
    @try {
        if (owner == nil) return nil;
        NSString *key = axs_open_windowKeyForView(owner);
        if (key == nil) return nil;
        UIImage *img = axs_open_snapshotCache[key];
        if (img == nil) {
            NSString *pngPath = [[axs_open_cacheDir()
                                  stringByAppendingPathComponent:key]
                                 stringByAppendingPathExtension:@"png"];
            img = [UIImage imageWithContentsOfFile:pngPath];
            if (img != nil) axs_open_snapshotCache[key] = img;
        }
        return img;
    } @catch (NSException *ignored) {
        return nil;
    }
}

static void axs_open_cacheCardSnapshot(UIView *owner, UIImage *img) {
    @try {
        if (owner == nil || img == nil || img.CGImage == NULL) return;
        if (CGImageGetWidth(img.CGImage) < 256 || CGImageGetHeight(img.CGImage) < 256) return;
        if (!axs_dm_centerHasContent(img)) {
            axs_dm_log(@"OPEN snapshot rejected (empty center)");
            return;
        }
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
                // .170: encode at 2x -- a full 3x PNG encode competed with
                // the dissolve animation and read as seconds of lag.
                UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
                fmt.opaque = NO;
                fmt.scale = 2.0;
                UIGraphicsImageRenderer *r =
                    [[UIGraphicsImageRenderer alloc] initWithBounds:CGRectMake(0, 0, pngImg.size.width, pngImg.size.height) format:fmt];
                UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx2) {
                    [pngImg drawInRect:CGRectMake(0, 0, pngImg.size.width, pngImg.size.height)];
                }];
                NSData *png = UIImagePNGRepresentation(small);
                if (png != nil) [png writeToFile:pngPath atomically:YES];
            } @catch (NSException *ignored) { }
        });
    } @catch (NSException *ignored) { }
}


static BOOL axs_dm_imageIsBlank(UIImage *img);   // defined later in this file
static UIImage *axs_dm_roundSnapshot(UIImage *img, UIView *refView);   // defined later in this file


static CGFloat axs_dm_cornerRadiusForView(UIView *view);   // defined later
static UIImage *axs_dm_roundSnapshot(UIImage *img, UIView *refView);   // defined later
static UIImage *axs_dm_fixSnapshotCorners(UIImage *img, UIView *refView);   // defined later
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
            // .180: the outermost rounded background layer defines the visible
            // corner radius -- take the largest, not the first.
            if (layer.backgroundColor != NULL && r > *bgRadius) *bgRadius = r;
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

// true-corner probe: are the four corners of the image opaque?
// .170: sample four tiny corner TILES via CGImageCreateWithImageInRect --
// the previous version re-rasterized the whole 1.4MP image just to read four
// pixels, up to 3 captures per close cycle, which read as seconds of lag.
static BOOL axs_dm_cornersAreOpaque(UIImage *img) {
    @try {
        if (img == nil || img.CGImage == NULL) return NO;
        CGImageRef cg = img.CGImage;
        size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
        if (w == 0 || h == 0) return NO;
        size_t ts = 8;
        if (ts > w) ts = w;
        if (ts > h) ts = h;
        CGRect rects[4] = {
            CGRectMake(0, 0, (CGFloat)ts, (CGFloat)ts),
            CGRectMake((CGFloat)(w - ts), 0, (CGFloat)ts, (CGFloat)ts),
            CGRectMake(0, (CGFloat)(h - ts), (CGFloat)ts, (CGFloat)ts),
            CGRectMake((CGFloat)(w - ts), (CGFloat)(h - ts), (CGFloat)ts, (CGFloat)ts),
        };
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        if (cs == NULL) return NO;
        uint8_t tiles[4][64 * 4];
        BOOL opaque = NO;
        for (int i = 0; i < 4 && !opaque; i++) {
            CGImageRef tile = CGImageCreateWithImageInRect(cg, rects[i]);
            if (tile == NULL) { opaque = YES; break; }
            CGContextRef ctx = CGBitmapContextCreate(tiles[i], ts, ts, 8, ts * 4, cs,
                                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            if (ctx != NULL) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)ts, (CGFloat)ts), tile);
                CGContextRelease(ctx);
                size_t c = ts / 2;
                if (tiles[i][(c * ts + c) * 4 + 3] > 8) opaque = YES;
            } else {
                opaque = YES;
            }
            CGImageRelease(tile);
        }
        CGColorSpaceRelease(cs);
        return opaque;
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
        // .175: DO NOT clear the container backgrounds -- the rounded dark
        // background IS the card content; clearing it made the texture nearly
        // transparent (probe: alpha 0 0 0 133) and the reveal vanished.
        // Capture as-is and clip the square corners with the measured radius.
        UIImage *shot = axs_dm_fixSnapshotCorners(axs_dm_snapshot(sourceView), sourceView);
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
static CFAbsoluteTime axs_open_lastAssembleStart = -1e9;
static __weak UIView *axs_open_currentCard = nil;
static CFAbsoluteTime axs_open_assembleStartAt = 0;
static UIImage *axs_open_cardTexture = nil;
static UIImage *axs_open_sourceTexture = nil;
static CGRect axs_open_sourceRect = CGRectZero;
static CGFloat axs_open_cornerR = 0.0;

static CGFloat axs_open_lastAssembleDur = 0.0;
static BOOL axs_open_dismissedSinceAssemble = NO;
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

// .146: wipe driver association key (declared early so markGone can clear it)
static char axs_open_wipeDriverKey;

static void axs_open_markGone(UIView *v) {
    objc_setAssociatedObject(v, &axs_open_goneKey, @(CACurrentMediaTime()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// .134: particle color = the card's background color (pure data read from
// the layer -- no rendering involved). The calculator is dark -> dark
// fragments, exactly like the reference video. Fallback: white.

// .145: colored sand texture for the open reveal. The reference plugin's
// grains are vivid cyan/purple/orange, NOT fragments of the whole screen --
// .144 cut the home-screen clock into the particles by capturing the full
// _UIScenePresentationView. A generated gradient gives every grain a stable
// color (the shader samples it with a per-cell hash) with zero capture cost.

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
// .183: THE SAME-FRAME HANDOFF -- fired by the Metal tick when min(dock)
// >= 0.999. Restores the real card (alpha/visibility) and logs; the Metal
// side removes the overlay immediately after this returns.
static void axs_open_revealSwap(void) {
    @try {
        UIView *card = axs_open_currentCard;
        if (card == nil) return;
        card.alpha = 1.0;
        if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), NO);
        } else if (axs_open_orig_setHidden == (IMP)1) {
            struct objc_super sup = { (id)card, class_getSuperclass(object_getClass(card)) };
            ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, @selector(setHidden:), NO);
        }
        axs_dm_log(@"OPEN openParticle reveal elapsed=%.3f hiddenCard=0",
                   CACurrentMediaTime() - axs_open_assembleStartAt);
        axs_open_setAssembled(card, YES);
        axs_open_openActiveUntil = CACurrentMediaTime() + 3.0;
        axs_open_currentCard = nil;
    } @catch (NSException *ignored) { }
}

// .183: capture the tapped dock icon as the SOURCE texture (60x60pt crop at
// 2x around the touch point) -- the dust grains carry these pixels into the
// window ("icon cell N lands on window cell N").
static UIImage *axs_open_captureSourceIcon(CGPoint center) {
    @try {
        UIView *snap = [[UIScreen mainScreen] snapshotViewAfterScreenUpdates:NO];
        if (snap == nil) return nil;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.scale = 2.0;
        fmt.opaque = YES;
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:snap.bounds format:fmt];
        UIImage *full = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [snap drawViewHierarchyInRect:snap.bounds afterScreenUpdates:NO];
        }];
        if (full == nil || full.CGImage == NULL) return nil;
        CGFloat scale = 2.0;
        CGFloat w = snap.bounds.size.width, h = snap.bounds.size.height;
        CGFloat x0 = center.x - 30.0, y0 = center.y - 30.0;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x0 + 60.0 > w) x0 = w - 60.0;
        if (y0 + 60.0 > h) y0 = h - 60.0;
        if (x0 < 0 || y0 < 0 || w < 60.0 || h < 60.0) return nil;
        CGRect crop = CGRectMake(x0 * scale, y0 * scale, 60.0 * scale, 60.0 * scale);
        CGImageRef piece = CGImageCreateWithImageInRect(full.CGImage, crop);
        if (piece == NULL) return nil;
        UIImage *out = [UIImage imageWithCGImage:piece];
        CGImageRelease(piece);
        return out;
    } @catch (NSException *ignored) {
        return nil;
    }
}

// .183: openParticle style switch (default 1; 0 = native present, no particles)
static int axs_open_stylePref(void) {
    @try {
        Class cfgClass = objc_getClass("AxsHoldLaunchConfig");
        if (cfgClass == nil) return 1;
        id cfg = [cfgClass performSelector:@selector(axs_holdlaunch_shared)];
        SEL sel = @selector(axs_holdlaunch_theirValueForKey:defaultValue:);
        if (cfg != nil && [cfg respondsToSelector:sel]) {
            id (*imp)(id, SEL, id, id) = (id (*)(id, SEL, id, id))[cfg methodForSelector:sel];
            id value = imp(cfg, sel, @"splitBeautifyOpenStyle", @1);
            if ([value isKindOfClass:[NSNumber class]]) return [value intValue];
        }
    } @catch (NSException *ignored) { }
    return 1;
}

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


// blank probe: samples the alpha channel on a sparse grid.
// .170: draw into a tiny 64x64 buffer instead of re-rasterizing the whole
// 1.4MP image (up to 3 captures per close cycle read as seconds of lag).
static BOOL axs_dm_imageIsBlank(UIImage *img) {
    if (img == nil || img.CGImage == NULL) return YES;
    CGImageRef cg = img.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return YES;
    const size_t S = 64;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (cs == NULL) return YES;
    uint8_t px[S * S * 4];
    CGContextRef ctx = CGBitmapContextCreate(px, S, S, 8, S * 4, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx == NULL) { CGColorSpaceRelease(cs); return YES; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)S, (CGFloat)S), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    for (size_t i = 0; i < S * S; i++) {
        if (px[i * 4 + 3] > 8) return NO;
    }
    return YES;
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
        // .183: the CARD texture (cached dismiss-time snapshot) and the SOURCE
        // texture (tapped icon crop) -- both required for openParticle.
        UIImage *cardTex = axs_open_cachedCardSnapshotForView(card);
        if (cardTex != nil && cardTex.CGImage != NULL
            && CGImageGetWidth(cardTex.CGImage) >= 256
            && axs_dm_centerHasContent(cardTex)) {
            tex = cardTex;
        }
        if (tex == nil) {
            axs_dm_log(@"OPEN openParticle abort reason=card texture blank");
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            card.alpha = 1.0;
            card.hidden = NO;
            axs_open_currentCard = nil;
            return;
        }
        UIImage *srcTex = axs_open_sourceTexture;
        if (srcTex == nil || srcTex.CGImage == NULL) {
            axs_dm_log(@"OPEN openParticle abort reason=no source texture");
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            card.alpha = 1.0;
            card.hidden = NO;
            axs_open_currentCard = nil;
            return;
        }
        if (tex == nil) {
            axs_dm_log(@"OPEN texture unavailable, native card restored");
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            card.hidden = NO;
            return;
        }
        axs_open_cornerR = axs_dm_cornerRadiusForView(card);
        CGRect srcRect = axs_open_sourceRect;
        axs_msd_setRevealSwapFn(axs_open_revealSwap);
        void *renderer = axs_metalAssemblePlayRet(tex, srcTex, frame, duration, density, sourcePoint,
                                                  srcRect, axs_open_cornerR);
        if (renderer == NULL) {
            axs_open_assembleInFlight = NO;
            axs_open_armSelfRestore();
            card.alpha = 1.0;
            card.hidden = NO;
            axs_open_currentCard = nil;
            axs_dm_log(@"OPEN openParticle abort reason=metal unavailable");
            return;
        }
        // all fallback paths above already returned, so the assemble WILL run.
        // .157: the card stays hidden the WHOLE time; the Metal overlay draws
        // both the dust and the deposited real-card texels (all GPU).
        @try {
            if (card.layer.mask != nil) card.layer.mask = nil;
            card.alpha = 1.0;
        } @catch (NSException *ignored) { }
        axs_open_assembleStartAt = CACurrentMediaTime();
        axs_dm_log(@"OPEN openParticle grains=%d grid=%dx%d dur=%.2f srcTex=%lux%lu cardTex=%lux%lu srcRect=(%.0f,%.0f,%.0f,%.0f) targetRect=(%.0f,%.0f,%.0f,%.0f) corner=%.1f",
                   96 * 144, 96, 144, duration,
                   (unsigned long)CGImageGetWidth(srcTex.CGImage),
                   (unsigned long)CGImageGetHeight(srcTex.CGImage),
                   (unsigned long)CGImageGetWidth(tex.CGImage),
                   (unsigned long)CGImageGetHeight(tex.CGImage),
                   srcRect.origin.x, srcRect.origin.y, srcRect.size.width, srcRect.size.height,
                   frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                   axs_open_cornerR);
        // .182: the real card is VISIBLE beneath the cover overlay from now
        // on (unhidden through the ORIGINAL IMP so our own hook does not
        // re-enter); the cover hides it until each cell is revealed.
        if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
            ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), NO);
        } else if (axs_open_orig_setHidden == (IMP)1) {
            struct objc_super sup = { (id)card, class_getSuperclass(object_getClass(card)) };
            ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, @selector(setHidden:), NO);
        }
        // .157: ALL-GPU reveal. The card stays hidden for the whole animation;
        // the Metal overlay deposits real-card texels per cell with the same
        // hash clock as the dust (openMode=2 pass). No CAShapeLayer mask, no
        // per-frame CPU path rebuild. Disarm the intercept window, make the
        // hidden state explicit through the ORIGINAL IMP, then start the async
        // capture retry so the deposit pass gets the real texture mid-flight.
        axs_open_interceptUntil = 0;
        @try {
            card.alpha = 1.0;
            if (axs_open_orig_setHidden != NULL && axs_open_orig_setHidden != (IMP)1) {
                ((void (*)(id, SEL, BOOL))axs_open_orig_setHidden)(card, @selector(setHidden:), YES);
            } else {
                card.hidden = YES;
            }
        } @catch (NSException *ignored) { }
        __weak UIView *weakCardTex = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCardTex;
            if (c != nil) axs_open_gpuTextureRetry(c, renderer, 30);
        });
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * 0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *c = weakCardTex;
            if (c != nil) {
                axs_open_assembleInFlight = NO;
                axs_open_armSelfRestore();
            }
        });
        // .183: no endWipeReveal timer -- the same-frame swap fires from the
        // Metal tick when min(dock) >= 0.999.
        return;
    } @catch (NSException *ignored) {
        axs_open_assembleInFlight = NO;
        card.hidden = NO;
    }
}

static void axs_open_becameVisible(UIView *v) {
    @try {
        // .144: a card already owned by an assemble is STILL the same visible
        // window -- its own reveal and ScreenCore's repeated presents must not
        // start a new assemble. This is persistent (unlike selfRestore) and is
        // cleared only on a genuine dismiss / off-window.
        // .149: but if the flag survives PAST our animation window while no
        // assemble is running, it is STALE (a dismissal path missed its
        // release). Skipping then eats a genuine open -- no particles, card
        // pops in. Release the stale flag and fall through to accept.
        // .180/.181: hard guard against double aggregation -- candidates within
        // a recent assemble window are skipped UNLESS a genuine dismiss happened
        // since (a dismiss releases the assembled flag and must not swallow the
        // next open's animation).
        if (!axs_open_dismissedSinceAssemble &&
            CACurrentMediaTime() - axs_open_lastAssembleStart < axs_open_lastAssembleDur + 0.6) {
            axs_dm_log(@"OPEN candidate skipped (recent assemble)");
            return;
        }
        axs_open_dismissedSinceAssemble = NO;
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
            if (CACurrentMediaTime() - axs_open_selfRestoreAt > 0.15) {
                axs_dm_log(@"OPEN orphaned self-restore flag released, re-assembling");
            } else {
                axs_dm_log(@"OPEN candidate skipped (self restore)");
                return;
            }
        }
        // .149: within the open-ownership window every extra visibility event
        // is ours (repeated presents, overlay cleanup), even if the assembled
        // flag was cleared behind our back by a racing dismissal safety net.
        {
            CFAbsoluteTime nowB = CACurrentMediaTime();
            if (nowB < axs_open_openActiveUntil) {
                axs_dm_log(@"OPEN candidate skipped (open still active %.2fs)",
                           axs_open_openActiveUntil - nowB);
                return;
            }
        }
        if (v.window == nil) return;
        if (v.bounds.size.width < 40 || v.bounds.size.height < 40) return;
        CFAbsoluteTime nowT = CACurrentMediaTime();
        NSNumber *gone = objc_getAssociatedObject(v, &axs_open_goneKey);
        CGFloat goneAt = gone ? [gone doubleValue] : -1e9;
        if (nowT - goneAt < 0.15) {
            axs_dm_log(@"OPEN candidate skipped (quick toggle %.2fs)", nowT - goneAt);
            return;
        }
        if (!axs_open_enabled()) {
            axs_dm_log(@"OPEN candidate ignored (switch off)");
            return;
        }
        if (axs_open_stylePref() != 1) {
            axs_dm_log(@"OPEN skipped (openStyle=%d native present)", axs_open_stylePref());
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
        // .149: own the card for the whole assemble+reveal+cleanup window
        axs_open_openActiveUntil = CACurrentMediaTime() + duration + 0.3;
        axs_open_lastAssembleStart = CACurrentMediaTime();
        axs_open_lastAssembleDur = duration;
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
        // .182: the pre-hide card capture is gone -- the reveal no longer
        // paints cached card texels at all (the real card is uncovered
        // beneath the wallpaper cover instead).
        // .122: hide from frame 0 (invisible). The native present animation is
        // NOT intercepted -- it still runs and its completions still fire, but
        // the addAnimation hook clamps its duration to 0.01s so it finishes
        // instantly behind our particles (see axs_open_addAnimation).
        // .123: the whole flow runs OUTSIDE the UIKit window-setup stack and
        // the poll uses weak captures only (see axs_open_pollStep) -- no
        // block-copy of strong view captures anywhere.
        card.hidden = YES;
        // .183: openParticle -- the REAL card goes transparent (alpha=0) while
        // the overlay paints the dust + the card-texture tiles; the same-frame
        // swap restores alpha when every cell has docked.
        card.alpha = 0.0;
        axs_open_currentCard = card;
        // .183: capture the tapped dock icon as the SOURCE texture
        axs_open_sourceTexture = axs_open_captureSourceIcon(sourcePoint);
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
                axs_open_armSelfRestore();
                // .144: the dismiss is complete -- release the card so the
                // user's NEXT genuine open can assemble. Until now the card
                // stayed "assembled" and every repeated present during the
                // dismiss was ignored.
                axs_open_setAssembled(container, NO);
                // .181: a genuine dismiss happened -- allow the next open's
                // animation even inside the recent-assemble window.
                axs_open_dismissedSinceAssemble = YES;
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
