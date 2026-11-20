## Frame renderer: model to `nvg/Canvas` calls.
##
## Phase 3 scope (layers before paints): hierarchy, opacity, blends,
## precomps, track mattes, masks. Geometry covers rect/ellipse/path/star;
## fills and strokes render solid (gradients fall back to their first stop,
## trim/dash/repeaters are parsed but ignored — phase 4).
## Fill rule is always even-odd; direction flags are ignored.

import std/math
import ../canvas
import ../surface
import ../types
import ../paint
import ../path
import ../pathmeasure
import ../layer
import ../transform
import ./model
import ./keyframe
import ./scene
import ./asset
import ./paints

proc applyLocal*(c: Canvas, m: Xform) =
  ## Compose a local matrix under the current canvas state: X = outer * m.
  ## `Canvas.applyTransform` pre-multiplies (X = m * outer), which is only
  ## correct on an identity state; nested group/layer transforms need the
  ## post-composed form (pure translations commute, which is why this only
  ## showed on rotated/scaled content).
  let outer = c.currentTransform()
  c.resetTransform()
  c.applyTransform(multiply(outer, m))

proc compOpOf*(b: BlendMode): CompOp =
  case b
  of bmNormal: coSourceOver
  of bmMultiply: coMultiply
  of bmScreen: coScreen
  of bmOverlay: coOverlay
  of bmDarken: coDarken
  of bmLighten: coLighten

proc emitPath*(c: Canvas, p: PathData) =
  ## Append path geometry to the current canvas path (no fill/stroke).
  if p.verts.len == 0: return
  c.moveTo(p.verts[0].x, p.verts[0].y)
  for i in 1 ..< p.verts.len:
    let cp1x = p.verts[i - 1].x + p.outT[i - 1].x
    let cp1y = p.verts[i - 1].y + p.outT[i - 1].y
    let cp2x = p.verts[i].x + p.inT[i].x
    let cp2y = p.verts[i].y + p.inT[i].y
    c.bezierTo(cp1x, cp1y, cp2x, cp2y, p.verts[i].x, p.verts[i].y)
  if p.closed: c.closePath()

proc firstStopColor*(stops: seq[float64]): LColor =
  ## Legacy solid fallback (kept for empty payloads).
  lcolor(1, 1, 1)

proc bakeStops*(raw: seq[float64], points: int, opacity: float64):
    seq[GradientStop] =
  ## Interpret a Bodymovin stop list and fold the paint opacity into the
  ## stop alphas (nvg paints carry no separate opacity).
  result = lottieStops(raw, points)
  let k = clamp(opacity / 100.0, 0.0, 1.0)
  for i in 0 ..< result.len:
    result[i].color.a = clamp(result[i].color.a * k, 0.0, 1.0)

proc gradientPaint*(c: Canvas, radial: bool, s, e: Vec2,
    stops: seq[GradientStop]): Paint =
  if not radial:
    c.linearGradientStops(s.x, s.y, e.x, e.y, stops)
  else:
    let r = hypot(e.x - s.x, e.y - s.y)
    c.radialGradientStops(s.x, s.y, 0.0, r, stops)

proc paintForFill*(s: Shape, frame: float64): tuple[col: LColor, op: float64] =
  case s.kind
  of skFill:
    (valueAt(s.fColor, frame), valueAt(s.fOpacity, frame) / 100.0)
  else:
    (lcolor(0, 0, 0), 0.0)

proc buildTempPath*(tp: var Path, s: Shape, frame: float64,
    rcRadius: float64, xf: Xform) =
  ## Mirror `drawGeom` onto an explicit `nvg/Path` with caller-supplied
  ## transform (used for trim: flatten in device space, then extract).
  case s.kind
  of skRect:
    let pos = valueAt(s.rPos, frame)
    let size = valueAt(s.rSize, frame)
    let round = valueAt(s.rRound, frame) + rcRadius
    if round > 0.0:
      tp.roundedRect(pos.x - size.x / 2.0, pos.y - size.y / 2.0,
        size.x, size.y, round, xf)
    else:
      tp.rect(pos.x - size.x / 2.0, pos.y - size.y / 2.0,
        size.x, size.y, xf)
  of skEllipse:
    let pos = valueAt(s.ePos, frame)
    let size = valueAt(s.eSize, frame)
    tp.ellipse(pos.x, pos.y, size.x / 2.0, size.y / 2.0, xf)
  of skPath:
    let p = valueAt(s.pShape, frame)
    if p.verts.len == 0: return
    tp.moveTo(p.verts[0].x, p.verts[0].y, xf)
    for i in 1 ..< p.verts.len:
      tp.bezierTo(p.verts[i - 1].x + p.outT[i - 1].x,
        p.verts[i - 1].y + p.outT[i - 1].y,
        p.verts[i].x + p.inT[i].x, p.verts[i].y + p.inT[i].y,
        p.verts[i].x, p.verts[i].y, xf)
    if p.closed: tp.closePath()
  of skStar:
    let pos = valueAt(s.sPos, frame)
    let orn = valueAt(s.sOuterR, frame)
    let inr = valueAt(s.sInnerR, frame)
    let rot = valueAt(s.sRot, frame) * PI / 180.0 - PI / 2.0
    let n = max(3, int(valueAt(s.sPoints, frame) + 0.5))
    let ornd = clamp(valueAt(s.sOuterRound, frame) / 100.0, 0.0, 1.0)
    let irnd = clamp(valueAt(s.sInnerRound, frame) / 100.0, 0.0, 1.0)
    if s.starType == stPolygon:
      tp.polygon(pos.x, pos.y, orn, n, rot, xf, ornd)
    else:
      tp.star(pos.x, pos.y, orn, inr, n, rot, xf, ornd, irnd)
  else:
    discard

proc drawGeom*(c: Canvas, s: Shape, frame: float64, rcRadius: float64) =
  ## Emit one geometry shape's outline, wrapped in its own path.
  c.beginPath()
  case s.kind
  of skRect:
    let pos = valueAt(s.rPos, frame)
    let size = valueAt(s.rSize, frame)
    let round = valueAt(s.rRound, frame) + rcRadius
    if round > 0.0:
      c.roundedRect(pos.x - size.x / 2.0, pos.y - size.y / 2.0,
        size.x, size.y, round)
    else:
      c.rect(pos.x - size.x / 2.0, pos.y - size.y / 2.0, size.x, size.y)
  of skEllipse:
    let pos = valueAt(s.ePos, frame)
    let size = valueAt(s.eSize, frame)
    c.ellipse(pos.x, pos.y, size.x / 2.0, size.y / 2.0)
  of skPath:
    emitPath(c, valueAt(s.pShape, frame))
  of skStar:
    let pos = valueAt(s.sPos, frame)
    let orn = valueAt(s.sOuterR, frame)
    let inr = valueAt(s.sInnerR, frame)
    let rot = valueAt(s.sRot, frame) * PI / 180.0 - PI / 2.0
    let n = max(3, int(valueAt(s.sPoints, frame) + 0.5))
    let ornd = clamp(valueAt(s.sOuterRound, frame) / 100.0, 0.0, 1.0)
    let irnd = clamp(valueAt(s.sInnerRound, frame) / 100.0, 0.0, 1.0)
    if s.starType == stPolygon:
      c.polygon(pos.x, pos.y, orn, n, rot, ornd)
    else:
      c.star(pos.x, pos.y, orn, inr, n, rot, ornd, irnd)
  else:
    discard

type TrimSeg* = tuple[lo, hi: float64, loop, active: bool]

proc groupTrim*(shapes: seq[Shape], frame: float64): TrimSeg =
  ## Last non-hidden trim in the list (simultaneous per shape; individual
  ## mode falls back to simultaneous). Inactive when no trim or full.
  for i in countdown(shapes.len - 1, 0):
    let s = shapes[i]
    if s.kind == skTrim and not s.hidden:
      let seg = trimSegment(valueAt(s.tStart, frame),
        valueAt(s.tEnd, frame), valueAt(s.tOffset, frame))
      if seg.empty: return (0, 0, false, true)
      if seg.full: return (0, 0, false, false)
      return (seg.lo, seg.hi, seg.loop, true)
  (0, 0, false, false)

proc emitGeomPath*(c: Canvas, s: Shape, frame: float64, rcRadius: float64,
    trim: TrimSeg, forFill: bool) =
  ## Emit geometry, trimmed when `trim.active`. Trimming flattens in
  ## device space (same tessellation as a normal fill) and replays the
  ## extracted range with the transform reset, so beziers under trim
  ## are polylines (documented approximation). Fills implicitly close
  ## open contours (NanoVG convention); strokes keep partial ranges open
  ## except fully extracted loops.
  if not trim.active:
    drawGeom(c, s, frame, rcRadius)
    if forFill: c.closePath()
    return
  var tp = Path()
  buildTempPath(tp, s, frame, rcRadius, c.currentTransform())
  let polys = tp.flatten(c.tessTol, DefaultDistTol)
  let total = polyLength(polys)
  echo "trim polys=", polys.len, " total=", total
  if total <= 0.0: return
  var ranges: seq[tuple[a, b: float64]] = @[]
  if trim.loop:
    ranges.add((trim.lo * total, total))
    ranges.add((0.0, trim.hi * total))
  else:
    ranges.add((trim.lo * total, trim.hi * total))
  c.beginPath()
  c.save()
  c.resetTransform()
  for (a, b) in ranges:
    echo "range ", a, "..", b
    for sp in extract(polys, a, b):
      echo "  sub pts=", sp.pts.len, " closed=", sp.closed
      if sp.pts.len == 0: continue
      c.moveTo(sp.pts[0].x, sp.pts[0].y)
      for i in 1 ..< sp.pts.len:
        c.lineTo(sp.pts[i].x, sp.pts[i].y)
      if forFill or sp.closed: c.closePath()
  c.restore()

proc styleStroke*(c: Canvas, width, cap, join: float64, miter: float64,
    dashes: seq[Animated[float64]], dashOff: Animated[float64],
    frame: float64) =
  c.setStrokeWidth(width)
  c.setLineCap(case int(cap)
    of 2: lcRound
    of 3: lcSquare
    else: lcButt)
  c.setLineJoin(case int(join)
    of 2: ljRound
    of 3: ljBevel
    else: ljMiter)
  c.setMiterLimit(max(1.01, miter))
  var vals: seq[float64] = @[]
  for d in dashes: vals.add(valueAt(d, frame))
  vals.add(valueAt(dashOff, frame))
  let (pat, off) = dashSplit(vals)
  if pat.len == 0:
    c.setLineDash(newSeq[float64](), 0.0)
  else:
    # Dash units are local; the rasterizer consumes device units.
    let k = averageScale(c.currentTransform())
    var sp: seq[float64] = @[]
    for v in pat: sp.add(v * k)
    c.setLineDash(sp, off * k)

proc renderShapes*(c: Canvas, shapes: seq[Shape], frame: float64) =
  ## Flat group renderer. rlottie order: the model keeps children
  ## front-to-back, drawing runs back-to-front, so geometries and nested
  ## groups draw in reverse file order. Paints style the geometries that
  ## precede them in file order (rlottie `Paint::addPathItems` claims paths
  ## added since group entry): each geometry draws once per following
  ## fill/stroke sibling in the same list. A bare `tr` re-bases the shapes
  ## that follow it in file order.
  var rcRadius = 0.0
  for s in shapes:
    if s.kind == skRoundedCorner and not s.hidden:
      rcRadius += valueAt(s.rcRadius, frame)
  let trim = groupTrim(shapes, frame)
  # Scopes of bare `tr`s (forward semantics); drawn under the transform at
  # the tr position, skipped at their own reverse position.
  var scoped = newSeq[bool](shapes.len)
  for i in 0 ..< shapes.len:
    if shapes[i].kind == skTr and not shapes[i].hidden:
      var j = i + 1
      while j < shapes.len and shapes[j].kind != skTr:
        scoped[j] = true
        inc j
  var i = shapes.len - 1
  while i >= 0:
    if scoped[i]:
      dec i
      continue
    let s = shapes[i]
    if s.hidden:
      dec i
      continue
    case s.kind
    of skGroup:
      c.save()
      let t = s.gTransform
      c.applyLocal(localMatrix(t, frame))
      renderShapes(c, s.children, frame)
      c.restore()
    of skTr:
      c.save()
      c.applyLocal(localMatrix(s.tr, frame))
      # A bare `tr` re-bases the shapes that follow it in file order.
      var j = i + 1
      var rest: seq[Shape] = @[]
      while j < shapes.len and shapes[j].kind != skTr:
        rest.add(shapes[j])
        inc j
      renderShapes(c, rest, frame)
      c.restore()
    of skRect, skEllipse, skPath, skStar:
      # Sibling paints listed after this geometry (rlottie claims paths
      # added before the paint); default to opaque black when none.
      var fills: seq[Shape] = @[]
      var strokes: seq[Shape] = @[]
      for q in shapes[i + 1 .. ^1]:
        if q.hidden: continue
        if q.kind in {skFill, skGFill}: fills.add(q)
        elif q.kind in {skStroke, skGStroke}: strokes.add(q)
      if fills.len == 0 and strokes.len == 0:
        emitGeomPath(c, s, frame, rcRadius, trim, true)
        c.setFillColor(color(0, 0, 0, 1.0))
        c.fill()
      else:
        for f in fills:
          if f.kind == skFill:
            let (col, op) = paintForFill(f, frame)
            if op <= 0.0: continue
            emitGeomPath(c, s, frame, rcRadius, trim, true)
            c.setFillColor(color(col.r, col.g, col.b, op))
            c.fill()
          else:
            let stops = bakeStops(valueAtRaw(f.gfStops, frame),
              f.gfPoints, valueAt(f.gfOpacity, frame))
            emitGeomPath(c, s, frame, rcRadius, trim, true)
            c.setFillPaint(gradientPaint(c, f.gfType == gtRadial,
              valueAt(f.gfStart, frame), valueAt(f.gfEnd, frame), stops))
            c.fill()
        for st in strokes:
          if st.kind == skStroke:
            let op = valueAt(st.sOpacity, frame) / 100.0
            if op <= 0.0: continue
            let col = valueAt(st.sColor, frame)
            emitGeomPath(c, s, frame, rcRadius, trim, false)
            styleStroke(c, valueAt(st.sWidth, frame),
              float64(st.sCap), float64(st.sJoin), st.sMiter,
              st.dashes, st.dashOffset, frame)
            c.setStrokeColor(color(col.r, col.g, col.b, op))
            c.stroke()
          else:
            let op = valueAt(st.gsOpacity, frame) / 100.0
            if op <= 0.0: continue
            let stops = bakeStops(valueAtRaw(st.gsStops, frame),
              st.gsPoints, valueAt(st.gsOpacity, frame))
            emitGeomPath(c, s, frame, rcRadius, trim, false)
            styleStroke(c, valueAt(st.gsWidth, frame),
              float64(st.gsCap), float64(st.gsJoin), st.gsMiter,
              st.gsDashes, st.gsDashOffset, frame)
            c.setStrokePaint(gradientPaint(c, st.gsType == gtRadial,
              valueAt(st.gsStart, frame), valueAt(st.gsEnd, frame),
              stops))
            c.stroke()
      # Skip sibling paints already consumed with this geometry run.
      # (Paints before any geometry paint nothing; harmless.)
    else:
      discard
    dec i

proc renderMaskSurface*(anim: Animation, layers: seq[Layer], l: Layer,
    frame: float64, w, h: int): Surface =
  ## White mask whose alpha is the combined layer masks.
  result = newSurface(w, h)
  result.clear(color(0, 0, 0, 0))
  let mc = newCanvas(w, h)
  var combined: Surface = nil
  for m in l.masks:
    if m.mode == mmNone: continue
    mc.clear(color(0, 0, 0, 0))
    let mp = valueAt(m.shape, frame)
    if mp.verts.len == 0: continue
    mc.save()
    mc.applyLocal(worldMatrix(layers, l, frame))
    mc.beginPath()
    emitPath(mc, mp)
    mc.setFillColor(color(1, 1, 1,
      clamp(valueAt(m.opacity, frame) / 100.0, 0.0, 1.0)))
    mc.fill()
    mc.restore()
    var one = maskFromAlpha(mc.surface)
    if m.inverted: one = maskInvert(one)
    let op =
      case m.mode
      of mmAdd: mAdd
      of mmSubtract: mSubtract
      of mmIntersect: mIntersect
      of mmDifference: mDifference
      of mmNone: mAdd
    if combined == nil:
      # Seed from the first mask: subtract cuts out of full coverage,
      # the rest start from the mask itself.
      case m.mode
      of mmSubtract: combined = maskInvert(one)
      else: combined = one
    else:
      combined = maskCombine(combined, one, op)
  if combined == nil:
    result.clear(color(1, 1, 1, 1))
  else:
    result = combined

proc renderLayers*(c: Canvas, anim: Animation, layers: seq[Layer],
  frame: float64, lib: AssetLib)

proc renderLayerContent*(c: Canvas, anim: Animation, layers: seq[Layer],
    l: Layer, frame: float64, lib: AssetLib) =
  case l.layerType
  of ltShape:
    renderShapes(c, l.shapes, frame)
  of ltSolid:
    c.beginPath()
    c.rect(0, 0, l.solidSize.x, l.solidSize.y)
    c.setFillColor(color(l.solidColor.r, l.solidColor.g,
      l.solidColor.b, 1.0))
    c.fill()
  of ltPrecomp:
    let a = assetById(anim, l.refId)
    if a != nil and a.kind == akPrecomp:
      # `frame` is already this layer's local time (renderLayers remapped
      # before dispatch); remapping again would shift by `st` twice.
      c.save()
      c.intersectScissor(0, 0, l.solidSize.x, l.solidSize.y)
      renderLayers(c, anim, a.layers, frame, lib)
      c.restore()
  of ltImage:
    # Image layers paint the asset stretched to the layer size. Unknown
    # handles (never registered) are skipped.
    let h = lib.imageHandle(l.refId)
    if h != 0 and l.solidSize.x > 0.0 and l.solidSize.y > 0.0:
      c.beginPath()
      c.rect(0, 0, l.solidSize.x, l.solidSize.y)
      c.setFillPaint(c.imagePattern(0, 0, l.solidSize.x, l.solidSize.y,
        0.0, h, 1.0))
      c.fill()
  of ltNull, ltText:
    # Null: no output (parenting only). Text: deferred.
    discard

proc renderLayers*(c: Canvas, anim: Animation, layers: seq[Layer],
    frame: float64, lib: AssetLib) =
  var skip: seq[int] = @[]
  for idx in drawOrder(layers):
    if idx in skip: continue
    let l = layers[idx]
    if l.hidden: continue
    if l.layerType == ltNull: continue # parenting only
    if l.layerType == ltText: continue # deferred pass
    if not isActive(l, frame): continue
    let lf = remapFrame(l, anim, frame)
    # Opacity, like every other animated property, evaluates at the layer's
    # local time (rlottie maps the frame before Layer::update reads it).
    let op = combinedOpacity(layers, l, lf)
    if op <= 0.0: continue
    let wm = worldMatrix(layers, l, lf)
    let matte = matteSource(layers, idx)
    if matte != nil and not isActive(matte, frame):
      continue # matte invisible: DestIn yields nothing; skip pair
    if matte != nil: skip.add(idx - 1)
    # Flatten precomps with fractional opacity offscreen so the alpha
    # applies once to the group, not per shape.
    let needsOffscreen = matte != nil or l.masks.len > 0 or
      (l.layerType == ltPrecomp and op < 1.0)
    if needsOffscreen:
      let w = c.width()
      let h = c.height()
      let tc = newCanvas(w, h)
      tc.save()
      tc.applyLocal(wm)
      tc.setGlobalAlpha(op)
      tc.setCompositeOp(compOpOf(l.blend))
      renderLayerContent(tc, anim, layers, l, lf, lib)
      tc.restore()
      var content = tc.surface
      if l.masks.len > 0:
        let m = renderMaskSurface(anim, layers, l, lf, w, h)
        var masked = newSurface(w, h)
        masked.clear(color(0, 0, 0, 0))
        blitMasked(masked, content, m, 0, 0)
        content = masked
      if matte != nil:
        let mw = newCanvas(w, h)
        mw.save()
        mw.applyLocal(worldMatrix(layers, matte,
          remapFrame(matte, anim, frame)))
        mw.setGlobalAlpha(combinedOpacity(layers, matte, frame))
        renderLayerContent(mw, anim, layers, matte,
          remapFrame(matte, anim, frame), lib)
        mw.restore()
        let mAlpha = maskFromAlpha(mw.surface)
        var out2 = newSurface(w, h)
        out2.clear(color(0, 0, 0, 0))
        case l.matte
        of mtAlpha:
          blitMasked(out2, content, mAlpha, 0, 0)
        of mtAlphaInv:
          blitMasked(out2, content, maskInvert(mAlpha), 0, 0)
        of mtLuma:
          blitMasked(out2, content, maskFromLuminance(mw.surface), 0, 0)
        of mtLumaInv:
          blitMasked(out2, content,
            maskInvert(maskFromLuminance(mw.surface)), 0, 0)
        of mtNone:
          discard
        content = out2
      compositeOver(c.surface, content, 0, 0, compOpOf(l.blend))
    else:
      c.save()
      c.applyLocal(wm)
      c.setGlobalAlpha(op)
      c.setCompositeOp(compOpOf(l.blend))
      renderLayerContent(c, anim, layers, l, lf, lib)
      c.restore()

proc renderFrame*(c: Canvas, anim: Animation, frame: float64) =
  ## Draw `frame` onto `c` (caller clears first). Image layers need a
  ## registered `AssetLib`; without one they are skipped.
  renderLayers(c, anim, anim.layers, frame, AssetLib())

proc renderFrame*(c: Canvas, anim: Animation, frame: float64,
    lib: AssetLib) =
  ## Draw `frame` with image assets from `lib` (see `registerAll`).
  renderLayers(c, anim, anim.layers, frame, lib)
