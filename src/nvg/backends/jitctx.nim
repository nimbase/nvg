## JIT context baking behind plain Nim (no Dynasm): row-fn types,
## per-fill/per-row ctx objects, `bake*Ctx`, and the skippable/runnable
## gates shared by the scalar-minded span pass (`raster.fill*Jit`) and the
## Dynasm kernel builders (`jit`). Offsets in the ctx objects are load-bearing:
## the x64/AArch64 kernels address fields by numeric displacement (see the
## layout notes on each object); keep field order stable.
import std/math
import ../types
import ../paint

export types

type
  SolidRowFn* = proc(dst, cov: pointer, n: int64,
    ctx: pointer) {.cdecl.}

  LinearRowFn* = SolidRowFn
    ## Same ABI as solid: per-row `rowX`/`m2y`/`m3y` travel inside ctx
    ## (mutated by Nim each row), so one kernel serves all linear fills.

  SolidCtx* = object
    sr*, sg*, sb*, sa*: float64
    c255*, half*, zero*, one*: float64
    divtab*: pointer

  LinearCtx* = object
    ## Per-fill constants (baked) + per-row fields (Nim-mutated).
    ## Offsets matter: the x64/AArch64 kernels below address fields by
    ## numeric displacement (m0=0 … one=168, divtab=176, rowX=184,
    ## m2y=192, m3y=200). Keep field order stable.
    m0*, m1*, m4*, m5*: float64
    sx*, sy*, dx*, dy*, len2*: float64
    r0*, dr*, g0*, dg*, b0*, db*, a0*, da*: float64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    rowX*, m2y*, m3y*: float64

var divTable: array[256, float64]
var divTableReady = false

proc ensureDivTable*() =
  ## Fill the byte->double table with runtime division (bit-identical
  ## to `blendPixel`'s `float64(byte) / 255.0` by construction).
  if divTableReady: return
  for i in 0 .. 255:
    divTable[i] = float64(i) / 255.0
  divTableReady = true

proc divTablePtr*(): pointer =
  ensureDivTable()
  addr divTable[0]

proc bakeSolidCtx*(src: Color, alpha: float64): SolidCtx =
  ## Bake per-fill constants. `src` channels stay raw (straight alpha,
  ## like the scalar source-over path); alpha folds `clamp01` in the
  ## same order (`src.a * clamp01(alpha)`, then clamp).
  let a = clamp01(alpha)
  SolidCtx(sr: src.r, sg: src.g, sb: src.b, sa: clamp01(src.a * a),
    c255: 255.0, half: 0.5, zero: 0.0, one: 1.0, divtab: divTablePtr())

proc bakeLinearCtx*(p: Paint, alpha: float64): LinearCtx =
  ## Bake a linear gradient for the JIT row kernel. Op order mirrors
  ## `paint.sample` + `blendPixel` exactly (see kernel docs); degenerate
  ## gradients (`len2 <= 1e-12`, same threshold as the scalar) bake as
  ## `dx=dy=0, len2=1` so the kernel's unconditional `t_num/len2` yields
  ## exactly `0.0` like the scalar `t=0.0` branch.
  let aAlpha = clamp01(alpha)
  var dx = p.linear.ex - p.linear.sx
  var dy = p.linear.ey - p.linear.sy
  var len2 = dx*dx + dy*dy
  if len2 <= 1e-12:
    dx = 0.0
    dy = 0.0
    len2 = 1.0
  result = LinearCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], sx: p.linear.sx, sy: p.linear.sy, dx: dx, dy: dy,
    len2: len2, r0: p.linear.icol.r, dr: p.linear.ocol.r - p.linear.icol.r,
    g0: p.linear.icol.g, dg: p.linear.ocol.g - p.linear.icol.g,
    b0: p.linear.icol.b, db: p.linear.ocol.b - p.linear.icol.b,
    a0: p.linear.icol.a, da: p.linear.ocol.a - p.linear.icol.a,
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc linearSkippable*(ctx: LinearCtx): bool =
  ## True when every pixel blends to a no-op: global alpha is zero, or
  ## both endpoint alphas are non-positive (lerp stays `<= 0` over
  ## `t in [0,1]`, so `clamp01(a_lerp * aAlpha)` is always `0`).
  if ctx.aAlpha <= 0.0: return true
  max(ctx.a0, ctx.a0 + ctx.da) <= 0.0

type
  RadialRowFn* = SolidRowFn
    ## Same ABI as solid/linear: per-row `rowX`/`m2y`/`m3y` travel
    ## inside ctx (mutated by Nim each row/run).

  RadialCtx* = object
    ## Same layout as `LinearCtx` (offsets 0..200 identical): the
    ## gradient block at 32..64 holds `cx/cy/inr/f` instead of
    ## `sx/sy/dx/dy/len2`, with `pad` keeping `r0` at 72. Kernels
    ## address fields by numeric displacement; keep field order stable.
    m0*, m1*, m4*, m5*: float64
    cx*, cy*, inr*, f*: float64
    pad*: float64
    r0*, dr*, g0*, dg*, b0*, db*, a0*, da*: float64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    rowX*, m2y*, m3y*: float64

proc bakeRadialCtx*(p: Paint, alpha: float64): RadialCtx =
  ## Bake a radial gradient. `f = max(1.0, outr - inr)` replicates the
  ## scalar feather floor (NanoVG still transitions on degenerate
  ## rings), so the kernel's unconditional `(dist-inr)/f` matches the
  ## scalar with no branch. `sqrtsd` == Nim `sqrt` bit-for-bit
  ## (200k-value sweep, 1e-300..1e300, zero diffs).
  let aAlpha = clamp01(alpha)
  result = RadialCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], cx: p.radial.cx, cy: p.radial.cy, inr: p.radial.inr,
    f: max(1.0, p.radial.outr - p.radial.inr), pad: 0.0,
    r0: p.radial.icol.r, dr: p.radial.ocol.r - p.radial.icol.r,
    g0: p.radial.icol.g, dg: p.radial.ocol.g - p.radial.icol.g,
    b0: p.radial.icol.b, db: p.radial.ocol.b - p.radial.icol.b,
    a0: p.radial.icol.a, da: p.radial.ocol.a - p.radial.icol.a,
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc radialSkippable*(ctx: RadialCtx): bool =
  ## Same no-op gate as `linearSkippable` (endpoint alphas + global).
  if ctx.aAlpha <= 0.0: return true
  max(ctx.a0, ctx.a0 + ctx.da) <= 0.0

type
  BoxRowFn* = SolidRowFn
    ## Same ABI as solid/linear/radial: per-row `rowX`/`m2y`/`m3y`
    ## travel inside ctx (mutated by Nim each row/run).

  BoxCtx* = object
    ## Like `LinearCtx` but the gradient block holds six doubles
    ## (`cx/cy/exr/eyr/radius/f`), so fields from `f` on sit 8 bytes
    ## later than in the linear/radial layout (`r0` at 80, `divtab` at
    ## 184, `rowX` at 192, `m2y` at 200, `m3y` at 208). `exr`/`eyr`
    ## bake `ex - r` / `ey - r`: the scalar recomputes the same
    ## subtraction per pixel from the same operands, so the baked
    ## value is bit-identical and saves two subs per pixel. Keep field
    ## order stable (kernels use numeric displacements).
    m0*, m1*, m4*, m5*: float64
    cx*, cy*, exr*, eyr*, radius*, f*: float64
    r0*, dr*, g0*, dg*, b0*, db*, a0*, da*: float64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    rowX*, m2y*, m3y*: float64

proc bakeBoxCtx*(p: Paint, alpha: float64): BoxCtx =
  ## Bake a box gradient. `f = max(1.0, feather)` replicates the scalar
  ## feather floor; the kernel's `(sd + f*0.5)/f` (via `divsd`) matches
  ## the scalar with no branch. `abs`/`min`/`max` replicate via
  ## sub+`maxpd` / `maxpd` / `minpd` (405k-value sweep over
  ## `sdRoundBox`, incl. ±0 crossings and `r > ex`, zero diffs) and
  ## `x^2` is `x*x` by `math.^`, so `mulsd` matches; `sqrtsd` == Nim
  ## `sqrt` (proven for radial). Finite colors only, as elsewhere.
  let aAlpha = clamp01(alpha)
  result = BoxCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], cx: p.box.cx, cy: p.box.cy,
    exr: p.box.ex - p.box.radius, eyr: p.box.ey - p.box.radius,
    radius: p.box.radius, f: max(1.0, p.box.feather),
    r0: p.box.icol.r, dr: p.box.ocol.r - p.box.icol.r,
    g0: p.box.icol.g, dg: p.box.ocol.g - p.box.icol.g,
    b0: p.box.icol.b, db: p.box.ocol.b - p.box.icol.b,
    a0: p.box.icol.a, da: p.box.ocol.a - p.box.icol.a,
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc boxSkippable*(ctx: BoxCtx): bool =
  ## Same no-op gate as `linearSkippable` (endpoint alphas + global).
  if ctx.aAlpha <= 0.0: return true
  max(ctx.a0, ctx.a0 + ctx.da) <= 0.0

type
  PatternRowFn* = SolidRowFn
    ## Same ABI as the other row kernels. Nearest-filter only: the
    ## kernel hard-requires `ifNearest` (bilinear stays scalar).

  PatternCtx* = object
    ## Nearest-pattern constants. Integer fields (`imgW/imgH/flags`)
    ## sit alongside the doubles; all are 8-byte aligned. `ca/sn`
    ## bake `cos/sin(angle)` (scalar recomputes them per pixel from the
    ## same input, so baking is bit-identical and saves two libm calls
    ## per pixel). `wF/hF` bake `float64(w/h)` (exact). Flags are three
    ## int64 0/1 fields (`flip/repX/repY`) because Dynasm `test` is
    ## reg-reg only. Keep field order stable (numeric displacements).
    m0*, m1*, m4*, m5*: float64
    ox*, oy*, ex*, ey*, ca*, sn*: float64
    wF*, hF*: float64
    tintR*, tintG*, tintB*, tintA*: float64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    imgPx*: pointer
    imgW*, imgH*: int64
    flip*, repX*, repY*: int64
    rowX*, m2y*, m3y*: float64

proc bakePatternCtx*(p: Paint, alpha: float64): PatternCtx =
  ## Bake a nearest image pattern. `u = (ca*dx+sn*dy)/ex` etc. replicate
  ## `paint.sample` (pattern branch) op-for-op via `divsd`; index math
  ## (trunc+adjust floor, `idiv` repeat-wrap, clamp) replicates
  ## `sampleImage` (300k-value spike, zero diffs); texel bytes convert
  ## through the div-table; tint then blends like any other kernel.
  ## Caller must pass `patternSkippable` first (`img` is dereferenced).
  let aAlpha = clamp01(alpha)
  let img = p.pattern.img
  result = PatternCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], ox: p.pattern.ox, oy: p.pattern.oy,
    ex: p.pattern.ex, ey: p.pattern.ey, ca: cos(p.pattern.angle),
    sn: sin(p.pattern.angle), wF: float64(img.w), hF: float64(img.h),
    tintR: p.pattern.tint.r, tintG: p.pattern.tint.g,
    tintB: p.pattern.tint.b, tintA: p.pattern.tint.a,
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), imgPx: addr img.pixels[0],
    imgW: int64(img.w), imgH: int64(img.h),
    flip: int64(if ifFlipY in img.flags: 1 else: 0),
    repX: int64(if ifRepeatX in img.flags: 1 else: 0),
    repY: int64(if ifRepeatY in img.flags: 1 else: 0),
    rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc patternSkippable*(p: Paint, alpha: float64): bool =
  ## Pre-bake no-op gate (safe on nil images): nil/empty image,
  ## degenerate tile (`|ex|,|ey| < 1e-12`, same threshold as the scalar,
  ## sampling transparent), zero global alpha, or non-positive tint
  ## alpha (every texel alpha scales by it: `ta >= 0`, so the source
  ## alpha stays `<= 0` under source-over).
  if p.pattern.img == nil: return true
  if abs(p.pattern.ex) < 1e-12 or abs(p.pattern.ey) < 1e-12: return true
  if p.pattern.img.w <= 0 or p.pattern.img.h <= 0: return true
  if clamp01(alpha) <= 0.0: return true
  p.pattern.tint.a <= 0.0

proc patternRunnable*(p: Paint): bool =
  ## Kernel-executable (safe to dereference `img`): non-nil, non-empty
  ## image with a sane tile. Transparent-but-runnable paints still run
  ## the kernel for non-sourceOver ops (clearing semantics differ from
  ## source-over's no-op); sourceOver skips them via `patternSkippable`.
  ## Non-runnable paints fall back to the scalar path (which samples
  ## transparent) for every op.
  p.kind == pkPattern and p.pattern.img != nil and
    abs(p.pattern.ex) >= 1e-12 and abs(p.pattern.ey) >= 1e-12 and
    p.pattern.img.w > 0 and p.pattern.img.h > 0

type
  MultiLinearRowFn* = SolidRowFn
    ## Multi-stop linear gradient row kernel. Same ABI as solid/linear;
    ## stops travel via pointer+len in ctx (heap array owned by the
    ## paint, alive through the fill).

  MultiLinearCtx* = object
    ## Pointer-based multi-stop ctx (arbitrary stop count, O(N) search
    ## per pixel like the scalar). Offsets are load-bearing for the new
    ## x64 kernels; keep field order stable.
    ## 0,8,16,24: m0,m1,m4,m5; 32,40,48,56,64: sx,sy,dx,dy,len2;
    ## 72: stopsPtr; 80: stopsLen; 88,96,104,112,120:
    ## aAlpha,c255,half,zero,one; 128: divtab; 136,144,152: rowX,m2y,m3y.
    m0*, m1*, m4*, m5*: float64
    sx*, sy*, dx*, dy*, len2*: float64
    stopsPtr*: pointer
    stopsLen*: int64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    rowX*, m2y*, m3y*: float64

  MultiRadialRowFn* = SolidRowFn

  MultiRadialCtx* = object
    ## Same idea for radial gradients: 0,8,16,24: m0,m1,m4,m5;
    ## 32,40,48,56: cx,cy,inr,f; 64: stopsPtr; 72: stopsLen;
    ## 80,88,96,104,112: aAlpha,c255,half,zero,one; 120: divtab;
    ## 128,136,144: rowX,m2y,m3y.
    m0*, m1*, m4*, m5*: float64
    cx*, cy*, inr*, f*: float64
    stopsPtr*: pointer
    stopsLen*: int64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    rowX*, m2y*, m3y*: float64

proc bakeMultiLinearCtx*(p: Paint, alpha: float64): MultiLinearCtx =
  ## Bake a multi-stop linear gradient. Same degenerate `len2` handling
  ## as `bakeLinearCtx`; stops pointer borrows the paint's heap array
  ## (alive through the synchronous fill).
  let aAlpha = clamp01(alpha)
  var dx = p.linear.ex - p.linear.sx
  var dy = p.linear.ey - p.linear.sy
  var len2 = dx*dx + dy*dy
  if len2 <= 1e-12:
    dx = 0.0
    dy = 0.0
    len2 = 1.0
  let n = p.linear.stops.len
  result = MultiLinearCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], sx: p.linear.sx, sy: p.linear.sy, dx: dx, dy: dy,
    len2: len2,
    stopsPtr: if n > 0: addr p.linear.stops[0] else: nil,
    stopsLen: int64(n),
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc bakeMultiRadialCtx*(p: Paint, alpha: float64): MultiRadialCtx =
  ## Bake a multi-stop radial gradient. Same `f` floor as `bakeRadialCtx`.
  let aAlpha = clamp01(alpha)
  let n = p.radial.stops.len
  result = MultiRadialCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], cx: p.radial.cx, cy: p.radial.cy, inr: p.radial.inr,
    f: max(1.0, p.radial.outr - p.radial.inr),
    stopsPtr: if n > 0: addr p.radial.stops[0] else: nil,
    stopsLen: int64(n),
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc multiLinearSkippable*(p: Paint, alpha: float64): bool =
  ## Source-over no-op gate for multi-stop linear: zero global alpha,
  ## empty (transparent), or every stop alpha non-positive (lerps stay
  ## `<= 0`, so `clamp01(a*alpha)` is always 0).
  if clamp01(alpha) <= 0.0: return true
  if p.linear.stops.len == 0: return true
  for s in p.linear.stops:
    if s.color.a > 0.0: return false
  true

proc multiRadialSkippable*(p: Paint, alpha: float64): bool =
  if clamp01(alpha) <= 0.0: return true
  if p.radial.stops.len == 0: return true
  for s in p.radial.stops:
    if s.color.a > 0.0: return false
  true

type
  MultiBoxRowFn* = SolidRowFn
    ## Multi-stop box-gradient row kernel. Same ABI as solid/linear;
    ## stops travel via pointer+len in ctx (heap array owned by the
    ## paint, alive through the fill).

  MultiBoxCtx* = object
    ## Box geometry block mirrors `BoxCtx` (so the `t` head matches the
    ## 2-stop box kernel op-for-op): 0,8,16,24: m0,m1,m4,m5;
    ## 32,40,48,56,64,72: cx,cy,exr,eyr,radius,f; 80: stopsPtr;
    ## 88: stopsLen; 96,104,112,120,128: aAlpha,c255,half,zero,one;
    ## 136: divtab; 144,152,160: rowX,m2y,m3y. Keep field order stable
    ## (kernels address fields by numeric displacement).
    m0*, m1*, m4*, m5*: float64
    cx*, cy*, exr*, eyr*, radius*, f*: float64
    stopsPtr*: pointer
    stopsLen*: int64
    aAlpha*, c255*, half*, zero*, one*: float64
    divtab*: pointer
    rowX*, m2y*, m3y*: float64

proc bakeMultiBoxCtx*(p: Paint, alpha: float64): MultiBoxCtx =
  ## Bake a multi-stop box gradient. Geometry matches `bakeBoxCtx`
  ## (`exr = ex - radius`, `f` floor); stops pointer borrows the paint
  ## heap array (alive through the synchronous fill).
  let aAlpha = clamp01(alpha)
  let n = p.box.stops.len
  result = MultiBoxCtx(m0: p.map[0], m1: p.map[1], m4: p.map[4],
    m5: p.map[5], cx: p.box.cx, cy: p.box.cy,
    exr: p.box.ex - p.box.radius, eyr: p.box.ey - p.box.radius,
    radius: p.box.radius, f: max(1.0, p.box.feather),
    stopsPtr: if n > 0: addr p.box.stops[0] else: nil,
    stopsLen: int64(n),
    aAlpha: aAlpha, c255: 255.0, half: 0.5, zero: 0.0, one: 1.0,
    divtab: divTablePtr(), rowX: 0.0, m2y: 0.0, m3y: 0.0)

proc multiBoxSkippable*(p: Paint, alpha: float64): bool =
  ## Source-over no-op gate for multi-stop box: zero global alpha,
  ## empty (transparent), or every stop alpha non-positive.
  if clamp01(alpha) <= 0.0: return true
  if p.box.stops.len == 0: return true
  for s in p.box.stops:
    if s.color.a > 0.0: return false
  true

type
  PatternBilinearRowFn* = SolidRowFn
    ## Bilinear-filter pattern row kernel. Same ABI and same `PatternCtx`
    ## layout as nearest (no new ctx); caller gates on runnable +
    ## `ifNearest` absent.
