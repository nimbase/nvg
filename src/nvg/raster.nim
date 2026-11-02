## CPU rasterizer: scanline span-fill with analytic edge handling.
##
## Fills use an even-odd scanline pass: per row, edge crossings at the
## pixel-center line delimit spans; pixels strictly inside a span with no
## edge passing through them take coverage 1.0 directly, while only edge
## pixels pay for 4x4 supersampling. Output is identical to brute-force
## full-grid supersampling (interior pixels measured 16/16 there), at a
## fraction of the cost on large fills. Paint sampling stays
## per-pixel-center (gradients vary slowly relative to geometry). Stroke
## expansion ports NanoVG's `nvg__calculateJoins` / `nvg__expandStroke`
## idea (miter with limit, bevel fallback, round fan, butt/square/round
## caps) but emits outline polygons consumed by the same even-odd
## filler, so no GPU stencil is needed. This module IS the v1 backend;
## `backend.nim` wraps it behind the pluggable seam for a future GPU
## renderer.

import std/algorithm
import std/math
import ./types
import ./path
import ./paint
import ./surface
import ./jit

export types

const
  SampleGrid* = 4
  SamplesPerPixel* = SampleGrid * SampleGrid

type
  Edge* = tuple[x0, y0, x1, y1: float64]
    ## One directed polygon edge in device space.

proc buildEdges*(polys: seq[SubPoly]): seq[Edge] =
  ## Flatten sub-polygons to a directed edge list, dropping degenerate
  ## zero-length edges.
  for s in polys:
    let n = s.pts.len
    if n < 2: continue
    let m = if s.closed: n else: n - 1
    for i in 0 ..< m:
      let a = s.pts[i]
      let b = s.pts[(i + 1) mod n]
      if a.x != b.x or a.y != b.y:
        result.add((a.x, a.y, b.x, b.y))

proc windingOfEdges*(x, y: float64, edges: openArray[Edge]): int =
  ## Signed winding number of `(x, y)` for a +x ray. Uses the same
  ## half-open y rule as the even-odd test (`y` in `[min, max)`), so the
  ## two rules agree on boundary handling; only the accumulation differs
  ## (toggle vs signed sum). Upward edges (`y1 > y0`) add +1, downward
  ## edges add -1.
  for e in edges:
    if ((e.y0 > y) != (e.y1 > y)):
      let xint = (e.x1 - e.x0) * (y - e.y0) / (e.y1 - e.y0) + e.x0
      if x < xint:
        result += (if e.y1 > e.y0: 1 else: -1)

proc pointInEdges*(x, y: float64, edges: openArray[Edge],
    rule = frEvenOdd): bool =
  ## Ray-cast (+x direction) containment over an edge list. Even-odd
  ## toggles per crossing; nonzero tests the signed winding number.
  if rule == frNonZero:
    return windingOfEdges(x, y, edges) != 0
  var inside = false
  for e in edges:
    if ((e.y0 > y) != (e.y1 > y)):
      let xint = (e.x1 - e.x0) * (y - e.y0) / (e.y1 - e.y0) + e.x0
      if x < xint:
        inside = not inside
  inside

proc pointInEvenOdd*(x, y: float64, polys: seq[SubPoly]): bool =
  ## Ray-cast (+x direction) even-odd containment over all sub-polygons.
  pointInEdges(x, y, buildEdges(polys))

proc pointInNonZero*(x, y: float64, polys: seq[SubPoly]): bool =
  ## Nonzero-winding containment over all sub-polygons.
  pointInEdges(x, y, buildEdges(polys), frNonZero)

proc coverageEdges*(x, y: float64, edges: openArray[Edge],
    rule = frEvenOdd): float64 =
  ## 4x4 subsample coverage of pixel `(x, y)` (pixel covers
  ## `[x, x+1) x [y, y+1)`) under `rule`.
  var hit = 0
  for gy in 0 ..< SampleGrid:
    for gx in 0 ..< SampleGrid:
      let sx = float64(x) + (float64(gx) + 0.5) / float64(SampleGrid)
      let sy = float64(y) + (float64(gy) + 0.5) / float64(SampleGrid)
      if pointInEdges(sx, sy, edges, rule):
        inc hit
  float64(hit) / float64(SamplesPerPixel)

proc coverageAt*(x, y: float64, polys: seq[SubPoly],
    rule = frEvenOdd): float64 =
  ## 4x4 subsample coverage of pixel `(x, y)` (pixel covers
  ## `[x, x+1) x [y, y+1)`) under `rule`.
  coverageEdges(x, y, buildEdges(polys), rule)

proc fillBounds*(polys: seq[SubPoly], surf: Surface,
    clip: Clip): tuple[x0, y0, x1, y1: int, ok: bool] =
  ## Device-space fill bounds shared by the scalar and JIT fill paths.
  let (bx0, by0, bx1, by1) = flattenBounds(polys)
  var x0 = max(0, int(floor(bx0)) - 1)
  var y0 = max(0, int(floor(by0)) - 1)
  var x1 = min(surf.w - 1, int(ceil(bx1)) + 1)
  var y1 = min(surf.h - 1, int(ceil(by1)) + 1)
  if clip.enabled:
    x0 = max(x0, int(floor(clip.x0)))
    y0 = max(y0, int(floor(clip.y0)))
    x1 = min(x1, int(ceil(clip.x1)) - 1)
    y1 = min(y1, int(ceil(clip.y1)) - 1)
  (x0, y0, x1, y1, not (x1 < x0 or y1 < y0))

proc scanRowSpans*(edges: openArray[Edge], x0, x1, y: int,
    edgeMark: var openArray[bool], xs: var seq[tuple[x: float64, dir: int]],
    spans: var seq[tuple[a, b: float64]], rule = frEvenOdd) =
  ## Per-row span scan shared by the scalar and JIT fill paths: marks
  ## pixels overlapped by any edge's x-range and pairs up center-line
  ## crossings into spans. Even-odd pairs sorted crossings `(0,1),(2,3)`;
  ## nonzero sweeps the signed winding (`dir` is +1 for upward edges,
  ## -1 for downward) and emits intervals where it is nonzero. Reuses
  ## the caller's buffers. `xs` carries `(x, dir)` so one pass serves
  ## both rules; even-odd ignores `dir`.
  let yTop = float64(y)
  let yBot = yTop + 1.0
  let Y = yTop + 0.5
  for i in 0 ..< edgeMark.len: edgeMark[i] = false
  xs.setLen(0)
  spans.setLen(0)
  for e in edges:
    let ey0 = min(e.y0, e.y1)
    let ey1 = max(e.y0, e.y1)
    if ey1 < yTop or ey0 > yBot: continue
    # An edge touching this row band can only affect the pixels its
    # x-range overlaps; mark exactly those as edge pixels. Pixels on
    # a span boundary are always marked (the crossing lies inside
    # them), so unmarked pixels in range are strictly interior.
    let mx0 = max(int(floor(min(e.x0, e.x1))), x0)
    let mx1 = min(int(floor(max(e.x0, e.x1))), x1)
    for mx in mx0 .. mx1:
      edgeMark[mx - x0] = true
    if abs(e.y1 - e.y0) < 1e-12: continue # horizontal: no crossing
    if ((e.y0 > Y) != (e.y1 > Y)):
      let xint = e.x0 + (Y - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0)
      xs.add((xint, if e.y1 > e.y0: 1 else: -1))
  if xs.len >= 2:
    xs.sort(proc(a, b: tuple[x: float64, dir: int]): int = cmp(a.x, b.x))
    if rule == frNonZero:
      var w = 0
      for i in 0 ..< xs.len - 1:
        w += xs[i].dir
        if w != 0:
          spans.add((xs[i].x, xs[i + 1].x))
    else:
      var k = 0
      while k + 1 < xs.len:
        spans.add((xs[k].x, xs[k + 1].x))
        k += 2

proc fillPolys*(surf: Surface, polys: seq[SubPoly], paint: Paint,
    alpha: float64, clip: Clip, aa = true, op = coSourceOver,
    rule = frEvenOdd) =
  if polys.len == 0: return
  let a = clamp01(alpha)
  if a <= 0.0: return
  let edges = buildEdges(polys)
  if edges.len == 0: return
  let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
  if not ok: return
  let rowW = x1 - x0 + 1
  var edgeMark = newSeq[bool](rowW)
  var xs: seq[tuple[x: float64, dir: int]] = @[]
  var spans: seq[tuple[a, b: float64]] = @[]
  for y in y0 .. y1:
    scanRowSpans(edges, x0, x1, y, edgeMark, xs, spans, rule)
    for x in x0 .. x1:
      let cx = float64(x) + 0.5
      var inside = false
      for sp in spans:
        if cx >= sp.a and cx <= sp.b:
          inside = true
          break
      let cov =
        if not aa:
          if inside: 1.0 else: 0.0
        elif edgeMark[x - x0]:
          coverageEdges(float64(x), float64(y), edges, rule)
        elif inside:
          1.0 # edge-free pixel agreeing with its center sample
        else:
          0.0
      if cov <= 0.0: continue
      let col = paint.sample(float64(x) + 0.5, float64(y) + 0.5)
      surf.blendPixel(x, y,
        color(col.r, col.g, col.b, col.a * a), cov, op)

proc fillSolidJit*(surf: Surface, polys: seq[SubPoly], src: Color,
    alpha: float64, clip: Clip, fn: SolidRowFn,
    covBuf: var seq[float64], aa = true, rule = frEvenOdd,
    op = coSourceOver) =
  ## Solid fill through an op-specialized JIT row kernel (`fn`, resolved by
  ## the caller from `JitKernels`). Span setup and coverage stay in Nim
  ## (identical values to `fillPolys`); only paint eval + blend run JIT.
  ## amd64 only: other arches must use `fillPolys` (the AArch64 kernel
  ## is assemble-verified but not execution-verified yet).
  if polys.len == 0 or surf.pixels.len == 0: return
  if clamp01(alpha) <= 0.0: return
  var ctx = bakeSolidCtx(src, alpha)
  if op == coSourceOver and ctx.sa <= 0.0: return
  let edges = buildEdges(polys)
  if edges.len == 0: return
  let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
  if not ok: return
  let rowW = x1 - x0 + 1
  if covBuf.len < rowW: covBuf.setLen(rowW)
  var edgeMark = newSeq[bool](rowW)
  var xs: seq[tuple[x: float64, dir: int]] = @[]
  var spans: seq[tuple[a, b: float64]] = @[]
  for y in y0 .. y1:
    scanRowSpans(edges, x0, x1, y, edgeMark, xs, spans, rule)
    # NB: no `spans.len == 0` skip here. Rows whose geometry misses
    # the center line can still own marked edge pixels with nonzero
    # orphan coverage (the scalar path paints them via the same
    # edgeMark branch); the `any` gate below skips truly empty rows.
    var any = false
    for x in x0 .. x1:
      let cx = float64(x) + 0.5
      var inside = false
      for sp in spans:
        if cx >= sp.a and cx <= sp.b:
          inside = true
          break
      let cov =
        if not aa:
          if inside: 1.0 else: 0.0
        elif edgeMark[x - x0]:
          coverageEdges(float64(x), float64(y), edges, rule)
        elif inside:
          1.0
        else:
          0.0
      covBuf[x - x0] = cov
      if cov > 0.0: any = true
    if not any: continue
    # Sparse-row sub-ranges: one kernel call per maximal covered run
    # instead of the full row. Dense rows collapse to a single call
    # (identical to before); thin strokes skip the zero-coverage gaps
    # the scalar path never touches. Grouping is output-neutral: every
    # pixel evaluates identically either way.
    let rowBase = cast[int](addr surf.pixels[0]) +
      (y * surf.w + x0) * 4
    var rx = x0
    while rx <= x1:
      if covBuf[rx - x0] <= 0.0:
        inc rx
        continue
      var re = rx
      while re + 1 <= x1 and covBuf[re + 1 - x0] > 0.0:
        inc re
      let dst = cast[pointer](rowBase + (rx - x0) * 4)
      fn(dst, addr covBuf[rx - x0], int64(re - rx + 1), addr ctx)
      rx = re + 1

proc fillLinearJit*(surf: Surface, polys: seq[SubPoly], paint: Paint,
    alpha: float64, clip: Clip, fn: LinearRowFn,
    covBuf: var seq[float64], aa = true, rule = frEvenOdd,
    op = coSourceOver) =
  ## Linear-gradient fill through an op-specialized JIT row kernel. Span
  ## setup and coverage stay in Nim (identical to `fillPolys`); paint
  ## eval + blend run JIT. Per-row fields (`m2y`, `m3y`) are refreshed
  ## in Nim with the same multiplies as `map.apply`, and `rowX` per
  ## covered run, so the kernel's `(m0*x + m2y) + m4` matches the scalar
  ## bit-for-bit. Each covered run is one kernel call (see
  ## `fillSolidJit`).
  if polys.len == 0 or surf.pixels.len == 0: return
  if paint.kind != pkLinear: return
  if clamp01(alpha) <= 0.0: return
  var ctx = bakeLinearCtx(paint, alpha)
  if op == coSourceOver and ctx.linearSkippable(): return
  let edges = buildEdges(polys)
  if edges.len == 0: return
  let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
  if not ok: return
  let rowW = x1 - x0 + 1
  if covBuf.len < rowW: covBuf.setLen(rowW)
  var edgeMark = newSeq[bool](rowW)
  var xs: seq[tuple[x: float64, dir: int]] = @[]
  var spans: seq[tuple[a, b: float64]] = @[]
  for y in y0 .. y1:
    scanRowSpans(edges, x0, x1, y, edgeMark, xs, spans, rule)
    # Same orphan-row rule as `fillSolidJit`: no spans-skip, `any` gate.
    var any = false
    for x in x0 .. x1:
      let cx = float64(x) + 0.5
      var inside = false
      for sp in spans:
        if cx >= sp.a and cx <= sp.b:
          inside = true
          break
      let cov =
        if not aa:
          if inside: 1.0 else: 0.0
        elif edgeMark[x - x0]:
          coverageEdges(float64(x), float64(y), edges, rule)
        elif inside:
          1.0
        else:
          0.0
      covBuf[x - x0] = cov
      if cov > 0.0: any = true
    if not any: continue
    let rowY = float64(y) + 0.5
    ctx.m2y = paint.map[2] * rowY
    ctx.m3y = paint.map[3] * rowY
    let rowBase = cast[int](addr surf.pixels[0]) +
      (y * surf.w + x0) * 4
    var rx = x0
    while rx <= x1:
      if covBuf[rx - x0] <= 0.0:
        inc rx
        continue
      var re = rx
      while re + 1 <= x1 and covBuf[re + 1 - x0] > 0.0:
        inc re
      # `rowX` is exact per run start (`float64(rx)+0.5`), so each
      # pixel's `x` matches the scalar center bit-for-bit.
      ctx.rowX = float64(rx) + 0.5
      let dst = cast[pointer](rowBase + (rx - x0) * 4)
      fn(dst, addr covBuf[rx - x0], int64(re - rx + 1), addr ctx)
      rx = re + 1

proc fillRadialJit*(surf: Surface, polys: seq[SubPoly], paint: Paint,
    alpha: float64, clip: Clip, fn: RadialRowFn,
    covBuf: var seq[float64], aa = true, rule = frEvenOdd,
    op = coSourceOver) =
  ## Radial-gradient fill through an op-specialized JIT row kernel. Same
  ## structure as `fillLinearJit` (span/coverage in Nim, per-run `rowX`
  ## plus per-row `m2y`/`m3y`, one kernel call per covered run).
  if polys.len == 0 or surf.pixels.len == 0: return
  if paint.kind != pkRadial: return
  if clamp01(alpha) <= 0.0: return
  var ctx = bakeRadialCtx(paint, alpha)
  if op == coSourceOver and ctx.radialSkippable(): return
  let edges = buildEdges(polys)
  if edges.len == 0: return
  let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
  if not ok: return
  let rowW = x1 - x0 + 1
  if covBuf.len < rowW: covBuf.setLen(rowW)
  var edgeMark = newSeq[bool](rowW)
  var xs: seq[tuple[x: float64, dir: int]] = @[]
  var spans: seq[tuple[a, b: float64]] = @[]
  for y in y0 .. y1:
    scanRowSpans(edges, x0, x1, y, edgeMark, xs, spans, rule)
    # Same orphan-row rule as `fillSolidJit`: no spans-skip, `any` gate.
    var any = false
    for x in x0 .. x1:
      let cx = float64(x) + 0.5
      var inside = false
      for sp in spans:
        if cx >= sp.a and cx <= sp.b:
          inside = true
          break
      let cov =
        if not aa:
          if inside: 1.0 else: 0.0
        elif edgeMark[x - x0]:
          coverageEdges(float64(x), float64(y), edges, rule)
        elif inside:
          1.0
        else:
          0.0
      covBuf[x - x0] = cov
      if cov > 0.0: any = true
    if not any: continue
    let rowY = float64(y) + 0.5
    ctx.m2y = paint.map[2] * rowY
    ctx.m3y = paint.map[3] * rowY
    let rowBase = cast[int](addr surf.pixels[0]) +
      (y * surf.w + x0) * 4
    var rx = x0
    while rx <= x1:
      if covBuf[rx - x0] <= 0.0:
        inc rx
        continue
      var re = rx
      while re + 1 <= x1 and covBuf[re + 1 - x0] > 0.0:
        inc re
      ctx.rowX = float64(rx) + 0.5
      let dst = cast[pointer](rowBase + (rx - x0) * 4)
      fn(dst, addr covBuf[rx - x0], int64(re - rx + 1), addr ctx)
      rx = re + 1

proc fillBoxJit*(surf: Surface, polys: seq[SubPoly], paint: Paint,
    alpha: float64, clip: Clip, fn: BoxRowFn,
    covBuf: var seq[float64], aa = true, rule = frEvenOdd,
    op = coSourceOver) =
  ## Box-gradient fill through an op-specialized JIT row kernel. Same
  ## structure as `fillLinearJit` (span/coverage in Nim, per-run `rowX`
  ## plus per-row `m2y`/`m3y`, one kernel call per covered run).
  if polys.len == 0 or surf.pixels.len == 0: return
  if paint.kind != pkBox: return
  if clamp01(alpha) <= 0.0: return
  var ctx = bakeBoxCtx(paint, alpha)
  if op == coSourceOver and ctx.boxSkippable(): return
  let edges = buildEdges(polys)
  if edges.len == 0: return
  let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
  if not ok: return
  let rowW = x1 - x0 + 1
  if covBuf.len < rowW: covBuf.setLen(rowW)
  var edgeMark = newSeq[bool](rowW)
  var xs: seq[tuple[x: float64, dir: int]] = @[]
  var spans: seq[tuple[a, b: float64]] = @[]
  for y in y0 .. y1:
    scanRowSpans(edges, x0, x1, y, edgeMark, xs, spans, rule)
    # Same orphan-row rule as `fillSolidJit`: no spans-skip, `any` gate.
    var any = false
    for x in x0 .. x1:
      let cx = float64(x) + 0.5
      var inside = false
      for sp in spans:
        if cx >= sp.a and cx <= sp.b:
          inside = true
          break
      let cov =
        if not aa:
          if inside: 1.0 else: 0.0
        elif edgeMark[x - x0]:
          coverageEdges(float64(x), float64(y), edges, rule)
        elif inside:
          1.0
        else:
          0.0
      covBuf[x - x0] = cov
      if cov > 0.0: any = true
    if not any: continue
    let rowY = float64(y) + 0.5
    ctx.m2y = paint.map[2] * rowY
    ctx.m3y = paint.map[3] * rowY
    let rowBase = cast[int](addr surf.pixels[0]) +
      (y * surf.w + x0) * 4
    var rx = x0
    while rx <= x1:
      if covBuf[rx - x0] <= 0.0:
        inc rx
        continue
      var re = rx
      while re + 1 <= x1 and covBuf[re + 1 - x0] > 0.0:
        inc re
      ctx.rowX = float64(rx) + 0.5
      let dst = cast[pointer](rowBase + (rx - x0) * 4)
      fn(dst, addr covBuf[rx - x0], int64(re - rx + 1), addr ctx)
      rx = re + 1

proc fillPatternJit*(surf: Surface, polys: seq[SubPoly], paint: Paint,
    alpha: float64, clip: Clip, fn: PatternRowFn,
    covBuf: var seq[float64], aa = true, rule = frEvenOdd,
    op = coSourceOver) =
  ## Nearest-pattern fill through an op-specialized JIT row kernel. Same
  ## structure as `fillLinearJit` (span/coverage in Nim, per-run `rowX`
  ## plus per-row `m2y`/`m3y`, one kernel call per covered run).
  ## Bilinear patterns never reach here (caller gates on `ifNearest`).
  if polys.len == 0 or surf.pixels.len == 0: return
  if paint.kind != pkPattern: return
  if clamp01(alpha) <= 0.0: return
  if op == coSourceOver and patternSkippable(paint, alpha): return
  var ctx = bakePatternCtx(paint, alpha)
  let edges = buildEdges(polys)
  if edges.len == 0: return
  let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
  if not ok: return
  let rowW = x1 - x0 + 1
  if covBuf.len < rowW: covBuf.setLen(rowW)
  var edgeMark = newSeq[bool](rowW)
  var xs: seq[tuple[x: float64, dir: int]] = @[]
  var spans: seq[tuple[a, b: float64]] = @[]
  for y in y0 .. y1:
    scanRowSpans(edges, x0, x1, y, edgeMark, xs, spans, rule)
    # Same orphan-row rule as `fillSolidJit`: no spans-skip, `any` gate.
    var any = false
    for x in x0 .. x1:
      let cx = float64(x) + 0.5
      var inside = false
      for sp in spans:
        if cx >= sp.a and cx <= sp.b:
          inside = true
          break
      let cov =
        if not aa:
          if inside: 1.0 else: 0.0
        elif edgeMark[x - x0]:
          coverageEdges(float64(x), float64(y), edges, rule)
        elif inside:
          1.0
        else:
          0.0
      covBuf[x - x0] = cov
      if cov > 0.0: any = true
    if not any: continue
    let rowY = float64(y) + 0.5
    ctx.m2y = paint.map[2] * rowY
    ctx.m3y = paint.map[3] * rowY
    let rowBase = cast[int](addr surf.pixels[0]) +
      (y * surf.w + x0) * 4
    var rx = x0
    while rx <= x1:
      if covBuf[rx - x0] <= 0.0:
        inc rx
        continue
      var re = rx
      while re + 1 <= x1 and covBuf[re + 1 - x0] > 0.0:
        inc re
      ctx.rowX = float64(rx) + 0.5
      let dst = cast[pointer](rowBase + (rx - x0) * 4)
      fn(dst, addr covBuf[rx - x0], int64(re - rx + 1), addr ctx)
      rx = re + 1

# --- Stroke expansion ---

proc norm2(x, y: float64): tuple[x, y: float64, len: float64] =
  let l = sqrt(x*x + y*y)
  if l < 1e-12: (0.0, 0.0, 0.0)
  else: (x / l, y / l, l)

proc expandStroke*(polys: seq[SubPoly], width: float64, cap: LineCap,
    join: LineJoin, miterLimit: float64): seq[SubPoly] =
  ## Expand flattened polygons into stroke outline polygons.
  ## Ports `nvg__calculateJoins` + `nvg__expandStroke`: per-vertex turn
  ## tracking (NanoVG `LEFT` convention: `cross = d1.x*d0.y - d0.x*d1.y`),
  ## miter with limit, bevel fallback, round fans, butt/square/round
  ## caps. Closed loops emit outset/inset polygon pairs consumed by the
  ## even-odd filler, so no stencil buffer is needed.
  result = @[]
  if width <= 0.0: return
  let hw = width * 0.5
  const dedupSq = 1e-12
  proc addPt(loop: var seq[Pt], q: Pt) =
    if loop.len == 0:
      loop.add(q)
    else:
      let a = loop[^1]
      let dx = a.x - q.x
      let dy = a.y - q.y
      if dx*dx + dy*dy >= dedupSq:
        loop.add(q)
  proc roundFan(loop: var seq[Pt], c: Pt, a0, a1: float64) =
    let sweep = abs(a1 - a0)
    let k = max(2, int(ceil(sweep / (PI / 8.0))) + 1)
    for j in 0 ..< k:
      let t = if k <= 1: 0.0 else: float64(j) / float64(k - 1)
      addPt(loop, pt(c.x + cos(a0 + (a1 - a0) * t) * hw,
        c.y + sin(a0 + (a1 - a0) * t) * hw))
  for s in polys:
    let n = s.pts.len
    if n == 0: continue
    if n == 1:
      # Degenerate: round dot so zero-length subpaths leave a mark.
      let c = s.pts[0]
      var dot: seq[Pt] = @[]
      let segs = 12
      for i in 0 ..< segs:
        let a = 2.0 * PI * float64(i) / float64(segs)
        dot.add(pt(c.x + cos(a) * hw, c.y + sin(a) * hw))
      result.add(SubPoly(pts: dot, closed: true,
        corners: newSeq[bool](dot.len)))
      continue
    if s.closed and n >= 3:
      var outer: seq[Pt] = @[]  # +normal side loop
      var inner: seq[Pt] = @[]  # -normal side loop
      for i in 0 ..< n:
        let prev = s.pts[(i - 1 + n) mod n]
        let curr = s.pts[i]
        let next = s.pts[(i + 1) mod n]
        let corner = i < s.corners.len and s.corners[i]
        let d0 = norm2(curr.x - prev.x, curr.y - prev.y)
        let d1 = norm2(next.x - curr.x, next.y - curr.y)
        if d0.len < 1e-12 or d1.len < 1e-12: continue
        let n0 = (x: d0.y, y: -d0.x)
        let n1 = (x: d1.y, y: -d1.x)
        var dm = ((n0.x + n1.x) * 0.5, (n0.y + n1.y) * 0.5)
        let dmr2 = dm[0]*dm[0] + dm[1]*dm[1]
        if dmr2 > 1e-9:
          let scale = min(1.0 / dmr2, 600.0)
          dm = (dm[0] * scale, dm[1] * scale)
        let left = d1.x*d0.y - d0.x*d1.y > 0.0
        let miterOver = dmr2 * miterLimit * miterLimit < 1.0
        let innerLimit = max(1.01, min(d0.len, d1.len) / hw)
        let innerBevel = dmr2 * innerLimit * innerLimit < 1.0
        let bevelFlag = corner and (miterOver or join != ljMiter)
        let useRound = join == ljRound and (bevelFlag or innerBevel)
        if left:
          # Outside of the turn is the -normal side.
          if useRound:
            var a0 = arctan2(-n0.y, -n0.x)
            var a1 = arctan2(-n1.y, -n1.x)
            if a1 > a0: a1 -= 2.0 * PI
            roundFan(inner, curr, a0, a1)
          elif bevelFlag:
            addPt(inner, pt(curr.x - n0.x * hw, curr.y - n0.y * hw))
            addPt(inner, pt(curr.x - n1.x * hw, curr.y - n1.y * hw))
          else:
            addPt(inner, pt(curr.x - dm[0] * hw, curr.y - dm[1] * hw))
          if innerBevel:
            addPt(outer, pt(curr.x + n0.x * hw, curr.y + n0.y * hw))
            addPt(outer, pt(curr.x + n1.x * hw, curr.y + n1.y * hw))
          else:
            addPt(outer, pt(curr.x + dm[0] * hw, curr.y + dm[1] * hw))
        else:
          # Outside of the turn is the +normal side.
          if useRound:
            var a0 = arctan2(n0.y, n0.x)
            var a1 = arctan2(n1.y, n1.x)
            if a1 < a0: a1 += 2.0 * PI
            roundFan(outer, curr, a0, a1)
          elif bevelFlag:
            addPt(outer, pt(curr.x + n0.x * hw, curr.y + n0.y * hw))
            addPt(outer, pt(curr.x + n1.x * hw, curr.y + n1.y * hw))
          else:
            addPt(outer, pt(curr.x + dm[0] * hw, curr.y + dm[1] * hw))
          if innerBevel:
            addPt(inner, pt(curr.x - n0.x * hw, curr.y - n0.y * hw))
            addPt(inner, pt(curr.x - n1.x * hw, curr.y - n1.y * hw))
          else:
            addPt(inner, pt(curr.x - dm[0] * hw, curr.y - dm[1] * hw))
      if outer.len >= 3:
        result.add(SubPoly(pts: outer, closed: true,
          corners: newSeq[bool](outer.len)))
      if inner.len >= 3:
        result.add(SubPoly(pts: inner, closed: true,
          corners: newSeq[bool](inner.len)))
    else:
      # Open polyline: single outline loop (+normal side forward,
      # -normal side backward). Interior joins use the same LEFT rule
      # as closed loops; endpoints get caps below.
      var left: seq[Pt] = @[]
      var right: seq[Pt] = @[]
      # Segment normals.
      var norms: seq[tuple[x, y: float64]] = @[]
      for i in 0 ..< n - 1:
        let d = norm2(s.pts[i+1].x - s.pts[i].x,
          s.pts[i+1].y - s.pts[i].y)
        if d.len < 1e-12:
          norms.add((x: 0.0, y: 0.0))
        else:
          norms.add((x: d.y, y: -d.x))
      for i in 0 ..< n:
        if i == 0 or i == n - 1:
          let nn = if i == 0: norms[0] else: norms[^1]
          addPt(left, pt(s.pts[i].x + nn.x * hw, s.pts[i].y + nn.y * hw))
          addPt(right, pt(s.pts[i].x - nn.x * hw,
            s.pts[i].y - nn.y * hw))
        else:
          let corner = i < s.corners.len and s.corners[i]
          let n0 = norms[i-1]
          let n1 = norms[i]
          let d0 = norm2(s.pts[i].x - s.pts[i-1].x,
            s.pts[i].y - s.pts[i-1].y)
          let d1 = norm2(s.pts[i+1].x - s.pts[i].x,
            s.pts[i+1].y - s.pts[i].y)
          var dm = ((n0.x + n1.x) * 0.5, (n0.y + n1.y) * 0.5)
          let dmr2 = dm[0]*dm[0] + dm[1]*dm[1]
          if dmr2 > 1e-9:
            let scale = min(1.0 / dmr2, 600.0)
            dm = (dm[0] * scale, dm[1] * scale)
          let leftTurn = d1.x*d0.y - d0.x*d1.y > 0.0
          let miterOver = dmr2 * miterLimit * miterLimit < 1.0
          let innerLimit = max(1.01, min(d0.len, d1.len) / hw)
          let innerBevel = dmr2 * innerLimit * innerLimit < 1.0
          let bevelFlag = corner and (miterOver or join != ljMiter)
          let useRound = join == ljRound and (bevelFlag or innerBevel)
          if leftTurn:
            if useRound:
              var a0 = arctan2(-n0.y, -n0.x)
              var a1 = arctan2(-n1.y, -n1.x)
              if a1 > a0: a1 -= 2.0 * PI
              roundFan(right, s.pts[i], a0, a1)
            elif bevelFlag:
              addPt(right, pt(s.pts[i].x - n0.x * hw,
                s.pts[i].y - n0.y * hw))
              addPt(right, pt(s.pts[i].x - n1.x * hw,
                s.pts[i].y - n1.y * hw))
            else:
              addPt(right, pt(s.pts[i].x - dm[0] * hw,
                s.pts[i].y - dm[1] * hw))
            if innerBevel:
              addPt(left, pt(s.pts[i].x + n0.x * hw,
                s.pts[i].y + n0.y * hw))
              addPt(left, pt(s.pts[i].x + n1.x * hw,
                s.pts[i].y + n1.y * hw))
            else:
              addPt(left, pt(s.pts[i].x + dm[0] * hw,
                s.pts[i].y + dm[1] * hw))
          else:
            if useRound:
              var a0 = arctan2(n0.y, n0.x)
              var a1 = arctan2(n1.y, n1.x)
              if a1 < a0: a1 += 2.0 * PI
              roundFan(left, s.pts[i], a0, a1)
            elif bevelFlag:
              addPt(left, pt(s.pts[i].x + n0.x * hw,
                s.pts[i].y + n0.y * hw))
              addPt(left, pt(s.pts[i].x + n1.x * hw,
                s.pts[i].y + n1.y * hw))
            else:
              addPt(left, pt(s.pts[i].x + dm[0] * hw,
                s.pts[i].y + dm[1] * hw))
            if innerBevel:
              addPt(right, pt(s.pts[i].x - n0.x * hw,
                s.pts[i].y - n0.y * hw))
              addPt(right, pt(s.pts[i].x - n1.x * hw,
                s.pts[i].y - n1.y * hw))
            else:
              addPt(right, pt(s.pts[i].x - dm[0] * hw,
                s.pts[i].y - dm[1] * hw))
      var loop: seq[Pt] = @[]
      for q in left: addPt(loop, q)
      # Start cap.
      let d0 = norm2(s.pts[1].x - s.pts[0].x, s.pts[1].y - s.pts[0].y)
      let dn = norm2(s.pts[n-1].x - s.pts[n-2].x,
        s.pts[n-1].y - s.pts[n-2].y)
      case cap
      of lcButt:
        discard
      of lcSquare:
        # Extend endpoints outward by hw along the path direction.
        if loop.len > 0:
          loop[^1] = pt(loop[^1].x + dn.x * hw, loop[^1].y + dn.y * hw)
        # Right side gets the same extension after reversal below; handle
        # by extending the stored end/start points.
        right[^1] = pt(right[^1].x + dn.x * hw,
          right[^1].y + dn.y * hw)
        right[0] = pt(right[0].x - d0.x * hw, right[0].y - d0.y * hw)
        loop[0] = pt(loop[0].x - d0.x * hw, loop[0].y - d0.y * hw)
      of lcRound:
        var fan: seq[Pt] = @[]
        let e = s.pts[n-1]
        let a = arctan2(dn.y, dn.x)
        let k = 8
        for j in 1 ..< k:
          let t = a - PI*0.5 + PI * float64(j) / float64(k)
          fan.add(pt(e.x + cos(t) * hw, e.y + sin(t) * hw))
        for q in fan: addPt(loop, q)
      for i in countdown(right.len - 1, 0):
        addPt(loop, right[i])
      if cap == lcRound:
        var fan2: seq[Pt] = @[]
        let e = s.pts[0]
        let a = arctan2(d0.y, d0.x)
        let k = 8
        for j in 1 ..< k:
          let t = a + PI*0.5 + PI * float64(j) / float64(k)
          fan2.add(pt(e.x + cos(t) * hw, e.y + sin(t) * hw))
        for q in fan2: addPt(loop, q)
      if loop.len >= 3:
        result.add(SubPoly(pts: loop, closed: true,
          corners: newSeq[bool](loop.len)))

proc strokePolys*(surf: Surface, polys: seq[SubPoly], paint: Paint,
    width: float64, cap: LineCap, join: LineJoin, miterLimit: float64,
    alpha: float64, clip: Clip, aa = true, op = coSourceOver) =
  let expanded = expandStroke(polys, width, cap, join, miterLimit)
  fillPolys(surf, expanded, paint, alpha, clip, aa, op)
