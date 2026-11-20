## Scene composition: layer lookup, time remap, hierarchy, draw order.
##
## Mirrors rlottie `CompLayer` + `Layer::timeRemap`: the model keeps layers
## front-to-back (file order), drawing runs back-to-front. Parent chains
## multiply (`matrix(frameNo, depth)`), opacity compounds down the chain.
## A layer carrying `tt != None` shows the layer above it (previous file
## index) through its matte.

import std/math
import ../transform
import ./model
import ./keyframe

proc layerById*(layers: seq[Layer], id: int): Layer =
  for l in layers:
    if l.id == id: return l
  nil

proc isActive*(l: Layer, frame: float64): bool =
  ## rlottie `visible()`: inside [inFrame, outFrame].
  frame >= l.inFrame and frame <= l.outFrame

proc assetById*(anim: Animation, id: string): Asset =
  for a in anim.assets:
    if a.id == id: return a
  nil

proc remapFrame*(l: Layer, anim: Animation, frame: float64): float64 =
  ## Mirror `Layer::timeRemap`: without a `tm` track, shift by start;
  ## with one, the remap value is seconds on the referenced comp timeline.
  var f = frame
  if l.hasTimeRemap:
    f = valueAt(l.timeRemap, frame) * anim.fr
  else:
    f = frame - l.startFrame
  f / l.timeStretch

proc localMatrix*(t: Transform, frame: float64): Xform =
  ## M = T(position) * R(rotation) * S(scale) * T(-anchor).
  ## `multiply(a, b)` applies `b` first, so post-multiply each factor.
  ## Skew (`sk`/`sa`) is parsed but ignored in v1 (documented).
  let a = valueAt(t.anchor, frame)
  let p = valueAt(t.position, frame)
  let s = valueAt(t.scale, frame)
  let r = valueAt(t.rotation, frame) * PI / 180.0
  result = identity()
  result = multiply(result, translate(p.x, p.y))
  result = multiply(result, rotate(r))
  result = multiply(result, scale(s.x / 100.0, s.y / 100.0))
  result = multiply(result, translate(-a.x, -a.y))

proc worldMatrix*(layers: seq[Layer], l: Layer, frame: float64): Xform =
  result = localMatrix(l.transform, frame)
  var cur = l
  var depth = 0
  while cur.parentId >= 0 and depth < 32:
    let p = layerById(layers, cur.parentId)
    if p == nil: break
    result = multiply(localMatrix(p.transform, frame), result)
    cur = p
    inc depth

proc combinedOpacity*(layers: seq[Layer], l: Layer, frame: float64): float64 =
  ## Product of own + ancestor opacities, 0..1.
  result = valueAt(l.transform.opacity, frame) / 100.0
  var cur = l
  var depth = 0
  while cur.parentId >= 0 and depth < 32:
    let p = layerById(layers, cur.parentId)
    if p == nil: break
    result *= valueAt(p.transform.opacity, frame) / 100.0
    cur = p
    inc depth

proc matteSource*(layers: seq[Layer], idx: int): Layer =
  ## For a file-order layer with `tt != None`, the matte is the nearest
  ## visible layer above it (lower file index). Single level in v1.
  if layers[idx].matte == mtNone or idx <= 0: return nil
  var i = idx - 1
  while i >= 0:
    if layers[i].layerType != ltNull and not layers[i].hidden:
      return layers[i]
    dec i
  nil

proc drawOrder*(layers: seq[Layer]): seq[int] =
  ## Back-to-front file indices (Lottie stores front-to-back).
  for i in countdown(layers.len - 1, 0):
    result.add(i)
