import std/unittest
import std/strutils
import nvg

proc shapeLayer(shapesJson, extra = ""): string =
  """{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,"layers":[
    {"ty":4,"ind":1,"ip":0,"op":30EXTRA,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes": SHAPES}]}""".replace("SHAPES", shapesJson).replace("EXTRA", extra)

proc directRect(x, y, w, h: float64, col: Color): seq[uint8] =
  let c = newCanvas(20, 20)
  c.beginPath()
  c.rect(x, y, w, h)
  c.setFillColor(col)
  c.fill()
  c.surface.pixels

test " Remap without time remap shifts by start":
  let a = parseString("""{"v":"5","w":10,"h":10,"fr":30,"ip":0,"op":30,
    "layers":[{"ty":4,"ind":1,"ip":0,"op":30,"st":-5,
    "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
    "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}}]}""")
  check remapFrame(a.layers[0], a, 15.0) == 20.0

test "parent transform compounds":
  let a = parseString("""{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,
    "layers":[
    {"ty":4,"ind":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[5,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}},
    {"ty":4,"ind":2,"parent":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[10,10]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":50}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[4,4]},"r":{"a":0,"k":0}},
       {"ty":"fl","c":{"a":0,"k":[1,0,0]},"o":{"a":0,"k":100}},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}
    ]}""")
  let wm = worldMatrix(a.layers, a.layers[1], 0.0)
  check abs(wm[4] - 15.0) < 1e-9
  check abs(wm[5] - 10.0) < 1e-9
  check combinedOpacity(a.layers, a.layers[1], 0.0) == 0.5
  let got = renderSurface(a, 0.0).pixels
  # Local rect(-2,-2,4,4) shifted by world (15,10) -> (13,8,4,4) at 50% red.
  let c = newCanvas(20, 20)
  c.beginPath()
  c.rect(13, 8, 4, 4)
  c.setFillColor(color(1, 0, 0, 0.5))
  c.fill()
  check got == c.surface.pixels

test "solid rect matches direct nvg draw":
  let a = parseString(shapeLayer("""[{"ty":"gr","it":[
    {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[10,10]},
     "r":{"a":0,"k":0}},
    {"ty":"fl","c":{"a":0,"k":[1,0,0]},"o":{"a":0,"k":100}},
    {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]"""))
  let got = renderSurface(a, 0.0).pixels
  check got == directRect(5, 5, 10, 10, color(1, 0, 0, 1))

test "blend multiply matches direct draw":
  let a = parseString(shapeLayer("""[{"ty":"gr","it":[
    {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[10,10]},
     "r":{"a":0,"k":0}},
    {"ty":"fl","c":{"a":0,"k":[1,0,0]},"o":{"a":0,"k":100}},
    {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]""",
    ",\"bm\": 1"))
  let c = newCanvas(20, 20)
  c.clear(color(0, 1, 0, 1))
  renderFrame(c, a, 0.0)
  let d = newCanvas(20, 20)
  d.clear(color(0, 1, 0, 1))
  d.beginPath()
  d.rect(5, 5, 10, 10)
  d.setFillColor(color(1, 0, 0, 1))
  d.setCompositeOp(coMultiply)
  d.fill()
  check c.surface.pixels == d.surface.pixels

test "alpha matte keeps only matte overlap":
  let a = parseString("""{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,
    "layers":[
    {"ty":4,"ind":1,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[5,10]},"s":{"a":0,"k":[10,20]},
        "r":{"a":0,"k":0}},
       {"ty":"fl","c":{"a":0,"k":[1,1,1]},"o":{"a":0,"k":100}},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]},
    {"ty":4,"ind":2,"ip":0,"op":30,"tt":1,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[20,20]},
        "r":{"a":0,"k":0}},
       {"ty":"fl","c":{"a":0,"k":[0,1,0]},"o":{"a":0,"k":100}},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}
    ]}""")
  let got = renderSurface(a, 0.0).pixels
  # Matte covers x 0..10, content full canvas -> left half green.
  check got == directRect(0, 0, 10, 20, color(0, 1, 0, 1))

test "subtract mask cuts a hole":
  let a = parseString(shapeLayer("""[{"ty":"gr","it":[
    {"ty":"rc","p":{"a":0,"k":[10,10]},"s":{"a":0,"k":[20,20]},
     "r":{"a":0,"k":0}},
    {"ty":"fl","c":{"a":0,"k":[1,0,0]},"o":{"a":0,"k":100}},
    {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]""",
    ""","hasMask": true, "masksProperties": [{"mode": "s", "inv": false,
     "pt": {"a": 0, "k": {"v": [[0,0],[10,0],[10,20],[0,20]],
       "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]],
       "c": true}}, "o": {"a": 0, "k": 100}}]"""))
  let got = renderSurface(a, 0.0).pixels
  check got == directRect(10, 0, 10, 20, color(1, 0, 0, 1))

test "precomp nests with remap":
  let a = parseString("""{"v":"5","w":20,"h":20,"fr":30,"ip":0,"op":30,
    "assets":[{"id":"c1","layers":[{"ty":4,"ind":9,"ip":0,"op":30,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}},
     "shapes":[{"ty":"gr","it":[
       {"ty":"rc","p":{"a":0,"k":[2,2]},"s":{"a":0,"k":[4,4]},
        "r":{"a":0,"k":0}},
       {"ty":"fl","c":{"a":0,"k":[0,0,1]},"o":{"a":0,"k":100}},
       {"ty":"tr","a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
        "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}]}]}],
    "layers":[{"ty":0,"ind":1,"ip":0,"op":30,"refId":"c1","w":20,"h":20,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[10,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}}]}""")
  let got = renderSurface(a, 0.0).pixels
  check got == directRect(10, 0, 4, 4, color(0, 0, 1, 1))
