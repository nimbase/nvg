## Immediate-mode 2D canvas (redesigned API).
##
## Not a `nvg*` name-for-name port: drawing state lives on a `Canvas`
## object with methods (`canvas.rect(...)`, `canvas.fill()`, ...),
## transforms are pre-multiplied like NanoVG, and path coordinates are
## captured in device space at verb time. Text renders through harfnim
## shaping into ordinary path fills/strokes (see `nvg/text`).

import std/tables
import std/math
import std/strutils
import std/unicode
import harfnim/feature
import ./types
import ./transform
import ./path
import ./paint
import ./surface
import ./dash
import ./backend
import ./text
import ./loadimage

export types
export transform except apply
export paint
export surface except blendPixel
export text
export loadimage

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
    lineHeightAbs*: float64
    fallbackFaces*: seq[int]

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
    letterSpacing: 0.0, lineHeightMul: 1.2, lineHeightAbs: 0.0,
    fallbackFaces: @[])

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

proc createImageMem*(c: Canvas, data: openArray[uint8],
    flags: set[ImageFlag]): int =
  ## Decode image bytes (format sniffed: PNG, JPEG, BMP, GIF first
  ## frame, QOI, PNM, TGA) into straight-alpha RGBA8, returning a
  ## handle, or 0 when the data is missing, unknown, or truncated.
  let d = decodeRgba8(data)
  if not d.ok or d.w <= 0 or d.h <= 0:
    return 0
  let id = c.nextImageId
  inc c.nextImageId
  c.images[id] = newImage(d.w, d.h, flags, d.pixels)
  id

proc createImageFile*(c: Canvas, file: string,
    flags: set[ImageFlag]): int =
  ## Like `createImageMem` but reads `file` first. Missing or
  ## undecodable files return 0.
  try:
    return c.createImageMem(cast[seq[uint8]](readFile(file)), flags)
  except CatchableError:
    return 0

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
  ## Line step as a multiple of the font size (default 1.2). Clears
  ## any absolute line height set by `setLineHeightPx`.
  c.states[^1].lineHeightMul = max(0.0, mul)
  c.states[^1].lineHeightAbs = 0.0

proc setLineHeightPx*(c: Canvas, px: float64) =
  ## Absolute baseline-to-baseline step in px, kept distinct from the
  ## font's own metrics. `0` (default) falls back to the multiplier;
  ## `setLineHeight` clears this back to `0`.
  c.states[^1].lineHeightAbs = max(0.0, px)

proc lookupFont(c: Canvas, id: int): TextFont =
  if id in c.fonts: c.fonts[id] else: nil

proc setFallbackFonts*(c: Canvas, names: varargs[string]) =
  ## Fallback faces for characters missing from the current font,
  ## tried in order (see `shapeCached`). Unknown names are skipped.
  ## Stateful: applies to every text call until changed.
  var ids: seq[int] = @[]
  for n in names:
    let id = c.findFont(n)
    if id != 0:
      ids.add(id)
  c.states[^1].fallbackFaces = ids

proc fallbackFonts(c: Canvas): seq[TextFont] =
  result = @[]
  for id in c.states[^1].fallbackFaces:
    let f = c.lookupFont(id)
    if f != nil:
      result.add(f)

proc widestAdvance(lay: TextLayout): float64 =
  for line in lay.lines:
    result = max(result, line.advance)

proc paintGroup(c: Canvas, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign, strokeMode: bool, wantColor: bool,
    color: Color)

proc paintLayout(c: Canvas, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign, strokeMode: bool) =
  var cols: seq[Color] = @[]
  for line in lay.lines:
    for g in line.glyphs:
      if g.hasColor:
        var seen = false
        for col in cols:
          if sameColor(col, g.color):
            seen = true
            break
        if not seen:
          cols.add(g.color)
  if cols.len == 0:
    c.paintGroup(lay, x, y, ha, va, strokeMode, false,
      rgbf(0, 0, 0))
  else:
    c.paintGroup(lay, x, y, ha, va, strokeMode, false,
      rgbf(0, 0, 0))
    for col in cols:
      c.paintGroup(lay, x, y, ha, va, strokeMode, true, col)

proc paintGroup(c: Canvas, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign, strokeMode: bool, wantColor: bool,
    color: Color) =
  var p = Path()
  p.appendLayoutSpan(c.states[^1].xform, lay, x, y, ha, va, wantColor,
    color)
  let polys = p.flatten(c.tessTol, DefaultDistTol)
  if polys.len == 0:
    return
  let st = c.states[^1]
  let paint = if wantColor: solidPaint(color) else:
    (if strokeMode: st.stroke else: st.fill)
  if strokeMode:
    let w = clamp(st.strokeWidth * averageScale(st.xform), 0.0, 200.0)
    if w <= 0.0:
      return
    let dashed = applyDash(polys, st.dash, st.dashOffset)
    if dashed.len == 0:
      return
    c.backend.stroke(c.surf, dashed, paint, w, st.lineCap,
      st.lineJoin, st.miterLimit, st.alpha, st.clip, c.shapeAA,
      st.compOp)
  else:
    c.backend.fill(c.surf, polys, paint, st.alpha, st.clip,
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
    st.letterSpacing, st.lineHeightMul, features, st.lineHeightAbs,
    c.fallbackFonts())
  c.paintLayout(lay, x, y, st.textHAlign, st.textVAlign, false)
  widestAdvance(lay)

proc fillText*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, ha = thaLeft, va = tvaBaseline, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless overload: explicit font and style, canvas state untouched.
  ## `lineHeightPx > 0` overrides the multiplier with an absolute step.
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features, lineHeightPx, fallbacks)
  c.paintLayout(lay, x, y, ha, va, false)
  widestAdvance(lay)

proc strokeText*(c: Canvas, x, y: float64, s: string,
    features: openArray[Feature] = []): float64 =
  ## Stroke text outlines with the current stroke style. Same layout
  ## and return conventions as `fillText`.
  let st = c.states[^1]
  let lay = layoutText(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, features, st.lineHeightAbs,
    c.fallbackFonts())
  c.paintLayout(lay, x, y, st.textHAlign, st.textVAlign, true)
  widestAdvance(lay)

proc strokeText*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, ha = thaLeft, va = tvaBaseline, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless overload of `strokeText`.
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features, lineHeightPx, fallbacks)
  c.paintLayout(lay, x, y, ha, va, true)
  widestAdvance(lay)

proc textBounds*(c: Canvas, x, y: float64, s: string,
    features: openArray[Feature] = []): Rect =
  ## Measured ink bounds for stateful text at `(x, y)` (user space).
  let st = c.states[^1]
  let lay = layoutText(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, features, st.lineHeightAbs,
    c.fallbackFonts())
  shiftBounds(lay, x, y, st.textHAlign, st.textVAlign)

proc textBounds*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, ha = thaLeft, va = tvaBaseline, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): Rect =
  ## Stateless overload of `textBounds` (no drawing).
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features, lineHeightPx, fallbacks)
  shiftBounds(lay, x, y, ha, va)

# --- Text boxes: wrap, justify, fit, overflow, box alignment ---

type
  BoxLayout* = object
    lay*: TextLayout
      ## Final shaped lines (post fit and scaleX).
    shift*: float64
      ## Baseline delta placing the block for the box vertical align
      ## (0 for `tvaBaseline`).

  WrapLine = tuple[para: int, idx: int, last: bool, text: string]

proc stopPad(spaceAdv, tabW, cur: float64): string =
  ## Spaces advancing from `cur` to the next multiple of `tabW`.
  if tabW <= 0.0 or spaceAdv <= 0.0:
    return " "
  let rem = cur - floor(cur / tabW) * tabW
  let need = if rem == 0.0: tabW else: tabW - rem
  let n = max(1, int(ceil(need / spaceAdv)))
  for _ in 0 ..< n:
    result.add(' ')

proc expandRun(font: TextFont, px: float64, lineSoFar: string,
    run: string, letterSpacing: float64, spaceAdv: float64,
    tabW: float64, features: openArray[Feature], cache: ShapeCache, fallbacks: openArray[TextFont]): string =
  ## Preserve-semantics expansion of one whitespace run: spaces
  ## verbatim, tabs to stops with a running advance.
  var cur = shapeCached(font, px, lineSoFar, letterSpacing,
    features, cache, fallbacks).advance
  for ch in run:
    if ch == ' ':
      result.add(' ')
      cur += spaceAdv
    else:
      let pad = stopPad(spaceAdv, tabW, cur)
      result.add(pad)
      cur += float64(pad.len) * spaceAdv

proc renderGap(font: TextFont, px: float64, lineSoFar: string, run: string,
    letterSpacing: float64, collapse: bool, spaceAdv: float64,
    tabW: float64, features: openArray[Feature], cache: ShapeCache, fallbacks: openArray[TextFont]): string =
  ## Render a raw whitespace run for layout. Collapsed: a single
  ## space, or a single tab stop when the run holds a tab (leading
  ## runs vanish). Preserved: spaces verbatim, tabs to stops with a
  ## running advance.
  if run.len == 0:
    return ""
  if collapse:
    if lineSoFar == "":
      return ""
    if '\t' in run:
      let adv0 = shapeCached(font, px, lineSoFar, letterSpacing,
        features, cache, fallbacks).advance
      return stopPad(spaceAdv, tabW, adv0)
    return " "
  expandRun(font, px, lineSoFar, run, letterSpacing, spaceAdv, tabW,
    features, cache, fallbacks)

proc expandPara(font: TextFont, px: float64, para: string,
    letterSpacing: float64, spaceAdv: float64, tabW: float64,
    features: openArray[Feature], cache: ShapeCache, fallbacks: openArray[TextFont]): string =
  ## Preserve-semantics expansion of a whole paragraph (for `twPre`):
  ## word chars verbatim, whitespace runs via `expandRun`.
  var run = ""
  for ch in para:
    if ch == ' ' or ch == '\t':
      run.add(ch)
    else:
      if run != "":
        result.add(expandRun(font, px, result, run, letterSpacing,
          spaceAdv, tabW, features, cache, fallbacks))
        run = ""
      result.add(ch)
  if run != "":
    result.add(expandRun(font, px, result, run, letterSpacing,
      spaceAdv, tabW, features, cache, fallbacks))

proc breakPieces(font: TextFont, px: float64, word: string,
    letterSpacing: float64, budget: float64, hyphen: string,
    features: openArray[Feature], cache: ShapeCache, fallbacks: openArray[TextFont]): seq[string] =
  ## Emergency-break `word` into budget-fitting fragments, `hyphen`
  ## suffixed but on the last. Never returns empty (a lone rune
  ## always fits somewhere).
  result = @[]
  var runes = word.toRunes()
  while runes.len > 0:
    if shapeCached(font, px, $runes, letterSpacing,
        features, cache, fallbacks).advance <= budget:
      result.add($runes)
      break
    var n = runes.len - 1
    while n > 1 and shapeCached(font, px, $runes[0 ..< n] & hyphen,
        letterSpacing, features, cache, fallbacks).advance > budget:
      dec n
    if n == 1 and shapeCached(font, px, $runes[0 ..< 1] & hyphen,
        letterSpacing, features, cache, fallbacks).advance > budget:
      # Even one rune plus hyphen overflows: bare rune, retry rest.
      result.add($runes[0 ..< 1])
      runes = runes[1 .. ^1]
      continue
    result.add($runes[0 ..< n] & hyphen)
    runes = runes[n .. ^1]

proc wrapAll(font: TextFont, px: float64, s: string,
    letterSpacing: float64, maxW: float64, indent: float64,
    o: TextBoxOpts, features: openArray[Feature], cache: ShapeCache, fallbacks: openArray[TextFont]): seq[WrapLine] =
  ## Greedy word wrap per paragraph, tagged with paragraph index,
  ## index within the paragraph, and end-of-paragraph flag (for
  ## last-line alignment under justify). A paragraph's first line
  ## budgets `maxW - indent`; continuations budget `maxW`.
  ## `twNormal` collapses space runs, `twPre*` preserve them; tabs
  ## expand to `tabWidth` stops first. Over-wide words
  ## emergency-break when `breakWord`, else take their own line.
  result = @[]
  let collapse = o.whiteSpace == twNormal
  let doWrap = o.wrap and o.whiteSpace != twPre
  let spaceAdv = shapeCached(font, px, " ", letterSpacing,
    features, cache, fallbacks).advance
  let tabW = if o.tabWidth > 0.0: o.tabWidth else: 8.0 * spaceAdv
  var pi = 0
  for para in splitTextLines(s):
    # Words separated by raw whitespace runs (spaces/tabs kept).
    var words: seq[string] = @[]
    var runs: seq[string] = @[] # runs[i] follows words[i]
    var cur = ""
    var run = ""
    var lead = ""
    for ch in para:
      if ch == ' ' or ch == '\t':
        if cur != "":
          words.add(cur)
          runs.add("")
          cur = ""
        if words.len > 0:
          runs[^1].add(ch)
        else:
          lead.add(ch)
      else:
        cur.add(ch)
    if cur != "":
      words.add(cur)
      runs.add("")
    var lines: seq[string] = @[]
    if doWrap and maxW > 0.0:
      var line = ""
      var first = true
      var leadDone = collapse
      var wi = 0
      while wi < words.len:
        let budget = maxW - (if first: indent else: 0.0)
        var joiner = ""
        if line != "":
          joiner = renderGap(font, px, line, runs[wi - 1], letterSpacing,
            collapse, spaceAdv, tabW, features, cache, fallbacks)
        elif not leadDone:
          joiner = renderGap(font, px, "", lead, letterSpacing,
            collapse, spaceAdv, tabW, features, cache, fallbacks)
        let trial = line & joiner & words[wi]
        if shapeCached(font, px, trial, letterSpacing,
            features, cache, fallbacks).advance <= budget or line == "":
          if line == "" and shapeCached(font, px, trial, letterSpacing,
              features, cache, fallbacks).advance > budget:
            # Over-wide word alone on the line.
            if o.breakWord:
              let parts = breakPieces(font, px, words[wi],
                letterSpacing, budget, o.hyphenChar, features, cache,
                fallbacks)
              for k in 0 ..< parts.len - 1:
                lines.add(if k == 0: joiner & parts[k]
                  else: parts[k])
              line = parts[^1]
            else:
              line = trial
          else:
            line = trial
          leadDone = true
          inc wi
        else:
          lines.add(line)
          line = ""
          first = false
      if words.len == 0:
        lines.add(renderGap(font, px, "", lead, letterSpacing,
          collapse, spaceAdv, tabW, features, cache, fallbacks))
      else:
        if not collapse and runs[^1].len > 0 and line != "":
          # Trailing whitespace belongs to the line in preserve modes.
          line.add(renderGap(font, px, line, runs[^1], letterSpacing,
            collapse, spaceAdv, tabW, features, cache, fallbacks))
        if line != "":
          lines.add(line)
      if lines.len == 0:
        lines.add("")
    else:
      if collapse:
        # No wrap, collapsed: single spaces, tabs included.
        var flat = ""
        for w in words:
          if flat != "":
            flat.add(' ')
          flat.add(w)
        lines.add(flat)
      else:
        # No wrap, preserved: expand tabs with a running advance.
        lines.add(expandPara(font, px, para, letterSpacing, spaceAdv,
          tabW, features, cache, fallbacks))
    for i, ln in lines:
      result.add((pi, i, i == lines.len - 1, ln))
    inc pi

proc clampCount(lines: var seq[WrapLine], maxLines: int) =
  ## Keep at most `maxLines` physical lines (`<= 0` keeps all); the
  ## new tail counts as a paragraph end for justification.
  if maxLines > 0 and lines.len > maxLines:
    lines.setLen(maxLines)
    lines[^1].last = true

proc widestStrings(font: TextFont, px: float64, lines: seq[WrapLine],
    letterSpacing: float64,
    features: openArray[Feature], cache: ShapeCache, fallbacks: openArray[TextFont]): float64 =
  ## Widest natural (unjustified) advance over already wrapped lines.
  for wl in lines:
    let a = shapeCached(font, px, wl.text, letterSpacing,
      features, cache, fallbacks).advance
    result = max(result, a)

# --- Rich text spans: shared text, per-range fonts/sizes/colors ---

type
  SpanPiece = tuple[span: int, text: string, word: int]
    ## A maximal same-span run (`span` -1 = layout style, `word`
    ## the word index in its line, -1 for gaps).
  SpanLine = object
    items*: seq[SpanPiece]
    para*: int
    idx*: int
    last*: bool

proc splitSpanPieces(spans: openArray[TextSpan], pos: int,
    text: string, word = -1): seq[SpanPiece] =
  ## Split `text` (starting at byte `pos`) at span boundaries.
  result = @[]
  var cur = -2
  var start = 0
  var i = 0
  while i < text.len:
    let si = spanAt(spans, pos + i)
    if si != cur:
      if cur != -2:
        result.add((cur, text[start ..< i], word))
      cur = si
      start = i
    # Advance one rune (pieces stay valid UTF-8).
    var w = 1
    while i + w < text.len and (ord(text[i + w]) and 0xC0) == 0x80:
      inc w
    i += w
  if cur != -2:
    result.add((cur, text[start ..< i], word))

proc spanFontSize(spans: openArray[TextSpan], si: int,
    font: TextFont, px: float64): tuple[font: TextFont, size: float64] =
  if si >= 0:
    let f = if spans[si].font != nil: spans[si].font else: font
    let sz = if spans[si].size > 0.0: spans[si].size else: px
    (f, sz)
  else:
    (font, px)

proc shapeSpanPiece(font: TextFont, px: float64,
    spans: openArray[TextSpan], si: int, text: string,
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache,
    fallbacks: openArray[TextFont]): ShapedLine =
  let (f, sz) = spanFontSize(spans, si, font, px)
  shapeCached(f, sz, text, letterSpacing, features, cache, fallbacks)

proc renderSpanGap(font: TextFont, px: float64,
    spans: openArray[TextSpan], lineAdv: float64, atStart: bool,
    run: string, runPos: int, letterSpacing: float64, collapse: bool,
    tabW: float64, features: openArray[Feature],
    cache: ShapeCache,
    fallbacks: openArray[TextFont]): seq[SpanPiece] =
  ## Render a raw whitespace run for span layout, split at span
  ## boundaries so metrics follow each piece's span. Collapsed: one
  ## space (leading runs vanish), or one tab stop from `lineAdv`.
  ## Preserved: spaces verbatim, tabs to stops with a running
  ## advance from `lineAdv`.
  if run.len == 0:
    return @[]
  if collapse:
    if atStart:
      return @[]
    if '\t' in run:
      let si = spanAt(spans, runPos)
      let (f, sz) = spanFontSize(spans, si, font, px)
      let sa = shapeCached(f, sz, " ", letterSpacing, features,
        cache, fallbacks).advance
      return @[(si, stopPad(sa, tabW, lineAdv), -1)]
    return @[(spanAt(spans, runPos), " ", -1)]
  result = @[]
  var cur = lineAdv
  for pc in splitSpanPieces(spans, runPos, run):
    let (f, sz) = spanFontSize(spans, pc.span, font, px)
    let sa = shapeCached(f, sz, " ", letterSpacing, features,
      cache, fallbacks).advance
    var outp = ""
    for ch in pc.text:
      if ch == ' ':
        outp.add(' ')
        cur += sa
      else:
        let pad = stopPad(sa, tabW, cur)
        outp.add(pad)
        cur += float64(pad.len) * sa
    if outp != "":
      result.add((pc.span, outp, -1))

proc pieceAdvance(font: TextFont, px: float64,
    spans: openArray[TextSpan], pc: SpanPiece, letterSpacing: float64,
    features: openArray[Feature], cache: ShapeCache,
    fallbacks: openArray[TextFont]): float64 =
  let (f, sz) = spanFontSize(spans, pc.span, font, px)
  shapeCached(f, sz, pc.text, letterSpacing, features, cache,
    fallbacks).advance

proc piecesAdvance(font: TextFont, px: float64,
    spans: openArray[TextSpan], pcs: openArray[SpanPiece],
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache,
    fallbacks: openArray[TextFont]): float64 =
  for pc in pcs:
    result += pieceAdvance(font, px, spans, pc, letterSpacing,
      features, cache, fallbacks)

proc assembleSpanLine(font: TextFont, px: float64,
    spans: openArray[TextSpan], items: openArray[SpanPiece],
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache, fallbacks: openArray[TextFont],
    justifyExtra = 0.0): ShapedLine =
  ## Concatenate shaped pieces with pen, line-local clusters, and
  ## span styles (size/color/decor; font stays nil unless a fallback
  ## shaped the glyph). `justifyExtra` adds fractional pen at each
  ## word boundary crossed.
  result = ShapedLine(glyphs: @[], advance: 0.0)
  var pen = 0.0
  var byteOff = 0
  var curWord = -2
  for pc in items:
    if pc.word >= 0 and pc.word != curWord:
      if curWord != -2:
        pen += justifyExtra
      curWord = pc.word
    let sh = shapeSpanPiece(font, px, spans, pc.span, pc.text,
      letterSpacing, features, cache, fallbacks)
    for g in sh.glyphs:
      var gg = g
      gg.x += pen
      if gg.hasInk:
        gg.x0 += pen
        gg.x1 += pen
      gg.cluster += uint32(byteOff)
      if pc.span >= 0:
        let (f, _) = spanFontSize(spans, pc.span, font, px)
        if f != font and gg.font == nil:
          gg.font = f
        if spans[pc.span].size > 0.0:
          gg.size = spans[pc.span].size
        gg.hasColor = spans[pc.span].hasColor
        gg.color = spans[pc.span].color
        gg.decor = spans[pc.span].decor
      result.glyphs.add(gg)
    pen += sh.advance
    byteOff += pc.text.len
  result.advance = pen

proc breakSpanPiece(font: TextFont, px: float64,
    spans: openArray[TextSpan], pcs: openArray[SpanPiece], room: float64,
    hyphen: string, letterSpacing: float64,
    features: openArray[Feature], cache: ShapeCache,
    fallbacks: openArray[TextFont]): tuple[kept, rest: seq[SpanPiece]]

proc wrapSpansAll(font: TextFont, px: float64, s: string,
    spans: openArray[TextSpan], letterSpacing: float64, maxW: float64,
    indent: float64, o: TextBoxOpts, features: openArray[Feature],
    cache: ShapeCache,
    fallbacks: openArray[TextFont]): seq[SpanLine] =
  ## Greedy word wrap over span-tagged text. Words keep their span
  ## pieces; gaps render per whitespace mode. Over-wide words
  ## emergency-break (`breakWord`) inside their pieces, else take
  ## their own line.
  result = @[]
  let collapse = o.whiteSpace == twNormal
  let doWrap = o.wrap and o.whiteSpace != twPre
  let spaceAdv = shapeCached(font, px, " ", letterSpacing, features,
    cache, fallbacks).advance
  let tabW = if o.tabWidth > 0.0: o.tabWidth else: 8.0 * spaceAdv
  var paraStart = 0
  var pi = 0
  for para in splitTextLines(s):
    # Words and raw gap runs with byte offsets.
    var words: seq[tuple[text: string, pos: int]] = @[]
    var gaps: seq[tuple[text: string, pos: int]] = @[]
    var cur = ""
    var lead = ""
    var leadPos = paraStart
    var pos = paraStart
    for ch in para:
      if ch == ' ' or ch == '\t':
        if cur != "":
          words.add((cur, pos - cur.len))
          gaps.add(("", pos))
          cur = ""
        if words.len > 0:
          gaps[^1].text.add(ch)
        else:
          lead.add(ch)
      else:
        cur.add(ch)
      inc pos
    if cur != "":
      words.add((cur, pos - cur.len))
      gaps.add(("", pos))
    var lines: seq[seq[SpanPiece]] = @[]
    if doWrap and maxW > 0.0:
      var line: seq[SpanPiece] = @[]
      var lineAdv = 0.0
      var first = true
      var leadDone = collapse
      var wi = 0
      var wordId = 0
      while wi < words.len:
        let budget = maxW - (if first: indent else: 0.0)
        var join: seq[SpanPiece] = @[]
        if line.len > 0:
          join = renderSpanGap(font, px, spans, lineAdv, false,
            gaps[wi - 1].text, gaps[wi - 1].pos, letterSpacing,
            collapse, tabW, features, cache, fallbacks)
        elif not leadDone:
          join = renderSpanGap(font, px, spans, 0.0, true, lead,
            leadPos, letterSpacing, collapse, tabW, features, cache,
            fallbacks)
        var wpcs: seq[SpanPiece] = @[]
        for pc in splitSpanPieces(spans, words[wi].pos,
            words[wi].text, wordId):
          wpcs.add(pc)
        let trialAdv = lineAdv + piecesAdvance(font, px, spans, join,
          letterSpacing, features, cache, fallbacks) +
          piecesAdvance(font, px, spans, wpcs, letterSpacing,
            features, cache, fallbacks)
        if trialAdv <= budget or line.len == 0:
          if line.len == 0 and trialAdv > budget:
            # Over-wide word alone on the line.
            if o.breakWord:
              var rest = wpcs
              var firstFrag = true
              while rest.len > 0:
                let room = budget - (if firstFrag: lineAdv +
                    piecesAdvance(font, px, spans, join,
                      letterSpacing, features, cache,
                      fallbacks) else: 0.0)
                let frag = breakSpanPiece(font, px, spans, rest,
                  room, o.hyphenChar, letterSpacing, features,
                  cache, fallbacks)
                if firstFrag:
                  line = line & join & frag.kept
                  lineAdv += piecesAdvance(font, px, spans, join,
                    letterSpacing, features, cache, fallbacks) +
                    piecesAdvance(font, px, spans, frag.kept,
                      letterSpacing, features, cache, fallbacks)
                  firstFrag = false
                else:
                  lines.add(line)
                  line = frag.kept
                  lineAdv = piecesAdvance(font, px, spans, frag.kept,
                    letterSpacing, features, cache, fallbacks)
                rest = frag.rest
                if frag.kept.len == 0 and rest.len > 0:
                  # No progress guard (should not happen).
                  line = line & rest
                  break
            else:
              line = line & join & wpcs
              lineAdv = trialAdv
          else:
            line = line & join & wpcs
            lineAdv = trialAdv
          leadDone = true
          inc wi
          inc wordId
        else:
          lines.add(line)
          line = @[]
          lineAdv = 0.0
          first = false
      if words.len == 0:
        let solo = renderSpanGap(font, px, spans, 0.0, true, lead,
          leadPos, letterSpacing, collapse, tabW, features, cache,
          fallbacks)
        lines.add(solo)
      else:
        if not collapse and gaps[^1].text.len > 0 and line.len > 0:
          let tail = renderSpanGap(font, px, spans, lineAdv, false,
            gaps[^1].text, gaps[^1].pos, letterSpacing, collapse,
            tabW, features, cache, fallbacks)
          line = line & tail
        if line.len > 0:
          lines.add(line)
      if lines.len == 0:
        lines.add(@[])
    else:
      # No wrap: one line; collapse joins words, preserve expands.
      var items: seq[SpanPiece] = @[]
      if collapse:
        var flatAdv = 0.0
        for i, w in words:
          if i > 0:
            let gp = renderSpanGap(font, px, spans, flatAdv, false,
              " ", w.pos - 1, letterSpacing, true, tabW, features,
              cache, fallbacks)
            items = items & gp
            flatAdv += piecesAdvance(font, px, spans, gp,
              letterSpacing, features, cache, fallbacks)
          for pc in splitSpanPieces(spans, w.pos, w.text, i):
            items.add(pc)
            flatAdv += pieceAdvance(font, px, spans, pc,
              letterSpacing, features, cache, fallbacks)
        lines.add(items)
      else:
        var adv = 0.0
        if lead.len > 0:
          let lp = renderSpanGap(font, px, spans, 0.0, true, lead,
            leadPos, letterSpacing, false, tabW, features, cache,
            fallbacks)
          items = items & lp
          adv += piecesAdvance(font, px, spans, lp, letterSpacing,
            features, cache, fallbacks)
        for i, w in words:
          for pc in splitSpanPieces(spans, w.pos, w.text, i):
            items.add(pc)
            adv += pieceAdvance(font, px, spans, pc, letterSpacing,
              features, cache, fallbacks)
          let gp = renderSpanGap(font, px, spans, adv, false,
            gaps[i].text, gaps[i].pos, letterSpacing, false, tabW,
            features, cache, fallbacks)
          items = items & gp
          adv += piecesAdvance(font, px, spans, gp, letterSpacing,
            features, cache, fallbacks)
        lines.add(items)
    for i, ln in lines:
      result.add(SpanLine(items: ln, para: pi, idx: i,
        last: i == lines.len - 1))
    inc pi
    paraStart += para.len + 1

proc breakSpanPiece(font: TextFont, px: float64,
    spans: openArray[TextSpan], pcs: openArray[SpanPiece], room: float64,
    hyphen: string, letterSpacing: float64,
    features: openArray[Feature], cache: ShapeCache,
    fallbacks: openArray[TextFont]): tuple[kept, rest: seq[SpanPiece]] =
  ## Take a prefix of the word pieces fitting `room`, hyphenating
  ## inside the last taken piece. Progress is guaranteed (a bare
  ## rune always fits somewhere).
  var kept: seq[SpanPiece] = @[]
  var rest: seq[SpanPiece] = @[]
  var used = 0.0
  var i = 0
  while i < pcs.len and used + pieceAdvance(font, px, spans, pcs[i],
      letterSpacing, features, cache, fallbacks) <= room:
    kept.add(pcs[i])
    used += pieceAdvance(font, px, spans, pcs[i], letterSpacing,
      features, cache, fallbacks)
    inc i
  for j in i ..< pcs.len:
    rest.add(pcs[j])
  if rest.len == 0:
    return (kept, rest)
  let (f, sz) = spanFontSize(spans, rest[0].span, font, px)
  let frags = breakPieces(f, sz, rest[0].text, letterSpacing, room,
    hyphen, features, cache, fallbacks)
  for k in 0 ..< frags.len - 1:
    kept.add((rest[0].span, frags[k], rest[0].word))
  var tail: seq[SpanPiece] = @[]
  if frags[^1] != "":
    tail.add((rest[0].span, frags[^1], rest[0].word))
  for j in 1 ..< rest.len:
    tail.add(rest[j])
  (kept, tail)

proc spanJustifyExtra(font: TextFont, px: float64,
    spans: openArray[TextSpan], items: openArray[SpanPiece],
    boxW: float64, letterSpacing: float64,
    features: openArray[Feature], cache: ShapeCache,
    fallbacks: openArray[TextFont]): float64 =
  ## Even share per word boundary spreading the line to `boxW` (`0`
  ## when there is nothing to spread between). Applied as fractional
  ## pen at assembly, so justification is exact.
  var ids: seq[int] = @[]
  for pc in items:
    if pc.word >= 0 and pc.word notin ids:
      ids.add(pc.word)
  if ids.len < 2:
    return 0.0
  let natural = piecesAdvance(font, px, spans, items, letterSpacing,
    features, cache, fallbacks)
  if natural >= boxW:
    return 0.0
  (boxW - natural) / float64(ids.len - 1)

proc spanEllipsizeLine(font: TextFont, px: float64,
    spans: openArray[TextSpan], items: openArray[SpanPiece],
    maxW: float64, marker: string, letterSpacing: float64,
    features: openArray[Feature], cache: ShapeCache,
    fallbacks: openArray[TextFont]): seq[SpanPiece] =
  ## Trim trailing items (then runes) and append `marker` in the last
  ## kept piece's span until the line fits `maxW`.
  var kept: seq[SpanPiece] = @items
  while true:
    let adv = piecesAdvance(font, px, spans, kept, letterSpacing,
      features, cache, fallbacks)
    if adv <= maxW or kept.len == 0:
      return kept
    while kept.len > 0 and kept[^1].word < 0:
      kept.setLen(kept.len - 1)
    if kept.len == 0:
      return kept
    let last = kept[^1]
    let rest = piecesAdvance(font, px, spans,
      kept[0 ..< kept.len - 1], letterSpacing, features, cache,
      fallbacks)
    let (f, sz) = spanFontSize(spans, last.span, font, px)
    var runes = last.text.toRunes()
    var done = false
    while runes.len > 0:
      runes.setLen(runes.len - 1)
      let t = $runes & marker
      if shapeCached(f, sz, t, letterSpacing, features, cache,
          fallbacks).advance <= maxW - rest:
        kept[^1] = (last.span, t, last.word)
        done = true
        break
    if done:
      return kept
    if shapeCached(f, sz, marker, letterSpacing, features, cache,
        fallbacks).advance <= maxW - rest:
      kept[^1] = (last.span, marker, last.word)
      return kept
    kept.setLen(kept.len - 1)

proc widestSpanLines(font: TextFont, px: float64,
    spans: openArray[TextSpan], lines: openArray[SpanLine],
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache,
    fallbacks: openArray[TextFont]): float64 =
  for ln in lines:
    result = max(result, piecesAdvance(font, px, spans, ln.items,
      letterSpacing, features, cache, fallbacks))

proc layoutBoxSpans*(font: TextFont, sizePx: float64, s: string,
    spans: openArray[TextSpan], letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightAbs = 0.0, o: TextBoxOpts,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): tuple[lay: TextLayout,
      shift: float64, sizePx: float64] =
  ## Box layout over span-tagged text: mirrors `layoutBoxOpts`
  ## (wrap, clamp, fit, justify, ellipsis, scale, align, gap,
  ## indent) with per-range fonts, sizes, colors and decorations.
  ## Ranges index `s` after `\r\n`/`\r` normalization. Pure layout.
  let src = s.replace("\r\n", "\n").replace("\r", "\n")
  let maxW = o.maxW
  let k = max(0.0, o.scaleX)
  let cache = newShapeCache()
  template widestAt(px: int32): float64 =
    var wlines = wrapSpansAll(font, float64(px), src, spans,
      letterSpacing, maxW, o.firstLineIndent, o, features, cache,
      fallbacks)
    if o.maxLines > 0 and wlines.len > o.maxLines:
      wlines.setLen(o.maxLines)
    widestSpanLines(font, float64(px), spans, wlines, letterSpacing,
      features, cache, fallbacks) * k
  let px0 = quantizePx(sizePx)
  var px = float64(px0)
  if o.fit != tfNone and maxW > 0.0:
    let w0 = widestAt(px0)
    if w0 != 0.0:
      case o.fit
      of tfNone:
        discard
      of tfShrink:
        if w0 > maxW:
          let floor = if o.minSize > 0.0: quantizePx(o.minSize)
            else: 1i32
          if floor >= px0:
            px = float64(px0) # bound above request: keep request
          elif widestAt(floor) > maxW:
            px = float64(floor) # floor: overflows, keeps the bound
          else:
            var lo = floor
            var hi = px0 - 1i32
            while lo < hi:
              let mid = (lo + hi + 1i32) div 2i32
              if widestAt(mid) <= maxW:
                lo = mid
              else:
                hi = mid - 1i32
            px = float64(lo)
      of tfStretch:
        if w0 <= maxW:
          let cap = max(px0, if o.maxSize > 0.0: quantizePx(o.maxSize)
            else: 8192i32)
          if not (widestAt(cap) <= maxW):
            var hi = px0 + 1i32
            while hi <= cap and widestAt(hi) <= maxW:
              hi *= 2i32
            var lo = min(px0, hi div 2i32)
            hi = min(hi, cap + 1i32)
            while lo < hi:
              let mid = (lo + hi + 1i32) div 2i32
              if mid > cap or widestAt(mid) > maxW:
                hi = mid - 1i32
              else:
                lo = mid
            px = float64(lo)
          else:
            px = float64(cap)
  let step = if lineHeightAbs > 0.0: lineHeightAbs
    else: px * max(0.0, lineHeightMul)
  var lay = TextLayout(font: font, lines: @[], sizePx: px,
    lineHeightPx: step)
  var lines = wrapSpansAll(font, px, src, spans, letterSpacing, maxW,
    o.firstLineIndent, o, features, cache, fallbacks)
  if o.maxLines > 0 and lines.len > o.maxLines:
    lines.setLen(o.maxLines)
    lines[^1].last = true
  for wl in lines:
    let indent = if wl.idx == 0: o.firstLineIndent else: 0.0
    let effW = maxW - indent
    var items = wl.items
    var extra = 0.0
    if o.overflow == toEllipsis:
      let adv = piecesAdvance(font, px, spans, items, letterSpacing,
        features, cache, fallbacks)
      if adv > effW and effW > 0.0:
        items = spanEllipsizeLine(font, px, spans, items, effW,
          o.ellipsis, letterSpacing, features, cache, fallbacks)
    elif o.ha == thaJustify and effW > 0.0 and
        (not wl.last or wl.idx == 0):
      extra = spanJustifyExtra(font, px, spans, items, effW,
        letterSpacing, features, cache, fallbacks)
    var shaped = assembleSpanLine(font, px, spans, items,
      letterSpacing, features, cache, fallbacks, extra)
    if indent != 0.0:
      for j in 0 ..< shaped.glyphs.len:
        shaped.glyphs[j].x += indent
        if shaped.glyphs[j].hasInk:
          shaped.glyphs[j].x0 += indent
          shaped.glyphs[j].x1 += indent
    lay.lines.add(shaped)
  lay = lay.withScaleX(o.scaleX)
  if maxW > 0.0 and (o.ha == thaCenter or o.ha == thaRight):
    for i in 0 ..< lay.lines.len:
      let xoff = if o.ha == thaCenter:
          (maxW - lay.lines[i].advance) * 0.5
        else:
          maxW - lay.lines[i].advance
      if xoff != 0.0:
        for j in 0 ..< lay.lines[i].glyphs.len:
          lay.lines[i].glyphs[j].x += xoff
          if lay.lines[i].glyphs[j].hasInk:
            lay.lines[i].glyphs[j].x0 += xoff
            lay.lines[i].glyphs[j].x1 += xoff
  if o.paragraphGap != 0.0 and lay.lines.len > 0:
    var acc = 0.0
    var prevPara = lines[0].para
    for i in 0 ..< lay.lines.len:
      if lines[i].para != prevPara:
        acc += o.paragraphGap
        prevPara = lines[i].para
      if acc != 0.0:
        for j in 0 ..< lay.lines[i].glyphs.len:
          lay.lines[i].glyphs[j].y += acc
          if lay.lines[i].glyphs[j].hasInk:
            lay.lines[i].glyphs[j].y0 += acc
            lay.lines[i].glyphs[j].y1 += acc
  var shift = 0.0
  if o.va != tvaBaseline:
    let ink = layoutInk(lay, thaLeft)
    if ink.found:
      case o.va
      of tvaBaseline:
        discard
      of tvaTop:
        shift = -ink.y0
      of tvaMiddle:
        shift = (o.boxH - (ink.y1 - ink.y0)) * 0.5 - ink.y0
      of tvaBottom:
        shift = o.boxH - ink.y1
  (lay, shift, px)

proc layoutBoxOpts*(font: TextFont, sizePx: float64, s: string,
    letterSpacing: float64, lineHeightMul: float64,
    lineHeightAbs: float64, o: TextBoxOpts,
    features: openArray[Feature],
    fallbacks: openArray[TextFont] = []): tuple[lay: TextLayout,
      shift: float64, sizePx: float64]

proc layoutBox*(font: TextFont, sizePx: float64, s: string,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightAbs = 0.0,
    maxW = 0.0, boxH = 0.0, ha = thaLeft, va = tvaTop, wrap = true,
    overflow = toVisible, fit = tfNone, scaleX = 1.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): tuple[lay: TextLayout,
      shift: float64, sizePx: float64] =
  ## Lay out `s` in a `maxW` x `boxH` box: wrap paragraphs, justify
  ## (CSS rule: every line but each paragraph's last, which follows
  ## `ha`, or left when `ha` itself is justify; a sole line
  ## justifies), fit the size, trim over-wide lines for ellipsis,
  ## then scale horizontally. Returns the final layout, the baseline
  ## shift placing the block for the box vertical align (`va`;
  ## `tvaBaseline` keeps the first baseline at the box top), and the
  ## fitted size. Lines come back box-positioned (x relative to the
  ## box left edge), so draw and measure the returned layout with
  ## `thaLeft`; `ha` only steers justification here. Pure layout: no
  ## drawing. Positional shorthand; the `TextBoxOpts` overload
  ## exposes clamping, custom markers, fit bounds, paragraph gap,
  ## indents and decorations.
  var o = TextBoxOpts(maxW: maxW, boxH: boxH, ha: ha, va: va,
    wrap: wrap, overflow: overflow, fit: fit, scaleX: scaleX)
  layoutBoxOpts(font, sizePx, s, letterSpacing, lineHeightMul,
    lineHeightAbs, o, features, fallbacks)

proc layoutBoxOpts*(font: TextFont, sizePx: float64, s: string,
    letterSpacing: float64, lineHeightMul: float64,
    lineHeightAbs: float64, o: TextBoxOpts,
    features: openArray[Feature],
    fallbacks: openArray[TextFont] = []): tuple[lay: TextLayout,
      shift: float64, sizePx: float64] =
  ## Full box layout: wrap paragraphs (first lines budget
  ## `maxW - firstLineIndent`), clamp to `maxLines`, fit the size
  ## within `minSize`/`maxSize`, justify (CSS last-line rule; a sole
  ## line justifies), trim over-wide lines with the `ellipsis`
  ## marker, scale horizontally, align lines in `[0, maxW]`, spread
  ## paragraphs by `paragraphGap`. Returns the final layout (draw and
  ## measure with `thaLeft`), the baseline shift for the box vertical
  ## align, and the fitted size. Pure layout: no drawing.
  let maxW = o.maxW
  let k = max(0.0, o.scaleX)
  let cache = newShapeCache()
  template widestAt(px: int32): float64 =
    var lines = wrapAll(font, float64(px), s, letterSpacing, maxW,
      o.firstLineIndent, o, features, cache, fallbacks)
    clampCount(lines, o.maxLines)
    widestStrings(font, float64(px), lines, letterSpacing,
      features, cache, fallbacks) * k
  let px0 = quantizePx(sizePx)
  var px = float64(px0)
  if o.fit != tfNone and maxW > 0.0:
    let w0 = widestAt(px0)
    if w0 != 0.0:
      case o.fit
      of tfNone:
        discard
      of tfShrink:
        if w0 > maxW:
          let floor = if o.minSize > 0.0: quantizePx(o.minSize)
            else: 1i32
          var lo = floor
          var hi = px0 - 1i32
          if w0 <= maxW or hi < lo:
            px = float64(px0)
          else:
            if widestAt(lo) > maxW:
              px = float64(lo) # floor: overflows, keeps the bound
            else:
              while lo < hi:
                let mid = (lo + hi + 1i32) div 2i32
                if widestAt(mid) <= maxW:
                  lo = mid
                else:
                  hi = mid - 1i32
              px = float64(lo)
      of tfStretch:
        if w0 <= maxW:
          let cap = max(px0, if o.maxSize > 0.0: quantizePx(o.maxSize)
            else: 8192i32)
          var hi = px0 + 1i32
          while hi <= cap and widestAt(hi) <= maxW:
            hi *= 2i32
          if hi > cap and widestAt(cap) <= maxW:
            px = float64(cap)
          else:
            var lo = min(px0, hi div 2i32)
            hi = min(hi, cap + 1i32)
            while lo < hi:
              let mid = (lo + hi + 1i32) div 2i32
              if mid > cap or widestAt(mid) > maxW:
                hi = mid - 1i32
              else:
                lo = mid
            px = float64(lo)
  let step = if lineHeightAbs > 0.0: lineHeightAbs
    else: px * max(0.0, lineHeightMul)
  var lay = TextLayout(font: font, lines: @[], sizePx: px,
    lineHeightPx: step)
  var lines = wrapAll(font, px, s, letterSpacing, maxW,
    o.firstLineIndent, o, features, cache, fallbacks)
  clampCount(lines, o.maxLines)
  for wl in lines:
    let indent = if wl.idx == 0: o.firstLineIndent else: 0.0
    let effW = maxW - indent
    var shaped = shapeCached(font, px, wl.text, letterSpacing, features,
      cache)
    if o.overflow == toEllipsis and shaped.advance > effW and
        effW > 0.0:
      shaped = ellipsizeLine(font, px, wl.text, letterSpacing, effW,
        features, o.ellipsis, cache, fallbacks)
    elif o.ha == thaJustify and effW > 0.0 and
        (not wl.last or wl.idx == 0):
      # Non-last lines spread; a paragraph's last line follows the
      # CSS rule (left here), except a sole line, which justifies.
      shaped = justifyLine(font, px, wl.text, letterSpacing, effW,
        features, cache, fallbacks)
    if indent != 0.0:
      for j in 0 ..< shaped.glyphs.len:
        shaped.glyphs[j].x += indent
        if shaped.glyphs[j].hasInk:
          shaped.glyphs[j].x0 += indent
          shaped.glyphs[j].x1 += indent
    lay.lines.add(shaped)
  lay = lay.withScaleX(o.scaleX)
  if maxW > 0.0 and (o.ha == thaCenter or o.ha == thaRight):
    # Box-relative alignment: x is always the box left edge, `ha`
    # positions lines within [0, maxW]. Over-wide lines spill evenly
    # (center) or left (right). Left/justify start at the edge.
    for i in 0 ..< lay.lines.len:
      let xoff = if o.ha == thaCenter:
          (maxW - lay.lines[i].advance) * 0.5
        else:
          maxW - lay.lines[i].advance
      if xoff != 0.0:
        for j in 0 ..< lay.lines[i].glyphs.len:
          lay.lines[i].glyphs[j].x += xoff
          if lay.lines[i].glyphs[j].hasInk:
            lay.lines[i].glyphs[j].x0 += xoff
            lay.lines[i].glyphs[j].x1 += xoff
  if o.paragraphGap != 0.0 and lay.lines.len > 0:
    # Non-uniform paragraph spacing rides on the glyphs so the
    # uniform line-step model (ink, valign, outlines) keeps working.
    var acc = 0.0
    var prevPara = lines[0].para
    for i in 0 ..< lay.lines.len:
      if lines[i].para != prevPara:
        acc += o.paragraphGap
        prevPara = lines[i].para
      if acc != 0.0:
        for j in 0 ..< lay.lines[i].glyphs.len:
          lay.lines[i].glyphs[j].y += acc
          if lay.lines[i].glyphs[j].hasInk:
            lay.lines[i].glyphs[j].y0 += acc
            lay.lines[i].glyphs[j].y1 += acc
  var shift = 0.0
  if o.va != tvaBaseline:
    let ink = layoutInk(lay, thaLeft)
    if ink.found:
      case o.va
      of tvaBaseline:
        discard
      of tvaTop:
        shift = -ink.y0
      of tvaMiddle:
        shift = (o.boxH - (ink.y1 - ink.y0)) * 0.5 - ink.y0
      of tvaBottom:
        shift = o.boxH - ink.y1
  (lay, shift, px)

proc paintDeco(c: Canvas, lay: TextLayout, x, y: float64,
    decor: TextDecor, strokeMode: bool) =
  ## Underline/strikethrough rules from ink extents, drawn at `(x, y)`
  ## like the glyphs (caller adds the box shift). Consecutive glyphs
  ## sharing an effective decor (per-glyph override, else `decor`)
  ## share one rule: underline sits below the group's deepest ink,
  ## strike crosses at ~x-height/2 of the group's largest size.
  ## Thickness scales with size.
  if lay.lines.len == 0:
    return
  var p = Path()
  for i, line in lay.lines:
    let base = y + float64(i) * lay.lineHeightPx
    var gi = 0
    while gi < line.glyphs.len:
      let eff = if line.glyphs[gi].decor != tdNone:
          line.glyphs[gi].decor else: decor
      if eff == tdNone:
        inc gi
        continue
      var x0 = Inf
      var x1 = -Inf
      var desc = 0.0
      var gsize = lay.sizePx
      while gi < line.glyphs.len:
        let e2 = if line.glyphs[gi].decor != tdNone:
            line.glyphs[gi].decor else: decor
        if e2 != eff:
          break
        let g = line.glyphs[gi]
        if g.hasInk:
          x0 = min(x0, g.x0)
          x1 = max(x1, g.x1)
          desc = max(desc, g.y1)
        if g.size > 0.0:
          gsize = max(gsize, g.size)
        inc gi
      if x1 <= x0:
        continue
      let t = max(1.0, gsize / 16.0)
      if eff == tdUnderline or eff == tdUnderStrike:
        let uy = base + desc + max(1.0, gsize * 0.06)
        p.rect(x + x0, uy, x1 - x0, t, c.states[^1].xform)
      if eff == tdStrike or eff == tdUnderStrike:
        let sy = base - gsize * 0.28 - t * 0.5
        p.rect(x + x0, sy, x1 - x0, t, c.states[^1].xform)
  let polys = p.flatten(c.tessTol, DefaultDistTol)
  if polys.len == 0:
    return
  let st = c.states[^1]
  let paint = if strokeMode: st.stroke else: st.fill
  c.backend.fill(c.surf, polys, paint, st.alpha, st.clip, c.shapeAA,
    st.compOp, frNonZero)

proc paintBox(c: Canvas, bl: tuple[lay: TextLayout, shift: float64,
    sizePx: float64], x, y, w, h: float64,
    overflow: TextOverflow, strokeMode: bool, decor = tdNone) =
  if overflow == toClip and w > 0.0 and h > 0.0:
    c.save()
    c.intersectScissor(x, y, w, h)
    c.paintLayout(bl.lay, x, y + bl.shift, thaLeft, tvaBaseline, strokeMode)
    c.paintDeco(bl.lay, x, y + bl.shift, decor, strokeMode)
    c.restore()
  else:
    c.paintLayout(bl.lay, x, y + bl.shift, thaLeft, tvaBaseline, strokeMode)
    c.paintDeco(bl.lay, x, y + bl.shift, decor, strokeMode)

proc fillTextBox*(c: Canvas, x, y, w, h: float64, s: string,
    ha = thaLeft, va = tvaTop, wrap = true, overflow = toVisible,
    fit = tfNone, scaleX = 1.0,
    features: openArray[Feature] = []): float64 =
  ## Fill text laid out in the `(x, y, w, h)` box with the state
  ## font/size/spacing/line-height. `(x, y)` is the box top-left;
  ## `ha` aligns lines within the box width (`thaJustify` spreads
  ## words to the box width); `va` aligns the block within the box
  ## height (`tvaBaseline` anchors the first baseline at `y` instead).
  ## `toClip` clips paint to the box. Returns the widest drawn
  ## advance. Draws nothing without a font.
  let st = c.states[^1]
  let bl = layoutBox(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, w, h, ha, va,
    wrap, overflow, fit, scaleX, features, c.fallbackFonts())
  c.paintBox(bl, x, y, w, h, overflow, false)
  widestAdvance(bl.lay)

proc fillTextBox*(c: Canvas, font: TextFont, size: float64, x, y, w,
    h: float64, s: string, ha = thaLeft, va = tvaTop, wrap = true,
    overflow = toVisible, fit = tfNone, scaleX = 1.0,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless overload of `fillTextBox` (no drawing without a font).
  let bl = layoutBox(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, w, h, ha, va, wrap, overflow, fit, scaleX, features,
    fallbacks)
  c.paintBox(bl, x, y, w, h, overflow, false)
  widestAdvance(bl.lay)

proc strokeTextBox*(c: Canvas, x, y, w, h: float64, s: string,
    ha = thaLeft, va = tvaTop, wrap = true, overflow = toVisible,
    fit = tfNone, scaleX = 1.0,
    features: openArray[Feature] = []): float64 =
  ## Stroke box text outlines with the current stroke style. Same
  ## layout and return conventions as `fillTextBox`.
  let st = c.states[^1]
  let bl = layoutBox(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, w, h, ha, va,
    wrap, overflow, fit, scaleX, features, c.fallbackFonts())
  c.paintBox(bl, x, y, w, h, overflow, true)
  widestAdvance(bl.lay)

proc strokeTextBox*(c: Canvas, font: TextFont, size: float64, x, y, w,
    h: float64, s: string, ha = thaLeft, va = tvaTop, wrap = true,
    overflow = toVisible, fit = tfNone, scaleX = 1.0,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless overload of `strokeTextBox`.
  let bl = layoutBox(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, w, h, ha, va, wrap, overflow, fit, scaleX, features,
    fallbacks)
  c.paintBox(bl, x, y, w, h, overflow, true)
  widestAdvance(bl.lay)

proc textBoxBounds*(c: Canvas, x, y, w, h: float64, s: string,
    ha = thaLeft, va = tvaTop, wrap = true, overflow = toVisible,
    fit = tfNone, scaleX = 1.0,
    features: openArray[Feature] = []): Rect =
  ## Measured ink bounds for box text at `(x, y)` (user space).
  let st = c.states[^1]
  let bl = layoutBox(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, w, h, ha, va,
    wrap, overflow, fit, scaleX, features, c.fallbackFonts())
  let b = layoutBounds(bl.lay, thaLeft)
  rect(x + b.x, y + bl.shift + b.y, b.w, b.h)

proc textBoxBounds*(c: Canvas, font: TextFont, size: float64, x, y, w,
    h: float64, s: string, ha = thaLeft, va = tvaTop, wrap = true,
    overflow = toVisible, fit = tfNone, scaleX = 1.0,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): Rect =
  ## Stateless overload of `textBoxBounds` (no drawing).
  let bl = layoutBox(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, w, h, ha, va, wrap, overflow, fit, scaleX, features,
    fallbacks)
  let b = layoutBounds(bl.lay, thaLeft)
  rect(x + b.x, y + bl.shift + b.y, b.w, b.h)

proc measureText*(c: Canvas, s: string,
    features: openArray[Feature] = []): TextMetrics =
  ## Widest advance, ink size, line count and size for stateful text
  ## (no box: explicit `\n` breaks only). See also `layoutText`,
  ## which exposes per-line breaks and glyph positions.
  let st = c.states[^1]
  let lay = layoutText(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, features, st.lineHeightAbs,
    c.fallbackFonts())
  measureLayout(lay, st.textHAlign)

proc measureText*(c: Canvas, font: TextFont, size: float64, s: string,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): TextMetrics =
  ## Stateless overload of `measureText`.
  let lay = layoutText(font, size, s, letterSpacing, lineHeightMul,
    features, lineHeightPx, fallbacks)
  measureLayout(lay, thaLeft)

proc measureTextBox*(c: Canvas, x, y, w, h: float64, s: string,
    ha = thaLeft, va = tvaTop, wrap = true, overflow = toVisible,
    fit = tfNone, scaleX = 1.0,
    features: openArray[Feature] = []): TextMetrics =
  ## Box-layout metrics: post-fit size, drawn advance, ink size and
  ## physical line count.
  let st = c.states[^1]
  let bl = layoutBox(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, w, h, ha, va,
    wrap, overflow, fit, scaleX, features, c.fallbackFonts())
  measureLayout(bl.lay, thaLeft)

proc measureTextBox*(c: Canvas, font: TextFont, size: float64, x, y, w,
    h: float64, s: string, ha = thaLeft, va = tvaTop, wrap = true,
    overflow = toVisible, fit = tfNone, scaleX = 1.0,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): TextMetrics =
  ## Stateless overload of `measureTextBox`.
  let bl = layoutBox(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, w, h, ha, va, wrap, overflow, fit, scaleX, features,
    fallbacks)
  measureLayout(bl.lay, thaLeft)

# --- Text boxes via `TextBoxOpts`: clamp, markers, fit bounds,
# --- paragraph gap/indents, decorations ---

proc fillTextBox*(c: Canvas, x, y: float64, s: string, o: TextBoxOpts,
    features: openArray[Feature] = []): float64 =
  ## `TextBoxOpts` overload of `fillTextBox`: full layout control
  ## with the state font/size/spacing/line-height. `(x, y)` is the
  ## box top-left (`o.maxW`/`o.boxH` size it).
  let st = c.states[^1]
  let bl = layoutBoxOpts(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o, features,
    c.fallbackFonts())
  c.paintBox(bl, x, y, o.maxW, o.boxH, o.overflow, false, o.decor)
  widestAdvance(bl.lay)

proc fillTextBox*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, o: TextBoxOpts, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless `TextBoxOpts` overload of `fillTextBox`.
  let bl = layoutBoxOpts(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, o, features, fallbacks)
  c.paintBox(bl, x, y, o.maxW, o.boxH, o.overflow, false, o.decor)
  widestAdvance(bl.lay)

proc strokeTextBox*(c: Canvas, x, y: float64, s: string,
    o: TextBoxOpts,
    features: openArray[Feature] = []): float64 =
  ## `TextBoxOpts` overload of `strokeTextBox`.
  let st = c.states[^1]
  let bl = layoutBoxOpts(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o, features,
    c.fallbackFonts())
  c.paintBox(bl, x, y, o.maxW, o.boxH, o.overflow, true, o.decor)
  widestAdvance(bl.lay)

proc strokeTextBox*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, o: TextBoxOpts, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless `TextBoxOpts` overload of `strokeTextBox`.
  let bl = layoutBoxOpts(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, o, features, fallbacks)
  c.paintBox(bl, x, y, o.maxW, o.boxH, o.overflow, true, o.decor)
  widestAdvance(bl.lay)

proc textBoxBounds*(c: Canvas, x, y: float64, s: string,
    o: TextBoxOpts,
    features: openArray[Feature] = []): Rect =
  ## `TextBoxOpts` overload of `textBoxBounds` (text ink only;
  ## decoration rules are ignored).
  let st = c.states[^1]
  let bl = layoutBoxOpts(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o, features,
    c.fallbackFonts())
  let b = layoutBounds(bl.lay, thaLeft)
  rect(x + b.x, y + bl.shift + b.y, b.w, b.h)

proc textBoxBounds*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, o: TextBoxOpts, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): Rect =
  ## Stateless `TextBoxOpts` overload of `textBoxBounds`.
  let bl = layoutBoxOpts(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, o, features, fallbacks)
  let b = layoutBounds(bl.lay, thaLeft)
  rect(x + b.x, y + bl.shift + b.y, b.w, b.h)

proc measureTextBox*(c: Canvas, x, y: float64, s: string,
    o: TextBoxOpts,
    features: openArray[Feature] = []): TextMetrics =
  ## `TextBoxOpts` overload of `measureTextBox`.
  let st = c.states[^1]
  let bl = layoutBoxOpts(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o, features,
    c.fallbackFonts())
  measureLayout(bl.lay, thaLeft)

proc measureTextBox*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, o: TextBoxOpts, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): TextMetrics =
  ## Stateless `TextBoxOpts` overload of `measureTextBox`.
  let bl = layoutBoxOpts(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, o, features, fallbacks)
  measureLayout(bl.lay, thaLeft)

proc textHitBox*(c: Canvas, px, py: float64, s: string, o: TextBoxOpts,
    features: openArray[Feature] = []): TextHit =
  ## Map a user-space point to a laid-out glyph: line index, glyph
  ## index, before/after side, and the glyph's byte offset in its
  ## line string. Layout runs with the state font/style; coordinates
  ## are box-relative (the box top-left is the origin).
  let st = c.states[^1]
  let bl = layoutBoxOpts(c.lookupFont(st.fontFace), st.fontSize, s,
    st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o, features,
    c.fallbackFonts())
  hitTest(bl.lay, px, py - bl.shift, thaLeft)

proc textHitBox*(c: Canvas, font: TextFont, size: float64, px, py: float64,
    s: string, o: TextBoxOpts, letterSpacing = 0.0,
    lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): TextHit =
  ## Stateless overload of `textHitBox`.
  let bl = layoutBoxOpts(font, size, s, letterSpacing, lineHeightMul,
    lineHeightPx, o, features, fallbacks)
  hitTest(bl.lay, px, py - bl.shift, thaLeft)

# --- Rich text spans: shared text, per-range style ---

proc fillSpans*(c: Canvas, x, y: float64, s: string,
    spans: openArray[TextSpan], ha = thaLeft, va = tvaBaseline,
    features: openArray[Feature] = []): float64 =
  ## Fill span-styled text with the state font/size/spacing as the
  ## base style (unspanned bytes) and the state fill paint for
  ## uncolored glyphs. Same positioning as `fillText`. Returns the
  ## widest line advance.
  let st = c.states[^1]
  let lay = layoutSpans(c.lookupFont(st.fontFace), st.fontSize, s,
    spans, st.letterSpacing, st.lineHeightMul, features,
    st.lineHeightAbs, c.fallbackFonts())
  c.paintLayout(lay, x, y, ha, va, false)
  widestAdvance(lay)

proc fillSpans*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, spans: openArray[TextSpan], ha = thaLeft,
    va = tvaBaseline, letterSpacing = 0.0, lineHeightMul = 1.2,
    lineHeightPx = 0.0, features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless overload of `fillSpans`.
  let lay = layoutSpans(font, size, s, spans, letterSpacing,
    lineHeightMul, features, lineHeightPx, fallbacks)
  c.paintLayout(lay, x, y, ha, va, false)
  widestAdvance(lay)

proc fillSpanBox*(c: Canvas, x, y: float64, s: string,
    spans: openArray[TextSpan], o: TextBoxOpts,
    features: openArray[Feature] = []): float64 =
  ## `TextBoxOpts` box layout over span-tagged text with the state
  ## base style. `(x, y)` is the box top-left. Returns the widest
  ## drawn advance.
  let st = c.states[^1]
  let bl = layoutBoxSpans(c.lookupFont(st.fontFace), st.fontSize, s,
    spans, st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o,
    features, c.fallbackFonts())
  c.paintBox(bl, x, y, o.maxW, o.boxH, o.overflow, false, o.decor)
  widestAdvance(bl.lay)

proc fillSpanBox*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, spans: openArray[TextSpan], o: TextBoxOpts,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): float64 =
  ## Stateless overload of `fillSpanBox`.
  let bl = layoutBoxSpans(font, size, s, spans, letterSpacing,
    lineHeightMul, lineHeightPx, o, features, fallbacks)
  c.paintBox(bl, x, y, o.maxW, o.boxH, o.overflow, false, o.decor)
  widestAdvance(bl.lay)

proc textSpanBounds*(c: Canvas, x, y: float64, s: string,
    spans: openArray[TextSpan], o: TextBoxOpts,
    features: openArray[Feature] = []): Rect =
  ## Measured ink bounds for span box text (user space).
  let st = c.states[^1]
  let bl = layoutBoxSpans(c.lookupFont(st.fontFace), st.fontSize, s,
    spans, st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o,
    features, c.fallbackFonts())
  let b = layoutBounds(bl.lay, thaLeft)
  rect(x + b.x, y + bl.shift + b.y, b.w, b.h)

proc textSpanBounds*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, spans: openArray[TextSpan], o: TextBoxOpts,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): Rect =
  ## Stateless overload of `textSpanBounds`.
  let bl = layoutBoxSpans(font, size, s, spans, letterSpacing,
    lineHeightMul, lineHeightPx, o, features, fallbacks)
  let b = layoutBounds(bl.lay, thaLeft)
  rect(x + b.x, y + bl.shift + b.y, b.w, b.h)

proc measureSpanBox*(c: Canvas, x, y: float64, s: string,
    spans: openArray[TextSpan], o: TextBoxOpts,
    features: openArray[Feature] = []): TextMetrics =
  ## Span box-layout metrics.
  let st = c.states[^1]
  let bl = layoutBoxSpans(c.lookupFont(st.fontFace), st.fontSize, s,
    spans, st.letterSpacing, st.lineHeightMul, st.lineHeightAbs, o,
    features, c.fallbackFonts())
  measureLayout(bl.lay, thaLeft)

proc measureSpanBox*(c: Canvas, font: TextFont, size: float64, x, y: float64,
    s: string, spans: openArray[TextSpan], o: TextBoxOpts,
    letterSpacing = 0.0, lineHeightMul = 1.2, lineHeightPx = 0.0,
    features: openArray[Feature] = [],
    fallbacks: openArray[TextFont] = []): TextMetrics =
  ## Stateless overload of `measureSpanBox`.
  let bl = layoutBoxSpans(font, size, s, spans, letterSpacing,
    lineHeightMul, lineHeightPx, o, features, fallbacks)
  measureLayout(bl.lay, thaLeft)

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
