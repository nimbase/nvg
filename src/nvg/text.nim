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
##   shaping never sees the newline). `wrapParagraph` adds greedy word
##   wrap to a width; `fillTextBox` (canvas) combines wrap, justify,
##   fit, overflow and box-relative vertical alignment.
## - Horizontal layout only: vertical scripts fall back to horizontal
##   advances. COLR/CPAL color emoji is out of scope (harfnim has no color
##   tables); such glyphs draw nothing but still advance.
## - Vertical alignment is relative to measured ink (union of placed
##   glyph extents), not font ascent/descent (harfnim exposes no hhea
##   metrics accessor yet).
## - `thaJustify` spreads words with spaces to a box width (a
##   word-space feature: CJK runs without spaces do not spread, and
##   mixed-direction lines lay words out in logical order). Outside a
##   box it anchors like left.
## - Line height is either a font-size multiplier or an absolute px
##   value (`lineHeightAbs`); the two are kept distinct, absolute wins.

import std/options
import std/strutils
import std/unicode
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
    thaJustify
      ## Spread space-separated words to a box width (box APIs only;
      ## anchors like left everywhere else).

  TextVAlign* = enum
    tvaBaseline
    tvaTop
    tvaMiddle
    tvaBottom

  TextFit* = enum
    tfNone
      ## Keep the requested size even if lines exceed the box.
    tfShrink
      ## Shrink the font (whole pixels) until the wrapped natural
      ## layout fits the box width. Never grows.
    tfStretch
      ## Grow the font (whole pixels) until the wrapped natural layout
      ## fills the box width. Never shrinks below the requested size.

  TextOverflow* = enum
    toVisible
      ## Draw everything, even past the box edges.
    toClip
      ## Clip drawing to the box rect (box APIs only).
    toEllipsis
      ## Trim over-wide lines and append the ellipsis marker to fit.

  TextDecor* = enum
    tdNone
    tdUnderline
    tdStrike
    tdUnderStrike

  TextBoxOpts* = object
    ## Full box-layout option set. Positional `fillTextBox` and kin
    ## cover the common cases; the `opts` overloads expose all of
    ## this. `maxW`/`boxH` travel here too so one value threads
    ## layout, alignment and clipping.
    maxW*: float64 = 0.0
    boxH*: float64 = 0.0
    ha*: TextHAlign = thaLeft
    va*: TextVAlign = tvaTop
    wrap*: bool = true
    overflow*: TextOverflow = toVisible
    fit*: TextFit = tfNone
    scaleX*: float64 = 1.0
    maxLines*: int = 0
      ## Line clamp: keep at most this many physical lines
      ## (`0` = unlimited). With `toEllipsis` the last kept line is
      ## trimmed with the marker; otherwise lines are cut silently.
    ellipsis*: string = "…"
      ## Marker appended by ellipsis trimming.
    minSize*: float64 = 0.0
      ## `tfShrink` floor in px (`0` = none: may shrink to 1px).
    maxSize*: float64 = 0.0
      ## `tfStretch` ceiling in px (`0` = none).
    paragraphGap*: float64 = 0.0
      ## Extra px between `\n` paragraphs (on top of line height).
    firstLineIndent*: float64 = 0.0
      ## Indent of each paragraph's first line in px; wrapped and
      ## justified widths shrink accordingly.
    decor*: TextDecor = tdNone
      ## Underline/strikethrough rules from per-line ink metrics
      ## (painted with the text paint; bounds ignore them).

  TextMetrics* = object
    advance*: float64
      ## Widest line advance (post scaleX).
    width*, height*: float64
      ## Measured ink bounds size.
    lineCount*: int
    sizePx*: float64
      ## Font size laid out (post fit).

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
    features: openArray[Feature] = [],
    lineHeightAbs = 0.0): TextLayout =
  ## Shape every `\n`-separated line. A nil font yields empty lines
  ## (callers draw nothing and measure zero). `lineHeightAbs > 0`
  ## overrides the multiplier with an absolute baseline step in px.
  let px = max(1.0, sizePx)
  let step = if lineHeightAbs > 0.0: lineHeightAbs
    else: px * max(0.0, lineHeightMul)
  result = TextLayout(font: font, lines: @[], sizePx: px,
    lineHeightPx: step)
  for line in splitTextLines(s):
    result.lines.add(shapeLine(font, px, line, letterSpacing, features))

proc linePenX*(advance: float64, ha: TextHAlign): float64 =
  ## Per-line pen start relative to the anchor x.
  case ha
  of thaLeft, thaJustify: 0.0
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

proc measureLayout*(lay: TextLayout, ha: TextHAlign): TextMetrics =
  ## Widest advance, ink size and line count for an already shaped
  ## layout. Anchor-free: alignment never changes these fields.
  var adv = 0.0
  for line in lay.lines:
    adv = max(adv, line.advance)
  let b = layoutBounds(lay, ha)
  TextMetrics(advance: adv, width: b.w, height: b.h,
    lineCount: lay.lines.len, sizePx: lay.sizePx)

proc withScaleX*(lay: TextLayout, sx: float64): TextLayout =
  ## Copy with every horizontal pen/ink coordinate scaled by `sx`
  ## (geometric condensed/extended rendering; `sx <= 0` draws nothing).
  ## Vertical metrics are untouched.
  let k = max(0.0, sx)
  result = TextLayout(font: lay.font, lines: @[], sizePx: lay.sizePx,
    lineHeightPx: lay.lineHeightPx)
  for line in lay.lines:
    var nl = ShapedLine(glyphs: @[], advance: line.advance * k)
    for g in line.glyphs:
      var gg = g
      gg.x *= k
      if gg.hasInk:
        gg.x0 *= k
        gg.x1 *= k
      nl.glyphs.add(gg)
    result.lines.add(nl)

proc wrapParagraph*(font: TextFont, sizePx: float64, para: string,
    letterSpacing: float64, maxW: float64,
    features: openArray[Feature]): seq[string] =
  ## Greedy word wrap of one `\n`-free paragraph to `maxW`, measured
  ## with the real shaper. Runs of spaces collapse; an over-wide
  ## single word gets its own line.
  result = @[]
  var line = ""
  for w in para.split(' '):
    if w.len == 0:
      continue
    let trial = if line == "": w else: line & " " & w
    if shapeLine(font, sizePx, trial, letterSpacing,
        features).advance <= maxW or line == "":
      line = trial
    else:
      result.add(line)
      line = w
  if line != "":
    result.add(line)
  if result.len == 0:
    result.add("")

proc justifyLine*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64, boxW: float64,
    features: openArray[Feature]): ShapedLine =
  ## Spread the words of `line` so the advance equals `boxW`, keeping
  ## intra-word shaping (kerning, letter spacing) intact. Single words
  ## and already-over-wide lines come back plainly shaped.
  var words: seq[string] = @[]
  for w in line.split(' '):
    if w.len > 0:
      words.add(w)
  if words.len < 2:
    return shapeLine(font, sizePx, line, letterSpacing, features)
  let spaceAdv = shapeLine(font, sizePx, " ", letterSpacing,
    features).advance
  var shaped: seq[ShapedLine] = @[]
  var natural = 0.0
  for w in words:
    let s = shapeLine(font, sizePx, w, letterSpacing, features)
    shaped.add(s)
    natural += s.advance
  natural += spaceAdv * float64(words.len - 1)
  if natural >= boxW:
    return shapeLine(font, sizePx, line, letterSpacing, features)
  let gap = spaceAdv + (boxW - natural) / float64(words.len - 1)
  result = ShapedLine(glyphs: @[], advance: boxW)
  var pen = 0.0
  for s in shaped:
    for g in s.glyphs:
      var gg = g
      gg.x += pen
      if gg.hasInk:
        gg.x0 += pen
        gg.x1 += pen
      result.glyphs.add(gg)
    pen += s.advance + gap

proc ellipsizeLine*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64, maxW: float64,
    features: openArray[Feature], marker = "…"): ShapedLine =
  ## Trim trailing runes and append `marker` until the line fits
  ## `maxW`. Fits already: plain shaping. Nothing fits (even the
  ## marker alone): an empty line.
  if maxW <= 0.0:
    return ShapedLine(glyphs: @[], advance: 0.0)
  var shaped = shapeLine(font, sizePx, line, letterSpacing, features)
  if shaped.advance <= maxW:
    return shaped
  var runes = line.toRunes()
  while runes.len > 0:
    runes.setLen(runes.len - 1)
    shaped = shapeLine(font, sizePx, $runes & marker, letterSpacing,
      features)
    if shaped.advance <= maxW:
      return shaped
  shaped = shapeLine(font, sizePx, marker, letterSpacing, features)
  if shaped.advance <= maxW:
    return shaped
  ShapedLine(glyphs: @[], advance: 0.0)

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
