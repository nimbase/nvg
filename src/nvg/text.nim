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
## - `thaJustify` spreads space-separated words to a box width;
##   spaceless runs (CJK included) spread between their runes, and
##   combining marks stay glued to their base. Plain lines lay out in
##   visual order via harfnim's `visualRuns` (bdAuto): each run shapes
##   with its explicit direction and clusters map back to logical
##   source offsets, so hit-testing reports logical positions.
##   Rich-span lines lay out in visual order too (see
##   `assembleSpans`): each run x span intersection shapes with its
##   run direction and span style. Outside a box justify anchors like
##   left.
## - Span lines are flex rows: the line is the container, runs and
##   inline boxes the items (`TextRowFlex` justification, gap and
##   item alignment; per-span `alignSelf`/`flexGrow`). Spans may
##   carry inline replaced boxes (image/path over one U+FFFC), laid
##   out as atomic units that grow the row and align per the line's
##   text ink (parent-driven, CSS-like). Non-box `TextBoxOpts`
##   inherit the box align as justification unless `flex.justify`
##   is set explicitly (which then distributes every line).
## - Line height is either a font-size multiplier or an absolute px
##   value (`lineHeightAbs`); the two are kept distinct, absolute wins.
##   Span lines with mixed sizes stack variable per-line boxes: each
##   line's height is its largest glyph size times the multiplier
##   (absolute wins globally and stays uniform); each boundary sits
##   0.2 of the previous height past the previous baseline plus 0.8
##   of the next height above the next one (the 0.8/0.2 split the
##   selection band uses). Uniform text reduces to the base step.

import std/options
import std/algorithm
import std/math
import std/strutils
import std/tables
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

  TextWhiteSpace* = enum
    twNormal
      ## Collapse space runs and tabs; wrap to the width.
    twPre
      ## Preserve spaces/tabs; never wrap (long lines overflow).
    twPreWrap
      ## Preserve spaces/tabs; wrap to the width.

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
    whiteSpace*: TextWhiteSpace = twNormal
    tabWidth*: float64 = 0.0
      ## Tab stop interval in px (`0` = 8 space advances at layout
      ## size). Tabs advance to the next multiple, measured from the
      ## line start at space granularity.
    breakWord*: bool = false
      ## Emergency-break an over-wide word at character boundaries
      ## instead of letting it overflow its line. Soft hyphens
      ## (U+00AD) always break first, with or without this flag.
    hyphenChar*: string = "-"
      ## Marker appended to each broken fragment but the last, for
      ## both soft-hyphen and emergency breaks (only when
      ## `breakWord`; `""` breaks CJK-style with no marker).
    decor*: TextDecor = tdNone
      ## Underline/strikethrough rules from per-line ink metrics
      ## (painted with the text paint; bounds ignore them).
    flex*: TextRowFlex
      ## Flex row options for span lines (the zero value follows
      ## `ha` for justification with baseline items and no gap, i.e.
      ## legacy behavior). `justify` set explicitly distributes every
      ## line to the width; `gap` and item alignment need no width.

  TextHit* = object
    ## A laid-out text position: physical `line`, glyph `index`
    ## within it, and whether the point sits `before` that glyph.
    ## `byteIndex` is the glyph's cluster (byte offset in the line
    ## string, line-local; -1 when the line has no glyphs).
    line*: int
    index*: int
    before*: bool
    byteIndex*: int

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
      ## pen plus the shaped offset. Box entries store their top edge
      ## in `y`.
    x0*, y0*, x1*, y1*: float64
      ## Line-local ink box in px (valid only when `hasInk`). Box
      ## entries report their placed rect here.
    hasInk*: bool
    cluster*: uint32
      ## Byte offset of the source character in the shaped string
      ## (from harfnim buffer clusters; line-local). Box entries
      ## report their segment start.
    font*: TextFont
      ## Fallback font that shaped this glyph (`nil` = layout font).
    size*: float64
      ## Glyph size in px (`0` = layout size; spans set their own).
    color*: Color
    hasColor*: bool
      ## Per-glyph ink color (spans); otherwise the layout paint.
    decor*: TextDecor
      ## Per-glyph decoration override (`tdNone` = layout decor).
    boxKind*: SpanBoxKind
      ## `sbkNone` for ordinary shaped glyphs, else an inline box
      ## (image/path) drawn by the canvas paint path.
    imageId*: int
      ## Canvas image handle for `sbkImage` entries.
    boxW*, boxH*: float64
      ## Placed box size in px for box entries.
    boxPath*: Path
      ## Box-local path for `sbkPath` entries, replayed at the placed
      ## offset with the span color (or layout paint).

  FlexJustify* = enum
    fjInherit
      ## Follow the box horizontal align (span boxes only): left maps
      ## to start, center to center, right to end, justify to
      ## space-between. Non-box layouts read this as start.
    fjStart
    fjCenter
    fjEnd
    fjSpaceBetween
    fjSpaceAround
    fjSpaceEvenly

  FlexAlign* = enum
    faAuto
      ## Inherit the container's `alignItems` (items only; a container
      ## set to auto reads as baseline).
    faBaseline
    faStart
    faCenter
    faEnd
    faStretch

  TextRowFlex* = object
    ## Flex row options for one laid-out line (the line is the flex
    ## container, its runs and boxes the items). The zero value is
    ## legacy behavior: follow the box align, baseline items, no gap.
    justify*: FlexJustify
    alignItems*: FlexAlign
    gap*: float64
      ## Fixed px added at each word boundary crossed (single-word
      ## lines have none). Independent of any distribution width.

  SpanBoxKind* = enum
    sbkNone
    sbkImage
      ## Decoded canvas image, drawn with an image-pattern rect.
    sbkPath
      ## Stored path, replayed at the placed offset and filled with
      ## the span color (or the layout paint): covers rectangles and
      ## arbitrary paths alike.

  SpanBox* = object
    ## Inline replaced box carried by a span over a single U+FFFC
    ## placeholder char. Layout reserves the fitted width, grows the
    ## row through the height channel, and aligns it per `alignSelf`;
    ## longer covered ranges still lay out as one box.
    case kind*: SpanBoxKind
    of sbkNone:
      discard
    of sbkImage:
      imageId*: int
        ## Canvas image handle, resolved at draw time.
      imageW*, imageH*: float64
        ## Intrinsic size in px (aspect kept when fitting).
    of sbkPath:
      path*: Path
        ## Box-local path (origin at the box top-left).
      boxW*, boxH*: float64
        ## Intrinsic size in px.

  TextSpan* = object
    ## A byte range `[first, last)` in shared text with its own font
    ## (`nil` = layout font), size (`<= 0` = layout size), color
    ## (`hasColor` off = layout paint) and decor (`tdNone` = layout
    ## decor). Ranges must be sorted, non-overlapping, and inside
    ## the text; gaps use the layout style. A span may instead carry
    ## an inline box (`box.kind != sbkNone`, over one U+FFFC): the
    ## range lays out as a replaced box with `alignSelf`/`flexGrow`
    ## flex item options (`flexGrow > 0` absorbs leftover distribution
    ## width as trailing space after the box; only boxes grow).
    first*, last*: int
    font*: TextFont
    size*: float64
    color*: Color
    hasColor*: bool
    decor*: TextDecor
    box*: SpanBox
    alignSelf*: FlexAlign
    flexGrow*: float64

  ShapedLine* = object
    glyphs*: seq[PlacedGlyph]
    advance*: float64
      ## Total pen advance including inter-glyph letter spacing.

  ShapeCache* = ref object
    ## Per-layout shaping memo: one cache per font (the key carries
    ## size, spacing and string, but not font identity). Returned
    ## layouts are copies, so callers may mutate them freely.
    tab*: Table[string, ShapedLine]

  TextLayout* = object
    font*: TextFont
    lines*: seq[ShapedLine]
    sizePx*: float64
    lineHeightPx*: float64
      ## Base baseline step (multiplier x layout size, or the
      ## absolute override). Span layouts with mixed sizes stack
      ## taller per-line boxes (see `lineYs`); this stays the
      ## uniform base for compatibility.
    lineYs*: seq[float64]
      ## Baseline y per line, relative to the first baseline
      ## (`lineYs[0] == 0` when non-empty). Plain layouts hold the
      ## uniform `i * lineHeightPx`; span layouts hold variable
      ## per-line boxes (0.2/0.8 stacking of adjacent heights, plus
      ## paragraph gaps in boxes). Always prefer this over
      ## `i * lineHeightPx`.

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

proc newShapeCache*(): ShapeCache =
  ## Empty per-font shaping memo for one layout pass.
  ShapeCache(tab: initTable[string, ShapedLine]())

proc shapeLine*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64,
    features: openArray[Feature],
    dir = dirInvalid): ShapedLine =
  ## Shape one line (no newlines) and walk the pen in px. Marks ride on
  ## the pen via their offsets; letter spacing applies between glyphs
  ## with nonzero advance only, so marks stay glued to their base.
  ## `dir` fixes the paragraph direction (`dirInvalid` guesses from
  ## content, as before); visual-run shaping passes each run's own.
  result = ShapedLine(glyphs: @[], advance: 0.0)
  if font == nil or line.len == 0:
    return
  let px = quantizePx(sizePx)
  var sf = font.shaper
  sf.setScale(px * textPosScale)
  var buf = newBuffer()
  buf.pushStr(line)
  if dir != dirInvalid:
    buf.setDirection(dir)
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
      hasInk: false, cluster: buf.info[i].cluster)
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

proc isGlue*(cp: uint32): bool =
  ## Characters that must not start a fallback run (they modify or
  ## join the previous character).
  (cp >= 0x0300u32 and cp <= 0x036Fu32) or
    (cp >= 0x1AB0u32 and cp <= 0x1AFFu32) or
    (cp >= 0x1DC0u32 and cp <= 0x1DFFu32) or
    (cp >= 0x20D0u32 and cp <= 0x20FFu32) or
    (cp >= 0xFE00u32 and cp <= 0xFE0Fu32) or
    (cp >= 0xFE20u32 and cp <= 0xFE2Fu32) or
    cp == 0x200Du32 or
    (cp >= 0x1F3FBu32 and cp <= 0x1F3FFu32) or
    (cp >= 0x1F1E6u32 and cp <= 0x1F1FFu32)

proc isSpreadSlot*(text: string, prev, next: PlacedGlyph): bool =
  ## Whether a justification gap may open between two adjacent
  ## glyphs: the next glyph starts a new character (`cluster`
  ## advances) that is not glue (marks stay on their base). Mirrors
  ## the plain path's chunk boundaries (marks joined to their base).
  let pc = int(prev.cluster)
  let nc = int(next.cluster)
  if nc <= pc or nc >= text.len or pc >= text.len:
    return false
  not isGlue(uint32(text.runeAt(nc)))

proc splitShy*(word: string): tuple[stripped: string,
    points: seq[tuple[bytePos, runeIdx: int]]] =
  ## Split U+00AD soft hyphens out of `word`: `stripped` drops them
  ## (they never shape), `points` marks each break opportunity by
  ## stripped byte offset (for cluster remap) and rune index (for
  ## fragment slicing). A break before stripped rune #q renders the
  ## prefix with the hyphen marker.
  result.stripped = ""
  result.points = @[]
  var bi = 0
  var ri = 0
  for r in word.runes:
    if uint32(r) == 0x00ADu32:
      result.points.add((bi, ri))
    else:
      let t = $r
      result.stripped.add(t)
      bi += t.len
      inc ri

proc unshyCluster*(points: openArray[tuple[bytePos, runeIdx: int]],
    c: uint32): uint32 =
  ## Map a stripped-string cluster back to source coordinates (+2
  ## bytes per earlier soft hyphen).
  result = c
  for p in points:
    if p.bytePos <= int(c):
      result += 2u32
    else:
      break

proc shapeCached*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache = nil,
    fallbacks: openArray[TextFont] = [],
    dir = dirInvalid): ShapedLine =
  ## `shapeLine` through `cache` (direct shaping when nil), splitting
  ## into per-font runs when `fallbacks` is non-empty: each rune goes
  ## to the first font covering it (primary first, uncovered runes
  ## stay primary and render `.notdef`). Glue characters (combining
  ## marks, variation selectors, ZWJ, skin tones, regional
  ## indicators) always join the previous run so sequences never
  ## split across fonts. Run glyphs carry their font (nil = primary).
  ## Hits return copies, so mutating the result never corrupts the
  ## memo (the memo key carries font identity and direction). Soft
  ## hyphens never shape: metrics run on the stripped string while
  ## clusters map back to the input coordinates. `dir` threads to
  ## `shapeLine` (explicit per-run direction for visual shaping).
  if font == nil:
    return shapeLine(font, sizePx, line, letterSpacing, features, dir)
  # Legacy kerning runs only when requested: enable it unless the
  # caller already said otherwise (an explicit `-kern` disables).
  var feats: seq[Feature] = @features
  let kernTag = tagFromStr("kern")
  var hasKern = false
  for f in features:
    if f.tag.toU32() == kernTag.toU32():
      hasKern = true
      break
  if not hasKern:
    feats.add(globalFeature(kernTag))
  # Soft hyphens never shape: metrics run on the stripped string
  # while clusters map back to the input coordinates.
  var eff = line
  var shy: seq[tuple[bytePos, runeIdx: int]] = @[]
  if "\u00AD" in line:
    let ss = splitShy(line)
    eff = ss.stripped
    shy = ss.points
  if fallbacks.len == 0:
    if cache == nil:
      result = shapeLine(font, sizePx, eff, letterSpacing, feats, dir)
    else:
      let key = $cast[int](font) & "\x1F" & $sizePx & "\x1F" &
        $letterSpacing & "\x1F" & $ord(dir) & "\x1F" & eff
      if key in cache.tab:
        result = cache.tab[key]
      else:
        let shaped = shapeLine(font, sizePx, eff, letterSpacing,
          feats, dir)
        cache.tab[key] = shaped
        result = shaped
  else:
    # Split into (byteStart, fontIndex) runs; 0 = primary.
    var runs: seq[tuple[start: int, fi: int]] = @[]
    var pos = 0
    var curFi = -1
    for r in eff.runes:
      let cp = uint32(r)
      let w = ($r).len
      var fi: int
      if curFi >= 0 and isGlue(cp):
        fi = curFi
      else:
        fi = 0
        if not font.shaper.hasGlyph(cp):
          for i, fb in fallbacks:
            if fb != nil and fb.shaper.hasGlyph(cp):
              fi = i + 1
              break
      if fi != curFi:
        runs.add((pos, fi))
        curFi = fi
      pos += w
    result = ShapedLine(glyphs: @[], advance: 0.0)
    if runs.len > 0:
      var pen = 0.0
      for i, rn in runs:
        let stop = if i + 1 < runs.len: runs[i + 1].start
          else: eff.len
        let sub = eff[rn.start ..< stop]
        let rf = if rn.fi == 0: font else: fallbacks[rn.fi - 1]
        let sh = shapeCached(rf, sizePx, sub, letterSpacing, feats,
          cache, dir = dir)
        for g in sh.glyphs:
          var gg = g
          gg.x += pen
          if gg.hasInk:
            gg.x0 += pen
            gg.x1 += pen
          gg.cluster += uint32(rn.start)
          gg.font = if rn.fi == 0: nil else: rf
          result.glyphs.add(gg)
        pen += sh.advance
      result.advance = pen
  if shy.len > 0:
    for j in 0 ..< result.glyphs.len:
      result.glyphs[j].cluster =
        unshyCluster(shy, result.glyphs[j].cluster)

proc shapeVisual*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache = nil,
    fallbacks: openArray[TextFont] = []): ShapedLine =
  ## `shapeCached` in visual order: `visualRuns` (bdAuto) splits the
  ## line, each run's logical substring shapes with that run's
  ## explicit direction (the shaper itself orders RTL runs visually),
  ## and clusters map back to logical source offsets, so hit-test
  ## `byteIndex` values stay logical while glyphs sit left to right.
  ## Single-run lines take the plain path (identical output, shared
  ## cache). Soft-hyphen lines keep the plain path too: U+00AD is BN
  ## and X9 would strip it before nvg's shy handling sees it
  ## (shy x bidi is deferred). Kern holds within runs; cross-run
  ## kern never applies (runs are directional segments). Runs shape
  ## from logical source bytes (X9-removed codes excluded via the
  ## map's coverage), never from the normalized visual text: shaping
  ## visual-order text would double-reverse RTL runs and strand
  ## combining marks ahead of their bases (dotted circles). L4
  ## mirrors apply to odd-level runs via `mirroringFor` before
  ## shaping, since the normalized text is bypassed.
  if "\u00AD" in line:
    return shapeCached(font, sizePx, line, letterSpacing, features,
      cache, fallbacks)
  let vt = visualRuns(line, bdAuto)
  if vt.runs.len <= 1 and vt.text == line:
    return shapeCached(font, sizePx, line, letterSpacing, features,
      cache, fallbacks)
  var covered = newSeq[bool](line.len)
  for m in vt.map:
    if m >= 0 and m < line.len:
      covered[m] = true
  result = ShapedLine(glyphs: @[], advance: 0.0)
  var pen = 0.0
  var prevAdv = false
  for rn in vt.runs:
    # Logical span of this visual run (contiguous barring removed
    # codes, which the coverage set skips).
    var lo = line.len
    var hi = -1
    for b in rn.first ..< rn.last:
      if b >= 0 and b < vt.map.len:
        lo = min(lo, vt.map[b])
        hi = max(hi, vt.map[b])
    if hi < lo:
      continue
    # Trailing joiners belong to this run. Forward-only expansion
    # gives single ownership: a joiner between runs shapes with its
    # preceding logical run, never twice. (Paragraph-initial
    # joiners have no preceding run and stay dropped, as in harfnim.)
    while hi + 3 < line.len:
      let j = hi + 1
      if uint8(line[j]) == 0xE2u8 and
          uint8(line[j + 1]) == 0x80u8 and
          (uint8(line[j + 2]) == 0x8Cu8 or
            uint8(line[j + 2]) == 0x8Du8):
        hi += 3
      else:
        break
    # Logical substring plus its own source map; odd levels take
    # L4 mirrors so cmap picks mirrored glyphs.
    var sub = ""
    var submap: seq[int] = @[]
    var i = lo
    let odd = rn.level mod 2 == 1
    while i <= hi:
      if i < 0 or i >= line.len:
        inc i
        continue
      if not covered[i]:
        # X9-removed bytes stay removed, except the joiners
        # U+200C/U+200D: BN by class, but they steer joining and
        # emoji sequences downstream, so they rejoin the logical
        # substring at their source position (ICU keeps them for
        # display for the same reason; harfnim drops all BN).
        if i + 2 <= hi and uint8(line[i]) == 0xE2u8 and
            uint8(line[i + 1]) == 0x80u8 and
            (uint8(line[i + 2]) == 0x8Cu8 or
              uint8(line[i + 2]) == 0x8Du8):
          sub.add(line[i ..< i + 3])
          for b in 0 ..< 3:
            submap.add(i + b)
          i += 3
        else:
          inc i
        continue
      let b0 = uint8(line[i])
      var w = 1
      if b0 >= 0xF0u8: w = 4
      elif b0 >= 0xE0u8: w = 3
      elif b0 >= 0xC2u8: w = 2
      elif b0 >= 0x80u8 and b0 < 0xC0u8:
        inc i # stray continuation: covered only via clamping
        continue
      var rep = line[i ..< min(i + w, hi + 1)]
      if odd:
        let r = line.runeAt(i)
        let m = mirroringFor(uint32(r))
        if m.isSome:
          rep = $Rune(m.get)
      sub.add(rep)
      for b in 0 ..< rep.len:
        submap.add(i + min(b, w - 1))
      i += w
    if sub.len == 0:
      continue
    let sh = shapeCached(font, sizePx, sub, letterSpacing, features,
      cache, fallbacks, rn.dir)
    if letterSpacing != 0.0 and prevAdv and sh.advance > 0.0 and
        sh.glyphs.len > 0:
      pen += letterSpacing
    for g in sh.glyphs:
      var gg = g
      gg.x += pen
      if gg.hasInk:
        gg.x0 += pen
        gg.x1 += pen
      let vc = int(g.cluster)
      if vc >= 0 and vc < submap.len:
        gg.cluster = uint32(submap[vc])
      result.glyphs.add(gg)
    pen += sh.advance
    prevAdv = sh.advance > 0.0
  result.advance = pen

proc fittedBox*(span: TextSpan, px: float64): tuple[w, h: float64] =
  ## Fitted inline-box size: span size (or layout size) tall, aspect
  ## kept from the intrinsic size. Zero intrinsic height keeps the
  ## intrinsic width with the fitted height.
  let fitH = if span.size > 0.0: span.size else: px
  case span.box.kind
  of sbkImage:
    if span.box.imageH > 0.0:
      let k = fitH / span.box.imageH
      (span.box.imageW * k, fitH)
    else:
      (span.box.imageW, fitH)
  of sbkPath:
    if span.box.boxH > 0.0:
      let k = fitH / span.box.boxH
      (span.box.boxW * k, fitH)
    else:
      (span.box.boxW, fitH)
  of sbkNone:
    (0.0, 0.0)

proc assembleSpans*(font: TextFont, px: float64,
    segs: openArray[tuple[span: int, text: string, word: int,
      alignSelf: FlexAlign, flexGrow: float64]],
    spans: openArray[TextSpan],
    letterSpacing: float64, features: openArray[Feature],
    cache: ShapeCache, fallbacks: openArray[TextFont],
    glyphExtra = 0.0, flex = TextRowFlex(), targetW = 0.0): ShapedLine =
  ## Concatenate span-tagged pieces (`segs` in logical order; `span`
  ## -1 = layout style, `word` -1 = gap) into one shaped line with
  ## line-local clusters. The line is a flex row container: `flex`
  ## sets justification, item alignment and the word-gap; each seg
  ## may override alignment and absorb leftover width (`flexGrow`,
  ## boxes only). Single LTR lines take the logical path (identical
  ## output). Otherwise each `visualRuns` (bdAuto) run shapes its
  ## logical substring with the run direction (the shaper orders RTL
  ## runs visually), split further at span boundaries, so
  ## mixed-direction lines come out in visual order while clusters
  ## stay logical and glyphs keep their span style. LTR runs emit
  ## segments forward, RTL runs reverse them; shaping never sees
  ## visual-order text (that would double-reverse RTL runs and
  ## strand marks). Odd runs take L4 mirrors via `mirroringFor`,
  ## X9-removed codes stay excluded (except re-injected U+200C/U+200D
  ## with single-owner forward expansion), and soft-hyphen lines keep
  ## the logical path (shy x bidi is deferred). Box segments (spans
  ## with a `SpanBox` payload) emit one replaced-box entry each
  ## (fitted width, full row height channel) instead of shaping;
  ## `glyphExtra` opens each spread slot in emission order, testing
  ## both orders so reversed RTL pairs still count while marks stay
  ## glued (never combined with width distribution). No letter
  ## spacing opens between segments (existing span semantics, unlike
  ## `shapeVisual`'s inter-run spacing). Width distribution
  ## (`targetW > 0`, leftover only): grow shares widen the pen after
  ## grow boxes, then justification shifts ride every visual gap per
  ## mode (with gap already walked into the pen at each word boundary
  ## crossed in emission order).
  var starts = newSeq[int](segs.len + 1)
  var concat = ""
  for i, sg in segs:
    concat.add(sg.text)
    starts[i + 1] = starts[i] + sg.text.len
  if concat.len == 0:
    return ShapedLine(glyphs: @[], advance: 0.0)
  let vt = visualRuns(concat, bdAuto)
  let singleLtr = vt.runs.len == 1 and vt.runs[0].level mod 2 == 0 and
    vt.text == concat
  let logical = "\u00AD" in concat or singleLtr
  result = ShapedLine(glyphs: @[], advance: 0.0)
  var pen = 0.0
  var curWord = -2
  # Emission records for the post passes: word-boundary glyph splits
  # (justification shares), box entries (glyph index, seg index).
  var bounds: seq[int] = @[]
  var boxes: seq[tuple[gi, si: int]] = @[]
  var boxDone = newSeq[bool](segs.len)
  template crossWord(sgWord: int) =
    ## Fixed gap at each new word (single-word lines have none).
    if sgWord >= 0 and sgWord != curWord:
      if curWord != -2:
        if flex.gap != 0.0:
          pen += flex.gap
        bounds.add(result.glyphs.len)
      curWord = sgWord
  template dressSpan(gg: var PlacedGlyph, gsi: int, pf: TextFont) =
    if gsi >= 0 and gsi < spans.len:
      if pf != font and gg.font == nil:
        gg.font = pf
      if spans[gsi].size > 0.0:
        gg.size = spans[gsi].size
      gg.hasColor = spans[gsi].hasColor
      gg.color = spans[gsi].color
      gg.decor = spans[gsi].decor
  template emitBox(si: int, atCluster: uint32) =
    let gsi = segs[si].span
    let (bw, bh) = fittedBox(spans[gsi], px)
    var gg = PlacedGlyph(x: pen, y: -bh, x0: pen, x1: pen + bw,
      y0: -bh, y1: 0.0, hasInk: bw > 0.0 and bh > 0.0,
      cluster: atCluster, size: bh, boxKind: spans[gsi].box.kind,
      boxW: bw, boxH: bh)
    if spans[gsi].box.kind == sbkImage:
      gg.imageId = spans[gsi].box.imageId
    elif spans[gsi].box.kind == sbkPath:
      gg.boxPath = spans[gsi].box.path
    gg.hasColor = spans[gsi].hasColor
    gg.color = spans[gsi].color
    gg.decor = spans[gsi].decor
    boxes.add((result.glyphs.len, si))
    result.glyphs.add(gg)
    pen += bw
  if logical:
    for i, sg in segs:
      crossWord(sg.word)
      let gsi = sg.span
      if gsi >= 0 and gsi < spans.len and
          spans[gsi].box.kind != sbkNone:
        emitBox(i, uint32(starts[i]))
        continue
      let pf = if gsi >= 0 and gsi < spans.len and
          spans[gsi].font != nil: spans[gsi].font else: font
      let psz = if gsi >= 0 and gsi < spans.len and
          spans[gsi].size > 0.0: spans[gsi].size else: px
      let sh = shapeCached(pf, psz, sg.text, letterSpacing, features,
        cache, fallbacks)
      for g in sh.glyphs:
        var gg = g
        gg.cluster += uint32(starts[i])
        if glyphExtra != 0.0 and result.glyphs.len > 0 and
            isSpreadSlot(concat, result.glyphs[^1], gg):
          pen += glyphExtra
        gg.x += pen
        if gg.hasInk:
          gg.x0 += pen
          gg.x1 += pen
        dressSpan(gg, gsi, pf)
        result.glyphs.add(gg)
      pen += sh.advance
  else:
    var covered = newSeq[bool](concat.len)
    for m in vt.map:
      if m >= 0 and m < concat.len:
        covered[m] = true
    for rn in vt.runs:
      var lo = concat.len
      var hi = -1
      for b in rn.first ..< rn.last:
        if b >= 0 and b < vt.map.len:
          lo = min(lo, vt.map[b])
          hi = max(hi, vt.map[b])
      if hi < lo:
        continue
      while hi + 3 < concat.len:
        let j = hi + 1
        if uint8(concat[j]) == 0xE2u8 and
            uint8(concat[j + 1]) == 0x80u8 and
            (uint8(concat[j + 2]) == 0x8Cu8 or
              uint8(concat[j + 2]) == 0x8Du8):
          hi += 3
        else:
          break
      let odd = rn.level mod 2 == 1
      var order: seq[int] = @[]
      for i in 0 ..< segs.len:
        let a = max(lo, starts[i])
        let b = min(hi + 1, starts[i + 1])
        if a < b:
          order.add(i)
      if odd:
        order.reverse()
      for si in order:
        let a = max(lo, starts[si])
        let b = min(hi + 1, starts[si + 1])
        crossWord(segs[si].word)
        let gsi = segs[si].span
        if gsi >= 0 and gsi < spans.len and
            spans[gsi].box.kind != sbkNone:
          if not boxDone[si]:
            boxDone[si] = true
            emitBox(si, uint32(starts[si]))
          continue
        var sub = ""
        var submap: seq[int] = @[]
        var i = a
        while i < b:
          if i < 0 or i >= concat.len:
            inc i
            continue
          if not covered[i]:
            if i + 2 < b and uint8(concat[i]) == 0xE2u8 and
                uint8(concat[i + 1]) == 0x80u8 and
                (uint8(concat[i + 2]) == 0x8Cu8 or
                  uint8(concat[i + 2]) == 0x8Du8):
              sub.add(concat[i ..< i + 3])
              for k in 0 ..< 3:
                submap.add(i + k)
              i += 3
            else:
              inc i
            continue
          let b0 = uint8(concat[i])
          var w = 1
          if b0 >= 0xF0u8: w = 4
          elif b0 >= 0xE0u8: w = 3
          elif b0 >= 0xC2u8: w = 2
          elif b0 >= 0x80u8 and b0 < 0xC0u8:
            inc i
            continue
          var rep = concat[i ..< min(i + w, b)]
          if odd:
            let r = concat.runeAt(i)
            let m = mirroringFor(uint32(r))
            if m.isSome:
              rep = $Rune(m.get)
          sub.add(rep)
          for k in 0 ..< rep.len:
            submap.add(i + min(k, w - 1))
          i += w
        if sub.len == 0:
          continue
        let pf = if gsi >= 0 and gsi < spans.len and
            spans[gsi].font != nil: spans[gsi].font else: font
        let psz = if gsi >= 0 and gsi < spans.len and
            spans[gsi].size > 0.0: spans[gsi].size else: px
        let sh = shapeCached(pf, psz, sub, letterSpacing, features,
          cache, fallbacks, rn.dir)
        for g in sh.glyphs:
          var gg = g
          let vc = int(g.cluster)
          if vc >= 0 and vc < submap.len:
            gg.cluster = uint32(submap[vc])
          if glyphExtra != 0.0 and result.glyphs.len > 0 and
              (isSpreadSlot(concat, result.glyphs[^1], gg) or
                isSpreadSlot(concat, gg, result.glyphs[^1])):
            pen += glyphExtra
          gg.x += pen
          if gg.hasInk:
            gg.x0 += pen
            gg.x1 += pen
          dressSpan(gg, gsi, pf)
          result.glyphs.add(gg)
        pen += sh.advance
  # Parent alignment pass: the line owns the baseline and content
  # box; each box declares how it sits in it. Text ink (excluding
  # boxes) anchors the reference; box-only lines fall back to the
  # box union.
  var refFound = false
  var refY0, refY1 = 0.0
  for g in result.glyphs:
    if g.boxKind != sbkNone or not g.hasInk:
      continue
    if not refFound:
      refY0 = g.y0
      refY1 = g.y1
      refFound = true
    else:
      refY0 = min(refY0, g.y0)
      refY1 = max(refY1, g.y1)
  if not refFound:
    for g in result.glyphs:
      if g.boxKind == sbkNone or not g.hasInk:
        continue
      if not refFound:
        refY0 = g.y0
        refY1 = g.y1
        refFound = true
      else:
        refY0 = min(refY0, g.y0)
        refY1 = max(refY1, g.y1)
  if refFound:
    let refCy = (refY0 + refY1) * 0.5
    for b in boxes:
      var al = segs[b.si].alignSelf
      if al == faAuto:
        al = flex.alignItems
      if al == faAuto:
        al = faBaseline
      case al
      of faBaseline, faAuto:
        discard
      of faStart:
        result.glyphs[b.gi].y = refY0
        result.glyphs[b.gi].y0 = refY0
        result.glyphs[b.gi].y1 = refY0 + result.glyphs[b.gi].boxH
      of faCenter:
        let t = refCy - result.glyphs[b.gi].boxH * 0.5
        result.glyphs[b.gi].y = t
        result.glyphs[b.gi].y0 = t
        result.glyphs[b.gi].y1 = t + result.glyphs[b.gi].boxH
      of faEnd:
        let t = refY1 - result.glyphs[b.gi].boxH
        result.glyphs[b.gi].y = t
        result.glyphs[b.gi].y0 = t
        result.glyphs[b.gi].y1 = t + result.glyphs[b.gi].boxH
      of faStretch:
        if result.glyphs[b.gi].boxH != refY1 - refY0:
          result.glyphs[b.gi].boxH = refY1 - refY0
        result.glyphs[b.gi].y = refY0
        result.glyphs[b.gi].y0 = refY0
        result.glyphs[b.gi].y1 = refY1
        result.glyphs[b.gi].hasInk =
          result.glyphs[b.gi].boxW > 0.0 and refY1 > refY0
  # Width distribution over the target width (leftover only, never
  # combined with `glyphExtra` spreading): grow shares widen the pen
  # after grow boxes first, then justification shifts ride the word
  # boundaries in emission order. Only distributing modes (and
  # growth) reach the target advance; center/end keep the natural
  # advance and shift the content instead.
  if targetW > 0.0 and glyphExtra == 0.0:
    var free = targetW - pen
    var reached = false
    if free > 0.0:
      var totalGrow = 0.0
      for b in boxes:
        totalGrow += max(0.0, segs[b.si].flexGrow)
      if totalGrow > 0.0:
        let base = free
        for b in boxes:
          let share = base * max(0.0, segs[b.si].flexGrow) /
            totalGrow
          if share != 0.0:
            for j in b.gi + 1 ..< result.glyphs.len:
              result.glyphs[j].x += share
              if result.glyphs[j].hasInk:
                result.glyphs[j].x0 += share
                result.glyphs[j].x1 += share
            pen += share
        free = targetW - pen
        reached = true
    if free > 0.0:
      var fj = flex.justify
      if fj == fjInherit:
        fj = fjStart
      template shiftAll(dx: float64) =
        if dx != 0.0:
          for j in 0 ..< result.glyphs.len:
            result.glyphs[j].x += dx
            if result.glyphs[j].hasInk:
              result.glyphs[j].x0 += dx
              result.glyphs[j].x1 += dx
      template shiftFrom(gi: int, dx: float64) =
        if dx != 0.0:
          for j in gi ..< result.glyphs.len:
            result.glyphs[j].x += dx
            if result.glyphs[j].hasInk:
              result.glyphs[j].x0 += dx
              result.glyphs[j].x1 += dx
      case fj
      of fjInherit, fjStart:
        discard
      of fjCenter:
        shiftAll(free * 0.5)
      of fjEnd:
        shiftAll(free)
      of fjSpaceBetween:
        if bounds.len > 0:
          for b in bounds:
            shiftFrom(b, free / float64(bounds.len))
          reached = true
      of fjSpaceAround:
        if bounds.len > 0:
          shiftAll(free / float64(2 * bounds.len))
          for b in bounds:
            shiftFrom(b, free / float64(bounds.len))
          reached = true
      of fjSpaceEvenly:
        let n = float64(bounds.len + 1)
        shiftAll(free / n)
        for b in bounds:
          shiftFrom(b, free / n)
        reached = true
    if reached:
      pen = targetW
  result.advance = pen

proc lineY*(lay: TextLayout, i: int): float64 =
  ## Baseline y of line `i`, relative to the first baseline.
  ## Prefers `lineYs`; falls back to `i * lineHeightPx`.
  if lay.lineYs.len == lay.lines.len and i >= 0 and
      i < lay.lineYs.len:
    lay.lineYs[i]
  else:
    float64(i) * lay.lineHeightPx

proc lineMaxSize*(lay: TextLayout, i: int): float64 =
  ## Largest glyph size on line `i` (per-glyph span sizes, else the
  ## layout size). Empty lines report the layout size.
  result = lay.sizePx
  if i < 0 or i >= lay.lines.len:
    return
  for g in lay.lines[i].glyphs:
    result = max(result, if g.size > 0.0: g.size else: lay.sizePx)

proc uniformBaselines*(n: int, step: float64): seq[float64] =
  ## `n` baselines at multiples of `step`.
  result = newSeq[float64](n)
  for i in 0 ..< n:
    result[i] = float64(i) * step

proc spanBaselines*(lines: openArray[ShapedLine], sizePx,
    lineHeightMul, lineHeightAbs: float64,
    newPara: openArray[bool] = [],
    paragraphGap = 0.0): seq[float64] =
  ## Variable baselines for span-shaped lines: each line's height is
  ## its largest glyph size times the multiplier (`lineHeightAbs > 0`
  ## forces that uniform step instead). Each boundary sits 0.2 of the
  ## previous height past the previous baseline plus 0.8 of the next
  ## height above the next one; `newPara[i]` adds `paragraphGap`
  ## before line `i`. Uniform sizes reduce to the base step.
  result = newSeq[float64](lines.len)
  if lines.len == 0:
    return
  if lineHeightAbs > 0.0:
    for i in 1 ..< lines.len:
      result[i] = result[i - 1] + lineHeightAbs +
        (if newPara.len == lines.len and newPara[i]: paragraphGap
          else: 0.0)
    return
  let mul = max(0.0, lineHeightMul)
  var hs = newSeq[float64](lines.len)
  for i, ln in lines:
    var m = sizePx
    for g in ln.glyphs:
      m = max(m, if g.size > 0.0: g.size else: sizePx)
    hs[i] = m * mul
  for i in 1 ..< lines.len:
    result[i] = result[i - 1] + 0.2 * hs[i - 1] + 0.8 * hs[i] +
      (if newPara.len == lines.len and newPara[i]: paragraphGap
        else: 0.0)

proc layoutText*(font: TextFont, sizePx: float64, s: string,
    letterSpacing = 0.0, lineHeightMul = 1.2,
    features: openArray[Feature] = [],
    lineHeightAbs = 0.0,
    fallbacks: openArray[TextFont] = []): TextLayout =
  ## Shape every `\n`-separated line. A nil font yields empty lines
  ## (callers draw nothing and measure zero). `lineHeightAbs > 0`
  ## overrides the multiplier with an absolute baseline step in px.
  ## `fallbacks` covers characters missing from `font` (see
  ## `shapeCached`); shaping memoizes within the call. Soft hyphens
  ## never shape (no break opportunity outside boxes: invisible).
  ## Lines lay out in visual order (see `shapeVisual`).
  let px = max(1.0, sizePx)
  let step = if lineHeightAbs > 0.0: lineHeightAbs
    else: px * max(0.0, lineHeightMul)
  result = TextLayout(font: font, lines: @[], sizePx: px,
    lineHeightPx: step)
  let cache = newShapeCache()
  for line in splitTextLines(s):
    result.lines.add(shapeVisual(font, px, line, letterSpacing,
      features, cache, fallbacks))
  result.lineYs = uniformBaselines(result.lines.len, step)

proc spanAt*(spans: openArray[TextSpan], bytePos: int): int =
  ## Index of the span containing `bytePos`, else -1. Linear scan;
  ## span counts are small.
  for i, sp in spans:
    if bytePos >= sp.first and bytePos < sp.last:
      return i
  -1

proc layoutSpans*(font: TextFont, sizePx: float64, s: string,
    spans: openArray[TextSpan], letterSpacing = 0.0,
    lineHeightMul = 1.2, features: openArray[Feature] = [],
    lineHeightAbs = 0.0,
    fallbacks: openArray[TextFont] = [],
    flex = TextRowFlex()): TextLayout =
  ## Shape explicit-`\n` lines with per-range fonts, sizes, colors
  ## and decorations. Unspanned bytes use the layout font/size/paint.
  ## Ranges index `s` after `\r\n`/`\r` normalization to `\n`.
  ## Clusters stay line-local; glyphs carry their span style. Span
  ## lines lay out in visual order (see `assembleSpans`): each run x
  ## span intersection shapes with its run direction and span style,
  ## clusters stay logical. `flex` opts into row flex (gap and item
  ## alignment work without a width; justification needs `targetW`,
  ## so only boxes distribute). Lines
  ## with larger spans stand taller (see `spanBaselines`); an
  ## absolute line height stays uniform.
  let src = s.replace("\r\n", "\n").replace("\r", "\n")
  let px = max(1.0, sizePx)
  let step = if lineHeightAbs > 0.0: lineHeightAbs
    else: px * max(0.0, lineHeightMul)
  result = TextLayout(font: font, lines: @[], sizePx: px,
    lineHeightPx: step)
  let cache = newShapeCache()
  var lineStart = 0
  for para in splitTextLines(src):
    if para.len == 0:
      result.lines.add(ShapedLine(glyphs: @[], advance: 0.0))
    else:
      var edges: seq[int] = @[0, para.len]
      for sp in spans:
        let a = clamp(sp.first - lineStart, 0, para.len)
        let b = clamp(sp.last - lineStart, 0, para.len)
        if a < b:
          edges.add(a)
          edges.add(b)
      edges.sort(system.cmp)
      var segs: seq[tuple[span: int, text: string, word: int,
        alignSelf: FlexAlign, flexGrow: float64]] = @[]
      var prev = -1
      for e in edges:
        if e == prev:
          continue
        if prev >= 0:
          let si = spanAt(spans, lineStart + prev)
          segs.add((si, para[prev ..< e], -1,
            if si >= 0: spans[si].alignSelf else: faAuto,
            if si >= 0: spans[si].flexGrow else: 0.0))
        prev = e
      result.lines.add(assembleSpans(font, px, segs, spans,
        letterSpacing, features, cache, fallbacks, 0.0, flex, 0.0))
    lineStart += para.len + 1
  result.lineYs = spanBaselines(result.lines, px, lineHeightMul,
    lineHeightAbs)

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
    let oy = lay.lineY(i)
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

proc hitTest*(lay: TextLayout, x, y: float64,
    ha = thaLeft): TextHit =
  ## Map a layout-local point to a glyph (`x` relative to the anchor,
  ## `y` relative to the first baseline; lines follow `lineYs`). Each
  ## point maps to its nearest baseline (ties go to the earlier
  ## line). Each glyph owns the span up to the next glyph's
  ## origin (last: to the line advance); the nearer half reports
  ## `before`. Empty layouts hit line -1; empty lines hit index 0.
  ## Box-positioned layouts (see `layoutBoxOpts`) pass `thaLeft`.
  if lay.lines.len == 0:
    return TextHit(line: -1, index: 0, before: true, byteIndex: -1)
  var li = 0
  var best = abs(y - lay.lineY(0))
  for i in 1 ..< lay.lines.len:
    let d = abs(y - lay.lineY(i))
    if d < best:
      best = d
      li = i
  let line = lay.lines[li]
  let pen = linePenX(line.advance, ha)
  if line.glyphs.len == 0:
    return TextHit(line: li, index: 0, before: true, byteIndex: -1)
  var idx = line.glyphs.len - 1
  var before = false
  for i, g in line.glyphs:
    let gx = pen + g.x
    let nx = if i + 1 < line.glyphs.len:
        pen + line.glyphs[i + 1].x
      else:
        pen + line.advance
    if x < nx:
      idx = i
      before = x < (gx + nx) * 0.5
      break
  TextHit(line: li, index: idx, before: before,
    byteIndex: int(line.glyphs[idx].cluster))

proc caretX*(lay: TextLayout, hit: TextHit,
    ha = thaLeft): float64 =
  ## Drawing x for a hit: the glyph origin (`before`) or the next
  ## boundary (line advance past the last glyph). Anchor-relative
  ## like `hitTest`.
  if hit.line < 0 or hit.line >= lay.lines.len:
    return 0.0
  let line = lay.lines[hit.line]
  let pen = linePenX(line.advance, ha)
  if hit.before or line.glyphs.len == 0:
    let i = clamp(hit.index, 0, max(0, line.glyphs.len - 1))
    if line.glyphs.len == 0:
      return pen
    return pen + line.glyphs[i].x
  let i = clamp(hit.index + 1, 0, line.glyphs.len)
  if i < line.glyphs.len:
    return pen + line.glyphs[i].x
  pen + line.advance

proc caretAtByte*(line: ShapedLine, byteIdx: int): float64 =
  ## Caret x for a line-local logical byte offset: the leading edge
  ## of the first glyph with that exact cluster, else the first
  ## glyph past it, else the line advance. Exact-match-first keeps
  ## visual lines correct (clusters are logical but glyphs sit in
  ## visual order); pure LTR lines reduce to the old scan. No
  ## affinity model: a boundary between runs reports one side.
  for g in line.glyphs:
    if int(g.cluster) == byteIdx:
      return g.x
  for g in line.glyphs:
    if int(g.cluster) > byteIdx:
      return g.x
  line.advance

proc selectionRects*(lay: TextLayout, fromLine, fromByte, toLine,
    toByte: int, ha = thaLeft): seq[Rect] =
  ## Highlight rects for the byte range
  ## `[fromLine:fromByte, toLine:toByte)` (line-local byte offsets,
  ## reversed ranges normalized, empty ranges yield nothing). One
  ## rect per covered line: caret to caret horizontally, line ink
  ## vertically (a 0.8/0.2 band of the line's largest size for
  ## inkless lines). Anchor-relative like `hitTest`. Logical ranges
  ## spanning runs of opposite direction highlight the visual span
  ## between the two carets (proper bidi selection wants disjoint
  ## rects; deferred).
  result = @[]
  if lay.lines.len == 0:
    return
  var fl = fromLine
  var fb = fromByte
  var tl = toLine
  var tb = toByte
  if fl > tl or (fl == tl and fb > tb):
    swap(fl, tl)
    swap(fb, tb)
  if fl == tl and fb == tb:
    return
  fl = clamp(fl, 0, lay.lines.len - 1)
  tl = clamp(tl, 0, lay.lines.len - 1)
  for li in fl .. tl:
    let line = lay.lines[li]
    let pen = linePenX(line.advance, ha)
    let x0 = pen + (if li == fl: caretAtByte(line, fb) else: 0.0)
    let x1 = pen + (if li == tl: caretAtByte(line, tb)
      else: line.advance)
    if x1 <= x0:
      continue
    let base = lay.lineY(li)
    var y0 = base - lay.lineMaxSize(li) * 0.8
    var y1 = base + lay.lineMaxSize(li) * 0.2
    var found = false
    for g in line.glyphs:
      if g.hasInk:
        if not found:
          y0 = base + g.y0
          y1 = base + g.y1
          found = true
        else:
          y0 = min(y0, base + g.y0)
          y1 = max(y1, base + g.y1)
    if y1 > y0:
      result.add(rect(x0, y0, x1 - x0, y1 - y0))

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
    lineHeightPx: lay.lineHeightPx, lineYs: lay.lineYs)
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
    if shapeCached(font, sizePx, trial, letterSpacing,
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
    features: openArray[Feature],
    cache: ShapeCache = nil,
    fallbacks: openArray[TextFont] = []): ShapedLine =
  ## Spread the words of `line` so the advance equals `boxW`. Chunk
  ## boundaries follow the runes (plus trailing spaces); the glyphs
  ## come from one whole-line visual shaping (`shapeVisual`), so
  ## kerning and ligatures survive across chunks, toggling
  ## justification never reflows them, and mixed-direction lines
  ## spread in visual order. Chunk lookup is by logical cluster
  ## (order-free), so each glyph rides its own chunk's share. The
  ## leftover spreads evenly over the chunk boundaries.
  ## Spaceless runs (CJK included) spread between their runes;
  ## combining marks join their base and never take a gap.
  ## Already-over-wide lines come back plainly shaped but
  ## gap-preserving.
  var words: seq[string] = @[]
  var gaps: seq[int] = @[]
  var cur = ""
  var sp = 0
  for r in line.runes:
    if uint32(r) == 0x20u32:
      inc sp
    elif isGlue(uint32(r)) and cur != "":
      # Combining marks join their base (never start a chunk), so
      # justification gaps never detach them. Byte-splitting here
      # used to shred multi-byte text into invalid chunks.
      cur.add($r)
    else:
      if cur != "" or sp > 0:
        if cur != "":
          words.add(cur)
          gaps.add(sp)
        elif words.len > 0:
          gaps[^1] += sp
        cur = ""
        sp = 0
      cur.add($r)
  if cur != "":
    words.add(cur)
    gaps.add(sp)
  elif sp > 0 and words.len > 0:
    gaps[^1] += sp
  if words.len == 0:
    return shapeCached(font, sizePx, line, letterSpacing, features,
      cache, fallbacks)
  # Chunk boundaries (byte offsets) steer the spread; the glyphs
  # come from one whole-line shaping so kerning and ligatures
  # survive across chunks.
  var starts: seq[int] = @[]
  var pos = 0
  for i, w in words:
    starts.add(pos)
    pos += w.len
    for _ in 0 ..< gaps[i]:
      pos += 1
  let whole = shapeVisual(font, sizePx, line, letterSpacing,
    features, cache, fallbacks)
  let natural = whole.advance
  if natural >= boxW or words.len < 2:
    # No room (or nothing to spread between): plain shaping, gaps
    # preserved. Spaceless runs spread between their runes through
    # the path below (each rune is its own chunk).
    return whole
  let extra = (boxW - natural) / float64(words.len - 1)
  result = ShapedLine(glyphs: @[], advance: boxW)
  for g in whole.glyphs:
    # Each glyph rides its chunk's accumulated share (order-free).
    var ci = 0
    for i, s in starts:
      if int(g.cluster) >= s:
        ci = i
      else:
        break
    var gg = g
    let dx = extra * float64(ci)
    gg.x += dx
    if gg.hasInk:
      gg.x0 += dx
      gg.x1 += dx
    result.glyphs.add(gg)

proc ellipsizeLine*(font: TextFont, sizePx: float64, line: string,
    letterSpacing: float64, maxW: float64,
    features: openArray[Feature], marker = "…",
    cache: ShapeCache = nil,
    fallbacks: openArray[TextFont] = []): ShapedLine =
  ## Trim trailing runes and append `marker` until the line fits
  ## `maxW`. Fits already: plain shaping. Nothing fits (even the
  ## marker alone): an empty line.
  if maxW <= 0.0:
    return ShapedLine(glyphs: @[], advance: 0.0)
  var shaped = shapeCached(font, sizePx, line, letterSpacing, features,
    cache, fallbacks)
  if shaped.advance <= maxW:
    return shaped
  var runes = line.toRunes()
  while runes.len > 0:
    runes.setLen(runes.len - 1)
    shaped = shapeCached(font, sizePx, $runes & marker, letterSpacing,
      features, cache, fallbacks)
    if shaped.advance <= maxW:
      return shaped
  shaped = shapeCached(font, sizePx, marker, letterSpacing, features,
    cache, fallbacks)
  if shaped.advance <= maxW:
    return shaped
  ShapedLine(glyphs: @[], advance: 0.0)

proc sameColor*(a, b: Color): bool =
  a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a

proc appendLayoutSpan*(p: var Path, xf: Xform, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign, wantColor: bool, color: Color) =
  ## Like `appendLayout` but only emits one color group: uncolored
  ## glyphs (`wantColor` false) or glyphs exactly matching `color`.
  ## Inline boxes never emit outline verbs here; the canvas paint
  ## path draws them separately (see `paintBoxes`).
  let dy = valignShift(lay, ha, va)
  for i, line in lay.lines:
    let ox = x + linePenX(line.advance, ha)
    let oy = y + dy + lay.lineY(i)
    for g in line.glyphs:
      if g.boxKind != sbkNone:
        continue
      if g.hasColor != wantColor:
        continue
      if wantColor and not sameColor(g.color, color):
        continue
      let gf = if g.font != nil: g.font else: lay.font
      if gf == nil:
        continue
      var ops: seq[DrawOp] = @[]
      var sf = gf.shaper
      if not sf.drawGlyph(newGlyphId(g.gid),
          proc(op: DrawOp) = ops.add(op)):
        continue
      let gs = (if g.size > 0.0: g.size else: lay.sizePx) / gf.upem
      let gx = ox + g.x
      let gy = oy + g.y
      for op in ops:
        case op.kind
        of moveTo:
          p.moveTo(gx + float64(op.to.x) * gs, gy - float64(op.to.y) * gs,
            xf)
        of lineTo:
          p.lineTo(gx + float64(op.to.x) * gs, gy - float64(op.to.y) * gs,
            xf)
        of quadraticTo:
          p.quadTo(gx + float64(op.qCtrl.x) * gs,
            gy - float64(op.qCtrl.y) * gs, gx + float64(op.qTo.x) * gs,
            gy - float64(op.qTo.y) * gs, xf)
        of cubicTo:
          p.bezierTo(gx + float64(op.c1.x) * gs,
            gy - float64(op.c1.y) * gs, gx + float64(op.c2.x) * gs,
            gy - float64(op.c2.y) * gs, gx + float64(op.cTo.x) * gs,
            gy - float64(op.cTo.y) * gs, xf)
        of closePath:
          p.closePath()

proc appendLayout*(p: var Path, xf: Xform, lay: TextLayout, x, y: float64,
    ha: TextHAlign, va: TextVAlign) =
  ## Emit the laid-out glyph outlines as path verbs (transform captured
  ## per verb, like all `Path` input). Glyphs without outlines advance
  ## the pen but emit nothing. Fallback glyphs draw with their own
  ## shaper at the layout size over their own upem. Inline boxes are
  ## skipped (drawn separately by the canvas paint path).
  if lay.lines.len == 0:
    return
  let dy = valignShift(lay, ha, va)
  for i, line in lay.lines:
    let ox = x + linePenX(line.advance, ha)
    let oy = y + dy + lay.lineY(i)
    for g in line.glyphs:
      if g.boxKind != sbkNone:
        continue
      let gf = if g.font != nil: g.font else: lay.font
      if gf == nil:
        continue
      var ops: seq[DrawOp] = @[]
      var sf = gf.shaper
      if not sf.drawGlyph(newGlyphId(g.gid),
          proc(op: DrawOp) = ops.add(op)):
        continue
      let gs = (if g.size > 0.0: g.size else: lay.sizePx) / gf.upem
      let gx = ox + g.x
      let gy = oy + g.y
      for op in ops:
        case op.kind
        of moveTo:
          p.moveTo(gx + float64(op.to.x) * gs, gy - float64(op.to.y) * gs,
            xf)
        of lineTo:
          p.lineTo(gx + float64(op.to.x) * gs, gy - float64(op.to.y) * gs,
            xf)
        of quadraticTo:
          p.quadTo(gx + float64(op.qCtrl.x) * gs,
            gy - float64(op.qCtrl.y) * gs, gx + float64(op.qTo.x) * gs,
            gy - float64(op.qTo.y) * gs, xf)
        of cubicTo:
          p.bezierTo(gx + float64(op.c1.x) * gs,
            gy - float64(op.c1.y) * gs, gx + float64(op.c2.x) * gs,
            gy - float64(op.c2.y) * gs, gx + float64(op.cTo.x) * gs,
            gy - float64(op.cTo.y) * gs, xf)
        of closePath:
          p.closePath()
