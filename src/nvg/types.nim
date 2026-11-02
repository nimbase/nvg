## Core value types for the pure-Nim 2D vector library.
##
## Units are user-space points with y pointing down (canvas top-left
## origin), matching the sibling `opengraphics/vector` model. Geometry
## uses `float64`; colors are 0..1 floats with straight (non-premultiplied)
## alpha at API boundaries.

type
  Pt* = object
    x*, y*: float64

  Rect* = object
    x*, y*, w*, h*: float64

  Xform* = array[6, float64]
    ## Affine `[a b c d e f]`: `x' = a*x + c*y + e`,
    ## `y' = b*x + d*y + f`.

  Color* = object
    r*, g*, b*, a*: float64

  LineCap* = enum
    lcButt
    lcRound
    lcSquare

  LineJoin* = enum
    ljMiter
    ljRound
    ljBevel

  FillRule* = enum
    frEvenOdd
    frNonZero

  Winding* = enum
    wCCW = 1
    wCW = 2

  CompOp* = enum
    ## Porter-Duff composite operations honored by the CPU rasterizer
    ## (see `surface.blendPixel`). `coSourceOver` IS Normal.
    coSourceOver
    coSourceIn
    coSourceOut
    coAtop
    coDestinationOver
    coDestinationIn
    coDestinationOut
    coDestinationAtop
    coLighter
    coCopy
    coXor
    coMultiply
    coScreen
    coOverlay

  Clip* = object
    enabled*: bool
    x0*, y0*, x1*, y1*: float64

proc pt*(x, y: float64): Pt = Pt(x: x, y: y)

proc rect*(x, y, w, h: float64): Rect = Rect(x: x, y: y, w: w, h: h)

proc rectBounds*(r: Rect): tuple[x0, y0, x1, y1: float64] =
  (r.x, r.y, r.x + r.w, r.y + r.h)

proc color*(r, g, b: float64, a = 1.0): Color =
  Color(r: r, g: g, b: b, a: a)

proc rgb*(r, g, b: uint8): Color =
  Color(r: float64(r) / 255.0, g: float64(g) / 255.0,
    b: float64(b) / 255.0, a: 1.0)

proc rgba*(r, g, b, a: uint8): Color =
  Color(r: float64(r) / 255.0, g: float64(g) / 255.0,
    b: float64(b) / 255.0, a: float64(a) / 255.0)

proc rgbf*(r, g, b: float64): Color = Color(r: r, g: g, b: b, a: 1.0)

proc rgbaf*(r, g, b, a: float64): Color = Color(r: r, g: g, b: b, a: a)

proc clamp01*(v: float64): float64 =
  if v < 0.0: 0.0 elif v > 1.0: 1.0 else: v

proc lerpColor*(c0, c1: Color, u: float64): Color =
  let t = clamp01(u)
  Color(r: c0.r + (c1.r - c0.r) * t, g: c0.g + (c1.g - c0.g) * t,
    b: c0.b + (c1.b - c0.b) * t, a: c0.a + (c1.a - c0.a) * t)

proc withAlpha*(c: Color, a: float64): Color =
  Color(r: c.r, g: c.g, b: c.b, a: clamp01(a))

proc toRgba8*(c: Color): tuple[r, g, b, a: uint8] =
  (uint8(clamp01(c.r) * 255.0 + 0.5), uint8(clamp01(c.g) * 255.0 + 0.5),
    uint8(clamp01(c.b) * 255.0 + 0.5), uint8(clamp01(c.a) * 255.0 + 0.5))
