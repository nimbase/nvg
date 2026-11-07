## Basic shapes with solid fills and strokes.
##
## Run: nim c -r examples/basic.nim [outDir]

import std/os
import nvg

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 300)
  c.clear(rgb(255, 255, 255))

  # Solid filled rect.
  c.beginPath()
  c.rect(20, 20, 120, 80)
  c.setFillColor(rgbf(0.9, 0.2, 0.2))
  c.fill()

  # Circle with translucent fill over the rect.
  c.beginPath()
  c.circle(200, 120, 70)
  c.setFillColor(rgbaf(0.2, 0.4, 0.9, 0.6))
  c.fill()

  # Rounded rect outline.
  c.beginPath()
  c.roundedRect(250, 180, 120, 90, 18)
  c.setStrokeColor(rgbf(0.1, 0.6, 0.2))
  c.setStrokeWidth(6.0)
  c.setLineJoin(ljRound)
  c.stroke()

  # Ellipse outline with square caps on an open path.
  c.beginPath()
  c.moveTo(30, 250)
  c.bezierTo(120, 200, 200, 300, 300, 240)
  c.setStrokeColor(rgbf(0.1, 0.1, 0.1))
  c.setStrokeWidth(3.0)
  c.setLineCap(lcRound)
  c.stroke()

  c.savePng(outDir / "basic.png")
  echo "wrote ", outDir / "basic.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
