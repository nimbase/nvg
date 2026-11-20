import std/unittest
import nvg

const loopPath = "examples/animations/Loop.json"

test "loop parses: nested precomp chain":
  let a = parseFile(loopPath)
  check a.w == 512
  check a.h == 512
  check a.layers.len == 61
  check a.assets.len == 2

test "loop renders and animates across the timeline":
  let a = parseFile(loopPath)
  var lib = AssetLib()
  var prev: seq[uint8] = @[]
  for f in [0.0, 90.0, 180.0, 270.0, 360.0]:
    let c = newCanvas(a.w, a.h)
    registerAll(c, lib, a)
    renderFrame(c, a, f, lib)
    var n = 0
    for b in c.surface.pixels: (if b != 0: inc n)
    check n > 1000
    if prev.len > 0:
      check c.surface.pixels != prev
    prev = c.surface.pixels
