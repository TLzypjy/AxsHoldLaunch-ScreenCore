// ---------------------------------------------------------------------------
// beautify.112 - unified Metal GPU renderer for ALL 9 dismiss styles. The
// whole card is uploaded as ONE texture and rendered as columns*rows instanced
// quads in a SINGLE drawPrimitives call on the GPU. The 8 former UIView grid
// styles (beautify.98/.99) were ported into per-style vertex shader branches,
// so there is no CPU layer path anymore -- UIView remains only as a concept
// that was fully retired in .112 (Metal unavailable = no dissolve effect).
//
// The sand shader lineage is reconstructed from the shader embedded verbatim
// in the reference dylib (com.example.noticelisttweak / NoticeListTweak.dylib
// mode 2). Compiled at runtime with newLibraryWithSource and cached.
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

// ---- MSL source -------------------------------------------------------------
// beautify.112: ONE unified GPU engine for ALL 9 styles. The 8 former UIView
// grid styles are ported into the vertex shader as per-style branches -- each
// style is just a different begin/span/dx/dy/shrink/rotation model over the
// same instanced-quad pipeline. UIView is no longer an engine; if Metal is
// unavailable there is simply no dissolve (the card closes natively).
// Timelines per style (T0, seconds at speed=1) are mirrored 1:1 in
// AxsDismissEffect.xm axs_dm_styleBaseDuration(); begin/span below are
// fractions of T0 so the speed slider keeps working unchanged.
// OPEN MODE (openMode=1, beautify.122): the dismiss-sand timeline played
// backwards -- grains start scattered up-right at reduced scale, invisible,
// then converge onto the card frame and fade IN; at time=1 the full card is
// assembled and the caller swaps in the real view. NOTE: no // comments are
// allowed INSIDE the string below -- the Logos preprocessor strips // to EOL
// (including the trailing line-continuation backslash) and would break the
// multiline literal.
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
    uint style;\n\
    uint openMode;\n\
    float sourceX;\n\
    float sourceY;\n\
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
    float r4 = dustHash(noiseCell + 43.7);\n\
    if (u.openMode == 1u) {\n\
        float beginO = (unit.x + 1.0-unit.y)*0.18 + r*0.025;\n\
        float spanO  = 0.56 + 0.035*r2;\n\
        float progressO = clamp((u.time-beginO)/spanO, 0.0, 1.0);\n\
        float leave = smoothstep(0.0,0.28,progressO);\n\
        float flyE = smoothstep(0.30,1.0,progressO);\n\
        float flyM = pow(flyE,1.12);\n\
        float angS = r*6.2831853;\n\
        float radS = (6.0 + 30.0*r4)*leave;\n\
        float2 startP = float2(u.sourceX,u.sourceY) + float2(cos(angS),sin(angS))*radS;\n\
        float2 endP = u.origin + unit*u.cardSize;\n\
        float shrinkO = mix(mix(0.15,0.40,r3), 1.0, flyM);\n\
        float angleO = (r3-0.5)*4.8*(1.0-flyM);\n\
        float2 tileSizeO = u.cardSize/grid;\n\
        float2 deltaO = (corner-0.5)*tileSizeO*shrinkO;\n\
        float cO=cos(angleO),sO=sin(angleO);\n\
        deltaO=float2(cO*deltaO.x-sO*deltaO.y,sO*deltaO.x+cO*deltaO.y);\n\
        float2 pO = mix(startP, endP, flyM) + deltaO;\n\
        DustVertex outO;\n\
        outO.position=float4(2.0*pO.x/u.viewport.x-1.0,1.0-2.0*pO.y/u.viewport.y,0,1);\n\
        outO.uv=(cell+corner)/grid;\n\
        outO.local=corner;\n\
        outO.fade=smoothstep(0.0,0.10,progressO);\n\
        outO.breakage=1.0;\n\
        return outO;\n\
    }\n\
    float2 rel = (unit-0.5)*u.cardSize;\n\
    float len = length(rel); if (len < 1.0) len = 1.0;\n\
    float2 dirOut = rel/len;\n\
    float2 dirIn = -dirOut;\n\
    float begin; float span;\n\
    float dx; float dy; float spinEnd; float scEnd;\n\
    int easeMode = 0;\n\
    if (u.style == 8u) {\n\
        begin = (unit.x + 1.0-unit.y)*0.18 + r*0.025;\n\
        span  = 0.56 + 0.035*r2;\n\
    } else if (u.style == 1u) {\n\
        dx = (r-0.5)*100.0;\n\
        dy = 80.0+140.0*r2;\n\
        spinEnd = (r3-0.5)*1.8;\n\
        scEnd = 0.35+0.30*r4;\n\
        begin = r4*0.15/1.20;\n\
        span = 1.05/1.20;\n\
        easeMode = 1;\n\
    } else if (u.style == 2u) {\n\
        float pull = len + 20.0+60.0*r;\n\
        float tang = 90.0+70.0*r2;\n\
        dx = dirIn.x*pull - dirIn.y*tang;\n\
        dy = dirIn.y*pull + dirIn.x*tang;\n\
        spinEnd = (r3-0.5)*6.0;\n\
        scEnd = 0.0;\n\
        begin = unit.y*0.18/1.03;\n\
        span = 0.85/1.03;\n\
    } else if (u.style == 3u) {\n\
        float dist = len + 160.0+120.0*r2;\n\
        dx = dirOut.x*dist;\n\
        dy = dirOut.y*dist;\n\
        spinEnd = 0.0;\n\
        scEnd = 0.2;\n\
        begin = (len/320.0)/1.83;\n\
        span = 0.70/1.83;\n\
    } else if (u.style == 4u) {\n\
        dx = (r-0.5)*90.0;\n\
        dy = -(60.0+110.0*r2);\n\
        spinEnd = (r3-0.5)*1.0;\n\
        scEnd = 0.15+0.25*r4;\n\
        begin = r4*0.30/1.55;\n\
        span = 1.25/1.55;\n\
    } else if (u.style == 5u) {\n\
        dx = 0.0; dy = 0.0; spinEnd = 0.0; scEnd = 1.0;\n\
        begin = r*0.70/0.88;\n\
        span = 0.18/0.88;\n\
    } else if (u.style == 6u) {\n\
        dx = (uint(cell.y) % 2u == 0u) ? 16.0 : -16.0;\n\
        dy = 0.0; spinEnd = 0.0; scEnd = 1.0;\n\
        begin = unit.y*0.60/0.85;\n\
        span = 0.25/0.85;\n\
    } else if (u.style == 7u) {\n\
        dx = cos(r*6.2831853)*(120.0+180.0*r2);\n\
        dy = sin(r*6.2831853)*(120.0+180.0*r2)+90.0;\n\
        spinEnd = (r3-0.5)*5.2;\n\
        scEnd = 0.25+0.25*r4;\n\
        begin = r4*0.08/1.03;\n\
        span = 0.95/1.03;\n\
        easeMode = 1;\n\
    } else {\n\
        dx = cos(r*6.2831853)*(100.0+220.0*r2);\n\
        dy = sin(r*6.2831853)*(100.0+220.0*r2)-40.0;\n\
        spinEnd = (r3-0.5)*2.0;\n\
        scEnd = 0.12;\n\
        begin = r4*0.12/0.87;\n\
        span = 0.75/0.87;\n\
    }\n\
    float progress = clamp((u.time-begin)/span, 0.0, 1.0);\n\
    float burst = smoothstep(0.0,0.18,progress);\n\
    float motion;\n\
    if (easeMode == 1) motion = progress*progress;\n\
    else if (easeMode == 0) motion = 1.0-(1.0-progress)*(1.0-progress);\n\
    else motion = pow(progress,1.12);\n\
    float dxm; float dym; float shrink; float angle;\n\
    if (u.style == 8u) {\n\
        dxm = (0.62 + 1.05*r)*u.distance*motion + (r2-0.5)*u.distance*0.40*motion;\n\
        dym = -(0.45 + 1.05*r2)*u.distance*motion + sin(progress*7.0+r3*6.283)*u.distance*0.13*motion;\n\
        shrink = mix(1.0, mix(0.24,0.56,r3), smoothstep(0.01,0.65,progress));\n\
        angle = (r3-0.5)*4.8*motion;\n\
    } else {\n\
        dxm = dx*motion;\n\
        dym = dy*motion;\n\
        shrink = mix(1.0, scEnd, motion);\n\
        angle = spinEnd*motion;\n\
    }\n\
    float2 tileSize = u.cardSize/grid;\n\
    float2 delta = (corner-0.5)*tileSize*shrink;\n\
    float c=cos(angle),s=sin(angle);\n\
    delta=float2(c*delta.x-s*delta.y,s*delta.x+c*delta.y);\n\
    float2 p = u.origin + unit*u.cardSize + delta + float2(dxm,dym);\n\
    DustVertex out;\n\
    out.position=float4(2.0*p.x/u.viewport.x-1.0,1.0-2.0*p.y/u.viewport.y,0,1);\n\
    out.uv=(cell+corner)/grid;\n\
    out.local=corner;\n\
    float fade;\n\
    if (u.style == 8u) fade = 1.0-smoothstep(0.32+0.20*r2,1.0,progress);\n\
    else fade = 1.0-motion;\n\
    out.fade=fade;\n\
    out.breakage=(u.style == 8u) ? burst : 0.0;\n\
    return out;\n\
}\n\
fragment float4 nlDustFragment(DustVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {\n\
    constexpr sampler sampleImage(coord::normalized,address::clamp_to_edge,filter::linear);\n\
    float4 color=image.sample(sampleImage,in.uv);\n\
    float roundDust=1.0-smoothstep(0.34,0.53,length(in.local-0.5));\n\
    float shape=mix(1.0,roundDust,in.breakage);\n\
    return color*(in.fade*shape);\n\
}\n";

// C-side mirror of DustUniforms. MSL float2 is 8-byte aligned; total = 56 bytes.
typedef struct {
    float viewport[2];
    float origin[2];
    float cardSize[2];
    uint32_t columns;
    uint32_t rows;
    float time;
    float distance;
    float seed;
    uint32_t style;
    uint32_t openMode;
    float sourcePoint[2];
} AXSMetalDustUniforms;

// ---- cached device + queue + pipeline (compiled once, reused) --------------
static id<MTLDevice> sMsdDevice = nil;
// .106 ROOT CAUSE: newCommandBuffer is a MTLCommandQueue method, NOT an
// MTLDevice method. .104 wrapped [device newCommandBuffer] in objc_msgSend to
// dodge a compile error, but it crashed at runtime with "unrecognized selector
// sent to AGXG15Device" -> Metal never drew -> always fell back to the slow
// 6000-layer UIView path (the persisting stutter). Create a command queue once
// and get command buffers from it, the correct Metal API usage.
// .107 ROOT CAUSE: the queue itself does NOT implement `newCommandBuffer` on
// this device (log: "unrecognized selector sent to AGXG15FamilyCommandQueue").
// The reference plugin whose sand matched the video uses `commandBuffer` on
// the queue -- its dylib contains "commandBuffer" (x2) and NEVER
// "newCommandBuffer" (x0). Switch to that selector with a runtime probe so a
// missing selector returns NO cleanly instead of throwing into UIView fallback.
static id<MTLCommandQueue> sMsdQueue = nil;
static id<MTLRenderPipelineState> sMsdPipeline = nil;
static BOOL sMsdTried = NO;

static NSString *sMsdFailReason = nil;   // .114: survives log rotation
static BOOL axs_msd_ensurePipeline(void) {
    if (sMsdTried) return (sMsdPipeline != nil);
    sMsdTried = YES;
    sMsdFailReason = nil;
    @try {
        sMsdDevice = MTLCreateSystemDefaultDevice();
        if (sMsdDevice == nil) {
            sMsdFailReason = @"metal device unavailable";
            axs_msd_log(@"%@", sMsdFailReason);
            return NO;
        }
        // .106: command buffers come from a queue, never from the device.
        sMsdQueue = [sMsdDevice newCommandQueue];
        if (sMsdQueue == nil) {
            sMsdFailReason = @"metal command queue unavailable";
            axs_msd_log(@"%@", sMsdFailReason);
            return NO;
        }
        NSError *err = nil;
        id<MTLLibrary> lib = [sMsdDevice newLibraryWithSource:AXS_MSD_SHADER
                                                      options:nil error:&err];
        if (lib == nil) {
            sMsdFailReason = [NSString stringWithFormat:@"shader compile FAILED: %@", [err localizedDescription]];
            axs_msd_log(@"%@", sMsdFailReason);
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
            sMsdFailReason = [NSString stringWithFormat:@"pipeline FAILED: %@", [pe localizedDescription]];
            axs_msd_log(@"%@", sMsdFailReason);
            return NO;
        }
        axs_msd_log(@"metal compiled OK pipeline ready");
        return YES;
    } @catch (NSException *e) {
        sMsdFailReason = [NSString stringWithFormat:@"ensurePipeline EXCEPTION %@", [e reason]];
        axs_msd_log(@"%@", sMsdFailReason);
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
                  style:(uint32_t)style
                density:(CGFloat)density
               openMode:(uint32_t)openMode
             sourcePoint:(CGPoint)sourcePoint;
@end

@implementation AXSMetalSandRenderer

- (BOOL)startWithTexture:(id<MTLTexture>)tex
                  frame:(CGRect)frame
               viewport:(CGSize)viewport
               duration:(CGFloat)dur
                overlay:(UIWindow *)win
                   view:(AXSMetalSandView *)view
                   seed:(float)seed
                  style:(uint32_t)style
                density:(CGFloat)density
               openMode:(uint32_t)openMode
             sourcePoint:(CGPoint)sourcePoint {
    self.texture = tex;
    self.duration = dur;
    self.overlay = win;
    self.metalLayer = (CAMetalLayer *)view.layer;

    AXSMetalDustUniforms u = {{0}};
    u.viewport[0] = (float)viewport.width;
    u.viewport[1] = (float)viewport.height;
    u.origin[0] = (float)frame.origin.x;
    u.origin[1] = (float)frame.origin.y;
    u.cardSize[0] = (float)frame.size.width;
    u.cardSize[1] = (float)frame.size.height;
    u.time = 0.0f;
    u.distance = 110.0f;     // DustDistance default (sand drift distance)
    u.seed = seed;
    u.style = style;
    u.openMode = openMode;
    u.sourcePoint[0] = (float)sourcePoint.x;
    u.sourcePoint[1] = (float)sourcePoint.y;
    // Grid = per-style base resolution scaled by the density slider.
    // Style 8 (sand) and open mode use the reference plugin's particle-count
    // model (14000 * density distributed by card aspect); the 8 grid styles
    // scale their characteristic base grids (Glass stays chunky 5x6, Dust 14x14...).
    uint32_t cols, rows;
    if (style == 8u || openMode == 1u) {
        int particles = (int)lround(14000.0 * density);
        if (particles < 200) particles = 200;
        if (particles > 40000) particles = 40000;
        CGFloat aspect = frame.size.height > 0.5 ? frame.size.width / frame.size.height : 1.0;
        cols = (uint32_t)lround(sqrtf((float)particles * (float)aspect));
        rows = (uint32_t)((particles + (int)cols - 1) / (int)cols);
    } else {
        int baseCols = 10, baseRows = 10;
        switch (style) {
            case 4u: baseCols = 14; baseRows = 14; break;   // Dust
            case 5u: baseCols = 12; baseRows = 12; break;   // Pixel dissolve
            case 6u: baseCols = 8;  baseRows = 14; break;   // Blinds
            case 7u: baseCols = 5;  baseRows = 6;  break;   // Glass
            default: break;                                  // 10x10 grid styles
        }
        cols = (uint32_t)lround((CGFloat)baseCols * density);
        rows = (uint32_t)lround((CGFloat)baseRows * density);
    }
    if (cols < 2) cols = 2; if (cols > 240) cols = 240;
    if (rows < 2) rows = 2; if (rows > 240) rows = 240;
    u.columns = cols;
    u.rows = rows;
    self.grainCount = (int)(cols * rows);
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
    [win layoutIfNeeded];

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

    // .107 FIX: the correct selector on MTLCommandQueue here is `commandBuffer`
    // (confirmed from the reference plugin dylib: commandBuffer x2,
    // newCommandBuffer x0). .106 sent `newCommandBuffer` to the queue and still
    // crashed with "unrecognized selector sent to AGXG15FamilyCommandQueue",
    // so Metal never drew and every close built 6000 UIView layers -> stutter.
    // Probe at runtime, prefer commandBuffer, keep newCommandBuffer as a
    // fallback for devices/SDKs that expose it; never throw into SpringBoard.
    SEL cbSel = @selector(commandBuffer);
    if (![sMsdQueue respondsToSelector:cbSel]) {
        cbSel = @selector(newCommandBuffer);
    }
    if (![sMsdQueue respondsToSelector:cbSel]) {
        axs_msd_log(@"metal queue exposes no command buffer selector");
        return NO;
    }
    id<MTLCommandBuffer> cb =
        ((id<MTLCommandBuffer> (*)(id, SEL))objc_msgSend)(sMsdQueue, cbSel);
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
    // .110 FIX (upside-down card): a raw CGBitmapContext has a y-up coordinate
    // space whose memory row 0 IS the buffer top, and the snapshot CGImage's
    // raster is top-down -- so a plain draw already lands image top at texture
    // row 0, which is exactly what the shader expects (uv.y=0 -> image top).
    // The .104-era extra TranslateCTM/ScaleCTM(1,-1) flip double-flipped the
    // card: the Metal path rendered the whole window mirrored vertically
    // (calculator upside down in the sand). The UIView fallback never used
    // this path, so the bug only surfaced once Metal started working in .109.
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

// ---- public entry points: return YES if Metal took over the effect --------
// common core shared by dismiss (openMode=0) and open-assemble (openMode=1)
static BOOL axs_metalPlayCommon(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                                uint32_t style, CGFloat density, uint32_t openMode,
                                CGPoint sourcePoint) {
    @try {
        if (!axs_msd_ensurePipeline()) {
            axs_msd_log(@"metal unavailable -> no dissolve effect (%@)",
                        sMsdFailReason ? sMsdFailReason : @"unknown");
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

        float seed = (float)(arc4random_uniform(100000)) / 1000.0f;
        // .105: startWithTexture does a synchronous first-frame probe and
        // returns NO if Metal cannot actually draw. Only claim success when it
        // really rendered.
        BOOL started = [renderer startWithTexture:tex frame:frameInWindow viewport:overlay.bounds.size
                                          duration:duration overlay:overlay view:view seed:seed
                                            style:style density:density openMode:openMode
                                      sourcePoint:sourcePoint];
        if (!started) {
            [sMsdActiveRenderers removeObject:renderer];
            overlay.hidden = YES;
            axs_msd_log(@"metal first-frame FAILED");
            return NO;
        }

        axs_msd_log(@"metal started open=%u style=%u grains=%d dur=%.2f density=%.2f img=%lux%lu frame=%@ scene=%@",
                    openMode, style, renderer.grainCount, duration, density,
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

// dismiss (dissolve): style selects the motion model, openMode=0
BOOL axs_metalSandPlay(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                       uint32_t style, CGFloat density) {
    return axs_metalPlayCommon(shot, frameInWindow, duration, style, density, 0,
                               CGPointMake(0, 0));
}

// beautify.122 open-assemble: grains fly FROM sourcePoint TO the card
BOOL axs_metalAssemblePlay(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                           CGFloat density, CGPoint sourcePoint) {
    return axs_metalPlayCommon(shot, frameInWindow, duration, 8, density, 1,
                               sourcePoint);
}
