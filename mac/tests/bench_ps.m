/*
 * bench_ps.m -- GPU cost of the NV2A pixel shaders, without the game.
 *
 *   bench_ps <nv2a.metal> <spec-keys.txt> [top N]
 *
 * spec-keys.txt is what RECOMP_SPEC_DUMP writes: one combiner configuration
 * per line with the number of draws that used it. Each of the N most used is
 * specialised from the shader source, as the renderer does, and drawn as
 * full-screen triangles into a 2560x1440 4x MSAA target with depth; the GPU
 * time per frame-sized fill is reported, then the average weighted by use.
 * Compiling the source (not the built library) lets a changed nv2a.metal be
 * measured before the game is rebuilt.
 */
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 2560
#define H 1440
#define SAMPLES 4
#define DRAWS 16

static const char *const psv_names[6] = { "ps_main", "ps_main_flat", "ps_wdepth", "ps_wdepth_flat",
                                          "ps_main_nc", "ps_main_flat_nc" };

static NSString *const bench_vs_src =
    @"\nstruct BenchV { float4 pos [[position]]; float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];\n"
    @"  float4 fog [[user(fog)]]; float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]];\n"
    @"  float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]]; };\n"
    @"vertex BenchV bench_vs(uint vid [[vertex_id]]) {\n"
    @"  float2 p = float2((vid << 1) & 2, vid & 2); BenchV o;\n"
    @"  o.pos = float4(p * 2.0 - 1.0, 0.5, 1.0);\n"
    @"  o.d0 = float4(0.8, 0.7, 0.6, 0.9); o.d1 = float4(0.2, 0.3, 0.4, 0.5);\n"
    @"  o.fog = float4(0.5, 1000.0 + 50000.0 * p.y, 0, 0);\n"
    @"  o.t0 = float4(p * 3.0, 0.4, 1.0); o.t1 = float4(p * 2.0, 0.3, 1.0);\n"
    @"  o.t2 = float4(p * 5.0, 0.6, 1.0); o.t3 = float4(p, 0.2, 1.0);\n"
    @"  return o; }\n";

static id<MTLTexture> make_tex(id<MTLDevice> dev, id<MTLCommandQueue> q, int cube, int size)
{
    MTLTextureDescriptor *d = cube
        ? [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm size:size mipmapped:YES]
        : [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:size height:size mipmapped:YES];
    id<MTLTexture> t;
    uint32_t *px = malloc((size_t)size * size * 4);
    int i, f;
    d.storageMode = MTLStorageModeShared;
    t = [dev newTextureWithDescriptor:d];
    for (i = 0; i < size * size; i++) px[i] = (uint32_t)(i * 2654435761u) | 0xFF000000u;
    for (f = 0; f < (cube ? 6 : 1); f++)
        [t replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0 slice:f
               withBytes:px bytesPerRow:size * 4 bytesPerImage:0];
    free(px);
    {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b generateMipmapsForTexture:t];
        [b endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
    }
    return t;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSError *err = nil;
        NSString *src;
        id<MTLLibrary> lib;
        MTLCompileOptions *opt = [[MTLCompileOptions alloc] init];
        int top = argc > 3 ? atoi(argv[3]) : 20, n = 0, i;
        struct { unsigned long long draws; unsigned variant; uint32_t v[53]; } keys[1024];
        FILE *f;
        char line[4096];
        id<MTLTexture> rt, ds, t2[4], tc[4];
        id<MTLSamplerState> smp;
        id<MTLDepthStencilState> dss;
        uint8_t consts[1024];
        id<MTLFunction> vs;
        double wsum = 0, wtot = 0;

        if (argc < 3) { fprintf(stderr, "usage: bench_ps nv2a.metal spec-keys.txt [N]\n"); return 2; }
        src = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
                                        encoding:NSUTF8StringEncoding error:&err];
        if (!src) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
        src = [src stringByAppendingString:bench_vs_src];
        opt.languageVersion = MTLLanguageVersion3_1;
        if (@available(macOS 15.0, *)) opt.mathMode = MTLMathModeRelaxed;
        lib = [dev newLibraryWithSource:src options:opt error:&err];
        if (!lib) { fprintf(stderr, "compile: %s\n", [[err description] UTF8String]); return 1; }
        vs = [lib newFunctionWithName:@"bench_vs"];

        if (!(f = fopen(argv[2], "r"))) { fprintf(stderr, "cannot read %s\n", argv[2]); return 1; }
        while (n < 1024 && fgets(line, sizeof line, f)) {
            char *p = line, *e;
            keys[n].draws = strtoull(p, &e, 10); p = e;
            keys[n].variant = (unsigned)strtoul(p, &e, 10); p = e;
            for (i = 0; i < 53; i++) { keys[n].v[i] = (uint32_t)strtoul(p, &e, 16); p = e; }
            n++;
        }
        fclose(f);
        /* most used first */
        for (i = 0; i < n; i++) {
            int j, b = i;
            for (j = i + 1; j < n; j++) if (keys[j].draws > keys[b].draws) b = j;
            if (b != i) { __typeof__(keys[0]) t = keys[i]; keys[i] = keys[b]; keys[b] = t; }
        }
        if (top > n) top = n;

        {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:W height:H mipmapped:NO];
            d.textureType = MTLTextureType2DMultisample; d.sampleCount = SAMPLES;
            d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
            rt = [dev newTextureWithDescriptor:d];
            d.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            ds = [dev newTextureWithDescriptor:d];
        }
        for (i = 0; i < 4; i++) { t2[i] = make_tex(dev, q, 0, 1024); tc[i] = make_tex(dev, q, 1, 128); }
        {
            MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
            sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
            sd.mipFilter = MTLSamplerMipFilterLinear;
            sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeRepeat;
            sd.maxAnisotropy = 16;
            smp = [dev newSamplerStateWithDescriptor:sd];
        }
        {
            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionAlways;
            dd.depthWriteEnabled = YES;
            dss = [dev newDepthStencilStateWithDescriptor:dd];
        }
        memset(consts, 0, sizeof consts);
        {   /* PSConsts: cf0/cf1 at 128/256, tex_scale at 528, zp0 736, zp1 752 */
            float *fl = (float *)consts;
            for (i = 0; i < 64; i++) fl[128 / 4 + i] = 0.5f;
            for (i = 0; i < 16; i++) fl[528 / 4 + i] = 1.0f;
            fl[736 / 4 + 2] = fl[736 / 4 + 3] = 4.0f;
            fl[752 / 4 + 0] = 1.0f / 16777216.0f; fl[752 / 4 + 1] = 16777215.0f;
        }

        printf("%-4s %10s %-16s %9s\n", "#", "draws", "shader", "ms/fill");
        for (i = -2; i < top; i++) {
            id<MTLFunction> fs;
            MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
            id<MTLRenderPipelineState> pso;
            const char *name;
            double best = 1e9;
            int rep;
            if (i == -2) { name = "ps_dbg"; fs = [lib newFunctionWithName:@"ps_dbg"]; }
            else if (i == -1) { name = "ps_dbg_tex"; fs = [lib newFunctionWithName:@"ps_dbg_tex"]; }
            else {
                MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
                name = psv_names[keys[i].variant & 7];
                [cv setConstantValues:keys[i].v type:MTLDataTypeUInt withRange:NSMakeRange(0, 53)];
                fs = [lib newFunctionWithName:[NSString stringWithUTF8String:name] constantValues:cv error:&err];
                if (!fs) { fprintf(stderr, "specialise %d: %s\n", i, [[err description] UTF8String]); continue; }
            }
            pd.vertexFunction = vs; pd.fragmentFunction = fs;
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pd.depthAttachmentPixelFormat = pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            pd.rasterSampleCount = SAMPLES;
            pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!pso) { fprintf(stderr, "pipeline %d: %s\n", i, [[err description] UTF8String]); continue; }
            for (rep = 0; rep < 6; rep++) {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                id<MTLRenderCommandEncoder> e;
                int k;
                rp.colorAttachments[0].texture = rt;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
                rp.depthAttachment.texture = ds;
                rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.storeAction = MTLStoreActionDontCare;
                rp.stencilAttachment.texture = ds;
                e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:pso];
                [e setDepthStencilState:dss];
                [e setFragmentBytes:consts length:928 atIndex:0];
                for (k = 0; k < 4; k++) {
                    [e setFragmentTexture:t2[k] atIndex:k];
                    [e setFragmentTexture:tc[k] atIndex:4 + k];
                    [e setFragmentSamplerState:smp atIndex:k];
                }
                [e setFragmentTexture:t2[0] atIndex:8];
                for (k = 0; k < DRAWS; k++)
                    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                if (rep >= 2) {
                    double t = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0 / DRAWS;
                    if (t < best) best = t;
                }
            }
            printf("%-4d %10llu %-16s %9.3f\n", i, i >= 0 ? keys[i].draws : 0ULL, name, best);
            if (i >= 0) { wsum += best * (double)keys[i].draws; wtot += (double)keys[i].draws; }
        }
        printf("weighted ms/fill over the top %d: %.3f\n", top, wtot ? wsum / wtot : 0.0);
    }
    return 0;
}
