import std/math
import std/unittest
import nvg

proc hasNaN(polys: seq[SubPoly]): bool =
  for s in polys:
    for q in s.pts:
      if q.x != q.x or q.y != q.y:
        return true
  false

test "polygon vertices land at rotation offsets":
  var p = Path()
  p.polygon(50, 50, 40, 4, 0.0, identity())
  check p.commands.len == 5 # 1 moveTo + 3 lineTo + 1 close
  let polys = flatten(p)
  check polys.len == 1 and polys[0].pts.len == 4
  check abs(polys[0].pts[0].x - 90.0) < 1e-9
  check abs(polys[0].pts[0].y - 50.0) < 1e-9
  var q = Path()
  q.polygon(50, 50, 40, 4, PI / 2.0, identity())
  let qp = flatten(q)[0].pts[0]
  check abs(qp.x - 50.0) < 1e-9 and abs(qp.y - 90.0) < 1e-9

test "star alternates outer and inner radii":
  var p = Path()
  p.star(50, 50, 40, 16, 5, 0.0, identity())
  let polys = flatten(p)
  check polys.len == 1 and polys[0].pts.len == 10
  for i, v in polys[0].pts:
    let d = sqrt((v.x - 50.0)^2 + (v.y - 50.0)^2)
    if i mod 2 == 0:
      check abs(d - 40.0) < 1e-6
    else:
      check abs(d - 16.0) < 1e-6

test "rounded corners emit curves, sharp emits lines":
  var sharp = Path()
  sharp.polygon(50, 50, 40, 5, 0.0, identity())
  var nLine = 0
  for c in sharp.commands:
    if c.kind == pcCubicTo: inc nLine
  check nLine == 0
  var round = Path()
  round.polygon(50, 50, 40, 5, 0.0, identity(), 1.0)
  var nCubic = 0
  for c in round.commands:
    if c.kind == pcCubicTo: inc nCubic
  check nCubic == 5
  check not hasNaN(flatten(round))

test "star roundness params round outer and inner tips":
  var p = Path()
  p.star(50, 50, 40, 16, 5, 0.0, identity(), 1.0, 1.0)
  var nCubic = 0
  for c in p.commands:
    if c.kind == pcCubicTo: inc nCubic
  check nCubic == 10

test "degenerate zero radius has no NaN":
  var p = Path()
  p.polygon(10, 10, 0, 5, 0.0, identity())
  p.star(10, 10, 0, 0, 5, 0.0, identity())
  p.polygon(10, 10, 10, 2, 0.0, identity()) # n < 3
  p.star(10, 10, 10, 5, 1, 0.0, identity()) # n < 3
  check not hasNaN(flatten(p))

test "degenerate fill paints nothing, stroke dots":
  let c = newCanvas(20, 20)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.star(10, 10, 0, 0, 5, 0.0)
  c.setFillColor(rgbf(1, 0, 0))
  c.fill()
  check c.surface.getPixel(10, 10).r > 0.9
  c.beginPath()
  c.polygon(10, 10, 0, 5, 0.0)
  c.setStrokeColor(rgbf(1, 0, 0))
  c.setStrokeWidth(4.0)
  c.stroke()
  check c.surface.getPixel(10, 10).r > 0.9 and
    c.surface.getPixel(10, 10).g < 0.1

test "star fills and strokes render":
  let c = newCanvas(100, 100)
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.star(50, 50, 40, 16, 5, -PI / 2.0)
  c.setFillColor(rgbf(0, 0.6, 0))
  c.fill()
  check c.surface.getPixel(50, 50).g > 0.5
  # Tip pointing up lands near (50, 10).
  check c.surface.getPixel(50, 14).g > 0.5
