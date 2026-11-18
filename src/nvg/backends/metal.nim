## Metal GPU backend (M0-M6): compute-shader fills and composites.
##
## Local-test path only. A `MetalCtx` owns a Shared `MTLBuffer` of
## `w*h` straight RGBA8 bytes in `Surface` layout (row-major, top-down).
## Paint/composite kernels run over the buffer; `readback` copies it to
## CPU for comparison against the scalar oracle. Paints assume an
## identity map for now (map support later).
##
## Layout rule for new kernels: MSL follows C++ alignment, so every
## `float4` member sits at a 16-byte offset and every `float2`/`uint2`
## at an 8-byte offset; the Nim mirror struct must place fields at the
## same offsets (the `sizeof` asserts catch size but NOT field drift, so
## keep explicit `_pad` members — see `BoxP`/`PatP`). A misaligned
## `float4` silently reads zeros (M6 lesson).
##
## Environment notes (AMD RX 570, macOS Sonoma), verified by throwaway
## ObjC probes before this file existed:
## - `MTLCreateSystemDefaultDevice` returns nil while
##   `MTLCopyAllDevices` yields the RX 570; the bridge picks device 0.
## - GPU writes to Metal *textures* never land here (render-pass clear,
##   pipeline draws, blit-to-texture, and compute `texture.write` all
##   complete without error yet read back zeros), while compute writes
##   to *buffers* and compute texture *reads* work. M0-M1 therefore
##   target buffers only; the vertex/fragment render-pipeline path is
##   written later and verified on real hardware.
## - TODO: `close` must be called (defer in tests); no `=destroy` hook yet.

when defined(macosx):
  {.compile: "metal_bridge.m".}
  {.passL: "-framework Metal -framework Foundation".}

import ../types
import ../images
import ../paint
import ../surface

type MetalCtx* = ref object
  p: pointer
  w*, h*: int

const
  MSlotSolid* = 0
  MSlotLinear* = 1
  MSlotSolidOver* = 2
  MSlotRadial* = 3
  MSlotBox* = 4
  MSlotBlend* = 5
  MSlotPattern* = 6
  MSlotBlurH* = 7
  MSlotBlurV* = 8
  MSlotPatternBilinear* = 9
  MSlotShade* = 10
  MSlotShadeMulti* = 11
  MSlotUnsharp* = 12
  MSlotMosaic* = 13
  MSlotNoiseMono* = 14
  MSlotNoiseColor* = 15
  MSlotRipple* = 16
  MSlotSwirl* = 17
  MSlotTurb* = 18
  MSlotWarp* = 19
  MSlotMotion* = 20

const solidMsl* = """
#include <metal_stdlib>
using namespace metal;
kernel void fill_solid(device uchar4 *out [[buffer(0)]],
                       constant float4 &col [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float4 c = saturate(col);
  out[gid.y * dims.x + gid.x] = uchar4(c * 255.0 + 0.5);
}
"""

const linearMsl* = """
#include <metal_stdlib>
using namespace metal;
struct LinP { float2 s; float2 e; float4 c0; float4 c1; };
kernel void fill_linear(device uchar4 *out [[buffer(0)]],
                        constant LinP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float2 d = u.e - u.s;
  float len2 = dot(d, d);
  float t = 0.0;
  if (len2 > 1e-12) {
    float2 q = float2(gid) + 0.5 - u.s;
    t = (q.x * d.x + q.y * d.y) / len2;
  }
  float4 c = mix(u.c0, u.c1, clamp(t, 0.0, 1.0));
  out[gid.y * dims.x + gid.x] = uchar4(saturate(c) * 255.0 + 0.5);
}
"""

const solidOverMsl* = """
#include <metal_stdlib>
using namespace metal;
kernel void comp_solid_over(device uchar4 *io [[buffer(0)]],
                            constant float4 &col [[buffer(1)]],
                            constant uint2 &dims [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  uint i = gid.y * dims.x + gid.x;
  float4 d = float4(io[i]) * (1.0 / 255.0);
  float sa = clamp(col.a, 0.0, 1.0);
  float inv = 1.0 - sa;
  float3 rgb = col.rgb * sa + d.rgb * inv;
  float a = sa + d.a * inv;
  io[i] = uchar4(saturate(float4(rgb, a)) * 255.0 + 0.5);
}
"""

const radialMsl* = """
#include <metal_stdlib>
using namespace metal;
struct RadP { float2 c; float2 r; float4 c0; float4 c1; };
kernel void fill_radial(device uchar4 *out [[buffer(0)]],
                        constant RadP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float2 q = float2(gid) + 0.5 - u.c;
  float dist = length(q);
  float f = max(1.0, u.r.y - u.r.x);
  float t = (dist - u.r.x) / f;
  float4 col = mix(u.c0, u.c1, clamp(t, 0.0, 1.0));
  out[gid.y * dims.x + gid.x] = uchar4(saturate(col) * 255.0 + 0.5);
}
"""

const boxMsl* = """
#include <metal_stdlib>
using namespace metal;
struct BoxP { float2 c; float2 e; float2 rf; float2 _pad; float4 c0; float4 c1; };
kernel void fill_box(device uchar4 *out [[buffer(0)]],
                     constant BoxP &u [[buffer(1)]],
                     constant uint2 &dims [[buffer(2)]],
                     uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float2 p = float2(gid) + 0.5 - u.c;
  float2 q = abs(p) - (u.e - u.rf.x);
  float sd = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - u.rf.x;
  float f = max(1.0, u.rf.y);
  float t = (sd + f * 0.5) / f;
  float4 col = mix(u.c0, u.c1, clamp(t, 0.0, 1.0));
  out[gid.y * dims.x + gid.x] = uchar4(saturate(col) * 255.0 + 0.5);
}
"""

type LinearParams* = object
  ## Must match MSL `LinP` layout: s, e, c0, c1 (48 bytes).
  sx*, sy*, ex*, ey*: cfloat
  c0*: array[4, cfloat]
  c1*: array[4, cfloat]

type RadialParams* = object
  ## Must match MSL `RadP` layout: c, r, c0, c1 (48 bytes).
  cx*, cy*, inr*, outr*: cfloat
  c0*: array[4, cfloat]
  c1*: array[4, cfloat]

type BoxParams* = object
  ## Must match MSL `BoxP` layout: c, e, rf, _pad, c0, c1 (64 bytes).
  cx*, cy*, ex*, ey*: cfloat
  radius*, feather*: cfloat
  pad*: array[2, cfloat]
  c0*: array[4, cfloat]
  c1*: array[4, cfloat]

const blendMsl* = """
#include <metal_stdlib>
using namespace metal;
// Op ordinals must match nvg CompOp order: 0 SourceOver, 1 SourceIn,
// 2 SourceOut, 3 Atop, 4 DestinationOver, 5 DestinationIn,
// 6 DestinationOut, 7 DestinationAtop, 8 Lighter, 9 Copy, 10 Xor,
// 11 Multiply, 12 Screen, 13 Overlay, 14 Darken, 15 Lighten,
// 16 ColorDodge, 17 ColorBurn, 18 HardLight, 19 SoftLight,
// 20 Difference, 21 Exclusion, 22 Hue, 23 Saturation, 24 Color,
// 25 Luminosity.
float mblend(uint op, float cs, float cb) {
  switch (op) {
    case 11: return cs * cb;
    case 12: return cs + cb - cs * cb;
    case 13:
      return cb <= 0.5 ? 2.0 * cs * cb
                       : 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb);
    case 14: return min(cs, cb);
    case 15: return max(cs, cb);
    case 16:
      if (cs <= 0.0) return 0.0;
      if (cb >= 1.0) return 1.0;
      return min(1.0, cs / (1.0 - cb));
    case 17:
      if (cs >= 1.0) return 1.0;
      if (cb <= 0.0) return 0.0;
      return 1.0 - min(1.0, (1.0 - cs) / cb);
    case 18:
      return cs <= 0.5 ? 2.0 * cs * cb
                       : 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb);
    case 19: {
      if (cs <= 0.5) return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
      float d = cb <= 0.25 ? ((16.0 * cb - 12.0) * cb + 4.0) * cb
                           : sqrt(cb);
      return cb + (2.0 * cs - 1.0) * (d - cb);
    }
    case 20: return abs(cs - cb);
    default: return cs + cb - 2.0 * cs * cb;
  }
}
float mlum(float3 c) { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; }
float3 mclip(float3 c) {
  float l = mlum(c);
  float n = min(c.r, min(c.g, c.b));
  float x = max(c.r, max(c.g, c.b));
  float3 r = c;
  if (n < 0.0) r = l + ((c - l) * l / (l - n));
  if (x > 1.0) r = l + ((r - l) * (1.0 - l) / (x - l));
  return r;
}
float3 msetlum(float3 c, float l) {
  float d = l - mlum(c);
  return mclip(c + d);
}
float msat(float3 c) {
  return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}
float3 msetsat(float3 c, float s) {
  float vals[3] = {c.r, c.g, c.b};
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  if (mx == mn) return float3(0.0);
  int iMax = c.r == mx ? 0 : (c.g == mx ? 1 : 2);
  int iMin = c.r == mn ? 0 : (c.g == mn ? 1 : 2);
  int iMid = 3 - iMax - iMin;
  float o[3] = {0.0, 0.0, 0.0};
  o[iMax] = s;
  o[iMid] = ((vals[iMid] - vals[iMin]) * s) / (vals[iMax] - vals[iMin]);
  return float3(o[0], o[1], o[2]);
}
struct BlendP { float4 col; uint op; float cov; };
kernel void comp_blend(device uchar4 *io [[buffer(0)]],
                       constant BlendP &u [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  uint i = gid.y * dims.x + gid.x;
  float4 dd = float4(io[i]) * (1.0 / 255.0);
  float3 sr3 = u.col.rgb;
  float sa = clamp(u.col.a, 0.0, 1.0) * clamp(u.cov, 0.0, 1.0);
  if (u.op == 0u) {
    if (sa <= 0.0) return;
    float inv = 1.0 - sa;
    float3 rgb = sr3 * sa + dd.rgb * inv;
    float a = sa + dd.a * inv;
    io[i] = uchar4(saturate(float4(rgb, a)) * 255.0 + 0.5);
    return;
  }
  float3 csr = sr3 * sa;
  float3 cdr = dd.rgb * dd.a;
  float da = dd.a;
  float3 cor;
  float ao;
  switch (u.op) {
    case 1: cor = csr * da; ao = sa * da; break;
    case 2: cor = csr * (1.0 - da); ao = sa * (1.0 - da); break;
    case 3: cor = csr * da + cdr * (1.0 - sa); ao = da; break;
    case 4: cor = csr * (1.0 - da) + cdr; ao = sa + da * (1.0 - sa); break;
    case 5: cor = cdr * sa; ao = da * sa; break;
    case 6: cor = cdr * (1.0 - sa); ao = da * (1.0 - sa); break;
    case 7: cor = csr * (1.0 - da) + cdr * sa; ao = sa; break;
    case 8:
      cor = csr + cdr;
      ao = min(1.0, sa + da);
      break;
    case 9: cor = csr; ao = sa; break;
    case 10:
      cor = csr * (1.0 - da) + cdr * (1.0 - sa);
      ao = sa + da - 2.0 * sa * da;
      break;
    default: {
      float3 br = float3(mblend(u.op, sr3.r, dd.r),
                         mblend(u.op, sr3.g, dd.g),
                         mblend(u.op, sr3.b, dd.b));
      if (u.op >= 22u) {
        float3 sc = sr3;
        float3 dc = dd.rgb;
        if (u.op == 22u) {
          br = msetlum(msetsat(sc, msat(dc)), mlum(dc));
        } else if (u.op == 23u) {
          br = msetlum(msetsat(dc, msat(sc)), mlum(dc));
        } else if (u.op == 24u) {
          br = msetlum(sc, mlum(dc));
        } else {
          br = msetlum(dc, mlum(sc));
        }
      }
      cor = (1.0 - da) * sa * sr3 + (1.0 - sa) * da * dd.rgb + sa * da * br;
      ao = sa + da * (1.0 - sa);
      break;
    }
  }
  uchar4 res;
  if (ao <= 1e-6) {
    res = uchar4(0, 0, 0, 0);
  } else {
    res = uchar4(saturate(float4(cor / ao, ao)) * 255.0 + 0.5);
  }
  io[i] = res;
}
"""

const shadeMsl* = """
#include <metal_stdlib>
using namespace metal;
// Generalized coverage-driven composite: evaluates any paint kind at
// pixel centers (identity map) and composites under any CompOp with
// per-pixel coverage from buffer(3), mirroring scalar fillPolys. kind:
// 0 solid, 1 linear, 2 radial, 3 box, 4 pattern (flags bit 3 selects
// bilinear). Payload `w` packs each paint's params as documented on
// `shadeOver`. Blend helpers mirror `blendMsl` (kept in sync by the
// M4/M11 tests).
struct ShadeU {
  uint kind;
  uint op;
  float alpha;
  float _p;
  float4 w0; float4 w1; float4 w2; float4 w3;
};
float4 sheval(uint2 gid, ShadeU u,
              texture2d<float, access::read> img) {
  float2 pc = float2(gid) + 0.5;
  switch (u.kind) {
    case 0: return u.w0;
    case 1: {
      float2 d = u.w0.zw - u.w0.xy;
      float len2 = dot(d, d);
      float t = 0.0;
      if (len2 > 1e-12) t = dot(pc - u.w0.xy, d) / len2;
      return mix(u.w1, u.w2, clamp(t, 0.0, 1.0));
    }
    case 2: {
      float dist = length(pc - u.w0.xy);
      float f = max(1.0, u.w0.w - u.w0.z);
      float t = (dist - u.w0.z) / f;
      return mix(u.w1, u.w2, clamp(t, 0.0, 1.0));
    }
    case 3: {
      float2 p = pc - u.w0.xy;
      float2 q = abs(p) - (u.w0.zw - u.w1.x);
      float sd = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - u.w1.x;
      float f = max(1.0, u.w1.y);
      float t = (sd + f * 0.5) / f;
      return mix(u.w2, u.w3, clamp(t, 0.0, 1.0));
    }
    default: {
      float2 q = pc - u.w0.xy;
      float ca = cos(u.w2.x);
      float sa = sin(u.w2.x);
      float uu = (ca * q.x + sa * q.y) / u.w0.z;
      float vv = (-sa * q.x + ca * q.y) / u.w0.w;
      uint flags = uint(u.w3.z);
      if ((flags & 4u) != 0u) vv = 1.0 - vv;
      int W = int(u.w3.x);
      int H = int(u.w3.y);
      float4 t;
      if ((flags & 8u) != 0u) {
        float fx = uu * float(W) - 0.5;
        float fy = vv * float(H) - 0.5;
        int x0 = int(floor(fx));
        int y0 = int(floor(fy));
        float tx = clamp(fx - float(x0), 0.0, 1.0);
        float ty = clamp(fy - float(y0), 0.0, 1.0);
        float4 acc = float4(0.0);
        for (int j = 0; j <= 1; j++) {
          for (int i = 0; i <= 1; i++) {
            int xi = x0 + i;
            int yi = y0 + j;
            if ((flags & 1u) != 0u) {
              xi = ((xi % W) + W) % W;
            } else {
              xi = clamp(xi, 0, W - 1);
            }
            if ((flags & 2u) != 0u) {
              yi = ((yi % H) + H) % H;
            } else {
              yi = clamp(yi, 0, H - 1);
            }
            float4 s = img.read(uint2(uint(xi), uint(yi)));
            float w = (i == 0 ? 1.0 - tx : tx) *
                      (j == 0 ? 1.0 - ty : ty);
            acc += float4(s.rgb * s.a, s.a) * w;
          }
        }
        if (acc.a > 1e-6) t = float4(acc.rgb / acc.a, acc.a);
        else t = float4(0.0);
      } else {
        int xi = int(floor(uu * float(W)));
        int yi = int(floor(vv * float(H)));
        if ((flags & 1u) != 0u) {
          xi = ((xi % W) + W) % W;
        } else {
          xi = clamp(xi, 0, W - 1);
        }
        if ((flags & 2u) != 0u) {
          yi = ((yi % H) + H) % H;
        } else {
          yi = clamp(yi, 0, H - 1);
        }
        t = img.read(uint2(uint(xi), uint(yi)));
      }
      return float4(t.rgb * u.w1.rgb, t.a * u.w1.a);
    }
  }
}
float mblend(uint op, float cs, float cb) {
  switch (op) {
    case 11: return cs * cb;
    case 12: return cs + cb - cs * cb;
    case 13:
      return cb <= 0.5 ? 2.0 * cs * cb
                       : 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb);
    case 14: return min(cs, cb);
    case 15: return max(cs, cb);
    case 16:
      if (cs <= 0.0) return 0.0;
      if (cb >= 1.0) return 1.0;
      return min(1.0, cs / (1.0 - cb));
    case 17:
      if (cs >= 1.0) return 1.0;
      if (cb <= 0.0) return 0.0;
      return 1.0 - min(1.0, (1.0 - cs) / cb);
    case 18:
      return cs <= 0.5 ? 2.0 * cs * cb
                       : 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb);
    case 19: {
      if (cs <= 0.5) return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
      float d = cb <= 0.25 ? ((16.0 * cb - 12.0) * cb + 4.0) * cb
                           : sqrt(cb);
      return cb + (2.0 * cs - 1.0) * (d - cb);
    }
    case 20: return abs(cs - cb);
    default: return cs + cb - 2.0 * cs * cb;
  }
}
float mlum(float3 c) { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; }
float3 mclip(float3 c) {
  float l = mlum(c);
  float n = min(c.r, min(c.g, c.b));
  float x = max(c.r, max(c.g, c.b));
  float3 r = c;
  if (n < 0.0) r = l + ((c - l) * l / (l - n));
  if (x > 1.0) r = l + ((r - l) * (1.0 - l) / (x - l));
  return r;
}
float3 msetlum(float3 c, float l) {
  float d = l - mlum(c);
  return mclip(c + d);
}
float msat(float3 c) {
  return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}
float3 msetsat(float3 c, float s) {
  float vals[3] = {c.r, c.g, c.b};
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  if (mx == mn) return float3(0.0);
  int iMax = c.r == mx ? 0 : (c.g == mx ? 1 : 2);
  int iMin = c.r == mn ? 0 : (c.g == mn ? 1 : 2);
  int iMid = 3 - iMax - iMin;
  float o[3] = {0.0, 0.0, 0.0};
  o[iMax] = s;
  o[iMid] = ((vals[iMid] - vals[iMin]) * s) / (vals[iMax] - vals[iMin]);
  return float3(o[0], o[1], o[2]);
}
kernel void shade(device uchar4 *io [[buffer(0)]],
                  constant ShadeU &u [[buffer(1)]],
                  constant uint2 &dims [[buffer(2)]],
                  device float *cov [[buffer(3)]],
                  texture2d<float, access::read> img [[texture(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  uint i = gid.y * dims.x + gid.x;
  float c = cov[i];
  if (c <= 0.0) return;
  float4 src = sheval(gid, u, img);
  float4 dd = float4(io[i]) * (1.0 / 255.0);
  float sa = clamp(src.a * u.alpha, 0.0, 1.0) * clamp(c, 0.0, 1.0);
  if (u.op == 0u) {
    if (sa <= 0.0) return;
    float inv = 1.0 - sa;
    float3 rgb = src.rgb * sa + dd.rgb * inv;
    float a = sa + dd.a * inv;
    io[i] = uchar4(saturate(float4(rgb, a)) * 255.0 + 0.5);
    return;
  }
  float3 sr3 = src.rgb;
  float3 csr = sr3 * sa;
  float3 cdr = dd.rgb * dd.a;
  float da = dd.a;
  float3 cor;
  float ao;
  switch (u.op) {
    case 1: cor = csr * da; ao = sa * da; break;
    case 2: cor = csr * (1.0 - da); ao = sa * (1.0 - da); break;
    case 3: cor = csr * da + cdr * (1.0 - sa); ao = da; break;
    case 4: cor = csr * (1.0 - da) + cdr; ao = sa + da * (1.0 - sa); break;
    case 5: cor = cdr * sa; ao = da * sa; break;
    case 6: cor = cdr * (1.0 - sa); ao = da * (1.0 - sa); break;
    case 7: cor = csr * (1.0 - da) + cdr * sa; ao = sa; break;
    case 8:
      cor = csr + cdr;
      ao = min(1.0, sa + da);
      break;
    case 9: cor = csr; ao = sa; break;
    case 10:
      cor = csr * (1.0 - da) + cdr * (1.0 - sa);
      ao = sa + da - 2.0 * sa * da;
      break;
    default: {
      float3 br = float3(mblend(u.op, sr3.r, dd.r),
                         mblend(u.op, sr3.g, dd.g),
                         mblend(u.op, sr3.b, dd.b));
      if (u.op >= 22u) {
        float3 sc = sr3;
        float3 dc = dd.rgb;
        if (u.op == 22u) {
          br = msetlum(msetsat(sc, msat(dc)), mlum(dc));
        } else if (u.op == 23u) {
          br = msetlum(msetsat(dc, msat(sc)), mlum(dc));
        } else if (u.op == 24u) {
          br = msetlum(sc, mlum(dc));
        } else {
          br = msetlum(dc, mlum(sc));
        }
      }
      cor = (1.0 - da) * sa * sr3 + (1.0 - sa) * da * dd.rgb + sa * da * br;
      ao = sa + da * (1.0 - sa);
      break;
    }
  }
  uchar4 res;
  if (ao <= 1e-6) {
    res = uchar4(0, 0, 0, 0);
  } else {
    res = uchar4(saturate(float4(cor / ao, ao)) * 255.0 + 0.5);
  }
  io[i] = res;
}
"""

const
  ShadeSolid* = 0
  ShadeLinear* = 1
  ShadeRadial* = 2
  ShadeBox* = 3
  ShadePattern* = 4

const MaxShadeStops* = 8

const shadeMultiMsl* = """
#include <metal_stdlib>
using namespace metal;
// Multi-stop coverage-driven source-over for linear (kind 1), radial
// (kind 2) and box (kind 3) gradients with up to 8 normalized stops.
// Stop lookup mirrors scalar `sampleStops` (last-wins duplicates,
// degenerate end segments); geometry matches `shade_over`.
struct MultiP {
  uint kind;
  float alpha;
  float2 g0;
  float2 g1;
  float2 g2;
  uint nstops;
  float pos[8];
  float _mpad[3];
  float4 col[8];
};
float4 msample_stops(float t, constant MultiP &u) {
  int n = int(u.nstops);
  if (n <= 0) return float4(0.0);
  if (n == 1) return u.col[0];
  float tc = clamp(t, 0.0, 1.0);
  if (tc < u.pos[0]) {
    int k = 0;
    while (k + 1 < n && u.pos[k + 1] == u.pos[0]) k++;
    return u.col[k];
  }
  if (tc >= u.pos[n - 1]) {
    int j = n - 1;
    while (j > 0 && u.pos[j - 1] == u.pos[n - 1]) j--;
    if (j == 0) return u.col[n - 1];
    j--;
    float uu = (tc - u.pos[j]) / (u.pos[n - 1] - u.pos[j]);
    return mix(u.col[j], u.col[n - 1], clamp(uu, 0.0, 1.0));
  }
  int L = 0;
  for (int i = 0; i < n; i++) {
    if (u.pos[i] <= tc) L = i;
    else break;
  }
  int R = L + 1;
  float uu = (tc - u.pos[L]) / (u.pos[R] - u.pos[L]);
  return mix(u.col[L], u.col[R], clamp(uu, 0.0, 1.0));
}
kernel void shade_multi(device uchar4 *io [[buffer(0)]],
                        constant MultiP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        device float *cov [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  uint i = gid.y * dims.x + gid.x;
  float c = cov[i];
  if (c <= 0.0) return;
  float2 pc = float2(gid) + 0.5;
  float t = 0.0;
  switch (u.kind) {
    case 1: {
      float2 d = u.g1 - u.g0;
      float len2 = dot(d, d);
      if (len2 > 1e-12) t = dot(pc - u.g0, d) / len2;
      break;
    }
    case 2: {
      float dist = length(pc - u.g0);
      float f = max(1.0, u.g1.y - u.g1.x);
      t = (dist - u.g1.x) / f;
      break;
    }
    default: {
      float2 p = pc - u.g0;
      float2 q = abs(p) - (u.g1 - u.g2.x);
      float sd = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - u.g2.x;
      float f = max(1.0, u.g2.y);
      t = (sd + f * 0.5) / f;
      break;
    }
  }
  float4 src = msample_stops(t, u);
  float4 dd = float4(io[i]) * (1.0 / 255.0);
  float sa = clamp(src.a * u.alpha, 0.0, 1.0) * clamp(c, 0.0, 1.0);
  if (sa <= 0.0) return;
  float inv = 1.0 - sa;
  float3 rgb = src.rgb * sa + dd.rgb * inv;
  float a = sa + dd.a * inv;
  io[i] = uchar4(saturate(float4(rgb, a)) * 255.0 + 0.5);
}
"""

type BlendParams* = object
  ## Must match MSL `BlendP` layout: col, op, cov (24 bytes).
  col*: array[4, cfloat]
  op*: cuint
  cov*: cfloat

type ShadeJob* = object
  ## Must match MSL `ShadeU` layout: kind, op, alpha, pad, w0..w3
  ## (80 bytes). Payload packing per kind is documented on `shadeOver`.
  kind*: cuint
  op*: cuint
  alpha*: cfloat
  pad*: cfloat
  w*: array[16, cfloat]

type MultiParams* = object
  ## Must match MSL `MultiP` layout: kind, alpha, g0..g2, nstops,
  ## pos, _mpad, col (208 bytes).
  kind*: cuint
  alpha*: cfloat
  g0*: array[2, cfloat]
  g1*: array[2, cfloat]
  g2*: array[2, cfloat]
  nstops*: cuint
  pos*: array[8, cfloat]
  mpad*: array[3, cfloat]
  col*: array[8, array[4, cfloat]]

const patternMsl* = """
#include <metal_stdlib>
using namespace metal;
// Nearest-filter pattern fill mirroring scalar `sample` for pkPattern
// with ifNearest at pixel centers, identity map. texel fetch via
// texture.read needs no sampler. flags bit 0 = repeatX, 1 = repeatY,
// 2 = flipY.
struct PatP {
  float2 o; float2 e; float4 tint; float ang; float _p0; uint2 img;
  uint flags;
};
kernel void fill_pattern_nearest(device uchar4 *out [[buffer(0)]],
                                 constant PatP &u [[buffer(1)]],
                                 constant uint2 &dims [[buffer(2)]],
                                 texture2d<float, access::read> img [[texture(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float2 q = float2(gid) + 0.5 - u.o;
  float ca = cos(u.ang);
  float sa = sin(u.ang);
  float uu = (ca * q.x + sa * q.y) / u.e.x;
  float vv = (-sa * q.x + ca * q.y) / u.e.y;
  if ((u.flags & 4u) != 0u) vv = 1.0 - vv;
  int W = int(u.img.x);
  int H = int(u.img.y);
  int xi = int(floor(uu * float(W)));
  int yi = int(floor(vv * float(H)));
  if ((u.flags & 1u) != 0u) {
    xi = ((xi % W) + W) % W;
  } else {
    xi = clamp(xi, 0, W - 1);
  }
  if ((u.flags & 2u) != 0u) {
    yi = ((yi % H) + H) % H;
  } else {
    yi = clamp(yi, 0, H - 1);
  }
  float4 t = img.read(uint2(uint(xi), uint(yi)));
  float4 c = float4(t.rgb * u.tint.rgb, t.a * u.tint.a);
  out[gid.y * dims.x + gid.x] = uchar4(saturate(c) * 255.0 + 0.5);
}
"""

type PatternParams* = object
  ## Must match MSL `PatP` layout: o, e, tint (16-aligned), ang, pad,
  ## img, flags (52 bytes used; MSL pads the struct to 64).
  ox*, oy*, ex*, ey*: cfloat
  tint*: array[4, cfloat]
  angle*: cfloat
  pad*: cfloat
  imgW*, imgH*: cuint
  flags*: cuint

const blurMsl* = """
#include <metal_stdlib>
using namespace metal;
// Separable box blur in premultiplied space, mirroring scalar
// `boxBlur`: taps accumulate rgb*a and a as uints, color divides by
// total alpha (transparent when zero), alpha averages over the
// window. Integer round-half-up throughout, so output is
// byte-identical to the CPU. Horizontal pass reads pixels and writes
// the aux buffer as bytes; vertical pass reads aux and writes pixels.
// (GPUs keep direct taps here; the O(pixels) running sums live on the
// CPU side where a single thread owns each row. Shared-memory tiling
// or downsampling would be the next step for very large radii.)
struct BlurP { int radius; };
kernel void blur_h(device uchar4 *src [[buffer(0)]],
                   constant BlurP &u [[buffer(1)]],
                   constant uint2 &dims [[buffer(2)]],
                   device uchar4 *tmp [[buffer(3)]],
                   uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  int r = u.radius;
  uint3 accC = uint3(0);
  uint accA = 0u;
  for (int k = -r; k <= r; k++) {
    int xx = clamp(int(gid.x) + k, 0, int(dims.x) - 1);
    uchar4 t = src[gid.y * dims.x + uint(xx)];
    accC += uint3(t.r, t.g, t.b) * uint(t.a);
    accA += uint(t.a);
  }
  uint n = uint(2 * r + 1);
  uint3 c = accA > 0u ? (accC + accA / 2u) / accA : uint3(0);
  uint a = (accA + n / 2u) / n;
  tmp[gid.y * dims.x + gid.x] = uchar4(uchar3(c), uchar(a));
}
kernel void blur_v(device uchar4 *dst [[buffer(0)]],
                   constant BlurP &u [[buffer(1)]],
                   constant uint2 &dims [[buffer(2)]],
                   device uchar4 *tmp [[buffer(3)]],
                   uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  int r = u.radius;
  uint3 accC = uint3(0);
  uint accA = 0u;
  for (int k = -r; k <= r; k++) {
    int yy = clamp(int(gid.y) + k, 0, int(dims.y) - 1);
    uchar4 t = tmp[uint(yy) * dims.x + gid.x];
    accC += uint3(t.r, t.g, t.b) * uint(t.a);
    accA += uint(t.a);
  }
  uint n = uint(2 * r + 1);
  uint3 c = accA > 0u ? (accC + accA / 2u) / accA : uint3(0);
  uint a = (accA + n / 2u) / n;
  dst[gid.y * dims.x + gid.x] = uchar4(uchar3(c), uchar(a));
}
"""

type BlurParams* = object
  ## Must match MSL `BlurP` layout (4 bytes).
  radius*: cint

const fxMsl* = """
#include <metal_stdlib>
using namespace metal;
// Unsharp mask mirroring scalar `unsharpMask`: premultiplied
// `original + amount * (original - blurred)`, divided back out by the
// original alpha. `orig` (buffer 4) is the pre-blur copy the caller
// stashed via `nvgmtl_copy`; `io` holds the blurred image and receives
// the result. CPU uses float64 while this uses float32, so the pair
// agrees within 2 LSB.
struct SharpP { float amount; };
kernel void unsharp(device uchar4 *io [[buffer(0)]],
                    constant SharpP &u [[buffer(1)]],
                    constant uint2 &dims [[buffer(2)]],
                    device uchar4 *orig [[buffer(4)]],
                    uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  uint i = gid.y * dims.x + gid.x;
  uchar4 o = orig[i];
  uchar4 b = io[i];
  if (o.a == 0u) {
    io[i] = uchar4(0, 0, 0, 0);
    return;
  }
  float oa = float(o.a);
  float3 op = float3(o.r, o.g, o.b) * oa;
  float3 bp = float3(b.r, b.g, b.b) * float(b.a);
  float3 sp = op + u.amount * (op - bp);
  float3 c = sp / oa;
  io[i] = uchar4(uchar3(saturate(c * (1.0 / 255.0)) * 255.0 + 0.5),
                 o.a);
}
// Mosaic/pixelation mirroring scalar `mosaic`: each cell averages its
// available pixels premultiplied (partial cells at the edges), integer
// round-half-up throughout, so output is byte-identical to the CPU.
// Reads pixels, writes aux; the caller copies aux back to pixels.
struct MosP { int cell; };
kernel void mosaic_avg(device uchar4 *src [[buffer(0)]],
                       constant MosP &u [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       device uchar4 *tmp [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  int c = u.cell;
  int ox = (int(gid.x) / c) * c;
  int oy = (int(gid.y) / c) * c;
  uint3 accC = uint3(0);
  uint accA = 0u;
  uint n = 0u;
  for (int y = oy; y < oy + c && y < int(dims.y); y++) {
    for (int x = ox; x < ox + c && x < int(dims.x); x++) {
      uchar4 t = src[uint(y) * dims.x + uint(x)];
      accC += uint3(t.r, t.g, t.b) * uint(t.a);
      accA += uint(t.a);
      n++;
    }
  }
  uint3 rgb = accA > 0u ? (accC + accA / 2u) / accA : uint3(0);
  uint a = (accA + n / 2u) / n;
  tmp[gid.y * dims.x + gid.x] =
      uchar4(uchar3(rgb), uchar(a));
}
"""

type MosParams* = object
  ## Must match MSL `MosP` layout (4 bytes).
  cell*: cint

type SharpParams* = object
  ## Must match MSL `SharpP` layout (4 bytes).
  amount*: cfloat

const grainMsl* = """
#include <metal_stdlib>
using namespace metal;
// Deterministic lattice hash mirroring scalar `hashPixel`: uint32
// wraparound throughout (MSL unsigned overflow and signed->unsigned
// conversion both wrap mod 2^32, matching Nim's bit-preserving
// cast), so both backends compute the same bits. Stateless and
// position-only: each thread owns its pixel.
uint hashPixel(int xi, int yi, uint seed, uint salt) {
  uint h = uint(xi) * 374761393u + uint(yi) * 668265263u +
      seed * 1442695041u + salt * 2246822519u;
  h = (h ^ (h >> 13)) * 1274126177u;
  return h ^ (h >> 16);
}
// Uniform map mirroring scalar `noiseDelta`: top 16 hash bits,
// multiply-shift into [-a, +a] (product fits 32 bits, no wrap).
int noiseMap(uint h, int a) {
  return int(((h >> 16) * uint(2 * a + 1)) >> 16) - a;
}
struct NoiseP { int amp; uint seed; int mode; };
kernel void noise_mono(device uchar4 *io [[buffer(0)]],
                       constant NoiseP &u [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  int a = u.amp;
  int d;
  if (u.mode == 0) {
    d = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed, 0u), a);
  } else {
    int u0 = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed, 0u), a) + a;
    int u1 = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed, 1u), a) + a;
    int u2 = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed, 2u), a) + a;
    d = int(uint(u0 + u1 + u2 + 1) / 3u) - a;
  }
  uint i = gid.y * dims.x + gid.x;
  uchar4 p = io[i];
  int3 v = int3(p.r, p.g, p.b) + d;
  io[i] = uchar4(uchar3(clamp(v, 0, 255)), p.a);
}
kernel void noise_color(device uchar4 *io [[buffer(0)]],
                        constant NoiseP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  int a = u.amp;
  int d[3];
  for (int c = 0; c < 3; c++) {
    if (u.mode == 0) {
      d[c] = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed,
                                uint(c)), a);
    } else {
      int u0 = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed,
                                  uint(c * 3)), a) + a;
      int u1 = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed,
                                  uint(c * 3 + 1)), a) + a;
      int u2 = noiseMap(hashPixel(int(gid.x), int(gid.y), u.seed,
                                  uint(c * 3 + 2)), a) + a;
      d[c] = int(uint(u0 + u1 + u2 + 1) / 3u) - a;
    }
  }
  uint i = gid.y * dims.x + gid.x;
  uchar4 p = io[i];
  int3 v = int3(p.r, p.g, p.b) + int3(d[0], d[1], d[2]);
  io[i] = uchar4(uchar3(clamp(v, 0, 255)), p.a);
}
""";

type NoiseParams* = object
  ## Must match MSL `NoiseP` layout (12 bytes).
  amp*: cint
  seed*: cuint
  mode*: cint

const warpMsl* = """
#include <metal_stdlib>
using namespace metal;
// Bilinear sampler mirroring scalar `sampleBilinearClamp`:
// straight-space taps with clamp edges and the premultiplied
// transparent guard. CPU uses float64, this uses float32, so warp
// pairs agree within 1 LSB.
float4 bilinClamp(device uchar4 *src, uint2 dims, float fx, float fy) {
  int x0 = int(floor(fx));
  int y0 = int(floor(fy));
  float tx = clamp(fx - float(x0), 0.0, 1.0);
  float ty = clamp(fy - float(y0), 0.0, 1.0);
  float4 acc = float4(0.0);
  for (int j = 0; j <= 1; j++) {
    for (int i = 0; i <= 1; i++) {
      int xi = clamp(x0 + i, 0, int(dims.x) - 1);
      int yi = clamp(y0 + j, 0, int(dims.y) - 1);
      float4 t = float4(src[uint(yi) * dims.x + uint(xi)]) *
          (1.0 / 255.0);
      float w = (i == 0 ? 1.0 - tx : tx) *
                (j == 0 ? 1.0 - ty : ty);
      acc += float4(t.rgb * t.a, t.a) * w;
    }
  }
  if (acc.a > 1e-6) return float4(acc.rgb / acc.a, acc.a);
  return float4(0.0);
}
struct RippleP { float amp; float period; float phase; float _p; };
kernel void warp_ripple(device uchar4 *src [[buffer(0)]],
                        constant RippleP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        device uchar4 *tmp [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float k = 2.0 * 3.14159265 / u.period;
  float sx = float(gid.x) + u.amp * sin(k * float(gid.y) + u.phase);
  float sy = float(gid.y) + u.amp * sin(k * float(gid.x) + u.phase);
  float4 c = bilinClamp(src, dims, sx, sy);
  tmp[gid.y * dims.x + gid.x] = uchar4(saturate(c) * 255.0 + 0.5);
}
struct SwirlP { float cx; float cy; float radius; float angle; };
kernel void warp_swirl(device uchar4 *src [[buffer(0)]],
                       constant SwirlP &u [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       device uchar4 *tmp [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float dx = float(gid.x) - u.cx;
  float dy = float(gid.y) - u.cy;
  float d = sqrt(dx * dx + dy * dy);
  uint i = gid.y * dims.x + gid.x;
  if (d >= u.radius) {
    tmp[i] = src[i];
    return;
  }
  float t = u.angle * (1.0 - d / u.radius);
  float c = cos(t);
  float sn = sin(t);
  float4 col = bilinClamp(src, dims, u.cx + dx * c + dy * sn,
                          u.cy - dx * sn + dy * c);
  tmp[i] = uchar4(saturate(col) * 255.0 + 0.5);
}
// Hashed value noise mirroring scalar `valueNoise`/`fbm`: lattice
// bits are exactly representable in float32 (u24 / 2^24), but fBm
// summation runs float32 here vs float64 on the CPU, so turbulence
// pairs agree within 2 LSB.
uint thash(int xi, int yi, uint seed, uint salt) {
  uint h = uint(xi) * 374761393u + uint(yi) * 668265263u +
      seed * 1442695041u + salt * 2246822519u;
  h = (h ^ (h >> 13)) * 1274126177u;
  return h ^ (h >> 16);
}
float latVal(int xi, int yi, uint seed) {
  return float(thash(xi, yi, seed, 0u) >> 8) / 16777216.0;
}
float vfade(float t) {
  return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}
float vnoise(float x, float y, uint seed) {
  int xi = int(floor(x));
  int yi = int(floor(y));
  float xf = x - float(xi);
  float yf = y - float(yi);
  float u = vfade(xf);
  float v = vfade(yf);
  float a = latVal(xi, yi, seed);
  float b = latVal(xi + 1, yi, seed);
  float c = latVal(xi, yi + 1, seed);
  float d = latVal(xi + 1, yi + 1, seed);
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}
float fbm(float x, float y, float freq, int oct, uint seed) {
  float amp = 1.0;
  float f = freq;
  float sum = 0.0;
  float norm = 0.0;
  for (int o = 0; o < oct; o++) {
    sum += amp * vnoise(x * f, y * f, seed);
    norm += amp;
    amp *= 0.5;
    f *= 2.0;
  }
  return sum / norm;
}
struct TurbP { float freq; int oct; uint seed; int _p; };
kernel void field_turb(device uchar4 *io [[buffer(0)]],
                       constant TurbP &u [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float n = fbm(float(gid.x), float(gid.y), u.freq, u.oct, u.seed);
  uchar v = uchar(saturate(n) * 255.0 + 0.5);
  uint i = gid.y * dims.x + gid.x;
  uchar4 p = io[i];
  io[i] = uchar4(v, v, v, p.a);
}
struct WarpP { float freq; float amp; int oct; uint seed; };
kernel void warp_domain(device uchar4 *src [[buffer(0)]],
                        constant WarpP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        device uchar4 *tmp [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float nx = fbm(float(gid.x), float(gid.y), u.freq, u.oct, u.seed) -
      0.5;
  float ny = fbm(float(gid.x), float(gid.y), u.freq, u.oct,
                 u.seed ^ 0x9E3779B9u) - 0.5;
  float4 c = bilinClamp(src, dims,
      float(gid.x) + nx * 2.0 * u.amp,
      float(gid.y) + ny * 2.0 * u.amp);
  tmp[gid.y * dims.x + gid.x] = uchar4(saturate(c) * 255.0 + 0.5);
}
// Directional blur mirroring scalar `motionBlur`: `taps` bilinear
// samples along the segment, premultiplied average with the
// transparent guard. Degrees in, full 360 circle, same modulo
// normalization as the CPU (any value works). float32 math, so the
// pair agrees within 1 LSB.
struct MotionP { float degrees; float length; int taps; int _p; };
kernel void motion_blur(device uchar4 *src [[buffer(0)]],
                        constant MotionP &u [[buffer(1)]],
                        constant uint2 &dims [[buffer(2)]],
                        device uchar4 *tmp [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float th = u.degrees * 3.14159265 / 180.0;
  float dx = cos(th);
  float dy = sin(th);
  float step = u.length / float(u.taps - 1);
  float mid = float(u.taps - 1) * 0.5;
  float n = float(u.taps);
  float3 accC = float3(0.0);
  float accA = 0.0;
  for (int i = 0; i < u.taps; i++) {
    float t = (float(i) - mid) * step;
    float4 c = bilinClamp(src, dims, float(gid.x) + dx * t,
                          float(gid.y) + dy * t);
    accC += c.rgb * c.a;
    accA += c.a;
  }
  float4 o;
  if (accA > 1e-6) o = float4(accC / accA, accA / n);
  else o = float4(0.0);
  tmp[gid.y * dims.x + gid.x] = uchar4(saturate(o) * 255.0 + 0.5);
}
""";

type RippleParams* = object
  ## Must match MSL `RippleP` layout (16 bytes).
  amp*: cfloat
  period*: cfloat
  phase*: cfloat
  pad*: cfloat

type SwirlParams* = object
  ## Must match MSL `SwirlP` layout (16 bytes).
  cx*: cfloat
  cy*: cfloat
  radius*: cfloat
  angle*: cfloat

type TurbParams* = object
  ## Must match MSL `TurbP` layout (16 bytes).
  freq*: cfloat
  oct*: cint
  seed*: cuint
  pad*: cint

type WarpParams* = object
  ## Must match MSL `WarpP` layout (16 bytes).
  freq*: cfloat
  amp*: cfloat
  oct*: cint
  seed*: cuint

type MotionParams* = object
  ## Must match MSL `MotionP` layout (16 bytes).
  degrees*: cfloat
  length*: cfloat
  taps*: cint
  pad*: cint

const patternBilinearMsl* = """
#include <metal_stdlib>
using namespace metal;
// Bilinear pattern fill mirroring scalar `sampleImage`: premultiplied
// accumulation with the transparent guard, then tint. Same `PatP`
// params as the nearest kernel; requires a non-nearest image.
struct PatP {
  float2 o; float2 e; float4 tint; float ang; float _p0; uint2 img;
  uint flags;
};
kernel void fill_pattern_bilinear(device uchar4 *out [[buffer(0)]],
                                  constant PatP &u [[buffer(1)]],
                                  constant uint2 &dims [[buffer(2)]],
                                  texture2d<float, access::read> img [[texture(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= dims.x || gid.y >= dims.y) return;
  float2 q = float2(gid) + 0.5 - u.o;
  float ca = cos(u.ang);
  float sa = sin(u.ang);
  float uu = (ca * q.x + sa * q.y) / u.e.x;
  float vv = (-sa * q.x + ca * q.y) / u.e.y;
  if ((u.flags & 4u) != 0u) vv = 1.0 - vv;
  int W = int(u.img.x);
  int H = int(u.img.y);
  float fx = uu * float(W) - 0.5;
  float fy = vv * float(H) - 0.5;
  int x0 = int(floor(fx));
  int y0 = int(floor(fy));
  float tx = clamp(fx - float(x0), 0.0, 1.0);
  float ty = clamp(fy - float(y0), 0.0, 1.0);
  float4 acc = float4(0.0);
  for (int j = 0; j <= 1; j++) {
    for (int i = 0; i <= 1; i++) {
      int xi = x0 + i;
      int yi = y0 + j;
      if ((u.flags & 1u) != 0u) {
        xi = ((xi % W) + W) % W;
      } else {
        xi = clamp(xi, 0, W - 1);
      }
      if ((u.flags & 2u) != 0u) {
        yi = ((yi % H) + H) % H;
      } else {
        yi = clamp(yi, 0, H - 1);
      }
      float4 t = img.read(uint2(uint(xi), uint(yi)));
      float w = (i == 0 ? 1.0 - tx : tx) * (j == 0 ? 1.0 - ty : ty);
      acc += float4(t.rgb * t.a, t.a) * w;
    }
  }
  float4 c;
  if (acc.a > 1e-6) {
    c = float4(acc.rgb / acc.a, acc.a);
  } else {
    c = float4(0.0);
  }
  c = float4(c.rgb * u.tint.rgb, c.a * u.tint.a);
  out[gid.y * dims.x + gid.x] = uchar4(saturate(c) * 255.0 + 0.5);
}
"""

static:
  doAssert sizeof(LinearParams) == 48
  doAssert sizeof(RadialParams) == 48
  doAssert sizeof(BoxParams) == 64
  doAssert sizeof(BlendParams) == 24
  doAssert sizeof(ShadeJob) == 80
  doAssert sizeof(MultiParams) == 208
  doAssert sizeof(PatternParams) == 52
  doAssert sizeof(BlurParams) == 4
  doAssert sizeof(MosParams) == 4
  doAssert sizeof(SharpParams) == 4
  doAssert sizeof(NoiseParams) == 12
  doAssert sizeof(RippleParams) == 16
  doAssert sizeof(SwirlParams) == 16
  doAssert sizeof(TurbParams) == 16
  doAssert sizeof(WarpParams) == 16
  doAssert sizeof(MotionParams) == 16

when defined(macosx):
  proc nvgmtl_device_count(): cint {.importc.}
  proc nvgmtl_create(w, h: cint): pointer {.importc.}
  proc nvgmtl_destroy(p: pointer) {.importc.}
  proc nvgmtl_build(p: pointer, slot: cint, src: cstring,
      srclen: cint, name: cstring, namelen: cint): cint {.importc.}
  proc nvgmtl_fill(p: pointer, slot: cint, params: pointer,
      paramslen: cint) {.importc.}
  proc nvgmtl_upload(p: pointer, slot: cint,
      src: ptr uint8) {.importc.}
  proc nvgmtl_copy(p: pointer, dstSlot, srcSlot: cint) {.importc.}
  proc nvgmtl_pattern(p: pointer, px: ptr uint8, w,
      h: cint): cint {.importc.}
  proc nvgmtl_readback(p: pointer, slot: cint,
      dst: ptr uint8) {.importc.}
  proc nvgmtl_device_name(p: pointer, dst: cstring,
      cap: cint): cint {.importc.}

proc mtlAvailable*(): bool =
  ## True when at least one Metal device enumerates (macOS only).
  when defined(macosx):
    nvgmtl_device_count() > 0
  else:
    false

proc buildSlot(ctx: MetalCtx, slot: int, src, name: string) =
  when defined(macosx):
    let rc = nvgmtl_build(ctx.p, cint(slot), src.cstring,
      cint(src.len), name.cstring, cint(name.len))
    if rc != 0:
      raise newException(IOError,
        "Metal pipeline build failed (" & name & "): " & $rc)

proc newMetalCtx*(w, h: int): MetalCtx =
  ## Create a context plus the solid/linear pipelines. Raises on failure.
  when defined(macosx):
    if w <= 0 or h <= 0:
      raise newException(ValueError, "MetalCtx needs positive size")
    let p = nvgmtl_create(cint(w), cint(h))
    if p == nil:
      raise newException(IOError, "no Metal device")
    result = MetalCtx(p: p, w: w, h: h)
    try:
      result.buildSlot(MSlotSolid, solidMsl, "fill_solid")
      result.buildSlot(MSlotLinear, linearMsl, "fill_linear")
      result.buildSlot(MSlotSolidOver, solidOverMsl, "comp_solid_over")
      result.buildSlot(MSlotRadial, radialMsl, "fill_radial")
      result.buildSlot(MSlotBox, boxMsl, "fill_box")
      result.buildSlot(MSlotBlend, blendMsl, "comp_blend")
      result.buildSlot(MSlotShade, shadeMsl, "shade")
      result.buildSlot(MSlotShadeMulti, shadeMultiMsl, "shade_multi")
      result.buildSlot(MSlotPattern, patternMsl, "fill_pattern_nearest")
      result.buildSlot(MSlotBlurH, blurMsl, "blur_h")
      result.buildSlot(MSlotBlurV, blurMsl, "blur_v")
      result.buildSlot(MSlotPatternBilinear, patternBilinearMsl,
        "fill_pattern_bilinear")
      result.buildSlot(MSlotUnsharp, fxMsl, "unsharp")
      result.buildSlot(MSlotMosaic, fxMsl, "mosaic_avg")
      result.buildSlot(MSlotNoiseMono, grainMsl, "noise_mono")
      result.buildSlot(MSlotNoiseColor, grainMsl, "noise_color")
      result.buildSlot(MSlotRipple, warpMsl, "warp_ripple")
      result.buildSlot(MSlotSwirl, warpMsl, "warp_swirl")
      result.buildSlot(MSlotTurb, warpMsl, "field_turb")
      result.buildSlot(MSlotWarp, warpMsl, "warp_domain")
      result.buildSlot(MSlotMotion, warpMsl, "motion_blur")
    except IOError:
      nvgmtl_destroy(p)
      result.p = nil
      raise
  else:
    raise newException(IOError, "Metal backend needs macOS")

proc deviceName*(ctx: MetalCtx): string =
  when defined(macosx):
    var buf = newString(256)
    let n = nvgmtl_device_name(ctx.p, buf.cstring, 256)
    if n <= 0:
      return ""
    buf.setLen(n)
    buf
  else:
    ""

proc fillSolid*(ctx: MetalCtx, r, g, b, a: float64) =
  ## Fill the buffer with a straight color. Colors are float64 at the
  ## API boundary like the rest of nvg; the kernel sees float32, so M0
  ## asserts byte-identity only on exactly representable values
  ## (0.0, 0.5, 1.0); general tolerance policy arrives with blending.
  when defined(macosx):
    var col = [cfloat(r), cfloat(g), cfloat(b), cfloat(a)]
    nvgmtl_fill(ctx.p, cint(MSlotSolid), addr col[0], 16)

proc fillLinear*(ctx: MetalCtx, sx, sy, ex, ey: float64, c0,
    c1: Color) =
  ## Linear 2-stop fill mirroring scalar `sample` for basic two-stop
  ## lists at pixel centers, identity map. float32 kernel math means
  ## the test allows 1 LSB (see t_metal).
  when defined(macosx):
    var u = LinearParams(sx: cfloat(sx), sy: cfloat(sy),
      ex: cfloat(ex), ey: cfloat(ey),
      c0: [cfloat(c0.r), cfloat(c0.g), cfloat(c0.b), cfloat(c0.a)],
      c1: [cfloat(c1.r), cfloat(c1.g), cfloat(c1.b), cfloat(c1.a)])
    nvgmtl_fill(ctx.p, cint(MSlotLinear), addr u, cint(sizeof(u)))

proc readback*(ctx: MetalCtx): seq[uint8] =
  when defined(macosx):
    result = newSeq[uint8](ctx.w * ctx.h * 4)
    if result.len > 0:
      nvgmtl_readback(ctx.p, 0, addr result[0])
  else:
    result = @[]

proc upload*(ctx: MetalCtx, pixels: openArray[uint8]) =
  ## Copy straight RGBA8 bytes into the pixel buffer (Surface layout).
  when defined(macosx):
    if pixels.len != ctx.w * ctx.h * 4:
      raise newException(ValueError, "upload size mismatch")
    nvgmtl_upload(ctx.p, 0, unsafeAddr pixels[0])

proc uploadAux*(ctx: MetalCtx, cov: openArray[float32]) =
  ## Copy per-pixel float32 coverage into the aux buffer.
  when defined(macosx):
    if cov.len != ctx.w * ctx.h:
      raise newException(ValueError, "aux upload size mismatch")
    nvgmtl_upload(ctx.p, 1, cast[ptr uint8](unsafeAddr cov[0]))

proc shadeOver*(ctx: MetalCtx, kind: int, op: CompOp, alpha: float64,
    w: array[16, cfloat]) =
  ## Coverage-driven composite for any paint kind under any `CompOp`
  ## (see `shadeMsl`). Payload `w` packs the paint params: solid:
  ## w0 = color; linear: w0.xy = s, w0.zw = e, w1 = c0, w2 = c1;
  ## radial: w0.xy = c, w0.zw = (inr, outr), w1 = c0, w2 = c1; box:
  ## w0.xy = c, w0.zw = (ex, ey), w1.xy = (radius, feather), w2 = c0,
  ## w3 = c1; pattern: w0.xy = o, w0.zw = (ex, ey), w1 = tint,
  ## w2.x = angle, w3 = (imgW, imgH, flags) with flags bit 3
  ## selecting bilinear. Op ordinal passes through like `compBlend`.
  when defined(macosx):
    var u = ShadeJob(kind: cuint(kind), op: cuint(ord(op)),
      alpha: cfloat(alpha), pad: cfloat(0), w: w)
    nvgmtl_fill(ctx.p, cint(MSlotShade), addr u, cint(sizeof(u)))

proc shadeMulti*(ctx: MetalCtx, kind: int, alpha: float64,
    g0, g1, g2: array[2, float64], stops: openArray[GradientStop]) =
  ## Multi-stop shade for linear (1), radial (2) and box (3) paints
  ## (see `shadeMultiMsl`). Geometry like `shadeOver`; `stops` are the
  ## normalized constructor lists, capped at `MaxShadeStops`.
  when defined(macosx):
    var u = MultiParams(kind: cuint(kind), alpha: cfloat(alpha),
      g0: [cfloat(g0[0]), cfloat(g0[1])],
      g1: [cfloat(g1[0]), cfloat(g1[1])],
      g2: [cfloat(g2[0]), cfloat(g2[1])],
      nstops: cuint(stops.len))
    for i in 0 ..< stops.len:
      u.pos[i] = cfloat(stops[i].pos)
      u.col[i] = [cfloat(stops[i].color.r), cfloat(stops[i].color.g),
        cfloat(stops[i].color.b), cfloat(stops[i].color.a)]
    nvgmtl_fill(ctx.p, cint(MSlotShadeMulti), addr u, cint(sizeof(u)))

proc setPattern*(ctx: MetalCtx, img: Image) =
  ## Upload `img` pixels as the pattern texture.
  when defined(macosx):
    if img == nil or img.w <= 0 or img.h <= 0:
      raise newException(ValueError, "pattern image needs size")
    if img.pixels.len != img.w * img.h * 4:
      raise newException(ValueError, "pattern pixels size mismatch")
    let rc = nvgmtl_pattern(ctx.p, unsafeAddr img.pixels[0],
      cint(img.w), cint(img.h))
    if rc != 0:
      raise newException(IOError, "pattern upload failed: " & $rc)

proc fillPatternNearest*(ctx: MetalCtx, ox, oy, ex, ey,
    angle: float64, tint: Color, img: Image) =
  ## Nearest pattern fill mirroring scalar `sample` at pixel centers,
  ## identity map. Requires `setPattern(img)` first; `img` supplies
  ## size and flags.
  when defined(macosx):
    if ifNearest notin img.flags:
      raise newException(ValueError, "nearest kernel needs ifNearest")
    if abs(ex) < 1e-12 or abs(ey) < 1e-12:
      raise newException(ValueError, "pattern extent needs size")
    var flags = 0u32
    if ifRepeatX in img.flags: flags = flags or 1u32
    if ifRepeatY in img.flags: flags = flags or 2u32
    if ifFlipY in img.flags: flags = flags or 4u32
    var u = PatternParams(ox: cfloat(ox), oy: cfloat(oy),
      ex: cfloat(ex), ey: cfloat(ey),
      tint: [cfloat(tint.r), cfloat(tint.g), cfloat(tint.b),
        cfloat(tint.a)],
      angle: cfloat(angle), pad: cfloat(0),
      imgW: cuint(img.w), imgH: cuint(img.h), flags: cuint(flags))
    nvgmtl_fill(ctx.p, cint(MSlotPattern), addr u, cint(sizeof(u)))

proc fillPatternBilinear*(ctx: MetalCtx, ox, oy, ex, ey,
    angle: float64, tint: Color, img: Image) =
  ## Bilinear pattern fill mirroring scalar `sampleImage` at pixel
  ## centers, identity map. Requires `setPattern(img)` first; `img`
  ## supplies size and flags and must not set ifNearest.
  when defined(macosx):
    if ifNearest in img.flags:
      raise newException(ValueError, "bilinear kernel needs filtering")
    if abs(ex) < 1e-12 or abs(ey) < 1e-12:
      raise newException(ValueError, "pattern extent needs size")
    var flags = 0u32
    if ifRepeatX in img.flags: flags = flags or 1u32
    if ifRepeatY in img.flags: flags = flags or 2u32
    if ifFlipY in img.flags: flags = flags or 4u32
    var u = PatternParams(ox: cfloat(ox), oy: cfloat(oy),
      ex: cfloat(ex), ey: cfloat(ey),
      tint: [cfloat(tint.r), cfloat(tint.g), cfloat(tint.b),
        cfloat(tint.a)],
      angle: cfloat(angle), pad: cfloat(0),
      imgW: cuint(img.w), imgH: cuint(img.h), flags: cuint(flags))
    nvgmtl_fill(ctx.p, cint(MSlotPatternBilinear), addr u,
      cint(sizeof(u)))

proc boxBlur*(ctx: MetalCtx, radius: int) =
  ## Separable box blur mirroring scalar `boxBlur`: horizontal pass
  ## into aux, vertical pass back into pixels. Integer math, so
  ## byte-identical to the CPU. Non-positive radii are a no-op.
  when defined(macosx):
    if radius <= 0: return
    var u = BlurParams(radius: cint(radius))
    nvgmtl_fill(ctx.p, cint(MSlotBlurH), addr u, cint(sizeof(u)))
    nvgmtl_fill(ctx.p, cint(MSlotBlurV), addr u, cint(sizeof(u)))

proc gaussianBlur*(ctx: MetalCtx, sigma: float64, boxes = 3) =
  ## Gaussian-like blur mirroring scalar `gaussianBlur`: the same
  ## `boxWidthsForSigma` widths as repeated box passes.
  when defined(macosx):
    for w in boxWidthsForSigma(sigma, boxes):
      ctx.boxBlur((w - 1) div 2)

proc unsharpMask*(ctx: MetalCtx, radius: int, amount: float64) =
  ## Unsharp mask mirroring scalar `unsharpMask`: stashes the original
  ## in spare slot 2, runs the box blur, then combines. Float32 math,
  ## so the pair agrees within 2 LSB. Non-positive radius or amount
  ## is a no-op.
  when defined(macosx):
    if radius <= 0 or amount <= 0.0: return
    nvgmtl_copy(ctx.p, 2, 0)
    ctx.boxBlur(radius)
    var u = SharpParams(amount: cfloat(amount))
    nvgmtl_fill(ctx.p, cint(MSlotUnsharp), addr u, cint(sizeof(u)))

proc mosaic*(ctx: MetalCtx, cell: int) =
  ## Mosaic mirroring scalar `mosaic`: averages into aux, then copies
  ## back to pixels. Integer math, so byte-identical to the CPU.
  ## Cells of size 1 or less are a no-op.
  when defined(macosx):
    if cell <= 1: return
    var u = MosParams(cell: cint(cell))
    nvgmtl_fill(ctx.p, cint(MSlotMosaic), addr u, cint(sizeof(u)))
    nvgmtl_copy(ctx.p, 0, 1)

proc monoNoise*(ctx: MetalCtx, amount: float64, seed: uint32 = 0,
    kind: NoiseKind = nkUniform) =
  ## Monochrome grain mirroring scalar `monoNoise`: per-pixel integer
  ## delta from the lattice hash, same channel shift. Integer math,
  ## so byte-identical to the CPU. Non-positive `amount` is a no-op.
  when defined(macosx):
    let a = noiseAmp(amount)
    if a <= 0: return
    let mode = if kind == nkUniform: 0 else: 1
    var u = NoiseParams(amp: cint(a), seed: cuint(seed),
      mode: cint(mode))
    nvgmtl_fill(ctx.p, cint(MSlotNoiseMono), addr u, cint(sizeof(u)))

proc colorNoise*(ctx: MetalCtx, amount: float64, seed: uint32 = 0,
    kind: NoiseKind = nkUniform) =
  ## Chromatic grain mirroring scalar `colorNoise`: independent hash
  ## streams per channel. Integer math, so byte-identical to the CPU.
  ## Non-positive `amount` is a no-op.
  when defined(macosx):
    let a = noiseAmp(amount)
    if a <= 0: return
    let mode = if kind == nkUniform: 0 else: 1
    var u = NoiseParams(amp: cint(a), seed: cuint(seed),
      mode: cint(mode))
    nvgmtl_fill(ctx.p, cint(MSlotNoiseColor), addr u, cint(sizeof(u)))

proc ripple*(ctx: MetalCtx, amp, period: float64, phase = 0.0) =
  ## Sine displacement mirroring scalar `ripple`: the kernel reads
  ## pixels and writes aux, then the caller copies aux back. float32
  ## trig and sampling, so the pair agrees within 1 LSB.
  ## Non-positive `amp` or `period` is a no-op.
  when defined(macosx):
    if amp <= 0.0 or period <= 0.0: return
    var u = RippleParams(amp: cfloat(amp), period: cfloat(period),
      phase: cfloat(phase), pad: 0)
    nvgmtl_fill(ctx.p, cint(MSlotRipple), addr u, cint(sizeof(u)))
    nvgmtl_copy(ctx.p, 0, 1)

proc swirl*(ctx: MetalCtx, cx, cy, radius, angle: float64) =
  ## Rotation warp mirroring scalar `swirl`: reads pixels, writes
  ## aux, copies back. float32 math, so the pair agrees within
  ## 1 LSB. Zero `angle` or non-positive `radius` is a no-op.
  when defined(macosx):
    if angle == 0.0 or radius <= 0.0: return
    var u = SwirlParams(cx: cfloat(cx), cy: cfloat(cy),
      radius: cfloat(radius), angle: cfloat(angle))
    nvgmtl_fill(ctx.p, cint(MSlotSwirl), addr u, cint(sizeof(u)))
    nvgmtl_copy(ctx.p, 0, 1)

proc turbulence*(ctx: MetalCtx, scale: float64, octaves = 4,
    seed: uint32 = 0) =
  ## fBm field mirroring scalar `turbulence`: in-place RGB write,
  ## alpha preserved. float32 fBm summation, so the pair agrees
  ## within 2 LSB. Non-positive `scale` is a no-op.
  when defined(macosx):
    if scale <= 0.0: return
    var u = TurbParams(freq: cfloat(1.0 / scale),
      oct: cint(clamp(octaves, 1, 8)), seed: cuint(seed), pad: 0)
    nvgmtl_fill(ctx.p, cint(MSlotTurb), addr u, cint(sizeof(u)))

proc domainWarp*(ctx: MetalCtx, scale, warpAmp: float64,
    octaves = 4, seed: uint32 = 0) =
  ## Turbulent displacement mirroring scalar `domainWarp`: reads
  ## pixels, writes aux, copies back. float32 math, so the pair
  ## agrees within 2 LSB. Non-positive `scale`/`warpAmp` is a no-op.
  when defined(macosx):
    if scale <= 0.0 or warpAmp <= 0.0: return
    var u = WarpParams(freq: cfloat(1.0 / scale),
      amp: cfloat(warpAmp), oct: cint(clamp(octaves, 1, 8)),
      seed: cuint(seed))
    nvgmtl_fill(ctx.p, cint(MSlotWarp), addr u, cint(sizeof(u)))
    nvgmtl_copy(ctx.p, 0, 1)

proc motionBlur*(ctx: MetalCtx, directionDeg, length: float64,
    taps = 9) =
  ## Directional blur mirroring scalar `motionBlur`: reads pixels,
  ## writes aux, copies back. Degrees in, full 360 circle. float32
  ## math, so the pair agrees within 1 LSB. Non-positive `length`
  ## or `taps < 2` is a no-op.
  when defined(macosx):
    if length <= 0.0 or taps < 2: return
    var u = MotionParams(degrees: cfloat(directionDeg),
      length: cfloat(length), taps: cint(taps), pad: 0)
    nvgmtl_fill(ctx.p, cint(MSlotMotion), addr u, cint(sizeof(u)))
    nvgmtl_copy(ctx.p, 0, 1)

proc compBlend*(ctx: MetalCtx, op: CompOp, r, g, b, a,
    cov: float64) =
  ## Composite a straight color onto the buffer under any `CompOp`,
  ## mirroring scalar `blendPixel`. `cov` scales the source alpha like
  ## the rasterizer coverage mask. Ordinal is passed through, so new
  ## appended ops work without bridge changes.
  when defined(macosx):
    var u = BlendParams(
      col: [cfloat(r), cfloat(g), cfloat(b), cfloat(a)],
      op: cuint(ord(op)), cov: cfloat(cov))
    nvgmtl_fill(ctx.p, cint(MSlotBlend), addr u, cint(sizeof(u)))

proc compSolidOver*(ctx: MetalCtx, r, g, b, a: float64) =
  ## Source-over composite of a straight color onto the buffer content,
  ## mirroring scalar `blendPixel` (coverage 1). Each thread owns its
  ## pixel, so the in-place read-modify-write needs no ordering.
  when defined(macosx):
    var col = [cfloat(r), cfloat(g), cfloat(b), cfloat(a)]
    nvgmtl_fill(ctx.p, cint(MSlotSolidOver), addr col[0], 16)

proc fillRadial*(ctx: MetalCtx, cx, cy, inr, outr: float64, c0,
    c1: Color) =
  ## Radial 2-stop fill mirroring scalar `sample` at pixel centers,
  ## identity map. 1 LSB allowance like `fillLinear`.
  when defined(macosx):
    var u = RadialParams(cx: cfloat(cx), cy: cfloat(cy),
      inr: cfloat(inr), outr: cfloat(outr),
      c0: [cfloat(c0.r), cfloat(c0.g), cfloat(c0.b), cfloat(c0.a)],
      c1: [cfloat(c1.r), cfloat(c1.g), cfloat(c1.b), cfloat(c1.a)])
    nvgmtl_fill(ctx.p, cint(MSlotRadial), addr u, cint(sizeof(u)))

proc fillBox*(ctx: MetalCtx, cx, cy, ex, ey, radius,
    feather: float64, c0, c1: Color) =
  ## Box 2-stop fill mirroring scalar `sample` at pixel centers,
  ## identity map. 1 LSB allowance like `fillLinear`.
  when defined(macosx):
    var u = BoxParams(cx: cfloat(cx), cy: cfloat(cy),
      ex: cfloat(ex), ey: cfloat(ey), radius: cfloat(radius),
      feather: cfloat(feather), pad: [cfloat(0), cfloat(0)],
      c0: [cfloat(c0.r), cfloat(c0.g), cfloat(c0.b), cfloat(c0.a)],
      c1: [cfloat(c1.r), cfloat(c1.g), cfloat(c1.b), cfloat(c1.a)])
    nvgmtl_fill(ctx.p, cint(MSlotBox), addr u, cint(sizeof(u)))

proc close*(ctx: MetalCtx) =
  when defined(macosx):
    if ctx.p != nil:
      nvgmtl_destroy(ctx.p)
      ctx.p = nil
