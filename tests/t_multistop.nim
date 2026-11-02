import std/unittest
import nvg

proc close(a, b: float64, eps = 1e-9): bool = abs(a - b) < eps

test "2-stop multi ctor equals legacy ctor":
  let a = linearGradient(0, 0, 10, 0, rgbf(1, 0, 0), rgbf(0, 0, 1))
  let b = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
      GradientStop(pos: 1.0, color: rgbf(0, 0, 1))])
  for x in [-5.0, 0.0, 2.5, 5.0, 7.5, 10.0, 15.0]:
    let ca = a.sample(x, 0.0)
    let cb = b.sample(x, 0.0)
    check ca.r == cb.r and ca.g == cb.g and ca.b == cb.b and
      ca.a == cb.a

test "3 stops interpolate between adjacent pairs":
  let m = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
      GradientStop(pos: 1.0, color: rgbf(0, 0, 1))])
  let mid = m.sample(5.0, 0.0)
  check close(mid.r, 0.0) and close(mid.g, 1.0) and close(mid.b, 0.0)
  let q1 = m.sample(2.5, 0.0) # halfway red->green
  check close(q1.r, 0.5) and close(q1.g, 0.5) and close(q1.b, 0.0)
  let q3 = m.sample(7.5, 0.0) # halfway green->blue
  check close(q3.r, 0.0) and close(q3.g, 0.5) and close(q3.b, 0.5)

test "unsorted input sorts stably":
  let sorted = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
      GradientStop(pos: 1.0, color: rgbf(0, 0, 1))])
  let shuffled = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 1.0, color: rgbf(0, 0, 1)),
      GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(0, 1, 0))])
  for x in [0.0, 2.5, 5.0, 7.5, 10.0]:
    let a = sorted.sample(x, 0.0)
    let b = shuffled.sample(x, 0.0)
    check a.r == b.r and a.g == b.g and a.b == b.b

test "duplicate positions: last wins, hard stops on both sides":
  let h = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
      GradientStop(pos: 0.5, color: rgbf(0, 0, 1)),
      GradientStop(pos: 1.0, color: rgbf(1, 1, 1))])
  let at = h.sample(5.0, 0.0)
  check close(at.b, 1.0) and close(at.r, 0.0) and close(at.g, 0.0)
  let left = h.sample(4.9, 0.0) # approaching green from the left
  check left.g > 0.9 and left.b < 0.1
  let right = h.sample(5.1, 0.0) # blue ramp to the right
  check right.b > 0.9 and right.g < 0.1

test "out of range clamps to end stops":
  let m = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.2, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.8, color: rgbf(0, 0, 1))])
  let lo = m.sample(-5.0, 0.0)
  check close(lo.r, 1.0) and close(lo.b, 0.0)
  let hi = m.sample(15.0, 0.0)
  check close(hi.b, 1.0) and close(hi.r, 0.0)

test "alpha stops ramp":
  let m = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 0.0)),
      GradientStop(pos: 1.0, color: rgbaf(1, 0, 0, 1.0))])
  check close(m.sample(5.0, 0.0).a, 0.5)
  check close(m.sample(0.0, 0.0).a, 0.0)
  check close(m.sample(10.0, 0.0).a, 1.0)

test "empty stops sample transparent, single stop is constant":
  let e = linearGradientStops(0, 0, 10, 0, [])
  check e.sample(5.0, 0.0).a == 0.0
  let one = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.3, color: rgbf(0, 1, 0))])
  check close(one.sample(0.0, 0.0).g, 1.0)
  check close(one.sample(9.9, 0.0).g, 1.0)

test "positions clamp into [0, 1]":
  let ns = normalizeStops([GradientStop(pos: -2.0, color: rgbf(1, 0, 0)),
    GradientStop(pos: 5.0, color: rgbf(0, 0, 1))])
  check ns[0].pos == 0.0 and ns[1].pos == 1.0
  check isBasicTwoStop(ns)

test "radial 2-stop equivalence and 3-stop mid":
  let a = radialGradient(0, 0, 0, 10, rgbf(0, 0, 0), rgbf(1, 1, 1))
  let b = radialGradientStops(0, 0, 0, 10,
    [GradientStop(pos: 0.0, color: rgbf(0, 0, 0)),
      GradientStop(pos: 1.0, color: rgbf(1, 1, 1))])
  for d in [0.0, 3.0, 5.0, 10.0, 20.0]:
    check a.sample(d, 0.0).r == b.sample(d, 0.0).r
  let m = radialGradientStops(0, 0, 0, 10,
    [GradientStop(pos: 0.0, color: rgbf(0, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(0.5, 0.5, 0.5)),
      GradientStop(pos: 1.0, color: rgbf(1, 1, 1))])
  check close(m.sample(5.0, 0.0).r, 0.5, 1e-6)

test "multi-stop renders and jit falls back identically":
  proc scene(backend: Backend): Canvas =
    result = newCanvas(40, 10, backend)
    result.clear(rgb(255, 255, 255))
    result.beginPath()
    result.rect(0, 0, 40, 10)
    result.setFillPaint(result.linearGradientStops(0, 0, 40, 0,
      [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
        GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
        GradientStop(pos: 1.0, color: rgbf(0, 0, 1))]))
    result.fill()
  let cpu = scene(nil)
  let jb = newJitBackend()
  let jit = scene(jb)
  check cpu.surface.pixels == jit.surface.pixels
  # Gradient actually varies across the rect.
  check cpu.surface.getPixel(2, 5).r > 0.7
  check cpu.surface.getPixel(20, 5).g > 0.7
  check cpu.surface.getPixel(37, 5).b > 0.7
  destroyJitBackend(jb)

test "isBasicTwoStop gates jit correctly":
  let a = linearGradient(0, 0, 10, 0, rgbf(1, 0, 0), rgbf(0, 0, 1))
  check isBasicTwoStop(a.linear.stops)
  let m = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
      GradientStop(pos: 1.0, color: rgbf(0, 0, 1)),
      GradientStop(pos: 0.5, color: rgbf(0, 1, 0))])
  check not isBasicTwoStop(m.linear.stops)
  let shifted = linearGradientStops(0, 0, 10, 0,
    [GradientStop(pos: 0.2, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.8, color: rgbf(0, 0, 1))])
  check not isBasicTwoStop(shifted.linear.stops)
