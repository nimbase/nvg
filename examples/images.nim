## Image file loading: decode bytes into pattern paints.
##
## Run: nim c -r examples/images.nim [outDir]
## Self-contained: the source image is rendered and PNG-encoded by nvg
## itself, then loaded back through `createImageMem` (same path real
## PNG/JPEG/BMP/GIF/QOI/PNM/TGA files take through `createImageFile`).

import std/os
import nvg

proc main(outDir: string) =
  createDir(outDir)

  # Paint the source image: gradients plus a solid block.
  let src = newCanvas(64, 64)
  src.beginPath()
  src.rect(0, 0, 64, 64)
  src.setFillPaint(src.linearGradient(0, 0, 64, 0,
    rgbf(0.9, 0.2, 0.2), rgbf(0.2, 0.2, 0.9)))
  src.fill()
  src.beginPath()
  src.circle(48, 48, 18)
  src.setFillColor(rgbf(0.1, 0.8, 0.3))
  src.fill()

  # Round-trip through the PNG encoder into the image registry.
  let c = newCanvas(320, 200)
  c.clear(rgb(255, 255, 255))
  let id = c.createImageMem(src.encodePng(), {ifRepeatX, ifRepeatY})
  if id == 0:
    quit "failed to decode our own PNG output"

  # Tiled pattern fill.
  c.beginPath()
  c.rect(20, 20, 130, 130)
  c.setFillPaint(c.imagePattern(20, 20, 32, 32, 0, id, 1.0))
  c.fill()

  # Rotated pattern stroke.
  c.beginPath()
  c.roundedRect(180, 20, 120, 130, 16)
  c.setStrokePaint(c.imagePattern(180, 20, 32, 32, 0.6, id, 1.0))
  c.setStrokeWidth(14.0)
  c.stroke()

  # Nearest-neighbor shows the texels; bilinear smooths them.
  let flat = c.createImageMem(src.encodePng(), {ifNearest})
  c.beginPath()
  c.rect(20, 165, 64, 24)
  c.setFillPaint(c.imagePattern(20, 165, 64, 24, 0, flat, 1.0))
  c.fill()
  c.beginPath()
  c.rect(100, 165, 64, 24)
  c.setFillPaint(c.imagePattern(100, 165, 64, 24, 0, id, 1.0))
  c.fill()

  c.savePng(outDir / "images.png")
  echo "wrote ", outDir / "images.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
