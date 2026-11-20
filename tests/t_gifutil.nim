import std/unittest
import std/random
import std/tables
import buffalo
import "../examples/lottie_gifutil"

test "flattenWhiteInto matches flattenWhite":
  var rng = initRand(1234)
  var px = newSeq[uint8](64 * 4)
  for i in 0 ..< px.len:
    px[i] = uint8(rng.rand(255))
  let a = flattenWhite(px)
  var pool = initPool(uint8, 64 * 3)
  withBorrow(pool, buf):
    flattenWhiteInto(px, buf)
    check buf.toSeq() == a

test "downsampleInto matches downsample on fractional ratio":
  var rng = initRand(99)
  var rgb = newSeq[uint8](7 * 5 * 3)
  for i in 0 ..< rgb.len:
    rgb[i] = uint8(rng.rand(255))
  let a = downsample(rgb, 7, 5, 4, 3)
  var pool = initPool(uint8, 4 * 3 * 3)
  withBorrow(pool, buf):
    downsampleInto(rgb, 7, 5, 4, 3, buf)
    check buf.toSeq() == a

test "quantizeFlat matches quantize on exact palette":
  var rng = initRand(7)
  var base: array[10, tuple[r, g, b: uint8]]
  for i in 0 ..< base.len:
    base[i] = (uint8(rng.rand(255)), uint8(rng.rand(255)), uint8(rng.rand(255)))
  var frames: seq[seq[uint8]] = @[]
  var flat: seq[uint8] = @[]
  for _ in 0 ..< 3:
    var fr = newSeq[uint8](8 * 3)
    for i in 0 ..< 8:
      let c = base[rng.rand(base.high)]
      fr[i * 3] = c.r
      fr[i * 3 + 1] = c.g
      fr[i * 3 + 2] = c.b
    frames.add(fr)
    flat.add(fr)
  let a = quantize(frames)
  let b = quantizeFlat(flat, 3, 8)
  check a.exact
  check b == a

test "quantizeFlat matches quantize on popularity palette":
  var rng = initRand(42)
  var frames: seq[seq[uint8]] = @[]
  var flat: seq[uint8] = @[]
  for _ in 0 ..< 4:
    var fr = newSeq[uint8](200 * 3)
    for i in 0 ..< fr.len:
      fr[i] = uint8(rng.rand(255))
    frames.add(fr)
    flat.add(fr)
  let a = quantize(frames)
  let b = quantizeFlat(flat, 4, 200)
  check not a.exact
  check b == a

test "streaming core agrees with quantizeFlat":
  var rng = initRand(42)
  var flat: seq[uint8] = @[]
  for _ in 0 ..< 4:
    for _ in 0 ..< 200 * 3:
      flat.add(uint8(rng.rand(255)))
  var freq = initCountTable[tuple[r, g, b: uint8]]()
  addFreq(freq, flat)
  let (pal, mutCache, exact) = buildPalette(freq)
  var cache = mutCache
  var idx = newSeq[uint8](4 * 200)
  indexPixels(flat, pal, cache, idx)
  let b = quantizeFlat(flat, 4, 200)
  check exact == b.exact
  check pal == b.palette
  var flatIdx: seq[uint8] = @[]
  for fr in b.indexed:
    flatIdx.add(fr)
  check idx == flatIdx

test "splitRanges covers all frames contiguously":
  let rs = splitRanges(361, 6)
  check rs.len == 6
  check rs[0].s == 0
  check rs[^1].e == 361
  for i in 1 ..< rs.len:
    check rs[i].s == rs[i - 1].e
  var total = 0
  for r in rs:
    total += r.e - r.s
  check total == 361
  check splitRanges(3, 8).len == 3
  check splitRanges(0, 4).len == 0

test "countFrames matches while-loop iteration count":
  check countFrames(0.0, 361.0) == 361
  check countFrames(0.0, 0.0) == 0
  var n = 0
  var f = 2.0
  while f < 10.0:
    inc n
    f += 1.0
  check countFrames(2.0, 10.0) == n

test "delaysFor averages out with floor":
  let d = delaysFor(4, 2.5)
  check d.len == 4
  var total = 0
  for v in d:
    check v >= 2
    total += v.int
  check total == 10
