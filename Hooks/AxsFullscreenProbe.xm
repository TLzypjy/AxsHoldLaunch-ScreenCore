#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>

// Declare the substrate hooking entry point explicitly: this translation unit
// has no %hook block, so Logos does not inject substrate.h here. Declaring the
// symbol directly avoids depending on header injection order across .xm files.
#ifdef __cplusplus
extern "C" {
#endif
void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);
#ifdef __cplusplus
}
#endif

// ---------------------------------------------------------------------------
// beautify.96 - STEP 0: large-floating-window -> fullscreen probe
//
// Hooks ONLY to log; never changes a return value, argument, or control flow.
// Goal: capture the real call order, the moment source rect becomes available,
// the target (fullscreen bounds) timing, and completion callback timing.
//
// Safety rules:
//   1. Before hooking, verify every non-self argument is an object pointer
//      ('@' or '#'). Any primitive (BOOL/NSInteger/CGRect) => SKIP that hook
//      and print its type encoding instead. (An id-typed param on a primitive
//      method gets ARC-retained and crashes - see holdlaunch history.)
//   2. Hook only the FIRST class declaring each selector (avoids orig clobber).
//   3. All logging inside @try; a logging failure never reaches SpringBoard.
//   4. Delayed re-probe up to 12s for late-registered classes, per-selector
//      once-only guard, so no double hook.
// ---------------------------------------------------------------------------

static NSString * const AXS_FS_LOG_PATH = @"/var/mobile/Documents/sc-fullscreen-probe.log";

static void axs_fs_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_fs_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AxsHoldLaunch:FSP] %@", message);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:AXS_FS_LOG_PATH error:nil];
        if ([[attr objectForKey:NSFileSize] unsignedLongLongValue] > 512 * 1024) {
            [fm removeItemAtPath:AXS_FS_LOG_PATH error:nil];
            attr = nil;
        }
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                          [[NSDate date] timeIntervalSince1970], message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:AXS_FS_LOG_PATH];
        if (handle == nil) {
            [line writeToFile:AXS_FS_LOG_PATH atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *ignored) {
        // logging must never take the host process down
    }
}

static unsigned long long axs_fs_seq = 0;

static NSString *axs_fs_desc(id obj) {
    if (obj == nil) return @"nil";
    @try {
        NSString *cls = NSStringFromClass([obj class]);
        if ([obj isKindOfClass:[UIView class]]) {
            UIView *v = (UIView *)obj;
            return [NSString stringWithFormat:@"%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f",
                    cls, NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
                    v.hidden ? 1 : 0, v.alpha];
        }
        NSString *d = [obj description];
        if (d.length > 140) d = [d substringToIndex:140];
        return [NSString stringWithFormat:@"%@ %@", cls, d];
    } @catch (NSException *e) {
        return @"<desc-error>";
    }
}

// Non-self arguments all object pointers? Strip type qualifiers first.
static BOOL axs_fs_argsAreObjects(Method m, NSUInteger expected) {
    if (m == NULL) return NO;
    unsigned int n = method_getNumberOfArguments(m);
    if (n != expected + 2) return NO;
    for (unsigned int i = 2; i < n; i++) {
        char *raw = method_copyArgumentType(m, i);
        if (raw == NULL) return NO;
        const char *p = raw;
        while (*p && strchr("rnNoORV", *p)) p++;
        BOOL ok = (p[0] == '@' || p[0] == '#');
        free(raw);
        if (!ok) return NO;
    }
    return YES;
}

static Class axs_fs_firstClassDeclaring(SEL sel) {
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

// --- replacements: call original with the SAME signature, then log ----------

static IMP axs_orig_fs_handleTap = NULL;
static void axs_fs_handleTap(id self, SEL _cmd, id arg) {
    unsigned long long seq = ++axs_fs_seq;
    axs_fs_log(@"#%llu IN  sc_handleFullscreenTap: self=%@ arg=%@",
               seq, axs_fs_desc(self), axs_fs_desc(arg));
    if (axs_orig_fs_handleTap != NULL) {
        ((void (*)(id, SEL, id))axs_orig_fs_handleTap)(self, _cmd, arg);
    }
    axs_fs_log(@"#%llu OUT sc_handleFullscreenTap:", seq);
}

static IMP axs_orig_fs_didRequest = NULL;
static void axs_fs_didRequest(id self, SEL _cmd, id arg) {
    unsigned long long seq = ++axs_fs_seq;
    axs_fs_log(@"#%llu IN  sc_floatingContainerViewDidRequestFullscreen: self=%@ arg=%@",
               seq, axs_fs_desc(self), axs_fs_desc(arg));
    if (axs_orig_fs_didRequest != NULL) {
        ((void (*)(id, SEL, id))axs_orig_fs_didRequest)(self, _cmd, arg);
    }
    axs_fs_log(@"#%llu OUT sc_floatingContainerViewDidRequestFullscreen:", seq);
}

static IMP axs_orig_fs_promoteSession = NULL;
static void axs_fs_promoteSession(id self, SEL _cmd, id manager, id session, id completion) {
    unsigned long long seq = ++axs_fs_seq;
    axs_fs_log(@"#%llu IN  promoteSceneToFullscreenForSession self=%@ manager=%@ session=%@ completion=%@",
               seq, axs_fs_desc(self), axs_fs_desc(manager),
               axs_fs_desc(session), completion ? @"non-nil" : @"nil");
    if (axs_orig_fs_promoteSession != NULL) {
        ((void (*)(id, SEL, id, id, id))axs_orig_fs_promoteSession)(
            self, _cmd, manager, session, completion);
    }
    axs_fs_log(@"#%llu OUT promoteSceneToFullscreenForSession", seq);
}

static IMP axs_orig_fs_promoteFrontmost = NULL;
static void axs_fs_promoteFrontmost(id self, SEL _cmd) {
    unsigned long long seq = ++axs_fs_seq;
    axs_fs_log(@"#%llu IN  sc_promoteFrontmostFloatingSceneToFullscreen self=%@",
               seq, axs_fs_desc(self));
    if (axs_orig_fs_promoteFrontmost != NULL) {
        ((void (*)(id, SEL))axs_orig_fs_promoteFrontmost)(self, _cmd);
    }
    axs_fs_log(@"#%llu OUT sc_promoteFrontmostFloatingSceneToFullscreen", seq);
}

// --- installer --------------------------------------------------------------

static NSMutableSet *axs_fs_hookedNames = nil;

static void axs_fs_installSelector(NSString *name, NSUInteger argCount,
                                   IMP replacement, IMP *original, NSString *tag) {
    if ([axs_fs_hookedNames containsObject:name]) return;
    SEL sel = NSSelectorFromString(name);
    Class cls = axs_fs_firstClassDeclaring(sel);
    if (cls == Nil) {
        axs_fs_log(@"PROBE %@ selector absent (will retry): %@", tag, name);
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    const char *enc = method_getTypeEncoding(m);
    BOOL safe = axs_fs_argsAreObjects(m, argCount);
    axs_fs_log(@"PROBE %@ class=%@ enc=%s argsSafe=%d",
               tag, NSStringFromClass(cls), enc ? enc : "?", safe ? 1 : 0);
    if (!safe) {
        [axs_fs_hookedNames addObject:name];  // signature unsafe: skip permanently
        axs_fs_log(@"PROBE %@ SKIPPED (primitive args): %@", tag, name);
        return;
    }
    MSHookMessageEx(cls, sel, replacement, original);
    [axs_fs_hookedNames addObject:name];
    axs_fs_log(@"PROBE %@ HOOKED on %@", tag, NSStringFromClass(cls));
}

static void axs_fs_installAll(void) {
    if (axs_fs_hookedNames == nil) axs_fs_hookedNames = [NSMutableSet set];
    axs_fs_installSelector(@"sc_handleFullscreenTap:", 1,
                           (IMP)axs_fs_handleTap, &axs_orig_fs_handleTap, @"tap");
    axs_fs_installSelector(@"sc_floatingContainerViewDidRequestFullscreen:", 1,
                           (IMP)axs_fs_didRequest, &axs_orig_fs_didRequest, @"request");
    axs_fs_installSelector(@"sc_floatingSceneManager:promoteSceneToFullscreenForSession:completion:", 3,
                           (IMP)axs_fs_promoteSession, &axs_orig_fs_promoteSession, @"promoteSession");
    axs_fs_installSelector(@"sc_promoteFrontmostFloatingSceneToFullscreen", 0,
                           (IMP)axs_fs_promoteFrontmost, &axs_orig_fs_promoteFrontmost, @"promoteFront");
}

%ctor {
    @autoreleasepool {
        if (objc_getClass("SpringBoard") == nil) return;
        axs_fs_log(@"FSP module loaded in SpringBoard (beautify.96, log-only probe)");
        axs_fs_installAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_fs_installAll(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ axs_fs_installAll(); });
    }
}
