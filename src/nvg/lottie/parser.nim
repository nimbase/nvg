## Tolerant Bodymovin JSON parser (static `std/json`, no streaming).
##
## Mirrors rlottie `lottieparser.cpp` key-by-key: unknown keys are ignored,
## missing keys fall back to documented defaults. Only the shape/layer
## taxonomy in `model.nim` is produced; animation sampling lives in
## `keyframe.nim`, composition in `scene.nim`.

import std/json
import std/strutils
import ./model
import ./keyframe

proc jfield*(n: JsonNode, key: string): JsonNode =
  if n != nil and n.kind == JObject and n.hasKey(key): n[key] else: nil

proc jstr*(n: JsonNode, key: string; dflt: string = ""): string =
  let f = jfield(n, key)
  if f != nil and f.kind == JString: f.getStr() else: dflt

proc jbool*(n: JsonNode, key: string, dflt = false): bool =
  let f = jfield(n, key)
  if f == nil: return dflt
  case f.kind
  of JBool: f.getBool()
  of JInt: f.getInt() != 0
  of JFloat: f.getFloat() != 0.0
  else: dflt

proc jfloat*(n: JsonNode, key: string, dflt = 0.0): float64 =
  let f = jfield(n, key)
  if f == nil: return dflt
  case f.kind
  of JFloat: f.getFloat()
  of JInt: float64(f.getInt())
  else: dflt

proc jint*(n: JsonNode, key: string, dflt = 0): int =
  let f = jfield(n, key)
  if f == nil: return dflt
  case f.kind
  of JInt: f.getInt()
  of JFloat: int(f.getFloat())
  else: dflt

proc numVal*(n: JsonNode): float64 =
  if n == nil: return 0.0
  case n.kind
  of JFloat: n.getFloat()
  of JInt: float64(n.getInt())
  else: 0.0

proc vecVal*(n: JsonNode): Vec2 =
  if n != nil and n.kind == JArray and n.len >= 2:
    vec2(numVal(n[0]), numVal(n[1]))
  else:
    vec2(0, 0)

proc colorVal*(n: JsonNode): LColor =
  if n != nil and n.kind == JArray and n.len >= 3:
    lcolor(numVal(n[0]), numVal(n[1]), numVal(n[2]))
  else:
    lcolor(0, 0, 0)

proc pathVal*(n: JsonNode): PathData =
  result = PathData(closed: false)
  if n == nil or n.kind != JObject: return
  let vv = jfield(n, "v")
  let ii = jfield(n, "i")
  let oo = jfield(n, "o")
  let cc = jfield(n, "c")
  if cc != nil:
    case cc.kind
    of JBool: result.closed = cc.getBool()
    of JInt: result.closed = cc.getInt() != 0
    else: discard
  if vv != nil and vv.kind == JArray:
    for i in 0 ..< vv.len:
      let p = vv[i]
      if p.kind == JArray and p.len >= 2:
        result.verts.add(vec2(numVal(p[0]), numVal(p[1])))
      else:
        result.verts.add(vec2(0, 0))
  if ii != nil and ii.kind == JArray:
    for p in ii:
      if p.kind == JArray and p.len >= 2:
        result.inT.add(vec2(numVal(p[0]), numVal(p[1])))
      else:
        result.inT.add(vec2(0, 0))
  if oo != nil and oo.kind == JArray:
    for p in oo:
      if p.kind == JArray and p.len >= 2:
        result.outT.add(vec2(numVal(p[0]), numVal(p[1])))
      else:
        result.outT.add(vec2(0, 0))
  while result.inT.len < result.verts.len: result.inT.add(vec2(0, 0))
  while result.outT.len < result.verts.len: result.outT.add(vec2(0, 0))

proc rawFloats*(n: JsonNode): seq[float64] =
  if n != nil and n.kind == JArray:
    for e in n: result.add(numVal(e))

proc easeOf*(kf: JsonNode): Easing =
  result = Easing(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0, hold: false)
  if jbool(kf, "h", false): result.hold = true
  let i = jfield(kf, "i")
  let o = jfield(kf, "o")
  if i != nil and o != nil:
    let ix = jfield(i, "x")
    let iy = jfield(i, "y")
    let ox = jfield(o, "x")
    let oy = jfield(o, "y")
    proc firstNum(a: JsonNode): float64 =
      if a != nil and a.kind == JArray and a.len > 0: numVal(a[0])
      elif a != nil: numVal(a)
      else: 0.0
    # i.x[0] is x2-ish, o.x[0] is x1-ish per Bodymovin convention.
    result.x1 = firstNum(ox)
    result.y1 = firstNum(oy)
    result.x2 = firstNum(ix)
    result.y2 = firstNum(iy)

proc kfStart*(kf: JsonNode): float64 =
  let t = jfield(kf, "t")
  if t == nil: 0.0 else: numVal(t)

proc scalarOf*(n: JsonNode, dflt = 0.0): float64 =
  ## Loose scalar: number, or first element of an array (split-dimension
  ## `y: {"k": [4]}`, exporter array-wrapped `"s": [66]`), else `dflt`.
  if n == nil: return dflt
  case n.kind
  of JFloat, JInt: numVal(n)
  of JArray:
    if n.len > 0: scalarOf(n[0], dflt) else: dflt
  else: dflt

proc animScalar*(prop: JsonNode, dflt = 0.0): Animated[float64] =
  if prop == nil: return staticAnim(dflt)
  if prop.kind != JObject: return staticAnim(numVal(prop))
  let a = jint(prop, "a", 0)
  let k = jfield(prop, "k")
  if a == 0 or k == nil:
    if k == nil: return staticAnim(dflt)
    return staticAnim(numVal(k))
  if k.kind != JArray or k.len == 0: return staticAnim(dflt)
  if k[0].kind != JObject or jfield(k[0], "t") == nil:
    # Static value smuggled in an animated wrapper.
    if k.len > 0 and (k[0].kind == JFloat or k[0].kind == JInt):
      return staticAnim(numVal(k[0]))
    return staticAnim(dflt)
  var keys: seq[Keyframe[float64]] = @[]
  for i in 0 ..< k.len:
    let kf = k[i]
    # Start/end may be array-wrapped (`"s": [66]`, exporter style);
    # `scalarOf` unwraps, `numVal` would zero them.
    let s = Keyframe[float64](start: kfStart(kf),
      startVal: scalarOf(jfield(kf, "s")), endVal: scalarOf(jfield(kf, "s")),
      ease: easeOf(kf))
    keys.add(s)
  for i in 0 ..< keys.len:
    if i + 1 < k.len:
      keys[i].finish = kfStart(k[i + 1])
      let e = jfield(k[i], "e")
      if e != nil and e.kind == JArray and e.len > 0:
        keys[i].endVal = scalarOf(e[0], keys[i].startVal)
      else:
        # rlottie: with no end value the segment ends at the next key.
        keys[i].endVal = keys[i + 1].startVal
    else:
      keys[i].finish = keys[i].start
      keys[i].endVal = keys[i].startVal
  animKeys(keys)

proc animDim*(prop: JsonNode, dflt = 0.0): Animated[float64] =
  ## Scalar property that also unwraps array-wrapped values.
  if prop == nil: return staticAnim(dflt)
  if prop.kind != JObject: return staticAnim(scalarOf(prop, dflt))
  let a = jint(prop, "a", 0)
  let k = jfield(prop, "k")
  if a == 0 or k == nil:
    if k == nil: return staticAnim(dflt)
    return staticAnim(scalarOf(k, dflt))
  if k.kind != JArray or k.len == 0: return staticAnim(dflt)
  if k[0].kind != JObject or jfield(k[0], "t") == nil:
    if k.len > 0 and (k[0].kind == JFloat or k[0].kind == JInt):
      return staticAnim(scalarOf(k, dflt))
    return staticAnim(scalarOf(k, dflt))
  var keys: seq[Keyframe[float64]] = @[]
  for kf in k:
    let s = Keyframe[float64](start: kfStart(kf),
      startVal: scalarOf(jfield(kf, "s"), dflt),
      endVal: scalarOf(jfield(kf, "s"), dflt),
      ease: easeOf(kf))
    keys.add(s)
  for i in 0 ..< keys.len:
    if i + 1 < k.len:
      keys[i].finish = kfStart(k[i + 1])
      let e = jfield(k[i], "e")
      if e != nil:
        keys[i].endVal = scalarOf(e, keys[i + 1].startVal)
      else:
        # rlottie: with no end value the segment ends at the next key.
        keys[i].endVal = keys[i + 1].startVal
    else:
      keys[i].finish = keys[i].start
      keys[i].endVal = keys[i].startVal
  animKeys(keys)

proc splitXY*(prop: JsonNode, xd, yd: float64): Animated[Vec2] =
  ## Split-dimension position: `p` with `"s": true` and `x`/`y` sub-props.
  let x = animDim(jfield(prop, "x"), xd)
  let y = animDim(jfield(prop, "y"), yd)
  if x.isStatic and y.isStatic:
    return staticAnim(vec2(valueAt(x, 0), valueAt(y, 0)))
  var keys: seq[Keyframe[Vec2]] = @[]
  # Sample-based merge: evaluate x/y at shared key boundaries.
  var bounds: seq[float64] = @[]
  for k in x.keys: bounds.add(k.start)
  for k in y.keys:
    var seen = false
    for b in bounds:
      if abs(b - k.start) < 1e-9: seen = true
    if not seen: bounds.add(k.start)
  for i in 0 ..< bounds.len:
    let t0 = bounds[i]
    let t1 = if i + 1 < bounds.len: bounds[i + 1] else: t0
    keys.add(Keyframe[Vec2](start: t0, finish: t1,
      startVal: vec2(valueAt(x, t0), valueAt(y, t0)),
      endVal: vec2(valueAt(x, t1), valueAt(y, t1)),
      ease: Easing(hold: true)))
  animKeys(keys)

proc animVec*(prop: JsonNode, dflt = vec2(0, 0)): Animated[Vec2] =
  if prop == nil: return staticAnim(dflt)
  if prop.kind == JArray: return staticAnim(vecVal(prop))
  if prop.kind != JObject: return staticAnim(dflt)
  if jbool(prop, "s", false):
    return splitXY(prop, dflt.x, dflt.y)
  let a = jint(prop, "a", 0)
  let k = jfield(prop, "k")
  if a == 0 or k == nil:
    if k == nil: return staticAnim(dflt)
    return staticAnim(vecVal(k))
  if k.kind != JArray or k.len == 0: return staticAnim(dflt)
  if k[0].kind != JObject or jfield(k[0], "t") == nil:
    return staticAnim(vecVal(k))
  var keys: seq[Keyframe[Vec2]] = @[]
  var hasEnd: seq[bool] = @[]
  for kf in k:
    var kk = Keyframe[Vec2](start: kfStart(kf), ease: easeOf(kf))
    let s = jfield(kf, "s")
    let e = jfield(kf, "e")
    kk.startVal = vecVal(s)
    kk.endVal = if e != nil: vecVal(e) else: kk.startVal
    hasEnd.add(e != nil)
    let to = jfield(kf, "to")
    let ti = jfield(kf, "ti")
    if to != nil and ti != nil:
      kk.hasSpatial = true
      kk.toOut = vecVal(to)
      kk.toIn = vecVal(ti)
    keys.add(kk)
  for i in 0 ..< keys.len:
    if i + 1 < keys.len:
      keys[i].finish = keys[i + 1].start
      # rlottie: with no end value the segment ends at the next key.
      if not hasEnd[i]: keys[i].endVal = keys[i + 1].startVal
    else:
      keys[i].finish = keys[i].start
      if not hasEnd[i]: keys[i].endVal = keys[i].startVal
  animKeys(keys)

proc animColor*(prop: JsonNode, dflt = lcolor(0, 0, 0)): Animated[LColor] =
  if prop == nil: return staticAnim(dflt)
  if prop.kind == JArray: return staticAnim(colorVal(prop))
  if prop.kind != JObject: return staticAnim(dflt)
  let a = jint(prop, "a", 0)
  let k = jfield(prop, "k")
  if a == 0 or k == nil:
    if k == nil: return staticAnim(dflt)
    return staticAnim(colorVal(k))
  if k.kind != JArray or k.len == 0: return staticAnim(dflt)
  if k[0].kind != JObject or jfield(k[0], "t") == nil:
    return staticAnim(colorVal(k))
  var keys: seq[Keyframe[LColor]] = @[]
  var hasEnd: seq[bool] = @[]
  for kf in k:
    var kk = Keyframe[LColor](start: kfStart(kf), ease: easeOf(kf))
    kk.startVal = colorVal(jfield(kf, "s"))
    let e = jfield(kf, "e")
    kk.endVal = if e != nil: colorVal(e) else: kk.startVal
    hasEnd.add(e != nil)
    keys.add(kk)
  for i in 0 ..< keys.len:
    if i + 1 < keys.len:
      keys[i].finish = keys[i + 1].start
      # rlottie: with no end value the segment ends at the next key.
      if not hasEnd[i]: keys[i].endVal = keys[i + 1].startVal
    else:
      keys[i].finish = keys[i].start
      if not hasEnd[i]: keys[i].endVal = keys[i].startVal
  animKeys(keys)

proc animPath*(prop: JsonNode): Animated[PathData] =
  if prop == nil: return staticAnim(PathData())
  if prop.kind == JObject and jfield(prop, "a") == nil:
    return staticAnim(pathVal(prop))
  let a = jint(prop, "a", 0)
  let k = jfield(prop, "k")
  if a == 0 or k == nil:
    if k == nil: return staticAnim(PathData())
    if k.kind == JObject: return staticAnim(pathVal(k))
    return staticAnim(PathData())
  if k.kind != JArray or k.len == 0: return staticAnim(PathData())
  if k[0].kind != JObject or jfield(k[0], "t") == nil:
    if k.kind == JObject: return staticAnim(pathVal(k))
    return staticAnim(PathData())
  var keys: seq[Keyframe[PathData]] = @[]
  var hasEnd: seq[bool] = @[]
  proc shapeOf(n: JsonNode): PathData =
    if n != nil and n.kind == JArray and n.len > 0: pathVal(n[0])
    elif n != nil and n.kind == JObject: pathVal(n)
    else: PathData()
  for kf in k:
    let e = jfield(kf, "e")
    keys.add(Keyframe[PathData](start: kfStart(kf), ease: easeOf(kf),
      startVal: shapeOf(jfield(kf, "s")), endVal: shapeOf(e)))
    hasEnd.add(e != nil)
  for i in 0 ..< keys.len:
    if i + 1 < keys.len:
      keys[i].finish = keys[i + 1].start
      # rlottie: with no end value the segment ends at the next key.
      if not hasEnd[i]: keys[i].endVal = keys[i + 1].startVal
    else:
      keys[i].finish = keys[i].start
      if not hasEnd[i]: keys[i].endVal = keys[i].startVal
    if keys[i].endVal.verts.len == 0:
      keys[i].endVal = keys[i].startVal
  animKeys(keys)

proc animRaw*(prop: JsonNode): Animated[seq[float64]] =
  ## Gradient stop payload `g`: `{"p": n, "k": ...}` where the inner `k`
  ## is `{"a": 0, "k": [...]}` (static), a bare array (legacy), or a
  ## keyframe list (animated, held per segment in v1).
  if prop == nil: return staticAnim(newSeq[float64]())
  let k =
    if prop.kind == JObject and jfield(prop, "k") != nil: jfield(prop, "k")
    else: prop
  if k.kind == JObject and jfield(k, "a") != nil:
    let a = jint(k, "a", 0)
    let kk = jfield(k, "k")
    if a == 0 or kk == nil:
      if kk == nil: return staticAnim(newSeq[float64]())
      return staticAnim(rawFloats(kk))
    if kk.kind == JArray and kk.len > 0 and
        (kk[0].kind == JFloat or kk[0].kind == JInt):
      return staticAnim(rawFloats(kk))
    if kk.kind == JArray:
      var keys: seq[Keyframe[seq[float64]]] = @[]
      for kf in kk:
        if kf.kind != JObject or jfield(kf, "t") == nil: continue
        keys.add(Keyframe[seq[float64]](start: kfStart(kf),
          ease: easeOf(kf),
          startVal: rawFloats(jfield(kf, "s"))))
      for i in 0 ..< keys.len:
        keys[i].finish = if i + 1 < keys.len: keys[i + 1].start
          else: keys[i].start
        keys[i].endVal = keys[i].startVal
      return animKeys(keys)
    return staticAnim(newSeq[float64]())
  staticAnim(rawFloats(k))

proc parseTransform*(n: JsonNode): Transform =
  result = Transform(
    anchor: staticAnim(vec2(0, 0)),
    position: staticAnim(vec2(0, 0)),
    scale: staticAnim(vec2(100, 100)),
    rotation: staticAnim(0.0),
    opacity: staticAnim(100.0),
    skew: staticAnim(0.0),
    skewAxis: staticAnim(0.0))
  if n == nil or n.kind != JObject: return
  let a = jfield(n, "a")
  let p = jfield(n, "p")
  let s = jfield(n, "s")
  let r = jfield(n, "r")
  let o = jfield(n, "o")
  if a != nil: result.anchor = animVec(a)
  if p != nil: result.position = animVec(p)
  if s != nil:
    let v = animVec(s, vec2(100, 100))
    result.scale = v
  if r != nil:
    if r.kind == JObject: result.rotation = animScalar(r)
    elif r.kind == JArray: result.rotation = staticAnim(numVal(r[0]))
    else: result.rotation = staticAnim(numVal(r))
  if o != nil: result.opacity = animScalar(o, 100.0)

proc parseDash*(n: JsonNode, dashes: var seq[Animated[float64]],
    offset: var Animated[float64]) =
  ## Positional like rlottie (`Dash::getDashInfo`): entries in file
  ## order, last value is the offset. `<= 1` entries means no dash.
  dashes = @[]
  offset = staticAnim(0.0)
  let d = jfield(n, "d")
  if d == nil or d.kind != JArray or d.len <= 1: return
  var vals: seq[Animated[float64]] = @[]
  for e in d:
    if e.kind != JObject: continue
    vals.add(animScalar(jfield(e, "v")))
  if vals.len <= 1: return
  for i in 0 ..< vals.len - 1: dashes.add(vals[i])
  offset = vals[^1]

proc parseShape*(n: JsonNode): Shape

proc parseGroup*(n: JsonNode): Shape =
  var kids: seq[Shape] = @[]
  var tr = Transform(anchor: staticAnim(vec2(0, 0)),
    position: staticAnim(vec2(0, 0)), scale: staticAnim(vec2(100, 100)),
    rotation: staticAnim(0.0), opacity: staticAnim(100.0),
    skew: staticAnim(0.0), skewAxis: staticAnim(0.0))
  let it = jfield(n, "it")
  if it != nil and it.kind == JArray:
    for e in it:
      if e.kind != JObject: continue
      if jstr(e, "ty", "") == "tr":
        tr = parseTransform(e)
      else:
        let s = parseShape(e)
        if s != nil and not s.hidden and s.kind != skUnknown: kids.add(s)
  result = Shape(kind: skGroup, name: jstr(n, "nm", ""),
    hidden: jbool(n, "hd", false), children: kids, gTransform: tr)

proc parseShape*(n: JsonNode): Shape =
  if n == nil or n.kind != JObject: return nil
  let ty = jstr(n, "ty", "")
  let hidden = jbool(n, "hd", false)
  case ty
  of "gr": parseGroup(n)
  of "rc":
    Shape(kind: skRect, name: jstr(n, "nm", ""), hidden: hidden,
      rPos: animVec(jfield(n, "p")), rSize: animVec(jfield(n, "s")),
      rRound: animScalar(jfield(n, "r")), rDir: jint(n, "d", 0))
  of "el":
    Shape(kind: skEllipse, name: jstr(n, "nm", ""), hidden: hidden,
      ePos: animVec(jfield(n, "p")), eSize: animVec(jfield(n, "s")),
      eDir: jint(n, "d", 0))
  of "sh":
    Shape(kind: skPath, name: jstr(n, "nm", ""), hidden: hidden,
      pShape: animPath(jfield(n, "ks")), pDir: jint(n, "d", 0))
  of "sr":
    let sy = jint(n, "sy", 1)
    Shape(kind: skStar, name: jstr(n, "nm", ""), hidden: hidden,
      sPos: animVec(jfield(n, "p")), sOuterR: animScalar(jfield(n, "or")),
      sInnerR: animScalar(jfield(n, "ir")), sRot: animScalar(jfield(n, "r")),
      sPoints: animScalar(jfield(n, "pt"), 5.0),
      sOuterRound: animScalar(jfield(n, "os")),
      sInnerRound: animScalar(jfield(n, "is")),
      starType: if sy == 2: stPolygon else: stStar, sDir: jint(n, "d", 0))
  of "fl":
    Shape(kind: skFill, name: jstr(n, "nm", ""), hidden: hidden,
      fColor: animColor(jfield(n, "c")), fOpacity: animScalar(jfield(n, "o"), 100.0),
      fRule: jint(n, "r", 0))
  of "st":
    var ds: seq[Animated[float64]] = @[]
    var off = staticAnim(0.0)
    parseDash(n, ds, off)
    Shape(kind: skStroke, name: jstr(n, "nm", ""), hidden: hidden,
      sColor: animColor(jfield(n, "c")), sOpacity: animScalar(jfield(n, "o"), 100.0),
      sWidth: animScalar(jfield(n, "w"), 1.0),
      sCap: jint(n, "lc", 1), sJoin: jint(n, "lj", 1),
      sMiter: jfloat(n, "ml", 4.0), dashes: ds, dashOffset: off)
  of "gf":
    let g = jfield(n, "g")
    Shape(kind: skGFill, name: jstr(n, "nm", ""), hidden: hidden,
      gfType: if jint(n, "t", 1) == 2: gtRadial else: gtLinear,
      gfStops: animRaw(g),
      gfPoints: jint(g, "p", -1),
      gfOpacity: animScalar(jfield(n, "o"), 100.0),
      gfStart: animVec(jfield(n, "s")), gfEnd: animVec(jfield(n, "e")),
      gfRule: jint(n, "r", 0))
  of "gs":
    let g = jfield(n, "g")
    var gds: seq[Animated[float64]] = @[]
    var goff = staticAnim(0.0)
    parseDash(n, gds, goff)
    Shape(kind: skGStroke, name: jstr(n, "nm", ""), hidden: hidden,
      gsType: if jint(n, "t", 1) == 2: gtRadial else: gtLinear,
      gsStops: animRaw(g),
      gsPoints: jint(g, "p", -1),
      gsOpacity: animScalar(jfield(n, "o"), 100.0),
      gsStart: animVec(jfield(n, "s")), gsEnd: animVec(jfield(n, "e")),
      gsWidth: animScalar(jfield(n, "w"), 1.0),
      gsCap: jint(n, "lc", 1), gsJoin: jint(n, "lj", 1),
      gsMiter: jfloat(n, "ml", 4.0), gsDashes: gds, gsDashOffset: goff)
  of "tm":
    Shape(kind: skTrim, name: jstr(n, "nm", ""), hidden: hidden,
      tStart: animScalar(jfield(n, "s")), tEnd: animScalar(jfield(n, "e"), 100.0),
      tOffset: animScalar(jfield(n, "o")), tMode: jint(n, "m", 1))
  of "tr":
    # Bare transform inside a group tail; parseGroup consumes it, but
    # tolerate it standalone too.
    Shape(kind: skTr, name: jstr(n, "nm", ""), hidden: hidden,
      tr: parseTransform(n))
  of "rd":
    Shape(kind: skRoundedCorner, name: jstr(n, "nm", ""), hidden: hidden,
      rcRadius: animScalar(jfield(n, "r")))
  of "rp":
    Shape(kind: skRepeater, name: jstr(n, "nm", ""), hidden: hidden)
  else:
    Shape(kind: skUnknown, name: jstr(n, "nm", ""), hidden: hidden)

proc parseMask*(n: JsonNode): Mask =
  result = Mask(mode: mmNone, shape: staticAnim(PathData()),
    opacity: staticAnim(100.0))
  if n == nil or n.kind != JObject: return
  let m = jstr(n, "mode", "n")
  result.mode =
    case m
    of "a": mmAdd
    of "s": mmSubtract
    of "i": mmIntersect
    of "f": mmDifference
    else: mmNone
  result.inverted = jbool(n, "inv", false)
  result.shape = animPath(jfield(n, "pt"))
  result.opacity = animScalar(jfield(n, "o"), 100.0)

proc parseLayer*(n: JsonNode): Layer =
  if n == nil or n.kind != JObject: return nil
  result = Layer(parentId: -1, timeStretch: 1.0, inFrame: 0, outFrame: 0,
    blend: bmNormal, matte: mtNone, solidSize: vec2(0, 0))
  result.name = jstr(n, "nm", "")
  result.id = jint(n, "ind", 0)
  let ty = jint(n, "ty", 3)
  result.layerType =
    case ty
    of 0: ltPrecomp
    of 1: ltSolid
    of 2: ltImage
    of 4: ltShape
    of 5: ltText
    else: ltNull
  result.hidden = jbool(n, "hd", false)
  if jfield(n, "parent") != nil: result.parentId = jint(n, "parent", -1)
  result.refId = jstr(n, "refId", "")
  result.inFrame = jfloat(n, "ip", 0.0)
  result.outFrame = jfloat(n, "op", 0.0)
  result.startFrame = jfloat(n, "st", 0.0)
  if jfield(n, "sr") != nil: result.timeStretch = jfloat(n, "sr", 1.0)
  if result.timeStretch == 0.0: result.timeStretch = 1.0
  result.blend =
    case jint(n, "bm", 0)
    of 1: bmMultiply
    of 2: bmScreen
    of 3: bmOverlay
    of 4: bmDarken
    of 5: bmLighten
    else: bmNormal
  result.matte =
    case jint(n, "tt", 0)
    of 1: mtAlpha
    of 2: mtAlphaInv
    of 3: mtLuma
    of 4: mtLumaInv
    else: mtNone
  result.autoOrient = jint(n, "ao", 0) != 0
  let ks = jfield(n, "ks")
  if ks != nil:
    result.transform = parseTransform(ks)
  # Solid color is a hex string; image/size fallbacks per rlottie.
  let sc = jstr(n, "sc", "")
  if sc.len >= 7 and sc[0] == '#':
    try:
      let r = parseHexInt(sc[1 .. 2])
      let g = parseHexInt(sc[3 .. 4])
      let b = parseHexInt(sc[5 .. 6])
      result.solidColor = lcolor(float64(r) / 255.0, float64(g) / 255.0,
        float64(b) / 255.0)
    except ValueError:
      discard
  let w = jfield(n, "w")
  let sw = jfield(n, "sw")
  let h = jfield(n, "h")
  let sh = jfield(n, "sh")
  let ww = if sw != nil: numVal(sw) elif w != nil: numVal(w) else: 0.0
  let hh = if sh != nil: numVal(sh) elif h != nil: numVal(h) else: 0.0
  result.solidSize = vec2(ww, hh)
  let shapes = jfield(n, "shapes")
  if shapes != nil and shapes.kind == JArray:
    for e in shapes:
      let s = parseShape(e)
      if s != nil and not s.hidden: result.shapes.add(s)
  if jbool(n, "hasMask", false):
    let mp = jfield(n, "masksProperties")
    if mp != nil and mp.kind == JArray:
      for e in mp:
        result.masks.add(parseMask(e))
  let tm = jfield(n, "tm")
  if tm != nil:
    result.hasTimeRemap = true
    result.timeRemap = animScalar(tm)
  if result.layerType == ltText:
    result.textReserved = $n

proc parseAsset*(n: JsonNode): Asset =
  if n == nil or n.kind != JObject: return nil
  let id = jstr(n, "id", "")
  let layers = jfield(n, "layers")
  if layers != nil and layers.kind == JArray:
    result = Asset(id: id, kind: akPrecomp)
    for e in layers:
      let l = parseLayer(e)
      if l != nil: result.layers.add(l)
    return
  # Image asset: `w`/`h` plus `p` (path) or `u` (folder).
  if jfield(n, "w") != nil and jfield(n, "h") != nil:
    let u = jstr(n, "u", "")
    let p = jstr(n, "p", "")
    result = Asset(id: id, kind: akImage, imgW: jint(n, "w", 0),
      imgH: jint(n, "h", 0), imgPath: u & p)
    return
  nil

proc parseAnimation*(root: JsonNode): Animation =
  result = Animation(fr: 60.0, ip: 0.0, op: 0.0)
  if root == nil or root.kind != JObject: return
  result.version = jstr(root, "v", "")
  result.name = jstr(root, "nm", "")
  result.w = jint(root, "w", 0)
  result.h = jint(root, "h", 0)
  result.fr = jfloat(root, "fr", 60.0)
  result.ip = jfloat(root, "ip", 0.0)
  result.op = jfloat(root, "op", 0.0)
  let assets = jfield(root, "assets")
  if assets != nil and assets.kind == JArray:
    for e in assets:
      let a = parseAsset(e)
      if a != nil: result.assets.add(a)
  let layers = jfield(root, "layers")
  if layers != nil and layers.kind == JArray:
    for e in layers:
      let l = parseLayer(e)
      if l != nil: result.layers.add(l)

proc parseString*(s: string): Animation =
  parseAnimation(parseJson(s))

proc parseFile*(path: string): Animation =
  parseAnimation(parseJson(readFile(path)))
