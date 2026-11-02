<p align="center">
  Pure-Nim antialiased 2D vector drawing (NanoVG-inspired)<br>
</p>

<p align="center">
  <code>nimble install nvg</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/nvg-nim/">API reference</a><br>
  <img src="https://github.com/nimbase/nvg-nim/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/nvg-nim/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
- Draw with a simple canvas: shapes, fills, strokes, transparency
- Smooth edges everywhere through supersampled antialiasing
- Gradients (linear, radial, box — with as many color stops as you like),
  image patterns, solid colors
- Flexible strokes: round/square caps, miter/bevel/round joins, dashed lines
- Two fill rules (even-odd, nonzero winding) for holes and overlaps
- 14 blend modes, from source-over to multiply, screen and overlay
- Masks and offscreen layers for cutouts and compositing tricks
- Stars, polygons, rounded corners, plus measuring/splitting paths
- An opt-in JIT backend that renders pixel-identical output, faster
- PNG export with zero dependencies (pure-Nim encoder)

## Examples
```nim
import nvg

let c = newCanvas(800, 600)
c.clear(rgb(255, 255, 255))
c.beginPath()
c.circle(400, 300, 200)
c.setFillPaint(c.radialGradient(400, 300, 20, 200,
  rgbf(0.9, 0.2, 0.2), rgbf(0.2, 0.2, 0.9)))
c.fill()
c.savePng("out.png")
```

Faster rendering with the JIT backend (same pixels, guaranteed).
Compile with `-d:nvgJit` (this keeps the kernel builders out of normal
builds, so everyday compiles stay fast):

```nim
# nim c -d:nvgJit myapp.nim
let c = newCanvas(800, 600, newJitBackend())
# ... draw as usual ...
destroyJitBackend(c.backend.JitBackend)
```

## Roadmap
- [x] CPU rasterizer with antialiased edges
- [x] Paths, transforms, scissor clips
- [x] Solid, gradient (multi-stop) and pattern paints
- [x] Strokes: caps, joins, dashes
- [x] Even-odd and nonzero winding fills
- [x] Blend modes (Porter-Duff + multiply/screen/overlay)
- [x] Mask and layer compositing primitives
- [x] Stars, polygons, path measurement and splitting
- [x] JIT backend, pixel-identical to scalar
- [x] PNG export without dependencies
- [ ] Text rendering (shaping + glyph outlines)
- [ ] Bilinear and multi-stop paints on the JIT fast path
- [ ] AArch64 kernel execution sign-off
- [ ] Image file loading API

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/nvg-nim/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/nvg-nim/fork)

### 🎩 License
MIT license | Nim Community.
