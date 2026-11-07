## Kaleidoscope from a photo (CPU backend, no font or GPU needed).
##
## Twelve mirrored wedges sample one photo tile: each wedge rotates the
## frame and every odd wedge mirrors it, so shared edges stay seamless
## by construction. A medallion and ring finish the disc.
##
## Run: nim c -r examples/kaleidoscope.nim [outDir]
## Source photo: tests/data/pexels-arash-kh-1030567404-24596467.jpg

import std/os
import std/math
import nvg

const
  W = 800
  H = 800
  Cx = 400.0
  Cy = 400.0
  Radius = 378.0
  Segments = 12

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(W, H)
  c.clear(rgbf(0.05, 0.05, 0.08))

  let id = c.createImageFile("tests/data/pexels-arash-kh-1030567404-24596467.jpg",
    {ifRepeatX, ifRepeatY})
  if id == 0:
    quit "cannot load tests/data/pexels-arash-kh-1030567404-24596467.jpg"

  # Wedge fan: alternate wedges mirror across their centerline, so
  # shared edges sample identical texels and stay seamless. Calls
  # compose right-to-left (pre-multiplied): mirror, then rotate about
  # the local origin, then move the apex to the disc center.
  let step = 2.0 * PI / float64(Segments)
  let ex = cos(step * 0.5) * Radius
  let ey = sin(step * 0.5) * Radius
  for i in 0 ..< Segments:
    c.save()
    if i mod 2 == 1:
      c.scale(1.0, -1.0)
    c.rotate(float64(i) * step)
    c.translate(Cx, Cy)
    c.setFillPaint(c.imagePattern(-140, -140, 280, 280, 0.0, id, 1.0))
    c.beginPath()
    c.moveTo(0, 0)
    c.lineTo(ex, -ey)
    c.lineTo(ex, ey)
    c.closePath()
    c.fill()
    c.restore()

  # Medallion with a zoomed tile plus ring strokes. Tile origin keeps
  # repeat-wrap boundaries outside the medallion (photos are not
  # tileable, so a wrap inside the circle would seam).
  c.setFillPaint(c.imagePattern(300, 300, 200, 200, 0.0, id, 1.0))
  c.beginPath()
  c.circle(Cx, Cy, 72)
  c.fill()
  c.setStrokeColor(rgbf(0.95, 0.95, 0.95))
  c.setStrokeWidth(4.0)
  c.beginPath()
  c.circle(Cx, Cy, 72)
  c.stroke()
  c.setStrokeColor(rgbf(0.08, 0.08, 0.12))
  c.setStrokeWidth(14.0)
  c.beginPath()
  c.circle(Cx, Cy, Radius + 2)
  c.stroke()

  c.savePng(outDir / "kaleidoscope.png")
  echo "wrote ", outDir / "kaleidoscope.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
