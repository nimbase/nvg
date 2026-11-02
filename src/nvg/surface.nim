## CPU pixel surface plus a dependency-free PNG writer.
##
## Pixels are straight (non-premultiplied) `RGBA8`. The PNG encoder uses
## per-row adaptive filtering (None/Sub/Up/Average/Paeth) plus a pure-Nim
## fixed-Huffman DEFLATE stream (greedy LZ77, hash chains): no zlib
## binding, decodable by any standard inflater, deterministic output.

import ./types

export types

type
  Surface* = ref object
    w*, h*: int
    pixels*: seq[uint8]

proc newSurface*(w, h: int): Surface =
  result = Surface(w: w, h: h, pixels: newSeq[uint8](w * h * 4))

proc idx(s: Surface, x, y: int): int = (y * s.w + x) * 4

proc inBounds*(s: Surface, x, y: int): bool =
  x >= 0 and y >= 0 and x < s.w and y < s.h

proc clear*(s: Surface, c: Color) =
  let (r, g, b, a) = c.toRgba8()
  var i = 0
  while i < s.pixels.len:
    s.pixels[i] = r
    s.pixels[i+1] = g
    s.pixels[i+2] = b
    s.pixels[i+3] = a
    i += 4

proc getPixel*(s: Surface, x, y: int): Color =
  if not s.inBounds(x, y):
    return rgbaf(0, 0, 0, 0)
  let i = s.idx(x, y)
  rgba(s.pixels[i], s.pixels[i+1], s.pixels[i+2], s.pixels[i+3])

proc setPixel*(s: Surface, x, y: int, c: Color) =
  if not s.inBounds(x, y): return
  let (r, g, b, a) = c.toRgba8()
  let i = s.idx(x, y)
  s.pixels[i] = r
  s.pixels[i+1] = g
  s.pixels[i+2] = b
  s.pixels[i+3] = a

proc blendPixel*(s: Surface, x, y: int, src: Color, coverage = 1.0,
    op = coSourceOver) =
  ## Blend `src` over the destination pixel under `op`. Coverage scales
  ## the source alpha (antialiasing mask). Colors are straight alpha
  ## throughout; `coLighter` clamps the additive result.
  ## `coSourceOver` is Normal. `coMultiply/coScreen/coOverlay` use
  ## blend-then-composite on straight RGBA8: with straight source
  ## `Cs,as` (coverage-scaled) and dest `Cb,ab`, `Bout = Blend(Cs,Cb)`
  ## (Multiply `Cs*Cb`, Screen `1-(1-Cs)(1-Cb)`, Overlay `2*Cs*Cb` for
  ## `Cb <= 0.5` else `1-2(1-Cs)(1-Cb)`), then
  ## `outA = as + ab*(1-as)` and
  ## `outRGB = ((1-ab)*as*Cs + (1-as)*ab*Cb + as*ab*Bout)/outA`
  ## (transparent black when `outA` is 0). Naive `mix(Cb,Bout,as)` agrees
  ## only for opaque dst and overweights translucent dst otherwise; the
  ## formula above matches the premultiplied style of the Porter-Duff
  ## branches below and stays correct for offscreen and mask surfaces.
  if not s.inBounds(x, y): return
  let sa = clamp01(src.a) * clamp01(coverage)
  let i = s.idx(x, y)
  if op == coSourceOver:
    if sa <= 0.0: return
    let dr = float64(s.pixels[i]) / 255.0
    let dg = float64(s.pixels[i+1]) / 255.0
    let db = float64(s.pixels[i+2]) / 255.0
    let da = float64(s.pixels[i+3]) / 255.0
    let inv = 1.0 - sa
    s.pixels[i] = uint8(clamp01(src.r * sa + dr * inv) * 255.0 + 0.5)
    s.pixels[i+1] = uint8(clamp01(src.g * sa + dg * inv) * 255.0 + 0.5)
    s.pixels[i+2] = uint8(clamp01(src.b * sa + db * inv) * 255.0 + 0.5)
    s.pixels[i+3] = uint8(clamp01(sa + da * inv) * 255.0 + 0.5)
    return
  let sr = clamp01(src.r)
  let sg = clamp01(src.g)
  let sb = clamp01(src.b)
  let dr = float64(s.pixels[i]) / 255.0
  let dg = float64(s.pixels[i+1]) / 255.0
  let db = float64(s.pixels[i+2]) / 255.0
  let da = float64(s.pixels[i+3]) / 255.0
  let csr = sr * sa
  let csg = sg * sa
  let csb = sb * sa
  let cdr = dr * da
  let cdg = dg * da
  let cdb = db * da
  var cor, cog, cob, ao: float64
  case op
  of coSourceOver: discard # handled above
  of coSourceIn:
    cor = csr * da; cog = csg * da; cob = csb * da; ao = sa * da
  of coSourceOut:
    cor = csr * (1.0 - da); cog = csg * (1.0 - da); cob = csb * (1.0 - da)
    ao = sa * (1.0 - da)
  of coAtop:
    cor = csr * da + cdr * (1.0 - sa)
    cog = csg * da + cdg * (1.0 - sa)
    cob = csb * da + cdb * (1.0 - sa)
    ao = da
  of coDestinationOver:
    cor = csr * (1.0 - da) + cdr
    cog = csg * (1.0 - da) + cdg
    cob = csb * (1.0 - da) + cdb
    ao = sa + da * (1.0 - sa)
  of coDestinationIn:
    cor = cdr * sa; cog = cdg * sa; cob = cdb * sa; ao = da * sa
  of coDestinationOut:
    cor = cdr * (1.0 - sa); cog = cdg * (1.0 - sa); cob = cdb * (1.0 - sa)
    ao = da * (1.0 - sa)
  of coDestinationAtop:
    cor = csr * (1.0 - da) + cdr * sa
    cog = csg * (1.0 - da) + cdg * sa
    cob = csb * (1.0 - da) + cdb * sa
    ao = sa
  of coLighter:
    cor = csr + cdr; cog = csg + cdg; cob = csb + cdb
    ao = min(1.0, sa + da)
  of coCopy:
    cor = csr; cog = csg; cob = csb; ao = sa
  of coXor:
    cor = csr * (1.0 - da) + cdr * (1.0 - sa)
    cog = csg * (1.0 - da) + cdg * (1.0 - sa)
    cob = csb * (1.0 - da) + cdb * (1.0 - sa)
    ao = sa + da - 2.0 * sa * da
  of coMultiply, coScreen, coOverlay:
    # Blend-then-composite (see `blendPixel` docs). `sr/sg/sb` are
    # straight clamped source, `dr/dg/db` straight dest, `sa` is
    # coverage-scaled, `da` dest alpha.
    proc blendCh(cs, cb: float64, op: CompOp): float64 =
      case op
      of coMultiply: cs * cb
      of coScreen: cs + cb - cs * cb
      else: # coOverlay
        if cb <= 0.5: 2.0 * cs * cb
        else: 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)
    let br = blendCh(sr, dr, op)
    let bg = blendCh(sg, dg, op)
    let bb = blendCh(sb, db, op)
    cor = (1.0 - da) * sa * sr + (1.0 - sa) * da * dr + sa * da * br
    cog = (1.0 - da) * sa * sg + (1.0 - sa) * da * dg + sa * da * bg
    cob = (1.0 - da) * sa * sb + (1.0 - sa) * da * db + sa * da * bb
    ao = sa + da * (1.0 - sa)
  if ao <= 1e-6:
    s.pixels[i] = 0
    s.pixels[i+1] = 0
    s.pixels[i+2] = 0
    s.pixels[i+3] = 0
  else:
    s.pixels[i] = uint8(clamp01(cor / ao) * 255.0 + 0.5)
    s.pixels[i+1] = uint8(clamp01(cog / ao) * 255.0 + 0.5)
    s.pixels[i+2] = uint8(clamp01(cob / ao) * 255.0 + 0.5)
    s.pixels[i+3] = uint8(clamp01(ao) * 255.0 + 0.5)

# --- DEFLATE with fixed Huffman codes (RFC 1951, pure Nim) ---
#
# A greedy LZ77 matcher (hash chains, 32K window) feeding the fixed
# literal/length and distance code tables. Single fixed-Huffman block
# per stream: deterministic output, no table-transmission overhead,
# decodable by any zlib implementation.

type BitWriter = object
  buf: seq[uint8]
  acc: uint32
  nbits: int

proc putBits(w: var BitWriter, val, n: int) =
  ## Append the low `n` bits of `val`, LSB first.
  w.acc = w.acc or (uint32(val) shl w.nbits)
  w.nbits += n
  while w.nbits >= 8:
    w.buf.add(uint8(w.acc and 0xFF))
    w.acc = w.acc shr 8
    w.nbits -= 8

proc flushBits(w: var BitWriter) =
  if w.nbits > 0:
    w.buf.add(uint8(w.acc and 0xFF))
    w.acc = 0
    w.nbits = 0

proc putCode(w: var BitWriter, code, nbits: int) =
  ## Emit a Huffman code, most-significant bit first (RFC 1951 packs
  ## codes MSB-first; block headers and extra bits stay LSB-first).
  var v = 0
  for i in 0 ..< nbits:
    v = (v shl 1) or ((code shr i) and 1)
  w.putBits(v, nbits)

proc putLitLen(w: var BitWriter, sym: int) =
  if sym <= 143:
    w.putCode(0x30 + sym, 8)
  elif sym <= 255:
    w.putCode(0x190 + (sym - 144), 9)
  elif sym <= 279:
    w.putCode(sym - 256, 7)
  else:
    w.putCode(0xC0 + (sym - 280), 8)

const
  lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3,
    3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
    193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
    12289, 16385, 24577]
  distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
    8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

proc deflateFixed*(data: openArray[uint8]): seq[uint8] =
  ## Compress `data` into one fixed-Huffman DEFLATE block.
  var w = BitWriter()
  w.putBits(1, 1) # BFINAL
  w.putBits(1, 2) # BTYPE = fixed Huffman
  if data.len == 0:
    w.putLitLen(256)
    w.flushBits()
    return w.buf
  const hashBits = 13
  const hashSize = 1 shl hashBits
  const hashMask = hashSize - 1
  const maxChain = 64
  const maxDist = 32768
  var head = newSeq[int](hashSize)
  var prev = newSeq[int](data.len)
  for i in 0 ..< hashSize: head[i] = -1
  var pos = 0
  while pos < data.len:
    var bestLen = 0
    var bestDist = 0
    if pos + 3 <= data.len:
      let h = ((int(data[pos]) shl 10) xor (int(data[pos+1]) shl 5) xor
        int(data[pos+2])) and hashMask
      var cand = head[h]
      let lim = max(0, pos - maxDist)
      var chain = 0
      let maxLen = min(258, data.len - pos)
      # NB: `>= lim` — position 0 is a valid match source; -1 (empty)
      # always fails since lim >= 0.
      while cand >= lim and chain < maxChain:
        var l = 0
        while l < maxLen and data[cand + l] == data[pos + l]: inc l
        if l >= 3 and l > bestLen:
          bestLen = l
          bestDist = pos - cand
          if l == 258: break
        cand = prev[cand]
        inc chain
      prev[pos] = head[h]
      head[h] = pos
    if bestLen >= 3:
      var li = 0
      while li + 1 < lenBase.len and lenBase[li+1] <= bestLen: inc li
      w.putLitLen(257 + li)
      if lenExtra[li] > 0:
        w.putBits(bestLen - lenBase[li], lenExtra[li])
      var di = 0
      while di + 1 < distBase.len and distBase[di+1] <= bestDist: inc di
      w.putCode(di, 5)
      if distExtra[di] > 0:
        w.putBits(bestDist - distBase[di], distExtra[di])
      # Index skipped positions so future matches see them.
      for k in 1 ..< bestLen:
        if pos + k + 3 <= data.len:
          let h = ((int(data[pos+k]) shl 10) xor
            (int(data[pos+k+1]) shl 5) xor int(data[pos+k+2])) and
            hashMask
          prev[pos + k] = head[h]
          head[h] = pos + k
      pos += bestLen
    else:
      w.putLitLen(int(data[pos]))
      inc pos
  w.putLitLen(256) # end of block
  w.flushBits()
  w.buf

# --- PNG row filters ---

proc paethPredictor(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc filterScore(raw: openArray[uint8]): int =
  ## Sum of absolute byte values (as signed) for filter selection.
  for b in raw:
    let v = int(b)
    result += (if v < 128: v else: 256 - v)

proc filterScanlines*(s: Surface): seq[uint8] =
  ## Filtered scanlines with per-row best-of-five filter selection
  ## (None/Sub/Up/Average/Paeth via minimum-sum heuristic).
  const bpp = 4
  let stride = s.w * bpp
  result = newSeq[uint8](s.h * (1 + stride))
  var prev = newSeq[uint8](stride) # zero row above the image
  var cand = newSeq[uint8](stride)
  var winner = newSeq[uint8](stride)
  var wpos = 0
  for y in 0 ..< s.h:
    let base = y * stride
    var bestFilter = 0
    var bestScore = high(int)
    for f in 0 .. 4:
      for i in 0 ..< stride:
        let left = if i >= bpp: int(s.pixels[base + i - bpp]) else: 0
        let up = int(prev[i])
        let upLeft = if i >= bpp: int(prev[i-bpp]) else: 0
        let pred = case f
          of 0: 0
          of 1: left
          of 2: up
          of 3: (left + up) div 2
          else: paethPredictor(left, up, upLeft)
        cand[i] = uint8((int(s.pixels[base + i]) - pred) and 0xFF)
      let score = filterScore(cand)
      if score < bestScore:
        bestScore = score
        bestFilter = f
        for i in 0 ..< stride:
          winner[i] = cand[i]
    result[wpos] = uint8(bestFilter)
    inc wpos
    for i in 0 ..< stride:
      result[wpos] = winner[i]
      inc wpos
      prev[i] = s.pixels[base + i]

var crcTable: array[256, uint32]
var crcReady = false

proc initCrc() =
  if crcReady: return
  for n in 0 .. 255:
    var c = uint32(n)
    for _ in 0 ..< 8:
      if (c and 1) != 0: c = 0xEDB88320'u32 xor (c shr 1)
      else: c = c shr 1
    crcTable[n] = c
  crcReady = true

proc crc32Chunk(chunkType: array[4, uint8],
    data: openArray[uint8]): uint32 =
  initCrc()
  var c = 0xFFFFFFFF'u32
  for b in chunkType:
    c = crcTable[(c xor uint32(b)) and 0xFF] xor (c shr 8)
  for b in data:
    c = crcTable[(c xor uint32(b)) and 0xFF] xor (c shr 8)
  c xor 0xFFFFFFFF'u32

proc adler32(data: openArray[uint8]): uint32 =
  var a = 1'u32
  var b = 0'u32
  for v in data:
    a = (a + uint32(v)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc pushU32BE(buf: var seq[uint8], v: uint32) =
  buf.add(uint8((v shr 24) and 0xFF))
  buf.add(uint8((v shr 16) and 0xFF))
  buf.add(uint8((v shr 8) and 0xFF))
  buf.add(uint8(v and 0xFF))

proc pushChunk(buf: var seq[uint8], name: string,
    data: openArray[uint8]) =
  var t: array[4, uint8]
  for i in 0 ..< 4: t[i] = uint8(name[i])
  buf.pushU32BE(uint32(data.len))
  for b in t: buf.add(b)
  for b in data: buf.add(b)
  buf.pushU32BE(crc32Chunk(t, data))

proc encodePng*(s: Surface): seq[uint8] =
  ## Encode the surface as PNG bytes (8-bit RGBA): per-row adaptive
  ## filtering plus fixed-Huffman DEFLATE, all pure Nim.
  result = @[]
  const sig: array[8, uint8] = [137'u8, 80, 78, 71, 13, 10, 26, 10]
  for b in sig: result.add(b)
  var ihdr: seq[uint8] = @[]
  ihdr.pushU32BE(uint32(s.w))
  ihdr.pushU32BE(uint32(s.h))
  ihdr.add(8'u8) # bit depth
  ihdr.add(6'u8) # color type: truecolor+alpha
  ihdr.add(0'u8)
  ihdr.add(0'u8)
  ihdr.add(0'u8)
  result.pushChunk("IHDR", ihdr)
  let raw = s.filterScanlines()
  var comp: seq[uint8] = @[0x78'u8, 0x01'u8]
  for b in deflateFixed(raw):
    comp.add(b)
  comp.pushU32BE(adler32(raw))
  result.pushChunk("IDAT", comp)
  result.pushChunk("IEND", [])

proc savePng*(s: Surface, path: string) =
  let bytes = s.encodePng()
  var f = open(path, fmWrite)
  defer: f.close()
  if bytes.len > 0:
    discard f.writeBytes(bytes, 0, bytes.len)
