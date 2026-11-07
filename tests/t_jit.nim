import std/unittest
import std/random
import dynasm
import nvg
import nvg/jit

# JitBackend must be pixel-identical to CpuBackend on every path, and
# the row kernel must match blendPixel sample-for-sample.
#
# NOTE: unittest `check` inside a helper proc does NOT fail the test
# (it records a global failure and exits 1 with all [OK]). Helpers
# below return data only; every `check` below sits directly in a
# `test` body.

proc renderBoth(w, h: int,
    scene: proc(c: Canvas)): tuple[cpu, jit: seq[uint8]] =
  let cc = newCanvas(w, h)
  scene(cc)
  let cj = newCanvas(w, h, newJitBackend())
  scene(cj)
  (cc.surface.pixels, cj.surface.pixels)

proc diffStat(a, b: seq[uint8]): tuple[n: int, detail: string] =
  ## Count differing bytes; describe the first few (with pixel coords
  ## for a 4-bytes-per-pixel buffer).
  if a.len != b.len:
    return (high(int), "len " & $a.len & " vs " & $b.len)
  var shown = 0
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      inc result.n
      if shown < 5:
        result.detail.add("byte " & $i & " (px " & $(i div 4) &
          " ch " & $(i mod 4) & "): cpu=" & $a[i] & " jit=" & $b[i] & "\n")
        inc shown

proc checkScene(w, h: int, scene: proc(c: Canvas)): tuple[n: int,
    detail: string] =
  let (a, b) = renderBoth(w, h, scene)
  diffStat(a, b)

test "solid fills identical: opaque, translucent, overlap, AA edges":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.rect(32.5, 32, 96, 64)
    c.setFillColor(rgb(255, 0, 0))
    c.fill()
    c.beginPath()
    c.circle(180, 80, 40)
    c.setFillColor(rgbaf(0, 0, 1, 0.5))
    c.fill()
    c.beginPath()
    c.rect(100.25, 150.75, 80.5, 40.25)
    c.setFillColor(rgbaf(0.2, 0.8, 0.3, 0.75))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "solid strokes identical: joins, caps, width":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.rect(20, 20, 120, 60)
    c.setStrokeColor(rgbf(0, 0, 0))
    c.setStrokeWidth(6.0)
    c.setLineJoin(ljRound)
    c.setLineCap(lcRound)
    c.stroke()
    c.beginPath()
    c.moveTo(10.5, 200.5)
    c.lineTo(100.5, 220.5)
    c.lineTo(200.5, 190.5)
    c.setStrokeColor(rgbaf(0.8, 0.1, 0.1, 0.6))
    c.setStrokeWidth(3.0)
    c.setLineJoin(ljMiter)
    c.setLineCap(lcButt)
    c.stroke())
  if d.n > 0: echo d.detail
  check d.n == 0

test "clip, aa=false, transparent, empty identical":
  let d = checkScene(120, 120, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.rect(0, 0, 120, 120)
    c.setFillColor(rgbaf(1, 0, 0, 0.0)) # fully transparent: no-op
    c.fill()
    c.scissor(10, 10, 60, 60)
    c.beginPath()
    c.circle(40.5, 40.5, 30)
    c.setFillColor(rgbf(0, 1, 0))
    c.fill()
    c.resetScissor())
  if d.n > 0: echo d.detail
  check d.n == 0
  block:
    let cc = newCanvas(64, 64)
    let cj = newCanvas(64, 64, newJitBackend())
    for c in [cc, cj]:
      c.clear(rgb(0, 0, 0))
      c.beginPath()
      c.rect(10.5, 10.5, 20, 20)
      c.setFillColor(rgb(255, 255, 255))
      c.setShapeAA(false)
      c.fill()
    let e = diffStat(cc.surface.pixels, cj.surface.pixels)
    if e.n > 0: echo e.detail
    check e.n == 0

test "linear fills identical: axis, diagonal, clamp, degenerate, alpha":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    # Horizontal, opaque endpoints.
    c.beginPath()
    c.rect(10.5, 10, 100, 60)
    c.setFillPaint(c.linearGradient(10, 10, 110, 10,
      rgbf(1, 0, 0), rgbf(0, 0, 1)))
    c.fill()
    # Vertical, translucent endpoints + global alpha.
    c.setGlobalAlpha(0.6)
    c.beginPath()
    c.rect(130.5, 10, 100, 60)
    c.setFillPaint(c.linearGradient(130, 10, 130, 70,
      rgbaf(0, 1, 0, 1), rgbaf(0, 1, 0, 0.2)))
    c.fill()
    c.setGlobalAlpha(1.0)
    # Diagonal, endpoints far outside the shape (clamp both ends).
    c.beginPath()
    c.circle(80.5, 180.5, 45)
    c.setFillPaint(c.linearGradient(60, 160, 100, 200,
      rgbaf(2.0, -0.5, 0.5, 0.75), rgbaf(0.2, 0.4, 0.8, 0.9)))
    c.fill()
    # Degenerate (zero-length): solid icol everywhere.
    c.beginPath()
    c.rect(150.5, 150.5, 80, 60)
    c.setFillPaint(c.linearGradient(50, 50, 50, 50,
      rgbf(0.9, 0.1, 0.7), rgbf(0, 0, 0)))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "linear with transform identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.translate(30, 20)
    c.scale(1.5, 1.5)
    c.beginPath()
    c.rect(10, 10, 80, 60)
    c.setFillPaint(c.linearGradient(10, 10, 90, 70,
      rgbf(1, 1, 0), rgbf(0, 1, 1)))
    c.fill()
    c.resetTransform()
    c.rotate(0.3)
    c.beginPath()
    c.circle(150, 150, 40)
    c.setFillPaint(c.linearGradient(110, 150, 190, 150,
      rgbaf(1, 0, 1, 0.8), rgbaf(0, 0, 0, 0.3)))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "linear strokes identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.rect(20, 20, 120, 60)
    c.setStrokePaint(c.linearGradient(20, 20, 140, 80,
      rgbf(1, 0, 0), rgbf(0, 0, 1)))
    c.setStrokeWidth(8.0)
    c.setLineJoin(ljRound)
    c.setLineCap(lcRound)
    c.stroke()
    c.beginPath()
    c.moveTo(10.5, 200.5)
    c.lineTo(120.5, 220.5)
    c.lineTo(220.5, 190.5)
    c.setStrokePaint(c.linearGradient(10, 200, 220, 200,
      rgbaf(0, 0.8, 0, 0.9), rgbaf(0.8, 0, 0, 0.4)))
    c.setStrokeWidth(5.0)
    c.setLineJoin(ljMiter)
    c.setLineCap(lcButt)
    c.stroke())
  if d.n > 0: echo d.detail
  check d.n == 0

test "radial fills identical: rings, degenerate, alpha":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    # Centered disc, opaque core fading out.
    c.beginPath()
    c.circle(70.5, 70.5, 55)
    c.setFillPaint(c.radialGradient(70, 70, 5, 55,
      rgbf(1, 0, 0), rgbf(0, 0, 1)))
    c.fill()
    # Ring (inr > 0) with translucent endpoints + global alpha.
    c.setGlobalAlpha(0.6)
    c.beginPath()
    c.rect(130.5, 10.5, 110, 110)
    c.setFillPaint(c.radialGradient(185, 65, 20, 60,
      rgbaf(0, 1, 0, 1), rgbaf(0, 1, 0, 0.2)))
    c.fill()
    c.setGlobalAlpha(1.0)
    # Offset center, out-of-range endpoint colors (no result clamp).
    c.beginPath()
    c.circle(80.5, 190.5, 45)
    c.setFillPaint(c.radialGradient(60, 170, 0, 50,
      rgbaf(2.0, -0.5, 0.5, 0.75), rgbaf(0.2, 0.4, 0.8, 0.9)))
    c.fill()
    # Degenerate ring (inr == outr): feather floor keeps a transition.
    c.beginPath()
    c.rect(150.5, 150.5, 80, 60)
    c.setFillPaint(c.radialGradient(190, 180, 20, 20,
      rgbf(0.9, 0.1, 0.7), rgbf(0, 0, 0)))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "radial with transform identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.translate(30, 20)
    c.scale(1.5, 1.5)
    c.beginPath()
    c.rect(10, 10, 80, 60)
    c.setFillPaint(c.radialGradient(50, 40, 5, 45,
      rgbf(1, 1, 0), rgbf(0, 1, 1)))
    c.fill()
    c.resetTransform()
    c.rotate(0.3)
    c.beginPath()
    c.circle(150, 150, 40)
    c.setFillPaint(c.radialGradient(150, 150, 0, 40,
      rgbaf(1, 0, 1, 0.8), rgbaf(0, 0, 0, 0.3)))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "radial strokes identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.rect(20, 20, 120, 60)
    c.setStrokePaint(c.radialGradient(80, 50, 5, 70,
      rgbf(1, 0, 0), rgbf(0, 0, 1)))
    c.setStrokeWidth(8.0)
    c.setLineJoin(ljRound)
    c.setLineCap(lcRound)
    c.stroke()
    c.beginPath()
    c.moveTo(10.5, 200.5)
    c.lineTo(120.5, 220.5)
    c.lineTo(220.5, 190.5)
    c.setStrokePaint(c.radialGradient(120, 205, 0, 60,
      rgbaf(0, 0.8, 0, 0.9), rgbaf(0.8, 0, 0, 0.4)))
    c.setStrokeWidth(5.0)
    c.setLineJoin(ljMiter)
    c.setLineCap(lcButt)
    c.stroke())
  if d.n > 0: echo d.detail
  check d.n == 0

test "box fills identical: feathered, sharp, degenerate, alpha":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    # Feathered rounded box.
    c.beginPath()
    c.rect(10.5, 10.5, 100, 80)
    c.setFillPaint(c.boxGradient(10, 10, 100, 80, 12, 20,
      rgbf(1, 0, 0), rgbf(0, 0, 1)))
    c.fill()
    # Sharp corners (radius 0) + translucent endpoints + global alpha.
    c.setGlobalAlpha(0.6)
    c.beginPath()
    c.rect(130.5, 10.5, 110, 80)
    c.setFillPaint(c.boxGradient(130, 10, 110, 80, 0, 10,
      rgbaf(0, 1, 0, 1), rgbaf(0, 1, 0, 0.2)))
    c.fill()
    c.setGlobalAlpha(1.0)
    # Out-of-range endpoint colors (no result clamp) on a circle.
    c.beginPath()
    c.circle(80.5, 190.5, 45)
    c.setFillPaint(c.boxGradient(35, 145, 90, 90, 15, 25,
      rgbaf(2.0, -0.5, 0.5, 0.75), rgbaf(0.2, 0.4, 0.8, 0.9)))
    c.fill()
    # Degenerate feather (0 -> floor 1.0): hard step.
    c.beginPath()
    c.rect(150.5, 150.5, 80, 60)
    c.setFillPaint(c.boxGradient(150, 150, 80, 60, 8, 0,
      rgbf(0.9, 0.1, 0.7), rgbf(0, 0, 0)))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "box with transform identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.translate(30, 20)
    c.scale(1.5, 1.5)
    c.beginPath()
    c.rect(10, 10, 80, 60)
    c.setFillPaint(c.boxGradient(10, 10, 80, 60, 10, 15,
      rgbf(1, 1, 0), rgbf(0, 1, 1)))
    c.fill()
    c.resetTransform()
    c.rotate(0.3)
    c.beginPath()
    c.circle(150, 150, 40)
    c.setFillPaint(c.boxGradient(110, 110, 80, 80, 20, 25,
      rgbaf(1, 0, 1, 0.8), rgbaf(0, 0, 0, 0.3)))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "box strokes identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    c.beginPath()
    c.rect(20, 20, 120, 60)
    c.setStrokePaint(c.boxGradient(20, 20, 120, 60, 10, 15,
      rgbf(1, 0, 0), rgbf(0, 0, 1)))
    c.setStrokeWidth(8.0)
    c.setLineJoin(ljRound)
    c.setLineCap(lcRound)
    c.stroke()
    c.beginPath()
    c.moveTo(10.5, 200.5)
    c.lineTo(120.5, 220.5)
    c.lineTo(220.5, 190.5)
    c.setStrokePaint(c.boxGradient(10, 190, 210, 40, 5, 10,
      rgbaf(0, 0.8, 0, 0.9), rgbaf(0.8, 0, 0, 0.4)))
    c.setStrokeWidth(5.0)
    c.setLineJoin(ljMiter)
    c.setLineCap(lcButt)
    c.stroke())
  if d.n > 0: echo d.detail
  check d.n == 0

test "pattern-nearest fills identical: clamp, repeat, flip, tint":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255]
    # Clamp, axis-aligned tile.
    let idC = c.createImageRGBA(2, 2, {ifNearest}, data)
    c.beginPath()
    c.rect(10.5, 10.5, 100, 80)
    c.setFillPaint(c.imagePattern(0, 0, 50, 40, 0, idC, 1.0))
    c.fill()
    # Repeat both axes + flipY + rotation + tint, translucent.
    let idR = c.createImageRGBA(2, 2,
      {ifNearest, ifRepeatX, ifRepeatY, ifFlipY}, data)
    c.beginPath()
    c.rect(130.5, 10.5, 110, 80)
    c.setFillPaint(c.imagePattern(130, 10, 30, 25, 0.4, idR, 0.8))
    c.fill()
    # Global alpha over a rotated repeat pattern.
    c.setGlobalAlpha(0.6)
    c.beginPath()
    c.circle(80.5, 190.5, 45)
    c.setFillPaint(c.imagePattern(40, 150, 25, 25, 0.9, idR, 1.0))
    c.fill()
    c.setGlobalAlpha(1.0))
  if d.n > 0: echo d.detail
  check d.n == 0

test "pattern-nearest with transform identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255]
    let id = c.createImageRGBA(2, 2, {ifNearest, ifRepeatX, ifRepeatY},
      data)
    c.translate(30, 20)
    c.scale(1.5, 1.5)
    c.beginPath()
    c.rect(10, 10, 80, 60)
    c.setFillPaint(c.imagePattern(10, 10, 20, 20, 0.2, id, 1.0))
    c.fill()
    c.resetTransform()
    c.rotate(0.3)
    c.beginPath()
    c.circle(150, 150, 40)
    c.setFillPaint(c.imagePattern(120, 120, 30, 30, 0.0, id, 0.7))
    c.fill())
  if d.n > 0: echo d.detail
  check d.n == 0

test "pattern-nearest strokes identical":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255]
    let id = c.createImageRGBA(2, 2, {ifNearest, ifRepeatX, ifRepeatY},
      data)
    c.beginPath()
    c.rect(20, 20, 120, 60)
    c.setStrokePaint(c.imagePattern(20, 20, 30, 30, 0.3, id, 1.0))
    c.setStrokeWidth(8.0)
    c.setLineJoin(ljRound)
    c.setLineCap(lcRound)
    c.stroke()
    c.beginPath()
    c.moveTo(10.5, 200.5)
    c.lineTo(120.5, 220.5)
    c.lineTo(220.5, 190.5)
    c.setStrokePaint(c.imagePattern(10, 200, 40, 20, 0.0, id, 0.9))
    c.setStrokeWidth(5.0)
    c.setLineJoin(ljMiter)
    c.setLineCap(lcButt)
    c.stroke())
  if d.n > 0: echo d.detail
  check d.n == 0

test "multi-stop and bilinear identical: fills, strokes, hard stops":
  let d = checkScene(256, 256, proc(c: Canvas) =
    c.clear(rgb(255, 255, 255))
    # Bilinear pattern fill (JIT fast path).
    let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
      0, 0, 255, 255, 255, 255, 255, 255]
    let id = c.createImageRGBA(2, 2, {}, data)
    c.beginPath()
    c.rect(20.5, 20.5, 60, 60)
    c.setFillPaint(c.imagePattern(0, 0, 2, 2, 0, id, 1.0))
    c.fill()
    # Bilinear with repeat + rotation + tint.
    let idR = c.createImageRGBA(2, 2, {ifRepeatX, ifRepeatY}, data)
    c.beginPath()
    c.rect(100.5, 20.5, 80, 60)
    c.setFillPaint(c.imagePattern(100, 20, 25, 25, 0.5, idR, 0.8))
    c.fill()
    # Multi-stop linear with a hard stop (duplicate pos).
    c.beginPath()
    c.circle(100, 170, 45)
    c.setFillPaint(c.linearGradientStops(55, 170, 145, 170,
      [GradientStop(pos: 0.0, color: rgbf(0, 0, 1)),
        GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
        GradientStop(pos: 0.5, color: rgbf(1, 1, 0)),
        GradientStop(pos: 1.0, color: rgbf(1, 0, 0))]))
    c.fill()
    # Multi-stop radial, translucent + global alpha.
    c.setGlobalAlpha(0.7)
    c.beginPath()
    c.rect(170.5, 120.5, 70, 80)
    c.setFillPaint(c.radialGradientStops(205, 160, 5, 50,
      [GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.6, color: rgbaf(0, 1, 0, 0.4)),
        GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.9))]))
    c.fill()
    c.setGlobalAlpha(1.0)
    # Multi-stop linear stroke.
    c.beginPath()
    c.rect(20, 220, 120, 20)
    c.setStrokePaint(c.linearGradientStops(20, 220, 140, 240,
      [GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
        GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
        GradientStop(pos: 1.0, color: rgbf(0, 0, 1))]))
    c.setStrokeWidth(6.0)
    c.stroke())
  if d.n > 0: echo d.detail
  check d.n == 0

test "all comp ops identical: fills":
  const ops = [coSourceOver, coSourceIn, coSourceOut, coAtop,
    coDestinationOver, coDestinationIn, coDestinationOut,
    coDestinationAtop, coLighter, coCopy, coXor, coMultiply, coScreen,
    coOverlay, coDarken, coLighten, coColorDodge, coColorBurn,
    coHardLight, coSoftLight, coDifference, coExclusion, coHue,
    coSaturation, coColor, coLuminosity]
  var totalDiff = 0
  for op in ops:
    let d = checkScene(160, 120, proc(c: Canvas) =
      c.clear(rgbaf(0.2, 0.4, 0.8, 0.6))
      c.beginPath()
      c.rect(10.5, 10.5, 60, 50)
      c.setFillColor(rgbaf(1, 0.2, 0.2, 0.7))
      c.setCompositeOp(op)
      c.fill()
      c.beginPath()
      c.circle(110.5, 60.5, 35)
      c.setFillPaint(c.linearGradient(80, 60, 140, 60,
        rgbaf(0, 1, 0, 0.8), rgbaf(0, 0, 1, 0.3)))
      c.setCompositeOp(op)
      c.fill()
      c.beginPath()
      c.rect(10.5, 70.5, 60, 40)
      c.setFillPaint(c.radialGradient(40, 90, 5, 30,
        rgbaf(1, 1, 0, 0.9), rgbaf(1, 0, 1, 0.2)))
      c.setCompositeOp(op)
      c.fill())
    if d.n > 0 and totalDiff == 0:
      echo "op=", op, "\n", d.detail
    totalDiff += d.n
  check totalDiff == 0

test "all comp ops identical: strokes, box, pattern":
  const ops = [coSourceIn, coDestinationOut, coCopy, coMultiply,
    coOverlay, coXor]
  var totalDiff = 0
  for op in ops:
    let d = checkScene(160, 120, proc(c: Canvas) =
      c.clear(rgbaf(0.8, 0.8, 0.8, 1.0))
      let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 255, 255, 255, 255]
      let id = c.createImageRGBA(2, 2, {ifNearest, ifRepeatX,
        ifRepeatY}, data)
      c.beginPath()
      c.rect(10.5, 10.5, 60, 50)
      c.setStrokePaint(c.imagePattern(10, 10, 20, 20, 0.3, id, 0.9))
      c.setStrokeWidth(6.0)
      c.setLineJoin(ljRound)
      c.setCompositeOp(op)
      c.stroke()
      c.beginPath()
      c.circle(110.5, 60.5, 35)
      c.setFillPaint(c.boxGradient(80, 30, 60, 60, 8, 12,
        rgbaf(1, 0, 0, 0.8), rgbaf(0, 0, 1, 0.2)))
      c.setCompositeOp(op)
      c.fill())
    if d.n > 0 and totalDiff == 0:
      echo "op=", op, "\n", d.detail
    totalDiff += d.n
  check totalDiff == 0

test "destroy is safe and idempotent":
  let b = newJitBackend()
  let c = newCanvas(32, 32, b)
  c.clear(rgb(1, 2, 3))
  c.beginPath()
  c.rect(0, 0, 32, 32)
  c.setFillColor(rgb(4, 5, 6))
  c.fill()
  destroyJitBackend(b)
  destroyJitBackend(b) # second call must not crash
  check true

when defined(amd64) or defined(arm64) or defined(aarch64):
  test "row kernel matches blendPixel over colors x coverages":
    randomize(20240)
    let kern = JitKernels()
    let fn = kern.getSolid()
    check fn != nil
    let srcs = [rgbaf(1, 0, 0, 1), rgbaf(0, 1, 0, 0.5),
      rgbaf(0.2, 0.4, 0.8, 0.0), rgbaf(2.0, -0.5, 0.5, 0.75),
      rgbaf(0.33, 0.66, 0.99, 0.01), rgbaf(0, 0, 0, 1),
      rgbaf(1, 1, 1, 1)]
    var totalDiff = 0
    for src in srcs:
      for n in [0, 1, 2, 3, 7, 64]:
        var dst = newSeq[uint8](n * 4)
        var cov = newSeq[float64](max(n, 1))
        for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
        for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
        var ctx = bakeSolidCtx(src, 1.0)
        var got = dst
        if n > 0:
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
        var surf = newSurface(max(n, 1), 1)
        surf.pixels.setLen(dst.len)
        for i, b in dst: surf.pixels[i] = b
        for x in 0 ..< n:
          surf.blendPixel(x, 0, src, cov[x], coSourceOver)
        let dd = diffStat(got, surf.pixels)
        if dd.n > 0 and totalDiff == 0:
          echo "src=", src, " n=", n, "\n", dd.detail
        totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "row kernel alpha folding matches fill":
    # bakeSolidCtx(src, alpha) must equal per-pixel col.a * alpha.
    let kern = JitKernels()
    let fn = kern.getSolid()
    var dst = [10'u8, 20, 30, 40]
    var cov = [1.0]
    var totalDiff = 0
    for alpha in [0.0, 0.25, 1.0]:
      var ctx = bakeSolidCtx(rgbaf(1, 0, 0, 0.8), alpha)
      var got = dst
      var surf = newSurface(1, 1)
      surf.pixels = @dst
      if alpha * 0.8 > 0.0:
        fn(addr got[0], addr cov[0], 1, addr ctx)
        surf.blendPixel(0, 0, rgbaf(1, 0, 0, 0.8 * alpha), 1.0,
          coSourceOver)
        let dd = diffStat(@got, surf.pixels)
        if dd.n > 0 and totalDiff == 0:
          echo "alpha=", alpha, "\n", dd.detail
        totalDiff += dd.n
      else:
        if ctx.sa > 0.0:
          echo "expected skip at alpha=", alpha
          totalDiff += 1
    check totalDiff == 0
    kern.destroy()

  test "generic-op kernels match blendPixel over colors x coverages":
    # Op-specialized tails vs the scalar premultiplied math, including
    # out-of-range channels (scalar clamps), random translucent dst,
    # and tiny-alpha pixels exercising the ao <= 1e-6 zero branch.
    randomize(91827)
    const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
      coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
      coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
      coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion, coHue, coSaturation, coColor,
      coLuminosity]
    let kern = JitKernels()
    let srcs = [rgbaf(1, 0, 0, 1), rgbaf(0, 1, 0, 0.5),
      rgbaf(0.2, 0.4, 0.8, 0.0), rgbaf(2.0, -0.5, 0.5, 0.75),
      rgbaf(0.33, 0.66, 0.99, 0.01), rgbaf(0, 0, 0, 1),
      rgbaf(1, 1, 1, 1), rgbaf(1.0 / 255.0, 0, 0, 1.0 / 255.0),
      rgbaf(0.5, 0.5, 0.5, 0.003)]
    var totalDiff = 0
    for op in ops:
      let fn = kern.getSolid(op)
      check fn != nil
      for src in srcs:
        for n in [1, 3, 7, 32]:
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](n)
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n:
            cov[i] = [0.0, 0.02, 0.25, 0.5, 1.0][rand(4)]
          var ctx = bakeSolidCtx(src, 1.0)
          var got = dst
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(n, 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          for x in 0 ..< n:
            surf.blendPixel(x, 0, src, cov[x], op)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "op=", op, " src=", src, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "linear generic-op kernel matches sample+blend":
    # Head+tail integration for one gradient shape; other shapes get
    # class coverage (Porter-Duff, blend, clearing) in the scene tests
    # above plus the solid sweep proving every tail branch.
    randomize(55121)
    const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
      coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
      coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
      coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion, coHue, coSaturation, coColor,
      coLuminosity]
    let kern = JitKernels()
    let p = linearGradient(10, 20, 300, 400,
      rgbaf(2.0, -0.5, 0.5, 0.75), rgbaf(0.2, 0.4, 0.8, 0.0))
    var totalDiff = 0
    for op in ops:
      let fn = kern.getLinear(op)
      check fn != nil
      for alpha in [1.0, 0.4]:
        for n in [1, 7, 32]:
          var ctx = bakeLinearCtx(p, alpha)
          let rowY = 7.5
          ctx.rowX = 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](n)
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(n, 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i], op)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "op=", op, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "clearing-op gates run the kernel instead of skipping":
    # Transparent sources clear under coDestinationIn/coCopy (not a
    # no-op), so the skippable gates must not fire; global alpha 0
    # still skips (scalar fillPolys returns early for every op).
    for op in [coSourceIn, coSourceOut, coDestinationIn,
        coDestinationAtop, coCopy]:
      let cc = newCanvas(20, 20)
      let cj = newCanvas(20, 20, newJitBackend())
      for c in [cc, cj]:
        c.clear(rgbaf(0, 0, 1, 1.0))
        c.beginPath()
        c.rect(0, 0, 20, 20)
        c.setFillColor(rgbaf(1, 0, 0, 0.0)) # transparent, clears
        c.setCompositeOp(op)
        c.fill()
      let d = diffStat(cc.surface.pixels, cj.surface.pixels)
      if d.n > 0: echo "op=", op, "\n", d.detail
      check d.n == 0
      # Region actually cleared (gate did not skip on either backend).
      check cc.surface.getPixel(10, 10).a < 0.05
    # Global alpha 0: no-op on both (scalar early-out).
    for op in [coCopy, coDestinationIn]:
      let cc = newCanvas(20, 20)
      let cj = newCanvas(20, 20, newJitBackend())
      for c in [cc, cj]:
        c.clear(rgbaf(0, 0, 1, 1.0))
        c.beginPath()
        c.rect(0, 0, 20, 20)
        c.setFillColor(rgbaf(1, 0, 0, 1.0))
        c.setGlobalAlpha(0.0)
        c.setCompositeOp(op)
        c.fill()
      let d = diffStat(cc.surface.pixels, cj.surface.pixels)
      check d.n == 0
      check cc.surface.getPixel(10, 10).b > 0.9

  test "pattern runnable gate falls back for nil images":
    # Nil-image patterns sample transparent: under clearing ops that
    # clears, so the backend must take the scalar path (the kernel
    # dereferences the image). Identical output, no crash.
    for op in [coSourceOver, coDestinationIn, coCopy]:
      let cc = newCanvas(20, 20)
      let cj = newCanvas(20, 20, newJitBackend())
      for c in [cc, cj]:
        c.clear(rgbaf(0, 0, 1, 1.0))
        c.beginPath()
        c.rect(0, 0, 20, 20)
        c.setFillPaint(c.imagePattern(0, 0, 4, 4, 0, 999, 1.0))
        c.setCompositeOp(op)
        c.fill()
      let d = diffStat(cc.surface.pixels, cj.surface.pixels)
      if d.n > 0: echo "op=", op, "\n", d.detail
      check d.n == 0
    var data = @[255'u8, 0, 0, 255]
    let img = newImage(1, 1, {ifNearest}, data)
    check not patternRunnable(imagePattern(nil, 0, 0, 8, 8, 0.0))
    check patternRunnable(imagePattern(img, 0, 0, 8, 8, 0.0))
    check not patternRunnable(imagePattern(img, 0, 0, 0, 8, 0.0))

  test "linear row kernel matches sample+blend":
    randomize(77031)
    let kern = JitKernels()
    let fn = kern.getLinear()
    check fn != nil
    var paints: seq[Paint] = @[
      linearGradient(0, 0, 800, 0, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 0.25)),
      linearGradient(10, 20, 300, 400, rgbaf(2.0, -0.5, 0.5, 0.75),
        rgbaf(0.2, 0.4, 0.8, 0.0)),
      linearGradient(50, 50, 50, 50, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 1))]
    var mapped = linearGradient(0, 0, 100, 50,
      rgbaf(0.33, 0.66, 0.99, 0.01), rgbaf(0, 0, 0, 1))
    mapped.map = [2.0, 0.5, -0.25, 1.5, 5.0, -3.0]
    paints.add(mapped)
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [10, 0, 100, 40][pi]
          let y = [0, 7, 50, 40][pi]
          var ctx = bakeLinearCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "linear skippable gate matches fill":
    var p = linearGradient(0, 0, 100, 0, rgbaf(1, 0, 0, 0.0),
      rgbaf(0, 0, 1, 0.0))
    check bakeLinearCtx(p, 1.0).linearSkippable()
    check bakeLinearCtx(p, 0.0).linearSkippable()
    var q = linearGradient(0, 0, 100, 0, rgbaf(1, 0, 0, 1.0),
      rgbaf(0, 0, 1, 0.0))
    check not bakeLinearCtx(q, 1.0).linearSkippable()
    check bakeLinearCtx(q, 0.0).linearSkippable()

  test "radial row kernel matches sample+blend":
    randomize(55021)
    let kern = JitKernels()
    let fn = kern.getRadial()
    check fn != nil
    var paints: seq[Paint] = @[
      radialGradient(100, 100, 5, 60, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 0.25)),
      radialGradient(0, 0, 0, 40, rgbaf(2.0, -0.5, 0.5, 0.75),
        rgbaf(0.2, 0.4, 0.8, 0.0)),
      radialGradient(50, 50, 20, 20, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 1)),
      radialGradient(50, 50, 30, 10, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 1))]
    var mapped = radialGradient(0, 0, 10, 50,
      rgbaf(0.33, 0.66, 0.99, 0.01), rgbaf(0, 0, 0, 1))
    mapped.map = [2.0, 0.5, -0.25, 1.5, 5.0, -3.0]
    paints.add(mapped)
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [60, 0, 40, 40, 100][pi]
          let y = [100, 7, 40, 40, 50][pi]
          var ctx = bakeRadialCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "radial skippable gate matches fill":
    var p = radialGradient(0, 0, 5, 50, rgbaf(1, 0, 0, 0.0),
      rgbaf(0, 0, 1, 0.0))
    check bakeRadialCtx(p, 1.0).radialSkippable()
    check bakeRadialCtx(p, 0.0).radialSkippable()
    var q = radialGradient(0, 0, 5, 50, rgbaf(1, 0, 0, 1.0),
      rgbaf(0, 0, 1, 0.0))
    check not bakeRadialCtx(q, 1.0).radialSkippable()
    check bakeRadialCtx(q, 0.0).radialSkippable()

  test "box row kernel matches sample+blend":
    randomize(88014)
    let kern = JitKernels()
    let fn = kern.getBox()
    check fn != nil
    var paints: seq[Paint] = @[
      boxGradient(100, 100, 60, 40, 10, 20, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 0.25)),
      boxGradient(0, 0, 50, 50, 0, 1, rgbaf(2.0, -0.5, 0.5, 0.75),
        rgbaf(0.2, 0.4, 0.8, 0.0)),
      boxGradient(50, 50, 30, 30, 5, 0, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 1)),
      boxGradient(50, 50, 10, 10, 30, 8, rgbaf(1, 0, 0, 1),
        rgbaf(0, 0, 1, 1))]
    var mapped = boxGradient(0, 0, 40, 30, 5, 15,
      rgbaf(0.33, 0.66, 0.99, 0.01), rgbaf(0, 0, 0, 1))
    mapped.map = [2.0, 0.5, -0.25, 1.5, 5.0, -3.0]
    paints.add(mapped)
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [60, 0, 40, 40, 100][pi]
          let y = [100, 7, 40, 40, 50][pi]
          var ctx = bakeBoxCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "box skippable gate matches fill":
    var p = boxGradient(0, 0, 50, 50, 10, 20, rgbaf(1, 0, 0, 0.0),
      rgbaf(0, 0, 1, 0.0))
    check bakeBoxCtx(p, 1.0).boxSkippable()
    check bakeBoxCtx(p, 0.0).boxSkippable()
    var q = boxGradient(0, 0, 50, 50, 10, 20, rgbaf(1, 0, 0, 1.0),
      rgbaf(0, 0, 1, 0.0))
    check not bakeBoxCtx(q, 1.0).boxSkippable()
    check bakeBoxCtx(q, 0.0).boxSkippable()

  test "pattern-nearest row kernel matches sample+blend":
    randomize(19283)
    var data = newSeq[uint8](7 * 5 * 4)
    for i in 0 ..< data.len: data[i] = uint8(rand(255))
    let kern = JitKernels()
    let fn = kern.getPattern()
    check fn != nil
    var paints: seq[Paint] = @[
      imagePattern(newImage(7, 5, {ifNearest}, data), 0, 0, 8, 8, 0.0),
      imagePattern(newImage(7, 5, {ifNearest, ifRepeatX, ifRepeatY}, data),
        0, 0, 8, 8, 0.0),
      imagePattern(newImage(7, 5, {ifNearest, ifFlipY}, data),
        0, 0, 8, 8, 0.0),
      imagePattern(newImage(4, 6,
        {ifNearest, ifRepeatX, ifRepeatY, ifFlipY}, data),
        10, 20, 30, 25, 0.7, rgbaf(0.9, 0.5, 0.2, 0.8))]
    var mapped = imagePattern(
      newImage(7, 5, {ifNearest, ifRepeatX}, data), 0, 0, 8, 8, 0.3)
    mapped.map = [2.0, 0.5, -0.25, 1.5, 5.0, -3.0]
    paints.add(mapped)
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [3, -20, 3, 0, 100][pi]
          let y = [2, -15, 2, 7, 50][pi]
          if patternSkippable(p, alpha): continue
          var ctx = bakePatternCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "pattern skippable gate matches fill":
    var data = @[255'u8, 0, 0, 255]
    let img = newImage(1, 1, {ifNearest}, data)
    check patternSkippable(imagePattern(nil, 0, 0, 8, 8, 0.0), 1.0)
    check patternSkippable(imagePattern(img, 0, 0, 0, 8, 0.0), 1.0)
    check patternSkippable(
      imagePattern(img, 0, 0, 8, 8, 0.0, rgbaf(1, 1, 1, 0.0)), 1.0)
    check patternSkippable(imagePattern(img, 0, 0, 8, 8, 0.0), 0.0)
    check not patternSkippable(imagePattern(img, 0, 0, 8, 8, 0.0), 1.0)

when defined(amd64):
  # Multi-stop and bilinear kernels exist for x64 only; AArch64 uses
  # the scalar fallback (covered by the CPU-side suites).
  test "multi-linear row kernel matches sample+blend":
    randomize(31415)
    let kern = JitKernels()
    let fn = kern.getMultiLinear()
    check fn != nil
    var paints: seq[Paint] = @[
      linearGradientStops(0, 0, 800, 0, [
        GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.5, color: rgbaf(0, 1, 0, 0.5)),
        GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.25))]),
      linearGradientStops(10, 20, 300, 400, [
        GradientStop(pos: 0.0, color: rgbaf(2.0, -0.5, 0.5, 0.75)),
        GradientStop(pos: 0.4, color: rgbaf(0.2, 0.4, 0.8, 0.0)),
        GradientStop(pos: 0.4, color: rgbaf(1, 1, 0, 0.5)),
        GradientStop(pos: 1.0, color: rgbaf(0, 1, 0, 0.9))]),
      linearGradientStops(50, 50, 50, 50, [
        GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.7, color: rgbaf(0, 1, 0, 1)),
        GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 1))]),
      linearGradientStops(0, 0, 100, 0, [
        GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
        GradientStop(pos: 0.0, color: rgbf(0, 1, 0)),
        GradientStop(pos: 1.0, color: rgbf(0, 0, 1))]),
      linearGradientStops(0, 0, 100, 0, [
        GradientStop(pos: 0.5, color: rgbaf(1, 0, 0, 0.8))])]
    var mapped = linearGradientStops(0, 0, 100, 50, [
      GradientStop(pos: 0.0, color: rgbaf(0.33, 0.66, 0.99, 0.01)),
      GradientStop(pos: 0.3, color: rgbaf(0.5, 0.1, 0.9, 0.6)),
      GradientStop(pos: 1.0, color: rgbaf(0, 0, 0, 1))])
    mapped.map = [2.0, 0.5, -0.25, 1.5, 5.0, -3.0]
    paints.add(mapped)
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [10, 0, 100, -10, 40, 100][pi]
          let y = [0, 7, 50, 0, 40, 50][pi]
          var ctx = bakeMultiLinearCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "multi-linear generic-op kernel matches sample+blend":
    randomize(27182)
    const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
      coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
      coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
      coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion, coHue, coSaturation, coColor,
      coLuminosity]
    let kern = JitKernels()
    let p = linearGradientStops(10, 20, 300, 400, [
      GradientStop(pos: 0.0, color: rgbaf(2.0, -0.5, 0.5, 0.75)),
      GradientStop(pos: 0.4, color: rgbaf(0.2, 0.4, 0.8, 0.0)),
      GradientStop(pos: 0.4, color: rgbaf(1, 1, 0, 0.5)),
      GradientStop(pos: 1.0, color: rgbaf(0, 1, 0, 0.9))])
    var totalDiff = 0
    for op in ops:
      let fn = kern.getMultiLinear(op)
      check fn != nil
      for alpha in [1.0, 0.4]:
        for n in [1, 7, 32]:
          var ctx = bakeMultiLinearCtx(p, alpha)
          let rowY = 7.5
          ctx.rowX = 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](n)
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(n, 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i], op)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "op=", op, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "multi skippable gates match fill":
    var p = linearGradientStops(0, 0, 100, 0, [
      GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 0.0)),
      GradientStop(pos: 0.5, color: rgbaf(0, 0, 1, 0.0)),
      GradientStop(pos: 1.0, color: rgbaf(0, 1, 0, 0.0))])
    check multiLinearSkippable(p, 1.0)
    check multiLinearSkippable(p, 0.0)
    var q = linearGradientStops(0, 0, 100, 0, [
      GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1.0)),
      GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.0))])
    check not multiLinearSkippable(q, 1.0)
    check multiLinearSkippable(q, 0.0)
    check multiLinearSkippable(
      linearGradientStops(0, 0, 100, 0, []), 1.0)
    var r = radialGradientStops(0, 0, 5, 50, [
      GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 0.0)),
      GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.0))])
    check multiRadialSkippable(r, 1.0)
    var s = radialGradientStops(0, 0, 5, 50, [
      GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1.0)),
      GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.0))])
    check not multiRadialSkippable(s, 1.0)
    var b = boxGradientStops(0, 0, 50, 50, 10, 20, [
      GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 0.0)),
      GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.0))])
    check multiBoxSkippable(b, 1.0)
    check multiBoxSkippable(b, 0.0)
    var c = boxGradientStops(0, 0, 50, 50, 10, 20, [
      GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1.0)),
      GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.0))])
    check not multiBoxSkippable(c, 1.0)
    check multiBoxSkippable(c, 0.0)
    check multiBoxSkippable(
      boxGradientStops(0, 0, 50, 50, 10, 20, []), 1.0)

  test "multi-radial row kernel matches sample+blend":
    randomize(80808)
    let kern = JitKernels()
    let fn = kern.getMultiRadial()
    check fn != nil
    var paints: seq[Paint] = @[
      radialGradientStops(100, 100, 5, 60, [
        GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.5, color: rgbaf(0, 1, 0, 0.5)),
        GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.25))]),
      radialGradientStops(0, 0, 0, 40, [
        GradientStop(pos: 0.0, color: rgbaf(2.0, -0.5, 0.5, 0.75)),
        GradientStop(pos: 1.0, color: rgbaf(0.2, 0.4, 0.8, 0.0))]),
      radialGradientStops(50, 50, 30, 10, [
        GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.3, color: rgbaf(0, 0, 1, 0.2)),
        GradientStop(pos: 1.0, color: rgbaf(0, 1, 0, 1))])]
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [60, 0, 40][pi]
          let y = [100, 7, 40][pi]
          var ctx = bakeMultiRadialCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "multi-radial generic-op kernel matches sample+blend":
    randomize(60617)
    const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
      coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
      coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
      coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion, coHue, coSaturation, coColor,
      coLuminosity]
    let kern = JitKernels()
    let p = radialGradientStops(50, 50, 10, 60, [
      GradientStop(pos: 0.0, color: rgbaf(2.0, -0.5, 0.5, 0.75)),
      GradientStop(pos: 0.5, color: rgbaf(0.2, 0.4, 0.8, 0.2)),
      GradientStop(pos: 1.0, color: rgbaf(0, 1, 0, 0.9))])
    var totalDiff = 0
    for op in ops:
      let fn = kern.getMultiRadial(op)
      check fn != nil
      for alpha in [1.0, 0.4]:
        for n in [1, 7, 32]:
          var ctx = bakeMultiRadialCtx(p, alpha)
          let rowY = 50.5
          ctx.rowX = 5.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](n)
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(n, 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(5 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i], op)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "op=", op, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "multi-box row kernel matches sample+blend":
    randomize(70707)
    let kern = JitKernels()
    let fn = kern.getMultiBox()
    check fn != nil
    var paints: seq[Paint] = @[
      boxGradientStops(100, 100, 60, 40, 10, 20, [
        GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.5, color: rgbaf(0, 1, 0, 0.5)),
        GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.25))]),
      boxGradientStops(0, 0, 50, 50, 0, 1, [
        GradientStop(pos: 0.0, color: rgbaf(2.0, -0.5, 0.5, 0.75)),
        GradientStop(pos: 1.0, color: rgbaf(0.2, 0.4, 0.8, 0.0))]),
      boxGradientStops(50, 50, 30, 30, 40, 8, [
        GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 1)),
        GradientStop(pos: 0.5, color: rgbaf(0, 0, 1, 0.2)),
        GradientStop(pos: 0.5, color: rgbaf(0, 1, 0, 0.9)),
        GradientStop(pos: 1.0, color: rgbaf(1, 1, 1, 1))])]
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [60, 0, 20][pi]
          let y = [100, 7, 50][pi]
          var ctx = bakeMultiBoxCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "multi-box generic-op kernel matches sample+blend":
    randomize(60618)
    const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
      coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
      coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
      coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion, coHue, coSaturation, coColor,
      coLuminosity]
    let kern = JitKernels()
    let p = boxGradientStops(50, 50, 40, 30, 8, 15, [
      GradientStop(pos: 0.0, color: rgbaf(2.0, -0.5, 0.5, 0.75)),
      GradientStop(pos: 0.5, color: rgbaf(0.2, 0.4, 0.8, 0.2)),
      GradientStop(pos: 1.0, color: rgbaf(0, 1, 0, 0.9))])
    var totalDiff = 0
    for op in ops:
      let fn = kern.getMultiBox(op)
      check fn != nil
      for alpha in [1.0, 0.4]:
        for n in [1, 7, 32]:
          var ctx = bakeMultiBoxCtx(p, alpha)
          let rowY = 50.5
          ctx.rowX = 5.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](n)
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(n, 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(5 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i], op)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "op=", op, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "pattern-bilinear row kernel matches sample+blend":
    randomize(50505)
    var data = newSeq[uint8](7 * 5 * 4)
    for i in 0 ..< data.len: data[i] = uint8(rand(255))
    let kern = JitKernels()
    let fn = kern.getPatternBilinear()
    check fn != nil
    var paints: seq[Paint] = @[
      imagePattern(newImage(7, 5, {}, data), 0, 0, 8, 8, 0.0),
      imagePattern(newImage(7, 5, {ifRepeatX, ifRepeatY}, data),
        0, 0, 8, 8, 0.0),
      imagePattern(newImage(7, 5, {ifFlipY}, data),
        0, 0, 8, 8, 0.0),
      imagePattern(newImage(4, 6,
        {ifRepeatX, ifRepeatY, ifFlipY}, data),
        10, 20, 30, 25, 0.7, rgbaf(0.9, 0.5, 0.2, 0.8))]
    var mapped = imagePattern(
      newImage(7, 5, {ifRepeatX}, data), 0, 0, 8, 8, 0.3)
    mapped.map = [2.0, 0.5, -0.25, 1.5, 5.0, -3.0]
    paints.add(mapped)
    var totalDiff = 0
    for pi, p in paints:
      for alpha in [1.0, 0.4]:
        for n in [0, 1, 2, 3, 7, 64]:
          let x0 = [3, -20, 3, 0, 100][pi]
          let y = [2, -15, 2, 7, 50][pi]
          if patternSkippable(p, alpha): continue
          var ctx = bakePatternCtx(p, alpha)
          let rowY = float64(y) + 0.5
          ctx.rowX = float64(x0) + 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](max(n, 1))
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          if n > 0:
            fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(max(n, 1), 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(x0 + i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i],
              coSourceOver)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "paint=", pi, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "pattern-bilinear generic-op kernel matches sample+blend":
    randomize(70707)
    const ops = [coSourceIn, coSourceOut, coAtop, coDestinationOver,
      coDestinationIn, coDestinationOut, coDestinationAtop, coLighter,
      coCopy, coXor, coMultiply, coScreen, coOverlay, coDarken,
      coLighten, coColorDodge, coColorBurn, coHardLight, coSoftLight,
      coDifference, coExclusion, coHue, coSaturation, coColor,
      coLuminosity]
    var data = newSeq[uint8](6 * 4 * 4)
    for i in 0 ..< data.len: data[i] = uint8(rand(255))
    let kern = JitKernels()
    let p = imagePattern(newImage(6, 4, {ifRepeatX, ifRepeatY}, data),
      5, 5, 20, 15, 0.5, rgbaf(0.9, 0.8, 0.7, 0.85))
    var totalDiff = 0
    for op in ops:
      let fn = kern.getPatternBilinear(op)
      check fn != nil
      for alpha in [1.0, 0.4]:
        for n in [1, 7, 32]:
          var ctx = bakePatternCtx(p, alpha)
          let rowY = 7.5
          ctx.rowX = 0.5
          ctx.m2y = p.map[2] * rowY
          ctx.m3y = p.map[3] * rowY
          var dst = newSeq[uint8](n * 4)
          var cov = newSeq[float64](n)
          for i in 0 ..< dst.len: dst[i] = uint8(rand(255))
          for i in 0 ..< n: cov[i] = [0.0, 0.25, 0.5, 1.0][rand(3)]
          var got = dst
          fn(addr got[0], addr cov[0], int64(n), addr ctx)
          var surf = newSurface(n, 1)
          surf.pixels.setLen(dst.len)
          for i, b in dst: surf.pixels[i] = b
          let aA = clamp01(alpha)
          for i in 0 ..< n:
            let col = p.sample(float64(i) + 0.5, rowY)
            surf.blendPixel(i, 0,
              color(col.r, col.g, col.b, col.a * aA), cov[i], op)
          let dd = diffStat(got, surf.pixels)
          if dd.n > 0 and totalDiff == 0:
            echo "op=", op, " alpha=", alpha, " n=", n, "\n", dd.detail
          totalDiff += dd.n
    check totalDiff == 0
    kern.destroy()

  test "all comp ops identical: multi-stop and bilinear fills":
    const ops = [coSourceOver, coSourceIn, coSourceOut, coAtop,
      coDestinationOver, coDestinationIn, coDestinationOut,
      coDestinationAtop, coLighter, coCopy, coXor, coMultiply, coScreen,
      coOverlay, coDarken, coLighten, coColorDodge, coColorBurn,
      coHardLight, coSoftLight, coDifference, coExclusion, coHue,
    coSaturation, coColor, coLuminosity]
    var totalDiff = 0
    for op in ops:
      let d = checkScene(160, 120, proc(c: Canvas) =
        c.clear(rgbaf(0.2, 0.4, 0.8, 0.6))
        let data = @[255'u8, 0, 0, 255, 0, 255, 0, 255,
          0, 0, 255, 255, 255, 255, 255, 255]
        let id = c.createImageRGBA(2, 2, {ifRepeatX, ifRepeatY}, data)
        c.beginPath()
        c.rect(10.5, 10.5, 60, 50)
        c.setFillPaint(c.imagePattern(10, 10, 20, 20, 0.3, id, 0.9))
        c.setCompositeOp(op)
        c.fill()
        c.beginPath()
        c.circle(110.5, 60.5, 35)
        c.setFillPaint(c.linearGradientStops(80, 60, 140, 60,
          [GradientStop(pos: 0.0, color: rgbaf(0, 1, 0, 0.8)),
            GradientStop(pos: 0.5, color: rgbaf(1, 1, 0, 0.5)),
            GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.3))]))
        c.setCompositeOp(op)
        c.fill()
        c.beginPath()
        c.rect(10.5, 70.5, 60, 40)
        c.setFillPaint(c.radialGradientStops(40, 90, 5, 30,
          [GradientStop(pos: 0.0, color: rgbaf(1, 1, 0, 0.9)),
            GradientStop(pos: 1.0, color: rgbaf(1, 0, 1, 0.2))]))
        c.setCompositeOp(op)
        c.fill()
        c.beginPath()
        c.rect(90.5, 75.5, 55, 35)
        c.setFillPaint(c.boxGradientStops(90, 75, 55, 35, 8, 12,
          [GradientStop(pos: 0.0, color: rgbaf(1, 0, 0, 0.9)),
            GradientStop(pos: 0.5, color: rgbaf(0, 1, 0, 0.6)),
            GradientStop(pos: 1.0, color: rgbaf(0, 0, 1, 0.3))]))
        c.setCompositeOp(op)
        c.fill())
      if d.n > 0 and totalDiff == 0:
        echo "op=", op, "\n", d.detail
      totalDiff += d.n
    check totalDiff == 0

test "aarch64 kernel assembles":
  # Bytes-only on non-ARM hosts; on AArch64 the sweep tests above
  # execute these kernels against the scalar oracle.
  var buf = buildSolidRowAarch64()
  let ok = buf.len > 100
  buf.destroy()
  var lbuf = buildLinearRowAarch64()
  let lok = lbuf.len > 100
  lbuf.destroy()
  var rbuf = buildRadialRowAarch64()
  let rok = rbuf.len > 100
  rbuf.destroy()
  var bbuf = buildBoxRowAarch64()
  let bok = bbuf.len > 100
  bbuf.destroy()
  var pbuf = buildPatternRowAarch64()
  let pok = pbuf.len > 100
  pbuf.destroy()
  check ok and lok and rok and bok and pok

test "aarch64 generic kernels assemble":
  # Every tail branch is covered via solid x all ops; each remaining
  # head is covered x one op per class (Porter-Duff, blend, clearing).
  # Heads and tails share only the documented register contract (tails
  # write every scratch before reading; entry regs are head-provided),
  # so per-head single-class plus per-op solid coverage is complete.
  template genOk(call: untyped): bool =
    block:
      var bb = call
      let good = bb.len > 100
      bb.destroy()
      good
  var n = 0
  if genOk(buildSolidRowGenAarch64(coSourceIn)): inc n
  if genOk(buildSolidRowGenAarch64(coSourceOut)): inc n
  if genOk(buildSolidRowGenAarch64(coAtop)): inc n
  if genOk(buildSolidRowGenAarch64(coDestinationOver)): inc n
  if genOk(buildSolidRowGenAarch64(coDestinationIn)): inc n
  if genOk(buildSolidRowGenAarch64(coDestinationOut)): inc n
  if genOk(buildSolidRowGenAarch64(coDestinationAtop)): inc n
  if genOk(buildSolidRowGenAarch64(coLighter)): inc n
  if genOk(buildSolidRowGenAarch64(coCopy)): inc n
  if genOk(buildSolidRowGenAarch64(coXor)): inc n
  if genOk(buildSolidRowGenAarch64(coMultiply)): inc n
  if genOk(buildSolidRowGenAarch64(coScreen)): inc n
  if genOk(buildSolidRowGenAarch64(coOverlay)): inc n
  if genOk(buildSolidRowGenAarch64(coDarken)): inc n
  if genOk(buildSolidRowGenAarch64(coLighten)): inc n
  if genOk(buildSolidRowGenAarch64(coColorDodge)): inc n
  if genOk(buildSolidRowGenAarch64(coColorBurn)): inc n
  if genOk(buildSolidRowGenAarch64(coHardLight)): inc n
  if genOk(buildSolidRowGenAarch64(coSoftLight)): inc n
  if genOk(buildSolidRowGenAarch64(coDifference)): inc n
  if genOk(buildSolidRowGenAarch64(coExclusion)): inc n
  if genOk(buildSolidRowGenAarch64(coHue)): inc n
  if genOk(buildSolidRowGenAarch64(coSaturation)): inc n
  if genOk(buildSolidRowGenAarch64(coColor)): inc n
  if genOk(buildSolidRowGenAarch64(coLuminosity)): inc n
  if genOk(buildLinearRowGenAarch64(coAtop)): inc n
  if genOk(buildLinearRowGenAarch64(coMultiply)): inc n
  if genOk(buildLinearRowGenAarch64(coCopy)): inc n
  if genOk(buildRadialRowGenAarch64(coAtop)): inc n
  if genOk(buildRadialRowGenAarch64(coMultiply)): inc n
  if genOk(buildRadialRowGenAarch64(coCopy)): inc n
  if genOk(buildBoxRowGenAarch64(coAtop)): inc n
  if genOk(buildBoxRowGenAarch64(coMultiply)): inc n
  if genOk(buildBoxRowGenAarch64(coCopy)): inc n
  if genOk(buildPatternRowGenAarch64(coAtop)): inc n
  if genOk(buildPatternRowGenAarch64(coMultiply)): inc n
  if genOk(buildPatternRowGenAarch64(coCopy)): inc n
  check n == 37
