## Image pattern paints: tiling, rotation, tint, bilinear filtering.
##
## Run: nim c -r examples/patterns.nim [outDir]

import std/os
import nvg

proc checkerData(w, h: int): seq[uint8] =
  ## Procedural 2-color checkerboard (RGBA8).
  result = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let on = ((x div 4) + (y div 4)) mod 2 == 0
      let i = (y * w + x) * 4
      result[i] = if on: 220'u8 else: 40'u8
      result[i + 1] = if on: 60'u8 else: 120'u8
      result[i + 2] = if on: 60'u8 else: 200'u8
      result[i + 3] = 255'u8

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 300)
  c.clear(rgb(255, 255, 255))

  # Nearest-neighbor clamp (single tile stretched over the rect).
  let idClamp = c.createImageRGBA(8, 8, {ifNearest}, checkerData(8, 8))
  c.beginPath()
  c.rect(20, 20, 160, 110)
  c.setFillPaint(c.imagePattern(20, 20, 160, 110, 0.0, idClamp, 1.0))
  c.fill()

  # Bilinear (default filter) with repeat + rotation + translucent tint.
  let idRep = c.createImageRGBA(8, 8,
    {ifRepeatX, ifRepeatY}, checkerData(8, 8))
  c.beginPath()
  c.rect(220, 20, 160, 110)
  c.setFillPaint(c.imagePattern(220, 20, 32, 32, 0.4, idRep, 0.85))
  c.fill()

  # Flipped vertically, tinted darker.
  let idFlip = c.createImageRGBA(8, 8,
    {ifRepeatX, ifRepeatY, ifFlipY}, checkerData(8, 8))
  c.beginPath()
  c.circle(200, 215, 65)
  c.setFillPaint(c.imagePattern(135, 150, 24, 24, 0.0, idFlip, 0.7))
  c.fill()

  c.savePng(outDir / "patterns.png")
  echo "wrote ", outDir / "patterns.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
