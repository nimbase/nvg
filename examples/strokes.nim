## Stroke styles: caps, joins, and dashed lines.
##
## Run: nim c -r examples/strokes.nim [outDir]

import std/os
import nvg

proc main(outDir: string) =
  createDir(outDir)
  let c = newCanvas(400, 320)
  c.clear(rgb(255, 255, 255))

  # Round caps and joins on a polyline.
  c.beginPath()
  c.moveTo(20, 40)
  c.lineTo(120, 90)
  c.lineTo(220, 30)
  c.setStrokeColor(rgbf(0.1, 0.1, 0.1))
  c.setStrokeWidth(10.0)
  c.setLineCap(lcRound)
  c.setLineJoin(ljRound)
  c.stroke()

  # Miter join with a bevel fallback on a sharp corner.
  c.beginPath()
  c.moveTo(250, 80)
  c.lineTo(330, 20)
  c.lineTo(360, 90)
  c.setStrokeColor(rgbf(0.8, 0.2, 0.1))
  c.setStrokeWidth(8.0)
  c.setLineCap(lcButt)
  c.setLineJoin(ljMiter)
  c.setMiterLimit(4.0)
  c.stroke()

  # Dashed line with round caps.
  c.setLineDash([18.0, 10.0, 6.0, 10.0], 0.0)
  c.beginPath()
  c.moveTo(20, 170)
  c.lineTo(380, 170)
  c.setStrokeColor(rgbf(0.1, 0.4, 0.8))
  c.setStrokeWidth(5.0)
  c.setLineCap(lcRound)
  c.stroke()

  # Dashed rect outline (solid again after clearing the dash).
  c.setLineDash([], 0.0)
  c.beginPath()
  c.rect(20, 210, 360, 80)
  c.setStrokeColor(rgbf(0.2, 0.6, 0.2))
  c.setStrokeWidth(4.0)
  c.setLineJoin(ljBevel)
  c.stroke()

  c.savePng(outDir / "strokes.png")
  echo "wrote ", outDir / "strokes.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
