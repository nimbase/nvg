## Immediate-mode path builder.
##
## Mirrors NanoVG's command model (`moveTo/lineTo/bezierTo/quadTo/arcTo`
## plus shape constructors) but stores commands in user space and applies
## the current transform on append, exactly like `nvg__appendCommands`.
## Flattening (below) matches `nvg__tesselateBezier` / `nvg__flattenPaths`.

import std/math
import ./types
import ./transform

export types

const
  Kappa90* = 0.5522847493
  DefaultTessTol* = 0.25
  DefaultDistTol* = 0.01

type
  CommandKind* = enum
    pcMoveTo
    pcLineTo
    pcCubicTo
    pcClose
    pcWinding

  Command* = object
    case kind*: CommandKind
    of pcMoveTo, pcLineTo:
      p*: Pt
    of pcCubicTo:
      c1*, c2*, p2*: Pt
    of pcClose:
      discard
    of pcWinding:
      winding*: Winding

  SubPoly* = object
    pts*: seq[Pt]
    closed*: bool
    corners*: seq[bool]
      ## Per-point corner flags (parallel to `pts`): true for explicit
      ## path vertices (moveTo/lineTo/curve endpoints), false for
      ## tessellation subdivisions. Ports NanoVG's `NVG_PT_CORNER` so
      ## stroke expansion can tell corners from smooth curve samples.

  Path* = object
    commands*: seq[Command]
    pen*: Pt
    hasPen*: bool

proc clear*(p: var Path) =
  p.commands.setLen(0)
  p.hasPen = false
  p.pen = pt(0, 0)

proc appendWinding*(p: var Path, w: Winding) =
  p.commands.add(Command(kind: pcWinding, winding: w))

proc moveTo*(p: var Path, x, y: float64, xf: Xform) =
  let q = xf.apply(x, y)
  p.commands.add(Command(kind: pcMoveTo, p: q))
  p.pen = q
  p.hasPen = true

proc lineTo*(p: var Path, x, y: float64, xf: Xform) =
  let q = xf.apply(x, y)
  if not p.hasPen:
    p.commands.add(Command(kind: pcMoveTo, p: q))
  else:
    p.commands.add(Command(kind: pcLineTo, p: q))
  p.pen = q
  p.hasPen = true

proc bezierTo*(p: var Path, c1x, c1y, c2x, c2y, x, y: float64,
    xf: Xform) =
  let c1 = xf.apply(c1x, c1y)
  let c2 = xf.apply(c2x, c2y)
  let q = xf.apply(x, y)
  if not p.hasPen:
    p.commands.add(Command(kind: pcMoveTo, p: c1))
    p.hasPen = true
  p.commands.add(Command(kind: pcCubicTo, c1: c1, c2: c2, p2: q))
  p.pen = q

proc quadTo*(p: var Path, cx, cy, x, y: float64, xf: Xform) =
  ## Promote quadratic to cubic (same math as `nvgQuadTo`). Promotion is
  ## exact for affine transforms, so promote the transformed cage.
  let q = xf.apply(x, y)
  let c = xf.apply(cx, cy)
  let s = if p.hasPen: p.pen else: c
  let c1 = pt(s.x + 2.0/3.0*(c.x - s.x), s.y + 2.0/3.0*(c.y - s.y))
  let c2 = pt(q.x + 2.0/3.0*(c.x - q.x), q.y + 2.0/3.0*(c.y - q.y))
  if not p.hasPen:
    p.commands.add(Command(kind: pcMoveTo, p: s))
    p.hasPen = true
  p.commands.add(Command(kind: pcCubicTo, c1: c1, c2: c2, p2: q))
  p.pen = q

proc closePath*(p: var Path) =
  p.commands.add(Command(kind: pcClose))

proc sgn*(v: float64): float64 =
  if v >= 0.0: 1.0 else: -1.0

proc distPtSegSq*(px, py, ax, ay, bx, by: float64): float64 =
  ## Squared distance from point to segment (port of `nvg__distPtSeg`).
  let dx = bx - ax
  let dy = by - ay
  let d2 = dx*dx + dy*dy
  if d2 < 1e-12:
    let ex = px - ax
    let ey = py - ay
    return ex*ex + ey*ey
  var t = ((px - ax)*dx + (py - ay)*dy) / d2
  t = clamp(t, 0.0, 1.0)
  let ex = px - (ax + t*dx)
  let ey = py - (ay + t*dy)
  ex*ex + ey*ey

proc rect*(p: var Path, x, y, w, h: float64, xf: Xform) =
  p.moveTo(x, y, xf)
  p.lineTo(x, y + h, xf)
  p.lineTo(x + w, y + h, xf)
  p.lineTo(x + w, y, xf)
  p.closePath()

proc roundedRectVarying*(p: var Path, x, y, w, h: float64,
    radTopLeft, radTopRight, radBottomRight, radBottomLeft: float64,
    xf: Xform) =
  ## Exact port of `nvgRoundedRectVarying`: plain rect only when ALL radii
  ## are negligible; per-corner radii clamped to half extents with
  ## per-axis signs so negative `w`/`h` trace the same shape.
  if radTopLeft < 0.1 and radTopRight < 0.1 and radBottomRight < 0.1 and
      radBottomLeft < 0.1:
    p.rect(x, y, w, h, xf)
    return
  let halfw = abs(w) * 0.5
  let halfh = abs(h) * 0.5
  let sw = sgn(w)
  let sh = sgn(h)
  let rxBL = min(radBottomLeft, halfw) * sw
  let ryBL = min(radBottomLeft, halfh) * sh
  let rxBR = min(radBottomRight, halfw) * sw
  let ryBR = min(radBottomRight, halfh) * sh
  let rxTR = min(radTopRight, halfw) * sw
  let ryTR = min(radTopRight, halfh) * sh
  let rxTL = min(radTopLeft, halfw) * sw
  let ryTL = min(radTopLeft, halfh) * sh
  let k = Kappa90
  p.moveTo(x, y + ryTL, xf)
  p.lineTo(x, y + h - ryBL, xf)
  p.bezierTo(x, y + h - ryBL*(1 - k), x + rxBL*(1 - k), y + h,
    x + rxBL, y + h, xf)
  p.lineTo(x + w - rxBR, y + h, xf)
  p.bezierTo(x + w - rxBR*(1 - k), y + h, x + w, y + h - ryBR*(1 - k),
    x + w, y + h - ryBR, xf)
  p.lineTo(x + w, y + ryTR, xf)
  p.bezierTo(x + w, y + ryTR*(1 - k), x + w - rxTR*(1 - k), y,
    x + w - rxTR, y, xf)
  p.lineTo(x + rxTL, y, xf)
  p.bezierTo(x + rxTL*(1 - k), y, x, y + ryTL*(1 - k), x, y + ryTL, xf)
  p.closePath()

proc roundedRect*(p: var Path, x, y, w, h, r: float64, xf: Xform) =
  p.roundedRectVarying(x, y, w, h, r, r, r, r, xf)

proc ellipse*(p: var Path, cx, cy, rx, ry: float64, xf: Xform) =
  if rx <= 0.0 or ry <= 0.0:
    return
  let k = Kappa90
  p.moveTo(cx - rx, cy, xf)
  p.bezierTo(cx - rx, cy + k*ry, cx - k*rx, cy + ry, cx, cy + ry, xf)
  p.bezierTo(cx + k*rx, cy + ry, cx + rx, cy + k*ry, cx + rx, cy, xf)
  p.bezierTo(cx + rx, cy - k*ry, cx + k*rx, cy - ry, cx, cy - ry, xf)
  p.bezierTo(cx - k*rx, cy - ry, cx - rx, cy - k*ry, cx - rx, cy, xf)
  p.closePath()

proc circle*(p: var Path, cx, cy, r: float64, xf: Xform) =
  p.ellipse(cx, cy, r, r, xf)

proc polyPoints(cx, cy, radius: float64, n: int,
    rotation: float64): seq[Pt] =
  ## Regular-polygon vertices (empty when degenerate). Angle convention
  ## matches `arc` (`x + cos`, `y + sin`, y-down).
  if radius <= 0.0 or n < 3:
    return @[]
  for i in 0 ..< n:
    let a = rotation + 2.0 * PI * float64(i) / float64(n)
    result.add(pt(cx + cos(a) * radius, cy + sin(a) * radius))

proc tracePoly(p: var Path, verts: seq[Pt], rounds: seq[float64],
    xf: Xform) =
  ## Trace closed `verts` with per-vertex roundness in `[0, 1]` (clamped).
  ## Sharp vertices use `lineTo`; rounded ones cut each adjacent edge at
  ## `f = roundness*0.5` and join the cuts with a `bezierTo` whose control
  ## arms take the `Kappa90` fraction toward the tip (same constant as
  ## the circle/rounded-rect approximation). `f <= 0.5` per side, so
  ## adjacent rounds meet at most at edge midpoints, never overlapping.
  let n = verts.len
  if n == 0: return
  var first = true
  for i in 0 ..< n:
    let r = clamp(rounds[i], 0.0, 1.0)
    let v = verts[i]
    if r <= 0.0:
      if first:
        p.moveTo(v.x, v.y, xf)
        first = false
      else:
        p.lineTo(v.x, v.y, xf)
      continue
    let pv = verts[(i - 1 + n) mod n]
    let nv = verts[(i + 1) mod n]
    let f = r * 0.5
    let ax = v.x + (pv.x - v.x) * f
    let ay = v.y + (pv.y - v.y) * f
    let bx = v.x + (nv.x - v.x) * f
    let by = v.y + (nv.y - v.y) * f
    if first:
      p.moveTo(ax, ay, xf)
      first = false
    else:
      p.lineTo(ax, ay, xf)
    p.bezierTo(ax + (v.x - ax) * Kappa90, ay + (v.y - ay) * Kappa90,
      bx + (v.x - bx) * Kappa90, by + (v.y - by) * Kappa90, bx, by, xf)
  p.closePath()

proc polygon*(p: var Path, cx, cy, radius: float64, n: int,
    rotation: float64, xf: Xform, roundness = 0.0) =
  ## Regular `n`-gon at `(cx,cy)` with first vertex at `rotation`
  ## radians. Degenerate (`radius <= 0` or `n < 3`) emits a single-point
  ## `moveTo` (no NaN: fill paints nothing, stroke leaves its round dot).
  let verts = polyPoints(cx, cy, radius, n, rotation)
  if verts.len == 0:
    p.moveTo(cx, cy, xf)
    return
  var rounds = newSeq[float64](verts.len)
  for i in 0 ..< rounds.len: rounds[i] = roundness
  p.tracePoly(verts, rounds, xf)

proc star*(p: var Path, cx, cy, outerR, innerR: float64, n: int,
    rotation: float64, xf: Xform, outerRound = 0.0, innerRound = 0.0) =
  ## `n`-point star alternating `outerR`/`innerR` vertices from
  ## `rotation`. Degenerate (`outerR <= 0` or `n < 3`) emits a
  ## single-point `moveTo`; negative `innerR` clamps to 0 (spikes reach
  ## the center, no NaN).
  let outer = max(0.0, outerR)
  let inner = max(0.0, innerR)
  if outer <= 0.0 or n < 3:
    p.moveTo(cx, cy, xf)
    return
  var verts: seq[Pt] = @[]
  var rounds: seq[float64] = @[]
  for i in 0 ..< n:
    let ao = rotation + 2.0 * PI * float64(i) / float64(n)
    let ai = ao + PI / float64(n)
    verts.add(pt(cx + cos(ao) * outer, cy + sin(ao) * outer))
    rounds.add(outerRound)
    verts.add(pt(cx + cos(ai) * inner, cy + sin(ai) * inner))
    rounds.add(innerRound)
  p.tracePoly(verts, rounds, xf)

proc arc*(p: var Path, cx, cy, r, a0, a1: float64, dir: Winding,
    xf: Xform) =
  ## Exact port of `nvgArc`: `wCW` sweeps increasing angles (visually
  ## clockwise in y-down), `wCCW` sweeps decreasing angles.
  if r <= 0.0:
    return
  var da = a1 - a0
  if dir == wCW:
    if abs(da) >= PI * 2.0:
      da = PI * 2.0
    else:
      while da < 0.0: da += PI * 2.0
  else:
    if abs(da) >= PI * 2.0:
      da = -PI * 2.0
    else:
      while da > 0.0: da -= PI * 2.0
  if abs(da) < 1e-9:
    return
  let ndivs = max(1, min(5, int(abs(da) / (PI * 0.5) + 0.5)))
  let hda = (da / float64(ndivs)) / 2.0
  var kappa = abs(4.0/3.0 * (1.0 - cos(hda)) / sin(hda))
  if dir == wCCW:
    kappa = -kappa
  var prevP = pt(0, 0)
  var prevT = pt(0, 0)
  for i in 0 .. ndivs:
    let a = a0 + da * float64(i) / float64(ndivs)
    let dx = cos(a)
    let dy = sin(a)
    let curr = pt(cx + dx * r, cy + dy * r)
    let tan = pt(-dy * r * kappa, dx * r * kappa)
    if i == 0:
      let q = xf.apply(curr.x, curr.y)
      if p.hasPen:
        p.commands.add(Command(kind: pcLineTo, p: q))
      else:
        p.commands.add(Command(kind: pcMoveTo, p: q))
      p.pen = q
      p.hasPen = true
    else:
      let c1 = pt(prevP.x + prevT.x, prevP.y + prevT.y)
      let c2 = pt(curr.x - tan.x, curr.y - tan.y)
      # Commands are stored pre-transformed; arc math runs in user space
      # so transform the cage here.
      let t1 = xf.apply(c1.x, c1.y)
      let t2 = xf.apply(c2.x, c2.y)
      let t3 = xf.apply(curr.x, curr.y)
      p.commands.add(Command(kind: pcCubicTo, c1: t1, c2: t2, p2: t3))
      p.pen = t3
    prevP = curr
    prevT = tan

proc arcTo*(p: var Path, x1, y1, x2, y2, radius: float64, xf: Xform) =
  ## Tangent arc from the current pen through `(x1,y1)` toward `(x2,y2)`.
  ## Exact port of `nvgArcTo`, including the `nvg__cross` sign convention
  ## (`dx1*dy0 - dx0*dy1`) and the collinear/radius fallbacks to lineTo.
  if not p.hasPen:
    return
  if radius < DefaultDistTol:
    p.lineTo(x1, y1, xf)
    return
  # Work in user space: invert the current transform on the stored pen.
  var inv = identity()
  if not inverse(xf, inv):
    p.lineTo(x1, y1, xf)
    return
  let x0 = inv.apply(p.pen)
  let same01 = abs(x0.x - x1) < DefaultDistTol and
    abs(x0.y - y1) < DefaultDistTol
  let same12 = abs(x1 - x2) < DefaultDistTol and
    abs(y1 - y2) < DefaultDistTol
  if same01 or same12 or
      distPtSegSq(x1, y1, x0.x, x0.y, x2, y2) <
      DefaultDistTol * DefaultDistTol:
    p.lineTo(x1, y1, xf)
    return
  var dx0 = pt(x0.x - x1, x0.y - y1)
  var dx1 = pt(x2 - x1, y2 - y1)
  let l0 = sqrt(dx0.x*dx0.x + dx0.y*dx0.y)
  let l1 = sqrt(dx1.x*dx1.x + dx1.y*dx1.y)
  if l0 < DefaultDistTol or l1 < DefaultDistTol:
    p.lineTo(x1, y1, xf)
    return
  dx0 = pt(dx0.x / l0, dx0.y / l0)
  dx1 = pt(dx1.x / l1, dx1.y / l1)
  let a = arccos(clamp(dx0.x*dx1.x + dx0.y*dx1.y, -1.0, 1.0))
  let d = radius / tan(a * 0.5)
  if d > 10000.0:
    p.lineTo(x1, y1, xf)
    return
  # NB: NanoVG cross is dx1*dy0 - dx0*dy1 (negated standard cross).
  let cross = dx1.x*dx0.y - dx0.x*dx1.y
  var cx, cy, a0, a1: float64
  var dir: Winding
  if cross > 0.0:
    cx = x1 + dx0.x*d + dx0.y*radius
    cy = y1 + dx0.y*d - dx0.x*radius
    a0 = arctan2(dx0.x, -dx0.y)
    a1 = arctan2(-dx1.x, dx1.y)
    dir = wCW
  else:
    cx = x1 + dx0.x*d - dx0.y*radius
    cy = y1 + dx0.y*d + dx0.x*radius
    a0 = arctan2(-dx0.x, dx0.y)
    a1 = arctan2(dx1.x, -dx1.y)
    dir = wCCW
  p.arc(cx, cy, radius, a0, a1, dir, xf)

# --- Flattening ---

proc tessBezier(pts: var seq[Pt], corners: var seq[bool], p1, p2, p3,
    p4: Pt, level: int, tessTol: float64, endCorner: bool) =
  if level > 10:
    pts.add(p4)
    corners.add(endCorner)
    return
  let dx = p4.x - p1.x
  let dy = p4.y - p1.y
  let d2 = abs((p2.x - p4.x)*dy - (p2.y - p4.y)*dx)
  let d3 = abs((p3.x - p4.x)*dy - (p3.y - p4.y)*dx)
  if (d2 + d3) * (d2 + d3) < tessTol * (dx*dx + dy*dy):
    pts.add(p4)
    corners.add(endCorner)
    return
  let m12 = pt((p1.x + p2.x)*0.5, (p1.y + p2.y)*0.5)
  let m23 = pt((p2.x + p3.x)*0.5, (p2.y + p3.y)*0.5)
  let m34 = pt((p3.x + p4.x)*0.5, (p3.y + p4.y)*0.5)
  let m123 = pt((m12.x + m23.x)*0.5, (m12.y + m23.y)*0.5)
  let m234 = pt((m23.x + m34.x)*0.5, (m23.y + m34.y)*0.5)
  let mid = pt((m123.x + m234.x)*0.5, (m123.y + m234.y)*0.5)
  tessBezier(pts, corners, p1, m12, m123, mid, level + 1, tessTol, false)
  tessBezier(pts, corners, mid, m234, m34, p4, level + 1, tessTol,
    endCorner)

proc flatten*(p: Path, tessTol = DefaultTessTol,
    distTol = DefaultDistTol): seq[SubPoly] =
  ## Commands to flattened polygons. Mirrors `nvg__flattenPaths` minus the
  ## winding sort (v1 uses even-odd, so winding is informational only).
  var cur: seq[Pt] = @[]
  var curCorners: seq[bool] = @[]
  var curClosed = false
  var pen = pt(0, 0)
  var hasPen = false
  var outPolys: seq[SubPoly] = @[]
  proc flush() =
    if cur.len > 0:
      # Drop trailing duplicate point like NanoVG does.
      if cur.len > 1:
        let a = cur[^1]
        let b = cur[0]
        let dx = a.x - b.x
        let dy = a.y - b.y
        if dx*dx + dy*dy < distTol*distTol and curClosed:
          cur.setLen(cur.len - 1)
          curCorners.setLen(curCorners.len - 1)
      outPolys.add(SubPoly(pts: cur, closed: curClosed,
        corners: curCorners))
      cur = @[]
      curCorners = @[]
      curClosed = false
  for c in p.commands:
    case c.kind
    of pcMoveTo:
      if cur.len > 0: flush()
      cur = @[c.p]
      curCorners = @[true]
      pen = c.p
      hasPen = true
    of pcLineTo:
      if not hasPen or cur.len == 0:
        cur = @[c.p]
        curCorners = @[true]
      else:
        let a = cur[^1]
        let dx = a.x - c.p.x
        let dy = a.y - c.p.y
        if dx*dx + dy*dy >= distTol*distTol:
          cur.add(c.p)
          curCorners.add(true)
      pen = c.p
      hasPen = true
    of pcCubicTo:
      if not hasPen or cur.len == 0:
        cur = @[c.c1]
        curCorners = @[false]
      let p0 = cur[^1]
      tessBezier(cur, curCorners, p0, c.c1, c.c2, c.p2, 0, tessTol,
        true)
      pen = c.p2
      hasPen = true
    of pcClose:
      curClosed = true
      flush()
    of pcWinding:
      discard
  if cur.len > 0: flush()
  result = outPolys

proc flattenBounds*(polys: seq[SubPoly]): tuple[x0, y0, x1, y1: float64] =
  var x0 = 1e6
  var y0 = 1e6
  var x1 = -1e6
  var y1 = -1e6
  for s in polys:
    for q in s.pts:
      x0 = min(x0, q.x)
      y0 = min(y0, q.y)
      x1 = max(x1, q.x)
      y1 = max(y1, q.y)
  if x1 < x0:
    return (0.0, 0.0, 0.0, 0.0)
  (x0, y0, x1, y1)
