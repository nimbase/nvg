import std/unittest
import nvg

proc solidSurf(w, h: int, c: Color): Surface =
  result = newSurface(w, h)
  result.clear(c)

proc alphaAt(s: Surface, x, y: int): uint8 =
  s.pixels[(y * s.w + x) * 4 + 3]

test "alpha cutout blanks the masked region":
  let dst = solidSurf(10, 10, rgbf(1, 0, 0))
  let m = newSurface(10, 10)
  m.clear(rgbaf(0, 0, 0, 0))
  for y in 2 ..< 8:
    for x in 2 ..< 8:
      m.setPixel(x, y, rgbf(1, 1, 1))
  let cut = maskInvert(maskFromAlpha(m))
  let src = solidSurf(10, 10, rgbaf(0, 0, 1, 1.0))
  blitMasked(dst, src, cut, 0, 0)
  let center = dst.getPixel(5, 5)
  check center.r > 0.9 and center.b < 0.1 # still red
  let corner = dst.getPixel(0, 0)
  check corner.b > 0.9 and corner.r < 0.1 # now blue

test "inverted mask is the complement":
  let m = solidSurf(4, 1, rgbaf(1, 1, 1, 1.0))
  m.setPixel(1, 0, rgbaf(1, 1, 1, 0.5))
  m.setPixel(2, 0, rgbaf(1, 1, 1, 0.0))
  let inv = maskInvert(maskFromAlpha(m))
  check alphaAt(inv, 0, 0) == 0
  check alphaAt(inv, 1, 0) > 120 and alphaAt(inv, 1, 0) < 136
  check alphaAt(inv, 3, 0) == 0
  check alphaAt(inv, 2, 0) == 255

test "intersect of two rects is the overlap":
  proc rectMask(x0, y0, x1, y1: int): Surface =
    result = newSurface(10, 10)
    result.clear(rgbaf(0, 0, 0, 0))
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        result.setPixel(x, y, rgbf(1, 1, 1))
  let inter = maskCombine(rectMask(0, 0, 6, 10), rectMask(4, 0, 10, 10),
    mIntersect)
  check alphaAt(inter, 5, 5) == 255
  check alphaAt(inter, 1, 5) == 0
  check alphaAt(inter, 8, 5) == 0
  let union = maskCombine(rectMask(0, 0, 6, 10), rectMask(4, 0, 10, 10),
    mAdd)
  check alphaAt(union, 1, 5) == 255 and alphaAt(union, 8, 5) == 255
  let diff = maskCombine(rectMask(0, 0, 6, 10), rectMask(4, 0, 10, 10),
    mSubtract)
  check alphaAt(diff, 5, 5) == 0 and alphaAt(diff, 1, 5) == 255

test "luminance mask scales by alpha":
  let s = newSurface(2, 1)
  s.setPixel(0, 0, rgbaf(1, 1, 1, 1.0)) # white opaque -> 255
  s.setPixel(1, 0, rgbaf(1, 1, 1, 0.5)) # white half -> ~128
  let m = maskFromLuminance(s)
  check alphaAt(m, 0, 0) == 255
  check alphaAt(m, 1, 0) > 120 and alphaAt(m, 1, 0) < 136

test "nested scratch compositing matches single pass":
  # Reference: blue fullscreen cut by a centered hole, red under it.
  let dst1 = solidSurf(10, 10, rgbf(1, 0, 0))
  let hole = newSurface(10, 10)
  hole.clear(rgbaf(0, 0, 0, 0))
  for y in 3 ..< 7:
    for x in 3 ..< 7:
      hole.setPixel(x, y, rgbf(1, 1, 1))
  let cut = maskInvert(maskFromAlpha(hole))
  let blue = solidSurf(10, 10, rgbaf(0, 0, 1, 1.0))
  blitMasked(dst1, blue, cut, 0, 0)
  # Nested: composite blue-through-cut onto a scratch, then over red.
  let scratch = newLayer(10, 10)
  blitMasked(scratch, blue, cut, 0, 0)
  let dst2 = solidSurf(10, 10, rgbf(1, 0, 0))
  compositeOver(dst2, scratch, 0, 0)
  check dst1.pixels == dst2.pixels

test "mismatched combine sizes return a copy of a":
  let a = solidSurf(4, 4, rgbaf(1, 1, 1, 1.0))
  let b = solidSurf(2, 2, rgbaf(1, 1, 1, 1.0))
  let c = maskCombine(a, b, mIntersect)
  check c.pixels == a.pixels

test "difference of two rects is the symmetric remainder":
  proc rectMask(x0, y0, x1, y1: int): Surface =
    result = newSurface(10, 10)
    result.clear(rgbaf(0, 0, 0, 0))
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        result.setPixel(x, y, rgbf(1, 1, 1))
  let d = maskCombine(rectMask(0, 0, 6, 10), rectMask(4, 0, 10, 10),
    mDifference)
  check alphaAt(d, 1, 5) == 255
  check alphaAt(d, 8, 5) == 255
  check alphaAt(d, 5, 5) == 0
  let same = maskCombine(rectMask(0, 0, 6, 10), rectMask(0, 0, 6, 10),
    mDifference)
  check alphaAt(same, 1, 5) == 0
  check alphaAt(same, 8, 5) == 0
