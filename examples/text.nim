## Text rendering with a real font (harfnim shaping + outlines).
##
## Shows font sizes, every horizontal x vertical alignment combo (with the
## anchor point and measured ink bounds drawn), letter spacing, line
## height, gradient fills, stroked outlines, and the stateless API.
##
## Run: nim c -r examples/text.nim -- /path/to/font.ttf [outDir]
## The font path can also come from the TEXT_FONT environment variable.

import std/os
import nvg

proc drawAnchor(c: Canvas, x, y: float64) =
  c.beginPath()
  c.moveTo(x - 7, y)
  c.lineTo(x + 7, y)
  c.moveTo(x, y - 7)
  c.lineTo(x, y + 7)
  c.setStrokeColor(rgbf(0.85, 0.2, 0.2))
  c.setStrokeWidth(1.5)
  c.stroke()

proc drawBounds(c: Canvas, b: Rect) =
  if b.w <= 0.0 or b.h <= 0.0:
    return
  c.beginPath()
  c.rect(b.x, b.y, b.w, b.h)
  c.setStrokeColor(rgbaf(0.2, 0.4, 0.9, 0.8))
  c.setStrokeWidth(1.0)
  c.stroke()

proc label(c: Canvas, x, y: float64, s: string) =
  c.setFontSize(15.0)
  c.setTextAlign(thaLeft, tvaBaseline)
  c.setLetterSpacing(0.0)
  c.setFillColor(rgbf(0.4, 0.4, 0.4))
  discard c.fillText(x, y, s)

const
  has = [thaLeft, thaCenter, thaRight]
  haNames = ["left", "center", "right"]
  vas = [tvaBaseline, tvaTop, tvaMiddle, tvaBottom]
  vaNames = ["baseline", "top", "middle", "bottom"]

proc main(fontPath, outDir: string) =
  createDir(outDir)
  let c = newCanvas(960, 1260)
  c.clear(rgb(255, 255, 255))

  let id = c.createFont("demo", fontPath)
  if id == 0:
    quit "cannot load font: " & fontPath
  c.setFontFace("demo")
  c.setLineHeight(1.2)
  c.setLetterSpacing(0.0)

  # --- Font sizes, all left/baseline anchored. ---
  label(c, 40, 34, "sizes (left/baseline)")
  for (size, y) in [(20.0, 70.0), (32.0, 125.0), (48.0, 200.0)]:
    c.setFontSize(size)
    c.setTextAlign(thaLeft, tvaBaseline)
    c.setFillColor(rgbf(0.1, 0.1, 0.1))
    discard c.fillText(40, y, "Agfi 123")

  # --- Alignment grid: every ha x va combo. Red cross is the anchor,
  # --- blue box is textBounds ink. Same "Ag" so only aligning moves. ---
  label(c, 40, 262, "alignment grid (anchor cross + ink bounds)")
  c.setFontSize(30.0)
  c.setLineHeight(1.2)
  c.setLetterSpacing(0.0)
  const cellW = 290.0
  const cellH = 104.0
  const gridY = 290.0
  for col, ha in has:
    label(c, 40 + float64(col) * cellW + cellW * 0.5 - 30, gridY - 8,
      haNames[col])
  for row, va in vas:
    label(c, 4, gridY + float64(row) * cellH + cellH * 0.5, vaNames[row])
    for col, ha in has:
      let ax = 40 + float64(col) * cellW + cellW * 0.5
      let ay = gridY + float64(row) * cellH + cellH * 0.5
      c.setTextAlign(ha, va)
      c.setFillColor(rgbf(0.1, 0.1, 0.1))
      drawBounds(c, c.textBounds(ax, ay, "Ag"))
      discard c.fillText(ax, ay, "Ag")
      drawAnchor(c, ax, ay)

  # --- Multiline + letter spacing + line height. ---
  let spY = gridY + 4 * cellH + 50
  label(c, 40, spY, "letter spacing 0 vs 5 (multiline, centered)")
  c.setFontSize(26.0)
  c.setTextAlign(thaCenter)
  c.setLineHeight(1.3)
  c.setFillColor(rgbf(0.7, 0.15, 0.2))
  c.setLetterSpacing(0.0)
  drawBounds(c, c.textBounds(250, spY + 40, "spaced\nlines"))
  discard c.fillText(250, spY + 40, "spaced\nlines")
  c.setLetterSpacing(5.0)
  c.setFillColor(rgbf(0.1, 0.3, 0.7))
  drawBounds(c, c.textBounds(700, spY + 40, "spaced\nlines"))
  discard c.fillText(700, spY + 40, "spaced\nlines")

  let lhY = spY + 150
  label(c, 40, lhY, "line height 1.0 vs 1.8 (left/baseline)")
  c.setTextAlign(thaLeft)
  c.setLetterSpacing(0.0)
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  c.setLineHeight(1.0)
  drawBounds(c, c.textBounds(40, lhY + 40, "tight\nlines"))
  discard c.fillText(40, lhY + 40, "tight\nlines")
  c.setLineHeight(1.8)
  drawBounds(c, c.textBounds(500, lhY + 40, "loose\nlines"))
  discard c.fillText(500, lhY + 40, "loose\nlines")

  # --- Paint modes: gradient fill, stroked outline, stateless call. ---
  let ptY = lhY + 190
  label(c, 40, ptY, "paints + stateless api")
  c.setFontSize(36.0)
  c.setLineHeight(1.2)
  c.setLetterSpacing(0.0)
  c.setTextAlign(thaLeft, tvaBaseline)
  c.setFillPaint(c.linearGradient(40, ptY, 500, ptY,
    rgbf(0.1, 0.3, 0.8), rgbf(0.1, 0.7, 0.4)))
  discard c.fillText(40, ptY + 60, "gradient")
  c.setTextAlign(thaLeft, tvaMiddle)
  c.setStrokeColor(rgbf(0.1, 0.5, 0.2))
  c.setStrokeWidth(1.5)
  discard c.strokeText(520, ptY + 60, "outline")

  # Stateless call draws the same pixels without touching canvas state.
  let font = loadFontFile(fontPath)
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  discard c.fillText(font, 20.0, 40, ptY + 120, "stateless left",
    thaLeft, tvaBaseline)
  discard c.fillText(font, 20.0, 920, ptY + 120, "stateless right",
    thaRight, tvaBaseline)

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
