import std/unittest
import nvg
import nvg/metal

test "metal device enumerates with a name":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    var ctx = newMetalCtx(1, 1)
    defer: ctx.close()
    check ctx.deviceName().len > 0
  else:
    skip()

test "compute solid fill matches cpu surface":
  when defined(macosx):
    if not mtlAvailable():
      skip()
    const W = 8
    const H = 8
    var ctx = newMetalCtx(W, H)
    defer: ctx.close()
    for (r, g, b, a) in [(1.0, 0.0, 0.0, 1.0), (0.0, 1.0, 0.0, 1.0),
        (0.0, 0.0, 1.0, 0.5), (0.5, 0.5, 0.5, 1.0)]:
      ctx.fillSolid(r, g, b, a)
      let got = ctx.readback()
      var s = newSurface(W, H)
      s.clear(rgbf(r, g, b).withAlpha(a))
      check got == s.pixels
  else:
    skip()
