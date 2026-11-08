## Text box tests on the synthetic font (see fontbuilder).
## Size 20: A = 12 advance / 10 ink, B = 14 / 8, space = 10 (no ink),
## A ink y -14..0, B ink y -10..0. All expectations hand-computed.

import std/unittest
import nvg
import ./fontbuilder

proc testCanvas(): Canvas =
  let c = newCanvas(120, 120)
  c.clear(rgb(255, 255, 255))
  discard c.createFontMem("t", buildTestFont())
  c.setFontFace("t")
  c.setFontSize(20.0)
  c.setFillColor(rgbf(0, 0, 0))
  c

proc close(a, b: float64, eps = 0.05): bool = abs(a - b) < eps

test "wrap splits on words, widest advance wins":
  let c = testCanvas()
  let m = c.measureTextBox(0, 0, 20, 200, "A B")
  check m.lineCount == 2
  check m.advance == 14.0
  let flat = c.measureTextBox(0, 0, 20, 200, "A B", wrap = false)
  check flat.lineCount == 1
  check flat.advance == 36.0

test "justify spreads sole and non-last lines to the box":
  let font = loadFontBytes(buildTestFont())
  let bl = layoutBox(font, 20.0, "A B", 0.0, 1.2, 0.0, 46.0, 0.0,
    thaJustify, tvaTop, false, toVisible, tfNone, 1.0, [])
  check bl.lay.lines.len == 1
  check bl.lay.lines[0].advance == 46.0
  check bl.lay.lines[0].glyphs.len == 3 # chunks keep the space glyph
  check close(bl.lay.lines[0].glyphs[2].x, 32.0) # B after 12 + gap 20
  check bl.lay.lines[0].glyphs[2].cluster == 2u32
  let ml = layoutBox(font, 20.0, "A B C\nA", 0.0, 1.2, 0.0, 46.0,
    0.0, thaJustify, tvaTop, true, toVisible, tfNone, 1.0, [])
  check ml.lay.lines.len == 3
  check ml.lay.lines[0].advance == 46.0 # wrapped, not last
  check ml.lay.lines[1].advance == 10.0 # last of para follows ha
  check ml.lay.lines[2].advance == 12.0 # sole single word: plain

test "ellipsis trims to the box":
  let font = loadFontBytes(buildTestFont())
  let bl = layoutBox(font, 20.0, "AB", 0.0, 1.2, 0.0, 20.0, 0.0,
    thaLeft, tvaTop, false, toEllipsis, tfNone, 1.0, [])
  check bl.lay.lines[0].advance == 10.0 # "A…" (22) -> "…" (10)
  check bl.lay.lines[0].glyphs.len == 1
  let fits = layoutBox(font, 20.0, "A", 0.0, 1.2, 0.0, 20.0, 0.0,
    thaLeft, tvaTop, false, toEllipsis, tfNone, 1.0, [])
  check fits.lay.lines[0].advance == 12.0

test "box vertical align anchors ink in the box":
  let c = testCanvas()
  let t = c.textBoxBounds(0, 100, 200, 28, "A", thaLeft, tvaTop)
  check close(t.y, 100.0) and close(t.h, 14.0)
  let m = c.textBoxBounds(0, 100, 200, 28, "A", thaLeft, tvaMiddle)
  check close(m.y, 107.0) and close(m.h, 14.0)
  let b = c.textBoxBounds(0, 100, 200, 28, "A", thaLeft, tvaBottom)
  check close(b.y, 114.0) and close(b.h, 14.0)

test "shrink fits whole pixels, stretch fills":
  let c = testCanvas()
  let sh = c.measureTextBox(0, 0, 20, 200, "AB", fit = tfShrink)
  check sh.sizePx == 15.0 # 16 -> 20.8 wide, 15 -> 19.5 wide
  check sh.advance == 19.5
  let noop = c.measureTextBox(0, 0, 20, 200, "A", fit = tfShrink)
  check noop.sizePx == 20.0
  let st = c.measureTextBox(0, 0, 20, 200, "A", fit = tfStretch)
  check st.sizePx == 33.0 # 0.6 px/px: 33 -> 19.8, 34 -> 20.4
  check st.advance <= 20.0

test "scaleX scales advance and ink, not height":
  let c = testCanvas()
  let m = c.measureTextBox(0, 0, 200, 200, "A", scaleX = 2.0)
  check m.advance == 24.0
  check close(m.width, 20.0)
  check close(m.height, 14.0)

test "absolute line height overrides the multiplier":
  let c = testCanvas()
  c.setLineHeightPx(40.0)
  let b = c.textBounds(10, 30, "A\nB")
  check close(b.h, 54.0) # -14 .. 40
  c.setLineHeight(1.2)
  check close(c.textBounds(10, 30, "A\nB").h, 38.0)

test "measureText reports advance, ink, breaks, size":
  let c = testCanvas()
  let m = c.measureText("A\nB")
  check m.advance == 14.0
  check close(m.width, 10.0)
  check close(m.height, 38.0)
  check m.lineCount == 2
  check m.sizePx == 20.0

test "clip keeps paint inside the box":
  let a = testCanvas()
  discard a.fillTextBox(10, 30, 15, 40, "AB", thaLeft, tvaTop, false,
    toClip)
  check a.surface.getPixel(27, 39).r > 0.9 # B ink would sit here
  let b = testCanvas()
  discard b.fillTextBox(10, 30, 15, 40, "AB", thaLeft, tvaTop, false,
    toVisible)
  check b.surface.getPixel(27, 39).r < 0.1
  check b.surface.getPixel(15, 35).r < 0.1 # A ink in both
  check a.surface.getPixel(15, 35).r < 0.1

test "stateless box matches stateful pixels":
  let data = buildTestFont()
  let a = newCanvas(120, 120)
  a.clear(rgb(255, 255, 255))
  discard a.createFontMem("t", data)
  a.setFontFace("t")
  a.setFontSize(20.0)
  a.setFillColor(rgbf(0, 0, 0))
  discard a.fillTextBox(10, 40, 80, 60, "A B A", thaJustify)
  let font = loadFontBytes(data)
  let b = newCanvas(120, 120)
  b.clear(rgb(255, 255, 255))
  b.setFillColor(rgbf(0, 0, 0))
  discard b.fillTextBox(font, 20.0, 10, 40, 80, 60, "A B A",
    thaJustify)
  check a.encodePng() == b.encodePng()

test "center and right position lines within the box":
  let font = loadFontBytes(buildTestFont())
  let cb = layoutBox(font, 20.0, "A", 0.0, 1.2, 0.0, 46.0, 0.0,
    thaCenter, tvaTop, false, toVisible, tfNone, 1.0, [])
  check close(cb.lay.lines[0].glyphs[0].x, 17.0) # (46-12)/2
  let rb = layoutBox(font, 20.0, "A", 0.0, 1.2, 0.0, 46.0, 0.0,
    thaRight, tvaTop, false, toVisible, tfNone, 1.0, [])
  check close(rb.lay.lines[0].glyphs[0].x, 34.0) # 46-12
  let c = testCanvas()
  let bb = c.textBoxBounds(10, 50, 46, 60, "A", thaCenter, tvaTop,
    false)
  check close(bb.x, 27.0) and close(bb.w, 10.0)

test "justify ink spans from first to last word":
  let c = testCanvas()
  let b = c.textBoxBounds(0, 50, 46, 60, "A B", thaJustify, tvaTop,
    false)
  check close(b.x, 0.0) and close(b.w, 40.0) # A at 0, B ends 32+8

test "line clamp keeps the head, ellipsis trims the tail":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 20, maxLines: 2)
  let m = c.measureTextBox(0, 0, "A\nB\nC", o)
  check m.lineCount == 2
  o = TextBoxOpts(maxW: 20, maxLines: 1, overflow: toEllipsis)
  let e = c.measureTextBox(0, 0, "AB\nCD", o)
  check e.lineCount == 1
  check e.advance == 10.0 # "AB" -> "A…" (22) -> "…" (10)
  o = TextBoxOpts(maxW: 20, maxLines: 1)
  let cut = c.measureTextBox(0, 0, "AB\nCD", o)
  check cut.lineCount == 1
  check cut.advance == 26.0 # silent cut: no trimming

test "custom ellipsis marker":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 20, overflow: toEllipsis, ellipsis: ">")
  let m = c.measureTextBox(0, 0, "AB", o)
  check m.advance == 10.0 # "A>" is 22, ">" alone is 10

test "fit honors min and max size bounds":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 20, fit: tfShrink, minSize: 18.0)
  let mn = c.measureTextBox(0, 0, "AB", o)
  check mn.sizePx == 18.0 # floor wins over fitting (19.5 needs 15)
  o = TextBoxOpts(maxW: 20, fit: tfStretch, maxSize: 25.0)
  let mx = c.measureTextBox(0, 0, "A", o)
  check mx.sizePx == 25.0 # ceiling wins over filling (33)

test "paragraph gap spreads baselines":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 200, va: tvaBaseline, paragraphGap: 10.0)
  let b = c.textBoxBounds(0, 30, "A\nB", o)
  check close(b.y, 16.0) # A ink top stays
  check close(b.h, 48.0) # -14 .. (24 + 10 gap) + 10 B ink

test "first-line indent shifts and narrows":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 200, firstLineIndent: 10.0)
  let b = c.textBoxBounds(0, 30, "A", o)
  check close(b.x, 10.0)
  o = TextBoxOpts(maxW: 30, firstLineIndent: 10.0)
  let m = c.measureTextBox(0, 0, "A B", o)
  check m.lineCount == 2 # first line budgets 30 - 10 = 20
  let bl = layoutBoxOpts(loadFontBytes(buildTestFont()), 20.0, "A B",
    0.0, 1.2, 0.0, o, [])
  check close(bl.lay.lines[0].glyphs[0].x, 10.0)
  check close(bl.lay.lines[1].glyphs[0].x, 0.0)

test "pre-wrap preserves space runs":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 50, whiteSpace: twPreWrap)
  let m = c.measureTextBox(0, 0, "A  B", o)
  check m.lineCount == 1
  check m.advance == 46.0 # 12 + two spaces + 14
  let n = TextBoxOpts(maxW: 50)
  check c.measureTextBox(0, 0, "A  B", n).advance == 36.0
  o = TextBoxOpts(maxW: 40, whiteSpace: twPreWrap)
  let w = c.measureTextBox(0, 0, "A  B", o)
  check w.lineCount == 2 # "A" then "B"

test "tabs stop at multiples":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 300, tabWidth: 40.0)
  let bl = layoutBoxOpts(loadFontBytes(buildTestFont()), 20.0, "A\tB",
    0.0, 1.2, 0.0, o, [])
  check bl.lay.lines.len == 1
  check bl.lay.lines[0].glyphs.len == 5 # A + 3 spaces + B
  # A ends at 12, next stop is 40: 3 spaces (30) put B at 42.
  check close(bl.lay.lines[0].glyphs[4].x, 42.0)

test "break-word hyphenates over-wide words":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 25, breakWord: true)
  let m = c.measureTextBox(0, 0, "AB", o)
  check m.lineCount == 2
  let bl = layoutBoxOpts(loadFontBytes(buildTestFont()), 20.0, "AB",
    0.0, 1.2, 0.0, o, [])
  check bl.lay.lines[0].advance == 22.0 # "A-"
  check bl.lay.lines[1].advance == 14.0 # "B"
  o = TextBoxOpts(maxW: 25, breakWord: true, hyphenChar: "")
  let b = c.measureTextBox(0, 0, "AB", o)
  check b.lineCount == 2
  o = TextBoxOpts(maxW: 25)
  check c.measureTextBox(0, 0, "AB", o).lineCount == 1 # overflow

test "hit test maps points to glyphs":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "AB")
  let h0 = hitTest(lay, 5, -7)
  check h0.line == 0 and h0.index == 0 and h0.before
  check h0.byteIndex == 0
  check caretX(lay, h0) == 0.0
  let h1 = hitTest(lay, 20, -7)
  check h1.line == 0 and h1.index == 1 and not h1.before
  check h1.byteIndex == 1
  check caretX(lay, h1) == 26.0
  let h2 = hitTest(lay, 200, 500) # clamped to the last line/glyph
  check h2.line == 0 and h2.index == 1 and not h2.before

test "hit test covers wrapped lines and empties":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "A\n\nB")
  check lay.lines.len == 3
  let h = hitTest(lay, 2, 30) # second line slot, empty
  check h.line == 1 and h.byteIndex == -1
  check caretX(lay, h) == 0.0
  let hb = hitTest(lay, 2, 60) # third line at 2.4 * 20 = 48..
  check hb.line == 2 and hb.byteIndex == 0

test "textHitBox works in box coordinates":
  let hc = testCanvas()
  var ho = TextBoxOpts(maxW: 200, boxH: 28, va: tvaMiddle)
  let hh = hc.textHitBox(5, 14, "AB", ho)
  check hh.line == 0 and hh.index == 0 and hh.byteIndex == 0

test "decorations paint rules, bounds ignore them":
  let c = testCanvas()
  var o = TextBoxOpts(maxW: 200, va: tvaBaseline, decor: tdUnderline)
  discard c.fillTextBox(10, 30, "A", o)
  check c.surface.getPixel(15, 31).r < 0.5 # rule row, in ink x
  let plain = testCanvas()
  let po = TextBoxOpts(maxW: 200, va: tvaBaseline)
  discard plain.fillTextBox(10, 30, "A", po)
  check plain.surface.getPixel(15, 31).r > 0.9
  let b = c.textBoxBounds(10, 30, "A", o)
  check close(b.y, 16.0) and close(b.h, 14.0) # rules ignored
  var s = TextBoxOpts(maxW: 200, va: tvaBaseline, decor: tdStrike)
  let st = testCanvas()
  discard st.fillTextBox(10, 30, "A A", s)
  check st.surface.getPixel(26, 24).r < 0.5 # inter-word gap, struck
  let nost = testCanvas()
  let no = TextBoxOpts(maxW: 200, va: tvaBaseline)
  discard nost.fillTextBox(10, 30, "A A", no)
  check nost.surface.getPixel(26, 24).r > 0.9
