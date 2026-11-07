## Blend modes (composite ops) over a common backdrop.
##
## Run: nim c -r examples/blends.nim [outDir]

import std/os
import nvg

const ops = [coSourceOver, coAtop, coLighter, coMultiply,
  coScreen, coOverlay, coXor, coDestinationOver]

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 300)
  # Shared translucent backdrop so blending is visible.
  c.clear(rgbaf(0.2, 0.4, 0.8, 1.0))
  c.beginPath()
  c.rect(0, 0, 400, 300)
  c.setFillColor(rgbaf(0.9, 0.9, 0.9, 0.85))
  c.fill()

  for i, op in ops:
    let x = 20 + (i mod 4) * 95
    let y = 20 + (i div 4) * 140
    c.save()
    c.scissor(float64(x), float64(y), 80, 110)
    c.beginPath()
    c.circle(float64(x) + 25, float64(y) + 45, 28)
    c.setFillColor(rgbaf(1.0, 0.25, 0.2, 0.8))
    c.setCompositeOp(op)
    c.fill()
    c.beginPath()
    c.rect(float64(x) + 30, float64(y) + 55, 45, 45)
    c.setFillColor(rgbaf(0.2, 0.8, 0.3, 0.8))
    c.setCompositeOp(op)
    c.fill()
    c.restore()
    c.setCompositeOp(coSourceOver)

  c.savePng(outDir / "blends.png")
  echo "wrote ", outDir / "blends.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
