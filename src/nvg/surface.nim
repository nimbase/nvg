## CPU pixel surface plus a dependency-free PNG writer.
##
## Pixels are straight (non-premultiplied) `RGBA8`. The PNG encoder uses
## per-row adaptive filtering (None/Sub/Up/Average/Paeth) plus a pure-Nim
## fixed-Huffman DEFLATE stream (greedy LZ77, hash chains): no zlib
## binding, decodable by any standard inflater, deterministic output.

import std/math
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
  ## `coSourceOver` is Normal. `coMultiply`..`coLuminosity` use
  ## blend-then-composite on straight RGBA8: with straight source
  ## `Cs,as` (coverage-scaled) and dest `Cb,ab`, `Bout = Blend(Cs,Cb)`
  ## (separable per channel: Multiply `Cs*Cb`, Screen, Overlay keyed on
  ## `Cb <= 0.5`, Darken `min`, Lighten `max`, ColorDodge/ColorBurn with
  ## zero-division guards, HardLight keyed on `Cs`, SoftLight per W3C,
  ## Difference `|Cs-Cb|`, Exclusion; non-separable Hue/Saturation/
  ## Color/Luminosity per W3C `Lum/ClipColor/SetLum/SetSat` with
  ## `Lum = 0.3R+0.59G+0.11B`), then
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
  of coMultiply, coScreen, coOverlay, coDarken, coLighten,
      coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion:
    # Blend-then-composite (see `blendPixel` docs). `sr/sg/sb` are
    # straight clamped source, `dr/dg/db` straight dest, `sa` is
    # coverage-scaled, `da` dest alpha. Separable formulae per W3C
    # Compositing and Blending L1 (blend(Cb,Cs) there, transposed here
    # to blend(Cs,Cb)); guard order matches the spec so joint edge
    # cases (e.g. Cs=0 with Cb=1) agree.
    proc blendCh(cs, cb: float64, op: CompOp): float64 =
      case op
      of coMultiply: cs * cb
      of coScreen: cs + cb - cs * cb
      of coOverlay:
        if cb <= 0.5: 2.0 * cs * cb
        else: 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)
      of coDarken: min(cs, cb)
      of coLighten: max(cs, cb)
      of coColorDodge:
        if cs <= 0.0: 0.0
        elif cb >= 1.0: 1.0
        else: min(1.0, cs / (1.0 - cb))
      of coColorBurn:
        if cs >= 1.0: 1.0
        elif cb <= 0.0: 0.0
        else: 1.0 - min(1.0, (1.0 - cs) / cb)
      of coHardLight:
        if cs <= 0.5: 2.0 * cs * cb
        else: 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)
      of coSoftLight:
        if cs <= 0.5:
          cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
        else:
          let d =
            if cb <= 0.25: ((16.0 * cb - 12.0) * cb + 4.0) * cb
            else: sqrt(cb)
          cb + (2.0 * cs - 1.0) * (d - cb)
      of coDifference: abs(cs - cb)
      else: # coExclusion
        cs + cb - 2.0 * cs * cb
    let br = blendCh(sr, dr, op)
    let bg = blendCh(sg, dg, op)
    let bb = blendCh(sb, db, op)
    cor = (1.0 - da) * sa * sr + (1.0 - sa) * da * dr + sa * da * br
    cog = (1.0 - da) * sa * sg + (1.0 - sa) * da * dg + sa * da * bg
    cob = (1.0 - da) * sa * sb + (1.0 - sa) * da * db + sa * da * bb
    ao = sa + da * (1.0 - sa)
  of coHue, coSaturation, coColor, coLuminosity:
    # Non-separable blends per W3C (same blend-then-composite wrapper;
    # `Lum = 0.3R+0.59G+0.11B` per the spec, not Rec.601).
    proc lumC(r, g, b: float64): float64 = 0.3 * r + 0.59 * g + 0.11 * b
    proc clipC(r, g, b: float64): tuple[r, g, b: float64] =
      let l = lumC(r, g, b)
      var rr = r
      var gg = g
      var bb = b
      let n = min(rr, min(gg, bb))
      let x = max(rr, max(gg, bb))
      if n < 0.0:
        rr = l + ((rr - l) * l / (l - n))
        gg = l + ((gg - l) * l / (l - n))
        bb = l + ((bb - l) * l / (l - n))
      if x > 1.0:
        rr = l + ((rr - l) * (1.0 - l) / (x - l))
        gg = l + ((gg - l) * (1.0 - l) / (x - l))
        bb = l + ((bb - l) * (1.0 - l) / (x - l))
      (rr, gg, bb)
    proc setLumC(r, g, b: float64, l: float64):
        tuple[r, g, b: float64] =
      let d = l - lumC(r, g, b)
      clipC(r + d, g + d, b + d)
    proc satC(r, g, b: float64): float64 =
      max(r, max(g, b)) - min(r, min(g, b))
    proc setSatC(r, g, b: float64, s: float64):
        tuple[r, g, b: float64] =
      var vals = [r, g, b]
      var iMax = 0
      var iMin = 0
      for k in 1 .. 2:
        if vals[k] > vals[iMax]: iMax = k
        if vals[k] < vals[iMin]: iMin = k
      if iMax == iMin: # gray input: spec yields black before SetLum
        return (0.0, 0.0, 0.0)
      let iMid = 3 - iMax - iMin
      let nMid = ((vals[iMid] - vals[iMin]) * s) /
        (vals[iMax] - vals[iMin])
      var o = [0.0, 0.0, 0.0]
      o[iMax] = s
      o[iMid] = nMid
      (o[0], o[1], o[2])
    var br, bg, bb: float64
    case op
    of coHue:
      let st = setSatC(sr, sg, sb, satC(dr, dg, db))
      let l = setLumC(st.r, st.g, st.b, lumC(dr, dg, db))
      br = l.r; bg = l.g; bb = l.b
    of coSaturation:
      let st = setSatC(dr, dg, db, satC(sr, sg, sb))
      let l = setLumC(st.r, st.g, st.b, lumC(dr, dg, db))
      br = l.r; bg = l.g; bb = l.b
    of coColor:
      let l = setLumC(sr, sg, sb, lumC(dr, dg, db))
      br = l.r; bg = l.g; bb = l.b
    else: # coLuminosity
      let l = setLumC(dr, dg, db, lumC(sr, sg, sb))
      br = l.r; bg = l.g; bb = l.b
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

proc boxBlur*(s: Surface, radius: int) =
  ## Separable box blur (window `2*radius+1`) in premultiplied space:
  ## each tap contributes `rgb*a` and `a`; the output divides color by
  ## total alpha (transparent when it is zero) and averages alpha over
  ## the window. Premultiplied averaging keeps blurred transparent
  ## edges the source hue instead of dark fringes; on opaque images it
  ## reduces exactly to the straight-channel mean. Edges clamp
  ## (replicate); all math is integer round-half-up, so the Metal
  ## mirror is byte-identical. Both passes use sliding running sums:
  ## O(pixels) regardless of radius. Non-positive radii are a no-op.
  if radius <= 0 or s.w <= 0 or s.h <= 0: return
  let n = 2 * radius + 1
  let halfN = n div 2
  var tmp = newSeq[uint8](s.pixels.len)
  for y in 0 ..< s.h:
    let row = y * s.w
    var ar, ag, ab, aa = 0
    for k in -radius .. radius:
      let i = (row + clamp(k, 0, s.w - 1)) * 4
      let a = int(s.pixels[i + 3])
      ar += int(s.pixels[i]) * a
      ag += int(s.pixels[i + 1]) * a
      ab += int(s.pixels[i + 2]) * a
      aa += a
    for x in 0 ..< s.w:
      let o = (row + x) * 4
      if aa > 0:
        let h = aa div 2
        tmp[o] = uint8((ar + h) div aa)
        tmp[o + 1] = uint8((ag + h) div aa)
        tmp[o + 2] = uint8((ab + h) div aa)
      else:
        tmp[o] = 0
        tmp[o + 1] = 0
        tmp[o + 2] = 0
      tmp[o + 3] = uint8((aa + halfN) div n)
      let li = (row + clamp(x - radius, 0, s.w - 1)) * 4
      let la = int(s.pixels[li + 3])
      ar -= int(s.pixels[li]) * la
      ag -= int(s.pixels[li + 1]) * la
      ab -= int(s.pixels[li + 2]) * la
      aa -= la
      let ri = (row + clamp(x + radius + 1, 0, s.w - 1)) * 4
      let ra = int(s.pixels[ri + 3])
      ar += int(s.pixels[ri]) * ra
      ag += int(s.pixels[ri + 1]) * ra
      ab += int(s.pixels[ri + 2]) * ra
      aa += ra
  for x in 0 ..< s.w:
    var ar, ag, ab, aa = 0
    for k in -radius .. radius:
      let i = (clamp(k, 0, s.h - 1) * s.w + x) * 4
      let a = int(tmp[i + 3])
      ar += int(tmp[i]) * a
      ag += int(tmp[i + 1]) * a
      ab += int(tmp[i + 2]) * a
      aa += a
    for y in 0 ..< s.h:
      let o = (y * s.w + x) * 4
      if aa > 0:
        let h = aa div 2
        s.pixels[o] = uint8((ar + h) div aa)
        s.pixels[o + 1] = uint8((ag + h) div aa)
        s.pixels[o + 2] = uint8((ab + h) div aa)
      else:
        s.pixels[o] = 0
        s.pixels[o + 1] = 0
        s.pixels[o + 2] = 0
      s.pixels[o + 3] = uint8((aa + halfN) div n)
      let li = (clamp(y - radius, 0, s.h - 1) * s.w + x) * 4
      let la = int(tmp[li + 3])
      ar -= int(tmp[li]) * la
      ag -= int(tmp[li + 1]) * la
      ab -= int(tmp[li + 2]) * la
      aa -= la
      let ri = (clamp(y + radius + 1, 0, s.h - 1) * s.w + x) * 4
      let ra = int(tmp[ri + 3])
      ar += int(tmp[ri]) * ra
      ag += int(tmp[ri + 1]) * ra
      ab += int(tmp[ri + 2]) * ra
      aa += ra

proc boxWidthsForSigma*(sigma: float64, boxes = 3): seq[int] =
  ## Odd box widths whose repeated application approximates Gaussian
  ## blur with standard deviation `sigma` (ideal width split over
  ## `boxes` passes). Width 1 means an identity pass. Empty for
  ## non-positive sigma. The Metal mirror runs the same widths.
  if sigma <= 0.0 or boxes <= 0:
    return @[]
  let n = boxes
  let ideal = sqrt((12.0 * sigma * sigma / float64(n)) + 1.0)
  var lo = int(floor(ideal))
  if lo mod 2 == 0:
    dec lo
  if lo < 1:
    lo = 1
  let hi = lo + 2
  let m = clamp(int(round((12.0 * sigma * sigma -
    float64(n * lo * lo) - 4.0 * float64(n) * float64(lo) -
    3.0 * float64(n)) / float64(-4 * lo - 4))), 0, n)
  for i in 0 ..< m:
    result.add(lo)
  for i in m ..< n:
    result.add(hi)

proc gaussianBlur*(s: Surface, sigma: float64, boxes = 3) =
  ## Gaussian-like blur via repeated box blur (`boxWidthsForSigma`):
  ## fast and visually close, though not an exact Gaussian.
  ## Non-positive sigma is a no-op.
  for w in boxWidthsForSigma(sigma, boxes):
    s.boxBlur((w - 1) div 2)

proc unsharpMask*(s: Surface, radius: int, amount: float64) =
  ## Sharpening via `output = original + amount * (original - blurred)`
  ## with a box-blurred copy. Color works in premultiplied space
  ## (`rgb*a`, divided back out by the original alpha) so transparent
  ## edges keep their hue; fully transparent pixels stay transparent
  ## and the alpha channel passes through untouched. Output clamps to
  ## byte range; excessive amounts ring and emphasize noise. CPU uses
  ## float64 while the Metal mirror uses float32, so the pair agrees
  ## within 2 LSB. Non-positive radius or amount is a no-op.
  if radius <= 0 or amount <= 0.0 or s.w <= 0 or s.h <= 0: return
  var blurred = newSurface(s.w, s.h)
  for i in 0 ..< s.pixels.len:
    blurred.pixels[i] = s.pixels[i]
  blurred.boxBlur(radius)
  for i in 0 ..< (s.w * s.h):
    let o = i * 4
    let oa = int(s.pixels[o + 3])
    if oa <= 0:
      s.pixels[o] = 0
      s.pixels[o + 1] = 0
      s.pixels[o + 2] = 0
      s.pixels[o + 3] = 0
    else:
      for k in 0 ..< 3:
        let op = float64(s.pixels[o + k]) * float64(oa)
        let bp = float64(blurred.pixels[o + k]) *
          float64(blurred.pixels[o + 3])
        let v = (op + amount * (op - bp)) / float64(oa)
        s.pixels[o + k] =
          if v <= 0.0: 0u8
          elif v >= 255.0: 255u8
          else: uint8(int(v + 0.5))

proc mosaic*(s: Surface, cell: int) =
  ## Pixelation: every `cell` by `cell` block (partial blocks at the
  ## right/bottom edges average their available pixels) becomes its
  ## premultiplied mean, like `boxBlur` in miniature: transparent
  ## blocks stay transparent, edges keep their hue. Integer
  ## round-half-up throughout, so the Metal mirror is byte-identical.
  ## Cells of size 1 or less are a no-op.
  if cell <= 1 or s.w <= 0 or s.h <= 0: return
  for oy in countup(0, s.h - 1, cell):
    for ox in countup(0, s.w - 1, cell):
      var ar, ag, ab, aa, n = 0
      let x1 = min(ox + cell, s.w)
      let y1 = min(oy + cell, s.h)
      for y in oy ..< y1:
        for x in ox ..< x1:
          let i = (y * s.w + x) * 4
          let a = int(s.pixels[i + 3])
          ar += int(s.pixels[i]) * a
          ag += int(s.pixels[i + 1]) * a
          ab += int(s.pixels[i + 2]) * a
          aa += a
          inc n
      var r, g, b: uint8
      if aa > 0:
        let h = aa div 2
        r = uint8((ar + h) div aa)
        g = uint8((ag + h) div aa)
        b = uint8((ab + h) div aa)
      else:
        r = 0
        g = 0
        b = 0
      let a = uint8((aa + n div 2) div n)
      for y in oy ..< y1:
        for x in ox ..< x1:
          let i = (y * s.w + x) * 4
          s.pixels[i] = r
          s.pixels[i + 1] = g
          s.pixels[i + 2] = b
          s.pixels[i + 3] = a

type NoiseKind* = enum
  nkUniform
    ## Uniform integer delta in `[-A, +A]` per pixel (`A` from
    ## `amount`). Flat histogram, harshest grain.
  nkGaussian
    ## Sum of 3 uniform taps, recentered and rescaled to `[-A, +A]`:
    ## triangular-like, softer grain from the same integer hash
    ## stream. Still integer-exact, so the Metal mirror stays
    ## byte-identical.

proc hashPixel*(x, y: int32, seed, salt: uint32): uint32 =
  ## Deterministic lattice hash (uint32 wraparound throughout, so the
  ## MSL mirror computes the same bits; negative coords wrap via the
  ## bit-preserving cast on both sides). One stream per `salt`, so
  ## mono and per-channel noise stay independent. Stateless and
  ## position-only: no RNG state, thread-parallel by construction.
  var h = cast[uint32](x) * 374761393u32 +
    cast[uint32](y) * 668265263u32 + seed * 1442695041u32 +
    salt * 2246822519u32
  h = (h xor (h shr 13)) * 1274126177u32
  h xor (h shr 16)

proc noiseDelta(h: uint32, a: int): int =
  ## Uniform integer delta in `[-a, +a]` from the top 16 hash bits.
  ## Multiply-shift (no modulo bias); the product fits 32 bits
  ## (`65535 * 511`), so no wrap on either backend.
  int(((h shr 16) * uint32(2 * a + 1)) shr 16) - a

proc noiseAmp*(amount: float64): int =
  ## Full-scale fraction to LSB half-range (`0.0..1.0` -> `0..255`).
  ## Shared with the Metal mirror so both backends quantize `amount`
  ## identically.
  if amount <= 0.0: 0 else: min(255, int(amount * 255.0 + 0.5))

proc monoNoise*(s: Surface, amount: float64, seed: uint32 = 0,
    kind: NoiseKind = nkUniform) =
  ## Monochrome grain: one hash per pixel, the same integer delta
  ## added to R, G and B (`dr == dg == db` everywhere), so hues never
  ## shift. Straight-space add with clamping; alpha passes through
  ## untouched (like `unsharpMask`). Integer-exact, so the Metal
  ## mirror is byte-identical. Non-positive `amount` is a no-op.
  let a = noiseAmp(amount)
  if a <= 0 or s.w <= 0 or s.h <= 0: return
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let d = case kind
        of nkUniform:
          noiseDelta(hashPixel(int32(x), int32(y), seed, 0u32), a)
        of nkGaussian:
          let u0 = noiseDelta(hashPixel(int32(x), int32(y), seed,
            0u32), a) + a
          let u1 = noiseDelta(hashPixel(int32(x), int32(y), seed,
            1u32), a) + a
          let u2 = noiseDelta(hashPixel(int32(x), int32(y), seed,
            2u32), a) + a
          # Non-negative division only (MSL `/` truncates like `div`
          # here), recentered to [-a, +a].
          int(uint32(u0 + u1 + u2 + 1) div 3u32) - a
      if d == 0: continue
      let o = (y * s.w + x) * 4
      for k in 0 ..< 3:
        s.pixels[o + k] = uint8(clamp(int(s.pixels[o + k]) + d, 0, 255))

proc colorNoise*(s: Surface, amount: float64, seed: uint32 = 0,
    kind: NoiseKind = nkUniform) =
  ## Chromatic grain: independent hash streams per channel (salts
  ## `c` / `c*3+k`), so channels decorrelate and hues speckle.
  ## Otherwise identical to `monoNoise` (straight-space clamp, alpha
  ## untouched, byte-identical Metal mirror). Non-positive `amount`
  ## is a no-op.
  let a = noiseAmp(amount)
  if a <= 0 or s.w <= 0 or s.h <= 0: return
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let o = (y * s.w + x) * 4
      for c in 0 ..< 3:
        let d = case kind
          of nkUniform:
            noiseDelta(hashPixel(int32(x), int32(y), seed,
              uint32(c)), a)
          of nkGaussian:
            let u0 = noiseDelta(hashPixel(int32(x), int32(y), seed,
              uint32(c * 3)), a) + a
            let u1 = noiseDelta(hashPixel(int32(x), int32(y), seed,
              uint32(c * 3 + 1)), a) + a
            let u2 = noiseDelta(hashPixel(int32(x), int32(y), seed,
              uint32(c * 3 + 2)), a) + a
            int(uint32(u0 + u1 + u2 + 1) div 3u32) - a
        if d != 0:
          s.pixels[o + c] = uint8(clamp(int(s.pixels[o + c]) + d,
            0, 255))

proc sampleBilinearClamp*(px: openArray[uint8], w, h: int, sx,
    sy: float64): tuple[r, g, b, a: int] =
  ## Straight-space bilinear sample with clamp (replicate) edges and
  ## the premultiplied transparent guard (mirrors the Metal pattern
  ## kernels: accumulate `rgb*a`, divide back out; zero alpha reads
  ## as transparent black). Integer coords are pixel centers. CPU
  ## uses float64 while the Metal mirror uses float32, so warp pairs
  ## agree within 1 LSB.
  let x0 = int(floor(sx))
  let y0 = int(floor(sy))
  let tx = clamp(sx - float64(x0), 0.0, 1.0)
  let ty = clamp(sy - float64(y0), 0.0, 1.0)
  var ar, ag, ab, aa = 0.0
  for j in 0 .. 1:
    for i in 0 .. 1:
      let xi = clamp(x0 + i, 0, w - 1)
      let yi = clamp(y0 + j, 0, h - 1)
      let o = (yi * w + xi) * 4
      let al = float64(px[o + 3]) / 255.0
      let wt = (if i == 0: 1.0 - tx else: tx) *
        (if j == 0: 1.0 - ty else: ty)
      ar += float64(px[o]) / 255.0 * al * wt
      ag += float64(px[o + 1]) / 255.0 * al * wt
      ab += float64(px[o + 2]) / 255.0 * al * wt
      aa += al * wt
  if aa > 1e-6:
    (int(ar / aa * 255.0 + 0.5), int(ag / aa * 255.0 + 0.5),
      int(ab / aa * 255.0 + 0.5), int(aa * 255.0 + 0.5))
  else:
    (0, 0, 0, 0)

proc ripple*(s: Surface, amp, period: float64, phase = 0.0) =
  ## Sine-wave displacement along both axes (`amp` in px, `period` in
  ## px), sampled bilinearly with clamp edges (see
  ## `sampleBilinearClamp`: 1 LSB vs the Metal mirror). Non-positive
  ## `amp` or `period` is a no-op.
  if amp <= 0.0 or period <= 0.0 or s.w <= 0 or s.h <= 0: return
  var src = newSeq[uint8](s.pixels.len)
  for i in 0 ..< s.pixels.len:
    src[i] = s.pixels[i]
  let k = 2.0 * PI / period
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let sx = float64(x) + amp * sin(k * float64(y) + phase)
      let sy = float64(y) + amp * sin(k * float64(x) + phase)
      let (r, g, b, a) = sampleBilinearClamp(src, s.w, s.h, sx, sy)
      let o = (y * s.w + x) * 4
      s.pixels[o] = uint8(r)
      s.pixels[o + 1] = uint8(g)
      s.pixels[o + 2] = uint8(b)
      s.pixels[o + 3] = uint8(a)

proc swirl*(s: Surface, cx, cy, radius, angle: float64) =
  ## Rotate pixels around (`cx`, `cy`) by `angle` radians at the
  ## center, falling off linearly to zero at `radius`; outside is an
  ## exact copy. Inverse-mapped and bilinearly sampled with clamp
  ## edges (1 LSB vs the Metal mirror). Zero `angle` or
  ## non-positive `radius` is a no-op.
  if angle == 0.0 or radius <= 0.0 or s.w <= 0 or s.h <= 0: return
  var src = newSeq[uint8](s.pixels.len)
  for i in 0 ..< s.pixels.len:
    src[i] = s.pixels[i]
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let dx = float64(x) - cx
      let dy = float64(y) - cy
      let d = sqrt(dx * dx + dy * dy)
      let o = (y * s.w + x) * 4
      if d >= radius:
        continue
      let t = angle * (1.0 - d / radius)
      let c = cos(t)
      let sn = sin(t)
      let (r, g, b, a) = sampleBilinearClamp(src, s.w, s.h,
        cx + dx * c + dy * sn, cy - dx * sn + dy * c)
      s.pixels[o] = uint8(r)
      s.pixels[o + 1] = uint8(g)
      s.pixels[o + 2] = uint8(b)
      s.pixels[o + 3] = uint8(a)

proc latVal(ix, iy: int32, seed: uint32): float64 =
  ## Hashed lattice value in `[0, 1)`: top 24 hash bits over `2^24`
  ## (exactly representable in float32, so the Metal mirror computes
  ## the same lattice bits).
  float64(hashPixel(ix, iy, seed, 0u32) shr 8) / 16777216.0

proc fade(t: float64): float64 =
  ## Perlin smootherstep `6t^5 - 15t^4 + 10t^3`.
  t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

proc valueNoise*(x, y: float64, seed: uint32): float64 =
  ## Gradient-free value noise in `[0, 1]`: bilinear mix of hashed
  ## lattice corners under smootherstep fade. Negative coords wrap
  ## through the same bit-preserving cast on both backends.
  let xi = int32(floor(x))
  let yi = int32(floor(y))
  let xf = x - float64(xi)
  let yf = y - float64(yi)
  let u = fade(xf)
  let v = fade(yf)
  let a = latVal(xi, yi, seed)
  let b = latVal(xi + 1, yi, seed)
  let c = latVal(xi, yi + 1, seed)
  let d = latVal(xi + 1, yi + 1, seed)
  a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v

proc fbm*(x, y, freq: float64, octaves: int, seed: uint32): float64 =
  ## Fractal Brownian motion: `octaves` (clamped `1..8`) of doubling
  ## `valueNoise` with halving amplitude, normalized by total
  ## amplitude to stay in `[0, 1]`. fBm summation runs float64 on the
  ## CPU and float32 on Metal, so turbulence pairs agree within
  ## 2 LSB.
  let oct = clamp(octaves, 1, 8)
  var amp = 1.0
  var f = freq
  var sum = 0.0
  var norm = 0.0
  for o in 0 ..< oct:
    sum += amp * valueNoise(x * f, y * f, seed)
    norm += amp
    amp *= 0.5
    f *= 2.0
  sum / norm

proc turbulence*(s: Surface, scale: float64, octaves = 4,
    seed: uint32 = 0) =
  ## Full-range grayscale fBm field written to RGB (`0..255`),
  ## alpha preserved: clouds/marble base for textures and masks.
  ## `scale` is the base feature size in px (`freq = 1/scale`).
  ## Non-positive `scale` is a no-op; 2 LSB vs the Metal mirror.
  if scale <= 0.0 or s.w <= 0 or s.h <= 0: return
  let freq = 1.0 / scale
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let n = fbm(float64(x), float64(y), freq, octaves, seed)
      let v = uint8(clamp(int(n * 255.0 + 0.5), 0, 255))
      let o = (y * s.w + x) * 4
      s.pixels[o] = v
      s.pixels[o + 1] = v
      s.pixels[o + 2] = v

proc domainWarp*(s: Surface, scale, warpAmp: float64,
    octaves = 4, seed: uint32 = 0) =
  ## Displace the image's own sampling by a turbulent offset field:
  ## two fBm components (second salted with the golden ratio word)
  ## recentered to `[-1, 1]` and scaled by `warpAmp` px, sampled
  ## bilinearly with clamp edges. Flat images are fixed points.
  ## Non-positive `scale`/`warpAmp` is a no-op; 2 LSB vs Metal.
  if scale <= 0.0 or warpAmp <= 0.0 or s.w <= 0 or s.h <= 0: return
  var src = newSeq[uint8](s.pixels.len)
  for i in 0 ..< s.pixels.len:
    src[i] = s.pixels[i]
  let freq = 1.0 / scale
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let nx = fbm(float64(x), float64(y), freq, octaves, seed) - 0.5
      let ny = fbm(float64(x), float64(y), freq, octaves,
        seed xor 0x9E3779B9u32) - 0.5
      let (r, g, b, a) = sampleBilinearClamp(src, s.w, s.h,
        float64(x) + nx * 2.0 * warpAmp,
        float64(y) + ny * 2.0 * warpAmp)
      let o = (y * s.w + x) * 4
      s.pixels[o] = uint8(r)
      s.pixels[o + 1] = uint8(g)
      s.pixels[o + 2] = uint8(b)
      s.pixels[o + 3] = uint8(a)

proc motionBlur*(s: Surface, directionDeg, length: float64, taps = 9) =
  ## Directional blur: `taps` bilinear samples evenly spaced along the
  ## segment of `length` px centered at each pixel, oriented at
  ## `directionDeg` degrees (0 = right, 90 = down, increasing
  ## visually clockwise on the y-down canvas). The full 360 circle
  ## works: any value is fine (normalized with modulo, so 360 == 0
  ## and -90 == 270). Premultiplied average with the transparent
  ## guard (hue-preserving like `boxBlur`); clamp edges. CPU uses
  ## float64 while the Metal mirror uses float32, so the pair agrees
  ## within 1 LSB. Non-positive `length` or `taps < 2` is a no-op.
  if length <= 0.0 or taps < 2 or s.w <= 0 or s.h <= 0: return
  var src = newSeq[uint8](s.pixels.len)
  for i in 0 ..< s.pixels.len:
    src[i] = s.pixels[i]
  let th = directionDeg * PI / 180.0
  let dx = cos(th)
  let dy = sin(th)
  let step = length / float64(taps - 1)
  let mid = float64(taps - 1) * 0.5
  let n = float64(taps)
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      var ar, ag, ab, aa = 0.0
      for i in 0 ..< taps:
        let t = (float64(i) - mid) * step
        let (r, g, b, a) = sampleBilinearClamp(src, s.w, s.h,
          float64(x) + dx * t, float64(y) + dy * t)
        ar += float64(r) * float64(a)
        ag += float64(g) * float64(a)
        ab += float64(b) * float64(a)
        aa += float64(a)
      let o = (y * s.w + x) * 4
      if aa > 1e-6:
        s.pixels[o] = uint8(int(ar / aa + 0.5))
        s.pixels[o + 1] = uint8(int(ag / aa + 0.5))
        s.pixels[o + 2] = uint8(int(ab / aa + 0.5))
        s.pixels[o + 3] = uint8(int(aa / n + 0.5))
      else:
        s.pixels[o] = 0
        s.pixels[o + 1] = 0
        s.pixels[o + 2] = 0
        s.pixels[o + 3] = 0
