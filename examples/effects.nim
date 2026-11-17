## Photo effects CLI: mosaic, box blur, gaussian blur, unsharp sharpen,
## grain (mono/color, uniform/soft), ripple, swirl, turbulence and
## domain warp.
##
## Each requested effect renders from the original image into its own
## PNG. CPU is the default backend; --backend metal runs the Metal
## compute mirrors (needs -d:nvgMetal and a Metal device, else CPU).
##
## Run: nim c -r examples/effects.nim [--backend cpu|metal]
##        [--mosaic N] [--blur R] [--gauss SIGMA] [--sharpen R,AMOUNT]
##        [--grain A,SEED] [--grain-color A,SEED]
##        [--grain-soft A,SEED] [--grain-color-soft A,SEED]
##        [--ripple AMP,PERIOD[,PHASE]] [--swirl CX,CY,RADIUS,ANGLE]
##        [--turbulence SCALE[,OCTAVES,SEED]] [--warp SCALE,AMP[,SEED]]
##        [image] [outDir]
## Defaults: the tubusan lemons photo, examples/out, and one of each
## effect when no effect flag is given.

import std/os
import std/strutils
import std/math
import nvg
when defined(nvgMetal):
  import nvg/metal

const DefaultImage = "tests/data/pexels-tubusan-5773749.jpg"

proc usage() =
  echo """usage: effects [--backend cpu|metal] [--mosaic N] [--blur R]
         [--gauss SIGMA] [--sharpen R,AMOUNT] [--grain A,SEED]
         [--grain-color A,SEED] [--grain-soft A,SEED]
         [--grain-color-soft A,SEED] [--ripple AMP,PERIOD[,PHASE]]
         [--swirl CX,CY,RADIUS,ANGLE] [--turbulence SCALE[,OCT,SEED]]
         [--warp SCALE,AMP[,SEED]] [image] [outDir]"""
  quit(1)

proc isImagePath(p: string): bool =
  let ext = p.splitFile().ext.toLowerAscii()
  ext in [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".qoi", ".pnm",
    ".tga"]

proc numRepr(v: float64): string =
  if v == floor(v):
    $int(v)
  else:
    ($v).replace(".", "p")

proc loadSurface(path: string): Surface =
  var data: seq[uint8]
  try:
    data = cast[seq[uint8]](readFile(path))
  except CatchableError:
    quit "cannot read image: " & path
  let d = decodeRgba8(data)
  if not d.ok:
    quit "cannot decode image: " & path
  result = newSurface(d.w, d.h)
  if d.pixels.len != result.pixels.len:
    quit "decoded size mismatch: " & path
  result.pixels = d.pixels

proc main() =
  var backend = "cpu"
  var mosaicCell = -1
  var blurR = -1
  var gaussS = -1.0
  var sharpR = -1
  var sharpA = -1.0
  var grainA = -1.0
  var grainSeed = 0u32
  var grainColorA = -1.0
  var grainColorSeed = 0u32
  var grainSoftA = -1.0
  var grainSoftSeed = 0u32
  var grainColorSoftA = -1.0
  var grainColorSoftSeed = 0u32
  var rippleAmp = -1.0
  var ripplePeriod = -1.0
  var ripplePhase = 0.0
  var swirlCx = 0.0
  var swirlCy = 0.0
  var swirlR = -1.0
  var swirlAngle = 0.0
  var swirlOn = false
  var turbScale = -1.0
  var turbOct = 4
  var turbSeed = 0u32
  var warpScale = -1.0
  var warpAmp = -1.0
  var warpSeed = 0u32
  var image = DefaultImage
  var outDir = "examples/out"
  var seenEffect = false
  var positionals: seq[string] = @[]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--help" or a == "-h":
      usage()
    elif a == "--backend":
      inc i
      if i > paramCount():
        usage()
      backend = paramStr(i)
      if backend != "cpu" and backend != "metal":
        usage()
    elif a == "--mosaic":
      inc i
      if i > paramCount():
        usage()
      mosaicCell = parseInt(paramStr(i))
      seenEffect = true
    elif a == "--blur":
      inc i
      if i > paramCount():
        usage()
      blurR = parseInt(paramStr(i))
      seenEffect = true
    elif a == "--gauss":
      inc i
      if i > paramCount():
        usage()
      gaussS = parseFloat(paramStr(i))
      seenEffect = true
    elif a == "--sharpen":
      inc i
      if i > paramCount():
        usage()
      let parts = paramStr(i).split(',')
      if parts.len != 2:
        usage()
      sharpR = parseInt(parts[0])
      sharpA = parseFloat(parts[1])
      seenEffect = true
    elif a == "--grain" or a == "--grain-color" or
        a == "--grain-soft" or a == "--grain-color-soft":
      inc i
      if i > paramCount():
        usage()
      let parts = paramStr(i).split(',')
      if parts.len != 2:
        usage()
      let ga = parseFloat(parts[0])
      let gs = parseInt(parts[1])
      if gs < 0:
        usage()
      if a == "--grain":
        grainA = ga
        grainSeed = uint32(gs)
      elif a == "--grain-color":
        grainColorA = ga
        grainColorSeed = uint32(gs)
      elif a == "--grain-soft":
        grainSoftA = ga
        grainSoftSeed = uint32(gs)
      else:
        grainColorSoftA = ga
        grainColorSoftSeed = uint32(gs)
      seenEffect = true
    elif a == "--ripple":
      inc i
      if i > paramCount():
        usage()
      let parts = paramStr(i).split(',')
      if parts.len < 2 or parts.len > 3:
        usage()
      rippleAmp = parseFloat(parts[0])
      ripplePeriod = parseFloat(parts[1])
      if parts.len == 3:
        ripplePhase = parseFloat(parts[2])
      seenEffect = true
    elif a == "--swirl":
      inc i
      if i > paramCount():
        usage()
      let parts = paramStr(i).split(',')
      if parts.len != 4:
        usage()
      swirlCx = parseFloat(parts[0])
      swirlCy = parseFloat(parts[1])
      swirlR = parseFloat(parts[2])
      swirlAngle = parseFloat(parts[3])
      swirlOn = true
      seenEffect = true
    elif a == "--turbulence":
      inc i
      if i > paramCount():
        usage()
      let parts = paramStr(i).split(',')
      if parts.len < 1 or parts.len > 3:
        usage()
      turbScale = parseFloat(parts[0])
      if parts.len >= 2:
        turbOct = parseInt(parts[1])
      if parts.len == 3:
        let ts = parseInt(parts[2])
        if ts < 0:
          usage()
        turbSeed = uint32(ts)
      seenEffect = true
    elif a == "--warp":
      inc i
      if i > paramCount():
        usage()
      let parts = paramStr(i).split(',')
      if parts.len < 2 or parts.len > 3:
        usage()
      warpScale = parseFloat(parts[0])
      warpAmp = parseFloat(parts[1])
      if parts.len == 3:
        let ws = parseInt(parts[2])
        if ws < 0:
          usage()
        warpSeed = uint32(ws)
      seenEffect = true
    elif a.startsWith("--"):
      usage()
    else:
      positionals.add(a)
    inc i
  if positionals.len > 0:
    # A single positional is the image, unless it names an existing
    # directory (or has no image extension and is not a file), in
    # which case it is the outDir.
    if positionals.len == 1 and not isImagePath(positionals[0]) and
        (dirExists(positionals[0]) or not fileExists(positionals[0])):
      outDir = positionals[0]
    else:
      image = positionals[0]
  if positionals.len > 1:
    outDir = positionals[1]
  if positionals.len > 2:
    usage()
  if not seenEffect:
    mosaicCell = 12
    blurR = 8
    gaussS = 2.0
    sharpR = 3
    sharpA = 1.0
    grainA = 0.15
    grainSeed = 1
    rippleAmp = 3.0
    ripplePeriod = 64.0
    turbScale = 64.0
    warpScale = 32.0
    warpAmp = 6.0
  createDir(outDir)
  let base = loadSurface(image)
  echo "image: ", base.w, "x", base.h

  var useMetal = backend == "metal"
  when defined(nvgMetal):
    var mb: MetalCtx = nil
    if useMetal:
      if mtlAvailable():
        mb = newMetalCtx(base.w, base.h)
        echo "backend: Metal"
      else:
        echo "backend: CPU (no Metal device)"
        useMetal = false
    else:
      echo "backend: CPU"
    defer:
      if mb != nil:
        mb.close()
  else:
    if useMetal:
      quit "rebuild with -d:nvgMetal for the metal backend"
    echo "backend: CPU"

  proc fresh(): Surface =
    result = newSurface(base.w, base.h)
    result.pixels = base.pixels

  when defined(nvgMetal):
    proc gpuFx(apply: proc(ctx: MetalCtx) {.closure.},
        name: string): Surface =
      mb.upload(base.pixels)
      apply(mb)
      result = newSurface(base.w, base.h)
      result.pixels = mb.readback()
      result.savePng(outDir / name)
      echo "wrote ", outDir / name

  if mosaicCell > 0:
    let name = "fx_mosaic_c" & $mosaicCell & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.mosaic(mosaicCell),
          name)
      else:
        let s = fresh()
        s.mosaic(mosaicCell)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.mosaic(mosaicCell)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if blurR > 0:
    let name = "fx_blur_r" & $blurR & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.boxBlur(blurR), name)
      else:
        let s = fresh()
        s.boxBlur(blurR)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.boxBlur(blurR)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if gaussS > 0.0:
    let name = "fx_gauss_s" & numRepr(gaussS) & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.gaussianBlur(gaussS),
          name)
      else:
        let s = fresh()
        s.gaussianBlur(gaussS)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.gaussianBlur(gaussS)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if sharpR > 0 and sharpA > 0.0:
    let name = "fx_sharp_r" & $sharpR & "_a" & numRepr(sharpA) & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(
          proc(ctx: MetalCtx) = ctx.unsharpMask(sharpR, sharpA), name)
      else:
        let s = fresh()
        s.unsharpMask(sharpR, sharpA)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.unsharpMask(sharpR, sharpA)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if grainA > 0.0:
    let name = "fx_grain_a" & numRepr(grainA) & "_s" & $grainSeed &
      ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(
          proc(ctx: MetalCtx) = ctx.monoNoise(grainA, grainSeed), name)
      else:
        let s = fresh()
        s.monoNoise(grainA, grainSeed)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.monoNoise(grainA, grainSeed)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if grainColorA > 0.0:
    let name = "fx_grain_color_a" & numRepr(grainColorA) & "_s" &
      $grainColorSeed & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) =
          ctx.colorNoise(grainColorA, grainColorSeed), name)
      else:
        let s = fresh()
        s.colorNoise(grainColorA, grainColorSeed)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.colorNoise(grainColorA, grainColorSeed)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if grainSoftA > 0.0:
    let name = "fx_grain_soft_a" & numRepr(grainSoftA) & "_s" &
      $grainSoftSeed & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.monoNoise(grainSoftA,
          grainSoftSeed, nkGaussian), name)
      else:
        let s = fresh()
        s.monoNoise(grainSoftA, grainSoftSeed, nkGaussian)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.monoNoise(grainSoftA, grainSoftSeed, nkGaussian)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if grainColorSoftA > 0.0:
    let name = "fx_grain_color_soft_a" & numRepr(grainColorSoftA) &
      "_s" & $grainColorSoftSeed & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.colorNoise(
          grainColorSoftA, grainColorSoftSeed, nkGaussian), name)
      else:
        let s = fresh()
        s.colorNoise(grainColorSoftA, grainColorSoftSeed, nkGaussian)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.colorNoise(grainColorSoftA, grainColorSoftSeed, nkGaussian)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if rippleAmp > 0.0 and ripplePeriod > 0.0:
    let name = "fx_ripple_a" & numRepr(rippleAmp) & "_p" &
      numRepr(ripplePeriod) & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.ripple(rippleAmp,
          ripplePeriod, ripplePhase), name)
      else:
        let s = fresh()
        s.ripple(rippleAmp, ripplePeriod, ripplePhase)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.ripple(rippleAmp, ripplePeriod, ripplePhase)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if swirlOn:
    let name = "fx_swirl_a" & numRepr(swirlAngle) & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.swirl(swirlCx, swirlCy,
          swirlR, swirlAngle), name)
      else:
        let s = fresh()
        s.swirl(swirlCx, swirlCy, swirlR, swirlAngle)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.swirl(swirlCx, swirlCy, swirlR, swirlAngle)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if turbScale > 0.0:
    let name = "fx_turb_s" & numRepr(turbScale) & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.turbulence(turbScale,
          turbOct, turbSeed), name)
      else:
        let s = fresh()
        s.turbulence(turbScale, turbOct, turbSeed)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.turbulence(turbScale, turbOct, turbSeed)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name
  if warpScale > 0.0 and warpAmp > 0.0:
    let name = "fx_warp_s" & numRepr(warpScale) & "_a" &
      numRepr(warpAmp) & ".png"
    when defined(nvgMetal):
      if useMetal:
        discard gpuFx(proc(ctx: MetalCtx) = ctx.domainWarp(warpScale,
          warpAmp, 4, warpSeed), name)
      else:
        let s = fresh()
        s.domainWarp(warpScale, warpAmp, 4, warpSeed)
        s.savePng(outDir / name)
        echo "wrote ", outDir / name
    else:
      let s = fresh()
      s.domainWarp(warpScale, warpAmp, 4, warpSeed)
      s.savePng(outDir / name)
      echo "wrote ", outDir / name

when isMainModule:
  main()
