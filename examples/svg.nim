## SVG loading: render documents into pattern paints.
##
## Run: nim c -r examples/svg.nim [outDir]
## Self-contained: the SVG sources live in this file. One document
## renders straight to PNG via `renderSvg`; the same bytes round-trip
## through the image registry (`createImageSvg`) into a tiled pattern.

import std/os
import nvg

const badge = "<svg width=\"64\" height=\"64\" viewBox=\"0 0 64 64\">" &
  "<defs><linearGradient id=\"sky\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">" &
  "<stop offset=\"0\" stop-color=\"#3a7bd5\"/>" &
  "<stop offset=\"1\" stop-color=\"#aee1f9\"/>" &
  "</linearGradient></defs>" &
  "<rect width=\"64\" height=\"64\" fill=\"url(#sky)\"/>" &
  "<circle cx=\"46\" cy=\"16\" r=\"9\" fill=\"#ffdf5d\"/>" &
  "<path d=\"M0 64 L20 30 L34 52 L46 26 L64 64 Z\" fill=\"#2d6a4f\"/>" &
  "<g transform=\"translate(10 46) scale(0.8)\">" &
  "<rect x=\"-8\" y=\"-8\" width=\"16\" height=\"16\" fill=\"#f4a261\" " &
  "fill-opacity=\"0.9\"/>" &
  "</g></svg>"

proc main(outDir: string) =
  createDir(outDir)

  # Direct render at 4x for crisp edges.
  let s = renderSvg(badge, 256, 256)
  if s == nil:
    quit "failed to render bundled SVG"
  s.savePng(outDir / "svg_direct.png")
  echo "wrote ", outDir / "svg_direct.png"

  # Through the registry: tiled pattern fill plus a rotated stroke.
  let c = newCanvas(320, 200)
  c.clear(rgb(255, 255, 255))
  let id = c.createImageSvg(badge, 64, 64, {ifRepeatX, ifRepeatY})
  if id == 0:
    quit "failed to upload bundled SVG"
  c.beginPath()
  c.rect(20, 20, 130, 130)
  c.setFillPaint(c.imagePattern(20, 20, 32, 32, 0, id, 1.0))
  c.fill()
  c.beginPath()
  c.roundedRect(180, 20, 120, 130, 16)
  c.setStrokePaint(c.imagePattern(180, 20, 32, 32, 0.6, id, 1.0))
  c.setStrokeWidth(14.0)
  c.stroke()

  c.savePng(outDir / "svg.png")
  echo "wrote ", outDir / "svg.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
