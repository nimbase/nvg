import std/unittest
import std/base64
import std/strutils
import nvg

proc imgLayerDoc(assetJson: string): string =
  """{"v":"5","w":4,"h":4,"fr":30,"ip":0,"op":30,
    "assets":[ASSET],
    "layers":[{"ty":2,"ind":1,"ip":0,"op":30,"refId":"img1","w":4,"h":4,
     "ks":{"a":{"a":0,"k":[0,0]},"p":{"a":0,"k":[0,0]},
     "s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}}]}""".replace(
    "ASSET", assetJson)

test "raster data-uri asset renders like a direct pattern":
  let src = newCanvas(2, 2)
  src.beginPath()
  src.rect(0, 0, 2, 2)
  src.setFillColor(color(1, 0, 0, 1))
  src.fill()
  let png = src.encodePng()
  check png.len > 0
  let uri = "data:image/png;base64," & encode(png)
  let a = parseString(imgLayerDoc(
    """{"id":"img1","w":2,"h":2,"p":"URI"}""".replace("URI", uri)))
  check a.assets.len == 1
  check a.assets[0].kind == akImage
  let c = newCanvas(4, 4)
  var lib = AssetLib()
  registerAll(c, lib, a)
  check lib.imageHandle("img1") != 0
  renderFrame(c, a, 0.0, lib)
  let d = newCanvas(4, 4)
  let h = d.createImageMem(png, {})
  check h != 0
  d.beginPath()
  d.rect(0, 0, 4, 4)
  d.setFillPaint(d.imagePattern(0, 0, 4, 4, 0.0, h, 1.0))
  d.fill()
  check c.surface.pixels == d.surface.pixels

test "svg data-uri asset renders through the svg module":
  let svg = "<svg width=\"4\" height=\"4\">" &
    "<rect width=\"4\" height=\"4\" fill=\"#00ff00\"/></svg>"
  let esc = svg.replace("\"", "\\\"")
  let a = parseString(imgLayerDoc(
    """{"id":"img1","w":4,"h":4,"p":"URI"}""".replace("URI",
      "data:image/svg+xml," & esc)))
  let c = newCanvas(4, 4)
  var lib = AssetLib()
  registerAll(c, lib, a)
  check lib.imageHandle("img1") != 0
  renderFrame(c, a, 0.0, lib)
  var n = 0
  for b in c.surface.pixels: (if b != 0: inc n)
  check n == 4 * 4 * 2 # opaque green: G and A bytes
  check c.surface.pixels[1] == 255
  check c.surface.pixels[3] == 255

test "missing image asset skips quietly":
  let a = parseString(imgLayerDoc(
    """{"id":"img1","w":4,"h":4,"p":"does-not-exist.png"}"""))
  let c = newCanvas(4, 4)
  var lib = AssetLib()
  registerAll(c, lib, a, baseDir = "/tmp")
  check lib.imageHandle("img1") == 0
  renderFrame(c, a, 0.0, lib)
  for b in c.surface.pixels: check b == 0
