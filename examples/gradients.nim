## Gradient paints: linear, radial, box, and multi-stop.
##
## Run: nim c -r examples/gradients.nim [outDir]

import std/os
import nvg

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 300)
  c.clear(rgb(255, 255, 255))

  # Two-stop linear gradient.
  c.beginPath()
  c.rect(20, 20, 160, 110)
  c.setFillPaint(c.linearGradient(20, 20, 180, 130,
    rgbf(1, 0, 0), rgbf(0, 0, 1)))
  c.fill()

  # Two-stop radial gradient (ring with inner radius).
  c.beginPath()
  c.circle(300, 75, 60)
  c.setFillPaint(c.radialGradient(300, 75, 8, 60,
    rgbf(1, 1, 0), rgbf(0, 0.5, 0)))
  c.fill()

  # Multi-stop linear gradient with a hard stop at 0.5
  # (duplicate position: last author wins).
  c.beginPath()
  c.rect(20, 160, 160, 110)
  c.setFillPaint(c.linearGradientStops(20, 160, 180, 160, [
    GradientStop(pos: 0.0, color: rgbf(0, 0, 1)),
    GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
    GradientStop(pos: 0.5, color: rgbf(1, 1, 0)),
    GradientStop(pos: 1.0, color: rgbf(1, 0, 0))]))
  c.fill()

  # Feathered box gradient.
  c.beginPath()
  c.rect(220, 160, 160, 110)
  c.setFillPaint(c.boxGradient(220, 160, 160, 110, 14, 24,
    rgbf(0.9, 0.1, 0.7), rgbf(0.1, 0.1, 0.4)))
  c.fill()

  c.savePng(outDir / "gradients.png")
  echo "wrote ", outDir / "gradients.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
