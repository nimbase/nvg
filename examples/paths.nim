## Stars, polygons, fill rules, and measuring paths.
##
## Run: nim c -r examples/paths.nim [outDir]

import std/os
import std/math
import nvg

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 340)
  c.clear(rgb(255, 255, 255))

  # Rounded star and hexagon.
  c.beginPath()
  c.star(90, 90, 70, 30, 5, -PI / 2.0, 0.25, 0.25)
  c.setFillColor(rgbf(0.95, 0.7, 0.1))
  c.fill()
  c.beginPath()
  c.polygon(280, 90, 65, 6, PI / 6.0, 0.15)
  c.setFillColor(rgbf(0.2, 0.55, 0.85))
  c.fill()
  c.beginPath()
  c.polygon(280, 90, 65, 6, PI / 6.0)
  c.setStrokeColor(rgbf(0.1, 0.1, 0.1))
  c.setStrokeWidth(3.0)
  c.stroke()

  # Fill rules: two concentric circles are a solid disc under
  # nonzero winding, but a ring under even-odd.
  for i, rule in [frEvenOdd, frNonZero]:
    let cx = 90.0 + float64(i) * 190.0
    c.beginPath()
    c.circle(cx, 245, 55)
    c.circle(cx, 245, 28)
    c.setFillColor(rgbaf(0.8, 0.2, 0.4, 0.85))
    c.fillWithRule(rule)

  # Measure a curve: dots march along it at equal arc-length steps
  # using the flattened path directly.
  var p: Path
  p.moveTo(20, 320, identity())
  p.bezierTo(140, 260, 260, 330, 380, 290, identity())
  let polys = flatten(p)
  echo "curve length: ", polyLength(polys)
  let n = 24
  for i in 0 .. n:
    let q = pointAtNorm(polys, float64(i) / float64(n))
    c.beginPath()
    c.circle(q.x, q.y, 3.5)
    c.setFillColor(rgbf(0.1, 0.1, 0.1))
    c.fill()

  c.savePng(outDir / "paths.png")
  echo "wrote ", outDir / "paths.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
