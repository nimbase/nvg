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

static:
  doAssert sizeof(LinearParams) == 48
  doAssert sizeof(RadialParams) == 48
  doAssert sizeof(BoxParams) == 64

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
