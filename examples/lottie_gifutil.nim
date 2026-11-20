## Shared GIF-export helpers for the examples: flatten straight-alpha
## RGBA8 onto white, build one global 256-color popularity palette across
## all frames (exact while the frames share at most 256 distinct colors,
## nearest-match otherwise), encode with the `image` package's GIF writer.
##
## A uniform 3-3-2 bucket fallback is NOT used: it collapses pale fills
## such as the cat's muzzle beige (246,232,217) into white (255,255,255),
## erasing graphics wherever they sit on a white background.
##
## The `*Into` cores write into caller-owned `buffalo` buffers so the
## exporters can reuse scratch across frames; the plain `seq` wrappers
## delegate to the same cores for tests and stay behavior-identical.

import std/tables
import std/algorithm
import std/math
import std/os
import std/osproc
import image
import buffalo

proc flattenWhiteInto*(px: openArray[uint8], dst: var PooledBuffer[uint8]) =
  ## Straight-alpha RGBA8 to opaque RGB triplets on white, reusing `dst`.
  let n = px.len div 4
  dst.ensureLen(n * 3)
  for i in 0 ..< n:
    let a = px[i * 4 + 3].float64 / 255.0
    dst[i * 3] = uint8(px[i * 4].float64 * a + 255.0 * (1.0 - a) + 0.5)
    dst[i * 3 + 1] = uint8(px[i * 4 + 1].float64 * a + 255.0 * (1.0 - a) + 0.5)
    dst[i * 3 + 2] = uint8(px[i * 4 + 2].float64 * a + 255.0 * (1.0 - a) + 0.5)

proc flattenWhite*(px: openArray[uint8]): seq[uint8] =
  ## Straight-alpha RGBA8 to opaque RGB triplets on white.
  var pool = initPool(uint8, px.len div 4 * 3)
  withBorrow(pool, buf):
    flattenWhiteInto(px, buf)
    result = buf.toSeq()

proc downsampleInto*(rgb: openArray[uint8], w, h, dw, dh: int,
    dst: var PooledBuffer[uint8]) =
  ## Area-average RGB triplets from w×h to dw×dh (handles fractional
  ## ratios, e.g. 512→250, exactly), reusing `dst`.
  dst.ensureLen(dw * dh * 3)
  let sx = w.float64 / dw.float64
  let sy = h.float64 / dh.float64
  for y in 0 ..< dh:
    for x in 0 ..< dw:
      let x0 = x.float64 * sx
      let x1 = (x + 1).float64 * sx
      let y0 = y.float64 * sy
      let y1 = (y + 1).float64 * sy
      var r, g, b, area = 0.0
      for iy in int(y0) ..< int(ceil(y1)):
        for ix in int(x0) ..< int(ceil(x1)):
          let wgt = max(0.0, min(x1, (ix + 1).float64) - max(x0, ix.float64)) *
            max(0.0, min(y1, (iy + 1).float64) - max(y0, iy.float64))
          if wgt <= 0.0: continue
          let i = (min(iy, h - 1) * w + min(ix, w - 1)) * 3
          r += rgb[i].float64 * wgt
          g += rgb[i + 1].float64 * wgt
          b += rgb[i + 2].float64 * wgt
          area += wgt
      let j = (y * dw + x) * 3
      dst[j] = uint8(r / area + 0.5)
      dst[j + 1] = uint8(g / area + 0.5)
      dst[j + 2] = uint8(b / area + 0.5)

proc downsample*(rgb: seq[uint8], w, h, dw, dh: int): seq[uint8] =
  ## Area-average RGB triplets from w×h to dw×dh (handles fractional
  ## ratios, e.g. 512→250, exactly).
  var pool = initPool(uint8, dw * dh * 3)
  withBorrow(pool, buf):
    downsampleInto(rgb, w, h, dw, dh, buf)
    result = buf.toSeq()

proc delaysFor*(n: int, avgCs: float64, minCs = 2): seq[uint16] =
  ## Per-frame GIF delays (whole centiseconds) averaging `avgCs`.
  ## Bresenham-style error diffusion; floored at `minCs` since several
  ## viewers clamp sub-20 ms delays up to 100 ms.
  result = newSeq[uint16](n)
  var err = 0.0
  for i in 0 ..< n:
    var d = max(int(avgCs), minCs)
    err += avgCs - float64(d)
    if err >= 1.0:
      inc d
      err -= 1.0
    result[i] = uint16(max(d, minCs))

proc nearest(pal: seq[tuple[r, g, b: uint8]],
    c: tuple[r, g, b: uint8]): uint8 =
  var best = 0
  var bestD = int.high
  for i, p in pal:
    let dr = c.r.int - p.r.int
    let dg = c.g.int - p.g.int
    let db = c.b.int - p.b.int
    let d = dr * dr + dg * dg + db * db
    if d < bestD:
      bestD = d
      best = i
  uint8(best)

proc addFreq*(freq: var CountTable[tuple[r, g, b: uint8]],
    rgb: openArray[uint8]) =
  ## Accumulate triplet frequencies from flat RGB bytes (streaming pass A).
  assert rgb.len mod 3 == 0
  for i in 0 ..< rgb.len div 3:
    freq.inc((rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]))

proc buildPalette*(freq: CountTable[tuple[r, g, b: uint8]]):
    tuple[pal: seq[tuple[r, g, b: uint8]],
    cache: Table[tuple[r, g, b: uint8], uint8], exact: bool] =
  ## Global popularity palette: exact table while the pixels share at most
  ## 256 distinct triplets, else top-256 plus nearest-match fallback.
  if freq.len <= 256:
    var pal: seq[tuple[r, g, b: uint8]] = @[]
    var cache = initTable[tuple[r, g, b: uint8], uint8]()
    for k in freq.keys:
      cache[k] = uint8(pal.len)
      pal.add(k)
    return (pal, cache, true)
  var pairs: seq[tuple[c: tuple[r, g, b: uint8], n: int]] = @[]
  for k, v in freq:
    pairs.add((k, v))
  pairs.sort(proc(a, b: tuple[c: tuple[r, g, b: uint8], n: int]): int =
    cmp(b.n, a.n))
  var pal = newSeq[tuple[r, g, b: uint8]](256)
  for i in 0 ..< 256:
    pal[i] = pairs[i].c
  var cache = initTable[tuple[r, g, b: uint8], uint8]()
  for i, p in pal:
    cache[p] = uint8(i)
  (pal, cache, false)

proc indexPixels*(src: openArray[uint8], pal: seq[tuple[r, g, b: uint8]],
    cache: var Table[tuple[r, g, b: uint8], uint8], dst: var seq[uint8]) =
  ## Map flat RGB triplets to palette indices (nearest-match fallback,
  ## memoized in `cache`). `src.len` must equal `dst.len * 3`.
  assert src.len == dst.len * 3
  for i in 0 ..< dst.len:
    let key = (src[i * 3], src[i * 3 + 1], src[i * 3 + 2])
    if key in cache:
      dst[i] = cache[key]
    else:
      let n = nearest(pal, key)
      cache[key] = n
      dst[i] = n

proc quantize*(frames: seq[seq[uint8]]): tuple[palette: seq[tuple[r, g, b: uint8]],
    indexed: seq[seq[uint8]], exact: bool] =
  ## Global popularity palette across all frames; the 256 most frequent
  ## triplets win, rarer (mostly antialiased edge) colors map to nearest.
  var freq = initCountTable[tuple[r, g, b: uint8]]()
  for fr in frames:
    addFreq(freq, fr)
  let (pal, mutCache, exact) = buildPalette(freq)
  var cache = mutCache
  var outFrames: seq[seq[uint8]] = @[]
  for fr in frames:
    var idx = newSeq[uint8](fr.len div 3)
    indexPixels(fr, pal, cache, idx)
    outFrames.add(idx)
  (pal, outFrames, exact)

proc quantizeFlat*(flat: openArray[uint8], nFrames, pxPerFrame: int):
    tuple[palette: seq[tuple[r, g, b: uint8]], indexed: seq[seq[uint8]],
    exact: bool] =
  ## Same global-popularity palette as `quantize`, but over one flat
  ## frame store (`nFrames` x `pxPerFrame` RGB triplets). Frame/pixel
  ## encounter order matches `quantize`, so the palette is identical.
  assert flat.len == nFrames * pxPerFrame * 3
  var freq = initCountTable[tuple[r, g, b: uint8]]()
  addFreq(freq, flat)
  let (pal, mutCache, exact) = buildPalette(freq)
  var cache = mutCache
  var outFrames: seq[seq[uint8]] = @[]
  for f in 0 ..< nFrames:
    var idx = newSeq[uint8](pxPerFrame)
    let base = f * pxPerFrame * 3
    indexPixels(flat.toOpenArray(base, base + pxPerFrame * 3 - 1), pal,
      cache, idx)
    outFrames.add(idx)
  (pal, outFrames, exact)

proc countFrames*(ip, op: float64, stride = 1): int =
  ## Number of `while f < op: f += stride` iterations from `ip`.
  result = 0
  var f = ip
  while f < op:
    inc result
    f += stride.float64

proc spillRenderSeq*(spillPath: string, nFrames, frameBytes: int,
    writeFrame: proc(idx: int, dst: var PooledBuffer[uint8])):
    CountTable[tuple[r, g, b: uint8]] =
  ## Sequential render pass: spill frames to `spillPath`, return the
  ## global color histogram (accumulated while pixels are hot in cache).
  var freq = initCountTable[tuple[r, g, b: uint8]]()
  var outFile = open(spillPath, fmWrite)
  try:
    # Owned scratch (not borrowed): file I/O takes its address, which the
    # borrow DSL forbids. Backing is still reused across all frames.
    var scratch = initPool(uint8, frameBytes)
    for idx in 0 ..< nFrames:
      scratch.clear()
      writeFrame(idx, scratch)
      assert scratch.len == frameBytes
      addFreq(freq, scratch.toOpenArray)
      let wrote = outFile.writeBuffer(unsafeAddr scratch.data[0], frameBytes)
      assert wrote == frameBytes
  finally:
    outFile.close()
  freq

proc readSpillFreq*(spillPath: string, nFrames, frameBytes: int):
    CountTable[tuple[r, g, b: uint8]] =
  ## Histogram pass over an existing spill (multiprocess path: workers
  ## rendered it, so pixels are not hot here — one sequential read).
  result = initCountTable[tuple[r, g, b: uint8]]()
  var inFile = open(spillPath, fmRead)
  try:
    var chunk = initPool(uint8, frameBytes)
    chunk.ensureLen(frameBytes)
    for _ in 0 ..< nFrames:
      let got = inFile.readBuffer(addr chunk.data[0], frameBytes)
      assert got == frameBytes
      chunk.len = frameBytes
      addFreq(result, chunk.toOpenArray)
  finally:
    inFile.close()

proc finishSpill*(outPath, spillPath: string, nFrames, pxPerFrame, w, h: int,
    delays: seq[uint16], freq: CountTable[tuple[r, g, b: uint8]]) =
  ## Palette + index pass over the spill, then GIF encode. `spillPath`
  ## lifecycle stays with the caller.
  assert delays.len == nFrames
  let frameBytes = pxPerFrame * 3
  let (pal, mutCache, exact) = buildPalette(freq)
  var cache = mutCache
  echo "frames: ", nFrames, " palette: ", pal.len,
    " colors (" & (if exact: "exact" else: "popularity-256") & ")"
  var indexed: seq[seq[uint8]] = @[]
  var inFile = open(spillPath, fmRead)
  try:
    var chunk = initPool(uint8, frameBytes)
    chunk.ensureLen(frameBytes)
    for _ in 0 ..< nFrames:
      let got = inFile.readBuffer(addr chunk.data[0], frameBytes)
      assert got == frameBytes
      chunk.len = frameBytes
      var idx = newSeq[uint8](pxPerFrame)
      indexPixels(chunk.toOpenArray, pal, cache, idx)
      indexed.add(idx)
  finally:
    inFile.close()
  let gif = encodeGif(indexed, uint16(w), uint16(h), pal, delays)
  writeFile(outPath, gif)
  echo "wrote ", outPath, " (", gif.len, " bytes)"

proc exportGifStreamed*(outPath: string, nFrames, pxPerFrame, w, h: int,
    delays: seq[uint16],
    writeFrame: proc(idx: int, dst: var PooledBuffer[uint8])) =
  ## Single-render low-peak GIF export. Frames spill to a temp file via
  ## stdio (bytes stay in kernel page cache, not process RSS — an mmap
  ## would count toward the max-RSS high-water mark), then stream back
  ## for the index pass (the histogram accumulates while pixels are hot).
  ## Only indexed frames (~1 byte/px) are retained.
  assert delays.len == nFrames
  let spillPath = outPath & ".spill"
  try:
    let freq = spillRenderSeq(spillPath, nFrames, pxPerFrame * 3, writeFrame)
    finishSpill(outPath, spillPath, nFrames, pxPerFrame, w, h, delays, freq)
  finally:
    try:
      removeFile(spillPath)
    except OSError:
      discard

proc defaultJobs*(): int =
  ## Worker processes for `--jobs` (default: one per core, at least one).
  max(1, countProcessors())

proc splitRanges*(nFrames, jobs: int): seq[tuple[s, e: int]] =
  ## Contiguous `[s, e)` frame ranges, at most `jobs` of them.
  let j = max(1, min(jobs, max(nFrames, 1)))
  result = @[]
  for k in 0 ..< j:
    let s = (k * nFrames) div j
    let e = ((k + 1) * nFrames) div j
    if e > s:
      result.add((s, e))

proc presizeFile*(path: string, total: int) =
  ## Create `path` with exactly `total` bytes (sparse) so chunk workers
  ## can write their ranges at offsets through independent handles.
  var f = open(path, fmWrite)
  try:
    if total > 0:
      f.setFilePos(total - 1)
      f.write('\0')
  finally:
    f.close()

proc spawnChunks*(exe: string, ranges: seq[tuple[s, e: int]],
    spill: string, size, stride: int): bool =
  ## Run `exe --chunk s e spill size stride` per range, wait for all,
  ## report success. Worker stdio inherits (errors stay visible);
  ## a nonzero exit fails the whole export.
  var procs: seq[Process] = @[]
  for r in ranges:
    procs.add(startProcess(exe,
      args=["--chunk", $r.s, $r.e, spill, $size, $stride],
      options={poParentStreams}))
  result = true
  for p in procs:
    let code = p.waitForExit()
    p.close()
    if code != 0:
      result = false

proc exportGifDelaysFlat*(outPath: string, flat: openArray[uint8],
    nFrames, pxPerFrame, w, h: int, delays: seq[uint16]) =
  ## Quantize a flat frame store, encode with per-frame `delays`,
  ## write `outPath`. Same bytes as `exportGifDelays` for the same pixels.
  let (pal, indexed, exact) = quantizeFlat(flat, nFrames, pxPerFrame)
  echo "frames: ", indexed.len, " palette: ", pal.len,
    " colors (" & (if exact: "exact" else: "popularity-256") & ")"
  assert delays.len == indexed.len
  let gif = encodeGif(indexed, uint16(w), uint16(h), pal, delays)
  writeFile(outPath, gif)
  echo "wrote ", outPath, " (", gif.len, " bytes)"

proc exportGifDelays*(outPath: string, rgbs: seq[seq[uint8]], w, h: int,
    delays: seq[uint16]) =
  ## Quantize flattened `rgbs` frames, encode with per-frame `delays`,
  ## write `outPath`.
  let (pal, indexed, exact) = quantize(rgbs)
  echo "frames: ", indexed.len, " palette: ", pal.len,
    " colors (" & (if exact: "exact" else: "popularity-256") & ")"
  assert delays.len == indexed.len
  let gif = encodeGif(indexed, uint16(w), uint16(h), pal, delays)
  writeFile(outPath, gif)
  echo "wrote ", outPath, " (", gif.len, " bytes)"

proc exportGif*(outPath: string, rgbs: seq[seq[uint8]], w, h: int,
    delayCs: uint16) =
  ## Quantize flattened `rgbs` frames, encode with a uniform delay,
  ## write `outPath`.
  var delays = newSeq[uint16](rgbs.len)
  for i in 0 ..< delays.len: delays[i] = delayCs
  exportGifDelays(outPath, rgbs, w, h, delays)
