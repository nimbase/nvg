import std/unittest
import nvg
import nvg/metal

test "metal device enumerates with a name":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    var ctx = newMetalCtx(1, 1)
    defer: ctx.close()
    check ctx.deviceName().len > 0
  else:
    skip()

test "compute solid fill matches cpu surface":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 8
    const H = 8
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for (r, g, b, a) in [(1.0, 0.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0),
        (0.0, 0.0, 1.0, 0.5), (0.5, 0.5, 0.5, 1.0)]:
      ctx.fillSolid(r, g, b, a)
      let got = ctx.readback()
      var s = newSurface(W, H)
      s.clear(rgbf(r, g, b).withAlpha(a))
      check got == s.pixels
  else:
    skip()

test "compute linear gradient matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 16
    const H = 16
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    let cases = [
      (0.0, 0.0, 16.0, 0.0, rgbf(0, 0, 0), rgbf(1, 1, 1)),
      (0.0, 0.0, 16.0, 16.0, rgbf(1, 0, 0), rgbf(0, 0, 1)),
    ]
    for (sx, sy, ex, ey, c0, c1) in cases:
      let paint = linearGradient(sx, sy, ex, ey, c0, c1)
      ctx.fillLinear(sx, sy, ex, ey, c0, c1)
      let got = ctx.readback()
      var maxDiff = 0
      for y in 0 ..< H:
        for x in 0 ..< W:
          let (r, g, b, a) = paint.sample(
            float64(x) + 0.5, float64(y) + 0.5).toRgba8()
          let i = (y * W + x) * 4
          for k in 0 ..< 4:
            let want = [r, g, b, a][k]
            let d = abs(int(got[i + k]) - int(want))
            if d > maxDiff:
              maxDiff = d
      check maxDiff <= 1
  else:
    skip()
