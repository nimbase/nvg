## Metal GPU backend (M0-M1): compute-shader fills.
##
## Local-test path only. A `MetalCtx` owns a Shared `MTLBuffer` of
## `w*h` straight RGBA8 bytes in `Surface` layout (row-major, top-down).
## `fillSolid` / `fillLinear` run one MSL compute kernel each over the
## buffer; `readback` copies it to CPU for comparison against the scalar
## oracle. Paints assume an identity map for now (map support later).
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

import ./types

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

type BlendParams* = object
  ## Must match MSL `BlendP` layout: col, op, cov (24 bytes).
  col*: array[4, cfloat]
  op*: cuint
  cov*: cfloat

static:
  doAssert sizeof(LinearParams) == 48
  doAssert sizeof(RadialParams) == 48
  doAssert sizeof(BoxParams) == 64
  doAssert sizeof(BlendParams) == 24

when defined(macosx):
  proc nvgmtl_device_count(): cint {.importc.}
  proc nvgmtl_create(w, h: cint): pointer {.importc.}
  proc nvgmtl_destroy(p: pointer) {.importc.}
  proc nvgmtl_build(p: pointer, slot: cint, src: cstring,
      srclen: cint, name: cstring, namelen: cint): cint {.importc.}
  proc nvgmtl_fill(p: pointer, slot: cint, params: pointer,
      paramslen: cint) {.importc.}
  proc nvgmtl_upload(p: pointer, src: ptr uint8) {.importc.}
  proc nvgmtl_readback(p: pointer, dst: ptr uint8) {.importc.}
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
      nvgmtl_readback(ctx.p, addr result[0])
  else:
    result = @[]

proc upload*(ctx: MetalCtx, pixels: openArray[uint8]) =
  ## Copy straight RGBA8 bytes into the buffer (Surface layout).
  when defined(macosx):
    if pixels.len != ctx.w * ctx.h * 4:
      raise newException(ValueError, "upload size mismatch")
    nvgmtl_upload(ctx.p, unsafeAddr pixels[0])

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
