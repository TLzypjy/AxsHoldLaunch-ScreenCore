// ---------------------------------------------------------------------------
// beautify.104 - Metal fine-sand renderer, ported from the reference plugin
// (com.example.noticelisttweak / NoticeListTweak.dylib mode 2). The whole card
// is uploaded as ONE texture and rendered as columns*rows instanced quads in a
// SINGLE drawPrimitives call on the GPU. No per-grain CALayer, no main-thread
// per-frame work -> fine sand (14000 grains) without the UIView stutter.
//
// The MSL source below is reconstructed from the shader embedded verbatim in
// the reference dylib (strings showed the full source; single "}" lines were
// dropped by the extractor and are restored here). It is compiled at runtime
// with newLibraryWithSource and cached, exactly like the reference plugin.
// ---------------------------------------------------------------------------

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- logging (shares the dismiss log so one file tells the whole story) ----
static NSString * const AXS_MSD_LOG_PATH = @"/var/mobile/Documents/sc-dismiss-effect.log";
static void axs_msd_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void axs_msd_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:AXS_MSD_LOG_PATH error:nil];
        if ([[attr objectForKey:NSFileSize] unsignedLongLongValue] > 512 * 1024) {
            [fm removeItemAtPath:AXS_MSD_LOG_PATH error:nil];
        }
        NSString *line = [NSString stringWithFormat:@"%.3f [MSD] %@\n",
                          [[NSDate date] timeIntervalSince1970], message];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:AXS_MSD_LOG_PATH];
        if (h == nil) {
            [line writeToFile:AXS_MSD_LOG_PATH atomically:YES
                     encoding:NSUTF8StringEncoding error:nil];
        } else {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *ignored) {
    }
}

// ---- MSL source (reconstructed from the reference dylib) -------------------
static NSString * const AXS_MSD_SHADER = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct DustUniforms {\n\
    float2 viewport;\n\
    float2 origin;\n\
    float2 cardSize;\n\
    uint columns;\n\
    uint rows;\n\
    float time;\n\
    float distance;\n\
    float seed;\n\
    float notificationSweep;\n\
};\n\
struct DustVertex {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
    float2 local;\n\
    float fade;\n\
    float breakage;\n\
};\n\
float dustHash(float2 v) {\n\
    return fract(sin(dot(v, float2(127.1,311.7))) * 43758.5453);\n\
}\n\
vertex DustVertex nlDustVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],\n\
                              constant DustUniforms& u [[buffer(0)]]) {\n\
    const float2 corners[6] = {float2(0,0),float2(1,0),float2(0,1),\n\
                              float2(1,0),float2(1,1),float2(0,1)};\n\
    float2 cell = float2(instanceID % u.columns, instanceID / u.columns);\n\
    float2 grid = float2(u.columns, u.rows);\n\
    float2 unit = (cell+0.5)/grid;\n\
    float2 corner = corners[vertexID];\n\
    float2 noiseCell = cell + float2(u.seed, u.seed*0.371);\n\
    float r = dustHash(noiseCell);\n\
    float r2 = dustHash(noiseCell + 19.7);\n\
    float r3 = dustHash(noiseCell + 72.3);\n\
    bool fineSand = u.notificationSweep>1.5;\n\
    float frontier = u.notificationSweep>0.5 ? unit.x*0.34 + unit.y*0.02\n\
                                            : (1.0-unit.x)*0.25 + unit.y*0.075;\n\
    float begin = frontier + r*(u.notificationSweep>0.5 ? 0.04 : 0.095);\n\
    if (fineSand) begin = (unit.x + 1.0-unit.y)*0.18 + r*0.025;\n\
    float progress = clamp((u.time-begin)/(0.56 + 0.035*r2), 0.0, 1.0);\n\
    float burst = smoothstep(0.0,0.18,progress);\n\
    float motion = pow(progress,1.12);\n\
    float dx = (0.62 + 1.05*r)*u.distance*motion;\n\
    float dy = -(0.45 + 1.05*r2)*u.distance*motion\n\
               + sin(progress*7.0+r3*6.283)*u.distance*0.13*motion;\n\
    dx += (r2-0.5)*u.distance*0.40*motion;\n\
    float2 tileSize = u.cardSize/grid;\n\
    float shrink = mix(1.0, mix(0.24,0.56,r3), smoothstep(0.01,0.65,progress));\n\
    float2 delta = (corner-0.5)*tileSize*shrink;\n\
    float angle = (r3-0.5)*4.8*motion;\n\
    float c=cos(angle),s=sin(angle);\n\
    delta=float2(c*delta.x-s*delta.y,s*delta.x+c*delta.y);\n\
    float2 p = u.origin + unit*u.cardSize + delta + float2(dx,dy);\n\
    DustVertex out;\n\
    out.position=float4(2.0*p.x/u.viewport.x-1.0,1.0-2.0*p.y/u.viewport.y,0,1);\n\
    out.uv=(cell+corner)/grid;\n\
    out.local=corner;\n\
    out.fade=1.0-smoothstep(0.32+0.20*r2,1.0,progress);\n\
    out.breakage=burst;\n\
    return out;\n\
}\n\
fragment float4 nlDustFragment(DustVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {\n\
    constexpr sampler sampleImage(coord::normalized,address::clamp_to_edge,filter::linear);\n\
    float4 color=image.sample(sampleImage,in.uv);\n\
    float roundDust=1.0-smoothstep(0.34,0.53,length(in.local-0.5));\n\
    float shape=mix(1.0,roundDust,in.breakage);\n\
    return color*(in.fade*shape);\n\
}\n";

// C-side mirror of DustUniforms. MSL float2 is 8-byte aligned; total = 48 bytes.
typedef struct {
    float viewport[2];
    float origin[2];
    float cardSize[2];
    uint32_t columns;
    uint32_t rows;
    float time;
    float distance;
    float seed;
    float notificationSweep;
} AXSMetalDustUniforms;

// ---- cached device + pipeline (compiled once, reused for every dismissal) --
static id<MTLDevice> sMsdDevice = nil;
static id<MTLRenderPipelineState> sMsdPipeline = nil;
static BOOL sMsdTried = NO;

static BOOL axs_msd_ensurePipeline(void) {
    if (sMsdTried) return (sMsdPipeline != nil);
    sMsdTried = YES;
    @try {
        sMsdDevice = MTLCreateSystemDefaultDevice();
        if (sMsdDevice == nil) {
            axs_msd_log(@"metal device unavailable");
            return NO;
        }
        NSError *err = nil;
        id<MTLLibrary> lib = [sMsdDevice newLibraryWithSource:AXS_MSD_SHADER
                                                      options:nil error:&err];
        if (lib == nil) {
            axs_msd_log(@"metal shader compile FAILED: %@", [err localizedDescription]);
            return NO;
        }
        id<MTLFunction> vf = [lib newFunctionWithName:@"nlDustVertex"];
        id<MTLFunction> ff = [lib newFunctionWithName:@"nlDustFragment"];
        if (vf == nil || ff == nil) {
            axs_msd_log(@"metal functions missing vf=%d ff=%d", vf != nil, ff != nil);
            return NO;
        }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf;
        pd.fragmentFunction = ff;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        // CG bitmap pixels are premultiplied -> one / oneMinusSourceAlpha
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        NSError *pe = nil;
        sMsdPipeline = [sMsdDevice newRenderPipelineStateWithDescriptor:pd error:&pe];
        if (sMsdPipeline == nil) {
            axs_msd_log(@"metal pipeline FAILED: %@", [pe localizedDescription]);
            return NO;
        }
        axs_msd_log(@"metal compiled OK pipeline ready");
        return YES;
    } @catch (NSException *e) {
        axs_msd_log(@"metal ensurePipeline EXCEPTION %@", [e reason]);
        return NO;
    }
}

// ---- a UIView whose backing layer is a CAMetalLayer ------------------------
@interface AXSMetalSandView : UIView
@end
@implementation AXSMetalSandView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

// ---- retain active renderers so ARC does not collect them mid-animation ----
static NSMutableArray *sMsdActiveRenderers = nil;

// ---- renderer: owns texture, overlay, display link; one instance per burst -
@interface AXSMetalSandRenderer : NSObject
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) UIWindow *overlay;
@property (nonatomic, assign) CFTimeInterval start;
@property (nonatomic, assign) CGFloat duration;
@property (nonatomic, assign) AXSMetalDustUniforms u;
@property (nonatomic, assign) int grainCount;
- (BOOL)startWithTexture:(id<MTLTexture>)tex
                  frame:(CGRect)frame
               viewport:(CGSize)viewport
               duration:(CGFloat)dur
                overlay:(UIWindow *)win
                   view:(AXSMetalSandView *)view
                   seed:(float)seed
               particles:(int)count;
@end

@implementation AXSMetalSandRenderer

- (BOOL)startWithTexture:(id<MTLTexture>)tex
                  frame:(CGRect)frame
               viewport:(CGSize)viewport
               duration:(CGFloat)dur
                overlay:(UIWindow *)win
                   view:(AXSMetalSandView *)view
                   seed:(float)seed
               particles:(int)count {
    self.texture = tex;
    self.duration = dur;
    self.overlay = win;
    self.grainCount = count;
    self.metalLayer = (CAMetalLayer *)view.layer;

    AXSMetalDustUniforms u = {{0}};
    u.viewport[0] = (float)viewport.width;
    u.viewport[1] = (float)viewport.height;
    u.origin[0] = (float)frame.origin.x;
    u.origin[1] = (float)frame.origin.y;
    u.cardSize[0] = (float)frame.size.width;
    u.cardSize[1] = (float)frame.size.height;
    // distribute `count` cells by card aspect ratio -> roughly square grains
    CGFloat aspect = frame.size.height > 0.5 ? frame.size.width / frame.size.height : 1.0;
    uint32_t cols = (uint32_t)lround(sqrtf((float)count * (float)aspect));
    if (cols < 2) cols = 2; if (cols > 240) cols = 240;
    uint32_t rows = (uint32_t)((count + (int)cols - 1) / (int)cols);
    if (rows < 2) rows = 2; if (rows > 240) rows = 240;
    u.columns = cols;
    u.rows = rows;
    u.time = 0.0f;
    u.distance = 110.0f;     // DustDistance default
    u.seed = seed;
    u.notificationSweep = 2.0f;  // mode 2 = lock-screen fine sand (BL -> TR)
    self.u = u;

    // .105: explicitly set the drawable pixel size. Without this the freshly
    // created CAMetalLayer may report a zero/1x1 drawable and nextDrawable
    // silently fails -> nothing ever renders.
    CGSize layerPt = view.bounds.size;
    if (layerPt.width <= 0 || layerPt.height <= 0) layerPt = viewport;
    CGFloat scale = self.metalLayer.contentsScale > 0 ? self.metalLayer.contentsScale : 1.0;
    self.metalLayer.drawableSize = CGSizeMake(layerPt.width * scale, layerPt.height * scale);

    // Force layout so the layer has real geometry before the first draw.
    [view layoutIfNeeded];
    [overlay layoutIfNeeded];

    // .105: synchronous first-frame probe. Draw time=0 (full image, grains at
    // rest) ONCE right now. If the whole Metal chain works we get YES; if the
    // layer/drawable/pipeline is broken we get NO and can fall back to UIView
    // instead of claiming success with nothing visible.
    BOOL firstFrameOK = [self renderOnce];
    axs_msd_log(@"metal first-frame probe %@ drawable=%lux%lu layer=%lux%lu",
                firstFrameOK ? @"OK" : @"FAIL",
                (unsigned long)self.metalLayer.drawableSize.width,
                (unsigned long)self.metalLayer.drawableSize.height,
                (unsigned long)layerPt.width, (unsigned long)layerPt.height);
    if (!firstFrameOK) {
        self.texture = nil;
        self.metalLayer = nil;
        return NO;
    }

    self.start = CACurrentMediaTime();
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return YES;
}

- (BOOL)renderOnce {
    if (sMsdPipeline == nil || self.texture == nil || self.metalLayer == nil) return NO;
    // .105: guard against a zero-sized layer -> nextDrawable returns nil and
    // the whole render silently no-ops (the .104 "no visible effect" bug).
    if (self.metalLayer.bounds.size.width <= 0 || self.metalLayer.bounds.size.height <= 0) {
        return NO;
    }
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (drawable == nil) return NO;
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    // objc_msgSend avoids a clang protocol-method lookup quirk on this SDK for
    // newCommandBuffer; runtime behaviour is identical to the bracket form.
    id<MTLCommandBuffer> cb = ((id<MTLCommandBuffer> (*)(id, SEL))objc_msgSend)(
        sMsdDevice, @selector(newCommandBuffer));
    if (cb == nil) return NO;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (enc == nil) return NO;
    [enc setRenderPipelineState:sMsdPipeline];
    [enc setVertexBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
    [enc setFragmentTexture:self.texture atIndex:0];
    // 6 vertices = one quad; one instance per grain. ONE draw call for all.
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
            vertexStart:0 vertexCount:6
          instanceCount:(NSUInteger)(_u.columns * _u.rows)];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    return YES;
}

- (void)tick:(CADisplayLink *)link {
    @try {
        CFTimeInterval elapsed = CACurrentMediaTime() - self.start;
        CGFloat t = self.duration > 0 ? elapsed / self.duration : 1.0;
        BOOL done = (t >= 1.0);
        _u.time = done ? 1.0f : (float)t;   // direct ivar: ARC forbids struct-member via property
        [self renderOnce];
        if (done) [self cleanup];
    } @catch (NSException *e) {
        axs_msd_log(@"metal tick EXCEPTION %@", [e reason]);
        [self cleanup];
    }
}

- (void)cleanup {
    @try {
        [self.link invalidate];
        self.link = nil;
        self.texture = nil;
        self.metalLayer = nil;
        self.overlay.hidden = YES;
        self.overlay = nil;
        [sMsdActiveRenderers removeObject:self];
    } @catch (NSException *ignored) {
    }
    axs_msd_log(@"metal sand cleaned grains=%d", self.grainCount);
}

@end

// ---- upload a CGImage into a BGRA8 unorm MTLTexture (premultiplied) --------
static id<MTLTexture> axs_msd_makeTexture(CGImageRef cg, id<MTLDevice> device) {
    if (cg == NULL) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return nil;
    size_t bpr = w * 4;
    NSMutableData *data = [NSMutableData dataWithLength:bpr * h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate([data mutableBytes], w, h, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (ctx == NULL) { CGColorSpaceRelease(cs); return nil; }
    // CoreGraphics origin is bottom-left; flip so texture row 0 = image top,
    // matching the shader's uv.y = row/grid (row 0 = card top).
    CGContextTranslateCTM(ctx, 0, (CGFloat)h);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    // .105 ROOT CAUSE: iOS textures default to MTLStorageModePrivate, and
    // replaceRegion:withBytes: is NOT allowed on private storage -> the upload
    // silently fails, the texture stays all-zero (fully transparent), so every
    // grain renders invisible. Shared mode makes CPU bytes visible to the GPU.
    if (@available(iOS 13.0, *)) {
        td.storageMode = MTLStorageModeShared;
    }
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    if (tex == nil) return nil;
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0
             withBytes:[data bytes] bytesPerRow:bpr];
    return tex;
}

// ---- public entry point: returns YES if Metal took over the effect --------
BOOL axs_metalSandPlay(UIImage *shot, CGRect frameInWindow, CGFloat duration) {
    @try {
        if (!axs_msd_ensurePipeline()) {
            axs_msd_log(@"metal sand unavailable -> caller will fall back");
            return NO;
        }
        if (shot == nil || shot.CGImage == nil) {
            axs_msd_log(@"metal sand no snapshot");
            return NO;
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
            axs_msd_log(@"metal sand no key window");
            return NO;
        }

        id<MTLTexture> tex = axs_msd_makeTexture(shot.CGImage, sMsdDevice);
        if (tex == nil) {
            axs_msd_log(@"metal sand texture upload failed");
            return NO;
        }

        UIWindow *overlay = [[UIWindow alloc] initWithFrame:host.bounds];
        if ([overlay respondsToSelector:@selector(setWindowScene:)]) {
            overlay.windowScene = host.windowScene;
        }
        overlay.windowLevel = UIWindowLevelAlert + 500;
        overlay.backgroundColor = [UIColor clearColor];
        overlay.userInteractionEnabled = NO;
        overlay.hidden = NO;

        AXSMetalSandView *view = [[AXSMetalSandView alloc] initWithFrame:overlay.bounds];
        view.backgroundColor = [UIColor clearColor];
        view.userInteractionEnabled = NO;
        CAMetalLayer *ml = (CAMetalLayer *)view.layer;
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ml.framebufferOnly = YES;
        ml.opaque = NO;
        ml.contentsScale = [[UIScreen mainScreen] scale];
        [overlay addSubview:view];

        AXSMetalSandRenderer *renderer = [AXSMetalSandRenderer new];
        if (sMsdActiveRenderers == nil) sMsdActiveRenderers = [NSMutableArray array];
        [sMsdActiveRenderers addObject:renderer];

        int particles = 14000;  // DustParticles default in the reference plugin
        float seed = (float)(arc4random_uniform(100000)) / 1000.0f;
        // .105: startWithTexture now does a synchronous first-frame probe and
        // returns NO if Metal cannot actually draw. Only claim success when it
        // really rendered, otherwise let the caller fall back to UIView so the
        // effect is never blank.
        BOOL started = [renderer startWithTexture:tex frame:frameInWindow viewport:overlay.bounds.size
                                          duration:duration overlay:overlay view:view seed:seed particles:particles];
        if (!started) {
            [sMsdActiveRenderers removeObject:renderer];
            overlay.hidden = YES;
            axs_msd_log(@"metal sand first-frame FAILED -> caller will fall back");
            return NO;
        }

        axs_msd_log(@"metal sand started grains=%d dur=%.2f img=%lux%lu frame=%@ scene=%@",
                    particles, duration,
                    (unsigned long)CGImageGetWidth(shot.CGImage),
                    (unsigned long)CGImageGetHeight(shot.CGImage),
                    NSStringFromCGRect(frameInWindow),
                    overlay.windowScene ? @"set" : @"NIL");
        return YES;
    } @catch (NSException *e) {
        axs_msd_log(@"metal sand EXCEPTION %@", [e reason]);
        return NO;
    }
}
