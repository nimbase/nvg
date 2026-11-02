import std/os
import std/math
import std/unittest
import nvg

proc dark(c: Color): bool = c.r < 0.5 and c.g < 0.5 and c.b < 0.5
proc light(c: Color): bool = c.r > 0.9 and c.g > 0.9 and c.b > 0.9

test "varying radii round only the specified corners":
  let c = newCanvas(120, 80)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.roundedRectVarying(10, 10, 100, 60, 20, 0, 20, 0)
  c.setFillColor(rgbf(0, 0, 0))
  c.fill()
  check light(c.surface.getPixel(12, 12)) # cut TL corner
  check dark(c.surface.getPixel(108, 11)) # sharp TR corner
  check light(c.surface.getPixel(107, 67)) # cut BR corner
  check dark(c.surface.getPixel(11, 68)) # sharp BL corner
  check dark(c.surface.getPixel(60, 40))

test "all-zero radii fall back to a plain rect":
  let c = newCanvas(80, 60)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.roundedRectVarying(10, 10, 50, 30, 0, 0, 0, 0)
  c.setFillColor(rgbf(0, 0, 0))
  c.fill()
  check dark(c.surface.getPixel(10, 10))
  check dark(c.surface.getPixel(35, 25))

test "negative height traces the same rounded shape":
  let a = newCanvas(120, 80)
  a.clear(rgb(255, 255, 255))
  a.beginPath()
  a.roundedRectVarying(10, 70, 100, -60, 10, 10, 10, 10)
  a.setFillColor(rgbf(0, 0, 0))
  a.fill()
  let b = newCanvas(120, 80)
  b.clear(rgb(255, 255, 255))
  b.beginPath()
  b.roundedRect(10, 10, 100, 60, 10)
  b.setFillColor(rgbf(0, 0, 0))
  b.fill()
  for (x, y) in [(60, 40), (11, 11), (30, 15), (100, 60)]:
    let pa = a.surface.getPixel(x, y)
    let pb = b.surface.getPixel(x, y)
    check abs(pa.r - pb.r) < 0.02

test "arc CW draws the short quarter":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.arc(50, 50, 30, 0, PI / 2.0, wCW)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(6.0)
  c.stroke()
  check dark(c.surface.getPixel(71, 71)) # 45-degree midpoint
  check dark(c.surface.getPixel(80, 50)) # start endpoint
  check dark(c.surface.getPixel(50, 80)) # end endpoint
  check light(c.surface.getPixel(50, 20)) # opposite side empty

test "arc CCW takes the long way around":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.arc(50, 50, 30, 0, PI / 2.0, wCCW)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(6.0)
  c.stroke()
  check dark(c.surface.getPixel(50, 20)) # -90 degrees covered
  check dark(c.surface.getPixel(20, 50)) # 180 degrees covered
  check light(c.surface.getPixel(71, 71)) # missing quarter stays empty

test "full-circle arc closes the ring":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.arc(50, 50, 20, 0, 2 * PI, wCW)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(6.0)
  c.stroke()
  check dark(c.surface.getPixel(50, 30))
  check light(c.surface.getPixel(50, 50))

test "arcTo rounds the fillet":
  let c = newCanvas(120, 120)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.moveTo(10, 110)
  c.lineTo(10, 35)
  c.arcTo(10, 10, 110, 10, 25)
  c.lineTo(110, 10)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(8.0)
  c.stroke()
  check dark(c.surface.getPixel(17, 17)) # arc midpoint hugs the corner
  check light(c.surface.getPixel(12, 12)) # sharp corner itself is cut
  check dark(c.surface.getPixel(10, 60)) # incoming tangent intact
  check dark(c.surface.getPixel(60, 10)) # outgoing tangent intact

test "arcTo degenerates to lineTo when collinear":
  let c = newCanvas(220, 40)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.moveTo(0, 10)
  c.lineTo(50, 10)
  c.arcTo(100, 10, 200, 10, 20)
  c.lineTo(200, 10)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(6.0)
  c.stroke()
  check dark(c.surface.getPixel(150, 10))
  check light(c.surface.getPixel(150, 25))

test "arcTo without a pen is a no-op":
  let c = newCanvas(40, 40)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.arcTo(10, 10, 30, 10, 10)
  check c.path.commands.len == 0
  c.setStrokeColor(rgbf(0, 0, 0))
  c.stroke()
  check light(c.surface.getPixel(20, 20))

test "tiny arcTo radius falls back to a line":
  let c = newCanvas(100, 60)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.moveTo(10, 50)
  c.arcTo(30, 10, 90, 10, 0.001)
  var sawCubic = false
  for cmd in c.path.commands:
    if cmd.kind == pcCubicTo: sawCubic = true
  check not sawCubic

test "degenerate paths are safe no-ops":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.setFillColor(rgbf(0, 0, 0))
  c.setStrokeColor(rgbf(0, 0, 0))
  c.beginPath()
  c.fill()
  c.stroke()
  c.beginPath()
  c.rect(20, 20, 0, 30)
  c.fill()
  c.beginPath()
  c.ellipse(50, 50, 0, 10)
  c.fill()
  c.beginPath()
  c.arc(50, 50, 0, 0, 1, wCW)
  c.fill()
  check light(c.surface.getPixel(50, 50))
  check light(c.surface.getPixel(20, 35))

test "moveTo-only subpath strokes a dot but fills nothing":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.moveTo(50, 50)
  c.setFillColor(rgbf(0, 0, 0))
  c.fill()
  check light(c.surface.getPixel(50, 50))
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(10.0)
  c.stroke()
  check dark(c.surface.getPixel(50, 50))

test "flatten marks corners and subdivisions":
  var pth = Path()
  pth.rect(0, 0, 10, 5, identity())
  let rectPolys = pth.flatten()
  check rectPolys.len == 1
  check rectPolys[0].pts.len == 4
  check rectPolys[0].corners.len == 4
  for f in rectPolys[0].corners: check f
  var circ = Path()
  circ.circle(0, 0, 10, identity())
  let circPolys = circ.flatten()
  check circPolys.len == 1
  check circPolys[0].pts.len > 8
  var sawPlain = false
  for f in circPolys[0].corners:
    if not f: sawPlain = true
  check sawPlain # curve subdivisions are not corners

test "path golden":
  let c = newCanvas(240, 160)
  c.clear(rgb(255, 255, 255))
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  c.setStrokeColor(rgbf(0.1, 0.1, 0.1))
  c.setStrokeWidth(5.0)
  c.beginPath()
  c.roundedRectVarying(10, 10, 100, 60, 18, 0, 18, 0)
  c.fill()
  c.beginPath()
  c.arc(170, 40, 28, 0, PI * 1.5, wCW)
  c.stroke()
  c.beginPath()
  c.moveTo(130, 130)
  c.lineTo(130, 100)
  c.arcTo(130, 90, 170, 90, 15)
  c.lineTo(220, 90)
  c.stroke()
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  c.savePng(outDir / "path_shapes.png")
  check fileExists(outDir / "path_shapes.png")
