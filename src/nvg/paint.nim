## Paints: solid colors, linear/radial/box gradients, image patterns.
##
## Gradient and pattern parameters live in USER space. Each paint carries
## `map`, the inverse of the canvas transform captured at creation, so
## sampling maps the device-space point back to user space first. This
## matches NanoVG (paint transform baked at assignment, shader evaluates
## in paint space), including rotated box gradients and transformed
## radial gradients. Feather distances read in user units, which agree
## with NanoVG's paint-local units for rigid transforms.
##
## Deliberate simplification: the transform bakes at paint CREATION,
## whereas NanoVG multiplies it in at style ASSIGNMENT (`nvgFillPaint`).
## The two agree unless the transform changes between creation and
## assignment; creation-time capture is the less surprising rule.

import std/algorithm
import std/math
import ./types
import ./transform
import ./images

export types
export images

type
  PaintKind* = enum
    pkSolid
    pkLinear
    pkRadial
    pkBox
    pkPattern

  GradientStop* = object
    ## One color stop: `pos` in `[0, 1]` (clamped on construction),
    ## `color` straight alpha.
    pos*: float64
    color*: Color

  LinearGrad* = object
    sx*, sy*, ex*, ey*: float64
    icol*, ocol*: Color
    stops*: seq[GradientStop]
      ## Normalized stop list (stable-sorted by `pos`, positions
      ## clamped). The 2-stop constructors store `[0: icol, 1: ocol]`;
      ## multi-stop constructors store the full list. `icol/ocol` stay
      ## as the first/last colors for the JIT fast path.

  RadialGrad* = object
    cx*, cy*, inr*, outr*: float64
    icol*, ocol*: Color
    stops*: seq[GradientStop]

  BoxGrad* = object
    cx*, cy*: float64
    ex*, ey*: float64
    radius*: float64
    feather*: float64
    icol*, ocol*: Color
    stops*: seq[GradientStop]
      ## Normalized stop list, same semantics as linear and radial.
      ## The 2-stop constructor stores `[0: icol, 1: ocol]`.

  Pattern* = object
    img*: Image
    ox*, oy*: float64
    ex*, ey*: float64
    angle*: float64
    tint*: Color

  Paint* = object
    map*: Xform
    case kind*: PaintKind
    of pkSolid:
      solid*: Color
    of pkLinear:
      linear*: LinearGrad
    of pkRadial:
      radial*: RadialGrad
    of pkBox:
      box*: BoxGrad
    of pkPattern:
      pattern*: Pattern

proc withMap*(p: Paint, m: Xform): Paint =
  ## Return `p` sampling through `m` (device to user mapping).
  result = p
  result.map = m

proc solidPaint*(c: Color): Paint =
  Paint(map: identity(), kind: pkSolid, solid: c)

proc normalizeStops*(stops: openArray[GradientStop]): seq[GradientStop] =
  ## Stable-sort by `pos` (author order preserved for ties) and clamp
  ## positions into `[0, 1]`. Empty stays empty; duplicates are kept so
  ## sampling can honor last-wins hard stops.
  var tmp: seq[tuple[idx: int, pos: float64, color: Color]] = @[]
  for i, s in stops:
    tmp.add((i, clamp01(s.pos), s.color))
  tmp.sort(proc(a, b: tuple[idx: int, pos: float64,
      color: Color]): int =
    let c = cmp(a.pos, b.pos)
    if c != 0: c else: cmp(a.idx, b.idx))
  var outs: seq[GradientStop] = @[]
  for t in tmp:
    outs.add(GradientStop(pos: t.pos, color: t.color))
  outs

proc isBasicTwoStop*(stops: openArray[GradientStop]): bool =
  ## True for JIT-eligible 2-stop lists: exactly `[0, 1]` positions.
  ## Multi-stop paints (any other shape) stay on the scalar path so
  ## output stays identical.
  stops.len == 2 and stops[0].pos == 0.0 and stops[1].pos == 1.0

proc sampleStops*(stops: openArray[GradientStop], t: float64): Color =
  ## Interpolate `stops` at `t` in straight alpha, clamped outside
  ## `[0, 1]` (documented choice: matches the legacy 2-stop clamp in
  ## `lerpColor`). `t` is clamped first, then the segment is located:
  ## `L` = last index with `pos <= tc`, `R` = first with `pos > tc`
  ## (`R = L+1`, `pos[R] > pos[L]` always, so zero-length duplicate
  ## segments never divide). Exact duplicate hits yield the LAST stop
  ## at that position (stable order); each side interpolates toward its
  ## nearest distinct neighbor, giving hard stops for free. Empty
  ## returns transparent; a single stop is constant.
  ## Bit-identity note: past the last stop the final NON-DEGENERATE
  ## segment is lerped at `u >= 1` (clamped inside `lerpColor`) rather
  ## than returning the endpoint color: legacy `lerpColor` always lerps,
  ## and `c0+(c1-c0)*1.0` can differ by 1 ulp from `c1` (e.g.
  ## `0.8+(0.3-0.8)*1.0 != 0.3`), which the JIT kernels replicate.
  if stops.len == 0:
    return rgbaf(0, 0, 0, 0)
  if stops.len == 1:
    return stops[0].color
  # Fast path: basic 2-stop lists interpolate exactly like the legacy
  # direct `lerpColor` call (bit-identical by construction, no search).
  if isBasicTwoStop(stops):
    return lerpColor(stops[0].color, stops[1].color, t)
  let tc = clamp01(t)
  # Below the first position: first position's color (last author at
  # that position if the minimum is duplicated). Exact (no arithmetic),
  # and unreachable for basic 2-stop lists (tc >= 0 = pos[0] always).
  if tc < stops[0].pos:
    var k = 0
    while k + 1 < stops.len and stops[k + 1].pos == stops[0].pos:
      inc k
    return stops[k].color
  # At or past the last position: lerp the final non-degenerate
  # segment (all-same-pos lists fall back to the last stop).
  if tc >= stops[^1].pos:
    var j = stops.len - 1
    while j > 0 and stops[j - 1].pos == stops[^1].pos:
      dec j
    if j == 0:
      return stops[^1].color
    dec j
    let u = (tc - stops[j].pos) / (stops[^1].pos - stops[j].pos)
    return lerpColor(stops[j].color, stops[^1].color, u)
  var L = 0
  for i in 0 ..< stops.len:
    if stops[i].pos <= tc:
      L = i
    else:
      break
  # `stops[L+1].pos > tc >= stops[L].pos`, so the divisor is nonzero.
  let R = L + 1
  let u = (tc - stops[L].pos) / (stops[R].pos - stops[L].pos)
  lerpColor(stops[L].color, stops[R].color, u)

proc linearGradient*(sx, sy, ex, ey: float64, icol, ocol: Color): Paint =
  Paint(map: identity(), kind: pkLinear,
    linear: LinearGrad(sx: sx, sy: sy, ex: ex, ey: ey, icol: icol,
      ocol: ocol, stops: @[GradientStop(pos: 0.0, color: icol),
        GradientStop(pos: 1.0, color: ocol)]))

proc radialGradient*(cx, cy, inr, outr: float64, icol,
    ocol: Color): Paint =
  Paint(map: identity(), kind: pkRadial,
    radial: RadialGrad(cx: cx, cy: cy, inr: inr, outr: outr, icol: icol,
      ocol: ocol, stops: @[GradientStop(pos: 0.0, color: icol),
        GradientStop(pos: 1.0, color: ocol)]))

proc linearGradientStops*(sx, sy, ex, ey: float64,
    stops: openArray[GradientStop]): Paint =
  ## Multi-stop linear gradient. `stops` are normalized (stable sort,
  ## clamp); empty paints transparent, one stop paints constant.
  let ns = normalizeStops(stops)
  let ic = if ns.len > 0: ns[0].color else: rgbaf(0, 0, 0, 0)
  let oc = if ns.len > 0: ns[^1].color else: rgbaf(0, 0, 0, 0)
  Paint(map: identity(), kind: pkLinear,
    linear: LinearGrad(sx: sx, sy: sy, ex: ex, ey: ey, icol: ic,
      ocol: oc, stops: ns))

proc radialGradientStops*(cx, cy, inr, outr: float64,
    stops: openArray[GradientStop]): Paint =
  ## Multi-stop radial gradient (same stop semantics as linear).
  let ns = normalizeStops(stops)
  let ic = if ns.len > 0: ns[0].color else: rgbaf(0, 0, 0, 0)
  let oc = if ns.len > 0: ns[^1].color else: rgbaf(0, 0, 0, 0)
  Paint(map: identity(), kind: pkRadial,
    radial: RadialGrad(cx: cx, cy: cy, inr: inr, outr: outr, icol: ic,
      ocol: oc, stops: ns))

proc boxGradient*(cx, cy, ex, ey, radius, feather: float64, icol,
    ocol: Color): Paint =
  Paint(map: identity(), kind: pkBox,
    box: BoxGrad(cx: cx, cy: cy, ex: ex, ey: ey, radius: radius,
      feather: feather, icol: icol, ocol: ocol,
      stops: @[GradientStop(pos: 0.0, color: icol),
        GradientStop(pos: 1.0, color: ocol)]))

proc boxGradientStops*(cx, cy, ex, ey, radius, feather: float64,
    stops: openArray[GradientStop]): Paint =
  ## Multi-stop box gradient (same stop semantics as linear).
  let ns = normalizeStops(stops)
  let ic = if ns.len > 0: ns[0].color else: rgbaf(0, 0, 0, 0)
  let oc = if ns.len > 0: ns[^1].color else: rgbaf(0, 0, 0, 0)
  Paint(map: identity(), kind: pkBox,
    box: BoxGrad(cx: cx, cy: cy, ex: ex, ey: ey, radius: radius,
      feather: feather, icol: ic, ocol: oc, stops: ns))

proc imagePattern*(img: Image, ox, oy, ex, ey, angle: float64,
    tint = rgbf(1, 1, 1)): Paint =
  Paint(map: identity(), kind: pkPattern,
    pattern: Pattern(img: img, ox: ox, oy: oy, ex: ex, ey: ey,
      angle: angle, tint: tint))

proc sdRoundBox*(px, py, ex, ey, r: float64): float64 =
  ## Signed distance to the rounded box centered on the origin
  ## (GLSL `sdroundrect` port from the NanoVG backend).
  let qx = abs(px) - (ex - r)
  let qy = abs(py) - (ey - r)
  min(max(qx, qy), 0.0) + sqrt(max(qx, 0.0)^2 + max(qy, 0.0)^2) - r

proc patternTexelsPerPx*(p: Paint): float64 =
  ## Max source texels covered by one device pixel for a pattern
  ## paint: the `map` (device to user) Jacobian composed with the
  ## pattern tile (`angle`, `ex`/`ey`) and image size. Minification
  ## (`> 1`) selects a mipmap level via `withMip`; magnification and
  ## non-pattern paints report `<= 1`.
  if p.kind != pkPattern or p.pattern.img == nil:
    return 1.0
  let pt = p.pattern
  if abs(pt.ex) < 1e-12 or abs(pt.ey) < 1e-12:
    return 1.0
  let ca = cos(pt.angle)
  let sa = sin(pt.angle)
  let iw = float64(pt.img.w)
  let ih = float64(pt.img.h)
  let m = p.map
  result = 1.0
  result = max(result, abs(iw * (ca * m[0] + sa * m[2]) / pt.ex))
  result = max(result, abs(iw * (ca * m[1] + sa * m[3]) / pt.ex))
  result = max(result, abs(ih * (-sa * m[0] + ca * m[2]) / pt.ey))
  result = max(result, abs(ih * (-sa * m[1] + ca * m[3]) / pt.ey))

proc withMip*(p: Paint): Paint =
  ## The same paint sampling the mipmap level that best matches the
  ## draw footprint (`patternTexelsPerPx`), so heavy minification
  ## filters instead of aliasing. Level 0 (at or above native size)
  ## returns `p` unchanged: magnification output is bit-identical,
  ## and every backend (scalar, JIT, Metal) needs no kernel changes
  ## since the level is just a smaller image. Anisotropic footprints
  ## take the worst axis (documented over-blur, still better than
  ## dropout). The level shares the base flags.
  if p.kind != pkPattern or p.pattern.img == nil:
    return p
  let lod = p.pattern.img.lodFor(p.patternTexelsPerPx())
  if lod <= 0:
    return p
  result = p
  result.pattern.img = p.pattern.img.mipFor(lod)

proc sample*(p: Paint, x, y: float64): Color =
  case p.kind
  of pkSolid:
    p.solid
  of pkLinear:
    let q = p.map.apply(x, y)
    let dx = p.linear.ex - p.linear.sx
    let dy = p.linear.ey - p.linear.sy
    let len2 = dx*dx + dy*dy
    var t = 0.0
    if len2 > 1e-12:
      t = ((q.x - p.linear.sx)*dx + (q.y - p.linear.sy)*dy) / len2
    if p.linear.stops.len > 0:
      sampleStops(p.linear.stops, t)
    else:
      lerpColor(p.linear.icol, p.linear.ocol, t)
  of pkRadial:
    let q = p.map.apply(x, y)
    let dx = q.x - p.radial.cx
    let dy = q.y - p.radial.cy
    let dist = sqrt(dx*dx + dy*dy)
    # NanoVG floors the feather at one unit so degenerate rings still
    # transition instead of stepping.
    let f = max(1.0, p.radial.outr - p.radial.inr)
    if p.radial.stops.len > 0:
      sampleStops(p.radial.stops, (dist - p.radial.inr) / f)
    else:
      lerpColor(p.radial.icol, p.radial.ocol, (dist - p.radial.inr) / f)
  of pkBox:
    let q = p.map.apply(x, y)
    let sd = sdRoundBox(q.x - p.box.cx, q.y - p.box.cy, p.box.ex,
      p.box.ey, p.box.radius)
    let f = max(1.0, p.box.feather)
    if p.box.stops.len > 0:
      sampleStops(p.box.stops, (sd + f * 0.5) / f)
    else:
      lerpColor(p.box.icol, p.box.ocol, (sd + f * 0.5) / f)
  of pkPattern:
    if p.pattern.img == nil or abs(p.pattern.ex) < 1e-12 or
        abs(p.pattern.ey) < 1e-12:
      return rgbaf(0, 0, 0, 0)
    let q = p.map.apply(x, y)
    let dx = q.x - p.pattern.ox
    let dy = q.y - p.pattern.oy
    let ca = cos(p.pattern.angle)
    let sa = sin(p.pattern.angle)
    # Inverse of NanoVG's rotate-then-offset pattern xform.
    let u = (ca*dx + sa*dy) / p.pattern.ex
    let v = (-sa*dx + ca*dy) / p.pattern.ey
    let t = sampleImage(p.pattern.img, u, v)
    let tint = p.pattern.tint
    rgbaf(t.r * tint.r, t.g * tint.g, t.b * tint.b, t.a * tint.a)
