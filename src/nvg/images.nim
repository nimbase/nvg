## CPU image store and sampling for image-pattern paints.
##
## Images are owned by the `Canvas` registry (`createImageRGBA` and
## friends); pattern paints hold a shared `Image` ref so sampling never
## needs a registry lookup in the inner loop. Pixels are straight
## (non-premultiplied) `RGBA8`: uploads flagged `ifPremultiplied` are
## converted once, and bilinear taps interpolate in premultiplied space
## to avoid dark halos at transparent edges.

import std/math
import ./types

export types

type
  ImageFlag* = enum
    ifRepeatX       ## Tile horizontally instead of clamping.
    ifRepeatY       ## Tile vertically instead of clamping.
    ifFlipY         ## Flip vertically when sampled.
    ifPremultiplied ## Upload data is premultiplied alpha.
    ifNearest       ## Nearest-neighbor instead of bilinear filtering.

  Image* = ref object
    w*, h*: int
    pixels*: seq[uint8]
    flags*: set[ImageFlag]

proc newImage*(w, h: int, flags: set[ImageFlag],
    data: openArray[uint8]): Image =
  ## Build an image, zero-padding short uploads and truncating long ones.
  ## Requires positive dimensions; callers validate first.
  result = Image(w: w, h: h, pixels: newSeq[uint8](w * h * 4),
    flags: flags)
  let n = min(data.len, result.pixels.len)
  for i in 0 ..< n:
    result.pixels[i] = data[i]
  if ifPremultiplied in flags:
    # Convert to straight alpha once, guarding fully transparent texels.
    var i = 0
    while i < result.pixels.len:
      let a = float64(result.pixels[i+3]) / 255.0
      if a > 1e-6:
        result.pixels[i] = uint8(min(255.0,
          float64(result.pixels[i]) / a + 0.5))
        result.pixels[i+1] = uint8(min(255.0,
          float64(result.pixels[i+1]) / a + 0.5))
        result.pixels[i+2] = uint8(min(255.0,
          float64(result.pixels[i+2]) / a + 0.5))
      else:
        result.pixels[i] = 0
        result.pixels[i+1] = 0
        result.pixels[i+2] = 0
      i += 4

proc update*(img: Image, data: openArray[uint8]): bool =
  ## Replace image contents; the size must match exactly.
  if data.len != img.pixels.len: return false
  for i in 0 ..< data.len:
    img.pixels[i] = data[i]
  if ifPremultiplied in img.flags:
    var i = 0
    while i < img.pixels.len:
      let a = float64(img.pixels[i+3]) / 255.0
      if a > 1e-6:
        img.pixels[i] = uint8(min(255.0, float64(img.pixels[i]) / a + 0.5))
        img.pixels[i+1] = uint8(min(255.0,
          float64(img.pixels[i+1]) / a + 0.5))
        img.pixels[i+2] = uint8(min(255.0,
          float64(img.pixels[i+2]) / a + 0.5))
      else:
        img.pixels[i] = 0
        img.pixels[i+1] = 0
        img.pixels[i+2] = 0
      i += 4
  true

proc texel(img: Image, x, y: int): tuple[r, g, b, a: float64] =
  let i = (y * img.w + x) * 4
  (float64(img.pixels[i]) / 255.0, float64(img.pixels[i+1]) / 255.0,
    float64(img.pixels[i+2]) / 255.0, float64(img.pixels[i+3]) / 255.0)

proc wrapIdx(v, n: int, repeat: bool): int =
  if repeat:
    ((v mod n) + n) mod n
  else:
    clamp(v, 0, n - 1)

proc sampleImage*(img: Image, u, v: float64): Color =
  ## Sample normalized `uv` (1.0 = full image extent) honoring the
  ## image wrap/filter/flip flags. A nil image samples transparent.
  if img == nil or img.w <= 0 or img.h <= 0:
    return rgbaf(0, 0, 0, 0)
  var uu = u
  var vv = v
  if ifFlipY in img.flags:
    vv = 1.0 - vv
  if ifNearest in img.flags:
    let xi = wrapIdx(int(floor(uu * float64(img.w))), img.w,
      ifRepeatX in img.flags)
    let yi = wrapIdx(int(floor(vv * float64(img.h))), img.h,
      ifRepeatY in img.flags)
    let t = img.texel(xi, yi)
    rgbaf(t.r, t.g, t.b, t.a)
  else:
    let fx = uu * float64(img.w) - 0.5
    let fy = vv * float64(img.h) - 0.5
    let x0 = int(floor(fx))
    let y0 = int(floor(fy))
    let tx = clamp01(fx - float64(x0))
    let ty = clamp01(fy - float64(y0))
    # Interpolate premultiplied to avoid halos at transparent edges.
    var acc = [0.0, 0.0, 0.0, 0.0]
    for j in 0 .. 1:
      for i in 0 .. 1:
        let t = img.texel(
          wrapIdx(x0 + i, img.w, ifRepeatX in img.flags),
          wrapIdx(y0 + j, img.h, ifRepeatY in img.flags))
        let w = (if i == 0: 1.0 - tx else: tx) *
          (if j == 0: 1.0 - ty else: ty)
        acc[0] += t.r * t.a * w
        acc[1] += t.g * t.a * w
        acc[2] += t.b * t.a * w
        acc[3] += t.a * w
    if acc[3] > 1e-6:
      rgbaf(acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3], acc[3])
    else:
      rgbaf(0, 0, 0, 0)
