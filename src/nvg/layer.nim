## Mask and layer compositing primitives.
##
## Offscreen helpers only — no scene graph or layer tree. Callers render
## content into a scratch `Surface`, shape it with mask combines, and
## composite back. All math is straight (non-premultiplied) RGBA8 to match
## `surface.blendPixel`; masks live in the alpha channel (luminance masks
## convert with Rec.601 luma). These primitives never alter default
## `fill`/`stroke` output.

import ./types
import ./surface

export types
export surface

type
  MaskOp* = enum
    mAdd        ## Union of coverage (`max`).
    mSubtract   ## Cut `b` out of `a` (`a*(1-b)`).
    mIntersect  ## Overlap (`min`).

proc newLayer*(w, h: int): Surface =
  ## Transparent scratch surface for offscreen rendering.
  newSurface(w, h)

proc maskFromAlpha*(src: Surface): Surface =
  ## White mask with `src` alpha in its alpha channel.
  result = newSurface(src.w, src.h)
  for i in 0 ..< src.w * src.h:
    result.pixels[i * 4] = 255
    result.pixels[i * 4 + 1] = 255
    result.pixels[i * 4 + 2] = 255
    result.pixels[i * 4 + 3] = src.pixels[i * 4 + 3]

proc maskFromLuminance*(src: Surface): Surface =
  ## White mask with Rec.601 luma (`0.299R+0.587G+0.114B`, straight
  ## channels scaled by alpha so transparent pixels mask nothing) in
  ## its alpha channel.
  result = newSurface(src.w, src.h)
  for i in 0 ..< src.w * src.h:
    let r = float64(src.pixels[i * 4]) / 255.0
    let g = float64(src.pixels[i * 4 + 1]) / 255.0
    let b = float64(src.pixels[i * 4 + 2]) / 255.0
    let a = float64(src.pixels[i * 4 + 3]) / 255.0
    let lum = (0.299 * r + 0.587 * g + 0.114 * b) * a
    result.pixels[i * 4] = 255
    result.pixels[i * 4 + 1] = 255
    result.pixels[i * 4 + 2] = 255
    result.pixels[i * 4 + 3] = uint8(clamp01(lum) * 255.0 + 0.5)

proc maskCombine*(a, b: Surface, op: MaskOp): Surface =
  ## Combine alpha channels of same-size `a`, `b` (result is white with
  ## the combined alpha). Sizes must match; mismatches return a copy of
  ## `a` (documented no-crash rule).
  result = newSurface(a.w, a.h)
  if a.w != b.w or a.h != b.h:
    for i in 0 ..< a.pixels.len:
      result.pixels[i] = a.pixels[i]
    return
  for i in 0 ..< a.w * a.h:
    let aa = float64(a.pixels[i * 4 + 3]) / 255.0
    let ba = float64(b.pixels[i * 4 + 3]) / 255.0
    let m = case op
      of mAdd: max(aa, ba)
      of mSubtract: aa * (1.0 - ba)
      of mIntersect: min(aa, ba)
    result.pixels[i * 4] = 255
    result.pixels[i * 4 + 1] = 255
    result.pixels[i * 4 + 2] = 255
    result.pixels[i * 4 + 3] = uint8(clamp01(m) * 255.0 + 0.5)

proc maskInvert*(m: Surface): Surface =
  ## Complement of the alpha channel (white stays white).
  result = newSurface(m.w, m.h)
  for i in 0 ..< m.w * m.h:
    result.pixels[i * 4] = 255
    result.pixels[i * 4 + 1] = 255
    result.pixels[i * 4 + 2] = 255
    result.pixels[i * 4 + 3] = 255 - m.pixels[i * 4 + 3]

proc blitMasked*(dst, src, mask: Surface, dx, dy: int,
    op = coSourceOver) =
  ## Composite `src` onto `dst` at offset (`dx`, `dy`), scaling each
  ## source alpha by the mask alpha (mask sampled at the source pixel,
  ## out-of-bounds mask reads 0). Sizes may differ; out-of-bounds dst
  ## writes are skipped via `blendPixel`.
  for y in 0 ..< src.h:
    for x in 0 ..< src.w:
      let si = (y * src.w + x) * 4
      var ma = 0.0
      if x >= 0 and y >= 0 and x < mask.w and y < mask.h:
        ma = float64(mask.pixels[(y * mask.w + x) * 4 + 3]) / 255.0
      if ma <= 0.0: continue
      let sa = float64(src.pixels[si + 3]) / 255.0 * ma
      if sa <= 0.0: continue
      dst.blendPixel(dx + x, dy + y, rgbaf(
        float64(src.pixels[si]) / 255.0,
        float64(src.pixels[si + 1]) / 255.0,
        float64(src.pixels[si + 2]) / 255.0, sa), 1.0, op)

proc compositeOver*(dst, layer: Surface, dx, dy: int,
    op = coSourceOver) =
  ## Composite the whole `layer` onto `dst` at (`dx`, `dy`) under `op`.
  for y in 0 ..< layer.h:
    for x in 0 ..< layer.w:
      let li = (y * layer.w + x) * 4
      let la = float64(layer.pixels[li + 3]) / 255.0
      if la <= 0.0: continue
      dst.blendPixel(dx + x, dy + y, rgbaf(
        float64(layer.pixels[li]) / 255.0,
        float64(layer.pixels[li + 1]) / 255.0,
        float64(layer.pixels[li + 2]) / 255.0, la), 1.0, op)
