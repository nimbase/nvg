import std/unittest
import nvg/lottie/model
import nvg/lottie/keyframe

test "linear float easing":
  let a = animKeys(@[Keyframe[float64](start: 0, finish: 10,
    startVal: 0, endVal: 10,
    ease: Easing(x1: 0, y1: 0, x2: 1, y2: 1))])
  check valueAt(a, 0) == 0.0
  check valueAt(a, 5) == 5.0
  check valueAt(a, 10) == 10.0
  check valueAt(a, -3) == 0.0
  check valueAt(a, 99) == 10.0

test "hold keyframe":
  let a = animKeys(@[
    Keyframe[float64](start: 0, finish: 5, startVal: 1, endVal: 7,
      ease: Easing(hold: true)),
    Keyframe[float64](start: 5, finish: 5, startVal: 7, endVal: 7,
      ease: Easing())])
  check valueAt(a, 2) == 1.0
  check valueAt(a, 5) == 7.0

test "ease in-out is symmetric at midpoint":
  let e = Easing(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)
  check abs(easeBezier(e, 0.5) - 0.5) < 1e-9

test "spatial bezier midpoint on symmetric curve":
  let a = animKeys(@[Keyframe[Vec2](start: 0, finish: 10,
    startVal: vec2(0, 0), endVal: vec2(10, 0),
    hasSpatial: true, toOut: vec2(0, 5), toIn: vec2(0, 5),
    ease: Easing(x1: 0, y1: 0, x2: 1, y2: 1))])
  let m = valueAt(a, 5)
  check abs(m.x - 5.0) < 1e-6
  check abs(m.y - 3.75) < 1e-6 # cubic B(0.5) with arms +-5

test "path lerp vertex-wise":
  let p0 = PathData(verts: @[vec2(0, 0), vec2(10, 0)],
    inT: @[vec2(0, 0), vec2(0, 0)], outT: @[vec2(0, 0), vec2(0, 0)])
  let p1 = PathData(verts: @[vec2(0, 10), vec2(10, 10)],
    inT: @[vec2(0, 0), vec2(0, 0)], outT: @[vec2(0, 0), vec2(0, 0)])
  let a = animKeys(@[Keyframe[PathData](start: 0, finish: 4,
    startVal: p0, endVal: p1, ease: Easing(x1: 0, y1: 0, x2: 1, y2: 1))])
  let m = valueAt(a, 2)
  check m.verts[0] == vec2(0, 5)
  check m.verts[1] == vec2(10, 5)
