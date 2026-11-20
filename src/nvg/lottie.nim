## Lottie animation renderer on `nvg/Canvas` (Bodymovin JSON + dotLottie).
##
## Drawing goes through `nvg/Canvas` (CPU or JIT backend, caller owned).
## The caller clears first; `renderFrame` draws all visible layers for
## the composition frame.

import ./canvas
import ./surface
import ./lottie/model
import ./lottie/parser
import ./lottie/keyframe
import ./lottie/scene
import ./lottie/paints
import ./lottie/render
import ./lottie/asset
import ./lottie/dotlottie

export model
export parser
export keyframe
export scene
export paints
export render
export asset
export dotlottie

proc loadString*(s: string): Animation =
  parseString(s)

proc loadFile*(path: string): Animation =
  parseFile(path)

proc frameCount*(a: Animation): float64 =
  max(0.0, a.op - a.ip)

proc durationSecs*(a: Animation): float64 =
  if a.fr > 0.0: frameCount(a) / a.fr else: 0.0

proc size*(a: Animation): tuple[w, h: int] =
  (a.w, a.h)

proc renderSurface*(a: Animation, frame: float64): Surface =
  ## Convenience: fresh transparent surface with `frame` drawn.
  let c = newCanvas(a.w, a.h)
  renderFrame(c, a, frame)
  c.surface
