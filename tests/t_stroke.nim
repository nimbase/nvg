import std/os
import std/unittest
import nvg

proc dark(c: Color): bool = c.r < 0.5 and c.g < 0.5 and c.b < 0.5
proc light(c: Color): bool = c.r > 0.9 and c.g > 0.9 and c.b > 0.9

proc strokedRect(join: LineJoin): Canvas =
  result = newCanvas(140, 140)
  result.clear(rgb(255, 255, 255))
  result.beginPath()
  result.rect(20, 20, 100, 100)
  result.setStrokeColor(rgbf(0, 0, 0))
  result.setStrokeWidth(20.0)
  result.setLineJoin(join)
  result.stroke()

test "round joins curve the outside, miter spikes, bevel cuts":
  # Outset corner is (10,10); outer arc center is the rect corner (20,20).
  let round = strokedRect(ljRound)
  check dark(round.surface.getPixel(13, 13)) # inside the corner arc
  check light(round.surface.getPixel(11, 11)) # outside the corner arc
  let miter = strokedRect(ljMiter)
  check dark(miter.surface.getPixel(13, 13))
  check dark(miter.surface.getPixel(11, 11)) # spike reaches the corner
  let bevel = strokedRect(ljBevel)
  check light(bevel.surface.getPixel(13, 13)) # flat cut
  check light(bevel.surface.getPixel(11, 11))

test "miter limit falls back to bevel on sharp turns":
  var pth = Path()
  pth.moveTo(0, 0, identity())
  pth.lineTo(100, 30, identity())
  pth.lineTo(0, 60, identity())
  let polys = pth.flatten()
  let spiked = expandStroke(polys, 10.0, lcButt, ljMiter, 10.0)
  let cut = expandStroke(polys, 10.0, lcButt, ljMiter, 1.5)
  let (_, _, spikeX1, _) = flattenBounds(spiked)
  let (_, _, cutX1, _) = flattenBounds(cut)
  check spikeX1 > 114.0 # full miter spike
  check cutX1 < 110.0 # beveled tip
  check cutX1 > 100.0 # but still past the vertex

test "caps end lines differently":
  proc cappedLine(cap: LineCap): Canvas =
    result = newCanvas(120, 120)
    result.clear(rgb(255, 255, 255))
    result.beginPath()
    result.moveTo(20, 60)
    result.lineTo(100, 60)
    result.setStrokeColor(rgbf(0, 0, 0))
    result.setStrokeWidth(10.0)
    result.setLineCap(cap)
    result.stroke()
  let butt = cappedLine(lcButt)
  check light(butt.surface.getPixel(17, 60)) # flush cut at x=20
  check dark(butt.surface.getPixel(25, 60))
  let square = cappedLine(lcSquare)
  check dark(square.surface.getPixel(17, 60)) # extends to x=15
  check light(square.surface.getPixel(14, 60))
  check dark(square.surface.getPixel(15, 55)) # square corner filled
  let round = cappedLine(lcRound)
  check dark(round.surface.getPixel(17, 60))
  check light(round.surface.getPixel(15, 55)) # round corner cut away

test "thin strokes measure true coverage":
  let c = newCanvas(120, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.moveTo(10, 50.5)
  c.lineTo(100, 50.5)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(0.5)
  c.stroke()
  let mid = c.surface.getPixel(50, 50)
  check mid.r > 0.2 and mid.r < 0.8 # ~50% coverage, not alpha-squared
  check light(c.surface.getPixel(50, 48))
  check light(c.surface.getPixel(50, 52))

test "zero width strokes nothing":
  let c = newCanvas(60, 60)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.rect(10, 10, 40, 40)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(0.0)
  c.stroke()
  check light(c.surface.getPixel(10, 10))
  check light(c.surface.getPixel(30, 10))

test "stroke width scales with the current transform":
  let c = newCanvas(200, 200)
  c.clear(rgb(255, 255, 255))
  c.save()
  c.scale(2.0, 2.0)
  c.beginPath()
  c.rect(10, 10, 40, 40)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(4.0)
  c.stroke()
  c.restore()
  # Device rect is (20,20,80,80) with an 8px stroke: top band y in 16..24.
  check dark(c.surface.getPixel(60, 17))
  check dark(c.surface.getPixel(60, 20))
  check light(c.surface.getPixel(60, 30))

test "round joins on open polylines bulge outward":
  let c = newCanvas(120, 120)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.moveTo(20, 100)
  c.lineTo(20, 40)
  c.lineTo(80, 40)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(12.0)
  c.setLineJoin(ljRound)
  c.stroke()
  # Outer corner arc center is (20,40) r6: diagonal point inside it.
  check dark(c.surface.getPixel(16, 36))
  check dark(c.surface.getPixel(20, 70)) # straight run intact

test "stroke golden":
  let c = newCanvas(360, 140)
  c.clear(rgb(255, 255, 255))
  c.setStrokeColor(rgbf(0.1, 0.1, 0.1))
  c.setStrokeWidth(16.0)
  for i, join in [ljMiter, ljRound, ljBevel]:
    c.beginPath()
    c.rect(10.0 + float64(i) * 120.0, 20, 100, 100)
    c.setLineJoin(join)
    c.stroke()
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  c.savePng(outDir / "stroke_joins.png")
  check fileExists(outDir / "stroke_joins.png")
