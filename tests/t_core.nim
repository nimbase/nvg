import std/unittest
import nvg

proc close(a, b: float64, eps = 1e-9): bool = abs(a - b) < eps

test "identity and translate compose":
  let m = multiply(translate(10, 0), scale(2, 2))
  let p = m.apply(pt(1, 1))
  check close(p.x, 12.0) and close(p.y, 2.0)

test "inverse round-trips points":
  let m = multiply(translate(5, -3), rotate(0.7))
  var inv = identity()
  check inverse(m, inv)
  let p = pt(17, 42)
  let q = inv.apply(m.apply(p))
  check close(q.x, p.x, 1e-6) and close(q.y, p.y, 1e-6)

test "singular matrix reports failure":
  var inv = identity()
  check not inverse(scale(0, 1), inv)

test "flattened rect has four corners":
  var pth = Path()
  pth.rect(0, 0, 10, 5, identity())
  let polys = pth.flatten()
  check polys.len == 1
  check polys[0].pts.len == 4

test "solid and linear paint sampling":
  let s = solidPaint(rgbf(1, 0, 0))
  check s.sample(0, 0).r > 0.99
  let g = linearGradient(0, 0, 10, 0, rgbf(0, 0, 0), rgbf(1, 1, 1))
  check g.sample(0, 0).r < 0.01
  check abs(g.sample(5, 0).r - 0.5) < 0.01
  check g.sample(10, 0).r > 0.99
