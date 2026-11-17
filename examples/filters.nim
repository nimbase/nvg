## Filter showcase: grain, ripple, swirl, motion blur, turbulence and
## domain warp on a synthetic scene (no photo needed).
##
## Run: nim c -r examples/filters.nim [outDir]

import std/os
import nvg

proc scene(): Canvas =
  result = newCanvas(480, 360)
  result.clear(rgb(24, 28, 40))
  # Sky gradient band.
  result.beginPath()
  result.rect(0, 0, 480, 200)
  result.setFillPaint(result.linearGradient(0, 0, 0, 200,
    rgbf(0.15, 0.3, 0.7), rgbf(0.6, 0.8, 1.0)))
  result.fill()
  # Sun with translucent halo (exercises alpha under filters).
  result.beginPath()
  result.circle(380, 70, 60)
  result.setFillColor(rgbaf(1.0, 0.85, 0.3, 0.35))
  result.fill()
  result.beginPath()
  result.circle(380, 70, 34)
  result.setFillColor(rgbf(1.0, 0.9, 0.4))
  result.fill()
  # Striped hills (directional filters read well on stripes).
  for i in 0 ..< 12:
    result.beginPath()
    result.rect(float64(i * 40), 200, 20, 160)
    result.setFillColor(rgbf(0.1 + 0.02 * float64(i), 0.45, 0.2))
    result.fill()
  result.beginPath()
  result.circle(120, 260, 70)
  result.setFillColor(rgbaf(0.9, 0.2, 0.2, 0.85))
  result.fill()
  result.beginPath()
  result.rect(280, 230, 150, 90)
  result.setFillColor(rgbaf(0.2, 0.7, 0.9, 0.7))
  result.fill()

proc fresh(base: Surface): Surface =
  result = newSurface(base.w, base.h)
  for i in 0 ..< base.pixels.len:
    result.pixels[i] = base.pixels[i]

proc main(outDir: string) =
  createDir(outDir)
  let base = scene().surface
  block:
    let s = fresh(base)
    s.monoNoise(0.12, 3)
    s.savePng(outDir / "filters_grain_mono.png")
    echo "wrote ", outDir / "filters_grain_mono.png"
  block:
    let s = fresh(base)
    s.colorNoise(0.12, 3)
    s.savePng(outDir / "filters_grain_color.png")
    echo "wrote ", outDir / "filters_grain_color.png"
  block:
    let s = fresh(base)
    s.monoNoise(0.12, 3, nkGaussian)
    s.savePng(outDir / "filters_grain_soft.png")
    echo "wrote ", outDir / "filters_grain_soft.png"
  block:
    let s = fresh(base)
    s.ripple(4.0, 48.0)
    s.savePng(outDir / "filters_ripple.png")
    echo "wrote ", outDir / "filters_ripple.png"
  block:
    let s = fresh(base)
    s.swirl(240.0, 180.0, 130.0, 1.1)
    s.savePng(outDir / "filters_swirl.png")
    echo "wrote ", outDir / "filters_swirl.png"
  block:
    let s = fresh(base)
    s.motionBlur(25.0, 14.0)
    s.savePng(outDir / "filters_motion_25.png")
    echo "wrote ", outDir / "filters_motion_25.png"
  block:
    let s = fresh(base)
    s.motionBlur(115.0, 14.0)
    s.savePng(outDir / "filters_motion_115.png")
    echo "wrote ", outDir / "filters_motion_115.png"
  block:
    let s = fresh(base)
    s.turbulence(48.0, 4, 7)
    s.savePng(outDir / "filters_turbulence.png")
    echo "wrote ", outDir / "filters_turbulence.png"
  block:
    let s = fresh(base)
    s.domainWarp(48.0, 9.0, 4, 7)
    s.savePng(outDir / "filters_warp.png")
    echo "wrote ", outDir / "filters_warp.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
