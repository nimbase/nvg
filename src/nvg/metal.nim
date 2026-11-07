## Metal GPU backend (M0 spike): compute-shader solid fill.
##
## Local-test path only. A `MetalCtx` owns a Shared `MTLBuffer` of
## `w*h` straight RGBA8 bytes in `Surface` layout (row-major, top-down).
## `fillSolid` runs one MSL compute kernel over the buffer; `readback`
## copies it to CPU for comparison against the scalar oracle.
##
## Environment notes (AMD RX 570, macOS Sonoma), verified by throwaway
## ObjC probes before this file existed:
## - `MTLCreateSystemDefaultDevice` returns nil while
##   `MTLCopyAllDevices` yields the RX 570; the bridge picks device 0.
## - GPU writes to Metal *textures* never land here (render-pass clear,
##   pipeline draws, blit-to-texture, and compute `texture.write` all
##   complete without error yet read back zeros), while compute writes
##   to *buffers* and compute texture *reads* work. M0 therefore targets
##   buffers only; the vertex/fragment render-pipeline path is written
##   later and verified on real hardware.
## - TODO: `close` must be called (defer in tests); no `=destroy` hook yet.

when defined(macosx):
  {.compile: "metal_bridge.m".}
  {.passL: "-framework Metal -framework Foundation".}

type MetalCtx* = ref object
  p: pointer
  w*, h*: int

const solidMsl* = """
#include <metal_stdlib>
using namespace metal;
kernel void fill_solid(device uchar4 *out [[buffer(0)]],
                       constant float4 &col [[buffer(1)]],
                       constant uint2 &dims [[buffer(2)]],
                       uint id [[thread_position_in_grid]]) {
  uint n = dims.x * dims.y;
  if (id >= n) return;
  float4 c = saturate(col);
  out[id] = uchar4(c * 255.0 + 0.5);
}
"""

when defined(macosx):
  proc nvgmtl_device_count(): cint {.importc.}
  proc nvgmtl_create(w, h: cint): pointer {.importc.}
  proc nvgmtl_destroy(p: pointer) {.importc.}
  proc nvgmtl_build_solid(p: pointer, src: cstring,
      len: cint): cint {.importc.}
  proc nvgmtl_fill_solid(p: pointer, r, g, b, a: cfloat) {.importc.}
  proc nvgmtl_readback(p: pointer, dst: ptr uint8) {.importc.}
  proc nvgmtl_device_name(p: pointer, dst: cstring,
      cap: cint): cint {.importc.}

proc mtlAvailable*(): bool =
  ## True when at least one Metal device enumerates (macOS only).
  when defined(macosx):
    nvgmtl_device_count() > 0
  else:
    false

proc newMetalCtx*(w, h: int): MetalCtx =
  ## Create a context plus the solid-fill pipeline. Raises on failure.
  when defined(macosx):
    if w <= 0 or h <= 0:
      raise newException(ValueError, "MetalCtx needs positive size")
    let p = nvgmtl_create(cint(w), cint(h))
    if p == nil:
      raise newException(IOError, "no Metal device")
    let rc = nvgmtl_build_solid(p, solidMsl.cstring, cint(solidMsl.len))
    if rc != 0:
      nvgmtl_destroy(p)
      raise newException(IOError,
        "Metal solid pipeline build failed: " & $rc)
    MetalCtx(p: p, w: w, h: h)
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
  ## API boundary like the rest of nvg; the kernel sees float32, so
  ## M0 asserts byte-identity only on exactly representable values
  ## (0.0, 0.5, 1.0); general tolerance policy arrives with blending.
  when defined(macosx):
    nvgmtl_fill_solid(ctx.p, cfloat(r), cfloat(g), cfloat(b), cfloat(a))

proc readback*(ctx: MetalCtx): seq[uint8] =
  when defined(macosx):
    result = newSeq[uint8](ctx.w * ctx.h * 4)
    if result.len > 0:
      nvgmtl_readback(ctx.p, addr result[0])
  else:
    result = @[]

proc close*(ctx: MetalCtx) =
  when defined(macosx):
    if ctx.p != nil:
      nvgmtl_destroy(ctx.p)
      ctx.p = nil
