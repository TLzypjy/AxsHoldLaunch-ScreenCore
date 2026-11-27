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
// OPEN MODE (openMode=1, beautify.157): ALL-GPU REFERENCE REVEAL.
// Copied from the reference plugin's ALGORITHM (its own code stays its own):
// every grain bursts from the FINGER lift point and flies to its own cell,
// flies on a gentle S-curve into its own jittered cell and DIES at arrival;
// a second draw pass (openMode=2) deposits the REAL card texel for each cell
// gated by the SAME per-cell hash arrival clock, so the rising card edge and
// the dust front are literally the same front -- no gap, no CPU mask, no
// per-frame CAShapeLayer rebuild. The card snapshot is captured ASYNC and
// swapped in mid-flight (cardReady); the card view itself stays hidden until
// endWipeReveal hands over from the identical deposited image.
// NOTE: no // comments
// are allowed INSIDE the string below -- the Logos preprocessor strips // to
// EOL (including the trailing line-continuation backslash) and would break
// the multiline literal.
// .188: CLASSIC .168 open shader (deposit cached card texels). Kept byte-identical.
static NSString * const AXS_MSD_SHADER_CLASSIC = @"\
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
    uint cornerKill;\n\
    float cornerRadius;\n\
    uint dirMode;\n\
    float2 srcOrigin;\n\
    float2 srcSize;\n\
    uint departDir;\n\
    uint arriveDir;\n\
};\n\
struct DustVertex {\n\
    float4 position [[position]];\n\
    float2 uv;\n\
    float2 local;\n\
    float fade;\n\
    float breakage;\n\
    float dock;\n\
    float3 tint;\n\
    float isOpen;\n\
    float noiseX;\n\
    float noiseY;\n\
};\n\
float dustHash(float2 v) {\n\
    return fract(sin(dot(v, float2(127.1,311.7))) * 43758.5453);\n\
}\n\
float3 axsPalette(float p) {\n\
    p = fract(p) * 5.0;\n\
    if (p < 1.0) return mix(float3(0.10,0.86,0.94), float3(0.25,0.45,0.98), p);\n\
    if (p < 2.0) return mix(float3(0.25,0.45,0.98), float3(0.68,0.28,0.98), p-1.0);\n\
    if (p < 3.0) return mix(float3(0.68,0.28,0.98), float3(0.98,0.30,0.68), p-2.0);\n\
    if (p < 4.0) return mix(float3(0.98,0.30,0.68), float3(1.00,0.68,0.22), p-3.0);\n\
    return mix(float3(1.00,0.68,0.22), float3(0.10,0.86,0.94), p-4.0);\n\
}\n\
float axsTransferOrder(float2 unit, uint mode) {\n\
    if (mode == 0u) return unit.y;\n\
    if (mode == 1u) return (1.0-unit.y);\n\
    if (mode == 2u) return (unit.x+unit.y)*0.5;\n\
    if (mode == 3u) return ((1.0-unit.x)+unit.y)*0.5;\n\
    if (mode == 4u) return (unit.x+(1.0-unit.y))*0.5;\n\
    if (mode == 5u) return ((1.0-unit.x)+(1.0-unit.y))*0.5;\n\
    return ((1.0-unit.x)+unit.y)*0.5;\n\
}\n\
float axsTransferHash(float2 cell) {\n\
    uint h = uint(cell.x)*73856093u ^ uint(cell.y)*19349663u ^ 83492791u;\n\
    h ^= h >> 13u; h *= 1274126177u; h ^= h >> 16u;\n\
    return (float)(h & 0xffffu)/65535.0;\n\
}\n\
float2 axsTransferLanding(float2 cell, float2 grid) {\n\
    float2 j = (float2(axsTransferHash(cell+float2(7.3)), axsTransferHash(cell+float2(19.1)))-0.5)*0.18;\n\
    return (cell+0.5+j)/grid;\n\
}\n\
float axsTransferDepart(float2 unit, uint mode, float hf) {\n\
    float o = clamp(0.96*axsTransferOrder(unit, mode) + 0.04*hf, 0.0, 1.0);\n\
    return 0.02 + 0.50*o;\n\
}\n\
float axsTransferArrive(float2 unit, uint mode, float hf) {\n\
    float o = clamp(0.96*axsTransferOrder(unit, mode) + 0.04*hf, 0.0, 1.0);\n\
    return 0.38 + 0.56*o;\n\
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
        uint h = uint(cell.x)*73856093u ^ uint(cell.y)*19349663u ^ 83492791u;\n\
        h ^= h >> 13u; h *= 1274126177u; h ^= h >> 16u;\n\
        float hf = (float)(h & 0xffffu)/65535.0;\n\
        float orderBase;\n\
        if (u.dirMode == 0u) orderBase = unit.y;\n\
        else if (u.dirMode == 1u) orderBase = (1.0-unit.y);\n\
        else if (u.dirMode == 2u) orderBase = (unit.x + unit.y)*0.5;\n\
        else if (u.dirMode == 3u) orderBase = ((1.0-unit.x) + unit.y)*0.5;\n\
        else if (u.dirMode == 4u) orderBase = (unit.x + (1.0-unit.y))*0.5;\n\
        else if (u.dirMode == 6u) {\n\
            float2 cp = u.origin + unit*u.cardSize;\n\
            float2 sp = float2(u.sourceX, u.sourceY);\n\
            float fx6 = max(abs(sp.x - u.origin.x), abs(sp.x - (u.origin.x + u.cardSize.x)));\n\
            float fy6 = max(abs(sp.y - u.origin.y), abs(sp.y - (u.origin.y + u.cardSize.y)));\n\
            orderBase = min(distance(cp, sp) / max(length(float2(fx6, fy6)), 1.0), 1.0);\n\
        }\n\
        else if (u.dirMode == 7u) {\n\
            float d7 = length((unit - 0.5) * u.cardSize);\n\
            orderBase = 1.0 - min(d7 / max(length(u.cardSize) * 0.5, 1.0), 1.0);\n\
        }\n\
        else orderBase = ((1.0-unit.x) + (1.0-unit.y))*0.5;\n\
        float order = 0.96*orderBase + 0.04*hf;\n\
        float arrival = 0.35 + 0.65*order;\n\
        float departure = arrival - 0.35;\n\
        float t = clamp((u.time - departure)/0.35, 0.0, 1.0);\n\
        float2 jitter = (float2(float((h>>16)&255u), float((h>>24)&255u))/255.0 - 0.5)*0.36;\n\
        float2 landing = (cell + 0.5 + jitter)/grid;\n\
        float kill = 1.0;\n\
        if (u.cornerKill != 0u) {\n\
            float2 pl = landing*u.cardSize;\n\
            float2 hcs = u.cardSize*0.5;\n\
            float2 q = abs(pl-hcs)-(hcs-float2(u.cornerRadius,u.cornerRadius));\n\
            float dOut = length(max(q,float2(0.0)))+min(max(q.x,q.y),0.0)-u.cornerRadius;\n\
            kill = 1.0 - smoothstep(-2.0,2.0,dOut);\n\
        }\n\
        float2 finger = float2(u.sourceX, u.sourceY);\n\
        float ang = r*6.2831853;\n\
        float2 start = finger + float2(cos(ang), sin(ang))*(9.0 + 48.0*r4);\n\
        float2 dest = u.origin + landing*u.cardSize;\n\
        float approach = clamp(u.cardSize.y*0.24, 64.0, 150.0);\n\
        float2 c1 = float2(mix(start.x, dest.x, 0.30) + (r2-0.5)*u.cardSize.x*0.55,\n\
                           max(start.y, dest.y) + approach*(0.7 + 1.5*r2));\n\
        float2 c2 = dest + float2((r-0.5)*u.cardSize.x*0.45, approach*(0.4 + 1.0*r3));\n\
        float b = 1.0 - t;\n\
        float2 pos = b*b*b*start + 3.0*b*b*t*c1 + 3.0*b*t*t*c2 + t*t*t*dest;\n\
        pos.x += sin(t*(4.0 + 5.0*r3)*6.2831853 + r*6.2831853)\n\
                 * u.cardSize.x*0.05*(1.0-t);\n\
        float2 dustSize = float2(mix(1.15, 2.4, r3));\n\
        pos += (corner-0.5)*dustSize;\n\
        float born = step(departure, u.time);\n\
        float gone = 1.0 - step(arrival - 0.006, u.time);\n\
        DustVertex outO;\n\
        outO.position=float4(2.0*pos.x/u.viewport.x-1.0,1.0-2.0*pos.y/u.viewport.y,0,1);\n\
        outO.uv=unit;\n\
        outO.local=corner;\n\
        outO.fade=born*gone*kill;\n\
        outO.breakage=0.0;\n\
        outO.dock=t;\n\
        outO.tint=axsPalette(r + hf*0.15);\n\
        outO.isOpen=1.0;\n\
        outO.noiseX=r;\n\
        outO.noiseY=r3;\n\
        return outO;\n\
    }\n\
    if (u.openMode == 2u) {\n\
        uint h2 = uint(cell.x)*73856093u ^ uint(cell.y)*19349663u ^ 83492791u;\n\
        h2 ^= h2 >> 13u; h2 *= 1274126177u; h2 ^= h2 >> 16u;\n\
        float hf2 = (float)(h2 & 0xffffu)/65535.0;\n\
        float orderBase2;\n\
        if (u.dirMode == 0u) orderBase2 = unit.y;\n\
        else if (u.dirMode == 1u) orderBase2 = (1.0-unit.y);\n\
        else if (u.dirMode == 2u) orderBase2 = (unit.x + unit.y)*0.5;\n\
        else if (u.dirMode == 3u) orderBase2 = ((1.0-unit.x) + unit.y)*0.5;\n\
        else if (u.dirMode == 4u) orderBase2 = (unit.x + (1.0-unit.y))*0.5;\n\
        else if (u.dirMode == 6u) {\n\
            float2 cp2 = u.origin + unit*u.cardSize;\n\
            float2 sp2 = float2(u.sourceX, u.sourceY);\n\
            float fx6 = max(abs(sp2.x - u.origin.x), abs(sp2.x - (u.origin.x + u.cardSize.x)));\n\
            float fy6 = max(abs(sp2.y - u.origin.y), abs(sp2.y - (u.origin.y + u.cardSize.y)));\n\
            orderBase2 = min(distance(cp2, sp2) / max(length(float2(fx6, fy6)), 1.0), 1.0);\n\
        }\n\
        else if (u.dirMode == 7u) {\n\
            float d7 = length((unit - 0.5) * u.cardSize);\n\
            orderBase2 = 1.0 - min(d7 / max(length(u.cardSize) * 0.5, 1.0), 1.0);\n\
        }\n\
        else orderBase2 = ((1.0-unit.x) + (1.0-unit.y))*0.5;\n\
        float order2 = 0.96*orderBase2 + 0.04*hf2;\n\
        float arrival2 = 0.35 + 0.65*order2;\n\
        float open = step(arrival2 - 0.006, u.time);\n\
        float2 tile = u.cardSize/grid;\n\
        float2 pos = u.origin + (cell + corner)*tile;\n\
        DustVertex outT;\n\
        outT.position=float4(2.0*pos.x/u.viewport.x-1.0,1.0-2.0*pos.y/u.viewport.y,0,1);\n\
        outT.uv=(cell+corner)/grid;\n\
        outT.local=corner;\n\
        outT.fade=open;\n\
        outT.breakage=0.0;\n\
        outT.dock=0.0;\n\
        outT.tint=float3(0.0);\n\
        outT.isOpen=2.0;\n\
        outT.noiseX=hf2;\n\
        outT.noiseY=hf2;\n\
        return outT;\n\
    }\n\
    if (u.openMode == 3u) {\n\
        float th3 = axsTransferHash(cell);\n\
        float2 landing3 = axsTransferLanding(cell, grid);\n\
        float depart3 = axsTransferDepart(unit, u.departDir, th3);\n\
        float arrive3 = axsTransferArrive(unit, u.arriveDir, th3);\n\
        float time3 = clamp((u.time-depart3)/max(arrive3-depart3,0.08), 0.0, 1.0);\n\
        float2 from3 = u.srcOrigin + landing3*u.srcSize;\n\
        float2 dest3 = u.origin + landing3*u.cardSize;\n\
        float2 ctrl3 = mix(from3,dest3,0.5) + float2((r2-0.5)*54.0, (r3-0.5)*54.0);\n\
        float b3 = 1.0-time3;\n\
        float2 pos3 = b3*b3*from3 + 2.0*b3*time3*ctrl3 + time3*time3*dest3;\n\
        pos3 += (corner-0.5)*float2(mix(1.2,2.2,r3));\n\
        float born3 = smoothstep(depart3, depart3+0.03, u.time);\n\
        float gone3 = 1.0 - smoothstep(arrive3-0.03, arrive3, u.time);\n\
        DustVertex out3;\n\
        out3.position=float4(2.0*pos3.x/u.viewport.x-1.0,1.0-2.0*pos3.y/u.viewport.y,0,1);\n\
        out3.uv=unit;\n\
        out3.local=corner;\n\
        out3.fade=born3*gone3;\n\
        out3.breakage=0.0;\n\
        out3.dock=time3;\n\
        out3.tint=float3(0.0);\n\
        out3.isOpen=3.0;\n\
        out3.noiseX=r;\n\
        out3.noiseY=r3;\n\
        return out3;\n\
    }\n\
    if (u.openMode == 4u) {\n\
        float th4 = axsTransferHash(cell);\n\
        float2 land4 = axsTransferLanding(cell, grid);\n\
        float dep4 = axsTransferDepart(unit, u.departDir, th4);\n\
        float keep4 = 1.0 - smoothstep(dep4-0.006, dep4+0.006, u.time);\n\
        float2 tile4 = u.srcSize/grid;\n\
        float2 p4 = u.srcOrigin + land4*u.srcSize + (corner-0.5)*tile4;\n\
        DustVertex out4;\n\
        out4.position=float4(2.0*p4.x/u.viewport.x-1.0,1.0-2.0*p4.y/u.viewport.y,0,1);\n\
        out4.uv=(cell+corner)/grid;\n\
        out4.local=corner;\n\
        out4.fade=keep4;\n\
        out4.breakage=0.0;\n\
        out4.dock=0.0;\n\
        out4.tint=float3(0.0);\n\
        out4.isOpen=2.0;\n\
        out4.noiseX=r;\n\
        out4.noiseY=r3;\n\
        return out4;\n\
    }\n\
    if (u.openMode == 5u) {\n\
        float th5 = axsTransferHash(cell);\n\
        float2 land5 = axsTransferLanding(cell, grid);\n\
        float arr5 = axsTransferArrive(unit, u.arriveDir, th5);\n\
        float grown5 = smoothstep(arr5-0.006, arr5+0.006, u.time);\n\
        float2 tile5 = u.cardSize/grid;\n\
        float2 p5 = u.origin + land5*u.cardSize + (corner-0.5)*tile5;\n\
        DustVertex out5;\n\
        out5.position=float4(2.0*p5.x/u.viewport.x-1.0,1.0-2.0*p5.y/u.viewport.y,0,1);\n\
        out5.uv=(cell+corner)/grid;\n\
        out5.local=corner;\n\
        out5.fade=grown5;\n\
        out5.breakage=0.0;\n\
        out5.dock=0.0;\n\
        out5.tint=float3(0.0);\n\
        out5.isOpen=2.0;\n\
        out5.noiseX=r;\n\
        out5.noiseY=r3;\n\
        return out5;\n\
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
    out.dock=0.0;\n\
    out.tint=float3(0.0);\n\
    out.isOpen=0.0;\n\
    return out;\n\
}\n\
fragment float4 nlDustFragment(DustVertex in [[stage_in]], constant DustUniforms& u [[buffer(0)]], texture2d<float> image [[texture(0)]]) {\n\
    constexpr sampler sampleImage(coord::normalized,address::clamp_to_edge,filter::linear);\n\
    float4 texel=image.sample(sampleImage,in.uv);\n\
    if (in.isOpen > 2.5) {\n\
        float roundDust = 1.0-smoothstep(0.34,0.53,length(in.local-0.5));\n\
        float3 base = mix(texel.rgb, axsPalette(in.noiseX + u.time*0.06), 0.25);\n\
        return float4(base,1.0)*(roundDust*in.fade);\n\
    }\n\
    if (in.isOpen > 1.5) {\n\
        return texel*in.fade;\n\
    }\n\
    if (in.isOpen > 0.5) {\n\
        float roundDust=1.0-smoothstep(0.32,0.51,length(in.local-0.5));\n\
        float core=1.0-smoothstep(0.0,0.40,length(in.local-0.5));\n\
        float phase=u.seed + u.time*2.1;\n\
        float3 texelC=texel.rgb/max(texel.a,0.001);\n\
        float3 grain=mix(axsPalette(in.noiseX + phase*0.025), texelC, 0.35);\n\
        float sparkle=0.5+0.5*sin(phase*2.1+in.noiseY*6.2831853);\n\
        float glint=smoothstep(0.60,0.87,in.noiseY)*core*(0.15+0.30*sparkle);\n\
        grain=mix(grain, axsPalette(in.noiseY+0.37*in.noiseX), glint);\n\
        float impact=smoothstep(0.88,0.985,in.dock)*(1.0-smoothstep(0.985,1.0,in.dock));\n\
        grain+=axsPalette(in.noiseX)*impact*0.22;\n\
        return float4(grain,1.0)*(roundDust*in.fade);\n\
    }\n\
    float roundDust=1.0-smoothstep(0.34,0.53,length(in.local-0.5));\n\
    float shape=mix(1.0,roundDust,in.breakage);\n\
    return texel*(in.fade*shape);\n\
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
    uint32_t cornerKill;
    float cornerRadius;
    uint32_t dirMode;
    float srcOrigin[2];
    float srcSize[2];
    uint32_t departDir;
    uint32_t arriveDir;
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
// .188: second pipeline for the wallpaper-cover open style (.182 shader).
// .197: kill dust grains whose landing cell falls OUTSIDE the card's rounded
// corners (square-corner halo). 0 = off (styles 0/1/2 unchanged); style 3
// arms it with the live card's real corner radius.
static uint32_t sMsdCornerKill = 0;
static float sMsdCornerKillRadius = 0.0f;
void axs_msd_setCornerKill(uint32_t on, float radius);
void axs_msd_setCornerKill(uint32_t on, float radius) { sMsdCornerKill = on; sMsdCornerKillRadius = radius; }
// .201: reveal direction. 0 = top->down (original), 1 = top-left->bottom-right.
static uint32_t sMsdDirMode = 0;
void axs_msd_setDirectionMode(uint32_t mode);
void axs_msd_setDirectionMode(uint32_t mode) { sMsdDirMode = mode; }
// beautify.230: dock transfer (openMode=3) config -- two source/target rects
// and independent departure/arrival diagonal orders.
static CGRect sMsdTransferFrom = CGRectZero;
static uint32_t sMsdTransferDepartDir = 3u;   // 3 = top-right -> bottom-left
static uint32_t sMsdTransferArriveDir = 3u;
void axs_msd_setTransferConfig(CGRect from, uint32_t departDir, uint32_t arriveDir);
void axs_msd_setTransferConfig(CGRect from, uint32_t departDir, uint32_t arriveDir) {
    sMsdTransferFrom = from;
    sMsdTransferDepartDir = departDir;
    sMsdTransferArriveDir = arriveDir;
}
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
        // .188: build a pipeline from each shader source. Classic MUST compile
        // (dismiss + classic open depend on it). Cover is optional: if it fails,
        // the wallpaper style falls back to native instead of killing dismiss.
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        // --- classic (.168) ---
        NSError *err = nil;
        id<MTLLibrary> lib = [sMsdDevice newLibraryWithSource:AXS_MSD_SHADER_CLASSIC
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
        pd.vertexFunction = vf;
        pd.fragmentFunction = ff;
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
@property (nonatomic, assign) BOOL fadingOut;
// .157: YES once the real card snapshot has been swapped in mid-flight;
// gates the openMode=2 deposited-tile draw pass.
@property (nonatomic, assign) BOOL cardReady;
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

// .140: the currently-running open-assemble renderer (mid-flight texture swap)
static __weak AXSMetalSandRenderer *sMsdActiveOpenRenderer = nil;

static id<MTLTexture> axs_msd_makeTexture(CGImageRef cg, id<MTLDevice> device);

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
    u.cornerKill = sMsdCornerKill;
    u.cornerRadius = sMsdCornerKillRadius;
    u.dirMode = sMsdDirMode;
    u.srcOrigin[0] = (float)sMsdTransferFrom.origin.x;
    u.srcOrigin[1] = (float)sMsdTransferFrom.origin.y;
    u.srcSize[0] = (float)sMsdTransferFrom.size.width;
    u.srcSize[1] = (float)sMsdTransferFrom.size.height;
    u.departDir = sMsdTransferDepartDir;
    u.arriveDir = sMsdTransferArriveDir;
    // Grid = per-style base resolution scaled by the density slider.
    // Style 8 (sand) and open mode use the reference plugin's particle-count
    // model (14000 * density distributed by card aspect); the 8 grid styles
    // scale their characteristic base grids (Glass stays chunky 5x6, Dust 14x14...).
    uint32_t cols, rows;
    if (style == 8u || openMode == 1u || openMode == 3u) {
        // .142: raise the cap and the rows clamp -- at density=3 the old
        // rows>240 clamp truncated 42000 grains down to 32640, so the slider
        // never actually delivered its full density on the tall card aspect.
        // .152: open mode uses a denser cloud so the band hugging the reveal
        // front reads as a tight cluster (reference), not a sparse drizzle.
        int particles = (int)lround(((openMode == 1u || openMode == 3u) ? 22000.0 : 14000.0) * density);
        if (particles < 200) particles = 200;
        if (particles > 48000) particles = 48000;
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
    if (cols < 2) cols = 2; if (cols > 320) cols = 320;
    if (rows < 2) rows = 2; if (rows > 320) rows = 320;
    u.columns = cols;
    u.rows = rows;
    self.grainCount = (int)(cols * rows);
    self.cardReady = NO;
    // .159: .158 seeds the open pass with the cached visible-card snapshot as
    // the INITIAL texture; cardReady used to be armed only in
    // replaceTextureWithImage, so the deposit pass never drew and the card
    // popped in after the dust. Arm it right here for a real initial capture.
    if (openMode == 1u && tex.width >= 256 && tex.height >= 256) {
        self.cardReady = YES;
    }
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
    [enc setFragmentTexture:self.texture atIndex:0];
    uint32_t savedOpenMode = _u.openMode;
    if (savedOpenMode == 3u) {
        // .231: staged wave -- draw the still-intact source card behind the
        // dissolve front, then the growing target card, then the flying grains.
        for (uint32_t pass = 4u; pass <= 5u; pass++) {
            _u.openMode = pass;
            [enc setVertexBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
            [enc setFragmentBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0 vertexCount:6
                  instanceCount:(NSUInteger)(_u.columns * _u.rows)];
        }
        _u.openMode = savedOpenMode;
    }
    [enc setVertexBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
    // .156: the open fragment reads u.seed/u.time for the sparkle phase;
    // without this binding the whole shader failed to compile and BOTH
    // open and dissolve fell back to "no effect".
    [enc setFragmentBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
    // 6 vertices = one quad; one instance per grain. ONE draw call for all.
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
            vertexStart:0 vertexCount:6
          instanceCount:(NSUInteger)(_u.columns * _u.rows)];
    // .157: deposited-card tile pass (open only, once the real texture has
    // been swapped in). Same clock, same hash, same grid -- the card is
    // painted on the GPU cell by cell, exactly where the dust dies.
    if (_u.openMode == 1u && _cardReady) {
        uint32_t savedOpen = _u.openMode;
        _u.openMode = 2u;
        [enc setVertexBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
        [enc setFragmentBytes:&_u length:sizeof(AXSMetalDustUniforms) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0 vertexCount:6
              instanceCount:(NSUInteger)(_u.columns * _u.rows)];
        _u.openMode = savedOpen;
    }
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
        if (done) {
            if (self.u.openMode == 1u && !self.fadingOut) {
                // .129/.165: open assemble -- the real card unhides at +0.05s
                // (endWipeReveal). The overlay fade must start only AFTER that
                // handoff: fading first let the card pop through a nearly
                // transparent overlay, which read as a flash after the dust.
                self.fadingOut = YES;
                self.link.paused = YES;   // freeze the deposited frame
                UIView *ov = self.overlay;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.18 animations:^{ ov.alpha = 0.0; }
                                     completion:^(BOOL finished){ [self cleanup]; }];
                });
                return;
            }
            [self cleanup];
        }
    } @catch (NSException *e) {
        axs_msd_log(@"metal tick EXCEPTION %@", [e reason]);
        [self cleanup];
    }
}

// .133: hide/show the particle overlay while the composited screen is
// captured (so the screen crop contains the card, not the particles)
// .131: swap the particle texture mid-flight -- the assemble starts with the
// glowing-dot texture, then the real card snapshot (captured while the card
// was briefly visible under the dense cloud) replaces it, so the converged
// grains literally become fragments of the floating window.
// .140: swap the particle texture mid-flight (scene capture finishes while
// the grains are already flying -- they switch to window fragments on the fly)
- (BOOL)replaceTextureWithImage:(UIImage *)img {
    @try {
        if (img == nil || img.CGImage == NULL) return NO;
        id<MTLTexture> newTex = axs_msd_makeTexture(img.CGImage, sMsdDevice);
        if (newTex == nil) return NO;
        self.texture = newTex;
        // .157: only a REAL card capture (>=256px) enables the deposited-tile
        // pass; the 128x128 sand placeholder never may.
        if (self.u.openMode == 1u
            && CGImageGetWidth(img.CGImage) >= 256
            && CGImageGetHeight(img.CGImage) >= 256) {
            self.cardReady = YES;
        }
        return YES;
    } @catch (NSException *ignored) {
        return NO;
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
        overlay.alpha = 1.0;
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
        if (openMode == 1u || openMode == 3u) sMsdActiveOpenRenderer = renderer;

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

// .133: hide/show the particle overlay while the composited screen is
// captured (so the screen crop contains the card, not the particles)
// .131: swap the particle texture mid-flight (the caller captured the real
// card while it was briefly visible under the dense cloud)
// beautify.141 open-assemble: grains fly FROM sourcePoint TO the card
// .140: open assemble returning the live renderer handle (for mid-flight swap)
void *axs_metalAssemblePlayRet(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                               CGFloat density, CGPoint sourcePoint) {
    BOOL ok = axs_metalPlayCommon(shot, frameInWindow, duration, 8, density, 1,
                                  sourcePoint);
    return ok ? (__bridge void *)sMsdActiveOpenRenderer : NULL;
}

BOOL axs_metalReplaceTexture(void *renderer, UIImage *img) {
    if (renderer == NULL || img == nil) return NO;
    AXSMetalSandRenderer *r = (__bridge AXSMetalSandRenderer *)renderer;
    // .157: the async capture retry may fire after cleanup released the
    // renderer; pointer comparison only, no deref of a dead object.
    if (sMsdActiveRenderers == nil || ![sMsdActiveRenderers containsObject:r]) {
        return NO;
    }
    return [r replaceTextureWithImage:img];
}

BOOL axs_metalAssemblePlay(UIImage *shot, CGRect frameInWindow, CGFloat duration,
                           CGFloat density, CGPoint sourcePoint) {
    return axs_metalPlayCommon(shot, frameInWindow, duration, 8, density, 1,
                               sourcePoint);
}

// beautify.231: staged rect-to-rect particle transfer for float<->dock.
// A cell leaves the source only when the dissolve front reaches it, flies to
// its matching target cell, and deposits there; the source stays intact behind
// the front and the target grows cell by cell. No whole-plane translation.
// departDir/arriveDir are the 0..7 diagonal order modes (3 = TR->BL, 4 = BL->TR).
void *axs_metalDockTransferPlayRet(UIImage *shot, CGRect fromFrame, CGRect toFrame,
                                   CGFloat duration, CGFloat density,
                                   uint32_t departDir, uint32_t arriveDir) {
    axs_msd_setTransferConfig(fromFrame, departDir, arriveDir);
    BOOL ok = axs_metalPlayCommon(shot, toFrame, duration, 8, density, 3,
                                  CGPointMake(0, 0));
    return ok ? (__bridge void *)sMsdActiveOpenRenderer : NULL;
}

// .155: the CPU reveal mask must use the renderer's exact clock, not a
// separately re-based one, or the card edge and particle arrivals drift apart.
CFTimeInterval axs_metalAssembleStartTime(void *renderer) {
    if (renderer == NULL) return CACurrentMediaTime();
    AXSMetalSandRenderer *r = (__bridge AXSMetalSandRenderer *)renderer;
    return r.start;
}
