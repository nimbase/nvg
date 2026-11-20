import std/unittest
import nvg

test "stop interpreter: colors then opacities":
  let stops = lottieStops(@[0.0, 1, 0, 0, 0.5, 0, 1, 0, 1.0, 0, 0, 1,
    0.0, 0.25, 1.0, 0.75], 3)
  check stops.len == 3
  check stops[0].pos == 0.0
  check abs(stops[0].color.a - 0.25) < 1e-9
  check abs(stops[1].color.g - 1.0) < 1e-9
  check abs(stops[1].color.a - 0.5) < 1e-9
  check abs(stops[2].color.a - 0.75) < 1e-9

test "stop interpreter: no opacity stops means opaque":
  let stops = lottieStops(@[0.0, 1, 0, 0, 1.0, 0, 0, 1], -1)
  check stops.len == 2
  check stops[0].color.a == 1.0
  check stops[1].color.a == 1.0

test "stop interpreter: empty falls back to white":
  let stops = lottieStops(@[], -1)
  check stops.len == 1
  check stops[0].color == rgbaf(1, 1, 1, 1)

test "dash split mirrors rlottie":
  let (p1, o1) = dashSplit(@[4.0, 2.0, 1.0])
  check p1 == @[4.0, 2.0]
  check o1 == 1.0
  let (p2, o2) = dashSplit(@[4.0, 1.0])
  check p2 == @[4.0, 4.0]
  check o2 == 1.0
  let (p3, o3) = dashSplit(@[5.0])
  check p3.len == 0

test "trim segment basics":
  let f = trimSegment(0, 100, 0)
  check f.full and not f.loop and not f.empty
  let e = trimSegment(30, 30, 0)
  check e.empty
  let n = trimSegment(10, 40, 0)
  check (not n.loop) and abs(n.lo - 0.1) < 1e-9 and
    abs(n.hi - 0.4) < 1e-9
  let l = trimSegment(80, 20, 0)
  check (not l.loop) and abs(l.lo - 0.2) < 1e-9 and abs(l.hi - 0.8) < 1e-9
  let w = trimSegment(80, 20, 180)
  check w.loop and abs(w.lo - 0.3) < 1e-9 and abs(w.hi - 0.7) < 1e-9

test "linear gradient fill matches direct nvg draw":
  let doc = """{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,"layers":[
    {"ty":4,"ind":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[20,4]},
        "r":{"a":0,"k":0}},
       {"ty":"gf","t":1,"o":{"a":0,"k":100},
        "s":{"a":0,"k":[0,10]},"e":{"a":0,"k":[20,10]},
        "g":{"p":2,"k":{"a":0,"k":[0,1,0,0,1,0,0,1]}}},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}
    ]}"""
  let a = parseString(doc)
  check a.layers[0].shapes[0].children[1].kind == skGFill
  check a.layers[0].shapes[0].children[1].gfPoints == 2
  let got = renderSurface(a, 0.0).pixels
  let d = newCanvas(20, 20)
  d.beginPath()
  d.rect(0, 8, 20, 4)
  d.setFillPaint(d.linearGradientStops(0, 10, 20, 10,
    [GradientStop(pos: 0, color: rgbaf(1, 0, 0, 1)),
     GradientStop(pos: 1, color: rgbaf(0, 0, 1, 1))]))
  d.fill()
  check got == d.surface.pixels

test "radial gradient fill matches direct nvg draw":
  let doc = """{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,"layers":[
    {"ty":4,"ind":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"el","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[16,16]}},
       {"ty":"gf","t":2,"o":{"a":0,"k":100},
        "s":{"a":0,"k":[10,10]},"e":{"a":0,"k":[18,10]},
        "g":{"p":2,"k":{"a":0,"k":[0,1,1,1,1,0,0,0]}}},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}
    ]}"""
  let a = parseString(doc)
  let got = renderSurface(a, 0.0).pixels
  let d = newCanvas(20, 20)
  d.beginPath()
  d.ellipse(10, 10, 8, 8)
  d.setFillPaint(d.radialGradientStops(10, 10, 0, 8,
    [GradientStop(pos: 0, color: rgbaf(1, 1, 1, 1)),
     GradientStop(pos: 1, color: rgbaf(0, 0, 0, 1))]))
  d.fill()
  check got == d.surface.pixels

test "dashed stroke matches direct nvg draw":
  let doc = """{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,"layers":[
    {"ty":4,"ind":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[16,16]},
        "r":{"a":0,"k":0}},
       {"ty":"st","c":{"a":0,"k":[1,0,0]},"o":{"a":0,"k":100},
        "w":{"a":0,"k":2},"lc":1,"lj":1,"ml":4,
        "d":[{"n":"d","v":{"a":0,"k":3}},{"n":"g","v":{"a":0,"k":2}},
             {"n":"o","v":{"a":0,"k":0}}]},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}
    ]}"""
  let a = parseString(doc)
  let st = a.layers[0].shapes[0].children[1]
  check st.kind == skStroke
  check st.dashes.len == 2 # positional: [d, g], offset last
  let got = renderSurface(a, 0.0).pixels
  let d = newCanvas(20, 20)
  d.beginPath()
  d.rect(2, 2, 16, 16)
  d.setStrokeWidth(2)
  d.setLineDash([3.0, 2.0], 0.0)
  d.setStrokeColor(color(1, 0, 0, 1))
  d.stroke()
  check got == d.surface.pixels

test "trim cuts a path in half":
  let doc = """{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,"layers":[
    {"ty":4,"ind":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[16,4]},
        "r":{"a":0,"k":0}},
       {"ty":"fl","c":{"a":0,"k":[1,0,0]},"o":{"a":0,"k":100}},
       {"ty":"tm","s":{"a":0,"k":0},"e":{"a":0,"k":50},
        "o":{"a":0,"k":0},"m":1},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}
    ]}"""
  let a = parseString(doc)
  let s = renderSurface(a, 0.0)
  var n = 0
  for b in s.pixels: (if b != 0: inc n)
  # Full rect would be 16x4=64px -> 128 nonzero bytes; trimmed half less.
  check n > 0 and n < 128
