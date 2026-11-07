## Photo effects CLI: mosaic, box blur, gaussian blur, unsharp sharpen.
##
## Each requested effect renders from the original image into its own
## PNG. CPU is the default backend; --backend metal runs the Metal
## compute mirrors (needs -d:nvgMetal and a Metal device, else CPU).
##
## Run: nim c -r examples/effects.nim [--backend cpu|metal]
##        [--mosaic N] [--blur R] [--gauss SIGMA] [--sharpen R,AMOUNT]
##        [image] [outDir]
## Defaults: the tubusan lemons photo, examples/out, and one of each
## effect (mosaic 12, blur 8, gauss 2.0, sharpen 3,1.0) when no effect
## flag is given.

import std/os
import std/strutils
import std/math
import nvg
when defined(nvgMetal):
  import nvg/metal

const DefaultImage = "tests/data/pexels-tubusan-5773749.jpg"

proc usage() =
  echo """usage: effects [--backend cpu|metal] [--mosaic N] [--blur R]
         [--gauss SIGMA] [--sharpen R,AMOUNT] [image] [outDir]"""
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

when isMainModule:
  main()
