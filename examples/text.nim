## Text rendering with a real font (harfnim shaping + outlines).
##
## Run: nim c -r examples/text.nim -- /path/to/font.ttf [outDir]
## The font path can also come from the TEXT_FONT environment variable.

import std/os
import nvg

proc main(fontPath, outDir: string) =
  createDir(outDir)
  let c = newCanvas(640, 420)
  c.clear(rgb(255, 255, 255))

  let id = c.createFont("demo", fontPath)
  if id == 0:
    quit "cannot load font: " & fontPath
  c.setFontFace("demo")

  # Baseline-anchored headline, left aligned.
  c.setFontSize(44.0)
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  discard c.fillText(40, 80, "AVfi 123")

  # Centered multiline block with extra line height.
  c.setFontSize(28.0)
  c.setTextAlign(thaCenter)
  c.setLineHeight(1.4)
  c.setFillColor(rgbf(0.7, 0.15, 0.2))
  discard c.fillText(320, 170, "Centered\nmultiline text")

  # Right-aligned + letter spacing, gradient-filled.
  c.setFontSize(24.0)
  c.setTextAlign(thaRight)
  c.setLetterSpacing(2.0)
  c.setLineHeight(1.2)
  c.setFillPaint(c.linearGradient(380, 220, 600, 220,
    rgbf(0.1, 0.3, 0.8), rgbf(0.1, 0.7, 0.4)))
  discard c.fillText(600, 280, "spaced right")

  # Stroked outline text, middle-anchored.
  c.setFontSize(36.0)
  c.setTextAlign(thaLeft, tvaMiddle)
  c.setLetterSpacing(0.0)
  c.setStrokeColor(rgbf(0.1, 0.5, 0.2))
  c.setStrokeWidth(1.5)
  discard c.strokeText(40, 360, "outline")

  # Stateless call draws the same pixels without touching state.
  let font = loadFontFile(fontPath)
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  discard c.fillText(font, 20.0, 40, 400, "stateless")

  c.savePng(outDir / "text.png")
  echo "wrote ", outDir / "text.png"

when isMainModule:
  var fontPath = getEnv("TEXT_FONT")
  var outDir = "examples/out"
  if paramCount() > 0:
    fontPath = paramStr(1)
  if paramCount() > 1:
    outDir = paramStr(2)
  if fontPath == "":
    quit "usage: text [font.ttf] [outDir]  (or set TEXT_FONT)"
  main(fontPath, outDir)
