## TEMPORARY CI diagnostic (do not land on main): runs fixed,
## rand-free pixels through the real kernels and the scalar oracle,
## echoing both byte vectors. Comparing the three legs shows whether
## the ARM divergence lives in the kernel or the scalar.
import std/unittest
import std/random
import std/strutils
import nvg/types
import nvg/surface
import nvg/jit
import dynasm/exec

test "zz hue kernel bytes":
  # Proves/disproves identical emitted bytes across legs (dynasm
  # version skew would show here). 1300 bytes hex.
  var buf = buildSolidRowGenAarch64(coHue)
  var s = ""
  for i in 0 ..< buf.length:
    s.add(buf[i].toHex(2))
  echo "zz-bytes len=", buf.length
  echo "zz-bytes0 ", s[0 ..< 650]
  echo "zz-bytes1 ", s[650 ..< 1300]
  echo "zz-bytes2 ", s[1300 ..< 1950]
  echo "zz-bytes3 ", s[1950 ..< s.len]
  buf.destroy()
  check true

test "zz rand stream check":
  # Proves/disproves identical rand streams across legs (load-bearing
  # premise for all input replication). Integer MT: must match.
  randomize(91827)
  var draws: seq[int] = @[]
  for i in 0 ..< 16:
    draws.add(rand(255))
  for i in 0 ..< 8:
    draws.add(rand(4))
  echo "zz-stream: ", draws
  check true

proc runCase(name: string, dst: seq[uint8], src: Color, cov: float64,
    op: CompOp) =
  let kern = JitKernels()
  let fn = kern.getSolid(op)
  var got = dst
  var cv = [cov]
  var ctx = bakeSolidCtx(src, 1.0)
  if fn != nil:
    fn(addr got[0], addr cv[0], int64(1), addr ctx)
  var surf = newSurface(1, 1)
  surf.pixels = dst
  surf.blendPixel(0, 0, src, cov, op)
  echo name, " dst=", dst, " src=", src, " cov=", cov,
    " kern=", got, " scalar=", surf.pixels
  kern.destroy()

test "zz fixed-pixel kernel-vs-scalar echoes":
  # Replicated sweep pixels (op=coHue/src0/n=32 stream position).
  runCase("hue-px2", @[118u8, 162u8, 253u8, 132u8],
    rgbaf(1, 0, 0, 1), 1.0, coHue)
  # Adversarial parked-l pixel (x86 kernel=122, scalar=123 locally).
  runCase("hue-adv", @[56u8, 234u8, 99u8, 245u8],
    rgbaf(1, 0, 0, 1), 1.0, coHue)
  # Controls: separable + sourceOver (green everywhere so far).
  runCase("mul-px", @[118u8, 162u8, 253u8, 132u8],
    rgbaf(1, 0, 0, 1), 1.0, coMultiply)
  runCase("over-px", @[10u8, 200u8, 30u8, 40u8],
    rgbaf(0.2, 0.4, 0.8, 0.5), 0.25, coSourceOver)
  check true

test "zz scalar sweep hashes":
  # Replicates the generic-op sweep's SCALAR side exactly (same ops,
  # srcs, seeds, draws, bake, blendPixel; no kernel calls). FNV hashes
  # per op prove/disprove scalar equality across legs. If these match
  # everywhere, the ARM divergence is kernel-side, full stop.
  randomize(91827)
  const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
    coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
    coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
    coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
    coDifference, coExclusion, coHue, coSaturation, coColor,
    coLuminosity]
  let srcs = [rgbaf(1, 0, 0, 1), rgbaf(0, 1, 0, 0.5),
    rgbaf(0.2, 0.4, 0.8, 0.0), rgbaf(2.0, -0.5, 0.5, 0.75),
    rgbaf(0.33, 0.66, 0.99, 0.01), rgbaf(0, 0, 0, 1),
    rgbaf(1, 1, 1, 1), rgbaf(1.0 / 255.0, 0, 0, 1.0 / 255.0),
    rgbaf(0.5, 0.5, 0.5, 0.003)]
  for op in ops:
    var h = 1469598103934665603u64
    for src in srcs:
      for n in [1, 3, 7, 32]:
        var dst = newSeq[uint8](n * 4)
        var cov = newSeq[float64](n)
        for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
        for i in 0 ..< n:
          cov[i] = [0.0, 0.02, 0.25, 0.5, 1.0][rand(4)]
        var surf = newSurface(max(n, 1), 1)
        surf.pixels.setLen(dst.len)
        for i, b in dst: surf.pixels[i] = b
        for x in 0 ..< n:
          surf.blendPixel(x, 0, src, cov[x], op)
        for b in surf.pixels:
          h = (h xor uint64(b)) * 1099511628211u64
    echo "zz-scalarhash ", op, " ", h.toHex(16)
  check true
  # Pure kernel characterization (no rand, no scalar): G byte 0..255,
  # fixed R/B/A/src/cov. Diffs vs the x86 curve pinpoint triggers.
  let kern = JitKernels()
  let fn = kern.getSolid(coHue)
  check fn != nil
  var line = ""
  for g in 0 ..< 256:
    var dst = @[118u8, uint8(g), 253u8, 132u8]
    var cv = [1.0]
    var ctx = bakeSolidCtx(rgbaf(1, 0, 0, 1), 1.0)
    var got = dst
    fn(addr got[0], addr cv[0], int64(1), addr ctx)
    line.add($got[1] & " ")
  echo "hue-curve-g: ", line
  kern.destroy()
