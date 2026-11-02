import std/math
import std/unittest
import nvg

proc linePolys(x0, y0, x1, y1: float64): seq[SubPoly] =
  var p = Path()
  p.moveTo(x0, y0, identity())
  p.lineTo(x1, y1, identity())
  flatten(p)

proc close(a, b: float64, eps = 1e-9): bool = abs(a - b) < eps

test "line length is exact":
  check close(polyLength(linePolys(0, 0, 30, 40)), 50.0)

test "multisubpath lengths sum":
  var p = Path()
  p.moveTo(0, 0, identity())
  p.lineTo(3, 4, identity()) # 5
  p.moveTo(0, 0, identity())
  p.lineTo(6, 8, identity()) # 10
  check close(polyLength(flatten(p)), 15.0)

test "cubic length converges within tolerance":
  var p = Path()
  p.moveTo(0, 0, identity())
  p.bezierTo(0, 50, 50, 50, 50, 0, identity())
  let coarse = polyLength(flatten(p, 0.25, DefaultDistTol))
  let fine = polyLength(flatten(p, 0.01, DefaultDistTol))
  check abs(coarse - fine) / fine < 0.01
  check coarse > 90.0 and coarse < 115.0

test "position at 0, 0.5, 1":
  let polys = linePolys(0, 0, 30, 40)
  let a = pointAtLen(polys, 0.0)
  check close(a.x, 0.0) and close(a.y, 0.0)
  let m = pointAtLen(polys, 25.0)
  check close(m.x, 15.0) and close(m.y, 20.0)
  let e = pointAtLen(polys, 50.0)
  check close(e.x, 30.0) and close(e.y, 40.0)
  check close(pointAtNorm(polys, 0.5).x, 15.0)
  # Clamping.
  check close(pointAtLen(polys, -5.0).x, 0.0)
  check close(pointAtLen(polys, 99.0).x, 30.0)

test "tangent direction is the edge unit vector":
  let polys = linePolys(0, 0, 30, 40)
  let t = tangentAtLen(polys, 25.0)
  check close(t.x, 0.6) and close(t.y, 0.8)
  check close(tangentAtNorm(polys, 0.0).x, 0.6)
  # Degenerate input gives zero.
  check tangentAtLen(@[], 0.0) == pt(0, 0)

test "zero-length subpath extraction is empty":
  let polys = linePolys(0, 0, 30, 40)
  check extract(polys, 10.0, 10.0).len == 0
  # Reversed order normalizes to the same interval.
  let fwd = extract(polys, 10.0, 20.0)
  let rev = extract(polys, 20.0, 10.0)
  check rev.len == fwd.len
  check abs(polyLength(rev) - polyLength(fwd)) < 1e-9

test "split and rejoin round trip":
  let polys = linePolys(0, 0, 30, 40)
  let e1 = extract(polys, 0.0, 25.0)
  let e2 = extract(polys, 25.0, 50.0)
  check close(polyLength(e1), 25.0)
  check close(polyLength(e2), 25.0)
  check close(polyLength(e1) + polyLength(e2), 50.0)
  # Cut point shared within epsilon.
  check close(e1[^1].pts[^1].x, e2[0].pts[0].x)
  check close(e1[^1].pts[^1].y, e2[0].pts[0].y)

test "extracted midpoint interpolates":
  let polys = linePolys(0, 0, 30, 40)
  let e = extract(polys, 10.0, 20.0)
  check e.len == 1
  check close(e[0].pts[0].x, 6.0) and close(e[0].pts[0].y, 8.0)
  check close(e[0].pts[^1].x, 12.0) and close(e[0].pts[^1].y, 16.0)
