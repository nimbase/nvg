import std/unittest
import nvg
import nvg/backends/metal
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

test "compute all blend ops match cpu":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 8
    const H = 8
    let dstCases = [
      rgbf(1, 1, 1),
      rgbf(0, 0, 0),
      rgbf(1, 0, 0),
      rgbaf(0, 0, 0, 0),
      rgbaf(0.2, 0.6, 0.4, 0.5),
    ]
    let srcCases = [
      rgbaf(1, 0, 0, 0.5),
      rgbaf(1, 1, 1, 1.0),
      rgbaf(0, 1, 1, 0.75),
    ]
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for op in low(CompOp) .. high(CompOp):
      let bar = if ord(op) <= 21: 1 else: 2
      for dst in dstCases:
        for src in srcCases:
          var s = newSurface(W, H)
          s.clear(dst)
          let before = s.pixels
          for y in 0 ..< H:
            for x in 0 ..< W:
              s.blendPixel(x, y, src, 1.0, op)
          ctx.upload(before)
          ctx.compBlend(op, src.r, src.g, src.b, src.a, 1.0)
          let got = ctx.readback()
          var maxDiff = 0
          for i in 0 ..< got.len:
            let d = abs(int(got[i]) - int(s.pixels[i]))
            if d > maxDiff:
              maxDiff = d
          check maxDiff <= bar
    # Coverage scaling through the over path.
    for cov in [0.0, 0.5]:
      var s = newSurface(W, H)
      s.clear(rgbf(0, 0, 1))
      let before = s.pixels
      let src = rgbaf(1, 0, 0, 0.8)
      for y in 0 ..< H:
        for x in 0 ..< W:
          s.blendPixel(x, y, src, cov, coSourceOver)
      ctx.upload(before)
      ctx.compBlend(coSourceOver, src.r, src.g, src.b, src.a, cov)
      check ctx.readback() == s.pixels
  else:
    skip()

test "metal backend canvas fill matches cpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 24
    const H = 24
    var cpu = newCanvas(W, H)
    cpu.setFillColor(rgbf(1, 0, 0))
    cpu.rect(2.5, 3.5, 10, 7)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillColor(rgbf(1, 0, 0))
    gpu.rect(2.5, 3.5, 10, 7)
    gpu.fill()
    let a = cpu.surf.pixels
    let g = gpu.surf.pixels
    check a.len == g.len
    var maxDiff = 0
    for i in 0 ..< a.len:
      let d = abs(int(a[i]) - int(g[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 1
  else:
    skip()

test "metal backend canvas stroke matches cpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 24
    const H = 24
    var cpu = newCanvas(W, H)
    cpu.setStrokeColor(rgbf(0, 0, 1))
    cpu.setStrokeWidth(3.0)
    cpu.rect(4.5, 4.5, 12, 12)
    cpu.stroke()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setStrokeColor(rgbf(0, 0, 1))
    gpu.setStrokeWidth(3.0)
    gpu.rect(4.5, 4.5, 12, 12)
    gpu.stroke()
    let a = cpu.surf.pixels
    let g = gpu.surf.pixels
    var maxDiff = 0
    for i in 0 ..< a.len:
      let d = abs(int(a[i]) - int(g[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 1
  else:
    skip()

test "metal backend shades linear paint on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let p = linearGradient(0, 0, 16, 0, rgbf(0, 0, 0), rgbf(1, 1, 1))
    var cpu = newCanvas(W, H)
    cpu.setFillPaint(p)
    cpu.rect(0, 0, 16, 16)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillPaint(p)
    gpu.rect(0, 0, 16, 16)
    gpu.fill()
    var maxDiff = 0
    for i in 0 ..< cpu.surf.pixels.len:
      let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 1
  else:
    skip()

test "metal backend shades multi-stop linear on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let p = linearGradientStops(0, 0, 16, 0, [
      GradientStop(pos: 0.0, color: rgbf(0, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(1, 0, 0)),
      GradientStop(pos: 1.0, color: rgbf(1, 1, 1)),
    ])
    var cpu = newCanvas(W, H)
    cpu.setFillPaint(p)
    cpu.rect(0, 0, 16, 16)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillPaint(p)
    gpu.rect(0, 0, 16, 16)
    gpu.fill()
    var maxDiff = 0
    for i in 0 ..< cpu.surf.pixels.len:
      let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 2
  else:
    skip()

test "metal backend shades multi-stop radial and box on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let paints = [
      radialGradientStops(8, 8, 0, 8, [
        GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
        GradientStop(pos: 0.4, color: rgbf(0, 1, 0)),
        GradientStop(pos: 0.7, color: rgbf(0, 0, 1)),
        GradientStop(pos: 1.0, color: rgbf(1, 1, 1)),
      ]),
      boxGradientStops(8, 8, 5, 5, 2, 3, [
        GradientStop(pos: 0.0, color: rgbf(0, 0, 0)),
        GradientStop(pos: 0.6, color: rgbf(1, 1, 0)),
        GradientStop(pos: 1.0, color: rgbf(1, 1, 1)),
      ]),
    ]
    for p in paints:
      var cpu = newCanvas(W, H)
      cpu.setFillPaint(p)
      cpu.rect(0, 0, 16, 16)
      cpu.fill()
      let mb = newMetalBackend(W, H)
      defer: mb.close()
      var gpu = newCanvas(W, H, mb)
      gpu.setFillPaint(p)
      gpu.rect(0, 0, 16, 16)
      gpu.fill()
      var maxDiff = 0
      for i in 0 ..< cpu.surf.pixels.len:
        let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 2
  else:
    skip()

test "metal backend shades hard stops on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let p = linearGradientStops(0, 0, 16, 0, [
      GradientStop(pos: 0.0, color: rgbf(0, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(1, 0, 0)),
      GradientStop(pos: 0.5, color: rgbf(0, 0, 1)),
      GradientStop(pos: 1.0, color: rgbf(1, 1, 1)),
    ])
    var cpu = newCanvas(W, H)
    cpu.setFillPaint(p)
    cpu.rect(0, 0, 16, 16)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillPaint(p)
    gpu.rect(0, 0, 16, 16)
    gpu.fill()
    var maxDiff = 0
    for i in 0 ..< cpu.surf.pixels.len:
      let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 2
  else:
    skip()

test "metal backend falls back past 8 stops":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    var stops: array[9, GradientStop]
    for i in 0 ..< 9:
      stops[i] = GradientStop(pos: float64(i) / 8.0,
        color: rgbf(float64(i) / 8.0, 0.2, 0.8))
    let p = linearGradientStops(0, 0, 16, 0, stops)
    var cpu = newCanvas(W, H)
    cpu.setFillPaint(p)
    cpu.rect(0, 0, 16, 16)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillPaint(p)
    gpu.rect(0, 0, 16, 16)
    gpu.fill()
    check gpu.surf.pixels == cpu.surf.pixels
  else:
    skip()

test "metal backend shades radial paint on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let p = radialGradient(8, 8, 1, 8, rgbf(0, 0, 0), rgbf(1, 1, 1))
    var cpu = newCanvas(W, H)
    cpu.setFillPaint(p)
    cpu.rect(0, 0, 16, 16)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillPaint(p)
    gpu.rect(0, 0, 16, 16)
    gpu.fill()
    var maxDiff = 0
    for i in 0 ..< cpu.surf.pixels.len:
      let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 1
  else:
    skip()

test "metal backend shades box paint on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let p = boxGradient(8, 8, 5, 5, 2, 3, rgbf(0, 0, 0), rgbf(1, 1, 1))
    var cpu = newCanvas(W, H)
    cpu.setFillPaint(p)
    cpu.rect(2.5, 2.5, 11, 11)
    cpu.fill()
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    var gpu = newCanvas(W, H, mb)
    gpu.setFillPaint(p)
    gpu.rect(2.5, 2.5, 11, 11)
    gpu.fill()
    var maxDiff = 0
    for i in 0 ..< cpu.surf.pixels.len:
      let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
      if d > maxDiff:
        maxDiff = d
    check maxDiff <= 1
  else:
    skip()

test "metal backend shades pattern paints on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 8
    const H = 8
    var px = newSeq[uint8](4 * 4 * 4)
    for y in 0 ..< 4:
      for x in 0 ..< 4:
        let i = (y * 4 + x) * 4
        px[i] = uint8(x * 85)
        px[i + 1] = uint8(y * 85)
        px[i + 2] = 170u8
        px[i + 3] = 255u8
    let flagSets2: array[2, set[ImageFlag]] = [{ifNearest}, {}]
    for flags in flagSets2:
      let img = newImage(4, 4, flags, px)
      let p = imagePattern(img, 0, 0, 4, 4, 0.0, rgbf(1, 1, 1))
      var cpu = newCanvas(W, H)
      cpu.setFillPaint(p)
      cpu.rect(0.5, 0.5, 7, 7)
      cpu.fill()
      let mb = newMetalBackend(W, H)
      defer: mb.close()
      var gpu = newCanvas(W, H, mb)
      gpu.setFillPaint(p)
      gpu.rect(0.5, 0.5, 7, 7)
      gpu.fill()
      var maxDiff = 0
      for i in 0 ..< cpu.surf.pixels.len:
        let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 1
  else:
    skip()

test "metal backend shades blend ops on gpu":
  when defined(macosx) and defined(nvgMetal):
    const W = 16
    const H = 16
    let bar1 = [coSourceIn, coDestinationOver, coLighter, coXor,
      coMultiply, coScreen, coOverlay, coDarken, coColorDodge,
      coDifference, coExclusion]
    let bar2 = [coHue, coSaturation, coColor, coLuminosity]
    let backdrops = [rgbf(0.2, 0.5, 0.6), rgbaf(0.7, 0.7, 0.7, 0.5)]
    let paints = [
      solidPaint(rgbaf(1, 0, 0, 0.8)),
      linearGradient(0, 0, 16, 0, rgbf(0, 0, 0), rgbf(1, 1, 1)),
    ]
    let mb = newMetalBackend(W, H)
    defer: mb.close()
    for backdrop in backdrops:
      for paint in paints:
        for op in bar1:
          var cpu = newCanvas(W, H)
          cpu.clear(backdrop)
          cpu.setFillPaint(paint)
          cpu.setCompositeOp(op)
          cpu.rect(2.5, 2.5, 11, 11)
          cpu.fill()
          var gpu = newCanvas(W, H, mb)
          gpu.clear(backdrop)
          gpu.setFillPaint(paint)
          gpu.setCompositeOp(op)
          gpu.rect(2.5, 2.5, 11, 11)
          gpu.fill()
          var maxDiff = 0
          for i in 0 ..< cpu.surf.pixels.len:
            let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
            if d > maxDiff:
              maxDiff = d
          check maxDiff <= 1
        for op in bar2:
          var cpu = newCanvas(W, H)
          cpu.clear(backdrop)
          cpu.setFillPaint(paint)
          cpu.setCompositeOp(op)
          cpu.rect(2.5, 2.5, 11, 11)
          cpu.fill()
          var gpu = newCanvas(W, H, mb)
          gpu.clear(backdrop)
          gpu.setFillPaint(paint)
          gpu.setCompositeOp(op)
          gpu.rect(2.5, 2.5, 11, 11)
          gpu.fill()
          var maxDiff = 0
          for i in 0 ..< cpu.surf.pixels.len:
            let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
            if d > maxDiff:
              maxDiff = d
          check maxDiff <= 2
    # One stroked case through the op path.
    var cpu = newCanvas(W, H)
    cpu.clear(rgbf(0.2, 0.5, 0.6))
    cpu.setStrokeColor(rgbf(1, 1, 0))
    cpu.setStrokeWidth(3.0)
    cpu.setCompositeOp(coMultiply)
    cpu.rect(3.5, 3.5, 9, 9)
    cpu.stroke()
    var gpu = newCanvas(W, H, mb)
    gpu.clear(rgbf(0.2, 0.5, 0.6))
    gpu.setStrokeColor(rgbf(1, 1, 0))
    gpu.setStrokeWidth(3.0)
    gpu.setCompositeOp(coMultiply)
    gpu.rect(3.5, 3.5, 9, 9)
    gpu.stroke()
    var maxDiff = 0
    for i in 0 ..< cpu.surf.pixels.len:
      let d = abs(int(gpu.surf.pixels[i]) - int(cpu.surf.pixels[i]))
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

test "compute nearest pattern matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 8
    const H = 8
    var px = newSeq[uint8](4 * 4 * 4)
    for y in 0 ..< 4:
      for x in 0 ..< 4:
        let i = (y * 4 + x) * 4
        px[i] = uint8(x * 85)
        px[i + 1] = uint8(y * 85)
        px[i + 2] = 170u8
        px[i + 3] = 255u8
    let flagSets = [
      {ifNearest},
      {ifNearest, ifRepeatX, ifRepeatY},
      {ifNearest, ifFlipY},
    ]
    let geoms = [
      (0.0, 0.0, 4.0, 4.0, rgbf(1, 1, 1)),
      (0.0, 0.0, 2.0, 2.0, rgbf(1, 1, 1)),
      (1.5, 0.5, 4.0, 4.0, rgbaf(0.5, 0.5, 0.5, 1.0)),
    ]
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for flags in flagSets:
      let img = newImage(4, 4, flags, px)
      ctx.setPattern(img)
      for (ox, oy, ex, ey, tint) in geoms:
        let paint = imagePattern(img, ox, oy, ex, ey, 0.0, tint)
        ctx.fillPatternNearest(ox, oy, ex, ey, 0.0, tint, img)
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

test "cpu box blur hand computed":
  var s = newSurface(5, 5)
  s.clear(rgbf(0, 0, 0))
  s.setPixel(2, 2, rgbf(1, 1, 1))
  s.boxBlur(1)
  # Horizontal: row 2 becomes [0, 85, 85, 85, 0]; vertical folds to
  # (255+1)/9-style thirds: (0+85+0+1)/3 = 28 at the cross.
  check s.getPixel(2, 2).toRgba8() == (28u8, 28u8, 28u8, 255u8)
  check s.getPixel(1, 2).toRgba8() == (28u8, 28u8, 28u8, 255u8)
  check s.getPixel(2, 1).toRgba8() == (28u8, 28u8, 28u8, 255u8)
  check s.getPixel(0, 0).toRgba8() == (0u8, 0u8, 0u8, 255u8)
  check s.getPixel(4, 2).toRgba8() == (0u8, 0u8, 0u8, 255u8)
  var flat = newSurface(4, 3)
  flat.clear(rgbf(0.5, 0.25, 1.0))
  flat.boxBlur(2)
  check flat.getPixel(1, 1).toRgba8() == (128u8, 64u8, 255u8, 255u8)
  var noop = newSurface(2, 2)
  noop.clear(rgbf(1, 0, 0))
  noop.boxBlur(0)
  check noop.getPixel(0, 0).toRgba8() == (255u8, 0u8, 0u8, 255u8)

test "cpu box blur keeps hue at transparent edges":
  # Premultiplied averaging: a lone red pixel blurs to full-red at
  # low alpha, never a dark-red fringe.
  var s = newSurface(5, 5)
  s.clear(rgbaf(0, 0, 0, 0))
  s.setPixel(2, 2, rgbf(1, 0, 0))
  s.boxBlur(1)
  check s.getPixel(1, 1).toRgba8() == (255u8, 0u8, 0u8, 28u8)
  check s.getPixel(2, 2).toRgba8() == (255u8, 0u8, 0u8, 28u8)
  check s.getPixel(0, 0).toRgba8() == (0u8, 0u8, 0u8, 0u8)

test "cpu gaussian blur spreads monotonically":
  var s = newSurface(9, 9)
  s.clear(rgbaf(0, 0, 0, 0))
  s.setPixel(4, 4, rgbf(1, 1, 1))
  s.gaussianBlur(1.0)
  # Premultiplied spread keeps full-white hue; only alpha falls off.
  let c = s.getPixel(4, 4).toRgba8()
  check c == (255u8, 255u8, 255u8, c[3])
  check c[3] < 255u8 and c[3] > 0u8
  # Symmetric falloff along the row through the center.
  for dx in 1 .. 4:
    let l = s.getPixel(4 - dx, 4).toRgba8()
    let r = s.getPixel(4 + dx, 4).toRgba8()
    check l == r
  let g1 = s.getPixel(3, 4).toRgba8()
  let g2 = s.getPixel(2, 4).toRgba8()
  check g1[0] == 255u8
  check g1[3] >= g2[3]
  check s.getPixel(0, 0).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  var again = newSurface(9, 9)
  again.clear(rgbaf(0, 0, 0, 0))
  again.setPixel(4, 4, rgbf(1, 1, 1))
  again.gaussianBlur(1.0)
  check again.pixels == s.pixels
  var tiny = newSurface(3, 3)
  tiny.clear(rgbf(0, 1, 0))
  tiny.gaussianBlur(0.0)
  check tiny.getPixel(1, 1).toRgba8() == (0u8, 255u8, 0u8, 255u8)

test "compute box blur is byte-identical to cpu":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for radius in [1, 2, 3]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.boxBlur(radius)
      ctx.upload(s.pixels)
      ctx.boxBlur(radius)
      check ctx.readback() == cpu.pixels
  else:
    skip()

test "compute gaussian blur is byte-identical to cpu":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for sigma in [0.5, 1.5, 3.0]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.gaussianBlur(sigma)
      ctx.upload(s.pixels)
      ctx.gaussianBlur(sigma)
      check ctx.readback() == cpu.pixels
  else:
    skip()

test "cpu unsharp mask hand computed":
  var s = newSurface(3, 3)
  for y in 0 ..< 3:
    for x in 0 ..< 3:
      s.setPixel(x, y, rgb(100, 100, 100))
  s.setPixel(1, 1, rgb(150, 150, 150))
  s.unsharpMask(1, 1.0)
  check s.getPixel(1, 1).toRgba8() == (194u8, 194u8, 194u8, 255u8)
  # Corner darkens away from the bright center (local contrast boost:
  # blurred corner is 106, so 100 + (100 - 106) = 94).
  check s.getPixel(0, 0).toRgba8() == (94u8, 94u8, 94u8, 255u8)
  var flat = newSurface(2, 2)
  flat.clear(rgbaf(0.4, 0.2, 0.8, 0.6))
  flat.unsharpMask(1, 2.0)
  check flat.getPixel(0, 0).toRgba8() == (102u8, 51u8, 204u8, 153u8)
  var noop = newSurface(2, 2)
  noop.clear(rgbf(1, 0, 0))
  noop.unsharpMask(1, 0.0)
  check noop.getPixel(1, 1).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  noop.unsharpMask(0, 1.0)
  check noop.getPixel(1, 1).toRgba8() == (255u8, 0u8, 0u8, 255u8)

test "cpu unsharp mask keeps transparent transparent":
  var s = newSurface(3, 3)
  s.clear(rgbaf(0, 0, 0, 0))
  s.setPixel(1, 1, rgbf(1, 0, 0))
  s.unsharpMask(1, 1.0)
  check s.getPixel(1, 1).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(0, 0).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  check s.getPixel(0, 1).toRgba8()[3] == 0u8

test "compute unsharp mask matches cpu within 2 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for radius in [1, 2]:
      for amount in [0.5, 1.5]:
        var cpu = newSurface(W, H)
        for i in 0 ..< s.pixels.len:
          cpu.pixels[i] = s.pixels[i]
        cpu.unsharpMask(radius, amount)
        ctx.upload(s.pixels)
        ctx.unsharpMask(radius, amount)
        let got = ctx.readback()
        var maxDiff = 0
        for i in 0 ..< got.len:
          let d = abs(int(got[i]) - int(cpu.pixels[i]))
          if d > maxDiff:
            maxDiff = d
        check maxDiff <= 2
  else:
    skip()

test "cpu mosaic hand computed":
  var s = newSurface(4, 4)
  s.clear(rgbf(0, 0, 1))
  for y in 0 ..< 2:
    for x in 0 ..< 2:
      s.setPixel(x, y, rgbf(1, 0, 0))
  s.mosaic(2)
  check s.getPixel(0, 0).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(1, 1).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check s.getPixel(2, 0).toRgba8() == (0u8, 0u8, 255u8, 255u8)
  check s.getPixel(3, 3).toRgba8() == (0u8, 0u8, 255u8, 255u8)
  var p = newSurface(5, 5)
  p.clear(rgbf(0, 1, 0))
  p.setPixel(4, 4, rgbf(1, 1, 1))
  p.mosaic(2)
  check p.getPixel(4, 4).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check p.getPixel(0, 4).toRgba8() == (0u8, 255u8, 0u8, 255u8)
  var t = newSurface(2, 2)
  t.clear(rgbaf(0, 0, 0, 0))
  t.setPixel(0, 0, rgbf(1, 0, 0))
  t.mosaic(2)
  for y in 0 ..< 2:
    for x in 0 ..< 2:
      check t.getPixel(x, y).toRgba8() == (255u8, 0u8, 0u8, 64u8)
  var noop = newSurface(2, 2)
  noop.clear(rgbf(1, 0, 0))
  noop.mosaic(1)
  check noop.getPixel(0, 0).toRgba8() == (255u8, 0u8, 0u8, 255u8)
  noop.mosaic(0)
  check noop.getPixel(0, 0).toRgba8() == (255u8, 0u8, 0u8, 255u8)

test "compute mosaic is byte-identical to cpu":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for cell in [2, 3, 4]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.mosaic(cell)
      ctx.upload(s.pixels)
      ctx.mosaic(cell)
      check ctx.readback() == cpu.pixels
  else:
    skip()

test "compute bilinear pattern matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 8
    const H = 8
    var px = newSeq[uint8](4 * 4 * 4)
    for y in 0 ..< 4:
      for x in 0 ..< 4:
        let i = (y * 4 + x) * 4
        px[i] = uint8(x * 85)
        px[i + 1] = uint8(y * 85)
        px[i + 2] = 170u8
        px[i + 3] = 255u8
    px[(3 * 4 + 3) * 4 + 0] = 0u8
    px[(3 * 4 + 3) * 4 + 1] = 0u8
    px[(3 * 4 + 3) * 4 + 2] = 0u8
    px[(3 * 4 + 3) * 4 + 3] = 0u8
    px[(2 * 4 + 1) * 4 + 3] = 128u8
    let flagSets: array[3, set[ImageFlag]] = [
      {},
      {ifRepeatX, ifRepeatY},
      {ifFlipY},
    ]
    let geoms = [
      (0.0, 0.0, 4.0, 4.0, rgbf(1, 1, 1)),
      (0.0, 0.0, 2.0, 2.0, rgbf(1, 1, 1)),
      (1.5, 0.5, 4.0, 4.0, rgbaf(0.5, 0.5, 0.5, 1.0)),
    ]
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for flags in flagSets:
      let img = newImage(4, 4, flags, px)
      ctx.setPattern(img)
      for (ox, oy, ex, ey, tint) in geoms:
        let paint = imagePattern(img, ox, oy, ex, ey, 0.0, tint)
        ctx.fillPatternBilinear(ox, oy, ex, ey, 0.0, tint, img)
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

test "cpu mono noise hand computed":
  # Amount 0.004 quantizes to A = 1. hashPixel(0, 0, seed 0, salt 0)
  # is 0 (all terms zero, xorshift of 0 stays 0), so the uniform delta
  # there is 0 - 1 = -1: flat 100 drops to 99 on every channel.
  var s = newSurface(3, 3)
  s.clear(rgb(100, 100, 100))
  s.monoNoise(0.004, 0)
  check s.getPixel(0, 0).toRgba8() == (99u8, 99u8, 99u8, 255u8)
  for y in 0 ..< 3:
    for x in 0 ..< 3:
      let (r, g, b, a) = s.getPixel(x, y).toRgba8()
      check r == g
      check g == b
      check a == 255u8
      check r >= 99u8 and r <= 101u8
  var w = newSurface(1, 1)
  w.clear(rgb(255, 255, 255))
  w.monoNoise(0.004, 0)
  check w.getPixel(0, 0).toRgba8() == (254u8, 254u8, 254u8, 255u8)
  var b = newSurface(1, 1)
  b.clear(rgb(0, 0, 0))
  b.monoNoise(0.004, 0)
  check b.getPixel(0, 0).toRgba8() == (0u8, 0u8, 0u8, 255u8)
  var t = newSurface(2, 2)
  t.clear(rgbaf(0.5, 0.5, 0.5, 0.5))
  t.monoNoise(0.2, 7)
  for y in 0 ..< 2:
    for x in 0 ..< 2:
      check t.getPixel(x, y).toRgba8()[3] == 128u8
  var noop = newSurface(2, 2)
  noop.clear(rgb(100, 100, 100))
  noop.monoNoise(0.0, 0)
  check noop.getPixel(1, 1).toRgba8() == (100u8, 100u8, 100u8, 255u8)
  var n1 = newSurface(4, 4)
  n1.clear(rgb(100, 100, 100))
  n1.monoNoise(0.1, 3)
  var n2 = newSurface(4, 4)
  n2.clear(rgb(100, 100, 100))
  n2.monoNoise(0.1, 3)
  check n1.pixels == n2.pixels
  var n3 = newSurface(4, 4)
  n3.clear(rgb(100, 100, 100))
  n3.monoNoise(0.1, 4)
  check n1.pixels != n3.pixels
  var g = newSurface(4, 4)
  g.clear(rgb(100, 100, 100))
  g.monoNoise(0.1, 3, nkGaussian)
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      let (r, gg, bb, a) = g.getPixel(x, y).toRgba8()
      check r == gg
      check gg == bb
      check a == 255u8
      check abs(int(r) - 100) <= 26

test "cpu color noise decorrelates channels":
  var s = newSurface(4, 4)
  s.clear(rgb(100, 100, 100))
  s.colorNoise(0.1, 3)
  var differs = false
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      let (r, g, b, a) = s.getPixel(x, y).toRgba8()
      check a == 255u8
      check abs(int(r) - 100) <= 26
      check abs(int(g) - 100) <= 26
      check abs(int(b) - 100) <= 26
      if r != g or g != b:
        differs = true
  check differs
  var t = newSurface(2, 2)
  t.clear(rgbaf(0.5, 0.5, 0.5, 0.5))
  t.colorNoise(0.2, 7, nkGaussian)
  for y in 0 ..< 2:
    for x in 0 ..< 2:
      check t.getPixel(x, y).toRgba8()[3] == 128u8
  var noop = newSurface(2, 2)
  noop.clear(rgb(100, 100, 100))
  noop.colorNoise(0.0, 0)
  check noop.getPixel(0, 0).toRgba8() == (100u8, 100u8, 100u8, 255u8)

test "compute noise is byte-identical to cpu":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for kind in [nkUniform, nkGaussian]:
      for seed in [0u32, 7u32]:
        var cpu = newSurface(W, H)
        for i in 0 ..< s.pixels.len:
          cpu.pixels[i] = s.pixels[i]
        cpu.monoNoise(0.1, seed, kind)
        ctx.upload(s.pixels)
        ctx.monoNoise(0.1, seed, kind)
        check ctx.readback() == cpu.pixels
        for i in 0 ..< s.pixels.len:
          cpu.pixels[i] = s.pixels[i]
        cpu.colorNoise(0.1, seed, kind)
        ctx.upload(s.pixels)
        ctx.colorNoise(0.1, seed, kind)
        check ctx.readback() == cpu.pixels
  else:
    skip()

test "cpu ripple hand computed":
  # White dot at (2, 2) on 5x5 black, amp 1, period 4, phase 0:
  # sin(2*pi*[x|y]/4) is 0, 1, 0, -1 down each axis. Pixel (1, 1)
  # samples (1 + 1, 1 + 1) = (2, 2); (3, 3) samples (3 - 1, 3 - 1)
  # = (2, 2); (2, 2) samples itself (sin pi ~ 0). All three read
  # the dot exactly (integer centers, no blending).
  var s = newSurface(5, 5)
  s.clear(rgb(0, 0, 0))
  s.setPixel(2, 2, rgb(255, 255, 255))
  s.ripple(1.0, 4.0)
  check s.getPixel(1, 1).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(2, 2).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(3, 3).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(0, 0).toRgba8() == (0u8, 0u8, 0u8, 255u8)
  check s.getPixel(2, 1).toRgba8() == (0u8, 0u8, 0u8, 255u8)
  check s.getPixel(4, 4).toRgba8() == (0u8, 0u8, 0u8, 255u8)
  var noop = newSurface(3, 3)
  noop.clear(rgb(100, 100, 100))
  noop.ripple(0.0, 4.0)
  check noop.getPixel(1, 1).toRgba8() == (100u8, 100u8, 100u8, 255u8)
  noop.ripple(1.0, 0.0)
  check noop.getPixel(1, 1).toRgba8() == (100u8, 100u8, 100u8, 255u8)

test "cpu swirl keeps center and outside":
  var s = newSurface(5, 5)
  s.clear(rgb(0, 0, 0))
  s.setPixel(2, 2, rgb(255, 255, 255))
  s.setPixel(0, 2, rgb(255, 255, 255))
  s.setPixel(4, 0, rgb(255, 255, 255))
  s.swirl(2.0, 2.0, 2.0, 1.0)
  # Center maps to itself; d = 2 boundary and outside are exact
  # copies; (2, 1) at d = 1 rotates half a radian and lands
  # between pixels (strict gray).
  check s.getPixel(2, 2).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(0, 2).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  check s.getPixel(4, 0).toRgba8() == (255u8, 255u8, 255u8, 255u8)
  let v = s.getPixel(2, 1).toRgba8()[0]
  check v > 0u8 and v < 255u8
  var noop = newSurface(2, 2)
  noop.clear(rgb(100, 100, 100))
  noop.swirl(1.0, 1.0, 4.0, 0.0)
  check noop.getPixel(0, 0).toRgba8() == (100u8, 100u8, 100u8, 255u8)
  noop.swirl(1.0, 1.0, 0.0, 1.0)
  check noop.getPixel(0, 0).toRgba8() == (100u8, 100u8, 100u8, 255u8)

test "compute ripple and swirl match cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for (amp, period, phase) in [(1.5, 4.0, 0.0), (2.0, 6.0, 0.7)]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.ripple(amp, period, phase)
      ctx.upload(s.pixels)
      ctx.ripple(amp, period, phase)
      let got = ctx.readback()
      var maxDiff = 0
      for i in 0 ..< got.len:
        let d = abs(int(got[i]) - int(cpu.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 1
    for (cx, cy, radius, angle) in [(4.0, 3.0, 3.0, 1.0),
        (2.0, 2.0, 5.0, -0.5)]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.swirl(cx, cy, radius, angle)
      ctx.upload(s.pixels)
      ctx.swirl(cx, cy, radius, angle)
      let got = ctx.readback()
      var maxDiff = 0
      for i in 0 ..< got.len:
        let d = abs(int(got[i]) - int(cpu.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 1
  else:
    skip()

test "cpu turbulence is deterministic grayscale":
  var s = newSurface(8, 8)
  s.clear(rgbaf(0.2, 0.4, 0.6, 0.5))
  s.turbulence(4.0, 3, 11)
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      let (r, g, b, a) = s.getPixel(x, y).toRgba8()
      check r == g
      check g == b
      check a == 128u8
  var again = newSurface(8, 8)
  again.clear(rgbaf(0.2, 0.4, 0.6, 0.5))
  again.turbulence(4.0, 3, 11)
  check again.pixels == s.pixels
  var other = newSurface(8, 8)
  other.clear(rgbaf(0.2, 0.4, 0.6, 0.5))
  other.turbulence(4.0, 3, 12)
  check other.pixels != s.pixels
  # fBm normalization holds over a sweep.
  for y in countup(-8, 16, 4):
    for x in countup(-8, 16, 4):
      for oct in [1, 4, 8]:
        let n = fbm(float64(x) + 0.25, float64(y) - 0.5, 0.25,
          oct, 5)
        check n >= 0.0 and n <= 1.0
  var noop = newSurface(2, 2)
  noop.clear(rgb(100, 100, 100))
  noop.turbulence(0.0)
  check noop.getPixel(0, 0).toRgba8() == (100u8, 100u8, 100u8, 255u8)

test "cpu domain warp fixes flat images":
  var flat = newSurface(8, 8)
  flat.clear(rgb(100, 150, 200))
  flat.domainWarp(4.0, 3.0)
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      check flat.getPixel(x, y).toRgba8() ==
        (100u8, 150u8, 200u8, 255u8)
  var s = newSurface(16, 16)
  s.clear(rgb(0, 0, 0))
  s.setPixel(8, 8, rgb(255, 255, 255))
  s.domainWarp(4.0, 3.0, 4, 9)
  # The dot's energy leaves the center: (7,7)/(8,7)/(7,8) go
  # nonzero while (8,8) samples away from the dot.
  var moved = false
  for y in 0 ..< 16:
    for x in 0 ..< 16:
      if s.getPixel(x, y).toRgba8()[0] != 0u8:
        if x != 8 or y != 8:
          moved = true
  check moved
  check s.getPixel(8, 8).toRgba8()[0] == 0u8
  var a = newSurface(8, 8)
  a.clear(rgbaf(0.2, 0.4, 0.6, 0.5))
  a.domainWarp(4.0, 3.0, 4, 9)
  var b2 = newSurface(8, 8)
  b2.clear(rgbaf(0.2, 0.4, 0.6, 0.5))
  b2.domainWarp(4.0, 3.0, 4, 9)
  check a.pixels == b2.pixels
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      check a.getPixel(x, y).toRgba8()[3] == 128u8
  var noop = newSurface(2, 2)
  noop.clear(rgb(100, 100, 100))
  noop.domainWarp(4.0, 0.0)
  check noop.getPixel(0, 0).toRgba8() == (100u8, 100u8, 100u8, 255u8)
  noop.domainWarp(0.0, 3.0)
  check noop.getPixel(0, 0).toRgba8() == (100u8, 100u8, 100u8, 255u8)

test "compute turbulence and warp match cpu within 2 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for (scale, oct, seed) in [(4.0, 3, 11u32), (2.5, 5, 3u32)]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.turbulence(scale, oct, seed)
      ctx.upload(s.pixels)
      ctx.turbulence(scale, oct, seed)
      let got = ctx.readback()
      var maxDiff = 0
      for i in 0 ..< got.len:
        let d = abs(int(got[i]) - int(cpu.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 2
    for (scale, amp, seed) in [(4.0, 2.0, 9u32), (8.0, 1.5, 1u32)]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.domainWarp(scale, amp, 4, seed)
      ctx.upload(s.pixels)
      ctx.domainWarp(scale, amp, 4, seed)
      let got = ctx.readback()
      var maxDiff = 0
      for i in 0 ..< got.len:
        let d = abs(int(got[i]) - int(cpu.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 2
  else:
    skip()

test "cpu motion blur hand computed":
  # White dot at (2, 2) on 5x5 transparent black, 0 degrees (right),
  # taps 3, length 2: samples at x - 1, x, x + 1. Pixels (1, 2),
  # (2, 2), (3, 2) each average one white tap: full white at alpha
  # 255 / 3 = 85 (premultiplied hue preservation, like boxBlur).
  # (0, 2) samples only clamped black and stays transparent.
  var s = newSurface(5, 5)
  s.clear(rgbaf(0, 0, 0, 0))
  s.setPixel(2, 2, rgb(255, 255, 255))
  s.motionBlur(0.0, 2.0, 3)
  check s.getPixel(1, 2).toRgba8() == (255u8, 255u8, 255u8, 85u8)
  check s.getPixel(2, 2).toRgba8() == (255u8, 255u8, 255u8, 85u8)
  check s.getPixel(3, 2).toRgba8() == (255u8, 255u8, 255u8, 85u8)
  check s.getPixel(0, 2).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  check s.getPixel(2, 0).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  # 90 degrees runs down columns instead of across rows.
  var v = newSurface(5, 5)
  v.clear(rgbaf(0, 0, 0, 0))
  v.setPixel(2, 2, rgb(255, 255, 255))
  v.motionBlur(90.0, 2.0, 3)
  check v.getPixel(2, 1).toRgba8() == (255u8, 255u8, 255u8, 85u8)
  check v.getPixel(2, 2).toRgba8() == (255u8, 255u8, 255u8, 85u8)
  check v.getPixel(2, 3).toRgba8() == (255u8, 255u8, 255u8, 85u8)
  check v.getPixel(2, 0).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  check v.getPixel(1, 2).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  # Full circle: 360/180/720 coincide with 0, -90/270/450 with 90.
  proc dotBlur(deg: float64): Surface =
    result = newSurface(5, 5)
    result.clear(rgbaf(0, 0, 0, 0))
    result.setPixel(2, 2, rgb(255, 255, 255))
    result.motionBlur(deg, 2.0, 3)
  check dotBlur(360.0).pixels == s.pixels
  check dotBlur(180.0).pixels == s.pixels
  check dotBlur(720.0).pixels == s.pixels
  check dotBlur(-90.0).pixels == v.pixels
  check dotBlur(270.0).pixels == v.pixels
  check dotBlur(450.0).pixels == v.pixels
  # Translucent dot keeps its hue at averaged alpha.
  var t = newSurface(5, 5)
  t.clear(rgbaf(0, 0, 0, 0))
  t.setPixel(2, 2, rgbaf(1, 1, 1, 128.0 / 255.0))
  t.motionBlur(0.0, 2.0, 3)
  check t.getPixel(2, 2).toRgba8() == (255u8, 255u8, 255u8, 43u8)
  check t.getPixel(0, 2).toRgba8() == (0u8, 0u8, 0u8, 0u8)
  # Flat opaque images are fixed points; degenerate params no-op.
  var flat = newSurface(4, 4)
  flat.clear(rgb(100, 150, 200))
  flat.motionBlur(35.0, 5.0, 7)
  check flat.getPixel(1, 1).toRgba8() == (100u8, 150u8, 200u8, 255u8)
  flat.motionBlur(35.0, 0.0, 7)
  check flat.getPixel(1, 1).toRgba8() == (100u8, 150u8, 200u8, 255u8)
  flat.motionBlur(35.0, 5.0, 1)
  check flat.getPixel(1, 1).toRgba8() == (100u8, 150u8, 200u8, 255u8)

test "compute motion blur matches cpu within 1 lsb":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 9
    const H = 7
    var s = newSurface(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        s.setPixel(x, y, rgbaf(float64((x * 37 + y * 91) mod 256) / 255.0,
          float64((x * 53 + y * 29) mod 256) / 255.0,
          float64((x * 11 + y * 71) mod 256) / 255.0,
          float64((x * 17 + y * 13) mod 256) / 255.0))
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for (deg, length, taps) in [(35.0, 5.0, 7), (120.0, 3.0, 5),
        (270.0, 4.0, 9)]:
      var cpu = newSurface(W, H)
      for i in 0 ..< s.pixels.len:
        cpu.pixels[i] = s.pixels[i]
      cpu.motionBlur(deg, length, taps)
      ctx.upload(s.pixels)
      ctx.motionBlur(deg, length, taps)
      let got = ctx.readback()
      var maxDiff = 0
      for i in 0 ..< got.len:
        let d = abs(int(got[i]) - int(cpu.pixels[i]))
        if d > maxDiff:
          maxDiff = d
      check maxDiff <= 1
  else:
    skip()

test "cpu dominant colors hand computed":
  # 3 red + 1 blue: red wins on weight, blue second.
  var s = newSurface(4, 1)
  s.setPixel(0, 0, rgb(255, 0, 0))
  s.setPixel(1, 0, rgb(255, 0, 0))
  s.setPixel(2, 0, rgb(255, 0, 0))
  s.setPixel(3, 0, rgb(0, 0, 255))
  let pal = s.dominantColors(2)
  check pal.len == 2
  check pal[0].toRgba8() == (255u8, 0u8, 0u8, 255u8)
  check pal[1].toRgba8() == (0u8, 0u8, 255u8, 255u8)
  # Tie (1 red, 1 blue, equal opaque weight) breaks by ascending
  # packed bin key: blue key 31 < red key 31744.
  var tie = newSurface(2, 1)
  tie.setPixel(0, 0, rgb(255, 0, 0))
  tie.setPixel(1, 0, rgb(0, 0, 255))
  let tp = tie.dominantColors(2)
  check tp.len == 2
  check tp[0].toRgba8() == (0u8, 0u8, 255u8, 255u8)
  check tp[1].toRgba8() == (255u8, 0u8, 0u8, 255u8)
  # Fully transparent pixels are ignored.
  var tr = newSurface(4, 1)
  tr.setPixel(0, 0, rgb(255, 0, 0))
  tr.setPixel(1, 0, rgb(255, 0, 0))
  tr.setPixel(2, 0, rgbaf(0, 1, 0, 0))
  tr.setPixel(3, 0, rgbaf(0, 0, 1, 0))
  let rp = tr.dominantColors(3)
  check rp.len == 1
  check rp[0].toRgba8() == (255u8, 0u8, 0u8, 255u8)
  # Alpha weighting: one opaque red (weight 255) loses to two
  # half-transparent blues (2 * 128 = 256).
  var aw = newSurface(3, 1)
  aw.setPixel(0, 0, rgb(255, 0, 0))
  aw.setPixel(1, 0, rgbaf(0, 0, 1, 128.0 / 255.0))
  aw.setPixel(2, 0, rgbaf(0, 0, 1, 128.0 / 255.0))
  let ap = aw.dominantColors(2)
  check ap.len == 2
  check ap[0].toRgba8() == (0u8, 0u8, 255u8, 255u8)
  check ap[1].toRgba8() == (255u8, 0u8, 0u8, 255u8)
  # Nearby shades share a bin (250 and 255 both quantize to 31)
  # and report the average: (250 + 255) div 2 = 252.
  var q = newSurface(2, 1)
  q.setPixel(0, 0, rgb(250, 0, 0))
  q.setPixel(1, 0, rgb(255, 0, 0))
  let qp = q.dominantColors(5)
  check qp.len == 1
  check qp[0].toRgba8() == (252u8, 0u8, 0u8, 255u8)
  # n clamping: zero/negative empty, oversize returns unique set,
  # flat image returns one color.
  check s.dominantColors(0).len == 0
  check s.dominantColors(-3).len == 0
  check s.dominantColors(9).len == 2
  var flat = newSurface(3, 2)
  flat.clear(rgb(100, 150, 200))
  let fp = flat.dominantColors(4)
  check fp.len == 1
  check fp[0].toRgba8() == (100u8, 150u8, 200u8, 255u8)
