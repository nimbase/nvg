## Synthetic test TTF shared by the text test files (no binary fixtures).
##
## Font (upem 1000, cmap format 4):
##   gid 0: empty (.notdef, advance 500)
##   gid 1 'A': triangle (0,0),(500,0),(250,700), advance 600
##   gid 2 'B': square 400x500 at origin, advance 700
##   gid 3 U+05D0: triangle (0,0),(200,0),(100,300), advance 500
##   gid 4 U+05D1: square 600x200 at origin, advance 700
##   gid 5 U+65E5: square 500x500 at origin, advance 600
##   gid 6 U+672C: square 400x500 at origin, advance 600
##   gid 7 U+0301: empty (zero advance, stands in for a mark)
##   kern: one pair, B followed by A tightened by 100 units
## At size 20 advances are exact: 10 / 12 / 14 px (marks: 0).

proc putU16*(s: var seq[uint8], v: uint16) =
  s.add(uint8(v shr 8))
  s.add(uint8(v and 0xFFu16))

proc putI16*(s: var seq[uint8], v: int16) =
  s.putU16(cast[uint16](v))

proc putU32*(s: var seq[uint8], v: uint32) =
  s.putU16(uint16(v shr 16))
  s.putU16(uint16(v and 0xFFFFu32))

proc pad4*(s: var seq[uint8]) =
  while s.len mod 4 != 0:
    s.add(0u8)

proc simpleGlyph*(pts: seq[tuple[x, y: int32, on: bool]],
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

proc buildCmap*(): seq[uint8] =
  # Format 4 (segments sorted): A-B -> 1-2, U+0301 -> 7,
  # U+05D0-U+05D1 -> 3-4, U+65E5 -> 5, U+672C -> 6, plus sentinel.
  var sub: seq[uint8] = @[]
  sub.putU16(4u16)
  sub.putU16(64u16)
  sub.putU16(0u16)
  sub.putU16(12u16)
  sub.putU16(8u16)
  sub.putU16(2u16)
  sub.putU16(4u16)
  for e in [0x42u16, 0x0301u16, 0x5D1u16, 0x65E5u16, 0x672Cu16,
      0xFFFFu16]:
    sub.putU16(e)
  sub.putU16(0u16)
  for e in [0x41u16, 0x0301u16, 0x5D0u16, 0x65E5u16, 0x672Cu16,
      0xFFFFu16]:
    sub.putU16(e)
  for d in [-64i16, -762i16, -1485i16, -26080i16, -26406i16, 1i16]:
    sub.putI16(d)
  for _ in 0 ..< 6:
    sub.putU16(0u16)
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.add(sub)

proc buildCmapSingle*(cp: uint16): seq[uint8] =
  ## Format 4 with one segment mapping `cp` to gid 1, plus sentinel.
  var sub: seq[uint8] = @[]
  sub.putU16(4u16)
  sub.putU16(24u16)
  sub.putU16(0u16)
  sub.putU16(4u16)
  sub.putU16(4u16)
  sub.putU16(1u16)
  sub.putU16(0u16)
  for e in [cp, 0xFFFFu16]:
    sub.putU16(e)
  sub.putU16(0u16)
  for e in [cp, 0xFFFFu16]:
    sub.putU16(e)
  sub.putI16(int16(1 - int(cp)))
  sub.putI16(1i16)
  for _ in 0 ..< 2:
    sub.putU16(0u16)
  result = @[]
  result.putU16(0u16)
  result.putU16(1u16)
  result.putU16(3u16)
  result.putU16(1u16)
  result.putU32(12u32)
  result.add(sub)

proc buildTestFontSingle*(cp: uint16): seq[uint8] =
  ## Two-glyph font (empty .notdef + triangle, advance 600) mapping
  ## only `cp` to gid 1. Pair two of these for fallback tests.
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
  hhea.putU16(2u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(2u16)
  var hmtx = newSeq[uint8]()
  for a in [500u16, 600u16]:
    hmtx.putU16(a)
    hmtx.putI16(0i16)
  let tri = simpleGlyph(@[(0i32, 0i32, true), (500i32, 0i32, true),
    (250i32, 700i32, true)], @[2])
  var loca = newSeq[uint8]()
  loca.putU16(0u16)
  loca.putU16(0u16)
  loca.putU16(uint16(tri.len div 2))
  let cmap = buildCmapSingle(cp)
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca), ("glyf", tri),
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

proc buildTestFont*(): seq[uint8] =
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
  hhea.putU16(8u16)
  var maxp = newSeq[uint8]()
  maxp.putU32(0x00005000u32)
  maxp.putU16(8u16)
  var hmtx = newSeq[uint8]()
  for a in [500u16, 600u16, 700u16, 500u16, 700u16, 600u16, 600u16,
      0u16]:
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
  let sq5 = simpleGlyph(@[(0i32, 0i32, true), (500i32, 0i32, true),
    (500i32, 500i32, true), (0i32, 500i32, true)], @[3])
  let sq6 = simpleGlyph(@[(0i32, 0i32, true), (400i32, 0i32, true),
    (400i32, 500i32, true), (0i32, 500i32, true)], @[3])
  var glyf: seq[uint8] = @[]
  var offs = @[0, 0] # gid 0 is empty; seven glyphs need eight entries
  for g in [triA, sqB, tri3, sq4, sq5, sq6]:
    glyf.add(g)
    offs.add(glyf.len)
  offs.add(glyf.len) # gid 7 (mark) is empty too
  var loca = newSeq[uint8]()
  for o in offs:
    loca.putU16(uint16(o div 2))
  let cmap = buildCmap()
  var kern = newSeq[uint8]()
  kern.putU16(0u16) # version
  kern.putU16(1u16) # one subtable
  kern.putU16(0u16) # subtable version
  kern.putU16(20u16) # subtable length
  kern.add(0u8) # format 0
  kern.add(1u8) # coverage: horizontal
  kern.putU16(1u16) # one pair
  kern.putU16(2u16) # searchRange
  kern.putU16(0u16) # entrySelector
  kern.putU16(0u16) # rangeShift
  kern.putU16(2u16) # left: B
  kern.putU16(1u16) # right: A
  kern.putI16(-100i16) # tighten by 100 units (-2 px at size 20)
  var tables = @[
    ("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx),
    ("cmap", cmap), ("loca", loca), ("glyf", glyf), ("kern", kern),
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
