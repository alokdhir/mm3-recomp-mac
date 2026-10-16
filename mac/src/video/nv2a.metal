/*
 * nv2a.metal -- the NV2A renderer's shaders for Metal (nv2a_metal.m).
 *
 * A translation of the HLSL in xboxrecomp's src/video/nv2a_d3d11.c (s_hlsl),
 * kept in the same order and with the same comments where they explain the
 * hardware, so the two can be compared line by line:
 *
 *   ub_vs                  every draw's vertex stage: pulls raw guest vertex
 *                          arrays and interprets the NV2A vertex program
 *   ps_main / ps_wdepth    the register combiners and texture stages, with
 *                          w-buffer depth in the second; *_flat variants take
 *                          colours from one vertex (FLATQ in the HLSL)
 *   present_*, clear_*     presentation, uploads and clears
 *   y16_*, y16d_*          a colour or depth target read as LU_IMAGE_Y16
 *
 * Specialisation: the HLSL compiled a variant per combiner configuration with
 * the control words as constants (SPEC/SPEC_DECL). Here they are function
 * constants; a pipeline built without them interprets the cbuffer copy.
 *
 * Differences that are not just spelling: HLSL round() is round-half-even,
 * which is MSL rint(); a vector ?: is select(); sampler LOD bias is not part
 * of a Metal sampler, so it arrives per stage in lod_bias.
 */
#include <metal_stdlib>
using namespace metal;

/* ------------------------------------------------------------ vertex stage */

struct UbConsts {
    uint4 at[16];       /* byte offset, stride, type, size (0: DEF) */
    float4 DEF[16];
    uint4 ub_info;      /* start slot, program, dx offset, - */
    float4 ub_map;      /* 2/w, 2/h, 1/zmax, squeeze */
    uint4 ub_fogi;
    float4 ub_fogf;
    float4 ub_place;    /* x shift (NDC), y scale, pixel-0 snap, screen offset */
};

struct VSOut {
    float4 pos [[position]];
    float4 d0 [[user(d0)]];
    float4 d1 [[user(d1)]];
    float4 fog [[user(fog)]];
    float4 t0 [[user(t0)]];
    float4 t1 [[user(t1)]];
    float4 t2 [[user(t2)]];
    float4 t3 [[user(t3)]];
    float psize [[point_size]];
};

static inline uint ldw(device const uint *VB, uint a)
{
    uint b = a >> 2, s = (a & 3u) * 8u, l = VB[b];
    return s ? (l >> s) | (VB[b + 1u] << (32u - s)) : l;
}

static inline float s16(device const uint *VB, uint a)
{
    return (float)(as_type<int>(ldw(VB, a) << 16) >> 16);
}

static float4 fetch(constant UbConsts &u, device const uint *VB, uint i, uint vid)
{
    uint4 d = u.at[i];
    if (d.w == 0u) return u.DEF[i];
    uint a = d.x + vid * d.y;
    float4 r = float4(0, 0, 0, 1);
    if (d.z == 0u) { uint c = ldw(VB, a); r = float4((c >> 16) & 255u, (c >> 8) & 255u, c & 255u, c >> 24) / 255.0; }
    else if (d.z == 6u) { int v = as_type<int>(ldw(VB, a));
        r = float4((float)((v << 21) >> 21) / 1023.0, (float)((v << 10) >> 21) / 1023.0, (float)(v >> 22) / 511.0, 1.0); }
    else if (d.z == 2u) { for (uint k = 0; k < 4; k++) if (k < d.w) r[k] = as_type<float>(ldw(VB, a + 4u * k)); }
    else if (d.z == 4u) { uint c = ldw(VB, a); for (uint k = 0; k < 4; k++) if (k < d.w) r[k] = (float)((c >> (8u * k)) & 255u) / 255.0; }
    else if (d.z == 1u) { for (uint k = 0; k < 4; k++) if (k < d.w) r[k] = s16(VB, a + 2u * k) / 32767.0; }
    else if (d.z == 5u) { for (uint k = 0; k < 4; k++) if (k < d.w) r[k] = s16(VB, a + 2u * k); }
    return r;
}

/* A component by dynamic index, by selection: indexing a vector compiles to
 * a dot product with a one-hot vector, and inf * 0 there turns every
 * component of a register holding an infinity (rcp of 0) into NaN. */
static inline float cmp4(float4 s, uint i)
{
    return i == 0u ? s.x : (i == 1u ? s.y : (i == 2u ? s.z : s.w));
}

static inline float4 rd(thread const float4 *R, thread const float4 *V, constant float4 *C,
                        uint swz, uint neg, uint mux, uint reg, uint vi, uint ci)
{
    float4 s = mux == 1u ? R[reg < 13u ? reg : 0u] : (mux == 2u ? V[vi] : C[ci]);
    float4 r = float4(cmp4(s, (swz >> 6) & 3u), cmp4(s, (swz >> 4) & 3u), cmp4(s, (swz >> 2) & 3u), cmp4(s, swz & 3u));
    return neg ? -r : r;
}

static inline float4 msk(float4 d, float4 v, uint m)
{
    return float4((m & 8u) ? v.x : d.x, (m & 4u) ? v.y : d.y, (m & 2u) ? v.z : d.z, (m & 1u) ? v.w : d.w);
}

static float ub_fog(constant UbConsts &u, float d)
{
    if (!u.ub_fogi.x) return 1.0;
    float f, px = u.ub_fogf.x, py = u.ub_fogf.y; uint mode = u.ub_fogi.y;
    if (mode == 0x800u || mode == 0x802u) f = px + exp2(d * py * 16.0) - 1.5;
    else if (mode == 0x801u || mode == 0x803u) f = px + exp2(-d * d * py * py * 32.0) - 1.5;
    else f = px + d * py - 1.0;
    if (mode == 0x802u || mode == 0x803u || mode == 0x804u) f = abs(f);
    if (isnan(f)) f = 1.0;
    return saturate(f);
}

vertex VSOut ub_vs(uint vid [[vertex_id]],
                   constant UbConsts &u [[buffer(0)]],
                   constant uint4 *PROG [[buffer(1)]],
                   constant float4 *C [[buffer(2)]],
                   device const uint *VB [[buffer(3)]])
{
    VSOut o;
    float4 P, d0, d1, t0, t1, t2, t3;
    float fog = 1.0;
    if (u.ub_info.y) {
        float4 R[13], V[16], O[13];
        for (uint i = 0; i < 16; i++) V[i] = fetch(u, VB, i, vid);
        for (uint j = 0; j < 13; j++) { R[j] = float4(0); O[j] = float4(0); }
        O[3].w = 1; O[4].w = 1; O[9].w = 1; O[10].w = 1; O[11].w = 1; O[12].w = 1;
        int a0 = 0;
        for (uint s = u.ub_info.x; s < 136u; s++) {
            uint4 ins = PROG[s];
            uint mac = (ins.y >> 21) & 15u, ilu = (ins.y >> 25) & 7u, vi = (ins.y >> 9) & 15u;
            int ci = (int)((ins.y >> 13) & 255u) + (((ins.w >> 1) & 1u) ? a0 : 0);
            uint cu = (ci >= 0 && ci < 192) ? (uint)ci : 0u;
            float4 A = rd(R, V, C, ins.y & 255u, (ins.y >> 8) & 1u, (ins.z >> 26) & 3u, (ins.z >> 28) & 15u, vi, cu);
            float4 B = rd(R, V, C, (ins.z >> 17) & 255u, (ins.z >> 25) & 1u, (ins.z >> 11) & 3u, (ins.z >> 13) & 15u, vi, cu);
            float4 Cc = rd(R, V, C, (ins.z >> 2) & 255u, (ins.z >> 10) & 1u, (ins.w >> 28) & 3u, ((ins.z & 3u) << 2) | (ins.w >> 30), vi, cu);
            float4 mr = mac ? A : float4(0), ir = ilu ? Cc : float4(0);
            if (mac == 2u) mr = A * B;
            else if (mac == 3u) mr = A + Cc;
            else if (mac == 4u) mr = A * B + Cc;
            else if (mac == 5u) mr = float4(dot(A.xyz, B.xyz));
            else if (mac == 6u) mr = float4(dot(A.xyz, B.xyz) + B.w);
            else if (mac == 7u) mr = float4(dot(A, B));
            else if (mac == 8u) mr = float4(1.0, A.y * B.y, A.z, B.w);
            else if (mac == 9u) mr = select(B, A, A < B);
            else if (mac == 10u) mr = select(B, A, A >= B);
            else if (mac == 11u) mr = select(float4(0), float4(1), A < B);
            else if (mac == 12u) mr = select(float4(0), float4(1), A >= B);
            else if (mac == 13u) a0 = (int)floor(A.x + 0.001);
            float x = Cc.x;
            if (ilu == 2u) ir = float4(x == 0.0 ? INFINITY : 1.0 / x);
            else if (ilu == 3u) { float f = 1.0 / x; float af = clamp(abs(f), 5.42101e-20, 1.884467e19);
                ir = float4(f < 0 ? -af : af); }
            else if (ilu == 4u) ir = float4(1.0 / sqrt(abs(x)));
            else if (ilu == 5u) { float fl = floor(x); ir = float4(exp2(fl), x - fl, exp2(x), 1.0); }
            else if (ilu == 6u) { float ax = abs(x);
                if (ax == 0.0) ir = float4(-INFINITY, 1.0, -INFINITY, 1.0);
                else { float e = floor(log2(ax)); ir = float4(e, ax / exp2(e), log2(ax), 1.0); } }
            else if (ilu == 7u) { float nl = max(x, 0.0), nh = max(Cc.y, 0.0), p = clamp(Cc.w, -127.9961, 127.9961);
                ir = float4(1.0, nl, x > 0.0 ? (p == 0.0 ? 1.0 : pow(nh, p)) : 0.0, 1.0); }
            uint mm = (ins.w >> 24) & 15u, im = (ins.w >> 16) & 15u, td = (ins.w >> 20) & 15u;
            uint om = (ins.w >> 12) & 15u, oa = (ins.w >> 3) & 255u;
            /* As xemu: paired with an ILU op the MAC cannot write R1 (the ILU
             * owns it), and an output comes only from a unit that ran. */
            if (mac != 0u && mac != 13u && mm != 0u && td < 13u && !(ilu != 0u && td == 1u))
                R[td] = msk(R[td], mr, mm);
            if (ilu != 0u && im != 0u) { uint it = mac ? 1u : td; if (it < 13u) R[it] = msk(R[it], ir, im); }
            /* ponytail: writes to the constant file (out-to-c[]) are dropped;
             * a local copy of C[] would support them. */
            if (om != 0u && ((ins.w >> 11) & 1u) && (((ins.w >> 2) & 1u) ? ilu : mac) != 0u) {
                float4 ov = ((ins.w >> 2) & 1u) ? ir : mr;
                if (oa == 0u) R[12] = msk(R[12], ov, om);
                else if (oa < 13u) O[oa] = msk(O[oa], ov, om);
            }
            if (ins.w & 1u) break;
        }
        P = R[12]; d0 = O[3]; d1 = O[4]; fog = ub_fog(u, O[5].x);
        t0 = O[9]; t1 = O[10]; t2 = O[11]; t3 = O[12];
    } else {
        /* Pre-transformed: position (x, y, z, rhw), diffuse 3, specular 4,
         * texture coordinates 9-12. */
        float4 p0 = fetch(u, VB, 0, vid);
        P = float4(p0.xyz, u.at[0].w == 4u && p0.w > 0.0 ? 1.0 / p0.w : 1.0);
        d0 = fetch(u, VB, 3, vid); d1 = fetch(u, VB, 4, vid);
        t0 = fetch(u, VB, 9, vid); t1 = fetch(u, VB, 10, vid);
        t2 = fetch(u, VB, 11, vid); t3 = fetch(u, VB, 12, vid);
    }
    float px = P.x;
    if (u.ub_info.z != 0xFFFFFFFFu) px += as_type<float>(VB[(u.ub_info.z >> 2) + vid]);
    /* The NV2A rasterises with 4-bit sub-pixel precision, truncating (xemu
     * roundScreenCoords), so the Xbox D3D screen offset 0.53125 puts a
     * full-target quad's left/top edge exactly on the centre of pixel 0. A
     * coordinate that truncates to that first centre is placed on the target
     * edge, as the hardware covers it; everything else is unchanged. */
    float py = P.y;
    if (u.ub_place.z != 0.0 && px >= 0.5 && px < 0.5625) px = 0.0;
    if (u.ub_place.z != 0.0 && py >= 0.5 && py < 0.5625) py = 0.0;
    if (u.ub_place.w != 0.0) {
        bool flat = abs(P.w - 1.0) < 1e-6;
        if (!flat || (fract(px) >= 0.5 && fract(px) < 0.5625)) px -= u.ub_place.w;
        if (!flat || (fract(py) >= 0.5 && fract(py) < 0.5625)) py -= u.ub_place.w;
    }
    /* NV2A clamps raster w away from zero and infinity (xemu clampAwayZeroInf),
     * keeping its sign so geometry behind the eye still clips. */
    float w = P.w;
    float aw = clamp(abs(w), 5.421011e-20, 1.8446744e19);
    w = w < 0 ? -aw : aw;
    o.pos = float4(((px * u.ub_map.x - 1.0) * u.ub_map.w + u.ub_place.x) * w,
                   (1.0 - py * u.ub_map.y) * u.ub_place.y * w, P.z * u.ub_map.z * w, w);
    o.d0 = saturate(d0); o.d1 = saturate(d1); o.fog = float4(fog, w, 0, 0);
    o.t0 = t0; o.t1 = t1; o.t2 = t2; o.t3 = t3;
    o.psize = 1.0;
    return o;
}

/* ------------------------------------------------------------- pixel stage */

struct PSConsts {
    uint4 c_icw[2]; uint4 a_icw[2]; uint4 c_ocw[2]; uint4 a_ocw[2];
    float4 cf0[8]; float4 cf1[8]; float4 fin_c0; float4 fin_c1;
    uint fin0; uint fin1; uint rc_control; uint stage_prog;
    uint alpha_func; uint alpha_ref; uint ps_flags; uint clip_plane;
    uint other_input; uint dot_map; uint pad0; uint pad1;
    uint4 tex_info[4];      /* x: bit0 alphakill, y: signed mask (filter>>28), z: tapbox */
    float4 tex_scale[4];    /* xy multiply the coordinate (1/size for linear) */
    float4 fog_color;
    float4 bump_mat[4]; float4 bump_lum[4];
    float4 zp0; float4 zp1;
    float4 wclip[8]; uint wclip_mode; uint wclip_pad0; uint wclip_pad1; uint wclip_pad2;
    float4 lod_bias;        /* per stage: the sampler's MipLODBias */
};

/* SPEC: the control words of one combiner configuration, as constants. */
constant uint sp_c_icw0 [[function_constant(0)]];
constant uint sp_c_icw1 [[function_constant(1)]];
constant uint sp_c_icw2 [[function_constant(2)]];
constant uint sp_c_icw3 [[function_constant(3)]];
constant uint sp_c_icw4 [[function_constant(4)]];
constant uint sp_c_icw5 [[function_constant(5)]];
constant uint sp_c_icw6 [[function_constant(6)]];
constant uint sp_c_icw7 [[function_constant(7)]];
constant uint sp_a_icw0 [[function_constant(8)]];
constant uint sp_a_icw1 [[function_constant(9)]];
constant uint sp_a_icw2 [[function_constant(10)]];
constant uint sp_a_icw3 [[function_constant(11)]];
constant uint sp_a_icw4 [[function_constant(12)]];
constant uint sp_a_icw5 [[function_constant(13)]];
constant uint sp_a_icw6 [[function_constant(14)]];
constant uint sp_a_icw7 [[function_constant(15)]];
constant uint sp_c_ocw0 [[function_constant(16)]];
constant uint sp_c_ocw1 [[function_constant(17)]];
constant uint sp_c_ocw2 [[function_constant(18)]];
constant uint sp_c_ocw3 [[function_constant(19)]];
constant uint sp_c_ocw4 [[function_constant(20)]];
constant uint sp_c_ocw5 [[function_constant(21)]];
constant uint sp_c_ocw6 [[function_constant(22)]];
constant uint sp_c_ocw7 [[function_constant(23)]];
constant uint sp_a_ocw0 [[function_constant(24)]];
constant uint sp_a_ocw1 [[function_constant(25)]];
constant uint sp_a_ocw2 [[function_constant(26)]];
constant uint sp_a_ocw3 [[function_constant(27)]];
constant uint sp_a_ocw4 [[function_constant(28)]];
constant uint sp_a_ocw5 [[function_constant(29)]];
constant uint sp_a_ocw6 [[function_constant(30)]];
constant uint sp_a_ocw7 [[function_constant(31)]];
constant uint sp_fin0 [[function_constant(32)]];
constant uint sp_fin1 [[function_constant(33)]];
constant uint sp_rc_control [[function_constant(34)]];
constant uint sp_stage_prog [[function_constant(35)]];
constant uint sp_alpha_func [[function_constant(36)]];
constant uint sp_ps_flags [[function_constant(37)]];
constant uint sp_clip_plane [[function_constant(38)]];
constant uint sp_other_input [[function_constant(39)]];
constant uint sp_dot_map [[function_constant(40)]];
constant uint sp_tex_info0x [[function_constant(41)]];
constant uint sp_tex_info0y [[function_constant(42)]];
constant uint sp_tex_info0z [[function_constant(43)]];
constant uint sp_tex_info1x [[function_constant(44)]];
constant uint sp_tex_info1y [[function_constant(45)]];
constant uint sp_tex_info1z [[function_constant(46)]];
constant uint sp_tex_info2x [[function_constant(47)]];
constant uint sp_tex_info2y [[function_constant(48)]];
constant uint sp_tex_info2z [[function_constant(49)]];
constant uint sp_tex_info3x [[function_constant(50)]];
constant uint sp_tex_info3y [[function_constant(51)]];
constant uint sp_tex_info3z [[function_constant(52)]];

constant bool SPEC = is_function_constant_defined(sp_rc_control);
#define SPV(n) (is_function_constant_defined(n) ? n : 0u)
/* Looked up per stage by switch rather than from constant arrays, and the
 * stage loops in shade() unrolled in full: together they let a specialised
 * shader fold every control word and keep the combiner registers R[] in
 * registers. Left to itself the compiler kept the loops, so R[] was indexed
 * at run time from memory -- 2 to 50 times the cost per pixel, most of the
 * GPU's time in a race (mac/tests/bench_ps.m measures it). */
static inline uint SP_C_ICW(uint s) { switch (s) { case 0: return SPV(sp_c_icw0); case 1: return SPV(sp_c_icw1); case 2: return SPV(sp_c_icw2); case 3: return SPV(sp_c_icw3); case 4: return SPV(sp_c_icw4); case 5: return SPV(sp_c_icw5); case 6: return SPV(sp_c_icw6); case 7: return SPV(sp_c_icw7); default: return 0u; } }
static inline uint SP_A_ICW(uint s) { switch (s) { case 0: return SPV(sp_a_icw0); case 1: return SPV(sp_a_icw1); case 2: return SPV(sp_a_icw2); case 3: return SPV(sp_a_icw3); case 4: return SPV(sp_a_icw4); case 5: return SPV(sp_a_icw5); case 6: return SPV(sp_a_icw6); case 7: return SPV(sp_a_icw7); default: return 0u; } }
static inline uint SP_C_OCW(uint s) { switch (s) { case 0: return SPV(sp_c_ocw0); case 1: return SPV(sp_c_ocw1); case 2: return SPV(sp_c_ocw2); case 3: return SPV(sp_c_ocw3); case 4: return SPV(sp_c_ocw4); case 5: return SPV(sp_c_ocw5); case 6: return SPV(sp_c_ocw6); case 7: return SPV(sp_c_ocw7); default: return 0u; } }
static inline uint SP_A_OCW(uint s) { switch (s) { case 0: return SPV(sp_a_ocw0); case 1: return SPV(sp_a_ocw1); case 2: return SPV(sp_a_ocw2); case 3: return SPV(sp_a_ocw3); case 4: return SPV(sp_a_ocw4); case 5: return SPV(sp_a_ocw5); case 6: return SPV(sp_a_ocw6); case 7: return SPV(sp_a_ocw7); default: return 0u; } }
static inline uint3 SP_TEX_INFO(uint n) {
    switch (n) {
    case 0: return uint3(SPV(sp_tex_info0x), SPV(sp_tex_info0y), SPV(sp_tex_info0z));
    case 1: return uint3(SPV(sp_tex_info1x), SPV(sp_tex_info1y), SPV(sp_tex_info1z));
    case 2: return uint3(SPV(sp_tex_info2x), SPV(sp_tex_info2y), SPV(sp_tex_info2z));
    default: return uint3(SPV(sp_tex_info3x), SPV(sp_tex_info3y), SPV(sp_tex_info3z)); } }

static inline uint U8(constant uint4 *a, uint s) { return a[s >> 2][s & 3]; }

#define K_C_ICW(s)      (SPEC ? SP_C_ICW(s) : U8(pc.c_icw, s))
#define K_A_ICW(s)      (SPEC ? SP_A_ICW(s) : U8(pc.a_icw, s))
#define K_C_OCW(s)      (SPEC ? SP_C_OCW(s) : U8(pc.c_ocw, s))
#define K_A_OCW(s)      (SPEC ? SP_A_OCW(s) : U8(pc.a_ocw, s))
#define K_FIN0          (SPEC ? SPV(sp_fin0) : pc.fin0)
#define K_FIN1          (SPEC ? SPV(sp_fin1) : pc.fin1)
#define K_RC_CONTROL    (SPEC ? SPV(sp_rc_control) : pc.rc_control)
#define K_STAGE_PROG    (SPEC ? SPV(sp_stage_prog) : pc.stage_prog)
#define K_ALPHA_FUNC    (SPEC ? SPV(sp_alpha_func) : pc.alpha_func)
#define K_PS_FLAGS      (SPEC ? SPV(sp_ps_flags) : pc.ps_flags)
#define K_CLIP_PLANE    (SPEC ? SPV(sp_clip_plane) : pc.clip_plane)
#define K_OTHER_INPUT   (SPEC ? SPV(sp_other_input) : pc.other_input)
#define K_DOT_MAP       (SPEC ? SPV(sp_dot_map) : pc.dot_map)
#define K_TEX_INFO(n)   (SPEC ? SP_TEX_INFO(n) : pc.tex_info[n].xyz)

/* What the stages read: four 2D textures, four cube maps, the frame drawn
 * so far (the horizon panorama) and four samplers. Passed explicitly. */
#define TEXARGS texture2d<float> T2D0, texture2d<float> T2D1, texture2d<float> T2D2, \
                texture2d<float> T2D3, texturecube<float> TC0, texturecube<float> TC1, \
                texturecube<float> TC2, texturecube<float> TC3, texture2d<float> FBK, \
                sampler S0, sampler S1, sampler S2, sampler S3
#define TEXPASS T2D0, T2D1, T2D2, T2D3, TC0, TC1, TC2, TC3, FBK, S0, S1, S2, S3

static float map_in(float x, uint b)
{
    float p = max(x, 0.0);
    switch ((b >> 5) & 7) {
    case 0: return p; case 1: return 1.0 - saturate(x); case 2: return 2.0 * p - 1.0;
    case 3: return -2.0 * p + 1.0; case 4: return p - 0.5; case 5: return -p + 0.5;
    case 6: return x; default: return -x; }
}
static inline float3 map_in3(float3 v, uint b) { return float3(map_in(v.x, b), map_in(v.y, b), map_in(v.z, b)); }
static float3 map_out3(float3 x, uint m)
{
    if (m == 0x08) return x - 0.5; if (m == 0x10) return x * 2.0; if (m == 0x18) return (x - 0.5) * 2.0;
    if (m == 0x20) return x * 4.0; if (m == 0x30) return x * 0.5; return x;
}
static inline float signed_c(float c) { float s = c * 255.0; return clamp((s >= 127.5 ? s - 256.0 : s) / 127.0, -1.0, 1.0); }
static float4 apply_signed(float4 t, uint m)
{
    if (m & 1) t.a = signed_c(t.a); if (m & 2) t.r = signed_c(t.r);
    if (m & 4) t.g = signed_c(t.g); if (m & 8) t.b = signed_c(t.b); return t;
}
/* SET_DOT_RGBMAPPING, as xemu's sign1/2/3: 1 MINUS_1_TO_1_D3D is the
 * biased (x - 128) / 127 that D3D's _bx2 on a texture read produces (255 is
 * +1), 2 the GL mapping, 3 two's complement. */
static float3 dotmap(float3 c, uint m)
{
    float3 x = rint(saturate(c) * 255.0);
    if (m == 1) return (x - 128.0) / 127.0;
    if (m == 2) return select((x + 0.5) / 127.5, (x - 255.5) / 127.5, x >= 128.0);
    if (m == 3) return select(x, x - 256.0, x >= 128.0) / 127.0;
    return c;
}

static float4 bspline0(texture2d<float> T2D0, sampler S0, float2 uv, float lod)
{
    float2 sz = float2(T2D0.get_width(0), T2D0.get_height(0));
    float nl = (float)T2D0.get_num_mip_levels();
    lod = min(lod, nl - 1.0); sz = max(floor(sz / exp2(lod)), 1.0);
    float2 p = uv * sz - 0.5, f = fract(p), f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0, w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0, w3 = f3 / 6.0;
    float2 s0 = w0 + w1, s1 = w2 + w3; p -= f;
    float2 c0 = (p - 0.5 + w1 / s0) / sz, c1 = (p + 1.5 + w3 / s1) / sz;
    return s0.y * (s0.x * T2D0.sample(S0, c0, level(lod)) + s1.x * T2D0.sample(S0, float2(c1.x, c0.y), level(lod))) +
           s1.y * (s0.x * T2D0.sample(S0, float2(c0.x, c1.y), level(lod)) + s1.x * T2D0.sample(S0, c1, level(lod)));
}

static float4 samp2(TEXARGS, constant PSConsts &pc, float2 g_pos, uint n, float2 uv)
{
    if (n == 0 && (K_PS_FLAGS & 4)) {
        float4 c = bspline0(T2D0, S0, uv, 0.0);
        float f = (float)((K_PS_FLAGS >> 8) & 255u) / 100.0, dv = dfdy(uv.y);
        if (f > 0.0 && abs(dv) > 1e-7) {
            float2 fs = float2(FBK.get_width(), FBK.get_height());
            float y0 = clamp(g_pos.y - uv.y / dv - 3.0 * fs.y / 900.0, 0.0, fs.y - 1.0);
            float3 sky = 0;
            for (int k = -4; k <= 4; k++)
                sky += FBK.read(uint2(clamp(g_pos.x + k * fs.x / 200.0, 0.0, fs.x - 1.0), y0), 0).rgb;
            c.rgb = mix(c.rgb, sky / 9.0, f);
        }
        return c;
    }
    if (n == 0) return T2D0.sample(S0, uv, bias(pc.lod_bias[0]));
    if (n == 1) return T2D1.sample(S1, uv, bias(pc.lod_bias[1]));
    if (n == 2) return T2D2.sample(S2, uv, bias(pc.lod_bias[2]));
    return T2D3.sample(S3, uv, bias(pc.lod_bias[3]));
}

/* A point-sampled tap at a fixed spot of an upscaled render target (light
 * flares test their visibility with three such taps of the frame's alpha).
 * The block of host pixels the guest pixel became is averaged instead of
 * one host texel that changes with every sub-pixel move of the scene.
 * g: guest texel coordinates, inv: 1 / guest size. */
static float4 ldn(TEXARGS, uint n, int2 p)
{
    if (n == 0) return T2D0.read(uint2(p), 0); if (n == 1) return T2D1.read(uint2(p), 0);
    if (n == 2) return T2D2.read(uint2(p), 0); return T2D3.read(uint2(p), 0);
}

static float4 tapbox(TEXARGS, uint n, float2 g, float2 inv)
{
    uint w, h;
    if (n == 0) { w = T2D0.get_width(); h = T2D0.get_height(); }
    else if (n == 1) { w = T2D1.get_width(); h = T2D1.get_height(); }
    else if (n == 2) { w = T2D2.get_width(); h = T2D2.get_height(); }
    else { w = T2D3.get_width(); h = T2D3.get_height(); }
    float2 dim = float2(w, h), sc = dim * inv, gi = floor(g);
    int2 a = clamp(int2(floor(gi * sc + 0.5)), int2(0), int2(dim) - 1);
    int2 b = clamp(int2(floor((gi + 1.0) * sc + 0.5)), a + 1, int2(dim));
    float4 acc = 0; float cnt = 0;
    for (int y = a.y; y < b.y && y < a.y + 8; y++)
        for (int x = a.x; x < b.x && x < a.x + 8; x++) { acc += ldn(TEXPASS, n, int2(x, y)); cnt += 1; }
    return acc / max(cnt, 1.0);
}

static float4 sampc(TEXARGS, constant PSConsts &pc, uint n, float3 d)
{
    if (n == 0) return TC0.sample(S0, d, bias(pc.lod_bias[0]));
    if (n == 1) return TC1.sample(S1, d, bias(pc.lod_bias[1]));
    if (n == 2) return TC2.sample(S2, d, bias(pc.lod_bias[2]));
    return TC3.sample(S3, d, bias(pc.lod_bias[3]));
}

struct PSIn {
    float4 pos [[position]];
    float4 d0 [[user(d0), centroid_perspective]];
    float4 d1 [[user(d1), centroid_perspective]];
    float4 fog [[user(fog), centroid_perspective]];
    float4 t0 [[user(t0), centroid_perspective]];
    float4 t1 [[user(t1), centroid_perspective]];
    float4 t2 [[user(t2), centroid_perspective]];
    float4 t3 [[user(t3), centroid_perspective]];
};

/* FLATQ: colours from one vertex for flat shading. */
struct PSInFlat {
    float4 pos [[position]];
    float4 d0 [[user(d0), flat]];
    float4 d1 [[user(d1), flat]];
    float4 fog [[user(fog), centroid_perspective]];
    float4 t0 [[user(t0), centroid_perspective]];
    float4 t1 [[user(t1), centroid_perspective]];
    float4 t2 [[user(t2), centroid_perspective]];
    float4 t3 [[user(t3), centroid_perspective]];
};

static float4 shade(TEXARGS, constant PSConsts &pc, float4 ipos, float4 id0, float4 id1, float4 ifog,
                    float4 it0, float4 it1, float4 it2, float4 it3, thread uint &cov)
{
    float2 g_pos = ipos.xy;
    if (pc.wclip_mode != 0u) {   /* window clip regions the scissor cannot express */
        bool in_any = false;
        for (uint w = 0; w < 8; w++)
            in_any = in_any || (all(ipos.xy >= pc.wclip[w].xy) && all(ipos.xy < pc.wclip[w].zw));
        if (in_any == (pc.wclip_mode == 2u)) discard_fragment();
    }
    float4 tc[4] = { it0, it1, it2, it3 };
    float4 T[4] = { float4(0,0,0,1), float4(0,0,0,1), float4(0,0,0,1), float4(0,0,0,1) };
    float dots[4] = { 0, 0, 0, 0 };
    uint stage_prog = K_STAGE_PROG, other_input = K_OTHER_INPUT, dot_map = K_DOT_MAP;
    uint clip_plane = K_CLIP_PLANE;
    _Pragma("clang loop unroll(full)")
    for (uint n = 0; n < 4; n++) {
        uint mode = (stage_prog >> (n * 5)) & 31;
        uint inp = n == 2 ? (other_input >> 16) & 1 : (n == 3 ? (other_input >> 20) & 3 : 0);
        uint dm = n ? (dot_map >> ((n - 1) * 4)) & 7 : 0;
        uint3 ti = K_TEX_INFO(n);
        float4 c = tc[n]; float4 t = float4(0, 0, 0, 1);
        float q = c.w != 0.0 ? c.w : 1.0;
        if (mode == 1 || mode == 2) {
            float2 g = c.xy / q, d = abs(dfdx(g)) + abs(dfdy(g));
            if (ti.z != 0u && max(d.x, d.y) < 1e-4) t = tapbox(TEXPASS, n, g, pc.tex_scale[n].xy);
            else t = samp2(TEXPASS, pc, g_pos, n, g * pc.tex_scale[n].xy);
        }
        else if (mode == 3) t = sampc(TEXPASS, pc, n, c.xyz);
        else if (mode == 4) t = saturate(c);
        else if (mode == 5) {
            for (uint j = 0; j < 4; j++) {
                bool ge = (clip_plane >> (n * 4 + j)) & 1;
                if (ge ? c[j] >= 0.0 : c[j] < 0.0) discard_fragment(); }
            t = float4(0, 0, 0, 0);
        } else if (mode == 6 || mode == 7) {
            float4 s = T[inp]; float4 m = pc.bump_mat[n];
            float2 uv = c.xy / q * pc.tex_scale[n].xy;
            uv += float2(m.x * s.r + m.z * s.g, m.y * s.r + m.w * s.g) * pc.tex_scale[n].zw;
            t = samp2(TEXPASS, pc, g_pos, n, uv);
            if (mode == 7) t.rgb *= saturate(s.b * pc.bump_lum[n].x + pc.bump_lum[n].y);
        } else if (mode == 17 || mode == 10) {
            dots[n] = dot(c.xyz, dotmap(T[inp].rgb, dm)); t = float4(0, 0, 0, 0);
        } else if (mode == 9) {
            dots[n] = dot(c.xyz, dotmap(T[inp].rgb, dm));
            t = samp2(TEXPASS, pc, g_pos, n, float2(dots[n ? n - 1 : 0], dots[n]) * pc.tex_scale[n].xy);
        } else if (mode == 13 || mode == 14 || mode == 12 || mode == 18 || mode == 11) {
            dots[n] = dot(c.xyz, dotmap(T[inp].rgb, dm));
            float3 N = float3(dots[1], dots[2], dots[3]);
            if (mode == 12 || mode == 18) {
                float3 E = mode == 12 ? float3(tc[1].w, tc[2].w, tc[3].w) : float3(0, 0, 1);
                N = 2.0 * N * dot(N, E) / max(dot(N, N), 1e-20) - E;
            }
            if (mode == 13) t = samp2(TEXPASS, pc, g_pos, n, N.xy * pc.tex_scale[n].xy);
            else t = sampc(TEXPASS, pc, n, N);
        } else if (mode == 15) t = samp2(TEXPASS, pc, g_pos, n, T[inp].ar);
        else if (mode == 16) t = samp2(TEXPASS, pc, g_pos, n, T[inp].gb);
        if (mode != 0 && mode != 4 && mode != 5 && mode != 10 && mode != 17) {
            t = apply_signed(t, ti.y);
            if ((ti.x & 1) && t.a == 0.0) discard_fragment();
        }
        T[n] = t;
    }
    float4 R[16];
    _Pragma("clang loop unroll(full)")
    for (uint k = 0; k < 16; k++) R[k] = float4(0);
    R[3] = float4(pc.fog_color.rgb, ifog.x); R[4] = id0; R[5] = id1;
    R[8] = T[0]; R[9] = T[1]; R[10] = T[2]; R[11] = T[3];
    float4 o;
    uint ps_flags = K_PS_FLAGS;
    if (!(ps_flags & 1)) {
        /* No combiner program yet: texture 0 modulated by diffuse. */
        o = (stage_prog & 31) ? T[0] * id0 : id0;
    } else {
        R[12].a = (stage_prog & 31) ? T[0].a : 1.0;
        uint rc_control = K_RC_CONTROL;
        uint nst = min(rc_control & 0xFF, 8u); uint fl8 = rc_control >> 8;
        _Pragma("clang loop unroll(full)")
        for (uint s = 0; s < nst; s++) {
            uint icw = K_C_ICW(s), ocw = K_C_OCW(s), aicw = K_A_ICW(s), aocw = K_A_OCW(s);
            if (((ocw | aocw) & 0xFFF) == 0) continue;
            R[1] = pc.cf0[(fl8 & 0x010) ? s : 0]; R[2] = pc.cf1[(fl8 & 0x100) ? s : 0];
            bool mux = (fl8 & 1) ? R[12].a >= 0.5 : (((uint)(R[12].a * 255.0)) & 1) != 0;
            uint b;
            b = icw >> 24; float3 A = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = icw >> 16; float3 B = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = icw >> 8;  float3 C = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = icw;       float3 D = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = aicw >> 24; float aA = map_in((b & 0x10) ? R[b & 15].a : R[b & 15].b, b);
            b = aicw >> 16; float aB = map_in((b & 0x10) ? R[b & 15].a : R[b & 15].b, b);
            b = aicw >> 8;  float aC = map_in((b & 0x10) ? R[b & 15].a : R[b & 15].b, b);
            b = aicw;       float aD = map_in((b & 0x10) ? R[b & 15].a : R[b & 15].b, b);
            uint fl = ocw >> 12, afl = aocw >> 12;
            float3 pab = (fl & 2) ? float3(dot(A, B)) : A * B;
            float3 pcd = (fl & 1) ? float3(dot(C, D)) : C * D;
            float3 sum = (fl & 4) ? (mux ? pcd : pab) : pab + pcd;
            float3 ab = clamp(map_out3(pab, fl & 0x38), -1.0, 1.0);
            float3 cd = clamp(map_out3(pcd, fl & 0x38), -1.0, 1.0);
            float3 ms = clamp(map_out3(sum, fl & 0x38), -1.0, 1.0);
            float apab = aA * aB, apcd = aC * aD;
            float asum = (afl & 4) ? (mux ? apcd : apab) : apab + apcd;
            float aab = clamp(map_out3(float3(apab), afl & 0x38).x, -1.0, 1.0);
            float acd = clamp(map_out3(float3(apcd), afl & 0x38).x, -1.0, 1.0);
            float ams = clamp(map_out3(float3(asum), afl & 0x38).x, -1.0, 1.0);
            uint d;
            d = (ocw >> 4) & 15; if (d) { R[d].rgb = ab; if (fl & 0x80) R[d].a = ab.b; }
            d = ocw & 15;        if (d) { R[d].rgb = cd; if (fl & 0x40) R[d].a = cd.b; }
            d = (ocw >> 8) & 15; if (d) R[d].rgb = ms;
            d = (aocw >> 4) & 15; if (d) R[d].a = aab;
            d = aocw & 15;        if (d) R[d].a = acd;
            d = (aocw >> 8) & 15; if (d) R[d].a = ams;
            R[0] = float4(0);
        }
        uint fin0 = K_FIN0, fin1 = K_FIN1;
        if (fin0 | fin1) {
            uint ff = fin1 & 0xFF; uint b;
            R[1] = pc.fin_c0; R[2] = pc.fin_c1;
            float3 va = (ff & 0x40) ? 1.0 - R[5].rgb : R[5].rgb;
            float3 vb = (ff & 0x20) ? 1.0 - R[12].rgb : R[12].rgb;
            R[14] = float4((ff & 0x80) ? saturate(va + vb) : va + vb, 0);
            b = fin1 >> 24; float3 E = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = fin1 >> 16; float3 F = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            R[15] = float4(E * F, 0);
            b = fin0 >> 24; float3 A = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = fin0 >> 16; float3 B = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = fin0 >> 8;  float3 C = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = fin0;       float3 D = map_in3((b & 0x10) ? R[b & 15].aaa : R[b & 15].rgb, b);
            b = fin1 >> 8;  float G = map_in((b & 0x10) ? R[b & 15].a : R[b & 15].b, b);
            o = float4(D + C * (1.0 - A) + B * A, G);
        } else o = R[12];
    }
    o = saturate(o);
    cov = 0xFFFFFFFFu;
    /* Alpha test. On a multisampled target an inequality test becomes sample
     * coverage across the one-pixel band around its threshold, so cut-out
     * edges -- foliage, fences -- are antialiased; single-sample: the plain test. */
    float a8 = o.a * 255.0, fw = max(fwidth(a8), 1e-3);
    if (ps_flags & 2) {
        uint alpha_func = K_ALPHA_FUNC;
        int v = (int)(a8 + 0.5), r = (int)(pc.alpha_ref & 0xFF); bool ok = true; float e = 0;
        switch (alpha_func) {
        case 0x200: ok = false; break; case 0x201: ok = v < r; e = r - 0.5 - a8; break;
        case 0x202: ok = v == r; break; case 0x203: ok = v <= r; e = r + 0.5 - a8; break;
        case 0x204: ok = v > r; e = a8 - (r + 0.5); break; case 0x205: ok = v != r; break;
        case 0x206: ok = v >= r; e = a8 - (r - 0.5); break; }
        uint ns = get_num_samples();
        bool ineq = alpha_func == 0x201 || alpha_func == 0x203 || alpha_func == 0x204 || alpha_func == 0x206;
        if (ns > 1 && ineq) {
            uint k = (uint)rint(saturate(e / fw + 0.5) * ns);
            if (k == 0) discard_fragment();
            cov = k >= 32 ? 0xFFFFFFFFu : (1u << k) - 1u;
        } else if (!ok) discard_fragment();
    }
    return o;
}

struct PSOut {
    float4 c [[color(0)]];
    uint cov [[sample_mask]];
};

struct PSOutZ {
    float4 c [[color(0)]];
    float dep [[depth(any)]];
    uint cov [[sample_mask]];
};

/* W-buffering (SET_CONTROL0 Z_PERSPECTIVE): the depth buffer holds w,
 * interpolated perspective-correctly (fog.y carries it), in 24-bit fixed
 * point -- linear precision, unlike z/w. Polygon offset is applied here as
 * xemu does. zp0 = offset factor, units, host pixels per guest pixel x/y;
 * zp1 = 1/(zmax+1), zmax, view remap scale (0 = off), knee. Draws after the
 * title read the depth buffer for its haze pass lose MSAA coverage by the
 * fraction y16d_ps hazes their depth, with a 2x2 Bayer spread. */
static float wdepth(constant PSConsts &pc, float4 ipos, float z, thread uint &cov)
{
    z += pc.zp0.y + pc.zp0.x * max(abs(dfdx(z)) * pc.zp0.z, abs(dfdy(z)) * pc.zp0.w);
    z = clamp(z, 0.0, pc.zp1.y);
    if (pc.zp1.z > 0.0) {
        float x = z * pc.zp1.x * pc.zp1.z, k = pc.zp1.w;
        if (x > k && x < 0.98 * pc.zp1.z) {
            float b = 1.0 - exp((k - x) / (1.0 - k));
            uint2 q = uint2(ipos.xy) & 1u;
            float r = (float)(q.x * 2u + (q.x ^ q.y)) * 0.25;
            uint ns = get_num_samples(), kk = (uint)floor((1.0 - b) * ns + r);
            if (kk == 0) discard_fragment();
            if (ns > 1 && kk < ns) cov &= (1u << kk) - 1u;
        }
    }
    return as_type<float>(as_type<uint>(floor(z) * pc.zp1.x) + 1u);
}

#define PS_ARGS \
    constant PSConsts &pc [[buffer(0)]], \
    texture2d<float> T2D0 [[texture(0)]], texture2d<float> T2D1 [[texture(1)]], \
    texture2d<float> T2D2 [[texture(2)]], texture2d<float> T2D3 [[texture(3)]], \
    texturecube<float> TC0 [[texture(4)]], texturecube<float> TC1 [[texture(5)]], \
    texturecube<float> TC2 [[texture(6)]], texturecube<float> TC3 [[texture(7)]], \
    texture2d<float> FBK [[texture(8)]], \
    sampler S0 [[sampler(0)]], sampler S1 [[sampler(1)]], \
    sampler S2 [[sampler(2)]], sampler S3 [[sampler(3)]]

#define SHADE(i, cov) shade(TEXPASS, pc, i.pos, i.d0, i.d1, i.fog, i.t0, i.t1, i.t2, i.t3, cov)

fragment PSOut ps_main(PSIn i [[stage_in]], PS_ARGS)
{
    PSOut o; uint cov;
    o.c = SHADE(i, cov); o.cov = cov;
    return o;
}

fragment PSOut ps_main_flat(PSInFlat i [[stage_in]], PS_ARGS)
{
    PSOut o; uint cov;
    o.c = SHADE(i, cov); o.cov = cov;
    return o;
}

/* The same without a coverage output, for draws that never change it (no
 * alpha test, or a single-sample target). A fragment function that writes
 * [[sample_mask]] is shaded before visibility is known, so on Apple GPUs it
 * forgoes hidden-surface removal and pays for every overdrawn pixel; these
 * keep it. */
struct PSOutNC {
    float4 c [[color(0)]];
};

fragment PSOutNC ps_main_nc(PSIn i [[stage_in]], PS_ARGS)
{
    PSOutNC o; uint cov;
    o.c = SHADE(i, cov);
    return o;
}

fragment PSOutNC ps_main_flat_nc(PSInFlat i [[stage_in]], PS_ARGS)
{
    PSOutNC o; uint cov;
    o.c = SHADE(i, cov);
    return o;
}

/* Measuring only (RECOMP_EXP_FILE): the diffuse colour alone, and that
 * times texture 0, standing in for every draw's shader. */
fragment PSOutNC ps_dbg(PSIn i [[stage_in]])
{
    PSOutNC o;
    o.c = saturate(i.d0);
    return o;
}

fragment PSOutNC ps_dbg_tex(PSIn i [[stage_in]], texture2d<float> T2D0 [[texture(0)]],
                            sampler S0 [[sampler(0)]], constant PSConsts &pc [[buffer(0)]])
{
    PSOutNC o;
    float q = i.t0.w != 0.0 ? i.t0.w : 1.0;
    o.c = saturate(T2D0.sample(S0, i.t0.xy / q * pc.tex_scale[0].xy) * i.d0);
    return o;
}

fragment PSOutZ ps_wdepth(PSIn i [[stage_in]], PS_ARGS)
{
    PSOutZ o; uint cov;
    o.c = SHADE(i, cov);
    o.dep = wdepth(pc, i.pos, i.fog.y, cov);
    o.cov = cov;
    return o;
}

fragment PSOutZ ps_wdepth_flat(PSInFlat i [[stage_in]], PS_ARGS)
{
    PSOutZ o; uint cov;
    o.c = SHADE(i, cov);
    o.dep = wdepth(pc, i.pos, i.fog.y, cov);
    o.cov = cov;
    return o;
}

/* ---------------------------------------------------- present and uploads */

/* Presentation and uploads: a textured rectangle, optionally with the PVIDEO
 * overlay composited the way the display hardware does. */
struct PresentConsts {
    float4 dst_rect; float4 src_uv; float4 src_size;
    float4 ovl_out; float4 ovl_walk; float4 ovl_in; uint4 ovl_flags; float4 force_alpha;
};

struct PO { float4 pos [[position]]; float2 uv; };

vertex PO present_vs(uint id [[vertex_id]], constant PresentConsts &p [[buffer(0)]])
{
    float2 c = float2(id & 1, id >> 1); PO o;
    o.pos = float4(mix(p.dst_rect.x, p.dst_rect.z, c.x), mix(p.dst_rect.y, p.dst_rect.w, c.y), 0, 1);
    o.uv = mix(p.src_uv.xy, p.src_uv.zw, c); return o;
}

fragment float4 present_ps(PO i [[stage_in]], constant PresentConsts &p [[buffer(0)]],
                           texture2d<float> SrcTex [[texture(0)]], texture2d<float> OvlTex [[texture(1)]],
                           sampler LinS [[sampler(0)]], sampler PointS [[sampler(1)]])
{
    if (p.ovl_flags.w) {
        /* Masked upload: only pixels the CPU changed replace what the GPU drew. */
        if (OvlTex.sample(PointS, i.uv).r < 0.5) discard_fragment();
        return SrcTex.sample(PointS, i.uv);
    }
    float4 c = SrcTex.sample(LinS, i.uv);
    if (p.ovl_flags.x) {
        float2 g = i.uv * p.src_size.xy;
        /* On a widened image the movie stays 4:3, centred (ovl_in.z = widening). */
        float2 d = float2(p.ovl_in.w + (g.x - p.ovl_in.w) * p.ovl_in.z, g.y) - p.ovl_out.xy;
        if (all(d >= 0) && all(d < p.ovl_out.zw)) {
            bool show = true;
            if (p.ovl_flags.y) {
                uint k = p.ovl_flags.z;
                float3 key = float3((k >> 16) & 255, (k >> 8) & 255, k & 255) / 255.0;
                float3 fb = SrcTex.read(uint2(floor(g) * p.src_size.zw / p.src_size.xy), 0).rgb;
                show = all(abs(fb - key) < 1.5 / 255.0);
            }
            if (show) c = OvlTex.sample(LinS, (p.ovl_walk.xy + d * p.ovl_walk.zw) / p.ovl_in.xy);
        }
    }
    /* Loading (force_alpha.y > 0, a phase): a turning arc in the bottom-right
     * corner while the title has stopped flipping; .zw is the target's size. */
    if (p.force_alpha.y > 0) {
        float s = p.force_alpha.w / 720.0;
        float2 d = i.pos.xy - (p.force_alpha.zw - 40.0 * s);
        float ring = saturate(2.0 * s - abs(length(d) - 13.0 * s));
        float a = fract(atan2(d.y, d.x) / 6.2831853 - p.force_alpha.y);
        c.rgb = mix(c.rgb, float3(0.91, 0.64, 0.24), ring * smoothstep(0.15, 1.0, a));
    }
    return p.force_alpha.x >= 0 ? float4(c.rgb, p.force_alpha.x) : c;
}

struct ClearConsts { float4 ccol; float4 cz; };

struct PosOnly { float4 pos [[position]]; };

vertex PosOnly clear_vs(uint id [[vertex_id]], constant ClearConsts &cc [[buffer(0)]])
{
    float2 c = float2(id & 1, id >> 1); PosOnly o;
    o.pos = float4(c.x * 2 - 1, 1 - c.y * 2, cc.cz.x, 1); return o;
}

fragment float4 clear_ps(constant ClearConsts &cc [[buffer(0)]]) { return cc.ccol; }

/* A 32-bit colour surface read as LU_IMAGE_Y16: twice as wide, texel 2x the
 * low 16-bit word of pixel x (G:B), 2x+1 the high one (A:R), as R=G=B, A=1
 * (xemu's mapping). MSAA surfaces are read at one sample. */
vertex PosOnly y16_vs(uint id [[vertex_id]])
{
    float2 c = float2((id << 1) & 2, id & 2); PosOnly o;
    o.pos = float4(c * float2(2, -2) + float2(-1, 1), 0, 1); return o;
}

static float4 y16_of(float4 c, uint2 q)
{
    uint4 b = (uint4)rint(saturate(c) * 255.0);
    float y = (float)((q.x & 1u) ? (b.a << 8 | b.r) : (b.g << 8 | b.b)) / 65535.0;
    return float4(y, y, y, 1);
}

fragment float4 y16_ps(float4 p [[position]], texture2d<float> Y16Src [[texture(0)]])
{
    uint2 q = uint2(p.xy);
    return y16_of(Y16Src.read(uint2(q.x >> 1, q.y), 0), q);
}

fragment float4 y16_ps_ms(float4 p [[position]], texture2d_ms<float> Y16Src [[texture(0)]])
{
    uint2 q = uint2(p.xy);
    return y16_of(Y16Src.read(uint2(q.x >> 1, q.y), 0), q);
}

/* The same view of a depth buffer (fog passes read depth this way). Both
 * texels of a guest pixel hold z[23:8]; the read is shifted left by ccol.z
 * host pixels so a building's edge does not pick up sky depth. ccol.xy =
 * nv2a_d3d_set_depth_view_remap (scale s, knee k): below k depth is as
 * stored, above it the band k..1 fills exponentially, so geometry past the
 * original far plane fades into the sky colour. d = 1 (sky) stays 1. */
static float4 y16d_of(float d, constant ClearConsts &cc)
{
    float s = cc.ccol.x, k = cc.ccol.y;
    d = saturate(d);
    if (s > 1.0 && d < 1.0) { float x = d * s; d = x <= k ? x : k + (1.0 - k) * (1.0 - exp((k - x) / (1.0 - k))); }
    float y = (float)((uint)rint(saturate(d) * 16777215.0) >> 8) / 65535.0;
    return float4(y, y, y, 1);
}

fragment float4 y16d_ps(float4 p [[position]], depth2d<float> Y16Z [[texture(0)]],
                        constant ClearConsts &cc [[buffer(0)]])
{
    uint2 q = uint2(p.xy);
    int zx = max(0, (int)floor((q.x + 0.5) * 0.5 - cc.ccol.z));
    return y16d_of(Y16Z.read(uint2(zx, q.y), 0), cc);
}

fragment float4 y16d_ps_ms(float4 p [[position]], depth2d_ms<float> Y16Z [[texture(0)]],
                           constant ClearConsts &cc [[buffer(0)]])
{
    uint2 q = uint2(p.xy);
    int zx = max(0, (int)floor((q.x + 0.5) * 0.5 - cc.ccol.z));
    return y16d_of(Y16Z.read(uint2(zx, q.y), 0), cc);
}
