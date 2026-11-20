## Render the bundled dotLottie file to a strip of PNG frames.
##
## Run: clue build examples/lottie_cat.nim --out:/tmp/cat && /tmp/cat /tmp/cat-out
##
## Loads `examples/animations/Cat is sleeping and rolling.lottie`, prints its
## size, duration and layer count, then draws four frames across the
## timeline. Needs no arguments besides the output directory.

import std/os
import nvg

const catFile = currentSourcePath().parentDir() / "animations" /
  "Cat is sleeping and rolling.lottie"

proc main(outDir: string) =
  createDir(outDir)
  if not fileExists(catFile):
    quit("missing " & catFile)
  let dl = loadDotLottieFile(catFile)
  let a = dl.anim
  echo "animation: ", dl.animId
  echo "size: ", a.w, "x", a.h
  echo "frames: ", a.ip, " to ", a.op, " @ ", a.fr, " fps"
  echo "layers: ", a.layers.len
  var lib = AssetLib()
  for i, f in [0.0, 0.25, 0.5, 0.75]:
    let frame = a.ip + f * (a.op - a.ip)
    let c = newCanvas(a.w, a.h)
    registerDotLottie(c, lib, dl)
    renderFrame(c, a, frame, lib)
    let path = outDir / "cat_" & $i & ".png"
    c.savePng(path)
    echo "wrote ", path, " (frame ", frame, ")"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "out")
