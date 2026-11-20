## Text outline capture with SVG and JSON export.
##
## `captureOutlines` converts a laid-out `TextLayout` (plain, span or
## box layout) into a single `Path` plus per-color command ranges, so
## callers can fill, stroke, serialize or inspect text as vector
## geometry without painting. Glyph ink uses the nonzero fill rule.
## Path boxes are replayed at their placed offset; image boxes (no
## vector form) contribute their placed rect; decorations append as
## rect rules. Clipping (`toClip`) is paint-only and never captured.

import std/json
import std/strutils
import ./types
import ./transform
import ./path
import ./text

type
  OutlineGroup* = object
    ## One paint group: a contiguous command range in `path.commands`
    ## sharing a color. `hasColor` false means the layout paint (the
    ## group holds uncolored glyphs/boxes/decor).
    color*: Color
    hasColor*: bool
    first*, last*: int

  TextOutlines* = object
    ## Captured text geometry: combined `path`, per-color `groups`
    ## partitioning it, the layout `advance` and `anchor`, and the
    ## user-space ink `bounds` (from the captured geometry, so box and
    ## decor extras are included).
    path*: Path
    groups*: seq[OutlineGroup]
    advance*: float64
    x*, y*: float64
    bounds*: Rect

proc pathBounds*(cmds: openArray[Command]): tuple[found: bool,
    x0, y0, x1, y1: float64] =
  ## Conservative ink box over command points (control points
  ## included, so curves never exceed it). Empty when no points.
  result.found = false
  template eat(px, py: float64) =
    if not result.found:
      result.x0 = px
      result.y0 = py
      result.x1 = px
      result.y1 = py
      result.found = true
    else:
      result.x0 = min(result.x0, px)
      result.y0 = min(result.y0, py)
      result.x1 = max(result.x1, px)
      result.y1 = max(result.y1, py)
  for cmd in cmds:
    case cmd.kind
    of pcMoveTo, pcLineTo:
      eat(cmd.p.x, cmd.p.y)
    of pcCubicTo:
      eat(cmd.c1.x, cmd.c1.y)
      eat(cmd.c2.x, cmd.c2.y)
      eat(cmd.p2.x, cmd.p2.y)
    of pcClose, pcWinding:
      discard

proc captureOutlines*(lay: TextLayout, x, y: float64,
    ha = thaLeft, va = tvaBaseline, xf = identity(),
    decor = tdNone): TextOutlines =
  ## Capture `lay` at anchor `(x, y)` under `xf` (user space, like
  ## paint). Box-positioned layouts pass `thaLeft`/`tvaBaseline` with
  ## the box shift already added to `y`, mirroring `paintBox`.
  ## Decor rules (box layouts) append first so the uncolored group
  ## owns them. Groups follow paint order: uncolored, then colors in
  ## first-seen order.
  result = TextOutlines(path: Path(), x: x, y: y)
  if decor != tdNone:
    result.path.appendDeco(xf, lay, x, y, decor)
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
  template emitGroup(wantColor: bool, col: Color) =
    let first = result.path.commands.len
    result.path.appendLayoutSpan(xf, lay, x, y, ha, va, wantColor, col)
    result.path.appendBoxes(xf, lay, x, y, ha, va, wantColor, col)
    let last = result.path.commands.len
    if last > first:
      result.groups.add(OutlineGroup(color: col, hasColor: wantColor,
        first: first, last: last))
  # The uncolored group starts at 0 so it owns any leading decor verbs.
  result.path.appendLayoutSpan(xf, lay, x, y, ha, va, false,
    rgbf(0, 0, 0))
  result.path.appendBoxes(xf, lay, x, y, ha, va, false,
    rgbf(0, 0, 0))
  if result.path.commands.len > 0:
    result.groups.add(OutlineGroup(hasColor: false,
      first: 0, last: result.path.commands.len))
  for col in cols:
    emitGroup(true, col)
  var adv = 0.0
  for line in lay.lines:
    adv = max(adv, line.advance)
  result.advance = adv
  if result.path.commands.len > 0:
    let b = pathBounds(result.path.commands)
    if b.found:
      result.bounds = rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0)
    else:
      result.bounds = rect(x, y, 0, 0)
  else:
    result.bounds = rect(x, y, 0, 0)

proc commandsSvgData*(cmds: openArray[Command]): string =
  ## Path verbs as SVG path-data (`M/L/C/Z`, windings skipped).
  ## Coordinates use shortest round-trip floats.
  var parts: seq[string] = @[]
  for cmd in cmds:
    case cmd.kind
    of pcMoveTo:
      parts.add("M " & $cmd.p.x & " " & $cmd.p.y)
    of pcLineTo:
      parts.add("L " & $cmd.p.x & " " & $cmd.p.y)
    of pcCubicTo:
      parts.add("C " & $cmd.c1.x & " " & $cmd.c1.y & " " &
        $cmd.c2.x & " " & $cmd.c2.y & " " & $cmd.p2.x & " " &
        $cmd.p2.y)
    of pcClose:
      parts.add("Z")
    of pcWinding:
      discard
  parts.join(" ")

proc pathSvgData*(p: Path): string =
  ## `commandsSvgData` over a whole path.
  commandsSvgData(p.commands)

proc colorCss*(c: Color): string =
  ## `rgba(r, g, b, a)` with 0-255 channels and shortest alpha.
  "rgba(" & $int(c.r * 255.0 + 0.5) & ", " &
    $int(c.g * 255.0 + 0.5) & ", " & $int(c.b * 255.0 + 0.5) &
    ", " & $c.a & ")"

proc outlinesSvg*(o: TextOutlines): string =
  ## Full standalone SVG document: viewBox covers the captured ink
  ## bounds, one `<path>` per group with `fill-rule="nonzero"`
  ## (per-element, so the rule survives SVG import too). Uncolored
  ## groups carry no `fill` (SVG default black); colored groups carry
  ## their `rgba()` fill.
  let b = o.bounds
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" &
    $b.x & " " & $b.y & " " & $b.w & " " & $b.h & "\">"
  for g in o.groups:
    let d = commandsSvgData(o.path.commands.toOpenArray(g.first,
      g.last - 1))
    if d.len == 0:
      continue
    if g.hasColor:
      result.add("<path d=\"" & d & "\" fill=\"" & colorCss(g.color) &
        "\" fill-rule=\"nonzero\"/>")
    else:
      result.add("<path d=\"" & d & "\" fill-rule=\"nonzero\"/>")
  result.add("</svg>")

proc commandJson*(cmd: Command): JsonNode =
  ## One verb as JSON (`M/L` carry `x`,`y`; `C` carries both
  ## controls plus the endpoint; `Z` is bare). Windings are skipped
  ## by the caller.
  case cmd.kind
  of pcMoveTo:
    %*{"op": "M", "x": cmd.p.x, "y": cmd.p.y}
  of pcLineTo:
    %*{"op": "L", "x": cmd.p.x, "y": cmd.p.y}
  of pcCubicTo:
    %*{"op": "C", "c1x": cmd.c1.x, "c1y": cmd.c1.y,
      "c2x": cmd.c2.x, "c2y": cmd.c2.y, "x": cmd.p2.x, "y": cmd.p2.y}
  of pcClose:
    %*{"op": "Z"}
  of pcWinding:
    newJNull()

proc outlinesJson*(o: TextOutlines): JsonNode =
  ## Full envelope: anchor, advance, user-space bounds, fill rule and
  ## per-group colors (null for the uncolored group) with verb lists.
  var groups = newJArray()
  for g in o.groups:
    var verbs = newJArray()
    for i in g.first ..< g.last:
      let cmd = o.path.commands[i]
      if cmd.kind == pcWinding:
        continue
      verbs.add(commandJson(cmd))
    var col: JsonNode
    if g.hasColor:
      col = %*[g.color.r, g.color.g, g.color.b, g.color.a]
    else:
      col = newJNull()
    groups.add(%*{"color": col, "path": verbs})
  %*{"x": o.x, "y": o.y, "advance": o.advance,
    "bounds": {"x": o.bounds.x, "y": o.bounds.y,
      "w": o.bounds.w, "h": o.bounds.h},
    "fillRule": "nonzero", "groups": groups}
