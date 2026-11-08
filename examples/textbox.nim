## Text box gallery: wrap, align, justify, box valign, overflow,
## fit and scaleX behind one layout call each.
##
## Run: nim c -r examples/textbox.nim -- /path/to/font.ttf [outDir]
## The font path can also come from the TEXT_FONT environment variable.

import std/os
import nvg

const Para = "Over hill, over dale, thorough bush, thorough brier, " &
  "over park, over pale, thorough flood, thorough fire."

proc boxFrame(c: Canvas, x, y, w, h: float64) =
  c.beginPath()
  c.rect(x, y, w, h)
  c.setStrokeColor(rgbaf(0.25, 0.45, 0.9, 0.8))
  c.setStrokeWidth(1.0)
  c.stroke()

proc caption(c: Canvas, x, y: float64, s: string) =
  c.save()
  c.setFontSize(14.0)
  c.setTextAlign(thaLeft, tvaBaseline)
  c.setLetterSpacing(0.0)
  c.setLineHeight(1.2)
  c.setFillColor(rgbf(0.4, 0.4, 0.4))
  discard c.fillText(x, y, s)
  c.restore()

proc main(fontPath, outDir: string) =
  createDir(outDir)
  let c = newCanvas(960, 1180)
  c.clear(rgb(255, 255, 255))
  let id = c.createFont("demo", fontPath)
  if id == 0:
    quit "cannot load font: " & fontPath
  c.setFontFace("demo")
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  c.setFontSize(19.0)
  c.setLineHeight(1.35)

  # --- Align row: left / center / right / justify in equal boxes. ---
  caption(c, 40, 34, "align in box (left, center, right, justify)")
  c.setFontSize(17.0)
  c.setLineHeight(1.35)
  const bw = 200.0
  const bh = 200.0
  let has = [thaLeft, thaCenter, thaRight, thaJustify]
  for i, ha in has:
    let x = 40.0 + float64(i) * (bw + 20.0)
    c.boxFrame(x, 50, bw, bh)
    discard c.fillTextBox(x + 8, 56, bw - 16, bh - 12, Para, ha)

  # --- Vertical align row: one fixed box, top / middle / bottom. ---
  c.setFontSize(19.0)
  caption(c, 40, 292,
    "vertical align in 150px box, left to right: top, middle, bottom")
  let vas = [tvaTop, tvaMiddle, tvaBottom]
  for i, va in vas:
    let x = 40.0 + float64(i) * 300.0
    c.boxFrame(x, 312, 260, 150)
    discard c.fillTextBox(x + 8, 312, 244, 150, "Titania\nwakes",
      thaCenter, va)

  # --- Overflow row: visible / clip / ellipsis on one line. ---
  caption(c, 40, 512,
    "overflow in 200px box, left to right: visible, clip, ellipsis")
  let ovs = [toVisible, toClip, toEllipsis]
  for i, ov in ovs:
    let x = 40.0 + float64(i) * 300.0
    c.boxFrame(x, 544, 200, 60)
    c.setFontSize(20.0)
    discard c.fillTextBox(x + 6, 550, 188, 48,
      "seek some dewdrops here", thaLeft, tvaTop, false, ov)
    c.setFontSize(19.0)

  # --- Fit row: shrink a headline, stretch a word, scaleX pair. ---
  caption(c, 40, 636, "fit shrink vs natural (240px box)")
  c.boxFrame(40, 652, 240, 110)
  c.setFontSize(34.0)
  discard c.fillTextBox(48, 652, 224, 100, "A Midsummer Night",
    thaCenter, tvaMiddle, false, toVisible, tfShrink)
  c.boxFrame(360, 652, 240, 110)
  discard c.fillTextBox(368, 652, 224, 100, "A Midsummer Night",
    thaCenter, tvaMiddle, false)
  caption(c, 360, 636, "(same call without fit)")
  c.setFontSize(19.0)

  caption(c, 40, 806, "scaleX 1.0 vs 0.75 vs 1.35 (geometric)")
  for i, sx in [1.0, 0.75, 1.35]:
    let x = 40.0 + float64(i) * 300.0
    c.boxFrame(x, 822, 260, 90)
    discard c.fillTextBox(x + 8, 828, 244, 78, "the moon's sphere",
      thaLeft, tvaTop, true, toVisible, tfNone, sx)

  # --- Measure row: reported advance, ink, lines, fitted size. ---
  caption(c, 40, 956, "measureTextBox report")
  let m = c.measureTextBox(40, 972, 500, 300, Para & "\n" & Para,
    thaJustify)
  c.boxFrame(40, 972, 500, 180)
  discard c.fillTextBox(48, 978, 484, 168, Para & "\n" & Para,
    thaJustify)
  c.setFontSize(15.0)
  c.setFillColor(rgbf(0.4, 0.4, 0.4))
  discard c.fillText(570, 1000, "advance " & $m.advance & "px")
  discard c.fillText(570, 1024, "ink " & $m.width & " x " & $m.height)
  discard c.fillText(570, 1048, "lines " & $m.lineCount)
  discard c.fillText(570, 1072, "size " & $m.sizePx & "px")
  let q = c.measureText("Ag")
  discard c.fillText(570, 1100, "measureText Ag: " & $q.advance &
    "px, " & $q.lineCount & " line")

  c.savePng(outDir / "textbox.png")
  echo "wrote ", outDir / "textbox.png"

when isMainModule:
  var fontPath = getEnv("TEXT_FONT")
  var outDir = "examples/out"
  if paramCount() > 0:
    fontPath = paramStr(1)
  if paramCount() > 1:
    outDir = paramStr(2)
  if fontPath == "":
    quit "usage: textbox [font.ttf] [outDir]  (or set TEXT_FONT)"
  main(fontPath, outDir)
