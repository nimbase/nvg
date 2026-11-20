import std/unittest
import std/os
import nvg

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const resDir = "/Users/georgelemon/Development/nimbase/references/rlottie/example/resource"

proc checkAnim(path, base: string) =
  let a = parseFile(path)
  check a.w > 0 and a.h > 0
  check a.layers.len > 0
  let c = newCanvas(a.w, a.h)
  var lib = AssetLib()
  registerAll(c, lib, a, baseDir = base)
  let mid = (a.ip + a.op) / 2.0
  renderFrame(c, a, a.ip, lib)
  renderFrame(c, a, mid, lib)
  var n = 0
  for b in c.surface.pixels:
    if b != 0: inc n
  check n > 0

test "vendored fixtures parse and render nonzero":
  var done = 0
  for f in walkFiles(fixturesDir / "*.json"):
    checkAnim(f, fixturesDir)
    inc done
  check done == 3

test "rlottie corpus parses without crashing (local only)":
  if not dirExists(resDir):
    skip()
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
    inc done
    if done >= 6: break
  check done > 0
