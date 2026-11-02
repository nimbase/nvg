# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "Pure Nim antialiased 2D vector drawing library (NanoVG-inspired)"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.4.0"
requires "dynasm >= 0.1.0"

task test, "Run nvg tests":
  exec "nim c -r --hints:off --path:src tests/test1.nim"
  exec "nim c -r --hints:off --path:src tests/t_core.nim"
  exec "nim c -r --hints:off --path:src tests/t_slice.nim"
  exec "nim c -r --hints:off --path:src tests/t_path.nim"
  exec "nim c -r --hints:off --path:src tests/t_stroke.nim"
  exec "nim c -r --hints:off --path:src tests/t_paint.nim"
  exec "nim c -r --hints:off --path:src tests/t_comp.nim"
  exec "nim c -r --hints:off --path:src tests/t_perf.nim"
  exec "nim c -r --hints:off --path:src tests/t_jit.nim"
  exec "nim c -r --hints:off --path:src tests/t_fillrule.nim"
  exec "nim c -r --hints:off --path:src tests/t_multistop.nim"
  exec "nim c -r --hints:off --path:src tests/t_dash.nim"
  exec "nim c -r --hints:off --path:src tests/t_pathmeasure.nim"
  exec "nim c -r --hints:off --path:src tests/t_starpoly.nim"
  exec "nim c -r --hints:off --path:src tests/t_layer.nim"
  exec "nim c -r --hints:off --path:src tests/t_blendex.nim"
