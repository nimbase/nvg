<p align="center">
  Pure-Nim antialiased 2D Vector Graphics (NanoVG-inspired)<br>
</p>

<p align="center">
  <code>nimble install nvg</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/nvg/">API reference</a><br>
  <img src="https://github.com/nimbase/nvg/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/nvg/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
- CPU and GPU rendering: a scalar rasterizer, an opt-in JIT backend,
  and a Metal GPU backend — pixel-identical output on every backend
- Draw with a simple canvas: shapes, fills, strokes, transparency
- Smooth edges everywhere through supersampled antialiasing
- Gradients (linear, radial, box — with as many color stops as you like),
  image patterns, solid colors
- Mipmapped image sampling, so minified images stay smooth instead of
  aliasing
- Photo filters: monochrome and color grain (uniform and soft), plus
  ripple, swirl, turbulence fields and domain-warp distortion, on
  both CPU and Metal compute
- SVG image loading straight into pattern paints
- Flexible strokes: round/square caps, miter/bevel/round joins, dashed lines
- Two fill rules (even-odd, nonzero winding) for holes and overlaps
- 26 blend modes: Porter-Duff plus the full CSS mix-blend set
- Masks and offscreen layers for cutouts and compositing tricks
- Stars, polygons, rounded corners, plus measuring/splitting paths
- Text rendering: harfnim shaping (kerning, ligatures, Arabic joining,
  RTL) with glyph outlines as fills and strokes, multiline + alignment
- Flexbox-style text rows: inline images, paths and rectangles that
  align to the text (baseline, center, top, bottom, stretch), with
  row justification, gaps and growth — including the footer-icon
  pattern, no hand-positioning needed
- An opt-in JIT backend that renders pixel-identical output, faster
- PNG export with zero dependencies (pure-Nim encoder)
- Image file loading: PNG, JPEG, BMP, GIF, QOI, PNM, TGA decode into
  pattern paints, no dependencies beyond the workspace

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
- [x] Blend modes (Porter-Duff + full CSS mix-blend set)
- [x] Mask and layer compositing primitives
- [x] Stars, polygons, path measurement and splitting
- [x] JIT backend, pixel-identical to scalar
- [x] Metal GPU backend (needs hosted-GPU verification)
- [x] Mipmapped image minification
- [x] All 26 blend modes on the JIT fast path (separable + non-separable)
- [x] PNG export without dependencies
- [x] Text rendering (shaping + glyph outlines, multiline + align)
- [x] Flex row lines (justify, gap, grow, item alignment)
- [x] Inline replaced boxes (image/path spans aligned to text ink)
- [x] Bilinear and multi-stop paints on the JIT fast path
- [ ] AArch64 kernel execution sign-off
- [x] Image file loading API
- [x] Photo filters (mono/color grain, ripple, swirl, turbulence,
  domain warp) on CPU + Metal compute
- [ ] SVG image loading

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/nvg-nim/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/nvg-nim/fork)

### 🎩 License
MIT license | Nim Community.
