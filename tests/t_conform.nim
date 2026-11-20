import std/unittest
import std/os
import nvg

const fixturesDir = currentSourcePath().parentDir() / "fixtures"

test "rlottie sample files parse and render without crashing":
  var done = 0
  for f in walkFiles(fixturesDir / "*.json"):
    let a = parseFile(f)
    check a.w > 0 and a.h > 0
    check a.layers.len > 0
    let c = newCanvas(a.w, a.h)
    var lib = AssetLib()
    registerAll(c, lib, a, baseDir = fixturesDir)
    renderFrame(c, a, a.ip, lib)
    renderFrame(c, a, (a.ip + a.op) / 2.0, lib)
    inc done
  check done == 6
