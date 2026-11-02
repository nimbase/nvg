import std/unittest
import nvg

proc hline(c: Canvas, x0, x1, y: float64) =
  c.beginPath()
  c.moveTo(x0, y)
  c.lineTo(x1, y)

proc redAt(c: Canvas, x, y: int): bool =
  let p = c.surface.getPixel(x, y)
  p.r > 0.9 and p.g < 0.5

test "on/off pattern paints dashes and gaps":
  let c = newCanvas(60, 10)
  c.clear(rgb(255, 255, 255))
  hline(c, 2.5, 57.5, 5.0)
  c.setStrokeColor(rgbf(1, 0, 0))
  c.setStrokeWidth(3.0)
  c.setLineDash([10.0, 5.0])
  c.stroke()
  check redAt(c, 5, 5) # in first on-run
  check not redAt(c, 14, 5) # in first gap (12.5..17.5)
  check redAt(c, 20, 5) # second on-run (17.5..27.5)

test "offset shifts the pattern":
  proc at(off: float64, x: int): bool =
    let c = newCanvas(60, 10)
    c.clear(rgb(255, 255, 255))
    hline(c, 2.5, 57.5, 5.0)
    c.setStrokeColor(rgbf(1, 0, 0))
    c.setStrokeWidth(3.0)
    c.setLineDash([10.0, 5.0], off)
    c.stroke()
    redAt(c, x, 5)
  check at(0.0, 5) == true
  check at(10.0, 5) == false # starts in the gap
  check at(15.0, 5) == true # wraps to pattern start
  check at(-5.0, 5) == at(10.0, 5) # negative wraps

test "closed rectangle dash is continuous":
  # rect() starts at top-left going DOWN the left edge; perimeter 120,
  # pattern 20: exactly 6 periods, wrapping on-phase at the corner.
  # Top edge runs last (dist 90..120, right to left): 90..100 gap,
  # 100..110 on, 110..120 gap.
  let c = newCanvas(40, 40)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.rect(5, 5, 30, 30)
  c.setStrokeColor(rgbf(1, 0, 0))
  c.setStrokeWidth(2.0)
  c.setLineDash([10.0, 10.0])
  c.stroke()
  check redAt(c, 5, 6) # corner starts on (dist ~1)
  check redAt(c, 5, 12) # left edge on (dist ~7)
  check not redAt(c, 5, 20) # left edge gap (dist ~15)
  check redAt(c, 16, 5) # top edge on (dist ~109)
  check not redAt(c, 26, 5) # top edge gap (dist ~99)

test "round caps extend dash ends past butt":
  proc extent(cap: LineCap): int =
    let c = newCanvas(40, 10)
    c.clear(rgb(255, 255, 255))
    hline(c, 2.5, 37.5, 5.0)
    c.setStrokeColor(rgbf(1, 0, 0))
    c.setStrokeWidth(4.0)
    c.setLineCap(cap)
    c.setLineDash([6.0, 20.0])
    c.stroke()
    # First dash covers 2.5..8.5; measure painted width on row 5.
    var lo = 40
    var hi = -1
    for x in 0 ..< 40:
      if redAt(c, x, 5):
        lo = min(lo, x)
        hi = max(hi, x)
    hi - lo
  check extent(lcRound) > extent(lcButt)

test "zero-width stroke stays a no-op with dashes":
  let c = newCanvas(10, 10)
  c.clear(rgb(255, 255, 255))
  hline(c, 1.0, 9.0, 5.0)
  c.setStrokeColor(rgbf(1, 0, 0))
  c.setStrokeWidth(0.0)
  c.setLineDash([4.0, 2.0])
  c.stroke()
  check c.surface.getPixel(5, 5).r > 0.9

test "dash normalization edge cases":
  check normalizeDash([]).len == 0
  check normalizeDash([4.0]) == @[4.0, 4.0] # single repeats on/off
  check normalizeDash([5.0, 3.0, 2.0]) ==
    @[5.0, 3.0, 2.0, 5.0, 3.0, 2.0] # odd doubles
  check normalizeDash([0.0, -2.0]).len == 0 # all dropped -> solid
  check normalizeDash([0.0, 5.0, 3.0]) == @[5.0, 3.0]
  check wrapOffset(25.0, 15.0) == 10.0
  check wrapOffset(-5.0, 15.0) == 10.0

test "empty dash paints solid":
  let c = newCanvas(60, 10)
  c.clear(rgb(255, 255, 255))
  hline(c, 2.5, 57.5, 5.0)
  c.setStrokeColor(rgbf(1, 0, 0))
  c.setStrokeWidth(3.0)
  c.setLineDash([])
  c.stroke()
  for x in [5, 14, 20, 30]:
    check redAt(c, x, 5)

test "dash state saves and restores":
  let c = newCanvas(10, 10)
  c.setLineDash([4.0, 2.0])
  c.save()
  c.setLineDash([])
  check c.lineDash().len == 0
  c.restore()
  check c.lineDash() == @[4.0, 2.0]

test "dashed stroke matches on jit backend":
  proc scene(backend: Backend): Canvas =
    result = newCanvas(60, 10, backend)
    result.clear(rgb(255, 255, 255))
    hline(result, 2.5, 57.5, 5.0)
    result.setStrokeColor(rgbf(1, 0, 0))
    result.setStrokeWidth(3.0)
    result.setLineDash([10.0, 5.0])
    result.stroke()
  let cpu = scene(nil)
  let jb = newJitBackend()
  let jit = scene(jb)
  check cpu.surface.pixels == jit.surface.pixels
  destroyJitBackend(jb)
