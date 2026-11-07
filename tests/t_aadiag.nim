## TEMPORARY CI diagnostic (do not land on main): runs fixed,
## rand-free pixels through the real kernels and the scalar oracle,
## echoing both byte vectors. Comparing the three legs shows whether
## the ARM divergence lives in the kernel or the scalar.
import std/unittest
import nvg/types
import nvg/surface
import nvg/jit

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

test "zz hue kernel curve over G byte":
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
