import std/unittest
import nvg
import nvg/metal
import nvg/surface

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

test "compute source-over matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 8
    const H = 8
    let dstCases = [
      rgbf(0, 0, 1),
      rgbaf(0, 0, 0, 0),
      rgbaf(0, 1, 0, 0.5),
      rgbaf(1, 1, 1, 0.25),
    ]
    let srcCases = [
      rgbaf(1, 0, 0, 0.5),
      rgbaf(1, 1, 0, 1.0),
      rgbaf(0, 1, 1, 0.0),
    ]
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for dst in dstCases:
      for src in srcCases:
        var s = newSurface(W, H)
        s.clear(dst)
        let before = s.pixels
        for y in 0 ..< H:
          for x in 0 ..< W:
            s.blendPixel(x, y, src, 1.0, coSourceOver)
        ctx.upload(before)
        ctx.compSolidOver(src.r, src.g, src.b, src.a)
        let got = ctx.readback()
        var maxDiff = 0
        for i in 0 ..< got.len:
          let d = abs(int(got[i]) - int(s.pixels[i]))
          if d > maxDiff:
            maxDiff = d
        check maxDiff <= 1
  else:
    skip()

test "compute radial gradient matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 16
    const H = 16
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    let cases = [
      (8.0, 8.0, 1.0, 8.0, rgbf(0, 0, 0), rgbf(1, 1, 1)),
      (4.0, 12.0, 0.0, 10.0, rgbf(1, 0, 0), rgbf(0, 0, 1)),
    ]
    for (cx, cy, inr, outr, c0, c1) in cases:
      let paint = radialGradient(cx, cy, inr, outr, c0, c1)
      ctx.fillRadial(cx, cy, inr, outr, c0, c1)
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

test "compute box gradient matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 16
    const H = 16
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    let cases = [
      (8.0, 8.0, 5.0, 5.0, 2.0, 3.0, rgbf(0, 0, 0), rgbf(1, 1, 1)),
      (8.0, 8.0, 6.0, 3.0, 1.0, 2.0, rgbf(1, 0, 0), rgbf(0, 0, 1)),
    ]
    for (cx, cy, ex, ey, radius, feather, c0, c1) in cases:
      let paint = boxGradient(cx, cy, ex, ey, radius, feather, c0, c1)
      ctx.fillBox(cx, cy, ex, ey, radius, feather, c0, c1)
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
