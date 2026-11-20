## Paint-level helpers: gradient stop interpretation, dash patterns,
## trim segments. Pure functions over parsed values; rendering lives in
## `render.nim`. Formulas mirror rlottie (`Gradient::populate`,
## `getOpacityAtPosition`, `Dash::getDashInfo`, `Trim::segment`).

import std/math
import ../paint
import ../types
import ./model

proc opacityAtPosition*(ops: openArray[float64], pos: float64): float64 =
  ## Mirror `getOpacityAtPosition`: opacity stops are `[pos, op]` pairs;
  ## scan from the second pair, lerp the bracketing pair, clamp. Returns
  ## 0 when nothing brackets (rlottie quirk: a lone stop, or `pos` past
  ## the last, yields 0, not the endpoint).
  var i = 2
  while i + 1 < ops.len:
    let lastPos = ops[i - 2]
    let thisPos = ops[i]
    if thisPos >= pos:
      let denom = thisPos - lastPos
      var t = if denom != 0.0: (pos - lastPos) / denom else: 0.0
      t = clamp(t, 0.0, 1.0)
      return ops[i - 1] + t * (ops[i + 1] - ops[i - 1])
    i += 2
  0.0

proc lottieStops*(raw: seq[float64], colorPoints: int): seq[GradientStop] =
  ## Interpret a Bodymovin gradient payload: `colorPoints` x
  ## `[pos, r, g, b]`, then `[pos, opacity]` pairs. `colorPoints < 0`
  ## (missing `p`, legacy files) means the whole array is color stops.
  ## Empty result falls back to opaque white, like rlottie.
  var cp = colorPoints
  if cp < 0 or (cp > 0 and cp > raw.len div 4):
    cp = raw.len div 4
  if cp < 0: cp = 0
  let colorSize = cp * 4
  var opSize = raw.len - colorSize
  if opSize mod 2 != 0 or opSize < 0: opSize = 0
  var ops: seq[float64] = @[]
  if opSize > 0:
    ops = raw[colorSize ..< colorSize + opSize]
  for i in 0 ..< cp:
    let pos = raw[i * 4]
    let a = if opSize > 0: opacityAtPosition(ops, pos) else: 1.0
    result.add(GradientStop(pos: pos,
      color: rgbaf(raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3], a)))
  if result.len == 0:
    result.add(GradientStop(pos: 0.0, color: rgbaf(1, 1, 1, 1)))

proc dashSplit*(vals: seq[float64]): tuple[pattern: seq[float64],
    offset: float64] =
  ## Mirror `Dash::getDashInfo`: at most one entry means no dash; the
  ## last value is the offset, the rest alternate on/off. An odd-length
  ## pattern duplicates its last value (nvg would repeat-double the
  ## whole pattern instead, which differs, so do it here).
  if vals.len <= 1: return (@[], 0.0)
  var pat = vals[0 .. ^2]
  if pat.len mod 2 == 1: pat.add(pat[^1])
  (pat, vals[^1])

proc trimSegment*(s, e, o: float64): tuple[lo, hi: float64, loop, empty,
    full: bool] =
  ## Mirror `Trim::segment` (simultaneous mode): `s`/`e` in percent,
  ## `o` in degrees. Returns the normalized range; `loop` means the
  ## range wraps (`lo..1` + `0..hi`), `empty`/`full` are the degenerate
  ## outcomes. Individual mode is mapped to simultaneous (documented).
  const eps = 1e-6
  let ss = s / 100.0
  let ee = e / 100.0
  let off = (o - floor(o / 360.0) * 360.0) / 360.0
  if abs(ss - ee) < eps: return (0, 0, false, true, false)
  if abs(abs(ss - ee) - 1.0) < eps: return (0, 1, false, false, true)
  var a = ss + off
  var b = ee + off
  if off > 0.0:
    if a <= 1.0 and b <= 1.0:
      result = (min(a, b), max(a, b), false, false, false)
    elif a > 1.0 and b > 1.0:
      result = (min(a - 1.0, b - 1.0), max(a - 1.0, b - 1.0),
        false, false, false)
    elif a > 1.0:
      result = (min(a - 1.0, b), max(a - 1.0, b), true, false, false)
    else:
      result = (min(a, b - 1.0), max(a, b - 1.0), true, false, false)
  else:
    if a >= 0.0 and b >= 0.0:
      result = (min(a, b), max(a, b), false, false, false)
    elif a < 0.0 and b < 0.0:
      result = (min(1.0 + a, 1.0 + b), max(1.0 + a, 1.0 + b),
        false, false, false)
    elif a < 0.0:
      result = (min(1.0 + a, b), max(1.0 + a, b), true, false, false)
    else:
      result = (min(a, 1.0 + b), max(a, 1.0 + b), true, false, false)
