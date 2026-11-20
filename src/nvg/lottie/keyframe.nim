## Keyframe evaluation: easing + value interpolation.
##
## Mirrors rlottie's `KeyFrames<T>` semantics: before the first key hold
## the start value, after the last hold the end value, inside a segment
## ease `t` with the segment interpolator then lerp. Positions with
## spatial tangents travel along the cubic instead of lerping; path
## shapes lerp vertex-by-vertex (same count required, else hold start).

import std/math
import ./model

proc cubicAt*(a, b, c, d, t: float64): float64 =
  ## Cubic bezier point for scalar control values.
  let u = 1.0 - t
  u*u*u*a + 3.0*u*u*t*b + 3.0*u*t*t*c + t*t*t*d

proc easeBezier*(e: Easing, t: float64): float64 =
  ## Solve x(t)=t for the cubic (0,0)-(x1,y1)-(x2,y2)-(1,1), return y.
  ## Bisection on x (monotone in practice); 24 iterations is plenty.
  if e.hold: return 0.0
  if t <= 0.0: return 0.0
  if t >= 1.0: return 1.0
  var lo = 0.0
  var hi = 1.0
  var u = t
  for _ in 0 ..< 24:
    let x = cubicAt(0.0, e.x1, e.x2, 1.0, u)
    if abs(x - t) < 1e-9: break
    if x < t: lo = u else: hi = u
    u = (lo + hi) * 0.5
  cubicAt(0.0, e.y1, e.y2, 1.0, u)

proc segProgress*[T](k: Keyframe[T], frame: float64): float64 =
  if k.finish <= k.start: return 0.0
  let t = clamp((frame - k.start) / (k.finish - k.start), 0.0, 1.0)
  easeBezier(k.ease, t)

proc lerpF*(a, b, t: float64): float64 = a + (b - a) * t

proc lerpVec*(a, b: Vec2, t: float64): Vec2 =
  vec2(lerpF(a.x, b.x, t), lerpF(a.y, b.y, t))

proc lerpColor*(a, b: LColor, t: float64): LColor =
  lcolor(lerpF(a.r, b.r, t), lerpF(a.g, b.g, t), lerpF(a.b, b.b, t))

proc valueAt*(a: Animated[float64], frame: float64): float64 =
  if a.isStatic or a.keys.len == 0: return a.value
  if frame <= a.keys[0].start: return a.keys[0].startVal
  if frame >= a.keys[^1].finish: return a.keys[^1].endVal
  for k in a.keys:
    if frame >= k.start and frame < k.finish:
      if k.ease.hold: return k.startVal
      return lerpF(k.startVal, k.endVal, segProgress(k, frame))
  a.keys[^1].endVal

proc valueAt*(a: Animated[Vec2], frame: float64): Vec2 =
  if a.isStatic or a.keys.len == 0: return a.value
  if frame <= a.keys[0].start: return a.keys[0].startVal
  if frame >= a.keys[^1].finish: return a.keys[^1].endVal
  for k in a.keys:
    if frame >= k.start and frame < k.finish:
      if k.ease.hold: return k.startVal
      let t = segProgress(k, frame)
      if k.hasSpatial:
        # Cubic from start along out-tangent to end along in-tangent.
        let p0 = k.startVal
        let p1 = vec2(p0.x + k.toOut.x, p0.y + k.toOut.y)
        let p3 = k.endVal
        let p2 = vec2(p3.x + k.toIn.x, p3.y + k.toIn.y)
        return vec2(cubicAt(p0.x, p1.x, p2.x, p3.x, t),
          cubicAt(p0.y, p1.y, p2.y, p3.y, t))
      return lerpVec(k.startVal, k.endVal, t)
  a.keys[^1].endVal

proc valueAt*(a: Animated[LColor], frame: float64): LColor =
  if a.isStatic or a.keys.len == 0: return a.value
  if frame <= a.keys[0].start: return a.keys[0].startVal
  if frame >= a.keys[^1].finish: return a.keys[^1].endVal
  for k in a.keys:
    if frame >= k.start and frame < k.finish:
      if k.ease.hold: return k.startVal
      return lerpColor(k.startVal, k.endVal, segProgress(k, frame))
  a.keys[^1].endVal

proc lerpPath*(a, b: PathData, t: float64): PathData =
  if a.verts.len != b.verts.len or a.verts.len == 0:
    return a
  result = PathData(closed: a.closed)
  for i in 0 ..< a.verts.len:
    result.verts.add(lerpVec(a.verts[i], b.verts[i], t))
    result.inT.add(lerpVec(a.inT[i], b.inT[i], t))
    result.outT.add(lerpVec(a.outT[i], b.outT[i], t))

proc valueAt*(a: Animated[PathData], frame: float64): PathData =
  if a.isStatic or a.keys.len == 0: return a.value
  if frame <= a.keys[0].start: return a.keys[0].startVal
  if frame >= a.keys[^1].finish: return a.keys[^1].endVal
  for k in a.keys:
    if frame >= k.start and frame < k.finish:
      if k.ease.hold: return k.startVal
      return lerpPath(k.startVal, k.endVal, segProgress(k, frame))
  a.keys[^1].endVal

proc valueAtRaw*(a: Animated[seq[float64]], frame: float64): seq[float64] =
  ## Gradient stop lists: no interpolation in v1 (hold segment start).
  ## Refined in the paints phase; layer tests never touch this path.
  if a.isStatic or a.keys.len == 0: return a.value
  if frame <= a.keys[0].start: return a.keys[0].startVal
  if frame >= a.keys[^1].finish: return a.keys[^1].endVal
  for k in a.keys:
    if frame >= k.start and frame < k.finish:
      return k.startVal
  a.keys[^1].endVal
