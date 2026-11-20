## Export the bundled dotLottie file as an animated GIF.
##
## Run: clue build examples/lottie_cat_gif.nim --release --out:/tmp/cat_gif && /tmp/cat_gif /tmp/cat.gif [--jobs N] [--size Px] [--stride S]
## (`--release` matters: the popularity palette hashes every pixel, ~2s
## optimized vs ~50s in debug for the old every-10th-frame version.)
##
## Renders every comp frame (or every S-th with `--stride S`) scaled to
## `--size` px (default 250, canvas pre-scaled from comp coordinates),
## flattens onto white (the GIF writer has no alpha) via `gifutil`, and
## encodes at the animation frame rate (~29.97 fps: 3,3,4 cs delays).
##
## Memory: single render pass; frames spill to a temp file and stream back
## for palette + indexing (`exportGifStreamed`), so only indexed frames
## (~1 byte/px) are retained. Per-frame scratch is pooled `buffalo` reuse.
## `--jobs N` renders frame ranges in N worker processes (same binary,
## `--chunk` mode) into one pre-sized spill; output bytes are identical.

import std/os
import std/strutils
import nvg
import buffalo
import ./lottie_gifutil

const
  catFile = currentSourcePath().parentDir() / "animations" /
    "Cat is sleeping and rolling.lottie"

proc renderOne(dl: DotLottie, a: Animation, lib: var AssetLib,
    idx, size, stride: int, dst: var PooledBuffer[uint8]) =
  let c = newCanvas(size, size)
  c.scale(size.float64 / a.w.float64, size.float64 / a.h.float64)
  registerDotLottie(c, lib, dl)
  renderFrame(c, a, a.ip + float64(idx * stride), lib)
  flattenWhiteInto(c.surface.pixels, dst)

proc runChunk(spill: string, s, e, size, stride: int) =
  let dl = loadDotLottieFile(catFile)
  let a = dl.anim
  var lib = AssetLib()
  let frameBytes = size * size * 3
  var scratch = initPool(uint8, frameBytes)
  var f = open(spill, fmReadWriteExisting)
  try:
    f.setFilePos(s * frameBytes)
    for idx in s ..< e:
      scratch.clear()
      renderOne(dl, a, lib, idx, size, stride, scratch)
      doAssert scratch.len == frameBytes
      let wrote = f.writeBuffer(unsafeAddr scratch.data[0], frameBytes)
      doAssert wrote == frameBytes
  finally:
    f.close()

proc main(outPath: string, jobs, size, stride: int) =
  if not fileExists(catFile):
    quit("missing " & catFile)
  let dl = loadDotLottieFile(catFile)
  let a = dl.anim
  var lib = AssetLib()
  let nFrames = countFrames(a.ip, a.op, stride)
  let delays = delaysFor(nFrames, stride.float64 * 100.0 / a.fr)
  if jobs <= 1:
    proc writeFrame(idx: int, dst: var PooledBuffer[uint8]) =
      renderOne(dl, a, lib, idx, size, stride, dst)
    exportGifStreamed(outPath, nFrames, size * size, size, size,
      delays, writeFrame)
  else:
    let ranges = splitRanges(nFrames, jobs)
    let spill = outPath & ".spill"
    presizeFile(spill, nFrames * size * size * 3)
    try:
      if not spawnChunks(getAppFilename(), ranges, spill, size, stride):
        quit("chunk render failed", 1)
      let freq = readSpillFreq(spill, nFrames, size * size * 3)
      finishSpill(outPath, spill, nFrames, size * size, size,
        size, delays, freq)
    finally:
      try:
        removeFile(spill)
      except OSError:
        discard

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == "--chunk":
    if paramCount() != 6:
      quit("usage: cat_gif --chunk <start> <end> <spill> <size> <stride>")
    runChunk(paramStr(4), parseInt(paramStr(2)), parseInt(paramStr(3)),
      parseInt(paramStr(5)), parseInt(paramStr(6)))
  else:
    if paramCount() < 1:
      quit("usage: cat_gif <out.gif> [--jobs N] [--size Px] [--stride S]")
    var jobs = defaultJobs()
    var size = 250
    var stride = 1
    var i = 2
    while i <= paramCount():
      if paramStr(i) == "--jobs" and i < paramCount():
        jobs = parseInt(paramStr(i + 1))
        inc i
      elif paramStr(i) == "--size" and i < paramCount():
        size = parseInt(paramStr(i + 1))
        inc i
      elif paramStr(i) == "--stride" and i < paramCount():
        stride = parseInt(paramStr(i + 1))
        inc i
      inc i
    main(paramStr(1), jobs, size, stride)
