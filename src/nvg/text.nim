## Text shaping and glyph-outline layout on top of harfnim.
##
## harfnim shapes (GSUB/GPOS, Arabic joining, mark positioning, legacy
## kern) and decodes outlines (glyf + CFF) as integer font-unit ops in a
## y-up coordinate system. This module lays those out in nvg user space
## (y-down, baseline origin) and feeds them to a `Path` with an explicit
## transform, so text renders through the normal fill/stroke backends
## (including the JIT fast path) with no rasterizer changes.
##
## Units and conventions (v1):
## - `setFontSize` takes pixels; sizes quantize to whole pixels because
##   harfnim positions are integers. Advances/offsets resolve to 1/64 px
##   internally (overscaled shaping), outlines scale smoothly.
## - Glyph ink uses the nonzero fill rule (TrueType holes rely on contour
##   direction, which even-odd also handles, but nonzero is spec-correct).
## - Multiline means explicit `\n` breaks (split before shaping, so
##   shaping never sees the newline). No automatic word wrap yet.
## - Horizontal layout only: vertical scripts fall back to horizontal
##   advances. COLR/CPAL color emoji is out of scope (harfnim has no color
##   tables); such glyphs draw nothing but still advance.
## - Vertical alignment is relative to measured ink (union of placed
##   glyph extents), not font ascent/descent (harfnim exposes no hhea
##   metrics accessor yet).

import std/options
import ./types
import ./path
import harfnim

const textPosScale* = 64
  ## Shaping overscale: advances/offsets are shaped at
  ## `sizePx * textPosScale` and divided back, giving 1/64 px precision
  ## while outlines scale by the exact `sizePx / upem` ratio.

type
  TextFont* = ref object
    ## Parsed font plus harfnim shaper state. The outline cache lives
    ## behind a ref inside `ShaperFont`, so copies share decoded outlines.
    shaper*: ShaperFont
    upem*: float64
    name*: string

  TextHAlign* = enum
    thaLeft
    thaCenter
    thaRight

  TextVAlign* = enum
    tvaBaseline
    tvaTop
    tvaMiddle
    tvaBottom

  PlacedGlyph* = object
    gid*: uint32
    x*, y*: float64
      ## Line-local origin in px (y-down, line baseline at y = 0):
      ## pen plus the shaped offset.
    x0*, y0*, x1*, y1*: float64
      ## Line-local ink box in px (valid only when `hasInk`).
    hasInk*: bool

  ShapedLine* = object
    glyphs*: seq[PlacedGlyph]
    advance*: float64
      ## Total pen advance including inter-glyph letter spacing.

  TextLayout* = object
    font*: TextFont
    lines*: seq[ShapedLine]
    sizePx*: float64
    lineHeightPx*: float64

proc loadFontBytes*(data: openArray[uint8], faceIndex = 0): TextFont =
  ## Parse font bytes (TTF/OTF/TTC). Raises `FontError` on bad data.
  let sf = parseFont(data, faceIndex)
  let base = newShaperFont(sf)
  TextFont(shaper: base, upem: float64(base.unitsPerEm), name: "")

proc loadFontFile*(path: string, faceIndex = 0): TextFont =
  ## Read a font file and parse it. Raises `IOError`/`FontError`.
  loadFontBytes(cast[seq[uint8]](readFile(path)), faceIndex)

proc splitTextLines*(s: string): seq[string] =
  ## Split on `\n` (tolerating `\r\n`), keeping empty lines so `"a\n"`
  ## is two lines and `""` is one empty line.
  result = @[]
  var cur = ""
  for ch in s:
    if ch == '\n':
      result.add(cur)
      cur = ""
    elif ch != '\r':
      cur.add(ch)
  result.add(cur)

proc quantizePx*(sizePx: float64): int32 =
  max(1i32, int32(sizePx + 0.5))

proc shapeLine*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64,
    features: openArray[Feature]): ShapedLine =
  ## Shape one line (no newlines) and walk the pen in px. Marks ride on
  ## the pen via their offsets; letter spacing applies between glyphs
  ## with nonzero advance only, so marks stay glued to their base.
  result = ShapedLine(glyphs: @[], advance: 0.0)
  if font == nil or line.len == 0:
    return
  let px = quantizePx(sizePx)
  var sf = font.shaper
  sf.setScale(px * textPosScale)
  var buf = newBuffer()
  buf.pushStr(line)
  sf.shape(buf, features)
  let n = min(buf.len, min(buf.info.len, buf.pos.len))
  const toPx = 1.0 / float64(textPosScale)
  var pen = 0.0
  for i in 0 ..< n:
    let pos = buf.pos[i]
    let adv = float64(pos.xAdvance) * toPx
    let gx = pen + float64(pos.xOffset) * toPx
    let gy = -float64(pos.yOffset) * toPx
    var g = PlacedGlyph(gid: buf.info[i].glyphId, x: gx, y: gy,
      hasInk: false)
    let ext = sf.glyphExtents(newGlyphId(g.gid))
    if ext.isSome:
      let e = ext.get
      let s = 1.0 / float64(textPosScale)
      g.x0 = gx + float64(e.xBearing) * s
      g.x1 = gx + float64(e.xBearing + e.width) * s
      # Extents are y-up with yBearing the top: flip around the origin.
      g.y0 = gy - float64(e.yBearing) * s
      g.y1 = gy - float64(e.yBearing + e.height) * s
      if g.x1 > g.x0 and g.y1 > g.y0:
        g.hasInk = true
    result.glyphs.add(g)
    pen += adv
    if adv != 0.0 and i + 1 < n:
      pen += letterSpacing
  result.advance = pen

proc layoutText*(font: TextFont, sizePx: float64, s: string,
    letterSpacing = 0.0, lineHeightMul = 1.2,
    features: openArray[Feature] = []): TextLayout =
  ## Shape every `\n`-separated line. A nil font yields empty lines
  ## (callers draw nothing and measure zero).
  let px = max(1.0, sizePx)
  result = TextLayout(font: font, lines: @[], sizePx: px,
    lineHeightPx: px * max(0.0, lineHeightMul))
  for line in splitTextLines(s):
    result.lines.add(shapeLine(font, px, line, letterSpacing, features))

proc linePenX*(advance: float64, ha: TextHAlign): float64 =
  ## Per-line pen start relative to the anchor x.
  case ha
  of thaLeft: 0.0
  of thaCenter: -advance * 0.5
  of thaRight: -advance

proc layoutInk*(lay: TextLayout, ha: TextHAlign):
    tuple[found: bool, x0, y0, x1, y1: float64] =
  ## Union of placed ink boxes, x relative to the anchor, y relative to
  ## the first baseline. Empty text reports `found = false`.
  var found = false
  var x0, y0, x1, y1 = 0.0
  for i, line in lay.lines:
    let ox = linePenX(line.advance, ha)
    let oy = float64(i) * lay.lineHeightPx
    for g in line.glyphs:
      if not g.hasInk:
        continue
      let gx0 = ox + g.x0
      let gy0 = oy + g.y0
      let gx1 = ox + g.x1
      let gy1 = oy + g.y1
      if not found:
        x0 = gx0
        y0 = gy0
        x1 = gx1
        y1 = gy1
        found = true
      else:
        x0 = min(x0, gx0)
        y0 = min(y0, gy0)
        x1 = max(x1, gx1)
        y1 = max(y1, gy1)
  (found, x0, y0, x1, y1)

proc layoutBounds*(lay: TextLayout, ha: TextHAlign): Rect =
  ## Anchor-relative ink bounds (x relative to anchor, y relative to
  ## the first baseline). No ink gives a zero rect at the anchor.
  let ink = layoutInk(lay, ha)
  if not ink.found:
    return rect(0, 0, 0, 0)
  rect(ink.x0, ink.y0, ink.x1 - ink.x0, ink.y1 - ink.y0)

proc valignShift*(lay: TextLayout, ha: TextHAlign,
    va: TextVAlign): float64 =
  ## Baseline delta so the block satisfies `va` (0 for baseline).
  if va == tvaBaseline:
    return 0.0
  let ink = layoutInk(lay, ha)
  if not ink.found:
    return 0.0
  case va
  of tvaBaseline: 0.0
  of tvaTop: -ink.y0
  of tvaMiddle: -(ink.y0 + ink.y1) * 0.5
  of tvaBottom: -ink.y1

proc appendLayout*(p: var Path, xf: Xform, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign) =
  ## Emit the laid-out glyph outlines as path verbs (transform captured
  ## per verb, like all `Path` input). Glyphs without outlines advance
  ## the pen but emit nothing.
  if lay.font == nil:
    return
  let s = lay.sizePx / lay.font.upem
  let dy = valignShift(lay, ha, va)
  for i, line in lay.lines:
    let ox = x + linePenX(line.advance, ha)
    let oy = y + dy + float64(i) * lay.lineHeightPx
    for g in line.glyphs:
      var ops: seq[DrawOp] = @[]
      var sf = lay.font.shaper
      if not sf.drawGlyph(newGlyphId(g.gid),
          proc(op: DrawOp) = ops.add(op)):
        continue
      let gx = ox + g.x
      let gy = oy + g.y
      for op in ops:
        case op.kind
        of moveTo:
          p.moveTo(gx + float64(op.to.x) * s, gy - float64(op.to.y) * s,
            xf)
        of lineTo:
          p.lineTo(gx + float64(op.to.x) * s, gy - float64(op.to.y) * s,
            xf)
        of quadraticTo:
          p.quadTo(gx + float64(op.qCtrl.x) * s,
            gy - float64(op.qCtrl.y) * s, gx + float64(op.qTo.x) * s,
            gy - float64(op.qTo.y) * s, xf)
        of cubicTo:
          p.bezierTo(gx + float64(op.c1.x) * s,
            gy - float64(op.c1.y) * s, gx + float64(op.c2.x) * s,
            gy - float64(op.c2.y) * s, gx + float64(op.cTo.x) * s,
            gy - float64(op.cTo.y) * s, xf)
        of closePath:
          p.closePath()
