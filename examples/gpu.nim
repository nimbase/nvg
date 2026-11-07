## GPU showcase: every backend feature in one scene (Metal backend).
##
## Combines multi-stop/radial/box gradients, solid shapes, nearest and
## bilinear image patterns, strokes (caps/joins/dashes), a blend-op
## gallery, global alpha, scissoring, stateful and stateless text with
## gradient fills and outlines, plus a box-blurred copy.
##
## Forced Metal: everything renders through `newMetalBackend`, so this
## example needs the define (wired automatically by examples/config.nims):
##   nim c -r -d:nvgMetal examples/gpu.nim -- /path/to/font.ttf [outDir]
## The font path can also come from the TEXT_FONT environment variable.
## On machines without a Metal device it exits after a short notice.

import std/os
import nvg
import nvg/metal

when not defined(nvgMetal):
  {.error: "gpu example forces the Metal backend: rebuild with -d:nvgMetal".}

proc checkerPixels(): seq[uint8] =
  result = newSeq[uint8](8 * 8 * 4)
  for y in 0 ..< 8:
    for x in 0 ..< 8:
      let i = (y * 8 + x) * 4
      if (x + y) mod 2 == 0:
        result[i] = 220u8
        result[i + 1] = 60u8
        result[i + 2] = 60u8
        result[i + 3] = 255u8
      else:
        result[i] = 245u8
        result[i + 1] = 245u8
        result[i + 2] = 245u8
        result[i + 3] = 255u8

proc label(c: Canvas, x, y: float64, s: string) =
  c.setFontSize(13.0)
  c.setTextAlign(thaCenter, tvaTop)
  c.setLetterSpacing(1.0)
  c.setFillColor(rgbf(0.25, 0.25, 0.25))
  discard c.fillText(x, y, s)

proc main(fontPath, outDir: string) =
  createDir(outDir)
  if not mtlAvailable():
    quit "gpu example needs a Metal device"
  let mb = newMetalBackend(760, 624)
  defer: mb.close()
  let c = newCanvas(760, 624, mb)

  let id = c.createFont("demo", fontPath)
  if id == 0:
    quit "cannot load font: " & fontPath
  c.setFontFace("demo")

  # Sky: multi-stop vertical gradient.
  c.setFillPaint(c.linearGradientStops(0, 0, 0, 340, [
    GradientStop(pos: 0.0, color: rgbf(0.05, 0.10, 0.30)),
    GradientStop(pos: 0.55, color: rgbf(0.20, 0.45, 0.65)),
    GradientStop(pos: 0.82, color: rgbf(0.95, 0.75, 0.50)),
    GradientStop(pos: 1.0, color: rgbf(0.98, 0.90, 0.70)),
  ]))
  c.beginPath()
  c.rect(0, 0, 760, 340)
  c.fill()

  # Sun glow (screen) plus sun disc (radial).
  c.setCompositeOp(coScreen)
  c.setFillPaint(c.radialGradient(560, 110, 4, 78,
    rgbaf(1.0, 0.9, 0.6, 0.9), rgbaf(1.0, 0.8, 0.4, 0.0)))
  c.beginPath()
  c.circle(560, 110, 78)
  c.fill()
  c.setCompositeOp(coSourceOver)
  c.setFillPaint(c.radialGradient(560, 110, 4, 46,
    rgbf(1.0, 0.97, 0.85), rgbf(1.0, 0.78, 0.35)))
  c.beginPath()
  c.circle(560, 110, 46)
  c.fill()

  # Dashed orbit ring around the sun.
  c.save()
  c.setLineDash([10.0, 6.0])
  c.setStrokeColor(rgbaf(1.0, 1.0, 1.0, 0.7))
  c.setStrokeWidth(2.0)
  c.beginPath()
  c.ellipse(560, 110, 100, 64)
  c.stroke()
  c.restore()

  # Mountains: solid AA polygons.
  c.beginPath()
  c.moveTo(0, 340)
  c.lineTo(150, 140)
  c.lineTo(300, 340)
  c.closePath()
  c.setFillColor(rgbf(0.25, 0.30, 0.40))
  c.fill()
  c.beginPath()
  c.moveTo(220, 340)
  c.lineTo(380, 180)
  c.lineTo(540, 340)
  c.closePath()
  c.setFillColor(rgbf(0.36, 0.43, 0.53))
  c.fill()

  # Mist band with global alpha.
  c.setGlobalAlpha(0.18)
  c.setFillColor(rgbf(1.0, 1.0, 1.0))
  c.beginPath()
  c.rect(0, 300, 760, 44)
  c.fill()
  c.setGlobalAlpha(1.0)

  # Lake: box gradient.
  c.setFillPaint(c.boxGradient(0, 340, 760, 120, 20, 40,
    rgbf(0.10, 0.25, 0.45), rgbf(0.35, 0.60, 0.75)))
  c.beginPath()
  c.rect(0, 340, 760, 120)
  c.fill()
  # Multiply ripple.
  c.setCompositeOp(coMultiply)
  c.setFillColor(rgbaf(0.55, 0.70, 0.85, 0.8))
  c.beginPath()
  c.ellipse(380, 400, 200, 28)
  c.fill()
  c.setCompositeOp(coSourceOver)

  # Meadow strip.
  c.setFillPaint(c.linearGradient(0, 460, 0, 500,
    rgbf(0.25, 0.50, 0.20), rgbf(0.45, 0.68, 0.30)))
  c.beginPath()
  c.rect(0, 460, 760, 40)
  c.fill()

  # River: round caps and joins.
  c.beginPath()
  c.moveTo(300, 340)
  c.lineTo(340, 380)
  c.lineTo(320, 420)
  c.lineTo(360, 462)
  c.setStrokeColor(rgbf(0.50, 0.75, 0.95))
  c.setStrokeWidth(9.0)
  c.setLineCap(lcRound)
  c.setLineJoin(ljRound)
  c.stroke()

  # Flag: mast plus nearest-repeat checker sail.
  c.setStrokeColor(rgbf(0.35, 0.22, 0.12))
  c.setStrokeWidth(6.0)
  c.setLineCap(lcButt)
  c.beginPath()
  c.moveTo(622, 180)
  c.lineTo(622, 332)
  c.stroke()
  let checker = c.createImageRGBA(8, 8,
    {ifNearest, ifRepeatX, ifRepeatY}, checkerPixels())
  c.setFillPaint(c.imagePattern(622, 180, 16, 16, 0.0, checker, 1.0))
  c.beginPath()
  c.moveTo(622, 180)
  c.lineTo(702, 206)
  c.lineTo(622, 236)
  c.closePath()
  c.fill()

  # Medallion: bilinear pattern circle.
  let soft = c.createImageRGBA(8, 8, {ifRepeatX, ifRepeatY},
    checkerPixels())
  c.setFillPaint(c.imagePattern(60, 384, 18, 18, 0.0, soft, 1.0))
  c.beginPath()
  c.circle(96, 420, 34)
  c.fill()
  c.setStrokeColor(rgbf(0.95, 0.95, 0.95))
  c.setStrokeWidth(3.0)
  c.beginPath()
  c.circle(96, 420, 34)
  c.stroke()

  # Title with shadow plus gradient fill, subtitle with spacing.
  c.setFontSize(46.0)
  c.setTextAlign(thaCenter, tvaTop)
  c.setLetterSpacing(1.0)
  c.setFillColor(rgbaf(0.0, 0.0, 0.0, 0.45))
  discard c.fillText(382, 24, "Metal Peaks")
  c.setFillPaint(c.linearGradient(0, 20, 0, 70,
    rgbf(1.0, 0.95, 0.80), rgbf(1.0, 0.65, 0.25)))
  discard c.fillText(380, 22, "Metal Peaks")
  c.setFontSize(17.0)
  c.setLetterSpacing(3.0)
  c.setFillColor(rgbf(1.0, 1.0, 1.0))
  discard c.fillText(380, 74, "every backend feature in one scene")
  c.setLetterSpacing(0.0)

  # Outlined text over the lake plus a stateless call.
  c.setFontSize(24.0)
  c.setTextAlign(thaCenter, tvaMiddle)
  c.setStrokeColor(rgbf(1.0, 1.0, 1.0))
  c.setStrokeWidth(1.5)
  discard c.strokeText(380, 430, "vector water")
  let font = loadFontFile(fontPath)
  c.setFillColor(rgbf(0.10, 0.10, 0.10))
  discard c.fillText(font, 15.0, 380, 478, "stateless caption",
    thaCenter, tvaTop)

  # Blend gallery over a black-to-white strip.
  c.setFillPaint(c.linearGradient(20, 0, 740, 0,
    rgbf(0, 0, 0), rgbf(1, 1, 1)))
  c.beginPath()
  c.rect(20, 500, 720, 80)
  c.fill()
  const ops = [coMultiply, coScreen, coOverlay, coColorDodge, coColor,
    coLuminosity]
  const opNames = ["multiply", "screen", "overlay", "dodge", "color",
    "luminosity"]
  for i, op in ops:
    let x = 30.0 + float64(i) * 118.0
    c.save()
    c.scissor(x, 500, 100, 80)
    c.beginPath()
    c.circle(x + 32, 532, 24)
    c.setFillColor(rgbaf(1.0, 0.25, 0.2, 0.8))
    c.setCompositeOp(op)
    c.fill()
    c.beginPath()
    c.rect(x + 42, 540, 40, 40)
    c.setFillColor(rgbaf(0.2, 0.8, 0.3, 0.8))
    c.setCompositeOp(op)
    c.fill()
    c.restore()
    c.setCompositeOp(coSourceOver)
    label(c, x + 50, 584, opNames[i])

  c.savePng(outDir / "gpu.png")
  echo "wrote ", outDir / "gpu.png"
  c.surf.boxBlur(2)
  c.savePng(outDir / "gpu_blurred.png")
  echo "wrote ", outDir / "gpu_blurred.png"

when isMainModule:
  var fontPath = getEnv("TEXT_FONT")
  var outDir = "examples/out"
  if paramCount() > 0:
    fontPath = paramStr(1)
  if paramCount() > 1:
    outDir = paramStr(2)
  if fontPath == "":
    quit "usage: gpu [font.ttf] [outDir]  (or set TEXT_FONT)"
  main(fontPath, outDir)
