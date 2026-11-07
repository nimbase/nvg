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
