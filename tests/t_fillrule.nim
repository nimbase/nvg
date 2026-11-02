import std/unittest
import nvg

proc sq(c: Canvas, x, y, w, h: float64) =
  c.moveTo(x, y)
  c.lineTo(x + w, y)
  c.lineTo(x + w, y + h)
  c.lineTo(x, y + h)
  c.closePath()

proc revSq(c: Canvas, x, y, w, h: float64) =
  c.moveTo(x, y)
  c.lineTo(x, y + h)
  c.lineTo(x + w, y + h)
  c.lineTo(x + w, y)
  c.closePath()

proc nestedScene(sameWinding: bool, rule: FillRule,
    backend: Backend = nil): Canvas =
  result = newCanvas(20, 20, backend)
  result.clear(rgb(255, 255, 255))
  result.beginPath()
  sq(result, 2, 2, 16, 16)
  if sameWinding: sq(result, 7, 7, 6, 6)
  else: revSq(result, 7, 7, 6, 6)
  result.setFillColor(rgbf(1, 0, 0))
  result.fill(rule)

test "same winding: hole under even-odd, filled under nonzero":
  check nestedScene(true, frEvenOdd).surface.getPixel(10, 10).r > 0.9
  let nz = nestedScene(true, frNonZero).surface.getPixel(10, 10)
  check nz.r > 0.9 and nz.g < 0.1

test "opposite winding: hole under both rules":
  check nestedScene(false, frEvenOdd).surface.getPixel(10, 10).r > 0.9
  check nestedScene(false, frNonZero).surface.getPixel(10, 10).r > 0.9

test "outer ring paints under both rules":
  for rule in [frEvenOdd, frNonZero]:
    let p = nestedScene(true, rule).surface.getPixel(4, 4)
    check p.r > 0.9 and p.g < 0.1

test "disjoint subpaths fill under both rules":
  for rule in [frEvenOdd, frNonZero]:
    let c = newCanvas(30, 10)
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    sq(c, 2, 2, 8, 6)
    sq(c, 18, 2, 8, 6)
    c.setFillColor(rgbf(1, 0, 0))
    c.fill(rule)
    check c.surface.getPixel(6, 5).r > 0.9 and
      c.surface.getPixel(6, 5).g < 0.1
    check c.surface.getPixel(22, 5).r > 0.9 and
      c.surface.getPixel(22, 5).g < 0.1
    check c.surface.getPixel(14, 5).r > 0.9 # gap stays white

test "fillWithRule matches fill with explicit rule":
  let a = nestedScene(true, frNonZero)
  let b = newCanvas(20, 20)
  b.clear(rgb(255, 255, 255))
  b.beginPath()
  sq(b, 2, 2, 16, 16)
  sq(b, 7, 7, 6, 6)
  b.setFillColor(rgbf(1, 0, 0))
  b.fillWithRule(frNonZero)
  check a.surface.pixels == b.surface.pixels

test "default fill stays even-odd":
  let a = nestedScene(true, frEvenOdd)
  let b = newCanvas(20, 20)
  b.clear(rgb(255, 255, 255))
  b.beginPath()
  sq(b, 2, 2, 16, 16)
  sq(b, 7, 7, 6, 6)
  b.setFillColor(rgbf(1, 0, 0))
  b.fill()
  check a.surface.pixels == b.surface.pixels

test "polygon-level winding queries agree with pixels":
  var pth = Path()
  pth.moveTo(2, 2, identity())
  pth.lineTo(18, 2, identity())
  pth.lineTo(18, 18, identity())
  pth.lineTo(2, 18, identity())
  pth.closePath()
  pth.moveTo(7, 7, identity())
  pth.lineTo(13, 7, identity())
  pth.lineTo(13, 13, identity())
  pth.lineTo(7, 13, identity())
  pth.closePath()
  let polys = flatten(pth)
  check pointInEdges(10.5, 10.5, buildEdges(polys), frEvenOdd) == false
  check pointInEdges(10.5, 10.5, buildEdges(polys), frNonZero) == true
  check pointInNonZero(10.5, 10.5, polys) == true
  check pointInEvenOdd(10.5, 10.5, polys) == false

test "nonzero coverage follows the rule on edges":
  # Fractional squares: outer 2.5..15.5, inner 7.5..12.5 (same winding).
  # Pixel (7,10) straddles the inner edge at x=7.5: left subsamples are
  # in-outer-only, right subsamples in both. Even-odd covers 1/2,
  # nonzero covers fully.
  var pth = Path()
  pth.moveTo(2.5, 2.5, identity())
  pth.lineTo(15.5, 2.5, identity())
  pth.lineTo(15.5, 15.5, identity())
  pth.lineTo(2.5, 15.5, identity())
  pth.closePath()
  pth.moveTo(7.5, 7.5, identity())
  pth.lineTo(12.5, 7.5, identity())
  pth.lineTo(12.5, 12.5, identity())
  pth.lineTo(7.5, 12.5, identity())
  pth.closePath()
  let edges = buildEdges(flatten(pth))
  let eo = coverageEdges(7.0, 10.0, edges, frEvenOdd)
  let nz = coverageEdges(7.0, 10.0, edges, frNonZero)
  check abs(eo - 0.5) < 1e-9
  check abs(nz - 1.0) < 1e-9
  # And the pixel paints accordingly.
  for rule in [frEvenOdd, frNonZero]:
    let c = newCanvas(20, 20)
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.moveTo(2.5, 2.5)
    c.lineTo(15.5, 2.5)
    c.lineTo(15.5, 15.5)
    c.lineTo(2.5, 15.5)
    c.closePath()
    c.moveTo(7.5, 7.5)
    c.lineTo(12.5, 7.5)
    c.lineTo(12.5, 12.5)
    c.lineTo(7.5, 12.5)
    c.closePath()
    c.setFillColor(rgbf(1, 0, 0))
    c.fill(rule)
    let p = c.surface.getPixel(7, 10)
    if rule == frEvenOdd:
      # Half coverage of opaque red over white: (1.0, 0.5, 0.5).
      check abs(p.r - 1.0) < 0.05 and abs(p.g - 0.5) < 0.15
    else:
      check p.r > 0.9 and p.g < 0.1

test "jit matches scalar under both rules":
  for rule in [frEvenOdd, frNonZero]:
    for same in [true, false]:
      let cpu = nestedScene(same, rule)
      let jitB = newJitBackend()
      let jit = nestedScene(same, rule, jitB)
      check cpu.surface.pixels == jit.surface.pixels
      destroyJitBackend(jitB)

test "aa=false honors the rule":
  for rule in [frEvenOdd, frNonZero]:
    let c = newCanvas(20, 20)
    c.clear(rgb(255, 255, 255))
    c.setShapeAA(false)
    c.beginPath()
    sq(c, 2, 2, 16, 16)
    sq(c, 7, 7, 6, 6)
    c.setFillColor(rgbf(1, 0, 0))
    c.fill(rule)
    let inner = c.surface.getPixel(10, 10)
    if rule == frEvenOdd:
      check inner.r > 0.9
    else:
      check inner.r > 0.9 and inner.g < 0.1
