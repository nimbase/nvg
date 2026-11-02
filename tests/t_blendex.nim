import std/unittest
import nvg

proc px(op: CompOp, src, dst: Color, cov = 1.0): Color =
  let s = newSurface(1, 1)
  s.clear(dst)
  s.blendPixel(0, 0, src, cov, op)
  s.getPixel(0, 0)

proc blendRef(mode: string, cs, cb: float64): float64 =
  case mode
  of "mul": cs * cb
  of "scr": cs + cb - cs * cb
  else:
    if cb <= 0.5: 2.0 * cs * cb
    else: 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)

proc expect(op: CompOp, src, dst: Color): tuple[r, g, b, a: float64] =
  ## Independent transcription of the blend-then-composite formula.
  let mode = if op == coMultiply: "mul"
    elif op == coScreen: "scr" else: "ovl"
  let br = blendRef(mode, src.r, dst.r)
  let bg = blendRef(mode, src.g, dst.g)
  let bb = blendRef(mode, src.b, dst.b)
  let sa = src.a
  let ab = dst.a
  let ao = sa + ab * (1.0 - sa)
  if ao <= 1e-6: return (0.0, 0.0, 0.0, 0.0)
  (((1.0 - ab) * sa * src.r + (1.0 - sa) * ab * dst.r + sa * ab * br) / ao,
    ((1.0 - ab) * sa * src.g + (1.0 - sa) * ab * dst.g + sa * ab * bg) / ao,
    ((1.0 - ab) * sa * src.b + (1.0 - sa) * ab * dst.b + sa * ab * bb) / ao,
    ao)

proc checkOp(op: CompOp, src, dst: Color) =
  let got = px(op, src, dst)
  let w = expect(op, src, dst)
  check abs(got.r - w.r) < 0.02
  check abs(got.g - w.g) < 0.02
  check abs(got.b - w.b) < 0.02
  check abs(got.a - w.a) < 0.02

test "multiply identities and opaque result":
  # White is identity, black clears.
  checkOp(coMultiply, rgbf(1, 1, 1), rgbaf(0.2, 0.4, 0.6, 1.0))
  checkOp(coMultiply, rgbf(0, 0, 0), rgbaf(0.2, 0.4, 0.6, 1.0))
  let got = px(coMultiply, rgbf(1, 0, 0), rgbf(0, 0, 1))
  check got.r < 0.02 and got.g < 0.02 and got.b < 0.02
  check abs(got.a - 1.0) < 0.02
  for src in [rgbaf(1, 0, 0, 1.0), rgbaf(0.3, 0.6, 0.9, 0.5),
      rgbaf(0, 0, 0, 0.0)]:
    for dst in [rgbaf(0, 0, 1, 1.0), rgbaf(0.9, 0.1, 0.4, 0.5),
        rgbaf(0, 0, 0, 0.0), rgbaf(1, 1, 1, 1.0)]:
      checkOp(coMultiply, src, dst)

test "screen identities and opaque result":
  # Black is identity, white fills.
  checkOp(coScreen, rgbf(0, 0, 0), rgbaf(0.2, 0.4, 0.6, 1.0))
  checkOp(coScreen, rgbf(1, 1, 1), rgbaf(0.2, 0.4, 0.6, 1.0))
  let got = px(coScreen, rgbf(1, 0, 0), rgbf(0, 0, 1))
  check abs(got.r - 1.0) < 0.02 and got.g < 0.02 and
    abs(got.b - 1.0) < 0.02
  for src in [rgbf(1, 1, 0), rgbaf(0.3, 0.6, 0.9, 0.5),
      rgbaf(1, 1, 1, 0.0)]:
    for dst in [rgbf(0, 1, 1), rgbaf(0.9, 0.1, 0.4, 0.5),
        rgbaf(0, 0, 0, 0.0), rgbaf(0, 0, 0, 1.0)]:
      checkOp(coScreen, src, dst)

test "overlay halves and opaque results":
  # Overlay black: doubles dark dst, 2Cb-1 on light dst.
  let dark = px(coOverlay, rgbf(0, 0, 0), rgbaf(0.25, 0.25, 0.25, 1.0))
  check dark.r < 0.02 and dark.g < 0.02 and dark.b < 0.02
  let light = px(coOverlay, rgbf(0, 0, 0), rgbaf(0.75, 0.75, 0.75, 1.0))
  check abs(light.r - 0.5) < 0.03
  for src in [rgbaf(1, 0, 0, 1.0), rgbaf(0.3, 0.6, 0.9, 0.5),
      rgbaf(1, 1, 1, 0.0)]:
    for dst in [rgbaf(0.2, 0.8, 0.5, 1.0), rgbaf(0.9, 0.1, 0.4, 0.5),
        rgbaf(0, 0, 0, 0.0), rgbaf(1, 1, 1, 1.0)]:
      checkOp(coOverlay, src, dst)

test "translucent pairs match hand-computed values":
  # Red@0.5 over blue@0.5 multiply: outA 0.75, rgb (1/3, 0, 1/3).
  let m = px(coMultiply, rgbaf(1, 0, 0, 0.5), rgbaf(0, 0, 1, 0.5))
  check abs(m.r - 1.0 / 3.0) < 0.02 and m.g < 0.02
  check abs(m.b - 1.0 / 3.0) < 0.02 and abs(m.a - 0.75) < 0.02
  # Same pair screened: (2/3, 0, 2/3).
  let s = px(coScreen, rgbaf(1, 0, 0, 0.5), rgbaf(0, 0, 1, 0.5))
  check abs(s.r - 2.0 / 3.0) < 0.02 and abs(s.b - 2.0 / 3.0) < 0.02

test "coverage scales the blend":
  let full = px(coMultiply, rgbaf(1, 1, 1, 1.0),
    rgbaf(0.2, 0.4, 0.6, 1.0))
  check abs(full.r - 0.2) < 0.03 # full coverage: identity
  let half = px(coMultiply, rgbaf(1, 1, 1, 1.0),
    rgbaf(0.2, 0.4, 0.6, 1.0), 0.5)
  # sa=0.5: halfway between dst and Bout=dst -> still dst here, so
  # use black src instead for a visible ramp.
  let ramp = px(coMultiply, rgbaf(0, 0, 0, 1.0),
    rgbaf(1.0, 1.0, 1.0, 1.0), 0.5)
  check abs(ramp.r - 0.5) < 0.03
  check half.r > 0.1

test "canvas composite op exposes the new modes":
  for op in [coMultiply, coScreen, coOverlay]:
    let c = newCanvas(10, 10)
    c.clear(rgbf(0, 0, 1))
    c.beginPath()
    c.rect(0, 0, 10, 10)
    c.setFillColor(rgbaf(1, 0, 0, 0.5))
    c.setCompositeOp(op)
    c.fill()
    let got = c.surface.getPixel(5, 5)
    let w = expect(op, rgbaf(1, 0, 0, 0.5), rgbf(0, 0, 1))
    check abs(got.r - w.r) < 0.03 and abs(got.b - w.b) < 0.03
