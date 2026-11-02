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
    coDestinationAtop, coLighter, coCopy, coXor]
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
