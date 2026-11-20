import std/unittest
import std/os
import nvg

const resDir = "/Users/georgelemon/Development/nimbase/references/rlottie/example/resource"

test "real files parse and render without crashing":
  var done = 0
  for f in walkFiles(resDir / "*.json"):
    let a = parseFile(f)
    check a.w > 0 and a.h > 0
    check a.layers.len > 0
    let c = newCanvas(a.w, a.h)
    var lib = AssetLib()
    registerAll(c, lib, a, baseDir = resDir)
    let mid = (a.ip + a.op) / 2.0
    renderFrame(c, a, a.ip, lib)
    renderFrame(c, a, mid, lib)
    var n = 0
    for b in c.surface.pixels: (if b != 0: inc n)
    echo lastPathPart(f), ": ", a.w, "x", a.h, " layers=", a.layers.len,
      " nonzero=", n
    inc done
    if done >= 6: break
  check done > 0
