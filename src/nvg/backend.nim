## Pluggable render backend seam.
##
## V1 ships only `CpuBackend` (the supersampled scanline rasterizer in
## `raster.nim`). A future GPU renderer implements the same `fill`/`stroke`
## signatures on a new `Backend` subtype so `canvas.nim` does not change.

import std/math
import ./types
import ./transform
import ./path
import ./paint
import ./surface
import ./raster
when defined(nvgJit):
  import ./jit
when defined(nvgMetal):
  import ./metal

export types
when defined(nvgJit):
  export jit

type
  Backend* = ref object of RootObj

  CpuBackend* = ref object of Backend

when defined(nvgJit):
  type
    JitBackend* = ref object of Backend
      ## CPU backend with op-specialized JIT row kernels (`jit.nim`) for
      ## solid, linear-, radial-, box-gradient (2-stop and multi-stop)
      ## and nearest/bilinear-pattern fills and strokes; everything else
      ## falls back to the scalar rasterizer, so output is identical to
      ## `CpuBackend`. Multi-stop and bilinear kernels are amd64-only
      ## for now (AArch64 runs those paints through the scalar
      ## fallback). Opt-in via `newCanvas(w, h, newJitBackend())`;
      ## call `destroyJitBackend` when done (mappings are also released
      ## by GC).
      kern*: JitKernels
      covJit*: seq[float64]

proc newCpuBackend*(): CpuBackend = CpuBackend()

when defined(nvgMetal):
  type MetalBackend* = ref object of Backend
    ## GPU backend (compute path): geometry and coverage stay on the
    ## CPU using the exact scalar code (`buildEdges`, `scanRowSpans`,
    ## `coverageEdges`), so antialiasing matches by construction; paint
    ## evaluation and compositing run in MSL over a shared buffer.
    ## Basic paints shade on the GPU under any `CompOp`; multi-stop
    ## shades on the GPU for source-over only; longer, mapped, or
    ## degenerate paints fall back to the scalar rasterizer, so output
    ## stays identical to `CpuBackend`. Opt-in via
    ## `newCanvas(w, h, newMetalBackend(w, h))`; call `close` when done.
    ctx*: MetalCtx
    covBuf*: seq[float32]

  proc newMetalBackend*(w, h: int): MetalBackend =
    MetalBackend(ctx: newMetalCtx(w, h),
      covBuf: newSeq[float32](w * h))

  proc close*(b: MetalBackend) =
    b.ctx.close()

  proc shadeFill(b: MetalBackend, surf: Surface, polys: seq[SubPoly],
      paint: Paint, alpha: float64, clip: Clip, aa: bool,
      rule: FillRule, op: CompOp) =
    ## Scalar `fillPolys` early-outs and coverage loop, GPU shade for
    ## identity-map basic paints under any op; multi-stop shades on GPU
    ## for source-over only, and mapped, degenerate, or over-long
    ## paints fall back to scalar.
    if polys.len == 0: return
    let a = clamp01(alpha)
    if a <= 0.0: return
    if b.ctx.w != surf.w or b.ctx.h != surf.h or
        b.covBuf.len != surf.w * surf.h:
      fillPolys(surf, polys, paint, alpha, clip, aa, op, rule)
      return
    var kind = -1
    var w: array[16, cfloat]
    var multiKind = -1
    var mg0, mg1, mg2: array[2, float64]
    var mstops: seq[GradientStop] = @[]
    if paint.map == identity():
      case paint.kind
      of pkSolid:
        kind = ShadeSolid
        w[0] = cfloat(paint.solid.r)
        w[1] = cfloat(paint.solid.g)
        w[2] = cfloat(paint.solid.b)
        w[3] = cfloat(paint.solid.a)
      of pkLinear:
        if isBasicTwoStop(paint.linear.stops):
          let g = paint.linear
          kind = ShadeLinear
          w[0] = cfloat(g.sx)
          w[1] = cfloat(g.sy)
          w[2] = cfloat(g.ex)
          w[3] = cfloat(g.ey)
          w[4] = cfloat(g.icol.r)
          w[5] = cfloat(g.icol.g)
          w[6] = cfloat(g.icol.b)
          w[7] = cfloat(g.icol.a)
          w[8] = cfloat(g.ocol.r)
          w[9] = cfloat(g.ocol.g)
          w[10] = cfloat(g.ocol.b)
          w[11] = cfloat(g.ocol.a)
        elif paint.linear.stops.len <= MaxShadeStops:
          let g = paint.linear
          multiKind = ShadeLinear
          mg0 = [g.sx, g.sy]
          mg1 = [g.ex, g.ey]
          mstops = paint.linear.stops
      of pkRadial:
        if isBasicTwoStop(paint.radial.stops):
          let g = paint.radial
          kind = ShadeRadial
          w[0] = cfloat(g.cx)
          w[1] = cfloat(g.cy)
          w[2] = cfloat(g.inr)
          w[3] = cfloat(g.outr)
          w[4] = cfloat(g.icol.r)
          w[5] = cfloat(g.icol.g)
          w[6] = cfloat(g.icol.b)
          w[7] = cfloat(g.icol.a)
          w[8] = cfloat(g.ocol.r)
          w[9] = cfloat(g.ocol.g)
          w[10] = cfloat(g.ocol.b)
          w[11] = cfloat(g.ocol.a)
        elif paint.radial.stops.len <= MaxShadeStops:
          let g = paint.radial
          multiKind = ShadeRadial
          mg0 = [g.cx, g.cy]
          mg1 = [g.inr, g.outr]
          mstops = paint.radial.stops
      of pkBox:
        if isBasicTwoStop(paint.box.stops):
          let g = paint.box
          kind = ShadeBox
          w[0] = cfloat(g.cx)
          w[1] = cfloat(g.cy)
          w[2] = cfloat(g.ex)
          w[3] = cfloat(g.ey)
          w[4] = cfloat(g.radius)
          w[5] = cfloat(g.feather)
          w[8] = cfloat(g.icol.r)
          w[9] = cfloat(g.icol.g)
          w[10] = cfloat(g.icol.b)
          w[11] = cfloat(g.icol.a)
          w[12] = cfloat(g.ocol.r)
          w[13] = cfloat(g.ocol.g)
          w[14] = cfloat(g.ocol.b)
          w[15] = cfloat(g.ocol.a)
        elif paint.box.stops.len <= MaxShadeStops:
          let g = paint.box
          multiKind = ShadeBox
          mg0 = [g.cx, g.cy]
          mg1 = [g.ex, g.ey]
          mg2 = [g.radius, g.feather]
          mstops = paint.box.stops
      of pkPattern:
        let pt = paint.pattern
        if pt.img != nil and abs(pt.ex) >= 1e-12 and
            abs(pt.ey) >= 1e-12:
          b.ctx.setPattern(pt.img)
          kind = ShadePattern
          var flags = 0.0
          if ifRepeatX in pt.img.flags: flags += 1.0
          if ifRepeatY in pt.img.flags: flags += 2.0
          if ifFlipY in pt.img.flags: flags += 4.0
          if ifNearest notin pt.img.flags: flags += 8.0
          w[0] = cfloat(pt.ox)
          w[1] = cfloat(pt.oy)
          w[2] = cfloat(pt.ex)
          w[3] = cfloat(pt.ey)
          w[4] = cfloat(pt.tint.r)
          w[5] = cfloat(pt.tint.g)
          w[6] = cfloat(pt.tint.b)
          w[7] = cfloat(pt.tint.a)
          w[8] = cfloat(pt.angle)
          w[12] = cfloat(pt.img.w)
          w[13] = cfloat(pt.img.h)
          w[14] = cfloat(flags)
    if kind < 0 and (multiKind < 0 or op != coSourceOver):
      fillPolys(surf, polys, paint, alpha, clip, aa, op, rule)
      return
    let edges = buildEdges(polys)
    if edges.len == 0: return
    let (x0, y0, x1, y1, ok) = fillBounds(polys, surf, clip)
    if not ok: return
    for i in 0 ..< b.covBuf.len: b.covBuf[i] = 0
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
            1.0
          else:
            0.0
        if cov > 0.0:
          b.covBuf[y * surf.w + x] = float32(cov)
    b.ctx.upload(surf.pixels)
    b.ctx.uploadAux(b.covBuf)
    if kind >= 0:
      b.ctx.shadeOver(kind, op, a, w)
    else:
      b.ctx.shadeMulti(multiKind, a, mg0, mg1, mg2, mstops)
    surf.pixels = b.ctx.readback()

when defined(nvgJit):
  proc newJitBackend*(): JitBackend =
    JitBackend(kern: JitKernels(), covJit: @[])

  proc destroyJitBackend*(b: JitBackend) =
    ## Release executable mappings. Idempotent.
    b.kern.destroy()

method fill*(b: Backend, surf: Surface, polys: seq[SubPoly],
    paint: Paint, alpha: float64, clip: Clip,
    aa = true, op = coSourceOver, rule = frEvenOdd) {.base.} =
  raise newException(CatchableError, "Backend.fill not implemented")

method stroke*(b: Backend, surf: Surface, polys: seq[SubPoly],
    paint: Paint, width: float64, cap: LineCap, join: LineJoin,
    miterLimit: float64, alpha: float64, clip: Clip,
    aa = true, op = coSourceOver) {.base.} =
  raise newException(CatchableError, "Backend.stroke not implemented")

method fill*(b: CpuBackend, surf: Surface, polys: seq[SubPoly],
    paint: Paint, alpha: float64, clip: Clip, aa = true,
    op = coSourceOver, rule = frEvenOdd) =
  fillPolys(surf, polys, paint, alpha, clip, aa, op, rule)

method stroke*(b: CpuBackend, surf: Surface, polys: seq[SubPoly],
    paint: Paint, width: float64, cap: LineCap, join: LineJoin,
    miterLimit: float64, alpha: float64, clip: Clip, aa = true,
    op = coSourceOver) =
  strokePolys(surf, polys, paint, width, cap, join, miterLimit, alpha,
    clip, aa, op)

when defined(nvgJit):
  method fill*(b: JitBackend, surf: Surface, polys: seq[SubPoly],
      paint: Paint, alpha: float64, clip: Clip, aa = true,
      op = coSourceOver, rule = frEvenOdd) =
    ## Stroke expansion stays even-odd always (`expandStroke` emits paired
    ## outer/inner loops for the even-odd filler; winding would need
    ## guaranteed opposite orientations and still mis-fills
    ## self-intersections), so only `fill` takes a rule; `stroke` below
    ## keeps the default. Kernels are op-specialized (`get*(op)`); the
    ## scalar fallback covers non-runnable patterns, multi-stop and
    ## bilinear paints on AArch64, and hosts with no JIT builders.
    when defined(amd64) or defined(arm64) or defined(aarch64):
      case paint.kind
      of pkSolid:
        let fn = b.kern.getSolid(op)
        if fn != nil:
          fillSolidJit(surf, polys, paint.solid, alpha, clip, fn,
            b.covJit, aa, rule, op)
          return
      of pkLinear:
        if isBasicTwoStop(paint.linear.stops):
          let fn = b.kern.getLinear(op)
          if fn != nil:
            fillLinearJit(surf, polys, paint, alpha, clip, fn,
              b.covJit, aa, rule, op)
            return
        else:
          let fn = b.kern.getMultiLinear(op)
          if fn != nil:
            fillMultiLinearJit(surf, polys, paint, alpha, clip, fn,
              b.covJit, aa, rule, op)
            return
      of pkRadial:
        if isBasicTwoStop(paint.radial.stops):
          let fn = b.kern.getRadial(op)
          if fn != nil:
            fillRadialJit(surf, polys, paint, alpha, clip, fn,
              b.covJit, aa, rule, op)
            return
        else:
          let fn = b.kern.getMultiRadial(op)
          if fn != nil:
            fillMultiRadialJit(surf, polys, paint, alpha, clip, fn,
              b.covJit, aa, rule, op)
            return
      of pkBox:
        if isBasicTwoStop(paint.box.stops):
          let fn = b.kern.getBox(op)
          if fn != nil:
            fillBoxJit(surf, polys, paint, alpha, clip, fn,
              b.covJit, aa, rule, op)
            return
        else:
          let fn = b.kern.getMultiBox(op)
          if fn != nil:
            fillMultiBoxJit(surf, polys, paint, alpha, clip, fn,
              b.covJit, aa, rule, op)
            return
      of pkPattern:
        if patternRunnable(paint):
          if paint.pattern.img != nil and
              ifNearest in paint.pattern.img.flags:
            let fn = b.kern.getPattern(op)
            if fn != nil:
              fillPatternJit(surf, polys, paint, alpha, clip, fn,
                b.covJit, aa, rule, op)
              return
          else:
            let fn = b.kern.getPatternBilinear(op)
            if fn != nil:
              fillPatternBilinearJit(surf, polys, paint, alpha, clip,
                fn, b.covJit, aa, rule, op)
              return
    fillPolys(surf, polys, paint, alpha, clip, aa, op, rule)

  method stroke*(b: JitBackend, surf: Surface, polys: seq[SubPoly],
      paint: Paint, width: float64, cap: LineCap, join: LineJoin,
      miterLimit: float64, alpha: float64, clip: Clip,
      aa = true, op = coSourceOver) =
    when defined(amd64) or defined(arm64) or defined(aarch64):
      case paint.kind
      of pkSolid:
        let fn = b.kern.getSolid(op)
        if fn != nil:
          let expanded = expandStroke(polys, width, cap, join, miterLimit)
          fillSolidJit(surf, expanded, paint.solid, alpha, clip, fn,
            b.covJit, aa, frEvenOdd, op)
          return
      of pkLinear:
        if isBasicTwoStop(paint.linear.stops):
          let fn = b.kern.getLinear(op)
          if fn != nil:
            let expanded = expandStroke(polys, width, cap, join, miterLimit)
            fillLinearJit(surf, expanded, paint, alpha, clip, fn,
              b.covJit, aa, frEvenOdd, op)
            return
        else:
          let fn = b.kern.getMultiLinear(op)
          if fn != nil:
            let expanded = expandStroke(polys, width, cap, join, miterLimit)
            fillMultiLinearJit(surf, expanded, paint, alpha, clip, fn,
              b.covJit, aa, frEvenOdd, op)
            return
      of pkRadial:
        if isBasicTwoStop(paint.radial.stops):
          let fn = b.kern.getRadial(op)
          if fn != nil:
            let expanded = expandStroke(polys, width, cap, join, miterLimit)
            fillRadialJit(surf, expanded, paint, alpha, clip, fn,
              b.covJit, aa, frEvenOdd, op)
            return
        else:
          let fn = b.kern.getMultiRadial(op)
          if fn != nil:
            let expanded = expandStroke(polys, width, cap, join, miterLimit)
            fillMultiRadialJit(surf, expanded, paint, alpha, clip, fn,
              b.covJit, aa, frEvenOdd, op)
            return
      of pkBox:
        if isBasicTwoStop(paint.box.stops):
          let fn = b.kern.getBox(op)
          if fn != nil:
            let expanded = expandStroke(polys, width, cap, join, miterLimit)
            fillBoxJit(surf, expanded, paint, alpha, clip, fn,
              b.covJit, aa, frEvenOdd, op)
            return
        else:
          let fn = b.kern.getMultiBox(op)
          if fn != nil:
            let expanded = expandStroke(polys, width, cap, join, miterLimit)
            fillMultiBoxJit(surf, expanded, paint, alpha, clip, fn,
              b.covJit, aa, frEvenOdd, op)
            return
      of pkPattern:
        if patternRunnable(paint):
          if paint.pattern.img != nil and
              ifNearest in paint.pattern.img.flags:
            let fn = b.kern.getPattern(op)
            if fn != nil:
              let expanded = expandStroke(polys, width, cap, join, miterLimit)
              fillPatternJit(surf, expanded, paint, alpha, clip, fn,
                b.covJit, aa, frEvenOdd, op)
              return
          else:
            let fn = b.kern.getPatternBilinear(op)
            if fn != nil:
              let expanded = expandStroke(polys, width, cap, join, miterLimit)
              fillPatternBilinearJit(surf, expanded, paint, alpha, clip,
                fn, b.covJit, aa, frEvenOdd, op)
              return
    strokePolys(surf, polys, paint, width, cap, join, miterLimit, alpha,
      clip, aa, op)

when defined(nvgMetal):
  method fill*(b: MetalBackend, surf: Surface, polys: seq[SubPoly],
      paint: Paint, alpha: float64, clip: Clip, aa = true,
      op = coSourceOver, rule = frEvenOdd) =
    b.shadeFill(surf, polys, paint, alpha, clip, aa, rule, op)

  method stroke*(b: MetalBackend, surf: Surface, polys: seq[SubPoly],
      paint: Paint, width: float64, cap: LineCap, join: LineJoin,
      miterLimit: float64, alpha: float64, clip: Clip,
      aa = true, op = coSourceOver) =
    let expanded = expandStroke(polys, width, cap, join, miterLimit)
    b.shadeFill(surf, expanded, paint, alpha, clip, aa, frEvenOdd,
      op)

