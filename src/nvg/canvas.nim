## Immediate-mode 2D canvas (redesigned API).
##
## Not a `nvg*` name-for-name port: drawing state lives on a `Canvas`
## object with methods (`canvas.rect(...)`, `canvas.fill()`, ...),
## transforms are pre-multiplied like NanoVG, and path coordinates are
## captured in device space at verb time. Text renders through harfnim
## shaping into ordinary path fills/strokes (see `nvg/text`).

import std/tables
import harfnim/feature
import ./types
import ./transform
import ./path
import ./paint
import ./surface
import ./dash
import ./backend
import ./text

export types
export transform except apply
export paint
export surface except blendPixel
export text

type
  DrawState* = object
    xform*: Xform
    fill*: Paint
    stroke*: Paint
    strokeWidth*: float64
    lineCap*: LineCap
    lineJoin*: LineJoin
    miterLimit*: float64
    dash*: seq[float64]
    dashOffset*: float64
    alpha*: float64
    clip*: Clip
    compOp*: CompOp
    fontFace*: int
    fontSize*: float64
    textHAlign*: TextHAlign
    textVAlign*: TextVAlign
    letterSpacing*: float64
    lineHeightMul*: float64

  Canvas* = ref object
    surf*: Surface
    states*: seq[DrawState]
    path*: Path
    backend*: Backend
    pixelRatio*: float64
    tessTol*: float64
    shapeAA*: bool
    images*: Table[int, Image]
    nextImageId*: int
    fonts*: Table[int, TextFont]
    fontNames*: Table[string, int]
    nextFontId*: int

proc defaultState*(): DrawState =
  DrawState(xform: identity(), fill: solidPaint(rgbf(0, 0, 0)),
    stroke: solidPaint(rgbf(0, 0, 0)), strokeWidth: 1.0,
    lineCap: lcButt, lineJoin: ljMiter, miterLimit: 4.0, dash: @[],
    dashOffset: 0.0, alpha: 1.0,
    clip: Clip(enabled: false), compOp: coSourceOver, fontFace: 0,
    fontSize: 16.0, textHAlign: thaLeft, textVAlign: tvaBaseline,
    letterSpacing: 0.0, lineHeightMul: 1.2)

proc newCanvas*(w, h: int, backend: Backend = nil): Canvas =
  result = Canvas(surf: newSurface(w, h), states: @[defaultState()],
    backend: if backend == nil: Backend(newCpuBackend()) else: backend,
    pixelRatio: 1.0, tessTol: DefaultTessTol, shapeAA: true,
    images: initTable[int, Image](), nextImageId: 1,
    fonts: initTable[int, TextFont](), fontNames: initTable[string, int](),
    nextFontId: 1)

proc width*(c: Canvas): int = c.surf.w
proc height*(c: Canvas): int = c.surf.h
proc surface*(c: Canvas): Surface = c.surf

proc state*(c: Canvas): var DrawState = c.states[^1]

proc setPixelRatio*(c: Canvas, ratio: float64) =
  c.pixelRatio = max(0.25, ratio)
  c.tessTol = DefaultTessTol / c.pixelRatio

proc clear*(c: Canvas, col: Color) =
  c.surf.clear(col)

# --- State stack ---

proc save*(c: Canvas) =
  c.states.add(c.states[^1])

proc restore*(c: Canvas) =
  if c.states.len > 1:
    c.states.setLen(c.states.len - 1)

proc reset*(c: Canvas) =
  c.states[^1] = defaultState()

# --- Style ---

proc setFillColor*(c: Canvas, col: Color) =
  c.states[^1].fill = solidPaint(col)

proc setFillPaint*(c: Canvas, p: Paint) =
  c.states[^1].fill = p

proc setStrokeColor*(c: Canvas, col: Color) =
  c.states[^1].stroke = solidPaint(col)

proc setStrokePaint*(c: Canvas, p: Paint) =
  c.states[^1].stroke = p

proc setStrokeWidth*(c: Canvas, w: float64) =
  c.states[^1].strokeWidth = max(0.0, w)

proc setLineCap*(c: Canvas, cap: LineCap) =
  c.states[^1].lineCap = cap

proc setLineJoin*(c: Canvas, join: LineJoin) =
  c.states[^1].lineJoin = join

proc setMiterLimit*(c: Canvas, limit: float64) =
  c.states[^1].miterLimit = max(1.01, limit)

proc setLineDash*(c: Canvas, dashes: openArray[float64],
    offset = 0.0) =
  ## Dash pattern for subsequent strokes: alternating on/off lengths in
  ## user units (scaled with the transform like the width). Empty means
  ## solid; non-positive entries are dropped, odd counts repeat doubled,
  ## and `offset` wraps modulo the total (see `dash.applyDash`). Applies
  ## after flatten, before stroke expansion; each "on" run gets the
  ## current caps.
  c.states[^1].dash = normalizeDash(dashes)
  c.states[^1].dashOffset = offset

proc lineDash*(c: Canvas): seq[float64] =
  c.states[^1].dash

proc setGlobalAlpha*(c: Canvas, a: float64) =
  c.states[^1].alpha = clamp01(a)

proc setCompositeOp*(c: Canvas, op: CompOp) =
  ## Porter-Duff composite operation applied to subsequent fills and
  ## strokes (see `surface.blendPixel`).
  c.states[^1].compOp = op

proc setShapeAA*(c: Canvas, enabled: bool) =
  ## Master antialiasing toggle (supersampled coverage in `raster`).
  c.shapeAA = enabled

# --- Transforms (pre-multiply, like NanoVG) ---

proc resetTransform*(c: Canvas) =
  c.states[^1].xform = identity()

proc applyTransform*(c: Canvas, m: Xform) =
  c.states[^1].xform = multiply(m, c.states[^1].xform)

proc translate*(c: Canvas, x, y: float64) =
  c.applyTransform(translate(x, y))

proc rotate*(c: Canvas, angleRad: float64) =
  c.applyTransform(rotate(angleRad))

proc scale*(c: Canvas, x, y: float64) =
  c.applyTransform(scale(x, y))

proc skewX*(c: Canvas, angleRad: float64) =
  c.applyTransform(skewX(angleRad))

proc skewY*(c: Canvas, angleRad: float64) =
  c.applyTransform(skewY(angleRad))

proc currentTransform*(c: Canvas): Xform =
  c.states[^1].xform

# --- Scissor (captured in device space, like NanoVG) ---

proc deviceAabb(c: Canvas, x, y, w, h: float64):
    tuple[x0, y0, x1, y1: float64] =
  ## Map a user-space rect through the current transform to a
  ## device-space AABB by projecting all four corners. Exact under
  ## rotation, unlike an average-scale approximation.
  let ww = max(0.0, w)
  let hh = max(0.0, h)
  let m = c.states[^1].xform
  var x0 = Inf
  var y0 = Inf
  var x1 = NegInf
  var y1 = NegInf
  for (cx, cy) in [(x, y), (x + ww, y), (x + ww, y + hh), (x, y + hh)]:
    let q = m.apply(cx, cy)
    x0 = min(x0, q.x)
    y0 = min(y0, q.y)
    x1 = max(x1, q.x)
    y1 = max(y1, q.y)
  (x0, y0, x1, y1)

proc scissor*(c: Canvas, x, y, w, h: float64) =
  let (x0, y0, x1, y1) = c.deviceAabb(x, y, w, h)
  c.states[^1].clip = Clip(enabled: true, x0: x0, y0: y0, x1: x1, y1: y1)

proc intersectScissor*(c: Canvas, x, y, w, h: float64) =
  let prev = c.states[^1].clip
  if not prev.enabled:
    c.scissor(x, y, w, h)
    return
  let (x0, y0, x1, y1) = c.deviceAabb(x, y, w, h)
  let nx0 = max(prev.x0, x0)
  let ny0 = max(prev.y0, y0)
  let nx1 = min(prev.x1, x1)
  let ny1 = min(prev.y1, y1)
  c.states[^1].clip = Clip(enabled: true, x0: nx0, y0: ny0,
    x1: max(nx0, nx1), y1: max(ny0, ny1))

proc resetScissor*(c: Canvas) =
  c.states[^1].clip = Clip(enabled: false)

# --- Path building (transform captured per verb) ---

proc beginPath*(c: Canvas) =
  c.path.clear()

proc moveTo*(c: Canvas, x, y: float64) =
  c.path.moveTo(x, y, c.states[^1].xform)

proc lineTo*(c: Canvas, x, y: float64) =
  c.path.lineTo(x, y, c.states[^1].xform)

proc bezierTo*(c: Canvas, c1x, c1y, c2x, c2y, x, y: float64) =
  c.path.bezierTo(c1x, c1y, c2x, c2y, x, y, c.states[^1].xform)

proc quadTo*(c: Canvas, cx, cy, x, y: float64) =
  c.path.quadTo(cx, cy, x, y, c.states[^1].xform)

proc arcTo*(c: Canvas, x1, y1, x2, y2, radius: float64) =
  c.path.arcTo(x1, y1, x2, y2, radius, c.states[^1].xform)

proc closePath*(c: Canvas) =
  c.path.closePath()

proc pathWinding*(c: Canvas, w: Winding) =
  ## Informational in v1 (filler is even-odd); kept for API parity.
  c.path.appendWinding(w)

proc rect*(c: Canvas, x, y, w, h: float64) =
  c.path.rect(x, y, w, h, c.states[^1].xform)

proc roundedRect*(c: Canvas, x, y, w, h, r: float64) =
  c.path.roundedRect(x, y, w, h, r, c.states[^1].xform)

proc roundedRectVarying*(c: Canvas, x, y, w, h, rtl, rtr, rbr,
    rbl: float64) =
  c.path.roundedRectVarying(x, y, w, h, rtl, rtr, rbr, rbl,
    c.states[^1].xform)

proc ellipse*(c: Canvas, cx, cy, rx, ry: float64) =
  c.path.ellipse(cx, cy, rx, ry, c.states[^1].xform)

proc circle*(c: Canvas, cx, cy, r: float64) =
  c.path.circle(cx, cy, r, c.states[^1].xform)

proc arc*(c: Canvas, cx, cy, r, a0, a1: float64, dir: Winding) =
  c.path.arc(cx, cy, r, a0, a1, dir, c.states[^1].xform)

proc polygon*(c: Canvas, cx, cy, radius: float64, n: int,
    rotation: float64, roundness = 0.0) =
  c.path.polygon(cx, cy, radius, n, rotation, c.states[^1].xform,
    roundness)

proc star*(c: Canvas, cx, cy, outerR, innerR: float64, n: int,
    rotation: float64, outerRound = 0.0, innerRound = 0.0) =
  c.path.star(cx, cy, outerR, innerR, n, rotation, c.states[^1].xform,
    outerRound, innerRound)

# --- Paint constructors (user space; transform captured as inverse) ---

proc captureMap(c: Canvas): Xform =
  ## Inverse of the current transform for paint sampling. Falls back to
  ## identity when singular (geometry collapses anyway in that case).
  result = identity()
  discard inverse(c.states[^1].xform, result)

proc linearGradient*(c: Canvas, sx, sy, ex, ey: float64, icol,
    ocol: Color): Paint =
  ## Gradient endpoints in user space; the current transform is baked in
  ## now, so later transform changes do not move the gradient.
  linearGradient(sx, sy, ex, ey, icol, ocol).withMap(c.captureMap())

proc radialGradient*(c: Canvas, cx, cy, inr, outr: float64, icol,
    ocol: Color): Paint =
  radialGradient(cx, cy, inr, outr, icol, ocol).withMap(c.captureMap())

proc linearGradientStops*(c: Canvas, sx, sy, ex, ey: float64,
    stops: openArray[GradientStop]): Paint =
  ## Multi-stop linear gradient in user space (see `paint.sampleStops`
  ## for interpolation/clamping). Transform baked now, like `linearGradient`.
  linearGradientStops(sx, sy, ex, ey, stops).withMap(c.captureMap())

proc radialGradientStops*(c: Canvas, cx, cy, inr, outr: float64,
    stops: openArray[GradientStop]): Paint =
  ## Multi-stop radial gradient in user space.
  radialGradientStops(cx, cy, inr, outr, stops).withMap(c.captureMap())

proc boxGradient*(c: Canvas, x, y, w, h, r, f: float64, icol,
    ocol: Color): Paint =
  ## `(x,y,w,h)` is the user-space box; `r` the corner radius and `f`
  ## the feather width in user units.
  boxGradient(x + w * 0.5, y + h * 0.5, w * 0.5, h * 0.5, r, f, icol,
    ocol).withMap(c.captureMap())

proc boxGradientStops*(c: Canvas, x, y, w, h, r, f: float64,
    stops: openArray[GradientStop]): Paint =
  ## Multi-stop box gradient in user space (see `paint.sampleStops`
  ## for interpolation/clamping). Transform baked now, like `boxGradient`.
  boxGradientStops(x + w * 0.5, y + h * 0.5, w * 0.5, h * 0.5, r, f,
    stops).withMap(c.captureMap())

# --- Images ---

proc createImageRGBA*(c: Canvas, w, h: int, flags: set[ImageFlag],
    data: openArray[uint8]): int =
  ## Register an RGBA8 image, returning a handle (0 on invalid sizes).
  if w <= 0 or h <= 0: return 0
  let id = c.nextImageId
  inc c.nextImageId
  c.images[id] = newImage(w, h, flags, data)
  id

proc updateImage*(c: Canvas, id: int, data: openArray[uint8]): bool =
  ## Replace image contents; size must match. Unknown ids fail.
  if id notin c.images: return false
  c.images[id].update(data)

proc deleteImage*(c: Canvas, id: int) =
  ## Drop an image from the registry. Paints already built from it keep
  ## sampling their shared copy (documented benign divergence from GPU
  ## backends, where sampling a deleted texture is undefined).
  c.images.del(id)

proc imageSize*(c: Canvas, id: int): tuple[w, h: int, ok: bool] =
  if id notin c.images: return (0, 0, false)
  let img = c.images[id]
  (img.w, img.h, true)

proc imagePattern*(c: Canvas, ox, oy, ex, ey, angle: float64, image: int,
    alpha: float64): Paint =
  ## Tile `image` over a user-space tile of `ex` by `ey` at `(ox,oy)`,
  ## rotated by `angle` radians, tinted by `alpha`. Unknown image ids
  ## paint transparent.
  var img: Image = nil
  if image in c.images:
    img = c.images[image]
  imagePattern(img, ox, oy, ex, ey, angle,
    rgbf(1, 1, 1).withAlpha(alpha)).withMap(c.captureMap())

# --- Fonts and text ---
#
# Stateful (NanoVG-like) register + style procs pair with stateless
# overloads that take an explicit `TextFont`. Both shape via harfnim,
# emit glyph outlines into a throwaway path (the current path is left
# untouched), and render through the active backend, so JIT kernels
# apply unchanged. Fills use nonzero winding (TrueType holes).

proc createFont*(c: Canvas, name, file: string, faceIndex = 0): int =
  ## Register a font from a file under `name` (TTC face via
  ## `faceIndex`), returning a nonzero handle, or 0 when the file is
  ## missing or unparseable. Re-registering a name replaces the entry
  ## but keeps its handle.
  try:
    let font = loadFontFile(file, faceIndex)
    font.name = name
    if name in c.fontNames:
      result = c.fontNames[name]
      c.fonts[result] = font
    else:
      result = c.nextFontId
      inc c.nextFontId
      c.fonts[result] = font
      c.fontNames[name] = result
  except CatchableError:
    result = 0

proc createFontMem*(c: Canvas, name: string, data: openArray[uint8],
    faceIndex = 0): int =
  ## Like `createFont` but parses `data` directly. Returns 0 on failure.
  try:
    let font = loadFontBytes(data, faceIndex)
    font.name = name
    if name in c.fontNames:
      result = c.fontNames[name]
      c.fonts[result] = font
    else:
      result = c.nextFontId
      inc c.nextFontId
      c.fonts[result] = font
      c.fontNames[name] = result
  except CatchableError:
    result = 0

proc findFont*(c: Canvas, name: string): int =
  ## Handle for a registered name, or 0 when unknown.
  if name in c.fontNames: c.fontNames[name] else: 0

proc setFontFace*(c: Canvas, name: string) =
  ## Select the font for subsequent stateful text (0 when unknown).
  c.states[^1].fontFace = c.findFont(name)

proc setFontFaceId*(c: Canvas, id: int) =
  ## Select the font by handle (0 when unknown).
  c.states[^1].fontFace = if id in c.fonts: id else: 0

proc setFontSize*(c: Canvas, px: float64) =
  c.states[^1].fontSize = max(1.0, px)

proc setTextAlign*(c: Canvas, ha: TextHAlign, va = tvaBaseline) =
  c.states[^1].textHAlign = ha
  c.states[^1].textVAlign = va

proc setLetterSpacing*(c: Canvas, px: float64) =
  c.states[^1].letterSpacing = px

proc setLineHeight*(c: Canvas, mul: float64) =
  ## Line step as a multiple of the font size (default 1.2).
  c.states[^1].lineHeightMul = max(0.0, mul)

proc lookupFont(c: Canvas, id: int): TextFont =
  if id in c.fonts: c.fonts[id] else: nil

proc widestAdvance(lay: TextLayout): float64 =
  for line in lay.lines:
    result = max(result, line.advance)

proc paintLayout(c: Canvas, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign, strokeMode: bool) =
  var p = Path()
  p.appendLayout(c.states[^1].xform, lay, x, y, ha, va)
  let polys = p.flatten(c.tessTol, DefaultDistTol)
  if polys.len == 0:
    return
  let st = c.states[^1]
  if strokeMode:
    let w = clamp(st.strokeWidth * averageScale(st.xform), 0.0, 200.0)
    if w <= 0.0:
      return
    let dashed = applyDash(polys, st.dash, st.dashOffset)
    if dashed.len == 0:
      return
    c.backend.stroke(c.surf, dashed, st.stroke, w, st.lineCap,
      st.lineJoin, st.miterLimit, st.alpha, st.clip, c.shapeAA,
      st.compOp)
  else:
    c.backend.fill(c.surf, polys, st.fill, st.alpha, st.clip,
      c.shapeAA, st.compOp, frNonZero)

proc shiftBounds(lay: TextLayout, x, y: float64, ha: TextHAlign,
    va: TextVAlign): Rect =
  let b = layoutBounds(lay, ha)
  rect(x + b.x, y + valignShift(lay, ha, va) + b.y, b.w, b.h)

proc fillText*(c: Canvas, x, y: float64, s: string,
    features: openArray[Feature] = []): float64 =
  ## Fill text with the current fill paint at `(x, y)` under the state
  ## font/align/spacing/line-height. `x` anchors each line per the
  ## horizontal align; `y` is the first baseline (or the ink
  ## top/middle/bottom for other vertical aligns). Returns the widest
  ## line advance. Draws nothing when no font is selected.
  let st = c.states[^1]
  let lay = layoutText(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, features)
  c.paintLayout(lay, x, y, st.textHAlign, st.textVAlign, false)
  widestAdvance(lay)

proc fillText*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, ha = thaLeft, va = tvaBaseline, letterSpacing = 0.0,
    lineHeightMul = 1.2,
    features: openArray[Feature] = []): float64 =
  ## Stateless overload: explicit font and style, canvas state untouched.
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features)
  c.paintLayout(lay, x, y, ha, va, false)
  widestAdvance(lay)

proc strokeText*(c: Canvas, x, y: float64, s: string,
    features: openArray[Feature] = []): float64 =
  ## Stroke text outlines with the current stroke style. Same layout
  ## and return conventions as `fillText`.
  let st = c.states[^1]
  let lay = layoutText(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, features)
  c.paintLayout(lay, x, y, st.textHAlign, st.textVAlign, true)
  widestAdvance(lay)

proc strokeText*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, ha = thaLeft, va = tvaBaseline, letterSpacing = 0.0,
    lineHeightMul = 1.2,
    features: openArray[Feature] = []): float64 =
  ## Stateless overload of `strokeText`.
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features)
  c.paintLayout(lay, x, y, ha, va, true)
  widestAdvance(lay)

proc textBounds*(c: Canvas, x, y: float64, s: string,
    features: openArray[Feature] = []): Rect =
  ## Measured ink bounds for stateful text at `(x, y)` (user space).
  let st = c.states[^1]
  let lay = layoutText(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, features)
  shiftBounds(lay, x, y, st.textHAlign, st.textVAlign)

proc textBounds*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, ha = thaLeft, va = tvaBaseline, letterSpacing = 0.0,
    lineHeightMul = 1.2,
    features: openArray[Feature] = []): Rect =
  ## Stateless overload of `textBounds` (no drawing).
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features)
  shiftBounds(lay, x, y, ha, va)

# --- Draw ---

proc flattened(c: Canvas): seq[SubPoly] =
  path.flatten(c.path, c.tessTol, DefaultDistTol)

proc fill*(c: Canvas, rule = frEvenOdd) =
  let polys = c.flattened()
  if polys.len == 0: return
  c.backend.fill(c.surf, polys, c.states[^1].fill,
    c.states[^1].alpha, c.states[^1].clip, c.shapeAA,
    c.states[^1].compOp, rule)

proc fillWithRule*(c: Canvas, rule: FillRule) =
  ## Fill the current path under `rule` (default `fill` is even-odd).
  ## Strokes always use even-odd (see `Backend.fill` docs).
  c.fill(rule)

proc stroke*(c: Canvas) =
  let polys = c.flattened()
  if polys.len == 0: return
  let st = c.states[^1]
  # Match `nvgStroke`: the width scales with the current transform and
  # clamps to [0, 200]. Deliberate divergence: NanoVG emulates sub-pixel
  # hairlines by widening to 1px and scaling alpha quadratically; our
  # supersampled filler measures true coverage of the real width, so no
  # alpha compensation is applied.
  let w = clamp(st.strokeWidth * averageScale(st.xform), 0.0, 200.0)
  if w <= 0.0: return
  let dashed = applyDash(polys, st.dash, st.dashOffset)
  if dashed.len == 0: return
  c.backend.stroke(c.surf, dashed, st.stroke, w,
    st.lineCap, st.lineJoin, st.miterLimit, st.alpha, st.clip,
    c.shapeAA, st.compOp)

# --- Output ---

proc savePng*(c: Canvas, path: string) =
  c.surf.savePng(path)

proc encodePng*(c: Canvas): seq[uint8] =
  c.surf.encodePng()
