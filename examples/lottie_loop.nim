## Render the bundled Loop.json to a strip of PNG frames.
##
## Run: clue build examples/lottie_loop.nim --out:/tmp/loop_ex && /tmp/loop_ex /tmp/loop-out
##
## Loads `examples/animations/Loop.json` (nested staggered precomps: one
## smiley tile repeated with time offsets), prints its size, duration and
## layer count, then draws four frames across the timeline. Needs no
## arguments besides the output directory.

import std/os
import nvg

const loopFile = currentSourcePath().parentDir() / "animations" /
  "Loop.json"

proc main(outDir: string) =
  createDir(outDir)
  if not fileExists(loopFile):
    quit("missing " & loopFile)
  let a = parseFile(loopFile)
  echo "animation: ", a.name
  echo "size: ", a.w, "x", a.h
  echo "frames: ", a.ip, " to ", a.op, " @ ", a.fr, " fps"
  echo "layers: ", a.layers.len
  var lib = AssetLib()
  for i, f in [0.0, 0.25, 0.5, 0.75]:
    let frame = a.ip + f * (a.op - a.ip)
    let c = newCanvas(a.w, a.h)
    registerAll(c, lib, a)
    renderFrame(c, a, frame, lib)
    let path = outDir / "loop_" & $i & ".png"
    c.savePng(path)
    echo "wrote ", path, " (frame ", frame, ")"

when isMainModule:
  main(if paramCount() > 0: paramStr(1) else: "out")
