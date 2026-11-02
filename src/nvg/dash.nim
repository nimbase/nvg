## Dashed strokes: dash-pattern splitting on flattened polygons.
##
## `applyDash` runs after `flatten` and before `expandStroke`. Each "on"
## run becomes its own open `SubPoly`, so `expandStroke` caps every dash
## end per the current `LineCap` (butt cuts clean; round extends a
## semicircle of radius `hw` past the dash end, shrinking the visual gap
## by `width` total — documented consequence, matches canvas behavior).
## Closed inputs walk cyclically from the dash offset, so rectangle dash
## continuity holds; a loop fully covered by "on" returns unchanged (joins
## preserved, no caps). Normalization: non-positive entries dropped (empty
## or all-dropped means solid), odd counts doubled (`[a,b,c]` repeats as
## `[a,b,c,a,b,c]`, canvas-spec), offset wraps modulo the total.

import std/math
import ./types
import ./path

export types
export path

const DashEps = 1e-9

proc normalizeDash*(dashes: openArray[float64]): seq[float64] =
  ## Filtered + doubled dash pattern (no offset). Empty means solid.
  for d in dashes:
    if d > DashEps:
      result.add(d)
  if result.len mod 2 == 1:
    result = result & result

proc dashTotal*(ds: openArray[float64]): float64 =
  for d in ds: result += d

proc wrapOffset*(offset, total: float64): float64 =
  ## Positive-modulo wrap of `offset` into `[0, total)`.
  if total <= DashEps: return 0.0
  result = offset - floor(offset / total) * total
  if result < 0.0: result += total
  if result >= total: result -= total

proc applyDash*(polys: seq[SubPoly], dashes: openArray[float64],
    offset = 0.0): seq[SubPoly] =
  ## Split flattened `polys` into dash "on" runs. Open subpaths restart
  ## the pattern per subpath at `offset`; closed loops run the pattern
  ## continuously around the loop from `offset`. Cut points get
  ## `corners = false`; runs starting/ending exactly at a path vertex
  ## inherit that vertex's corner flag.
  let ds = normalizeDash(dashes)
  if ds.len == 0: return polys
  let total = dashTotal(ds)
  if total <= DashEps: return polys
  let off = wrapOffset(offset, total)
  result = @[]
  for s in polys:
    let n = s.pts.len
    if n < 2:
      result.add(s)
      continue
    let nEdges = if s.closed: n else: n - 1
    # Pattern phase at path start: consume `off` from slot 0.
    var pi = 0
    var rem = ds[0]
    var o = off
    while o > DashEps:
      if o < rem - DashEps:
        rem -= o
        o = 0.0
      else:
        o -= rem
        pi = (pi + 1) mod ds.len
        rem = ds[pi]
    let base = result.len # runs of this subpath start here
    var cur: seq[Pt] = @[]
    var curCorners: seq[bool] = @[]
    var curLen = 0.0
    var everOff = false
    template flushRun() =
      if cur.len >= 2 and curLen > DashEps:
        result.add(SubPoly(pts: cur, closed: false, corners: curCorners))
      cur = @[]
      curCorners = @[]
      curLen = 0.0
    for ei in 0 ..< nEdges:
      let ai = ei mod n
      let bi = (ei + 1) mod n
      var px = s.pts[ai].x
      var py = s.pts[ai].y
      let qx = s.pts[bi].x
      let qy = s.pts[bi].y
      let ex = qx - px
      let ey = qy - py
      let L = sqrt(ex * ex + ey * ey)
      if L < DashEps:
        continue
      let ux = ex / L
      let uy = ey / L
      let aCorner = ai < s.corners.len and s.corners[ai]
      let bCorner = bi < s.corners.len and s.corners[bi]
      var left = L
      var atVertex = true # px,py sits exactly on s.pts[ai]
      while left > DashEps:
        let take = min(rem, left)
        let on = (pi mod 2) == 0
        if not on:
          everOff = true
        if on and take > DashEps:
          if cur.len == 0:
            cur.add(pt(px, py))
            curCorners.add(atVertex and aCorner)
          let endsAtVertex = take >= left - DashEps
          cur.add(pt(px + ux * take, py + uy * take))
          curCorners.add(endsAtVertex and bCorner)
          curLen += take
          atVertex = endsAtVertex
        else:
          atVertex = take >= left - DashEps
        px += ux * take
        py += uy * take
        left -= take
        rem -= take
        if rem <= DashEps:
          if on:
            flushRun()
          pi = (pi + 1) mod ds.len
          rem = ds[pi]
    flushRun()
    if s.closed:
      if not everOff:
        # Fully covered loop: keep joins, no caps. Drop any emitted
        # runs (there is exactly the whole loop as on-runs) and keep
        # the original.
        result.setLen(base)
        result.add(s)
        continue
      # Join a wrap-around on-run: when the loop starts and ends in
      # "on", the first and last emitted runs are one continuous run
      # through the start vertex.
      if result.len - base >= 2:
        let f = result[base]
        let l = result[^1]
        let st = s.pts[0]
        if f.pts.len >= 2 and l.pts.len >= 2 and
            abs(f.pts[0].x - st.x) < DashEps and
            abs(f.pts[0].y - st.y) < DashEps and
            abs(l.pts[^1].x - st.x) < DashEps and
            abs(l.pts[^1].y - st.y) < DashEps:
          result[base] = SubPoly(pts: l.pts & f.pts[1 .. ^1],
            closed: false, corners: l.corners & f.corners[1 .. ^1])
          result.setLen(result.len - 1)
