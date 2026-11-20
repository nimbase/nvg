## Lottie data model (Bodymovin subset, static types for the JSON format).
##
## Mirrors rlottie's `lottiemodel.h` shape/layer taxonomy, trimmed to what
## the `nvg` backend can draw. Unknown shape types (`mm` merge paths,
## `rd` handled separately, `rp` repeaters beyond v1) parse as `skUnknown`
## and are skipped at render. Text layers keep reserved fields so the
## deferred text pass can map to `nvg`'s box layout API later.

type
  Vec2* = object
    x*, y*: float64

  LColor* = object
    r*, g*, b*: float64

  PathData* = object
    ## AE shape: vertices with in/out tangent offsets, plus closed flag.
    ## Tangents are offsets (CP = vertex + tangent), matching Bodymovin.
    verts*: seq[Vec2]
    inT*: seq[Vec2]
    outT*: seq[Vec2]
    closed*: bool

  Easing* = object
    ## Cubic bezier easing handles (`i`/`o` in keyframes), resolved per
    ## component like rlottie (`VInterpolator`). `hold` renders the start
    ## value through the whole segment.
    x1*, y1*, x2*, y2*: float64
    hold*: bool

  Keyframe*[T] = object
    start*: float64
    finish*: float64
    startVal*: T
    endVal*: T
    ease*: Easing
    # Spatial tangents for positions (offsets, `to`/`ti` in JSON).
    hasSpatial*: bool
    toOut*: T
    toIn*: T

  Animated*[T] = object
    isStatic*: bool
    value*: T
    keys*: seq[Keyframe[T]]

  Transform* = object
    anchor*: Animated[Vec2]
    position*: Animated[Vec2]
    scale*: Animated[Vec2] ## percent, 100 = identity
    rotation*: Animated[float64] ## degrees
    opacity*: Animated[float64] ## 0..100
    skew*: Animated[float64] ## degrees, v1 ignored at render
    skewAxis*: Animated[float64] ## degrees, v1 ignored at render
    autoOrient*: bool

  ShapeKind* = enum
    skGroup
    skRect
    skEllipse
    skPath
    skStar ## polystar (`sr`): star or polygon by `starType`
    skFill
    skStroke
    skGFill
    skGStroke
    skTrim
    skTr ## group transform marker (kept separate, not drawn)
    skRoundedCorner ## applied to sibling rects at parse
    skRepeater ## v1: parsed, not rendered
    skUnknown

  StarType* = enum
    stStar = 1
    stPolygon = 2

  GradientType* = enum
    gtLinear = 1
    gtRadial = 2

  Shape* = ref object
    name*: string
    hidden*: bool
    case kind*: ShapeKind
    of skGroup:
      children*: seq[Shape]
      gTransform*: Transform
    of skRect:
      rPos*: Animated[Vec2]
      rSize*: Animated[Vec2]
      rRound*: Animated[float64]
      rDir*: int
    of skEllipse:
      ePos*: Animated[Vec2]
      eSize*: Animated[Vec2]
      eDir*: int
    of skPath:
      pShape*: Animated[PathData]
      pDir*: int
    of skStar:
      sPos*: Animated[Vec2]
      sOuterR*: Animated[float64]
      sInnerR*: Animated[float64]
      sRot*: Animated[float64]
      sPoints*: Animated[float64]
      sOuterRound*: Animated[float64]
      sInnerRound*: Animated[float64]
      starType*: StarType
      sDir*: int
    of skFill:
      fColor*: Animated[LColor]
      fOpacity*: Animated[float64]
      fRule*: int ## 1 = nonzero, else even-odd (render always even-odd)
    of skStroke:
      sColor*: Animated[LColor]
      sOpacity*: Animated[float64]
      sWidth*: Animated[float64]
      sCap*: int ## 1 butt, 2 round, 3 square
      sJoin*: int ## 1 miter, 2 round, 3 bevel
      sMiter*: float64
      dashes*: seq[Animated[float64]]
      dashOffset*: Animated[float64]
    of skGFill:
      gfType*: GradientType
      gfStops*: Animated[seq[float64]] ## raw Bodymovin stop list
      gfPoints*: int ## `g.p` color-stop count, -1 when absent (legacy)
      gfOpacity*: Animated[float64]
      gfStart*: Animated[Vec2]
      gfEnd*: Animated[Vec2]
      gfRule*: int
    of skGStroke:
      gsType*: GradientType
      gsStops*: Animated[seq[float64]]
      gsPoints*: int
      gsOpacity*: Animated[float64]
      gsStart*: Animated[Vec2]
      gsEnd*: Animated[Vec2]
      gsWidth*: Animated[float64]
      gsCap*: int
      gsJoin*: int
      gsMiter*: float64
      gsDashes*: seq[Animated[float64]]
      gsDashOffset*: Animated[float64]
    of skTrim:
      tStart*: Animated[float64] ## percent 0..100
      tEnd*: Animated[float64]
      tOffset*: Animated[float64] ## degrees
      tMode*: int ## 1 = simultaneous (v1 implements this), 2 = individual
    of skTr:
      tr*: Transform
    of skRoundedCorner:
      rcRadius*: Animated[float64]
    of skRepeater:
      discard
    of skUnknown:
      discard

  MaskMode* = enum
    mmNone = 0
    mmAdd = 1
    mmSubtract = 2
    mmIntersect = 3
    mmDifference = 4

  Mask* = object
    mode*: MaskMode
    inverted*: bool
    shape*: Animated[PathData]
    opacity*: Animated[float64]

  LayerType* = enum
    ltPrecomp = 0
    ltSolid = 1
    ltImage = 2
    ltNull = 3
    ltShape = 4
    ltText = 5 ## reserved: skipped at render until the text pass

  MatteType* = enum
    mtNone = 0
    mtAlpha = 1
    mtAlphaInv = 2
    mtLuma = 3
    mtLumaInv = 4

  BlendMode* = enum
    bmNormal = 0
    bmMultiply = 1
    bmScreen = 2
    bmOverlay = 3
    bmDarken = 4
    bmLighten = 5

  Layer* = ref object
    id*: int
    parentId*: int ## -1 when no parent
    name*: string
    layerType*: LayerType
    hidden*: bool
    inFrame*: float64
    outFrame*: float64
    startFrame*: float64
    timeStretch*: float64
    blend*: BlendMode
    matte*: MatteType
    transform*: Transform
    shapes*: seq[Shape]
    masks*: seq[Mask]
    refId*: string ## precomp / image asset reference
    solidColor*: LColor
    solidSize*: Vec2 ## `sw`/`sh` or `w`/`h` on the layer
    autoOrient*: bool
    hasTimeRemap*: bool
    timeRemap*: Animated[float64] ## seconds on the referenced comp timeline
    textReserved*: string ## raw text payload kept for the deferred pass

  AssetKind* = enum
    akPrecomp
    akImage

  Asset* = ref object
    id*: string
    case kind*: AssetKind
    of akPrecomp:
      layers*: seq[Layer]
    of akImage:
      imgW*, imgH*: int
      imgPath*: string

  Animation* = ref object
    version*: string
    name*: string
    w*, h*: int
    fr*: float64 ## frame rate
    ip*, op*: float64 ## in/out points (frames)
    layers*: seq[Layer]
    assets*: seq[Asset]

proc vec2*(x, y: float64): Vec2 = Vec2(x: x, y: y)

proc lcolor*(r, g, b: float64): LColor = LColor(r: r, g: g, b: b)

proc staticAnim*[T](v: T): Animated[T] =
  Animated[T](isStatic: true, value: v, keys: @[])

proc animKeys*[T](ks: seq[Keyframe[T]]): Animated[T] =
  if ks.len == 0:
    Animated[T](isStatic: true)
  elif ks.len == 1 and ks[0].start == ks[0].finish:
    Animated[T](isStatic: true, value: ks[0].startVal)
  else:
    Animated[T](isStatic: false, keys: ks)
