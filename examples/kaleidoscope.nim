## Kaleidoscope from a photo (CPU and GPU backends).
##
## Twelve mirrored wedges sample one photo tile: each wedge rotates the
## frame and every odd wedge mirrors it, so shared edges stay seamless
## by construction. An outer ring finishes the disc.
##
## Run: nim c -r examples/kaleidoscope.nim [outDir]
## Source photo: tests/data/pexels-arash-kh-1030567404-24596467.jpg
## With -d:nvgMetal it renders through the Metal backend when a device
## is present, falling back to CPU otherwise:
##   nim c -r -d:nvgMetal examples/kaleidoscope.nim [outDir]

import std/os
import std/math
import nvg
when defined(nvgMetal):
  import nvg/metal

const
  W = 800
  H = 800
  Cx = 400.0
  Cy = 400.0
  Radius = 378.0
  Segments = 12

proc main(outDir: string) =
  createDir(outDir)
  when defined(nvgMetal):
    var mb: MetalBackend = nil
    if mtlAvailable():
      mb = newMetalBackend(W, H)
      echo "backend: Metal"
    else:
      echo "backend: CPU (no Metal device)"
    defer:
      if mb != nil:
        mb.close()
    let c =
      if mb != nil: newCanvas(W, H, mb)
      else: newCanvas(W, H)
  else:
    echo "backend: CPU"
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
  # Each wedge overlaps its neighbors by ~1px at the rim: coverage of
  # a shared edge splits across two source-over passes, which would
  # bleed background through (up to 25% at a 0.5/0.5 split) plus float
  # edge mismatch; the overlap lets the top wedge win opaquely.
  let step = 2.0 * PI / float64(Segments)
  let ha = step * 0.5 + 1.0 / Radius
  let ex = cos(ha) * Radius
  let ey = sin(ha) * Radius
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

  # Outer frame ring.
  c.setStrokeColor(rgbf(0.08, 0.08, 0.12))
  c.setStrokeWidth(14.0)
  c.beginPath()
  c.circle(Cx, Cy, Radius + 2)
  c.stroke()

  c.savePng(outDir / "kaleidoscope.png")
  echo "wrote ", outDir / "kaleidoscope.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
