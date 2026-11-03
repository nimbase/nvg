import std/os
import std/math
import std/unittest
import nvg

proc close(a, b: float64, eps = 0.04): bool = abs(a - b) < eps
proc same(c: Color, r, g, b, a: float64): bool =
  close(c.r, r) and close(c.g, g) and close(c.b, b) and close(c.a, a)

proc compPixel(op: CompOp, bg: Color): Color =
  let c = newCanvas(20, 20)
  c.clear(bg)
  c.beginPath()
  c.rect(0, 0, 20, 20)
  c.setFillColor(rgbaf(1, 0, 0, 0.5))
  c.setCompositeOp(op)
  c.fill()
  c.surface.getPixel(10, 10)

test "composite ops over opaque blue":
  let bg = rgbf(0, 0, 1)
  check same(compPixel(coSourceOver, bg), 0.5, 0, 0.5, 1)
  check same(compPixel(coSourceIn, bg), 1, 0, 0, 0.5)
  check compPixel(coSourceOut, bg).a < 0.05 # cleared
  check same(compPixel(coAtop, bg), 0.5, 0, 0.5, 1)
  check same(compPixel(coDestinationOver, bg), 0, 0, 1, 1)
  check same(compPixel(coDestinationIn, bg), 0, 0, 1, 0.5)
  check same(compPixel(coDestinationOut, bg), 0, 0, 1, 0.5)
  check same(compPixel(coDestinationAtop, bg), 0, 0, 1, 0.5)
  check same(compPixel(coLighter, bg), 0.5, 0, 1, 1)
  check same(compPixel(coCopy, bg), 1, 0, 0, 0.5)
  check same(compPixel(coXor, bg), 0, 0, 1, 0.5)

test "separable blends over opaque blue":
  let bg = rgbf(0, 0, 1)
  check same(compPixel(coDarken, bg), 0, 0, 0.5, 1)
  check same(compPixel(coLighten, bg), 0.5, 0, 1, 1)
  check same(compPixel(coColorDodge, bg), 0.5, 0, 0.5, 1)
  check same(compPixel(coColorBurn, bg), 0.5, 0, 0.5, 1)
  check same(compPixel(coHardLight, bg), 0.5, 0, 0.5, 1)
  check same(compPixel(coSoftLight, bg), 0, 0, 1, 1)
  check same(compPixel(coDifference, bg), 0.5, 0, 1, 1)
  check same(compPixel(coExclusion, bg), 0.5, 0, 1, 1)

test "non-separable blends over opaque blue":
  let bg = rgbf(0, 0, 1)
  check same(compPixel(coHue, bg), 0.18, 0, 0.5, 1)
  check same(compPixel(coSaturation, bg), 0, 0, 1, 1)
  check same(compPixel(coColor, bg), 0.18, 0, 0.5, 1)
  check same(compPixel(coLuminosity, bg), 0.11, 0.11, 1, 1)

test "blend-then-composite over translucent destination":
  # Naive mix(Cb,Bout,as) agrees only for opaque dst; these pin the
  # premultiplied wrapper: darken gives 1/3, difference 2/3.
  let bg = rgbaf(0, 0, 1, 0.5)
  let dk = compPixel(coDarken, bg)
  check same(dk, 1.0 / 3.0, 0, 1.0 / 3.0, 0.75)
  let df = compPixel(coDifference, bg)
  check same(df, 2.0 / 3.0, 0, 2.0 / 3.0, 0.75)
  check close(compPixel(coColorDodge, bg).a, 0.75)
  check close(compPixel(coLuminosity, bg).a, 0.75)

test "atop preserves translucent destination alpha":
  let bg = rgbaf(0, 0, 1, 0.5)
  let atop = compPixel(coAtop, bg)
  check same(atop, 0.5, 0, 0.5, 0.5)
  let over = compPixel(coSourceOver, bg)
  check close(over.a, 0.75) # atop keeps 0.5, over does not

test "scissor follows rotation":
  let c = newCanvas(120, 120)
  c.clear(rgb(255, 255, 255))
  c.rotate(PI / 2.0)
  c.translate(60, 60)
  # User rect x0..40,y0..20 lands on device x40..60,y60..100.
  c.scissor(0, 0, 40, 20)
  c.resetTransform()
  c.beginPath()
  c.rect(0, 0, 120, 120)
  c.setFillColor(rgbf(1, 0, 0))
  c.fill()
  check c.surface.getPixel(50, 80).r > 0.9
  check c.surface.getPixel(70, 70).r < 0.1 + 1.0 and
    c.surface.getPixel(70, 70).g > 0.9 # outside: still white
  check c.surface.getPixel(50, 50).g > 0.9

test "intersected scissor clips to the overlap":
  let c = newCanvas(120, 120)
  c.clear(rgb(255, 255, 255))
  c.scissor(10, 10, 100, 100)
  c.intersectScissor(30, 30, 40, 40)
  c.beginPath()
  c.rect(0, 0, 120, 120)
  c.setFillColor(rgbf(0, 0, 0))
  c.fill()
  check c.surface.getPixel(20, 20).r > 0.9
  check c.surface.getPixel(50, 50).r < 0.1
  check c.surface.getPixel(80, 80).r > 0.9
  c.resetScissor()
  c.beginPath()
  c.rect(0, 0, 120, 120)
  c.fill()
  check c.surface.getPixel(20, 20).r < 0.1 # clip released

test "composite golden":
  const ops = [coSourceOver, coSourceIn, coSourceOut, coAtop,
    coDestinationOver, coDestinationIn, coDestinationOut,
    coDestinationAtop, coLighter, coCopy, coXor, coMultiply, coScreen,
    coOverlay, coDarken, coLighten, coColorDodge, coColorBurn,
    coHardLight, coSoftLight, coDifference, coExclusion, coHue,
    coSaturation, coColor, coLuminosity]
  let c = newCanvas(ops.len * 24, 24)
  c.clear(rgbf(0, 0, 1))
  for i, op in ops:
    c.beginPath()
    c.rect(float64(i * 24) + 2, 2, 20, 20)
    c.setFillColor(rgbaf(1, 0, 0, 0.6))
    c.setCompositeOp(op)
    c.fill()
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  c.savePng(outDir / "comp_ops.png")
  check fileExists(outDir / "comp_ops.png")
