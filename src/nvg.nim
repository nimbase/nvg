## Pure-Nim antialiased 2D vector drawing (NanoVG-inspired).
##
## Redesigned immediate-mode API on `Canvas` (see `nvg/canvas`).
## V1 renders to a CPU `Surface`; `nvg/backend` keeps the seam for a
## future GPU renderer. Text shapes via harfnim into path fills/strokes
## (see `nvg/text`).

import ./nvg/types
import ./nvg/transform
import ./nvg/path
import ./nvg/images
import ./nvg/paint
import ./nvg/surface
import ./nvg/raster
import ./nvg/dash
import ./nvg/pathmeasure
import ./nvg/layer
import ./nvg/text
import ./nvg/jitctx
when defined(nvgJit):
  import ./nvg/jit
import ./nvg/backend
import ./nvg/canvas

export types
export transform
export path
export images
export paint
export surface
export raster
export dash
export pathmeasure
export layer
export text
export jitctx
when defined(nvgJit):
  export jit
export backend
export canvas
