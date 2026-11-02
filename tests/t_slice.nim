import std/os
import std/unittest
import nvg

test "vertical slice: solid rect, gradient circle, stroked rect":
  let c = newCanvas(256, 256)
  c.clear(rgb(255, 255, 255))

  # 1. Solid red rect (fractional origin so the left edge cuts through
  # pixels and exercises AA coverage).
  c.beginPath()
  c.rect(32.5, 32, 96, 64)
  c.setFillColor(rgb(255, 0, 0))
  c.fill()
  let center = c.surface.getPixel(80, 64)
  check abs(center.r - 1.0) < 0.02
  check center.g < 0.02
  check center.b < 0.02

  # Antialiased edge: the column at x=32 straddles the rect edge, so it
  # must be a blend of red over white (partial coverage).
  let edge = c.surface.getPixel(32, 64)
  check edge.r > 0.95
  check edge.g > 0.05 and edge.g < 0.95

  # 2. Linear-gradient circle (blue -> green along x).
  c.beginPath()
  c.circle(180, 80, 40)
  c.setFillPaint(c.linearGradient(140, 80, 220, 80,
    rgbf(0, 0, 1), rgbf(0, 1, 0)))
  c.fill()
  let left = c.surface.getPixel(145, 80)
  let right = c.surface.getPixel(215, 80)
  let mid = c.surface.getPixel(180, 80)
  check left.b > left.g + 0.3
  check right.g > right.b + 0.3
  check abs(mid.b - 0.5) < 0.15 and abs(mid.g - 0.5) < 0.15

  # 3. Stroked rect under a transform.
  c.save()
  c.translate(16, 160)
  c.beginPath()
  c.rect(0, 0, 120, 60)
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(6.0)
  c.setLineJoin(ljMiter)
  c.setLineCap(lcButt)
  c.stroke()
  c.restore()
  # Top edge of the stroked rect runs at y=160; its 6px stroke covers
  # roughly y=157..163. The interior must stay white.
  let border = c.surface.getPixel(76, 160)
  let inside = c.surface.getPixel(76, 190)
  check border.r < 0.2 and border.g < 0.2 and border.b < 0.2
  check inside.r > 0.95 and inside.g > 0.95

  # 4. PNG round-trip: signature + non-trivial payload.
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  let pngPath = outDir / "slice.png"
  c.savePng(pngPath)
  check fileExists(pngPath)
  let bytes = c.encodePng()
  check bytes.len > 100
  check bytes[0] == 137'u8 and bytes[1] == 80'u8
  check bytes[2] == 78'u8 and bytes[3] == 71'u8
