import std/unittest
import nvg/lottie/model
import nvg/lottie/parser

const doc = """{
  "v": "5.7.4", "nm": "t", "w": 100, "h": 100, "fr": 60,
  "ip": 0, "op": 120, "foo": [1, 2],
  "layers": [
    {"ty": 4, "nm": "r", "ind": 1, "ip": 0, "op": 120, "bogus": {},
     "ks": {"a": {"a": 0, "k": [0, 0]},
             "p": {"a": 0, "k": [50, 50]},
             "s": {"a": 0, "k": [100, 100]},
             "r": {"a": 0, "k": 0},
             "o": {"a": 0, "k": 100}},
     "shapes": [
       {"ty": "gr", "nm": "g", "it": [
         {"ty": "rc", "nm": "rect", "p": {"a": 0, "k": [0, 0]},
          "s": {"a": 0, "k": [10, 20]}, "r": {"a": 0, "k": 2}, "zzz": 1},
         {"ty": "fl", "nm": "fill", "c": {"a": 0, "k": [1, 0, 0]},
          "o": {"a": 0, "k": 100}},
         {"ty": "mm", "nm": "merge"},
         {"ty": "tr", "nm": "t", "a": {"a": 0, "k": [0, 0]},
          "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]},
          "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}
       ]}
     ]}
  ]
}"""

test "header, defaults, unknown keys tolerated":
  let a = parseString(doc)
  check a.version == "5.7.4"
  check a.w == 100
  check a.h == 100
  check a.fr == 60.0
  check a.layers.len == 1
  let l = a.layers[0]
  check l.layerType == ltShape
  check l.id == 1
  check l.parentId == -1
  check l.timeStretch == 1.0
  check l.blend == bmNormal
  check l.matte == mtNone
  check l.shapes.len == 1
  let g = l.shapes[0]
  check g.kind == skGroup
  check g.children.len == 2 # rect + fill; mm skipped, tr folded
  check g.children[0].kind == skRect
  check g.children[0].rSize.value == vec2(10, 20)
  check g.children[1].kind == skFill

test "split position parses":
  let a = parseString("""{"v":"5","w":10,"h":10,"fr":30,"ip":0,"op":10,
    "layers":[{"ty":4,"ind":1,"ip":0,"op":10,
    "ks":{"a":{"a":0,"k":[0,0]},
    "p":{"s":true,"x":{"a":0,"k":3},"y":{"a":0,"k":[4]}},"s":{"a":0,"k":[100,100]},
    "r":{"a":0,"k":0},"o":{"a":0,"k":100}}}] }""")
  check a.layers.len == 1
  check a.layers[0].transform.position.value == vec2(3, 4)

test "masks, matte, solid color, assets":
  let a = parseString("""{"v":"5","w":10,"h":10,"fr":30,"ip":0,"op":10,
    "assets":[{"id":"c1","layers":[{"ty":1,"ind":9,"ip":0,"op":10,
    "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
    "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}}]}],
    "layers":[
      {"ty":1,"ind":1,"ip":0,"op":10,"sc":"#ff0000","sw":20,"sh":30,
       "tt":1,"hasMask":true,
       "masksProperties":[{"mode":"a","inv":false,
         "pt":{"a":0,"k":{"v":[[0,0]],"i":[[0,0]],"o":[[0,0]],"c":true}},
         "o":{"a":0,"k":100}}],
       "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
       "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}},
      {"ty":0,"ind":2,"ip":0,"op":10,"refId":"c1","w":5,"h":6,
       "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
       "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}}
    ]}""")
  check a.assets.len == 1
  check a.assets[0].kind == akPrecomp
  check a.layers[0].matte == mtAlpha
  check a.layers[0].masks.len == 1
  check a.layers[0].masks[0].mode == mmAdd
  check a.layers[0].solidColor == lcolor(1, 0, 0)
  check a.layers[0].solidSize == vec2(20, 30)
  check a.layers[1].layerType == ltPrecomp
  check a.layers[1].refId == "c1"
  check a.layers[1].solidSize == vec2(5, 6)
