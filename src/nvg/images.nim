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
    mips*: seq[Image]
      ## Box-filtered halves (level 1 = half size, ..., 1x1 last),
      ## built at upload in premultiplied space. `withMip` (see
      ## `paint`) samples these under minification; single-tap
      ## bilinear on the base level aliases when a pixel covers many
      ## texels (thin strokes break up), while a 2x-oversampled level
      ## keeps coverage even. Levels share the base flags.

proc halvePixels(cur: openArray[uint8], cw, ch: int):
    tuple[w, h: int, pixels: seq[uint8]] =
  ## One area-weighted box halve in premultiplied space (straight
  ## alpha out). Even dims average exact 2x2 boxes; odd dims weight
  ## partial edge texels proportionally so no source texel is dropped.
  let nw = max(1, cw div 2)
  let nh = max(1, ch div 2)
  var nxt = newSeq[uint8](nw * nh * 4)
  let sx = float64(cw) / float64(nw)
  let sy = float64(ch) / float64(nh)
  for y in 0 ..< nh:
    let y0 = float64(y) * sy
    let y1 = y0 + sy
    for x in 0 ..< nw:
      let x0 = float64(x) * sx
      let x1 = x0 + sx
      var acc = [0.0, 0.0, 0.0, 0.0]
      var area = 0.0
      for j in max(0, int(y0)) .. min(ch - 1, int(y1 - 1e-9)):
        let wy = min(float64(j + 1), y1) - max(float64(j), y0)
        for i in max(0, int(x0)) .. min(cw - 1, int(x1 - 1e-9)):
          let wx = min(float64(i + 1), x1) - max(float64(i), x0)
          let w = wx * wy
          let s = (j * cw + i) * 4
          let a = float64(cur[s + 3]) / 255.0
          acc[0] += float64(cur[s]) / 255.0 * a * w
          acc[1] += float64(cur[s + 1]) / 255.0 * a * w
          acc[2] += float64(cur[s + 2]) / 255.0 * a * w
          acc[3] += a * w
          area += w
      let d = (y * nw + x) * 4
      if area > 1e-9 and acc[3] > 1e-9 * area:
        let a = acc[3] / area
        nxt[d] = uint8(min(255.0, acc[0] / area / a * 255.0 + 0.5))
        nxt[d + 1] = uint8(min(255.0, acc[1] / area / a * 255.0 + 0.5))
        nxt[d + 2] = uint8(min(255.0, acc[2] / area / a * 255.0 + 0.5))
        nxt[d + 3] = uint8(min(255.0, a * 255.0 + 0.5))
      else:
        nxt[d] = 0
        nxt[d + 1] = 0
        nxt[d + 2] = 0
        nxt[d + 3] = 0
  (nw, nh, nxt)

proc buildMips(w, h: int, pixels: seq[uint8],
    flags: set[ImageFlag]): seq[Image] =
  ## Halve until 1x1. Each level owns its pixels (built once per
  ## upload; sampling only reads).
  result = @[]
  var cw = w
  var ch = h
  var cur = pixels
  while cw > 1 or ch > 1:
    let (nw, nh, nxt) = halvePixels(cur, cw, ch)
    result.add(Image(w: nw, h: nh, pixels: nxt, flags: flags))
    cur = nxt
    cw = nw
    ch = nh

proc newImage*(w, h: int, flags: set[ImageFlag],
    data: openArray[uint8]): Image =
  ## Build an image, zero-padding short uploads and truncating long ones.
  ## Requires positive dimensions; callers validate first. The mipmap
  ## pyramid builds here (about 1/3 extra memory, one-time box filter).
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
  result.mips = buildMips(result.w, result.h, result.pixels, flags)

proc update*(img: Image, data: openArray[uint8]): bool =
  ## Replace image contents; the size must match exactly. The pyramid
  ## rebuilds from the new pixels.
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
  img.mips = buildMips(img.w, img.h, img.pixels, img.flags)
  true

proc mipFor*(img: Image, lod: int): Image =
  ## The pyramid level for `lod` (0 = base), clamped to the finest
  ## level built. Nil images pass through.
  if img == nil or lod <= 0 or img.mips.len == 0:
    return img
  img.mips[min(lod, img.mips.len) - 1]

proc lodFor*(img: Image, tpp: float64): int =
  ## Level whose texels best match `tpp` source texels per device
  ## pixel (`floor(log2)`, so a level texel covers at most ~2 px).
  ## Nil or level-less images report 0.
  if img == nil or img.mips.len == 0:
    return 0
  clamp(int(floor(log2(max(1.0, tpp)))), 0, img.mips.len)

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
