import std/os
import std/math
import std/unittest
import nvg

proc dark(c: Color): bool = c.r < 0.5 and c.g < 0.5 and c.b < 0.5
proc light(c: Color): bool = c.r > 0.9 and c.g > 0.9 and c.b > 0.9

test "radial gradient falls off with distance":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.circle(50, 50, 45)
  c.setFillPaint(c.radialGradient(50, 50, 10, 40, rgbf(0, 0, 0),
    rgbf(1, 1, 1)))
  c.fill()
  check dark(c.surface.getPixel(50, 50)) # center: inner color
  check dark(c.surface.getPixel(50, 60)) # inner radius edge
  let mid = c.surface.getPixel(50, 74) # dist 24, t ~ 0.47
  check mid.r > 0.3 and mid.r < 0.65
  check c.surface.getPixel(50, 88).r > 0.85 # near outer radius

test "degenerate radial ring transitions within a pixel":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.rect(0, 0, 100, 100)
  c.setFillPaint(c.radialGradient(50, 50, 20, 20, rgbf(0, 0, 0),
    rgbf(1, 1, 1)))
  c.fill()
  check dark(c.surface.getPixel(50, 50))
  check dark(c.surface.getPixel(50, 69)) # center (50.5,69.5): dist < inr
  check light(c.surface.getPixel(50, 71)) # center dist 21.5: outer color

test "gradients capture the transform at creation":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  let g = c.radialGradient(10, 10, 5, 15, rgbf(0, 0, 0), rgbf(1, 1, 1))
  c.scale(2.0, 2.0) # must not move the already-created gradient
  c.beginPath()
  c.rect(0, 0, 60, 60)
  c.setFillPaint(g)
  c.fill()
  check dark(c.surface.getPixel(10, 10)) # device center baked in
  check light(c.surface.getPixel(30, 30))

test "box gradient mixes across the feather band":
  let c = newCanvas(120, 80)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.rect(0, 0, 120, 80)
  c.setFillPaint(c.boxGradient(20, 20, 60, 40, 8, 10, rgbf(0, 0, 0),
    rgbf(1, 1, 1)))
  c.fill()
  check dark(c.surface.getPixel(50, 40)) # deep inside
  check dark(c.surface.getPixel(70, 40)) # 10px inside the edge
  let edge = c.surface.getPixel(80, 40) # on the edge: 50% mix
  check edge.r > 0.3 and edge.r < 0.7
  check light(c.surface.getPixel(95, 40)) # well outside

test "box corner radius rounds the falloff":
  proc boxAt(r: float64): Canvas =
    result = newCanvas(100, 100)
    result.clear(rgb(255, 255, 255))
    result.beginPath()
    result.rect(0, 0, 100, 100)
    result.setFillPaint(result.boxGradient(20, 20, 60, 40, r, 10,
      rgbf(0, 0, 0), rgbf(1, 1, 1)))
    result.fill()
  let sharp = boxAt(0.0) # corner (80,60): sd 0 -> mid gray
  let round = boxAt(12.0) # same point: sd 5 -> outer color
  let s = sharp.surface.getPixel(80, 60)
  check s.r > 0.3 and s.r < 0.7
  check light(round.surface.getPixel(80, 60))

test "image pattern samples exact texels with nearest":
  let c = newCanvas(4, 4)
  c.clear(rgb(255, 255, 255))
  let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
    0, 0, 255, 255, 255, 255, 255, 255]
  let id = c.createImageRGBA(2, 2, {ifNearest}, data)
  check id != 0
  let (w, h, ok) = c.imageSize(id)
  check ok and w == 2 and h == 2
  c.beginPath()
  c.rect(0, 0, 2, 2)
  c.setFillPaint(c.imagePattern(0, 0, 2, 2, 0, id, 1.0))
  c.fill()
  let r = c.surface.getPixel(0, 0)
  check r.r > 0.9 and r.g < 0.1 and r.b < 0.1
  let g = c.surface.getPixel(1, 0)
  check g.g > 0.9 and g.r < 0.1
  let b = c.surface.getPixel(0, 1)
  check b.b > 0.9 and b.r < 0.1
  let wh = c.surface.getPixel(1, 1)
  check wh.r > 0.9 and wh.g > 0.9 and wh.b > 0.9

test "pattern repeat tiles, clamp stretches the edge":
  proc tiled(repeat: bool): Color =
    let c = newCanvas(5, 1)
    c.clear(rgb(255, 255, 255))
    let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255]
    var flags: set[ImageFlag] = {ifNearest}
    if repeat: flags.incl(ifRepeatX)
    let id = c.createImageRGBA(2, 1, flags, data)
    c.beginPath()
    c.rect(0, 0, 5, 1)
    c.setFillPaint(c.imagePattern(0, 0, 2, 1, 0, id, 1.0))
    c.fill()
    c.surface.getPixel(2, 0) # u = 1.25: repeat -> red, clamp -> green
  let rep = tiled(true)
  check rep.r > 0.9 and rep.g < 0.1
  let cl = tiled(false)
  check cl.g > 0.9 and cl.r < 0.1

test "pattern flipY mirrors vertically":
  let c = newCanvas(1, 2)
  c.clear(rgb(255, 255, 255))
  let data = @[255'u8, 0, 0, 255, 0, 0, 255, 255] # top red, bottom blue
  let id = c.createImageRGBA(1, 2, {ifNearest, ifFlipY}, data)
  c.beginPath()
  c.rect(0, 0, 1, 2)
  c.setFillPaint(c.imagePattern(0, 0, 1, 2, 0, id, 1.0))
  c.fill()
  check c.surface.getPixel(0, 0).b > 0.9
  check c.surface.getPixel(0, 1).r > 0.9

test "rotated pattern follows the inverse-rotation convention":
  let c = newCanvas(2, 4)
  c.clear(rgb(255, 255, 255))
  let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255] # red, green
  let id = c.createImageRGBA(2, 1, {ifNearest, ifRepeatX, ifRepeatY},
    data)
  c.beginPath()
  c.rect(0, 0, 2, 4)
  c.setFillPaint(c.imagePattern(0, 0, 2, 1, PI / 2.0, id, 1.0))
  c.fill()
  check c.surface.getPixel(0, 0).r > 0.9 # u = 0.25 -> red
  check c.surface.getPixel(0, 1).g > 0.9 # u = 0.75 -> green
  check c.surface.getPixel(0, 2).r > 0.9 # u = 1.25 wraps -> red
  check c.surface.getPixel(1, 1).g > 0.9

test "bilinear default stretches a single texel":
  let c = newCanvas(3, 3)
  c.clear(rgb(255, 255, 255))
  let id = c.createImageRGBA(1, 1, {}, @[255'u8, 0, 0, 255])
  c.beginPath()
  c.rect(0, 0, 3, 3)
  c.setFillPaint(c.imagePattern(0, 0, 3, 3, 0, id, 1.0))
  c.fill()
  for y in 0 ..< 3:
    for x in 0 ..< 3:
      check c.surface.getPixel(x, y).r > 0.9

test "premultiplied uploads convert to straight":
  let c = newCanvas(2, 2)
  c.clear(rgb(255, 255, 255))
  let id = c.createImageRGBA(1, 1, {ifNearest, ifPremultiplied},
    @[128'u8, 0, 0, 128])
  c.beginPath()
  c.rect(0, 0, 2, 2)
  c.setFillPaint(c.imagePattern(0, 0, 2, 2, 0, id, 1.0))
  c.fill()
  let p = c.surface.getPixel(0, 0) # red@0.5 over white
  check p.r > 0.9 and p.g > 0.3 and p.g < 0.7

test "image update, bad update, and unknown ids":
  let c = newCanvas(2, 2)
  let id = c.createImageRGBA(1, 1, {ifNearest},
    @[255'u8, 0, 0, 255])
  check c.updateImage(id, @[0'u8, 255, 0, 255])
  check not c.updateImage(id, @[0'u8, 255, 0]) # wrong size
  check not c.updateImage(999, @[0'u8, 0, 0, 255])
  c.beginPath()
  c.rect(0, 0, 2, 2)
  c.setFillPaint(c.imagePattern(0, 0, 2, 2, 0, id, 1.0))
  c.fill()
  check c.surface.getPixel(0, 0).g > 0.9 # updated to green
  check c.imageSize(999) == (0, 0, false)
  c.deleteImage(id)
  check c.imageSize(id) == (0, 0, false)
  check c.createImageRGBA(0, 4, {}, []) == 0

test "unknown pattern image paints transparent":
  let c = newCanvas(10, 10)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.rect(0, 0, 10, 10)
  c.setFillPaint(c.imagePattern(0, 0, 4, 4, 0, 999, 1.0))
  c.fill()
  check light(c.surface.getPixel(5, 5))

test "paint golden":
  let c = newCanvas(280, 120)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.circle(60, 60, 50)
  c.setFillPaint(c.radialGradient(60, 60, 5, 50, rgbf(0.8, 0.1, 0.1),
    rgbf(0.1, 0.1, 0.8)))
  c.fill()
  c.beginPath()
  c.rect(130, 10, 140, 100)
  c.setFillPaint(c.boxGradient(130, 10, 140, 100, 12, 18,
    rgbf(0.1, 0.5, 0.1), rgbf(0.9, 0.9, 0.9)))
  c.fill()
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  c.savePng(outDir / "paint_sampling.png")
  check fileExists(outDir / "paint_sampling.png")
