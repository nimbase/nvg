## Affine transform math (2x3, y-down points).
##
## Port of the `nvgTransform*` family from NanoVG, in `float64`.
## Premultiply convention: `multiply(a, b)` returns `a * b`, i.e. applying
## `b` first, then `a` — the same order NanoVG's state stack uses when
## each verb pre-multiplies the current transform.

import std/math
import ./types

export types

proc identity*(): Xform = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]

proc translate*(tx, ty: float64): Xform = [1.0, 0.0, 0.0, 1.0, tx, ty]

proc scale*(sx, sy: float64): Xform = [sx, 0.0, 0.0, sy, 0.0, 0.0]

proc rotate*(angleRad: float64): Xform =
  let c = cos(angleRad)
  let s = sin(angleRad)
  [c, s, -s, c, 0.0, 0.0]

proc skewX*(angleRad: float64): Xform =
  [1.0, 0.0, tan(angleRad), 1.0, 0.0, 0.0]

proc skewY*(angleRad: float64): Xform =
  [1.0, tan(angleRad), 0.0, 1.0, 0.0, 0.0]

proc multiply*(a, b: Xform): Xform =
  ## Return `a * b` (apply `b` first, then `a`).
  [a[0]*b[0] + a[2]*b[1], a[1]*b[0] + a[3]*b[1],
   a[0]*b[2] + a[2]*b[3], a[1]*b[2] + a[3]*b[3],
   a[0]*b[4] + a[2]*b[5] + a[4], a[1]*b[4] + a[3]*b[5] + a[5]]

proc premultiply*(dst: var Xform, src: Xform) =
  ## Set `dst = src * dst`.
  dst = multiply(src, dst)

proc inverse*(src: Xform, dst: var Xform): bool =
  let det = src[0]*src[3] - src[2]*src[1]
  if abs(det) < 1e-12:
    dst = identity()
    return false
  let inv = 1.0 / det
  dst = [(src[3])*inv, (-src[1])*inv, (-src[2])*inv, (src[0])*inv,
    (src[2]*src[5] - src[3]*src[4])*inv,
    (src[1]*src[4] - src[0]*src[5])*inv]
  true

proc apply*(m: Xform, p: Pt): Pt =
  pt(m[0]*p.x + m[2]*p.y + m[4], m[1]*p.x + m[3]*p.y + m[5])

proc apply*(m: Xform, x, y: float64): Pt =
  pt(m[0]*x + m[2]*y + m[4], m[1]*x + m[3]*y + m[5])

proc averageScale*(m: Xform): float64 =
  let sx = sqrt(m[0]*m[0] + m[2]*m[2])
  let sy = sqrt(m[1]*m[1] + m[3]*m[3])
  (sx + sy) * 0.5

proc degToRad*(deg: float64): float64 = deg * PI / 180.0

proc radToDeg*(rad: float64): float64 = rad * 180.0 / PI
