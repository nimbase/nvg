## Text rendering tests with a fully synthetic TTF (no binary fixtures).
##
## Font (upem 1000, cmap format 4):
##   gid 0: empty (.notdef, advance 500)
##   gid 1 'A': triangle (0,0),(500,0),(250,700), advance 600
##   gid 2 'B': square 400x500 at origin, advance 700
##   gid 3 U+05D0: triangle (0,0),(200,0),(100,300), advance 500
##   gid 4 U+05D1: square 600x200 at origin, advance 700
## At size 20 advances are exact: 10 / 12 / 14 px.

import std/os
import std/unittest
import nvg
import ./fontbuilder

proc testCanvas(): Canvas =
  let c = newCanvas(60, 70)
  c.clear(rgb(255, 255, 255))
  discard c.createFontMem("t", buildTestFont())
  c.setFontFace("t")
  c.setFontSize(20.0)
  c.setFillColor(rgbf(0, 0, 0))
  c

proc close(a, b: float64, eps = 0.05): bool = abs(a - b) < eps

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

test "advances sum shaped glyphs":
  let c = testCanvas()
  check c.fillText(10, 30, "A") == 12.0
  check c.fillText(10, 30, "AB") == 26.0
  check c.fillText(10, 30, "A?B") == 36.0 # '?' -> empty .notdef, adv 10
  check c.fillText(10, 30, "") == 0.0
  check c.fillText(10, 30, "?") == 10.0

test "outline emission flips y around the baseline":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "A")
  var p = Path()
  p.appendLayout(identity(), lay, 10, 30, thaLeft, tvaBaseline)
  check p.commands.len == 4
  check p.commands[0].kind == pcMoveTo
  check abs(p.commands[0].p.x - 10.0) < 1e-9
  check abs(p.commands[0].p.y - 30.0) < 1e-9
  check p.commands[1].kind == pcLineTo
  check abs(p.commands[1].p.x - 20.0) < 1e-9
  check abs(p.commands[1].p.y - 30.0) < 1e-9
  check abs(p.commands[2].p.x - 15.0) < 1e-9
  check abs(p.commands[2].p.y - 16.0) < 1e-9 # apex 700 up -> 14 above
  check p.commands[3].kind == pcClose

test "bounds measure placed ink":
  let c = testCanvas()
  let b = c.textBounds(10, 30, "A")
  check close(b.x, 10.0) and close(b.y, 16.0)
  check close(b.w, 10.0) and close(b.h, 14.0)
  check c.textBounds(10, 30, "").w == 0.0

test "glyph pixels fill solid interior":
  let c = testCanvas()
  discard c.fillText(10, 30, "A")
  let inside = c.surface.getPixel(15, 25)
  check inside.r < 0.1 and inside.g < 0.1 and inside.b < 0.1
  let outside = c.surface.getPixel(5, 5)
  check outside.r > 0.9 and outside.g > 0.9 and outside.b > 0.9

test "text leaves the current path alone":
  let c = testCanvas()
  c.beginPath()
  c.rect(40, 50, 10, 10)
  discard c.fillText(10, 30, "A")
  c.setFillColor(rgbf(1, 0, 0))
  c.fill()
  check c.surface.getPixel(45, 55).r > 0.9
  check c.surface.getPixel(15, 25).r < 0.1 # text still drawn

test "multiline stacks by line height and aligns per line":
  let c = testCanvas()
  check c.fillText(10, 30, "A\nB") == 14.0 # widest line wins
  let b = c.textBounds(10, 30, "A\nB")
  check close(b.x, 10.0) and close(b.y, 16.0)
  check close(b.w, 10.0) and close(b.h, 38.0) # ink, not advance: A is wider
  c.setTextAlign(thaCenter)
  let cb = c.textBounds(10, 30, "A\nB")
  check close(cb.x, 3.0) and close(cb.y, 16.0)
  check close(cb.w, 11.0) and close(cb.h, 38.0)
  c.setTextAlign(thaRight)
  let rb = c.textBounds(10, 30, "A")
  check close(rb.x, -2.0) and close(rb.w, 10.0)

test "letter spacing separates advances, not marks":
  let c = testCanvas()
  c.setLetterSpacing(3.0)
  check c.fillText(10, 30, "AB") == 29.0
  let b = c.textBounds(10, 30, "AB")
  check close(b.x, 10.0) and close(b.w, 23.0)

test "rtl text draws in visual order":
  let font = loadFontBytes(buildTestFont())
  let lay = layoutText(font, 20.0, "אב")
  check lay.lines.len == 1
  check lay.lines[0].glyphs.len == 2
  check lay.lines[0].glyphs[0].gid == 4u32
  check lay.lines[0].glyphs[1].gid == 3u32
  check lay.lines[0].advance == 24.0

test "vertical align anchors to ink":
  let c = testCanvas()
  check close(c.textBounds(10, 30, "A").y, 16.0) # baseline
  c.setTextAlign(thaLeft, tvaTop)
  let t = c.textBounds(10, 30, "A")
  check close(t.y, 30.0) and close(t.h, 14.0)
  c.setTextAlign(thaLeft, tvaMiddle)
  check close(c.textBounds(10, 30, "A").y, 23.0)
  c.setTextAlign(thaLeft, tvaBottom)
  check close(c.textBounds(10, 30, "A").y, 16.0)

test "stateless api matches stateful pixels":
  let data = buildTestFont()
  let a = newCanvas(60, 70)
  a.clear(rgb(255, 255, 255))
  discard a.createFontMem("t", data)
  a.setFontFace("t")
  a.setFontSize(20.0)
  a.setFillColor(rgbf(0, 0, 0))
  discard a.fillText(10, 30, "A\nB")
  let font = loadFontBytes(data)
  let b = newCanvas(60, 70)
  b.clear(rgb(255, 255, 255))
  b.setFillColor(rgbf(0, 0, 0))
  discard b.fillText(font, 20.0, 10, 30, "A\nB")
  check a.encodePng() == b.encodePng()

test "stroke text outlines render":
  let c = testCanvas()
  c.setStrokeColor(rgbf(0, 0, 0))
  c.setStrokeWidth(2.0)
  check c.strokeText(10, 30, "AB") == 26.0
  var ink = 0
  for y in 0 ..< 70:
    for x in 0 ..< 60:
      if c.surface.getPixel(x, y).r < 0.5:
        inc ink
  check ink > 20

test "font registry failures are handles, not exceptions":
  let c = newCanvas(20, 20)
  c.clear(rgb(255, 255, 255))
  check c.createFontMem("bad", @[0u8, 1u8, 2u8]) == 0
  check c.createFont("missing", "/nonexistent/font.ttf") == 0
  check c.findFont("nope") == 0
  check c.fillText(2, 10, "A") == 0.0
  check c.surface.getPixel(10, 10).r > 0.9 # untouched
  let id = c.createFontMem("t", buildTestFont())
  check id != 0 and c.findFont("t") == id
  let id2 = c.createFontMem("t", buildTestFont())
  check id2 == id # re-register keeps the handle

test "text golden":
  let c = testCanvas()
  discard c.fillText(10, 30, "AB")
  c.setTextAlign(thaCenter)
  discard c.fillText(30, 60, "A\nB")
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  c.savePng(outDir / "text.png")
  check fileExists(outDir / "text.png")
