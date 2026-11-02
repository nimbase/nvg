## Path measurement over flattened polygons.
##
## Length, point/tangent queries, and subpath extraction run on
## `flatten` output (`seq[SubPoly]`), so callers can build trimming,
## marching ants, or text-on-path without touching the rasterizer.
## Distances concatenate subpaths in order; `extract` preserves the
## `closed` flag only when the whole loop is extracted. Operates on the
## flattened polyline, so cubic "exact" length is the polyline length at
## the caller's `tessTol` (tests use tolerance, not equality).

import std/math
import ./types
import ./path

export types
export path

proc segLens*(pts: openArray[Pt], closed: bool): seq[float64] =
  ## Per-edge lengths (closing edge included for closed loops).
  let n = pts.len
  if n < 2: return @[]
  let m = if closed: n else: n - 1
  for i in 0 ..< m:
    let a = pts[i]
    let b = pts[(i + 1) mod n]
    result.add(sqrt((b.x - a.x)^2 + (b.y - a.y)^2))

proc polyLength*(polys: seq[SubPoly]): float64 =
  ## Total length over all subpaths concatenated in order.
  for s in polys:
    for L in segLens(s.pts, s.closed):
      result += L

proc pointAtLen*(polys: seq[SubPoly], d: float64): Pt =
  ## Point at absolute distance `d` (clamped to `[0, total]`). Empty
  ## input returns the origin; zero total returns the first point.
  let total = polyLength(polys)
  var dd = clamp(d, 0.0, total)
  for s in polys:
    let ls = segLens(s.pts, s.closed)
    for i in 0 ..< ls.len:
      if dd <= ls[i] or (dd <= 1e-12 and ls[i] <= 1e-12):
        let a = s.pts[i]
        let b = s.pts[(i + 1) mod s.pts.len]
        if ls[i] <= 1e-12:
          return a
        let t = clamp01(dd / ls[i])
        return pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
      dd -= ls[i]
  # Clamped end: last point of the last non-empty subpath.
  for i in countdown(polys.len - 1, 0):
    if polys[i].pts.len > 0:
      return polys[i].pts[^1]
  pt(0, 0)

proc tangentAtLen*(polys: seq[SubPoly], d: float64): Pt =
  ## Unit tangent at absolute distance `d` (direction of the edge
  ## containing `d`). Zero vector when undefined (empty or degenerate).
  let total = polyLength(polys)
  var dd = clamp(d, 0.0, total)
  for s in polys:
    let ls = segLens(s.pts, s.closed)
    for i in 0 ..< ls.len:
      if ls[i] <= 1e-12:
        continue
      if dd <= ls[i]:
        let a = s.pts[i]
        let b = s.pts[(i + 1) mod s.pts.len]
        return pt((b.x - a.x) / ls[i], (b.y - a.y) / ls[i])
      dd -= ls[i]
  pt(0, 0)

proc pointAtNorm*(polys: seq[SubPoly], u: float64): Pt =
  ## Point at normalized distance `u` in `[0, 1]`.
  pointAtLen(polys, clamp01(u) * polyLength(polys))

proc tangentAtNorm*(polys: seq[SubPoly], u: float64): Pt =
  ## Unit tangent at normalized distance `u` in `[0, 1]`.
  tangentAtLen(polys, clamp01(u) * polyLength(polys))

proc extract*(polys: seq[SubPoly], d0, d1: float64): seq[SubPoly] =
  ## Subpaths covering `[d0, d1]` (absolute distances, clamped and
  ## order-independent; empty when `d0 == d1`). Points are interpolated at the cut positions, so
  ## `extract(p, 0, m) + extract(p, m, total)` length-sums to the total
  ## within float epsilon (split-and-rejoin round trip). Cut points get
  ## `corners = false`; inherited vertices keep their flags. A fully
  ## extracted closed loop keeps `closed = true`; partial loops come out
  ## open.
  let total = polyLength(polys)
  let a = clamp(min(d0, d1), 0.0, total)
  let b = clamp(max(d0, d1), 0.0, total)
  if b <= a: return @[]
  result = @[]
  var dist = 0.0 # distance at current edge start
  for s in polys:
    let ls = segLens(s.pts, s.closed)
    var cur: seq[Pt] = @[]
    var curCorners: seq[bool] = @[]
    var coveredFull = s.closed
    for i in 0 ..< ls.len:
      let e0 = dist
      let e1 = dist + ls[i]
      let c0 = max(e0, a)
      let c1 = min(e1, b)
      if c1 > c0 + 1e-12 and ls[i] > 1e-12:
        let p = s.pts[i]
        let q = s.pts[(i + 1) mod s.pts.len]
        let t0 = (c0 - e0) / ls[i]
        let t1 = (c1 - e0) / ls[i]
        let r0 = pt(p.x + (q.x - p.x) * t0, p.y + (q.y - p.y) * t0)
        let r1 = pt(p.x + (q.x - p.x) * t1, p.y + (q.y - p.y) * t1)
        if cur.len == 0:
          cur.add(r0)
          curCorners.add(t0 <= 1e-9 and
            (i < s.corners.len and s.corners[i]))
        cur.add(r1)
        curCorners.add(t1 >= 1.0 - 1e-9 and
          (((i + 1) mod s.pts.len) < s.corners.len and
            s.corners[(i + 1) mod s.pts.len]))
      else:
        coveredFull = false
      if e0 < a - 1e-9 or e1 > b + 1e-9:
        coveredFull = false
      dist = e1
    if cur.len >= 2:
      result.add(SubPoly(pts: cur, closed: coveredFull and cur.len > 2,
        corners: curCorners))
