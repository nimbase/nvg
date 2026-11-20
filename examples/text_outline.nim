## Text as vector outlines: capture, SVG and JSON export.
##
## Loads a real font, captures a spanned sample as outlines, and writes
## a standalone SVG document plus the JSON envelope next to a PNG
## reference rendering. Usage:
##   nim c -r examples/text_outline.nim -- /path/to/font.ttf [outDir]
## The font path can also come from the TEXT_FONT environment variable.

import std/json
import std/os
import nvg

proc main(fontPath, outDir: string) =
  createDir(outDir)
  let font = loadFontFile(fontPath)
  let red = rgbf(0.8, 0.15, 0.2)
  let blue = rgbf(0.1, 0.3, 0.8)
  let spans = [TextSpan(first: 0, last: 5, color: red, hasColor: true),
    TextSpan(first: 6, last: 12, color: blue, hasColor: true)]
  let lay = layoutSpans(font, 48.0, "Hello, outlines!", spans)
  let o = captureOutlines(lay, 20.0, 80.0)
  writeFile(outDir / "text_outline.svg", outlinesSvg(o))
  writeFile(outDir / "text_outline.json", $outlinesJson(o))
  echo "groups: ", o.groups.len, " verbs: ", o.path.commands.len
  echo "advance: ", o.advance, " bounds: ", o.bounds.x, " ", o.bounds.y,
    " ", o.bounds.w, " ", o.bounds.h
  let c = newCanvas(480, 160)
  c.clear(rgbaf(0, 0, 0, 0))
  discard c.fillSpans(font, 48.0, 20.0, 80.0, "Hello, outlines!", spans)
  c.savePng(outDir / "text_outline.png")
  echo "wrote ", outDir / "text_outline.svg, .json, .png"

when isMainModule:
  var fontPath = getEnv("TEXT_FONT")
  var outDir = "examples/out"
  if paramCount() > 0:
    fontPath = paramStr(1)
  if paramCount() > 1:
    outDir = paramStr(2)
  if fontPath == "":
    quit "usage: text_outline [font.ttf] [outDir]  (or set TEXT_FONT)"
  main(fontPath, outDir)
