## JIT backend: pixel-identical output, faster.
##
## Compile with -d:nvgJit (normal builds skip the kernel builders so
## everyday compiles stay fast):
##   nim c -r -d:nvgJit examples/jit.nim [outDir]

import std/os
import std/times
import nvg

proc scene(c: Canvas) =
  c.clear(rgb(255, 255, 255))
  c.beginPath()
  c.rect(20.5, 20.5, 200, 140)
  c.setFillPaint(c.linearGradientStops(20, 20, 220, 160, [
    GradientStop(pos: 0.0, color: rgbf(1, 0, 0)),
    GradientStop(pos: 0.5, color: rgbf(0, 1, 0)),
    GradientStop(pos: 1.0, color: rgbf(0, 0, 1))]))
  c.fill()
  c.beginPath()
  c.circle(300, 150, 90)
  c.setFillPaint(c.radialGradient(300, 150, 10, 90,
    rgbf(1, 1, 0), rgbf(0.1, 0.1, 0.5)))
  c.fill()
  c.beginPath()
  c.star(200, 260, 60, 25, 5, 0.0)
  c.setFillColor(rgbaf(0.2, 0.2, 0.2, 0.85))
  c.fill()

proc main(outDir: string) =
  createDir(outDir)
  when not defined(nvgJit):
    echo "hint: rebuild with -d:nvgJit to use the JIT backend"
  let cpu = newCanvas(400, 320)
  let t0 = cpuTime()
  scene(cpu)
  let tCpu = cpuTime() - t0
  cpu.savePng(outDir / "jit_cpu.png")

  when defined(nvgJit):
    let jit = newCanvas(400, 320, newJitBackend())
    let t1 = cpuTime()
    scene(jit)
    let tJit = cpuTime() - t1
    jit.savePng(outDir / "jit_jit.png")
    var diff = 0
    for i in 0 ..< cpu.surface.pixels.len:
      if cpu.surface.pixels[i] != jit.surface.pixels[i]: inc diff
    echo "cpu: ", tCpu, "s jit: ", tJit, "s differing bytes: ", diff
    echo "wrote ", outDir / "jit_cpu.png and ", outDir / "jit_jit.png"
  else:
    echo "cpu: ", tCpu, "s"
    echo "wrote ", outDir / "jit_cpu.png"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "examples/out")
