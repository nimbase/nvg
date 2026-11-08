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
  let c = newCanvas(960, 2100)
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
  c.setFontSize(34.0)
  c.boxFrame(680, 652, 240, 110)
  var fo = TextBoxOpts(maxW: 224, boxH: 100, ha: thaCenter,
    va: tvaMiddle, fit: tfShrink, minSize: 30.0)
  discard c.fillTextBox(688, 652, "A Midsummer Night", fo)
  caption(c, 680, 636, "(shrink floor min 30)")
  c.setFontSize(19.0)
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

  # --- Clamp row: full vs 2-line ellipsis vs custom marker. ---
  caption(c, 40, 1190, "line clamp (full, 2 lines, custom marker)")
  const clampText = "Over hill, over dale\nthorough bush, thorough brier, " &
    "over park, over pale, thorough flood, thorough fire, over " &
    "hill, over dale, thorough bush, thorough brier"
  c.boxFrame(40, 1206, 260, 170)
  discard c.fillTextBox(48, 1212, 244, 160, clampText, thaLeft, tvaTop,
    true)
  c.boxFrame(340, 1206, 260, 170)
  var co = TextBoxOpts(maxW: 244, boxH: 160, maxLines: 2,
    overflow: toEllipsis, wrap: false)
  discard c.fillTextBox(348, 1212, clampText, co)
  c.boxFrame(640, 1206, 260, 170)
  co.ellipsis = " [...]"
  discard c.fillTextBox(648, 1212, clampText, co)

  # --- Paragraph row: gap between stanzas, indented first lines. ---
  caption(c, 40, 1408, "paragraph gap 12, first-line indent 24")
  c.boxFrame(40, 1424, 880, 170)
  var po = TextBoxOpts(maxW: 864, boxH: 160, paragraphGap: 12.0,
    firstLineIndent: 24.0)
  discard c.fillTextBox(48, 1430, Para & "\n" & Para, po)

  # --- Decor row: underline, strike, both. ---
  caption(c, 40, 1626, "decorations (underline, strike, both)")
  let ds = [tdUnderline, tdStrike, tdUnderStrike]
  for i, d in ds:
    let x = 40.0 + float64(i) * 300.0
    c.boxFrame(x, 1642, 260, 60)
    var dob = TextBoxOpts(maxW: 244, boxH: 48, decor: d)
    discard c.fillTextBox(x + 8, 1648, "Titania wakes", dob)

  # --- Whitespace row: pre with tabs, pre-wrap with breaks. ---
  caption(c, 40, 1740, "whitespace (pre tabs, pre-wrap double spaces)")
  var pre = TextBoxOpts(maxW: 300, boxH: 130, whiteSpace: twPre,
    tabWidth: 60.0)
  c.boxFrame(40, 1756, 320, 144)
  discard c.fillTextBox(48, 1762, "fn\tmain() {\n\tlet x\t= 1;\n}",
    pre)
  var prew = TextBoxOpts(maxW: 300, boxH: 130, whiteSpace: twPreWrap,
    breakWord: true)
  c.boxFrame(400, 1756, 320, 144)
  discard c.fillTextBox(408, 1762, "A  double  spaced  line plus " &
    "AVeryLongWordThatAbsolutelyMustBreakSomewhere ok", prew)

  # --- Hit-test row: red carets at probed byte offsets. ---
  caption(c, 40, 1932, "hit test (carets + byte offsets)")
  var ho = TextBoxOpts(maxW: 500, boxH: 60)
  c.boxFrame(40, 1948, 520, 90)
  let hfont = loadFontFile(fontPath)
  let hbl = layoutBoxOpts(hfont, 19.0, "Pack my box with five dozen",
    0.0, 1.35, 0.0, ho, [])
  c.setFillColor(rgbaf(0.65, 0.8, 1.0, 0.6))
  for r in selectionRects(hbl.lay, 0, 5, 0, 14):
    c.beginPath()
    c.rect(48 + r.x, 1954 + hbl.shift + r.y, r.w, r.h)
    c.fill()
  c.setFillColor(rgbf(0.1, 0.1, 0.1))
  discard c.fillTextBox(48, 1954, "Pack my box with five dozen", ho)
  c.setStrokeColor(rgbf(0.85, 0.2, 0.2))
  c.setStrokeWidth(1.5)
  c.setFontSize(13.0)
  c.setFillColor(rgbf(0.85, 0.2, 0.2))
  for qx in [5.0, 60.0, 130.0, 210.0, 330.0]:
    let h = hitTest(hbl.lay, qx, 12.0, thaLeft)
    let cx = caretX(hbl.lay, h, thaLeft)
    c.beginPath()
    c.moveTo(48 + cx, 1954)
    c.lineTo(48 + cx, 1980)
    c.stroke()
    discard c.fillText(48 + cx + 3, 1986, $h.byteIndex)

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
