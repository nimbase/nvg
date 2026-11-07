## Pluggable render backend seam.
##
## V1 ships only `CpuBackend` (the supersampled scanline rasterizer in
## `raster.nim`). A future GPU renderer implements the same `fill`/`stroke`
## signatures on a new `Backend` subtype so `canvas.nim` does not change.

import ./types
import ./path
import ./paint
import ./surface
import ./raster
when defined(nvgJit):
  import ./jit

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
      ## `CpuBackend`. Opt-in via `newCanvas(w, h, newJitBackend())`;
      ## call `destroyJitBackend` when done (mappings are also released
      ## by GC).
      kern*: JitKernels
      covJit*: seq[float64]

proc newCpuBackend*(): CpuBackend = CpuBackend()

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
    ## scalar fallback covers non-runnable patterns and non-amd64 hosts.
    when defined(amd64):
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
    when defined(amd64):
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

