## Offscreen layers and alpha masks.
##
## A second canvas renders content offscreen; an alpha mask cut from a
## circle shapes it, then it is composited back onto the main scene.
##
## Run: nim c -r examples/masks.nim [outDir]

import std/os
import nvg

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 300)
  c.clear(rgb(255, 255, 255))

  # Backdrop gradient on the main canvas.
  c.beginPath()
  c.rect(0, 0, 400, 300)
  c.setFillPaint(c.linearGradient(0, 0, 400, 300,
    rgbf(0.15, 0.2, 0.45), rgbf(0.6, 0.7, 0.95)))
  c.fill()

  # Offscreen content: warm gradient rect with a star.
  let layer = newCanvas(400, 300)
  layer.beginPath()
  layer.rect(60, 60, 280, 180)
  layer.setFillPaint(layer.linearGradient(60, 60, 340, 240,
    rgbf(1.0, 0.75, 0.2), rgbf(0.9, 0.25, 0.15)))
  layer.fill()
  layer.beginPath()
  layer.star(200, 150, 80, 34, 5, 0.0)
  layer.setFillColor(rgbf(1, 1, 1))
  layer.fill()

  # Mask: white circle on transparency, cut out of the layer bounds.
  let m = newCanvas(400, 300)
  m.beginPath()
  m.circle(200, 150, 110)
  m.setFillColor(rgbf(1, 1, 1))
  m.fill()
  let mask = maskFromAlpha(m.surface)

  # Shape the layer through the mask, then composite it back.
  let shaped = newLayer(400, 300)
  blitMasked(shaped, layer.surface, mask, 0, 0)
  compositeOver(c.surface, shaped, 0, 0)

  c.savePng(outDir / "masks.png")
  echo "wrote ", outDir / "masks.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
