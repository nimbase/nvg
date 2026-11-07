# nvg examples
#
# Each file is a standalone program that renders a PNG into `examples/out/`
# (override with an argument: `nim c -r examples/basic.nim /tmp/shots`).
#
# Run them all (sh):
#   for f in examples/*.nim; do nim c -r "$f"; done
# The JIT example needs the define (others must NOT pass it):
#   nim c -r -d:nvgJit examples/jit.nim
# The text example needs a font file (or TEXT_FONT set):
#   nim c -r examples/text.nim -- /path/to/font.ttf
#
# | file            | shows                                              |
# |-----------------|----------------------------------------------------|
# | `basic.nim`     | shapes, solid fills/strokes, translucent overlap   |
# | `gradients.nim` | linear, radial, box, multi-stop (+ hard stop)      |
# | `strokes.nim`   | caps, joins, dashes                                |
# | `patterns.nim`  | image patterns: clamp/repeat/flip/tint, bilinear   |
# | `blends.nim`    | composite ops over a shared backdrop               |
# | `masks.nim`     | offscreen layers + alpha masks                     |
# | `paths.nim`     | stars, polygons, fill rules, path measurement      |
# | `jit.nim`       | CPU vs JIT backend, pixel-identity check           |
# | `text.nim`      | shaped text (needs a font path argument)         |
