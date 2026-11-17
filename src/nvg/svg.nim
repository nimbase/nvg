## Minimal SVG image loading: a vetted subset of SVG rendered through
## the normal canvas pipeline.
##
## An SVG document is parsed (stdlib `std/xmlparser`, no new
## dependencies) and its elements drive ordinary `Canvas` calls, so
## gradients, transforms and paints behave exactly like hand-drawn
## content on every backend (CPU, JIT, Metal). The result uploads via
## the existing image registry, mipping included.
##
## Supported subset (v1): `svg` root with `width`/`height`/`viewBox`,
## `g`, nested `svg` (x/y offset plus optional viewport mapping),
## `rect` (with `rx`/`ry`), `circle`, `ellipse`, `line`, `polyline`,
## `polygon`, `path` (`M L H V C S Q T Z`, absolute and relative;
## arcs are skipped), `defs`, `linearGradient` and `radialGradient`
## (`userSpaceOnUse` and `objectBoundingBox`, `gradientTransform`),
## presentation attributes (`fill`, `stroke`, `stroke-width`,
## `fill-opacity`, `stroke-opacity`, `opacity`, `fill-rule`,
## `stroke-linecap`, `stroke-linejoin`, `transform`, `display`,
## `visibility`). Colors: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`,
## `rgb()`/`rgba()` (numbers or percents), a small named table, and
## `none`. Transforms: `translate`, `scale`, `rotate` (degrees,
## optional center), `skewX`/`skewY` (degrees), `matrix`.
## `preserveAspectRatio` honors `none`, otherwise uniform meet
## (always centered). Everything else — text, raster `image`, `use`,
## clipping, masks, filters, animation, external refs, stylesheets —
## is ignored, so documents using them render partially.
##
## Sizing: explicit output dimensions win; otherwise the root
## `width`/`height`, otherwise the `viewBox`. Malformed documents
## return nil (surface procs) or 0 (registry procs).

import std/math
import std/strutils
import std/xmlparser
import std/xmltree
import ./types
import ./transform
import ./canvas
import ./surface
import ./paint

export types

# --------------------------------------------------------------------------
# Small lexers
# --------------------------------------------------------------------------

proc parseNum(s: string, dflt: float64): float64 =
  ## Plain number with an optional `px` suffix, else `dflt`.
  var t = s.strip()
  if t.toLowerAscii().endsWith("px"):
    t = t[0 ..< t.len - 2].strip()
  try:
    result = parseFloat(t)
  except ValueError:
    return dflt
  if result.classify in {fcNan, fcInf, fcNegInf}:
    return dflt

proc parseLen(s: string, dflt: float64): tuple[v: float64, pct: bool] =
  ## Length that may also be a percent (`pct` true, `v` the fraction).
  let t = s.strip()
  if t.endsWith("%"):
    try:
      var v = parseFloat(t[0 ..< t.len - 1].strip()) / 100.0
      if v.classify in {fcNan, fcInf, fcNegInf}:
        return (dflt, false)
      return (v, true)
    except ValueError:
      return (dflt, false)
  (parseNum(t, dflt), false)

proc parseOpacity(s: string, dflt = 1.0): float64 =
  clamp01(parseLen(s, dflt)[0])

proc parsePoints(s: string): seq[float64] =
  ## Whitespace/comma separated number list (stops at the first
  ## unparseable token).
  result = @[]
  var cur = ""
  for ch in s:
    if ch in {' ', '\t', '\n', '\r', ','}:
      if cur.strip().len > 0:
        try:
          let v = parseFloat(cur.strip())
          if v.classify notin {fcNan, fcInf, fcNegInf}:
            result.add(v)
        except ValueError:
          discard
        cur = ""
    else:
      cur.add(ch)
  if cur.strip().len > 0:
    try:
      let v = parseFloat(cur.strip())
      if v.classify notin {fcNan, fcInf, fcNegInf}:
        result.add(v)
    except ValueError:
      discard

# --------------------------------------------------------------------------
# Colors
# --------------------------------------------------------------------------

const namedColors = [
  ("black", 0, 0, 0), ("white", 255, 255, 255),
  ("red", 255, 0, 0), ("green", 0, 128, 0), ("blue", 0, 0, 255),
  ("yellow", 255, 255, 0), ("cyan", 0, 255, 255),
  ("magenta", 255, 0, 255), ("orange", 255, 165, 0),
  ("purple", 128, 0, 128), ("pink", 255, 192, 203),
  ("brown", 165, 42, 42), ("gray", 128, 128, 128),
  ("grey", 128, 128, 128), ("lime", 0, 255, 0), ("navy", 0, 0, 128),
  ("teal", 0, 128, 128), ("aqua", 0, 255, 255),
  ("fuchsia", 255, 0, 255), ("silver", 192, 192, 192),
  ("maroon", 128, 0, 0), ("olive", 128, 128, 0)]

proc hexNibble(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  of 'A' .. 'F': ord(c) - ord('A') + 10
  else: -1

proc parseHexColor(t: string, ok: var bool): Color =
  ok = true
  let n = t.len - 1
  var v: array[8, int]
  if n notin [3, 4, 6, 8]:
    ok = false
    return rgbaf(0, 0, 0, 0)
  for i in 0 ..< n:
    v[i] = hexNibble(t[1 + i])
    if v[i] < 0:
      ok = false
      return rgbaf(0, 0, 0, 0)
  proc dup2(a, b: int): int = a * 16 + b
  case n
  of 3: rgb(uint8(dup2(v[0], v[0])), uint8(dup2(v[1], v[1])),
      uint8(dup2(v[2], v[2])))
  of 4: rgba(uint8(dup2(v[0], v[0])), uint8(dup2(v[1], v[1])),
      uint8(dup2(v[2], v[2])), uint8(dup2(v[3], v[3])))
  of 6: rgb(uint8(dup2(v[0], v[1])), uint8(dup2(v[2], v[3])),
      uint8(dup2(v[4], v[5])))
  else: rgba(uint8(dup2(v[0], v[1])), uint8(dup2(v[2], v[3])),
      uint8(dup2(v[4], v[5])), uint8(dup2(v[6], v[7])))

proc parseFuncColor(t: string, ok: var bool): Color =
  ## `rgb(...)` / `rgba(...)` with numbers or percents.
  ok = true
  let inner = t[t.find('(') + 1 ..< t.rfind(')')]
  let parts = inner.replace(",", " ").splitWhitespace()
  if parts.len notin [3, 4]:
    ok = false
    return rgbaf(0, 0, 0, 0)
  var ch: array[4, float64]
  for i in 0 ..< parts.len:
    let p = parts[i].strip()
    try:
      if p.endsWith("%"):
        ch[i] = clamp01(parseFloat(
          p[0 ..< p.len - 1].strip()) / 100.0)
      elif i < 3:
        ch[i] = clamp01(parseFloat(p) / 255.0)
      else:
        ch[i] = clamp01(parseFloat(p))
    except ValueError:
      ok = false
      return rgbaf(0, 0, 0, 0)
  let a = if parts.len == 4: ch[3] else: 1.0
  rgbaf(ch[0], ch[1], ch[2], a)

proc parseColor(s: string, ok: var bool): Color =
  ## CSS color without `none` (handled by callers). Falls back to
  ## opaque black with `ok` false.
  let t = s.strip().toLowerAscii()
  if t.len == 0:
    ok = false
    return rgbf(0, 0, 0)
  if t[0] == '#':
    return parseHexColor(t, ok)
  if t.startsWith("rgb"):
    if '(' in t and ')' in t:
      return parseFuncColor(t, ok)
    ok = false
    return rgbf(0, 0, 0)
  if t == "transparent":
    ok = true
    return rgbaf(0, 0, 0, 0)
  for (name, r, g, b) in namedColors:
    if t == name:
      ok = true
      return rgb(uint8(r), uint8(g), uint8(b))
  ok = false
  rgbf(0, 0, 0)

# --------------------------------------------------------------------------
# Transforms
# --------------------------------------------------------------------------

proc parseTransform(s: string): Xform =
  ## SVG `transform` attribute: functions apply left to right
  ## (`translate(10) scale(2)` moves then scales the local frame).
  ## Unknown functions are skipped. Angles are degrees.
  result = identity()
  var i = 0
  while i < s.len:
    while i < s.len and s[i] in {' ', '\t', '\n', '\r', ','}:
      inc i
    var name = ""
    while i < s.len and s[i] in {'a' .. 'z', 'A' .. 'Z'}:
      name.add(s[i])
      inc i
    while i < s.len and s[i] in {' ', '\t', '\n', '\r'}:
      inc i
    if i >= s.len or s[i] != '(':
      continue
    inc i
    var depth = 1
    let start = i
    while i < s.len and depth > 0:
      if s[i] == '(':
        inc depth
      elif s[i] == ')':
        dec depth
      inc i
    let args = parsePoints(s[start ..< i - 1])
    var m = identity()
    var valid = true
    case name
    of "translate":
      if args.len == 1:
        m = translate(args[0], 0.0)
      elif args.len >= 2:
        m = translate(args[0], args[1])
      else:
        valid = false
    of "scale":
      if args.len == 1:
        m = scale(args[0], args[0])
      elif args.len >= 2:
        m = scale(args[0], args[1])
      else:
        valid = false
    of "rotate":
      if args.len == 1:
        m = rotate(degToRad(args[0]))
      elif args.len >= 3:
        m = multiply(translate(args[1], args[2]),
          multiply(rotate(degToRad(args[0])),
            translate(-args[1], -args[2])))
      else:
        valid = false
    of "skewX":
      if args.len >= 1:
        m = skewX(degToRad(args[0]))
      else:
        valid = false
    of "skewY":
      if args.len >= 1:
        m = skewY(degToRad(args[0]))
      else:
        valid = false
    of "matrix":
      if args.len >= 6:
        m = [args[0], args[1], args[2], args[3], args[4], args[5]]
      else:
        valid = false
    else:
      valid = false
    if valid:
      result = multiply(result, m)

# --------------------------------------------------------------------------
# Path data
# --------------------------------------------------------------------------

type PathLexer = object
  s: string
  pos: int

proc skipSep(t: var PathLexer, stopAtDot = false) =
  while t.pos < t.s.len:
    let ch = t.s[t.pos]
    if ch in {' ', '\t', '\n', '\r', ','}:
      inc t.pos
    else:
      break

proc peekCmd(t: PathLexer): char =
  var i = t.pos
  while i < t.s.len and t.s[i] in {' ', '\t', '\n', '\r', ','}:
    inc i
  if i < t.s.len and
      t.s[i] in {'A' .. 'Z', 'a' .. 'z'} and t.s[i] != 'e' and
      t.s[i] != 'E':
    t.s[i]
  else:
    '\0'

proc readNum(t: var PathLexer, ok: var bool): float64 =
  t.skipSep()
  let start = t.pos
  if t.pos < t.s.len and t.s[t.pos] in {'+', '-'}:
    inc t.pos
  var intDigits = 0
  while t.pos < t.s.len and t.s[t.pos] in {'0' .. '9'}:
    inc t.pos
    inc intDigits
  var fracDigits = 0
  if t.pos < t.s.len and t.s[t.pos] == '.':
    inc t.pos
    while t.pos < t.s.len and t.s[t.pos] in {'0' .. '9'}:
      inc t.pos
      inc fracDigits
  if intDigits == 0 and fracDigits == 0:
    ok = false
    return 0.0
  if t.pos < t.s.len and t.s[t.pos] in {'e', 'E'}:
    var j = t.pos + 1
    if j < t.s.len and t.s[j] in {'+', '-'}:
      inc j
    var ed = 0
    while j < t.s.len and t.s[j] in {'0' .. '9'}:
      inc j
      inc ed
    if ed > 0:
      t.pos = j
  try:
    result = parseFloat(t.s[start ..< t.pos])
  except ValueError:
    ok = false
    return 0.0
  if result.classify in {fcNan, fcInf, fcNegInf}:
    ok = false
    return 0.0
  ok = true

type BBox = object
  x0*, y0*, x1*, y1*: float64
  empty*: bool

proc upd(b: var BBox, x, y: float64) =
  if b.empty:
    b.x0 = x
    b.y0 = y
    b.x1 = x
    b.y1 = y
    b.empty = false
  else:
    b.x0 = min(b.x0, x)
    b.y0 = min(b.y0, y)
    b.x1 = max(b.x1, x)
    b.y1 = max(b.y1, y)

proc drawPathData(c: Canvas, d: string): BBox =
  ## Emit `d` into the current canvas path (absolute user coords),
  ## tracking the control-point bounding box. Arcs are skipped
  ## (their parameters are consumed); unknown commands stop parsing.
  result = BBox(empty: true)
  var t = PathLexer(s: d, pos: 0)
  var cx, cy = 0.0
  var sx, sy = 0.0
  var c2x, c2y = 0.0
  var qx, qy = 0.0
  var prev = '\0'
  var cmd = '\0'
  var ok = true
  t.skipSep()
  if t.peekCmd() == '\0':
    return
  while true:
    t.skipSep()
    if t.pos >= t.s.len:
      break
    let p = t.peekCmd()
    if p != '\0':
      t.pos.inc()
      cmd = p
      if cmd in {'M', 'm'}:
        prev = '\0'
    elif cmd == '\0':
      break
    case cmd
    of 'M', 'm':
      let x = t.readNum(ok)
      if not ok:
        break
      let y = t.readNum(ok)
      if not ok:
        break
      if cmd == 'm':
        cx += x
        cy += y
      else:
        cx = x
        cy = y
      c.moveTo(cx, cy)
      result.upd(cx, cy)
      sx = cx
      sy = cy
      prev = '\0'
      cmd = if cmd == 'm': 'l' else: 'L'
    of 'L', 'l':
      let x = t.readNum(ok)
      if not ok:
        break
      let y = t.readNum(ok)
      if not ok:
        break
      if cmd == 'l':
        cx += x
        cy += y
      else:
        cx = x
        cy = y
      c.lineTo(cx, cy)
      result.upd(cx, cy)
      prev = '\0'
    of 'H', 'h':
      let x = t.readNum(ok)
      if not ok:
        break
      cx = if cmd == 'h': cx + x else: x
      c.lineTo(cx, cy)
      result.upd(cx, cy)
      prev = '\0'
    of 'V', 'v':
      let y = t.readNum(ok)
      if not ok:
        break
      cy = if cmd == 'v': cy + y else: y
      c.lineTo(cx, cy)
      result.upd(cx, cy)
      prev = '\0'
    of 'C', 'c':
      var a: array[6, float64]
      var good = true
      for k in 0 ..< 6:
        a[k] = t.readNum(ok)
        if not ok:
          good = false
          break
      if not good:
        break
      var x1, y1, x2, y2, x, y: float64
      if cmd == 'c':
        x1 = cx + a[0]
        y1 = cy + a[1]
        x2 = cx + a[2]
        y2 = cy + a[3]
        x = cx + a[4]
        y = cy + a[5]
      else:
        x1 = a[0]
        y1 = a[1]
        x2 = a[2]
        y2 = a[3]
        x = a[4]
        y = a[5]
      c.bezierTo(x1, y1, x2, y2, x, y)
      result.upd(x1, y1)
      result.upd(x2, y2)
      result.upd(x, y)
      c2x = x2
      c2y = y2
      cx = x
      cy = y
      prev = 'C'
    of 'S', 's':
      var a: array[4, float64]
      var good = true
      for k in 0 ..< 4:
        a[k] = t.readNum(ok)
        if not ok:
          good = false
          break
      if not good:
        break
      var x1, y1: float64
      if prev in {'C', 'S'}:
        x1 = 2.0 * cx - c2x
        y1 = 2.0 * cy - c2y
      else:
        x1 = cx
        y1 = cy
      var x2, y2, x, y: float64
      if cmd == 's':
        x2 = cx + a[0]
        y2 = cy + a[1]
        x = cx + a[2]
        y = cy + a[3]
      else:
        x2 = a[0]
        y2 = a[1]
        x = a[2]
        y = a[3]
      c.bezierTo(x1, y1, x2, y2, x, y)
      result.upd(x1, y1)
      result.upd(x2, y2)
      result.upd(x, y)
      c2x = x2
      c2y = y2
      cx = x
      cy = y
      prev = 'S'
    of 'Q', 'q':
      var a: array[4, float64]
      var good = true
      for k in 0 ..< 4:
        a[k] = t.readNum(ok)
        if not ok:
          good = false
          break
      if not good:
        break
      var qcx, qcy, x, y: float64
      if cmd == 'q':
        qcx = cx + a[0]
        qcy = cy + a[1]
        x = cx + a[2]
        y = cy + a[3]
      else:
        qcx = a[0]
        qcy = a[1]
        x = a[2]
        y = a[3]
      c.quadTo(qcx, qcy, x, y)
      result.upd(qcx, qcy)
      result.upd(x, y)
      qx = qcx
      qy = qcy
      cx = x
      cy = y
      prev = 'Q'
    of 'T', 't':
      let x = t.readNum(ok)
      if not ok:
        break
      let y = t.readNum(ok)
      if not ok:
        break
      var qcx, qcy: float64
      if prev in {'Q', 'T'}:
        qcx = 2.0 * cx - qx
        qcy = 2.0 * cy - qy
      else:
        qcx = cx
        qcy = cy
      var ex, ey: float64
      if cmd == 't':
        ex = cx + x
        ey = cy + y
      else:
        ex = x
        ey = y
      c.quadTo(qcx, qcy, ex, ey)
      result.upd(qcx, qcy)
      result.upd(ex, ey)
      qx = qcx
      qy = qcy
      cx = ex
      cy = ey
      prev = 'T'
    of 'A', 'a':
      # Arcs are unsupported: consume the 7 parameters per set.
      var good = true
      while true:
        for k in 0 ..< 7:
          discard t.readNum(ok)
          if not ok:
            good = false
            break
        if not good:
          break
        t.skipSep()
        if t.peekCmd() != '\0' or t.pos >= t.s.len:
          break
        # Another implicit set follows only if a number follows.
        var j = t.pos
        while j < t.s.len and t.s[j] in {' ', '\t', '\n', '\r', ','}:
          inc j
        if j < t.s.len and (t.s[j] in {'0' .. '9', '+', '-', '.'}):
          continue
        break
      if not good:
        break
      prev = '\0'
      # Current point is unknown after a skipped arc; keep it so a
      # following relative command stays anchored.
    of 'Z', 'z':
      c.closePath()
      cx = sx
      cy = sy
      prev = '\0'
    else:
      break

# --------------------------------------------------------------------------
# Document model
# --------------------------------------------------------------------------

proc localName(tag: string): string =
  let i = tag.rfind(':')
  if i >= 0:
    tag[i + 1 .. ^1]
  else:
    tag

proc attr(node: XmlNode, name: string): string =
  if node == nil:
    return ""
  result = xmltree.attr(node, name)
  if result == "" and name == "href":
    result = xmltree.attr(node, "xlink:href")

proc findById(node: XmlNode, id: string): XmlNode =
  if node == nil or id == "":
    return nil
  if node.kind == xnElement and attr(node, "id") == id:
    return node
  for child in node:
    let f = findById(child, id)
    if f != nil:
      return f

type
  PaintKindRef = enum
    prNone
    prColor
    prUrl

  PaintRef = object
    kind: PaintKindRef
    color: Color
    url: string

  SvgStyle = object
    fill: PaintRef
    fillOpacity: float64
    stroke: PaintRef
    strokeOpacity: float64
    strokeWidth: float64
    opacity: float64
    fillRule: FillRule
    cap: LineCap
    join: LineJoin

proc defaultStyle(): SvgStyle =
  SvgStyle(fill: PaintRef(kind: prColor, color: rgbf(0, 0, 0)),
    fillOpacity: 1.0, stroke: PaintRef(kind: prNone),
    strokeOpacity: 1.0, strokeWidth: 1.0, opacity: 1.0,
    fillRule: frNonZero, cap: lcButt, join: ljMiter)

proc parsePaintRef(s: string): PaintRef =
  let t = s.strip()
  if t == "" or t.toLowerAscii() == "none":
    return PaintRef(kind: prNone)
  if t.toLowerAscii().startsWith("url(") and t.endsWith(")"):
    var inner = t[4 ..< t.len - 1].strip()
    if inner.startsWith("#"):
      inner = inner[1 .. ^1]
    elif (inner.startsWith("\"#") or inner.startsWith("'#")) and
        inner.len > 3:
      inner = inner[2 ..< inner.len - 1]
    else:
      return PaintRef(kind: prNone)
    if inner == "":
      return PaintRef(kind: prNone)
    return PaintRef(kind: prUrl, url: inner)
  var ok = true
  let c = parseColor(t, ok)
  if not ok:
    # Invalid colors use the lacuna value (black for fill, none for
    # stroke); the caller picks per property.
    return PaintRef(kind: prColor, color: rgbf(0, 0, 0))
  PaintRef(kind: prColor, color: c)

proc applyStyleAttrs(st: var SvgStyle, node: XmlNode) =
  let f = attr(node, "fill")
  if f != "":
    st.fill = parsePaintRef(f)
    if st.fill.kind == prColor and not f.strip().toLowerAscii().startsWith(
        "url("):
      var ok = true
      discard parseColor(f, ok)
      if not ok:
        st.fill = PaintRef(kind: prColor, color: rgbf(0, 0, 0))
  let s = attr(node, "stroke")
  if s != "":
    st.stroke = parsePaintRef(s)
    if st.stroke.kind == prColor:
      var ok = true
      discard parseColor(s, ok)
      if not ok:
        # Lacuna for stroke is none.
        st.stroke = PaintRef(kind: prNone)
  let fo = attr(node, "fill-opacity")
  if fo != "":
    st.fillOpacity = parseOpacity(fo)
  let so = attr(node, "stroke-opacity")
  if so != "":
    st.strokeOpacity = parseOpacity(so)
  let sw = attr(node, "stroke-width")
  if sw != "":
    st.strokeWidth = max(0.0, parseNum(sw, st.strokeWidth))
  let op = attr(node, "opacity")
  if op != "":
    st.opacity = parseOpacity(op)
  let fr = attr(node, "fill-rule").strip().toLowerAscii()
  if fr == "evenodd":
    st.fillRule = frEvenOdd
  elif fr == "nonzero":
    st.fillRule = frNonZero
  let lc = attr(node, "stroke-linecap").strip().toLowerAscii()
  if lc == "round":
    st.cap = lcRound
  elif lc == "square":
    st.cap = lcSquare
  elif lc == "butt":
    st.cap = lcButt
  let lj = attr(node, "stroke-linejoin").strip().toLowerAscii()
  if lj == "round":
    st.join = ljRound
  elif lj == "bevel":
    st.join = ljBevel
  elif lj == "miter":
    st.join = ljMiter

# --------------------------------------------------------------------------
# Gradients
# --------------------------------------------------------------------------

proc collectStops(grad: XmlNode): seq[GradientStop] =
  result = @[]
  for child in grad:
    if child.kind != xnElement:
      continue
    if localName(child.tag) != "stop":
      continue
    let off = child.attr("offset").strip()
    var pos = 0.0
    if off.endsWith("%"):
      try:
        pos = parseFloat(off[0 ..< off.len - 1].strip()) / 100.0
      except ValueError:
        continue
    else:
      try:
        pos = parseFloat(off)
      except ValueError:
        continue
    if pos.classify in {fcNan, fcInf, fcNegInf}:
      continue
    pos = clamp(pos, 0.0, 1.0)
    var ok = true
    var col = parseColor(child.attr("stop-color"), ok)
    if not ok:
      col = rgbf(0, 0, 0)
    let so = child.attr("stop-opacity")
    let sa = if so == "": 1.0 else: parseOpacity(so)
    result.add(GradientStop(pos: pos, color: col.withAlpha(
      clamp01(col.a * sa))))

proc resolvePaint(c: Canvas, root: XmlNode, r: PaintRef, pam: float64,
    bbox: BBox): tuple[ok: bool, p: Paint] =
  ## `pam` is the property alpha multiplier (fill-/stroke-opacity).
  case r.kind
  of prNone:
    (false, solidPaint(rgbf(0, 0, 0)))
  of prColor:
    (true, solidPaint(r.color.withAlpha(clamp01(r.color.a * pam))))
  of prUrl:
    let g = findById(root, r.url)
    if g == nil or g.kind != xnElement:
      return (false, solidPaint(rgbf(0, 0, 0)))
    let gt = localName(g.tag)
    if gt != "linearGradient" and gt != "radialGradient":
      return (false, solidPaint(rgbf(0, 0, 0)))
    let stops = collectStops(g)
    if stops.len == 0:
      return (false, solidPaint(rgbf(0, 0, 0)))
    var units = g.attr("gradientUnits").strip()
    if units == "":
      units = "objectBoundingBox"
    let gt2 = parseTransform(g.attr("gradientTransform"))
    if units == "userSpaceOnUse":
      if gt == "linearGradient":
        var x1 = parseNum(g.attr("x1"), 0.0)
        var y1 = parseNum(g.attr("y1"), 0.0)
        var x2 = parseNum(g.attr("x2"), 1.0)
        var y2 = parseNum(g.attr("y2"), 0.0)
        var p1 = gt2.apply(x1, y1)
        var p2 = gt2.apply(x2, y2)
        x1 = p1.x
        y1 = p1.y
        x2 = p2.x
        y2 = p2.y
        var st = stops
        for i in 0 ..< st.len:
          st[i].color = st[i].color.withAlpha(
            clamp01(st[i].color.a * pam))
        (true, c.linearGradientStops(x1, y1, x2, y2, st))
      else:
        var cx = parseNum(g.attr("cx"), 0.5)
        var cy = parseNum(g.attr("cy"), 0.5)
        var r = max(0.0, parseNum(g.attr("r"), 0.5))
        var pc = gt2.apply(cx, cy)
        cx = pc.x
        cy = pc.y
        r *= averageScale(gt2)
        var st = stops
        for i in 0 ..< st.len:
          st[i].color = st[i].color.withAlpha(
            clamp01(st[i].color.a * pam))
        (true, c.radialGradientStops(cx, cy, 0.0, r, st))
    else:
      if bbox.empty:
        return (false, solidPaint(rgbf(0, 0, 0)))
      let bw = max(0.0, bbox.x1 - bbox.x0)
      let bh = max(0.0, bbox.y1 - bbox.y0)
      proc fx(v: float64): float64 = bbox.x0 + v * bw
      proc fy(v: float64): float64 = bbox.y0 + v * bh
      if gt == "linearGradient":
        let (qx1, px1) = parseLen(g.attr("x1"), 0.0)
        let (qy1, py1) = parseLen(g.attr("y1"), 0.0)
        let (qx2, px2) = parseLen(g.attr("x2"), 1.0)
        let (qy2, py2) = parseLen(g.attr("y2"), 0.0)
        var p1 = gt2.apply(fx(qx1), fy(qy1))
        var p2 = gt2.apply(fx(qx2), fy(qy2))
        discard px1
        discard py1
        discard px2
        discard py2
        var st = stops
        for i in 0 ..< st.len:
          st[i].color = st[i].color.withAlpha(
            clamp01(st[i].color.a * pam))
        (true, c.linearGradientStops(p1.x, p1.y, p2.x, p2.y, st))
      else:
        let (qcx, pcx) = parseLen(g.attr("cx"), 0.5)
        let (qcy, pcy) = parseLen(g.attr("cy"), 0.5)
        let (qr, pr) = parseLen(g.attr("r"), 0.5)
        discard pcx
        discard pcy
        discard pr
        let pc = gt2.apply(fx(qcx), fy(qcy))
        let rr = max(0.0, qr) * 0.5 * (bw + bh) * averageScale(gt2)
        var st = stops
        for i in 0 ..< st.len:
          st[i].color = st[i].color.withAlpha(
            clamp01(st[i].color.a * pam))
        (true, c.radialGradientStops(pc.x, pc.y, 0.0, rr, st))

# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------

proc emitShape(c: Canvas, node: XmlNode): tuple[ok: bool, bbox: BBox] =
  ## `beginPath` + emit one drawable element, tracking the bbox.
  ## Unknown shapes report `ok` false (caller skips the element).
  result = (false, BBox(empty: true))
  let tag = localName(node.tag)
  var bb = BBox(empty: true)
  c.beginPath()
  case tag
  of "rect":
    let x = parseNum(attr(node, "x"), 0.0)
    let y = parseNum(attr(node, "y"), 0.0)
    let w = parseNum(attr(node, "width"), 0.0)
    let h = parseNum(attr(node, "height"), 0.0)
    if w <= 0.0 or h <= 0.0:
      return
    let rx = parseNum(attr(node, "rx"), 0.0)
    let ry = parseNum(attr(node, "ry"), 0.0)
    var r = 0.0
    if rx > 0.0 or ry > 0.0:
      let ex = if rx > 0.0: rx else: ry
      let ey = if ry > 0.0: ry else: rx
      r = min(min(ex, ey), min(w, h) * 0.5)
    if r > 0.0:
      c.roundedRect(x, y, w, h, r)
    else:
      c.rect(x, y, w, h)
    bb.upd(x, y)
    bb.upd(x + w, y + h)
  of "circle":
    let cx = parseNum(attr(node, "cx"), 0.0)
    let cy = parseNum(attr(node, "cy"), 0.0)
    let r = parseNum(attr(node, "r"), 0.0)
    if r <= 0.0:
      return
    c.circle(cx, cy, r)
    bb.upd(cx - r, cy - r)
    bb.upd(cx + r, cy + r)
  of "ellipse":
    let cx = parseNum(attr(node, "cx"), 0.0)
    let cy = parseNum(attr(node, "cy"), 0.0)
    let rx = parseNum(attr(node, "rx"), 0.0)
    let ry = parseNum(attr(node, "ry"), 0.0)
    if rx <= 0.0 or ry <= 0.0:
      return
    c.ellipse(cx, cy, rx, ry)
    bb.upd(cx - rx, cy - ry)
    bb.upd(cx + rx, cy + ry)
  of "line":
    let x1 = parseNum(attr(node, "x1"), 0.0)
    let y1 = parseNum(attr(node, "y1"), 0.0)
    let x2 = parseNum(attr(node, "x2"), 0.0)
    let y2 = parseNum(attr(node, "y2"), 0.0)
    c.moveTo(x1, y1)
    c.lineTo(x2, y2)
    bb.upd(x1, y1)
    bb.upd(x2, y2)
  of "polyline", "polygon":
    let nums = parsePoints(attr(node, "points"))
    if nums.len < 4:
      return
    c.moveTo(nums[0], nums[1])
    bb.upd(nums[0], nums[1])
    var i = 2
    while i + 1 < nums.len:
      c.lineTo(nums[i], nums[i + 1])
      bb.upd(nums[i], nums[i + 1])
      i += 2
    if tag == "polygon":
      c.closePath()
  of "path":
    bb = c.drawPathData(attr(node, "d"))
  else:
    return
  result = (true, bb)

# --------------------------------------------------------------------------
# Tree walk
# --------------------------------------------------------------------------

proc renderKids(c: Canvas, root, node: XmlNode, st: SvgStyle,
    alpha: float64)

proc renderSvgKids(c: Canvas, root, node: XmlNode, st: SvgStyle,
    alpha: float64)

proc renderElement(c: Canvas, root, node: XmlNode, parent: SvgStyle,
    parentAlpha: float64) =
  if node.kind != xnElement:
    return
  let tag = localName(node.tag)
  if tag == "defs" or tag == "linearGradient" or
      tag == "radialGradient" or tag == "title" or tag == "desc" or
      tag == "metadata" or tag == "style":
    return
  var st = parent
  applyStyleAttrs(st, node)
  if attr(node, "display").strip().toLowerAscii() == "none":
    return
  let vis = attr(node, "visibility").strip().toLowerAscii()
  if vis == "hidden" or vis == "collapse":
    return
  let alpha = parentAlpha * clamp01(st.opacity)
  let hasXf = attr(node, "transform").strip() != ""
  if hasXf:
    c.save()
    c.applyTransform(parseTransform(attr(node, "transform")))
  c.setGlobalAlpha(alpha)
  if tag == "g" or tag == "a":
    renderKids(c, root, node, st, alpha)
  elif tag == "svg":
    renderSvgKids(c, root, node, st, alpha)
  elif tag == "rect" or tag == "circle" or tag == "ellipse" or
      tag == "line" or tag == "polyline" or tag == "polygon" or
      tag == "path":
    let (ok, bb) = emitShape(c, node)
    if ok:
      if st.fill.kind != prNone:
        let (fok, fp) = resolvePaint(c, root, st.fill,
          st.fillOpacity, bb)
        if fok:
          c.setFillPaint(fp)
          c.fillWithRule(st.fillRule)
      if st.stroke.kind != prNone and st.strokeWidth > 0.0:
        let (sok, sp) = resolvePaint(c, root, st.stroke,
          st.strokeOpacity, bb)
        if sok:
          c.setStrokePaint(sp)
          c.setStrokeWidth(st.strokeWidth)
          c.setLineCap(st.cap)
          c.setLineJoin(st.join)
          c.stroke()
  else:
    # Unsupported elements (text, raster image, use, clip paths,
    # masks, filters, ...) render nothing, but containers still
    # recurse so nested supported shapes survive.
    renderKids(c, root, node, st, alpha)
  if hasXf:
    c.restore()
  else:
    # Restore the inherited alpha without touching the transform.
    c.setGlobalAlpha(parentAlpha)

proc renderKids(c: Canvas, root, node: XmlNode, st: SvgStyle,
    alpha: float64) =
  for child in node:
    renderElement(c, root, child, st, alpha)

# --------------------------------------------------------------------------
# Viewport mapping
# --------------------------------------------------------------------------

proc parseViewBox(s: string): tuple[ok: bool, x, y, w, h: float64] =
  let nums = parsePoints(s)
  if nums.len != 4 or nums[2] <= 0.0 or nums[3] <= 0.0:
    return (false, 0.0, 0.0, 0.0, 0.0)
  (true, nums[0], nums[1], nums[2], nums[3])

proc applyViewport(c: Canvas, node: XmlNode, vw, vh: float64) =
  ## Map the node's `viewBox` onto a `vw` by `vh` box at the current
  ## origin: uniform meet (centered) by default, stretched on
  ## `preserveAspectRatio="none"`.
  let (ok, vbx, vby, vbw, vbh) = parseViewBox(attr(node, "viewBox"))
  if not ok:
    return
  let par = attr(node, "preserveAspectRatio").strip()
  if par.toLowerAscii().startsWith("none"):
    c.translate(-vbx, -vby)
    c.scale(vw / vbw, vh / vbh)
  else:
    let s = min(vw / vbw, vh / vbh)
    let ox = (vw - vbw * s) * 0.5
    let oy = (vh - vbh * s) * 0.5
    c.translate(-vbx, -vby)
    c.scale(s, s)
    c.translate(ox, oy)

proc renderSvgKids(c: Canvas, root, node: XmlNode, st: SvgStyle,
    alpha: float64) =
  ## Nested `svg`: x/y offset plus optional viewport mapping.
  let (_, wPct) = parseLen(attr(node, "width"), -1.0)
  let (_, hPct) = parseLen(attr(node, "height"), -1.0)
  discard wPct
  discard hPct
  let hasBox = attr(node, "viewBox").strip() != ""
  let x = parseNum(attr(node, "x"), 0.0)
  let y = parseNum(attr(node, "y"), 0.0)
  if not hasBox:
    var nst = st
    if x != 0.0 or y != 0.0:
      c.save()
      c.translate(x, y)
      renderKids(c, root, node, nst, alpha)
      c.restore()
    else:
      renderKids(c, root, node, nst, alpha)
    return
  let w = parseNum(attr(node, "width"), -1.0)
  let h = parseNum(attr(node, "height"), -1.0)
  if w <= 0.0 or h <= 0.0:
    return
  c.save()
  c.translate(x, y)
  c.applyViewport(node, w, h)
  renderKids(c, root, node, st, alpha)
  c.restore()

# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

proc svgSize*(data: string): tuple[w, h: float64, ok: bool] =
  ## Intrinsic size: root `width`/`height`, else the `viewBox`.
  ## Percentages and missing values fall back to the `viewBox`.
  try:
    let root = parseXml(data)
    if root == nil or root.kind != xnElement or
        localName(root.tag) != "svg":
      return (0.0, 0.0, false)
    let (ws, wp) = parseLen(attr(root, "width"), -1.0)
    let (hs, hp) = parseLen(attr(root, "height"), -1.0)
    if not wp and not hp and ws > 0.0 and hs > 0.0:
      return (ws, hs, true)
    let (ok, _, _, vbw, vbh) = parseViewBox(attr(root, "viewBox"))
    if ok:
      return (vbw, vbh, true)
    (0.0, 0.0, false)
  except CatchableError:
    (0.0, 0.0, false)

proc renderSvg*(data: string, w = 0.0, h = 0.0): Surface =
  ## Render an SVG document to a transparent `Surface` (nil on
  ## malformed input or unknowable size). Explicit `w`/`h` win;
  ## one-sided sizes keep the intrinsic aspect; otherwise the
  ## intrinsic size is used.
  var root: XmlNode
  try:
    root = parseXml(data)
  except CatchableError:
    return nil
  if root == nil or root.kind != xnElement or
      localName(root.tag) != "svg":
    return nil
  let (iw, ih, iok) = svgSize(data)
  var ow = w
  var oh = h
  if ow <= 0.0 or oh <= 0.0:
    if not iok:
      return nil
    if ow <= 0.0 and oh <= 0.0:
      ow = iw
      oh = ih
    elif ow <= 0.0:
      ow = oh * iw / ih
    else:
      oh = ow * ih / iw
  if ow <= 0.0 or oh <= 0.0:
    return nil
  let c = newCanvas(max(1, int(ow + 0.5)), max(1, int(oh + 0.5)))
  let (ws, wp) = parseLen(attr(root, "width"), -1.0)
  let (hs, hp) = parseLen(attr(root, "height"), -1.0)
  discard ws
  discard hs
  discard wp
  discard hp
  c.applyViewport(root, ow, oh)
  let st = defaultStyle()
  renderKids(c, root, root, st, 1.0)
  c.surf

proc renderSvgFile*(file: string, w = 0.0, h = 0.0): Surface =
  ## Like `renderSvg` but reads `file` first (nil when missing).
  try:
    return renderSvg(cast[string](readFile(file)), w, h)
  except CatchableError:
    return nil

proc createImageSvg*(c: Canvas, data: string, w, h: int,
    flags: set[ImageFlag]): int =
  ## Render SVG bytes at `w` by `h` into the image registry (0 on
  ## malformed input or non-positive sizes). Same handle semantics
  ## as `createImageMem`.
  if w <= 0 or h <= 0:
    return 0
  let s = renderSvg(data, float64(w), float64(h))
  if s == nil:
    return 0
  c.createImageRGBA(s.w, s.h, flags, s.pixels)

proc createImageSvgFile*(c: Canvas, file: string, w, h: int,
    flags: set[ImageFlag]): int =
  ## Like `createImageSvg` but reads `file` first.
  if w <= 0 or h <= 0:
    return 0
  let s = renderSvgFile(file, float64(w), float64(h))
  if s == nil:
    return 0
  c.createImageRGBA(s.w, s.h, flags, s.pixels)