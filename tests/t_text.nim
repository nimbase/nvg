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

# --------------------------------------------------------------------------
# Minimal TTF builder
# --------------------------------------------------------------------------

proc putU16(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

proc putI16(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc pad4(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc simpleGlyph(pts: seq[tuple[x, y: int32, on: bool]],
    ends: seq[int]): seq[uint8] =
  result = @[]
  result.putI16(int16(ends.len))
  var x0 = pts[0].x
  var y0 = pts[0].y
  var x1 = x0
  var y1 = y0
  for p in pts:
    x0 = min(x0, p.x)
    y0 = min(y0, p.y)
    x1 = max(x1, p.x)
    y1 = max(y1, p.y)
  result.putI16(int16(x0))
  result.putI16(int16(y0))
  result.putI16(int16(x1))
  result.putI16(int16(y1))
  for e in ends:
    result.putU16(uint16(e))
  result.putU16(0u16)
  for p in pts:
    result.add(if p.on: 1u8 else: 0u8)
  var px = 0i32
  for p in pts:
    result.putI16(int16(p.x - px))
    px = p.x
  var py = 0i32
  for p in pts:
    result.putI16(int16(p.y - py))
    py = p.y
  while result.len mod 2 != 0:
    result.add(0u8)

proc buildCmap(): seq[uint8] =
  # Format 4: A-B -> 1-2, U+05D0-U+05D1 -> 3-4, plus the 0xFFFF sentinel.
  var sub: seq[uint8] = @[]
  sub.putU16(4u16)
  sub.putU16(40u16)
  sub.putU16(0u16)
  sub.putU16(6u16)
  sub.putU16(4u16)
  sub.putU16(1u16)
  sub.putU16(2u16)
  for e in [0x42u16, 0x5D1u16, 0xFFFFu16]:
    sub.putU16(e)
  sub.putU16(0u16)
  for e in [0x41u16, 0x5D0u16, 0xFFFFu16]:
    sub.putU16(e)
  for d in [-64i16, -1485i16, 1i16]:
    sub.putI16(d)
  for _ in 0 ..< 3:
    sub.putU16(0u16)
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.add(sub)

proc buildTestFont(): seq[uint8] =
  var head = newSeq[uint8]()
  head.putU32(0x00010000u32)
  head.putU32(0u32)
  head.putU32(0u32)
  head.putU32(0x5F0F3CF5u32)
  head.putU16(0u16)
  head.putU16(1000u16)
  for _ in 0 ..< 4:
    head.putU32(0u32)
  for _ in 0 ..< 4:
    head.putI16(0i16)
  head.putU16(0u16)
  head.putU16(0u16)
  head.putI16(0i16)
  head.putI16(0i16)
  head.putU16(0u16)
  var hhea = newSeq[uint8]()
  hhea.putU32(0x00010000u32)
  hhea.putI16(800i16)
  hhea.putI16(-200i16)
  hhea.putI16(0i16)
  hhea.putU16(600u16)
  for _ in 0 ..< 11:
    hhea.putI16(0i16)
  hhea.putU16(5u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(5u16)
  var hmtx = newSeq[uint8]()
  for a in [500u16, 600u16, 700u16, 500u16, 700u16]:
    hmtx.putU16(a)
    hmtx.putI16(0i16)
  let triA = simpleGlyph(@[(0i32, 0i32, true), (500i32, 0i32, true),
    (250i32, 700i32, true)], @[2])
  let sqB = simpleGlyph(@[(0i32, 0i32, true), (400i32, 0i32, true),
    (400i32, 500i32, true), (0i32, 500i32, true)], @[3])
  let tri3 = simpleGlyph(@[(0i32, 0i32, true), (200i32, 0i32, true),
    (100i32, 300i32, true)], @[2])
  let sq4 = simpleGlyph(@[(0i32, 0i32, true), (600i32, 0i32, true),
    (600i32, 200i32, true), (0i32, 200i32, true)], @[3])
  var glyf: seq[uint8] = @[]
  var offs = @[0, 0] # gid 0 is empty; five glyphs need six loca entries
  for g in [triA, sqB, tri3, sq4]:
    glyf.add(g)
    offs.add(glyf.len)
  var loca = newSeq[uint8]()
  for o in offs:
    loca.putU16(uint16(o div 2))
  let cmap = buildCmap()
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca), ("glyf", glyf),
  ]
  result = @[]
  result.putU32(0x00010000u32)
  result.putU16(uint16(tables.len))
  result.putU16(32u16)
  result.putU16(1u16)
  result.putU16(16u16)
  var off = 12 + tables.len * 16
  for (name, data) in tables:
    for ch in name:
      result.add(uint8(ch))
    result.putU32(0u32)
    result.putU32(uint32(off))
    result.putU32(uint32((data.len + 3) and not 3))
    off += (data.len + 3) and not 3
  for (_, data) in tables:
    result.add(data)
    result.pad4()

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
