## Image file loading tests with hand-crafted fixtures (no binaries).
##
## QOI/BMP/GIF/PNM/TGA inputs are built byte by byte below; PNG and
## JPEG round-trip through encoders. Every pixel expectation is derived
## from the format spec, not snapshotted.

import std/os
import std/tables
import std/unittest
import nvg
import image/buffer
import image/dynamic
import image/color
import image/codecs/jpgenc

# --------------------------------------------------------------------------
# Fixture builders
# --------------------------------------------------------------------------

proc putU16le(s: var seq[uint8], v: uint16) =
  s.add(uint8(v and 0xFFu16))
  s.add(uint8(v shr 8))

proc putI32le(s: var seq[uint8], v: int32) =
  s.putU16le(cast[uint16](v and 0xFFFFi32))
  s.putU16le(cast[uint16]((v shr 16) and 0xFFFFi32))

proc putU32le(s: var seq[uint8], v: uint32) =
  s.putU16le(uint16(v and 0xFFFFu32))
  s.putU16le(uint16((v shr 16) and 0xFFFFu32))

proc putU32be(s: var seq[uint8], v: uint32) =
  s.add(uint8((v shr 24) and 0xFFu32))
  s.add(uint8((v shr 16) and 0xFFu32))
  s.add(uint8((v shr 8) and 0xFFu32))
  s.add(uint8(v and 0xFFu32))

proc qoiRed1x1(): seq[uint8] =
  ## 1x1 red QOI: magic, BE size, channels, colorspace, OP_RGB, padding.
  result = @[uint8('q'), uint8('o'), uint8('i'), uint8('f')]
  result.putU32be(1u32)
  result.putU32be(1u32)
  result.add(3u8)
  result.add(0u8)
  result.add(0xFEu8)
  result.add(255u8)
  result.add(0u8)
  result.add(0u8)
  for _ in 0 ..< 7:
    result.add(0u8)
  result.add(1u8)

proc bmp2x2(): seq[uint8] =
  ## 2x2 24-bit BMP, bottom-up rows padded to 4 bytes:
   ## top row red/green, bottom row blue/white.
  result = @[uint8('B'), uint8('M')]
  result.putU32le(70u32)
  result.putU32le(0u32)
  result.putU32le(54u32)
  result.putU32le(40u32)
  result.putI32le(2i32)
  result.putI32le(2i32)
  result.putU16le(1u16)
  result.putU16le(24u16)
  result.putU32le(0u32)
  result.putU32le(16u32)
  result.putU32le(0u32)
  result.putU32le(0u32)
  result.putU32le(0u32)
  result.putU32le(0u32)
  # Bottom row first, BGR: blue, white.
  result.add([255u8, 0u8, 0u8, 255u8, 255u8, 255u8, 0u8, 0u8])
  # Top row: red, green.
  result.add([0u8, 0u8, 255u8, 0u8, 255u8, 0u8, 0u8, 0u8])

proc gifRed1x1(): seq[uint8] =
  ## 1x1 GIF89a, 4-color table, single red pixel. LZW min code 2:
  ## clear(100) pixel(000) eoi(101) packed LSB-first into 0x44 0x01.
  result = @[uint8('G'), uint8('I'), uint8('F'), uint8('8'), uint8('9'),
    uint8('a')]
  result.add([1u8, 0u8, 1u8, 0u8, 0x81u8, 0u8, 0u8])
  result.add([255u8, 0u8, 0u8, 0u8, 0u8, 255u8,
    0u8, 0u8, 0u8, 0u8, 0u8, 0u8])
  result.add([0x2Cu8, 0u8, 0u8, 0u8, 0u8, 1u8, 0u8, 1u8, 0u8, 0u8])
  result.add([2u8, 2u8, 0x44u8, 0x01u8, 0u8, 0x3Bu8])

proc ppm2x2(): seq[uint8] =
  ## Binary P6 PPM: same 2x2 as the BMP (RGB, top-down).
  result = @[]
  for ch in "P6\n2 2\n255\n":
    result.add(uint8(ch))
  result.add([255u8, 0u8, 0u8, 0u8, 255u8, 0u8,
    0u8, 0u8, 255u8, 255u8, 255u8, 255u8])

proc tga2x2(): seq[uint8] =
  ## 2x2 uncompressed 24-bit TGA, top-left origin, BGR.
  result = @[0u8, 0u8, 2u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8]
  result.putU16le(2u16)
  result.putU16le(2u16)
  result.add(24u8)
  result.add(0x20u8)
  result.add([0u8, 0u8, 255u8, 0u8, 255u8, 0u8,
    255u8, 0u8, 0u8, 255u8, 255u8, 255u8])

proc rgbaAt(c: Canvas, id, x, y: int): seq[uint8] =
  let img = c.images[id]
  let o = (y * img.w + x) * 4
  img.pixels[o ..< o + 4]

proc checkPx(c: Canvas, id, x, y: int, r, g, b, a: uint8) =
  check c.rgbaAt(id, x, y) == @[r, g, b, a]

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

test "qoi decodes to exact texels":
  let c = newCanvas(4, 4)
  let id = c.createImageMem(qoiRed1x1(), {})
  check id != 0
  check c.imageSize(id) == (1, 1, true)
  checkPx(c, id, 0, 0, 255u8, 0u8, 0u8, 255u8)

test "bmp flips bottom-up rows to top-down rgba":
  let c = newCanvas(4, 4)
  let id = c.createImageMem(bmp2x2(), {})
  check id != 0
  check c.imageSize(id) == (2, 2, true)
  checkPx(c, id, 0, 0, 255u8, 0u8, 0u8, 255u8) # red
  checkPx(c, id, 1, 0, 0u8, 255u8, 0u8, 255u8) # green
  checkPx(c, id, 0, 1, 0u8, 0u8, 255u8, 255u8) # blue
  checkPx(c, id, 1, 1, 255u8, 255u8, 255u8, 255u8) # white

test "gif first frame composites":
  let c = newCanvas(4, 4)
  let id = c.createImageMem(gifRed1x1(), {})
  check id != 0
  check c.imageSize(id) == (1, 1, true)
  checkPx(c, id, 0, 0, 255u8, 0u8, 0u8, 255u8)

test "ppm and tga agree on the same 2x2":
  let want = [255u8, 0u8, 0u8, 255u8, 0u8, 255u8, 0u8, 255u8,
    0u8, 0u8, 255u8, 255u8, 255u8, 255u8, 255u8, 255u8]
  let c = newCanvas(4, 4)
  let p = c.createImageMem(ppm2x2(), {})
  check p != 0 and c.images[p].pixels == want
  let t = c.createImageMem(tga2x2(), {})
  check t != 0 and c.images[t].pixels == want

test "png round-trips through our own encoder":
  let src = newCanvas(4, 4)
  src.clear(rgbf(0, 1, 0))
  let c = newCanvas(4, 4)
  let id = c.createImageMem(src.encodePng(), {})
  check id != 0
  check c.imageSize(id) == (4, 4, true)
  checkPx(c, id, 2, 3, 0u8, 255u8, 0u8, 255u8)
  # Truncated PNG fails clean.
  check c.createImageMem(src.encodePng()[0 ..< 24], {}) == 0

test "jpeg round-trips solid colors within tolerance":
  var px = newSeq[Rgba[uint8]](256)
  for i in 0 ..< 256:
    px[i] = Rgba[uint8](data: [0u8, 0u8, 255u8, 255u8])
  let enc = encodeJpeg(DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 16u32, height: 16u32, pixels: px)), 90)
  check enc.ok
  let c = newCanvas(20, 20)
  let id = c.createImageMem(enc.value, {})
  check id != 0
  check c.imageSize(id) == (16, 16, true)
  let got = c.rgbaAt(id, 7, 9)
  check abs(int(got[0]) - 0) <= 12
  check abs(int(got[1]) - 0) <= 12
  check abs(int(got[2]) - 255) <= 12
  check got[3] == 255u8

test "undecodable inputs are 0 handles, not exceptions":
  let c = newCanvas(8, 8)
  check c.createImageMem([], {}) == 0
  check c.createImageMem(@[77u8, 90u8, 1u8, 2u8, 3u8], {}) == 0
  check c.createImageMem(bmp2x2()[0 ..< 20], {}) == 0 # truncated BMP
  check c.createImageFile("/nonexistent/nvg-test.png", {}) == 0
  check c.imageSize(999) == (0, 0, false)

test "image files load from disk":
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  writeFile(outDir / "bmp2x2.bmp", cast[string](bmp2x2()))
  let c = newCanvas(8, 8)
  let id = c.createImageFile(outDir / "bmp2x2.bmp", {})
  check id != 0
  checkPx(c, id, 0, 0, 255u8, 0u8, 0u8, 255u8)
  checkPx(c, id, 1, 1, 255u8, 255u8, 255u8, 255u8)

test "loaded images paint as patterns":
  let c = newCanvas(4, 4)
  c.clear(rgb(255, 255, 255))
  let id = c.createImageMem(bmp2x2(), {ifNearest})
  check id != 0
  c.beginPath()
  c.rect(0, 0, 4, 4)
  c.setFillPaint(c.imagePattern(0, 0, 2, 2, 0, id, 1.0))
  c.fill()
  check c.surface.getPixel(0, 0).r > 0.9 # red texel
  check c.surface.getPixel(3, 0).g > 0.9 # green texel
  check c.surface.getPixel(0, 3).b > 0.9 # blue texel
  let w = c.surface.getPixel(3, 3)
  check w.r > 0.9 and w.g > 0.9 and w.b > 0.9 # white texel

test "image loading golden":
  let c = newCanvas(64, 32)
  c.clear(rgb(255, 255, 255))
  let id = c.createImageMem(bmp2x2(), {ifRepeatX, ifRepeatY})
  c.beginPath()
  c.rect(4, 4, 56, 24)
  c.setFillPaint(c.imagePattern(4, 4, 8, 8, 0, id, 1.0))
  c.fill()
  let outDir = currentSourcePath().parentDir() / "testresults"
  createDir(outDir)
  c.savePng(outDir / "images.png")
  check fileExists(outDir / "images.png")
