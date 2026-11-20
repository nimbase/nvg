import std/unittest
import std/tables
import nvg

const catPath = "examples/animations/Cat is sleeping and rolling.lottie"

test "dotlottie loads the bundled cat":
  let dl = loadDotLottieFile(catPath)
  check dl.animId == "12345"
  check dl.anim.w == 500
  check dl.anim.h == 500
  check dl.anim.layers.len == 15
  check dl.files.hasKey("animations/12345.json")

test "dotlottie frames differ as the cat rolls":
  let dl = loadDotLottieFile(catPath)
  let c0 = newCanvas(dl.anim.w, dl.anim.h)
  var lib = AssetLib()
  registerDotLottie(c0, lib, dl)
  renderFrame(c0, dl.anim, 0.0, lib)
  let c1 = newCanvas(dl.anim.w, dl.anim.h)
  renderFrame(c1, dl.anim, 240.0, lib)
  var n0 = 0
  for b in c0.surface.pixels: (if b != 0: inc n0)
  check n0 > 1000
  check c0.surface.pixels != c1.surface.pixels

test "unknown animation id raises":
  var raised = false
  try:
    discard loadDotLottieFile(catPath, "nope")
  except ValueError:
    raised = true
  check raised

test "zip magic sniff":
  check isDotLottieData("PK\x03\x04rest")
  check not isDotLottieData("{\"v\":\"5\"}")
  check not isDotLottieData("")
